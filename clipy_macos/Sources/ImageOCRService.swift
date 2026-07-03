import AppKit
import Vision

enum ImageOCRService {
    private static let queue = DispatchQueue(label: "com.clipy.image-ocr", qos: .userInitiated)

    static func recognize(cgImage: CGImage, completion: @escaping (String?) -> Void) {
        queue.async {
            let text = recognizeSync(cgImage: cgImage)
            DispatchQueue.main.async {
                completion(text)
            }
        }
    }

    static func recognizeSync(cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    static func recognize(image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return recognizeSync(cgImage: cgImage)
    }
}
