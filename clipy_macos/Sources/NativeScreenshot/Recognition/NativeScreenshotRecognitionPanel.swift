import AppKit
import CoreGraphics
import SwiftUI

enum NativeScreenshotRecognitionIntent: Equatable {
    case none, text, qrCode, both, redact, translate
}

/// The old result window used an AppKit text editor so ordinary editing,
/// selection, find, and undo shortcuts work even after a translation replaces
/// the complete document. The SwiftUI panel keeps that editor as its text area.
private struct NativeScreenshotEditableOCRText: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.autoresizingMask = [.width]
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView,
              editor.string != text else { return }
        context.coordinator.isApplyingExternalChange = true
        editor.insertText(text,
                          replacementRange: NSRange(location: 0,
                                                    length: (editor.string as NSString).length))
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        context.coordinator.isApplyingExternalChange = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeScreenshotEditableOCRText
        var isApplyingExternalChange = false

        init(_ parent: NativeScreenshotEditableOCRText) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange,
                  let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

/// All Vision requests start from a user action. Opening this panel only shows
/// the image; closing it cancels any pending result delivery.
struct NativeScreenshotRecognitionPanel: View {
    let image: CGImage
    let language: NativeScreenshotOCRLanguage
    let initialIntent: NativeScreenshotRecognitionIntent
    var onRedactedImage: ((CGImage) -> Void)? = nil
    var onCopyOriginal: (() -> Void)? = nil
    var onSaveOriginal: (() -> Void)? = nil
    var onContinueEditing: (() -> Void)? = nil

    @State private var task: Task<Void, Never>?
    @State private var textLines: [NativeScreenshotRecognizedText] = []
    @State private var qrCodes: [NativeScreenshotQRCode] = []
    @State private var isWorking = false
    @State private var hasScannedText = false
    @State private var hasScannedQR = false
    @State private var errorMessage: String?
    @State private var review: NativeScreenshotRedactionReview?
    @State private var showsReview = false
    @State private var didStartInitialIntent = false
    @State private var editableText = ""
    @State private var originalText = ""
    @State private var isShowingTranslation = false
    @State private var targetLanguageCode = UserDefaults.standard.string(forKey: "translateTargetLang") ?? "en"
    @State private var translationRequest: NativeScreenshotTranslationRequest?
    @State private var translationIsWorking = false

    /// A caller with an application preference enum (for example
    /// `ScreenshotOCRLanguage`) can pass it directly with an explicit mapping.
    init<PreferenceLanguage>(
        image: CGImage,
        language: PreferenceLanguage,
        mappedBy map: (PreferenceLanguage) -> NativeScreenshotOCRLanguage,
        initialIntent: NativeScreenshotRecognitionIntent = .none,
        onRedactedImage: ((CGImage) -> Void)? = nil,
        onCopyOriginal: (() -> Void)? = nil,
        onSaveOriginal: (() -> Void)? = nil,
        onContinueEditing: (() -> Void)? = nil
    ) {
        self.image = image
        self.language = map(language)
        self.initialIntent = initialIntent
        self.onRedactedImage = onRedactedImage
        self.onCopyOriginal = onCopyOriginal
        self.onSaveOriginal = onSaveOriginal
        self.onContinueEditing = onContinueEditing
    }

    init(
        image: CGImage,
        language: NativeScreenshotOCRLanguage = .automatic,
        initialIntent: NativeScreenshotRecognitionIntent = .none,
        onRedactedImage: ((CGImage) -> Void)? = nil,
        onCopyOriginal: (() -> Void)? = nil,
        onSaveOriginal: (() -> Void)? = nil,
        onContinueEditing: (() -> Void)? = nil
    ) {
        self.image = image
        self.language = language
        self.initialIntent = initialIntent
        self.onRedactedImage = onRedactedImage
        self.onCopyOriginal = onCopyOriginal
        self.onSaveOriginal = onSaveOriginal
        self.onContinueEditing = onContinueEditing
    }

