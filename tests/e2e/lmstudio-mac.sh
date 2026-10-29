#!/usr/bin/env bash
# Opt-in end-to-end check of LM Studio as a runtime DevOS ADE installs, runs and watches itself on an Apple-silicon Mac
# (JON-829; run by hand, not part of tests/run.sh, CI or tests/e2e/run.sh). This checkout's code on a scratch .env and
# state folder: the llmster archive catalog/runtimes.pins names is downloaded from lmstudio.ai, checked against its pinned
# SHA-512, installed by its own bootstrap into the scratch stack's folder (its own HOME: your ~/.lmstudio is not touched)
# and run as a launchd user agent of the scratch stack (a label of its own; the trap removes it). LM Studio is not open
# source: running this accepts its terms (lmstudio.ai/app-terms), so it asks for --accept-terms. Checks: 1 install:
# running, the agent's plist, as this user, its gate on 127.0.0.1:11439 and LM Studio's own server on another port of
# 127.0.0.1, ~/.lmstudio untouched; 2 the gate: nothing without the key, nothing for another name (DNS rebinding),
# nothing of LM Studio's API but the OpenAI-compatible one (no model download), no CORS for a foreign page; 3 a small GGUF model downloaded the way Settings does it, handed to LM Studio by link, answered
# by the key LM Studio gave it, listed as loaded, then removed; 4 llmster killed: launchd starts it again and the watch
# records it; 5 Stop: no agent, no llmster, nothing on 11439; Start: it answers again; 6 its log; 7 Uninstall: its
# folder, its models, the plist, the port and every process of it gone.
# Needs: an Apple-silicon Mac, 127.0.0.1:11439 free, outbound access to llmster.lmstudio.ai (and huggingface.co for check
# 3), about 3 GB of disk.
#   --accept-terms   required: LM Studio's terms (lmstudio.ai/app-terms) apply to what this downloads
#   --no-model       skip check 3 (no model download)        --out DIR   where the summary goes (tests/e2e/out)
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/tests/e2e/out"; MODEL=1; TERMS=0
REPO=bartowski/SmolLM2-135M-Instruct-GGUF; QUANT=Q4_K_M
while [ $# -gt 0 ]; do
  case "$1" in
    --accept-terms) TERMS=1; shift ;;
    --no-model) MODEL=0; shift ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/lmstudio-mac.sh --help)" >&2; exit 2 ;;
  esac
