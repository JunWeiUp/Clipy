import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
        menuController = MenuController()
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
