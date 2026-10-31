import SwiftUI
import UserNotifications

/// One day of notifications in the flat, newest-first list.
struct NotificationDaySection: Identifiable {
    let id: String
    let title: String
    let items: [NotificationManager.NotificationEntry]
}

final class NotificationViewModel: ObservableObject {
    /// Loaded paging window (newest first). Only this window lives in memory.
    @Published private(set) var entries: [NotificationManager.NotificationEntry] = []
    /// `entries`, or the SQL search result while a query is active.
    @Published private(set) var filteredEntries: [NotificationManager.NotificationEntry] = []
    /// Per-app totals for the sidebar (SQL `GROUP BY`, not the paging window).
    @Published private(set) var appSummaries: [NotificationRepository.AppSummary] = []
    @Published private(set) var totalCount = 0
    /// nil = all phone notifications; otherwise a package filter.
    @Published private(set) var selectedPackage: String?
    @Published var selectedIDs = Set<String>()
    @Published var searchText = ""
    @Published var bannerKeywordsText: String
    @Published var blockedKeywordsText: String
    @Published var notificationAuthorized: UNAuthorizationStatus = .notDetermined

    #if CLIPY_CORE_TESTS
    func setSnapshot(entries value: [NotificationManager.NotificationEntry],
                     apps: [NotificationRepository.AppSummary], total: Int) {
        entries = value
        filteredEntries = value
        appSummaries = apps
        totalCount = total
    }
    #endif
    private let manager = NotificationManager.shared
    private var isActive = false
    /// Tracks the last full reload so the window can refresh on (re)show when
    /// notifications arrived while it was closed. SwiftUI's `onAppear` does not
    /// fire when an NSWindow is reused (only `makeKeyAndOrderFront` runs), so
    /// we cannot rely on it as the sole data-load trigger.
    private var lastReloadAt: Date = .distantPast
    private static let refreshMinInterval: TimeInterval = 1
    private static let searchDebounce: TimeInterval = 0.25

    private var loadedCount = 0
    private var hasMore = false
    private var isLoadingMore = false
    /// Search results are capped — SQL-side search (repository.search) means
    /// the window never materializes the whole table to filter it.
    private static let searchResultCap = 500
    /// Bumped whenever the paging window resets, so an in-flight background
    /// fetch can tell its rows are stale.
    private var dataGeneration: UInt64 = 0
    private var searchDebounceWorkItem: DispatchWorkItem?

