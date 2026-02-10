import Foundation
import Network
import CryptoKit

struct SyncMessage: Codable {
    let deviceId: String
    let timestamp: TimeInterval
    let type: String
    let content: String // Base64 encrypted data
    let hash: String
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
     
    private let serviceType = "_clipy-sync._tcp" 
    private var deviceId: String { PreferencesManager.shared.deviceName } 
     
    private let hardcodedSecret = "ClipySyncSecret2026" 
    
    private var encryptionKey: SymmetricKey {
        let data = hardcodedSecret.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        return SymmetricKey(data: hash)
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
            appLog("Received sync from \(message.deviceId): \(decrypted.prefix(20))...")
            ClipboardManager.shared.handleRemoteSync(content: decrypted, hash: message.hash)
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
