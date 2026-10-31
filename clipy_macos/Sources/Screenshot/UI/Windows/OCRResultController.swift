import Cocoa

class OCRResultController: NSObject {

    private var window: NSPanel?
    private var textView: NSTextView?
    private var translatedView: NSTextView?
    private var charCountLabel: NSTextField?
    private var translateButton: NSButton?
    private var langPopup: NSPopUpButton?
    private var copyButton: NSButton?
    private var spinnerView: NSProgressIndicator?
    private var translationPlaceholder: NSTextField?

    private var qrCodes: [QRCodePayload]
    private var isShowingTranslation = false
    private var translationGeneration = 0

    /// Invoked once when the window closes (either close button or title-bar
    /// red-X), so the owner can drop its reference to this controller.
    var onClose: (() -> Void)?

    init(text: String, image: NSImage?, qrCodes: [QRCodePayload] = []) {
        self.qrCodes = qrCodes
        super.init()
        buildWindow(text: text, image: image, qrCodes: qrCodes)
    }

    // MARK: - Build

    private func buildWindow(text: String, image: NSImage?, qrCodes: [QRCodePayload]) {
        // V3 (mac-capture-results.html): 760×456 window, title + live count subtitle,
        // source / translation columns, QR cards and a footer with AI Search + Copy.
        let width: CGFloat = 760, height: CGFloat = 404
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2)
        let panel = KeyablePanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = qrCodes.isEmpty ? L("Text Recognition") : L("Text & QR Recognition")
        panel.toolbar = NSToolbar(identifier: "ClipyOCRResult")
        panel.toolbarStyle = .unified
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.minSize = NSSize(width: 620, height: 340)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = OCRBackgroundView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let footerH: CGFloat = 52
        let left = OCRPaneView(frame: .zero)
        let right = OCRPaneView(frame: .zero)
        right.fillColor = OCRPalette.secondaryBackground
        root.addSubview(left)
        root.addSubview(right)
        root.onLayout = { [weak left, weak right] bounds in
            let paneH = bounds.height - footerH
            let half = (bounds.width / 2).rounded()
            left?.frame = NSRect(x: 0, y: footerH, width: half, height: paneH)
            right?.frame = NSRect(x: half, y: footerH, width: bounds.width - half, height: paneH)
        }

        // Left header: source thumbnail · 识别原文 · 可直接编辑
        let thumb = NSImageView()
        thumb.image = image
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 5
        thumb.layer?.masksToBounds = true
        thumb.toolTip = L("Original")
        thumb.isHidden = image == nil
        let sourceTitle = NSTextField(labelWithString: L("Recognized Text"))
        sourceTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        sourceTitle.textColor = .tertiaryLabelColor
        let editableHint = NSTextField(labelWithString: L("Editable"))
        editableHint.font = .systemFont(ofSize: 12)
        editableHint.textColor = .tertiaryLabelColor
        for view in [thumb, sourceTitle, editableHint] { left.addSubview(view) }
        let count = NSTextField(labelWithString: "")
        charCountLabel = count
        updateCharCount(for: text)

