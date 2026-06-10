import AppKit

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: HostingWindow<SettingsView>?

    private init() {}

    func makeKeyAndOrderFront(_ sender: Any?) {
        show()
    }

    func show() {
        if window == nil {
            window = HostingWindow(
                title: L10n.t(.preferences),
                size: AppWindowSize.settings,
                minSize: AppWindowSize.settings,
                resizable: false,
                frameAutosaveName: "SettingsWindow"
            ) {
                SettingsView()
            }
        }
        window?.title = L10n.t(.preferences)
        window?.show()
    }
}
