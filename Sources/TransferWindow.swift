import AppKit
import Foundation

class TransferWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?
    private var emptyLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var isUpdatingContextMenuSelection = false
    private var keyMonitor: Any?

    private let transferManager = TransferManager.shared

    override init() {
        super.init()
    }

    func showWindow() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        createWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        window?.close()
    }

    // MARK: - Window Creation

    private func createWindow() {
        let windowRect = NSRect(x: 0, y: 0, width: 620, height: 480)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let win = NSWindow(contentRect: windowRect, styleMask: styleMask, backing: .buffered, defer: false)

        win.title = L10n.t(.transferStation)
        win.minSize = NSSize(width: 480, height: 320)
        win.isReleasedWhenClosed = false
        win.center()

        let contentView = NSView(frame: win.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Toolbar area
        let toolbarHeight: CGFloat = 40
        let toolbarRect = NSRect(x: 0, y: windowRect.height - toolbarHeight, width: windowRect.width, height: toolbarHeight)
        let toolbar = NSView(frame: toolbarRect)
        toolbar.autoresizingMask = [.width, .minYMargin]

        let addTextBtn = NSButton(title: L10n.t(.addText), target: self, action: #selector(addTextClicked))
        addTextBtn.bezelStyle = .rounded
        addTextBtn.frame = NSRect(x: 8, y: 6, width: 80, height: 28)
        toolbar.addSubview(addTextBtn)

        let addFileBtn = NSButton(title: L10n.t(.addFile), target: self, action: #selector(addFileClicked))
        addFileBtn.bezelStyle = .rounded
        addFileBtn.frame = NSRect(x: 96, y: 6, width: 80, height: 28)
        toolbar.addSubview(addFileBtn)

        let addFolderBtn = NSButton(title: L10n.t(.addFolderTransfer), target: self, action: #selector(addFolderClicked))
        addFolderBtn.bezelStyle = .rounded
        addFolderBtn.frame = NSRect(x: 184, y: 6, width: 90, height: 28)
        toolbar.addSubview(addFolderBtn)

        let clearBtn = NSButton(title: L10n.t(.clearAll), target: self, action: #selector(clearAllClicked))
        clearBtn.bezelStyle = .rounded
        clearBtn.frame = NSRect(x: windowRect.width - 88, y: 6, width: 80, height: 28)
        clearBtn.autoresizingMask = [.minXMargin]
        toolbar.addSubview(clearBtn)

        contentView.addSubview(toolbar)

        // Table view
        let tableRect = NSRect(x: 0, y: 24, width: windowRect.width, height: windowRect.height - toolbarHeight - 24)
        let scroll = NSScrollView(frame: tableRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false

        let table = TransferTableView()
        table.dataSource = self
        table.delegate = self
        table.contextMenuProvider = { [weak self, weak table] row in
            guard let self = self, let table = table else { return nil }
            self.isUpdatingContextMenuSelection = true
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            self.isUpdatingContextMenuSelection = false
            return self.contextMenu(for: table, row: row)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 36
        table.headerView = nil

        let iconColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        iconColumn.width = 36
        iconColumn.minWidth = 36
        iconColumn.maxWidth = 36
        table.addTableColumn(iconColumn)

        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.width = 260
        titleColumn.minWidth = 120
        titleColumn.title = L10n.t(.title)
        table.addTableColumn(titleColumn)

        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.width = 60
        typeColumn.minWidth = 50
        typeColumn.title = L10n.t(.type)
        table.addTableColumn(typeColumn)

        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.width = 80
        sourceColumn.minWidth = 60
        sourceColumn.title = L10n.t(.source)
        table.addTableColumn(sourceColumn)

        let permColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("permanent"))
        permColumn.width = 60
        permColumn.minWidth = 50
        permColumn.title = ""
        table.addTableColumn(permColumn)

        scroll.documentView = table
        contentView.addSubview(scroll)
        self.scrollView = scroll
        self.tableView = table

        // Register for drag and drop
        table.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL, .string, .tiff, .png, .rtf])
        scroll.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL, .string, .tiff, .png, .rtf])

        // Status bar
        let statusRect = NSRect(x: 8, y: 4, width: windowRect.width - 16, height: 18)
        let status = NSTextField(labelWithString: "")
        status.frame = statusRect
        status.autoresizingMask = [.width, .maxYMargin]
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        contentView.addSubview(status)
        self.statusLabel = status

        // Empty state label
        let empty = NSTextField(labelWithString: L10n.t(.dragOrAddToTransfer))
        empty.alignment = .center
        empty.font = NSFont.systemFont(ofSize: 16)
        empty.textColor = .tertiaryLabelColor
        empty.frame = NSRect(x: 0, y: 0, width: windowRect.width, height: 40)
        empty.autoresizingMask = [.width]
        empty.isHidden = true
        contentView.addSubview(empty)
        self.emptyLabel = empty

        win.contentView = contentView
        self.window = win

        // Cmd+W to close window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
                self?.closeWindow()
                return nil
            }
            return event
        }

        // Setup drop zone on the window itself
        win.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL, .string, .tiff, .png, .rtf])

        // Observers
        transferManager.onItemsChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.reloadData()
            }
        }

        reloadData()

        // Make the window a dragging destination
        let dragView = WindowDragView(frame: contentView.bounds)
        dragView.autoresizingMask = [.width, .height]
        dragView.onDrop = { [weak self] sender in
            return self?.handleDrop(sender) ?? false
        }
        contentView.addSubview(dragView, positioned: .below, relativeTo: nil)
    }

    // MARK: - Table View

    func numberOfRows(in tableView: NSTableView) -> Int {
        return transferManager.items.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < transferManager.items.count else { return nil }
        return nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < transferManager.items.count, let column = tableColumn else { return nil }
        let item = transferManager.items[row]
        let identifier = column.identifier.rawValue

        let cellView = NSTableCellView()
        let textField = NSTextField()
        textField.isBordered = false
        textField.isEditable = false
        textField.drawsBackground = false
        textField.lineBreakMode = .byTruncatingTail
        cellView.addSubview(textField)

        switch identifier {
        case "icon":
            let imageView = NSImageView()
            imageView.frame = NSRect(x: 6, y: 6, width: 24, height: 24)
            imageView.image = item.content.icon
            imageView.image?.size = NSSize(width: 18, height: 18)
            cellView.addSubview(imageView)
            return cellView

        case "title":
            textField.frame = NSRect(x: 4, y: 6, width: column.width - 8, height: 24)
            textField.stringValue = item.title
            textField.font = NSFont.systemFont(ofSize: 13)
            cellView.textField = textField
            return cellView

        case "type":
            textField.frame = NSRect(x: 4, y: 6, width: column.width - 8, height: 24)
            textField.stringValue = item.content.typeLabel
            textField.font = NSFont.systemFont(ofSize: 11)
            textField.textColor = .secondaryLabelColor
            cellView.textField = textField
            return cellView

        case "source":
            textField.frame = NSRect(x: 4, y: 6, width: column.width - 8, height: 24)
            textField.stringValue = item.sourceDevice
            textField.font = NSFont.systemFont(ofSize: 11)
            textField.textColor = .secondaryLabelColor
            cellView.textField = textField
            return cellView

        case "permanent":
            textField.frame = NSRect(x: 4, y: 6, width: column.width - 8, height: 24)
            textField.stringValue = item.isPermanent ? "🔒" : "⏱"
            textField.font = NSFont.systemFont(ofSize: 14)
            textField.alignment = .center
            cellView.textField = textField
            return cellView

        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingContextMenuSelection else { return }
        guard let tableView = notification.object as? NSTableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < transferManager.items.count else { return }
        let item = transferManager.items[row]

        switch item.content {
        case .file(let path, _, _):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .folder(let path, _, _):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .text(let str):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(str, forType: .string)
        default:
            break
        }

        tableView.deselectRow(row)
    }

    // MARK: - Context Menu

    private func contextMenu(for _: NSTableView, row: Int) -> NSMenu? {
        guard row < transferManager.items.count else { return nil }
        let item = transferManager.items[row]

        let menu = NSMenu()

        let copyItem = NSMenuItem(title: L10n.t(.copyContent), action: #selector(copyItemClicked(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = item
        menu.addItem(copyItem)

        if case .file = item.content {
            let openItem = NSMenuItem(title: L10n.t(.openFile), action: #selector(openFileClicked(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = item
            menu.addItem(openItem)

            let revealItem = NSMenuItem(title: L10n.t(.showInFinder), action: #selector(revealInFinderClicked(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = item
            menu.addItem(revealItem)

            let saveAsItem = NSMenuItem(title: L10n.t(.saveAs), action: #selector(saveAsClicked(_:)), keyEquivalent: "")
            saveAsItem.target = self
            saveAsItem.representedObject = item
            menu.addItem(saveAsItem)
        }

        if case .folder = item.content {
            let openItem = NSMenuItem(title: L10n.t(.openFolder), action: #selector(openFolderClicked(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = item
            menu.addItem(openItem)

            let revealItem = NSMenuItem(title: L10n.t(.showInFinder), action: #selector(revealInFinderClicked(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = item
            menu.addItem(revealItem)

            let saveAsItem = NSMenuItem(title: L10n.t(.saveAs), action: #selector(saveAsClicked(_:)), keyEquivalent: "")
            saveAsItem.target = self
            saveAsItem.representedObject = item
            menu.addItem(saveAsItem)
        }

        menu.addItem(NSMenuItem.separator())

        let permTitle = item.isPermanent ? L10n.t(.setTemporary) : L10n.t(.setPermanent)
        let permItem = NSMenuItem(title: permTitle, action: #selector(togglePermanentClicked(_:)), keyEquivalent: "")
        permItem.target = self
        permItem.representedObject = item
        menu.addItem(permItem)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: L10n.t(.delete), action: #selector(deleteItemClicked(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = item
        menu.addItem(deleteItem)

        return menu
    }

    // MARK: - Drag & Drop (Table)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < transferManager.items.count else { return nil }
        let item = transferManager.items[row]
        switch item.content {
        case .text(let str):
            let pbItem = NSPasteboardItem()
            pbItem.setString(str, forType: .string)
            return pbItem
        case .file(let path, _, _), .folder(let path, _, _):
            return NSURL(fileURLWithPath: path) as NSPasteboardWriting
        default:
            return nil
        }
    }

    // MARK: - Drop Handling

    func handleDrop(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        transferManager.addFolderItem(from: url)
                    } else {
                        transferManager.addFileItem(from: url)
                    }
                }
            }
            return true
        }

        if let str = pb.string(forType: .string), !str.isEmpty {
            transferManager.addItem(.text(str), title: nil)
            return true
        }

        if let tiffData = pb.data(forType: .tiff), let image = NSImage(data: tiffData) {
            transferManager.addImageItem(image)
            return true
        }

        if let pngData = pb.data(forType: .png) {
            transferManager.addItem(.image(pngData), title: "Image \(DateFormatter.transferShort.string(from: Date()))")
            return true
        }

        return false
    }

    // MARK: - Actions

    @objc private func addTextClicked() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.addText)
        alert.informativeText = L10n.t(.enterTextContent)
        alert.addButton(withTitle: L10n.t(.add))
        alert.addButton(withTitle: L10n.t(.cancel))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        alert.accessoryView = scrollView

        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn {
                let text = textView.string
                if !text.isEmpty {
                    self.transferManager.addItem(.text(text), title: nil)
                }
            }
        }
    }

    @objc private func addFileClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = L10n.t(.selectFiles)

        panel.beginSheetModal(for: window!) { response in
            if response == .OK {
                for url in panel.urls {
                    self.transferManager.addFileItem(from: url)
                }
            }
        }
    }

    @objc private func addFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.t(.selectFolder)

        panel.beginSheetModal(for: window!) { response in
            if response == .OK {
                for url in panel.urls {
                    self.transferManager.addFolderItem(from: url)
                }
            }
        }
    }

    @objc private func clearAllClicked() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.clearAllTransfer)
        alert.informativeText = L10n.t(.clearAllTransferConfirm)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t(.clearAll))
        alert.addButton(withTitle: L10n.t(.cancel))

        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn {
                self.transferManager.clearAll()
            }
        }
    }

    @objc private func copyItemClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TransferItem else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.content {
        case .text(let str):
            pb.setString(str, forType: .string)
        case .rtf(let data):
            pb.setData(data, forType: .rtf)
        case .image(let data):
            pb.setData(data, forType: .png)
        case .file(let path, _, _), .folder(let path, _, _):
            pb.writeObjects([NSURL(fileURLWithPath: path)])
        }
    }

    @objc private func revealInFinderClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TransferItem else { return }
        if case .file(let path, _, _) = item.content {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else if case .folder(let path, _, _) = item.content {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    @objc private func openFileClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TransferItem else { return }
        if case .file(let path, _, _) = item.content {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc private func saveAsClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TransferItem else { return }
        let source: (path: String, name: String)
        switch item.content {
        case .file(let path, let fileName, _):
            source = (path, fileName)
        case .folder(let path, let folderName, _):
            source = (path, folderName)
        default:
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window!) { response in
            if response == .OK, let destURL = panel.url {
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: destURL)
                    let alert = NSAlert()
                    alert.messageText = L10n.t(.saveAsSuccess)
                    alert.informativeText = destURL.path
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: L10n.t(.ok))
                    alert.beginSheetModal(for: self.window!, completionHandler: nil)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Error"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L10n.t(.ok))
                    alert.beginSheetModal(for: self.window!, completionHandler: nil)
                }
            }
        }
    }

    @objc private func openFolderClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TransferItem else { return }
        if case .folder(let path, _, _) = item.content {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc private func togglePermanentClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TransferItem else { return }
        transferManager.togglePermanent(id: item.id)
    }

    @objc private func deleteItemClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TransferItem else { return }
        transferManager.removeItem(id: item.id)
    }

    // MARK: - Reload

    private func reloadData() {
        tableView?.reloadData()
        let count = transferManager.items.count
        let permanentCount = transferManager.items.filter { $0.isPermanent }.count
        statusLabel?.stringValue = "\(count) items (\(permanentCount) permanent)"
        emptyLabel?.isHidden = count > 0
    }
}

// MARK: - TransferTableView

private class TransferTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }

        return contextMenuProvider?(row)
    }
}

// MARK: - WindowDragView

class WindowDragView: NSView {
    var onDrop: ((NSDraggingInfo) -> Bool)?

    override func awakeFromNib() {
        super.awakeFromNib()
        registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL, .string, .tiff, .png, .rtf])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return onDrop?(sender) ?? false
    }

    override var acceptsFirstResponder: Bool { return false }
}
