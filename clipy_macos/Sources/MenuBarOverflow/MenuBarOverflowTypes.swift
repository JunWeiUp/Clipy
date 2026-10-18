import AppKit
import ApplicationServices
import Darwin

enum MenuBarOverflowProcessIdentity {
    /// Launch Services returns nil launchDate for some accessory/command-line processes.
    /// Kernel start time both includes those apps and protects against PID reuse.
    static func launchDate(for pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}

/// All geometry is in Quartz logical points (top-left origin), never Retina pixels.
struct MenuBarOverflowGeometry {
    let screen: CGRect
    let barHeight: CGFloat
    let rightAreaMinX: CGFloat

    func isOverflow(_ frame: CGRect, applicationMenuMaxX: CGFloat?) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              frame.height <= barHeight + 8,
              abs(frame.minY - screen.minY) <= barHeight else { return false }
        // A zero-sized AX placeholder or a window on another row is not an overflow item.
        let left = max(rightAreaMinX, applicationMenuMaxX ?? screen.minX)
        // Even a small overlap with the notch can suppress the entire status window.
        // The system clock can extend two points beyond the right screen edge.
        return frame.minX < left || frame.maxX > screen.maxX + 2
    }

    /// Pick the menu bar that owns an item. A center inside a display stays there;
    /// an item clipped outside every display stays with the nearest bar.
    static func owner(of frame: CGRect, among geometries: [MenuBarOverflowGeometry]) -> MenuBarOverflowGeometry? {
        let row = geometries.filter {
            frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0 &&
            frame.height <= $0.barHeight + 8 &&
            abs(frame.minY - $0.screen.minY) <= $0.barHeight
        }
        guard !row.isEmpty else { return nil }
        if let inside = row.first(where: { frame.midX >= $0.screen.minX && frame.midX < $0.screen.maxX }) {
            return inside
        }
        return row.min { abs($0.screen.midX - frame.midX) < abs($1.screen.midX - frame.midX) }
    }
}

struct MenuBarOverflowIdentity: Hashable {
    let pid: pid_t
    let launchDate: Date
    let windowID: CGWindowID?
    let ordinal: Int
}

struct MenuBarOverflowItem {
    let id: MenuBarOverflowIdentity
    let title: String
    let frame: CGRect
    let element: AXUIElement
    let canPress: Bool
    var image: NSImage?
}

struct MenuBarOverflowApplication {
    let pid: pid_t
    let launchDate: Date
    let name: String
    let icon: NSImage?
    let isControlCenter: Bool
}

struct MenuBarOverflowContext {
    let geometry: MenuBarOverflowGeometry
    /// Every display menu bar. Older callers pass only `geometry`.
    var geometries: [MenuBarOverflowGeometry]
    let applications: [MenuBarOverflowApplication]
    let frontPID: pid_t?

    init(geometry: MenuBarOverflowGeometry, geometries: [MenuBarOverflowGeometry]? = nil,
         applications: [MenuBarOverflowApplication], frontPID: pid_t?) {
        self.geometry = geometry
        self.geometries = geometries?.isEmpty == false ? geometries! : [geometry]
        self.applications = applications
        self.frontPID = frontPID
    }
}

enum MenuBarOverflowStatus {
    case disabled, needsPermission, unsupportedDisplay, suspended, loading, ready, partial, failed, activating, unconfirmed

    var messageKey: L10nKey {
        switch self {
        case .disabled: return .overflowDisabled
        case .needsPermission: return .overflowPermission
        case .unsupportedDisplay: return .overflowDisplay
        case .suspended: return .overflowSuspended
        case .loading: return .overflowLoading
        case .ready: return .overflowReady
        case .partial: return .overflowPartial
        case .failed: return .overflowFailed
        case .activating: return .overflowActivating
        case .unconfirmed: return .overflowUnconfirmed
        }
    }
}

/// Shared cancellation for bounded AX reads. Never queue unbounded work for a hung app.
final class MenuBarOverflowCancellation {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum MenuBarOverflowActivationResult { case requested, unconfirmed, unavailable, cancelled }

struct MenuBarOverflowScan {
    let items: [MenuBarOverflowItem]
    let isComplete: Bool
}

protocol MenuBarOverflowProviding {
    func scan(_ context: MenuBarOverflowContext, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowScan
    func press(_ item: MenuBarOverflowItem, cancellation: MenuBarOverflowCancellation) -> MenuBarOverflowActivationResult
}
