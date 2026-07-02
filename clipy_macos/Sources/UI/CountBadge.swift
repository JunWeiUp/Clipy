import SwiftUI

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: AppFont.captionSize, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, AppSpacing.xs)
            .padding(.vertical, 2)
            .background(Color.accentColor)
            .clipShape(Capsule())
    }
}

struct LevelBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(width: 50)
            .background(color)
            .cornerRadius(AppCornerRadius.small)
    }
}
