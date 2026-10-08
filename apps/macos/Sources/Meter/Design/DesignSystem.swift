import AppKit
import SwiftUI

// MARK: - Adaptive colors
//
// The Electron app expressed every token as a CSS custom property with a light
// and a dark value. NSColor's dynamic provider gives the same "resolve per
// appearance" behaviour natively.

extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let raw = UInt32(value, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((raw >> 16) & 0xFF) / 255,
            green: CGFloat((raw >> 8) & 0xFF) / 255,
            blue: CGFloat(raw & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// A color that resolves differently in light and dark appearance.
    init(light: String, dark: String) {
        let dynamic = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light) ?? .labelColor
        }
        self.init(nsColor: dynamic)
    }

    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex) ?? .labelColor)
    }
}

// MARK: - Semantic tokens
//
// Mirrors the HeroUI semantic layer the renderer relied on, plus the literal
// values that were hard-coded in `index.css` / `DesktopWindow.ts`.

enum Theme {
    static let background = Color(light: "#f5f5f5", dark: "#050607")
    static let surface = Color(light: "#ffffff", dark: "#101113")
    static let surfaceSecondary = Color(light: "#fafafa", dark: "#17181b")
    static let surfaceTertiary = Color(light: "#f4f4f5", dark: "#1e1f23")
    static let overlay = Color(light: "#ffffff", dark: "#1b1c20")
    static let foreground = Color(light: "#18181b", dark: "#f4f4f5")
    static let muted = Color(light: "#71717a", dark: "#a1a1aa")
    static let border = Color(light: "#e4e4e7", dark: "#28292d")
    static let accent = Color(light: "#0485f7", dark: "#48a7ff")
    static let positive = Color(light: "#16a34a", dark: "#4ade80")
    static let negative = Color(light: "#dc2626", dark: "#f87171")
    static let warning = Color(light: "#d97706", dark: "#fbbf24")

    /// `--chart-1..8` from the renderer's stylesheet.
    private static let chartRamp: [(String, String)] = [
        ("#0485f7", "#48a7ff"),
        ("#4fbd91", "#62cfa4"),
        ("#f0a12b", "#f4b64c"),
        ("#8b6ee8", "#aa91f2"),
        ("#e45b55", "#f07872"),
        ("#d65791", "#e776aa"),
        ("#20a5a5", "#45bdbd"),
        ("#7e8797", "#a0a8b6"),
    ]

    static func chartColor(_ index: Int) -> Color {
        let (light, dark) = chartRamp[((index % chartRamp.count) + chartRamp.count) % chartRamp.count]
        return Color(light: light, dark: dark)
    }

    /// Five-step heatmap intensity (`--heatmap-0..4`).
    ///
    /// `--heatmap-1..3` were `color-mix(in oklab, var(--accent) N%, var(--surface))`;
    /// these pre-blended values match closely and avoid per-cell compositing.
    static func heatmapLevel(_ level: Int) -> Color {
        switch level {
        case 0: return Color(light: "#ececee", dark: "#1c1d21")
        case 1: return Color(light: "#cfe5fa", dark: "#16324d")
        case 2: return Color(light: "#93c5f6", dark: "#1d4a75")
        case 3: return Color(light: "#4b9ff0", dark: "#2f6ba8")
        default: return accent
        }
    }
}

// MARK: - Tool / source catalog
//
// Ported verbatim from `apps/desktop/src/renderer/lib/tokens.ts` so tool ids
// that arrive with a family prefix (`claude-desktop`, `deepseek-harness`, …)
// still resolve to one row, one label and one colour.

enum SourceCatalog {
    struct Entry {
        let label: String
        let light: String
        let dark: String
    }

