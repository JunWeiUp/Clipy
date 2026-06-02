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
    /// 避免在 `reloadData` 后仍选中同一项时重复 `updateDetailView()`，否则侧栏刷新会拆掉正在编辑的标题/正文视图，导致“存不上”。
    private var activeDetailKey: String?
    private var selectedFolderId: UUID?
    private var selectedSnippetId: UUID?
    private weak var activeFolderTitleField: NSTextField?
    private weak var activeSnippetTitleField: NSTextField?
    /// 在批量 reloadData() + 恢复选中期间置 true，防止 outlineViewSelectionDidChange 误重建右侧面板。
    private var isSuppressingSelectionChange = false
    
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
        splitView.delegate = self
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
        sidebarView.registerForDraggedTypes([.string])
        sidebarView.setDraggingSourceOperationMask(.move, forLocal: true)
        sidebarView.setDraggingSourceOperationMask([], forLocal: false)
        
        sidebarScrollView.documentView = sidebarView
        splitView.addArrangedSubview(sidebarScrollView)
        
        // Detail View
        detailView = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 600))
        splitView.addArrangedSubview(detailView)
        
        updateDetailView()
    }
    
    func updateDetailView() {
        detailView.subviews.forEach { $0.removeFromSuperview() }
        
        // `NSOutlineView` 会缓存 struct item；详情区始终按选中 ID 从 SnippetManager 取最新数据。
        if let snippetId = selectedSnippetId, let snippet = Self.latestSnippet(matching: snippetId) {
            showSnippetDetail(snippet)
        } else if let folderId = selectedFolderId, let folder = Self.latestFolder(matching: folderId) {
            showFolderDetail(folder)
        } else {
            let label = NSTextField(labelWithString: "请在左侧选择一个文件夹或片段")
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: (detailView.bounds.width - 200)/2, y: detailView.bounds.height/2, width: 200, height: 20)
            detailView.addSubview(label)
        }
    }
    
    private func showFolderDetail(_ folder: SnippetFolder) {
        activeFolderTitleField = nil
        activeSnippetTitleField = nil
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
        activeFolderTitleField = nil
        activeSnippetTitleField = nil
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
        recorder.onShortcutChanged = { [weak self] newCombo in
            self?.updateSnippetShortcut(snippet.id, newCombo)
        }
        detailView.addSubview(recorder)
    }
    
    private func updateSnippetShortcut(_ snippetId: UUID, _ combo: ShortcutCombo?) {
        SnippetManager.shared.updateSnippetShortcut(id: snippetId, shortcut: combo)
    }
    
    /// 仅刷新当前选中行的 cell 显示（如名称更新），不影响选中状态，不触发 outlineViewSelectionDidChange。
    private func refreshCurrentSidebarCell() {
        let row: Int
        if let sid = selectedSnippetId { row = rowForSnippetId(sid) }
        else if let fid = selectedFolderId { row = rowForFolderId(fid) }
        else { return }
        guard row >= 0 else { return }
        sidebarView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }
    
    /// 结构性变化（增删、重排）时使用，全量 reload 并按 ID 恢复展开/选中/滚动状态。
    private func reloadSidebarPreservingSelection() {
        let fid = selectedFolderId
        let sid = selectedSnippetId
        var expandedFolderIds = currentlyExpandedFolderIds()
        if let sid, let parent = Self.folder(containingSnippetId: sid) {
            expandedFolderIds.insert(parent.id)
        }
        if let fid {
            expandedFolderIds.insert(fid)
        }
        let visibleOrigin = sidebarView.enclosingScrollView?.contentView.bounds.origin
        
        isSuppressingSelectionChange = true
        sidebarView.reloadData()
        restoreSidebarState(expandedFolderIds: expandedFolderIds, folderId: fid, snippetId: sid, visibleOrigin: visibleOrigin)
        isSuppressingSelectionChange = false
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.selectedFolderId == fid && self.selectedSnippetId == sid else { return }
            self.isSuppressingSelectionChange = true
            self.restoreSidebarState(expandedFolderIds: expandedFolderIds, folderId: fid, snippetId: sid, visibleOrigin: visibleOrigin)
            self.isSuppressingSelectionChange = false
        }
    }
    
    private func restoreSidebarState(expandedFolderIds: Set<UUID>, folderId: UUID?, snippetId: UUID?, visibleOrigin: NSPoint?) {
        restoreExpandedFolders(expandedFolderIds)
        
        if let snippetId {
            let row = rowForSnippetId(snippetId)
            if row >= 0 {
                sidebarView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                restoreSidebarScrollPosition(visibleOrigin)
                return
            }
        }
        if let folderId {
            let row = rowForFolderId(folderId)
            if row >= 0 {
                sidebarView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        restoreSidebarScrollPosition(visibleOrigin)
    }
    
    private func currentlyExpandedFolderIds() -> Set<UUID> {
        var ids = Set<UUID>()
        for row in 0..<sidebarView.numberOfRows {
            guard let folder = sidebarView.item(atRow: row) as? SnippetFolder else { continue }
            if sidebarView.isItemExpanded(folder) {
                ids.insert(folder.id)
            }
        }
        return ids
    }
    
    private func restoreExpandedFolders(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            let row = rowForFolderId(id)
            guard row >= 0,
                  let folder = sidebarView.item(atRow: row) as? SnippetFolder else { continue }
            sidebarView.expandItem(folder)
        }
    }
    
    private func restoreSidebarScrollPosition(_ origin: NSPoint?) {
        guard let origin,
              let scrollView = sidebarView.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    
    private func rowForFolderId(_ id: UUID) -> Int {
        for r in 0..<sidebarView.numberOfRows {
            if let f = sidebarView.item(atRow: r) as? SnippetFolder, f.id == id { return r }
        }
        return -1
    }
    
    private func rowForSnippetId(_ id: UUID) -> Int {
        for r in 0..<sidebarView.numberOfRows {
            if let s = sidebarView.item(atRow: r) as? Snippet, s.id == id { return r }
        }
        return -1
    }
    
    private func visibleFolderItem(for id: UUID) -> SnippetFolder? {
        let row = rowForFolderId(id)
        guard row >= 0 else { return nil }
        return sidebarView.item(atRow: row) as? SnippetFolder
    }
    
    private func currentSidebarSelectionIds() -> (folderId: UUID?, snippetId: UUID?) {
        let row = sidebarView.selectedRow
        if row >= 0, let item = sidebarView.item(atRow: row) {
            if let folder = item as? SnippetFolder {
                return (folder.id, nil)
            }
            if let snippet = item as? Snippet {
                return (nil, snippet.id)
            }
        }
        if let snippetId = selectedSnippetId, Self.latestSnippet(matching: snippetId) != nil {
            return (nil, snippetId)
        }
        if let folderId = selectedFolderId, Self.latestFolder(matching: folderId) != nil {
            return (folderId, nil)
        }
        return (nil, nil)
    }
    
    private func destinationFolderIdForNewSnippet() -> UUID? {
        let selection = currentSidebarSelectionIds()
        if let folderId = selection.folderId {
            return folderId
        }
        if let snippetId = selection.snippetId {
            return Self.folder(containingSnippetId: snippetId)?.id
        }
        if let firstFolder = SnippetManager.shared.folders.first {
            return firstFolder.id
        }
        SnippetManager.shared.addFolder(title: "新文件夹")
        return SnippetManager.shared.folders.last?.id
    }
    
    private static func folder(containingSnippetId id: UUID) -> SnippetFolder? {
        for folder in SnippetManager.shared.folders {
            if folder.snippets.contains(where: { $0.id == id }) {
                return folder
            }
        }
        return nil
    }
    
    private static func latestFolder(matching id: UUID) -> SnippetFolder? {
        SnippetManager.shared.folders.first { $0.id == id }
    }
    
    private static func latestSnippet(matching id: UUID) -> Snippet? {
        for folder in SnippetManager.shared.folders {
            if let s = folder.snippets.first(where: { $0.id == id }) {
                return s
            }
        }
        return nil
    }
    
}

extension SnippetEditorWindow: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === activeSnippetTitleField, let id = selectedSnippetId {
            SnippetManager.shared.updateSnippetTitle(id: id, title: field.stringValue)
            refreshCurrentSidebarCell()
        } else if field === activeFolderTitleField, let id = selectedFolderId {
            SnippetManager.shared.updateFolderTitle(id: id, title: field.stringValue)
            refreshCurrentSidebarCell()
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
        guard let folderId = destinationFolderIdForNewSnippet() else { return }
        
        let parentItem = visibleFolderItem(for: folderId)
        var expandedFolderIds = currentlyExpandedFolderIds()
        expandedFolderIds.insert(folderId)
        let visibleOrigin = sidebarView.enclosingScrollView?.contentView.bounds.origin
        
        guard let newSnippet = SnippetManager.shared.addSnippet(to: folderId, title: "新片段", content: "") else { return }
        
        activeDetailKey = "snippet:\(newSnippet.id.uuidString)"
        selectedFolderId = nil
        selectedSnippetId = newSnippet.id
        
        if let parentItem {
            isSuppressingSelectionChange = true
            if !sidebarView.isItemExpanded(parentItem) {
                sidebarView.expandItem(parentItem, expandChildren: false)
            }
            sidebarView.reloadItem(parentItem, reloadChildren: true)
            sidebarView.expandItem(parentItem, expandChildren: false)
            restoreSidebarState(expandedFolderIds: expandedFolderIds, folderId: nil, snippetId: newSnippet.id, visibleOrigin: visibleOrigin)
            isSuppressingSelectionChange = false
            updateDetailView()
            
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedSnippetId == newSnippet.id else { return }
                self.isSuppressingSelectionChange = true
                self.restoreSidebarState(expandedFolderIds: expandedFolderIds, folderId: nil, snippetId: newSnippet.id, visibleOrigin: visibleOrigin)
                self.isSuppressingSelectionChange = false
            }
            return
        }
        
        // 空列表首次创建文件夹后没有可见父行，只在这个兜底场景全量刷新。
        isSuppressingSelectionChange = true
        sidebarView.reloadData()
        restoreSidebarState(expandedFolderIds: expandedFolderIds, folderId: nil, snippetId: newSnippet.id, visibleOrigin: visibleOrigin)
        isSuppressingSelectionChange = false
        updateDetailView()
    }
    
    @objc func addFolderAction() {
        SnippetManager.shared.addFolder(title: "新文件夹")
        reloadSidebarPreservingSelection()
    }
    
    @objc func deleteAction() {
        let selection = currentSidebarSelectionIds()
        guard selection.folderId != nil || selection.snippetId != nil else { return }
        
        let alert = NSAlert()
        alert.messageText = "确定要删除吗？"
        alert.informativeText = "此操作不可撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let folderId = selection.folderId {
                SnippetManager.shared.deleteFolder(id: folderId)
            } else if let snippetId = selection.snippetId {
                SnippetManager.shared.deleteSnippet(id: snippetId)
            }
            currentSelection = nil
            activeDetailKey = nil
            selectedFolderId = nil
            selectedSnippetId = nil
            reloadSidebarPreservingSelection()
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
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let p = NSPasteboardItem()
        if let f = item as? SnippetFolder {
            p.setString(f.id.uuidString, forType: .string)
        } else if let s = item as? Snippet {
            p.setString(s.id.uuidString, forType: .string)
        } else {
            return nil
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
              let target = item as? SnippetFolder,
              target.id == folderId else { return [] }
        return .move
    }
    
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item proposedItem: Any?, childIndex index: Int) -> Bool {
        guard let idStr = info.draggingPasteboard.string(forType: .string),
              let uuid = UUID(uuidString: idStr) else { return false }
        
        if let fromIndex = SnippetManager.shared.folders.firstIndex(where: { $0.id == uuid }) {
            guard proposedItem == nil else { return false }
            var dropIdx = index
            if dropIdx == NSOutlineViewDropOnItemIndex {
                dropIdx = SnippetManager.shared.folders.count
            }
            SnippetManager.shared.reorderFolder(from: fromIndex, toDropIndex: dropIdx)
            reloadSidebarPreservingSelection()
            return true
        }
        
        guard let (folderId, fromIdx) = Self.folderAndSnippetIndex(forSnippetId: uuid),
              let target = proposedItem as? SnippetFolder,
              target.id == folderId else { return false }
        
        let count = SnippetManager.shared.folders.first(where: { $0.id == folderId })?.snippets.count ?? 0
        var dropIdx = index
        if dropIdx == NSOutlineViewDropOnItemIndex {
            dropIdx = count
        }
        SnippetManager.shared.reorderSnippet(inFolderId: folderId, from: fromIdx, toDropIndex: dropIdx)
        reloadSidebarPreservingSelection()
        return true
    }
    
    private static func folderAndSnippetIndex(forSnippetId id: UUID) -> (UUID, Int)? {
        for folder in SnippetManager.shared.folders {
            if let idx = folder.snippets.firstIndex(where: { $0.id == id }) {
                return (folder.id, idx)
            }
        }
        return nil
    }
    
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return SnippetManager.shared.folders.count
        } else if let folder = item as? SnippetFolder {
            return Self.latestFolder(matching: folder.id)?.snippets.count ?? 0
        }
        return 0
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return SnippetManager.shared.folders[index]
        } else if let folder = item as? SnippetFolder,
                  let latestFolder = Self.latestFolder(matching: folder.id),
                  latestFolder.snippets.indices.contains(index) {
            return latestFolder.snippets[index]
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
            let latestFolder = Self.latestFolder(matching: folder.id) ?? folder
            view?.textField?.stringValue = "📁 " + latestFolder.title
        } else if let snippet = item as? Snippet {
            let latestSnippet = Self.latestSnippet(matching: snippet.id) ?? snippet
            view?.textField?.stringValue = "📄 " + latestSnippet.title
        }
        
        return view
    }
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSuppressingSelectionChange else { return }
        let row = sidebarView.selectedRow
        if row < 0 {
            activeDetailKey = nil
            selectedFolderId = nil
            selectedSnippetId = nil
            activeFolderTitleField = nil
            activeSnippetTitleField = nil
            currentSelection = nil
            updateDetailView()
            return
        }
        guard let item = sidebarView.item(atRow: row) else { return }
        let key: String
        if let f = item as? SnippetFolder {
            key = "folder:\(f.id.uuidString)"
            selectedFolderId = f.id
            selectedSnippetId = nil
        } else if let s = item as? Snippet {
            key = "snippet:\(s.id.uuidString)"
            selectedSnippetId = s.id
            selectedFolderId = nil
        } else {
            activeDetailKey = nil
            selectedFolderId = nil
            selectedSnippetId = nil
            currentSelection = nil
            updateDetailView()
            return
        }
        if key == activeDetailKey {
            return
        }
        activeDetailKey = key
        currentSelection = item
        updateDetailView()
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
