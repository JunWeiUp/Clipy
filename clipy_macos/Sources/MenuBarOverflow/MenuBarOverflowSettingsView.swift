import SwiftUI

struct MenuBarOverflowSettingsView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject private var manager = MenuBarOverflowManager.shared
    var body: some View {
        let _ = languageObserver.revision
        Toggle(L10n.t(.overflowEnabled), isOn: Binding(get: { manager.enabled }, set: { manager.setEnabled($0) }))
        Text(L10n.t(.overflowHint)).font(.caption).foregroundStyle(.secondary)
        if manager.enabled {
            Text(L10n.t(manager.status.messageKey)).font(.caption).foregroundStyle(.secondary)
            HStack {
                if manager.status == .needsPermission {
                    Button(L10n.t(.overflowGrant)) { AccessibilityManager.requestSystemPrompt(); AccessibilityManager.openSettings() }
                }
                Button(L10n.t(.overflowRefresh)) { manager.refresh() }
            }
        }
    }
}
