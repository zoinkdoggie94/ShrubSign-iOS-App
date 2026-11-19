//
//  InstallationView.swift
//  ShrubSign
//
//  Created by samara on 3.06.2025 for Feather.
//  Reworked for ShrubSign 3.2.2: installation modes are explained in place,
//  local profile setup is one tap, and a real install check replaces guesswork.
//

import SwiftUI
import UIKit
import NimbleViews

// MARK: - View
struct InstallationView: View {
    @AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
    @AppStorage(ShrubInstallKey.mode) private var _mode: Int = ShrubInstallMode.automatic.rawValue
    @AppStorage(ShrubInstallKey.allowLocalNetwork) private var _allowLocalNetwork: Bool = false
    @AppStorage(ShrubInstallKey.customManifestURL) private var _customManifestURL: String = ""
    @StateObject private var _readiness = ShrubInstallReadiness.shared
    @StateObject private var _options = OptionsManager.shared
    @State private var _showMethodChangedAlert = false

    private let _installationMethods: [String] = [
        .localized("Server"),
        .localized("idevice")
    ]

    // MARK: Body
    var body: some View {
        NBList(.localized("Installation")) {
            Section {
                Picker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
                    ForEach(_installationMethods.indices, id: \.description) { index in
                        Text(_installationMethods[index]).tag(index)
                    }
                }
            } footer: {
                Text("Server (Recommended):\nSigns, then hands the app to iOS from this device.\n\nIDevice (advanced):\nUses a VPN and a pairing file to write to the device directly. No certificates or local server needed.")
            }

            if _installationMethod == 0 {
                _modeSection()
                ServerView()
                _diagnosticsSection()
                _advancedSection()
            } else {
                TunnelView()
            }
        }
        .onChange(of: _installationMethod) { newValue in
            guard newValue == 1 else { return }
            _showMethodChangedAlert = true
        }
        .alert(.localized("Advanced Installation Method"), isPresented: $_showMethodChangedAlert) {
            Button(.localized("Switch Back"), role: .destructive) {
                _installationMethod = 0
            }
            Button(.localized("OK"), role: .cancel) {}
        } message: {
            Text(.localized("idevice warning"))
        }
        .onChange(of: _mode) { _ in
            _readiness.refresh()
        }
        .onAppear {
            _readiness.refresh()
        }
        .animation(.default, value: _installationMethod)
    }
}

// MARK: - Sections
extension InstallationView {
    @ViewBuilder
    private func _modeSection() -> some View {
        Section {
            ForEach(ShrubInstallMode.allCases) { mode in
                Button {
                    _mode = mode.rawValue
                    _readiness.refresh()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: mode.symbol)
                            .font(.body)
                            .frame(width: 28, height: 28)
                            .foregroundStyle(mode.rawValue == _mode ? Color.accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(mode.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                if mode == .automatic {
                                    Text("Recommended")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(mode.footnote)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: mode.rawValue == _mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(mode.rawValue == _mode ? Color.accentColor : .tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Installation mode")
        } footer: {
            Text("Automatic uses Fully Local as soon as the profile is trusted, and falls back to Semi Local otherwise.")
        }
    }

    @ViewBuilder
    private func _diagnosticsSection() -> some View {
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

            Button {
                Task { await _readiness.runChecks() }
            } label: {
                HStack {
                    Label("Run install check", systemImage: "stethoscope")
                    Spacer()
                    if _readiness.isChecking { ProgressView() }
                }
            }
            .disabled(_readiness.isChecking)

            ForEach(_readiness.checks) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: _icon(for: check.level))
                        .foregroundStyle(_color(for: check.level))
                        .font(.footnote)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title)
                            .font(.subheadline.weight(.semibold))
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 3)
            }

            if !_readiness.checks.isEmpty {
                Button {
                    UIPasteboard.general.string = _readiness.diagnosticsText
                } label: {
                    Label("Copy diagnostics", systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text("Install check")
        } footer: {
            if let date = _readiness.lastChecked {
                Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened)).")
            } else {
                Text("Checks the certificate, trust, the manifest helper and free storage.")
            }
        }
    }

    @ViewBuilder
    private func _advancedSection() -> some View {
        Section {
            Toggle(isOn: $_allowLocalNetwork) {
                Label("Allow installs over the local network", systemImage: "network")
            }
            TextField("https://example.com/genPlist", text: $_customManifestURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle(isOn: $_options.options.backgroundAudio) {
                Label("Keep ShrubSign awake in the background", systemImage: "arrow.trianglehead.2.clockwise")
            }
            Button("ShrubCerts · Private Certificates", systemImage: "checkmark.shield") {
                UIApplication.open("https://shrubcerts.pages.dev")
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Loopback (127.0.0.1) is used by default, so no local network permission is needed. A custom manifest server must return an OTA plist and accept bundleid, name, version and fetchurl query items.")
        }
        .onChange(of: _options.options.backgroundAudio) { _ in
            _options.saveOptions()
        }
    }

    private func _icon(for level: ShrubInstallReadiness.Check.Level) -> String {
        switch level {
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func _color(for level: ShrubInstallReadiness.Check.Level) -> Color {
        switch level {
        case .pass: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}
