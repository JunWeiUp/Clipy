import SwiftUI

enum AppColor {
  static var windowChrome: Color { Color(nsColor: .windowBackgroundColor) }
  static var windowBackground: Color { Color(nsColor: .textBackgroundColor) }
  static var controlBackground: Color { Color(nsColor: .controlBackgroundColor) }
  static var groupedBackground: Color { Color(nsColor: .windowBackgroundColor) }

  /// 统一强调色：单一冷色，遵循「One accent color」。
  static var accent: Color { Color(nsColor: .controlAccentColor) }
  static var separator: Color { Color(nsColor: .separatorColor) }
  static var secondaryLabel: Color { Color(nsColor: .secondaryLabelColor) }
}

/// 统一的窗口顶栏容器，与 AppToolbar 使用相同背景与内边距。
struct AppWindowHeader<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .padding(.horizontal, AppSpacing.md)
      .padding(.vertical, AppSpacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if reduceTransparency { AppColor.windowChrome } else { Rectangle().fill(.bar) }
      }
  }
}

/// 列表类窗口的统一布局：顶栏 → 分隔线 → 内容 → 分隔线 → 状态栏
struct AppListWindowLayout<Toolbar: View, Content: View>: View {
  var statusText: String?
  @ViewBuilder let toolbar: () -> Toolbar
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      toolbar()
      Divider()
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let statusText {
        Divider()
        StatusBarView(text: statusText)
      }
    }
    .background(AppColor.windowBackground)
  }
}

/// 表单类窗口的统一布局
struct AppFormWindowLayout<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .padding(AppSpacing.sm)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(AppColor.groupedBackground)
  }
}

struct AppInputSurface: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, AppSpacing.sm)
      .padding(.vertical, 9)
      .background(
        AppColor.controlBackground, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppCornerRadius.medium).strokeBorder(
          AppColor.separator.opacity(0.45), lineWidth: 0.5))
  }
}

struct AppSettingsPage: Identifiable {
  let id: String
  let title: String
  let symbol: String
}

private struct AppSettingsPositionKey: PreferenceKey {
  static var defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

/// A single scrollable settings document. Sidebar clicks jump to a section;
/// scrolling updates the highlighted category without triggering another jump.
struct AppSettingsLayout<Content: View>: View {
  @Binding var selection: String
  let pages: [AppSettingsPage]
  @ViewBuilder let content: (String) -> Content
  @StateObject private var navigator = AppSettingsNavigator()
  @State private var pendingJump: String?
  @State private var jumpReset: DispatchWorkItem?

  var body: some View {
    Group {
      HStack(spacing: 0) {
        List(
          selection: Binding<String?>(
            get: { selection },
            set: { value in
              guard let value else { return }
              selection = value
              pendingJump = value
              jumpReset?.cancel()
              navigator.scroll(to: value)
              let reset = DispatchWorkItem { pendingJump = nil }
              jumpReset = reset
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: reset)
            })
        ) {
          ForEach(pages) { page in
            Label {
              Text(page.title).lineLimit(1)
            } icon: {
              Image(systemName: page.symbol).frame(width: 20)
            }
            .font(AppFont.body)
            .padding(.vertical, 6)
            .tag(page.id)
          }
        }
        .listStyle(.sidebar)
        .padding(.top, AppSpacing.sm)
        .frame(width: 168)
        Divider()
        Form {
          ForEach(pages) { page in
            Section {
              content(page.id)
            } header: {
              Text(page.title)
                .font(AppFont.title)
                .accessibilityAddTraits(.isHeader)
                .foregroundStyle(.primary)
                .padding(.top, AppSpacing.sm)
                .padding(.bottom, AppSpacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppSettingsScrollAnchor(id: page.id, navigator: navigator))
                .background(
                  GeometryReader { geometry in
                    Color.clear.preference(
                      key: AppSettingsPositionKey.self,
                      value: [page.id: geometry.frame(in: .named("settingsDocument")).minY])
                  })
            }
          }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .coordinateSpace(name: "settingsDocument")
        .onPreferenceChange(AppSettingsPositionKey.self) { positions in
          guard pendingJump == nil else { return }
          let current =
            navigator.isAtEnd
            ? pages.last
            : (pages.last { (positions[$0.id] ?? .infinity) <= 80 } ?? pages.first)
          if let current, selection != current.id { selection = current.id }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.groupedBackground)
      }
    }
    .onDisappear {
      jumpReset?.cancel()
      pendingJump = nil
    }
  }
}

/// AppKit scrolling also works inside the grouped macOS Form on macOS 13,
/// where ScrollViewReader does not consistently resolve section header IDs.
private final class AppSettingsNavigator: ObservableObject {
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

  func scroll(to id: String) {
    guard let view = anchors[id]?.view,
      let scroll = view.enclosingScrollView,
      let document = scroll.documentView
    else { return }
    let clip = scroll.contentView
    let rect = document.convert(view.bounds, from: view)
    let targetY = document.isFlipped ? rect.minY - 20 : rect.maxY - clip.bounds.height + 20
    let maximumY = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
    clip.scroll(
      to: NSPoint(
        x: clip.bounds.minX,
        y: min(maximumY, max(document.bounds.minY, targetY))))
    scroll.reflectScrolledClipView(clip)
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