done
say() { printf '==> %s\n' "$*" >&2; }
FAILS=0; CHECKS=()
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$*"); }
ok() { printf 'ok    %s\n' "$*" >&2; CHECKS+=("ok	$*"); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }
[ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || { echo "this check is for an Apple-silicon Mac (LM Studio has no Intel-Mac build; DevOS ADE does not run it on Linux)" >&2; exit 2; }
[ "$TERMS" = 1 ] || { echo "LM Studio is not open source: this downloads it, which accepts its terms (lmstudio.ai/app-terms). Run again with --accept-terms." >&2; exit 2; }
WORK="$ROOT/tests/e2e/work/bne2e-lmstudio"; API=http://127.0.0.1:11439
cleanup() {
  local rc=$?
  if [ -n "${STATE_DIR:-}" ] && declare -F _rt_agent_down >/dev/null; then
    _rt_agent_down lmstudio >/dev/null 2>&1; rm -f "$(rt_plist lmstudio)"
  fi
  { [ "$rc" = 0 ] && [ "$FAILS" = 0 ]; } || { [ ! -d "$WORK/state/runtimes" ] || { mkdir -p "$OUT" && tail -n 200 "$WORK/state/runtimes/lmstudio/server.log" > "$OUT/lmstudio-mac.log" 2>/dev/null; }; }
  rm -rf "$WORK"
  mkdir -p "$OUT" 2>/dev/null && printf '%s\n' ${CHECKS[@]+"${CHECKS[@]}"} | python3 -I -c 'import json, sys
print(json.dumps({"failures": int(sys.argv[1]), "checks": [dict(zip(("status", "check"), l.rstrip("\n").split("\t", 1))) for l in sys.stdin if "\t" in l]}, indent=1))' "$FAILS" > "$OUT/lmstudio-mac.json" 2>/dev/null
}
trap cleanup EXIT; trap 'exit 130' INT TERM
rm -rf "$WORK"; mkdir -p "$WORK/state" "$OUT"

# --- this checkout's code, on a scratch .env and state dir (never an installed stack) ---
STACK_DIR="$ROOT"; ENV_FILE="$WORK/.env"; STATE_DIR="$WORK/state"; printf 'LOCAL_RUNTIME=lmstudio\n' > "$ENV_FILE"
export STACK_DIR ENV_FILE STATE_DIR
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
config_apply() { _cfg_write; CFG_ORDER=''; }   # (.env only: there is no model gateway here to reload)
export ASSUME_YES=1
agent_pid() { _rt_launchd lmstudio | awk '$1 == "pid" && $2 == "=" { print $3; exit }'; }
# tree PID -> PID and every process under it
tree() { ps -A -o pid=,ppid= | awk -v r="$1" '{ p[$1] = $2 } END { for (x in p) { y = x; while (y != "" && y != r && y != 1 && y != 0) y = p[y]; if (y == r) print x } }'; }
answers() { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 -H @"$WORK/state/runtimes/lmstudio/etc/auth.hdr" "$API/v1/models")" = 200 ]; }
not() { ! "$@"; }
wait_for() { local n=0 max="$1"; shift; while [ "$n" -lt "$max" ]; do "$@" && return 0; sleep 1; n=$((n + 1)); done; return 1; }
status_json() { rt_status_write; python3 -I -c "$1" "$(rt_status_file)"; }
code() { curl -s -o /dev/null -w '%{http_code}' -m 10 "$@"; }
WORKR="$(cd "$WORK" && pwd -P)"   # (llmster's recorded place is resolved)
mine() { pgrep -f "$WORKR/state/runtimes/lmstudio" >/dev/null; }   # (a process of it: its program is in the scratch folder)
LMS_BEFORE="$(ls -la "$HOME/.lmstudio" 2>/dev/null | sed 1d; stat -f %m "$HOME/.lmstudio" 2>/dev/null)"

# --- 0: something on its port is never installed over ---
if [ "$(code "$API/v1/models")" != 000 ]; then
  check "0 what answers on 11439 is not this stack's" [ "$(rt_state lmstudio)" = external ]
  if ( rt_install lmstudio ) > "$WORK/install.log" 2>&1; then fail "0 install went ahead over it"
  else check "0 install refuses to go over it" grep "not DevOS ADE's already answers" "$WORK/install.log"; fi
  echo "something already answers on 127.0.0.1:11439: checks 1-7 need the port free" >&2
  exit 2
fi
PIN="$(rt_pin LMSTUDIO_VERSION)"

# --- 1: install ---
say "installing LM Studio $PIN (download about 615 MB, SHA-512, unpack, its bootstrap, launchd)"
if ! ( rt_install lmstudio ) > "$WORK/install.log" 2>&1; then
  fail "1 install: $(tail -n 3 "$WORK/install.log" | tr '\n' ' ')"; exit 1
fi
D="$(rt_dir lmstudio)"; H="$(rt_lmstudio_home)"
check "1 it is running" [ "$(rt_state lmstudio)" = running ]
check "1 it is the pinned version ($PIN)" [ "$(rt_installed_version lmstudio)" = "$PIN" ]
check "1 its lms and llmster are in the stack's folder" sh -c '[ -x "$1/bin/lms" ] && [ -s "$2/llmster.run" ]' _ "$H" "$D"
check "1 the agent's plist is this stack's, mode 600" [ "$(stat -f %Lp "$(rt_plist lmstudio)" 2>/dev/null)" = 600 ]
PID="$(agent_pid)"
check "1 launchd runs it (pid ${PID:-none})" [ -n "$PID" ]
check "1 as this user, not root" [ "$(ps -o user= -p "${PID:-0}" 2>/dev/null | tr -d ' ')" = "$(id -un)" ]
PIDS="$(tree "${PID:-0}" | paste -sd, -)"
LISTEN="$(lsof -nP -a -p "${PIDS:-0}" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u | tr '\n' ' ')"
check "1 its gate listens on 127.0.0.1:11439 ($LISTEN)" grep -F "127.0.0.1:11439 " <<< "$LISTEN"
BPORT="$(sed -n "s/^lmstudio-agent: LM Studio's server on 127\.0\.0\.1:\([0-9]*\),.*/\1/p" "$D/server.log" 2>/dev/null | tail -n 1)"
check "1 LM Studio's own server is on another port of 127.0.0.1 (${BPORT:-none})" sh -c '[ -n "$1" ] && [ "$1" != 11439 ] && grep -F "127.0.0.1:$1 " <<EOF >/dev/null
$2
EOF' _ "$BPORT" "$LISTEN"
check "1 nothing of it listens beyond this computer ($LISTEN)" not grep -vE '^(127\.0\.0\.1|\[::1\]):[0-9]+$' <(tr ' ' '\n' <<< "$LISTEN" | sed '/^$/d')
check "1 your ~/.lmstudio is untouched" [ "$(ls -la "$HOME/.lmstudio" 2>/dev/null | sed 1d; stat -f %m "$HOME/.lmstudio" 2>/dev/null)" = "$LMS_BEFORE" ]

# --- 2: the gate ---
HDR="$D/etc/auth.hdr"
check "2 a request without the key is refused" [ "$(code "$API/v1/models")" = 401 ]
check "2 with the key it is answered" [ "$(code -H @"$HDR" "$API/v1/models")" = 200 ]
check "2 a request for another name (DNS rebinding) is refused, with the key too" [ "$(code -H @"$HDR" -H 'Host: rebind.example:11439' "$API/v1/models")" = 403 ]
check "2 LM Studio's model download is not reachable, with the key too" [ "$(code -X POST -H @"$HDR" -H 'Content-Type: application/json' -d '{}' "$API/api/v1/models/download")" = 403 ]
check "2 nor its log" [ "$(code -H @"$HDR" "$API/api/v1/log/entries")" = 403 ]
check "2 a foreign web page is not allowed to read its answers (CORS)" \
  not grep -iE '^access-control-allow-origin: *(\*|https://rebind\.example)' <(curl -s -D - -o /dev/null -m 10 -H 'Origin: https://rebind.example' -H @"$HDR" "$API/v1/models")
say "note: LM Studio's own server on 127.0.0.1:${BPORT:-?} has no key (LM Studio makes keys only in its app): docs/security.md"

# --- 3: a model, downloaded the way Settings does it, answered, listed as loaded, removed ---
if [ "$MODEL" = 1 ]; then
  say "downloading $REPO $QUANT (about 100 MB) the way Settings does"
  if ( local_pull "$REPO" "$QUANT" --context 8192 --tools no ) > "$WORK/pull.log" 2>&1; then
    ok "3 the download finished"
    ID="$REPO:$QUANT"; KEY="$(rt_lmstudio_key "$ID")"
    check "3 LM Studio gave it a key ($KEY)" [ -n "$KEY" ]
    check "3 LM Studio has it by link, not a copy" sh -c '[ -n "$(find "$1/models" -type l -name "*.gguf" 2>/dev/null)" ] && [ -z "$(find "$1/models" -type f -name "*.gguf" 2>/dev/null)" ]' _ "$H"
    check "3 LOCAL_MODELS has it" grep -F "lmstudio:$ID" "$ENV_FILE"
    check "3 the gateway's entry names it by its key" grep -F "model: \"openai/$KEY\"" <(LOCAL_MODELS="lmstudio:$ID" local_models_yaml)
    check "3 the gateway's entry carries the gate's key" grep -F "api_key: \"$(rt_api_key lmstudio)\"" <(LOCAL_MODELS="lmstudio:$ID" local_models_yaml)
    curl -s -m 300 -H @"$HDR" -H 'Content-Type: application/json' "$API/v1/chat/completions" \
      -d "{\"model\":\"$KEY\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":4}" > "$WORK/chat.json" 2>&1
    check "3 it answers a chat completion through the gate (loaded on its first request)" python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["choices"][0]["message"], d' "$WORK/chat.json"
    check "3 it is listed as loaded" status_json 'import json, sys
