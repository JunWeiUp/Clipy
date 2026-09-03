import CoreGraphics
import Foundation
import ImageIO
import Vision

/// OCR in a throwaway child process.
///
/// Vision keeps its recognition models (~100MB after first use) resident for
/// the lifetime of the calling process and offers no API to release them. The
/// main app is a permanently-resident menu bar agent, so loading Vision there
/// raised its idle footprint floor permanently. Instead the parent spawns this
/// same executable with `--clipy-ocr-child`, streams a JSON request batch
/// through stdin and reads JSON results from stdout; when the child exits,
/// every byte of Vision memory goes back to the system. If the child cannot be
/// spawned or the protocol fails, callers fall back to in-process Vision so
/// recognition never breaks — at the cost of the residency this exists to avoid.
enum OCRSubprocess {
    static let childModeArgument = "--clipy-ocr-child"
    /// Generous: accurate-level recognition of a 2048px image takes well under
    /// a second on Apple Silicon; the timeout only guards a hung child.
    private static let timeout: TimeInterval = 30

    private struct Request: Codable {
        let path: String
        let maxPixelSize: Int
        let languages: [String]
    }

    private struct Result: Codable {
        let ok: Bool
        let text: String?
    }

    // MARK: - Parent side

    /// Recognizes text in the image file at `path` (plain readable bytes —
    /// decrypt encrypted media before calling). Returns nil when the child
    /// could not be used, so callers can fall back.
    static func recognizeText(at path: String, maxPixelSize: Int, languages: [String]) -> String? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let request = Request(path: path, maxPixelSize: maxPixelSize, languages: languages)
        guard let requestData = try? JSONEncoder().encode([request]) else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = [childModeArgument]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        input.fileHandleForWriting.write(requestData)
        try? input.fileHandleForWriting.close()

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let results = try? JSONDecoder().decode([Result].self, from: data),
              let result = results.first else { return nil }
        return result.ok ? result.text : nil
    }

    /// In-memory image variant: encodes a temporary PNG and routes it through
    /// the child, falling back to in-process Vision when that is unavailable.
    static func recognize(cgImage: CGImage, languages: ScreenshotOCRLanguage) -> String? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-ocr-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, "public.png" as CFString, 1, nil) else {
            return ImageOCRService.recognizeInProcess(cgImage: cgImage, languages: languages)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return ImageOCRService.recognizeInProcess(cgImage: cgImage, languages: languages)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let text = recognizeText(
            at: tempURL.path,
            maxPixelSize: max(cgImage.width, cgImage.height),
            languages: languages.recognitionLanguages) {
            return text
        }
        return ImageOCRService.recognizeInProcess(cgImage: cgImage, languages: languages)
    }

    // MARK: - Child side (runs before any AppKit initialization)

    /// Entry for `--clipy-ocr-child`, branched at the very top of main.swift.
    /// Reads `[Request]` JSON from stdin, writes `[Result]` JSON to stdout.
    /// Must stay free of AppKit singletons — it runs instead of
    /// `NSApplication.shared`, and its whole process is discarded afterwards.
    static func runChildMode() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var results: [Result] = []
        if let requests = try? JSONDecoder().decode([Request].self, from: input) {
            for request in requests {
                guard let cgImage = downsampledCGImage(at: request.path, maxPixelSize: request.maxPixelSize) else {
                    results.append(Result(ok: false, text: nil))
                    continue
                }
                results.append(Result(ok: true, text: childRecognize(cgImage: cgImage, languages: request.languages)))
            }
        }
        if let data = try? JSONEncoder().encode(results) {
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }

    private static func downsampledCGImage(at path: String, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func childRecognize(cgImage: CGImage, languages: [String]) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Auto mode: leave recognitionLanguages empty so Vision picks all
        // supported languages; otherwise filter the requested tags to what
        // this OS actually supports (mirrors ImageOCRService's old logic).
        if !languages.isEmpty {
            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            request.recognitionLanguages = languages.filter { supported.contains($0) }
            if request.recognitionLanguages.isEmpty {
                request.recognitionLanguages = supported
            }
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
