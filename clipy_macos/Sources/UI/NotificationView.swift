import SwiftUI

struct NotificationGroup: Identifiable {
    let id: String
    let packageName: String
    let appName: String
    let items: [NotificationManager.NotificationEntry]
}

final class NotificationViewModel: ObservableObject {
    @Published var groups: [NotificationGroup] = []
    @Published var expandedPackages = Set<String>()
    @Published var selectedIDs = Set<String>()

    private let manager = NotificationManager.shared
    private let pageSize = NotificationManager.pageSize
    private var loadedEntries: [NotificationManager.NotificationEntry] = []
    private var loadedOffset = 0
    private var isLoadingMore = false
    private var isActive = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notificationsDidChange),
            name: .phoneNotificationsDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func onAppear() {
        isActive = true
        reload()
    }

    func onDisappear() {
        prepareForClose()
    }

    func prepareForClose() {
        isActive = false
        loadedEntries = []
        loadedOffset = 0
        isLoadingMore = false
        groups = []
        expandedPackages.removeAll()
        selectedIDs.removeAll()
    }

    @objc private func notificationsDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.reload()
        }
    }

    var statusText: String {
        let count = manager.notificationCount
        return count == 0 ? L10n.t(.noNotifications) : "\(L10n.t(.phoneNotifications)): \(count)"
    }

    var canLoadMore: Bool {
        loadedEntries.count < manager.notificationCount
    }

    func reload() {
        loadedEntries = []
        loadedOffset = 0
        isLoadingMore = false
        loadNextPage()
    }

    func loadMoreIfNeeded() {
        guard canLoadMore, !isLoadingMore else { return }
        loadNextPage()
    }

    private func loadNextPage() {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        let page = manager.fetchPage(offset: loadedOffset, limit: pageSize)
        loadedOffset += page.count
        loadedEntries.append(contentsOf: page)
        rebuildGroups()
        isLoadingMore = false
    }

    private func rebuildGroups() {
        var grouped: [String: NotificationGroup] = [:]
        var order: [String] = []

        for entry in loadedEntries {
            if grouped[entry.packageName] == nil {
                order.append(entry.packageName)
                grouped[entry.packageName] = NotificationGroup(
                    id: entry.packageName,
                    packageName: entry.packageName,
                    appName: entry.appName,
                    items: []
                )
            }
            var group = grouped[entry.packageName]!
            group = NotificationGroup(
                id: group.id,
                packageName: group.packageName,
                appName: group.appName,
                items: group.items + [entry]
            )
            grouped[entry.packageName] = group
        }

        groups = order.compactMap { grouped[$0] }
    }

    func toggleGroup(_ packageName: String) {
        if expandedPackages.contains(packageName) {
            expandedPackages.remove(packageName)
        } else {
            expandedPackages.insert(packageName)
        }
    }

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

    var body: some View {
        let _ = languageObserver.revision

        AppListWindowLayout(statusText: viewModel.statusText) {
            AppToolbar(
                leading: [
                    AppToolbarButton(title: L10n.t(.clearNotifications), systemImage: "trash", action: viewModel.clearLocal),
                    AppToolbarButton(title: L10n.t(.clearAllOnPhone), systemImage: "iphone.and.arrow.forward", action: viewModel.clearPhone),
                ],
                trailing: [
                    AppToolbarButton(title: L10n.t(.copyContent), systemImage: "doc.on.doc", action: viewModel.copySelected),
                ]
            )
        } content: {
            ZStack {
                if viewModel.groups.isEmpty {
                    EmptyStateView(message: L10n.t(.noNotifications))
                } else {
                    List(selection: $viewModel.selectedIDs) {
                        ForEach(viewModel.groups) { group in
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
                                HStack {
                                    Text(group.appName)
                                        .font(AppFont.body.weight(.semibold))
                                    Spacer()
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
                        }

                        if viewModel.canLoadMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                            .onAppear {
                                viewModel.loadMoreIfNeeded()
                            }
                        }
                    }
                }
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

    @ViewBuilder
    private func notificationDetailRow(_ entry: NotificationManager.NotificationEntry) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(AppFont.body)
                    .lineLimit(1)
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
