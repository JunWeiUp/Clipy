import Cocoa

/// Handles rectangle tool interaction.
/// Shift-constrains to square. Applies corner radius, fill style, and line style.
final class RectangleToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .rectangle

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let annotation = Annotation(
            tool: .rectangle,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .rectangle),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.rectCornerRadius = canvas.currentRectCornerRadius
        annotation.rectFillStyle = canvas.currentRectFillStyle
        annotation.lineStyle = canvas.currentLineStyle
        return annotation
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
