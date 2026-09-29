import AppKit
import SwiftUI

enum TokenUsageFormat {
    static func money(_ value: Double) -> String {
        if value > 0 && value < 0.0001 { return "$<0.0001" }
        return String(format: "$%.4f", value)
    }
    static func tokens(_ value: Int) -> String { value.formatted() }
    static func compactTokens(_ value: Int) -> String {
        let amount = Double(value)
        if PreferencesManager.shared.appLanguage == .zh {
            if value >= 100_000_000 { return String(format: "%.2f亿", amount / 100_000_000) }
            if value >= 10_000 { return String(format: "%.1f万", amount / 10_000) }
        } else {
            if value >= 1_000_000 { return String(format: "%.1fM", amount / 1_000_000) }
            if value >= 1_000 { return String(format: "%.1fK", amount / 1_000) }
        }
        return tokens(value)
    }
    static func compactMoney(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<$0.01" }
        return String(format: "≈$%.2f", value)
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

final class TokenUsageWindow {
    static let shared = TokenUsageWindow()
    private let session = WindowSession<TokenUsageView>()

    func showWindow() {
        session.present(create: {
            HostingWindow(title: L10n.t(.tokenUsageTitle), size: CGSize(width: 860, height: 700),
                          minSize: CGSize(width: 600, height: 480), frameAutosaveName: "TokenUsageWindow") {
                TokenUsageView(manager: .shared)
            }
        }, onPrepareForClose: {}, update: { window in
            window.title = L10n.t(.tokenUsageTitle)
            TokenUsageManager.shared.refreshIfStale()
        })
    }
}

struct TokenUsagePanelSummary: View {
    @ObservedObject var manager: TokenUsageManager
    @EnvironmentObject private var language: AppLanguageObserver
    var open: () -> Void

    var body: some View {
        let _ = language.revision
        let today = manager.report.days.first { $0.day == TokenUsageFormat.day(Date()) }
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 16)).foregroundStyle(AppColor.accent)
                    .frame(width: 24)
                Text(L10n.t(.tokenUsageToday)).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                if manager.isScanning { ProgressView().controlSize(.small) }
                if let today {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(L10n.t(.tokenUsageTokens)).foregroundStyle(.secondary)
                            Text(TokenUsageFormat.compactTokens(today.counts.total)).fontWeight(.semibold).monospacedDigit()
                        }
                        HStack(spacing: 5) {
                            Text(L10n.t(.tokenUsageEstimate)).foregroundStyle(.secondary)
                            Text(today.estimatedUSD == 0 && today.unpricedEvents > 0 ? "—" : TokenUsageFormat.compactMoney(today.estimatedUSD))
                                .fontWeight(.semibold).monospacedDigit()
                            if today.unpricedEvents > 0 {
                                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                                    .help(L10n.format(.tokenUsageUnpriced, today.unpricedEvents))
                            }
                        }
                    }.font(AppFont.caption)
                } else if !manager.isScanning {
                    Text(L10n.t(.tokenUsageNoData)).font(AppFont.secondary).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(AppFont.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 9).frame(height: 50).contentShape(Rectangle())
                .background(AppColor.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(L10n.t(.tokenUsageToday)), \(L10n.t(.tokenUsageTokens)) \(today.map { TokenUsageFormat.tokens($0.counts.total) } ?? "—"), \(L10n.t(.tokenUsageEstimate)) \(today.map { $0.estimatedUSD == 0 && $0.unpricedEvents > 0 ? "—" : TokenUsageFormat.money($0.estimatedUSD) } ?? "—")")
            .help(L10n.t(.tokenUsageHint) + "\n" + L10n.t(.tokenUsagePriceNote))
    }
}

struct TokenUsageView: View {
    @ObservedObject var manager: TokenUsageManager
    @EnvironmentObject private var language: AppLanguageObserver
    @State private var days = 30
    @State private var selectedAgent: TokenAgent?

    private var cutoff: String {
        let today = Calendar.current.startOfDay(for: Date())
        return TokenUsageFormat.day(Calendar.current.date(byAdding: .day, value: 1 - days, to: today) ?? today)
    }
    private var lines: [TokenUsageLine] {
        manager.report.lines.filter { $0.day >= cutoff && (selectedAgent == nil || $0.agent == selectedAgent) }
    }
    private var daily: [TokenUsageDay] {
        var grouped: [String: (TokenCounts, Double, Int)] = [:]
        for line in lines {
            var value = grouped[line.day] ?? (TokenCounts(), 0, 0)
            value.0 = value.0 + line.counts
            value.1 += line.estimatedUSD ?? 0
            value.2 += line.unpricedEvents
            grouped[line.day] = value
        }
        return grouped.map { TokenUsageDay(day: $0.key, counts: $0.value.0,
                                           estimatedUSD: $0.value.1, unpricedEvents: $0.value.2) }
            .sorted { $0.day > $1.day }
    }
    private var totalCounts: TokenCounts { lines.reduce(TokenCounts()) { $0 + $1.counts } }
    private var totalCost: Double { lines.reduce(0) { $0 + ($1.estimatedUSD ?? 0) } }
    private var unpriced: Int { lines.reduce(0) { $0 + $1.unpricedEvents } }

