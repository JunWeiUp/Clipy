import Foundation
import Network
import CryptoKit
import Compression

struct SyncMessage: Codable {
    let deviceId: String
    let timestamp: TimeInterval
    let type: String
    let content: String // Base64 encrypted data
    let hash: String
}

struct FileHeader: Codable {
    let fileId: String
    let fileName: String
    let fileSize: Int64
}

struct DiscoveredPeer {
    let peerId: String
    let displayName: String
    let endpoint: NWEndpoint
    let browseResult: NWBrowser.Result
}

struct FileChunk: Codable {
    let fileId: String
    let chunkIndex: Int
    let data: String // Base64 chunk data (encryption happens on the outer SyncMessage)
    let isLast: Bool
    let isCompressed: Bool
    let originalSize: Int?
    
    init(fileId: String, chunkIndex: Int, data: String, isLast: Bool, isCompressed: Bool = false, originalSize: Int? = nil) {
        self.fileId = fileId
        self.chunkIndex = chunkIndex
        self.data = data
        self.isLast = isLast
        self.isCompressed = isCompressed
        self.originalSize = originalSize
    }
    
    enum CodingKeys: String, CodingKey {
        case fileId, chunkIndex, data, isLast, isCompressed, originalSize
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileId = try container.decode(String.self, forKey: .fileId)
        self.chunkIndex = try container.decode(Int.self, forKey: .chunkIndex)
        self.data = try container.decode(String.self, forKey: .data)
        self.isLast = try container.decode(Bool.self, forKey: .isLast)
        self.isCompressed = try container.decodeIfPresent(Bool.self, forKey: .isCompressed) ?? false
        self.originalSize = try container.decodeIfPresent(Int.self, forKey: .originalSize)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileId, forKey: .fileId)
        try container.encode(chunkIndex, forKey: .chunkIndex)
        try container.encode(data, forKey: .data)
        try container.encode(isLast, forKey: .isLast)
        try container.encode(isCompressed, forKey: .isCompressed)
        try container.encodeIfPresent(originalSize, forKey: .originalSize)
    }
}

class SyncManager: NSObject, NetServiceDelegate {
    static let shared = SyncManager()
    
    var onDevicesChanged: (([String]) -> Void)?
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    
    private var browser: NWBrowser? 
    private var listener: NWListener? 
    private var netService: NetService?
    private var discoveredPeers: [String: DiscoveredPeer] = [:]
    private let peersLock = NSLock()
    private var activeConnections: [NWConnection] = [] 
    private let syncQueue = DispatchQueue(label: "com.clipy.sync")
    // File transfers run on their own queue so blocking sends never stall message receive.
    private let fileTransferQueue = DispatchQueue(label: "com.clipy.sync.filetransfer")

    /// Reject any frame larger than this to avoid attacker-controlled allocations.
    private static let maxMessageLength = 2 * 1024 * 1024
    /// Incomplete inbound transfers are dropped after this much inactivity.
    private static let pendingFileTimeout: TimeInterval = 60

    private struct PendingFileTransfer {
        let header: FileHeader
        let senderName: String
        let localURL: URL
        var expectedChunkIndex: Int = 0
        var lastActivity = Date()
    }

    private var pendingFiles: [String: PendingFileTransfer] = [:]
    private var pendingFileCleanupTimer: DispatchSourceTimer?
     
    private let serviceType = "_clipy-sync._tcp" 
    private var displayName: String { PreferencesManager.shared.deviceName }
    private var peerId: String { PreferencesManager.shared.syncPeerId }
     
    private let hardcodedSecret = "ClipySyncSecret2026"

    private var encryptionKey: SymmetricKey {
        let data = hardcodedSecret.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        return SymmetricKey(data: hash)
    }
    
