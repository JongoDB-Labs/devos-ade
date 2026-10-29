#!/usr/bin/env bash
# Opt-in end-to-end check of Ollama as a runtime DevOS ADE installs, runs and watches itself on a Mac (JON-829; run by
# hand, not part of tests/run.sh, CI or tests/e2e/run.sh). This checkout's code on a scratch .env and state folder: the
# Ollama build catalog/runtimes.pins names is downloaded from GitHub, checked against its pinned SHA-256 and run as a
# launchd user agent of the scratch stack (a label of its own; the trap removes it). Checks: 1 install: running, the
# pinned version answers, the agent's plist, 127.0.0.1 only, as this user; 2 a request for another name (DNS rebinding)
# and one from a foreign web page are refused; 3 a small model pulled and loaded shows with its size and GPU memory;
# 4 Ollama killed: launchd starts it again and the watch records it (Activity); 5 Stop: no agent, nothing on 11434, and
# it stays down; Start: it answers again; 6 its log; 7 Uninstall: its folder, its models, the plist and the port gone.
# Needs: a Mac, 127.0.0.1:11434 free (an Ollama of yours there: only check 0, that it is never installed over, runs),
# outbound access to github.com (and huggingface.co for check 3), about 300 MB of disk.
#   --no-model   skip check 3 (no model download)        --out DIR   where the summary goes (tests/e2e/out)
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/tests/e2e/out"; MODEL=1
MODEL_NAME="hf.co/bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-model) MODEL=0; shift ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/runtimes-mac.sh --help)" >&2; exit 2 ;;
  esac
done
say() { printf '==> %s\n' "$*" >&2; }
FAILS=0; CHECKS=()
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$*"); }
ok() { printf 'ok    %s\n' "$*" >&2; CHECKS+=("ok	$*"); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }
[ "$(uname -s)" = Darwin ] || { echo "this check is for a Mac (Linux runs Ollama as a container: tests/test_runtimes.sh, tests/caddy-validate.sh)" >&2; exit 2; }
WORK="$ROOT/tests/e2e/work/bne2e-runtimes"; API=http://127.0.0.1:11434
cleanup() {
  local rc=$?
  if [ -n "${STATE_DIR:-}" ] && declare -F _rt_agent_down >/dev/null; then
    _rt_agent_down ollama >/dev/null 2>&1; rm -f "$(rt_plist ollama)"
  fi
  { [ "$rc" = 0 ] && [ "$FAILS" = 0 ]; } || { [ ! -d "$WORK/state/runtimes" ] || { mkdir -p "$OUT" && tail -n 200 "$WORK/state/runtimes/ollama/server.log" > "$OUT/runtimes-mac-ollama.log" 2>/dev/null; }; }
  rm -rf "$WORK"
  mkdir -p "$OUT" 2>/dev/null && printf '%s\n' ${CHECKS[@]+"${CHECKS[@]}"} | python3 -I -c 'import json, sys
print(json.dumps({"failures": int(sys.argv[1]), "checks": [dict(zip(("status", "check"), l.rstrip("\n").split("\t", 1))) for l in sys.stdin if "\t" in l]}, indent=1))' "$FAILS" > "$OUT/runtimes-mac.json" 2>/dev/null
}
trap cleanup EXIT; trap 'exit 130' INT TERM
rm -rf "$WORK"; mkdir -p "$WORK/state" "$OUT"

# --- this checkout's code, on a scratch .env and state dir (never an installed stack) ---
STACK_DIR="$ROOT"; ENV_FILE="$WORK/.env"; STATE_DIR="$WORK/state"; : > "$ENV_FILE"
export STACK_DIR ENV_FILE STATE_DIR
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
config_apply() { _cfg_write; CFG_ORDER=''; }   # (.env only: there is no model gateway here to reload)
export ASSUME_YES=1
agent_pid() { _rt_launchd ollama | awk '$1 == "pid" && $2 == "=" { print $3; exit }'; }
answers() { [ -n "$(_rt_ollama_version)" ]; }
not() { ! "$@"; }
wait_for() { local n=0 max="$1"; shift; while [ "$n" -lt "$max" ]; do "$@" && return 0; sleep 1; n=$((n + 1)); done; return 1; }
status_json() { rt_status_write; python3 -I -c "$1" "$(rt_status_file)"; }

# --- 0: an Ollama of yours is never installed over ---
if answers; then
  check "0 an Ollama that is not this stack's is 'Yours' ($(_rt_ollama_version))" [ "$(rt_state ollama)" = external ]
  if ( rt_install ollama ) > "$WORK/install.log" 2>&1; then fail "0 install went ahead over it"
  else check "0 install refuses to go over it" grep -q "not DevOS ADE's already answers" "$WORK/install.log"; fi
  echo "an Ollama already answers on 127.0.0.1:11434: checks 1-7 need the port free (quit it and run this again)" >&2
  exit 2
fi
PIN="$(rt_pin OLLAMA_VERSION)"

# --- 1: install ---
say "installing Ollama $PIN (download, SHA-256, unpack, launchd)"
if ! ( rt_install ollama ) > "$WORK/install.log" 2>&1; then
  fail "1 install: $(tail -n 3 "$WORK/install.log" | tr '\n' ' ')"; exit 1
