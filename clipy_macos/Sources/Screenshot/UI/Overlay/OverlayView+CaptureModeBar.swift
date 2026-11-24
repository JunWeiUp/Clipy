import AVFoundation
import Cocoa
import UniformTypeIdentifiers

// MARK: - V3 idle capture mode bar

/// Dark capture-bar chrome (mac-capture.html `.capbar`) for the idle mode buttons.
final class CaptureModeBarView: NSView {
    private var separatorX: CGFloat = 0
    func layoutButtons() {
        let buttons = subviews.compactMap { $0 as? CaptureModeBarButton }
        var x: CGFloat = 7
        for button in buttons {
            if button.isClose {
                separatorX = x + 4
                x = separatorX + 0.5 + 4 + 6
            }
            let size = button.preferredSize
            button.frame = NSRect(x: x, y: 7 + (50 - size.height) / 2, width: size.width, height: size.height)
            x += size.width + 6
        }
        frame.size = NSSize(width: x - 6 + 7, height: 64)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 16, yRadius: 16)
        NSColor(srgbRed: 30 / 255, green: 31 / 255, blue: 36 / 255, alpha: 0.9).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        NSColor.white.withAlphaComponent(0.18).setFill()
        if separatorX > 0 { NSRect(x: separatorX, y: (bounds.height - 34) / 2, width: 0.5, height: 34).fill() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? self : hit
    }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Icon-over-label mode button (`.capbar .m`) or the round close button (`.x`).
final class CaptureModeBarButton: NSButton {
    let isClose: Bool
    private let symbol: String
    var isOn = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    init(title: String, symbol: String, isClose: Bool) {
        self.isClose = isClose
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize {
        if isClose { return NSSize(width: 32, height: 32) }
        let width = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
        return NSSize(width: max(62, width + 16), height: 50)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        let white = NSColor.white
        let radius: CGFloat = isClose ? bounds.height / 2 : 10
        if isOn || hovering || isHighlighted {
            white.withAlphaComponent(isOn ? 0.14 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let iconColor = isClose ? white.withAlphaComponent(0.7) : white
        if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: isClose ? 14 : 17, weight: .regular)) {
            let tinted = NSImage(size: symbolImage.size, flipped: false) { rect in
                symbolImage.draw(in: rect); iconColor.setFill(); rect.fill(using: .sourceAtop); return true
            }
            let y = isClose ? bounds.midY - symbolImage.size.height / 2
                : (isFlipped ? bounds.midY - symbolImage.size.height - 1 : bounds.midY + 1)
            tinted.draw(in: NSRect(x: bounds.midX - symbolImage.size.width / 2, y: y,
                                   width: symbolImage.size.width, height: symbolImage.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        guard !isClose else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: isOn ? white : white.withAlphaComponent(0.72)]
        let size = (title as NSString).size(withAttributes: attrs)
        let y = isFlipped ? bounds.midY + 3 : bounds.midY - size.height - 3
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y), withAttributes: attrs)
    }
}

/// Non-interactive shortcut reminder (`Space 按住移动选区 · ⇧ 正方形 · ↩ 快速截图 · esc 取消`).
final class CaptureHintView: NSView {
    private let items: [(String, String)]
    /// Island-hosted variant: small dim text on the island glass (mac-capture.html `.island .hint`).
    private let compact: Bool
    private let font: NSFont
    private let keyFont: NSFont
    private var keyHeight: CGFloat { compact ? 16 : 20 }
    private var itemGap: CGFloat { 14 }

    init(items: [(String, String)], compact: Bool = false) {
        self.items = items
        self.compact = compact
        font = NSFont.systemFont(ofSize: compact ? 10.5 : 12)
        keyFont = NSFont.systemFont(ofSize: compact ? 9.5 : 11, weight: .semibold)
        super.init(frame: .zero)
        let inset: CGFloat = compact ? 0 : 12
        var width: CGFloat = inset
        for (index, item) in items.enumerated() {
            width += keyWidth(item.0) + (compact ? 4 : 5) + ceil((item.1 as NSString).size(withAttributes: [.font: font]).width)
            if index < items.count - 1 { width += itemGap }
        }
        frame.size = NSSize(width: width + inset, height: compact ? 18 : 34)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func keyWidth(_ key: String) -> CGFloat {
        max(compact ? 16 : 20, ceil((key as NSString).size(withAttributes: [.font: keyFont]).width) + (compact ? 8 : 12))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if !compact {
            NSColor(srgbRed: 20 / 255, green: 22 / 255, blue: 28 / 255, alpha: 0.72).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        var x: CGFloat = compact ? 0 : 12
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(compact ? 0.5 : 0.85)]
        let keyAttrs: [NSAttributedString.Key: Any] = [.font: keyFont, .foregroundColor: NSColor.white.withAlphaComponent(compact ? 0.75 : 1)]
        for (key, text) in items {
            let kw = keyWidth(key)
            let keyRect = NSRect(x: x, y: (bounds.height - keyHeight) / 2, width: kw, height: keyHeight)
            NSColor.white.withAlphaComponent(compact ? 0.08 : 0.15).setFill()
            NSBezierPath(roundedRect: keyRect, xRadius: 5, yRadius: 5).fill()
            let ks = (key as NSString).size(withAttributes: keyAttrs)
            (key as NSString).draw(at: NSPoint(x: keyRect.midX - ks.width / 2, y: keyRect.midY - ks.height / 2), withAttributes: keyAttrs)
            x += kw + (compact ? 4 : 5)
            let ts = (text as NSString).size(withAttributes: textAttrs)
            (text as NSString).draw(at: NSPoint(x: x, y: (bounds.height - ts.height) / 2), withAttributes: textAttrs)
            x += ceil(ts.width) + itemGap
        }
    }
}
