import Foundation
import Darwin

/// Confined to the session queue. Writable events drain a bounded FIFO without
/// poll/wait, so a stalled peer cannot block reads, heartbeats or other peers.
/// The owner closes the fd only after both read and write sources cancel.
final class SyncSocketWriter {
    private struct Frame {
        let data: Data
        let completion: ((Bool) -> Void)?
    }
    private let fd: Int32
    private let queue: DispatchQueue
    private let byteLimit: Int
    private let timeout: TimeInterval
    private let onFailure: () -> Void
    private let onDrained: () -> Void
    private var frames: [Frame] = []
    private var retainedBytes = 0
    private var offset = 0
    private var source: DispatchSourceWrite?
    private var timer: DispatchSourceTimer?
    private var lastProgress = DispatchTime.now()
    private var suspended = true
    private(set) var isClosed = false

    init(fd: Int32, queue: DispatchQueue, byteLimit: Int = 4 * 1024 * 1024,
         timeout: TimeInterval = 10, onDrained: @escaping () -> Void = {}, onFailure: @escaping () -> Void) {
        self.fd = fd
        self.queue = queue
        self.byteLimit = byteLimit
        self.timeout = timeout
        self.onFailure = onFailure
        self.onDrained = onDrained
    }

    func canEnqueue(_ data: Data) -> Bool {
        !isClosed && frames.count < 256 && data.count <= byteLimit - retainedBytes
    }

    @discardableResult
    func enqueue(_ data: Data, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard canEnqueue(data) else {
            completion?(false)
            return false
        }
        if data.isEmpty { completion?(true); return true }
        let wasEmpty = frames.isEmpty
        frames.append(Frame(data: data, completion: completion))
        retainedBytes += data.count
        if source == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            self.source = source
        }
        if wasEmpty {
            lastProgress = .now()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout, repeating: timeout)
            timer.setEventHandler { [weak self] in
                guard let self, !self.frames.isEmpty else { return }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.lastProgress.uptimeNanoseconds) / 1_000_000_000
                if elapsed >= self.timeout { self.fail() }
            }
            self.timer = timer
            timer.resume()
            if suspended { suspended = false; source?.resume() }
        }
        return true
    }

    private func drain() {
        guard !isClosed else { return }
        var budget = 256 * 1024
        while !frames.isEmpty && budget > 0 {
            let count = frames[0].data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.send(fd, base + offset, min(raw.count - offset, budget), 0)
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else { fail(); return }
            lastProgress = .now()
            offset += count
            budget -= count
            if offset == frames[0].data.count {
                let frame = frames.removeFirst()
                retainedBytes -= frame.data.count
                offset = 0
                frame.completion?(true)
                if isClosed { return }
            }
        }
        if frames.isEmpty {
            frames = []
            timer?.cancel(); timer = nil
            if !suspended { suspended = true; source?.suspend() }
            onDrained()
        }
    }

    private func fail() {
        guard !isClosed else { return }
        // Owner cancels both sources and closes the session; do not close fd here.
        onFailure()
    }

    func cancel(completion: @escaping () -> Void) {
        guard !isClosed else { completion(); return }
        isClosed = true
        timer?.cancel(); timer = nil
        let pending = frames
        frames = []; retainedBytes = 0; offset = 0
        if let source {
            source.setCancelHandler(handler: completion)
            source.cancel()
            if suspended { suspended = false; source.resume() }
            self.source = nil
        } else { completion() }
        for frame in pending { frame.completion?(false) }
    }
}
