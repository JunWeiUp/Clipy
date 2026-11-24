import AVFoundation
import Cocoa
import UniformTypeIdentifiers

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayViewDidFinishSelection(_ rect: NSRect)
    func overlayViewSelectionDidChange(_ rect: NSRect)
    func overlayViewDidCancel()
    func overlayViewDidConfirm()
    func overlayViewDidRequestSave()
    func overlayViewDidRequestSaveAs()
    func overlayViewDidRequestPin()
    func overlayViewDidRequestOCR()
    func overlayViewDidRequestQuickSave()
    func overlayViewDidRequestFileSave()
    func overlayViewDidRequestUpload()
    func overlayViewDidRequestShare(anchorView: NSView?)
    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground()
    func overlayViewDidRequestEnterRecordingMode()
    func overlayViewDidRequestStartRecording(rect: NSRect)
    func overlayViewDidRequestStopRecording()
    func overlayViewDidRequestDetach()
    func overlayViewDidRequestScrollCapture(rect: NSRect)
    func overlayViewDidRequestStopScrollCapture()
    func overlayViewDidRequestToggleAutoScroll()
    func overlayViewDidRequestAccessibilityPermission()
    func overlayViewDidRequestInputMonitoringPermission()
    func overlayViewDidBeginSelection()
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect)
    func overlayViewDidChangeWindowSnapState()
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect)
    func overlayViewDidRequestAddCapture()
}

/// An entry in the undo/redo history.
enum UndoEntry {
    case added(Annotation)  // annotation was added; undo removes it
    case deleted(Annotation, Int)  // annotation was deleted at index; undo re-inserts it
    /// Image transform (crop/flip): stores the previous image and annotation offsets to restore.
    case imageTransform(previousImage: NSImage, annotationOffsets: [(Annotation, CGFloat, CGFloat)])
    /// Property change: stores the annotation and a snapshot taken before the edit.
    case propertyChange(annotation: Annotation, snapshot: Annotation)

    var annotation: Annotation {
        switch self {
        case .added(let a), .deleted(let a, _): return a
        case .propertyChange(let a, _): return a
        case .imageTransform:
            return Annotation(
                tool: .measure, startPoint: .zero, endPoint: .zero, color: .clear, strokeWidth: 0)  // dummy
        }
    }
}

/// Snapshot of the mutable editor state.
struct OverlayEditorState {
    var screenshotImage: NSImage?
    var selectionRect: NSRect
    var annotations: [Annotation]
    var undoStack: [UndoEntry]
    var redoStack: [UndoEntry]
    var currentTool: AnnotationTool
    var currentColor: NSColor
    var currentStrokeWidth: CGFloat
    var currentMarkerSize: CGFloat
    var currentNumberSize: CGFloat
    var numberCounter: Int
    var beautifyEnabled: Bool
    var beautifyStyleIndex: Int
    var effectsPreset: ImageEffectPreset
    var effectsBrightness: Float
    var effectsContrast: Float
    var effectsSaturation: Float
    var effectsSharpness: Float
}

class OverlayView: NSView {

    // MARK: - Properties

    weak var overlayDelegate: OverlayViewDelegate?
    var timingMark: ((String) -> Void)?

    override var isOpaque: Bool {
        !usesExternalScreenshotPreview && screenshotImage != nil && !isScrollCapturing && !isRecording && !isEditorMode
    }

    /// When true, hides overlay-only toolbar buttons (record, delay, cancel, move, scroll capture).
    /// Override point for subclasses. EditorView returns true.
    var isEditorMode: Bool { false }
    /// When true, NSScrollView handles zoom/pan/centering. Coordinate transforms become identity.
    var isInsideScrollView: Bool { false }
    /// When in scroll view mode, toolbar strips are added to this view (window content) instead of self.
    weak var chromeParentView: NSView?

    var screenshotImage: NSImage? {
        didSet {
            cancelRecognition()
            cachedCompositedImage = nil
            cachedEffectsScreenshot = nil
            cachedOpaqueRect = nil
            // Load the custom beautify background at session start. reset() only
            // runs at session teardown, so the FIRST capture of a freshly-created
            // pooled controller would otherwise render with no custom background
            // (and fall through to a gradient) if beautify was left on with the
            // custom-image style. The beautifyConfig getter is now side-effect-free,
            // so this must be done eagerly. Idempotent.
            if screenshotImage != nil { ensureCustomBeautifyBackgroundLoaded() }
            if captureSourceImage != nil {
                captureSourceImage = screenshotImage
            }
            if usesExternalScreenshotPreview {
                let cgImage = screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                externalScreenshotPreviewUpdater?(cgImage)
            }
            needsDisplay = true
            // Screenshot just arrived (async capture) — enable snap queries now.
            if screenshotImage != nil && windowSnapCooldown {
                windowSnapCooldown = false
                if window?.isVisible == true,
                   state == .idle && windowSnapEnabled && !windowSnapQueryInFlight {
                    queryWindowSnap(at: NSEvent.mouseLocation)
                }
            }
            // Build (or invalidate) the boundary-snap edge index off the main thread.
            boundarySnapBuildGeneration += 1
            boundarySnapIndex = nil
            boundarySnapGuideX = nil
            boundarySnapGuideY = nil
            if boundarySnapEnabled, !isEditorMode {
                scheduleBoundarySnapIndexBuild()
            }
        }
    }
    var captureSourceImage: NSImage?
    var externalScreenshotPreviewUpdater: ((CGImage?) -> Void)?
    var usesExternalScreenshotPreview = false {
        didSet { needsDisplay = true }
    }

    // State
    enum State {
        case idle
        case selecting
        case selected
    }

    var state: State = .idle

    // Zoom — the capture overlay no longer zooms (scroll/pinch zoom was
    // removed). These remain fixed at the identity values so the shared
    // coordinate transforms (viewToCanvas / canvasToView / applyZoomTransform)
    // stay pure pass-throughs; the editor zooms via NSScrollView magnification
    // instead, which doesn't touch these.
    var zoomLevel: CGFloat = 1.0
    var zoomAnchorCanvas: NSPoint = .zero
    var zoomAnchorView: NSPoint = .zero

    // Selection
    var selectionRect: NSRect = .zero {
        didSet { if selectionRect != oldValue { cancelRecognition() } }
    }

    // Fixed-size task ownership; pooled overlays must never retain an old session's OCR.
    let scanRecognition = ScreenshotOCRTaskOwner()
    let redactionRecognition = ScreenshotOCRTaskOwner()
    let translationRecognition = ScreenshotOCRTaskOwner()

    func cancelRecognition() {
        scanRecognition.cancel()
        redactionRecognition.cancel()
        translationRecognition.cancel()
        isTranslating = false
        (toolHandlers[.marker] as? MarkerToolHandler)?.reset()
        (toolHandlers[.pixelate] as? PixelateToolHandler)?.reset()
    }
    /// Selection rect from another overlay (in this view's local coords), drawn during cross-screen drag.
    var remoteSelectionRect: NSRect = .zero
    /// The full (unclipped) remote selection in this view's local coords — used for resize anchor calculation.
    var remoteSelectionFullRect: NSRect = .zero
    var isResizingRemoteSelection: Bool = false
    var remoteResizeHandle: ResizeHandle = .none
    var remoteResizeAnchor: NSPoint = .zero  // the fixed corner during remote resize
    var selectionStart: NSPoint = .zero
    /// Trackpad/mouse QoL: when the user right-clicks in the empty overlay
    /// (state == .idle), we anchor a selection at that point and let the
    /// cursor resize it with no button held. A subsequent left-click
    /// finalizes, ESC cancels. This mirrors the drag flow but removes the
    /// need to keep pressing — big usability win for large selections on
    /// trackpads.
    var isAnchoredSelecting: Bool = false
    var isDraggingSelection: Bool = false
    var isResizingSelection: Bool = false
    var resizeHandle: ResizeHandle = .none
    var dragOffset: NSPoint = .zero
    var lastDragPoint: NSPoint?  // for shift constraint on flagsChanged
    var spaceRepositioning: Bool = false  // Space held during drag to reposition
    var spaceRepositionLast: NSPoint = .zero  // last mouse position when space reposition started

    /// Snapshot of `undoStack.count` taken at the start of a fresh click in `selected` state.
    /// Used by the "double-click to copy" feature to rewind annotations that the first click
    /// (and any in-progress second click) added before triggering the confirm path.
    var doubleClickUndoBaseline: Int?
    /// Short-lived marker for the Text tool case where the first click opens an empty editor.
    var textToolDoubleClickCopyDeadline: TimeInterval = 0

    // Annotations
    var annotations: [Annotation] = [] {
        didSet {
            cachedCompositedImage = nil
            cachedEffectsScreenshot = nil
            // Update move button enabled state when annotations change
            if showToolbars { rebuildToolbarLayout() }
        }
    }
    var undoStack: [UndoEntry] = [] {
        didSet {
            // Every annotation/image edit mutates the undo stack — notify so the
            // editor can show/hide its "Done" button based on dirty state.
            if undoStack.count != oldValue.count { onContentChanged?() }
        }
    }
    var redoStack: [UndoEntry] = []
    /// Fired when editable content changes (undo stack, or beautify/effects).
    /// The detached editor uses this to reveal "Done" only once there's an edit.
    var onContentChanged: (() -> Void)?
    var currentAnnotation: Annotation?
    /// Whether the user is actively drawing/dragging a new annotation.
    var isActivelyDrawing: Bool { currentAnnotation != nil }

