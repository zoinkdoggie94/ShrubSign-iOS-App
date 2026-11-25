//
//  UIApplication+open.swift
//  Feather
//
//  Created by samara on 21.04.2025.
//

import UIKit.UIApplication
import ObjectiveC

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

        guard let workspace = installWorkspace() else { return nil }

        let selector = NSSelectorFromString("applicationIsInstalled:")
        guard workspace.responds(to: selector), let method = workspace.method(for: selector) else { return nil }
        typealias IsInstalled = @convention(c) (NSObject, Selector, NSString) -> Bool
        return unsafeBitCast(method, to: IsInstalled.self)(workspace, selector, identifier as NSString)
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

        let selector = NSSelectorFromString("installProgressForBundleID:makeSynchronous:")
        guard let workspace = installWorkspace(),
              workspace.responds(to: selector), let method = workspace.method(for: selector) else { return nil }

        // The last argument in this Objective-C method is a scalar. Calling
        // perform(_:with:with:) passes a boxed object instead of a BOOL.
        typealias InstallProgress = @convention(c) (NSObject, Selector, NSString, Bool) -> Unmanaged<AnyObject>?
        let function = unsafeBitCast(method, to: InstallProgress.self)
        let progress = function(workspace, selector, identifier as NSString, synchronous)?.takeUnretainedValue()
        return (progress as? Progress)?.fractionCompleted
    }

    /// A registered application, excluding the placeholder shown during installation.
    static public func installedApplication(_ identifier: String) -> InstalledApplication? {
        let selector = NSSelectorFromString("applicationProxyForIdentifier:")
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type,
              class_getClassMethod(proxyClass, selector) != nil,
              let proxy = proxyClass.perform(selector, with: identifier)?.takeUnretainedValue() as? NSObject else {
            return nil
        }

        let placeholder = NSSelectorFromString("isPlaceholder")
        guard proxy.responds(to: placeholder), let method = proxy.method(for: placeholder) else { return nil }
        typealias IsPlaceholder = @convention(c) (NSObject, Selector) -> Bool
        guard !unsafeBitCast(method, to: IsPlaceholder.self)(proxy, placeholder),
              appIsInstalled(identifier) != false else { return nil }

        let bundleURL = NSSelectorFromString("bundleURL")
        let version = NSSelectorFromString("bundleVersion")
        let url = proxy.responds(to: bundleURL) ? proxy.perform(bundleURL)?.takeUnretainedValue() as? URL : nil
        let build = proxy.responds(to: version) ? proxy.perform(version)?.takeUnretainedValue() as? String : nil
        guard url?.isFileURL == true || build != nil else { return nil }
        return InstalledApplication(bundlePath: url?.standardizedFileURL.path, buildVersion: build)
    }

    private static func installWorkspace() -> NSObject? {
        let selector = NSSelectorFromString("defaultWorkspace")
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              class_getClassMethod(workspaceClass, selector) != nil else { return nil }
        return workspaceClass.perform(selector)?.takeUnretainedValue() as? NSObject
    }
}
