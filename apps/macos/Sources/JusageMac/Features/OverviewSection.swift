import SwiftUI

/// `用量概览` — four metric cards followed by the 52-week activity heatmap.
struct OverviewSection: View {
    let metric: UsageStore.MetricKind

    @Environment(UsageStore.self) private var store

    // The panel is narrow, so the four metrics sit in a 2×2 grid.
    private let columns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
            // One container lets adjacent glass cards blend as a group.
            GlassEffectContainer(spacing: 7) {
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(cards) { card in
                        MetricCard(card: card)
                    }
                }
            }
            ActivityHeatmapCard()
        }
    }

    private var cards: [MetricCardModel] {
        let totals = store.overview
        let changes = store.changes
        let sparkline = store.sparklinePoints
        let inputDelta = deltaTokens(sparkline.map(\.inputTokens))
        let outputDelta = deltaTokens(sparkline.map(\.outputTokens))

        return [
            MetricCardModel(
                id: "cost",
                label: "预估费用",
                value: Fmt.usd(totals.costUsd),
                exact: Fmt.usd(totals.costUsd),
                caption: nil,
                trendText: changes.totalCostUsd == 0 ? nil : Fmt.percentChange(changes.totalCostUsd),
                trendPositive: changes.totalCostUsd >= 0,
                sparkline: sparkline.map(\.costUsd),
                help: MetricHelp(
                    title: "预估费用",
                    detail: "按本地定价表与已采集用量估算，不是账单金额。"
                )
            ),
            MetricCardModel(
                id: "total-tokens",
                label: "总 Token",
                value: Fmt.tokens(Double(totals.tokens)),
                exact: Fmt.tokensExact(Double(totals.tokens)),
                caption: store.requestCaption,
                trendText: changes.totalTokens == 0 ? nil : Fmt.percentChange(changes.totalTokens),
                trendPositive: changes.totalTokens >= 0,
                sparkline: sparkline.map { Double($0.tokens) },
                help: MetricHelp(
                    title: "总 Token 构成",
                    rows: tokenCompositionRows(totals),
                    footnote: """
                    总 Token = 输入 + 输出 + 缓存读 + 缓存写 + 其它
                    请求数优先用本地请求证据；无证据时按 conversation 累计；不完整时可能偏低。
                    """
                )
            ),
            MetricCardModel(
                id: "input-tokens",
                label: "输入 Token",
                value: Fmt.tokens(totals.inputTokens),
                exact: Fmt.tokensExact(totals.inputTokens),
                caption: totals.cacheHitRate.map { "缓存命中率 \(Fmt.rate($0))" },
                trendText: Fmt.deltaTokens(inputDelta),
                trendPositive: inputDelta >= 0,
                sparkline: sparkline.map { Double($0.inputTokens) },
                help: MetricHelp(
                    title: "输入 Token",
                    detail: """
                    不含缓存读取与缓存写入。
                    缓存命中率 = 缓存读 ÷（输入 + 缓存读 + 缓存写）。
                    """
                )
            ),
            MetricCardModel(
                id: "output-tokens",
                label: "输出 Token",
                value: Fmt.tokens(totals.outputTokens),
                exact: Fmt.tokensExact(totals.outputTokens),
                caption: nil,
                trendText: Fmt.deltaTokens(outputDelta),
                trendPositive: outputDelta >= 0,
                sparkline: sparkline.map { Double($0.outputTokens) },
                help: MetricHelp(
                    title: "输出 Token",
                    detail: "部分工具（如 Codex）的推理 Token 已计入输出。"
                )
            ),
        ]
    }

    private func deltaTokens(_ values: [Int64]) -> Double {
        guard values.count >= 2 else { return 0 }
        return Double(values[values.count - 1] - values[values.count - 2])
    }

    private func tokenCompositionRows(_ totals: OverviewTotals) -> [MetricHelpRow] {
        let other = max(0, totals.tokens - totals.inputTokens - totals.outputTokens
            - totals.cachedInputTokens - totals.cacheCreationInputTokens)
        return [
            MetricHelpRow(id: "input", label: "输入", value: Fmt.tokens(totals.inputTokens)),
            MetricHelpRow(id: "output", label: "输出", value: Fmt.tokens(totals.outputTokens)),
            MetricHelpRow(id: "cache-read", label: "缓存 · 读", value: Fmt.tokens(totals.cachedInputTokens)),
            MetricHelpRow(id: "cache-write", label: "缓存 · 写", value: Fmt.tokens(totals.cacheCreationInputTokens)),
            MetricHelpRow(id: "other", label: "其它", value: Fmt.tokens(other)),
            MetricHelpRow(id: "total", label: "合计", value: Fmt.tokens(totals.tokens)),
        ]
    }
}

