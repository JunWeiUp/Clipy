import AppKit
import SwiftUI

// MARK: - Settings pages & search

struct AppSettingsPage: Identifiable {
  let id: String
  let title: String
  let symbol: String
  /// Optional trailing count in the sidebar (e.g. online devices).
  var badge: String? = nil
}

enum AppSettingsSearch {
  /// Bilingual keywords per page, in addition to the visible row labels that each
  /// settings row reports at runtime (`labels`).
  static let keywords: [String: String] = [
    "general": "主题 外观 浅色 深色 跟随系统 语言 登录 启动 菜单栏 隐藏 图标 appearance theme light dark system language login menu hidden icons",
    "history": "数量 保留 时长 排除 应用 加密 OCR 识别 retention limit exclude encryption image text recognition",
    "shortcuts": "全局 搜索 查词 单词 快捷键 shortcut hotkey search word",
    "screenshot.capture": "截图 模式 全屏 窗口 区域 分辨率 放大镜 自动保存 OCR capture screenshot resolution magnifier save",
    "screenshot.recording": "录制 录屏 帧率 音频 麦克风 摄像头 按键 recording fps audio microphone webcam keystroke",
    "screenshot.output": "格式 路径 质量 缩略图 提示音 output thumbnail format quality sound",
    "screenshot.scroll": "长截图 滚动 标注 压感 画笔 平滑 scroll annotation pencil pressure smooth",
    "screenshot.effects": "美化 背景 阴影 圆角 亮度 对比度 饱和度 锐度 特效 beautify background shadow effects contrast saturation",
    "sync": "设备 同步 中继 公网 端口 IP 锁屏 解锁 密码 网络 诊断 device sync relay port network lock unlock passcode diagnostics",
    "permissions": "权限 授权 辅助功能 屏幕录制 输入监控 麦克风 摄像头 permission accessibility camera microphone screen input monitoring",
    "about": "关于 版本 日志 诊断 向导 about version logs diagnostics guide",
  ]

