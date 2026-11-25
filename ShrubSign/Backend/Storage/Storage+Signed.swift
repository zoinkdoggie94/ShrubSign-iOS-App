//
//  Storage+Signed.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Signed Apps
extension Storage {
    @MainActor
	func addSigned(
		uuid: String,
		source: URL? = nil,
		certificate: CertificatePair? = nil,
		
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil
	) throws -> Signed {
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		let new = Signed(context: context)
		
		new.uuid = uuid
		new.source = source
		new.date = Date()
		// if nil, we assume adhoc or certificate was deleted afterwards
		new.certificate = certificate
		// could possibly be nil, but thats fine.
		new.identifier = appIdentifier
		new.name = appName
		new.icon = appIcon
		new.version = appVersion
		
        do {
            try context.save()
        } catch {
            context.delete(new)
            throw error
        }
        generator.impactOccurred()
        return new
	}
}