// MARK: - Metric card model

struct MetricHelpRow: Identifiable {
    let id: String
    let label: String
    let value: String
}

struct MetricHelp {
    let title: String
    var rows: [MetricHelpRow] = []
    var detail: String? = nil
    var footnote: String? = nil
}

struct MetricCardModel: Identifiable {
    let id: String
    let label: String
    let value: String
    let exact: String
    let caption: String?
    let trendText: String?
    let trendPositive: Bool
    let sparkline: [Double]
    let help: MetricHelp
}

private struct MetricCard: View {
    let card: MetricCardModel

    var body: some View {
        CardSurface(padding: 9, cornerRadius: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // Label + help on the left, trend on the right. The trend is
                // `fixedSize` so it can never be compressed into the label (it
                // used to render as overlapping glyphs), and the sparkline lives
                // on the caption row instead of competing for this one.
                HStack(spacing: 3) {
                    Text(card.label)
                        .font(AppFont.text(10, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    HelpButton(help: card.help)
                    Spacer(minLength: 2)
                    if let trendText = card.trendText {
                        Text(trendText)
                            .font(AppFont.mono(9))
                            .monospacedDigit()
                            .foregroundStyle(card.trendPositive ? Theme.positive : Theme.negative)
                            .fixedSize()
                    }
                }

                Text(card.value)
                    .font(AppFont.mono(18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .help("精确值：\(card.exact)")

                HStack(spacing: 4) {
                    Text(card.caption ?? " ")
                        .font(AppFont.text(9))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Sparkline(values: card.sparkline)
                        .frame(width: 46, height: 12)
                        .foregroundStyle(card.trendPositive ? Theme.positive : Theme.negative)
                }
            }
        }
    }
}

private struct HelpButton: View {
    let help: MetricHelp
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(help.title)
                    .font(AppFont.text(12, weight: .semibold))
                ForEach(help.rows) { row in
                    HStack {
                        Text(row.label).foregroundStyle(Theme.muted)
                        Spacer(minLength: 16)
                        Text(row.value).monospacedDigit()
                    }
                    .font(AppFont.text(11))
                }
                if let detail = help.detail {
                    Text(detail)
                        .font(AppFont.text(11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let footnote = help.footnote {
                    Divider()
                    Text(footnote)
                        .font(AppFont.text(10))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        }
    }
}

/// 64×22 trend line; hidden when there are fewer than two points.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            if values.count >= 2 {
                let points = normalized(in: geometry.size)
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        let maxValue = values.max() ?? 0
        let minValue = values.min() ?? 0
        let span = max(maxValue - minValue, 1)
        let step = size.width / CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { index, value in
            let ratio = (value - minValue) / span
            return CGPoint(
                x: CGFloat(index) * step,
                y: size.height - CGFloat(ratio) * size.height
            )
        }
    }
}

// MARK: - Activity heatmap

/// One day in the heatmap grid.
struct HeatBin: Identifiable {
    let id: String
    let date: String
    let tokens: Int64
    let level: Int
    let models: [String: Int64]
}

/// Daily activity grid, `日一二三四五六` rows × N week columns.
///
/// Deliberately **not** inside a horizontal `ScrollView`: a scroll view reports
/// its content's width as its ideal width, which inflated the whole panel
/// column to ~900 pt and made the 452 pt frame clip the content down the middle.
/// Instead the week count adapts to the width the panel actually offers, and the
/// grid never renders wider than that. Month labels are positioned with
/// `.offset` inside a `ZStack` so they cannot influence the layout size either.
private struct ActivityHeatmapCard: View {
    @Environment(UsageStore.self) private var store

    private let maxWeeks = 52
    private let cellSize: CGFloat = 9
    private let cellGap: CGFloat = 2
    /// Weekday-letter column plus the gap after it.
    private let gutter: CGFloat = 12
    private let gutterGap: CGFloat = 5
    private let monthStrip: CGFloat = 10
    private static let dayLabels = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        CardSurface(padding: 11) {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(
                    title: "活动热力图",
                    subtitle: "每日 Token 用量，点击某天可筛选整个看板"
                )
                // GeometryReader takes the width it is offered and never
                // propagates an intrinsic width, which is what keeps the panel
                // from being widened; its height must therefore be explicit.
                GeometryReader { geometry in
                    let weeks = weekCount(for: geometry.size.width)
                    grid(weeks: weeks)
                }
                .frame(height: monthStrip + 7 * cellSize + 6 * cellGap)
                legend
            }
        }
    }

    // MARK: Sizing

    /// How many whole weeks of `cellSize` cells fit in the offered width.
    private func weekCount(for width: CGFloat) -> Int {
        let available = width - gutter - gutterGap
        guard available > 0 else { return 8 }
        let fits = Int(floor((available + cellGap) / (cellSize + cellGap)))
        return min(maxWeeks, max(8, fits))
    }

    // MARK: Grid

    private func grid(weeks: Int) -> some View {
        let matrix = buildMatrix(weeks: weeks)
        return ZStack(alignment: .topLeading) {
            monthLabels(weeks: weeks)
                .offset(y: 0)

            HStack(alignment: .top, spacing: gutterGap) {
                VStack(alignment: .trailing, spacing: cellGap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(Self.dayLabels[row])
                            .font(AppFont.text(7))
                            .foregroundStyle(Theme.muted)
                            .frame(height: cellSize)
                    }
                }
                .frame(width: gutter, alignment: .trailing)

                VStack(alignment: .leading, spacing: cellGap) {
                    ForEach(0..<7, id: \.self) { row in
                        HStack(spacing: cellGap) {
                            ForEach(0..<weeks, id: \.self) { column in
                                if let bin = matrix[row][column] {
                                    HeatmapCell(bin: bin, size: cellSize)
                                } else {
                                    Color.clear.frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }
                }
            }
            .offset(y: monthStrip)
        }
    }

    /// `M月` above the first column of each month. Positioned by offset with
    /// `fixedSize` so a label wider than its column overflows instead of
    /// wrapping or stretching the layout.
    ///
    /// The month is derived from each column's own start date rather than from
    /// whichever days happen to have data, so an empty stretch cannot shift or
    /// duplicate a boundary label.
    private func monthLabels(weeks: Int) -> some View {
        let tz = store.statsTimezone
        let end = store.today
        let rawStart = StatsClock.addDays(-(weeks * 7 - 1), to: end, tz)
        let gridStart = StatsClock.addDays(
            -StatsClock.sundayFirstWeekday(rawStart, tz),
            to: rawStart,
            tz
        )

        var labels: [(column: Int, text: String)] = []
        var lastMonth: Int? = nil
        for column in 0..<weeks {
            let date = StatsClock.addDays(column * 7, to: gridStart, tz)
            let month = StatsClock.month(date)
            if month != lastMonth {
                labels.append((column, "\(month)月"))
                lastMonth = month
            }
        }

        return ZStack(alignment: .topLeading) {
            ForEach(labels, id: \.column) { label in
                Text(label.text)
                    .font(AppFont.text(7))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                    .offset(x: gutter + gutterGap + CGFloat(label.column) * (cellSize + cellGap))
            }
        }
        .frame(height: monthStrip, alignment: .topLeading)
    }

    /// Row-major (weekday × week) grid, Sunday-first.
    private func buildMatrix(weeks: Int) -> [[HeatBin?]] {
        var matrix = [[HeatBin?]](
            repeating: [HeatBin?](repeating: nil, count: weeks),
            count: 7
        )
        let days = store.heatmapDaysFiltered
        guard !days.isEmpty else { return matrix }

        let tz = store.statsTimezone
        let end = store.today
        let rawStart = StatsClock.addDays(-(weeks * 7 - 1), to: end, tz)
        // Back up to the Sunday that opens the first column.
        let gridStart = StatsClock.addDays(
            -StatsClock.sundayFirstWeekday(rawStart, tz),
            to: rawStart,
            tz
        )

        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let thresholds = quantileThresholds(days.map { Double($0.tokens) })

        // `gridStart` is a Sunday, so index = column * 7 + weekday.
        for index in 0..<(weeks * 7) {
            let date = StatsClock.addDays(index, to: gridStart, tz)
            guard let day = byDate[date] else { continue }
            let column = index / 7
            let row = index % 7
            guard column < weeks else { continue }
            matrix[row][column] = HeatBin(
                id: date,
                date: date,
                tokens: day.tokens,
                level: intensity(Double(day.tokens), thresholds: thresholds),
                models: day.models
            )
        }
        return matrix
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("少").font(AppFont.text(8)).foregroundStyle(Theme.muted)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.heatmapLevel(level))
                    .frame(width: 9, height: 9)
            }
            Text("多").font(AppFont.text(8)).foregroundStyle(Theme.muted)
        }
    }

