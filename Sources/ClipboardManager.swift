import AppKit
import Foundation
import CoreGraphics
import ApplicationServices
import CryptoKit

extension Notification.Name {
    static let clipboardHistoryDidChange = Notification.Name("clipboardHistoryDidChange")
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
}

struct FileHistoryItem: Codable {
    let id: UUID
    let fileName: String
    let filePath: String
    let fileSize: Int64
    let timestamp: Date
    let senderName: String
}

class ClipboardManager {
    static let shared = ClipboardManager()

    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: Timer?
    private(set) var history: [HistoryEntry] = []
    private(set) var totalHistoryCount = 0
    private var loadedCount = 100
    var hasMoreHistory: Bool { history.count < totalHistoryCount }
    var fileHistory: [FileHistoryItem] = []
    private var maxHistoryItems: Int { PreferencesManager.shared.historyLimit }
    private let repository = HistoryRepository.shared
    private let fileHistoryURL: URL
    private var lastSyncHash: String?
    
    // Performance optimization: debounce and content tracking
    private var lastCheckTime: Date = Date()
    private var pendingContentCheck: Bool = false
    private let minCheckInterval: TimeInterval = 0.3 // Reduced from 0.5s to 0.3s with better logic
    private var recentContentHashes: Set<String> = []
    private let recentContentHashesMaxSize = 50
    private var pendingIndexHashes: Set<String> = []
    private var pasteEventTap: CFMachPort?
    private var pasteEventTapRunLoopSource: CFRunLoopSource?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFormatter.date(from: dateStr) {
                return date
            }

