import AppKit
import SwiftUI

/// The app's primary surface: the dashboard shown inside the menu-bar popover.
///
/// There is no main window and no tool buttons here — 同步 / 主题 / 设置 / 关于 /
/// 退出 all live in the status item's right-click menu (`StatusItemController`).
/// Styled with Liquid Glass (macOS 26).
struct DashboardPanel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(UsageStore.self) private var store
    @Environment(AppPreferences.self) private var prefs

    @State private var metric: UsageStore.MetricKind = .tokens

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            content
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .task {
            // Keeps a panel opened before the engine is ready from staying empty.
            if !store.hasLoadedOnce {
                await store.reload()
            }
        }
    }

    // MARK: - 顶部工具栏

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Meter")
                    .font(AppFont.text(12, weight: .semibold))
                if store.isSyncing {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
                Text(store.range.longLabel)
                    .font(AppFont.text(10))
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: 6) {
                SegmentedPicker(
                    options: AppPreferences.Range.allCases,
                    selection: Binding(
                        get: { prefs.range },
                        set: { prefs.range = $0; store.range = $0 }
                    ),
                    label: \.label
                )
                ChannelFilterMenu()
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, PanelMetrics.outerPadding)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                banners

                if let caption = store.drilldownCaption {
                    DrilldownChip(caption: caption) { store.clearDrilldown() }
                }

                OverviewSection(metric: metric)

                TokenTrendCard(points: store.trendPoints, isToday: store.range == .today)
                DailyTrendCard(points: store.trendPoints, subtitle: trendSubtitle, metric: $metric)

                StackedBarsCard(
                    title: Copy.cardToolModel,
                    subtitle: Copy.cardToolModelSubtitle,
                    help: Copy.cardToolModelHelp,
                    rows: store.toolModelRows,
                    emptyMessage: store.isFilteringSources ? Copy.emptyChannelNoUsage : Copy.emptyNoToolModel,
                    visibleRows: 6
                )
                StackedBarsCard(
                    title: Copy.cardProject,
                    subtitle: Copy.cardProjectSubtitle,
                    help: Copy.cardProjectHelp,
                    rows: store.projectStackedRows,
                    emptyMessage: Copy.emptyNoProject,
                    visibleRows: 6
                )
                DistributionCard(
                    title: Copy.cardToolDistribution,
                    subtitle: Copy.cardToolDistributionSubtitle,
                    slices: store.distribution(by: .tool, metric: metric),
                    metric: $metric
                )
                DistributionCard(
                    title: Copy.cardModelDistribution,
                    subtitle: Copy.cardModelDistributionSubtitle,
                    slices: store.distribution(by: .model, metric: metric),
                    metric: $metric
                )

                footer
            }
            .padding(.horizontal, PanelMetrics.outerPadding)
            .padding(.top, PanelMetrics.sectionSpacing)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var banners: some View {
        if let error = store.errorMessage {
            StatusBanner(tone: .error, message: error)
        } else if case .failed(let failure) = env.engine.phase {
            StatusBanner(tone: .error, message: failure.message)
        } else if store.hasLoadedOnce, store.isEmptyDataset {
            StatusBanner(tone: .info, message: Copy.noUsageData)
        } else if !store.hasLoadedOnce {
            StatusBanner(tone: .info, message: Copy.localServiceRecovering)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(Copy.lastSync(store.lastSyncCaption))
                .font(AppFont.text(9))
                .foregroundStyle(Theme.muted)
            if store.isExpandingRange {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
            Text(env.engineStatusText)
                .font(AppFont.text(9))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.top, 2)
    }

    // MARK: - Derived labels

    private var trendSubtitle: String {
        if store.selectedDate != nil {
            return Copy.byHour(Fmt.monthDay(store.focusedDate))
        }
        if store.range == .today {
            return Copy.hourlyTrendToday
        }
        return Copy.dailyTrendRange(store.range.days)
    }
}

// MARK: - Filters

/// Segmented control for the range and metric switches.
struct SegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(AppFont.text(10))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? Theme.accent : Color.clear)
                        )
                        .foregroundStyle(isSelected ? Color.white : Theme.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }
}

/// `全部渠道` / one channel / `已选 N 个渠道`, with a clear action.
private struct ChannelFilterMenu: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        Menu {
            if !store.selectedSources.isEmpty {
                Button(Copy.clearChannelFilter) { store.selectedSources = [] }
                Divider()
            }
            ForEach(store.availableSources, id: \.self) { source in
                Toggle(
                    SourceCatalog.label(source),
                    isOn: Binding(
                        get: { store.selectedSources.contains(source) },
                        set: { _ in store.toggleSource(source) }
                    )
                )
            }
        } label: {
            HStack(spacing: 4) {
                if store.selectedSources.count == 1, let only = store.selectedSources.first {
                    Circle()
                        .fill(SourceCatalog.color(only))
                        .frame(width: 6, height: 6)
                }
                Text(store.channelFilterLabel)
                    .font(AppFont.text(10))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Misc chrome

private struct DrilldownChip: View {
    let caption: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(caption)
                .font(AppFont.text(10))
                .foregroundStyle(Theme.foreground)
            Button(Copy.clear, action: onClear)
                .font(AppFont.text(10))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
    }
}

struct StatusBanner: View {
    enum Tone { case info, warn, error, success }

    let tone: Tone
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .font(AppFont.text(10))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassEffect(glass, in: .rect(cornerRadius: 9))
    }

    private var icon: String {
        switch tone {
        case .info: return "info.circle"
        case .warn: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .success: return "checkmark.circle"
        }
    }

    private var foreground: Color {
        switch tone {
        case .info: return Theme.muted
        case .warn: return Theme.warning
        case .error: return Theme.negative
        case .success: return Theme.positive
        }
    }

    private var glass: Glass {
        switch tone {
        case .info: return .regular
        case .warn: return .regular.tint(Theme.warning.opacity(0.35))
        case .error: return .regular.tint(Theme.negative.opacity(0.35))
        case .success: return .regular.tint(Theme.positive.opacity(0.35))
        }
    }
}
