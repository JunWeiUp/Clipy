import AppKit
import Combine

/// UI-only state. History queries are bounded and cancelled on every edit/close.
/// No clipboard data or temporary menu-bar identities are persisted here.
final class MenuBarPanelModel: ObservableObject {
    enum Tab: CaseIterable { case clipboard, snippets, tools
        var title: String {
            switch self {
            case .clipboard: return L10n.t(.panelClipboard)
            case .snippets: return L10n.t(.snippets)
            case .tools: return L10n.t(.menuTools)
            }
        }
    }
    enum Page { case home, capture, devices, notifications, settings }
    enum Action { case search(String), snippets, preferences, syncSettings, notifications, word, wordBook, smartSwitch, password, tokenUsage
        case region, window, fullscreen, screenshotSettings, permission, quit
        case sendText(String), sendFile(String)
    }
    enum Tool: String, CaseIterable {
        case capture, word, wordBook, smartSwitch, password
        var title: L10nKey {
            switch self {
            case .capture: return .panelCapture
            case .word: return .wordLookup
            case .wordBook: return .wordBook
            case .smartSwitch: return .smartSwitchTitle
            case .password: return .generatePassword
            }
        }
        var hint: L10nKey {
            switch self {
            case .capture: return .panelCaptureToolHint
            case .word: return .panelWordHint
            case .wordBook: return .panelBookHint
            case .smartSwitch: return .panelSmartHint
            case .password: return .panelPasswordHint
            }
        }
        var symbol: String {
            switch self {
            case .capture: return "camera"
            case .word: return "character.book.closed"
            case .wordBook: return "books.vertical"
            case .smartSwitch: return "arrow.triangle.swap"
            case .password: return "key.horizontal"
            }
        }
    }
    enum HistoryAction { case use, copy, plainText, fileNames, reveal }
    typealias Search = (SearchHistoryOptions, HistorySearchCancellation) -> [HistoryEntry]
    @Published var tab: Tab = .clipboard
    @Published var page: Page = .home
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var filter: HistoryTypeFilter = .all { didSet { if filter != oldValue { scheduleSearch() } } }
    @Published var folderID: UUID?
    @Published private(set) var history: [HistoryEntry] = []
    @Published var folders: [SnippetFolder] = []
    @Published var devices: [DeviceEntry] = []
    @Published var notifications: [NotificationManager.NotificationEntry] = []
    @Published var notificationCount = 0
    @Published var pinned = false
    @Published var selectedID: String?
    @Published private(set) var loading = false
    @Published var focusRequest = 0
    @Published var notice: String?
    var onAction: ((Action) -> Void)?
    var onHistory: ((HistoryEntry, HistoryAction) -> Void)?
    var onSnippet: ((UUID) -> Void)?
    var onClose: (() -> Void)?
    private let search: Search
    private let queue: DispatchQueue
    private var cancellation: HistorySearchCancellation?
    private var revision = 0
    private var open = false
    private var pending: DispatchWorkItem?

