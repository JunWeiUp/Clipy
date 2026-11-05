import Foundation

@main
struct SyncInboundBudgetRegression {
    static func main() {
        let a = UUID(), b = UUID(), replacement = UUID()
        var budget = SyncInboundBudget(limits: .init(sessionBytes: 10, sessionTasks: 2,
                                                     globalBytes: 15, globalTasks: 3))
        precondition(budget.reserve(bytes: 0, sessionID: a) == nil)
        precondition(budget.reserve(bytes: -1, sessionID: a) == nil)
        precondition(budget.reserve(bytes: Int.max, sessionID: a) == nil)
        let first = budget.reserve(bytes: 6, sessionID: a)!
        precondition(budget.reserve(bytes: 5, sessionID: a) == nil, "per-session byte ceiling")
        let second = budget.reserve(bytes: 4, sessionID: a)!
        precondition(budget.usage(for: a) == .init(bytes: 10, tasks: 2))
        precondition(budget.reserve(bytes: 1, sessionID: a) == nil, "per-session task ceiling")
        let third = budget.reserve(bytes: 5, sessionID: b)!
        precondition(budget.total == .init(bytes: 15, tasks: 3))
        precondition(budget.reserve(bytes: 1, sessionID: replacement) == nil,
                     "replacement cannot evade outstanding global charges")
        precondition(budget.release(first))
        precondition(!budget.release(first), "duplicate completion must not refund twice")
        precondition(budget.reserve(bytes: 7, sessionID: replacement) == nil, "global bytes")
        let fourth = budget.reserve(bytes: 6, sessionID: replacement)!
        precondition(budget.reserve(bytes: 1, sessionID: b) == nil, "global task ceiling")
        for ticket in [second, third, fourth] { precondition(budget.release(ticket)) }
        precondition(budget.total == .init() && budget.usage(for: a) == .init())

        // Isolate count limits from byte limits: many tiny notifications must
        // stop even with ample byte headroom.
        var tiny = SyncInboundBudget(limits: .init(sessionBytes: 100, sessionTasks: 2,
                                                   globalBytes: 1000, globalTasks: 3))
        let t1 = tiny.reserve(bytes: 1, sessionID: a)!
        let t2 = tiny.reserve(bytes: 1, sessionID: a)!
        precondition(tiny.reserve(bytes: 1, sessionID: a) == nil, "session count alone")
        let t3 = tiny.reserve(bytes: 1, sessionID: b)!
        precondition(tiny.reserve(bytes: 1, sessionID: replacement) == nil, "global count alone")
        for ticket in [t1, t2, t3] { precondition(tiny.release(ticket)) }
        var bytesOnly = SyncInboundBudget(limits: .init(sessionBytes: 10, sessionTasks: 100,
                                                        globalBytes: 15, globalTasks: 100))
        _ = bytesOnly.reserve(bytes: 10, sessionID: a)!
        precondition(bytesOnly.reserve(bytes: 1, sessionID: a) == nil, "session bytes alone")
        _ = bytesOnly.reserve(bytes: 5, sessionID: b)!
        precondition(bytesOnly.reserve(bytes: 1, sessionID: replacement) == nil, "global bytes alone")
        var production = SyncInboundBudget()
        let maximumFrame = production.reserve(bytes: 2 * 1024 * 1024, sessionID: a)!
        precondition(production.release(maximumFrame), "legal maximum frame must make progress")

        // Deterministic slow-consumer burst: retain denied frames at the head;
        // repeatedly complete one job, then drain buffered work before reading more.
        var pending = Array(0..<10_000), accepted: [Int] = [], completed: [Int] = []
        var inFlight: [(Int, SyncInboundBudget.Ticket)] = []
        while !pending.isEmpty || !inFlight.isEmpty {
            while let next = pending.first,
                  let ticket = budget.reserve(bytes: next.isMultiple(of: 2) ? 4 : 3,
                                              sessionID: next.isMultiple(of: 2) ? a : b) {
                pending.removeFirst()
                accepted.append(next)
                inFlight.append((next, ticket))
                precondition(budget.total.bytes <= 15 && budget.total.tasks <= 3)
            }
            let job = inFlight.removeFirst()
            completed.append(job.0)
            precondition(budget.release(job.1))
        }
        precondition(accepted == Array(0..<10_000) && completed == accepted, "FIFO loss/duplication")
        precondition(budget.total == .init(), "idle accounting must release")
        print("SyncInboundBudgetRegression passed")
    }
}
