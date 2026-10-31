import Cocoa

@MainActor
func runCaptureResultsLayoutSnapshot() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let directory = ProcessInfo.processInfo.environment["CLIPY_CAPTURE_RESULTS_SNAPSHOT_DIR"] else { exit(2) }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let image = NSImage(size: NSSize(width: 640, height: 360))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 640, height: 360).fill()
    image.unlockFocus()
    let controller = OCRResultController(text: "Fictional sample\nClipy screenshot", image: image,
                                         qrCodes: [QRCodePayload(value: "https://example.com")])
    controller.show()
    guard let window = app.windows.first(where: { $0.title == L("Text & QR Recognition") }) else { exit(3) }
    let pin = PinPanel(image: image, screenRect: NSRect(x: 100, y: 100, width: 320, height: 180), id: UUID(), onClose: { _ in })
    let hud = RecordingHUDPanel()
    hud.update(elapsedSeconds: 42)
    let thumbnail = FloatingThumbnailController(image: image)
    thumbnail.show(at: NSPoint(x: 50, y: 50), corner: .bottomRight)
    thumbnail.setCompact(true)
    let fullThumbnail = FloatingThumbnailController(image: image)
    fullThumbnail.show(at: NSPoint(x: 50, y: 300), corner: .bottomRight)
    fullThumbnail.showHoverForSnapshot()
    pin.orderFrontRegardless()
    hud.orderFrontRegardless()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    var step = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
        guard let view = window.contentView else { exit(4) }
        view.layoutSubtreeIfNeeded()
        let editors = descendants(view).compactMap { $0 as? NSTextView }
        guard editors.contains(where: { $0.isEditable && $0.string.contains("Fictional sample") }),
              editors.contains(where: { !$0.isEditable }) else { exit(5) }
        // Include the unified title bar (title + live count subtitle).
        let frameView = view.superview ?? view
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(6) }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(7) }
        do { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(step == 0 ? "ocr-light.png" : "ocr-dark.png")) }
        catch { exit(8) }
        for (name, panel) in [("pin", pin as NSWindow), ("hud", hud as NSWindow)] {
            guard let content = panel.contentView else { exit(9) }
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(10) }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let bytes = bitmap.representation(using: .png, properties: [:]) else { exit(11) }
            do { try bytes.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(step == 0 ? "light" : "dark").png")) }
            catch { exit(12) }
        }
        let thumbWindows = app.windows.filter { $0.contentView.map { String(describing: type(of: $0)) == "ThumbnailView" } ?? false }
        guard let thumbWindow = thumbWindows.first(where: { ($0.contentView?.bounds.height ?? 0) <= 70 }),
              let content = thumbWindow.contentView else { exit(13) }
        for window in thumbWindows { window.appearance = NSAppearance(named: step == 0 ? .aqua : .darkAqua) }
        if let full = thumbWindows.first(where: { ($0.contentView?.bounds.height ?? 0) > 70 })?.contentView,
           let fullRep = full.bitmapImageRepForCachingDisplay(in: full.bounds) {
            full.cacheDisplay(in: full.bounds, to: fullRep)
            try? fullRep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("thumbnail-full-\(step == 0 ? "light" : "dark").png"))
        }
        guard content.bounds.height <= 70 else { exit(17) }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(14) }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { exit(15) }
        do { try bytes.write(to: URL(fileURLWithPath: directory).appendingPathComponent("thumbnail-\(step == 0 ? "light" : "dark").png")) }
        catch { exit(16) }
        if step == 1 { timer.invalidate(); controller.close(); thumbnail.dismiss(); fullThumbnail.dismiss(); pin.orderOut(nil); hud.orderOut(nil); exit(0) }
        step += 1
        window.appearance = NSAppearance(named: .darkAqua)
        pin.appearance = NSAppearance(named: .darkAqua)
        hud.appearance = NSAppearance(named: .darkAqua)
        thumbWindow.appearance = NSAppearance(named: .darkAqua)
    }
    window.appearance = NSAppearance(named: .aqua)
    pin.appearance = NSAppearance(named: .aqua)
    hud.appearance = NSAppearance(named: .aqua)
    withExtendedLifetime((controller, window, pin, hud, thumbnail, fullThumbnail, timer)) { app.run() }
    exit(0)
}
