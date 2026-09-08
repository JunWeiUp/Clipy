import Foundation
import Darwin

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func runCoreRegressionTests() {
    runWordLookupRegressionTests()
    func entry(_ text: String, _ date: Double = 1) -> HistoryEntry {
        HistoryEntry(item: .text(text), date: Date(timeIntervalSince1970: date), sourceApp: nil, contentHash: nil)
    }
    var pages = 0
    let fixtures = [entry("foo middle bar"), HistoryEntry(item: .image("unused"), date: Date(), sourceApp: nil, contentHash: nil, searchIndex: "发票编号")]
    func search(_ query: String, regex: Bool = false, limit: Int = 10) -> [HistorySearchResult] {
        HistorySearchService.search(options: SearchHistoryOptions(query: query, useRegex: regex, browseLimit: limit),
            defaultLimit: 10, cancellation: nil, fetchPage: { _, cursor, size in
                check(size <= 128, "unbounded page")
                pages += 1
                return cursor == Int64.max ? (fixtures, 1) : ([], nil)
            }, fetchBrowse: { _, _ in fatalError("unexpected browse") })
    }
    check(search("foo.*bar", regex: true).count == 1, "regex was filtered out")
    check(search("foo bar").count == 1, "multi-term fuzzy match was filtered out")
    check(search("fmb").count == 1, "subsequence match was filtered out")
    check(search("发票编号").count == 1, "OCR match was lost")
    check(search("发票编号")[0].entry.searchIndex == nil, "UI retains OCR index")
    let previousPages = pages
    check(search("[", regex: true).isEmpty && pages == previousPages, "invalid regex read the DB")
    check(HistorySearchQueryParser.parse("https://example.com").textTerms == ["https://example.com"], "URL swallowed as filter")
    let cancellation = HistorySearchCancellation()
    var batches = 0
    let cancelled = HistorySearchService.search(options: SearchHistoryOptions(query: "foo"), defaultLimit: 10,
        cancellation: cancellation, fetchPage: { _, _, _ in
            batches += 1; cancellation.cancel(); return ([entry("foo")], 1)
        }, fetchBrowse: { _, _ in [] })
    check(cancelled.isEmpty && batches == 1, "cancelled search keeps scanning")
    var cursorSeen = Int64.max
    let ranked = HistorySearchService.search(options: SearchHistoryOptions(query: "foo", browseLimit: 3),
        defaultLimit: 3, cancellation: nil, fetchPage: { _, cursor, _ in
            check(cursor <= cursorSeen, "cursor did not advance")
            cursorSeen = cursor
            if cursor == 1 { return ([], nil) }
            let page = (0..<128).map { entry("foo", Double(cursor == Int64.max ? $0 : $0 + 128)) }
            return (page, cursor == Int64.max ? 129 : 1)
        }, fetchBrowse: { _, _ in [] })
    check(ranked.count == 3 && ranked[0].entry.date.timeIntervalSince1970 == 255, "top K ignored later pages")
    print("Search regressions passed (regex, fuzzy, OCR, cancellation, bounded top K).")

    let manager = SyncManager()
    let listenerReady = DispatchSemaphore(value: 0)
    manager.syncQueue.sync {
        manager.startListening(port: 0)
        let fd = manager.listenFD
        manager.startListening(port: 0)
        check(manager.listenFD == fd, "duplicate start replaced the listener")
        manager.stopListening()
        manager.startListening(port: 0) // Old cancel handler has not run yet.
        manager.syncQueue.asyncAfter(deadline: .now() + 0.05) {
            check(manager.listenFD >= 0 && fcntl(manager.listenFD, F_GETFD) >= 0,
                  "old cancellation closed the new listener")
            manager.stopListening()
            listenerReady.signal()
        }
    }
    check(listenerReady.wait(timeout: .now() + 2) == .success, "listener restart hung")
    print("Listener regressions passed (duplicate start and stop/start race).")

    // A non-reading socket saturates, but another writer on the SAME queue
    // must still complete. Timeout/cancel release all pending callbacks.
    let queue = DispatchQueue(label: "clipy.test.writers")
    func pair() -> [Int32] {
        var fds: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair")
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        var small: Int32 = 4096
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        return fds
    }
    let slow = pair(), fast = pair()
    let slowClosed = DispatchSemaphore(value: 0), fastSent = DispatchSemaphore(value: 0)
    var slowWriter: SyncSocketWriter!
    var fastWriter: SyncSocketWriter!
    var failures = 0
    queue.sync {
        slowWriter = SyncSocketWriter(fd: slow[0], queue: queue, byteLimit: 512 * 1024, timeout: 0.2) {
            slowWriter.cancel { Darwin.close(slow[0]); slowClosed.signal() }
        }
        fastWriter = SyncSocketWriter(fd: fast[0], queue: queue) { fatalError("fast writer failed") }
        check(slowWriter.enqueue(Data(repeating: 7, count: 512 * 1024)) { ok in
            check(!ok, "stalled frame unexpectedly completed"); failures += 1
        }, "first frame rejected")
        check(!slowWriter.enqueue(Data([1])), "buffer limit not enforced")
        check(fastWriter.enqueue(Data("hello".utf8)) { ok in
            check(ok, "fast frame failed"); fastSent.signal()
        }, "fast frame rejected")
    }
    check(fastSent.wait(timeout: .now() + 1) == .success, "slow peer blocked another session")
    check(slowClosed.wait(timeout: .now() + 2) == .success, "stalled writer did not time out")
    let closed = DispatchSemaphore(value: 0)
    queue.sync {
        check(failures == 1, "pending callback not completed exactly once")
        check(!slowWriter.enqueue(Data([2])), "closed writer accepted a frame")
        fastWriter.cancel { Darwin.close(fast[0]); closed.signal() }
    }
    check(closed.wait(timeout: .now() + 2) == .success, "idle writer cancellation hung")
    Darwin.close(slow[1]); Darwin.close(fast[1])
    let ordered = pair()
    let received = DispatchSemaphore(value: 0)
    let orderedClosed = DispatchSemaphore(value: 0)
    var orderedWriter: SyncSocketWriter!
    let expected = Data(repeating: 1, count: 200_000) + Data(repeating: 2, count: 200_000) + Data(repeating: 3, count: 200_000)
    DispatchQueue.global().async {
        var actual = Data(), scratch = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(5)
        while actual.count < expected.count && Date() < deadline {
            let count = recv(ordered[1], &scratch, scratch.count, 0)
            if count > 0 { actual.append(contentsOf: scratch.prefix(count)) }
            else { usleep(1000) }
        }
        check(actual == expected, "partial writes lost bytes or reordered frames")
        received.signal()
    }
    queue.sync {
        orderedWriter = SyncSocketWriter(fd: ordered[0], queue: queue) { fatalError("ordered writer failed") }
        for byte in UInt8(1)...UInt8(3) {
            check(orderedWriter.enqueue(Data(repeating: byte, count: 200_000)), "ordered enqueue failed")
        }
    }
    check(received.wait(timeout: .now() + 6) == .success, "partial write test hung")
    queue.sync { orderedWriter.cancel { Darwin.close(ordered[0]); orderedClosed.signal() } }
    check(orderedClosed.wait(timeout: .now() + 2) == .success, "ordered cancel hung")
    Darwin.close(ordered[1])
    print("Socket regressions passed (bounded FIFO, peer isolation, timeout, cancellation).")
}
