import AppKit
import Foundation
import CoreGraphics
import CryptoKit

extension Notification.Name {
    static let clipboardHistoryDidChange = Notification.Name("clipboardHistoryDidChange")
}

enum HistoryItem: Codable {
    case text(String)
    case image(Data)
    case rtf(Data)
    case pdf(Data)
    case html(Data)
    case files([URL])

    enum CodingKeys: String, CodingKey {
        case text, image, rtf, pdf, html, fileURL, files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .text) {
            self = .text(value)
        } else if let value = try? container.decode(Data.self, forKey: .image) {
            self = .image(value)
        } else if let value = try? container.decode(Data.self, forKey: .rtf) {
            self = .rtf(value)
        } else if let value = try? container.decode(Data.self, forKey: .pdf) {
            self = .pdf(value)
        } else if let value = try? container.decode(Data.self, forKey: .html) {
            self = .html(value)
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
        case .text(let value): try container.encode(value, forKey: .text)
        case .image(let value): try container.encode(value, forKey: .image)
        case .rtf(let value): try container.encode(value, forKey: .rtf)
        case .pdf(let value): try container.encode(value, forKey: .pdf)
        case .html(let value): try container.encode(value, forKey: .html)
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
    let item: HistoryItem
    let date: Date
    let sourceApp: String?
    let contentHash: String?
    var isPinned: Bool

    init(
        item: HistoryItem,
        date: Date,
        sourceApp: String?,
        contentHash: String?,
        isPinned: Bool = false
    ) {
        self.item = item
        self.date = date
        self.sourceApp = sourceApp
        self.contentHash = contentHash
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case item, date, sourceApp, contentHash, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try container.decode(HistoryItem.self, forKey: .item)
        date = try container.decode(Date.self, forKey: .date)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
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
    var fileHistory: [FileHistoryItem] = []
    private var maxHistoryItems: Int { PreferencesManager.shared.historyLimit }
    private let storageURL: URL
    private let fileHistoryURL: URL
    private var lastSyncHash: String?
    
    // Performance optimization: debounce and content tracking
    private var lastCheckTime: Date = Date()
    private var pendingContentCheck: Bool = false
    private let minCheckInterval: TimeInterval = 0.3 // Reduced from 0.5s to 0.3s with better logic
    private var recentContentHashes: Set<String> = []
    private let recentContentHashesMaxSize = 50

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
        self.storageURL = appSupport.appendingPathComponent("history_v2.json")
        self.fileHistoryURL = appSupport.appendingPathComponent("file_history.json")

        loadHistory()
        loadFileHistory()
        startPolling()
        
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
        if let data = try? Data(contentsOf: storageURL),
           let savedHistory = try? decoder.decode([HistoryEntry].self, from: data) {
            self.history = savedHistory
            history = orderedHistory()
        }
    }
    
    private func saveHistory() {
        if let data = try? encoder.encode(history) {
            try? data.write(to: storageURL)
        }
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

        var newItem: HistoryItem?

        if let fileURLs = readFileURLsFromPasteboard(), !fileURLs.isEmpty {
            newItem = .files(fileURLs)
        } else if let rtfData = pasteboard.data(forType: .rtf) {
            newItem = .rtf(rtfData)
        } else if let htmlData = pasteboard.data(forType: .html) {
            newItem = .html(htmlData)
        } else if let pdfData = pasteboard.data(forType: .pdf) {
            newItem = .pdf(pdfData)
        } else if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            newItem = .image(imageData)
        } else if let newString = pasteboard.string(forType: .string), !newString.isEmpty {
            newItem = .text(newString)
        }
        
        if let item = newItem {
            addToHistory(item, sourceApp: sourceApp)
        }
    }

