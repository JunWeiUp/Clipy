import Foundation

class LogManager: ObservableObject {
    static let shared = LogManager()
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let level: LogLevel
        
        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
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
    
    private init() {}
    
    func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        
        DispatchQueue.main.async {
            self.logs.insert(entry, at: 0)
            if self.logs.count > self.maxLogs {
                self.logs.removeLast()
            }
            // 同时打印到控制台
            print("[\(entry.formattedTimestamp)] [\(level.rawValue)] \(message)")
        }
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}

// 全局便捷方法
func appLog(_ message: String, level: LogManager.LogLevel = .info) {
    LogManager.shared.log(message, level: level)
}
