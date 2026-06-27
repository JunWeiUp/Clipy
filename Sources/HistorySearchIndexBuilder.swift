import AppKit
import Foundation
import PDFKit
import Vision

enum HistorySearchIndexBuilder {
    private static let maxIndexLength = 500
    private static let indexQueue = DispatchQueue(label: "com.clipy.history-index", qos: .utility)

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
        guard case .image(let path) = entry.item,
              let image = NSImage(contentsOf: URL(fileURLWithPath: path)),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        indexQueue.async {
            let text = recognizeText(in: cgImage)
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

    private static func recognizeText(in cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            return lines.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    private static func truncate(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxIndexLength { return trimmed }
        return String(trimmed.prefix(maxIndexLength))
    }
}
