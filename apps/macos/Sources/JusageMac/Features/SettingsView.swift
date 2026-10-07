import SwiftUI

/// `设置` sheet. Only usage-statistics preferences survive the Electron removal:
/// the pet / 掘金 / auto-update / autostart tabs are gone.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(UsageStore.self) private var store
    @Environment(AppPreferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case app = "应用"
        case device = "设备信息"
        case about = "关于"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(AppFont.text(15, weight: .semibold))
                Spacer()
                Button("关闭设置") { dismiss() }
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
                            Text(item.rawValue)
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
                Toggle("在菜单栏显示今日用量", isOn: $prefs.showTrayUsage)
                    .font(AppFont.text(12))

                HStack {
                    Text("显示方式")
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
                    Text("默认时间范围")
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
                    Text("主题")
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
            }
            .padding(6)
        } label: {
            Text("界面与菜单栏").font(AppFont.text(12, weight: .semibold))
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("统计引擎")
                    .font(AppFont.text(12, weight: .semibold))

                Toggle("接管本地同步（结束其他采集进程）", isOn: Binding(
                    get: { prefs.takesOwnership },
                    set: { newValue in
                        prefs.takesOwnership = newValue
                        env.restartEngine()
                    }
                ))
                .font(AppFont.text(12))

                Text("关闭时，若 CLI 或旧版桌面端正在采集，本应用只读取同一份 ~/.ai-usage 数据，不抢占采集权。开启后会结束对方的采集进程并独自接管。")
                    .font(AppFont.text(10))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(env.engineStatusText)
                        .font(AppFont.text(11))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button("重新启动引擎") { env.restartEngine() }
                        .font(AppFont.text(11))
                }
                if case .failed(let reason) = env.engine.phase {
                    Text(reason)
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
                InfoRow(label: "数据目录", value: env.dataDir.path)
                InfoRow(label: "统计起点", value: store.syncStatus?.statsSince ?? "未知")
                InfoRow(label: "上次同步", value: store.lastSyncCaption)
                InfoRow(label: "引擎版本", value: env.engineVersion.isEmpty ? "未知" : env.engineVersion)
                InfoRow(label: "已采集天数", value: "\(store.heatmapDays.count) 天")
                InfoRow(label: "工具数量", value: "\(store.availableSources.count) 个")

                HStack {
                    Button("立即同步") {
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
            Text("本地采集").font(AppFont.text(12, weight: .semibold))
        }

        Text("所有用量数据都保存在本机，不会上传。")
            .font(AppFont.text(11))
            .foregroundStyle(Theme.muted)
    }

    // MARK: - 关于

    @ViewBuilder
    private var aboutTab: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "版本信息", value: "JusageMac \(appVersion)")
                InfoRow(label: "统计引擎", value: env.engineVersion.isEmpty ? "未知" : env.engineVersion)
                InfoRow(label: "系统", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("版本信息").font(AppFont.text(12, weight: .semibold))
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("支持的工具")
                    .font(AppFont.text(12, weight: .semibold))
                Text("同一系列的多端形态用括号标出。")
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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}

/// Standalone `关于` sheet reachable from the dashboard toolbar.
struct AboutView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("关于")
                    .font(AppFont.text(15, weight: .semibold))
                Spacer()
                Button("关闭关于") { dismiss() }
                    .font(AppFont.text(12))
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("版本信息")
                            .font(AppFont.text(12, weight: .semibold))
                        InfoRow(label: "客户端", value: appVersion)
                        InfoRow(label: "统计引擎", value: env.engineVersion.isEmpty ? "未知" : env.engineVersion)
                        InfoRow(label: "数据目录", value: env.dataDir.path)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("支持的工具")
                            .font(AppFont.text(12, weight: .semibold))
                        Text("同一系列的多端形态用括号标出。")
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

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(AppFont.text(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 76, alignment: .leading)
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
