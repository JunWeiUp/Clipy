import AppKit
import UniformTypeIdentifiers

enum ScreenshotExport {
    /// Copy to clipboard + history (always PNG for paste compatibility) and, if
    /// auto-save is on, write a disk file using the smart encoder (opaque → JPEG,
    /// transparent → PNG) so the on-disk file is far smaller while the in-app
    /// history keeps full-quality PNG.
    static func exportPNG(_ pngData: Data, image: NSImage, logicalSize: NSSize) {
        ClipboardManager.shared.ingestCapturedImage(pngData, copyToPasteboard: true)
        if PreferencesManager.shared.isScreenshotAutoSaveEnabled {
            if let encoded = ScreenshotImageProcessor.encodeForSave(from: image, logicalSize: logicalSize) {
                _ = ScreenshotSaveService.save(encoded: encoded)
            } else {
                _ = ScreenshotSaveService.save(pngData: pngData)
            }
        }
    }

    static func pin(image: NSImage, at screenRect: NSRect? = nil, skipIngest: Bool = false) {
        PinPanelController.shared.pin(image: image, at: screenRect, skipIngest: skipIngest)
    }

    static func runOCR(on image: NSImage, completion: @escaping (String?) -> Void) {
        // Use bestCGImage to get the native-pixel CGImage (the rep attached by
        // fromCapture), not cgImage(forProposedRect:) which can re-rasterize.
        guard let cgImage = ScreenshotImageProcessor.bestCGImage(from: image) else {
            completion(nil)
            return
        }
        ImageOCRService.recognize(cgImage: cgImage, completion: completion)
    }

    /// Prompt the user for a location and write the image there using the smart
    /// encoder (opaque → JPEG, transparent → PNG). Does not touch the clipboard
    /// or the auto-save directory. Defaults the panel to the detected format.
    @discardableResult
    static func saveAs(image: NSImage, logicalSize: NSSize) -> URL? {
        guard let encoded = ScreenshotImageProcessor.encodeForSave(from: image, logicalSize: logicalSize) else {
            return nil
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = L10n.t(.screenshotPostActionSaveAs)
        panel.nameFieldStringValue = ScreenshotSaveService.defaultFilename()
        let utType: UTType = encoded.fileExtension == "jpg" ? .jpeg : .png
        panel.allowedContentTypes = [utType]
        panel.directoryURL = URL(
            fileURLWithPath: PreferencesManager.shared.screenshotSaveDirectoryPath,
            isDirectory: true
        )
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try encoded.data.write(to: url, options: .atomic)
            return url
        } catch {
            appLog("Screenshot saveAs failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// Apply the user's configured post-capture action to a finished capture.
    /// `userOverride` lets a toolbar button press take precedence over the default action.
    static func applyPostAction(
        _ action: ScreenshotPostCaptureAction,
        pngData: Data,
        image: NSImage,
        logicalSize: NSSize,
        screenRect: NSRect? = nil
    ) {
        switch action {
        case .copy:
            exportPNG(pngData, image: image, logicalSize: logicalSize)
        case .pin:
            exportPNG(pngData, image: image, logicalSize: logicalSize)
            pin(image: image, at: screenRect, skipIngest: true)
        case .ocr:
            exportPNG(pngData, image: image, logicalSize: logicalSize)
            runOCR(on: image) { text in
                if let text, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        case .saveAs:
            // saveAs is explicit; still copy to clipboard so the capture is not "lost"
            // if the user cancels the panel.
            ClipboardManager.shared.ingestCapturedImage(pngData, copyToPasteboard: true)
            _ = saveAs(image: image, logicalSize: logicalSize)
        }
    }
}
