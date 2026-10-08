import Foundation
import Observation

// MARK: - Languages

/// The concrete language the UI renders in. Only these two ship today.
enum UILanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Endonym: the picker shows each language in its own script, so it stays
    /// readable whichever language is currently active.
    var nativeName: String {
        switch self {
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// The stored preference. `.system` follows the macOS language order.
enum LanguagePreference: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return Copy.languageSystem
        case .chinese: return UILanguage.chinese.nativeName
        case .english: return UILanguage.english.nativeName
        }
    }

    var resolved: UILanguage {
        switch self {
        case .system: return Localization.systemLanguage()
        case .chinese: return .chinese
        case .english: return .english
        }
    }
}

// MARK: - Active language

/// Holds the resolved language for the whole app.
///
/// `@Observable` is what makes a switch live: every view body that read a
/// localized string registered `language` as a dependency, so flipping it
/// re-renders the popover, the settings window and the About window in place,
/// with no relaunch. All copy goes through `Copy`, which always reads this.
///
/// Deliberately not `@MainActor`: `Fmt` and `LanguagePreference` are plain,
/// non-isolated enums that read it too. `apply(_:)` is only ever called from the
/// main thread (`AppPreferences`), which is what the app's reads assume.
@Observable
final class Localization {
    static let shared = Localization()

    private(set) var language: UILanguage
    private(set) var preference: LanguagePreference = .system

    private init() {
        language = Self.systemLanguage()
    }

    /// Applies a stored preference. `.system` re-resolves the macOS order on
    /// every launch, so a system-wide change — or the per-app language override
    /// in System Settings, which lands in `Locale.preferredLanguages` too — is
    /// picked up at startup without the app storing anything.
    func apply(_ preference: LanguagePreference) {
        self.preference = preference
        language = preference.resolved
    }

    /// First entry of the user's preferred languages that this app speaks.
    ///
    /// macOS reports the whole list, so a French or Japanese system lands on
    /// English rather than falling back to Chinese.
    static func systemLanguage(preferred: [String] = Locale.preferredLanguages) -> UILanguage {
        for identifier in preferred {
            let tag = identifier.lowercased()
            if tag.hasPrefix("zh") { return .chinese }
            if tag.hasPrefix("en") { return .english }
        }
        return .english
    }
}

/// Shorthand for the `Copy` table and the format helpers.
enum L10n {
    static var language: UILanguage { Localization.shared.language }
    static var isEnglish: Bool { language == .english }

    /// A Chinese source string paired with its English translation.
    static func t(_ chinese: String, _ english: String) -> String {
        isEnglish ? english : chinese
    }
}

// MARK: - String table

/// Every user-facing string, keyed by meaning and paired `中文 / English`.
///
/// The pair lives next to its key rather than in separate `.lproj` resources:
/// the SwiftPM bundle ships one executable, and a *missing* translation would
/// otherwise only surface at runtime. Placeholders keep their order (`%02d`-style
/// formats are avoided in favour of interpolation so a translator can reorder).
enum Copy {
    // MARK: Menu bar and context menu

    static var panelShow: String { L10n.t("显示用量面板", "Show usage panel") }
    static var syncNow: String { L10n.t("同步数据", "Sync now") }
    static var theme: String { L10n.t("主题", "Theme") }
    static var settings: String { L10n.t("设置", "Settings") }
    static var settingsEllipsis: String { L10n.t("设置…", "Settings…") }
    static var aboutMeter: String { L10n.t("关于 Meter", "About Meter") }
    static var quit: String { L10n.t("退出", "Quit") }
    static var about: String { L10n.t("关于", "About") }
    static var closeSettings: String { L10n.t("关闭设置", "Close settings") }
    static var closeAbout: String { L10n.t("关闭关于", "Close about") }

    // MARK: Theme, tray display and time range

    static var themeSystem: String { L10n.t("跟随系统", "System") }
    static var themeLight: String { L10n.t("浅色", "Light") }
    static var themeDark: String { L10n.t("深色", "Dark") }

    static var trayBoth: String { L10n.t("Token 和金额", "Tokens & cost") }
    static var trayTokens: String { L10n.t("仅 Token", "Tokens only") }
    static var trayCost: String { L10n.t("仅金额", "Cost only") }