    private static let entries: [String: Entry] = [
        "claude": Entry(label: "Claude", light: "#f0a12b", dark: "#f4b64c"),
        "codex": Entry(label: "Codex", light: "#4fbd91", dark: "#62cfa4"),
        "cursor": Entry(label: "Cursor", light: "#0485f7", dark: "#48a7ff"),
        "qoder": Entry(label: "Qoder", light: "#e85d04", dark: "#fb923c"),
        "trae": Entry(label: "Trae", light: "#0d9488", dark: "#2dd4bf"),
        "gemini": Entry(label: "Gemini", light: "#4285f4", dark: "#6ba4f8"),
        "opencode": Entry(label: "OpenCode", light: "#ff5c00", dark: "#ff7a33"),
        "copilot": Entry(label: "Copilot", light: "#6e40c9", dark: "#8b5cf6"),
        "antigravity": Entry(label: "Antigravity", light: "#1a73e8", dark: "#4d9af5"),
        "openclaw": Entry(label: "OpenClaw", light: "#0ea5e9", dark: "#38bdf8"),
        "autoclaw": Entry(label: "AutoClaw", light: "#e11d48", dark: "#fb7185"),
        "hermes": Entry(label: "Hermes", light: "#7c3aed", dark: "#a78bfa"),
        "zcode": Entry(label: "ZCode", light: "#10b981", dark: "#34d399"),
        "dsh": Entry(label: "DeepSeek Harness", light: "#4d6bfe", dark: "#6b85fe"),
        "pi": Entry(label: "pi", light: "#f59e0b", dark: "#fbbf24"),
        "kimi": Entry(label: "Kimi", light: "#6366f1", dark: "#818cf8"),
        "roocode": Entry(label: "Roo Code", light: "#14b8a6", dark: "#2dd4bf"),
        "droid": Entry(label: "Droid", light: "#64748b", dark: "#94a3b8"),
        "kiro": Entry(label: "Kiro", light: "#ec4899", dark: "#f472b6"),
        "cline": Entry(label: "Cline", light: "#f97316", dark: "#fb923c"),
        "amp": Entry(label: "Amp", light: "#a855f7", dark: "#c084fc"),
        "qwen": Entry(label: "Qwen Code", light: "#6366f1", dark: "#818cf8"),
        "codebuddy": Entry(label: "CodeBuddy", light: "#0052d9", dark: "#3b82f6"),
        "workbuddy": Entry(label: "WorkBuddy", light: "#0ea5e9", dark: "#38bdf8"),
        "grok": Entry(label: "Grok Build", light: "#111827", dark: "#e5e7eb"),
        "mimo": Entry(label: "Mimo", light: "#ff6900", dark: "#fb923c"),
        "every-code": Entry(label: "Every Code", light: "#4fbd91", dark: "#62cfa4"),
        "omp": Entry(label: "OMP", light: "#6366f1", dark: "#818cf8"),
        "kilo-cli": Entry(label: "Kilo CLI", light: "#22c55e", dark: "#4ade80"),
        "kilocode": Entry(label: "Kilo Code", light: "#22c55e", dark: "#4ade80"),
        "goose": Entry(label: "Goose", light: "#f97316", dark: "#fb923c"),
        "zed": Entry(label: "Zed", light: "#084ccf", dark: "#3b82f6"),
        "warp": Entry(label: "Warp", light: "#01a4ff", dark: "#38bdf8"),
        "qwenwork": Entry(label: "QwenWork", light: "#7c3aed", dark: "#a78bfa"),
        "command-code": Entry(label: "Command Code", light: "#06b6d4", dark: "#22d3ee"),
        "minimax-code": Entry(label: "MiniMax Code", light: "#ef4444", dark: "#f87171"),
        "wps-comate": Entry(label: "WPS Comate", light: "#e34d59", dark: "#ff6b6b"),
    ]

