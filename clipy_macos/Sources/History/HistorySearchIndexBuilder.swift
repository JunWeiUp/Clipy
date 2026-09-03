import AppKit
import Foundation
import PDFKit

enum HistorySearchIndexBuilder {
    private static let maxIndexLength = 500
    private static let ocrMaxPixelSize = 2048
    private static let indexQueue = DispatchQueue(label: "com.clipy.history-index", qos: .utility)
    private static let ocrSemaphore = DispatchSemaphore(value: 1)

    static func buildIndex(for item: HistoryItem) -> String? {
        let store = HistoryMediaStore.shared
        switch item {
        case .text:
            return nil
        case .rtf(let path):
            guard let data = store.data(at: path) else { return nil }
            return truncate(rtfPlainText(from: data))
        case .html(let path):
            guard let data = store.data(at: path),
                  let html = HistoryPreviewSupport.htmlString(from: data) else { return nil }
            return truncate(stripHTML(html))
        case .pdf(let path):
            guard let data = store.data(at: path) else { return nil }
            return truncate(pdfPlainText(from: data))
        case .image:
            return nil
        case .files(let urls):
            let text = urls.map { "\($0.lastPathComponent)\n\($0.path)" }.joined(separator: "\n")
            return truncate(text)
        }
    }

    /// Schedules OCR for an image entry. `updater` is invoked exactly once on
    /// the main thread for every scheduled hash — with empty text when the
    /// image is unreadable or OCR finds nothing — so the caller can always
    /// clear its in-flight bookkeeping (empty-text callbacks previously never
    /// fired, leaking the hash from the pending set forever).
    ///
    /// Recognition runs in the OCR child process (see `OCRSubprocess`) so the
    /// Vision models never stay resident in the main app; in-process Vision is
    /// only the fallback when the child cannot be spawned.
    static func scheduleOCR(for entry: HistoryEntry, contentHash: String, updater: @escaping (String, String) -> Void) {
        guard case .image(let path) = entry.item else { return }

        indexQueue.async {
            ocrSemaphore.wait()
            defer { ocrSemaphore.signal() }

            // The child reads the file directly, so encrypted media must be
            // decrypted here and staged as plain bytes in a temp file.
            var stagedTemp: URL?
            let plainPath: String
            if PreferencesManager.shared.isHistoryEncryptionEnabled {
                guard let data = HistoryMediaStore.shared.data(at: path) else {
                    DispatchQueue.main.async { updater(contentHash, "") }
                    return
                }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clipy-ocr-\(UUID().uuidString).img")
                do {
                    try data.write(to: temp, options: .atomic)
                } catch {
                    DispatchQueue.main.async { updater(contentHash, "") }
                    return
                }
                stagedTemp = temp
                plainPath = temp.path
            } else {
                plainPath = path
            }
            defer { if let stagedTemp { try? FileManager.default.removeItem(at: stagedTemp) } }

            let languagePref = PreferencesManager.shared.screenshotOCRLanguage
            let text = OCRSubprocess.recognizeText(
                at: plainPath,
                maxPixelSize: ocrMaxPixelSize,
                languages: languagePref.recognitionLanguages
            ) ?? ImageDownsampler.cgImage(at: plainPath, maxPixelSize: ocrMaxPixelSize)
                .flatMap { ImageOCRService.recognizeInProcess(cgImage: $0, languages: languagePref) }
            guard let text, !text.isEmpty else {
                DispatchQueue.main.async { updater(contentHash, "") }
                return
            }
            DispatchQueue.main.async {
                updater(contentHash, truncate(text) ?? text)
            }
        }
    }

    private static func rtfPlainText(from data: Data) -> String? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        return attributed.string
    }

    private static func pdfPlainText(from data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        let limit = min(document.pageCount, 5)
        var parts: [String] = []
        for index in 0..<limit {
            guard let page = document.page(at: index), let text = page.string else { continue }
            parts.append(text)
            if parts.joined().count >= maxIndexLength { break }
        }
        return parts.joined(separator: "\n")
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxIndexLength { return trimmed }
        return String(trimmed.prefix(maxIndexLength))
    }
}
