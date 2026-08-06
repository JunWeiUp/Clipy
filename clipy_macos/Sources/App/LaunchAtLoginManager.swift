import Foundation
import ServiceManagement

enum LaunchAtLoginError: LocalizedError {
    case appPathUnavailable
    case launchAgentWriteFailed

    var errorDescription: String? {
        switch self {
        case .appPathUnavailable:
            return "Unable to locate the app executable path."
        case .launchAgentWriteFailed:
            return "Unable to write the Launch Agent plist."
        }
    }
}

enum LaunchAtLoginManager {
    static let bundleIdentifier = "com.yourdomain.ClipyClone"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleIdentifier).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                return true
            case .notRegistered, .notFound:
                return false
            @unknown default:
                return false
            }
        }
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static func syncWithPreference() {
        let wanted = PreferencesManager.shared.launchAtLogin
        guard wanted != isEnabled else { return }
        try? setEnabled(wanted)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            removeLegacyLaunchAgentIfNeeded()
        } else if enabled {
            try installLaunchAgent()
        } else {
            try removeLaunchAgent()
        }
        PreferencesManager.shared.launchAtLogin = enabled
    }

    private static func installLaunchAgent() throws {
        guard let executablePath = Bundle.main.executablePath else {
            throw LaunchAtLoginError.appPathUnavailable
        }

        let plist: [String: Any] = [
            "Label": bundleIdentifier,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Background"
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let directory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: launchAgentURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(getuid())", launchAgentURL.path]
        try process.run()
        process.waitUntilExit()
    }

    private static func removeLaunchAgent() throws {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", launchAgentURL.path]
        try process.run()
        process.waitUntilExit()

        try FileManager.default.removeItem(at: launchAgentURL)
    }

    private static func removeLegacyLaunchAgentIfNeeded() {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return }
        try? removeLaunchAgent()
    }
}
