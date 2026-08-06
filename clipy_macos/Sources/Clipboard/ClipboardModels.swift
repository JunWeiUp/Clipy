import AppKit
import Foundation

/// Core clipboard-history data model: the item payload types plus the entry and
/// summary shapes the rest of the app persists, syncs and renders. Split out of
/// ClipboardManager, which now only holds behaviour.

extension Notification.Name {
    static let clipboardHistoryDidChange = Notification.Name("clipboardHistoryDidChange")
    static let historyEncryptionDidFinish = Notification.Name("historyEncryptionDidFinish")
}

enum HistoryItem: Codable {
    case text(String)
    case image(String)
    case rtf(String)
    case pdf(String)
    case html(String)
    case files([URL])

    enum CodingKeys: String, CodingKey {
        case text
        case imagePath, rtfPath, pdfPath, htmlPath
        case image, rtf, pdf, html
        case fileURL, files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let store = HistoryMediaStore.shared
        if let value = try? container.decode(String.self, forKey: .text) {
            self = .text(value)
        } else if let path = try? container.decode(String.self, forKey: .imagePath) {
            self = .image(path)
        } else if let data = try? container.decode(Data.self, forKey: .image) {
            self = .image(store.storeLegacy(data: data, kind: .image))
        } else if let path = try? container.decode(String.self, forKey: .rtfPath) {
            self = .rtf(path)
        } else if let data = try? container.decode(Data.self, forKey: .rtf) {
            self = .rtf(store.storeLegacy(data: data, kind: .rtf))
        } else if let path = try? container.decode(String.self, forKey: .pdfPath) {
            self = .pdf(path)
        } else if let data = try? container.decode(Data.self, forKey: .pdf) {
            self = .pdf(store.storeLegacy(data: data, kind: .pdf))
        } else if let path = try? container.decode(String.self, forKey: .htmlPath) {
            self = .html(path)
        } else if let data = try? container.decode(Data.self, forKey: .html) {
            self = .html(store.storeLegacy(data: data, kind: .html))
        } else if let value = try? container.decode([URL].self, forKey: .files) {
            self = .files(value)
        } else if let value = try? container.decode(URL.self, forKey: .fileURL) {
            self = .files([value])
        } else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "Invalid HistoryItem format")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .image(let path):
            try container.encode(path, forKey: .imagePath)
        case .rtf(let path):
            try container.encode(path, forKey: .rtfPath)
        case .pdf(let path):
            try container.encode(path, forKey: .pdfPath)
        case .html(let path):
            try container.encode(path, forKey: .htmlPath)
        case .files(let urls):
            if urls.count == 1 {
                try container.encode(urls[0], forKey: .fileURL)
            } else {
                try container.encode(urls, forKey: .files)
            }
        }
    }

    var fileURLs: [URL]? {
        if case .files(let urls) = self { return urls }
        return nil
    }

    var isFile: Bool {
        if case .files = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .text(let str):
            return str.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .image:
            return "[Image]"
        case .rtf:
            return "[Rich Text]"
        case .pdf:
            return "[PDF Document]"
        case .html:
            return "[HTML]"
        case .files(let urls):
            guard !urls.isEmpty else { return "[File]" }
            if urls.count == 1 {
                return urls[0].lastPathComponent
            }
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            return "[\(urls.count) Files] \(names)"
        }
    }

    var locationSummary: String? {
        if let path = storedMediaPath {
            return FilePathDisplay.shorten(path)
        }
        guard case .files(let urls) = self, !urls.isEmpty else { return nil }
        if urls.count == 1 {
            return FilePathDisplay.string(for: urls[0])
        }
        return urls.map { FilePathDisplay.string(for: $0) }.joined(separator: "\n")
    }

    var fileNamesText: String? {
        guard case .files(let urls) = self, !urls.isEmpty else { return nil }
        return urls.map(\.lastPathComponent).joined(separator: "\n")
    }
}

