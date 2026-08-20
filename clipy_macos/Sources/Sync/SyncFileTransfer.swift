import Foundation
import CryptoKit

/// Chunked file transfer over the v2 session protocol (see docs/PROTOCOL.md).
///
/// - `file.meta`  sender → receiver, encrypted JSON metadata, `hash` = sha256.
/// - `file.chunk` sender → receiver, encrypted `u32 BE index ‖ bytes`, msgId = fileId.
/// - `file.ack`   receiver → sender, encrypted JSON `{fileId, ok, error?}`.
///
/// Transfers are interactive one-shots: nothing is enqueued into
/// `PendingSyncRepository`; if the session drops mid-transfer both sides
/// discard state and the user can simply retry.
extension SyncManager {
    static let fileChunkSize = 1024 * 1024
    static let fileMaxBytes = 512 * 1024 * 1024
    static let fileIncomingIdleTimeout: TimeInterval = 120
    /// A whole chunk frame must fit in the socket send buffer so `send()`
    /// returns promptly; otherwise two Macs blasting files at each other could
    /// deadlock (both blocked writing, neither reading).
    static let fileSendBufferSize = 4 * 1024 * 1024
    /// Pipelined chunk writes: this many frames may sit in flight before the
    /// sender pauses and waits. 8 × ~1.4 MiB ≈ 11 MiB burst memory.
    static let fileMaxInflightChunks = 8

    private struct FileMeta: Decodable {
        let fileId: String
        let name: String
        let size: Int
        let chunkSize: Int
        let chunks: Int
        let sha256: String
    }

    // MARK: - Sending

