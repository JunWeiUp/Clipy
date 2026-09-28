import AppKit
import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var model: MenuBarPanelModel
    @ObservedObject var overflow: MenuBarOverflowManager
    @EnvironmentObject private var language: AppLanguageObserver
    var activateIcon: (MenuBarOverflowItem) -> Void

    var body: some View {
        let _ = language.revision
        VStack(spacing: 0) {
            topBar.padding(.bottom, 12)
            overflowStrip.padding(.bottom, 12)
            if model.page == .home && !model.isSearching {
                TokenUsagePanelSummary(manager: .shared) { model.onAction?(.tokenUsage) }
                    .padding(.bottom, 12)
            }
            tabs.padding(.bottom, 10)
            // The builder emits a detail header AND its body. Frame the stack,
            // not each emitted child, or the header consumes half the free height.
            VStack(spacing: 0) {
                content
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer.padding(.vertical, 12)
        }
        .padding(.horizontal, 16).padding(.top, 18)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large))
        .overlay(RoundedRectangle(cornerRadius: AppCornerRadius.large).strokeBorder(Color.primary.opacity(0.10)))
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice).font(AppFont.secondary).padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20).padding(.bottom, 65)
                    .allowsHitTesting(false)
            }
        }
        .font(AppFont.body).tint(AppColor.accent)
    }
    private var topBar: some View {
        HStack(spacing: 10) {
            search.frame(maxWidth: .infinity)
            iconButton(model.pinned ? .panelUnpin : .panelPin, symbol: model.pinned ? "pin.fill" : "pin") { model.pinned.toggle() }
                .foregroundStyle(model.pinned ? AppColor.accent : Color.primary)
            iconButton(.preferences, symbol: "gearshape") { model.navigate(model.page == .settings ? .home : .settings) }
        }
    }
    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 17))
            MenuBarPanelSearchField(model: model)
            if model.isSearching { iconButton(.clear, symbol: "xmark.circle.fill") { model.query = "" } }
            else { Text("⌘ F").font(AppFont.secondary).foregroundStyle(.secondary).padding(4).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4)) }
        }.padding(.horizontal, 12).frame(height: 42)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
    }
    private var overflowStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t(.overflowTitle)).font(AppFont.caption).foregroundStyle(.secondary)
                Spacer()
                if overflow.status == .loading || overflow.status == .activating { ProgressView().controlSize(.small) }
            }
            if !overflow.items.isEmpty && overflow.enabled {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(overflow.items, id: \.id) { item in
                            Button { activateIcon(item) } label: {
                                HStack(spacing: 7) {
                                    if let image = item.image { Image(nsImage: image).resizable().scaledToFit().frame(width: 30, height: 30) }
                                    else { Image(systemName: "app.dashed").font(.system(size: 25)).frame(width: 30, height: 30) }
                                    Text(item.title).lineLimit(1).frame(maxWidth: 118, alignment: .leading)
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!item.canPress || overflow.status == .activating)
                                .help(item.title + "\n" + L10n.t(item.canPress ? .overflowClickHint : .overflowUnavailable))
                        }
                    }
                }
                if overflow.status == .failed || overflow.status == .unconfirmed {
                    Text(L10n.t(overflow.status.messageKey)).font(AppFont.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Text(L10n.t(overflow.status == .ready ? .overflowEmpty : overflow.status.messageKey))
                        .font(AppFont.secondary).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 4)
                    if !overflow.enabled { Button(L10n.t(.panelEnable)) { overflow.setEnabled(true) }.buttonStyle(.link) }
                    else if overflow.status == .needsPermission { Button(L10n.t(.overflowGrant)) { model.onAction?(.permission) }.buttonStyle(.link) }
                }.frame(minHeight: 25)
            }
        }.padding(12)
            .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(MenuBarPanelModel.Tab.allCases, id: \.self) { tab in
                Button { model.selectTab(tab) } label: {
                    Text(tab.title).frame(maxWidth: .infinity).frame(height: 34)
                        .contentShape(Rectangle())
                        .background(model.page == .home && model.tab == tab ? AppColor.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(model.page == .home && model.tab == tab ? Color.white : .primary)
                }.buttonStyle(.plain).accessibilityAddTraits(model.page == .home && model.tab == tab ? [.isSelected] : [])
            }
        }.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var content: some View {
        if model.page != .home {
            HStack {
                Button { model.navigate(.home) } label: { Label(L10n.t(.panelBack), systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(AppColor.accent)
                Spacer()
                Text(pageTitle).font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 45, height: 1)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
        }
        switch model.page {
        case .home:
            if model.isSearching { searchResults }
            else {
                switch model.tab {
                case .clipboard: historyContent
                case .snippets: snippetsContent
                case .tools:
                    ScrollViewReader { proxy in
                        ScrollView { toolList }.onChange(of: model.selectedID) { id in if let id { proxy.scrollTo(id) } }
                    }
                }
            }
        case .capture: captureContent
        case .devices: devicesContent
        case .notifications: notificationsContent
        case .settings: settingsContent
        }
    }
    private var pageTitle: String {
        switch model.page {
        case .capture: return L10n.t(.panelCapture)
        case .devices: return L10n.t(.lanDevices)
        case .notifications: return L10n.t(.notificationSync)
        case .settings: return L10n.t(.preferences)
        case .home: return model.tab.title
        }
    }
    private var historyContent: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(HistoryTypeFilter.allCases) { filter in
                    pill(L10n.t(filter.labelKey), selected: model.filter == filter) { model.filter = filter }
                }
                Spacer(minLength: 0)
            }.padding(.bottom, 4)
            historyList
            actionLink(.panelAllHistory) { model.onAction?(.search(model.query)) }
        }
    }
    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.loading { ProgressView().padding(30).frame(maxWidth: .infinity) }
                else if model.history.isEmpty { empty(.noHistory, hint: .panelNoHistoryHint, symbol: "clipboard") }
                else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history) { entry in historyRow(entry) }
                    }
                }
            }.onChange(of: model.selectedID) { id in if let id { proxy.scrollTo(id) } }
        }
    }
    private func historyRow(_ entry: HistoryEntry) -> some View {
        MenuBarPanelHistoryRow(entry: entry, selected: model.selectedID == "h:" + entry.id,
                              use: { model.onHistory?(entry, .use) }, copy: { model.onHistory?(entry, .copy) })
            .id("h:" + entry.id)
            .onHover { if $0 { model.selectedID = "h:" + entry.id } }
            .contextMenu {
                Button(L10n.t(.panelUse)) { model.onHistory?(entry, .use) }
                Button(L10n.t(.copyContent)) { model.onHistory?(entry, .copy) }
                if entry.item.isFile {
                    Button(L10n.t(.pasteFileName)) { model.onHistory?(entry, .fileNames) }
                    Button(L10n.t(.showInFinder)) { model.onHistory?(entry, .reveal) }
                } else {
                    switch entry.item {
                    case .html, .rtf: Button(L10n.t(.pastePlainText)) { model.onHistory?(entry, .plainText) }
                    default: EmptyView()
                    }
                }
            }
    }
    private var snippetsContent: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    pill(L10n.t(.historyFilterAll), selected: model.folderID == nil) { model.folderID = nil }
                    ForEach(model.folders) { folder in
                        pill(folder.title, selected: model.folderID == folder.id) { model.folderID = folder.id }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                ScrollView {
                    if model.visibleSnippets.isEmpty { empty(.noSnippets, hint: .panelManageSnippets, symbol: "square.on.square") }
                    else { LazyVStack(spacing: 0) { ForEach(model.visibleSnippets) { snippetRow($0) } } }
                }.onChange(of: model.selectedID) { id in if let id { proxy.scrollTo(id) } }
            }
            actionLink(.panelManageSnippets) { model.onAction?(.snippets) }
        }
    }
    private func snippetRow(_ snippet: Snippet) -> some View {
        Button { model.onSnippet?(snippet.id) } label: {
            HStack(spacing: 11) {
                Image(systemName: "text.alignleft").font(.system(size: 19)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(snippet.title).lineLimit(1)
                    Text(snippet.content).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 3)
                if let shortcut = snippet.shortcut { Text(shortcut.displayString).font(AppFont.caption).foregroundStyle(.secondary) }
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(model.selectedID == "s:" + snippet.id.uuidString ? AppColor.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).id("s:" + snippet.id.uuidString)
            .onHover { if $0 { model.selectedID = "s:" + snippet.id.uuidString } }
    }
    private var searchResults: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.loading { ProgressView().padding().frame(maxWidth: .infinity) }
                        ForEach(model.history) { historyRow($0) }
                        ForEach(model.visibleSnippets) { snippetRow($0) }
                        toolList
                        if !model.loading && model.history.isEmpty && model.visibleSnippets.isEmpty && model.matchingTools.isEmpty {
                            empty(.panelEmptySearch, hint: .panelEmptyHint, symbol: "magnifyingglass")
                        }
                    }
                }.onChange(of: model.selectedID) { id in if let id { proxy.scrollTo(id) } }
            }
            actionLink(.panelAllHistory) { model.onAction?(.search(model.query)) }
        }
    }
    private var toolList: some View {
        VStack(spacing: 0) {
            ForEach(model.matchingTools, id: \.rawValue) { tool in
                toolRow(tool.title, detail: tool.hint, symbol: tool.symbol) { model.useTool(tool) }
                    .id("t:" + tool.rawValue)
                    .background(model.selectedID == "t:" + tool.rawValue ? AppColor.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .onHover { if $0 { model.selectedID = "t:" + tool.rawValue } }
            }
        }
    }
    private var captureContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                toolRow(.screenshotRegion, detail: nil, symbol: "viewfinder") { model.onAction?(.region) }
                toolRow(.screenshotWindow, detail: nil, symbol: "macwindow") { model.onAction?(.window) }
                toolRow(.screenshotFullscreen, detail: nil, symbol: "rectangle.inset.filled") { model.onAction?(.fullscreen) }
                Text(L10n.t(.panelCaptureHint)).font(AppFont.secondary).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                actionLink(.screenshotPreferences) { model.onAction?(.screenshotSettings) }
            }
        }
    }
    private var devicesContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t(.panelSyncHint)).font(AppFont.caption).foregroundStyle(.secondary)
                Spacer()
                Button { SyncManager.shared.triggerCrossBandDiscovery() } label: { Image(systemName: "arrow.clockwise") }.help(L10n.t(.refreshDevices))
            }.padding(.vertical, 8)
            ScrollView {
                if model.devices.isEmpty { empty(.noDevicesFound, hint: .panelSyncHint, symbol: "network") }
                else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.devices, id: \.peerId) { device in
                            HStack(spacing: 10) {
                                Image(systemName: "desktopcomputer").font(.system(size: 24)).foregroundStyle(.secondary)
                                Text(device.displayName).lineLimit(2)
                                Spacer()
                                Menu {
                                    Button(L10n.t(.sendFile)) { model.onAction?(.sendFile(device.peerId)) }
                                    Button(L10n.t(.sendText)) { model.onAction?(.sendText(device.peerId)) }
                                } label: { Text(L10n.t(.send)) }.fixedSize()
                            }.padding(.vertical, 14)
                            Divider()
                        }
                    }
                }
            }
            actionLink(.panelSyncSettings) { model.onAction?(.syncSettings) }
        }
    }
    private var notificationsContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                if model.notifications.isEmpty { empty(.noNotifications, hint: nil, symbol: "bell") }
                else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.notifications) { notification in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(notification.appName).font(AppFont.caption).foregroundStyle(.secondary)
                                Text(notification.title).font(.system(size: 13, weight: .medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(notification.body).font(AppFont.secondary).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
            }
            actionLink(.panelAllNotifications) { model.onAction?(.notifications) }
        }
    }
    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(L10n.t(.overflowEnabled), isOn: Binding(get: { overflow.enabled }, set: { overflow.setEnabled($0) }))
                Text(L10n.t(.overflowHint)).font(AppFont.caption).foregroundStyle(.secondary)
                Divider()
                Toggle(L10n.t(.panelPin), isOn: $model.pinned)
                Text(L10n.t(.panelPinHint)).font(AppFont.caption).foregroundStyle(.secondary)
                Divider()
                actionLink(.overflowGrant) { model.onAction?(.permission) }
                actionLink(.panelSettingsHint) { model.onAction?(.preferences) }
            }.toggleStyle(.switch).padding(.vertical, 12)
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            quick(.panelCaptureShortcut, symbol: "camera") { model.navigate(.capture) }
            quick(.panelLookupShortcut, symbol: "character.book.closed") { model.onAction?(.word) }
            quick(.panelSwitchShortcut, symbol: "arrow.triangle.swap") { model.onAction?(.smartSwitch) }
            Spacer(minLength: 0)
            Divider().frame(height: 24)
            Button { model.navigate(.devices) } label: {
                Text(L10n.format(.panelDeviceCount, model.devices.count)).font(AppFont.secondary).lineLimit(1)
            }.buttonStyle(.plain)
            Button { model.navigate(.notifications) } label: {
                Image(systemName: "bell").font(.system(size: 18)).frame(width: 27, height: 30)
                    .contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if model.notificationCount > 0 {
                            Text(model.notificationCount > 99 ? "99+" : "\(model.notificationCount)")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                                .padding(3).background(Color.red, in: Capsule()).offset(x: 5, y: -5)
                        }
                    }
            }.buttonStyle(.plain).help(L10n.t(.notificationSync)).accessibilityLabel(L10n.t(.notificationSync))
            Menu {
                Button(L10n.t(.preferences)) { model.onAction?(.preferences) }
                Button(L10n.t(.overflowRefresh)) { overflow.refreshForMenu() }
                Divider()
                Button(L10n.t(.quit)) { model.onAction?(.quit) }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.t(.panelMore)).accessibilityLabel(L10n.t(.panelMore))
        }
    }
    private func quick(_ key: L10nKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(L10n.t(key), systemImage: symbol).font(AppFont.secondary).lineLimit(1).padding(.horizontal, 8).frame(height: 34).contentShape(Rectangle()).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
    }
    private func iconButton(_ key: L10nKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 17)).frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(.plain).help(L10n.t(key)).accessibilityLabel(L10n.t(key))
    }
    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(AppFont.secondary).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle()).background(selected ? AppColor.accent.opacity(0.13) : Color.primary.opacity(0.045), in: Capsule()).foregroundStyle(selected ? AppColor.accent : .secondary) }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func toolRow(_ title: L10nKey, detail: L10nKey?, symbol: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.system(size: 22)).frame(width: 27)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.t(title))
                        if let detail { Text(L10n.t(detail)).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(AppFont.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 8).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider()
        }
    }
    private func actionLink(_ key: L10nKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 5) { Text(L10n.t(key)); Image(systemName: "chevron.right").font(.system(size: 10)) }.font(AppFont.secondary).frame(maxWidth: .infinity).frame(height: 39).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(AppColor.accent)
    }
    private func empty(_ title: L10nKey, hint: L10nKey?, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 29, weight: .light)).foregroundStyle(.secondary)
            Text(L10n.t(title))
            if let hint { Text(L10n.t(hint)).font(AppFont.secondary).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }.padding(24).frame(maxWidth: .infinity, minHeight: 175)
    }
}

