//
//  ArchiveHandler.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import Zip
import SwiftUI
import IDeviceSwift

// Posting a SwiftUI state change for every ZIP progress callback can flood the
// main actor during large IPA creation. Keep it to roughly ten updates/second.
private final class ShrubArchiveProgressGate {
    private let lock = NSLock()
    private var lastReport: TimeInterval = 0

    func shouldReport(_ progress: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if progress >= 1 || now - lastReport >= 0.10 {
            lastReport = now
            return true
        }
        return false
    }
}

final class ArchiveHandler: NSObject {
	@ObservedObject var viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _payloadUrl: URL?
	
	private var _app: AppInfoPresentable
	private let _uniqueWorkDir: URL
	
	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
		self._app = app
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherInstall_\(_uuid)", isDirectory: true)
		
		super.init()
	}
	
	func move() async throws {
		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}
		
		let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
		let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
		
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_payloadUrl = payloadUrl
	}
	
	func archive() async throws -> URL {
		return try await Task.detached(priority: .background) { [self] in
			guard let payloadUrl = await self._payloadUrl else {
				throw SigningFileHandlerError.appNotFound
			}
			
			let zipUrl = self._uniqueWorkDir.appendingPathComponent("Archive.zip")
			let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
			
            let progressGate = ShrubArchiveProgressGate()
			try await Zip.zipFiles(
				paths: [payloadUrl],
				zipFilePath: zipUrl,
				password: nil,
				compression: ArchiveHandler.selectedCompression(),
				progress: { progress in
                    guard progressGate.shouldReport(progress) else { return }
					Task { @MainActor in
						self.viewModel.packageProgress = progress
					}
				})
			
			try FileManager.default.moveItem(at: zipUrl, to: ipaUrl)
			return ipaUrl
		}.value
	}
	
	func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
		let rawName = (_app.name?.isEmpty == false ? _app.name : nil) ?? "ShrubSignApp"
		let rawVersion = (_app.version?.isEmpty == false ? _app.version : nil) ?? "UnknownVersion"
		let invalidFilenameCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
		let safeName = rawName.components(separatedBy: invalidFilenameCharacters).joined(separator: "_")
		let safeVersion = rawVersion.components(separatedBy: invalidFilenameCharacters).joined(separator: "_")
		let appendingString = "\(safeName)_\(safeVersion)_\(Int(Date().timeIntervalSince1970)).ipa"
		let dest = _fileManager.archives.appendingPathComponent(appendingString)
		
		try _fileManager.moveItem(at: package, to: dest)
		
		if shouldOpen, let sharedURL = FileManager.default.archives.toSharedDocumentsURL() {
			await MainActor.run {
				UIApplication.open(sharedURL)
			}
		}
		
		return dest
	}
	
    // Prefer fast ZIP creation for fresh installs; users can still choose a
    // different compression level in Settings. Never index with a rawValue.
    static func selectedCompression() -> ZipCompression {
        let defaults = UserDefaults.standard
        let key = "Feather.compressionLevel"
        guard defaults.object(forKey: key) != nil else { return .BestSpeed }
        let savedRawValue = defaults.integer(forKey: key)
        return ZipCompression.allCases.first(where: { $0.rawValue == savedRawValue }) ?? .BestSpeed
    }
}
