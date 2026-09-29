import CoreGraphics
import Foundation

enum NativeScreenshotRedactionCategory: String, CaseIterable {
    case credential
    case paymentCard
    case email
    case phone

    var title: String {
        switch self {
        case .credential: return "Credential"
        case .paymentCard: return "Payment card"
        case .email: return "Email address"
        case .phone: return "Phone number"
        }
    }

    var chineseTitle: String {
        switch self {
        case .credential: return "凭据"
        case .paymentCard: return "支付卡号"
        case .email: return "电子邮箱"
        case .phone: return "电话号码"
        }
    }
}

struct NativeScreenshotRedactionSuggestion: Identifiable {
    let id: UUID
    let category: NativeScreenshotRedactionCategory
    /// A complete OCR line, deliberately expanded because OCR character boxes
    /// can be approximate. The user reviews this area before any pixels change.
    let bounds: CGRect
    /// No raw sensitive text is retained in the suggestion or shown in its label.
    let lineNumber: Int

    init(id: UUID = UUID(), category: NativeScreenshotRedactionCategory,
         bounds: CGRect, lineNumber: Int) {
        self.id = id
        self.category = category
        self.bounds = bounds
        self.lineNumber = lineNumber
    }
}

/// Conservative suggestions only. Matching never modifies image pixels.
enum NativeScreenshotRedactionDetector {
    private static let credential = try! NSRegularExpression(
        pattern: #"(?:password|passwd|api[_ -]?key|secret|token|密码|密钥)\s*[:：=]\s*\S{4,}"#,
        options: [.caseInsensitive])
    private static let email = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive])
    private static let paymentCandidate = try! NSRegularExpression(
        pattern: #"(?:\d[ -]?){13,19}"#)
    private static let phone = try! NSRegularExpression(
        pattern: #"\+?\d[\d .()\-]{7,}\d"#)

    static func suggest(
        from lines: [NativeScreenshotRecognizedText],
        imageSize: CGSize
    ) -> [NativeScreenshotRedactionSuggestion] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        let canvas = CGRect(origin: .zero, size: imageSize)
        return lines.enumerated().compactMap { index, line in
            guard let category = category(for: line.text) else { return nil }
            let padding = max(4, line.bounds.height * 0.14)
            let padded = line.bounds.standardized.insetBy(dx: -padding, dy: -padding)
                .intersection(canvas).integral
            guard !padded.isNull, !padded.isEmpty else { return nil }
            return NativeScreenshotRedactionSuggestion(
                category: category, bounds: padded, lineNumber: index + 1)
        }
    }

    static func category(for text: String) -> NativeScreenshotRedactionCategory? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if credential.firstMatch(in: text, range: range) != nil { return .credential }
        if paymentCandidate.matches(in: text, range: range).contains(where: { match in
            guard let matched = Range(match.range, in: text) else { return false }
            return isValidPaymentCard(String(text[matched]))
        }) { return .paymentCard }
        if email.firstMatch(in: text, range: range) != nil { return .email }
        if let match = phone.firstMatch(in: text, range: range),
           let matched = Range(match.range, in: text) {
            let digits = text[matched].filter(\.isNumber)
            if (9...15).contains(digits.count) { return .phone }
        }
        return nil
    }

    private static func isValidPaymentCard(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var total = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index.isMultiple(of: 2) {
                total += digit
            } else {
                let doubled = digit * 2
                total += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return total.isMultiple(of: 10)
    }
}

enum NativeScreenshotRedactionError: Error {
    case invalidImageSize
    case bitmapContextUnavailable
    case imageCreationFailed
}

/// Source image stays untouched. `previewImage` only draws translucent review
/// markers; `confirm` is the sole operation that burns opaque masks into a copy.
struct NativeScreenshotRedactionReview {
    let sourceImage: CGImage
    let suggestions: [NativeScreenshotRedactionSuggestion]

    var allSuggestionIDs: Set<UUID> { Set(suggestions.map(\.id)) }

    func previewImage(selectedIDs: Set<UUID>) throws -> CGImage {
        try render { context, height in
            for suggestion in suggestions {
                guard let box = outputRect(suggestion.bounds, height: height) else { continue }
                context.saveGState()
                context.setStrokeColor(CGColor(colorSpace: colorSpace,
                                               components: [1, 0.15, 0.08, 1])!)
                context.setLineWidth(2)
                if selectedIDs.contains(suggestion.id) {
                    context.setFillColor(CGColor(colorSpace: colorSpace,
                                                 components: [1, 0.15, 0.08, 0.30])!)
                    context.fill(box)
                } else {
                    context.setLineDash(phase: 0, lengths: [5, 4])
                }
                context.stroke(box)
                context.restoreGState()
            }
        }
    }

    /// Explicit user confirmation produces a new, flattened image. Unknown IDs
    /// are ignored; an empty selection returns an unchanged copy of the source.
    func confirm(selectedIDs: Set<UUID>) throws -> CGImage {
        try render { context, height in
            context.setFillColor(CGColor(colorSpace: colorSpace,
                                         components: [0, 0, 0, 1])!)
            context.setAlpha(1)
            for suggestion in suggestions where selectedIDs.contains(suggestion.id) {
                if let box = outputRect(suggestion.bounds, height: height) {
                    context.fill(box)
                }
            }
        }
    }

    private var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    private func render(_ draw: (CGContext, CGFloat) -> Void) throws -> CGImage {
        let width = sourceImage.width
        let height = sourceImage.height
        guard width > 0, height > 0, width <= 40_000, height <= 40_000,
              width <= 160_000_000 / height else {
            throw NativeScreenshotRedactionError.invalidImageSize
        }
        let sourceSpace = sourceImage.colorSpace
        let space = sourceSpace?.model == .rgb ? sourceSpace! : colorSpace
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw NativeScreenshotRedactionError.bitmapContextUnavailable }
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        draw(context, CGFloat(height))
        guard let output = context.makeImage() else {
            throw NativeScreenshotRedactionError.imageCreationFailed
        }
        return output
    }

    private func outputRect(_ topLeft: CGRect, height: CGFloat) -> CGRect? {
        guard topLeft.origin.x.isFinite, topLeft.origin.y.isFinite,
              topLeft.width.isFinite, topLeft.height.isFinite else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let rect = topLeft.standardized.intersection(bounds).integral
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return CGRect(x: rect.minX, y: height - rect.maxY,
                      width: rect.width, height: rect.height)
    }
}
