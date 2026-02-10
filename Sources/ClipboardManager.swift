import AppKit
import Foundation
import CoreGraphics
import CryptoKit

enum HistoryItem: Codable {
    case text(String)
    case image(Data)
    case rtf(Data)
    case pdf(Data)
    case fileURL(URL)
    
    enum CodingKeys: String, CodingKey {
        case text, image, rtf, pdf, fileURL
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
        } else if let value = try? container.decode(URL.self, forKey: .fileURL) {
            self = .fileURL(value)
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
        case .fileURL(let value): try container.encode(value, forKey: .fileURL)
        }
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
        case .fileURL(let url):
            return "[File] \(url.lastPathComponent)"
        }
    }
}

struct HistoryEntry: Codable {
    let item: HistoryItem
    let date: Date
    let sourceApp: String?
    let contentHash: String?
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
        
        if let newString = pasteboard.string(forType: .string), !newString.isEmpty {
            newItem = .text(newString)
        } else if let rtfData = pasteboard.data(forType: .rtf) {
            newItem = .rtf(rtfData)
        } else if let pdfData = pasteboard.data(forType: .pdf) {
            newItem = .pdf(pdfData)
        } else if let fileURLString = pasteboard.string(forType: .fileURL), let url = URL(string: fileURLString) {
            newItem = .fileURL(url)
        } else if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            newItem = .image(imageData)
        }
        
        if let item = newItem {
            let hash = contentHash(for: item)
            
            // Early duplicate detection using recent hashes
            if let hash = hash, recentContentHashes.contains(hash) {
                appLog("Skipping duplicate content (hash: \(hash.prefix(8)))")
                return
            }
            
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

        history.removeAll { entry in
            if let h = entry.contentHash, let nh = hash {
                return h == nh
            }
            switch (entry.item, item) {
            case (.text(let s1), .text(let s2)): return s1 == s2
            case (.fileURL(let u1), .fileURL(let u2)): return u1 == u2
            default: return false
            }
        }

        let entry = HistoryEntry(item: item, date: Date(), sourceApp: sourceApp, contentHash: hash)
        history.insert(entry, at: 0)

        if history.count > maxHistoryItems {
            history.removeLast()
        }

        // Update recent content hashes for performance
        if let hash = hash {
            recentContentHashes.insert(hash)
            if recentContentHashes.count > recentContentHashesMaxSize {
                // Remove oldest hash by rebuilding set from current history
                updateRecentContentHashes()
            }
        }

        saveHistory()
        onHistoryChanged?(history)
    }
    
    func handleRemoteSync(content: String, hash: String) {
        appLog("Handling remote sync: \(hash.prefix(8))")
        // Prevent loop if we already have this content
        guard hash != lastSyncHash else { 
            appLog("Sync loop detected or duplicate hash, ignoring")
            return 
        }
        
        // Also check if it's already in history
        if history.contains(where: { $0.contentHash == hash }) {
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

    func clearHistory() {
        history.removeAll()
        saveHistory()
        onHistoryChanged?(history)
    }
    
    func copyToPasteboard(_ item: HistoryItem) {
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
        case .fileURL(let url):
            pasteboard.setString(url.absoluteString, forType: .fileURL)
        }
        changeCount = pasteboard.changeCount
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
        case .fileURL(let url):
            let s = url.absoluteString
            guard let data = s.data(using: .utf8) else { return nil }
            return sha256Hex(data)
        }
    }
    
    private func sha256Hex(_ data: Data) -> String {
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
