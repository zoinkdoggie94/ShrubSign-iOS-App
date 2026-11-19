//
//  ShrubInstallSupport.swift
//  ShrubSign
//
//  Shared install vocabulary for ShrubSign 3.2.2.
//  Installation used to depend on a single external manifest service
//  (api.palera.in) that can disappear. These types let the app describe how it
//  will hand an IPA to iOS, validate that hand off before trying it, and fall
//  back to another route instead of failing silently.
//

import Foundation

// MARK: - User defaults
enum ShrubInstallKey {
    /// Kept for compatibility with earlier ShrubSign builds (0 = Fully Local, 1 = Semi Local).
    static let mode = "Feather.serverMethod"
    static let allowLocalNetwork = "ShrubSign.allowLocalNetworkInstall"
    static let customManifestURL = "ShrubSign.customManifestURL"
    static let migrationV2 = "ShrubSign.installModeV2"
}

// MARK: - Modes
enum ShrubInstallMode: Int, CaseIterable, Identifiable {
    /// Uses Fully Local when the trust profile is installed, otherwise Semi Local.
    case automatic = 2
    case fullyLocal = 0
    case localServer = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .fullyLocal: return "Fully Local"
        case .localServer: return "Semi Local"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic:
            return "Installs with Semi Local first, then falls back to Fully Local when the local profile is trusted."
        case .fullyLocal:
            return "The manifest and the IPA are served from this device over trusted HTTPS. Works offline."
        case .localServer:
            return "The IPA stays on this device; the install manifest comes from an online HTTPS helper."
        }
    }

    var footnote: String {
        switch self {
        case .automatic: return "Recommended"
        case .fullyLocal: return "One-time trust profile"
        case .localServer: return "Needs internet"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: return "wand.and.stars"
        case .fullyLocal: return "lock.shield.fill"
        case .localServer: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - Errors
enum ShrubInstallError: LocalizedError {
    case missingPackage
    case missingBundleIdentifier
    case localServerUnavailable
    case secureServerUnavailable
    case profileMissing
    case trustRequired
    case manifestUnavailable(String)
    case invalidManifest(String)
    case invalidPage

    var errorDescription: String? {
        switch self {
        case .missingPackage:
            return "The signed IPA is missing. Sign or import the app again before installing."
        case .missingBundleIdentifier:
            return "This app has no bundle identifier, so iOS cannot install it. Sign the app again."
        case .localServerUnavailable:
            return "The local install server could not start. Try again, or switch Installation Type."
        case .secureServerUnavailable:
            return "The local HTTPS server could not start. Regenerate the local certificate in Settings → Installation."
        case .profileMissing:
            return "No local trust profile exists yet. Tap “Install Local Profile” first."
        case .trustRequired:
            return "Fully Local needs the ShrubSign trust profile. Tap “Install Local Profile”, then turn it on in Settings → General → About → Certificate Trust Settings."
        case .manifestUnavailable(let detail):
            return "The install manifest could not be loaded. \(detail)"
        case .invalidManifest(let detail):
            return "The install manifest was rejected. \(detail)"
        case .invalidPage:
            return "The local install page could not be opened."
        }
    }
}

// MARK: - Sheets
struct ShrubSheetURL: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Manifest providers
struct ShrubManifestResolution {
    let url: URL
    let providerName: String
    let isLocal: Bool
}

struct ShrubManifestProvider: Identifiable {
    let id: String
    let name: String
    let detail: String

    /// Builds the HTTPS manifest URL for a provider. The manifest itself points
    /// back at the payload served by this device.
    func manifestURL(
        bundleID: String,
        name: String,
        version: String,
        payload: URL,
        port: Int
    ) -> URL? {
        switch id {
        case "otame":
            // SignTools ota-me publishes one static HTTPS manifest per port and
            // serves the package from http://127.0.0.1:<port>/ota-me.
            guard port > 0, port <= 10_000 else { return nil }
            return URL(string: "https://signtools.github.io/ota-me/data/\(port)")
        default:
            guard var components = URLComponents(string: detail) else { return nil }
            var items = components.queryItems ?? []
            items.append(contentsOf: [
                URLQueryItem(name: "bundleid", value: bundleID),
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "version", value: version),
                URLQueryItem(name: "fetchurl", value: payload.absoluteString)
            ])
            components.queryItems = items
            return components.url
        }
    }
}

enum ShrubManifestProviders {
    /// Ordered best first. Each candidate is validated against the manifest the
    /// system installer would fetch before ShrubSign hands the link to iOS.
    static var all: [ShrubManifestProvider] {
        var providers: [ShrubManifestProvider] = [
            ShrubManifestProvider(
                id: "otame",
                name: "SignTools ota-me",
                detail: "Static HTTPS manifest hosted on GitHub Pages"
            ),
            ShrubManifestProvider(
                id: "palera",
                name: "Palera plist service",
                detail: "https://api.palera.in/genPlist"
            )
        ]

        let custom = UserDefaults.standard.string(forKey: ShrubInstallKey.customManifestURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty, URL(string: custom)?.host != nil {
            providers.insert(
                ShrubManifestProvider(
                    id: "custom",
                    name: "Custom manifest server",
                    detail: custom
                ),
                at: 0
            )
        }

        return providers
    }
}
