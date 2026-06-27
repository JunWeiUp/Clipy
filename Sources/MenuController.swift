import AppKit

class MenuController: NSObject {
    private static let menuDisplayLimit = 50
    private static let menuShortcutHistoryLimit = 50
    private var statusItem: NSStatusItem!
    private let clipboardManager = ClipboardManager.shared
    private let snippetManager = SnippetManager.shared
    private lazy var notificationWindow = NotificationWindow()
    private lazy var collectorWindow = CollectorWindow()
    
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
        NotificationManager.shared.onNotificationsChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenu(with: self?.clipboardManager.history ?? [])
            }
        }
        DeviceCollectorManager.shared.onEventsChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenu(with: self?.clipboardManager.history ?? [])
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
            self?.updateMenu(with: self?.clipboardManager.history ?? [])
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "📋"
        }
        
        updateMenu(with: clipboardManager.history)
        
        SyncManager.shared.onDevicesChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenu(with: self?.clipboardManager.history ?? [])
            }
        }
    }
    
    private func setupClipboardObserver() {
        clipboardManager.onHistoryChanged = { [weak self] history in
            DispatchQueue.main.async {
                self?.updateMenu(with: history)
            }
        }
        clipboardManager.onFileHistoryChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenu(with: self?.clipboardManager.history ?? [])
            }
        }
    }
    
    private func updateMenu(with history: [HistoryEntry]) {
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

        if history.isEmpty {
            let emptyItem = NSMenuItem(title: L10n.t(.noHistory), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            addHistoryGroups(to: menu, history: Array(history.prefix(Self.menuDisplayLimit)), startIndex: 0)
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
        let collectorCount = DeviceCollectorManager.shared.events.count
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

    private func addHistoryGroups(to menu: NSMenu, history: [HistoryEntry], startIndex: Int) {
        let groupSize = 10
        for start in stride(from: 0, to: history.count, by: groupSize) {
            let end = min(start + groupSize, history.count)
            let groupMenu = NSMenu()
            let groupTitle = "\(startIndex + start + 1) - \(startIndex + end)"
            let groupFolderItem = NSMenuItem(title: "  " + groupTitle, action: nil, keyEquivalent: "")

            for i in start..<end {
                let entry = history[i]
                let menuItem = makeHistoryMenuItem(entry: entry, indexInGroup: i - start, startIndex: startIndex)
                groupMenu.addItem(menuItem)
            }

            groupFolderItem.submenu = groupMenu
            menu.addItem(groupFolderItem)
        }
    }
    
    private func makeHistoryMenuItem(entry: HistoryEntry, indexInGroup: Int, startIndex: Int) -> NSMenuItem {
        let title = entry.item.title
        let displayTitle = title.count > 50 ? String(title.prefix(50)) + "..." : title

        let menuIndex = (indexInGroup + 1) % 10
        let prefix = "\(menuIndex). "
        let keyEquivalent = startIndex + indexInGroup < Self.menuShortcutHistoryLimit ? "\(menuIndex)" : ""

        if entry.item.isFile, let urls = entry.item.fileURLs {
            let fileItem = NSMenuItem(title: prefix + displayTitle, action: nil, keyEquivalent: keyEquivalent)
            let fileSubmenu = NSMenu()

            let pasteNameItem = NSMenuItem(title: L10n.t(.pasteFileName), action: #selector(pasteFileNameClicked(_:)), keyEquivalent: "")
            pasteNameItem.target = self
            pasteNameItem.representedObject = entry
            fileSubmenu.addItem(pasteNameItem)

            let pasteFileItem = NSMenuItem(title: L10n.t(.pasteFile), action: #selector(pasteFileClicked(_:)), keyEquivalent: "")
            pasteFileItem.target = self
            pasteFileItem.representedObject = entry
            fileSubmenu.addItem(pasteFileItem)

            let revealItem = NSMenuItem(title: L10n.t(.showInFinder), action: #selector(revealHistoryFileInFinder(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = entry
            fileSubmenu.addItem(revealItem)

            fileItem.submenu = fileSubmenu
            fileItem.toolTip = historyFileToolTip(for: entry, urls: urls)
            fileItem.image = NSWorkspace.shared.icon(forFile: urls[0].path)
            return fileItem
        }

        let menuItem = NSMenuItem(title: prefix + displayTitle, action: #selector(menuItemClicked(_:)), keyEquivalent: keyEquivalent)
        menuItem.target = self
        menuItem.representedObject = entry
        menuItem.toolTip = historyToolTip(for: entry)

        if case .image(let path) = entry.item, let image = NSImage(contentsOf: URL(fileURLWithPath: path)) {
            let iconSize = NSSize(width: 24, height: 24)
            image.size = iconSize
            menuItem.image = image
        }

        return menuItem
    }

    private func historyToolTip(for entry: HistoryEntry) -> String? {
        var parts: [String] = []
        if let location = entry.item.locationSummary {
            parts.append("\(L10n.t(.location)): \(location)")
        }
        if let app = entry.sourceApp {
            parts.append("\(L10n.t(.source)): \(app)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func historyFileToolTip(for entry: HistoryEntry, urls: [URL]) -> String {
        var parts: [String] = []
        if let location = entry.item.locationSummary {
            parts.append("\(L10n.t(.location)): \(location)")
        } else {
            parts.append(urls.map(\.path).joined(separator: "\n"))
        }
        if let app = entry.sourceApp {
            parts.append("\(L10n.t(.source)): \(app)")
        }
        return parts.joined(separator: "\n")
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? HistoryEntry {
            clipboardManager.moveHistoryEntryToFront(entry)
            clipboardManager.copyToPasteboard(entry.item)
        } else if let item = sender.representedObject as? HistoryItem {
            clipboardManager.copyToPasteboard(item)
        }
    }

    @objc private func pasteFileNameClicked(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry,
              let urls = entry.item.fileURLs else { return }
        clipboardManager.moveHistoryEntryToFront(entry)
        clipboardManager.copyFileNamesToPasteboard(urls)
    }

    @objc private func pasteFileClicked(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        clipboardManager.moveHistoryEntryToFront(entry)
        clipboardManager.writeToPasteboard(entry.item)
    }

    @objc private func revealHistoryFileInFinder(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        clipboardManager.revealInFinder(for: entry)
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
    }

    @objc private func languageDidChange() {
        updateMenu(with: clipboardManager.history)
    }
}
