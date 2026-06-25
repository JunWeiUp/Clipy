import AppKit
import Foundation
import PDFKit
import Vision

enum HistorySearchIndexBuilder {
    private static let maxIndexLength = 8_000
    private static let indexQueue = DispatchQueue(label: "com.clipy.history-index", qos: .utility)

    static func buildIndex(for item: HistoryItem) -> String? {
        switch item {
        case .text(let str):
            return truncate(str)
        case .rtf(let data):
            return truncate(rtfPlainText(from: data))
        case .html(let data):
            if let html = HistoryPreviewSupport.htmlString(from: data) {
                return truncate(stripHTML(html))
            }
            return nil
        case .pdf(let data):
            return truncate(pdfPlainText(from: data))
        case .image:
            return nil
        case .files(let urls):
            let text = urls.map { "\($0.lastPathComponent)\n\($0.path)" }.joined(separator: "\n")
            return truncate(text)
        }
    }

    static func scheduleOCR(for entry: HistoryEntry, contentHash: String, updater: @escaping (String, String) -> Void) {
        guard case .image(let data) = entry.item, let image = NSImage(data: data),
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
