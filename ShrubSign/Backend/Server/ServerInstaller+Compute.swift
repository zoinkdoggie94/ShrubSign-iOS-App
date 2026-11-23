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
    /// Safari cannot be force-closed by an external app. Make one install
    /// request per attempt and offer an explicit way back to ShrubSign.
    var _installPage: String {
        let displayName = Self.escapeHTML(app.name ?? "your app")
        let provider = Self.escapeHTML(activeProviderName ?? "Automatic")
        let href = Self.escapeHTML(handoffLink)
        let attemptKey = "shrubsign-install-\(id.uuidString)"
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="dark">
        <title>ShrubSign · Install \(displayName)</title>
        <style>
          :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
          * { box-sizing: border-box; }
          body { margin: 0; min-height: 100dvh; padding: max(22px, env(safe-area-inset-top)) 22px max(22px, env(safe-area-inset-bottom));
                 background: #0e1210; color: #eef4ef; display: grid; place-items: center; }
          main { width: min(100%, 410px); }
          .brand { display: flex; align-items: center; gap: 10px; margin-bottom: 20px;
                   font-weight: 750; font-size: 12px; letter-spacing: .12em; color: #b7c7bb; }
          .mark { width: 30px; height: 30px; background: #254431; border-radius: 9px; color: #98f0b2;
                  display: grid; place-items: center; font-size: 19px; }
          section { padding: 25px 23px; background: #19211c; border: 1px solid #2e3b32; border-radius: 22px; }
          .eyebrow { font-size: 12px; font-weight: 700; color: #9fe8b1; letter-spacing: .05em; text-transform: uppercase; }
          h1 { margin: 9px 0 12px; font-size: clamp(22px, 6vw, 27px); line-height: 1.18; letter-spacing: -.035em;
               overflow-wrap: anywhere; }
          p { color: #bbcbc0; font-size: 14px; line-height: 1.55; margin: 0; }
          .steps { display: grid; gap: 13px; margin: 19px 0; padding: 17px 0;
                   border-top: 1px solid #2e3b32; border-bottom: 1px solid #2e3b32; }
          .step { display: flex; gap: 12px; font-size: 14px; align-items: flex-start; color: #dfebe2; }
          .number { flex: 0 0 23px; height: 23px; border-radius: 50%; display: grid; place-items: center;
                    background: #2e4837; color: #a1ebb3; font-size: 12px; font-weight: 700; }
          a { text-decoration: none; }
          .action { display: block; padding: 14px; text-align: center; border-radius: 12px;
                    background: #90e6a6; color: #12291b; font-size: 15px; font-weight: 750; }
          .action.disabled { pointer-events: none; color: #b4c2b8; background: #384a3e; }
          .return { display: block; padding: 10px; margin-top: 10px; text-align: center;
                    color: #bce9c7; font-size: 14px; font-weight: 600; }
          #status { min-height: 47px; margin: 13px 0 0; font-size: 13px; }
          footer { color: #899a8e; font-size: 12px; text-align: center; line-height: 1.5; margin-top: 17px; }
        </style>
        </head>
        <body>
          <main>
            <div class="brand"><span class="mark">✳</span> SHRUBSIGN</div>
            <section>
              <div class="eyebrow">Ready to install</div>
              <h1>\(displayName)</h1>
              <p>Approve the iOS installation prompt to install your signed IPA.</p>
              <div class="steps">
                <div class="step"><span class="number">1</span><span>Tap “Open in iTunes” if asked.</span></div>
                <div class="step"><span class="number">2</span><span>Confirm “Install” in the system prompt.</span></div>
                <div class="step"><span class="number">3</span><span>Return to ShrubSign for progress.</span></div>
              </div>
              <a id="manual" class="action" href="\(href)">Request installation</a>
              <p id="status" role="status" aria-live="polite">Preparing a single install request…</p>
              <a class="return" href="shrubsign://install-return">Return to ShrubSign</a>
            </section>
            <footer>\(provider) · Keep ShrubSign available until the IPA transfer completes.</footer>
          </main>
          <script>
          (function () {
            'use strict';
            const key = '\(attemptKey)';
            const button = document.getElementById('manual');
            const status = document.getElementById('status');
            let sent = false;
            try { sent = sessionStorage.getItem(key) === 'sent'; } catch (_) {}
            function render() {
              if (sent) {
                button.classList.add('disabled');
                button.setAttribute('aria-disabled', 'true');
                button.textContent = 'Install request sent';
                status.textContent = 'Check the iOS prompt. If it did not appear, return to ShrubSign and tap Try again.';
              }
            }
            function requestOnce(event) {
              if (event) event.preventDefault();
              if (sent) return;
              sent = true;
              try { sessionStorage.setItem(key, 'sent'); } catch (_) {}
              render();
              window.location.replace(button.href);
            }
            button.addEventListener('click', requestOnce);
            render();
            if (!sent) setTimeout(requestOnce, 350);
          }());
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
