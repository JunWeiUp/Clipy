import Cocoa

class CountdownView: NSView {
    var remaining: Int = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let circleRect = bounds.insetBy(dx: 10, dy: 10)

        // Background circle
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        // Ring
        let ringPath = NSBezierPath(ovalIn: circleRect.insetBy(dx: 3, dy: 3))
        ringPath.lineWidth = 3
        NSColor.white.withAlphaComponent(0.6).setStroke()
        ringPath.stroke()

        // Number
        let text = "\(remaining)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 52, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let point = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        text.draw(at: point, withAttributes: attrs)
    }
}
