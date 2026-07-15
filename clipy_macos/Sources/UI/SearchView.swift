import SwiftUI
import UniformTypeIdentifiers

extension HistoryEntry: Identifiable {
    var id: String {
        let hash = contentHash ?? ""
        return "\(date.timeIntervalSince1970)-\(hash)"
    }
}

final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var typeFilter: HistoryTypeFilter = .all
    @Published var sourceAppFilter = ""
    @Published var dateFilter: HistoryDateFilter = .all
    @Published var contentCategory: HistoryContentCategory?
    @Published var useRegex = false
    @Published var availableSourceApps: [String] = []
    @Published var results: [HistorySearchResult] = []
    @Published var selectedIDs = Set<HistoryEntry.ID>()
    @Published var statusText = ""

    private var debounceWorkItem: DispatchWorkItem?
    private var historyObserver: NSObjectProtocol?
    private var browseLimit: Int

    private var isLoadingMore = false
    private var searchGeneration = 0
    private let searchQueue = DispatchQueue(label: "com.clipy.search", qos: .userInitiated)

    init() {
        browseLimit = PreferencesManager.shared.historyLoadCount
    }

    func onResultRowAppear(_ result: HistorySearchResult) {
        guard result.id == results.last?.id else { return }
        loadMoreIfNeeded()
    }

    private func loadMoreIfNeeded() {
        guard canAutoLoadMore, !isLoadingMore else { return }
        isLoadingMore = true
        let pageSize = PreferencesManager.shared.historyLoadCount
        browseLimit = min(browseLimit + pageSize, ClipboardManager.shared.totalHistoryCount)
        // Cleared in applySearchResults once the async page lands.
        performSearch(immediate: true)
    }

    private var canAutoLoadMore: Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedQuery.isEmpty
            && typeFilter == .all
            && sourceAppFilter.isEmpty
            && dateFilter == .all
            && contentCategory == nil
            && !useRegex
            && browseLimit < ClipboardManager.shared.totalHistoryCount
    }

    func onAppear() {
        browseLimit = PreferencesManager.shared.historyLoadCount
        let snapshot = HistorySearchStateStore.load()
        query = snapshot.query
        typeFilter = snapshot.typeFilter
        sourceAppFilter = snapshot.sourceAppFilter
        dateFilter = snapshot.dateFilter
        useRegex = snapshot.useRegex
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

    func onDisappear() {
        prepareForClose()
    }

    func prepareForClose() {
        saveSearchState()
        clearLoadedData()
    }

    func clearLoadedData() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        isLoadingMore = false
        results = []
        selectedIDs = []
        statusText = ""
        browseLimit = PreferencesManager.shared.historyLoadCount
        availableSourceApps = []
        if let observer = historyObserver {
            NotificationCenter.default.removeObserver(observer)
            historyObserver = nil
        }
    }

    private func saveSearchState() {
        HistorySearchStateStore.save(HistorySearchStateStore.Snapshot(
            query: query,
            typeFilter: typeFilter,
            sourceAppFilter: sourceAppFilter,
            dateFilter: dateFilter,
            useRegex: useRegex
        ))
    }

    func onFilterChange() {
        performSearch(immediate: true)
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
        let manager = ClipboardManager.shared
        if !sourceAppFilter.isEmpty, !availableSourceApps.contains(sourceAppFilter), !availableSourceApps.isEmpty {
            sourceAppFilter = ""
        }
        let selectedSourceApp = sourceAppFilter.isEmpty ? nil : sourceAppFilter
        let isBrowseMode = trimmed.isEmpty
            && typeFilter == .all
            && sourceAppFilter.isEmpty
            && dateFilter == .all
            && contentCategory == nil
            && !useRegex
        let options = SearchHistoryOptions(
            query: trimmed,
            typeFilter: typeFilter,
            sourceApp: selectedSourceApp,
            dateFilter: dateFilter,
            contentCategory: contentCategory,
            useRegex: useRegex,
            browseLimit: isBrowseMode ? browseLimit : nil
        )

        // SQLite fetch (up to historyLimit rows) plus ranking (which may read full
        // text from disk) can take long on large histories: run off the main thread
        // and drop stale generations.
        searchGeneration += 1
        let generation = searchGeneration
        searchQueue.async { [weak self] in
            let sourceApps = manager.availableSourceApps()
            let searchResults = manager.searchHistory(options: options)
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }
                self.availableSourceApps = sourceApps
                self.applySearchResults(
                    searchResults,
                    trimmed: trimmed,
                    selectedSourceApp: selectedSourceApp,
                    totalCount: manager.totalHistoryCount
                )
            }
        }
    }

    private func applySearchResults(
        _ searchResults: [HistorySearchResult],
        trimmed: String,
        selectedSourceApp: String?,
        totalCount: Int
    ) {
        let previousSelection = selectedIDs
        results = searchResults
        isLoadingMore = false

        if totalCount == 0 {
            statusText = L10n.t(.noHistory)
        } else if results.isEmpty {
            statusText = L10n.format(.noSearchResultsWithTotal, totalCount)
        } else if isShowingAllHistory(
            trimmed: trimmed,
            selectedSourceApp: selectedSourceApp,
            shownCount: results.count,
            totalCount: totalCount
        ) {
            statusText = L10n.format(.historyTotalCount, totalCount)
        } else {
            statusText = L10n.format(.historyShownOfTotal, results.count, totalCount)
        }

        let validIDs = Set(results.map(\.id))
        selectedIDs = previousSelection.intersection(validIDs)
        if selectedIDs.isEmpty {
            selectedIDs = [results.first?.id].compactMap { $0 }.reduce(into: Set()) { $0.insert($1) }
        }
    }

    var primarySelectedID: HistoryEntry.ID? {
        selectedIDs.first ?? results.first?.id
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty, let currentID = primarySelectedID else { return }
        let currentIndex = results.firstIndex { $0.id == currentID } ?? 0
        let newIndex = max(0, min(currentIndex + offset, results.count - 1))
        selectedIDs = [results[newIndex].id]
    }

    func selectQuickIndex(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIDs = [results[index].id]
    }

    func selectAll() {
        selectedIDs = Set(results.map(\.id))
    }

    func selectCurrent(action: HistorySelectAction = .pasteAndClose) {
        guard let id = primarySelectedID,
              let result = results.first(where: { $0.id == id }) else { return }
        applyAction(action, to: result.entry)
    }

    func applyAction(_ action: HistorySelectAction, to entry: HistoryEntry, pasteFileAsName: Bool = true) {
        if case .files = entry.item {
            let clipboard = ClipboardManager.shared
            clipboard.moveHistoryEntryToFront(entry)
            if pasteFileAsName {
                clipboard.writeFileNamesToPasteboard(entry.item.fileURLs ?? [])
            } else {
                clipboard.writeToPasteboard(entry.item)
            }
            if action == .pasteAndClose {
                SearchWindow.shared.closeWindow()
            }
            if pasteFileAsName, action != .copyOnly {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    clipboard.simulatePasteIfTrusted()
                }
            }
            return
        }
        ClipboardManager.shared.applyHistoryEntry(entry, action: action)
    }

    func deleteSelected() {
        let entries = results.filter { selectedIDs.contains($0.id) }.map(\.entry)
        ClipboardManager.shared.removeHistoryEntries(entries)
        performSearch(immediate: true)
    }

    func togglePinSelected() {
        for id in selectedIDs {
            guard let entry = results.first(where: { $0.id == id })?.entry else { continue }
            ClipboardManager.shared.togglePin(for: entry)
        }
        performSearch(immediate: true)
    }

    func revealInFinder(_ entry: HistoryEntry) {
        ClipboardManager.shared.revealInFinder(for: entry)
    }

    func saveAsSnippet(_ entry: HistoryEntry) {
        let title = String(entry.item.title.prefix(40))
        let content: String
        switch entry.item {
        case .text: content = entry.resolvedText ?? entry.item.title
        case .files(let urls): content = urls.map(\.lastPathComponent).joined(separator: "\n")
        default: content = ClipboardManager.shared.plainText(for: entry.item) ?? entry.item.title
        }
        SnippetEditorWindow.shared.showWithPrefilledSnippet(title: title, content: content)
    }

    func isPinned(_ entry: HistoryEntry) -> Bool {
        entry.isPinned
    }

    func highlightRanges(for result: HistorySearchResult) -> [Range<String.Index>] {
        result.highlightRanges
    }

    private func matchesSelection(_ lhs: HistoryEntry, _ rhs: HistoryEntry) -> Bool {
        let lhsHash = lhs.contentHash ?? ""
        let rhsHash = rhs.contentHash ?? ""
        if !lhsHash.isEmpty, lhsHash == rhsHash { return true }
        return lhs.id == rhs.id
    }

    private func isShowingAllHistory(
        trimmed: String,
        selectedSourceApp: String?,
        shownCount: Int,
        totalCount: Int
    ) -> Bool {
        guard shownCount == totalCount else { return false }
        guard trimmed.isEmpty else { return false }
        guard typeFilter == .all else { return false }
        guard selectedSourceApp == nil else { return false }
        guard dateFilter == .all else { return false }
        guard contentCategory == nil else { return false }
        guard !useRegex else { return false }
        return true
    }
}

