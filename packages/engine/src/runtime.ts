/**
 * Headless port of `apps/desktop/src/main/local-runtime.ts`.
 *
 * The Electron main process owned `loadConfig` + `BucketStore` + `AggregateCache`
 * + `watchRuntimeSignals` + the poll loop and served core's local-api over IPC.
 * This module keeps that lifecycle verbatim (minus the Electron-only pieces) so
 * the same core runtime can be served over plain localhost HTTP to the SwiftUI
 * app. No parser / aggregation logic lives here — it is only wiring.
 *
 * Deliberately NOT ported from the Electron runtime (documented on purpose):
 *   - the utilityProcess sync worker (`sync-worker-host.ts`): a sidecar process
 *     has no UI event loop to protect, so sync runs in-process like the CLI;
 *   - the pet / renderer notification bus and the foreground-poke debounce:
 *     the host app calls `POST /functions/tud-trigger-sync` instead;
 *   - `evictCliAutostart()` + `evictRuntimeKind('cli')`: the engine never kills
 *     unrelated `jusage` processes; ownership, not eviction, is how it takes over.
 */
import {
  appendJsonLog,
  BucketStore,
  claimRuntimeOwner,
  clearRuntimeHeartbeat,
  createAggregateCache,
  createApplyAfterSync,
  createLocalApiApp,
  createPollBackoff,
  DEFAULT_PRICING_FIRST_FETCH_TIMEOUT_MS,
  getHookStatus,
  getRunningOwner,
  HEARTBEAT_INTERVAL_MS,
  loadConfig,
  measureCpuPhase,
  POLL_INTERVAL_MS,
  releaseRuntimeOwner,
  resolveLocalCollectSince,
  resolvePricingRefreshConfig,
  setupClaudeHook,
  setupCodexHook,
  startPricingRefresh,
  syncLogPath,
  touchRuntimeHeartbeat,
  touchStatsSince,
  watchRuntimeSignals,
  type AggregateCache,
  type LoadConfigResult,
  type LocalApiDeps,
  type SyncResult,
  type TudConfig,
} from '@juejin-opensource/jusage-core';

/** The local-api Hono app type, derived from core so this package needs no `hono` dep. */
type LocalApiApp = ReturnType<typeof createLocalApiApp>;

export interface EngineRuntimeLogger {
  info(message: string): void;
  warn(message: string): void;
}

export interface StartEngineRuntimeOptions {
  /** Absolute data dir. Defaults to core's `DEFAULT_DATA_DIR` when omitted. */
  dataDir?: string;
  /** `--take-owner`: force-claim `tud.pid`, stopping the previous sync owner. */
  takeOwner: boolean;
  /** Register the Claude / Codex notify hooks (skipped with `--no-hooks`). */
  hooks: boolean;
  logger: EngineRuntimeLogger;
}

export interface EngineRuntimeHandle {
  /** Absolute data dir the runtime actually uses. */
  dataDir: string;
  /** local-api app to hand to `createHttpServer`. */
  app: LocalApiApp;
}

interface RuntimeState {
  dir: string;
  config: TudConfig;
  bucketStore: BucketStore;
  aggregateCache: AggregateCache;
  app: LocalApiApp;
  role: 'owner';
}

/** Path of the config write endpoint that must never be able to enable upload. */
const CONFIG_FUNCTION_PATH = '/functions/tud-config';

let runtime: RuntimeState | null = null;
let logger: EngineRuntimeLogger = { info: () => {}, warn: () => {} };
let pollTimer: ReturnType<typeof setTimeout> | null = null;
let syncWatcherStop: (() => void) | null = null;
let pricingRefreshStop: (() => void) | null = null;
let heartbeatTimer: ReturnType<typeof setTimeout> | null = null;
let ownedPid = false;
/** Data dir whose `tud.pid` this process owns (kept even if a later boot step throws). */
let ownedDataDir: string | null = null;
let runSyncFn:
  | ((reason: string, source?: string) => Promise<SyncResult[]>)
  | null = null;
