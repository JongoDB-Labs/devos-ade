# shellcheck shell=bash
# Model runtimes as core services (JON-829): the local-model runtimes DevOS ADE installs, starts, stops, updates and
# watches itself, on the same footing as its containers (Settings › Models & providers › Local models › Runtimes, Home,
# Activity, ./stack runtimes): Ollama and llama.cpp.
#
#   macOS   Ollama's own release build (github.com/ollama/ollama, ollama-darwin.tgz: the version and its SHA-256 pinned in
#           catalog/runtimes.pins, checked before anything is unpacked) in .state/runtimes/ollama/bin, run as a launchd
#           user agent of this stack: natively, so on the GPU (Metal), on 127.0.0.1:11434 only, its models in
#           .state/runtimes/ollama/models, its own HOME there too, Ollama's cloud features off. The plist is there only
#           while it should run (install, start, ./stack up): Stop and ./stack down remove it, so a login does not start
#           it again. launchd starts it again when it ends by itself; the update helper notices (Activity).
#   Linux   Ollama's image (compose.yaml, pinned by digest) as the stack's "ollama" service, in the "ollama" profile while
#           it is installed: on an internal network with the model gateway alone (which reaches it as ollama:11434),
#           its models in the ollama-models volume. Its gate, "ollama-gate" (caddy/ollama-gate.caddy), publishes it on
#           127.0.0.1:11434 alone and lets only loopback names through, as a native Ollama does. compose.ollama-gpu.yaml
#           gives it the NVIDIA GPUs when Docker had the NVIDIA runtime at install. Container health (lib/health.sh)
#           watches both like the others.
#
# An Ollama that already answers on 127.0.0.1:11434 and is not this stack's is "yours": downloads can go to it as they
# did before (LOCAL_RUNTIME), and it is never installed over, stopped or removed.
#
# llama.cpp (github.com/ggml-org/llama.cpp): llama-server in router mode, one server for every model downloaded to it
# (Settings › Local models, lib/local_models.sh: the GGUF files of a quantization, checked against the Hub's hashes),
# each a section of etc/presets.ini named as the model gateway asks for it; it loads a model at its first request and
# unloads the oldest past two. Every request but /health needs its API key (etc/api-key, made at install: the model
# gateway's config has it), it serves no web UI, and it downloads nothing itself.
#   macOS   the release's own build for this Mac (llama-<build>-bin-macos-arm64|x64.tar.gz: pinned with its SHA-256 in
#           catalog/runtimes.pins) in .state/runtimes/llamacpp/bin, a launchd user agent like Ollama's, on 127.0.0.1:11438.
#   Linux   its image (compose.yaml "llamacpp", pinned by digest; the CUDA one with compose.llamacpp-gpu.yaml) on an
#           internal network with the model gateway alone, which reaches it as llamacpp:8080: it publishes nothing and
#           reaches nothing. It runs as you (rootless Docker: its root), read-only, the models and etc/ mounted read-only.
#
#   ./stack runtimes [status]           each runtime: state, version, address, models loaded, memory in use
#   ./stack runtimes install ID         download it (pinned, hash-checked) and start it (asks first in a terminal)
#   ./stack runtimes start | stop ID
#   ./stack runtimes uninstall ID       stop it and delete it with its downloaded models (asks first in a terminal)
#   ./stack runtimes cancel             stop an install that is running (what arrived is kept for the next one)
#   ./stack runtimes logs ID [N]        its last N log lines (200)
#
# Files: .state/runtimes/<id>/ (installed: the version installed; gpu; watch: what the helper last saw), .state/runtimes/
# job.json (the one install, start, stop or uninstall running), events.tsv (what happened, for Activity), and the
# portal's read-only copy .state/status/runtimes.json (Settings, Home, Activity).

RUNTIME_IDS="ollama llamacpp"
RT_LLAMACPP_MODELS_MAX=2               # models llama.cpp keeps loaded at once (the oldest is unloaded)
RT_LLAMACPP_CTX=8192                   # a model's context when its own is not known (at most 32768)
RT_EVENTS_MAX=30                       # events kept for Activity
RT_LOG_MAX=$((10 * 1024 * 1024))       # a server log this big is moved aside at the next start
RT_LOG_LINES=200                       # the lines Logs shows

valid_runtime_id() { case " $RUNTIME_IDS " in *" ${1:-x} "*) return 0 ;; esac; return 1; }
rt_name() { case "$1" in ollama) echo Ollama ;; llamacpp) echo llama.cpp ;; *) echo "$1" ;; esac; }
rt_os() { case "$(uname -s)" in Darwin) echo mac ;; Linux) echo linux ;; *) echo other ;; esac; }
rt_root() { printf '%s/runtimes\n' "$STATE_DIR"; }
rt_dir() { printf '%s/%s\n' "$(rt_root)" "$1"; }
rt_job_file() { printf '%s/job.json\n' "$(rt_root)"; }
rt_events_file() { printf '%s/events.tsv\n' "$(rt_root)"; }
rt_status_file() { printf '%s/runtimes.json\n' "$(status_dir)"; }
# rt_pin NAME -> a value of catalog/runtimes.pins (ARG NAME=value)
rt_pin() { sed -n "s/^ARG $1=\\([^[:space:]]*\\).*/\\1/p" "$STACK_DIR/catalog/runtimes.pins" 2>/dev/null | head -n 1 || true; }
# GitHub's address for the downloads (tests point it at a stand-in on this computer)
_rt_github() { printf '%s\n' "${RUNTIMES_GITHUB:-https://github.com}"; }
rt_port() { case "$1" in ollama) echo 11434 ;; llamacpp) echo 11438 ;; esac; }
# rt_pinned_version ID -> the version this release pins (macOS: catalog/runtimes.pins; Linux: compose.yaml's image —
# llama.cpp's image names its build, the pins say which release that is)
rt_pinned_version() {
  case "$1" in
    llamacpp) rt_pin LLAMACPP_VERSION ;;
    *) if [ "$(rt_os)" = linux ]; then awk '!f && /^ *image: ollama\/ollama:/ { sub(/.*ollama\/ollama:/, ""); sub(/@.*/, ""); print; f = 1 }' "$STACK_DIR/compose.yaml"
       else rt_pin OLLAMA_VERSION; fi ;;
  esac
}
# rt_address ID -> where it answers (llama.cpp on Linux: the model gateway's network only)
rt_address() {
  if [ "$1" = llamacpp ] && [ "$(rt_os)" = linux ]; then echo "llamacpp:8080 (the model gateway's network only)"
  else printf '127.0.0.1:%s\n' "$(rt_port "$1")"; fi
}
# rt_installed ID -> 0 when this stack installed it (and has not removed it)
rt_installed() { [ -s "$(rt_dir "$1")/installed" ]; }
rt_installed_version() { [ -s "$(rt_dir "$1")/installed" ] || return 0; head -n 1 "$(rt_dir "$1")/installed" | LC_ALL=C tr -cd '0-9A-Za-z.+-' | cut -c1-40; }
# _rt_bytes FILE -> its size (0: there is none)
_rt_bytes() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
# rt_kind ID -> how it runs here: agent (a launchd user agent: macOS), container (compose: Linux), none
rt_kind() { case "$(rt_os)" in mac) echo agent ;; linux) echo container ;; *) echo none ;; esac; }
# rt_size ID -> what an install downloads, in words (the dialog says it before anything starts)
rt_size() {
  case "$1:$(rt_os)" in
    ollama:mac) echo "about 180 MB" ;;
    llamacpp:mac) [ "$(uname -m)" = arm64 ] && echo "about 16 MB" || echo "about 12 MB" ;;
    llamacpp:*) echo "about 290 MB (its image; about 2.4 GB with NVIDIA's libraries)" ;;
    *) case "$(uname -m)" in aarch64 | arm64) echo "about 2.8 GB (its image)" ;; *) echo "about 3.4 GB (its image, with NVIDIA's libraries)" ;; esac ;;
  esac
}
# rt_why_not ID -> why it cannot run on this computer (nothing: it can)
rt_why_not() {
  case "$(rt_os)" in
    mac) [ "$(uname -m)" = arm64 ] || [ "$(uname -m)" = x86_64 ] || echo "this Mac's processor is not one $(rt_name "$1") builds for" ;;
    linux) command -v docker >/dev/null 2>&1 || echo "it runs as a container here, and Docker is not installed" ;;
    *) echo "DevOS ADE runs it on macOS and Linux only" ;;
  esac
}