    static var rangeToday: String { L10n.t("今天", "Today") }
    static var rangeWeekLong: String { L10n.t("近 7 天", "Last 7 days") }
    static var rangeMonthLong: String { L10n.t("近 30 天", "Last 30 days") }
    static var rangeQuarterLong: String { L10n.t("近 90 天", "Last 90 days") }

    static var language: String { L10n.t("语言", "Language") }
    static var languageSystem: String { L10n.t("跟随系统", "Follow system") }

    // MARK: Channel filter

    static var allChannels: String { L10n.t("全部渠道", "All channels") }
    static func channelsSelected(_ count: Int) -> String {
        L10n.t("已选 \(count) 个渠道", "\(count) channels selected")
    }
    static var clearChannelFilter: String { L10n.t("清空渠道筛选", "Clear channel filter") }
    static var clear: String { L10n.t("清除", "Clear") }

    // MARK: Dashboard chrome

    static var noUsageData: String { L10n.t("暂无用量数据", "No usage data yet") }
    static var localServiceRecovering: String {
        L10n.t("本地服务正在恢复，请稍候", "The local service is recovering, please wait")
    }
    static func lastSync(_ caption: String) -> String {
        L10n.t("最近同步：\(caption)", "Last sync: \(caption)")
    }
    static func byHour(_ date: String) -> String {
        L10n.t("\(date) 按小时", "\(date), by hour")
    }
    static var hourlyTrendToday: String {
        L10n.t("今日按小时的 Token 与费用趋势", "Hourly token and cost trend for today")
    }
    static func dailyTrendRange(_ days: Int) -> String {
        L10n.t("最近 \(days) 天的 Token 与费用趋势", "Token and cost trend over the last \(days) days")
    }

    // MARK: Panel cards

    static var cardToolModel: String { L10n.t("工具与模型用量", "Tool & model usage") }
    static var cardToolModelSubtitle: String { L10n.t("按平台比较总 Token", "Total tokens by platform") }
    static var cardToolModelHelp: String {
        L10n.t("按编程工具与 Agent 比较总 Token", "Compare total tokens across coding tools and agents")
    }
    static var emptyNoToolModel: String { L10n.t("暂无工具或模型用量", "No tool or model usage yet") }
    static var emptyChannelNoUsage: String {
        L10n.t("当前渠道暂无用量", "No usage for the selected channels")
    }

    static var cardProject: String { L10n.t("项目分布", "Project breakdown") }
    static var cardProjectSubtitle: String { L10n.t("按项目比较总 Token", "Total tokens by project") }
    static var cardProjectHelp: String {
        L10n.t(
            "按工作目录查看用量。仅本地展示，不上报。部分工具如 Cursor 暂无项目信息。",
            "Usage by working directory. Local only, never uploaded. Some tools, such as Cursor, do not report a project."
        )
    }
    static var emptyNoProject: String { L10n.t("暂无项目用量", "No project usage yet") }

    static var cardToolDistribution: String { L10n.t("工具分布", "Tool distribution") }
    static var cardToolDistributionSubtitle: String {
        L10n.t("按编程工具与 Agent 查看用量占比", "Share of usage by coding tool and agent")
    }
    static var cardModelDistribution: String { L10n.t("模型分布", "Model distribution") }
    static var cardModelDistributionSubtitle: String {
        L10n.t("按模型查看 Token 与费用占比", "Share of tokens and cost by model")
    }

    // MARK: Metric cards

    static var metricCost: String { L10n.t("预估费用", "Estimated cost") }
    static var metricCostHelp: String {
        L10n.t(
            "按本地定价表与已采集用量估算，不是账单金额。",
            "Estimated from the local pricing table and the collected usage — not a bill."
        )
    }

    static var metricTotalTokens: String { L10n.t("总 Token", "Total tokens") }
    static var metricTotalTokensHelpTitle: String { L10n.t("总 Token 构成", "Total token composition") }
    static var metricTotalTokensFootnote: String {
        L10n.t(
            """
            总 Token = 输入 + 输出 + 缓存读 + 缓存写 + 其它
            请求数优先用本地请求证据；无证据时按 conversation 累计；不完整时可能偏低。
            """,
            """
            Total tokens = input + output + cache read + cache write + other
            Request counts prefer local request evidence, fall back to conversation totals, and can undercount when incomplete.
            """
        )
    }

