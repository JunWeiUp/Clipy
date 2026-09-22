import Foundation
import Darwin

func runFolderTransferRegressionTests() {
    let fm = FileManager.default
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    func rejected(_ message: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure(message) } catch { }
    }
    do {
        let sandbox = fm.temporaryDirectory.appendingPathComponent("clipy-folder-test-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: sandbox) }
        let source = sandbox.appendingPathComponent("资料.v1")
        let destination = sandbox.appendingPathComponent("received")
        try fm.createDirectory(at: source.appendingPathComponent("嵌套/空目录"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let content = Data((0..<(2 * SyncManager.fileChunkSize + 37)).map { UInt8(truncatingIfNeeded: $0) })
        let original = source.appendingPathComponent("嵌套/带 空格😀.bin")
        try content.write(to: original)
        try Data().write(to: source.appendingPathComponent("empty.txt"))
        let hiddenContent = Data("hidden-data-for-crc".utf8)
        try hiddenContent.write(to: source.appendingPathComponent(".hidden"))
        let executable = source.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\necho demo\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let prepared = try FolderTransferArchive.prepare(source, maxBytes: SyncManager.fileMaxBytes)
        defer { prepared.remove() }
        let restored = try FolderTransferArchive.unpack(prepared.url, folderName: prepared.folderName,
                                                       in: destination, maxBytes: SyncManager.fileMaxBytes)
        check(restored.lastPathComponent == source.lastPathComponent, "folder name changed")
        check(tryData(restored.appendingPathComponent("嵌套/带 空格😀.bin")) == content, "nested binary content changed")
        check(tryData(original) == content, "source changed")
        check(fm.fileExists(atPath: restored.appendingPathComponent("嵌套/空目录").path), "empty nested folder lost")
        check(tryData(restored.appendingPathComponent(".hidden")) == hiddenContent, "hidden file lost")
        check(tryData(restored.appendingPathComponent("empty.txt")) == Data(), "empty file lost")
        let mode = try fm.attributesOfItem(atPath: restored.appendingPathComponent("run.sh").path)[.posixPermissions] as! NSNumber
        check(mode.intValue & 0o100 != 0, "executable bit lost")
        let second = try FolderTransferArchive.unpack(prepared.url, folderName: prepared.folderName,
                                                     in: destination, maxBytes: SyncManager.fileMaxBytes)
        check(second.lastPathComponent == "资料.v1 (2)", "folder collision overwrote or split extension")
        check(tryData(restored.appendingPathComponent(".hidden")) == hiddenContent, "existing folder overwritten")

        // Old receivers get a valid ZIP that standard macOS unzip can read.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tqq", prepared.url.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run(); unzip.waitUntilExit()
        check(unzip.terminationStatus == 0, "archive is not a valid standard ZIP")

        let empty = sandbox.appendingPathComponent("完全为空")
        try fm.createDirectory(at: empty, withIntermediateDirectories: false)
        let emptyArchive = try FolderTransferArchive.prepare(empty, maxBytes: 4096)
        defer { emptyArchive.remove() }
        let emptyResult = try FolderTransferArchive.unpack(emptyArchive.url, folderName: emptyArchive.folderName,
                                                          in: destination, maxBytes: 4096)
        let emptyChildren = try fm.contentsOfDirectory(atPath: emptyResult.path)
        check(emptyChildren.isEmpty, "empty root folder lost")

        rejected("size cap ignored") { _ = try FolderTransferArchive.prepare(source, maxBytes: 128) }
        let link = source.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: original)
        rejected("sender followed symlink") { _ = try FolderTransferArchive.prepare(source, maxBytes: SyncManager.fileMaxBytes) }
        try fm.removeItem(at: link)
        rejected("wrong root accepted") {
            _ = try FolderTransferArchive.unpack(prepared.url, folderName: "../escape", in: destination, maxBytes: SyncManager.fileMaxBytes)
        }

        let zip = try Data(contentsOf: prepared.url)
        let bad = sandbox.appendingPathComponent("bad.zip")
        func rejectArchive(_ data: Data, _ reason: String) throws {
            try data.write(to: bad)
            rejected(reason) {
                _ = try FolderTransferArchive.unpack(bad, folderName: prepared.folderName, in: destination, maxBytes: SyncManager.fileMaxBytes)
            }
            let leftovers = try fm.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".folder-") }
            check(leftovers.isEmpty, "failed extraction left staging data")
        }
        try rejectArchive(Data(zip.dropLast()), "truncated archive accepted")
        var corrupted = zip
        // Alter a local header without changing the directory copy.
        corrupted[14] ^= 1
        try rejectArchive(corrupted, "header mismatch accepted")
        var modifiedPayload = zip
        let payloadRange = modifiedPayload.range(of: hiddenContent)!
        modifiedPayload[payloadRange.lowerBound] ^= 1
        try rejectArchive(modifiedPayload, "CRC mismatch accepted")
        var traversal = zip
        let pathBytes = Data("嵌套/".utf8)
        let replacement = Data("../xxx/".utf8) // same byte length
        check(pathBytes.count == replacement.count, "test fixture length mismatch")
        while let range = traversal.range(of: pathBytes) { traversal.replaceSubrange(range, with: replacement) }
        try rejectArchive(traversal, "path traversal accepted")

        try runFolderWireRegression(source: source, archive: prepared.url, sandbox: sandbox, expected: content)

        prepared.remove()
        check(!fm.fileExists(atPath: prepared.temporaryDirectory.path), "sender archive cleanup failed")
        print("Folder transfer regressions passed (ZIP compatibility, binary/Unicode/empty folders, collision, limits, links, traversal, CRC, cleanup).")
    } catch { preconditionFailure("Folder transfer regression failed: \(error)") }
}

