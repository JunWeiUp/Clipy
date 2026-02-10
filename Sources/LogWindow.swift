import SwiftUI
import AppKit

struct LogView: View {
    @ObservedObject var logManager = LogManager.shared
    @State private var searchText = ""
    
    var filteredLogs: [LogManager.LogEntry] {
        if searchText.isEmpty {
            return logManager.logs
        } else {
            return logManager.logs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: .infinity)
                
                Button(action: { copyLogs() }) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                
                Button(action: { logManager.clear() }) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // 日志列表
            List(filteredLogs) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.formattedTimestamp)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 85, alignment: .leading)
                    
                    Text(entry.level.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(colorForLevel(entry.level))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                        .frame(width: 50)
                    
                    Text(entry.message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
    
    private func colorForLevel(_ level: LogManager.LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .error: return .red
        case .warning: return .orange
        case .debug: return .gray
        }
    }
    
    private func copyLogs() {
        let allLogs = filteredLogs.map { "[\($0.formattedTimestamp)] [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(allLogs, forType: .string)
    }
}

class LogWindow: NSWindow {
    static var shared: LogWindow?
    
    init() {
        let logView = LogView()
        let hostingController = NSHostingController(rootView: logView)
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        self.title = "Clipy Logs"
        self.contentViewController = hostingController
        self.center()
        self.setFrameAutosaveName("LogWindow")
        self.isReleasedWhenClosed = false
    }
    
    static func show() {
        if shared == nil {
            shared = LogWindow()
        }
        shared?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
