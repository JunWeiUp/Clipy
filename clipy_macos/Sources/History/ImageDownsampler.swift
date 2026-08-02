import AppKit
import ImageIO

enum ImageDownsampler {
    static func thumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0 else { return nil }
        return autoreleasepool {
            guard let cgImage = createThumbnail(from: data, maxPixelSize: maxPixelSize) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    static func thumbnail(at path: String, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0,
              let data = HistoryMediaStore.shared.data(at: path) else { return nil }
        return thumbnail(from: data, maxPixelSize: maxPixelSize)
    }

    static func thumbnail(atFileURL url: URL, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0,
              let data = try? Data(contentsOf: url) else { return nil }
        return thumbnail(from: data, maxPixelSize: maxPixelSize)
    }

    static func cgImage(at path: String, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let data = HistoryMediaStore.shared.data(at: path) else { return nil }
        return autoreleasepool {
            createThumbnail(from: data, maxPixelSize: maxPixelSize)
        }
    }

    private static func createThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
