import Foundation

/// One main-thread, latest-only recognition slot. Owners cancel on close or image/selection
/// changes; generation checks also protect follow-up work (such as translation).
@MainActor
final class ScreenshotOCRTaskOwner {
    var task: OCRTask?
    private(set) var generation: UInt = 0

    @discardableResult
    func begin() -> UInt {
        cancel()
        return generation
    }

    func isCurrent(_ generation: UInt) -> Bool {
        self.generation == generation
    }

    func finish(_ generation: UInt) {
        guard isCurrent(generation) else { return }
        task = nil
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// Independent drawing gestures are not replaceable queries. Reserve a bounded
/// slot for each gesture; only teardown/undo invalidates all unfinished gestures.
@MainActor
final class ScreenshotOCRGestureTasks {
    private struct Entry { var task: OCRTask? }
    private var entries: [UUID: Entry] = [:]
    let limit: Int
    var count: Int { entries.count }

    init(limit: Int = 4) { self.limit = limit }

    func reserve() -> UUID? {
        guard entries.count < limit else { return nil }
        let id = UUID()
        entries[id] = Entry()
        return id
    }

    func attach(_ task: OCRTask?, to id: UUID) {
        guard entries[id] != nil else { task?.cancel(); return }
        guard let task else { entries[id] = nil; return }
        entries[id]?.task = task
    }

    @discardableResult
    func finish(_ id: UUID) -> Bool { entries.removeValue(forKey: id) != nil }

    func cancel() {
        let previous = entries
        entries.removeAll()
        for entry in previous.values { entry.task?.cancel() }
    }

    deinit { for entry in entries.values { entry.task?.cancel() } }
}