            isoFormatter.formatOptions = [.withInternetDateTime]
            if let date = isoFormatter.date(from: dateStr) {
                return date
            }

            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                "yyyy-MM-dd'T'HH:mm:ss.SSS",
                "yyyy-MM-dd'T'HH:mm:ss"
            ]
            let df = DateFormatter()
            df.calendar = Calendar(identifier: .iso8601)
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            for format in formats {
                df.dateFormat = format
                if let date = df.date(from: dateStr) {
                    return date
                }
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateStr)")
        }
        return decoder
    }()

    var onHistoryChanged: (([HistoryEntry]) -> Void)?
    var onFileHistoryChanged: (([FileHistoryItem]) -> Void)?

    private init() {
        self.changeCount = pasteboard.changeCount

        // Setup storage
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("ClipyClone")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileHistoryURL = appSupport.appendingPathComponent("file_history.json")

        HistoryRepository.shared.migrateFromLegacyJSONIfNeeded()
        HistoryRepository.shared.clearTextSearchIndexes()
        loadHistory()
        loadFileHistory()
        startPolling()
        backfillSearchIndexesIfNeeded()
        startPasteUsageMonitoringIfNeeded()
        
        // Initialize recent content hashes from existing history
        updateRecentContentHashes()
    }
    
    private func updateRecentContentHashes() {
        recentContentHashes.removeAll()
        for entry in history.prefix(recentContentHashesMaxSize) {
            if let hash = entry.contentHash {
                recentContentHashes.insert(hash)
            }
        }
    }
    
    private func loadFileHistory() {
        if let data = try? Data(contentsOf: fileHistoryURL),
           let savedHistory = try? decoder.decode([FileHistoryItem].self, from: data) {
            self.fileHistory = savedHistory
        }
    }
    
    func saveFileHistory() {
        if let data = try? encoder.encode(fileHistory) {
            try? data.write(to: fileHistoryURL)
            onFileHistoryChanged?(fileHistory)
        }
    }
    
    func addToFileHistory(fileName: String, filePath: String, fileSize: Int64, senderName: String) {
        let item = FileHistoryItem(
            id: UUID(),
            fileName: fileName,
            filePath: filePath,
            fileSize: fileSize,
            timestamp: Date(),
            senderName: senderName
        )
        fileHistory.insert(item, at: 0)
        if fileHistory.count > 20 {
            fileHistory.removeLast()
        }
        saveFileHistory()
    }
    
    private func loadHistory() {
        loadedCount = PreferencesManager.shared.historyLoadCount
        if HistoryMediaStore.shared.consumeLegacyMigrationNeeded() {
            reimportHistoryForLegacyMediaMigration()
        }
        totalHistoryCount = repository.count()
        history = repository.fetch(limit: loadedCount)
        pruneUnreferencedMediaFiles()
    }

    private func reloadLoadedHistory() {
        totalHistoryCount = repository.count()
        history = repository.fetch(limit: loadedCount)
    }

    func loadMoreHistory() {
        guard hasMoreHistory else { return }
        loadedCount = min(loadedCount + PreferencesManager.shared.historyLoadCount, totalHistoryCount)
        history = repository.fetch(limit: loadedCount)
        notifyHistoryChanged()
    }

    private func reimportHistoryForLegacyMediaMigration() {
        let all = repository.fetchAll(includeSearchIndex: true)
        for entry in all {
            _ = repository.insertOrReplace(entry)
        }
    }

    @discardableResult
    func setHistoryEncryptionEnabled(_ enabled: Bool) -> Bool {
        let previous = PreferencesManager.shared.isHistoryEncryptionEnabled
        guard previous != enabled else { return true }

        PreferencesManager.shared.isHistoryEncryptionEnabled = enabled
        let paths = repository.referencedStoragePaths()
        HistoryMediaStore.shared.reencryptReferencedFiles(keeping: paths, wasEncrypted: previous)
        return true
    }

    private func startPolling() {
        Timer.scheduledTimer(withTimeInterval: minCheckInterval, repeats: true) { [weak self] _ in
            self?.checkPasteboardWithDebounce()
        }
    }

    private func checkPasteboardWithDebounce() {
        let now = Date()
        let timeSinceLastCheck = now.timeIntervalSince(lastCheckTime)
        
        // If clipboard hasn't changed, skip processing
        guard pasteboard.changeCount != changeCount else { return }
        
        // Implement debounce: if we've checked recently, delay this check
        if timeSinceLastCheck < minCheckInterval {
            if !pendingContentCheck {
                pendingContentCheck = true
                // Schedule a check after the debounce period
                DispatchQueue.main.asyncAfter(deadline: .now() + (minCheckInterval - timeSinceLastCheck)) { [weak self] in
                    self?.processPendingContentCheck()
                }
            }
            return
        }
        
        // Process immediately if enough time has passed
        lastCheckTime = now
        pendingContentCheck = false
        processClipboardContent()
    }
    
    private func processPendingContentCheck() {
        if pendingContentCheck {
            pendingContentCheck = false
            lastCheckTime = Date()
            processClipboardContent()
        }
    }
    
    private func processClipboardContent() {
        changeCount = pasteboard.changeCount

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceApp = frontmostApp?.localizedName
        let bundleIdentifier = frontmostApp?.bundleIdentifier

        appLog("Clipboard changed. Source: \(sourceApp ?? "Unknown") (\(bundleIdentifier ?? "N/A"))")

        // Clipy feature: Exclude sensitive apps (e.g., Password managers)
        if let bundleID = bundleIdentifier, PreferencesManager.shared.excludedApps.contains(bundleID) {
            return
        }

        guard let item = historyItemFromCurrentPasteboard() else { return }
        addToHistory(item, sourceApp: sourceApp, sourceBundleId: bundleIdentifier)
    }

    private func historyItemFromCurrentPasteboard() -> HistoryItem? {
        let store = HistoryMediaStore.shared
        if let fileURLs = readFileURLsFromPasteboard(), !fileURLs.isEmpty {
            return .files(fileURLs)
        }
        if let rtfData = pasteboard.data(forType: .rtf) {
            return .rtf(store.store(data: rtfData, kind: .rtf))
        }
        if let htmlData = pasteboard.data(forType: .html) {
            return .html(store.store(data: htmlData, kind: .html))
        }
        if let pdfData = pasteboard.data(forType: .pdf) {
            return .pdf(store.store(data: pdfData, kind: .pdf))
        }
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            return .image(store.store(data: imageData, kind: .image))
        }
        if let newString = pasteboard.string(forType: .string), !newString.isEmpty {
            return .text(newString)
        }
        return nil
    }

    func startPasteUsageMonitoringIfNeeded() {
        guard AccessibilityManager.isTrusted, pasteEventTap == nil else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passRetained(event)
                }
                guard type == .keyDown else {
                    return Unmanaged.passRetained(event)
                }

                let flags = event.flags
                guard flags.contains(.maskCommand),
                      !flags.contains(.maskAlternate),
                      event.getIntegerValueField(.keyboardEventKeycode) == 0x09 else {
                    return Unmanaged.passRetained(event)
                }

                let manager = Unmanaged<ClipboardManager>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.recordUsageIfPasteboardMatchesHistory()
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: userInfo
        ) else {
            return
        }

        pasteEventTap = tap
        pasteEventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let pasteEventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), pasteEventTapRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func recordUsageIfPasteboardMatchesHistory() {
        guard let item = historyItemFromCurrentPasteboard(),
              let entry = historyEntry(matching: item) else { return }
        recordHistoryUsage(entry)
        moveHistoryEntryToFront(entry)
    }

    private func historyEntry(matching item: HistoryItem) -> HistoryEntry? {
        let hash = contentHash(for: item)
        if let entry = repository.findMatching(item: item, contentHash: hash) {
            return entry
        }
        if case .text(let text) = item {
            let fileEntries = repository.fetchFiltered(
                filters: SearchHistoryFilters(typeFilter: .file),
                includeSearchIndex: false
            )
            return fileEntries.first { entry in
                guard case .files = entry.item else { return false }
                return plainText(for: entry.item) == text
            }
        }
        return nil
    }

    private func addToHistory(_ item: HistoryItem, sourceApp: String?, sourceBundleId: String? = nil) {
        let hash = contentHash(for: item)
        appLog("Adding to history: \(item.title), Hash: \(hash?.prefix(8) ?? "N/A")")

        if let nh = hash, nh != lastSyncHash {
            if case .text(let str) = item {
                SyncManager.shared.broadcastSync(content: str, hash: nh)
            }
        }

        let searchIndex = HistorySearchIndexBuilder.buildIndex(for: item)
        let existing = repository.findMatching(item: item, contentHash: hash)
        let entry = HistoryEntry(
            item: item,
            date: Date(),
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            contentHash: hash,
            isPinned: existing?.isPinned ?? false,
            searchIndex: searchIndex,
            lastUsedAt: existing?.lastUsedAt,
            useCount: existing?.useCount ?? 0
        )

        _ = repository.insertOrReplace(entry)
        repository.trimToLimit(maxHistoryItems)
        reloadLoadedHistory()

        scheduleImageOCRIfNeeded(for: entry)

        if let hash = hash {
            recentContentHashes.insert(hash)
            if recentContentHashes.count > recentContentHashesMaxSize {
                updateRecentContentHashes()
            }
        }

        notifyHistoryChanged()
    }

    private func notifyHistoryChanged() {
        onHistoryChanged?(history)
        NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
    }
    
    func handleRemoteSync(content: String, hash: String) {
        appLog("Handling remote sync: \(hash.prefix(8))")
        // Prevent loop if we already have this content
        guard hash != lastSyncHash else { 
            appLog("Sync loop detected or duplicate hash, ignoring")
            return 
        }
        
        
        lastSyncHash = hash
        
        // Update pasteboard
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        changeCount = pasteboard.changeCount
        
        // Add to history
        addToHistory(.text(content), sourceApp: "Remote Device")
    }

    func availableSourceApps() -> [String] {
        repository.distinctSourceApps()
    }

    func searchHistory(
        query: String,
        typeFilter: HistoryTypeFilter = .all,
        sourceApp: String? = nil
    ) -> [HistoryEntry] {
        searchHistory(options: SearchHistoryOptions(
            query: query,
            typeFilter: typeFilter,
            sourceApp: sourceApp
        )).map(\.entry)
    }

    func searchHistory(options: SearchHistoryOptions) -> [HistorySearchResult] {
        let parsed = HistorySearchQueryParser.parse(options.query)
        let effectiveType = parsed.typeFilter ?? options.typeFilter
        let effectiveSource = parsed.sourceApp ?? options.sourceApp
        let effectivePinnedOnly = parsed.pinnedOnly || options.pinnedOnly
        let effectivePath = parsed.pathContains ?? options.pathContains
        let effectiveURLOnly = parsed.urlOnly || options.urlOnly
        let textQuery = parsed.textTerms.joined(separator: " ")

        let trimmed = textQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let browseLoadedOnly = trimmed.isEmpty && !hasActiveSearchFilters(
            options: options,
            effectiveType: effectiveType,
            effectiveSource: effectiveSource,
            effectivePinnedOnly: effectivePinnedOnly,
            effectivePath: effectivePath,
            effectiveURLOnly: effectiveURLOnly
        )
        let filters = SearchHistoryFilters(
            typeFilter: effectiveType,
            sourceApp: effectiveSource,
            dateFilter: options.dateFilter,
            pinnedOnly: effectivePinnedOnly,
            pathContains: effectivePath,
            urlOnly: effectiveURLOnly
        )
        let ordered = browseLoadedOnly
            ? history
            : repository.fetchFiltered(
                filters: filters,
                textQuery: trimmed.isEmpty ? nil : trimmed,
                includeSearchIndex: false
            )
        let filtered = ordered.filter { entry in
            if let category = options.contentCategory, !category.matches(entry) {
                return false
            }
            if effectiveURLOnly {
                let text = entry.resolvedText ?? entry.item.title
                guard text.contains("://") else { return false }
            }
            return true
        }

        guard !trimmed.isEmpty else {
            return filtered.map {
                HistorySearchResult(entry: $0, highlightRanges: [])
            }
        }

        return HistorySearchRanker.rank(
            entries: filtered,
            query: trimmed,
            useRegex: options.useRegex,
            loadFullTextIfNeeded: true
        )
    }

    private func hasActiveSearchFilters(
        options: SearchHistoryOptions,
        effectiveType: HistoryTypeFilter,
        effectiveSource: String?,
        effectivePinnedOnly: Bool,
        effectivePath: String?,
        effectiveURLOnly: Bool
    ) -> Bool {
        effectiveType != .all
            || effectiveSource != nil
            || effectivePinnedOnly
            || effectivePath != nil
            || effectiveURLOnly
            || options.contentCategory != nil
            || options.dateFilter != .all
    }

    func removeHistoryEntry(_ entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        guard repository.delete(contentHash: hash, item: entry.item) else { return }
        reloadLoadedHistory()
        updateRecentContentHashes()
        pruneUnreferencedMediaFiles()
        notifyHistoryChanged()
    }

    func removeHistoryEntries(_ entries: [HistoryEntry]) {
        guard !entries.isEmpty else { return }
        var removed = false
        for entry in entries {
            let hash = entry.contentHash ?? contentHash(for: entry.item)
            if repository.delete(contentHash: hash, item: entry.item) {
                removed = true
            }
        }
        guard removed else { return }
        reloadLoadedHistory()
        updateRecentContentHashes()
        pruneUnreferencedMediaFiles()
        notifyHistoryChanged()
    }

    func recordHistoryUsage(_ entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        guard repository.update(contentHash: hash, item: entry.item, transform: { stored in
            stored.useCount += 1
            stored.lastUsedAt = Date()
        }) != nil else { return }
        reloadLoadedHistory()
        notifyHistoryChanged()
    }

    func orderedHistory() -> [HistoryEntry] {
        history
    }

    func togglePin(for entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        guard repository.update(contentHash: hash, item: entry.item, transform: { stored in
            stored.isPinned.toggle()
            stored.date = Date()
        }) != nil else { return }
        reloadLoadedHistory()
        notifyHistoryChanged()
    }

    func clearHistory() {
        loadedCount = PreferencesManager.shared.historyLoadCount
        _ = repository.deleteAll()
        HistoryMediaStore.shared.removeAllManagedFiles()
        reloadLoadedHistory()
        updateRecentContentHashes()
        notifyHistoryChanged()
    }

    func applyHistoryLimit() {
        let previousTotal = totalHistoryCount
        repository.trimToLimit(maxHistoryItems)
        reloadLoadedHistory()
        guard totalHistoryCount != previousTotal else { return }
        updateRecentContentHashes()
        pruneUnreferencedMediaFiles()
        notifyHistoryChanged()
    }

    func moveHistoryEntryToFront(_ entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        guard repository.update(contentHash: hash, item: entry.item, transform: { stored in
            stored.date = Date()
        }) != nil else { return }
        reloadLoadedHistory()
        updateRecentContentHashes()
        notifyHistoryChanged()
    }

    private func pruneUnreferencedMediaFiles() {
        let referenced = repository.referencedStoragePaths()
        HistoryMediaStore.shared.removeUnreferencedFiles(keeping: referenced)
    }

    func writePlainTextToPasteboard(_ item: HistoryItem, textPath: String? = nil) {
        pasteboard.clearContents()
        if let text = plainText(for: item, textPath: textPath) {
            pasteboard.setString(text, forType: .string)
            changeCount = pasteboard.changeCount
        }
    }

    func plainText(for item: HistoryItem, textPath: String? = nil) -> String? {
        if let textPath, let text = HistoryMediaStore.shared.text(at: textPath) {
            return text
        }
        switch item {
        case .text(let str):
            return str
        case .rtf(let path):
            return HistorySearchIndexBuilder.buildIndex(for: .rtf(path))
        case .html(let path):
            return HistorySearchIndexBuilder.buildIndex(for: .html(path))
        case .pdf(let path):
            return HistorySearchIndexBuilder.buildIndex(for: .pdf(path))
        case .image:
            return nil
        case .files(let urls):
            return urls.map(\.lastPathComponent).joined(separator: "\n")
        }
    }

    func plainText(for entry: HistoryEntry) -> String? {
        plainText(for: entry.item, textPath: entry.textPath)
    }

    func applyHistoryEntry(_ entry: HistoryEntry, action: HistorySelectAction) {
        switch action {
        case .copyOnly:
            if case .files(let urls) = entry.item {
                writeFileNamesToPasteboard(urls)
            } else {
                writeToPasteboard(entry.item, textPath: entry.textPath)
            }
            moveHistoryEntryToFront(entry)
        case .pastePlainAndClose, .pastePlainKeepOpen:
            writePlainTextToPasteboard(entry.item, textPath: entry.textPath)
            moveHistoryEntryToFront(entry)
            let keepOpen = action == .pastePlainKeepOpen
            if !keepOpen { SearchWindow.shared.closeWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.simulatePasteIfTrusted() }
        case .pasteKeepOpen:
            performPaste(entry: entry, pasteFileAsName: true, closeWindow: false)
        case .pasteAndClose:
            performPaste(entry: entry, pasteFileAsName: true, closeWindow: true)
        }
    }

    private func performPaste(entry: HistoryEntry, pasteFileAsName: Bool, closeWindow: Bool) {
        moveHistoryEntryToFront(entry)

        let shouldAutoPaste: Bool
        if case .files(let urls) = entry.item, pasteFileAsName {
            writeFileNamesToPasteboard(urls)
            shouldAutoPaste = true
        } else if case .files = entry.item {
            writeToPasteboard(entry.item)
            shouldAutoPaste = false
        } else {
            writeToPasteboard(entry.item, textPath: entry.textPath)
            shouldAutoPaste = itemSupportsAutoPaste(entry.item)
        }

        if closeWindow {
            SearchWindow.shared.closeWindow()
        }

        guard shouldAutoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.simulatePasteIfTrusted() }
    }

    private func backfillSearchIndexesIfNeeded() {
        let pending = repository.entriesNeedingSearchIndex(limit: 100)
        guard !pending.isEmpty else { return }

        var changed = false
        for entry in pending {
            if let built = buildSearchIndex(for: entry) {
                if let hash = entry.contentHash {
                    if repository.updateSearchIndex(contentHash: hash, text: built) {
                        changed = true
                    }
                }
            }
            scheduleImageOCRIfNeeded(for: entry)
        }
        if changed {
            notifyHistoryChanged()
        }
    }

    private func buildSearchIndex(for entry: HistoryEntry) -> String? {
        if case .text = entry.item { return nil }
        return HistorySearchIndexBuilder.buildIndex(for: entry.item)
    }

    private func scheduleImageOCRIfNeeded(for entry: HistoryEntry) {
        guard case .image = entry.item, let hash = entry.contentHash else { return }
        guard !pendingIndexHashes.contains(hash) else { return }
        pendingIndexHashes.insert(hash)
        HistorySearchIndexBuilder.scheduleOCR(for: entry, contentHash: hash) { [weak self] contentHash, text in
            guard let self else { return }
            self.pendingIndexHashes.remove(contentHash)
            if self.repository.updateSearchIndex(contentHash: contentHash, text: text) {
                self.notifyHistoryChanged()
            }
        }
    }

    func writeToPasteboard(_ item: HistoryItem, textPath: String? = nil) {
        let store = HistoryMediaStore.shared
        pasteboard.clearContents()
        switch item {
        case .text:
            if let text = plainText(for: item, textPath: textPath) {
                pasteboard.setString(text, forType: .string)
            }
        case .image(let path):
            if let data = store.data(at: path) {
                pasteboard.setData(data, forType: .tiff)
            }
        case .rtf(let path):
            if let data = store.data(at: path) {
                pasteboard.setData(data, forType: .rtf)
            }
        case .pdf(let path):
            if let data = store.data(at: path) {
                pasteboard.setData(data, forType: .pdf)
            }
        case .html(let path):
            if let data = store.data(at: path) {
                pasteboard.setData(data, forType: .html)
                if let str = HistoryPreviewSupport.htmlString(from: data) {
                    pasteboard.setString(str, forType: .string)
                }
                let fileURLs = fileURLsFromHTMLData(data)
                if !fileURLs.isEmpty {
                    pasteboard.writeObjects(fileURLs as [NSURL])
                }
            }
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
        changeCount = pasteboard.changeCount
    }

    func writeFileNamesToPasteboard(_ urls: [URL]) {
        let text = urls.map(\.lastPathComponent).joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changeCount = pasteboard.changeCount
    }

    func copyFileNamesToPasteboard(_ urls: [URL], simulatePaste: Bool = true) {
        writeFileNamesToPasteboard(urls)
        guard simulatePaste, AccessibilityManager.ensureTrustedForPaste() else { return }
        paste()
    }

    func copyToPasteboard(_ item: HistoryItem, simulatePaste: Bool = true) {
        writeToPasteboard(item)
        if case .files = item { return }
        guard simulatePaste, itemSupportsAutoPaste(item) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.simulatePasteIfTrusted()
        }
    }

    private func itemSupportsAutoPaste(_ item: HistoryItem) -> Bool {
        switch item {
        case .text, .html, .rtf:
            return true
        default:
            return false
        }
    }

    func simulatePasteIfTrusted() {
        startPasteUsageMonitoringIfNeeded()
        guard AccessibilityManager.ensureTrustedForPaste() else { return }
        paste()
    }
    
    private func paste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // Command + V Key Down
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vKeyDown?.flags = .maskCommand
        
        // Command + V Key Up
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vKeyUp?.flags = .maskCommand
        
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)
    }
    
    private func isSameHistoryItem(_ entry: HistoryEntry, as item: HistoryItem, contentHash hash: String?) -> Bool {
        if let existingHash = entry.contentHash, let hash = hash {
            return existingHash == hash
        }
        
        switch (entry.item, item) {
        case (.text(let s1), .text(let s2)):
            return s1 == s2
        case (.files(let u1), .files(let u2)):
            return u1 == u2
        case (.image(let p1), .image(let p2)),
             (.rtf(let p1), .rtf(let p2)),
             (.pdf(let p1), .pdf(let p2)),
             (.html(let p1), .html(let p2)):
            return p1 == p2
        default:
            return false
        }
    }
    
    private func contentHash(for item: HistoryItem) -> String? {
        switch item {
        case .text(let str):
            let normalized = str.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            guard let data = normalized.data(using: .utf8) else { return nil }
            return sha256Hex(data)
        case .image(let path):
            return HistoryMediaStore.shared.contentHash(forPath: path)
        case .rtf(let path):
            return HistoryMediaStore.shared.contentHash(forPath: path)
        case .pdf(let path):
            return HistoryMediaStore.shared.contentHash(forPath: path)
        case .html(let path):
            return HistoryMediaStore.shared.contentHash(forPath: path)
        case .files(let urls):
            let s = urls.map(\.absoluteString).joined(separator: "\n")
            guard let data = s.data(using: .utf8) else { return nil }
            return sha256Hex(data)
        }
    }

    private func readFileURLsFromPasteboard() -> [URL]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], !urls.isEmpty {
            return urls
        }

        let legacyType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: legacyType) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }

        if let fileURLString = pasteboard.string(forType: .fileURL) {
            if let url = URL(string: fileURLString), url.isFileURL {
                return [url]
            }
            if fileURLString.hasPrefix("/") {
                return [URL(fileURLWithPath: fileURLString)]
            }
        }

        return nil
    }

    private func fileURLsFromHTMLData(_ data: Data) -> [URL] {
        guard let html = HistoryPreviewSupport.htmlString(from: data) else { return [] }
        return fileURLsFromHTML(html)
    }

    private func fileURLsFromHTML(_ html: String) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href=\"(file://[^\"]+)\""#,
            options: .caseInsensitive
        ) else { return [] }

        var urls: [URL] = []
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let urlRange = Range(match.range(at: 1), in: html) else { return }
            let urlString = String(html[urlRange])
            if let url = URL(string: urlString), url.isFileURL {
                urls.append(url)
            }
        }
        return urls
    }

    func revealInFinder(for entry: HistoryEntry) {
        guard let urls = entry.item.fileURLs else { return }
        FilePathDisplay.revealInFinder(urls: urls)
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
