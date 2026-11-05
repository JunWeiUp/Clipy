import CoreGraphics
import Foundation
import ImageIO
import Vision

/// All recognition runs in a throwaway child, including empty/error cases.
/// One process at a time across history indexing and interactive recognition. No parent
/// Vision fallback: a failed worker is reported/retried by the caller, not made permanent.
enum OCRSubprocess {
    static let childModeArgument = "--clipy-ocr-child"
    static let maximumResultBytes = 2 * 1_024 * 1_024
    private static let timeout: TimeInterval = 30
    private static let processGate = DispatchSemaphore(value: 1)

    static func recognizeText(at path: String, maxPixelSize: Int, languages: [String]) -> String? {
        do {
            return try perform(OCRRequest(path: path, maxPixelSize: maxPixelSize, languages: languages), task: OCRTask()).text
        } catch {
            // Do not log image paths or recognized text.
            appLog("OCR worker failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    static func perform(_ request: OCRRequest, task: OCRTask) throws -> OCRResponse {
        // Only active work waits here (no idle timer). A cancelled interactive job
        // must not retain its staging image for the history worker's full timeout.
        while processGate.wait(timeout: .now() + 0.1) == .timedOut {
            if task.isCancelled { throw OCRServiceError.cancelled }
        }
        defer { processGate.signal() }
        guard !task.isCancelled else { throw OCRServiceError.cancelled }
        guard let executable = Bundle.main.executableURL else { throw OCRServiceError.workerFailed }
        let data = try JSONEncoder().encode(request)
        guard data.count <= 65_536 else { throw OCRServiceError.resultTooLarge }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("request.json")
        let outputURL = directory.appendingPathComponent("result.json")
        try data.write(to: inputURL)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw OCRServiceError.workerFailed
        }
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = [childModeArgument]
        process.standardInput = input
        // A dedicated result file avoids pipe deadlock AND Vision/Espresso stdout
        // diagnostics corrupting JSON (observed in repeated recognition on macOS).
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CLIPY_OCR_RESULT_PATH": outputURL.path], uniquingKeysWith: { _, new in new })
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try task.launch(process)
        defer { task.detachProcess() }
        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let start = Date()
        process.waitUntilExit()
        deadline.cancel()
        guard !task.isCancelled else { throw OCRServiceError.cancelled }
        guard process.terminationStatus == 0 else {
            throw Date().timeIntervalSince(start) >= timeout ? OCRServiceError.timedOut : OCRServiceError.workerFailed
        }
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumResultBytes else { throw OCRServiceError.resultTooLarge }
        return try JSONDecoder().decode(OCRResponse.self, from: Data(contentsOf: outputURL)).validated()
    }

    /// Branch before NSApplication initialization (also in the regression executable).
    static func runChildMode() -> Never {
        let response: OCRResponse = autoreleasepool {
            do {
                let input = try FileHandle.standardInput.read(upToCount: 65_537) ?? Data()
                guard input.count <= 65_536 else { throw OCRServiceError.resultTooLarge }
                let request = try JSONDecoder().decode(OCRRequest.self, from: input)
                guard request.maxPixelSize > 0, request.maxPixelSize <= 16_384,
                      request.matchingPatterns.count <= 32,
                      request.matchingPatterns.allSatisfy({ $0.utf8.count <= 2_048 }),
                      request.languages.count <= 32,
                      let image = downsampledCGImage(at: request.path, maxPixelSize: request.maxPixelSize) else {
                    throw OCRServiceError.invalidImage
                }
                return try recognize(image: image, request: request).validated()
            } catch {
                return OCRResponse(status: .failure, error: "recognition-failed")
            }
        }
        guard let outputPath = ProcessInfo.processInfo.environment["CLIPY_OCR_RESULT_PATH"],
              let data = try? JSONEncoder().encode(response), data.count <= maximumResultBytes else { exit(1) }
        do {
            // Parent created this 0600 file inside its unique 0700 staging directory.
            // Never use stdout for the protocol: frameworks may write diagnostics there.
            let output = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
            try output.truncate(atOffset: 0)
            try output.write(contentsOf: data)
            try output.close()
            exit(0)
        } catch { exit(1) }
    }

    private static func downsampledCGImage(at path: String, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    private static func recognize(image: CGImage, request: OCRRequest) throws -> OCRResponse {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        switch request.kind {
        case .faces:
            let detect = VNDetectFaceRectanglesRequest()
            try handler.perform([detect])
            return OCRResponse(status: .success, boxes: (detect.results ?? []).map(\.boundingBox))
        case .people:
            let detect = VNDetectHumanRectanglesRequest()
            try handler.perform([detect])
            return OCRResponse(status: .success, boxes: (detect.results ?? []).map(\.boundingBox))
        case .text, .textAndQR:
            let regexes = try request.matchingPatterns.map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
            func recognizeText(level: VNRequestTextRecognitionLevel) throws -> [OCRTextObservation] {
                let detect = VNRecognizeTextRequest()
                detect.recognitionLevel = level
                detect.usesLanguageCorrection = true
                detect.automaticallyDetectsLanguage = request.automaticLanguageDetection
                if !request.languages.isEmpty {
                    let supported = try detect.supportedRecognitionLanguages()
                    let selected = request.languages.filter { supported.contains($0) }
                    detect.recognitionLanguages = selected.isEmpty ? supported : selected
                }
                try handler.perform([detect])
                let results = detect.results ?? []
                guard results.count <= 2_000 else { throw OCRServiceError.resultTooLarge }
                var totalTextBytes = 0
                var totalMatches = 0
                return try results.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string
                    totalTextBytes += text.utf8.count
                    guard totalTextBytes <= 131_072 else { throw OCRServiceError.resultTooLarge }
                    var matches: [CGRect] = []
                    for regex in regexes {
                        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                            guard let range = Range(match.range, in: text), let box = try? candidate.boundingBox(for: range) else { continue }
                            matches.append(box.boundingBox)
                            totalMatches += 1
                            guard matches.count <= 2_000, totalMatches <= 8_000 else { throw OCRServiceError.resultTooLarge }
                        }
                    }
                    return OCRTextObservation(text: text, boundingBox: observation.boundingBox, matchedBoxes: matches)
                }
            }
            var observations: [OCRTextObservation] = []
            var textError: Error?
            do {
                do { observations = try recognizeText(level: .accurate) }
                catch let error as OCRServiceError { throw error }
                catch { observations = try recognizeText(level: .fast) }
            } catch { textError = error }
            // QR-only captures must remain usable even if a text model is unavailable.
            var codes: [String] = []
            var qrError: Error?
            if request.kind == .textAndQR {
                let detect = VNDetectBarcodesRequest()
                detect.symbologies = [.qr, .microQR]
                // Barcode support varies by OS; preserve successfully recognized text.
                do { try handler.perform([detect]) } catch { qrError = error }
                var seen = Set<String>()
                codes = (detect.results ?? []).compactMap { observation in
                    guard let text = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty, seen.insert(text).inserted else { return nil }
                    return text
                }
            }
            return try OCRResponse.recognized(observations: observations, qrCodes: codes,
                                              textError: textError, qrError: qrError)
        }
    }
}
