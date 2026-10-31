import Cocoa

/// The selection resolution control shown over a capture/recording selection:
///   [ W field ] × [ H field ]  [▾ presets]
/// Two real, separately-editable number fields with a non-editable "×" between
/// them (so the separator can't be deleted), plus a presets dropdown button for
/// aspect ratios and common resolutions. Replaces the old drawn "W × H" badge.
final class ResolutionBoxView: NSView, NSTextFieldDelegate {

    enum EditedDimension {
        case width
        case height
        case both
    }

    /// Called when the user commits new W/H values (Enter or focus loss).
    var onCommit: ((_ w: Int, _ h: Int, _ edited: EditedDimension) -> Void)?
    /// Called after Enter commits so the owning overlay can reclaim keyboard
    /// focus from the field editor/panel.
    var onFinishEditing: (() -> Void)?
    /// Called when the presets button is clicked; passes the button for anchoring.
    var onPresets: ((_ anchor: NSView) -> Void)?

    private let widthField = ResolutionNumberField()
    private let heightField = ResolutionNumberField()
    private let timesLabel = CenteredGlyphView(glyph: "\u{00D7}")
    private let presetsButton = NSButton()

    // mac-capture.html `.pillx.blue`: 24pt brand pill, 18pt fields, chevron preset button.
    private var widthFieldW: CGFloat = 34
    private var heightFieldW: CGFloat = 34
    private let fieldH: CGFloat = 18
    private let gap: CGFloat = 2
    private let pad: CGFloat = 3
    private let btnW: CGFloat = 20
    private let pillH: CGFloat = 24
    private let pillGap: CGFloat = 6
    /// Pill background drawn behind the editable W × H fields.
    private let dimensionPill = NSView()
    /// Read-only info pills (`.pillx`): Retina pixel size, snapped-to-edge state.
    private var infoPills: [NSView] = []
    private var suppressNextEndEditingCommit = false

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        dimensionPill.wantsLayer = true
        dimensionPill.layer?.cornerRadius = 7
        dimensionPill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addSubview(dimensionPill)

        configureField(widthField)
        configureField(heightField)

        timesLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        timesLabel.color = NSColor.white.withAlphaComponent(0.7)
        addSubview(timesLabel)

