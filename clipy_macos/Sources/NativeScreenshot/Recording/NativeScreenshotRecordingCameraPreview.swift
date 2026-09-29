import AppKit
import AVFoundation

#if !NATIVE_SCREENSHOT_RECORDING_TESTS

/// Temporary live preview while the user configures an area recording. The
/// capture session ends before the screen stream is created.
@MainActor
final class NativeScreenshotRecordingCameraPreview {
    let deviceID: String
    private let window: NSPanel
    private let session = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let sessionQueue = DispatchQueue(label: "clipy.screenshot.camera-setup")

    init(device: AVCaptureDevice) throws {
        deviceID = device.uniqueID
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NativeScreenshotRecordingError.captureUnavailable
        }
        session.addInput(input)
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        let content = NSView(frame: .zero)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 2
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        content.layer?.addSublayer(previewLayer)
        window.contentView = content
    }

    func show(in selection: CGRect, position: String, size: String, shape: String) {
        guard selection.width >= 72, selection.height >= 72 else {
            close()
            return
        }
        let side = min(selection.width, selection.height)
        let fraction: CGFloat
        switch size {
        case "small": fraction = 0.16
        case "large": fraction = 0.30
        case "xlarge": fraction = 0.38
        default: fraction = 0.22
        }
        let width = min(selection.width - 12, max(48, side * fraction))
        let height = shape == "circle" ? width : width * 0.75
        let inset = max(12, side * 0.025)
        let left = position == "topLeft" || position == "bottomLeft"
        let top = position == "topLeft" || position == "topRight"
        let x = left ? selection.minX + inset : selection.maxX - inset - width
        let y = top ? selection.maxY - inset - height : selection.minY + inset
        window.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        window.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView?.layer?.cornerRadius = shape == "circle" ? height / 2 : 14
        previewLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.orderFrontRegardless()
        let session = session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    func close() {
        window.orderOut(nil)
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func stopAndWait() async {
        window.orderOut(nil)
        let session = session
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }
}

#endif
