import Foundation

// MARK: - Response envelope
//
// Every `/functions/tud-*` route answers with `{ success, message, data }`
// (see `packages/core/src/server/local-api.ts`). `/health` is the one
// exception and answers `{ ok: true }`.

struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let message: String?
    let data: T?
}

struct APIError: LocalizedError {
    let message: String
    let status: Int?

    var errorDescription: String? { message }
}

// MARK: - Lenient number decoding
//
// Queue rows written by older parsers omit optional counters, and aggregates
// emit plain JSON numbers. Decoding must never fail the whole response because
// one legacy field is absent.

private extension KeyedDecodingContainer {
    func token(_ key: Key, default fallback: Int64 = 0) -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int64(value.rounded()) }
        return fallback
    }

    func token(_ key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int64(value.rounded()) }
        return nil
    }

    func double(_ key: Key, default fallback: Double = 0) -> Double {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return Double(value) }
        return fallback
    }

    func int(_ key: Key, default fallback: Int = 0) -> Int {
        Int(token(key, default: Int64(fallback)))
    }
}

// MARK: - Local request/cache evidence
//
// `packages/core/src/local-metrics.ts` — `cacheHitRate` is a 0…1 fraction and
// nullable, unlike `pct` elsewhere which is already a percentage.

struct LocalUsageMetrics: Decodable, Hashable {
    let uncachedInputTokens: Int64
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let requestCount: Int64?
    let knownRequestCount: Int64
    let cacheHitRate: Double?
    let missingReasons: [String]

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens, cacheReadTokens, cacheWriteTokens, outputTokens
        case reasoningOutputTokens, requestCount, knownRequestCount, cacheHitRate, missingReasons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uncachedInputTokens = c.token(.uncachedInputTokens)
        cacheReadTokens = c.token(.cacheReadTokens)
        cacheWriteTokens = c.token(.cacheWriteTokens)
        outputTokens = c.token(.outputTokens)
        reasoningOutputTokens = c.token(.reasoningOutputTokens)
        requestCount = c.token(.requestCount)
        knownRequestCount = c.token(.knownRequestCount)
        cacheHitRate = try? c.decodeIfPresent(Double.self, forKey: .cacheHitRate) ?? nil
        missingReasons = (try? c.decodeIfPresent([String].self, forKey: .missingReasons)) ?? []
    }
}

// MARK: - GET /functions/tud-usage-summary

struct UsageSummary: Decodable {
    let totalTokens: Int64
    let totalCostUsd: Double
    let todayTokens: Int64
    let todayCostUsd: Double
    let statsSince: String
    let bySource: [SourceUsageRow]
    let localMetrics: LocalUsageMetrics?
    let todayLocalMetrics: LocalUsageMetrics?

    enum CodingKeys: String, CodingKey {
        case totalTokens, totalCostUsd, todayTokens, todayCostUsd, statsSince
        case bySource, localMetrics, todayLocalMetrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = c.token(.totalTokens)
        totalCostUsd = c.double(.totalCostUsd)
        todayTokens = c.token(.todayTokens)
        todayCostUsd = c.double(.todayCostUsd)
        statsSince = (try? c.decode(String.self, forKey: .statsSince)) ?? ""
        bySource = (try? c.decode([SourceUsageRow].self, forKey: .bySource)) ?? []
        localMetrics = try? c.decodeIfPresent(LocalUsageMetrics.self, forKey: .localMetrics) ?? nil
        todayLocalMetrics = try? c.decodeIfPresent(LocalUsageMetrics.self, forKey: .todayLocalMetrics) ?? nil
    }

    static let empty = UsageSummary()

    private init() {
        totalTokens = 0
        totalCostUsd = 0
        todayTokens = 0
        todayCostUsd = 0
        statsSince = ""
        bySource = []
        localMetrics = nil
        todayLocalMetrics = nil
    }
}

struct SourceUsageRow: Decodable, Identifiable {
    let source: String
    let tokens: Int64
    let costUsd: Double
    let pct: Double
    let models: [ModelUsageRow]
    let localMetrics: LocalUsageMetrics?

    var id: String { source }

