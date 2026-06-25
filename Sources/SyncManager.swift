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

struct FileChunk: Codable {
    let fileId: String
    let chunkIndex: Int
    let data: String // Base64 encrypted chunk data
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
    
    private var browser: NWBrowser? 
    private var listener: NWListener? 
    private var netService: NetService?
    private var discoveredEndpoints: [NWEndpoint: NWBrowser.Result] = [:] 
    private var activeConnections: [NWConnection] = [] 
    private let syncQueue = DispatchQueue(label: "com.clipy.sync")
    private var pendingFiles: [String: (header: FileHeader, senderName: String, localURL: URL)] = [:]
     
    private let serviceType = "_clipy-sync._tcp" 
    private var deviceId: String { PreferencesManager.shared.deviceName } 
     
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
    
    private func compressData(_ data: Data) -> Data? {
        let bufferSize = data.count + 64 // Add some overhead for compression metadata
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        let compressedSize = data.withUnsafeBytes { inputPtr in
            buffer.withUnsafeMutableBytes { outputPtr in
                compression_encode_buffer(
                    outputPtr.baseAddress!,
                    bufferSize,
                    inputPtr.baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        
        if compressedSize == 0 {
            return nil // Compression failed or not beneficial
        }
        
        return Data(buffer[0..<compressedSize])
    }
    
    private func decompressData(_ data: Data, originalSize: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: originalSize)
        
        let decompressedSize = data.withUnsafeBytes { inputPtr in
            buffer.withUnsafeMutableBytes { outputPtr in
                compression_decode_buffer(
                    outputPtr.baseAddress!,
                    originalSize,
                    inputPtr.baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        
        if decompressedSize != originalSize {
            return nil // Decompression failed
        }
        
        return Data(buffer)
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
        
        discoveredEndpoints.removeAll()
        appLog("SyncManager stopped.")
    }
    
    func restartService() {
        appLog("Restarting Sync services with new device name: \(deviceId)")
        stop()
        
        // Use syncQueue for restarting to ensure serial execution
        syncQueue.asyncAfter(deadline: .now() + 1.5) {
            self.start()
        }
    }
    
    // MARK: - Network Framework Discovery (NWBrowser)
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
            
            // Update our discovered endpoints
            self.discoveredEndpoints.removeAll()
            for result in results {
                if case let .service(name, type, domain, interface) = result.endpoint {
                    let interfaceName = interface?.name ?? "any"
                    
                    // Get addresses if possible from metadata or other sources
                    // NWBrowser.Result doesn't directly give IPs until we connect, 
                    // but we can see the interface.
                    appLog("Discovered service: \(name) (\(type).\(domain)) on interface \(interfaceName)")
                    
                    if name != self.deviceId {
                        self.discoveredEndpoints[result.endpoint] = result
                    } else {
                        appLog("Skipping local service: \(name)")
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.onDevicesChanged?(self.availableDeviceNames)
            }
            self.requestTransferListsForAvailableDevices()
        }
        
        browser.start(queue: syncQueue)
        appLog("Network Framework browser started for \(serviceType)")
    }
    
    var availableDeviceNames: [String] {
        return discoveredEndpoints.compactMap { (endpoint, _) -> String? in
            if case let .service(name, _, _, _) = endpoint {
                return name
            }
            return nil
        }.sorted()
    }
    
    // MARK: - Network Framework Listener (NWListener)
    private func startListening() {
        let currentDeviceId = deviceId
        let port = Int32(PreferencesManager.shared.syncPort)
        appLog("Starting listener on port \(port) as '\(currentDeviceId)'...")
        
        do {
            let parameters = NWParameters.tcp
            let nwPort = NWEndpoint.Port(rawValue: UInt16(port))!
            let listener = try NWListener(using: parameters, on: nwPort)
            
            // NetService must be published on a thread with a RunLoop (usually Main)
            DispatchQueue.main.async {
                // NetService type should NOT have a trailing dot here, 
                // it is usually like "_clipy-sync._tcp"
                let ns = NetService(domain: "local.", type: self.serviceType, name: currentDeviceId, port: port)
                ns.delegate = self
                ns.schedule(in: .main, forMode: .common)
                ns.publish()
                self.netService = ns
                appLog("NetService (Main Thread) publishing as: \(currentDeviceId) on port \(port) with type \(self.serviceType)")
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
                    appLog("NWListener state: \(state)")
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                appLog("New incoming connection from \(connection.endpoint)")
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
    
    private func receiveMessage(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            if let data = data, data.count == 4 {
                let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                appLog("Incoming message length: \(length)")
                
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak connection] data, _, _, error in
                    if let data = data {
                        self?.processReceivedData(data)
                    }
                    if let connection = connection {
                        self?.removeConnection(connection)
                        connection.cancel()
                    }
                }
            } else if let error = error {
                appLog("Receive length failed: \(error)", level: .error)
                self?.removeConnection(connection)
                connection.cancel()
            }
        }
    }
    
    private func processReceivedData(_ data: Data) {
        appLog("Processing received data (\(data.count) bytes)")
        guard let message = try? JSONDecoder().decode(SyncMessage.self, from: data) else {
            appLog("Failed to decode SyncMessage", level: .error)
            return
        }
        
        // Authorization check
        if !PreferencesManager.shared.authorizedDevices.contains(message.deviceId) {
            appLog("Rejecting sync from unauthorized device: \(message.deviceId)", level: .warning)
            return
        }
        
        if let decrypted = decrypt(message.content) {
            if message.type == "text/plain" {
                appLog("Received sync from \(message.deviceId): \(decrypted.prefix(20))...")
                ClipboardManager.shared.handleRemoteSync(content: decrypted, hash: message.hash)
            } else if message.type == "file/header" {
                handleFileHeader(decrypted, from: message.deviceId)
            } else if message.type == "file/chunk" {
                handleFileChunk(decrypted, from: message.deviceId)
            } else if message.type == "transfer/add" {
                TransferManager.shared.handleRemoteAdd(decrypted, from: message.deviceId)
            } else if message.type == "transfer/remove" {
                TransferManager.shared.handleRemoteRemove(decrypted)
            } else if message.type == "transfer/request" {
                TransferManager.shared.syncAllTo(message.deviceId)
            } else if message.type == "transfer/list" {
                TransferManager.shared.handleRemoteList(decrypted, from: message.deviceId)
            } else if message.type == "transfer/file/header" {
                handleTransferFileHeader(decrypted, from: message.deviceId)
            } else if message.type == "transfer/file/chunk" {
                handleTransferFileChunk(decrypted, from: message.deviceId)
            } else if message.type == "notification/post" {
                NotificationManager.shared.handleRemoteNotification(decrypted, from: message.deviceId)
            } else if message.type == "notification/dismiss" {
                NotificationManager.shared.handleRemoteDismiss(decrypted)
            } else if message.type == "notification/clear_all" {
                NotificationManager.shared.handleRemoteClearAll()
            } else if message.type == "notification/config" {
                handleNotificationConfig(decrypted)
            } else if message.type == "collector/event" {
                DeviceCollectorManager.shared.handleRemoteEvent(decrypted, from: message.deviceId)
            }
        }
    }

    private func handleNotificationConfig(_ decrypted: String) {
        guard let data = decrypted.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["allowedPackages"] as? [String] else { return }
        NotificationManager.shared.allowedPackages = Set(packages)
        NotificationManager.shared.savePreferences()
    }
    
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
        
        pendingFiles[header.fileId] = (header, sender, localURL)
    }
    
    private func handleFileChunk(_ json: String, from sender: String) {
        guard let data = json.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(FileChunk.self, from: data) else {
            appLog("Failed to decode FileChunk", level: .error)
            return
        }
        
        guard let (header, senderName, localURL) = pendingFiles[chunk.fileId] else {
            appLog("Received chunk for unknown fileId: \(chunk.fileId)", level: .error)
            return
        }
        
        guard var chunkData = Data(base64Encoded: chunk.data) else {
            appLog("Failed to decode base64 chunk data", level: .error)
            return
        }
        
        // Handle decompression if needed
        if chunk.isCompressed, let originalSize = chunk.originalSize {
            if let decompressedData = decompressData(chunkData, originalSize: originalSize) {
                chunkData = decompressedData
                appLog("Decompressed chunk \(chunk.chunkIndex) from \(Data(base64Encoded: chunk.data)!.count) to \(decompressedData.count) bytes")
            } else {
                appLog("Failed to decompress chunk \(chunk.chunkIndex)", level: .error)
                return
            }
        }
        
        do {
            let fileHandle = try FileHandle(forWritingTo: localURL)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: chunkData)
            
            if chunk.isLast {
                appLog("File transfer completed: \(header.fileName)")
                pendingFiles.removeValue(forKey: chunk.fileId)
                
                // Add to history
                DispatchQueue.main.async {
                    ClipboardManager.shared.addToFileHistory(
                        fileName: header.fileName,
                        filePath: localURL.path,
                        fileSize: header.fileSize,
                        senderName: senderName
                    )
                    
                    // Show notification
                    let notification = NSUserNotification()
                    notification.title = L10n.t(.fileReceived)
                    notification.informativeText = L10n.format(.receivedFileFrom, header.fileName, senderName)
                    notification.soundName = NSUserNotificationDefaultSoundName
                    NSUserNotificationCenter.default.deliver(notification)
                }
            }
        } catch {
            appLog("Failed to write chunk: \(error)", level: .error)
        }
    }
    
    // MARK: - Transfer Station Sync
    func broadcastTransferMessage(type: String, content: String, hash: String) {
        appLog("Broadcasting transfer message: \(type)")
        guard PreferencesManager.shared.isSyncEnabled else { return }

        guard let encryptedContent = encrypt(content) else { return }

        let message = SyncMessage(
            deviceId: deviceId,
            timestamp: Date().timeIntervalSince1970,
            type: type,
            content: encryptedContent,
            hash: hash
        )

        guard let jsonData = try? JSONEncoder().encode(message) else { return }

        let authorizedDevices = PreferencesManager.shared.authorizedDevices
        let targetResults = discoveredEndpoints.values.filter { result in
            if case let .service(name, _, _, _) = result.endpoint {
                return authorizedDevices.contains(name)
            }
            return false
        }

        for result in targetResults {
            if case let .service(name, _, _, _) = result.endpoint {
                appLog("Sending transfer message to: \(name)")
            }
            sendSync(jsonData, to: result.endpoint)
        }
    }

    func sendTransferMessage(type: String, content: String, hash: String, to targetName: String) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        guard let encryptedContent = encrypt(content) else { return }

        let message = SyncMessage(
            deviceId: deviceId,
            timestamp: Date().timeIntervalSince1970,
            type: type,
            content: encryptedContent,
            hash: hash
        )

        guard let jsonData = try? JSONEncoder().encode(message) else { return }

        guard let result = discoveredEndpoints.values.first(where: { result in
            if case let .service(name, _, _, _) = result.endpoint {
                return name == targetName
            }
            return false
        }) else {
            appLog("Transfer: could not find endpoint for device: \(targetName)", level: .error)
            return
        }

        sendSync(jsonData, to: result.endpoint)
    }

    func requestTransferList(from deviceName: String) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        guard PreferencesManager.shared.authorizedDevices.contains(deviceName) else { return }
        appLog("Transfer: requesting station snapshot from \(deviceName)")
        sendTransferMessage(type: "transfer/request", content: "{}", hash: "", to: deviceName)
    }

    func requestTransferListsForAvailableDevices() {
        let authorizedDevices = Set(PreferencesManager.shared.authorizedDevices)
        for deviceName in availableDeviceNames where authorizedDevices.contains(deviceName) {
            requestTransferList(from: deviceName)
        }
    }

    private var pendingTransferFiles: [String: (header: FileHeader, senderName: String, localURL: URL)] = [:]

    private func handleTransferFileHeader(_ json: String, from sender: String) {
        guard let data = json.data(using: .utf8),
              let header = try? JSONDecoder().decode(FileHeader.self, from: data) else {
            appLog("Transfer: failed to decode file header", level: .error)
            return
        }

        appLog("Transfer: received file header for \(header.fileName) from \(sender)")

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destDir = appSupport.appendingPathComponent("ClipyClone/TransferFiles")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let localURL = destDir.appendingPathComponent(header.fileName)
        try? FileManager.default.removeItem(at: localURL)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)

        pendingTransferFiles[header.fileId] = (header, sender, localURL)
    }

