import Foundation

/// Per-peer sync health counters for the diagnostics page. Written from
/// syncQueue / scanQueue / fileTransferQueue, read from the main thread, so
/// everything goes through one lock and readers get value snapshots.
final class SyncDiagnostics {
    struct PeerRecord {
        var peerId: String
        var name: String?
        var host: String?
        var sessionUpAt: Date?
        var sessionDownAt: Date?
        var lastSentAt: Date?
        var lastAckAt: Date?
        var lastReceivedAt: Date?
        var lastError: String?
        var lastErrorAt: Date?
    }

    private let lock = NSLock()
    private var records: [String: PeerRecord] = [:]

    private func update(_ peerId: String, _ body: (inout PeerRecord) -> Void) {
        guard !peerId.isEmpty else { return }
        lock.lock()
        var record = records[peerId] ?? PeerRecord(peerId: peerId)
        body(&record)
        records[peerId] = record
        lock.unlock()
    }

    func noteSessionUp(peerId: String, name: String, host: String) {
        update(peerId) {
            $0.name = name; $0.host = host; $0.sessionUpAt = Date()
            $0.lastError = nil; $0.lastErrorAt = nil
        }
    }

    func noteSessionDown(peerId: String) { update(peerId) { $0.sessionDownAt = Date() } }
    func noteSent(peerId: String) { update(peerId) { $0.lastSentAt = Date() } }
    func noteAck(peerId: String) { update(peerId) { $0.lastAckAt = Date() } }
    func noteReceived(peerId: String) { update(peerId) { $0.lastReceivedAt = Date() } }

    func noteError(peerId: String, name: String? = nil, host: String? = nil, _ message: String) {
        update(peerId) {
            if let name { $0.name = name }
            if let host { $0.host = host }
            $0.lastError = message; $0.lastErrorAt = Date()
        }
    }

    func snapshot() -> [String: PeerRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    func reset() {
        lock.lock(); records.removeAll(); lock.unlock()
    }
}

extension SyncManager {
    struct DiagnosticsRow: Identifiable {
        var id: String { record.peerId }
        var record: SyncDiagnostics.PeerRecord
        var displayName: String
        var isOnline: Bool
        var isAuthorized: Bool
        var pendingCount: Int
    }

    /// One row per peer that is authorized, online, has queued frames, or has
    /// recorded activity. Online first, then by name.
    func diagnosticsRows() -> [DiagnosticsRow] {
        var records = diagnostics.snapshot()
        let online = syncQueue.sync { Set(sessions.keys) }
        let pending = PendingSyncRepository.shared.pendingCounts()
        let authorized = Set(PreferencesManager.shared.authorizedPeerIds)
        for id in online.union(pending.keys).union(authorized) where records[id] == nil {
            records[id] = SyncDiagnostics.PeerRecord(peerId: id)
        }
        return records.values.map { record in
            DiagnosticsRow(
                record: record,
                displayName: record.name ?? resolvedPeerLabel(peerId: record.peerId),
                isOnline: online.contains(record.peerId),
                isAuthorized: authorized.contains(record.peerId),
                pendingCount: pending[record.peerId] ?? 0)
        }.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func notePairingMismatch(peerId: String, name: String?, host: String) {
        diagnostics.noteError(peerId: peerId, name: name, host: host, "pairingMismatch")
    }
}
