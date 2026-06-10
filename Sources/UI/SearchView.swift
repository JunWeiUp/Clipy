import SwiftUI

extension HistoryEntry: Identifiable {
    var id: String {
        let hash = contentHash ?? ""
        return "\(date.timeIntervalSince1970)-\(hash)"
    }
}

final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [HistoryEntry] = []
    @Published var selectedID: HistoryEntry.ID?
    @Published var statusText = ""

    private var debounceWorkItem: DispatchWorkItem?
    private var historyObserver: NSObjectProtocol?

    func onAppear() {
        performSearch(immediate: true)
        guard historyObserver == nil else { return }
        historyObserver = NotificationCenter.default.addObserver(
            forName: .clipboardHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performSearch(immediate: true)
        }
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    func onQueryChange() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSearch(immediate: false)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func performSearch(immediate: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSelection = selectedID
        results = ClipboardManager.shared.searchHistory(query: trimmed)
        if trimmed.isEmpty {
            statusText = L10n.format(.searchResultCount, results.count)
        } else if results.isEmpty {
            statusText = L10n.t(.noSearchResults)
        } else {
            statusText = L10n.format(.searchResultCount, results.count)
        }
        if let previousSelection,
           results.contains(where: { $0.id == previousSelection }) {
            selectedID = previousSelection
        } else {
            selectedID = results.first?.id
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = results.firstIndex { $0.id == selectedID } ?? 0
        let newIndex = max(0, min(currentIndex + offset, results.count - 1))
        selectedID = results[newIndex].id
    }

    func selectCurrent() {
        guard let selectedID,
              let entry = results.first(where: { $0.id == selectedID }) else { return }
        selectEntry(entry)
    }

    func selectEntry(_ entry: HistoryEntry, pasteFileAsName: Bool = true) {
        let clipboard = ClipboardManager.shared
        clipboard.moveHistoryEntryToFront(entry)

        let shouldAutoPaste: Bool
        if case .files(let urls) = entry.item, pasteFileAsName {
            clipboard.writeFileNamesToPasteboard(urls)
            shouldAutoPaste = true
        } else if case .files = entry.item {
            clipboard.writeToPasteboard(entry.item)
            shouldAutoPaste = false
        } else {
            clipboard.writeToPasteboard(entry.item)
            shouldAutoPaste = {
                if case .text = entry.item { return true }
                return false
            }()
        }

        NSApp.keyWindow?.close()

        guard shouldAutoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard AccessibilityManager.isTrusted else { return }
            self.simulatePaste()
        }
    }

    func revealInFinder(_ entry: HistoryEntry) {
        ClipboardManager.shared.revealInFinder(for: entry)
    }

    func togglePin(_ entry: HistoryEntry) {
        ClipboardManager.shared.togglePin(for: entry)
    }

    func isPinned(_ entry: HistoryEntry) -> Bool {
        ClipboardManager.shared.history.first { matchesSelection($0, entry) }?.isPinned ?? entry.isPinned
    }

    var selectedEntry: HistoryEntry? {
        guard let selectedID else { return nil }
        return results.first { $0.id == selectedID }
    }

    private func matchesSelection(_ lhs: HistoryEntry, _ rhs: HistoryEntry) -> Bool {
        let lhsHash = lhs.contentHash ?? ""
        let rhsHash = rhs.contentHash ?? ""
        if !lhsHash.isEmpty, lhsHash == rhsHash {
            return true
        }
        return lhs.id == rhs.id
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vKeyDown?.flags = .maskCommand
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vKeyUp?.flags = .maskCommand
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)
    }

    private func contentPreview(for entry: HistoryEntry) -> String {
        let title = entry.item.title
        let singleLine = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count > 80 {
            return String(singleLine.prefix(80)) + "..."
        }
        return singleLine
    }
}

