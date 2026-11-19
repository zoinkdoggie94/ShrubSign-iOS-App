//
//  ServerInstaller.swift
//  ShrubSign
//
//  Originally created by samara on 22.08.2024 for feather.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR SHRUBSIGN
//
//  ShrubSign 3.2.2 rework:
//  • Always starts an HTTP listener for the install page and the local payload.
//  • Additionally starts an HTTPS listener whenever device certificates exist,
//    so Fully Local can serve its own manifest instead of relying on an
//    external service that may be offline.
//  • Validates the exact manifest iOS is about to fetch and reports why it
//    failed, instead of handing over a link that silently does nothing.
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
    let id = UUID()

    /// Plain HTTP listener: install page, trust profile, and the local payload
    /// used by Semi Local installs.
    private(set) var port = 0
    /// HTTPS listener: manifest and payload used by Fully Local installs.
    private(set) var securePort = 0
    private(set) var isSecureServerRunning = false

    private var _needsShutdown = false
    private var _server: Application?
    private var _secureServer: Application?

    var packageUrl: URL?
    var app: AppInfoPresentable
    @ObservedObject var viewModel: InstallerStatusViewModel

    /// The manifest URL ShrubSign decided to hand to iOS.
    @Published private(set) var activeManifestURL: URL?
    @Published private(set) var activeProviderName: String?

    // iOS may dismiss the installation view while itms-services is fetching
    // the manifest and IPA. Hold a bounded reference so SwiftUI view teardown
    // does not destroy the server during that handoff.
    private static let activeInstallLock = NSLock()
    private static var activeInstallers: [UUID: ServerInstaller] = [:]

    // MARK: - Mode
    static var mode: ShrubInstallMode {
        get {
            let raw = UserDefaults.standard.object(forKey: ShrubInstallKey.mode) as? Int
            guard let raw, let mode = ShrubInstallMode(rawValue: raw) else { return .automatic }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ShrubInstallKey.mode) }
    }

    /// The mode that will actually be used for the next install.
    static func resolvedMode() -> ShrubInstallMode {
        switch mode {
        case .fullyLocal, .localServer:
            return mode
        case .automatic:
            return (PersonalSSL.hasCredentials && PersonalSSL.isTrusted()) ? .fullyLocal : .localServer
        }
    }

    /// Kept for callers that still read the raw value.
    static func getServerMethod() -> Int { mode.rawValue }

    static func setServerMethod(_ method: Int) {
        mode = ShrubInstallMode(rawValue: method) ?? .automatic
    }

    static func allowLocalNetworkInstall() -> Bool {
        UserDefaults.standard.bool(forKey: ShrubInstallKey.allowLocalNetwork)
    }

    // MARK: - Lifecycle
    init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
        self.app = app
        self.viewModel = viewModel

        var httpError: Error?
        for _ in 0..<6 {
            let candidate = Int.random(in: 4000...8000)
            do {
                let server = try Self.setupApp(port: candidate, secure: false)
                self._server = server
                try _configureRoutes(server, secure: false)
                try server.server.start()
                self.port = candidate
                self._needsShutdown = true
                break
            } catch {
                httpError = error
                if let server = self._server {
                    server.server.shutdown()
                    server.shutdown()
                }
                self._server = nil
            }
        }

        // Fully Local needs TLS. Start it whenever credentials exist so the
        // manifest is ready even if the user switches modes later.
        if (try? Self.tls()) != nil {
            for _ in 0..<6 {
                var candidate = Int.random(in: 4000...8000)
                if candidate == port { candidate += 1 }
                do {
                    let server = try Self.setupApp(port: candidate, secure: true)
                    self._secureServer = server
                    try _configureRoutes(server, secure: true)
                    try server.server.start()
                    self.securePort = candidate
                    self.isSecureServerRunning = true
                    break
                } catch {
                    if let server = self._secureServer {
                        server.server.shutdown()
                        server.shutdown()
                    }
                    self._secureServer = nil
                    self.isSecureServerRunning = false
                }
            }
        }

        if port == 0 {
            let error = httpError ?? ShrubInstallError.localServerUnavailable
            DispatchQueue.main.async {
                viewModel.status = .broken(error)
            }
        }
    }

    deinit {
        _shutdownServers()
    }

    private func _shutdownServers() {
        guard _needsShutdown else { return }
        _needsShutdown = false
        _server?.server.shutdown()
        _server?.shutdown()
        _server = nil
        _secureServer?.server.shutdown()
        _secureServer?.shutdown()
        _secureServer = nil
    }

    // MARK: - Keep alive
    func keepServerAliveDuringInstall() {
        ServerInstaller.activeInstallLock.lock()
        ServerInstaller.activeInstallers[id] = self
        ServerInstaller.activeInstallLock.unlock()

        // Prevent unbounded retained servers. Expiry is a fallback for installs
        // where iOS never reports success or failure to the application.
        let installID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 900) {
            Self.releaseInstallation(installID)
        }
    }

    func stopKeepingAlive() {
        Self.releaseInstallation(id)
    }

    static func releaseInstallation(_ installID: UUID) {
        ServerInstaller.activeInstallLock.lock()
        let released = ServerInstaller.activeInstallers.removeValue(forKey: installID)
        ServerInstaller.activeInstallLock.unlock()
        _ = released
    }

    // MARK: - Hand-off
    /// Prepares the manifest iOS will fetch and returns the local page that
    /// triggers itms-services. Throws a readable error instead of failing
    /// silently inside the system installer.
    @MainActor
    func prepareInstallHandoff() async throws -> URL {
        guard let fileURL = packageUrl,
              fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ShrubInstallError.missingPackage
        }

        let bundleID = (app.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !bundleID.hasPrefix("com.shrubsign.unknown") else {
            throw ShrubInstallError.missingBundleIdentifier
        }

        activeManifestURL = nil
        activeProviderName = nil

        switch Self.resolvedMode() {
        case .fullyLocal:
            try await _prepareFullyLocal()
        case .localServer, .automatic:
            try await _prepareLocalServer(bundleID: bundleID)
        }

        guard let page = installPageURL else { throw ShrubInstallError.invalidPage }
        return page
    }

    private func _prepareFullyLocal() async throws {
        guard port > 0 else { throw ShrubInstallError.localServerUnavailable }
        guard PersonalSSL.hasCredentials else { throw ShrubInstallError.profileMissing }
        guard isSecureServerRunning, securePort > 0 else {
            throw ShrubInstallError.secureServerUnavailable
        }
        guard PersonalSSL.isTrusted() else { throw ShrubInstallError.trustRequired }

        let url = manifestURL(secure: true)
        try await Self.validateManifest(at: url)
        activeManifestURL = url
        activeProviderName = "This device (HTTPS)"
    }

    private func _prepareLocalServer(bundleID: String) async throws {
        guard port > 0 else { throw ShrubInstallError.localServerUnavailable }

        let payload = payloadURL(secure: false)
        let displayName = app.name?.isEmpty == false ? (app.name ?? "ShrubSign App") : "ShrubSign App"
        let version = app.version?.isEmpty == false ? (app.version ?? "1.0") : "1.0"

        var failures: [String] = []
        for provider in ShrubManifestProviders.all {
            guard let url = provider.manifestURL(
                bundleID: bundleID,
                name: displayName,
                version: version,
                payload: payload,
                port: port
            ) else {
                failures.append("\(provider.name): unavailable for port \(port)")
                continue
            }
            do {
                try await Self.validateManifest(at: url)
                activeManifestURL = url
                activeProviderName = provider.name
                return
            } catch {
                failures.append("\(provider.name): \(error.localizedDescription)")
            }
        }

        throw ShrubInstallError.manifestUnavailable(
            "No online manifest helper answered. " + failures.joined(separator: " · ")
            + " Install the local trust profile to use Fully Local instead."
        )
    }

    /// Fetches the manifest exactly the way the system installer will and
    /// verifies that it describes a software package.
    static func validateManifest(at url: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.setValue("1", forHTTPHeaderField: "X-ShrubSign-Preflight")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw ShrubInstallError.manifestUnavailable(
                    "\(url.host ?? "The manifest server") returned HTTP \(status)."
                )
            }
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard
                let dictionary = plist as? [String: Any],
                let items = dictionary["items"] as? [[String: Any]],
                !items.isEmpty,
                let assets = items[0]["assets"] as? [[String: Any]],
                assets.contains(where: { ($0["kind"] as? String) == "software-package" })
            else {
                throw ShrubInstallError.invalidManifest(
                    "\(url.host ?? "The manifest server") did not return a valid installation manifest."
                )
            }
        } catch let error as ShrubInstallError {
            throw error
        } catch {
            throw ShrubInstallError.manifestUnavailable(
                "\(url.host ?? "The manifest server"): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Routes
    private func _configureRoutes(_ server: Application, secure: Bool) throws {
        server.get("*") { [weak self] req in
            guard let self else { return Response(status: .badGateway) }
            switch req.url.path {
            case "/manifest.plist", "/\(self.id).plist":
                // A local preflight request must not masquerade as iOS
                // starting the installation.
                if req.headers.first(name: "X-ShrubSign-Preflight") != "1" {
                    self._updateStatus(.sendingManifest)
                }
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "text/xml",
                    "Cache-Control": "no-store"
                ], body: .init(data: self._manifestData(secure: secure)))

            case "/payload.ipa", "/\(self.id).ipa", "/ota-me":
                guard let packageUrl = self.packageUrl else {
                    return Response(status: .notFound)
                }
                self._updateStatus(.sendingPayload)
                return req.fileio.streamFile(at: packageUrl.path) { result in
                    switch result {
                    case .success:
                        self._updateStatus(.installing)
                    case .failure(let error):
                        self._updateStatus(.broken(error))
                    }
                }

            case "/app57x57.png":
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "no-store"
                ], body: .init(data: self._icon(57, secure: secure)))

            case "/app512x512.png":
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "no-store"
                ], body: .init(data: self._icon(512, secure: secure)))

            case "/install":
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Cache-Control": "no-store"
                ], body: .init(string: self._installPage))

            case "/trust.mobileconfig":
                guard let url = PersonalSSL.profileURL,
                      let data = try? Data(contentsOf: url) else {
                    return Response(status: .notFound)
                }
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "application/x-apple-aspen-config",
                    "Content-Disposition": "attachment; filename=\"ShrubSign-Local-Trust.mobileconfig\"",
                    "Cache-Control": "no-store"
                ], body: .init(data: data))

            case "/health":
                let text = """
                ok
                httpPort=\(self.port)
                httpsPort=\(self.securePort)
                https=\(self.isSecureServerRunning)
                provider=\(self.activeProviderName ?? "none")
                """
                return Response(status: .ok, headers: ["Content-Type": "text/plain; charset=utf-8"],
                                body: .init(string: text))

            default:
                return Response(status: .notFound)
            }
        }
    }

    private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
        DispatchQueue.main.async {
            self.viewModel.status = newStatus
        }
    }

}
