//
//  ShrubProfileServer.swift
//  ShrubSign
//
//  Serves the device-local trust profile over loopback HTTP so Safari can hand
//  it to iOS. Previously the profile had to be shared to Files and opened by
//  hand; one tap now starts the system profile installer.
//

import Foundation
import Vapor
import UIKit

@MainActor
final class ShrubProfileServer {
    static let shared = ShrubProfileServer()

    private var _server: Application?
    private var _stopWorkItem: DispatchWorkItem?
    private var _backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var port = 0

    private init() {}

    var isRunning: Bool { _server != nil }

    var url: URL? {
        guard port > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/profile.mobileconfig"
        return components.url
    }

    /// Starts the profile server (or reuses the running one) and returns the
    /// URL Safari should open.
    @discardableResult
    func start() throws -> URL {
        if _backgroundTask == .invalid {
            _backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ShrubSignTrustProfile") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        if let existing = url, isRunning {
            scheduleStop()
            return existing
        }

        guard PersonalSSL.hasCredentials else { throw ShrubInstallError.profileMissing }
        guard PersonalSSL.profileURL != nil else { throw ShrubInstallError.profileMissing }

        var lastError: Error?
        for _ in 0..<6 {
            let candidate = Int.random(in: 4020...8020)
            let app = ServerInstaller.setupApp(port: candidate, loopbackOnly: true)
            do {
                app.get("profile.mobileconfig") { _ -> Response in
                    guard let fileURL = PersonalSSL.profileURL,
                          let data = try? Data(contentsOf: fileURL) else {
                        return Response(status: .notFound)
                    }
                    return Response(status: .ok, headers: [
                        "Content-Type": "application/x-apple-aspen-config",
                        "Content-Disposition": "attachment; filename=\"ShrubSign-Local-Trust.mobileconfig\"",
                        "Cache-Control": "no-store"
                    ], body: .init(data: data))
                }

                app.get("health") { _ -> Response in
                    Response(status: .ok, body: .init(string: "ok"))
                }

                try app.server.start()
                _server = app
                port = candidate
                scheduleStop()
                if let started = url { return started }
            } catch {
                lastError = error
                app.shutdown()
                _server = nil
                port = 0
            }
        }

        endBackgroundTask()
        throw lastError ?? ShrubInstallError.localServerUnavailable
    }

    func stop() {
        endBackgroundTask()
        _stopWorkItem?.cancel()
        _stopWorkItem = nil
        _server?.server.shutdown()
        _server?.shutdown()
        _server = nil
        port = 0
    }

    private func endBackgroundTask() {
        guard _backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(_backgroundTask)
        _backgroundTask = .invalid
    }

    /// Keeps the listener around long enough for the user to finish the
    /// Settings flow, then releases the port automatically.
    private func scheduleStop() {
        _stopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        _stopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 900, execute: item)
    }

}
