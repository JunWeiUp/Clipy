import Combine
import SwiftUI

/// Per-device sync health (state, pending queue, last ACK, last error) shown
/// on the LAN devices settings page. Polls `SyncManager.diagnosticsRows()`
/// while visible; the data itself lives in memory only.
struct SyncDiagnosticsSection: View {
  @State private var rows: [SyncManager.DiagnosticsRow] = []
  private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  var body: some View {
    Section {
      Text(L10n.t(.syncDiagnosticsHint))
        .font(AppFont.caption)
        .foregroundStyle(.secondary)
      if rows.isEmpty {
        Text(L10n.t(.syncDiagnosticsEmpty))
          .font(AppFont.caption)
          .foregroundStyle(.secondary)
      }
      ForEach(rows) { row in
        SyncDiagnosticsRowView(row: row)
      }
      Button(L10n.t(.syncDiagnosticsReset)) {
        SyncManager.shared.diagnostics.reset()
        reload()
      }
    } header: {
      Text(L10n.t(.syncDiagnosticsTitle))
    }
    .onAppear(perform: reload)
    .onReceive(timer) { _ in reload() }
  }

  private func reload() {
    DispatchQueue.global(qos: .userInitiated).async {
      let fresh = SyncManager.shared.diagnosticsRows()
      DispatchQueue.main.async { rows = fresh }
    }
  }
}

private struct SyncDiagnosticsRowView: View {
  let row: SyncManager.DiagnosticsRow

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Circle()
          .fill(row.isOnline ? Color.green : Color.secondary.opacity(0.5))
          .frame(width: 7, height: 7)
        Text(row.displayName).font(AppFont.body)
        Text(L10n.t(row.isOnline ? .deviceOnline : .deviceOffline))
          .font(AppFont.caption)
          .foregroundStyle(.secondary)
        if !row.isAuthorized {
          Text(L10n.t(.syncDiagnosticsNotAuthorized))
            .font(AppFont.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(L10n.format(.syncDiagnosticsPending, row.pendingCount))
          .font(AppFont.caption)
          .foregroundStyle(row.pendingCount > 0 ? Color.orange : Color.secondary)
      }
      Text(detailLine)
        .font(AppFont.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      if let error = row.record.lastError {
        Text("\(L10n.t(.syncDiagnosticsLastError)): \(error) · \(time(row.record.lastErrorAt))")
          .font(AppFont.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
    .padding(.vertical, 2)
  }

  private var detailLine: String {
    let record = row.record
    var parts: [String] = []
    if let host = record.host { parts.append(host) }
    parts.append(String(record.peerId.prefix(8)))
    if row.isOnline {
      parts.append("\(L10n.t(.syncDiagnosticsSessionUp)) \(time(record.sessionUpAt))")
    } else if record.sessionDownAt != nil {
      parts.append("\(L10n.t(.syncDiagnosticsSessionDown)) \(time(record.sessionDownAt))")
    }
    parts.append("\(L10n.t(.syncDiagnosticsLastSent)) \(time(record.lastSentAt))")
    parts.append("\(L10n.t(.syncDiagnosticsLastAck)) \(time(record.lastAckAt))")
    parts.append("\(L10n.t(.syncDiagnosticsLastReceived)) \(time(record.lastReceivedAt))")
    return parts.joined(separator: " · ")
  }

  private func time(_ date: Date?) -> String {
    guard let date else { return L10n.t(.syncDiagnosticsNever) }
    return RelativeTimeFormatter.string(from: date)
  }
}
