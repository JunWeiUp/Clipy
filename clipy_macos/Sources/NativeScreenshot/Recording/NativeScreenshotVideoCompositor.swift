import Carbon
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation

/// Camera and legacy click overlay. Called only from the recording sample queue.
final class NativeScreenshotVideoCompositor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let webcam: NativeScreenshotRecordingOptions.Webcam?
    private var latestCameraFrame: CVPixelBuffer?
    private var latestClick: (point: CGPoint, uptime: TimeInterval)?
    private var latestKeystroke: (image: CIImage, uptime: TimeInterval, generation: UInt64)?
    private var keystrokeGeneration: UInt64 = 0

    init(webcam: NativeScreenshotRecordingOptions.Webcam?) {
        self.webcam = webcam
    }

    func updateCameraFrame(_ sample: CMSampleBuffer) {
        latestCameraFrame = CMSampleBufferGetImageBuffer(sample)
    }

    func clearCameraFrame() { latestCameraFrame = nil }

    func showClick(at point: CGPoint) {
        latestClick = (point, ProcessInfo.processInfo.systemUptime)
    }

    @discardableResult
    func showKeystroke(_ text: String) -> UInt64? {
        guard let image = Self.makeKeystrokeImage(text) else { return nil }
        keystrokeGeneration &+= 1
        latestKeystroke = (image, ProcessInfo.processInfo.systemUptime, keystrokeGeneration)
        return keystrokeGeneration
    }

    func expireKeystroke(generation: UInt64) -> Bool {
        guard let latestKeystroke, latestKeystroke.generation == generation,
              ProcessInfo.processInfo.systemUptime - latestKeystroke.uptime >= 1.2 else { return false }
        self.latestKeystroke = nil
        return true
    }

    func compose(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard let screen = CMSampleBufferGetImageBuffer(sample) else { return sample }
        let width = CVPixelBufferGetWidth(screen)
        let height = CVPixelBufferGetHeight(screen)
        let screenImage = CIImage(cvPixelBuffer: screen)
        var composite = screenImage
        var hasOverlay = false
        if let webcam, let camera = latestCameraFrame,
           let cameraOverlay = makeCameraOverlay(camera, webcam: webcam, width: width, height: height) {
            composite = cameraOverlay.composited(over: composite)
            hasOverlay = true
        }
        if let click = latestClick {
            let age = ProcessInfo.processInfo.systemUptime - click.uptime
            if age < 0.45 {
                let radius: CGFloat = 25 + CGFloat(age) * 45
                let alpha = max(0, 0.75 - age * 1.6)
                if let ring = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(cgPoint: click.point),
                    "inputRadius0": radius * 0.45,
                    "inputRadius1": radius,
                    "inputColor0": CIColor(red: 1, green: 0.75, blue: 0, alpha: alpha),
                    "inputColor1": CIColor.clear
                ])?.outputImage {
                    composite = ring.cropped(to: screenImage.extent).composited(over: composite)
                    hasOverlay = true
                }
            } else {
                latestClick = nil
            }
        }
        if let keystroke = latestKeystroke {
            if IsSecureEventInputEnabled() {
                latestKeystroke = nil
            } else if ProcessInfo.processInfo.systemUptime - keystroke.uptime < 1.2 {
                let x = (CGFloat(width) - keystroke.image.extent.width) / 2
                composite = keystroke.image
                    .transformed(by: CGAffineTransform(translationX: x, y: 24))
                    .cropped(to: screenImage.extent)
                    .composited(over: composite)
                hasOverlay = true
            } else {
                latestKeystroke = nil
            }
        }
        guard hasOverlay else { return sample }

        var outputBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &outputBuffer) == kCVReturnSuccess,
              let outputBuffer else { return sample }
        context.render(composite, to: outputBuffer, bounds: screenImage.extent,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                          imageBuffer: outputBuffer,
                                                          formatDescriptionOut: &format) == noErr,
              let format else { return sample }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                                        decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample))
        var composed: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                      imageBuffer: outputBuffer,
                                                      formatDescription: format,
                                                      sampleTiming: &timing,
                                                      sampleBufferOut: &composed) == noErr,
              let composed else { return sample }
        return composed
    }

    private func makeCameraOverlay(_ camera: CVPixelBuffer,
                                   webcam: NativeScreenshotRecordingOptions.Webcam,
                                   width: Int, height: Int) -> CIImage? {
        let side = CGFloat(min(width, height))
        let fraction: CGFloat
        switch webcam.size {
        case .small: fraction = 0.16
        case .medium: fraction = 0.22
        case .large: fraction = 0.30
        case .extraLarge: fraction = 0.38
        }
        let cameraWidth = max(48, side * fraction)
        let cameraHeight = webcam.shape == .circle ? cameraWidth : cameraWidth * 0.75
        let inset = max(12, side * 0.025)
        let x: CGFloat
        let y: CGFloat
        switch webcam.position {
        case .topLeft: x = inset; y = CGFloat(height) - inset - cameraHeight
        case .topRight: x = CGFloat(width) - inset - cameraWidth; y = CGFloat(height) - inset - cameraHeight
        case .bottomLeft: x = inset; y = inset
        case .bottomRight: x = CGFloat(width) - inset - cameraWidth; y = inset
        }
        let destination = CGRect(x: x, y: y, width: cameraWidth, height: cameraHeight).integral
        guard destination.minX >= 0, destination.minY >= 0,
              destination.maxX <= CGFloat(width), destination.maxY <= CGFloat(height) else { return nil }

        let cameraImage = CIImage(cvPixelBuffer: camera)
        let cameraScale = max(destination.width / cameraImage.extent.width,
                              destination.height / cameraImage.extent.height)
        let scaled = cameraImage.transformed(by: CGAffineTransform(scaleX: cameraScale, y: cameraScale))
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: destination.midX - scaled.extent.midX,
            y: destination.midY - scaled.extent.midY
        )).cropped(to: destination)
        let radius = webcam.shape == .circle ? min(destination.width, destination.height) / 2 : 14
        guard let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: destination),
            "inputRadius": radius,
            "inputColor": CIColor.white
        ])?.outputImage else { return nil }
        return CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: translated,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: destination),
            kCIInputMaskImageKey: mask
        ])?.outputImage
    }

    private static func makeKeystrokeImage(_ text: String) -> CIImage? {
        let width = 480
        let height = 72
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let background = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                                cornerWidth: 18, cornerHeight: 18, transform: nil)
        context.addPath(background)
        context.setFillColor(CGColor(gray: 0.08, alpha: 0.82))
        context.fillPath()
        let font = CTFontCreateWithName("Menlo" as CFString, 28, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: max(12, (CGFloat(width) - lineWidth) / 2), y: 21)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    func clear() { latestCameraFrame = nil; latestClick = nil; latestKeystroke = nil }
}