    /// Normalises a raw `source` value onto a catalog key.
    /// Order matters: `qwenwork` must be checked before `qwen`, `pi` before
    /// `kimi`, and `kilo-cli` before `kilocode`.
    static func canonical(_ source: String) -> String {
        let key = source.lowercased()
        func has(_ prefix: String) -> Bool { key.hasPrefix(prefix) }

        if key == "claude-code" || has("claude") { return "claude" }
        if key == "codex" || has("codex") { return "codex" }
        if key == "cursor" || has("cursor") { return "cursor" }
        if key == "qoder" || has("qoder") { return "qoder" }
        if key == "trae" || has("trae") { return "trae" }
        if key == "gemini-cli" || has("gemini") { return "gemini" }
        if key == "open-code" || has("opencode") { return "opencode" }
        if key == "github-copilot" || key == "copilot-cli" || has("copilot") { return "copilot" }
        if has("antigravity") { return "antigravity" }
        if has("openclaw") || has("open-claw") { return "openclaw" }
        if key == "auto-claw" || has("autoclaw") { return "autoclaw" }
        if has("hermes") { return "hermes" }
        if has("zcode") || key == "zai" { return "zcode" }
        if key == "dsh" || key == "deepseek" || key == "harness"
            || has("deepseek-harness") || has("dsh-") { return "dsh" }
        if key == "pi-coding-agent" || has("pi") { return "pi" }
        if has("kimi") { return "kimi" }
        if key == "roo-code" || has("roocode") || has("roo") { return "roocode" }
        if has("droid") || has("factory") { return "droid" }
        if has("kiro") { return "kiro" }
        if has("cline") { return "cline" }
        if has("amp") { return "amp" }
        if has("qwenwork") { return "qwenwork" }
        if key == "qwen-code" || has("qwen") { return "qwen" }
        if has("codebuddy") || key == "code-buddy" { return "codebuddy" }
        if has("workbuddy") { return "workbuddy" }
        if has("grok") { return "grok" }
        if has("mimo") || key == "mimocode" || has("xiaomi") { return "mimo" }
        if key == "everycode" || has("every-code") { return "every-code" }
        if has("omp") || key == "oh-my-pi" { return "omp" }
        if has("kilo-cli") || key == "kilo" { return "kilo-cli" }
        if has("kilocode") || key == "kilo-code" { return "kilocode" }
        if has("goose") { return "goose" }
        if has("zed") { return "zed" }
        if has("warp") { return "warp" }
        if has("command-code") || has("commandcode") { return "command-code" }
        if has("minimax-code") || key == "mcode" { return "minimax-code" }
        if has("wps-comate") || has("wpscomate") { return "wps-comate" }
        return key
    }

    static func label(_ source: String) -> String {
        entries[canonical(source)]?.label ?? source
    }

    /// Display order for the "支持的工具" list, following `TOOL_CATALOG`'s
    /// `sortOrder` then the remaining ids alphabetically.
    static let orderedKeys: [String] = [
        "cursor", "claude", "codex", "trae", "qoder", "opencode", "copilot",
        "gemini", "antigravity", "kimi", "qwen", "dsh", "grok", "zcode",
        "openclaw", "autoclaw", "hermes", "roocode", "kilocode", "kilo-cli",
        "cline", "goose", "zed", "warp", "droid", "kiro", "amp", "mimo",
        "codebuddy", "workbuddy", "pi", "omp", "every-code", "qwenwork",
        "command-code", "minimax-code", "wps-comate",
    ]

    /// `(key, displayName)` pairs for every catalogued tool.
    static var allTools: [(key: String, label: String)] {
        orderedKeys.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return (key, entry.label)
        }
    }

    static func color(_ source: String) -> Color {
        guard let entry = entries[canonical(source)] else { return Theme.muted }
        return Color(light: entry.light, dark: entry.dark)
    }
}

// MARK: - Fonts
//
// The renderer used JetBrains Mono for both prose and numerals. Use it when the
// user happens to have it installed and fall back to SF Mono otherwise.