  static func tokens(_ query: String) -> [String] {
    query.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  static func text(_ text: String, matches query: String) -> Bool {
    let tokens = tokens(query)
    return !tokens.isEmpty && tokens.allSatisfy { text.localizedStandardContains($0) }
  }

  static func matches(_ page: AppSettingsPage, query: String, labels: [String] = []) -> Bool {
    let tokens = tokens(query)
    guard !tokens.isEmpty else { return true }
    let searchable = ([page.title, keywords[page.id] ?? ""] + labels).joined(separator: " ")
    return tokens.allSatisfy { searchable.localizedStandardContains($0) }
  }
}

// MARK: - Palette (V3 mac settings tokens)

enum SettingsPalette {
  static func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
  }
  private static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
  }

  static let main = dynamic(light: rgba(247, 247, 249), dark: rgba(30, 30, 33))
  static let sidebar = dynamic(light: rgba(240, 241, 245), dark: rgba(40, 40, 46))
  static let card = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.04))
  static let line = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))
  static let text = dynamic(light: rgba(29, 29, 31), dark: rgba(242, 242, 245))
  static let text2 = dynamic(light: rgba(29, 29, 31, 0.66), dark: rgba(242, 242, 245, 0.66))
  static let text3 = dynamic(light: rgba(29, 29, 31, 0.42), dark: rgba(242, 242, 245, 0.40))
  static let fill = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.06))
  static let fill2 = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.10))
  static let control = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.08))
  static let controlLine = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.10))
  static let hit = dynamic(light: rgba(10, 108, 255, 0.11), dark: rgba(61, 139, 255, 0.22))
  static let ok = dynamic(light: rgba(22, 163, 74), dark: rgba(52, 211, 153))
  static let okBackground = dynamic(light: rgba(22, 163, 74, 0.12), dark: rgba(52, 211, 153, 0.15))
  static let warn = dynamic(light: rgba(217, 119, 6), dark: rgba(251, 191, 36))
  static let bad = dynamic(light: rgba(229, 56, 59), dark: rgba(255, 107, 107))

  /// Category square gradients (top → bottom) from the V3 sidebar.
  static func gradient(for pageID: String) -> [Color] {
    func c(_ hex: UInt32) -> Color {
      Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
    switch pageID {
    case "general": return [c(0x8E8E93), c(0x636366)]
    case "history": return [c(0x5AC8FA), c(0x0A84FF)]
    case "shortcuts": return [c(0xBF5AF2), c(0x8944AB)]
    case "screenshot.capture": return [c(0xFF6482), c(0xFF375F)]
    case "screenshot.recording": return [c(0xFF453A), c(0xD70015)]
    case "screenshot.output": return [c(0xFF9F0A), c(0xFF6B00)]
    case "screenshot.scroll": return [c(0xFFD60A), c(0xFF9F0A)]
    case "screenshot.effects": return [c(0x7D7AFF), c(0x5E5CE6)]
    case "sync": return [c(0x64D2FF), c(0x0A84FF)]
    case "permissions": return [c(0x30D158), c(0x248A3D)]
    case "about": return [c(0xAEAEB2), c(0x8E8E93)]
    default: return [c(0x8E8E93), c(0x636366)]
    }
  }

  /// Tinted row icon (`.ri`) styles.
  enum Tint {
    case blue, orange, green, purple, red, neutral
    var foreground: Color {
      switch self {
      case .blue: return Color(.sRGB, red: 10 / 255, green: 132 / 255, blue: 1)
      case .orange: return Color(.sRGB, red: 240 / 255, green: 138 / 255, blue: 0)
      case .green: return Color(.sRGB, red: 40 / 255, green: 167 / 255, blue: 69 / 255)
      case .purple: return Color(.sRGB, red: 160 / 255, green: 80 / 255, blue: 216 / 255)
      case .red: return Color(.sRGB, red: 229 / 255, green: 55 / 255, blue: 45 / 255)
      case .neutral: return SettingsPalette.text2
      }
    }
    var background: Color {
      switch self {
      case .blue: return Color(.sRGB, red: 10 / 255, green: 132 / 255, blue: 1, opacity: 0.12)
      case .orange: return Color(.sRGB, red: 1, green: 159 / 255, blue: 10 / 255, opacity: 0.14)
      case .green: return Color(.sRGB, red: 52 / 255, green: 199 / 255, blue: 89 / 255, opacity: 0.14)
      case .purple: return Color(.sRGB, red: 191 / 255, green: 90 / 255, blue: 242 / 255, opacity: 0.14)
      case .red: return Color(.sRGB, red: 1, green: 69 / 255, blue: 58 / 255, opacity: 0.12)
      case .neutral: return SettingsPalette.fill2
      }
    }
  }
}

/// Localized literal for settings-only copy that has no shared L10n key.
func settingsText(_ zh: String, _ en: String) -> String {
  PreferencesManager.shared.appLanguage == .zh ? zh : en
}

struct SettingsCategoryIcon: View {
  let pageID: String
  let symbol: String
  var size: CGFloat = 22

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.56, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        LinearGradient(colors: SettingsPalette.gradient(for: pageID), startPoint: .top, endPoint: .bottom),
        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
  }
}

// MARK: - Search plumbing (environment + reported row labels)

private struct SettingsSearchQueryKey: EnvironmentKey { static let defaultValue = "" }
private struct SettingsPageIDKey: EnvironmentKey { static let defaultValue = "" }
private struct SettingsNavigatorKey: EnvironmentKey { static let defaultValue: AppSettingsNavigator? = nil }

extension EnvironmentValues {
  var settingsSearchQuery: String {
    get { self[SettingsSearchQueryKey.self] }
    set { self[SettingsSearchQueryKey.self] = newValue }
  }
  var settingsPageID: String {
    get { self[SettingsPageIDKey.self] }
    set { self[SettingsPageIDKey.self] = newValue }
  }
  fileprivate var settingsNavigator: AppSettingsNavigator? {
    get { self[SettingsNavigatorKey.self] }
    set { self[SettingsNavigatorKey.self] = newValue }
  }
}

