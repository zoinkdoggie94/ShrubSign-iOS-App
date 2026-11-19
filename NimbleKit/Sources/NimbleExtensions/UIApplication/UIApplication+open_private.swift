//
//  UIApplication+open.swift
//  Feather
//
//  Created by samara on 21.04.2025.
//

import UIKit.UIApplication

extension UIApplication {
	/// Opens an app with an identifier
	/// - Parameter identifier: Application identifier
	static public func openApp(with identifier: String) {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" 			// LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="     			// defaultWorkspace
		let openSelectorBase64 = "b3BlbkFwcGxpY2F0aW9uV2l0aEJ1bmRsZUlEOg==" // openApplicationWithBundleID:
		
		guard
			let classNameData = Data(base64Encoded: classNameBase64),
			let defaultSelectorData = Data(base64Encoded: defaultSelectorBase64),
			let openSelectorData = Data(base64Encoded: openSelectorBase64),
			let className = String(data: classNameData, encoding: .utf8),
			let defaultSelector = String(data: defaultSelectorData, encoding: .utf8),
			let openSelector = String(data: openSelectorData, encoding: .utf8)
		else {
			return
		}
		
		guard
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else {
			return
		}
		
		_ = workspace.perform(NSSelectorFromString(openSelector), with: identifier)
	}
    /// Returns whether an app with this bundle identifier is installed.
    /// - Parameter identifier: Bundle identifier
    /// - Returns: `nil` when the workspace lookup is unavailable
    static public func appIsInstalled(_ identifier: String) -> Bool? {
        guard !identifier.isEmpty else { return nil }

        let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ=="             // LSApplicationWorkspace
        let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="               // defaultWorkspace
        let installedSelectorBase64 = "YXBwbGljYXRpb25Jc0luc3RhbGxlZDo="   // applicationIsInstalled:

        guard
            let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
            let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
            let installedSelectorName = String(data: Data(base64Encoded: installedSelectorBase64)!, encoding: .utf8),
            let workspaceClass = NSClassFromString(className) as? NSObject.Type,
            let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?
                .takeUnretainedValue() as? NSObject
        else { return nil }

        let selector = NSSelectorFromString(installedSelectorName)
        guard workspace.responds(to: selector) else { return nil }

        // A BOOL-returning Objective-C method cannot be read through perform()
        // because that treats the return value as an object. Call it directly.
        typealias IsInstalledFunction = @convention(c) (NSObject, Selector, NSString) -> Bool
        let implementation = workspace.method(for: selector)
        let function = unsafeBitCast(implementation, to: IsInstalledFunction.self)
        return function(workspace, selector, identifier as NSString)
    }

    
    /// Returns install progress for a bundle identifier (0.0 – 1.0)
    /// - Parameters:
    ///   - identifier: Bundle identifier
    ///   - synchronous: Whether the call should block
    /// - Returns: Progress value if available
    static public func installProgress(
        for identifier: String,
        makeSynchronous synchronous: Bool = true
    ) -> Double? {

        let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" // LSApplicationWorkspace
        let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="   // defaultWorkspace
        let progressSelectorBase64 = "aW5zdGFsbFByb2dyZXNzRm9yQnVuZGxlSUQ6bWFrZVN5bmNocm9ub3VzOg==" // installProgressForBundleID:makeSynchronous:

        guard
            let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
            let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
            let progressSelector = String(data: Data(base64Encoded: progressSelectorBase64)!, encoding: .utf8),
            let workspaceClass = NSClassFromString(className) as? NSObject.Type,
            let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
        else { return nil }

        let result = workspace.perform(
            NSSelectorFromString(progressSelector),
            with: identifier,
            with: synchronous
        )?.takeUnretainedValue()

        if let number = result as? Progress {
            return number.fractionCompleted
        }

        return nil
    }
}