    private let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    private let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init() {
        bannerKeywordsText = NotificationManager.shared.bannerKeywords.joined(separator: ", ")
        blockedKeywordsText = NotificationManager.shared.blockedKeywords.joined(separator: ", ")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notificationsDidChange),
            name: .phoneNotificationsDidChange,
            object: nil
        )
    }

    deinit {
        searchDebounceWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func onAppear() {
        isActive = true
        reload()
        refreshAuthorization()
    }

    func onDisappear() {
        prepareForClose()
    }

    func prepareForClose() {
        isActive = false
        searchDebounceWorkItem?.cancel()
        searchDebounceWorkItem = nil
        // Release all notification data immediately to minimize memory footprint.
        entries = []
        filteredEntries = []
        appSummaries = []
        selectedIDs.removeAll()
        selectedPackage = nil
        searchText = ""
        bannerKeywordsText = ""
        loadedCount = 0
        hasMore = false
        isLoadingMore = false
        dataGeneration &+= 1
    }

    @objc private func notificationsDidChange() {
        DispatchQueue.main.async { [weak self] in
            // Only reload when the window is actually visible. After close the
            // VM may stay alive for a few minutes (WindowSession teardown delay)
            // and still receive this broadcast; reloading then would pull the
            // full notification table back into memory for nothing. The menu
            // bar count is maintained independently in NotificationManager and
            // does not depend on this reload.
            guard let self, self.isActive else { return }
            self.reload()
        }
    }

    /// Called from the window's show hook (WindowSession.update). Ensures data
    /// is fresh even when the window was closed (or reused) when notifications
    /// arrived. Throttled to avoid reloading on every focus change.
    func refreshIfStale() {
        // Must run before the throttle check: on a reused window this is the only
        // hook that fires, and leaving `isActive` false made the VM ignore every
        // subsequent change broadcast, so the list stayed frozen until the user
        // touched a filter.
        isActive = true
        guard Date().timeIntervalSince(lastReloadAt) >= Self.refreshMinInterval else { return }
        reload()
    }

    // MARK: - Data loading (paged)

    private var expectedCount: Int {
        guard let selectedPackage else { return totalCount }
        return appSummaries.first { $0.packageName == selectedPackage }?.count ?? 0
    }

    private func fetch(offset: Int) -> [NotificationManager.NotificationEntry] {
        if let selectedPackage {
            return manager.fetchPage(packageName: selectedPackage, offset: offset, limit: NotificationManager.pageSize)
        }
        return manager.fetchPage(offset: offset, limit: NotificationManager.pageSize)
    }

    func reload() {
        lastReloadAt = Date()
        isLoadingMore = false
        dataGeneration &+= 1
        loadedCount = 0
        totalCount = manager.notificationCount
        appSummaries = manager.appSummaries()
        if let selectedPackage, !appSummaries.contains(where: { $0.packageName == selectedPackage }) {
            self.selectedPackage = nil
        }
        let page = fetch(offset: 0)
        entries = page
        loadedCount = page.count
        hasMore = loadedCount < expectedCount
        recomputeFiltered()
    }

    func selectApp(_ packageName: String?) {
        guard selectedPackage != packageName || isSearching else { return }
        selectedPackage = packageName
        selectedIDs.removeAll()
        guard isActive else { return }
        reload()
    }

    func onEntryAppear(_ entry: NotificationManager.NotificationEntry) {
        guard entry.id == filteredEntries.last?.id else { return }
        loadMoreIfNeeded()
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadMoreIfNeeded() {
        guard hasMore, !isLoadingMore, !isSearching else { return }
        isLoadingMore = true
        let page = fetch(offset: loadedCount)
        if page.isEmpty {
            hasMore = false
            isLoadingMore = false
            return
        }
        entries.append(contentsOf: page)
        loadedCount += page.count
        hasMore = loadedCount < expectedCount
        isLoadingMore = false
        recomputeFiltered()
    }

    func onSearchTextChange() {
        searchDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recomputeFiltered()
        }
        searchDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchDebounce, execute: work)
    }

    private func recomputeFiltered() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            filteredEntries = entries
            ensureSelection()
            return
        }
        // SQL-side search on a background queue; the paging window (`entries`)
        // is left untouched, so clearing the query restores it without a
        // refetch. A stale result (query changed since) is simply dropped —
        // the newer debounce pass supersedes it.
        let generation = dataGeneration
        let query = trimmed
        let package = selectedPackage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = NotificationManager.shared.searchNotifications(
                query: query, limit: Self.searchResultCap)
                .filter { package == nil || $0.packageName == package }
            DispatchQueue.main.async {
                guard let self, self.isActive else { return }
                guard self.dataGeneration == generation, self.selectedPackage == package else { return }
                self.filteredEntries = found
                self.ensureSelection()
            }
        }
    }

    /// Keeps the detail column populated: drop selections that are no longer
    /// visible and fall back to the newest visible notification.
    private func ensureSelection() {
        let visible = Set(filteredEntries.map(\.id))
        let kept = selectedIDs.intersection(visible)
        if kept != selectedIDs { selectedIDs = kept }
        if selectedIDs.isEmpty, let first = filteredEntries.first { selectedIDs = [first.id] }
    }

    var daySections: [NotificationDaySection] {
        let calendar = Calendar.current
        var sections: [NotificationDaySection] = []
        var currentKey: Date?
        var bucket: [NotificationManager.NotificationEntry] = []
        func flush() {
            guard let currentKey, !bucket.isEmpty else { return }
            sections.append(.init(id: "\(currentKey.timeIntervalSince1970)", title: dayTitle(currentKey), items: bucket))
        }
        for entry in filteredEntries {
            let day = calendar.startOfDay(for: date(from: entry.postTime))
            if day != currentKey {
                flush()
                currentKey = day
                bucket = []
            }
            bucket.append(entry)
        }
        flush()
        return sections
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L10n.t(.historyDateFilterToday) }
        if calendar.isDateInYesterday(day) { return L10n.t(.notifYesterday) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: PreferencesManager.shared.appLanguage == .zh ? "zh_CN" : "en_US")
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMdEEE" : "yMMMd")
        return formatter.string(from: day)
    }

    // MARK: - Banner toggles per app

    func toggleBanner(for packageName: String) {
        if manager.bannerApps.contains(packageName) {
            manager.bannerApps.remove(packageName)
        } else {
            manager.bannerApps.insert(packageName)
        }
        manager.savePreferences()
        // bannerApps lives on the manager (not @Published), so without an
        // explicit change signal SwiftUI never re-renders the bell icon and
        // the toggle looks stuck until the next unrelated reload.
        objectWillChange.send()
    }

    func isBannerEnabled(for packageName: String) -> Bool {
        manager.bannerApps.contains(packageName)
    }

    // MARK: - Preferences (mirrored for popover binding)

    var notificationSyncEnabled: Bool {
        get { manager.notificationSyncEnabled }
        set {
            objectWillChange.send()
            manager.notificationSyncEnabled = newValue
            manager.savePreferences()
        }
    }

    var notificationSound: Bool {
        get { manager.notificationSound }
        set {
            objectWillChange.send()
            manager.notificationSound = newValue
            manager.savePreferences()
        }
    }

    func commitBannerKeywords() {
        let keywords = bannerKeywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        manager.bannerKeywords = keywords
        manager.savePreferences()
        bannerKeywordsText = keywords.joined(separator: ", ")
    }

    func commitBlockedKeywords() {
        let keywords = blockedKeywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        manager.blockedKeywords = keywords
        manager.savePreferences()
        blockedKeywordsText = keywords.joined(separator: ", ")
    }

    // MARK: - System notification authorization

    func refreshAuthorization() {
        manager.checkNotificationAuthorization { [weak self] status in
            self?.notificationAuthorized = status
        }
    }

    func openSystemNotificationSettings() {
        manager.openSystemNotificationSettings()
    }

    // MARK: - Selection

    var primarySelection: NotificationManager.NotificationEntry? {
        filteredEntries.first { selectedIDs.contains($0.id) }
    }

    /// Click = single select, ⌘-click toggles, ⇧-click extends from the anchor.
    func click(_ entry: NotificationManager.NotificationEntry, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) } else { selectedIDs.insert(entry.id) }
        } else if modifiers.contains(.shift), let anchor = primarySelection,
                  let from = filteredEntries.firstIndex(where: { $0.id == anchor.id }),
                  let to = filteredEntries.firstIndex(where: { $0.id == entry.id }) {
            selectedIDs = Set(filteredEntries[min(from, to)...max(from, to)].map(\.id))
        } else {
            selectedIDs = [entry.id]
        }
    }

    func moveSelection(by delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let current = primarySelection.flatMap { entry in filteredEntries.firstIndex { $0.id == entry.id } }
        let next = max(0, min(filteredEntries.count - 1, (current ?? -1) + delta))
        selectedIDs = [filteredEntries[next].id]
    }

    func selectedEntries() -> [NotificationManager.NotificationEntry] {
        filteredEntries.filter { selectedIDs.contains($0.id) }
    }

    func copySelected() {
        let text = selectedEntries().map { detailText(for: $0) }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func dismissSelectedOnPhone() {
        for entry in selectedEntries() {
            manager.dismissOnRemote(entry)
        }
    }

    func deleteSelected() {
        let removed = selectedEntries()
        guard !removed.isEmpty else { return }
        // Keep the reading position: select the row after the deleted block,
        // or the one before it at the end of the list.
        let removedIDs = Set(removed.map(\.id))
        let lastIndex = filteredEntries.lastIndex { removedIDs.contains($0.id) } ?? 0
        let firstIndex = filteredEntries.firstIndex { removedIDs.contains($0.id) } ?? 0
        let neighbour = filteredEntries[(lastIndex + 1)...].first { !removedIDs.contains($0.id) }
            ?? filteredEntries[..<firstIndex].last
        for entry in removed {
            manager.removeNotification(entry.id)
        }
        entries.removeAll { removedIDs.contains($0.id) }
        filteredEntries.removeAll { removedIDs.contains($0.id) }
        selectedIDs = neighbour.map { [$0.id] } ?? []
    }

    func clearLocal() {
        manager.clearAllLocal()
    }

    func clearPhone() {
        manager.clearAllOnRemote()
    }

    func exportJSON() {
        let panel = NSSavePanel()
        panel.title = "Export Notifications"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "notifications_\(exportTimestamp()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Export always reads the full table so pagination in the list UI
        // cannot silently omit older notifications from the file.
        let allEntries = manager.fetchAllNotifications()
        let jsonArray = allEntries.map { entry -> [String: Any] in
            var dict: [String: Any] = [
                "id": entry.id,
                "packageName": entry.packageName,
                "appName": entry.appName,
                "title": entry.title,
                "body": entry.body,
                "postTime": entry.postTime,
                "isClearable": entry.isClearable,
            ]
            if let key = entry.notificationKey, !key.isEmpty { dict["notificationKey"] = key }
            if let subtitle = entry.subtitle, !subtitle.isEmpty { dict["subtitle"] = subtitle }
            if let groupKey = entry.groupKey, !groupKey.isEmpty { dict["groupKey"] = groupKey }
            if let extras = entry.extras, !extras.isEmpty { dict["extras"] = extras }
            return dict
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys])
        } catch {
            appLog("Failed to serialize notifications: \(error)", level: .error)
            return
        }

        do {
            try data.write(to: url)
            appLog("Exported \(jsonArray.count) notifications to \(url.path)")
        } catch {
            appLog("Failed to write export file: \(error)", level: .error)
        }
    }

    private func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Helpers

    func formattedTime(for entry: NotificationManager.NotificationEntry) -> String {
        detailFormatter.string(from: date(from: entry.postTime))
    }

    func rowTime(for entry: NotificationManager.NotificationEntry) -> String {
        rowTimeFormatter.string(from: date(from: entry.postTime))
    }

    private func date(from timestamp: TimeInterval) -> Date {
        timestamp > 10_000_000_000
            ? Date(timeIntervalSince1970: timestamp / 1000)
            : Date(timeIntervalSince1970: timestamp)
    }

    private func detailText(for entry: NotificationManager.NotificationEntry) -> String {
        var lines = [
            "App: \(entry.appName)",
            "Package: \(entry.packageName)",
            "Title: \(entry.title)",
        ]
        if let subtitle = entry.subtitle, !subtitle.isEmpty {
            lines.append("Subtitle: \(subtitle)")
        }
        if !entry.body.isEmpty {
            lines.append("Body: \(entry.body)")
        }
        lines.append("Time: \(formattedTime(for: entry))")
        if let notificationKey = entry.notificationKey, !notificationKey.isEmpty {
            lines.append("Key: \(notificationKey)")
        }
        if let groupKey = entry.groupKey, !groupKey.isEmpty {
            lines.append("Group: \(groupKey)")
        }
        if let extras = entry.extras, !extras.isEmpty {
            lines.append("")
            lines.append("Extras:")
            for key in extras.keys.sorted() {
                if let value = extras[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("\(key): \(value)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - View

/// App monogram tile (`.mono`): first letter of the app name on a stable tint.
private struct NotificationAppAvatar: View {
    let appName: String
    let packageName: String
    var size: CGFloat = 18

    private var letter: String {
        appName.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Text(letter)
            .font(.system(size: size * (size <= 18 ? 0.58 : 0.46), weight: .semibold))
            .foregroundStyle(SplitV3Color.text2)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size / 4).fill(SplitV3Color.avatarTint(for: packageName)))
            .accessibilityHidden(true)
    }
}

struct NotificationView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: NotificationViewModel
    @ObservedObject private var notificationPopups = NotificationPopupPreference.shared
    @State private var showSettingsPopover = false

    var body: some View {
        let _ = languageObserver.revision

        HStack(spacing: 0) {
            notificationSidebar
            SplitV3Hairline(vertical: true)
            listColumn
                .frame(width: 390)
                .opacity(viewModel.notificationSyncEnabled ? 1 : 0.55)
            SplitV3Hairline(vertical: true)
            detailColumn
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SplitV3Color.content)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            #if CLIPY_CORE_TESTS
            if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return }
            #endif
            viewModel.onAppear()
        }
        .onDisappear {
            #if CLIPY_CORE_TESTS
            if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return }
            #endif
            viewModel.onDisappear()
        }
        .frame(minWidth: 900, minHeight: AppWindowSize.notificationMin.height)
    }

    // MARK: Sidebar

    private var notificationSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            MainWindowSidebarHeader()
            sidebarRow(isOn: viewModel.selectedPackage == nil, action: { viewModel.selectApp(nil) }) {
                Image(systemName: "tray").font(.system(size: 14)).foregroundStyle(AppColor.accent)
                    .frame(width: 18)
                Text(L10n.t(.phoneNotifications)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(viewModel.totalCount)").font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(SplitV3Color.text3)
            }
            Text(L10n.t(.notifSidebarApps))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(SplitV3Color.text3)
                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 5)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(viewModel.appSummaries.filter { $0.count > 0 }, id: \.packageName) { app in
                        appRow(app)
                    }
                }
            }
            SplitV3Hairline().padding(.top, 4)
            HStack(spacing: 10) {
                Image(systemName: "bell").font(.system(size: 12))
                Text(L10n.t(.enableNotificationSync)).lineLimit(1)
                Spacer(minLength: 4)
                Toggle("", isOn: $viewModel.notificationSyncEnabled)
                    .labelsHidden().toggleStyle(SplitV3SwitchStyle())
                    .accessibilityLabel(L10n.t(.enableNotificationSync))
            }
            .font(.system(size: 12)).foregroundStyle(SplitV3Color.text2)
            .padding(10)
            MainWindowSidebarFooter().padding(.bottom, 10)
        }
        .padding(.horizontal, 10).padding(.bottom, 0)
        .frame(width: MainWindowMetrics.sidebarWidth).frame(maxHeight: .infinity, alignment: .top)
        .background(SplitV3Color.sidebar)
    }

    private func appRow(_ app: NotificationRepository.AppSummary) -> some View {
        let bannerOn = viewModel.isBannerEnabled(for: app.packageName)
        return sidebarRow(isOn: viewModel.selectedPackage == app.packageName,
                          action: { viewModel.selectApp(app.packageName) }) {
            NotificationAppAvatar(appName: app.appName, packageName: app.packageName)
            Text(app.appName).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button { viewModel.toggleBanner(for: app.packageName) } label: {
                Image(systemName: bannerOn ? "bell.badge" : "bell.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(bannerOn ? AppColor.accent : SplitV3Color.text3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t(bannerOn ? .notifBannerOn : .notifBannerOff))
            .accessibilityLabel(L10n.t(bannerOn ? .notifBannerOn : .notifBannerOff))
            SplitV3CountPill(count: app.count)
        }
    }

    private func sidebarRow<Content: View>(isOn: Bool, action: @escaping () -> Void,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) { content() }
            .font(.system(size: 13, weight: isOn ? .medium : .regular))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? SplitV3Color.fill2 : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            SplitV3Toolbar(leading: 14, trailing: 14) {
                SplitV3SearchField(placeholder: L10n.t(.searchApps), text: $viewModel.searchText) {
                    viewModel.onSearchTextChange()
                }
                Button(action: viewModel.exportJSON) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(SplitV3IconButtonStyle())
                    .help(L10n.t(.exportAction)).accessibilityLabel(L10n.t(.exportAction))
                Button { showSettingsPopover.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(SplitV3IconButtonStyle())
                    .help(L10n.t(.notificationSettings)).accessibilityLabel(L10n.t(.notificationSettings))
                    .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) { settingsPopover }
                Menu {
                    Button(permissionLabel, action: viewModel.openSystemNotificationSettings)
                    Divider()
                    Button(L10n.t(.clearNotifications), role: .destructive, action: confirmClearLocal)
                    Button(L10n.t(.clearAllOnPhone), role: .destructive, action: confirmClearPhone)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(SplitV3Color.text2)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 28, height: 28)
                .help(L10n.t(.notifMore)).accessibilityLabel(L10n.t(.notifMore))
            }
            notificationList
        }
        .background(SplitV3Color.content)
    }

    @ViewBuilder
    private var notificationList: some View {
        let sections = viewModel.daySections
        if sections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bell").font(.system(size: 34, weight: .light))
                Text(L10n.t(viewModel.totalCount == 0 ? .noNotifications : .noSearchResults))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.primary)
            }
            .foregroundStyle(SplitV3Color.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(SplitV3Color.text3)
                                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 6)
                            ForEach(section.items, id: \.id) { entry in
                                notificationRow(entry).id(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .modifier(NotificationListKeyboard(viewModel: viewModel, onMove: { id in
                    proxy.scrollTo(id)
                }))
            }
        }
    }

    private func notificationRow(_ entry: NotificationManager.NotificationEntry) -> some View {
        let selected = viewModel.selectedIDs.contains(entry.id)
        return HStack(alignment: .top, spacing: 11) {
            NotificationAppAvatar(appName: entry.appName, packageName: entry.packageName, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title.isEmpty ? entry.appName : entry.title)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if entry.isArchived {
                        Text(L10n.t(.notificationArchivedBadge))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.orange)
                    }
                    Spacer(minLength: 4)
                    Text(viewModel.rowTime(for: entry)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(SplitV3Color.text3)
                }
                if !rowBody(entry).isEmpty {
                    Text(rowBody(entry))
                        .font(.system(size: 12.5)).foregroundStyle(SplitV3Color.text2)
                        .lineSpacing(2).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if viewModel.selectedPackage == nil {
                    Text(entry.appName).font(.system(size: 11)).foregroundStyle(SplitV3Color.text3)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11).fill(selected ? SplitV3Color.selection : .clear))
        .contentShape(Rectangle())
        .onTapGesture { viewModel.click(entry, modifiers: NSEvent.modifierFlags) }
        .contextMenu {
            Button(L10n.t(.copyContent)) { selectForMenu(entry); viewModel.copySelected() }
            Button(L10n.t(.dismissOnPhone)) { selectForMenu(entry); viewModel.dismissSelectedOnPhone() }
            Divider()
            Button(L10n.t(.delete), role: .destructive) { selectForMenu(entry); viewModel.deleteSelected() }
        }
        .onAppear { viewModel.onEntryAppear(entry) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func rowBody(_ entry: NotificationManager.NotificationEntry) -> String {
        [entry.subtitle, entry.body].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func selectForMenu(_ entry: NotificationManager.NotificationEntry) {
        if !viewModel.selectedIDs.contains(entry.id) { viewModel.selectedIDs = [entry.id] }
    }

    // MARK: Detail column

    @ViewBuilder
    private var detailColumn: some View {
        let entry = viewModel.primarySelection
        VStack(alignment: .leading, spacing: 0) {
            SplitV3Toolbar(leading: 26, trailing: 14, transparent: true) {
                HStack(spacing: 6) {
                    Image(systemName: "iphone").font(.system(size: 11))
                    Text(L10n.t(.phoneNotifications))
                }
                .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
                Spacer(minLength: 0)
                Button(action: viewModel.copySelected) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(SplitV3IconButtonStyle())
                    .help(L10n.t(.copyContent)).accessibilityLabel(L10n.t(.copyContent))
                    .disabled(entry == nil)
                Button(action: viewModel.deleteSelected) { Image(systemName: "trash") }
                    .buttonStyle(SplitV3IconButtonStyle())
                    .help(L10n.t(.delete)).accessibilityLabel(L10n.t(.delete))
                    .disabled(entry == nil)
            }
            if let entry {
                ScrollView { detailBody(entry) }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "bell").font(.system(size: 34, weight: .light))
                    Text(L10n.t(.noNotifications)).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .foregroundStyle(SplitV3Color.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SplitV3Color.inspector)
    }

    private func detailBody(_ entry: NotificationManager.NotificationEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    NotificationAppAvatar(appName: entry.appName, packageName: entry.packageName, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.isEmpty ? entry.appName : entry.title)
                            .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                            .textSelection(.enabled)
                        Text("\(entry.appName) · \(viewModel.formattedTime(for: entry))")
                            .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if entry.isArchived {
                        Text(L10n.t(.notificationArchivedBadge))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.orange)
                    }
                }
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(SplitV3Color.text2)
                        .textSelection(.enabled)
                        .padding(.top, 14)
                }
                if !entry.body.isEmpty {
                    Text(entry.body).font(.system(size: 14)).lineSpacing(7)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(SplitV3Color.card)
                    .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SplitV3Color.line, lineWidth: 0.5))
            .padding(.top, 6)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                detailRow(L10n.t(.notifDetailApp), "\(entry.appName)（\(entry.packageName)）")
                detailRow(L10n.t(.notifDetailTime), viewModel.formattedTime(for: entry))
                detailRow(L10n.t(.notifDetailPhone), L10n.t(entry.isClearable ? .notifClearable : .notifOngoing))
            }
            .font(.system(size: 12.5))
            .padding(.top, 18)

            HStack(spacing: 8) {
                Button(action: viewModel.copySelected) { Label(L10n.t(.copyContent), systemImage: "doc.on.doc") }
                    .buttonStyle(SplitV3ButtonStyle())
                Button(action: viewModel.dismissSelectedOnPhone) {
                    Label(L10n.t(.dismissOnPhone), systemImage: "iphone")
                }
                .buttonStyle(SplitV3ButtonStyle())
                .opacity(entry.isClearable ? 1 : 0.5)
                Spacer(minLength: 0)
                Button(action: viewModel.deleteSelected) { Label(L10n.t(.delete), systemImage: "trash") }
                    .buttonStyle(SplitV3ButtonStyle(kind: .danger))
            }
            .padding(.vertical, 18)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11)).padding(.top, 1)
                Text(L10n.t(.notifActionHint)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
        }
        .padding(.horizontal, 26).padding(.bottom, 20)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(SplitV3Color.text3).frame(width: 90, alignment: .leading)
            Text(value).fontWeight(.medium).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Toolbar menu + popover

    private var permissionLabel: String {
        switch viewModel.notificationAuthorized {
        case .authorized: return L10n.t(.macNotificationGranted)
        case .denied: return L10n.t(.macNotificationDenied)
        default: return L10n.t(.openNotificationSettings)
        }
    }

    private func confirm(title: String, message: String, button: String, action: () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let ok = alert.addButton(withTitle: button)
        ok.hasDestructiveAction = true
        alert.addButton(withTitle: L10n.t(.cancel))
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }

    private func confirmClearLocal() {
        confirm(title: L10n.t(.notifClearLocalTitle),
                message: L10n.format(.notifClearLocalMessage, viewModel.totalCount),
                button: L10n.t(.notifClearLocalConfirm), action: viewModel.clearLocal)
    }

    private func confirmClearPhone() {
        confirm(title: L10n.t(.notifClearPhoneTitle), message: L10n.t(.notifClearPhoneMessage),
                button: L10n.t(.notifClearPhoneConfirm), action: viewModel.clearPhone)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverToggle(L10n.t(.notificationPopups), isOn: Binding(
                get: { notificationPopups.enabled },
                set: { notificationPopups.setEnabled($0) }))
            popoverNote(L10n.t(.notificationPopupsHint))
            popoverToggle(L10n.t(.enableNotificationSync), isOn: $viewModel.notificationSyncEnabled)
            popoverToggle(L10n.t(.notificationSound), isOn: $viewModel.notificationSound)
            SplitV3Hairline().padding(.vertical, 10)
            Text(L10n.t(.bannerKeywords)).fontWeight(.medium).padding(.top, 8).padding(.bottom, 5)
            TextField(L10n.t(.bannerKeywords), text: $viewModel.bannerKeywordsText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.commitBannerKeywords() }
            popoverNote(L10n.t(.bannerKeywordsHint))
            Text(L10n.t(.blockedKeywords)).fontWeight(.medium).padding(.top, 8).padding(.bottom, 5)
            TextField(L10n.t(.blockedKeywords), text: $viewModel.blockedKeywordsText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.commitBlockedKeywords() }
            popoverNote(L10n.t(.blockedKeywordsHint))
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 280)
    }

    private func popoverToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(SplitV3SwitchStyle())
                .accessibilityLabel(title)
        }
        .frame(minHeight: 28)
    }

    private func popoverNote(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(SplitV3Color.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2).padding(.bottom, 6)
    }
}

/// Arrow-key navigation and ⌫ delete for the hand-drawn list (macOS 13
/// `focusable` draws a focus ring, so it is only enabled where it can be hidden).
private struct NotificationListKeyboard: ViewModifier {
    @ObservedObject var viewModel: NotificationViewModel
    let onMove: (String) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    switch direction {
                    case .up: viewModel.moveSelection(by: -1)
                    case .down: viewModel.moveSelection(by: 1)
                    default: return
                    }
                    if let id = viewModel.primarySelection?.id { onMove(id) }
                }
                .onDeleteCommand { viewModel.deleteSelected() }
        } else {
            content
        }
    }
}