/// pageID → visible row labels, in document order.
private struct SettingsRowLabelsKey: PreferenceKey {
  static var defaultValue: [String: [String]] = [:]
  static func reduce(value: inout [String: [String]], nextValue: () -> [String: [String]]) {
    value.merge(nextValue(), uniquingKeysWith: { $0 + $1 })
  }
}

private struct SettingsSearchableModifier: ViewModifier {
  let label: String
  @Environment(\.settingsSearchQuery) private var query
  @Environment(\.settingsPageID) private var pageID
  @Environment(\.settingsNavigator) private var navigator

  func body(content: Content) -> some View {
    let hit = AppSettingsSearch.text(label, matches: query)
    content
      .background(hit ? SettingsPalette.hit : Color.clear)
      .background {
        if hit, let navigator { AppSettingsScrollAnchor(id: "row:\(pageID):\(label)", navigator: navigator) }
      }
      .preference(key: SettingsRowLabelsKey.self, value: pageID.isEmpty ? [:] : [pageID: [label]])
  }
}

extension View {
  /// Reports the row's visible text to settings search and highlights it on a match.
  func settingsSearchable(_ texts: String?...) -> some View {
    modifier(SettingsSearchableModifier(label: texts.compactMap { $0 }.joined(separator: " ")))
  }
}

private struct AppSettingsPositionKey: PreferenceKey {
  static var defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private struct AppSettingsTopKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Layout

/// V3 preferences shell: full-height 236 pt sidebar (search, coloured category
/// squares, counts), a toolbar with back/forward + current category, and one
/// continuous scrolling document. Sidebar clicks jump to a section; scrolling
/// updates the highlighted category without triggering another jump.
struct AppSettingsLayout<Content: View>: View {
  @Binding var selection: String
  let pages: [AppSettingsPage]
  var showsSidebar = true
  var underTitlebar = false
  @ViewBuilder let content: (String) -> Content
  @StateObject private var navigator = AppSettingsNavigator()
  @State private var pendingJump: String?
  @State private var jumpReset: DispatchWorkItem?
  @State private var searchText = ""
  @State private var rowLabels: [String: [String]] = [:]
  @State private var navHistory: [String] = []
  @State private var navPosition = -1
  @State private var isScrolled = false
  @FocusState private var searchFocused: Bool

  private func pageMatches(_ page: AppSettingsPage) -> Bool {
    AppSettingsSearch.matches(page, query: searchText, labels: rowLabels[page.id] ?? [])
  }

  /// Jumps to a category. `push` records it for back/forward like the design.
  private func navigate(to id: String, push: Bool) {
    if push {
      if navPosition >= 0, navPosition < navHistory.count { navHistory = Array(navHistory.prefix(navPosition + 1)) }
      if navHistory.last != id { navHistory.append(id) }
      navPosition = navHistory.count - 1
    }
    jump(to: id, anchor: id, offset: 6)
  }

  private func jump(to id: String, anchor: String, offset: CGFloat) {
    selection = id
    pendingJump = id
    jumpReset?.cancel()
    DispatchQueue.main.async { navigator.scroll(to: anchor, offset: offset) }
    let reset = DispatchWorkItem { pendingJump = nil }
    jumpReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: reset)
  }

  private func goBack() {
    guard navPosition > 0 else { return }
    navPosition -= 1
    navigate(to: navHistory[navPosition], push: false)
  }

  private func goForward() {
    guard navPosition < navHistory.count - 1 else { return }
    navPosition += 1
    navigate(to: navHistory[navPosition], push: false)
  }

