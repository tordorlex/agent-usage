# JusageMac — 原生 SwiftUI 菜单栏应用

纯原生 macOS 客户端（SwiftUI + Liquid Glass），取代 `apps/desktop`（Electron）。
**没有主窗口**：整个界面是菜单栏图标弹出的面板；设置与关于是独立小窗口。

数据层不做任何改动：App 启动时拉起 `packages/engine`（Node 边车）作为统计引擎，通过
`127.0.0.1` 上的 localhost HTTP 消费与 CLI / Electron 完全相同的 `/functions/tud-*` 契约。

```
┌──────────────┐   spawn    ┌──────────────────────┐   HTTP    ┌──────────────────────┐
│ JusageMac.app│──────────▶│ node + packages/engine│──────────▶│ packages/core 运行时  │
│  (SwiftUI)   │◀──────────│  (stdout 握手 + 端口)  │           │  解析 / 聚合 / 定价    │
└──────────────┘  handshake └──────────────────────┘           └──────────┬───────────┘
                                                                          │
                                                              ~/.ai-usage（与 CLI 共享）
```

## 功能范围

只保留**用量统计**，并据此删除了掘金与桌面宠物相关的全部内容：

| 保留 | 删除 |
|------|------|
| 用量概览（预估费用 / 总 Token / 输入 / 输出 + 趋势 + 迷你折线） | 掘金登录、云端上报 / 同步 |
| 52 周活动热力图（点击某天筛选整个看板） | 排行榜、分享卡片、数据校准 |
| Token 用量趋势（全部 / 详细）、每日 Token 与费用趋势 | 桌面宠物（含 `~/.ai-usage/pets`） |
| 工具与模型用量、项目分布（横向堆叠条） | 自动更新 |
| 工具分布 / 模型分布（环形图，可隐藏单项） | 开机自启 |
| 菜单栏今日用量（`1.2M Token · $3.40`，三种显示方式） | 订阅额度卡片（需要抓取各厂商凭据） |
| 时间范围 今天 / 7D / 30D / 90D、渠道多选筛选、设置 / 关于 | |

引擎被强制 `juejin.enabled = false` 且 `PUT /functions/tud-config` 无法重新打开它，
因此这个 App **不会向任何服务器上报数据**；`~/.ai-usage` 之外的写入只有引擎自己的
`~/.config/jusage/device-id`。

## 构建

需要 macOS 26（Liquid Glass API 与部署目标都是 26.0）、Xcode 26、Node 20+。

```bash
# 仓库根：安装依赖并构建 Core + Engine
pnpm install
pnpm --filter @juejin-opensource/jusage-core build
pnpm --filter @juejin-opensource/jusage-engine build

# 直接跑（开发用；会在仓库里解析引擎脚本，使用 PATH 上的 node）
cd apps/macos && swift build && swift run

# 打出可双击的 .app（内嵌 node + 引擎，无需本机安装任何东西）
pnpm build:macos:app          # 等价于 apps/macos/scripts/bundle.sh
```

产物：`apps/macos/dist/JusageMac.app`（约 123 MB，其中大部分是内嵌的 node）。

> 沙箱 / CI 中构建 Swift 时，若 `~/Library/Caches/org.swift.swiftpm` 不可写，
> 需要把缓存指到仓库内并关闭 SwiftPM 自己的 sandbox：
> `swift build --disable-sandbox --scratch-path .build --cache-path .swiftpm/cache --config-path .swiftpm/config --security-path .swiftpm/security`
> （`bundle.sh` 已经这么做）。

## 运行与数据

| 项 | 值 |
|----|----|
| 数据目录 | `~/.ai-usage`（与 CLI 相同；可用 `JUSAGE_DATA_DIR` 覆盖） |
| 设备 ID 边车 | `~/.config/jusage/device-id`（可用 `JUSAGE_CONFIG_HOME` 覆盖） |
| 引擎脚本 | 打包版：`JusageMac.app/Contents/Resources/JusageEngine/dist/index.js`；开发版：`packages/engine/dist/index.js` |
| node | 打包版：`Contents/Resources/JusageEngine/node`；开发版：`PATH` 上的 node，找不到时回退到登录 shell |
| 覆盖项 | `JUSAGE_NODE_BIN`、`JUSAGE_ENGINE_SCRIPT`、`JUSAGE_REPO_ROOT` |

