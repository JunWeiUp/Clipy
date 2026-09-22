import Foundation
import Darwin
import zlib

/// A bounded, streaming ZIP subset used only for explicitly marked folder transfers.
/// Entries are stored without compression, so unpacking cannot expand the wire size.
/// Ordinary ZIP files sent as files are never unpacked automatically.
enum FolderTransferArchive {
    static let format = "zip-store-v1"
    static let maxEntries = 10_000
    static let bufferSize = 256 * 1024

    enum Failure: Error {
        case invalidArchive, unsupportedItem, tooLarge, sourceChanged
    }

    struct Prepared {
        let url: URL
        let folderName: String
        let temporaryDirectory: URL

        func remove() { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private struct Entry: Equatable {
        let name: Data
        let size: UInt32
        let crc: UInt32
        let offset: UInt32
        let isDirectory: Bool
        let mode: UInt32
    }

    /// Private snapshot; the user's directory is never modified.
    static func prepare(_ source: URL, maxBytes: Int) throws -> Prepared {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.standardizedFileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsupportedItem }
        // DirectoryEnumerator canonicalizes /var -> /private/var on macOS.
        // Canonicalize the base too before computing relative entry names.
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        let folderName = SyncManager.sanitizeFileName(root.lastPathComponent)
        _ = try components(folderName)
        let temp = fm.temporaryDirectory.appendingPathComponent("clipy-folder-\(UUID().uuidString)", isDirectory: true)
        let rootPath = root.resolvingSymlinksInPath().path
        guard rootPath != "/", !temp.resolvingSymlinksInPath().path.hasPrefix(rootPath + "/")
        else { throw Failure.unsupportedItem }
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let prepared = Prepared(url: temp.appendingPathComponent("folder.zip"), folderName: folderName, temporaryDirectory: temp)
        do {
            try write(root, to: prepared.url, folderName: folderName, maxBytes: maxBytes)
            return prepared
        } catch {
            prepared.remove()
            throw error
        }
    }

