import SwiftUI
import AppKit
import PDFKit

/// Content card of the history window's preview column. The type badge,
/// facts and actions around it live in `SearchView`.
struct HistoryPreviewView: View {
    let entry: HistoryEntry?
    /// Current (non-regex) search text, highlighted in the preview.
    var query: String = ""
    var onRevealInFinder: (HistoryEntry) -> Void = { _ in }

    static let contentInsets = EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26)

    var body: some View {
        Group {
            if let entry {
                previewBody(for: entry)
            } else {
                EmptyStateView(message: L10n.t(.selectHistoryToPreview), symbol: "doc.text.magnifyingglass")
            }
        }
        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func previewBody(for entry: HistoryEntry) -> some View {
        switch entry.item {
        case .text:
            if let text = entry.resolvedText {
                textItemPreview(text)
            } else {
                EmptyStateView(message: L10n.t(.historyPreviewLoadFailed))
            }

        case .image(let path):
            AsyncHistoryImagePreviewView(path: path, ocrHit: ocrHit(for: entry))

        case .rtf(let path):
            AsyncRTFPreviewView(path: path)

        case .pdf(let path):
            AsyncPDFHistoryPreviewView(path: path)

        case .html(let path):
            AsyncHTMLHistoryPreviewView(path: path)

        case .files(let urls):
            filesPreview(entry: entry, urls: urls)
        }
    }

    private func ocrHit(for entry: HistoryEntry) -> String? {
        let query = trimmedQuery
        guard !query.isEmpty, let index = entry.searchIndex,
              index.localizedCaseInsensitiveContains(query) else { return nil }
        return query
    }

    @ViewBuilder
    private func textItemPreview(_ str: String) -> some View {
        let kind = HistoryPreviewSupport.resolvedTextKind(for: str)
        if kind == .html {
            HTMLPreviewRepresentable(html: str)
                .padding(AppSpacing.xs)
        } else {
            let payload = HistoryPreviewSupport.textPreviewPayload(for: str, kind: kind)
            TextPreviewPanel(payload: payload, highlight: trimmedQuery)
        }
    }

    @ViewBuilder
    private func filesPreview(entry: HistoryEntry, urls: [URL]) -> some View {
        if urls.count == 1 {
            singleFilePreview(entry: entry, url: urls[0])
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                        fileCard(entry: entry, url: url)
                    }
                }
                .padding(Self.contentInsets)
            }
        }
    }

    @ViewBuilder
    private func singleFilePreview(entry: HistoryEntry, url: URL) -> some View {
        let kind = HistoryPreviewSupport.fileKind(for: url)
        switch kind {
        case .image:
            AsyncLocalImagePreviewView(url: url)
        case .pdf:
            AsyncPDFFilePreviewView(url: url)
        case .html:
            HTMLFilePreviewRepresentable(url: url)
                .padding(AppSpacing.xs)
        case .json, .markdown, .plainText:
            AsyncTextFilePreviewView(url: url, kind: kind)
        case .other:
            if HistoryPreviewSupport.isLikelyPlainTextFile(at: url) {
                AsyncTextFilePreviewView(url: url, kind: .plainText)
            } else {
                fileCard(entry: entry, url: url)
                    .padding(Self.contentInsets)
            }
        }
    }

    /// Design `.doc` file card: tile, highlighted name, path and Finder button.
    private func fileCard(entry: HistoryEntry, url: URL) -> some View {
        let archive = ["zip", "rar", "7z", "gz", "tar", "tgz", "xz", "bz2"].contains(url.pathExtension.lowercased())
        return HStack(alignment: .center, spacing: 14) {
            HistoryTypeTile(kind: .file, symbol: archive ? "doc.zipper" : "doc", size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(HistoryRowText.highlighted(
                    title: url.lastPathComponent,
                    ranges: HistorySearchRanker.highlightRanges(for: url.lastPathComponent, terms: trimmedQuery.split(whereSeparator: \.isWhitespace).map(String.init))
                ))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                Text(FilePathDisplay.string(for: url))
                    .font(.system(size: 12.5))
                    .foregroundStyle(HistoryV3.text3)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(url.path)
                Button(L10n.t(.showInFinder)) { onRevealInFinder(entry) }
                    .buttonStyle(HistoryActionButtonStyle(small: true))
                    .padding(.top, 7)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HistoryV3.line, lineWidth: 0.5))
    }
}

/// Secondary fact next to the preview's type badge: characters for text,
/// pixel size for images, item count for files. Loaded off the main thread.
struct HistoryPreviewDetailText: View {
    let entry: HistoryEntry
    @State private var detail: String?

    var body: some View {
        Text(detail ?? " ")
            .font(.system(size: 11.5))
            .foregroundStyle(HistoryV3.text3)
            .lineLimit(1)
            .task(id: entry.id) {
                detail = nil
                let entry = entry
                detail = await Task.detached(priority: .utility) { Self.compute(entry) }.value
            }
    }

    nonisolated private static func compute(_ entry: HistoryEntry) -> String? {
        switch entry.item {
        case .files(let urls):
            return L10n.format(.historyFileCount, urls.count)
        case .image(let path):
            guard let data = HistoryMediaStore.shared.data(at: path),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return "\(width) × \(height)"
        case .text:
            guard let text = entry.resolvedText else { return nil }
            return L10n.format(.historyCharacterCount, text.count)
        case .rtf, .html, .pdf:
            guard let text = ClipboardManager.shared.plainText(for: entry) else { return nil }
            return L10n.format(.historyCharacterCount, text.count)
        }
    }
}