# --- what answers ---
# _rt_version ID -> what answers on its address says it is (its version; nothing: nothing answers there)
_rt_version() { case "$1" in ollama) _rt_ollama_version ;; llamacpp) _rt_llamacpp_version ;; esac; }
# _rt_ps ID -> the models it has loaded now, one per line: name TAB bytes TAB bytes in GPU memory (0: not known)
_rt_ps() { case "$1" in ollama) _rt_ollama_ps ;; llamacpp) _rt_llamacpp_ps ;; esac; }
# _rt_ollama_version -> the version the Ollama on 127.0.0.1:11434 says (nothing: none answers)
_rt_ollama_version() {
  curl -s -m 3 "$(_local_ollama_url)/api/version" 2>/dev/null | sed -n 's/.*"version" *: *"\([0-9A-Za-z.+-]*\)".*/\1/p' | head -n 1 | cut -c1-40 || true
}
# _rt_ollama_ps -> the models loaded now, one per line: name TAB bytes TAB bytes in GPU memory (read as JSON: each model's
# "details" is an object of its own, and size_vram comes after it; a name keeps only the characters a model name has)
_rt_ollama_ps() {
  curl -s -m 3 "$(_local_ollama_url)/api/ps" 2>/dev/null | python3 -I -c '
import json, re, sys
try:
    ms = json.load(sys.stdin).get("models") or []
except Exception:
    ms = []
n0 = lambda x: x if isinstance(x, int) and not isinstance(x, bool) and x >= 0 else 0
for m in ms if isinstance(ms, list) else []:
    n = re.sub(r"[^A-Za-z0-9._:/@+-]", "", str(m.get("name") or ""))[:160] if isinstance(m, dict) else ""
    if n:
        print("%s\t%d\t%d" % (n, n0(m.get("size")), n0(m.get("size_vram"))))' 2>/dev/null || true
}
_local_llamacpp_url() { printf '%s\n' "${LOCAL_LLAMACPP_URL:-http://127.0.0.1:$(rt_port llamacpp)}"; }
# _rt_llamacpp_version -> the version installed, while a llama.cpp answers (its /health; Linux: its container's health
# check), "unknown" for a server that is not this stack's; nothing while none answers
_rt_llamacpp_version() {
  local code
  if [ "$(rt_os)" = linux ]; then
    rt_installed llamacpp && [ "$(dc ps --format '{{.Health}}' llamacpp 2>/dev/null | head -n 1)" = healthy ] || return 0
  else
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$(_local_llamacpp_url)/health" 2>/dev/null || true)"
    case "$code" in '' | 000) return 0 ;; esac
    rt_installed llamacpp && _rt_agent_loaded llamacpp || { echo unknown; return 0; }
  fi
  rt_installed_version llamacpp
}
# _rt_llamacpp_ps -> the models it has loaded (GET /models, with its key: each model's status), as _rt_ps; their memory
# is not given (0)
_rt_llamacpp_ps() {
  local d; d="$(rt_dir llamacpp)"
  [ -s "$d/etc/auth.hdr" ] || return 0
  if [ "$(rt_os)" = linux ]; then dc exec -T llamacpp curl -s -m 3 -H @/etc/llamacpp/auth.hdr http://127.0.0.1:8080/models </dev/null 2>/dev/null
  else curl -s -m 3 -H @"$d/etc/auth.hdr" "$(_local_llamacpp_url)/models" 2>/dev/null; fi | python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
ms = d.get("data") if isinstance(d, dict) else d
for m in ms if isinstance(ms, list) else []:
    if not isinstance(m, dict):
        continue
    st = m.get("status")
    if (st.get("value") if isinstance(st, dict) else st) != "loaded":
        continue
    n = re.sub(r"[^A-Za-z0-9._:/@+-]", "", str(m.get("id") or m.get("name") or ""))[:160]
    if n:
        print("%s\t0\t0" % n)' 2>/dev/null || true
}

# --- macOS: the launchd user agent ---
rt_label() { printf 'dev.devos.ade.%s.%s\n' "$1" "$(printf '%s' "$STATE_DIR" | cksum | cut -d' ' -f1)"; }
rt_plist() { printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(rt_label "$1")"; }
_rt_launchd() { launchctl print "gui/$(id -u)/$(rt_label "$1")" 2>/dev/null; }
# _rt_agent_field ID FIELD -> FIELD's value in launchctl print (its own lines only, one tab in: pid, runs, last exit code);
# nothing while it is not loaded
_rt_agent_field() { _rt_launchd "$1" | awk -v f="$2" '!n && index($0, "\t" f " = ") == 1 { print substr($0, length(f) + 5); n = 1 }' || true; }
_rt_agent_loaded() { _rt_launchd "$1" >/dev/null; }
_rt_xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
_rt_plist() { case "$1" in ollama) _rt_ollama_plist ;; llamacpp) _rt_llamacpp_plist ;; esac; }
# _rt_program ID -> the program its agent runs
_rt_program() { case "$1" in ollama) echo "$(rt_dir ollama)/bin/ollama" ;; llamacpp) echo "$(rt_dir llamacpp)/bin/llama-server" ;; esac; }
# _rt_folders ID -> the folders of its own its agent needs
_rt_folders() { case "$1" in ollama) echo "models home" ;; llamacpp) echo "home cache hub etc" ;; esac; }
# _rt_ollama_plist -> the agent: 127.0.0.1 only, the stack's own models folder and HOME, cloud features off
_rt_ollama_plist() {
  local d; d="$(_rt_xml "$(rt_dir ollama)")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(rt_label ollama)</string>
<key>ProgramArguments</key><array><string>$d/bin/ollama</string><string>serve</string></array>
<key>EnvironmentVariables</key><dict><key>OLLAMA_HOST</key><string>$(rt_address ollama)</string><key>OLLAMA_MODELS</key><string>$d/models</string><key>OLLAMA_NO_CLOUD</key><string>1</string><key>HOME</key><string>$d/home</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>$d/server.log</string><key>StandardErrorPath</key><string>$d/server.log</string>
</dict></plist>
EOF
}
# _rt_llamacpp_plist -> the agent: router mode on 127.0.0.1 only, its presets and API key, no web UI, CORS for localhost
_rt_llamacpp_plist() {
  local d a='' x; d="$(_rt_xml "$(rt_dir llamacpp)")"
  for x in --host 127.0.0.1 --port "$(rt_port llamacpp)" --models-preset "$d/etc/presets.ini" --api-key-file "$d/etc/api-key" --no-ui \
    --cors-origins localhost --models-max "$RT_LLAMACPP_MODELS_MAX" --models-memory-margin 1024; do a="$a<string>$x</string>"; done
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(rt_label llamacpp)</string>
<key>ProgramArguments</key><array><string>$d/bin/llama-server</string>$a</array>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>$d/home</string><key>LLAMA_CACHE</key><string>$d/cache</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>$d/server.log</string><key>StandardErrorPath</key><string>$d/server.log</string>
</dict></plist>
EOF
}
# _rt_log_rotate ID — a server log past RT_LOG_MAX is moved aside (one old one kept)
_rt_log_rotate() {
  local f; f="$(rt_dir "$1")/server.log"
  [ "$(_rt_bytes "$f")" -le "$RT_LOG_MAX" ] || mv -f "$f" "$f.1" 2>/dev/null || true
}
_rt_agent_up() {
  local id="$1" plist lbl n=0 f; plist="$(rt_plist "$1")"; lbl="$(rt_label "$1")"
  mkdir -p "$HOME/Library/LaunchAgents"
  for f in $(_rt_folders "$id"); do mkdir -p "$(rt_dir "$id")/$f"; done
  _rt_log_rotate "$id"
  _rt_plist "$id" > "$plist.tmp" && chmod 600 "$plist.tmp" && mv -f "$plist.tmp" "$plist" || return 1
  if _rt_agent_loaded "$id"; then
    launchctl bootout "gui/$(id -u)/$lbl" >/dev/null 2>&1 || true
    while _rt_agent_loaded "$id" && [ "$n" -lt 20 ]; do sleep 0.25; n=$((n + 1)); done
  fi
  launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || return 1
}
_rt_agent_down() {
  local n=0 was=0
  ! _rt_agent_loaded "$1" || was=1
  local plist; plist="$(rt_plist "$1")"
  launchctl bootout "gui/$(id -u)/$(rt_label "$1")" >/dev/null 2>&1 || true
  rm -f "$plist"
  [ "$was" = 1 ] || return 0
  while [ -n "$(_rt_version "$1")" ] && [ "$n" -lt 40 ]; do sleep 0.25; n=$((n + 1)); done
}

