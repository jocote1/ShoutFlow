import Foundation
import ServiceManagement

public enum LaunchAtLogin {
    private static let launchAgentPlistName = "no.hnhvgs.shoutflow.plist"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(launchAgentPlistName)
    }

    public static var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                // If running within an .app bundle
                if Bundle.main.bundleURL.pathExtension == "app" {
                    return SMAppService.mainApp.status == .enabled
                }
            }
            return FileManager.default.fileExists(atPath: launchAgentURL.path)
        }
        set {
            setLaunchAtLogin(newValue)
        }
    }

    public static func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            if Bundle.main.bundleURL.pathExtension == "app" {
                do {
                    if enabled {
                        if SMAppService.mainApp.status != .enabled {
                            try SMAppService.mainApp.register()
                        }
                    } else {
                        if SMAppService.mainApp.status == .enabled {
                            try SMAppService.mainApp.unregister()
                        }
                    }
                    return
                } catch {
                    print("[ShoutFlow] SMAppService failed (\(error.localizedDescription)). Using LaunchAgent fallback.")
                }
            }
        }

        // Fallback using LaunchAgent plist
        let fm = FileManager.default
        let plistURL = launchAgentURL

        if enabled {
            let appPath: String
            if Bundle.main.bundleURL.pathExtension == "app" {
                appPath = Bundle.main.executableURL?.path ?? Bundle.main.bundlePath
            } else {
                appPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
            }

            let plistDict: [String: Any] = [
                "Label": "no.hnhvgs.shoutflow",
                "ProgramArguments": [appPath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]

            let parentDir = plistURL.deletingLastPathComponent()
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

            if let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) {
                try? data.write(to: plistURL)
            }
        } else {
            try? fm.removeItem(at: plistURL)
        }
    }
}
