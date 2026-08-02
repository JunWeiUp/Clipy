import Foundation

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
    private let maxLogs = 500

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

/// Records uncaught Objective-C exceptions to the log file before the process aborts.
/// AppKit drawing code throws these from CoreText/CoreFoundation and Swift cannot catch them,
/// so the file is the only trace left besides the system crash report.
enum CrashReporter {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n    ")
            LogManager.shared.logFatalSynchronously(
                "Uncaught \(exception.name.rawValue): \(exception.reason ?? "no reason")\n    \(stack)"
            )
        }
    }
}

// 全局便捷方法
func appLog(_ message: String, level: LogManager.LogLevel = .info) {
    LogManager.shared.log(message, level: level)
}
