import CoreGraphics
import Foundation

// libwebp's simple C encoder ABI. Its source is statically linked from the
// pinned archive in third_party/libwebp; no dynamic library is loaded.
@_silgen_name("WebPEncodeRGBA")
private func webPEncodeRGBA(
    _ rgba: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ height: Int32,
    _ stride: Int32,
    _ quality: Float,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
) -> Int

@_silgen_name("WebPFree")
private func webPFree(_ pointer: UnsafeMutableRawPointer?)

enum NativeScreenshotWebPEncoder {
    enum EncodingError: Error {
        case invalidDimensions
        case renderFailed
        case encodeFailed
    }

    // WebP's bitstream limits each side to 16,383 pixels.
    static func encode(_ image: CGImage, quality: CGFloat) throws -> Data {
        let width = image.width
        let height = image.height
        guard (1...16_383).contains(width), (1...16_383).contains(height),
              height <= (512 * 1024 * 1024) / (width * 4) else {
            throw EncodingError.invalidDimensions
        }

        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: stride,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                        CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard rendered else { throw EncodingError.renderFailed }

        // Core Graphics writes premultiplied RGBA; libwebp expects straight RGBA.
        // Restore color channels before encoding to avoid dark edges at alpha.
        for offset in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            if alpha == 0 {
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
            } else if alpha < 255 {
                for channel in 0..<3 {
                    let premultiplied = Int(pixels[offset + channel])
                    pixels[offset + channel] = UInt8(min(255, (premultiplied * 255 + alpha / 2) / alpha))
                }
            }
        }

        var encoded: UnsafeMutablePointer<UInt8>?
        let clampedQuality = quality.isFinite ? min(1, max(0.1, quality)) : 0.85
        let byteCount = pixels.withUnsafeBufferPointer { buffer in
            webPEncodeRGBA(
                buffer.baseAddress,
                Int32(width), Int32(height), Int32(stride),
                Float(clampedQuality * 100),
                &encoded
            )
        }
        guard byteCount > 0, let encoded else { throw EncodingError.encodeFailed }
        defer { webPFree(encoded) }
        return Data(bytes: encoded, count: byteCount)
    }
}