private func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }

/// Exercise the real send API, encryption, framing, receiver and ACK in both
/// directions simultaneously. Only discovery, UI notifications and user paths
/// are replaced; fixtures never touch the user's history or Downloads.
private func runFolderWireRegression(source: URL, archive: URL, sandbox: URL, expected: Data) throws {
    let defaults = UserDefaults.standard
    let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = previousArguments; arguments["syncEnabled"] = true
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
    let fm = FileManager.default
    let left = SyncManager(), right = SyncManager()
    let leftDir = sandbox.appendingPathComponent("left"), rightDir = sandbox.appendingPathComponent("right")
    for dir in [leftDir, rightDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: false) }
    left.fileReceiveDirectoryForTesting = leftDir; right.fileReceiveDirectoryForTesting = rightDir
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    func connect(_ manager: SyncManager, fd: Int32, remote: String) -> DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: manager.syncQueue)
        reader.setEventHandler { manager.onSessionReadable(peerId: remote) }
        manager.syncQueue.sync {
            let writer = SyncSocketWriter(fd: fd, queue: manager.syncQueue) { preconditionFailure("fixture socket failed") }
            manager.sessions[remote] = SyncManager.Session(peerId: remote, host: "127.0.0.1", port: 0,
                                                          fd: fd, readSource: reader, writer: writer, isClient: true)
        }
        reader.resume()
        return reader
    }
    let leftReader = connect(left, fd: fds[0], remote: "right")
    let rightReader = connect(right, fd: fds[1], remote: "left")
    defer {
        let stopped = DispatchGroup()
        for (manager, reader) in [(left, leftReader), (right, rightReader)] {
            manager.syncQueue.sync {
                for session in manager.sessions.values {
                    if let writer = session.writer {
                        stopped.enter(); writer.cancel { stopped.leave() }
                    }
                }
                manager.sessions.removeAll()
                stopped.enter(); reader.setCancelHandler { stopped.leave() }
                reader.cancel()
            }
        }
        precondition(stopped.wait(timeout: .now() + 2) == .success)
        for fd in fds { Darwin.close(fd) }
    }
    func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "folder wire transfer timed out (bidirectional deadlock)")
    }
    var completed = 0
    left.sendFileToPeer(at: source, peerId: "right") { ok, error in
        precondition(ok && error == nil, "left folder send failed"); completed += 1
    }
    right.sendFileToPeer(at: source, peerId: "left") { ok, error in
        precondition(ok && error == nil, "right folder send failed"); completed += 1
    }
    wait { completed == 2 }
    for dir in [leftDir, rightDir] {
        precondition(tryData(dir.appendingPathComponent("资料.v1/嵌套/带 空格😀.bin")) == expected)
        precondition(!fm.fileExists(atPath: dir.appendingPathComponent("资料.v1.zip").path))
    }
    // An ordinary ZIP is a file, even if its bytes match our folder container.
    left.sendFileToPeer(at: archive, peerId: "right") { ok, error in
        precondition(ok && error == nil, "ordinary ZIP send failed"); completed += 1
    }
    wait { completed == 3 }
    precondition(tryData(rightDir.appendingPathComponent(archive.lastPathComponent)) == tryData(archive), "ordinary ZIP was auto-unpacked")
    left.sendFileToPeer(at: sandbox.appendingPathComponent("完全为空"), peerId: "right") { ok, error in
        precondition(ok && error == nil, "empty folder send failed"); completed += 1
    }
    wait { completed == 4 }
    let emptyChildren = try fm.contentsOfDirectory(atPath: rightDir.appendingPathComponent("完全为空").path)
    precondition(emptyChildren.isEmpty)
    left.sendFileToPeer(at: source.appendingPathComponent("empty.txt"), peerId: "right") { ok, error in
        precondition(ok && error == nil, "zero-byte file send failed"); completed += 1
    }
    wait { completed == 5 }
    precondition(tryData(rightDir.appendingPathComponent("empty.txt")) == Data())

    func metadata(_ extra: [String: Any] = [:]) throws -> SyncEnvelope {
        var fields: [String: Any] = ["fileId": "../remote-path", "name": "test.bin", "size": 2,
                                     "chunkSize": 1, "chunks": 2, "sha256": "unused-fixture-hash"]
        fields.merge(extra) { _, replacement in replacement }
        let payload = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        return SyncEnvelope.make(type: SyncType.fileMeta, peerId: "left", payload: left.encrypt(payload))
    }
    let unknown = try metadata(["folderFormat": "unknown", "folderName": "folder"])
    let badCount = try metadata(["chunks": 1])
    let valid = try metadata()
    right.syncQueue.sync {
        right.handleFileMeta(unknown, from: "left")
        precondition(right.incomingFiles.isEmpty, "unknown folder format accepted")
        right.handleFileMeta(badCount, from: "left")
        precondition(right.incomingFiles.isEmpty, "invalid chunk count accepted")
        right.handleFileMeta(valid, from: "left")
        let state = right.incomingFiles["../remote-path"]!
        precondition(state.partURL.deletingLastPathComponent().standardizedFileURL.path == rightDir.standardizedFileURL.path,
                     "remote fileId escaped receive directory")
        var chunk = SyncEnvelope.make(type: SyncType.fileChunk, peerId: "left", payload: left.encryptBytes(Data([0, 0, 0, 1, 7])))
        chunk.msgId = "../remote-path" // Index 1 arriving before index 0 must abort.
        right.handleFileChunk(chunk, from: "left")
        precondition(right.incomingFiles.isEmpty && !fm.fileExists(atPath: state.partURL.path), "bad chunk left partial data")
    }
    let children = try fm.contentsOfDirectory(atPath: rightDir.path)
    precondition(!children.contains { $0.hasPrefix(".incoming-") || $0.hasPrefix(".folder-") })
    print("Folder wire regressions passed (encrypted multi-chunk bidirectional transfers, empty folder/file, ACK after restore, ordinary ZIP unchanged, invalid metadata/chunk cleanup).")
}
