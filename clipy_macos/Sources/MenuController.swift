import AppKit

class MenuController: NSObject {
    private static let menuDisplayLimit = 50
    private static let menuShortcutHistoryLimit = 50
    private static let menuIndent = "  "

    private static func indentedMenuTitle(_ title: String) -> String {
        menuIndent + title
    }

    private var statusItem: NSStatusItem!
    private let clipboardManager = ClipboardManager.shared
    private let snippetManager = SnippetManager.shared
    private lazy var notificationWindow = NotificationWindow()
    private var menuUpdateWorkItem: DispatchWorkItem?
    
    override init() {
        super.init()
        setupStatusItem()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
        NotificationManager.shared.onNotificationsChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleMenuUpdate()
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
        let menu = NSMenu()

        let searchItem = NSMenuItem(title: L10n.t(.searchHistory), action: #selector(openSearch), keyEquivalent: "f")
        searchItem.keyEquivalentModifierMask = [.command, .shift]
        searchItem.target = self
        menu.addItem(searchItem)
        menu.addItem(NSMenuItem.separator())

        if folder.snippets.isEmpty {
            let emptyItem = NSMenuItem(title: L10n.t(.noSnippets), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return menu
        }

        for (index, snippet) in folder.snippets.enumerated() {
            let menuIndex = (index + 1) % 10
            let prefix = "\(menuIndex). "
            let keyEquivalent = index < 10 ? "\(menuIndex)" : ""

            let menuItem = NSMenuItem(title: prefix + snippet.title, action: #selector(menuItemClicked(_:)), keyEquivalent: keyEquivalent)
            menuItem.target = self
            menuItem.representedObject = SnippetMenuReference(snippetId: snippet.id)
            menu.addItem(menuItem)
        }

        return menu
    }

    private func setupSnippetObserver() {
        snippetManager.onSnippetsChanged = { [weak self] _ in
            self?.scheduleMenuUpdate()
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
        }

        // 常驻菜单对象：靠 menuNeedsUpdate 在每次打开前就地刷新内容。
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        SyncManager.shared.onDevicesChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.scheduleMenuUpdate()
            }
        }
    }
    
    private func setupClipboardObserver() {
        clipboardManager.onHistoryChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleMenuUpdate()
            }
        }
        clipboardManager.onFileHistoryChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.scheduleMenuUpdate()
            }
        }
    }

    private func scheduleMenuUpdate() {
        menuUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 仅在菜单已打开（仍保留摘要）时刷新；关闭状态下交给下次 menuNeedsUpdate。
            guard self.clipboardManager.isMenuMemoryRetained,
                  let menu = self.statusItem.menu else { return }
            self.clipboardManager.ensureMenuSummariesLoaded()
            self.rebuildMenuContents(menu, with: self.clipboardManager.recentSummaries)
        }
        menuUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func refreshMenuForOpen(_ menu: NSMenu) {
        clipboardManager.refreshFromPasteboardIfNeeded()
        clipboardManager.ensureMenuSummariesLoaded()
        rebuildMenuContents(menu, with: clipboardManager.recentSummaries)
    }

    private func rebuildMenuContents(_ menu: NSMenu, with summaries: [HistorySummary]) {
        menu.removeAllItems()
        populateMenu(menu, with: summaries)
    }

    private func populateMenu(_ menu: NSMenu, with summaries: [HistorySummary]) {
        // --- Clipboard / History ---
        menu.addItem(makeSectionHeaderItem(
            title: L10n.t(.history),
            symbolName: "magnifyingglass",
            toolTip: L10n.t(.searchHistory),
            keyEquivalent: "f",
            keyEquivalentModifierMask: [.command, .shift],
            action: #selector(openSearch)
        ) { [weak self] in
            self?.openSearch()
        })

        if summaries.isEmpty {
            let emptyItem = NSMenuItem(
                title: Self.indentedMenuTitle(L10n.t(.noHistory)),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            addHistoryGroups(to: menu, summaries: Array(summaries.prefix(Self.menuDisplayLimit)), startIndex: 0)
        }
        menu.addItem(NSMenuItem.separator())

        // --- Snippets ---
        menu.addItem(makeSectionHeaderItem(
            title: L10n.t(.snippets),
            symbolName: "square.and.pencil",
            toolTip: L10n.t(.editSnippets),
            keyEquivalent: "S",
            keyEquivalentModifierMask: [.command],
            action: #selector(openSnippetEditor)
        ) { [weak self] in
            self?.openSnippetEditor()
        })

        if snippetManager.folders.isEmpty {
            let emptyItem = NSMenuItem(
                title: Self.indentedMenuTitle(L10n.t(.noSnippets)),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for folder in snippetManager.folders {
                let categoryMenu = NSMenu()
                let categoryItem = NSMenuItem(
                    title: Self.indentedMenuTitle(folder.title),
                    action: nil,
                    keyEquivalent: ""
                )

                for (index, snippet) in folder.snippets.enumerated() {
                    let menuIndex = (index + 1) % 10
                    let prefix = "\(menuIndex). "
                    let keyEquivalent = index < 10 ? "\(menuIndex)" : ""

                    let menuItem = NSMenuItem(
                        title: prefix + snippet.title,
                        action: #selector(menuItemClicked(_:)),
                        keyEquivalent: keyEquivalent
                    )
                    menuItem.target = self
                    menuItem.representedObject = SnippetMenuReference(snippetId: snippet.id)
                    categoryMenu.addItem(menuItem)
                }

                categoryItem.submenu = categoryMenu
                menu.addItem(categoryItem)
            }
        }
        menu.addItem(NSMenuItem.separator())

        // --- Network ---
        let syncEnabled = PreferencesManager.shared.isSyncEnabled
        menu.addItem(makeSectionHeaderItem(
            title: L10n.t(.lanDevices),
            symbolName: "arrow.clockwise",
            toolTip: L10n.t(.refreshDevices),
            keyEquivalent: "r",
            keyEquivalentModifierMask: [.command],
            action: #selector(refreshLanDevices),
            buttonEnabled: syncEnabled
        ) { [weak self] in
            self?.refreshLanDevices()
        })

        let availableDevices = SyncManager.shared.availableDeviceNames
        if availableDevices.isEmpty {
            let emptyItem = NSMenuItem(
                title: Self.indentedMenuTitle(L10n.t(.noDevicesFound)),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for deviceName in availableDevices {
                let deviceItem = NSMenuItem(
                    title: Self.indentedMenuTitle(deviceName),
                    action: nil,
                    keyEquivalent: ""
                )
                let deviceSubmenu = NSMenu()

                let sendTextItem = NSMenuItem(
                    title: L10n.t(.sendText),
                    action: #selector(sendTextClicked(_:)),
                    keyEquivalent: ""
                )
                sendTextItem.target = self
                sendTextItem.representedObject = deviceName
                deviceSubmenu.addItem(sendTextItem)

                let sendFileItem = NSMenuItem(
                    title: L10n.t(.sendFile),
                    action: #selector(sendFileClicked(_:)),
                    keyEquivalent: ""
                )
                sendFileItem.target = self
                sendFileItem.representedObject = deviceName
                deviceSubmenu.addItem(sendFileItem)

                deviceItem.submenu = deviceSubmenu
                menu.addItem(deviceItem)
            }
        }

        let fileHistoryItem = NSMenuItem(
            title: Self.indentedMenuTitle(L10n.t(.fileHistory)),
            action: nil,
            keyEquivalent: ""
        )
        let fileHistorySubmenu = NSMenu()
        if clipboardManager.fileHistory.isEmpty {
            let emptyItem = NSMenuItem(title: L10n.t(.noFiles), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            fileHistorySubmenu.addItem(emptyItem)
        } else {
            for file in clipboardManager.fileHistory {
                let menuItem = NSMenuItem(
                    title: file.fileName,
                    action: #selector(fileHistoryItemClicked(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = file
                menuItem.toolTip = "\(L10n.t(.from)): \(file.senderName)\nPath: \(file.filePath)"
                fileHistorySubmenu.addItem(menuItem)
            }
        }
        fileHistoryItem.submenu = fileHistorySubmenu
        menu.addItem(fileHistoryItem)
        menu.addItem(NSMenuItem.separator())

        // --- Tools / Settings ---
        let screenshotItem = NSMenuItem(title: L10n.t(.screenshot), action: nil, keyEquivalent: "")
        let screenshotSubmenu = NSMenu()
        let regionItem = NSMenuItem(
            title: L10n.t(.screenshotRegion),
            action: #selector(startScreenshotRegion),
            keyEquivalent: ""
        )
        regionItem.target = self
        screenshotSubmenu.addItem(regionItem)
        let windowItem = NSMenuItem(
            title: L10n.t(.screenshotWindow),
            action: #selector(startScreenshotWindow),
            keyEquivalent: ""
        )
        windowItem.target = self
        screenshotSubmenu.addItem(windowItem)
        let fullscreenItem = NSMenuItem(
            title: L10n.t(.screenshotFullscreen),
            action: #selector(startScreenshotFullscreen),
            keyEquivalent: ""
        )
        fullscreenItem.target = self
        screenshotSubmenu.addItem(fullscreenItem)
        screenshotSubmenu.addItem(NSMenuItem.separator())
        let screenshotPreferencesItem = NSMenuItem(
            title: L10n.t(.screenshotPreferences) + "...",
            action: #selector(openScreenshotPreferences),
            keyEquivalent: ""
        )
        screenshotPreferencesItem.target = self
        screenshotSubmenu.addItem(screenshotPreferencesItem)
        screenshotItem.submenu = screenshotSubmenu
        menu.addItem(screenshotItem)

        let notificationCount = NotificationManager.shared.notificationCount
        let notificationItem = NSMenuItem(
            title: "\(L10n.t(.notificationSync)) (\(notificationCount))...",
            action: #selector(openNotifications),
            keyEquivalent: "N"
        )
        notificationItem.target = self
        notificationItem.toolTip = L10n.t(.enableNotificationSync)
        menu.addItem(notificationItem)

        let preferencesItem = NSMenuItem(
            title: L10n.t(.preferences) + "...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        menu.addItem(NSMenuItem.separator())

        // --- System ---
        let clearItem = NSMenuItem(title: L10n.t(.clearHistory), action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let logsItem = NSMenuItem(title: L10n.t(.showLogs), action: #selector(openLogs), keyEquivalent: "L")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(NSMenuItem(title: L10n.t(.quit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addHistoryGroups(to menu: NSMenu, summaries: [HistorySummary], startIndex: Int) {
        let groupSize = 10
        for start in stride(from: 0, to: summaries.count, by: groupSize) {
            let end = min(start + groupSize, summaries.count)
            let groupMenu = NSMenu()
            let groupTitle = "\(startIndex + start + 1) - \(startIndex + end)"
            let groupFolderItem = NSMenuItem(
                title: Self.indentedMenuTitle(groupTitle),
                action: nil,
                keyEquivalent: ""
            )

            for i in start..<end {
                let summary = summaries[i]
                let menuItem = makeHistoryMenuItem(summary: summary, indexInGroup: i - start, startIndex: startIndex)
                groupMenu.addItem(menuItem)
            }

            groupFolderItem.submenu = groupMenu
            menu.addItem(groupFolderItem)
        }
    }
    
    private func makeHistoryMenuItem(summary: HistorySummary, indexInGroup: Int, startIndex: Int) -> NSMenuItem {
        let rawTitle = summaryDisplayTitle(for: summary)
        let displayTitle = rawTitle.count > 50 ? String(rawTitle.prefix(50)) + "..." : rawTitle

        let menuIndex = (indexInGroup + 1) % 10
        let prefix = "\(menuIndex). "
        let keyEquivalent = startIndex + indexInGroup < Self.menuShortcutHistoryLimit ? "\(menuIndex)" : ""

        if summary.item.isFile, let urls = summary.item.fileURLs {
            let fileItem = NSMenuItem(title: prefix + displayTitle, action: nil, keyEquivalent: keyEquivalent)
            let fileSubmenu = NSMenu()

            let pasteNameItem = NSMenuItem(title: L10n.t(.pasteFileName), action: #selector(pasteFileNameClicked(_:)), keyEquivalent: "")
            pasteNameItem.target = self
            pasteNameItem.representedObject = summary
            fileSubmenu.addItem(pasteNameItem)

            let pasteFileItem = NSMenuItem(title: L10n.t(.pasteFile), action: #selector(pasteFileClicked(_:)), keyEquivalent: "")
            pasteFileItem.target = self
            pasteFileItem.representedObject = summary
            fileSubmenu.addItem(pasteFileItem)

            let revealItem = NSMenuItem(title: L10n.t(.showInFinder), action: #selector(revealHistoryFileInFinder(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = summary
            fileSubmenu.addItem(revealItem)

            fileItem.submenu = fileSubmenu
            fileItem.toolTip = historyFileToolTip(for: summary, urls: urls)
            fileItem.image = Self.cachedFileIcon(forPath: urls[0].path)
            return fileItem
        }

        if case .html = summary.item {
            // Show the fast title immediately; resolving plain text reads and parses
            // the HTML file from disk, so do it off the main thread and patch the title.
            let htmlItem = NSMenuItem(title: prefix + displayTitle, action: nil, keyEquivalent: keyEquivalent)
            let entry = summary.asEntry()
            let manager = clipboardManager
            DispatchQueue.global(qos: .userInitiated).async { [weak htmlItem] in
                guard let plainTitle = manager.plainText(for: entry), !plainTitle.isEmpty else { return }
                let htmlDisplayTitle = plainTitle.count > 50 ? String(plainTitle.prefix(50)) + "..." : plainTitle
                DispatchQueue.main.async {
                    htmlItem?.title = prefix + htmlDisplayTitle
                }
            }
            let htmlSubmenu = NSMenu()

            let pastePlainItem = NSMenuItem(title: L10n.t(.pastePlainText), action: #selector(pasteHTMLPlainTextClicked(_:)), keyEquivalent: "")
            pastePlainItem.target = self
            pastePlainItem.representedObject = summary
            htmlSubmenu.addItem(pastePlainItem)

            let pasteFormattedItem = NSMenuItem(title: L10n.t(.copyContent), action: #selector(pasteHTMLFormattedClicked(_:)), keyEquivalent: "")
            pasteFormattedItem.target = self
            pasteFormattedItem.representedObject = summary
            htmlSubmenu.addItem(pasteFormattedItem)

            htmlItem.submenu = htmlSubmenu
            htmlItem.toolTip = historyToolTip(for: summary)
            htmlItem.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: L10n.t(.historyTypeHTML))
            return htmlItem
        }

        let menuItem = NSMenuItem(title: prefix + displayTitle, action: #selector(menuItemClicked(_:)), keyEquivalent: keyEquivalent)
        menuItem.target = self
        menuItem.representedObject = summary
        menuItem.toolTip = historyToolTip(for: summary)

        if case .image(let path) = summary.item {
            // Thumbnails come from disk (possibly with decrypt + downsample on miss);
            // never block menu construction on that IO.
            DispatchQueue.global(qos: .userInitiated).async { [weak menuItem] in
                let thumbnail = HistoryThumbnailCache.thumbnail(for: path, size: NSSize(width: 32, height: 32))
                DispatchQueue.main.async {
                    menuItem?.image = thumbnail
                }
            }
        }

        return menuItem
    }

    private static let fileIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private static func cachedFileIcon(forPath path: String) -> NSImage {
        let key = (path as NSString).pathExtension.lowercased() as NSString
        if key.length > 0, let cached = fileIconCache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if key.length > 0 {
            fileIconCache.setObject(icon, forKey: key)
        }
        return icon
    }

    private func summaryDisplayTitle(for summary: HistorySummary) -> String {
        summary.asEntry().listDisplayTitle
    }

    private func historyToolTip(for summary: HistorySummary) -> String? {
        var parts: [String] = []
        if let location = summary.item.locationSummary {
            parts.append("\(L10n.t(.location)): \(location)")
        }
        if let app = summary.sourceApp {
            parts.append("\(L10n.t(.source)): \(app)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func historyFileToolTip(for summary: HistorySummary, urls: [URL]) -> String {
        var parts: [String] = []
        if let location = summary.item.locationSummary {
            parts.append("\(L10n.t(.location)): \(location)")
        } else {
            parts.append(urls.map(\.path).joined(separator: "\n"))
        }
        if let app = summary.sourceApp {
            parts.append("\(L10n.t(.source)): \(app)")
        }
        return parts.joined(separator: "\n")
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        if let summary = sender.representedObject as? HistorySummary {
            let entry = clipboardManager.resolveEntry(summary)
            clipboardManager.moveHistoryEntryToFront(entry)
            clipboardManager.copyToPasteboard(entry.item)
        } else if let reference = sender.representedObject as? SnippetMenuReference,
                  let snippet = snippetManager.snippet(id: reference.snippetId) {
            clipboardManager.copyToPasteboard(.text(snippet.content))
        } else if let item = sender.representedObject as? HistoryItem {
            clipboardManager.copyToPasteboard(item)
        }
    }

    @objc private func pasteFileNameClicked(_ sender: NSMenuItem) {
        guard let entry = historyEntry(from: sender),
              let urls = entry.item.fileURLs else { return }
        clipboardManager.moveHistoryEntryToFront(entry)
        clipboardManager.copyFileNamesToPasteboard(urls)
    }

    @objc private func pasteFileClicked(_ sender: NSMenuItem) {
        guard let entry = historyEntry(from: sender) else { return }
        clipboardManager.moveHistoryEntryToFront(entry)
        clipboardManager.writeToPasteboard(entry.item)
    }

    @objc private func revealHistoryFileInFinder(_ sender: NSMenuItem) {
        guard let entry = historyEntry(from: sender) else { return }
        clipboardManager.revealInFinder(for: entry)
    }

    @objc private func pasteHTMLPlainTextClicked(_ sender: NSMenuItem) {
        guard let entry = historyEntry(from: sender) else { return }
        clipboardManager.moveHistoryEntryToFront(entry)
        clipboardManager.writePlainTextToPasteboard(entry.item, textPath: entry.textPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.clipboardManager.simulatePasteIfTrusted()
        }
    }

    @objc private func pasteHTMLFormattedClicked(_ sender: NSMenuItem) {
        guard let entry = historyEntry(from: sender) else { return }
        clipboardManager.moveHistoryEntryToFront(entry)
        clipboardManager.copyToPasteboard(entry.item)
    }

    private func historyEntry(from sender: NSMenuItem) -> HistoryEntry? {
        guard let summary = sender.representedObject as? HistorySummary else { return nil }
        return clipboardManager.resolveEntry(summary)
    }
    
    @objc private func fileHistoryItemClicked(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? FileHistoryItem else { return }
        let url = URL(fileURLWithPath: file.filePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    @objc private func sendTextClicked(_ sender: NSMenuItem) {
        guard let deviceName = sender.representedObject as? String else { return }
        appLog("Send Text clicked for device: \(deviceName)")

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
        SyncManager.shared.sendText(content, hash: hash, toDevice: deviceName)
    }

    @objc private func sendFileClicked(_ sender: NSMenuItem) {
        guard let deviceName = sender.representedObject as? String else { return }
        appLog("Send File clicked for device: \(deviceName)")
        
        NSApp.activate(ignoringOtherApps: true)
        
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = L10n.format(.chooseFileToSend, deviceName)
        openPanel.prompt = L10n.t(.send)
        
        // Use runModal to ensure the dialog appears and blocks until a choice is made
        let response = openPanel.runModal()
        if response == .OK, let url = openPanel.url {
            appLog("Selected file: \(url.lastPathComponent), sending...")
            SyncManager.shared.sendFile(at: url, toDevice: deviceName)
        }
    }
    
    @objc private func clearHistory() {
        clipboardManager.clearHistory()
    }

    @objc private func openNotifications() {
        notificationWindow.showWindow()
    }

    @objc private func refreshLanDevices() {
        SyncManager.shared.refreshDiscovery()
        scheduleMenuUpdate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.scheduleMenuUpdate()
        }
    }
    
    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.makeKeyAndOrderFront(nil)
    }

    @objc private func openScreenshotPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        ScreenshotSettingsWindow.shared.makeKeyAndOrderFront(nil)
    }
    
    @objc private func openSnippetEditor() {
        NSApp.activate(ignoringOtherApps: true)
        SnippetEditorWindow.shared.makeKeyAndOrderFront(nil)
    }
    
    @objc private func openLogs() {
        LogWindow.show()
    }

    @objc private func openSearch() {
        NSApp.activate(ignoringOtherApps: true)
        SearchWindow.shared.showWindow()
    }

    @objc private func registerGlobalHotKeys() {
        SearchGlobalHotKeyManager.register()
        ScreenshotGlobalHotKeyManager.register()
    }

    @objc private func startScreenshotRegion() {
        NSApp.activate(ignoringOtherApps: true)
        ScreenshotCoordinator.shared.start(mode: .region)
    }

    @objc private func startScreenshotWindow() {
        NSApp.activate(ignoringOtherApps: true)
        ScreenshotCoordinator.shared.start(mode: .window)
    }

    @objc private func startScreenshotFullscreen() {
        NSApp.activate(ignoringOtherApps: true)
        ScreenshotCoordinator.shared.start(mode: .fullscreen)
    }

    @objc private func languageDidChange() {
        if clipboardManager.isMenuMemoryRetained, let menu = statusItem.menu {
            rebuildMenuContents(menu, with: clipboardManager.recentSummaries)
        }
    }

    private func makeSectionHeaderItem(
        title: String,
        symbolName: String,
        toolTip: String,
        keyEquivalent: String,
        keyEquivalentModifierMask: NSEvent.ModifierFlags,
        action: Selector,
        buttonEnabled: Bool = true,
        onAction: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalentModifierMask
        item.target = self
        item.isEnabled = buttonEnabled
        let headerView = SectionMenuHeaderView(
            title: title,
            symbolName: symbolName,
            toolTip: toolTip,
            buttonEnabled: buttonEnabled
        )
        headerView.onAction = onAction
        item.view = headerView
        return item
    }
}

/// Section header with a trailing hoverable action icon.
private final class SectionMenuHeaderView: NSView {
    var onAction: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let actionButton = HoverIconButton(frame: .zero)

    init(
        title: String,
        symbolName: String,
        toolTip: String,
        buttonEnabled: Bool = true,
        width: CGFloat = 240
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        wantsLayer = true

        titleLabel.stringValue = title
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.backgroundColor = .clear
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.imageScaling = .scaleProportionallyDown
        actionButton.toolTip = toolTip
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.isEnabled = buttonEnabled
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            actionButton.image = image.withSymbolConfiguration(config)
        }
        actionButton.normalTint = .secondaryLabelColor
        actionButton.hoverTint = .labelColor
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 22),
            actionButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let menuWidth = enclosingMenuItem?.menu?.size.width, menuWidth > frame.width {
            setFrameSize(NSSize(width: menuWidth, height: frame.height))
        }
    }

    @objc private func actionClicked() {
        enclosingMenuItem?.menu?.cancelTracking()
        onAction?()
    }
}

/// Small icon button with hover highlight suitable for menu accessory controls.
private final class HoverIconButton: NSButton {
    var normalTint: NSColor = .secondaryLabelColor {
        didSet { applyAppearance(hovered: isHovered) }
    }
    var hoverTint: NSColor = .labelColor {
        didSet { applyAppearance(hovered: isHovered) }
    }

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        isBordered = false
        applyAppearance(hovered: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { applyAppearance(hovered: isHovered) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        applyAppearance(hovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance(hovered: false)
    }

    private func applyAppearance(hovered: Bool) {
        if !isEnabled {
            contentTintColor = .tertiaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        contentTintColor = hovered ? hoverTint : normalTint
        layer?.backgroundColor = hovered
            ? NSColor.quaternaryLabelColor.cgColor
            : NSColor.clear.cgColor
    }
}

extension MenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        refreshMenuForOpen(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        clipboardManager.releaseMenuMemory()
        MemoryFootprintReclaimer.reclaimIfIdle()
    }
}
