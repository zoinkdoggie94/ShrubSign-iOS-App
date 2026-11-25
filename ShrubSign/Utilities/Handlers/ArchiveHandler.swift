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
    private(set) var buildVersion: String?
	
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
		guard let appUrl = await MainActor.run(body: { Storage.shared.getAppDirectory(for: _app) }) else {
			throw SigningFileHandlerError.appNotFound
		}
		
        buildVersion = Bundle(url: appUrl)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
		let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
		let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
		
		try _fileManager.copyAppBundle(at: appUrl, to: movedAppURL)
		_payloadUrl = payloadUrl
	}
	
    func archive(forLocalInstall: Bool) async throws -> URL {
        guard let payloadURL = _payloadUrl else { throw SigningFileHandlerError.appNotFound }
        let ipaURL = _uniqueWorkDir.appendingPathComponent("Archive.ipa")
        let progressGate = ShrubArchiveProgressGate()
        try Zip.zipFiles(
            paths: [payloadURL],
            zipFilePath: ipaURL,
            password: nil,
            compression: Self.selectedCompression(forLocalInstall: forLocalInstall),
            progress: { progress in
                guard progress.isFinite, progressGate.shouldReport(progress) else { return }
                Task { @MainActor in
                    self.viewModel.packageProgress = max(self.viewModel.packageProgress, progress)
                }
            }
        )
        try? _fileManager.removeItem(at: payloadURL)
        await MainActor.run { viewModel.packageProgress = 1 }
        return ipaURL
    }

    func clean() {
        try? _fileManager.removeItem(at: _uniqueWorkDir)
    }

	func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
		let rawName = (_app.name?.isEmpty == false ? _app.name : nil) ?? "ShrubSignApp"
		let rawVersion = (_app.version?.isEmpty == false ? _app.version : nil) ?? "UnknownVersion"
		let invalidFilenameCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
		let safeName = rawName.components(separatedBy: invalidFilenameCharacters).joined(separator: "_")
		let safeVersion = rawVersion.components(separatedBy: invalidFilenameCharacters).joined(separator: "_")
		let appendingString = "\(safeName)_\(safeVersion)_\(Int(Date().timeIntervalSince1970)).ipa"
		let dest = _fileManager.archives.appendingPathComponent(appendingString)
		
        let output: URL
        if _fileManager.fileExists(atPath: dest.path) {
            output = dest.deletingPathExtension()
                .appendingPathExtension(UUID().uuidString)
                .appendingPathExtension("ipa")
        } else {
            output = dest
        }
        try _fileManager.moveItem(at: package, to: output)
		
		if shouldOpen, let sharedURL = FileManager.default.archives.toSharedDocumentsURL() {
			await MainActor.run {
				UIApplication.open(sharedURL)
			}
		}
		
		return output
	}
	
    static func selectedCompression(forLocalInstall: Bool) -> ZipCompression {
        let defaults = UserDefaults.standard
        let key = "Feather.compressionLevel"
        guard defaults.object(forKey: key) != nil else {
            return forLocalInstall ? .NoCompression : .BestSpeed
        }
        let savedRawValue = defaults.integer(forKey: key)
        return ZipCompression.allCases.first(where: { $0.rawValue == savedRawValue }) ?? .BestSpeed
    }
}
