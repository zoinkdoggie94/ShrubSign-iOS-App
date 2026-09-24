// ShrubSign 2.3.1 · Explicit loading, lightweight first launch, clear repository controls.
import SwiftUI
import CoreData
import AltSourceKit
import NukeUI

struct ShrubCatalogView: View {
    @StateObject private var catalog = ShrubCatalogModel.shared
    @StateObject private var customModel = SourcesViewModel.shared
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var customSources: FetchedResults<AltSource>

    @State private var searchText = ""
    @State private var scope = 0
    @State private var results: [ShrubCatalogEntry] = []
    @State private var totalMatches = 0
    @State private var visibleLimit = 80
    @State private var isSearching = false
    @State private var showingAddSource = false
    @State private var showingFailures = false
    @State private var customRevision = 0

    private var revisionKey: String {
        "\(catalog.revision):\(customRevision):\(searchText):\(scope)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Catalog section", selection: $scope) {
                    Text("All Apps").tag(0)
                    Text("Repositories").tag(1)
                    Text("Imported").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                if scope == 0 { appsList }
                else if scope == 1 { repositoryList }
                else { importedList }
            }
            .navigationTitle("ShrubLibrary")
            .searchable(text: $searchText, prompt: scope == 0 ? "Search apps, bundles, sources" : "Search repositories")
            .toolbar {
                if scope != 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        if catalog.isLoading {
                            ProgressView().accessibilityLabel("Loading ShrubLibrary repositories")
                        } else {
                            Button { Task { await catalog.refresh() } } label: {
                                Label("Load or refresh repositories", systemImage: "arrow.clockwise")
                            }
                            .accessibilityHint("Starts loading the ShrubLibrary repository directory")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddSource = true } label: {
                        Label("Add custom repository", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSource) {
                SourcesAddView().presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingFailures) { failureSheet }
            // Custom repositories are only fetched after choosing Imported;
            // opening the catalog must never start two independent loading jobs.
            .task(id: scope == 2 ? customSources.map { $0.objectID }.description : "not-imported") {
                guard scope == 2 else { return }
                await customModel.fetchSources(customSources)
            }
            .onReceive(customModel.$sources) { _ in customRevision &+= 1 }
            .task(id: revisionKey) { await runSearch() }
        }
    }