  /// Search: scroll to the first matching row (or matching category heading).
  private func revealFirstMatch() {
    guard !AppSettingsSearch.tokens(searchText).isEmpty else { return }
    for page in pages {
      if let label = rowLabels[page.id]?.first(where: { AppSettingsSearch.text($0, matches: searchText) }) {
        // The highlight anchor is created by the same update; retry briefly until it exists.
        navigator.scrollWhenReady(to: "row:\(page.id):\(label)", offset: 40)
        selection = page.id
        return
      }
      if AppSettingsSearch.matches(page, query: searchText) {
        jump(to: page.id, anchor: page.id, offset: 6)
        return
      }
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      if showsSidebar {
        sidebar
        Rectangle().fill(SettingsPalette.line).frame(width: 0.5)
      }
      VStack(spacing: 0) {
        if showsSidebar { toolbar }
        document
      }
      .background(SettingsPalette.main)
    }
    .ignoresSafeArea(.container, edges: underTitlebar ? .top : [])
    .onReceive(NotificationCenter.default.publisher(for: .appSettingsNavigate)) { notification in
      guard let id = notification.object as? String, pages.contains(where: { $0.id == id }) else { return }
      // External deep links (menu / other windows) start a fresh history like opening the window.
      searchText = ""
      navHistory = [id]
      navPosition = 0
      navigate(to: id, push: false)
    }
    #if CLIPY_CORE_TESTS
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("clipySettingsSnapshotSearch"))) { notification in
      searchText = notification.object as? String ?? ""
    }
    #endif
    .onAppear {
      if navHistory.isEmpty {
        navHistory = [selection]
        navPosition = 0
      }
    }
    .onDisappear {
      jumpReset?.cancel()
      pendingJump = nil
    }
  }

  // MARK: Sidebar

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear.frame(height: underTitlebar ? 36 : 0)
      searchField
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 0) {
          ForEach(pages) { page in sidebarRow(page) }
        }
      }
    }
    .padding(.top, 14)
    .padding(.horizontal, 10)
    .padding(.bottom, 10)
    .frame(width: 236)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(SettingsPalette.sidebar)
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13))
        .foregroundStyle(SettingsPalette.text3)
      TextField("", text: $searchText, prompt: Text(L10n.t(.searchSettings)).foregroundColor(SettingsPalette.text3))
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .focused($searchFocused)
        .onExitCommand {
          searchText = ""
          searchFocused = false
        }
        .accessibilityLabel(L10n.t(.searchSettings))
      if !searchText.isEmpty {
        Button { searchText = "" } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(SettingsPalette.text3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t(.clear))
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 28)
    .background(searchFocused ? SettingsPalette.card : SettingsPalette.fill, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      if searchFocused {
        RoundedRectangle(cornerRadius: 8).strokeBorder(AppColor.accent, lineWidth: 1)
          .padding(-0.5)
          .shadow(color: AppColor.accent.opacity(0.25), radius: 2)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { searchFocused = true }
    .background {
      Button("") { searchFocused = true }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
    .onChange(of: searchText) { _ in revealFirstMatch() }
  }

  private func sidebarRow(_ page: AppSettingsPage) -> some View {
    let selected = selection == page.id
    return Button {
      searchFocused = false
      navigate(to: page.id, push: true)
    } label: {
      HStack(spacing: 9) {
        SettingsCategoryIcon(pageID: page.id, symbol: page.symbol)
        Text(page.title)
          .font(.system(size: 13, weight: selected ? .medium : .regular))
          .lineLimit(1)
        Spacer(minLength: 4)
        if let badge = page.badge {
          Text(badge)
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundStyle(selected ? Color.white.opacity(0.8) : SettingsPalette.text3)
        }
      }
      .foregroundStyle(selected ? Color.white : SettingsPalette.text)
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(selected ? AppColor.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(pageMatches(page) ? 1 : 0.35)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 10) {
      toolbarButton("chevron.left", help: settingsText("后退", "Back"), enabled: navPosition > 0, action: goBack)
      toolbarButton(
        "chevron.right", help: settingsText("前进", "Forward"),
        enabled: navPosition >= 0 && navPosition < navHistory.count - 1, action: goForward)
      Text(pages.first(where: { $0.id == selection })?.title ?? L10n.t(.preferences))
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(SettingsPalette.text)
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
    }
    .padding(.leading, 18)
    .padding(.trailing, 14)
    .frame(height: 52)
    .overlay(alignment: .bottom) {
      Rectangle().fill(isScrolled ? SettingsPalette.line : Color.clear).frame(height: 0.5)
    }
  }

  private func toolbarButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(SettingsPalette.text2)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.35)
    .help(help)
    .accessibilityLabel(help)
  }

  // MARK: Document

  private var document: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        Color.clear.frame(height: 0)
          .background(
            GeometryReader { geometry in
              Color.clear.preference(key: AppSettingsTopKey.self, value: geometry.frame(in: .named("settingsDocument")).minY)
            })
        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
          pageHeader(page, first: index == 0)
          content(page.id)
            .environment(\.settingsPageID, page.id)
        }
      }
      .padding(.horizontal, showsSidebar ? 30 : 20)
      .padding(.top, showsSidebar ? 0 : 14)
      .padding(.bottom, 60)
      .environment(\.settingsSearchQuery, searchText)
      .environment(\.settingsNavigator, navigator)
    }
    .coordinateSpace(name: "settingsDocument")
    .onPreferenceChange(AppSettingsTopKey.self) { top in
      let scrolled = top < -2
      if scrolled != isScrolled { isScrolled = scrolled }
    }
    .onPreferenceChange(SettingsRowLabelsKey.self) { labels in
      if labels != rowLabels { rowLabels = labels }
    }
    .onPreferenceChange(AppSettingsPositionKey.self) { positions in
      guard pendingJump == nil else { return }
      let current =
        navigator.isAtEnd
        ? pages.last
        : (pages.last { (positions[$0.id] ?? .infinity) <= 40 } ?? pages.first)
      if let current, selection != current.id { selection = current.id }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func pageHeader(_ page: AppSettingsPage, first: Bool) -> some View {
    let anchor = Color.clear
      .background(AppSettingsScrollAnchor(id: page.id, navigator: navigator))
      .background(
        GeometryReader { geometry in
          Color.clear.preference(
            key: AppSettingsPositionKey.self,
            value: [page.id: geometry.frame(in: .named("settingsDocument")).minY])
        })
    if showsSidebar {
      HStack(spacing: 8) {
        SettingsCategoryIcon(pageID: page.id, symbol: page.symbol, size: 24)
        Text(page.title)
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(SettingsPalette.text)
          .accessibilityAddTraits(.isHeader)
      }
      .padding(.horizontal, 4)
      .background(anchor)
      .padding(.top, first ? 6 : 16)
      .padding(.bottom, 10)
    } else {
      anchor.frame(height: 0)
    }
  }
}

