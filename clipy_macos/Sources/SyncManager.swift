import Foundation
import AppKit
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
}

struct DeviceEntry {
    let displayName: String   // Disambiguated name (may include short peerId suffix)
    let peerId: String
    let originalName: String  // Original display name from mDNS
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

class SyncManager: NSObject {
    static let shared = SyncManager()

    var onDevicesChanged: (([String]) -> Void)?
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?

    private var discoveredPeers: [String: DiscoveredPeer] = [:]
    private let peersLock = NSLock()
    private var activeConnections: [NWConnection] = [] 
    private let syncQueue = DispatchQueue(label: "com.clipy.sync")
    // File transfers run on their own queue so blocking sends never stall message receive.
    private let fileTransferQueue = DispatchQueue(label: "com.clipy.sync.filetransfer")
    // Cross-band subnet scan uses group.wait() to bound concurrency. It must NOT
    // run on syncQueue: performHandshake dispatches its NWConnection + completion
    // onto handshakeQueue, so blocking scanQueue would deadlock the completions.
    private let scanQueue = DispatchQueue(label: "com.clipy.scan")
    /// Dedicated queue for outbound handshake NWConnection state callbacks.
    /// Keeping these off syncQueue prevents 64 concurrent scan handshakes from
    /// starving the POSIX IPv4 listener's DispatchSourceRead (which services
    /// inbound connections on syncQueue). Without this, a busy scan can delay
    /// recv() past the peer's read timeout, causing the peer to RST before its
    /// hello is ever processed.
    private let handshakeQueue = DispatchQueue(label: "com.clipy.sync.handshake")
    /// Pending scan work item for debouncing triggerCrossBandDiscovery so
    /// rapid UI toggles (e.g. checkbox spam) coalesce into a single sweep.
    private var pendingScanWorkItem: DispatchWorkItem?

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
    private var isRefreshingDiscovery = false

    /// mDNS does not reliably report abrupt departures (kill, power loss, Wi-Fi
    /// drop), so discovered peers are probed over TCP on this interval and
    /// evicted after peerLivenessMaxMisses consecutive failures.
    ///
    /// 45s × 3 ≈ 2 min 15s grace window. The previous 30s × 2 ≈ 1 min was too
    /// aggressive: a peer's TCP listener can be briefly unresponsive during
    /// AppNap / display sleep / Wi-Fi roam, after which it would be evicted and
    /// only reappear on the next mDNS browse cycle. Keep aligned with Android.
    private static let peerLivenessInterval: TimeInterval = 45
    private static let peerLivenessMaxMisses = 3
    private var peerLivenessTimer: DispatchSourceTimer?
    private var peerMissCounts: [String: Int] = [:]

    /// Watches the system network path so a Wi-Fi switch / interface change /
    /// reconnect triggers an immediate `refreshDiscovery()` instead of relying
    /// on the wake notification or a manual refresh. Tracks the previous status
    /// and available interfaces so we only react to meaningful transitions.
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.clipy.sync.pathmonitor")
    private var lastPathStatus: NWPath.Status = .requiresConnection
    private var lastInterfaceTypes: Set<NWInterface.InterfaceType> = []

    /// Per-connection reassembly buffer. Network.framework does not guarantee a
    /// single `receive` returns a whole frame; we accumulate until the declared
    /// length is available, mirroring the Android side's buffer loop.
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var isProbingPeers = false

    // MARK: POSIX IPv4 listener state
    // NWListener on macOS creates an IPv6 socket that remote IPv4 LAN peers
    // cannot reach; this parallel IPv4 listener accepts those connections.
    // All access is confined to syncQueue.
    private var posixListenFD: Int32 = -1
    private var posixListenSource: DispatchSourceRead?
    private var posixClientSources: [Int32: DispatchSourceRead] = [:]
    private var posixClientBuffers: [Int32: Data] = [:]
    private var posixClientHosts: [Int32: String] = [:]

