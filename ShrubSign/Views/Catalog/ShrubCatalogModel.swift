// ShrubSign 2.3.1 · Explicit catalog loading; avoid decoding the entire cache on first tab display.
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
    // Prepared off the main actor alongside repository decoding.
    let entries: [ShrubCatalogEntry]

    init(sourceURL: URL, repository: ASRepository?, message: String?, usedCache: Bool) {
        self.sourceURL = sourceURL
        self.repository = repository
        self.message = message
        self.usedCache = usedCache
        let name = repository?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false ? name! : sourceURL.host ?? "Repository")
        if let repository {
            self.entries = repository.apps.enumerated().map { index, app in
                ShrubCatalogEntry(id: "\(sourceURL.absoluteString)#\(index)",
                                  sourceURL: sourceURL, sourceName: displayName,
                                  repository: repository, app: app)
            }
        } else {
            self.entries = []
        }
    }
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
    @Published private(set) var hasRequestedLoad = false
    @Published private(set) var directoryError: String?
    @Published private(set) var revision = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastAttempt: Date?

    @Published private(set) var appCount = 0
    @Published private(set) var currentSourceName: String?

    private var loadedCache = false
    private var isPreparingLoad = false
    private static let proxyBase = URL(string: "https://shrublibrary.pages.dev/proxy")!
    private var revisionWorkItem: DispatchWorkItem?
    private let refreshInterval: TimeInterval = 15 * 60

    private init() {
        let defaults = UserDefaults.standard
        let successTimestamp = defaults.double(forKey: "ShrubSign.catalog.lastRefresh")
        let attemptTimestamp = defaults.double(forKey: "ShrubSign.catalog.lastAttempt")
        if successTimestamp > 0 { lastUpdated = Date(timeIntervalSince1970: successTimestamp) }
        if attemptTimestamp > 0 { lastAttempt = Date(timeIntervalSince1970: attemptTimestamp) }
    }

    // Called exclusively by a user action. Merely opening the ShrubLibrary tab
    // must not begin network requests or decode thousands of cached app models.
    @MainActor
    func refresh() async {
        guard !isPreparingLoad && !isLoading else { return }
        isPreparingLoad = true
        hasRequestedLoad = true
        defer { isPreparingLoad = false }
        await loadCacheDirectoryOnce()
        await loadNetwork(force: true)
    }

    // Cache hydration previously eagerly decoded every saved repository as soon
    // as the tab appeared. On low-memory devices this could terminate the app.
    // A small cached directory is enough to retain source URLs for offline retry;
    // individual repositories use their disk cache only when a fetch fails.
    @MainActor
    private func loadCacheDirectoryOnce() async {
        guard !loadedCache else { return }
        loadedCache = true
        let cachedDirectory = Self.readCachedDirectory()
        directory = Self.parseDirectory(cachedDirectory)
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
        currentSourceName = nil

        let attemptDate = Date()
        lastAttempt = attemptDate
        UserDefaults.standard.set(attemptDate.timeIntervalSince1970, forKey: "ShrubSign.catalog.lastAttempt")

        defer {
            isLoading = false
            currentSourceName = nil
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
            let concurrency = min(2, urls.count)
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
                currentSourceName = result.repository?.name ?? result.sourceURL.host
                let key = result.sourceURL.absoluteString
                if let repo = result.repository {
                    accept(repo, from: result.sourceURL, entries: result.entries)
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
    private func accept(_ repository: ASRepository, from url: URL, entries: [ShrubCatalogEntry]) {
        let key = url.absoluteString
        appCount += entries.count - (chunks[key]?.count ?? 0)
        repositories[key] = repository
        chunks[key] = entries
    }

    @MainActor
    private func publishRevisionSoon() {
        revisionWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.revision &+= 1
        }
        revisionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: item)
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
        guard let response = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw NSError(domain: "ShrubLibraryHTTP", code: response.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(response.statusCode)"])
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
            let (repo, _) = try decodeRepository(data, originalURL: url)
            return ShrubCatalogResult(sourceURL: url, repository: repo, message: nil, usedCache: true)
        } catch {
            return ShrubCatalogResult(sourceURL: url, repository: nil, message: error.localizedDescription, usedCache: false)
        }
    }

    // Proxy is a fallback for connection/format failures, not a mandatory extra
    // round trip for every healthy repository. The original source URL stays
    // attached to the parsed repository and is never replaced with /proxy.
    private static func proxyURL(for original: URL, repair: Bool = false, image: Bool = false) -> URL? {
        guard ["https", "http"].contains(original.scheme?.lowercased() ?? ""),
              let host = original.host, !host.isEmpty else { return nil }
        var components = URLComponents(url: proxyBase, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "url", value: original.absoluteString)]
        if repair { items.append(URLQueryItem(name: "repair", value: "1")) }
        if image { items.append(URLQueryItem(name: "image", value: "1")) }
        components?.queryItems = items
        return components?.url
    }

    static func imageFallbackURL(for url: URL) -> URL? {
        proxyURL(for: url, image: true)
    }

    private static func fetchRepository(at url: URL) async -> ShrubCatalogResult {
        var failures: [String] = []
        // Only known TLS-troubled sources try the existing ShrubLibrary edge
        // proxy first; all other sources prefer a normal, direct request.
        let proxyFirst = ["delvek.net", "ipa.thuthuatjb.com"].contains(url.host?.lowercased() ?? "")
        var attempts: [(URL, Bool)] = []
        if proxyFirst, let proxy = proxyURL(for: url) { attempts.append((proxy, false)) }
        attempts.append((url, false))
        if !proxyFirst, let proxy = proxyURL(for: url) { attempts.append((proxy, false)) }

        for (requestURL, _) in attempts {
            if Task.isCancelled {
                return ShrubCatalogResult(sourceURL: url, repository: nil, message: "Cancelled", usedCache: false)
            }
            do {
                let data = try await downloadRepositoryData(from: requestURL)
                do {
                    let (repo, normalizedData) = try decodeRepository(data, originalURL: url)
                    try? normalizedData.write(to: cacheURL(for: url), options: .atomic)
                    return ShrubCatalogResult(sourceURL: url, repository: repo, message: nil, usedCache: false)
                } catch {
                    failures.append("\(requestURL == url ? "Direct" : "Proxy"): \(friendlyError(error))")
                    // Repair only malformed JSON. A repository with valid JSON but
                    // unsupported app metadata cannot be fixed by JSON text repair.
                    if requestURL != url, !isValidJSON(data),
                       let repaired = proxyURL(for: url, repair: true) {
                        do {
                            let repairedData = try await downloadRepositoryData(from: repaired)
                            let (repo, normalizedData) = try decodeRepository(repairedData, originalURL: url)
                            try? normalizedData.write(to: cacheURL(for: url), options: .atomic)
                            return ShrubCatalogResult(sourceURL: url, repository: repo, message: nil, usedCache: false)
                        } catch {
                            failures.append("Repair: \(friendlyError(error))")
                        }
                    }
                }
            } catch {
                failures.append("\(requestURL == url ? "Direct" : "Proxy"): \(friendlyError(error))")
            }
        }
        // A temporary fetch failure must not erase previously cached apps.
        let cached = cachedRepository(at: url)
        let message = failures.joined(separator: " · ")
        if let repo = cached.repository {
            return ShrubCatalogResult(sourceURL: url, repository: repo,
                                      message: message, usedCache: true)
        }
        return ShrubCatalogResult(sourceURL: url, repository: nil,
                                  message: message.isEmpty ? "Source unavailable" : message,
                                  usedCache: false)
    }

    private static func downloadRepositoryData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("ShrubSign/2.3 (iOS; repository client)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response, data: data, maximum: 100_000_000)
        return data
    }

    private static func isValidJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private static func decodeRepository(_ data: Data, originalURL: URL) throws -> (ASRepository, Data) {
        // Fast path: preserve standard repositories byte-for-byte when possible.
        if let repo = try? JSONDecoder().decode(ASRepository.self, from: data),
           (repo.iconURL == nil || repo.iconURL?.scheme != nil) {
            return (repo, data)
        }
        // Tolerant fallback: normalize inconsistent optional metadata and URLs,
        // while keeping real app names, source identities and download links.
        let cleaned = try ShrubCatalogJSON.normalize(data, sourceURL: originalURL)
        return (try JSONDecoder().decode(ASRepository.self, from: cleaned), cleaned)
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
