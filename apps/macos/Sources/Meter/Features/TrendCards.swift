import Charts
import SwiftUI

/// One plotted value: which bucket, which series, how much.
private struct SeriesPoint: Identifiable {
    let id: String
    let index: Int
    let series: String
    let value: Double
}

/// `Token 用量` — a single total area, or a detailed breakdown by token kind.
struct TokenTrendCard: View {
    let points: [TrendPoint]
    /// `今天` plots hours rather than days, which the title states.
    let isToday: Bool

    @State private var detailed = false

    /// Exact series colours from `TokenUsageTrendCard.tsx`.
    private let totalColor = Color(light: "#1f6fe5", dark: "#48a7ff")
    private let inputColor = Color(light: "#71bd99", dark: "#62cfa4")
    private let outputColor = Color(light: "#397fec", dark: "#6ba4f8")
    private let cacheColor = Color(light: "#e9a846", dark: "#f4b64c")
    private let otherColor = Color(light: "#8c7ae6", dark: "#aa91f2")

    var body: some View {
        CardSurface(padding: 11) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    title: isToday ? Copy.tokenUsageToday : Copy.tokenUsage,
                    subtitle: detailed ? Copy.tokenTrendDetailedSubtitle : Copy.tokenTrendSubtitle
                ) {
                    SegmentedPicker(
                        options: [false, true],
                        selection: $detailed,
                        label: { $0 ? Copy.pickerDetail : Copy.pickerAll }
                    )
                }