# --- Linux: the compose service ---
# rt_compose_on ID -> 0 while its container is part of the stack (installed here, on Linux): dc() adds its profile
rt_compose_on() { [ "$(rt_os)" = linux ] && rt_installed "$1"; }
# rt_services ID -> its compose services (Linux): Ollama and its gate; llama.cpp
rt_services() { case "$1" in ollama) echo "ollama ollama-gate" ;; llamacpp) echo llamacpp ;; esac; }
# runtime_services -> the runtime containers ./stack up starts (lib/commands.sh optional_services)
runtime_services() { local id out=''; for id in $RUNTIME_IDS; do ! rt_compose_on "$id" || out="$out${out:+ }$(rt_services "$id")"; done; printf '%s\n' "$out"; }
# runtime_profiles -> the compose profiles of the runtime containers (lib/common.sh dc): each installed one's, and the one
# _RT_PROFILE names (its own pull, rm and logs, before it is installed or after it is not)
runtime_profiles() { local id; for id in $RUNTIME_IDS; do ! { rt_compose_on "$id" || [ "${_RT_PROFILE:-}" = "$id" ]; } || echo "$id"; done; }
# runtime_overlays -> the compose files of their GPUs (lib/common.sh compose_overlays)
runtime_overlays() {
  local id
  for id in $RUNTIME_IDS; do
    # (also while it is being installed: its pull is of the GPU's image)
    { rt_compose_on "$id" || [ "${_RT_PROFILE:-}" = "$id" ]; } || continue
    [ "$(cat "$(rt_dir "$id")/gpu" 2>/dev/null)" != nvidia ] || echo "compose.$id-gpu.yaml"
  done
}
# _rt_volumes ID -> its compose volumes (Linux: deleted with it)
_rt_volumes() { case "$1" in ollama) echo ollama-models ;; esac; }
_rt_container_state() { dc ps -a --format '{{.State}}' "$1" 2>/dev/null | head -n 1 | LC_ALL=C tr -cd 'a-z' | cut -c1-20; }

# --- the state ---
# rt_state ID -> installing | running | starting | stopped | not-installed | external (an Ollama of yours) | unsupported
rt_state() {
  local id="$1" v j
  [ -z "$(rt_why_not "$id")" ] || { echo unsupported; return 0; }
  j="$(cat "$(rt_job_file)" 2>/dev/null || true)"
  if rt_job_running && [ "$(_local_json_str "$j" id)" = "$id" ] && [ "$(_local_json_str "$j" op)" = install ]; then echo installing; return 0; fi
  v="$(_rt_version "$id")"
  if ! rt_installed "$id"; then [ -n "$v" ] && echo external || echo not-installed; return 0; fi
  if [ "$(rt_kind "$id")" = agent ]; then
    if [ -n "$v" ] && _rt_agent_loaded "$id"; then echo running
    elif [ -n "$v" ]; then echo external   # (installed, but what answers is another Ollama: ours cannot start)
    elif [ -f "$(rt_plist "$id")" ] && _rt_agent_loaded "$id"; then echo starting
    else echo stopped; fi
  else
    case "$(_rt_container_state "$id")" in
      running) [ -n "$v" ] && echo running || echo starting ;;
      restarting | created) echo starting ;;
      *) echo stopped ;;
    esac
  fi
}

# --- the job (one at a time: install, start, stop, uninstall) ---
rt_job_running() {
  local pid; pid="$(cat "$(rt_root)/job.pid" 2>/dev/null || true)"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && grep -q '"state":"running"' "$(rt_job_file)" 2>/dev/null
}
# _rt_job STATE ID OP DONE TOTAL MESSAGE — job.json, and the portal's file (STATE: running, done, failed, cancelled)
_rt_job() {
  mkdir -p "$(rt_root)" && chmod 700 "$(rt_root)" 2>/dev/null || true
  printf '{"id":"%s","op":"%s","state":"%s","done_bytes":%s,"total_bytes":%s,"message":%s,"at":%s}\n' \
    "$2" "$3" "$1" "${4:-0}" "${5:-0}" "$(_local_q "$6" 400)" "$(date +%s)" | _local_put "$(rt_job_file)"
  rt_status_write
}
_rt_fail() { _rt_job failed "$1" "$2" 0 0 "$3"; rm -f "$(rt_root)/job.pid"; _rt_event "$1" failed "$3"; die "$3"; }
_rt_begin() {
  ! rt_job_running || die "a runtime job is running: wait for it (./stack runtimes)"
  mkdir -p "$(rt_dir "$1")" && chmod 700 "$(rt_root)" "$(rt_dir "$1")"
  printf '%s\n' "${BASHPID:-$$}" > "$(rt_root)/job.pid"
}
_rt_end() { _rt_job done "$1" "$2" "${4:-0}" "${4:-0}" "$3"; rm -f "$(rt_root)/job.pid"; }
_rt_cancel_file() { printf '%s/cancel\n' "$(rt_root)"; }

