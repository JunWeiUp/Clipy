import AVFoundation
import Cocoa
import UniformTypeIdentifiers

extension OverlayView {
    // MARK: - Custom Color Persistence
    func saveCustomColors() {
        let hexArray = customColors.map { color -> String in
            guard let c = color else { return "" }
            return colorToHexString(c)
        }
        UserDefaults.standard.set(hexArray, forKey: "customColors")
    }
    /// The expanded rect including beautify padding (for live preview).


    func drawBeautifyPreview(context: NSGraphicsContext) {
        let config = beautifyConfig
        let pad = config.padding
        let cornerRadius = config.isWindowSnap ? 10 : config.cornerRadius  // native macOS corner radius for snapped windows
        let shadowRadius = config.shadowRadius
        let shadowOffset = BeautifyRenderer.shadowOffset(for: shadowRadius)

        // Compute the expanded frame around the selection.
        // Shadow extends downward (negative Y in AppKit), so expand the origin down.
        let shadowBleed = shadowRadius + shadowOffset
        let expandedRect: NSRect
        if config.mode == .window && !config.isWindowSnap {
            let titleBarH: CGFloat = 28
            expandedRect = NSRect(
                x: selectionRect.minX - pad - shadowBleed,
                y: selectionRect.minY - pad - shadowBleed,
                width: selectionRect.width + pad * 2 + shadowBleed * 2,
                height: selectionRect.height + titleBarH + pad * 2 + shadowBleed * 2
            )
        } else {
            expandedRect = NSRect(
                x: selectionRect.minX - pad - shadowBleed,
                y: selectionRect.minY - pad - shadowBleed,
                width: selectionRect.width + pad * 2 + shadowBleed * 2,
                height: selectionRect.height + pad * 2 + shadowBleed * 2
            )
        }

        // Clear the dark overlay for the expanded area to make the preview visible
        context.saveGraphicsState()
        if !isEditorMode {
            // Overlay: re-draw the screenshot in the expanded area to erase the dark overlay,
            // then draw the dark overlay back so we have a clean base for the gradient.
            context.cgContext.saveGState()
            NSBezierPath(rect: expandedRect).addClip()
            if let image = screenshotImage {
                image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            }
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(rect: expandedRect).fill()
            context.cgContext.restoreGState()
        }

        // Position the image/window centered within the expanded rect (not affected by shadow bleed)
        let innerX = selectionRect.minX - pad
        let innerY = selectionRect.minY - pad

        // Draw gradient background (inner rect without shadow bleed)
        let bgRect: NSRect
        if config.mode == .window && !config.isWindowSnap {
            let titleBarH: CGFloat = 28
            bgRect = NSRect(
                x: innerX, y: innerY, width: selectionRect.width + pad * 2,
                height: selectionRect.height + titleBarH + pad * 2)
        } else {
            bgRect = NSRect(
                x: innerX, y: innerY, width: selectionRect.width + pad * 2,
                height: selectionRect.height + pad * 2)
        }
        context.cgContext.saveGState()
        let bgPath = NSBezierPath(
            roundedRect: bgRect, xRadius: config.bgRadius, yRadius: config.bgRadius)
        bgPath.addClip()
        BeautifyRenderer.drawGradientBackground(
            in: bgRect, config: config, context: context.cgContext)
        context.cgContext.restoreGState()

        // Compute the image rect inside the expanded frame
        let imageRect: NSRect
        let windowRect: NSRect

        if config.mode == .window && !config.isWindowSnap {
            let titleBarH: CGFloat = 28
            let windowW = selectionRect.width
            let windowH = selectionRect.height + titleBarH
            windowRect = NSRect(
                x: innerX + pad,
                y: innerY + pad,
                width: windowW,
                height: windowH
            )
            imageRect = NSRect(
                x: windowRect.minX,
                y: windowRect.minY,
                width: windowW,
                height: windowH - titleBarH
            )
        } else {
            imageRect = NSRect(
                x: innerX + pad,
                y: innerY + pad,
                width: selectionRect.width,
                height: selectionRect.height
            )
            windowRect = imageRect
        }

        // Drop shadow (not for snapped windows — handled via transparency layer below)
        if shadowRadius > 0 && !config.isWindowSnap {
            let shadowPath = NSBezierPath(
                roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius)
            BeautifyRenderer.drawShadowedPath(shadowPath, radius: shadowRadius)
        }

        if config.isWindowSnap {
            // Snapped window: use independently captured window image (has real transparent corners).
            // Draw it directly on top of the gradient — transparent corners reveal the gradient.
            context.cgContext.saveGState()

            // Drop shadow from the window shape
            if shadowRadius > 0 {
                context.cgContext.saveGState()
                context.cgContext.setShadow(
                    offset: CGSize(
                        width: 0,
                        height: -BeautifyRenderer.contactShadowOffset(for: shadowRadius)),
                    blur: BeautifyRenderer.contactShadowBlur(for: shadowRadius),
                    color: NSColor.black.withAlphaComponent(
                        BeautifyRenderer.contactShadowAlpha(for: shadowRadius)).cgColor)
                if let windowImg = snappedWindowImage {
                    windowImg.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                } else if let image = screenshotImage {
                    let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                    drawImage.draw(
                        in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
                }
                context.cgContext.restoreGState()

                context.cgContext.saveGState()
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: -shadowOffset),
                    blur: shadowRadius,
                    color: NSColor.black.withAlphaComponent(
                        BeautifyRenderer.shadowAlpha(for: shadowRadius)).cgColor)
                if let windowImg = snappedWindowImage {
                    windowImg.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                } else if let image = screenshotImage {
                    let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                    drawImage.draw(
                        in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
                }
                context.cgContext.restoreGState()
            }

            if let windowImg = snappedWindowImage {
                windowImg.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else if let image = screenshotImage {
                // Fallback: crop from screenshot (before window capture completes)
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(
                    in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
            }

            // Draw annotations shifted to the preview position
            let dx = imageRect.minX - selectionRect.minX
            let dy = imageRect.minY - selectionRect.minY
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: dx, y: dy)
            }
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            Annotation.drawHighlightDim(for: annotations, extra: currentAnnotation, in: selectionRect)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: -dx, y: -dy)
            }

