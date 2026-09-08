import AppKit
import Foundation
import UniformTypeIdentifiers

final class SnippetEditorViewModel: ObservableObject {
    enum SidebarSelection: Equatable {
        case folder(UUID)
        case snippet(UUID)
    }

    @Published var selectedFolderId: UUID?
    @Published var selectedSnippetId: UUID?
    @Published var sidebarRevision = 0
    @Published var searchQuery = ""
    @Published var focusNewTitleID: UUID?
    @Published var folderSettingsRequest = 0

    private var sidebarRefreshWorkItem: DispatchWorkItem?
    private var selectSnippetObserver: NSObjectProtocol?

    init() {
        selectSnippetObserver = NotificationCenter.default.addObserver(
            forName: .snippetEditorSelectSnippet,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snippetID = notification.object as? UUID else { return }
            self?.searchQuery = ""
            self?.selectSnippet(snippetID)
            self?.reloadSidebar()
        }
    }

    deinit {
        if let selectSnippetObserver {
            NotificationCenter.default.removeObserver(selectSnippetObserver)
        }
    }

    func prepareForClose() {
        sidebarRefreshWorkItem?.cancel()
        sidebarRefreshWorkItem = nil
        selectedFolderId = nil
        selectedSnippetId = nil
        searchQuery = ""
        focusNewTitleID = nil
    }

    var currentSelection: SidebarSelection? {
        if let snippetId = selectedSnippetId, Self.latestSnippet(matching: snippetId) != nil {
            return .snippet(snippetId)
        }
        if let folderId = selectedFolderId, Self.latestFolder(matching: folderId) != nil {
            return .folder(folderId)
        }
        return nil
    }

    func selectFolder(_ id: UUID?) {
        selectedFolderId = id
        searchQuery = ""
        selectedSnippetId = id.flatMap { Self.latestFolder(matching: $0)?.snippets.first?.id }
    }

    func selectSnippet(_ id: UUID?) {
        selectedSnippetId = id
        if let id { selectedFolderId = Self.folderId(containingSnippetId: id) }
    }

    var selectedFolder: SnippetFolder? {
        selectedFolderId.flatMap(Self.latestFolder)
    }

