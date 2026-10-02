import SwiftUI

struct TokenUsageHeatmapView: View {
    let heatmap: TokenUsageHeatmap
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredDay: String?
    @State private var selectedDay: String?

    private let gap: CGFloat = 3
    private let weekdayWidth: CGFloat = 30
    private var locale: Locale {
        Locale(identifier: PreferencesManager.shared.appLanguage == .zh ? "zh_CN" : "en_US")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t(.tokenUsageActivity)).font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(L10n.t(.tokenUsageYear)).font(AppFont.secondary).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let side = min(14, max(10, floor((geometry.size.width - weekdayWidth - gap * CGFloat(heatmap.weeks.count))
                                                / CGFloat(heatmap.weeks.count))))
                HStack(alignment: .top, spacing: gap) {
                    weekdayLabels(side: side)
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal) {
                            chart(side: side).padding(.bottom, 8)
                        }
                        .onAppear { scroll.scrollTo(heatmap.weeks.count - 1, anchor: .trailing) }
                        .onChange(of: geometry.size.width) { _ in
                            scroll.scrollTo(heatmap.weeks.count - 1, anchor: .trailing)
                        }
                    }
                }
            }.frame(height: 148)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    dayDetails
                    Spacer(minLength: 8)
                    legend
                }
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    dayDetails
                    legend
                }
            }
        }
        .padding(AppSpacing.md)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: AppCornerRadius.large))
        .overlay(RoundedRectangle(cornerRadius: AppCornerRadius.large).strokeBorder(Color.primary.opacity(0.10)))
    }

    private func weekdayLabels(side: CGFloat) -> some View {
        VStack(spacing: gap) {
            Color.clear.frame(height: 20)
            ForEach(0..<7, id: \.self) { row in
                Text([1, 3, 5].contains(row) ? weekday(row) : "")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: weekdayWidth, height: side, alignment: .leading)
            }
        }.frame(width: weekdayWidth).accessibilityHidden(true)
    }

    private func chart(side: CGFloat) -> some View {
        let pitch = side + gap
        return VStack(alignment: .leading, spacing: gap) {
            monthLabels(pitch: pitch)
                .frame(width: CGFloat(heatmap.weeks.count) * pitch - gap, height: 20, alignment: .leading)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: gap) {
                ForEach(heatmap.weeks.indices, id: \.self) { column in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            if let day = heatmap.weeks[column][row] {
                                dayCell(day, side: side)
                            } else {
                                Color.clear.frame(width: side, height: side).accessibilityHidden(true)
                            }
                        }
                    }.id(column)
                }
            }
        }
    }

    private func dayCell(_ day: TokenUsageHeatmap.Day, side: CGFloat) -> some View {
        Button {
            selectedDay = selectedDay == day.id ? nil : day.id
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(heatmap.intensity(for: day)))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.primary.opacity(selectedDay == day.id || hoveredDay == day.id ? 0.8 : 0.06), lineWidth: 1))
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredDay = day.id }
            else if hoveredDay == day.id { hoveredDay = nil }
        }
        .help(details(day))
        .accessibilityLabel(details(day))
        .accessibilityAddTraits(selectedDay == day.id ? [.isSelected] : [])
    }

    private var dayDetails: some View {
        let day = heatmap.days.first { $0.id == (hoveredDay ?? selectedDay) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(day.map { "\($0.id) · \(TokenUsageFormat.tokens($0.usage.counts.total)) \(L10n.t(.tokenUsageTokens))" }
                 ?? L10n.format(.tokenUsageActiveDays, heatmap.activeDays, TokenUsageFormat.compactTokens(heatmap.totalTokens)))
                .font(AppFont.secondary).monospacedDigit()
            Text(day.map(costDetails) ?? L10n.t(.tokenUsageHeatmapHint))
                .font(AppFont.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text(L10n.t(.tokenUsageLess))
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(color(level)).frame(width: 10, height: 10)
            }
            Text(L10n.t(.tokenUsageMore))
        }.font(AppFont.caption).foregroundStyle(.secondary).fixedSize()
            .help(L10n.t(.tokenUsageHeatmapScale))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t(.tokenUsageHeatmapScale))
    }

    private func details(_ day: TokenUsageHeatmap.Day) -> String {
        "\(day.id) · \(TokenUsageFormat.tokens(day.usage.counts.total)) \(L10n.t(.tokenUsageTokens))\n\(costDetails(day))"
    }

    private func costDetails(_ day: TokenUsageHeatmap.Day) -> String {
        let usage = day.usage
        let money = usage.estimatedUSD == 0 && usage.unpricedEvents > 0 ? "—" : TokenUsageFormat.money(usage.estimatedUSD)
        return L10n.t(.tokenUsageEstimate) + " " + money
            + (usage.unpricedEvents > 0 ? " · " + L10n.format(.tokenUsageUnpriced, usage.unpricedEvents) : "")
    }

    private func weekday(_ row: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        return formatter.shortWeekdaySymbols[row]
    }

    private func monthLabels(pitch: CGFloat) -> some View {
        let formatter = DateFormatter()
        formatter.calendar = heatmap.calendar
        formatter.timeZone = heatmap.calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "MMM"
        let width = CGFloat(heatmap.weeks.count) * pitch - gap
        var labels: [(id: Int, text: String, x: CGFloat)] = []
        for month in heatmap.months {
            let x = min(CGFloat(month.column) * pitch, width - 32)
            // Avoid overlaps for partial first/last months; keep the later month.
            if let last = labels.last, x - last.x < 34 { labels.removeLast() }
            labels.append((month.id, formatter.string(from: month.date), x))
        }
        return ZStack(alignment: .leading) {
            ForEach(labels, id: \.id) { label in
                Text(label.text).font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize().offset(x: label.x)
            }
        }
    }

    private func color(_ level: Int) -> Color {
        if level == 0 { return Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.055) }
        let light: [UInt32] = [0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
        let dark: [UInt32] = [0x0E4429, 0x006D32, 0x26A641, 0x39D353]
        let rgb = (colorScheme == .dark ? dark : light)[level - 1]
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
