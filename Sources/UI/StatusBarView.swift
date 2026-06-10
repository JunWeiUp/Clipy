import SwiftUI

struct StatusBarView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs / 2)
    }
}
