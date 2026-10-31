import Cocoa

/// Real NSView container for a row (horizontal) or column (vertical) of ToolbarButtonViews.
/// Dark rounded background matching the existing toolbar look.
class ToolbarStripView: NSView {

    enum Orientation { case horizontal, vertical }

    var orientation: Orientation { didSet { layoutButtons() } }
    private(set) var buttonViews: [ToolbarButtonView] = []
    /// Set to true in editor mode so gap clicks pass through to the image beneath.
    var passesThrough = false
    var usesWindowAppearance = false
    /// Suppress hover visuals/callbacks while a toolbar-initiated drag is moving
    /// the whole toolbar panel under the cursor.
    var suppressesHover = false {
        didSet {
            if suppressesHover {
                for bv in buttonViews { bv.setHovered(false) }
            }
        }
    }

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?

    private let padding: CGFloat = 4
    private let spacing: CGFloat = 2

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Strip-level tracking area: clears all button hovers when the cursor leaves
    /// the whole strip (covers the case where AppKit drops the last button's
    /// mouseExited in a non-activating panel).
    private var stripTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = stripTracking { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        stripTracking = ta
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) {
        clearInteractionState(clearPressed: !suppressesHover)
    }

    /// Rebuild buttons from ToolbarButton data.
    func setButtons(_ buttons: [ToolbarButton]) {
        for bv in buttonViews { bv.removeFromSuperview() }
        buttonViews.removeAll()

        for data in buttons {
            let bv = ToolbarButtonView(action: data.action, sfSymbol: data.sfSymbol, tooltip: data.tooltip)
            bv.isOn = data.isSelected
            bv.tintColor = data.tintColor
            bv.swatchColor = data.bgColor
            bv.hasContextMenu = data.hasContextMenu
            bv.label = data.label
            bv.style = data.style
            bv.groupStart = data.groupStart
            bv.fillColor = data.fillColor
            bv.onClick = { [weak self] action in self?.onClick?(action) }
            bv.onRightClick = { [weak self] action, view in self?.onRightClick?(action, view) }
            bv.onHover = { [weak self] action, hovered in self?.onHover?(action, hovered) }
            addSubview(bv)
            buttonViews.append(bv)
        }
        layoutButtons()
    }

    /// Clear hover on every button except `keep`. Called when a button is
    /// entered, to defensively reset any sibling AppKit failed to send
    /// mouseExited to (happens in non-activating glass chrome panels).
    func clearHover(except keep: ToolbarButtonView) {
        if suppressesHover { return }
        for bv in buttonViews where bv !== keep { bv.setHovered(false) }
    }

    func clearInteractionState(
        suppressHoverUntilMouseMoved suppress: Bool = false,
        clearPressed: Bool = true
    ) {
        for bv in buttonViews {
            bv.clearInteractionState(
                suppressHoverUntilMouseMoved: suppress,
                clearPressed: clearPressed)
        }
    }

    /// Update button state without rebuilding views.
    func updateState(from buttons: [ToolbarButton]) {
        for (i, data) in buttons.enumerated() where i < buttonViews.count {
            buttonViews[i].configure(with: data)
        }
        layoutButtons()
    }

    /// Bar chrome: `.standard` icon strip, or the V3 labelled capture / recording bars.
    enum BarStyle { case standard, captureBar, recordBar }
    var barStyle: BarStyle = .standard { didSet { if oldValue != barStyle { layoutButtons(); needsDisplay = true } } }
    private var separatorXs: [CGFloat] = []

    private func layoutButtons() {
        let btnSize = ToolbarButtonView.size
        let count = CGFloat(buttonViews.count)
        separatorXs = []
        guard count > 0 else {
            frame.size = .zero
            return
        }

        let labelled = barStyle != .standard || buttonViews.contains { $0.style != .icon || $0.groupStart }
        if orientation == .horizontal, labelled {
            let pad: CGFloat = barStyle == .captureBar ? 7 : (barStyle == .recordBar ? 6 : padding)
            let gap: CGFloat = barStyle == .captureBar ? 6 : (barStyle == .recordBar ? 4 : spacing)
            let sizes = buttonViews.map { $0.preferredSize }
            let h = (sizes.map(\.height).max() ?? btnSize) + pad * 2
            var x = pad
            for (i, bv) in buttonViews.enumerated() {
                if bv.groupStart && i > 0 {
                    // ".s" / ".sep": 4pt margins around a hairline, plus the regular gap.
                    let sepX = x + 4
                    separatorXs.append(sepX)
                    x = sepX + 0.5 + 4 + gap
                }
                bv.frame = NSRect(x: x, y: (h - sizes[i].height) / 2, width: sizes[i].width, height: sizes[i].height)
                x += sizes[i].width + gap
            }
            frame.size = NSSize(width: x - gap + pad, height: h)
            needsDisplay = true
            return
        }

        switch orientation {
        case .horizontal:
            let w = count * btnSize + max(0, count - 1) * spacing + padding * 2
            let h = btnSize + padding * 2
            frame.size = NSSize(width: w, height: h)
            // Left-align buttons
            for (i, bv) in buttonViews.enumerated() {
                bv.frame.origin = NSPoint(x: padding + CGFloat(i) * (btnSize + spacing), y: padding)
            }
        case .vertical:
            let w = btnSize + padding * 2
            let h = count * btnSize + max(0, count - 1) * spacing + padding * 2
            frame.size = NSSize(width: w, height: h)
            for (i, bv) in buttonViews.enumerated() {
                // First button at top
                bv.frame.origin = NSPoint(x: padding, y: h - padding - btnSize - CGFloat(i) * (btnSize + spacing))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // The V3 editor hosts the strip inside its title-bar row, which draws its own material.
        if usesWindowAppearance { return }
        if barStyle != .standard {
            // mac-capture.html .capbar / mac-recording.html .ctl: dark glass, hairline edge.
            let radius: CGFloat = barStyle == .captureBar ? 16 : 14
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            NSColor(srgbRed: 30 / 255, green: 31 / 255, blue: 36 / 255, alpha: 0.9).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        } else {
            ToolbarLayout.bgColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        }
        let sepH: CGFloat = barStyle == .captureBar ? 34 : (barStyle == .recordBar ? 24 : 20)
        NSColor.white.withAlphaComponent(0.18).setFill()
        for x in separatorXs {
            NSRect(x: x, y: (bounds.height - sepH) / 2, width: 0.5, height: sepH).fill()
        }
    }

    // Consume clicks on gaps between buttons so they don't fall through to OverlayView.
    // In editor mode (passesThrough), let gap clicks pass through so drawing works
    // over the toolbar area.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let result = super.hitTest(point), result !== self { return result }
        if passesThrough { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
