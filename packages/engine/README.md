# @juejin-opensource/jusage-engine

把 `@juejin-opensource/jusage-core` 的运行时（同步循环、定价、聚合缓存、local-api）
包装成一个**无界面边车进程**，给原生宿主使用。目前唯一的宿主是
[`apps/macos`](../../apps/macos)（SwiftUI 菜单栏应用），它取代了原来的 Electron 主进程。

Electron 版在进程内直接调 core，并用 IPC 把 `/functions/tud-*` 递给渲染层；
这里换成 **localhost HTTP + stdout 握手**，因为 Swift 侧无法共享 Node 的对象。

## 用法

```bash
node packages/engine/dist/index.js --data-dir ~/.ai-usage --host 127.0.0.1 --port 0
```

| 参数 | 说明 |
|------|------|
| `--data-dir <dir>` | 数据目录，默认 `~/.ai-usage` |
| `--host <host>` | 监听地址，默认 `127.0.0.1`（回环） |
| `--port <n>` | 默认 `0`，由系统分配；实际端口见 stdout 握手 |
| `--take-owner` | 强制接管 `tud.pid`，结束当前采集者（CLI / Electron） |
| `--no-hooks` | 不注册 Claude / Codex Hook |
| `--parent-pid <pid>` | 父进程消失时自动退出（宿主未使用管道 stdin 时） |

## 传输契约（冻结，宿主按此解析）

- **stdout 只输出一行**：启动成功后是握手 JSON，启动失败则是 `engine-error` 并退出非零。

  ```json
  {"type":"engine-ready","host":"127.0.0.1","port":64786,"pid":43713,"dataDir":"/Users/me/.ai-usage","version":"0.1.13"}
  {"type":"engine-error","message":"EPERM: ..."}
  ```

- 其余日志一律走 **stderr**，保证 stdout 可被逐行解析。
- stdin 是管道时，读到 EOF 视为宿主已退出 → 自行关闭；否则用 `--parent-pid` 轮询。
- `SIGINT` / `SIGTERM`：停轮询、停信号监听、停定价刷新、关 HTTP、释放 `tud.pid`、
  清心跳，然后退出 0。

## 端点

即 core 的 `local-api`，响应信封统一为 `{ success, message, data }`：

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/health` | `{"ok":true}`（无信封），宿主用来判断就绪 |
| GET | `/functions/tud-usage-summary` | 全量 + 今日汇总，按来源/模型分组 |
| GET | `/functions/tud-usage-daily?days=` | 每日用量（默认 90，clamp 1…365） |
| GET | `/functions/tud-usage-hourly?days=` | 按（日期, 小时, 来源）的用量（默认 1） |
| GET | `/functions/tud-usage-model-breakdown?days=` | 模型 + 项目明细（默认 30） |
| GET | `/functions/tud-sync-status` | 各来源同步状态、上次同步时间 |
| GET | `/functions/tud-config` | 采集起点等本地字段 |
| POST | `/functions/tud-trigger-sync` | 立即同步一轮 |
| POST | `/functions/tud-ensure-local-range` | 扩宽本地采集窗口（`days ∈ {1,7,30,90}`），必要时重扫 |

`local-api` 里掘金相关的路由（`tud-leaderboard*`、`tud-calibrate-*`）即使存在也无人调用。

## 强制关闭云端上报

宿主的产品定位是「只有用量统计」，所以引擎在**任何同步发生之前**就把
`config.juejin.enabled` 置为 `false`：

- `maybeUploadAfterSync` / `uploadToServer` 都会在 `!config.juejin.enabled` 时提前返回
  （见 `packages/core/src/upload/client.ts`），因此不会有任何上传、也不会写 `upload.state.json`；
- 注入给同步内部（`createSyncRunner`）的 `loadConfig` 是包装后的
  `loadSanitizedConfig`，因为 runner 会自己读配置并把它直接交给上报函数，只改内存里的那一份
  是不够的；
- `PUT /functions/tud-config` 若试图把 `juejin.enabled` 改回 `true`，会被拒绝并记日志。

磁盘上的 `config.json` 仍保留用户原本的掘金字段（引擎只在内存里覆盖），所以 CLI 的行为不变。
注意：`POST /functions/tud-ensure-local-range` 会 `saveConfig` 一次内存里的配置，
在那条路径上会把 `juejin.enabled=false` 落到磁盘——CLI 之后就不会再上报了。如果不想影响 CLI，
就不要从原生 App 触发扩宽（或先把 CLI 换成只读用法）。

## 与 CLI 的关系

| | CLI `jusage start` | Engine |
|--|--|--|
| 数据目录 | `~/.ai-usage` | 同左 |
| 读数方式 | HTTP `:8452` + 内置面板 | localhost HTTP（随机端口，无静资源） |
| 采集权 | `tud.pid` owner | 默认 observer，`--take-owner` 才抢占 |
| 云端上报 | 配置开启时上报 | 恒不上报 |

## 验证

```bash
bash packages/engine/scripts/smoke.sh
```

脚本在 `packages/engine/.tmp-data*`（已 gitignore）里跑一个全新数据目录，**不碰**
真实的 `~/.ai-usage` / `~/.claude` / `~/.codex`，并检查：握手行、各端点 200 与信封、
`--parent-pid`、SIGTERM 清理、心跳与 `tud.pid` 释放、无孤儿进程。
