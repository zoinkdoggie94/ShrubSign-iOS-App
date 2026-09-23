// ShrubSign 2.1 · Native ShrubLibrary catalog. Sources remain independent.
import Foundation
import SwiftUI
import AltSourceKit

struct ShrubCatalogEntry: Identifiable, Sendable {
    let id: String
    let sourceURL: URL
    let sourceName: String
    let repository: ASRepository
    let app: ASRepository.App
}

struct ShrubCatalogResult: Sendable {
    let sourceURL: URL
    let repository: ASRepository?
    let message: String?
}

final class ShrubCatalogModel: ObservableObject {
    static let shared = ShrubCatalogModel()
    static let directoryURL = URL(string: "https://shrublibrary.pages.dev/repos.txt")!

    @Published private(set) var directory: [URL] = []
    @Published private(set) var repositories: [String: ASRepository] = [:]
    @Published private(set) var chunks: [String: [ShrubCatalogEntry]] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var checkedCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var directoryError: String?
    @Published private(set) var revision = 0
    @Published private(set) var lastUpdated: Date?

    var appCount: Int { chunks.values.reduce(0) { $0 + $1.count } }
    private var loadedCache = false
    private let refreshInterval: TimeInterval = 15 * 60

    private init() {
        let timestamp = UserDefaults.standard.double(forKey: "ShrubSign.catalog.lastRefresh")
        if timestamp > 0 { lastUpdated = Date(timeIntervalSince1970: timestamp) }
    }

    @MainActor func loadIfNeeded() async { await load(force: false) }
    @MainActor func refresh() async { await load(force: true) }

    @MainActor private func load(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        directoryError = nil

        if !loadedCache {
            loadedCache = true
            let cachedDirectory = Self.readCachedDirectory()
            directory = Self.parseDirectory(cachedDirectory)
            // Read and parse persisted source JSON without blocking the UI thread.
            for group in stride(from: 0, to: directory.count, by: 4) {
                let batch = Array(directory[group..<min(group + 4, directory.count)])
                await withTaskGroup(of: ShrubCatalogResult.self) { tasks in
                    for url in batch {
                        tasks.addTask { Self.cachedRepository(at: url) }
                    }
                    for await result in tasks {
                        if let repo = result.repository { accept(repo, from: result.sourceURL) }
                    }
                }
            }
        }

        if !force, !directory.isEmpty,
           let lastUpdated, Date().timeIntervalSince(lastUpdated) < refreshInterval { return }

        let urls: [URL]
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.directoryURL)
            try Self.checkHTTP(response, data: data, maximum: 2_000_000)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CatalogError.invalidDirectory
            }
            let parsed = Self.parseDirectory(text)
            guard !parsed.isEmpty else { throw CatalogError.invalidDirectory }
            directory = parsed
            Self.saveDirectory(text)
            urls = parsed
        } catch {
            directoryError = "Directory refresh failed: \(error.localizedDescription). Showing available cached sources."
            urls = directory
        }
        guard !urls.isEmpty else { return }
        errors = [:]
        checkedCount = 0
        // A queue of at most three in-flight source requests. Each completed repo
        // is published immediately; one failed source never blocks the others.
        await withTaskGroup(of: ShrubCatalogResult.self) { tasks in
            var iterator = urls.makeIterator()
            for _ in 0..<min(3, urls.count) {
                if let url = iterator.next() { tasks.addTask { await Self.fetchRepository(at: url) } }
            }
            for await result in tasks {
                checkedCount += 1
                if let repo = result.repository {
                    accept(repo, from: result.sourceURL)
                    errors.removeValue(forKey: result.sourceURL.absoluteString)
                } else {
                    errors[result.sourceURL.absoluteString] = result.message ?? "Source unavailable"
                }
                if let next = iterator.next() {
                    tasks.addTask { await Self.fetchRepository(at: next) }
                }
            }
        }
        // A partial failure is not a successful catalog refresh. Retry it next time.
        if errors.isEmpty && directoryError == nil {
            let date = Date()
            lastUpdated = date
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "ShrubSign.catalog.lastRefresh")
        }
    }

    @MainActor private func accept(_ repository: ASRepository, from url: URL) {
        let key = url.absoluteString
        repositories[key] = repository
        let name = repository.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false ? name! : url.host ?? "Repository")
        chunks[key] = repository.apps.enumerated().map { index, app in
            ShrubCatalogEntry(
                id: "\(key)#\(index)", sourceURL: url, sourceName: displayName,
                repository: repository, app: app
            )
        }
        revision &+= 1
    }

    private enum CatalogError: LocalizedError {
        case invalidDirectory, invalidResponse, oversized
        var errorDescription: String? {
            switch self {
            case .invalidDirectory: return "No valid repository URLs in repos.txt"
            case .invalidResponse: return "The server returned an error or unexpected content"
            case .oversized: return "Source exceeds the 100 MB per-source safety limit"
            }
        }
    }

    private static func checkHTTP(_ response: URLResponse, data: Data, maximum: Int) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw CatalogError.invalidResponse
        }
        guard data.count <= maximum else { throw CatalogError.oversized }
    }

    private static func parseDirectory(_ string: String) -> [URL] {
        var seen = Set<String>()
        return string.components(separatedBy: .newlines).compactMap { line -> URL? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parsed = trimmed.hasPrefix("/")
                ? URL(string: trimmed, relativeTo: directoryURL)?.absoluteURL
                : URL(string: trimmed)
            guard let url = parsed,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            let canonical = url.absoluteString
            guard seen.insert(canonical).inserted else { return nil }
            return url
        }
    }

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("ShrubLibraryCatalog-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cacheURL(for url: URL) -> URL {
        // Stable FNV-1a hash; URL strings are never used as filenames.
        let hash = url.absoluteString.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        return cacheDirectory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    private static func readCachedDirectory() -> String {
        (try? String(contentsOf: cacheDirectory.appendingPathComponent("repos.txt"), encoding: .utf8)) ?? ""
    }

    private static func saveDirectory(_ string: String) {
        try? string.write(to: cacheDirectory.appendingPathComponent("repos.txt"), atomically: true, encoding: .utf8)
    }

    private static func cachedRepository(at url: URL) -> ShrubCatalogResult {
        do {
            let data = try Data(contentsOf: cacheURL(for: url))
            let repo = try JSONDecoder().decode(ASRepository.self, from: data)
            return ShrubCatalogResult(sourceURL: url, repository: repo, message: nil)
        } catch {
            return ShrubCatalogResult(sourceURL: url, repository: nil, message: error.localizedDescription)
        }
    }

    private static func fetchRepository(at url: URL) async -> ShrubCatalogResult {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 40
            let (data, response) = try await URLSession.shared.data(for: request)
            try checkHTTP(response, data: data, maximum: 100_000_000)
            let repo = try JSONDecoder().decode(ASRepository.self, from: data)
            try? data.write(to: cacheURL(for: url), options: .atomic)
            return ShrubCatalogResult(sourceURL: url, repository: repo, message: nil)
        } catch {
            return ShrubCatalogResult(sourceURL: url, repository: nil, message: error.localizedDescription)
        }
    }
}
