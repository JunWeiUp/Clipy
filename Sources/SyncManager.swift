import Foundation
import Network
import CryptoKit

struct SyncMessage: Codable {
    let historyItem: HistoryEntry?
    let snippetFolders: [SnippetFolder]?
    let ping: String?
    let handshake: HandshakeData?
    let contentHash: String?
    let origin: String?
    
    struct HandshakeData: Codable {
        let name: String
        let version: Int
        let lastSyncTime: Date?
    }
    
    static func handshake(name: String, version: Int, lastSyncTime: Date?) -> SyncMessage {
        SyncMessage(historyItem: nil,
                    snippetFolders: nil,
                    ping: nil,
                    handshake: HandshakeData(name: name, version: version, lastSyncTime: lastSyncTime),
                    contentHash: nil,
                    origin: nil)
    }
    
    static func ping(_ name: String) -> SyncMessage {
        SyncMessage(historyItem: nil,
                    snippetFolders: nil,
                    ping: name,
                    handshake: nil,
                    contentHash: nil,
                    origin: nil)
    }
    
    static func historyItem(_ entry: HistoryEntry, contentHash: String, origin: String) -> SyncMessage {
        SyncMessage(historyItem: entry,
                    snippetFolders: nil,
                    ping: nil,
                    handshake: nil,
                    contentHash: contentHash,
                    origin: origin)
    }
    
    static func snippetFolders(_ folders: [SnippetFolder], contentHash: String, origin: String) -> SyncMessage {
        SyncMessage(historyItem: nil,
                    snippetFolders: folders,
                    ping: nil,
                    handshake: nil,
                    contentHash: contentHash,
                    origin: origin)
    }
}

class SyncManager: NSObject {
    static let shared = SyncManager()
    
    private let serviceType = "_clipy-sync._tcp"
    
    private var listener: NWListener?
    private var netServiceBrowser: NetServiceBrowser?
    private var netService: NetService?
    private var resolvingServices: [String: NetService] = [:]
    
    private var discoveredDeviceNames: Set<String> = []
    private var discoveredDeviceIPs: [String: [String]] = [:]
    private var deviceLastSeen: [String: Date] = [:]
    
    private var recentContentHashes: [String: Date] = [:]
    private let contentHashTTL: TimeInterval = 300
    
    var onDevicesChanged: ((Set<String>) -> Void)?
    var onDeviceStatusChanged: (([String: Date]) -> Void)?
    
    var discoveredDevices: Set<String> {
        return syncOnQueue { discoveredDeviceNames }
    }
    
    var deviceStatuses: [String: Date] {
        return syncOnQueue { deviceLastSeen }
    }
    
    private let queue = DispatchQueue(label: "com.clipyclone.sync")
    private let queueKey = DispatchSpecificKey<Void>()
    
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    
    private var symmetricKey: SymmetricKey {
        let keyString = PreferencesManager.shared.syncKey
        var keyData = keyString.data(using: .utf8) ?? Data()
        
        // Ensure 32 bytes for AES-256
        if keyData.count < 32 {
            keyData.append(Data(repeating: 0, count: 32 - keyData.count))
        } else if keyData.count > 32 {
            keyData = keyData.prefix(32)
        }
        
        return SymmetricKey(data: keyData)
    }
    
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            
            // 1. Try ISO8601 with fractional seconds and 'Z'
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFormatter.date(from: dateStr) {
                return date
            }
            
            // 2. Try ISO8601 without fractional seconds
            isoFormatter.formatOptions = [.withInternetDateTime]
            if let date = isoFormatter.date(from: dateStr) {
                return date
            }
            
            // 3. Fallback for Dart's default toIso8601String()
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

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()
    
