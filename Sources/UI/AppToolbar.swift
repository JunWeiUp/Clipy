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
            Spacer()
            ForEach(trailing) { button in
                toolbarButton(button)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColor.windowChrome)
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
