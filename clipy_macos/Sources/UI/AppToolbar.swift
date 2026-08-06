import SwiftUI

struct AppToolbarButton: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String?
    let action: () -> Void
}

struct AppToolbar: View {
    let leading: [AppToolbarButton]
    var trailing: [AppToolbarButton] = []

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            ForEach(leading) { button in
                toolbarButton(button)
            }
            Spacer(minLength: 0)
            ForEach(trailing) { button in
                toolbarButton(button)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        // 顶部让出标题栏高度，功能按钮位于交通灯按钮下方一行。
        .padding(.top, AppTitleBar.height)
        .padding(.bottom, AppSpacing.xs)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func toolbarButton(_ button: AppToolbarButton) -> some View {
        if let systemImage = button.systemImage {
            Button(action: button.action) {
                Label(button.title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
        } else {
            Button(button.title, action: button.action)
                .buttonStyle(.bordered)
        }
    }
}
