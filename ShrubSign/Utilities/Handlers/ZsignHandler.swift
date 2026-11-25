//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import ZsignSwift
import UIKit

final class ZsignHandler {
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}
		
        var signingError: Error?
        var callbackSucceeded: Bool?
        let succeeded = Zsign.sign(
            appPath: _appUrl.relativePath,
            provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
            p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
            p12Password: cert.password ?? "",
            entitlementsPath: _options.appEntitlementsFile?.path ?? "",
            customIdentifier: _options.appIdentifier ?? "",
            customName: _options.appName ?? "",
            customVersion: _options.appVersion ?? "",
            removeProvision: false,
            completion: { success, error in
                callbackSucceeded = success
                signingError = error
            }
        )
        if let signingError { throw signingError }
        guard succeeded, callbackSucceeded != false else { throw SigningFileHandlerError.signFailed }
    }
	
	func adhocSign() async throws {
        var signingError: Error?
        var callbackSucceeded: Bool?
        let succeeded = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			customIdentifier: _options.appIdentifier ?? "",
			customName: _options.appName ?? "",
			customVersion: _options.appVersion ?? "",
			adhoc: true,
            removeProvision: _options.removeProvisioning,
            completion: { success, error in
                callbackSucceeded = success
                signingError = error
            }
        )
        if let signingError { throw signingError }
        guard succeeded, callbackSucceeded != false else { throw SigningFileHandlerError.signFailed }
             
	}
}
