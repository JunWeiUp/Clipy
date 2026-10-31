import SwiftUI

/// Rows for the General settings card (V3): toggle with description, live status
/// caption and the refresh / grant action row while enabled.
struct MenuBarOverflowSettingsView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject private var manager = MenuBarOverflowManager.shared
    var body: some View {
        let _ = languageObserver.revision
        VStack(spacing: 0) {
            SettingsRow(title: L10n.t(.overflowEnabled), detail: L10n.t(.overflowHint)) {
                SettingsSwitch(isOn: Binding(get: { manager.enabled }, set: { manager.setEnabled($0) }))
            }
            if manager.enabled {
                SettingsHairline()
                SettingsCaptionRow(L10n.t(manager.status.messageKey))
                SettingsHairline()
                SettingsCustomRow(searchText: L10n.t(.overflowRefresh)) {
                    if manager.status == .needsPermission {
                        Button(L10n.t(.overflowGrant)) { AccessibilityManager.requestSystemPrompt(); AccessibilityManager.openSettings() }
                            .buttonStyle(SettingsButtonStyle(prominent: true))
                    }
                    Button(L10n.t(.overflowRefresh)) { manager.refresh() }
                        .buttonStyle(SettingsButtonStyle())
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