private struct MenuBarPanelHistoryRow: View {
    let entry: HistoryEntry
    let selected: Bool
    let use: () -> Void
    let copy: () -> Void
    @StateObject private var thumbnail = MenuBarPanelThumbnail()
    private var symbol: String {
        switch entry.item {
        case .image: return "photo"
        case .files: return "doc"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .rtf: return "doc.richtext"
        case .pdf: return "doc.text"
        case .text: return entry.isPinned ? "pin" : "text.alignleft"
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Button(action: use) {
                HStack(spacing: 10) {
                    if let image = thumbnail.image { Image(nsImage: image).resizable().scaledToFit().frame(width: 46, height: 34) }
                    else { Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 24) }
                    Text(entry.listDisplayTitle).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 3) {
                        if let source = entry.sourceApp { Text(source).lineLimit(1) }
                        Text(RelativeTimeFormatter.string(from: entry.date)).lineLimit(1)
                    }.font(AppFont.caption).foregroundStyle(.secondary).frame(maxWidth: 82, alignment: .trailing)
                }.frame(maxWidth: .infinity, minHeight: 47).contentShape(Rectangle())
            }.buttonStyle(.plain).help(entry.item.fileURLs?.map(\.path).joined(separator: "\n") ?? entry.listDisplayTitle)
            if selected {
                Button(action: copy) { Text(L10n.t(.panelCopy)).font(AppFont.secondary).padding(.horizontal, 10).padding(.vertical, 4).contentShape(Rectangle()).background(Color(nsColor: .textBackgroundColor), in: Capsule()) }.buttonStyle(.plain).foregroundStyle(AppColor.accent)
            }
        }.padding(.horizontal, 9)
            .background(selected ? AppColor.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) { if !selected { Divider() } }
            .onAppear {
                if case .image(let path) = entry.item { thumbnail.load(path) }
            }
            .onDisappear { thumbnail.cancel() }
    }
}

