import Cocoa

/// Transparent fullscreen overlay that draws a selection border rectangle during recording.
/// Shows the user which area is being captured. Click-through (ignoresMouseEvents).
class SelectionBorderOverlay: NSPanel {

    private let borderView: SelectionBorderView

    init(screen: NSScreen) {
        borderView = SelectionBorderView()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 1
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        borderView.frame = NSRect(origin: .zero, size: screen.frame.size)
        borderView.backingScale = screen.backingScaleFactor
        borderView.autoresizingMask = [.width, .height]
        contentView = borderView
    }

    /// Set the selection rect in screen coordinates.
    func setSelectionRect(_ screenRect: NSRect) {
        // Convert screen coords to window-local coords
        let localRect = convertFromScreen(screenRect)
        borderView.selectionRect = localRect
        borderView.needsDisplay = true
    }
}

private class SelectionBorderView: NSView {

    var selectionRect: NSRect = .zero
    var backingScale: CGFloat = 1

    override func draw(_ dirtyRect: NSRect) {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return }

        // mac-recording.html `.rec.live`: 2pt red frame drawn entirely OUTSIDE the
        // selection so it never ends up in the recording (SCStream crops to it).
        let lineW: CGFloat = 2
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: selectionRect.insetBy(dx: -lineW / 2, dy: -lineW / 2))
        path.lineWidth = lineW
        path.stroke()

        // Status tag attached to the frame's top-left edge: "● 正在录制 · W × H".
        let dimensions = "\(Int(selectionRect.width.rounded())) × \(Int(selectionRect.height.rounded()))"
        let text = "\(L("Recording now")) · \(dimensions)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attrs)
        let width = 9 + 7 + 6 + textSize.width + 9
        let x = max(bounds.minX + 4, min(selectionRect.minX - lineW, bounds.maxX - width - 4))
        let y = min(bounds.maxY - 22, selectionRect.maxY + lineW)
        let tag = NSRect(x: x, y: y, width: width, height: 22)
        NSColor.systemRed.setFill()
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: tag.minX, y: tag.minY))
        shape.line(to: NSPoint(x: tag.maxX, y: tag.minY))
        shape.appendArc(withCenter: NSPoint(x: tag.maxX - 6, y: tag.maxY - 6), radius: 6, startAngle: 0, endAngle: 90)
        shape.appendArc(withCenter: NSPoint(x: tag.minX + 6, y: tag.maxY - 6), radius: 6, startAngle: 90, endAngle: 180)
        shape.close()
        shape.fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: tag.minX + 9, y: tag.midY - 3.5, width: 7, height: 7)).fill()
        text.draw(at: NSPoint(x: tag.minX + 22, y: tag.midY - textSize.height / 2), withAttributes: attrs)
    }
}