        func makeText(editable: Bool) -> (OCRTextBox, NSTextView) {
            let box = OCRTextBox()
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            let tv = NSTextView(frame: .zero)
            tv.isEditable = editable
            tv.isSelectable = true
            tv.isRichText = false
            tv.allowsUndo = editable
            tv.font = .systemFont(ofSize: 13)
            tv.textContainerInset = NSSize(width: 9, height: 10)
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            tv.autoresizingMask = [.width]
            tv.drawsBackground = false
            tv.usesFindBar = true
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = 4
            tv.defaultParagraphStyle = style
            tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: style, .foregroundColor: NSColor.labelColor]
            scroll.documentView = tv
            box.addSubview(scroll)
            box.scroll = scroll
            return (box, tv)
        }
        let (sourceBox, original) = makeText(editable: true)
        left.addSubview(sourceBox)
        original.delegate = self
        let noText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        original.string = noText ? L("(No text detected in the selected area)") : text
        if let style = original.defaultParagraphStyle {
            original.textStorage?.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: (original.string as NSString).length))
        }
        textView = original

        var qrCards: [NSView] = []
        for (index, payload) in qrCodes.prefix(3).enumerated() {
            let card = makeQRCodeCard(payload, index: index)
            left.addSubview(card)
            qrCards.append(card)
        }
        left.onLayout = { [weak thumb, weak sourceTitle, weak editableHint, weak sourceBox] bounds in
            guard let thumb, let sourceTitle, let editableHint, let sourceBox else { return }
            let inset: CGFloat = 16
            var y: CGFloat = 14
            var x = inset
            if !thumb.isHidden {
                thumb.frame = NSRect(x: x, y: y, width: 46, height: 28)
                x += 46 + 8
            }
            sourceTitle.sizeToFit(); editableHint.sizeToFit()
            sourceTitle.frame.origin = NSPoint(x: x, y: y + (28 - sourceTitle.frame.height) / 2)
            editableHint.frame.origin = NSPoint(x: bounds.width - inset - editableHint.frame.width, y: y + (28 - editableHint.frame.height) / 2)
            y += 28 + 10
            var bottom = bounds.height - 14
            for card in qrCards.reversed() {
                card.frame = NSRect(x: inset, y: bottom - 64, width: bounds.width - inset * 2, height: 64)
                bottom -= 64 + 10
            }
            sourceBox.frame = NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: max(60, bottom - y))
        }

        // Right header: 翻译为 [language ⌄] … 翻译
        let langIcon = NSImageView(image: NSImage(systemSymbolName: "translate", accessibilityDescription: nil) ?? NSImage())
        langIcon.contentTintColor = .tertiaryLabelColor
        langIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        let langLabel = NSTextField(labelWithString: L("Translate to"))
        langLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        langLabel.textColor = .tertiaryLabelColor
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        for lang in TranslationService.availableLanguages {
            popup.addItem(withTitle: lang.name)
            popup.lastItem?.representedObject = lang.code
        }
        if let index = TranslationService.availableLanguages.firstIndex(where: { $0.code == TranslationService.targetLanguage }) { popup.selectItem(at: index) }
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        langPopup = popup
        let translate = NSButton(title: L("Translate"), target: self, action: #selector(toggleTranslate))
        translate.bezelStyle = .rounded
        translate.controlSize = .small
        translate.font = .systemFont(ofSize: 12)
        translateButton = translate
        let (targetBox, translated) = makeText(editable: false)
        translatedView = translated
        let placeholder = NSTextField(labelWithString: L("Translation appears here."))
        placeholder.font = .systemFont(ofSize: 12.5)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        targetBox.addSubview(placeholder)
        translationPlaceholder = placeholder
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        targetBox.addSubview(spinner)
        spinnerView = spinner
        for view in [langIcon, langLabel, popup, translate, targetBox] as [NSView] { right.addSubview(view) }
        right.onLayout = { [weak langIcon, weak langLabel, weak popup, weak translate, weak targetBox, weak placeholder, weak spinner] bounds in
            guard let langIcon, let langLabel, let popup, let translate, let targetBox, let placeholder, let spinner else { return }
            let inset: CGFloat = 16
            let rowY: CGFloat = 14, rowH: CGFloat = 28
            langIcon.frame = NSRect(x: inset, y: rowY + 7, width: 14, height: 14)
            langLabel.sizeToFit()
            langLabel.frame.origin = NSPoint(x: langIcon.frame.maxX + 6, y: rowY + (rowH - langLabel.frame.height) / 2)
            popup.sizeToFit()
            popup.frame = NSRect(x: langLabel.frame.maxX + 8, y: rowY + (rowH - popup.frame.height) / 2,
                                 width: max(96, popup.frame.width), height: popup.frame.height)
            translate.sizeToFit()
            translate.frame.origin = NSPoint(x: bounds.width - inset - translate.frame.width, y: rowY + (rowH - translate.frame.height) / 2)
            targetBox.frame = NSRect(x: inset, y: rowY + rowH + 10, width: bounds.width - inset * 2,
                                     height: max(60, bounds.height - rowY - rowH - 10 - 14))
            placeholder.sizeToFit()
            placeholder.frame.origin = NSPoint(x: (targetBox.bounds.width - placeholder.frame.width) / 2,
                                               y: (targetBox.bounds.height - placeholder.frame.height) / 2)
            spinner.frame = NSRect(x: targetBox.bounds.midX - 8, y: targetBox.bounds.midY - 8, width: 16, height: 16)
        }

        // Footer
        let footer = OCRPaneView(frame: .zero)
        footer.drawsTopLine = true
        root.addSubview(footer)
        let footHint = NSTextField(labelWithString: L("Edit the recognized text before copying"))
        footHint.font = .systemFont(ofSize: 12)
        footHint.textColor = .tertiaryLabelColor
        let ai = NSButton(title: L("AI Search"), target: self, action: #selector(openAISearch))
        ai.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        ai.imagePosition = .imageLeading
        ai.bezelStyle = .rounded
        // Primary brand button (mac.css .btn.primary), drawn the same way as the editor's Done.
        let copy = EditorFooterButton()
        copy.configure(title: L("Copy") + "  ⌘↩", symbol: "doc.on.doc", primary: true)
        copy.target = self
        copy.action = #selector(copyAll)
        copy.keyEquivalent = "\r"
        copy.keyEquivalentModifierMask = [.command]
        copyButton = copy
        for view in [footHint, ai, copy] { footer.addSubview(view) }
        let rootLayout = root.onLayout
        root.onLayout = { [weak footer, weak footHint, weak ai, weak copy] bounds in
            rootLayout?(bounds)
            guard let footer, let footHint, let ai, let copy else { return }
            footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footerH)
            ai.sizeToFit()
            ai.frame.size.width += 8
            copy.frame.size.height = ai.frame.height
            copy.frame.origin = NSPoint(x: bounds.width - 16 - copy.frame.width, y: (footerH - copy.frame.height) / 2)
            ai.frame.origin = NSPoint(x: copy.frame.minX - 8 - ai.frame.width, y: (footerH - ai.frame.height) / 2)
            footHint.sizeToFit()
            footHint.frame.origin = NSPoint(x: 16, y: (footerH - footHint.frame.height) / 2)
        }
        panel.contentView = root
        self.window = panel
        updateCharCount(for: original.string)
    }

    private func makeQRCodeCard(_ payload: QRCodePayload, index: Int) -> NSView {
        let card = OCRTextBox()
        let code = NSImageView()
        code.image = Self.qrImage(for: payload.value)
        code.imageScaling = .scaleProportionallyUpOrDown
        code.wantsLayer = true
        code.layer?.cornerRadius = 6
        code.layer?.masksToBounds = true
        let caption = NSTextField(labelWithString: L("QR Code"))
        caption.font = .systemFont(ofSize: 11.5)
        caption.textColor = .tertiaryLabelColor
        let value = NSTextField(labelWithString: payload.value)
        value.font = .systemFont(ofSize: 12.5)
        value.textColor = payload.url == nil ? .labelColor : .linkColor
        value.lineBreakMode = .byTruncatingTail
        value.isSelectable = true
        let button: NSButton
        if payload.url != nil {
            button = NSButton(title: L("Open Link"), target: self, action: #selector(openQRCode(_:)))
            button.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        } else {
            button = NSButton(title: L("Copy"), target: self, action: #selector(copyQRCode(_:)))
            button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.tag = index
        for view in [code, caption, value, button] { card.addSubview(view) }
        card.onLayout = { [weak code, weak caption, weak value, weak button] bounds in
            guard let code, let caption, let value, let button else { return }
            code.frame = NSRect(x: 12, y: 10, width: 44, height: 44)
            button.sizeToFit()
            button.frame.size.width += 8
            button.frame.origin = NSPoint(x: bounds.width - 12 - button.frame.width, y: (bounds.height - button.frame.height) / 2)
            caption.sizeToFit()
            caption.frame.origin = NSPoint(x: 68, y: 12)
            value.frame = NSRect(x: 68, y: caption.frame.maxY + 2, width: max(40, button.frame.minX - 12 - 68), height: 18)
        }
        return card
    }

    private static func qrImage(for value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Show / Close

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let tv = self.textView else { return }
            self.window?.makeFirstResponder(tv)
            tv.selectAll(nil)
        }
    }

    func close() {
        // Route through window.close() so both the in-app buttons and the
        // title-bar red-X converge on the same teardown in windowWillClose.
        window?.close()
    }

    private func tearDown() {
        translationGeneration += 1
        window?.delegate = nil
        window = nil
        onClose?()
        onClose = nil
        MainActor.assumeIsolated {
            screenshotAppIntegration()?.returnFocusIfNeeded()
        }
    }

    // MARK: - Actions

    @objc private func copyAll() {
        let text = textView?.string ?? ""
        let noTextMessage = L("(No text detected in the selected area)")
        let copyText = text == noTextMessage ? qrCodes.map(\.value).joined(separator: "\n") : text
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        close()
    }

    @objc private func copyQRCode(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < qrCodes.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(qrCodes[sender.tag].value, forType: .string)
    }

    @objc private func openQRCode(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < qrCodes.count,
              let url = qrCodes[sender.tag].url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAISearch() {
        guard let text = textView?.string, !text.isEmpty else { return }
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)&csuir=1&udm=50") else { return }
        NSWorkspace.shared.open(url)
        close()
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let code = sender.selectedItem?.representedObject as? String else { return }
        TranslationService.targetLanguage = code
        // A pending response belongs to the old language; discard it.
        let wasTranslating = spinnerView?.isHidden == false
        translationGeneration += 1
        if isShowingTranslation || wasTranslating {
            performTranslation(targetLang: code)
        }
    }

    @objc private func toggleTranslate() {
        let code = (langPopup?.selectedItem?.representedObject as? String)
            ?? TranslationService.targetLanguage
        performTranslation(targetLang: code)
    }

    private func performTranslation(targetLang: String) {
        guard let tv = textView else { return }
        let sourceText = tv.string
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceText != L("(No text detected in the selected area)") else { return }

        translationGeneration += 1
        let generation = translationGeneration

        translateButton?.isEnabled = false
        translationPlaceholder?.isHidden = true
        spinnerView?.isHidden = false
        spinnerView?.startAnimation(nil)

        // Split into lines for per-line translation (preserves layout)
        let lines = sourceText.components(separatedBy: "\n")
        let nonEmpty = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        TranslationService.translateBatch(texts: nonEmpty, targetLang: targetLang) { [weak self] result in
            guard let self = self, self.window != nil,
                  self.translationGeneration == generation else { return }
            self.spinnerView?.stopAnimation(nil)
            self.spinnerView?.isHidden = true
            self.translateButton?.isEnabled = true

            switch result {
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = L("Translation Failed")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window = self.window { alert.beginSheetModal(for: window) }

            case .success(let translated):
                // Restore empty lines to preserve paragraph structure
                var result: [String] = []
                for (i, original) in lines.enumerated() {
                    if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append("")
                    } else if i < translated.count {
                        result.append(translated[i])
                    }
                }
                let translatedText = result.joined(separator: "\n")
                self.isShowingTranslation = true
                self.translationPlaceholder?.isHidden = true
                self.translatedView?.string = translatedText
                self.translatedView?.textColor = .labelColor
                self.translateButton?.title = L("Translate")
            }
        }
    }

    private func updateCharCount(for text: String) {
        let chars = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        charCountLabel?.stringValue = String(format: L("%d chars · %d words"), chars, words)
        window?.subtitle = charCountLabel?.stringValue ?? ""
    }
}

