import AppKit
import Vision

enum ImageOCRService {
    private static let queue = DispatchQueue(label: "com.clipy.image-ocr", qos: .userInitiated)

    static func recognize(cgImage: CGImage, completion: @escaping (String?) -> Void) {
        recognize(cgImage: cgImage, languages: PreferencesManager.shared.screenshotOCRLanguage, completion: completion)
    }

    static func recognize(
        cgImage: CGImage,
        languages: ScreenshotOCRLanguage,
        completion: @escaping (String?) -> Void
    ) {
        queue.async {
            let text = recognizeSync(cgImage: cgImage, languages: languages)
            DispatchQueue.main.async {
                completion(text)
            }
        }
    }

    static func recognizeSync(cgImage: CGImage) -> String? {
        recognizeSync(cgImage: cgImage, languages: PreferencesManager.shared.screenshotOCRLanguage)
    }

    static func recognizeSync(cgImage: CGImage, languages: ScreenshotOCRLanguage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Auto mode: leave recognitionLanguages empty so Vision picks all supported languages.
        let tags = languages.recognitionLanguages
        if !tags.isEmpty {
            // `supportedRecognitionLanguages` is a throwing property; resolve it once.
            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            // VNRecognizeTextRequest will filter to the ones it actually supports on this OS.
            request.recognitionLanguages = tags.filter { supported.contains($0) }
            if request.recognitionLanguages.isEmpty {
                // Fall back to whatever the OS supports for the chosen level/locale.
                request.recognitionLanguages = supported
            }
        }
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
