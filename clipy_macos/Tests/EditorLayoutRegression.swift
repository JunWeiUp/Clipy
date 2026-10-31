import Cocoa

/// Exercise the real editor layout with a generated image and no capture or sync services.
@MainActor
func runEditorLayoutSnapshot() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let directory = ProcessInfo.processInfo.environment["CLIPY_EDITOR_SNAPSHOT_DIR"] else { exit(2) }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    guard let bitmap = CGContext(data: nil, width: 640, height: 420, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(9) }
    bitmap.setFillColor(NSColor.white.cgColor)
    bitmap.fill(CGRect(x: 0, y: 0, width: 640, height: 420))
    bitmap.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor)
    bitmap.fill(CGRect(x: 24, y: 270, width: 592, height: 120))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
    ("Clipy • Design review" as NSString).draw(at: NSPoint(x: 48, y: 330), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black])
    ("Fictional content for editor layout verification." as NSString).draw(at: NSPoint(x: 48, y: 302), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.darkGray])
    NSGraphicsContext.restoreGraphicsState()
    guard let cgImage = bitmap.makeImage() else { exit(9) }
    let raster = NSImage(cgImage: cgImage, size: NSSize(width: 640, height: 420))
    UserDefaults.standard.set(true, forKey: "beautifyEnabled")
    UserDefaults.standard.set(1, forKey: "beautifyMode")
    UserDefaults.standard.set(0, forKey: "beautifyStyleIndex")
    let red = NSColor.systemRed
    let box = Annotation(tool: .rectangle, startPoint: NSPoint(x: 40, y: 286), endPoint: NSPoint(x: 360, y: 336), color: red, strokeWidth: 3)
    let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 470, y: 180), endPoint: NSPoint(x: 380, y: 290), color: red, strokeWidth: 3)
    let number = Annotation(tool: .number, startPoint: NSPoint(x: 390, y: 312), endPoint: NSPoint(x: 390, y: 312), color: red, strokeWidth: 3)
    number.number = 1
    DetachedEditorWindowController.open(image: raster, tool: .rectangle, annotations: [box, arrow, number])
    guard let window = app.windows.first(where: { $0.contentView is EditorChromeView }) else { exit(3) }
    window.appearance = NSAppearance(named: .aqua)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    guard let root = window.contentView,
          let editor = descendants(root).compactMap({ $0 as? EditorView }).first else { exit(10) }
    for tool: AnnotationTool in [.pencil, .arrow, .rectangle, .ellipse, .text, .number, .marker, .loupe] {
        editor.handleToolbarAction(.tool(tool))
        root.layoutSubtreeIfNeeded()
        guard let options = descendants(root).compactMap({ $0 as? ToolOptionsRowView }).first else { exit(11) }
        for control in options.subviews where !control.isHidden {
            guard options.bounds.insetBy(dx: -1, dy: -1).contains(control.frame) else { exit(12) }
        }
    }
    editor.handleToolbarAction(.tool(.rectangle))
    editor.selectAnnotationForSnapshot(box)
    // An unsaved beautify edit reveals the primary Done button, as in the design.
    editor.beautifyPadding = 30; editor.beautifyCornerRadius = 16; editor.beautifyShadowRadius = 60
    editor.onContentChanged?()
    window.setContentSize(NSSize(width: 1200, height: 730))
    var step = 0
    var captureWindow: NSWindow?
    var capture: OverlayView?
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
        let activeWindow = step < 2 ? window : captureWindow!
        // macOS 26: the unified toolbar's scroll-edge effect blanks scroll views in
        // cacheDisplay bitmaps; detach it only while caching the editor frame.
        let toolbar = activeWindow.toolbar
        let detachesToolbar = step < 2
        if detachesToolbar { activeWindow.toolbar = nil }
        defer { if detachesToolbar { activeWindow.toolbar = toolbar } }
        activeWindow.contentView?.layoutSubtreeIfNeeded()
        // The editor snapshot includes the title-bar frame (traffic lights live there).
        guard let view = step < 2 ? activeWindow.contentView?.superview : activeWindow.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(4) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(5) }
        let names = ["annotation-light.png", "annotation-dark.png", "capture-preparation.png", "capture-selected.png", "recording-preparation.png"]
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(names[step]))
        if step == 0, let chrome = window.contentView as? EditorChromeView,
           let inspector = descendants(chrome).compactMap({ $0 as? NSScrollView }).first(where: { !($0.documentView is EditorView) }),
           let document = inspector.documentView {
            for tool: AnnotationTool in [.arrow, .text, .pixelate, .pencil, .number, .stamp, .highlight, .loupe, .measure, .marker] {
                editor.selectAnnotationForSnapshot(nil)
                editor.handleToolbarAction(.tool(tool))
                chrome.refreshFromOverlay()
                chrome.layoutSubtreeIfNeeded()
                guard let toolRep = document.bitmapImageRepForCachingDisplay(in: document.bounds) else { continue }
                document.cacheDisplay(in: document.bounds, to: toolRep)
                try? toolRep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("inspector-\(tool.rawValue).png"))
            }
            editor.handleToolbarAction(.tool(.rectangle))
            editor.selectAnnotationForSnapshot(box)
        }
        if step == 4 {
            guard descendants(view).compactMap({ $0 as? ToolbarStripView }).contains(where: {
                if case .horizontal = $0.orientation { return !$0.isHidden }; return false
            }) else { exit(14) }
            timer.invalidate(); capture?.reset(); activeWindow.close(); exit(0)
        }
        if step == 1 {
            window.close()
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
            overlay.screenshotImage = raster
            overlay.windowSnapEnabled = false
            panel.contentView = overlay
            panel.center(); panel.makeKeyAndOrderFront(nil)
            captureWindow = panel
            capture = overlay
        } else if step == 2 {
            guard descendants(view).compactMap({ $0 as? NSButton }).contains(where: { $0.title == L("Full Screen") }) else { exit(13) }
            capture?.applySelection(NSRect(x: 180, y: 250, width: 740, height: 360))
            capture?.currentTool = .arrow
            capture?.rebuildToolbarLayout()
        } else if step == 3 {
            for key in ["recordMicAudio", "recordWebcam", "recordKeystroke"] { UserDefaults.standard.set(false, forKey: key) }
            UserDefaults.standard.set(true, forKey: "recordMouseHighlight")
            UserDefaults.standard.set(true, forKey: "recordSystemAudio")
            capture?.applySelection(NSRect(x: 180, y: 170, width: 740, height: 400))
            capture?.isRecording = true
            capture?.rebuildToolbarLayout()
        }
        step += 1
        if step == 1 { window.appearance = NSAppearance(named: .darkAqua) }
    }
    withExtendedLifetime((raster, window, timer)) { app.run() }
    exit(0)
}
