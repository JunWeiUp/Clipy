import SwiftUI

struct HighlightedText: View {
    let text: String
    let highlightRanges: [Range<String.Index>]
    var font: Font = AppFont.body
    var lineLimit: Int = 1

    var body: some View {
        Text(attributedText)
            .font(font)
            .lineLimit(lineLimit)
    }

    private var attributedText: AttributedString {
        var attributed = AttributedString(text)
        for range in highlightRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = .yellow.opacity(0.45)
            attributed[lower..<upper].foregroundColor = .primary
        }
        return attributed
    }
}
