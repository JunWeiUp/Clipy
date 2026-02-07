import AppKit

class MenuController: NSObject {
    private var statusItem: NSStatusItem!
    private let clipboardManager = ClipboardManager.shared
    private let snippetManager = SnippetManager.shared
    private let syncManager = SyncManager.shared
    
    override init() {
        super.init()
        setupStatusItem()
        setupClipboardObserver()
        setupSnippetObserver()
        setupHotKeyObserver()
        setupSyncObserver()
    }
    
    private func setupSyncObserver() {
        syncManager.onDevicesChanged = { [weak self] _ in
            self?.updateMenu(with: self?.clipboardManager.history ?? [])
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
    }
    
    private func setupClipboardObserver() {
        clipboardManager.onHistoryChanged = { [weak self] history in
            self?.updateMenu(with: history)
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
        
        // --- Devices Section ---
        let devicesHeader = NSMenuItem(title: "Sync Devices", action: nil, keyEquivalent: "")
        devicesHeader.isEnabled = false
        menu.addItem(devicesHeader)
        
        let devices = syncManager.discoveredDevices
        if !PreferencesManager.shared.isSyncEnabled {
            let disabledItem = NSMenuItem(title: "  Sync Disabled", action: nil, keyEquivalent: "")
            disabledItem.isEnabled = false
            menu.addItem(disabledItem)
        } else if devices.isEmpty {
            let searchingItem = NSMenuItem(title: "  Searching...", action: nil, keyEquivalent: "")
            searchingItem.isEnabled = false
            menu.addItem(searchingItem)
        } else {
            for device in devices {
                let isAllowed = PreferencesManager.shared.allowedDevices.contains(device)
                let deviceItem = NSMenuItem(title: "  📱 " + device, action: #selector(toggleDeviceSync(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = device
                deviceItem.state = isAllowed ? .on : .off
                menu.addItem(deviceItem)
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
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? HistoryItem {
            clipboardManager.copyToPasteboard(item)
        }
    }
    
    @objc private func toggleDeviceSync(_ sender: NSMenuItem) {
        if let deviceName = sender.representedObject as? String {
            PreferencesManager.shared.toggleDeviceAllowance(deviceName)
            // Refresh menu to show checkmark change
            updateMenu(with: clipboardManager.history)
        }
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
}
