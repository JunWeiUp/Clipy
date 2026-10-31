import Cocoa

/// Real NSView for a single toolbar button. Handles its own hover, press, drawing.
/// Matches the existing dark toolbar look: purple accent, SF Symbols, color swatches.
class ToolbarButtonView: NSView {

    var action: ToolbarButtonAction
    var sfSymbol: String?
    var isOn: Bool = false { didSet { if oldValue != isOn { cachedIcon = nil; needsDisplay = true } } }
    var tintColor: NSColor = ToolbarLayout.iconColor { didSet { cachedIcon = nil; cachedIconIsOn = nil; needsDisplay = true } }
    var swatchColor: NSColor? { didSet { needsDisplay = true } }
    var hasContextMenu: Bool = false
    var label: String? { didSet { needsDisplay = true } }
    var style: ToolbarButtonStyle = .icon { didSet { needsDisplay = true } }
    var groupStart = false
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    /// Mic input level (0–1). When > 0, draws a green fill from the bottom of the button.
    var micLevel: Float = 0 { didSet { if abs(oldValue - micLevel) > 0.005 { needsDisplay = true } } }

    private var isHovered: Bool = false
    var isPressed: Bool = false
    private var trackingArea: NSTrackingArea?
    private var suppressHoverStartPoint: NSPoint?
    private var cachedIcon: NSImage?       // cached tinted SF Symbol for current state
    private var cachedIconIsOn: Bool?       // the isOn state when icon was cached

