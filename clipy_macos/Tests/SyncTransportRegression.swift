import Foundation
import Darwin

/// Transport-layer regression: default AES-GCM payload crypto,
/// length-prefixed framing, and the hello/welcome handshake over a real
/// socketpair. The remote side is scripted by hand because two managers in
/// one process share the same peerId (they would trip selfHandshake).
func runSyncTransportRegressionTests() {
    let defaults = UserDefaults.standard
    let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
    func useSecret(_ secret: String) {
        var arguments = previousArguments
        arguments["syncPairingSecret"] = secret
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    let manager = SyncManager()
    useSecret("transport-test-secret-A")
    runCryptoChecks(manager, useSecret: useSecret)
    useSecret("transport-test-secret-A")
    runFramingChecks(manager)
    runHandshakeChecks(manager, useSecret: useSecret)
    useSecret("transport-test-secret-A")
    runSessionReaderChecks(manager)
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), "SyncTransportRegression: " + message)
}

private func runCryptoChecks(_ m: SyncManager, useSecret: (String) -> Void) {
    let text = "剪贴板 clipboard 😀 " + String(repeating: "x", count: 4096)
    guard let sealed = m.encrypt(text) else { preconditionFailure("encrypt failed") }
    check(m.decrypt(sealed) == text, "text round-trip")
    check(m.encrypt(text) != sealed, "nonce reused")
    let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    guard let sealedBytes = m.encryptBytes(bytes) else { preconditionFailure("encryptBytes failed") }
    check(m.decryptToBytes(sealedBytes) == bytes, "bytes round-trip")

    var tampered = Data(base64Encoded: sealed)!
    tampered[tampered.count / 2] ^= 0x01
    check(m.decrypt(tampered.base64EncodedString()) == nil, "tampered ciphertext accepted")
    check(m.decrypt("not base64!") == nil, "garbage accepted")
    check(m.decrypt(Data(count: 28).base64EncodedString()) == nil, "short input accepted")

    for legacy in ["", "different-previous-code"] {
        useSecret(legacy)
        check(m.decrypt(sealed) == text, "legacy pairing preference changed default key")
        check(m.decryptToBytes(sealedBytes) == bytes, "legacy preference changed binary key")
    }
    let fixture = "AAECAwQFBgcICQoLhdUwCui4zMJDC8GLd3CsDGCvgcc2/Zua+hgmwEW4aNreepO2aYY99Q=="
    check(m.decrypt(fixture) == "default transport 世界", "default-key interoperability vector")
}

private func makePair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    var yes: Int32 = 1
    for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) }
    return (fds[0], fds[1])
}

private func rawWrite(_ fd: Int32, _ data: Data) {
    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    check(written == data.count, "fixture write short")
}

private func lengthPrefix(_ length: UInt32) -> Data {
    var big = length.bigEndian
    return Data(bytes: &big, count: 4)
}

