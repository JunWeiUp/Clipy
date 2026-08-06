import SwiftUI

struct SnippetEditorSidebarRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: SnippetEditorViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true

        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.title = L10n.t(.nameColumn)
        column.width = 250
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.headerView = nil
        outlineView.rowHeight = AppRowHeight.compact
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        outlineView.registerForDraggedTypes([.string])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView
        context.coordinator.rebuildNodes()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.viewModel = viewModel
        if context.coordinator.lastRevision != viewModel.sidebarRevision {
            context.coordinator.lastRevision = viewModel.sidebarRevision
            context.coordinator.reloadPreservingState()
        }
        context.coordinator.restoreSelectionFromViewModel()
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var viewModel: SnippetEditorViewModel
        weak var outlineView: NSOutlineView?
        var lastRevision = -1

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

        private var sidebarNodes: [SidebarNode] = []
        private var folderNodesById: [UUID: SidebarNode] = [:]
        private var snippetNodesById: [UUID: SidebarNode] = [:]
        private var isReloading = false

        init(viewModel: SnippetEditorViewModel) {
            self.viewModel = viewModel
        }

        func rebuildNodes() {
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

        func reloadPreservingState() {
            guard let outlineView else { return }
            let expanded = currentExpandedFolderIds()
            let visibleOrigin = outlineView.enclosingScrollView?.contentView.bounds.origin
            rebuildNodes()
            isReloading = true
            outlineView.reloadData()
            restoreExpandedFolders(expanded)
            restoreSelectionFromViewModel()
            if let visibleOrigin, let scrollView = outlineView.enclosingScrollView {
                scrollView.contentView.scroll(to: visibleOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            isReloading = false
        }

        func restoreSelectionFromViewModel() {
            guard let outlineView else { return }
            let node: SidebarNode?
            if let snippetId = viewModel.selectedSnippetId {
                node = snippetNodesById[snippetId]
            } else if let folderId = viewModel.selectedFolderId {
                node = folderNodesById[folderId]
            } else {
                outlineView.deselectAll(nil)
                return
            }
            guard let node else {
                outlineView.deselectAll(nil)
                return
            }
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        }

        private func currentExpandedFolderIds() -> Set<UUID> {
            guard let outlineView else { return [] }
            var ids = Set<UUID>()
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? SidebarNode,
                      let folderId = node.folderId,
                      outlineView.isItemExpanded(node) else { continue }
                ids.insert(folderId)
            }
            return ids
        }

        private func restoreExpandedFolders(_ ids: Set<UUID>) {
            guard let outlineView else { return }
            for id in ids {
                guard let node = folderNodesById[id] else { continue }
                outlineView.expandItem(node, expandChildren: false)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SidebarNode else { return sidebarNodes.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SidebarNode else { return sidebarNodes[index] }
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
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                let textField = NSTextField(labelWithString: "")
                textField.isBordered = false
                textField.drawsBackground = false
                textField.textColor = .labelColor
                textField.lineBreakMode = .byTruncatingTail
                textField.translatesAutoresizingMaskIntoConstraints = false
                view?.imageView = imageView
                view?.textField = textField
                view?.addSubview(imageView)
                view?.addSubview(textField)
                if let view {
                    NSLayoutConstraint.activate([
                        imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                        imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                        imageView.widthAnchor.constraint(equalToConstant: 16),
                        imageView.heightAnchor.constraint(equalToConstant: 16),
                        textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                        textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                        textField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    ])
                }
            }

            switch node.kind {
            case .folder(let id):
                let title = SnippetEditorViewModel.latestFolder(matching: id)?.title ?? L10n.t(.folderFallback)
                view?.textField?.stringValue = title
                view?.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            case .snippet(let id, _):
                let title = SnippetEditorViewModel.latestSnippet(matching: id)?.title ?? L10n.t(.snippetFallback)
                view?.textField?.stringValue = title
                view?.imageView?.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            }

            return view
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isReloading, let outlineView else { return }
            let row = outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode else { return }
            switch node.kind {
            case .folder(let id):
                viewModel.selectFolder(id)
            case .snippet(let id, _):
                viewModel.selectSnippet(id)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarNode else { return nil }
            let pasteboardItem = NSPasteboardItem()
            switch node.kind {
            case .folder(let id), .snippet(let id, _):
                pasteboardItem.setString(id.uuidString, forType: .string)
            }
            return pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let idStr = info.draggingPasteboard.string(forType: .string),
                  let uuid = UUID(uuidString: idStr) else { return [] }

            if SnippetManager.shared.folders.contains(where: { $0.id == uuid }) {
                return item == nil ? .move : []
            }

            guard let (folderId, _) = folderAndSnippetIndex(forSnippetId: uuid),
                  let target = item as? SidebarNode,
                  target.folderId == folderId else { return [] }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item proposedItem: Any?, childIndex index: Int) -> Bool {
            guard let idStr = info.draggingPasteboard.string(forType: .string),
                  let uuid = UUID(uuidString: idStr) else { return false }
            let expandedIds = currentExpandedFolderIds()

            if let fromIndex = SnippetManager.shared.folders.firstIndex(where: { $0.id == uuid }) {
                guard proposedItem == nil else { return false }
                var dropIdx = index
                if dropIdx == NSOutlineViewDropOnItemIndex {
                    dropIdx = SnippetManager.shared.folders.count
                }
                SnippetManager.shared.reorderFolder(from: fromIndex, toDropIndex: dropIdx)
                viewModel.reloadSidebar()
                restoreExpandedFolders(expandedIds)
                return true
            }

            guard let (folderId, fromIdx) = folderAndSnippetIndex(forSnippetId: uuid),
                  let target = proposedItem as? SidebarNode,
                  target.folderId == folderId else { return false }

            let count = SnippetEditorViewModel.latestFolder(matching: folderId)?.snippets.count ?? 0
            var dropIdx = index
            if dropIdx == NSOutlineViewDropOnItemIndex {
                dropIdx = count
            }
            SnippetManager.shared.reorderSnippet(inFolderId: folderId, from: fromIdx, toDropIndex: dropIdx)
            viewModel.reloadSidebar()
            restoreExpandedFolders(expandedIds.union([folderId]))
            return true
        }

        private func folderAndSnippetIndex(forSnippetId id: UUID) -> (UUID, Int)? {
            for folder in SnippetManager.shared.folders {
                if let idx = folder.snippets.firstIndex(where: { $0.id == id }) {
                    return (folder.id, idx)
                }
            }
            return nil
        }
    }
}
