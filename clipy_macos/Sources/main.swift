import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// MARK: - Screenshot app integration
// Conformance lets macshot's detached editor window route lifecycle events
// (show pin / floating thumbnail, restore focus) back into clipy1. Every method
// has a default no-op, so only the ones clipy1 cares about are overridden here.
extension AppDelegate: ScreenshotAppIntegration {
    func showPin(image: NSImage) {
        PinPanelController.shared.pin(image: image, at: nil, skipIngest: false)
    }

    func showFloatingThumbnail(image: NSImage, annotationData: CaptureAnnotationData?, historyEntryID: String?) {
        // Ingest into history + sync; a dedicated floating-thumbnail UX can be added later.
        if let data = ImageEncoder.encodePNG(image) {
            ClipboardManager.shared.ingestCapturedImage(data, copyToPasteboard: false)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogManager.shared.startSession()
        CrashReporter.install()
        setupMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
        menuController = MenuController()
        MemoryFootprintReclaimer.registerIdleHandlers()
        LaunchAtLoginManager.syncWithPreference()
        SyncManager.shared.start()
        print("Clipy clone started!")
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: L10n.t(.quitClipy),
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: L10n.t(.editMenu))
        editMenu.addItem(NSMenuItem(title: L10n.t(.undo), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: L10n.t(.redo), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: L10n.t(.cut), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.t(.copy), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.t(.paste), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.t(.selectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func languageDidChange() {
        setupMainMenu()
    }
}

app.run()
