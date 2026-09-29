import CoreGraphics
import Foundation
import ImageIO

func runNativeScreenshotWebPRegressionTests() {
    let width = 128
    let height = 128
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { preconditionFailure("WebP fixture context unavailable") }
    for row in 0..<height {
        for column in 0..<width {
            let red = CGFloat((row * 37 + column * 19) % 256) / 255
            let blue = CGFloat((row * 11 + column * 71) % 256) / 255
            let alpha: CGFloat = (row + column) % 7 == 0 ? 0.5 : 1
            context.setFillColor(CGColor(red: red, green: 0.4, blue: blue, alpha: alpha))
            context.fill(CGRect(x: column, y: row, width: 1, height: 1))
        }
    }
    guard let image = context.makeImage() else {
        preconditionFailure("WebP fixture image unavailable")
    }
    do {
        let low = try NativeScreenshotImageProcessor.encode(image, as: .webp, quality: 0.15)
        let high = try NativeScreenshotImageProcessor.encode(image, as: .webp, quality: 0.95)
        precondition(low.prefix(4) == Data("RIFF".utf8))
        precondition(low[8..<12] == Data("WEBP".utf8))
        precondition(high.count > low.count, "WebP quality control is ineffective")
        guard let source = CGImageSourceCreateWithData(high as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            preconditionFailure("ImageIO could not decode encoded WebP")
        }
        precondition(decoded.width == width && decoded.height == height,
                     "WebP round trip changed dimensions")
        precondition(decoded.alphaInfo != .none && decoded.alphaInfo != .noneSkipLast,
                     "WebP round trip discarded transparency")
        print("Native screenshot WebP regressions passed.")
    } catch {
        preconditionFailure("Native screenshot WebP regression failed: \(error)")
    }
}
