import Foundation
import Darwin

/// Used by the app and Share Extension. File locks serialize cross-process writes;
/// only atomically published manifests are visible to Flutter. Never holds file bytes in memory.
enum ShareInboxStore {
  static let maxBytes = ShareTransferLimits.fileBytes
  struct SharedFile: Codable {
    let relativePath: String
    let name: String
    let size: Int64
  }
  struct Batch: Codable {
    let id: String
    let files: [SharedFile]
    let error: String
  }
  enum Failure: Error { case unavailable, limit, invalid, tooLarge, storageFull, cancelled }

  static func root() throws -> URL {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "ClipyAppGroup") as? String,
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw Failure.unavailable
    }
    return container.appendingPathComponent("IncomingShares", isDirectory: true)
  }

  static func locked<T>(_ body: (URL) throws -> T) throws -> T {
    var root = try root()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try root.setResourceValues(values)
    let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw Failure.unavailable }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw Failure.unavailable }
    defer { flock(fd, LOCK_UN) }
    return try body(root)
  }

  static func begin() throws -> String {
    try locked { root in
      let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
        .filter { UUID(uuidString: $0.lastPathComponent) != nil }
      // Orphaned imports / unopened shares expire on the next user-triggered import (no timer).
      for directory in directories {
        let date = try directory.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
        if Date().timeIntervalSince(date) > 24 * 60 * 60 { try? FileManager.default.removeItem(at: directory) }
      }
      let remaining = directories.filter { FileManager.default.fileExists(atPath: $0.path) }
      guard remaining.count < 4 else { throw Failure.limit }
      let id = UUID().uuidString
      try FileManager.default.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: true)
      return id
    }
  }

  static func copy(_ source: URL, name: String, batchID: String, index: Int,
                   cancelled: () -> Bool = { false }) throws -> SharedFile {
    try locked { root in
      guard UUID(uuidString: batchID) != nil, index < 32 else { throw Failure.invalid }
      let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalid }
      let sourceSize = Int64(values.fileSize ?? 0)
      guard sourceSize <= maxBytes else { throw Failure.tooLarge }
      let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
      if let capacity, sourceSize + ShareTransferLimits.diskReserve > capacity { throw Failure.storageFull }
      let used = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
        .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
      let safe = String(name.components(separatedBy: CharacterSet(charactersIn: "/\\").union(.controlCharacters)).joined(separator: "_").prefix(120))
      let filename = safe.isEmpty || safe == "." || safe == ".." ? "shared-file" : safe
      let relativePath = "\(index)/\(filename)"
      let destination = root.appendingPathComponent(batchID).appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw Failure.unavailable }
      var success = false
      defer { if !success { try? FileManager.default.removeItem(at: destination) } }
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      var size: Int64 = 0
      while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
        if cancelled() { throw Failure.cancelled }
        size += Int64(data.count)
        guard size <= maxBytes else { throw Failure.tooLarge }
        guard used + size <= ShareTransferLimits.stagingBytes else { throw Failure.storageFull }
        try output.write(contentsOf: data)
      }
      success = true
      return SharedFile(relativePath: relativePath, name: filename, size: size)
    }
  }

  static func publish(_ batch: Batch) throws {
    try locked { root in
      guard UUID(uuidString: batch.id) != nil else { throw Failure.invalid }
      let data = try JSONEncoder().encode(batch)
      try data.write(to: root.appendingPathComponent(batch.id).appendingPathComponent("manifest.json"), options: .atomic)
    }
  }

  static func next() throws -> [String: Any]? {
    try locked { root in
      let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
        .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
      for directory in directories {
        let manifest = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let batch = try? JSONDecoder().decode(Batch.self, from: data),
              batch.id == directory.lastPathComponent else { continue }
        var files: [[String: Any]] = []
        for file in batch.files {
          let path = directory.appendingPathComponent(file.relativePath).standardizedFileURL
          guard path.path.hasPrefix(directory.path + "/"), FileManager.default.fileExists(atPath: path.path) else { continue }
          files.append(["path": path.path, "name": file.name, "size": file.size])
        }
        return ["id": batch.id, "files": files, "error": files.count == batch.files.count ? batch.error : "unreadable"]
      }
      return nil
    }
  }

  static func remove(_ id: String) throws {
    guard UUID(uuidString: id) != nil else { throw Failure.invalid }
    try locked { root in
      let directory = root.appendingPathComponent(id)
      if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
  }
}