enum OCRPalette {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    /// mac.css --m-bg / --m-bg-2 / --m-line
    static let background = dynamic(.white, NSColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1))
    static let secondaryBackground = dynamic(NSColor(srgbRed: 0.969, green: 0.969, blue: 0.976, alpha: 1),
                                             NSColor(srgbRed: 0.145, green: 0.145, blue: 0.157, alpha: 1))
    static let line = dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.09))
}

private final class OCRBackgroundView: NSView {
    var onLayout: ((NSRect) -> Void)?
    override func layout() { super.layout(); onLayout?(bounds) }
    override func draw(_ dirtyRect: NSRect) {
        OCRPalette.background.setFill()
        dirtyRect.fill()
    }
}

/// Flipped pane with optional fill, left divider and top divider.
private final class OCRPaneView: NSView {
    var fillColor: NSColor?
    var drawsTopLine = false
    var onLayout: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?(bounds) }
    override func draw(_ dirtyRect: NSRect) {
        if let fillColor { fillColor.setFill(); bounds.fill() }
        OCRPalette.line.setFill()
        if fillColor != nil { NSRect(x: 0, y: 0, width: 0.5, height: bounds.height).fill() }
        if drawsTopLine { NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill() }
    }
}

/// Rounded content card (`.txt` / `.qr` in the design).
private final class OCRTextBox: NSView {
    weak var scroll: NSScrollView?
    var onLayout: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        scroll?.frame = bounds.insetBy(dx: 4, dy: 3)
        if let text = scroll?.documentView as? NSTextView {
            text.frame.size.width = scroll?.contentSize.width ?? bounds.width
            text.minSize = NSSize(width: 0, height: scroll?.contentSize.height ?? 0)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        onLayout?(bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 10, yRadius: 10)
        OCRPalette.background.setFill()
        path.fill()
        OCRPalette.line.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

extension OCRResultController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Fires for both the title-bar red-X and the in-app close() path. Nil
        // out our retained references and return focus exactly once.
        guard window != nil else { return }
        tearDown()
    }
}

extension OCRResultController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view === textView else { return }
        translationGeneration += 1
        spinnerView?.stopAnimation(nil)
        spinnerView?.isHidden = true
        translateButton?.isEnabled = true
        updateCharCount(for: view.string)
    }
}

private class KeyablePanel: EscapeClosingPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Ensure Cmd+C, Cmd+A, Cmd+Z etc. always reach the first responder (NSTextView).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let the first responder handle standard text editing shortcuts first.
        if let fr = firstResponder as? NSTextView {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command {
                switch event.keyCode {
                case 8:  fr.copy(nil);      return true  // C
                case 7:  fr.cut(nil);       return true  // X
                case 9:  fr.paste(nil);     return true  // V
                case 0:  fr.selectAll(nil); return true  // A
                case 6:  fr.undoManager?.undo(); return true  // Z
                default: break
                }
            }
            if flags == [.command, .shift], event.keyCode == 6 {  // Z
                fr.undoManager?.redo(); return true
            }
        }
        // Cmd+W to close — handle outside the text view check so it always works
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 13 {  // W
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