fi
check "1 it is running" [ "$(rt_state ollama)" = running ]
check "1 the pinned version answers ($PIN)" [ "$(_rt_ollama_version)" = "$PIN" ]
check "1 the agent's plist is this stack's, mode 600" [ "$(stat -f %Lp "$(rt_plist ollama)" 2>/dev/null)" = 600 ]
PID="$(agent_pid)"
check "1 launchd runs it (pid ${PID:-none})" [ -n "$PID" ]
check "1 as this user, not root" [ "$(ps -o user= -p "${PID:-0}" 2>/dev/null | tr -d ' ')" = "$(id -un)" ]
LISTEN="$(lsof -nP -a -p "${PID:-0}" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u | tr '\n' ' ')"
check "1 it listens on 127.0.0.1:11434 alone ($LISTEN)" [ "$LISTEN" = "127.0.0.1:11434 " ]
check "1 its models go to the stack's folder" grep -q "<string>$(rt_dir ollama)/models</string>" "$(rt_plist ollama)"

# --- 2: a web page cannot use it ---
code() { curl -s -o /dev/null -w '%{http_code}' -m 10 "$@"; }
check "2 a request for another name (DNS rebinding) is refused" [ "$(code -H 'Host: rebind.example:11434' "$API/api/version")" = 403 ]
check "2 a request from a foreign web page is refused" [ "$(code -H 'Origin: https://rebind.example' -H 'Content-Type: application/json' -d '{"model":"x"}' "$API/api/show")" = 403 ]
check "2 localhost is answered" [ "$(code "http://localhost:11434/api/version")" = 200 ]

# --- 3: a model loaded, with its GPU memory ---
if [ "$MODEL" = 1 ]; then
  say "pulling $MODEL_NAME (about 100 MB) and loading it"
  curl -s -m 900 "$API/api/pull" -d "{\"model\":\"$MODEL_NAME\",\"stream\":false}" > "$WORK/pull.json" 2>&1
  curl -s -m 300 "$API/api/generate" -d "{\"model\":\"$MODEL_NAME\",\"prompt\":\"Hi\",\"stream\":false,\"keep_alive\":\"5m\",\"options\":{\"num_predict\":2}}" > "$WORK/gen.json" 2>&1
  GPU=0; [ "$(uname -m)" != arm64 ] || GPU=1
  if status_json 'import json, sys
r = json.load(open(sys.argv[1]))["runtimes"][0]
l = [m for m in r["loaded"] if m["name"].startswith("hf.co/bartowski/SmolLM2-135M")]
assert l and l[0]["bytes"] > 10_000_000, r["loaded"]
assert '"$GPU"' == 0 or l[0]["gpu_bytes"] > 0, ("no GPU memory", l)
assert r["memory_bytes"] >= l[0]["bytes"], r'; then
    ok "3 the model is listed as loaded, with its size$([ "$GPU" = 1 ] && echo " and its GPU memory (Metal)")"
  else
    fail "3 the model is not listed as loaded as it should be ($(head -c 200 "$WORK/pull.json") $(head -c 200 "$WORK/gen.json"))"
  fi
  check "3 ./stack runtimes status says so" grep -q "loaded: hf.co/bartowski/SmolLM2-135M" <(cmd_runtimes status 2>&1)
fi

# --- 4: it ends by itself: launchd starts it again, the watch records it ---
say "ending Ollama (kill -9): launchd should start it again"
runtimes_watch
kill -9 "${PID:-0}" 2>/dev/null
restarted() { local p; p="$(agent_pid)"; [ -n "$p" ] && [ "$p" != "$PID" ] && answers; }
check "4 launchd started it again (within 30 s)" wait_for 30 restarted
runtimes_watch
check "4 the watch recorded it for Activity" grep -q "	restart	" "$(rt_events_file)"
check "4 the portal's file counts it" status_json 'import json, sys; r = json.load(open(sys.argv[1]))["runtimes"][0]; assert r["restarts"] >= 1, r'
PID="$(agent_pid)"

# --- 5: Stop and Start ---
( rt_stop ollama ) > "$WORK/stop.log" 2>&1
check "5 Stop: it is stopped" [ "$(rt_state ollama)" = stopped ]
check "5 Stop: no plist (a login does not start it)" [ ! -e "$(rt_plist ollama)" ]
sleep 12
check "5 Stop: nothing answers on 11434, 12 s later" not answers
( rt_start ollama ) > "$WORK/start.log" 2>&1
check "5 Start: it answers again" [ "$(rt_state ollama)" = running ]

# --- 6: its log ---
check "6 its log says where it listens" grep -q "127.0.0.1:11434" <(rt_logs_text ollama 400)

# --- 7: Uninstall ---
D="$(rt_dir ollama)"; PL="$(rt_plist ollama)"
( rt_uninstall ollama ) > "$WORK/uninstall.log" 2>&1
check "7 Uninstall: its folder and models are gone" [ ! -e "$D" ]
check "7 Uninstall: no plist" [ ! -e "$PL" ]
check "7 Uninstall: no agent" not _rt_agent_loaded ollama
check "7 Uninstall: nothing answers on 11434" not answers
check "7 Uninstall: the state is not installed" [ "$(rt_state ollama)" = not-installed ]

printf '\n%d checks, %d failed\n' "${#CHECKS[@]}" "$FAILS" >&2
[ "$FAILS" = 0 ]