/// AppKit scrolling also works on macOS 13, where ScrollViewReader does not
/// consistently resolve section IDs inside the settings document.
final class AppSettingsNavigator: ObservableObject {
  private final class Anchor {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
  }
  private var anchors: [String: Anchor] = [:]

  func register(_ view: NSView, id: String) { anchors[id] = Anchor(view) }

  var isAtEnd: Bool {
    guard let scroll = anchors.values.compactMap({ $0.view?.enclosingScrollView }).first,
      let document = scroll.documentView,
      document.bounds.height > scroll.contentView.bounds.height
    else { return false }
    let visible = scroll.contentView.bounds
    return document.isFlipped
      ? document.bounds.maxY - visible.maxY <= 2
      : visible.minY - document.bounds.minY <= 2
  }

  func scrollWhenReady(to id: String, offset: CGFloat, attempts: Int = 8) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      if !self.scroll(to: id, offset: offset), attempts > 1 {
        self.scrollWhenReady(to: id, offset: offset, attempts: attempts - 1)
      }
    }
  }

  @discardableResult
  func scroll(to id: String, offset: CGFloat = 6) -> Bool {
    guard let view = anchors[id]?.view, view.window != nil,
      let scroll = view.enclosingScrollView,
      let document = scroll.documentView
    else { return false }
    let clip = scroll.contentView
    let rect = document.convert(view.bounds, from: view)
    let targetY = document.isFlipped ? rect.minY - offset : rect.maxY - clip.bounds.height + offset
    let maximumY = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
    clip.scroll(
      to: NSPoint(
        x: clip.bounds.minX,
        y: min(maximumY, max(document.bounds.minY, targetY))))
    scroll.reflectScrolledClipView(clip)
    return true
  }
}

