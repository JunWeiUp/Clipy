import AppKit

class ShortcutRecorderView: NSView {
    var onShortcutChanged: ((ShortcutCombo?) -> Void)?
    var combo: ShortcutCombo? {
        didSet {
            updateDisplay()
        }
    }
    
    private let label = NSTextField(labelWithString: "点击录制快捷键")
    private let clearButton = NSButton(title: "✕", target: nil, action: nil)
    private var isRecording = false
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.frame = NSRect(x: 5, y: 5, width: bounds.width - 35, height: bounds.height - 10)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        
        clearButton.frame = NSRect(x: bounds.width - 25, y: (bounds.height - 20) / 2, width: 20, height: 20)
        clearButton.bezelStyle = .circular
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.isHidden = true
        addSubview(clearButton)
    }
    
    private func updateDisplay() {
        if isRecording {
            label.stringValue = "录制中..."
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            clearButton.isHidden = true
        } else if let combo = combo {
            label.stringValue = combo.displayString
            layer?.borderColor = NSColor.separatorColor.cgColor
            clearButton.isHidden = false
        } else {
            label.stringValue = "点击录制快捷键"
            layer?.borderColor = NSColor.separatorColor.cgColor
            clearButton.isHidden = true
        }
    }
    
    @objc private func clearShortcut() {
        combo = nil
        onShortcutChanged?(nil)
        updateDisplay()
    }
    
    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
        updateDisplay()
    }
    
    override var acceptsFirstResponder: Bool { true }
    
    override func resignFirstResponder() -> Bool {
        isRecording = false
        updateDisplay()
        return true
    }
    
    override func keyDown(with event: NSEvent) {
        if isRecording {
            if event.keyCode == 53 { // ESC
                isRecording = false
                window?.makeFirstResponder(nil)
                updateDisplay()
                return
            }
            
            // Only record if at least one modifier is pressed, or it's a function key
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !modifiers.isEmpty || (event.keyCode >= 96 && event.keyCode <= 101) {
                let combo = ShortcutCombo(keyCode: Int(event.keyCode), modifierFlags: event.modifierFlags.rawValue)
                self.combo = combo
                isRecording = false
                onShortcutChanged?(combo)
                window?.makeFirstResponder(nil)
                updateDisplay()
            }
        }
    }
}

class SnippetEditorWindow: NSWindow {
    static let shared = SnippetEditorWindow()
    
    private var splitView: NSSplitView!
    private var sidebarView: NSOutlineView!
    private var detailView: NSView!
    private var currentSelection: Any?
    
