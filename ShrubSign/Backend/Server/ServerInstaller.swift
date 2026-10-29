//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
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
	private(set) var port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

    // iOS may dismiss the installation view while itms-services is fetching
    // the manifest and IPA. Hold a bounded reference so SwiftUI view teardown
    // does not destroy the server during that handoff.
    private static let activeInstallLock = NSLock()
    private static var activeInstallers: [UUID: ServerInstaller] = [:]

    func keepServerAliveDuringInstall() {
        Self.activeInstallLock.lock()
        Self.activeInstallers[id] = self
        Self.activeInstallLock.unlock()

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
        activeInstallLock.lock()
        let released = activeInstallers.removeValue(forKey: installID)
        activeInstallLock.unlock()
        _ = released
    }

    // Test the same HTTPS hostname and manifest URL that the system installer
    // will receive. Unlike checking that three files exist, this exercises
    // DNS, TLS trust, the listener, and manifest delivery.
    func verifyFullyLocalConnection() async throws {
        guard Self.getServerMethod() != 1 else { return }
        guard let fileURL = packageUrl,
              fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "ShrubSign.Install", code: 11,
                userInfo: [NSLocalizedDescriptionKey:
                    "The signed IPA is missing. Export or sign the app again before installing."])
        }

        let target = plistEndpoint
        var request = URLRequest(url: target)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("1", forHTTPHeaderField: "X-ShrubSign-Preflight")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "ShrubSign.Install", code: 12,
                    userInfo: [NSLocalizedDescriptionKey:
                        "The local HTTPS server did not return its installation manifest (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."])
            }
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dictionary = plist as? [String: Any], dictionary["items"] != nil else {
                throw NSError(domain: "ShrubSign.Install", code: 13,
                    userInfo: [NSLocalizedDescriptionKey:
                        "The local HTTPS server returned an invalid installation manifest."])
            }
        } catch {
            throw NSError(domain: "ShrubSign.Install", code: 14,
                userInfo: [NSLocalizedDescriptionKey:
                    "Fully Local HTTPS is not reachable at \(target.host ?? "localhost"):\(target.port ?? 0). The signed IPA has NOT been handed to iOS yet. Check Settings → General → About → Certificate Trust Settings, or use Semi Local until this connection works. Details: \(error.localizedDescription)",
                    NSUnderlyingErrorKey: error])
        }
    }

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.app = app
		self.viewModel = viewModel

        var lastError: Error?
        // Local server ports can occasionally already be occupied. Retry a few
        // times instead of crashing or making the user retry the whole install.
        for _ in 0..<5 {
            port = Int.random(in: 4000...8000)
            do {
                let server = try Self.setupApp(port: port)
                self._server = server
                try _configureRoutes()
                try server.server.start()
                _needsShutdown = true
                return
            } catch {
                lastError = error
                if let server = self._server {
                    server.server.shutdown()
                    server.shutdown()
                }
                self._server = nil
            }
        }

        DispatchQueue.main.async {
            viewModel.status = .broken(lastError ?? URLError(.cannotConnectToHost))
        }
	}
	
	deinit {
		_shutdownServer()
	}
		
	private func _configureRoutes() throws {
        guard let server = _server else { return }
		server.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
                // A local preflight request must not masquerade as iOS
                // starting the installation.
                if req.headers.first(name: "X-ShrubSign-Preflight") != "1" {
                    self._updateStatus(.sendingManifest)
                }
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}
				
				self._updateStatus(.sendingPayload)
				
				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
                    switch result {
                    case .success:
                        self._updateStatus(.installing)
                    case .failure(let error):
                        self._updateStatus(.broken(error))
                    }
				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
        guard let server = _server else { return }
		server.server.shutdown()
		server.shutdown()
        _server = nil
	}
	
    private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}
		
	static func getServerMethod() -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "Feather.serverMethod") != nil else { return 1 }
        return defaults.integer(forKey: "Feather.serverMethod")
	}
	
	static func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Feather.ipFix")
	}
	
	static func setServerMethod(_ method: Int) {
		UserDefaults.standard.set(method, forKey: "Feather.serverMethod")
	}
	
	static func setIPFix(_ enabled: Bool) {
		UserDefaults.standard.set(enabled, forKey: "Feather.ipFix")
	}
}