    private var wordCount: Int {
        editableText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(nsImage: NSImage(cgImage: image,
                                   size: NSSize(width: image.width, height: image.height)))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 240)
                .frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.22))
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                NativeScreenshotEditableOCRText(text: $editableText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(NativeScreenshotRecognitionLabels.text(
                        "可编辑的识别文字", "Editable recognized text"))
                if hasScannedQR { qrSection }
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 540, minHeight: 360)
        .onAppear {
            guard !didStartInitialIntent else { return }
            didStartInitialIntent = true
            switch initialIntent {
            case .none: break
            case .qrCode: scanQR()
            case .text, .redact, .translate: scanText()
            case .both: scanBoth()
            }
        }
        .onDisappear {
            task?.cancel()
            task = nil
            translationRequest = nil
            isWorking = false
        }
        .sheet(isPresented: $showsReview) {
            if let review {
                NativeScreenshotRedactionReviewView(
                    review: review,
                    onConfirm: { output in
                        showsReview = false
                        onRedactedImage?(output)
                    },
                    onCancel: { showsReview = false })
            }
        }
        .background {
            if #available(macOS 15.0, *), let translationRequest {
                NativeScreenshotTranslationTaskView(
                    request: translationRequest,
                    onTranslated: { id, translated in
                        guard self.translationRequest?.id == id else { return }
                        self.translationRequest = nil
                        self.translationIsWorking = false
                        self.editableText = translated
                        self.isShowingTranslation = true
                    },
                    onFailure: { id, message in
                        guard self.translationRequest?.id == id else { return }
                        self.translationRequest = nil
                        self.translationIsWorking = false
                        self.errorMessage = message
                    })
                    .id(translationRequest.id)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(NativeScreenshotRecognitionLabels.text("翻译成", "Translate to:"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("", selection: $targetLanguageCode) {
                ForEach(NativeScreenshotTranslationTarget.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .frame(width: 132)
            .onChange(of: targetLanguageCode) { code in
                UserDefaults.standard.set(code, forKey: "translateTargetLang")
                if isShowingTranslation { startTranslation(source: originalText) }
            }
            Button(NativeScreenshotRecognitionLabels.text(
                isShowingTranslation ? "显示原文" : "翻译",
                isShowingTranslation ? "Show Original" : "Translate")) {
                if isShowingTranslation {
                    translationRequest = nil
                    editableText = originalText
                    isShowingTranslation = false
                } else {
                    originalText = editableText
                    startTranslation(source: editableText)
                }
            }
            .disabled(editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || translationIsWorking)
            if isWorking || translationIsWorking { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            Text(String(format: NativeScreenshotRecognitionLabels.text(
                "%d 字 · %d 词", "%d chars · %d words"), editableText.count, wordCount))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private var qrSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text(NativeScreenshotRecognitionLabels.text(
                qrCodes.count == 1 ? "二维码" : "二维码列表",
                qrCodes.count == 1 ? "QR Code" : "QR Codes"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if qrCodes.isEmpty {
                Text(NativeScreenshotRecognitionLabels.text("未发现二维码", "No QR code found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(qrCodes) { code in
                            HStack(spacing: 6) {
                                Text(code.payload)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button(NativeScreenshotRecognitionLabels.text("复制", "Copy")) {
                                    copyToPasteboard(code.payload)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 116)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu(NativeScreenshotRecognitionLabels.text("操作", "Actions")) {
                Button(NativeScreenshotRecognitionLabels.text("重新识别文字", "Recognize Text"), action: scanText)
                Button(NativeScreenshotRecognitionLabels.text("识别二维码", "Scan QR Codes"), action: scanQR)
                if onRedactedImage != nil, hasScannedText, !textLines.isEmpty {
                    Button(NativeScreenshotRecognitionLabels.text(
                        "检查自动遮挡…", "Review Redactions…"), action: showRedactionReview)
                }
                if onCopyOriginal != nil || onSaveOriginal != nil || onContinueEditing != nil {
                    Divider()
                    if let onCopyOriginal {
                        Button(Self.originalActionTitle(.copy, intent: initialIntent), action: onCopyOriginal)
                    }
                    if let onSaveOriginal {
                        Button(Self.originalActionTitle(.save, intent: initialIntent), action: onSaveOriginal)
                    }
                    if let onContinueEditing {
                        Button(Self.originalActionTitle(.edit, intent: initialIntent), action: onContinueEditing)
                    }
                }
            }
            Spacer(minLength: 0)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Button(NativeScreenshotRecognitionLabels.text("复制  ⌘↩", "Copy  ⌘↩"), action: copyAll)
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(editableText.isEmpty && qrCodes.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    enum OriginalAction { case copy, save, edit }

    static func originalActionTitle(_ action: OriginalAction,
                                    intent: NativeScreenshotRecognitionIntent) -> String {
        let unredacted = intent == .redact
        switch action {
        case .copy:
            return unredacted
                ? NativeScreenshotRecognitionLabels.text("复制未遮挡原图", "Copy unredacted image")
                : NativeScreenshotRecognitionLabels.text("复制原图", "Copy original image")
        case .save:
            return unredacted
                ? NativeScreenshotRecognitionLabels.text("保存未遮挡原图…", "Save unredacted image…")
                : NativeScreenshotRecognitionLabels.text("保存原图…", "Save original image…")
        case .edit:
            return unredacted
                ? NativeScreenshotRecognitionLabels.text("编辑未遮挡原图", "Edit unredacted image")
                : NativeScreenshotRecognitionLabels.text("继续编辑原图", "Continue editing image")
        }
    }

    private func scanText() {
        task?.cancel()
        isWorking = true
        hasScannedText = false
        textLines = []
        errorMessage = nil
        task = Task { @MainActor in
            do {
                let lines = try await NativeScreenshotRecognitionService.recognizeText(
                    in: image, language: language)
                guard !Task.isCancelled else { return }
                textLines = lines
                hasScannedText = true
                isWorking = false
                let recognized = lines.map(\.text).joined(separator: "\n")
                editableText = recognized
                originalText = recognized
                isShowingTranslation = false
                translationRequest = nil
                if !lines.isEmpty {
                    if initialIntent == .translate { startTranslation(source: recognized) }
                    if initialIntent == .redact, onRedactedImage != nil {
                        let suggestions = NativeScreenshotRedactionDetector.suggest(
                            from: lines,
                            imageSize: CGSize(width: image.width, height: image.height))
                        review = NativeScreenshotRedactionReview(
                            sourceImage: image, suggestions: suggestions)
                        showsReview = true
                    }
                }
            } catch is CancellationError {
                // Superseded by a newer scan or the panel closed.
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = NativeScreenshotRecognitionLabels.text(
                    "文字识别失败，请重试。", "Text recognition failed. Please retry.")
                isWorking = false
            }
        }
    }

    private func scanQR() {
        task?.cancel()
        isWorking = true
        hasScannedQR = false
        qrCodes = []
        errorMessage = nil
        task = Task { @MainActor in
            do {
                let codes = try await NativeScreenshotRecognitionService.recognizeQRCodes(in: image)
                guard !Task.isCancelled else { return }
                qrCodes = codes
                hasScannedQR = true
                isWorking = false
            } catch is CancellationError {
                // Superseded by a newer scan or the panel closed.
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = NativeScreenshotRecognitionLabels.text(
                    "二维码识别失败，请重试。", "QR scan failed. Please retry.")
                isWorking = false
            }
        }
    }

    private func scanBoth() {
        task?.cancel()
        isWorking = true
        hasScannedText = false
        hasScannedQR = false
        textLines = []
        qrCodes = []
        errorMessage = nil
        task = Task { @MainActor in
            do {
                let lines = try await NativeScreenshotRecognitionService.recognizeText(
                    in: image, language: language)
                guard !Task.isCancelled else { return }
                textLines = lines
                hasScannedText = true
                let recognized = lines.map(\.text).joined(separator: "\n")
                editableText = recognized
                originalText = recognized
                isShowingTranslation = false
                translationRequest = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = NativeScreenshotRecognitionLabels.text(
                    "文字识别失败，请重试。", "Text recognition failed. Please retry.")
            }
            do {
                let codes = try await NativeScreenshotRecognitionService.recognizeQRCodes(in: image)
                guard !Task.isCancelled else { return }
                qrCodes = codes
                hasScannedQR = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = NativeScreenshotRecognitionLabels.text(
                    "二维码识别失败，请重试。", "QR scan failed. Please retry.")
                errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n")
            }
            isWorking = false
        }
    }

    private func startTranslation(source: String) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard #available(macOS 15.0, *) else {
            errorMessage = NativeScreenshotRecognitionLabels.text(
                "本机翻译需要 macOS 15 或更高版本。", "On-device translation requires macOS 15 or later.")
            return
        }
        errorMessage = nil
        translationIsWorking = true
        translationRequest = NativeScreenshotTranslationRequest(
            sourceText: source, targetCode: targetLanguageCode)
    }

    private func showRedactionReview() {
        let suggestions = NativeScreenshotRedactionDetector.suggest(
            from: textLines,
            imageSize: CGSize(width: image.width, height: image.height))
        review = NativeScreenshotRedactionReview(sourceImage: image, suggestions: suggestions)
        showsReview = true
    }

    private func copyAll() {
        let text = editableText.isEmpty ? qrCodes.map(\.payload).joined(separator: "\n") : editableText
        guard !text.isEmpty else { return }
        copyToPasteboard(text)
        NSApp.keyWindow?.performClose(nil)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
