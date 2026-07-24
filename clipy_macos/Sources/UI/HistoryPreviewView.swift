import SwiftUI
import AppKit
import PDFKit

struct HistoryPreviewView: View {
    let entry: HistoryEntry?

    var body: some View {
        Group {
            if let entry {
                previewContent(for: entry)
            } else {
                EmptyStateView(message: L10n.t(.selectHistoryToPreview))
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    @ViewBuilder
    private func previewContent(for entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            previewHeader(for: entry)
            Divider()
            previewBody(for: entry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewHeader(for entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(typeLabel(for: entry.item))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                if entry.isPinned {
                    Label(L10n.t(.pinToTop), systemImage: "pin.fill")
                        .font(AppFont.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleOnly)
                }
            }
            if let source = entry.sourceApp {
                Text("\(L10n.t(.source)): \(source)")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(L10n.t(.time)): \(RelativeTimeFormatter.string(from: entry.date))")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Text("\(L10n.t(.pasteCount)): \(entry.useCount)")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
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
            AsyncHistoryImagePreviewView(path: path)

        case .rtf(let path):
            if let data = HistoryMediaStore.shared.data(at: path),
               let attributed = rtfAttributedString(from: data) {
                if attributed.length > HistoryPreviewSupport.swiftUITextThreshold {
                    PlainTextPreviewRepresentable(text: attributed.string)
                } else {
                    ScrollView {
                        Text(AttributedString(attributed))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppSpacing.sm)
                    }
                }
            } else {
                typePlaceholder(icon: "doc.richtext", label: L10n.t(.historyTypeRTF))
            }

        case .pdf(let path):
            let url = URL(fileURLWithPath: path)
            if PDFDocument(url: url) != nil {
                PDFFilePreviewRepresentable(url: url)
            } else if let data = HistoryMediaStore.shared.data(at: path) {
                pdfFallback(size: data.count)
            } else {
                pdfFallback(size: 0)
            }

        case .html(let path):
            if let data = HistoryMediaStore.shared.data(at: path),
               let html = HistoryPreviewSupport.htmlString(from: data) {
                HTMLPreviewRepresentable(html: html)
                    .padding(AppSpacing.xs)
            } else {
                typePlaceholder(icon: "chevron.left.forwardslash.chevron.right", label: L10n.t(.historyTypeHTML))
            }

        case .files(let urls):
            filesPreview(urls: urls)
        }
    }

    @ViewBuilder
    private func textItemPreview(_ str: String) -> some View {
        let kind = HistoryPreviewSupport.resolvedTextKind(for: str)
        if kind == .html {
            HTMLPreviewRepresentable(html: str)
                .padding(AppSpacing.xs)
        } else {
            let payload = HistoryPreviewSupport.textPreviewPayload(for: str, kind: kind)
            TextPreviewPanel(payload: payload)
        }
    }

    @ViewBuilder
    private func filesPreview(urls: [URL]) -> some View {
        if urls.count == 1 {
            singleFilePreview(url: urls[0])
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                        fileRow(for: url)
                    }
                }
                .padding(AppSpacing.sm)
            }
        }
    }

    @ViewBuilder
    private func singleFilePreview(url: URL) -> some View {
        let kind = HistoryPreviewSupport.fileKind(for: url)
        switch kind {
        case .image:
            AsyncLocalImagePreviewView(url: url)
        case .pdf:
            if PDFDocument(url: url) != nil {
                PDFFilePreviewRepresentable(url: url)
            } else {
                fileRow(for: url)
                    .padding(AppSpacing.sm)
            }
        case .html:
            HTMLFilePreviewRepresentable(url: url)
                .padding(AppSpacing.xs)
        case .json, .markdown, .plainText:
            AsyncTextFilePreviewView(url: url, kind: kind)
        case .other:
            if HistoryPreviewSupport.isLikelyPlainTextFile(at: url) {
                AsyncTextFilePreviewView(url: url, kind: .plainText)
            } else {
                fileRow(for: url)
                    .padding(AppSpacing.sm)
            }
        }
    }

    private func pdfFallback(size: Int) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            typePlaceholder(icon: "doc.fill", label: L10n.t(.historyTypePDF))
            Text(L10n.format(.historyDataSize, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fileRow(for url: URL) -> some View {
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
        .padding(AppSpacing.xs)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium))
    }

    private func typePlaceholder(icon: String, label: String) -> some View {
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

    private func typeLabel(for item: HistoryItem) -> String {
        switch item {
        case .text(let str):
            switch HistoryPreviewSupport.resolvedTextKind(for: str) {
            case .html: return L10n.t(.historyTypeHTML)
            case .json: return L10n.t(.historyTypeJSON)
            default: return L10n.t(.historyTypeText)
            }
        case .image: return L10n.t(.historyTypeImage)
        case .rtf: return L10n.t(.historyTypeRTF)
        case .pdf: return L10n.t(.historyTypePDF)
        case .html: return L10n.t(.historyTypeHTML)
        case .files(let urls):
            if urls.count == 1 {
                switch HistoryPreviewSupport.fileKind(for: urls[0]) {
                case .image: return L10n.t(.historyTypeImage)
                case .pdf: return L10n.t(.historyTypePDF)
                case .html: return L10n.t(.historyTypeHTML)
                case .json: return L10n.t(.historyTypeJSON)
                case .markdown: return L10n.t(.historyTypeMarkdown)
                case .plainText: return L10n.t(.historyTypePlainText)
                case .other:
                    if HistoryPreviewSupport.isLikelyPlainTextFile(at: urls[0]) {
                        return L10n.t(.historyTypePlainText)
                    }
                    return L10n.t(.historyTypeFile)
                }
            }
            return L10n.t(.historyTypeFile)
        }
    }

    private func rtfAttributedString(from data: Data) -> NSAttributedString? {
        try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }
}

private struct AsyncHistoryImagePreviewView: View {
    let path: String
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
