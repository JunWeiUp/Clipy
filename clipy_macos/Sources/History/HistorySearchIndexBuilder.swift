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

    static func scheduleOCR(for entry: HistoryEntry, contentHash: String, updater: @escaping (String, String) -> Void) {
        guard case .image(let path) = entry.item else { return }

        indexQueue.async {
            ocrSemaphore.wait()
            defer { ocrSemaphore.signal() }

            guard let cgImage = ImageDownsampler.cgImage(at: path, maxPixelSize: ocrMaxPixelSize) else { return }
            let text = ImageOCRService.recognizeSync(cgImage: cgImage)
            guard let text, !text.isEmpty else { return }
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
