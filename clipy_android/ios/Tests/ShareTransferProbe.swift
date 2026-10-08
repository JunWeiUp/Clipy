import Foundation

@main enum ShareTransferProbe {
  static func main() {
    let args = CommandLine.arguments
    guard args.count == 5, let port = UInt16(args[2]) else { exit(64) }
    let token = ShareCancellation()
    if let raw = ProcessInfo.processInfo.environment["CLIPY_TEST_CANCEL_MS"], let delay = Double(raw) {
      DispatchQueue.global().asyncAfter(deadline: .now() + delay / 1000) { token.cancel() }
    }
    let client = ShareTransferClient(name: "Share regression fixture")
    do {
      try client.send(file: URL(fileURLWithPath: args[4]),
                      to: SharePeer(peerId: args[3], name: "Fixture", host: args[1], port: port),
                      cancellation: token, progress: { _ in })
      print("acknowledged")
    } catch { print(String(describing: error)); exit(2) }
  }
}
