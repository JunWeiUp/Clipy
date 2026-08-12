import Foundation

extension SyncManager {
    func clipboardAuthIds() -> Set<String> { Set(PreferencesManager.shared.clipboardSyncPeerIds) }
    func notificationAuthIds() -> Set<String> { Set(PreferencesManager.shared.notificationSyncPeerIds) }

    func authIds(for env: SyncEnvelope) -> Set<String> {
        switch env.type {
        case SyncType.history: return clipboardAuthIds()
        case SyncType.notifPost, SyncType.notifDismiss, SyncType.notifClear, SyncType.notifConfig: return notificationAuthIds()
        default: return Set(PreferencesManager.shared.authorizedPeerIds)
        }
    }

    func isQueueableSyncType(_ type: String) -> Bool {
        type == SyncType.history || type == SyncType.historyDirect || type == SyncType.notifPost
    }

    func fanoutReliable(_ env: SyncEnvelope, requireAuth: Bool, allowWithoutClipboardSync: Bool = false) {
        if !allowWithoutClipboardSync && !PreferencesManager.shared.isSyncEnabled { return }
        guard let data = encodeFrame(env) else { return }
        let auth = authIds(for: env)
        peersLock.lock(); let discovered = Set(discoveredPeers.keys); peersLock.unlock()
        let targets = requireAuth ? Array(auth) : Array(discovered)
        guard !targets.isEmpty else {
            if env.type == SyncType.history {
                appLog("history frame not delivered: no authorized clipboard sync target — enable clipboard sync for the target device in Settings", level: .warning)
            }
            scheduleDiscovery(immediate: false, scanFullSubnet: false)
            return
        }
        let queueable = isQueueableSyncType(env.type)
        syncQueue.async { [weak self] in
            guard let self else { return }
            var needsDiscovery = false
            for id in targets {
                let hasSession = self.sessions[id] != nil, isDiscovered = discovered.contains(id)
                if hasSession || isDiscovered {
                    let delivered = self.deliver(data: data, type: env.type, peerId: id, hash: env.hash, reliable: true)
                    appLog("fanout \(env.type) to \(id.prefix(8)): \(hasSession ? "session" : "discovered") deliver=\(delivered)")
                    if queueable && delivered { self.enqueuePending(data: data, type: env.type, peerId: id, hash: env.hash) }
                } else if queueable {
                    self.enqueuePending(data: data, type: env.type, peerId: id, hash: env.hash)
                    appLog("fanout \(env.type) to \(id.prefix(8)): queued (peer not reachable)")
                    needsDiscovery = true
                }
            }
            if needsDiscovery { self.scheduleDiscovery(immediate: false, scanFullSubnet: false) }
        }
    }

    func sendEnvelope(_ env: SyncEnvelope, to targetId: String, reliable: Bool, dialReason: String = "deliver", completion: ((Bool) -> Void)? = nil) {
        guard let data = encodeFrame(env) else { completion?(false); return }
        syncQueue.async { [weak self] in
            guard let self else { if let completion { DispatchQueue.main.async { completion(false) } }; return }
            let delivered = self.deliver(data: data, type: env.type, peerId: targetId, hash: env.hash, reliable: reliable, dialReason: dialReason)
            if let completion { DispatchQueue.main.async { completion(delivered) } }
        }
    }

    @discardableResult func deliver(data: Data, type: String, peerId: String, hash: String?, reliable: Bool, dialReason: String = "deliver") -> Bool {
        if let session = sessions[peerId], writeAll(session.fd, data) { return true }
        if reliable { enqueuePending(data: data, type: type, peerId: peerId, hash: hash) }
        let reason = (type == SyncType.historyDirect) ? "direct" : dialReason
        if let peer = peerSnapshot(peerId) {
            dial(host: peer.host, port: peer.port, reason: reason, peerId: peerId)
        } else if let cached = cachedEndpoint(for: peerId) {
            dial(host: cached.host, port: cached.port, reason: reason, peerId: peerId)
        } else {
            scheduleDiscovery(immediate: false, scanFullSubnet: false)
        }
        scheduleReconnect(peerId: peerId)
        return false
    }

    func enqueuePending(data: Data, type: String, peerId: String, hash: String?) {
        guard let hash, !hash.isEmpty else { return }
        PendingSyncRepository.shared.enqueue(peerId: peerId, hash: hash, type: type, data: data, ttl: Self.pendingQueueTTL, maxPerPeer: Self.pendingQueueMax)
    }