# --- events (Activity) ---
# _rt_event ID KIND TEXT — KIND: installed, removed, started, stopped, restart (it ended and launchd started it again), down
# (it stopped answering by itself), up (it answers again), failed (an install, start or stop)
_rt_event() {
  local f tmp; f="$(rt_events_file)"; mkdir -p "$(rt_root)" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$(printf '%s' "$3" | LC_ALL=C tr -d '\t\000-\037\177' | cut -c1-300)" >> "$f"
  tmp="$f.tmp"; tail -n "$RT_EVENTS_MAX" "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
}
# _rt_watch_mark ID — what the helper compares with next (after this stack itself started or stopped it: no event)
_rt_watch_mark() {
  local id="$1"
  printf '%s\t%s\n' "$(rt_state "$id")" "$(_rt_agent_field "$id" runs 2>/dev/null | tr -cd '0-9')" > "$(rt_dir "$id")/watch" 2>/dev/null || true
}
# runtimes_watch — the update helper, every loop: an installed runtime that ended and was started again, stopped
# answering or answers again becomes an event (Activity, Home)
runtimes_watch() {
  local id st runs prev pruns code
  for id in $RUNTIME_IDS; do
    rt_installed "$id" || continue
    [ -d "$(rt_dir "$id")" ] || continue
    ! rt_job_running || continue
    st="$(rt_state "$id")"; runs=''
    [ "$(rt_kind "$id")" != agent ] || runs="$(_rt_agent_field "$id" runs | tr -cd '0-9')"
    prev=''; pruns=''; [ ! -f "$(rt_dir "$id")/watch" ] || IFS=$'\t' read -r prev pruns < "$(rt_dir "$id")/watch" || true
    if [ -n "$runs" ] && [ -n "$pruns" ] && [ "$runs" -gt "$pruns" ] 2>/dev/null; then
      code="$(_rt_agent_field "$id" "last exit code" | LC_ALL=C tr -cd '0-9a-z() -' | cut -c1-40)"
      _rt_event "$id" restart "$(rt_name "$id") ended (exit code ${code:-unknown}) and was started again"
    fi
    case "$prev:$st" in
      running:stopped | running:starting) _rt_event "$id" down "$(rt_name "$id") stopped answering on $(rt_address "$id")" ;;
      stopped:running | starting:running) [ "$(rt_kind "$id")" = container ] || [ -f "$(rt_plist "$id")" ] && _rt_event "$id" up "$(rt_name "$id") answers again on $(rt_address "$id")" ;;
    esac
    printf '%s\t%s\n' "$st" "$runs" > "$(rt_dir "$id")/watch" 2>/dev/null || true
  done
  rt_status_write
}

