import Charts
import SwiftUI

/// Horizontal stacked bars, used for `工具与模型用量` and `项目分布`.
struct StackedBarsCard: View {
    let title: String
    let subtitle: String
    let help: String
    let rows: [StackedRow]
    let emptyMessage: String
    let visibleRows: Int

    @State private var showAll = false
    @State private var helpPresented = false

    private let rowHeight: CGFloat = 22
    private let labelWidth: CGFloat = 92

    var body: some View {
        CardSurface(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                CardHeader(title: title, subtitle: subtitle) {
                    Button {
                        helpPresented.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $helpPresented, arrowEdge: .bottom) {
                        Text(help)
                            .font(AppFont.text(11))
                            .foregroundStyle(Theme.foreground)
                            .frame(width: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                }

                if rows.isEmpty {
                    CardEmptyState(message: emptyMessage).frame(height: 120)
                } else {
                    VStack(spacing: 6) {
                        ForEach(showAll ? rows : Array(rows.prefix(visibleRows))) { row in
                            BarRow(row: row, labelWidth: labelWidth, height: rowHeight)
                        }
                    }

                    if rows.count > visibleRows {
                        Button(showAll ? "收起" : "查看全部（\(rows.count)）") {
                            withAnimation(.smooth(duration: 0.2)) { showAll.toggle() }
                        }
                        .font(AppFont.text(11))
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}

/// A single bar: label, proportional stacked segments, percentage and tokens.
private struct BarRow: View {
    let row: StackedRow
    let labelWidth: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(row.color)
                        .frame(width: 6, height: 6)
                    Text(row.label)
                        .font(AppFont.text(10))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: labelWidth, alignment: .leading)

                Spacer(minLength: 4)

                Text(Fmt.pct(row.pct))
                    .font(AppFont.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.foreground)
                Text(Fmt.tokens(row.total))
                    .font(AppFont.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .frame(width: 62, alignment: .trailing)
            }

            GeometryReader { geometry in
                let total = max(row.segments.reduce(0) { $0 + $1.value }, 1)
                HStack(spacing: 1) {
                    ForEach(row.segments) { segment in
                        let ratio = segment.value / total
                        if ratio > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(segment.color)
                                .frame(width: max(1, geometry.size.width * ratio))
                        }
                    }
                }
            }
            .frame(height: 6)
            .help(tooltip)

            Text(row.detail)
                .font(AppFont.text(9))
                .foregroundStyle(Theme.muted)
        }
    }

    private var tooltip: String {
        let total = max(row.segments.reduce(0) { $0 + $1.value }, 1)
        var lines = ["\(row.label) · \(Fmt.tokens(row.total)) Token · \(Fmt.usd(row.costUsd))"]
        for segment in row.segments.prefix(10) {
            let pct = segment.value / total * 100
            lines.append("  \(segment.label)  \(Fmt.tokens(segment.value)) · \(Fmt.pct(pct))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Donut plus legend list, used for `工具分布` and `模型分布`.
struct DistributionCard: View {
    let title: String
    let subtitle: String
    let slices: [DistributionSlice]
    @Binding var metric: UsageStore.MetricKind

    @State private var hidden: Set<String> = []
    @State private var showAll = false

    private let inlineLimit = 5

    var body: some View {
        CardSurface(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                CardHeader(title: title, subtitle: subtitle) {
                    SegmentedPicker(
                        options: [UsageStore.MetricKind.tokens, .cost],
                        selection: $metric,
                        label: { $0 == .tokens ? "Token" : "费用" }
                    )
                }

                if visibleSlices.isEmpty {
                    CardEmptyState().frame(height: 120)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        donut
                            .frame(width: 104, height: 104)
                        legend
                    }
                }
            }
        }
    }

    private var visibleSlices: [DistributionSlice] {
        slices.filter { !hidden.contains($0.id) }
    }

    private var donut: some View {
        Chart(visibleSlices) { slice in
            SectorMark(
                angle: .value("用量", value(of: slice)),
                innerRadius: .ratio(0.62),
                angularInset: 1
            )
            .cornerRadius(2)
            .foregroundStyle(slice.color)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 2) {
                Text(metric == .tokens ? "Tokens" : "费用")
                    .font(AppFont.text(8))
                    .foregroundStyle(Theme.muted)
                Text(metric == .tokens ? Fmt.tokens(totalValue) : Fmt.usd(totalValue))
                    .font(AppFont.mono(11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.foreground)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(showAll ? slices : Array(slices.prefix(inlineLimit))) { slice in
                LegendRow(
                    slice: slice,
                    metric: metric,
                    isHidden: hidden.contains(slice.id),
                    onToggle: { toggle(slice.id) }
                )
            }
            if slices.count > inlineLimit {
                Button(showAll ? "收起" : "查看全部（\(slices.count)）") {
                    withAnimation(.smooth(duration: 0.2)) { showAll.toggle() }
                }
                .font(AppFont.text(11))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
    }

    private func value(of slice: DistributionSlice) -> Double {
        metric == .tokens ? slice.tokens : slice.costUsd
    }

    private var totalValue: Double {
        visibleSlices.reduce(0) { $0 + value(of: $1) }
    }
}

private struct LegendRow: View {
    let slice: DistributionSlice
    let metric: UsageStore.MetricKind
    let isHidden: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(slice.color)
                    .frame(width: 8, height: 8)
                Text(slice.label)
                    .font(AppFont.text(10))
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(isHidden ? "—" : Fmt.pct(slice.pct))
                    .font(AppFont.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                Text(metric == .tokens ? Fmt.tokens(slice.tokens) : Fmt.usd(slice.costUsd))
                    .font(AppFont.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .opacity(isHidden ? 0.4 : 1)
            .strikethrough(isHidden, color: Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isHidden ? "显示 \(slice.label)" : "隐藏 \(slice.label)")
    }
}
