import SwiftUI

struct EmptyStateView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(AppFont.emptyState)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(AppSpacing.lg)
    }
}
