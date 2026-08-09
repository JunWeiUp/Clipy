import Foundation
import SQLite3

/// On-disk delivery queue for sync frames awaiting ACK.
///
/// The history (and notif.post) frames a peer has not yet ACKed are persisted
/// here so they survive a Mac restart/crash. Previously they lived only in an
/// in-memory array (`SyncManager.pendingQueue`), which meant any content copied
/// just before a quit was lost forever. Mirrors the Android
/// `pending_text_sync` table for symmetry.
///
/// All access is serialized on `AppDatabase.shared.queue`.
final class PendingSyncRepository {
    static let shared = PendingSyncRepository()

    private var db: OpaquePointer? { AppDatabase.shared.db }
    private var queue: DispatchQueue { AppDatabase.shared.queue }

    private init() {}

    struct PendingFrame {
        let peerId: String
        let hash: String
        let type: String
        let data: Data
        let enqueueAt: Date
    }

    // MARK: - Write

    /// Insert (or replace) a pending frame for a peer. Same (peerId, hash) is
    /// upserted via the PRIMARY KEY so a redelivery attempt doesn't duplicate.
    /// Returns false if the per-peer cap would be exceeded.
    @discardableResult
    func enqueue(
        peerId: String,
        hash: String,
        type: String,
        data: Data,
        enqueueAt: Date = Date(),
        ttl: TimeInterval,
        maxPerPeer: Int
    ) -> Bool {
        queue.sync {
            guard let db else { return false }
            // Opportunistic TTL sweep: drop frames older than the cutoff.
            let cutoff = Date().addingTimeInterval(-ttl).timeIntervalSince1970
            sqliteExec(db, "DELETE FROM pending_sync WHERE enqueue_at < \(cutoff)",
                       context: "pending_sync TTL sweep")

            // Per-peer cap: avoid unbounded growth if a peer never ACKs.
            let count = peerCountLocked(peerId)
            if count >= maxPerPeer { return false }

            var stmt: OpaquePointer?
            let sql = """
            INSERT OR REPLACE INTO pending_sync (peer_id, hash, type, data, enqueue_at)
            VALUES (?, ?, ?, ?, ?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqliteLogFailure(db, "pending_sync enqueue prepare")
                return false
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, peerId)
            bindText(stmt, 2, hash)
            bindText(stmt, 3, type)
            data.withUnsafeBytes { rawBuffer in
                let rawPtr = rawBuffer.baseAddress
                sqlite3_bind_blob(stmt, 4, rawPtr, Int32(data.count), sqliteTransient)
            }
            sqlite3_bind_double(stmt, 5, enqueueAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqliteLogFailure(db, "pending_sync enqueue step")
                return false
            }
            return true
        }
    }

    // MARK: - Read

    /// All due (non-expired) pending frames for a peer, oldest first.
    func fetchDue(forPeer peerId: String, ttl: TimeInterval) -> [PendingFrame] {
        queue.sync {
            guard let db else { return [] }
            let cutoff = Date().addingTimeInterval(-ttl).timeIntervalSince1970
            let sql = """
            SELECT peer_id, hash, type, data, enqueue_at FROM pending_sync
            WHERE peer_id = ? AND enqueue_at >= ?
            ORDER BY enqueue_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqliteLogFailure(db, "pending_sync fetch prepare")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, peerId)
            sqlite3_bind_double(stmt, 2, cutoff)
            return readRows(stmt)
        }
    }

    /// All pending hashes for a peer (used to know what's awaiting ACK).
    func pendingHashes(forPeer peerId: String) -> Set<String> {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT hash FROM pending_sync WHERE peer_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, peerId)
            var hashes = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let h = optionalString(stmt, 0) { hashes.insert(h) }
            }
            return hashes
        }
    }

    // MARK: - Delete

    /// Remove a frame by (peerId, hash) once the peer ACKs it.
    /// - Returns: `true` if a row was actually deleted.
    @discardableResult
    func remove(peerId: String, hash: String) -> Bool {
        queue.sync {
            guard let db else { return false }
            var stmt: OpaquePointer?
            let sql = "DELETE FROM pending_sync WHERE peer_id = ? AND hash = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqliteLogFailure(db, "pending_sync remove prepare")
                return false
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, peerId)
            bindText(stmt, 2, hash)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqliteLogFailure(db, "pending_sync remove step")
                return false
            }
            return sqlite3_changes(db) > 0
        }
    }

    /// Drop all pending frames for a peer (e.g. when sync is disabled).
    func removeAll(forPeer peerId: String) {
        queue.sync {
            guard let db else { return }
            sqliteExec(db, "DELETE FROM pending_sync WHERE peer_id = '\(peerId.replacingOccurrences(of: "'", with: "''"))'",
                       context: "pending_sync removeAll peer")
        }
    }

    /// Drop everything (e.g. on stop()).
    func clearAll() {
        queue.sync {
            guard let db else { return }
            sqliteExec(db, "DELETE FROM pending_sync", context: "pending_sync clearAll")
        }
    }

    /// Sweep expired frames older than `ttl`. Called on startup.
    func cleanOld(ttl: TimeInterval) {
        queue.sync {
            guard let db else { return }
            let cutoff = Date().addingTimeInterval(-ttl).timeIntervalSince1970
            sqliteExec(db, "DELETE FROM pending_sync WHERE enqueue_at < \(cutoff)",
                       context: "pending_sync cleanOld")
        }
    }

    // MARK: - Private helpers

    private func peerCountLocked(_ peerId: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM pending_sync WHERE peer_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, peerId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func readRows(_ stmt: OpaquePointer?) -> [PendingFrame] {
        var frames: [PendingFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pid = optionalString(stmt, 0),
                  let hash = optionalString(stmt, 1),
                  let type = optionalString(stmt, 2) else { continue }
            let blobSize = sqlite3_column_bytes(stmt, 3)
            guard blobSize > 0, let blobPtr = sqlite3_column_blob(stmt, 3) else { continue }
            let data = Data(bytes: blobPtr, count: Int(blobSize))
            let ts = sqlite3_column_double(stmt, 4)
            frames.append(PendingFrame(
                peerId: pid,
                hash: hash,
                type: type,
                data: data,
                enqueueAt: Date(timeIntervalSince1970: ts)
            ))
        }
        return frames
    }
}
