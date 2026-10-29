#!/usr/bin/env bash
# Opt-in end-to-end check of llama.cpp as a runtime DevOS ADE installs, runs and watches itself on a Mac (JON-829; run by
# hand, not part of tests/run.sh, CI or tests/e2e/run.sh). This checkout's code on a scratch .env and state folder: the
# llama.cpp build catalog/runtimes.pins names is downloaded from GitHub, checked against its pinned SHA-256 and run as a
# launchd user agent of the scratch stack (a label of its own; the trap removes it). Checks: 1 install: running, the
# pinned build, the agent's plist, 127.0.0.1 only, as this user, no web UI; 2 its key: no request without it (another
# name, a foreign web page), and a page cannot read its answers; 3 a small GGUF model downloaded the way Settings does it
# (checked, pinned to the commit, into presets.ini), answered with the key, listed as loaded, then removed; 4 llama.cpp
# killed: launchd starts it again and the watch records it (Activity); 5 Stop: no agent, nothing on 11438, and it stays
# down; Start: it answers again; 6 its log; 7 Uninstall: its folder, its models, its key, the plist and the port gone.
# Needs: a Mac, 127.0.0.1:11438 free, outbound access to github.com (and huggingface.co for check 3), about 150 MB of disk.
#   --no-model   skip check 3 (no model download)        --out DIR   where the summary goes (tests/e2e/out)
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/tests/e2e/out"; MODEL=1
REPO=bartowski/SmolLM2-135M-Instruct-GGUF; QUANT=Q4_K_M
while [ $# -gt 0 ]; do
  case "$1" in
    --no-model) MODEL=0; shift ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/llamacpp-mac.sh --help)" >&2; exit 2 ;;
  esac
done
say() { printf '==> %s\n' "$*" >&2; }
FAILS=0; CHECKS=()
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$*"); }
ok() { printf 'ok    %s\n' "$*" >&2; CHECKS+=("ok	$*"); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }
[ "$(uname -s)" = Darwin ] || { echo "this check is for a Mac (Linux runs llama.cpp as a container: tests/test_llamacpp.sh)" >&2; exit 2; }
WORK="$ROOT/tests/e2e/work/bne2e-llamacpp"; API=http://127.0.0.1:11438
cleanup() {
  local rc=$?
  if [ -n "${STATE_DIR:-}" ] && declare -F _rt_agent_down >/dev/null; then
    _rt_agent_down llamacpp >/dev/null 2>&1; rm -f "$(rt_plist llamacpp)"
  fi
  { [ "$rc" = 0 ] && [ "$FAILS" = 0 ]; } || { [ ! -d "$WORK/state/runtimes" ] || { mkdir -p "$OUT" && tail -n 200 "$WORK/state/runtimes/llamacpp/server.log" > "$OUT/llamacpp-mac.log" 2>/dev/null; }; }
  rm -rf "$WORK"
  mkdir -p "$OUT" 2>/dev/null && printf '%s\n' ${CHECKS[@]+"${CHECKS[@]}"} | python3 -I -c 'import json, sys
print(json.dumps({"failures": int(sys.argv[1]), "checks": [dict(zip(("status", "check"), l.rstrip("\n").split("\t", 1))) for l in sys.stdin if "\t" in l]}, indent=1))' "$FAILS" > "$OUT/llamacpp-mac.json" 2>/dev/null
}
trap cleanup EXIT; trap 'exit 130' INT TERM
rm -rf "$WORK"; mkdir -p "$WORK/state" "$OUT"

