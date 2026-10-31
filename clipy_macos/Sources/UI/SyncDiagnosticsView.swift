import Combine
import SwiftUI

/// Diagnostics in the main window Devices module; records remain owned by SyncManager.
struct SyncDiagnosticsPage: View {
  @State private var rows: [SyncManager.DiagnosticsRow] = []
  private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 0) {
      SplitV3Toolbar {
        Text(L10n.t(.syncDiagnosticsTitle)).font(.system(size: 15, weight: .semibold))
        Spacer()
        Button {
          SyncManager.shared.diagnostics.reset()
          reload()
        } label: {
          Label(L10n.t(.syncDiagnosticsReset), systemImage: "arrow.counterclockwise")
        }.buttonStyle(SplitV3ButtonStyle())
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(L10n.t(.syncDiagnosticsHint))
            .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
            .fixedSize(horizontal: false, vertical: true)
          if rows.isEmpty {
            Text(L10n.t(.syncDiagnosticsEmpty))
              .font(.system(size: 13)).foregroundStyle(SplitV3Color.text2)
              .frame(maxWidth: .infinity).padding(.vertical, 40)
          }
          ForEach(rows) { row in card(row) }
        }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
      }
    }
    .background(SplitV3Color.inspector)
    .onAppear(perform: reload)
    .onReceive(timer) { _ in reload() }
  }

  private func card(_ row: SyncManager.DiagnosticsRow) -> some View {
    let record = row.record
    let cells: [(String, String, Bool)] = [
      (L10n.t(row.isOnline ? .syncDiagnosticsSessionUp : .syncDiagnosticsSessionDown),
       time(row.isOnline ? record.sessionUpAt : record.sessionDownAt), false),
      (L10n.t(.syncDiagnosticsLastSent), time(record.lastSentAt), false),
      (L10n.t(.syncDiagnosticsLastAck), time(record.lastAckAt), false),
      (L10n.t(.syncDiagnosticsLastReceived), time(record.lastReceivedAt), false),
      (L10n.format(.syncDiagnosticsPending, row.pendingCount), "\(row.pendingCount)", false),
      (L10n.t(.syncDiagnosticsLastError), record.lastError ?? "—", record.lastError != nil),
    ]
    return VStack(spacing: 0) {
      HStack(spacing: 8) {
        Circle().fill(row.isOnline ? Color(red: 0.19, green: 0.82, blue: 0.35) : SplitV3Color.text3)
          .frame(width: 7, height: 7)
        Text(row.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text(L10n.t(row.isOnline ? .deviceOnline : .deviceOffline))
          .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
        if !row.isAuthorized {
          Text(L10n.t(.syncDiagnosticsNotAuthorized))
            .font(.system(size: 11, weight: .medium)).foregroundStyle(SplitV3Color.text2)
            .padding(.horizontal, 7).frame(height: 20).background(SplitV3Color.fill, in: RoundedRectangle(cornerRadius: 6))
        }
        Spacer(minLength: 0)
        Text([record.host, String(record.peerId.prefix(8))].compactMap { $0 }.joined(separator: " · "))
          .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(SplitV3Color.text3)
          .lineLimit(1).textSelection(.enabled)
      }.padding(.horizontal, 14).frame(height: 40)
      SplitV3Hairline()
      ForEach(0..<2, id: \.self) { r in
        if r == 1 { SplitV3Hairline() }
        HStack(spacing: 0) {
          ForEach(0..<3, id: \.self) { c in
            if c > 0 { SplitV3Hairline(vertical: true) }
            let cell = cells[r * 3 + c]
            VStack(alignment: .leading, spacing: 2) {
              Text(r * 3 + c == 4 ? (PreferencesManager.shared.appLanguage == .zh ? "待发送" : "Pending") : cell.0)
                .font(.system(size: 11)).foregroundStyle(SplitV3Color.text3).lineLimit(1)
              Text(cell.1).font(.system(size: 13, weight: .medium)).monospacedDigit()
                .foregroundStyle(cell.2 ? Color(nsColor: .systemRed) : Color.primary)
                .lineLimit(1).help(cell.1).textSelection(.enabled)
            }.padding(.horizontal, 14).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
          }
        }.fixedSize(horizontal: false, vertical: true)
      }
    }.devicesCard()
  }

  private func reload() {
    #if CLIPY_CORE_TESTS
    if ProcessInfo.processInfo.environment["CLIPY_WINDOW_SNAPSHOT_DIR"] != nil { return }
    #endif
    DispatchQueue.global(qos: .userInitiated).async {
      let fresh = SyncManager.shared.diagnosticsRows()
      DispatchQueue.main.async { rows = fresh }
    }
  }

  private func time(_ date: Date?) -> String {
    guard let date else { return "—" }
    return RelativeTimeFormatter.string(from: date)
  }
}
