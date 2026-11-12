import AppKit
import SwiftUI

/// Clipy 主窗口（V3 · `docs/design/design-v3/screens/mac-hub.html`）：剪贴板历史 / 片段 / 设备 / 手机通知 /
/// 工具 / 设置合在唯一的窗口，侧栏顶部切换（⌥⌘1–6，⌘, 直达设置；⌘1–9 留给历史快速粘贴）。
/// 不再有独立的偏好设置、查词或生成密码窗口：菜单、面板与全局快捷键都调用这里的
/// `showSettings` / `showTools` 等入口定位模块与分区，设置项与各模块之间双向直达。
///
/// 生命周期沿用各模块原有规则：同一时刻只挂载当前模块视图，切走时视图消失、由各自的
/// onDisappear / prepareForClose 释放数据，切回时 onAppear 重新加载；关窗调用当前模块
/// prepareForClose，复用窗口重新打开时调用其原有的 reactivate 钩子。
enum MainWindowSection: String, CaseIterable, Identifiable {
    case history, snippets, devices, notifications, tools, settings

    var id: String { rawValue }

    private static var zh: Bool { PreferencesManager.shared.appLanguage == .zh }

    /// 侧栏切换条上的短标签。
    var label: String {
        switch self {
        case .history: return Self.zh ? "历史" : "History"
        case .snippets: return Self.zh ? "片段" : "Snippets"
        case .devices: return Self.zh ? "设备" : "Devices"
        case .notifications: return Self.zh ? "通知" : "Alerts"
        case .tools: return Self.zh ? "工具" : "Tools"
        case .settings: return Self.zh ? "设置" : "Settings"
        }
    }

    var title: String {
        switch self {
        case .history: return Self.zh ? "剪贴板历史" : "Clipboard History"
        case .snippets: return Self.zh ? "片段" : "Snippets"
        case .devices: return Self.zh ? "设备" : "Devices"
        case .notifications: return Self.zh ? "手机通知" : "Phone Notifications"
        case .tools: return Self.zh ? "工具" : "Tools"
        case .settings: return Self.zh ? "设置" : "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .history: return "clock"
        case .snippets: return "text.quote"
        case .devices: return "laptopcomputer.and.iphone"
        case .notifications: return "bell"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }

    /// 与 ⌥⌘ 组合的数字键。
    var keyEquivalent: String { String((Self.allCases.firstIndex(of: self) ?? 0) + 1) }
}

final class MainWindowNavigator: ObservableObject {
    @Published fileprivate(set) var section: MainWindowSection

    init(section: MainWindowSection) {
        self.section = section
    }

    func select(_ section: MainWindowSection) {
        MainWindow.shared.select(section)
    }
}

private struct MainWindowNavigatorKey: EnvironmentKey {
    static let defaultValue: MainWindowNavigator? = nil
}

extension EnvironmentValues {
    /// 非 nil 表示模块视图正嵌在主窗口中：侧栏顶部显示模块切换条。
    var mainWindowNavigator: MainWindowNavigator? {
        get { self[MainWindowNavigatorKey.self] }
        set { self[MainWindowNavigatorKey.self] = newValue }
    }
}

enum MainWindowMetrics {
    /// 主窗口内各模块统一的侧栏宽度。
    static let sidebarWidth: CGFloat = 220
    static let size = CGSize(width: 1180, height: 720)
    static let minSize = CGSize(width: 980, height: 560)
}

final class MainWindow {
    static let shared = MainWindow()

    private static let sectionDefaultsKey = "MainWindow.section"