    enum CodingKeys: String, CodingKey { case source, tokens, costUsd, pct, models, localMetrics }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decode(String.self, forKey: .source)) ?? "unknown"
        tokens = c.token(.tokens)
        costUsd = c.double(.costUsd)
        pct = c.double(.pct)
        models = (try? c.decode([ModelUsageRow].self, forKey: .models)) ?? []
        localMetrics = try? c.decodeIfPresent(LocalUsageMetrics.self, forKey: .localMetrics) ?? nil
    }
}

struct ModelUsageRow: Decodable, Identifiable {
    let model: String
    let tokens: Int64
    let costUsd: Double
    let pct: Double
    let localMetrics: LocalUsageMetrics?

    var id: String { model }

    enum CodingKeys: String, CodingKey { case model, tokens, costUsd, pct, localMetrics }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model)) ?? "unknown"
        tokens = c.token(.tokens)
        costUsd = c.double(.costUsd)
        pct = c.double(.pct)
        localMetrics = try? c.decodeIfPresent(LocalUsageMetrics.self, forKey: .localMetrics) ?? nil
    }
}

// MARK: - GET /functions/tud-usage-daily

struct DailyUsageResponse: Decodable {
    let days: [DailyUsageRow]

    enum CodingKeys: String, CodingKey { case days }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? c.decode([DailyUsageRow].self, forKey: .days)) ?? []
    }
}

struct DailyUsageRow: Decodable, Identifiable {
    let date: String
    let tokens: Int64
    let costUsd: Double
    /// Keys are `source\u{1f}model` (`dailyModelKey`).
    let models: [String: Int64]
    let projects: [DailyProjectUsage]
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedInputTokens: Int64
    let cacheCreationInputTokens: Int64
    let localMetrics: LocalUsageMetrics?

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date, tokens, costUsd, models, projects
        case inputTokens, outputTokens, cachedInputTokens, cacheCreationInputTokens, localMetrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        tokens = c.token(.tokens)
        costUsd = c.double(.costUsd)
        models = Self.decodeTokenMap(c, .models)
        projects = (try? c.decode([DailyProjectUsage].self, forKey: .projects)) ?? []
        inputTokens = c.token(.inputTokens)
        outputTokens = c.token(.outputTokens)
        cachedInputTokens = c.token(.cachedInputTokens)
        cacheCreationInputTokens = c.token(.cacheCreationInputTokens)
        localMetrics = try? c.decodeIfPresent(LocalUsageMetrics.self, forKey: .localMetrics) ?? nil
    }

    /// `models` maps use `source\u{1f}model` keys and arrive as JSON numbers;
    /// decode through `Double` so integral values are never rejected.
    static func decodeTokenMap(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [String: Int64] {
        guard let raw = (try? c.decodeIfPresent([String: Double].self, forKey: key)) ?? nil else {
            return [:]
        }
        return raw.mapValues { Int64($0.rounded()) }
    }
}

struct DailyProjectUsage: Decodable, Identifiable {
    let project: String
    let tokens: Int64
    let models: [String: Int64]

    var id: String { project }

    enum CodingKeys: String, CodingKey { case project, tokens, models }

    init(project: String, tokens: Int64, models: [String: Int64]) {
        self.project = project
        self.tokens = tokens
        self.models = models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = (try? c.decode(String.self, forKey: .project)) ?? "unknown"
        tokens = c.token(.tokens)
        guard let raw = (try? c.decodeIfPresent([String: Double].self, forKey: .models)) ?? nil else {
            models = [:]
            return
        }
        models = raw.mapValues { Int64($0.rounded()) }
    }

    func scaled(by share: Double) -> DailyProjectUsage {
        DailyProjectUsage(
            project: project,
            tokens: Int64((Double(tokens) * share).rounded()),
            models: models.mapValues { Int64((Double($0) * share).rounded()) }
        )
    }
}

// MARK: - Daily row reconstruction
//
// The custom `init(from:)` above suppresses the memberwise initializer, but the
// channel filter needs to rebuild rows at a proportional share.

extension DailyUsageRow {
    init(
        date: String,
        tokens: Int64,
        costUsd: Double,
        models: [String: Int64],
        projects: [DailyProjectUsage],
        inputTokens: Int64,
        outputTokens: Int64,
        cachedInputTokens: Int64,
        cacheCreationInputTokens: Int64,
        localMetrics: LocalUsageMetrics?
    ) {
        self.date = date
        self.tokens = tokens
        self.costUsd = costUsd
        self.models = models
        self.projects = projects
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.localMetrics = localMetrics
    }