    private var appsList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.green)
                            .frame(width: 46, height: 46)
                            .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ShrubLibrary Catalog").font(.headline)
                            Text("Apps from independent sources")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Label("\(catalog.appCount.formatted()) apps", systemImage: "square.grid.2x2.fill")
                        Label("\(catalog.repositories.count)/\(catalog.directory.count) sources", systemImage: "tray.full.fill")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    catalogLoadingControl
                    if !catalog.errors.isEmpty || catalog.directoryError != nil {
                        Button { showingFailures = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle")
                                Text("Review \(catalog.errors.count) source issues")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Review repository errors")
                    }
                    if !catalog.cachedFallbacks.isEmpty {
                        Label("\(catalog.cachedFallbacks.count) sources using saved data", systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("App listings are provided by independent repositories. Check the source before installing.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            if isSearching { ProgressView("Updating results...") }
            Section {
                NavigationLink {
                    DownloaderView()
                } label: {
                    Label("Downloads & recent imports", systemImage: "square.and.arrow.down")
                }
            }
            Section("Apps · \(totalMatches.formatted()) matches") {
                if results.isEmpty && !isSearching {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("No apps found", systemImage: "magnifyingglass")
                        Text(catalog.isLoading ? "Results will appear as repositories finish loading." :
                             !catalog.hasRequestedLoad ? "Tap Load ShrubLibrary Repositories above to get started." :
                             "Try a different search, or tap Refresh repositories above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(results.prefix(visibleLimit)) { entry in
                    NavigationLink {
                        SourceAppsDetailView(source: entry.repository, app: entry.app)
                    } label: {
                        catalogAppRow(entry)
                    }
                }
                if visibleLimit < results.count {
                    Button("Show more results") { visibleLimit += 80 }
                        .frame(maxWidth: .infinity)
                }
                if totalMatches > results.count {
                    Text("Showing the first \(results.count.formatted()) matches. Narrow your search to find more.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await catalog.refresh() }
    }

    // A full-size labeled action is deliberately shown even when the toolbar
    // contains a refresh symbol. This makes first-run behavior obvious on iPad.
    private var catalogLoadingControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            if catalog.isLoading {
                HStack(spacing: 10) {
                    ProgressView().tint(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Loading ShrubLibrary").font(.subheadline.weight(.semibold))
                        Text(catalog.directory.isEmpty ? "Connecting to the repository directory…" :
                             "Checking \(catalog.checkedCount) of \(catalog.directory.count) repositories")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if !catalog.directory.isEmpty {
                    ProgressView(value: Double(catalog.checkedCount),
                                 total: Double(max(catalog.directory.count, 1)))
                        .tint(.green)
                    if let name = catalog.currentSourceName {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Text("You can search apps that have already loaded.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(!catalog.hasRequestedLoad ? "Discover apps from ShrubLibrary" :
                         catalog.repositories.isEmpty ? "Unable to load repositories" : "Your library is ready")
                        .font(.subheadline.weight(.semibold))
                    Text(!catalog.hasRequestedLoad ?
                         "Repositories load only when you tap the button below. Nothing downloads just by opening this tab." :
                         catalog.repositories.isEmpty ? "Check source status or try loading again. Saved app data is not deleted." :
                         "You control when repositories refresh. Your current results remain available until you choose to reload.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await catalog.refresh() }
                } label: {
                    Label(catalog.hasRequestedLoad ? "Refresh repositories" : "Load ShrubLibrary Repositories",
                          systemImage: catalog.hasRequestedLoad ? "arrow.clockwise" : "square.and.arrow.down.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .accessibilityHint("Loads repositories from ShrubLibrary when you choose")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func catalogAppRow(_ entry: ShrubCatalogEntry) -> some View {
        HStack(spacing: 12) {
            LazyImage(url: entry.app.iconURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "app.dashed").resizable().scaledToFit().padding(12).foregroundStyle(.secondary)
                }
            }
            .frame(width: 49, height: 49)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.app.currentName).font(.body.weight(.semibold))
                    .lineLimit(2).minimumScaleFactor(0.85)
                Text(entry.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let version = entry.app.currentVersion {
                    Text("Version \(version)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var repositoryList: some View {
        List {
            Section { catalogLoadingControl }
            Section("ShrubLibrary · \(catalog.directory.count) sources") {
                if !catalog.errors.isEmpty || catalog.directoryError != nil {
                    Button { showingFailures = true } label: {
                        Label("Review \(catalog.errors.count) repository issues", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(catalog.directory.filter { url in
                    searchText.isEmpty || (catalog.repositories[url.absoluteString]?.name ?? url.host ?? "").localizedCaseInsensitiveContains(searchText)
                }, id: \.absoluteString) { url in
                    if let repo = catalog.repositories[url.absoluteString] {
                        NavigationLink {
                            ShrubCatalogRepositoryView(repository: repo, sourceURL: url)
                        } label: {
                            HStack(spacing: 12) {
                                ShrubCatalogRemoteIcon(url: repo.iconURL, size: 44,
                                                       fallback: "square.stack.3d.up")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(repo.name ?? url.host ?? "Repository")
                                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text("\(repo.apps.count.formatted()) apps · \(url.host ?? "")")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } else {
                        HStack {
                            ShrubCatalogRemoteIcon(url: nil, size: 40,
                                                   fallback: "square.stack.3d.up")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url.host ?? url.absoluteString).lineLimit(2)
                                Text(catalog.errors[url.absoluteString] != nil ? "Unavailable · Check source status" :
                                     catalog.isLoading ? "Waiting for repository…" : "Not loaded")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if catalog.isLoading && catalog.errors[url.absoluteString] == nil {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                }
            }
            Section("Your repositories") {
                NavigationLink { SourcesView() } label: {
                    Label("Manage custom repositories", systemImage: "slider.horizontal.3")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var importedList: some View {
        List {
            Section {
                Button { showingAddSource = true } label: {
                    Label("Import repository URL", systemImage: "plus.circle.fill")
                }
                NavigationLink { SourcesView() } label: {
                    Label("Manage all imported sources", systemImage: "square.stack.3d.up")
                }
            }
            Section("Your sources · \(customSources.count)") {
                ForEach(customSources.filter { source in
                    searchText.isEmpty || (source.name ?? "").localizedCaseInsensitiveContains(searchText)
                }) { source in
                    if let repo = customModel.sources[source] {
                        NavigationLink {
                            ShrubCatalogRepositoryView(repository: repo, sourceURL: source.sourceURL)
                        } label: {
                            HStack(spacing: 12) {
                                ShrubCatalogRemoteIcon(url: repo.iconURL, size: 44,
                                                       fallback: "square.stack.3d.up")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name ?? "Unnamed source").lineLimit(2)
                                    Text("\(repo.apps.count.formatted()) apps · \(source.sourceURL?.host ?? "")")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    } else {
                        Label(source.name ?? "Unavailable source", systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await customModel.fetchSources(customSources, refresh: true) }
    }

    private var failureSheet: some View {
        NavigationStack {
            List {
                if let error = catalog.directoryError { Text(error) }
                ForEach(catalog.errors.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(key, systemImage: "exclamationmark.triangle")
                            .font(.footnote.weight(.medium)).textSelection(.enabled)
                        Text(catalog.errors[key] ?? "Could not load this source right now")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Repository status")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingFailures = false } }
            }
        }
    }

    private func runSearch() async {
        guard scope == 0 else { isSearching = false; return }
        // Do not start a detached search worker when the app has only just
        // opened and no repository data has been requested or loaded.
        if catalog.chunks.isEmpty && customModel.sources.isEmpty {
            results = []
            totalMatches = 0
            isSearching = false
            return
        }
        isSearching = true
        if !searchText.isEmpty {
            try? await Task.sleep(nanoseconds: 220_000_000)
        }
        guard !Task.isCancelled else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Snapshot source metadata on the UI actor; filter and rank in a background task.
        let chunksSnapshot = Array(catalog.chunks.values)
        let known = Set(catalog.repositories.keys)
        let customSnapshot: [(URL, String, ASRepository)] = customModel.sources.compactMap { source, repo in
            guard let url = source.sourceURL, !known.contains(url.absoluteString) else { return nil }
            return (url, repo.name ?? source.name ?? url.host ?? "Repository", repo)
        }
        let worker = Task.detached(priority: .userInitiated) { () -> ([ShrubCatalogEntry], Int) in
            let tokens = query.lowercased()
            var buckets = Array(repeating: [ShrubCatalogEntry](), count: 7)
            var count = 0
            var searchChunks = chunksSnapshot
            for (url, name, repo) in customSnapshot {
                searchChunks.append(repo.apps.enumerated().map { index, app in
                    ShrubCatalogEntry(id: "custom:\(url.absoluteString)#\(index)", sourceURL: url,
                                      sourceName: name, repository: repo, app: app)
                })
            }
            for chunk in searchChunks {
                if Task.isCancelled { break }
                for entry in chunk {
                    if Task.isCancelled { break }
                    let name = entry.app.currentName.lowercased()
                    let identifier = (entry.app.id ?? "").lowercased()
                    let source = entry.sourceName.lowercased()
                    let rank: Int
                    if tokens.isEmpty { rank = 0 }
                    else if name == tokens { rank = 0 }
                    else if name.hasPrefix(tokens) { rank = 1 }
                    else if identifier == tokens { rank = 2 }
                    else if name.contains(tokens) { rank = 3 }
                    else if identifier.contains(tokens) { rank = 4 }
                    else if source.contains(tokens) { rank = 5 }
                    else if (entry.app.localizedDescription ?? "").localizedCaseInsensitiveContains(query) { rank = 6 }
                    else { continue }
                    count += 1
                    // Limit retained results to keep huge sources responsive.
                    if buckets[rank].count < 1200 { buckets[rank].append(entry) }
                }
            }
            return (Array(buckets.joined().prefix(1200)), count)
        }
        let outcome = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        results = outcome.0
        totalMatches = outcome.1
        visibleLimit = 80
        isSearching = false
    }
}

private struct ShrubCatalogRepositoryView: View {
    let repository: ASRepository
    let sourceURL: URL?
    @State private var search = ""
    @State private var visible = 80

    private var matches: [ASRepository.App] {
        guard !search.isEmpty else { return repository.apps }
        return repository.apps.filter {
            $0.currentName.localizedCaseInsensitiveContains(search) ||
            ($0.id ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    ShrubCatalogRemoteIcon(url: repository.iconURL, size: 56,
                                           fallback: "square.stack.3d.up.fill")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(repository.name ?? "Repository")
                            .font(.headline).lineLimit(2)
                        Text("\(repository.apps.count.formatted()) app listings")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if let sourceURL {
                    Text(sourceURL.absoluteString).font(.caption)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("Apps") {
                ForEach(Array(matches.prefix(visible).enumerated()), id: \.offset) { item in
                    NavigationLink {
                        SourceAppsDetailView(source: repository, app: item.element)
                    } label: {
                        HStack(spacing: 12) {
                            ShrubCatalogRemoteIcon(url: item.element.iconURL, size: 42,
                                                   fallback: "app.dashed")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.element.currentName).lineLimit(2)
                                Text(item.element.currentVersion ?? "Version not listed")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if visible < matches.count {
                    Button("Show more") { visible += 80 }
                }
            }
        }
        .navigationTitle(repository.name ?? "Repository")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search this repository")
        .onChange(of: search) { _ in visible = 80 }
    }
}

// Display genuine source artwork when published; use an unobtrusive native
// symbol when absent. Only retry a failed icon through the existing proxy.
private struct ShrubCatalogRemoteIcon: View {
    let url: URL?
    let size: CGFloat
    let fallback: String
    @State private var useProxy = false

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: useProxy ? ShrubCatalogModel.imageFallbackURL(for: url) : url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: fallback)
                            .resizable().scaledToFit().padding(size * 0.27)
                            .foregroundStyle(.secondary)
                            .task { if !useProxy { useProxy = true } }
                    case .empty:
                        Image(systemName: fallback)
                            .resizable().scaledToFit().padding(size * 0.27)
                            .foregroundStyle(.secondary)
                    @unknown default:
                        Image(systemName: fallback)
                            .resizable().scaledToFit().padding(size * 0.27)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: fallback)
                    .resizable().scaledToFit().padding(size * 0.27)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}
