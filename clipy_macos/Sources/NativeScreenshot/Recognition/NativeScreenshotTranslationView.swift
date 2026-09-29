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