    static var metricInputTokens: String { L10n.t("输入 Token", "Input tokens") }
    static var metricInputTokensHelp: String {
        L10n.t(
            """
            不含缓存读取与缓存写入。
            缓存命中率 = 缓存读 ÷（输入 + 缓存读 + 缓存写）。
            """,
            """
            Excludes cache reads and cache writes.
            Cache hit rate = cache read ÷ (input + cache read + cache write).
            """
        )
    }
    static func cacheHitRate(_ rate: String) -> String {
        L10n.t("缓存命中率 \(rate)", "Cache hit rate \(rate)")
    }

    static var metricOutputTokens: String { L10n.t("输出 Token", "Output tokens") }
    static var metricOutputTokensHelp: String {
        L10n.t(
            "部分工具（如 Codex）的推理 Token 已计入输出。",
            "Reasoning tokens from some tools (such as Codex) are already counted as output."
        )
    }

    static func exactValue(_ value: String) -> String {
        L10n.t("精确值：\(value)", "Exact value: \(value)")
    }

    // Token composition rows (total-token help popover).
    static var tokenInput: String { L10n.t("输入", "Input") }
    static var tokenOutput: String { L10n.t("输出", "Output") }
    static var tokenCacheRead: String { L10n.t("缓存 · 读", "Cache · read") }
    static var tokenCacheWrite: String { L10n.t("缓存 · 写", "Cache · write") }
    static var tokenOther: String { L10n.t("其它", "Other") }
    static var tokenTotal: String { L10n.t("合计", "Total") }

    // MARK: Activity heatmap

    static var heatmapTitle: String { L10n.t("活动热力图", "Activity heatmap") }
    static var heatmapSubtitle: String {
        L10n.t(
            "每日 Token 用量，点击某天可筛选整个看板",
            "Daily token usage — click a day to filter the whole dashboard"
        )
    }
    static var heatmapLess: String { L10n.t("少", "Less") }
    static var heatmapMore: String { L10n.t("多", "More") }

    /// Column labels, Sunday first in both languages.
    static var weekdayInitials: [String] {
        L10n.isEnglish
            ? ["S", "M", "T", "W", "T", "F", "S"]
            : ["日", "一", "二", "三", "四", "五", "六"]
    }

    /// Short month name above the heatmap's first column of each month.
    static func monthAbbreviation(_ month: Int) -> String {
        let names = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        let index = min(max(month, 1), 12) - 1
        return L10n.isEnglish ? names[index] : "\(month)月"
    }

    /// `10月7日` / `Oct 7`. Built from `monthAbbreviation` rather than a
    /// `DateFormatter` so the result never depends on the process locale.
    static func monthDay(month: Int, day: Int) -> String {
        L10n.isEnglish ? "\(monthAbbreviation(month)) \(day)" : "\(month)月\(day)日"
    }

    static func heatmapTooltipTitle(_ date: String, level: Int) -> String {
        L10n.t("\(date) · 等级 \(level)", "\(date) · level \(level)")
    }
    static func heatmapTooltipTotal(_ tokens: String) -> String {
        L10n.t("总用量 \(tokens) Token", "\(tokens) tokens in total")
    }
    static var modelBreakdown: String { L10n.t("模型明细", "Model breakdown") }
    static var unknown: String { L10n.t("未知", "Unknown") }

    // MARK: Trends

    static var tokenUsageToday: String { L10n.t("今日 Token 用量", "Today's token usage") }
    static var tokenUsage: String { L10n.t("Token 用量", "Token usage") }
    static var tokenTrendDetailedSubtitle: String {
        L10n.t("输入、输出、缓存与其他 Token 趋势", "Input, output, cache and other token trend")
    }
    static var tokenTrendSubtitle: String { L10n.t("总 Token 用量趋势", "Total token usage trend") }

    static var pickerDetail: String { L10n.t("详细", "Detail") }
    static var pickerAll: String { L10n.t("全部", "All") }

    static var dailyTrend: String { L10n.t("每日趋势", "Daily trend") }
    static var costTrend: String { L10n.t("费用趋势", "Cost trend") }

    // Chart series and axis names. The series names double as Swift Charts'
    // style-scale keys, so they must come from one place per chart.
    static var seriesTotalTokens: String { L10n.t("总 Token", "Total tokens") }
    static var seriesInput: String { L10n.t("输入", "Input") }
    static var seriesOutput: String { L10n.t("输出", "Output") }
    static var seriesCache: String { L10n.t("缓存", "Cache") }
    static var seriesCachedInput: String { L10n.t("缓存输入", "Cached input") }
    static var seriesOther: String { L10n.t("其他", "Other") }
    static var seriesCost: String { L10n.t("费用", "Cost") }

