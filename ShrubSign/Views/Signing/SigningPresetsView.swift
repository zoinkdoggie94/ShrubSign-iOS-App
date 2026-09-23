// ShrubSign 2.1 · Reusable signing settings. Never persists keys or passwords.
import SwiftUI
import CoreData

struct ShrubSigningPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var certificateUUID: String?
    var options: Options
}

final class ShrubSigningPresets: ObservableObject {
    static let shared = ShrubSigningPresets()
    @Published private(set) var presets: [ShrubSigningPreset] = []
    @Published private(set) var defaultID: UUID?
    private let key = "ShrubSign.signingPresets.v1"
    private let defaultKey = "ShrubSign.signingPresets.default"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([ShrubSigningPreset].self, from: data) {
            presets = list
        }
        if let text = UserDefaults.standard.string(forKey: defaultKey) { defaultID = UUID(uuidString: text) }
    }

    var preferred: ShrubSigningPreset? { presets.first { $0.id == defaultID } }

    func save(name: String, options: Options, certificateUUID: String?) {
        var copy = options
        // Identity, name and version are app-specific. A reusable preset must not
        // carry those values into a different application.
        copy.appName = nil
        copy.appIdentifier = nil
        copy.appVersion = nil
        copy.appEntitlementsFile = nil
        copy.injectionFiles = copy.injectionFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        let preset = ShrubSigningPreset(id: UUID(), name: name, certificateUUID: certificateUUID, options: copy)
        presets.append(preset)
        persist()
    }

    func rename(_ preset: ShrubSigningPreset, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = name
        persist()
    }

    func delete(_ preset: ShrubSigningPreset) {
        presets.removeAll { $0.id == preset.id }
        if defaultID == preset.id { setDefault(nil) }
        persist()
    }

    func setDefault(_ id: UUID?) {
        defaultID = id
        UserDefaults.standard.set(id?.uuidString, forKey: defaultKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct SigningPresetsView: View {
    @Binding var options: Options
    @Binding var certificateIndex: Int
    @StateObject private var store = ShrubSigningPresets.shared
    @FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)])
    private var certificates: FetchedResults<CertificatePair>
    @State private var newName = ""
    @State private var renameName = ""
    @State private var renameTarget: ShrubSigningPreset?
    @State private var showingSave = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Button { showingSave = true } label: { Label("Save current settings as preset", systemImage: "plus.circle.fill") }
            } footer: {
                Text("Presets remember signing options and a certificate reference. Private keys and passwords are never copied into presets. App-specific names and identifiers are not reused.")
            }
            Section("Saved presets") {
                if store.presets.isEmpty {
                    Text("No presets saved yet.").foregroundStyle(.secondary)
                }
                ForEach(store.presets) { preset in
                    Button {
                        apply(preset)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name).foregroundStyle(.primary)
                                Text(certificateName(for: preset)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.defaultID == preset.id {
                                Image(systemName: "star.fill").foregroundStyle(.tint)
                            }
                            Image(systemName: "checkmark.circle").foregroundStyle(.tint)
                        }
                    }
                    .contextMenu {
                        Button("Set as default", systemImage: "star") { store.setDefault(preset.id) }
                        Button("Rename", systemImage: "pencil") {
                            renameTarget = preset
                            renameName = preset.name
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(preset) }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { store.delete(preset) }
                    }
                }
            }
            if store.defaultID != nil {
                Section {
                    Button("Clear default preset") { store.setDefault(nil) }
                }
            }
        }
        .navigationTitle("Signing Presets")
        .alert("Save signing preset", isPresented: $showingSave) {
            TextField("Preset name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let uuid = certificates.indices.contains(certificateIndex) ? certificates[certificateIndex].uuid : nil
                store.save(name: name, options: options, certificateUUID: uuid)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: { Text("Save your current certificate selection and signing preferences.") }
        .alert("Rename preset", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Preset name", text: $renameName)
            Button("Save") {
                if let target = renameTarget {
                    let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { store.rename(target, to: name) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Cannot apply preset", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func certificateName(for preset: ShrubSigningPreset) -> String {
        guard let uuid = preset.certificateUUID else { return "No certificate (ad hoc / modify-only)" }
        return certificates.first(where: { $0.uuid == uuid })?.nickname ?? "Certificate unavailable"
    }

    private func apply(_ preset: ShrubSigningPreset) {
        if let uuid = preset.certificateUUID {
            guard let index = certificates.firstIndex(where: { $0.uuid == uuid }) else {
                errorMessage = "This preset's certificate is no longer imported. Import it again or choose another preset."
                return
            }
            if let expiry = certificates[index].expiration, expiry <= Date() {
                errorMessage = "This preset's certificate has expired. Choose another certificate before signing."
                return
            }
            certificateIndex = index
        } else if !preset.options.doAdhocSigning && !preset.options.onlyModify {
            errorMessage = "This preset has no signing certificate. Choose a certificate before applying it."
            return
        }
        var copy = preset.options
        copy.injectionFiles = copy.injectionFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        // Keep current per-app customizations instead of importing another app's identity.
        copy.appName = options.appName
        copy.appIdentifier = options.appIdentifier
        copy.appVersion = options.appVersion
        options = copy
        dismiss()
    }
}

// Manage saved profiles from Settings; applying to an app remains in its signing screen.
struct ShrubPresetSettingsView: View {
    @StateObject private var store = ShrubSigningPresets.shared
    var body: some View {
        List {
            Section {
                Text("Create and apply presets from an app's signing screen. Hold a preset to set it as your default or delete it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Saved presets") {
                ForEach(store.presets) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        if preset.id == store.defaultID { Label("Default", systemImage: "star.fill").foregroundStyle(.tint) }
                    }
                    .contextMenu {
                        Button("Set as default", systemImage: "star") { store.setDefault(preset.id) }
                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(preset) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { store.delete(preset) } }
                }
            }
            if store.defaultID != nil {
                Button("Clear default preset") { store.setDefault(nil) }
            }
        }
        .navigationTitle("Signing Presets")
    }
}
