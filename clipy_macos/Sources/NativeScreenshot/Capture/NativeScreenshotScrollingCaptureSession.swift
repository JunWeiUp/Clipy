import ApplicationServices
import CoreGraphics
import Foundation

/// Coordinates one long screenshot. UI windows must be hidden in `beforeFrame`
/// before each capture and can be restored in `afterFrame`.
@MainActor
final class NativeScreenshotScrollingCaptureSession {
    enum SessionError: Error {
        case notStarted
        case alreadyStarted
        case automaticScrollNeedsAccessibility
    }

    struct Options {
        var maximumHeight: Int = 30_000
        var maximumPixels: Int = 100_000_000
        var autoScrollSpeed: Int = 3
        var detectFrozenEdges = true
        var showsCursor = false
    }

    typealias BeforeFrame = () async -> Void
    typealias AfterFrame = () -> Void

    private let region: CGRect
    private let options: Options
    private let beforeFrame: BeforeFrame
    private let afterFrame: AfterFrame
    private var assembler: NativeScreenshotScrollAssembler?
    private var activeCapture: NativeScreenshotStaticCapture?
    private var automaticTask: Task<Void, Never>?
    private var isCancelled = false
    private var isFinished = false

    init(region: CGRect, options: Options,
         beforeFrame: @escaping BeforeFrame,
         afterFrame: @escaping AfterFrame) {
        self.region = region
        self.options = options
        self.beforeFrame = beforeFrame
        self.afterFrame = afterFrame
    }

    func start() async throws -> CGImage {
        guard assembler == nil else { throw SessionError.alreadyStarted }
        guard !isCancelled && !isFinished else { throw CancellationError() }
        let first = try await captureFrame()
        guard !isCancelled && !isFinished else { throw CancellationError() }
        assembler = try NativeScreenshotScrollAssembler(
            firstFrame: first,
            maximumHeight: options.maximumHeight,
            maximumPixels: options.maximumPixels,
            detectFrozenEdges: options.detectFrozenEdges
        )
        return first
    }

    func captureNext() async throws -> (NativeScreenshotScrollAssembler.AppendResult, CGImage?) {
        guard let assembler else { throw SessionError.notStarted }
        let frame = try await captureFrame()
        guard !isCancelled && !isFinished else { throw CancellationError() }
        let result = try assembler.append(frame)
        let preview: CGImage?
        switch result {
        case .appended:
            let plan = try assembler.renderPlan()
            preview = try await Task.detached(priority: .userInitiated) {
                try plan.render(maximumWidth: 360)
            }.value
            guard !isCancelled && !isFinished else { throw CancellationError() }
        case .noMovement, .uncertainOverlap, .heightLimit:
            preview = nil
        }
        return (result, preview)
    }

    func startAutomaticScroll(
        onFrame: @escaping (NativeScreenshotScrollAssembler.AppendResult, CGImage?) -> Void,
        onError: @escaping (Error) -> Void,
        onReachedEnd: @escaping () -> Void
    ) throws {
        guard assembler != nil else { throw SessionError.notStarted }
        guard automaticTask == nil else { return }
        guard AXIsProcessTrusted() else {
            throw SessionError.automaticScrollNeedsAccessibility
        }
        let speed = min(5, max(1, options.autoScrollSpeed))
        automaticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var noMovementStreak = 0
            while !Task.isCancelled && !self.isCancelled {
                self.postScroll(distance: speed * 2)
                do {
                    try await Task.sleep(nanoseconds: 420_000_000)
                    let (result, preview) = try await self.captureNext()
                    onFrame(result, preview)
                    if result == .heightLimit { break }
                    if result == .noMovement {
                        noMovementStreak += 1
                        if noMovementStreak >= 6 {
                            onReachedEnd()
                            break
                        }
                    } else {
                        noMovementStreak = 0
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch is CancellationError {
                    break
                } catch {
                    onError(error)
                    break
                }
            }
            self.automaticTask = nil
        }
    }

    func stopAutomaticScroll() {
        automaticTask?.cancel()
        automaticTask = nil
    }

    func finish() async throws -> CGImage {
        stopAutomaticScroll()
        guard let assembler else { throw SessionError.notStarted }
        isFinished = true
        activeCapture?.cancel()
        let plan = try assembler.renderPlan()
        self.assembler = nil
        activeCapture = nil
        return try await Task.detached(priority: .userInitiated) {
            try plan.render()
        }.value
    }

    func cancel() {
        isCancelled = true
        stopAutomaticScroll()
        activeCapture?.cancel()
        activeCapture = nil
        assembler = nil
    }

    private func captureFrame() async throws -> CGImage {
        guard !isCancelled && !isFinished else { throw CancellationError() }
        await beforeFrame()
        defer { afterFrame() }
        guard !isCancelled && !isFinished else { throw CancellationError() }
        let capture = NativeScreenshotStaticCapture()
        activeCapture = capture
        defer { activeCapture = nil }
        let result = try await capture.captureRegion(region, showsCursor: options.showsCursor)
        return result.image
    }

    private func postScroll(distance: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: -Int32(distance),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = CGPoint(x: region.midX, y: region.midY)
        event.post(tap: .cghidEventTap)
    }
}
