import SwiftUI

enum AppColor {
    static var windowChrome: Color { Color(nsColor: .windowBackgroundColor) }
    static var windowBackground: Color { Color(nsColor: .textBackgroundColor) }
}

/// 统一的窗口顶栏容器，与 AppToolbar 使用相同背景与内边距。
struct AppWindowHeader<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.windowChrome)
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
            .padding(AppSpacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.windowBackground)
    }
}
