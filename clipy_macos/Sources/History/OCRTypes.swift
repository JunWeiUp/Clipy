import Foundation
import CoreGraphics

/// Wire values only: no Vision objects (and therefore no model ownership) escape the worker.
enum OCRRequestKind: String, Codable { case text, textAndQR, faces, people }

struct OCRTextObservation: Codable, Equatable {
    let text: String
    let boundingBox: CGRect
    /// Exact substring rectangles for requested PII patterns, computed inside Vision's process.
    var matchedBoxes: [CGRect] = []
}

struct OCRRequest: Codable {
    let path: String
    let maxPixelSize: Int
    var languages: [String] = []
    var kind: OCRRequestKind = .text
    var matchingPatterns: [String] = []
    var automaticLanguageDetection: Bool = false
}

struct OCRResponse: Codable {
    enum Status: String, Codable { case success, failure }
    let status: Status
    var observations: [OCRTextObservation] = []
    var qrCodes: [String] = []
    var boxes: [CGRect] = []
    var error: String?

    var text: String { observations.map(\.text).joined(separator: "\n") }

    /// Preserve partial OCR/QR results, but never disguise a failed empty scan as success.
    static func recognized(observations: [OCRTextObservation], qrCodes: [String],
                           textError: Error?, qrError: Error?) throws -> OCRResponse {
        if observations.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), qrCodes.isEmpty {
            if let textError { throw textError }
            if let qrError { throw qrError }
        }
        return OCRResponse(status: .success, observations: observations, qrCodes: qrCodes)
    }

    /// Empty recognition is a successful result, never a reason to load Vision in the parent.
    func validated() throws -> OCRResponse {
        guard status == .success else { throw OCRServiceError.workerFailed }
        guard observations.count <= 2_000, qrCodes.count <= 128, boxes.count <= 2_000,
              observations.reduce(0, { $0 + $1.text.utf8.count }) <= 131_072,
              observations.allSatisfy({ $0.matchedBoxes.count <= 2_000 && Self.valid($0.boundingBox) && $0.matchedBoxes.allSatisfy(Self.valid) }),
              boxes.allSatisfy(Self.valid) else { throw OCRServiceError.resultTooLarge }
        return self
    }

    private static func valid(_ box: CGRect) -> Bool {
        [box.origin.x, box.origin.y, box.width, box.height].allSatisfy(\.isFinite)
            && box.width >= 0 && box.height >= 0
    }
}

enum OCRServiceError: Error, LocalizedError {
    case cancelled, busy, invalidImage, workerFailed, timedOut, resultTooLarge
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Recognition was cancelled."
        case .busy: return "Recognition is busy. Please try again after the current task finishes."
        case .invalidImage: return "The image could not be prepared for recognition."
        case .workerFailed: return "Recognition could not complete. Please try again."
        case .timedOut: return "Recognition timed out. Please try a smaller selection."
        case .resultTooLarge: return "The recognition result is too large. Please use a smaller selection."
        }
    }
}

/// Thread-safe cancellation shared by the queue, short-lived process and UI delivery.
/// Owners cancel on replacement/close; the queue clears its cancellation hook on completion.
final class OCRTask {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let child = process
        let handler = cancellationHandler
        cancellationHandler = nil
        lock.unlock()
        // The child only reads input and writes its disposable result; immediate kill is safe.
        // Killing/reaping it also bounds cancellation latency when Vision itself is hung.
        if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        handler?()
    }

    func onCancel(_ handler: (() -> Void)?) {
        lock.lock()
        cancellationHandler = cancelled ? nil : handler
        let invoke = cancelled
        lock.unlock()
        if invoke { handler?() }
    }

    func launch(_ child: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw OCRServiceError.cancelled }
        try child.run()
        process = child
    }

    func detachProcess() { lock.lock(); process = nil; lock.unlock() }
}