    /// Outbound retry buffer: when an authorized peer is momentarily unreachable
    /// (mDNS flutter, peer asleep, transient connect failure) the frame is kept
    /// here and flushed once the peer reappears. Bounded + TTL'd to avoid leaks.
    /// Keep aligned with the Android side's _pendingQueue.
    private struct PendingSync {
        let data: Data
        let type: String
        let targetPeerId: String
        let enqueueAt: Date
    }
    private var pendingQueue: [PendingSync] = []
    private static let pendingQueueMax = 50
    private static let pendingQueueTTL: TimeInterval = 30
    private static let sendConnectTimeout: TimeInterval = 5

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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard PreferencesManager.shared.isSyncEnabled else { return }
            appLog("System wake detected; refreshing LAN discovery")
            self?.refreshDiscovery()
        }
    }

    /// Starts monitoring the system network path so a Wi-Fi switch / interface
    /// change / reconnect triggers an immediate `refreshDiscovery()`. Without
    /// this, mDNS advertisement and browsing can stay stale after a network
    /// change until the next manual refresh or system wake.
    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let prevStatus = self.lastPathStatus
            let prevTypes = self.lastInterfaceTypes
            let curTypes = Set(path.availableInterfaces.map { $0.type })
            self.lastPathStatus = path.status
            self.lastInterfaceTypes = curTypes

            guard PreferencesManager.shared.isSyncEnabled else { return }
            guard path.status == .satisfied else { return }
            // Refresh on recovery (was not satisfied → now satisfied) or on a
            // meaningful interface change while staying satisfied (e.g. roaming
            // between Wi-Fi APs / switching SSID). Same-type/same-status updates
            // are ignored to avoid flapping. refreshDiscovery() has its own
            // reentry guard, so concurrent triggers are coalesced.
            let recovered = prevStatus != .satisfied
            let interfacesChanged = prevTypes != curTypes
            guard recovered || interfacesChanged else { return }
            appLog("Network path changed (status \(prevStatus)→\(path.status), types \(prevTypes)→\(curTypes)); refreshing LAN discovery")
            self.refreshDiscovery()
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathStatus = .requiresConnection
        lastInterfaceTypes = []
    }

    func start() {
        appLog("SyncManager starting...")
        let needListen = PreferencesManager.shared.isSyncEnabled ||
            NotificationManager.shared.notificationSyncEnabled
        guard needListen else { return }

        startListening()
        if PreferencesManager.shared.isSyncEnabled {
            startPeerLivenessProbing()
            triggerCrossBandDiscovery()
        }
        startPathMonitoring()
    }
    
    func stop() {
        appLog("SyncManager stopping and cleaning up resources...")

        // Tear down the POSIX IPv4 listener and all its clients.
        stopPosixIPv4Listener()

        // Cancel all active connections
        for connection in activeConnections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        activeConnections.removeAll()

        peerLivenessTimer?.cancel()
        peerLivenessTimer = nil
        isProbingPeers = false
        stopPathMonitoring()

        // A stop discards queued frames: they were bound to the now-vanished
        // session. On restart, fresh copies will re-broadcast as the user re-copies.
        pendingQueue.removeAll()
        receiveBuffers.removeAll()

        peersLock.lock()
        discoveredPeers.removeAll()
        peerMissCounts.removeAll()
        peersLock.unlock()

        // Notify UI so stale device snapshots do not linger after sync stops.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDevicesChanged?([])
            self.onPeersChanged?([])
            NotificationCenter.default.post(
                name: .syncAvailableDevicesDidChange,
                object: self,
                userInfo: ["devices": [String](), "peers": [DiscoveredPeer]()]
            )
        }

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

    /// Clears discovered peers and re-runs subnet scan + manual peer connect.
    /// Keeps the TCP listener running so inbound messages are not interrupted.
    func refreshDiscovery() {
        guard PreferencesManager.shared.isSyncEnabled else {
            appLog("refreshDiscovery skipped: sync disabled", level: .warning)
            return
        }
        guard !isRefreshingDiscovery else {
            appLog("refreshDiscovery skipped: already in progress")
            return
        }
        isRefreshingDiscovery = true
        appLog("Refreshing LAN device discovery...")

        peersLock.lock()
        discoveredPeers.removeAll()
        peerMissCounts.removeAll()
        peersLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDevicesChanged?([])
            self.onPeersChanged?([])
            NotificationCenter.default.post(
                name: .syncAvailableDevicesDidChange,
                object: self,
                userInfo: ["devices": [String](), "peers": [DiscoveredPeer]()]
            )
        }

        syncQueue.async { [weak self] in
            guard let self else { return }
            self.triggerCrossBandDiscovery()
            self.isRefreshingDiscovery = false
            appLog("LAN device discovery refresh completed")
        }
    }

    var availablePeers: [DiscoveredPeer] {
        peersLock.lock()
        defer { peersLock.unlock() }
        return discoveredPeers.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var availableDeviceNames: [String] {
        return availablePeers.map(\.displayName)
    }

    /// Returns device entries with disambiguated display names. When two or more
    /// peers share the same original display name, a short peerId suffix is
    /// appended (e.g. "Mac (a1b2c3)") so the user can distinguish them in the menu.
    var availableDeviceEntries: [DeviceEntry] {
        let peers = availablePeers
        var nameCounts: [String: Int] = [:]
        for peer in peers {
            nameCounts[peer.displayName, default: 0] += 1
        }
        return peers.map { peer in
            let display: String
            if (nameCounts[peer.displayName] ?? 0) > 1 {
                let suffix = String(peer.peerId.prefix(6))
                display = "\(peer.displayName) (\(suffix))"
            } else {
                display = peer.displayName
            }
            return DeviceEntry(displayName: display, peerId: peer.peerId, originalName: peer.displayName)
        }
    }

    // MARK: - Peer Liveness Probing
    private func startPeerLivenessProbing() {
        peerLivenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + Self.peerLivenessInterval, repeating: Self.peerLivenessInterval)
        timer.setEventHandler { [weak self] in
            self?.probeDiscoveredPeers()
        }
        peerLivenessTimer = timer
        timer.resume()
    }

    /// Probes every discovered peer's TCP server; browse results alone cannot be
    /// trusted because mDNS may never report an abrupt departure.
    private func probeDiscoveredPeers() {
        guard !isRefreshingDiscovery, !isProbingPeers else { return }
        let peers = availablePeers
        guard !peers.isEmpty else { return }
        isProbingPeers = true

        let group = DispatchGroup()
        let resultsLock = NSLock()
        var failedPeerIds: [String] = []

        for peer in peers {
            group.enter()
            probePeer(peer) { [weak self] reachable in
                if reachable {
                    self?.peersLock.lock()
                    self?.peerMissCounts[peer.peerId] = 0
                    self?.peersLock.unlock()
                } else {
                    resultsLock.lock()
                    failedPeerIds.append(peer.peerId)
                    resultsLock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: syncQueue) { [weak self] in
            guard let self else { return }
            self.isProbingPeers = false
            for peerId in failedPeerIds {
                self.recordPeerMiss(peerId: peerId)
            }
        }
    }

    /// A live peer accepts a bare TCP connection on its sync port instantly.
    private func probePeer(_ peer: DiscoveredPeer, completion: @escaping (Bool) -> Void) {
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        let connection = NWConnection(to: peer.endpoint, using: parameters)

        let finishLock = NSLock()
        var finished = false
        let finish: (Bool) -> Void = { reachable in
            finishLock.lock()
            guard !finished else {
                finishLock.unlock()
                return
            }
            finished = true
            finishLock.unlock()
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(reachable)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: syncQueue)
        syncQueue.asyncAfter(deadline: .now() + 4) {
            finish(false)
        }
    }

    /// Counts a failed connection attempt; evicts the peer after repeated failures.
    private func recordPeerMiss(peerId: String) {
        peersLock.lock()
        guard discoveredPeers[peerId] != nil else {
            peerMissCounts.removeValue(forKey: peerId)
            peersLock.unlock()
            return
        }
        let misses = (peerMissCounts[peerId] ?? 0) + 1
        peerMissCounts[peerId] = misses
        let shouldEvict = misses >= Self.peerLivenessMaxMisses
        if shouldEvict {
            discoveredPeers.removeValue(forKey: peerId)
            peerMissCounts.removeValue(forKey: peerId)
        }
        peersLock.unlock()

        guard shouldEvict else { return }
        appLog("Evicting unreachable peer \(peerId) after \(misses) failed probes", level: .warning)
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

    /// Maps a failed send endpoint back to a discovered peer and counts the miss.
    private func recordPeerMiss(forEndpoint endpoint: NWEndpoint) {
        guard case let .hostPort(host, _) = endpoint else { return }
        peersLock.lock()
        let peerId = discoveredPeers.values.first { peer in
            if case let .hostPort(peerHost, _) = peer.endpoint {
                return peerHost == host
            }
            return false
        }?.peerId
        peersLock.unlock()
        if let peerId {
            recordPeerMiss(peerId: peerId)
        }
    }

    // MARK: - POSIX IPv4 Listener
    //
    // mDNS has been removed; NWListener is no longer needed (it was only used
    // to register a Bonjour service and accept inbound NWConnections). Its
    // IPv6/dual-stack socket behavior caused port conflicts with the POSIX
    // IPv4 listener and unreliable IPv4-mapped connection handling (symptom:
    // "Connection reset by peer" on the Android side). The POSIX listener is
    // now the sole inbound path: it binds 0.0.0.0 explicitly so IPv4 LAN peers
    // can reach us, and dispatches into processReceivedData for framing.
    private func startListening() {
        let port = Int32(PreferencesManager.shared.syncPort)
        appLog("Starting POSIX IPv4 listener on port \(port) as '\(displayName)' (peerId=\(peerId))...")
        startPosixIPv4Listener()
    }
    
    // MARK: - POSIX IPv4 Listener
    //
    // NWListener (Network.framework) on macOS always creates an IPv6 socket
    // regardless of requiredLocalEndpoint, so remote IPv4 LAN peers time out
    // connecting to it (the cross-band sync root cause). This POSIX listener
    // binds 0.0.0.0 explicitly so those peers can reach us. Accepted
    // connections reuse the same length-prefixed framing and dispatch into
    // processReceivedData. All handlers run on syncQueue.

    private func startPosixIPv4Listener() {
        let port = UInt16(PreferencesManager.shared.syncPort)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            appLog("POSIX IPv4 socket() failed errno=\(errno)", level: .error)
            return
        }
        // Non-blocking so DispatchSourceRead can drive accept/recv.
        let curFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, curFlags | O_NONBLOCK)
        // Allow quick rebind after restart.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0  // INADDR_ANY (0.0.0.0)
        let bindOk = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0 else {
            appLog("POSIX IPv4 bind failed on 0.0.0.0:\(port) errno=\(errno)", level: .error)
            close(fd)
            return
        }
        guard listen(fd, 32) == 0 else {
            appLog("POSIX IPv4 listen failed errno=\(errno)", level: .error)
            close(fd)
            return
        }
        posixListenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: syncQueue)
        source.setEventHandler { [weak self] in
            self?.posixAcceptLoop(listenFD: fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        posixListenSource = source
        appLog("POSIX IPv4 listener ready on 0.0.0.0:\(port)")
    }

    /// Drains the accept queue until EWOULDBLOCK. Each client fd is armed with
    /// its own read source for length-prefixed frame reassembly.
    private func posixAcceptLoop(listenFD: Int32) {
        while true {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFD, sa, &len)
                }
            }
            if clientFD >= 0 {
                let cflags = fcntl(clientFD, F_GETFL, 0)
                _ = fcntl(clientFD, F_SETFL, cflags | O_NONBLOCK)
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sinAddr = addr.sin_addr
                inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let host = String(cString: ipBuf)
                posixArmClient(clientFD, host: host)
            } else if errno == EWOULDBLOCK || errno == EAGAIN {
                break
            } else if errno == EINTR {
                continue
            } else {
                appLog("POSIX accept error errno=\(errno)", level: .warning)
                break
            }
        }
    }

    private func posixArmClient(_ fd: Int32, host: String) {
        posixClientBuffers[fd] = Data()
        posixClientHosts[fd] = host
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: syncQueue)
        source.setEventHandler { [weak self] in
            self?.posixHandleClientReadable(fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        posixClientSources[fd] = source
        appLog("POSIX client connected fd=\(fd) host=\(host)")
    }

    /// Loops recv until EWOULDBLOCK so one event handler drains all pending
    /// bytes (DispatchSourceRead is level-triggered, but this avoids extra
    /// wakeups on large transfers).
    private func posixHandleClientReadable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // posixIngest may tear down a misbehaving connection mid-frame.
            guard posixClientSources[fd] != nil else { return }
            let n = chunk.withUnsafeMutableBytes { buf in
                recv(fd, buf.baseAddress, buf.count, 0)
            }
            if n == 0 {
                posixCloseClient(fd)
                return
            }
            if n < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR {
                    return
                }
                posixCloseClient(fd)
                return
            }
            posixIngest(Data(chunk.prefix(n)), fd: fd)
        }
    }

    /// Length-prefixed frame reassembly for POSIX clients, mirroring
    /// ingestReceivedData. Dispatches whole frames to processReceivedData with
    /// a reply closure that writes directly to the client fd.
    private func posixIngest(_ chunk: Data, fd: Int32) {
        var buffer = posixClientBuffers[fd] ?? Data()
        buffer.append(chunk)
        while true {
            guard buffer.count >= 4 else { break }
            let length = Int(buffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard length > 0, length <= Self.maxMessageLength else {
                appLog("POSIX rejecting frame with invalid length \(length)", level: .error)
                posixCloseClient(fd)
                return
            }
            guard buffer.count >= 4 + length else { break }
            let frame = buffer.subdata(in: 4..<(4 + length))
            let host = posixClientHosts[fd]
            processReceivedData(frame, peerHost: host, reply: { [weak self] replyData in
                self?.posixSend(fd: fd, data: replyData)
            })
            buffer.removeSubrange(0..<(4 + length))
        }
        posixClientBuffers[fd] = buffer
    }

    private func posixSend(fd: Int32, data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    appLog("POSIX send failed fd=\(fd) errno=\(errno)", level: .warning)
                    return
                }
                sent += n
            }
        }
    }

    private func posixCloseClient(_ fd: Int32) {
        if let source = posixClientSources.removeValue(forKey: fd) {
            source.cancel()  // cancelHandler closes the fd
        }
        posixClientBuffers.removeValue(forKey: fd)
        posixClientHosts.removeValue(forKey: fd)
    }

    private func stopPosixIPv4Listener() {
        posixListenSource?.cancel()  // cancelHandler closes the listen fd
        posixListenSource = nil
        posixListenFD = -1
        for fd in Array(posixClientSources.keys) {
            posixCloseClient(fd)
        }
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
        connection.receive(minimumIncompleteLength: 4, maximumLength: Self.maxMessageLength) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }
            if let data = data, !data.isEmpty {
                self.ingestReceivedData(data, from: connection)
            }
            if error != nil || isComplete {
                self.receiveBuffers.removeValue(forKey: ObjectIdentifier(connection))
                self.removeConnection(connection)
                connection.cancel()
            } else {
                self.receiveMessage(from: connection)
            }
        }
    }

    /// Appends newly arrived bytes to the per-connection buffer and extracts as
    /// many whole length-prefixed frames as are available. A single TCP segment
    /// may carry a partial frame, multiple frames, or a frame spanning segments.
    private func ingestReceivedData(_ chunk: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var buffer = receiveBuffers[key] ?? Data()
        buffer.append(chunk)

        while true {
            guard buffer.count >= 4 else { break }
            let length = Int(buffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard length > 0, length <= Self.maxMessageLength else {
                appLog("Rejecting frame with invalid length \(length)", level: .error)
                receiveBuffers.removeValue(forKey: key)
                removeConnection(connection)
                connection.cancel()
                return
            }
            guard buffer.count >= 4 + length else { break }

            let frame = buffer.subdata(in: 4..<(4 + length))
            processReceivedData(frame, peerHost: hostString(from: connection.endpoint), reply: { [weak connection] data in
                connection?.send(content: data, completion: .contentProcessed { _ in })
            })

            buffer.removeSubrange(0..<(4 + length))
        }

        receiveBuffers[key] = buffer
    }
    
    private func processReceivedData(_ data: Data, peerHost: String? = nil, reply: ((Data) -> Void)? = nil) {
        guard let message = try? JSONDecoder().decode(SyncMessage.self, from: data) else {
            appLog("Failed to decode SyncMessage", level: .error)
            return
        }

        // Inbound trust is the shared AES secret. authorizedPeerIds only controls
        // which peers this device pushes clipboard/history to (one-way authorize UX).
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
        case "handshake/hello":
            handleHandshakeHello(decrypted, from: message.deviceId, peerHost: peerHost, reply: reply)
        case "handshake/hi":
            handleHandshakeHi(decrypted, from: message.deviceId, peerHost: peerHost)
        default:
            break
        }
    }

    private func handleNotificationConfig(_ decrypted: String) {
        // 安全加固：不再允许对端远程覆盖本地白名单。
        // 筛选配置由本机用户自主管理（Android 端两层筛选模型）。
        appLog("SyncManager: ignored remote notification config (security policy)", level: .warning)
    }

    // MARK: - Cross-Band Discovery (subnet scan + manual peers)
    //
    // mDNS multicast is often blocked between 2.4G and 5G bands on home routers,
    // so devices on different bands never discover each other. These paths use
    // direct unicast TCP connects (which are NOT subject to multicast isolation)
    // plus an encrypted handshake to exchange peerId/displayName, then inject the
    // peer into discoveredPeers so all existing fan-out / liveness / queue logic
    // works unchanged.

    private struct HandshakePayload: Decodable {
        let name: String
        let port: Int
    }

    /// Single entry point invoked from start() / refreshDiscovery(). Runs subnet
    /// scan and manual-peer connect in parallel on syncQueue, fully decoupled
    /// from mDNS browsing so neither blocks the other.
    func triggerCrossBandDiscovery() {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        // Debounce: cancel any pending sweep and schedule a fresh one 400ms
        // later. Coalesces rapid fire from UI toggles / network changes.
        pendingScanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connectManualPeers()
            self?.scanSubnets()
        }
        pendingScanWorkItem = work
        scanQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Enumerates all non-loopback IPv4 addresses on physical interfaces via
    /// getifaddrs(). Used to derive the local /24 subnets to scan.
    /// Non-loopback IPv4 addresses on physical/virtual interfaces, for display.
    func enumerateLocalIPv4s() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let cur = ptr {
            let interface = cur.pointee
            ptr = interface.ifa_next
            guard let addrPtr = interface.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            let addr = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = addr.sin_addr
            inet_ntop(AF_INET, &sinAddr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            guard !ip.hasPrefix("127."), Self.isLanIPv4(ip) else { continue }
            addresses.append(ip)
        }
        return addresses
    }

    /// Returns true only for RFC1918 private addresses used on home/office LANs.
    /// Filters out carrier-grade NAT (e.g. 10.x from mobile data) and public IPs
    /// so we don't try to sync over a metered connection or display noisy IPs.
    private static func isLanIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
        if a == 192 && b == 168 { return true }
        if a == 172 && (b >= 16 && b <= 31) { return true }
        if a == 169 && b == 254 { return true }
        return false
    }

    /// Builds the candidate IPv4 list to probe. Prefers ARP-table filtering
    /// (reads the kernel ARP cache via `arp -a`): on a typical home LAN only
    /// 5-30 entries are live, drastically reducing the TCP probe set versus a
    /// blind /24 sweep. Falls back to full /24 enumeration when ARP yields
    /// nothing (e.g. fresh boot, cross-subnet routing).
    private func candidateScanIPs() -> [String] {
        let myIPs = enumerateLocalIPv4s()
        var seen = Set<String>()
        // Build the full /24 candidate set for every local subnet.
        var fullCandidates: [String] = []
        for ip in myIPs {
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
            for i in 1...254 {
                let candidate = "\(prefix).\(i)"
                if !myIPs.contains(candidate), !seen.contains(candidate) {
                    seen.insert(candidate)
                    fullCandidates.append(candidate)
                }
            }
        }
        // Try ARP-table filtering: keep only candidates present in the cache.
        let arpIPs = readArpTable()
        if !arpIPs.isEmpty {
            let filtered = fullCandidates.filter { arpIPs.contains($0) }
            if !filtered.isEmpty {
                appLog("ARP prefilter: \(fullCandidates.count) → \(filtered.count) candidates")
                return filtered
            }
        }
        appLog("ARP prefilter unavailable, using full \(fullCandidates.count) candidates")
        return fullCandidates
    }

    /// Reads the kernel ARP cache by shelling out to `arp -a -n` and extracting
    /// the IPv4 addresses. Returns an empty set on any failure so callers can
    /// transparently fall back to full /24 enumeration.
    private func readArpTable() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-a", "-n"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var result = Set<String>()
        // arp -a output: "? (192.168.31.1) at aa:bb:.. on en0 ifscope [ethernet]"
        let regex = try? NSRegularExpression(pattern: "\\((\\d+\\.\\d+\\.\\d+\\.\\d+)\\)")
        regex?.enumerateMatches(in: output, range: NSRange(location: 0, length: output.utf16.count)) { match, _, _ in
            if let match = match, let r = Range(match.range(at: 1), in: output) {
                result.insert(String(output[r]))
            }
        }
        return result
    }

    /// Concurrently probes every candidate IP on the sync port; on connect it
    /// fires an encrypted handshake to learn the peer's identity. Concurrency is
    /// capped at 16 and each connect has a 300ms establishment timeout so a full
    /// /24 sweep completes in ~5s without flooding the LAN.
    private func scanSubnets() {
        let portValue = UInt16(PreferencesManager.shared.syncPort)
        guard let nwPort = NWEndpoint.Port(rawValue: portValue) else { return }
        let candidates = candidateScanIPs()
        guard !candidates.isEmpty else { return }
        let scanStart = Date()
        var hits = 0
        appLog("Subnet scan: probing \(candidates.count) candidates on port \(portValue)")

        // 64 concurrent connects is well within LAN TCP SYN capacity and cuts
        // a /24 sweep from ~16s (16-wide) down to ~2s worst case.
        let semaphore = DispatchSemaphore(value: 64)
        let group = DispatchGroup()
        for ip in candidates {
            semaphore.wait()
            group.enter()
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: nwPort)
            performHandshake(to: endpoint) { ok in
                if ok { hits += 1; appLog("Subnet scan: handshake succeeded with \(ip)") }
                semaphore.signal()
                group.leave()
            }
        }
        // Bounded wait: don't let a single stuck NWConnection stall the sweep.
        _ = group.wait(timeout: .now() + 10)
        let elapsedMs = Int(Date().timeIntervalSince(scanStart) * 1000)
        appLog("Subnet scan complete: \(candidates.count) probed, \(hits) hits in \(elapsedMs)ms")
    }

    /// Connects to each manually-configured peer (host:port) and handshakes.
    /// Covers cross-subnet / strict-isolation cases the /24 scan cannot reach.
    private func connectManualPeers() {
        let manualPeers = PreferencesManager.shared.manualSyncPeers
        guard !manualPeers.isEmpty else { return }
        let portValue = UInt16(PreferencesManager.shared.syncPort)
        for entry in manualPeers {
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
            let host = String(parts[0])
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: portValue)!)
            performHandshake(to: endpoint) { ok in
                appLog("Manual peer \(entry) handshake: \(ok ? "ok" : "failed")", level: ok ? .info : .warning)
            }
        }
    }

    /// Opens a TCP connection to `endpoint`, sends an encrypted handshake/hello,
    /// and waits for handshake/hi. On success the peer is recorded via the
    /// normal receive path (processReceivedData → handleHandshakeHi).
    private func performHandshake(to endpoint: NWEndpoint, completion: @escaping (Bool) -> Void) {
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        let connection = NWConnection(to: endpoint, using: parameters)
        var didComplete = false

        // Bounded handshake: 400ms covers LAN RTT (<10ms) plus cross-band
        // routing latency; anything beyond is almost certainly a dead host.
        let timeout = DispatchWorkItem { [weak connection] in
            guard !didComplete else { return }
            didComplete = true
            connection?.cancel()
            completion(false)
        }
        handshakeQueue.asyncAfter(deadline: .now() + 0.4, execute: timeout)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self = self else { return }
                guard let helloFrame = self.makeHandshakeFrame(type: "handshake/hello") else {
                    if !didComplete { didComplete = true; timeout.cancel(); connection.cancel(); completion(false) }
                    return
                }
                connection.send(content: helloFrame, completion: .contentProcessed { error in
                    if let error = error {
                        appLog("Handshake send failed to \(endpoint): \(error)", level: .warning)
                        if !didComplete { didComplete = true; timeout.cancel(); connection.cancel(); completion(false) }
                    }
                })
                // Await the hi reply on the same connection. Route through
                // ingestReceivedData so the 4-byte length prefix is stripped
                // before JSON decode (processReceivedData expects raw JSON).
                connection.receive(minimumIncompleteLength: 4, maximumLength: Self.maxMessageLength) { data, _, _, error in
                    guard !didComplete else { return }
                    didComplete = true
                    timeout.cancel()
                    if let data = data, !data.isEmpty {
                        self.ingestReceivedData(data, from: connection)
                        completion(true)
                    } else {
                        completion(false)
                    }
                    self.receiveBuffers.removeValue(forKey: ObjectIdentifier(connection))
                    connection.cancel()
                }
            case .failed, .cancelled:
                guard !didComplete else { return }
                didComplete = true
                timeout.cancel()
                completion(false)
            default:
                break
            }
        }
        // Run on handshakeQueue (not syncQueue) so 64 concurrent scan
        // handshakes don't starve the POSIX IPv4 listener on syncQueue.
        connection.start(queue: handshakeQueue)
    }

    /// Builds a length-prefixed frame carrying an encrypted handshake message.
    private func makeHandshakeFrame(type: String) -> Data? {
        let payload = "{\"name\":\"\(displayName)\",\"port\":\(PreferencesManager.shared.syncPort)}"
        guard let encryptedContent = encrypt(payload) else { return nil }
        let message = SyncMessage(
            deviceId: peerId,
            timestamp: Date().timeIntervalSince1970,
            type: type,
            content: encryptedContent,
            hash: ""
        )
        guard let body = try? JSONEncoder().encode(message) else { return nil }
        var frame = Data()
        var length = UInt32(body.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(body)
        return frame
    }

    private func handleHandshakeHello(_ decrypted: String, from remotePeerId: String, peerHost: String?, reply: ((Data) -> Void)?) {
        guard let data = decrypted.data(using: .utf8),
              let info = try? JSONDecoder().decode(HandshakePayload.self, from: data) else {
            appLog("Failed to decode handshake/hello payload", level: .warning)
            return
        }
        // The remote's listen port is inside the payload; the remote host is the
        // connection's peer address (the initiator's source IP).
        guard let host = peerHost else {
            appLog("Handshake/hello without resolvable peer host", level: .warning)
            return
        }
        let port = NWEndpoint.Port(rawValue: UInt16(info.port)) ?? NWEndpoint.Port(rawValue: UInt16(PreferencesManager.shared.syncPort))!
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        recordDiscoveredPeer(peerId: remotePeerId, name: info.name, endpoint: endpoint)
        // Reply with hi on the same connection so the initiator learns our identity.
        if let hiFrame = makeHandshakeFrame(type: "handshake/hi") {
            reply?(hiFrame)
        }
    }

    private func handleHandshakeHi(_ decrypted: String, from remotePeerId: String, peerHost: String?) {
        guard let data = decrypted.data(using: .utf8),
              let info = try? JSONDecoder().decode(HandshakePayload.self, from: data) else {
            appLog("Failed to decode handshake/hi payload", level: .warning)
            return
        }
        guard let host = peerHost else { return }
        let port = NWEndpoint.Port(rawValue: UInt16(info.port)) ?? NWEndpoint.Port(rawValue: UInt16(PreferencesManager.shared.syncPort))!
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        recordDiscoveredPeer(peerId: remotePeerId, name: info.name, endpoint: endpoint)
    }

    private func hostString(from endpoint: NWEndpoint) -> String? {
        if case let .hostPort(host, _) = endpoint {
            return "\(host)"
        }
        return nil
    }

    /// Records a peer discovered via handshake and fires the downstream hooks
    /// (UI notification, pending-queue flush, notification backfill) that mDNS
    /// discovery also fires.
    private func recordDiscoveredPeer(peerId: String, name: String, endpoint: NWEndpoint) {
        guard peerId != self.peerId else { return }
        let peer = DiscoveredPeer(peerId: peerId, displayName: name, endpoint: endpoint)
        peersLock.lock()
        let isNew = discoveredPeers[peerId] == nil
        discoveredPeers[peerId] = peer
        peerMissCounts[peerId] = 0
        peersLock.unlock()
        appLog("Discovered peer via handshake: \(name) (peerId=\(peerId)) at \(endpoint)")
        notifyPeersChanged()
        if isNew {
            flushPendingQueue(forPeerId: peerId)
        }
    }

    private func notifyPeersChanged() {
        let peers = availablePeers
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDevicesChanged?(peers.map(\.displayName))
            self.onPeersChanged?(peers)
            NotificationCenter.default.post(
                name: .syncAvailableDevicesDidChange,
                object: self,
                userInfo: ["devices": peers.map(\.displayName), "peers": peers]
            )
        }
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
                // Record the received file in the MAIN clipboard history so it
                // appears in the history list, global search, and the Files type
                // filter — same as locally-copied files. (The legacy standalone
                // file_history.json store has been removed.)
                ClipboardManager.shared.addReceivedFileToHistory(localURL, senderName: senderName)

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

        dispatchBroadcast(jsonData: jsonData, type: type)
    }

    /// Send ACK for a received notification so Android can remove it from
    /// its offline delivery queue. Uses dispatchBroadcast directly (no
    /// isSyncEnabled check) since notification sync operates independently.
    func sendNotificationAck(hash: String) {
        appLog("Sending notification ACK for hash: \(hash)")
        guard let encryptedContent = encrypt("{}") else { return }
        let message = SyncMessage(
            deviceId: peerId,
            timestamp: Date().timeIntervalSince1970,
            type: "notification/ack",
            content: encryptedContent,
            hash: hash
        )
        guard let jsonData = try? JSONEncoder().encode(message) else { return }
        dispatchBroadcast(jsonData: jsonData, type: "notification/ack")
    }

    // MARK: - Sending Sync
    func broadcastSync(content: String, hash: String) {
        guard PreferencesManager.shared.isSyncEnabled else { return }

        guard let jsonData = makeTextSyncPayload(content: content, hash: hash) else { return }

        dispatchBroadcast(jsonData: jsonData, type: "text/plain")
    }

    /// Shared fan-out: sends to authorized peers that are online now, and queues
    /// a copy for each authorized peer that is momentarily offline so it can be
    /// flushed when the peer reappears. Eliminates the "copy during a flutter =
    /// content lost forever" failure mode.
    private func dispatchBroadcast(jsonData: Data, type: String) {
        let authorizedPeerIds = PreferencesManager.shared.authorizedPeerIds
        guard !authorizedPeerIds.isEmpty else { return }

        let onlineTargets = availablePeers.filter { authorizedPeerIds.contains($0.peerId) }
        let onlineIds = Set(onlineTargets.map { $0.peerId })

        for peer in onlineTargets {
            appLog("Sending \(type) to \(peer.displayName) (peerId=\(peer.peerId))")
            sendSync(jsonData, to: peer.endpoint, type: type, targetPeerId: peer.peerId)
        }

        let offlineAuthorized = authorizedPeerIds.filter { !onlineIds.contains($0) }
        if !offlineAuthorized.isEmpty {
            appLog(
                "Queuing \(type) for offline authorized peers: \(offlineAuthorized.joined(separator: ", "))",
                level: .warning
            )
            for peerId in offlineAuthorized {
                enqueuePendingSync(data: jsonData, type: type, targetPeerId: peerId)
            }
        }
    }

    private func enqueuePendingSync(data: Data, type: String, targetPeerId: String) {
        // Drop expired entries first to make room and keep the queue fresh.
        let cutoff = Date().addingTimeInterval(-Self.pendingQueueTTL)
        pendingQueue.removeAll { $0.enqueueAt < cutoff || $0.targetPeerId == targetPeerId && $0.data == data }

        // Per-peer cap: avoid one chatty offline peer monopolizing the buffer.
        let perPeerCount = pendingQueue.filter { $0.targetPeerId == targetPeerId }.count
        guard perPeerCount < Self.pendingQueueMax else { return }

        pendingQueue.append(PendingSync(
            data: data,
            type: type,
            targetPeerId: targetPeerId,
            enqueueAt: Date()
        ))
    }

    /// Called from the browse-results callback when a peer (re)appears: deliver
    /// any frames queued for it while it was offline, oldest first.
    private func flushPendingQueue(forPeerId peerId: String) {
        let cutoff = Date().addingTimeInterval(-Self.pendingQueueTTL)
        let due = pendingQueue.filter { $0.targetPeerId == peerId && $0.enqueueAt >= cutoff }
        guard !due.isEmpty else { return }
        pendingQueue.removeAll { $0.targetPeerId == peerId }

        guard let endpoint = availablePeers.first(where: { $0.peerId == peerId })?.endpoint else { return }
        appLog("Flushing \(due.count) queued frame(s) to reappeared peer \(peerId)")
        for item in due.sorted(by: { $0.enqueueAt < $1.enqueueAt }) {
            sendSync(item.data, to: endpoint, type: item.type, targetPeerId: peerId)
        }
    }

    // MARK: - Peer-targeted sends (resolve by peerId, not displayName)

    @discardableResult
    func sendTextToPeer(_ content: String, hash: String, peerId: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard PreferencesManager.shared.isSyncEnabled else { return false }

        guard let peer = availablePeers.first(where: { $0.peerId == peerId }) else {
            appLog("Could not find peer: \(peerId)", level: .error)
            return false
        }

        guard let jsonData = makeTextSyncPayload(content: content, hash: hash) else { return false }

        appLog("Sending text to \(peer.displayName) (peerId=\(peer.peerId))")
        sendSync(jsonData, to: peer.endpoint, type: "text/plain", targetPeerId: peerId)
        return true
    }

    @discardableResult
    func sendFileToPeer(at url: URL, peerId: String) -> Bool {
        guard PreferencesManager.shared.isSyncEnabled else { return false }
        guard let peer = availablePeers.first(where: { $0.peerId == peerId }) else {
            appLog("Could not find peer: \(peerId)", level: .error)
            return false
        }
        sendFile(at: url, toEndpoint: peer.endpoint, recipientName: peer.displayName,
                 headerType: "file/header", chunkType: "file/chunk")
        return true
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
        guard let peer = availablePeers.first(where: { $0.displayName == targetName }) else {
            appLog("Could not find endpoint for device: \(targetName)", level: .error)
            return
        }
        sendFile(at: url, toEndpoint: peer.endpoint, recipientName: targetName,
                 headerType: "file/header", chunkType: "file/chunk")
    }

    private func sendFile(
        at url: URL,
        toEndpoint endpoint: NWEndpoint,
        recipientName: String,
        headerType: String,
        chunkType: String
    ) {
        appLog("Preparing to send file \(url.lastPathComponent) to \(recipientName)")
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
                appLog("Failed to open connection for file transfer to \(recipientName)", level: .error)
                return
            }
            defer { connection.cancel() }

            guard self.sendFrameBlocking(headerJson, over: connection) else {
                appLog("Failed to send file header to \(recipientName)", level: .error)
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

                // Record the sent file in the MAIN clipboard history (same store
                // as received files and locally-copied files) so it shows up in
                // the history list, global search, and the Files type filter.
                DispatchQueue.main.async {
                    ClipboardManager.shared.addSentFileToHistory(url, recipientName: recipientName)
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
    
    private func sendSync(
        _ data: Data,
        to endpoint: NWEndpoint,
        type: String? = nil,
        targetPeerId: String? = nil
    ) {
        let parameters = NWParameters.tcp
        // Bypass system proxies to avoid 127.0.0.1 redirection from tools like Clash/Surge
        parameters.preferNoProxies = true

        let connection = NWConnection(to: endpoint, using: parameters)

        // Track readiness so the connect-timeout below can no-op once the send
        // has started. NWConnection exposes current state only via its handler.
        // Both the state handler and the timeout fire on syncQueue (serial), so
        // a plain captured var is race-free here.
        var didConnect = false

        // Bounded connection establishment. Without this a `.waiting` connection
        // can linger for the system default (tens of seconds) during network
        // flutter, pinning a slot on syncQueue. Aligns with Android's 5s timeout.
        let timeoutWork: DispatchWorkItem
        if let targetPeerId = targetPeerId, let type = type {
            timeoutWork = DispatchWorkItem { [weak self] in
                guard !didConnect else { return }
                connection.cancel()
                // Transient failure before establishment: re-queue if still fresh.
                self?.enqueuePendingSync(data: data, type: type, targetPeerId: targetPeerId)
            }
        } else {
            timeoutWork = DispatchWorkItem {
                guard !didConnect else { return }
                connection.cancel()
            }
        }
        syncQueue.asyncAfter(deadline: .now() + Self.sendConnectTimeout, execute: timeoutWork)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                didConnect = true
                timeoutWork.cancel()
                // Send length prefix (4 bytes, big-endian) followed by data
                var messageData = Data()
                var length = UInt32(data.count).bigEndian
                let lengthBytes = withUnsafeBytes(of: &length) { Data($0) }
                messageData.append(lengthBytes)
                messageData.append(data)

                connection.send(content: messageData, completion: .contentProcessed({ error in
                    if let error = error {
                        appLog("Send failed to \(endpoint): \(error)", level: .error)
                        // Established but the send itself failed: re-queue once.
                        if let targetPeerId = targetPeerId, let type = type, let self = self {
                            self.enqueuePendingSync(data: data, type: type, targetPeerId: targetPeerId)
                        }
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
                self?.recordPeerMiss(forEndpoint: endpoint)
                if let targetPeerId = targetPeerId, let type = type, let self = self {
                    self.enqueuePendingSync(data: data, type: type, targetPeerId: targetPeerId)
                }
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
