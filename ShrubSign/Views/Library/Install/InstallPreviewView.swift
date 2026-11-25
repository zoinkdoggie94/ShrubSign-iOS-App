//
//  InstallPreviewView.swift
//  ShrubSign
//
//  Created by samara on 22.04.2025 for Feather.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import IDeviceSwift

struct InstallPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("Feather.useShareSheetForArchiving") private var useShareSheet = false

    @StateObject private var viewModel: InstallerStatusViewModel
    @StateObject private var installer: ServerInstaller
    @State private var mode = ServerInstaller.mode
    @State private var stage: Stage = .packaging
    @State private var recordID: UUID?
    @State private var preparation: Task<Void, Never>?
    @State private var progressTask: Task<Void, Never>?
    @State private var watchdog: Task<Void, Never>?
    @State private var wasInstalled: Bool?
    @State private var previousRegistration: InstalledApplication?
    @State private var lastProgressAt: TimeInterval?
    @State private var installProgressStale = false
    @State private var payloadRequested = false
    @State private var confirmManualCompletion = false
    @State private var started = false
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var handedOff = false
    @State private var installPage: URL?
    @State private var showsInstallBrowser = false
    @State private var openingSafari = false
    @State private var profileMessage: String?
    @State private var copiedError = false
    @State private var shareURL: URL?

    let app: AppInfoPresentable
    let isSharing: Bool
    let onFinished: ((Error?) -> Void)?

    private enum Stage {
        case packaging, preparing, waitingForApproval, transferring, installing, completed
        case issue(Error, unconfirmed: Bool)
    }

    private var isServerInstall: Bool { !isSharing && !viewModel.isIDevice }

    init(app: AppInfoPresentable, isSharing: Bool = false, onFinished: ((Error?) -> Void)? = nil) {
        self.app = app
        self.isSharing = isSharing
        self.onFinished = onFinished

        let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
        let model = InstallerStatusViewModel(isIdevice: method == 1 && !isSharing)
        _viewModel = StateObject(wrappedValue: model)
        _installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: model))
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }
        }
        .frame(idealWidth: 420)
        .sheet(isPresented: $showsInstallBrowser) {
            if let installPage {
                SafariRepresentableView(url: embeddedInstallPage(installPage)) {
                    showsInstallBrowser = false
                }
                .ignoresSafeArea()
            }
        }
        .onReceive(viewModel.$status, perform: handle)
        .alert("Mark app installed?", isPresented: $confirmManualCompletion) {
            Button("Mark Installed", action: markInstalledManually)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Open the app from your Home Screen first. Mark it installed here once you’ve verified it opens.")
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            if case .issue = stage, profileMessage != nil {
                ShrubInstallReadiness.shared.refresh()
                if PersonalSSL.isTrusted() { profileMessage = "Local profile trusted. Tap Try again to continue." }
            } else if handedOff, recordID != nil {
                BackgroundAudioManager.shared.start(force: true, installation: installer.id)
                _ = checkInstalled()
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            start()
        }
        .onDisappear(perform: closeAttempt)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                Text(isSharing ? "Export IPA" : "Install app")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if onFinished == nil {
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            InstallProgressView(app: app, status: status, detail: detail, progress: progress, tint: tint,
                                showsActivity: showsActivity)
            if case .issue(let error, _) = stage {
                recovery(error)
            } else if case .waitingForApproval = stage, !showsInstallBrowser {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Open in Safari") { openInstallPageInSafari() }
                        .buttonStyle(.borderedProminent)
                        .disabled(openingSafari)
                    Button("Try again in ShrubSign") {
                        finish(ShrubInstallError.handoffTimedOut, unconfirmed: true)
                        retry()
                    }
                    .buttonStyle(.bordered)
                }
            } else if case .completed = stage, onFinished == nil {
                HStack {
                    if let shareURL {
                        ShareLink(item: shareURL)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
            if payloadRequested && (installProgressStale || isInstallUnconfirmed) {
                if isInstallUnconfirmed {
                    Button("Check again") { _ = checkInstalled() }
                        .buttonStyle(.bordered)
                }
                Button("I verified the app opens") { confirmManualCompletion = true }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .padding(24)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
    }

    private var status: LocalizedStringKey {
        switch stage {
        case .packaging: return "Packaging IPA"
        case .preparing: return "Checking install connection"
        case .waitingForApproval: return "Waiting for iOS approval"
        case .transferring: return installProgressStale ? "Checking installation" : "Sending app to iOS"
        case .installing: return installProgressStale ? "Checking installation" : "Installing in iOS"
        case .completed: return isSharing ? "Exported" : "Installed"
        case .issue(_, let unconfirmed): return unconfirmed ? "Install unconfirmed" : "Installation failed"
        }
    }

    private var detail: LocalizedStringKey? {
        switch stage {
        case .waitingForApproval: return "Tap Install on the install page and confirm the iOS prompt."
        case .transferring where installProgressStale:
            return "iOS is handling the installation. Check your Home Screen if the app already appears."
        case .transferring: return isServerInstall ? "Keep ShrubSign open while the IPA transfers." : nil
        case .installing where installProgressStale:
            return "iOS has stopped reporting progress. Check for the app on your Home Screen."
        case .installing: return isServerInstall ? "iOS is finishing the installation." : nil
        default: return nil
        }
    }

    private var progress: Double? {
        switch stage {
        case .packaging: return viewModel.packageProgress
        case .transferring where !isServerInstall: return viewModel.uploadProgress
        case .installing where !installProgressStale && viewModel.installProgress > 0: return min(viewModel.installProgress, 0.99)
        case .completed where !isSharing: return 1
        default: return nil
        }
    }

    private var isInstallUnconfirmed: Bool {
        if case .issue(_, true) = stage { return true }
        return false
    }

    private var showsActivity: Bool {
        switch stage {
        case .completed, .issue: return false
        default: return true
        }
    }

    private var tint: Color {
        switch stage {
        case .completed: return .green
        case .issue(_, let unconfirmed): return unconfirmed ? .orange : .red
        default: return .accentColor
        }
    }

    private var alternateMode: ShrubInstallMode {
        let currentMode = installer.activeMode ?? (mode == .automatic ? ServerInstaller.resolvedMode() : mode)
        return currentMode == .fullyLocal ? .localServer : .fullyLocal
    }

    @ViewBuilder
    private func recovery(_ error: Error) -> some View {
        Text(error.localizedDescription)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 8) {
            if case .selfInstall? = error as? ShrubInstallError {
                EmptyView()
            } else {
                Button("Try again") { retry() }
                    .buttonStyle(.borderedProminent)
                if case .handoffTimedOut? = error as? ShrubInstallError, isServerInstall {
                    Button("Open in Safari") { retry(inSafari: true) }
                        .buttonStyle(.bordered)
                }
                if isServerInstall {
                    Button("Try \(alternateMode.title)") {
                        mode = alternateMode
                        retry()
                    }
                    .buttonStyle(.bordered)
                    if !PersonalSSL.isTrusted() {
                        Button("Install local profile") { openProfileSetup() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            Button(copiedError ? "Copied" : "Copy error details") {
                UIPasteboard.general.string = error.localizedDescription
                copiedError = true
            }
            .buttonStyle(.bordered)
            if let onFinished {
                Button("Skip app") { onFinished(error) }
                    .buttonStyle(.bordered)
            }
        }

        if let profileMessage {
            Text(profileMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func handle(_ status: InstallerStatusViewModel.InstallerStatus) {
        guard recordID != nil else { return }
        switch status {
        case .sendingPayload:
            showsInstallBrowser = false
            if isServerInstall, !payloadRequested {
                payloadRequested = true
                lastProgressAt = ProcessInfo.processInfo.systemUptime
            }
            if case .waitingForApproval = stage { stage = .transferring }
            if !isServerInstall { stage = .transferring }
            if isServerInstall, progressTask == nil {
                installer.keepServerAliveDuringInstall()
                startWatchdog(seconds: 600, waitingForApproval: false)
                pollProgress()
            }
        case .installing:
            stage = .installing
            if isServerInstall {
                lastProgressAt = ProcessInfo.processInfo.systemUptime
                installProgressStale = false
            }
            if isServerInstall { startWatchdog(seconds: 300, waitingForApproval: false) }
        case .completed(let result):
            switch result {
            case .success: finish(nil)
            case .failure(let error): finish(error)
            }
        case .broken(let error):
            finish(error)
        case .none, .ready, .sendingManifest:
            break
        }
    }

    private func start(inSafari: Bool = false) {
        stage = .packaging
        if !isSharing {
            let id = UUID()
            recordID = id
            ShrubSigningCenter.shared.begin(id: id, name: app.name ?? "Unnamed IPA",
                                           bundleID: app.identifier, kind: "Installation")
        }

        if isServerInstall, let identifier = app.identifier, identifier == Bundle.main.bundleIdentifier {
            finish(ShrubInstallError.selfInstall)
            return
        }

        let settings = useShareSheet
        let localInstall = isServerInstall
        preparation = Task { @MainActor in
            do {
                if let file = installer.packageUrl, FileManager.default.isReadableFile(atPath: file.path) {
                    try await install(file, inSafari: inSafari)
                    return
                }
                let package = try await Task.detached(priority: .userInitiated) {
                    let handler = ArchiveHandler(app: app, viewModel: viewModel)
                    do {
                        try await handler.move()
                        let url = try await handler.archive(forLocalInstall: localInstall)
                        if isSharing {
                            let exported = try await handler.moveToArchive(url, shouldOpen: !settings)
                            handler.clean()
                            return (exported, nil as String?)
                        }
                        return (Optional(url), handler.buildVersion)
                    } catch {
                        handler.clean()
                        throw error
                    }
                }.value
                if Task.isCancelled {
                    if !isSharing, let file = package.0 {
                        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    }
                    return
                }
                guard let file = package.0 else { throw ShrubInstallError.missingPackage }
                if isSharing {
                    if settings { shareURL = file }
                    stage = .completed
                } else {
                    installer.packageUrl = file
                    installer.buildVersion = package.1
                    try await install(file, inSafari: inSafari)
                }
            } catch {
                guard !Task.isCancelled else { return }
                finish(error)
                if viewModel.isIDevice { HeartbeatManager.shared.start(true) }
            }
        }
    }

    @MainActor
    private func install(_ package: URL, inSafari: Bool) async throws {
        if !isServerInstall {
            let proxy = InstallationProxy(viewModel: viewModel)
            let isSelfUpdate = app.identifier.map { $0 == Bundle.main.bundleIdentifier } ?? false
            try await proxy.install(at: package, suspend: isSelfUpdate)
            return
        }

        wasInstalled = app.identifier.flatMap { UIApplication.appIsInstalled($0) }
        previousRegistration = app.identifier.flatMap { UIApplication.installedApplication($0) }
        stage = .preparing
        let page = try await installer.prepareInstallHandoff(mode: mode)
        try Task.checkCancellation()

        handedOff = true
        installPage = page
        stage = .waitingForApproval
        installer.keepServerAliveDuringInstall()
        BackgroundAudioManager.shared.start(force: true, installation: installer.id)
        beginBackgroundTask()
        startWatchdog(seconds: 120, waitingForApproval: true)
        if inSafari {
            openInstallPageInSafari()
        } else {
            showsInstallBrowser = true
        }
    }

    private func embeddedInstallPage(_ page: URL) -> URL {
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        components?.fragment = "in-app"
        return components?.url ?? page
    }

    private func openInstallPageInSafari() {
        guard !openingSafari, case .waitingForApproval = stage, let page = installPage, let recordID else { return }
        openingSafari = true
        UIApplication.shared.open(page, options: [:]) { opened in
            guard self.recordID == recordID else { return }
            openingSafari = false
            guard case .waitingForApproval = stage else { return }
            if opened {
                startWatchdog(seconds: 120, waitingForApproval: true)
            } else {
                handedOff = false
                finish(ShrubInstallError.invalidPage)
            }
        }
    }

    private func openProfileSetup() {
        do {
            let url = try ShrubInstallReadiness.shared.installProfile()
            UIApplication.shared.open(url, options: [:]) { opened in
                profileMessage = opened
                    ? "Install the downloaded profile in Settings, then enable its root in Certificate Trust Settings."
                    : "Safari could not open the profile download."
            }
        } catch {
            profileMessage = error.localizedDescription
        }
    }

    private func retry(inSafari: Bool = false) {
        preparation?.cancel()
        preparation = nil
        handedOff = false
        installer.invalidateAttempt()
        profileMessage = nil
        copiedError = false
        payloadRequested = false
        installProgressStale = false
        lastProgressAt = nil
        viewModel.installProgress = 0
        viewModel.uploadProgress = 0
        viewModel.status = .none
        start(inSafari: inSafari)
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ShrubSignInstall") {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func startWatchdog(seconds: UInt64, waitingForApproval: Bool) {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            if checkInstalled() { return }
            let error: ShrubInstallError = waitingForApproval ? .handoffTimedOut : .completionUnconfirmed
            finish(error, unconfirmed: !waitingForApproval)
        }
    }

    private func pollProgress() {
        guard let bundleID = app.identifier, !bundleID.isEmpty else { return }
        let model = viewModel
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                if let raw = UIApplication.installProgress(for: bundleID, makeSynchronous: false),
                   raw.isFinite, raw > model.installProgress {
                    model.installProgress = min(raw, 1)
                    lastProgressAt = now
                    installProgressStale = false
                }
                if let lastProgressAt, now - lastProgressAt >= 8 {
                    installProgressStale = true
                }
                if checkInstalled() { return }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
    }

    @discardableResult
    private func checkInstalled() -> Bool {
        guard payloadRequested, let bundleID = app.identifier,
              let registered = UIApplication.installedApplication(bundleID),
              registered.confirmsInstall(expectedBuild: installer.buildVersion,
                                         previous: previousRegistration, wasAbsent: wasInstalled == false) else {
            return false
        }
        finish(nil)
        return true
    }

    private func markInstalledManually() {
        guard payloadRequested, installProgressStale || isInstallUnconfirmed else { return }
        finish(nil, verifiedByUser: true)
    }

    private func finish(_ error: Error?, unconfirmed: Bool = false, verifiedByUser: Bool = false) {
        if !isSharing, recordID == nil { return }
        if let recordID {
            ShrubSigningCenter.shared.finish(id: recordID, error: error, unconfirmed: unconfirmed,
                                              verifiedByUser: verifiedByUser)
        }
        if !unconfirmed { recordID = nil }
        stopMonitoring()
        if let error {
            stage = .issue(error, unconfirmed: unconfirmed)
        } else {
            stage = .completed
            onFinished?(nil)
        }
    }

    private func stopMonitoring() {
        showsInstallBrowser = false
        openingSafari = false
        installPage = nil
        watchdog?.cancel()
        watchdog = nil
        progressTask?.cancel()
        progressTask = nil
        endBackgroundTask()
        BackgroundAudioManager.shared.stop(installation: installer.id)
        if handedOff {
            installer.keepServerAliveDuringInstall(for: 60)
        } else {
            installer.stopKeepingAlive()
        }
    }

    private func closeAttempt() {
        preparation?.cancel()
        preparation = nil
        if let recordID {
            if !isInstallUnconfirmed {
                ShrubSigningCenter.shared.finish(id: recordID, error: ShrubInstallError.installSheetClosed, unconfirmed: true)
            }
            self.recordID = nil
            stopMonitoring()
        }
    }
}
