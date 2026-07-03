import AppKit

final class SettingsWindow {
    static let shared = SettingsWindow()

    private let session = WindowSession<SettingsView>()

    private init() {}

    func makeKeyAndOrderFront(_ sender: Any?) {
        show()
    }

    func show() {
        session.present(
            create: {
                HostingWindow(
                    title: L10n.t(.preferences),
                    size: AppWindowSize.settings,
                    minSize: CGSize(width: 420, height: 560),
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