    /// Shared cross-instance cache: avoids re-rasterizing SF Symbols when toolbar is rebuilt.
    /// NSCache (not a plain Dictionary) so it auto-evicts under memory pressure and is
    /// bounded by `countLimit` — a plain Dictionary grew without bound as the user picked
    /// new colors in the picker (each color is a distinct cache key). Key: "symbolName|isOn|R,G,B".
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    private static func cacheKey(name: String, isOn: Bool, color: NSColor) -> NSString {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: nil)
        return "\(name)|\(isOn)|\(Int(r*255)),\(Int(g*255)),\(Int(b*255))" as NSString
    }

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onMouseDown: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?  // (action, isHovered)

    static let size: CGFloat = 32
    private static let radius: CGFloat = 6

    var tooltipText: String = ""

    init(action: ToolbarButtonAction, sfSymbol: String?, tooltip: String) {
        self.action = action
        self.sfSymbol = sfSymbol
        self.tooltipText = tooltip
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cachedIcon = nil
        cachedIconIsOn = nil
        needsDisplay = true
    }


    func configure(with data: ToolbarButton) {
        action = data.action
        isOn = data.isSelected
        tintColor = data.tintColor
        swatchColor = data.bgColor
        sfSymbol = data.sfSymbol
        tooltipText = data.tooltip
        hasContextMenu = data.hasContextMenu
        label = data.label
        style = data.style
        groupStart = data.groupStart
        fillColor = data.fillColor
        if case .micAudio = action {
            // Preserve the live mic meter while this reused view is still the
            // mic button.
        } else {
            micLevel = 0
        }
        // Only the move button uses onMouseDown for synchronous drag tracking.
        // Reset it when a reused slot changes meaning; OverlayView assigns it
        // again to the current move button after updating the strip.
        onMouseDown = nil
        dragForwardTarget = nil
        forwardingDrag = false
        isPressed = false
        needsDisplay = true
    }

    // MARK: - Labelled styles (V3 capture / recording bars)

    private static let labelFont = NSFont.systemFont(ofSize: 12.5)
    private static let modeFont = NSFont.systemFont(ofSize: 11)
    private static let primaryFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    private static let toggleFont = NSFont.systemFont(ofSize: 12)

    /// Natural size for the current style (icon buttons stay 32×32).
    var preferredSize: NSSize {
        func textWidth(_ font: NSFont) -> CGFloat {
            ceil(((label ?? "") as NSString).size(withAttributes: [.font: font]).width)
        }
        switch style {
        case .icon: return NSSize(width: Self.size, height: Self.size)
        case .mode: return NSSize(width: max(62, textWidth(Self.modeFont) + 16), height: 50)
        case .option: return NSSize(width: 10 + 16 + 6 + textWidth(Self.labelFont) + 10, height: 32)
        case .primary:
            let height: CGFloat = fillColor == nil ? 40 : 36
            let pad: CGFloat = fillColor == nil ? 18 : 14
            return NSSize(width: pad + 16 + 7 + textWidth(Self.primaryFont) + pad, height: height)
        case .toggle: return NSSize(width: 10 + 17 + 6 + textWidth(Self.toggleFont) + 10, height: 36)
        case .square: return NSSize(width: 36, height: 36)
        case .close: return NSSize(width: 32, height: 32)
        }
    }

    private func symbolImage(pointSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
        guard let name = sfSymbol,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: tooltipText)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) else { return nil }
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func drawLabelled() {
        let white = NSColor.white
        var background: NSColor?
        switch style {
        case .primary:
            let base = fillColor ?? ToolbarLayout.accentColor
            background = isPressed ? base.withAlphaComponent(0.75) : (isHovered ? base.withAlphaComponent(0.9) : base)
        case .mode, .toggle, .square:
            if isOn { background = white.withAlphaComponent(isPressed ? 0.2 : 0.14) }
            else if isHovered || isPressed { background = white.withAlphaComponent(0.08) }
        default:
            if isHovered || isPressed { background = white.withAlphaComponent(0.1) }
        }
        let radius: CGFloat
        switch style {
        case .mode, .primary: radius = 10
        case .option: radius = 8
        case .toggle, .square: radius = 9
        case .close: radius = bounds.height / 2
        case .icon: radius = Self.radius
        }
        if let background {
            background.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let title = label ?? ""
        switch style {
        case .mode:
            let iconColor = tintColor == ToolbarLayout.iconColor ? white : tintColor
            let textColor = isOn ? white : white.withAlphaComponent(0.72)
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.modeFont, .foregroundColor: textColor]
            let textSize = (title as NSString).size(withAttributes: attrs)
            if let icon = symbolImage(pointSize: 17, color: iconColor) {
                icon.draw(in: NSRect(x: bounds.midX - icon.size.width / 2, y: bounds.midY + 1, width: icon.size.width, height: icon.size.height))
            }
            (title as NSString).draw(at: NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height - 3), withAttributes: attrs)
        case .option, .toggle, .primary:
            let font = style == .primary ? Self.primaryFont : (style == .toggle ? Self.toggleFont : Self.labelFont)
            let textColor: NSColor = style == .primary ? white
                : style == .toggle ? (isOn ? white : white.withAlphaComponent(0.55))
                : white.withAlphaComponent(0.85)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let textSize = (title as NSString).size(withAttributes: attrs)
            let iconPoint: CGFloat = style == .toggle ? 15 : (style == .primary ? 14 : 14)
            let iconColor = (style == .option || style == .primary) ? textColor
                : (tintColor == ToolbarLayout.iconColor ? textColor : tintColor)
            let icon: NSImage? = (style == .primary && sfSymbol == "_record.dot") ? nil
                : symbolImage(pointSize: iconPoint, weight: style == .primary ? .semibold : .regular, color: iconColor)
            let iconW = icon?.size.width ?? 12
            let gap: CGFloat = style == .primary ? 7 : 6
            var x = (bounds.width - (iconW + gap + textSize.width)) / 2
            if let icon {
                icon.draw(in: NSRect(x: x, y: bounds.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            } else {
                // Recording "start" dot (mac-recording.html .start i.dot).
                let dot = NSRect(x: x, y: bounds.midY - 6, width: 12, height: 12)
                white.withAlphaComponent(0.35).setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -2, dy: -2)).fill()
                white.setFill(); NSBezierPath(ovalIn: dot).fill()
            }
            x += iconW + gap
            (title as NSString).draw(at: NSPoint(x: x, y: bounds.midY - textSize.height / 2), withAttributes: attrs)
        case .square, .close:
            let color = style == .close ? white.withAlphaComponent(0.7) : (tintColor == ToolbarLayout.iconColor ? white.withAlphaComponent(0.9) : tintColor)
            if let icon = symbolImage(pointSize: style == .close ? 14 : 16, color: color) {
                icon.draw(in: NSRect(x: bounds.midX - icon.size.width / 2, y: bounds.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            }
        case .icon:
            break
        }
        if hasContextMenu, style == .mode || style == .toggle || style == .square {
            // Corner triangle (".ctx::after").
            let s: CGFloat = 4
            let path = NSBezierPath()
            if style == .mode {
                path.move(to: NSPoint(x: bounds.maxX - 6 - s, y: bounds.maxY - 6))
                path.line(to: NSPoint(x: bounds.maxX - 6, y: bounds.maxY - 6))
                path.line(to: NSPoint(x: bounds.maxX - 6, y: bounds.maxY - 6 - s))
            } else {
                path.move(to: NSPoint(x: bounds.maxX - 3 - s, y: bounds.minY + 3))
                path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3))
                path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3 + s))
            }
            path.close()
            white.withAlphaComponent(0.5).setFill()
            path.fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if style != .icon {
            drawLabelled()
            return
        }
        // Background
        let bg: NSColor
        if isPressed {
            bg = ToolbarLayout.accentColor.withAlphaComponent(0.6)
        } else if isOn {
            bg = ToolbarLayout.accentColor
        } else if isHovered {
            bg = (superview as? ToolbarStripView)?.usesWindowAppearance == true
                ? NSColor.labelColor.withAlphaComponent(0.06)
                : ToolbarLayout.iconColor.withAlphaComponent(0.12)
        } else {
            bg = NSColor.clear
        }
        bg.setFill()
        let inWindowChrome = (superview as? ToolbarStripView)?.usesWindowAppearance == true
        let radius = inWindowChrome ? 8 : Self.radius
        if inWindowChrome && isOn && !isPressed {
            // V3 editor tool row: selected tool is a brand tile with a soft shadow.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = ToolbarLayout.accentColor.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSBezierPath(roundedRect: inWindowChrome ? bounds.insetBy(dx: 1, dy: 1) : bounds, xRadius: radius, yRadius: radius).fill()
        }

        // Mic level fill — green bar rising from the bottom inside the button
        if micLevel > 0.001 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).addClip()
            let fillH = bounds.height * CGFloat(min(micLevel, 1.0))
            let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: fillH)
            NSColor.systemGreen.withAlphaComponent(0.45).setFill()
            fillRect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Color swatch
        if let swatch = swatchColor {
            let inset: CGFloat = 6
            let r = bounds.insetBy(dx: inset, dy: inset)
            swatch.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            ToolbarLayout.iconColor.withAlphaComponent(0.4).setStroke()
            let border = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            border.lineWidth = 0.5
            border.stroke()
            return
        }

        // SF Symbol or custom icon (static cache survives toolbar rebuilds)
        guard let name = sfSymbol else { return }
        let currentIsOn = isOn
        if cachedIcon == nil || cachedIconIsOn != currentIsOn {
            let color = currentIsOn ? ToolbarLayout.iconColor : tintColor
            let key = Self.cacheKey(name: name, isOn: currentIsOn, color: color)
            if let cached = Self.iconCache.object(forKey: key) {
                cachedIcon = cached
                cachedIconIsOn = currentIsOn
            } else {
                let img: NSImage?
                if name == "_custom.checkerboard" {
                    img = Self.checkerboardIcon(color: color)
                } else {
                    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                            .withSymbolConfiguration(cfg) {
                        img = NSImage(size: symbol.size, flipped: false) { r in
                            symbol.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                            color.setFill()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                    } else {
                        img = nil
                    }
                }
                if let img = img {
                    img.lockFocus(); img.unlockFocus()
                    Self.iconCache.setObject(img, forKey: key)
                    cachedIcon = img
                    cachedIconIsOn = currentIsOn
                }
            }
        }
        if let icon = cachedIcon {
            let x = bounds.midX - icon.size.width / 2
            let y = bounds.midY - icon.size.height / 2
            icon.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Context menu triangle
        if hasContextMenu {
            let s: CGFloat = 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.maxX - s - 3, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3 + s))
            path.close()
            ToolbarLayout.iconColor.withAlphaComponent(0.4).setFill()
            path.fill()
        }
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        // `.activeAlways` (not `.activeInActiveApp`): macshot is a menu-bar
        // LSUIElement app and the toolbars can live in non-activating panels
        // (Liquid Glass chrome). With `.activeInActiveApp`, mouseExited wouldn't
        // fire when the app isn't frontmost, leaving a previous button stuck in
        // its hover state when moving to another.
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Toolbar buttons always show the arrow cursor, overriding the overlay's
    // crosshair / hidden drawing-cursor that would otherwise bleed through.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    private var owningStrip: ToolbarStripView? {
        superview as? ToolbarStripView ?? superview?.superview as? ToolbarStripView
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        guard owningStrip?.suppressesHover != true else {
            setHovered(false)
            return
        }
        guard suppressHoverStartPoint == nil else {
            setHovered(false)
            return
        }
        // Robustly clear any sibling that AppKit failed to send mouseExited to
        // (common in non-activating glass chrome panels) so only one button is
        // ever hovered.
        owningStrip?.clearHover(except: self)
        setHovered(true)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        guard owningStrip?.suppressesHover != true else {
            setHovered(false)
            return
        }
        if let start = suppressHoverStartPoint {
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x
            let dy = now.y - start.y
            // AppKit can synthesize a mouseMoved/entered pass at the same
            // location after a toolbar drag loop unwinds. Keep hover suppressed
            // until the pointer actually moves away from the release point.
            guard dx * dx + dy * dy >= 9 else {
                setHovered(false)
                return
            }
            suppressHoverStartPoint = nil
        }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            owningStrip?.clearHover(except: self)
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        suppressHoverStartPoint = nil
        setHovered(false)
    }

    /// Externally force the hover state (used by the strip to clear stale hovers).
    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
        onHover?(action, hovered)
    }

    func clearInteractionState(
        suppressHoverUntilMouseMoved suppress: Bool = false,
        clearPressed: Bool = true
    ) {
        suppressHoverStartPoint = suppress ? NSEvent.mouseLocation : nil
        forwardingDrag = false
        if clearPressed {
            isPressed = false
        }
        setHovered(false)
        needsDisplay = true
    }

    private var forwardingDrag = false
    /// The view that should receive forwarded drag events (set by onMouseDown handler).
    var dragForwardTarget: NSView?

    override func mouseDown(with event: NSEvent) {
        isPressed = true; needsDisplay = true
        if onMouseDown != nil {
            onMouseDown?(action)
            if dragForwardTarget != nil {
                forwardingDrag = true
            }
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if forwardingDrag, let target = dragForwardTarget {
            target.mouseDragged(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false; needsDisplay = true
        if forwardingDrag, let target = dragForwardTarget {
            forwardingDrag = false
            target.mouseUp(with: event)
            return
        }
        forwardingDrag = false
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(action)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(action, self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - Custom checkerboard icon

    /// Generate a checkerboard icon matching the style of SF Symbols, tinted with the given color.
    /// The result is a rounded square with a 4x4 checkerboard pattern.
    private static func checkerboardIcon(color: NSColor) -> NSImage {
        let size: CGFloat = 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let cornerRadius: CGFloat = 3
            let cellSize = size / 4
            let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                    xRadius: cornerRadius, yRadius: cornerRadius)
            clip.addClip()

            for row in 0..<4 {
                for col in 0..<4 {
                    let isDark = (row + col) % 2 == 0
                    if isDark {
                        color.setFill()
                    } else {
                        color.withAlphaComponent(0.35).setFill()
                    }
                    let cellRect = NSRect(x: CGFloat(col) * cellSize, y: CGFloat(row) * cellSize,
                                          width: cellSize, height: cellSize)
                    cellRect.fill()
                }
            }
            return true
        }
        return img
    }
}
