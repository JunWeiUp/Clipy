import AppKit
import Darwin

/// Optional private enumeration only. Missing symbols fall back to AX + application icons.
/// Do not use a hosted window's PID as its owning application (Control Center on macOS 26).
final class MenuBarSystemBridge {
    struct Window {
        let id: CGWindowID
        let frame: CGRect
    }
    private typealias Connection = @convention(c) () -> Int32
    private typealias Count = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias List = @convention(c) (Int32, Int32, Int32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias Rect = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    private let handle: UnsafeMutableRawPointer?

    init() { handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) }
    deinit { if let handle { dlclose(handle) } }

    func windows() -> [Window] {
        guard let handle,
              let c = dlsym(handle, "CGSMainConnectionID"),
              let n = dlsym(handle, "CGSGetWindowCount"),
              let l = dlsym(handle, "CGSGetProcessMenuBarWindowList"),
              let r = dlsym(handle, "CGSGetScreenRectForWindow") else { return [] }
        let connection = unsafeBitCast(c, to: Connection.self)()
        var count: Int32 = 0
        guard unsafeBitCast(n, to: Count.self)(connection, 0, &count) == 0,
              count > 0, count <= 16_384 else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(count))
        var actual: Int32 = 0
        guard unsafeBitCast(l, to: List.self)(connection, 0, count, &ids, &actual) == 0,
              actual >= 0, actual <= count else { return [] }
        let rect = unsafeBitCast(r, to: Rect.self)
        return ids.prefix(Int(actual)).compactMap { id in
            var frame = CGRect.zero
            guard rect(connection, id, &frame) == 0, frame.width > 0, frame.height > 0 else { return nil }
            return Window(id: id, frame: frame)
        }
    }

    /// Match by center and containment; AX often describes only the button inside its window.
    /// Ambiguous matches are deliberately not used for images or identity.
    static func window(for frame: CGRect, in windows: [Window]) -> CGWindowID? {
        matchedWindow(for: frame, in: windows)?.id
    }

    static func matchedWindow(for frame: CGRect, in windows: [Window]) -> Window? {
        let matches = windows.filter {
            abs($0.frame.midX - frame.midX) <= 4 && abs($0.frame.midY - frame.midY) <= 4
                && $0.frame.width <= frame.width + 32 && $0.frame.intersects(frame)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
