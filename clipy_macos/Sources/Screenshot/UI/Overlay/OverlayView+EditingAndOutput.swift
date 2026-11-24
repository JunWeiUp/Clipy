import AVFoundation
import Cocoa
import UniformTypeIdentifiers

extension OverlayView {
    // MARK: - Annotation Copy/Paste

    static let annotationPasteboardType = NSPasteboard.PasteboardType("com.sw33tlie.macshot.annotations")

    /// Copy selected annotations to the pasteboard.
    func copySelectedAnnotations() {
        let toCopy = selectedAnnotations.isEmpty ? [] : selectedAnnotations
        guard !toCopy.isEmpty else { return }
        guard let data = AnnotationSerializer.encode(toCopy) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.annotationPasteboardType)
    }

    /// Paste annotations from the pasteboard, offset slightly so they're visible.
    func pasteAnnotations() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: Self.annotationPasteboardType),
              let pasted = AnnotationSerializer.decode(data) else { return }
        selectedAnnotations = []
        var newAnnotations: [Annotation] = []
        for ann in pasted {
            let copy = ann.clone()
            copy.move(dx: 15, dy: -15)
            annotations.append(copy)
            undoStack.append(.added(copy))
            newAnnotations.append(copy)
        }
        redoStack.removeAll()
        selectedAnnotations = newAnnotations
        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Duplicate the selected annotations in place (Cmd+D) — same offset behavior
    /// as copy+paste, but the user's clipboard is left untouched.
    func duplicateSelectedAnnotations() {
        let toDuplicate = selectedAnnotations
        guard !toDuplicate.isEmpty else { return }
        // Fresh groupID per action: a multi-duplicate undoes as one step, and the
        // clone doesn't inherit the source's groupID (which would batch its undo
        // with unrelated entries, e.g. auto-redact groups).
        let groupID = toDuplicate.count > 1 ? UUID() : nil
        var newAnnotations: [Annotation] = []
        for ann in toDuplicate {
            let copy = ann.clone()
            copy.groupID = groupID
            copy.move(dx: 15, dy: -15)
            annotations.append(copy)
            undoStack.append(.added(copy))
            newAnnotations.append(copy)
        }
        redoStack.removeAll()
        selectedAnnotations = newAnnotations
        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Editor only: paste an image from the clipboard as a draggable stamp placed
    /// below the canvas (auto-expands to fit), mirroring the "Add Capture" flow.
    /// Returns true if an image was found and pasted.
    func pasteImageFromClipboard() -> Bool {
        guard isEditorMode else { return false }
        guard let image = NSImage(pasteboard: NSPasteboard.general), image.size.width > 0, image.size.height > 0 else {
            return false
        }
        addCaptureImage(image)
        return true
    }

    /// Push undo entries for a finished drag/resize/rotate manipulation, but only
    /// for annotations whose geometry actually changed vs the pre-manipulation
    /// snapshot. Recording these makes such edits undoable AND makes them count as
    /// a change (so the editor shows "Done" and prompts on close).
    func commitAnnotationManipulationUndo() {
        guard !preMoveSnapshots.isEmpty else { return }
        var pushed = false
        for (ann, snapshot) in preMoveSnapshots where Self.annotationGeometryChanged(ann, snapshot) {
            undoStack.append(.propertyChange(annotation: ann, snapshot: snapshot))
            pushed = true
        }
        preMoveSnapshots = []
        if pushed {
            redoStack.removeAll()
            cachedCompositedImage = nil
        }
    }

    /// Whether two annotations differ in position/size/rotation (the things a
    /// drag/resize/rotate changes).
    static func annotationGeometryChanged(_ a: Annotation, _ b: Annotation) -> Bool {
        if a.startPoint != b.startPoint || a.endPoint != b.endPoint { return true }
        if abs(a.rotation - b.rotation) > 0.0001 { return true }
        if a.controlPoint != b.controlPoint { return true }
        if (a.points ?? []) != (b.points ?? []) { return true }
        if (a.anchorPoints ?? []) != (b.anchorPoints ?? []) { return true }
        if a.textDrawRect != b.textDrawRect { return true }
        if a.loupeSourceRect != b.loupeSourceRect { return true }
        if abs(a.loupeMagnification - b.loupeMagnification) > 0.0001 { return true }
        return false
    }

    // MARK: - Undo/Redo

    func undo() {
        cancelRecognition()
        guard let entry = undoStack.last else { return }
        undoStack.removeLast()
        switch entry {
        case .added(let ann):
            // Undo an addition — handle batch (groupID) or single
            if let groupID = ann.groupID {
                var batch: [UndoEntry] = [.added(ann)]
                while let prev = undoStack.last, prev.annotation.groupID == groupID {
                    undoStack.removeLast()
                    batch.append(prev)
                }
                for e in batch { annotations.removeAll { $0 === e.annotation } }
                if ann.tool == .number { numberCounter = max(0, numberCounter - batch.count) }
                if ann.tool == .translateOverlay { translateEnabled = false; rebuildToolbarLayout() }
                redoStack.append(contentsOf: batch)
                clearHoverIfNeeded(batch.map { $0.annotation })
            } else {
                annotations.removeAll { $0 === ann }
                if ann.tool == .number { numberCounter = max(0, numberCounter - 1) }
                if ann.tool == .translateOverlay { translateEnabled = false; rebuildToolbarLayout() }
                redoStack.append(.added(ann))
                clearHoverIfNeeded([ann])
            }
        case .deleted(let ann, let idx):
            // Undo a deletion — re-insert at original position
            let safeIdx = min(idx, annotations.count)
            annotations.insert(ann, at: safeIdx)
            if ann.tool == .number { numberCounter += 1 }
            redoStack.append(.deleted(ann, idx))
        case .propertyChange(let ann, let snapshot):
            // Undo property change — swap current state with snapshot
            let currentSnapshot = ann.clone()
            ann.copyProperties(from: snapshot)
            redoStack.append(.propertyChange(annotation: ann, snapshot: currentSnapshot))
            cachedCompositedImage = nil
        case .imageTransform(let previousImage, _):
            // Undo crop/flip — swap the current image with the saved one
            let currentImage = screenshotImage?.copy() as? NSImage ?? previousImage
            redoStack.append(.imageTransform(previousImage: currentImage, annotationOffsets: []))
            screenshotImage = previousImage
            // Update selectionRect to match restored image size
            if isEditorMode {
                selectionRect = NSRect(origin: .zero, size: previousImage.size)
                if isInsideScrollView { frame.size = previousImage.size }
            }
            cachedCompositedImage = nil
            resetZoom()
        }
        needsDisplay = true
    }

    func clearHoverIfNeeded(_ removed: [Annotation]) {
        var changed = false
        if let h = hoveredAnnotation, removed.contains(where: { $0 === h }) {
            hoveredAnnotationClearTimer?.invalidate()
            hoveredAnnotationClearTimer = nil
            hoveredAnnotation = nil
            changed = true
        }
        let beforeCount = selectedAnnotations.count
        selectedAnnotations.removeAll { ann in removed.contains(where: { $0 === ann }) }
        if selectedAnnotations.count != beforeCount {
            changed = true
        }
        // The hover highlight and selection handles are drawn from this state, so
        // dropping them has to invalidate — `changed` was computed and discarded,
        // leaving stale handles on screen until some other event forced a redraw.
        if changed {
            cachedAnnotationLayerExcludingSelected = nil
            needsDisplay = true
        }
    }

    func redo() {
        cancelRecognition()
        guard let entry = redoStack.last else { return }
        redoStack.removeLast()
        switch entry {
        case .added(let ann):
            if let groupID = ann.groupID {
                var batch: [UndoEntry] = [.added(ann)]
                while let next = redoStack.last, next.annotation.groupID == groupID {
                    redoStack.removeLast()
                    batch.append(next)
                }
                for e in batch { annotations.append(e.annotation) }
                if ann.tool == .number { numberCounter += batch.count }
                undoStack.append(contentsOf: batch)
            } else {
                annotations.append(ann)
                if ann.tool == .number { numberCounter += 1 }
                undoStack.append(.added(ann))
            }
        case .deleted(let ann, let idx):
            // Redo a deletion — remove again
            annotations.removeAll { $0 === ann }
            if ann.tool == .number { numberCounter = max(0, numberCounter - 1) }
            undoStack.append(.deleted(ann, idx))
        case .propertyChange(let ann, let snapshot):
            // Redo property change — swap again
            let currentSnapshot = ann.clone()
            ann.copyProperties(from: snapshot)
            undoStack.append(.propertyChange(annotation: ann, snapshot: currentSnapshot))
            cachedCompositedImage = nil
        case .imageTransform(let redoImage, _):
            // Redo crop/flip — swap back
            let currentImage = screenshotImage?.copy() as? NSImage ?? redoImage
            undoStack.append(.imageTransform(previousImage: currentImage, annotationOffsets: []))
            screenshotImage = redoImage
            if isEditorMode {
                selectionRect = NSRect(origin: .zero, size: redoImage.size)
                if isInsideScrollView { frame.size = redoImage.size }
            }
            cachedCompositedImage = nil
            if !isInsideScrollView { resetZoom() }
        }
        needsDisplay = true
    }

    // MARK: - Annotation layer cache

    /// Render all committed annotations into a transparent bitmap (canvas-space, no zoom).
    /// Reused across frames until annotations change, avoiding per-frame iteration.
    func annotationLayerImage() -> NSImage {
        if let cached = cachedAnnotationLayer { return cached }
        let image = renderAnnotationBitmap(annotations: annotations)
        cachedAnnotationLayer = image
        return image
    }

    var annotationLayerCache: NSImage? { cachedAnnotationLayer }

    /// Incrementally add a newly committed annotation onto a previous cache snapshot.
    /// Avoids a full rebuild which can cause a visible lag (cursor disappears for a frame).
    func appendToAnnotationCache(_ annotation: Annotation, previousCache: NSImage) {
        guard let existingCG = previousCache.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2.0
        let pxW = Int(ceil(size.width * scale))
        let pxH = Int(ceil(size.height * scale))
        let colorSpace = window?.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgCtx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        cgCtx.scaleBy(x: scale, y: scale)

        // Draw existing cache
        cgCtx.draw(existingCG, in: CGRect(origin: .zero, size: size))

        // Draw new annotation on top
        let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        annotation.draw(in: nsCtx)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgCtx.makeImage() else { return }
        cachedAnnotationLayer = NSImage(cgImage: cgImage, size: size)
    }

    /// Build annotation layer excluding specific annotations (used during drag/resize).
    /// Skips the highlight dim: while dragging/resizing, the dim is a moving union
    /// of ALL highlights, so it's drawn live in the draw pass over this static
    /// layer rather than baked here (which would dim using stale positions and
    /// double up with the live pass).
    func buildAnnotationLayer(excluding: Set<ObjectIdentifier>) -> NSImage {
        let filtered = annotations.filter { !excluding.contains(ObjectIdentifier($0)) }
        return renderAnnotationBitmap(annotations: filtered, skipHighlightDim: true)
    }

    /// Render annotations into a fixed bitmap at the current backing scale.
    /// Uses CGBitmapContext with the window's color space so colors match exactly.
    /// Returns an NSImage backed by a CGImage so AppKit never re-invokes a
    /// drawing handler when the image is drawn into a zoomed context.
    func renderAnnotationBitmap(annotations: [Annotation], skipHighlightDim: Bool = false) -> NSImage {
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2.0
        let pxW = Int(ceil(size.width * scale))
        let pxH = Int(ceil(size.height * scale))
        let colorSpace = window?.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgCtx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }
        // Scale so drawing in points maps to pixels
        cgCtx.scaleBy(x: scale, y: scale)

        let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        for annotation in annotations where annotation.tool == .pixelate {
            annotation.draw(in: nsCtx)
        }
        // Spotlight dim: a single union pass over all highlight rects, after the
        // censor effects and before the shape annotations (so shapes stay
        // readable over the dimming). Highlights' own draw() only adds a border.
        if !skipHighlightDim {
            Annotation.drawHighlightDim(for: annotations, in: highlightDimBounds)
        }
        for annotation in annotations where annotation.tool != .pixelate {
            annotation.draw(in: nsCtx)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgCtx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: - Output

    /// Render screenshot + all existing annotations into a full-size image.
    /// Used as source for pixelate/blur so they operate on the composited result.
    func compositedImage() -> NSImage? {
        if let cached = cachedCompositedImage { return cached }
        guard let screenshot = captureSourceImage ?? screenshotImage else { return nil }
        if annotations.isEmpty { return screenshot }

        let drawRect = captureDrawRect
        let dimBounds = highlightDimBounds
        let annotationsCopy = annotations
        var success = false
        let image = NSImage(size: drawRect.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else {
                return true
            }
            screenshot.draw(
                in: NSRect(origin: .zero, size: drawRect.size), from: .zero, operation: .copy,
                fraction: 1.0)
            // Translate so annotations at selectionRect coords render correctly
            context.cgContext.translateBy(x: -drawRect.origin.x, y: -drawRect.origin.y)
            // Censor annotations render first so other annotations appear on top
            for annotation in annotationsCopy where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            Annotation.drawHighlightDim(for: annotationsCopy, in: dimBounds)
            for annotation in annotationsCopy where annotation.tool != .pixelate {
                annotation.draw(in: context)
            }
            success = true
            return true
        }
        if !success {
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if !success { return screenshot }
        cachedCompositedImage = image
        return image
    }
    func captureSelectedRegion() -> NSImage? {
        return renderSelectedRegion(includeAnnotations: true)
    }

    /// Capture the selected region WITHOUT annotations — just the raw screenshot.
    /// Used for editable history: the raw image is stored alongside annotation data.
    func captureSelectedRegionRaw() -> NSImage? {
        return renderSelectedRegion(includeAnnotations: false)
    }

    func renderSelectedRegion(includeAnnotations: Bool) -> NSImage? {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return nil }

        // Determine the source image's actual pixel scale so we render at
        // native resolution instead of relying on lockFocus() which always
        // picks the highest backing scale of any connected display.  This
        // prevents interpolation-upscaling when a 1x external monitor is
        // captured while a Retina display is also connected.
        let scale: CGFloat
        if let screenshot = captureSourceImage ?? screenshotImage,
            let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = window?.backingScaleFactor ?? 2.0
        }

        // Snap selection rect to pixel boundaries to prevent sub-pixel
        // interpolation blur (especially visible on 1x non-Retina displays
        // where fractional mouse coordinates aren't absorbed by 2x scaling).
        let snappedRect = NSRect(
            x: round(selectionRect.origin.x * scale) / scale,
            y: round(selectionRect.origin.y * scale) / scale,
            width: round(selectionRect.width * scale) / scale,
            height: round(selectionRect.height * scale) / scale
        )

        let pixelW = Int(snappedRect.width * scale)
        let pixelH = Int(snappedRect.height * scale)
        guard pixelW > 0, pixelH > 0 else { return nil }
        // Use the source image's color space to avoid expensive color conversion on render.
        // Fall back to sRGB if unavailable.
        let cs: CGColorSpace
        if let screenshot = captureSourceImage ?? screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srcCS = cg.colorSpace {
            cs = srcCS
        } else {
            cs = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let cgCtx = CGContext(
                data: nil,
                width: pixelW, height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: pixelW * 4,
                space: cs,
                bitmapInfo: bitmapInfo
            )
        else { return nil }

        // Disable interpolation for pixel-perfect output — the screenshot
        // pixels should map 1:1 to the output without any filtering.
        cgCtx.interpolationQuality = .none
        // Scale the CG context so drawing in points maps to the correct pixels.
        cgCtx.scaleBy(x: scale, y: scale)
        cgCtx.translateBy(x: -snappedRect.origin.x, y: -snappedRect.origin.y)

        let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        if let screenshot = captureSourceImage ?? screenshotImage {
            // In editor mode the image is at selectionRect (natural size);
            // in overlay mode it fills bounds (full screen).
            let drawRect = captureDrawRect
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        }

        if includeAnnotations {
            // Match the live draw order: censor effects first, then the spotlight
            // dim (union of highlight rects), then the regular shape annotations
            // on top — so the exported image matches what's on screen.
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: nsContext)
            }
            Annotation.drawHighlightDim(for: annotations, in: highlightDimBounds)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: nsContext)
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: snappedRect.size)
    }

    // MARK: - Cleanup

    /// Pre-set a selection (used by delay capture to restore the previous region)
    func snapshotEditorState() -> OverlayEditorState {
        return OverlayEditorState(
            screenshotImage: screenshotImage,
            selectionRect: selectionRect,
            annotations: annotations,
            undoStack: undoStack,
            redoStack: redoStack,
            currentTool: currentTool,
            currentColor: currentColor,
            currentStrokeWidth: currentStrokeWidth,
            currentMarkerSize: currentMarkerSize,
            currentNumberSize: currentNumberSize,
            numberCounter: numberCounter,
            beautifyEnabled: beautifyEnabled,
            beautifyStyleIndex: beautifyStyleIndex,
            effectsPreset: effectsPreset,
            effectsBrightness: effectsBrightness,
            effectsContrast: effectsContrast,
            effectsSaturation: effectsSaturation,
            effectsSharpness: effectsSharpness
        )
    }

    /// Restore editor state.
    /// Translates annotation coordinates by `offset` (the selection origin in the original view).
    func setAnnotations(_ anns: [Annotation]) {
        // Set sourceImage on loupe annotations so they can re-bake from the editor's image.
        // Also set it on pixelate/blur without a baked result (shouldn't happen, but defensive).
        if let img = screenshotImage {
            let bounds = captureDrawRect
            for ann in anns {
                if ann.tool == .loupe || ((ann.tool == .pixelate || ann.tool == .blur) && ann.bakedBlurNSImage == nil) {
                    ann.sourceImage = img
                    ann.sourceImageBounds = bounds
                    if ann.tool == .loupe { ann.bakeLoupe() }
                    if ann.tool == .pixelate { ann.bakePixelate() }
                }
            }
        }
        annotations = anns
        undoStack = anns.map { .added($0) }
        redoStack = []
        cachedCompositedImage = nil
        needsDisplay = true
    }

    func applySelection(_ rect: NSRect) {
        selectionRect = rect
        selectionStart = rect.origin
        state = .selected
        showToolbars = true
        needsDisplay = true
    }

    func applyFullScreenSelection() {
        selectionRect = bounds
        selectionStart = bounds.origin
        state = .selected
        showToolbars = true
        overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        needsDisplay = true
    }

    func clearSelection() {
        state = .idle
        selectionRect = .zero
        remoteSelectionRect = .zero
        remoteSelectionFullRect = .zero
        showToolbars = false
        updateResolutionBox()  // remove the box (no selection)
        needsDisplay = true
    }

    // MARK: - Tool options API (used by ToolOptionsRowView)

    func activeStrokeWidthForTool(_ tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .number: return currentNumberSize
        case .marker: return currentMarkerSize
        case .loupe: return currentLoupeSize
        default: return currentStrokeWidth
        }
    }

    func setActiveStrokeWidth(_ value: CGFloat, for tool: AnnotationTool) {
        switch tool {
        case .number:
            currentNumberSize = value
            UserDefaults.standard.set(Double(value), forKey: "numberStrokeWidth")
        case .marker:
            currentMarkerSize = value
            UserDefaults.standard.set(Double(value), forKey: "markerStrokeWidth")
        case .loupe:
            currentLoupeSize = value
            UserDefaults.standard.set(Double(value), forKey: "loupeSize")
        default:
            currentStrokeWidth = value
            UserDefaults.standard.set(Double(value), forKey: "currentStrokeWidth")
        }
        needsDisplay = true
    }

    func setActiveStampSize(_ value: CGFloat) {
        currentStampSize = min(256, max(16, value))
        UserDefaults.standard.set(Double(currentStampSize), forKey: "stampSize")
    }

    func setActiveLoupeMagnification(_ value: CGFloat) {
        currentLoupeMagnification = min(6.0, max(1.1, value))
        UserDefaults.standard.set(Double(currentLoupeMagnification), forKey: "loupeMagnification")
        needsDisplay = true
    }


    /// Invalidate the cached layers so loupe appearance changes (outline color/
    /// toggle) repaint immediately.
    func invalidateLoupeCaches() {
        cachedAnnotationLayer = nil
        cachedAnnotationLayerExcludingSelected = nil
        cachedCompositedImage = nil
    }

    func showColorPickerPopover(target: ColorPickerTarget, anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        colorPickerTarget = target
        let picker = ColorPickerView()
        let initialColor: NSColor
        switch target {
        case .drawColor: initialColor = currentColor
        case .textBg: initialColor = textEditor.bgColor
        case .textOutline: initialColor = textEditor.outlineColor
        case .textGlyphStroke: initialColor = textEditor.glyphStrokeColor
        case .annotationOutline:
            if let data = UserDefaults.standard.data(forKey: "annotationOutlineColor"),
               let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                initialColor = c
            } else {
                initialColor = .white
            }
        case .loupeOutline:
            let editingLoupe = toolOptionsRowView?.editingAnnotation.flatMap { $0.tool == .loupe ? $0 : nil }
            initialColor = (editingLoupe ?? selectedAnnotations.first { $0.tool == .loupe })?.outlineColor
                ?? currentLoupeOutlineColor
        }
        picker.setColor(initialColor, opacity: currentColorOpacity)
        picker.customColors = customColors
        picker.selectedColorSlot = selectedColorSlot

        picker.onColorChanged = { [weak self] color in
            guard let self = self else { return }
            self.applyPickedColor(color)
            picker.saveToSelectedSlot(color)
            // Update toolbar color swatches without rebuilding (which destroys the popover anchor)
            self.toolOptionsRowView?.updateSwatchColors()
            self.needsDisplay = true
        }
        picker.onOpacityChanged = { [weak self] opacity in
            guard let self = self else { return }
            self.currentColorOpacity = opacity
            OverlayView.lastUsedOpacity = opacity
            UserDefaults.standard.set(Double(opacity), forKey: "lastUsedColorOpacity")
            self.applyColorToSelectedAnnotation()
            self.needsDisplay = true
        }
        picker.onCustomSlotSelected = { [weak self] idx in
            self?.selectedColorSlot = idx
        }
        picker.onCustomColorsChanged = { [weak self] colors in
            self?.customColors = colors
            self?.saveCustomColors()
        }

        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if anchorRect != .zero {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: anchorRect.midX, y: anchorRect.midY), in: self, preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self, preferredEdge: .minY)
        }
    }

    func applyPickedColor(_ color: NSColor) {
        switch colorPickerTarget {
        case .drawColor:
            currentColor = color
            applyColorToTextIfEditing()
            applyColorToSelectedAnnotation()
        case .textBg:
            textEditor.bgColor = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textBgColor")
            }
        case .textOutline:
            textEditor.outlineColor = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textOutlineColor")
            }
        case .textGlyphStroke:
            textEditor.glyphStrokeColor = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textGlyphStrokeColor")
            }
            applyGlyphStrokeToLiveTextView()
            applyTextBgOutlineToSelectedAnnotations()
        case .annotationOutline:
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "annotationOutlineColor")
            }
            // Apply to selected annotations
            for ann in selectedAnnotations {
                ann.outlineColor = color
            }
            cachedCompositedImage = nil
        case .loupeOutline:
            currentLoupeOutlineColor = color
            currentLoupeOutlineEnabled = true
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "loupeOutlineColor")
            }
            UserDefaults.standard.set(true, forKey: "loupeOutlineEnabled")
            // Apply to the loupe being edited / selected loupes.
            var targets = selectedAnnotations.filter { $0.tool == .loupe }
            if let editing = toolOptionsRowView?.editingAnnotation, editing.tool == .loupe,
               !targets.contains(where: { $0 === editing }) {
                targets.append(editing)
            }
            for ann in targets {
                ann.outlineColor = color
                ann.loupeOutlineEnabled = true
            }
            cachedAnnotationLayer = nil
            cachedAnnotationLayerExcludingSelected = nil
            cachedCompositedImage = nil
            toolOptionsRowView?.updateSwatchColors()
        }
        needsDisplay = true
    }

    func reset() {
        cancelRecognition()
        state = .idle
        annotationToolsVisible = true
        selectionRect = .zero
        selectionIsWindowSnap = false
        snappedWindowID = nil
        snappedWindowImage = nil
        remoteSelectionRect = .zero
        remoteSelectionFullRect = .zero
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        currentAnnotation = nil
        currentTool = OverlayView.initialTool
        numberCounter = 0
        showToolbars = false
        dismissResolutionBox()
        islandAnchor = nil
        islandDragStartAnchor = nil
        islandCollapsed = false
        hideCaptureIsland()
        bottomStripView?.isHidden = true
        rightStripView?.isHidden = true
        toolOptionsRowView?.isHidden = true
        PopoverHelper.dismiss()
        editorTooltipView?.removeFromSuperview()
        editorTooltipView = nil
        captureSourceImage = nil
        isTranslating = false
        translateEnabled = false
        autoMeasurePreview = nil
        autoMeasureKeyHeld = false
        autoMeasureBitmapCtx = nil
        isKeyboardMoveSelectionActive = false
        isToolbarMoveDragActive = false
        keyboardMoveSelectionShortcut = ""
        selectedAnnotation = nil
        isDraggingAnnotation = false
        hoveredAnnotationClearTimer?.invalidate()
        hoveredAnnotationClearTimer = nil
        hoveredAnnotation = nil
        // Overlays are pooled, so a repeating timer left running here keeps
        // firing (and retaining its target) for the rest of the app's life.
        beautifyToolbarAnimTimer?.invalidate()
        beautifyToolbarAnimTimer = nil
        editorZoomAnimTimer?.invalidate()
        editorZoomAnimTimer = nil
        editorZoomRedrawTimer?.invalidate()
        editorZoomRedrawTimer = nil
        longPressTimer?.invalidate()
        longPressTimer = nil
        stopMicLevelMonitor()
        colorWheel.dismiss()
        beautifyEnabled = UserDefaults.standard.bool(forKey: "beautifyEnabled")
        beautifyStyleIndex = UserDefaults.standard.integer(forKey: "beautifyStyleIndex")
        beautifyMode =
            BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
        beautifyPadding = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyPadding") as? Double ?? 48)
        beautifyCornerRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyCornerRadius") as? Double ?? 10)
        beautifyShadowRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyShadowRadius") as? Double ?? 20)
        beautifyBgRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyBgRadius") as? Double ?? 8)
        // Only released here, never reloaded: reset() runs at session teardown,
        // and re-reading the background would keep a full-size wallpaper plus its
        // CGImage cache resident in every pooled overlay until the next capture.
        // The `screenshotImage` setter and the beautify tool both load it eagerly
        // when it is actually needed. (The load must stay out of the
        // `beautifyConfig` getter so draws never mutate state.)
        customBeautifyBackground = nil
        currentLineStyle =
            LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
        currentArrowStyle =
            ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle"))
            ?? .single
        currentRectFillStyle =
            RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle"))
            ?? .stroke
        currentRectCornerRadius = CGFloat(
            UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double ?? 0)
        textEditor.dismiss()
        dismissResolutionBox()
        hidePreSelectionPresetButton()
        captureModeBar?.removeFromSuperview()
        captureModeBar = nil
        captureHintView?.removeFromSuperview()
        captureHintView = nil
        captureIsland?.removeFromSuperview()
        captureIsland = nil
        islandSnapGuides.forEach { $0.removeFromSuperview() }
        islandSnapGuides = []
        lockedAspect = activePreSelectionRatio
        isResizingAnnotation = false
        loupeCursorPoint = .zero
        colorSamplerPoint = .zero
        colorSamplerBitmap = nil
        overlayErrorTimer?.invalidate()
        overlayErrorTimer = nil
        overlayErrorMessage = nil
        hoveredWindowRect = nil
        isRecording = false
        // Webcam setup preview (if any) — clear so a reused overlay doesn't
        // show a stale camera feed on the next session.
        webcamSetupPreview?.stopPreview()
        webcamSetupPreview?.close()
        webcamSetupPreview = nil
        // Auto-mode flags — these are set per-session by the controller and
        // must NOT leak into the next session.
        autoEnterRecordingMode = false
        autoOCRMode = false
        autoTranslateOverlayMode = false
        autoTranslateOverlayLang = nil
        autoQuickSaveMode = false
        autoScrollCaptureMode = false
        autoConfirmMode = false
        // Drawing caches hold full-display composite/annotation NSImages (a
        // 4K composite is ~64MB). The overlay controller is kept alive across
        // sessions for warm captures, so these MUST be dropped here — otherwise
        // they leak for the lifetime of the app. They are lazily rebuilt by
        // the draw path on the next session, so clearing is behavior-free.
        cachedCompositedImage = nil
        cachedAnnotationLayer = nil
        cachedAnnotationLayerExcludingSelected = nil
        needsDisplay = true
    }
}