    func sendFileToPeer(at url: URL, peerId targetId: String, completion: ((Bool) -> Void)? = nil) {
        guard PreferencesManager.shared.isSyncEnabled else { completion?(false); return }
        fileTransferQueue.async { [weak self] in
            guard let self else { completion?(false); return }
            let ok = self.sendFileToPeerSync(at: url, peerId: targetId)
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    func sendFile(at url: URL, toDevice targetName: String) {
        guard let peer = availablePeers.first(where: { $0.displayName == targetName }) else { return }
        sendFileToPeer(at: url, peerId: peer.peerId)
    }

    /// Runs on `fileTransferQueue`. Frame writes hop through `syncQueue.sync`
    /// so they serialize with session-close bookkeeping and never block reads
    /// for longer than one chunk.
    private func sendFileToPeerSync(at url: URL, peerId targetId: String) -> Bool {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return false }
        } catch {
            appLog("sendFile: cannot stat \(url.lastPathComponent): \(error)", level: .warning)
            return false
        }
        let length = values.fileSize ?? 0
        if length > Self.fileMaxBytes {
            appLog("sendFile: \(url.lastPathComponent) exceeds \(Self.fileMaxBytes) bytes", level: .warning)
            return false
        }

        guard let fd = waitForSessionFd(peerId: targetId, timeout: 8) else {
            appLog("sendFile: no session with \(targetId.prefix(8))", level: .warning)
            return false
        }

        let fileId = UUID().uuidString
        let fileName = url.lastPathComponent
        let chunkSize = Self.fileChunkSize
        let chunkCount = length == 0 ? 0 : (length + chunkSize - 1) / chunkSize

        guard let sha256Hex = hashFile(at: url) else {
            appLog("sendFile: cannot read \(fileName)", level: .warning)
            return false
        }

        // Register the ack waiter before the first frame goes out — the peer
        // may reject immediately after reading file.meta.
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var ackResult: Bool?
        syncQueue.sync {
            fileAckWaiters[fileId] = { ok in
                resultLock.lock(); ackResult = ok; resultLock.unlock()
                semaphore.signal()
            }
        }

        func fail(_ reason: String) -> Bool {
            appLog("sendFile \(fileName): \(reason)", level: .warning)
            syncQueue.sync { _ = fileAckWaiters.removeValue(forKey: fileId) }
            return false
        }

        guard let metaPayload = encodeFileTransferJSON([
            "fileId": fileId, "name": fileName, "size": length,
            "chunkSize": chunkSize, "chunks": chunkCount, "sha256": sha256Hex,
        ]) else { return fail("meta encode failed") }
        let metaEnvelope = SyncEnvelope.make(
            type: SyncType.fileMeta, peerId: peerId, name: displayName,
            hash: sha256Hex, payload: metaPayload
        )
        guard let metaData = encodeFrame(metaEnvelope), writeFrameToSession(fd, metaData) else {
            return fail("meta write failed")
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return fail("cannot open file") }
        defer { try? handle.close() }

        // Pipelined writes: dispatch frames to syncQueue and keep reading +
        // encrypting the next chunk while the previous one drains. Bounded by
        // a semaphore so memory stays capped; a failure flag aborts early.
        let inflight = DispatchSemaphore(value: Self.fileMaxInflightChunks)
        let drain = DispatchSemaphore(value: 0)
        let flightLock = NSLock()
        var inFlightCount = 0
        var writeFailed = false

        func checkWriteFailed() -> Bool {
            flightLock.lock(); defer { flightLock.unlock() }
            return writeFailed
        }

        func dispatchFrame(_ frame: Data) {
            inflight.wait()
            flightLock.lock(); inFlightCount += 1; flightLock.unlock()
            syncQueue.async { [weak self] in
                let ok = self?.writeFrameToSession(fd, frame) ?? false
                flightLock.lock()
                inFlightCount -= 1
                let nowEmpty = inFlightCount == 0
                if !ok { writeFailed = true }
                flightLock.unlock()
                inflight.signal()
                if nowEmpty { drain.signal() }
            }
        }

        var index: UInt32 = 0
        while Int(index) < chunkCount {
            // Peer rejected mid-stream or a write already failed → stop.
            if checkWriteFailed() { return fail("chunk write failed") }
            if !syncQueue.sync(execute: { fileAckWaiters[fileId] != nil }) {
                resultLock.lock(); let rejected = ackResult == false; resultLock.unlock()
                if rejected { return fail("rejected by peer") }
            }
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            var plain = Data(count: 4)
            plain.reserveCapacity(4 + chunk.count)
            plain.withUnsafeMutableBytes { $0.storeBytes(of: index.bigEndian, as: UInt32.self) }
            plain.append(chunk)
            guard let payload = encryptBytes(plain) else { return fail("chunk encrypt failed") }
            let envelope = SyncEnvelope(
                v: SyncEnvelope.version, type: SyncType.fileChunk, msgId: fileId,
                peerId: peerId, name: displayName, port: nil,
                ts: Date().timeIntervalSince1970, hash: nil, payload: payload
            )
            guard let frame = encodeFrame(envelope) else { return fail("chunk encode failed") }
            dispatchFrame(frame)
            index &+= 1
        }

        // Wait until every dispatched frame has actually hit the socket.
        while true {
            flightLock.lock()
            let remaining = inFlightCount
            let failed = writeFailed
            flightLock.unlock()
            if remaining == 0 || failed { break }
            _ = drain.wait(timeout: .now() + .seconds(30))
        }
        if checkWriteFailed() { return fail("chunk write failed") }

        let timeout = max(45, length / (200 * 1024))
        if semaphore.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            return fail("no ack within \(timeout)s")
        }
        resultLock.lock(); let ok = ackResult == true; resultLock.unlock()
        if ok { appLog("sendFile: \(fileName) (\(length) bytes) delivered to \(targetId.prefix(8))") }
        else { appLog("sendFile: \(fileName) rejected by \(targetId.prefix(8))", level: .warning) }
        syncQueue.sync { _ = fileAckWaiters.removeValue(forKey: fileId) }
        return ok
    }

    /// Write one frame on the sync queue with the retired-fd guard.
    private func writeFrameToSession(_ fd: Int32, _ data: Data) -> Bool {
        syncQueue.sync {
            guard !retiredFDs.contains(fd), sessions.values.first(where: { $0.fd == fd }) != nil else { return false }
            return writeAll(fd, data)
        }
    }

    /// Poll briefly for a live session, dialing `direct` (no auth, like the
    /// text send) once along the way.
    private func waitForSessionFd(peerId: String, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        var dialed = false
        while Date() < deadline {
            if let fd = syncQueue.sync(execute: { sessions[peerId]?.fd }),
               !syncQueue.sync(execute: { retiredFDs.contains(fd) }) {
                return fd
            }
            if !dialed {
                dialed = true
                if let peer = peerSnapshot(peerId) {
                    dial(host: peer.host, port: peer.port, reason: "direct", peerId: peerId)
                } else if let cached = cachedEndpoint(for: peerId) {
                    dial(host: cached.host, port: cached.port, reason: "direct", peerId: peerId)
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return syncQueue.sync(execute: { sessions[peerId]?.fd })
    }

    private func hashFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `read(upToCount:)` returns nil (not empty Data) at EOF — only a
            // thrown error is a real failure. Treating nil as an error made
            // every transfer fail with "hash mismatch (got nil)".
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1024 * 1024) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Receiving (all handlers run on syncQueue)

    func handleFileMeta(_ env: SyncEnvelope, from peerId: String) {
        guard let payload = env.payload, let plain = decrypt(payload),
              let data = plain.data(using: .utf8), let meta = try? JSONDecoder().decode(FileMeta.self, from: data)
        else {
            appLog("file.meta undecodable from \(peerId.prefix(8))", level: .warning)
            return
        }
        if meta.size > Self.fileMaxBytes || meta.chunkSize <= 0 || meta.sha256.isEmpty {
            appLog("file.meta rejected (invalid) from \(peerId.prefix(8))", level: .warning)
            sendFileAck(to: peerId, fileId: meta.fileId, ok: false, error: "tooLarge")
            return
        }

        // A duplicate meta for the same fileId restarts the transfer.
        discardIncomingFile(fileId: meta.fileId)
        let partURL = Self.fileReceiveDirectory().appendingPathComponent(".incoming-\(meta.fileId).part")
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        var state = IncomingFileState(
            peerId: peerId,
            senderName: env.name ?? String(peerId.prefix(8)),
            fileId: meta.fileId,
            fileName: Self.sanitizeFileName(meta.name),
            fileSize: meta.size,
            chunkSize: meta.chunkSize,
            chunkCount: meta.chunks,
            sha256: meta.sha256,
            partURL: partURL
        )
        // One persistent append handle instead of open/write/close per chunk.
        do {
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.seekToEnd()
            state.handle = handle
        } catch {
            appLog("file.meta part file unavailable: \(error)", level: .error)
            sendFileAck(to: peerId, fileId: meta.fileId, ok: false, error: "ioError")
            return
        }
        incomingFiles[meta.fileId] = state
        armIncomingIdleTimer(fileId: meta.fileId)
        appLog("file.meta from \(peerId.prefix(8)): \(meta.name) (\(meta.size) bytes, \(meta.chunks) chunks)")
        // Zero-byte files carry no chunks; finish immediately.
        if meta.chunks == 0 {
            completeChunkedFile(fileId: meta.fileId)
        }
    }

    func handleFileChunk(_ env: SyncEnvelope, from peerId: String) {
        // Chunks carry msgId = fileId.
        guard var state = incomingFiles[env.msgId], state.peerId == peerId,
              let payload = env.payload, let plain = decryptToBytes(payload), plain.count > 4
        else { return }
        let index = Int(plain.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard index < state.chunkCount else { return }
        let data = plain.dropFirst(4)
        do {
            guard let handle = state.handle else { return }
            // Sequential appends: the handle already sits at EOF (seekToEnd at
            // meta) and TCP delivers chunks in order; a restart always begins
            // with a fresh fileId (fresh part file).
            try handle.write(contentsOf: data)
        } catch {
            appLog("file.chunk write failed: \(error)", level: .error)
            discardIncomingFile(fileId: state.fileId)
            sendFileAck(to: peerId, fileId: state.fileId, ok: false, error: "ioError")
            return
        }
        state.received.insert(index)
        incomingFiles[env.msgId] = state
        armIncomingIdleTimer(fileId: state.fileId)
        if state.received.count >= state.chunkCount {
            completeChunkedFile(fileId: env.msgId)
        }
    }

    /// Pull the finished state out of the map (closing the part-file handle)
    /// and hand the heavy verification tail to fileTransferQueue.
    private func completeChunkedFile(fileId: String) {
        guard var state = incomingFiles.removeValue(forKey: fileId) else { return }
        state.idleWork?.cancel()
        let handle = state.handle
        state.handle = nil
        if let handle { try? handle.close() }
        fileTransferQueue.async { [weak self] in
            self?.completeIncomingFile(state)
        }
    }

    func handleFileAck(_ env: SyncEnvelope, from peerId: String) {
        guard let payload = env.payload, let plain = decrypt(payload),
              let data = plain.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileId = json["fileId"] as? String
        else { return }
        let ok = json["ok"] as? Bool ?? false
        fileAckWaiters.removeValue(forKey: fileId)?(ok)
    }

    /// Heavy tail of the receive path: hash verification, move into
    /// ~/Downloads/Clipy, history insert, ack. Runs on fileTransferQueue with
    /// an isolated copy of the state (already removed from the live map).
    private func completeIncomingFile(_ state: IncomingFileState) {
        let sha256Hex = hashFile(at: state.partURL)
        if sha256Hex != state.sha256 {
            appLog("file transfer hash mismatch for \(state.fileName) (got \(sha256Hex?.prefix(8) ?? "nil"))", level: .warning)
            try? FileManager.default.removeItem(at: state.partURL)
            sendFileAckOnQueue(to: state.peerId, fileId: state.fileId, ok: false, error: "hashMismatch")
            return
        }
        let directory = Self.fileReceiveDirectory()
        let destination = Self.dedupeDestination(in: directory, fileName: state.fileName)
        do {
            try FileManager.default.moveItem(at: state.partURL, to: destination)
        } catch {
            appLog("file receive move failed: \(error)", level: .error)
            try? FileManager.default.removeItem(at: state.partURL)
            sendFileAckOnQueue(to: state.peerId, fileId: state.fileId, ok: false, error: "ioError")
            return
        }
        let senderName = state.senderName
        let fileName = state.fileName
        DispatchQueue.main.async {
            ClipboardManager.shared.handleRemoteFileSync(url: destination, senderName: senderName)
            TransferNotifier.shared.notifyFileReceived(name: fileName, sender: senderName)
        }
        sendFileAckOnQueue(to: state.peerId, fileId: state.fileId, ok: true)
        appLog("Received file \(state.fileName) (\(state.fileSize) bytes) from \(senderName)")
    }

    private func sendFileAckOnQueue(to peerId: String, fileId: String, ok: Bool, error: String? = nil) {
        syncQueue.async { [weak self] in
            self?.sendFileAck(to: peerId, fileId: fileId, ok: ok, error: error)
        }
    }

    private func sendFileAck(to peerId: String, fileId: String, ok: Bool, error: String? = nil) {
        var object: [String: Any] = ["fileId": fileId, "ok": ok]
        if let error { object["error"] = error }
        guard let payload = encodeFileTransferJSON(object) else { return }
        let env = SyncEnvelope.make(type: SyncType.fileAck, peerId: self.peerId, payload: payload)
        guard let data = encodeFrame(env), let fd = sessions[peerId]?.fd, writeAll(fd, data) else { return }
    }

    private func armIncomingIdleTimer(fileId: String) {
        incomingFiles[fileId]?.idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let entry = self.incomingFiles.removeValue(forKey: fileId) else { return }
            appLog("Incoming file \(entry.fileName) timed out; discarded", level: .warning)
            if let handle = entry.handle { try? handle.close() }
            try? FileManager.default.removeItem(at: entry.partURL)
        }
        incomingFiles[fileId]?.idleWork = work
        syncQueue.asyncAfter(deadline: .now() + Self.fileIncomingIdleTimeout, execute: work)
    }

    /// Drop an incoming transfer (state + part file). Session close and
    /// duplicate meta both funnel through here.
    func discardIncomingFile(fileId: String) {
        guard let state = incomingFiles.removeValue(forKey: fileId) else { return }
        state.idleWork?.cancel()
        if let handle = state.handle { try? handle.close() }
        try? FileManager.default.removeItem(at: state.partURL)
    }

    func discardIncomingFiles(from peerId: String) {
        for state in incomingFiles.values where state.peerId == peerId {
            discardIncomingFile(fileId: state.fileId)
        }
    }

    private func encodeFileTransferJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return encrypt(json)
    }

    // MARK: - Paths

    /// Parts live next to the destination so the final move stays on one
    /// volume (atomic rename).
    static func fileReceiveDirectory() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = downloads.appendingPathComponent("Clipy", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sanitizeFileName(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\u{0}", with: "")
        // Keep the receive dir browsable: no hidden/dot-prefixed results.
        while cleaned.hasPrefix(".") { cleaned = String(cleaned.dropFirst()) }
        return cleaned.isEmpty ? "file" : cleaned
    }

    static func dedupeDestination(in directory: URL, fileName: String) -> URL {
        var candidate = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
