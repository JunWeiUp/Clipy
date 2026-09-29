import AppKit
import Foundation
import UniformTypeIdentifiers

/// Performs one user-visible handoff per confirmed screenshot. The PNG copy
/// used for history is encoded once, regardless of the chosen follow-up.
@MainActor
enum NativeScreenshotDeliveryService {
    struct Delivery {
        let historyPNG: Data
        let savedURL: URL?
        let recognizedText: String?
    }

    enum DeliveryError: Error {
        case noRecognizedText
        case invalidOutputFormat
        case saveCancelled
    }

    static func deliver(
        _ captured: NativeScreenshotCapturedImage,
        action: ScreenshotPostCaptureAction? = nil
    ) async throws -> Delivery {
        let preferences = PreferencesManager.shared
        let chosenAction = action ?? preferences.screenshotPostCaptureAction
        let png = try await encodePNG(captured.image)
        var savedURL: URL?
        if chosenAction == .saveAs {
            // Cancelling the destination picker leaves history and pasteboard
            // untouched, just like cancelling the capture itself.
            savedURL = try await saveAs(
                captured.image,
                format: preferredFormat(preferences.imageFormat),
                quality: preferences.imageQuality
            )
        }

        // The image enters history exactly once. Copy only for the explicit
        // copy action; other actions may put text or files on the pasteboard.
        try ClipboardManager.shared.ingestCapturedImage(
            png, copyToPasteboard: chosenAction == .copy
        )

        if preferences.isScreenshotAutoSaveEnabled && chosenAction != .saveAs {
            savedURL = try await save(
                captured.image,
                in: preferences.screenshotSaveDirectory,
                format: preferredFormat(preferences.imageFormat),
                quality: preferences.imageQuality
            )
        }

        var recognizedText: String?
        switch chosenAction {
        case .copy:
            break
        case .pin:
            let image = NSImage(
                cgImage: captured.image,
                size: NSSize(width: captured.image.width, height: captured.image.height)
            )
            PinPanelController.shared.pin(image: image, skipIngest: true)
        case .ocr:
            let language = preferences.screenshotOCRLanguage
            let lines = try await Task.detached(priority: .userInitiated) {
                try NativeScreenshotImageProcessor.recognizeText(
                    in: captured.image, language: language
                )
            }.value
            let text = lines.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else { throw DeliveryError.noRecognizedText }
            recognizedText = text
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .saveAs:
            break
        }
        return Delivery(historyPNG: png, savedURL: savedURL,
                        recognizedText: recognizedText)
    }

    static func saveOnly(_ image: CGImage) async throws -> URL {
        let preferences = PreferencesManager.shared
        return try await saveAs(
            image,
            format: preferredFormat(preferences.imageFormat),
            quality: preferences.imageQuality
        )
    }

    static func saveToDefault(_ image: CGImage) async throws -> URL {
        let preferences = PreferencesManager.shared
        return try await save(
            image,
            in: preferences.screenshotSaveDirectory,
            format: preferredFormat(preferences.imageFormat),
            quality: preferences.imageQuality
        )
    }

    /// Quick capture overrides auto-save and the default post-capture action.
    /// History still records the image once for recovery and search.
    static func deliverQuick(
        _ captured: NativeScreenshotCapturedImage,
        mode: Int
    ) async throws -> Delivery {
        let selected = min(3, max(0, mode))
        let png = try await encodePNG(captured.image)
        try ClipboardManager.shared.ingestCapturedImage(
            png, copyToPasteboard: selected == 1 || selected == 2
        )
        let saved: URL?
        if selected == 0 || selected == 2 {
            let preferences = PreferencesManager.shared
            saved = try await save(
                captured.image,
                in: preferences.screenshotSaveDirectory,
                format: preferredFormat(preferences.imageFormat),
                quality: preferences.imageQuality
            )
        } else {
            saved = nil
        }
        return Delivery(historyPNG: png, savedURL: saved, recognizedText: nil)
    }

    private static func preferredFormat(
        _ raw: String
    ) -> NativeScreenshotImageProcessor.FileFormat {
        NativeScreenshotImageProcessor.FileFormat(rawValue: raw) ?? .png
    }

    private static func save(
        _ image: CGImage,
        in directory: URL,
        format: NativeScreenshotImageProcessor.FileFormat,
        quality: Double
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = ScreenshotSaveService.defaultFilename()
        let uniqueBase = "\(base)-\(UUID().uuidString.prefix(8))"
        let output = directory.appendingPathComponent(uniqueBase)
            .appendingPathExtension(format.rawValue)
        try await encodeAndWrite(image, format: format, quality: quality, to: output)
        return output
    }

    private static func saveAs(
        _ image: CGImage,
        format: NativeScreenshotImageProcessor.FileFormat,
        quality: Double
    ) async throws -> URL {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = ScreenshotSaveService.defaultFilename()
            + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else {
            throw DeliveryError.saveCancelled
        }
        try await encodeAndWrite(image, format: format, quality: quality, to: url)
        return url
    }

    private static func encodePNG(_ image: CGImage) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try NativeScreenshotImageProcessor.encode(image, as: .png)
            try Task.checkCancellation()
            return data
        }.value
    }

    private static func encodeAndWrite(
        _ image: CGImage,
        format: NativeScreenshotImageProcessor.FileFormat,
        quality: Double,
        to url: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try NativeScreenshotImageProcessor.encode(
                image, as: format, quality: CGFloat(quality)
            )
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
        }.value
    }
}