    private let session = WindowSession<MainWindowRootView>()
    private let navigator: MainWindowNavigator
    private var searchModel: SearchViewModel?
    private var snippetModel: SnippetEditorViewModel?
    private var notificationModel: NotificationViewModel?
    private var wordModel: WordLookupViewModel?
    private var passwordModel: PasswordViewModel?
    /// 工具模块导航（单词查询 / 单词表 / 生成密码与保持唤醒），跨挂载保留。
    let wordNavigation = WordWorkspaceNavigation()
    /// 设置模块下次挂载时定位的分类（外部深链）。
    private(set) var pendingSettingsPage: String?
    private weak var window: NSWindow?
    private var wasVisibleBeforeShow = false

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.sectionDefaultsKey)
        navigator = MainWindowNavigator(section: stored.flatMap(MainWindowSection.init(rawValue:)) ?? .history)
    }

    var section: MainWindowSection { navigator.section }
    private(set) var devicesPage: DevicesPage = .devices

    func showDevices(page: DevicesPage) {
        devicesPage = page
        show(.devices)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .devicesNavigate, object: page)
        }
    }

    var searchViewModel: SearchViewModel {
        if let searchModel { return searchModel }
        let model = SearchViewModel()
        searchModel = model
        return model
    }

    var snippetViewModel: SnippetEditorViewModel {
        if let snippetModel { return snippetModel }
        let model = SnippetEditorViewModel()
        snippetModel = model
        return model
    }

    var notificationViewModel: NotificationViewModel {
        if let notificationModel { return notificationModel }
        let model = NotificationViewModel()
        notificationModel = model
        return model
    }

    var wordViewModel: WordLookupViewModel {
        if let wordModel { return wordModel }
        let model = WordLookupViewModel()
        wordModel = model
        return model
    }

    var passwordViewModel: PasswordViewModel {
        if let passwordModel { return passwordModel }
        let model = PasswordViewModel()
        passwordModel = model
        return model
    }

    // MARK: Routing (all entries land in this window)

    /// 设置模块并定位分类；`sync` 为旧的设备分类，转到「设备 › 局域网设置」。
    func showSettings(page: String? = nil) {
        if page == "sync" {
            showDevices(page: .lan)
            return
        }
        pendingSettingsPage = page
        let alreadyShowing = navigator.section == .settings && window?.isVisible == true
        show(.settings)
        // 已挂载的设置文档直接滚动；新挂载时由 SettingsView 读取 pendingSettingsPage。
        if alreadyShowing, let page {
            pendingSettingsPage = nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .appSettingsNavigate, object: page)
            }
        }
    }

    func consumePendingSettingsPage() -> String? {
        defer { pendingSettingsPage = nil }
        return pendingSettingsPage
    }

    /// 工具模块：单词查询（可带查询词 / 剪贴板预填）、单词表、生成密码与保持唤醒。
    func showTools(_ page: WordWorkspacePage = .lookup, query: String? = nil, openModelSettings: Bool = false) {
        let items = NSPasteboard.general.pasteboardItems ?? []
        let clipboardText = items.count == 1 && !items[0].types.contains(.fileURL)
            ? items[0].string(forType: .string) : nil
        wordNavigation.page = page
        show(.tools)
        let model = wordViewModel
        switch page {
        case .lookup:
            if let query {
                model.query = query
                model.search()
            } else if !openModelSettings {
                model.prepareForPresentation(clipboardText: clipboardText)
            }
        case .book:
            model.prepareForClose()
        case .utilities:
            break
        }
        if openModelSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in wordNavigation.showsModelSettings = true }
        }
    }

    func showSnippets(openFolderSettings: Bool) {
        show(.snippets)
        guard openFolderSettings else { return }
        // 等新挂载的视图订阅后再请求，popover 才有锚点。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in snippetViewModel.folderSettingsRequest += 1 }
    }

    func showNotifications(openSettings: Bool) {
        showNotifications()
        guard openSettings else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in notificationViewModel.settingsPopoverRequest += 1 }
    }

    func showHistory(initialQuery: String) {
        show(.history)
        searchViewModel.acceptPanelQuery(initialQuery)
    }

    func showNotifications() {
        show(.notifications)
        // 已停在通知页时不会重新 onAppear，保留原来的节流刷新。
        notificationViewModel.refreshIfStale()
    }

    func showWithPrefilledSnippet(title: String, content: String) {
        guard let snippet = SnippetManager.shared.addSnippetToDefaultFolder(title: title, content: content) else { return }
        show(.snippets)
        DispatchQueue.main.async { [self] in
            snippetViewModel.selectSnippet(snippet.id)
            snippetViewModel.reloadSidebar()
        }
    }

    func show(_ section: MainWindowSection? = nil) {
        if let section { select(section) }
        NSApp.activate(ignoringOtherApps: true)
        session.present(
            create: { [self] in
                let created = HostingWindow(
                    title: windowTitle,
                    size: MainWindowMetrics.size,
                    minSize: MainWindowMetrics.minSize,
                    fullSizeContent: true,
                    frameAutosaveName: "MainWindow"
                ) {
                    MainWindowRootView(owner: self, navigator: self.navigator)
                }
                window = created
                return created
            },
            onPrepareForClose: { [weak self] in
                self?.prepareCurrentForClose()
            },
            onTeardown: { [weak self] in
                self?.searchModel = nil
                self?.snippetModel = nil
                self?.notificationModel = nil
                self?.wordModel = nil
                self?.passwordModel = nil
                MemoryFootprintReclaimer.reclaimIfIdle()
            },
            update: { [weak self] window in
                self?.wasVisibleBeforeShow = window.isVisible
                window.title = self?.windowTitle ?? window.title
            },
            onShow: { [weak self] in
                // 复用已关闭的窗口时 SwiftUI 不会再触发 onAppear，按各模块原窗口的方式重新激活。
                guard let self, !self.wasVisibleBeforeShow else { return }
                self.reactivateCurrent()
            }
        )
    }

    func select(_ newSection: MainWindowSection) {
        let old = navigator.section
        guard newSection != old else { return }
        navigator.section = newSection
        UserDefaults.standard.set(newSection.rawValue, forKey: Self.sectionDefaultsKey)
        window?.title = windowTitle
        // 历史 / 通知视图的 onDisappear 自行释放；片段在视图卸载（草稿 flush）之后再清选择。
        if old == .snippets {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.navigator.section != .snippets else { return }
                self.snippetModel?.prepareForClose()
            }
        }
        // 工具：切走即停止查询 / 发音并清空结果（与原查词窗口关闭一致），密码不留在内存。
        if old == .tools {
            wordModel?.prepareForClose()
            passwordModel = nil
        }
    }

    /// 仅当主窗口当前显示的是指定模块时关闭（如历史「粘贴并关闭」）。
    func close(ifShowing section: MainWindowSection) {
        guard navigator.section == section else { return }
        session.close()
    }

    private var windowTitle: String { "Clipy — " + navigator.section.title }

    private func prepareCurrentForClose() {
        switch navigator.section {
        case .history: searchModel?.prepareForClose()
        case .snippets: snippetModel?.prepareForClose()
        case .notifications: notificationModel?.prepareForClose()
        case .tools:
            wordModel?.prepareForClose()
            passwordModel = nil
        case .devices, .settings: break
        }
    }

    private func reactivateCurrent() {
        switch navigator.section {
        case .history: searchModel?.reactivate()
        case .snippets: snippetModel?.activate()
        case .notifications: notificationModel?.refreshIfStale()
        case .devices, .tools, .settings: break
        }
    }

    // MARK: App menu

    /// 应用菜单「窗口」：六个模块（⌥⌘1–6）。
    static func makeWindowMenuItems(target: AnyObject, action: Selector) -> [NSMenuItem] {
        MainWindowSection.allCases.enumerated().map { index, section in
            let item = NSMenuItem(title: section.title, action: action, keyEquivalent: section.keyEquivalent)
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = index
            item.target = target
            return item
        }
    }

    static func section(forMenuTag tag: Int) -> MainWindowSection? {
        MainWindowSection.allCases.indices.contains(tag) ? MainWindowSection.allCases[tag] : nil
    }
}