    init(search: @escaping Search = { options, cancellation in
        ClipboardManager.shared.searchHistory(options: options, cancellation: cancellation).map(\.entry)
    }, queue: DispatchQueue = DispatchQueue(label: "clipy.control-panel.search", qos: .userInitiated)) {
        self.search = search
        self.queue = queue
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var visibleSnippets: [Snippet] {
        folders.filter { isSearching || folderID == nil || $0.id == folderID }
            .flatMap(\.snippets).filter { matches($0.title + " " + $0.content) }
    }
    func matches(_ text: String) -> Bool {
        !isSearching || text.localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func begin() {
        open = true
        tab = .clipboard; page = .home; query = ""; filter = .all
        folderID = nil; selectedID = nil; notice = nil
        scheduleSearch(immediate: true)
    }
    func end() {
        open = false; revision += 1
        pending?.cancel(); pending = nil
        cancellation?.cancel(); cancellation = nil
        history = []; folders = []; devices = []; notifications = []
        query = ""; selectedID = nil; loading = false; notice = nil
    }
    func refreshHistory() { scheduleSearch(immediate: true) }
    func navigate(_ page: Page) { self.page = page; query = ""; selectedID = nil; notice = nil }
    func selectTab(_ tab: Tab) { self.tab = tab; navigate(.home) }
    func escape() {
        if isSearching { query = "" }
        else if page != .home { navigate(.home) }
        else { onClose?() }
    }
    var matchingTools: [Tool] { Tool.allCases.filter { matches(L10n.t($0.title) + " " + L10n.t($0.hint)) } }
    func useTool(_ tool: Tool) {
        switch tool {
        case .capture: navigate(.capture)
        case .word: onAction?(.word)
        case .wordBook: onAction?(.wordBook)
        case .smartSwitch: onAction?(.smartSwitch)
        case .password: onAction?(.password)
        }
    }
    var selectableIDs: [String] {
        guard page == .home else { return [] }
        if isSearching { return history.map { "h:" + $0.id } + visibleSnippets.map { "s:" + $0.id.uuidString } + matchingTools.map { "t:" + $0.rawValue } }
        switch tab {
        case .clipboard: return history.map { "h:" + $0.id }
        case .snippets: return visibleSnippets.map { "s:" + $0.id.uuidString }
        case .tools: return matchingTools.map { "t:" + $0.rawValue }
        }
    }
    func moveSelection(_ delta: Int) {
        selectedID = MenuBarPanelPolicy.nextSelection(ids: selectableIDs, selected: selectedID, delta: delta)
    }
    func useSelection() {
        guard let id = selectedID ?? selectableIDs.first else { return }
        if let entry = history.first(where: { "h:" + $0.id == id }) { onHistory?(entry, .use) }
        else if let snippet = visibleSnippets.first(where: { "s:" + $0.id.uuidString == id }) { onSnippet?(snippet.id) }
        else if let tool = matchingTools.first(where: { "t:" + $0.rawValue == id }) { useTool(tool) }
    }
    func useHistoryShortcut(_ index: Int) {
        guard page == .home, tab == .clipboard, history.indices.contains(index) else { return }
        onHistory?(history[index], .use)
    }
    private func scheduleSearch(immediate: Bool = false) {
        guard open else { return }
        revision += 1
        let ticket = revision
        pending?.cancel(); cancellation?.cancel()
        let token = HistorySearchCancellation()
        cancellation = token
        // Never execute a selection from the previous query while a new one is loading.
        history = []; selectedID = nil; loading = true
        let options = SearchHistoryOptions(query: query, typeFilter: isSearching ? .all : filter,
                                           browseLimit: isSearching || filter != .all ? 40 : 6)
        let search = self.search
        let work = DispatchWorkItem { [weak self] in
            guard !token.isCancelled else { return }
            let entries = search(options, token)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.open, self.revision == ticket, !token.isCancelled else { return }
                self.history = entries
                self.loading = false
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.18), execute: work)
    }
}

/// Pure policies used by the window and by the core regression harness.
enum MenuBarPanelPolicy {
    static func nextSelection(ids: [String], selected: String?, delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else { return delta < 0 ? ids.last : ids.first }
        return ids[(index + delta % ids.count + ids.count) % ids.count]
    }
    static func frame(anchor: CGRect, visible: CGRect, preferred: CGSize) -> CGRect {
        let width = min(preferred.width, max(1, visible.width - 16))
        let height = min(preferred.height, max(1, visible.height - 16))
        let x = min(max(anchor.maxX - width, visible.minX + 8), visible.maxX - width - 8)
        let y = min(max(anchor.minY - height - 8, visible.minY + 8), visible.maxY - height - 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    static func mayPaste(ticket: UInt64, current: UInt64, copiedVersion: Int, currentVersion: Int,
                         targetPID: pid_t?, frontPID: pid_t?, panelVisible: Bool, hasKeyWindow: Bool) -> Bool {
        ticket == current && copiedVersion == currentVersion && targetPID != nil && targetPID == frontPID
            && !panelVisible && !hasKeyWindow
    }
}
