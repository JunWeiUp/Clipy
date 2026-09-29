import AppKit
import Foundation
import SwiftUI
import Translation

enum NativeScreenshotTranslationAvailability: Equatable {
    case available
    case requiresMacOS15

    static func status(forMacOSMajorVersion major: Int) -> Self {
        major >= 15 ? .available : .requiresMacOS15
    }
}

struct NativeScreenshotTranslationTarget: Identifiable {
    let code: String
    let name: String
    var id: String { code }

    /// Keep the old result window's target-language choices. The on-device
    /// framework may reject an unsupported pair and the caller shows that error.
    static let all: [Self] = [
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "pl", name: "Polish"),
        .init(code: "ru", name: "Russian"),
        .init(code: "zh-CN", name: "Chinese (Simplified)"),
        .init(code: "zh-TW", name: "Chinese (Traditional)"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "sv", name: "Swedish"),
        .init(code: "da", name: "Danish"),
        .init(code: "fi", name: "Finnish"),
        .init(code: "nb", name: "Norwegian"),
        .init(code: "uk", name: "Ukrainian"),
        .init(code: "cs", name: "Czech"),
        .init(code: "ro", name: "Romanian"),
        .init(code: "hu", name: "Hungarian"),
        .init(code: "sk", name: "Slovak"),
        .init(code: "bg", name: "Bulgarian"),
        .init(code: "hr", name: "Croatian"),
        .init(code: "id", name: "Indonesian"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "th", name: "Thai"),
        .init(code: "vi", name: "Vietnamese")
    ]

    static func appleCode(for savedCode: String) -> String {
        switch savedCode {
        case "zh-CN": return "zh-Hans"
        case "zh-TW": return "zh-Hant"
        case "nb": return "no"
        default: return savedCode
        }
    }
}

struct NativeScreenshotTranslationRequest: Identifiable {
    let id = UUID()
    let sourceText: String
    let targetCode: String
}

/// A short-lived SwiftUI host gives Apple's Translation framework a visible
/// task context. Results return to the editable OCR text view; no third-party
/// translation endpoint receives the screenshot contents.
@available(macOS 15.0, *)
struct NativeScreenshotTranslationTaskView: View {
    let request: NativeScreenshotTranslationRequest
    let onTranslated: (UUID, String) -> Void
    let onFailure: (UUID, String) -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(
                source: nil,
                target: Locale.Language(identifier:
                    NativeScreenshotTranslationTarget.appleCode(for: request.targetCode))
            ) { session in
                do {
                    let response = try await session.translate(request.sourceText)
                    await MainActor.run { onTranslated(request.id, response.targetText) }
                } catch is CancellationError {
                    // Closing the panel or picking another language cancels this request.
                } catch {
                    await MainActor.run {
                        onFailure(request.id, NativeScreenshotRecognitionLabels.text(
                            "翻译失败。请确认语言包可用后重试。",
                            "Translation failed. Check the language pack and try again."))
                    }
                }
            }
    }
}

/// The user sees the exact OCR text and explicitly opens Apple's system
/// translation UI. No translation starts on view presentation, no network
/// request is made by Clipy, and the source text is never sent to a third party.
/// Apple documents Translation as processing content on the user's device:
/// https://developer.apple.com/documentation/translation/translationsession
struct NativeScreenshotTranslationPanel: View {
    let sourceText: String

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                NativeScreenshotTranslationAvailableView(sourceText: sourceText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(NativeScreenshotRecognitionLabels.text("翻译暂不可用", "Translation unavailable"))
                        .font(.headline)
                    Text(NativeScreenshotRecognitionLabels.text(
                        "Apple 系统翻译需要 macOS 15 或更高版本。仍可复制识别文字。",
                        "Apple system translation requires macOS 15 or later. You can still copy the recognized text."))
                        .foregroundStyle(.secondary)
                    Button(NativeScreenshotRecognitionLabels.text("复制原文", "Copy source text")) {
                        copyToPasteboard(sourceText)
                    }
                    .disabled(sourceText.isEmpty)
                }
                .padding(16)
            }
        }
    }
}

@available(macOS 15.0, *)
private struct NativeScreenshotTranslationAvailableView: View {
    let sourceText: String
    @State private var showsSystemTranslation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NativeScreenshotRecognitionLabels.text("翻译识别文字", "Translate recognized text"))
                .font(.headline)
            Text(NativeScreenshotRecognitionLabels.text(
                "请先检查以下原文。点击翻译后，Apple 系统会在本机处理这段文字；首次使用可能需要下载语言包。",
                "Review the text below. When you choose Translate, Apple's system processes this text on your device. A language download may be needed first."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(sourceText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 200)
            HStack {
                Button(NativeScreenshotRecognitionLabels.text("本机翻译", "Translate on device")) {
                    showsSystemTranslation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(NativeScreenshotRecognitionLabels.text("复制原文", "Copy source text")) {
                    copyToPasteboard(sourceText)
                }
                .disabled(sourceText.isEmpty)
            }
        }
        .padding(16)
        .translationPresentation(isPresented: $showsSystemTranslation, text: sourceText)
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