    private func handleTransferFileChunk(_ json: String, from sender: String) {
        guard let data = json.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(FileChunk.self, from: data) else {
            appLog("Transfer: failed to decode file chunk", level: .error)
            return
        }

        guard let (header, _, localURL) = pendingTransferFiles[chunk.fileId] else {
            appLog("Transfer: received chunk for unknown fileId: \(chunk.fileId)", level: .error)
            return
        }

        guard var chunkData = Data(base64Encoded: chunk.data) else {
            appLog("Transfer: failed to decode base64 chunk data", level: .error)
            return
        }

        if chunk.isCompressed, let originalSize = chunk.originalSize {
            if let decompressedData = decompressData(chunkData, originalSize: originalSize) {
                chunkData = decompressedData
            }
        }

        do {
            let fileHandle = try FileHandle(forWritingTo: localURL)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: chunkData)

            if chunk.isLast {
                appLog("Transfer: file transfer completed: \(header.fileName)")
                pendingTransferFiles.removeValue(forKey: chunk.fileId)

                DispatchQueue.main.async {
                    TransferManager.shared.addReceivedFileItem(
                        from: localURL,
                        fileName: header.fileName,
                        fileSize: header.fileSize,
                        sourceDevice: sender
                    )
                }
            }
        } catch {
            appLog("Transfer: failed to write chunk: \(error)", level: .error)
        }
    }

    // MARK: - Notification Sync
    func broadcastNotificationMessage(type: String, content: String, hash: String) {
        appLog("Broadcasting notification message: \(type)")
        guard PreferencesManager.shared.isSyncEnabled else { return }

        guard let encryptedContent = encrypt(content) else { return }

        let message = SyncMessage(
            deviceId: deviceId,
            timestamp: Date().timeIntervalSince1970,
            type: type,
            content: encryptedContent,
            hash: hash
        )

        guard let jsonData = try? JSONEncoder().encode(message) else { return }

        let authorizedDevices = PreferencesManager.shared.authorizedDevices
        let targetResults = discoveredEndpoints.values.filter { result in
            if case let .service(name, _, _, _) = result.endpoint {
                return authorizedDevices.contains(name)
            }
            return false
        }

        for result in targetResults {
            if case let .service(name, _, _, _) = result.endpoint {
                appLog("Sending notification message to: \(name)")
            }
            sendSync(jsonData, to: result.endpoint)
        }
    }

    // MARK: - Sending Sync
    func broadcastSync(content: String, hash: String) {
        appLog("Broadcasting sync message: \(hash.prefix(8))...")
        guard PreferencesManager.shared.isSyncEnabled else { return }
        
        guard let encryptedContent = encrypt(content) else { return }
        
        let message = SyncMessage(
            deviceId: deviceId,
            timestamp: Date().timeIntervalSince1970,
            type: "text/plain",
            content: encryptedContent,
            hash: hash
        )
        
        guard let jsonData = try? JSONEncoder().encode(message) else { return }
        
        let authorizedDevices = PreferencesManager.shared.authorizedDevices
        
        // Target endpoints that are authorized
        let targetResults = discoveredEndpoints.values.filter { result in
            if case let .service(name, _, _, _) = result.endpoint {
                return authorizedDevices.contains(name)
            }
            return false
        }
        
        for result in targetResults {
            if case let .service(name, _, _, _) = result.endpoint {
                appLog("Sending sync to authorized device: \(name)")
            }
            sendSync(jsonData, to: result.endpoint)
        }
    }
    
    func sendFile(at url: URL, toDevice targetName: String) {
        sendFile(at: url, toDevice: targetName, headerType: "file/header", chunkType: "file/chunk", addToFileHistory: true)
    }

    func broadcastTransferFile(at url: URL) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        let authorizedDevices = Set(PreferencesManager.shared.authorizedDevices)
        for deviceName in availableDeviceNames where authorizedDevices.contains(deviceName) {
            sendTransferFile(at: url, toDevice: deviceName)
        }
    }

    func sendTransferFile(at url: URL, toDevice targetName: String) {
        sendFile(at: url, toDevice: targetName, headerType: "transfer/file/header", chunkType: "transfer/file/chunk", addToFileHistory: false)
    }

    private func sendFile(
        at url: URL,
        toDevice targetName: String,
        headerType: String,
        chunkType: String,
        addToFileHistory: Bool
    ) {
        appLog("Preparing to send file \(url.lastPathComponent) to \(targetName)")

        guard let result = discoveredEndpoints.values.first(where: { result in
            if case let .service(name, _, _, _) = result.endpoint {
                return name == targetName
            }
            return false
        }) else {
            appLog("Could not find endpoint for device: \(targetName)", level: .error)
            return
        }

        let endpoint = result.endpoint
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
            deviceId: deviceId,
            timestamp: Date().timeIntervalSince1970,
            type: headerType,
            content: encryptedHeader,
            hash: ""
        )

        guard let headerJson = try? JSONEncoder().encode(headerMessage) else { return }
        sendSync(headerJson, to: endpoint)

        syncQueue.async {
            do {
                let fileHandle = try FileHandle(forReadingFrom: url)
                defer { try? fileHandle.close() }

                // Keep packets comfortably below Android's 1MB safety limit after JSON/Base64/encryption overhead.
                let chunkSize = 128 * 1024

                let shouldCompress = self.shouldCompressFile(at: url)
                appLog("File compression enabled: \(shouldCompress), chunk size: \(chunkSize)")

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
                        deviceId: self.deviceId,
                        timestamp: Date().timeIntervalSince1970,
                        type: chunkType,
                        content: encryptedChunk,
                        hash: ""
                    )

                    guard let chunkJson = try? JSONEncoder().encode(chunkMessage) else { break }

                    let delay = min(0.1, Double(processedData.count) / 1000000.0)
                    if delay > 0 {
                        Thread.sleep(forTimeInterval: delay)
                    }
                    self.sendSync(chunkJson, to: endpoint)

                    chunkIndex += 1
                    appLog("Sent chunk \(chunkIndex) (\(bytesRead)/\(fileSize) bytes, compressed: \(isCompressed))")
                }
                appLog("File transfer completed for \(fileName)")

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
    
    private func sendSync(_ data: Data, to endpoint: NWEndpoint) {
        appLog("Starting TCP connection to \(endpoint)...")
        
        let parameters = NWParameters.tcp
        // Bypass system proxies to avoid 127.0.0.1 redirection from tools like Clash/Surge
        parameters.preferNoProxies = true
        
        // Force IPv6 preference if possible by allowing all but explicitly logging results
        // Network framework naturally prefers IPv6 (Happy Eyeballs) if not intercepted
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let remoteAddress: String
                let localAddress: String
                let interfaceName: String
                
                if let remote = connection.currentPath?.remoteEndpoint {
                    remoteAddress = "\(remote)"
                } else {
                    remoteAddress = "unknown"
                }
                
                if let local = connection.currentPath?.localEndpoint {
                    localAddress = "\(local)"
                } else {
                    localAddress = "unknown"
                }
                
                interfaceName = connection.currentPath?.availableInterfaces.first?.name ?? "unknown"

                appLog("TCP connection ready to \(endpoint). Remote: \(remoteAddress), Local: \(localAddress), Interface: \(interfaceName)")
                // Send length prefix (4 bytes, big-endian) followed by data
                var messageData = Data()
                var length = UInt32(data.count).bigEndian
                let lengthBytes = withUnsafeBytes(of: &length) { Data($0) }
                messageData.append(lengthBytes)
                messageData.append(data)
                
                appLog("Sending total \(messageData.count) bytes (length prefix: \(data.count))")
                
                connection.send(content: messageData, completion: .contentProcessed({ error in
                    if let error = error {
                        appLog("Send failed to \(endpoint): \(error)", level: .error)
                    } else {
                        appLog("Sync data sent successfully to \(endpoint)")
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
            case .preparing:
                appLog("Connection preparing for \(endpoint)...")
            case .setup:
                appLog("Connection setup for \(endpoint)...")
            case .cancelled:
                appLog("Connection cancelled for \(endpoint)")
            @unknown default:
                break
            }
        }
        
        connection.start(queue: syncQueue)
    }
}
