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
        guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        image.size = size
        let cost = Int(size.width * size.height * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    static func clear() {
        cache.removeAllObjects()
    }
}
