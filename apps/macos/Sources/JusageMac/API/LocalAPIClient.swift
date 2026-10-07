import Foundation

/// Typed client for the Node sidecar's local HTTP API.
///
/// The routes, query defaults and response envelope are the existing
/// `packages/core/src/server/local-api.ts` contract — the same one the Electron
/// renderer used over IPC. Only usage-statistics routes are exposed here;
/// leaderboard / calibration / upload routes are intentionally not called.
actor LocalAPIClient {
    private var baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(host: String, port: Int) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        // Local sidecar only: never route through a proxy or cache stale stats.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    func updateEndpoint(host: String, port: Int) {
        baseURL = URL(string: "http://\(host):\(port)")!
    }

    // MARK: - Usage statistics

    func health() async throws -> Bool {
        struct Health: Decodable { let ok: Bool }
        let value: Health = try await requestRaw("/health")
        return value.ok
    }

    func usageSummary() async throws -> UsageSummary {
        try await request("/functions/tud-usage-summary")
    }

    /// `days` defaults to 90 server-side; clamped to 1…365 there.
    func usageDaily(days: Int) async throws -> DailyUsageResponse {
        try await request("/functions/tud-usage-daily", query: [URLQueryItem(name: "days", value: String(days))])
    }

    /// `days` defaults to 1 server-side.
    func usageHourly(days: Int) async throws -> HourlyUsageResponse {
        try await request("/functions/tud-usage-hourly", query: [URLQueryItem(name: "days", value: String(days))])
    }

    /// `days` defaults to 30 server-side.
    func modelBreakdown(days: Int) async throws -> ModelBreakdownResponse {
        try await request(
            "/functions/tud-usage-model-breakdown",
            query: [URLQueryItem(name: "days", value: String(days))]
        )
    }

    // MARK: - Runtime state

    func syncStatus() async throws -> SyncStatus {
        try await request("/functions/tud-sync-status")
    }

    func localConfig() async throws -> LocalConfigView {
        try await request("/functions/tud-config")
    }

    @discardableResult
    func triggerSync(source: String? = nil) async throws -> TriggerSyncResponse {
        var body: [String: String] = [:]
        if let source { body["source"] = source }
        return try await request(
            "/functions/tud-trigger-sync",
            method: "POST",
            body: body.isEmpty ? nil : try JSONEncoder().encode(body)
        )
    }

    /// Widens the local collect window so a longer range has data to show.
    /// `days` must be one of 1 / 7 / 30 / 90 (the server rejects anything else).
    @discardableResult
    func ensureLocalRange(days: Int) async throws -> EnsureLocalRangeResponse {
        try await request(
            "/functions/tud-ensure-local-range",
            method: "POST",
            body: try JSONEncoder().encode(["days": days])
        )
    }

    // MARK: - Plumbing

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        let envelope: APIEnvelope<T> = try await perform(path, method: method, query: query, body: body)
        guard envelope.success else {
            throw APIError(message: envelope.message ?? "请求失败", status: nil)
        }
        guard let data = envelope.data else {
            throw APIError(message: "响应缺少 data 字段", status: nil)
        }
        return data
    }

    private func requestRaw<T: Decodable>(_ path: String) async throws -> T {
        try await perform(path, method: "GET", query: [], body: nil)
    }

    private func perform<T: Decodable>(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError(message: "非法请求地址 \(path)", status: nil)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw APIError(message: "非法请求地址 \(path)", status: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError(message: "无法连接本地统计服务：\(error.localizedDescription)", status: nil)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Error envelopes still carry a machine-readable message.
            if let envelope = try? decoder.decode(APIEnvelope<EmptyPayload>.self, from: data) {
                throw APIError(message: envelope.message ?? "HTTP \(status)", status: status)
            }
            throw APIError(message: "HTTP \(status)", status: status)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(message: "解析响应失败：\(error)", status: status)
        }
    }
}

private struct EmptyPayload: Decodable {}
