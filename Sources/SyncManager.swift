import Foundation
import Network

enum SyncMessage: Codable {
    case historyItem(HistoryEntry)
    case snippetFolders([SnippetFolder])
    case ping(String) // Device name

    enum CodingKeys: String, CodingKey {
        case historyItem
        case snippetFolders
        case ping
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let entry = try? container.decode(HistoryEntry.self, forKey: .historyItem) {
            self = .historyItem(entry)
        } else if let folders = try? container.decode([SnippetFolder].self, forKey: .snippetFolders) {
            self = .snippetFolders(folders)
        } else if let name = try? container.decode(String.self, forKey: .ping) {
            self = .ping(name)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .ping, in: container, debugDescription: "Invalid message format")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .historyItem(let entry):
            try container.encode(entry, forKey: .historyItem)
        case .snippetFolders(let folders):
            try container.encode(folders, forKey: .snippetFolders)
        case .ping(let name):
            try container.encode(name, forKey: .ping)
        }
    }
}

class SyncManager {
    static let shared = SyncManager()
    
    private let serviceType = "_clipy-sync._tcp"
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [UUID: NWConnection] = [:]
    private var connectedEndpoints: Set<String> = []
    private var deviceNames: [UUID: String] = [:]
    
    var onDevicesChanged: ((Set<String>) -> Void)?
    var discoveredDevices: Set<String> {
        return queue.sync { Set(deviceNames.values) }
    }
    
    private let queue = DispatchQueue(label: "com.clipyclone.sync")
    
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
    
    private init() {
        if PreferencesManager.shared.isSyncEnabled {
            start()
        }
    }
    
    func start() {
        startListening()
        startBrowsing()
    }
    
    func stop() {
        listener?.cancel()
        browser?.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        connectedEndpoints.removeAll()
        deviceNames.removeAll()
        onDevicesChanged?(Set())
    }
    
    private func startListening() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: PreferencesManager.shared.syncDeviceName, type: serviceType)
            
            listener.stateUpdateHandler = { state in
                print("Listener state: \(state)")
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.setupConnection(connection)
            }
            
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("Failed to start listener: \(error)")
        }
    }
    
    private func startBrowsing() {
        let parameters = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            for result in results {
                self?.connect(to: result.endpoint)
            }
        }
        
        browser.start(queue: queue)
        self.browser = browser
    }
    
    private func connect(to endpoint: NWEndpoint) {
        let endpointString = endpoint.debugDescription
        if connectedEndpoints.contains(endpointString) {
            return
        }
        
        // Avoid connecting to self
        if case let .service(name, _, _, _) = endpoint, name == PreferencesManager.shared.syncDeviceName {
            return
        }
        
        print("Connecting to \(endpoint)...")
        let connection = NWConnection(to: endpoint, using: .tcp)
        setupConnection(connection)
    }
    
    private func setupConnection(_ connection: NWConnection) {
        let id = UUID()
        let endpointString = connection.endpoint.debugDescription
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("Connection ready: \(connection.endpoint)")
                self.queue.async {
                    self.connections[id] = connection
                    self.connectedEndpoints.insert(endpointString)
                }
                self.receiveMessage(from: connection, id: id)
                self.sendPing(to: connection)
            case .failed(let error):
                print("Connection failed: \(error)")
                self.removeConnection(id: id, endpoint: endpointString)
            case .cancelled:
                self.removeConnection(id: id, endpoint: endpointString)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    private func sendPing(to connection: NWConnection) {
        sendMessage(.ping(PreferencesManager.shared.syncDeviceName), to: connection)
    }
    
    private func sendMessage(_ message: SyncMessage, to connection: NWConnection) {
        do {
            let data = try encoder.encode(message)
            // Use a simple length-prefix framing
            var prefix = UInt32(data.count).bigEndian
            let prefixData = Data(bytes: &prefix, count: 4)
            
            connection.send(content: prefixData + data, completion: .contentProcessed { error in
                if let error = error {
                    print("Send error: \(error)")
                }
            })
        } catch {
            print("Encode error: \(error)")
        }
    }
    
    func broadcast(_ message: SyncMessage) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        queue.async {
            for (id, connection) in self.connections {
                // Only broadcast to allowed devices
                if let deviceName = self.deviceNames[id], PreferencesManager.shared.allowedDevices.contains(deviceName) {
                    self.sendMessage(message, to: connection)
                }
            }
        }
    }
    
    private func receiveMessage(from connection: NWConnection, id: UUID) {
        // Read 4 bytes length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            if let data = data, data.count == 4 {
                let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                self?.receivePayload(length: Int(length), from: connection, id: id)
            } else if isComplete {
                self?.removeConnection(id: id, endpoint: connection.endpoint.debugDescription)
            } else if let error = error {
                print("Receive error: \(error)")
            }
        }
    }
    
    private func receivePayload(length: Int, from connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            if let data = data {
                self?.handleIncomingData(data, from: id)
                self?.receiveMessage(from: connection, id: id) // Next message
            } else if isComplete {
                self?.removeConnection(id: id, endpoint: connection.endpoint.debugDescription)
            } else if let error = error {
                print("Receive payload error: \(error)")
            }
        }
    }
    
    private func removeConnection(id: UUID, endpoint: String) {
        self.queue.async {
            self.connections.removeValue(forKey: id)
            self.connectedEndpoints.remove(endpoint)
            self.deviceNames.removeValue(forKey: id)
            let currentDevices = Set(self.deviceNames.values)
            DispatchQueue.main.async {
                self.onDevicesChanged?(currentDevices)
            }
        }
    }
    
    private func handleIncomingData(_ data: Data, from id: UUID) {
        do {
            let message = try decoder.decode(SyncMessage.self, from: data)
            
            // We are already on 'queue' here because connection.receive was started with it.
            // Accessing deviceNames is safe without queue.sync.
            let deviceName = self.deviceNames[id]
            let isAllowed = deviceName != nil && PreferencesManager.shared.allowedDevices.contains(deviceName!)

            DispatchQueue.main.async {
                switch message {
                case .historyItem(let entry):
                    if isAllowed {
                        ClipboardManager.shared.receiveSyncedItem(entry)
                    }
                case .snippetFolders(let folders):
                    if isAllowed {
                        SnippetManager.shared.receiveSyncedFolders(folders)
                    }
                case .ping(let name):
                    print("Received ping from \(name)")
                    self.queue.async {
                        self.deviceNames[id] = name
                        // Get current devices directly while on queue to avoid deadlock with computed property
                        let currentDevices = Set(self.deviceNames.values)
                        DispatchQueue.main.async {
                            self.onDevicesChanged?(currentDevices)
                        }
                    }
                }
            }
        } catch {
            print("Decode incoming error: \(error)")
        }
    }
}
