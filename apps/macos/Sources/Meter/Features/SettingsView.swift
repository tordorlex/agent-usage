import SwiftUI

/// `设置` sheet. Only usage-statistics preferences survive the Electron removal:
/// the pet / 掘金 / auto-update / autostart tabs are gone.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(UsageStore.self) private var store
    @Environment(AppPreferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case app, device, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .app: return Copy.tabApp
            case .device: return Copy.tabDevice
            case .about: return Copy.tabAbout
            }
        }
    }

    @State private var tab: Tab = .app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Copy.settings)
                    .font(AppFont.text(15, weight: .semibold))
                Spacer()
                Button(Copy.closeSettings) { dismiss() }
                    .font(AppFont.text(12))
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Tab.allCases) { item in
                        Button {
                            tab = item
                        } label: {
                            Text(item.title)
                                .font(AppFont.text(12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(tab == item ? Theme.accent.opacity(0.15) : .clear)
                                )
                                .foregroundStyle(tab == item ? Theme.accent : Theme.foreground)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 130)
                .background(Theme.surfaceSecondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch tab {
                        case .app: appTab
                        case .device: deviceTab
                        case .about: aboutTab
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 660, height: 480)
    }

    // MARK: - 应用

    @ViewBuilder
    private var appTab: some View {
        @Bindable var prefs = prefs

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(Copy.showTrayUsage, isOn: $prefs.showTrayUsage)
                    .font(AppFont.text(12))

                HStack {
                    Text(Copy.displayMode)
                        .font(AppFont.text(12))
                    Spacer()
                    Picker("", selection: $prefs.trayUsageMode) {
                        ForEach(AppPreferences.TrayUsageMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!prefs.showTrayUsage)
                }

                HStack {
                    Text(Copy.defaultRange)
                        .font(AppFont.text(12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { prefs.range },
                        set: { prefs.range = $0; store.range = $0 }
                    )) {
                        ForEach(AppPreferences.Range.allCases) { range in
                            Text(range.longLabel).tag(range)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                HStack {
                    Text(Copy.theme)
                        .font(AppFont.text(12))
                    Spacer()
                    Picker("", selection: $prefs.themeMode) {
                        ForEach(AppPreferences.ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                // The list shows each language in its own script and `.system`
                // follows the macOS language, so both audiences can get back to
                // their own wording without reading the other one.
                HStack {
                    Text(Copy.language)
                        .font(AppFont.text(12))
                    Spacer()
                    Picker("", selection: $prefs.language) {
                        ForEach(LanguagePreference.allCases) { preference in
                            Text(preference.label).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            .padding(6)
        } label: {
            Text(Copy.interfaceAndMenuBar).font(AppFont.text(12, weight: .semibold))
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.statisticsEngine)
                    .font(AppFont.text(12, weight: .semibold))

                Toggle(Copy.takeOwnership, isOn: Binding(
                    get: { prefs.takesOwnership },
                    set: { newValue in
                        prefs.takesOwnership = newValue
                        env.restartEngine()
                    }
                ))
                .font(AppFont.text(12))

                Text(Copy.takeOwnershipNote)
                    .font(AppFont.text(10))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(env.engineStatusText)
                        .font(AppFont.text(11))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button(Copy.restartEngine) { env.restartEngine() }
                        .font(AppFont.text(11))
                }
                if case .failed(let failure) = env.engine.phase {
                    Text(failure.message)
                        .font(AppFont.mono(10))
                        .foregroundStyle(Theme.negative)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 设备信息

    @ViewBuilder
    private var deviceTab: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                InfoRow(label: Copy.dataDirectory, value: env.dataDir.path)
                InfoRow(label: Copy.statsSince, value: store.syncStatus?.statsSince ?? Copy.unknown)
                InfoRow(label: Copy.lastSyncLabel, value: store.lastSyncCaption)
                InfoRow(label: Copy.engineVersion, value: engineVersionText)
                InfoRow(label: Copy.daysCollected, value: Copy.daysValue(store.heatmapDays.count))
                InfoRow(label: Copy.toolCount, value: Copy.countValue(store.availableSources.count))

                HStack {
                    Button(Copy.syncNow) {
                        Task { await store.triggerSync() }
                    }
                    .font(AppFont.text(11))
                    if store.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(Copy.localCollection).font(AppFont.text(12, weight: .semibold))
        }

        Text(Copy.localOnlyNote)
            .font(AppFont.text(11))
            .foregroundStyle(Theme.muted)
    }

    // MARK: - 关于

    @ViewBuilder
    private var aboutTab: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: Copy.versionInfo, value: "Meter \(appVersion)")
                InfoRow(label: Copy.statisticsEngine, value: engineVersionText)
                InfoRow(label: Copy.system, value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(Copy.versionInfo).font(AppFont.text(12, weight: .semibold))
        }

        SupportedToolsList()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var engineVersionText: String {
        env.engineVersion.isEmpty ? Copy.unknown : env.engineVersion
    }
}

/// Standalone `关于` sheet reachable from the dashboard toolbar.
struct AboutView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Copy.about)
                    .font(AppFont.text(15, weight: .semibold))
                Spacer()
                Button(Copy.closeAbout) { dismiss() }
                    .font(AppFont.text(12))
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Copy.versionInfo)
                            .font(AppFont.text(12, weight: .semibold))
                        InfoRow(label: Copy.client, value: appVersion)
                        InfoRow(
                            label: Copy.statisticsEngine,
                            value: env.engineVersion.isEmpty ? Copy.unknown : env.engineVersion
                        )
                        InfoRow(label: Copy.dataDirectory, value: env.dataDir.path)
                    }

                    SupportedToolsList()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 520)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}

/// `支持的工具` — every catalogued channel, in `SourceCatalog` order.
private struct SupportedToolsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.supportedTools)
                .font(AppFont.text(12, weight: .semibold))
            Text(Copy.supportedToolsNote)
                .font(AppFont.text(10))
                .foregroundStyle(Theme.muted)
            ForEach(SourceCatalog.allTools, id: \.key) { tool in
                HStack(spacing: 6) {
                    Circle()
                        .fill(SourceCatalog.color(tool.key))
                        .frame(width: 6, height: 6)
                    Text(tool.label)
                        .font(AppFont.text(11))
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    /// English labels are wider than their Chinese counterparts, so the column
    /// grows rather than truncating "Statistics engine" into "Statistics e…".
    private var labelWidth: CGFloat { L10n.isEnglish ? 104 : 76 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(AppFont.text(11))
                .foregroundStyle(Theme.muted)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(AppFont.mono(11))
                .foregroundStyle(Theme.foreground)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
