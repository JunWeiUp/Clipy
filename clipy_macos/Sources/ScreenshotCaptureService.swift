import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenshotCaptureService {
    static func capture(rect: NSRect, forMagnifier: Bool = false, completion: @escaping (NSImage?) -> Void) {
        guard #available(macOS 14.0, *) else {
            appLog("Screenshot capture requires macOS 14 or later", level: .warning)
            completion(nil)
            return
        }

        guard rect.width > 1, rect.height > 1 else {
            completion(nil)
            return
        }

        let screen = screenContaining(rect: rect)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let screenFrame = screen.frame

        Task.detached(priority: .userInitiated) {
            let image: NSImage?
            do {
                if let capture = try await captureDisplayRegion(
                    rect,
                    screenFrame: screenFrame,
                    displayID: displayID,
                    forMagnifier: forMagnifier
                ) {
                    image = ScreenshotImageProcessor.fromCapture(
                        capture.image,
                        logicalSize: rect.size,
                        displayNativeScale: capture.nativeScale
                    )
                } else {
                    image = nil
                }
            } catch {
                appLog("Screenshot region capture failed: \(error.localizedDescription)", level: .error)
                image = nil
            }

            await MainActor.run {
                completion(image)
            }
        }
    }

    static func capture(windowID: CGWindowID, completion: @escaping (NSImage?) -> Void) {
        guard #available(macOS 14.0, *) else {
            appLog("Screenshot capture requires macOS 14 or later", level: .warning)
            completion(nil)
            return
        }

        let logicalSize = windowBounds(for: windowID)?.size ?? .zero

        Task.detached(priority: .userInitiated) {
            let image: NSImage?
            do {
                if let capture = try await captureWindow(windowID) {
                    let bounds = windowBounds(for: windowID)
                    let size = bounds?.size ?? logicalSize
                    let fallbackScale = PreferencesManager.shared.screenshotResolution.pixelScale(for: NSScreen.main)
                    let resolvedSize = size.width > 1 ? size : NSSize(
                        width: CGFloat(capture.image.width) / fallbackScale,
                        height: CGFloat(capture.image.height) / fallbackScale
                    )
                    image = ScreenshotImageProcessor.fromCapture(
                        capture.image,
                        logicalSize: resolvedSize,
                        displayNativeScale: capture.nativeScale
                    )
                } else {
                    image = nil
                }
            } catch {
                appLog("Screenshot window capture failed: \(error.localizedDescription)", level: .error)
                image = nil
            }

            await MainActor.run {
                completion(image)
            }
        }
    }

    static func captureFullscreen(on screen: NSScreen? = NSScreen.main, completion: @escaping (NSImage?) -> Void) {
        guard let screen else {
            completion(nil)
            return
        }
        capture(rect: screen.frame, completion: completion)
    }

    static func windowUnderMouse(at point: NSPoint) -> CGWindowID? {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let cgPoint = ScreenshotCoordinateConverter.cgPoint(from: point)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for info in windowInfoList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ownPID,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName != "Window Server",
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            if bounds.contains(cgPoint) {
                return windowID
            }
        }
        return nil
    }

    static func windowBounds(for windowID: CGWindowID) -> NSRect? {
        guard let windowInfoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = windowInfoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }

        let cgRect = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
        return ScreenshotCoordinateConverter.nsRect(from: cgRect)
    }

    private struct CapturedImage {
        let image: CGImage
        let nativeScale: CGFloat
    }

    @available(macOS 14.0, *)
    private static func captureDisplayRegion(
        _ rect: NSRect,
        screenFrame: NSRect,
        displayID: CGDirectDisplayID?,
        forMagnifier: Bool = false
    ) async throws -> CapturedImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = displayMatching(displayID: displayID, fallbackRect: rect, displays: content.displays) else {
            appLog("Screenshot: no display found for rect \(rect)", level: .warning)
            return nil
        }

        let resolution = PreferencesManager.shared.screenshotResolution
        let nativeScale = CGFloat(display.width) / max(display.frame.width, 1)
        let filter = SCContentFilter(display: display, excludingWindows: ownApplicationWindows(from: content))

        if forMagnifier {
            let magnifierScale = max(
                nativeScale,
                screenContaining(rect: rect).backingScaleFactor
            )
            return try await captureDisplayRegionWithSourceRect(
                rect: rect,
                display: display,
                nativeScale: nativeScale,
                resolution: resolution,
                filter: filter,
                pixelScaleOverride: magnifierScale
            )
        }

        if resolution == .auto {
            return try await captureDisplayRegionByCropping(
                rect: rect,
                display: display,
                nativeScale: nativeScale,
                resolution: resolution,
                filter: filter
            )
        }

        return try await captureDisplayRegionWithSourceRect(
            rect: rect,
            display: display,
            nativeScale: nativeScale,
            resolution: resolution,
            filter: filter
        )
    }

    @available(macOS 14.0, *)
    private static func captureDisplayRegionByCropping(
        rect: NSRect,
        display: SCDisplay,
        nativeScale: CGFloat,
        resolution: ScreenshotResolution,
        filter: SCContentFilter
    ) async throws -> CapturedImage? {
        let configuration = makeStreamConfiguration(
            width: display.width,
            height: display.height,
            resolution: resolution
        )

        appLog("Screenshot: capturing full display \(display.width)x\(display.height) then cropping")
        let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let cropRect = ScreenshotCoordinateConverter.pixelCropRect(
            from: rect,
            displayFrame: display.frame,
            pixelWidth: fullImage.width,
            pixelHeight: fullImage.height
        )

        guard cropRect.width > 1, cropRect.height > 1,
              let cropped = fullImage.cropping(to: cropRect) else {
            appLog("Screenshot: crop failed for rect \(rect) -> \(cropRect)", level: .warning)
            return nil
        }

        appLog("Screenshot: cropped to \(cropped.width)x\(cropped.height) at native scale \(nativeScale)")
        return CapturedImage(image: cropped, nativeScale: nativeScale)
    }

    @available(macOS 14.0, *)
    private static func captureDisplayRegionWithSourceRect(
        rect: NSRect,
        display: SCDisplay,
        nativeScale: CGFloat,
        resolution: ScreenshotResolution,
        filter: SCContentFilter,
        pixelScaleOverride: CGFloat? = nil
    ) async throws -> CapturedImage? {
        let relativeRect = ScreenshotCoordinateConverter.displayRelativeRect(
            from: rect,
            displayFrame: display.frame
        )
        let pixelScale = pixelScaleOverride ?? resolution.pixelScale(
            for: screenContaining(rect: rect),
            displayNativeScale: nativeScale
        )
        let targetPixelSize = ScreenshotImageProcessor.pixelSize(
            forLogicalSize: rect.size,
            scale: pixelScale
        )
        let configuration = makeStreamConfiguration(
            width: Int(targetPixelSize.width),
            height: Int(targetPixelSize.height),
            resolution: resolution
        )
        configuration.sourceRect = relativeRect

        appLog("Screenshot: capturing display region \(relativeRect) at \(resolution.displayName()) scale \(pixelScale)")
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedImage(image: image, nativeScale: nativeScale)
    }

    @available(macOS 14.0, *)
    private static func ownApplicationWindows(from content: SCShareableContent) -> [SCWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == ownPID }
    }

    @available(macOS 14.0, *)
    private static func captureWindow(_ windowID: CGWindowID) async throws -> CapturedImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            appLog("Screenshot: window \(windowID) not found in shareable content", level: .warning)
            return nil
        }

        let resolution = PreferencesManager.shared.screenshotResolution
        let bounds = windowBounds(for: windowID)
        let screen = bounds.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.main
        let display = content.displays.first { display in
            display.frame.intersects(window.frame)
        }
        let nativeScale = display.map { CGFloat($0.width) / $0.frame.width }
        let pixelScale = resolution.pixelScale(for: screen, displayNativeScale: nativeScale)
        let logicalSize = NSSize(width: window.frame.width, height: window.frame.height)
        let targetPixelSize = ScreenshotImageProcessor.pixelSize(
            forLogicalSize: logicalSize,
            scale: pixelScale
        )
        let configuration = makeStreamConfiguration(
            width: Int(targetPixelSize.width),
            height: Int(targetPixelSize.height),
            resolution: resolution
        )
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedImage(image: image, nativeScale: nativeScale ?? screen?.backingScaleFactor ?? 1)
    }

    @available(macOS 14.0, *)
    private static func makeStreamConfiguration(width: Int, height: Int, resolution: ScreenshotResolution) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, width)
        configuration.height = max(1, height)
        configuration.showsCursor = true
        configuration.captureResolution = resolution.prefersNominalCapture ? .nominal : .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = false
        return configuration
    }

    @available(macOS 14.0, *)
    private static func displayContaining(rect: CGRect, displays: [SCDisplay]) -> SCDisplay? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return displays.first { $0.frame.contains(center) } ?? displays.first
    }

    private static func screenContaining(rect: NSRect) -> NSScreen {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    @available(macOS 14.0, *)
    private static func displayMatching(displayID: CGDirectDisplayID?, fallbackRect: NSRect, displays: [SCDisplay]) -> SCDisplay? {
        if let displayID, let display = displays.first(where: { $0.displayID == displayID }) {
            return display
        }
        let cgRect = ScreenshotCoordinateConverter.cgRect(from: fallbackRect)
        return displayContaining(rect: cgRect, displays: displays)
    }
}
