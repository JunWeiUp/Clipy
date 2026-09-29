import Foundation

@main
enum NativeScreenshotStartupRegression {
    static func main() async throws {
        localizedTimeoutMessage()
        try await successBeforeDeadline()
        try await timeoutIgnoresLateResult()
        try await cancellationReturnsPromptly()
        print("NativeScreenshotStartupRegression passed")
    }

    private static func localizedTimeoutMessage() {
        let previousLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "appLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "appLanguage")
            }
        }
        let timeout = NativeScreenshotStartupTimeout(stage: "capturing display 7")
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        precondition(timeout.errorDescription == "截图启动超时，请重试。",
                     "startup timeout ignored the app's Chinese language")
        precondition(timeout.localizedDescription == "截图启动超时，请重试。",
                     "the user-visible Chinese error did not use the localized description")
        UserDefaults.standard.set("en", forKey: "appLanguage")
        precondition(timeout.errorDescription == "Screenshot startup timed out. Please try again.",
                     "startup timeout ignored the app's English language")
        precondition(timeout.localizedDescription == "Screenshot startup timed out. Please try again.",
                     "the user-visible English error did not use the localized description")
        precondition(timeout.stage == "capturing display 7",
                     "localization should not discard the diagnostic stage")
    }

    @MainActor
    private static func successBeforeDeadline() async throws {
        var timeoutCount = 0
        let value = try await NativeScreenshotStartupDeadline.run(
            stage: "success", nanoseconds: 500_000_000,
            onTimeout: { timeoutCount += 1 }
        ) {
            try await Task.sleep(nanoseconds: 10_000_000)
            return 42
        }
        precondition(value == 42 && timeoutCount == 0,
                     "a successful first frame was treated as a timeout")
    }

    @MainActor
    private static func timeoutIgnoresLateResult() async throws {
        var pending: CheckedContinuation<Int, Error>?
        var timeoutCount = 0
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let _: Int = try await NativeScreenshotStartupDeadline.run(
                stage: "test display", nanoseconds: 40_000_000,
                onTimeout: { timeoutCount += 1 }
            ) {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                }
            }
            preconditionFailure("an unresponsive capture returned without timing out")
        } catch let error as NativeScreenshotStartupTimeout {
            precondition(error.stage == "test display", "timeout lost its stage")
        }
        precondition(ProcessInfo.processInfo.systemUptime - started < 0.5,
                     "startup did not return promptly at the deadline")
        precondition(timeoutCount == 1, "timeout callback ran more than once")
        precondition(pending != nil, "the simulated capture never started")
        pending?.resume(returning: 99)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(timeoutCount == 1, "a late frame restarted timeout handling")
    }

    @MainActor
    private static func cancellationReturnsPromptly() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task {
            try await NativeScreenshotStartupDeadline.run(
                stage: "cancelled display", nanoseconds: 2_000_000_000,
                onTimeout: { preconditionFailure("cancelled capture reached its deadline") }
            ) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("cancelled capture returned a frame")
        } catch is CancellationError {
            precondition(ProcessInfo.processInfo.systemUptime - started < 0.5,
                         "cancelled capture did not release its caller")
        }
    }
}
