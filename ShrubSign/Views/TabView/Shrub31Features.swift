// ShrubSign 3.1: real signing history, per-app rules, IPA inspection and tweak profiles.
import SwiftUI
import CoreData
import Foundation

// MARK: - Signing Center: persists real results, not simulated progress.
struct ShrubSigningRecord: Codable, Identifiable {
    let id: UUID
    let appName: String
    let bundleID: String?
    let kind: String?
    let started: Date
    var finished: Date?
    var status: String
    var message: String?
}

final class ShrubSigningCenter: ObservableObject {
    static let shared = ShrubSigningCenter()
    @Published private(set) var records: [ShrubSigningRecord] = []
    private let key = "ShrubSign.signingCenter.history.v1"
    private init() {
        if let bytes = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([ShrubSigningRecord].self, from: bytes) {
            records = saved.map { item in
                var copy = item
                if copy.status == "Signing" || copy.status == "Installing" {
                    copy.status = "Interrupted"
                    copy.message = "The app closed before this signing operation reported a result."
                    copy.finished = Date()
                }
                return copy
            }
            persist()
        }
    }
    func begin(id: UUID, name: String, bundleID: String?, kind: String = "Signing") {
        records.insert(ShrubSigningRecord(id: id, appName: name, bundleID: bundleID, kind: kind,
            started: Date(), finished: nil, status: kind == "Installation" ? "Installing" : "Signing", message: nil), at: 0)
        if records.count > 100 { records = Array(records.prefix(100)) }
        persist()
    }
    func finish(id: UUID, error: Error?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = error == nil ? "Completed" : "Failed"
        records[index].finished = Date()
        // Avoid persisting URL query strings or sensitive paths from third-party errors.
        if let error {
            let raw = error.localizedDescription
            records[index].message = raw.components(separatedBy: "?").first.map { String($0.prefix(220)) }
        }
        persist()
    }
    func clearCompleted() {
        records.removeAll { $0.status != "Signing" && $0.status != "Installing" }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct ShrubSigningCenterView: View {
    @StateObject private var center = ShrubSigningCenter.shared
    var body: some View {
        List {
            Section {
                Label("Signing and installation results from this device. Revisit Library to retry failed operations.", systemImage: "checkmark.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink { LibraryView() } label: { Label("Open Library to sign or retry", systemImage: "square.stack") }
            }
            Section("Signing activity") {
                if center.records.isEmpty {
                    Label("No signing operations yet", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                }
                ForEach(center.records) { record in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: record.status == "Completed" ? "checkmark.circle.fill" :
                            record.status == "Signing" ? "hourglass.circle" : "exclamationmark.circle.fill")
                            .foregroundStyle(record.status == "Completed" ? Color.green :
                                record.status == "Signing" ? Color.orange : Color.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.appName).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text("\(record.kind ?? "Signing") · \(record.status)")
                                .font(.caption.weight(.medium))
                            Text(record.started.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                            if let detail = record.message {
                                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                }
            }
            if !center.records.isEmpty {
                Section { Button("Clear completed history", role: .destructive) { center.clearCompleted() } }
            }
        }
        .navigationTitle("Signing & Installation")
    }
}

// MARK: - Per-app Quick Sign rules, referencing existing saved presets only.
struct ShrubQuickRule: Codable {
    let presetID: UUID?
    var autoInstall: Bool
}

final class ShrubQuickRules: ObservableObject {
    static let shared = ShrubQuickRules()
    @Published private(set) var rules: [String: ShrubQuickRule] = [:]
    private let key = "ShrubSign.quickRules.v1"
    private init() {
        if let bytes = UserDefaults.standard.data(forKey: key),
           let existing = try? JSONDecoder().decode([String: ShrubQuickRule].self, from: bytes) { rules = existing }
    }
    func rule(for bundle: String?) -> ShrubQuickRule? {
        guard let bundle, !bundle.isEmpty else { return nil }
        return rules[bundle.lowercased()]
    }
    func set(bundle: String, rule: ShrubQuickRule?) {
        let key = bundle.lowercased()
        if let rule { rules[key] = rule } else { rules.removeValue(forKey: key) }
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: self.key) }
    }
}

struct ShrubQuickRuleEditor: View {
    let bundleID: String
    @StateObject private var rules = ShrubQuickRules.shared
    @StateObject private var presets = ShrubSigningPresets.shared
    @State private var selected = ""
    @State private var autoInstall = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section {
                LabeledContent("Bundle ID", value: bundleID).font(.footnote)
                Picker("Signing preset", selection: $selected) {
                    Text("Use default preset").tag("")
                    ForEach(presets.presets) { item in Text(item.name).tag(item.id.uuidString) }
                }
                Toggle("Install after Quick Sign", isOn: $autoInstall)
            } header: {
                Text("For this app")
            } footer: {
                Text("Quick Sign applies this app's saved preset when available. If no rule is saved, your default signing preset is used.")
            }
            Section {
                Button("Save app rule") {
                    rules.set(bundle: bundleID, rule: ShrubQuickRule(presetID: UUID(uuidString: selected), autoInstall: autoInstall))
                    dismiss()
                }
                Button("Remove app rule", role: .destructive) { rules.set(bundle: bundleID, rule: nil); dismiss() }
            }
        }
        .navigationTitle("Quick Sign Rule")
        .onAppear {
            if let saved = rules.rule(for: bundleID) {
                selected = saved.presetID?.uuidString ?? ""
                autoInstall = saved.autoInstall
            }
        }
    }
}

// MARK: - Tweak Studio: named reusable tweak selections.
struct ShrubTweakProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    var filenames: [String]
    var intoExtensions: Bool
}

