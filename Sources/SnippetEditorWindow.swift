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
            if event.keyCode == 53 {
                isRecording = false
                window?.makeFirstResponder(nil)
                updateDisplay()
                return
            }
            
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
    
    private final class SidebarNode {
        enum Kind {
            case folder(UUID)
            case snippet(id: UUID, folderId: UUID)
        }
        
        let kind: Kind
        var children: [SidebarNode] = []
        
        init(kind: Kind) {
            self.kind = kind
        }
        
        var folderId: UUID? {
            if case .folder(let id) = kind { return id }
            return nil
        }
        
        var snippetId: UUID? {
            if case .snippet(let id, _) = kind { return id }
            return nil
        }
    }
    
    private enum SidebarSelection {
        case folder(UUID)
        case snippet(UUID)
    }
    
    private var splitView: NSSplitView!
    private var sidebarView: NSOutlineView!
    private var detailView: NSView!
    private var sidebarNodes: [SidebarNode] = []
    private var folderNodesById: [UUID: SidebarNode] = [:]
    private var snippetNodesById: [UUID: SidebarNode] = [:]
    private var selectedFolderId: UUID?
    private var selectedSnippetId: UUID?
    private weak var activeFolderTitleField: NSTextField?
    private weak var activeSnippetTitleField: NSTextField?
    private var isReloadingSidebar = false
    
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
        reloadSidebar(selecting: nil)
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
        splitView.delegate = self
        contentView.addSubview(splitView)
        
        let sidebarScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        sidebarScrollView.hasVerticalScroller = true
        
        sidebarView = NSOutlineView(frame: sidebarScrollView.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.title = "Name"
        column.width = sidebarScrollView.bounds.width
        column.resizingMask = .autoresizingMask
        sidebarView.addTableColumn(column)
        sidebarView.outlineTableColumn = column
        sidebarView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sidebarView.headerView = nil
        sidebarView.rowHeight = 24
        sidebarView.delegate = self
        sidebarView.dataSource = self
        sidebarView.registerForDraggedTypes([.string])
        sidebarView.setDraggingSourceOperationMask(.move, forLocal: true)
        sidebarView.setDraggingSourceOperationMask([], forLocal: false)
        
        sidebarScrollView.documentView = sidebarView
        splitView.addArrangedSubview(sidebarScrollView)
        
        detailView = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 600))
        splitView.addArrangedSubview(detailView)
        
        updateDetailView()
    }
    
    private func rebuildSidebarNodes() {
        var folders: [SidebarNode] = []
        var folderMap: [UUID: SidebarNode] = [:]
        var snippetMap: [UUID: SidebarNode] = [:]
        
        for folder in SnippetManager.shared.folders {
            let folderNode = SidebarNode(kind: .folder(folder.id))
            folderNode.children = folder.snippets.map { snippet in
                let node = SidebarNode(kind: .snippet(id: snippet.id, folderId: folder.id))
                snippetMap[snippet.id] = node
                return node
            }
            folders.append(folderNode)
            folderMap[folder.id] = folderNode
        }
        
        sidebarNodes = folders
        folderNodesById = folderMap
        snippetNodesById = snippetMap
    }
    
    private func reloadSidebar(selecting selection: SidebarSelection?, expanding extraExpandedFolderIds: Set<UUID> = [], preserveSelectionWhenNil: Bool = true) {
        let visibleOrigin = sidebarView.enclosingScrollView?.contentView.bounds.origin
        var expandedFolderIds = currentExpandedFolderIds().union(extraExpandedFolderIds)
        let selectionToRestore = selection ?? (preserveSelectionWhenNil ? currentSelection() : nil)
        
        if case .folder(let folderId) = selectionToRestore {
            expandedFolderIds.insert(folderId)
        } else if case .snippet(let snippetId) = selectionToRestore,
                  let folderId = Self.folderId(containingSnippetId: snippetId) {
            expandedFolderIds.insert(folderId)
        }
        
        rebuildSidebarNodes()
        isReloadingSidebar = true
        sidebarView.reloadData()
        restoreExpandedFolders(expandedFolderIds)
        restoreSelection(selectionToRestore)
        restoreSidebarScrollPosition(visibleOrigin)
        isReloadingSidebar = false
        syncSelection(selectionToRestore)
    }
    
    private func currentExpandedFolderIds() -> Set<UUID> {
        var ids = Set<UUID>()
        guard sidebarView != nil else { return ids }
        for row in 0..<sidebarView.numberOfRows {
            guard let node = sidebarView.item(atRow: row) as? SidebarNode,
                  let folderId = node.folderId,
                  sidebarView.isItemExpanded(node) else { continue }
            ids.insert(folderId)
        }
        return ids
    }
    
    private func restoreExpandedFolders(_ ids: Set<UUID>) {
        for id in ids {
            guard let node = folderNodesById[id] else { continue }
            sidebarView.expandItem(node, expandChildren: false)
        }
    }
    
    private func restoreSelection(_ selection: SidebarSelection?) {
        guard let selection else {
            sidebarView.deselectAll(nil)
            return
        }
        
        let node: SidebarNode?
        switch selection {
        case .folder(let id):
            node = folderNodesById[id]
        case .snippet(let id):
            node = snippetNodesById[id]
        }
        
        guard let node else {
            sidebarView.deselectAll(nil)
            return
        }
        
        let row = sidebarView.row(forItem: node)
        if row >= 0 {
            sidebarView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            sidebarView.scrollRowToVisible(row)
        }
    }
    
    private func restoreSidebarScrollPosition(_ origin: NSPoint?) {
        guard let origin,
              let scrollView = sidebarView.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    
    private func currentSelection() -> SidebarSelection? {
        if let selected = selectedNodeSelection() {
            return selected
        }
        if let snippetId = selectedSnippetId, Self.latestSnippet(matching: snippetId) != nil {
            return .snippet(snippetId)
        }
        if let folderId = selectedFolderId, Self.latestFolder(matching: folderId) != nil {
            return .folder(folderId)
        }
        return nil
    }
    
    private func selectedNodeSelection() -> SidebarSelection? {
        let row = sidebarView.selectedRow
        guard row >= 0, let node = sidebarView.item(atRow: row) as? SidebarNode else { return nil }
        switch node.kind {
        case .folder(let id):
            return .folder(id)
        case .snippet(let id, _):
            return .snippet(id)
        }
    }
    
    private func syncSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .folder(let id):
            selectedFolderId = Self.latestFolder(matching: id) == nil ? nil : id
            selectedSnippetId = nil
        case .snippet(let id):
            selectedSnippetId = Self.latestSnippet(matching: id) == nil ? nil : id
            selectedFolderId = nil
        case nil:
            selectedFolderId = nil
            selectedSnippetId = nil
        }
    }
    
    private func destinationFolderIdForNewSnippet() -> UUID? {
        if let selection = currentSelection() {
            switch selection {
            case .folder(let folderId):
                return folderId
            case .snippet(let snippetId):
                return Self.folderId(containingSnippetId: snippetId)
            }
        }
        if let firstFolder = SnippetManager.shared.folders.first {
            return firstFolder.id
        }
        SnippetManager.shared.addFolder(title: "新文件夹")
        return SnippetManager.shared.folders.last?.id
    }
    
    private func refreshCurrentSidebarRow() {
        guard let selection = currentSelection() else { return }
        let node: SidebarNode?
        switch selection {
        case .folder(let id):
            node = folderNodesById[id]
        case .snippet(let id):
            node = snippetNodesById[id]
        }
        guard let node else { return }
        let row = sidebarView.row(forItem: node)
        guard row >= 0 else { return }
        sidebarView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }
    
    func updateDetailView() {
        detailView.subviews.forEach { $0.removeFromSuperview() }
        activeFolderTitleField = nil
        activeSnippetTitleField = nil
        
        if let snippetId = selectedSnippetId, let snippet = Self.latestSnippet(matching: snippetId) {
            showSnippetDetail(snippet)
        } else if let folderId = selectedFolderId, let folder = Self.latestFolder(matching: folderId) {
            showFolderDetail(folder)
        } else {
            showEmptyDetail()
        }
    }
    
    private func showEmptyDetail() {
        let label = NSTextField(labelWithString: "请在左侧选择一个文件夹或片段")
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: (detailView.bounds.width - 220) / 2, y: detailView.bounds.height / 2, width: 220, height: 20)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        detailView.addSubview(label)
    }
    
    private func showFolderDetail(_ folder: SnippetFolder) {
        selectedFolderId = folder.id
        selectedSnippetId = nil
        
        let titleLabel = NSTextField(labelWithString: "文件夹名称")
        titleLabel.frame = NSRect(x: 50, y: 520, width: 100, height: 20)
        detailView.addSubview(titleLabel)
        
        let titleField = NSTextField(frame: NSRect(x: 50, y: 490, width: 400, height: 24))
        titleField.stringValue = folder.title
        titleField.delegate = self
        detailView.addSubview(titleField)
        activeFolderTitleField = titleField
        
        let shortcutLabel = NSTextField(labelWithString: "快捷键")
        shortcutLabel.frame = NSRect(x: 50, y: 440, width: 100, height: 20)
        detailView.addSubview(shortcutLabel)
        
        let recorder = ShortcutRecorderView(frame: NSRect(x: 50, y: 400, width: 200, height: 30))
        recorder.combo = folder.shortcut
        recorder.onShortcutChanged = { newCombo in
            SnippetManager.shared.updateFolderShortcut(id: folder.id, shortcut: newCombo)
        }
        detailView.addSubview(recorder)
        
        let infoLabel = NSTextField(labelWithString: "设置后可通过快捷键直接弹出该文件夹菜单")
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.frame = NSRect(x: 50, y: 380, width: 300, height: 15)
        detailView.addSubview(infoLabel)
    }
    
    private func showSnippetDetail(_ snippet: Snippet) {
        selectedSnippetId = snippet.id
        selectedFolderId = nil
        
        let titleLabel = NSTextField(labelWithString: "片段标题")
        titleLabel.frame = NSRect(x: 50, y: 520, width: 100, height: 20)
        detailView.addSubview(titleLabel)
        
        let titleField = NSTextField(frame: NSRect(x: 50, y: 490, width: 400, height: 24))
        titleField.stringValue = snippet.title
        titleField.delegate = self
        detailView.addSubview(titleField)
        activeSnippetTitleField = titleField
        
        let contentLabel = NSTextField(labelWithString: "内容")
        contentLabel.frame = NSRect(x: 50, y: 450, width: 100, height: 20)
        detailView.addSubview(contentLabel)
        
        let scrollView = NSScrollView(frame: NSRect(x: 50, y: 100, width: 450, height: 340))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        
        let textView = NSTextView(frame: scrollView.bounds)
        textView.string = snippet.content
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textStorage?.delegate = self
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        detailView.addSubview(scrollView)
        
        let shortcutLabel = NSTextField(labelWithString: "快捷键")
        shortcutLabel.frame = NSRect(x: 50, y: 70, width: 100, height: 20)
        detailView.addSubview(shortcutLabel)
        
        let recorder = ShortcutRecorderView(frame: NSRect(x: 50, y: 30, width: 200, height: 30))
        recorder.combo = snippet.shortcut
        recorder.onShortcutChanged = { newCombo in
            SnippetManager.shared.updateSnippetShortcut(id: snippet.id, shortcut: newCombo)
        }
        detailView.addSubview(recorder)
    }
    
    private static func latestFolder(matching id: UUID) -> SnippetFolder? {
        SnippetManager.shared.folders.first { $0.id == id }
    }
    
    private static func latestSnippet(matching id: UUID) -> Snippet? {
        for folder in SnippetManager.shared.folders {
            if let snippet = folder.snippets.first(where: { $0.id == id }) {
                return snippet
            }
        }
        return nil
    }
    
    private static func folderId(containingSnippetId id: UUID) -> UUID? {
        for folder in SnippetManager.shared.folders {
            if folder.snippets.contains(where: { $0.id == id }) {
                return folder.id
            }
        }
        return nil
    }
    
    private static func folderAndSnippetIndex(forSnippetId id: UUID) -> (UUID, Int)? {
        for folder in SnippetManager.shared.folders {
            if let idx = folder.snippets.firstIndex(where: { $0.id == id }) {
                return (folder.id, idx)
            }
        }
        return nil
    }
    
    private static func selectionAfterDeletingSnippet(_ id: UUID) -> SidebarSelection? {
        for folder in SnippetManager.shared.folders {
            guard let index = folder.snippets.firstIndex(where: { $0.id == id }) else { continue }
            if index > 0 {
                return .snippet(folder.snippets[index - 1].id)
            }
            if folder.snippets.indices.contains(index + 1) {
                return .snippet(folder.snippets[index + 1].id)
            }
            return .folder(folder.id)
        }
        return nil
    }
}