struct SearchView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let _ = languageObserver.revision

        AppListWindowLayout(statusText: viewModel.statusText) {
            AppWindowHeader {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(spacing: AppSpacing.sm) {
                        TextField(L10n.t(.searchHistoryPlaceholder), text: $viewModel.query)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFocused)
                            .onChange(of: viewModel.query) { _ in
                                viewModel.onQueryChange()
                            }
                        Toggle(L10n.t(.historyRegexSearch), isOn: $viewModel.useRegex)
                            .toggleStyle(.checkbox)
                            .onChange(of: viewModel.useRegex) { _ in
                                viewModel.onFilterChange()
                            }
                    }

                    HStack(spacing: AppSpacing.sm) {
                        Picker("", selection: $viewModel.typeFilter) {
                            ForEach(HistoryTypeFilter.allCases) { filter in
                                Text(L10n.t(filter.labelKey)).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: viewModel.typeFilter) { _ in viewModel.onFilterChange() }

                        Picker(L10n.t(.historyFilterSource), selection: $viewModel.sourceAppFilter) {
                            Text(L10n.t(.historyFilterAllSources)).tag("")
                            ForEach(viewModel.availableSourceApps, id: \.self) { app in
                                Text(app).tag(app)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 180)

                        Picker(L10n.t(.historyDateFilter), selection: $viewModel.dateFilter) {
                            ForEach(HistoryDateFilter.allCases) { filter in
                                Text(L10n.t(filter.labelKey)).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 120)
                        .onChange(of: viewModel.dateFilter) { _ in viewModel.onFilterChange() }
                    }
                    .onChange(of: viewModel.sourceAppFilter) { _ in viewModel.onFilterChange() }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.xs) {
                            categoryChip(title: L10n.t(.historyFilterAll), category: nil)
                            ForEach(HistoryContentCategory.allCases) { category in
                                categoryChip(title: L10n.t(category.labelKey), category: category)
                            }
                        }
                    }

                }
            }
        } content: {
            HSplitView {
                historyTable
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                HistoryPreviewView(entry: selectedEntry)
            }
        }
        .frame(
            minWidth: AppWindowSize.searchMin.width,
            idealWidth: AppWindowSize.search.width,
            maxWidth: .infinity,
            minHeight: AppWindowSize.searchMin.height,
            idealHeight: AppWindowSize.search.height,
            maxHeight: .infinity
        )
        .onAppear {
            viewModel.onAppear()
            searchFocused = true
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .background(SearchKeyHandler(viewModel: viewModel))
    }

    private var selectedEntry: HistoryEntry? {
        guard let id = viewModel.primarySelectedID else { return nil }
        return viewModel.results.first { $0.id == id }?.entry
    }

    private func categoryChip(title: String, category: HistoryContentCategory?) -> some View {
        let isSelected = viewModel.contentCategory == category
        return Button(title) {
            viewModel.contentCategory = category
            viewModel.onFilterChange()
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
    }

    private var historyTable: some View {
        Table(viewModel.results, selection: $viewModel.selectedIDs) {
            TableColumn(L10n.t(.content)) { result in
                historyContentRow(for: result)
                    .onDrag { dragItemProvider(for: result.entry) }
                    .onAppear { viewModel.onResultRowAppear(result) }
            }
            TableColumn(L10n.t(.location)) { result in
                Text(locationPreview(for: result.entry))
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TableColumn(L10n.t(.source)) { result in
                Text(result.entry.sourceApp ?? "—")
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
            }
            TableColumn(L10n.t(.time)) { result in
                Text(RelativeTimeFormatter.string(from: result.entry.date))
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            let entries = viewModel.results.filter { ids.contains($0.id) }.map(\.entry)
            if entries.count == 1, let entry = entries.first {
                contextMenu(for: entry)
            } else if !entries.isEmpty {
                Button(L10n.t(.delete)) { viewModel.deleteSelected() }
            }
        }
        .background(
            HistoryTableDoubleClickHandler(results: viewModel.results.map(\.entry)) { entry in
                viewModel.applyAction(.pasteAndClose, to: entry)
            }
        )
    }

    @ViewBuilder
    private func contextMenu(for entry: HistoryEntry) -> some View {
        if entry.item.isFile {
            Button(L10n.t(.pasteFileName)) {
                viewModel.applyAction(.pasteAndClose, to: entry, pasteFileAsName: true)
            }
            Button(L10n.t(.pasteFile)) {
                viewModel.applyAction(.pasteAndClose, to: entry, pasteFileAsName: false)
            }
            Button(L10n.t(.showInFinder)) {
                viewModel.revealInFinder(entry)
            }
        } else {
            Button(L10n.t(.copyContent)) {
                viewModel.applyAction(.copyOnly, to: entry)
            }
            Button(L10n.t(.pastePlainText)) {
                viewModel.applyAction(.pastePlainAndClose, to: entry)
            }
        }
        Divider()
        Button(L10n.t(.saveAsSnippet)) {
            viewModel.saveAsSnippet(entry)
        }
        Divider()
        if viewModel.isPinned(entry) {
            Button(L10n.t(.unpinFromTop)) { viewModel.togglePinSelected() }
        } else {
            Button(L10n.t(.pinToTop)) { viewModel.togglePinSelected() }
        }
        Button(L10n.t(.delete), role: .destructive) {
            viewModel.selectedIDs = [entry.id]
            viewModel.deleteSelected()
        }
    }

    @ViewBuilder
    private func historyContentRow(for result: HistorySearchResult) -> some View {
        if case .image(let path) = result.entry.item {
            HStack(spacing: 8) {
                if viewModel.isPinned(result.entry) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                LazyHistoryThumbnailView(
                    path: path,
                    size: NSSize(width: 72, height: 54),
                    placeholderSize: NSSize(width: 72, height: 54)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.entry.listDisplayTitle)
                        .font(AppFont.body)
                        .lineLimit(1)
                    if let location = result.entry.item.locationSummary {
                        Text(location)
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                historyTypeIcon(for: result.entry)
                if viewModel.isPinned(result.entry) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                HighlightedText(
                    text: contentPreview(for: result.entry),
                    highlightRanges: viewModel.highlightRanges(for: result)
                )
            }
        }
    }

    @ViewBuilder
    private func historyTypeIcon(for entry: HistoryEntry) -> some View {
        if entry.item.isFile, let urls = entry.item.fileURLs, let first = urls.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                .resizable()
                .frame(width: 16, height: 16)
        } else if case .image(let path) = entry.item {
            LazyHistoryThumbnailView(
                path: path,
                size: NSSize(width: 16, height: 16),
                placeholderSize: NSSize(width: 16, height: 16),
                cornerRadius: 2
            )
        } else {
            Image(systemName: iconName(for: entry.item))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    private func iconName(for item: HistoryItem) -> String {
        switch item {
        case .text: return "doc.text"
        case .image: return "photo"
        case .rtf: return "doc.richtext"
        case .pdf: return "doc.fill"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .files: return "doc"
        }
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

    private func dragItemProvider(for entry: HistoryEntry) -> NSItemProvider {
        switch entry.item {
        case .text:
            let text = entry.resolvedText ?? ""
            return NSItemProvider(object: text as NSString)
        case .image(let path):
            if let data = HistoryMediaStore.shared.data(at: path) {
                return NSItemProvider(item: data as NSSecureCoding, typeIdentifier: UTType.tiff.identifier)
            }
            return NSItemProvider()
        case .files(let urls):
            if let url = urls.first {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider()
        default:
            if let text = ClipboardManager.shared.plainText(for: entry) {
                return NSItemProvider(object: text as NSString)
            }
            return NSItemProvider(object: entry.item.title as NSString)
        }
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
                if let tableView = findTableViewInSubtree(node) { return tableView }
                current = node.superview
            }
            return nil
        }

        private func findTableViewInSubtree(_ view: NSView) -> NSTableView? {
            if let tableView = view as? NSTableView { return tableView }
            for subview in view.subviews {
                if let tableView = findTableViewInSubtree(subview) { return tableView }
            }
            return nil
        }
    }
}

private struct SearchKeyHandler: NSViewRepresentable {
    @ObservedObject var viewModel: SearchViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherView()
        view.coordinator = context.coordinator
        context.coordinator.installMonitor(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCatcherView else { return }
        view.coordinator = context.coordinator
        context.coordinator.viewModel = viewModel
        context.coordinator.installMonitor(for: view)
    }

    final class Coordinator {
        var viewModel: SearchViewModel
        private weak var view: KeyCatcherView?
        private var monitor: Any?

        init(viewModel: SearchViewModel) {
            self.viewModel = viewModel
        }

        func installMonitor(for view: KeyCatcherView) {
            self.view = view
            guard monitor == nil else { return }
            guard let window = view.window else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.installMonitor(for: view)
                }
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                return self.handle(event: event)
            }
        }

        private func handle(event: NSEvent) -> NSEvent? {
            let window = event.window
            let editingText = isEditingText(in: window)

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = flags.contains(.command)
            let option = flags.contains(.option)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if !editingText {
                if cmd, !option, key == "c" {
                    viewModel.selectCurrent(action: .copyOnly)
                    return nil
                }
                if cmd, option, key == "v" {
                    viewModel.selectCurrent(action: .pastePlainAndClose)
                    return nil
                }
                if cmd, key == "p" {
                    viewModel.togglePinSelected()
                    return nil
                }
                if cmd, let digit = Int(key), digit >= 1, digit <= 9 {
                    viewModel.selectQuickIndex(digit - 1)
                    return nil
                }
                if cmd, key == "a" {
                    viewModel.selectAll()
                    return nil
                }
                if event.keyCode == 36, cmd {
                    viewModel.selectCurrent(action: .pasteKeepOpen)
                    return nil
                }
                if event.keyCode == 51 || event.keyCode == 117 {
                    viewModel.deleteSelected()
                    return nil
                }

                switch event.keyCode {
                case 126:
                    viewModel.moveSelection(by: -1)
                    return nil
                case 125:
                    viewModel.moveSelection(by: 1)
                    return nil
                case 36:
                    viewModel.selectCurrent(action: .pasteAndClose)
                    return nil
                case 53:
                    SearchWindow.shared.closeWindow()
                    return nil
                default:
                    return event
                }
            }

            if event.keyCode == 53 {
                SearchWindow.shared.closeWindow()
                return nil
            }
            return event
        }

        private func isEditingText(in window: NSWindow?) -> Bool {
            guard let firstResponder = window?.firstResponder else { return false }
            if firstResponder is NSTextField { return true }
            if let textView = firstResponder as? NSTextView, textView.isFieldEditor {
                return true
            }
            return false
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private final class KeyCatcherView: NSView {
    weak var coordinator: SearchKeyHandler.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let coordinator, let window = window {
            coordinator.installMonitor(for: self)
            _ = window
        }
    }
}

private struct LazyHistoryThumbnailView: View {
    let path: String
    let size: NSSize
    let placeholderSize: NSSize
    var cornerRadius: CGFloat = 4

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: min(placeholderSize.width, placeholderSize.height) * 0.35))
                    .foregroundStyle(.secondary)
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
            }
        }
        .onAppear {
            loadThumbnailIfNeeded()
        }
        .onChange(of: path) { _ in
            thumbnail = nil
            loadThumbnailIfNeeded()
        }
    }

    private func loadThumbnailIfNeeded() {
        guard thumbnail == nil else { return }
        let path = path
        let size = size
        DispatchQueue.global(qos: .utility).async {
            let image = HistoryThumbnailCache.thumbnail(for: path, size: size)
            DispatchQueue.main.async {
                self.thumbnail = image
            }
        }
    }
}
