import AppKit
import CoreGraphics

/// Places temporary recording controls beside a ScreenCaptureKit selection.
/// AppKit and Quartz use opposite vertical origins, including on secondary displays.
@MainActor
enum NativeScreenshotRecordingPanelPlacement {
    static func place(_ window: NSWindow, near region: CGRect, displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) ?? NSScreen.main,
              let selection = selectionFrame(region: region, displayID: displayID) else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(origin(
            selection: selection, visible: visible, panelSize: window.frame.size))
    }

    static func selectionFrame(region: CGRect, displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) ?? NSScreen.main else { return nil }
        let displayFrame = CGDisplayBounds(displayID)
        return CGRect(
            x: screen.frame.minX + region.minX - displayFrame.minX,
            y: screen.frame.maxY - (region.maxY - displayFrame.minY),
            width: region.width, height: region.height)
    }

    /// Align with the selection's upper-right edge, then fall below when
    /// the upper edge has no room for the control pill.
    static func origin(
        selection: CGRect, visible: CGRect, panelSize: CGSize
    ) -> CGPoint {
        let gap: CGFloat = 8
        let above = selection.maxY + gap
        let preferredY = above + panelSize.height <= visible.maxY - 4
            ? above : selection.minY - panelSize.height - gap
        return CGPoint(
            x: max(visible.minX + 4,
                   min(selection.maxX - panelSize.width - gap,
                       visible.maxX - panelSize.width - 4)),
            y: max(visible.minY + 4,
                   min(preferredY, visible.maxY - panelSize.height - 4))
        )
    }
}