    var filteredSnippets: [Snippet] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippets = selectedFolder?.snippets ?? []
        guard !query.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedStandardContains(query) || $0.content.localizedStandardContains(query)
        }
    }

    func activate() {
        if currentSelection == nil { selectFolder(SnippetManager.shared.folders.first?.id) }
        reloadSidebar()
    }

    func filterChanged() {
        if !filteredSnippets.contains(where: { $0.id == selectedSnippetId }) {
            selectSnippet(filteredSnippets.first?.id)
        }
    }

    func persistTitle(_ title: String, for snippetId: UUID) {
        guard let snippet = Self.latestSnippet(matching: snippetId), snippet.title != title else { return }
        SnippetManager.shared.updateSnippetTitle(id: snippetId, title: title)
        scheduleSidebarRefresh()
    }

    func renameFolder(_ id: UUID, title: String) {
        guard let folder = Self.latestFolder(matching: id), folder.title != title else { return }
        SnippetManager.shared.updateFolderTitle(id: id, title: title)
        reloadSidebar()
    }

    func setFolderShortcut(_ id: UUID, shortcut: ShortcutCombo?) {
        SnippetManager.shared.updateFolderShortcut(id: id, shortcut: shortcut)
        reloadSidebar()
    }

    func deleteFolder(_ id: UUID) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.confirmDeleteFolder)
        alert.informativeText = L10n.t(.deleteFolderWarning)
        alert.addButton(withTitle: L10n.t(.delete))
        alert.addButton(withTitle: L10n.t(.cancel))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SnippetManager.shared.deleteFolder(id: id)
        selectFolder(SnippetManager.shared.folders.first?.id)
        reloadSidebar()
    }

    func reloadSidebar() {
        sidebarRevision += 1
    }

    /// Explicit-id variant for the debounced body editor, which must still save
    /// after a selection change or window close has cleared `selectedSnippetId`.
    func persistContent(_ content: String, for snippetId: UUID) {
        guard let snippet = Self.latestSnippet(matching: snippetId), snippet.content != content else { return }
        SnippetManager.shared.updateSnippetContent(id: snippetId, content: content)
        scheduleSidebarRefresh()
    }

    private func scheduleSidebarRefresh() {
        sidebarRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadSidebar()
        }
        sidebarRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func addSnippet() {
        guard let folderId = destinationFolderIdForNewSnippet(),
              let newSnippet = SnippetManager.shared.addSnippet(to: folderId, title: L10n.t(.newSnippet), content: "") else { return }
        searchQuery = ""
        focusNewTitleID = newSnippet.id
        selectSnippet(newSnippet.id)
        reloadSidebar()
    }

    func addFolder() {
        SnippetManager.shared.addFolder(title: L10n.t(.newFolder))
        guard let folderId = SnippetManager.shared.folders.last?.id else { return }
        selectFolder(folderId)
        reloadSidebar()
        folderSettingsRequest += 1
    }

    func deleteSelection() {
        guard let selection = currentSelection else { return }
        switch selection {
        case .folder(let folderId):
            let alert = NSAlert()
            alert.messageText = L10n.t(.confirmDeleteFolder)
            alert.informativeText = L10n.t(.deleteFolderWarning)
            alert.addButton(withTitle: L10n.t(.delete))
            alert.addButton(withTitle: L10n.t(.cancel))
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            SnippetManager.shared.deleteFolder(id: folderId)
            selectFolder(SnippetManager.shared.folders.first?.id)
        case .snippet(let snippetId):
            let next = Self.selectionAfterDeletingSnippet(snippetId)
            SnippetManager.shared.deleteSnippet(id: snippetId)
            switch next {
            case .folder(let id): selectFolder(id)
            case .snippet(let id): selectSnippet(id)
            case nil: selectFolder(nil)
            }
        }
        reloadSidebar()
    }

    /// `.clipy` has no registered UTI, so it is declared here as an XML subtype.
    private static let snippetContentTypes: [UTType] = {
        var types: [UTType] = [.xml]
        if let clipy = UTType(filenameExtension: "clipy", conformingTo: .xml) {
            types.insert(clipy, at: 0)
        }
        return types
    }()

    func importSnippets() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.allowedContentTypes = Self.snippetContentTypes
        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            do {
                let xmlString = try String(contentsOf: url, encoding: .utf8)
                SnippetManager.shared.importFromXML(xmlString)
                DispatchQueue.main.async {
                    self?.selectFolder(SnippetManager.shared.folders.first?.id)
                    self?.reloadSidebar()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.t(.importFailed)
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func exportSnippets() {
        let savePanel = NSSavePanel()
        savePanel.title = L10n.t(.exportSnippets)
        savePanel.nameFieldStringValue = "ClipySnippets.clipy"
        savePanel.allowedContentTypes = Self.snippetContentTypes
        savePanel.canCreateDirectories = true
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            let xml = SnippetManager.shared.exportToXMLString()
            do {
                try xml.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.t(.exportFailed)
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func destinationFolderIdForNewSnippet() -> UUID? {
        if let selection = currentSelection {
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
        SnippetManager.shared.addFolder(title: L10n.t(.newFolder))
        return SnippetManager.shared.folders.last?.id
    }

    static func latestFolder(matching id: UUID) -> SnippetFolder? {
        SnippetManager.shared.folders.first { $0.id == id }
    }

    static func latestSnippet(matching id: UUID) -> Snippet? {
        for folder in SnippetManager.shared.folders {
            if let snippet = folder.snippets.first(where: { $0.id == id }) {
                return snippet
            }
        }
        return nil
    }

    static func folderId(containingSnippetId id: UUID) -> UUID? {
        for folder in SnippetManager.shared.folders {
            if folder.snippets.contains(where: { $0.id == id }) {
                return folder.id
            }
        }
        return nil
    }

    static func selectionAfterDeletingSnippet(_ id: UUID) -> SidebarSelection? {
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
