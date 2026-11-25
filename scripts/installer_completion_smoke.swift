import Foundation

@main
struct InstallerCompletionSmoke {
    static func main() {
        let previous = InstalledApplication(bundlePath: "/old/App.app", buildVersion: "3")
        let reinstalled = InstalledApplication(bundlePath: "/new/App.app", buildVersion: "3")
        let updated = InstalledApplication(bundlePath: "/old/App.app", buildVersion: "4")
        let versionHidden = InstalledApplication(bundlePath: "/new/App.app", buildVersion: nil)
        let pathHidden = InstalledApplication(bundlePath: nil, buildVersion: "3")

        precondition(reinstalled.confirmsInstall(expectedBuild: "3", previous: previous, wasAbsent: false))
        precondition(updated.confirmsInstall(expectedBuild: "4", previous: previous, wasAbsent: false))
        precondition(versionHidden.confirmsInstall(expectedBuild: "3", previous: previous, wasAbsent: false))
        precondition(pathHidden.confirmsInstall(expectedBuild: "3", previous: nil, wasAbsent: true))
        precondition(!previous.confirmsInstall(expectedBuild: "3", previous: previous, wasAbsent: false))
        precondition(!reinstalled.confirmsInstall(expectedBuild: "4", previous: previous, wasAbsent: false))
        precondition(!reinstalled.confirmsInstall(expectedBuild: "3", previous: nil, wasAbsent: false))
        precondition(!pathHidden.confirmsInstall(expectedBuild: "3", previous: previous, wasAbsent: false))
        print("Install completion regression checks passed.")
    }
}
