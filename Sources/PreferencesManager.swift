import AppKit
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
    private let historyEncryptionEnabledKey = "historyEncryptionEnabled"
    private let searchGlobalShortcutEnabledKey = "searchGlobalShortcutEnabled"
    private let searchHistoryShortcutKey = "searchHistoryShortcut"
    private let collectorSyncEnabledKey = "collectorSyncEnabled"
    private let collectorAlertEnabledKey = "collectorAlertEnabled"
    private let collectorNotificationEnabledKey = "collectorNotificationEnabled"
    private let collectorSmsEnabledKey = "collectorSmsEnabled"
    private let collectorCallEnabledKey = "collectorCallEnabled"
    private let collectorCallLogEnabledKey = "collectorCallLogEnabled"
    private let collectorClipboardEnabledKey = "collectorClipboardEnabled"
    private let collectorLocationEnabledKey = "collectorLocationEnabled"
    private let collectorSystemEnabledKey = "collectorSystemEnabled"
    
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

    var isHistoryEncryptionEnabled: Bool {
        get { defaults.bool(forKey: historyEncryptionEnabledKey) }
        set { defaults.set(newValue, forKey: historyEncryptionEnabledKey) }
    }

    var isSearchGlobalShortcutEnabled: Bool {
        get {
            if defaults.object(forKey: searchGlobalShortcutEnabledKey) == nil { return true }
            return defaults.bool(forKey: searchGlobalShortcutEnabledKey)
        }
        set { defaults.set(newValue, forKey: searchGlobalShortcutEnabledKey) }
    }

    var searchHistoryShortcut: ShortcutCombo? {
        get {
            if let data = defaults.data(forKey: searchHistoryShortcutKey),
               let combo = try? JSONDecoder().decode(ShortcutCombo.self, from: data) {
                return combo
            }
            return ShortcutCombo(keyCode: 0x03, modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: searchHistoryShortcutKey)
            } else {
                defaults.removeObject(forKey: searchHistoryShortcutKey)
            }
        }
    }

    var isCollectorSyncEnabled: Bool {
        get {
            if defaults.object(forKey: collectorSyncEnabledKey) == nil {
                return defaults.object(forKey: "notificationSyncEnabled") as? Bool ?? true
            }
            return defaults.bool(forKey: collectorSyncEnabledKey)
        }
        set { defaults.set(newValue, forKey: collectorSyncEnabledKey) }
    }

    var isCollectorAlertEnabled: Bool {
        get { defaults.object(forKey: collectorAlertEnabledKey) == nil ? true : defaults.bool(forKey: collectorAlertEnabledKey) }
        set { defaults.set(newValue, forKey: collectorAlertEnabledKey) }
    }

    var isCollectorNotificationEnabled: Bool {
        get { defaults.object(forKey: collectorNotificationEnabledKey) == nil ? true : defaults.bool(forKey: collectorNotificationEnabledKey) }
        set { defaults.set(newValue, forKey: collectorNotificationEnabledKey) }
    }

    var isCollectorSmsEnabled: Bool {
        get { defaults.object(forKey: collectorSmsEnabledKey) == nil ? true : defaults.bool(forKey: collectorSmsEnabledKey) }
        set { defaults.set(newValue, forKey: collectorSmsEnabledKey) }
    }

    var isCollectorCallEnabled: Bool {
        get { defaults.object(forKey: collectorCallEnabledKey) == nil ? true : defaults.bool(forKey: collectorCallEnabledKey) }
        set { defaults.set(newValue, forKey: collectorCallEnabledKey) }
    }

    var isCollectorCallLogEnabled: Bool {
        get { defaults.object(forKey: collectorCallLogEnabledKey) == nil ? true : defaults.bool(forKey: collectorCallLogEnabledKey) }
        set { defaults.set(newValue, forKey: collectorCallLogEnabledKey) }
    }

    var isCollectorClipboardEnabled: Bool {
        get { defaults.object(forKey: collectorClipboardEnabledKey) == nil ? true : defaults.bool(forKey: collectorClipboardEnabledKey) }
        set { defaults.set(newValue, forKey: collectorClipboardEnabledKey) }
    }

    var isCollectorLocationEnabled: Bool {
        get { defaults.object(forKey: collectorLocationEnabledKey) == nil ? true : defaults.bool(forKey: collectorLocationEnabledKey) }
        set { defaults.set(newValue, forKey: collectorLocationEnabledKey) }
    }

    var isCollectorSystemEnabled: Bool {
        get { defaults.object(forKey: collectorSystemEnabledKey) == nil ? true : defaults.bool(forKey: collectorSystemEnabledKey) }
        set { defaults.set(newValue, forKey: collectorSystemEnabledKey) }
    }
    
    private init() {}
}