    var body: some View {
        let _ = language.revision
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    filters
                    summary
                    sourceStatuses
                    if daily.isEmpty {
                        EmptyStateView(message: L10n.t(.tokenUsageNoData), symbol: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity, minHeight: 170)
                    } else {
                        dailySection
                        modelSection
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.t(.tokenUsagePriceNote)).font(AppFont.caption).foregroundStyle(.secondary)
                        Text(L10n.format(.tokenUsagePriceSource,
                                         manager.priceSource == "Bundled" ? L10n.t(.tokenUsageBundledPrice) : manager.priceSource)
                             + (manager.priceUpdatedAt.map { " · " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""))
                            .font(AppFont.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").foregroundStyle(AppColor.accent)
            Text(L10n.t(.tokenUsageTitle)).font(AppFont.title)
            Spacer()
            if manager.isScanning { ProgressView().controlSize(.small); Text(L10n.t(.tokenUsageScanning)).font(AppFont.caption) }
            Button { manager.refresh() } label: { Label(L10n.t(.tokenUsageRefresh), systemImage: "arrow.clockwise") }
                .disabled(manager.isScanning)
            Button { manager.updatePrices() } label: { Label(L10n.t(.tokenUsageUpdatePrices), systemImage: "dollarsign.arrow.circlepath") }
                .disabled(manager.isUpdatingPrices)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var filters: some View {
        HStack {
            Picker("", selection: $days) {
                Text(L10n.t(.tokenUsageDay)).tag(1)
                Text(L10n.t(.tokenUsageWeek)).tag(7)
                Text(L10n.t(.tokenUsageMonth)).tag(30)
            }.pickerStyle(.segmented).frame(width: 285).labelsHidden()
            Spacer()
            Picker("", selection: $selectedAgent) {
                Text(L10n.t(.tokenUsageAllAgents)).tag(TokenAgent?.none)
                ForEach(TokenAgent.allCases) { agent in Text(agent.title).tag(Optional(agent)) }
            }.frame(width: 175).labelsHidden()
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            metric(L10n.t(.tokenUsageEstimate), totalCost == 0 && unpriced > 0 ? "—" : TokenUsageFormat.money(totalCost), symbol: "dollarsign.circle")
            metric(L10n.t(.tokenUsageTokens), TokenUsageFormat.tokens(totalCounts.total), symbol: "number")
            metric(L10n.format(.tokenUsageUnpriced, unpriced), "\(unpriced)", symbol: "questionmark.circle")
        }
    }
    private func metric(_ label: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(label, systemImage: symbol).font(AppFont.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sourceStatuses: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(TokenAgent.allCases) { agent in
                    let status = manager.statuses[agent]
                    HStack(spacing: 4) {
                        Image(systemName: status?.state == .ready ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(status?.state == .ready ? AppColor.accent : Color.secondary)
                        Text(agent.title)
                        if let status, status.state != .ready { Text("· " + statusText(status.state)).foregroundStyle(.secondary) }
                    }.font(AppFont.caption).lineLimit(1).help(status?.detail ?? "")
                }
            }
            if let error = manager.errorMessage { Text(error).font(AppFont.caption).foregroundStyle(.red) }
        }
    }
    private func statusText(_ state: TokenSourceState) -> String {
        switch state {
        case .ready: return L10n.t(.tokenUsageStatusReady)
        case .missing: return L10n.t(.tokenUsageStatusMissing)
        case .unreadable: return L10n.t(.tokenUsageStatusUnreadable)
        case .unsupported: return L10n.t(.tokenUsageStatusUnsupported)
        case .failed: return L10n.t(.tokenUsageStatusFailed)
        }
    }

    private var dailySection: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(.tokenUsageDaily)).font(.system(size: 16, weight: .semibold))
            let maximum = max(daily.map(\.estimatedUSD).max() ?? 0, 0.0001)
            ForEach(daily) { day in
                HStack(spacing: 12) {
                    Text(day.day).font(AppFont.body).frame(width: 100, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule().fill(AppColor.accent.opacity(0.55))
                            .frame(width: day.estimatedUSD > 0
                                ? max(2, geometry.size.width * day.estimatedUSD / maximum) : 0, height: 8)
                            .frame(maxHeight: .infinity)
                    }.frame(height: 18)
                    Text(TokenUsageFormat.tokens(day.counts.total)).font(AppFont.caption).foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                    Text(day.estimatedUSD == 0 && day.unpricedEvents > 0 ? "—" : TokenUsageFormat.money(day.estimatedUSD))
                        .monospacedDigit().frame(width: 90, alignment: .trailing)
                    if day.unpricedEvents > 0 { Image(systemName: "questionmark.circle").help(L10n.format(.tokenUsageUnpriced, day.unpricedEvents)) }
                }.padding(.vertical, 5)
                Divider()
            }
        }
    }

    private var modelSection: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(.tokenUsageModels)).font(.system(size: 16, weight: .semibold))
            ForEach(lines) { line in
                HStack(spacing: 10) {
                    Text(line.day).foregroundStyle(.secondary).frame(width: 94, alignment: .leading)
                    Text(line.agent.title).frame(width: 100, alignment: .leading)
                    Text(line.model).lineLimit(1).help(line.model)
                    Spacer()
                    Text(TokenUsageFormat.tokens(line.counts.total)).foregroundStyle(.secondary)
                    Text(line.estimatedUSD.map(TokenUsageFormat.money) ?? "—")
                        .monospacedDigit().frame(width: 90, alignment: .trailing)
                    if line.unpricedEvents > 0 { Image(systemName: "questionmark.circle").help(L10n.format(.tokenUsageUnpriced, line.unpricedEvents)) }
                }.font(AppFont.secondary).padding(.vertical, 5)
                Divider()
            }
        }
    }
}