    private func shouldCompressFile(at url: URL) -> Bool {
        // Never compress binary/executable files or already compressed formats
        let fileExtension = url.pathExtension.lowercased()
        let neverCompressExtensions = [
            // Archives and compressed files
            "zip", "gz", "7z", "rar", "tar", "bz2", "xz", "tgz", "tbz2",
            // Images
            "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "svg", "ico",
            // Video
            "mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "m4v",
            // Audio
            "mp3", "wav", "flac", "aac", "ogg", "m4a", "wma",
            // Documents
            "pdf", "docx", "xlsx", "pptx", "epub", "mobi",
            // Executables and binaries
            "exe", "dll", "so", "dylib", "app", "apk", "ipa", "bin", "dmg",
            // Other compressed or binary formats
            "psd", "ai", "indd", "raw", "cr2", "nef", "arw"
        ]
        
        if neverCompressExtensions.contains(fileExtension) {
            return false
        }
        
        // Only compress text-based files
        let textExtensions = [
            "txt", "log", "csv", "json", "xml", "html", "htm", "css", "js", "ts",
            "py", "java", "cpp", "c", "h", "hpp", "cs", "rb", "php", "go", "rs",
            "swift", "kt", "kts", "md", "markdown", "yaml", "yml", "toml", "ini",
            "properties", "cfg", "conf", "sh", "bash", "bat", "cmd", "sql", "pl",
            "pm", "lua", "r", "scala", "clj", "cljs", "edn", "coffee", "scss", "sass"
        ]
        
        if !textExtensions.contains(fileExtension) {
            // For unknown file types, check file content to determine if it's text
            return isLikelyTextFile(at: url)
        }
        
        // Check file size - don't compress very small files
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attrs[.size] as? Int64 ?? 0
            if fileSize < 1024 { // Less than 1KB
                return false
            }
            if fileSize > 10 * 1024 * 1024 { // More than 10MB, skip compression to avoid memory issues
                return false
            }
        } catch {
            appLog("Failed to get file size for compression check: \(error)", level: .warning)
            return false
        }
        
