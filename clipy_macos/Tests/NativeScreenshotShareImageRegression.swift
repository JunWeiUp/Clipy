import CoreGraphics
import Foundation

@main
@MainActor
enum NativeScreenshotShareImageRegression {
    static func main() async throws {
        var calls: [String] = []
        let processed = try await NativeScreenshotShareImagePipeline.resolve(
            exactWindowID: CGWindowID(42), hasInlineEdits: false,
            captureExactWindow: { windowID in
                calls.append("capture:\(windowID)")
                return 10
            }, renderProcessedPreview: {
                calls.append("preview")
                return 99
            }, postprocessWindow: { raw in
                calls.append("process")
                return raw + 7
            })
        precondition(processed == 17)
        precondition(calls == ["capture:42", "process"],
                     "sharing an exact window skipped postprocessing or lost its ID")

        calls.removeAll()
        let edited = try await NativeScreenshotShareImagePipeline.resolve(
            exactWindowID: CGWindowID(42), hasInlineEdits: true,
            captureExactWindow: { _ in calls.append("capture"); return 10 },
            renderProcessedPreview: { calls.append("preview"); return 99 },
            postprocessWindow: { raw in calls.append("process"); return raw + 7 })
        precondition(edited == 99 && calls == ["preview"],
                     "inline edits must use the already processed preview")

        calls.removeAll()
        let region = try await NativeScreenshotShareImagePipeline.resolve(
            exactWindowID: nil, hasInlineEdits: false,
            captureExactWindow: { _ in calls.append("capture"); return 10 },
            renderProcessedPreview: { calls.append("preview"); return 99 },
            postprocessWindow: { raw in calls.append("process"); return raw + 7 })
        precondition(region == 99 && calls == ["preview"],
                     "region sharing must preserve its processed preview path")
        print("NativeScreenshotShareImageRegression passed")
    }
}
