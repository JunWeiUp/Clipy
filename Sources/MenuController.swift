import AppKit

class MenuController: NSObject {
    private var statusItem: NSStatusItem!
    private let clipboardManager = ClipboardManager.shared
    private let snippetManager = SnippetManager.shared
    
    override init() {
        super.init()
        setupStatusItem()
        setupClipboardObserver()
        setupSnippetObserver()
        setupHotKeyObserver()
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
        let menu = NSMenu()
        for (index, snippet) in folder.snippets.enumerated() {
            let menuIndex = (index + 1) % 10
            let prefix = "\(menuIndex). "
            let keyEquivalent = index < 10 ? "\(menuIndex)" : ""
            
            let menuItem = NSMenuItem(title: prefix + snippet.title, action: #selector(menuItemClicked(_:)), keyEquivalent: keyEquivalent)
            menuItem.target = self
            menuItem.representedObject = HistoryItem.text(snippet.content)
            menu.addItem(menuItem)
        }
        
        // Show menu at mouse location
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
        let historyHeader = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyHeader.isEnabled = false
        menu.addItem(historyHeader)
        
        if history.isEmpty {
            let emptyItem = NSMenuItem(title: "  No History", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            // Grouping history into folders (Clipy style: 10 items per folder)
            let groupSize = 10
            let groups = stride(from: 0, to: history.count, by: groupSize)
            
            for start in groups {
                let end = min(start + groupSize, history.count)
                let groupMenu = NSMenu()
                let groupTitle = "\(start + 1) - \(end)"
                let groupFolderItem = NSMenuItem(title: "  " + groupTitle, action: nil, keyEquivalent: "")
                
                for i in start..<end {
                    let entry = history[i]
                    let title = entry.item.title
                    let displayTitle = title.count > 50 ? String(title.prefix(50)) + "..." : title
                    
                    // Add index prefix (1, 2, ..., 9, 0)
                    let indexInGroup = i - start
                    let menuIndex = (indexInGroup + 1) % 10
                    let prefix = "\(menuIndex). "
                    let keyEquivalent = "\(menuIndex)"
                    
                    let menuItem = NSMenuItem(title: prefix + displayTitle, action: #selector(menuItemClicked(_:)), keyEquivalent: keyEquivalent)
                    menuItem.target = self
                    menuItem.representedObject = entry.item
                    
                    // Add app source if available
                    if let app = entry.sourceApp {
                        menuItem.toolTip = "Source: \(app)"
                    }
                    
                    // Add image preview
                    if case .image(let data) = entry.item, let image = NSImage(data: data) {
                        let iconSize = NSSize(width: 24, height: 24)
                        image.size = iconSize
                        menuItem.image = image
                    }
                    
                    groupMenu.addItem(menuItem)
                }
                
                groupFolderItem.submenu = groupMenu
                menu.addItem(groupFolderItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // --- Snippets Section ---
        let snippetHeader = NSMenuItem(title: "Snippets", action: nil, keyEquivalent: "")
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
        let fileHistoryItem = NSMenuItem(title: "File History", action: nil, keyEquivalent: "")
        let fileHistorySubmenu = NSMenu()
        
        if clipboardManager.fileHistory.isEmpty {
            let emptyItem = NSMenuItem(title: "No Files", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            fileHistorySubmenu.addItem(emptyItem)
        } else {
            for file in clipboardManager.fileHistory {
                let menuItem = NSMenuItem(title: file.fileName, action: #selector(fileHistoryItemClicked(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = file
                menuItem.toolTip = "From: \(file.senderName)\nPath: \(file.filePath)"
                fileHistorySubmenu.addItem(menuItem)
            }
        }
        fileHistoryItem.submenu = fileHistorySubmenu
        menu.addItem(fileHistoryItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // --- Authorized Devices Section ---
        let devicesHeader = NSMenuItem(title: "Authorized Devices", action: nil, keyEquivalent: "")
        devicesHeader.isEnabled = false
        menu.addItem(devicesHeader)
        
        let availableDevices = SyncManager.shared.availableDeviceNames
        if availableDevices.isEmpty {
            let emptyItem = NSMenuItem(title: "  No Devices Found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for deviceName in availableDevices {
                let deviceMenuItem = NSMenuItem(title: "  " + deviceName, action: nil, keyEquivalent: "")
                let deviceSubmenu = NSMenu()
                
                // Authorization Toggle
                let authItem = NSMenuItem(title: "Authorized", action: #selector(toggleDeviceAuthorization(_:)), keyEquivalent: "")
                authItem.target = self
                authItem.representedObject = deviceName
                let isAuthorized = PreferencesManager.shared.authorizedDevices.contains(deviceName)
                authItem.state = isAuthorized ? .on : .off
                deviceSubmenu.addItem(authItem)
                
                // Send File Action (only if authorized)
                if isAuthorized {
                    deviceSubmenu.addItem(NSMenuItem.separator())
                    let sendFileItem = NSMenuItem(title: "Send File...", action: #selector(sendFileClicked(_:)), keyEquivalent: "")
                    sendFileItem.target = self
                    sendFileItem.representedObject = deviceName
                    deviceSubmenu.addItem(sendFileItem)
                }
                
                deviceMenuItem.submenu = deviceSubmenu
                menu.addItem(deviceMenuItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let editSnippetsItem = NSMenuItem(title: "Edit Snippets...", action: #selector(openSnippetEditor), keyEquivalent: "S")
        editSnippetsItem.target = self
        menu.addItem(editSnippetsItem)
        
        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        
        let logsItem = NSMenuItem(title: "Show Logs...", action: #selector(openLogs), keyEquivalent: "L")
        logsItem.target = self
        menu.addItem(logsItem)
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? HistoryItem {
            clipboardManager.copyToPasteboard(item)
        }
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
        openPanel.message = "Choose a file to send to \(deviceName)"
        openPanel.prompt = "Send"
        
        // Use runModal to ensure the dialog appears and blocks until a choice is made
        let response = openPanel.runModal()
        if response == .OK, let url = openPanel.url {
            appLog("Selected file: \(url.lastPathComponent), sending...")
            SyncManager.shared.sendFile(at: url, toDevice: deviceName)
        }
    }
    
    @objc private func toggleDeviceAuthorization(_ sender: NSMenuItem) {
        guard let deviceName = sender.representedObject as? String else { return }
        
        var authorizedDevices = PreferencesManager.shared.authorizedDevices
        if authorizedDevices.contains(deviceName) {
            authorizedDevices.removeAll { $0 == deviceName }
            sender.state = .off
        } else {
            authorizedDevices.append(deviceName)
            sender.state = .on
        }
        PreferencesManager.shared.authorizedDevices = authorizedDevices
    }
    
    @objc private func clearHistory() {
        clipboardManager.clearHistory()
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
}
