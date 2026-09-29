import Foundation
import NaturalLanguage
import SwiftUI
import Translation

enum NativeScreenshotOnDeviceTranslationError: LocalizedError {
    case requiresMacOS15
    case timedOut
    case responseCountMismatch

    var errorDescription: String? {
        switch self {
        case .requiresMacOS15:
            return NativeScreenshotRecognitionLabels.text(
                "原位翻译需要 macOS 15 或更高版本。", "In-place translation requires macOS 15 or later.")
        case .timedOut:
            return NativeScreenshotRecognitionLabels.text(
                "翻译超时。请检查语言包后重试。", "Translation timed out. Check the language pack and try again.")
        case .responseCountMismatch:
            return NativeScreenshotRecognitionLabels.text(
                "翻译结果不完整，请重试。", "The translation is incomplete. Please try again.")
        }
    }
}

/// Apple requires a SwiftUI `.translationTask` on macOS 15–25 to obtain a
/// session that may request a language download. Headless session creation is
/// only available on macOS 26+, and cannot replace the view-hosted path here.
@available(macOS 15.0, *)
enum NativeScreenshotOnDeviceTranslationService {
    static var preferredTargetCode: String {
        let saved = UserDefaults.standard.string(forKey: "translateTargetLang")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.flatMap { $0.isEmpty ? nil : $0 } ?? "en"
    }

    /// Results retain the input order, including empty and already-target-
    /// language lines. The caller owns the OCR image and any resulting edits;
    /// neither is cached by this service.
    static func translate(
        _ strings: [String],
        targetCode: String? = nil,
        using session: TranslationSession,
        timeout: TimeInterval = 120
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard !strings.isEmpty else { return [] }
        let target = NativeScreenshotTranslationTarget.appleCode(
            for: targetCode ?? preferredTargetCode)
        let indices = strings.indices.filter { index in
            let source = strings[index]
            return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !isAlreadyTargetLanguage(source, targetCode: target,
                                            declaredSource: session.sourceLanguage)
        }
        guard !indices.isEmpty else { return strings }

        let requests = indices.map {
            TranslationSession.Request(sourceText: strings[$0], clientIdentifier: String($0))
        }
        let gate = NativeScreenshotTranslationCompletionGate()
        let work = Task {
            do {
                let responses = try await session.translations(from: requests)
                try Task.checkCancellation()
                guard responses.count == requests.count else {
                    throw NativeScreenshotOnDeviceTranslationError.responseCountMismatch
                }
                var translated = strings
                let expected = Set(indices)
                var received: Set<Int> = []
                for response in responses {
                    guard let identifier = response.clientIdentifier,
                          let index = Int(identifier), expected.contains(index),
                          received.insert(index).inserted,
                          !response.targetText.isEmpty else {
                        throw NativeScreenshotOnDeviceTranslationError.responseCountMismatch
                    }
                    translated[index] = response.targetText
                }
                guard received == expected else {
                    throw NativeScreenshotOnDeviceTranslationError.responseCountMismatch
                }
                await gate.resolve(.success(translated))
            } catch {
                await gate.resolve(.failure(error))
            }
        }

        let seconds = timeout.isFinite ? max(0.1, min(timeout, 600)) : 120
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            work.cancel()
            if #available(macOS 26.0, *) { session.cancel() }
            await gate.resolve(.failure(NativeScreenshotOnDeviceTranslationError.timedOut))
        }
        defer {
            timer.cancel()
            work.cancel()
        }
        return try await withTaskCancellationHandler {
            try await gate.value()
        } onCancel: {
            work.cancel()
            timer.cancel()
            if #available(macOS 26.0, *) { session.cancel() }
            Task { await gate.resolve(.failure(CancellationError())) }
        }
    }

    private static func isAlreadyTargetLanguage(
        _ source: String,
        targetCode: String,
        declaredSource: Locale.Language?
    ) -> Bool {
        if let declaredSource {
            return languageKey(declaredSource.minimalIdentifier) == languageKey(targetCode)
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(source)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.8 else { return false }
        return languageKey(language.rawValue) == languageKey(targetCode)
    }

    private static func languageKey(_ code: String) -> String {
        let normalized = NativeScreenshotTranslationTarget.appleCode(for: code)
            .lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized.hasPrefix("zh") {
            return normalized.contains("hant") || normalized.contains("tw") || normalized.contains("hk")
                ? "zh-hant" : "zh-hans"
        }
        return String(normalized.split(separator: "-").first ?? Substring(normalized))
    }
}

@available(macOS 15.0, *)
private actor NativeScreenshotTranslationCompletionGate {
    private var continuation: CheckedContinuation<[String], Error>?
    private var resolved: Result<[String], Error>?

    func value() async throws -> [String] {
        try await withCheckedThrowingContinuation { next in
            if let resolved {
                next.resume(with: resolved)
            } else {
                continuation = next
            }
        }
    }

    func resolve(_ result: Result<[String], Error>) {
        guard resolved == nil else { return }
        resolved = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

struct NativeScreenshotOverlayTranslationRequest: Identifiable {
    let id: UUID
    let sourceLines: [String]
    let targetCode: String

    init(id: UUID = UUID(), sourceLines: [String], targetCode: String? = nil) {
        self.id = id
        self.sourceLines = sourceLines
        self.targetCode = targetCode ?? UserDefaults.standard.string(forKey: "translateTargetLang") ?? "en"
    }
}

/// Mount this in a 1×1 NSHostingView while a user-requested translation is
/// active. Replacing its request identity cancels the old SwiftUI task; the
/// callback also carries that identity so the overlay can reject stale work.
@available(macOS 15.0, *)
struct NativeScreenshotOverlayTranslationTaskView: View {
    let request: NativeScreenshotOverlayTranslationRequest
    let onTranslated: (UUID, [String]) -> Void
    let onFailure: (UUID, Error) -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(
                source: nil,
                target: Locale.Language(identifier:
                    NativeScreenshotTranslationTarget.appleCode(for: request.targetCode))
            ) { session in
                do {
                    let result = try await NativeScreenshotOnDeviceTranslationService.translate(
                        request.sourceLines, targetCode: request.targetCode, using: session)
                    try Task.checkCancellation()
                    await MainActor.run { onTranslated(request.id, result) }
                } catch is CancellationError {
                    // The overlay discarded this request or the user closed it.
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { onFailure(request.id, error) }
                }
            }
            .id(request.id)
    }
}
