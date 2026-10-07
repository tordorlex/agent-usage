/**
 * Headless engine entrypoint (`node dist/index.js …`).
 *
 * TRANSPORT CONTRACT (frozen — the SwiftUI host parses this):
 *   - stdout carries EXACTLY ONE line: the `engine-ready` handshake, or an
 *     `engine-error` line when startup fails (then exit non-zero).
 *   - every other log line goes to stderr, so the stdout stream stays parsable.
 *
 * Orphan prevention (both mechanisms are independent):
 *   - stdin: when the host spawns us with a piped stdin, `end`/`close` means the
 *     host is gone → shut down. The watcher is only armed when fd 0 really is a
 *     pipe/FIFO, so `</dev/null` (launchd, nohup, service managers) is not
 *     mistaken for a closed parent.
 *   - `--parent-pid <pid>`: poll `isPidAlive(pid)` and shut down when the parent
 *     dies, for hosts that do not pipe stdin.
 */
import { fstatSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import type { Server } from 'node:http';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  createHttpServer,
  DEFAULT_DATA_DIR,
  isPidAlive,
  listenServer,
} from '@juejin-opensource/jusage-core';

import {
  startEngineRuntime,
  stopEngineRuntime,
  type EngineRuntimeLogger,
} from './runtime.js';

/** Defaults from the task contract: loopback only, OS-assigned port. */
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 0;
/** How often `--parent-pid` is probed for liveness. */
const PARENT_POLL_INTERVAL_MS = 2_000;
/**
 * The engine serves no static assets: the SwiftUI host only needs `/functions/*`
 * and `/health`. A non-existent dir makes any other path answer 503 from core's
 * static handler instead of leaking a dashboard bundle.
 */
const STATIC_DIR = join(fileURLToPath(new URL('.', import.meta.url)), 'no-static-assets');

const logger: EngineRuntimeLogger = {
  info: (message) => {
    process.stderr.write(`[jusage-engine] ${message}\n`);
  },
  warn: (message) => {
    process.stderr.write(`[jusage-engine] warn: ${message}\n`);
  },
};

interface EngineArgs {
  dataDir: string;
  host: string;
  port: number;
  takeOwner: boolean;
  hooks: boolean;
  parentPid: number | null;
  help: boolean;
}

function usage(): string {
  return [
    '用法: jusage-engine [options]',
    '',
    '  --data-dir <dir>     数据目录（默认 ~/.ai-usage）',
    '  --host <host>        监听地址（默认 127.0.0.1）',
    '  --port <n>           监听端口（默认 0 = 系统分配，实际端口见 stdout 握手）',
    '  --take-owner         强制接管 tud.pid（结束当前同步 owner）',
    '  --no-hooks           不注册 Claude / Codex Hook',
    '  --parent-pid <pid>   父进程退出时自动关闭（未使用管道 stdin 时）',
    '  -h, --help           显示帮助',
    '',
    'stdout 只输出一行握手 JSON：',
    '  {"type":"engine-ready","host":"…","port":<n>,"pid":<n>,"dataDir":"…","version":"…"}',
  ].join('\n');
}

function parseBool(value: string, flag: string): boolean {
  if (value === 'true' || value === '1') return true;
  if (value === 'false' || value === '0') return false;
  throw new Error(`${flag} 只接受 true / false`);
}

function parseArgs(argv: readonly string[]): EngineArgs {
  const args: EngineArgs = {
    dataDir: DEFAULT_DATA_DIR,
    host: DEFAULT_HOST,
    port: DEFAULT_PORT,
    takeOwner: false,
    hooks: true,
    parentPid: null,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const raw = argv[index]!;
    const eq = raw.indexOf('=');
    const flag = eq === -1 ? raw : raw.slice(0, eq);
    const inline = eq === -1 ? undefined : raw.slice(eq + 1);
    const value = (): string => {
      if (inline !== undefined) return inline;
      const next = argv[index + 1];
      if (next === undefined || next.startsWith('--')) {
        throw new Error(`${flag} 缺少参数值`);
      }
      index += 1;
      return next;
    };

    switch (flag) {
      case '--data-dir':
        // Resolve here: core's resolveDataDir keeps relative paths relative,
        // and the handshake must report an absolute dir.
        args.dataDir = resolve(value());
        break;
      case '--host':
        args.host = value();
        break;
      case '--port': {
        const port = Number(value());
        if (!Number.isInteger(port) || port < 0 || port > 65535) {
          throw new Error(`--port 无效: ${inline ?? argv[index]}`);
        }
        args.port = port;
        break;
      }
      case '--take-owner':
        args.takeOwner = inline === undefined ? true : parseBool(inline, flag);
        break;
      case '--no-hooks':
        args.hooks = inline === undefined ? false : !parseBool(inline, flag);
        break;
      case '--parent-pid': {
        const pid = Number(value());
        if (!Number.isInteger(pid) || pid <= 0) {
          throw new Error('--parent-pid 需要一个正整数 pid');
        }
        args.parentPid = pid;
        break;
      }
      case '-h':
      case '--help':
        args.help = true;
        break;
      default:
        throw new Error(`未知参数: ${raw}`);
    }
  }

  return args;
}

async function readEngineVersion(): Promise<string> {
  try {
    const raw = await readFile(new URL('../package.json', import.meta.url), 'utf8');
    const parsed = JSON.parse(raw) as { version?: unknown };
    return typeof parsed.version === 'string' ? parsed.version : '0.0.0';
  } catch {
    return '0.0.0';
  }
}

