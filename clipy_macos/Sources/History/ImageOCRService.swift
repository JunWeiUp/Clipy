import Vision

enum ImageOCRService {
    /// In-process recognition. Vision keeps its models resident for the rest
    /// of the process lifetime once loaded (~100MB, not releasable), so this
    /// is only the fallback for when the OCR subprocess cannot be spawned —
    /// normal traffic goes through `OCRSubprocess`.
    static func recognizeInProcess(cgImage: CGImage, languages: ScreenshotOCRLanguage) -> String? {
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
}
