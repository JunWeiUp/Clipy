import AppKit

final class ScreenshotSettingsWindow {
    static let shared = ScreenshotSettingsWindow()

    private let session = WindowSession<ScreenshotSettingsView>()

    private init() {}

    func makeKeyAndOrderFront(_ sender: Any?) {
        show()
    }

    func show() {
        session.present(
            create: {
                HostingWindow(
                    title: L10n.t(.screenshotPreferences),
                    size: AppWindowSize.screenshotSettings,
                    minSize: CGSize(width: 420, height: 480),
                    resizable: true,
                    frameAutosaveName: "ScreenshotSettingsWindow"
                ) {
                    ScreenshotSettingsView()
                }
            },
            onPrepareForClose: {},
            update: { window in
                window.title = L10n.t(.screenshotPreferences)
            }
        )
    }
}
