import SwiftUI

enum AppColor {
    static var windowChrome: Color { Color(nsColor: .windowBackgroundColor) }
    static var windowBackground: Color { Color(nsColor: .textBackgroundColor) }

    /// 统一强调色：单一冷色，遵循「One accent color」。
    static var accent: Color { Color(nsColor: .controlAccentColor) }
    static var separator: Color { Color(nsColor: .separatorColor) }
    static var secondaryLabel: Color { Color(nsColor: .secondaryLabelColor) }
}

/// 统一的窗口顶栏容器，与 AppToolbar 使用相同背景与内边距。
struct AppWindowHeader<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, AppSpacing.sm)
            // 顶部让出标题栏高度，内容位于交通灯按钮下方一行。
            .padding(.top, AppTitleBar.height)
            .padding(.bottom, AppSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
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
        // 内容区透出窗口底层（underWindowBackground）的毛玻璃。
        .background(Color.clear)
    }
}

/// 表单类窗口的统一布局
struct AppFormWindowLayout<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .formStyle(.grouped)
            // 顶部让出标题栏高度，避免 grouped 表单头被交通灯按钮遮挡。
            .padding(.top, AppTitleBar.height)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.bottom, AppSpacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
    }
}
