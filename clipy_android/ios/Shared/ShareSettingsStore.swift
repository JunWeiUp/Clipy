import Foundation
import Darwin

struct ShareSettings: Codable {
  var name: String = "iPhone"
  var language: String = Locale.preferredLanguages.first ?? "en"
  var port: UInt16 = 5566
  var peers: [SharePeer] = []
}

enum ShareSettingsStore {
  static func read() -> ShareSettings {
    (try? ShareInboxStore.locked { root in
      let data = try Data(contentsOf: root.appendingPathComponent("settings.json"))
      return try JSONDecoder().decode(ShareSettings.self, from: data)
    }) ?? ShareSettings()
  }
  static func write(_ settings: ShareSettings) throws {
    try ShareInboxStore.locked { root in
      var bounded = settings; bounded.peers = Array(settings.peers.prefix(128))
      try JSONEncoder().encode(bounded).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
    }
  }
  static func configure(_ args: [String: Any]) throws {
    var settings = read()
    settings.name = String((args["name"] as? String ?? "iPhone").prefix(100))
    settings.language = args["language"] as? String ?? settings.language
    if let port = args["port"] as? Int, (1...65535).contains(port) { settings.port = UInt16(port) }
    let peers = (args["peers"] as? [[String: Any]] ?? []).prefix(128).compactMap { row -> SharePeer? in
      guard let id = row["peerId"] as? String, !id.isEmpty,
            let host = row["host"] as? String, validIPv4(host),
            let port = row["port"] as? Int, (1...65535).contains(port) else { return nil }
      return SharePeer(peerId: id, name: String((row["name"] as? String ?? host).prefix(100)), host: host, port: UInt16(port))
    }
    // Preserve peers explicitly discovered in the extension, replacing stale endpoints by ID.
    let ids = Set(peers.map(\.peerId))
    settings.peers = Array((peers + settings.peers.filter { !ids.contains($0.peerId) }).prefix(128))
    try write(settings)
  }
  static func validIPv4(_ value: String) -> Bool {
    var address = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
  }
  static func localIPv4() -> [String] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(first) }
    var addresses: [String] = []
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let node = current {
      defer { current = node.pointee.ifa_next }
      let value = node.pointee
      guard String(cString: value.ifa_name).hasPrefix("en"), let address = value.ifa_addr,
            address.pointee.sa_family == UInt8(AF_INET), (value.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        addresses.append(String(cString: host))
      }
    }
    return Array(Set(addresses)).sorted()
  }
}
