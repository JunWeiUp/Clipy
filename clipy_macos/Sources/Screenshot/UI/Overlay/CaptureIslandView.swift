import Cocoa

/// mac-capture.html / mac-annotation-avoidance.html「统一控制岛」.
///
/// One dark-glass surface drawn *behind* the existing capture chrome (options row,
/// annotation strip, capture bar, shortcut hint). The strips stay siblings in the
/// overlay; OverlayView positions them inside this island's frame, so dragging the
/// island moves the whole group. Moving it never touches selection or annotation
/// coordinates.
///
/// Header row: 「已固定」 badge (left) · grabber (centre) · reset / pin / collapse (right).
/// Collapsed: a pill with grip · current tool · expand.
final class CaptureIslandView: NSView {

    static let headerHeight: CGFloat = 28
    static let padding: CGFloat = 8
    static let collapsedSize = NSSize(width: 100, height: 42)

    var isPinned = false { didSet { if oldValue != isPinned { refreshControls() } } }
    var isCollapsed = false { didSet { if oldValue != isCollapsed { refreshControls() } } }
    /// SF Symbol of the active annotation tool, shown in the collapsed pill.
    var currentToolSymbol: String? { didSet { if oldValue != currentToolSymbol { needsDisplay = true } } }
    /// Local Y of the hairline between the annotation strip and the capture bar (nil = none).
    var separatorY: CGFloat? { didSet { if oldValue != separatorY { needsDisplay = true } } }
    private(set) var isDragging = false { didSet { needsDisplay = true } }

