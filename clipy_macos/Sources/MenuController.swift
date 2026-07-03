import AppKit

class MenuController: NSObject {
    private static let menuDisplayLimit = 50
    private static let menuShortcutHistoryLimit = 50
    private var statusItem: NSStatusItem!
    private let clipboardManager = ClipboardManager.shared
    private let snippetManager = SnippetManager.shared
    private lazy var notificationWindow = NotificationWindow()
    private lazy var collectorWindow = CollectorWindow()
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
        DeviceCollectorManager.shared.onEventsChanged = { [weak self] in
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
            menuItem.representedObject = HistoryItem.text(snippet.content)
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
            button.title = "📋"
        }
        
        updateMenu(with: clipboardManager.recentSummaries)
        
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
            self.updateMenu(with: self.clipboardManager.recentSummaries)
        }
        menuUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    
    private func updateMenu(with summaries: [HistorySummary]) {
        let menu = NSMenu()
        
        // --- History Section ---
        let historyHeader = NSMenuItem(
            title: L10n.format(.historyWithCount, clipboardManager.totalHistoryCount),
            action: nil,
            keyEquivalent: ""
        )
        historyHeader.isEnabled = false
        menu.addItem(historyHeader)

        let searchItem = NSMenuItem(title: L10n.t(.searchHistory), action: #selector(openSearch), keyEquivalent: "f")
        searchItem.keyEquivalentModifierMask = [.command, .shift]
        searchItem.target = self
        menu.addItem(searchItem)
        menu.addItem(NSMenuItem.separator())

        if summaries.isEmpty {
            let emptyItem = NSMenuItem(title: L10n.t(.noHistory), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            addHistoryGroups(to: menu, summaries: Array(summaries.prefix(Self.menuDisplayLimit)), startIndex: 0)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // --- Snippets Section ---
        let snippetHeader = NSMenuItem(title: L10n.t(.snippets), action: nil, keyEquivalent: "")
        snippetHeader.isEnabled = false
        menu.addItem(snippetHeader)

        for folder in snippetManager.folders {
            let categoryMenu = NSMenu()
            let categoryItem = NSMenuItem(title: "  " + folder.title, action: nil, keyEquivalent: "")

            for (index, snippet) in folder.snippets.enumerated() {
                let menuIndex = (index + 1) % 10
                let prefix = "\(menuIndex). "
                let keyEquivalent = index < 10 ? "\(menuIndex)" : ""

                let menuItem = NSMenuItem(title: prefix + snippet.title, action: #selector(menuItemClicked(_:)), keyEquivalent: keyEquivalent)
                menuItem.target = self
                menuItem.representedObject = HistoryItem.text(snippet.content)
                categoryMenu.addItem(menuItem)
            }

            categoryItem.submenu = categoryMenu
            menu.addItem(categoryItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // --- File History Section ---
        let fileHistoryItem = NSMenuItem(title: L10n.t(.fileHistory), action: nil, keyEquivalent: "")
        let fileHistorySubmenu = NSMenu()
        
        if clipboardManager.fileHistory.isEmpty {
            let emptyItem = NSMenuItem(title: L10n.t(.noFiles), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            fileHistorySubmenu.addItem(emptyItem)
        } else {
            for file in clipboardManager.fileHistory {
                let menuItem = NSMenuItem(title: file.fileName, action: #selector(fileHistoryItemClicked(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = file
                menuItem.toolTip = "\(L10n.t(.from)): \(file.senderName)\nPath: \(file.filePath)"
                fileHistorySubmenu.addItem(menuItem)
            }
        }
        fileHistoryItem.submenu = fileHistorySubmenu
        menu.addItem(fileHistoryItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // --- Phone Collector Section ---
        let collectorCount = DeviceCollectorManager.shared.eventCount
        let collectorTitle = "\(L10n.t(.phoneCollector)) (\(collectorCount))..."
        let collectorItem = NSMenuItem(title: collectorTitle, action: #selector(openCollector), keyEquivalent: "N")
        collectorItem.target = self
        collectorItem.toolTip = L10n.t(.enableCollectorSync)
        menu.addItem(collectorItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // --- LAN Devices (send file) ---
        let devicesHeader = NSMenuItem(title: L10n.t(.lanDevices), action: nil, keyEquivalent: "")
        devicesHeader.isEnabled = false
        menu.addItem(devicesHeader)
        
        let availableDevices = SyncManager.shared.availableDeviceNames
        if availableDevices.isEmpty {
            let emptyItem = NSMenuItem(title: L10n.t(.noDevicesFound), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for deviceName in availableDevices {
                let sendFileItem = NSMenuItem(
                    title: "  \(deviceName) — \(L10n.t(.sendFile))",
                    action: #selector(sendFileClicked(_:)),
                    keyEquivalent: ""
                )
                sendFileItem.target = self
                sendFileItem.representedObject = deviceName
                menu.addItem(sendFileItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem.separator())

        let screenshotItem = NSMenuItem(title: L10n.t(.screenshot), action: nil, keyEquivalent: "")
        let screenshotSubmenu = NSMenu()
        let regionItem = NSMenuItem(title: L10n.t(.screenshotRegion), action: #selector(startScreenshotRegion), keyEquivalent: "")
        regionItem.target = self
        screenshotSubmenu.addItem(regionItem)
        let windowItem = NSMenuItem(title: L10n.t(.screenshotWindow), action: #selector(startScreenshotWindow), keyEquivalent: "")
        windowItem.target = self
        screenshotSubmenu.addItem(windowItem)
        let fullscreenItem = NSMenuItem(title: L10n.t(.screenshotFullscreen), action: #selector(startScreenshotFullscreen), keyEquivalent: "")
        fullscreenItem.target = self
        screenshotSubmenu.addItem(fullscreenItem)
        screenshotItem.submenu = screenshotSubmenu
        menu.addItem(screenshotItem)

        let editSnippetsItem = NSMenuItem(title: L10n.t(.editSnippets), action: #selector(openSnippetEditor), keyEquivalent: "S")
        editSnippetsItem.target = self
        menu.addItem(editSnippetsItem)
        
        let preferencesItem = NSMenuItem(title: L10n.t(.preferences) + "...", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let clearItem = NSMenuItem(title: L10n.t(.clearHistory), action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        
        let logsItem = NSMenuItem(title: L10n.t(.showLogs), action: #selector(openLogs), keyEquivalent: "L")
        logsItem.target = self
        menu.addItem(logsItem)
        
        menu.addItem(NSMenuItem(title: L10n.t(.quit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }

    private func addHistoryGroups(to menu: NSMenu, summaries: [HistorySummary], startIndex: Int) {
        let groupSize = 10
        for start in stride(from: 0, to: summaries.count, by: groupSize) {
            let end = min(start + groupSize, summaries.count)
            let groupMenu = NSMenu()
            let groupTitle = "\(startIndex + start + 1) - \(startIndex + end)"
            let groupFolderItem = NSMenuItem(title: "  " + groupTitle, action: nil, keyEquivalent: "")

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
        let title = summary.item.title
        let displayTitle = title.count > 50 ? String(title.prefix(50)) + "..." : title

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
            fileItem.image = NSWorkspace.shared.icon(forFile: urls[0].path)
            return fileItem
        }

        if case .html = summary.item {
            let plainTitle = clipboardManager.plainText(for: summary.asEntry()) ?? title
            let htmlDisplayTitle = plainTitle.count > 50 ? String(plainTitle.prefix(50)) + "..." : plainTitle
            let htmlItem = NSMenuItem(title: prefix + htmlDisplayTitle, action: nil, keyEquivalent: keyEquivalent)
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
            menuItem.image = HistoryThumbnailCache.thumbnail(for: path)
        }

        return menuItem
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

    @objc private func openCollector() {
        collectorWindow.showWindow()
    }

    @objc private func openNotifications() {
        collectorWindow.showWindow()
    }
    
    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.makeKeyAndOrderFront(nil)
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
        updateMenu(with: clipboardManager.recentSummaries)
    }
}