    static var metricTokens: String { L10n.t("Token", "Token") }
    static var metricTokensPlural: String { L10n.t("Tokens", "Tokens") }
    static var metricCostShort: String { L10n.t("费用", "Cost") }
    /// Unit word after a count: `1.2M Token` / `1.2M tokens`.
    static var tokenUnit: String { L10n.t("Token", "tokens") }

    static var axisDate: String { L10n.t("日期", "Date") }
    static var axisSeries: String { L10n.t("系列", "Series") }
    static var axisToken: String { L10n.t("Token", "Token") }
    static var axisCost: String { L10n.t("费用", "Cost") }
    static var axisUsage: String { L10n.t("用量", "Usage") }

    // MARK: Breakdown cards

    static func showAll(_ count: Int) -> String {
        L10n.t("查看全部（\(count)）", "View all (\(count))")
    }
    static var collapse: String { L10n.t("收起", "Show less") }

    static func legendShow(_ label: String) -> String { L10n.t("显示 \(label)", "Show \(label)") }
    static func legendHide(_ label: String) -> String { L10n.t("隐藏 \(label)", "Hide \(label)") }

    static func barTooltip(_ label: String, tokens: String, cost: String) -> String {
        L10n.t("\(label) · \(tokens) Token · \(cost)", "\(label) · \(tokens) tokens · \(cost)")
    }
    static func modelCount(_ count: Int, cost: String) -> String {
        L10n.t("\(count) 个模型 · \(cost)", "\(count) models · \(cost)")
    }
    static var emptyNoData: String { L10n.t("暂无数据", "No data yet") }

    // MARK: Settings

    static var tabApp: String { L10n.t("应用", "App") }
    static var tabDevice: String { L10n.t("设备信息", "Device") }
    static var tabAbout: String { L10n.t("关于", "About") }

    static var interfaceAndMenuBar: String { L10n.t("界面与菜单栏", "Interface & menu bar") }
    static var showTrayUsage: String {
        L10n.t("在菜单栏显示今日用量", "Show today's usage in the menu bar")
    }
    static var displayMode: String { L10n.t("显示方式", "Display") }
    static var defaultRange: String { L10n.t("默认时间范围", "Default range") }

    static var statisticsEngine: String { L10n.t("统计引擎", "Statistics engine") }
    static var takeOwnership: String {
        L10n.t("接管本地同步（结束其他采集进程）", "Take over local sync (stop other collectors)")
    }
    static var takeOwnershipNote: String {
        L10n.t(
            "关闭时，若 CLI 或旧版桌面端正在采集，本应用只读取同一份 ~/.ai-usage 数据，不抢占采集权。开启后会结束对方的采集进程并独自接管。",
            "When off, this app only reads the shared ~/.ai-usage data while the CLI or the legacy desktop app is collecting. When on, it stops the other collector and takes over exclusively."
        )
    }
    static var restartEngine: String { L10n.t("重新启动引擎", "Restart engine") }

    static var localCollection: String { L10n.t("本地采集", "Local collection") }
    static var dataDirectory: String { L10n.t("数据目录", "Data directory") }
    static var statsSince: String { L10n.t("统计起点", "Collecting since") }
    static var lastSyncLabel: String { L10n.t("上次同步", "Last sync") }
    static var engineVersion: String { L10n.t("引擎版本", "Engine version") }
    static var daysCollected: String { L10n.t("已采集天数", "Days collected") }
    static var toolCount: String { L10n.t("工具数量", "Tools") }
    static func daysValue(_ count: Int) -> String { L10n.t("\(count) 天", "\(count) days") }
    static func countValue(_ count: Int) -> String { L10n.t("\(count) 个", "\(count)") }
    static var localOnlyNote: String {
        L10n.t(
            "所有用量数据都保存在本机，不会上传。",
            "All usage data stays on this machine; nothing is ever uploaded."
        )
    }

    static var versionInfo: String { L10n.t("版本信息", "Version") }
    static var client: String { L10n.t("客户端", "Client") }
    static var system: String { L10n.t("系统", "System") }
    static var supportedTools: String { L10n.t("支持的工具", "Supported tools") }
    static var supportedToolsNote: String {
        L10n.t(
            "同一系列的多端形态用括号标出。",
            "Multi-surface variants of the same family are shown in parentheses."
        )
    }

