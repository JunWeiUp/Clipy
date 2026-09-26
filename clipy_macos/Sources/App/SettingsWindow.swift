import AppKit

final class SettingsWindow {
    static let shared = SettingsWindow()

    private let session = WindowSession<SettingsView>()

    private init() {}

    func makeKeyAndOrderFront(_ sender: Any?) {
        show()
    }

    /// Opens preferences and scrolls the settings document to `page`.
    func show(page: String) {
        show()
        // Wait for newly-created settings anchors to be attached before scrolling.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appSettingsNavigate, object: page)
        }
    }

    func show() {
        session.present(
            create: {
                HostingWindow(
                    title: L10n.t(.preferences),
                    size: AppWindowSize.settings,
                    minSize: AppWindowSize.settingsMin,
                    resizable: true,
                    frameAutosaveName: "SettingsWindow"
                ) {
                    SettingsView()
                }
            },
            onPrepareForClose: {},
            update: { window in
                window.title = L10n.t(.preferences)
            }
        )
    }
}
