import AppKit
import SwiftUI

final class ScreenshotEditorViewModel: ObservableObject {
    @Published var toastMessage: String?
    @Published var isRecognizing = false

    let baseImage: NSImage
    let annotationModel = AnnotationCanvasModel()
    var canvasView: AnnotationCanvasView?

    init(image: NSImage) {
        self.baseImage = image
    }

    func flattenedImage() -> NSImage? {
        canvasView?.renderFlattenedImage() ?? baseImage
    }

    func copyToClipboard() {
        guard let image = flattenedImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
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
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
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
