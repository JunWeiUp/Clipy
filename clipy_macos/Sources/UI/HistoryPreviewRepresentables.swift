import AppKit
import PDFKit
import SwiftUI
import WebKit

struct PDFDataPreviewRepresentable: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .textBackgroundColor
        pdfView.document = PDFDocument(data: data)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        pdfView.document = PDFDocument(data: data)
    }
}

struct PDFFilePreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .textBackgroundColor
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        pdfView.document = PDFDocument(url: url)
    }
}

struct HTMLPreviewRepresentable: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(html: html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(html: html, into: webView)
    }

    final class Coordinator {
        private var loadedHTML: String?

        func load(html: String, into webView: WKWebView) {
            guard loadedHTML != html else { return }
            loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

struct HTMLFilePreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(url: url, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url: url, into: webView)
    }

    final class Coordinator {
        private var loadedPath: String?

        func load(url: URL, into webView: WKWebView) {
            guard loadedPath != url.path else { return }
            loadedPath = url.path
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

struct PlainTextPreviewRepresentable: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        configure(textView)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    private func configure(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: AppFont.bodySize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
    }
}

struct AsyncTextFilePreviewView: View {
    let url: URL
    let kind: HistoryPreviewSupport.FileKind

    @State private var loaded: HistoryPreviewSupport.TextPreviewPayload?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loaded {
                TextPreviewPanel(payload: loaded)
            } else {
                EmptyStateView(message: L10n.t(.historyPreviewLoadFailed))
            }
        }
        .task(id: url) {
            isLoading = true
            loaded = nil
            let result = await HistoryPreviewSupport.loadTextPreview(from: url, kind: kind)
            loaded = result
            isLoading = false
        }
    }
}

struct TextPreviewPanel: View {
    let payload: HistoryPreviewSupport.TextPreviewPayload

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if payload.truncated {
                Text(L10n.t(.historyPreviewTruncated))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.top, AppSpacing.xs)
            }
            PlainTextPreviewRepresentable(text: payload.displayText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum HistoryPreviewSupport {
    enum FileKind {
        case image
        case pdf
        case html
        case json
        case markdown
        case plainText
        case other
    }

    struct TextPreviewPayload {
        let displayText: String
        let truncated: Bool
        let kind: FileKind
    }

    private static let jsonExtensions: Set<String> = ["json", "jsonc"]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    private static let plainTextExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "xml", "yaml", "yml",
        "swift", "py", "js", "ts", "jsx", "tsx", "rb", "go", "rs", "java",
        "kt", "kts", "c", "cc", "cpp", "h", "hpp", "m", "mm", "sh", "bash", "zsh",
        "sql", "ini", "cfg", "conf", "env", "toml", "properties", "plist", "css", "scss",
    ]

    static let maxTextPreviewBytes = 128_000
    static let swiftUITextThreshold = 8_000

    static func fileKind(for url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "svg", "ico":
            return .image
        case "pdf":
            return .pdf
        case "html", "htm":
            return .html
        default:
            break
        }
        if jsonExtensions.contains(ext) { return .json }
        if markdownExtensions.contains(ext) { return .markdown }
        if plainTextExtensions.contains(ext) { return .plainText }
        return .other
    }

    static func textString(from data: Data) -> String? {
        if let string = String(data: data, encoding: .utf8) { return string }
        if let string = String(data: data, encoding: .utf16) { return string }
        return String(data: data, encoding: .isoLatin1)
    }

    static func htmlString(from data: Data) -> String? {
        textString(from: data)
    }

    static func readTextFile(at url: URL) -> (content: String, truncated: Bool)? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let truncated = data.count > maxTextPreviewBytes
        let slice = truncated ? Data(data.prefix(maxTextPreviewBytes)) : data
        guard let content = textString(from: slice) else { return nil }
        return (content, truncated)
    }

    static func loadTextPreview(from url: URL, kind: FileKind) async -> TextPreviewPayload? {
        await Task.detached(priority: .userInitiated) {
            guard let loaded = readTextFile(at: url) else { return nil }
            var resolvedKind = kind == .other ? fileKind(for: url) : kind
            if resolvedKind == .plainText, looksLikeJSON(loaded.content) {
                resolvedKind = .json
            }
            let display = displayText(for: loaded.content, kind: resolvedKind)
            return TextPreviewPayload(displayText: display, truncated: loaded.truncated, kind: resolvedKind)
        }.value
    }

    static func textPreviewPayload(for text: String, kind: FileKind) -> TextPreviewPayload {
        let truncated = text.utf8.count > maxTextPreviewBytes
        let content: String
        if truncated, let data = text.data(using: .utf8) {
            let slice = data.prefix(maxTextPreviewBytes)
            content = textString(from: Data(slice)) ?? String(text.prefix(swiftUITextThreshold))
        } else {
            content = text
        }
        return TextPreviewPayload(
            displayText: displayText(for: content, kind: kind),
            truncated: truncated,
            kind: kind
        )
    }

    static func displayText(for content: String, kind: FileKind) -> String {
        switch kind {
        case .json:
            return formatJSON(content) ?? content
        default:
            return content
        }
    }

    static func resolvedTextKind(for text: String) -> FileKind {
        if looksLikeHTML(text) { return .html }
        if looksLikeJSON(text) { return .json }
        return .plainText
    }

    static func formatJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let result = String(data: formatted, encoding: .utf8) else {
            return nil
        }
        return result
    }

    static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return false
        }
        return true
    }

    static func isLikelyPlainTextFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty else { return false }
        let sample = Data(data.prefix(4096))
        guard let text = textString(from: sample) else { return false }
        let nonPrintable = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: return false
            case 0x20...0x7E, 0x80...: return false
            default: return true
            }
        }
        return Double(nonPrintable.count) / Double(max(text.count, 1)) < 0.05
    }

    static func looksLikeHTML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
            return true
        }
        return trimmed.contains("<") && trimmed.contains(">") && trimmed.contains("</")
    }

    static func usesEmbeddedScroller(for item: HistoryItem) -> Bool {
        switch item {
        case .pdf, .html:
            return true
        case .text(let str):
            if looksLikeHTML(str) { return true }
            return true
        case .files(let urls):
            guard urls.count == 1 else { return false }
            switch fileKind(for: urls[0]) {
            case .pdf, .html, .json, .markdown, .plainText:
                return true
            case .other:
                return isLikelyPlainTextFile(at: urls[0])
            default:
                return false
            }
        default:
            return false
        }
    }

}
