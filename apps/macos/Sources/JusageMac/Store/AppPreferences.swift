import Foundation
import Observation
import SwiftUI

/// User-facing preferences, persisted in `UserDefaults`.
///
/// Raw values for the range match the Electron app's ids (`last-7-days`, …) so
/// the wording and semantics stay identical even though the storage domain is new.
@MainActor
@Observable
final class AppPreferences {
    enum ThemeMode: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        var next: ThemeMode {
            switch self {
            case .system: return .light
            case .light: return .dark
            case .dark: return .system
            }
        }
    }

    enum TrayUsageMode: String, CaseIterable, Identifiable {
        case both, tokens, cost

        var id: String { rawValue }

        var label: String {
            switch self {
            case .both: return "Token 和金额"
            case .tokens: return "仅 Token"
            case .cost: return "仅金额"
            }
        }
    }

    /// `DashboardRange` — labels are the renderer's segmented-control labels.
    enum Range: String, CaseIterable, Identifiable {
        case today = "today"
        case week = "last-7-days"
        case month = "last-30-days"
        case quarter = "last-90-days"

        var id: String { rawValue }

        var days: Int {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            }
        }

        /// Segmented-control label: `今天` / `7D` / `30D` / `90D`.
        var label: String {
            switch self {
            case .today: return "今天"
            case .week: return "7D"
            case .month: return "30D"
            case .quarter: return "90D"
            }
        }

        /// Long form used in captions: `今天` / `近 7 天` / …
        var longLabel: String {
            switch self {
            case .today: return "今天"
            case .week: return "近 7 天"
            case .month: return "近 30 天"
            case .quarter: return "近 90 天"
            }
        }
    }

    private enum Key {
        static let themeMode = "tud.themeMode"
        static let range = "tud.dashboardRange"
        static let showTrayUsage = "tud.showTrayUsage"
        static let trayUsageMode = "tud.trayUsageMode"
        static let takesOwnership = "tud.takesOwnership"
    }

    private let defaults: UserDefaults

    var themeMode: ThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Key.themeMode) }
    }

    var range: Range {
        didSet { defaults.set(range.rawValue, forKey: Key.range) }
    }

    var showTrayUsage: Bool {
        didSet { defaults.set(showTrayUsage, forKey: Key.showTrayUsage) }
    }

    var trayUsageMode: TrayUsageMode {
        didSet { defaults.set(trayUsageMode.rawValue, forKey: Key.trayUsageMode) }
    }

    /// Take over `tud.pid` so this app alone runs collection.
    var takesOwnership: Bool {
        didSet { defaults.set(takesOwnership, forKey: Key.takesOwnership) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themeMode = ThemeMode(rawValue: defaults.string(forKey: Key.themeMode) ?? "") ?? .system
        range = Range(rawValue: defaults.string(forKey: Key.range) ?? "") ?? .week
        showTrayUsage = defaults.object(forKey: Key.showTrayUsage) as? Bool ?? true
        trayUsageMode = TrayUsageMode(rawValue: defaults.string(forKey: Key.trayUsageMode) ?? "") ?? .both
        takesOwnership = defaults.object(forKey: Key.takesOwnership) as? Bool ?? false
    }

    /// Menu-bar title, e.g. `1.2M Token · $3.40`.
    func trayTitle(tokens: Int64, costUsd: Double) -> String? {
        guard showTrayUsage else { return nil }
        switch trayUsageMode {
        case .tokens: return "\(Fmt.tokens(Double(tokens))) Token"
        case .cost: return Fmt.usd(costUsd)
        case .both: return "\(Fmt.tokens(Double(tokens))) Token · \(Fmt.usd(costUsd))"
        }
    }
}
