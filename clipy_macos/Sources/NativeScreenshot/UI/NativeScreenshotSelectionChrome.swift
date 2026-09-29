import AppKit
import CoreGraphics

/// Visual state of the temporary selection frame. Keep it separate from the
/// annotation canvas, which has its own handles and colors.
enum NativeScreenshotSelectionChrome {
    enum Phase {
        case idle
        case hoveringWindow
        case selecting
        case selected
        case scrolling
        case recording
    }

    struct Style {
        let stroke: NSColor
        let fill: NSColor?
        let lineWidth: CGFloat
        let cornerRadius: CGFloat
        let handleDiameter: CGFloat
        let strokeOutside: Bool

        var showsHandles: Bool { handleDiameter > 0 }
    }

    static func style(for phase: Phase, accent: NSColor) -> Style {
        switch phase {
        case .idle:
            return Style(stroke: .clear, fill: nil, lineWidth: 0,
                         cornerRadius: 0, handleDiameter: 0, strokeOutside: false)
        case .hoveringWindow:
            return Style(stroke: .systemBlue.withAlphaComponent(0.85),
                         fill: .systemBlue.withAlphaComponent(0.08), lineWidth: 2,
                         cornerRadius: 4, handleDiameter: 0, strokeOutside: false)
        case .selecting:
            return Style(stroke: accent, fill: nil, lineWidth: 2,
                         cornerRadius: 0, handleDiameter: 0, strokeOutside: false)
        case .selected:
            return Style(stroke: accent, fill: nil, lineWidth: 2,
                         cornerRadius: 0, handleDiameter: 10, strokeOutside: false)
        case .scrolling:
            return Style(stroke: .systemRed, fill: nil, lineWidth: 2.5,
                         cornerRadius: 0, handleDiameter: 0, strokeOutside: false)
        case .recording:
            return Style(stroke: accent.withAlphaComponent(0.8), fill: nil,
                         lineWidth: 1.5, cornerRadius: 0, handleDiameter: 0,
                         strokeOutside: true)
        }
    }

    static func draw(in context: CGContext, rect: CGRect, style: Style) {
        guard !rect.isNull, !rect.isEmpty, style.lineWidth > 0 else { return }
        context.saveGState()
        if let fill = style.fill {
            context.setFillColor(fill.cgColor)
            context.addPath(path(for: rect, cornerRadius: style.cornerRadius))
            context.fillPath()
        }
        let strokeRect = style.strokeOutside
            ? rect.insetBy(dx: -style.lineWidth, dy: -style.lineWidth) : rect
        context.setStrokeColor(style.stroke.cgColor)
        context.setLineWidth(style.lineWidth)
        context.addPath(path(for: strokeRect, cornerRadius: style.cornerRadius))
        context.strokePath()

        if style.showsHandles {
            let diameter = style.handleDiameter
            let anchors = [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)
            ]
            context.setFillColor(style.stroke.cgColor)
            for point in anchors {
                context.fillEllipse(in: CGRect(x: point.x - diameter / 2,
                                               y: point.y - diameter / 2,
                                               width: diameter, height: diameter))
            }
        }
        context.restoreGState()
    }

    private static func path(for rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        if cornerRadius <= 0 { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                      cornerHeight: cornerRadius, transform: nil)
    }
}