# --- this checkout's code, on a scratch .env and state dir (never an installed stack) ---
STACK_DIR="$ROOT"; ENV_FILE="$WORK/.env"; STATE_DIR="$WORK/state"; printf 'LOCAL_RUNTIME=llamacpp\n' > "$ENV_FILE"
export STACK_DIR ENV_FILE STATE_DIR
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
config_apply() { _cfg_write; CFG_ORDER=''; }   # (.env only: there is no model gateway here to reload)
export ASSUME_YES=1
agent_pid() { _rt_launchd llamacpp | awk '$1 == "pid" && $2 == "=" { print $3; exit }'; }
answers() { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$API/health")" = 200 ]; }
not() { ! "$@"; }
wait_for() { local n=0 max="$1"; shift; while [ "$n" -lt "$max" ]; do "$@" && return 0; sleep 1; n=$((n + 1)); done; return 1; }
status_json() { rt_status_write; python3 -I -c "$1" "$(rt_status_file)"; }
code() { curl -s -o /dev/null -w '%{http_code}' -m 10 "$@"; }

# --- 0: something on its port is never installed over ---
if [ "$(code "$API/health")" != 000 ]; then
  check "0 what answers on 11438 is not this stack's" [ "$(rt_state llamacpp)" = external ]
  if ( rt_install llamacpp ) > "$WORK/install.log" 2>&1; then fail "0 install went ahead over it"
  else check "0 install refuses to go over it" grep "not DevOS ADE's already answers" "$WORK/install.log"; fi
  echo "something already answers on 127.0.0.1:11438: checks 1-7 need the port free" >&2
  exit 2
fi
PIN="$(rt_pin LLAMACPP_VERSION)"; BUILD="$(rt_pin LLAMACPP_BUILD)"

# --- 1: install ---
say "installing llama.cpp $PIN ($BUILD: download, SHA-256, unpack, launchd)"
if ! ( rt_install llamacpp ) > "$WORK/install.log" 2>&1; then
  fail "1 install: $(tail -n 3 "$WORK/install.log" | tr '\n' ' ')"; exit 1
fi
D="$(rt_dir llamacpp)"; HDR="$D/etc/auth.hdr"
check "1 it is running" [ "$(rt_state llamacpp)" = running ]
check "1 it is the pinned build ($BUILD)" grep "${BUILD#b}" <("$D/bin/llama-server" --version 2>&1)
check "1 the agent's plist is this stack's, mode 600" [ "$(stat -f %Lp "$(rt_plist llamacpp)" 2>/dev/null)" = 600 ]
check "1 its key is in a folder of its own, mode 600, and never in the plist" \
  sh -c '[ "$(stat -f %Lp "$1/etc")" = 700 ] && [ "$(stat -f %Lp "$1/etc/api-key")" = 600 ] && ! grep -F "$(cat "$1/etc/api-key")" "$2" >/dev/null' _ "$D" "$(rt_plist llamacpp)"
PID="$(agent_pid)"
check "1 launchd runs it (pid ${PID:-none})" [ -n "$PID" ]
check "1 as this user, not root" [ "$(ps -o user= -p "${PID:-0}" 2>/dev/null | tr -d ' ')" = "$(id -un)" ]
LISTEN="$(lsof -nP -a -p "${PID:-0}" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u | tr '\n' ' ')"
check "1 it listens on 127.0.0.1:11438 alone ($LISTEN)" [ "$LISTEN" = "127.0.0.1:11438 " ]
check "1 no web UI (/ is not its web app)" not grep -i '<html' <(curl -s -m 10 -H @"$HDR" "$API/")

# --- 2: nothing without its key; a web page cannot read it ---
check "2 a request without the key is refused" [ "$(code "$API/v1/models")" = 401 ]
check "2 with the key it is answered" [ "$(code -H @"$HDR" "$API/v1/models")" = 200 ]
check "2 a request for another name (DNS rebinding) without the key is refused" [ "$(code -H 'Host: rebind.example:11438' "$API/v1/models")" = 401 ]
check "2 a foreign web page is not allowed to read its answers (CORS)" \
  not grep -iE '^access-control-allow-origin: *(\*|https://rebind\.example)' <(curl -s -D - -o /dev/null -m 10 -H 'Origin: https://rebind.example' -H @"$HDR" "$API/v1/models")

