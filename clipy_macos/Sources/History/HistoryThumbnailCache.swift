import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        guard let rendered = autoreleasepool(invoking: {
            guard let downsampled = ImageDownsampler.cgImage(at: path, maxPixelSize: maxPixel) else {
                return nil as CGImage?
            }
            return centered(downsampled, in: size)
        }) else { return nil }

        let thumbnail = NSImage(cgImage: rendered, size: size)
        if let pngData = pngData(from: rendered) {
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

    private static func pngData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Letterboxes `image` into `targetSize`.
    ///
    /// Uses CoreGraphics rather than `NSImage.lockFocus()`: thumbnails are built
    /// on a background queue, and lockFocus touches the shared AppKit graphics
    /// state (and picks the backing scale of whichever display happens to be
    /// attached), neither of which is safe or predictable off the main thread.
    private static func centered(_ image: CGImage, in targetSize: NSSize) -> CGImage? {
        let width = max(1, Int(targetSize.width.rounded()))
        let height = max(1, Int(targetSize.height.rounded()))
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return image }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        let scale = min(CGFloat(width) / sourceWidth, CGFloat(height) / sourceHeight)
        let drawWidth = max(1, (sourceWidth * scale).rounded(.down))
        let drawHeight = max(1, (sourceHeight * scale).rounded(.down))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (CGFloat(width) - drawWidth) / 2,
            y: (CGFloat(height) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        ))
        return context.makeImage() ?? image
    }
}