private struct AsyncRTFPreviewView: View {
    let path: String
    @State private var attributed: NSAttributedString?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let attributed {
                if attributed.length > HistoryPreviewSupport.swiftUITextThreshold {
                    PlainTextPreviewRepresentable(text: attributed.string)
                } else {
                    ScrollView {
                        Text(AttributedString(attributed))
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(HistoryPreviewView.contentInsets)
                    }
                }
            } else {
                previewTypePlaceholder(icon: "doc.richtext", label: L10n.t(.historyTypeRTF))
            }
        }
        .task(id: path) {
            isLoading = true
            attributed = nil
            let loaded = await Task.detached(priority: .utility) { () -> NSAttributedString? in
                guard let data = HistoryMediaStore.shared.data(at: path) else { return nil }
                return try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
            }.value
            attributed = loaded
            isLoading = false
        }
    }
}

private struct AsyncHTMLHistoryPreviewView: View {
    let path: String
    @State private var html: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let html {
                HTMLPreviewRepresentable(html: html)
                    .padding(AppSpacing.xs)
            } else {
                previewTypePlaceholder(
                    icon: "chevron.left.forwardslash.chevron.right",
                    label: L10n.t(.historyTypeHTML)
                )
            }
        }
        .task(id: path) {
            isLoading = true
            html = nil
            let loaded = await Task.detached(priority: .utility) { () -> String? in
                guard let data = HistoryMediaStore.shared.data(at: path) else { return nil }
                return HistoryPreviewSupport.htmlString(from: data)
            }.value
            html = loaded
            isLoading = false
        }
    }
}

private enum PDFHistoryLoadResult {
    case document(URL)
    case fallback(byteCount: Int)
}

private struct AsyncPDFHistoryPreviewView: View {
    let path: String
    @State private var result: PDFHistoryLoadResult?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .document(let url) = result {
                PDFFilePreviewRepresentable(url: url)
            } else if case .fallback(let size) = result {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    previewTypePlaceholder(icon: "doc.fill", label: L10n.t(.historyTypePDF))
                    Text(L10n.format(.historyDataSize, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                previewTypePlaceholder(icon: "doc.fill", label: L10n.t(.historyTypePDF))
            }
        }
        .task(id: path) {
            isLoading = true
            result = nil
            let loaded = await Task.detached(priority: .utility) { () -> PDFHistoryLoadResult in
                let url = URL(fileURLWithPath: path)
                if PDFDocument(url: url) != nil {
                    return .document(url)
                }
                let byteCount = HistoryMediaStore.shared.data(at: path)?.count ?? 0
                return .fallback(byteCount: byteCount)
            }.value
            result = loaded
            isLoading = false
        }
    }
}

private func previewTypePlaceholder(icon: String, label: String) -> some View {
    VStack(spacing: AppSpacing.sm) {
        Image(systemName: icon)
            .font(.system(size: 40))
            .foregroundStyle(.secondary)
        Text(label)
            .font(AppFont.body)
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppSpacing.lg)
}

private struct AsyncHistoryImagePreviewView: View {
    let path: String
    /// Query text found in the image's recognised (OCR) text, if any.
    var ocrHit: String?
    private let maxPixelSize = 1600
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(HistoryV3.line, lineWidth: 0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    if let ocrHit {
                        Text(ocrCaption(ocrHit))
                            .font(.system(size: 12))
                            .foregroundStyle(HistoryV3.text3)
                    }
                }
                .padding(HistoryPreviewView.contentInsets)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            image = nil
            let loaded = await Task.detached(priority: .utility) {
                ImageDownsampler.thumbnail(at: path, maxPixelSize: maxPixelSize)
            }.value
            image = loaded
        }
    }

    private func ocrCaption(_ hit: String) -> AttributedString {
        var mark = AttributedString(hit)
        mark.backgroundColor = HistoryV3.mark
        return AttributedString(HistoryV3.s("已识别图中文字，可按“", "Recognised text in this image; searching “"))
            + mark + AttributedString(HistoryV3.s("”搜到此图。", "” finds it."))
    }
}

private struct AsyncLocalImagePreviewView: View {
    let url: URL
    private let maxPixelSize = 1600
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small))
                    .padding(AppSpacing.sm)
            } else {
                filePreviewPlaceholder
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await Task.detached(priority: .utility) {
                ImageDownsampler.thumbnail(atFileURL: url, maxPixelSize: maxPixelSize)
            }.value
            image = loaded
        }
    }

    private var filePreviewPlaceholder: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(AppFont.body)
                    .lineLimit(2)
                Text(FilePathDisplay.string(for: url))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(AppSpacing.sm)
    }
}

/// `PDFDocument(url:)` parses the file to tell whether it is a readable PDF, so
/// the check runs off the main thread before the real preview is mounted.
private struct AsyncPDFFilePreviewView: View {
    let url: URL
    @State private var isReadable: Bool?

    var body: some View {
        Group {
            switch isReadable {
            case true:
                PDFFilePreviewRepresentable(url: url)
            case false:
                filePreviewPlaceholder
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            isReadable = nil
            let readable = await Task.detached(priority: .utility) {
                PDFDocument(url: url) != nil
            }.value
            isReadable = readable
        }
    }

    private var filePreviewPlaceholder: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(AppFont.body)
                    .lineLimit(2)
                Text(FilePathDisplay.string(for: url))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(AppSpacing.sm)
    }
}
