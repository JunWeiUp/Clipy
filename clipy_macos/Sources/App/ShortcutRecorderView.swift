import AppKit

class ShortcutRecorderView: NSView {
    var onShortcutChanged: ((ShortcutCombo?) -> Void)?
    var combo: ShortcutCombo? {
        didSet {
            updateDisplay()
        }
    }

    private let label = NSTextField(labelWithString: L10n.t(.recordShortcut))
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private var labelTrailingToClearConstraint: NSLayoutConstraint?
    private var labelTrailingToEdgeConstraint: NSLayoutConstraint?
    private var isRecording = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = AppCornerRadius.small
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearButton.imagePosition = .imageOnly
        clearButton.bezelStyle = .circular
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.isHidden = true
        clearButton.toolTip = L10n.t(.clearShortcut)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        let trailingToClear = label.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4)
        let trailingToEdge = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        labelTrailingToClearConstraint = trailingToClear
        labelTrailingToEdgeConstraint = trailingToEdge

        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 18),
            clearButton.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingToEdge,
        ])
    }

    func refreshLocalizedStrings() {
        if !isRecording, combo == nil {
            label.stringValue = L10n.t(.recordShortcut)
        }
        clearButton.toolTip = L10n.t(.clearShortcut)
    }

    private func updateDisplay() {
        if isRecording {
            label.stringValue = L10n.t(.recordingShortcut)
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            clearButton.isHidden = true
            labelTrailingToClearConstraint?.isActive = false
            labelTrailingToEdgeConstraint?.isActive = true
        } else if let combo = combo {
            label.stringValue = combo.displayString
            layer?.borderColor = NSColor.separatorColor.cgColor
            clearButton.isHidden = false
            labelTrailingToEdgeConstraint?.isActive = false
            labelTrailingToClearConstraint?.isActive = true
        } else {
            label.stringValue = L10n.t(.recordShortcut)
            layer?.borderColor = NSColor.separatorColor.cgColor
            clearButton.isHidden = true
            labelTrailingToClearConstraint?.isActive = false
            labelTrailingToEdgeConstraint?.isActive = true
        }
    }

    @objc private func clearShortcut() {
        combo = nil
        onShortcutChanged?(nil)
        updateDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
        updateDisplay()
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        updateDisplay()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            if event.keyCode == 53 {
                isRecording = false
                window?.makeFirstResponder(nil)
                updateDisplay()
                return
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !modifiers.isEmpty || (event.keyCode >= 96 && event.keyCode <= 101) {
                let combo = ShortcutCombo(keyCode: Int(event.keyCode), modifierFlags: event.modifierFlags.rawValue)
                self.combo = combo
                isRecording = false
                onShortcutChanged?(combo)
                window?.makeFirstResponder(nil)
                updateDisplay()
            }
        }
    }
}
