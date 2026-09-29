import Foundation

struct NativeScreenshotStartupTimeout: LocalizedError, Equatable {
    let stage: String

    var errorDescription: String? {
        NativeScreenshotUserText.string(
            "截图启动超时，请重试。", "Screenshot startup timed out. Please try again.")
    }
}

/// Returns at the deadline even when a ScreenCaptureKit async call does not
/// promptly respond to task cancellation. A late result is discarded.
@MainActor
enum NativeScreenshotStartupDeadline {
    static func run<Value>(
        stage: String,
        nanoseconds: UInt64,
        onTimeout: @escaping @MainActor () -> Void,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let completion = NativeScreenshotStartupCompletion<Value>()
        let boxed: NativeScreenshotStartupValue<Value> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.continuation = continuation
                completion.operationTask = Task { [weak completion] in
                    do { completion?.finish(.success(.init(value: try await operation()))) }
                    catch { completion?.finish(.failure(error)) }
                }
                completion.deadlineTask = Task {
                    do { try await Task.sleep(nanoseconds: nanoseconds) }
                    catch { return }
                    if completion.finish(
                        .failure(NativeScreenshotStartupTimeout(stage: stage)),
                        cancelOperation: true
                    ) {
                        onTimeout()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                completion.finish(.failure(CancellationError()), cancelOperation: true)
            }
        }
        return boxed.value
    }
}

/// ScreenCaptureKit's Objective-C result objects are used only on the main
/// actor. The continuation itself must carry a Sendable value across tasks.
private struct NativeScreenshotStartupValue<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
private final class NativeScreenshotStartupCompletion<Value> {
    var continuation: CheckedContinuation<NativeScreenshotStartupValue<Value>, Error>?
    var operationTask: Task<Void, Never>?
    var deadlineTask: Task<Void, Never>?
    private var completed = false

    @discardableResult
    func finish(
        _ result: Result<NativeScreenshotStartupValue<Value>, Error>,
        cancelOperation: Bool = false
    ) -> Bool {
        guard !completed else { return false }
        completed = true
        deadlineTask?.cancel()
        if cancelOperation { operationTask?.cancel() }
        continuation?.resume(with: result)
        continuation = nil
        operationTask = nil
        deadlineTask = nil
        return true
    }
}
