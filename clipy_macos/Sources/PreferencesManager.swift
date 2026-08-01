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
    private let clipboardSyncPeerIdsKey = "clipboardSyncPeerIds"
    private let notificationSyncPeerIdsKey = "notificationSyncPeerIds"
    private let syncPeerIdKey = "syncPeerId"
    private let authorizedPeerIdsMigratedKey = "authorizedPeerIdsMigrated"
    private let dualSyncAuthMigratedKey = "dualSyncAuthMigrated"
    private let deviceNameKey = "deviceName"
    private let appLanguageKey = "appLanguage"
    private let launchAtLoginKey = "launchAtLogin"
    private let historyEncryptionEnabledKey = "historyEncryptionEnabled"
    private let searchGlobalShortcutEnabledKey = "searchGlobalShortcutEnabled"
    private let searchHistoryShortcutKey = "searchHistoryShortcut"
    private let screenshotShortcutEnabledKey = "screenshotShortcutEnabled"
    private let screenshotShortcutKey = "screenshotShortcut"
    private let screenshotDefaultModeKey = "screenshotDefaultMode"
    private let screenshotMagnifierEnabledKey = "screenshotMagnifierEnabled"
    private let screenshotElementSnapEnabledKey = "screenshotElementSnapEnabled"
    private let screenshotAutoSaveEnabledKey = "screenshotAutoSaveEnabled"
    private let screenshotSaveDirectoryKey = "screenshotSaveDirectory"
    private let screenshotResolutionKey = "screenshotResolution"
    private let screenshotPostCaptureActionKey = "screenshotPostCaptureAction"
    private let screenshotOCRLanguageKey = "screenshotOCRLanguage"
    private let screenshotTextFontSizeKey = "screenshotTextFontSize"
    private let screenshotTextBoldKey = "screenshotTextBold"
    private let screenshotTextItalicKey = "screenshotTextItalic"
    private let screenshotTextUnderlineKey = "screenshotTextUnderline"
    private let screenshotTextBackgroundEnabledKey = "screenshotTextBackgroundEnabled"
    
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

    /// Union of clipboard + notification outbound targets (stale UI / discovery hints).
    var authorizedPeerIds: [String] {
        get {
            migrateDualSyncAuthIfNeeded()
            return Array(Set(clipboardSyncPeerIds).union(notificationSyncPeerIds)).sorted()
        }
        set {
            // Legacy single-list writes apply to both capabilities.
            clipboardSyncPeerIds = newValue
            notificationSyncPeerIds = newValue
            defaults.set(newValue, forKey: authorizedPeerIdsKey)
        }
    }

    /// Peers this device may push clipboard/history to (outbound only).
    var clipboardSyncPeerIds: [String] {
        get {
            migrateDualSyncAuthIfNeeded()
            return defaults.stringArray(forKey: clipboardSyncPeerIdsKey) ?? []
        }
        set {
            defaults.set(newValue, forKey: clipboardSyncPeerIdsKey)
            syncAuthorizedPeerIdsUnion()
        }
    }

    /// Peers this device may push notifications to (outbound only).
    var notificationSyncPeerIds: [String] {
        get {
            migrateDualSyncAuthIfNeeded()
            return defaults.stringArray(forKey: notificationSyncPeerIdsKey) ?? []
        }
        set {
            defaults.set(newValue, forKey: notificationSyncPeerIdsKey)
            syncAuthorizedPeerIdsUnion()
        }
    }

    var authorizedDevices: [String] {
        get { defaults.stringArray(forKey: authorizedDevicesKey) ?? [] }
        set { defaults.set(newValue, forKey: authorizedDevicesKey) }
    }

    /// One-shot: copy legacy `authorizedPeerIds` into both capability lists (both on).
    private func migrateDualSyncAuthIfNeeded() {
        guard !defaults.bool(forKey: dualSyncAuthMigratedKey) else { return }
        let legacy = defaults.stringArray(forKey: authorizedPeerIdsKey) ?? []
        if defaults.object(forKey: clipboardSyncPeerIdsKey) == nil {
            defaults.set(legacy, forKey: clipboardSyncPeerIdsKey)
        }
        if defaults.object(forKey: notificationSyncPeerIdsKey) == nil {
            defaults.set(legacy, forKey: notificationSyncPeerIdsKey)
        }
        defaults.set(true, forKey: dualSyncAuthMigratedKey)
        syncAuthorizedPeerIdsUnion()
    }

    private func syncAuthorizedPeerIdsUnion() {
        let union = Array(
            Set(defaults.stringArray(forKey: clipboardSyncPeerIdsKey) ?? [])
                .union(defaults.stringArray(forKey: notificationSyncPeerIdsKey) ?? [])
        ).sorted()
        defaults.set(union, forKey: authorizedPeerIdsKey)
    }

    func setClipboardSync(peerId: String, enabled: Bool) {
        var ids = Set(clipboardSyncPeerIds)
        if enabled { ids.insert(peerId) } else { ids.remove(peerId) }
        clipboardSyncPeerIds = ids.sorted()
    }

    func setNotificationSync(peerId: String, enabled: Bool) {
        var ids = Set(notificationSyncPeerIds)
        if enabled { ids.insert(peerId) } else { ids.remove(peerId) }
        notificationSyncPeerIds = ids.sorted()
    }

    /// Remove a peer from both capability lists (stale offline row delete).
    func removeAuthorizedPeer(_ peerId: String) {
        var clip = Set(clipboardSyncPeerIds)
        var notif = Set(notificationSyncPeerIds)
        clip.remove(peerId)
        notif.remove(peerId)
        clipboardSyncPeerIds = clip.sorted()
        notificationSyncPeerIds = notif.sorted()
    }

    /// Manually configured peers (format "host:port") for cross-band /
    /// cross-subnet discovery when mDNS multicast is isolated by the router.
    private let manualSyncPeersKey = "manualSyncPeers"
    var manualSyncPeers: [String] {
        get { defaults.stringArray(forKey: manualSyncPeersKey) ?? [] }
        set { defaults.set(newValue, forKey: manualSyncPeersKey) }
    }

    func addManualPeer(_ peer: String) {
        var peers = manualSyncPeers
        if !peers.contains(peer) {
            peers.append(peer)
            manualSyncPeers = peers
        }
    }

    func removeManualPeer(_ peer: String) {
        var peers = manualSyncPeers
        peers.removeAll { $0 == peer }
        manualSyncPeers = peers
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

    var screenshotPostCaptureAction: ScreenshotPostCaptureAction {
        get {
            guard let raw = defaults.string(forKey: screenshotPostCaptureActionKey),
                  let action = ScreenshotPostCaptureAction(rawValue: raw) else {
                return .default
            }
            return action
        }
        set { defaults.set(newValue.rawValue, forKey: screenshotPostCaptureActionKey) }
    }

    var screenshotOCRLanguage: ScreenshotOCRLanguage {
        get {
            guard let raw = defaults.string(forKey: screenshotOCRLanguageKey),
                  let language = ScreenshotOCRLanguage(rawValue: raw) else {
                return .default
            }
            return language
        }
        set { defaults.set(newValue.rawValue, forKey: screenshotOCRLanguageKey) }
    }

    var screenshotTextFontSize: CGFloat {
        get {
            let value = defaults.object(forKey: screenshotTextFontSizeKey) as? Double
            return CGFloat(min(96, max(12, value ?? 18)))
        }
        set { defaults.set(Double(min(96, max(12, newValue))), forKey: screenshotTextFontSizeKey) }
    }

    var screenshotTextBold: Bool {
        get { defaults.bool(forKey: screenshotTextBoldKey) }
        set { defaults.set(newValue, forKey: screenshotTextBoldKey) }
    }

    var screenshotTextItalic: Bool {
        get { defaults.bool(forKey: screenshotTextItalicKey) }
        set { defaults.set(newValue, forKey: screenshotTextItalicKey) }
    }

    var screenshotTextUnderline: Bool {
        get { defaults.bool(forKey: screenshotTextUnderlineKey) }
        set { defaults.set(newValue, forKey: screenshotTextUnderlineKey) }
    }

    var screenshotTextBackgroundEnabled: Bool {
        get { defaults.bool(forKey: screenshotTextBackgroundEnabledKey) }
        set { defaults.set(newValue, forKey: screenshotTextBackgroundEnabledKey) }
    }

    static var defaultScreenshotSaveDirectoryPath: String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("ClipyScreenshots", isDirectory: true).path
    }
    
    private init() {}
}
