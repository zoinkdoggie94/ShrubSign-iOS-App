//
//  ServerInstaller+Compute.swift
//  ShrubSign
//
//  Originally created by samara on 22.08.2024 for Feather.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR SHRUBSIGN
//

import Foundation

extension ServerInstaller {
    func _endpoint(_ path: String, secure: Bool, token: UUID, host: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = host ?? (secure ? PersonalSSL.host : Self.localHost)
        components.port = secure ? securePort : port
        components.path = path
        components.queryItems = [URLQueryItem(name: "attempt", value: token.uuidString)]
        // The host is loopback or a numeric IPv4 address from getLocalAddress().
        return components.url!
    }

    func payloadURL(secure: Bool, token: UUID) -> URL {
        _endpoint("/payload.ipa", secure: secure, token: token)
    }

    func manifestURL(secure: Bool, token: UUID) -> URL {
        _endpoint("/manifest.plist", secure: secure, token: token)
    }

    static func iTunesLink(_ urlString: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "%#&+?=")
        let encoded = urlString.addingPercentEncoding(withAllowedCharacters: allowed) ?? urlString
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func _installPage(manifest: URL, token: UUID) -> String {
        let displayName = Self.escapeHTML(app.name ?? "Signed app")
        let href = Self.escapeHTML(Self.iTunesLink(manifest.absoluteString))
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <title>Install \(displayName) · ShrubSign</title>
        <style>
          :root {
            color-scheme: light dark;
            --surface: #f1f6f2; --card: #fff; --ink: #13261c; --muted: #4b6053;
            --line: #d7e4da; --accent: #176344; --on-accent: #fff;
            font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --surface: #111b16; --card: #1b2a22; --ink: #edf7ef; --muted: #bbcbbf;
              --line: #3a5143; --accent: #a3e7bb; --on-accent: #102b1d;
            }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0; min-height: 100vh; min-height: 100dvh; display: grid; place-items: center;
            padding: max(1rem, env(safe-area-inset-top)) max(1rem, env(safe-area-inset-right))
                     max(1rem, env(safe-area-inset-bottom)) max(1rem, env(safe-area-inset-left));
            background: var(--surface); color: var(--ink);
          }
          main {
            width: min(100%, 28rem); padding: clamp(1rem, 6vw, 2rem);
            background: var(--card); border: 1px solid var(--line); border-radius: 1.5rem;
          }
          header { color: var(--accent); font-weight: 700; }
          h1 { margin: .625rem 0 .75rem; font-size: clamp(1.625rem, 6vw, 2.25rem);
               line-height: 1.16; overflow-wrap: anywhere; }
          p { color: var(--muted); line-height: 1.55; margin: 0 0 1.25rem; }
          nav { display: grid; gap: .625rem; }
          a {
            display: flex; align-items: center; justify-content: center;
            min-height: 2.875rem; padding: .625rem 1rem; text-align: center;
            border-radius: .75rem; color: var(--accent); font-weight: 650;
          }
          a[hidden] { display: none; }
          a.primary { background: var(--accent); color: var(--on-accent); text-decoration: none; }
          a[aria-disabled="true"] { background: var(--surface); color: var(--muted); }
          a:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
        </style>
        </head>
        <body>
          <main>
            <header>ShrubSign</header>
            <h1>Install \(displayName)</h1>
            <p id="status" role="status">Tap Install, then confirm the prompt from iOS.</p>
            <nav aria-label="Installation actions">
              <a id="install" class="primary" href="\(href)">Install</a>
              <a id="return" href="shrubsign://install-return">Back to ShrubSign</a>
            </nav>
          </main>
          <script>
          (() => {
            const key = 'shrubsign-install-\(token.uuidString)';
            const install = document.getElementById('install');
            const back = document.getElementById('return');
            const status = document.getElementById('status');
            const inApp = location.hash === '#in-app';
            const stateURL = '/install-status' + location.search;
            back.hidden = inApp;
            let sent = false;
            let returned = false;
            try {
              sent = sessionStorage.getItem(key) !== null;
              returned = sessionStorage.getItem(key) === 'returned';
            } catch (_) {}

            function sentState() {
              install.setAttribute('aria-disabled', 'true');
              install.textContent = 'Install requested';
              status.textContent = inApp
                ? 'Confirm the iOS prompt. If it does not appear, close this sheet and tap Open in Safari.'
                : 'Confirm the iOS prompt. If it does not appear, return to ShrubSign to retry.';
            }
            function fetchingState() {
              status.textContent = 'iOS is downloading the app. You can return to ShrubSign.';
            }
            function returnToApp() {
              returned = true;
              try { sessionStorage.setItem(key, 'returned'); } catch (_) {}
              // Browsers only allow script-opened tabs to close themselves.
              if (window.opener) setTimeout(() => window.close(), 800);
            }
            async function checkDownload() {
              try {
                const response = await fetch(stateURL, { cache: 'no-store' });
                if (response.status === 404) {
                  status.textContent = 'This install attempt expired. Return to ShrubSign to retry.';
                  return;
                }
                if (response.ok && await response.text() === 'fetching') {
                  fetchingState();
                  if (!returned && document.visibilityState === 'visible') {
                    returnToApp();
                    location.href = back.href;
                  }
                  return;
                }
              } catch (_) {}
              if (!returned) setTimeout(checkDownload, 1500);
            }

            back.addEventListener('click', returnToApp);
            install.addEventListener('click', event => {
              if (sent) {
                event.preventDefault();
                return;
              }
              sent = true;
              try { sessionStorage.setItem(key, 'sent'); } catch (_) {}
              sentState();
              if (!inApp) setTimeout(checkDownload, 1500);
            });
            if (sent) {
              sentState();
              if (!inApp) checkDownload();
            }
            document.addEventListener('visibilitychange', () => {
              if (!inApp && sent && !returned && document.visibilityState === 'visible') checkDownload();
            });
          })();
          </script>
        </body>
        </html>
        """
    }

    var manifestBuildVersion: String {
        [buildVersion, app.version].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "1.0"
    }

    func _manifestData(token: UUID) -> Data {
        let package = ["kind": "software-package", "url": payloadURL(secure: true, token: token).absoluteString]
        let metadata = [
            "bundle-identifier": (app.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "bundle-version": manifestBuildVersion,
            "kind": "software",
            "title": app.name?.isEmpty == false ? (app.name ?? "ShrubSign App") : "ShrubSign App"
        ]
        let manifest = ["items": [["assets": [package], "metadata": metadata]]]
        return (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)) ?? Data()
    }
}