final class ShrubTweakProfiles: ObservableObject {
    static let shared = ShrubTweakProfiles()
    @Published private(set) var profiles: [ShrubTweakProfile] = []
    private let key = "ShrubSign.tweakProfiles.v1"
    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let existing = try? JSONDecoder().decode([ShrubTweakProfile].self, from: data) { profiles = existing }
    }
    func save(name: String, files: [URL], extensions: Bool) {
        let valid = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.lastPathComponent)
        var seen = Set<String>()
        let unique = valid.filter { seen.insert($0).inserted }
        profiles.append(ShrubTweakProfile(id: UUID(), name: name, filenames: unique, intoExtensions: extensions))
        persist()
    }
    func delete(_ profile: ShrubTweakProfile) { profiles.removeAll { $0.id == profile.id }; persist() }
    func resolvedFiles(for profile: ShrubTweakProfile) -> [URL] {
        let directory = FileManager.default.tweaks
        return profile.filenames.compactMap { name -> URL? in
            // Store filenames, not arbitrary absolute paths supplied by presets.
            guard name == (name as NSString).lastPathComponent else { return nil }
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
    private func persist() {
        if let bytes = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(bytes, forKey: key) }
    }
}

// MARK: - IPA Inspector: reads app bundles directly; no remote dependencies.
struct ShrubIPAReport {
    let displayName: String
    let bundleID: String
    let version: String
    let executable: String
    let minimumOS: String
    let architectures: String
    let appExtensions: Int
    let frameworks: Int
    let dynamicLibraries: Int
    let bytes: Int64
    let isExecutablePresent: Bool
    let warnings: [String]
    var printable: String {
        "App: \(displayName)\nBundle: \(bundleID)\nVersion: \(version)\nExecutable: \(executable)\nMinimum iOS: \(minimumOS)\nArchitecture: \(architectures)\nExtensions: \(appExtensions)\nFrameworks: \(frameworks)\nDynamic libraries: \(dynamicLibraries)\nExtracted size: \(bytes) bytes\n" + warnings.joined(separator: "\n")
    }
    static func inspect(_ directory: URL) -> ShrubIPAReport {
        let data = (NSDictionary(contentsOf: directory.appendingPathComponent("Info.plist")) as? [String: Any]) ?? [:]
        func value(_ key: String) -> String { data[key] as? String ?? "Unknown" }
        let executable = value("CFBundleExecutable")
        let binaryURL = directory.appendingPathComponent(executable)
        let exists = executable != "Unknown" && FileManager.default.fileExists(atPath: binaryURL.path)
        var architectures = "Unknown"
        if exists, let handle = try? FileHandle(forReadingFrom: binaryURL) {
            let header = handle.readData(ofLength: 8)
            try? handle.close()
            if header.count >= 8 {
                let magic = Array(header.prefix(4))
                if magic == [0xcf, 0xfa, 0xed, 0xfe] { architectures = "64-bit Mach-O" }
                else if magic == [0xca, 0xfe, 0xba, 0xbe] || magic == [0xbe, 0xba, 0xfe, 0xca] { architectures = "Fat / universal Mach-O" }
                else if magic == [0xce, 0xfa, 0xed, 0xfe] { architectures = "32-bit Mach-O" }
                else { architectures = "Unrecognized executable header" }
            }
        }
        let extensionsDirectory = directory.appendingPathComponent("PlugIns")
        let frameworkDirectory = directory.appendingPathComponent("Frameworks")
        let fm = FileManager.default
        let extensions = (try? fm.contentsOfDirectory(at: extensionsDirectory, includingPropertiesForKeys: nil)) ?? []
        let frameworks = (try? fm.contentsOfDirectory(at: frameworkDirectory, includingPropertiesForKeys: nil)) ?? []
        var total: Int64 = 0
        if let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let url as URL in walker {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        var warnings: [String] = []
        if data.isEmpty { warnings.append("Info.plist could not be read.") }
        if !exists { warnings.append("The declared executable is missing.") }
        if architectures == "32-bit Mach-O" { warnings.append("32-bit apps cannot run on modern iOS.") }
        if !fm.fileExists(atPath: directory.appendingPathComponent("embedded.mobileprovision").path) {
            warnings.append("No embedded provisioning profile found. This may be expected before signing.")
        }
        return ShrubIPAReport(displayName: value("CFBundleDisplayName") == "Unknown" ? value("CFBundleName") : value("CFBundleDisplayName"),
            bundleID: value("CFBundleIdentifier"), version: value("CFBundleShortVersionString"),
            executable: executable, minimumOS: value("MinimumOSVersion"), architectures: architectures,
            appExtensions: extensions.filter { $0.pathExtension == "appex" }.count,
            frameworks: frameworks.filter { $0.pathExtension == "framework" }.count,
            dynamicLibraries: frameworks.filter { $0.pathExtension == "dylib" }.count,
            bytes: total, isExecutablePresent: exists, warnings: warnings)
    }
}

struct ShrubIPAInspectorView: View {
    let app: AppInfoPresentable
    @State private var report: ShrubIPAReport?
    @State private var comparison: ShrubIPAReport?
    @State private var errorText: String?
    @FetchRequest(entity: Signed.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)])
    private var signedApps: FetchedResults<Signed>
    @FetchRequest(entity: Imported.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)])
    private var importedApps: FetchedResults<Imported>
    var body: some View {
        List {
            Section {
                Label("IPA Inspector reads the imported application bundle on this device.", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let report {
                Section("Bundle information") {
                    LabeledContent("Name", value: report.displayName)
                    LabeledContent("Bundle ID", value: report.bundleID)
                    LabeledContent("Version", value: report.version)
                    LabeledContent("Minimum iOS", value: report.minimumOS)
                    LabeledContent("Executable", value: report.executable)
                    LabeledContent("Architecture", value: report.architectures)
                }
                Section("Contents") {
                    LabeledContent("Extensions", value: String(report.appExtensions))
                    LabeledContent("Frameworks", value: String(report.frameworks))
                    LabeledContent("Dylibs", value: String(report.dynamicLibraries))
                    LabeledContent("Extracted size", value: ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file))
                }
                Section("Compatibility checks") {
                    Label(report.isExecutablePresent ? "Main executable found" : "Main executable missing",
                          systemImage: report.isExecutablePresent ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(report.isExecutablePresent ? Color.green : Color.red)
                    ForEach(report.warnings, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if report.warnings.isEmpty { Text("No structural warnings detected.").foregroundStyle(.secondary) }
                    Text("This is a structural inspection, not malware detection or a guarantee the app will install.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let comparison {
                    Section("Before & after signing") {
                        Text("Compared with a saved \(app.isSigned ? "imported" : "signed") app using the same bundle identifier.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Bundle identifier", value: report.bundleID == comparison.bundleID ? "Unchanged" : "Changed")
                        LabeledContent("Version", value: report.version == comparison.version ? "Unchanged" : "Changed")
                        LabeledContent("Framework count", value: report.frameworks == comparison.frameworks ? "Unchanged" : "\(comparison.frameworks) → \(report.frameworks)")
                        LabeledContent("Dylib count", value: report.dynamicLibraries == comparison.dynamicLibraries ? "Unchanged" : "\(comparison.dynamicLibraries) → \(report.dynamicLibraries)")
                        Text("Only available bundle metadata is compared; this is not a binary cryptographic diff.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section { ShareLink("Share inspection report", item: report.printable) }
            } else if let errorText {
                Section { Text(errorText).foregroundStyle(.secondary) }
            } else { Section { ProgressView("Inspecting imported app…") } }
        }
        .navigationTitle("IPA Inspector")
        .task(id: app.uuid ?? "unknown") {
            guard let directory = Storage.shared.getAppDirectory(for: app) else {
                errorText = "The imported app directory could not be located."
                return
            }
            let value = await Task.detached(priority: .utility) { ShrubIPAReport.inspect(directory) }.value
            guard !Task.isCancelled else { return }
            report = value
            let other: AppInfoPresentable? = app.isSigned
                ? (importedApps.first(where: { $0.identifier == app.identifier }) as AppInfoPresentable?)
                : (signedApps.first(where: { $0.identifier == app.identifier }) as AppInfoPresentable?)
            if let other, let otherURL = Storage.shared.getAppDirectory(for: other) {
                comparison = await Task.detached(priority: .utility) { ShrubIPAReport.inspect(otherURL) }.value
            }
        }
    }
}
