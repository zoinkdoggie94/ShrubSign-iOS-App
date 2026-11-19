//
//  ServerInstaller+Compute.swift
//  ShrubSign
//
//  Originally created by samara on 22.08.2024 for feather.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR SHRUBSIGN
//
//  Manifest, icon, and install page generation. Everything the system
//  installer needs is produced locally in 3.2.2; only Semi Local's manifest URL
//  comes from an external HTTPS helper.
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
    // MARK: - Endpoints
    func _endpoint(_ path: String, secure: Bool, host: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = host ?? (secure ? Self.sni : Self.localHost)
        components.port = secure ? securePort : port
        components.path = path
        return components.url ?? URL(string: "http://127.0.0.1")!
    }

    func payloadURL(secure: Bool) -> URL {
        _endpoint("/payload.ipa", secure: secure)
    }

    func manifestURL(secure: Bool) -> URL {
        _endpoint("/manifest.plist", secure: secure)
    }

    func iconURL(size: Int, secure: Bool) -> URL {
        _endpoint(size <= 64 ? "/app57x57.png" : "/app512x512.png", secure: secure)
    }

    /// The page Safari opens. It immediately redirects to itms-services, which
    /// is required on iOS 18+ where a direct open from a third-party app is
    /// ignored without additional entitlements.
    var installPageURL: URL? {
        guard port > 0 else { return nil }
        return _endpoint("/install", secure: false, host: "127.0.0.1")
    }

    /// A manifest URL that can be used before a hand-off has been prepared.
    var _fallbackManifestURL: URL? {
        let provider = ShrubManifestProviders.all.first
        let bundleID = app.identifier ?? "com.shrubsign.unknown"
        let name = app.name ?? "ShrubSign App"
        let version = app.version ?? "1.0"
        return provider?.manifestURL(
            bundleID: bundleID,
            name: name,
            version: version,
            payload: payloadURL(secure: false),
            port: port
        )
    }

    // MARK: - itms-services
    static func iTunesLink(_ urlString: String) -> String {
        guard !urlString.isEmpty else {
            return "itms-services://?action=download-manifest"
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+?=")
        let encoded = urlString.addingPercentEncoding(withAllowedCharacters: allowed) ?? urlString
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    var handoffLink: String {
        Self.iTunesLink((activeManifestURL ?? _fallbackManifestURL)?.absoluteString ?? "")
    }

    static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Page
    var _installPage: String {
        let displayName = Self.escapeHTML(app.name ?? "your app")
        let provider = Self.escapeHTML(activeProviderName ?? "Automatic")
        let link = handoffLink
        let href = Self.escapeHTML(link)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>ShrubSign Install</title>
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
            margin: 0; min-height: 100vh; display: flex; align-items: center;
            justify-content: center; padding: 28px;
            font: -apple-system-body;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            background: #0b0d0c; color: #f4f7f4;
        }
        .card {
            width: 100%; max-width: 420px; padding: 26px; border-radius: 24px;
            background: linear-gradient(160deg, rgba(114,232,148,0.20), rgba(114,232,148,0.04));
            border: 1px solid rgba(114,232,148,0.28);
            text-align: center;
        }
        h1 { font-size: 21px; margin: 0 0 10px; letter-spacing: -0.02em; }
        p { font-size: 15px; line-height: 1.45; margin: 8px 0; color: #d7ded9; }
        a {
            display: inline-block; margin-top: 14px; padding: 13px 24px; border-radius: 14px;
            background: #72e894; color: #06230f; font-weight: 700; text-decoration: none;
        }
        .hint { font-size: 12.5px; color: #9aa59e; margin-top: 16px; }
        </style>
        </head>
        <body>
        <div class="card">
            <h1>Installing \(displayName)</h1>
            <p>ShrubSign is handing this app to iOS.</p>
            <a id="manual" href="\(href)">Install now</a>
            <p class="hint">If the installer does not appear, tap the button above.</p>
            <p class="hint">Keep ShrubSign open until the installation starts · \(provider)</p>
        </div>
        <script>
        var target = "\(link)";
        function go() { try { window.location.replace(target); } catch (error) {} }
        document.getElementById('manual').addEventListener('click', function (event) {
            event.preventDefault();
            go();
        });
        go();
        setTimeout(go, 1500);
        setTimeout(go, 4000);
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Manifest
    func _manifest(secure: Bool) -> [String: Any] {
        let bundleID = app.identifier ?? "com.shrubsign.unknown"
        let version = app.version ?? "1.0"
        let title = app.name ?? "ShrubSign App"

        let assets: [[String: String]] = [
            [
                "kind": "software-package",
                "url": payloadURL(secure: secure).absoluteString
            ],
            [
                "kind": "display-image",
                "url": iconURL(size: 57, secure: secure).absoluteString
            ],
            [
                "kind": "full-size-image",
                "url": iconURL(size: 512, secure: secure).absoluteString
            ]
        ]

        let metadata: [String: String] = [
            "bundle-identifier": bundleID,
            "bundle-version": version,
            "kind": "software",
            "title": title
        ]

        let item: [String: Any] = [
            "assets": assets,
            "metadata": metadata
        ]

        return ["items": [item]]
    }

    func _manifestData(secure: Bool) -> Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: _manifest(secure: secure),
            format: .xml,
            options: .zero
        )) ?? Data()
    }

    // MARK: - Icons
    func _icon(_ radius: CGFloat, secure: Bool) -> Data {
        let renderer = UIGraphicsImageRenderer(size: .init(width: radius, height: radius))
        let image = renderer.image { context in
            UIColor.accent.setFill()
            context.fill(.init(x: 0, y: 0, width: radius, height: radius))
        }
        return image.pngData() ?? Data()
    }
}
