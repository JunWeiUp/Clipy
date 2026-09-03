import Foundation
import Darwin
import Network

extension SyncManager {
    enum ConnectFailure: Hashable {
        case timeout, refused, unreachable, other
        init(errno err: Int32) {
            switch err {
            case ECONNREFUSED: self = .refused
            case EHOSTUNREACH, ENETUNREACH: self = .unreachable
            default: self = .other
            }
        }
        init(soError err: Int32) { self.init(errno: err) }
        var label: String {
            switch self {
            case .timeout: return "timeout"
            case .refused: return "refused"
            case .unreachable: return "unreachable"
            case .other: return "other"
            }
        }
    }

    enum HandshakeFailure {
        case writeFail, readTimeout, versionMismatch, selfHandshake, badType
        var label: String {
            switch self {
            case .writeFail: return "writeFail"
            case .readTimeout: return "readTimeout"
            case .versionMismatch: return "versionMismatch"
            case .selfHandshake: return "selfHandshake"
            case .badType: return "badType"
            }
        }
    }

    final class ScanStats {
        private let lock = NSLock()
        private var attempted = 0
        private var connectOk = 0
        private var connectFail: [ConnectFailure: Int] = [:]
        private var handshakeFail: [HandshakeFailure: Int] = [:]
        func recordAttempt() { lock.lock(); defer { lock.unlock() }; attempted += 1 }
        func recordConnectOk() { lock.lock(); defer { lock.unlock() }; connectOk += 1 }
        func recordConnectFailure(_ failure: ConnectFailure) { lock.lock(); defer { lock.unlock() }; connectFail[failure, default: 0] += 1 }
        func recordHandshakeFailure(_ failure: HandshakeFailure) { lock.lock(); defer { lock.unlock() }; handshakeFail[failure, default: 0] += 1 }
        func summary() -> String {
            lock.lock(); defer { lock.unlock() }
            let handshakeFailureTotal = handshakeFail.values.reduce(0, +)
            let connectFailures = connectFail.sorted { $0.key.label < $1.key.label }.map { "\($0.key.label)=\($0.value)" }.joined(separator: ",")
            let handshakeFailures = handshakeFail.sorted { $0.key.label < $1.key.label }.map { "\($0.key.label)=\($0.value)" }.joined(separator: ",")
            return "attempted=\(attempted) connect_ok=\(connectOk) handshake_ok=\(max(connectOk - handshakeFailureTotal, 0)) | connect_fail{\(connectFailures)} handshake_fail{\(handshakeFailures)}"
        }
    }

    var currentGeneration: Int {
        scanStateLock.lock()
        defer { scanStateLock.unlock() }
        return serviceGeneration
    }

    func dial(host: String, port: UInt16, reason: String, peerId: String? = nil, timeout: TimeInterval = SyncManager.connectTimeout) {
        scanQueue.async { [weak self] in
            self?.dialOnScanQueue(host: host, port: port, reason: reason, peerId: peerId, timeout: timeout, stats: nil)
        }
    }

    /// Non-`scan`/`direct` dials require an authorized peerId (clipboard ∪ notification).
    /// `direct` = device-list one-shot send (text/file); no mutual auth.
    func allowsProactiveDial(reason: String, peerId: String?) -> Bool {
        if reason == "scan" || reason == "direct" { return true }
        guard let peerId, !peerId.isEmpty else { return false }
        return Set(PreferencesManager.shared.authorizedPeerIds).contains(peerId)
    }

    func resolvePeerId(host: String, port: UInt16) -> String? {
        if let id = syncQueue.sync(execute: { sessions.first(where: { $0.value.host == host })?.key }) {
            return id
        }
        peersLock.lock()
        let fromMemory = discoveredPeers.values.first(where: { $0.host == host && $0.port == port })?.peerId
        peersLock.unlock()
        if let fromMemory { return fromMemory }
        return loadEndpointCacheEntries().first(where: { $0.host == host && $0.port == port })?.peerId
    }