    private static func write(_ source: URL, to archive: URL, folderName: String, maxBytes: Int) throws {
        let fd = open(archive.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unsupportedItem }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var entries: [Entry] = []
        var position = 0
        var centralSize = 0

        func append(_ data: Data) throws {
            guard data.count <= maxBytes - position else { throw Failure.tooLarge }
            try output.write(contentsOf: data)
            position += data.count
        }

        func add(_ url: URL, path: String) throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else { throw Failure.unsupportedItem }
            let isDirectory = type == .typeDirectory
            _ = try components(path)
            let name = Data((path + (isDirectory ? "/" : "")).utf8)
            let size = isDirectory ? 0 : (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard entries.count < maxEntries, size >= 0, size <= maxBytes,
                  position + 30 + name.count + size + centralSize + 46 + name.count + 22 <= maxBytes
            else { throw Failure.tooLarge }
            let offset = position
            var header = Data()
            header.le32(0x04034b50); header.le16(20); header.le16(0x800); header.le16(0)
            header.le16(0); header.le16(33); header.le32(0)
            header.le32(UInt32(size)); header.le32(UInt32(size)); header.le16(UInt16(name.count)); header.le16(0)
            try append(header); try append(name)
            var checksum: UInt32 = 0
            if !isDirectory {
                // Do not follow a symlink swapped in after directory enumeration.
                let inputFD = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard inputFD >= 0 else { throw Failure.unsupportedItem }
                let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
                defer { try? input.close() }
                var info = stat()
                guard fstat(inputFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == size
                else { throw Failure.sourceChanged }
                var remaining = size
                while remaining > 0 {
                    let data = try read(input, count: min(bufferSize, remaining))
                    checksum = crc(data, seed: checksum)
                    try append(data)
                    remaining -= data.count
                }
                guard try input.read(upToCount: 1)?.isEmpty != false else { throw Failure.sourceChanged }
            }
            // Patch CRC after the streamed read; no second pass over source data.
            try output.seek(toOffset: UInt64(offset + 14))
            var checksumData = Data(); checksumData.le32(checksum)
            try output.write(contentsOf: checksumData)
            try output.seek(toOffset: UInt64(position))
            let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
            let mode: UInt32 = (isDirectory ? 0o040000 : 0o100000) | (permissions & 0o777)
            entries.append(Entry(name: name, size: UInt32(size), crc: checksum,
                                 offset: UInt32(offset), isDirectory: isDirectory, mode: mode))
            centralSize += 46 + name.count
        }

        try add(source, path: folderName)
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, error in enumerationError = error; return false })
        else { throw Failure.unsupportedItem }
        for case let enumeratedURL as URL in iterator {
            let url = enumeratedURL.standardizedFileURL
            guard url.path.hasPrefix(source.path + "/") else { throw Failure.sourceChanged }
            let relative = String(url.path.dropFirst(source.path.count + 1))
            try add(url, path: folderName + "/" + relative)
        }
        if let enumerationError { throw enumerationError }
        let centralOffset = position
        for entry in entries { try append(centralRecord(entry)) }
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0)
        end.le16(UInt16(entries.count)); end.le16(UInt16(entries.count))
        end.le32(UInt32(position - centralOffset)); end.le32(UInt32(centralOffset)); end.le16(0)
        try append(end)
    }

    /// Decode only our exact ZIP subset into a private, new directory. Validate
    /// every header, path, byte count and CRC before publishing the folder.
    static func unpack(_ archive: URL, folderName: String, in parent: URL, maxBytes: Int) throws -> URL {
        let fm = FileManager.default
        let temp = parent.appendingPathComponent(".folder-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        guard length <= maxBytes, length >= 22 else { throw Failure.invalidArchive }
        try input.seek(toOffset: length - 22)
        let end = try read(input, count: 22)
        let count = Int(end.u16(10)), centralSize = Int(end.u32(12)), centralOffset = Int(end.u32(16))
        guard end.u32(0) == 0x06054b50, end.u16(4) == 0, end.u16(6) == 0,
              end.u16(8) == count, end.u16(20) == 0, count > 0, count <= maxEntries,
              centralOffset + centralSize + 22 == length else { throw Failure.invalidArchive }
        _ = try components(folderName)
        guard !folderName.contains("/") else { throw Failure.invalidArchive }
        try input.seek(toOffset: UInt64(centralOffset))
        var entries: [Entry] = []
        var paths = Set<String>()
        for _ in 0..<count {
            let header = try read(input, count: 46)
            let nameLength = Int(header.u16(28))
            guard header.u32(0) == 0x02014b50, header.u16(4) == 0x0314, header.u16(6) == 20,
                  header.u16(8) == 0x800, header.u16(10) == 0, header.u16(30) == 0,
                  header.u16(32) == 0, header.u16(34) == 0, header.u32(20) == header.u32(24),
                  nameLength > 0, nameLength <= 4096 else { throw Failure.invalidArchive }
            let name = try read(input, count: nameLength)
            guard let path = String(data: name, encoding: .utf8) else { throw Failure.invalidArchive }
            let parts = try components(path)
            let isDirectory = path.hasSuffix("/")
            let mode = header.u32(38) >> 16
            guard parts.first == folderName, paths.insert(parts.joined(separator: "/")).inserted,
                  (mode & 0o170000) == (isDirectory ? 0o040000 : 0o100000),
                  !isDirectory || header.u32(24) == 0 else { throw Failure.invalidArchive }
            entries.append(Entry(name: name, size: header.u32(24), crc: header.u32(16),
                                 offset: header.u32(42), isDirectory: isDirectory, mode: mode))
        }
        guard try input.offset() == length - 22,
              entries.first?.name == Data((folderName + "/").utf8) else { throw Failure.invalidArchive }
        var position = 0
        for entry in entries {
            guard entry.offset == position,
                  position + 30 + entry.name.count + Int(entry.size) <= centralOffset else { throw Failure.invalidArchive }
            try input.seek(toOffset: UInt64(position))
            let header = try read(input, count: 30)
            guard header.u32(0) == 0x04034b50, header.u16(4) == 20,
                  header.u16(6) == 0x800, header.u16(8) == 0, header.u32(14) == entry.crc,
                  header.u32(18) == entry.size, header.u32(22) == entry.size,
                  header.u16(26) == entry.name.count, header.u16(28) == 0,
                  try read(input, count: entry.name.count) == entry.name else { throw Failure.invalidArchive }
            let path = String(data: entry.name, encoding: .utf8)!
            let target = temp.appendingPathComponent(path)
            if entry.isDirectory {
                // Parent-before-child, no implicit directories or duplicate aliases.
                guard !fm.fileExists(atPath: target.path) else { throw Failure.invalidArchive }
                try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                guard entry.crc == 0 else { throw Failure.invalidArchive }
            } else {
                let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw Failure.invalidArchive }
                let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? output.close() }
                var remaining = Int(entry.size), checksum: UInt32 = 0
                while remaining > 0 {
                    let data = try read(input, count: min(bufferSize, remaining))
                    checksum = crc(data, seed: checksum)
                    try output.write(contentsOf: data)
                    remaining -= data.count
                }
                guard checksum == entry.crc else { throw Failure.invalidArchive }
                // Preserve executability, never restore setuid/setgid or foreign ownership.
                guard fchmod(fd, mode_t(entry.mode & 0o777) | 0o600) == 0 else { throw Failure.invalidArchive }
            }
            position += 30 + entry.name.count + Int(entry.size)
        }
        guard position == centralOffset else { throw Failure.invalidArchive }
        // Folder names may contain dots; append collision suffix after the whole name.
        let destination = SyncManager.dedupeDestination(in: parent, fileName: folderName, isDirectory: true)
        try fm.moveItem(at: temp.appendingPathComponent(folderName), to: destination)
        return destination
    }

    private static func components(_ path: String) throws -> [String] {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.components(separatedBy: "/")
        guard !trimmed.isEmpty, path.utf8.count <= 4096, parts.count <= 128,
              !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw Failure.invalidArchive }
        return parts
    }

    private static func centralRecord(_ entry: Entry) -> Data {
        var data = Data()
        data.le32(0x02014b50); data.le16(0x0314); data.le16(20); data.le16(0x800); data.le16(0)
        data.le16(0); data.le16(33); data.le32(entry.crc); data.le32(entry.size); data.le32(entry.size)
        data.le16(UInt16(entry.name.count)); data.le16(0); data.le16(0); data.le16(0); data.le16(0)
        data.le32((entry.mode << 16) | (entry.isDirectory ? 0x10 : 0)); data.le32(entry.offset)
        data.append(entry.name)
        return data
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let bytes = try handle.read(upToCount: count - data.count), !bytes.isEmpty else { throw Failure.invalidArchive }
            data.append(bytes)
        }
        return data
    }

    private static func crc(_ data: Data, seed: UInt32) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(uLong(seed), $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8) }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | (UInt32(u16(offset + 2)) << 16) }
}
