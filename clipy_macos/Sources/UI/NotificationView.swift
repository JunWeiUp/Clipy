import SwiftUI
import UserNotifications

struct NotificationGroup: Identifiable {
    let id: String
    let packageName: String
    let appName: String
    var items: [NotificationManager.NotificationEntry]
}

final class NotificationViewModel: ObservableObject {
    @Published var groups: [NotificationGroup] = []
    @Published private(set) var filteredGroups: [NotificationGroup] = []
    @Published var expandedPackages = Set<String>()
    @Published var selectedIDs = Set<String>()
    @Published var searchText = ""
    @Published var bannerKeywordsText: String
    @Published var blockedKeywordsText: String
    @Published var notificationAuthorized: UNAuthorizationStatus = .notDetermined

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
    private var isLoadingAllForSearch = false
    /// Bumped whenever the paging window resets, so an in-flight background
    /// fetch can tell its rows are stale.
    private var dataGeneration: UInt64 = 0
    private var searchDebounceWorkItem: DispatchWorkItem?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
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
        groups = []
        filteredGroups = []
        expandedPackages.removeAll()
        selectedIDs.removeAll()
        searchText = ""
        bannerKeywordsText = ""
        loadedCount = 0
        hasMore = false
        isLoadingMore = false
        isLoadingAllForSearch = false
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

    var statusText: String {
        let count = manager.notificationCount
        return count == 0 ? L10n.t(.noNotifications) : "\(L10n.t(.phoneNotifications)): \(count)"
    }

    // MARK: - Data loading (paged)

    func reload() {
        lastReloadAt = Date()
        isLoadingMore = false
        isLoadingAllForSearch = false
        dataGeneration &+= 1
        loadedCount = 0
        let page = manager.fetchPage(offset: 0, limit: NotificationManager.pageSize)
        groups = Self.buildGroups(from: page)
        loadedCount = page.count
        hasMore = loadedCount < manager.notificationCount
        recomputeFilteredGroups()
    }

    func onGroupRowAppear(_ group: NotificationGroup) {
        guard group.id == filteredGroups.last?.id else { return }
        loadMoreIfNeeded()
    }

    private func loadMoreIfNeeded() {
        guard hasMore, !isLoadingMore else { return }
        // While searching, ensureFullyLoaded already pulled the rest if needed.
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return }

