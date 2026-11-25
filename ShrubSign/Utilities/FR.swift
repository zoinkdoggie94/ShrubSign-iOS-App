//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift

enum FR {
	static func handlePackageFile(
		_ ipa: URL,
		download: Download? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = AppFileHandler(file: ipa, download: download)
			
			do {
				try await handler.copy()
				try await handler.extract()
				try await handler.move()
				try await handler.addToDatabase()
                
                try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		completion: @escaping (Result<Signed, Error>) -> Void
	) {
        let recordID = UUID()
        let displayName = app.name ?? "Unnamed IPA"
        let bundleID = app.identifier
        Task.detached(priority: .userInitiated) {
            await MainActor.run {
                ShrubSigningCenter.shared.begin(id: recordID, name: displayName, bundleID: bundleID)
            }
			let handler = SigningHandler(app: app, options: options)
			if !options.onlyModify {
				handler.appCertificate = certificate
			}
			handler.appIcon = icon
			
            do {
                let start = ProcessInfo.processInfo.systemUptime
                try await handler.copy()
                let copied = ProcessInfo.processInfo.systemUptime
                let signed = try await handler.modify()
                let modified = ProcessInfo.processInfo.systemUptime
                print("[ShrubSign] Signing stages: prepare=\(Int((copied - start) * 1000))ms, modify+sign+save=\(Int((modified - copied) * 1000))ms")
                try? await handler.clean()
				
                await MainActor.run {
                    ShrubSigningCenter.shared.finish(id: recordID, error: nil)
                    completion(.success(signed))
                }
            } catch {
                try? await handler.clean()
                await MainActor.run {
                    ShrubSigningCenter.shared.finish(id: recordID, error: error)
                    completion(.failure(error))
                }
            }
        }
    }

    static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_WHAT_THE_FUCK_free(provision.path)
		}
		
		password_check_fix_WHAT_THE_FUCK(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func checkPasswordForCertificateData(
		p12Data: Data,
		provisionData: Data,
		password: String
	) -> Bool {
		let tempDir = FileManager.default.temporaryDirectory
		let tempP12 = tempDir.appendingPathComponent("temp_cert.p12")
		let tempProvision = tempDir.appendingPathComponent("temp_provision.mobileprovision")
		
		defer {
			try? FileManager.default.removeItem(at: tempP12)
			try? FileManager.default.removeItem(at: tempProvision)
		}
		
		do {
			try p12Data.write(to: tempP12)
			try provisionData.write(to: tempProvision)
			
			return checkPasswordForCertificate(for: tempP12, with: password, using: tempProvision)
		} catch {
			print("Error creating temporary files for password check: \(error)")
			return false
		}
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")

		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	#if SERVER
	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Bool) -> Void
	) {
		let generator = UINotificationFeedbackGenerator()
		generator.prepare()
		
		NBFetchService().fetch(from: urlString) { (result: Result<ServerPackModel, Error>) in
			switch result {
			case .success(let pack):
				do {
					let serverDir = URL.documentsDirectory.appendingPathComponent("App").appendingPathComponent("Server")
					let pemURL = serverDir.appendingPathComponent("server.pem")
					let crtURL = serverDir.appendingPathComponent("server.crt")
					let commonNameURL = serverDir.appendingPathComponent("commonName.txt")
					
					try FileManager.default.createDirectoryIfNeeded(at: serverDir)
					try pack.key.write(to: pemURL, atomically: true, encoding: .utf8)
					try pack.cert.write(to: crtURL, atomically: true, encoding: .utf8)
					try pack.info.domains.commonName.write(to: commonNameURL, atomically: true, encoding: .utf8)
					
					generator.notificationOccurred(.success)
					completion(true)
				} catch {
					completion(false)
				}
			case .failure(_):
				completion(false)
			}
		}
	}
	#endif
	
	static func handleSource(
		_ urlString: String,
		competion: @escaping () -> Void
	) {
		handleSourceWithResult(urlString) { result in
			switch result {
			case .success:
				competion()
			case .failure(let error):
				UIAlertController.showAlertWithOk(title: "Repository", message: error.localizedDescription)
			}
		}
	}

	/// Always calls back on the main thread, including failed validations.
	/// Core Data's viewContext must never be used on URLSession callback queues.
	static func handleSourceWithResult(
		_ urlString: String,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = URL(string: trimmed),
			  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
			  url.host != nil else {
			DispatchQueue.main.async {
				completion(.failure(NSError(domain: "ShrubSign.Source", code: 1,
					userInfo: [NSLocalizedDescriptionKey: "Enter a valid http or https repository URL."])))
			}
			return
		}
		NBFetchService().fetch(from: url) { (result: Result<ASRepository, Error>) in
			DispatchQueue.main.async {
				switch result {
				case .success(let repository):
					let identifier = repository.id ?? url.absoluteString
					guard !Storage.shared.sourceExists(identifier) else {
						completion(.failure(NSError(domain: "ShrubSign.Source", code: 2,
							userInfo: [NSLocalizedDescriptionKey: "This repository is already in your sources."])))
						return
					}
					Storage.shared.addSource(url, repository: repository, id: identifier) { error in
						if let error {
							completion(.failure(error))
						} else {
							completion(.success(()))
						}
					}
				case .failure(let error):
					completion(.failure(error))
				}
			}
		}
	}

}

private enum CertificateHandlerError: Error {
	case invalidCertificate
}