    private override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: ())
        if PreferencesManager.shared.isSyncEnabled {
            start()
        }
    }
    
    func start() {
        startHTTPServer()
        startBonjour()
    }
    
    func stop() {
        listener?.cancel()
        netServiceBrowser?.stop()
        netService?.stop()
        discoveredDeviceNames.removeAll()
        discoveredDeviceIPs.removeAll()
        onDevicesChanged?(Set())
    }
    
    private func startHTTPServer() {
        do {
            let parameters = NWParameters.tcp
            let listener = try NWListener(using: parameters, on: 8080)
            listener.stateUpdateHandler = { state in
                print("HTTP listener state: \(state)")
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleHTTPConnection(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("Failed to start HTTP listener: \(error)")
        }
    }
    
    private func startBonjour() {
        let service = NetService(domain: "local.", type: serviceType, name: PreferencesManager.shared.syncDeviceName, port: 8080)
        service.delegate = self
        service.includesPeerToPeer = true
        service.publish()
        netService = service
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
        netServiceBrowser = browser
    }
    
    private func handleHTTPConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(from: connection)
    }
    
    private func receiveHTTPRequest(from connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let _ = error {
                connection.cancel()
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            var newBuffer = buffer
            if let data = data {
                newBuffer.append(data)
            }
            if let headerRange = newBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = newBuffer.subdata(in: 0..<headerRange.lowerBound)
                let bodyStart = headerRange.upperBound
                if let headerText = String(data: headerData, encoding: .utf8) {
                    let lines = headerText.components(separatedBy: "\r\n")
                    guard let requestLine = lines.first, requestLine.hasPrefix("POST /sync") else {
                        connection.cancel()
                        return
                    }
                    let contentLength = lines
                        .first(where: { $0.lowercased().hasPrefix("content-length:") })
                        .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                    if contentLength <= 0 || contentLength > 10 * 1024 * 1024 {
                        connection.cancel()
                        return
                    }
                    let totalLength = bodyStart + contentLength
                    if newBuffer.count >= totalLength {
                        let body = newBuffer.subdata(in: bodyStart..<totalLength)
                        self.handleSyncBody(body, from: connection)
                        return
                    }
                }
            }
            self.receiveHTTPRequest(from: connection, buffer: newBuffer)
        }
    }
    
    private func handleSyncBody(_ body: Data, from connection: NWConnection) {
        if body.count == 0 || body.count > 10 * 1024 * 1024 {
            connection.cancel()
            return
        }
        if let package = try? decoder.decode(EncryptedPackage.self, from: body),
           let decrypted = decrypt(package) {
            processSyncMessage(decrypted, from: connection)
        } else {
            processSyncMessage(body, from: connection)
        }
    }
    
    private func processSyncMessage(_ data: Data, from connection: NWConnection) {
        do {
            let message = try decoder.decode(SyncMessage.self, from: data)
            guard let origin = message.origin else {
                respondOK(connection)
                return
            }
            if origin == PreferencesManager.shared.syncDeviceName {
                respondOK(connection)
                return
            }
            if !PreferencesManager.shared.allowedDevices.contains(origin) {
                respondOK(connection)
                return
            }
            if let contentHash = message.contentHash, hasSeenContentHash(contentHash) {
                respondOK(connection)
                return
            }
            if let entry = message.historyItem {
                updateLastSeen(for: origin)
                PreferencesManager.shared.setLastSyncTime(for: origin, date: Date())
                if let hash = entry.contentHash ?? message.contentHash ?? contentHash(for: entry) {
                    recordContentHash(hash)
                    let normalized = HistoryEntry(item: entry.item, date: entry.date, sourceApp: entry.sourceApp, contentHash: hash)
                    DispatchQueue.main.async {
                        ClipboardManager.shared.receiveSyncedItem(normalized)
                    }
                } else {
                    DispatchQueue.main.async {
                        ClipboardManager.shared.receiveSyncedItem(entry)
                    }
                }
                respondOK(connection)
                return
            }
            if let folders = message.snippetFolders {
                updateLastSeen(for: origin)
                PreferencesManager.shared.setLastSyncTime(for: origin, date: Date())
                if let hash = message.contentHash ?? contentHash(for: folders) {
                    recordContentHash(hash)
                }
                DispatchQueue.main.async {
                    SnippetManager.shared.receiveSyncedFolders(folders)
                }
                respondOK(connection)
                return
            }
            respondOK(connection)
        } catch {
            connection.cancel()
        }
    }
    
    private func respondOK(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func updateLastSeen(for deviceName: String) {
        queue.async {
            self.deviceLastSeen[deviceName] = Date()
            let statuses = self.deviceLastSeen
            DispatchQueue.main.async {
                self.onDeviceStatusChanged?(statuses)
            }
        }
    }

    private func syncOnQueue<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return block()
        }
        return queue.sync { block() }
    }
    
    private func pruneContentHashes(now: Date) {
        recentContentHashes = recentContentHashes.filter { now.timeIntervalSince($0.value) < contentHashTTL }
    }
    
    private func recordContentHash(_ hash: String) {
        recentContentHashes[hash] = Date()
    }
    
    private func hasSeenContentHash(_ hash: String) -> Bool {
        pruneContentHashes(now: Date())
        return recentContentHashes[hash] != nil
    }
    
    private func normalizeString(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    
    private func contentHash(for entry: HistoryEntry) -> String? {
        contentHash(for: entry.item)
    }
    
    private func contentHash(for item: HistoryItem) -> String? {
        switch item {
        case .text(let str):
            let normalized = normalizeString(str.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let data = normalized.data(using: .utf8) else { return nil }
            return sha256Hex(data)
        case .image(let data):
            return sha256Hex(data)
        case .rtf(let data):
            return sha256Hex(data)
        case .pdf(let data):
            return sha256Hex(data)
        case .fileURL(let url):
            let normalized = normalizeString(url.absoluteString)
            guard let data = normalized.data(using: .utf8) else { return nil }
            return sha256Hex(data)
        }
    }
    
    private func contentHash(for folders: [SnippetFolder]) -> String? {
        let sortedFolders = folders.sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
        var parts: [String] = []
        for folder in sortedFolders {
            let folderTitle = normalizeString(folder.title)
            let folderPart = "F|\(folder.id.uuidString.lowercased())|\(folderTitle)|\(folder.isEnabled ? "1" : "0")"
            parts.append(folderPart)
            let sortedSnippets = folder.snippets.sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
            for snippet in sortedSnippets {
                let title = normalizeString(snippet.title)
                let content = normalizeString(snippet.content)
                parts.append("S|\(snippet.id.uuidString.lowercased())|\(title)|\(content)")
            }
        }
        let joined = parts.joined(separator: "\n")
        guard let data = joined.data(using: .utf8) else { return nil }
        return sha256Hex(data)
    }
    
    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    func broadcastHistory(_ entry: HistoryEntry) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        queue.async {
            guard let hash = entry.contentHash ?? self.contentHash(for: entry) else { return }
            let normalizedEntry = HistoryEntry(item: entry.item, date: entry.date, sourceApp: entry.sourceApp, contentHash: hash)
            let message = SyncMessage.historyItem(normalizedEntry, contentHash: hash, origin: PreferencesManager.shared.syncDeviceName)
            self.recordContentHash(hash)
            for (deviceName, ips) in self.discoveredDeviceIPs {
                if PreferencesManager.shared.allowedDevices.contains(deviceName) {
                    self.postSync(message: message, toDevice: deviceName, ips: ips)
                }
            }
        }
    }
    
    func broadcastSnippets(_ folders: [SnippetFolder]) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        queue.async {
            guard let hash = self.contentHash(for: folders) else { return }
            let message = SyncMessage.snippetFolders(folders, contentHash: hash, origin: PreferencesManager.shared.syncDeviceName)
            self.recordContentHash(hash)
            for (deviceName, ips) in self.discoveredDeviceIPs {
                if PreferencesManager.shared.allowedDevices.contains(deviceName) {
                    self.postSync(message: message, toDevice: deviceName, ips: ips)
                }
            }
        }
    }
    
    private func postSync(message: SyncMessage, toDevice deviceName: String, ips: [String]) {
        do {
            var data = try encoder.encode(message)
            if message.historyItem != nil || message.snippetFolders != nil {
                if let encryptedData = encrypt(data) {
                    data = try encoder.encode(encryptedData)
                }
            }
            sendSync(data: data, deviceName: deviceName, ips: ips, index: 0)
        } catch {}
    }

    private func sendSync(data: Data, deviceName: String, ips: [String], index: Int) {
        guard index < ips.count else { return }
        let ip = ips[index]
        let host = ip.contains(":") ? "[\(ip)]" : ip
        guard let url = URL(string: "http://\(host):8080/sync") else {
            sendSync(data: data, deviceName: deviceName, ips: ips, index: index + 1)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        urlSession.dataTask(with: request) { _, _, error in
            if let error = error {
                print("HTTP sync failed to \(ip): \(error)")
                self.sendSync(data: data, deviceName: deviceName, ips: ips, index: index + 1)
            }
        }.resume()
    }
    
    // MARK: - Encryption
    
    struct EncryptedPackage: Codable {
        let iv: String
        let payload: String
        let tag: String
    }
    
    private func encrypt(_ data: Data) -> EncryptedPackage? {
        do {
            let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
            return EncryptedPackage(
                iv: sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                payload: sealedBox.ciphertext.base64EncodedString(),
                tag: sealedBox.tag.base64EncodedString()
            )
        } catch {
            print("Encryption error: \(error)")
            return nil
        }
    }
    
    private func decrypt(_ package: EncryptedPackage) -> Data? {
        guard let nonceData = Data(base64Encoded: package.iv),
              let ciphertext = Data(base64Encoded: package.payload),
              let tag = Data(base64Encoded: package.tag) else {
            return nil
        }
        
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            print("Decryption error: \(error)")
            return nil
        }
    }
}

