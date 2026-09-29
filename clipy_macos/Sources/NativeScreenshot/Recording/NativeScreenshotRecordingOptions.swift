import CoreGraphics
import Foundation

/// A display-local rectangle in points. The caller excludes its own controls from the stream.
struct NativeScreenshotRecordingOptions {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let outputURL: URL
    let framesPerSecond: Int
    let includesSystemAudio: Bool
    let includesMicrophone: Bool
    let microphoneDeviceID: String?
    let highlightsMouseClicks: Bool
    let webcam: Webcam?
    let webcamDeviceID: String?
    let keystrokeMode: KeystrokeMode
    let maxDuration: TimeInterval
    let maxDimension: Int

    init(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        outputURL: URL,
        framesPerSecond: Int = 30,
        includesSystemAudio: Bool = false,
        includesMicrophone: Bool = false,
        microphoneDeviceID: String? = nil,
        highlightsMouseClicks: Bool = false,
        webcam: Webcam? = nil,
        webcamDeviceID: String? = nil,
        keystrokeMode: KeystrokeMode = .off,
        maxDuration: TimeInterval = 3_600,
        maxDimension: Int = 4_096
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect.standardized
        self.outputURL = outputURL
        self.framesPerSecond = framesPerSecond
        self.includesSystemAudio = includesSystemAudio
        self.includesMicrophone = includesMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.highlightsMouseClicks = highlightsMouseClicks
        self.webcam = webcam
        self.webcamDeviceID = webcamDeviceID
        self.keystrokeMode = keystrokeMode
        self.maxDuration = maxDuration
        self.maxDimension = maxDimension
    }

    struct Webcam {
        enum Position { case topLeft, topRight, bottomLeft, bottomRight }
        enum Size { case small, medium, large, extraLarge }
        enum Shape { case circle, roundedRectangle }
        let position: Position
        let size: Size
        let shape: Shape

        init(position: Position = .bottomRight, size: Size = .medium, shape: Shape = .circle) {
            self.position = position
            self.size = size
            self.shape = shape
        }
    }

    enum KeystrokeMode {
        case off
        case shortcutsOnly
        case allKeys
    }

    func validated() throws -> Self {
        guard [15, 24, 30, 60].contains(framesPerSecond) else {
            throw NativeScreenshotRecordingError.invalidFrameRate
        }
        guard sourceRect.width >= 2, sourceRect.height >= 2,
              sourceRect.origin.x.isFinite, sourceRect.origin.y.isFinite,
              sourceRect.width.isFinite, sourceRect.height.isFinite,
              maxDuration > 0, maxDuration.isFinite, maxDimension >= 64 else {
            throw NativeScreenshotRecordingError.invalidRegion
        }
        guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == "mp4" else {
            throw NativeScreenshotRecordingError.invalidDestination
        }
        return self
    }

    /// The H.264 encoder requires even dimensions; preserve aspect ratio within the cap.
    func outputSize(displayScale: CGFloat) -> CGSize {
        let rawWidth = sourceRect.width * displayScale
        let rawHeight = sourceRect.height * displayScale
        let scale = min(1, CGFloat(maxDimension) / max(rawWidth, rawHeight))
        let width = max(2, Int(floor(rawWidth * scale)) & ~1)
        let height = max(2, Int(floor(rawHeight * scale)) & ~1)
        return CGSize(width: width, height: height)
    }

    /// Maps Quartz global mouse coordinates (top-left origin) to CI output pixels.
    func outputPoint(forGlobalPoint point: CGPoint, displayFrame: CGRect, outputSize: CGSize) -> CGPoint? {
        let local = CGPoint(x: point.x - displayFrame.minX - sourceRect.minX,
                            y: point.y - displayFrame.minY - sourceRect.minY)
        guard local.x >= 0, local.y >= 0,
              local.x < sourceRect.width, local.y < sourceRect.height else { return nil }
        return CGPoint(x: local.x * outputSize.width / sourceRect.width,
                       y: outputSize.height - local.y * outputSize.height / sourceRect.height)
    }
}

enum NativeScreenshotRecordingError: LocalizedError {
    case invalidFrameRate
    case invalidRegion
    case invalidDestination
    case displayUnavailable
    case captureUnavailable
    case noFrames
    case durationLimitReached
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrameRate: return "录屏帧率必须为 15、24、30 或 60 FPS。"
        case .invalidRegion: return "录屏区域或时长限制无效。"
        case .invalidDestination: return "录屏目标必须是本地 MP4 文件。"
        case .displayUnavailable: return "录屏显示器已不可用。"
        case .captureUnavailable: return "屏幕录制不可用，请检查系统权限。"
        case .noFrames: return "录屏没有收到可写入的视频帧。"
        case .durationLimitReached: return "录屏已达到时长上限。"
        case .writerFailed(let message): return "录屏写入失败：\(message)"
        }
    }
}
