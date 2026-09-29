import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

func runNativeScreenshotProcessingRegressionTests() {
    let qr = CIFilter.qrCodeGenerator()
    qr.message = Data("clipy-native-qr".utf8)
    qr.correctionLevel = "H"
    guard let output = qr.outputImage,
          let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
            output.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
            from: output.extent.applying(CGAffineTransform(scaleX: 12, y: 12))
          ) else {
        preconditionFailure("could not make QR fixture")
    }
    do {
        let codes = try NativeScreenshotImageProcessor.recognizeQRCodes(in: image)
        precondition(codes.contains { $0.payload == "clipy-native-qr" },
                     "QR recognition lost the payload")

        let png = try NativeScreenshotImageProcessor.encode(image, as: .png)
        let source = CGImageSourceCreateWithData(png as CFData, nil)
        let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        precondition(decoded?.width == image.width && decoded?.height == image.height,
                     "PNG round trip changed dimensions")

        let adjusted = try NativeScreenshotImageProcessor.adjust(
            image, using: .init(brightness: 0.1, contrast: 1.2,
                                saturation: 0.8, sharpness: 0.3)
        )
        precondition(adjusted.width == image.width && adjusted.height == image.height,
                     "image adjustment changed dimensions")

        let colorFixture = makeEffectFixture()
        let originalPixels = pixels(of: colorFixture)
        for preset in NativeScreenshotImageProcessor.EffectPreset.allCases {
            let rendered = try NativeScreenshotImageProcessor.applyEffects(
                colorFixture, using: .init(preset: preset))
            precondition(rendered.width == colorFixture.width
                         && rendered.height == colorFixture.height,
                         "\(preset) preset changed image dimensions")
            let renderedPixels = pixels(of: rendered)
            precondition(preset == .none
                         ? renderedPixels == originalPixels
                         : renderedPixels != originalPixels,
                         "\(preset) preset did not apply its image effect")
        }

        let obscured = try NativeScreenshotImageProcessor.obscure(
            image,
            normalizedRegions: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)],
            style: .solid(.black)
        )
        precondition(obscured.width == image.width && obscured.height == image.height,
                     "censor render changed dimensions")
        let suggestions = NativeScreenshotImageProcessor.sensitiveTextSuggestions(from: [
            .init(text: "contact: person@example.com", confidence: 1,
                  bounds: CGRect(x: 0, y: 0, width: 0.5, height: 0.1)),
            .init(text: "ordinary note", confidence: 1,
                  bounds: CGRect(x: 0, y: 0.2, width: 0.5, height: 0.1))
        ])
        precondition(suggestions.count == 1,
                     "sensitive text suggestions over-selected content")
        print("Native screenshot processing regressions passed.")
    } catch {
        preconditionFailure("Native screenshot processing regression failed: \(error)")
    }
}

private func makeEffectFixture() -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 32, height: 32,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        preconditionFailure("could not make effect fixture")
    }
    for (rect, components) in [
        (CGRect(x: 0, y: 0, width: 16, height: 16), [CGFloat(0.9), 0.2, 0.1, 1]),
        (CGRect(x: 16, y: 0, width: 16, height: 16), [CGFloat(0.1), 0.8, 0.3, 1]),
        (CGRect(x: 0, y: 16, width: 16, height: 16), [CGFloat(0.15), 0.25, 0.9, 1]),
        (CGRect(x: 16, y: 16, width: 16, height: 16), [CGFloat(0.95), 0.8, 0.2, 1])
    ] {
        context.setFillColor(CGColor(colorSpace: space, components: components)!)
        context.fill(rect)
    }
    guard let image = context.makeImage() else {
        preconditionFailure("could not render effect fixture")
    }
    return image
}

private func pixels(of image: CGImage) -> [UInt8] {
    let bytesPerRow = image.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress,
                                      width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            preconditionFailure("could not inspect effect pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: image.width, height: image.height))
    }
    return bytes
}