    // MARK: - Tool handlers
    lazy var toolHandlers: [AnnotationTool: AnnotationToolHandler] = {
        let handlers: [AnnotationToolHandler] = [
            PencilToolHandler(),
            MarkerToolHandler(),
            LineToolHandler(),
            ArrowToolHandler(),
            RectangleToolHandler(),
            FilledRectangleToolHandler(),
            EllipseToolHandler(),
            PixelateToolHandler(),
            LoupeToolHandler(),
            MeasureToolHandler(),
            NumberToolHandler(),
            StampToolHandler(),
            HighlightToolHandler(),
        ]
        return Dictionary(uniqueKeysWithValues: handlers.map { ($0.tool, $0) })
    }()
    /// Last tool the user explicitly picked — persisted across app launches.
    static var lastUsedTool: AnnotationTool = {
        if let raw = UserDefaults.standard.object(forKey: "lastUsedTool") as? Int,
           let tool = AnnotationTool(rawValue: raw) {
            return tool
        }
        return .arrow
    }()
    static var shouldRememberLastTool: Bool {
        UserDefaults.standard.object(forKey: "rememberLastTool") as? Bool ?? true
    }
    static var initialTool: AnnotationTool {
        shouldRememberLastTool ? lastUsedTool : .arrow
    }
    static func resetRememberedTool() {
        lastUsedTool = .arrow
        UserDefaults.standard.removeObject(forKey: "lastUsedTool")
    }
    var currentTool: AnnotationTool = {
        OverlayView.initialTool
    }() {
        didSet {
            // Persist drawing tool choices; skip transient/mode tools
            if OverlayView.shouldRememberLastTool && currentTool != .select && currentTool != .loupe {
                OverlayView.lastUsedTool = currentTool
                UserDefaults.standard.set(currentTool.rawValue, forKey: "lastUsedTool")
            }
        }
    }
    var currentColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "lastUsedColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return .systemRed
    }() {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: currentColor, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "lastUsedColor")
            }
            updateToolbarColorSwatch()
        }
    }
    /// currentColor with opacity applied — used for all tools except marker, loupe, measure, pixelate, blur
    var annotationColor: NSColor { currentColor.withAlphaComponent(currentColorOpacity) }
    var currentStrokeWidth: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "currentStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var currentNumberSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "numberStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var currentMarkerSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "markerStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var numberCounter: Int = 0
    var numberStartAt: Int = {
        UserDefaults.standard.object(forKey: "numberStartAt") as? Int ?? 1
    }()
    /// Next number value, derived from the annotations currently on the canvas
    /// (issue #211): one past the highest existing number, or `numberStartAt`
    /// when no number annotations exist. Deriving from canvas state means the
    /// sequence resets correctly after any delete, multi-delete, or undo —
    /// no separate counter to keep in sync.
    var nextNumberValue: Int {
        let maxExisting = annotations
            .filter { $0.tool == .number }
            .compactMap { $0.number }
            .max()
        if let maxExisting { return maxExisting + 1 }
        return numberStartAt
    }
    var currentNumberFormat: NumberFormat = {
        NumberFormat(rawValue: UserDefaults.standard.integer(forKey: "numberFormat")) ?? .decimal
    }()

    // Select/move mode
    /// All currently selected annotations (supports multi-select via Shift+Click).
    var selectedAnnotations: [Annotation] = [] {
        didSet {
            let oldSingle = oldValue.first
            let newSingle = selectedAnnotations.first
            if newSingle !== oldSingle || oldValue.count != selectedAnnotations.count {
                toolOptionsRowView?.clearEditingAnnotation()

                if selectedAnnotations.count == 1, let ann = newSingle {
                    // Load text annotation properties into textEditor so toolbar shows correct state
                    if ann.tool == .text {
                        textEditor.restoreState(from: ann)
                    }
                    toolOptionsRowView?.rebuild(forAnnotation: ann)
                    repositionToolbars()
                } else if selectedAnnotations.isEmpty {
                    if let tool = currentTool as AnnotationTool? {
                        toolOptionsRowView?.rebuild(for: tool)
                        repositionToolbars()
                    }
                } else {
                    // Multi-select: revert to tool options (no per-annotation editing)
                    if let tool = currentTool as AnnotationTool? {
                        toolOptionsRowView?.rebuild(for: tool)
                        repositionToolbars()
                    }
                }
            }
        }
    }

    /// Convenience: the single selected annotation (nil if 0 or 2+ selected).
    var selectedAnnotation: Annotation? {
        get { selectedAnnotations.count == 1 ? selectedAnnotations.first : nil }
        set {
            if let ann = newValue {
                selectedAnnotations = [ann]
            } else {
                selectedAnnotations = []
            }
        }
    }

    /// Whether an annotation is in the current selection.
    func isSelected(_ annotation: Annotation) -> Bool {
        selectedAnnotations.contains(where: { $0 === annotation })
    }
    var isDraggingAnnotation: Bool = false
    var didMoveAnnotation: Bool = false
    /// Pre-move clones of the annotations being dragged, captured on the first
    /// move so the drag can be pushed as an undo entry (and counts as an edit).
    var preMoveSnapshots: [(annotation: Annotation, snapshot: Annotation)] = []
    var annotationDragStart: NSPoint = .zero
    /// Two-circle loupe: dragging the small SOURCE circle (re-roots what's
    /// magnified) independently of the lens.
    var isDraggingLoupeSource: Bool = false
    var loupeSourceDragStart: NSPoint = .zero
    var loupeSourceDragOrig: NSRect = .zero
    /// Two-circle loupe: resizing the SOURCE circle (changes the zoom).
    var isResizingLoupeSource: Bool = false
    /// When ctrl+clicking an already-selected annotation, defer the deselect
    /// to mouseUp so the user can still drag the full multi-selection.
    weak var shiftClickPendingDeselect: Annotation?
    /// Lasso selection: Ctrl+drag on empty space draws a marquee rectangle.
    var isLassoSelecting: Bool = false
    var lassoStart: NSPoint = .zero
    var lassoRect: NSRect = .zero
    // Long-press-to-select for pencil/marker tools
    var longPressTimer: Timer?
    var longPressPoint: NSPoint = .zero
    var longPressTriggered: Bool = false
    /// Annotation under the cursor when using a non-select drawing tool — enables on-the-fly move without switching tools.
    var hoveredAnnotation: Annotation?
    /// Delays clearing hoveredAnnotation so the cursor can travel to handles/buttons that sit outside the hit area.
    var hoveredAnnotationClearTimer: Timer?

    // Text editing — state managed by TextEditingController
    let textEditor = TextEditingController()
    var textEditView: NSTextView? { textEditor.textView }
    /// True for the duration of a single mouseDown that committed an open text
    /// editor, so the text tool dismisses it without placing a new field at the
    /// click point. Reset at the end of mouseDown.
    var justDismissedTextEditor = false

    // Text box resize state (stays here — tied to mouse drag handling)
    var isResizingTextBox: Bool = false
    var textBoxResizeHandle: ResizeHandle = .none
    var textBoxResizeStart: NSPoint = .zero
    var textBoxOrigFrame: NSRect = .zero
    // (Text box move handle removed — standard annotation chrome handles movement)

    // Toolbars (drawn inline)
    var bottomButtons: [ToolbarButton] = []
    var rightButtons: [ToolbarButton] = []
    var bottomBarRect: NSRect = .zero
    var rightBarRect: NSRect = .zero
    var showToolbars: Bool = false {
        didSet {
            if showToolbars && !oldValue {
                rebuildToolbarLayout()
            } else if !showToolbars && oldValue {
                bottomStripView?.isHidden = true
                rightStripView?.isHidden = true
                toolOptionsRowView?.isHidden = true
                dismissResolutionBox()
                optionsRowRect = .zero
            }
        }
    }
    var bottomStripView: ToolbarStripView?
    var rightStripView: ToolbarStripView?
    var toolOptionsRowView: ToolOptionsRowView?

    /// Intended overlay-space rect of the options row. .zero when the row is hidden.
    var optionsRowRect: NSRect = .zero
    // Resolution box (W × H fields + presets). Replaces the old drawn size badge.
    var resolutionBox: ResolutionBoxView?
    /// Overlay-space frame of the resolution box (for chrome hit-test / cursor /
    /// zoom-badge anchoring). .zero when not shown.
    var resolutionBoxRect: NSRect = .zero
    var captureModeBar: CaptureModeBarView?
    var captureHintView: CaptureHintView?
    // Unified control island (mac-capture.html `.island`): one draggable group for
    // options row + annotation strip + capture bar + shortcut hint.
    var captureIsland: CaptureIslandView?
    var islandSnapGuides: [IslandSnapGuideView] = []
    /// User-placed bottom-centre anchor for this session (nil = pinned/default position).
    var islandAnchor: NSPoint?
    var islandDragStartAnchor: NSPoint?
    var islandCollapsed = false
    /// Overlay-space frame of the island. .zero when hidden.
    var islandRect: NSRect = .zero
    var preSelectionPresetButton: PreSelectionPresetButton?
    var preSelectionPresetButtonRect: NSRect = .zero

    // Beautify
    var beautifyEnabled: Bool = UserDefaults.standard.bool(forKey: "beautifyEnabled")
    var beautifyStyleIndex: Int = UserDefaults.standard.integer(
        forKey: "beautifyStyleIndex")
    var beautifyMode: BeautifyMode =
        BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
    var beautifyPadding: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyPadding") as? Double
        return v != nil ? CGFloat(v!) : 48
    }()
    var beautifyCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 10
    }()
    var beautifyShadowRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyShadowRadius") as? Double
        return v != nil ? CGFloat(v!) : 20
    }()
    var beautifyBgRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyBgRadius") as? Double
        return v != nil ? CGFloat(v!) : 8
    }()

    var customBeautifyBackground: NSImage? {
        didSet { cachedBeautifyBgCGImage = nil }
    }
    var beautifyBackgroundBlur: CGFloat = UserDefaults.standard.object(forKey: "beautifyBgBlur") as? CGFloat ?? 0 {
        didSet {
            cachedBeautifyBgCGImage = nil
            prepareBeautifyBackgroundCache()
        }
    }
    var cachedBeautifyBgCGImage: CGImage?

    func prepareBeautifyBackgroundCache() {
        guard let bg = customBeautifyBackground else { return }
        var cfg = BeautifyConfig(customBackgroundImage: bg, backgroundBlur: beautifyBackgroundBlur)
        cfg.prepareBackgroundCache()
        cachedBeautifyBgCGImage = cfg.cachedBackgroundCGImage
    }

    /// Load the custom beautify background from UserDefaults if the custom style
    /// is selected but the image isn't in memory yet. MUST be called explicitly
    /// (not from the `beautifyConfig` getter) — a getter that mutates state caused
    /// the editor's "Save changes?" prompt to fire on reopen even with no edits,
    /// because the lazy load changed `customBeautifyBackground` after the editor's
    /// clean-state signature was captured. Safe to call repeatedly.
    func ensureCustomBeautifyBackgroundLoaded() {
        guard beautifyStyleIndex == -1, customBeautifyBackground == nil else { return }
        if let data = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
           let img = NSImage(data: data) {
            customBeautifyBackground = img
            prepareBeautifyBackgroundCache()
        }
    }

    var beautifyConfig: BeautifyConfig {
        return BeautifyConfig(
            mode: beautifyMode,
            styleIndex: beautifyStyleIndex,
            padding: beautifyPadding,
            cornerRadius: beautifyCornerRadius,
            shadowRadius: beautifyShadowRadius,
            bgRadius: 0,
            isWindowSnap: selectionIsWindowSnap,
            customBackgroundImage: beautifyStyleIndex == -1 ? customBeautifyBackground : nil,
            backgroundBlur: beautifyBackgroundBlur,
            cachedBackgroundCGImage: beautifyStyleIndex == -1 ? cachedBeautifyBgCGImage : nil
        )
    }

    var showBeautifyInOptionsRow: Bool = false
    /// V3 capture bar "标注" mode: show the annotation strip + options row.
    var annotationToolsVisible = true

    // Image effects
    var effectsPreset: ImageEffectPreset =
        ImageEffectPreset(rawValue: UserDefaults.standard.integer(forKey: "effectsPreset")) ?? .none
    var effectsBrightness: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsBrightness") as? Double
        return v != nil ? Float(v!) : 0
    }()
    var effectsContrast: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsContrast") as? Double
        return v != nil ? Float(v!) : 1.0
    }()
    var effectsSaturation: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsSaturation") as? Double
        return v != nil ? Float(v!) : 1.0
    }()
    var effectsSharpness: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsSharpness") as? Double
        return v != nil ? Float(v!) : 0
    }()

    var effectsConfig: ImageEffectsConfig {
        ImageEffectsConfig(
            preset: effectsPreset,
            brightness: effectsBrightness,
            contrast: effectsContrast,
            saturation: effectsSaturation,
            sharpness: effectsSharpness
        )
    }
    var effectsActive: Bool { !effectsConfig.isIdentity }

    /// Cached effects-processed screenshot for live preview. Invalidated when effects or annotations change.
    var cachedEffectsScreenshot: NSImage?

    // Color picker target
    enum ColorPickerTarget { case drawColor, textBg, textOutline, textGlyphStroke, annotationOutline, loupeOutline }
    var colorPickerTarget: ColorPickerTarget = .drawColor

    // Beautify toolbar animation
    var beautifyToolbarAnimProgress: CGFloat = 1.0  // 0..1, 1 = fully settled
    var beautifyToolbarAnimTimer: Timer?
    var beautifyToolbarAnimTarget: Bool = false  // target beautify state

    // Tool options row (second row below bottom bar)
    var currentMeasureInPoints: Bool = UserDefaults.standard.bool(forKey: "measureInPoints")
    // Default ON: measuring outside the capture area is almost always an accident (#212)
    var currentMeasureClampToSelection: Bool = UserDefaults.standard.object(forKey: "measureClampToSelection") as? Bool ?? true
    var currentLineStyle: LineStyle =
        LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
    var currentArrowStyle: ArrowStyle =
        ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle")) ?? .single
    var arrowReversed: Bool =
        UserDefaults.standard.bool(forKey: "arrowReversed")
    var currentRectFillStyle: RectFillStyle =
        RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle"))
        ?? .stroke
    var currentStampImage: NSImage?  // selected emoji/image for stamp tool
    var currentStampEmoji: String?  // emoji string for highlight tracking
    var currentStampSize: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "stampSize") as? Double
        return v != nil ? CGFloat(v!) : 64
    }()
    var stampPreviewPoint: NSPoint?  // mouse position for stamp cursor preview
    var currentRectCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 0
    }()

    // Stroke width picker popover

    var pencilSmoothMode: Int = {
        // Migrate old bool to new mode: true → 1 (Smooth), false → 0 (None)
        if let old = UserDefaults.standard.object(forKey: "pencilSmoothEnabled") as? Bool {
            UserDefaults.standard.removeObject(forKey: "pencilSmoothEnabled")
            let mode = old ? 1 : 0
            UserDefaults.standard.set(mode, forKey: "pencilSmoothMode")
            return mode
        }
        return UserDefaults.standard.object(forKey: "pencilSmoothMode") as? Int ?? 1
    }()
    var pencilPressureEnabled: Bool =
        UserDefaults.standard.object(forKey: "pencilPressureEnabled") as? Bool ?? false
    var currentPressure: CGFloat = 1.0
    var smartMarkerEnabled: Bool =
        UserDefaults.standard.object(forKey: "smartMarkerEnabled") as? Bool ?? false {
        didSet { if !smartMarkerEnabled { (toolHandlers[.marker] as? MarkerToolHandler)?.reset() } }
    }


    var currentLoupeSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "loupeSize") as? Double
        return saved != nil ? CGFloat(saved!) : 120.0
    }()
    var currentLoupeMagnification: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "loupeMagnification") as? Double
        return saved != nil ? CGFloat(saved!) : 2.0
    }()
    var currentLoupeOutlineColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "loupeOutlineColor"),
           let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return c
        }
        return .systemRed
    }()
    var currentLoupeOutlineEnabled: Bool =
        UserDefaults.standard.object(forKey: "loupeOutlineEnabled") as? Bool ?? false
    var loupeCursorPoint: NSPoint = .zero
    var drawingCursorPoint: NSPoint = .zero
    var smartMarkerLineHeight: CGFloat?  // detected text line height at cursor (smart marker)
    var colorSamplerPoint: NSPoint = .zero  // canvas space, for color picker tool
    var colorSamplerBitmap: NSBitmapImageRep?  // cached bitmap for fast pixel sampling
    // Auto-measure preview (live while holding 1 or 2 key)
    var autoMeasurePreview: Annotation?  // temporary, drawn but not in annotations[]
    var autoMeasureVertical: Bool = true  // true = "1" key, false = "2" key
    var autoMeasureKeyHeld: Bool = false  // true while 1 or 2 is held down
    var autoMeasureBitmapCtx: CGContext?  // cached pixel data for fast scanning
    var autoMeasureBitmapW: Int = 0
    var autoMeasureBitmapH: Int = 0
    // Snap/alignment guides
    var snapGuideX: CGFloat? = nil  // vertical guide line X
    var snapGuideY: CGFloat? = nil  // horizontal guide line Y
    let snapThreshold: CGFloat = 5
    var snapGuidesEnabled: Bool {
        UserDefaults.standard.object(forKey: "snapGuidesEnabled") as? Bool ?? true
    }
    var selectionOutsideShadowDisabled: Bool {
        UserDefaults.standard.bool(forKey: "disableSelectionOutsideShadow")
    }
    var tooltipShortcutDisplayEnabled: Bool {
        UserDefaults.standard.bool(forKey: "showToolShortcutsInTooltips")
    }

    var cachedCompositedImage: NSImage? = nil {  // invalidated when annotations change
        didSet { if !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation { cachedAnnotationLayer = nil } }
    }
    /// Cached transparent image of committed annotations only (no screenshot).
    /// Drawn with applyCanvasTransform so zoom works correctly. Invalidated alongside cachedCompositedImage.
    var cachedAnnotationLayer: NSImage? = nil
    /// During drag/resize, this holds a cache of all annotations EXCEPT the ones being manipulated.
    var cachedAnnotationLayerExcludingSelected: NSImage? = nil
    var cachedOpaqueRect: NSRect?  // cached opaque content bounds of screenshotImage

    var isTranslating: Bool = false
    var translateEnabled: Bool = false {
        didSet { if !translateEnabled { translationRecognition.cancel(); isTranslating = false } }
    }

    // Crop tool state
    var isCropDragging: Bool = false
    var cropDragStart: NSPoint = .zero
    var cropDragRect: NSRect = .zero

    // Annotation selection/resize controls
    var isResizingAnnotation: Bool = false
    var annotationResizeHandle: ResizeHandle = .none
    var annotationResizeAnchorIndex: Int = -1  // index into anchorPoints for multi-anchor drag
    var isRotatingAnnotation: Bool = false
    var rotationStartAngle: CGFloat = 0
    var rotationOriginal: CGFloat = 0
    var annotationRotateHandleRect: NSRect = .zero
    var annotationResizeOrigStart: NSPoint = .zero
    var annotationResizeOrigEnd: NSPoint = .zero
    var annotationResizeOrigTextOrigin: NSPoint = .zero
    var annotationResizeOrigControlPoint: NSPoint = .zero
    var annotationResizeMouseStart: NSPoint = .zero
    var annotationDeleteButtonRect: NSRect = .zero
    var annotationEditButtonRect: NSRect = .zero
    /// Resize handle on a two-circle loupe's SOURCE circle (.zero when none).
    var loupeSourceHandleRect: NSRect = .zero
    var annotationResizeHandleRects: [(ResizeHandle, NSRect)] = []
    var multiSelectDeleteButtonRect: NSRect = .zero  // consolidated delete for multi-selection

    // Overlay error message
    var overlayErrorMessage: String? = nil

    // Instant tooltip for hovered toolbar button
    var hoveredTooltip: String?
    var hoveredTooltipButtonView: ToolbarButtonView?
    var isToolbarMoveDragActive = false
    var isKeyboardMoveSelectionActive = false
    var keyboardMoveSelectionOffset: NSPoint = .zero
    var keyboardMoveSelectionShortcut: String = ""

    var currentCanvasMousePoint: NSPoint? {
        guard let windowPoint = window?.mouseLocationOutsideOfEventStream else { return nil }
        return viewToCanvas(convert(windowPoint, from: nil))
    }
    var editorTooltipView: NSView?
    var overlayErrorTimer: Timer? = nil

    // Recording state
    var isRecording: Bool = false {  // true when recording toolbar is shown (pre-recording setup)
        didSet {
            if isRecording {
                // Clear drawing previews so they don't linger from screenshot mode
                commitTextFieldIfNeeded()
                stampPreviewPoint = nil
                loupeCursorPoint = .zero
                drawingCursorPoint = .zero
                autoMeasurePreview = nil
                hoveredAnnotation = nil
                selectedAnnotation = nil
                needsDisplay = true
                // Pre-check Input Monitoring permission if keystroke overlay is enabled
                if UserDefaults.standard.bool(forKey: "recordKeystroke") && !KeystrokeOverlay.hasInputMonitoringPermission {
                    UserDefaults.standard.set(false, forKey: "recordKeystroke")
                    rebuildToolbarLayout()
                    overlayDelegate?.overlayViewDidRequestInputMonitoringPermission()
                }

                // Pre-check mic + camera permissions sequentially so dialogs don't overlap
                preCheckRecordingPermissions()
            } else {
                stopMicLevelMonitor()
                dismissWebcamSetupPreview()
            }
        }
    }
    var autoEnterRecordingMode: Bool = false  // set by "Record Screen" menu — enters recording mode after selection
    var autoOCRMode: Bool = false  // set by "Capture OCR & QR" menu — triggers OCR immediately after selection
    var autoTranslateOverlayMode: Bool = false  // set by macshot://ocr-translate — OCR + translate + overlay after selection
    var autoTranslateOverlayLang: String?  // target language for autoTranslateOverlayMode (nil = saved default)
    var autoQuickSaveMode: Bool = false  // set by "Quick Capture" menu — quick-saves immediately after selection
    var autoScrollCaptureMode: Bool = false  // set by "Scroll Capture" menu — triggers scroll capture immediately after selection
    var autoConfirmMode: Bool = false  // set by "Add Capture" — auto-confirms selection (no toolbars, no save)

    // Recording session overrides (popover settings — nil means use UserDefaults default)
    var sessionRecordingFPS: Int?
    var sessionRecordingOnStop: String?
    var sessionRecordingDelay: Int?
    var sessionHideRecordingHUD: Bool?

    // Scroll capture state
    var isScrollCapturing: Bool = false
    var scrollCaptureStripCount: Int = 0
    var scrollCapturePixelSize: CGSize = .zero
    var scrollCaptureMaxHeight: Int = 0
    var scrollCaptureAutoScrolling: Bool = false
    var scrollCaptureHUDPanel: ScrollCaptureHUDPanel?
    var scrollCaptureMouseTap: CFMachPort?
    var scrollCaptureMouseTapSource: CFRunLoopSource?
    var scrollCaptureKeyMonitor: Any?
    var scrollCaptureLocalKeyMonitor: Any?
    /// Activate the app visible under the selection rect so the user doesn't need a warmup click.
    func activateAppUnderSelection() {
        guard selectionRect.width > 0, let win = window else { return }
        // Convert selection center to global screen coords
        let centerLocal = NSPoint(x: selectionRect.midX, y: selectionRect.midY)
        let centerScreen = win.convertToScreen(NSRect(origin: centerLocal, size: .zero)).origin

        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return }

        let overlayWindowNumber = win.windowNumber
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let winNum = info[kCGWindowNumber as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                winNum != overlayWindowNumber
            else { continue }

            let cgX = boundsDict["X"] ?? 0
            let cgY = boundsDict["Y"] ?? 0
            let cgW = boundsDict["Width"] ?? 0
            let cgH = boundsDict["Height"] ?? 0
            let appKitRect = NSRect(x: cgX, y: screenH - cgY - cgH, width: cgW, height: cgH)

            if appKitRect.contains(centerScreen) {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                return
            }
        }
    }

    func startScrollCaptureMode() {
        isScrollCapturing = true
        updateResolutionBox()  // hide the box during scroll capture
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero
        scrollCaptureAutoScrolling = false

        activateAppUnderSelection()
        window?.ignoresMouseEvents = true

        // Suppress mouse-moved events via CGEvent tap so hover effects in the
        // target app don't break stitch detection. Requires Accessibility permission
        // (checked before entering scroll capture mode).
        if AXIsProcessTrusted() {
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
                callback: { _, _, _, _ in nil },
                userInfo: nil)
            if let tap = tap {
                let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                scrollCaptureMouseTap = tap
                scrollCaptureMouseTapSource = source
            }
        }

        // Escape key monitor — global catches when another app has focus; local when macshot has focus.
        let handleScrollKey: (NSEvent) -> Void = { [weak self] event in
            guard let self = self, self.isScrollCapturing else { return }
            if event.keyCode == 53 {  // Escape
                self.overlayDelegate?.overlayViewDidRequestStopScrollCapture()
            }
        }
        scrollCaptureKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handleScrollKey(event)
        }
        scrollCaptureLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleScrollKey(event)
            if event.keyCode == 53 { return nil }  // consume
            return event
        }

        // Show real NSPanel-based HUD (receives clicks independently of overlay window)
        let panel = ScrollCaptureHUDPanel()
        panel.hudView.onStop = { [weak self] in
            self?.overlayDelegate?.overlayViewDidRequestStopScrollCapture()
        }
        panel.hudView.onToggleAutoScroll = { [weak self] in
            self?.overlayDelegate?.overlayViewDidRequestToggleAutoScroll()
        }
        panel.hudView.update(
            stripCount: 0, pixelSize: .zero,
            backingScale: window?.backingScaleFactor ?? 2,
            maxScrollHeight: scrollCaptureMaxHeight,
            autoScrolling: scrollCaptureAutoScrolling)
        if let win = window {
            panel.position(relativeTo: selectionRect, in: win)
        }
        panel.orderFront(nil)
        scrollCaptureHUDPanel = panel

        needsDisplay = true
    }

    func stopScrollCaptureMode() {
        isScrollCapturing = false
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero
        scrollCaptureAutoScrolling = false

        if let m = scrollCaptureKeyMonitor { NSEvent.removeMonitor(m); scrollCaptureKeyMonitor = nil }
        if let m = scrollCaptureLocalKeyMonitor { NSEvent.removeMonitor(m); scrollCaptureLocalKeyMonitor = nil }
        if let tap = scrollCaptureMouseTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = scrollCaptureMouseTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            scrollCaptureMouseTap = nil
            scrollCaptureMouseTapSource = nil
        }
        scrollCaptureHUDPanel?.close()
        scrollCaptureHUDPanel = nil
        window?.ignoresMouseEvents = false

        needsDisplay = true
    }

    /// Update the scroll capture HUD with new strip count and pixel size.
    func updateScrollCaptureHUD() {
        scrollCaptureHUDPanel?.hudView.update(
            stripCount: scrollCaptureStripCount,
            pixelSize: scrollCapturePixelSize,
            backingScale: window?.backingScaleFactor ?? 2,
            maxScrollHeight: scrollCaptureMaxHeight,
            autoScrolling: scrollCaptureAutoScrolling)
        if let win = window {
            scrollCaptureHUDPanel?.position(relativeTo: selectionRect, in: win)
        }
    }

    // Window snapping
    var windowSnapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "windowSnapEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "windowSnapEnabled") }
    }

    // Boundary snapping — snap the selection's dragged edges to strong color
    // edges in the captured image (UI lines, window borders, etc.). Off by
    // default. Hold Option while dragging to bypass.
    var boundarySnapEnabled: Bool {
        UserDefaults.standard.object(forKey: "boundarySnapEnabled") as? Bool ?? true
    }
    var boundarySnapIndex: BoundarySnapIndex?
    var boundarySnapBuildGeneration = 0
    /// Snap radius in overlay points.
    let boundarySnapRadiusPoints: CGFloat = 4
    /// Overlay-space coordinates of the active snapped edge(s), for the guide
    /// line feedback. nil when not snapping that axis.
    var boundarySnapGuideX: CGFloat?
    var boundarySnapGuideY: CGFloat?
    var hoveredWindowRect: NSRect? = nil
    var hoveredWindowID: CGWindowID? = nil
    var windowSnapCooldown: Bool = true  // true until overlay has rendered
    /// True when the current selection was made via window snap (click without drag).
    /// Cleared when the user manually resizes the selection.
    var selectionIsWindowSnap: Bool = false
    /// Locked aspect ratio (width / height) for the selection, or nil for freeform.
    /// When set, drag-resize and the resolution box maintain this ratio.
    var lockedAspect: CGFloat? = nil
    /// When true, the locked aspect ratio persists across captures (and launches).
    /// Stored in UserDefaults so a new selection starts already constrained.
    var keepRatioForNextCaptures: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAspectRatio") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAspectRatio") }
    }
    /// The persisted ratio value. Zero means freeform/no locked ratio.
    var persistedAspect: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "keepAspectRatioValue")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "keepAspectRatioValue") }
    }
    enum PreSelectionPreset {
        case freeform
        case ratio(CGFloat)
        case resolution(w: Int, h: Int)
    }
    enum PreSelectionPresetStorageKind: Int {
        case inherited = 0
        case freeform = 1
        case ratio = 2
        case resolution = 3
    }
    static let preSelectionPresetKindKey = "preSelectionResolutionPresetKind"
    static let preSelectionPresetAspectKey = "preSelectionResolutionPresetAspect"
    static let preSelectionPresetWidthKey = "preSelectionResolutionPresetWidth"
    static let preSelectionPresetHeightKey = "preSelectionResolutionPresetHeight"
    var snappedWindowID: CGWindowID? = nil
    /// Independently captured window image (with transparent corners) for beautify snap mode.
    var snappedWindowImage: NSImage? = nil
    var windowSnapQueryInFlight: Bool = false

    /// Perform a window snap query at the given screen point (AppKit screen coordinates).
    func queryWindowSnap(at screenPoint: NSPoint) {
        guard !windowSnapQueryInFlight,
            state == .idle && windowSnapEnabled,
            !(remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1),
            let viewWindow = window
        else { return }
        let overlayWindowNumber = viewWindow.windowNumber
        let windowOrigin = viewWindow.frame.origin
        let viewBounds = bounds
        let screenH = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        windowSnapQueryInFlight = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = Self.windowRectOnBackground(
                screenPoint: screenPoint,
                overlayWindowNumber: overlayWindowNumber,
                windowOrigin: windowOrigin,
                viewBounds: viewBounds,
                screenH: screenH
            )
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.windowSnapQueryInFlight = false
                let newRect = result?.rect
                if newRect != self.hoveredWindowRect {
                    self.hoveredWindowRect = newRect
                    self.hoveredWindowID = result?.windowID
                    self.needsDisplay = true
                }
            }
        }
    }

    // Mic level monitor (volume meter shown when mic is enabled before recording)
    var micLevelEngine: AVAudioEngine?
    var micLevelTimer: Timer?

    var customColors: [NSColor?] = Array(repeating: nil, count: 7)
    var selectedColorSlot: Int = 0  // which custom slot is selected for saving colors
    static var lastUsedOpacity: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "lastUsedColorOpacity") as? Double
        return saved != nil ? CGFloat(saved!) : 1.0
    }()
    var currentColorOpacity: CGFloat = OverlayView.lastUsedOpacity

    // Radial color wheel (right-click in drawing mode)
    let colorWheel = ColorWheelRenderer()

    // Webcam setup preview (shown during recording setup when webcam is enabled)
    var webcamSetupPreview: WebcamOverlay?

    // Handle
    let handleSize: CGFloat = 10

    enum ResizeHandle {
        case none
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case move
    }

    // MARK: - Setup

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)

        // Don't run the initial snap query here — it fires before the screenshot
        // arrives (async capture). The snap query is triggered when screenshotImage
        // is set (via didSet → needsDisplay → mouseMoved), or we kick it off
        // explicitly in the screenshotImage setter below.
        // Skip cooldown in editor mode — screenshotImage is set before the view
        // moves to the window, so the didSet won't clear it. Window snap is
        // irrelevant in editor anyway.
        if !isEditorMode {
            windowSnapCooldown = true
        }

        // viewDidMoveToWindow fires again every time a pooled overlay is reused,
        // so remove first — otherwise handleToolbarColorsChanged (which rebuilds
        // the whole toolbar) ends up running once per past capture.
        NotificationCenter.default.removeObserver(
            self, name: .toolbarColorsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToolbarColorsChanged),
            name: .toolbarColorsDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func handleToolbarColorsChanged() {
        // Rebuild toolbars and options row with new colors.
        if let row = toolOptionsRowView {
            row.layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        }
        toolOptionsRowView?.appearance = ToolbarLayout.appearance
        rebuildToolbarLayout()
        if let tool = toolOptionsRowView?.currentTool {
            toolOptionsRowView?.rebuild(for: tool)
        }
        needsDisplay = true
    }

    /// Invalidate only the rect around a cursor preview (old + new position) instead of the whole view.
    func invalidateCursorPreview(oldCanvas: NSPoint, newCanvas: NSPoint, radius: CGFloat) {
        let margin: CGFloat = 4
        // Scale canvas-space radius to view-space pixels (zoom factor)
        let r = (radius + margin) * zoomLevel
        if oldCanvas != .zero {
            let oldView = canvasToView(oldCanvas)
            setNeedsDisplay(NSRect(x: oldView.x - r, y: oldView.y - r, width: r * 2, height: r * 2))
        }
        guard newCanvas != .zero else { return }
        let newView = canvasToView(newCanvas)
        setNeedsDisplay(NSRect(x: newView.x - r, y: newView.y - r, width: r * 2, height: r * 2))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Anchored selection (right-click in idle → track cursor without
        // holding a button). Shares all modifier behaviour with drag-based
        // selection via `updateAnchoredSelection` so Shift-constrain and
        // the snap fallback in mouseUp still apply when the user commits.
        if isAnchoredSelecting {
            updateAnchoredSelection(to: point, event: event)
            updateCursorForPoint(point)
            return
        }

        if isKeyboardMoveSelectionActive {
            updateKeyboardMoveSelection(to: point, modifiers: event.modifierFlags)
            updateCursorForPoint(point)
            return
        }

        // Sticky color wheel: track hover with mouse movement
        if colorWheel.isVisible && colorWheel.isSticky {
            colorWheel.updateHover(at: point)
            needsDisplay = true
            return
        }

        // Stamp cursor preview — track in view coords (same as annotations)
        if currentTool == .stamp && currentStampImage != nil && state == .selected && !isRecording
            && !showBeautifyInOptionsRow
        {
            let canvasStampPt = viewToCanvas(point)
            let hoveringStamp = annotations.reversed().contains {
                $0.tool == .stamp && $0.hitTest(point: canvasStampPt)
            }
            let previewPoint: NSPoint? = hoveringStamp ? nil : canvasStampPt
            let shouldMovePreview: Bool
            if let previewPoint, let stampPreviewPoint {
                shouldMovePreview = hypot(
                    previewPoint.x - stampPreviewPoint.x,
                    previewPoint.y - stampPreviewPoint.y) > 0.5
            } else {
                shouldMovePreview = previewPoint != stampPreviewPoint
            }
            if shouldMovePreview {
                let oldPt = stampPreviewPoint ?? .zero
                stampPreviewPoint = previewPoint
                // Radius must cover the drawn preview (centered, max side = currentStampSize)
                invalidateCursorPreview(
                    oldCanvas: oldPt, newCanvas: previewPoint ?? .zero,
                    radius: max(40, currentStampSize / 2))
            }
        } else if stampPreviewPoint != nil {
            let oldPt = stampPreviewPoint!
            stampPreviewPoint = nil
            invalidateCursorPreview(
                oldCanvas: oldPt, newCanvas: oldPt, radius: max(40, currentStampSize / 2))
        }

        // Update cursor on every mouse move
        updateCursorForPoint(point)

        // Auto-measure: update preview as cursor moves while key is held
        if autoMeasureKeyHeld {
            updateAutoMeasurePreview()
        }

        // Window snap: highlight hovered window in idle state.
        // CGWindowListCopyWindowInfo is expensive — run it on a background thread,
        // skipping new queries while one is already in flight.
        // Delay window snap queries briefly after overlay appears so the overlay
        // renders without competing with CGWindowListCopyWindowInfo for the window server
        if windowSnapCooldown { return }
        if state == .idle && windowSnapEnabled && !windowSnapQueryInFlight
            && !(remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1)
        {
            guard
                let screenPoint = window.map({
                    NSPoint(x: $0.frame.origin.x + point.x, y: $0.frame.origin.y + point.y)
                })
            else { return }
            queryWindowSnap(at: screenPoint)
        }

        // Track cursor for loupe live preview (use canvas space for zoom correctness)
        if state == .selected && currentTool == .loupe && !isRecording && !showBeautifyInOptionsRow {
            let canvasPoint = viewToCanvas(point)
            let hoveringLoupe = annotations.reversed().contains {
                $0.tool == .loupe && $0.hitTest(point: canvasPoint)
            }
            let newPoint = hoveringLoupe ? NSPoint.zero : canvasPoint
            if newPoint != loupeCursorPoint {
                let oldPt = loupeCursorPoint
                loupeCursorPoint = newPoint
                let r = currentLoupeSize / 2 + 4
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: newPoint, radius: r)
            }
        }

        // Track cursor for pencil/marker dot preview (canvas space so it scales with zoom)
        let showDrawingCursor = state == .selected && !isRecording
            && (currentTool == .pencil || currentTool == .marker)
        if showDrawingCursor {
            let canvasPoint = viewToCanvas(point)
            if canvasPoint != drawingCursorPoint {
                let oldPt = drawingCursorPoint
                let oldR = drawingCursorRadius
                drawingCursorPoint = canvasPoint
                // Smart marker: query line height at cursor and update preview size
                if currentTool == .marker && smartMarkerEnabled {
                    if let handler = toolHandlers[.marker] as? MarkerToolHandler {
                        handler.ensureOCRCache(canvas: self)
                        smartMarkerLineHeight = handler.textLineHeight(at: canvasPoint, canvas: self)
                    }
                }
                // Invalidate both old and new positions with the larger radius
                let newR = drawingCursorRadius
                let r = max(oldR, newR) + 4
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: canvasPoint, radius: r)
            }
        } else if drawingCursorPoint != .zero {
            let oldPt = drawingCursorPoint
            let r = drawingCursorRadius + 4
            drawingCursorPoint = .zero
            smartMarkerLineHeight = nil
            invalidateCursorPreview(oldCanvas: oldPt, newCanvas: oldPt, radius: r)
        }

        // Track cursor for color sampler tool (canvas space)
        if state == .selected && currentTool == .colorSampler && !isRecording {
            let canvasPoint = viewToCanvas(point)
            if canvasPoint != colorSamplerPoint {
                let oldPt = colorSamplerPoint
                colorSamplerPoint = canvasPoint
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: canvasPoint, radius: 200)
            }
        } else if colorSamplerPoint != .zero {
            let oldPt = colorSamplerPoint
            colorSamplerPoint = .zero
            colorSamplerBitmap = nil
            invalidateCursorPreview(oldCanvas: oldPt, newCanvas: oldPt, radius: 200)
        }

        // Toolbar hover handled by ToolbarButtonView (real NSView subviews)
    }

    // Custom cursors
    /// Transparent 1x1 cursor used to hide the system cursor while the drawing dot preview is shown.
    static let invisibleCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    // Diagonal resize cursors (macOS doesn't provide these publicly)
    static let nwseCursor: NSCursor = {
        // Top-left <-> Bottom-right (backslash direction)
        if let cursor = NSCursor.perform(
            NSSelectorFromString("_windowResizeNorthWestSouthEastCursor"))?.takeUnretainedValue()
            as? NSCursor
        {
            return cursor
        }
        return .crosshair
    }()

    static let neswCursor: NSCursor = {
        // Top-right <-> Bottom-left (slash direction)
        if let cursor = NSCursor.perform(
            NSSelectorFromString("_windowResizeNorthEastSouthWestCursor"))?.takeUnretainedValue()
            as? NSCursor
        {
            return cursor
        }
        return .crosshair
    }()

    override func cursorUpdate(with event: NSEvent) {
        // Intentionally empty — cursor management is handled imperatively in mouseMoved
        // via updateCursorForPoint(). Overriding prevents AppKit's default cursorUpdate
        // from resetting our custom cursors.
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !isEditorMode && !isScrollCapturing && !isRecording && (state == .idle || state == .selecting) {
            addCursorRect(bounds, cursor: .crosshair)
            if preSelectionPresetButton?.isHidden == false && preSelectionPresetButtonRect.width > 1 {
                addCursorRect(preSelectionPresetButtonRect, cursor: .arrow)
            }
        }
    }

    /// Imperative cursor management. Called from mouseMoved and a 30fps timer.
    /// Simplified: arrow for chrome, resize cursors for handles, tool cursor for canvas.
    func updateCursorForPoint(_ point: NSPoint) {
        // Arrow cursor when mouse is over an open popover
        if PopoverHelper.isMouseInsidePopover {
            NSCursor.arrow.set()
            return
        }

        // Over the resolution box: let its own cursor rects (I-beam over fields,
        // arrow over the presets button) decide — don't override here.
        if resolutionBoxRect != .zero && resolutionBoxRect.contains(point) {
            return
        }
        if preSelectionPresetButton?.isHidden == false && preSelectionPresetButtonRect.contains(point) {
            NSCursor.arrow.set()
            return
        }

        // Non-interactive states — simple cursors
        if textEditView != nil {
            NSCursor.arrow.set()
            return
        }
        if state == .idle || state == .selecting {
            // Recording mode: arrow cursor (no selection interaction)
            if isRecording {
                NSCursor.arrow.set()
                return
            }
            // Show resize cursor for remote selection handles
            if state == .idle && remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
                let remoteHandle = hitTestRemoteHandle(at: point)
                if remoteHandle != .none {
                    cursorForHandle(remoteHandle).set()
                    return
                }
            }
            NSCursor.crosshair.set()
            return
        }
        guard state == .selected else { return }

        // Chrome areas — arrow
        if isPointOnChrome(point) {
            NSCursor.arrow.set()
            return
        }

        // Selection resize handles (overlay only, not during scroll capture)
        if !isEditorMode && !isScrollCapturing, let handleCursor = resizeHandleCursor(at: point) {
            handleCursor.set()
            return
        }

        // Annotation control cursors (resize handles, rotation, delete, body)
        if state == .selected && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
            // Check selected annotation's handles first
            if selectedAnnotation != nil {
                // Unrotate point for handle hit test
                let handlePoint: NSPoint
                if let ann = selectedAnnotation, ann.rotation != 0 && ann.supportsRotation {
                    let center = NSPoint(x: ann.boundingRect.midX, y: ann.boundingRect.midY)
                    let cos_r = cos(-ann.rotation)
                    let sin_r = sin(-ann.rotation)
                    let dx = point.x - center.x
                    let dy = point.y - center.y
                    handlePoint = NSPoint(x: center.x + dx * cos_r - dy * sin_r,
                                          y: center.y + dx * sin_r + dy * cos_r)
                } else {
                    handlePoint = point
                }

                // Resize handles — directional cursors for shapes, open hand for line/arrow points
                let isShapeTool = [AnnotationTool.rectangle, .filledRectangle, .ellipse, .text,
                                   .pixelate, .stamp, .loupe, .highlight].contains(selectedAnnotation?.tool)
                for (_, handleEntry) in annotationResizeHandleRects.enumerated() {
                    let (handle, rect) = handleEntry
                    if rect.insetBy(dx: -4, dy: -4).contains(handlePoint) {
                        if isShapeTool {
                            switch handle {
                            case .topLeft, .bottomRight: Self.nwseCursor.set()
                            case .topRight, .bottomLeft: Self.neswCursor.set()
                            case .top, .bottom: NSCursor.resizeUpDown.set()
                            case .left, .right: NSCursor.resizeLeftRight.set()
                            default: NSCursor.openHand.set()
                            }
                        } else {
                            NSCursor.openHand.set()
                        }
                        return
                    }
                }

                // Rotation handle
                if annotationRotateHandleRect != .zero
                    && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point) {
                    // Use a rotation-style cursor (crosshair works as a generic grab indicator)
                    NSCursor.openHand.set()
                    return
                }

                // Delete button
                if annotationDeleteButtonRect.contains(point) {
                    NSCursor.arrow.set()
                    return
                }

                // Edit button
                if annotationEditButtonRect != .zero && annotationEditButtonRect.contains(point) {
                    NSCursor.arrow.set()
                    return
                }
            }

            // Multi-select delete button
            if selectedAnnotations.count > 1 && multiSelectDeleteButtonRect.contains(point) {
                NSCursor.arrow.set()
                return
            }

            // Body hover — open hand (skip for pencil/marker where click always draws)
            if currentTool != .pencil && currentTool != .marker {
                let canvasPoint = viewToCanvas(point)
                if let selected = selectedAnnotation, selected.hitTest(point: canvasPoint) {
                    NSCursor.openHand.set()
                    return
                }
                if annotations.reversed().contains(where: { $0.isMovable && $0.hitTest(point: canvasPoint) }) {
                    NSCursor.openHand.set()
                    return
                }
            }
        }

        // Tool cursor — use handler's state-aware cursor if available, else legacy switch
        // Pencil/marker: hide system cursor when dot preview is active (the dot IS the cursor)
        if (currentTool == .pencil || currentTool == .marker)
            && state == .selected && drawingCursorPoint != .zero {
            Self.invisibleCursor.set()
        } else if let handler = toolHandlers[currentTool], let cursor = handler.cursorForCanvas(self) {
            cursor.set()
        } else {
            switch currentTool {
            case .select: NSCursor.arrow.set()
            default: NSCursor.crosshair.set()
            }
        }
    }

    /// Re-evaluate the cursor for the current tool (e.g. after toggling smart marker).
    /// Find the editor chrome (for updating zoom label from keyboard shortcuts).
    func findTopBar() -> EditorChromeView? {
        chromeParentView as? EditorChromeView
    }

    func updateCursorForCurrentTool() {
        guard let win = window else { return }
        let point = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        updateCursorForPoint(point)
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let real NSView subviews (toolbar strips, options row) handle their own events.
        // This prevents our mouseDown override from intercepting slider drags etc.
        // In editor mode the strips live in chromeParentView (a sibling container), not in
        // this view — AppKit's normal hit testing on the container handles them. Routing them
        // here would compare coordinates in different spaces and cause false matches.
        if !isEditorMode {
            let localPoint = convert(point, from: superview)
            if let strip = bottomStripView, !strip.isHidden, strip.frame.contains(localPoint) {
                return strip.hitTest(convert(point, to: strip.superview))
            }
            if let strip = rightStripView, !strip.isHidden, strip.frame.contains(localPoint) {
                return strip.hitTest(convert(point, to: strip.superview))
            }
            if let row = toolOptionsRowView, !row.isHidden, row.frame.contains(localPoint) {
                return row.hitTest(convert(point, to: row.superview))
            }
        }
        if let event = NSApp.currentEvent, shouldRouteTextEditorDoubleClickToCopy(event: event, at: point) {
            return self
        }
        let result = super.hitTest(point)
        if shouldIgnoreInactiveChromeHit(result) {
            return self
        }
        return result
    }

    /// AppKit's default hitTest can still resolve a mouse-down to a hidden or
    /// inactive toolbar/options subview (the chrome views are pooled and reused
    /// across capture sessions, not destroyed). When that happens the event
    /// never reaches OverlayView.mouseDown, so a new selection drag started over
    /// the *previous* position of now-hidden chrome silently fails. Redirect
    /// those hits back to self. Visible chrome is unaffected. (PR #219)
    func shouldIgnoreInactiveChromeHit(_ view: NSView?) -> Bool {
        guard !isEditorMode, let view, view !== self else { return false }

        var current: NSView? = view
        var hasHiddenAncestor = false
        while let candidate = current, candidate !== self {
            hasHiddenAncestor = hasHiddenAncestor || candidate.isHidden
            if isOverlayChromeRoot(candidate) {
                return !showToolbars || hasHiddenAncestor
            }
            current = candidate.superview
        }
        return false
    }

    func isOverlayChromeRoot(_ view: NSView) -> Bool {
        if let bottomStripView, view === bottomStripView { return true }
        if let rightStripView, view === rightStripView { return true }
        if let toolOptionsRowView, view === toolOptionsRowView { return true }
        if let captureIsland, view === captureIsland { return true }
        return false
    }

    /// Returns true if the point is over any chrome element (toolbars, options row, popovers, labels).
    func isPointOnChrome(_ point: NSPoint) -> Bool {
        // In editor mode, strips are in chromeParentView — different coordinate space.
        // Don't check them here; they handle their own hit testing as container subviews.
        if showToolbars && !isEditorMode {
            // Use the shared OVERLAY-space rects, valid in both themes: in normal
            // mode they equal the strip frames; in glass mode the strips live in
            // panels (frame is panel-local), so the rects are the only truth.
            if bottomStripView?.isHidden == false, bottomBarRect.contains(point) { return true }
            if rightStripView?.isHidden == false, rightBarRect.contains(point) { return true }
            if toolOptionsRowView?.isHidden == false, optionsRowRect.width > 1,
               optionsRowRect.contains(point) { return true }
            if captureIsland?.isHidden == false, islandRect.contains(point) { return true }
        }
        if updateCursorForChrome(at: point) { return true }
        if resolutionBoxRect != .zero && resolutionBoxRect.contains(point) { return true }
        if preSelectionPresetButton?.isHidden == false && preSelectionPresetButtonRect.contains(point) {
            return true
        }
        return false
    }

    /// Returns the appropriate resize cursor if the point is on a selection handle, nil otherwise.
    func resizeHandleCursor(at point: NSPoint) -> NSCursor? {
        let r = selectionRect
        let hs = handleSize + 4
        let edgeT: CGFloat = 6
        // Corner handles
        if NSRect(x: r.minX - hs / 2, y: r.maxY - hs / 2, width: hs, height: hs).contains(point)
            || NSRect(x: r.maxX - hs / 2, y: r.minY - hs / 2, width: hs, height: hs).contains(point)
        {
            return Self.nwseCursor
        }
        if NSRect(x: r.maxX - hs / 2, y: r.maxY - hs / 2, width: hs, height: hs).contains(point)
            || NSRect(x: r.minX - hs / 2, y: r.minY - hs / 2, width: hs, height: hs).contains(point)
        {
            return Self.neswCursor
        }
        // Edge handles
        if NSRect(x: r.minX + hs / 2, y: r.maxY - edgeT / 2, width: r.width - hs, height: edgeT)
            .contains(point)
            || NSRect(x: r.minX + hs / 2, y: r.minY - edgeT / 2, width: r.width - hs, height: edgeT)
                .contains(point)
        {
            return .resizeUpDown
        }
        if NSRect(x: r.minX - edgeT / 2, y: r.minY + hs / 2, width: edgeT, height: r.height - hs)
            .contains(point)
            || NSRect(
                x: r.maxX - edgeT / 2, y: r.minY + hs / 2, width: edgeT, height: r.height - hs
            ).contains(point)
        {
            return .resizeLeftRight
        }
        return nil
    }

    func cursorForHandle(_ handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .topLeft, .bottomRight: return Self.nwseCursor
        case .topRight, .bottomLeft: return Self.neswCursor
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .none, .move: return .arrow
        }
    }

    // MARK: - Subclass override points

    /// Override to handle cursor for editor chrome (top bar). Base returns false.
    func updateCursorForChrome(at point: NSPoint) -> Bool { return false }

    /// Check if a view-space point is within the image/selection area.
    /// In overlay mode, compares directly. In editor mode, converts to canvas space first.
    func pointIsInSelection(_ viewPoint: NSPoint) -> Bool {
        if isEditorMode {
            let canvasPoint = viewToCanvas(viewPoint)
            return selectionRect.contains(canvasPoint)
        }
        return selectionRect.contains(viewPoint)
    }

    /// Override point for editor background drawing. Base does nothing (overlay has no editor background).
    func drawEditorBackground(context: NSGraphicsContext) {
    }

    /// Override to clip the selection image in overlay mode. Base returns true when not in editor mode.
    func shouldClipSelectionImage() -> Bool { !isEditorMode }

    /// Override to control selection border drawing. Base returns true when not in editor mode.
    func shouldDrawSelectionBorder() -> Bool { !isEditorMode }

    /// Override to control size label drawing. Base returns true when not recording/scrolling/editing.
    /// The resolution box shows whenever there's an adjustable selection — including
    /// recording SETUP (isRecording true). When recording actually starts the
    /// overlay is dismissed, so no separate gate is needed for that.
    func shouldShowResolutionBox() -> Bool {
        state == .selected && !isScrollCapturing && !isEditorMode
            && selectionRect.width > 1 && selectionRect.height > 1
    }

    /// Override to draw top chrome (e.g. editor top bar). Base draws editor top bar when in editor mode.    /// Override to adjust a view-space point for editor canvas offset. Base returns point unchanged.
    func adjustPointForEditor(_ p: NSPoint) -> NSPoint { p }

    /// Override point for editor-specific graphics context transform. Base does nothing.
    func applyEditorTransform(to context: NSGraphicsContext) {}

    /// Override to control whether selection resize handles are active. Base returns true when not in editor mode or scroll capturing.
    func shouldAllowSelectionResize() -> Bool { !isEditorMode && !isScrollCapturing }

    /// Override to control whether a new selection can be started. Base returns true when not recording and not in editor mode.
    func shouldAllowNewSelection() -> Bool { !isRecording && !isEditorMode }

    /// Override to change the rect used when drawing the screenshot in `captureSelectedRegion`. Base returns bounds.
    var captureDrawRect: NSRect { isEditorMode ? selectionRect : bounds }

    /// Bounds the spotlight dim is clipped to: only the screenshot SELECTION
    /// region should dim, never the dark area outside it. In editor mode the
    /// drawn region is the whole document (selectionRect); in overlay mode the
    /// selection is a sub-rect of the full-screen overlay.
    var highlightDimBounds: NSRect { isEditorMode ? captureDrawRect : selectionRect }

    /// Override to position toolbars for editor mode. Base pins bottom bar centered at bottom, right bar at top-right.    /// Override to control whether detach (open in editor) is allowed. Base returns true when not in editor mode.
    func shouldAllowDetach() -> Bool { !isEditorMode }

    /// Override to handle clicks on chrome areas. Base returns false.
    func handleTopChromeClick(at point: NSPoint) -> Bool { false }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        timingMark?("OverlayView.draw begin state=\(state) screenshot=\(screenshotImage != nil) dirty=\(Int(dirtyRect.width))x\(Int(dirtyRect.height)) opaque=\(isOpaque)")
        defer {
            timingMark?("OverlayView.draw end")
        }
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current else { return }

        // In editor mode: dark background, draw image centered at natural size (no stretch).
        // selectionRect stays at (0, 0, imgW, imgH) — annotations always use image-relative coords.
        if isEditorMode {
            drawEditorBackground(context: context)
        } else if isScrollCapturing {
            // During scroll capture: make the entire window transparent so the user sees
            // live screen content everywhere (not just inside the selection).
            context.cgContext.clear(bounds)
        } else if !isRecording {
            if let image = screenshotImage {
                // Screenshot ready — draw it with dark overlay
                if !usesExternalScreenshotPreview {
                    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
                }
                if !selectionOutsideShadowDisabled {
                    NSColor.black.withAlphaComponent(0.45).setFill()
                    NSBezierPath(rect: bounds).fill()
                }
            } else {
                // No screenshot yet — fully transparent. User sees live desktop
                // through the overlay and can start selecting immediately.
                context.cgContext.clear(bounds)
            }
        }

        // Window snap highlight (drawn before helper text so text appears on top)
        drawWindowSnapHighlight()
        updateCaptureModeBar()

        // Helper text (capture instructions). Suppressed when the user has
        // enabled "Hide capture instructions" in Settings (issue #226).
        if UserDefaults.standard.bool(forKey: "hideCaptureInstructions") {
            hidePreSelectionPresetButton()
        } else {
            if state == .idle {
                if screenshotImage != nil {
                    drawIdleHelperText()
                } else {
                    hidePreSelectionPresetButton()
                }
            } else if state == .selecting {
                hidePreSelectionPresetButton()
                drawSelectingHelperText()
            } else {
                hidePreSelectionPresetButton()
            }
        }

        // Draw remote selection region (cross-screen drag from another overlay)
        if remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
            if shouldClipSelectionImage() {
                context.saveGraphicsState()
                NSBezierPath(rect: remoteSelectionRect).setClip()
                if usesExternalScreenshotPreview && zoomLevel == 1 {
                    context.cgContext.setBlendMode(.clear)
                    NSBezierPath(rect: remoteSelectionRect).fill()
                } else if let image = screenshotImage {
                    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
                }
                context.restoreGraphicsState()
            }
            // Purple border for remote selection
            let remoteBorder = NSBezierPath(rect: remoteSelectionRect)
            remoteBorder.lineWidth = 2.0
            ToolbarLayout.accentColor.setStroke()
            remoteBorder.stroke()

            // Resize handles for remote selection
            drawRemoteResizeHandles()
        }

        // Draw clear selection region
        if state != .idle && selectionRect.width >= 1 && selectionRect.height >= 1 {
            // During scroll capture: punch a fully-transparent hole so the live screen
            // content underneath shows through the overlay window.
            if isScrollCapturing {
                context.saveGraphicsState()
                context.cgContext.clear(selectionRect)
                context.restoreGraphicsState()
            }

            // Draw screenshot clipped to selection (image never bleeds outside).
            // In editor mode this is already handled by the detached draw block above.
            if shouldClipSelectionImage() {
                context.saveGraphicsState()
                NSBezierPath(rect: selectionRect).setClip()
                if !isScrollCapturing, !isRecording, usesExternalScreenshotPreview, zoomLevel == 1 {
                    context.cgContext.setBlendMode(.clear)
                    NSBezierPath(rect: selectionRect).fill()
                } else if !isScrollCapturing, !isRecording, let image = screenshotImage {
                    applyZoomTransform(to: context)
                    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
                }
                context.restoreGraphicsState()
            }

            // Skip annotation drawing if the editor already drew them via the cached composite.
            let editorDrawnFromCache = (self as? EditorView)?.drewFromCompositeCache ?? false
            let drawingHighlightPreview = currentAnnotation?.tool == .highlight

            if !editorDrawnFromCache {
                // Use cached annotation layer whenever possible — even during active
                // drawing. Committed annotations don't change while a new stroke is
                // being drawn, so re-iterating them every frame wastes CPU and causes
                // event coalescing (fewer mouse events → over-smoothed strokes).
                if !annotations.isEmpty && !isEditorMode {
                    if (isDraggingAnnotation || isResizingAnnotation || isRotatingAnnotation),
                       let staticLayer = cachedAnnotationLayerExcludingSelected {
                        // During drag/resize: draw cached static annotations + selected ones live
                        context.saveGraphicsState()
                        applyCanvasTransform(to: context)
                        staticLayer.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
                        // The static layer skipped the highlight dim; draw it live
                        // here over the union of ALL highlights at their current
                        // (possibly mid-drag) positions, before the selected
                        // annotations' borders.
                        Annotation.drawHighlightDim(for: annotations, in: highlightDimBounds)
                        for annotation in selectedAnnotations {
                            annotation.draw(in: context)
                        }
                    } else if drawingHighlightPreview {
                        // Drawing a NEW highlight: draw only pre-dim effects here.
                        // The live union dim and all annotation borders are drawn
                        // below in final render order so existing highlight borders
                        // do not appear thinner while dragging.
                        context.saveGraphicsState()
                        applyCanvasTransform(to: context)
                        for annotation in annotations where annotation.tool == .pixelate {
                            annotation.draw(in: context)
                        }
                    } else {
                        let layer = annotationLayerImage()
                        context.saveGraphicsState()
                        applyCanvasTransform(to: context)
                        layer.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
                    }
                } else if !annotations.isEmpty {
                    // Editor mode: no annotation layer cache, draw individually.
                    // Draw translate overlays clipped to selection (they must stay inside).
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    NSBezierPath(rect: selectionRect).setClip()
                    for annotation in annotations where annotation.tool == .translateOverlay {
                        annotation.draw(in: context)
                    }
                    context.restoreGraphicsState()

                    // Draw user annotations unclipped — strokes can continue past the selection border.
                    // Censor annotations (pixelate/blur) render first so other annotations
                    // always appear on top of blurred regions.
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    for annotation in annotations where annotation.tool != .translateOverlay && annotation.tool == .pixelate {
                        annotation.draw(in: context)
                    }
                    // Skip the committed-highlight dim while a new highlight is
                    // being drawn — it's drawn live below over the full union
                    // (committed + in-progress) so the existing ones don't get
                    // re-dimmed by the preview pass.
                    if !drawingHighlightPreview {
                        Annotation.drawHighlightDim(for: annotations, in: highlightDimBounds)
                        for annotation in annotations where annotation.tool != .translateOverlay && annotation.tool != .pixelate {
                            annotation.draw(in: context)
                        }
                    }
                } else {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                }
            } else {
                // Still need the canvas transform for active drawing and overlays below
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
            }
            // Live spotlight dim preview while a new highlight is being dragged:
            // dim the union of ALL highlights (committed + the in-progress one) so
            // previously-placed highlights stay bright instead of being re-dimmed.
            if let cur = currentAnnotation, cur.tool == .highlight {
                Annotation.drawHighlightDim(for: annotations, extra: cur, in: highlightDimBounds)
                for annotation in annotations where annotation.tool != .pixelate {
                    if isEditorMode && annotation.tool == .translateOverlay { continue }
                    annotation.draw(in: context)
                }
            }
            currentAnnotation?.draw(in: context)
            autoMeasurePreview?.draw(in: context)

            // Crop selection rectangle preview
            if isCropDragging && cropDragRect.width > 1 && cropDragRect.height > 1 {
                drawCropPreview()

                // Crop border
                NSColor.white.setStroke()
                let cropBorder = NSBezierPath(rect: cropDragRect)
                cropBorder.lineWidth = 1.5
                cropBorder.stroke()

                // Rule of thirds grid
                NSColor.white.withAlphaComponent(0.3).setStroke()
                let thirdW = cropDragRect.width / 3
                let thirdH = cropDragRect.height / 3
                for i in 1...2 {
                    let gridLine = NSBezierPath()
                    gridLine.move(
                        to: NSPoint(
                            x: cropDragRect.minX + thirdW * CGFloat(i), y: cropDragRect.minY))
                    gridLine.line(
                        to: NSPoint(
                            x: cropDragRect.minX + thirdW * CGFloat(i), y: cropDragRect.maxY))
                    gridLine.lineWidth = 0.5
                    gridLine.stroke()
                    let hLine = NSBezierPath()
                    hLine.move(
                        to: NSPoint(
                            x: cropDragRect.minX, y: cropDragRect.minY + thirdH * CGFloat(i)))
                    hLine.line(
                        to: NSPoint(
                            x: cropDragRect.maxX, y: cropDragRect.minY + thirdH * CGFloat(i)))
                    hLine.lineWidth = 0.5
                    hLine.stroke()
                }
            }

            // Live loupe preview when loupe tool is active
            if currentTool == .loupe && selectionRect.contains(loupeCursorPoint)
                && loupeCursorPoint != .zero
            {
                drawLoupePreview(at: loupeCursorPoint)
            }
            if currentTool == .colorSampler && colorSamplerPoint != .zero {
                drawColorSamplerPreview(at: colorSamplerPoint)
            }

            // Draw selection highlight for selected annotations
            // Suppressed during recording so annotations are purely visual overlays.
            if !isRecording {
                for selected in selectedAnnotations {
                    // Only draw full controls (handles, buttons) for single selection
                    drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
                }
                // Consolidated delete button for multi-selection
                drawMultiSelectDeleteButton()
            }

            // Pencil/marker cursor dot preview inside zoom transform so it scales with zoom
            if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
                drawDrawingCursorPreview(at: drawingCursorPoint)
            }

            // Snap alignment guides
            drawSnapGuides()

            // Lasso selection marquee (drawn in canvas space — same as annotations)
            if isLassoSelecting && lassoRect.width > 0 && lassoRect.height > 0 {
                NSColor.systemBlue.withAlphaComponent(0.1).setFill()
                NSBezierPath(rect: lassoRect).fill()
                NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
                let border = NSBezierPath(rect: lassoRect)
                border.lineWidth = 1.0
                let pattern: [CGFloat] = [4, 3]
                border.setLineDash(pattern, count: 2, phase: 0)
                border.stroke()
            }

            context.restoreGraphicsState()

            // (Text move handle removed — standard annotation chrome handles movement)

            // Live beautify preview — draw gradient background, shadow, and rounded image around selection
            let showBeautifyPreview = beautifyEnabled && state == .selected && !isScrollCapturing && !isRecording
            let showEffectsPreview = effectsActive && state == .selected && !isScrollCapturing && !isRecording && !beautifyEnabled

            if showBeautifyPreview {
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                drawBeautifyPreview(context: context)
                context.restoreGraphicsState()

                // Re-draw in-progress annotation on top of beautify so it stays visible
                if currentAnnotation != nil || autoMeasurePreview != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    currentAnnotation?.draw(in: context)
                    autoMeasurePreview?.draw(in: context)
                    context.restoreGraphicsState()
                }

                // Re-draw annotation controls on top of the beautify preview so they stay visible.
                if !isRecording && !selectedAnnotations.isEmpty {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    for selected in selectedAnnotations {
                        drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
                    }
                    drawMultiSelectDeleteButton()
                    context.restoreGraphicsState()
                }

                // Re-draw loupe preview on top of beautify so it stays visible
                if currentTool == .loupe && selectionRect.contains(loupeCursorPoint)
                    && loupeCursorPoint != .zero
                {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawLoupePreview(at: loupeCursorPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw color sampler preview on top of beautify
                if currentTool == .colorSampler && colorSamplerPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawColorSamplerPreview(at: colorSamplerPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw snap guides on top of beautify
                if snapGuideX != nil || snapGuideY != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawSnapGuides()
                    context.restoreGraphicsState()
                }

                // Re-draw drawing cursor dot preview on top of beautify
                if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation
                {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawDrawingCursorPreview(at: drawingCursorPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw crop preview on top of beautify
                if isCropDragging && cropDragRect.width > 1 && cropDragRect.height > 1 {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawCropPreview()
                    NSColor.white.setStroke()
                    let cropBorder = NSBezierPath(rect: cropDragRect)
                    cropBorder.lineWidth = 1.5
                    cropBorder.stroke()
                    context.restoreGraphicsState()
                }
            }

            // Effects-only preview (no beautify) — draw effects-processed screenshot in selection
            if showEffectsPreview, let screenshot = screenshotImage {
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                NSBezierPath(rect: selectionRect).setClip()
                let effectsImage = effectsProcessedScreenshot(screenshot)
                effectsImage.draw(in: captureDrawRect, from: .zero, operation: .copy, fraction: 1.0)
                // Re-draw annotations on top (censor first, then everything else)
                for annotation in annotations where annotation.tool == .pixelate { annotation.draw(in: context) }
                Annotation.drawHighlightDim(for: annotations, extra: currentAnnotation, in: highlightDimBounds)
                for annotation in annotations where annotation.tool != .pixelate { annotation.draw(in: context) }
                currentAnnotation?.draw(in: context)
                context.restoreGraphicsState()

                // Re-draw overlays on top of effects preview
                if !selectedAnnotations.isEmpty {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    for selected in selectedAnnotations {
                        drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
                    }
                    drawMultiSelectDeleteButton()
                    context.restoreGraphicsState()
                }
                if currentTool == .loupe && selectionRect.contains(loupeCursorPoint) && loupeCursorPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawLoupePreview(at: loupeCursorPoint)
                    context.restoreGraphicsState()
                }
                if currentTool == .colorSampler && colorSamplerPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawColorSamplerPreview(at: colorSamplerPoint)
                    context.restoreGraphicsState()
                }
                if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawDrawingCursorPreview(at: drawingCursorPoint)
                    context.restoreGraphicsState()
                }
                if snapGuideX != nil || snapGuideY != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawSnapGuides()
                    context.restoreGraphicsState()
                }
            }

            // Selection border — hidden in editor mode and when beautify/effects preview is active,
            // red during scroll capture, purple otherwise
            if shouldDrawSelectionBorder()
                && !showBeautifyPreview && !showEffectsPreview
            {
                let borderPath = NSBezierPath(rect: selectionRect)
                borderPath.lineWidth = isScrollCapturing ? 2.5 : 2.0
                (isScrollCapturing ? NSColor.systemRed : ToolbarLayout.accentColor).setStroke()
                borderPath.stroke()
            }

            // Resolution box (real NSView) is managed in updateResolutionBox(),
            // called from layout/selection changes — not drawn here.

            // Resize handles (drawn even in recording setup mode, but not during scroll capture)
            if state == .selected && !isEditorMode && !isScrollCapturing {
                drawResizeHandles()
            }

            // Boundary-snap guide line(s) — while resizing or drawing a new
            // selection with an active snap.
            if isResizingSelection || state == .selecting {
                drawBoundarySnapGuides()
            }

            // Hide the text view when color picker is open for bg/outline (so picker isn't behind it)
            if let sv = textEditor.scrollView {
                let shouldHide = false
                sv.isHidden = shouldHide
            }

            // Live text box (bg/outline + resize handles)
            if let sv = textEditor.scrollView, textEditView != nil {
                let pad: CGFloat = 4
                let pillRect = sv.frame.insetBy(dx: -pad, dy: -pad)
                let cornerR: CGFloat = 4

                // Background fill
                if textEditor.bgEnabled {
                    textEditor.bgColor.setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR).fill()
                }

                // Text outline
                if textEditor.outlineEnabled {
                    textEditor.outlineColor.setStroke()
                    let outlinePath = NSBezierPath(
                        roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR)
                    outlinePath.lineWidth = 2
                    outlinePath.stroke()
                }

                // Draw text content when scroll view is hidden (color picker open)
                if sv.isHidden, let tv = textEditView, let attrStr = tv.textStorage,
                    attrStr.length > 0
                {
                    let inset = tv.textContainerInset
                    let textRect = NSRect(
                        x: sv.frame.minX + inset.width, y: sv.frame.minY + inset.height,
                        width: sv.frame.width - inset.width * 2,
                        height: sv.frame.height - inset.height * 2)
                    context.saveGraphicsState()
                    let flipped = NSAffineTransform()
                    flipped.translateX(by: 0, yBy: sv.frame.maxY + sv.frame.minY)
                    flipped.scaleX(by: 1, yBy: -1)
                    flipped.concat()
                    attrStr.draw(in: textRect)
                    context.restoreGraphicsState()
                }

                // Box border (always visible while editing)
                NSColor.white.withAlphaComponent(0.4).setStroke()
                let borderPath = NSBezierPath(rect: sv.frame)
                borderPath.lineWidth = 1
                let pattern: [CGFloat] = [4, 3]
                borderPath.setLineDash(pattern, count: 2, phase: 0)
                borderPath.stroke()

                // Resize handles on the text box
                let hs: CGFloat = 6
                let handleColor = NSColor.white
                let handleRects = [
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom-left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom-right
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top-left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top-right
                    NSRect(
                        x: sv.frame.midX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom
                    NSRect(
                        x: sv.frame.midX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.midY - hs / 2, width: hs, height: hs),  // left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.midY - hs / 2, width: hs, height: hs),  // right
                ]
                for hr in handleRects {
                    handleColor.setFill()
                    NSBezierPath(roundedRect: hr, xRadius: 1, yRadius: 1).fill()
                    NSColor.black.withAlphaComponent(0.3).setStroke()
                    NSBezierPath(roundedRect: hr, xRadius: 1, yRadius: 1).stroke()
                }
            }

            // Stamp cursor preview
            if let previewPt = stampPreviewPoint, let img = currentStampImage,
                currentTool == .stamp, !isRecording
            {
                let stampSize: CGFloat = currentStampSize
                let aspect = img.size.width / max(img.size.height, 1)
                let w = aspect >= 1 ? stampSize : stampSize * aspect
                let h = aspect >= 1 ? stampSize / aspect : stampSize
                let previewRect = NSRect(
                    x: previewPt.x - w / 2, y: previewPt.y - h / 2, width: w, height: h)
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                img.draw(
                    in: previewRect, from: .zero, operation: .sourceOver, fraction: 0.5,
                    respectFlipped: true, hints: nil)
                context.restoreGraphicsState()
            }

            // Toolbars — reposition only when selection/layout changes (not every draw).
            // In editor mode toolbars have autoresizingMask, so they only need repositioning
            // on explicit layout changes (handled by rebuildToolbarLayout).
            // In overlay mode the selection rect moves, so we must reposition here.
            if showToolbars && state == .selected && !isScrollCapturing {
                if !isEditorMode { repositionToolbars() }
                // Toolbars are real NSView subviews (ToolbarStripView) — no custom drawing needed.
                // Tool options row handled by ToolOptionsRowView (real NSView subview)
                if !toolHasOptionsRow || isRecording {
                    // options row rect managed by ToolOptionsRowView
                }

                // Color picker popover

                // Beautify style picker popover

                // Stroke width picker popover

                // Loupe size picker

                // Upload confirm picker

                // Redact type picker

            }

            // Radial color wheel
            if colorWheel.isVisible {
                colorWheel.draw(currentColor: currentColor)
            }
        }

        // Overlay error message
        if let errorMsg = overlayErrorMessage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let str = errorMsg as NSString
            let strSize = str.size(withAttributes: attrs)
            let padding: CGFloat = 12
            let msgW = strSize.width + padding * 2
            let msgH = strSize.height + padding
            let msgX = bounds.midX - msgW / 2
            let msgY = bounds.maxY - msgH - 40
            let msgRect = NSRect(x: msgX, y: msgY, width: msgW, height: msgH)
            NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: msgRect, xRadius: 8, yRadius: 8).fill()
            str.draw(
                at: NSPoint(x: msgRect.minX + padding, y: msgRect.minY + padding / 2),
                withAttributes: attrs)
        }

        // Instant tooltip for hovered toolbar button
        drawHoveredTooltip()

    }
    static let helperFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let helperSmallFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let helperSmallBoldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let helperDimColor = NSColor.white.withAlphaComponent(0.7)

    func drawIdleHelperText() {
        let line1 =
            windowSnapEnabled
            ? L("Click a window  ·  Drag for custom area  ·  F for full screen")
            : L("Drag to select  ·  Click for full screen")
        let snapOn = windowSnapEnabled
        let line3prefix = L("Window snap: ")
        let line3state = snapOn ? L("ON") : L("OFF")
        let line3suffix = L("  (Tab to toggle)")

        let snapColor = snapOn ? NSColor.systemGreen : NSColor.systemOrange

        let attrs1: [NSAttributedString.Key: Any] = [.font: Self.helperFont, .foregroundColor: NSColor.white]
        let attrs2prefix: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallFont, .foregroundColor: Self.helperDimColor,
        ]
        let attrs2state: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallBoldFont, .foregroundColor: snapColor,
        ]
        let attrs2suffix: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallFont, .foregroundColor: Self.helperDimColor,
        ]

        let size1 = (line1 as NSString).size(withAttributes: attrs1)
        let size2pre = (line3prefix as NSString).size(withAttributes: attrs2prefix)
        let size2state = (line3state as NSString).size(withAttributes: attrs2state)
        let size2suf = (line3suffix as NSString).size(withAttributes: attrs2suffix)
        let size2total = CGSize(
            width: size2pre.width + size2state.width + size2suf.width,
            height: max(size2pre.height, size2state.height, size2suf.height))

        let lineSpacing: CGFloat = 6
        let padding: CGFloat = 14
        let buttonSize = NSSize(width: 34, height: 28)
        let buttonGap: CGFloat = 10
        let showPresetButton = shouldShowPreSelectionPresetButton
        let buttonBlockHeight = showPresetButton ? buttonSize.height + buttonGap : 0
        let totalTextHeight = size1.height + lineSpacing + size2total.height + buttonBlockHeight
        let bgWidth = max(size1.width, size2total.width, showPresetButton ? buttonSize.width : 0) + padding * 2
        let bgHeight = totalTextHeight + padding * 2

        let bgX = bounds.midX - bgWidth / 2
        let bgY = bounds.midY - bgHeight / 2
        let bgRect = NSRect(x: bgX, y: bgY, width: bgWidth, height: bgHeight)

        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8).fill()

        if showPresetButton {
            let buttonFrame = NSRect(
                x: bounds.midX - buttonSize.width / 2,
                y: bgY + padding,
                width: buttonSize.width,
                height: buttonSize.height)
            showPreSelectionPresetButton(frame: buttonFrame)
        } else {
            hidePreSelectionPresetButton()
        }

        let textY2 = bgY + padding + buttonBlockHeight
        let textY1 = textY2 + size2total.height + lineSpacing

        (line1 as NSString).draw(
            at: NSPoint(x: bounds.midX - size1.width / 2, y: textY1), withAttributes: attrs1)

        // Draw snap line as three segments with different colors
        let line2startX = bounds.midX - size2total.width / 2
        let line2Y = textY2 + (size2total.height - size2pre.height) / 2
        (line3prefix as NSString).draw(
            at: NSPoint(x: line2startX, y: line2Y), withAttributes: attrs2prefix)
        (line3state as NSString).draw(
            at: NSPoint(x: line2startX + size2pre.width, y: line2Y), withAttributes: attrs2state)
        (line3suffix as NSString).draw(
            at: NSPoint(x: line2startX + size2pre.width + size2state.width, y: line2Y),
            withAttributes: attrs2suffix)
    }

    static let helperTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    func drawSelectingHelperText() {
        guard selectionRect.width >= 1, selectionRect.height >= 1 else { return }

        let text = autoQuickSaveMode
            ? L("Hold Space to move. Release to finish")
            : L("Hold Space to move. Release to annotate and edit")
        let attrs = Self.helperTextAttrs
        let size = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 10
        let bgWidth = size.width + padding * 2
        let bgHeight = size.height + padding

        // Position below the selection, centered
        var labelX = selectionRect.midX - bgWidth / 2
        var labelY = selectionRect.minY - bgHeight - 8

        // If below screen, put above
        if labelY < bounds.minY + 4 {
            labelY = selectionRect.maxY + 8
        }
        // Clamp horizontal
        labelX = max(bounds.minX + 4, min(labelX, bounds.maxX - bgWidth - 4))

        let bgRect = NSRect(x: labelX, y: labelY, width: bgWidth, height: bgHeight)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6).fill()

        (text as NSString).draw(
            at: NSPoint(x: bgRect.minX + padding, y: bgRect.minY + padding / 2),
            withAttributes: attrs)
    }

    static let sizeLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    /// Compute where the resolution box sits relative to the selection. Aligns
    /// the box's W↔H midpoint (the "×") with the selection's horizontal center,
    /// so the dimensions read as centered on the selection — the trailing presets
    /// button just overhangs to the right (not counted in the centering).
    func resolutionBoxFrame(size: NSSize, dimsCenterX: CGFloat) -> NSRect {
        // mac-capture.html `.size`: left-aligned with the selection, just above it.
        let x = selectionRect.minX - 1
        let clampedX = max(bounds.minX + 2, min(x, bounds.maxX - size.width - 2))
        let edgeGap = handleSize / 2 + 3
        let above = selectionRect.maxY + edgeGap
        let below = selectionRect.minY - size.height - edgeGap
        let minY = bounds.minY + 2
        let maxY = bounds.maxY - 2

        func rect(at y: CGFloat) -> NSRect {
            NSRect(x: clampedX, y: y, width: size.width, height: size.height)
        }
        func fits(_ rect: NSRect) -> Bool {
            rect.minY >= minY && rect.maxY <= maxY
        }
        let toolbarAvoidanceRects = resolutionBoxAvoidanceRects().map { $0.insetBy(dx: -4, dy: -4) }
        let topObstructionRects = screenTopObstructionRects().map { $0.insetBy(dx: -4, dy: -2) }
        let avoidanceRects = toolbarAvoidanceRects + topObstructionRects
        func loweredBelowTopObstructions(_ rect: NSRect) -> NSRect {
            var adjusted = rect
            for obstruction in topObstructionRects where adjusted.intersects(obstruction) {
                adjusted.origin.y = min(adjusted.origin.y, obstruction.minY - adjusted.height - 2)
            }
            return adjusted
        }
        func overlapArea(_ rect: NSRect) -> CGFloat {
            avoidanceRects.reduce(CGFloat(0)) { total, occupied in
                let hit = rect.intersection(occupied)
                guard !hit.isNull else { return total }
                return total + max(0, hit.width) * max(0, hit.height)
            }
        }

        let aboveRect = loweredBelowTopObstructions(rect(at: above))
        let belowRect = loweredBelowTopObstructions(rect(at: below))
        let outsideCandidates = [aboveRect, belowRect]
        if let clear = outsideCandidates.first(where: { fits($0) && overlapArea($0) == 0 }) {
            return clear
        }

        let insideTop = loweredBelowTopObstructions(rect(at: selectionRect.maxY - size.height - edgeGap))
        let insideBottom = loweredBelowTopObstructions(rect(at: selectionRect.minY + edgeGap))
        func fitsInsideSelection(_ rect: NSRect) -> Bool {
            rect.minY >= selectionRect.minY + 2 && rect.maxY <= selectionRect.maxY - 2
        }
        let insideCandidates: [NSRect]
        if !fits(aboveRect) && fits(belowRect) {
            insideCandidates = [insideTop, insideBottom]
        } else if !fits(belowRect) && fits(aboveRect) {
            insideCandidates = [insideBottom, insideTop]
        } else {
            insideCandidates = [insideTop, insideBottom]
        }
        let clearInsideCandidates = insideCandidates.filter { fits($0) && fitsInsideSelection($0) }
        if let clearInside = clearInsideCandidates.first(where: { overlapArea($0) == 0 }) {
            return clearInside
        }

        let candidates = outsideCandidates + clearInsideCandidates
        if let leastBlocked = candidates.filter(fits).min(by: { overlapArea($0) < overlapArea($1) }) {
            return leastBlocked
        }
        let clampedY = max(minY, min(above, maxY - size.height))
        let clampedRect = loweredBelowTopObstructions(rect(at: clampedY))
        return fits(clampedRect) ? clampedRect : rect(at: clampedY)
    }

    /// Notched displays expose the unobscured top-left/right menu-bar areas via
    /// NSScreen. The remaining top band is the camera housing area; keep small
    /// floating chrome out of that rect while still allowing it in the safe side
    /// areas on MacBooks with a notch.
    func screenTopObstructionRects() -> [NSRect] {
        guard #available(macOS 12.0, *),
              let screen = window?.screen,
              screen.safeAreaInsets.top > 0 else { return [] }

        let topBandScreen = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: screen.frame.width,
            height: screen.safeAreaInsets.top)

        let topBand = overlayRect(fromScreenRect: topBandScreen)
        guard topBand.width > 1, topBand.height > 1 else { return [] }

        let unobscuredTopAreas = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 }
            .map { overlayRect(fromScreenRect: $0).intersection(topBand) }
            .filter { !$0.isNull && $0.width > 1 && $0.height > 1 }

        return unobscuredTopAreas.reduce([topBand]) { blockedRects, unobscured in
            blockedRects.flatMap { subtract(unobscured, from: $0) }
        }.filter { $0.width > 1 && $0.height > 1 }
    }

    func overlayRect(fromScreenRect rect: NSRect) -> NSRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        if let win = window {
            return convert(win.convertFromScreen(rect), from: nil)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        }
        return rect
    }

    func subtract(_ cut: NSRect, from source: NSRect) -> [NSRect] {
        let hit = source.intersection(cut)
        guard !hit.isNull, hit.width > 0, hit.height > 0 else { return [source] }

        var pieces: [NSRect] = []
        if hit.maxY < source.maxY {
            pieces.append(NSRect(x: source.minX, y: hit.maxY, width: source.width, height: source.maxY - hit.maxY))
        }
        if hit.minY > source.minY {
            pieces.append(NSRect(x: source.minX, y: source.minY, width: source.width, height: hit.minY - source.minY))
        }
        if hit.minX > source.minX {
            pieces.append(NSRect(x: source.minX, y: hit.minY, width: hit.minX - source.minX, height: hit.height))
        }
        if hit.maxX < source.maxX {
            pieces.append(NSRect(x: hit.maxX, y: hit.minY, width: source.maxX - hit.maxX, height: hit.height))
        }
        return pieces
    }

    func resolutionBoxAvoidanceRects() -> [NSRect] {
        guard showToolbars && !isEditorMode && state == .selected && !isScrollCapturing else { return [] }

        var rects: [NSRect] = []
        if bottomStripView?.isHidden == false {
            rects.append(bottomBarRect)
        }
        if toolOptionsRowView?.isHidden == false, optionsRowRect.width > 1, optionsRowRect.height > 1 {
            rects.append(optionsRowRect)
        }
        if rightStripView?.isHidden == false {
            rects.append(rightBarRect)
        }
        if captureIsland?.isHidden == false {
            rects.append(islandRect)
        }
        return rects.filter { $0.width > 1 && $0.height > 1 }
    }

    /// Create/position/update or remove the resolution box for the current state.
    /// In the Liquid Glass theme the box is hosted in a glass chrome panel (like
    /// the toolbars); otherwise it's a solid-bg overlay subview.
    func updateResolutionBox() {
        guard shouldShowResolutionBox() else {
            dismissResolutionBox()
            return
        }
        // While a W/H field is being edited, leave the box exactly where it is.
        // Re-laying-out mid-edit disturbs the field editor / first responder,
        // which makes typing beep. The selection isn't changing during editing,
        // so there's nothing to update.
        if let editing = resolutionBox, editing.isActivelyEditing { return }

        let box: ResolutionBoxView
        if let existing = resolutionBox {
            box = existing
        } else {
            box = ResolutionBoxView()
            box.onCommit = { [weak self] w, h, edited in
                guard let self else { return }
                if self.applyDisplaySize(w: w, h: h, edited: edited) {
                    self.clearStaleExactPreSelectionPresetIfNeeded()
                }
            }
            box.onFinishEditing = { [weak self] in
                guard let self else { return }
                self.window?.makeKey()
                self.window?.makeFirstResponder(self)
                self.updateResolutionBox()
            }
            box.onPresets = { [weak self] anchor in self?.showResolutionPresets(from: anchor) }
            resolutionBox = box
        }
        let px = selectionDisplaySize
        box.setDimensions(w: px.w, h: px.h)
        // V3 info pills: the other unit on Retina screens, and the edge-snap state.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        var retinaText: String?
        if scale > 1.01, !isRecording {
            if resolutionUnitIsPoints {
                let pixels = selectionPixelSize
                retinaText = "Retina · \(pixels.w) × \(pixels.h)"
            } else {
                retinaText = "Retina · \(Int(selectionRect.width.rounded())) × \(Int(selectionRect.height.rounded())) pt"
            }
        }
        box.setInfo(retina: retinaText, snapped: !isRecording && (boundarySnapGuideX != nil || boundarySnapGuideY != nil))
        let frame = resolutionBoxFrame(size: box.preferredSize, dimsCenterX: box.dimensionsCenterX)
        resolutionBoxRect = frame  // overlay-space rect (for chrome/cursor/zoom anchor)
        box.setActivePresetLabel(preSelectionPresetDisplayLabel)

        // Inline: a solid-bg overlay subview at the overlay-space frame.
        if box.superview !== self { box.removeFromSuperview(); addSubview(box) }
        box.frame = frame
    }

    func refreshResolutionAndToolbarLayout() {
        updateResolutionBox()
        repositionToolbars()
        updateResolutionBox()
    }

    /// Human label of the currently locked aspect ratio, if any.
    var activeRatioLabel: String? {
        guard let a = lockedAspect else { return nil }
        return ResolutionPresetCatalog.ratios.first {
            if case .ratio(_, let v) = $0 { return abs(v - a) < 0.001 }
            return false
        }?.label
    }

    /// True if a non-nil locked aspect doesn't match any named ratio preset —
    /// i.e. it's a custom ratio (e.g. locked from a typed W×H).
    var lockedAspectIsCustom: Bool {
        guard let a = lockedAspect, a > 0 else { return false }
        return !ResolutionPresetCatalog.ratios.contains {
            if case .ratio(_, let v) = $0 { return abs(v - a) < 0.001 }
            return false
        }
    }

    /// A compact aspect-ratio label that always fits the popover column. Uses a
    /// small reduced "W : H" only when it reduces cleanly to short numbers
    /// (e.g. 16 : 9, 3 : 1); otherwise a short decimal like "1.62 : 1". Never
    /// shows raw multi-digit pixel dims (which overflowed the column).
    func ratioLabel(for aspect: CGFloat) -> String {
        guard aspect > 0 else { return "—" }
        let px = selectionPixelSize
        if px.w > 0, px.h > 0, abs(CGFloat(px.w) / CGFloat(px.h) - aspect) < 0.01 {
            let g = Self.gcd(px.w, px.h)
            let rw = px.w / g, rh = px.h / g
            if rw <= 32 && rh <= 32 { return "\(rw) : \(rh)" }
        }
        // Decimal fallback — compact and bounded width.
        if abs(aspect.rounded() - aspect) < 0.001 { return "\(Int(aspect.rounded())) : 1" }
        return String(format: "%.2f : 1", aspect)
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    /// The current selection's aspect ratio (w/h) in pixel space, or nil when
    /// there's no usable selection.
    var currentSelectionAspect: CGFloat? {
        let px = selectionPixelSize
        guard px.w > 0, px.h > 0 else { return nil }
        return CGFloat(px.w) / CGFloat(px.h)
    }

    /// Toggle the presets popover (aspect ratios + common resolutions) from `anchor`.
    func showResolutionPresets(from anchor: NSView) {
        // Clicking the button while the popover is open should close it.
        if PopoverHelper.toggleClosedIfOpen() { return }
        let activePreset = activePreSelectionPreset
        let view = ResolutionPresetsView()

        let customLocked = lockedAspectIsCustom
        var ratioRows = ResolutionPresetCatalog.ratios.map { preset -> ResolutionPresetsView.Row in
            // When a custom ratio is locked, no named preset (including Freeform)
            // is the active one — the Custom row owns the checkmark.
            let selected = !customLocked && preSelectionPreset(activePreset, selects: preset)
            return ResolutionPresetsView.Row(title: preset.label, isSelected: selected) { [weak self] in
                PopoverHelper.dismiss()
                guard let self else { return }
                // A choice made on an active selection only persists into the
                // next capture when "keep ratio for next captures" is on. When
                // it's off, apply to the current selection but clear any
                // pre-selection preset so the next capture starts freeform.
                if self.keepRatioForNextCaptures {
                    if let aspect = preset.aspectValue {
                        self.setPreSelectionPreset(.ratio(aspect))
                    } else {
                        self.setPreSelectionPreset(.freeform)
                    }
                } else {
                    self.setPreSelectionPreset(.freeform)
                }
                self.applyLockedAspect(preset.aspectValue)
                self.persistRatioIfNeeded()
            }
        }

        // "Custom" row: lock the CURRENT selection's aspect ratio (e.g. one you
        // just set by typing W and H). Shows the live ratio and is checked when a
        // non-preset ratio is locked. Lets you resize while keeping that ratio.
        if let curAspect = currentSelectionAspect {
            let customSelected = customLocked
            let customTitle = customSelected
                ? String(format: L("Custom · %@"), ratioLabel(for: lockedAspect ?? curAspect))
                : String(format: L("Custom · %@"), ratioLabel(for: curAspect))
            let customRow = ResolutionPresetsView.Row(title: customTitle, isSelected: customSelected) { [weak self] in
                PopoverHelper.dismiss()
                guard let self else { return }
                let aspect = self.currentSelectionAspect ?? curAspect
                // Persist for the next capture only when keep-ratio is on.
                if self.keepRatioForNextCaptures {
                    self.setPreSelectionPreset(.ratio(aspect))
                } else {
                    self.setPreSelectionPreset(.freeform)
                }
                self.applyLockedAspect(aspect)
                self.persistRatioIfNeeded()
            }
            // Place Custom right after Freeform (index 0) so it sits at the top
            // of the real ratios.
            ratioRows.insert(customRow, at: 1)
        }
        view.ratioRows = ratioRows
        view.resolutionRows = ResolutionPresetCatalog.resolutions.map { preset in
            guard case .resolution(_, let w, let h) = preset else {
                return ResolutionPresetsView.Row(title: preset.label, isSelected: false, action: {})
            }
            return ResolutionPresetsView.Row(title: preset.label, isSelected: preSelectionPreset(activePreset, selects: preset)) { [weak self] in
                PopoverHelper.dismiss()
                guard let self else { return }
                // Same rule for fixed resolutions: only persist for the next
                // capture when keep-ratio is on; otherwise this resolution
                // applies to the current selection only.
                if self.keepRatioForNextCaptures {
                    self.setPreSelectionPreset(.resolution(w: w, h: h))
                } else {
                    self.setPreSelectionPreset(.freeform)
                }
                self.applyLockedAspect(nil)
                self.applyPixelSize(w: w, h: h)
                self.persistRatioIfNeeded()
            }
        }
        view.keepRatioOn = keepRatioForNextCaptures
        view.onToggleKeepRatio = { [weak self] on in
            guard let self else { return }
            self.keepRatioForNextCaptures = on
            self.persistRatioIfNeeded()
            self.refreshResolutionAndToolbarLayout()  // refresh the enforced-icon tint
        }
        view.unitIndex = resolutionUnitIsPoints ? 1 : 0
        view.onPickUnit = { [weak self] idx in
            self?.resolutionUnitIsPoints = (idx == 1)
            self?.refreshResolutionAndToolbarLayout()  // re-display W/H in the new unit
        }
        view.build()
        PopoverHelper.show(view, size: view.preferredSize,
                           relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    var preSelectionPresetStorageKind: PreSelectionPresetStorageKind {
        get {
            PreSelectionPresetStorageKind(
                rawValue: UserDefaults.standard.integer(forKey: Self.preSelectionPresetKindKey))
                ?? .inherited
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.preSelectionPresetKindKey) }
    }

    var activePreSelectionPreset: PreSelectionPreset {
        switch preSelectionPresetStorageKind {
        case .freeform:
            return .freeform
        case .ratio:
            let aspect = CGFloat(UserDefaults.standard.double(forKey: Self.preSelectionPresetAspectKey))
            return aspect > 0 ? .ratio(aspect) : .freeform
        case .resolution:
            let w = UserDefaults.standard.integer(forKey: Self.preSelectionPresetWidthKey)
            let h = UserDefaults.standard.integer(forKey: Self.preSelectionPresetHeightKey)
            return w > 0 && h > 0 ? .resolution(w: w, h: h) : .freeform
        case .inherited:
            return keepRatioForNextCaptures && persistedAspect > 0 ? .ratio(persistedAspect) : .freeform
        }
    }

    var activePreSelectionRatio: CGFloat? {
        if case .ratio(let aspect) = activePreSelectionPreset, aspect > 0 { return aspect }
        return nil
    }

    var preSelectionPresetDisplayLabel: String? {
        switch activePreSelectionPreset {
        case .freeform:
            // A custom ratio can be locked for the current selection even when
            // it isn't persisted for the next capture (keep-ratio off). Surface
            // it so the box/button still shows the active lock.
            if lockedAspectIsCustom, let a = lockedAspect {
                return ratioLabel(for: a)
            }
            return nil
        case .ratio(let aspect):
            return ResolutionPresetCatalog.ratios.first {
                if case .ratio(_, let value) = $0 { return abs(value - aspect) < 0.001 }
                return false
            }?.label ?? ratioLabel(for: aspect)
        case .resolution(let w, let h):
            return ResolutionPresetCatalog.resolutions.first {
                if case .resolution(_, let presetW, let presetH) = $0 {
                    return presetW == w && presetH == h
                }
                return false
            }?.label ?? "\(w) × \(h)"
        }
    }

    func preSelectionPreset(_ activePreset: PreSelectionPreset, selects preset: ResolutionPreset) -> Bool {
        switch (activePreset, preset) {
        case (.freeform, .freeform):
            return true
        case (.ratio(let active), .ratio(_, let value)):
            return abs(active - value) < 0.001
        case (.resolution(let activeW, let activeH), .resolution(_, let w, let h)):
            return activeW == w && activeH == h
        default:
            return false
        }
    }

    func clearStaleExactPreSelectionPresetIfNeeded() {
        guard case .resolution(let presetW, let presetH) = activePreSelectionPreset else { return }
        let px = selectionPixelSize
        if px.w != presetW || px.h != presetH {
            setPreSelectionPreset(.freeform)
        }
    }

    var shouldShowPreSelectionPresetButton: Bool {
        state == .idle
            && screenshotImage != nil
            && !isEditorMode
            && !isRecording
            && !autoOCRMode
            && remoteSelectionRect.width < 1
            && remoteSelectionRect.height < 1
    }

    func updateCaptureModeBar() {
        guard !isEditorMode, state == .idle, screenshotImage != nil,
              remoteSelectionRect.width < 1, remoteSelectionRect.height < 1 else {
            captureModeBar?.isHidden = true
            return
        }
        if captureModeBar == nil {
            // mac-capture.html idle "#modebar": 区域 / 窗口 / 全屏 | ×, dark capture-bar chrome.
            let bar = CaptureModeBarView()
            for (tag, symbol, title) in [
                (0, "square.dashed", L("Region")), (1, "macwindow", L("Window")),
                (2, "display", L("Full Screen")), (4, "xmark", L("Cancel"))
            ] {
                let button = CaptureModeBarButton(title: title, symbol: symbol, isClose: tag == 4)
                button.target = self
                button.action = #selector(captureModeClicked(_:))
                button.tag = tag
                button.toolTip = title
                bar.addSubview(button)
            }
            addSubview(bar)
            captureModeBar = bar
        }
        guard let bar = captureModeBar else { return }
        for case let button as CaptureModeBarButton in bar.subviews {
            button.isOn = (button.tag == 1 && windowSnapEnabled) || (button.tag == 0 && !windowSnapEnabled)
        }
        bar.layoutButtons()
        bar.frame.origin = NSPoint(x: bounds.midX - bar.frame.width / 2, y: bounds.minY + 34)
        bar.isHidden = false
    }

    @objc func captureModeClicked(_ sender: NSButton) {
        guard state == .idle else { return }
        switch sender.tag {
        case 0, 1:
            windowSnapEnabled = sender.tag == 1
            hoveredWindowRect = nil
            overlayDelegate?.overlayViewDidChangeWindowSnapState()
            window?.makeFirstResponder(self)
            updateCaptureModeBar()
            needsDisplay = true
        case 2:
            selectionRect = bounds
            state = .selected
            hoveredWindowRect = nil
            captureModeBar?.isHidden = true
            if autoQuickSaveMode {
                autoQuickSaveMode = false
                overlayDelegate?.overlayViewDidRequestQuickSave()
            } else {
                showToolbars = true
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
                needsDisplay = true
            }
        default: overlayDelegate?.overlayViewDidCancel()
        }
    }

    func showPreSelectionPresetButton(frame: NSRect) {
        let button: PreSelectionPresetButton
        if let existing = preSelectionPresetButton {
            button = existing
        } else {
            button = PreSelectionPresetButton()
            button.target = self
            button.action = #selector(preSelectionPresetButtonClicked(_:))
            preSelectionPresetButton = button
        }

        if button.superview !== self {
            button.removeFromSuperview()
            addSubview(button)
        }

        preSelectionPresetButtonRect = frame
        button.frame = frame
        let label = preSelectionPresetDisplayLabel
        let title = L("Aspect ratio & resolution presets")
        button.update(active: label != nil, tooltip: label.map { "\(title): \($0)" } ?? title)
        button.isHidden = false
    }

    func hidePreSelectionPresetButton() {
        preSelectionPresetButton?.isHidden = true
        preSelectionPresetButtonRect = .zero
    }

    @objc func preSelectionPresetButtonClicked(_ sender: NSButton) {
        showPreSelectionResolutionPresets(from: sender)
    }

    func setPreSelectionPreset(_ preset: PreSelectionPreset) {
        switch preset {
        case .freeform:
            preSelectionPresetStorageKind = .freeform
            lockedAspect = nil
        case .ratio(let aspect):
            preSelectionPresetStorageKind = .ratio
            UserDefaults.standard.set(Double(aspect), forKey: Self.preSelectionPresetAspectKey)
            lockedAspect = aspect
        case .resolution(let w, let h):
            preSelectionPresetStorageKind = .resolution
            UserDefaults.standard.set(w, forKey: Self.preSelectionPresetWidthKey)
            UserDefaults.standard.set(h, forKey: Self.preSelectionPresetHeightKey)
            lockedAspect = nil
        }
        if state == .selected {
            refreshResolutionAndToolbarLayout()
        }
        preSelectionPresetButton?.update(
            active: preSelectionPresetDisplayLabel != nil,
            tooltip: preSelectionPresetDisplayLabel.map {
                "\(L("Aspect ratio & resolution presets")): \($0)"
            } ?? L("Aspect ratio & resolution presets"))
        needsDisplay = true
    }

    func showPreSelectionResolutionPresets(from anchor: NSView) {
        if PopoverHelper.toggleClosedIfOpen() { return }

        let activePreset = activePreSelectionPreset
        let view = ResolutionPresetsView()
        view.showsKeepRatioToggle = true
        view.showsUnitSelector = false
        view.ratioRows = ResolutionPresetCatalog.ratios.map { preset in
            let selected = preSelectionPreset(activePreset, selects: preset)
            return ResolutionPresetsView.Row(title: preset.label, isSelected: selected) { [weak self] in
                PopoverHelper.dismiss()
                guard let self else { return }
                switch preset {
                case .freeform:
                    self.setPreSelectionPreset(.freeform)
                case .ratio(_, let value):
                    self.setPreSelectionPreset(.ratio(value))
                default:
                    break
                }
            }
        }
        view.resolutionRows = ResolutionPresetCatalog.resolutions.map { preset in
            guard case .resolution(_, let w, let h) = preset else {
                return ResolutionPresetsView.Row(title: preset.label, isSelected: false, action: {})
            }
            let selected = preSelectionPreset(activePreset, selects: preset)
            return ResolutionPresetsView.Row(title: preset.label, isSelected: selected) { [weak self] in
                PopoverHelper.dismiss()
                self?.setPreSelectionPreset(.resolution(w: w, h: h))
            }
        }
        view.keepRatioOn = keepRatioForNextCaptures
        view.onToggleKeepRatio = { [weak self] on in
            guard let self else { return }
            self.keepRatioForNextCaptures = on
            if on, case .ratio(let aspect) = self.activePreSelectionPreset {
                self.persistedAspect = aspect
            } else if !on {
                self.persistedAspect = 0
            }
            self.refreshResolutionAndToolbarLayout()
        }
        view.build()
        PopoverHelper.show(view, size: view.preferredSize,
                           relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Persist (or clear) the current locked ratio for future captures, per the
    /// "keep ratio" toggle.
    func persistRatioIfNeeded() {
        guard keepRatioForNextCaptures else { return }
        persistedAspect = lockedAspect ?? 0
    }

    /// Apply the persisted aspect ratio to a freshly started selection, if the
    /// "keep ratio for next captures" toggle is on. Call when a new capture
    /// overlay/selection begins.
    func applyPersistedRatioIfNeeded() {
        guard keepRatioForNextCaptures, persistedAspect > 0 else { return }
        lockedAspect = persistedAspect
    }

    /// Current selection size in device pixels (rounded, not truncated).
    var selectionPixelSize: (w: Int, h: Int) {
        let scale = window?.backingScaleFactor ?? 2.0
        return (Int((selectionRect.width * scale).rounded()),
                Int((selectionRect.height * scale).rounded()))
    }

    /// Whether the resolution box shows/accepts points (true) or device pixels.
    var resolutionUnitIsPoints: Bool {
        get { UserDefaults.standard.bool(forKey: "resolutionUnitIsPoints") }
        set { UserDefaults.standard.set(newValue, forKey: "resolutionUnitIsPoints") }
    }

    /// Selection size in the user's chosen display unit (px or pt).
    var selectionDisplaySize: (w: Int, h: Int) {
        if resolutionUnitIsPoints {
            return (Int(selectionRect.width.rounded()), Int(selectionRect.height.rounded()))
        }
        return selectionPixelSize
    }

    /// Resize from values typed in the current display unit.
    @discardableResult
    func applyDisplaySize(
        w inputW: Int,
        h inputH: Int,
        edited: ResolutionBoxView.EditedDimension = .both
    ) -> Bool {
        var w = inputW
        var h = inputH
        if let aspect = lockedAspect, aspect > 0 {
            switch edited {
            case .width:
                h = max(1, Int((CGFloat(w) / aspect).rounded()))
            case .height:
                w = max(1, Int((CGFloat(h) * aspect).rounded()))
            case .both:
                break
            }
        }
        if resolutionUnitIsPoints {
            let scale = window?.backingScaleFactor ?? 2.0
            return applyPixelSize(w: Int((CGFloat(w) * scale).rounded()),
                                  h: Int((CGFloat(h) * scale).rounded()))
        }
        return applyPixelSize(w: w, h: h)
    }

    /// Resize the selection to an exact pixel size (W×H in device pixels),
    /// center-anchored and clamped to the screen. Used by the resolution box
    /// fields and resolution presets. Returns true if it fit exactly (no clamp).
    @discardableResult
    func applyPixelSize(w pxW: Int, h pxH: Int) -> Bool {
        guard pxW > 0, pxH > 0 else { return false }
        let scale = window?.backingScaleFactor ?? 2.0
        var newW = CGFloat(pxW) / scale
        var newH = CGFloat(pxH) / scale

        // Clamp to the overlay bounds, preserving aspect so presets don't distort.
        let maxW = bounds.width
        let maxH = bounds.height
        var fits = true
        if newW > maxW || newH > maxH {
            fits = false
            let s = min(maxW / newW, maxH / newH)
            newW *= s
            newH *= s
        }

        // Center on the current selection (or screen center if no selection yet),
        // then shift fully on-screen.
        let cx = selectionRect.width > 0 ? selectionRect.midX : bounds.midX
        let cy = selectionRect.height > 0 ? selectionRect.midY : bounds.midY
        var rect = NSRect(x: cx - newW / 2, y: cy - newH / 2, width: newW, height: newH)
        rect.origin.x = max(bounds.minX, min(rect.origin.x, bounds.maxX - newW))
        rect.origin.y = max(bounds.minY, min(rect.origin.y, bounds.maxY - newH))

        selectionIsWindowSnap = false
        selectionRect = rect
        refreshResolutionAndToolbarLayout()
        refreshCursorAfterSelectionChange()
        needsDisplay = true
        return fits
    }

    /// After a programmatic selection-rect change (typed size, ratio lock,
    /// preset) the cursor is managed imperatively, so re-evaluate it for the
    /// current mouse position — otherwise the resize cursor over a handle isn't
    /// updated until the user moves the mouse.
    func refreshCursorAfterSelectionChange() {
        guard let win = window else { return }
        let p = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        updateCursorForPoint(p)
    }

    /// Lock (or clear, when nil) the selection's aspect ratio and immediately
    /// reshape the current selection to match (center-anchored, clamped).
    func applyLockedAspect(_ aspect: CGFloat?) {
        lockedAspect = aspect
        selectionIsWindowSnap = false
        guard let aspect, aspect > 0, selectionRect.width > 1 else {
            refreshResolutionAndToolbarLayout()
            needsDisplay = true
            return
        }
        // Reshape to the locked ratio, keeping area roughly similar, centered.
        let cur = selectionRect
        var w = cur.width
        var h = w / aspect
        if h > bounds.height || w > bounds.width {
            let s = min(bounds.width / w, bounds.height / h)
            w *= s; h *= s
        }
        var rect = NSRect(x: cur.midX - w / 2, y: cur.midY - h / 2, width: w, height: h)
        rect.origin.x = max(bounds.minX, min(rect.origin.x, bounds.maxX - w))
        rect.origin.y = max(bounds.minY, min(rect.origin.y, bounds.maxY - h))
        selectionRect = rect
        refreshResolutionAndToolbarLayout()
        refreshCursorAfterSelectionChange()
        needsDisplay = true
    }

    func drawResizeHandles() {
        for (_, rect) in allHandleRects() {
            ToolbarLayout.handleColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
    /// Compare two colors by RGB components (ignoring minor floating point differences)    /// Convert NSColor to hex string like "FF3B30"
    func colorToHexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }


    // MARK: - Handle hit testing

    func allHandleRects() -> [(ResizeHandle, NSRect)] {
        let r = selectionRect
        let s = handleSize
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

    func hitTestHandle(at point: NSPoint) -> ResizeHandle {
        // Use the same hit area as resizeHandleCursor so cursor and click zones match
        let hitPad: CGFloat = 2  // handle rect is already handleSize; expand by 2 to match cursor zone
        // Check corner handles first (they take priority over edges)
        for (handle, rect) in allHandleRects() {
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                if rect.insetBy(dx: -hitPad, dy: -hitPad).contains(point) {
                    return handle
                }
            default:
                break
            }
        }

        // Check full edges/borders (not just the handle dots)
        let edgeThickness: CGFloat = 6  // match resizeHandleCursor's edgeT
        let r = selectionRect
        // Top edge
        if NSRect(x: r.minX, y: r.maxY - edgeThickness / 2, width: r.width, height: edgeThickness)
            .contains(point)
        {
            return .top
        }
        // Bottom edge
        if NSRect(x: r.minX, y: r.minY - edgeThickness / 2, width: r.width, height: edgeThickness)
            .contains(point)
        {
            return .bottom
        }
        // Left edge
        if NSRect(x: r.minX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height)
            .contains(point)
        {
            return .left
        }
        // Right edge
        if NSRect(x: r.maxX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height)
            .contains(point)
        {
            return .right
        }

        return .none
    }

    func handleRectsForRect(_ r: NSRect) -> [(ResizeHandle, NSRect)] {
        let s = handleSize
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

    func hitTestRemoteHandle(at point: NSPoint) -> ResizeHandle {
        let r = remoteSelectionRect
        guard r.width >= 1, r.height >= 1 else { return .none }
        let hitPad: CGFloat = 2
        for (handle, rect) in handleRectsForRect(r) {
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                if rect.insetBy(dx: -hitPad, dy: -hitPad).contains(point) { return handle }
            default: break
            }
        }
        let edgeThickness: CGFloat = 6
        if NSRect(x: r.minX, y: r.maxY - edgeThickness / 2, width: r.width, height: edgeThickness).contains(point) { return .top }
        if NSRect(x: r.minX, y: r.minY - edgeThickness / 2, width: r.width, height: edgeThickness).contains(point) { return .bottom }
        if NSRect(x: r.minX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height).contains(point) { return .left }
        if NSRect(x: r.maxX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height).contains(point) { return .right }
        return .none
    }

    func drawRemoteResizeHandles() {
        for (_, rect) in handleRectsForRect(remoteSelectionRect) {
            ToolbarLayout.handleColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    /// Returns the anchor point (fixed corner) for a given resize handle on a rect.
    func anchorForHandle(_ handle: ResizeHandle, in r: NSRect) -> NSPoint {
        switch handle {
        case .topLeft:     return NSPoint(x: r.maxX, y: r.minY)
        case .topRight:    return NSPoint(x: r.minX, y: r.minY)
        case .bottomLeft:  return NSPoint(x: r.maxX, y: r.maxY)
        case .bottomRight: return NSPoint(x: r.minX, y: r.maxY)
        case .top:         return NSPoint(x: r.midX, y: r.minY)
        case .bottom:      return NSPoint(x: r.midX, y: r.maxY)
        case .left:        return NSPoint(x: r.maxX, y: r.midY)
        case .right:       return NSPoint(x: r.minX, y: r.midY)
        case .none, .move:  return .zero
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        justDismissedTextEditor = false  // reset per click; set below if we commit one

        // Anchored selection commit: a left-click while the right-click-
        // anchored tracker is live finalizes the selection and returns to
        // the standard flow. Do this BEFORE any other mouseDown handling so
        // we don't accidentally restart the selection from the click point.
        if isAnchoredSelecting {
            updateSelectionRect(to: point, shiftHeld: event.modifierFlags.contains(.shift), modifiers: event.modifierFlags)
            commitAnchoredSelection()
            return
        }

        // Update pressure for tablet/Sidecar (0.0 for non-tablet events → treat as 1.0)
        let p = event.pressure
        #if PRESSURE_EMULATION
        // Debug: simulate pressure from mouse speed. Slow = heavy (1.0), fast = light (0.2).
        // Uses deltaX/deltaY from the event to compute instantaneous speed.
        let speed = hypot(event.deltaX, event.deltaY)
        let simulated = max(0.2, min(1.0, 1.0 - speed / 40.0))
        currentPressure = simulated
        #else
        currentPressure = p > 0 ? CGFloat(p) : 1.0
        #endif

        // Auto-measure: click to commit the preview annotation
        if autoMeasureKeyHeld, let preview = autoMeasurePreview {
            annotations.append(preview)
            undoStack.append(.added(preview))
            redoStack.removeAll()
            autoMeasurePreview = nil
            cachedCompositedImage = nil
            // Recompute a new preview at the current position
            updateAutoMeasurePreview()
            return
        }

        // Note: toolbar strips and options row are routed by hitTest() — they never reach here
        if preSelectionPresetButton?.isHidden == false && preSelectionPresetButtonRect.contains(point) {
            return
        }

        // Control-click = right-click for color sampler (supports BetterTouchTool and other tools
        // that simulate right-click via control-click instead of rightMouseDown)
        if event.modifierFlags.contains(.control) && state == .selected
            && currentTool == .colorSampler
        {
            if let screenshot = screenshotImage,
                let result = sampleColor(from: screenshot, at: viewToCanvas(point))
            {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.hex, forType: .string)
                showOverlayError(String(format: L("Copied %@"), result.hex))
                needsDisplay = true
            }
            return
        }

        // Control-click on line/arrow: add anchor point (same as right-click)
        if event.modifierFlags.contains(.control) && state == .selected {
            if let ann = selectedAnnotation,
                ann.tool == .arrow || ann.tool == .line || ann.tool == .measure
            {
                let canvasPoint = viewToCanvas(point)
                if ann.hitTest(point: canvasPoint) {
                    addAnchorPoint(to: ann, at: canvasPoint)
                    cachedCompositedImage = nil
                    needsDisplay = true
                    return
                }
            }
        }

        // Editor top bar button clicks
        if handleTopChromeClick(at: point) {
            return
        }

        if state == .selected
            && isDoubleClickToCopyEnabled
            && textEditor.isEditing
            && handleDoubleClickToCopy(event: event, at: point)
        {
            return
        }

        let isTextEditing = textEditView != nil

        // Check text box resize handles when editing
        if isTextEditing && showToolbars {
            // Check text box resize handles
            if let sv = textEditor.scrollView {
                let hs: CGFloat = 10  // hit area
                let f = sv.frame
                let handles: [(ResizeHandle, NSRect)] = [
                    (
                        .bottomLeft,
                        NSRect(x: f.minX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .bottomRight,
                        NSRect(x: f.maxX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .topLeft,
                        NSRect(x: f.minX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .topRight,
                        NSRect(x: f.maxX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .bottom,
                        NSRect(x: f.midX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (.top, NSRect(x: f.midX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)),
                    (.left, NSRect(x: f.minX - hs / 2, y: f.midY - hs / 2, width: hs, height: hs)),
                    (.right, NSRect(x: f.maxX - hs / 2, y: f.midY - hs / 2, width: hs, height: hs)),
                ]
                for (handle, rect) in handles {
                    if rect.contains(point) {
                        isResizingTextBox = true
                        textBoxResizeHandle = handle
                        textBoxResizeStart = point
                        textBoxOrigFrame = f
                        return
                    }
                }
            }
            // Clicking on the text editor itself — don't commit
            if let sv = textEditor.scrollView, sv.frame.contains(point) {
                return
            }
        }

        // Don't commit text if clicking on text formatting controls in the options row
        let isTextFormattingClick =
            textEditView != nil && currentTool == .text
            && ((toolOptionsRowView?.frame.contains(point) ?? false))
        // A click that dismisses an open text editor should NOT also place a new
        // text box where it landed — remember that we just committed one so the
        // text-tool dispatch (startAnnotation) skips creating a new field.
        justDismissedTextEditor = textEditor.isEditing && !isTextFormattingClick
        if !isTextFormattingClick {
            commitTextFieldIfNeeded()
        }

        // Double-click to copy: when the setting is on, two fast clicks inside the
        // selection confirm the capture. Annotations the first click added (and any
        // in-progress second-click annotation) are rewound first via the undo stack
        // so the copied image looks like nothing was drawn during the double-click.
        if state == .selected
            && isDoubleClickToCopyEnabled
            && handleDoubleClickToCopy(event: event, at: point)
        {
            return
        }

        switch state {
        case .idle:
            // Check remote selection handles for cross-screen resize
            if remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
                let remoteHandle = hitTestRemoteHandle(at: point)
                if remoteHandle != .none {
                    isResizingRemoteSelection = true
                    remoteResizeHandle = remoteHandle
                    remoteResizeAnchor = anchorForHandle(remoteHandle, in: remoteSelectionFullRect)
                    return
                }
                return
            }
            // Always start a drag — snap is resolved in mouseUp if no real drag occurred
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            overlayDelegate?.overlayViewDidBeginSelection()
            needsDisplay = true

        case .selected:
            // Sticky color wheel: click to pick a color
            if colorWheel.isVisible && colorWheel.isSticky {
                colorWheel.updateHover(at: point)
                if let hoveredColor = colorWheel.hoveredColor {
                    currentColor = hoveredColor
                    applyColorToTextIfEditing()
                    applyColorToSelectedAnnotation()
                    rebuildToolbarLayout()
                }
                colorWheel.dismiss()
                needsDisplay = true
                return
            }

            // Resolution box is a real interactive subview — clicks inside it are
            // handled by the view itself (don't intercept here).
            if resolutionBoxRect != .zero && resolutionBoxRect.contains(point) {
                return
            }

            // Check handles (disabled in editor)
            if shouldAllowSelectionResize() {
                let handle = hitTestHandle(at: point)
                if handle != .none {
                    isResizingSelection = true
                    selectionIsWindowSnap = false
                    snappedWindowID = nil
                    snappedWindowImage = nil
                    resizeHandle = handle
                    return
                }
            }

            // Crop tool drag (use canvas coords so it aligns with the image)
            if currentTool == .crop && pointIsInSelection(point) {
                isCropDragging = true
                cropDragStart = viewToCanvas(point)
                cropDragRect = .zero
                needsDisplay = true
                return
            }

            // Color sampler works anywhere on the screenshot, not just inside selection
            if currentTool == .colorSampler {
                let canvasPoint = viewToCanvas(point)
                startAnnotation(at: canvasPoint)
                return
            }

            // Start annotation (convert to canvas space for zoom).
            // Require the click to be inside the selection rectangle.
            if currentTool != .crop && pointIsInSelection(point) {
                let canvasPoint = viewToCanvas(point)
                startAnnotation(at: canvasPoint)
                return
            }

            // Outside the selection — historically this reset everything to
            // start a new selection, but accidental clicks outside an
            // established selection were destroying in-progress annotation
            // work (#154). Treat outside clicks as a no-op once we have a
            // committed selection; ESC still cancels deliberately.
            return

        case .selecting:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Cancel long-press timer if the user moved more than 3px (they're drawing, not selecting)
        if longPressTimer != nil {
            let dx = point.x - longPressPoint.x
            let dy = point.y - longPressPoint.y
            if dx * dx + dy * dy > 9 {
                longPressTimer?.invalidate()
                longPressTimer = nil
            }
        }

        // If long-press already triggered selection, handle as annotation drag
        if longPressTriggered && isDraggingAnnotation {
            // Fall through to the annotation drag handling below
        }

        // Remote selection resize (cross-screen)
        if isResizingRemoteSelection {
            let anchor = remoteResizeAnchor
            let fullRect = remoteSelectionFullRect
            var newRect = NSRect(
                x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            // For edge handles, preserve the dimension that shouldn't change
            switch remoteResizeHandle {
            case .top, .bottom:
                newRect.origin.x = fullRect.origin.x
                newRect.size.width = fullRect.width
            case .left, .right:
                newRect.origin.y = fullRect.origin.y
                newRect.size.height = fullRect.height
            default: break
            }
            // Update full rect and clip for local display
            remoteSelectionFullRect = newRect
            let screenBounds = NSRect(origin: .zero, size: bounds.size)
            let clipped = newRect.intersection(screenBounds)
            remoteSelectionRect = clipped.isEmpty ? .zero : clipped
            // Update primary + other screens
            overlayDelegate?.overlayViewRemoteSelectionDidChange(newRect)
            needsDisplay = true
            return
        }

        // Crop drag update (in canvas coords)
        if isCropDragging {
            let canvasPt = viewToCanvas(point)
            let clampedPoint = NSPoint(
                x: max(selectionRect.minX, min(canvasPt.x, selectionRect.maxX)),
                y: max(selectionRect.minY, min(canvasPt.y, selectionRect.maxY))
            )
            let origin = NSPoint(
                x: min(cropDragStart.x, clampedPoint.x), y: min(cropDragStart.y, clampedPoint.y))
            cropDragRect = NSRect(
                origin: origin,
                size: NSSize(
                    width: abs(clampedPoint.x - cropDragStart.x),
                    height: abs(clampedPoint.y - cropDragStart.y)))
            needsDisplay = true
            return
        }

        // Handle text box resize
        if isResizingTextBox, let sv = textEditor.scrollView, let tv = textEditView {
            let dx = point.x - textBoxResizeStart.x
            let dy = point.y - textBoxResizeStart.y
            let orig = textBoxOrigFrame
            var newFrame = orig
            let minW: CGFloat = 60
            let minH: CGFloat = max(28, textEditor.fontSize + 12)

            switch textBoxResizeHandle {
            case .right: newFrame.size.width = max(minW, orig.width + dx)
            case .left:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
            case .top: newFrame.size.height = max(minH, orig.height + dy)
            case .bottom:
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            case .topRight:
                newFrame.size.width = max(minW, orig.width + dx)
                newFrame.size.height = max(minH, orig.height + dy)
            case .topLeft:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
                newFrame.size.height = max(minH, orig.height + dy)
            case .bottomRight:
                newFrame.size.width = max(minW, orig.width + dx)
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            case .bottomLeft:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            default: break
            }

            sv.frame = newFrame
            tv.frame.size = newFrame.size
            tv.textContainer?.containerSize = NSSize(
                width: newFrame.width - tv.textContainerInset.width * 2,
                height: CGFloat.greatestFiniteMagnitude)
            needsDisplay = true
            return
        }

        switch state {
        case .selecting:
            updateSelectionRect(to: point, shiftHeld: event.modifierFlags.contains(.shift), modifiers: event.modifierFlags)

        case .selected:
            // Convert to canvas space for annotation interactions (accounts for zoom)
            let canvasPoint = viewToCanvas(point)
            if isRotatingAnnotation, let annotation = selectedAnnotation {
                let center = NSPoint(
                    x: annotation.boundingRect.midX, y: annotation.boundingRect.midY)
                let currentAngle = atan2(canvasPoint.x - center.x, canvasPoint.y - center.y)
                var newRotation = rotationOriginal - (currentAngle - rotationStartAngle)
                // Shift: snap to 45° steps
                if NSEvent.modifierFlags.contains(.shift) {
                    let step = CGFloat.pi / 4
                    newRotation = (newRotation / step).rounded() * step
                }
                annotation.rotation = newRotation
                needsDisplay = true
                return
            }
            if isResizingAnnotation, let annotation = selectedAnnotation {
                if spaceRepositioning {
                    let dx = canvasPoint.x - spaceRepositionLast.x
                    let dy = canvasPoint.y - spaceRepositionLast.y
                    annotation.move(dx: dx, dy: dy)
                    annotationResizeOrigStart.x += dx
                    annotationResizeOrigStart.y += dy
                    annotationResizeOrigEnd.x += dx
                    annotationResizeOrigEnd.y += dy
                    annotationResizeOrigTextOrigin.x += dx
                    annotationResizeOrigTextOrigin.y += dy
                    annotationResizeOrigControlPoint.x += dx
                    annotationResizeOrigControlPoint.y += dy
                    annotationResizeMouseStart.x += dx
                    annotationResizeMouseStart.y += dy
                    spaceRepositionLast = canvasPoint
                    if annotation.tool == .loupe {
                        annotation.bakedBlurNSImage = nil
                        annotation.bakeLoupe()
                    }
                    if annotation.tool == .pixelate { annotation.bakedBlurNSImage = nil }
                    cachedCompositedImage = nil
                    needsDisplay = true
                    return
                }

                let dx = canvasPoint.x - annotationResizeMouseStart.x
                let dy = canvasPoint.y - annotationResizeMouseStart.y
                let origStart = annotationResizeOrigStart
                let origEnd = annotationResizeOrigEnd

                // Text annotations: resize the text box and re-render textImage
                if annotation.tool == .text {
                    let origRect = NSRect(origin: origStart,
                        size: NSSize(width: origEnd.x - origStart.x, height: origEnd.y - origStart.y))
                    var newRect = origRect
                    let minW: CGFloat = 40
                    // Minimum height must fit the actual rendered line height
                    // (ascent+descent+leading ≈ 1.2–1.3× font size), not just the
                    // point size, or the text clips at the bottom and floats with
                    // a gap at the top. Measure it from the string when available.
                    let textInset: CGFloat = 4
                    let lineHeight: CGFloat
                    if let attrStr = annotation.attributedText, attrStr.length > 0 {
                        lineHeight = ceil(attrStr.boundingRect(
                            with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
                    } else {
                        lineHeight = ceil(annotation.fontSize * 1.3)
                    }
                    let minH: CGFloat = max(20, lineHeight + textInset * 2)

                    switch annotationResizeHandle {
                    case .right: newRect.size.width = max(minW, origRect.width + dx)
                    case .left:
                        newRect.origin.x = min(origRect.maxX - minW, origRect.minX + dx)
                        newRect.size.width = origRect.maxX - newRect.minX
                    case .top:
                        newRect.size.height = max(minH, origRect.height + dy)
                    case .bottom:
                        let newMinY = min(origRect.maxY - minH, origRect.minY + dy)
                        newRect.origin.y = newMinY
                        newRect.size.height = origRect.maxY - newMinY
                    case .topRight:
                        newRect.size.width = max(minW, origRect.width + dx)
                        newRect.size.height = max(minH, origRect.height + dy)
                    case .topLeft:
                        newRect.origin.x = min(origRect.maxX - minW, origRect.minX + dx)
                        newRect.size.width = origRect.maxX - newRect.minX
                        newRect.size.height = max(minH, origRect.height + dy)
                    case .bottomRight:
                        newRect.size.width = max(minW, origRect.width + dx)
                        let newMinY = min(origRect.maxY - minH, origRect.minY + dy)
                        newRect.origin.y = newMinY
                        newRect.size.height = origRect.maxY - newMinY
                    case .bottomLeft:
                        newRect.origin.x = min(origRect.maxX - minW, origRect.minX + dx)
                        newRect.size.width = origRect.maxX - newRect.minX
                        let newMinY = min(origRect.maxY - minH, origRect.minY + dy)
                        newRect.origin.y = newMinY
                        newRect.size.height = origRect.maxY - newMinY
                    default: break
                    }

                    annotation.startPoint = newRect.origin
                    annotation.endPoint = NSPoint(x: newRect.maxX, y: newRect.maxY)
                    annotation.textDrawRect = newRect
                    // Re-render textImage at new size through the outline layout
                    // manager so a per-glyph outline stays outside the fill (#257).
                    if let attrStr = annotation.attributedText {
                        annotation.textImage = OutlineTextRenderer.renderImage(
                            attrStr, size: newRect.size, inset: 4)
                    }
                    cachedCompositedImage = nil
                    needsDisplay = true
                    break
                }

                let shiftHeld = event.modifierFlags.contains(.shift)

                if annotation.tool == .number {
                    switch annotationResizeHandle {
                    case .bottomLeft:
                        let pointerWasCollapsed =
                            hypot(origEnd.x - origStart.x, origEnd.y - origStart.y) <= 4
                        annotation.startPoint = canvasPoint
                        if pointerWasCollapsed {
                            annotation.endPoint = canvasPoint
                        }
                    case .topRight:
                        var newTip = canvasPoint
                        if shiftHeld {
                            let dx = canvasPoint.x - annotation.startPoint.x
                            let dy = canvasPoint.y - annotation.startPoint.y
                            let angle = atan2(dy, dx)
                            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                            let distance = hypot(dx, dy)
                            newTip = NSPoint(
                                x: annotation.startPoint.x + distance * cos(snapped),
                                y: annotation.startPoint.y + distance * sin(snapped))
                        }
                        annotation.endPoint = newTip
                    default:
                        break
                    }
                    cachedCompositedImage = nil
                    needsDisplay = true
                    return
                }

                // Arrow/line/measure: .bottomLeft = startPoint, .topRight = endPoint, others = anchor points
                if annotation.tool == .arrow || annotation.tool == .line
                    || annotation.tool == .measure
                {
                    let newPt = NSPoint(
                        x: annotationResizeOrigControlPoint.x + dx,
                        y: annotationResizeOrigControlPoint.y + dy)
                    switch annotationResizeHandle {
                    case .bottomLeft:
                        var newStart = NSPoint(x: origStart.x + dx, y: origStart.y + dy)
                        if shiftHeld {
                            let anchor = annotation.endPoint
                            let ddx = newStart.x - anchor.x
                            let ddy = newStart.y - anchor.y
                            let angle = atan2(ddy, ddx)
                            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                            let dist = hypot(ddx, ddy)
                            newStart = NSPoint(
                                x: anchor.x + dist * cos(snapped), y: anchor.y + dist * sin(snapped)
                            )
                        }
                        if annotation.tool == .measure && currentMeasureClampToSelection {
                            newStart = shiftHeld
                                ? newStart.clampedAlongRay(from: annotation.endPoint, in: selectionRect)
                                : newStart.clampedToRect(selectionRect)
                        }
                        annotation.startPoint = newStart
                        if var anchors = annotation.anchorPoints, !anchors.isEmpty {
                            anchors[0] = newStart
                            annotation.anchorPoints = anchors
                        }
                    case .topRight:
                        var newEnd = NSPoint(x: origEnd.x + dx, y: origEnd.y + dy)
                        if shiftHeld {
                            let anchor = annotation.startPoint
                            let ddx = newEnd.x - anchor.x
                            let ddy = newEnd.y - anchor.y
                            let angle = atan2(ddy, ddx)
                            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                            let dist = hypot(ddx, ddy)
                            newEnd = NSPoint(
                                x: anchor.x + dist * cos(snapped), y: anchor.y + dist * sin(snapped)
                            )
                        }
                        if annotation.tool == .measure && currentMeasureClampToSelection {
                            newEnd = shiftHeld
                                ? newEnd.clampedAlongRay(from: annotation.startPoint, in: selectionRect)
                                : newEnd.clampedToRect(selectionRect)
                        }
                        annotation.endPoint = newEnd
                        if var anchors = annotation.anchorPoints, anchors.count >= 2 {
                            anchors[anchors.count - 1] = newEnd
                            annotation.anchorPoints = anchors
                        }
                    default:
                        // Dragging an anchor point (multi-anchor or legacy controlPoint)
                        if annotationResizeAnchorIndex >= 0, var anchors = annotation.anchorPoints {
                            if annotationResizeAnchorIndex < anchors.count {
                                anchors[annotationResizeAnchorIndex] = newPt
                                annotation.anchorPoints = anchors
                                // Keep start/end in sync
                                annotation.startPoint = anchors.first!
                                annotation.endPoint = anchors.last!
                            }
                        } else {
                            // Legacy single controlPoint
                            annotation.controlPoint = newPt
                        }
                    }
                } else {
                    // Work in bounding-rect space so resize is correct regardless of draw direction
                    let origMinX = min(origStart.x, origEnd.x)
                    let origMaxX = max(origStart.x, origEnd.x)
                    let origMinY = min(origStart.y, origEnd.y)
                    let origMaxY = max(origStart.y, origEnd.y)
                    var newMinX = origMinX
                    var newMaxX = origMaxX
                    var newMinY = origMinY
                    var newMaxY = origMaxY

                    switch annotationResizeHandle {
                    case .topLeft:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .topRight:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .bottomLeft:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .bottomRight:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .top:
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .bottom:
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .left:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                    case .right:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                    default:
                        break
                    }

                    // Loupe is always circular; shift forces square/circle for other shape corner handles.
                    if annotation.tool == .loupe {
                        let w = newMaxX - newMinX
                        let h = newMaxY - newMinY
                        let side: CGFloat
                        switch annotationResizeHandle {
                        case .left, .right:
                            side = max(40, w)
                        case .top, .bottom:
                            side = max(40, h)
                        default:
                            side = max(40, max(w, h))
                        }
                        let centerX = (origMinX + origMaxX) / 2
                        let centerY = (origMinY + origMaxY) / 2
                        switch annotationResizeHandle {
                        case .topLeft:
                            newMinX = origMaxX - side
                            newMaxX = origMaxX
                            newMinY = origMinY
                            newMaxY = origMinY + side
                        case .topRight:
                            newMinX = origMinX
                            newMaxX = origMinX + side
                            newMinY = origMinY
                            newMaxY = origMinY + side
                        case .bottomLeft:
                            newMinX = origMaxX - side
                            newMaxX = origMaxX
                            newMinY = origMaxY - side
                            newMaxY = origMaxY
                        case .bottomRight:
                            newMinX = origMinX
                            newMaxX = origMinX + side
                            newMinY = origMaxY - side
                            newMaxY = origMaxY
                        case .top:
                            newMinX = centerX - side / 2
                            newMaxX = centerX + side / 2
                            newMinY = origMinY
                            newMaxY = origMinY + side
                        case .bottom:
                            newMinX = centerX - side / 2
                            newMaxX = centerX + side / 2
                            newMinY = origMaxY - side
                            newMaxY = origMaxY
                        case .left:
                            newMinX = origMaxX - side
                            newMaxX = origMaxX
                            newMinY = centerY - side / 2
                            newMaxY = centerY + side / 2
                        case .right:
                            newMinX = origMinX
                            newMaxX = origMinX + side
                            newMinY = centerY - side / 2
                            newMaxY = centerY + side / 2
                        default:
                            break
                        }
                        annotation.strokeWidth = side
                    } else if annotation.tool == .stamp {
                        // Stamps always keep their aspect ratio, whichever handle is dragged.
                        let origW = max(origMaxX - origMinX, 1)
                        let origH = max(origMaxY - origMinY, 1)
                        var scale: CGFloat
                        switch annotationResizeHandle {
                        case .left, .right:
                            scale = (newMaxX - newMinX) / origW
                        case .top, .bottom:
                            scale = (newMaxY - newMinY) / origH
                        default:
                            scale = max((newMaxX - newMinX) / origW, (newMaxY - newMinY) / origH)
                        }
                        scale = max(scale, 10 / min(origW, origH))
                        let w = origW * scale
                        let h = origH * scale
                        let centerX = (origMinX + origMaxX) / 2
                        let centerY = (origMinY + origMaxY) / 2
                        switch annotationResizeHandle {
                        case .topLeft:
                            newMinX = origMaxX - w
                            newMaxX = origMaxX
                            newMinY = origMinY
                            newMaxY = origMinY + h
                        case .topRight:
                            newMinX = origMinX
                            newMaxX = origMinX + w
                            newMinY = origMinY
                            newMaxY = origMinY + h
                        case .bottomLeft:
                            newMinX = origMaxX - w
                            newMaxX = origMaxX
                            newMinY = origMaxY - h
                            newMaxY = origMaxY
                        case .bottomRight:
                            newMinX = origMinX
                            newMaxX = origMinX + w
                            newMinY = origMaxY - h
                            newMaxY = origMaxY
                        case .top:
                            newMinX = centerX - w / 2
                            newMaxX = centerX + w / 2
                            newMinY = origMinY
                            newMaxY = origMinY + h
                        case .bottom:
                            newMinX = centerX - w / 2
                            newMaxX = centerX + w / 2
                            newMinY = origMaxY - h
                            newMaxY = origMaxY
                        case .left:
                            newMinX = origMaxX - w
                            newMaxX = origMaxX
                            newMinY = centerY - h / 2
                            newMaxY = centerY + h / 2
                        case .right:
                            newMinX = origMinX
                            newMaxX = origMinX + w
                            newMinY = centerY - h / 2
                            newMaxY = centerY + h / 2
                        default:
                            break
                        }
                    } else if shiftHeld {
                        let w = newMaxX - newMinX
                        let h = newMaxY - newMinY
                        let side = max(w, h)
                        switch annotationResizeHandle {
                        case .topLeft:
                            newMinX = newMaxX - side
                            newMaxY = newMinY + side
                        case .topRight:
                            newMaxX = newMinX + side
                            newMaxY = newMinY + side
                        case .bottomLeft:
                            newMinX = newMaxX - side
                            newMinY = newMaxY - side
                        case .bottomRight:
                            newMaxX = newMinX + side
                            newMinY = newMaxY - side
                        default: break
                        }
                    }

                    annotation.startPoint = NSPoint(x: newMinX, y: newMinY)
                    annotation.endPoint = NSPoint(x: newMaxX, y: newMaxY)
                    if annotation.tool == .loupe {
                        // Two-circle loupe: resizing the lens keeps the zoom
                        // (magnification) fixed and re-frames the source so it
                        // still outlines exactly what the lens shows.
                        annotation.syncLoupeSourceToMagnification()
                        annotation.bakedBlurNSImage = nil
                        annotation.bakeLoupe()
                    }
                }
                if annotation.tool == .pixelate { annotation.bakedBlurNSImage = nil }
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isLassoSelecting {
                // Update lasso marquee rectangle
                let x = min(lassoStart.x, canvasPoint.x)
                let y = min(lassoStart.y, canvasPoint.y)
                let w = abs(canvasPoint.x - lassoStart.x)
                let h = abs(canvasPoint.y - lassoStart.y)
                lassoRect = NSRect(x: x, y: y, width: w, height: h)
                needsDisplay = true
            } else if isResizingLoupeSource, let loupe = selectedAnnotation, loupe.tool == .loupe {
                // Resize the source circle by dragging its handle → changes zoom.
                // magnification = lensSize / sourceSize; the source is re-framed to
                // match via syncLoupeSourceToMagnification on the next draw/bake.
                let cx = loupeSourceDragOrig.midX, cy = loupeSourceDragOrig.midY
                let newR = max(6, hypot(canvasPoint.x - cx, canvasPoint.y - cy))
                let lensSize = loupe.loupeLensSquareRect.width
                let mag = max(1.1, min(12, lensSize / (newR * 2)))
                loupe.loupeMagnification = mag
                let newSize = lensSize / mag
                loupe.loupeSourceRect = NSRect(x: cx - newSize / 2, y: cy - newSize / 2,
                                               width: newSize, height: newSize)
                loupe.bakedBlurNSImage = nil
                loupe.bakeLoupe()
                didMoveAnnotation = true
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingLoupeSource, let loupe = selectedAnnotation, loupe.tool == .loupe {
                // Move the rooted source circle independently; the lens stays put
                // and the connecting line re-adjusts. Magnification is kept, so
                // the source size is unchanged.
                let dx = canvasPoint.x - loupeSourceDragStart.x
                let dy = canvasPoint.y - loupeSourceDragStart.y
                loupe.loupeSourceRect = loupeSourceDragOrig.offsetBy(dx: dx, dy: dy)
                loupe.bakedBlurNSImage = nil
                loupe.bakeLoupe()
                didMoveAnnotation = true
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingAnnotation, !selectedAnnotations.isEmpty {
                // Snapshot the pre-move state once, on the first actual move, so
                // the drag can be recorded as an undo entry on mouseUp (which also
                // makes "move existing shape" register as an edit).
                if !didMoveAnnotation {
                    preMoveSnapshots = selectedAnnotations.map { ($0, $0.clone()) }
                }
                let rawDx = canvasPoint.x - annotationDragStart.x
                let rawDy = canvasPoint.y - annotationDragStart.y
                // For single selection, apply snap; for multi, just move raw
                let finalDx: CGFloat
                let finalDy: CGFloat
                if selectedAnnotations.count == 1, let annotation = selectedAnnotations.first {
                    let movedRect = annotation.boundingRect.offsetBy(dx: rawDx, dy: rawDy)
                    let snap = snapRectDelta(rect: movedRect, excluding: annotation)
                    finalDx = rawDx + snap.dx
                    finalDy = rawDy + snap.dy
                    annotationDragStart = NSPoint(
                        x: canvasPoint.x + snap.dx, y: canvasPoint.y + snap.dy)
                } else {
                    finalDx = rawDx
                    finalDy = rawDy
                    annotationDragStart = canvasPoint
                }
                for annotation in selectedAnnotations {
                    annotation.move(dx: finalDx, dy: finalDy)
                    if annotation.tool == .loupe {
                        annotation.bakedBlurNSImage = nil
                        annotation.bakeLoupe()
                    }
                }
                didMoveAnnotation = true
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingSelection {
                var moved = selectionRect
                moved.origin = NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
                selectionRect = boundarySnappedMovedRect(moved, modifiers: event.modifierFlags)
                updateResolutionBox()
                needsDisplay = true
            } else if isResizingSelection {
                if spaceRepositioning {
                    let dx = point.x - spaceRepositionLast.x
                    let dy = point.y - spaceRepositionLast.y
                    var moved = selectionRect
                    moved.origin.x += dx
                    moved.origin.y += dy
                    selectionRect = boundarySnappedMovedRect(moved, modifiers: event.modifierFlags)
                    spaceRepositionLast = point
                } else {
                    resizeSelection(to: point, modifiers: event.modifierFlags)
                }
                overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
                updateResolutionBox()
                needsDisplay = true
            } else if let annotationInProgress = currentAnnotation {
                if spaceRepositioning {
                    // Space held: reposition the whole shape
                    let dx = canvasPoint.x - spaceRepositionLast.x
                    let dy = canvasPoint.y - spaceRepositionLast.y
                    annotationInProgress.startPoint.x += dx
                    annotationInProgress.startPoint.y += dy
                    annotationInProgress.endPoint.x += dx
                    annotationInProgress.endPoint.y += dy
                    if let points = annotationInProgress.points {
                        annotationInProgress.points = points.map {
                            NSPoint(x: $0.x + dx, y: $0.y + dy)
                        }
                    }
                    spaceRepositionLast = canvasPoint
                } else {
                    let p = event.pressure
                    #if PRESSURE_EMULATION
                    let speed = hypot(event.deltaX, event.deltaY)
                    currentPressure = max(0.2, min(1.0, 1.0 - speed / 40.0))
                    #else
                    currentPressure = p > 0 ? CGFloat(p) : 1.0
                    #endif
                    updateAnnotation(
                        at: canvasPoint, shiftHeld: event.modifierFlags.contains(.shift))
                }
                lastDragPoint = canvasPoint
                needsDisplay = true
            }

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        spaceRepositioning = false

        // Any drag that used boundary snap is ending — clear its guide lines.
        boundarySnapGuideX = nil
        boundarySnapGuideY = nil

        // Clean up long-press timer
        longPressTimer?.invalidate()
        longPressTimer = nil
        longPressTriggered = false

        // Finish remote selection resize — final sync + transfer focus to the primary
        if isResizingRemoteSelection {
            isResizingRemoteSelection = false
            remoteResizeHandle = .none
            overlayDelegate?.overlayViewRemoteSelectionDidFinish(remoteSelectionFullRect)
            return
        }

        // Crop commit
        if isCropDragging {
            isCropDragging = false
            let rect = cropDragRect
            cropDragRect = .zero
            if rect.width > 4 && rect.height > 4 {
                commitCrop(viewRect: rect)
            }
            needsDisplay = true
            return
        }

        if isResizingTextBox {
            isResizingTextBox = false
            return
        }
        if isRotatingAnnotation {
            isRotatingAnnotation = false
            commitAnnotationManipulationUndo()
            cachedAnnotationLayerExcludingSelected = nil
            cachedAnnotationLayer = nil
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        if isDraggingLoupeSource || isResizingLoupeSource {
            let wasResize = isResizingLoupeSource
            isDraggingLoupeSource = false
            isResizingLoupeSource = false
            commitAnnotationManipulationUndo()
            cachedAnnotationLayerExcludingSelected = nil
            cachedAnnotationLayer = nil
            if let ann = selectedAnnotation, ann.tool == .loupe {
                ann.bakedBlurNSImage = nil
                ann.bakeLoupe()
                if wasResize {
                    // Reflect the new zoom in the options row slider/label.
                    toolOptionsRowView?.rebuild(forAnnotation: ann)
                }
            }
            cachedCompositedImage = nil
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        if isResizingAnnotation {
            isResizingAnnotation = false
            commitAnnotationManipulationUndo()
            cachedAnnotationLayerExcludingSelected = nil
            cachedAnnotationLayer = nil
            annotationResizeHandle = .none
            if let ann = selectedAnnotation {
                if ann.tool == .loupe { ann.bakeLoupe() }
                if ann.tool == .pixelate { ann.bakedBlurNSImage = nil; ann.bakePixelate() }
                if ann.tool == .stamp && !ann.isCaptureStamp {
                    // Remember the size so the next stamp is placed to match.
                    setActiveStampSize(max(ann.boundingRect.width, ann.boundingRect.height))
                }
                toolOptionsRowView?.rebuild(forAnnotation: ann)
            }
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        lastDragPoint = nil
        switch state {
        case .selecting:
            finishSelection()

        case .selected:
            if isLassoSelecting {
                isLassoSelecting = false
                // Select all annotations whose bounding rect intersects the lasso
                if lassoRect.width > 2 && lassoRect.height > 2 {
                    let selected = annotations.filter { $0.isMovable && $0.boundingRect.intersects(lassoRect) }
                    if !selected.isEmpty {
                        selectedAnnotations = selected
                    }
                }
                lassoRect = .zero
                needsDisplay = true
            } else if isDraggingAnnotation {
                // Deferred ctrl+click deselect: only remove the annotation if
                // the user didn't drag (i.e. it was a click, not a move).
                if let pending = shiftClickPendingDeselect {
                    shiftClickPendingDeselect = nil
                    if !didMoveAnnotation {
                        if let idx = selectedAnnotations.firstIndex(where: { $0 === pending }) {
                            selectedAnnotations.remove(at: idx)
                        }
                    }
                }
                // Record the move as an undo entry (and an edit) if anything
                // actually moved. Each dragged annotation gets its own entry.
                commitAnnotationManipulationUndo()
                isDraggingAnnotation = false
                didMoveAnnotation = false
                cachedAnnotationLayerExcludingSelected = nil
                cachedAnnotationLayer = nil
                snapGuideX = nil
                snapGuideY = nil
                NSCursor.openHand.set()
                for ann in selectedAnnotations {
                    if ann.tool == .loupe { ann.bakeLoupe() }
                    if ann.tool == .pixelate { ann.bakedBlurNSImage = nil; ann.bakePixelate() }
                }
                // Auto-expand canvas if annotation was dragged outside bounds (editor mode)
                expandCanvasToFitAnnotations()
                needsDisplay = true
            } else if isDraggingSelection {
                isDraggingSelection = false
                needsDisplay = true
            } else if isResizingSelection {
                isResizingSelection = false
                resizeHandle = .none
                boundarySnapGuideX = nil
                boundarySnapGuideY = nil
                if let win = window {
                    updateCursorForPoint(convert(win.mouseLocationOutsideOfEventStream, from: nil))
                }
                needsDisplay = true
            } else if let annotation = currentAnnotation {
                finishAnnotation(annotation)
            }

        default:
            break
        }
    }

    /// Handle the "double-click to copy" feature. Called from `mouseDown` when the setting
    /// is enabled and `state == .selected`. Returns true when the event was consumed.
    ///
    /// On the first click we snapshot the undo-stack depth. On the second click (clickCount >= 2)
    /// inside the selection we rewind the stack to that snapshot — removing any annotation the
    /// first click finished — cancel any in-progress drawing, then trigger confirm.
    func handleDoubleClickToCopy(event: NSEvent, at point: NSPoint) -> Bool {
        // A double-click landing on an existing text annotation should never
        // "copy" — it means "edit that text" (issue #287). Return false so the
        // downstream edit paths (text-tool inline / select-tool handler) run.
        // For tools that don't route into text editing (e.g. crop, colorSampler)
        // this simply suppresses the accidental copy, which is the safe outcome.
        //
        // Only while NOT already editing: when a text field is open, the
        // in-editor double-click-to-copy path (deadline logic below) owns this
        // gesture, and another committed text box happening to sit under the
        // click must not hijack it.
        if !textEditor.isEditing {
            let hitText = annotations.reversed().contains(where: {
                $0.tool == .text && $0.hitTest(point: point)
            }) || (selectedAnnotation?.tool == .text && selectedAnnotation?.hitTest(point: point) == true)
            if hitText {
                textToolDoubleClickCopyDeadline = 0
                return false
            }
        }

        if textEditor.isEditing {
            guard hasPendingTextToolDoubleClickCopy(for: event) else { return false }
        }

        if event.clickCount >= 2 {
            if textEditor.isEditing {
                commitTextFieldIfNeeded()
                doubleClickUndoBaseline = undoStack.count
            }
            guard pointIsInSelection(point) else {
                // Outside selection: no drawing occurred — just confirm.
                doubleClickUndoBaseline = nil
                textToolDoubleClickCopyDeadline = 0
                overlayDelegate?.overlayViewDidConfirm()
                return true
            }
            // Cancel any in-progress annotation from this second click.
            currentAnnotation = nil
            // Rewind the undo stack to the baseline captured on the first click,
            // popping the annotation(s) the first click finished.
            if let baseline = doubleClickUndoBaseline {
                while undoStack.count > baseline { undo() }
            }
            doubleClickUndoBaseline = nil
            textToolDoubleClickCopyDeadline = 0
            // Clear caches so the confirm renders without the popped annotations.
            cachedCompositedImage = nil
            cachedAnnotationLayer = nil
            overlayDelegate?.overlayViewDidConfirm()
            return true
        }

        // clickCount == 1: record the baseline so the next click (if it doubles up)
        // knows how far to rewind. Only record when the click could plausibly create
        // an annotation (inside selection, drawing tool). Otherwise leave it nil so
        // a double-click outside still works without an unrelated baseline.
        if pointIsInSelection(point) {
            doubleClickUndoBaseline = undoStack.count
            let hitText = annotations.reversed().contains(where: {
                $0.tool == .text && $0.hitTest(point: point)
            })
            textToolDoubleClickCopyDeadline =
                currentTool == .text && !hitText
                ? event.timestamp + NSEvent.doubleClickInterval + 0.05
                : 0
        } else {
            doubleClickUndoBaseline = nil
            textToolDoubleClickCopyDeadline = 0
        }
        return false
    }

    var isDoubleClickToCopyEnabled: Bool {
        UserDefaults.standard.object(forKey: "doubleClickToCopy") as? Bool ?? true
    }

    func hasPendingTextToolDoubleClickCopy(for event: NSEvent) -> Bool {
        event.type == .leftMouseDown
            && event.clickCount >= 2
            && event.timestamp <= textToolDoubleClickCopyDeadline
    }

    func shouldRouteTextEditorDoubleClickToCopy(event: NSEvent, at point: NSPoint) -> Bool {
        guard state == .selected,
              isDoubleClickToCopyEnabled,
              hasPendingTextToolDoubleClickCopy(for: event),
              let sv = textEditor.scrollView,
              sv.frame.contains(point)
        else { return false }
        return true
    }

    func finishSelection() {
        if selectionRect.width > 5 || selectionRect.height > 5 {
            // Real drag — use drawn rect as-is
            state = .selected
            applyPreSelectionLockAfterSelection()
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        } else if windowSnapEnabled, let snapRect = hoveredWindowRect, !snapRect.isEmpty {
            // Click (no drag) with snap on — snap to hovered window
            selectionRect = snapRect
            selectionIsWindowSnap = true
            snappedWindowID = hoveredWindowID
            // Capture the window independently for beautify (transparent corners)
            if let wid = hoveredWindowID, let screen = window?.screen {
                Task {
                    if let cgImage = await ScreenCaptureManager.captureWindow(windowID: wid, screen: screen) {
                        self.snappedWindowImage = NSImage(cgImage: cgImage,
                            size: NSSize(width: CGFloat(cgImage.width) / screen.backingScaleFactor,
                                         height: CGFloat(cgImage.height) / screen.backingScaleFactor))
                        self.needsDisplay = true
                    }
                }
            }
            state = .selected
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        } else {
            // Click (no drag), snap off — expand to full screen
            selectionRect = bounds
            state = .selected
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        }
        hoveredWindowRect = nil
        // Update cursor to match the selected tool (replaces resize cursor from dragging)
        if let win = window {
            let point = convert(win.mouseLocationOutsideOfEventStream, from: nil)
            updateCursorForPoint(point)
        }
        // Auto-enter recording mode if triggered from "Record Screen"
        if autoEnterRecordingMode {
            autoEnterRecordingMode = false
            overlayDelegate?.overlayViewDidRequestEnterRecordingMode()
        }
        // Auto-trigger OCR if triggered from "Capture OCR & QR"
        if autoOCRMode {
            autoOCRMode = false
            overlayDelegate?.overlayViewDidRequestOCR()
        }
        // Auto-trigger OCR + translate + in-place overlay (macshot://ocr-translate).
        // Unlike OCR, this keeps the overlay open so the translated result can be
        // reviewed/edited before saving. Toolbars stay visible (not suppressed above).
        if autoTranslateOverlayMode {
            autoTranslateOverlayMode = false
            let lang = autoTranslateOverlayLang ?? TranslationService.targetLanguage
            autoTranslateOverlayLang = nil
            // Mirror the interactive Translate tool's state so the toolbar button
            // shows as active and the language picker re-translates on change.
            translateEnabled = true
            performTranslate(targetLang: lang)
        }
        // Auto-trigger quick save if triggered from "Quick Capture"
        if autoQuickSaveMode {
            autoQuickSaveMode = false
            overlayDelegate?.overlayViewDidRequestQuickSave()
        }
        // Auto-trigger scroll capture if triggered from "Scroll Capture"
        if autoScrollCaptureMode {
            autoScrollCaptureMode = false
            overlayDelegate?.overlayViewDidRequestScrollCapture(rect: selectionRect)
        }
        // Auto-confirm for "Add Capture" — just confirm selection, no save/copy
        if autoConfirmMode {
            autoConfirmMode = false
            overlayDelegate?.overlayViewDidConfirm()
        }
        needsDisplay = true
    }

    func applyPreSelectionLockAfterSelection() {
        switch activePreSelectionPreset {
        case .ratio(let aspect):
            lockedAspect = aspect > 0 ? aspect : nil
        case .freeform, .resolution:
            lockedAspect = nil
        }
    }

    /// Update `selectionRect` from the anchor at `selectionStart` to the
    /// current cursor point. Honors Shift (constrain to square) and Space
    /// (reposition anchor). Shared between drag-to-select (mouseDragged)
    /// and right-click-anchored select (mouseMoved) so both flows produce
    /// identical geometry.
    func updateSelectionRect(to point: NSPoint, shiftHeld: Bool,
                                     modifiers: NSEvent.ModifierFlags = []) {
        var point = point
        if spaceRepositioning {
            let dx = point.x - spaceRepositionLast.x
            let dy = point.y - spaceRepositionLast.y
            selectionStart.x += dx
            selectionStart.y += dy
            spaceRepositionLast = point
        }

        if case .resolution(let pxW, let pxH) = activePreSelectionPreset {
            selectionRect = fixedPreSelectionRect(centeredAt: point, pxW: pxW, pxH: pxH)
            overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
            needsDisplay = true
            return
        }

        // Boundary snap the MOVING corner (the cursor) to nearby image edges.
        // Skipped for freeform-constrained drags (aspect/shift) so the constraint
        // stays exact, and bypassed with Option. The anchor edge stays put.
        // While repositioning with Space the whole rect translates rigidly, so we
        // snap the WHOLE moved rect below instead of just the cursor corner.
        if !spaceRepositioning, boundarySnapEnabled, !modifiers.contains(.option), let index = boundarySnapIndex,
           activePreSelectionRatio == nil, !shiftHeld {
            point = snapMovingPoint(point, anchor: selectionStart, index: index)
        } else if !spaceRepositioning, boundarySnapGuideX != nil || boundarySnapGuideY != nil {
            boundarySnapGuideX = nil
            boundarySnapGuideY = nil
        }

        let rawW = abs(point.x - selectionStart.x)
        let rawH = abs(point.y - selectionStart.y)
        var w = max(1, rawW)
        var h = max(1, rawH)
        if let aspect = activePreSelectionRatio, aspect > 0 {
            if rawW / max(rawH, 1) > aspect {
                w = max(1, rawH * aspect)
                h = max(1, rawH)
            } else {
                w = max(1, rawW)
                h = max(1, rawW / aspect)
            }
        } else if shiftHeld {
            let side = max(1, min(rawW, rawH))
            w = side
            h = side
        }

        let x = selectionStart.x < point.x ? selectionStart.x : selectionStart.x - w
        let y = selectionStart.y < point.y ? selectionStart.y : selectionStart.y - h
        var rect = NSRect(x: x, y: y, width: w, height: h)
        // Space reposition: the rect is moving rigidly, so snap the whole rect to
        // nearby image edges. The snap is applied only to the displayed rect, NOT
        // baked back into selectionStart — the logical anchor stays unsnapped so
        // the rect releases cleanly once the cursor moves past the snap radius.
        if spaceRepositioning {
            rect = boundarySnappedMovedRect(rect, modifiers: modifiers)
        }
        selectionRect = rect
        overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
        needsDisplay = true
    }

    func fixedPreSelectionRect(centeredAt point: NSPoint, pxW: Int, pxH: Int) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2.0
        var w = CGFloat(max(1, pxW)) / scale
        var h = CGFloat(max(1, pxH)) / scale

        if w > bounds.width || h > bounds.height {
            let s = min(bounds.width / w, bounds.height / h)
            w *= s
            h *= s
        }

        var x = point.x - w / 2
        var y = point.y - h / 2
        x = max(bounds.minX, min(x, bounds.maxX - w))
        y = max(bounds.minY, min(y, bounds.maxY - h))
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// mouseMoved entry point when the right-click-anchored mode is active.
    /// Kept separate from the drag path so cross-screen tracking and other
    /// mouseDragged-only features don't get accidentally invoked.
    func updateAnchoredSelection(to point: NSPoint, event: NSEvent) {
        updateSelectionRect(to: point, shiftHeld: event.modifierFlags.contains(.shift), modifiers: event.modifierFlags)
    }

    /// Commit an anchored selection — matches the branch in mouseUp that
    /// fires after a drag-to-select, so the same snap-to-window /
    /// fallback-to-fullscreen logic applies when the user confirms with a
    /// tiny (no-move) rectangle.
    func commitAnchoredSelection() {
        isAnchoredSelecting = false
        if selectionRect.width > 5 || selectionRect.height > 5 {
            state = .selected
            applyPreSelectionLockAfterSelection()
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode {
                showToolbars = true
            }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        } else if windowSnapEnabled, let snapRect = hoveredWindowRect, !snapRect.isEmpty {
            selectionRect = snapRect
            selectionIsWindowSnap = true
            snappedWindowID = hoveredWindowID
            if let wid = hoveredWindowID, let screen = window?.screen {
                Task {
                    if let cgImage = await ScreenCaptureManager.captureWindow(windowID: wid, screen: screen) {
                        self.snappedWindowImage = NSImage(
                            cgImage: cgImage,
                            size: NSSize(
                                width: CGFloat(cgImage.width) / screen.backingScaleFactor,
                                height: CGFloat(cgImage.height) / screen.backingScaleFactor))
                        self.needsDisplay = true
                    }
                }
            }
            state = .selected
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode {
                showToolbars = true
            }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        } else {
            selectionRect = bounds
            state = .selected
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode {
                showToolbars = true
            }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        }
        hoveredWindowRect = nil
        if let win = window {
            updateCursorForPoint(convert(win.mouseLocationOutsideOfEventStream, from: nil))
        }
        needsDisplay = true
    }

    /// Cancel anchored-selection mode (ESC). Resets back to idle without
    /// leaving a tiny selection behind.
    func cancelAnchoredSelection() {
        guard isAnchoredSelecting else { return }
        isAnchoredSelecting = false
        selectionRect = .zero
        state = .idle
        overlayDelegate?.overlayViewSelectionDidChange(.zero)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Text Fill/Outline color picking handled by ToolOptionsRowView

        // Toolbar right-clicks handled by ToolbarButtonView.onRightClick → handleToolbarButtonRightClick

        // Anchored selection toggle: right-click in idle starts no-hold
        // tracking from that point; a second right-click while tracking
        // commits. Left-click during tracking also commits (handled in
        // mouseDown). ESC cancels. Locked during recording and editor mode.
        if isAnchoredSelecting {
            updateSelectionRect(to: point, shiftHeld: event.modifierFlags.contains(.shift), modifiers: event.modifierFlags)
            commitAnchoredSelection()
            return
        }
        if state == .idle && shouldAllowNewSelection() {
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            isAnchoredSelecting = true
            overlayDelegate?.overlayViewDidBeginSelection()
            needsDisplay = true
            return
        }

        // Right-click on a line/arrow/measure: add anchor point.
        // Auto-selects the annotation if it isn't selected yet.
        if state == .selected {
            let canvasPoint = viewToCanvas(point)
            // Check already-selected annotation first
            if let ann = selectedAnnotation,
                (ann.tool == .arrow || ann.tool == .line || ann.tool == .measure),
                ann.hitTest(point: canvasPoint)
            {
                addAnchorPoint(to: ann, at: canvasPoint)
                cachedCompositedImage = nil
                needsDisplay = true
                return
            }
            // Check any unselected line/arrow/measure under the cursor
            if let ann = annotations.reversed().first(where: {
                ($0.tool == .arrow || $0.tool == .line || $0.tool == .measure)
                && $0.hitTest(point: canvasPoint)
            }) {
                selectedAnnotation = ann
                addAnchorPoint(to: ann, at: canvasPoint)
                cachedCompositedImage = nil
                needsDisplay = true
                return
            }
        }

        if state == .selected && currentTool == .colorSampler {
            // Right-click with color sampler: copy hex to clipboard
            if let screenshot = screenshotImage,
                let result = sampleColor(from: screenshot, at: viewToCanvas(point))
            {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.hex, forType: .string)
                showOverlayError(String(format: L("Copied %@"), result.hex))
                needsDisplay = true
            }
            return
        }

        if state == .selected && pointIsInSelection(point) {
            // Show radial color wheel
            colorWheel.show(at: point)

            colorWheel.hoveredIndex = -1
            needsDisplay = true
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if colorWheel.isVisible {
            let point = convert(event.locationInWindow, from: nil)
            colorWheel.updateHover(at: point)
            needsDisplay = true
            return
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if colorWheel.isVisible && !colorWheel.isSticky {
            if let hoveredColor = colorWheel.hoveredColor {
                // User dragged to a color — pick it and dismiss
                currentColor = hoveredColor
                applyColorToTextIfEditing()
                applyColorToSelectedAnnotation()
                rebuildToolbarLayout()
                colorWheel.dismiss()
            } else {
                // User released without dragging — enter sticky mode
                // so they can click a color (iPad/Sidecar/accessibility)
                colorWheel.isSticky = true
            }
            needsDisplay = true
            return
        }
    }

    // MARK: - Zoom (scroll wheel + trackpad pinch)

    var editorZoomRedrawTimer: Timer?

    /// Perform cursor-centered zoom on the enclosing scroll view.
    /// Uses NSScrollView's own setMagnification(_:centeredAt:) which handles all the
    /// coordinate math correctly, but we disable allowsMagnification so it doesn't
    /// apply its own elastic physics on top.
    // Animated zoom state for smooth mouse wheel zooming
    var editorZoomTarget: CGFloat = 1.0
    var editorZoomAnimTimer: Timer?
    var editorZoomCursorDoc: NSPoint = .zero

    func editorZoom(by factor: CGFloat, cursorInWindow: NSPoint, animated: Bool = false) {
        guard let sv = enclosingScrollView else { return }

        if animated {
            // Accumulate target and animate toward it
            if editorZoomAnimTimer == nil {
                editorZoomTarget = sv.magnification
            }
            editorZoomTarget = max(sv.minMagnification, min(sv.maxMagnification, editorZoomTarget * factor))
            editorZoomCursorDoc = convert(cursorInWindow, from: nil)

            if editorZoomAnimTimer == nil {
                editorZoomAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                    guard let self = self, let sv = self.enclosingScrollView else {
                        timer.invalidate()
                        return
                    }
                    let current = sv.magnification
                    let target = self.editorZoomTarget
                    let diff = target - current
                    if abs(diff) < 0.001 {
                        sv.setMagnification(target, centeredAt: self.editorZoomCursorDoc)
                        timer.invalidate()
                        self.editorZoomAnimTimer = nil
                        self.needsDisplay = true
                        if let topBar = sv.superview as? EditorChromeView {
                            topBar.updateZoom(target)
                        }
                        return
                    }
                    // Ease toward target: move 25% of remaining distance per frame
                    let next = current + diff * 0.25
                    sv.setMagnification(next, centeredAt: self.editorZoomCursorDoc)
                    if let topBar = sv.superview as? EditorChromeView {
                        topBar.updateZoom(next)
                    }
                }
            }
            return
        }

        let oldMag = sv.magnification
        let newMag = max(sv.minMagnification, min(sv.maxMagnification, oldMag * factor))
        guard newMag != oldMag else { return }

        // Convert cursor from window coords to document view (unscaled) coords
        let cursorInDoc = convert(cursorInWindow, from: nil)
        sv.setMagnification(newMag, centeredAt: cursorInDoc)

        // During active zooming, let the GPU-scaled layer handle the visual — it's instant.
        // Debounce the full-resolution redraw to when zooming stops (150ms idle).
        editorZoomRedrawTimer?.invalidate()
        editorZoomRedrawTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.needsDisplay = true
        }

        if let topBar = sv.superview as? EditorChromeView {
            topBar.updateZoom(newMag)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Editor mode: all scroll handling is done by CenteringClipView.
        // The capture overlay no longer zooms/pans on scroll.
        if isInsideScrollView {
            enclosingScrollView?.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        // Editor mode pinch-zooms via the scroll view; the capture overlay
        // does not respond to pinch.
        if isInsideScrollView {
            editorZoom(by: 1.0 + event.magnification, cursorInWindow: event.locationInWindow)
        }
    }

    // MARK: - Middle Mouse (toggle move mode)

    override func otherMouseDown(with event: NSEvent) {
        // Middle mouse: no action (previously toggled select tool)
    }

    // MARK: - Keyboard

    override func flagsChanged(with event: NSEvent) {
        // Re-apply shift constraint immediately when Shift is pressed/released during annotation drag
        if currentAnnotation != nil, let lastPoint = lastDragPoint {
            let shiftHeld = event.modifierFlags.contains(.shift)
            updateAnnotation(at: lastPoint, shiftHeld: shiftHeld)
            needsDisplay = true
        }
    }

    /// Called by the Character Palette when the user selects an emoji.
    override func insertText(_ insertString: Any) {
        guard currentTool == .stamp, let str = insertString as? String, !str.isEmpty else { return }
        currentStampImage = StampEmojis.renderEmoji(str)
        currentStampEmoji = str
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The global screenshot shortcut has already started this session. The
        // original key event can still reach the newly-key overlay on some
        // macOS versions, where AppKit may interpret Control+number as a
        // regular command or cancellation. Consume the exact configured combo
        // while the overlay is active instead of routing it through keyDown.
        if matchesGlobalScreenshotShortcut(event) {
            return true
        }

        // ⌥⌘T: collapse / expand the capture control island (keyCode = layout-independent T).
        let mods = event.modifierFlags
        if event.keyCode == 17, mods.contains(.command), mods.contains(.option),
           !mods.contains(.control), !mods.contains(.shift), textEditView == nil, canToggleIsland {
            toggleIslandCollapsed()
            return true
        }
        // Forward Cmd shortcuts to the text view when editing — the main menu
        // intercepts these before keyDown reaches the overlay window.
        // Use keyCode (hardware-based) instead of charactersIgnoringModifiers
        // so shortcuts work regardless of keyboard layout (e.g. Russian, Arabic).
        if event.modifierFlags.contains(.command) {
            let key = event.keyCode
            // Text editing: forward to NSTextView (only when text is actively selected)
            if let tv = textEditView {
                switch key {
                case 8:  // C
                    if tv.selectedRange().length > 0 {
                        tv.copy(nil)
                    } else {
                        // No text selected — commit, copy annotation, then deselect
                        // so the purple selection chrome doesn't flash
                        commitTextFieldIfNeeded()
                        if selectedAnnotations.isEmpty, let last = annotations.last, last.tool == .text {
                            selectedAnnotation = last
                        }
                        copySelectedAnnotations()
                        selectedAnnotations = []
                        needsDisplay = true
                    }
                    return true
                case 9:  // V
                    if NSPasteboard.general.data(forType: Self.annotationPasteboardType) != nil {
                        commitTextFieldIfNeeded()
                        pasteAnnotations()
                        selectedAnnotations = []
                        needsDisplay = true
                    } else if NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil) {
                        // Clipboard has text — paste it into the text field.
                        tv.paste(nil)
                    } else if isEditorMode {
                        // No text, but an image may be present — commit the text edit
                        // and paste the image as a stamp (mirrors "Add Capture").
                        commitTextFieldIfNeeded()
                        _ = pasteImageFromClipboard()
                    } else {
                        tv.paste(nil)
                    }
                    return true
                case 7: tv.cut(nil); return true  // X
                case 0: tv.selectAll(nil); return true  // A
                case 6:  // Z
                    if event.modifierFlags.contains(.shift) { tv.undoManager?.redo() }
                    else { tv.undoManager?.undo() }
                    return true
                default: break
                }
            }

            // Annotation copy/paste (no text editing active)
            if state == .selected {
                switch key {
                case 8:  // C
                    if !selectedAnnotations.isEmpty {
                        copySelectedAnnotations()
                    } else {
                        overlayDelegate?.overlayViewDidConfirm()
                    }
                    return true
                case 9:  // V
                    if NSPasteboard.general.data(forType: Self.annotationPasteboardType) != nil {
                        pasteAnnotations()
                        return true
                    }
                    // Editor only: fall back to pasting a clipboard image as a stamp
                    // placed below the canvas (mirrors "Add Capture").
                    if pasteImageFromClipboard() {
                        return true
                    }
                case 2:  // D — duplicate in place, without touching the clipboard
                    if !selectedAnnotations.isEmpty {
                        duplicateSelectedAnnotations()
                        return true
                    }
                default: break
                }
            }

            // Canvas undo/redo — intercept before main menu consumes the event
            if state == .selected {
                switch key {
                case 6:  // Z
                    if event.modifierFlags.contains(.shift) { redo() }
                    else { undo() }
                    return true
                case 16:  // Y
                    redo()
                    return true
                default: break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    func matchesGlobalScreenshotShortcut(_ event: NSEvent) -> Bool {
        guard PreferencesManager.shared.isScreenshotShortcutEnabled,
              let combo = PreferencesManager.shared.screenshotShortcut else {
            return false
        }
        let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let configuredFlags = NSEvent.ModifierFlags(rawValue: combo.modifierFlags)
            .intersection(relevantFlags)
        let eventFlags = event.modifierFlags.intersection(relevantFlags)
        return Int(event.keyCode) == combo.keyCode && eventFlags == configuredFlags
    }

    override func keyDown(with event: NSEvent) {
        if matchesGlobalScreenshotShortcut(event) {
            return
        }

        // In recording mode, only allow Escape (to exit recording mode)
        if isRecording {
            if event.keyCode == 53 { // Escape
                handleToolbarAction(.stopRecord)
            }
            return
        }

        // Space: reposition shape/selection mid-drag (design tool convention).
        // When it is not actionable, still consume it so key repeat never falls
        // through to AppKit's "unhandled key" beep while the overlay is focused.
        if event.keyCode == 49 && textEditView == nil
            && !event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.option)
            && !event.modifierFlags.contains(.control)
        {
            // Swallow all repeats while repositioning to prevent system beep
            if spaceRepositioning { return }

            if !event.isARepeat {
                let isDrawingAnnotation =
                    currentAnnotation != nil && currentAnnotation!.tool != .pencil
                    && currentAnnotation!.tool != .marker
                let isResizingExistingAnnotation = isResizingAnnotation && selectedAnnotation != nil
                let isResizingCaptureSelection = isResizingSelection
                let isDraggingNewSelection = state == .selecting

                if isDrawingAnnotation || isResizingExistingAnnotation
                    || isResizingCaptureSelection || isDraggingNewSelection
                {
                    spaceRepositioning = true
                    if isDrawingAnnotation {
                        spaceRepositionLast = lastDragPoint ?? currentCanvasMousePoint ?? .zero
                    } else if isResizingExistingAnnotation {
                        spaceRepositionLast = currentCanvasMousePoint ?? annotationResizeMouseStart
                    } else if isResizingCaptureSelection, let windowPoint = window?.mouseLocationOutsideOfEventStream {
                        spaceRepositionLast = convert(windowPoint, from: nil)
                    } else if let windowPoint = window?.mouseLocationOutsideOfEventStream {
                        spaceRepositionLast = convert(windowPoint, from: nil)
                    }
                    return
                }
            }
            // Space may be a user-configured action shortcut (Copy, Save, Pin, …).
            // The reposition feature only owns Space during an active drag, so an
            // idle press must go through the same dispatch as every other key (#292).
            if !event.isARepeat, state == .selected,
               let action = ToolShortcutManager.lookupAction(for: " ") {
                switch action {
                case .moveSelection:
                    if !isKeyboardMoveSelectionActive {
                        _ = startKeyboardMoveSelection()
                    }
                case .detach:
                    if shouldAllowDetach() { handleToolbarAction(.detach) }
                case .pin, .scrollCapture:
                    if !isEditorMode { handleToolbarAction(action) }
                default:
                    handleToolbarAction(action)
                }
                return
            }
            // Unbound Space is still consumed so key repeat never falls through
            // to AppKit's "unhandled key" beep while the overlay is focused.
            return
        }

        switch event.keyCode {
        case 53:  // Escape
            cancelRecognition()
            if isScrollCapturing {
                overlayDelegate?.overlayViewDidRequestStopScrollCapture()
                return
            }
            if isAnchoredSelecting {
                cancelAnchoredSelection()
                return
            }
            if colorWheel.isVisible && colorWheel.isSticky {
                colorWheel.dismiss()
                needsDisplay = true
            } else if textEditView != nil {
                cancelTextEditing()
            } else if PopoverHelper.isVisible {
                PopoverHelper.dismiss()
            } else if !selectedAnnotations.isEmpty {
                selectedAnnotations = []
                needsDisplay = true
            } else {
                overlayDelegate?.overlayViewDidCancel()
            }
        case 48:  // Tab
            if state == .idle {
                // Toggle window snapping in idle state
                windowSnapEnabled = !windowSnapEnabled
                hoveredWindowRect = nil
                needsDisplay = true
                // Notify other overlays to redraw (for multi-monitor setups)
                overlayDelegate?.overlayViewDidChangeWindowSnapState()
            }
        case 3:  // F — full screen capture (only in idle state with snap on)
            if state == .idle && windowSnapEnabled {
                selectionRect = bounds
                state = .selected
                hoveredWindowRect = nil
                if autoQuickSaveMode {
                    autoQuickSaveMode = false
                    overlayDelegate?.overlayViewDidRequestQuickSave()
                } else {
                    showToolbars = true
                    overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
                    needsDisplay = true
                }
            }
        case 36, 76:  // Return / numpad Enter — quick capture (respects quickCaptureMode setting)
            if textEditView == nil, state == .selected {
                overlayDelegate?.overlayViewDidRequestQuickSave()
            }
        case 51, 117:  // Backspace / Forward-Delete — remove selected annotation(s)
            guard textEditView == nil, state == .selected, !selectedAnnotations.isEmpty else { break }
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
        default:
            // Auto-measure: hold "1" = vertical preview, hold "2" = horizontal preview
            if state == .selected && currentTool == .measure && textEditView == nil
                && !event.modifierFlags.contains(.command)
            {
                if let char = event.charactersIgnoringModifiers {
                    if char == "1" || char == "2" {
                        autoMeasureVertical = (char == "1")
                        if !autoMeasureKeyHeld {
                            autoMeasureKeyHeld = true
                            updateAutoMeasurePreview()
                        }
                        return
                    }
                }
            }
            // Single-key tool shortcuts (only when selected, not editing text, no modifiers)
            if state == .selected && textEditView == nil && !event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control)
            {
                if let char = event.charactersIgnoringModifiers?.lowercased(),
                   let action = ToolShortcutManager.lookupAction(for: char) {
                    switch action {
                    case .moveSelection:
                        if !isKeyboardMoveSelectionActive {
                            _ = startKeyboardMoveSelection()
                        }
                    case .detach:
                        if shouldAllowDetach() { handleToolbarAction(.detach) }
                    case .pin, .scrollCapture:
                        if !isEditorMode { handleToolbarAction(action) }
                    default:
                        handleToolbarAction(action)
                    }
                    return
                }
            }
            if event.modifierFlags.contains(.command) {
                // Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z are handled in performKeyEquivalent.
                // Only Cmd+S and zoom shortcuts remain here.
                // Use keyCode for letters so shortcuts work with any keyboard layout.
                if event.keyCode == 1 {  // S
                    if state == .selected {
                        overlayDelegate?.overlayViewDidRequestSave()
                    }
                    return
                }
                if event.charactersIgnoringModifiers == "0" {
                    // Cmd+0 resets zoom in the editor only; the capture overlay
                    // doesn't zoom.
                    if isInsideScrollView, let sv = enclosingScrollView {
                        sv.magnification = 1.0
                        findTopBar()?.updateZoom(1.0)
                    }
                    return
                }
                if isInsideScrollView {
                    if event.charactersIgnoringModifiers == "=" || event.charactersIgnoringModifiers == "+" {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let newMag = min(sv.maxMagnification, sv.magnification * 1.25)
                            sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
                            findTopBar()?.updateZoom(newMag)
                        }
                        return
                    }
                    if event.charactersIgnoringModifiers == "-" {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let newMag = max(sv.minMagnification, sv.magnification / 1.25)
                            sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
                            findTopBar()?.updateZoom(newMag)
                        }
                        return
                    }
                    if event.charactersIgnoringModifiers == "1" {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let unscaledW = doc.frame.width / sv.magnification
                            let unscaledH = doc.frame.height / sv.magnification
                            guard unscaledW > 0, unscaledH > 0 else { return }
                            let clipSize = sv.contentView.bounds.size
                            let fitMag = min(clipSize.width / unscaledW, clipSize.height / unscaledH)
                            let clamped = max(sv.minMagnification, min(sv.maxMagnification, fitMag))
                            sv.magnification = clamped
                            findTopBar()?.updateZoom(clamped)
                        }
                        return
                    }
                }
            }
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if isKeyboardMoveSelectionActive && eventEndsKeyboardMoveSelection(event) {
            endKeyboardMoveSelection()
            return
        }
        if event.keyCode == 49 && spaceRepositioning {
            spaceRepositioning = false
            return
        }
        if event.keyCode == 49 && textEditView == nil
            && !event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.option)
            && !event.modifierFlags.contains(.control)
        {
            return
        }
        // Clear auto-measure preview on key release (click to commit instead)
        if let char = event.charactersIgnoringModifiers, char == "1" || char == "2" {
            if autoMeasureKeyHeld {
                autoMeasureKeyHeld = false
                autoMeasurePreview = nil
                autoMeasureBitmapCtx = nil  // free cached bitmap
                needsDisplay = true
                return
            }
        }
        super.keyUp(with: event)
    }

}

// MARK: - NSTextViewDelegate

extension OverlayView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(self)
            textDidChange(Notification(name: NSText.didChangeNotification))
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        textEditor.resizeToFit()
        needsDisplay = true
    }
}

// MARK: - AnnotationCanvas conformance

// MARK: - Image Effects helpers

extension OverlayView {
    /// Returns the effects-processed screenshot, cached for performance during draw().
    func effectsProcessedScreenshot(_ screenshot: NSImage) -> NSImage {
        if let cached = cachedEffectsScreenshot { return cached }
        let config = effectsConfig
        guard !config.isIdentity else { return screenshot }
        let processed = ImageEffects.apply(to: screenshot, config: config)
        cachedEffectsScreenshot = processed
        return processed
    }
}

extension OverlayView: AnnotationCanvas {
    var activeAnnotation: Annotation? {
        get { currentAnnotation }
        set { currentAnnotation = newValue }
    }

    func setNeedsDisplay() {
        needsDisplay = true
    }

    func invalidateAnnotationRendering() {
        cachedAnnotationLayer = nil
        cachedAnnotationLayerExcludingSelected = nil
        cachedCompositedImage = nil
        cachedEffectsScreenshot = nil
        needsDisplay = true
        onContentChanged?()
    }
}

// MARK: - TextEditingCanvas conformance

extension OverlayView: TextEditingCanvas {}

/// Small rounded-rect tooltip view used for editor mode toolbar hover labels.
class TooltipBackgroundView: NSView {
    var text: String = ""

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor,
        ]
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let pad: CGFloat = 6
        (text as NSString).draw(at: NSPoint(x: pad, y: pad / 2), withAttributes: attrs)
    }
}

/// Compact icon-only control shown in the pre-selection helper. It opens the
/// same ratio/resolution presets as the selected-area size control without
/// turning the idle helper into a full toolbar.
final class PreSelectionPresetButton: NSButton {
    var hovered = false
    var activePreset = false
    var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setButtonType(.momentaryChange)
        if #available(macOS 11.0, *) {
            let symbol = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
            symbol?.isTemplate = true
            image = symbol
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(active: Bool, tooltip: String) {
        activePreset = active
        toolTip = tooltip
        contentTintColor = active ? ToolbarLayout.accentColor : ToolbarLayout.iconColor.withAlphaComponent(0.88)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg: NSColor
        if isHighlighted {
            bg = ToolbarLayout.accentColor.withAlphaComponent(0.28)
        } else if hovered {
            bg = ToolbarLayout.iconColor.withAlphaComponent(0.14)
        } else {
            bg = NSColor.white.withAlphaComponent(0.07)
        }
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let stroke = activePreset
            ? ToolbarLayout.accentColor.withAlphaComponent(0.85)
            : ToolbarLayout.iconColor.withAlphaComponent(0.18)
        stroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        border.lineWidth = activePreset ? 1.3 : 1.0
        border.stroke()

        super.draw(dirtyRect)
    }
}

// MARK: - V3 editor inspector bridge

/// Narrow accessors used by `EditorChromeView`. They route through the same
/// private state and helpers as the color popover and toolbar buttons.
extension OverlayView {
    var inspectorSelectedAnnotationCount: Int { selectedAnnotations.count }
    var inspectorColorOpacity: CGFloat { currentColorOpacity }
    var inspectorCanUndo: Bool { !undoStack.isEmpty }
    var inspectorCanRedo: Bool { !redoStack.isEmpty }

    func applyInspectorColor(_ color: NSColor) {
        colorPickerTarget = .drawColor
        applyPickedColor(color)
        toolOptionsRowView?.updateSwatchColors()
        needsDisplay = true
        rebuildToolbarLayout()
    }

    #if CLIPY_CORE_TESTS
    func selectAnnotationForSnapshot(_ annotation: Annotation?) {
        selectedAnnotations = annotation.map { [$0] } ?? []
        rebuildToolbarLayout()
    }
    #endif

    func applyInspectorOpacity(_ opacity: CGFloat) {
        currentColorOpacity = opacity
        OverlayView.lastUsedOpacity = opacity
        UserDefaults.standard.set(Double(opacity), forKey: "lastUsedColorOpacity")
        applyColorToSelectedAnnotation()
        needsDisplay = true
    }
}
