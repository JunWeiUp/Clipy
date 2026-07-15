import Foundation

class LogManager: ObservableObject {
    static let shared = LogManager()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
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

    private init() {}
    
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

    private func flushPending() {
        let entries = pendingEntries
        pendingEntries = []
        flushScheduled = false
        guard !entries.isEmpty else { return }

        DispatchQueue.main.async {
            // Newest first, mirroring the previous insert(at: 0) behaviour.
            self.logs.insert(contentsOf: entries.reversed(), at: 0)
            if self.logs.count > self.maxLogs {
                self.logs.removeLast(self.logs.count - self.maxLogs)
            }
        }
    }
    
    func clear() {
        bufferQueue.async {
            self.pendingEntries.removeAll()
        }
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}

// 全局便捷方法
func appLog(_ message: String, level: LogManager.LogLevel = .info) {
    LogManager.shared.log(message, level: level)
}
