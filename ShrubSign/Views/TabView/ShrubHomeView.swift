// ShrubSign dashboard. All actions use the existing app services.
import SwiftUI
import CoreData
import NimbleViews
import UniformTypeIdentifiers

struct ShrubHomeView: View {
    @StateObject private var sourcesModel = SourcesViewModel.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var isImporting = false
    @State private var isAddingSource = false
    @State private var isURLDownloadPresented = false
    @State private var importError: String?

    @FetchRequest(entity: Imported.entity(), sortDescriptors: [])
    private var importedApps: FetchedResults<Imported>
    @FetchRequest(entity: Signed.entity(), sortDescriptors: [])
    private var signedApps: FetchedResults<Signed>
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var repositories: FetchedResults<AltSource>
    @FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)])
    private var certificates: FetchedResults<CertificatePair>

    private var expiringSoon: Int {
        let cutoff = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return certificates.filter { $0.expiration.map { $0 <= cutoff } ?? false }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dashboardHeader
                    dashboardCounts
                    quickActions
                    repositoryPreview
                    expirationNotice
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 32)
                .frame(maxWidth: 740)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ShrubUpdatesView() } label: {
                        Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .sheet(isPresented: $isImporting) {
                FileImporterRepresentableView(
                    allowedContentTypes: [.ipa, .tipa],
                    allowsMultipleSelection: true,
                    onDocumentsPicked: { urls in
                        guard !urls.isEmpty else { return }
                        for url in urls {
                            let download = downloadManager.startArchive(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
                            downloadManager.handlePachageFile(url: url, dl: download) { error in
                                if error != nil {
                                    DispatchQueue.main.async {
                                        importError = "Could not import \(url.lastPathComponent). Try another extraction method in Settings."
                                    }
                                }
                            }
                        }
                    }
                )
            }
            .sheet(isPresented: $isAddingSource) {
                SourcesAddView().presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isURLDownloadPresented) {
                ShrubURLDownloadSheet(downloadManager: downloadManager)
                    .presentationDetents([.medium])
            }
            .alert("IPA import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "The selected IPA could not be imported.")
            }
        }
    }

    private var dashboardHeader: some View {
        HStack(spacing: 14) {
            Image("ShrubHubMark")
                .resizable()
                .scaledToFit()
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("ShrubSign")
                        .font(.largeTitle.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("v\(Bundle.main.version)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                Text("Signing is easy with ShrubSign")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.06))
        }
        .padding(.top, 12)
    }

    private var dashboardCounts: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            countTile("Imported", count: importedApps.count, symbol: "square.and.arrow.down")
            countTile("Signed", count: signedApps.count, symbol: "checkmark.seal")
            countTile("Repositories", count: repositories.count, symbol: "square.stack.3d.up")
            countTile("Certificates", count: certificates.count, symbol: "signature")
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get started").font(.title2.bold())
            Button { isImporting = true } label: {
                actionRow("Import IPAs", description: "Choose one or several files to add to your library", icon: "square.and.arrow.down.fill")
            }
            Button { isURLDownloadPresented = true } label: {
                actionRow("Download IPA from URL", description: "Import a direct IPA link through the existing downloader", icon: "link")
            }
            NavigationLink {
                ShrubCatalogView()
            } label: {
                actionRow("ShrubLibrary Catalog", description: "On-demand search across ShrubLibrary and your custom repositories", icon: "books.vertical.fill")
            }
            NavigationLink {
                SourceAppsView(object: Array(repositories), viewModel: sourcesModel)
            } label: {
                actionRow("Browse repositories", description: "Open your saved sources and load them only when needed", icon: "magnifyingglass")
            }
            .disabled(repositories.isEmpty)
            NavigationLink {
                LibraryView()
            } label: {
                actionRow("Sign & manage apps", description: "Sign imported IPAs, or select several to batch sign", icon: "checkmark.shield.fill")
            }
            NavigationLink {
                CertificatesView()
            } label: {
                actionRow("Signing certificates", description: "Select, import, and inspect signing identities", icon: "person.crop.rectangle.stack")
            }
            NavigationLink {
                FilesView()
            } label: {
                actionRow("File manager", description: "Inspect and manage files stored in ShrubSign", icon: "folder.fill")
            }
            NavigationLink {
                SourcesView()
            } label: {
                actionRow("Manage repositories", description: "Refresh, add, browse, or remove your sources", icon: "square.stack.3d.up.fill")
            }
        }
        .buttonStyle(.plain)
    }

    private var repositoryPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Repositories").font(.title2.bold())
                Spacer()
                Button("Add source", systemImage: "plus") { isAddingSource = true }
                    .font(.subheadline)
            }
            if repositories.isEmpty {
                Text("Add an AltStore-compatible source to discover apps.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(repositories.prefix(4))) { repository in
                    NavigationLink {
                        SourceAppsView(object: [repository], viewModel: sourcesModel)
                    } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                            Text(repository.name ?? "Unnamed repository")
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(13)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain)
                }
            }
            Link(destination: URL(string: "https://shrublibrary.pages.dev")!) {
                actionRow("Explore ShrubLibrary", description: "Find more repository links on the ShrubLibrary website", icon: "globe")
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var expirationNotice: some View {
        if expiringSoon > 0 {
            Label("\(expiringSoon) certificate(s) expired or expiring within 30 days. Check your certificates before signing.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        Text("The certificate dates are read from your saved profiles. Expiration does not indicate Apple revocation status.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func countTile(_ label: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(count.formatted()).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.75)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func actionRow(_ title: String, description: String, icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 36, height: 36)
                .foregroundStyle(.tint)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
        .contentShape(Rectangle())
    }
}

private struct ShrubURLDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var downloadManager: DownloadManager
    @State private var text = ""

    private var inputURL: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host != nil else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/app.ipa", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Direct IPA link")
                } footer: {
                    Text("Enter an HTTP or HTTPS link to an IPA file. The existing download manager imports the archive into your library after downloading it.")
                }
                Section {
                    Button("Download and import", systemImage: "arrow.down.circle.fill") {
                        guard let url = inputURL else { return }
                        _ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
                        dismiss()
                    }
                    .disabled(inputURL == nil)
                }
            }
            .navigationTitle("Download IPA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