# --- install ---
_rt_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
# _rt_unpack TGZ DIR -> 0 when the archive holds only plain files, folders and links to a name beside them (no absolute
# path, no .., no link out of DIR, nothing else) and it unpacked into DIR (made here: empty)
_rt_unpack() {
  local tgz="$1" dir="$2" bad
  # (each list read to its end: under pipefail a reader that stops early would end tar with SIGPIPE)
  bad="$(tar -tzf "$tgz" 2>/dev/null | awk '!n && (/^\// || /(^|\/)\.\.(\/|$)/) { print; n = 1 }')" || return 1
  [ -z "$bad" ] || return 1
  bad="$(tar -tvzf "$tgz" 2>/dev/null | awk '
    n { next }
    { t = substr($0, 1, 1) }
    t != "-" && t != "d" && t != "l" { print; n = 1; next }
    t == "l" { i = index($0, " -> "); if (i == 0) { print; n = 1; next } x = substr($0, i + 4); if (x ~ /\// || x == ".." || x == ".") { print; n = 1 } }')" || return 1
  [ -z "$bad" ] || return 1
  rm -rf "$dir" && mkdir -p "$dir" && chmod 700 "$dir" || return 1
  tar -xzf "$tgz" -C "$dir" --no-same-owner 2>/dev/null
}
# _rt_remote_size URL -> the bytes the download will be (0: not known)
_rt_remote_size() {
  local n; n="$(curl -q -sSIL --max-redirs 5 -m 20 "$1" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')"
  case "$n" in '' | *[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}
# _rt_download ID WHAT URL SHA256 PART — GitHub's file into PART (continuing what an earlier one left), checked against
# the pinned SHA-256 (_RT_TOTAL: its size). 1: cancelled (the job says so); a failure ends here (_rt_fail)
_rt_download() {
  local id="$1" what="$2" url="$3" sha="$4" part="$5" d total have rc=0 pid
  d="$(rt_dir "$id")"
  total="$(_rt_remote_size "$url")"
  have="$(_rt_bytes "$part")"
  if [ "$total" -eq 0 ] || [ "$have" -lt "$total" ]; then
    _rt_job running "$id" install "$have" "$total" "Downloading $what from GitHub"
    # (https only, also after GitHub's redirect to its file host; -C -: continues what an earlier one left)
    ( exec curl -q -fsSL --proto '=https' --proto-redir '=https' --max-redirs 5 --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
        --retry 3 -C - -o "$part" "$url" ) </dev/null > "$d/install.log" 2>&1 &
    pid=$!; printf '%s\n' "$pid" > "$(rt_root)/dl.pid"
    while kill -0 "$pid" 2>/dev/null; do
      _rt_job running "$id" install "$(_rt_bytes "$part")" "$total" "Downloading $what from GitHub"
      sleep "${RT_POLL_S:-1}"
    done
    wait "$pid" || rc=$?
    rm -f "$(rt_root)/dl.pid"
    if [ -f "$(_rt_cancel_file)" ]; then
      rm -f "$(_rt_cancel_file)" "$(rt_root)/job.pid"; _rt_job cancelled "$id" install 0 "$total" "Cancelled: what arrived is kept, and the next install continues from it."
      return 1
    fi
    [ "$rc" -eq 0 ] || _rt_fail "$id" install "The download from GitHub stopped (curl exit $rc). Install again: it continues from what arrived."
  fi
  _rt_job running "$id" install "$total" "$total" "Checking it against the SHA-256 this release pins"
  if [ "$(_rt_sha256 "$part")" != "$sha" ]; then
    rm -f "$part"
    _rt_fail "$id" install "What arrived does not match the SHA-256 DevOS ADE pins for $what, so it was deleted and nothing was installed."
  fi
  _RT_TOTAL="$total"
}
# _rt_swap_in ID PART VERSION — bin.new (checked) becomes bin, the agent stopped first; the download deleted
_rt_swap_in() {
  local id="$1" d; d="$(rt_dir "$1")"
  ! _rt_agent_loaded "$id" || _rt_agent_down "$id"
  rm -rf "$d/bin.old"; [ ! -d "$d/bin" ] || mv "$d/bin" "$d/bin.old"
  mv "$d/bin.new" "$d/bin" || _rt_fail "$id" install "Could not move the new $(rt_name "$id") into place (.state/runtimes/$id): nothing was installed."
  rm -rf "$d/bin.old" "$2" "$d/install.log"
  printf '%s\n' "$3" > "$d/installed"
}
_rt_install_ollama_mac() {
  local id=ollama d ver sha url part
  d="$(rt_dir "$id")"; ver="$(rt_pin OLLAMA_VERSION)"; sha="$(rt_pin OLLAMA_SHA256_DARWIN)"
  [[ $ver =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] && [[ $sha =~ ^[0-9a-f]{64}$ ]] || _rt_fail "$id" install "catalog/runtimes.pins has no pin for Ollama"
  url="$(_rt_github)/ollama/ollama/releases/download/v$ver/ollama-darwin.tgz"
  part="$d/ollama-darwin-$ver.tgz.part"
  find "$d" -maxdepth 1 -name 'ollama-darwin-*.tgz.part' ! -name "ollama-darwin-$ver.tgz.part" -exec rm -f {} + 2>/dev/null || true
  _rt_download "$id" "Ollama $ver" "$url" "$sha" "$part" || return 0
  _rt_job running "$id" install "$_RT_TOTAL" "$_RT_TOTAL" "Unpacking it"
  _rt_unpack "$part" "$d/bin.new" || { rm -rf "$d/bin.new"; _rt_fail "$id" install "The archive holds something other than Ollama's files (a path out of its folder): nothing was installed."; }
  [ -f "$d/bin.new/ollama" ] && [ ! -L "$d/bin.new/ollama" ] && [ -x "$d/bin.new/ollama" ] || { rm -rf "$d/bin.new"; _rt_fail "$id" install "The archive has no ollama program: nothing was installed."; }
  _rt_swap_in "$id" "$part" "$ver"
}
_rt_install_llamacpp_mac() {
  local id=llamacpp d ver build arch sha url part
  d="$(rt_dir "$id")"; ver="$(rt_pin LLAMACPP_VERSION)"; build="$(rt_pin LLAMACPP_BUILD)"
  case "$(uname -m)" in arm64) arch=arm64; sha="$(rt_pin LLAMACPP_SHA256_MACOS_ARM64)" ;; *) arch=x64; sha="$(rt_pin LLAMACPP_SHA256_MACOS_X64)" ;; esac
  [[ $ver =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] && [[ $build =~ ^b[0-9]{1,7}$ ]] && [[ $sha =~ ^[0-9a-f]{64}$ ]] || _rt_fail "$id" install "catalog/runtimes.pins has no pin for llama.cpp"
  url="$(_rt_github)/ggml-org/llama.cpp/releases/download/$build/llama-$build-bin-macos-$arch.tar.gz"
  part="$d/llama-$build-bin-macos-$arch.tar.gz.part"
  find "$d" -maxdepth 1 -name 'llama-*.tar.gz.part' ! -name "${part##*/}" -exec rm -f {} + 2>/dev/null || true
  _rt_download "$id" "llama.cpp $ver" "$url" "$sha" "$part" || return 0
  _rt_job running "$id" install "$_RT_TOTAL" "$_RT_TOTAL" "Unpacking it"
  _rt_unpack "$part" "$d/bin.new" || { rm -rf "$d/bin.new"; _rt_fail "$id" install "The archive holds something other than llama.cpp's files (a path out of its folder): nothing was installed."; }
  # (its files are in one folder, llama-<build>: up one level, so the agent's program is bin/llama-server)
  if [ -d "$d/bin.new/llama-$build" ] && [ ! -L "$d/bin.new/llama-$build" ]; then
    { mv "$d/bin.new/llama-$build" "$d/bin.flat" && rm -rf "$d/bin.new" && mv "$d/bin.flat" "$d/bin.new"; } || { rm -rf "$d/bin.new" "$d/bin.flat"; _rt_fail "$id" install "Could not unpack llama.cpp (.state/runtimes/$id): nothing was installed."; }
  fi
  [ -f "$d/bin.new/llama-server" ] && [ ! -L "$d/bin.new/llama-server" ] && [ -x "$d/bin.new/llama-server" ] || { rm -rf "$d/bin.new"; _rt_fail "$id" install "The archive has no llama-server program: nothing was installed."; }
  _rt_llamacpp_etc || _rt_fail "$id" install "Could not write llama.cpp's settings (.state/runtimes/$id/etc): nothing was installed."
  _rt_swap_in "$id" "$part" "$ver"
}
_rt_install_ollama_linux() {
  local id=ollama d; d="$(rt_dir "$id")"
  # (the GPU is decided once, here: dc() must not ask Docker on every call)
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep '"nvidia"' >/dev/null; then echo nvidia > "$d/gpu"; else rm -f "$d/gpu"; fi
  _rt_job running "$id" install 0 0 "Downloading Ollama's image ($(rt_size "$id"))"
  _RT_PROFILE=ollama dc pull -q ollama </dev/null > "$d/install.log" 2>&1 || _rt_fail "$id" install "Docker could not download Ollama's image: $(tail -n 2 "$d/install.log" | LC_ALL=C tr -cd ' -~\n' | tr '\n' ' ' | cut -c1-200)"
  if [ -f "$(_rt_cancel_file)" ]; then rm -f "$(_rt_cancel_file)" "$(rt_root)/job.pid"; _rt_job cancelled "$id" install 0 0 "Cancelled."; return 0; fi
  rt_pinned_version "$id" > "$d/installed"
}
_rt_install_llamacpp_linux() {
  local id=llamacpp d; d="$(rt_dir "$id")"
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep '"nvidia"' >/dev/null; then echo nvidia > "$d/gpu"; else rm -f "$d/gpu"; fi
  _rt_llamacpp_user > "$d/user" && _rt_llamacpp_etc || _rt_fail "$id" install "Could not write llama.cpp's settings (.state/runtimes/$id/etc): nothing was installed."
  _rt_job running "$id" install 0 0 "Downloading llama.cpp's image ($(rt_size "$id"))"
  _RT_PROFILE=llamacpp dc pull -q llamacpp </dev/null > "$d/install.log" 2>&1 || _rt_fail "$id" install "Docker could not download llama.cpp's image: $(tail -n 2 "$d/install.log" | LC_ALL=C tr -cd ' -~\n' | tr '\n' ' ' | cut -c1-200)"
  if [ -f "$(_rt_cancel_file)" ]; then rm -f "$(_rt_cancel_file)" "$(rt_root)/job.pid"; _rt_job cancelled "$id" install 0 0 "Cancelled."; return 0; fi
  rt_pin LLAMACPP_VERSION > "$d/installed"
}
# _rt_llamacpp_user -> who its container runs as: you, so it reads the folders this stack made for it (mode 700); rootless
# Docker (its root is you) and ./stack run as root: 0:0 — with every capability dropped, it reads only what is its own
_rt_llamacpp_user() {
  if [ "$(id -u)" = 0 ] || docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep rootless >/dev/null; then echo 0:0; return 0; fi
  printf '%s:%s\n' "$(id -u)" "$(id -g)"
}
# _rt_llamacpp_etc — etc/ (700): its API key (made once: 32 random bytes, in hex), the request header that carries it
# (auth.hdr, for ./stack's own looks: curl -H @file, never an argument), and presets.ini
_rt_llamacpp_etc() {
  local d e k; d="$(rt_dir llamacpp)"; e="$d/etc"
  mkdir -p "$e" "$d/hub" && chmod 700 "$e" "$d/hub" || return 1
  k="$(cat "$e/api-key" 2>/dev/null || true)"
  if ! [[ $k =~ ^[0-9a-f]{64}$ ]]; then
    k="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"; [[ $k =~ ^[0-9a-f]{64}$ ]] || return 1
    ( umask 077; printf '%s\n' "$k" > "$e/api-key.tmp" ) && mv -f "$e/api-key.tmp" "$e/api-key" || return 1
  fi
  ( umask 077; printf 'Authorization: Bearer %s\n' "$k" > "$e/auth.hdr" ) || return 1
  rt_llamacpp_presets_write
}
# rt_llamacpp_key -> its API key (the model gateway's config has it: lib/local_models.sh); nothing before an install
rt_llamacpp_key() { local k; k="$(cat "$(rt_dir llamacpp)/etc/api-key" 2>/dev/null || true)"; [[ $k =~ ^[0-9a-f]{64}$ ]] && printf '%s\n' "$k" || true; }
# models.tsv (lib/local_models.sh writes it): one row per model downloaded to llama.cpp — its id (the preset's name, as
# the model gateway asks for it), its first GGUF file under hub/, its context (- : not known), its files (comma list)
rt_llamacpp_models() { printf '%s/models.tsv\n' "$(rt_dir llamacpp)"; }
# rt_llamacpp_presets_write — etc/presets.ini: the defaults ([*]: Jinja chat templates, so tool calls; a context of
# RT_LLAMACPP_CTX), then a section per model: its file (a Mac: under hub/ here; Linux: the container's /models) and its
# context, at most 32768
rt_llamacpp_presets_write() {
  local d e root id rel ctx _f; d="$(rt_dir llamacpp)"; e="$d/etc"
  [ -d "$e" ] || return 0
  if [ "$(rt_os)" = linux ]; then root=/models; else root="$d/hub"; fi
  {
    printf '; DevOS ADE (lib/runtimes.sh) writes this file: the models downloaded in Settings › Local models\n[*]\njinja = true\nc = %s\n' "$RT_LLAMACPP_CTX"
    while IFS=$'\t' read -r id rel ctx _f; do
      [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,125}$ ]] && [[ $rel =~ ^[A-Za-z0-9._/+-]+$ ]] && [ "${#rel}" -le 400 ] && [[ /$rel/ != */../* ]] || continue
      printf '\n[%s]\nmodel = %s/%s\n' "$id" "$root" "$rel"
      case "$ctx" in '' | *[!0-9]*) ;; *) [ "$ctx" -le 32768 ] || ctx=32768; printf 'c = %s\n' "$ctx" ;; esac
    done < <(cat "$(rt_llamacpp_models)" 2>/dev/null || true)
  } > "$e/presets.ini.tmp" && chmod 600 "$e/presets.ini.tmp" && mv -f "$e/presets.ini.tmp" "$e/presets.ini"
}
# rt_llamacpp_model_put ID FILE CTX FILES — a model in models.tsv (in place of one of the same id) and in presets.ini
rt_llamacpp_model_put() {
  local f tmp; f="$(rt_llamacpp_models)"
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,125}$ ]] && [[ $2 =~ ^[A-Za-z0-9._/+-]+$ ]] && [ "${#2}" -le 400 ] && [[ /$2/ != */../* ]] \
    && [[ $4 =~ ^[A-Za-z0-9._/+,-]+$ ]] && [ "${#4}" -le 4000 ] || return 1   # (macOS regex: no count above 255)
  mkdir -p "$(rt_dir llamacpp)" && tmp="$(mktemp "$f.XXXXXX")" || return 1
  { awk -F'\t' -v i="$1" '$1 != i' "$f" 2>/dev/null || true; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "$4"; } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f" || return 1
  rt_llamacpp_presets_write
}
# rt_llamacpp_forget ID — a model out of models.tsv and presets.ini (llama.cpp started again without it) and its files
# deleted: its repo's whole folder when no other quantization of it is left, else its own files and their blobs
rt_llamacpp_forget() {
  local f row rel files rd sha other tmp x t
  f="$(rt_llamacpp_models)"
  row="$(awk -F'\t' -v i="$1" '!d && $1 == i { print; d = 1 }' "$f" 2>/dev/null || true)"
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r _ rel _ files <<< "$row"
  [[ $rel =~ ^models--[A-Za-z0-9._-]+--[A-Za-z0-9._-]+/snapshots/[0-9a-f]{40}/ ]] || return 1
  rd="$(rt_dir llamacpp)/hub/${rel%%/*}"; sha="${rel#*/snapshots/}"; sha="${sha%%/*}"
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  awk -F'\t' -v i="$1" '$1 != i' "$f" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f" || return 1
  rt_llamacpp_presets_write
  rt_llamacpp_reload || true   # (it stops serving the model either way: the gateway no longer names it)
  other="$(awk -F'\t' -v r="${rel%%/*}/" '!d && index($2, r) == 1 { print; d = 1 }' "$f")"
  if [ -z "$other" ]; then rm -rf -- "$rd"; return 0; fi
  for x in ${files//,/ }; do
    [[ $x =~ ^[A-Za-z0-9._/+-]{1,200}$ ]] && [[ /$x/ != */../* ]] || continue
    t="$(readlink "$rd/snapshots/$sha/$x" 2>/dev/null || true)"
    [[ ${t##*/} =~ ^[0-9a-f]{40,64}$ ]] && rm -f -- "$rd/blobs/${t##*/}"
    rm -f -- "$rd/snapshots/$sha/$x"
  done
}
# rt_llamacpp_reload — a running llama.cpp started again, so it reads presets.ini (a model added or removed): its loaded
# models are unloaded. 1: it did not answer again
rt_llamacpp_reload() {
  local n=0
  rt_installed llamacpp || return 0
  case "$(rt_state llamacpp)" in running | starting) ;; *) return 0 ;; esac
  if [ "$(rt_kind llamacpp)" = agent ]; then launchctl kickstart -k "gui/$(id -u)/$(rt_label llamacpp)" >/dev/null 2>&1 || return 1
  else dc restart llamacpp </dev/null >/dev/null 2>&1 || return 1; fi
  sleep 1
  while [ "$n" -lt "${RT_START_WAIT:-60}" ]; do [ -z "$(_rt_version llamacpp)" ] || { _rt_watch_mark llamacpp; return 0; }; sleep 1; n=$((n + 1)); done
  return 1
}
# rt_install ID — download, check and start it (one job; a terminal asks first)
rt_install() {
  local id="${1:-}" st why
  valid_runtime_id "$id" || die "not a runtime: $id ($RUNTIME_IDS)"
  why="$(rt_why_not "$id")"; [ -z "$why" ] || die "$(rt_name "$id") does not run here: $why"
  st="$(rt_state "$id")"
  case "$st" in
    external) die "$(_rt_external_text "$id")" ;;
    installing) die "$(rt_name "$id") is being installed" ;;
  esac
  if [ -t 0 ] && [ "${BEDROCK_NOW_JOB_ORIGIN:-}" != helper ] && [ "${ASSUME_YES:-0}" != 1 ]; then
    confirm "Install $(rt_name "$id") $(rt_pinned_version "$id") ($(rt_size "$id")$([ "$(rt_os)" = mac ] && echo ", from github.com/$(_rt_repo "$id"), into .state/runtimes/$id" || echo ", $(rt_name "$id")'s image")), running on $(rt_address "$id") only?" || die "nothing was installed"
  fi
  _rt_begin "$id"; rm -f "$(_rt_cancel_file)"
  case "$(rt_os)" in mac) "_rt_install_${id}_mac" ;; linux) "_rt_install_${id}_linux" ;; esac
  rt_installed "$id" || return 0   # (cancelled)
  _rt_job running "$id" install 0 0 "Starting it"
  _rt_start_now "$id" || _rt_fail "$id" install "$(rt_name "$id") is installed but did not start: $(_rt_log_hint "$id")"
  _rt_watch_mark "$id"
  _rt_event "$id" installed "$(rt_name "$id") $(rt_installed_version "$id") was installed and runs on $(rt_address "$id")"
  _rt_end "$id" install "$(rt_name "$id") $(rt_installed_version "$id") is running on $(rt_address "$id")"
  log "$(rt_name "$id") $(rt_installed_version "$id") is running on $(rt_address "$id")"
}

