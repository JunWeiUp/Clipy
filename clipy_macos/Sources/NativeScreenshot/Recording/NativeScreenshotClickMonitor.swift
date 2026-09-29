import CoreGraphics
import Foundation

/// Read-only event tap used for click rings on macOS 13/14.
/// start/stop must run on the main thread, which owns the tap's run-loop source.
final class NativeScreenshotClickMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onClick: ((CGPoint) -> Void)?

    @discardableResult
    func start() -> Bool {
        precondition(Thread.isMainThread)
        guard CGPreflightListenEventAccess() else { return false }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<NativeScreenshotClickMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .leftMouseDown || type == .rightMouseDown {
                    monitor.onClick?(event.location)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        onClick = nil
    }
}