            context.cgContext.restoreGState()
        } else if config.mode == .window {
            // Draw window chrome
            let titleBarH: CGFloat = 28

            context.cgContext.saveGState()
            NSBezierPath(roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius)
                .addClip()

            // Window background
            NSColor(white: 0.97, alpha: 1.0).setFill()
            NSBezierPath(rect: windowRect).fill()

            // Title bar
            let titleBarRect = NSRect(
                x: windowRect.minX, y: windowRect.maxY - titleBarH, width: windowRect.width,
                height: titleBarH)
            NSColor(white: 0.94, alpha: 1.0).setFill()
            NSBezierPath(rect: titleBarRect).fill()

            // Separator
            NSColor(white: 0.82, alpha: 1.0).setFill()
            NSBezierPath(
                rect: NSRect(
                    x: windowRect.minX, y: titleBarRect.minY - 0.5, width: windowRect.width,
                    height: 0.5)
            ).fill()

            // Traffic lights
            let buttonY = titleBarRect.midY
            let buttonRadius: CGFloat = 6
            let buttonStartX = windowRect.minX + 14
            let buttonSpacing: CGFloat = 20
            let trafficLights: [(NSColor, NSColor)] = [
                (
                    NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
                    NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.22, alpha: 1.0)
                ),
                (
                    NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1.0),
                    NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.15, alpha: 1.0)
                ),
                (
                    NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 1.0),
                    NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.25, alpha: 1.0)
                ),
            ]
            for (i, (fill, ring)) in trafficLights.enumerated() {
                let cx = buttonStartX + CGFloat(i) * buttonSpacing
                let circleRect = NSRect(
                    x: cx - buttonRadius, y: buttonY - buttonRadius, width: buttonRadius * 2,
                    height: buttonRadius * 2)
                fill.setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                ring.setStroke()
                let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 0.5
                border.stroke()
            }

            // Draw screenshot in content area (clipped to window shape), with effects if active
            if let image = screenshotImage {
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(
                    in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
            }

            // Draw annotations shifted to the preview position (including current live annotation)
            let dx = imageRect.minX - selectionRect.minX
            let dy = imageRect.minY - selectionRect.minY
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: dx, y: dy)
            }
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            Annotation.drawHighlightDim(for: annotations, extra: currentAnnotation, in: selectionRect)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: -dx, y: -dy)
            }

            context.cgContext.restoreGState()
        } else {
            // Rounded mode — just rounded corners on the image
            context.cgContext.saveGState()
            NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius)
                .addClip()

            if let image = screenshotImage {
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(in: imageRect, from: selectionRect, operation: .copy, fraction: 1.0)
            }

            // Draw annotations shifted to preview position (including current live annotation)
            let dx = imageRect.minX - selectionRect.minX
            let dy = imageRect.minY - selectionRect.minY
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: dx, y: dy)
            }
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            Annotation.drawHighlightDim(for: annotations, extra: currentAnnotation, in: selectionRect)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: -dx, y: -dy)
            }

            context.cgContext.restoreGState()
        }

        context.restoreGraphicsState()
    }

    /// Whether the current tool should show the options row
    var toolHasOptionsRow: Bool {
        // Show options row for a selected annotation's tool even when currentTool is .select
        if selectedAnnotation != nil && toolOptionsRowView?.editingAnnotation != nil {
            return true
        }
        switch currentTool {
        case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe, .measure,
            .pixelate, .stamp, .highlight:
            return true
        case .text:
            return true
        default:
            return showBeautifyInOptionsRow
        }
    }

    func startBeautifyToolbarAnimation() {
        beautifyToolbarAnimProgress = 0
        beautifyToolbarAnimTarget = beautifyEnabled
        beautifyToolbarAnimTimer?.invalidate()
        beautifyToolbarAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true)
        { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.beautifyToolbarAnimProgress += 0.08  // ~12 frames = 0.2s
            if self.beautifyToolbarAnimProgress >= 1.0 {
                self.beautifyToolbarAnimProgress = 1.0
                timer.invalidate()
                self.beautifyToolbarAnimTimer = nil
            }
            self.needsDisplay = true
        }
    }

    // MARK: - Color Sampler Preview

    /// Sample the pixel color at `canvasPoint` from the screenshot and draw a live preview.
    func drawColorSamplerPreview(at canvasPoint: NSPoint) {
        guard let screenshot = screenshotImage else { return }
        guard let result = sampleColor(from: screenshot, at: canvasPoint) else { return }
        let sampledColor = result.color
        let hexStr = result.hex

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let copyFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let hexAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let copyAttrs: [NSAttributedString.Key: Any] = [
            .font: copyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]

        let hexSize = (hexStr as NSString).size(withAttributes: hexAttrs)
        let copyText = L("Right-click to copy")
        let copySize = (copyText as NSString).size(withAttributes: copyAttrs)

        let swatchSize: CGFloat = 16
        let padding: CGFloat = 8
        let gap: CGFloat = 6
        let labelW = padding + swatchSize + gap + max(hexSize.width, copySize.width) + padding
        let labelH = padding + hexSize.height + 2 + copySize.height + padding

        let labelX = canvasPoint.x + 16
        let labelY = canvasPoint.y - labelH - 8
        let labelRect = NSRect(x: labelX, y: labelY, width: labelW, height: labelH)

        // Background pill
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()

        // Color swatch
        let swatchRect = NSRect(
            x: labelRect.minX + padding,
            y: labelRect.midY - swatchSize / 2,
            width: swatchSize, height: swatchSize)
        sampledColor.setFill()
        NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let swatchBorder = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
        swatchBorder.lineWidth = 0.5
        swatchBorder.stroke()

        // Hex text + copy hint
        let textX = swatchRect.maxX + gap
        (hexStr as NSString).draw(
            at: NSPoint(x: textX, y: labelRect.maxY - padding - hexSize.height),
            withAttributes: hexAttrs)
        (copyText as NSString).draw(
            at: NSPoint(x: textX, y: labelRect.minY + padding), withAttributes: copyAttrs)

        context.restoreGraphicsState()
    }

    /// Sample a pixel color from the screenshot at the given canvas-space point.
    /// Returns (NSColor for display, hex string with raw sRGB values matching what other tools report).
    func sampleColor(from image: NSImage, at canvasPoint: NSPoint) -> (
        color: NSColor, hex: String
    )? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let imgSize = image.size
        let drawRect = captureDrawRect

        let px = (canvasPoint.x - drawRect.origin.x) * imgSize.width / drawRect.width
        let py = (canvasPoint.y - drawRect.origin.y) * imgSize.height / drawRect.height
        guard px >= 0, py >= 0, px < imgSize.width, py < imgSize.height else { return nil }

        // Map to CGImage pixel coordinates.
        let scaleX = CGFloat(cgImage.width) / imgSize.width
        let scaleY = CGFloat(cgImage.height) / imgSize.height
        let cgX = Int(px * scaleX)
        let cgY = Int(CGFloat(cgImage.height) - 1 - py * scaleY)  // flip Y for CGImage (top-left origin)
        guard cgX >= 0, cgX < cgImage.width, cgY >= 0, cgY < cgImage.height else { return nil }

        // Render the single pixel into a known-format 1×1 sRGB bitmap to get correct raw values.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let ctx = CGContext(
                data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(
            cgImage,
            in: CGRect(
                x: -CGFloat(cgX), y: -(CGFloat(cgImage.height) - 1 - CGFloat(cgY)),
                width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        guard let data = ctx.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let a = CGFloat(ptr[3]) / 255
        guard a > 0 else { return nil }
        // Undo premultiplication
        let r = UInt8(min(255, CGFloat(ptr[0]) / a))
        let g = UInt8(min(255, CGFloat(ptr[1]) / a))
        let b = UInt8(min(255, CGFloat(ptr[2]) / a))

        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let color = NSColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        return (color, hex)
    }

    // MARK: - Editor Image Transforms

    func flipImageHorizontally() {
        guard let original = screenshotImage,
            let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Save state for undo
        let prevImage = original.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let w = cgImage.width
        let h = cgImage.height
        // Preserve the source image's color space so colors stay correct.
        let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0, space: cs,
                bitmapInfo: bitmapInfo)
        else { return }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flipped = ctx.makeImage() else { return }

        screenshotImage = NSImage(cgImage: flipped, size: original.size)

        // Mirror annotation X coordinates around the image center
        let imgW = original.size.width
        for ann in annotations {
            ann.startPoint.x = selectionRect.minX + (selectionRect.maxX - ann.startPoint.x)
            ann.endPoint.x = selectionRect.minX + (selectionRect.maxX - ann.endPoint.x)
            if let cp = ann.controlPoint {
                ann.controlPoint = NSPoint(
                    x: selectionRect.minX + (selectionRect.maxX - cp.x), y: cp.y)
            }
            // Mirror freeform points
            if let pts = ann.points {
                ann.points = pts.map {
                    NSPoint(x: selectionRect.minX + (selectionRect.maxX - $0.x), y: $0.y)
                }
            }
        }

        cachedCompositedImage = nil
        needsDisplay = true
    }

    func flipImageVertically() {
        guard let original = screenshotImage,
            let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let prevImage = original.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let w = cgImage.width
        let h = cgImage.height
        let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0, space: cs,
                bitmapInfo: bitmapInfo)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flipped = ctx.makeImage() else { return }

        screenshotImage = NSImage(cgImage: flipped, size: original.size)

        // Mirror annotation Y coordinates around the image center
        for ann in annotations {
            ann.startPoint.y = selectionRect.minY + (selectionRect.maxY - ann.startPoint.y)
            ann.endPoint.y = selectionRect.minY + (selectionRect.maxY - ann.endPoint.y)
            if let cp = ann.controlPoint {
                ann.controlPoint = NSPoint(
                    x: cp.x, y: selectionRect.minY + (selectionRect.maxY - cp.y))
            }
            if let pts = ann.points {
                ann.points = pts.map {
                    NSPoint(x: $0.x, y: selectionRect.minY + (selectionRect.maxY - $0.y))
                }
            }
        }

        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Add a captured image as a draggable stamp annotation, placed below the current canvas.
    /// The canvas auto-expands to fit. Used by "Add Capture" in the editor.
    func addCaptureImage(_ newImage: NSImage) {
        let imgW = newImage.size.width
        let imgH = newImage.size.height

        // Place below the current canvas, left-aligned
        let placeY = -imgH  // just below origin (canvas will expand)

        let ann = Annotation(
            tool: .stamp,
            startPoint: NSPoint(x: 0, y: placeY),
            endPoint: NSPoint(x: imgW, y: placeY + imgH),
            color: NSColor.white.withAlphaComponent(0),
            strokeWidth: 0)
        ann.stampImage = newImage
        ann.isCaptureStamp = true

        annotations.append(ann)
        undoStack.append(.added(ann))
        redoStack.removeAll()

        // Auto-select so user can move/resize immediately
        currentTool = .select
        selectedAnnotation = ann
        cachedCompositedImage = nil

        // Expand the canvas to fit the new annotation
        expandCanvasToFitAnnotations()
        rebuildToolbarLayout()

        // Keep the editor top-bar size label in sync (the canvas may have grown).
        if let cg = screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let topBar = chromeParentView as? EditorChromeView {
            topBar.updateSizeLabel(width: cg.width, height: cg.height)
        }

        needsDisplay = true
    }

    /// Resizes the canvas to tightly fit the original image content plus all annotations.
    /// Grows or shrinks as needed. Shifts everything so origin stays at (0,0).
    /// Only runs the expensive pixel scan when add-capture stamps are present.
    func expandCanvasToFitAnnotations() {
        guard isEditorMode, let original = screenshotImage,
              let oldCG = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Only resize canvas when there are add-capture image stamps that might be outside bounds.
        // Normal annotations (arrows, text, etc.) don't need canvas resizing.
        let hasImageStamps = annotations.contains { $0.tool == .stamp && $0.stampImage != nil }
        guard hasImageStamps else { return }

        let scale = CGFloat(oldCG.width) / original.size.width

        // Detect the non-transparent bounding box of the original image.
        let opaqueRect: NSRect
        if let cached = cachedOpaqueRect {
            opaqueRect = cached
        } else {
            opaqueRect = opaqueContentRect(of: oldCG, scale: scale)
            cachedOpaqueRect = opaqueRect
        }

        // Compute bounding box of opaque image content + all annotations
        var minX: CGFloat = opaqueRect.minX
        var minY: CGFloat = opaqueRect.minY
        var maxX: CGFloat = opaqueRect.maxX
        var maxY: CGFloat = opaqueRect.maxY

        for ann in annotations {
            let r = ann.boundingRect
            guard r.width > 0, r.height > 0 else { continue }
            minX = min(minX, r.minX)
            minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX)
            maxY = max(maxY, r.maxY)
        }

        let targetRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // If canvas already matches, nothing to do
        if abs(minX) < 1 && abs(minY) < 1
            && abs(maxX - selectionRect.width) < 1 && abs(maxY - selectionRect.height) < 1 {
            return
        }

        let newPtW = targetRect.width
        let newPtH = targetRect.height
        let newPxW = max(1, Int(newPtW * scale))
        let newPxH = max(1, Int(newPtH * scale))

        let cs = oldCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: newPxW, height: newPxH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Draw old image offset so that targetRect.origin maps to (0,0)
        let drawX = -targetRect.origin.x * scale
        let drawY = -targetRect.origin.y * scale
        ctx.draw(oldCG, in: CGRect(x: drawX, y: drawY, width: CGFloat(oldCG.width), height: CGFloat(oldCG.height)))

        guard let newCG = ctx.makeImage() else { return }
        let prevImage = original.copy() as! NSImage
        let shiftDx = -targetRect.origin.x
        let shiftDy = -targetRect.origin.y
        let offsets = annotations.map { ($0, shiftDx, shiftDy) }
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: offsets))

        screenshotImage = NSImage(cgImage: newCG, size: NSSize(width: newPtW, height: newPtH))
        cachedOpaqueRect = nil  // invalidate — image content changed

        // Shift all annotations so they align with the new origin
        if shiftDx != 0 || shiftDy != 0 {
            for ann in annotations {
                ann.move(dx: shiftDx, dy: shiftDy)
            }
        }

        selectionRect = NSRect(origin: .zero, size: NSSize(width: newPtW, height: newPtH))
        frame.size = NSSize(width: newPtW, height: newPtH)
        cachedCompositedImage = nil
    }

    /// Returns the bounding rect (in point coords) of non-transparent pixels in the image.
    /// Uses fast row/column scanning on the raw pixel data.
    func opaqueContentRect(of cgImage: CGImage, scale: CGFloat) -> NSRect {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else {
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        // Alpha channel offset depends on bitmap info
        let alphaInfo = CGImageAlphaInfo(rawValue: cgImage.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let alphaOffset: Int
        switch alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: alphaOffset = 0
        case .premultipliedLast, .last, .noneSkipLast: alphaOffset = 3
        default: alphaOffset = 3
        }

        var minRow = h, maxRow = 0, minCol = w, maxCol = 0

        for row in 0..<h {
            let rowBase = row * bytesPerRow
            for col in 0..<w {
                let alpha = ptr[rowBase + col * bytesPerPixel + alphaOffset]
                if alpha > 0 {
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                    if col < minCol { minCol = col }
                    if col > maxCol { maxCol = col }
                }
            }
        }

        if minRow > maxRow {
            // Fully transparent — return full rect
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        // CGImage rows are top-to-bottom, convert to AppKit bottom-left origin
        let ptMinX = CGFloat(minCol) / scale
        let ptMinY = CGFloat(h - 1 - maxRow) / scale
        let ptMaxX = CGFloat(maxCol + 1) / scale
        let ptMaxY = CGFloat(h - minRow) / scale
        return NSRect(x: ptMinX, y: ptMinY, width: ptMaxX - ptMinX, height: ptMaxY - ptMinY)
    }

    func invertImageColors() {
        guard let original = screenshotImage,
            let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let prevImage = original.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorInvert") else { return }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return }

        let ciCtx = CIContext()
        guard let inverted = ciCtx.createCGImage(output, from: output.extent) else { return }

        screenshotImage = NSImage(cgImage: inverted, size: original.size)
        cachedCompositedImage = nil
        needsDisplay = true
    }

    // MARK: - Snap/Alignment Guides

    /// Collect all snap target X and Y values from the selection rect and existing annotations.
    func collectSnapTargets(excluding: Annotation? = nil) -> (xs: [CGFloat], ys: [CGFloat])
    {
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []

        // Selection rect edges and center
        xs += [selectionRect.minX, selectionRect.midX, selectionRect.maxX]
        ys += [selectionRect.minY, selectionRect.midY, selectionRect.maxY]

        // Existing annotation bounding rects
        for ann in annotations where ann !== excluding {
            let r = ann.boundingRect
            guard r.width > 0 || r.height > 0 else { continue }
            xs += [r.minX, r.midX, r.maxX]
            ys += [r.minY, r.midY, r.maxY]
        }

        return (xs, ys)
    }

    /// Snap a point's X and Y to the nearest target within threshold. Returns snapped point and sets guide lines.
    func snapPoint(_ point: NSPoint, excluding: Annotation? = nil) -> NSPoint {
        guard snapGuidesEnabled else {
            snapGuideX = nil
            snapGuideY = nil
            return point
        }

        let (xs, ys) = collectSnapTargets(excluding: excluding)
        var result = point
        snapGuideX = nil
        snapGuideY = nil

        // Snap X
        var bestDx: CGFloat = snapThreshold + 1
        for tx in xs {
            let d = abs(point.x - tx)
            if d < bestDx {
                bestDx = d
                result.x = tx
                snapGuideX = tx
            }
        }
        if bestDx > snapThreshold {
            snapGuideX = nil
            result.x = point.x
        }

        // Snap Y
        var bestDy: CGFloat = snapThreshold + 1
        for ty in ys {
            let d = abs(point.y - ty)
            if d < bestDy {
                bestDy = d
                result.y = ty
                snapGuideY = ty
            }
        }
        if bestDy > snapThreshold {
            snapGuideY = nil
            result.y = point.y
        }

        return result
    }

    /// Snap a rect (for move operations) — checks all edges and center against targets.
    /// Returns the delta adjustment needed.
    func snapRectDelta(rect: NSRect, excluding: Annotation? = nil) -> (
        dx: CGFloat, dy: CGFloat
    ) {
        guard snapGuidesEnabled else {
            snapGuideX = nil
            snapGuideY = nil
            return (0, 0)
        }

        let (xs, ys) = collectSnapTargets(excluding: excluding)
        let edgesX = [rect.minX, rect.midX, rect.maxX]
        let edgesY = [rect.minY, rect.midY, rect.maxY]

        snapGuideX = nil
        snapGuideY = nil
        var bestDx: CGFloat = snapThreshold + 1
        var snapDx: CGFloat = 0
        var bestDy: CGFloat = snapThreshold + 1
        var snapDy: CGFloat = 0

        for ex in edgesX {
            for tx in xs {
                let d = abs(ex - tx)
                if d < bestDx {
                    bestDx = d
                    snapDx = tx - ex
                    snapGuideX = tx
                }
            }
        }
        if bestDx > snapThreshold {
            snapGuideX = nil
            snapDx = 0
        }

        for ey in edgesY {
            for ty in ys {
                let d = abs(ey - ty)
                if d < bestDy {
                    bestDy = d
                    snapDy = ty - ey
                    snapGuideY = ty
                }
            }
        }
        if bestDy > snapThreshold {
            snapGuideY = nil
            snapDy = 0
        }

        return (snapDx, snapDy)
    }

    /// Draw snap guide lines (called from draw after annotations, before toolbars).
    func drawSnapGuides() {
        guard snapGuidesEnabled else { return }

        let guideColor = NSColor.systemCyan.withAlphaComponent(0.6)
        guideColor.setStroke()

        if let gx = snapGuideX {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: gx, y: selectionRect.minY))
            line.line(to: NSPoint(x: gx, y: selectionRect.maxY))
            line.lineWidth = 0.5
            let pattern: [CGFloat] = [4, 3]
            line.setLineDash(pattern, count: 2, phase: 0)
            line.stroke()
        }

        if let gy = snapGuideY {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: selectionRect.minX, y: gy))
            line.line(to: NSPoint(x: selectionRect.maxX, y: gy))
            line.lineWidth = 0.5
            let pattern: [CGFloat] = [4, 3]
            line.setLineDash(pattern, count: 2, phase: 0)
            line.stroke()
        }
    }

    /// Solid accent guide line(s) on the image edge the selection just snapped
    /// to (boundary snap). Spans the full overlay so the snapped image line is
    /// obvious. Drawn only while resizing with an active snap.
    func drawBoundarySnapGuides() {
        guard boundarySnapGuideX != nil || boundarySnapGuideY != nil else { return }
        ToolbarLayout.accentColor.withAlphaComponent(0.9).setStroke()
        if let gx = boundarySnapGuideX {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: gx, y: bounds.minY))
            line.line(to: NSPoint(x: gx, y: bounds.maxY))
            line.lineWidth = 1
            line.stroke()
        }
        if let gy = boundarySnapGuideY {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.minX, y: gy))
            line.line(to: NSPoint(x: bounds.maxX, y: gy))
            line.lineWidth = 1
            line.stroke()
        }
    }

    // MARK: - Auto Measure

    /// Update the auto-measure live preview based on cursor position.
    /// Called on keyDown repeat and mouseMoved while key is held.
    func updateAutoMeasurePreview() {
        let vertical = autoMeasureVertical
        autoMeasurePreview = computeAutoMeasure(vertical: vertical)
        needsDisplay = true
    }

    /// Compute an auto-measure annotation from the cursor position along a vertical or horizontal axis
    /// by scanning outward until the pixel color changes significantly.
    func computeAutoMeasure(vertical: Bool) -> Annotation? {
        guard let screenshot = screenshotImage,
            let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        guard let window = window else { return nil }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = convert(windowPoint, from: nil)
        let canvasPoint = viewToCanvas(viewPoint)

        let drawRect = captureDrawRect
        let normX = (canvasPoint.x - drawRect.minX) / drawRect.width
        let normY = (canvasPoint.y - drawRect.minY) / drawRect.height

        let w = cgImage.width
        let h = cgImage.height

        let pixelX = Int(normX * CGFloat(w))
        let pixelY = Int((1.0 - normY) * CGFloat(h))

        guard pixelX >= 0, pixelX < w, pixelY >= 0, pixelY < h else {
            return nil
        }

        // Cache the bitmap context — only recreate if the image dimensions changed
        if autoMeasureBitmapCtx == nil || autoMeasureBitmapW != w || autoMeasureBitmapH != h {
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            autoMeasureBitmapCtx = ctx
            autoMeasureBitmapW = w
            autoMeasureBitmapH = h
        }

        guard let data = autoMeasureBitmapCtx?.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)

        func pixelAt(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * w + x) * 4
            return (ptr[offset], ptr[offset + 1], ptr[offset + 2])
        }

        func colorDiff(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Int {
            abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))
        }

        let refColor = pixelAt(pixelX, pixelY)
        let threshold = 30

        func toCanvas(px: Int, py: Int) -> NSPoint {
            let nx = CGFloat(px) / CGFloat(w)
            let ny = 1.0 - CGFloat(py) / CGFloat(h)
            return NSPoint(
                x: drawRect.minX + nx * drawRect.width,
                y: drawRect.minY + ny * drawRect.height)
        }

        var startPx: Int
        var endPx: Int

        if vertical {
            startPx = pixelY
            for py in stride(from: pixelY - 1, through: 0, by: -1) {
                if colorDiff(refColor, pixelAt(pixelX, py)) > threshold { break }
                startPx = py
            }
            endPx = pixelY
            for py in (pixelY + 1)..<h {
                if colorDiff(refColor, pixelAt(pixelX, py)) > threshold { break }
                endPx = py
            }
            var p1 = toCanvas(px: pixelX, py: startPx)
            var p2 = toCanvas(px: pixelX, py: endPx)
            // Auto-measure scans the whole screenshot; when clamping is on and the
            // cursor is inside the selection, stop the ruler at the selection edges.
            if currentMeasureClampToSelection && selectionRect.contains(canvasPoint) {
                p1.y = min(max(p1.y, selectionRect.minY), selectionRect.maxY)
                p2.y = min(max(p2.y, selectionRect.minY), selectionRect.maxY)
            }
            let ann = Annotation(
                tool: .measure, startPoint: p1, endPoint: p2,
                color: annotationColor, strokeWidth: currentStrokeWidth)
            ann.measureInPoints = currentMeasureInPoints
            return ann
        } else {
            startPx = pixelX
            for px in stride(from: pixelX - 1, through: 0, by: -1) {
                if colorDiff(refColor, pixelAt(px, pixelY)) > threshold { break }
                startPx = px
            }
            endPx = pixelX
            for px in (pixelX + 1)..<w {
                if colorDiff(refColor, pixelAt(px, pixelY)) > threshold { break }
                endPx = px
            }
            var p1 = toCanvas(px: startPx, py: pixelY)
            var p2 = toCanvas(px: endPx, py: pixelY)
            if currentMeasureClampToSelection && selectionRect.contains(canvasPoint) {
                p1.x = min(max(p1.x, selectionRect.minX), selectionRect.maxX)
                p2.x = min(max(p2.x, selectionRect.minX), selectionRect.maxX)
            }
            let ann = Annotation(
                tool: .measure, startPoint: p1, endPoint: p2,
                color: annotationColor, strokeWidth: currentStrokeWidth)
            ann.measureInPoints = currentMeasureInPoints
            return ann
        }
    }

    // MARK: - Marker Cursor Preview

    func drawCropPreview() {
        let dimColor = NSColor.black.withAlphaComponent(0.4)
        dimColor.setFill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: cropDragRect.maxY,
                width: selectionRect.width, height: selectionRect.maxY - cropDragRect.maxY)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: selectionRect.minY,
                width: selectionRect.width, height: cropDragRect.minY - selectionRect.minY)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: cropDragRect.minY,
                width: cropDragRect.minX - selectionRect.minX, height: cropDragRect.height)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: cropDragRect.maxX, y: cropDragRect.minY,
                width: selectionRect.maxX - cropDragRect.maxX, height: cropDragRect.height)
        ).fill()
    }

    /// Half-extent of the drawing cursor preview (used for dirty rect invalidation).
    var drawingCursorRadius: CGFloat {
        if currentTool == .marker {
            if smartMarkerEnabled {
                // Smart marker pill: height is the dominant dimension
                let h = smartMarkerLineHeight ?? (currentMarkerSize * 6)
                return h / 2
            }
            return (currentMarkerSize * 6) / 2
        } else {
            return max(currentStrokeWidth / 2, 2)
        }
    }

    func drawDrawingCursorPreview(at center: NSPoint) {
        if currentTool == .marker && smartMarkerEnabled {
            // Smart marker: vertical pill that scales to text line height
            let h = smartMarkerLineHeight ?? (currentMarkerSize * 6)
            let w: CGFloat = min(h * 0.55, 14)
            let pillRect = NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: w / 2, yRadius: w / 2)
            currentColor.withAlphaComponent(0.45).setFill()
            pill.fill()
            currentColor.withAlphaComponent(0.8).setStroke()
            pill.lineWidth = 1.0
            pill.stroke()
        } else if currentTool == .marker {
            // Normal marker: circle at marker stroke size
            let radius = drawingCursorRadius
            let circleRect = NSRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: circleRect)
            currentColor.withAlphaComponent(0.35).setFill()
            path.fill()
            currentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        } else {
            // Pencil: solid dot at stroke width (fixed size — don't scale by pressure
            // to avoid distracting size ripple while moving the cursor)
            let radius = max(drawingCursorRadius, 0.5)
            let circleRect = NSRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: circleRect)
            annotationColor.setFill()
            path.fill()
            let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1.0
            NSColor.white.withAlphaComponent(0.6).setStroke()
            border.stroke()
            let inner = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
            inner.lineWidth = 0.5
            NSColor.black.withAlphaComponent(0.3).setStroke()
            inner.stroke()
        }
    }

    // MARK: - Loupe Preview

    func drawLoupePreview(at center: NSPoint) {
        guard let screenshot = screenshotImage, let context = NSGraphicsContext.current else {
            return
        }
        // Build a throwaway loupe annotation with the SAME settings used on commit
        // and render it through the real drawLoupe path, so the cursor-follow
        // preview matches the placed loupe exactly (outline color + thickness).
        let size = currentLoupeSize
        let preview = Annotation(
            tool: .loupe,
            startPoint: NSPoint(x: center.x - size / 2, y: center.y - size / 2),
            endPoint: NSPoint(x: center.x + size / 2, y: center.y + size / 2),
            color: currentColor,
            strokeWidth: size)
        preview.loupeMagnification = currentLoupeMagnification
        preview.outlineColor = currentLoupeOutlineColor
        preview.loupeOutlineEnabled = currentLoupeOutlineEnabled
        preview.sourceImage = screenshot
        preview.sourceImageBounds = captureDrawRect
        preview.bakeLoupe()

        context.saveGraphicsState()
        context.cgContext.setAlpha(0.75)
        preview.draw(in: context)
        context.restoreGraphicsState()
    }

    // MARK: - Zoom helpers

    /// Convert a canvas-space point to view-space (reverse of viewToCanvas).
    func canvasToView(_ p: NSPoint) -> NSPoint {
        if isInsideScrollView { return p }
        var q = p
        // Apply zoom
        if zoomLevel != 1.0 || zoomAnchorCanvas != .zero || zoomAnchorView != .zero {
            q = NSPoint(
                x: zoomAnchorView.x + (p.x - zoomAnchorCanvas.x) * zoomLevel,
                y: zoomAnchorView.y + (p.y - zoomAnchorCanvas.y) * zoomLevel
            )
        }

        return q
    }

    /// Convert a point in view space to canvas (annotation) space by reversing the zoom transform.
    func viewToCanvas(_ p: NSPoint) -> NSPoint {
        if isInsideScrollView { return p }
        var q = adjustPointForEditor(p)
        if zoomLevel == 1.0 && zoomAnchorCanvas == .zero && zoomAnchorView == .zero { return q }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return q }
        return NSPoint(
            x: zoomAnchorCanvas.x + (q.x - zoomAnchorView.x) / zoomLevel,
            y: zoomAnchorCanvas.y + (q.y - zoomAnchorView.y) / zoomLevel
        )
    }

    func applyZoomTransform(to context: NSGraphicsContext) {
        if isInsideScrollView { return }
        if zoomLevel == 1.0 && zoomAnchorCanvas == .zero && zoomAnchorView == .zero { return }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return }
        let cgCtx = context.cgContext
        // screen = anchorView + (canvas - anchorCanvas) * zoom
        cgCtx.translateBy(
            x: zoomAnchorView.x - zoomAnchorCanvas.x * zoomLevel,
            y: zoomAnchorView.y - zoomAnchorCanvas.y * zoomLevel)
        cgCtx.scaleBy(x: zoomLevel, y: zoomLevel)
    }

    /// Apply editor canvas offset + zoom transform. Use this for all canvas-space drawing.
    func applyCanvasTransform(to context: NSGraphicsContext) {
        applyEditorTransform(to: context)
        applyZoomTransform(to: context)
    }

    /// Set zoom level, pinning the given view-space cursor point in place.
    /// Reset zoom to 1× (no transform). Retained because crop/undo/redo call it;
    /// the overlay no longer zooms, so this just affirms the identity state.
    func resetZoom() {
        zoomLevel = 1.0
        zoomAnchorCanvas = .zero
        zoomAnchorView = .zero
    }

    /// Crop the screenshot to `viewRect` (view-space, within selectionRect),
    /// translate all annotations accordingly, and reset zoom.
    func commitCrop(viewRect: NSRect) {
        guard let originalImage = screenshotImage,
            let cgOriginal = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // viewRect is already in canvas space (cropDragRect uses canvas coords).
        let canvasRect = viewRect

        // Map canvas rect → CGImage pixel rect.
        // CGImage uses top-left origin; canvas uses bottom-left.
        let pointsW = originalImage.size.width
        let pointsH = originalImage.size.height
        let pixScale = CGFloat(cgOriginal.width) / pointsW

        let normX = (canvasRect.minX - selectionRect.minX) / selectionRect.width
        let normY = (canvasRect.minY - selectionRect.minY) / selectionRect.height
        let normW = canvasRect.width / selectionRect.width
        let normH = canvasRect.height / selectionRect.height

        let cgW = CGFloat(cgOriginal.width)
        let cgH = CGFloat(cgOriginal.height)
        let cgPixelRect = CGRect(
            x: max(0, normX * cgW),
            y: max(0, (1.0 - normY - normH) * cgH),  // flip Y for CGImage top-left origin
            width: min(normW * cgW, cgW - max(0, normX * cgW)),
            height: min(normH * cgH, cgH - max(0, (1.0 - normY - normH) * cgH))
        )

        guard cgPixelRect.width > 0, cgPixelRect.height > 0,
            let croppedCG = cgOriginal.cropping(to: cgPixelRect)
        else { return }

        // Save state for undo before modifying
        let prevImage = originalImage.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let dx = selectionRect.minX - canvasRect.minX
        let dy = selectionRect.minY - canvasRect.minY
        for ann in annotations { ann.move(dx: dx, dy: dy) }

        // Set NSImage size in points (not pixels) to preserve Retina scale
        let croppedPointSize = NSSize(
            width: CGFloat(croppedCG.width) / pixScale,
            height: CGFloat(croppedCG.height) / pixScale)
        screenshotImage = NSImage(cgImage: croppedCG, size: croppedPointSize)

        // Update selectionRect to match new image size
        selectionRect = NSRect(origin: .zero, size: croppedPointSize)

        cachedCompositedImage = nil

        // Resize view frame to match new image size (scroll view re-centers automatically)
        if isInsideScrollView {
            frame.size = croppedPointSize
            enclosingScrollView?.magnification = 1.0
            // Update top bar size label
            if let topBar = chromeParentView as? EditorChromeView
            {
                topBar.updateSizeLabel(width: croppedCG.width, height: croppedCG.height)
                topBar.updateZoom(1.0)
            }
        } else {
            resetZoom()
        }
        currentTool = .arrow
        rebuildToolbarLayout()
        needsDisplay = true
    }

}