        presetsButton.bezelStyle = .regularSquare
        presetsButton.isBordered = false
        presetsButton.imagePosition = .imageOnly
        presetsButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("Aspect ratio & resolution presets"))?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        presetsButton.contentTintColor = .white
        presetsButton.target = self
        presetsButton.action = #selector(presetsClicked)
        presetsButton.toolTip = L("Aspect ratio & resolution presets")
        addSubview(presetsButton)

        layoutPieces()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureField(_ f: NSTextField) {
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        f.alignment = .center
        f.textColor = .white
        f.delegate = self
        f.isEditable = true
        f.isSelectable = true
        // No system bezel/border — they ignore the toolbar theme. Draw a themed
        // rounded background via the field's own layer instead (derived from
        // iconColor so it adapts to the user's toolbar colors / light & dark).
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.wantsLayer = true
        f.layer?.cornerRadius = 4
        f.layer?.backgroundColor = NSColor.clear.cgColor
        f.formatter = ResolutionBoxView.intFormatter()
        addSubview(f)
    }

    private static func intFormatter() -> NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.minimum = 1
        nf.maximum = 100000
        nf.allowsFloats = false
        return nf
    }

    private var timesWidth: CGFloat { max(12, timesLabel.intrinsicContentSize.width) }

    /// Natural size of the control.
    var preferredSize: NSSize {
        var width = dimensionPillWidth
        for pill in infoPills { width += pillGap + pill.frame.width }
        return NSSize(width: width, height: pillH)
    }

    private var dimensionPillWidth: CGFloat {
        4 + widthFieldW + gap + timesWidth + gap + heightFieldW + gap + btnW + pad
    }

    /// X (in this view's coords) of the midpoint of the W↔H pair — i.e. the center
    /// of the "×". OverlayView aligns this with the selection center so the box
    /// reads as centered on the dimensions, ignoring the trailing presets button.
    var dimensionsCenterX: CGFloat {
        4 + widthFieldW + gap + timesWidth / 2
    }

    private func layoutPieces() {
        let h = pillH
        var x: CGFloat = 4
        let y = (pillH - fieldH) / 2
        widthField.frame = NSRect(x: x, y: y, width: widthFieldW, height: fieldH)
        x += widthFieldW + gap
        // Vertically center the "×" against the fields' text. A label is
        // bottom-baseline; give it the full field height and center its glyph by
        // matching the field font's vertical metrics.
        timesLabel.frame = NSRect(x: x, y: y, width: timesWidth, height: fieldH)
        x += timesWidth + gap
        heightField.frame = NSRect(x: x, y: y, width: heightFieldW, height: fieldH)
        x += heightFieldW + gap
        presetsButton.frame = NSRect(x: x, y: y, width: btnW, height: fieldH)
        x += btnW + pad
        dimensionPill.frame = NSRect(x: 0, y: 0, width: x, height: h)
        for pill in infoPills {
            x += pillGap
            pill.frame.origin = NSPoint(x: x, y: 0)
            x += pill.frame.width
        }
        frame.size = NSSize(width: x, height: h)
    }

    /// Show the read-only info pills next to the size: pixel size on Retina
    /// screens and the "snapped to element edge" state while a snap guide is active.
    func setInfo(retina: String?, snapped: Bool) {
        let key = "\(retina ?? "")|\(snapped)"
        guard key != infoKey else { return }
        infoKey = key
        infoPills.forEach { $0.removeFromSuperview() }
        infoPills = []
        if let retina { infoPills.append(Self.makeInfoPill(symbol: "display", text: retina)) }
        if snapped { infoPills.append(Self.makeInfoPill(symbol: "dot.squareshape.split.2x2", text: L("Snapped to element edge"))) }
        infoPills.forEach { addSubview($0) }
        layoutPieces()
    }
    private var infoKey = ""

    private static func makeInfoPill(symbol: String, text: String) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 7
        pill.layer?.backgroundColor = NSColor(srgbRed: 20 / 255, green: 22 / 255, blue: 28 / 255, alpha: 0.82).cgColor
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage())
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        icon.frame = NSRect(x: 9, y: 5, width: 14, height: 14)
        label.frame.origin = NSPoint(x: 9 + 14 + 5, y: (24 - label.frame.height) / 2)
        pill.addSubview(icon)
        pill.addSubview(label)
        pill.frame.size = NSSize(width: label.frame.maxX + 9, height: 24)
        return pill
    }

    /// Update displayed dimensions from the selection. Skips a field only while it
    /// is ACTIVELY being edited (has a field editor) so we don't clobber typing —
    /// previously the guard also skipped when nothing was focused, leaving fields
    /// blank.
    func setDimensions(w: Int, h: Int) {
        if !isEditing(widthField) {
            widthField.stringValue = "\(w)"
        }
        if !isEditing(heightField) {
            heightField.stringValue = "\(h)"
        }
        let font = widthField.font ?? .systemFont(ofSize: 12)
        func fieldWidth(_ text: String) -> CGFloat {
            max(34, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8)
        }
        let newW = fieldWidth(widthField.stringValue), newH = fieldWidth(heightField.stringValue)
        if newW != widthFieldW || newH != heightFieldW {
            widthFieldW = newW; heightFieldW = newH
            layoutPieces()
        }
    }

    private func isEditing(_ field: NSTextField) -> Bool {
        // A field is being edited only if it has an active field editor that is
        // also the window's first responder.
        guard let editor = field.currentEditor() else { return false }
        return field.window?.firstResponder === editor
    }

    /// True while either W/H field is actively being edited. The owning overlay
    /// uses this to avoid re-presenting/re-placing the glass panel mid-edit,
    /// which would disturb the field editor and make typing beep.
    var isActivelyEditing: Bool {
        isEditing(widthField) || isEditing(heightField)
    }

    /// Reflect the active ratio/resolution preset in the presets button.
    func setActivePresetLabel(_ label: String?) {
        presetsButton.toolTip = label.map { "\(L("Presets")) — \($0)" } ?? L("Aspect ratio & resolution presets")
        presetsButton.contentTintColor = label == nil ? NSColor.white.withAlphaComponent(0.85) : .white
    }

    @objc private func presetsClicked() {
        onPresets?(presetsButton)
    }

    private func editedDimension(for control: Any?) -> EditedDimension {
        guard let control = control as? NSControl else { return .both }
        if control === widthField { return .width }
        if control === heightField { return .height }
        return .both
    }

    private func commit(edited: EditedDimension) {
        guard let w = Int(widthField.stringValue), let h = Int(heightField.stringValue),
              w > 0, h > 0 else { return }
        onCommit?(w, h, edited)
    }

    private func finishEditing() {
        window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            self?.onFinishEditing?()
        }
    }

    // Enter or Escape in either field commits and returns focus to the overlay.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.cancelOperation(_:)) {
            suppressNextEndEditingCommit = true
            commit(edited: editedDimension(for: control))
            finishEditing()
            return true
        }
        return false
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.object as? NSTextField)?.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
    }

    // Commit on focus loss too.
    func controlTextDidEndEditing(_ obj: Notification) {
        (obj.object as? NSTextField)?.layer?.backgroundColor = NSColor.clear.cgColor
        if suppressNextEndEditingCommit {
            suppressNextEndEditingCommit = false
            return
        }
        commit(edited: editedDimension(for: obj.object))
    }

    override func resetCursorRects() {
        // Fields show the I-beam (editable affordance); the button shows arrow.
        addCursorRect(widthField.frame, cursor: .iBeam)
        addCursorRect(heightField.frame, cursor: .iBeam)
        addCursorRect(presetsButton.frame, cursor: .arrow)
    }
}

