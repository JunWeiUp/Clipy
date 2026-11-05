import Foundation

func runUIMemoryPolicyRegressionTests() {
    var search = LatestOnlyUIWork<String>()
    let a = search.submit("A", generation: search.invalidate())!
    let bGeneration = search.invalidate() // Keystroke, before debounce fires.
    precondition(!search.accepts(a), "Old query accepted during debounce")
    precondition(search.submit("B", generation: bGeneration) == nil)
    for index in 0..<1000 {
        let generation = search.invalidate()
        precondition(search.submit("query-\(index)", generation: generation) == nil)
    }
    precondition(search.running?.request == "A" && search.pending?.request == "query-999")
    let latest = search.finish(a)!
    precondition(latest.request == "query-999" && search.pending == nil)
    precondition(search.accepts(latest))
    let pending = search.invalidate()
    precondition(search.submit("queued at close", generation: pending) == nil)
    search.invalidate() // close clears pending, keeps the real in-flight slot.
    precondition(search.pending == nil && !search.accepts(latest))
    precondition(search.finish(latest) == nil && search.running == nil)
    let reopened = search.submit("A", generation: search.invalidate())!
    precondition(!search.accepts(a) && search.accepts(reopened), "A→B→A/reopen aliased old generation")
    precondition(search.submit("stale debounce", generation: a.generation) == nil)
    precondition(search.finish(a) == nil && search.running?.generation == reopened.generation)
    let cancellation = UIWorkCancellation()
    precondition(!cancellation.isCancelled)
    cancellation.cancel()
    precondition(cancellation.isCancelled)

    var misses = UIExpiringMisses<String>(limit: 128, ttl: 60)
    for index in 0..<1000 { misses.insert("app-\(index)", now: Double(index) / 1000) }
    precondition(misses.count == 128)
    precondition(!misses.contains("app-0", now: 1))
    precondition(misses.contains("app-999", now: 1))
    precondition(!misses.contains("app-999", now: 61) && misses.count == 0)
    misses.insert("reinstalled", now: 100)
    precondition(!misses.contains("reinstalled", now: 160), "Miss should expire at its exact deadline")
    misses.insert("app", now: 200)
    misses.removeAll()
    precondition(misses.count == 0)

    var thumbnails = UIKeyedWorkPolicy<String>(concurrency: 2, pendingLimit: 3)
    precondition(thumbnails.request("a") && thumbnails.request("a"))
    precondition(thumbnails.pending == ["a"], "Duplicate pending decode")
    precondition(thumbnails.takeNext() == "a")
    precondition(thumbnails.request("a") && thumbnails.pending.isEmpty, "Duplicate running decode")
    precondition(thumbnails.request("b") && thumbnails.takeNext() == "b")
    precondition(thumbnails.request("c") && thumbnails.request("d") && thumbnails.request("e"))
    precondition(!thumbnails.request("overflow") && thumbnails.takeNext() == nil)
    thumbnails.cancelPending("c")
    thumbnails.cancelPending("a") // Cancelling subscribers cannot free an active decode slot.
    precondition(thumbnails.running.count == 2 && thumbnails.pending == ["d", "e"])
    thumbnails.finish("a")
    precondition(thumbnails.takeNext() == "d" && thumbnails.running.count == 2)

    var window = WindowSessionReusePolicy()
    precondition(window.delay == 30)
    let closed = window.didClose()
    precondition(window.shouldTeardown(generation: closed, isVisible: false))
    precondition(!window.shouldTeardown(generation: closed, isVisible: true))
    window.keepAlive() // Reopen or temporarily hidden for handoff.
    precondition(!window.shouldTeardown(generation: closed, isVisible: false))
    let secondClose = window.didClose()
    precondition(!window.shouldTeardown(generation: closed, isVisible: false))
    precondition(window.shouldTeardown(generation: secondClose, isVisible: false))
    precondition(WindowSessionReusePolicy(delay: 1).delay == 1)
    precondition(WindowSessionReusePolicy(delay: -1).delay == 0)
    precondition(WindowSessionReusePolicy(delay: .nan).delay == 30)
    print("UI memory policy regressions passed (latest-only, close/reopen, bounded misses/decodes, handoff).")
}

#if CLIPY_UI_MEMORY_POLICY_STANDALONE
@main private enum UIMemoryPolicyRegressionMain {
    static func main() { runUIMemoryPolicyRegressionTests() }
}
#endif