private func runFramingChecks(_ m: SyncManager) {
    let env = SyncEnvelope.make(type: SyncType.history, peerId: "peer-x", name: "名字", port: 5566,
                                hash: "h1", payload: m.encrypt("payload"))
    guard let frame = m.encodeFrame(env) else { preconditionFailure("encodeFrame failed") }
    let length = frame.prefix(4).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
    check(length == frame.count - 4, "length prefix mismatch")
    let decoded = m.decodeEnvelope(frame.dropFirst(4))
    check(decoded?.type == env.type && decoded?.msgId == env.msgId && decoded?.name == "名字"
          && decoded?.hash == "h1" && decoded?.payload == env.payload, "envelope round-trip")
    check(m.decodeEnvelope(Data("{".utf8)) == nil, "broken JSON decoded")
    let huge = SyncEnvelope.make(type: SyncType.history, peerId: "p",
                                 payload: String(repeating: "a", count: SyncManager.maxFrameLength))
    check(m.encodeFrame(huge) == nil, "oversized frame encoded")

    // Fragmented delivery is reassembled.
    do {
        let (a, b) = makePair(); defer { Darwin.close(a); Darwin.close(b) }
        DispatchQueue.global().async {
            rawWrite(b, frame.prefix(2)); usleep(50_000)
            rawWrite(b, frame.subdata(in: 2..<40)); usleep(50_000)
            rawWrite(b, frame.suffix(from: 40))
        }
        check(m.readOneFrame(fd: a, timeout: 2) == frame.dropFirst(4), "fragmented frame not reassembled")
    }
    // Zero / oversized length prefixes and silence all fail cleanly.
    for (prefix, label) in [(lengthPrefix(0), "zero length"),
                            (lengthPrefix(UInt32(SyncManager.maxHandshakeFrameLength + 1)), "oversized handshake frame")] {
        let (a, b) = makePair(); defer { Darwin.close(a); Darwin.close(b) }
        rawWrite(b, prefix + Data(count: 8))
        check(m.readOneFrame(fd: a, timeout: 1) == nil, label + " accepted")
    }
    do {
        let (a, b) = makePair(); defer { Darwin.close(a); Darwin.close(b) }
        let started = Date()
        check(m.readOneFrame(fd: a, timeout: 0.3) == nil, "silent peer returned a frame")
        check(Date().timeIntervalSince(started) < 1.5, "readOneFrame ignored its timeout")
    }
    do {
        let (a, b) = makePair(); defer { Darwin.close(a) }
        rawWrite(b, lengthPrefix(10) + Data(count: 3)); Darwin.close(b)
        check(m.readOneFrame(fd: a, timeout: 1) == nil, "truncated frame at EOF accepted")
    }
}

/// Runs `performHandshake` on the manager's side of a socketpair while
/// `script` plays the remote. syncQueue is held until the handshake returns
/// and the generation is bumped, so a successful handshake's adoptSession is
/// discarded (it closes the fd) instead of touching real session state.
private func handshake(_ m: SyncManager, script: (Int32) -> Void) -> SyncManager.HandshakeFailure? {
    let (local, remote) = makePair()
    defer { Darwin.close(remote) }
    let hold = DispatchSemaphore(value: 0)
    m.syncQueue.async { hold.wait() }
    var failure: SyncManager.HandshakeFailure?
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        m.performHandshake(fd: local, host: "127.0.0.1", port: 5566, inbound: true) { failure = $0 }
        m.scanStateLock.lock(); m.serviceGeneration &+= 1; m.scanStateLock.unlock()
        done.signal()
    }
    script(remote)
    check(done.wait(timeout: .now() + 5) == .success, "handshake hung")
    hold.signal()
    m.syncQueue.sync {}
    return failure
}

private func sendHello(_ fd: Int32, _ m: SyncManager, peerId: String, payload: String? = nil, version: Int = SyncEnvelope.version) {
    var hello = SyncEnvelope.make(type: SyncType.hello, peerId: peerId, name: "Fixture", port: 5566, payload: payload)
    hello.v = version
    rawWrite(fd, m.encodeFrame(hello)!)
}