extension SyncManager: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let localName = PreferencesManager.shared.syncDeviceName
        if service.name == localName {
            return
        }
        service.delegate = self
        resolvingServices[service.name] = service
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        queue.async {
            self.resolvingServices.removeValue(forKey: name)
            self.discoveredDeviceNames.remove(name)
            self.discoveredDeviceIPs.removeValue(forKey: name)
            let devices = self.discoveredDeviceNames
            DispatchQueue.main.async {
                self.onDevicesChanged?(devices)
            }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let ips = extractIPAddresses(from: sender)
        if !ips.isEmpty {
            queue.async {
                self.discoveredDeviceNames.insert(name)
                self.discoveredDeviceIPs[name] = ips
                let devices = self.discoveredDeviceNames
                DispatchQueue.main.async {
                    self.onDevicesChanged?(devices)
                }
            }
        }
        resolvingServices.removeValue(forKey: name)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        resolvingServices.removeValue(forKey: sender.name)
    }

    private func extractIPAddresses(from service: NetService) -> [String] {
        guard let addresses = service.addresses else { return [] }
        var ipv4Addresses: [String] = []
        var ipv6Addresses: [String] = []
        for addressData in addresses {
            let ip = addressData.withUnsafeBytes { pointer -> String? in
                guard let sockaddrPointer = pointer.bindMemory(to: sockaddr.self).baseAddress else {
                    return nil
                }
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(sockaddrPointer, socklen_t(addressData.count), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
                if result == 0 {
                    return String(cString: hostBuffer)
                }
                return nil
            }
            guard let resolved = ip, !resolved.isEmpty else { continue }
            let family = addressData.withUnsafeBytes { pointer -> sa_family_t? in
                guard let sockaddrPointer = pointer.bindMemory(to: sockaddr.self).baseAddress else {
                    return nil
                }
                return sockaddrPointer.pointee.sa_family
            }
            if family == sa_family_t(AF_INET) {
                ipv4Addresses.append(resolved)
            } else if family == sa_family_t(AF_INET6) {
                ipv6Addresses.append(resolved)
            }
        }
        return ipv4Addresses + ipv6Addresses
    }
}
