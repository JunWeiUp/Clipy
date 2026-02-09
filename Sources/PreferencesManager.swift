import Foundation

class PreferencesManager {
    static let shared = PreferencesManager()
    
    private let defaults = UserDefaults.standard
    private let historyLimitKey = "historyLimit"
    private let excludedAppsKey = "excludedApps"
    private let isSyncEnabledKey = "isSyncEnabled"
    private let syncDeviceNameKey = "syncDeviceName"
    private let allowedDevicesKey = "allowedDevices"
    private let deviceLastSyncTimesKey = "deviceLastSyncTimes"
    private let syncKeyKey = "syncKey"
    
    var historyLimit: Int {
        get { defaults.integer(forKey: historyLimitKey) == 0 ? 50 : defaults.integer(forKey: historyLimitKey) }
        set { defaults.set(newValue, forKey: historyLimitKey) }
    }
    
    var excludedApps: [String] {
        get { defaults.stringArray(forKey: excludedAppsKey) ?? ["com.agilebits.onepassword7", "com.apple.keychainaccess"] }
        set { defaults.set(newValue, forKey: excludedAppsKey) }
    }

    var isSyncEnabled: Bool {
        get { defaults.bool(forKey: isSyncEnabledKey) }
        set { defaults.set(newValue, forKey: isSyncEnabledKey) }
    }

    var syncDeviceName: String {
        get { defaults.string(forKey: syncDeviceNameKey) ?? Host.current().localizedName ?? "Mac" }
        set { defaults.set(newValue, forKey: syncDeviceNameKey) }
    }

    var syncKey: String {
        get { defaults.string(forKey: syncKeyKey) ?? "clipy-clone-secret-key-32-chars!!" }
        set { defaults.set(newValue, forKey: syncKeyKey) }
    }
    
    var allowedDevices: Set<String> {
        get { Set(defaults.stringArray(forKey: allowedDevicesKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: allowedDevicesKey) }
    }

    var deviceLastSyncTimes: [String: Date] {
        get { defaults.dictionary(forKey: deviceLastSyncTimesKey) as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: deviceLastSyncTimesKey) }
    }

    func setLastSyncTime(for device: String, date: Date) {
        var times = deviceLastSyncTimes
        times[device] = date
        deviceLastSyncTimes = times
    }
    
    func getLastSyncTime(for device: String) -> Date? {
        return deviceLastSyncTimes[device]
    }
    
    func toggleDeviceAllowance(_ deviceName: String) {
        var devices = allowedDevices
        if devices.contains(deviceName) {
            devices.remove(deviceName)
        } else {
            devices.insert(deviceName)
        }
        allowedDevices = devices
    }
    
    private init() {}
}