enum HistoryTypeFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file
    case richText

    var id: String { rawValue }

    var labelKey: L10nKey {
        switch self {
        case .all: return .historyFilterAll
        case .text: return .historyTypeText
        case .image: return .historyTypeImage
        case .file: return .historyTypeFile
        case .richText: return .historyFilterRichText
        }
    }

    func matches(_ item: HistoryItem) -> Bool {
        switch self {
        case .all:
            return true
        case .text:
            if case .text = item { return true }
            return false
        case .image:
            if case .image = item { return true }
            return false
        case .file:
            return item.isFile
        case .richText:
            switch item {
            case .rtf, .html, .pdf:
                return true
            default:
                return false
            }
        }
    }
}

enum FilePathDisplay {
    static func string(for url: URL) -> String {
        shorten(url.path)
    }

    static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        if path == home {
            return "~"
        }
        return path
    }

    static func revealInFinder(urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

struct HistorySummary {
    let rowid: Int64
    var item: HistoryItem
    var date: Date
    let sourceApp: String?
    let sourceBundleId: String?
    let contentHash: String?
    var isPinned: Bool
    let textPath: String?

    func asEntry(
        searchIndex: String? = nil,
        lastUsedAt: Date? = nil,
        useCount: Int = 0
    ) -> HistoryEntry {
        HistoryEntry(
            item: item,
            date: date,
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            contentHash: contentHash,
            isPinned: isPinned,
            searchIndex: searchIndex,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            textPath: textPath
        )
    }

    static func from(entry: HistoryEntry, rowid: Int64) -> HistorySummary {
        HistorySummary(
            rowid: rowid,
            item: entry.item,
            date: entry.date,
            sourceApp: entry.sourceApp,
            sourceBundleId: entry.sourceBundleId,
            contentHash: entry.contentHash,
            isPinned: entry.isPinned,
            textPath: entry.textPath
        )
    }
}

struct HistoryEntry: Codable {
    var item: HistoryItem
    var date: Date
    let sourceApp: String?
    let sourceBundleId: String?
    let contentHash: String?
    var isPinned: Bool
    var searchIndex: String?
    var lastUsedAt: Date?
    var useCount: Int
    var textPath: String?

    init(
        item: HistoryItem,
        date: Date,
        sourceApp: String?,
        sourceBundleId: String? = nil,
        contentHash: String?,
        isPinned: Bool = false,
        searchIndex: String? = nil,
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        textPath: String? = nil
    ) {
        self.item = item
        self.date = date
        self.sourceApp = sourceApp
        self.sourceBundleId = sourceBundleId
        self.contentHash = contentHash
        self.isPinned = isPinned
        self.searchIndex = searchIndex
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.textPath = textPath
    }

    enum CodingKeys: String, CodingKey {
        case item, date, sourceApp, sourceBundleId, contentHash, isPinned
        case searchIndex, lastUsedAt, useCount, textPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try container.decode(HistoryItem.self, forKey: .item)
        date = try container.decode(Date.self, forKey: .date)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceBundleId = try container.decodeIfPresent(String.self, forKey: .sourceBundleId)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        searchIndex = try container.decodeIfPresent(String.self, forKey: .searchIndex)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        textPath = try container.decodeIfPresent(String.self, forKey: .textPath)
    }

    var listDisplayTitle: String {
        switch item {
        case .image:
            if isScreenshotCapture {
                return L10n.t(.screenshot)
            }
            return L10n.t(.historyTypeImage)
        default:
            return item.title
        }
    }

    private var isScreenshotCapture: Bool {
        sourceBundleId == Bundle.main.bundleIdentifier
            || sourceApp?.localizedCaseInsensitiveContains("screenshot") == true
    }
}

struct FileHistoryItem: Codable {
    let id: UUID
    let fileName: String
    let filePath: String
    let fileSize: Int64
    let timestamp: Date
    let senderName: String
}