    /// Applies the selected-channel share to every counter on the row.
    func scaled(by share: Double) -> DailyUsageRow {
        guard share < 1 else { return self }
        func apply(_ value: Int64) -> Int64 { Int64((Double(value) * share).rounded()) }
        return DailyUsageRow(
            date: date,
            tokens: apply(tokens),
            costUsd: costUsd * share,
            models: models.mapValues { Int64((Double($0) * share).rounded()) },
            projects: projects.map { $0.scaled(by: share) },
            inputTokens: apply(inputTokens),
            outputTokens: apply(outputTokens),
            cachedInputTokens: apply(cachedInputTokens),
            cacheCreationInputTokens: apply(cacheCreationInputTokens),
            localMetrics: localMetrics
        )
    }
}

extension ProjectBreakdownRow {
    init(
        project: String,
        tokens: Int64,
        costUsd: Double,
        pct: Double,
        models: [ProjectModelBreakdownRow],
        localMetrics: LocalUsageMetrics?
    ) {
        self.project = project
        self.tokens = tokens
        self.costUsd = costUsd
        self.pct = pct
        self.models = models
        self.localMetrics = localMetrics
    }

    /// Narrows the row to a subset of its models and re-bases the totals.
    func replacingModels(_ models: [ProjectModelBreakdownRow]) -> ProjectBreakdownRow {
        ProjectBreakdownRow(
            project: project,
            tokens: models.reduce(0) { $0 + $1.tokens },
            costUsd: models.reduce(0) { $0 + $1.costUsd },
            pct: pct,
            models: models,
            localMetrics: localMetrics
        )
    }

    func replacingPct(_ pct: Double) -> ProjectBreakdownRow {
        ProjectBreakdownRow(
            project: project,
            tokens: tokens,
            costUsd: costUsd,
            pct: pct,
            models: models,
            localMetrics: localMetrics
        )
    }
}

// MARK: - GET /functions/tud-usage-hourly

struct HourlyUsageResponse: Decodable {
    let hours: [HourlyUsageRow]
    let timeZone: String

    enum CodingKeys: String, CodingKey { case hours, timeZone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = (try? c.decode([HourlyUsageRow].self, forKey: .hours)) ?? []
        timeZone = (try? c.decode(String.self, forKey: .timeZone)) ?? "Asia/Shanghai"
    }
}

struct HourlyUsageRow: Decodable, Identifiable {
    let date: String
    let hour: Int
    let source: String
    let tokens: Int64
    let costUsd: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedInputTokens: Int64

    var id: String { "\(date)T\(hour)|\(source)" }

    enum CodingKeys: String, CodingKey {
        case date, hour, source, tokens, costUsd, inputTokens, outputTokens, cachedInputTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        hour = c.int(.hour)
        source = (try? c.decode(String.self, forKey: .source)) ?? "unknown"
        tokens = c.token(.tokens)
        costUsd = c.double(.costUsd)
        inputTokens = c.token(.inputTokens)
        outputTokens = c.token(.outputTokens)
        cachedInputTokens = c.token(.cachedInputTokens)
    }
}

// MARK: - GET /functions/tud-usage-model-breakdown

struct ModelBreakdownResponse: Decodable {
    let models: [ModelBreakdownRow]
    let projects: [ProjectBreakdownRow]

    enum CodingKeys: String, CodingKey { case models, projects }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = (try? c.decode([ModelBreakdownRow].self, forKey: .models)) ?? []
        projects = (try? c.decode([ProjectBreakdownRow].self, forKey: .projects)) ?? []
    }
}

struct ModelBreakdownRow: Decodable, Identifiable {
    let model: String
    let source: String
    let tokens: Int64
    let costUsd: Double
    let pct: Double
    let localMetrics: LocalUsageMetrics?

    var id: String { "\(source)\u{0}\(model)" }

    enum CodingKeys: String, CodingKey { case model, source, tokens, costUsd, pct, localMetrics }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model)) ?? "unknown"
        source = (try? c.decode(String.self, forKey: .source)) ?? "unknown"
        tokens = c.token(.tokens)
        costUsd = c.double(.costUsd)
        pct = c.double(.pct)
        localMetrics = try? c.decodeIfPresent(LocalUsageMetrics.self, forKey: .localMetrics) ?? nil
    }
}

