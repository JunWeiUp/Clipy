import CoreGraphics

/// Keep sharing attached to its live toolbar while resolving the image. An
/// exact window capture must receive the same postprocessing as other outputs;
/// a preview has already been postprocessed by previewSelectedImage().
@MainActor
enum NativeScreenshotShareImagePipeline {
    static func resolve<Image>(
        exactWindowID: CGWindowID?,
        hasInlineEdits: Bool,
        captureExactWindow: (CGWindowID) async throws -> Image,
        renderProcessedPreview: () throws -> Image,
        postprocessWindow: (Image) async throws -> Image
    ) async throws -> Image {
        if let exactWindowID, !hasInlineEdits {
            let captured = try await captureExactWindow(exactWindowID)
            return try await postprocessWindow(captured)
        }
        return try renderProcessedPreview()
    }
}
