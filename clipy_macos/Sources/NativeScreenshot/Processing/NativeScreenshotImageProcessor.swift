import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Image operations for the independently implemented screenshot pipeline.
/// Coordinates for recognized and censored regions use Vision's normalized,
/// bottom-left origin so they can be stored without depending on display scale.
enum NativeScreenshotImageProcessor {
    enum ImageError: Error {
        case invalidImage
        case unavailableEncoder(String)
        case renderingFailed
    }

    enum FileFormat: String {
        case png, jpeg, heic, webp

        var type: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .webp: return .webP
            }
        }
    }

    struct TextObservation {
        let text: String
        let confidence: Float
        let bounds: CGRect
    }

    struct CodeObservation {
        let payload: String
        let bounds: CGRect
    }

    struct Adjustments {
        var brightness: Float = 0
        var contrast: Float = 1
        var saturation: Float = 1
        var sharpness: Float = 0
    }

    enum ObscureStyle {
        case solid(NSColor)
        case blur(radius: CGFloat)
        case pixelate(cellSize: CGFloat)
    }

    static func cgImage(from image: NSImage) throws -> CGImage {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        guard let data = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageError.invalidImage
        }
        return cgImage
    }

    static func encode(
        _ image: CGImage,
        as format: FileFormat,
        quality: CGFloat = 0.85
    ) throws -> Data {
        if format == .webp {
            return try NativeScreenshotWebPEncoder.encode(image, quality: quality)
        }
        let identifier = format.type.identifier
        guard let supported = CGImageDestinationCopyTypeIdentifiers() as? [String],
              supported.contains(identifier) else {
            throw ImageError.unavailableEncoder(identifier)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, identifier as CFString, 1, nil
        ) else {
            throw ImageError.unavailableEncoder(identifier)
        }
        let properties: [CFString: Any] = format == .png ? [:] : [
            kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, quality))
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.renderingFailed
        }
        return output as Data
    }

    static func recognizeText(
        in image: CGImage,
        language: ScreenshotOCRLanguage
    ) throws -> [TextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !language.recognitionLanguages.isEmpty {
            request.recognitionLanguages = language.recognitionLanguages
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { result in
            guard let candidate = result.topCandidates(1).first,
                  !candidate.string.isEmpty else { return nil }
            return TextObservation(
                text: candidate.string,
                confidence: candidate.confidence,
                bounds: result.boundingBox
            )
        }
    }

    static func recognizeQRCodes(in image: CGImage) throws -> [CodeObservation] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { result in
            guard let payload = result.payloadStringValue, !payload.isEmpty else { return nil }
            return CodeObservation(payload: payload, bounds: result.boundingBox)
        }
    }

    /// Returns suggestions only. The caller must show these boxes for review
    /// before permanently covering pixels in an exported screenshot.
    static func sensitiveTextSuggestions(
        from observations: [TextObservation]
    ) -> [CGRect] {
        let email = try? NSRegularExpression(
            pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            options: [.caseInsensitive]
        )
        let card = try? NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#)
        let phone = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        )
        return observations.compactMap { item in
            let range = NSRange(item.text.startIndex..<item.text.endIndex, in: item.text)
            let containsSensitiveValue = email?.firstMatch(in: item.text, range: range) != nil
                || card?.firstMatch(in: item.text, range: range) != nil
                || phone?.firstMatch(in: item.text, range: range) != nil
            return containsSensitiveValue ? item.bounds : nil
        }
    }

    static func adjust(_ image: CGImage, using values: Adjustments) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let color = CIFilter.colorControls()
        color.inputImage = input
        color.brightness = values.brightness
        color.contrast = values.contrast
        color.saturation = values.saturation
        guard let colored = color.outputImage else { throw ImageError.renderingFailed }
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = colored
        sharpen.sharpness = values.sharpness
        guard let output = sharpen.outputImage,
              let rendered = makeContext().createCGImage(output, from: input.extent) else {
            throw ImageError.renderingFailed
        }
        return rendered
    }

    static func obscure(
        _ image: CGImage,
        normalizedRegions: [CGRect],
        style: ObscureStyle
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ImageError.renderingFailed
        }
        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.draw(image, in: imageBounds)
        let processed: CGImage?
        switch style {
        case .solid:
            processed = nil
        case .blur(let radius):
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = CIImage(cgImage: image).clampedToExtent()
            filter.radius = Float(max(0, radius))
            processed = filter.outputImage.flatMap {
                makeContext().createCGImage($0, from: imageBounds)
            }
        case .pixelate(let cellSize):
            let filter = CIFilter.pixellate()
            filter.inputImage = CIImage(cgImage: image)
            filter.scale = Float(max(2, cellSize))
            processed = filter.outputImage.flatMap {
                makeContext().createCGImage($0, from: imageBounds)
            }
        }
        for normalized in normalizedRegions {
            let bounded = normalized.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !bounded.isNull, bounded.width > 0, bounded.height > 0 else { continue }
            let region = CGRect(
                x: bounded.minX * CGFloat(width),
                y: bounded.minY * CGFloat(height),
                width: bounded.width * CGFloat(width),
                height: bounded.height * CGFloat(height)
            ).integral
            canvas.saveGState()
            canvas.clip(to: region)
            switch style {
            case .solid(let color):
                canvas.setFillColor(color.cgColor)
                canvas.fill(region)
            case .blur, .pixelate:
                guard let processed else { throw ImageError.renderingFailed }
                canvas.draw(processed, in: imageBounds)
            }
            canvas.restoreGState()
        }
        guard let result = canvas.makeImage() else { throw ImageError.renderingFailed }
        return result
    }

    private static func makeContext() -> CIContext {
        CIContext(options: [.cacheIntermediates: false])
    }
}