r = [x for x in json.load(open(sys.argv[1]))["runtimes"] if x["id"] == "lmstudio"][0]
assert [m for m in r["loaded"] if m["name"] == sys.argv[2]], r["loaded"]' "$KEY"
    check "3 ./stack runtimes status says so" grep -F "loaded: $KEY" <(cmd_runtimes status 2>&1)
    ( local_rm "$REPO" "$QUANT" ) > "$WORK/rm.log" 2>&1
    check "3 Remove: its files are gone" [ -z "$(ls "$D/hub" 2>/dev/null)" ]
    check "3 Remove: LM Studio no longer lists it" not grep -F "\"$KEY\"" <(_rt_lms ls --json 2>/dev/null)
    check "3 Remove: not in models.tsv" [ ! -s "$(rt_lmstudio_models)" ]
  else
    fail "3 the download: $(tail -n 3 "$WORK/pull.log" | tr '\n' ' ')"
  fi
fi

# --- 4: llmster ends by itself: launchd starts it again, the watch records it ---
say "ending llmster (kill -9): launchd should start it again"
runtimes_watch
PID="$(agent_pid)"
kill -9 $(pgrep -P "${PID:-0}" 2>/dev/null) 2>/dev/null
restarted() { local p; p="$(agent_pid)"; [ -n "$p" ] && [ "$p" != "$PID" ] && answers; }
check "4 launchd started it again (within 90 s)" wait_for 90 restarted
runtimes_watch
check "4 the watch recorded it for Activity" grep "	lmstudio	restart	" "$(rt_events_file)"

