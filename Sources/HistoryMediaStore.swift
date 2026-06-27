import AppKit
import CryptoKit
import Foundation

enum HistoryMediaKind: String {
    case image
    case rtf
    case pdf
    case html

    var fileExtension: String { rawValue == "image" ? "png" : rawValue }
}

struct StoredTextReference {
    let path: String
    let preview: String
}

final class HistoryMediaStore {
    static let shared = HistoryMediaStore()

    static let textPreviewLength = 200

    let imagesDirectory: URL
    let richTextDirectory: URL
    let documentsDirectory: URL
    let textDirectory: URL

    private let fileManager = FileManager.default
    private var legacyMigrationNeeded = false

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone", isDirectory: true)
        imagesDirectory = appSupport.appendingPathComponent("images", isDirectory: true)
        richTextDirectory = appSupport.appendingPathComponent("rich_text", isDirectory: true)
        documentsDirectory = appSupport.appendingPathComponent("documents", isDirectory: true)
        textDirectory = appSupport.appendingPathComponent("text", isDirectory: true)
        for directory in [imagesDirectory, richTextDirectory, documentsDirectory, textDirectory] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func store(data: Data, kind: HistoryMediaKind, preferredHash: String? = nil) -> String {
        let hash = preferredHash ?? sha256Hex(data)
        let url = fileURL(for: kind, hash: hash)
        if !fileManager.fileExists(atPath: url.path) {
            switch kind {
            case .image:
                writeImageData(data, to: url)
            default:
                writeProtectedData(data, to: url)
            }
        }
        return url.path
    }

    func storeLegacy(data: Data, kind: HistoryMediaKind) -> String {
        legacyMigrationNeeded = true
        return store(data: data, kind: kind)
    }

    func consumeLegacyMigrationNeeded() -> Bool {
        defer { legacyMigrationNeeded = false }
        return legacyMigrationNeeded
    }

    func storeText(_ text: String, preferredHash: String? = nil) -> StoredTextReference {
        let data = Data(text.utf8)
        let hash = preferredHash ?? sha256Hex(data)
        let url = textDirectory.appendingPathComponent("\(hash).txt")
        if !fileManager.fileExists(atPath: url.path) {
            writeProtectedData(data, to: url)
        }
        let preview = String(text.prefix(Self.textPreviewLength))
        return StoredTextReference(path: url.path, preview: preview)
    }

    func text(at path: String) -> String? {
        guard let data = data(at: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(at path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return decryptIfNeeded(raw)
    }

    func reencryptReferencedFiles(keeping referencedPaths: Set<String>, wasEncrypted: Bool) {
        for path in referencedPaths where isManagedPath(path) {
            let url = URL(fileURLWithPath: path)
            guard let raw = try? Data(contentsOf: url) else { continue }
            let plain: Data
            if wasEncrypted {
                guard let key = HistoryKeychain.loadKey(),
                      let decrypted = try? SecureStorageCrypto.decrypt(raw, using: key) else { continue }
                plain = decrypted
            } else {
                plain = raw
            }
            writeProtectedData(plain, to: url)
        }
    }

    private func writeProtectedData(_ data: Data, to url: URL) {
        if PreferencesManager.shared.isHistoryEncryptionEnabled,
           let key = HistoryKeychain.loadOrCreateKey(),
           let encrypted = try? SecureStorageCrypto.encrypt(data, using: key) {
            try? encrypted.write(to: url, options: .atomic)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func decryptIfNeeded(_ data: Data) -> Data? {
        guard PreferencesManager.shared.isHistoryEncryptionEnabled,
              let key = HistoryKeychain.loadKey() else {
            return data
        }
        return try? SecureStorageCrypto.decrypt(data, using: key)
    }

    func fileURL(for item: HistoryItem) -> URL? {
        guard let path = item.storedMediaPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    func contentHash(forPath path: String) -> String? {
        guard let data = data(at: path) else { return nil }
        return sha256Hex(data)
    }

    func isManagedPath(_ path: String) -> Bool {
        let prefixes = [
            imagesDirectory.path + "/",
            richTextDirectory.path + "/",
            documentsDirectory.path + "/",
            textDirectory.path + "/",
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }

    func collectReferencedPaths(from history: [HistoryEntry]) -> Set<String> {
        var paths = Set<String>()
        for entry in history {
            if let path = entry.item.storedMediaPath {
                paths.insert(path)
            }
            if let textPath = entry.textPath {
                paths.insert(textPath)
            }
        }
        return paths
    }

    func removeUnreferencedFiles(keeping referencedPaths: Set<String>) {
        for directory in [imagesDirectory, richTextDirectory, documentsDirectory, textDirectory] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.hasDirectoryPath == false {
                if !referencedPaths.contains(file.path) {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }

    func removeAllManagedFiles() {
        for directory in [imagesDirectory, richTextDirectory, documentsDirectory, textDirectory] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func fileURL(for kind: HistoryMediaKind, hash: String) -> URL {
        let directory: URL
        switch kind {
        case .image:
            directory = imagesDirectory
        case .rtf, .html:
            directory = richTextDirectory
        case .pdf:
            directory = documentsDirectory
        }
        return directory.appendingPathComponent("\(hash).\(kind.fileExtension)")
    }

    private func writeImageData(_ data: Data, to url: URL) {
        if let image = NSImage(data: data),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            writeProtectedData(pngData, to: url)
            return
        }
        writeProtectedData(data, to: url)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension HistoryItem {
    var storedMediaPath: String? {
        switch self {
        case .image(let path), .rtf(let path), .pdf(let path), .html(let path):
            return path
        default:
            return nil
        }
    }

    var storedMediaURL: URL? {
        guard let path = storedMediaPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    func loadStoredData() -> Data? {
        guard let path = storedMediaPath else { return nil }
        return HistoryMediaStore.shared.data(at: path)
    }
}
