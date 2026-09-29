import CoreGraphics
import Foundation

/// Coordinates are image pixels with the origin at the upper-left corner.
/// A color sampler is an editing operation and is intentionally absent from exports.
enum NativeScreenshotAnnotationKind: String, CaseIterable {
    case pencil, line, arrow, rectangle, filledRectangle, ellipse
    case highlighter, richText, number, stamp
    case pixelate, blur, solidCensor, eraseCensor
    case magnifier, ruler, colorSampler, spotlight
}

struct NativeScreenshotColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let black = NativeScreenshotColor(red: 0, green: 0, blue: 0)
    static let white = NativeScreenshotColor(red: 1, green: 1, blue: 1)
    static let red = NativeScreenshotColor(red: 1, green: 0, blue: 0)
    static let yellow = NativeScreenshotColor(red: 1, green: 0.88, blue: 0)

    var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [red.clamped01, green.clamped01, blue.clamped01, alpha.clamped01]
        )!
    }
}

private extension CGFloat {
    var clamped01: CGFloat { Swift.min(1, Swift.max(0, isFinite ? self : 0)) }
}

struct NativeScreenshotAnnotationStyle {
    var strokeColor: NativeScreenshotColor = .red
    var fillColor: NativeScreenshotColor = .white
    var lineWidth: CGFloat = 3
    var opacity: CGFloat = 1
    /// Translation text covers the source line with its sampled background;
    /// keeping this on the text annotation makes the whole block move together.
    var fillsTextBox: Bool = false

    init(
        strokeColor: NativeScreenshotColor = .red,
        fillColor: NativeScreenshotColor = .white,
        lineWidth: CGFloat = 3,
        opacity: CGFloat = 1,
        fillsTextBox: Bool = false
    ) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.fillsTextBox = fillsTextBox
    }
}

struct NativeScreenshotStrokeSample {
    var point: CGPoint
    /// 0...1. A constant 1 produces an ordinary mouse stroke.
    var pressure: CGFloat

    init(_ point: CGPoint, pressure: CGFloat = 1) {
        self.point = point
        self.pressure = pressure
    }
}

enum NativeScreenshotPencilSmoothing: Int, CaseIterable {
    case none, smooth, refined
}

enum NativeScreenshotArrowStyle: Int, CaseIterable {
    case solid, dashed, curved, curvedDashed, sketch, doubleHeaded
}

struct NativeScreenshotTextRun {
    var text: String
    var color: NativeScreenshotColor
    var fontName: String?
    var fontSize: CGFloat
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var outlineWidth: CGFloat
    var backgroundColor: NativeScreenshotColor?

    init(
        text: String,
        color: NativeScreenshotColor = .black,
        fontName: String? = nil,
        fontSize: CGFloat = 24,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        outlineWidth: CGFloat = 0,
        backgroundColor: NativeScreenshotColor? = nil
    ) {
        self.text = text
        self.color = color
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.outlineWidth = outlineWidth
        self.backgroundColor = backgroundColor
    }
}

enum NativeScreenshotStamp {
    case emoji(String)
    case image(CGImage)
}

