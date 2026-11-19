//
//  BulkInstallPreviewView.swift
//  ShrubSign
//
//  Created by Nagata Asami on 27/1/26.
//  3.2.2: iOS can only install one app at a time, so bulk installs now run
//  sequentially through the same validated hand-off used for single installs
//  instead of presenting several local servers at once.
//

import SwiftUI
import NimbleViews

struct BulkInstallPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    var apps: [AppInfoPresentable]

    @State private var _index = 0
    @State private var _results: [BulkInstallResult] = []

    var body: some View {
        VStack(spacing: 0) {
            if _index < apps.count {
                _header()
                _current()
            } else {
                _summary()
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear(perform: _start)
    }

    private func _start() {
        BackgroundAudioManager.shared.start(force: true)
    }

    @ViewBuilder
    private func _header() -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bulk install")
                    .font(.headline)
                Text("App \(_index + 1) of \(apps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .font(.subheadline)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func _current() -> some View {
        let app = apps[_index]
        InstallPreviewView(app: app) { error in
            _results.append(BulkInstallResult(
                name: app.name ?? "Unnamed IPA",
                success: error == nil,
                detail: error?.localizedDescription
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                _index += 1
            }
        }
        .id(app.uuid ?? "index-\(_index)")
    }

    @ViewBuilder
    private func _summary() -> some View {
        let failures = _results.filter { !$0.success }.count
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: failures == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(failures == 0 ? Color.green : Color.orange)

                Text("Bulk install finished")
                    .font(.headline)
                Text(failures == 0
                     ? "\(_results.count) app(s) installed."
                     : "\(_results.count - failures) installed, \(failures) failed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    ForEach(_results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                if let detail = result.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BulkInstallResult: Identifiable {
    let id = UUID()
    let name: String
    let success: Bool
    let detail: String?
}
