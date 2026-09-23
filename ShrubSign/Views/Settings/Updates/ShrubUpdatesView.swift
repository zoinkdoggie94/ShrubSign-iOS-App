import SwiftUI

/// Only reports release metadata returned by GitHub; it does not install IPAs or infer revocation.
@MainActor
final class ShrubReleaseChecker: ObservableObject {
    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let name: String?
        let tag_name: String
        let html_url: URL
        let target_commitish: String?
        let published_at: Date?
        let assets: [Asset]
    }

    @Published private(set) var release: Release?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    var installedCommit: String { Bundle.main.object(forInfoDictionaryKey: "ShrubSignBuildSHA") as? String ?? "" }
    var isCurrentBuild: Bool? {
        guard let current = release?.target_commitish?.lowercased(), !installedCommit.isEmpty,
              installedCommit != "local", current.range(of: "^[0-9a-f]{12,40}$", options: .regularExpression) != nil
        else { return nil }
        return current.hasPrefix(installedCommit.lowercased()) || installedCommit.lowercased().hasPrefix(current)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let url = URL(string: "https://api.github.com/repos/zoinkdoggie94/ShrubSign-iOS-App/releases/tags/beta")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ShrubSign-iOS", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard response.statusCode == 200 else {
                if response.statusCode == 404 {
                    throw ReleaseError.message("No beta release has been published yet.")
                }
                throw ReleaseError.message("GitHub returned HTTP \(response.statusCode). Try again later.")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            release = try decoder.decode(Release.self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    private enum ReleaseError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}

struct ShrubUpdatesView: View {
    @StateObject private var checker = ShrubReleaseChecker()
    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
    var body: some View {
        Form {
            Section("Installed") {
                LabeledContent("Version", value: installedVersion)
                if !checker.installedCommit.isEmpty && checker.installedCommit != "local" {
                    LabeledContent("Build", value: String(checker.installedCommit.prefix(12)))
                }
            }
            Section("GitHub beta") {
                if checker.isLoading { ProgressView("Checking GitHub…") }
                if let release = checker.release {
                    LabeledContent("Release", value: release.name ?? release.tag_name)
                    if let published = release.published_at {
                        LabeledContent("Published") { Text(published, style: .date) }
                    }
                    if let current = checker.isCurrentBuild {
                        Label(current ? "This is the published beta build." : "GitHub has a different beta build available.",
                              systemImage: current ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(current ? .green : .orange)
                    } else {
                        Text("Build comparison unavailable. You can review the release on GitHub.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Link("View release details", destination: release.html_url)
                    if let ipa = release.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }) {
                        Link("Download \(ipa.name)", destination: ipa.browser_download_url)
                    }
                }
                if let error = checker.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button("Check again", systemImage: "arrow.clockwise") {
                    Task { await checker.refresh() }
                }.disabled(checker.isLoading)
            }
            Section {
                Text("Downloads open through iOS. To install an update, use your existing signing and installation workflow; downloading does not install an IPA.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ShrubSign updates")
        .task { await checker.refresh() }
    }
}
