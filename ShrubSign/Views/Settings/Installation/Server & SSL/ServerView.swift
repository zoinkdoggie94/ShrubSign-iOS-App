//
//  ServerView.swift
//  ShrubSign
//
//  Device-local HTTPS setup. 3.2.2 removes the Files / share-sheet detour:
//  the profile is served over loopback so Safari hands it straight to iOS.
//

import SwiftUI
import UIKit
import NimbleViews

struct ServerView: View {
    @StateObject private var _readiness = ShrubInstallReadiness.shared
    @State private var _profileSheet: ShrubSheetURL?
    @State private var _message: String?
    @State private var _confirmRegenerate = false
    @Environment(\.scenePhase) private var _scenePhase

    var body: some View {
        Group {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: _readiness.symbol)
                        .font(.title3)
                        .foregroundStyle(_readiness.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(_readiness.headline)
                            .font(.subheadline.weight(.semibold))
                        Text(_readiness.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 3)
            } header: {
                Text("Local installation")
            } footer: {
                Text("Fully Local installs the manifest and the IPA from this device. It needs no internet and no third-party service.")
            }

            Section {
                Button {
                    _installProfile()
                } label: {
                    Label(
                        PersonalSSL.hasCredentials ? "Install local profile again" : "Install local profile",
                        systemImage: "lock.shield"
                    )
                }

                Button {
                    _readiness.openTrustSettings()
                } label: {
                    Label("Open Certificate Trust Settings", systemImage: "checkmark.shield")
                }

                Button {
                    _verify()
                } label: {
                    Label("Verify trust", systemImage: "checkmark.circle")
                }

                if let _message {
                    Text(_message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("One-time setup")
            } footer: {
                Text("1. Install the local profile.\n2. Open Settings → General → About → Certificate Trust Settings and turn on “ShrubSign Local Installation”.\n3. Come back — ShrubSign verifies it automatically.")
            }

            Section {
                Button(role: .destructive) {
                    _confirmRegenerate = true
                } label: {
                    Label("Regenerate certificate", systemImage: "arrow.clockwise")
                }
            } footer: {
                Text("A new certificate replaces the current one. You must install and trust the new profile afterwards.")
            }
        }
        .sheet(item: $_profileSheet, onDismiss: {
            _readiness.stopProfileServer()
            _readiness.refresh()
        }) { sheet in
            SafariRepresentableView(url: sheet.url)
                .ignoresSafeArea()
        }
        .alert("Regenerate certificate?", isPresented: $_confirmRegenerate) {
            Button("Regenerate", role: .destructive) { _regenerate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Fully Local will stop working until you install and trust the new profile.")
        }
        .onChange(of: _scenePhase) { phase in
            if phase == .active { _readiness.refresh() }
        }
        .onAppear { _readiness.refresh() }
    }

    // MARK: - Actions
    private func _installProfile() {
        _message = nil
        do {
            let url = try _readiness.installProfile()
            _message = "Approve the profile in Settings, then enable it under Certificate Trust Settings."
            // Safari handles configuration profiles reliably; an in-app
            // browser can only display the XML.
            UIApplication.shared.open(url, options: [:]) { opened in
                if !opened {
                    _profileSheet = ShrubSheetURL(url: url)
                }
            }
        } catch {
            _message = error.localizedDescription
        }
    }

    private func _verify() {
        _readiness.refresh()
        if PersonalSSL.isTrusted() {
            _message = "Verified. Fully Local is ready — installs now work without internet."
        } else if PersonalSSL.hasCredentials {
            _message = "Not trusted yet. Open Certificate Trust Settings and enable “ShrubSign Local Installation”."
        } else {
            _message = "Create the profile first."
        }
    }

    private func _regenerate() {
        _message = nil
        do {
            _ = try PersonalSSL.generate()
            ShrubProfileServer.shared.stop()
            _readiness.refresh()
            _message = "New certificate created. Install and trust the new profile."
        } catch {
            _message = error.localizedDescription
        }
    }
}
