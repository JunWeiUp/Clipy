import AppKit

protocol ScrollingCaptureOverviewDelegate: AnyObject {
    func scrollingOverviewDidFinish()
    func scrollingOverviewDidCancel()
}

final class ScrollingCaptureOverviewPanel: NSPanel {
    weak var overviewDelegate: ScrollingCaptureOverviewDelegate?

    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var dragOffset: NSPoint = .zero

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver + 2
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        contentView = buildContent()
        isMovableByWindowBackground = true
    }

    func placeDefault(on screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.minY + 24
        )
        setFrameOrigin(origin)
    }

    func update(preview: NSImage?, pixelHeight: Int, duplicateHint: Bool, limitHint: Bool) {
        imageView.image = preview
        if limitHint {
            statusLabel.stringValue = L10n.t(.screenshotScrollingLimitReached)
        } else if duplicateHint {
            statusLabel.stringValue = L10n.t(.screenshotScrollingEndHint)
        } else {
            statusLabel.stringValue = L10n.format(.screenshotScrollingHeight, pixelHeight)
        }
        hintLabel.stringValue = L10n.t(.screenshotScrollingHint)
    }

    private func buildContent() -> NSView {
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 280))
        effect.material = .underWindowBackground
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        let title = NSTextField(labelWithString: L10n.t(.screenshotScrolling))
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 180).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 160).isActive = true

        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 2
        hintLabel.lineBreakMode = .byWordWrapping

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let done = NSButton(title: L10n.t(.screenshotDone), target: self, action: #selector(finishAction))
        done.bezelStyle = .push
        done.controlSize = .small
        done.keyEquivalent = "\r"

        let cancel = NSButton(title: L10n.t(.cancel), target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .push
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}"

        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(done)

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12)
        ])

        return effect
    }

    @objc private func finishAction() {
        overviewDelegate?.scrollingOverviewDidFinish()
    }

    @objc private func cancelAction() {
        overviewDelegate?.scrollingOverviewDidCancel()
    }
}
