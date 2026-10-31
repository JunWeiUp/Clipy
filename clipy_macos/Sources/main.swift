import AppKit

#if CLIPY_CORE_TESTS
if CommandLine.arguments.contains("--clipy-capture-results-snapshot") {
    MainActor.assumeIsolated { runCaptureResultsLayoutSnapshot() }
} else if CommandLine.arguments.contains("--clipy-video-editor-snapshot") {
    MainActor.assumeIsolated { runVideoEditorLayoutSnapshot() }
} else if CommandLine.arguments.contains("--clipy-editor-snapshot") {
    MainActor.assumeIsolated { runEditorLayoutSnapshot() }
} else if CommandLine.arguments.contains("--clipy-window-snapshot") {
    runWindowSnapshots()
} else if CommandLine.arguments.contains("--clipy-panel-snapshot") {
    runMenuBarPanelSnapshot()
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

// Local, explicit administration; credentials are read from a private file, never command arguments.
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--relay-device-id" {
    print(SyncRelaySettings.deviceID)
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--relay-import" {
    do {
        let path = CommandLine.arguments[2]
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              (attributes[.size] as? NSNumber)?.intValue ?? 65537 <= 65536 else {
            throw NSError(domain: "SyncRelay", code: 1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let raw = String(decoding: data, as: UTF8.self)
        guard let _ = SyncRelayClient.Access.parse(raw),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String else { throw NSError(domain: "SyncRelay", code: 2) }
        try SyncRelaySettings.save(enabled: true, url: url, token: raw)
        UserDefaults.standard.synchronize()
        print("Relay configuration imported; restart Clipy to connect.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Relay import failed; verify private file permissions and device configuration.\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
#endif

// MARK: - Screenshot app integration
// Conformance lets macshot's detached editor window route lifecycle events
// (show pin / floating thumbnail, restore focus) back into clipy1. Every method
// has a default no-op, so only the ones clipy1 cares about are overridden here.
extension AppDelegate: ScreenshotAppIntegration {
    func returnFocusIfNeeded() {
        // 截图/视频编辑器打开时会把应用临时提升为 .regular，以便编辑器窗口
        // 成为 main window 并显示应用菜单栏。所有编辑器窗口关闭后恢复成
        // accessory（LSUIElement 默认状态），否则应用图标会一直常驻 Dock。
        NSApp.setActivationPolicy(.accessory)
    }

    func showPin(image: NSImage, screenRect: NSRect?) {
        PinPanelController.shared.pin(image: image, at: screenRect, skipIngest: false)
    }

    func showFloatingThumbnail(image: NSImage, annotationData: CaptureAnnotationData?, historyEntryID: String?, captureScreenRect: NSRect?) {
        // Ingest into history + sync; a dedicated floating-thumbnail UX can be added later.
        if let data = ImageEncoder.encodePNG(image) {
            ClipboardManager.shared.ingestCapturedImage(data, copyToPasteboard: false)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferencesManager.shared.appAppearance.apply()
        // Existing installations already have a database or sync identity. Only
        // seed the first-run guide for a new installation; it remains available
        // from About for everyone, including users upgrading from older builds.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: OnboardingWindow.completedKey) == nil {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClipyClone", isDirectory: true)
            let hasExistingData = ["clipy.db", "history_v2.json", "snippets.json"].contains {
                FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path)
            }
            let hasIdentity = defaults.string(forKey: "syncPeerId") != nil
            if !hasExistingData && !hasIdentity { defaults.set(false, forKey: OnboardingWindow.completedKey) }
        }
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
        MemoryFootprintReclaimer.registerIdleHandlers()
        LaunchAtLoginManager.syncWithPreference()
        SyncManager.shared.start()
        if defaults.object(forKey: OnboardingWindow.completedKey) != nil && !defaults.bool(forKey: OnboardingWindow.completedKey) {
            DispatchQueue.main.async { OnboardingWindow.shared.show() }
        }
        print("Clipy clone started!")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { menuController?.showControlPanel() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwakeManager.shared.stop()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let preferencesItem = NSMenuItem(
            title: L10n.t(.preferences) + "…",
            action: #selector(openPreferencesFromMenu),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        appMenu.addItem(NSMenuItem.separator())
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

        // 主窗口四个模块（⌥⌘1–4），偏好设置仍是独立窗口。
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: PreferencesManager.shared.appLanguage == .zh ? "窗口" : "Window")
        MainWindow.makeWindowMenuItems(target: self, action: #selector(showMainWindowSection(_:)))
            .forEach(windowMenu.addItem)
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openPreferencesFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.makeKeyAndOrderFront(nil)
    }

    @objc private func showMainWindowSection(_ sender: NSMenuItem) {
        guard let section = MainWindow.section(forMenuTag: sender.tag) else { return }
        MainWindow.shared.show(section)
    }

    @objc private func languageDidChange() {
        setupMainMenu()
    }
}

#if !CLIPY_CORE_TESTS
app.run()
#endif
