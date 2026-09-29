import CoreGraphics
import Foundation
import Vision

enum NativeScreenshotOCRLanguage {
    case english
    case chineseAndEnglish
    case automatic
}

struct NativeScreenshotRecognizedText: Identifiable {
    let id: UUID
    let text: String
    let confidence: Float
    /// Pixel rectangle in the original image, with a top-left origin.
    let bounds: CGRect

    init(id: UUID = UUID(), text: String, confidence: Float, bounds: CGRect) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.bounds = bounds
    }
}

struct NativeScreenshotQRCode: Identifiable {
    let id: UUID
    let payload: String
    /// Pixel rectangle in the original image, with a top-left origin.
    let bounds: CGRect

    init(id: UUID = UUID(), payload: String, bounds: CGRect) {
        self.id = id
        self.payload = payload
        self.bounds = bounds
    }
}

/// Stateless, on-demand Vision requests. The async forms keep OCR work off the
/// UI thread; neither the image nor recognized content is retained afterwards.
enum NativeScreenshotRecognitionService {
    static func recognizeText(
        in image: CGImage,
        language: NativeScreenshotOCRLanguage = .automatic
    ) async throws -> [NativeScreenshotRecognizedText] {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try recognizeTextSynchronously(in: image, language: language)
            try Task.checkCancellation()
            return result
        }.value
    }

    static func recognizeQRCodes(in image: CGImage) async throws -> [NativeScreenshotQRCode] {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try recognizeQRCodesSynchronously(in: image)
            try Task.checkCancellation()
            return result
        }.value
    }

    /// Synchronous entry points are useful for a caller that already owns a worker queue.
    static func recognizeTextSynchronously(
        in image: CGImage,
        language: NativeScreenshotOCRLanguage = .automatic
    ) throws -> [NativeScreenshotRecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        switch language {
        case .english:
            request.recognitionLanguages = ["en-US"]
        case .chineseAndEnglish:
            request.recognitionLanguages = ["zh-Hans", "en-US"]
        case .automatic:
            request.automaticallyDetectsLanguage = true
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return NativeScreenshotRecognizedText(
                text: candidate.string,
                confidence: candidate.confidence,
                bounds: pixelRect(from: observation.boundingBox,
                                  imageSize: CGSize(width: image.width, height: image.height))
            )
        }.sorted {
            if abs($0.bounds.minY - $1.bounds.minY) < 6 {
                return $0.bounds.minX < $1.bounds.minX
            }
            return $0.bounds.minY < $1.bounds.minY
        }
    }

    static func recognizeQRCodesSynchronously(in image: CGImage) throws -> [NativeScreenshotQRCode] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            return NativeScreenshotQRCode(
                payload: payload,
                bounds: pixelRect(from: observation.boundingBox,
                                  imageSize: CGSize(width: image.width, height: image.height))
            )
        }.sorted {
            if abs($0.bounds.minY - $1.bounds.minY) < 6 {
                return $0.bounds.minX < $1.bounds.minX
            }
            return $0.bounds.minY < $1.bounds.minY
        }
    }

    /// Vision's normalized boxes use a lower-left origin; the rest of this
    /// module uses upper-left image pixels.
    static func pixelRect(from normalized: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * imageSize.width,
            y: (1 - normalized.maxY) * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
    }
}
