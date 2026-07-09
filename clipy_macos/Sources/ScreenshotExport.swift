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

    /// Prompt the user for a location and write the PNG there.
    /// Does not touch the clipboard or the auto-save directory.
    @discardableResult
    static func saveAs(pngData: Data) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = L10n.t(.screenshotPostActionSaveAs)
        panel.nameFieldStringValue = ScreenshotSaveService.defaultFilename()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = URL(
            fileURLWithPath: PreferencesManager.shared.screenshotSaveDirectoryPath,
            isDirectory: true
        )
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try pngData.write(to: url, options: .atomic)
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
            _ = saveAs(pngData: pngData)
        }
    }
}
