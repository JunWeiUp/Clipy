import SwiftUI
import AppKit

final class LogViewModel: ObservableObject {
    @Published var searchText = ""

    func prepareForClose() {
        searchText = ""
    }
}

struct LogView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: LogViewModel
    @ObservedObject var logManager = LogManager.shared

    var filteredLogs: [LogManager.LogEntry] {
        if viewModel.searchText.isEmpty {
            return logManager.logs
        }
        return logManager.logs.filter { $0.message.localizedCaseInsensitiveContains(viewModel.searchText) }
    }

    private var statusText: String {
        L10n.format(.searchResultCount, filteredLogs.count)
    }

    var body: some View {
        let _ = languageObserver.revision

        AppListWindowLayout(statusText: statusText) {
            AppWindowHeader {
                HStack(spacing: AppSpacing.sm) {
                    TextField(L10n.t(.searchLogs), text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)

                    Button(action: copyLogs) {
                        Label(L10n.t(.copyAll), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button(action: { logManager.clear() }) {
                        Label(L10n.t(.clear), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        } content: {
            List(filteredLogs) { entry in
                HStack(alignment: .top, spacing: AppSpacing.xs) {
                    Text(entry.formattedTimestamp)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 85, alignment: .leading)

                    LevelBadge(text: entry.level.rawValue, color: colorForLevel(entry.level))

                    Text(entry.message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(minWidth: AppWindowSize.listMin.width, minHeight: AppWindowSize.listMin.height)
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
        let allLogs = filteredLogs
            .map { "[\($0.formattedTimestamp)] [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(allLogs, forType: .string)
    }
}

final class LogWindow {
    private static var shared: LogWindow?

    private let session = WindowSession<LogView>()
    private var viewModel: LogViewModel?

    static func show() {
        if shared == nil {
            shared = LogWindow()
        }
        shared?.showWindow()
    }

    private func showWindow() {
        session.present(
            create: { [self] in
                let viewModel = LogViewModel()
                self.viewModel = viewModel
                return HostingWindow(
                    title: L10n.t(.clipyLogs),
                    size: AppWindowSize.log,
                    minSize: AppWindowSize.listMin,
                    frameAutosaveName: "LogWindow"
                ) {
                    LogView(viewModel: viewModel)
                }
            },
            onPrepareForClose: { [weak self] in
                self?.viewModel?.prepareForClose()
            },
            onTeardown: { [weak self] in
                self?.viewModel = nil
                LogWindow.shared = nil
            },
            update: { window in
                window.title = L10n.t(.clipyLogs)
            }
        )
    }
}
