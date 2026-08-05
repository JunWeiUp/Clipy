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
        guard maxPixelSize > 0, let cgImage = cgImage(at: path, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func thumbnail(atFileURL url: URL, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0,
              let data = try? Data(contentsOf: url) else { return nil }
        return thumbnail(from: data, maxPixelSize: maxPixelSize)
    }

    /// Prefers a URL-backed image source so ImageIO can map the file and decode
    /// only what the thumbnail needs. Reading the whole file into `Data` first
    /// meant a 24x24 menu icon still had to materialize the full-size image
    /// (tens of MB for a 4K capture). Encrypted files have no such shortcut —
    /// GCM must authenticate the whole ciphertext — so they fall back to bytes.
    static func cgImage(at path: String, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        return autoreleasepool {
            let url = URL(fileURLWithPath: path)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let thumbnail = createThumbnail(from: source, maxPixelSize: maxPixelSize) {
                return thumbnail
            }
            guard let data = HistoryMediaStore.shared.data(at: path) else { return nil }
            return createThumbnail(from: data, maxPixelSize: maxPixelSize)
        }
    }

    private static func createThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return createThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func createThumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
