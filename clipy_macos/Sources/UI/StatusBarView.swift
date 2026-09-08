import SwiftUI

struct StatusBarView: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 7)
        .background(AppColor.groupedBackground)
    }
}
