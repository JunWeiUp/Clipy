import AppKit

enum ScreenshotGlobalHotKeyManager {
    private static let hotKeyID: UInt32 = 0x5343_524E // 'SCRN'

    static func register() {
        guard PreferencesManager.shared.isScreenshotShortcutEnabled,
              let combo = PreferencesManager.shared.screenshotShortcut else {
            HotKeyManager.shared.unregister(id: hotKeyID)
            return
        }

        HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifierFlags, id: hotKeyID) {
            DispatchQueue.main.async {
                ScreenshotCoordinator.shared.start()
            }
        }
    }
}