private struct AppSettingsScrollAnchor: NSViewRepresentable {
  let id: String
  let navigator: AppSettingsNavigator
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    navigator.register(view, id: id)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { navigator.register(view, id: id) }
}

// MARK: - Components (V3 grouped form)

/// Rounded card; inserts hairlines between its rows (`.fr + .fr`).
struct SettingsCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    _VariadicView.Tree(SettingsCardLayout()) { content() }
      .background(SettingsPalette.card)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SettingsPalette.line, lineWidth: 0.5))
      .padding(.bottom, 12)
  }
}

private struct SettingsCardLayout: _VariadicView_MultiViewRoot {
  @ViewBuilder
  func body(children: _VariadicView.Children) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(children) { child in
        if child.id != children.first?.id {
          SettingsHairline()
        }
        child
      }
    }
  }
}

/// Row separator: 0.5 pt on Retina, one device pixel on 1× displays.
struct SettingsHairline: View {
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    Rectangle().fill(SettingsPalette.line).frame(height: max(0.5, 1 / max(displayScale, 1)))
  }
}

/// Small bold heading between cards (`.sh`).
struct SettingsSubheader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 6) {
      Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsPalette.text)
      trailing()
    }
    .padding(.horizontal, 4)
    .padding(.top, 4)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension SettingsSubheader where Trailing == EmptyView {
  init(_ title: String) {
    self.title = title
    self.trailing = { EmptyView() }
  }
}

/// Note under a card (`.ft`).
struct SettingsFootnote: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(.system(size: 11.5))
      .foregroundStyle(SettingsPalette.text3)
      .lineSpacing(2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
      .padding(.top, -4)
      .padding(.bottom, 12)
  }
}

