import Foundation
import Observation
import SwiftUI

// MARK: - Presentation models
//
// These mirror the shapes the renderer built in `lib/dashboard-data.ts` and
// `lib/chart-data.ts`: a trend point per bucket, stacked rows for the
// tool/model/project panels, and distribution slices for the donuts.

struct TrendPoint: Identifiable {
    let id: String
    let label: String
    let totalTokens: Double
    let inputTokens: Double
    let outputTokens: Double
    let cachedTokens: Double
    /// `max(0, total - input - cached - output)` — reasoning and any residual.
    let otherTokens: Double
    let costUsd: Double
}

struct StackedSegment: Identifiable {
    let id: String
    let label: String
    let value: Double
    let color: Color
}

struct StackedRow: Identifiable {
    let id: String
    let label: String
    let color: Color
    let detail: String
    let total: Double
    let costUsd: Double
    let pct: Double
    let segments: [StackedSegment]
}

struct DistributionSlice: Identifiable {
    let id: String
    let label: String
    let color: Color
    let tokens: Double
    let costUsd: Double
    let pct: Double
}

/// Range-scoped totals for the four metric cards.
struct OverviewTotals {
    var costUsd: Double = 0
    var tokens: Double = 0
    var inputTokens: Double = 0
    var outputTokens: Double = 0
    var cachedInputTokens: Double = 0
    var cacheCreationInputTokens: Double = 0
    /// `nil` when any contributing request count was unknown (matches the
    /// renderer's "null poisons the total" rule).
    var requestCount: Int64?
    var knownRequestCount: Int64 = 0

    var cacheHitRate: Double? {
        let denominator = inputTokens + cachedInputTokens + cacheCreationInputTokens
        guard denominator > 0 else { return nil }
        return cachedInputTokens / denominator
    }
}

/// Day-over-day change, matching `buildMetricChanges`.
struct MetricChanges {
    var totalCostUsd: Double = 0
    var totalTokens: Double = 0
    var inputTokens: Double = 0
    var outputTokens: Double = 0

    static func between(current: DailyUsageRow?, previous: DailyUsageRow?) -> MetricChanges {
        guard let current, let previous else { return MetricChanges() }
        func change(_ value: Double, _ before: Double) -> Double {
            before > 0 ? ((value - before) / before) * 100 : 0
        }
        return MetricChanges(
            totalCostUsd: change(current.costUsd, previous.costUsd),
            totalTokens: change(Double(current.tokens), Double(previous.tokens)),
            inputTokens: change(Double(current.inputTokens), Double(previous.inputTokens)),
            outputTokens: change(Double(current.outputTokens), Double(previous.outputTokens))
        )
    }
}

// MARK: - Store

/// Fetches usage statistics from the Node sidecar and derives everything the
/// dashboard renders. One instance is shared by the main window and the
/// menu-bar popover so both stay on the same range and filter.
@MainActor
@Observable
final class UsageStore {
    /// Daily rows are fetched with the heatmap lookback, then sliced per range.
    private static let heatmapLookbackDays = 365
    /// `useDashboardData` polled every 10 s, gated by a cheap sync probe.
    private static let pollInterval: Duration = .seconds(10)

    // MARK: Inputs

    var range: AppPreferences.Range {
        didSet {
            guard range != oldValue else { return }
            selectedDate = nil
            Task { await reloadForRangeChange() }
        }
    }

    /// Canonical source keys. Empty means 全部渠道 (no filtering, no scaling).
    var selectedSources: Set<String> = [] {
        didSet {
            guard selectedSources != oldValue else { return }
            pruneSelection()
        }
    }

    /// Heatmap drill-down; when set the whole dashboard narrows to that day.
    var selectedDate: String?

    // MARK: Raw payloads

    private(set) var summary: UsageSummary?
    private(set) var syncStatus: SyncStatus?
    private(set) var dailyRows: [DailyUsageRow] = []
    private(set) var hourlyRows: [HourlyUsageRow] = []
    private(set) var modelRows: [ModelBreakdownRow] = []
    private(set) var projectRows: [ProjectBreakdownRow] = []
    private(set) var statsTimezone: String = StatsClock.defaultTimeZone