        return true
    }
    
    private func isLikelyTextFile(at url: URL) -> Bool {
        // Read first 1KB of file to check if it's likely text
        do {
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { try? fileHandle.close() }
            
            let data = fileHandle.readData(ofLength: 1024)
            if data.isEmpty {
                return false
            }
            
            // Check for null bytes - binary files often contain them
            if data.contains(0) {
                return false
            }
            
            // Try to decode as UTF-8
            if let string = String(data: data, encoding: .utf8) {
                // Check if most characters are printable
                var printableCount = 0
                for char in string.utf8 {
                    // Printable ASCII: 32-126 (space to ~)
                    // Also allow common whitespace: tab(9), newline(10), carriage return(13)
                    if (32...126).contains(char) || [9, 10, 13].contains(char) {
                        printableCount += 1
                    }
                }
                let ratio = Double(printableCount) / Double(string.utf8.count)
                return ratio > 0.9 // At least 90% printable characters
            }
            
            return false
        } catch {
            appLog("Failed to check file content: \(error)", level: .warning)
            return false
        }
    }
    
    // MARK: - Compression (gzip container, interoperable with Android's dart:io gzip codec)
    //
    // Apple's Compression framework only produces RAW deflate (COMPRESSION_ZLIB
    // without headers), so we wrap/unwrap the gzip container manually to stay
    // byte-compatible with Dart's `gzip.encode`/`gzip.decode`.

    private static let crc32Table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var crc = UInt32(index)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
            }
            return crc
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = Self.crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private func rawDeflate(_ data: Data) -> Data? {
        let bufferSize = data.count + 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let compressedSize = data.withUnsafeBytes { inputPtr -> Int in
            guard let base = inputPtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                &buffer, bufferSize,
                base.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard compressedSize > 0 else { return nil }
        return Data(buffer[0..<compressedSize])
    }

    private func rawInflate(_ data: Data, expectedSize: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: expectedSize)
        let decompressedSize = data.withUnsafeBytes { inputPtr -> Int in
            guard let base = inputPtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                &buffer, expectedSize,
                base.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard decompressedSize == expectedSize else { return nil }
        return Data(buffer)
    }

    private func compressData(_ data: Data) -> Data? {
        guard !data.isEmpty, let deflated = rawDeflate(data) else { return nil }

        var output = Data(capacity: deflated.count + 18)
        // Minimal gzip header: magic, deflate method, no flags, no mtime, unknown OS.
        output.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(deflated)

        var crc = Self.crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &isize) { output.append(contentsOf: $0) }
        return output
    }

    private func decompressData(_ data: Data, originalSize: Int) -> Data? {
        guard originalSize > 0, data.count > 18 else { return nil }
        let bytes = [UInt8](data)
        // gzip magic + deflate method.
        guard bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else { return nil }

        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard bytes.count > offset + 2 else { return nil }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 { // FNAME (NUL-terminated)
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT (NUL-terminated)
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }
        guard offset < bytes.count - 8 else { return nil }

        let deflateBody = data.subdata(in: offset..<(data.count - 8))
        guard let inflated = rawInflate(deflateBody, expectedSize: originalSize) else { return nil }

        // Verify the trailer CRC so corrupt chunks can never be written to disk.
        let trailerStart = data.count - 8
        let expectedCRC = UInt32(bytes[trailerStart])
            | (UInt32(bytes[trailerStart + 1]) << 8)
            | (UInt32(bytes[trailerStart + 2]) << 16)
            | (UInt32(bytes[trailerStart + 3]) << 24)
        guard Self.crc32(inflated) == expectedCRC else { return nil }
        return inflated
    }

    private func encrypt(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            let iv = AES.GCM.Nonce() // 12 bytes nonce for GCM
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey, nonce: iv)
            // Combine IV + Ciphertext + Tag
            let combined = iv + sealedBox.ciphertext + sealedBox.tag
            return combined.base64EncodedString()
        } catch {
            appLog("Encryption error: \(error)", level: .error)
            return nil
        }
    }

    private func decrypt(_ base64String: String) -> String? {
        guard let data = Data(base64Encoded: base64String) else { return nil }
        do {
            // Data format: IV(12) + Ciphertext + Tag(16)
            guard data.count > 28 else { 
                return decryptLegacy(base64String)
            }
            let nonce = try AES.GCM.Nonce(data: data.prefix(12))
            let tag = data.suffix(16)
            let ciphertext = data[12..<(data.count - 16)]
            
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
            return String(data: decryptedData, encoding: .utf8)
        } catch {
            return decryptLegacy(base64String)
        }
    }

    private func decryptLegacy(_ base64String: String) -> String? {
        guard let data = Data(base64Encoded: base64String) else { return nil }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
            return String(data: decryptedData, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private override init() {
        super.init()
    }
    
    func start() {
        appLog("SyncManager starting...")
        guard PreferencesManager.shared.isSyncEnabled else { return }
        
        startListening()
        startBrowsing()
    }
    
    func stop() {
        appLog("SyncManager stopping and cleaning up resources...")
        
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        
        // Stop and nil NetService advertisement on main thread
        DispatchQueue.main.async {
            self.netService?.delegate = nil
            self.netService?.stop()
            self.netService = nil
        }
        
        // Explicitly clear service before cancelling listener to help mDNS unregistration
        listener?.service = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        
        // Cancel all active connections
        for connection in activeConnections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        activeConnections.removeAll()
        
        peersLock.lock()
        discoveredPeers.removeAll()
        peersLock.unlock()

        syncQueue.async {
            self.abortAllPendingFiles()
        }
        appLog("SyncManager stopped.")
    }
    
    func restartService() {
        appLog("Restarting Sync services with new device name: \(displayName)")
        stop()
        
        // Use syncQueue for restarting to ensure serial execution
        syncQueue.asyncAfter(deadline: .now() + 1.5) {
            self.start()
        }
    }
    
    // MARK: - Network Framework Discovery (NWBrowser)
    private func peerId(from result: NWBrowser.Result, serviceName: String) -> String {
        if case let .bonjour(txtRecord) = result.metadata,
           let id = txtRecord["peerId"],
           !id.isEmpty {
            return id
        }
        return serviceName
    }

    private func startBrowsing() {
        appLog("Starting mDNS browsing for \(serviceType)...")
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: parameters)
        self.browser = browser
        
        browser.stateUpdateHandler = { state in
            appLog("Browser state: \(state)")
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            
            appLog("mDNS browse results changed: \(results.count) devices found")
            
            var updatedPeers: [String: DiscoveredPeer] = [:]
            for result in results {
                if case let .service(name, type, domain, interface) = result.endpoint {
                    let interfaceName = interface?.name ?? "any"
                    let remotePeerId = self.peerId(from: result, serviceName: name)
                    appLog("Discovered service: \(name) peerId=\(remotePeerId) (\(type).\(domain)) on interface \(interfaceName)")
                    
                    if name == self.displayName || remotePeerId == self.peerId {
                        continue
                    }
                    updatedPeers[remotePeerId] = DiscoveredPeer(
                        peerId: remotePeerId,
                        displayName: name,
                        endpoint: result.endpoint,
                        browseResult: result
                    )
                }
            }

            self.peersLock.lock()
            self.discoveredPeers = updatedPeers
            self.peersLock.unlock()

            PreferencesManager.shared.migrateAuthorizedPeerIds(from: self.availablePeers)
            
            DispatchQueue.main.async {
                let names = self.availableDeviceNames
                let peers = self.availablePeers
                self.onDevicesChanged?(names)
                self.onPeersChanged?(peers)
                NotificationCenter.default.post(
                    name: .syncAvailableDevicesDidChange,
                    object: self,
                    userInfo: ["devices": names, "peers": peers]
                )
            }
        }
        
        browser.start(queue: syncQueue)
        appLog("Network Framework browser started for \(serviceType)")
    }
    
    var availablePeers: [DiscoveredPeer] {
        peersLock.lock()
        defer { peersLock.unlock() }
        return discoveredPeers.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var availableDeviceNames: [String] {
        return availablePeers.map(\.displayName)
    }
    
    // MARK: - Network Framework Listener (NWListener)
    private func startListening() {
        let currentDisplayName = displayName
        let currentPeerId = peerId
        let port = Int32(PreferencesManager.shared.syncPort)
        appLog("Starting listener on port \(port) as '\(currentDisplayName)' (peerId=\(currentPeerId))...")
        
        do {
            let parameters = NWParameters.tcp
            let nwPort = NWEndpoint.Port(rawValue: UInt16(port))!
            let listener = try NWListener(using: parameters, on: nwPort)
            
            DispatchQueue.main.async {
                let ns = NetService(domain: "local.", type: self.serviceType, name: currentDisplayName, port: port)
                let txtData = NetService.data(fromTXTRecord: ["peerId": Data(currentPeerId.utf8)])
                ns.setTXTRecord(txtData)
                ns.delegate = self
                ns.schedule(in: .main, forMode: .common)
                ns.publish()
                self.netService = ns
                appLog("NetService publishing as: \(currentDisplayName) peerId=\(currentPeerId) on port \(port)")
            }
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    appLog("NWListener ready on port \(port)")
                case .failed(let error):
                    appLog("NWListener failed: \(error)", level: .error)
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        appLog("Port in use, will retry in 2 seconds...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.restartService()
                        }
                    }
                case .cancelled:
                    appLog("NWListener cancelled")
                default:
                    break
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }
            
            self.listener = listener
            listener.start(queue: syncQueue)
            appLog("Network Framework listener started on port \(port)")
        } catch {
            appLog("Failed to start NWListener: \(error)", level: .error)
        }
    }
    
    // MARK: - NetServiceDelegate
    func netServiceDidPublish(_ sender: NetService) {
        appLog("NetService successfully published: \(sender.name)")
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        appLog("NetService failed to publish: \(errorDict)", level: .error)
    }
    
    func netServiceDidStop(_ sender: NetService) {
        appLog("NetService stopped: \(sender.name)")
    }
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .ready:
                self.receiveMessage(from: connection)
            case .failed(let error):
                appLog("Incoming connection failed: \(error)", level: .error)
                self.removeConnection(connection)
            case .cancelled:
                self.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: syncQueue)
    }
    
    private func removeConnection(_ connection: NWConnection) {
        if let index = activeConnections.firstIndex(where: { $0 === connection }) {
            activeConnections.remove(at: index)
        }
    }
    
    /// Reads length-prefixed frames in a loop so one connection can carry many messages
    /// (used by file transfers to keep chunks ordered on a single connection).
    private func receiveMessage(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }
            guard let data = data, data.count == 4 else {
                if error != nil || isComplete {
                    self.removeConnection(connection)
                    connection.cancel()
                }
                return
            }

            let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard length > 0, length <= Self.maxMessageLength else {
                appLog("Rejecting frame with invalid length \(length)", level: .error)
                self.removeConnection(connection)
                connection.cancel()
                return
            }

            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak connection] data, _, isComplete, error in
                guard let self = self, let connection = connection else { return }
                if let data = data {
                    self.processReceivedData(data)
                }
                if error != nil || isComplete {
                    self.removeConnection(connection)
                    connection.cancel()
                } else {
                    self.receiveMessage(from: connection)
                }
            }
        }
    }
    
    private func processReceivedData(_ data: Data) {
        guard let message = try? JSONDecoder().decode(SyncMessage.self, from: data) else {
            appLog("Failed to decode SyncMessage", level: .error)
            return
        }
        
        guard PreferencesManager.shared.authorizedPeerIds.contains(message.deviceId) else {
            appLog("Rejecting sync from unauthorized peer: \(message.deviceId)", level: .warning)
            return
        }
        
        guard let decrypted = decrypt(message.content) else {
            appLog("Failed to decrypt message from \(message.deviceId), type: \(message.type)", level: .error)
            return
        }
        
        switch message.type {
        case "text/plain":
            // ClipboardManager touches NSPasteboard and UI state: main thread only.
            DispatchQueue.main.async {
                ClipboardManager.shared.handleRemoteSync(content: decrypted, hash: message.hash)
            }
        case "file/header":
            handleFileHeader(decrypted, from: message.deviceId)
        case "file/chunk":
            handleFileChunk(decrypted, from: message.deviceId)
        case "notification/post":
            DispatchQueue.main.async {
                NotificationManager.shared.handleRemoteNotification(decrypted, from: message.deviceId)
            }
        case "notification/dismiss":
            DispatchQueue.main.async {
                NotificationManager.shared.handleRemoteDismiss(decrypted)
            }
        case "notification/clear_all":
            DispatchQueue.main.async {
                NotificationManager.shared.handleRemoteClearAll()
            }
        case "notification/config":
            DispatchQueue.main.async {
                self.handleNotificationConfig(decrypted)
            }
        case "collector/event":
            DispatchQueue.main.async {
                DeviceCollectorManager.shared.handleRemoteEvent(decrypted, from: message.deviceId)
            }
        default:
            break
        }
    }

    private func handleNotificationConfig(_ decrypted: String) {
        guard let data = decrypted.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["allowedPackages"] as? [String] else { return }
        NotificationManager.shared.allowedPackages = Set(packages)
        NotificationManager.shared.savePreferences()
    }
    
    // MARK: - Inbound File Transfers (state confined to syncQueue)

    private func handleFileHeader(_ json: String, from sender: String) {
        guard let data = json.data(using: .utf8),
              let header = try? JSONDecoder().decode(FileHeader.self, from: data) else {
            appLog("Failed to decode FileHeader", level: .error)
            return
        }
        
        appLog("Received FileHeader for \(header.fileName) (\(header.fileSize) bytes) from \(sender)")
        
        let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Clipy")
        try? FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
        
        let localURL = downloadsFolder.appendingPathComponent(header.fileName)
        
        // Ensure the file is empty or doesn't exist
        try? FileManager.default.removeItem(at: localURL)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        
        pendingFiles[header.fileId] = PendingFileTransfer(header: header, senderName: sender, localURL: localURL)
        schedulePendingFileCleanupIfNeeded()
    }
    
    private func handleFileChunk(_ json: String, from sender: String) {
        guard let data = json.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(FileChunk.self, from: data) else {
            appLog("Failed to decode FileChunk", level: .error)
            return
        }
        
        guard var pending = pendingFiles[chunk.fileId] else {
            appLog("Received chunk for unknown fileId: \(chunk.fileId)", level: .error)
            return
        }

        guard chunk.chunkIndex == pending.expectedChunkIndex else {
            appLog(
                "Out-of-order chunk for \(pending.header.fileName): got \(chunk.chunkIndex), expected \(pending.expectedChunkIndex). Aborting transfer.",
                level: .error
            )
            abortPendingFile(chunk.fileId)
            return
        }
        
        guard var chunkData = Data(base64Encoded: chunk.data) else {
            appLog("Failed to decode base64 chunk data", level: .error)
            abortPendingFile(chunk.fileId)
            return
        }
        
        // Handle decompression if needed
        if chunk.isCompressed, let originalSize = chunk.originalSize {
            guard let decompressedData = decompressData(chunkData, originalSize: originalSize) else {
                appLog("Failed to decompress chunk \(chunk.chunkIndex) of \(pending.header.fileName). Aborting transfer.", level: .error)
                abortPendingFile(chunk.fileId)
                return
            }
            chunkData = decompressedData
        }
        
        do {
            let fileHandle = try FileHandle(forWritingTo: pending.localURL)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: chunkData)
        } catch {
            appLog("Failed to write chunk: \(error)", level: .error)
            abortPendingFile(chunk.fileId)
            return
        }

        pending.expectedChunkIndex += 1
        pending.lastActivity = Date()
        pendingFiles[chunk.fileId] = pending

        if chunk.isLast {
            appLog("File transfer completed: \(pending.header.fileName)")
            pendingFiles.removeValue(forKey: chunk.fileId)
            let header = pending.header
            let senderName = pending.senderName
            let localURL = pending.localURL

            DispatchQueue.main.async {
                ClipboardManager.shared.addToFileHistory(
                    fileName: header.fileName,
                    filePath: localURL.path,
                    fileSize: header.fileSize,
                    senderName: senderName
                )
                
                let notification = NSUserNotification()
                notification.title = L10n.t(.fileReceived)
                notification.informativeText = L10n.format(.receivedFileFrom, header.fileName, senderName)
                notification.soundName = NSUserNotificationDefaultSoundName
                NSUserNotificationCenter.default.deliver(notification)
            }
        }
    }

    private func schedulePendingFileCleanupIfNeeded() {
        guard pendingFileCleanupTimer == nil, !pendingFiles.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.cleanupStalePendingFiles()
        }
        timer.resume()
        pendingFileCleanupTimer = timer
    }

    private func cleanupStalePendingFiles() {
        let cutoff = Date().addingTimeInterval(-Self.pendingFileTimeout)
        for (fileId, pending) in pendingFiles where pending.lastActivity < cutoff {
            appLog("File transfer timed out: \(pending.header.fileName)", level: .warning)
            abortPendingFile(fileId)
        }
        if pendingFiles.isEmpty {
            pendingFileCleanupTimer?.cancel()
            pendingFileCleanupTimer = nil
        }
    }

    private func abortPendingFile(_ fileId: String) {
        guard let pending = pendingFiles.removeValue(forKey: fileId) else { return }
        try? FileManager.default.removeItem(at: pending.localURL)
        if pendingFiles.isEmpty {
            pendingFileCleanupTimer?.cancel()
            pendingFileCleanupTimer = nil
        }
    }

    private func abortAllPendingFiles() {
        for fileId in Array(pendingFiles.keys) {
            abortPendingFile(fileId)
        }
    }
    
    // MARK: - Notification Sync
    func broadcastNotificationMessage(type: String, content: String, hash: String) {
        appLog("Broadcasting notification message: \(type)")
        guard PreferencesManager.shared.isSyncEnabled else { return }

        guard let encryptedContent = encrypt(content) else { return }

        let message = SyncMessage(
            deviceId: peerId,
            timestamp: Date().timeIntervalSince1970,
            type: type,
            content: encryptedContent,
            hash: hash
        )

        guard let jsonData = try? JSONEncoder().encode(message) else { return }

        let authorizedPeerIds = PreferencesManager.shared.authorizedPeerIds
        let targets = availablePeers.filter { authorizedPeerIds.contains($0.peerId) }

        for peer in targets {
            sendSync(jsonData, to: peer.endpoint)
        }
    }

    // MARK: - Sending Sync
    func broadcastSync(content: String, hash: String) {
        guard PreferencesManager.shared.isSyncEnabled else { return }

        guard let jsonData = makeTextSyncPayload(content: content, hash: hash) else { return }

        let authorizedPeerIds = PreferencesManager.shared.authorizedPeerIds
        let targets = availablePeers.filter { authorizedPeerIds.contains($0.peerId) }

        if targets.isEmpty {
            let discovered = availablePeers.map { "\($0.displayName):\($0.peerId)" }.joined(separator: ", ")
            let authorized = authorizedPeerIds.joined(separator: ", ")
            appLog(
                "Sync not sent: authorizedPeerIds=[\(authorized)], discovered=[\(discovered)]. Enable a device in Settings → LAN Sync.",
                level: .warning
            )
            return
        }

        for peer in targets {
            appLog("Sending sync to \(peer.displayName) (peerId=\(peer.peerId))")
            sendSync(jsonData, to: peer.endpoint)
        }
    }

    func sendText(_ content: String, hash: String, toDevice targetName: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard PreferencesManager.shared.isSyncEnabled else { return }

        guard let peer = availablePeers.first(where: { $0.displayName == targetName }) else {
            appLog("Could not find endpoint for device: \(targetName)", level: .error)
            return
        }

        guard let jsonData = makeTextSyncPayload(content: content, hash: hash) else { return }

        appLog("Sending text to \(peer.displayName) (peerId=\(peer.peerId))")
        sendSync(jsonData, to: peer.endpoint)
    }

    private func makeTextSyncPayload(content: String, hash: String) -> Data? {
        guard let encryptedContent = encrypt(content) else { return nil }

        let message = SyncMessage(
            deviceId: peerId,
            timestamp: Date().timeIntervalSince1970,
            type: "text/plain",
            content: encryptedContent,
            hash: hash
        )

        return try? JSONEncoder().encode(message)
    }
    
    func sendFile(at url: URL, toDevice targetName: String) {
        sendFile(at: url, toDevice: targetName, headerType: "file/header", chunkType: "file/chunk", addToFileHistory: true)
    }

    private func sendFile(
        at url: URL,
        toDevice targetName: String,
        headerType: String,
        chunkType: String,
        addToFileHistory: Bool
    ) {
        appLog("Preparing to send file \(url.lastPathComponent) to \(targetName)")

        guard let peer = availablePeers.first(where: { $0.displayName == targetName }) else {
            appLog("Could not find endpoint for device: \(targetName)", level: .error)
            return
        }

        let endpoint = peer.endpoint
        let fileId = UUID().uuidString
        let fileName = url.lastPathComponent
        let fileSize: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = attrs[.size] as? Int64 ?? 0
        } catch {
            appLog("Failed to get file size: \(error)", level: .error)
            return
        }

        let header = FileHeader(fileId: fileId, fileName: fileName, fileSize: fileSize)
        guard let headerData = try? JSONEncoder().encode(header),
              let encryptedHeader = encrypt(String(data: headerData, encoding: .utf8) ?? "") else { return }

        let headerMessage = SyncMessage(
            deviceId: peerId,
            timestamp: Date().timeIntervalSince1970,
            type: headerType,
            content: encryptedHeader,
            hash: ""
        )

        guard let headerJson = try? JSONEncoder().encode(headerMessage) else { return }

        // Send header + all chunks over ONE connection so ordering is guaranteed,
        // and run everything on the dedicated transfer queue so syncQueue stays responsive.
        fileTransferQueue.async {
            guard let connection = self.openBlockingConnection(to: endpoint) else {
                appLog("Failed to open connection for file transfer to \(targetName)", level: .error)
                return
            }
            defer { connection.cancel() }

            guard self.sendFrameBlocking(headerJson, over: connection) else {
                appLog("Failed to send file header to \(targetName)", level: .error)
                return
            }

            do {
                let fileHandle = try FileHandle(forReadingFrom: url)
                defer { try? fileHandle.close() }

                // Keep packets comfortably below the 2MB frame limit after JSON/Base64/encryption overhead.
                let chunkSize = 128 * 1024

                let shouldCompress = self.shouldCompressFile(at: url)

                var chunkIndex = 0
                var bytesRead: Int64 = 0

                while bytesRead < fileSize {
                    let rawData = fileHandle.readData(ofLength: chunkSize)
                    if rawData.isEmpty { break }

                    bytesRead += Int64(rawData.count)
                    let isLast = bytesRead >= fileSize

                    var processedData = rawData
                    let originalSize = rawData.count
                    var isCompressed = false

                    if shouldCompress, let compressedData = self.compressData(rawData) {
                        let compressionRatio = Double(compressedData.count) / Double(rawData.count)
                        if compressionRatio < 0.9 && compressedData.count < rawData.count {
                            processedData = compressedData
                            isCompressed = true
                        }
                    }

                    let chunk = FileChunk(
                        fileId: fileId,
                        chunkIndex: chunkIndex,
                        data: processedData.base64EncodedString(),
                        isLast: isLast,
                        isCompressed: isCompressed,
                        originalSize: isCompressed ? originalSize : nil
                    )

                    guard let chunkData = try? JSONEncoder().encode(chunk),
                          let encryptedChunk = self.encrypt(String(data: chunkData, encoding: .utf8) ?? "") else { break }

                    let chunkMessage = SyncMessage(
                        deviceId: self.peerId,
                        timestamp: Date().timeIntervalSince1970,
                        type: chunkType,
                        content: encryptedChunk,
                        hash: ""
                    )

                    guard let chunkJson = try? JSONEncoder().encode(chunkMessage) else { break }

                    guard self.sendFrameBlocking(chunkJson, over: connection) else {
                        appLog("Failed to send chunk \(chunkIndex) of \(fileName)", level: .error)
                        return
                    }

                    chunkIndex += 1
                }
                appLog("File transfer completed for \(fileName) (\(chunkIndex) chunks)")

                if addToFileHistory {
                    DispatchQueue.main.async {
                        ClipboardManager.shared.addToFileHistory(
                            fileName: fileName,
                            filePath: url.path,
                            fileSize: fileSize,
                            senderName: "Me (Sent to \(targetName))"
                        )
                    }
                }
            } catch {
                appLog("Failed to read file: \(error)", level: .error)
            }
        }
    }

    /// Opens a connection and blocks (on fileTransferQueue only) until ready or timeout.
    private func openBlockingConnection(to endpoint: NWEndpoint) -> NWConnection? {
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        let connection = NWConnection(to: endpoint, using: parameters)

        let ready = DispatchSemaphore(value: 0)
        var didConnect = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                didConnect = true
                ready.signal()
            case .failed(let error):
                appLog("File transfer connection failed: \(error)", level: .error)
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: syncQueue)

        guard ready.wait(timeout: .now() + 10) == .success, didConnect else {
            connection.cancel()
            return nil
        }
        connection.stateUpdateHandler = nil
        return connection
    }

    /// Sends one length-prefixed frame, blocking until the send completes (fileTransferQueue only).
    private func sendFrameBlocking(_ data: Data, over connection: NWConnection) -> Bool {
        var frame = Data(capacity: data.count + 4)
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(data)

        let done = DispatchSemaphore(value: 0)
        var succeeded = false
        connection.send(content: frame, completion: .contentProcessed { error in
            succeeded = (error == nil)
            if let error = error {
                appLog("Frame send failed: \(error)", level: .error)
            }
            done.signal()
        })
        return done.wait(timeout: .now() + 30) == .success && succeeded
    }
    
    private func sendSync(_ data: Data, to endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        // Bypass system proxies to avoid 127.0.0.1 redirection from tools like Clash/Surge
        parameters.preferNoProxies = true
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Send length prefix (4 bytes, big-endian) followed by data
                var messageData = Data()
                var length = UInt32(data.count).bigEndian
                let lengthBytes = withUnsafeBytes(of: &length) { Data($0) }
                messageData.append(lengthBytes)
                messageData.append(data)
                
                connection.send(content: messageData, completion: .contentProcessed({ error in
                    if let error = error {
                        appLog("Send failed to \(endpoint): \(error)", level: .error)
                    }
                    // Give it a tiny bit of time before closing to ensure flush
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        connection.cancel()
                    }
                }))
            case .waiting(let error):
                appLog("Connection waiting for \(endpoint): \(error)", level: .warning)
            case .failed(let error):
                appLog("Connection failed to \(endpoint): \(error)", level: .error)
            default:
                break
            }
        }
        
        connection.start(queue: syncQueue)
    }
}

extension Notification.Name {
    static let syncAvailableDevicesDidChange = Notification.Name("SyncAvailableDevicesDidChange")
}