### 采集权（`tud.pid`）

同一时刻只有一个进程做采集。默认**不抢占**：

- 没有其他 runtime 运行时，引擎正常成为 owner 并采集；
- CLI（`jusage start`）或旧版 Electron 桌面端正在采集时，引擎以 observer 身份加入，
  只读取同一份 `~/.ai-usage` 队列，**不会**杀掉对方。

需要在设置里打开「接管本地同步（结束其他采集进程）」才会带 `--take-owner` 启动，
结束对方的采集进程并独占。等 Electron 版彻底移除后，这个开关就是唯一采集者，
也可以把默认值改成开启（`AppPreferences.takesOwnership`）。

## 代码结构

```
apps/macos/
├── Package.swift                     # macOS 26 / SwiftPM 可执行目标
├── scripts/bundle.sh                 # 组装 .app（deploy 引擎 + 内嵌 node + ad-hoc 签名）
└── Sources/JusageMac/
    ├── JusageMacApp.swift            # @main：MenuBarExtra + 设置/关于窗口 + AppDelegate
    ├── App/AppEnvironment.swift       # 单例环境：引擎 ⇄ store 的接线、退出清理
    ├── Engine/
    │   ├── EngineController.swift     # 拉起/守护 node 边车、解析 stdout 握手、崩溃重启
    │   └── EngineLocator.swift        # 定位 node 与引擎脚本（打包 / 开发两种布局）
    ├── API/
    │   ├── APIModels.swift            # `/functions/tud-*` 响应的 Codable 映射
    │   └── LocalAPIClient.swift       # actor：并发请求 + 信封解包
    ├── Store/
    │   ├── UsageStore.swift           # 取数、轮询、范围/渠道筛选、全部派生统计
    │   ├── AppPreferences.swift       # UserDefaults 偏好（范围、主题、菜单栏、采集权）
    │   └── StatsClock.swift           # Asia/Shanghai 的日期/小时/窗口计算
    ├── Design/DesignSystem.swift      # 色板、37 个工具的标签与配色、数字格式化、玻璃卡片
    └── Features/
        ├── DashboardView.swift        # 面板：顶部工具栏 + 单列滚动内容
        ├── OverviewSection.swift      # 四张指标卡 + 52 周热力图
        ├── TrendCards.swift           # Token 趋势 / 每日 Token 与费用趋势（Swift Charts）
        ├── BreakdownCards.swift       # 堆叠条与环形分布
        └── SettingsView.swift         # 设置 / 关于窗口
```

### 与 Electron 版的一致之处

聚合口径完全沿用渲染层（`apps/desktop/src/renderer/lib/*`），以便两版数字对得上：

- 指标卡是**区间**口径（由区间内的每日行汇总），不是全量 `tud-usage-summary`；
- 趋势箭头是**相邻两天**比较（`buildMetricChanges`）；
- 「输入 Token」的缓存命中率 = 缓存读 ÷（输入 + 缓存读 + 缓存写）；
- 渠道筛选按当日 `models`（键为 `source\u{1f}model`）算出占比，再**按比例缩放**当日行，
  与 `usage-filter.ts` 的做法一致；选中的渠道在数据里消失时会自动剔除；
- 工具/模型的别名归一化（`claude-desktop → claude`、`deepseek-* → dsh`、
  `qwenwork` 先于 `qwen`、`pi` 先于 `kimi`、`kilo-cli` 先于 `kilocode`）逐条照搬；
- 数字单位是 T/B/M/K（不是万/亿），费用 `$x.xx`，百分比一位小数。

### Liquid Glass

