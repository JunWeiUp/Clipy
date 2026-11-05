import Foundation

/// Only an actual close may tear down a window. Handoff hides preserve drafts.
/// Callers can inject a shorter/longer reuse interval without a global timer.
struct WindowSessionReusePolicy {
    static let defaultDelay: TimeInterval = 30
    let delay: TimeInterval
    private(set) var generation: UInt64 = 0
    private var closed = false

    init(delay: TimeInterval = Self.defaultDelay) {
        self.delay = delay.isFinite ? max(0, delay) : Self.defaultDelay
    }
    mutating func keepAlive() { generation &+= 1; closed = false }
    mutating func didClose() -> UInt64 {
        generation &+= 1
        closed = true
        return generation
    }
    func shouldTeardown(generation: UInt64, isVisible: Bool) -> Bool {
        closed && self.generation == generation && !isVisible
    }
}