_rt_repo() { case "$1" in ollama) echo ollama/ollama ;; llamacpp) echo ggml-org/llama.cpp ;; esac; }
# _rt_external_text ID -> why it is not installed over what already answers on its address
_rt_external_text() {
  case "$1" in
    ollama) echo "An Ollama that is not DevOS ADE's already answers on $(rt_address ollama) (the Ollama app, or one you started): downloads can go to it as it is (Settings › Local models). To have DevOS ADE run its own, quit that one first." ;;
    *) echo "Something that is not DevOS ADE's already answers on $(rt_address "$1"), the address $(rt_name "$1") would have: quit it first." ;;
  esac
}

# --- start, stop ---
# _rt_start_now ID -> 0 once it answers (60 s at most)
_rt_start_now() {
  local id="$1" n=0
  if [ "$(rt_kind "$id")" = agent ]; then
    [ -x "$(_rt_program "$id")" ] || return 1
    [ -z "$(_rt_version "$id")" ] || _rt_agent_loaded "$id" || return 1   # (something else holds the port)
    _rt_agent_up "$id" || return 1
  else
    # shellcheck disable=SC2046
    dc up -d $(rt_services "$id") </dev/null >/dev/null 2>&1 || return 1
  fi
  while [ "$n" -lt "${RT_START_WAIT:-60}" ]; do [ -z "$(_rt_version "$id")" ] || return 0; sleep 1; n=$((n + 1)); done
  return 1
}
_rt_log_hint() { rt_logs_text "$1" 3 | tr '\n' ' ' | cut -c1-200; }
rt_start() {
  local id="${1:-}"
  valid_runtime_id "$id" || die "not a runtime: $id ($RUNTIME_IDS)"
  rt_installed "$id" || die "$(rt_name "$id") is not installed by DevOS ADE: ./stack runtimes install $id"
  [ "$(rt_state "$id")" != running ] || { log "$(rt_name "$id") is running"; return 0; }
  [ "$(rt_state "$id")" != external ] || die "$(_rt_external_text "$id")"
  _rt_begin "$id"
  _rt_job running "$id" start 0 0 "Starting $(rt_name "$id")"
  _rt_start_now "$id" || _rt_fail "$id" start "$(rt_name "$id") did not start: $(_rt_log_hint "$id")"
  _rt_watch_mark "$id"; _rt_event "$id" started "$(rt_name "$id") was started"
  _rt_end "$id" start "$(rt_name "$id") is running on $(rt_address "$id")"
  log "$(rt_name "$id") is running on $(rt_address "$id")"
}
rt_stop() {
  local id="${1:-}"
  valid_runtime_id "$id" || die "not a runtime: $id ($RUNTIME_IDS)"
  rt_installed "$id" || die "$(rt_name "$id") is not installed by DevOS ADE (one of yours is never stopped from here)"
  _rt_begin "$id"
  _rt_job running "$id" stop 0 0 "Stopping $(rt_name "$id")"
  # shellcheck disable=SC2046
  if [ "$(rt_kind "$id")" = agent ]; then _rt_agent_down "$id"; else dc stop $(rt_services "$id") </dev/null >/dev/null 2>&1 || true; fi
  _rt_watch_mark "$id"; _rt_event "$id" stopped "$(rt_name "$id") was stopped"
  _rt_end "$id" stop "$(rt_name "$id") is stopped: its models are not served until it starts again"
  log "$(rt_name "$id") is stopped"
}
# runtimes_up_hook / runtimes_down_hook — ./stack up starts the installed agents (macOS; Linux's containers are compose's),
# ./stack down stops them; never fatal
runtimes_up_hook() {
  local id
  [ "$(rt_os)" = mac ] || return 0
  for id in $RUNTIME_IDS; do
    rt_installed "$id" || continue
    [ "$(rt_state "$id")" = stopped ] || continue
    if _rt_start_now "$id"; then _rt_watch_mark "$id"; else warn "$(rt_name "$id") did not start: ./stack runtimes logs $id"; fi
  done
  return 0
}
runtimes_down_hook() {
  local id
  [ "$(rt_os)" = mac ] || return 0
  for id in $RUNTIME_IDS; do ! rt_installed "$id" || { _rt_agent_down "$id"; _rt_watch_mark "$id"; }; done
  return 0
}