private final class MenuBarPanelThumbnail: ObservableObject {
    @Published var image: NSImage?
    private var revision = 0
    func load(_ path: String) {
        revision += 1
        let ticket = revision
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image = HistoryThumbnailCache.thumbnail(for: path, size: NSSize(width: 92, height: 68))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == ticket else { return }
                self.image = image
            }
        }
    }
    func cancel() { revision += 1; image = nil }
}

/// AppKit field delegates navigation only after the input method has finished composition.
private struct MenuBarPanelSearchField: NSViewRepresentable {
    @ObservedObject var model: MenuBarPanelModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.cell?.usesSingleLineMode = true
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.setAccessibilityLabel(L10n.t(.panelSearch))
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        field.placeholderAttributedString = NSAttributedString(string: L10n.t(.panelSearch), attributes: AppFont.textAttributes(size: 14, color: .secondaryLabelColor))
        field.setAccessibilityLabel(L10n.t(.panelSearch))
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing && field.stringValue != model.query { field.stringValue = model.query }
        if context.coordinator.focusRequest != model.focusRequest {
            context.coordinator.focusRequest = model.focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window?.isVisible == true else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: MenuBarPanelModel
        var focusRequest = 0
        init(_ model: MenuBarPanelModel) { self.model = model }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if model.page != .home { model.page = .home }
            model.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): model.moveSelection(1); return true
            case #selector(NSResponder.moveUp(_:)): model.moveSelection(-1); return true
            case #selector(NSResponder.insertNewline(_:)): model.useSelection(); return true
            default: return false
            }
        }
    }
}
