import AppKit

/// Local presentation preference; does not change macOS or other devices.
enum AppAppearancePreference: String, CaseIterable {
    case system, light, dark
    static let defaultsKey = "appAppearance"

    static func read(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var displayName: String {
        switch self {
        case .system: return L10n.t(.appearanceSystem)
        case .light: return L10n.t(.appearanceLight)
        case .dark: return L10n.t(.appearanceDark)
        }
    }

    func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
