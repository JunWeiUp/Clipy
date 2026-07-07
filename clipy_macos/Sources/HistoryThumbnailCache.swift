import AppKit
import Foundation

enum HistoryThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func thumbnail(for path: String, size: NSSize = NSSize(width: 24, height: 24)) -> NSImage? {
        let key = "\(path)_\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let data = HistoryMediaStore.shared.data(at: path),
              let source = NSImage(data: data) else { return nil }
        let thumbnail = scaledImage(source, toFit: size)
        let cost = Int(size.width * size.height * 4)
        cache.setObject(thumbnail, forKey: key, cost: cost)
        return thumbnail
    }

    static func clear() {
        cache.removeAllObjects()
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