- 卡片：`.glassEffect(.regular, in: .rect(cornerRadius:))`（`CardSurface` / `InnerGlassSurface`）；
- 指标卡外层套 `GlassEffectContainer`，让相邻玻璃块成组混合；
- 工具栏按钮：`.buttonStyle(.glass)`；分段控件与渠道菜单是胶囊玻璃；
- 状态提示按语义 `tint` 玻璃。

主题（跟随系统 / 浅色 / 深色）通过 `preferredColorScheme` 应用；数字用等宽字体并开启
`monospacedDigit`，避免数值跳动时抖动。

## 布局陷阱（已踩过，别再踩）

面板固定 **452×660**，内容套在竖向 `ScrollView` 里。SwiftUI 的 `ScrollView` 会把
**内容沿滚动轴的理想尺寸**当作自己的理想尺寸上报给父级：

- 只要某张卡片里有横向 `ScrollView`（或任何忽略父级建议宽度的元素），面板那一列就会被
  撑到内容宽度——热力图当时是 52 周 × 16pt ≈ 900pt，整列变成 922pt；
- 外层 `.frame(width: 452)` 对超宽内容默认**居中**，于是左右各裁掉约 235pt：
  四张指标卡只剩右列可见、热力图月份标签重叠、下方卡片整体移出屏幕。

因此**面板宽度内的内容一律不得依赖横向滚动**。热力图已改成「按可用宽度决定显示多少周，
绝不超出」：`GeometryReader` 只取宽度并显式给高度，月份标签用 `.offset` + `.fixedSize()`
定位，不参与布局计算。

排查手段（无窗口应用无法截图时）：

```bash
# 1) 把内容渲染进真实 NSWindow，遍历 AppKit 视图树找越界。
#    任何 frame.maxX > 内容宽度的视图就是元凶——当初就是这样定位到 922pt 的。
# 2) 用 Vision OCR 读回文字与坐标，确认内容渲染到了哪里：
swiftc -O -o /tmp/ocr apps/macos/scripts/ocr.swift && /tmp/ocr <screenshot.png>
```

注意 `ImageRenderer` 离屏渲染**画不出** Liquid Glass，只会得到全透明图；
`cacheDisplay(in:to:)` 也抓不到玻璃背景层（实测约 92% 像素透明）。
判断布局要用视图树尺寸，判断文字要用 OCR。

### Swift Charts（三个已踩的坑）

1. **整数 x 轴的刻度标签读不出来**：用整数下标作 x 时，Charts 把它当连续轴，回传的 mark
   值是 `Double`，`value.as(Int.self)` 永远失败 → **X 轴一个标签都不画**（图表看起来「显示不全」）。
   要读 `value.as(Double.self)` 再四舍五入成下标。
2. **`BarMark` 必须显式给宽度**：否则打印 *"Falling back to a fixed dimension size for a mark"*，
   并在 30 / 90 个桶时让柱子互相重叠。用 `width: .ratio(0.72)`。
3. **内置图例会被丢掉**：绘图区高度不够时（如 132pt）`chartLegend(position: .bottom)` 直接不渲染，
   多序列图就没有图例。改为 `.chartLegend(.hidden)` + 自绘 `ChartLegendRow`。

改动后用真实窗口 + OCR 跑一遍，确认刻度标签和图例文字都能读出来。

## 数据路径的验证方式

界面是无窗口的菜单栏面板，自动化验证走两条路：

1. **引擎契约**：`bash packages/engine/scripts/smoke.sh`（全新数据目录 + `--no-hooks`，
   自带 stdout 握手、各端点 JSON、SIGTERM 清理与孤儿进程检查）。
2. **面板与统计**：用同样的源码编译一个临时宿主（`swiftc` 编译除 `JusageMacApp.swift`
   之外的全部源码 + 一个自带 `@main` 的文件），把 `DashboardPanel` 放进真实 `NSWindow`，
   再用 `swiftc` 编译的 OCR 工具读回文字坐标（见上一节）。真实窗口服务器才会合成玻璃。