    func dialOnScanQueue(host: String, port: UInt16, reason: String, peerId: String? = nil, timeout: TimeInterval, stats: ScanStats?) {
        let resolvedPeerId = peerId ?? (reason == "scan" ? nil : resolvePeerId(host: host, port: port))
        if !allowsProactiveDial(reason: reason, peerId: resolvedPeerId) {
            return
        }
        let key = "\(host):\(port)", now = Date()
        dialDedupLock.lock()
        if let last = lastDialAt[key], now.timeIntervalSince(last) < dialDedupTTL, reason == "scan" {
            dialDedupLock.unlock()
            return
        }
        lastDialAt[key] = now
        dialDedupLock.unlock()
        if syncQueue.sync(execute: { sessions.values.contains { $0.host == host } }) { return }

        if reason == "scan" { stats?.recordAttempt() }
        var failure: ConnectFailure?
        guard let fd = tcpConnectDiag(host: host, port: port, timeout: timeout, failure: &failure) else {
            if reason == "scan" { stats?.recordConnectFailure(failure ?? .other) }
            else {
                appLog("Dial \(reason) \(host):\(port) failed: connect(\(failure?.label ?? "unknown"))", level: .warning)
                // A dead authorized endpoint is the auto-rediscover signal;
                // scan/direct dials have no stable peer identity to count against.
                if let resolvedPeerId { noteAuthorizedDialFailure(peerId: resolvedPeerId) }
            }
            return
        }
        if reason == "scan" { stats?.recordConnectOk() }
        performHandshake(fd: fd, host: host, port: port, inbound: false) { handshakeFailure in
            if reason == "scan" { stats?.recordHandshakeFailure(handshakeFailure) }
            else { appLog("Dial \(reason) \(host):\(port) failed: handshake(\(handshakeFailure.label))", level: .warning) }
        }
    }

    func performHandshake(fd: Int32, host: String, port: UInt16, inbound: Bool, onFailure: ((HandshakeFailure) -> Void)? = nil) {
        let generation = currentGeneration
        let hello = SyncEnvelope.make(type: SyncType.hello, peerId: peerId, name: displayName, port: Int(syncPort))
        guard let helloData = encodeFrame(hello), writeAll(fd, helloData) else {
            onFailure?(.writeFail); Darwin.close(fd); return
        }
        guard let frame = readOneFrame(fd: fd, timeout: Self.handshakeTimeout), let env = decodeEnvelope(frame) else {
            onFailure?(.readTimeout); Darwin.close(fd); return
        }
        guard env.v == SyncEnvelope.version else { onFailure?(.versionMismatch); Darwin.close(fd); return }
        if inbound, env.type == SyncType.hello {
            guard env.peerId != peerId, !env.peerId.isEmpty else { onFailure?(.selfHandshake); Darwin.close(fd); return }
            let welcome = SyncEnvelope.make(type: SyncType.welcome, peerId: peerId, name: displayName, port: Int(syncPort))
            if let data = encodeFrame(welcome), !writeAll(fd, data) { appLog("welcome send failed (inbound) to \(env.peerId.prefix(8))", level: .warning) }
            adoptSession(peerId: env.peerId, name: env.name ?? env.peerId, host: host, port: UInt16(env.port ?? Int(port)), fd: fd, generation: generation)
            return
        }
        guard env.type == SyncType.welcome || env.type == SyncType.hello, env.peerId != peerId, !env.peerId.isEmpty else {
            onFailure?(env.peerId == peerId ? .selfHandshake : .badType); Darwin.close(fd); return
        }
        if env.type == SyncType.hello {
            let welcome = SyncEnvelope.make(type: SyncType.welcome, peerId: peerId, name: displayName, port: Int(syncPort))
            if let data = encodeFrame(welcome), !writeAll(fd, data) { appLog("welcome send failed (outbound) to \(env.peerId.prefix(8))", level: .warning) }
        }
        adoptSession(peerId: env.peerId, name: env.name ?? env.peerId, host: host, port: UInt16(env.port ?? Int(port)), fd: fd, generation: generation)
    }

