//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct SettingsView: View {
    @AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
        animation: .snappy
    ) private var _certificates: FetchedResults<CertificatePair>
    
    private var selectedCertificate: CertificatePair? {
        guard
            _storedSelectedCert >= 0,
            _storedSelectedCert < _certificates.count
        else {
            return nil
        }
        return _certificates[_storedSelectedCert]
    }
    
    
		private let _githubUrl = "https://github.com/zoinkdoggie94/ShrubSign-iOS-App"
    private let _discordUrl = "https://dsc.gg/shrubhub"
	// MARK: Body
    var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				_feedback()
				
				Section {
                    NavigationLink(destination: ShrubUpdatesView()) {
                        Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink(destination: AppIconView()) {
                        Label(.localized("App Icon"), systemImage: "app.badge")
                    }
					NavigationLink(destination: AppearanceView()) {
                        Label(.localized("Appearance"), systemImage: "paintbrush")
                    }
				}
                
                NBSection(.localized("Certificates")) {
                    
                    if let cert = selectedCertificate {
                        CertificatesCellView(cert: cert)
                    } else {
                        Text(.localized("No Certificate"))
                            .font(.footnote)
                            .foregroundColor(.disabled())
                    }
                    NavigationLink(destination: CertificatesView()) {
                        Label(.localized("Certificates"), systemImage: "signature")
                    }
                 
                } footer: {
                    Text(.localized("Add and manage certificates used for signing applications."))
                }
				
				NBSection(.localized("Features")) {
                    NavigationLink(destination: LogsView(manager: LogsManager.shared)) {
                        Label(.localized("Logs"), systemImage: "apple.terminal")
                    }
					NavigationLink(destination: AppFeaturesView()) {
                        Label(.localized("App Features"), systemImage: "sparkles")
                    }
					NavigationLink(destination: ConfigurationView()) {
                        Label(.localized("Signing Options"), systemImage: "gear")
                    }
					NavigationLink(destination: ArchiveView()) {
                        Label(.localized("Archive & Extraction"), systemImage: "archivebox")
                    }
					NavigationLink(destination: InstallationView()) {
                        Label(.localized("Installation"), systemImage: "server.rack")
                    }
				}
				
				_directories()
                
                Section {
                    NavigationLink(destination: ResetView()) {
                        Label(.localized("Reset"), systemImage: "trash")
                    }
                } footer: {
                    Text("Reset the applications sources, certificates, apps, and general contents.")
                }

            }
        }
    }
}

// MARK: - View extension
extension SettingsView {
	@ViewBuilder
	private func _feedback() -> some View {
		Section {
			NavigationLink(destination: AboutShrubSignView()) {
                Label(.localized("About"), systemImage: "info.circle")
            }
			Button("ShrubLibrary", systemImage: "safari") {
				UIApplication.open("https://shrublibrary.pages.dev")
			}
			Button(.localized("GitHub Repository"), systemImage: "safari") {
				UIApplication.open(_githubUrl)
			}
            Button(.localized("Discord Server"), systemImage: "safari") {
                UIApplication.open(_discordUrl)
            }
		}
	}
	
	@ViewBuilder
	private func _directories() -> some View {
		NBSection(.localized("Misc")) {
			Button(.localized("Open Documents"), systemImage: "folder") {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Archives"), systemImage: "folder") {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
		} footer: {
			Text(.localized("All of ShrubSign files except certificates are contained in the documents directory, here are some quick links to these."))
		}
	}
}
