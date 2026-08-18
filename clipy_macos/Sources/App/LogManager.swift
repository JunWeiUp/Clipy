import Foundation
import Darwin

class LogManager: ObservableObject {
    static let shared = LogManager()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let level: LogLevel

        var formattedTimestamp: String {
            LogManager.timestampFormatter.string(from: timestamp)
        }
    }

    enum LogLevel: String {
        case info = "INFO"
        case error = "ERROR"
        case warning = "WARN"
        case debug = "DEBUG"
    }

    @Published var logs: [LogEntry] = []
    // In-memory ring for the Log window only; the full history lives in the
    // daily files under ~/Library/Logs/ClipyClone/.
    private let maxLogs = 200

    /// Batch buffer: log lines land here first so hot paths (sync/file transfer)
    /// don't hit the main thread once per line.
    private let bufferQueue = DispatchQueue(label: "com.clipy.log-buffer")
    private var pendingEntries: [LogEntry] = []
    private var flushScheduled = false

    /// Kept open across the session so appending never re-opens the file per line.
    private var fileHandle: FileHandle?
    private var fileHandleDay: String?

    static let retentionDays = 7

    /// `~/Library/Logs/ClipyClone` — survives relaunches, readable in Console.app.
    static var logDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/ClipyClone", isDirectory: true)
    }

    static var currentLogFile: URL {
        logDirectory.appendingPathComponent("ClipyClone-\(dayFormatter.string(from: Date())).log")
    }

    private init() {}

    /// Writes the session banner and drops expired files. Call once at launch.
    func startSession() {
        bufferQueue.async {
            self.pruneExpiredFiles()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            self.writeToFile(
                "\n===== session start · v\(version) (\(build)) · pid \(ProcessInfo.processInfo.processIdentifier) "
                + "· macOS \(ProcessInfo.processInfo.operatingSystemVersionString) =====\n"
            )
        }
    }

    func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)

        #if DEBUG
        print("[\(entry.formattedTimestamp)] [\(level.rawValue)] \(message)")
        #endif

        bufferQueue.async {
            self.pendingEntries.append(entry)
            if !self.flushScheduled {
                self.flushScheduled = true
                self.bufferQueue.asyncAfter(deadline: .now() + 0.5) {
                    self.flushPending()
                }
            }
        }
    }

    /// Synchronous, buffer-bypassing write for the moments before the process dies.
    func logFatalSynchronously(_ message: String) {
        let line = "[\(Self.fileTimestampFormatter.string(from: Date()))] [FATAL] \(message)\n"
        let pending = bufferQueue.sync { () -> [LogEntry] in
            let entries = pendingEntries
            pendingEntries = []
            return entries
        }
        writeToFile(pending.map(Self.fileLine).joined())
        writeToFile(line)
        try? fileHandle?.synchronize()
    }

    private func flushPending() {
        let entries = pendingEntries
        pendingEntries = []
        flushScheduled = false
        guard !entries.isEmpty else { return }

        writeToFile(entries.map(Self.fileLine).joined())

        DispatchQueue.main.async {
            // Newest first, mirroring the previous insert(at: 0) behaviour.
            self.logs.insert(contentsOf: entries.reversed(), at: 0)
            if self.logs.count > self.maxLogs {
                self.logs.removeLast(self.logs.count - self.maxLogs)
            }
        }
    }

    private static func fileLine(_ entry: LogEntry) -> String {
        "[\(fileTimestampFormatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)\n"
    }

    // MARK: - File output

    private func writeToFile(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        guard let handle = currentHandle() else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fileHandle = nil
            fileHandleDay = nil
        }
    }

    private func currentHandle() -> FileHandle? {
        let day = Self.dayFormatter.string(from: Date())
        if let handle = fileHandle, fileHandleDay == day {
            return handle
        }

        try? fileHandle?.close()
        fileHandle = nil

        let directory = Self.logDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ClipyClone-\(day).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandleDay = fileHandle == nil ? nil : day
        return fileHandle
    }

    private func pruneExpiredFiles() {
        let directory = Self.logDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        for file in files where file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Clears the in-memory view only — files on disk are the crash record and stay put.
    func clear() {
        bufferQueue.async {
            self.pendingEntries.removeAll()
        }
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}

/// Captures both uncaught Objective-C exceptions and fatal POSIX signals so a
/// trace always lands in the log file before the process dies.
///
/// Why two mechanisms: `NSSetUncaughtExceptionHandler` only catches ObjC
/// `NSException` — it never fires for a signal-driven crash (SIGABRT from a
/// TCC privacy violation, SIGSEGV/SIGBUS from native code, etc.), which is why
/// earlier "the app just crashed" incidents left no trace in this file. The
/// signal handler below closes that gap using only async-signal-safe POSIX
/// calls, then re-raises the signal so macOS `ReportCrash` still emits a
/// system `.ips` report (full machine stack) plus the "unexpectedly quit" dialog.
enum CrashReporter {
    /// Today's log path, captured at `install()` time (main context — safe) and
    /// leaked on purpose: the process is about to die, and the signal handler
    /// must not call `FileManager`/`DateFormatter` to recompute it.
    private static var crashLogPath: UnsafeMutablePointer<CChar>?

    /// Preallocated backtrace buffer so the signal handler never `malloc`s
    /// (malloc is not async-signal-safe). One crash is terminal, so a single
    /// shared buffer is fine — there is no re-entrancy to worry about.
    private static var backtraceBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

    static func install() {
        // --- Capture everything that is NOT async-signal-safe while still on the
        // main queue: the log path, and force symbol binding for backtrace()/
        // backtrace_symbols_fd (their *first* call would otherwise hit lazy
        // binding, which is unsafe inside a signal handler). ---
        let path = LogManager.currentLogFile.path
        crashLogPath = strdup(path)

        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
        frames.initialize(repeating: nil, count: 64)
        backtraceBuffer = frames
        let devNull = open("/dev/null", O_WRONLY)
        if devNull >= 0 {
            let n = backtrace(frames, 64)
            backtrace_symbols_fd(frames, n, devNull)
            close(devNull)
        }

        // ObjC NSException handler — unchanged. Swift cannot catch these, the
        // file is the only trace besides the system crash report.
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n    ")
            LogManager.shared.logFatalSynchronously(
                "Uncaught \(exception.name.rawValue): \(exception.reason ?? "no reason")\n    \(stack)"
            )
        }

        // POSIX signal handler. `@convention(c)` so it can be stored as a raw
        // `sighandler_t`. The body only calls async-signal-safe code.
        let handler: @convention(c) (Int32) -> Void = { sig in
            CrashReporter.writeSignalTrace(sig)
            // Restore the default disposition and re-raise so ReportCrash still
            // produces the system .ips report + "unexpectedly quit" dialog.
            signal(sig, SIG_DFL)
            raise(sig)
            // Should not return; guarantee termination if it somehow does.
            _exit(128 + sig)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL] {
            signal(sig, handler)
        }
        // A sync peer closing its socket mid-write must not abort us.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Async-signal-safe crash trace writer.
    ///
    /// Only uses POSIX primitives documented safe inside a signal handler:
    /// `open`/`write`/`fsync`/`close`, `backtrace`/`backtrace_symbols_fd`,
    /// `time`/`ctime_r`, plus trivial byte/integer arithmetic. No `snprintf`
    /// (variadic — unavailable in Swift), no `Foundation` formatting. It
    /// deliberately does NOT touch `logFatalSynchronously` (uses
    /// `bufferQueue.sync`, `DateFormatter`, `FileHandle.synchronize`) — those
    /// would deadlock or crash a second time from this context.
    private static func writeSignalTrace(_ sig: Int32) {
        guard let pathPtr = crashLogPath, let frames = backtraceBuffer else { return }
        let fd = open(pathPtr, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644))
        guard fd >= 0 else { return }
        defer { close(fd) }

        var now: time_t = 0
        time(&now)
        var timebuf = [CChar](repeating: 0, count: 32)
        ctime_r(&now, &timebuf)

        // Header: "[<time>] [FATAL] signal <n> captured ...\nCall stack:\n"
        // Assembled by hand to stay async-signal-safe (no printf/string interp).
        writeStr(fd, "[")
        writeCStr(fd, timebuf)
        writeStr(fd, "] [FATAL] signal ")
        writeInt32(fd, sig)
        writeStr(fd, " captured — see ~/Library/Logs/DiagnosticReports for the full system .ips\nCall stack:\n")

        let count = backtrace(frames, 64)
        backtrace_symbols_fd(frames, count, fd)

        writeStr(fd, "\n==============================\n")

        fsync(fd)
    }

    /// Writes a Swift string literal as UTF-8 — string literals are static
    /// storage, safe to reference from a signal handler.
    @inline(__always)
    private static func writeStr(_ fd: Int32, _ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }

    /// Writes a NUL-terminated C string buffer (e.g. ctime_r output).
    @inline(__always)
    private static func writeCStr(_ fd: Int32, _ buf: [CChar]) {
        buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            var len = 0
            while len < ptr.count && base[len] != 0 { len += 1 }
            _ = write(fd, base, len)
        }
    }

    /// Writes a non-negative Int32 in decimal — pure arithmetic, no allocation.
    @inline(__always)
    private static func writeInt32(_ fd: Int32, _ value: Int32) {
        var v = value < 0 ? -value : value
        var digits: [UInt8] = []
        if v == 0 {
            digits.append(48) // '0'
        } else {
            while v > 0 {
                digits.append(UInt8(v % 10) + 48)
                v /= 10
            }
        }
        if value < 0 { digits.append(45) } // '-'
        // digits are little-endian (least significant first); reverse on write.
        var i = digits.count - 1
        var out: [UInt8] = []
        out.reserveCapacity(digits.count)
        while i >= 0 { out.append(digits[i]); i -= 1 }
        out.withUnsafeBufferPointer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }
}

// 全局便捷方法
func appLog(_ message: String, level: LogManager.LogLevel = .info) {
    LogManager.shared.log(message, level: level)
}
