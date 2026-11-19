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
    @State private var _isPulsing = false

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
            FRAppIconView(app: app, size: 56)
                .opacity(0.2)
                .foregroundStyle(Color.black)

            FRAppIconView(app: app, size: 56)
                .mask(
                    ZStack {
                        Circle().strokeBorder(Color.white, lineWidth: 4.5)
                        PieShape(progress: progress)
                            .scaleEffect(viewModel.isCompleted ? 2.2 : 1)
                            .animation(.smooth, value: viewModel.isCompleted)
                    }
                )
                .scaleEffect(_isPulsing ? 0.94 : 1.0)
                .animation(
                    .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: _isPulsing
                )
                .onAppear { _isPulsing = true }
        }
    }

    struct PieShape: Shape {
        var progress: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            let startAngle = Angle(degrees: -90)
            let endAngle = Angle(degrees: -90 + progress * 360)

            path.move(to: center)
            path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
            path.closeSubpath()

            return path
        }

        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }
    }
}
