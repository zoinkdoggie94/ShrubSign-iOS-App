//
//  InstallProgressView.swift
//  ShrubSign
//
//  Created by samara on 23.04.2025 for Feather.
//  Polished for ShrubSign 3.2.2: shows what is happening, how far along it is,
//  and stays readable on iPad and in a compact sheet.
//

import SwiftUI
import IDeviceSwift

struct InstallProgressView: View {
    var app: AppInfoPresentable
    @ObservedObject var viewModel: InstallerStatusViewModel

    private var progress: Double {
        min(max(viewModel.overallProgress, 0), 1)
    }

    private var statusTint: Color {
        switch viewModel.status {
        case .broken: return .red
        case .completed: return .green
        case .installing, .sendingPayload: return .accentColor
        default: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            _appIcon()

            VStack(spacing: 3) {
                Text(app.name ?? "Unnamed IPA")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                HStack(spacing: 5) {
                    if case .broken = viewModel.status {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    Text(viewModel.statusLabel)
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(statusTint)
                .animation(.smooth, value: viewModel.statusLabel)
            }

            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .tint(statusTint == .secondary ? .accentColor : statusTint)
                    .frame(maxWidth: 320)
                if progress > 0, !viewModel.isCompleted {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func _appIcon() -> some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.015, progress))
                .stroke(statusTint == .red ? Color.red : Color.accentColor,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
            FRAppIconView(app: app, size: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(width: 74, height: 74)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name ?? "App"), \(Int((progress * 100).rounded())) percent")
    }

}