extension SnippetEditorWindow: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === activeSnippetTitleField, let id = selectedSnippetId {
            SnippetManager.shared.updateSnippetTitle(id: id, title: field.stringValue)
            refreshCurrentSidebarRow()
        } else if field === activeFolderTitleField, let id = selectedFolderId {
            SnippetManager.shared.updateFolderTitle(id: id, title: field.stringValue)
            refreshCurrentSidebarRow()
        }
    }
}

extension SnippetEditorWindow: NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard let id = selectedSnippetId else { return }
        SnippetManager.shared.updateSnippetContent(id: id, content: textStorage.string)
    }
}

extension SnippetEditorWindow {
    @objc func addSnippetAction() {
        guard let folderId = destinationFolderIdForNewSnippet(),
              let newSnippet = SnippetManager.shared.addSnippet(to: folderId, title: "新片段", content: "") else { return }
        
        selectedFolderId = nil
        selectedSnippetId = newSnippet.id
        reloadSidebar(selecting: .snippet(newSnippet.id), expanding: [folderId])
        updateDetailView()
    }
    
    @objc func addFolderAction() {
        SnippetManager.shared.addFolder(title: "新文件夹")
        guard let folderId = SnippetManager.shared.folders.last?.id else { return }
        selectedFolderId = folderId
        selectedSnippetId = nil
        reloadSidebar(selecting: .folder(folderId), expanding: [folderId])
        updateDetailView()
    }
    