                if points.isEmpty {
                    CardEmptyState().frame(height: 132)
                } else {
                    chart.frame(height: 132)
                    if detailed {
                        ChartLegendRow(items: activeKeys.map { ($0.name, $0.color) })
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            if detailed {
                ForEach(series(keys: activeKeys)) { point in
                    AreaMark(
                        x: .value(Copy.axisDate, point.index),
                        y: .value(Copy.axisToken, point.value)
                    )
                    .foregroundStyle(by: .value(Copy.axisSeries, point.series))
                    .opacity(0.22)
                    LineMark(
                        x: .value(Copy.axisDate, point.index),
                        y: .value(Copy.axisToken, point.value)
                    )
                    .foregroundStyle(by: .value(Copy.axisSeries, point.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            } else {
                ForEach(series(keys: activeKeys)) { point in
                    AreaMark(
                        x: .value(Copy.axisDate, point.index),
                        y: .value(Copy.axisToken, point.value)
                    )
                    .foregroundStyle(totalColor.opacity(0.25))
                    LineMark(
                        x: .value(Copy.axisDate, point.index),
                        y: .value(Copy.axisToken, point.value)
                    )
                    .foregroundStyle(totalColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
            }
        }
        // Domain and range come from the same list that feeds the marks, so the
        // style scale can never disagree with the plotted series.
        .chartForegroundStyleScale(
            domain: activeKeys.map(\.name),
            range: activeKeys.map(\.color)
        )
        .chartLegend(.hidden)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
    }

    private typealias Key = (name: String, color: Color, value: KeyPath<TrendPoint, Double>)

    private var totalKey: Key { (Copy.seriesTotalTokens, totalColor, \.totalTokens) }

    private var detailedKeys: [Key] {
        [
            totalKey,
            (Copy.seriesInput, inputColor, \.inputTokens),
            (Copy.seriesOutput, outputColor, \.outputTokens),
            (Copy.seriesCache, cacheColor, \.cachedTokens),
            (Copy.seriesOther, otherColor, \.otherTokens),
        ]
    }

    private var activeKeys: [Key] { detailed ? detailedKeys : [totalKey] }

    private func series(keys: [Key]) -> [SeriesPoint] {
        points.enumerated().flatMap { index, point in
            keys.map { key in
                SeriesPoint(
                    id: "\(index)-\(key.name)",
                    index: index,
                    series: key.name,
                    value: point[keyPath: key.value]
                )
            }
        }
    }

    /// The x axis is plotted from an integer index, but Swift Charts treats it
    /// as a continuous domain and hands marks back as `Double` — reading
    /// `value.as(Int.self)` silently produced no labels at all.
    private var xAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisGridLine().foregroundStyle(Theme.border)
            AxisValueLabel {
                if let raw = value.as(Double.self),
                   points.indices.contains(Int(raw.rounded())) {
                    Text(points[Int(raw.rounded())].label)
                        .font(AppFont.text(8))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(Theme.border)
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(Fmt.tokens(amount))
                        .font(AppFont.text(8))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

/// `每日趋势` / `今日趋势` — stacked token kinds, or the cost curve.
struct DailyTrendCard: View {
    let points: [TrendPoint]
    let subtitle: String
    @Binding var metric: UsageStore.MetricKind

    /// `--chart-1` / `--chart-3` / `--chart-2` / `--chart-6` from the renderer.
    private let inputColor = Theme.chartColor(0)
    private let cachedColor = Theme.chartColor(2)
    private let outputColor = Theme.chartColor(1)
    private let otherColor = Theme.chartColor(5)
    private let costColor = Theme.chartColor(0)

    var body: some View {
        CardSurface(padding: 11) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    title: metric == .tokens ? Copy.dailyTrend : Copy.costTrend,
                    subtitle: subtitle
                ) {
                    SegmentedPicker(
                        options: [UsageStore.MetricKind.tokens, .cost],
                        selection: $metric,
                        label: { $0 == .tokens ? Copy.metricTokens : Copy.metricCostShort }
                    )
                }

                if points.isEmpty {
                    CardEmptyState().frame(height: 132)
                } else {
                    chart.frame(height: 132)
                    if metric == .tokens {
                        ChartLegendRow(items: tokenKeys.map { ($0.name, $0.color) })
                    }
                }
            }
        }
    }

    private typealias Key = (name: String, color: Color, value: KeyPath<TrendPoint, Double>)

    /// Series key for the stacked bars; the cost curve is a single series.
    private var tokenKeys: [Key] {
        [
            (Copy.seriesInput, inputColor, \.inputTokens),
            (Copy.seriesCachedInput, cachedColor, \.cachedTokens),
            (Copy.seriesOutput, outputColor, \.outputTokens),
            (Copy.seriesOther, otherColor, \.otherTokens),
        ]
    }

    private struct Bucket: Identifiable {
        let id: String
        let index: Int
        let series: String
        let value: Double
    }

    private var bars: [Bucket] {
        points.enumerated().flatMap { index, point in
            tokenKeys.map { key in
                Bucket(
                    id: "\(index)-\(key.name)",
                    index: index,
                    series: key.name,
                    value: point[keyPath: key.value]
                )
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if metric == .tokens {
            Chart(bars) { bucket in
                // The x axis is a continuous integer index, so the bar width
                // must be stated explicitly (`.ratio` of the step): without it
                // Swift Charts falls back to a fixed mark size, which makes bars
                // overlap once the range has 30–90 buckets.
                BarMark(
                    x: .value(Copy.axisDate, bucket.index),
                    y: .value(Copy.axisToken, bucket.value),
                    width: .ratio(0.72)
                )
                .foregroundStyle(by: .value(Copy.axisSeries, bucket.series))
            }
            .chartForegroundStyleScale(
                domain: tokenKeys.map(\.name),
                range: tokenKeys.map(\.color)
            )
            .chartLegend(.hidden)
            .chartXAxis { axis }
            .chartYAxis { yAxis }
        } else {
            Chart(points.enumerated().map { index, point in
                Bucket(id: "cost-\(index)", index: index, series: Copy.seriesCost, value: point.costUsd)
            }) { bucket in
                AreaMark(
                    x: .value(Copy.axisDate, bucket.index),
                    y: .value(Copy.axisCost, bucket.value)
                )
                .foregroundStyle(costColor.opacity(0.25))
                LineMark(
                    x: .value(Copy.axisDate, bucket.index),
                    y: .value(Copy.axisCost, bucket.value)
                )
                .foregroundStyle(costColor)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            .chartXAxis { axis }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(Fmt.usd(amount))
                                .font(AppFont.text(8))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
        }
    }

    /// See `TokenTrendCard.xAxis`: the mark value arrives as `Double`, not `Int`.
    private var axis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisGridLine().foregroundStyle(Theme.border)
            AxisValueLabel {
                if let raw = value.as(Double.self),
                   points.indices.contains(Int(raw.rounded())) {
                    Text(points[Int(raw.rounded())].label)
                        .font(AppFont.text(8))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(Theme.border)
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(Fmt.tokens(amount))
                        .font(AppFont.text(8))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}
