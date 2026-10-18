import Foundation
import Darwin

@main struct RelaySmoke {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["CLIPY_RELAY_TEST_URL"], let keyFile = env["CLIPY_RELAY_TEST_KEY_FILE"] else { fatalError("Set test URL and key file") }
        let token = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var client: SyncRelayClient!
        client = SyncRelayClient(url: URL(string: url)!, token: token, id: "smoke-swift", name: "Relay test Swift", port: 5566, addresses: []) { peers in
            guard peers.contains(where: { $0.id == "smoke-dart" }) else { return }
            client.open(peer: "smoke-dart") { fd in
                DispatchQueue.global().async {
                    var timeout = timeval(tv_sec: 30, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    let size = 8 * 1024 * 1024
                    let group = DispatchGroup(); group.enter()
                    DispatchQueue.global().async {
                        var offset = 0
                        while offset < size {
                            let bytes = (offset..<min(offset + 65536, size)).map { UInt8($0 % 251) }
                            var written = 0
                            while written < bytes.count {
                                let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + written, bytes.count - written, 0) }
                                guard n > 0 else { fatalError("Smoke send failed") }
                                written += n
                            }
                            offset += bytes.count
                        }
                        group.leave()
                    }
                    var offset = 0
                    let started = Date()
                    while offset < size {
                        var bytes = [UInt8](repeating: 0, count: 65536)
                        let n = Darwin.recv(fd, &bytes, bytes.count, 0)
                        guard n > 0 else { fatalError("Smoke receive failed at \(offset)") }
                        for i in 0..<n { precondition(bytes[i] == UInt8((offset + i) % 251), "Byte corruption") }
                        offset += n
                    }
                    group.wait()
                    print("Swift ↔ Dart relay: \(offset) bytes echoed and verified in \(Date().timeIntervalSince(started))s")
                    Darwin.close(fd); client.stop()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { exit(0) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { fatalError("Smoke timeout") }
        client.start(); dispatchMain()
    }
}
