import AppKit
import ApplicationServices

enum UIElementDetectSource {
    case element
    case window
}

struct UIElementDetectResult {
    let rect: NSRect
    let source: UIElementDetectSource
    let windowID: CGWindowID?
}

enum UIElementDetector {
    static func detect(at screenPoint: NSPoint, elementSnapEnabled: Bool) -> UIElementDetectResult? {
        guard elementSnapEnabled else { return nil }

        if AccessibilityManager.isTrusted, let rect = accessibilityBounds(at: screenPoint) {
            return UIElementDetectResult(rect: rect, source: .element, windowID: nil)
        }

        if let windowID = ScreenshotCaptureService.windowUnderMouse(at: screenPoint),
           let bounds = ScreenshotCaptureService.windowBounds(for: windowID) {
            return UIElementDetectResult(rect: bounds, source: .window, windowID: windowID)
        }

        return nil
    }

    static func snapRect(_ rect: NSRect, to target: NSRect, threshold: CGFloat = ScreenshotChrome.snapThreshold) -> NSRect {
        var result = rect
        if abs(rect.minX - target.minX) <= threshold {
            result.origin.x = target.minX
        }
        if abs(rect.maxX - target.maxX) <= threshold {
            result.origin.x = target.maxX - rect.width
        }
        if abs(rect.minY - target.minY) <= threshold {
            result.origin.y = target.minY
        }
        if abs(rect.maxY - target.maxY) <= threshold {
            result.origin.y = target.maxY - rect.height
        }
        return result
    }

    private static func accessibilityBounds(at screenPoint: NSPoint) -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(screenPoint.x),
            Float(screenPoint.y),
            &elementRef
        )
        guard error == .success, let element = elementRef else { return nil }
        return frame(of: element)
    }

    private static func frame(of element: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 2, size.height > 2 else {
            return nil
        }

        return NSRect(origin: position, size: size)
    }
}
