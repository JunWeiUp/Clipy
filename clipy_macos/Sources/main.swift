import AppKit

#if CLIPY_CORE_TESTS
if CommandLine.arguments.contains("--clipy-panel-snapshot") {
    runMenuBarPanelSnapshot()
} else if CommandLine.arguments.contains("--clipy-token-snapshot") {
    runTokenUsageSnapshot()
} else if CommandLine.arguments.contains("--clipy-overflow-fixture-menu") {
    runMenuBarOverflowFixture(popover: false)
} else if CommandLine.arguments.contains("--clipy-overflow-fixture-popover") {
    runMenuBarOverflowFixture(popover: true)
} else if CommandLine.arguments.contains("--clipy-overflow-live-tests") {
    runMenuBarOverflowLiveTests()
} else {
    runCoreRegressionTests()
}
#else
// OCR child mode must branch before any AppKit state exists: this same
// executable is re-invoked with a flag as a short-lived Vision worker, and
// must never build NSApplication.
if CommandLine.arguments.contains(OCRSubprocess.childModeArgument) {
    OCRSubprocess.runChildMode()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
#endif

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogManager.shared.startSession()
        CrashReporter.install()
        SystemNotificationRouter.shared.install()
        setupMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
        menuController = MenuController()
        SmartSwitchVoiceRouter.shared.start()
        MemoryFootprintReclaimer.registerIdleHandlers()
        LaunchAtLoginManager.syncWithPreference()
        SyncManager.shared.start()
        print("Clipy clone started!")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { menuController?.showControlPanel() }
        return true
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

#if !CLIPY_CORE_TESTS
app.run()
#endif
