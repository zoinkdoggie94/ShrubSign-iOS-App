//
//  InstallProgressView.swift
//  ShrubSign
//
//  Created by samara on 23.04.2025 for Feather.
//

import SwiftUI

struct InstallProgressView: View {
    let app: AppInfoPresentable
    let status: LocalizedStringKey
    let detail: LocalizedStringKey?
    let progress: Double?
    let tint: Color
    let showsActivity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                FRAppIconView(app: app, size: 50)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name ?? "Unnamed IPA")
                        .font(.title3.weight(.semibold))
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(tint)
                }
                Spacer(minLength: 0)
                if showsActivity && progress == nil {
                    ProgressView()
                        .accessibilityLabel(status)
                }
            }
            if let progress, progress.isFinite {
                let value = min(max(progress, 0), 1)
                ProgressView(value: value) {
                    Text("\(Int(value * 100))%")
                        .font(.caption.monospacedDigit())
                }
                .tint(tint)
                .accessibilityLabel(status)
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
