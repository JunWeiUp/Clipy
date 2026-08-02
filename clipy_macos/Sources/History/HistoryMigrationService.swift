import Foundation

/// Migrates clipboard history from the legacy JSON store (`history_v2.json`)
/// into the current SQLite database. Extracting this keeps one-time, versioned
/// migration logic out of the core repository.
final class HistoryMigrationService {

    private let database: AppDatabase
    private let legacyJSONURL: URL

    init(database: AppDatabase) {
        self.database = database
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone", isDirectory: true)
        self.legacyJSONURL = appSupport.appendingPathComponent("history_v2.json")
    }

    /// Reads the legacy JSON file (plain or encrypted) and, if present, imports
    /// every entry through the supplied `insertHandler`. The JSON file is then
    /// moved to a `.bak` backup.
    ///
    /// - Note: The `insertHandler` runs on the caller's behalf while the
    ///   database queue is already held, so it must **not** perform its own
    ///   queue synchronization (i.e. it should be a "locked" variant).
    func migrateFromLegacyJSONIfNeeded(insertHandler: (HistoryEntry) -> Bool) {
        database.queue.sync {
            guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }
            guard let entries = decodeLegacyJSON(from: legacyJSONURL), !entries.isEmpty else { return }

            appLog("Migrating clipboard history from JSON to SQLite...", level: .info)
            for entry in entries {
                _ = insertHandler(entry)
            }
            let backupURL = legacyJSONURL.deletingPathExtension().appendingPathExtension("json.bak")
            try? FileManager.default.moveItem(at: legacyJSONURL, to: backupURL)
            appLog("History migration complete: \(entries.count) entries", level: .info)
        }
    }

    // MARK: - Private

    private func decodeLegacyJSON(from url: URL) -> [HistoryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(LegacyHistoryStorageEnvelope.self, from: data), envelope.encrypted {
            guard let encryptedData = Data(base64Encoded: envelope.payload),
                  let key = HistoryKeychain.loadKey(),
                  let decrypted = try? SecureStorageCrypto.decrypt(encryptedData, using: key),
                  let entries = try? decoder.decode([HistoryEntry].self, from: decrypted) else {
                return nil
            }
            return entries
        }
        return try? decoder.decode([HistoryEntry].self, from: data)
    }

    private struct LegacyHistoryStorageEnvelope: Codable {
        let version: Int
        let encrypted: Bool
        let payload: String
    }
}
