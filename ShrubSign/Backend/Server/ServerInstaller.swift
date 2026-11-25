//
//  ServerInstaller.swift
//  ShrubSign
//
//  Originally created by samara on 22.08.2024 for feather.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR SHRUBSIGN
//

import Foundation
import Vapor
import NIOSSL
import Combine
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
    let id = UUID()

    /// Plain HTTP listener: install page, trust profile, and the local payload
    /// used by Semi Local installs.
    private(set) var port = 0
    private(set) var securePort = 0
    private var _server: Application?
    private var _secureServer: Application?

    var packageUrl: URL?
    let app: AppInfoPresentable
    let viewModel: InstallerStatusViewModel
    var buildVersion: String?

    private struct Attempt {
        let id: UUID
        let package: URL
        var html: String?
        var payloadRequested = false
    }
    private let _attemptLock = NSLock()
    private var _attempt: Attempt?
    private var _releaseTask: DispatchWorkItem?
    @MainActor private static var activeInstallers: [UUID: ServerInstaller] = [:]

    // MARK: - Mode
    static var mode: ShrubInstallMode {
        get {
            let raw = UserDefaults.standard.object(forKey: ShrubInstallKey.mode) as? Int
            guard let raw, let mode = ShrubInstallMode(rawValue: raw) else { return .automatic }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ShrubInstallKey.mode) }
    }

    /// The mode that will actually be used first for the next install.
    static func resolvedMode() -> ShrubInstallMode {
        switch mode {
        case .fullyLocal, .localServer:
            return mode
        case .automatic:
            // Automatic starts with Semi Local because it only needs internet.
            // Fully Local is attempted afterwards when the local profile is
            // installed and trusted, so a bad trust setup cannot break installs.
            return .localServer
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
    }

    deinit {
        // A request callback can hold the final reference to the installer.
        // Blocking server shutdown must not run on that request's event loop.
        let servers = [_server, _secureServer].compactMap { $0 }
        let directory = packageUrl?.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async {
            for server in servers {
                server.server.shutdown()
                server.shutdown()
            }
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private func _startServer(secure: Bool) throws -> (Application, Int) {
        let tls = secure ? try Self.tls() : nil
        if secure, tls == nil { throw ShrubInstallError.secureServerUnavailable }
        var lastError: Error?
        for _ in 0..<6 {
            let port = Int.random(in: 4000...8000)
            let server = Self.setupApp(port: port, tls: tls, loopbackOnly: secure)
            _configureRoutes(server, secure: secure)
            do {
                try server.server.start()
                return (server, port)
            } catch {
                server.shutdown()
                lastError = error
            }
        }
        throw lastError ?? ShrubInstallError.localServerUnavailable
    }

    // MARK: - Keep alive
    @MainActor
    func keepServerAliveDuringInstall(for delay: TimeInterval = 900) {
        _releaseTask?.cancel()
        Self.activeInstallers[id] = self
        let installID = id
        let release = DispatchWorkItem {
            Self.activeInstallers.removeValue(forKey: installID)
        }
        _releaseTask = release
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: release)
    }

    @MainActor
    func stopKeepingAlive() {
        _releaseTask?.cancel()
        _releaseTask = nil
        Self.activeInstallers.removeValue(forKey: id)
    }

    // MARK: - Hand-off
    @MainActor
    func prepareInstallHandoff(mode: ShrubInstallMode) async throws -> URL {
        guard let fileURL = packageUrl,
              fileURL.isFileURL,
              FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw ShrubInstallError.missingPackage
        }
        let bundleID = (app.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !bundleID.hasPrefix("com.shrubsign.unknown") else {
            throw ShrubInstallError.missingBundleIdentifier
        }

        if _server == nil {
            let (server, listenPort) = try _startServer(secure: false)
            _server = server
            port = listenPort
        }

        let token = UUID()
        _setAttempt(Attempt(id: token, package: fileURL))
        let manifest: URL
        switch mode {
        case .fullyLocal:
            manifest = try await _prepareFullyLocal(bundleID: bundleID, token: token)
        case .localServer:
            manifest = try await _prepareLocalServer(bundleID: bundleID, token: token)
        case .automatic:
            do {
                manifest = try await _prepareLocalServer(bundleID: bundleID, token: token)
            } catch {
                try Task.checkCancellation()
                guard PersonalSSL.isTrusted() else { throw error }
                manifest = try await _prepareFullyLocal(bundleID: bundleID, token: token)
            }
        }
        try Task.checkCancellation()
        let page = _endpoint("/install", secure: false, token: token, host: PersonalSSL.host)
        _setAttempt(Attempt(id: token, package: fileURL, html: _installPage(manifest: manifest, token: token)))
        return page
    }

    @MainActor
    private func _prepareFullyLocal(bundleID: String, token: UUID) async throws -> URL {
        guard PersonalSSL.hasDeviceLocalIdentity else { throw ShrubInstallError.profileMissing }
        guard PersonalSSL.isTrusted() else { throw ShrubInstallError.trustRequired }
        // The trust profile may have been created or renewed while this installer
        // was open. Load the current identity before each Fully Local hand-off.
        if let server = _secureServer {
            _secureServer = nil
            securePort = 0
            await server.server.shutdown()
            try await server.asyncShutdown()
        }
        let (server, listenPort) = try _startServer(secure: true)
        _secureServer = server
        securePort = listenPort
        let url = manifestURL(secure: true, token: token)
        try await Self.validateManifest(at: url, expectedBundleID: bundleID,
                                        expectedPayload: payloadURL(secure: true, token: token),
                                        expectedVersion: manifestBuildVersion)
        return url
    }

    @MainActor
    private func _prepareLocalServer(bundleID: String, token: UUID) async throws -> URL {
        let payload = payloadURL(secure: false, token: token)
        let displayName = app.name?.isEmpty == false ? (app.name ?? "ShrubSign App") : "ShrubSign App"
        let version = manifestBuildVersion

        var failures: [String] = []
        for provider in ShrubManifestProviders.all {
            guard let url = provider.manifestURL(
                bundleID: bundleID, name: displayName, version: version, payload: payload, port: port
            ) else { continue }
            do {
                try await Self.validateManifest(at: url, expectedBundleID: bundleID,
                                                expectedPayload: payload, expectedVersion: version)
                return url
            } catch {
                try Task.checkCancellation()
                failures.append("\(provider.name): \(error.localizedDescription)")
            }
        }

        throw ShrubInstallError.manifestUnavailable(
            "No online manifest helper returned a usable manifest. " + failures.joined(separator: " · ")
            + " Set up the local trust profile to use Fully Local."
        )
    }

    /// Fetches the manifest exactly the way the system installer will and
    /// verifies that it describes a software package.
    static func validateManifest(
        at url: URL, expectedBundleID: String, expectedPayload: URL, expectedVersion: String
    ) async throws {
        guard url.scheme?.lowercased() == "https" else {
            throw ShrubInstallError.invalidManifest("The manifest URL must use HTTPS.")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, response.url?.scheme?.lowercased() == "https" else {
                throw ShrubInstallError.manifestUnavailable(
                    "\(url.host ?? "The manifest server") must return HTTP 200 over HTTPS (received \(status))."
                )
            }
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard
                let dictionary = plist as? [String: Any],
                let items = dictionary["items"] as? [[String: Any]],
                items.count == 1,
                let assets = items[0]["assets"] as? [[String: Any]],
                let package = assets.first(where: { ($0["kind"] as? String) == "software-package" }),
                let address = package["url"] as? String, URL(string: address) == expectedPayload,
                let metadata = items[0]["metadata"] as? [String: Any],
                metadata["bundle-identifier"] as? String == expectedBundleID,
                metadata["kind"] as? String == "software",
                metadata["bundle-version"] as? String == expectedVersion,
                let title = metadata["title"] as? String, !title.isEmpty
            else {
                throw ShrubInstallError.invalidManifest(
                    "\(url.host ?? "The manifest server") did not describe the signed app and its local download URL."
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
    func invalidateAttempt() {
        _setAttempt(nil)
    }

    private func _setAttempt(_ attempt: Attempt?) {
        _attemptLock.lock()
        defer { _attemptLock.unlock() }
        _attempt = attempt
    }

    private func _currentAttempt(_ token: UUID) -> Attempt? {
        _attemptLock.lock()
        defer { _attemptLock.unlock() }
        guard _attempt?.id == token else { return nil }
        return _attempt
    }

    private func _markPayloadRequested(_ token: UUID) {
        _attemptLock.lock()
        defer { _attemptLock.unlock() }
        if _attempt?.id == token { _attempt?.payloadRequested = true }
    }

    private func _configureRoutes(_ server: Application, secure: Bool) {
        server.get("*") { [weak self] req in
            guard let self, let rawToken = req.query[String.self, at: "attempt"],
                  let token = UUID(uuidString: rawToken), let attempt = self._currentAttempt(token) else {
                return Response(status: .notFound)
            }

            switch req.url.path {
            case "/manifest.plist" where secure:
                return Response(status: .ok, headers: [
                    "Content-Type": "text/xml",
                    "Cache-Control": "no-store"
                ], body: .init(data: self._manifestData(token: token)))

            case "/payload.ipa" where attempt.html != nil:
                let response = req.fileio.streamFile(at: attempt.package.path) { [weak self] result in
                    if case .success = result, req.method == .GET, !req.headers.contains(name: .range) {
                        self?._updateStatus(.installing, token: token)
                    }
                }
                if req.method == .GET, response.status == .ok || response.status == .partialContent {
                    self._markPayloadRequested(token)
                    self._updateStatus(.sendingPayload, token: token)
                }
                response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return response

            case "/install" where !secure:
                guard let html = attempt.html else { return Response(status: .notFound) }
                return Response(status: .ok, headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Cache-Control": "no-store",
                    "Referrer-Policy": "no-referrer"
                ], body: .init(string: html))

            case "/install-status" where !secure:
                return Response(status: .ok, headers: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "Cache-Control": "no-store"
                ], body: .init(string: attempt.payloadRequested ? "fetching" : "waiting"))

            default:
                return Response(status: .notFound)
            }
        }
    }

    private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus, token: UUID) {
        DispatchQueue.main.async {
            guard self._currentAttempt(token) != nil else { return }
            switch self.viewModel.status {
            case .completed, .broken:
                return
            case .installing:
                // A subsequent range request must not move the UI backwards.
                return
            default:
                self.viewModel.status = newStatus
            }
        }
    }
}
