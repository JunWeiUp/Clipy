import Cocoa

/// Exercise the real video editor without starting application services.
@MainActor
func runVideoEditorLayoutSnapshot() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let directory = ProcessInfo.processInfo.environment["CLIPY_VIDEO_EDITOR_SNAPSHOT_DIR"],
          let path = ProcessInfo.processInfo.environment["CLIPY_VIDEO_EDITOR_FIXTURE"] else { exit(2) }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    VideoEditorWindowController.open(url: URL(fileURLWithPath: path), deleteOnClose: false)
    guard let window = app.windows.first(where: { $0.title.contains("Video Editor") || $0.title.contains("视频编辑") }) else { exit(3) }
    window.setContentSize(NSSize(width: 1224, height: 700))
    window.appearance = NSAppearance(named: .aqua)
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    var step = 0
    func addButton(_ id: String, in view: NSView) -> NSButton? {
        descendants(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }
    }
    let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
        // macOS 26: the unified toolbar's scroll-edge effect blanks scroll views in
        // cacheDisplay bitmaps; detach it only while caching (header + traffic lights stay).
        let toolbar = window.toolbar
        window.toolbar = nil
        defer { window.toolbar = toolbar }
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView, let frameView = view.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(4) }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(5) }
        do {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(step == 0 ? "video-light.png" : "video-dark.png"))
        } catch { exit(6) }
        if step == 1 {
            guard descendants(view).compactMap({ $0 as? NSButton }).contains(where: { $0.title == L("Delete") }) else { exit(7) }
            for title in ["Add Censor", "Add Text", "Add Speed", "Add Freeze", "Add Cut"] {
                guard let button = addButton(title, in: view), button.isEnabled else { exit(9) }
                button.performClick(nil)
                guard descendants(view).compactMap({ $0 as? NSButton }).contains(where: { $0.title == L("Delete") }) else { exit(10) }
            }
            timer.invalidate(); window.close(); exit(0)
        }
        step += 1
        guard let addZoom = addButton("Add Zoom", in: view), addZoom.isEnabled else { exit(8) }
        addZoom.performClick(nil)
        window.appearance = NSAppearance(named: .darkAqua)
    }
    withExtendedLifetime((window, timer)) { app.run() }
    exit(0)
}
