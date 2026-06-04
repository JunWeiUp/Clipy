import Foundation
import CryptoKit
import AppKit

struct TransferItem: Codable, Identifiable {
    let id: UUID
    var title: String
    let content: TransferContent
    let createdAt: Date
    var isPermanent: Bool
    let sourceDevice: String
    let contentHash: String

    init(id: UUID = UUID(), title: String, content: TransferContent, createdAt: Date = Date(), isPermanent: Bool = false, sourceDevice: String, contentHash: String) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.isPermanent = isPermanent
        self.sourceDevice = sourceDevice
        self.contentHash = contentHash
    }
}

enum TransferContent: Codable {
    case text(String)
    case rtf(Data)
    case image(Data)
    case file(filePath: String, fileName: String, fileSize: Int64)
    case folder(folderPath: String, folderName: String, fileCount: Int)

    enum CodingKeys: String, CodingKey {
        case text, rtf, image, file, folder
        case filePath, fileName, fileSize
        case folderPath, folderName, fileCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .text) {
            self = .text(value)
        } else if let value = try? container.decode(Data.self, forKey: .rtf) {
            self = .rtf(value)
        } else if let value = try? container.decode(Data.self, forKey: .image) {
            self = .image(value)
        } else if container.contains(.filePath) {
            let path = try container.decode(String.self, forKey: .filePath)
            let name = try container.decode(String.self, forKey: .fileName)
            let size = try container.decode(Int64.self, forKey: .fileSize)
            self = .file(filePath: path, fileName: name, fileSize: size)
        } else if container.contains(.folderPath) {
            let path = try container.decode(String.self, forKey: .folderPath)
            let name = try container.decode(String.self, forKey: .folderName)
            let count = try container.decode(Int.self, forKey: .fileCount)
            self = .folder(folderPath: path, folderName: name, fileCount: count)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "Invalid TransferContent")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .rtf(let value):
            try container.encode(value, forKey: .rtf)
        case .image(let value):
            try container.encode(value, forKey: .image)
        case .file(let path, let name, let size):
            try container.encode(path, forKey: .filePath)
            try container.encode(name, forKey: .fileName)
            try container.encode(size, forKey: .fileSize)
        case .folder(let path, let name, let count):
            try container.encode(path, forKey: .folderPath)
            try container.encode(name, forKey: .folderName)
            try container.encode(count, forKey: .fileCount)
        }
    }

    var typeLabel: String {
        switch self {
        case .text: return "Text"
        case .rtf: return "RTF"
        case .image: return "Image"
        case .file: return "File"
        case .folder: return "Folder"
        }
    }

    var icon: NSImage? {
        switch self {
        case .text:
            return NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        case .rtf:
            return NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        case .image:
            return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        case .file:
            return NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        case .folder:
            return NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
    }

    var displayTitle: String {
        switch self {
        case .text(let str):
            let preview = str.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            return preview.count > 60 ? String(preview.prefix(60)) + "..." : preview
        case .rtf:
            return "[Rich Text]"
        case .image:
            return "[Image]"
        case .file(_, let name, _):
            return name
        case .folder(_, let name, let count):
            return "\(name) (\(count) files)"
        }
    }
}

struct TransferPayload: Codable {
    let id: String
    let title: String
    let content: TransferContent
    let createdAt: TimeInterval
    let isPermanent: Bool
    let sourceDevice: String
    let contentHash: String
}

struct TransferListPayload: Codable {
    let items: [TransferPayload]
}

class TransferManager {
    static let shared = TransferManager()

    var onItemsChanged: (([TransferItem]) -> Void)?

    private(set) var items: [TransferItem] = [] {
        didSet {
            onItemsChanged?(items)
        }
    }

    private let storageURL: URL
    private let fileManager = FileManager.default
    private var tempCleanupTimer: Timer?
    private let tempItemLifetime: TimeInterval = 24 * 60 * 60 // 24 hours

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = appSupport.appendingPathComponent("ClipyClone")
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        storageURL = appDir.appendingPathComponent("transfer_items.json")

