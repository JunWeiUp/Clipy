import SwiftUI
import UniformTypeIdentifiers

final class TransferViewModel: ObservableObject {
    @Published var items: [TransferItem] = []
    @Published var selectedIDs = Set<TransferItem.ID>()

    private let manager = TransferManager.shared

    init() {
        items = manager.items
        manager.onItemsChanged = { [weak self] newItems in
            DispatchQueue.main.async {
                self?.items = newItems
            }
        }
    }

    var statusText: String {
        let permanentCount = items.filter(\.isPermanent).count
        return L10n.format(.transferStatusFormat, items.count, permanentCount)
    }

    func handleSelection(_ item: TransferItem) {
        switch item.content {
        case .file(let path, _, _), .folder(let path, _, _):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .text(let str):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(str, forType: .string)
        default:
            break
        }
        selectedIDs.removeAll()
    }

    func addText() {
        AlertPresenter.promptText(
            title: L10n.t(.addText),
            message: L10n.t(.enterTextContent)
        ) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.manager.addItem(.text(text), title: nil)
        }
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = L10n.t(.selectFiles)
        if panel.runModal() == .OK {
            for url in panel.urls {
                manager.addFileItem(from: url)
            }
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.t(.selectFolder)
        if panel.runModal() == .OK {
            for url in panel.urls {
                manager.addFolderItem(from: url)
            }
        }
    }

    func clearAll() {
        AlertPresenter.confirm(
            title: L10n.t(.clearAllTransfer),
            message: L10n.t(.clearAllTransferConfirm),
            confirmTitle: L10n.t(.clearAll)
        ) { [weak self] in
            self?.manager.clearAll()
        }
    }

    func copyItem(_ item: TransferItem) {
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

    func openFile(_ item: TransferItem) {
        if case .file(let path, _, _) = item.content {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    func openFolder(_ item: TransferItem) {
        if case .folder(let path, _, _) = item.content {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    func revealInFinder(_ item: TransferItem) {
        switch item.content {
        case .file(let path, _, _), .folder(let path, _, _):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        default:
            break
        }
    }

    func saveAs(_ item: TransferItem) {
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
        if panel.runModal() == .OK, let destURL = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: destURL)
                AlertPresenter.showInfo(title: L10n.t(.saveAsSuccess), message: destURL.path)
            } catch {
                AlertPresenter.showWarning(title: L10n.t(.error), message: error.localizedDescription)
            }
        }
    }

    func togglePermanent(_ item: TransferItem) {
        manager.togglePermanent(id: item.id)
    }

    func deleteItem(_ item: TransferItem) {
        manager.removeItem(id: item.id)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                        if isDir.boolValue {
                            self.manager.addFolderItem(from: url)
                        } else {
                            self.manager.addFileItem(from: url)
                        }
                        handled = true
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    defer { group.leave() }
                    if let str = object as? String, !str.isEmpty {
                        self.manager.addItem(.text(str), title: nil)
                        handled = true
                    }
                }
            }
        }

        group.notify(queue: .main) {}
        return handled
    }
}

struct TransferView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @StateObject private var viewModel = TransferViewModel()

    var body: some View {
        let _ = languageObserver.revision

        AppListWindowLayout(statusText: viewModel.statusText) {
            AppToolbar(
                leading: [
                    AppToolbarButton(title: L10n.t(.addText), systemImage: "text.badge.plus", action: viewModel.addText),
                    AppToolbarButton(title: L10n.t(.addFile), systemImage: "doc.badge.plus", action: viewModel.addFiles),
                    AppToolbarButton(title: L10n.t(.addFolderTransfer), systemImage: "folder.badge.plus", action: viewModel.addFolder),
                ],
                trailing: [
                    AppToolbarButton(title: L10n.t(.clearAll), systemImage: "trash", action: viewModel.clearAll),
                ]
            )
        } content: {
            ZStack {
                if viewModel.items.isEmpty {
                    EmptyStateView(message: L10n.t(.dragOrAddToTransfer))
                } else {
                    Table(viewModel.items, selection: $viewModel.selectedIDs) {
                        TableColumn("") { item in
                            Image(nsImage: item.content.icon ?? NSImage())
                                .resizable()
                                .frame(width: 18, height: 18)
                        }
                        .width(36)

                        TableColumn(L10n.t(.title)) { item in
                            Text(item.title)
                                .font(AppFont.body)
                                .lineLimit(1)
                        }

                        TableColumn(L10n.t(.type)) { item in
                            Text(item.content.typeLabel)
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }

                        TableColumn(L10n.t(.source)) { item in
                            Text(item.sourceDevice)
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }

                        TableColumn("") { item in
                            Image(systemName: item.isPermanent ? "lock.fill" : "clock")
                                .foregroundStyle(item.isPermanent ? .primary : .secondary)
                        }
                        .width(40)
                    }
                    .contextMenu(forSelectionType: TransferItem.ID.self) { ids in
                        if let id = ids.first, let item = viewModel.items.first(where: { $0.id == id }) {
                            transferContextMenu(for: item)
                        }
                    }
                    .onChange(of: viewModel.selectedIDs) { newValue in
                        guard let id = newValue.first,
                              let item = viewModel.items.first(where: { $0.id == id }) else { return }
                        viewModel.handleSelection(item)
                    }
                }
            }
        }
        .frame(minWidth: AppWindowSize.listMin.width, minHeight: AppWindowSize.listMin.height)
        .onDrop(of: [.fileURL, .plainText, .image], isTargeted: nil) { providers in
            viewModel.handleDrop(providers)
        }
    }

    @ViewBuilder
    private func transferContextMenu(for item: TransferItem) -> some View {
        Button(L10n.t(.copyContent)) { viewModel.copyItem(item) }

        if case .file = item.content {
            Button(L10n.t(.openFile)) { viewModel.openFile(item) }
            Button(L10n.t(.showInFinder)) { viewModel.revealInFinder(item) }
            Button(L10n.t(.saveAs)) { viewModel.saveAs(item) }
        }

        if case .folder = item.content {
            Button(L10n.t(.openFolder)) { viewModel.openFolder(item) }
            Button(L10n.t(.showInFinder)) { viewModel.revealInFinder(item) }
            Button(L10n.t(.saveAs)) { viewModel.saveAs(item) }
        }

        Divider()

        Button(item.isPermanent ? L10n.t(.setTemporary) : L10n.t(.setPermanent)) {
            viewModel.togglePermanent(item)
        }

        Divider()

        Button(L10n.t(.delete), role: .destructive) {
            viewModel.deleteItem(item)
        }
    }
}

extension AlertPresenter {
    static func promptText(title: String, message: String, onSubmit: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t(.add))
        alert.addButton(withTitle: L10n.t(.cancel))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: AppFont.bodySize)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        alert.accessoryView = scrollView

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    onSubmit(textView.string)
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onSubmit(textView.string)
        }
    }
}