    var onReset: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleCollapse: (() -> Void)?
    /// Drag lifecycle; `onDragMoved` receives the total offset since mouse-down (screen points).
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private let resetButton = IslandIconButton(symbol: "arrow.counterclockwise")
    private let pinButton = IslandIconButton(symbol: "pin")
    private let collapseButton = IslandIconButton(symbol: "arrow.down.right.and.arrow.up.left")
    private var dragStart: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -10)
        resetButton.onClick = { [weak self] in self?.onReset?() }
        pinButton.onClick = { [weak self] in self?.onTogglePin?() }
        collapseButton.onClick = { [weak self] in self?.onToggleCollapse?() }
        [resetButton, pinButton, collapseButton].forEach(addSubview)
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    private var cornerRadius: CGFloat { isCollapsed ? bounds.height / 2 : 18 }

    private func refreshControls() {
        resetButton.toolTip = L("Reset position")
        pinButton.toolTip = isPinned ? L("Unpin position") : L("Pin position")
        pinButton.isActive = isPinned
        pinButton.symbol = isPinned ? "pin.fill" : "pin"
        resetButton.isEnabled = !isPinned
        collapseButton.symbol = isCollapsed
            ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
        collapseButton.toolTip = (isCollapsed ? L("Expand") : L("Collapse")) + "  ⌥⌘T"
        resetButton.isHidden = isCollapsed
        pinButton.isHidden = isCollapsed
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        if isCollapsed {
            collapseButton.frame = NSRect(x: bounds.maxX - 6 - 28, y: (bounds.height - 28) / 2, width: 28, height: 28)
        } else {
            let y = bounds.maxY - 3 - 22
            var x = bounds.maxX - 6 - 24
            for button in [collapseButton, pinButton, resetButton] {
                button.frame = NSRect(x: x, y: y, width: 24, height: 22)
                x -= 26
            }
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(srgbRed: 36 / 255, green: 38 / 255, blue: 46 / 255, alpha: 0.94).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(isDragging ? 0.24 : 0.16).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        if isCollapsed {
            drawGrip(in: NSRect(x: 8, y: 0, width: 16, height: bounds.height))
            let toolRect = NSRect(x: 28, y: (bounds.height - 30) / 2, width: 30, height: 30)
            ToolbarLayout.accentColor.setFill()
            NSBezierPath(roundedRect: toolRect, xRadius: 7, yRadius: 7).fill()
            if let symbol = currentToolSymbol, let image = Self.symbolImage(symbol, size: 15, color: .white) {
                image.draw(in: NSRect(x: toolRect.midX - image.size.width / 2, y: toolRect.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height))
            }
            return
        }

        // Grabber
        let grabber = NSRect(x: bounds.midX - 18, y: bounds.maxY - 7 - 4, width: 36, height: 4)
        let grabberColor: NSColor = isDragging
            ? ToolbarLayout.accentColor
            : NSColor.white.withAlphaComponent(isPinned ? 0.15 : 0.35)
        grabberColor.setFill()
        NSBezierPath(roundedRect: grabber, xRadius: 2, yRadius: 2).fill()

        if isPinned {
            let blue = NSColor(srgbRed: 90 / 255, green: 162 / 255, blue: 1, alpha: 1)
            var x: CGFloat = 12
            if let pin = Self.symbolImage("pin.fill", size: 9, color: blue) {
                pin.draw(in: NSRect(x: x, y: bounds.maxY - 14 - pin.size.height / 2, width: pin.size.width, height: pin.size.height))
                x += pin.size.width + 3
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: blue]
            let text = L("Pinned") as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: x, y: bounds.maxY - 14 - size.height / 2), withAttributes: attrs)
        }

        if let y = separatorY {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSRect(x: Self.padding + 4, y: y, width: bounds.width - (Self.padding + 4) * 2, height: 0.5).fill()
        }
    }

    private func drawGrip(in rect: NSRect) {
        NSColor.white.withAlphaComponent(isPinned ? 0.2 : 0.45).setFill()
        for col in 0..<2 {
            for row in 0..<3 {
                let dot = NSRect(x: rect.midX - 3.5 + CGFloat(col) * 5, y: rect.midY - 6 + CGFloat(row) * 5, width: 2.2, height: 2.2)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    static func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [color]))
        return base.withSymbolConfiguration(config)
    }

    // MARK: Interaction

    private var dragArea: NSRect {
        isCollapsed
            ? NSRect(x: 0, y: 0, width: 26, height: bounds.height)
            : NSRect(x: 0, y: bounds.maxY - Self.headerHeight, width: bounds.width, height: Self.headerHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Any background area of the island drags the group (header is the visual handle).
        guard !isPinned else { return }
        dragStart = NSEvent.mouseLocation
        isDragging = true
        NSCursor.closedHand.set()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        onDragMoved?(NSPoint(x: now.x - start.x, y: now.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        isDragging = false
        onDragEnded?()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        if !isPinned { addCursorRect(dragArea, cursor: .openHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !isPinned && dragArea.contains(p) { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }
}

/// Small header icon button (reset / pin / collapse).
final class IslandIconButton: NSView {
    var symbol: String { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = isEnabled }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor(srgbRed: 90 / 255, green: 162 / 255, blue: 1, alpha: 1)
        if isActive {
            ToolbarLayout.accentColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        } else if hovered && isEnabled {
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let color: NSColor = isActive ? blue
            : NSColor.white.withAlphaComponent(!isEnabled ? 0.25 : (hovered ? 1 : 0.62))
        guard let image = CaptureIslandView.symbolImage(symbol, size: bounds.height > 24 ? 13 : 11.5, color: color) else { return }
        image.draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                              width: image.size.width, height: image.size.height))
    }
}

/// Dashed drop target shown while dragging the island (默认位置 · 底部居中 / 顶部居中).
final class IslandSnapGuideView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var isHit = false { didSet { if oldValue != isHit { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = ToolbarLayout.accentColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        accent.withAlphaComponent(isHit ? 0.16 : 0.06).setFill()
        path.fill()
        accent.withAlphaComponent(isHit ? 1 : 0.6).setStroke()
        path.lineWidth = 1.5
        if !isHit { path.setLineDash([6, 4], count: 2, phase: 0) }
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let text = title as NSString
        let size = text.size(withAttributes: attrs)
        let pill = NSRect(x: bounds.midX - size.width / 2 - 10, y: bounds.midY - 11, width: size.width + 20, height: 22)
        accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2), withAttributes: attrs)
    }
}
