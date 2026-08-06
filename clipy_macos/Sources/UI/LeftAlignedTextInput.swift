import SwiftUI

struct LeftAlignedTextField: NSViewRepresentable {
    @Binding var text: String
    var onTextChange: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        field.font = NSFont.systemFont(ofSize: AppFont.bodySize)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.editingEnded(_:))
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onTextChange = onTextChange
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.alignment = .left
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onTextChange: (() -> Void)?

        init(text: Binding<String>, onTextChange: (() -> Void)?) {
            _text = text
            self.onTextChange = onTextChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
            onTextChange?()
        }

        @objc func editingEnded(_ sender: NSTextField) {
            text = sender.stringValue
            onTextChange?()
        }
    }
}

struct LeftAlignedTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Fired with the latest text after typing settles (debounce) or on blur.
    /// Not invoked on every keystroke — callers use this for persistence.
    var onCommit: ((String) -> Void)?
    var commitDebounce: TimeInterval = 0.5

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, commitDebounce: commitDebounce)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.font = NSFont.systemFont(ofSize: AppFont.bodySize)
        textView.alignment = .left
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.commitDebounce = commitDebounce
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.alignment = .left
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onCommit: ((String) -> Void)?
        var commitDebounce: TimeInterval
        weak var textView: NSTextView?
        private var commitWorkItem: DispatchWorkItem?

        init(text: Binding<String>, onCommit: ((String) -> Void)?, commitDebounce: TimeInterval) {
            _text = text
            self.onCommit = onCommit
            self.commitDebounce = commitDebounce
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            scheduleCommit(textView.string)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            flushCommit(textView.string)
        }

        private func scheduleCommit(_ value: String) {
            commitWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onCommit?(value)
            }
            commitWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + commitDebounce, execute: work)
        }

        func flushCommit(_ value: String) {
            commitWorkItem?.cancel()
            commitWorkItem = nil
            onCommit?(value)
        }

        deinit {
            // Pending debounce must not fire after the editor is torn down;
            // the owning view flushes explicitly on disappear when needed.
            commitWorkItem?.cancel()
        }
    }
}
