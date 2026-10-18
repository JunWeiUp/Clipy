import Foundation
import Security

// Access keys are per deployment, never embedded in builds or synced to peers.
enum SyncRelaySettings {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "syncRelayEnabled") }
    static var url: String { UserDefaults.standard.string(forKey: "syncRelayURL") ?? "" }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.clipy.sync-relay", kSecAttrAccount as String: "default"]
    }
    static func token() -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func clearEnrollment() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain:"SyncRelay",code:Int(status)) }
        UserDefaults.standard.set(false,forKey:"syncRelayEnabled")
        UserDefaults.standard.set(UUID().uuidString,forKey:"syncRelayDeviceId")
    }
    static var deviceID: String {
        UserDefaults.standard.string(forKey: "syncRelayDeviceId")
            ?? SyncRelayClient.Access.parse(token())?.device
            ?? PreferencesManager.shared.syncPeerId
    }
    static func validDeviceID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }
    static func preparedConfiguration(existing: String, deviceID: String, accessKey: String, enrollment: String) throws -> String {
        guard validDeviceID(deviceID), enrollment.utf8.count <= 65536 else { throw NSError(domain: "SyncRelay", code: 3) }
        let source = enrollment.isEmpty ? existing : enrollment
        if source.isEmpty {
            guard accessKey.isEmpty else { throw NSError(domain: "SyncRelay", code: 4) }
            return ""
        }
        guard var object = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any],
              enrollment.isEmpty || object["device"] as? String == deviceID else { throw NSError(domain: "SyncRelay", code: 3) }
        if enrollment.isEmpty, accessKey.isEmpty, object["device"] as? String == deviceID { return existing }
        object["device"] = deviceID
        if !accessKey.isEmpty { object["token"] = accessKey }
        let result = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        guard SyncRelayClient.Access.parse(result) != nil else { throw NSError(domain: "SyncRelay", code: 3) }
        return result
    }
    @discardableResult
    static func save(enabled: Bool, url: String, token: String, deviceID: String? = nil, accessKey: String = "") throws -> Bool {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = (deviceID ?? SyncRelayClient.Access.parse(token)?.device ?? Self.deviceID).trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Self.token()
        let updated = try preparedConfiguration(existing: existing, deviceID: device,
            accessKey: accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            enrollment: token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !enabled || (SyncRelayClient.validURL(url) && SyncRelayClient.Access.parse(updated) != nil) else { throw NSError(domain: "SyncRelay", code: 4) }
        guard updated != existing || enabled != Self.enabled || url != Self.url || device != Self.deviceID else { return false }
        if updated != existing {
            let attributes = [kSecValueData as String: Data(updated.utf8)]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query; item[kSecValueData as String] = Data(updated.utf8)
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw NSError(domain: "SyncRelay", code: Int(status)) }
        }
        UserDefaults.standard.set(device, forKey: "syncRelayDeviceId")
        UserDefaults.standard.set(url, forKey: "syncRelayURL")
        UserDefaults.standard.set(enabled, forKey: "syncRelayEnabled")
        return true
    }
}

extension SyncManager {
    func restartRelayConfiguration() {
        syncQueue.async { [self] in
            relayConfigurationGeneration += 1
            relayClient?.stop(); relayClient = nil
            relayConnecting.removeAll()
            for (id, session) in sessions where session.host.hasPrefix("relay:") {
                closeSession(peerId: id, scheduleReconnect: false)
            }
            startRelay()
        }
    }

    /// Called on syncQueue; stopped with the ordinary synchronization lifetime.
    func startRelay() {
        guard relayClient == nil, SyncRelaySettings.enabled,
              SyncRelayClient.validURL(SyncRelaySettings.url),
              let url = URL(string: SyncRelaySettings.url) else { return }
        let token = SyncRelaySettings.token()
        guard token.utf8.count >= 32 else { return }
        let generation = currentGeneration
        let relayGeneration = relayConfigurationGeneration
        let client = SyncRelayClient(url: url, token: token, id: peerId, name: displayName,
            port: syncPort, addresses: Self.localIPv4Addresses()) { [weak self] peers in
            guard let self else { return }
            self.syncQueue.async { [self] in
                guard generation == self.currentGeneration && relayGeneration == self.relayConfigurationGeneration else { return }
                for peer in peers where self.sessions[peer.id] == nil && !self.relayConnecting.contains(peer.id) {
                    self.relayConnecting.insert(peer.id)
                    self.scanQueue.async {
                        // A small LAN probe precedes each relay fallback; never scan the Internet.
                        for host in peer.addresses.prefix(2) {
                            let octets = host.split(separator: ".").compactMap { Int($0) }
                            guard octets.count == 4, Self.isLanIPv4(a: octets[0], b: octets[1]) else { continue }
                            guard generation == self.currentGeneration && relayGeneration == self.relayConfigurationGeneration else { return }
                            if self.syncQueue.sync(execute: { self.sessions[peer.id] != nil }) { break }
                            self.dialOnScanQueue(host: host, port: peer.port, reason: "direct", peerId: peer.id, timeout: 0.8, stats: nil)
                        }
                        self.syncQueue.async { [self] in
                            guard generation == self.currentGeneration && relayGeneration == self.relayConfigurationGeneration else { return }
                            self.relayConnecting.remove(peer.id)
                            guard self.sessions[peer.id] == nil else { return }
                            self.relayClient?.open(peer: peer.id) { [weak self] fd in
                                guard let self else { Darwin.close(fd); return }
                                self.scanQueue.async {
                                    self.performHandshake(fd: fd, host: "relay:\(peer.id)", port: peer.port,
                                        inbound: self.peerId > peer.id, expectedPeerId: peer.id,
                                        expectedGeneration: generation)
                                }
                            }
                        }
                    }
                }
            }
        }
        client.onPeerAvailable = { [weak self] in
            self?.syncQueue.async { [weak self] in
                guard let self, generation == self.currentGeneration, relayGeneration == self.relayConfigurationGeneration else { return }
                self.probeNetworkSessions()
            }
        }
        relayClient = client; client.start()
    }
}
