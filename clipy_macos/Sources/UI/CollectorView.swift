import SwiftUI

final class CollectorViewModel: ObservableObject {
    @Published private(set) var displayedEvents: [CollectorEvent] = []
    @Published var selectedCategory: CollectorCategory? = nil
    @Published var searchQuery: String = ""

    private let manager = DeviceCollectorManager.shared
    private let pageSize = 200
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
            selector: #selector(eventsDidChange),
            name: .deviceCollectorEventsDidChange,
            object: nil
        )
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
        displayedEvents = []
        loadedOffset = 0
        isLoadingMore = false
    }

    @objc private func eventsDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.reload()
        }
    }

    var statusText: String {
        let total = manager.eventCount
        if total == 0 {
            return L10n.t(.noCollectorEvents)
        }
        if displayedEvents.count < total {
            return L10n.format(.collectorEventCount, total) + " (\(displayedEvents.count))"
        }
        return L10n.format(.collectorEventCount, total)
    }

    var canLoadMore: Bool {
        displayedEvents.count < manager.eventCount
    }

    func reload() {
        displayedEvents = []
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
        let page = manager.searchEvents(
            query: searchQuery,
            category: selectedCategory,
            offset: loadedOffset,
            limit: pageSize
        )
        loadedOffset += page.count
        displayedEvents.append(contentsOf: page)
        isLoadingMore = false
    }

    func formattedTime(for event: CollectorEvent) -> String {
        let seconds = event.timestamp > 10_000_000_000 ? event.timestamp / 1000 : event.timestamp
        return dateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    func title(for event: CollectorEvent) -> String {
        switch event.collectorCategory {
        case .notification:
            return event.payload["title"] ?? event.payload["appName"] ?? L10n.t(.collectorCategoryNotification)
        case .sms:
            return event.payload["address"] ?? L10n.t(.collectorCategorySms)
        case .call, .callLog:
            return event.payload["phoneNumber"] ?? L10n.t(.collectorCategoryCall)
        case .clipboard:
            return L10n.t(.collectorCategoryClipboard)
        case .location:
            return L10n.t(.collectorCategoryLocation)
        case .system:
            return L10n.t(.collectorCategorySystem)
        case .none:
            return event.category
        }
    }

    func subtitle(for event: CollectorEvent) -> String {
        switch event.collectorCategory {
        case .notification:
            return event.payload["body"] ?? event.payload["subtitle"] ?? ""
        case .sms:
            return event.payload["body"] ?? ""
        case .call:
            let state = event.payload["state"] ?? ""
            let direction = event.payload["direction"] ?? ""
            return "\(direction) · \(state)"
        case .callLog:
            let type = event.payload["type"] ?? ""
            let duration = event.payload["duration"] ?? "0"
            return "\(type) · \(duration)s"
        case .clipboard:
            let text = event.payload["text"] ?? ""
            return String(text.prefix(200))
        case .location:
            let lat = event.payload["latitude"] ?? ""
            let lon = event.payload["longitude"] ?? ""
            return "\(lat), \(lon)"
        case .system:
            let battery = event.payload["batteryLevel"] ?? ""
            let network = event.payload["networkType"] ?? ""
            return "\(battery)% · \(network)"
        case .none:
            return event.payload.map { "\($0.key): \($0.value)" }.joined(separator: " · ")
        }
    }

    func categoryLabel(for event: CollectorEvent) -> String {
        guard let category = event.collectorCategory else { return event.category }
        return L10n.t(category.displayNameKey)
    }

    func copyEvent(_ event: CollectorEvent) {
        let text: String
        switch event.collectorCategory {
        case .clipboard:
            text = event.payload["text"] ?? subtitle(for: event)
        default:
            text = "\(title(for: event))\n\(subtitle(for: event))"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func dismissNotificationOnPhone(_ event: CollectorEvent) {
        guard event.collectorCategory == .notification else { return }
        let request = NotificationManager.NotificationDismissRequest(
            packageName: event.payload["packageName"] ?? "",
            groupKey: event.payload["groupKey"],
            notificationKey: event.payload["notificationKey"]
        )
        guard let content = try? JSONEncoder().encode(request),
              let json = String(data: content, encoding: .utf8) else { return }
        SyncManager.shared.broadcastNotificationMessage(type: "notification/dismiss", content: json, hash: "")
    }
}

struct CollectorView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: CollectorViewModel

    var body: some View {
        let _ = languageObserver.revision

        AppListWindowLayout(statusText: viewModel.statusText) {
            VStack(spacing: AppSpacing.xs) {
                AppToolbar(
                    leading: [
                        AppToolbarButton(title: L10n.t(.clear), systemImage: "trash") {
                            DeviceCollectorManager.shared.clearAll()
                            viewModel.reload()
                        },
                    ],
                    trailing: []
                )

                HStack(spacing: AppSpacing.xs) {
                    Picker("", selection: $viewModel.selectedCategory) {
                        Text(L10n.t(.collectorFilterAll)).tag(CollectorCategory?.none)
                        ForEach(CollectorCategory.allCases, id: \.self) { category in
                            Text(L10n.t(category.displayNameKey)).tag(Optional(category))
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField(L10n.t(.collectorSearchPlaceholder), text: $viewModel.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.bottom, AppSpacing.xs)
            }
        } content: {
            if viewModel.displayedEvents.isEmpty {
                EmptyStateView(message: L10n.t(.noCollectorEvents))
            } else {
                List {
                    ForEach(viewModel.displayedEvents) { event in
                        CollectorEventRow(event: event, viewModel: viewModel)
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
                .listStyle(.plain)
            }
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .onChange(of: viewModel.searchQuery) { _ in
            viewModel.reload()
        }
        .onChange(of: viewModel.selectedCategory) { _ in
            viewModel.reload()
        }
    }
}

private struct CollectorEventRow: View {
    let event: CollectorEvent
    @ObservedObject var viewModel: CollectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Text(viewModel.categoryLabel(for: event))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.formattedTime(for: event))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.title(for: event))
                .font(AppFont.body)
                .lineLimit(2)

            if !viewModel.subtitle(for: event).isEmpty {
                Text(viewModel.subtitle(for: event))
                    .font(AppFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                Text(event.deviceId)
                    .font(AppFont.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button(L10n.t(.copy)) {
                    viewModel.copyEvent(event)
                }
                .buttonStyle(.borderless)

                if event.collectorCategory == .notification {
                    Button(L10n.t(.dismissOnPhone)) {
                        viewModel.dismissNotificationOnPhone(event)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }
}
