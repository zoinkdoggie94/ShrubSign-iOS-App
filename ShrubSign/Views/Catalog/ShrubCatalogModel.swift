// ShrubSign 2.2 · Fast, on-demand ShrubLibrary catalog.
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
    let usedCache: Bool
}

final class ShrubCatalogModel: ObservableObject {
    static let shared = ShrubCatalogModel()
    static let directoryURL = URL(string: "https://shrublibrary.pages.dev/repos.txt")!

    @Published private(set) var directory: [URL] = []
    @Published private(set) var repositories: [String: ASRepository] = [:]
    @Published private(set) var chunks: [String: [ShrubCatalogEntry]] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var cachedFallbacks: Set<String> = []
    @Published private(set) var checkedCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var directoryError: String?
    @Published private(set) var revision = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastAttempt: Date?

    var appCount: Int { chunks.values.reduce(0) { $0 + $1.count } }

    private var loadedCache = false
    private var didAutoRefreshThisSession = false
    private var revisionWorkItem: DispatchWorkItem?
    private let refreshInterval: TimeInterval = 15 * 60

    private init() {
        let defaults = UserDefaults.standard
        let successTimestamp = defaults.double(forKey: "ShrubSign.catalog.lastRefresh")
        let attemptTimestamp = defaults.double(forKey: "ShrubSign.catalog.lastAttempt")
        if successTimestamp > 0 { lastUpdated = Date(timeIntervalSince1970: successTimestamp) }
        if attemptTimestamp > 0 { lastAttempt = Date(timeIntervalSince1970: attemptTimestamp) }
    }

    @MainActor
    func loadIfNeeded() async {
        await loadCacheOnce()
        guard !didAutoRefreshThisSession else { return }
        didAutoRefreshThisSession = true

        // A partial failure must not cause a refresh loop every time SwiftUI recreates the view.
        if !directory.isEmpty,
           let lastAttempt,
           Date().timeIntervalSince(lastAttempt) < refreshInterval {
            return
        }
        await loadNetwork(force: false)
    }

    @MainActor
    func refresh() async {
        await loadCacheOnce()
        await loadNetwork(force: true)
    }

    @MainActor
    private func loadCacheOnce() async {
        guard !loadedCache else { return }
        loadedCache = true

        let cachedDirectory = Self.readCachedDirectory()
        directory = Self.parseDirectory(cachedDirectory)
        guard !directory.isEmpty else { return }

        // Load disk cache in small batches. Cached apps appear immediately with no network traffic.
        for group in stride(from: 0, to: directory.count, by: 6) {
            guard !Task.isCancelled else { return }
            let batch = Array(directory[group..<min(group + 6, directory.count)])
            await withTaskGroup(of: ShrubCatalogResult.self) { tasks in
                for url in batch {
                    tasks.addTask { Self.cachedRepository(at: url) }
                }
                for await result in tasks {
                    if let repo = result.repository {
                        accept(repo, from: result.sourceURL)
                    }
                }
            }
        }
        publishRevisionSoon()
    }

    @MainActor
    private func loadNetwork(force: Bool) async {
        guard !isLoading else { return }
        if !force,
           let lastAttempt,
           Date().timeIntervalSince(lastAttempt) < refreshInterval {
            return
        }

        isLoading = true
        directoryError = nil
        checkedCount = 0
        errors = [:]
        cachedFallbacks = []

        let attemptDate = Date()
        lastAttempt = attemptDate
        UserDefaults.standard.set(attemptDate.timeIntervalSince1970, forKey: "ShrubSign.catalog.lastAttempt")

        defer {
            isLoading = false
            publishRevisionSoon()
        }

        let urls: [URL]
        do {
            var request = URLRequest(url: Self.directoryURL)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkHTTP(response, data: data, maximum: 2_000_000)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CatalogError.invalidDirectory
            }
            let parsed = Self.parseDirectory(text)
            guard !parsed.isEmpty else { throw CatalogError.invalidDirectory }
            directory = parsed
            Self.saveDirectory(text)
            urls = parsed
        } catch is CancellationError {
            return
        } catch {
            directoryError = "Could not refresh the source directory: \(error.localizedDescription). Cached repositories remain available."
            urls = directory
        }

        guard !urls.isEmpty else { return }

