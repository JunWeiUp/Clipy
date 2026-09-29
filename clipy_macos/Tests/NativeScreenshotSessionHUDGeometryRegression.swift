import AppKit

@main
@MainActor
enum NativeScreenshotSessionHUDGeometryRegression {
    static func main() {
        let visible = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let center = CGRect(x: 300, y: 120, width: 400, height: 350)
        let short = CGSize(width: 400, height: 300)
        let tall = CGSize(width: 400, height: 2_000)

        let preview = NativeScreenshotSessionHUDGeometry.scrollPreviewFrame(
            selection: center, visible: visible, imagePixels: short)!
        precondition(preview.width == 200)
        precondition(preview.minX >= center.maxX + 12)
        precondition(preview.minY >= visible.minY)
        let grown = NativeScreenshotSessionHUDGeometry.scrollPreviewFrame(
            selection: center, visible: visible, imagePixels: tall)!
        precondition(grown.height > preview.height)
        precondition(grown.maxY <= visible.maxY - 20)

        let rightEdge = CGRect(x: 830, y: 120, width: 300, height: 350)
        let leftPreview = NativeScreenshotSessionHUDGeometry.scrollPreviewFrame(
            selection: rightEdge, visible: visible, imagePixels: short)!
        precondition(leftPreview.maxX <= rightEdge.minX - 12)

        let wide = CGRect(x: 100, y: 120, width: 1_000, height: 350)
        precondition(NativeScreenshotSessionHUDGeometry.scrollPreviewFrame(
            selection: wide, visible: visible, imagePixels: short) == nil,
            "A narrow side must hide the preview instead of covering the capture")

        let bottom = CGRect(x: 300, y: 10, width: 400, height: 350)
        let controls = NativeScreenshotSessionHUDGeometry.scrollControlFrame(
            selection: bottom, visible: visible)
        precondition(controls.minY >= bottom.maxY + 6)
        precondition(controls.minX >= visible.minX)
        precondition(controls.maxX <= visible.maxX)

        let recordingAbove = NativeScreenshotRecordingPanelPlacement.origin(
            selection: center, visible: visible, panelSize: CGSize(width: 164, height: 32))
        precondition(recordingAbove.x > center.midX)
        precondition(recordingAbove.y >= center.maxY + 8)
        let highSelection = CGRect(x: 300, y: 550, width: 400, height: 230)
        let recordingBelow = NativeScreenshotRecordingPanelPlacement.origin(
            selection: highSelection, visible: visible,
            panelSize: CGSize(width: 164, height: 32))
        precondition(recordingBelow.y <= highSelection.minY - 32 - 8)
        print("NativeScreenshotSessionHUDGeometryRegression passed")
    }
}