# --- 5: Stop and Start ---
( rt_stop lmstudio ) > "$WORK/stop.log" 2>&1
check "5 Stop: it is stopped" [ "$(rt_state lmstudio)" = stopped ]
check "5 Stop: no plist (a login does not start it)" [ ! -e "$(rt_plist lmstudio)" ]
sleep 12
check "5 Stop: nothing answers on 11439, 12 s later" not answers
check "5 Stop: no llmster left running" not mine
( rt_start lmstudio ) > "$WORK/start.log" 2>&1
check "5 Start: it answers again" [ "$(rt_state lmstudio)" = running ]

# --- 6: its log ---
check "6 its log says where it listens" grep "11439" <(rt_logs_text lmstudio 400)

# --- 7: Uninstall ---
PL="$(rt_plist lmstudio)"
( rt_uninstall lmstudio ) > "$WORK/uninstall.log" 2>&1
check "7 Uninstall: its folder and models are gone" [ ! -e "$D" ]
check "7 Uninstall: no plist" [ ! -e "$PL" ]
check "7 Uninstall: no agent" not _rt_agent_loaded lmstudio
check "7 Uninstall: nothing answers on 11439" not answers
check "7 Uninstall: no process of it left" not mine
check "7 Uninstall: the state is not installed" [ "$(rt_state lmstudio)" = not-installed ]

printf '\n%d checks, %d failed\n' "${#CHECKS[@]}" "$FAILS" >&2
[ "$FAILS" = 0 ]
