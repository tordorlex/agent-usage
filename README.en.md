<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/logo-dark.png">
    <img src="./assets/logo-light.png" alt="Meter" width="140">
  </picture>
</p>

<h1 align="center">Meter</h1>

<p align="center">
  <b>AI coding usage dashboard that lives in the macOS menu bar</b><br>
  Native SwiftUI (macOS 26 · Liquid Glass) · parses logs locally · uploads nothing
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/SwiftUI-native-F05138?style=flat-square&logo=swift&logoColor=white" alt="SwiftUI">
  <img src="https://img.shields.io/badge/version-0.1.13-2ea44f?style=flat-square" alt="0.1.13">
  <img src="https://img.shields.io/badge/license-MIT-3b82f6?style=flat-square" alt="MIT">
</p>

<p align="center">
  <a href="https://github.com/tordorlex/agent-usage/releases">Download</a> ·
  <a href="#-interface">Screenshots</a> ·
  <a href="#-features">Features</a> ·
  <a href="#-quick-start">Quick start</a> ·
  <a href="./FAQ.md">FAQ (中文)</a> ·
  <a href="#-relationship-to-upstream">Relationship to upstream</a> ·
  <a href="./README.md">中文</a>
</p>

<p align="center">
  <img src="./assets/screenshots/panel-overview.png" alt="Meter panel: metric cards and a 52-week activity heatmap" width="440"><br>
  <sub>Usage panel: four metric cards plus a 52-week activity heatmap — <b>click a day to filter the whole dashboard to it</b></sub>
</p>

## 🎯 What Meter is

Meter is an **AI coding usage dashboard that runs in the macOS menu bar**. It reads the logs the
various agents and coding tools on your machine already leave behind (Claude Code, Codex, Cursor,
Gemini CLI … 37 in total), computes token usage and estimated cost with one consistent set of rules,
and renders them in a native SwiftUI panel — no account, no sign-in, no upload.

| | |
|---|---|
| **Native client** | SwiftUI + Liquid Glass, not a wrapped web page; no main window, the whole UI is the panel that drops from the menu-bar icon |
| **Local first** | Every parse and aggregation happens on this machine; data lives in `~/.ai-usage` |
| **Never uploads** | Cloud reporting is force-disabled inside the engine (`juejin.enabled = false`) and the config route cannot turn it back on |
| **Consistent numbers** | Shares the same data and the same aggregation rules as the CLI / Electron clients in this repo, so the figures line up |
| **Always visible** | The menu bar shows today's usage directly (`1.2M Token · $3.40`), with three display modes |
| **Bilingual** | Chinese and English, chosen from the macOS language by default and pinned in Settings if you prefer |

## 🖼️ Interface

From top to bottom the panel shows: the usage overview (four metric cards plus the 52-week activity
heatmap, pictured above), the trend charts, the project / tool / model breakdowns, and finally the
sync status bar. Each section follows in order.

### Trend charts

<p align="center">
  <img src="./assets/screenshots/panel-trends.png" alt="Token usage trend and daily token / cost trend" width="430">
</p>

Drawn with Swift Charts: a **total token usage trend** (switchable between “All” and “Detail”) and a
**daily token and cost trend**. The Y axis picks its unit from T / B / M / K automatically, and
switching the time range recomputes immediately.

### Project / tool / model breakdowns

<p align="center">
  <img src="./assets/screenshots/panel-breakdown.png" alt="Project, tool and model breakdowns" width="430">
</p>

Three views onto where the usage went: **project breakdown** (by working directory, shown locally
only), **tool breakdown** and **model breakdown**. The stacked bars and the donuts both switch
between tokens and cost, and the donut lets you hide individual slices.

### Settings and About

<table>
  <tr>
    <td align="center"><img src="./assets/screenshots/settings-app.png" alt="Settings · App" width="360"></td>
    <td align="center"><img src="./assets/screenshots/settings-device.png" alt="Settings · Device" width="360"></td>
  </tr>
  <tr>
    <td align="center"><sub>Settings · menu-bar display, default range, theme, engine</sub></td>
    <td align="center"><sub>Settings · data directory, collection start, last sync, engine status</sub></td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><img src="./assets/screenshots/about.png" alt="About Meter" width="330"></td>
    <td align="center"><img src="./assets/screenshots/menu.png" alt="Menu-bar context menu" width="170"></td>
  </tr>
  <tr>
    <td align="center"><sub>About: client version, statistics engine, supported tools</sub></td>
    <td align="center"><sub>Right-click menu: sync / theme / settings / quit</sub></td>
  </tr>
