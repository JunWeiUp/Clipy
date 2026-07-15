import AppKit
import Foundation

/// 缩略图仅落盘缓存，不常驻内存；使用时从磁盘按需读取。
enum HistoryThumbnailCache {
    private static let fileManager = FileManager.default

    private static var thumbnailsDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone/thumbnails", isDirectory: true)
    }

    static func thumbnail(for path: String, size: NSSize = NSSize(width: 24, height: 24)) -> NSImage? {
        let cacheKey = cacheKey(for: path, size: size)
        ensureThumbnailsDirectory()
        let diskURL = thumbnailsDirectory.appendingPathComponent("\(cacheKey).png")

        if fileManager.fileExists(atPath: diskURL.path),
           let data = try? Data(contentsOf: diskURL) {
            return autoreleasepool {
                NSImage(data: data)
            }
        }

        let maxPixel = max(1, Int(max(size.width, size.height)))
        guard let thumbnail = autoreleasepool(invoking: {
            guard let downsampled = ImageDownsampler.thumbnail(at: path, maxPixelSize: maxPixel) else {
                return nil as NSImage?
            }
            return scaledImage(downsampled, toFit: size)
        }) else { return nil }

        if let pngData = pngData(from: thumbnail) {
            try? pngData.write(to: diskURL, options: .atomic)
        }
        return thumbnail
    }

    static func removeAllThumbnailFiles() {
        ensureThumbnailsDirectory()
        guard let files = try? fileManager.contentsOfDirectory(
            at: thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    static func pruneUnreferenced(keepingSourcePaths sourcePaths: Set<String>) {
        ensureThumbnailsDirectory()
        var validPrefixes = Set<String>()
        for path in sourcePaths {
            if let hash = HistoryMediaStore.shared.contentHash(forPath: path) {
                validPrefixes.insert(hash)
            }
        }
        guard let files = try? fileManager.contentsOfDirectory(
            at: thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.hasDirectoryPath == false {
            let name = file.deletingPathExtension().lastPathComponent
            let prefix = name.split(separator: "_", maxSplits: 1).first.map(String.init) ?? ""
            if !validPrefixes.contains(prefix) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private static func ensureThumbnailsDirectory() {
        try? fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
    }

    private static func cacheKey(for path: String, size: NSSize) -> String {
        let hash = HistoryMediaStore.shared.contentHash(forPath: path)
            ?? String(UInt(bitPattern: path.hashValue), radix: 16)
        return "\(hash)_\(Int(size.width))x\(Int(size.height))"
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func scaledImage(_ image: NSImage, toFit targetSize: NSSize) -> NSImage {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }

        let scale = min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        let scaledSize = NSSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )

        let result = NSImage(size: targetSize)
        result.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: targetSize).fill()
        let origin = NSPoint(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2
        )
        image.draw(
            in: NSRect(origin: origin, size: scaledSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1.0
        )
        result.unlockFocus()
        return result
    }
}
