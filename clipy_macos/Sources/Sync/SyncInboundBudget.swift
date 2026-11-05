import Foundation

/// Queue-confined admission accounting, independent of sockets and main-thread storage.
/// Charge the encoded frame (including metadata), before decoding/decrypting it.
/// Decrypted UTF-8 is smaller than its base64 envelope; queued work must not also
/// retain the envelope/ciphertext. Task limits bound small-frame/closure overhead.
struct SyncInboundBudget {
    struct Limits {
        var sessionBytes = 4 * 1024 * 1024
        var sessionTasks = 32
        var globalBytes = 16 * 1024 * 1024
        var globalTasks = 128
    }
    struct Usage: Equatable {
        var bytes = 0
        var tasks = 0
    }
    struct Ticket: Hashable {
        fileprivate let id: UUID
        let sessionID: UUID
        let bytes: Int
    }

    let limits: Limits
    private(set) var total = Usage()
    private var sessions: [UUID: Usage] = [:]
    private var tickets = Set<Ticket>()

    init(limits: Limits = Limits()) { self.limits = limits }

    func usage(for sessionID: UUID) -> Usage { sessions[sessionID] ?? Usage() }

    mutating func reserve(bytes: Int, sessionID: UUID) -> Ticket? {
        let usage = usage(for: sessionID)
        guard bytes > 0, bytes <= limits.sessionBytes, bytes <= limits.globalBytes,
              usage.tasks < limits.sessionTasks, total.tasks < limits.globalTasks,
              usage.bytes <= limits.sessionBytes - bytes,
              total.bytes <= limits.globalBytes - bytes else { return nil }
        let ticket = Ticket(id: UUID(), sessionID: sessionID, bytes: bytes)
        tickets.insert(ticket)
        sessions[sessionID] = Usage(bytes: usage.bytes + bytes, tasks: usage.tasks + 1)
        total.bytes += bytes
        total.tasks += 1
        return ticket
    }

    /// Closing a session does NOT reset its accounting: dispatched main work still
    /// owns plaintext until it runs (or skips its stale generation) and completes.
    /// This prevents rapid stop/replacement from accumulating uncharged closures.
    @discardableResult
    mutating func release(_ ticket: Ticket) -> Bool {
        guard tickets.remove(ticket) != nil else { return false }
        var usage = usage(for: ticket.sessionID)
        usage.bytes -= ticket.bytes
        usage.tasks -= 1
        if usage.tasks == 0 { sessions.removeValue(forKey: ticket.sessionID) }
        else { sessions[ticket.sessionID] = usage }
        total.bytes -= ticket.bytes
        total.tasks -= 1
        return true
    }
}
