//
//  SafariWebView.swift
//  NimbleKit
//
//  Created by samara on 30.04.2025.
//

import SwiftUI
import SafariServices

public struct SafariRepresentableView: UIViewControllerRepresentable {
    public let url: URL
    private let onDone: (() -> Void)?

    public init(url: URL, onDone: (() -> Void)? = nil) {
        self.url = url
        self.onDone = onDone
    }

    public func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.onDone = onDone
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone)
    }

    public final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var onDone: (() -> Void)?

        init(onDone: (() -> Void)?) {
            self.onDone = onDone
        }

        public func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDone?()
        }
    }
}