enum NativeScreenshotAnnotationContent {
    case pencil(samples: [NativeScreenshotStrokeSample], smoothing: NativeScreenshotPencilSmoothing)
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint, style: NativeScreenshotArrowStyle)
    case rectangle(CGRect)
    case filledRectangle(CGRect)
    case ellipse(CGRect)
    case highlighter(points: [CGPoint])
    case richText(rect: CGRect, runs: [NativeScreenshotTextRun])
    case number(center: CGPoint, value: Int)
    case stamp(rect: CGRect, content: NativeScreenshotStamp)
    case pixelate(rect: CGRect, blockSize: CGFloat)
    case blur(rect: CGRect, radius: CGFloat)
    case solidCensor(CGRect)
    /// Removes pixels from the resulting image, including the original image.
    case eraseCensor(CGRect)
    case magnifier(source: CGRect, destination: CGRect)
    case ruler(start: CGPoint, end: CGPoint)
    case colorSampler(CGPoint)
    case spotlight(CGRect)

    var kind: NativeScreenshotAnnotationKind {
        switch self {
        case .pencil: return .pencil
        case .line: return .line
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .filledRectangle: return .filledRectangle
        case .ellipse: return .ellipse
        case .highlighter: return .highlighter
        case .richText: return .richText
        case .number: return .number
        case .stamp: return .stamp
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .solidCensor: return .solidCensor
        case .eraseCensor: return .eraseCensor
        case .magnifier: return .magnifier
        case .ruler: return .ruler
        case .colorSampler: return .colorSampler
        case .spotlight: return .spotlight
        }
    }

    func translated(by offset: CGSize) -> Self {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.width, y: p.y + offset.height) }
        func rect(_ r: CGRect) -> CGRect { r.offsetBy(dx: offset.width, dy: offset.height) }
        switch self {
        case let .pencil(samples, smoothing):
            return .pencil(samples: samples.map { .init(point($0.point), pressure: $0.pressure) }, smoothing: smoothing)
        case let .line(start, end): return .line(start: point(start), end: point(end))
        case let .arrow(start, end, style): return .arrow(start: point(start), end: point(end), style: style)
        case let .rectangle(r): return .rectangle(rect(r))
        case let .filledRectangle(r): return .filledRectangle(rect(r))
        case let .ellipse(r): return .ellipse(rect(r))
        case let .highlighter(points): return .highlighter(points: points.map(point))
        case let .richText(r, runs): return .richText(rect: rect(r), runs: runs)
        case let .number(center, value): return .number(center: point(center), value: value)
        case let .stamp(r, content): return .stamp(rect: rect(r), content: content)
        case let .pixelate(r, blockSize): return .pixelate(rect: rect(r), blockSize: blockSize)
        case let .blur(r, radius): return .blur(rect: rect(r), radius: radius)
        case let .solidCensor(r): return .solidCensor(rect(r))
        case let .eraseCensor(r): return .eraseCensor(rect(r))
        case let .magnifier(source, destination):
            return .magnifier(source: rect(source), destination: rect(destination))
        case let .ruler(start, end): return .ruler(start: point(start), end: point(end))
        case let .colorSampler(p): return .colorSampler(point(p))
        case let .spotlight(r): return .spotlight(rect(r))
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        switch self {
        case let .pencil(samples, _): return polylineHit(samples.map(\.point), point, tolerance)
        case let .highlighter(points): return polylineHit(points, point, tolerance)
        case let .line(start, end), let .arrow(start, end, _), let .ruler(start, end):
            return segmentDistance(point, start, end) <= tolerance
        case let .rectangle(rect), let .filledRectangle(rect), let .ellipse(rect),
             let .richText(rect, _), let .stamp(rect, _), let .pixelate(rect, _),
             let .blur(rect, _), let .solidCensor(rect), let .eraseCensor(rect),
             let .spotlight(rect):
            return rect.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case let .magnifier(_, destination):
            return destination.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case let .number(center, _), let .colorSampler(center):
            return hypot(point.x - center.x, point.y - center.y) <= max(16, tolerance)
        }
    }
}

struct NativeScreenshotAnnotation: Identifiable {
    var id: UUID
    var content: NativeScreenshotAnnotationContent
    var style: NativeScreenshotAnnotationStyle
    var isVisible: Bool

    init(
        id: UUID = UUID(),
        content: NativeScreenshotAnnotationContent,
        style: NativeScreenshotAnnotationStyle = .init(),
        isVisible: Bool = true
    ) {
        self.id = id
        self.content = content
        self.style = style
        self.isVisible = isVisible
    }

    var kind: NativeScreenshotAnnotationKind { content.kind }

    func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        isVisible && content.hitTest(point, tolerance: tolerance + max(0, style.lineWidth / 2))
    }
}

private func polylineHit(_ points: [CGPoint], _ point: CGPoint, _ tolerance: CGFloat) -> Bool {
    if points.count == 1 {
        return hypot(point.x - points[0].x, point.y - points[0].y) <= tolerance
    }
    guard points.count > 1 else { return false }
    return zip(points, points.dropFirst()).contains {
        segmentDistance(point, $0.0, $0.1) <= tolerance
    }
}

private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let projection = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + projection * dx), p.y - (a.y + projection * dy))
}
