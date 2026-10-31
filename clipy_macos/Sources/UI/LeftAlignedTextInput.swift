import SwiftUI

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
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.alignment = .left
        textView.textContainerInset = NSSize(width: AppSpacing.xl, height: AppSpacing.lg)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = Self.bodyAttributes(paragraph)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        Self.applyBodyStyle(to: textView)
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
            Self.applyBodyStyle(to: textView)
        }
        textView.alignment = .left
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
    }

    private static func bodyAttributes(_ paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var attributes = AppFont.textAttributes(size: 14, color: .labelColor)
        attributes[.paragraphStyle] = paragraph
        return attributes
    }

    /// `string =` replaces storage without the default paragraph style, so
    /// re-apply the body line height (design: 14pt / 1.85) to programmatic text.
    private static func applyBodyStyle(to textView: NSTextView) {
        guard let storage = textView.textStorage, let paragraph = textView.defaultParagraphStyle else { return }
        let attributes = bodyAttributes(paragraph)
        storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = attributes
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
