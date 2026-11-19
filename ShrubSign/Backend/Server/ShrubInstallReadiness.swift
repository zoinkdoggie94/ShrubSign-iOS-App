//
//  ShrubInstallReadiness.swift
//  ShrubSign
//
//  Answers one question in one place: can ShrubSign install an app right now,
//  and if not, what exactly is missing? Used by Settings and the Home dashboard
//  so installation problems are visible before signing instead of after.
//

import Foundation
import SwiftUI
import UIKit

final class ShrubInstallReadiness: ObservableObject {
    static let shared = ShrubInstallReadiness()

    // MARK: - Types
    struct Check: Identifiable {
        enum Level {
            case pass
            case warning
            case failure
        }

        let id: String
        let title: String
        let detail: String
        let level: Level
    }

    enum Status: Equatable {
        case checking
        case offlineReady
        case onlineOnly
        case needsProfile
        case needsTrust
    }

    // MARK: - Published state
    @Published private(set) var status: Status = .checking
    @Published private(set) var checks: [Check] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?

    private init() {
        refresh()
    }

    // MARK: - Presentation
    var headline: String {
        switch status {
        case .checking: return "Checking installation…"
        case .offlineReady: return "Offline installation ready"
        case .onlineOnly: return "Semi Local ready"
        case .needsProfile: return "Local profile needed"
        case .needsTrust: return "Trust the local profile"
        }
    }

    var message: String {
        switch status {
        case .checking:
            return "ShrubSign is checking this device's install setup."
        case .offlineReady:
            return "Fully Local is trusted on this device. Installs work without internet."
        case .onlineOnly:
            return "Installs use an online manifest helper. Install the local profile to install offline too."
        case .needsProfile:
            return "Install the ShrubSign profile once, then install apps without internet."
        case .needsTrust:
            return "The profile is installed but not trusted yet. Trust it in Settings → General → About → Certificate Trust Settings."
        }
    }

    var symbol: String {
        switch status {
        case .checking: return "hourglass"
        case .offlineReady: return "checkmark.shield.fill"
        case .onlineOnly: return "antenna.radiowaves.left.and.right"
        case .needsProfile: return "lock.shield"
        case .needsTrust: return "exclamationmark.shield.fill"
        }
    }

    var tint: Color {
        switch status {
        case .checking: return .secondary
        case .offlineReady: return .green
        case .onlineOnly: return .orange
        case .needsProfile, .needsTrust: return .orange
        }
    }

    var isOfflineCapable: Bool { status == .offlineReady }

    // MARK: - Refresh (cheap, no network)
    func refresh() {
        let hasCredentials = PersonalSSL.hasCredentials
        let trusted = hasCredentials && PersonalSSL.isTrusted()
        let selected = ServerInstaller.mode

        if trusted {
            status = .offlineReady
        } else if !hasCredentials {
            status = selected == .fullyLocal ? .needsProfile : .onlineOnly
        } else {
            status = selected == .fullyLocal ? .needsTrust : .onlineOnly
        }
    }

    // MARK: - Profile helpers
    /// Creates credentials if needed and returns the loopback URL Safari should
    /// open so iOS offers the profile for installation immediately.
    func installProfile() throws -> URL {
        PersonalSSL.ensureCredentials()
        guard PersonalSSL.hasCredentials, PersonalSSL.profileURL != nil else {
            throw ShrubInstallError.profileMissing
        }
        return try ShrubProfileServer.shared.start()
    }

    func stopProfileServer() {
        ShrubProfileServer.shared.stop()
    }