    private func addToHistory(_ item: HistoryItem, sourceApp: String?) {
        let hash = contentHash(for: item)
        appLog("Adding to history: \(item.title), Hash: \(hash?.prefix(8) ?? "N/A")")

        // Broadcast to other devices if it's a new text item and not from sync
        if let nh = hash, nh != lastSyncHash {
            if case .text(let str) = item {
                SyncManager.shared.broadcastSync(content: str, hash: nh)
            }
        }

        var preservedPin = false
        history.removeAll { entry in
            let isDuplicate: Bool
            if let h = entry.contentHash, let nh = hash {
                isDuplicate = h == nh
            } else {
                switch (entry.item, item) {
                case (.text(let s1), .text(let s2)): isDuplicate = s1 == s2
                case (.files(let u1), .files(let u2)): isDuplicate = u1 == u2
                default: isDuplicate = false
                }
            }
            if isDuplicate {
                preservedPin = entry.isPinned
            }
            return isDuplicate
        }

        let entry = HistoryEntry(
            item: item,
            date: Date(),
            sourceApp: sourceApp,
            contentHash: hash,
            isPinned: preservedPin
        )
        insertEntry(entry)
        trimHistoryIfNeeded()

        // Update recent content hashes for performance
        if let hash = hash {
            recentContentHashes.insert(hash)
            if recentContentHashes.count > recentContentHashesMaxSize {
                // Remove oldest hash by rebuilding set from current history
                updateRecentContentHashes()
            }
        }

        saveHistory()
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

    func searchHistory(query: String) -> [HistoryEntry] {
        let ordered = orderedHistory()
        guard !query.isEmpty else { return Array(ordered.prefix(20)) }
        let lowercased = query.lowercased()
        let matched = ordered.filter { entry in
            if let source = entry.sourceApp, source.lowercased().contains(lowercased) {
                return true
            }
            switch entry.item {
            case .text(let str):
                return str.lowercased().contains(lowercased)
            case .files(let urls):
                return urls.contains { url in
                    url.lastPathComponent.lowercased().contains(lowercased)
                        || url.path.lowercased().contains(lowercased)
                        || FilePathDisplay.string(for: url).lowercased().contains(lowercased)
                }
            case .image:
                return "image".contains(lowercased)
            case .rtf:
                return "rich text".contains(lowercased)
            case .pdf:
                return "pdf".contains(lowercased)
            case .html(let data):
                return "html".contains(lowercased)
                    || (HistoryPreviewSupport.htmlString(from: data).map {
                        $0.lowercased().contains(lowercased)
                    } ?? false)
            }
        }
        return sortPinnedFirst(matched)
    }

    func orderedHistory() -> [HistoryEntry] {
        let pinned = history.filter(\.isPinned)
        let unpinned = history.filter { !$0.isPinned }
        return pinned + unpinned
    }

    func togglePin(for entry: HistoryEntry) {
        guard let index = indexOfEntry(matching: entry) else { return }
        var updated = history[index]
        updated.isPinned.toggle()
        history.remove(at: index)
        insertEntry(updated)
        saveHistory()
        notifyHistoryChanged()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
        notifyHistoryChanged()
    }

    func applyHistoryLimit() {
        let previousCount = history.count
        trimHistoryIfNeeded()
        guard history.count != previousCount else { return }
        updateRecentContentHashes()
        saveHistory()
        notifyHistoryChanged()
    }
    
    func moveHistoryEntryToFront(_ entry: HistoryEntry) {
        let hash = entry.contentHash ?? contentHash(for: entry.item)

        history.removeAll { existingEntry in
            isSameHistoryItem(existingEntry, as: entry.item, contentHash: hash)
        }

        let updatedEntry = HistoryEntry(
            item: entry.item,
            date: Date(),
            sourceApp: entry.sourceApp,
            contentHash: hash,
            isPinned: entry.isPinned
        )
        insertEntry(updatedEntry)
        trimHistoryIfNeeded()

        updateRecentContentHashes()
        saveHistory()
        notifyHistoryChanged()
    }

    private func insertEntry(_ entry: HistoryEntry) {
        if entry.isPinned {
            history.insert(entry, at: 0)
            return
        }
        let insertIndex = history.firstIndex(where: { !$0.isPinned }) ?? history.count
        history.insert(entry, at: insertIndex)
    }

    private func trimHistoryIfNeeded() {
        while history.count > maxHistoryItems {
            if let index = history.lastIndex(where: { !$0.isPinned }) {
                history.remove(at: index)
            } else {
                history.removeLast()
            }
        }
    }

    private func sortPinnedFirst(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        let pinned = entries.filter(\.isPinned)
        let unpinned = entries.filter { !$0.isPinned }
        return pinned + unpinned
    }

    private func indexOfEntry(matching entry: HistoryEntry) -> Int? {
        let hash = entry.contentHash ?? contentHash(for: entry.item)
        return history.firstIndex { existingEntry in
            isSameHistoryItem(existingEntry, as: entry.item, contentHash: hash)
        }
    }
    
    func writeToPasteboard(_ item: HistoryItem) {
        pasteboard.clearContents()
        switch item {
        case .text(let str):
            pasteboard.setString(str, forType: .string)
        case .image(let data):
            pasteboard.setData(data, forType: .tiff)
        case .rtf(let data):
            pasteboard.setData(data, forType: .rtf)
        case .pdf(let data):
            pasteboard.setData(data, forType: .pdf)
        case .html(let data):
            pasteboard.setData(data, forType: .html)
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
        guard simulatePaste, AccessibilityManager.ensureTrustedForPaste() else { return }
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
        case (.image(let d1), .image(let d2)),
             (.rtf(let d1), .rtf(let d2)),
             (.pdf(let d1), .pdf(let d2)),
             (.html(let d1), .html(let d2)):
            return d1 == d2
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
        case .image(let data):
            return sha256Hex(data)
        case .rtf(let data):
            return sha256Hex(data)
        case .pdf(let data):
            return sha256Hex(data)
        case .html(let data):
            return sha256Hex(data)
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

    func revealInFinder(for entry: HistoryEntry) {
        guard let urls = entry.item.fileURLs else { return }
        FilePathDisplay.revealInFinder(urls: urls)
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
