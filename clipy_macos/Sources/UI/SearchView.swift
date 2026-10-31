import SwiftUI
import UniformTypeIdentifiers

extension HistoryEntry: Identifiable {
    var id: String {
        let hash = contentHash ?? ""
        return "\(date.timeIntervalSince1970)-\(hash)"
    }
}

final class SearchViewModel: ObservableObject {
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter
    }()

    private static func grouped(_ value: Int) -> NSString {
        (countFormatter.string(from: NSNumber(value: value)) ?? String(value)) as NSString
    }

    private var hasAppeared = false
    private var pendingPanelQuery: String?

    func acceptPanelQuery(_ text: String) {
        pendingPanelQuery = text
        if hasAppeared { applyPanelQuery(); performSearch(immediate: true) }
    }

    private func applyPanelQuery() {
        guard let text = pendingPanelQuery else { return }
        pendingPanelQuery = nil
        query = text; typeFilter = .all; sourceAppFilter = ""; dateFilter = .all
        useRegex = false; contentCategory = nil; pinnedOnly = false
    }

    @Published var query = ""
    @Published var typeFilter: HistoryTypeFilter = .all
    @Published var sourceAppFilter = ""
    @Published var dateFilter: HistoryDateFilter = .all
    @Published var pinnedOnly = false
    @Published var contentCategory: HistoryContentCategory?
    @Published var useRegex = false
    @Published var availableSourceApps: [String] = []
    @Published var results: [HistorySearchResult] = []
    @Published var selectedIDs = Set<HistoryEntry.ID>()
    private var selectionAnchor: HistoryEntry.ID?
    @Published var statusText = ""
    /// Whole-history row count for the sidebar badge (refreshed with each search).
    @Published var totalCount = 0
    /// Message for the transient undo banner shown after a delete.
    @Published var undoMessage: String?
    private var lastDeletedEntries: [HistoryEntry] = []
    private var undoExpiryWorkItem: DispatchWorkItem?
    /// Kept well below ClipboardManager's 30s media-prune delay so restored
    /// entries still find their image/text files on disk.
    private static let undoWindow: TimeInterval = 8

    private var debounceWorkItem: DispatchWorkItem?
    private var historyChangeWorkItem: DispatchWorkItem?
    private var historyObserver: NSObjectProtocol?
    private var browseLimit: Int

    private var isLoadingMore = false
    private var searchGeneration = 0
    private var searchCancellation: HistorySearchCancellation?
    private let searchQueue = DispatchQueue(label: "com.clipy.search", qos: .userInitiated)
    private static let historyChangeDebounce: TimeInterval = 0.25

    init() {
        // First screen is one page; further pages load when the last row appears.
        browseLimit = PreferencesManager.shared.historyLoadCount
    }

    func onResultRowAppear(_ result: HistorySearchResult) {
        #if CLIPY_CORE_TESTS
        if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return }
        #endif
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
        return results.count >= browseLimit
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
        hasAppeared = true
        applyPanelQuery()
        performSearch(immediate: true)
        registerHistoryChangeObserver()
    }

    /// Called when the search window is reopened while still cached (within the
    /// WindowSession teardown window). SwiftUI's `.onAppear` does NOT fire again
    /// in that case because the view tree is reused, yet `prepareForClose`
    /// cleared `results` and removed the change observer on close. Without this
    /// the list would be blank until the user toggled a filter. Re-runs the
    /// query and re-registers the observer so the reopened window reflects the
    /// current history (including anything copied while it was closed).
    func reactivate() {
        browseLimit = PreferencesManager.shared.historyLoadCount
        hasAppeared = true
        applyPanelQuery()
        performSearch(immediate: true)
        registerHistoryChangeObserver()
    }

    private func registerHistoryChangeObserver() {
        guard historyObserver == nil else { return }
        historyObserver = NotificationCenter.default.addObserver(
            forName: .clipboardHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleHistoryChangeRefresh()
        }
    }

    /// Clipboard churn (rapid copies / remote sync) can fire many notifications;
    /// coalesce into one search so we don't re-query SQLite on every event.
    private func scheduleHistoryChangeRefresh() {
        historyChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSearch(immediate: true)
        }
        historyChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historyChangeDebounce, execute: work)
    }

    func onDisappear() {
        prepareForClose()
    }

    func prepareForClose() {
        saveSearchState()
        clearLoadedData()
        // A panel query arriving while the view is off screen waits for onAppear,
        // which would otherwise overwrite it with the saved search state.
        hasAppeared = false
    }

    func clearLoadedData() {
        searchCancellation?.cancel()
        searchGeneration += 1
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        historyChangeWorkItem?.cancel()
        historyChangeWorkItem = nil
        isLoadingMore = false
        results = []
        selectedIDs = []
        selectionAnchor = nil
        statusText = ""
        dismissUndo()
        // Reset to one page; onAppear/reactivate also re-seed this before fetch.
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
        browseLimit = PreferencesManager.shared.historyLoadCount
        performSearch(immediate: true)
    }

    deinit {
        searchCancellation?.cancel()
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    func onQueryChange() {
        searchCancellation?.cancel()
        searchGeneration += 1
        browseLimit = PreferencesManager.shared.historyLoadCount
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
        let options = SearchHistoryOptions(
            query: trimmed,
            typeFilter: typeFilter,
            sourceApp: selectedSourceApp,
            dateFilter: dateFilter,
            contentCategory: contentCategory,
            pinnedOnly: pinnedOnly,
            useRegex: useRegex,
            browseLimit: browseLimit
        )

        // SQLite fetch (up to historyLimit rows) plus ranking (which may read full
        // text from disk) can take long on large histories: run off the main thread
        // and drop stale generations.
        searchCancellation?.cancel()
        let cancellation = HistorySearchCancellation()
        searchCancellation = cancellation
        searchGeneration += 1
        let generation = searchGeneration
        searchQueue.async { [weak self] in
            guard !cancellation.isCancelled else { return }
            let sourceApps = manager.availableSourceApps()
            let searchResults = manager.searchHistory(options: options, cancellation: cancellation)
            DispatchQueue.main.async {
                guard let self, !cancellation.isCancelled, generation == self.searchGeneration else { return }
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
        self.totalCount = totalCount
        isLoadingMore = false

        if totalCount == 0 {
            statusText = L10n.t(.noHistory)
        } else if results.isEmpty {
            statusText = L10n.format(.noSearchResultsWithTotal, Self.grouped(totalCount))
        } else if isShowingAllHistory(
            trimmed: trimmed,
            selectedSourceApp: selectedSourceApp,
            shownCount: results.count,
            totalCount: totalCount
        ) {
            statusText = L10n.format(.historyTotalCount, Self.grouped(totalCount))
        } else {
            statusText = L10n.format(.historyShownOfTotal, Self.grouped(results.count), Self.grouped(totalCount))
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

    /// The row owns taps as well as dragging: onDrag consumes the native List
    /// mouse selection over its content. Keep modifier selection explicit so a
    /// tap cannot be lost (or Command-toggle applied twice by the native List).
    func selectRow(_ id: HistoryEntry.ID, modifiers: NSEvent.ModifierFlags) {
        let ids = results.map(\.id)
        guard let end = ids.firstIndex(of: id) else { return }
        if modifiers.contains(.shift),
           let anchor = selectionAnchor ?? ids.first(where: { selectedIDs.contains($0) }),
           let start = ids.firstIndex(of: anchor) {
            let range = Set(ids[min(start, end)...max(start, end)])
            selectedIDs = modifiers.contains(.command) ? selectedIDs.union(range) : range
            selectionAnchor = anchor
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            selectionAnchor = id
        } else {
            selectedIDs = [id]
            selectionAnchor = id
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty, let currentID = primarySelectedID else { return }
        let currentIndex = results.firstIndex { $0.id == currentID } ?? 0
        let newIndex = max(0, min(currentIndex + offset, results.count - 1))
        selectedIDs = [results[newIndex].id]
        selectionAnchor = results[newIndex].id
    }

    func selectQuickIndex(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIDs = [results[index].id]
        selectionAnchor = results[index].id
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
                MainWindow.shared.close(ifShowing: .history)
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
        guard !entries.isEmpty else { return }
        let removed = ClipboardManager.shared.removeHistoryEntries(entries)
        performSearch(immediate: true)
        guard !removed.isEmpty else { return }
        lastDeletedEntries = removed
        undoMessage = L10n.format(.historyDeletedCount, removed.count)
        undoExpiryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissUndo() }
        undoExpiryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow, execute: work)
    }

    /// Restores the most recent delete. Returns false when nothing is pending.
    @discardableResult
    func undoDelete() -> Bool {
        guard !lastDeletedEntries.isEmpty else { return false }
        let entries = lastDeletedEntries
        dismissUndo()
        ClipboardManager.shared.restoreHistoryEntries(entries)
        performSearch(immediate: true)
        selectedIDs = Set(entries.map(\.id))
        return true
    }

    func dismissUndo() {
        undoExpiryWorkItem?.cancel()
        undoExpiryWorkItem = nil
        lastDeletedEntries = []
        undoMessage = nil
    }

    /// 清空全部历史记录（破坏性操作，弹窗确认）。返回是否已执行清理。
    @discardableResult
    func clearAllHistory() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.t(.clearHistory)
        alert.informativeText = L10n.t(.clearHistoryConfirm)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t(.clear))
        alert.addButton(withTitle: L10n.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        ClipboardManager.shared.clearHistory()
        performSearch(immediate: true)
        return true
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
        MainWindow.shared.showWithPrefilledSnippet(title: title, content: content)
    }

    func isPinned(_ entry: HistoryEntry) -> Bool {
        entry.isPinned
    }

    func highlightRanges(for result: HistorySearchResult) -> [Range<String.Index>] {
        result.highlightRanges
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
        guard contentCategory == nil, !pinnedOnly else { return false }
        guard !useRegex else { return false }
        return true
    }
}

struct SearchView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var searchFocused: Bool

    private static let listWidth: CGFloat = 388

    var body: some View {
        let _ = languageObserver.revision

        HStack(spacing: 0) {
            historySidebar
            listColumn
                .frame(width: Self.listWidth)
            previewColumn
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(
            minWidth: AppWindowSize.searchMin.width,
            idealWidth: AppWindowSize.search.width,
            maxWidth: .infinity,
            minHeight: AppWindowSize.searchMin.height,
            idealHeight: AppWindowSize.search.height,
            maxHeight: .infinity
        )
        .onAppear {
            #if CLIPY_CORE_TESTS
            if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { searchFocused = true; return }
            #endif
            viewModel.onAppear()
            searchFocused = true
        }
        .onDisappear {
            #if CLIPY_CORE_TESTS
            if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return }
            #endif
            viewModel.onDisappear()
        }
        .background(SearchKeyHandler(viewModel: viewModel))
    }

    // MARK: Sidebar

    private enum SidebarFilter: Equatable {
        case all, pinned, type(HistoryTypeFilter), category(HistoryContentCategory)
    }

    private var activeSidebarFilter: SidebarFilter {
        if viewModel.pinnedOnly { return .pinned }
        if let category = viewModel.contentCategory { return .category(category) }
        if viewModel.typeFilter != .all { return .type(viewModel.typeFilter) }
        return .all
    }

    private func applySidebarFilter(_ filter: SidebarFilter) {
        viewModel.pinnedOnly = filter == .pinned
        if case .type(let type) = filter { viewModel.typeFilter = type } else { viewModel.typeFilter = .all }
        if case .category(let category) = filter { viewModel.contentCategory = category } else { viewModel.contentCategory = nil }
        viewModel.onFilterChange()
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights, which sit inside the sidebar
            // (plus the module switcher when hosted in the main window).
            MainWindowSidebarHeader()
            sidebarRow(.all, title: HistoryV3.s("全部历史", "All History"), symbol: "clock",
                       count: viewModel.totalCount > 0 ? viewModel.totalCount.formatted() : nil)
            sidebarRow(.pinned, title: HistoryV3.s("已置顶", "Pinned"), symbol: "pin")
            sidebarHeader(HistoryV3.s("类型", "Types"))
            sidebarRow(.type(.text), title: L10n.t(.historyTypeText), symbol: HistorySymbol.type)
            sidebarRow(.type(.richText), title: L10n.t(.historyFilterRichText), symbol: "doc.richtext")
            sidebarRow(.type(.image), title: L10n.t(.historyTypeImage), symbol: "photo")
            sidebarRow(.type(.file), title: L10n.t(.historyTypeFile), symbol: "doc.text")
            sidebarHeader(HistoryV3.s("分类", "Categories"))
            ForEach(HistoryContentCategory.allCases) { category in
                sidebarRow(.category(category), title: L10n.t(category.labelKey),
                           symbol: categorySymbol(category), muted: true)
            }
            Spacer(minLength: 8)
            Button {
                SettingsWindow.shared.show(page: "history")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hourglass").font(.system(size: 13)).foregroundStyle(HistoryV3.text3)
                    Text(L10n.t(.historyRetention)).foregroundStyle(HistoryV3.text2)
                    Spacer(minLength: 4)
                    let days = PreferencesManager.shared.historyRetentionDays
                    Text(days == 0 ? L10n.t(.historyRetentionForever) : L10n.format(.historyRetentionDays, days))
                        .foregroundStyle(HistoryV3.text3)
                }
                .font(.system(size: 12))
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(HistoryV3.s("打开偏好设置 · 保留时长", "Open Preferences · Keep History For"))
            .overlay(alignment: .top) { HistoryV3.line.frame(height: 0.5) }
            MainWindowSidebarFooter()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: MainWindowMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(HistoryV3.sidebar)
        .overlay(alignment: .trailing) { HistoryV3.line.frame(width: 0.5) }
    }

    private func sidebarHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(HistoryV3.text3)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 5)
            .accessibilityAddTraits(.isHeader)
    }

    private func sidebarRow(_ filter: SidebarFilter, title: String, symbol: String, count: String? = nil, muted: Bool = false) -> some View {
        let isOn = activeSidebarFilter == filter
        return Button {
            applySidebarFilter(filter)
        } label: {
            HStack(spacing: 9) {
                HistorySymbol(name: symbol, size: 14)
                    .foregroundStyle(muted ? HistoryV3.text2 : HistoryV3.brand)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: isOn ? .medium : .regular))
                    .foregroundStyle(HistoryV3.text)
                Spacer(minLength: 4)
                if let count {
                    Text(count)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(HistoryV3.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isOn ? HistoryV3.fill2 : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func categorySymbol(_ category: HistoryContentCategory) -> String {
        switch category {
        case .url: return "link"
        case .email: return "envelope"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .json: return "curlybraces"
        }
    }

    // MARK: List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                searchField
                Button {
                    viewModel.clearAllHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(HistoryToolButtonStyle())
                .help(L10n.t(.clearHistory))
                .accessibilityLabel(L10n.t(.clearHistory))
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .overlay(alignment: .bottom) { HistoryV3.line.frame(height: 0.5) }

            filterChips
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

            historyList
                .frame(maxHeight: .infinity)

            HStack(spacing: 6) {
                Text(L10n.t(.historyShortcutHint)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(viewModel.statusText).lineLimit(1).fixedSize()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(HistoryV3.text3)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .overlay(alignment: .top) { HistoryV3.line.frame(height: 0.5) }
        }
        .background(HistoryV3.listBackground)
        .overlay(alignment: .trailing) { HistoryV3.line.frame(width: 0.5) }
        .overlay(alignment: .bottom) {
            if let message = viewModel.undoMessage {
                undoBanner(message)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: viewModel.undoMessage)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(HistoryV3.text3)
            TextField(L10n.t(.searchHistoryPlaceholder), text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onChange(of: viewModel.query) { _ in viewModel.onQueryChange() }
            Button {
                viewModel.useRegex.toggle()
                viewModel.onFilterChange()
            } label: {
                HStack(spacing: 4) {
                    Text(".*").font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    Text(L10n.t(.historyRegexSearch))
                }
                .font(.system(size: 11.5, weight: viewModel.useRegex ? .semibold : .regular))
                .foregroundStyle(viewModel.useRegex ? HistoryV3.brand : HistoryV3.text3)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(viewModel.useRegex ? HistoryV3.brand.opacity(0.14) : HistoryV3.fill,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t(.historyRegexSearch))
            .accessibilityAddTraits(viewModel.useRegex ? .isSelected : [])
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(searchFocused ? HistoryV3.listBackground : HistoryV3.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? HistoryV3.brand : Color.clear, lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                .stroke(searchFocused ? HistoryV3.brand.opacity(0.25) : Color.clear, lineWidth: 3.5)
                .padding(-1.75)
        )
        .frame(maxWidth: .infinity)
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(HistoryDateFilter.allCases) { filter in
                Button(L10n.t(filter.labelKey)) {
                    viewModel.dateFilter = filter
                    viewModel.onFilterChange()
                }
                .buttonStyle(HistoryChipStyle(isOn: viewModel.dateFilter == filter))
                .accessibilityAddTraits(viewModel.dateFilter == filter ? .isSelected : [])
            }
            Button {
                showSourceMenu()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow").font(.system(size: 11))
                    Text(viewModel.sourceAppFilter.isEmpty ? L10n.t(.historyFilterAllSources) : viewModel.sourceAppFilter)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.7)
                }
            }
            .buttonStyle(HistoryChipStyle(isOn: !viewModel.sourceAppFilter.isEmpty))
            .help(L10n.t(.historyFilterSource))
            Spacer(minLength: 0)
        }
    }

    private func showSourceMenu() {
        var items: [HistoryPopupMenu.Item] = [
            .init(title: L10n.t(.historyFilterAllSources), isOn: viewModel.sourceAppFilter.isEmpty) { [viewModel] in
                viewModel.sourceAppFilter = ""
                viewModel.onFilterChange()
            }
        ]
        if !viewModel.availableSourceApps.isEmpty { items.append(.separator) }
        for app in viewModel.availableSourceApps {
            items.append(.init(title: app, isOn: viewModel.sourceAppFilter == app) { [viewModel] in
                viewModel.sourceAppFilter = app
                viewModel.onFilterChange()
            })
        }
        HistoryPopupMenu.show(items)
    }

    private func undoBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(HistoryV3.text)
            Button(L10n.t(.undo)) { viewModel.undoDelete() }
                .buttonStyle(HistoryActionButtonStyle(small: true))
            Text("⌘Z")
                .font(.system(size: 11))
                .foregroundStyle(HistoryV3.text3)
                .padding(.trailing, 6)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(HistoryV3.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    // MARK: List

    private struct HistoryDayGroup: Identifiable {
        let id: Int
        let title: String
        let entries: [HistorySearchResult]
    }

    /// Design groups rows into 今天 / 更早, keeping the search order inside.
    private var historyGroups: [HistoryDayGroup] {
        let calendar = Calendar.current
        var today: [HistorySearchResult] = []
        var earlier: [HistorySearchResult] = []
        for result in viewModel.results {
            if calendar.isDateInToday(result.entry.date) { today.append(result) } else { earlier.append(result) }
        }
        var groups: [HistoryDayGroup] = []
        if !today.isEmpty { groups.append(.init(id: 0, title: L10n.t(.historyDateFilterToday), entries: today)) }
        if !earlier.isEmpty { groups.append(.init(id: 1, title: HistoryV3.s("更早", "Earlier"), entries: earlier)) }
        return groups
    }

    #if CLIPY_CORE_TESTS
    var historyListForTesting: some View { historyList }
    #endif

    private var historyList: some View {
        List(selection: $viewModel.selectedIDs) {
            ForEach(historyGroups) { group in
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HistoryV3.text3)
                    .padding(.horizontal, 10)
                    .padding(.top, group.id == historyGroups.first?.id ? 8 : 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.entries) { result in
                    historyRow(result)
                        .tag(result.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 1, trailing: 8))
                        .listRowSeparator(.hidden)
                        .onAppear { viewModel.onResultRowAppear(result) }
                        .onTapGesture {
                            let event = NSApp.currentEvent
                            viewModel.selectRow(result.id, modifiers: event?.modifierFlags ?? [])
                            if event?.clickCount == 2 {
                                viewModel.applyAction(.pasteAndClose, to: result.entry)
                            }
                        }
                        .onDrag { dragItemProvider(for: result.entry) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .background(HistoryListSelectionStyler())
        .overlay {
            if viewModel.results.isEmpty, !viewModel.statusText.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(HistoryV3.text3)
                    Text(viewModel.statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(HistoryV3.text3)
                }
                .padding()
                .allowsHitTesting(false)
            }
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            let entries = viewModel.results.filter { ids.contains($0.id) }.map(\.entry)
            if entries.count == 1, let entry = entries.first {
                contextMenu(for: entry)
            } else if !entries.isEmpty {
                Button(L10n.t(.delete)) { viewModel.deleteSelected() }
            }
        } primaryAction: { ids in
            // Native primary action also covers keyboard/accessibility activation.
            // Row taps handle mouse selection and double-click without a delaying
            // double-tap recognizer.
            guard let id = ids.first,
                  let entry = viewModel.results.first(where: { $0.id == id })?.entry else { return }
            viewModel.applyAction(.pasteAndClose, to: entry)
        }
    }

    private func historyRow(_ result: HistorySearchResult) -> some View {
        let entry = result.entry
        let info = HistoryKind.of(entry)
        let isSelected = viewModel.selectedIDs.contains(result.id)
        let multiLine = info.kind == .text || info.kind == .rich
        return HStack(alignment: .top, spacing: 11) {
            if case .image(let path) = entry.item {
                LazyHistoryThumbnailView(
                    path: path,
                    size: NSSize(width: 92, height: 68),
                    placeholderSize: NSSize(width: 46, height: 34),
                    cornerRadius: 6,
                    fill: true
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HistoryV3.line, lineWidth: 0.5))
            } else {
                HistoryTypeTile(kind: info.kind, symbol: info.symbol)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(rowText(for: result, kind: info.kind))
                    .font(info.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .foregroundStyle(HistoryV3.text)
                    .lineSpacing(2.5)
                    .lineLimit(multiLine ? 2 : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                rowMeta(for: entry)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? HistoryV3.selection : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private func rowText(for result: HistorySearchResult, kind: HistoryKind) -> AttributedString {
        if case .image = result.entry.item {
            return AttributedString(result.entry.listDisplayTitle)
        }
        return HistoryRowText.highlighted(title: result.entry.item.title, ranges: viewModel.highlightRanges(for: result))
    }

    private func rowMeta(for entry: HistoryEntry) -> some View {
        HStack(spacing: 6) {
            HistorySourceAppLabel(name: entry.sourceApp, bundleID: entry.sourceBundleId)
            Text("·")
            Text(RelativeTimeFormatter.string(from: entry.date)).fixedSize()
            if let location = rowLocation(for: entry) {
                Text("·")
                Text(location)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.item.locationSummary ?? "")
            }
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(HistoryV3.warn)
                    .help(L10n.t(.pinToTop))
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(HistoryV3.text3)
        .lineLimit(1)
    }

    /// File rows show the path; image rows show the OCR hit when the current
    /// query matched recognised text (`searchIndex`).
    private func rowLocation(for entry: HistoryEntry) -> AttributedString? {
        switch entry.item {
        case .files:
            guard let location = entry.item.locationSummary?.components(separatedBy: "\n").first else { return nil }
            return AttributedString(location)
        case .image:
            let query = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, !viewModel.useRegex,
                  let index = entry.searchIndex, index.localizedCaseInsensitiveContains(query) else { return nil }
            var hit = AttributedString(query)
            hit.backgroundColor = HistoryV3.mark
            return AttributedString(HistoryV3.s("含识别文字“", "Contains text “")) + hit + AttributedString("”")
        default:
            return nil
        }
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

    /// Same items as the row context menu, for the preview toolbar's “更多”.
    private func showMoreMenu(for entry: HistoryEntry) {
        var items: [HistoryPopupMenu.Item] = []
        if entry.item.isFile {
            items.append(.init(title: L10n.t(.pasteFileName)) { [viewModel] in
                viewModel.applyAction(.pasteAndClose, to: entry, pasteFileAsName: true)
            })
            items.append(.init(title: L10n.t(.pasteFile)) { [viewModel] in
                viewModel.applyAction(.pasteAndClose, to: entry, pasteFileAsName: false)
            })
            items.append(.init(title: L10n.t(.showInFinder)) { [viewModel] in viewModel.revealInFinder(entry) })
        } else {
            items.append(.init(title: L10n.t(.copyContent)) { [viewModel] in viewModel.applyAction(.copyOnly, to: entry) })
            items.append(.init(title: L10n.t(.pastePlainText)) { [viewModel] in viewModel.applyAction(.pastePlainAndClose, to: entry) })
        }
        items.append(.separator)
        items.append(.init(title: L10n.t(.saveAsSnippet)) { [viewModel] in viewModel.saveAsSnippet(entry) })
        items.append(.separator)
        items.append(.init(title: L10n.t(entry.isPinned ? .unpinFromTop : .pinToTop)) { [viewModel] in viewModel.togglePinSelected() })
        items.append(.init(title: L10n.t(.delete)) { [viewModel] in
            viewModel.selectedIDs = [entry.id]
            viewModel.deleteSelected()
        })
        HistoryPopupMenu.show(items)
    }

    // MARK: Preview column

    private var selectedEntry: HistoryEntry? {
        guard let id = viewModel.primarySelectedID else { return nil }
        return viewModel.results.first { $0.id == id }?.entry
    }

    private var previewColumn: some View {
        let entry = selectedEntry
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let entry {
                    let info = HistoryKind.of(entry)
                    HistoryTypeTag(kind: info.kind, symbol: info.symbol, label: info.label)
                    HistoryPreviewDetailText(entry: entry)
                }
                Spacer(minLength: 8)
                Group {
                    Button {
                        viewModel.togglePinSelected()
                    } label: { Image(systemName: entry?.isPinned == true ? "pin.fill" : "pin") }
                        .buttonStyle(HistoryToolButtonStyle(isOn: entry?.isPinned == true))
                        .help(L10n.t(entry?.isPinned == true ? .unpinFromTop : .pinToTop))
                        .accessibilityLabel(L10n.t(entry?.isPinned == true ? .unpinFromTop : .pinToTop))
                    Button {
                        if let entry { viewModel.saveAsSnippet(entry) }
                    } label: { Image(systemName: "bookmark") }
                        .buttonStyle(HistoryToolButtonStyle())
                        .help(L10n.t(.saveAsSnippet)).accessibilityLabel(L10n.t(.saveAsSnippet))
                    Button { viewModel.deleteSelected() } label: { Image(systemName: "trash") }
                        .buttonStyle(HistoryToolButtonStyle())
                        .help(L10n.t(.delete)).accessibilityLabel(L10n.t(.delete))
                    Button {
                        if let entry { showMoreMenu(for: entry) }
                    } label: { Image(systemName: "ellipsis") }
                        .buttonStyle(HistoryToolButtonStyle())
                        .help(HistoryV3.s("更多", "More")).accessibilityLabel(HistoryV3.s("更多", "More"))
                }
                .disabled(entry == nil)
            }
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .frame(height: 52)

            HistoryPreviewView(entry: entry, query: viewModel.useRegex ? "" : viewModel.query) { entry in
                viewModel.revealInFinder(entry)
            }
            .background(HistoryV3.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HistoryV3.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .padding(.horizontal, 22)
            .padding(.top, 2)

            if let entry {
                previewFacts(for: entry)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                previewActions(for: entry)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
            } else {
                Color.clear.frame(height: 22)
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .background(HistoryV3.previewBackground)
    }

    private func previewFacts(for entry: HistoryEntry) -> some View {
        HStack(spacing: 0.5) {
            factCell(HistoryV3.s("来源", "Source")) {
                HistorySourceAppLabel(name: entry.sourceApp, bundleID: entry.sourceBundleId, fact: true)
            }
            factCell(HistoryV3.s("复制时间", "Copied")) {
                Text(HistoryRowText.absolute(entry.date))
            }
            factCell(HistoryV3.s("使用次数", "Uses")) {
                Text(HistoryV3.s("\(entry.useCount) 次", entry.useCount == 1 ? "1 time" : "\(entry.useCount) times"))
            }
            factCell(HistoryV3.s("最近使用", "Last Used")) {
                Text(entry.lastUsedAt.map(HistoryRowText.absolute) ?? "—")
            }
        }
        .background(HistoryV3.line)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(HistoryV3.line, lineWidth: 0.5))
    }

    private func factCell<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(HistoryV3.text3)
            value()
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(HistoryV3.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HistoryV3.card)
    }

    @ViewBuilder
    private func previewActions(for entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            if entry.item.isFile {
                Button {
                    viewModel.applyAction(.pasteAndClose, to: entry, pasteFileAsName: false)
                } label: { Label(L10n.t(.pasteFile), systemImage: "doc.on.clipboard") }
                    .buttonStyle(HistoryActionButtonStyle(primary: true))
                Button {
                    viewModel.applyAction(.pasteAndClose, to: entry, pasteFileAsName: true)
                } label: { Label { Text(L10n.t(.pasteFileName)) } icon: { HistorySymbol(name: HistorySymbol.type) } }
                    .buttonStyle(HistoryActionButtonStyle())
            } else {
                Button {
                    viewModel.applyAction(.pasteAndClose, to: entry)
                } label: { Label(L10n.t(.paste), systemImage: "doc.on.clipboard") }
                    .buttonStyle(HistoryActionButtonStyle(primary: true))
                    .help(HistoryV3.s("粘贴并关闭窗口", "Paste and close the window"))
                Button {
                    viewModel.applyAction(.copyOnly, to: entry)
                } label: { Label(L10n.t(.panelCopy), systemImage: "doc.on.doc") }
                    .buttonStyle(HistoryActionButtonStyle())
                    .help(L10n.t(.copyContent))
                if case .image = entry.item {} else {
                    Button {
                        viewModel.applyAction(.pastePlainAndClose, to: entry)
                    } label: { Label { Text(L10n.t(.pastePlainText)) } icon: { HistorySymbol(name: HistorySymbol.removeFormatting) } }
                        .buttonStyle(HistoryActionButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
        .labelStyle(HistoryButtonLabelStyle())
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

private struct HistoryButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 13))
            configuration.title
        }
    }
}

/// Native List selection stays (multi-select, double-click, context menu,
/// drag), but its system highlight is replaced by the V3 row background.
private struct HistoryListSelectionStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(from: nsView)
    }

    private func apply(from view: NSView) {
        DispatchQueue.main.async {
            var node: NSView? = view
            while let current = node {
                if let table = Self.findTable(in: current) {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    table.backgroundColor = .clear
                    return
                }
                node = current.superview
            }
        }
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = findTable(in: subview) { return table }
        }
        return nil
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

            // Esc: clear the query first, then close (leave IME composition alone).
            if event.keyCode == 53, flags.isDisjoint(with: [.command, .option, .control, .shift]) {
                if let textView = window?.firstResponder as? NSTextView, textView.hasMarkedText() { return event }
                if !viewModel.query.isEmpty {
                    viewModel.query = ""
                } else {
                    MainWindow.shared.close(ifShowing: .history)
                }
                return nil
            }

            if !editingText {
                if cmd, !option, key == "z", viewModel.undoDelete() {
                    return nil
                }
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
                // ⌥⌘1–4 is the main window's section switch; leave it to the app menu.
                if cmd, !option, let digit = Int(key), digit >= 1, digit <= 9 {
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
                default:
                    return event
                }
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
    /// Aspect-fill the frame (V3 row thumbnails) instead of stretching.
    var fill = false

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: min(placeholderSize.width, placeholderSize.height) * 0.35))
                    .foregroundStyle(HistoryKind.image.tint)
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
                    .background(HistoryKind.image.tintBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
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

/// Source column cell: app icon (resolved from the bundle ID) + name.
/// Rows without a bundle ID but with a name come from another device
/// (LAN/relay sync or received files) and get the device glyph.
struct HistorySourceAppLabel: View {
    let name: String?
    let bundleID: String?
    /// Preview fact cell: inherits the caller's font/colour.
    var fact = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon = AppIconCache.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            } else if name != nil, bundleID == nil {
                Image(systemName: "iphone")
                    .font(.system(size: 11))
                    .frame(width: 14, height: 14)
            }
            Text(name ?? "—")
                .lineLimit(1)
        }
        .help(name ?? "")
    }
}

/// Small bounded cache of app icons keyed by bundle ID; misses are cached too
/// so uninstalled apps do not hit Launch Services on every row render.
enum AppIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
    private static var misses = Set<String>()

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty, !misses.contains(bundleID) else { return nil }
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    static func removeAll() {
        cache.removeAllObjects()
        misses.removeAll()
    }
}