const pollBackoff = createPollBackoff();
/** Re-arm the poll timer at the backoff's current delay (owner only). */
let reArmPoll: ((delayMs?: number) => void) | null = null;
let stopping = false;
let startInFlight: Promise<EngineRuntimeHandle> | null = null;

/**
 * UPLOAD IS DISABLED IN ENGINE MODE.
 *
 * `maybeUploadAfterSync` / `uploadToServer` early-return while
 * `config.juejin.enabled` is false (see `packages/core/src/upload/client.ts`),
 * so this single mutation is what keeps the engine from ever reporting usage to
 * the cloud. It runs on every config object core gives us, because core
 * re-reads config from disk in several paths and then hands *that* object to the
 * upload helpers:
 *   - `createSyncRunner` calls the injected `loadConfig` itself and passes the
 *     result to `maybeUploadAfterSync` → hence `loadSanitizedConfig` below;
 *   - `deps.getConfig()` is used by local-api handlers (summary/config/ensure)
 *     → hence `readConfigForApi`;
 *   - `PUT /functions/tud-config` could otherwise stage `juejin.enabled = true`
 *     from the host app → hence the HTTP guard in `createEngineApiApp`.
 */
function disableUpload(config: TudConfig): TudConfig {
  config.juejin.enabled = false;
  return config;
}

/** Upload-disabled view of the live config handed to local-api. */
function readConfigForApi(): TudConfig {
  const config = runtime?.config;
  if (!config) throw new Error('engine runtime is not started');
  return { ...config, juejin: { ...config.juejin, enabled: false } };
}

/** Store the live config with upload still disabled. */
function setRuntimeConfig(next: TudConfig): void {
  if (!runtime) return;
  runtime.config = { ...next, juejin: { ...next.juejin, enabled: false } };
}

/** `loadConfig` for sync internals, upload-disabled before the caller sees it. */
async function loadSanitizedConfig(dataDir?: string): Promise<LoadConfigResult> {
  const result = await loadConfig(dataDir);
  disableUpload(result.config);
  return result;
}

function isConfigWriteRequest(request: Request): boolean {
  const method = request.method.toUpperCase();
  if (method !== 'PUT' && method !== 'POST' && method !== 'PATCH') return false;
  try {
    return new URL(request.url, 'http://localhost').pathname === CONFIG_FUNCTION_PATH;
  } catch {
    return false;
  }
}