    func flushPending(for peerId: String) {
        let allowClipboard = clipboardAuthIds().contains(peerId), allowNotification = notificationAuthIds().contains(peerId)
        guard let session = sessions[peerId] else { return }
        let due = PendingSyncRepository.shared.fetchDue(forPeer: peerId, ttl: Self.pendingQueueTTL).filter {
            switch $0.type {
            case SyncType.history: return allowClipboard
            case SyncType.historyDirect: return true // device-list send: no auth
            case SyncType.notifPost, SyncType.notifDismiss, SyncType.notifClear, SyncType.notifConfig: return allowNotification
            default: return true
            }
        }
        guard !due.isEmpty else { return }
        let dropped = due.filter { isQueueableSyncType($0.type) && (inFlightHashes[peerId]?.contains($0.hash) ?? false) }.count
        appLog("Flushing \(due.count) pending frame(s) to \(peerId)\(dropped > 0 ? " (skipped \(dropped) in-flight)" : "")")
        for frame in due {
            let needsAck = isQueueableSyncType(frame.type)
            if needsAck, inFlightHashes[peerId]?.contains(frame.hash) ?? false { continue }
            if writeAll(session.fd, frame.data) {
                if needsAck { if inFlightHashes[peerId] == nil { inFlightHashes[peerId] = [] }; inFlightHashes[peerId]?.insert(frame.hash) }
                else { PendingSyncRepository.shared.remove(peerId: peerId, hash: frame.hash) }
            } else { appLog("flushPending \(frame.type) send failed to \(peerId.prefix(8)); frame retained", level: .warning) }
        }
    }

    /// True when peer has a queued device-list direct send (reconnect may dial without auth).
    func hasDirectPending(for peerId: String) -> Bool {
        PendingSyncRepository.shared.fetchDue(forPeer: peerId, ttl: Self.pendingQueueTTL)
            .contains { $0.type == SyncType.historyDirect }
    }

    func refreshPendingDelivery(for peerId: String) {
        syncQueue.async { [weak self] in self?.flushPending(for: peerId) }
    }

    func handleAck(hash: String, from remotePeerId: String) {
        guard !hash.isEmpty, !remotePeerId.isEmpty else { return }
        let removed = PendingSyncRepository.shared.remove(peerId: remotePeerId, hash: hash)
        // history.fetch replay is not enqueued — ACKs for those are no-ops; only
        // log when a real outbound pending row was cleared.
        if removed {
            appLog("ACK from \(remotePeerId.prefix(8)) cleared pending for hash \(hash.prefix(8))")
        }
        inFlightHashes[remotePeerId]?.remove(hash)
    }

    func replyAck(to peerId: String, hash: String?) {
        guard let hash, !hash.isEmpty else { return }
        let env = SyncEnvelope.make(type: SyncType.ack, peerId: self.peerId, hash: hash)
        guard let data = encodeFrame(env), let fd = sessions[peerId]?.fd, !writeAll(fd, data) else { return }
        appLog("ack send failed to \(peerId.prefix(8))", level: .warning)
    }

    func scheduleReconnect(peerId: String) {
        guard PreferencesManager.shared.isSyncEnabled, pendingReconnects[peerId] == nil else { return }
        let now = Date()
        if let last = lastReconnectAttempt[peerId], now.timeIntervalSince(last) < Self.minReconnectInterval { return }
        lastReconnectAttempt[peerId] = now
        let delay = reconnectBackoffs[peerId] ?? 1
        reconnectBackoffs[peerId] = min(delay * 2, Self.maxReconnectBackoff)
        appLog("Reconnect scheduled for \(peerId.prefix(8)) in \(Int(delay))s (next backoff \(Int(min(delay * 2, Self.maxReconnectBackoff)))s)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReconnects.removeValue(forKey: peerId)
            guard self.sessions[peerId] == nil else { return }
            let reason = self.hasDirectPending(for: peerId) ? "direct" : "reconnect"
            if let peer = self.peerSnapshot(peerId) {
                self.dial(host: peer.host, port: peer.port, reason: reason, peerId: peerId)
            } else if let cached = self.cachedEndpoint(for: peerId) {
                self.dial(host: cached.host, port: cached.port, reason: reason, peerId: peerId)
            } else {
                self.scheduleDiscovery(immediate: false, scanFullSubnet: false)
            }
        }
        pendingReconnects[peerId] = work
        syncQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func retryStalePendingHistory(for peerId: String) {
        let due = PendingSyncRepository.shared.fetchDue(forPeer: peerId, ttl: Self.pendingQueueTTL)
        let cutoff = Date().addingTimeInterval(-Self.pendingAckRetryAge)
        let stale = due.filter {
            ($0.type == SyncType.history || $0.type == SyncType.historyDirect) && $0.enqueueAt <= cutoff
        }
        guard !stale.isEmpty else { return }
        for frame in stale { inFlightHashes[peerId]?.remove(frame.hash) }
        appLog("Retrying \(stale.count) stale pending history frame(s) to \(peerId.prefix(8)) (no ACK ≥\(Int(Self.pendingAckRetryAge))s)")
        flushPending(for: peerId)
    }
}