/// Tinted square row icon (`.ri`).
struct SettingsRowIcon: View {
  let symbol: String
  var tint: SettingsPalette.Tint = .neutral
  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 14))
      .foregroundStyle(tint.foreground)
      .frame(width: 30, height: 30)
      .background(tint.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

/// Standard row: optional icon, title + description, trailing controls (`.fr`).
struct SettingsRow<Accessory: View>: View {
  var icon: SettingsRowIcon? = nil
  /// Application icon (22 pt) shown instead of a tinted symbol.
  var image: NSImage? = nil
  let title: String
  var detail: String? = nil
  /// Fixed label column (text-field rows), otherwise the label takes the free width.
  var labelWidth: CGFloat? = nil
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    HStack(spacing: 12) {
      if let icon { icon }
      if let image {
        Image(nsImage: image).resizable().interpolation(.high).frame(width: 22, height: 22)
      }
      label
      accessory()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .settingsSearchable(title, detail)
  }

  @ViewBuilder private var label: some View {
    let column = VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 13, weight: detail == nil ? .regular : .medium))
        .foregroundStyle(SettingsPalette.text)
        .fixedSize(horizontal: false, vertical: true)
      if let detail {
        Text(detail)
          .font(.system(size: 11.5))
          .foregroundStyle(SettingsPalette.text3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    if let labelWidth {
      column.frame(width: labelWidth, alignment: .leading)
    } else {
      column.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension SettingsRow where Accessory == EmptyView {
  init(icon: SettingsRowIcon? = nil, title: String, detail: String? = nil) {
    self.icon = icon
    self.image = nil
    self.title = title
    self.detail = detail
    self.labelWidth = nil
    self.accessory = { EmptyView() }
  }
}

/// Free-form row content with the standard row padding (`.fr`).
struct SettingsCustomRow<Content: View>: View {
  var searchText: String
  var minHeight: CGFloat = 44
  @ViewBuilder let content: () -> Content
  var body: some View {
    HStack(spacing: 12) { content() }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
      .settingsSearchable(searchText)
  }
}

/// Compact caption row (`.fr.c`).
struct SettingsCaptionRow: View {
  let text: String
  var symbol: String? = nil
  var color: Color? = nil
  init(_ text: String, symbol: String? = nil, color: Color? = nil) {
    self.text = text
    self.symbol = symbol
    self.color = color
  }
  var body: some View {
    HStack(spacing: 6) {
      if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
      Text(text).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
    }
    .font(.system(size: 11.5))
    .foregroundStyle(color ?? SettingsPalette.text3)
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .settingsSearchable(text)
  }
}

/// Gray bar at the bottom of a list card with an add control and a note.
struct SettingsCardFooter<Leading: View>: View {
  let note: String
  @ViewBuilder let leading: () -> Leading
  var body: some View {
    HStack(spacing: 8) {
      leading()
      Text(note)
        .font(.system(size: 11.5))
        .foregroundStyle(SettingsPalette.text3)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(SettingsPalette.fill)
    .settingsSearchable(note)
  }
}

struct SettingsSwitch: View {
  @Binding var isOn: Bool
  var body: some View {
    Toggle("", isOn: $isOn)
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.mini)
  }
}

/// Small push button (`.btn.sm`, `.btn.sm.prom`).
struct SettingsButtonStyle: ButtonStyle {
  var prominent = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .lineLimit(1)
      .foregroundStyle(prominent ? Color.white : SettingsPalette.text)
      .padding(.horizontal, 9)
      .frame(height: 24)
      .background(
        prominent ? AppColor.accent : SettingsPalette.control,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay {
        if !prominent {
          RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SettingsPalette.controlLine, lineWidth: 0.5)
        }
      }
      .shadow(color: .black.opacity(prominent ? 0 : 0.06), radius: 0.75, y: 1)
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
      .contentShape(Rectangle())
  }
}

/// Single-line text field surface (`.tf`).
struct SettingsTextFieldStyle: ViewModifier {
  var height: CGFloat = 24
  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .font(.system(size: 12.5))
      .padding(.horizontal, 8)
      .frame(height: height)
      .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SettingsPalette.controlLine, lineWidth: 0.5))
  }
}

/// Slider + value column (`.rng`).
struct SettingsSlider: View {
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double? = nil
  let format: (Double) -> String
  var onCommit: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      // Snap manually: a stepped NSSlider draws tick marks the V3 track does not have.
      Slider(
        value: Binding(
          get: { value },
          set: { newValue in
            guard let step, step > 0 else { value = newValue; return }
            let snapped = (newValue / step).rounded() * step
            value = min(range.upperBound, max(range.lowerBound, snapped))
          }),
        in: range
      ) { editing in if !editing { onCommit() } }
      .labelsHidden()
      .controlSize(.small)
      Text(format(value))
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(SettingsPalette.text2)
        .frame(minWidth: 38, alignment: .trailing)
    }
    .frame(width: 260)
  }
}

/// Green "granted" pill (`.tag.ok`).
struct SettingsStatusTag: View {
  let text: String
  var symbol: String? = "checkmark"
  var body: some View {
    HStack(spacing: 4) {
      if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
      Text(text)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(SettingsPalette.ok)
    .padding(.horizontal, 7)
    .frame(height: 20)
    .background(SettingsPalette.okBackground, in: RoundedRectangle(cornerRadius: 5))
  }
}