let httpServer: Server | null = null;
let parentWatchTimer: ReturnType<typeof setInterval> | null = null;
let shuttingDown = false;
let ready = false;

function emitReady(payload: {
  host: string;
  port: number;
  dataDir: string;
  version: string;
}): void {
  process.stdout.write(
    `${JSON.stringify({
      type: 'engine-ready',
      host: payload.host,
      port: payload.port,
      pid: process.pid,
      dataDir: payload.dataDir,
      version: payload.version,
    })}\n`,
  );
}

function isStdinPipe(): boolean {
  try {
    const stat = fstatSync(0);
    return stat.isFIFO() || stat.isSocket();
  } catch {
    return false;
  }
}

function armStdinWatch(): void {
  if (!isStdinPipe()) {
    logger.info(
      'stdin is not a pipe; host-exit detection relies on --parent-pid only',
    );
    return;
  }
  const onHostGone = (event: string) => {
    logger.info(`stdin ${event} (host process exited)`);
    void shutdown(0);
  };
  process.stdin.on('end', () => onHostGone('end'));
  process.stdin.on('close', () => onHostGone('close'));
  process.stdin.on('error', (err) => {
    logger.warn(`stdin error: ${err.message}`);
    void shutdown(0);
  });
  // Flowing mode is what actually emits 'end'.
  process.stdin.resume();
}

function armParentWatch(parentPid: number | null): void {
  if (parentPid == null) return;
  if (parentPid === process.pid) {
    logger.warn('--parent-pid 指向本进程，已忽略');
    return;
  }
  if (!isPidAlive(parentPid)) {
    logger.warn(`parent pid ${parentPid} 已不存在，直接退出`);
    void shutdown(0);
    return;
  }
  parentWatchTimer = setInterval(() => {
    if (!isPidAlive(parentPid)) {
      logger.info(`parent pid ${parentPid} exited`);
      void shutdown(0);
    }
  }, PARENT_POLL_INTERVAL_MS);
  parentWatchTimer.unref();
}

function closeHttpServer(server: Server): Promise<void> {
  return new Promise((resolveClose) => {
    server.close(() => resolveClose());
    // Screens out idle keep-alive curls so shutdown cannot hang on them.
    server.closeIdleConnections();
  });
}

/**
 * Graceful shutdown: stop poll / signal watcher / pricing refresh, close the
 * HTTP server, then release `tud.pid` and the heartbeat (see
 * `stopEngineRuntime`) and exit with `code`.
 */
async function shutdown(code: number): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  if (parentWatchTimer) {
    clearInterval(parentWatchTimer);
    parentWatchTimer = null;
  }
  process.stdin.removeAllListeners();
  process.stdin.pause();

  try {
    await stopEngineRuntime({
      beforeReleaseOwner: async () => {
        const server = httpServer;
        httpServer = null;
        if (server) await closeHttpServer(server);
      },
    });
  } catch (err) {
    logger.warn(
      `shutdown failed: ${err instanceof Error ? err.message : err}`,
    );
  }
  logger.info(`stopped (exit ${code})`);
  process.exit(code);
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stderr.write(`${usage()}\n`);
    return;
  }

  const version = await readEngineVersion();
  const runtime = await startEngineRuntime({
    dataDir: args.dataDir,
    takeOwner: args.takeOwner,
    hooks: args.hooks,
    logger,
  });

  const server = createHttpServer({
    honoApp: runtime.app,
    staticDir: STATIC_DIR,
    host: args.host,
    port: args.port,
  });

  let actualPort: number;
  try {
    ({ port: actualPort } = await listenServer(server, args.host, args.port));
  } catch (err) {
    await stopEngineRuntime();
    throw err;
  }
  httpServer = server;
  ready = true;

  process.on('SIGINT', () => {
    void shutdown(0);
  });
  process.on('SIGTERM', () => {
    void shutdown(0);
  });
  // A host that dies while we are mid-write must not leave a zombie engine.
  process.stdout.on('error', () => {
    void shutdown(0);
  });
  process.stderr.on('error', () => {});
  process.on('uncaughtException', (err) => {
    logger.warn(`uncaughtException: ${err.stack ?? err.message}`);
    void shutdown(1);
  });
  process.on('unhandledRejection', (reason) => {
    logger.warn(
      `unhandledRejection: ${reason instanceof Error ? reason.message : String(reason)}`,
    );
  });

  armParentWatch(args.parentPid);
  armStdinWatch();

  logger.info(`listening on http://${args.host}:${actualPort}`);
  logger.info(`data dir: ${runtime.dataDir}`);
  emitReady({
    host: args.host,
    port: actualPort,
    dataDir: runtime.dataDir,
    version,
  });
}

function fatal(err: unknown): void {
  const message = err instanceof Error ? err.message : String(err);
  logger.warn(`fatal: ${message}`);
  if (ready) {
    // The ready line already went out, so stdout stays a single-line stream:
    // the host detects the failure from the non-zero process exit.
    void shutdown(1);
    return;
  }
  // Flush the handshake on stdout before exiting non-zero.
  const timer = setTimeout(() => process.exit(1), 1_000);
  process.stdout.write(
    `${JSON.stringify({ type: 'engine-error', message })}\n`,
    () => {
      clearTimeout(timer);
      process.exit(1);
    },
  );
}

main().catch((err) => {
  void stopEngineRuntime()
    .catch(() => {})
    .finally(() => fatal(err));
});
