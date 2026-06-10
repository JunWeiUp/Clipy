import Foundation

class PreferencesManager {
    static let shared = PreferencesManager()
    
    private let defaults = UserDefaults.standard
    private let historyLimitKey = "historyLimit"
    private let excludedAppsKey = "excludedApps"
    private let syncEnabledKey = "syncEnabled"
    private let syncPortKey = "syncPort"
    private let syncSecretKey = "syncSecret"
    private let authorizedDevicesKey = "authorizedDevices"
    private let deviceNameKey = "deviceName"
    private let appLanguageKey = "appLanguage"
    private let launchAtLoginKey = "launchAtLogin"
    
    var deviceName: String {
        get { defaults.string(forKey: deviceNameKey) ?? Host.current().localizedName ?? "Mac" }
        set { defaults.set(newValue, forKey: deviceNameKey) }
    }

    var appLanguage: AppLanguage {
        get {
            guard let rawValue = defaults.string(forKey: appLanguageKey),
                  let language = AppLanguage(rawValue: rawValue) else {
                return AppLanguage.systemDefault
            }
            return language
        }
        set {
            guard appLanguage != newValue else { return }
            defaults.set(newValue.rawValue, forKey: appLanguageKey)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }
    
    var historyLimit: Int {
        get { defaults.integer(forKey: historyLimitKey) == 0 ? 1000 : defaults.integer(forKey: historyLimitKey) }
        set { defaults.set(newValue, forKey: historyLimitKey) }
    }
    
    var excludedApps: [String] {
        get { defaults.stringArray(forKey: excludedAppsKey) ?? ["com.agilebits.onepassword7", "com.apple.keychainaccess"] }
        set { defaults.set(newValue, forKey: excludedAppsKey) }
    }

    var isSyncEnabled: Bool {
        get { defaults.bool(forKey: syncEnabledKey) }
        set { defaults.set(newValue, forKey: syncEnabledKey) }
    }

    var syncPort: Int {
        get { 
            let port = defaults.integer(forKey: syncPortKey)
            return port == 0 ? 5566 : port
        }
        set { defaults.set(newValue, forKey: syncPortKey) }
    }

    var syncSecret: String {
        get { 
            if let secret = defaults.string(forKey: syncSecretKey) {
                return secret
            }
            let newSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            defaults.set(newSecret, forKey: syncSecretKey)
            return newSecret
        }
        set { defaults.set(newValue, forKey: syncSecretKey) }
    }

    var authorizedDevices: [String] {
        get { defaults.stringArray(forKey: authorizedDevicesKey) ?? [] }
        set { defaults.set(newValue, forKey: authorizedDevicesKey) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: launchAtLoginKey) }
        set { defaults.set(newValue, forKey: launchAtLoginKey) }
    }
    
    private init() {}
}
