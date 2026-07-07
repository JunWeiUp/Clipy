import AppKit

enum ScreenshotExport {
    static func exportPNG(_ pngData: Data, image: NSImage, logicalSize: NSSize) {
        ClipboardManager.shared.ingestCapturedImage(pngData, copyToPasteboard: true)
        _ = ScreenshotSaveService.saveIfEnabled(pngData: pngData)
    }

    static func pin(image: NSImage, at screenRect: NSRect? = nil, skipIngest: Bool = false) {
        PinPanelController.shared.pin(image: image, at: screenRect, skipIngest: skipIngest)
    }

    static func runOCR(on image: NSImage, completion: @escaping (String?) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(nil)
            return
        }
        ImageOCRService.recognize(cgImage: cgImage, completion: completion)
    }
}
