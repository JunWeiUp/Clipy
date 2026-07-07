import AppKit
import Foundation

class PreferencesManager {
    static let shared = PreferencesManager()
    
    private let defaults = UserDefaults.standard
    private let historyLimitKey = "historyLimit"
    private let historyLoadCountKey = "historyLoadCount"
    private let excludedAppsKey = "excludedApps"
    private let syncEnabledKey = "syncEnabled"
    private let syncPortKey = "syncPort"
    private let syncSecretKey = "syncSecret"
    private let authorizedDevicesKey = "authorizedDevices"
    private let authorizedPeerIdsKey = "authorizedPeerIds"
    private let syncPeerIdKey = "syncPeerId"
    private let authorizedPeerIdsMigratedKey = "authorizedPeerIdsMigrated"
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
    private let screenshotShortcutEnabledKey = "screenshotShortcutEnabled"
    private let screenshotShortcutKey = "screenshotShortcut"
    private let screenshotDefaultModeKey = "screenshotDefaultMode"
    private let screenshotMagnifierEnabledKey = "screenshotMagnifierEnabled"
    private let screenshotElementSnapEnabledKey = "screenshotElementSnapEnabled"
    private let screenshotAutoSaveEnabledKey = "screenshotAutoSaveEnabled"
    private let screenshotSaveDirectoryKey = "screenshotSaveDirectory"
    private let screenshotResolutionKey = "screenshotResolution"
    
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

    /// 每次从磁盘加载到内存的历史条数（默认 100）
    var historyLoadCount: Int {
        get {
            let value = defaults.integer(forKey: historyLoadCountKey)
            return value == 0 ? 100 : value
        }
        set { defaults.set(newValue, forKey: historyLoadCountKey) }
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

    var syncPeerId: String {
        get {
            if let id = defaults.string(forKey: syncPeerIdKey), !id.isEmpty {
                return id
            }
            let id = UUID().uuidString
            defaults.set(id, forKey: syncPeerIdKey)
            return id
        }
    }

    var authorizedPeerIds: [String] {
        get { defaults.stringArray(forKey: authorizedPeerIdsKey) ?? [] }
        set { defaults.set(newValue, forKey: authorizedPeerIdsKey) }
    }

    var authorizedDevices: [String] {
        get { defaults.stringArray(forKey: authorizedDevicesKey) ?? [] }
        set { defaults.set(newValue, forKey: authorizedDevicesKey) }
    }

    /// Maps legacy display-name authorizations to stable peer IDs when peers are discovered.
    func migrateAuthorizedPeerIds(from peers: [DiscoveredPeer]) {
        guard !defaults.bool(forKey: authorizedPeerIdsMigratedKey) else { return }

        var peerIds = Set(authorizedPeerIds)
        for legacyName in authorizedDevices {
            if let match = peers.first(where: { $0.displayName == legacyName }) {
                peerIds.insert(match.peerId)
            } else {
                // Pre-peerId builds used the mDNS service name as SyncMessage.deviceId.
                peerIds.insert(legacyName)
            }
        }
        authorizedPeerIds = peerIds.sorted()
        defaults.set(true, forKey: authorizedPeerIdsMigratedKey)
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

    var isScreenshotShortcutEnabled: Bool {
        get {
            if defaults.object(forKey: screenshotShortcutEnabledKey) == nil { return true }
            return defaults.bool(forKey: screenshotShortcutEnabledKey)
        }
        set { defaults.set(newValue, forKey: screenshotShortcutEnabledKey) }
    }

    var screenshotShortcut: ShortcutCombo? {
        get {
            if let data = defaults.data(forKey: screenshotShortcutKey),
               let combo = try? JSONDecoder().decode(ShortcutCombo.self, from: data) {
                return combo
            }
            return ShortcutCombo(keyCode: 0x17, modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: screenshotShortcutKey)
            } else {
                defaults.removeObject(forKey: screenshotShortcutKey)
            }
        }
    }

    var screenshotDefaultMode: ScreenshotCaptureMode {
        get {
            guard let raw = defaults.string(forKey: screenshotDefaultModeKey),
                  let mode = ScreenshotCaptureMode(rawValue: raw) else {
                return .region
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: screenshotDefaultModeKey) }
    }

    var isScreenshotMagnifierEnabled: Bool {
        get {
            if defaults.object(forKey: screenshotMagnifierEnabledKey) == nil { return true }
            return defaults.bool(forKey: screenshotMagnifierEnabledKey)
        }
        set { defaults.set(newValue, forKey: screenshotMagnifierEnabledKey) }
    }

    var isScreenshotElementSnapEnabled: Bool {
        get {
            if defaults.object(forKey: screenshotElementSnapEnabledKey) == nil { return true }
            return defaults.bool(forKey: screenshotElementSnapEnabledKey)
        }
        set { defaults.set(newValue, forKey: screenshotElementSnapEnabledKey) }
    }

    var isScreenshotAutoSaveEnabled: Bool {
        get { defaults.bool(forKey: screenshotAutoSaveEnabledKey) }
        set { defaults.set(newValue, forKey: screenshotAutoSaveEnabledKey) }
    }

    var screenshotSaveDirectoryPath: String {
        get {
            if let path = defaults.string(forKey: screenshotSaveDirectoryKey), !path.isEmpty {
                return path
            }
            return Self.defaultScreenshotSaveDirectoryPath
        }
        set { defaults.set(newValue, forKey: screenshotSaveDirectoryKey) }
    }

    var screenshotSaveDirectory: URL {
        URL(fileURLWithPath: screenshotSaveDirectoryPath, isDirectory: true)
    }

    var screenshotResolution: ScreenshotResolution {
        get {
            if let raw = defaults.string(forKey: screenshotResolutionKey),
               let resolution = ScreenshotResolution(rawValue: raw) {
                return resolution
            }
            if defaults.object(forKey: screenshotResolutionKey) != nil {
                return ScreenshotResolution.fromLegacyDPI(defaults.integer(forKey: screenshotResolutionKey)) ?? .default
            }
            return .default
        }
        set { defaults.set(newValue.rawValue, forKey: screenshotResolutionKey) }
    }

    static var defaultScreenshotSaveDirectoryPath: String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("ClipyScreenshots", isDirectory: true).path
    }
    
    private init() {}
}