</table>

<sub>Screenshots were taken with the UI in Chinese.</sub>

## ✨ Features

| Capability | Description |
|---|---|
| Usage overview | Estimated cost, total tokens, input / output tokens, with cache hit rate and day-over-day change |
| Activity heatmap | 52 weeks of daily usage; click a day to filter the whole dashboard to it |
| Trend charts | Total token usage trend (all / detail), daily token and cost trend |
| Breakdowns | Tool and model usage (stacked bars), project breakdown, tool / model breakdown (donuts) |
| Filtering | Today / 7D / 30D / 90D time ranges; multi-select channel filter (scales a day's figures by share) |
| Menu bar | Today's usage always on display — “tokens & cost / tokens only / cost only”, or icon only |
| Appearance | Follow system / light / dark |
| Language | Follows the macOS language (简体中文 / English) out of the box, or pin one in Settings |
| Collection rights | Read-only on the shared `~/.ai-usage` by default; one switch takes over and stops other collectors |
| Data | Data directory, collection start, last sync, engine version and days collected at a glance, plus a manual sync |

What it deliberately **does not** do (the biggest difference from the upstream desktop client):

| Not included | Why |
|---|---|
| Juejin sign-in / cloud reporting / leaderboard / sharing | Local statistics only; the upload path is force-disabled in the engine |
| Desktop pets | Unrelated to usage statistics |
| Auto-update / launch at login | Keeps it a small tool you open and use, with no background service |
| Subscription quota cards | Would require scraping each vendor's credentials, outside the local-first scope |

## 🔧 How it works

The app parses no logs itself: at launch it spawns a headless Node sidecar (`packages/engine`) as
the statistics engine, the two shake hands over stdout to learn the port, and from then on
everything goes over localhost HTTP against the same `/functions/tud-*` contract.

```
┌──────────────┐   spawn    ┌──────────────────────┐   HTTP     ┌──────────────────────┐
│  Meter.app   │───────────▶│node + packages/engine│            │ packages/core runtime│
│  (SwiftUI)   │◀───────────│(stdout handshake)    │            │ parse / aggregate /  │
└──────────────┘  handshake └──────────────────────┘            │ price                │
                                                                └──────────┬───────────┘
                                                                           │
                                                               ~/.ai-usage (shared with the CLI)
```

- A crashed engine is restarted automatically, and Settings offers a manual “Restart engine”;
- The packaged build ships the Node runtime and the engine inside the `.app` (about 123 MB, most of
  it Node), so nothing has to be installed on the user's machine;
- The data layer is untouched, so the CLI, the legacy Electron client and Meter all see the same
  data through the same rules.

## 🚀 Quick start

### Download

Grab `Meter-<version>.dmg` from [Releases](https://github.com/tordorlex/agent-usage/releases) and
drag it into Applications.

> The app is ad-hoc signed and not notarized. If the first launch says it is damaged, run
> `sudo xattr -dr com.apple.quarantine /Applications/Meter.app` in a terminal, or right-click and
> choose “Open”.

### Build from source

Requires **macOS 26 + Xcode 26** (the Liquid Glass APIs and the deployment target are both 26.0) and
Node.js 20+.

```bash
pnpm install

# Run in development (resolves the engine inside the repo, uses node from PATH)
pnpm dev:macos

# Build a double-clickable .app (embeds Node and the engine)
pnpm build:macos:app        # → apps/macos/dist/Meter.app

# Build a distributable .dmg
pnpm build:macos:dmg        # → apps/macos/dist/Meter-<version>.dmg
```

### Command line (optional, same data)

The repo also keeps the upstream CLI and its local dashboard, sharing `~/.ai-usage` with Meter:

```bash
npm i -g @juejin-opensource/jusage
jusage service start
# dashboard: http://127.0.0.1:8452
```

The full command and option reference is in [CLI 使用说明](./CLI.md) (Chinese).

## 🔒 Data and privacy

Meter only does local statistics. Every usage detail, model name, source channel and project path is
written on this machine alone.

| Item | Location |
|---|---|
| Data directory | `~/.ai-usage` (override with `JUSAGE_DATA_DIR`) |
| Logs | `~/.ai-usage/logs/` |
| Device ID | `~/.config/jusage/device-id` |
| Pricing overlay | `~/.ai-usage/pricing-overlay.json` |

- 🚫 **Not collected, not uploaded**: conversation contents, prompt text, code and API keys — the
  parser extracts token counts, model names and usage metadata only, and all of it stays local;
- 🚫 **No uploads**: cloud reporting is force-disabled in the engine, and `PUT /functions/tud-config`
  cannot re-enable it;
- 🌐 **The only outbound request**: one fetch of the public model pricing table at startup
  (`https://api.juejin.cn/aiusage_api/functions/tud-pricing`, no polling). If it fails, the previous
  copy on disk is used, then the built-in table — statistics are unaffected either way;
- 🔁 **Collection rights**: exactly one process collects at a time, coordinated through
  `~/.ai-usage/tud.pid`. Meter does **not** seize it by default — while the CLI or the Electron app
  is collecting, Meter reads the same data as an observer. Turn on “Take over local sync” in Settings
  when you want it to be the only collector;
- 🎛️ **Clear anytime**: delete `~/.ai-usage` to wipe every local record.

## 🧰 Supported tools

37 in total; different surfaces of the same family collapse into one row:

<sub>Cursor · Claude · Codex · Trae · Qoder · OpenCode · Copilot · Gemini · Antigravity · Kimi ·
Qwen Code · DeepSeek Harness · Grok Build · ZCode · OpenClaw · AutoClaw · Hermes · Roo Code ·
Kilo Code · Kilo CLI · Cline · Goose · Zed · Warp · Droid · Kiro · Amp · Mimo · CodeBuddy ·
WorkBuddy · pi · OMP · Every Code · QwenWork · Command Code · MiniMax Code · WPS Comate</sub>

## 🧱 Repository layout

| Path | Responsibility |
|---|---|
| `apps/macos` | **Meter itself**: the native SwiftUI menu-bar client (macOS 26 + Liquid Glass) |
| `packages/engine` | Headless Node sidecar: hands the core runtime to a native host over localhost HTTP plus a stdout handshake |
| `packages/core` | Per-agent log parsing, the usage queue, the aggregation cache, pricing and the local-api contract |
| `packages/cli` | `jusage`: HTTP service plus the hosted dashboard |
| `packages/dashboard` | The dashboard the CLI embeds (the same one served at `/aiusage/`) |
| `apps/desktop` | The upstream Electron client (to be removed) |

Build steps, code structure and the gotchas of the native app are in
[apps/macos/README.md](./apps/macos/README.md) (Chinese).

## 🙏 Relationship to upstream

This repository, [agent-usage](https://github.com/tordorlex/agent-usage), is a derivative of
**[稀土掘金 · juejin-cn/juejin-usage](https://github.com/juejin-cn/juejin-usage)**: the log parsing,
the aggregation rules, the pricing table and the `/functions/tud-*` contract all come from the
original project, and this repository adds a native macOS client on top.

**Heartfelt thanks** to the [juejin-cn](https://github.com/juejin-cn) team and to
[every upstream contributor](https://github.com/juejin-cn/juejin-usage/graphs/contributors) — without
the original project there would be no repository here. Upstream is MIT licensed (Copyright (c) 2026
juejin-cn) and this repository keeps the same license.

Upstream links: [repository](https://github.com/juejin-cn/juejin-usage) ·
[Releases](https://github.com/juejin-cn/juejin-usage/releases) ·
[Issues](https://github.com/juejin-cn/juejin-usage/issues)

## 🤝 Contributing

Branch conventions, local setup and how to run the tests are in the
[Contributing Guide](./CONTRIBUTING.md) (Chinese). Make sure `pnpm build` and `pnpm test` pass before
you open a pull request.

- Contact the Captain: 229199157

## 📚 Related projects

- [Token Tracker](https://github.com/xiufengsun/TokenTracker): automatically collects token usage from 30 AI coding tools and shows real cost and trends in a polished dashboard
- [vibe-usage](https://github.com/vibe-cafe/vibe-usage): a CLI token usage tracker
- [OpenUsage](https://github.com/robinebers/openusage): The Only AI Usage Tracker That's Truly Yours
- [models.dev](https://models.dev): the model pricing data source the built-in table is synced from

## 📄 License

[MIT](./LICENSE)