    /// Quantile thresholds at the 50 / 75 / 90 percentile over non-zero days.
    private func quantileThresholds(_ values: [Double]) -> (Double, Double, Double) {
        let nonZero = values.filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return (0, 0, 0) }
        func quantile(_ q: Double) -> Double {
            let index = Int((Double(nonZero.count - 1) * q).rounded())
            return nonZero[min(max(index, 0), nonZero.count - 1)]
        }
        return (quantile(0.5), quantile(0.75), quantile(0.9))
    }

    private func intensity(_ value: Double, thresholds: (Double, Double, Double)) -> Int {
        guard value > 0 else { return 0 }
        if value <= thresholds.0 { return 1 }
        if value <= thresholds.1 { return 2 }
        if value <= thresholds.2 { return 3 }
        return 4
    }
}

private struct HeatmapCell: View {
    let bin: HeatBin
    let size: CGFloat

    @Environment(UsageStore.self) private var store

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.heatmapLevel(bin.level))
            .frame(width: size, height: size)
            .overlay {
                if store.selectedDate == bin.date {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Theme.foreground, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectedDate = store.selectedDate == bin.date ? nil : bin.date
            }
            .help(tooltip)
    }

    private var tooltip: String {
        var lines = [
            "\(bin.date) · 等级 \(bin.level)",
            "总用量 \(Fmt.tokens(Double(bin.tokens))) Token",
        ]
        let top = bin.models.sorted { $0.value > $1.value }.prefix(6)
        if !top.isEmpty {
            lines.append("模型明细")
            let total = Double(bin.tokens)
            for (key, tokens) in top {
                let parts = key.split(separator: "\u{1f}")
                let source = parts.first.map { SourceCatalog.label(String($0)) } ?? "未知"
                let model = parts.count > 1 ? String(parts[1]) : ""
                let pct = total > 0 ? Double(tokens) / total * 100 : 0
                lines.append("  \(source) · \(model)  \(Fmt.tokens(Double(tokens))) · \(Fmt.pct(pct))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
