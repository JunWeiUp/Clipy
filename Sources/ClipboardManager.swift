import AppKit
import Foundation
import CoreGraphics

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
}

class ClipboardManager {
    static let shared = ClipboardManager()
    
    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private(set) var history: [HistoryEntry] = []
    private var maxHistoryItems: Int { PreferencesManager.shared.historyLimit }
    private let storageURL: URL
    
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    
    var onHistoryChanged: (([HistoryEntry]) -> Void)?

    private init() {
        self.changeCount = pasteboard.changeCount
        
        // Setup storage
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("ClipyClone")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.storageURL = appSupport.appendingPathComponent("history_v2.json")
        
        loadHistory()
        startPolling()
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
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    private func checkPasteboard() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceApp = frontmostApp?.localizedName
        let bundleIdentifier = frontmostApp?.bundleIdentifier
        
        // Clipy feature: Exclude sensitive apps (e.g., Password managers)
        if let bundleID = bundleIdentifier, PreferencesManager.shared.excludedApps.contains(bundleID) {
            return
        }
        
        if let newString = pasteboard.string(forType: .string), !newString.isEmpty {
            addToHistory(.text(newString), sourceApp: sourceApp)
        } else if let rtfData = pasteboard.data(forType: .rtf) {
            addToHistory(.rtf(rtfData), sourceApp: sourceApp)
        } else if let pdfData = pasteboard.data(forType: .pdf) {
            addToHistory(.pdf(pdfData), sourceApp: sourceApp)
        } else if let fileURLString = pasteboard.string(forType: .fileURL), let url = URL(string: fileURLString) {
            addToHistory(.fileURL(url), sourceApp: sourceApp)
        } else if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            addToHistory(.image(imageData), sourceApp: sourceApp)
        }
    }

    private func addToHistory(_ item: HistoryItem, sourceApp: String?) {
        // Deduplication
        history.removeAll { entry in
            switch (entry.item, item) {
            case (.text(let s1), .text(let s2)): return s1 == s2
            case (.fileURL(let u1), .fileURL(let u2)): return u1 == u2
            default: return false
            }
        }
        
        let entry = HistoryEntry(item: item, date: Date(), sourceApp: sourceApp)
        history.insert(entry, at: 0)
        
        if history.count > maxHistoryItems {
            history.removeLast()
        }
        
        saveHistory()
        onHistoryChanged?(history)
        
        // Broadcast change
        SyncManager.shared.broadcast(.historyItem(entry))
    }
    
    func receiveSyncedItem(_ entry: HistoryEntry) {
        // Deduplication
        history.removeAll { existing in
            switch (existing.item, entry.item) {
            case (.text(let s1), .text(let s2)): return s1 == s2
            case (.fileURL(let u1), .fileURL(let u2)): return u1 == u2
            default: return false
            }
        }
        
        history.insert(entry, at: 0)
        if history.count > maxHistoryItems {
            history.removeLast()
        }
        
        saveHistory()
        onHistoryChanged?(history)
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
}
