// ShrubSign 3.1 · saved apps, version discovery, and changed-version tracking.
import SwiftUI
import Foundation
import AltSourceKit

struct ShrubCatalogUpdate: Codable, Identifiable {
    var id: String { appID }
    let appID: String
    let appName: String
    let previous: String
    let current: String
    let discovered: Date
}

final class ShrubCatalogFavorites: ObservableObject {
    static let shared = ShrubCatalogFavorites()
    @Published private(set) var saved: Set<String> = []
    @Published private(set) var updates: [ShrubCatalogUpdate] = []
    private var knownVersions: [String: String] = [:]
    private let savedKey = "ShrubSign.catalog.favoriteIDs.v1"
    private let versionsKey = "ShrubSign.catalog.knownVersions.v1"
    private let updatesKey = "ShrubSign.catalog.favoriteUpdates.v1"
    private init() {
        saved = Set(UserDefaults.standard.stringArray(forKey: savedKey) ?? [])
        knownVersions = UserDefaults.standard.dictionary(forKey: versionsKey) as? [String: String] ?? [:]
        if let data = UserDefaults.standard.data(forKey: updatesKey),
           let savedUpdates = try? JSONDecoder().decode([ShrubCatalogUpdate].self, from: data) { updates = savedUpdates }
    }
    static func key(_ app: ASRepository.App) -> String {
        let id = app.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false ? id! : app.currentName).lowercased()
    }
    func contains(_ app: ASRepository.App) -> Bool { saved.contains(Self.key(app)) }
    func toggle(_ app: ASRepository.App) {
        let id = Self.key(app)
        if !saved.insert(id).inserted {
            saved.remove(id)
            updates.removeAll { $0.appID == id }
        }
        UserDefaults.standard.set(Array(saved).sorted(), forKey: savedKey)
        saveUpdates()
    }
    func observe(_ chunks: [String: [ShrubCatalogEntry]]) {
        guard !saved.isEmpty else { return }
        var latest: [String: (String, String)] = [:]
        for chunk in chunks.values {
            for entry in chunk {
                let key = Self.key(entry.app)
                guard saved.contains(key), let version = entry.app.currentVersion, !version.isEmpty else { continue }
                if let previous = latest[key],
                   previous.0.compare(version, options: .numeric) != .orderedAscending { continue }
                latest[key] = (version, entry.app.currentName)
            }
        }
        for (key, value) in latest {
            if let prior = knownVersions[key],
               prior.compare(value.0, options: .numeric) == .orderedAscending {
                updates.removeAll { $0.appID == key }
                updates.insert(ShrubCatalogUpdate(appID: key, appName: value.1,
                    previous: prior, current: value.0, discovered: Date()), at: 0)
            }
            knownVersions[key] = value.0
        }
        updates = Array(updates.prefix(50))
        UserDefaults.standard.set(knownVersions, forKey: versionsKey)
        saveUpdates()
    }
    func clearUpdates() { updates = []; saveUpdates() }
    private func saveUpdates() {
        if let data = try? JSONEncoder().encode(updates) { UserDefaults.standard.set(data, forKey: updatesKey) }
    }
}

struct ShrubCompareVersionsView: View {
    let app: ASRepository.App
    @StateObject private var catalog = ShrubCatalogModel.shared
    private var matches: [ShrubCatalogEntry] {
        let key = ShrubCatalogFavorites.key(app)
        return catalog.chunks.values.flatMap { $0 }.filter {
            ShrubCatalogFavorites.key($0.app) == key
        }.sorted {
            ($0.app.currentVersion ?? "0").compare($1.app.currentVersion ?? "0", options: .numeric) == .orderedDescending
        }
    }
    var body: some View {
        List {
            Section {
                Text("Compare versions of this app across loaded ShrubLibrary sources. Original download URLs and repository identities are preserved.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Available sources · \(matches.count)") {
                if matches.isEmpty { Text("Load ShrubLibrary repositories to compare releases.").foregroundStyle(.secondary) }
                ForEach(matches) { entry in
                    NavigationLink {
                        SourceAppsDetailView(source: entry.repository, app: entry.app)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.app.currentVersion ?? "Version not listed")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            Text(entry.sourceName).font(.caption).foregroundStyle(.secondary)
                            if let url = entry.app.currentDownloadUrl {
                                Text(url.host ?? url.absoluteString)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Available Versions")
    }
}

struct ShrubSavedUpdatesView: View {
    @StateObject private var store = ShrubCatalogFavorites.shared
    @StateObject private var catalog = ShrubCatalogModel.shared
    private var favorites: [ShrubCatalogEntry] {
        var unique = Set<String>()
        var results: [ShrubCatalogEntry] = []
        for entry in catalog.chunks.values.flatMap({ $0 }) {
            let key = ShrubCatalogFavorites.key(entry.app)
            if store.saved.contains(key), unique.insert(key).inserted { results.append(entry) }
        }
        return results.sorted { $0.app.currentName.localizedStandardCompare($1.app.currentName) == .orderedAscending }
    }
    var body: some View {
        List {
            Section("New versions since your last catalog refresh") {
                if store.updates.isEmpty {
                    Text("No new versions detected for saved apps yet. Save apps, then refresh ShrubLibrary later to compare releases.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.updates) { update in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(update.appName).font(.subheadline.weight(.semibold))
                        Text("\(update.previous) → \(update.current)").font(.caption).foregroundStyle(.green)
                        Text(update.discovered, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !store.updates.isEmpty { Button("Clear update notices") { store.clearUpdates() } }
            }
            Section("Saved apps · \(store.saved.count)") {
                if favorites.isEmpty { Text("Save apps using the star beside catalog results.").foregroundStyle(.secondary) }
                ForEach(favorites) { entry in
                    NavigationLink {
                        ShrubCompareVersionsView(app: entry.app)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.app.currentName)
                            Text(entry.sourceName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Saved & What's New")
    }
}