    @objc func deleteAction() {
        guard let selection = currentSelection() else { return }
        
        var nextSelection: SidebarSelection?
        switch selection {
        case .folder(let folderId):
            let alert = NSAlert()
            alert.messageText = "确定要删除文件夹吗？"
            alert.informativeText = "文件夹内的片段也会被删除，此操作不可撤销。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            
            SnippetManager.shared.deleteFolder(id: folderId)
        case .snippet(let snippetId):
            nextSelection = Self.selectionAfterDeletingSnippet(snippetId)
            SnippetManager.shared.deleteSnippet(id: snippetId)
        }
        
        syncSelection(nextSelection)
        reloadSidebar(selecting: nextSelection, preserveSelectionWhenNil: nextSelection != nil)
        updateDetailView()
    }
    
    @objc func importAction() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.allowedFileTypes = ["xml", "clipy"]
        
        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            do {
                let xmlString = try String(contentsOf: url, encoding: .utf8)
                SnippetManager.shared.importFromXML(xmlString)
                DispatchQueue.main.async {
                    self?.selectedFolderId = nil
                    self?.selectedSnippetId = nil
                    self?.reloadSidebar(selecting: nil, preserveSelectionWhenNil: false)
                    self?.updateDetailView()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "导入失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
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

extension SnippetEditorWindow: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
    
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMinimumPosition }
        let minSidebar: CGFloat = 140
        return max(proposedMinimumPosition, minSidebar)
    }
    
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMaximumPosition }
        let totalWidth = splitView.bounds.width
        let minDetailWidth: CGFloat = 280
        let maxDividerX = totalWidth - minDetailWidth
        return min(proposedMaximumPosition, maxDividerX)
    }
}