enum AppFont {
    private static let jetBrainsAvailable: Bool = {
        NSFont(name: "JetBrainsMono-Regular", size: 12) != nil
            || NSFont(name: "JetBrains Mono", size: 12) != nil
    }()

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if jetBrainsAvailable {
            return .custom("JetBrainsMono-Regular", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if jetBrainsAvailable {
            return .custom("JetBrainsMono-Regular", size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

// MARK: - Number formatting
//
// Straight ports of `lib/format.ts` / `lib/utils.ts`. Note the units are
// T/B/M/K — *not* Chinese 万/亿 — and `formatTokens` carries to the next unit at
// exactly 1000 so that 1_000_000_000 renders as `1B`, not `1000M`.

enum Fmt {
    /// `formatCompactTokenCount` — one decimal, trailing `.0` stripped.
    static func tokens(_ value: Double) -> String {
        let n = value.isFinite ? value : 0
        let sign = n < 0 ? "-" : ""
        let abs = Swift.abs(n)

        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000_000, "T"),
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K"),
        ]
        for unit in units where abs >= unit.threshold {
            let scaled = abs / unit.threshold
            // Carry guard: 999.95K must not render as `1000K`.
            let rounded = (scaled * 10).rounded() / 10
            if rounded >= 1000, let next = nextUnit(after: unit.suffix) {
                return sign + trim((rounded / 1000)) + next
            }
            return sign + trim(rounded) + unit.suffix
        }
        return sign + String(Int(abs.rounded()))
    }

    private static func nextUnit(after suffix: String) -> String? {
        switch suffix {
        case "K": return "M"
        case "M": return "B"
        case "B": return "T"
        default: return nil
        }
    }

    private static func trim(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// `formatTokensExact` — grouped integer, e.g. `1,234,567`.
    static func tokensExact(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value.isFinite ? value : 0)
    }

    /// `formatPct` — the API already sends percentages with one decimal.
    static func pct(_ value: Double) -> String {
        String(format: "%.1f%%", value.isFinite ? value : 0)
    }

    /// `cacheHitRate` is a 0…1 fraction, unlike `pct`.
    static func rate(_ value: Double) -> String {
        String(format: "%.1f%%", (value.isFinite ? value : 0) * 100)
    }

    /// Signed compact delta used by the 输入/输出 Token trend chips.
    static func deltaTokens(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "\u{2212}"  // U+2212 minus, matching the renderer
        return sign + tokens(Swift.abs(value))
    }

    static func percentChange(_ value: Double) -> String {
        let arrow = value >= 0 ? "\u{2191}" : "\u{2193}"  // ↑ / ↓
        return "\(arrow) \(String(format: "%.1f%%", Swift.abs(value)))"
    }

    /// `M月d日` / `Oct 7`; the formatting itself lives in `Copy` so that both
    /// languages stay in one place.
    static func monthDay(_ isoDate: String) -> String {
        let parts = isoDate.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return isoDate
        }
        return Copy.monthDay(month: month, day: day)
    }

    /// Relative "最近同步" caption.
    static func relativeSync(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return Copy.never }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return Copy.unknown }

        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return Copy.justNow }
        if elapsed < 3600 { return Copy.minutesAgo(Int(elapsed / 60)) }
        if elapsed < 86_400 { return Copy.hoursAgo(Int(elapsed / 3600)) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if L10n.isEnglish {
            return "\(Copy.monthAbbreviation(month)) \(day), \(clock)"
        }
        return "\(month)/\(day) \(clock)"
    }
}

// MARK: - Card chrome
//
// Liquid Glass (macOS 26) replaces the old opaque surface + hairline border:
// every card is a glass shape that refracts the popover's material behind it.

struct CardSurface<Content: View>: View {
    var padding: CGFloat = 11
    var cornerRadius: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// Thinner glass used for inner rows and nested panels, so a card inside a card
/// still reads as layered rather than doubling the blur.
struct InnerGlassSurface<Content: View>: View {
    var padding: CGFloat = 8
    var cornerRadius: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// Section header: title + optional description, matching the card titles the
/// renderer used (`当日趋势` / `最近 N 天的 Token 与费用趋势`).
struct CardHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.text(12, weight: .semibold))
                    .foregroundStyle(Theme.foreground)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.text(10))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Compact legend for the charts.
///
/// Swift Charts drops its own legend when the plot frame is short — the stacked
/// token bars ended up with no legend at all — so the series key is drawn here,
/// where the size and wording are under our control.
struct ChartLegendRow: View {
    let items: [(label: String, color: Color)]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(item.color)
                        .frame(width: 7, height: 7)
                    Text(item.label)
                        .font(AppFont.text(8))
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Empty-state copy used across every card.
struct CardEmptyState: View {
    var message: String = Copy.emptyNoData

    var body: some View {
        Text(message)
            .font(AppFont.text(12))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
