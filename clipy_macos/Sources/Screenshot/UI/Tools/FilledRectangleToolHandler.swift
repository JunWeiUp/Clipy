import Cocoa

/// Handles filled rectangle (redact) tool interaction.
/// Shift-constrains to square. No corner radius or line style — just an opaque filled rect.
final class FilledRectangleToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .filledRectangle

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        Annotation(
            tool: .filledRectangle,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .filledRectangle),
            strokeWidth: canvas.currentStrokeWidth
        )
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            clampedPoint = snapSquare(point, from: annotation.startPoint)
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
        } else {
            clampedPoint = canvas.snapPoint(point, excluding: annotation)
        }

        annotation.endPoint = clampedPoint
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        let dx = abs(annotation.endPoint.x - annotation.startPoint.x)
        let dy = abs(annotation.endPoint.y - annotation.startPoint.y)
        guard dx > 2 || dy > 2 else {
            canvas.activeAnnotation = nil
            canvas.setNeedsDisplay()
            return
        }
        commitAnnotation(annotation, canvas: canvas)
    }
}
