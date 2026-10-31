import AppKit

class MenuController: NSObject {
    private var statusItem: NSStatusItem!
    private var controlPanelStorage: MenuBarPanelController?
    private var controlPanel: MenuBarPanelController {
        if let controlPanelStorage { return controlPanelStorage }
        let panel = MenuBarPanelController()
        panel.onAction = { [weak self] action in self?.performPanelAction(action) }
        panel.onVisibilityChanged = { [weak self] visible in
            self?.statusItem.button?.state = visible ? .on : .off
        }
        controlPanelStorage = panel
        return panel
    }
    private let clipboardManager = ClipboardManager.shared
    private let snippetManager = SnippetManager.shared

    /// Skip idle memory reclamation while the control panel is visible.
    var isMenuBarMenuOpen: Bool { controlPanelStorage?.isVisible == true }
    /// The live instance (MenuController is created by AppDelegate, not a
    /// singleton). The idle memory monitor reads the panel visibility through
    /// it, from the main thread only.
    private(set) static weak var active: MenuController?

    override init() {
        super.init()
        MenuController.active = self
        setupStatusItem()
        MenuBarOverflowManager.shared.start()
        setupClipboardObserver()
        setupSnippetObserver()
        setupHotKeyObserver()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registerGlobalHotKeys),
            name: .globalHotKeysShouldRegister,
            object: nil
        )
        registerGlobalHotKeys()
        NotificationManager.shared.onNotificationsChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshControlPanel()
            }
        }
    }
    
    private func setupHotKeyObserver() {
        snippetManager.onHotKeyTriggered = { [weak self] item in
            if let snippet = item as? Snippet {
                self?.clipboardManager.copyToPasteboard(.text(snippet.content))
            } else if let folder = item as? SnippetFolder {
                self?.showFolderMenu(folder)
            }
        }
    }
    
    private func showFolderMenu(_ folder: SnippetFolder) {
        let menu = buildSnippetSubmenu(for: folder)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func buildSnippetSubmenu(for folder: SnippetFolder) -> NSMenu {
        let menu = AppMenuStyle.menu()
        let search = actionItem(L10n.t(.searchHistory), symbol: "magnifyingglass", action: #selector(openSearch))
        if PreferencesManager.shared.isSearchGlobalShortcutEnabled {
            AppMenuStyle.applyShortcut(PreferencesManager.shared.searchHistoryShortcut, to: search)
        }
        menu.addItem(search)
        menu.addItem(.separator())
        menu.addItem(AppMenuStyle.header(AppMenuStyle.compactTitle(folder.title)))
        if folder.snippets.isEmpty {
            menu.addItem(AppMenuStyle.detail(L10n.t(.noSnippets)))
        }
        for (index, snippet) in folder.snippets.enumerated() {
            let item = actionItem(AppMenuStyle.compactTitle(snippet.title), symbol: "text.alignleft",
                                  action: #selector(menuItemClicked(_:)), key: index < 10 ? "\((index + 1) % 10)" : "")
            item.representedObject = SnippetMenuReference(snippetId: snippet.id)
            item.toolTip = snippet.title
            menu.addItem(item)
        }

        return menu
    }

    private func setupSnippetObserver() {
        snippetManager.onSnippetsChanged = { [weak self] _ in
            self?.refreshControlPanel()
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // 使用 SF Symbol 替代 emoji，与系统菜单栏图标风格统一。
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.image = NSImage(
                systemSymbolName: "clipboard",
                accessibilityDescription: NSLocalizedString("Clipy", comment: "status item accessibility")
            )?.withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }

        SyncManager.shared.onDevicesChanged = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.controlPanelStorage?.refreshSnapshots()
            }
        }
    }
    
    func showControlPanel() {
        guard let button = statusItem.button else { return }
        controlPanel.show(from: button)
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        controlPanel.toggle(from: sender)
    }

    private func performPanelAction(_ action: MenuBarPanelModel.Action) {
        switch action {
        case .search(let query):
            NSApp.activate(ignoringOtherApps: true)
            MainWindow.shared.showHistory(initialQuery: query)
        case .snippets: openSnippetEditor()
        case .preferences: openPreferences()
        case .syncSettings:
            NSApp.activate(ignoringOtherApps: true)
            MainWindow.shared.showDevices(page: .devices)
        case .notifications: openNotifications()
        case .word: openWordLookup()
        case .wordBook: openWordBook()
        case .password: openPasswordGenerator()
        case .toggleKeepAwake:
            if !KeepAwakeManager.shared.toggle() {
                controlPanelStorage?.model.notice = L10n.t(.keepAwakeFailed)
            } else {
                controlPanelStorage?.model.notice = nil
            }
        case .region: startScreenshotRegion()
        case .window: startScreenshotWindow()
        case .fullscreen: startScreenshotFullscreen()
        case .screenshotSettings: openScreenshotPreferences()
        case .permission: grantOverflowPermission()
        case .sendText(let peerID):
            sendText(to: peerID)
        case .sendFile(let peerID):
            sendFile(to: peerID)
        }
    }

    private func setupClipboardObserver() {
        clipboardManager.onHistoryChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshControlPanel()
            }
        }
    }

    private func refreshControlPanel() {
        controlPanelStorage?.refreshHistory()
        controlPanelStorage?.refreshSnapshots()
    }

    private func grantOverflowPermission() {
        DispatchQueue.main.async {
            AccessibilityManager.requestSystemPrompt()
            AccessibilityManager.openSettings()
        }
    }

    private func actionItem(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title.replacingOccurrences(of: "...", with: "…"), action: action, keyEquivalent: key)
        item.target = self
        item.image = AppMenuStyle.icon(symbol)
        return item
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        if let reference = sender.representedObject as? SnippetMenuReference,
           let snippet = snippetManager.snippet(id: reference.snippetId) {
            clipboardManager.copyToPasteboard(.text(snippet.content))
        }
    }

    func sendText(to peerId: String) {
        // Resolve display name for the dialog title
        let deviceName = SyncManager.shared.availableDeviceEntries.first(where: { $0.peerId == peerId })?.displayName ?? peerId
        appLog("Send Text clicked for peer: \(peerId)")

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = L10n.format(.chooseTextToSend, deviceName)
        alert.informativeText = L10n.t(.sendTextHint)
        alert.addButton(withTitle: L10n.t(.send))
        alert.addButton(withTitle: L10n.t(.cancel))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        textField.stringValue = NSPasteboard.general.string(forType: .string) ?? ""
        textField.placeholderString = L10n.t(.enterTextToSend)
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.isScrollable = true
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let content = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        let hash = ClipboardManager.shared.contentHashForPlainText(content) ?? UUID().uuidString
        SyncManager.shared.sendTextToPeer(content, hash: hash, peerId: peerId) { success in
            if !success {
                Self.showSendFailedAlert()
            }
        }
    }

    func sendFile(to peerId: String) {
        let deviceName = SyncManager.shared.availableDeviceEntries.first(where: { $0.peerId == peerId })?.displayName ?? peerId
        appLog("Send File clicked for peer: \(peerId)")

        NSApp.activate(ignoringOtherApps: true)

        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = L10n.format(.chooseFileToSend, deviceName)
        openPanel.prompt = L10n.t(.send)

        // Use runModal to ensure the dialog appears and blocks until a choice is made
        let response = openPanel.runModal()
        if response == .OK, let url = openPanel.url {
            appLog("Selected file: \(url.lastPathComponent), sending...")
            SyncManager.shared.sendFileToPeer(at: url, peerId: peerId) { success, error in
                if !success {
                    Self.showSendFailedAlert(detail: error.map { _ in L10n.t(.folderSendPreparationFailed) })
                }
            }
        }
    }

    private static func showSendFailedAlert(detail: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = detail ?? L10n.t(.sendFailed)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t(.ok))
        alert.runModal()
    }
    
    @objc private func openNotifications() {
        MainWindow.shared.showNotifications()
    }

    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.makeKeyAndOrderFront(nil)
    }

    @objc private func openScreenshotPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.show(page: ScreenshotSettingsView.pagePrefix + "capture")
    }
    
    @objc private func openSnippetEditor() {
        NSApp.activate(ignoringOtherApps: true)
        MainWindow.shared.show(.snippets)
    }
    
    @objc private func openSearch() {
        NSApp.activate(ignoringOtherApps: true)
        MainWindow.shared.show(.history)
    }

    @objc private func openWordBook() {
        WordBookWindow.shared.showWindow()
    }

    @objc private func openWordLookup() {
        WordLookupWindow.shared.showWindow()
    }

    @objc private func openPasswordGenerator() {
        NSApp.activate(ignoringOtherApps: true)
        PasswordGeneratorWindow.show()
    }

    @objc private func registerGlobalHotKeys() {
        SearchGlobalHotKeyManager.register()
        WordGlobalHotKeyManager.register()
        ScreenshotGlobalHotKeyManager.register()
    }

    @objc private func startScreenshotRegion() {
        ScreenshotSessionCoordinator.shared.startCapture(mode: .region, fromMenu: true)
    }

    @objc private func startScreenshotWindow() {
        ScreenshotSessionCoordinator.shared.startCapture(mode: .window, fromMenu: true)
    }

    @objc private func startScreenshotFullscreen() {
        ScreenshotSessionCoordinator.shared.startCapture(mode: .fullscreen, fromMenu: true)
    }

}
