import Foundation

/// Main-thread-owned policy: one running request and one replaceable latest request.
/// Invalidation does not free the running slot until its completion acknowledges it.
struct LatestOnlyUIWork<Request> {
    struct Ticket {
        let generation: UInt64
        let request: Request
    }
    private(set) var generation: UInt64 = 0
    private(set) var running: Ticket?
    private(set) var pending: Ticket?

    @discardableResult mutating func invalidate() -> UInt64 {
        generation &+= 1
        pending = nil
        return generation
    }

    mutating func submit(_ request: Request, generation: UInt64) -> Ticket? {
        guard generation == self.generation else { return nil }
        let ticket = Ticket(generation: generation, request: request)
        guard running == nil else { pending = ticket; return nil }
        running = ticket
        return ticket
    }

    mutating func finish(_ ticket: Ticket) -> Ticket? {
        guard running?.generation == ticket.generation else { return nil }
        running = nil
        guard let next = pending else { return nil }
        pending = nil
        running = next
        return next
    }

    func accepts(_ ticket: Ticket) -> Bool { ticket.generation == generation }
}

/// Cancellation may be read on a worker; all scheduling policy stays on main.
final class UIWorkCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Negative-cache entries expire lazily, without a timer or an unbounded miss set.
struct UIExpiringMisses<Key: Hashable> {
    let limit: Int
    let ttl: TimeInterval
    private var deadlines: [Key: TimeInterval] = [:]
    var count: Int { deadlines.count }

    mutating func contains(_ key: Key, now: TimeInterval) -> Bool {
        deadlines = deadlines.filter { $0.value > now }
        return deadlines[key] != nil
    }
    mutating func insert(_ key: Key, now: TimeInterval) {
        guard limit > 0, ttl > 0 else { return }
        deadlines = deadlines.filter { $0.value > now }
        if deadlines[key] == nil, deadlines.count >= limit,
           let oldest = deadlines.min(by: { $0.value < $1.value })?.key {
            deadlines.removeValue(forKey: oldest)
        }
        deadlines[key] = now + ttl
    }
    mutating func removeAll() { deadlines.removeAll() }
}

/// Keyed decode slots remain occupied even if their last subscriber disappears.
/// A new subscriber may join that decode, but cannot start a duplicate decoder.
struct UIKeyedWorkPolicy<Key: Hashable> {
    let concurrency: Int
    let pendingLimit: Int
    private(set) var running = Set<Key>()
    private(set) var pending: [Key] = []

    mutating func request(_ key: Key) -> Bool {
        if running.contains(key) || pending.contains(key) { return true }
        guard pending.count < pendingLimit else { return false }
        pending.append(key)
        return true
    }
    mutating func takeNext() -> Key? {
        guard running.count < concurrency, !pending.isEmpty else { return nil }
        let key = pending.removeFirst()
        running.insert(key)
        return key
    }
    mutating func cancelPending(_ key: Key) { pending.removeAll { $0 == key } }
    mutating func finish(_ key: Key) { running.remove(key) }
}