        // Keep network pressure low on iPad. Completing one source starts exactly one next source.
        await withTaskGroup(of: ShrubCatalogResult.self) { tasks in
            var iterator = urls.makeIterator()
            let concurrency = min(3, urls.count)
            for _ in 0..<concurrency {
                if let url = iterator.next() {
                    tasks.addTask { await Self.fetchRepository(at: url) }
                }
            }

            for await result in tasks {
                if Task.isCancelled {
                    tasks.cancelAll()
                    break
                }

                checkedCount += 1
                let key = result.sourceURL.absoluteString
                if let repo = result.repository {
                    accept(repo, from: result.sourceURL)
                    errors.removeValue(forKey: key)
                    if result.usedCache { cachedFallbacks.insert(key) }
                    else { cachedFallbacks.remove(key) }
                } else {
                    // "Unavailable" means this app couldn't fetch/parse it right now; it is not a block list.
                    errors[key] = result.message ?? "Could not load this source"
                }

                if checkedCount % 4 == 0 { publishRevisionSoon() }
                if let next = iterator.next() {
                    tasks.addTask { await Self.fetchRepository(at: next) }
                }
            }
        }

        if errors.isEmpty && directoryError == nil && !Task.isCancelled {
            let date = Date()
            lastUpdated = date
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "ShrubSign.catalog.lastRefresh")
        }
    }

    @MainActor
    private func accept(_ repository: ASRepository, from url: URL) {
        let key = url.absoluteString
        repositories[key] = repository
        let name = repository.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false ? name! : url.host ?? "Repository")
        chunks[key] = repository.apps.enumerated().map { index, app in
            ShrubCatalogEntry(
                id: "\(key)#\(index)",
                sourceURL: url,
                sourceName: displayName,
                repository: repository,
                app: app
            )
        }
    }

    @MainActor
    private func publishRevisionSoon() {
        revisionWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.revision &+= 1
        }
        revisionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: item)
    }

    private enum CatalogError: LocalizedError {
        case invalidDirectory, invalidResponse, oversized
        var errorDescription: String? {
            switch self {
            case .invalidDirectory: return "repos.txt did not contain usable repository URLs"
            case .invalidResponse: return "the server returned an unexpected response"
            case .oversized: return "the source exceeds the 100 MB per-source safety limit"
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
        let url = base.appendingPathComponent("ShrubLibraryCatalog-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cacheURL(for url: URL) -> URL {
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
            let data = try Data(contentsOf: cacheURL(for: url), options: [.mappedIfSafe])
            let repo = try JSONDecoder().decode(ASRepository.self, from: data)
            return ShrubCatalogResult(sourceURL: url, repository: repo, message: nil, usedCache: true)
        } catch {
            return ShrubCatalogResult(sourceURL: url, repository: nil, message: error.localizedDescription, usedCache: false)
        }
    }

    private static func fetchRepository(at url: URL) async -> ShrubCatalogResult {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 22
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("ShrubSign/2.2", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            try checkHTTP(response, data: data, maximum: 100_000_000)
            let repo = try JSONDecoder().decode(ASRepository.self, from: data)
            try? data.write(to: cacheURL(for: url), options: .atomic)
            return ShrubCatalogResult(sourceURL: url, repository: repo, message: nil, usedCache: false)
        } catch is CancellationError {
            return ShrubCatalogResult(sourceURL: url, repository: nil, message: "Cancelled", usedCache: false)
        } catch {
            // A temporary network/parse failure should not erase a repository that worked previously.
            let cached = cachedRepository(at: url)
            if let repo = cached.repository {
                return ShrubCatalogResult(sourceURL: url, repository: repo, message: error.localizedDescription, usedCache: true)
            }
            return ShrubCatalogResult(sourceURL: url, repository: nil, message: Self.friendlyError(error), usedCache: false)
        }
    }

    private static func friendlyError(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(_): return "Unsupported or malformed repository JSON"
            case .keyNotFound(_), .typeMismatch(_), .valueNotFound(_): return "Repository format is not compatible with this parser"
            @unknown default: return "Repository JSON could not be parsed"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "Request timed out"
            case .cannotFindHost, .cannotConnectToHost: return "Could not connect to the source"
            case .notConnectedToInternet: return "No internet connection"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
