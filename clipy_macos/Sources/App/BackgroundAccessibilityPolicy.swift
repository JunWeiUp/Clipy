import Foundation

/// AX reads of our own process can execute AppKit/SwiftUI getters inline on the
/// worker. Messaging timeouts only bound remote IPC, not those local getters.
enum BackgroundAccessibilityPolicy {
    static func canRead(pid: pid_t, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        pid > 0 && pid != ownPID
    }
}
