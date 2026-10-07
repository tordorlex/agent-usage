#!/usr/bin/env bash
# End-to-end smoke test for the engine sidecar.
#
# Everything runs inside packages/engine: data dirs under .tmp-data* (gitignored)
# — NEVER the real ~/.ai-usage — and always with --no-hooks, so the run cannot
# touch ~/.claude / ~/.codex.
#
# Usage: bash packages/engine/scripts/smoke.sh
# Artifacts (handshake, stderr logs, per-endpoint JSON bodies) land in
# packages/engine/.tmp-data-run/.
set -uo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$ENGINE_DIR/.tmp-data"
RUN_DIR="$ENGINE_DIR/.tmp-data-run"
CONFIG_HOME="$ENGINE_DIR/.tmp-data-config"
BASE_LOG="$RUN_DIR/base-engine.log"
FAILURES=0

fail() {
  echo "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

rm -rf "$DATA_DIR" "$RUN_DIR" "$CONFIG_HOME"
mkdir -p "$RUN_DIR"

# core keeps the durable deviceId in a sidecar OUTSIDE the data dir
# (~/.config/jusage/device-id). Point it back into the repo so a smoke run stays
# hermetic and never touches the machine's real identity file.
export JUSAGE_CONFIG_HOME="$CONFIG_HOME"

cd "$ENGINE_DIR"

# Wait until a log file has at least one line (the stdout handshake).
wait_for_line() {
  local file="$1" tries="${2:-300}"
  for _ in $(seq 1 "$tries"); do
    [ -s "$file" ] && return 0
    sleep 0.2
  done
  return 1
}

# Wait until a background subshell wrote its exit code.
wait_for_exit_file() {
  local file="$1" tries="${2:-150}"
  for _ in $(seq 1 "$tries"); do
    [ -s "$file" ] && return 0
    sleep 0.2
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. Boot + stdout handshake + HTTP contract
# ---------------------------------------------------------------------------
node dist/index.js \
  --data-dir "$DATA_DIR" \
  --host 127.0.0.1 \
  --port 0 \
  --no-hooks \
  >"$RUN_DIR/stdout.log" 2>"$RUN_DIR/stderr.log" </dev/null &
ENGINE_PID=$!

if ! wait_for_line "$RUN_DIR/stdout.log"; then
  fail 'no engine-ready line on stdout'
  cat "$RUN_DIR/stderr.log"
  kill -9 "$ENGINE_PID" 2>/dev/null
  exit 1
fi

echo '=== stdout (must be exactly one handshake line) ==='
cat "$RUN_DIR/stdout.log"
PORT="$(LOG_FILE="$RUN_DIR/stdout.log" ENGINE_PID="$ENGINE_PID" node -e '
const fs=require("fs");
const lines=fs.readFileSync(process.env.LOG_FILE,"utf8").trim().split("\n");
if(lines.length!==1){console.error("FAIL: expected exactly 1 stdout line, got "+lines.length);process.exit(2)}
const j=JSON.parse(lines[0]);
if(j.type!=="engine-ready"){console.error("FAIL: first stdout line is not engine-ready");process.exit(2)}
for(const k of ["host","port","pid","dataDir","version"]){if(j[k]===undefined){console.error("FAIL: missing "+k);process.exit(2)}}
if(!Number.isInteger(j.port)||j.port<=0){console.error("FAIL: no real port in handshake");process.exit(2)}
if(j.pid!==Number(process.env.ENGINE_PID)){console.error("FAIL: handshake pid mismatch");process.exit(2)}
if(!j.dataDir.startsWith("/")){console.error("FAIL: dataDir is not absolute");process.exit(2)}
process.stdout.write(String(j.port));
')" || { fail 'handshake invalid'; kill -9 "$ENGINE_PID" 2>/dev/null; exit 1; }
echo "engine pid=$ENGINE_PID port=$PORT"

BASE="http://127.0.0.1:$PORT"

check() {
  local name="$1" path="$2"
  local body status
  body="$(curl -sS -w '\n%{http_code}' "$BASE$path")"
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"
  printf '%s' "$body" >"$RUN_DIR/$name.json"
  echo "=== GET $path -> HTTP $status (body: .tmp-data-run/$name.json)"
  head -c 260 "$RUN_DIR/$name.json"; echo
  [ "$status" = "200" ] || fail "expected 200 for $path (got $status)"
  BODY_FILE="$RUN_DIR/$name.json" PATH_LABEL="$path" node -e '
const b=JSON.parse(require("fs").readFileSync(process.env.BODY_FILE,"utf8"));
const ok=b.success===true&&typeof b.message==="string"&&Object.prototype.hasOwnProperty.call(b,"data");
if(!ok){console.error("FAIL: {success,message,data} envelope mismatch on "+process.env.PATH_LABEL);process.exit(1)}
' || fail "envelope mismatch on $path"
}

echo "=== GET /health -> $(curl -sS -w ' HTTP %{http_code}' "$BASE/health")"
check usage-summary  /functions/tud-usage-summary
check usage-daily-7  '/functions/tud-usage-daily?days=7'
check usage-hourly-1 '/functions/tud-usage-hourly?days=1'
check usage-model-30 '/functions/tud-usage-model-breakdown?days=30'
check sync-status    /functions/tud-sync-status

echo '=== POST /functions/tud-trigger-sync'
STATUS="$(curl -sS -o "$RUN_DIR/trigger-sync.json" -w '%{http_code}' -X POST "$BASE/functions/tud-trigger-sync" \
  -H 'content-type: application/json' -d '{"source":"claude"}')"
echo "HTTP $STATUS (body: .tmp-data-run/trigger-sync.json)"
head -c 200 "$RUN_DIR/trigger-sync.json"; echo
[ "$STATUS" = "200" ] || fail "trigger-sync returned $STATUS"

# After a completed sync the aggregate endpoints must actually carry rows, so
# the check above is not merely proving an empty-envelope happy path.
echo '=== aggregate endpoints after sync (days=90 window)'
curl -sS -o "$RUN_DIR/usage-daily-90.json" "$BASE/functions/tud-usage-daily?days=90"
curl -sS -o "$RUN_DIR/usage-model-90.json" "$BASE/functions/tud-usage-model-breakdown?days=90"
DAILY_FILE="$RUN_DIR/usage-daily-90.json" MODEL_FILE="$RUN_DIR/usage-model-90.json" node -e '
const fs=require("fs");
const d=JSON.parse(fs.readFileSync(process.env.DAILY_FILE,"utf8")).data;
const m=JSON.parse(fs.readFileSync(process.env.MODEL_FILE,"utf8")).data;
console.log("daily days="+d.days.length+" rows, models="+m.models.length+" rows, projects="+m.projects.length+" rows");
if(d.days.length===0&&m.models.length===0){console.error("FAIL: aggregates empty after sync");process.exit(1)}
' || fail 'aggregate endpoints carry no data after sync'

# ---------------------------------------------------------------------------
# 2. Upload can never be enabled through the app-facing config endpoint
# ---------------------------------------------------------------------------
echo '=== GET /functions/tud-config'
curl -sS -o "$RUN_DIR/config.json" "$BASE/functions/tud-config"
CONFIG_FILE="$RUN_DIR/config.json" node -e '
const b=JSON.parse(require("fs").readFileSync(process.env.CONFIG_FILE,"utf8"));
console.log("juejin view:",JSON.stringify(b.data.juejin));
if(b.data.juejin.enabled!==false){console.error("FAIL: engine reports upload enabled");process.exit(1)}
' || fail 'engine reports juejin.enabled != false'

echo '=== PUT /functions/tud-config {juejin:{enabled:true}} (must be refused)'
STATUS="$(curl -sS -o "$RUN_DIR/config-put.json" -w '%{http_code}' -X PUT "$BASE/functions/tud-config" \
  -H 'content-type: application/json' -d '{"juejin":{"enabled":true}}')"
cat "$RUN_DIR/config-put.json"; echo " <- HTTP $STATUS"
[ "$STATUS" = "403" ] || fail 'config update could re-enable upload'

# ---------------------------------------------------------------------------
# 3. SIGTERM: clean exit, pid file + heartbeat released, no orphan
# ---------------------------------------------------------------------------
echo '=== SIGTERM'
kill -TERM "$ENGINE_PID"
wait "$ENGINE_PID"
EXIT_CODE=$?
echo "exit code: $EXIT_CODE"
[ "$EXIT_CODE" = "0" ] || fail "SIGTERM exit code $EXIT_CODE (expected 0)"
if kill -0 "$ENGINE_PID" 2>/dev/null; then fail 'engine process still alive'; else echo 'process gone (ok)'; fi
if CHILD_OUT="$(pgrep -P "$ENGINE_PID" 2>&1)"; then
  fail "children left behind: $CHILD_OUT"
elif [ -n "$CHILD_OUT" ]; then
  echo "pgrep unavailable in this environment ($CHILD_OUT) — child check skipped"
else
  echo 'no children (ok)'
fi
for gone in tud.pid tud.heartbeat; do
  if [ -e "$DATA_DIR/$gone" ]; then fail "$gone not released"; else echo "$gone released (ok)"; fi
done
if [ -f "$DATA_DIR/logs/upload.log" ]; then
  echo "upload.log exists ($(wc -l <"$DATA_DIR/logs/upload.log") lines) — must contain no batch POST:"
  tail -5 "$DATA_DIR/logs/upload.log"
else
  echo 'no upload.log at all (ok: the upload path was never entered)'
fi
echo "persisted config juejin.enabled = $(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).juejin.enabled)' "$DATA_DIR/config.json")"

# ---------------------------------------------------------------------------
# 4. Orphan prevention: host spawned us with a piped stdin and then exited
# ---------------------------------------------------------------------------
echo '=== orphan prevention: piped stdin closes ==='
STDIN_DIR="$RUN_DIR/data-stdin"
rm -rf "$STDIN_DIR"
( sleep 3 | node dist/index.js --data-dir "$STDIN_DIR" --no-hooks \
    >"$RUN_DIR/stdin.log" 2>"$RUN_DIR/stdin.err"; echo $? >"$RUN_DIR/stdin.exit" ) &
if ! wait_for_line "$RUN_DIR/stdin.log"; then fail 'stdin run never became ready'; fi
echo "handshake: $(cat "$RUN_DIR/stdin.log")"
if wait_for_exit_file "$RUN_DIR/stdin.exit" 150; then
  echo "exited by itself after stdin closed, exit code $(cat "$RUN_DIR/stdin.exit") (ok)"
  [ "$(cat "$RUN_DIR/stdin.exit")" = "0" ] || fail 'stdin-close shutdown was not a clean exit'
else
  fail 'engine still running 30s after the stdin pipe closed'
fi

# ---------------------------------------------------------------------------
# 5. Orphan prevention: --parent-pid watchdog
# ---------------------------------------------------------------------------
echo '=== orphan prevention: --parent-pid dies ==='
PARENT_DIR="$RUN_DIR/data-parent-pid"
rm -rf "$PARENT_DIR"
sleep 3 &
PARENT_PID=$!
( node dist/index.js --data-dir "$PARENT_DIR" --no-hooks --parent-pid "$PARENT_PID" </dev/null \
    >"$RUN_DIR/parent-pid.log" 2>"$RUN_DIR/parent-pid.err"; echo $? >"$RUN_DIR/parent-pid.exit" ) &
if ! wait_for_line "$RUN_DIR/parent-pid.log"; then fail 'parent-pid run never became ready'; fi
echo "handshake: $(cat "$RUN_DIR/parent-pid.log")"
if wait_for_exit_file "$RUN_DIR/parent-pid.exit" 150; then
  echo "exited by itself after parent pid $PARENT_PID died, exit code $(cat "$RUN_DIR/parent-pid.exit") (ok)"
  [ "$(cat "$RUN_DIR/parent-pid.exit")" = "0" ] || fail 'parent-pid shutdown was not a clean exit'
else
  fail 'engine still running 30s after its parent died'
fi
wait "$PARENT_PID" 2>/dev/null

# ---------------------------------------------------------------------------
# 6. Ownership: a second engine is refused, --take-owner takes over
# ---------------------------------------------------------------------------
echo '=== ownership: tud.pid is exclusive ==='
OWN_DIR="$RUN_DIR/data-owner"
rm -rf "$OWN_DIR"
( node dist/index.js --data-dir "$OWN_DIR" --no-hooks </dev/null \
    >"$RUN_DIR/owner-a.log" 2>"$RUN_DIR/owner-a.err"; echo $? >"$RUN_DIR/owner-a.exit" ) &
if ! wait_for_line "$RUN_DIR/owner-a.log"; then fail 'owner A never became ready'; fi
OWNER_A_PID="$(LOG_FILE="$RUN_DIR/owner-a.log" node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.env.LOG_FILE,"utf8").trim()).pid))')"
echo "owner A pid=$OWNER_A_PID: $(cat "$RUN_DIR/owner-a.log")"

# B: same data dir, no --take-owner → engine-error + non-zero exit.
node dist/index.js --data-dir "$OWN_DIR" --no-hooks </dev/null \
  >"$RUN_DIR/owner-b.log" 2>"$RUN_DIR/owner-b.err"
STATUS=$?
echo "second engine (no --take-owner) exit=$STATUS stdout=$(cat "$RUN_DIR/owner-b.log")"
[ "$STATUS" != "0" ] || fail 'second engine must not start as owner'
LOG_FILE="$RUN_DIR/owner-b.log" node -e '
const j=JSON.parse(require("fs").readFileSync(process.env.LOG_FILE,"utf8").trim());
if(j.type!=="engine-error"){console.error("FAIL: expected engine-error, got "+j.type);process.exit(1)}
' || fail 'second engine did not report engine-error'
if kill -0 "$OWNER_A_PID" 2>/dev/null; then echo 'owner A still running (ok)'; else fail 'owner A died'; fi

# C: --take-owner → stops A, becomes the owner.
echo '=== ownership: --take-owner takes over ==='
( node dist/index.js --data-dir "$OWN_DIR" --no-hooks --take-owner </dev/null \
    >"$RUN_DIR/owner-c.log" 2>"$RUN_DIR/owner-c.err"; echo $? >"$RUN_DIR/owner-c.exit" ) &
if ! wait_for_line "$RUN_DIR/owner-c.log"; then fail 'owner C never became ready'; fi
echo "owner C: $(cat "$RUN_DIR/owner-c.log")"
if wait_for_exit_file "$RUN_DIR/owner-a.exit" 100; then
  echo "owner A exited after takeover, exit code $(cat "$RUN_DIR/owner-a.exit") (ok)"
else
  fail 'previous owner A did not exit after --take-owner'
fi
OWNER_C_PID="$(LOG_FILE="$RUN_DIR/owner-c.log" node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.env.LOG_FILE,"utf8").trim()).pid))')"
kill -TERM "$OWNER_C_PID"
if wait_for_exit_file "$RUN_DIR/owner-c.exit" 100; then
  echo "owner C exit code $(cat "$RUN_DIR/owner-c.exit") (ok)"
else
  fail 'owner C did not exit on SIGTERM'
fi
echo "owner C released tud.pid: $([ -e "$OWN_DIR/tud.pid" ] && echo NO || echo yes)"
[ -e "$OWN_DIR/tud.pid" ] && fail 'owner C did not release tud.pid'

# ---------------------------------------------------------------------------
echo '=== stderr tail (base run) ==='
tail -12 "$RUN_DIR/stderr.log"
echo
if [ "$FAILURES" = "0" ]; then
  echo 'SMOKE: all checks passed'
else
  echo "SMOKE: $FAILURES failure(s)"
  exit 1
fi
