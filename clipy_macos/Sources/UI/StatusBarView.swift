import SwiftUI

struct StatusBarView: View {
    let text: String
    var hint: String? = nil

    var body: some View {
        HStack {
            Text(text)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let hint {
                Text(hint)
                    .font(AppFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 7)
        .background(AppColor.groupedBackground)
    }
}
