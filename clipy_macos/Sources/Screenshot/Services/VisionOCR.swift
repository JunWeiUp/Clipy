import Foundation
import CoreGraphics

struct QRCodePayload: Equatable {
    let value: String

    var url: URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

struct OCRScanResult {
    let text: String
    let qrCodes: [QRCodePayload]
    var error: Error? = nil

    var copyText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return text }
        return qrCodes.map(\.value).joined(separator: "\n")
    }
}

/// Screenshot-facing facade. All callbacks arrive on main, and cancellation suppresses
/// queued delivery. Vision and its accurate/fast fallback run only in the child process.
enum VisionOCR {
    @discardableResult
    static func performTextRecognition(
        cgImage: CGImage,
        matchingPatterns: [String] = [],
        completionHandler: @escaping ([OCRTextObservation], Error?) -> Void
    ) -> OCRTask {
        submit(cgImage, kind: .text, patterns: matchingPatterns) { result in
            switch result {
            case .success(let value): completionHandler(value.observations, nil)
            case .failure(let error): completionHandler([], error)
            }
        }
    }

    @discardableResult
    static func performTextAndQRCodeRecognition(
        cgImage: CGImage,
        completionHandler: @escaping (OCRScanResult) -> Void
    ) -> OCRTask {
        submit(cgImage, kind: .textAndQR) { result in
            switch result {
            case .success(let value):
                completionHandler(OCRScanResult(text: value.text, qrCodes: value.qrCodes.map { QRCodePayload(value: $0) }))
            case .failure(let error): completionHandler(OCRScanResult(text: "", qrCodes: [], error: error))
            }
        }
    }

    @discardableResult
    static func performDetection(cgImage: CGImage, kind: OCRRequestKind,
                                 completionHandler: @escaping ([CGRect], Error?) -> Void) -> OCRTask {
        submit(cgImage, kind: kind) { result in
            switch result {
            case .success(let value): completionHandler(value.boxes, nil)
            case .failure(let error): completionHandler([], error)
            }
        }
    }

    private static func submit(_ image: CGImage, kind: OCRRequestKind, patterns: [String] = [],
                               completion: @escaping (Result<OCRResponse, Error>) -> Void) -> OCRTask {
        OCRRecognitionQueue.shared.submit(image: image,
            request: OCRRequest(path: "", maxPixelSize: min(16_384, max(image.width, image.height)),
                                kind: kind, matchingPatterns: patterns, automaticLanguageDetection: true),
            completion: completion)
    }
}
