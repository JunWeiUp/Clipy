import SwiftUI

struct EmptyStateView: View {
    let message: String
    var symbol: String = "tray"

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(message)
            .font(AppFont.emptyState)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.xl)
    }
}
