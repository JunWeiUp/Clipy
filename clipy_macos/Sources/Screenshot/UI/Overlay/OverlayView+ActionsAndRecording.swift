import AVFoundation
import Cocoa
import UniformTypeIdentifiers

extension OverlayView {
    // MARK: - Selection Resizing

    func resizeSelection(to point: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let minSize: CGFloat = 10
        let r = selectionRect
        var newRect = r

        switch resizeHandle {
        case .topLeft:
            let newX = min(point.x, r.maxX - minSize)
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: newX, y: r.minY, width: r.maxX - newX, height: newMaxY - r.minY)
        case .topRight:
            let newMaxX = max(point.x, r.minX + minSize)
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(
                x: r.minX, y: r.minY, width: newMaxX - r.minX, height: newMaxY - r.minY)
        case .bottomLeft:
            let newX = min(point.x, r.maxX - minSize)
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: newX, y: newY, width: r.maxX - newX, height: r.maxY - newY)
        case .bottomRight:
            let newMaxX = max(point.x, r.minX + minSize)
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: r.minX, y: newY, width: newMaxX - r.minX, height: r.maxY - newY)
        case .top:
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: r.width, height: newMaxY - r.minY)
        case .bottom:
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: r.minX, y: newY, width: r.width, height: r.maxY - newY)
        case .left:
            let newX = min(point.x, r.maxX - minSize)
            newRect = NSRect(x: newX, y: r.minY, width: r.maxX - newX, height: r.height)
        case .right:
            let newMaxX = max(point.x, r.minX + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: newMaxX - r.minX, height: r.height)
        default:
            break
        }

        // Boundary snap (before aspect, so the locked ratio is preserved): snap
        // the dragged edge(s) to nearby strong image edges. Option bypasses.
        if boundarySnapEnabled, !modifiers.contains(.option), let index = boundarySnapIndex {
            newRect = applyBoundarySnap(to: newRect, handle: resizeHandle, minSize: minSize, index: index)
        } else if boundarySnapGuideX != nil || boundarySnapGuideY != nil {
            boundarySnapGuideX = nil
            boundarySnapGuideY = nil
        }

        if let aspect = lockedAspect, aspect > 0 {
            newRect = constrainToAspect(newRect, aspect: aspect, handle: resizeHandle, minSize: minSize)
        }

        selectionRect = newRect
    }

    /// Snap the dragged edge(s) of `rect` to nearby strong image boundaries.
    /// Each handle drives one or two edges; only those are snapped. Updates the
    /// snap-guide feedback coordinates.
    func applyBoundarySnap(to rect: NSRect, handle: ResizeHandle, minSize: CGFloat,
                                   index: BoundarySnapIndex) -> NSRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var guideX: CGFloat?
        var guideY: CGFloat?
        let radius = boundarySnapRadiusPoints

        // Which edges does this handle move?
        let movesLeft = handle == .left || handle == .topLeft || handle == .bottomLeft
        let movesRight = handle == .right || handle == .topRight || handle == .bottomRight
        let movesTop = handle == .top || handle == .topLeft || handle == .topRight
        let movesBottom = handle == .bottom || handle == .bottomLeft || handle == .bottomRight

        if movesLeft, let hit = index.nearestVertical(toViewX: minX, yMinView: minY, yMaxView: maxY, radiusPoints: radius) {
            if hit.viewPosition <= maxX - minSize { minX = hit.viewPosition; guideX = hit.viewPosition }
        }
        if movesRight, let hit = index.nearestVertical(toViewX: maxX, yMinView: minY, yMaxView: maxY, radiusPoints: radius) {
            if hit.viewPosition >= minX + minSize { maxX = hit.viewPosition; guideX = hit.viewPosition }
        }
        if movesBottom, let hit = index.nearestHorizontal(toViewY: minY, xMinView: minX, xMaxView: maxX, radiusPoints: radius) {
            if hit.viewPosition <= maxY - minSize { minY = hit.viewPosition; guideY = hit.viewPosition }
        }
        if movesTop, let hit = index.nearestHorizontal(toViewY: maxY, xMinView: minX, xMaxView: maxX, radiusPoints: radius) {
            if hit.viewPosition >= minY + minSize { maxY = hit.viewPosition; guideY = hit.viewPosition }
        }

        boundarySnapGuideX = guideX
        boundarySnapGuideY = guideY
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Snap a whole rect being MOVED (not resized) to nearby image edges. Unlike
    /// resize snapping, the rect size is fixed: we translate it so an edge lands
    /// on a boundary. Both left/right edges are candidates on X (and top/bottom on
    /// Y); the nearer snap wins per axis. Returns the translated rect and updates
    /// the snap-guide feedback. Returns the rect unchanged when snapping is off /
    /// Option is held / no index is built.
    func boundarySnappedMovedRect(_ rect: NSRect, modifiers: NSEvent.ModifierFlags) -> NSRect {
        guard boundarySnapEnabled, !modifiers.contains(.option), let index = boundarySnapIndex else {
            if boundarySnapGuideX != nil || boundarySnapGuideY != nil {
                boundarySnapGuideX = nil
                boundarySnapGuideY = nil
            }
            return rect
        }
        let radius = boundarySnapRadiusPoints
        var dx: CGFloat = 0
        var guideX: CGFloat?
        // X axis: try snapping the left edge and the right edge; take the smaller
        // shift so the closer boundary wins.
        var bestX: CGFloat = .greatestFiniteMagnitude
        if let hit = index.nearestVertical(toViewX: rect.minX, yMinView: rect.minY, yMaxView: rect.maxY, radiusPoints: radius) {
            let shift = hit.viewPosition - rect.minX
            if abs(shift) < abs(bestX) { bestX = shift; guideX = hit.viewPosition }
        }
        if let hit = index.nearestVertical(toViewX: rect.maxX, yMinView: rect.minY, yMaxView: rect.maxY, radiusPoints: radius) {
            let shift = hit.viewPosition - rect.maxX
            if abs(shift) < abs(bestX) { bestX = shift; guideX = hit.viewPosition }
        }
        if bestX != .greatestFiniteMagnitude { dx = bestX }

        var dy: CGFloat = 0
        var guideY: CGFloat?
        var bestY: CGFloat = .greatestFiniteMagnitude
        if let hit = index.nearestHorizontal(toViewY: rect.minY, xMinView: rect.minX, xMaxView: rect.maxX, radiusPoints: radius) {
            let shift = hit.viewPosition - rect.minY
            if abs(shift) < abs(bestY) { bestY = shift; guideY = hit.viewPosition }
        }
        if let hit = index.nearestHorizontal(toViewY: rect.maxY, xMinView: rect.minX, xMaxView: rect.maxX, radiusPoints: radius) {
            let shift = hit.viewPosition - rect.maxY
            if abs(shift) < abs(bestY) { bestY = shift; guideY = hit.viewPosition }
        }
        if bestY != .greatestFiniteMagnitude { dy = bestY }

        boundarySnapGuideX = guideX
        boundarySnapGuideY = guideY
        return rect.offsetBy(dx: dx, dy: dy)
    }

    /// Snap the moving corner of an in-progress rubber-band selection to nearby
    /// image edges (the anchor corner stays fixed). Returns the adjusted point
    /// and updates the snap-guide feedback.
    func snapMovingPoint(_ point: NSPoint, anchor: NSPoint,
                                 index: BoundarySnapIndex) -> NSPoint {
        var p = point
        var guideX: CGFloat?
        var guideY: CGFloat?
        let radius = boundarySnapRadiusPoints
        let yMin = min(anchor.y, point.y), yMax = max(anchor.y, point.y)
        let xMin = min(anchor.x, point.x), xMax = max(anchor.x, point.x)
        if let hit = index.nearestVertical(toViewX: point.x, yMinView: yMin, yMaxView: yMax, radiusPoints: radius) {
            p.x = hit.viewPosition
            guideX = hit.viewPosition
        }
        if let hit = index.nearestHorizontal(toViewY: point.y, xMinView: xMin, xMaxView: xMax, radiusPoints: radius) {
            p.y = hit.viewPosition
            guideY = hit.viewPosition
        }
        boundarySnapGuideX = guideX
        boundarySnapGuideY = guideY
        return p
    }

    /// Build the boundary-snap edge index for the current screenshot off the
    /// main thread, discarding the result if a newer screenshot arrived.
    func scheduleBoundarySnapIndexBuild() {
        guard let image = screenshotImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let generation = boundarySnapBuildGeneration
        let drawRect = captureDrawRect
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let index = BoundarySnapIndex.build(from: cgImage, drawRect: drawRect)
            DispatchQueue.main.async {
                guard let self, self.boundarySnapBuildGeneration == generation else { return }
                self.boundarySnapIndex = index
            }
        }
    }

    /// Adjust `rect` to the locked `aspect` (w/h), keeping the handle's anchor fixed.
    /// Corner handles keep the opposite corner fixed and drive from the dominant
    /// dimension; edge handles drive the dragged axis and center the other.
    func constrainToAspect(_ rect: NSRect, aspect: CGFloat, handle: ResizeHandle, minSize: CGFloat) -> NSRect {
        var w = rect.width
        var h = rect.height

        // Derive the dependent dimension from the driven one.
        switch handle {
        case .top, .bottom:           w = h * aspect        // height driven
        case .left, .right:           h = w / aspect        // width driven
        default:                                            // corner: dominant axis
            if w / aspect >= h { h = w / aspect } else { w = h * aspect }
        }

        // Enforce min size as a RATIO-PRESERVING pair (scale both up together).
        if w < minSize || h < minSize {
            let s = max(minSize / w, minSize / h)
            w *= s; h *= s
        }
        // Shrink (ratio-preserved) if larger than the screen.
        if w > bounds.width || h > bounds.height {
            let s = min(bounds.width / w, bounds.height / h)
            w *= s; h *= s
        }

        // Anchor: corner handles keep the OPPOSITE corner fixed; edge handles keep
        // the opposite edge fixed and center the derived dimension.
        var x = rect.minX
        var y = rect.minY
        switch handle {
        case .topLeft:      x = rect.maxX - w; y = rect.minY
        case .topRight:     x = rect.minX;     y = rect.minY
        case .bottomLeft:   x = rect.maxX - w; y = rect.maxY - h
        case .bottomRight:  x = rect.minX;     y = rect.maxY - h
        case .top:          x = rect.midX - w / 2; y = rect.minY
        case .bottom:       x = rect.midX - w / 2; y = rect.maxY - h
        case .left:         x = rect.maxX - w; y = rect.midY - h / 2
        case .right:        x = rect.minX;     y = rect.midY - h / 2
        default: break
        }
        // Clamp POSITION into bounds (size already fits) without distorting ratio.
        x = max(bounds.minX, min(x, bounds.maxX - w))
        y = max(bounds.minY, min(y, bounds.maxY - h))
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Toolbar Actions

    /// Handle right-click on a toolbar button (context menus, popovers).
    func handleToolbarButtonHover(_ action: ToolbarButtonAction, hovered: Bool, strip: ToolbarStripView?) {
        if isToolbarMoveDragActive { return }
        if hovered {
            let btn = strip?.buttonViews.first { bv in
                // Compare by identity — find the button that triggered the hover
                if case .tool(let t1) = bv.action, case .tool(let t2) = action { return t1 == t2 }
                // For non-tool actions, compare string representation
                return "\(bv.action)" == "\(action)"
            }
            hoveredTooltip = toolbarTooltipText(for: action, base: btn?.tooltipText)
            hoveredTooltipButtonView = btn
        } else {
            hoveredTooltip = nil
            hoveredTooltipButtonView = nil
        }
        needsDisplay = true
    }

    func toolbarTooltipText(for action: ToolbarButtonAction, base: String?) -> String? {
        guard let base, !base.isEmpty else { return base }
        guard tooltipShortcutDisplayEnabled,
              let shortcut = ToolShortcutManager.tooltipShortcut(for: action)
        else { return base }
        return "\(base) (\(shortcut))"
    }

    func clearToolbarHoverState(
        suppressUntilMouseMoved: Bool = false,
        clearTooltip: Bool = true,
        clearPressed: Bool = true
    ) {
        if clearTooltip {
            hoveredTooltip = nil
            hoveredTooltipButtonView = nil
        }
        bottomStripView?.clearInteractionState(
            suppressHoverUntilMouseMoved: suppressUntilMouseMoved,
            clearPressed: clearPressed)
        rightStripView?.clearInteractionState(
            suppressHoverUntilMouseMoved: suppressUntilMouseMoved,
            clearPressed: clearPressed)
        needsDisplay = true
    }

    func showMoveDragTooltip(anchor moveButton: ToolbarButtonView?) {
        hoveredTooltip = L("Release to finish")
        hoveredTooltipButtonView = moveButton
        needsDisplay = true
    }

    func moveSelectionButtonView() -> ToolbarButtonView? {
        rightStripView?.buttonViews.first {
            if case .moveSelection = $0.action { return true }
            return false
        }
    }

    func eventMatchesToolShortcut(_ event: NSEvent, action: ToolShortcutManager.Action) -> Bool {
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control),
              let char = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        let shortcut = ToolShortcutManager.key(for: action).lowercased()
        return !shortcut.isEmpty && char == shortcut
    }

    func eventEndsKeyboardMoveSelection(_ event: NSEvent) -> Bool {
        if keyboardMoveSelectionShortcut == " " {
            return event.keyCode == 49
        }
        guard let char = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return !keyboardMoveSelectionShortcut.isEmpty && char == keyboardMoveSelectionShortcut
    }

    func canStartKeyboardMoveSelection() -> Bool {
        state == .selected
            && !isEditorMode
            && textEditView == nil
            && !isRecording
            && !isScrollCapturing
            && !isAnchoredSelecting
            && !isResizingSelection
            && !isDraggingSelection
            && currentAnnotation == nil
            && !isDraggingAnnotation
            && !isResizingAnnotation
            && !isRotatingAnnotation
            && !isCropDragging
            && !isResizingTextBox
            && !PopoverHelper.isVisible
    }

    @discardableResult
    func startKeyboardMoveSelection() -> Bool {
        guard canStartKeyboardMoveSelection(), let win = window else { return false }
        var moveButton = moveSelectionButtonView()

        isKeyboardMoveSelectionActive = true
        isToolbarMoveDragActive = true
        keyboardMoveSelectionShortcut = ToolShortcutManager.key(for: .moveSelection).lowercased()
        setToolbarHoverSuppressed(true)
        clearToolbarHoverState(suppressUntilMouseMoved: true, clearPressed: false)

        if selectionIsWindowSnap {
            selectionIsWindowSnap = false
            snappedWindowID = nil
            snappedWindowImage = nil
            rebuildToolbarLayout()
            setToolbarHoverSuppressed(true)
            moveButton = moveSelectionButtonView()
        }

        let point = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        keyboardMoveSelectionOffset = NSPoint(
            x: point.x - selectionRect.origin.x,
            y: point.y - selectionRect.origin.y)

        moveButton?.isPressed = true
        moveButton?.needsDisplay = true
        moveButton?.displayIfNeeded()
        showMoveDragTooltip(anchor: moveButton)
        needsDisplay = true
        return true
    }

    func updateKeyboardMoveSelection(to point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard isKeyboardMoveSelectionActive else { return }
        var moved = selectionRect
        moved.origin = NSPoint(
            x: point.x - keyboardMoveSelectionOffset.x,
            y: point.y - keyboardMoveSelectionOffset.y)
        selectionRect = boundarySnappedMovedRect(moved, modifiers: modifiers)
        if webcamSetupPreview != nil { repositionWebcamSetupPreview() }
        updateResolutionBox()
        repositionToolbars()
        showMoveDragTooltip(anchor: moveSelectionButtonView())
        needsDisplay = true
    }

    func endKeyboardMoveSelection() {
        guard isKeyboardMoveSelectionActive else { return }
        isKeyboardMoveSelectionActive = false
        keyboardMoveSelectionShortcut = ""
        boundarySnapGuideX = nil
        boundarySnapGuideY = nil
        let moveButton = moveSelectionButtonView()
        moveButton?.isPressed = false
        moveButton?.needsDisplay = true
        moveButton?.displayIfNeeded()
        clearToolbarHoverState(suppressUntilMouseMoved: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearToolbarHoverState(suppressUntilMouseMoved: true)
            self.setToolbarHoverSuppressed(false)
            self.isToolbarMoveDragActive = false
        }
    }

    func setToolbarHoverSuppressed(_ suppressed: Bool) {
        bottomStripView?.suppressesHover = suppressed
        rightStripView?.suppressesHover = suppressed
    }

    /// True if `btn` belongs to `strip` (direct subview or via the strip's view
    /// tree — covers both in-overlay and glass-chrome-panel hosting).
    func isButton(_ btn: NSView, inStrip strip: ToolbarStripView?) -> Bool {
        guard let strip else { return false }
        var v: NSView? = btn
        while let cur = v {
            if cur === strip { return true }
            v = cur.superview
        }
        return strip.buttonViews.contains { $0 === btn }
    }

    func drawHoveredTooltip() {
        // In editor mode, tooltips are drawn via a floating NSView in the chrome parent
        if isEditorMode {
            updateEditorTooltipView()
            return
        }

        guard let tooltip = hoveredTooltip, !tooltip.isEmpty,
              let btn = hoveredTooltipButtonView,
              !PopoverHelper.isVisible else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor,
        ]
        let str = tooltip as NSString
        let textSize = str.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let tipW = textSize.width + pad * 2
        let tipH = textSize.height + pad

        // Convert the button's rect to OverlayView coordinates. The button may
        // live in a separate glass chrome panel (different window), so go through
        // screen coordinates rather than a same-window convert (which would
        // misplace the tooltip far off, e.g. screen-left).
        let btnFrame: NSRect
        if let btnWindow = btn.window, let selfWindow = window, btnWindow !== selfWindow {
            let inBtnWindow = btn.convert(btn.bounds, to: nil)
            let screenRect = btnWindow.convertToScreen(inBtnWindow)
            let inSelfWindow = selfWindow.convertFromScreen(screenRect)
            btnFrame = convert(inSelfWindow, from: nil)
        } else {
            btnFrame = btn.convert(btn.bounds, to: self)
        }
        // The button is hosted in a strip; find which strip via the panel chain.
        let isBottomBar = isButton(btn, inStrip: bottomStripView)
        let tipRect: NSRect

        if isBottomBar {
            // Above bottom bar, or below if no room
            var tipY = bottomBarRect.maxY + 4
            if tipY + tipH > bounds.maxY - 2 { tipY = bottomBarRect.minY - tipH - 4 }
            tipRect = NSRect(x: btnFrame.midX - tipW / 2, y: tipY, width: tipW, height: tipH)
        } else {
            // Left of right bar
            tipRect = NSRect(x: btnFrame.minX - tipW - 6, y: btnFrame.midY - tipH / 2, width: tipW, height: tipH)
        }

        // Clamp to bounds
        let clamped = NSRect(
            x: max(bounds.minX + 2, min(tipRect.minX, bounds.maxX - tipW - 2)),
            y: max(bounds.minY + 2, min(tipRect.minY, bounds.maxY - tipH - 2)),
            width: tipW, height: tipH)

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: clamped, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: clamped.minX + pad, y: clamped.minY + pad / 2), withAttributes: attrs)
    }

    /// In editor mode, show tooltip as a floating NSView in the chrome parent (container),
    /// since EditorView's draw() can only paint within the image bounds.
    func updateEditorTooltipView() {
        guard let parent = chromeParentView else {
            editorTooltipView?.removeFromSuperview()
            editorTooltipView = nil
            return
        }

        guard let tooltip = hoveredTooltip, !tooltip.isEmpty,
              let btn = hoveredTooltipButtonView,
              !PopoverHelper.isVisible else {
            editorTooltipView?.removeFromSuperview()
            editorTooltipView = nil
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = tooltip as NSString
        let textSize = str.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let tipW = textSize.width + pad * 2
        let tipH = textSize.height + pad

        let btnFrame = btn.convert(btn.bounds, to: parent)
        let isBottomBar = btn.superview === bottomStripView
        let tipRect: NSRect

        if isBottomBar {
            let stripFrame = bottomStripView?.frame ?? .zero
            var tipY = stripFrame.maxY + 4
            if tipY + tipH > parent.bounds.maxY - 2 { tipY = stripFrame.minY - tipH - 4 }
            tipRect = NSRect(x: btnFrame.midX - tipW / 2, y: tipY, width: tipW, height: tipH)
        } else {
            tipRect = NSRect(x: btnFrame.minX - tipW - 6, y: btnFrame.midY - tipH / 2, width: tipW, height: tipH)
        }

        let clamped = NSRect(
            x: max(parent.bounds.minX + 2, min(tipRect.minX, parent.bounds.maxX - tipW - 2)),
            y: max(parent.bounds.minY + 2, min(tipRect.minY, parent.bounds.maxY - tipH - 2)),
            width: tipW, height: tipH)

        let tip: TooltipBackgroundView
        if let existing = editorTooltipView as? TooltipBackgroundView {
            tip = existing
        } else {
            editorTooltipView?.removeFromSuperview()
            tip = TooltipBackgroundView(frame: clamped)
            parent.addSubview(tip)
            editorTooltipView = tip
        }
        tip.frame = clamped
        tip.text = tooltip
        tip.needsDisplay = true
    }

    func handleToolbarButtonRightClick(_ action: ToolbarButtonAction, anchorView: NSView) {
        switch action {
        case .autoRedact:
            showRedactTypePopover(
                anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        case .save:
            let menu = NSMenu()
            switch SaveActionPreference.current {
            case .saveToFolder:
                let saveAsItem = NSMenuItem(
                    title: L("Save As..."), action: #selector(saveAsMenuAction), keyEquivalent: "")
                saveAsItem.target = self
                menu.addItem(saveAsItem)
            case .askWhereToSave:
                let folderName = URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent
                let saveToFolderItem = NSMenuItem(
                    title: "\(L("Save to")) \(folderName)",
                    action: #selector(saveToFolderMenuAction),
                    keyEquivalent: "")
                saveToFolderItem.target = self
                menu.addItem(saveToFolderItem)
            }
            menu.popUp(
                positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
        case .upload:
            #if !OFFLINE
            showUploadConfirmPopover(
                anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
            #endif
        case .translate:
            showTranslatePopover(
                anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        case .micAudio:
            showMicDeviceMenu(anchorView: anchorView)
        case .showKeystrokes:
            showKeystrokeModeMenu(anchorView: anchorView)
        case .webcam:
            showWebcamDeviceMenu(anchorView: anchorView)
        default:
            break
        }
    }

    func showKeystrokeModeMenu(anchorView: NSView) {
        let menu = NSMenu()
        let allKeys = UserDefaults.standard.bool(forKey: "keystrokeShowAll")

        let shortcutsItem = NSMenuItem(title: L("Shortcuts Only"), action: #selector(keystrokeModeShortcuts), keyEquivalent: "")
        shortcutsItem.target = self
        if !allKeys { shortcutsItem.state = .on }
        menu.addItem(shortcutsItem)

        let allItem = NSMenuItem(title: L("All Keystrokes"), action: #selector(keystrokeModeAll), keyEquivalent: "")
        allItem.target = self
        if allKeys { allItem.state = .on }
        menu.addItem(allItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
    }

    @objc func keystrokeModeShortcuts() {
        UserDefaults.standard.set(false, forKey: "keystrokeShowAll")
    }

    @objc func keystrokeModeAll() {
        UserDefaults.standard.set(true, forKey: "keystrokeShowAll")
    }

    func showMicDeviceMenu(anchorView: NSView) {
        let menu = NSMenu()
        let savedUID = UserDefaults.standard.string(forKey: "selectedMicDeviceUID")
        let micOn = UserDefaults.standard.bool(forKey: "recordMicAudio")

        // "None" option — turns off mic recording
        let noneItem = NSMenuItem(title: L("None"), action: #selector(micMenuNone), keyEquivalent: "")
        noneItem.target = self
        if !micOn { noneItem.state = .on }
        menu.addItem(noneItem)
        menu.addItem(NSMenuItem.separator())

        // List available audio input devices (filter out virtual aggregate devices)
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio, position: .unspecified).devices
            .filter { !$0.uniqueID.contains("CADefaultDeviceAggregate") }
        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(micMenuSelectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            if micOn && (savedUID == device.uniqueID || (savedUID == nil && device == AVCaptureDevice.default(for: .audio))) {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
    }

    @objc func micMenuNone() {
        UserDefaults.standard.set(false, forKey: "recordMicAudio")
        stopMicLevelMonitor()
        rebuildToolbarLayout()
    }

    @objc func micMenuSelectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: "selectedMicDeviceUID")
        UserDefaults.standard.set(true, forKey: "recordMicAudio")
        rebuildToolbarLayout()
        startMicLevelMonitor()
    }

    // MARK: - Recording Permission Pre-checks

    /// Sequentially request mic and camera permissions so system dialogs don't overlap behind the overlay.
    func preCheckRecordingPermissions() {
        checkMicPermission { [weak self] in
            self?.checkCameraPermission()
        }
    }

    func checkMicPermission(then next: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "recordMicAudio") else { next(); return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            startMicLevelMonitor()
            next()
        } else if status == .notDetermined {
            let savedLevel = window?.level
            window?.level = .normal
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if let saved = savedLevel { self?.window?.level = saved }
                    if granted {
                        self?.startMicLevelMonitor()
                    } else {
                        UserDefaults.standard.set(false, forKey: "recordMicAudio")
                        self?.rebuildToolbarLayout()
                    }
                    next()
                }
            }
        } else {
            UserDefaults.standard.set(false, forKey: "recordMicAudio")
            rebuildToolbarLayout()
            showMicPermissionAlert()
            next()
        }
    }

    func checkCameraPermission() {
        guard UserDefaults.standard.bool(forKey: "recordWebcam") else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized {
            showWebcamSetupPreview()
        } else if status == .notDetermined {
            let savedLevel = window?.level
            window?.level = .normal
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if let saved = savedLevel { self?.window?.level = saved }
                    if granted {
                        self?.showWebcamSetupPreview()
                    } else {
                        UserDefaults.standard.set(false, forKey: "recordWebcam")
                        self?.rebuildToolbarLayout()
                    }
                }
            }
        } else {
            UserDefaults.standard.set(false, forKey: "recordWebcam")
            rebuildToolbarLayout()
        }
    }

    // MARK: - Webcam Toggle & Device Menu

    func toggleWebcamOverlay() {
        let current = UserDefaults.standard.bool(forKey: "recordWebcam")
        if current {
            UserDefaults.standard.set(false, forKey: "recordWebcam")
            dismissWebcamSetupPreview()
            rebuildToolbarLayout()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            UserDefaults.standard.set(true, forKey: "recordWebcam")
            rebuildToolbarLayout()
            showWebcamSetupPreview()
        case .notDetermined:
            let savedLevel = window?.level
            window?.level = .normal
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if let saved = savedLevel { self?.window?.level = saved }
                    if granted {
                        UserDefaults.standard.set(true, forKey: "recordWebcam")
                        self?.showWebcamSetupPreview()
                    }
                    self?.rebuildToolbarLayout()
                }
            }
        case .denied, .restricted:
            showCameraPermissionAlert()
        @unknown default:
            break
        }
    }

    func showWebcamSetupPreview() {
        guard webcamSetupPreview == nil else { return }
        guard let screen = window?.screen ?? NSScreen.main else { return }

        let overlay = WebcamOverlay(screen: screen)
        let position = WebcamPosition(rawValue: UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight") ?? .bottomRight
        let size = WebcamSize(rawValue: UserDefaults.standard.string(forKey: "webcamSize") ?? "medium") ?? .medium
        let shape = WebcamShape(rawValue: UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") ?? .circle

        let screenOrigin = screen.frame.origin
        let screenRect = NSRect(
            x: selectionRect.origin.x + screenOrigin.x,
            y: selectionRect.origin.y + screenOrigin.y,
            width: selectionRect.width,
            height: selectionRect.height)

        overlay.configure(position: position, size: size, shape: shape, recordingRect: screenRect)
        overlay.startPreview(deviceUID: UserDefaults.standard.string(forKey: "selectedCameraDeviceUID"))
        overlay.setDraggable(true)
        overlay.orderFront(nil)
        webcamSetupPreview = overlay
    }

    func dismissWebcamSetupPreview() {
        webcamSetupPreview?.stopPreview()
        webcamSetupPreview?.close()
        webcamSetupPreview = nil
    }

    /// Detach the setup preview so it can be reused during recording (avoids camera restart).
    func detachWebcamSetupPreview() -> WebcamOverlay? {
        let overlay = webcamSetupPreview
        webcamSetupPreview = nil
        return overlay
    }

    func updateWebcamSetupPreview() {
        guard webcamSetupPreview != nil else { return }
        dismissWebcamSetupPreview()
        if UserDefaults.standard.bool(forKey: "recordWebcam") {
            showWebcamSetupPreview()
        }
    }

    /// Reposition the webcam preview to follow the current selection without restarting the camera.
    func repositionWebcamSetupPreview() {
        guard let overlay = webcamSetupPreview,
              let screen = window?.screen ?? NSScreen.main else { return }
        let position = WebcamPosition(rawValue: UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight") ?? .bottomRight
        let size = WebcamSize(rawValue: UserDefaults.standard.string(forKey: "webcamSize") ?? "medium") ?? .medium
        let shape = WebcamShape(rawValue: UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") ?? .circle
        let screenOrigin = screen.frame.origin
        let screenRect = NSRect(
            x: selectionRect.origin.x + screenOrigin.x,
            y: selectionRect.origin.y + screenOrigin.y,
            width: selectionRect.width,
            height: selectionRect.height)
        overlay.configure(position: position, size: size, shape: shape, recordingRect: screenRect)
    }

    func showCameraPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L("Camera Access Required")
        alert.informativeText = L("macshot needs camera permission for the webcam overlay. Open System Settings to grant access.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showWebcamDeviceMenu(anchorView: NSView) {
        let menu = NSMenu()
        let savedUID = UserDefaults.standard.string(forKey: "selectedCameraDeviceUID")
        let webcamOn = UserDefaults.standard.bool(forKey: "recordWebcam")

        let noneItem = NSMenuItem(title: L("None"), action: #selector(webcamMenuNone), keyEquivalent: "")
        noneItem.target = self
        if !webcamOn { noneItem.state = .on }
        menu.addItem(noneItem)
        menu.addItem(NSMenuItem.separator())

        let devices = WebcamOverlay.availableCameras
        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(webcamMenuSelectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            if webcamOn && (savedUID == device.uniqueID || (savedUID == nil && device == AVCaptureDevice.default(for: .video))) {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
    }

    @objc func webcamMenuNone() {
        UserDefaults.standard.set(false, forKey: "recordWebcam")
        dismissWebcamSetupPreview()
        rebuildToolbarLayout()
    }

    @objc func webcamMenuSelectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: "selectedCameraDeviceUID")
        UserDefaults.standard.set(true, forKey: "recordWebcam")
        rebuildToolbarLayout()
        updateWebcamSetupPreview()
    }

    /// Update the color swatch on the main toolbar's color button without a full rebuild.
    func updateToolbarColorSwatch() {
        if let idx = bottomButtons.firstIndex(where: { if case .color = $0.action { return true } else { return false } }) {
            bottomButtons[idx].bgColor = currentColor
            bottomStripView?.updateState(from: bottomButtons)
            // Schedule button redraw on next run loop iteration so it happens after
            // the overlay's own draw pass (which can paint over button subviews).
            if idx < (bottomStripView?.buttonViews.count ?? 0) {
                let buttonView = bottomStripView?.buttonViews[idx]
                DispatchQueue.main.async {
                    buttonView?.needsDisplay = true
                }
            }
        }
    }

    func handleToolbarAction(_ action: ToolbarButtonAction, mousePoint: NSPoint = .zero) {
        switch action {
        case .tool(let tool):
            commitTextFieldIfNeeded()
            showBeautifyInOptionsRow = false  // switch back to tool options
            currentTool = tool
            // Auto-select first emoji when switching to stamp tool with nothing selected
            if tool == .stamp && currentStampImage == nil {
                currentStampImage = StampEmojis.renderEmoji(StampEmojis.common[0])
                currentStampEmoji = StampEmojis.common[0]
            }
            needsDisplay = true
        case .loupe:
            currentTool = .loupe
            needsDisplay = true
        case .color:
            if PopoverHelper.toggleClosedIfOpen() { break }
            let colorBtn = bottomStripView?.buttonViews.first { if case .color = $0.action { return true }; return false }
            showColorPickerPopover(target: .drawColor, anchorView: colorBtn)
        case .sizeDisplay:
            break
        case .moveSelection:
            guard let win = window else { break }
            isToolbarMoveDragActive = true
            var moveButton = rightStripView?.buttonViews.first {
                if case .moveSelection = $0.action { return true }
                return false
            }
            setToolbarHoverSuppressed(true)
            clearToolbarHoverState(suppressUntilMouseMoved: true, clearPressed: false)
            // Moving breaks window snap — revert to normal beautify mode
            if selectionIsWindowSnap {
                selectionIsWindowSnap = false
                snappedWindowID = nil
                snappedWindowImage = nil
                rebuildToolbarLayout()
                setToolbarHoverSuppressed(true)
                moveButton = rightStripView?.buttonViews.first {
                    if case .moveSelection = $0.action { return true }
                    return false
                }
            }
            moveButton?.isPressed = true
            moveButton?.needsDisplay = true
            moveButton?.displayIfNeeded()
            showMoveDragTooltip(anchor: moveButton)
            needsDisplay = true
            displayIfNeeded()
            // Synchronous drag loop: tracks mouse from button press until release.
            // Convert the current mouse via screen coords (the move button may
            // live in a glass chrome panel, so events target that window, not the
            // overlay — we read app-wide events and map by screen location).
            func overlayPoint(fromScreen screen: NSPoint) -> NSPoint {
                convert(win.convertPoint(fromScreen: screen), from: nil)
            }
            let startPoint = overlayPoint(fromScreen: NSEvent.mouseLocation)
            let offset = NSPoint(x: startPoint.x - selectionRect.origin.x, y: startPoint.y - selectionRect.origin.y)
            let hasWebcam = webcamSetupPreview != nil
            while true {
                guard let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                                  until: .distantFuture, inMode: .eventTracking, dequeue: true) else { break }
                let point = overlayPoint(fromScreen: NSEvent.mouseLocation)
                var moved = selectionRect
                moved.origin = NSPoint(x: point.x - offset.x, y: point.y - offset.y)
                // Snap the moved selection to nearby image edges (Option bypasses).
                selectionRect = boundarySnappedMovedRect(moved, modifiers: event.modifierFlags)
                if hasWebcam { repositionWebcamSetupPreview() }
                updateResolutionBox()  // track the box live during the move drag
                repositionToolbars()
                showMoveDragTooltip(anchor: moveButton)
                needsDisplay = true
                displayIfNeeded()
                if event.type == .leftMouseUp { break }
            }
            // Clear any boundary-snap guide lines left from the move.
            boundarySnapGuideX = nil
            boundarySnapGuideY = nil
            needsDisplay = true
            moveButton?.isPressed = false
            moveButton?.needsDisplay = true
            moveButton?.displayIfNeeded()
            clearToolbarHoverState(suppressUntilMouseMoved: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearToolbarHoverState(suppressUntilMouseMoved: true)
                self.setToolbarHoverSuppressed(false)
                self.isToolbarMoveDragActive = false
            }
        case .undo:
            undo()
        case .redo:
            redo()
        case .copy:
            overlayDelegate?.overlayViewDidConfirm()
        case .save:
            overlayDelegate?.overlayViewDidRequestSave()
        case .upload:
            #if !OFFLINE
            let confirmEnabled = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
            if confirmEnabled {
                let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
                let title: String
                switch provider {
                case "gdrive": title = L("Upload to Google Drive?")
                case "s3": title = L("Upload to S3?")
                default: title = L("Upload to imgbb.com?")
                }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = L("Your screenshot will be uploaded.")
                alert.addButton(withTitle: L("Upload"))
                alert.addButton(withTitle: L("Cancel"))
                alert.alertStyle = .informational
                // Temporarily lower window level so the alert is visible
                let originalLevel = window?.level ?? .statusBar
                window?.level = .normal
                let response = alert.runModal()
                window?.level = originalLevel
                if response == .alertFirstButtonReturn {
                    overlayDelegate?.overlayViewDidRequestUpload()
                }
            } else {
                overlayDelegate?.overlayViewDidRequestUpload()
            }
            #endif
        case .share:
            // Show share picker anchored to the share button, then dismiss on selection
            let shareBtn = rightStripView?.buttonViews.first { if case .share = $0.action { return true }; return false }
            overlayDelegate?.overlayViewDidRequestShare(anchorView: shareBtn)
        case .pin:
            overlayDelegate?.overlayViewDidRequestPin()
        case .ocr:
            overlayDelegate?.overlayViewDidRequestOCR()
        case .autoRedact:
            performAutoRedact()
        case .removeBackground:
            if #available(macOS 14.0, *) {
                overlayDelegate?.overlayViewDidRequestRemoveBackground()
            }
        case .invertColors:
            invertImageColors()
        case .effects:
            let btn = bottomStripView?.buttonViews.first { if case .effects = $0.action { return true }; return false }
            showEffectsPopover(anchorView: btn)
        case .beautify:
            commitTextFieldIfNeeded()
            stampPreviewPoint = nil
            loupeCursorPoint = .zero
            // Auto-enable beautify on first click in this session
            if !beautifyEnabled {
                beautifyEnabled = true
                UserDefaults.standard.set(true, forKey: "beautifyEnabled")
                startBeautifyToolbarAnimation()
            }
            // Load the custom background eagerly if that style is selected (the
            // beautifyConfig getter no longer does this as a side effect).
            ensureCustomBeautifyBackgroundLoaded()
            showBeautifyInOptionsRow = true
            needsDisplay = true
        case .beautifyStyle:
            beautifyStyleIndex = (beautifyStyleIndex + 1) % BeautifyRenderer.styles.count
            UserDefaults.standard.set(beautifyStyleIndex, forKey: "beautifyStyleIndex")
            needsDisplay = true
        case .delayCapture:
            break
        case .translate:
            if translateEnabled {
                // Toggle off: remove overlays, restore original
                translateEnabled = false
                annotations.removeAll { $0.tool == .translateOverlay }
                isTranslating = false
            } else {
                translateEnabled = true
                performTranslate(targetLang: TranslationService.targetLanguage)
            }
            needsDisplay = true
        case .record:
            // Enter recording mode — shows recording setup toolbar
            overlayDelegate?.overlayViewDidRequestEnterRecordingMode()
        case .startRecord:
            // Start recording — overlay will be dismissed by AppDelegate
            overlayDelegate?.overlayViewDidRequestStartRecording(rect: selectionRect)
        case .stopRecord:
            // Exit recording mode — dismiss overlay entirely (user changed mind)
            isRecording = false
            overlayDelegate?.overlayViewDidCancel()
        case .mouseHighlight:
            let current = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            UserDefaults.standard.set(!current, forKey: "recordMouseHighlight")
            rebuildToolbarLayout()
        case .showKeystrokes:
            toggleKeystrokeOverlay()
        case .systemAudio:
            let current = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            UserDefaults.standard.set(!current, forKey: "recordSystemAudio")
            rebuildToolbarLayout()
        case .micAudio:
            toggleMicAudio()
        case .webcam:
            toggleWebcamOverlay()
        case .cancel:
            overlayDelegate?.overlayViewDidCancel()
        case .detach:
            overlayDelegate?.overlayViewDidRequestDetach()
        case .scrollCapture:
            overlayDelegate?.overlayViewDidRequestScrollCapture(rect: selectionRect)
        case .addCapture:
            overlayDelegate?.overlayViewDidRequestAddCapture()
        case .toggleAnnotationTools:
            commitTextFieldIfNeeded()
            annotationToolsVisible.toggle()
            needsDisplay = true
        case .recordSettings:
            let gearBtn = rightStripView?.buttonViews.first { if case .recordSettings = $0.action { return true }; return false }
            showRecordingSettingsPopover(anchorView: gearBtn)
        }

        // Rebuild toolbars to reflect new state (selected tool, color, etc.)
        rebuildToolbarLayout()
    }

    /// Returns a color if a preset swatch was clicked, toggles the inline HSB picker
    /// if the custom picker swatch was clicked, or picks from the HSB gradient.
    /// Returns nil if nothing was hit.

    func applyColorToTextIfEditing() {
        if textEditor.isEditing {
            textEditor.applyColorToLiveText(color: annotationColor)
        }
    }

    /// Push a property change undo entry. Called by ToolOptionsRowView when editing completes.
    func updateBeautifySwatch(styleIndex: Int) {
        toolOptionsRowView?.updateBeautifySwatch(styleIndex: styleIndex)
    }

    func pushPropertyChangeUndo(annotation: Annotation, snapshot: Annotation) {
        undoStack.append(.propertyChange(annotation: annotation, snapshot: snapshot))
        redoStack.removeAll()
        cachedCompositedImage = nil
    }

    func applyColorToSelectedAnnotation() {
        guard !selectedAnnotations.isEmpty else { return }
        for ann in selectedAnnotations {
            ann.color = opacityAppliedColor(for: ann.tool)
        }
        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Apply current text formatting from textEditor to selected text annotations (when not actively editing).
    func applyTextFormattingToSelectedAnnotations() {
        guard textEditor.textView == nil else { return }  // skip if actively editing
        var changed = false
        for ann in selectedAnnotations where ann.tool == .text {
            ann.fontSize = textEditor.fontSize
            ann.isBold = textEditor.bold
            ann.isItalic = textEditor.italic
            ann.isUnderline = textEditor.underline
            ann.isStrikethrough = textEditor.strikethrough
            ann.fontFamilyName = textEditor.fontFamily == "System" ? nil : textEditor.fontFamily
            ann.textAlignment = textEditor.alignment
            ann.reRenderTextImage()
            changed = true
        }
        if changed {
            cachedCompositedImage = nil
            needsDisplay = true
        }
    }

    /// Apply current glyph-stroke state to the live NSTextView (if open).
    /// Touches existing text + future typing so the change is visible immediately.
    func applyGlyphStrokeToLiveTextView() {
        guard let tv = textEditor.textView, let storage = tv.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        let enabled = textEditor.glyphStrokeEnabled
        if range.length > 0 {
            OutlineTextRenderer.applyOutline(enabled ? textEditor.glyphStrokeColor : nil,
                                             to: storage, range: range)
        }
        if enabled {
            tv.typingAttributes[.macshotOutlineColor] = textEditor.glyphStrokeColor
        } else {
            tv.typingAttributes.removeValue(forKey: .macshotOutlineColor)
        }
        tv.needsDisplay = true
    }

    /// Apply text background/outline toggle to selected text annotations.
    func applyTextBgOutlineToSelectedAnnotations() {
        guard textEditor.textView == nil else { return }
        var changed = false
        for ann in selectedAnnotations where ann.tool == .text {
            ann.textBgColor = textEditor.bgEnabled ? textEditor.bgColor : nil
            ann.textOutlineColor = textEditor.outlineEnabled ? textEditor.outlineColor : nil
            ann.textGlyphStrokeColor = textEditor.glyphStrokeEnabled ? textEditor.glyphStrokeColor : nil
            ann.reRenderTextImage()
            changed = true
        }
        if changed {
            cachedCompositedImage = nil
        }
    }

    /// Returns currentColor with opacity applied for tools that respect it.
    /// Marker uses a fixed alpha in its draw method; loupe/measure/pixelate/blur are color-independent.
    func opacityAppliedColor(for tool: AnnotationTool) -> NSColor {
        switch tool {
        case .marker, .loupe, .measure, .pixelate, .blur, .translateOverlay:
            return currentColor
        default:
            return annotationColor
        }
    }

    // MARK: - Annotation Creation

    func startAnnotation(at point: NSPoint) {
        // No drawing in recording setup mode
        guard !isRecording else { return }

        // Click-to-select: if clicking on an existing annotation, select it instead of
        // starting a new annotation. Pencil and marker use long-press instead (so taps
        // and drags always draw, even single dots).
        let isPencilOrMarker = currentTool == .pencil || currentTool == .marker

        // Option = draw-through: with a drawing tool active, ignore annotations
        // (and their controls) under the cursor so the tool draws/places over
        // them instead of selecting/moving them. The select tool keeps its
        // normal behavior — its whole job is annotation interaction.
        let drawThrough = currentTool != .select && NSEvent.modifierFlags.contains(.option)

        // Multi-select delete button — check before single-select controls
        if !drawThrough && selectedAnnotations.count > 1 && multiSelectDeleteButtonRect.contains(point) {
            for ann in selectedAnnotations {
                if let idx = annotations.firstIndex(where: { $0 === ann }) {
                    annotations.remove(at: idx)
                    undoStack.append(.deleted(ann, idx))
                }
            }
            redoStack.removeAll()
            selectedAnnotations = []
            cachedCompositedImage = nil
            needsDisplay = true
            return
        }

        // Always check selected annotation controls (delete, resize, etc.) for all tools
        if currentTool != .colorSampler && !drawThrough {
            if let selected = selectedAnnotation {
                if handleSelectedAnnotationClick(selected, at: point) { return }
            }
        }

        // Click-to-select body: Ctrl+click adds/removes from multi-selection
        // (consistent with Ctrl+drag for lasso). Shift is reserved for angle/shape
        // constraining during drawing.
        // For pencil/marker, only instant-select when Ctrl is held or a multi-selection
        // already exists (so the user can drag the group without a modifier).
        // Text tool: allow selecting annotations on click; only skip instant-select
        // when clicking empty space (where a new text box should be created).
        let ctrlHeld = NSEvent.modifierFlags.contains(.control)
        let pencilHasMultiSelection = isPencilOrMarker && selectedAnnotations.count > 1
        let textHitsAnnotation = currentTool == .text
            && annotations.reversed().contains(where: { $0.isMovable && $0.hitTest(point: point) })
        let useInstantSelect = !drawThrough
            && currentTool != .colorSampler
            && (currentTool != .text || ctrlHeld || textHitsAnnotation)
            && (!isPencilOrMarker || ctrlHeld || pencilHasMultiSelection)
        if useInstantSelect {
            if let clicked = annotations.reversed().first(where: { $0.isMovable && $0.hitTest(point: point) }) {
                shiftClickPendingDeselect = nil
                if ctrlHeld {
                    if isSelected(clicked) {
                        // Defer deselect to mouseUp — allows dragging the full
                        // multi-selection even when ctrl+clicking a selected item.
                        shiftClickPendingDeselect = clicked
                    } else {
                        selectedAnnotations.append(clicked)
                    }
                } else if !isSelected(clicked) {
                    // Not Ctrl, not already selected: replace selection
                    selectedAnnotation = clicked
                }
                // Two-circle loupe: if the click landed on the small SOURCE circle
                // (and not the lens), drag the source — even on the first click
                // that also selects the loupe. Otherwise the first click would
                // fall through to the lens drag below.
                if clicked.tool == .loupe, let src = clicked.loupeSourceRect, src.width > 4 {
                    let sr = min(src.width, src.height) / 2 + 6
                    let onSource = hypot(point.x - src.midX, point.y - src.midY) <= sr
                    let onLens = NSBezierPath(ovalIn: clicked.loupeLensSquareRect).contains(point)
                    if onSource && !onLens {
                        isDraggingLoupeSource = true
                        didMoveAnnotation = false
                        preMoveSnapshots = [(clicked, clicked.clone())]
                        loupeSourceDragStart = point
                        loupeSourceDragOrig = src
                        cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
                        NSCursor.closedHand.set()
                        needsDisplay = true
                        return
                    }
                }
                // If already selected without Ctrl: keep current selection (allows multi-drag)
                isDraggingAnnotation = true
                didMoveAnnotation = false
                annotationDragStart = point
                // Build cache of non-selected annotations for fast drag rendering
                cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
                NSCursor.closedHand.set()
                needsDisplay = true
                return
            }
        }

        // Ctrl+click on empty space — start lasso marquee selection
        if ctrlHeld {
            isLassoSelecting = true
            lassoStart = point
            lassoRect = .zero
            needsDisplay = true
            return
        }

        // Pencil/marker without Ctrl: start a long-press timer. If the user holds
        // still for 300ms on an annotation, select it. Otherwise drawing starts
        // normally (the timer is cancelled in mouseDragged when movement exceeds 3px).
        if isPencilOrMarker && !ctrlHeld && !drawThrough {
            let hasAnnotationUnder = annotations.reversed().contains(where: { $0.isMovable && $0.hitTest(point: point) })
            if hasAnnotationUnder {
                longPressPoint = point
                longPressTriggered = false
                longPressTimer?.invalidate()
                longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.longPressTriggered = true
                    self.longPressTimer = nil
                    // Select the annotation under the long-press point
                    if let clicked = self.annotations.reversed().first(where: { $0.isMovable && $0.hitTest(point: point) }) {
                        self.shiftClickPendingDeselect = nil
                        if NSEvent.modifierFlags.contains(.control) {
                            if self.isSelected(clicked) {
                                self.shiftClickPendingDeselect = clicked
                            } else {
                                self.selectedAnnotations.append(clicked)
                            }
                        } else if !self.isSelected(clicked) {
                            self.selectedAnnotation = clicked
                        }
                        self.isDraggingAnnotation = true
                        self.didMoveAnnotation = false
                        self.annotationDragStart = point
                        // Build cache of non-selected annotations for fast drag rendering
                        self.cachedAnnotationLayerExcludingSelected = self.buildAnnotationLayer(excluding: Set(self.selectedAnnotations.map { ObjectIdentifier($0) }))
                        // Cancel any in-progress pencil stroke
                        self.currentAnnotation = nil
                        NSCursor.closedHand.set()
                        self.needsDisplay = true
                    }
                }
            }
        }

        // Clicking empty space — clear selection and start new annotation
        if !selectedAnnotations.isEmpty { selectedAnnotations = [] }

        // Dispatch to extracted tool handler if available
        if let handler = toolHandlers[currentTool] {
            if let annotation = handler.start(at: point, canvas: self) {
                // Apply outline color from settings for supported tools
                let outlineTools: [AnnotationTool] = [.arrow, .line, .rectangle, .ellipse, .number]
                if outlineTools.contains(currentTool) && UserDefaults.standard.bool(forKey: "annotationOutlineEnabled") {
                    annotation.outlineColor = ToolOptionsRowView.savedOutlineColor
                }
                currentAnnotation = annotation
                needsDisplay = true
            }
            return
        }

        // Color sampler: click sets the current drawing color, no annotation created.
        // Note: point is already in canvas space (converted by caller).
        if currentTool == .colorSampler {
            if let screenshot = screenshotImage,
                let result = sampleColor(from: screenshot, at: point)
            {
                currentColor = result.color
                currentColorOpacity = 1.0
                OverlayView.lastUsedOpacity = 1.0
                UserDefaults.standard.set(1.0, forKey: "lastUsedColorOpacity")
                // Also save to selected custom slot
                if selectedColorSlot >= 0 && selectedColorSlot < customColors.count {
                    customColors[selectedColorSlot] = result.color.withAlphaComponent(1.0)
                    saveCustomColors()
                    // Advance to next slot for rapid collection
                    let nextSlot = selectedColorSlot + 1
                    if nextSlot < customColors.count { selectedColorSlot = nextSlot }
                }
                showOverlayError(String(format: L("Set color %@"), result.hex))
                needsDisplay = true
            }
            return
        }

        if currentTool == .text && !drawThrough {
            // Click on existing text annotation → select it (double-click enters edit via handleSelectedAnnotationClick)
            if let existingAnn = annotations.reversed().first(where: {
                $0.tool == .text && $0.hitTest(point: point)
            }) {
                selectedAnnotation = existingAnn
                needsDisplay = true
                // If double-click, immediately enter edit mode
                if let event = NSApp.currentEvent, event.clickCount >= 2 {
                    textEditor.editingAnnotation = existingAnn
                    textEditor.restoreState(from: existingAnn)
                    if let idx = annotations.firstIndex(where: { $0 === existingAnn }) {
                        annotations.remove(at: idx)
                        selectedAnnotation = nil
                    }
                    showTextField(
                        at: existingAnn.textDrawRect.origin,
                        existingText: existingAnn.attributedText,
                        existingFrame: existingAnn.textDrawRect)
                    cachedCompositedImage = nil
                }
            } else if !justDismissedTextEditor {
                // Click on empty space → new text annotation, immediately enter
                // edit. Skipped when this same click just dismissed an open editor
                // (clicking out should close it, not place a new field).
                showTextField(at: point)
            }
        }
    }

    func updateAnnotation(at point: NSPoint, shiftHeld: Bool = false) {
        guard let annotation = currentAnnotation else { return }
        if let handler = toolHandlers[annotation.tool] {
            handler.update(to: point, shiftHeld: shiftHeld, canvas: self)
        }
    }

    func finishAnnotation(_ annotation: Annotation) {
        if let handler = toolHandlers[annotation.tool] {
            handler.finish(canvas: self)
        }
    }

    /// Handle click on the selected annotation's controls (resize handles, rotation, delete).
    /// Returns true if the click was consumed. Does NOT check the annotation body — that's
    /// handled by the caller's hit-test loop.
    func handleSelectedAnnotationClick(_ selected: Annotation, at point: NSPoint) -> Bool {
        // Unrotate point for resize handle hit test
        let handleTestPoint: NSPoint
        if selected.rotation != 0 && selected.supportsRotation {
            let center = NSPoint(x: selected.boundingRect.midX, y: selected.boundingRect.midY)
            let cos_r = cos(-selected.rotation)
            let sin_r = sin(-selected.rotation)
            let dx = point.x - center.x
            let dy = point.y - center.y
            handleTestPoint = NSPoint(
                x: center.x + dx * cos_r - dy * sin_r,
                y: center.y + dx * sin_r + dy * cos_r)
        } else {
            handleTestPoint = point
        }
        // Two-circle loupe: source-circle resize handle (changes zoom).
        if selected.tool == .loupe, loupeSourceHandleRect != .zero,
           loupeSourceHandleRect.insetBy(dx: -6, dy: -6).contains(point) {
            isResizingLoupeSource = true
            didMoveAnnotation = false
            preMoveSnapshots = [(selected, selected.clone())]
            loupeSourceDragStart = point
            loupeSourceDragOrig = selected.loupeSourceRect ?? .zero
            cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
            NSCursor.closedHand.set()
            needsDisplay = true
            return true
        }
        // Check resize handles (populated by drawAnnotationControls)
        for (handleIdx, handleEntry) in annotationResizeHandleRects.enumerated() {
            let (handle, rect) = handleEntry
            if rect.insetBy(dx: -4, dy: -4).contains(handleTestPoint) {
                isResizingAnnotation = true
                // Snapshot for undo + change detection (resize records an edit).
                preMoveSnapshots = [(selected, selected.clone())]
                // Build cache of non-selected annotations for fast resize rendering
                cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
                annotationResizeHandle = handle
                annotationResizeOrigStart = selected.startPoint
                annotationResizeOrigEnd = selected.endPoint
                annotationResizeOrigTextOrigin = selected.textDrawRect.origin
                annotationResizeMouseStart = point
                annotationResizeAnchorIndex = -1
                if let anchors = selected.anchorPoints, anchors.count >= 3, handleIdx >= 2 {
                    let anchorIdx = handleIdx - 2 + 1
                    if anchorIdx > 0 && anchorIdx < anchors.count - 1 {
                        annotationResizeAnchorIndex = anchorIdx
                        annotationResizeOrigControlPoint = anchors[anchorIdx]
                    }
                } else if handle == .none || (handle != .bottomLeft && handle != .topRight) {
                    if annotationResizeAnchorIndex < 0 {
                        annotationResizeOrigControlPoint =
                            selected.controlPoint
                            ?? NSPoint(
                                x: (selected.startPoint.x + selected.endPoint.x) / 2,
                                y: (selected.startPoint.y + selected.endPoint.y) / 2
                            )
                    }
                }
                NSCursor.closedHand.set()
                needsDisplay = true
                return true
            }
        }
        // Check rotation handle
        if annotationRotateHandleRect != .zero
            && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point)
        {
            isRotatingAnnotation = true
            // Snapshot for undo + change detection (rotate records an edit).
            preMoveSnapshots = [(selected, selected.clone())]
            cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
            let center = NSPoint(x: selected.boundingRect.midX, y: selected.boundingRect.midY)
            rotationStartAngle = atan2(point.x - center.x, point.y - center.y)
            rotationOriginal = selected.rotation
            NSCursor.closedHand.set()
            needsDisplay = true
            return true
        }
        // Check edit button (text annotations only)
        if selected.tool == .text && annotationEditButtonRect != .zero && annotationEditButtonRect.contains(point) {
            textEditor.restoreState(from: selected)
            if let idx = annotations.firstIndex(where: { $0 === selected }) {
                annotations.remove(at: idx)
                selectedAnnotation = nil
            }
            showTextField(
                at: selected.textDrawRect.origin, existingText: selected.attributedText,
                existingFrame: selected.textDrawRect)
            needsDisplay = true
            return true
        }
        // Check delete button
        if annotationDeleteButtonRect.contains(point) {
            if let idx = annotations.firstIndex(where: { $0 === selected }) {
                annotations.remove(at: idx)
                undoStack.append(.deleted(selected, idx))
                redoStack.removeAll()
            }
            selectedAnnotation = nil
            needsDisplay = true
            return true
        }
        // Double-click on text annotation — enter edit mode
        if selected.tool == .text && selected.hitTest(point: point) {
            if let event = NSApp.currentEvent, event.clickCount >= 2 {
                textEditor.editingAnnotation = selected
                textEditor.restoreState(from: selected)
                if let idx = annotations.firstIndex(where: { $0 === selected }) {
                    annotations.remove(at: idx)
                    selectedAnnotation = nil
                }
                showTextField(
                    at: selected.textDrawRect.origin, existingText: selected.attributedText,
                    existingFrame: selected.textDrawRect)
                cachedCompositedImage = nil
                return true
            }
        }
        // Two-circle loupe: pressing the small SOURCE circle drags it
        // independently (re-roots what's magnified), with the connecting line
        // auto-adjusting. Check this BEFORE the lens body so the source wins when
        // the press is over it but not over the lens.
        if selected.tool == .loupe, let src = selected.loupeSourceRect, src.width > 4 {
            let sr = min(src.width, src.height) / 2 + 6
            let onSource = hypot(point.x - src.midX, point.y - src.midY) <= sr
            let onLens = NSBezierPath(ovalIn: selected.loupeLensSquareRect).contains(point)
            if onSource && !onLens {
                isDraggingLoupeSource = true
                didMoveAnnotation = false
                loupeSourceDragStart = point
                loupeSourceDragOrig = src
                cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
                NSCursor.closedHand.set()
                needsDisplay = true
                return true
            }
        }
        // Click on the annotation body — start drag (annotation already selected)
        if selected.hitTest(point: point) {
            isDraggingAnnotation = true
            didMoveAnnotation = false
            annotationDragStart = point
            cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
            NSCursor.closedHand.set()
            needsDisplay = true
            return true
        }
        return false
    }

    // MARK: - Text Field

    func showTextField(
        at point: NSPoint, existingText: NSAttributedString? = nil, existingFrame: NSRect = .zero
    ) {
        textEditor.show(
            in: self, at: point, color: currentColor,
            existingText: existingText, existingFrame: existingFrame,
            canvas: self)
        textEditor.textView?.delegate = self
        rebuildToolbarLayout()
        needsDisplay = true
    }

    func cancelTextEditing() {
        textToolDoubleClickCopyDeadline = 0
        textEditor.cancel(canvas: self)
        window?.makeFirstResponder(self)
        rebuildToolbarLayout()
        needsDisplay = true
    }

    func toggleKeystrokeOverlay() {
        let current = UserDefaults.standard.bool(forKey: "recordKeystroke")
        if current {
            UserDefaults.standard.set(false, forKey: "recordKeystroke")
            rebuildToolbarLayout()
            return
        }
        // Requires Input Monitoring permission for CGEvent tap
        if KeystrokeOverlay.hasInputMonitoringPermission {
            UserDefaults.standard.set(true, forKey: "recordKeystroke")
            rebuildToolbarLayout()
        } else {
            overlayDelegate?.overlayViewDidRequestInputMonitoringPermission()
        }
    }

    func commitTextFieldIfNeeded() {
        guard textEditor.isEditing else { return }
        textToolDoubleClickCopyDeadline = 0
        textEditor.commit(canvas: self)
        window?.makeFirstResponder(self)
        rebuildToolbarLayout()
        needsDisplay = true
    }

    // MARK: - Mic Permission & Toggle

    func toggleMicAudio() {
        let current = UserDefaults.standard.bool(forKey: "recordMicAudio")
        if current {
            // Turning off — no permission needed
            UserDefaults.standard.set(false, forKey: "recordMicAudio")
            stopMicLevelMonitor()
            rebuildToolbarLayout()
            return
        }
        // Turning on — check mic permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            UserDefaults.standard.set(true, forKey: "recordMicAudio")
            rebuildToolbarLayout()
            startMicLevelMonitor()
        case .notDetermined:
            // Lower overlay so the system permission dialog is clickable
            let savedLevel = window?.level
            window?.level = .normal
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if let saved = savedLevel { self?.window?.level = saved }
                    if granted {
                        UserDefaults.standard.set(true, forKey: "recordMicAudio")
                        self?.startMicLevelMonitor()
                    }
                    self?.rebuildToolbarLayout()
                }
            }
        case .denied, .restricted:
            showMicPermissionAlert()
        @unknown default:
            break
        }
    }

    func showMicPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L("Microphone Access Required")
        alert.informativeText =
            L("macshot needs microphone permission to record voice audio. Open System Settings to grant access.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Mic Level Monitor

    func startMicLevelMonitor() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        stopMicLevelMonitor()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { return }

        var peakLevel: Float = 0
        let lock = NSLock()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<frames {
                let val = abs(channelData[0][i])
                if val > peak { peak = val }
            }
            lock.lock()
            peakLevel = peak
            lock.unlock()
        }

        do {
            try engine.start()
        } catch {
            return
        }
        micLevelEngine = engine

        // Poll level at ~20fps and drive the mic button's built-in level meter
        var displayLevel: Float = 0
        micLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            lock.lock()
            let level = peakLevel
            peakLevel = 0
            lock.unlock()
            // Smooth: fast attack, slow release
            displayLevel = level > displayLevel ? level : displayLevel * 0.8 + level * 0.2
            self?.setMicButtonLevel(displayLevel)
        }
    }

    func stopMicLevelMonitor() {
        micLevelTimer?.invalidate()
        micLevelTimer = nil
        micLevelEngine?.inputNode.removeTap(onBus: 0)
        micLevelEngine?.stop()
        micLevelEngine = nil
        setMicButtonLevel(0)
    }

    func setMicButtonLevel(_ level: Float) {
        // Find mic button in both toolbar strips
        let strips: [ToolbarStripView?] = [bottomStripView, rightStripView]
        for strip in strips {
            if let btn = strip?.buttonViews.first(where: {
                if case .micAudio = $0.action { return true }; return false
            }) {
                btn.micLevel = level
            }
        }
    }

    // MARK: - Context Menu Actions

    /// Add an anchor point to a line/arrow annotation at the position closest to `canvasPoint`.
    /// Inserts the point between the two nearest existing waypoints.
    func addAnchorPoint(to annotation: Annotation, at canvasPoint: NSPoint) {
        var pts = annotation.waypoints

        // Find which segment the point is closest to, and insert there
        var bestIdx = 1
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 1..<pts.count {
            let d = distanceToSegment(point: canvasPoint, from: pts[i - 1], to: pts[i])
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }

        // Project the point onto the segment for exact placement
        let a = pts[bestIdx - 1]
        let b = pts[bestIdx]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        let t: CGFloat =
            lenSq < 0.001
            ? 0.5
            : max(
                0.05, min(0.95, ((canvasPoint.x - a.x) * dx + (canvasPoint.y - a.y) * dy) / lenSq))
        let projected = NSPoint(x: a.x + t * dx, y: a.y + t * dy)

        pts.insert(projected, at: bestIdx)

        // Store as anchorPoints, update startPoint/endPoint to match
        annotation.anchorPoints = pts
        annotation.startPoint = pts.first!
        annotation.endPoint = pts.last!
        // Clear legacy controlPoint since we're using anchorPoints now
        annotation.controlPoint = nil
    }

    func distanceToSegment(point: NSPoint, from a: NSPoint, to b: NSPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.001 { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = NSPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - proj.x, point.y - proj.y)
    }

    @objc func saveAsMenuAction() {
        overlayDelegate?.overlayViewDidRequestSaveAs()
    }

    @objc func saveToFolderMenuAction() {
        overlayDelegate?.overlayViewDidRequestFileSave()
    }

}