    init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                   styleMask: styleMask,
                   backing: .buffered,
                   defer: false)
        self.isReleasedWhenClosed = false
        
        self.title = "Clipy - 片段编辑器"
        self.center()
        setupToolbar()
        setupUI()
    }
    
    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "SnippetToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        self.toolbar = toolbar
    }
    
    private func setupUI() {
        let contentView = NSView(frame: self.frame)
        self.contentView = contentView
        
        splitView = NSSplitView(frame: contentView.bounds)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        contentView.addSubview(splitView)
        
        // Sidebar
        let sidebarScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        sidebarScrollView.hasVerticalScroller = true
        
        sidebarView = NSOutlineView(frame: sidebarScrollView.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.title = "Name"
        sidebarView.addTableColumn(column)
        sidebarView.outlineTableColumn = column
        sidebarView.headerView = nil
        sidebarView.delegate = self
        sidebarView.dataSource = self
        
        sidebarScrollView.documentView = sidebarView
        splitView.addArrangedSubview(sidebarScrollView)
        
        // Detail View
        detailView = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 600))
        splitView.addArrangedSubview(detailView)
        
        updateDetailView()
    }
    
    func updateDetailView() {
        detailView.subviews.forEach { $0.removeFromSuperview() }
        
        if let folder = currentSelection as? SnippetFolder {
            showFolderDetail(folder)
        } else if let snippet = currentSelection as? Snippet {
            showSnippetDetail(snippet)
        } else {
            let label = NSTextField(labelWithString: "请在左侧选择一个文件夹或片段")
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: (detailView.bounds.width - 200)/2, y: detailView.bounds.height/2, width: 200, height: 20)
            detailView.addSubview(label)
        }
    }
    
    private func showFolderDetail(_ folder: SnippetFolder) {
        let titleLabel = NSTextField(labelWithString: "文件夹名称")
        titleLabel.frame = NSRect(x: 50, y: 520, width: 100, height: 20)
        detailView.addSubview(titleLabel)
        
        let titleField = NSTextField(frame: NSRect(x: 50, y: 490, width: 400, height: 24))
        titleField.stringValue = folder.title
        titleField.target = self
        titleField.action = #selector(folderTitleChanged(_:))
        detailView.addSubview(titleField)
        
        let shortcutLabel = NSTextField(labelWithString: "快捷键")
        shortcutLabel.frame = NSRect(x: 50, y: 440, width: 100, height: 20)
        detailView.addSubview(shortcutLabel)
        
        let recorder = ShortcutRecorderView(frame: NSRect(x: 50, y: 400, width: 200, height: 30))
        recorder.combo = folder.shortcut
        recorder.onShortcutChanged = { [weak self] newCombo in
            SnippetManager.shared.updateFolderShortcut(id: folder.id, shortcut: newCombo)
            self?.sidebarView.reloadData()
        }
        detailView.addSubview(recorder)
        
        let infoLabel = NSTextField(labelWithString: "设置后可通过快捷键直接弹出该文件夹菜单")
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.frame = NSRect(x: 50, y: 380, width: 300, height: 15)
        detailView.addSubview(infoLabel)
    }
    
    @objc private func folderTitleChanged(_ sender: NSTextField) {
        guard let folder = currentSelection as? SnippetFolder else { return }
        SnippetManager.shared.updateFolderTitle(id: folder.id, title: sender.stringValue)
        sidebarView.reloadData()
    }
    
    private func showSnippetDetail(_ snippet: Snippet) {
        let titleLabel = NSTextField(labelWithString: "片段标题")
        titleLabel.frame = NSRect(x: 50, y: 520, width: 100, height: 20)
        detailView.addSubview(titleLabel)
        
        let titleField = NSTextField(frame: NSRect(x: 50, y: 490, width: 400, height: 24))
        titleField.stringValue = snippet.title
        titleField.target = self
        titleField.action = #selector(snippetTitleChanged(_:))
        detailView.addSubview(titleField)
        
        let contentLabel = NSTextField(labelWithString: "内容")
        contentLabel.frame = NSRect(x: 50, y: 450, width: 100, height: 20)
        detailView.addSubview(contentLabel)
        
        let scrollView = NSScrollView(frame: NSRect(x: 50, y: 100, width: 450, height: 340))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        
        let textView = NSTextView(frame: scrollView.bounds)
        textView.string = snippet.content
        textView.isRichText = false
        textView.delegate = self
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        detailView.addSubview(scrollView)
        
        let shortcutLabel = NSTextField(labelWithString: "快捷键")
        shortcutLabel.frame = NSRect(x: 50, y: 70, width: 100, height: 20)
        detailView.addSubview(shortcutLabel)
        
        let recorder = ShortcutRecorderView(frame: NSRect(x: 50, y: 30, width: 200, height: 30))
        recorder.combo = snippet.shortcut
        recorder.onShortcutChanged = { [weak self] newCombo in
            self?.updateSnippetShortcut(snippet.id, newCombo)
        }
        detailView.addSubview(recorder)
    }
    
    private func updateSnippetShortcut(_ snippetId: UUID, _ combo: ShortcutCombo?) {
        SnippetManager.shared.updateSnippetShortcut(id: snippetId, shortcut: combo)
        sidebarView.reloadData()
    }
    
    @objc private func snippetTitleChanged(_ sender: NSTextField) {
        guard let snippet = currentSelection as? Snippet else { return }
        SnippetManager.shared.updateSnippetTitle(id: snippet.id, title: sender.stringValue)
        sidebarView.reloadData()
    }
}