extension SnippetEditorWindow: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else {
            return sidebarNodes.count
        }
        return node.children.count
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else {
            return sidebarNodes[index]
        }
        return node.children[index]
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.folderId != nil
    }
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        
        let identifier = NSUserInterfaceItemIdentifier("SnippetCell")
        var view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
        if view == nil {
            view = NSTableCellView(frame: NSRect(x: 0, y: 0, width: max(outlineView.bounds.width, 220), height: outlineView.rowHeight))
            view?.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.isBordered = false
            textField.drawsBackground = false
            textField.textColor = .labelColor
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            view?.textField = textField
            view?.addSubview(textField)
            if let view {
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
            }
        }
        
        switch node.kind {
        case .folder(let id):
            view?.textField?.stringValue = "📁 " + (Self.latestFolder(matching: id)?.title ?? "文件夹")
        case .snippet(let id, _):
            view?.textField?.stringValue = "📄 " + (Self.latestSnippet(matching: id)?.title ?? "片段")
        }
        
        return view
    }
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloadingSidebar else { return }
        let selection = selectedNodeSelection()
        syncSelection(selection)
        updateDetailView()
    }
    
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode else { return nil }
        let p = NSPasteboardItem()
        switch node.kind {
        case .folder(let id):
            p.setString(id.uuidString, forType: .string)
        case .snippet(let id, _):
            p.setString(id.uuidString, forType: .string)
        }
        return p
    }
    
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let idStr = info.draggingPasteboard.string(forType: .string),
              let uuid = UUID(uuidString: idStr) else { return [] }
        
        if SnippetManager.shared.folders.contains(where: { $0.id == uuid }) {
            return item == nil ? .move : []
        }
        
        guard let (folderId, _) = Self.folderAndSnippetIndex(forSnippetId: uuid),
              let target = item as? SidebarNode,
              target.folderId == folderId else { return [] }
        return .move
    }
    
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item proposedItem: Any?, childIndex index: Int) -> Bool {
        guard let idStr = info.draggingPasteboard.string(forType: .string),
              let uuid = UUID(uuidString: idStr) else { return false }
        let expandedIds = currentExpandedFolderIds()
        let selection = currentSelection()
        
        if let fromIndex = SnippetManager.shared.folders.firstIndex(where: { $0.id == uuid }) {
            guard proposedItem == nil else { return false }
            var dropIdx = index
            if dropIdx == NSOutlineViewDropOnItemIndex {
                dropIdx = SnippetManager.shared.folders.count
            }
            SnippetManager.shared.reorderFolder(from: fromIndex, toDropIndex: dropIdx)
            reloadSidebar(selecting: selection, expanding: expandedIds)
            return true
        }
        
        guard let (folderId, fromIdx) = Self.folderAndSnippetIndex(forSnippetId: uuid),
              let target = proposedItem as? SidebarNode,
              target.folderId == folderId else { return false }
        
        let count = Self.latestFolder(matching: folderId)?.snippets.count ?? 0
        var dropIdx = index
        if dropIdx == NSOutlineViewDropOnItemIndex {
            dropIdx = count
        }
        SnippetManager.shared.reorderSnippet(inFolderId: folderId, from: fromIdx, toDropIndex: dropIdx)
        reloadSidebar(selecting: selection, expanding: expandedIds.union([folderId]))
        return true
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