        load()
        startTempCleanupTimer()
    }

    // MARK: - Public API

    func addItem(_ content: TransferContent, title: String? = nil, isPermanent: Bool = false, broadcast: Bool = true) {
        let hash = computeHash(for: content)
        let deviceName = PreferencesManager.shared.deviceName

        if let existingIndex = items.firstIndex(where: { $0.contentHash == hash && $0.sourceDevice == deviceName }) {
            let existing = items[existingIndex]
            let updated = TransferItem(
                id: existing.id,
                title: title ?? existing.title,
                content: content,
                createdAt: Date(),
                isPermanent: isPermanent,
                sourceDevice: deviceName,
                contentHash: hash
            )
            items.remove(at: existingIndex)
            items.insert(updated, at: 0)
        } else {
            let item = TransferItem(
                title: title ?? content.displayTitle,
                content: content,
                isPermanent: isPermanent,
                sourceDevice: deviceName,
                contentHash: hash
            )
            items.insert(item, at: 0)
        }

        save()

        if broadcast {
            broadcastAdd(items[0])
        }

        appLog("Transfer: added item '\(items[0].title)' (permanent: \(isPermanent))")
    }

    func addReceivedFileItem(from url: URL, fileName: String, fileSize: Int64, sourceDevice: String) {
        let content = TransferContent.file(filePath: url.path, fileName: fileName, fileSize: fileSize)
        let hash = computeHash(for: content)
        let item = TransferItem(
            title: fileName,
            content: content,
            isPermanent: false,
            sourceDevice: sourceDevice,
            contentHash: hash
        )

        if let existingIndex = items.firstIndex(where: { $0.contentHash == hash && $0.sourceDevice == sourceDevice }) {
            items.remove(at: existingIndex)
        }
        items.insert(item, at: 0)
        save()
        appLog("Transfer: received file item '\(fileName)' from \(sourceDevice)")
    }

    func removeItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        items.remove(at: index)
        save()
        broadcastRemove(id: id)

        if case .file(let path, _, _) = item.content {
            try? fileManager.removeItem(atPath: path)
        } else if case .folder(let path, _, _) = item.content {
            try? fileManager.removeItem(atPath: path)
        }

        appLog("Transfer: removed item '\(item.title)'")
    }

    func togglePermanent(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPermanent.toggle()
        save()
        appLog("Transfer: toggled permanent for '\(items[index].title)' -> \(items[index].isPermanent)")
    }

    func clearAll() {
        for item in items {
            if case .file(let path, _, _) = item.content {
                try? fileManager.removeItem(atPath: path)
            } else if case .folder(let path, _, _) = item.content {
                try? fileManager.removeItem(atPath: path)
            }
        }
        items.removeAll()
        save()
        broadcastList()
        appLog("Transfer: cleared all items")
    }

    // MARK: - Remote Sync Handling

    func handleRemoteAdd(_ json: String, from device: String) {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TransferPayload.self, from: data) else {
            appLog("Transfer: failed to decode remote add payload", level: .error)
            return
        }

        upsertRemotePayload(payload, from: device)
        save()
        appLog("Transfer: received remote item '\(payload.title)' from \(device)")
    }

    func handleRemoteList(_ json: String, from device: String) {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TransferListPayload.self, from: data) else {
            appLog("Transfer: failed to decode remote list payload", level: .error)
            return
        }

        let remoteIds = Set(payload.items.map(\.id))
        items.removeAll { item in
            item.sourceDevice == device && !remoteIds.contains(item.id.uuidString)
        }
        for itemPayload in payload.items {
            upsertRemotePayload(itemPayload, from: device)
        }
        sortItems()
        save()
        appLog("Transfer: synced \(payload.items.count) transfer items from \(device)")
    }

    func handleRemoteRemove(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let idString = dict["id"],
              let id = UUID(uuidString: idString) else {
            appLog("Transfer: failed to decode remote remove payload", level: .error)
            return
        }

        if let index = items.firstIndex(where: { $0.id == id }) {
            let item = items[index]
            items.remove(at: index)
            save()
            appLog("Transfer: remote removed item '\(item.title)'")
        }
    }

    func syncAllTo(_ deviceName: String) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        let payload = TransferListPayload(items: localItems.map(makePayload))
        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        SyncManager.shared.sendTransferMessage(type: "transfer/list", content: jsonString, hash: "", to: deviceName)
        for item in localItems {
            if case .file(let path, _, _) = item.content {
                SyncManager.shared.sendTransferFile(at: URL(fileURLWithPath: path), toDevice: deviceName)
            }
        }
    }

    private func broadcastList() {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        let payload = TransferListPayload(items: localItems.map(makePayload))
        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        SyncManager.shared.broadcastTransferMessage(type: "transfer/list", content: jsonString, hash: "")
    }

    // MARK: - Broadcasting

    private func broadcastAdd(_ item: TransferItem, targetDevice: String? = nil) {
        guard PreferencesManager.shared.isSyncEnabled else { return }

        let payload = makePayload(item)

        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        if let target = targetDevice {
            SyncManager.shared.sendTransferMessage(type: "transfer/add", content: jsonString, hash: item.contentHash, to: target)
        } else {
            SyncManager.shared.broadcastTransferMessage(type: "transfer/add", content: jsonString, hash: item.contentHash)
        }
    }

    private func broadcastRemove(id: UUID) {
        guard PreferencesManager.shared.isSyncEnabled else { return }

        let dict = ["id": id.uuidString]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        SyncManager.shared.broadcastTransferMessage(type: "transfer/remove", content: jsonString, hash: "")
    }

    private func upsertRemotePayload(_ payload: TransferPayload, from device: String) {
        let existingIndex = items.firstIndex(where: {
            $0.id.uuidString == payload.id || ($0.contentHash == payload.contentHash && $0.sourceDevice == device)
        })
        var content = payload.content
        if let existingIndex,
           case .file = payload.content,
           case .file(let localPath, _, _) = items[existingIndex].content,
           fileManager.fileExists(atPath: localPath) {
            content = items[existingIndex].content
        }

        let item = TransferItem(
            id: UUID(uuidString: payload.id) ?? UUID(),
            title: payload.title,
            content: content,
            createdAt: Date(timeIntervalSince1970: payload.createdAt),
            isPermanent: payload.isPermanent,
            sourceDevice: device,
            contentHash: payload.contentHash
        )

        if let index = existingIndex {
            items[index] = item
        } else {
            items.append(item)
        }
        sortItems()
    }

    private func makePayload(_ item: TransferItem) -> TransferPayload {
        TransferPayload(
            id: item.id.uuidString,
            title: item.title,
            content: item.content,
            createdAt: item.createdAt.timeIntervalSince1970,
            isPermanent: item.isPermanent,
            sourceDevice: item.sourceDevice,
            contentHash: item.contentHash
        )
    }

    private func sortItems() {
        items.sort { $0.createdAt > $1.createdAt }
    }

    private var localItems: [TransferItem] {
        items.filter { $0.sourceDevice == PreferencesManager.shared.deviceName }
    }

    // MARK: - File Transfer

    func addFileItem(from url: URL, isPermanent: Bool = false) {
        let fileName = url.lastPathComponent
        let fileSize: Int64
        do {
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            fileSize = attrs[.size] as? Int64 ?? 0
        } catch {
            appLog("Transfer: failed to get file size: \(error)", level: .error)
            return
        }

        let destDir = transferFilesDirectory()
        let destURL = destDir.appendingPathComponent(fileName)
        if destURL.path != url.path {
            do {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: url, to: destURL)
            } catch {
                appLog("Transfer: failed to copy file: \(error)", level: .error)
                return
            }
        }

        addItem(.file(filePath: destURL.path, fileName: fileName, fileSize: fileSize), title: fileName, isPermanent: isPermanent)
        if PreferencesManager.shared.isSyncEnabled {
            SyncManager.shared.broadcastTransferFile(at: destURL)
        }
    }

    func addFolderItem(from url: URL, isPermanent: Bool = false) {
        let folderName = url.lastPathComponent
        var fileCount = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case _ as URL in enumerator { fileCount += 1 }
        }

        let destDir = transferFilesDirectory()
        let destURL = destDir.appendingPathComponent(folderName)
        if destURL.path != url.path {
            do {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: url, to: destURL)
            } catch {
                appLog("Transfer: failed to copy folder: \(error)", level: .error)
                return
            }
        }

        addItem(.folder(folderPath: destURL.path, folderName: folderName, fileCount: fileCount), title: folderName, isPermanent: isPermanent)
    }

    func addImageItem(_ image: NSImage, isPermanent: Bool = false) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            appLog("Transfer: failed to convert image to PNG", level: .error)
            return
        }
        let title = "Image \(DateFormatter.transferShort.string(from: Date()))"
        addItem(.image(pngData), title: title, isPermanent: isPermanent)
    }

    func addRTFItem(_ data: Data, isPermanent: Bool = false) {
        let title = "RTF \(DateFormatter.transferShort.string(from: Date()))"
        addItem(.rtf(data), title: title, isPermanent: isPermanent)
    }

    // MARK: - Cleanup

    private func startTempCleanupTimer() {
        tempCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.cleanupTempItems()
        }
        cleanupTempItems()
    }

    private func cleanupTempItems() {
        let cutoff = Date(timeIntervalSinceNow: -tempItemLifetime)
        let expired = items.filter { !$0.isPermanent && $0.createdAt < cutoff }
        for item in expired {
            if case .file(let path, _, _) = item.content {
                try? fileManager.removeItem(atPath: path)
            } else if case .folder(let path, _, _) = item.content {
                try? fileManager.removeItem(atPath: path)
            }
        }
        let before = items.count
        items.removeAll { !$0.isPermanent && $0.createdAt < cutoff }
        if items.count != before {
            save()
            appLog("Transfer: cleaned up \(before - items.count) expired temp items")
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: storageURL)
        } catch {
            appLog("Transfer: failed to save items: \(error)", level: .error)
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            items = try JSONDecoder().decode([TransferItem].self, from: data)
            appLog("Transfer: loaded \(items.count) items")
        } catch {
            appLog("Transfer: failed to load items: \(error)", level: .error)
        }
    }

    // MARK: - Helpers

    private func transferFilesDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ClipyClone/TransferFiles")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func computeHash(for content: TransferContent) -> String {
        let data: Data
        switch content {
        case .text(let str):
            let normalized = str.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            data = Data(normalized.utf8)
        case .rtf(let d):
            data = d
        case .image(let d):
            data = d
        case .file(_, let name, let size):
            data = Data("\(name):\(size)".utf8)
        case .folder(_, let name, let count):
            data = Data("\(name):\(count)".utf8)
        }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

private let transferShortFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

extension DateFormatter {
    static let transferShort: DateFormatter = transferShortFormatter
}
