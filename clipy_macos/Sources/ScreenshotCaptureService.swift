import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenshotCaptureService {
    static func capture(rect: NSRect, completion: @escaping (NSImage?) -> Void) {
        guard #available(macOS 14.0, *) else {
            appLog("Screenshot capture requires macOS 14 or later", level: .warning)
            completion(nil)
            return
        }

        let cgRect = ScreenshotCoordinateConverter.cgRect(from: rect)
        guard cgRect.width > 1, cgRect.height > 1 else {
            completion(nil)
            return
        }

        Task.detached(priority: .userInitiated) {
            let image: NSImage?
            do {
                if let cgImage = try await captureDisplayRegion(cgRect) {
                    image = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgRect.width, height: cgRect.height)
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

        Task.detached(priority: .userInitiated) {
            let image: NSImage?
            do {
                if let cgImage = try await captureWindow(windowID) {
                    image = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
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

        let cgPoint = ScreenshotCoordinateConverter.cgRect(
            from: NSRect(origin: point, size: .zero)
        ).origin

        for info in windowInfoList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
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

    @available(macOS 14.0, *)
    private static func captureDisplayRegion(_ rect: CGRect) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = displayContaining(rect: rect, displays: content.displays) else {
            appLog("Screenshot: no display found for rect \(rect)", level: .warning)
            return nil
        }

        let relativeRect = CGRect(
            x: rect.origin.x - display.frame.origin.x,
            y: rect.origin.y - display.frame.origin.y,
            width: rect.width,
            height: rect.height
        )

        let scaleX = CGFloat(display.width) / display.frame.width
        let scaleY = CGFloat(display.height) / display.frame.height

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = relativeRect
        configuration.width = max(1, Int(relativeRect.width * scaleX))
        configuration.height = max(1, Int(relativeRect.height * scaleY))
        configuration.showsCursor = true
        configuration.captureResolution = .best

        appLog("Screenshot: capturing display region \(relativeRect) on display \(display.displayID)")
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    @available(macOS 14.0, *)
    private static func captureWindow(_ windowID: CGWindowID) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            appLog("Screenshot: window \(windowID) not found in shareable content", level: .warning)
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width))
        configuration.height = max(1, Int(window.frame.height))
        configuration.showsCursor = true
        configuration.captureResolution = .best

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    @available(macOS 14.0, *)
    private static func displayContaining(rect: CGRect, displays: [SCDisplay]) -> SCDisplay? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return displays.first { $0.frame.contains(center) } ?? displays.first
    }
}
