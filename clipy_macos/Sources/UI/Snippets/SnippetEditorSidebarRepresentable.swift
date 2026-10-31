import SwiftUI

/// Both navigation columns use native selection, keyboard navigation and drag reordering.
struct SnippetEditorSidebarRepresentable: NSViewRepresentable {
    enum Pane { case folders, snippets }
    @ObservedObject var viewModel: SnippetEditorViewModel
    var pane: Pane

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel, pane: pane) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("Name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = .init(width: 0, height: 2)
        table.rowHeight = pane == .folders ? 34 : 60
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes([Coordinator.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.refresh()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.refresh()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.clipy.snippet-editor-row")
        var viewModel: SnippetEditorViewModel
        let pane: Pane
        weak var table: NSTableView?
        private var ids: [UUID] = []
        private var revision = -1
        private var changingSelection = false

        init(viewModel: SnippetEditorViewModel, pane: Pane) {
            self.viewModel = viewModel
            self.pane = pane
        }

        func refresh() {
            guard let table else { return }
            let updated = pane == .folders ? SnippetManager.shared.folders.map(\.id) : viewModel.filteredSnippets.map(\.id)
            changingSelection = true
            if revision != viewModel.sidebarRevision || updated != ids {
                let origin = table.enclosingScrollView?.contentView.bounds.origin
                ids = updated
                revision = viewModel.sidebarRevision
                table.reloadData()
                if let origin { table.enclosingScrollView?.contentView.scroll(to: origin) }
            }
            let selection = pane == .folders ? viewModel.selectedFolderId : viewModel.selectedSnippetId
            let row = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
            if table.selectedRow != row {
                table.selectRowIndexes(row >= 0 ? IndexSet(integer: row) : [], byExtendingSelection: false)
                if row >= 0 { table.scrollRowToVisible(row) }
            }
            changingSelection = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard ids.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier(pane == .folders ? "Folder" : "Snippet")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SnippetNavigationCell)
                ?? SnippetNavigationCell(isFolder: pane == .folders)
            cell.identifier = identifier
            if pane == .folders, let folder = SnippetEditorViewModel.latestFolder(matching: ids[row]) {
                cell.configure(title: folder.title, subtitle: nil, count: folder.snippets.count)
            } else if let snippet = SnippetEditorViewModel.latestSnippet(matching: ids[row]) {
                let excerpt = snippet.content.prefix(240).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                cell.configure(title: snippet.title, subtitle: excerpt, count: nil)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            SnippetNavigationRowView(isFolder: pane == .folders)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !changingSelection, let table, ids.indices.contains(table.selectedRow) else { return }
            if pane == .folders { viewModel.selectFolder(ids[table.selectedRow]) }
            else { viewModel.selectSnippet(ids[table.selectedRow]) }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard ids.indices.contains(row), pane == .folders || viewModel.searchQuery.isEmpty else { return nil }
            let item = NSPasteboardItem()
            item.setString(ids[row].uuidString, forType: Self.dragType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let source = info.draggingSource as? NSTableView, source === tableView,
                  pane == .folders || viewModel.searchQuery.isEmpty else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let source = info.draggingSource as? NSTableView, source === tableView,
                  let string = info.draggingPasteboard.string(forType: Self.dragType),
                  let id = UUID(uuidString: string), let from = ids.firstIndex(of: id),
                  pane == .folders || viewModel.searchQuery.isEmpty else { return false }
            if pane == .folders { SnippetManager.shared.reorderFolder(from: from, toDropIndex: row) }
            else if let folder = viewModel.selectedFolderId {
                SnippetManager.shared.reorderSnippet(inFolderId: folder, from: from, toDropIndex: row)
            } else { return false }
            viewModel.reloadSidebar()
            return true
        }
    }
}

private final class SnippetNavigationCell: NSTableCellView {
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let isFolder: Bool

    init(isFolder: Bool) {
        self.isFolder = isFolder
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: isFolder ? .regular : .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        textField = title
        if isFolder {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            icon.contentTintColor = SnippetNavigationPalette.text2
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            countLabel.textColor = SnippetNavigationPalette.text3
            countLabel.translatesAutoresizingMaskIntoConstraints = false
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            addSubview(countLabel)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),
                countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = SnippetNavigationPalette.text3
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subtitleLabel)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
                subtitleLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                subtitleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String?, count: Int?) {
        textField?.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        countLabel.stringValue = count.map(String.init) ?? ""
        setAccessibilityLabel([title, subtitle, count.map { L10n.format(.snippetFolderCount, $0) }].compactMap { $0 }.joined(separator: ", "))
        toolTip = title
    }

    /// Folder rows keep normal text on a soft fill with an accent folder icon;
    /// snippet rows invert to white on the accent fill (design `.fo.on` / `.sn.on`).
    func applySelection(_ selected: Bool) {
        if isFolder {
            textField?.textColor = .labelColor
            textField?.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
            imageView?.contentTintColor = selected ? .controlAccentColor : SnippetNavigationPalette.text2
            countLabel.textColor = SnippetNavigationPalette.text3
        } else {
            textField?.textColor = selected ? .white : .labelColor
            subtitleLabel.textColor = selected ? NSColor.white.withAlphaComponent(0.82) : SnippetNavigationPalette.text3
        }
    }
}

private enum SnippetNavigationPalette {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    static let text2 = dynamic(light: NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 0.66),
                               dark: NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 245 / 255, alpha: 0.66))
    static let text3 = dynamic(light: NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 0.42),
                               dark: NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 245 / 255, alpha: 0.40))
    static let fill2 = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.10))
}

/// Draws the design's rounded selection regardless of key-window state so the
/// active snippet stays accent-filled while editing its body.
private final class SnippetNavigationRowView: NSTableRowView {
    private let isFolder: Bool

    init(isFolder: Bool) {
        self.isFolder = isFolder
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isSelected: Bool {
        didSet { updateCells() }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && !isFolder ? .emphasized : .normal
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SnippetNavigationCell)?.applySelection(isSelected)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: isFolder ? 8 : 10, yRadius: isFolder ? 8 : 10)
        (isFolder ? SnippetNavigationPalette.fill2 : NSColor.controlAccentColor).setFill()
        path.fill()
    }

    private func updateCells() {
        for case let cell as SnippetNavigationCell in subviews { cell.applySelection(isSelected) }
        needsDisplay = true
    }
}