struct SearchView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        let _ = languageObserver.revision

        AppListWindowLayout(statusText: viewModel.statusText) {
            AppWindowHeader {
                TextField(L10n.t(.searchHistoryPlaceholder), text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onChange(of: viewModel.query) { _ in
                        viewModel.onQueryChange()
                    }
            }
        } content: {
            HSplitView {
                historyTable
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                HistoryPreviewView(entry: viewModel.selectedEntry)
            }
        }
        .frame(minWidth: AppWindowSize.searchMin.width, minHeight: AppWindowSize.searchMin.height)
        .onAppear {
            viewModel.onAppear()
            searchFocused = true
        }
        .background(SearchKeyHandler(
            onUp: { viewModel.moveSelection(by: -1) },
            onDown: { viewModel.moveSelection(by: 1) },
            onEnter: { viewModel.selectCurrent() },
            onEscape: { NSApp.keyWindow?.close() }
        ))
    }

    private var historyTable: some View {
        Table(viewModel.results, selection: $viewModel.selectedID) {
            TableColumn(L10n.t(.content)) { entry in
                HStack(spacing: 6) {
                    if viewModel.isPinned(entry) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    if entry.item.isFile, let urls = entry.item.fileURLs, let first = urls.first {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    Text(contentPreview(for: entry))
                        .font(AppFont.body)
                        .lineLimit(1)
                }
            }
            TableColumn(L10n.t(.location)) { entry in
                Text(locationPreview(for: entry))
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TableColumn(L10n.t(.source)) { entry in
                Text(entry.sourceApp ?? "—")
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
            }
            TableColumn(L10n.t(.time)) { entry in
                Text(RelativeTimeFormatter.string(from: entry.date))
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            if let id = ids.first,
               let entry = viewModel.results.first(where: { $0.id == id }) {
                if entry.item.isFile {
                    Button(L10n.t(.pasteFileName)) {
                        viewModel.selectEntry(entry, pasteFileAsName: true)
                    }
                    Button(L10n.t(.pasteFile)) {
                        viewModel.selectEntry(entry, pasteFileAsName: false)
                    }
                    Button(L10n.t(.showInFinder)) {
                        viewModel.revealInFinder(entry)
                    }
                } else {
                    Button(L10n.t(.copyContent)) {
                        viewModel.selectEntry(entry)
                    }
                }
                Divider()
                if viewModel.isPinned(entry) {
                    Button(L10n.t(.unpinFromTop)) {
                        viewModel.togglePin(entry)
                    }
                } else {
                    Button(L10n.t(.pinToTop)) {
                        viewModel.togglePin(entry)
                    }
                }
            }
        }
        .background(
            HistoryTableDoubleClickHandler(results: viewModel.results) { entry in
                viewModel.selectEntry(entry)
            }
        )
    }

    private func contentPreview(for entry: HistoryEntry) -> String {
        let title = entry.item.title
        let singleLine = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count > 80 {
            return String(singleLine.prefix(80)) + "..."
        }
        return singleLine
    }

    private func locationPreview(for entry: HistoryEntry) -> String {
        entry.item.locationSummary ?? "—"
    }
}

private struct HistoryTableDoubleClickHandler: NSViewRepresentable {
    let results: [HistoryEntry]
    let onDoubleClick: (HistoryEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClick: onDoubleClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view, results: results)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView, results: results)
    }

    final class Coordinator: NSObject {
        var onDoubleClick: (HistoryEntry) -> Void
        private weak var tableView: NSTableView?
        private var results: [HistoryEntry] = []

        init(onDoubleClick: @escaping (HistoryEntry) -> Void) {
            self.onDoubleClick = onDoubleClick
        }

        func attach(to view: NSView, results: [HistoryEntry]) {
            self.results = results
            DispatchQueue.main.async { [weak self] in
                guard let self, let tableView = self.findTableView(from: view) else { return }
                guard self.tableView !== tableView else { return }
                self.tableView = tableView
                tableView.target = self
                tableView.doubleAction = #selector(self.handleDoubleClick(_:))
            }
        }

        @objc private func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < results.count else { return }
            onDoubleClick(results[row])
        }

        private func findTableView(from view: NSView) -> NSTableView? {
            var current: NSView? = view
            while let node = current {
                if let tableView = findTableViewInSubtree(node) {
                    return tableView
                }
                current = node.superview
            }
            return nil
        }

        private func findTableViewInSubtree(_ view: NSView) -> NSTableView? {
            if let tableView = view as? NSTableView { return tableView }
            for subview in view.subviews {
                if let tableView = findTableViewInSubtree(subview) {
                    return tableView
                }
            }
            return nil
        }
    }
}

private struct SearchKeyHandler: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherView()
        view.coordinator = context.coordinator
        context.coordinator.bind(
            view: view,
            onUp: onUp,
            onDown: onDown,
            onEnter: onEnter,
            onEscape: onEscape
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCatcherView else { return }
        context.coordinator.bind(
            view: view,
            onUp: onUp,
            onDown: onDown,
            onEnter: onEnter,
            onEscape: onEscape
        )
    }

    final class Coordinator {
        private weak var view: KeyCatcherView?
        private var monitor: Any?
        private var onUp: (() -> Void)?
        private var onDown: (() -> Void)?
        private var onEnter: (() -> Void)?
        private var onEscape: (() -> Void)?

        func bind(
            view: KeyCatcherView,
            onUp: @escaping () -> Void,
            onDown: @escaping () -> Void,
            onEnter: @escaping () -> Void,
            onEscape: @escaping () -> Void
        ) {
            self.view = view
            view.coordinator = self
            self.onUp = onUp
            self.onDown = onDown
            self.onEnter = onEnter
            self.onEscape = onEscape
            installMonitorIfNeeded(for: view)
        }

        func reinstallMonitor(for view: KeyCatcherView) {
            installMonitorIfNeeded(for: view)
        }

        private func installMonitorIfNeeded(for view: KeyCatcherView) {
            guard monitor == nil else { return }
            guard let window = view.window else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.installMonitorIfNeeded(for: view)
                }
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                switch event.keyCode {
                case 126:
                    self.onUp?()
                    return nil
                case 125:
                    self.onDown?()
                    return nil
                case 36:
                    self.onEnter?()
                    return nil
                case 53:
                    self.onEscape?()
                    return nil
                default:
                    return event
                }
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

private final class KeyCatcherView: NSView {
    weak var coordinator: SearchKeyHandler.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.reinstallMonitor(for: self)
    }
}
