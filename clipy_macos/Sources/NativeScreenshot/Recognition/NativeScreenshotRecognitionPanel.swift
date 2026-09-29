import AppKit
import CoreGraphics
import SwiftUI

/// All Vision requests start from a user action. Opening this panel only shows
/// the image; closing it cancels any pending result delivery.
struct NativeScreenshotRecognitionPanel: View {
    let image: CGImage
    let language: NativeScreenshotOCRLanguage
    var onRedactedImage: ((CGImage) -> Void)? = nil

    @State private var task: Task<Void, Never>?
    @State private var textLines: [NativeScreenshotRecognizedText] = []
    @State private var qrCodes: [NativeScreenshotQRCode] = []
    @State private var isWorking = false
    @State private var hasScannedText = false
    @State private var hasScannedQR = false
    @State private var errorMessage: String?
    @State private var review: NativeScreenshotRedactionReview?
    @State private var showsReview = false
    @State private var showsTranslation = false

    /// A caller with an application preference enum (for example
    /// `ScreenshotOCRLanguage`) can pass it directly with an explicit mapping.
    init<PreferenceLanguage>(
        image: CGImage,
        language: PreferenceLanguage,
        mappedBy map: (PreferenceLanguage) -> NativeScreenshotOCRLanguage,
        onRedactedImage: ((CGImage) -> Void)? = nil
    ) {
        self.image = image
        self.language = map(language)
        self.onRedactedImage = onRedactedImage
    }

    init(
        image: CGImage,
        language: NativeScreenshotOCRLanguage = .automatic,
        onRedactedImage: ((CGImage) -> Void)? = nil
    ) {
        self.image = image
        self.language = language
        self.onRedactedImage = onRedactedImage
    }

    private var combinedText: String {
        textLines.map(\.text).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NativeScreenshotRecognitionLabels.text("识别截图内容", "Recognize screenshot content"))
                .font(.title2.weight(.semibold))
            Image(nsImage: NSImage(cgImage: image,
                                   size: NSSize(width: image.width, height: image.height)))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 220)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Button(NativeScreenshotRecognitionLabels.text("识别文字", "Recognize text"), action: scanText)
                Button(NativeScreenshotRecognitionLabels.text("识别二维码", "Scan QR codes"), action: scanQR)
                if isWorking { ProgressView().controlSize(.small) }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
            if hasScannedText {
                GroupBox(NativeScreenshotRecognitionLabels.text("文字", "Text")) {
                    if textLines.isEmpty {
                        Text(NativeScreenshotRecognitionLabels.text("未识别到文字", "No text found"))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(combinedText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 60, maxHeight: 180)
                        HStack {
                            Button(NativeScreenshotRecognitionLabels.text("复制文字", "Copy text")) {
                                copyToPasteboard(combinedText)
                            }
                            Button(NativeScreenshotRecognitionLabels.text("翻译…", "Translate…")) {
                                showsTranslation = true
                            }
                            if onRedactedImage != nil {
                                Button(NativeScreenshotRecognitionLabels.text("检查自动遮挡…", "Review redactions…")) {
                                    let suggestions = NativeScreenshotRedactionDetector.suggest(
                                        from: textLines,
                                        imageSize: CGSize(width: image.width, height: image.height))
                                    review = NativeScreenshotRedactionReview(
                                        sourceImage: image, suggestions: suggestions)
                                    showsReview = true
                                }
                            }
                        }
                    }
                }
            }
            if hasScannedQR {
                GroupBox(NativeScreenshotRecognitionLabels.text("二维码", "QR codes")) {
                    if qrCodes.isEmpty {
                        Text(NativeScreenshotRecognitionLabels.text("未发现二维码", "No QR code found"))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(qrCodes) { code in
                                    HStack(alignment: .top) {
                                        Text(code.payload)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button(NativeScreenshotRecognitionLabels.text("复制", "Copy")) {
                                            copyToPasteboard(code.payload)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 50, maxHeight: 130)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .onDisappear {
            task?.cancel()
            task = nil
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
        .sheet(isPresented: $showsTranslation) {
            NativeScreenshotTranslationPanel(sourceText: combinedText)
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

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