extension SnippetEditorWindow: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let snippet = currentSelection as? Snippet else { return }
        
        SnippetManager.shared.updateSnippetContent(id: snippet.id, content: textView.string)
    }
}

extension SnippetEditorWindow {
    @objc func addSnippetAction() {
        if let folder = currentSelection as? SnippetFolder {
            SnippetManager.shared.addSnippet(to: folder.id, title: "新片段", content: "")
            sidebarView.reloadData()
            sidebarView.expandItem(folder)
        }
    }
    
    @objc func addFolderAction() {
        SnippetManager.shared.addFolder(title: "新文件夹")
        sidebarView.reloadData()
    }
    
    @objc func deleteAction() {
        guard let selection = currentSelection else { return }
        
        let alert = NSAlert()
        alert.messageText = "确定要删除吗？"
        alert.informativeText = "此操作不可撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let folder = selection as? SnippetFolder {
                SnippetManager.shared.deleteFolder(id: folder.id)
            } else if let snippet = selection as? Snippet {
                SnippetManager.shared.deleteSnippet(id: snippet.id)
            }
            currentSelection = nil
            sidebarView.reloadData()
            updateDetailView()
        }
    }
    
    @objc func importAction() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.allowedFileTypes = ["xml", "clipy"]
        
        openPanel.begin { [weak self] response in
            if response == .OK, let url = openPanel.url {
                do {
                    let xmlString = try String(contentsOf: url, encoding: .utf8)
                    SnippetManager.shared.importFromXML(xmlString)
                    DispatchQueue.main.async {
                        self?.sidebarView.reloadData()
                    }
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "导入失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @objc func exportAction() {
        let savePanel = NSSavePanel()
        savePanel.title = "导出片段"
        savePanel.nameFieldStringValue = "ClipySnippets.clipy"
        savePanel.allowedFileTypes = ["clipy", "xml"]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            let xml = SnippetManager.shared.exportToXMLString()
            do {
                try xml.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

extension SnippetEditorWindow: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return SnippetManager.shared.folders.count
        } else if let folder = item as? SnippetFolder {
            return folder.snippets.count
        }
        return 0
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return SnippetManager.shared.folders[index]
        } else if let folder = item as? SnippetFolder {
            return folder.snippets[index]
        }
        return ""
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is SnippetFolder
    }
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SnippetCell")
        var view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
        if view == nil {
            view = NSTableCellView()
            view?.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.isBordered = false
            textField.drawsBackground = false
            view?.textField = textField
            view?.addSubview(textField)
            textField.frame = NSRect(x: 20, y: 0, width: 200, height: 20)
        }
        
        if let folder = item as? SnippetFolder {
            view?.textField?.stringValue = "📁 " + folder.title
        } else if let snippet = item as? Snippet {
            view?.textField?.stringValue = "📄 " + snippet.title
        }
        
        return view
    }
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarView.selectedRow
        if row >= 0 {
            currentSelection = sidebarView.item(atRow: row)
            updateDetailView()
        }
    }
}

extension SnippetEditorWindow: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier.rawValue {
        case "addSnippet":
            item.label = "添加片段"
            item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(addSnippetAction)
        case "addFolder":
            item.label = "添加文件夹"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(addFolderAction)
        case "delete":
            item.label = "删除"
            item.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(deleteAction)
        case "import":
            item.label = "导入"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(importAction)
        case "export":
            item.label = "导出"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(exportAction)
        default:
            return nil
        }
        return item
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            NSToolbarItem.Identifier("addSnippet"),
            NSToolbarItem.Identifier("addFolder"),
            NSToolbarItem.Identifier("delete"),
            .flexibleSpace,
            NSToolbarItem.Identifier("import"),
            NSToolbarItem.Identifier("export")
        ]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }
}
