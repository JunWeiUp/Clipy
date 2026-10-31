import SwiftUI

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
