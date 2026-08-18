import Foundation
import Network

extension SyncManager {
    /// - Parameter scanFullSubnet: only user refresh / explicit scan may dial every /24 host.
    func scheduleDiscovery(immediate: Bool, scanFullSubnet: Bool = false) {
        pendingDiscoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runDiscovery(force: immediate, scanFullSubnet: scanFullSubnet)
        }
        pendingDiscoveryWork = work
        let delay = immediate ? 0.05 : Self.discoveryDebounce
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    func beginSubnetScan(force: Bool) -> Bool {
        scanStateLock.lock()
        defer { scanStateLock.unlock() }
        if isScanning { return false }
        if !force, let last = lastScanFinishedAt,
           Date().timeIntervalSince(last) < Self.subnetScanCooldown {
            return false
        }
        isScanning = true
        return true
    }

    func endSubnetScan() {
        scanStateLock.lock()
        isScanning = false
        lastScanFinishedAt = Date()
        scanStateLock.unlock()
    }

    func runDiscovery(force: Bool, scanFullSubnet: Bool = false) {
        guard PreferencesManager.shared.isSyncEnabled else { return }
        let port = syncPort
        let myIPs = Set(Self.localIPv4Addresses())
        let myPeerId = peerId
        let auth = Set(PreferencesManager.shared.authorizedPeerIds)
        appLog(Self.diagnoseInterfaces())

        // Proactive cache dial: authorized peers only (gate also in dialOnScanQueue).
        for entry in loadEndpointCacheEntries() where entry.peerId != myPeerId {
            guard auth.contains(entry.peerId) else { continue }
            dial(host: entry.host, port: entry.port, reason: "cache", peerId: entry.peerId)
        }

        // Manual IPs: only dial when host maps to an authorized peer (else wait for scan).
        let manual = PreferencesManager.shared.manualSyncPeers
        for entry in manual {
            let parts = entry.split(separator: ":")
            guard let host = parts.first.map(String.init), !host.isEmpty else { continue }
            let p = parts.count >= 2 ? UInt16(parts[1]) ?? port : port
            guard let peerId = resolvePeerId(host: host, port: p), auth.contains(peerId) else { continue }
            dial(host: host, port: p, reason: "manual", peerId: peerId)
        }

        guard scanFullSubnet else { return }
        guard beginSubnetScan(force: force) else { return }
        defer { endSubnetScan() }
        var candidates: [String] = []
        var subnets = Set<String>()
        for ip in myIPs {
            let parts = ip.split(separator: ".").map(String.init)
            guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]),
                  Self.isLanIPv4(a: a, b: b) else { continue }
            subnets.insert("\(a).\(b).\(c).0/24")
            for d in 1...254 {
                let candidate = "\(a).\(b).\(c).\(d)"
                if !myIPs.contains(candidate) { candidates.append(candidate) }
            }
        }
        candidates = Array(Set(candidates)).sorted()
        let connectedHosts: Set<String> = syncQueue.sync { Set(sessions.values.map(\.host)) }
        let toScan = candidates.filter { !connectedHosts.contains($0) }
        let subnetList = subnets.isEmpty ? "<none>" : subnets.sorted().joined(separator: ", ")
        appLog("Subnet scan: \(toScan.count) hosts on :\(port) (subnets: \(subnetList))")

        let stats = ScanStats()
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: Self.scanConcurrency)
        for host in toScan {
            group.enter()
            semaphore.wait()
            scanQueue.async {
                defer { semaphore.signal(); group.leave() }
                self.dialOnScanQueue(host: host, port: port, reason: "scan", timeout: Self.scanConnectTimeout, stats: stats)
            }
        }
        _ = group.wait(timeout: .now() + 20)
        appLog("Subnet scan finished: \(stats.summary())")
        pruneStaleDialTimestamps()
    }

    func peerSnapshot(_ id: String) -> DiscoveredPeer? {
        peersLock.lock()
        defer { peersLock.unlock() }
        return discoveredPeers[id]
    }

    struct CachedEndpoint: Codable {
        let peerId: String
        let name: String
        let host: String
        let port: UInt16
        let ts: TimeInterval
    }

    func persistEndpoint(peerId: String, name: String, host: String, port: UInt16) {
        var entries = loadEndpointCacheEntries()
        entries.removeAll { $0.peerId == peerId }
        entries.append(CachedEndpoint(peerId: peerId, name: name, host: host, port: port, ts: Date().timeIntervalSince1970))
        writeEndpointCacheEntries(entries)
    }

    /// After user refresh: keep live sessions + authorized peers still in cache (drop unauthorized ghosts).
    func rewriteEndpointCacheAfterRefresh(livePeers: [DiscoveredPeer]) {
        let auth = Set(PreferencesManager.shared.authorizedPeerIds)
        let previous = Dictionary(uniqueKeysWithValues: loadEndpointCacheEntries().map { ($0.peerId, $0) })
        let now = Date().timeIntervalSince1970
        var entries: [CachedEndpoint] = livePeers.map {
            CachedEndpoint(peerId: $0.peerId, name: $0.displayName, host: $0.host, port: $0.port, ts: now)
        }
        let liveIds = Set(livePeers.map(\.peerId))
        for (id, entry) in previous where auth.contains(id) && !liveIds.contains(id) {
            entries.append(entry)
        }
        writeEndpointCacheEntries(entries)
        appLog("endpoint cache pruned to \(entries.count) peer(s) after refresh (live+authorized)")
    }

    func writeEndpointCacheEntries(_ entries: [CachedEndpoint]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.endpointCacheKey)
        } else if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.endpointCacheKey)
        }
    }

    func loadEndpointCacheEntries() -> [CachedEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: Self.endpointCacheKey),
              let decoded = try? JSONDecoder().decode([CachedEndpoint].self, from: data) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - Self.endpointCacheTTL
        return decoded.filter { $0.ts >= cutoff }
    }

    func cachedEndpoint(for peerId: String) -> CachedEndpoint? {
        loadEndpointCacheEntries().first { $0.peerId == peerId }
    }

    /// Display name for settings / offline authorized rows.
    func resolvedPeerLabel(peerId: String) -> String {
        if let peer = peerSnapshot(peerId) { return peer.displayName }
        if let cached = cachedEndpoint(for: peerId), !cached.name.isEmpty { return cached.name }
        return String(peerId.prefix(8))
    }

    func resolvedPeerHostPort(peerId: String) -> String? {
        if let peer = peerSnapshot(peerId) { return "\(peer.host):\(peer.port)" }
        if let cached = cachedEndpoint(for: peerId) { return "\(cached.host):\(cached.port)" }
        return nil
    }

    /// Dial cached endpoints for authorized peers only; list after handshake.
    func loadEndpointCache() {
        let auth = Set(PreferencesManager.shared.authorizedPeerIds)
        for entry in loadEndpointCacheEntries() where entry.peerId != peerId {
            guard auth.contains(entry.peerId) else { continue }
            dial(host: entry.host, port: entry.port, reason: "cache", peerId: entry.peerId)
        }
    }

    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var addr = p.pointee.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(&addr, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, isLanIPv4(a: parts[0], b: parts[1]) else { continue }
            result.append(ip)
        }
        return Array(Set(result)).sorted()
    }

    static func diagnoseInterfaces() -> String {
        var parts: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "Discovery local interfaces: <getifaddrs failed>" }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let ifName = p.pointee.ifa_name.map { String(cString: $0) } ?? "?"
            var addr = p.pointee.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(&addr, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            let isLan = octets.count == 4 && isLanIPv4(a: octets[0], b: octets[1])
            parts.append("\(ifName)=\(ip)[\(isLan ? "LAN" : "ignored")]")
        }
        return parts.isEmpty ? "Discovery local interfaces: <none>" : "Discovery local interfaces: " + parts.joined(separator: ", ")
    }

    static func isLanIPv4(a: Int, b: Int) -> Bool {
        a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) || (a == 169 && b == 254)
    }
}