# --- 3: a model, downloaded the way Settings does it, answered, listed as loaded, removed ---
if [ "$MODEL" = 1 ]; then
  say "downloading $REPO $QUANT (about 100 MB) the way Settings does"
  if ( local_pull "$REPO" "$QUANT" --context 8192 --tools no ) > "$WORK/pull.log" 2>&1; then
    ok "3 the download finished"
    ID="$REPO:$QUANT"
    check "3 presets.ini names it" grep -F "[$ID]" "$D/etc/presets.ini"
    check "3 LOCAL_MODELS has it" grep -F "llamacpp:$ID" "$ENV_FILE"
    curl -s -m 300 -H @"$HDR" -H 'Content-Type: application/json' "$API/v1/chat/completions" \
      -d "{\"model\":\"$ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":4}" > "$WORK/chat.json" 2>&1
    check "3 it answers a chat completion with the key" python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["choices"][0]["message"], d' "$WORK/chat.json"
    check "3 it is listed as loaded" status_json 'import json, sys
r = [x for x in json.load(open(sys.argv[1]))["runtimes"] if x["id"] == "llamacpp"][0]
assert [m for m in r["loaded"] if m["name"] == sys.argv[2]], r["loaded"]' "$ID"
    check "3 ./stack runtimes status says so" grep -F "loaded: $ID" <(cmd_runtimes status 2>&1)
    ( local_rm "$REPO" "$QUANT" ) > "$WORK/rm.log" 2>&1
    check "3 Remove: its files are gone" [ -z "$(ls "$D/hub" 2>/dev/null)" ]
    check "3 Remove: presets.ini no longer names it" not grep -F "[$ID]" "$D/etc/presets.ini"
  else
    fail "3 the download: $(tail -n 3 "$WORK/pull.log" | tr '\n' ' ')"
  fi
fi

# --- 4: it ends by itself: launchd starts it again, the watch records it ---
say "ending llama.cpp (kill -9): launchd should start it again"
runtimes_watch
PID="$(agent_pid)"
kill -9 "${PID:-0}" 2>/dev/null
restarted() { local p; p="$(agent_pid)"; [ -n "$p" ] && [ "$p" != "$PID" ] && answers; }
check "4 launchd started it again (within 30 s)" wait_for 30 restarted
runtimes_watch
check "4 the watch recorded it for Activity" grep "	llamacpp	restart	" "$(rt_events_file)"

# --- 5: Stop and Start ---
( rt_stop llamacpp ) > "$WORK/stop.log" 2>&1
check "5 Stop: it is stopped" [ "$(rt_state llamacpp)" = stopped ]
check "5 Stop: no plist (a login does not start it)" [ ! -e "$(rt_plist llamacpp)" ]
sleep 12
check "5 Stop: nothing answers on 11438, 12 s later" not answers
( rt_start llamacpp ) > "$WORK/start.log" 2>&1
check "5 Start: it answers again" [ "$(rt_state llamacpp)" = running ]

# --- 6: its log ---
check "6 its log says where it listens" grep "11438" <(rt_logs_text llamacpp 400)

# --- 7: Uninstall ---
PL="$(rt_plist llamacpp)"
( rt_uninstall llamacpp ) > "$WORK/uninstall.log" 2>&1
check "7 Uninstall: its folder, models and key are gone" [ ! -e "$D" ]
check "7 Uninstall: no plist" [ ! -e "$PL" ]
check "7 Uninstall: no agent" not _rt_agent_loaded llamacpp
check "7 Uninstall: nothing answers on 11438" not answers
check "7 Uninstall: the state is not installed" [ "$(rt_state llamacpp)" = not-installed ]

printf '\n%d checks, %d failed\n' "${#CHECKS[@]}" "$FAILS" >&2
[ "$FAILS" = 0 ]
