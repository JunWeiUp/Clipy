import Foundation

/// Installed bundle metadata, shared by Settings and the menu-bar panel.
enum AppVersion {
    static let displayString: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }()
}