private func runHandshakeChecks(_ m: SyncManager, useSecret: (String) -> Void) {
    let remoteId = "transport-fixture-peer"
    for legacy in ["", "old-code-A", "old-code-B"] {
        useSecret(legacy)
        var welcome: SyncEnvelope?
        let failure = handshake(m) { fd in
            guard let frame = m.readOneFrame(fd: fd, timeout: 2), let hello = m.decodeEnvelope(frame) else {
                preconditionFailure("no hello from manager")
            }
            check(hello.type == SyncType.hello && hello.payload == nil, "hello requires pairing")
            sendHello(fd, m, peerId: remoteId)
            welcome = m.readOneFrame(fd: fd, timeout: 2).flatMap(m.decodeEnvelope)
        }
        check(failure == nil && welcome?.type == SyncType.welcome && welcome?.payload == nil,
              "default handshake failed with old preference")
    }
    let cases: [(String, Int, SyncManager.HandshakeFailure)] = [
        (m.peerId, SyncEnvelope.version, .selfHandshake),
        (remoteId, 2, .versionMismatch),
    ]
    for (sender, version, expected) in cases {
        let failure = handshake(m) { fd in
            _ = m.readOneFrame(fd: fd, timeout: 2)
            sendHello(fd, m, peerId: sender, version: version)
            check(m.readOneFrame(fd: fd, timeout: 2) == nil, "invalid handshake got reply")
        }
        check(failure == expected, "incorrect handshake rejection")
    }
    m.diagnostics.reset()

    check(handshake(m) { fd in
        _ = m.readOneFrame(fd: fd, timeout: 2)
        rawWrite(fd, lengthPrefix(5) + Data("nope!".utf8))
    } == .readTimeout, "undecodable reply not rejected")

    let started = Date()
    check(handshake(m) { fd in _ = m.readOneFrame(fd: fd, timeout: 2) } == .readTimeout, "silent peer not timed out")
    check(Date().timeIntervalSince(started) < SyncManager.handshakeTimeout + 2, "handshake timeout not honoured")

}

/// Session read path: fragmented frames are reassembled, a bad length prefix
/// drops the session, undecryptable payloads are recorded — all visible in
/// diagnostics.
private func runSessionReaderChecks(_ m: SyncManager) {
    let remote = "transport-session-peer"
    let (local, peer) = makePair()
    defer { Darwin.close(peer) }
    _ = fcntl(local, F_SETFL, fcntl(local, F_GETFL, 0) | O_NONBLOCK)
    let reader = DispatchSource.makeReadSource(fileDescriptor: local, queue: m.syncQueue)
    reader.setEventHandler { m.onSessionReadable(peerId: remote) }
    m.syncQueue.sync {
        let writer = SyncSocketWriter(fd: local, queue: m.syncQueue) {}
        // isClient=false: a keepalive-driven close must not schedule a redial.
        m.sessions[remote] = SyncManager.Session(peerId: remote, host: "127.0.0.1", port: 0,
                                                 fd: local, readSource: reader, writer: writer, isClient: false)
    }
    reader.resume()
    m.diagnostics.reset()

    let ping = m.encodeFrame(SyncEnvelope.make(type: SyncType.ping, peerId: remote))!
    rawWrite(peer, ping.prefix(3)); usleep(50_000); rawWrite(peer, ping.suffix(from: 3))
    let pong = m.readOneFrame(fd: peer, timeout: 2).flatMap(m.decodeEnvelope)
    check(pong?.type == SyncType.pong, "fragmented ping not answered")

    let bogus = SyncEnvelope.make(type: SyncType.history, peerId: remote, hash: "h", payload: "AAAA" + String(repeating: "B", count: 60))
    rawWrite(peer, m.encodeFrame(bogus)!)
    func waitFor(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { usleep(10_000) }
        check(condition(), what)
    }
    waitFor("decrypt failure not recorded") { m.diagnostics.snapshot()[remote]?.lastError == "decryptFailed" }
    check(m.diagnostics.snapshot()[remote]?.lastReceivedAt != nil, "received frame not recorded")

    rawWrite(peer, lengthPrefix(UInt32(SyncManager.maxFrameLength + 1)))
    waitFor("bad length did not drop the session") { m.syncQueue.sync { m.sessions[remote] == nil } }
    let record = m.diagnostics.snapshot()[remote]
    check(record?.lastError?.hasPrefix("badFrameLength") == true && record?.sessionDownAt != nil, "session drop not diagnosed")
    // closeSession closes the fd; the fixture end sees EOF.
    var byte: UInt8 = 0
    waitFor("session fd not closed") { Darwin.read(peer, &byte, 1) == 0 }
    m.diagnostics.reset()
}
