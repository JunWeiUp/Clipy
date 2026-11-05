import Foundation

extension SyncManager {
    /// Called on syncQueue only after transport admission. Capture plaintext and
    /// small routing fields, not SyncEnvelope (which also owns base64 ciphertext).
    func dispatchInboundStore(type: String, text: String?, hash: String?, from peer: String,
                              ticket: SyncInboundBudget.Ticket) {
        let generation = sessions[peer]?.inboundGeneration ?? currentGeneration
        let work = { [weak self] in
            guard let self else { return }
            let current = self.syncQueue.sync {
                generation == self.currentGeneration && self.sessions[peer]?.inboundID == ticket.sessionID
            }
            if current {
                self.inboundNotificationAckHandler = { [weak self] hash, sender in
                    guard sender == peer else { return }
                    self?.syncQueue.async { [weak self] in
                        guard let self, generation == self.currentGeneration,
                              self.sessions[peer]?.inboundID == ticket.sessionID,
                              let data = self.encodeFrame(SyncEnvelope.make(type: SyncType.notifAck,
                                  peerId: self.peerId, hash: hash)),
                              let writer = self.sessions[peer]?.writer else { return }
                        _ = writer.enqueue(data)
                    }
                }
                defer { self.inboundNotificationAckHandler = nil }
                #if CLIPY_CORE_TESTS
                if let apply = self.inboundApplyForTesting { apply(type, text) }
                else { self.applyInboundStore(type: type, text: text, hash: hash, from: peer) }
                #else
                self.applyInboundStore(type: type, text: text, hash: hash, from: peer)
                #endif
            }
            self.syncQueue.async { [weak self] in
                guard let self else { return }
                // Persistence precedes ACK; a retired task cannot ACK a new session.
                if current, generation == self.currentGeneration,
                   self.sessions[peer]?.inboundID == ticket.sessionID,
                   type == SyncType.history || type == SyncType.historyDirect {
                    self.replyAck(to: peer, hash: hash)
                }
                if self.inboundBudget.release(ticket) { self.resumeInboundReaders() }
            }
        }
        #if CLIPY_CORE_TESTS
        if let dispatch = inboundMainDispatchForTesting { dispatch(work); return }
        #endif
        DispatchQueue.main.async(execute: work)
    }

    private func applyInboundStore(type: String, text: String?, hash: String?, from peer: String) {
        switch type {
        case SyncType.history, SyncType.historyDirect:
            ClipboardManager.shared.handleRemoteSync(content: text ?? "", hash: hash ?? "")
        case SyncType.notifPost:
            NotificationManager.shared.handleRemoteNotification(text ?? "", from: peer)
        case SyncType.notifDismiss:
            NotificationManager.shared.handleRemoteDismiss(text ?? "")
        case SyncType.notifClear:
            NotificationManager.shared.handleRemoteClearAll()
        default: break
        }
    }

    /// A denied frame stays in its original session buffer. Both LAN TCP and the
    /// relay's socketpair use this read source. RelayByteBridge already awaits its
    /// bounded writer before receiving another SDK record, propagating this pause.
    func pauseInboundReader(peerId: String) {
        guard var session = sessions[peerId], !session.readSuspended else { return }
        session.readSuspended = true
        sessions[peerId] = session
        session.readSource?.suspend()
    }

    /// Never resume recv before draining already buffered frames: no future socket
    /// event is guaranteed for a complete frame that is already in user memory.
    func resumeInboundReaders() {
        for peer in sessions.keys.sorted() {
            guard let paused = sessions[peer], paused.readSuspended else { continue }
            drainBuffer(peerId: peer)
            guard var session = sessions[peer], session.inboundID == paused.inboundID,
                  session.readSuspended else { continue }
            // drainBuffer leaves a complete frame intact only when admission fails.
            if session.buffer.count >= 4 {
                let length = session.buffer.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                if session.buffer.count >= 4 + length { continue }
            }
            session.readSuspended = false
            // Time spent intentionally paused is not a missing-pong failure.
            session.lastPong = Date()
            sessions[peer] = session
            session.readSource?.resume()
        }
    }
}
