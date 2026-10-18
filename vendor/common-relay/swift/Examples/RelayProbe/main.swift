import Foundation
import CommonRelay

@main struct Probe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: RelayProbe private-config.json") }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let peers = try (object["trusted_peers"] as! [String: String]).mapValues { try Data(relayHex: $0) }
        let identity = try RelayIdentity(app: object["app"] as! String, group: object["group"] as! String, device: object["device"] as! String, secretKey: Data(relayHex: object["secret_key"] as! String), trustedPeers: peers)
        let journal = try (object["state_path"] as? String).map { try RelayJournal(directory: URL(fileURLWithPath: $0)) }
        let client = RelayClient(identity: identity, journal: journal)
        let events = try await client.connect(url: URL(string: object["url"] as! String)!, token: object["token"] as! String, allowLocalTest: object["allow_local_test"] as? Bool ?? false)
        print("READY")
        for try await event in events {
            if event["type"] as? String == "stream.open" {
                Task {
                    do {
                        let stream = try await client.acceptStream(event)
                        while !(await stream.receivedFinal) { let data = try await stream.receive(); try await stream.send(data, final: await stream.receivedFinal) }
                    } catch { print("STREAM_FAILED") }
                }
            } else if event["type"] as? String == "message", let from = event["from"] as? String, let data = event["data"] as? Data {
                _ = try await client.message(to: from, data: data, offline: event["offline"] as? Bool ?? false)
                if event["offline"] as? Bool == true { try await client.acknowledge(id: event["id"] as! String, from: from, offline: true) }
            }
        }
    }
}
