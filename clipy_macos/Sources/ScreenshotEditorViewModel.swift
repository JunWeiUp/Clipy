import AppKit
import SwiftUI

final class ScreenshotEditorViewModel: ObservableObject {
    @Published var toastMessage: String?
    @Published var isRecognizing = false

    private(set) var baseImage: NSImage
    let annotationModel = AnnotationCanvasModel()
    var canvasView: AnnotationCanvasView?

    init(image: NSImage) {
        self.baseImage = image
    }

    func replaceBaseImage(_ image: NSImage) {
        baseImage = image
    }

    func flattenedImage() -> NSImage? {
        guard baseImage.size.width > 0, baseImage.size.height > 0 else { return nil }
        let image = canvasView?.renderFlattenedImage() ?? baseImage
        return ScreenshotImageProcessor.preservePixels(image, logicalSize: baseImage.size)
    }

    func copyToClipboard() {
        guard let image = flattenedImage(),
              let pngData = ScreenshotImageProcessor.pngData(from: image, logicalSize: baseImage.size) else {
            return
        }
        ClipboardManager.shared.ingestCapturedImage(pngData, copyToPasteboard: true)
    }

    func pinToScreen() {
        guard let image = flattenedImage() else { return }
        PinPanelController.shared.pin(image: image)
    }

    func runOCR() {
        guard let image = flattenedImage(),
              let cgImage = ScreenshotImageProcessor.bestCGImage(from: image) else {
            return
        }
        isRecognizing = true
        ImageOCRService.recognize(cgImage: cgImage) { [weak self] text in
            guard let self else { return }
            self.isRecognizing = false
            if let text, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.showToast(L10n.t(.screenshotCopied))
            } else {
                self.showToast(L10n.t(.screenshotOCRNoText))
            }
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
    }
}
