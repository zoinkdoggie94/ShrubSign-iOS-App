// ShrubSign 2.3: Convert nonstandard optional AltStore metadata to a form the
// existing repository model can decode. No download URL or source identity is
// fabricated. This runs off the main UI thread with the catalog's fetch task.
import Foundation

enum ShrubCatalogJSON {
    enum FormatError: LocalizedError {
        case notARepository, noApps, incompatibleApps(Int), marketplaceOnly
        var errorDescription: String? {
            switch self {
            case .notARepository: return "Response is not a compatible repository JSON object"
            case .noApps: return "This source lists no apps"
            case .incompatibleApps(let count): return "This source has \(count) app entries, but their format is not supported"
            case .marketplaceOnly: return "This is a marketplace-only source; it does not provide a sideloadable IPA"
            }
        }
    }

    static func normalize(_ data: Data, sourceURL: URL) throws -> Data {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var root: [String: Any]
        if let object = raw as? [String: Any] {
            if let wrapped = (object["repository"] ?? object["source"]) as? [String: Any], wrapped["apps"] != nil {
                root = wrapped
            } else { root = object }
        } else if let array = raw as? [[String: Any]] {
            root = ["apps": array]
        } else { throw FormatError.notARepository }

        // Only use an alias when the expected apps key is truly absent.
        if root["apps"] == nil {
            root["apps"] = root["applications"] ?? root["packages"]
        }
        if root["identifier"] == nil { root["identifier"] = root["id"] }
        if root["name"] == nil { root["name"] = sourceURL.host ?? "Repository" }
        for key in ["name", "identifier", "subtitle", "description", "patreonURL"] {
            stringValue(&root, key: key)
        }
        for key in ["website", "iconURL", "headerURL"] {
            webURL(&root, key: key, base: sourceURL)
        }
        // Optional malformed presentation metadata should not hide valid apps.
        if !(root["featuredApps"] is [String]) { root.removeValue(forKey: "featuredApps") }
        root.removeValue(forKey: "news")
        root.removeValue(forKey: "userInfo")
        root.removeValue(forKey: "tintColor")

        guard let rawApps = root["apps"] as? [Any] else { throw FormatError.notARepository }
        guard !rawApps.isEmpty else { throw FormatError.noApps }
        var normalized: [[String: Any]] = []
        var marketplaceOnly = 0
        for rawApp in rawApps {
            guard var app = rawApp as? [String: Any] else { continue }
            if app["bundleIdentifier"] == nil { app["bundleIdentifier"] = app["bundleID"] ?? app["bundleId"] ?? app["identifier"] }
            if app["name"] == nil { app["name"] = app["appName"] ?? app["title"] }
            if app["developerName"] == nil { app["developerName"] = app["developer"] }
            if app["downloadURL"] == nil { app["downloadURL"] = app["ipaURL"] ?? app["downloadUrl"] }
            if app["iconURL"] == nil { app["iconURL"] = app["icon"] }
            for key in ["name", "bundleIdentifier", "subtitle", "description", "developerName",
                        "version", "versionDescription", "localizedDescription", "category"] {
                stringValue(&app, key: key)
            }
            if app["name"] == nil { app["name"] = app["bundleIdentifier"] ?? "Unnamed app" }
            for key in ["downloadURL", "iconURL"] { webURL(&app, key: key, base: sourceURL) }
            if let screenshotArray = app["screenshotURLs"] as? [Any] {
                app["screenshotURLs"] = screenshotArray.compactMap { absoluteURL($0, relativeTo: sourceURL) }
            } else { app.removeValue(forKey: "screenshotURLs") }
            // The UI supports the original screenshot metadata when valid; do
            // not let an unusual layout invalidate the entire app.
            if let shots = app["screenshots"] as? [Any] {
                app["screenshots"] = shots.compactMap { absoluteURL($0, relativeTo: sourceURL) }
            } else if let shots = app["screenshots"] as? [String: Any] {
                var fixed: [String: Any] = [:]
                for key in ["iphone", "ipad"] {
                    if let values = shots[key] as? [Any] {
                        fixed[key] = values.compactMap { absoluteURL($0, relativeTo: sourceURL) }
                    }
                }
                app["screenshots"] = fixed
            } else { app.removeValue(forKey: "screenshots") }
            if let number = app["size"] as? NSNumber { app["size"] = number.int64Value }
            else if let text = app["size"] as? String, Int64(text) == nil { app.removeValue(forKey: "size") }
            else if app["size"] != nil && !(app["size"] is String) { app.removeValue(forKey: "size") }
            if !(app["beta"] is Bool) { app.removeValue(forKey: "beta") }
            app.removeValue(forKey: "tintColor")
            app.removeValue(forKey: "permissions")
            app.removeValue(forKey: "appPermissions")
            if let versions = app["versions"] as? [[String: Any]] {
                var cleanedVersions: [[String: Any]] = []
                for var version in versions {
                    if version["version"] == nil { version["version"] = app["version"] ?? "Unknown" }
                    for key in ["version", "buildVersion", "localizedDescription"] { stringValue(&version, key: key) }
                    if version["downloadURL"] == nil { version["downloadURL"] = version["ipaURL"] ?? version["url"] }
                    webURL(&version, key: "downloadURL", base: sourceURL)
                    if let n = version["size"] as? NSNumber { version["size"] = n.uint64Value }
                    else if let t = version["size"] as? String, UInt(t) == nil { version.removeValue(forKey: "size") }
                    version.removeValue(forKey: "minOSVersion")
                    if !(version["date"] is String) { version.removeValue(forKey: "date") }
                    cleanedVersions.append(version)
                }
                app["versions"] = cleanedVersions
            } else { app.removeValue(forKey: "versions") }
            if !(app["versionDate"] is String) { app.removeValue(forKey: "versionDate") }
            let hasDownload = (app["downloadURL"] as? String) != nil ||
                ((app["versions"] as? [[String: Any]])?.contains { $0["downloadURL"] is String } ?? false)
            if app["marketplaceID"] != nil && !hasDownload { marketplaceOnly += 1; continue }
            // This source can also include IPA versions alongside a marketplace
            // ID. Keep the IPA versions; marketplace-only items are omitted.
            app.removeValue(forKey: "marketplaceID")
            normalized.append(app)
        }
        guard !normalized.isEmpty else {
            if marketplaceOnly > 0 { throw FormatError.marketplaceOnly }
            throw FormatError.incompatibleApps(rawApps.count)
        }
        root["apps"] = normalized
        return try JSONSerialization.data(withJSONObject: root, options: [.fragmentsAllowed])
    }

    private static func stringValue(_ dict: inout [String: Any], key: String) {
        guard let value = dict[key], !(value is NSNull) else { dict.removeValue(forKey: key); return }
        if let string = value as? String { dict[key] = string }
        else if let number = value as? NSNumber { dict[key] = number.stringValue }
        else { dict.removeValue(forKey: key) }
    }

    private static func webURL(_ dict: inout [String: Any], key: String, base: URL) {
        if let absolute = absoluteURL(dict[key], relativeTo: base) { dict[key] = absolute }
        else { dict.removeValue(forKey: key) }
    }

    private static func absoluteURL(_ value: Any?, relativeTo base: URL) -> String? {
        guard let text = value as? String, !text.isEmpty,
              let resolved = URL(string: text, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(resolved.scheme?.lowercased() ?? ""),
              resolved.host != nil else { return nil }
        return resolved.absoluteString
    }
}
