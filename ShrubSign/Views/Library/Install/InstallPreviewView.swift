//
//  InstallPreviewView.swift
//  ShrubSign
//
//  Created by samara on 22.04.2025 for Feather.
//  3.2.2: one hand-off path for every install. The manifest is validated before
//  iOS is asked to install, failures are explained in place, and a watchdog
//  offers retry, mode switching, or opening the page in Safari.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    // Sharing
    @AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false

    // Methods
    @AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0

    @StateObject var viewModel: InstallerStatusViewModel
    @StateObject var installer: ServerInstaller

    @State private var _sheet: ShrubSheetURL?
    @State private var _didStartHandoff = false
    @State private var _didPreparePackage = false
    @State private var _didFinish = false
    @State private var _problem: String?
    @State private var _progressTask: Task<Void, Never>?
    @State private var _watchdog: Task<Void, Never>?
    @State private var _installRecordID = UUID()
    @State private var _didBeginRecord = false
    @State private var _wasInstalled: Bool?

    var app: AppInfoPresentable
    var isSharing: Bool
    var onFinished: ((Error?) -> Void)?

    init(app: AppInfoPresentable, isSharing: Bool = false, onFinished: ((Error?) -> Void)? = nil) {
        self.app = app
        self.isSharing = isSharing
        self.onFinished = onFinished
        let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
        let viewModel = InstallerStatusViewModel(isIdevice: method == 1)
        self._viewModel = StateObject(wrappedValue: viewModel)
        self._installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: viewModel))
    }

    // MARK: Body
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    InstallProgressView(app: app, viewModel: viewModel)

                    if let problem = _problem {
                        _problemCard(problem)
                    } else if _didStartHandoff, !viewModel.isCompleted {
                        Label("Waiting for iOS to start the installation…", systemImage: "hourglass")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    _actions()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $_sheet) { sheet in
            SafariRepresentableView(url: sheet.url)
                .ignoresSafeArea()
        }
        .onReceive(viewModel.$status) { newStatus in
            _handle(newStatus)
        }
        .onAppear {
            BackgroundAudioManager.shared.start(force: true)
            _install()
        }
        .onDisappear {
            _progressTask?.cancel()
            _progressTask = nil
            _watchdog?.cancel()
            _watchdog = nil
            BackgroundAudioManager.shared.stop()
        }
    }

    // MARK: - Actions
    @ViewBuilder
    private func _actions() -> some View {
        if _problem != nil {
            VStack(spacing: 9) {
                Button {
                    _retry()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    _switchMode()
                } label: {
                    Label("Use \(_alternateModeTitle)", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let page = installer.installPageURL {
                    Button {
                        UIApplication.shared.open(page, options: [:], completionHandler: nil)
                    } label: {
                        Label("Open install page in Safari", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if !PersonalSSL.isTrusted() {
                    Button {
                        _openProfileSetup()
                    } label: {
                        Label("Set up offline install", systemImage: "lock.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.subheadline.weight(.semibold))
            .controlSize(.large)
        } else if viewModel.isCompleted, onFinished == nil {
            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
        }
    }

    private func _problemCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Installation didn't start", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Status
    private func _handle(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
        switch newStatus {
        case .ready:
            _startHandoff()

        case .sendingManifest:
            break

        case .sendingPayload:
            _watchdog?.cancel()
            _watchdog = nil
            _problem = nil
            _sheet = nil

        case .installing:
            _watchdog?.cancel()
            _startWatchdog(seconds: 300, stalledWhileInstalling: true)
            _startProgressPolling()

        case .completed:
            _finish(nil)

        case .broken(let error):
            _finish(error)

        case .none:
            break
        }
    }

    private func _finish(_ error: Error?) {
        guard !_didFinish else { return }
        _didFinish = true
        _progressTask?.cancel()
        _progressTask = nil
        _watchdog?.cancel()
        _watchdog = nil

        if !isSharing {
            ShrubSigningCenter.shared.finish(id: _installRecordID, error: error)
        }
        if let error {
            _problem = error.localizedDescription
        }
        BackgroundAudioManager.shared.stop()

        // Keep the local server alive briefly so iOS can finish reading the
        // payload after the last byte is written.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            installer.stopKeepingAlive()
        }
        onFinished?(error)
    }

    // MARK: - Hand-off
    @MainActor
    private func _startHandoff() {
        guard !_didStartHandoff, _problem == nil else { return }
        _didStartHandoff = true
        installer.keepServerAliveDuringInstall()

        Task { @MainActor in
            do {
                let page = try await installer.prepareInstallHandoff()
                _sheet = ShrubSheetURL(url: page)
                _startWatchdog(seconds: 35, stalledWhileInstalling: false)
            } catch {
                _didStartHandoff = false
                installer.stopKeepingAlive()
                _problem = error.localizedDescription
            }
        }
    }

    private func _startWatchdog(seconds: UInt64, stalledWhileInstalling: Bool) {
        _watchdog?.cancel()
        _watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, _problem == nil else { return }

            if case .completed = viewModel.status { return }
            if case .sendingPayload = viewModel.status { return }
            if case .installing = viewModel.status, !stalledWhileInstalling { return }

            _problem = stalledWhileInstalling
                ? "iOS has been installing for a while without reporting progress. If the app is not on your Home Screen, try again."
                : "iOS opened the installer but did not start the download. This usually means the manifest could not be fetched or the local server stopped."
        }
    }

    private func _retry() {
        _problem = nil
        _sheet = nil
        _didStartHandoff = false
        _didFinish = false
        _watchdog?.cancel()
        _watchdog = nil

        if installer.packageUrl == nil {
            _didPreparePackage = false
            viewModel.status = .none
            _install()
        } else {
            // Re-emitting .ready runs the hand-off again with the freshly
            // validated manifest.
            viewModel.status = .ready
        }
    }

    private var _alternateModeTitle: String {
        ServerInstaller.resolvedMode() == .fullyLocal ? "Semi Local" : "Fully Local"
    }

    private func _switchMode() {
        ServerInstaller.mode = ServerInstaller.resolvedMode() == .fullyLocal ? .localServer : .fullyLocal
        _retry()
    }

    private func _openProfileSetup() {
        do {
            let url = try ShrubInstallReadiness.shared.installProfile()
            _sheet = ShrubSheetURL(url: url)
        } catch {
            _problem = error.localizedDescription
        }
    }

    // MARK: - Packaging
    private func _install() {
        guard !_didPreparePackage else { return }
        _didPreparePackage = true
        _wasInstalled = app.identifier.flatMap { UIApplication.appIsInstalled($0) }

        if !isSharing, !_didBeginRecord {
            _didBeginRecord = true
            ShrubSigningCenter.shared.begin(
                id: _installRecordID,
                name: app.name ?? "Unnamed IPA",
                bundleID: app.identifier,
                kind: "Installation"
            )
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        guard isSharing || app.identifier != ownBundleID || _installationMethod == 1 else {
            if !isSharing {
                ShrubSigningCenter.shared.finish(id: _installRecordID, error: NSError(
                    domain: "ShrubSign.Install",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "You cannot replace ShrubSign using this installation method."]
                ))
            }
            UIAlertController.showAlertWithOk(
                title: .localized("Install"),
                message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
            )
            return
        }

        Task.detached {
            do {
                let handler = await ArchiveHandler(app: app, viewModel: viewModel)
                try await handler.move()

                let packageUrl = try await handler.archive()

                if await !isSharing {
                    if await _installationMethod == 0 {
                        await MainActor.run {
                            installer.packageUrl = packageUrl
                            viewModel.status = .ready
                        }
                    } else if await _installationMethod == 1 {
                        let proxy = await InstallationProxy(viewModel: viewModel)
                        try await proxy.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier)
                    }
                } else {
                    let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)

                    if await !_useShareSheet {
                        await MainActor.run {
                            dismiss()
                        }
                    } else if let package {
                        await MainActor.run {
                            dismiss()
                            UIActivityViewController.show(activityItems: [package])
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    _progressTask?.cancel()
                    _problem = error.localizedDescription
                    _finish(error)
                    HeartbeatManager.shared.start(true)
                }
            }
        }
    }

    // MARK: - Progress polling
    private func _startProgressPolling() {
        guard _progressTask == nil else { return }
        guard let bundleID = app.identifier, !bundleID.isEmpty else {
            _finish(NSError(
                domain: "ShrubSign.Install",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This app does not have a valid bundle identifier."]
            ))
            return
        }
        _progressTask = _pollInstallProgress(bundleID: bundleID, wasInstalled: _wasInstalled)
    }

    private func _pollInstallProgress(bundleID: String, wasInstalled: Bool?) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            var hasStarted = false
            var ticks = 0

            while !Task.isCancelled {
                ticks += 1
                let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

                if rawProgress > 0 {
                    hasStarted = true
                }

                let progress = hasStarted ? _normalizeInstallProgress(rawProgress) : 0.0
                Logger.misc.info("Install progress for \(bundleID): \(progress) - \(rawProgress)")

                await MainActor.run {
                    viewModel.installProgress = progress
                }

                if hasStarted && rawProgress == 0 {
                    await MainActor.run {
                        viewModel.installProgress = 1.0
                        viewModel.status = .completed(.success(()))
                    }
                    break
                }

                // Some iOS builds do not publish install progress for apps
                // served locally. If the app was absent before this install and
                // is present now, the installation clearly succeeded.
                if !hasStarted, wasInstalled == false, ticks % 8 == 0,
                   UIApplication.appIsInstalled(bundleID) == true {
                    await MainActor.run {
                        viewModel.installProgress = 1.0
                        viewModel.status = .completed(.success(()))
                    }
                    break
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
        min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
    }
}
