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
    static func detect(
        at screenPoint: NSPoint,
        elementSnapEnabled: Bool,
        preferWindow: Bool = false
    ) -> UIElementDetectResult? {
        guard elementSnapEnabled else { return nil }

        let windowResult = windowSnap(at: screenPoint)
        let elementResult = accessibilitySnap(at: screenPoint)

        if preferWindow {
            return windowResult ?? elementResult
        }
        return elementResult ?? windowResult
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

    private static func windowSnap(at screenPoint: NSPoint) -> UIElementDetectResult? {
        guard let windowID = ScreenshotCaptureService.windowUnderMouse(at: screenPoint),
              let bounds = ScreenshotCaptureService.windowBounds(for: windowID) else {
            return nil
        }
        return UIElementDetectResult(rect: bounds, source: .window, windowID: windowID)
    }

    private static func accessibilitySnap(at screenPoint: NSPoint) -> UIElementDetectResult? {
        guard AccessibilityManager.isTrusted,
              let rect = accessibilityBounds(at: screenPoint) else {
            return nil
        }
        return UIElementDetectResult(rect: rect, source: .element, windowID: nil)
    }

    private static func accessibilityBounds(at screenPoint: NSPoint) -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        let cgPoint = ScreenshotCoordinateConverter.cgPoint(from: screenPoint)
        var elementRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(cgPoint.x),
            Float(cgPoint.y),
            &elementRef
        )
        guard error == .success, let element = elementRef else { return nil }
        return frame(of: element, near: screenPoint)
    }

    private static func frame(of element: AXUIElement, near screenPoint: NSPoint) -> NSRect? {
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

        let fromQuartz = ScreenshotCoordinateConverter.nsRect(
            from: CGRect(origin: position, size: size)
        )
        let fromCocoa = NSRect(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )

        return bestMatchingRect(
            candidates: [fromQuartz, fromCocoa],
            near: screenPoint
        )
    }

    private static func bestMatchingRect(candidates: [NSRect], near screenPoint: NSPoint) -> NSRect? {
        let tolerance: CGFloat = 16
        let valid = candidates.filter { $0.width > 2 && $0.height > 2 }
        guard !valid.isEmpty else { return nil }

        if let containing = valid.first(where: { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(screenPoint) }) {
            return containing
        }

        return valid.min { lhs, rhs in
            distance(from: screenPoint, to: lhs) < distance(from: screenPoint, to: rhs)
        }
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }

        return hypot(dx, dy)
    }
}
