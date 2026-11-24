import AVFoundation
import Cocoa
import UniformTypeIdentifiers

extension OverlayView {
    // MARK: - Annotation Controls

    func drawAnnotationControls(for annotation: Annotation, fullControls: Bool = true) {
        // Arrow, line, and measure: show only 2 endpoint handles, no bounding box
        if annotation.tool == .arrow || annotation.tool == .line || annotation.tool == .measure {
            if !fullControls {
                drawAnnotationOutlineGlow(annotation)
                return
            }

            let pts = annotation.waypoints
            let s: CGFloat = 10
            let sm: CGFloat = 8

            annotationResizeHandleRects = []

            // Draw guide path through all waypoints
            if pts.count > 2 {
                let guidePath = NSBezierPath()
                guidePath.lineWidth = 1
                guidePath.setLineDash([3, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.35).setStroke()
                guidePath.move(to: pts[0])
                for i in 1..<pts.count { guidePath.line(to: pts[i]) }
                guidePath.stroke()
            } else if annotation.controlPoint != nil {
                let midPt = annotation.controlPoint!
                let guidePath = NSBezierPath()
                guidePath.lineWidth = 1
                guidePath.setLineDash([3, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.35).setStroke()
                guidePath.move(to: annotation.startPoint)
                guidePath.line(to: midPt)
                guidePath.line(to: annotation.endPoint)
                guidePath.stroke()
            }

            // Endpoint handles (start = .bottomLeft, end = .topRight)
            let startRect = NSRect(
                x: pts.first!.x - s / 2, y: pts.first!.y - s / 2, width: s, height: s)
            let endRect = NSRect(
                x: pts.last!.x - s / 2, y: pts.last!.y - s / 2, width: s, height: s)
            annotationResizeHandleRects.append((.bottomLeft, startRect))
            annotationResizeHandleRects.append((.topRight, endRect))

            for rect in [startRect, endRect] {
                ToolbarLayout.accentColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1.5
                border.stroke()
            }

            // Intermediate anchor handles — use .none as handle ID since we identify
            // them by array index (annotationResizeAnchorIndex), not by ResizeHandle enum.
            if pts.count > 2 {
                for i in 1..<(pts.count - 1) {
                    let handleID: ResizeHandle = .none
                    let midRect = NSRect(
                        x: pts[i].x - sm / 2, y: pts[i].y - sm / 2, width: sm, height: sm)
                    annotationResizeHandleRects.append((handleID, midRect))
                    NSColor.white.withAlphaComponent(0.9).setFill()
                    NSBezierPath(ovalIn: midRect).fill()
                    ToolbarLayout.accentColor.setStroke()
                    let midBorder = NSBezierPath(ovalIn: midRect.insetBy(dx: 0.5, dy: 0.5))
                    midBorder.lineWidth = 1.5
                    midBorder.stroke()
                }
            } else {
                // Legacy single bend handle (or visual midpoint)
                let midPt =
                    annotation.controlPoint
                    ?? NSPoint(
                        x: (annotation.startPoint.x + annotation.endPoint.x) / 2,
                        y: (annotation.startPoint.y + annotation.endPoint.y) / 2
                    )
                let midRect = NSRect(
                    x: midPt.x - sm / 2, y: midPt.y - sm / 2, width: sm, height: sm)
                annotationResizeHandleRects.append((.top, midRect))
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: midRect).fill()
                ToolbarLayout.accentColor.setStroke()
                let midBorder = NSBezierPath(ovalIn: midRect.insetBy(dx: 0.5, dy: 0.5))
                midBorder.lineWidth = 1.5
                midBorder.stroke()
            }

            // Delete button near endPoint
            let btnSize: CGFloat = 22
            let deleteRect = NSRect(
                x: annotation.endPoint.x + 8, y: annotation.endPoint.y + 2, width: btnSize,
                height: btnSize)
            annotationDeleteButtonRect = deleteRect
            drawDeleteCircle(in: deleteRect)
            annotationEditButtonRect = .zero
            return
        }

        if annotation.tool == .number {
            drawNumberAnnotationControls(for: annotation, fullControls: fullControls)
            return
        }

        let baseRect: NSRect
        switch annotation.tool {
        case .pencil, .marker:
            guard let points = annotation.points, !points.isEmpty else { return }
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for p in points {
                minX = min(minX, p.x)
                minY = min(minY, p.y)
                maxX = max(maxX, p.x)
                maxY = max(maxY, p.y)
            }
            // Expand by the actual painted stroke radius so the box matches the visible stroke
            let strokeRadius =
                (annotation.tool == .marker ? annotation.strokeWidth * 6 : annotation.strokeWidth)
                / 2
            baseRect = NSRect(
                x: minX - strokeRadius, y: minY - strokeRadius,
                width: maxX - minX + strokeRadius * 2, height: maxY - minY + strokeRadius * 2)
        case .text:
            // startPoint = top-left, endPoint = bottom-right (set at commit time)
            if annotation.endPoint != annotation.startPoint {
                baseRect = annotation.boundingRect
            } else {
                // Legacy: recompute from attributed string size
                let text =
                    annotation.attributedText
                    ?? annotation.text.map {
                        NSAttributedString(
                            string: $0,
                            attributes: [.font: NSFont.systemFont(ofSize: annotation.fontSize)])
                    }
                let size = text?.size() ?? NSSize(width: 50, height: 20)
                baseRect = NSRect(origin: annotation.startPoint, size: size)
            }
        case .loupe:
            baseRect = annotation.boundingRect
        default:
            let strokePad = annotation.strokeWidth / 2
            baseRect = annotation.boundingRect.insetBy(dx: -strokePad, dy: -strokePad)
        }

        let padded = baseRect.insetBy(dx: -4, dy: -4)

        // Text: a glyph-tracing glow looks noisy. Show a plain solid selection
        // rectangle connecting the handles instead. Other annotations keep the
        // shape-following outline glow.
        if annotation.tool == .text {
            let rotated = annotation.rotation != 0 && annotation.supportsRotation
            if rotated {
                // Draw the rect rotated about the box center to match the text.
                NSGraphicsContext.current?.cgContext.saveGState()
                let center = NSPoint(x: baseRect.midX, y: baseRect.midY)
                let xform = NSAffineTransform()
                xform.translateX(by: center.x, yBy: center.y)
                xform.rotate(byRadians: annotation.rotation)
                xform.translateX(by: -center.x, yBy: -center.y)
                xform.concat()
            }
            let border = NSBezierPath(rect: padded)
            border.lineWidth = 1.5
            ToolbarLayout.accentColor.setStroke()
            border.stroke()
            if rotated {
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
        } else {
            // Generic outline glow — works for all annotation types, single and multi-select
            drawAnnotationOutlineGlow(annotation)
        }

        // Multi-select: no handles, rotate, or delete buttons
        guard fullControls else { return }

        // Apply annotation rotation to controls (handles, delete button)
        if annotation.rotation != 0 && annotation.supportsRotation {
            let center = NSPoint(x: baseRect.midX, y: baseRect.midY)
            let xform = NSAffineTransform()
            xform.translateX(by: center.x, yBy: center.y)
            xform.rotate(byRadians: annotation.rotation)
            xform.translateX(by: -center.x, yBy: -center.y)
            NSGraphicsContext.current?.cgContext.saveGState()
            xform.concat()
        }

        // Draw resize handles (8 positions) — pencil/marker don't support rectangular resize.
        if annotation.tool != .pencil && annotation.tool != .marker {
            let handles = annotationAllHandleRects(for: padded)
            annotationResizeHandleRects = handles
            for (_, rect) in handles {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect).fill()
                ToolbarLayout.accentColor.setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1.5
                border.stroke()
            }
        } else {
            annotationResizeHandleRects = []
        }

        // Restore rotation transform before drawing rotation handle (in screen space)
        if annotation.rotation != 0 && annotation.supportsRotation {
            NSGraphicsContext.current?.cgContext.restoreGState()
        }

        // Rotation handle (above top-center) — matches delete/edit button style
        annotationRotateHandleRect = .zero
        if annotation.supportsRotation {
            let center = NSPoint(x: padded.midX, y: padded.midY)
            let hs: CGFloat = 22
            let handleDist: CGFloat = padded.height / 2 + 20
            // Rotate the handle position by the annotation's current rotation
            let handleX = center.x - handleDist * sin(annotation.rotation)
            let handleY = center.y + handleDist * cos(annotation.rotation)
            let rotRect = NSRect(x: handleX - hs / 2, y: handleY - hs / 2, width: hs, height: hs)
            annotationRotateHandleRect = rotRect

            // Connecting line from top-center of box to handle
            let topCenterX = center.x - (padded.height / 2 + 2) * sin(annotation.rotation)
            let topCenterY = center.y + (padded.height / 2 + 2) * cos(annotation.rotation)
            let connPath = NSBezierPath()
            connPath.lineWidth = 1
            connPath.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.5).setStroke()
            connPath.move(to: NSPoint(x: topCenterX, y: topCenterY))
            connPath.line(to: NSPoint(x: handleX, y: handleY))
            connPath.stroke()

            // Dark fill (same as delete/edit)
            NSColor(white: 0.12, alpha: 0.94).setFill()
            NSBezierPath(ovalIn: rotRect).fill()
            // Accent border
            ToolbarLayout.accentColor.withAlphaComponent(0.9).setStroke()
            let rotBorder = NSBezierPath(ovalIn: rotRect.insetBy(dx: 0.75, dy: 0.75))
            rotBorder.lineWidth = 1.5
            rotBorder.stroke()

            // White rotate icon
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            if let img = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(
                    x: rotRect.midX - img.size.width / 2 + 0.5, y: rotRect.midY - img.size.height / 2,
                    width: img.size.width, height: img.size.height))
            }
        }

        // Delete button (X) at top-right outside the box
        let btnSize: CGFloat = 22
        let deleteRect = NSRect(
            x: padded.maxX + 4, y: padded.maxY - btnSize, width: btnSize, height: btnSize)
        annotationDeleteButtonRect = deleteRect
        drawDeleteCircle(in: deleteRect)

        // Two-circle loupe: resize handle on the SOURCE circle (drag to change
        // zoom — the source frames exactly what the lens shows).
        loupeSourceHandleRect = .zero
        if annotation.tool == .loupe, let src = annotation.loupeSourceRect, src.width > 4 {
            let r = min(src.width, src.height) / 2
            // Place on the source circle's outer edge, away from the lens.
            let lensCenter = NSPoint(x: annotation.loupeLensSquareRect.midX,
                                     y: annotation.loupeLensSquareRect.midY)
            let srcCenter = NSPoint(x: src.midX, y: src.midY)
            var ux = srcCenter.x - lensCenter.x, uy = srcCenter.y - lensCenter.y
            let d = hypot(ux, uy)
            if d > 0.001 { ux /= d; uy /= d } else { ux = 0; uy = -1 }
            let hp = NSPoint(x: srcCenter.x + ux * r, y: srcCenter.y + uy * r)
            let hs: CGFloat = 12
            let hrect = NSRect(x: hp.x - hs / 2, y: hp.y - hs / 2, width: hs, height: hs)
            loupeSourceHandleRect = hrect
            NSColor.white.setFill()
            NSBezierPath(ovalIn: hrect).fill()
            ToolbarLayout.accentColor.setStroke()
            let hb = NSBezierPath(ovalIn: hrect.insetBy(dx: 0.5, dy: 0.5))
            hb.lineWidth = 1.5
            hb.stroke()
        }

        // Edit button (pencil) for text annotations — matches delete button style
        if annotation.tool == .text {
            let editRect = NSRect(
                x: padded.maxX + 4, y: padded.maxY - btnSize * 2 - 4, width: btnSize,
                height: btnSize)
            annotationEditButtonRect = editRect
            // Dark fill (same as delete)
            NSColor(white: 0.12, alpha: 0.94).setFill()
            NSBezierPath(ovalIn: editRect).fill()
            // Accent border
            ToolbarLayout.accentColor.withAlphaComponent(0.9).setStroke()
            let editBorder = NSBezierPath(ovalIn: editRect.insetBy(dx: 0.75, dy: 0.75))
            editBorder.lineWidth = 1.5
            editBorder.stroke()
            // White pencil icon
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            if let img = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect)
                    NSColor.white.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let imgRect = NSRect(
                    x: editRect.midX - img.size.width / 2, y: editRect.midY - img.size.height / 2,
                    width: img.size.width, height: img.size.height)
                tinted.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        } else {
            annotationEditButtonRect = .zero
        }
    }

    func drawNumberAnnotationControls(for annotation: Annotation, fullControls: Bool) {
        drawAnnotationOutlineGlow(annotation)

        annotationRotateHandleRect = .zero
        annotationEditButtonRect = .zero
        annotationResizeHandleRects = []

        guard fullControls else { return }

        let center = annotation.startPoint
        let tip = displayNumberTipHandlePoint(for: annotation)
        let guidePath = NSBezierPath()
        guidePath.lineWidth = 1
        guidePath.setLineDash([3, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        guidePath.move(to: center)
        guidePath.line(to: tip)
        guidePath.stroke()

        let handleSize: CGFloat = 10
        let centerRect = NSRect(
            x: center.x - handleSize / 2, y: center.y - handleSize / 2,
            width: handleSize, height: handleSize)
        let tipRect = NSRect(
            x: tip.x - handleSize / 2, y: tip.y - handleSize / 2,
            width: handleSize, height: handleSize)
        // Keep both as draggable handles (center moves the circle, tip moves the
        // pointer), but only DRAW the tip dot. The center dot sat on top of the
        // digit and made the number hard to read while selected — the whole
        // circle body is draggable anyway.
        annotationResizeHandleRects = [(.bottomLeft, centerRect), (.topRight, tipRect)]

        ToolbarLayout.accentColor.setFill()
        NSBezierPath(ovalIn: tipRect).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let tipBorder = NSBezierPath(ovalIn: tipRect.insetBy(dx: 0.5, dy: 0.5))
        tipBorder.lineWidth = 1.5
        tipBorder.stroke()

        let buttonAnchor = annotation.boundingRect
        let btnSize: CGFloat = 22
        let deleteRect = NSRect(
            x: buttonAnchor.maxX + 6, y: buttonAnchor.maxY - btnSize,
            width: btnSize, height: btnSize)
        annotationDeleteButtonRect = deleteRect
        drawDeleteCircle(in: deleteRect)
    }

    func displayNumberTipHandlePoint(for annotation: Annotation) -> NSPoint {
        let dx = annotation.endPoint.x - annotation.startPoint.x
        let dy = annotation.endPoint.y - annotation.startPoint.y
        if hypot(dx, dy) > 4 {
            return annotation.endPoint
        }
        let radius = 8 + annotation.strokeWidth * 3
        return NSPoint(x: annotation.startPoint.x + radius + 16, y: annotation.startPoint.y)
    }

    /// Shared CIContext for outline glow rendering — reused across frames.
    /// Lazily created and intentionally releasable: a CIContext's IOSurface/
    /// texture pool grows to the largest rendered image and never shrinks, so
    /// a big glow (e.g. a loupe/marker spanning a large area) can pin tens of
    /// MB. The reclaimer drops it when idle / after a screenshot session.
    static var _outlineGlowCIContext: CIContext?
    static var outlineGlowCIContext: CIContext {
        if let ctx = _outlineGlowCIContext { return ctx }
        let ctx = CIContext()
        _outlineGlowCIContext = ctx
        return ctx
    }
    /// Drop the outline-glow CIContext so its IOSurface/texture pool returns
    /// to the system. Re-creating it on next use costs only tens of ms.
    static func releaseOutlineGlowContext() { _outlineGlowCIContext = nil }

    /// Draw a generic outline glow around any annotation by rendering it offscreen,
    /// dilating the alpha mask, then compositing the outline back. Cached on the annotation.
    func drawAnnotationOutlineGlow(_ annotation: Annotation) {
        // Skip expensive glow during resize — bounding box changes every frame,
        // invalidating the CIFilter cache. A simple stroke rect is drawn instead.
        if isResizingAnnotation && isSelected(annotation) {
            if annotation.tool == .number { return }
            let rect = annotation.boundingRect.insetBy(dx: -2, dy: -2)
            ToolbarLayout.accentColor.withAlphaComponent(0.5).setStroke()
            let path = annotation.tool == .loupe
                ? NSBezierPath(ovalIn: rect)
                : NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.lineWidth = 2
            path.stroke()
            return
        }
        let outlineWidth: CGFloat = 3
        // Generous padding — accounts for stroke width, line caps, Chaikin smoothing overshoot,
        // arrowheads, and the dilation radius. Bitmap is cached so size doesn't matter per-frame.
        let effectiveStroke: CGFloat
        switch annotation.tool {
        case .marker:
            effectiveStroke = annotation.strokeWidth * 6
        case .loupe:
            effectiveStroke = 4
        default:
            effectiveStroke = annotation.strokeWidth
        }
        let padding = effectiveStroke + outlineWidth + 20

        // Compute actual bounding box — for pencil/marker, use the points array
        // since boundingRect only considers startPoint/endPoint.
        let baseBBox: NSRect
        if let pts = annotation.points, !pts.isEmpty,
           (annotation.tool == .pencil || annotation.tool == .marker) {
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for p in pts {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            baseBBox = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else {
            baseBBox = annotation.boundingRect
        }

        // For the glow cache, always use the unrotated bbox. We'll apply rotation at draw time.
        // This avoids regenerating the expensive CIFilter pipeline on every rotation change.
        let unrotatedBBox = baseBBox.insetBy(dx: -padding, dy: -padding)
        guard unrotatedBBox.width > 0, unrotatedBBox.height > 0 else { return }

        // Expand to rotated bounding box for the draw rect so the image covers the full rotated shape
        let drawBBox: NSRect
        if annotation.rotation != 0 && annotation.supportsRotation {
            let cx = unrotatedBBox.midX, cy = unrotatedBBox.midY
            let cos_r = abs(cos(annotation.rotation)), sin_r = abs(sin(annotation.rotation))
            let w = unrotatedBBox.width, h = unrotatedBBox.height
            let rotW = w * cos_r + h * sin_r
            let rotH = w * sin_r + h * cos_r
            drawBBox = NSRect(x: cx - rotW / 2, y: cy - rotH / 2, width: rotW, height: rotH)
        } else {
            drawBBox = unrotatedBBox
        }

        // Use cached glow if available and unrotated position hasn't changed.
        // Rotation is handled at draw time via transform, not by regenerating the glow.
        if let cached = annotation.outlineGlowImage, annotation.outlineGlowRect == unrotatedBBox {
            guard let context = NSGraphicsContext.current else { return }
            context.cgContext.saveGState()
            context.cgContext.setAlpha(0.55)
            if annotation.rotation != 0 && annotation.supportsRotation {
                let cx = unrotatedBBox.midX, cy = unrotatedBBox.midY
                context.cgContext.translateBy(x: cx, y: cy)
                context.cgContext.rotate(by: annotation.rotation)
                context.cgContext.translateBy(x: -cx, y: -cy)
            }
            cached.draw(in: unrotatedBBox, from: .zero, operation: .sourceOver, fraction: 1.0)
            context.cgContext.restoreGState()
            return
        }

        let scale: CGFloat = window?.backingScaleFactor ?? 2.0
        let pxW = Int(ceil(unrotatedBBox.width * scale))
        let pxH = Int(ceil(unrotatedBBox.height * scale))
        guard pxW > 0, pxH > 0, pxW < 8000, pxH < 8000 else { return }

        // Render the annotation at rotation=0 into an offscreen bitmap.
        // We temporarily zero out rotation so the glow is cached unrotated.
        let savedRotation = annotation.rotation
        annotation.rotation = 0
        let offscreen = NSImage(size: NSSize(width: unrotatedBBox.width * scale, height: unrotatedBBox.height * scale))
        offscreen.lockFocus()
        guard let offNSCtx = NSGraphicsContext.current else { annotation.rotation = savedRotation; offscreen.unlockFocus(); return }
        offNSCtx.cgContext.scaleBy(x: scale, y: scale)
        offNSCtx.cgContext.translateBy(x: -unrotatedBBox.origin.x, y: -unrotatedBBox.origin.y)
        if annotation.tool == .loupe {
            // Glow only the lens circle. Drawing the full loupe would trace the
            // connecting line + source ring too, and since the glow bitmap is
            // clipped to the lens bounding box, the line produced a broken stray
            // segment. A filled lens circle gives a clean ring glow.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: annotation.loupeLensSquareRect).fill()
        } else {
            annotation.draw(in: offNSCtx)
        }
        offscreen.unlockFocus()
        annotation.rotation = savedRotation

        guard let cgOrig = offscreen.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let ciOrig = CIImage(cgImage: cgOrig)
        guard let dilateFilter = CIFilter(name: "CIMorphologyMaximum") else { return }
        dilateFilter.setValue(ciOrig, forKey: kCIInputImageKey)
        dilateFilter.setValue(outlineWidth * scale, forKey: kCIInputRadiusKey)
        guard let dilated = dilateFilter.outputImage else { return }

        guard let colorFilter = CIFilter(name: "CIFalseColor") else { return }
        let accentCI = CIColor(color: ToolbarLayout.accentColor) ?? CIColor.blue
        colorFilter.setValue(dilated, forKey: kCIInputImageKey)
        colorFilter.setValue(accentCI, forKey: "inputColor0")
        colorFilter.setValue(accentCI, forKey: "inputColor1")
        guard let colored = colorFilter.outputImage else { return }

        guard let subtractFilter = CIFilter(name: "CISourceOutCompositing") else { return }
        subtractFilter.setValue(colored, forKey: kCIInputImageKey)
        subtractFilter.setValue(ciOrig, forKey: kCIInputBackgroundImageKey)
        guard let outline = subtractFilter.outputImage else { return }

        guard let outlineCG = Self.outlineGlowCIContext.createCGImage(outline, from: ciOrig.extent) else { return }

        let outlineImage = NSImage(cgImage: outlineCG, size: unrotatedBBox.size)
        annotation.outlineGlowImage = outlineImage
        annotation.outlineGlowRect = unrotatedBBox

        guard let context = NSGraphicsContext.current else { return }
        context.cgContext.saveGState()
        context.cgContext.setAlpha(0.55)
        if annotation.rotation != 0 && annotation.supportsRotation {
            let cx = unrotatedBBox.midX, cy = unrotatedBBox.midY
            context.cgContext.translateBy(x: cx, y: cy)
            context.cgContext.rotate(by: annotation.rotation)
            context.cgContext.translateBy(x: -cx, y: -cy)
        }
        outlineImage.draw(in: unrotatedBBox, from: .zero, operation: .sourceOver, fraction: 1.0)
        context.cgContext.restoreGState()
    }

    /// Draw a single-annotation delete circle — dark fill, red border, red xmark icon.
    func drawDeleteCircle(in rect: NSRect) {
        // Dark fill
        NSColor(white: 0.12, alpha: 0.94).setFill()
        NSBezierPath(ovalIn: rect).fill()
        // Red border
        let borderColor = NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.9)
        borderColor.setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()
        // Red xmark icon
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        if let xImg = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg) {
            let tinted = NSImage(size: xImg.size, flipped: false) { r in
                xImg.draw(in: r)
                NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - xImg.size.width / 2,
                                    y: rect.midY - xImg.size.height / 2,
                                    width: xImg.size.width, height: xImg.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }

    /// Draw a pill-shaped "Delete N" button below the multi-selection bounding box.
    func drawMultiSelectDeleteButton() {
        guard selectedAnnotations.count > 1 else {
            multiSelectDeleteButtonRect = .zero
            return
        }

        // Compute union bounding rect of all selected annotations
        var unionRect = selectedAnnotations[0].boundingRect
        for ann in selectedAnnotations.dropFirst() {
            unionRect = unionRect.union(ann.boundingRect)
        }

        // Build label
        let count = selectedAnnotations.count
        let label = L("Delete") + " \(count)"
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)

        // Pill dimensions
        let iconSize: CGFloat = 13
        let hPad: CGFloat = 12
        let gap: CGFloat = 5
        let pillW = hPad + iconSize + gap + labelSize.width + hPad
        let pillH: CGFloat = 28
        let pillX = unionRect.midX - pillW / 2
        let pillY = unionRect.minY - pillH - 8

        let pillRect = NSRect(x: pillX, y: pillY, width: pillW, height: pillH)
        multiSelectDeleteButtonRect = pillRect

        // Dark background pill
        NSColor(white: 0.12, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2).fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let borderPath = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: pillH / 2, yRadius: pillH / 2)
        borderPath.lineWidth = 0.5
        borderPath.stroke()

        // Trash icon
        let iconCfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
        if let trashImg = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg) {
            let tinted = NSImage(size: trashImg.size, flipped: false) { rect in
                trashImg.draw(in: rect)
                NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0).setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            let iconY = pillRect.midY - trashImg.size.height / 2
            tinted.draw(in: NSRect(x: pillX + hPad, y: iconY,
                                    width: trashImg.size.width, height: trashImg.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Label
        let labelX = pillX + hPad + iconSize + gap
        let labelY = pillRect.midY - labelSize.height / 2
        (label as NSString).draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttrs)
    }

    func annotationAllHandleRects(for rect: NSRect) -> [(ResizeHandle, NSRect)] {
        let s: CGFloat = 8
        let r = rect
        return [
            (.topLeft, NSRect(x: r.minX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.topRight, NSRect(x: r.maxX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.bottomLeft, NSRect(x: r.minX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.bottomRight, NSRect(x: r.maxX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.top, NSRect(x: r.midX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.bottom, NSRect(x: r.midX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.left, NSRect(x: r.minX - s / 2, y: r.midY - s / 2, width: s, height: s)),
            (.right, NSRect(x: r.maxX - s / 2, y: r.midY - s / 2, width: s, height: s)),
        ]
    }

    // MARK: - Overlay Error

    func showOverlayError(_ message: String) {
        overlayErrorTimer?.invalidate()
        overlayErrorMessage = message
        needsDisplay = true
        overlayErrorTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) {
            [weak self] _ in
            self?.overlayErrorMessage = nil
            self?.needsDisplay = true
        }
    }

    // MARK: - Toolbar Layout

    /// Rebuild toolbar button content. Call when tool, color, or state changes — NOT on every draw.
    func rebuildToolbarLayout() {
        // Clear tooltip before rebuilding — old button views are about to be destroyed
        hoveredTooltip = nil
        hoveredTooltipButtonView = nil

        let movableAnnotations = annotations.contains { $0.isMovable }
        bottomButtons = ToolbarLayout.bottomButtons(
            selectedTool: currentTool, selectedColor: currentColor,
            beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex,
            hasAnnotations: movableAnnotations, isRecording: isRecording,
            effectsActive: effectsActive
        )
        if showBeautifyInOptionsRow {
            for i in bottomButtons.indices {
                if case .tool = bottomButtons[i].action {
                    bottomButtons[i].isSelected = false
                } else if case .beautify = bottomButtons[i].action {
                    bottomButtons[i].isSelected = true
                }
            }
        }
        rightButtons = ToolbarLayout.rightButtons(
            beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex,
            hasAnnotations: movableAnnotations, translateEnabled: translateEnabled,
            isRecording: isRecording,
            isEditorMode: isEditorMode,
            annotationToolsVisible: annotationToolsVisible)

        if isEditorMode {
            // V3 editor: the title-bar row only hosts drawing tools. Color, undo/redo,
            // image actions and outputs live in the window chrome (inspector/footer),
            // which calls the same handleToolbarAction commands.
            bottomButtons = bottomButtons.filter { if case .tool = $0.action { return true }; return false }
            for i in bottomButtons.indices where bottomButtons[i].bgColor == nil {
                bottomButtons[i].tintColor = .secondaryLabelColor
            }
            rightButtons = []
        }

        // Create strip views if needed — add to chrome parent (window content) when in scroll view
        let parent = chromeParentView ?? self
        if bottomStripView == nil {
            let strip = ToolbarStripView(orientation: .horizontal)
            parent.addSubview(strip)
            bottomStripView = strip
        }
        if rightStripView == nil {
            let strip = ToolbarStripView(orientation: isEditorMode ? .horizontal : .vertical)
            parent.addSubview(strip)
            rightStripView = strip
        }

        rightStripView?.orientation = .horizontal
        rightStripView?.barStyle = isEditorMode ? .standard : (isRecording ? .recordBar : .captureBar)
        bottomStripView?.usesWindowAppearance = isEditorMode
        rightStripView?.usesWindowAppearance = isEditorMode
        // Update existing buttons if count matches, rebuild only if structure changed
        if bottomStripView?.buttonViews.count == bottomButtons.count && bottomStripView?.buttonViews.count ?? 0 > 0 {
            bottomStripView?.updateState(from: bottomButtons)
        } else {
            bottomStripView?.setButtons(bottomButtons)
            bottomStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
            bottomStripView?.onRightClick = { [weak self] action, view in
                self?.handleToolbarButtonRightClick(action, anchorView: view)
            }
            bottomStripView?.onHover = { [weak self] action, hovered in
                self?.handleToolbarButtonHover(action, hovered: hovered, strip: self?.bottomStripView)
            }
        }
        if rightStripView?.buttonViews.count == rightButtons.count && rightStripView?.buttonViews.count ?? 0 > 0 {
            rightStripView?.updateState(from: rightButtons)
        } else {
            rightStripView?.setButtons(rightButtons)
            rightStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
            rightStripView?.onRightClick = { [weak self] action, view in
                self?.handleToolbarButtonRightClick(action, anchorView: view)
            }
            rightStripView?.onHover = { [weak self] action, hovered in
                self?.handleToolbarButtonHover(action, hovered: hovered, strip: self?.rightStripView)
            }
        }
        // Move button needs onMouseDown for press-and-drag (synchronous tracking loop)
        for bv in rightStripView?.buttonViews ?? [] {
            if case .moveSelection = bv.action, bv.onMouseDown == nil {
                bv.onMouseDown = { [weak self] _ in self?.handleToolbarAction(.moveSelection) }
            }
        }

        // Rebuild options row content
        if toolHasOptionsRow {
            if toolOptionsRowView == nil {
                let row = ToolOptionsRowView()
                row.overlayView = self
                if isEditorMode, let chrome = parent as? EditorChromeView {
                    chrome.installOptions(row)
                } else {
                    parent.addSubview(row)
                }
                toolOptionsRowView = row
            }
            // Don't overwrite annotation-specific options when editing a selected annotation
            if let ann = selectedAnnotation, toolOptionsRowView?.editingAnnotation === ann {
                // Already showing this annotation's options — skip rebuild
            } else {
                toolOptionsRowView?.rebuild(for: currentTool)
            }
        }

        updateCaptureHint()
        repositionToolbars()
        updateResolutionBox()
    }

    /// mac-capture.html `.hint`: top-right shortcut reminder in the selected state.
    func updateCaptureHint() {
        let visible = !isEditorMode && !isRecording && !isScrollCapturing && showToolbars && state == .selected
            && !islandCollapsed
        guard visible else { captureHintView?.isHidden = true; return }
        let hint = captureHintView ?? {
            let view = CaptureHintView(items: [
                ("Space", L("Hold to move selection")), ("⇧", L("Square")),
                ("↩", L("Quick capture")), ("esc", L("Cancel")),
            ], compact: true)
            addSubview(view)
            captureHintView = view
            return view
        }()
        // Positioned inside the control island by layoutCaptureIsland().
        hint.isHidden = false
    }

    /// Reposition toolbar strips based on current selection/bounds. Cheap — safe to call from draw().
    func repositionToolbars() {
        guard let bottomStrip = bottomStripView, let rightStrip = rightStripView else { return }
        if captureHintView != nil { updateCaptureHint() }

        // In editor mode, let toolbar gap clicks pass through to the image beneath
        bottomStrip.passesThrough = isEditorMode
        rightStrip.passesThrough = isEditorMode

        let visible = showToolbars && state == .selected && !isScrollCapturing
        let bottomHasButtons = bottomStrip.buttonViews.count > 0
        bottomStrip.isHidden = !visible || !bottomHasButtons
        let rightHasButtons = rightStrip.buttonViews.count > 0
        rightStrip.isHidden = !visible || !rightHasButtons
        toolOptionsRowView?.isHidden = !visible || !toolHasOptionsRow || !bottomHasButtons
        let usesIsland = visible && !isEditorMode && !isRecording
        if !usesIsland { hideCaptureIsland() }
        if isEditorMode || isRecording {
            bottomStrip.drawsChromeBackground = true
            rightStrip.drawsChromeBackground = true
            toolOptionsRowView?.isIslandHosted = false
        }
        guard visible else {
            // Toolbars hidden (deselected / scroll capture): dismiss the
            // resolution box and clear the chrome rects so isPointOnChrome
            // doesn't see stale areas.
            dismissResolutionBox()
            optionsRowRect = .zero
            return
        }

        // Anchor rect: beautify-expanded when active, selection otherwise
        let config = beautifyConfig
        let bPad = config.padding
        let titleBarH: CGFloat = config.mode == .window ? 28 : 0
        let expandedAnchor = NSRect(
            x: selectionRect.minX - bPad, y: selectionRect.minY - bPad,
            width: selectionRect.width + bPad * 2,
            height: selectionRect.height + titleBarH + bPad * 2)
        let anchorRect: NSRect
        if beautifyToolbarAnimProgress < 1.0 {
            let t = beautifyToolbarAnimProgress
            let eased = 1.0 - (1.0 - t) * (1.0 - t)
            let fromRect = beautifyToolbarAnimTarget ? selectionRect : expandedAnchor
            let toRect = beautifyToolbarAnimTarget ? expandedAnchor : selectionRect
            anchorRect = NSRect(
                x: fromRect.minX + (toRect.minX - fromRect.minX) * eased,
                y: fromRect.minY + (toRect.minY - fromRect.minY) * eased,
                width: fromRect.width + (toRect.width - fromRect.width) * eased,
                height: fromRect.height + (toRect.height - fromRect.height) * eased
            )
        } else if beautifyEnabled && !isScrollCapturing && !isRecording {
            anchorRect = expandedAnchor
        } else {
            anchorRect = selectionRect
        }

        let rightSize = rightStrip.frame.size

        let bottomSize = bottomStrip.frame.size

        if isEditorMode {
            // EditorChromeView owns the editor layout (tool row, inspector, footer).
            if let chrome = chromeParentView as? EditorChromeView {
                if chrome.toolStrip !== bottomStrip { chrome.toolStrip = bottomStrip }
                chrome.scheduleRefresh()
            }
            _ = (rightSize, bottomSize)
        } else if isRecording {
            // mac-recording.html "录制准备": one labelled control bar, bottom-centre of the screen.
            let x = max(bounds.minX + 8, min(bounds.midX - rightSize.width / 2, bounds.maxX - rightSize.width - 8))
            rightStrip.frame.origin = NSPoint(x: x, y: bounds.minY + 84)
        } else {
            // mac-capture.html `.island`: options row, annotation strip, capture bar and
            // shortcut hint stacked inside one draggable control island.
            layoutCaptureIsland(capStrip: rightStrip, toolStrip: bottomStrip)
        }

        // bottomBarRect is the intended OVERLAY-space rect. Build it from the
        // strip's size + the origin we just set (rather than reading back the
        // live frame, which is panel-local when the strip is glass-panel-hosted).
        bottomBarRect = NSRect(origin: bottomStrip.frame.origin, size: bottomStrip.frame.size)
        rightBarRect = rightStrip.frame

        // Position options row — above bottom bar in editor, below in overlay
        if usesIsland {
            if let row = toolOptionsRowView, !row.isHidden {
                optionsRowRect = NSRect(origin: row.frame.origin, size: row.frame.size)
            } else {
                optionsRowRect = .zero
            }
        } else if let row = toolOptionsRowView, !row.isHidden {
            // Use the wider of the bottom bar and the row's natural content width
            let rowW = max(bottomBarRect.width, row.contentWidth)
            if !isEditorMode { row.frame.size.width = rowW }
            let rowY: CGFloat
            if isEditorMode {
                // In editor mode, center the options row the same way as the bottom bar
                // The inspector reflow already ran in rebuild(for:); EditorChromeView places it.
                row.autoresizingMask = []
            } else {
                // Centered above the annotation strip (mac-capture.html .orow), clamped to view bounds
                var rowX = bottomBarRect.midX - rowW / 2
                rowX = max(4, min(rowX, bounds.maxX - rowW - 4))
                rowY = isRecording ? bottomBarRect.minY - row.frame.height - 2 : bottomBarRect.maxY + 6
                row.frame.origin = NSPoint(x: rowX, y: rowY)
            }
            optionsRowRect = NSRect(origin: row.frame.origin, size: row.frame.size)
        } else {
            optionsRowRect = .zero
        }
    }

    // MARK: - Unified control island

    static let islandPinnedKey = "captureIslandPinned"
    static let islandPinnedXKey = "captureIslandPinnedCenterX"
    static let islandPinnedYKey = "captureIslandPinnedBottomY"
    static let islandSnapDistance: CGFloat = 40

    var islandPinned: Bool { UserDefaults.standard.bool(forKey: Self.islandPinnedKey) }

    func ensureCaptureIsland(below strip: NSView) -> CaptureIslandView {
        if let island = captureIsland { return island }
        let island = CaptureIslandView()
        island.onReset = { [weak self] in self?.resetIslandPosition() }
        island.onTogglePin = { [weak self] in self?.toggleIslandPinned() }
        island.onToggleCollapse = { [weak self] in self?.toggleIslandCollapsed() }
        island.onDragBegan = { [weak self] in self?.beginIslandDrag() }
        island.onDragMoved = { [weak self] delta in self?.moveIslandDrag(by: delta) }
        island.onDragEnded = { [weak self] in self?.endIslandDrag() }
        let parent = strip.superview ?? self
        parent.addSubview(island, positioned: .below, relativeTo: strip)
        captureIsland = island
        return island
    }

    func hideCaptureIsland() {
        captureIsland?.isHidden = true
        islandSnapGuides.forEach { $0.isHidden = true }
        islandRect = .zero
    }

    /// Default anchor (bottom-centre) or the top-centre snap slot for an island of `size`.
    func islandSlotAnchor(top: Bool, size: NSSize) -> NSPoint {
        top ? NSPoint(x: bounds.midX, y: bounds.maxY - 44 - size.height)
            : NSPoint(x: bounds.midX, y: bounds.minY + 26)
    }

    func pinnedIslandAnchor() -> NSPoint? {
        guard islandPinned, bounds.width > 1, bounds.height > 1 else { return nil }
        let d = UserDefaults.standard
        return NSPoint(x: bounds.minX + CGFloat(d.double(forKey: Self.islandPinnedXKey)) * bounds.width,
                       y: bounds.minY + CGFloat(d.double(forKey: Self.islandPinnedYKey)) * bounds.height)
    }

    func clampedIslandOrigin(anchor: NSPoint, size: NSSize) -> NSPoint {
        let x = max(bounds.minX + 8, min(anchor.x - size.width / 2, bounds.maxX - size.width - 8))
        let y = max(bounds.minY + 8, min(anchor.y, bounds.maxY - size.height - 8))
        return NSPoint(x: round(x), y: round(y))
    }

    func layoutCaptureIsland(capStrip: ToolbarStripView, toolStrip: ToolbarStripView) {
        let island = ensureCaptureIsland(below: toolStrip)
        island.isPinned = islandPinned
        island.isCollapsed = islandCollapsed
        island.currentToolSymbol = toolStrip.buttonViews.first { bv in
            if case .tool = bv.action { return bv.isOn }
            return false
        }?.sfSymbol
        capStrip.drawsChromeBackground = false
        toolStrip.drawsChromeBackground = false
        toolOptionsRowView?.isIslandHosted = true

        let pad = CaptureIslandView.padding
        let toolsVisible = !islandCollapsed && annotationToolsVisible && !toolStrip.isHidden
        let row: ToolOptionsRowView? = {
            guard toolsVisible, let r = toolOptionsRowView, !r.isHidden else { return nil }
            return r
        }()
        let hint: CaptureHintView? = (!islandCollapsed && captureHintView?.isHidden == false) ? captureHintView : nil
        if !toolsVisible { toolStrip.isHidden = true }
        if row == nil { toolOptionsRowView?.isHidden = true }
        if hint == nil { captureHintView?.isHidden = true }
        capStrip.isHidden = islandCollapsed || capStrip.buttonViews.isEmpty

        let size: NSSize
        var contentW: CGFloat = 0
        if islandCollapsed {
            size = CaptureIslandView.collapsedSize
        } else {
            contentW = capStrip.frame.width
            if toolsVisible { contentW = max(contentW, toolStrip.frame.width) }
            if let row { contentW = max(contentW, row.contentWidth) }
            if let hint { contentW = max(contentW, hint.frame.width) }
            contentW = ceil(contentW)
            var h = pad + capStrip.frame.height
            if let hint { h += 4 + hint.frame.height }
            if toolsVisible { h += 13 + toolStrip.frame.height }
            if let row { h += 6 + row.frame.height }
            h += CaptureIslandView.headerHeight
            size = NSSize(width: contentW + pad * 2, height: ceil(h))
        }

        let anchor = islandAnchor ?? pinnedIslandAnchor() ?? islandSlotAnchor(top: false, size: size)
        let origin = clampedIslandOrigin(anchor: anchor, size: size)
        island.frame = NSRect(origin: origin, size: size)
        island.isHidden = false
        islandRect = island.frame
        guard !islandCollapsed else { island.separatorY = nil; return }

        let midX = origin.x + size.width / 2
        var y = origin.y + pad
        if let hint {
            hint.frame.origin = NSPoint(x: round(midX - hint.frame.width / 2), y: y)
            y += hint.frame.height + 4
        }
        capStrip.frame.origin = NSPoint(x: round(midX - capStrip.frame.width / 2), y: y)
        y += capStrip.frame.height
        if toolsVisible {
            island.separatorY = y + 6 - origin.y
            y += 13
            toolStrip.frame.origin = NSPoint(x: round(midX - toolStrip.frame.width / 2), y: y)
            y += toolStrip.frame.height
        } else {
            island.separatorY = nil
        }
        if let row {
            y += 6
            row.frame.size.width = contentW
            row.frame.origin = NSPoint(x: origin.x + pad, y: y)
        }
    }

    func beginIslandDrag() {
        guard !islandPinned, islandRect.width > 1 else { return }
        islandDragStartAnchor = NSPoint(x: islandRect.midX, y: islandRect.minY)
        let size = islandRect.size
        if islandSnapGuides.isEmpty, let island = captureIsland {
            for _ in 0..<2 {
                let guide = IslandSnapGuideView()
                (island.superview ?? self).addSubview(guide, positioned: .below, relativeTo: island)
                islandSnapGuides.append(guide)
            }
        }
        for (index, guide) in islandSnapGuides.enumerated() {
            let top = index == 1
            let anchor = islandSlotAnchor(top: top, size: size)
            guide.frame = NSRect(origin: clampedIslandOrigin(anchor: anchor, size: size), size: size)
            guide.title = top ? L("Top center") : L("Default position · bottom center")
            guide.isHit = false
            guide.isHidden = false
        }
    }

    func moveIslandDrag(by delta: NSPoint) {
        guard let start = islandDragStartAnchor else { return }
        islandAnchor = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        repositionToolbars()
        for guide in islandSnapGuides { guide.isHit = islandNear(guide.frame.origin) }
    }

    func islandNear(_ origin: NSPoint) -> Bool {
        abs(islandRect.minX - origin.x) < Self.islandSnapDistance
            && abs(islandRect.minY - origin.y) < Self.islandSnapDistance
    }

    func endIslandDrag() {
        guard islandDragStartAnchor != nil else { return }
        islandDragStartAnchor = nil
        if let hit = islandSnapGuides.first(where: { islandNear($0.frame.origin) }) {
            islandAnchor = NSPoint(x: hit.frame.midX, y: hit.frame.minY)
        } else if islandRect.width > 1 {
            islandAnchor = NSPoint(x: islandRect.midX, y: islandRect.minY)
        }
        islandSnapGuides.forEach { $0.isHidden = true }
        repositionToolbars()
    }

    func resetIslandPosition() {
        guard !islandPinned else { return }
        islandAnchor = nil
        repositionToolbars()
    }

    /// Pinning remembers the position (as a fraction of the screen) for later captures
    /// until the user unpins it.
    func toggleIslandPinned() {
        let d = UserDefaults.standard
        if islandPinned {
            if islandRect.width > 1 { islandAnchor = NSPoint(x: islandRect.midX, y: islandRect.minY) }
            d.set(false, forKey: Self.islandPinnedKey)
            d.removeObject(forKey: Self.islandPinnedXKey)
            d.removeObject(forKey: Self.islandPinnedYKey)
        } else if islandRect.width > 1, bounds.width > 1, bounds.height > 1 {
            d.set(Double((islandRect.midX - bounds.minX) / bounds.width), forKey: Self.islandPinnedXKey)
            d.set(Double((islandRect.minY - bounds.minY) / bounds.height), forKey: Self.islandPinnedYKey)
            d.set(true, forKey: Self.islandPinnedKey)
            islandAnchor = nil
        }
        repositionToolbars()
    }

    func toggleIslandCollapsed() {
        // Anchors are bottom-centre points, so the island keeps its bottom edge and
        // centre while it changes size; re-anchor a custom position to its clamped frame.
        if islandAnchor != nil, islandRect.width > 1 {
            islandAnchor = NSPoint(x: islandRect.midX, y: islandRect.minY)
        }
        islandCollapsed.toggle()
        captureIsland?.isCollapsed = islandCollapsed
        updateCaptureHint()
        repositionToolbars()
    }

    var canToggleIsland: Bool {
        !isEditorMode && !isRecording && !isScrollCapturing && showToolbars && state == .selected
    }

    /// Liquid Glass: lift each toolbar surface (bottom strip, right strip, tool
    /// options row) into a floating child panel above the overlay window,
    /// positioned at its screen rect, so its glass refracts the overlay
    /// (screenshot + dim) beneath. `repositionToolbars` has just set the intended
    /// OVERLAY-space frames; we use those (not the live panel-local frames).
    /// Dismiss the resolution box. It is recreated on demand by
    /// updateResolutionBox(), so it's fully disposed (not just hidden) on
    /// deselect to avoid leaving a stray box behind.
    func dismissResolutionBox() {
        resolutionBox?.removeFromSuperview()
        resolutionBox = nil
        resolutionBoxRect = .zero
    }

}