struct ProjectBreakdownRow: Decodable, Identifiable {
    let project: String
    let tokens: Int64
    let costUsd: Double
    let pct: Double
    let models: [ProjectModelBreakdownRow]
    let localMetrics: LocalUsageMetrics?

    var id: String { project }

    enum CodingKeys: String, CodingKey { case project, tokens, costUsd, pct, models, localMetrics }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = (try? c.decode(String.self, forKey: .project)) ?? "unknown"
        tokens = c.token(.tokens)
        costUsd = c.double(.costUsd)
        pct = c.double(.pct)
        models = (try? c.decode([ProjectModelBreakdownRow].self, forKey: .models)) ?? []
        localMetrics = try? c.decodeIfPresent(LocalUsageMetrics.self, forKey: .localMetrics) ?? nil
    }
}

struct ProjectModelBreakdownRow: Decodable, Identifiable {
    let model: String
    let source: String
    let tokens: Int64
    let costUsd: Double
    /// Share of the parent project, not of the whole window.
    let pct: Double

    var id: String { "\(source)\u{0}\(model)" }

    enum CodingKeys: String, CodingKey { case model, source, tokens, costUsd, pct }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model)) ?? "unknown"
        source = (try? c.decode(String.self, forKey: .source)) ?? "unknown"
        tokens = c.token(.tokens)
        costUsd = c.double(.costUsd)
        pct = c.double(.pct)
    }
}

// MARK: - GET /functions/tud-sync-status

struct SyncStatus: Decodable {
    let lastSyncAt: String?
    let statsSince: String
    let pollIntervalSeconds: Int
    let sources: [String: SourceSyncState]

    enum CodingKeys: String, CodingKey { case lastSyncAt, statsSince, pollIntervalSeconds, sources }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSyncAt = try? c.decodeIfPresent(String.self, forKey: .lastSyncAt) ?? nil
        statsSince = (try? c.decode(String.self, forKey: .statsSince)) ?? ""
        pollIntervalSeconds = c.int(.pollIntervalSeconds, default: 60)
        sources = (try? c.decode([String: SourceSyncState].self, forKey: .sources)) ?? [:]
    }
}

struct SourceSyncState: Decodable {
    let status: String
    let rows: Int64?
    let hook: String
    let syncMode: String
    let message: String?
    let error: String?

    enum CodingKeys: String, CodingKey { case status, rows, hook, syncMode, message, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        rows = c.token(.rows)
        hook = (try? c.decode(String.self, forKey: .hook)) ?? ""
        syncMode = (try? c.decode(String.self, forKey: .syncMode)) ?? ""
        message = try? c.decodeIfPresent(String.self, forKey: .message) ?? nil
        error = try? c.decodeIfPresent(String.self, forKey: .error) ?? nil
    }
}

// MARK: - GET /functions/tud-config (local fields only)

struct LocalConfigView: Decodable {
    let statsSince: String
    let localCollectSince: String
    let lastSyncAt: String?

    enum CodingKeys: String, CodingKey { case statsSince, localCollectSince, lastSyncAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statsSince = (try? c.decode(String.self, forKey: .statsSince)) ?? ""
        localCollectSince = (try? c.decode(String.self, forKey: .localCollectSince)) ?? ""
        lastSyncAt = try? c.decodeIfPresent(String.self, forKey: .lastSyncAt) ?? nil
    }
}

struct TriggerSyncResponse: Decodable {
    let ok: Bool
    let message: String?

    enum CodingKeys: String, CodingKey { case ok, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        message = try? c.decodeIfPresent(String.self, forKey: .message) ?? nil
    }
}

/// `POST /functions/tud-ensure-local-range` — widens the local collect floor
/// (and rescans) when the user picks a range longer than what was collected.
struct EnsureLocalRangeResponse: Decodable {
    let expanded: Bool
    let localCollectSince: String?
    let statsSince: String?
    let message: String?

    enum CodingKeys: String, CodingKey { case expanded, localCollectSince, statsSince, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expanded = (try? c.decode(Bool.self, forKey: .expanded)) ?? false
        localCollectSince = try? c.decodeIfPresent(String.self, forKey: .localCollectSince) ?? nil
        statsSince = try? c.decodeIfPresent(String.self, forKey: .statsSince) ?? nil
        message = try? c.decodeIfPresent(String.self, forKey: .message) ?? nil
    }
}