        isLoadingMore = true
        let page = manager.fetchPage(offset: loadedCount, limit: NotificationManager.pageSize)
        if page.isEmpty {
            hasMore = false
            isLoadingMore = false
            return
        }
        appendEntries(page)
        loadedCount += page.count
        hasMore = loadedCount < manager.notificationCount
        isLoadingMore = false
        recomputeFilteredGroups()
    }

    private func appendEntries(_ entries: [NotificationManager.NotificationEntry]) {
        var grouped = Dictionary(uniqueKeysWithValues: groups.map { ($0.packageName, $0) })
        var order = groups.map(\.packageName)
        for entry in entries {
            if grouped[entry.packageName] == nil {
                order.append(entry.packageName)
                grouped[entry.packageName] = NotificationGroup(
                    id: entry.packageName,
                    packageName: entry.packageName,
                    appName: entry.appName,
                    items: []
                )
            }
            grouped[entry.packageName]!.items.append(entry)
        }
        groups = order.compactMap { grouped[$0] }
    }

    private static func buildGroups(from entries: [NotificationManager.NotificationEntry]) -> [NotificationGroup] {
        var grouped: [String: NotificationGroup] = [:]
        var order: [String] = []
        for entry in entries {
            if grouped[entry.packageName] == nil {
                order.append(entry.packageName)
                grouped[entry.packageName] = NotificationGroup(
                    id: entry.packageName,
                    packageName: entry.packageName,
                    appName: entry.appName,
                    items: []
                )
            }
            grouped[entry.packageName]!.items.append(entry)
        }
        return order.compactMap { grouped[$0] }
    }

    func onSearchTextChange() {
        searchDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recomputeFilteredGroups()
        }
        searchDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchDebounce, execute: work)
    }

    private func recomputeFilteredGroups() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            filteredGroups = groups
            return
        }
        // Show matches among the loaded pages right away, then widen the result
        // once the rest of the table arrives.
        filteredGroups = Self.filterGroups(groups, matching: trimmed)
        loadRemainingForSearch()
    }

    /// Search has to see rows beyond the loaded pages. Reading them is SQLite IO
    /// proportional to the whole table, so it runs off the main thread and the
    /// filter is recomputed when the rows land.
    private func loadRemainingForSearch() {
        guard hasMore, !isLoadingAllForSearch else { return }
        isLoadingAllForSearch = true
        let generation = dataGeneration
        let startOffset = loadedCount
        let pageSize = NotificationManager.pageSize
        let manager = self.manager
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var collected: [NotificationManager.NotificationEntry] = []
            var offset = startOffset
            while true {
                let page = manager.fetchPage(offset: offset, limit: pageSize)
                collected.append(contentsOf: page)
                offset += page.count
                if page.count < pageSize { break }
            }
            DispatchQueue.main.async {
                guard let self, self.isActive else { return }
                self.isLoadingAllForSearch = false
                // A reload while we were fetching reset the paging window; these
                // rows would append at the wrong offset and duplicate.
                guard self.dataGeneration == generation else {
                    self.recomputeFilteredGroups()
                    return
                }
                if !collected.isEmpty {
                    self.appendEntries(collected)
                    self.loadedCount += collected.count
                }
                self.hasMore = false
                let trimmed = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.filteredGroups = trimmed.isEmpty
                    ? self.groups
                    : Self.filterGroups(self.groups, matching: trimmed)
            }
        }
    }

    private static func filterGroups(_ groups: [NotificationGroup], matching trimmed: String) -> [NotificationGroup] {
        groups.compactMap { group -> NotificationGroup? in
            // App/package match keeps the whole group; otherwise filter down to
            // only entries whose content (title/subtitle/body) matches the query.
            if group.appName.localizedCaseInsensitiveContains(trimmed) ||
                group.packageName.localizedCaseInsensitiveContains(trimmed) {
                return group
            }
            let matched = group.items.filter { entry in
                entry.title.localizedCaseInsensitiveContains(trimmed) ||
                entry.body.localizedCaseInsensitiveContains(trimmed) ||
                (entry.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
            guard !matched.isEmpty else { return nil }
            return NotificationGroup(
                id: group.id,
                packageName: group.packageName,
                appName: group.appName,
                items: matched
            )
        }
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
        set { manager.notificationSyncEnabled = newValue; manager.savePreferences() }
    }

    var notificationSound: Bool {
        get { manager.notificationSound }
        set { manager.notificationSound = newValue; manager.savePreferences() }
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

    // MARK: - Helpers

    func formattedTime(for entry: NotificationManager.NotificationEntry) -> String {
        dateFormatter.string(from: date(from: entry.postTime))
    }

    func latestTime(for group: NotificationGroup) -> String {
        guard let latest = group.items.first else { return "" }
        return formattedTime(for: latest)
    }

    func selectedEntries() -> [NotificationManager.NotificationEntry] {
        var result: [NotificationManager.NotificationEntry] = []
        for group in groups {
            if selectedIDs.contains(group.packageName) {
                result.append(contentsOf: group.items)
            }
            for item in group.items where selectedIDs.contains(item.id) {
                result.append(item)
            }
        }
        return result
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
        for entry in selectedEntries() {
            manager.removeNotification(entry.id)
        }
        selectedIDs.removeAll()
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

struct NotificationView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: NotificationViewModel
    @State private var showSettingsPopover = false

    var body: some View {
        let _ = languageObserver.revision

        AppListWindowLayout(statusText: viewModel.statusText) {
            NotificationToolbar(viewModel: viewModel, showSettingsPopover: $showSettingsPopover)
        } content: {
            VStack(spacing: 0) {
                searchField
                Divider()
                notificationList
            }
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .frame(minWidth: AppWindowSize.notificationMin.width, minHeight: AppWindowSize.notificationMin.height)
    }

    private var searchField: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.t(.searchApps), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .onChange(of: viewModel.searchText) { _ in
                    viewModel.onSearchTextChange()
                }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
    }

    private var notificationList: some View {
        let displayedGroups = viewModel.filteredGroups
        return ZStack {
            if displayedGroups.isEmpty {
                EmptyStateView(message: viewModel.groups.isEmpty ? L10n.t(.noNotifications) : L10n.t(.noSearchResults))
            } else {
                List(selection: $viewModel.selectedIDs) {
                    ForEach(displayedGroups) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { viewModel.expandedPackages.contains(group.packageName) },
                                set: { expanded in
                                    if expanded {
                                        viewModel.expandedPackages.insert(group.packageName)
                                    } else {
                                        viewModel.expandedPackages.remove(group.packageName)
                                    }
                                }
                            )
                        ) {
                            ForEach(group.items, id: \.id) { entry in
                                notificationDetailRow(entry)
                                    .tag(entry.id)
                                    .contextMenu {
                                        notificationContextMenu()
                                    }
                            }
                        } label: {
                            groupLabel(group)
                        }
                        .onAppear {
                            viewModel.onGroupRowAppear(group)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func groupLabel(_ group: NotificationGroup) -> some View {
        HStack {
            Text(group.appName)
                .font(AppFont.body.weight(.semibold))
            Spacer()
            Button(action: { viewModel.toggleBanner(for: group.packageName) }) {
                Image(systemName: viewModel.isBannerEnabled(for: group.packageName) ? "bell.badge.fill" : "bell.slash")
                    .foregroundStyle(viewModel.isBannerEnabled(for: group.packageName) ? AppColor.accent : .secondary)
            }
            .buttonStyle(.borderless)
            CountBadge(count: group.items.count)
            Text(viewModel.latestTime(for: group))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: AppRowHeight.group)
        .tag(group.packageName)
        .contextMenu {
            notificationContextMenu()
        }
    }

    @ViewBuilder
    private func notificationDetailRow(_ entry: NotificationManager.NotificationEntry) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(AppFont.body)
                    .lineLimit(1)
                if entry.isArchived {
                    Text(L10n.t(.notificationArchivedBadge))
                        .font(AppFont.caption)
                        .foregroundStyle(.orange)
                }
                Text(entry.body)
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(viewModel.formattedTime(for: entry))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: AppRowHeight.standard)
    }

    @ViewBuilder
    private func notificationContextMenu() -> some View {
        Button(L10n.t(.copyContent)) { viewModel.copySelected() }
        Button(L10n.t(.dismissOnPhone)) { viewModel.dismissSelectedOnPhone() }
        Divider()
        Button(L10n.t(.delete), role: .destructive) { viewModel.deleteSelected() }
    }
}

// MARK: - Toolbar

private struct NotificationToolbar: View {
    @ObservedObject var viewModel: NotificationViewModel
    @Binding var showSettingsPopover: Bool

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            toolbarButton(title: L10n.t(.clearNotifications), systemImage: "trash", action: viewModel.clearLocal)
            toolbarButton(title: L10n.t(.clearAllOnPhone), systemImage: "iphone.and.arrow.forward", action: viewModel.clearPhone)
            Spacer(minLength: 0)
            toolbarButton(title: L10n.t(.notificationSettings), systemImage: "gearshape") {
                showSettingsPopover = true
            }
            .popover(isPresented: $showSettingsPopover, arrowEdge: .top) {
                settingsPopover
            }
            toolbarButton(
                title: permissionLabel,
                systemImage: permissionIcon
            ) {
                viewModel.openSystemNotificationSettings()
            }
            toolbarButton(title: L10n.t(.copyContent), systemImage: "doc.on.doc", action: viewModel.copySelected)
            toolbarButton(title: "Export JSON", systemImage: "square.and.arrow.up", action: viewModel.exportJSON)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.top, AppTitleBar.height)
        .padding(.bottom, AppSpacing.xs)
        .background(.thinMaterial)
    }

    private var permissionLabel: String {
        switch viewModel.notificationAuthorized {
        case .authorized: return L10n.t(.macNotificationGranted)
        case .denied: return L10n.t(.macNotificationDenied)
        default: return L10n.t(.openNotificationSettings)
        }
    }

    private var permissionIcon: String {
        switch viewModel.notificationAuthorized {
        case .authorized: return "bell.badge.fill"
        default: return "bell.slash"
        }
    }

    @ViewBuilder
    private func toolbarButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Toggle(L10n.t(.enableNotificationSync), isOn: $viewModel.notificationSyncEnabled)
            Toggle(L10n.t(.notificationSound), isOn: $viewModel.notificationSound)

            Divider()

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(L10n.t(.bannerKeywords))
                    .font(AppFont.body.weight(.medium))
                TextField(L10n.t(.bannerKeywords), text: $viewModel.bannerKeywordsText)
                    .onSubmit {
                        viewModel.commitBannerKeywords()
                    }
                Text(L10n.t(.bannerKeywordsHint))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(L10n.t(.blockedKeywords))
                    .font(AppFont.body.weight(.medium))
                TextField(L10n.t(.blockedKeywords), text: $viewModel.blockedKeywordsText)
                    .onSubmit {
                        viewModel.commitBlockedKeywords()
                    }
                Text(L10n.t(.blockedKeywordsHint))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppSpacing.md)
        .frame(width: 280)
    }
}
