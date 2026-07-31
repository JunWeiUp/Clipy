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

    /// Low-frequency UI presence refresh: every `peerPresenceInterval` we probe
    /// discovered peers only to keep the device list / menu accurate and evict
    /// dead ones after peerLivenessMaxMisses consecutive failures. This is a UI
    /// concern only — actual delivery does NOT depend on it: `sendSync` connects
    /// directly (probe folded into the send path) and a failed send triggers an
    /// on-demand rescan. The previous 120s steady-state probe was lifted to 300s
    /// to drop idle power. 300s × 3 ≈ 15 min grace window. Keep aligned with Android.
    private static let peerPresenceInterval: TimeInterval = 300
    private static let peerLivenessMaxMisses = 3
    private var peerLivenessTimer: DispatchSourceTimer?
    private var peerMissCounts: [String: Int] = [:]

    /// Remembers the last-known endpoint of recently-evicted peers so an
    /// on-demand rescan can re-probe them directly, bypassing ARP-cache
    /// filtering. macOS ARP entries expire (~20 min); once expired the
    /// ARP-filtered /24 scan would never try that IP again, so a phone that
    /// went backgrounded → evicted → ARP-expired → thawed would stay
    /// invisible indefinitely. Entries are pruned after evictedPeerRetention.
    private var evictedPeerEndpoints: [String: (endpoint: NWEndpoint, evictedAt: Date)] = [:]
    private static let evictedPeerRetention: TimeInterval = 600

    /// Persisted cache of discovered peer endpoints (peerId → host/port/name/ts).
    /// Loaded at start() so data transfer works immediately after launch without
    /// waiting for a subnet scan. The full /24 rescan was removed to save power;
    /// instead discovery is on-demand (UI open / endpoint-failure fallback).
    /// Entries expire after endpointCacheTTL. Keep aligned with Android.
    private static let endpointCacheKey = "clipy.peerEndpoints"
    private static let endpointCacheTTL: TimeInterval = 86400 // 24h

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

    // MARK: - Persistent outbound connections
    //
    // Paired devices keep a long-lived outbound TCP connection (with kernel
    // keepalive) so (a) each message skips a fresh connect/handshake, (b) the
    // presence of a live connection IS the online state (no periodic probe
    // needed), and (c) idle traffic collapses to a 60s keepalive ack.
    // Topology is bidirectional independent-outbound: each side maintains its
    // own outbound link for sending; the peer's outbound link lands on our
    // listener for receiving. A pair has at most 2 connections (one per
    // direction); dedup is unnecessary on a LAN.
    private var persistentConnections: [String: NWConnection] = [:]   // peerId -> outbound
    private var reconnectBackoffs: [String: TimeInterval] = [:]       // peerId -> next delay
    private let connectionLock = NSLock()
    private static let keepaliveIdle: TimeInterval = 60
    private static let keepaliveInterval: TimeInterval = 60
    private static let maxReconnectBackoff: TimeInterval = 30

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
        /// Content hash for text/plain frames; used to match an incoming
        /// `message/ack` back to the queued frame so it can be dropped. nil for
        /// types that don't participate in reliable delivery (notification/* etc.).
        let hash: String?
    }
    private var pendingQueue: [PendingSync] = []
    private static let pendingQueueMax = 50
    private static let pendingQueueTTL: TimeInterval = 30
    private static let sendConnectTimeout: TimeInterval = 5

    /// Persistent store for text/plain frames awaiting ACK. Survives restarts
    /// so clipboard content copied just before a quit/crash still reaches the
    /// peer when it reappears (24h window). Bounded (50/peer) + 24h TTL.
    /// All access is syncQueue-confined (callers hop).
    private final class PendingSyncStore {
        // Entry is not `private`: flushPendingQueue (in the enclosing
        // SyncManager) reads its fields (enqueueAt/hash) to merge persisted
        // frames with in-memory ones. PendingSyncStore itself is private to
        // SyncManager, so Entry is never reachable outside this file.
        struct Entry: Codable {
            let data: Data
            let type: String
            let targetPeerId: String
            let hash: String
            let enqueueAt: Date
        }
        static let ttl: TimeInterval = 24 * 60 * 60
        static let maxPerPeer = 50

        private let fileURL: URL
        private var entries: [Entry] = []

        init() {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = appSupport.appendingPathComponent("clipy_pending_sync.json")
            load()
        }

        private func load() {
            guard let raw = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode([Entry].self, from: raw)
            else { return }
            let cutoff = Date().addingTimeInterval(-Self.ttl)
            entries = decoded.filter { $0.enqueueAt >= cutoff }
        }

        private func persist() {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            do {
                let encoded = try JSONEncoder().encode(entries)
                try encoded.write(to: fileURL, options: .atomic)
            } catch {
                appLog("PendingSyncStore: failed to persist (\(error))", level: .error)
            }
        }

        func add(data: Data, type: String, targetPeerId: String, hash: String) {
            let cutoff = Date().addingTimeInterval(-Self.ttl)
            entries.removeAll { $0.enqueueAt < cutoff }
            // Replace any prior entry for the same (peer, hash) — latest copy wins.
            entries.removeAll { $0.targetPeerId == targetPeerId && $0.hash == hash }
            let perPeer = entries.filter { $0.targetPeerId == targetPeerId }.count
            guard perPeer < Self.maxPerPeer else { return }
            entries.append(Entry(
                data: data, type: type, targetPeerId: targetPeerId,
                hash: hash, enqueueAt: Date()))
            persist()
        }

        func remove(hash: String) {
            let before = entries.count
            entries.removeAll { $0.hash == hash }
            if entries.count != before { persist() }
        }

        func entries(forPeerId peerId: String) -> [Entry] {
            let cutoff = Date().addingTimeInterval(-Self.ttl)
            return entries.filter {
                $0.targetPeerId == peerId && $0.enqueueAt >= cutoff
            }
        }

        func clearAll() {
            guard !entries.isEmpty else { return }
            entries.removeAll()
            persist()
        }
    }
    private let pendingSyncStore = PendingSyncStore()

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
            loadPersistedPeerEndpoints()
            // Periodic peer probing removed: a live persistent connection now
            // implies online. Discovery runs on demand (refreshDiscovery) and
            // on network-path changes instead of a 300s timer.
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

        // Tear down persistent outbound connections and cancel pending reconnects.
        connectionLock.lock()
        let persistent = persistentConnections
        persistentConnections.removeAll()
        reconnectBackoffs.removeAll()
        connectionLock.unlock()
        for connection in persistent.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

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
        evictedPeerEndpoints.removeAll()
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

    // MARK: - Peer Presence Refresh (UI only)
    private func startPeerPresenceProbing() {
        peerLivenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + Self.peerPresenceInterval, repeating: Self.peerPresenceInterval)
        timer.setEventHandler { [weak self] in
            self?.probeDiscoveredPeers()
        }
        peerLivenessTimer = timer
        timer.resume()
    }

    /// Extracts host string + port from an NWEndpoint for (de)serialization.
    private func endpointComponents(_ endpoint: NWEndpoint) -> (host: String, port: Int)? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let hostString: String
        switch host {
        case .name(let name, _): hostString = name
        case .ipv4(let addr): hostString = "\(addr)"
        case .ipv6(let addr): hostString = "\(addr)"
        default: hostString = "\(host)"
        }
        return (hostString, Int(port.rawValue))
    }

    /// Loads cached peer endpoints from UserDefaults at launch so data transfer
    /// works immediately without a subnet scan. Stale entries (>endpointCacheTTL)
    /// are discarded. The liveness probe / on-demand scan will validate them.
    private func loadPersistedPeerEndpoints() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.endpointCacheKey) as? [String: [String: Any]] else { return }
        let cutoff = Date().addingTimeInterval(-Self.endpointCacheTTL)
        var loaded = 0
        peersLock.lock()
        for (pid, info) in raw {
            guard let host = info["host"] as? String,
                  let port = info["port"] as? Int,
                  let ts = info["ts"] as? Date, ts > cutoff,
                  let name = info["name"] as? String,
                  let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { continue }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            if discoveredPeers[pid] == nil {
                discoveredPeers[pid] = DiscoveredPeer(peerId: pid, displayName: name, endpoint: endpoint)
                peerMissCounts[pid] = 0
                loaded += 1
            }
        }
        peersLock.unlock()
        if loaded > 0 {
            appLog("Loaded \(loaded) cached peer endpoint(s) from disk")
            notifyPeersChanged()
        }
    }

    /// Persists current discovered peer endpoints to UserDefaults (debounced by
    /// coalescing on each call). Called after a successful discovery.
    private func persistPeerEndpoints() {
        let peers = availablePeers
        var dict: [String: [String: Any]] = [:]
        let now = Date()
        for peer in peers {
            guard let comps = endpointComponents(peer.endpoint) else { continue }
            dict[peer.peerId] = ["host": comps.host, "port": comps.port, "name": peer.displayName, "ts": now]
        }
        UserDefaults.standard.set(dict, forKey: Self.endpointCacheKey)
    }

    /// Removes a single peer's endpoint from the persisted cache (on eviction).
    private func removePersistedPeerEndpoint(peerId: String) {
        guard var dict = UserDefaults.standard.dictionary(forKey: Self.endpointCacheKey) as? [String: [String: Any]] else { return }
        dict.removeValue(forKey: peerId)
        UserDefaults.standard.set(dict, forKey: Self.endpointCacheKey)
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
            if let endpoint = discoveredPeers[peerId]?.endpoint {
                evictedPeerEndpoints[peerId] = (endpoint, Date())
            }
            discoveredPeers.removeValue(forKey: peerId)
            peerMissCounts.removeValue(forKey: peerId)
        }
        peersLock.unlock()
        guard shouldEvict else { return }
        appLog("Evicting unreachable peer \(peerId) after \(misses) failed probes", level: .warning)
        removePersistedPeerEndpoint(peerId: peerId)
        // On-demand fallback: a failed endpoint (DHCP renewal, Wi-Fi roam) is
        // re-discovered by a single subnet scan instead of the old 30s timer.
        triggerCrossBandDiscovery()
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
                // Enable TCP keepalive on the accepted inbound socket so the
                // server side of a persistent link also detects half-open peers
                // within the keepalive window. Inbound persistent connections
                // (the peer's outbound) are drained by posixHandleClientReadable.
                var keepalive: Int32 = 1
                _ = setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &keepalive, socklen_t(MemoryLayout<Int32>.size))
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
            // Reliable delivery: ACK the frame on the inbound socket so the
            // sender can drop it from its persistent queue. Unknown to legacy
            // peers (they fall through to `default` and ignore).
            if let ackFrame = makeMessageAckFrame(hash: message.hash) {
                reply?(ackFrame)
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
        case "message/ack":
            // Sender confirms it processed a text/plain frame we queued; drop
            // the matching entry from the in-memory + persistent queues.
            handleMessageAck(message.hash)
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
            self?.reprobeEvictedPeers()
        }
        pendingScanWorkItem = work
        scanQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Re-probes peers that were recently evicted (e.g. a phone backgrounded →
    /// Doze froze its socket → later thawed). The ARP-filtered subnet scan
    /// misses these IPs once the kernel ARP cache expires, so we probe the
    /// last-known endpoint directly. Entries expire after evictedPeerRetention.
    private func reprobeEvictedPeers() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.evictedPeerRetention)
        peersLock.lock()
        evictedPeerEndpoints = evictedPeerEndpoints.filter { _, entry in
            entry.evictedAt > cutoff
        }
        let toProbe = evictedPeerEndpoints
        peersLock.unlock()
        guard !toProbe.isEmpty else { return }
        for (peerId, info) in toProbe {
            performHandshake(to: info.endpoint) { ok in
                if ok {
                    appLog("Evicted-peer re-probe succeeded: \(peerId) at \(info.endpoint)")
                }
            }
        }
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

    // MARK: - Persistent connection lifecycle

    /// Builds NWParameters with TCP keepalive enabled so half-open links are
    /// detected within the keepalive window instead of lingering indefinitely.
    private static func makeKeepaliveParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = Int(keepaliveIdle)
        tcp.keepaliveInterval = Int(keepaliveInterval)
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        return parameters
    }

    /// Thread-safe lookup of the live outbound connection for a peer.
    private func persistentConnection(for peerId: String) -> NWConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return persistentConnections[peerId]
    }

    /// Writes a length-prefixed frame on an existing connection.
    private func sendFrame(_ connection: NWConnection, data: Data, completion: @escaping (Error?) -> Void) {
        var messageData = Data()
        var length = UInt32(data.count).bigEndian
        messageData.append(withUnsafeBytes(of: &length) { Data($0) })
        messageData.append(data)
        connection.send(content: messageData, completion: .contentProcessed { error in
            completion(error)
        })
    }

    /// Extracts the sender peerId from the first length-prefixed frame in a
    /// raw byte buffer (the handshake/hi reply). Used by the handshake path to
    /// key the resulting persistent connection before promoting it.
    private func extractPeerId(fromLengthPrefixedFrame data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard length > 0, length <= Self.maxMessageLength, data.count >= 4 + length else { return nil }
        let body = data.subdata(in: 4..<(4 + length))
        guard let message = try? JSONDecoder().decode(SyncMessage.self, from: body) else { return nil }
        return message.deviceId
    }

    /// Promotes a freshly established connection to a persistent outbound link
    /// keyed by peerId, replacing any prior link, then starts the inbound drain
    /// loop and flushes frames queued while the peer was offline.
    private func promotePersistentConnection(_ connection: NWConnection, peerId: String) {
        connectionLock.lock()
        let existing = persistentConnections.removeValue(forKey: peerId)
        persistentConnections[peerId] = connection
        reconnectBackoffs[peerId] = 0
        connectionLock.unlock()
        existing?.stateUpdateHandler = nil
        existing?.cancel()
        appLog("Promoted persistent outbound connection to peer \(peerId)")
        receiveMessagePersistent(from: connection, peerId: peerId)
        flushPendingQueue(forPeerId: peerId)
    }

    /// Perpetual receive loop bound to a persistent connection. Drains inbound
    /// frames (acks, peer-originated replies) and tears down on EOF/error.
    private func receiveMessagePersistent(from connection: NWConnection, peerId: String) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: Self.maxMessageLength) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }
            if let data = data, !data.isEmpty {
                self.ingestReceivedData(data, from: connection)
            }
            if error != nil || isComplete {
                self.receiveBuffers.removeValue(forKey: ObjectIdentifier(connection))
                connection.cancel()
                self.teardownPersistentConnection(peerId: peerId)
            } else {
                self.receiveMessagePersistent(from: connection, peerId: peerId)
            }
        }
    }

    /// Tears down a peer's persistent link, marks the peer offline in the UI,
    /// remembers its last endpoint for reconnect, and schedules a backoff retry.
    private func teardownPersistentConnection(peerId: String) {
        connectionLock.lock()
        let conn = persistentConnections.removeValue(forKey: peerId)
        connectionLock.unlock()
        conn?.cancel()

        peersLock.lock()
        if let endpoint = discoveredPeers[peerId]?.endpoint {
            evictedPeerEndpoints[peerId] = (endpoint, Date())
        }
        let didEvict = discoveredPeers.removeValue(forKey: peerId) != nil
        peerMissCounts.removeValue(forKey: peerId)
        peersLock.unlock()
        if didEvict {
            appLog("Persistent link to \(peerId) dropped; marking offline", level: .warning)
            notifyPeersChanged()
        }
        scheduleReconnect(forPeerId: peerId)
    }

    /// Exponential-backoff reconnect (1s→2s→…→30s). Uses the cached evicted
    /// endpoint directly; falls back to the next discovery sweep otherwise.
    /// Cleared on success (promotePersistentConnection resets the backoff).
    private func scheduleReconnect(forPeerId peerId: String) {
        connectionLock.lock()
        let alreadyConnected = persistentConnections[peerId] != nil
        let prev = reconnectBackoffs[peerId] ?? 1
        let backoff = min(prev, Self.maxReconnectBackoff)
        reconnectBackoffs[peerId] = min(prev * 2, Self.maxReconnectBackoff)
        connectionLock.unlock()
        guard !alreadyConnected else { return }

        syncQueue.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self = self else { return }
            self.connectionLock.lock()
            let connected = self.persistentConnections[peerId] != nil
            self.connectionLock.unlock()
            guard !connected else { return }
            self.peersLock.lock()
            let endpoint = self.evictedPeerEndpoints[peerId]?.endpoint
            self.peersLock.unlock()
            guard let endpoint = endpoint else {
                // No cached endpoint; the next refreshDiscovery() sweep will retry.
                return
            }
            self.performHandshake(to: endpoint) { ok in
                if !ok {
                    self.scheduleReconnect(forPeerId: peerId)
                }
            }
        }
    }

    /// Opens a TCP connection to `endpoint`, sends an encrypted handshake/hello,
    /// and waits for handshake/hi. On success the link is promoted to a
    /// persistent outbound connection keyed by the peerId in the hi reply.
    private func performHandshake(to endpoint: NWEndpoint, completion: @escaping (Bool) -> Void) {
        let parameters = Self.makeKeepaliveParameters()
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
                // before JSON decode (processReceivedData expects raw JSON),
                // then promote the link to a persistent outbound connection.
                connection.receive(minimumIncompleteLength: 4, maximumLength: Self.maxMessageLength) { data, _, _, error in
                    guard !didComplete else { return }
                    didComplete = true
                    timeout.cancel()
                    guard let data = data, !data.isEmpty, error == nil else {
                        connection.cancel()
                        completion(false)
                        return
                    }
                    self.ingestReceivedData(data, from: connection)
                    if let peerId = self.extractPeerId(fromLengthPrefixedFrame: data) {
                        self.promotePersistentConnection(connection, peerId: peerId)
                        completion(true)
                    } else {
                        self.receiveBuffers.removeValue(forKey: ObjectIdentifier(connection))
                        connection.cancel()
                        completion(false)
                    }
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
        evictedPeerEndpoints.removeValue(forKey: peerId)
        peersLock.unlock()
        appLog("Discovered peer via handshake: \(name) (peerId=\(peerId)) at \(endpoint)")
        persistPeerEndpoints()
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

        // text/plain participates in reliable delivery (ack + persistence);
        // other types use the in-memory buffer only.
        let hash = (type == "text/plain") ? extractHash(from: data) : nil

        pendingQueue.append(PendingSync(
            data: data,
            type: type,
            targetPeerId: targetPeerId,
            enqueueAt: Date(),
            hash: hash
        ))

        if let hash = hash {
            pendingSyncStore.add(
                data: data, type: type, targetPeerId: targetPeerId, hash: hash)
        }
    }

    /// Best-effort extraction of the content hash from a serialized SyncMessage.
    /// Used to key reliable-delivery entries without changing every enqueue
    /// call site to thread the hash through.
    private func extractHash(from data: Data) -> String? {
        return (try? JSONDecoder().decode(SyncMessage.self, from: data))?.hash
    }

    /// Build a `message/ack` frame acknowledging the given content hash. The
    /// receiver of a text/plain frame replies with this on the inbound socket
    /// so the sender can drop the frame from its persistent delivery queue.
    private func makeMessageAckFrame(hash: String) -> Data? {
        guard let encryptedContent = encrypt("{}") else { return nil }
        let message = SyncMessage(
            deviceId: peerId,
            timestamp: Date().timeIntervalSince1970,
            type: "message/ack",
            content: encryptedContent,
            hash: hash
        )
        return try? JSONEncoder().encode(message)
    }

    /// Handle an inbound ACK: drop the matching text/plain frame from both the
    /// in-memory retry buffer and the persistent store. Hops to syncQueue since
    /// pendingQueue/pendingSyncStore are syncQueue-confined.
    private func handleMessageAck(_ hash: String) {
        syncQueue.async {
            let before = self.pendingQueue.count
            self.pendingQueue.removeAll { $0.hash == hash }
            self.pendingSyncStore.remove(hash: hash)
            if self.pendingQueue.count != before {
                appLog("ACK for hash \(hash) cleared pending frame(s)")
            }
        }
    }

    /// Called from the browse-results callback when a peer (re)appears: deliver
    /// any frames queued for it while it was offline, oldest first. Pulls from
    /// both the in-memory retry buffer and the persistent text/plain store;
    /// dedupes by hash so a frame present in both is sent once. Persisted
    /// entries are NOT removed here — only an ACK retires them.
    private func flushPendingQueue(forPeerId peerId: String) {
        let cutoff = Date().addingTimeInterval(-Self.pendingQueueTTL)
        let due = pendingQueue.filter { $0.targetPeerId == peerId && $0.enqueueAt >= cutoff }
        pendingQueue.removeAll { $0.targetPeerId == peerId }

        // Merge persisted text/plain frames awaiting ACK, deduped by hash.
        var seenHashes = Set<String>()
        var frames: [(Data, String)] = []
        for item in due.sorted(by: { $0.enqueueAt < $1.enqueueAt }) {
            if let h = item.hash { seenHashes.insert(h) }
            frames.append((item.data, item.type))
        }
        let persisted = pendingSyncStore.entries(forPeerId: peerId)
        for item in persisted.sorted(by: { $0.enqueueAt < $1.enqueueAt }) where !seenHashes.contains(item.hash) {
            frames.append((item.data, item.type))
        }

        guard !frames.isEmpty else { return }
        guard let endpoint = availablePeers.first(where: { $0.peerId == peerId })?.endpoint else { return }
        appLog("Flushing \(frames.count) frame(s) to reappeared peer \(peerId) (\(due.count) queued + \(persisted.count) persisted)")
        for frame in frames {
            sendSync(frame.0, to: endpoint, type: frame.1, targetPeerId: peerId)
        }
    }

    /// Handles a send that never established a connection. With periodic
    /// probing removed, a peer may be momentarily absent from the discovered
    /// set (IP change, just-woke-from-sleep, cross-band roam). Before giving
    /// up to the pending queue, do ONE on-demand rescan + retry so a fresh
    /// send reaches the peer in ~1–2s instead of waiting for the next
    /// presence refresh. The retry is bounded (`allowRetry`) to prevent loops.
    private func handleSendEstablishmentFailure(
        data: Data, type: String, peerId: String, allowRetry: Bool
    ) {
        if allowRetry {
            rescanThenRetry(data: data, type: type, peerId: peerId)
        } else {
            enqueuePendingSync(data: data, type: type, targetPeerId: peerId)
        }
    }

    /// Runs an on-demand cross-band rediscovery on scanQueue, then retries the
    /// send once on syncQueue against the peer's (possibly new) endpoint. If
    /// the peer is still unreachable, the frame is handed to the pending queue
    /// for delivery on its next reappearance.
    private func rescanThenRetry(data: Data, type: String, peerId: String) {
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            appLog("On-demand rescan before retrying \(type) send to \(peerId)")
            self.connectManualPeers()
            self.scanSubnets()
            self.reprobeEvictedPeers()
            self.syncQueue.async {
                if let endpoint = self.availablePeers.first(where: { $0.peerId == peerId })?.endpoint {
                    appLog("Rescan rediscovered peer \(peerId); retrying send")
                    self.sendSync(data, to: endpoint, type: type, targetPeerId: peerId, allowRescanRetry: false)
                } else {
                    appLog("Rescan did not rediscover peer \(peerId); queueing", level: .warning)
                    self.enqueuePendingSync(data: data, type: type, targetPeerId: peerId)
                }
            }
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
        targetPeerId: String? = nil,
        allowRescanRetry: Bool = true
    ) {
        // Fast path: reuse a live persistent outbound connection instead of
        // establishing a new TCP connection for every send. The persistent link
        // is keyed by peerId; on send error we tear it down and re-queue the
        // frame so the next attempt goes through the establishment path.
        if let targetPeerId = targetPeerId, let conn = persistentConnection(for: targetPeerId) {
            sendFrame(conn, data: data) { [weak self] error in
                guard let self = self, let error = error else { return }
                appLog("Persistent send to \(targetPeerId) failed: \(error); tearing down", level: .error)
                // The persistent connection runs on handshakeQueue, but
                // pendingQueue is confined to syncQueue. Hop queues to keep
                // pendingQueue access single-threaded.
                self.syncQueue.async {
                    self.teardownPersistentConnection(peerId: targetPeerId)
                    if let type = type {
                        self.enqueuePendingSync(data: data, type: type, targetPeerId: targetPeerId)
                    }
                }
            }
            return
        }

        // Establishment path: for routed sends (targetPeerId + type) with no
        // live persistent link, establish one via handshake and send on it.
        // This replaces the old one-shot connection so a successful send also
        // (re)promotes the persistent link for subsequent reuse. The handshake
        // completion fires on handshakeQueue; pendingQueue is syncQueue-confined
        // so all failure handling hops back to syncQueue.
        if let targetPeerId = targetPeerId, let type = type {
            performHandshake(to: endpoint) { [weak self] ok in
                guard let self = self else { return }
                guard ok, let conn = self.persistentConnection(for: targetPeerId) else {
                    self.syncQueue.async {
                        self.handleSendEstablishmentFailure(
                            data: data, type: type, peerId: targetPeerId, allowRetry: allowRescanRetry)
                    }
                    return
                }
                self.sendFrame(conn, data: data) { [weak self] error in
                    guard let self = self, let error = error else { return }
                    appLog("Post-handshake send to \(targetPeerId) failed: \(error)", level: .error)
                    self.syncQueue.async {
                        self.teardownPersistentConnection(peerId: targetPeerId)
                        self.enqueuePendingSync(data: data, type: type, targetPeerId: targetPeerId)
                    }
                }
            }
            return
        }

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
                // Transient failure before establishment: rediscover then retry
                // once before falling back to the pending queue.
                self?.handleSendEstablishmentFailure(
                    data: data, type: type, peerId: targetPeerId, allowRetry: allowRescanRetry)
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
                    self.handleSendEstablishmentFailure(
                        data: data, type: type, peerId: targetPeerId, allowRetry: allowRescanRetry)
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
