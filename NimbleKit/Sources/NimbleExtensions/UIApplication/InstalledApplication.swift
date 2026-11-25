import Foundation

public struct InstalledApplication {
    public let bundlePath: String?
    public let buildVersion: String?

    public init(bundlePath: String?, buildVersion: String?) {
        self.bundlePath = bundlePath
        self.buildVersion = buildVersion
    }

    /// Use evidence that the registration belongs to this install attempt.
    public func confirmsInstall(
        expectedBuild: String?,
        previous: Self?,
        wasAbsent: Bool
    ) -> Bool {
        if let expectedBuild, let buildVersion, expectedBuild != buildVersion { return false }
        if wasAbsent { return true }
        guard let previous else { return false }
        if let bundlePath, let oldPath = previous.bundlePath, bundlePath != oldPath { return true }
        if let expectedBuild, let oldBuild = previous.buildVersion {
            return buildVersion == expectedBuild && oldBuild != expectedBuild
        }
        return false
    }
}