/// Vertically centers the text within a non-bezeled field (and its field editor),
/// so the digits sit in the middle of the themed background instead of the top.
private final class VCenterTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        guard textHeight < rect.height else { return rect }
        let dy = (rect.height - textHeight) / 2
        return NSRect(x: rect.minX, y: rect.minY + dy, width: rect.width, height: textHeight)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: centered(rect))
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: editor,
                   delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: editor,
                     delegate: delegate, start: start, length: length)
    }
}

/// A number field may enter editing from a direct mouse click, without becoming
/// a stray first responder during overlay keyboard handling.
private final class ResolutionNumberField: NSTextField {
    private var acceptingMouseFocus = false

    override class var cellClass: AnyClass? {
        get { VCenterTextFieldCell.self }
        set {}
    }

    // The field lives in a borderless, non-activating overlay window. For AppKit
    // to install a field editor there, the field must advertise that it needs the
    // window to become key — otherwise clicks focus it inconsistently and typing
    // beeps.
    override var needsPanelToBecomeKey: Bool { true }

    override var acceptsFirstResponder: Bool {
        acceptingMouseFocus || currentEditor() != nil
    }

    override func becomeFirstResponder() -> Bool {
        guard acceptingMouseFocus || currentEditor() != nil else { return false }
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        acceptingMouseFocus = true
        defer { acceptingMouseFocus = false }
        super.mouseDown(with: event)
    }
}

/// Draws a single glyph centered both horizontally and vertically — used for the
/// "×" so it lines up with the bezeled number fields (an NSTextField label is
/// baseline-anchored and sits too high/low).
private final class CenteredGlyphView: NSView {
    private let glyph: String
    var font: NSFont = .systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    init(glyph: String) {
        self.glyph = glyph
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = (glyph as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width), height: ceil(s.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (glyph as NSString).size(withAttributes: attrs)
        let p = NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2)
        (glyph as NSString).draw(at: p, withAttributes: attrs)
    }
}