    func adoptSession(peerId: String, name: String, host: String, port: UInt16, fd: Int32, generation: Int) {
        syncQueue.async { [weak self] in
            guard let self else { Darwin.close(fd); return }
            guard generation == self.currentGeneration else { Darwin.close(fd); return }
            if let existing = self.sessions[peerId] {
                appLog("Replacing session for \(peerId.prefix(8)) (existing last pong \(Int(Date().timeIntervalSince(existing.lastPong)))s ago)")
                self.closeSession(peerId: peerId, scheduleReconnect: false)
            }
            if let client = self.acceptingClients.removeValue(forKey: fd) { client.source.cancel() }
            // A recycled fd number may still sit in retiredFDs from its previous
            // life; the new incarnation is live again.
            retiredFDs.remove(fd)
            var session = Session(peerId: peerId, host: host, port: port, fd: fd, isClient: self.peerId < peerId)
            setNonBlocking(fd)
            // Chunked file transfer writes single frames up to ~1.4MB; make sure
            // the kernel buffers can absorb several of them so a blocking
            // send()/recv() can't wedge syncQueue while the peer drains.
            var sendBuffer = Int32(SyncManager.fileSendBufferSize)
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout.size(ofValue: sendBuffer)))
            var recvBuffer = Int32(SyncManager.fileSendBufferSize)
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &recvBuffer, socklen_t(MemoryLayout.size(ofValue: recvBuffer)))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.syncQueue)
            source.setEventHandler { [weak self] in self?.onSessionReadable(peerId: peerId) }
            session.readSource = source
            self.sessions[peerId] = session
            source.resume()
            self.reconnectBackoffs[peerId] = 1
            self.pendingReconnects.removeValue(forKey: peerId)?.cancel()
            self.noteSessionEstablished()
            self.recordPeer(peerId: peerId, name: name, host: host, port: port)
            self.persistEndpoint(peerId: peerId, name: name, host: host, port: port)
            self.flushPending(for: peerId)
            appLog("Session up with \(name) (\(peerId.prefix(8))) @ \(host):\(port)")
        }
    }

    func recordPeer(peerId: String, name: String, host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5566)
        let peer = DiscoveredPeer(peerId: peerId, displayName: name, endpoint: endpoint, host: host, port: port)
        peersLock.lock(); discoveredPeers[peerId] = peer; let peers = Array(discoveredPeers.values); peersLock.unlock()
        PreferencesManager.shared.migrateAuthorizedPeerIds(from: peers)
        notifyPeersChanged()
    }

    func onSessionReadable(peerId: String) {
        guard var session = sessions[peerId] else { return }
        if receiveScratch.count < 262144 { receiveScratch = Data(count: 262144) }
        // Drain everything available in one event: chunked file transfers push
        // multi-megabyte back-to-back frames, and one 64KB recv per event
        // multiplies scheduler round-trips for nothing.
        while true {
            let count = receiveScratch.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(session.fd, base, raw.count, 0)
            }
            if count > 0 {
                session.buffer.append(receiveScratch.prefix(count))
                sessions[peerId] = session
                drainBuffer(peerId: peerId)
                guard let current = sessions[peerId] else { return }
                session = current
                continue
            }
            if count == 0 {
                appLog("recv EOF from \(peerId.prefix(8))")
                closeSession(peerId: peerId, scheduleReconnect: true, keepaliveDriven: true)
            } else if errno != EAGAIN {
                appLog("recv error errno=\(errno) from \(peerId.prefix(8))")
                closeSession(peerId: peerId, scheduleReconnect: true, keepaliveDriven: true)
            }
            return
        }
    }

    func drainBuffer(peerId: String) {
        guard var session = sessions[peerId] else { return }
        while true {
            guard session.buffer.count >= 4 else { sessions[peerId] = session; return }
            let length = session.buffer.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length > 0, length <= Self.maxFrameLength else { closeSession(peerId: peerId, scheduleReconnect: true, keepaliveDriven: true); return }
            guard session.buffer.count >= 4 + length else { sessions[peerId] = session; return }
            let frame = session.buffer.subdata(in: 4..<(4 + length))
            if session.buffer.count == 4 + length { session.buffer = Data() } else { session.buffer.removeSubrange(0..<(4 + length)) }
            sessions[peerId] = session
            handleFrame(frame, from: peerId, host: session.host)
            guard let current = sessions[peerId] else { return }
            session = current
        }
    }

    func closeSession(peerId: String, scheduleReconnect: Bool, keepaliveDriven: Bool = false) {
        guard let session = sessions.removeValue(forKey: peerId) else { return }
        session.readSource?.cancel()
        retiredFDs.insert(session.fd)
        Darwin.close(session.fd)
        inFlightHashes.removeValue(forKey: peerId)
        // Mid-transfer file chunks will never arrive on this socket again.
        discardIncomingFiles(from: peerId)
        appLog("Session closed with \(peerId.prefix(8))")
        guard scheduleReconnect, !(keepaliveDriven && !session.isClient) else { return }
        self.scheduleReconnect(peerId: peerId)
    }

    func startListening() {
        stopListening()
        let port = syncPort, fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { appLog("Failed to create listen socket", level: .error); return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bindResult == 0, Darwin.listen(fd, 32) == 0 else { appLog("Failed to bind/listen on \(port): \(errno)", level: .error); Darwin.close(fd); return }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: syncQueue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [weak self] in if let self, self.listenFD >= 0 { Darwin.close(self.listenFD); self.listenFD = -1 } }
        listenSource = source; source.resume()
        appLog("Listening on 0.0.0.0:\(port)")
    }

    func stopListening() {
        listenSource?.cancel(); listenSource = nil
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
    }

    func acceptClient() {
        var addr = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &length) } }
        guard clientFD >= 0 else { return }
        var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); inet_ntop(AF_INET, &addr.sin_addr, &hostBuffer, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: hostBuffer)
        setNonBlocking(clientFD)
        appLog("Inbound connection from \(host)")
        scanQueue.async { [weak self] in
            guard let self else { Darwin.close(clientFD); return }
            self.performHandshake(fd: clientFD, host: host, port: self.syncPort, inbound: true) { appLog("Inbound handshake failed from \(host): \($0.label)", level: .warning) }
        }
    }

    func tcpConnectDiag(host: String, port: UInt16, timeout: TimeInterval, failure: inout ConnectFailure?) -> Int32? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { failure = .other; return nil }
        let flags = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { failure = .other; Darwin.close(fd); return nil }
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result == 0 { setTCPNoDelay(fd); return fd }
        guard errno == EINPROGRESS else { failure = ConnectFailure(errno: errno); Darwin.close(fd); return nil }
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFD, 1, Int32(timeout * 1000)) > 0 else { failure = .timeout; Darwin.close(fd); return nil }
        var error: Int32 = 0; var errorLength = socklen_t(MemoryLayout<Int32>.size); getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorLength)
        guard error == 0 else { failure = ConnectFailure(soError: error); Darwin.close(fd); return nil }
        setTCPNoDelay(fd); setKeepalive(fd); return fd
    }

    func setTCPNoDelay(_ fd: Int32) { var value: Int32 = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, socklen_t(MemoryLayout.size(ofValue: value))) }
    func setKeepalive(_ fd: Int32) { var value: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &value, socklen_t(MemoryLayout.size(ofValue: value))) }

    /// Session sockets stay non-blocking: the read loop drains until EAGAIN
    /// and writes poll for room. A blocking socket would wedge the serial
    /// syncQueue forever the moment a peer stalls (one dead recv stalled
    /// accepts/pings/everything — the "device unreachable" bug).
    func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Non-blocking send + poll(POLLOUT) with a total deadline. macOS has no
    /// SO_SNDTIMEO for TCP; a plain blocking send() on a stalled peer would
    /// freeze syncQueue (and thus every session + the listener).
    @discardableResult func writeAll(_ fd: Int32, _ data: Data, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base + sent, raw.count - sent, 0)
                if count > 0 { sent += count; continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let remain = deadline.timeIntervalSinceNow
                    guard remain > 0, poll(&pollFD, 1, Int32(remain * 1000)) > 0 else { return false }
                    continue
                }
                return false
            }
            return true
        }
    }

    func readOneFrame(fd: Int32, timeout: TimeInterval, maxLength: Int = SyncManager.maxHandshakeFrameLength) -> Data? {
        var buffer = Data(), scratch = Data(count: 16384); let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if buffer.count >= 4 {
                let length = buffer.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard length > 0, length <= maxLength else { return nil }
                if buffer.count >= 4 + length { return buffer.subdata(in: 4..<(4 + length)) }
            }
            guard buffer.count <= 4 + maxLength else { return nil }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remain = deadline.timeIntervalSinceNow
            guard remain > 0, poll(&pollFD, 1, Int32(remain * 1000)) > 0 else { return nil }
            let count = scratch.withUnsafeMutableBytes { raw -> Int in guard let base = raw.baseAddress else { return -1 }; return Darwin.recv(fd, base, raw.count, 0) }
            // Non-blocking fd: a spurious wakeup can leave nothing to read.
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else { return nil }; buffer.append(scratch.prefix(count))
        }
        return nil
    }
}