    // MARK: Statistics engine

    static var engineStarting: String { L10n.t("正在启动统计引擎…", "Starting the statistics engine…") }
    static var engineRestarting: String {
        L10n.t("正在重启统计引擎…", "Restarting the statistics engine…")
    }
    static func engineConnected(_ port: Int) -> String {
        L10n.t("已连接 127.0.0.1:\(port)", "Connected to 127.0.0.1:\(port)")
    }
    static var engineInvalidPort: String {
        L10n.t("统计引擎未返回有效端口", "The statistics engine did not report a valid port")
    }
    static var engineLaunchFailed: String {
        L10n.t("统计引擎启动失败", "The statistics engine failed to start")
    }
    static func engineSpawnFailed(_ detail: String) -> String {
        L10n.t("启动统计引擎失败：\(detail)", "Failed to start the statistics engine: \(detail)")
    }
    static func engineExitedImmediately(_ status: Int32) -> String {
        L10n.t(
            "统计引擎启动后立即退出（exit \(status)）",
            "The statistics engine exited right after launch (exit \(status))"
        )
    }
    static func engineLaunchFailed(_ status: Int32, detail: String) -> String {
        L10n.t(
            "统计引擎启动失败（exit \(status)）：\n\(detail)",
            "The statistics engine failed to start (exit \(status)):\n\(detail)"
        )
    }
    static var engineGaveUp: String {
        L10n.t(
            "统计引擎反复退出，已停止重试。请查看运行日志。",
            "The statistics engine keeps exiting, so retries have stopped. Check the runtime logs."
        )
    }
    static func locatorNodeMissing(_ overrideVariable: String) -> String {
        L10n.t(
            """
            未找到 Node.js 运行时。\
            请安装 Node 20+（brew install node），或设置环境变量 \(overrideVariable) 指向 node 可执行文件。
            """,
            """
            No Node.js runtime found. \
            Install Node 20+ (brew install node), or point the \(overrideVariable) environment variable at a node executable.
            """
        )
    }
    static func locatorScriptMissing(_ tried: [String]) -> String {
        L10n.t(
            """
            未找到统计引擎脚本 packages/engine/dist/index.js。\
            请先构建：pnpm --filter @juejin-opensource/jusage-engine build
            已尝试：\(tried.joined(separator: "、"))
            """,
            """
            The statistics engine script packages/engine/dist/index.js was not found. \
            Build it first: pnpm --filter @juejin-opensource/jusage-engine build
            Tried: \(tried.joined(separator: ", "))
            """
        )
    }

    // MARK: Store and API client

    static var dataLoadFailed: String { L10n.t("数据加载失败", "Failed to load the usage data") }
    static func dataLoadFailed(_ detail: String) -> String {
        L10n.t("数据加载失败：\(detail)", "Failed to load the usage data: \(detail)")
    }
    static var syncFailed: String { L10n.t("同步失败，请稍后重试", "Sync failed, please try again later") }
    static func requests(_ count: String) -> String { L10n.t("\(count) 次请求", "\(count) requests") }
    static func filteredTo(_ date: String) -> String {
        L10n.t("当前筛选：\(date)", "Filtered to \(date)")
    }

    static var never: String { L10n.t("从未", "Never") }
    static var justNow: String { L10n.t("刚刚", "Just now") }
    static func minutesAgo(_ minutes: Int) -> String {
        L10n.t("\(minutes) 分钟前", "\(minutes) min ago")
    }
    static func hoursAgo(_ hours: Int) -> String {
        L10n.t("\(hours) 小时前", "\(hours) h ago")
    }

    static var requestFailed: String { L10n.t("请求失败", "Request failed") }
    static var missingDataField: String {
        L10n.t("响应缺少 data 字段", "The response is missing its data field")
    }
    static func invalidRequestURL(_ path: String) -> String {
        L10n.t("非法请求地址 \(path)", "Invalid request URL \(path)")
    }
    static func localServiceUnreachable(_ detail: String) -> String {
        L10n.t(
            "无法连接本地统计服务：\(detail)",
            "Cannot reach the local statistics service: \(detail)"
        )
    }
    static func responseDecodeFailed(_ detail: String) -> String {
        L10n.t("解析响应失败：\(detail)", "Failed to parse the response: \(detail)")
    }
}
