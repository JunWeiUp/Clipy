import AppKit

/// AppKit views used by the status-bar menu: a section header with a trailing
/// hover action, and the hover-highlighting icon button it embeds. Split out of
/// MenuController so that file only orchestrates menu structure and actions.

/// Section header with a trailing hoverable action icon.
final class SectionMenuHeaderView: NSView {
    var onAction: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let actionButton = HoverIconButton(frame: .zero)

    init(
        title: String,
        symbolName: String,
        toolTip: String,
        buttonEnabled: Bool = true,
        width: CGFloat = 240
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        wantsLayer = true

        titleLabel.stringValue = title
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.backgroundColor = .clear
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.imageScaling = .scaleProportionallyDown
        actionButton.toolTip = toolTip
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.isEnabled = buttonEnabled
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            actionButton.image = image.withSymbolConfiguration(config)
        }
        actionButton.normalTint = .secondaryLabelColor
        actionButton.hoverTint = .labelColor
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 22),
            actionButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let menuWidth = enclosingMenuItem?.menu?.size.width, menuWidth > frame.width {
            setFrameSize(NSSize(width: menuWidth, height: frame.height))
        }
    }

    @objc private func actionClicked() {
        enclosingMenuItem?.menu?.cancelTracking()
        onAction?()
    }
}

/// Small icon button with hover highlight suitable for menu accessory controls.
final class HoverIconButton: NSButton {
    var normalTint: NSColor = .secondaryLabelColor {
        didSet { applyAppearance(hovered: isHovered) }
    }
    var hoverTint: NSColor = .labelColor {
        didSet { applyAppearance(hovered: isHovered) }
    }

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        isBordered = false
        applyAppearance(hovered: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { applyAppearance(hovered: isHovered) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        applyAppearance(hovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance(hovered: false)
    }

    private func applyAppearance(hovered: Bool) {
        if !isEnabled {
            contentTintColor = .tertiaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        contentTintColor = hovered ? hoverTint : normalTint
        layer?.backgroundColor = hovered
            ? NSColor.quaternaryLabelColor.cgColor
            : NSColor.clear.cgColor
    }
}
