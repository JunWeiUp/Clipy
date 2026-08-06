import AppKit

extension Notification.Name {
    static let globalHotKeysShouldRegister = Notification.Name("globalHotKeysShouldRegister")
    static let snippetEditorSelectSnippet = Notification.Name("snippetEditorSelectSnippet")
}

enum SearchGlobalHotKeyManager {
    private static let hotKeyID: UInt32 = 0x5345_4152 // 'SEAR'

    static func register() {
        guard PreferencesManager.shared.isSearchGlobalShortcutEnabled,
              let combo = PreferencesManager.shared.searchHistoryShortcut else {
            HotKeyManager.shared.unregister(id: hotKeyID)
            return
        }

        HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifierFlags, id: hotKeyID) {
            DispatchQueue.main.async {
                SearchWindow.shared.showWindow()
            }
        }
    }
}
