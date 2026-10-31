import SwiftUI

extension Notification.Name {
  static let appSettingsNavigate = Notification.Name("appSettingsNavigate")
}

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
  var statusHint: String? = nil
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
        StatusBarView(text: statusText, hint: statusHint)
      }
    }
    .background(AppColor.windowBackground)
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

// Settings layout (AppSettingsLayout, AppSettingsPage, search) lives in AppSettingsLayout.swift.
