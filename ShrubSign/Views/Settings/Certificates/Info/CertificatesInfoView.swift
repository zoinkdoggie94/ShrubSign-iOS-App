//
//  CertificatesInfoView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificatesInfoView: View {
	@Environment(\.dismiss) var dismiss
	@State var data: Certificate?
	
	var cert: CertificatePair
	
	// MARK: Body
    var body: some View {
		NBNavigationView(cert.nickname ?? "", displayMode: .inline) {
			Form {
				Section {} header: {
					Image("Cert")
						.resizable()
						.scaledToFit()
						.frame(width: 107, height: 107)
						.frame(maxWidth: .infinity, alignment: .center)
				}
				
				if let data {
					_infoSection(data: data)
					_entitlementsSection(data: data)
					_miscSection(data: data)
				}
			}
			.toolbar {
				NBToolbarButton(role: .close)
			}
		}
		.onAppear {
			data = Storage.shared.getProvisionFileDecoded(for: cert)
		}
    }
}

// MARK: - Extension: View
extension CertificatesInfoView {
	@ViewBuilder
	private func _infoSection(data: Certificate) -> some View {
		NBSection(.localized("Profile")) {
			_info(.localized("Name"), description: data.Name)
			_info(.localized("AppID Name"), description: data.AppIDName)
			_info(.localized("Team Name"), description: data.TeamName)
            _info("Profile UUID", description: data.UUID)
            _info("Created", description: data.CreationDate.formatted(date: .abbreviated, time: .shortened))
            _info("Time to live", description: "\(data.TimeToLive) days")
            _info("Profile version", description: data.Version.description)
            if let teamID = data.TeamIdentifier.first {
                _info("Team ID", description: teamID)
            }
            if let appIdentifier = data.Entitlements?["application-identifier"]?.value as? String {
                _info("Application identifier", description: appIdentifier)
            }
		}
		
		NBSection(.localized("Status")) {
			_info(.localized("Expires"), description: data.ExpirationDate.formatted(date: .abbreviated, time: .shortened))
				.foregroundStyle(data.ExpirationDate.expirationInfo().color)
            _info("Validity", description: data.ExpirationDate > Date() ? "Not expired" : "Expired")
            _info("Distribution", description: _distributionDescription(data))
            if let devices = data.ProvisionedDevices {
                _info("Provisioned devices", description: devices.count.formatted())
            }
            _info("Saved revocation flag", description: cert.revoked ? "Flagged" : "Not flagged")
            Text("Expiration and the saved flag are local profile information; ShrubSign does not claim a live Apple revocation status check.")
                .font(.caption).foregroundStyle(.secondary)
            
			if let ppq = data.PPQCheck {
				_info("PPQCheck", description: ppq ? "Yes" : "No")
			}
		}
	}

    private func _distributionDescription(_ data: Certificate) -> String {
        if data.ProvisionsAllDevices == true { return "All devices" }
        if let devices = data.ProvisionedDevices, !devices.isEmpty { return "Registered devices" }
        return data.IsXcodeManaged == true ? "Xcode managed" : "Distribution profile"
    }
	
	@ViewBuilder
	private func _entitlementsSection(data: Certificate) -> some View {
		if let entitlements = data.Entitlements {
			Section {
				NavigationLink(.localized("View Entitlements")) {
					CertificatesInfoEntitlementView(entitlements: entitlements)
				}
			}
		}
	}
	
	@ViewBuilder
	private func _miscSection(data: Certificate) -> some View {
		NBSection(.localized("Misc")) {
			_disclosure(.localized("Platform"), keys: data.Platform)
			
			if let all = data.ProvisionsAllDevices {
				_info(.localized("Provision All Devices"), description: all.description)
			}
			
			if let devices = data.ProvisionedDevices {
				_disclosure(.localized("Provisioned Devices"), keys: devices)
			}
			
			_disclosure(.localized("Team Identifiers"), keys: data.TeamIdentifier)
			
			if let prefix = data.ApplicationIdentifierPrefix{
				_disclosure(.localized("Identifier Prefix"), keys: prefix)
			}
		}
	}
	
	@ViewBuilder
	private func _info(_ title: String, description: String) -> some View {
		LabeledContent(title) {
			Text(description)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
		}
	}
	
	@ViewBuilder
	private func _disclosure(_ title: String, keys: [String]) -> some View {
		DisclosureGroup(title) {
			ForEach(keys, id: \.self) { key in
				Text(key)
					.foregroundStyle(.secondary)
			}
		}
	}
}