struct MainWindowRootView: View {
    let owner: MainWindow
    @ObservedObject var navigator: MainWindowNavigator

    var body: some View {
        content
            .environment(\.mainWindowNavigator, navigator)
            .frame(minWidth: MainWindowMetrics.minSize.width, minHeight: MainWindowMetrics.minSize.height)
    }

    @ViewBuilder
    private var content: some View {
        switch navigator.section {
        case .history:
            SearchView(viewModel: owner.searchViewModel)
        case .snippets:
            SnippetEditorView(viewModel: owner.snippetViewModel)
        case .devices:
            DevicesView(page: owner.devicesPage)
        case .notifications:
            NotificationView(viewModel: owner.notificationViewModel)
        case .tools:
            WordWorkspaceView(model: owner.wordViewModel, navigation: owner.wordNavigation,
                              passwordModel: owner.passwordViewModel)
        case .settings:
            SettingsView(initialPage: owner.consumePendingSettingsPage())
        }
    }
}

// MARK: - Sidebar chrome shared by the modules

/// 侧栏顶部：红绿灯留白 + 模块切换条。
struct MainWindowSidebarHeader: View {
    @Environment(\.mainWindowNavigator) private var navigator

    var body: some View {
        if let navigator {
            VStack(spacing: 0) {
                Color.clear.frame(height: 44)
                MainWindowSectionSwitcher(navigator: navigator)
                    .padding(.bottom, 8)
            }
        }
    }
}

private struct MainWindowSectionSwitcher: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var navigator: MainWindowNavigator

    var body: some View {
        let _ = languageObserver.revision
        HStack(spacing: 4) {
            ForEach(MainWindowSection.allCases) { section in
                MainWindowSectionButton(section: section, isOn: navigator.section == section) {
                    navigator.select(section)
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(SplitV3Color.fill))
        .accessibilityElement(children: .contain)
    }
}

private struct MainWindowSectionButton: View {
    let section: MainWindowSection
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? AppColor.accent : (hovered ? Color.primary : SplitV3Color.text2))
                    .frame(height: 18)
                Text(section.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOn || hovered ? Color.primary : SplitV3Color.text2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(SplitV3Color.control)
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SplitV3Color.controlLine, lineWidth: 0.5))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(section.title)  ⌥⌘\(section.keyEquivalent)")
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