    // MARK: State

    /// Why the dashboard has no data. Kept structural so the banner text follows
    /// the UI language; `.api` carries whatever the engine reported.
    enum Failure {
        case api(String)
        case load
        case loadDetail(String)
        case sync

        var message: String {
            switch self {
            case .api(let text): return text
            case .load: return Copy.dataLoadFailed
            case .loadDetail(let detail): return Copy.dataLoadFailed(detail)
            case .sync: return Copy.syncFailed
            }
        }
    }

    private(set) var isLoading = false
    private(set) var isSyncing = false
    private(set) var isExpandingRange = false
    private(set) var failure: Failure?
    private(set) var hasLoadedOnce = false

    /// Rendered by the dashboard banner; `nil` while everything is healthy.
    var errorMessage: String? { failure?.message }

    private var client: LocalAPIClient?
    private var pollTask: Task<Void, Never>?
    private var lastSyncStamp: String?
    /// Monotonic floor of ranges already ensured on the server.
    private var ensuredMaxDays = 0

    init(range: AppPreferences.Range = .week) {
        self.range = range
        self.selectedDate = nil
    }

    // MARK: Wiring

    func attach(client: LocalAPIClient) {
        self.client = client
        Task { await reload() }
        startPolling()
    }

    func detach() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                await self.probeAndReload()
            }
        }
    }

    // MARK: Loading

    /// Cheap probe: only refetch the full dataset when the engine reported a
    /// newer sync, so idle polling costs one small request.
    private func probeAndReload() async {
        guard let client, !isLoading else { return }
        do {
            let status = try await client.syncStatus()
            let stamp = status.lastSyncAt ?? ""
            if hasLoadedOnce, stamp == lastSyncStamp { return }
            lastSyncStamp = stamp
            await reload()
        } catch {
            // The engine may be restarting; a full reload reports the error.
            if !hasLoadedOnce { await reload() }
        }
    }

    func reload() async {
        await load(expandingRange: true)
    }

    private func reloadForRangeChange() async {
        await load(expandingRange: true)
    }

    private func load(expandingRange: Bool) async {
        guard let client else { return }
        guard !isLoading else { return }

        isLoading = true
        if !hasLoadedOnce { failure = nil }
        defer { isLoading = false }

        let rangeDays = range.days
        let dailyDays = max(rangeDays, Self.heatmapLookbackDays)
        let breakdownDays = rangeDays
        // Today's chart needs at least two days so the hourly axis can roll over.
        let hourlyDays = max(rangeDays == 1 ? 2 : rangeDays, 2)

        if expandingRange, rangeDays > ensuredMaxDays {
            await ensureRange(rangeDays, client: client)
        }

        do {
            async let summaryTask = client.usageSummary()
            async let statusTask = client.syncStatus()
            async let dailyTask = client.usageDaily(days: dailyDays)
            async let modelTask = client.modelBreakdown(days: breakdownDays)

            // An hourly failure must not fail the whole dashboard.
            async let hourlyTask: HourlyUsageResponse? = try? await client.usageHourly(days: hourlyDays)

            let loadedSummary = try await summaryTask
            let loadedStatus = try await statusTask
            let loadedDaily = try await dailyTask
            let loadedModels = try await modelTask
            let loadedHourly = await hourlyTask

            summary = loadedSummary
            syncStatus = loadedStatus
            dailyRows = loadedDaily.days
            modelRows = loadedModels.models.filter { $0.tokens > 0 }
            projectRows = loadedModels.projects.filter { $0.tokens > 0 }
            if let loadedHourly {
                hourlyRows = loadedHourly.hours
                statsTimezone = loadedHourly.timeZone
            }
            lastSyncStamp = loadedStatus.lastSyncAt ?? ""
            failure = nil
            hasLoadedOnce = true
            ensuredMaxDays = max(ensuredMaxDays, rangeDays)
        } catch let error as APIError {
            failure = .api(error.message)
        } catch {
            failure = .loadDetail(error.localizedDescription)
        }
    }

    /// Widens the server-side collect floor. Never shrinks it.
    private func ensureRange(_ days: Int, client: LocalAPIClient) async {
        isExpandingRange = true
        defer { isExpandingRange = false }
        do {
            _ = try await client.ensureLocalRange(days: days)
        } catch {
            // Non-fatal: the range simply shows whatever was already collected.
        }
    }

    func triggerSync() async {
        guard let client, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await client.triggerSync()
            // Give the engine a moment to write the queue before refetching.
            try? await Task.sleep(for: .milliseconds(600))
            ensuredMaxDays = 0
            await reload()
        } catch let error as APIError {
            failure = .api(error.message)
        } catch {
            failure = .sync
        }
    }

    // MARK: - Windows

    var today: String { StatsClock.today(statsTimezone) }
    var rangeStart: String { StatsClock.windowStart(days: range.days, statsTimezone) }

    /// The date the dashboard is focused on: an explicit drill-down, else today.
    var focusedDate: String { selectedDate ?? today }

    /// Rows inside the active window (or the drilled-down day).
    private var rangeDailyUnfiltered: [DailyUsageRow] {
        if let selectedDate {
            return dailyRows.filter { $0.date == selectedDate }
        }
        let start = rangeStart
        let end = today
        return dailyRows.filter { $0.date >= start && $0.date <= end }
    }

    /// All fetched days, for the 52-week heatmap.
    var heatmapDays: [DailyUsageRow] {
        let start = StatsClock.windowStart(days: Self.heatmapLookbackDays, statsTimezone)
        let end = today
        return dailyRows.filter { $0.date >= start && $0.date <= end }
    }

    // MARK: - Source filtering

    var isFilteringSources: Bool { !selectedSources.isEmpty }

    /// Raw source keys available in the current dataset, most-used first.
    var availableSources: [String] {
        var totals: [String: Int64] = [:]
        for row in modelRows {
            totals[SourceCatalog.canonical(row.source), default: 0] += row.tokens
        }
        return totals.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)
    }

    /// Selection badge text for the channel filter.
    var channelFilterLabel: String {
        if selectedSources.isEmpty { return Copy.allChannels }
        if selectedSources.count == 1 { return SourceCatalog.label(selectedSources.first!) }
        return Copy.channelsSelected(selectedSources.count)
    }

    func toggleSource(_ source: String) {
        let key = SourceCatalog.canonical(source)
        if selectedSources.contains(key) {
            selectedSources.remove(key)
        } else {
            selectedSources.insert(key)
        }
    }

    /// Drop selections whose tool no longer appears in the data.
    private func pruneSelection() {
        guard !selectedSources.isEmpty else { return }
        let available = Set(availableSources)
        guard !available.isEmpty else { return }
        let pruned = selectedSources.intersection(available)
        if pruned != selectedSources { selectedSources = pruned }
    }

    /// Share of a day's tokens belonging to the selected channels.
    ///
    /// The API's per-day `models` map is keyed `source\u{1f}model`, so the share
    /// can be computed exactly and applied to the row's totals (which also carry
    /// cost and the input/output breakdown) — the same proportional approach the
    /// renderer used.
    private func sourceShare(for day: DailyUsageRow) -> Double {
        guard isFilteringSources else { return 1 }
        var selected: Double = 0
        var total: Double = 0
        for (key, tokens) in day.models {
            let source = SourceCatalog.canonical(String(key.split(separator: "\u{1f}").first ?? ""))
            total += Double(tokens)
            if selectedSources.contains(source) { selected += Double(tokens) }
        }
        guard total > 0 else { return 0 }
        return selected / total
    }

    /// Range-wide fallback share for days that carry no per-day breakdown.
    private var rangeFallbackShare: Double {
        guard isFilteringSources else { return 1 }
        var selected: Double = 0
        var total: Double = 0
        for row in modelRows {
            total += Double(row.tokens)
            if selectedSources.contains(SourceCatalog.canonical(row.source)) {
                selected += Double(row.tokens)
            }
        }
        guard total > 0 else { return 0 }
        return selected / total
    }

    private func scaled(_ row: DailyUsageRow, share: Double) -> DailyUsageRow {
        guard share < 1 else { return row }
        return row.scaled(by: share)
    }

    /// Daily rows inside the window, scaled when a channel filter is active.
    var rangeDaily: [DailyUsageRow] {
        let rows = rangeDailyUnfiltered
        guard isFilteringSources else { return rows }
        let fallback = rangeFallbackShare
        return rows.map { row in
            let hasBreakdown = !row.models.isEmpty
            return scaled(row, share: hasBreakdown ? sourceShare(for: row) : fallback)
        }
    }

    /// Heatmap days, scaled the same way so the heatmap tracks the filter.
    var heatmapDaysFiltered: [DailyUsageRow] {
        let rows = heatmapDays
        guard isFilteringSources else { return rows }
        let fallback = rangeFallbackShare
        return rows.map { row in
            let hasBreakdown = !row.models.isEmpty
            return scaled(row, share: hasBreakdown ? sourceShare(for: row) : fallback)
        }
    }

    /// Model rows limited to the selected channels.
    var rangeModelRows: [ModelBreakdownRow] {
        guard isFilteringSources else { return modelRows }
        return modelRows.filter { selectedSources.contains(SourceCatalog.canonical($0.source)) }
    }

    /// Project rows limited to the selected channels; projects are re-based so
    /// `pct` stays a share of the visible total.
    var rangeProjectRows: [ProjectBreakdownRow] {
        guard isFilteringSources else { return projectRows }
        let filtered: [ProjectBreakdownRow] = projectRows.compactMap { row in
            let models = row.models.filter {
                selectedSources.contains(SourceCatalog.canonical($0.source))
            }
            guard !models.isEmpty else { return nil }
            return row.replacingModels(models)
        }
        let total = filtered.reduce(0.0) { $0 + Double($1.tokens) }
        guard total > 0 else { return filtered }
        return filtered.map { row in
            row.replacingPct(Double(row.tokens) / total * 100)
        }
    }

    // MARK: - Overview

    var overview: OverviewTotals {
        var totals = OverviewTotals()
        var poisoned = false
        var sawRequestEvidence = false

        for row in rangeDaily {
            totals.costUsd += row.costUsd
            totals.tokens += Double(row.tokens)
            totals.inputTokens += Double(row.inputTokens)
            totals.outputTokens += Double(row.outputTokens)
            totals.cachedInputTokens += Double(row.cachedInputTokens)
            totals.cacheCreationInputTokens += Double(row.cacheCreationInputTokens)

            if let metrics = row.localMetrics {
                sawRequestEvidence = true
                totals.knownRequestCount += metrics.knownRequestCount
                if let count = metrics.requestCount {
                    totals.requestCount = (totals.requestCount ?? 0) + count
                } else {
                    poisoned = true
                }
            }
        }

        if poisoned { totals.requestCount = nil }
        if !sawRequestEvidence { totals.requestCount = nil }
        return totals
    }

    /// Today's figures for the menu-bar title (from the API summary, which is
    /// always today-scoped and independent of the selected range).
    var todayTokens: Int64 { summary?.todayTokens ?? 0 }
    var todayCostUsd: Double { summary?.todayCostUsd ?? 0 }

    var changes: MetricChanges {
        let rows = rangeDaily
        guard rows.count >= 2 else { return MetricChanges() }
        return .between(current: rows[rows.count - 1], previous: rows[rows.count - 2])
    }

    /// Request-count caption, e.g. `132 次请求` / `132 requests`.
    var requestCaption: String? {
        let totals = overview
        let count = totals.requestCount ?? (totals.knownRequestCount > 0 ? totals.knownRequestCount : nil)
        guard let count else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let text = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return Copy.requests(text)
    }

    // MARK: - Trends

    /// Buckets for the trend cards: hours for `今天`, otherwise days.
    var trendPoints: [TrendPoint] {
        range == .today ? hourlyTrendPoints(for: focusedDate) : dailyTrendPoints()
    }

    private func dailyTrendPoints() -> [TrendPoint] {
        rangeDaily.map { row in
            let total = Double(row.tokens)
            let input = Double(row.inputTokens)
            let cached = Double(row.cachedInputTokens)
            let output = Double(row.outputTokens)
            return TrendPoint(
                id: row.date,
                label: StatsClock.axisLabel(row.date),
                totalTokens: total,
                inputTokens: input,
                outputTokens: output,
                cachedTokens: cached,
                otherTokens: max(0, total - input - cached - output),
                costUsd: row.costUsd
            )
        }
    }

    /// Aggregates the sparse (date, hour, source) rows into one point per hour.
    private func hourlyTrendPoints(for date: String) -> [TrendPoint] {
        let rows = hourlyRows.filter { $0.date == date }
        guard !rows.isEmpty else { return [] }

        var byHour: [Int: (total: Double, input: Double, output: Double, cached: Double, cost: Double)] = [:]
        for row in rows {
            var bucket = byHour[row.hour] ?? (0, 0, 0, 0, 0)
            bucket.total += Double(row.tokens)
            bucket.input += Double(row.inputTokens)
            bucket.output += Double(row.outputTokens)
            bucket.cached += Double(row.cachedInputTokens)
            bucket.cost += row.costUsd
            byHour[row.hour] = bucket
        }

        // Emit a continuous 0…maxHour axis so the chart has no gaps.
        guard let maxHour = byHour.keys.max() else { return [] }
        return (0...maxHour).map { hour in
            let bucket = byHour[hour] ?? (0, 0, 0, 0, 0)
            return TrendPoint(
                id: "\(date)T\(hour)",
                label: String(format: "%02d", hour),
                totalTokens: bucket.total,
                inputTokens: bucket.input,
                outputTokens: bucket.output,
                cachedTokens: bucket.cached,
                otherTokens: max(0, bucket.total - bucket.input - bucket.cached - bucket.output),
                costUsd: bucket.cost
            )
        }
    }

    /// Up to seven daily points ending at the focused day, for the sparklines.
    var sparklinePoints: [DailyUsageRow] {
        let end = focusedDate
        let start = StatsClock.addDays(-6, to: end, statsTimezone)
        return rangeDaily.filter { $0.date >= start && $0.date <= end }
    }

    // MARK: - Stacked breakdowns

    /// One row per channel, one segment per model.
    var toolModelRows: [StackedRow] {
        var bySource: [String: [ModelBreakdownRow]] = [:]
        for row in rangeModelRows {
            bySource[SourceCatalog.canonical(row.source), default: []].append(row)
        }
        let grandTotal = bySource.values.reduce(0.0) { $0 + $1.reduce(0.0) { $0 + Double($1.tokens) } }

        return bySource.map { source, rows -> StackedRow in
            let sorted = rows.sorted { $0.tokens > $1.tokens }
            let total = sorted.reduce(0.0) { $0 + Double($1.tokens) }
            let cost = sorted.reduce(0.0) { $0 + $1.costUsd }
            return StackedRow(
                id: source,
                label: SourceCatalog.label(source),
                color: SourceCatalog.color(source),
                detail: Copy.modelCount(sorted.count, cost: Fmt.usd(cost)),
                total: total,
                costUsd: cost,
                pct: grandTotal > 0 ? total / grandTotal * 100 : 0,
                segments: sorted.map { row in
                    StackedSegment(
                        id: "\(source)\u{1f}\(row.model)",
                        label: row.model,
                        value: Double(row.tokens),
                        color: Theme.chartColor(abs(row.model.hashValue) % 8)
                    )
                }
            )
        }
        .sorted { $0.total > $1.total }
    }

    /// 项目分布 — one row per project, one segment per (channel, model).
    var projectStackedRows: [StackedRow] {
        let rows = rangeProjectRows
        let grandTotal = rows.reduce(0.0) { $0 + Double($1.tokens) }

        return rows.map { row -> StackedRow in
            let models = row.models.sorted { $0.tokens > $1.tokens }
            let total = Double(row.tokens)
            let cost = row.costUsd
            return StackedRow(
                id: row.project,
                label: row.project,
                color: Theme.chartColor(abs(row.project.hashValue) % 8),
                detail: Copy.modelCount(models.count, cost: Fmt.usd(cost)),
                total: total,
                costUsd: cost,
                pct: grandTotal > 0 ? total / grandTotal * 100 : 0,
                segments: models.map { model in
                    StackedSegment(
                        id: "\(model.source)\u{1f}\(model.model)",
                        label: "\(SourceCatalog.label(model.source)) · \(model.model)",
                        value: Double(model.tokens),
                        color: SourceCatalog.color(model.source)
                    )
                }
            )
        }
        .sorted { $0.total > $1.total }
    }

    // MARK: - Distributions

    func distribution(by dimension: DistributionDimension, metric: MetricKind) -> [DistributionSlice] {
        var tokens: [String: Double] = [:]
        var cost: [String: Double] = [:]
        var labels: [String: String] = [:]
        var colors: [String: Color] = [:]

        let rows: [ModelBreakdownRow] = rangeModelRows
        for row in rows {
            let key: String
            switch dimension {
            case .tool:
                let source = SourceCatalog.canonical(row.source)
                key = source
                labels[key] = SourceCatalog.label(source)
                colors[key] = SourceCatalog.color(source)
            case .model:
                key = row.model
                labels[key] = row.model
                colors[key] = Theme.chartColor(abs(row.model.hashValue) % 8)
            }
            tokens[key, default: 0] += Double(row.tokens)
            cost[key, default: 0] += row.costUsd
        }

        let value: (String) -> Double = { key in
            metric == .tokens ? (tokens[key] ?? 0) : (cost[key] ?? 0)
        }
        let total = tokens.keys.reduce(0.0) { $0 + value($1) }
        guard total > 0 else { return [] }

        var slices = tokens.keys.map { key in
            DistributionSlice(
                id: key,
                label: labels[key] ?? key,
                color: colors[key] ?? Theme.muted,
                tokens: tokens[key] ?? 0,
                costUsd: cost[key] ?? 0,
                pct: value(key) / total * 100
            )
        }
        slices.sort { value($0.id) > value($1.id) }

        // Collapse the tail into 其他, the way the renderer normalised to ≤7 rows.
        let limit = 6
        guard slices.count > limit else { return slices }
        let head = Array(slices.prefix(limit))
        let tail = slices.dropFirst(limit)
        let otherTokens = tail.reduce(0.0) { $0 + $1.tokens }
        let otherCost = tail.reduce(0.0) { $0 + $1.costUsd }
        let otherValue = metric == .tokens ? otherTokens : otherCost
        return head + [
            DistributionSlice(
                id: "__other",
                label: Copy.seriesOther,
                color: Theme.muted,
                tokens: otherTokens,
                costUsd: otherCost,
                pct: otherValue / total * 100
            )
        ]
    }

    enum DistributionDimension { case tool, model }
    enum MetricKind { case tokens, cost }

    // MARK: - Heatmap drill-down

    var drilldownCaption: String? {
        guard let selectedDate else { return nil }
        return Copy.filteredTo(Fmt.monthDay(selectedDate))
    }

    func clearDrilldown() {
        selectedDate = nil
    }

    /// Last sync caption for the tray footer.
    var lastSyncCaption: String {
        Fmt.relativeSync(syncStatus?.lastSyncAt)
    }

    var isEmptyDataset: Bool { dailyRows.isEmpty }
}