    /// Opens the Certificate Trust Settings screen when iOS allows the deep
    /// link, otherwise falls back to Settings.
    func openTrustSettings() {
        if let url = URL(string: "App-Prefs:root=General&path=About/CERT_TRUST_SETTINGS") {
            UIApplication.shared.open(url, options: [:]) { accepted in
                if !accepted, let settings = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settings, options: [:], completionHandler: nil)
                }
            }
            return
        }
        if let settings = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settings, options: [:], completionHandler: nil)
        }
    }

    // MARK: - Full check
    func runChecks() async {
        await MainActor.run {
            self.isChecking = true
        }

        var results: [Check] = []

        // 1. Local credentials
        if PersonalSSL.hasCredentials {
            results.append(Check(
                id: "credentials",
                title: "Local certificate",
                detail: "ShrubSign has a device certificate for 127.0.0.1.",
                level: .pass
            ))
        } else {
            results.append(Check(
                id: "credentials",
                title: "Local certificate",
                detail: "Not created yet. Tap “Install Local Profile” to create it.",
                level: .warning
            ))
        }

        // 2. Trust
        if PersonalSSL.hasCredentials {
            if PersonalSSL.isTrusted() {
                results.append(Check(
                    id: "trust",
                    title: "Certificate trusted",
                    detail: "The system trusts ShrubSign's local certificate for 127.0.0.1.",
                    level: .pass
                ))
            } else {
                results.append(Check(
                    id: "trust",
                    title: "Certificate trusted",
                    detail: "Install the profile and enable it under Certificate Trust Settings.",
                    level: .failure
                ))
            }
        }

        // 3. Install mode
        let resolved = ServerInstaller.resolvedMode()
        results.append(Check(
            id: "mode",
            title: "Install mode",
            detail: resolved == .fullyLocal
                ? "Fully Local: the manifest and IPA are served from this device."
                : "Semi Local: the IPA stays local, the manifest comes from an online helper.",
            level: .pass
        ))

        // 4. Online manifest helper (only when Semi Local would be used)
        if resolved == .localServer {
            var reachable: String?
            var failures: [String] = []
            for provider in ShrubManifestProviders.all {
                guard let url = provider.manifestURL(
                    bundleID: "com.shrubhub.shrubsign.check",
                    name: "Check",
                    version: "1.0",
                    payload: URL(string: "http://127.0.0.1:4321/payload.ipa")!,
                    port: 4321
                ) else { continue }
                do {
                    try await ServerInstaller.validateManifest(at: url)
                    reachable = provider.name
                    break
                } catch {
                    failures.append("\(provider.name): \(error.localizedDescription)")
                }
            }
            if let reachable {
                results.append(Check(
                    id: "manifest",
                    title: "Online manifest helper",
                    detail: "\(reachable) answered with a valid manifest.",
                    level: .pass
                ))
            } else {
                results.append(Check(
                    id: "manifest",
                    title: "Online manifest helper",
                    detail: "No helper answered. Install the local profile to use Fully Local. "
                        + failures.joined(separator: " · "),
                    level: .failure
                ))
            }
        }

        // 5. Keep-alive while installing
        if OptionsManager.shared.options.backgroundAudio {
            results.append(Check(
                id: "keepalive",
                title: "Keep-alive",
                detail: "ShrubSign keeps the install server running while iOS installs.",
                level: .pass
            ))
        } else {
            results.append(Check(
                id: "keepalive",
                title: "Keep-alive",
                detail: "Background audio is off. ShrubSign still keeps itself awake during an install, but enabling it helps long installs.",
                level: .warning
            ))
        }

        // 6. Free storage
        var capacity: Int64 = 0
        if let values = try? URL.documentsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage {
            capacity = available
        }
        if capacity > 0, capacity < 1_000_000_000 {
            results.append(Check(
                id: "storage",
                title: "Free storage",
                detail: "Only \(ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)) is available. Free space before installing large apps.",
                level: .warning
            ))
        } else {
            results.append(Check(
                id: "storage",
                title: "Free storage",
                detail: "Enough space is available for packaging an IPA.",
                level: .pass
            ))
        }

        // 7. Last installation result reported by the signing centre
        if let last = ShrubSigningCenter.shared.records.first(where: { $0.kind == "Installation" }) {
            results.append(Check(
                id: "last",
                title: "Last installation",
                detail: last.status == "Completed"
                    ? "\(last.appName) installed successfully."
                    : "\(last.appName): \(last.status)\(last.message.map { " — \($0)" } ?? "")",
                level: last.status == "Completed" ? .pass : .warning
            ))
        }

        let snapshot = results
        await MainActor.run {
            self.checks = snapshot
            self.lastChecked = Date()
            self.isChecking = false
            self.refresh()
        }
    }

    var diagnosticsText: String {
        var lines: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        lines.append("ShrubSign \(version) installation diagnostics")
        lines.append("Mode: \(ServerInstaller.mode.title) (resolved: \(ServerInstaller.resolvedMode().title))")
        lines.append("Credentials: \(PersonalSSL.hasCredentials ? "present" : "missing")")
        lines.append("Trusted: \(PersonalSSL.isTrusted() ? "yes" : "no")")
        lines.append("Profile: \(PersonalSSL.profileURL == nil ? "missing" : "present")")
        lines.append("Online helpers: \(ShrubManifestProviders.all.map(\.name).joined(separator: ", "))")
        for check in checks {
            let state: String
            switch check.level {
            case .pass: state = "PASS"
            case .warning: state = "WARN"
            case .failure: state = "FAIL"
            }
            lines.append("[\(state)] \(check.title): \(check.detail)")
        }
        if let lastChecked {
            lines.append("Checked: \(lastChecked.formatted(date: .abbreviated, time: .standard))")
        }
        return lines.joined(separator: "\n")
    }
}