# --- uninstall ---
# _rt_unregister RT — every model of that runtime out of LOCAL_MODELS (one settings change) and the registry
_rt_unregister() {
  local cur new='' e
  cur="$(get_env LOCAL_MODELS)"
  while IFS= read -r e; do [ -n "$e" ] && [ "${e%%:*}" != "$1" ] && new="${new:+$new,}$e"; done < <(printf '%s\n' "$cur" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  local_registry_rows | awk -F'\t' -v r="$1" '$1 == r { print $2 }' | while IFS= read -r e; do local_registry_drop "$1" "$e"; done
  [ "$new" != "$cur" ] || return 0
  CFG_ORDER=''; cfg_put LOCAL_MODELS "$new"
  config_apply local cli ''
}
rt_uninstall() {
  local id="${1:-}" d v
  valid_runtime_id "$id" || die "not a runtime: $id ($RUNTIME_IDS)"
  rt_installed "$id" || [ -d "$(rt_dir "$id")/bin" ] || die "$(rt_name "$id") is not installed by DevOS ADE (one of yours is never removed from here)"
  if [ -t 0 ] && [ "${BEDROCK_NOW_JOB_ORIGIN:-}" != helper ] && [ "${ASSUME_YES:-0}" != 1 ]; then
    confirm "Remove $(rt_name "$id") and every model downloaded to it?" || die "nothing was removed"
  fi
  _rt_begin "$id"; d="$(rt_dir "$id")"
  _rt_job running "$id" uninstall 0 0 "Taking its models out of the model gateway"
  _rt_unregister "$id" || _rt_fail "$id" uninstall "The model gateway did not let its models go: nothing was removed (./stack runtimes)"
  _rt_job running "$id" uninstall 0 0 "Stopping and removing $(rt_name "$id")"
  if [ "$(rt_kind "$id")" = agent ]; then
    _rt_agent_down "$id"
  else
    # shellcheck disable=SC2046
    _RT_PROFILE="$id" dc rm -sf $(rt_services "$id") </dev/null >/dev/null 2>&1 || true
    for v in $(_rt_volumes "$id"); do docker volume rm "$(project_name)_$v" >/dev/null 2>&1 || true; done
  fi
  rm -rf "$d"
  _rt_event "$id" removed "$(rt_name "$id") was removed with its models"
  _rt_end "$id" uninstall "$(rt_name "$id") was removed with its models"
  log "$(rt_name "$id") was removed with its models"
}
# runtimes_uninstall_all — ./stack uninstall: every runtime this stack installed (an Ollama of yours stays)
runtimes_uninstall_all() {
  local id v
  for id in $RUNTIME_IDS; do
    rt_installed "$id" || [ -d "$(rt_dir "$id")" ] || continue
    [ "$(rt_kind "$id")" != agent ] || _rt_agent_down "$id"
    if [ "$(rt_os)" = linux ]; then for v in $(_rt_volumes "$id"); do docker volume rm "$(project_name)_$v" >/dev/null 2>&1 || true; done; fi
    rm -rf "$(rt_dir "$id")"
  done
  rm -rf "$(rt_root)"
}
# rt_cancel — the running install stops (what arrived is kept); nothing else is stopped halfway
rt_cancel() {
  local j n=0; j="$(cat "$(rt_job_file)" 2>/dev/null || true)"
  rt_job_running && [ "$(_local_json_str "$j" op)" = install ] || { log "No install is running"; return 0; }
  : > "$(_rt_cancel_file)"
  _local_kill_tree "$(cat "$(rt_root)/dl.pid" 2>/dev/null || true)" TERM
  while rt_job_running && [ "$n" -lt 40 ]; do sleep 0.5; n=$((n + 1)); done
  if rt_job_running; then
    _local_kill_tree "$(cat "$(rt_root)/job.pid" 2>/dev/null || true)" TERM
    rm -f "$(_rt_cancel_file)" "$(rt_root)/job.pid"
    _rt_job cancelled "$(_local_json_str "$j" id)" install 0 0 "Cancelled: what arrived is kept, and the next install continues from it."
  fi
  log "Cancelled"
}

# --- logs ---
# rt_logs_text ID [N] -> its last N log lines, printable characters only
rt_logs_text() {
  local id="$1" n="${2:-$RT_LOG_LINES}"
  case "$n" in '' | *[!0-9]*) n="$RT_LOG_LINES" ;; esac
  [ "$n" -le 2000 ] || n=2000
  if [ "$(rt_kind "$id")" = agent ]; then [ ! -f "$(rt_dir "$id")/server.log" ] || tail -n "$n" "$(rt_dir "$id")/server.log"
  else _RT_PROFILE="$id" dc logs --no-color --tail "$n" "$(rt_services "$id" | cut -d' ' -f1)" 2>/dev/null || true; fi | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | LC_ALL=C tr -cd '\t\n -~' | cut -c1-400
}
# rt_logs_write ID — the portal's copy (status/runtime-logs/ID.txt), when Settings asks for it
rt_logs_write() {
  local d; d="$(status_dir)/runtime-logs"; mkdir -p "$d" 2>/dev/null || return 0
  rt_logs_text "$1" | _local_put "$d/$1.txt"
}

