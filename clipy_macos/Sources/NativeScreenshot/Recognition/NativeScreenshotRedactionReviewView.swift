import AppKit
import CoreGraphics
import SwiftUI

/// Localized labels are intentionally injected only at the presentation layer;
/// detection and saved suggestions do not retain sensitive OCR strings.
enum NativeScreenshotRecognitionLabels {
    static var usesChinese: Bool { NativeScreenshotUserText.usesChinese }

    static func text(_ chinese: String, _ english: String) -> String {
        usesChinese ? chinese : english
    }

    static func category(_ category: NativeScreenshotRedactionCategory) -> String {
        usesChinese ? category.chineseTitle : category.title
    }
}

/// This view never calls `confirm` until the user presses its explicit button.
/// Dismissing the review leaves `sourceImage` unchanged.
struct NativeScreenshotRedactionReviewView: View {
    let review: NativeScreenshotRedactionReview
    let onConfirm: (CGImage) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<UUID>
    @State private var previewImage: CGImage?
    @State private var errorMessage: String?

    init(
        review: NativeScreenshotRedactionReview,
        onConfirm: @escaping (CGImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.review = review
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selectedIDs = State(initialValue: review.allSuggestionIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NativeScreenshotRecognitionLabels.text("检查敏感信息遮挡", "Review sensitive information"))
                .font(.title2.weight(.semibold))
            Text(NativeScreenshotRecognitionLabels.text(
                "红框只是预览。检查每处建议，确认后才会把选中区域烧录到图片中。",
                "Red boxes are previews. Review every suggestion; selected areas are permanently covered only after confirmation."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Group {
                if let previewImage {
                    Image(nsImage: NSImage(cgImage: previewImage,
                                           size: NSSize(width: previewImage.width,
                                                        height: previewImage.height)))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .accessibilityLabel(NativeScreenshotRecognitionLabels.text(
                            "待检查的遮挡预览", "Redaction review preview"))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 440)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if review.suggestions.isEmpty {
                Text(NativeScreenshotRecognitionLabels.text(
                    "未发现可建议的敏感信息；请手工检查图片。",
                    "No sensitive text suggestions were found. Check the image manually."))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(review.suggestions) { suggestion in
                            Toggle(isOn: Binding(
                                get: { selectedIDs.contains(suggestion.id) },
                                set: { isOn in
                                    if isOn { selectedIDs.insert(suggestion.id) }
                                    else { selectedIDs.remove(suggestion.id) }
                                }
                            )) {
                                Text("\(NativeScreenshotRecognitionLabels.category(suggestion.category)) · \(NativeScreenshotRecognitionLabels.text("第", "Line "))\(suggestion.lineNumber)\(NativeScreenshotRecognitionLabels.usesChinese ? " 行" : "")")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button(NativeScreenshotRecognitionLabels.text("取消", "Cancel"), action: onCancel)
                Button(NativeScreenshotRecognitionLabels.text("确认并遮挡", "Confirm redaction")) {
                    do {
                        let result = try review.confirm(selectedIDs: selectedIDs)
                        onConfirm(result)
                    } catch {
                        errorMessage = NativeScreenshotRecognitionLabels.text(
                            "无法生成遮挡图片。原图未更改。",
                            "Could not create the redacted image. The original is unchanged.")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(20)
        .onAppear(perform: refreshPreview)
        .onChange(of: selectedIDs) { _ in refreshPreview() }
    }

    private func refreshPreview() {
        do {
            previewImage = try review.previewImage(selectedIDs: selectedIDs)
            errorMessage = nil
        } catch {
            previewImage = nil
            errorMessage = NativeScreenshotRecognitionLabels.text(
                "无法生成预览。原图未更改。",
                "Could not create a preview. The original is unchanged.")
        }
    }
}
