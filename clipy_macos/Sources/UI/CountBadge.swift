import SwiftUI

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: AppFont.captionSize, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.xs)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.07))
            .clipShape(Capsule())
    }
}

struct LevelBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(width: 50)
            .background(color.opacity(0.12))
            .cornerRadius(AppCornerRadius.small)
    }
}