# --- the portal's file ---
_rt_status_one() {
  local id="$1" st v ver pin loaded='' mem=0 vram=0 name b vb n=0 restarts='' code='' why
  st="$(rt_state "$id")"; why="$(rt_why_not "$id")"; pin="$(rt_pinned_version "$id")"; ver=''
  case "$st" in running | external) ver="$(_rt_version "$id")" ;; esac
  [ -n "$ver" ] || ver="$(rt_installed_version "$id")"
  if [ "$st" = running ] || [ "$st" = external ]; then
    while IFS=$'\t' read -r name b vb; do
      [ -n "$name" ] || continue
      loaded="$loaded${loaded:+,}{\"name\":$(_local_q "$name" 160),\"bytes\":${b:-0},\"gpu_bytes\":${vb:-0}}"
      mem=$((mem + ${b:-0})); vram=$((vram + ${vb:-0})); n=$((n + 1))
    done < <(_rt_ps "$id")
  fi
  if rt_installed "$id" && [ "$(rt_kind "$id")" = agent ] && _rt_agent_loaded "$id"; then
    restarts="$(_rt_agent_field "$id" runs | tr -cd '0-9')"; [ -z "$restarts" ] || restarts=$((restarts - 1))
    code="$(_rt_agent_field "$id" "last exit code" | tr -cd '0-9')"
  fi
  printf '{"id":"%s","name":%s,"state":"%s","managed":%s,"kind":"%s","version":%s,"pinned":%s,"address":"%s","loaded":[%s],"memory_bytes":%s,"gpu_bytes":%s,"restarts":%s,"last_exit":%s,"size":%s,"why_not":%s}' \
    "$id" "$(_local_q "$(rt_name "$id")")" "$st" "$(rt_installed "$id" && echo true || echo false)" "$(rt_kind "$id")" \
    "$(_local_q "$ver" 40)" "$(_local_q "$pin" 40)" "$(rt_address "$id")" "$loaded" "$mem" "$vram" "${restarts:-null}" "${code:-null}" \
    "$(_local_q "$(rt_size "$id")" 80)" "$(_local_q "$why" 200)"
}
# rt_status_write — .state/status/runtimes.json: each runtime, the job, the last events
rt_status_write() {
  local id out='' ev='' at rid kind text job
  for id in $RUNTIME_IDS; do out="$out${out:+,}$(_rt_status_one "$id")"; done
  while IFS=$'\t' read -r at rid kind text; do
    [[ $at =~ ^[0-9]{1,12}$ ]] && valid_runtime_id "$rid" || continue
    case "$kind" in installed | removed | started | stopped | restart | down | up | failed) ;; *) continue ;; esac
    ev="$ev${ev:+,}{\"at\":$at,\"id\":\"$rid\",\"kind\":\"$kind\",\"text\":$(_local_q "$text")}"
  done < <(tail -n "$RT_EVENTS_MAX" "$(rt_events_file)" 2>/dev/null)
  job="$(cat "$(rt_job_file)" 2>/dev/null || true)"
  case "$job" in '{'*'}') ;; *) job='{"state":"idle"}' ;; esac
  printf '{"version":1,"at":%s,"os":"%s","runtimes":[%s],"job":%s,"events":[%s]}\n' "$(date +%s)" "$(rt_os)" "$out" "$job" "$ev" | _local_put "$(rt_status_file)"
}

# --- ./stack runtimes ---
_rt_status_lines() {
  local id st line
  for id in $RUNTIME_IDS; do
    st="$(rt_state "$id")"
    case "$st" in
      running) line="running $(_rt_version "$id") on $(rt_address "$id")$([ "$(rt_kind "$id")" = agent ] && echo " (launchd agent)" || echo " (container)")" ;;
      external) [ "$id" = ollama ] && line="yours: $(rt_name "$id") $(_rt_version "$id") that is not DevOS ADE's answers on $(rt_address "$id")" \
                  || line="its address is taken: something that is not DevOS ADE's answers on $(rt_address "$id")" ;;
      not-installed) line="not installed (./stack runtimes install $id: $(rt_size "$id"))" ;;
      unsupported) line="does not run here: $(rt_why_not "$id")" ;;
      stopped) line="stopped (./stack runtimes start $id)" ;;
      installing) line="installing: $(_local_json_str "$(cat "$(rt_job_file)" 2>/dev/null || true)" message)" ;;
      *) line="$st" ;;
    esac
    printf '%-10s  %s\n' "$(rt_name "$id")" "$line"
    if [ "$st" = running ] || [ "$st" = external ]; then
      _rt_ps "$id" | while IFS=$'\t' read -r n b vb; do printf '            loaded: %s (%s, %s on the GPU)\n' "$n" "$(_local_size "$b")" "$(_local_size "$vb")"; done
    fi
  done
}
cmd_runtimes() {
  local sub="${1:-status}"; shift 2>/dev/null || true
  case "$sub" in
    status | '') rt_status_write; _rt_status_lines ;;
    install) rt_install "$@" ;;
    start) rt_start "$@" ;;
    stop) rt_stop "$@" ;;
    uninstall | rm | remove) rt_uninstall "$@" ;;
    cancel) rt_cancel ;;
    logs) valid_runtime_id "${1:-}" || die "usage: ./stack runtimes logs ID [LINES] ($RUNTIME_IDS)"; [ "${2:-}" != --portal ] || { rt_logs_write "$1"; return 0; }; rt_logs_text "$1" "${2:-}" ;;
    -h | --help | help) sed -n '/^#   \.\/stack runtimes/,/^#$/p' "$STACK_DIR/lib/runtimes.sh" | sed 's/^# \{0,1\}//' ;;
    *) die "usage: ./stack runtimes [status] | install ID | start ID | stop ID | uninstall ID | cancel | logs ID [LINES]" ;;
  esac
}