/** True when the JSON body asks the engine to turn Juejin upload back on. */
async function requestsUploadEnabled(request: Request): Promise<boolean> {
  try {
    const body = (await request.clone().json()) as {
      juejin?: { enabled?: unknown };
    } | null;
    return body?.juejin?.enabled === true;
  } catch {
    // Unparsable body: let local-api answer with its own INVALID_JSON.
    return false;
  }
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

/**
 * local-api plus the one guard the engine needs: `juejin.enabled: true` is
 * rejected before the handler can stage it, persist it, or trigger its
 * "remote changed → auto upload" branch. Reads (`GET`) stay untouched.
 */
function createEngineApiApp(deps: LocalApiDeps): LocalApiApp {
  const inner = createLocalApiApp(deps);
  const guarded = {
    async fetch(request: Request): Promise<Response> {
      if (isConfigWriteRequest(request) && (await requestsUploadEnabled(request))) {
        logger.warn(
          'rejected config update: 云端上报在本引擎中被强制关闭（juejin.enabled=false）',
        );
        return jsonResponse(
          { success: false, message: 'UPLOAD_DISABLED', data: null },
          403,
        );
      }
      return inner.fetch(request);
    },
  };
  // core's createHttpServer only ever calls `honoApp.fetch(request)`; the cast
  // keeps this package free of a direct `hono` dependency.
  return guarded as unknown as LocalApiApp;
}

async function startPricingOverlayRefresh(
  dir: string,
  config: TudConfig,
): Promise<void> {
  pricingRefreshStop?.();
  pricingRefreshStop = null;
  const { url } = resolvePricingRefreshConfig({
    url: config.pricing?.url,
    ttlMs: config.pricing?.ttlMs,
  });
  if (!url) return;
  const handle = startPricingRefresh({
    url,
    dataDir: dir,
    firstFetchTimeoutMs: DEFAULT_PRICING_FIRST_FETCH_TIMEOUT_MS,
    onUpdate: () => {
      const current = runtime;
      if (!current) return;
      void measureCpuPhase(
        syncLogPath(dir),
        'pricing_rebuild',
        { role: 'engine' },
        () => current.aggregateCache.rebuildFromRows(current.bucketStore.getRows()),
      ).catch((err) => {
        logger.warn(
          `pricing overlay cache rebuild failed: ${err instanceof Error ? err.message : err}`,
        );
      });
    },
    onError: (err) => {
      logger.warn(
        `pricing overlay refresh failed: ${err instanceof Error ? err.message : err}`,
      );
    },
  });
  pricingRefreshStop = handle;
  logger.info(`pricing overlay: ${url} (startup fetch)`);
  await handle.ready;
}

async function refreshRuntimeFromDisk(): Promise<void> {
  const current = runtime;
  if (!current) return;
  try {
    const { config } = await loadSanitizedConfig(current.dir);
    current.config = config;
    await current.bucketStore.refresh(
      current.dir,
      resolveLocalCollectSince(config),
    );
    await current.aggregateCache.rebuildFromRows(current.bucketStore.getRows());
    await appendJsonLog(syncLogPath(current.dir), {
      event: 'bucket_refresh',
      statsSince: config.statsSince,
      localCollectSince: resolveLocalCollectSince(config),
      lastSyncAt: config.lastSyncAt,
    });
  } catch (err) {
    await appendJsonLog(syncLogPath(current.dir), {
      event: 'bucket_refresh_error',
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

/** Snap the idle backoff to the fastest interval and re-arm a slowed-down poll timer. */
function resetPollBackoffToFast(): void {
  const wasSlow = pollBackoff.currentDelayMs() > POLL_INTERVAL_MS;
  pollBackoff.reset();
  if (wasSlow) reArmPoll?.();
}

function buildApp(state: {
  dir: string;
  getConfig: () => TudConfig;
  bucketStore: BucketStore;
  aggregateCache: AggregateCache;
  runSyncViaRunner?: (reason: string, source?: string) => Promise<SyncResult[]>;
}): LocalApiApp {
  return createEngineApiApp({
    dataDir: state.dir,
    getConfig: state.getConfig,
    bucketStore: state.bucketStore,
    aggregateCache: state.aggregateCache,
    runSyncViaRunner: state.runSyncViaRunner,
    getHookStatus: () => getHookStatus(state.dir),
    onConfigChange: (next) => {
      setRuntimeConfig(next);
    },
  });
}

/** Start the core runtime and hand back the local-api app. Idempotent. */
export async function startEngineRuntime(
  opts: StartEngineRuntimeOptions,
): Promise<EngineRuntimeHandle> {
  if (runtime) return { dataDir: runtime.dir, app: runtime.app };
  if (startInFlight) return startInFlight;
  logger = opts.logger;
  stopping = false;
  startInFlight = startEngineRuntimeUnlocked(opts).finally(() => {
    startInFlight = null;
  });
  return startInFlight;
}

async function startEngineRuntimeUnlocked(
  opts: StartEngineRuntimeOptions,
): Promise<EngineRuntimeHandle> {
  // `loadConfig` also recovers a corrupt config.json (backup + salvage) and
  // creates the data dir / queue / bin / logs subdirs on first run.
  const loaded = await loadConfig(opts.dataDir);
  const dir = loaded.dir;
  // Force-disable cloud upload BEFORE anything can sync (see `disableUpload`).
  const config = disableUpload(loaded.config);
  if (loaded.recoveredFromCorrupt) {
    logger.warn(
      `config.json 已损坏，已备份到 ${loaded.recoveredFromCorrupt.backupPath} 并重建`,
    );
  }

  await touchStatsSince(dir, config);

  // Single sync owner, exactly like the Electron app: `kind: 'desktop'` keeps
  // an already-running `jusage` CLI from syncing/uploading at the same time.
  const claim = await claimRuntimeOwner(dir, {
    kind: 'desktop',
    force: opts.takeOwner,
  });
  if (claim.role !== 'owner') {
    throw new Error(
      `本地 runtime 已由 ${claim.ownerKind} pid ${claim.ownerPid} 占用；` +
        '如需接管请加 --take-owner',
    );
  }
  ownedPid = true;
  ownedDataDir = dir;
  await touchRuntimeHeartbeat({ kind: 'desktop', pid: process.pid }, dir);

  logger.info(`data dir: ${dir}`);
  logger.info('runtime role: owner (kind desktop)');

  if (opts.hooks) {
    const { hookOk: claudeHookOk } = await setupClaudeHook(dir);
    const { hookOk: codexHookOk } = await setupCodexHook(dir);
    if (!claudeHookOk) {
      logger.warn('Claude Hook 未注册成功，将依赖轮询同步');
    }
    if (!codexHookOk) {
      logger.warn('Codex Hook 未注册成功，将依赖轮询同步');
    }
  } else {
    logger.info('hooks: skipped (--no-hooks)');
  }

  // Re-read: hook setup may rewrite config.json.
  const { config: refreshed } = await loadSanitizedConfig(dir);
  await startPricingOverlayRefresh(dir, refreshed);

  const bucketStore = new BucketStore();
  await bucketStore.reload(dir, resolveLocalCollectSince(refreshed));
  const aggregateCache = await createAggregateCache(dir, bucketStore.getRows());

  // Placeholder app; rebuilt below once the owner runner is wired so manual
  // sync shares the same coalescing runner as poll / hook notify.
  const state: RuntimeState = {
    dir,
    config: refreshed,
    bucketStore,
    aggregateCache,
    app: buildApp({
      dir,
      getConfig: readConfigForApi,
      bucketStore,
      aggregateCache,
    }),
    role: 'owner',
  };
  runtime = state;

  const applyAfterSync = createApplyAfterSync({
    getBucketStore: () => state.bucketStore,
    getAggregateCache: () => state.aggregateCache,
    // No onApplied: the Electron runtime used it to poke the renderer/pet UI.
    // The host app polls /functions/* instead.
  });
  const timedApplyAfterSync = async (
    results: SyncResult[],
    applyOpts?: { quiet?: boolean; forceNotify?: boolean },
  ) => {
    await measureCpuPhase(
      syncLogPath(dir),
      'apply_after_sync',
      {
        role: 'engine',
        buckets: results.reduce((n, r) => n + r.writtenBuckets.length, 0),
        quiet: Boolean(applyOpts?.quiet),
      },
      () => applyAfterSync(results, applyOpts),
    );
  };

  const { stop, runSync } = watchRuntimeSignals({
    dataDir: dir,
    getConfig: readConfigForApi,
    setConfig: (next: TudConfig) => {
      setRuntimeConfig(next);
    },
    // Sync already returns the latest changed buckets. Applying that delta
    // avoids reading the large append-only queue after every hook signal.
    refreshFromDisk: async (results, applyOpts) => {
      if (!runtime) return;
      // Non-quiet result delivery means a hook/manual sync ran: the user is
      // active, so snap the idle backoff back to the fastest interval.
      if (results && results.length > 0 && !applyOpts?.quiet) {
        resetPollBackoffToFast();
      }
      if (!results) {
        await refreshRuntimeFromDisk();
        return;
      }
      await timedApplyAfterSync(results, applyOpts);
    },
    isOwner: () => runtime?.role === 'owner',
    loadConfig: loadSanitizedConfig,
  });  syncWatcherStop = stop;
  runSyncFn = runSync;

  // Rebuild with the shared runner so manual sync coalesces with poll/notify.
  state.app = buildApp({
    dir,
    getConfig: readConfigForApi,
    bucketStore,
    aggregateCache,
    runSyncViaRunner: (reason, source) => runSync(reason, source),
  });

  // A full local scan may take longer than the nominal interval. Scheduling the
  // next poll only after this one settles leaves a real idle window instead of
  // starting a new full scan immediately after a long sync. Idle rounds back off
  // 1min → 2min → 5min; any activity re-arms at 1min.
  const scheduleNextPoll = (delayMs = pollBackoff.currentDelayMs()) => {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = null;
    if (!runtime || runtime.role !== 'owner' || !runSyncFn) return;
    pollTimer = setTimeout(() => {
      void runScheduledPoll();
    }, delayMs);
  };
  reArmPoll = scheduleNextPoll;

  const runScheduledPoll = async () => {
    let nextDelayMs = pollBackoff.currentDelayMs();
    try {
      if (!runtime || runtime.role !== 'owner' || !runSyncFn) return;
      const results = await runSyncFn('poll');
      const wroteAny = results.some((r) => r.writtenBuckets.length > 0);
      nextDelayMs = pollBackoff.noteRound(wroteAny);
    } catch (err) {
      logger.warn(
        `poll sync failed: ${err instanceof Error ? err.message : err}`,
      );
    } finally {
      scheduleNextPoll(nextDelayMs);
    }
  };

  startRuntimeWatchdog();

  logger.info('background syncing local usage…');
  void runSync('startup')
    .catch((err) => {
      logger.warn(
        `startup sync failed: ${err instanceof Error ? err.message : err}`,
      );
    })
    .finally(scheduleNextPoll);

  return { dataDir: state.dir, app: state.app };
}

/**
 * Liveness heartbeat + ownership guard, the stripped-down equivalent of the
 * Electron runtime watchdog: refresh `runtime.heartbeat`, then reclaim `tud.pid`
 * if another process took it over while we were running.
 */
function startRuntimeWatchdog(): void {
  stopRuntimeWatchdog();
  const schedule = (delayMs: number) => {
    if (stopping) return;
    heartbeatTimer = setTimeout(() => {
      void runWatchdogTick().then(() => schedule(HEARTBEAT_INTERVAL_MS));
    }, delayMs);
  };
  schedule(HEARTBEAT_INTERVAL_MS);
}

function stopRuntimeWatchdog(): void {
  if (heartbeatTimer) {
    clearTimeout(heartbeatTimer);
    heartbeatTimer = null;
  }
}

async function runWatchdogTick(): Promise<void> {
  const current = runtime;
  if (stopping || !current) return;
  try {
    await touchRuntimeHeartbeat(
      { kind: 'desktop', pid: process.pid },
      current.dir,
    );
    const owner = await getRunningOwner(current.dir);
    if (owner != null && owner.pid !== process.pid) {
      logger.warn(
        `lost runtime ownership to pid ${owner.pid}, reclaiming`,
      );
      await claimRuntimeOwner(current.dir, { kind: 'desktop', force: true });
    }
  } catch (err) {
    logger.warn(
      `runtime watchdog failed: ${err instanceof Error ? err.message : err}`,
    );
  }
}

export interface StopEngineRuntimeOptions {
  /**
   * Runs after the poll loop / signal watcher / pricing refresh are stopped and
   * before the owner pid is released — the entrypoint closes the HTTP server
   * here so no request can race the release.
   */
  beforeReleaseOwner?: () => Promise<void>;
}

/** Stop everything and release `tud.pid` + the heartbeat. Idempotent. */
export async function stopEngineRuntime(
  opts: StopEngineRuntimeOptions = {},
): Promise<void> {
  if (stopping) return;
  stopping = true;
  stopRuntimeWatchdog();
  if (pricingRefreshStop) {
    pricingRefreshStop();
    pricingRefreshStop = null;
  }
  if (pollTimer) {
    clearTimeout(pollTimer);
    pollTimer = null;
  }
  if (syncWatcherStop) {
    syncWatcherStop();
    syncWatcherStop = null;
  }
  runSyncFn = null;
  reArmPoll = null;
  pollBackoff.reset();

  await opts.beforeReleaseOwner?.();

  const dir = runtime?.dir ?? ownedDataDir;
  if (ownedPid && dir) {
    await releaseRuntimeOwner(dir);
    ownedPid = false;
  }
  if (dir) {
    await clearRuntimeHeartbeat(dir);
  }
  ownedDataDir = null;
  runtime = null;
}

export function isEngineRuntimeRunning(): boolean {
  return runtime != null;
}
