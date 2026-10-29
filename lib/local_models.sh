# shellcheck shell=bash
# Local models (JON-816): models downloaded from Hugging Face and run on this computer, served to LiteLLM, so they show
# in Chat, the Code page and the terminal like any other model — marked Local, $0.
#
# Runtime: MLX on Apple silicon (below), else Docker Model Runner (docker model …: built into Docker Desktop,
# docker-model-plugin on Docker Engine; llama.cpp on the host, with Metal on Apple silicon), else Ollama (hf.co/… pulls
# too): DevOS ADE's own (lib/runtimes.sh: installed from Settings › Local models › Runtimes, a launchd agent on a Mac, a
# container of the stack on Linux) or one of yours. LOCAL_RUNTIME picks one (blank: that order). Nothing is installed or
# switched on by itself: when none runs, the portal says how, and ./stack local-models enable (Docker Model Runner) or
# ./stack runtimes install ollama does it after asking. llama.cpp (DevOS ADE's own, from Runtimes too) takes a download
# only when named (LOCAL_RUNTIME=llamacpp) or when none of those runs: the GGUF files of the quantization, checked against
# the Hub's hashes (lib/hf_fetch.py), into its own folder; llama-server serves every one of them (lib/runtimes.sh). LM
# Studio (DevOS ADE's own, on an Apple-silicon Mac) the same way, last: the same files, which it gets by `lms import`.
#
#   ./stack local-models [status]                 the runtime, what is downloaded, disk used (and writes the portal's file)
#   ./stack local-models pull REPO QUANT [opts]   download hf.co/REPO:QUANT, then register it (LOCAL_MODELS, applied live)
#   ./stack local-models rm REPO QUANT            unregister it, then delete it from the runtime
#   ./stack local-models enable                   turn a runtime on (asks first)
#
# Files (all under .state/): local-models/installed.tsv (what ./stack downloaded: runtime, runner id, repo, quant, bytes,
# license, tools, context, parameters in millions, when), local-models/job.json (the one running pull), and the portal's
# read-only copy status/local-models.json. Setting: LOCAL_MODELS = a comma list of "dmr:<runner id>" / "ollama:<id>"
# (what LiteLLM serves, rendered by local_models_yaml as "lm/<id>"); HF_TOKEN (a Hugging Face token for gated models,
# only ever read from .env here, passed to the runtime in its environment: never in a URL, an argument or a log).
#
# Verified against Docker's and Ollama's docs 2026-10-27: `docker model pull hf.co/<org>/<repo>:<quant>` (Q4_K_M when no
# tag), `docker model status --json` ({running, kind, endpoint}), `docker model list --openai`, `docker model rm`,
# `docker desktop enable model-runner --tcp 12434`, `apt-get install docker-model-plugin`; Ollama's POST /api/pull
# (streamed {status,digest,total,completed}), GET /api/tags, OpenAI/native chat on :11434.

LOCAL_MODELS_MAX=24                    # models registered at once (each is a LiteLLM deployment)
LOCAL_MAX_OUT=4096                     # a local model's answer is capped here: a stuck small model stops, it does not run on
LOCAL_TINY_PARAMS_M=3000               # under 3B parameters: chat only (Claude Code's tools are beyond it)
LOCAL_SMALL_PARAMS_M=7000              # under 7B: tools work badly
local_dir() { printf '%s/local-models\n' "$STATE_DIR"; }
local_registry() { printf '%s/installed.tsv\n' "$(local_dir)"; }
local_job_file() { printf '%s/job.json\n' "$(local_dir)"; }
local_status_file() { printf '%s/local-models.json\n' "$(status_dir)"; }
# the portal asks (no password: a free, read-only look) by creating this file in the requests folder
local_wanted_file() { printf '%s/local-wanted\n' "$(request_dir)"; }

# --- ids ---
# valid_hf_repo ORG/REPO, valid_hf_quant TAG (what hf.co/<repo>:<tag> takes: a quant name, or a file name)
valid_hf_repo() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]]; }
valid_hf_quant() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
# a registered model: "dmr:<id>" or "ollama:<id>"; <id> as valid_code_model_id (a letter or digit, then letters, digits and
# . _ : / -), at most 126 characters
valid_local_entry() { [[ $1 =~ ^(dmr|ollama|mlx|llamacpp|lmstudio):[A-Za-z0-9][A-Za-z0-9._:/-]{0,125}$ ]]; }
# valid_local_models VALUE -> 0 for blank or a comma list of them (at most LOCAL_MODELS_MAX)
valid_local_models() {
  local m rest n=0
  case "$1" in '') return 0 ;; ,* | *, | *,,*) return 1 ;; esac
  rest="$1,"
  while [ -n "$rest" ]; do m="${rest%%,*}"; rest="${rest#*,}"; valid_local_entry "$m" || return 1; n=$((n + 1)); done
  [ "$n" -le "$LOCAL_MODELS_MAX" ]
}
valid_hf_token() { [ -z "$1" ] || [[ $1 =~ ^hf_[A-Za-z0-9]{20,200}$ ]]; }

# local_model_name ENTRY -> the name LiteLLM serves it under: lm/<id without hf.co/>
local_model_name() { local id="${1#*:}"; printf 'lm/%s\n' "${id#hf.co/}"; }

# local_models_wanted -> the entries LOCAL_MODELS names (valid, each once; a name twice: the first)
local_models_wanted() {
  local v; v="$(get_env LOCAL_MODELS)"; [ -n "$v" ] || return 0
  printf '%s\n' "$v" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    while IFS= read -r m; do valid_local_entry "$m" && printf '%s\t%s\n' "$(local_model_name "$m")" "$m"; done |
    awk -F'\t' '!seen[$1]++ { print $2 }' | head -n "$LOCAL_MODELS_MAX"
}

# --- the runtimes ---
# _local_docker_ok -> 0 when the docker command and its model plugin are there
_local_docker_ok() { command -v docker >/dev/null 2>&1 && docker model version >/dev/null 2>&1; }
_local_ollama_url() { printf '%s\n' "${LOCAL_OLLAMA_URL:-http://127.0.0.1:11434}"; }
_local_json_str() { printf '%s' "$1" | sed -n "s/.*\"$2\" *: *\"\\([^\"]*\\)\".*/\\1/p" | head -n 1; }

# local_dmr_state -> "ready|not-enabled|plugin-missing|not-installed"
local_dmr_state() {
  local out
  command -v docker >/dev/null 2>&1 || { echo not-installed; return 0; }
  _local_docker_ok || { echo plugin-missing; return 0; }
  out="$(_with_deadline 8 docker model status --json 2>/dev/null || true)"
  case "$out" in *'"running":true'* | *'"running": true'*) echo ready ;; *) echo not-enabled ;; esac
}
# local_ollama_state -> "ready|not-running|not-installed"
local_ollama_state() {
  if curl -s -m 3 -o /dev/null "$(_local_ollama_url)/api/version" 2>/dev/null; then echo ready
  elif command -v ollama >/dev/null 2>&1; then echo not-running
  else echo not-installed; fi
}
# local_llamacpp_state -> "ready|not-running|not-installed": DevOS ADE's own llama.cpp (lib/runtimes.sh)
local_llamacpp_state() {
  declare -F rt_installed >/dev/null && rt_installed llamacpp || { echo not-installed; return 0; }
  [ "$(rt_state llamacpp)" = running ] && echo ready || echo not-running
}
# local_lmstudio_state -> "ready|not-running|not-installed": DevOS ADE's own LM Studio (lib/runtimes.sh)
local_lmstudio_state() {
  declare -F rt_installed >/dev/null && rt_installed lmstudio || { echo not-installed; return 0; }
  [ "$(rt_state lmstudio)" = running ] && echo ready || echo not-running
}
# local_lmstudio_base -> where the model gateway reaches it: this Mac's agent, as host.docker.internal
local_lmstudio_base() { printf 'http://host.docker.internal:%s/v1\n' "$(rt_port lmstudio)"; }
# local_llamacpp_base -> where the model gateway reaches it: its container by name (Linux), this Mac's agent as
# host.docker.internal
local_llamacpp_base() {
  if [ "$(rt_os)" = linux ]; then echo http://llamacpp:8080/v1; else printf 'http://host.docker.internal:%s/v1\n' "$(rt_port llamacpp)"; fi
}
# local_dmr_base -> the address LiteLLM's container reaches Docker Model Runner at (engine path included). On Docker
# Desktop: model-runner.docker.internal (no port); on Docker Engine: the host's TCP port 12434 (compose gives LiteLLM
# host.docker.internal). LOCAL_DMR_BASE overrides (tests).
local_dmr_base() {
  local os
  if [ -n "${LOCAL_DMR_BASE:-}" ]; then printf '%s\n' "$LOCAL_DMR_BASE"; return 0; fi
  os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
  case "$os" in *"Docker Desktop"*) printf 'http://model-runner.docker.internal/engines/llama.cpp\n' ;; *) printf 'http://host.docker.internal:12434/engines/llama.cpp\n' ;; esac
}
# local_ollama_base -> where the model gateway reaches Ollama: the stack's own container on its network (Linux, lib/runtimes.sh),
# else this computer's (DevOS ADE's launchd agent on a Mac, or one of yours) as host.docker.internal
local_ollama_base() {
  if [ -n "${LOCAL_OLLAMA_BASE:-}" ]; then printf '%s\n' "$LOCAL_OLLAMA_BASE"
  elif declare -F rt_compose_on >/dev/null && rt_compose_on ollama; then printf 'http://ollama:11434\n'
  else printf 'http://host.docker.internal:11434\n'; fi
}


# --- MLX: the primary runtime on Apple silicon (JON-816, owner's decision) ---
# mlx-lm's own server (mlx_lm.server: OpenAI chat API with tool calls, runs on the GPU through Metal, so it runs on the
# host, never in a container) in a uv venv of this stack's own (state dir mlx/venv, mlx-lm pinned and hash-locked in
# catalog/mlx-requirements.lock: nothing is installed system-wide), as a launchd user agent bound to 127.0.0.1 only; the
# model gateway reaches it as host.docker.internal. Models come from Hugging Face's MLX catalog into this stack's own
# HF_HOME (mlx/hf), so disk use and Remove are exact; the server runs with HF_HUB_OFFLINE=1 and takes a model's name from
# each request (it loads it on first use, and swaps when another is named: the first answer after a swap waits for the
# load), so it can never download anything itself.
# Security (non-negotiable): --trust-remote-code is never passed (CVE-2026-5843: an old mlx-lm ran the Python file a
# config.json's model_file names; 0.32.x refuses it unless trusted, and the lock pins that line); before a download a repo
# whose config.json has model_file or auto_map, or that ships any .py file, is refused; no .py file is ever fetched.
local_mlx_dir() { printf '%s/mlx\n' "$STATE_DIR"; }
local_mlx_port() { printf '%s\n' "${LOCAL_MLX_PORT:-18765}"; }
local_mlx_label() { printf 'dev.devos.ade.mlx.%s\n' "$(printf '%s' "$STATE_DIR" | cksum | cut -d' ' -f1)"; }
local_mlx_base() { printf 'http://host.docker.internal:%s/v1\n' "$(local_mlx_port)"; }
local_mlx_hub() { printf '%s/hf/hub\n' "$(local_mlx_dir)"; }
local_mlx_repo_dir() { printf '%s/models--%s\n' "$(local_mlx_hub)" "${1//\//--}"; }
# local_mlx_capable -> 0 on Apple silicon with uv (LOCAL_MLX=off turns it off)
local_mlx_capable() {
  [ "${LOCAL_MLX:-auto}" != off ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] && command -v uv >/dev/null 2>&1
}
# local_mlx_state -> ready | stopped | not-installed | no-uv | unsupported
local_mlx_state() {
  if [ "${LOCAL_MLX:-auto}" = off ] || [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then echo unsupported; return 0; fi
  if [ -x "$(local_mlx_dir)/venv/bin/mlx_lm.server" ]; then
    if curl -s -m 3 -o /dev/null "http://127.0.0.1:$(local_mlx_port)/v1/models" 2>/dev/null; then echo ready; else echo stopped; fi
  elif command -v uv >/dev/null 2>&1; then echo not-installed
  else echo no-uv; fi
}
local_mlx_install() {
  local d; d="$(local_mlx_dir)"
  [ ! -x "$d/venv/bin/mlx_lm.server" ] || return 0
  mkdir -p "$d" && chmod 700 "$d"
  uv venv -q --python 3.12 "$d/venv" >/dev/null 2>&1 || uv venv -q "$d/venv" >/dev/null 2>&1 || return 1
  uv pip install -q --require-hashes -r "$STACK_DIR/catalog/mlx-requirements.lock" --python "$d/venv/bin/python" >/dev/null 2>&1 || { rm -rf "$d/venv"; return 1; }
}
# local_mlx_up -> the server running as this stack's launchd user agent (a few seconds), 127.0.0.1 only, offline
local_mlx_up() {
  local d lbl plist n=0; d="$(local_mlx_dir)"; lbl="$(local_mlx_label)"; plist="$HOME/Library/LaunchAgents/$lbl.plist"
  [ "$(local_mlx_state)" != ready ] || return 0
  mkdir -p "$HOME/Library/LaunchAgents" "$d/hf"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$lbl</string>
<key>ProgramArguments</key><array><string>$d/venv/bin/mlx_lm.server</string><string>--host</string><string>127.0.0.1</string><string>--port</string><string>$(local_mlx_port)</string><string>--allowed-origins</string><string>http://127.0.0.1</string></array>
<key>EnvironmentVariables</key><dict><key>HF_HOME</key><string>$d/hf</string><key>HF_HUB_OFFLINE</key><string>1</string><key>HF_HUB_DISABLE_TELEMETRY</key><string>1</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$d/server.log</string><key>StandardErrorPath</key><string>$d/server.log</string>
</dict></plist>
EOF
  chmod 600 "$plist"
  launchctl bootout "gui/$(id -u)/$lbl" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || launchctl load -w "$plist" >/dev/null 2>&1 || return 1
  while [ "$n" -lt 60 ]; do [ "$(local_mlx_state)" = ready ] && return 0; sleep 1; n=$((n + 1)); done
  return 1
}
# local_mlx_uninstall [--models] -> the agent, its plist and the venv go; the models only with --models
local_mlx_uninstall() {
  local lbl d; lbl="$(local_mlx_label)"; d="$(local_mlx_dir)"
  launchctl bootout "gui/$(id -u)/$lbl" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/$lbl.plist"
  rm -rf "$d/venv" "$d/server.log"
  if [ "${1:-}" = --models ]; then rm -rf "$d/hf" "$d"; fi
}
# the repo check before a download: config.json's model_file/auto_map and any .py file refuse it. Prints ONE line: "sha <40 hex>"
# (the commit that was checked: the download is pinned to it, so a push after the check is never fetched) or "no <why>".
# MANIFEST gets that commit's files (path, size, SHA-256 of a large file, git blob id): lib/hf_fetch.py downloads and checks them.
_local_mlx_vet() {  # _local_mlx_vet REPO MANIFEST  (HF_TOKEN in the environment)
  local d; d="$(local_mlx_dir)"
  HF_HOME="$d/hf" HF_HUB_DISABLE_TELEMETRY=1 "$d/venv/bin/python" -I -c '
import json, sys
from huggingface_hub import HfApi, hf_hub_download
repo = sys.argv[1]
info = HfApi().model_info(repo, files_metadata=True)
sha = info.sha
files = [s.rfilename for s in info.siblings]
py = [f for f in files if f.endswith(".py")]
if py: print("no it ships Python files (%s): running them is how this kind of model runs code on your computer" % ", ".join(py[:3])); sys.exit(0)
if "config.json" not in files: print("no it has no config.json: not an MLX model"); sys.exit(0)
cfg = json.load(open(hf_hub_download(repo, "config.json", revision=sha)))
bad = [k for k in ("model_file", "auto_map") if k in cfg]
if bad: print("no its config.json asks to run custom code (%s)" % ", ".join(bad)); sys.exit(0)
with open(sys.argv[2], "w") as m:
    for s in info.siblings:
        m.write("%s\t%s\t%s\t%s\n" % (s.rfilename, s.size, (s.lfs or {}).get("sha256") or "", s.blob_id or ""))
print("sha " + sha)
' "$1" "$2" 2>&1 | tail -n 1 | cut -c1-300
}
# _local_mlx_recheck REPO SHA -> why the DOWNLOADED snapshot may not be used (nothing: it is fine). The same config.json
# rule, on the files on disk, so what is served is what was checked, whatever the Hub answered at download time.
_local_mlx_recheck() {
  local snap; snap="$(local_mlx_repo_dir "$1")/snapshots/$2"
  [[ $2 =~ ^[0-9a-f]{40}$ ]] || { printf 'the vetted revision is not a commit\n'; return 0; }
  [ -d "$snap" ] || { printf 'the download is not the revision that was checked (%s)\n' "${2:0:12}"; return 0; }
  python3 -I -c '
import json, os, sys
snap = sys.argv[1]
py = [f for _, _, fs in os.walk(snap) for f in fs if f.endswith(".py")]
if py: print("the download contains Python files (%s)" % ", ".join(py[:3])); sys.exit(0)
cfg = os.path.join(snap, "config.json")
if not os.path.isfile(cfg): print("the download has no config.json"); sys.exit(0)
try: c = json.load(open(cfg))
except Exception: print("its config.json could not be read"); sys.exit(0)
bad = [k for k in ("model_file", "auto_map") if k in c]
if bad: print("its config.json asks to run custom code (%s)" % ", ".join(bad))
' "$snap" 2>/dev/null | head -n 1 | cut -c1-300 || true
}
# _local_pull_mlx REPO BYTES TOOLS CTX PM LIC — install (once), vet, download, serve, register
_local_pull_mlx() {
  local repo="$1" bytes="$2" tools="$3" ctx="$4" pm="$5" lic="$6" quant=mlx d logf pid why done_b=0 rc=0 id sha='' man stop
  d="$(local_mlx_dir)"
  if [ ! -x "$d/venv/bin/mlx_lm.server" ]; then
    _local_job pulling "$repo" "$quant" 0 "$bytes" "Setting up MLX (one time, about a minute): mlx-lm into this stack's own Python environment"
    local_mlx_install || { _local_job failed "$repo" "$quant" 0 "$bytes" "Could not set up MLX (uv pip install of the locked mlx-lm failed: offline, or no Python 3.12?)."; die "mlx-lm setup failed"; }
  fi
  _local_job pulling "$repo" "$quant" 0 "$bytes" "Checking $repo is safe to run (no custom code)"
  man="$(local_dir)/manifest.tsv"; : > "$man"; chmod 600 "$man"
  why="$(HF_TOKEN="$(get_env HF_TOKEN)" _local_mlx_vet "$repo" "$man")"
  case "$why" in "sha "*) sha="${why#sha }"; why='' ;; "no "*) why="${why#no }" ;; *) why="${why:-the check gave no answer}" ;; esac
  [ -n "$why" ] || [[ $sha =~ ^[0-9a-f]{40}$ ]] || why="the check did not give a revision to download"
  if [ -n "$why" ]; then
    local rd; rd="$(local_mlx_repo_dir "$repo")"; rm -rf -- "$rd"
    _local_job failed "$repo" "$quant" 0 "$bytes" "Not downloaded: $why. DevOS ADE never runs a model's own code."
    die "refused: $why"
  fi
  stop="$(_local_stop_asked)"
  if [ -n "$stop" ]; then _local_stopped "$stop" mlx "$repo" "$quant" 0 "$bytes"; return 0; fi
  logf="$(local_dir)/pull.log"; : > "$logf"; chmod 600 "$logf"
  # lib/hf_fetch.py, not `hf download` (which deletes a file's unfinished part when it stops): each file downloads into a
  # part of its own that a stopped download continues from, and is checked against the hash the Hub gives for it
  ( export HF_TOKEN; HF_TOKEN="$(get_env HF_TOKEN)"; exec "$d/venv/bin/python" -I "$STACK_DIR/lib/hf_fetch.py" "$repo" "$sha" "$(local_mlx_hub)" "$man" ) </dev/null > "$logf" 2>&1 &
  pid=$!; printf '%s\n' "$pid" > "$(local_dl_pid_file)"
  _local_speed_reset
  while kill -0 "$pid" 2>/dev/null; do
    done_b="$({ du -sk "$(local_mlx_repo_dir "$repo")" 2>/dev/null || true; } | awk '{ print $1 * 1024 }')"
    case "$done_b" in '' | *[!0-9]*) done_b=0 ;; esac
    _local_speed "$done_b" "$bytes"
    _local_job pulling "$repo" "$quant" "$done_b" "$bytes" "$(_local_dl_message "$repo")" "$_LS_RATE" "$_LS_ETA" "$_LS_STALLED"
    sleep "${LOCAL_POLL_S:-1}"
  done
  wait "$pid" || rc=$?
  rm -f "$(local_dl_pid_file)"
  stop="$(_local_stop_asked)"
  if [ "$stop" = cancel ] || { [ "$stop" = pause ] && [ "$rc" -ne 0 ]; }; then _local_stopped "$stop" mlx "$repo" "$quant" "$done_b" "$bytes"; return 0; fi
  rm -f "$(local_stop_file)"
  if [ "$rc" -ne 0 ]; then
    _local_job failed "$repo" "$quant" "$done_b" "$bytes" "The download stopped ($(tail -n 2 "$logf" | LC_ALL=C tr -cd ' -~\n' | tr '\n' ' ' | cut -c1-200)). What arrived is kept: Resume continues from it, Cancel deletes it. A gated model needs a Hugging Face token (Settings › Models & providers) and its license accepted on huggingface.co."
    die "the download failed"
  fi
  why="$(_local_mlx_recheck "$repo" "$sha")"
  if [ -n "$why" ]; then
    local rd; rd="$(local_mlx_repo_dir "$repo")"; rm -rf -- "$rd"
    _local_job failed "$repo" "$quant" 0 "$bytes" "Deleted, not registered: after the download, $why. DevOS ADE never runs a model's own code."
    die "refused after the download: $why"
  fi
  # the server loads a model by its name offline (HF_HUB_OFFLINE), through the cache's refs/main, which a download pinned
  # to a commit does not write: it names the vetted commit, so the snapshot served is the one checked
  mkdir -p "$(local_mlx_repo_dir "$repo")/refs" && printf '%s' "$sha" > "$(local_mlx_repo_dir "$repo")/refs/main"
  [ "$bytes" -gt 0 ] 2>/dev/null || bytes="$({ du -sk "$(local_mlx_repo_dir "$repo")" 2>/dev/null || true; } | awk '{ print $1 * 1024 }')"
  _local_job registering "$repo" "$quant" "$bytes" "$bytes" "Starting the MLX server and registering the model (a few seconds)"
  local_mlx_up || { _local_job failed "$repo" "$quant" "$bytes" "$bytes" "Downloaded, but the MLX server did not start: see $(local_mlx_dir)/server.log"; die "mlx server did not start"; }
  id="$repo"
  valid_local_entry "mlx:$id" || { _local_job failed "$repo" "$quant" 0 "$bytes" "The model name is one this stack cannot serve."; die "unusable model id"; }
  local_registry_put mlx "$id" "$repo" "$quant" "$bytes" "$lic" "$([ "$tools" = yes ] && echo 1 || { [ "$tools" = no ] && echo 0 || echo -; })" "$ctx" "$pm" "$sha"
  local_register_apply add "mlx:$id" || { _local_job failed "$repo" "$quant" "$bytes" "$bytes" "Downloaded, but the model gateway did not take it: ./stack local-models status"; die "registration failed"; }
  _local_job done "$repo" "$quant" "$bytes" "$bytes" "Ready: $(local_model_name "mlx:$id") is in Chat, the Code page and the terminal (the first answer waits while it loads)"
  rm -f "$(local_dir)/job.pid"
}

# --- llama.cpp: DevOS ADE's own (lib/runtimes.sh); a model is the GGUF files of one quantization ---
# _local_gguf_vet REPO QUANT MANIFEST -> ONE line: "sha <40 hex><TAB><its first file><TAB><bytes>" (the commit checked: the
# download is pinned to it, so a push after the check is never fetched) or "no <why>". MANIFEST gets the quantization's
# GGUF files at that commit (path, size, SHA-256, git blob id) for lib/hf_fetch.py: one file, or every part of a split
# one (…-00001-of-0000N.gguf); never a vision projector (mmproj) or anything but GGUF. A file whose name has the
# quantization (Q4_K_M matches …-Q4_K_M.gguf and Q4_K_M/…, never …-Q4_K_M_L or IQ4_K_M); of two, the shorter name. The
# Hub is asked with the token in a header curl reads from stdin (HF_TOKEN in the environment).
_local_gguf_vet() {
  local body code ep; body="$(local_dir)/vet.json"; ep="${HF_ENDPOINT:-https://huggingface.co}"; ep="${ep%/}"
  code="$({ [ -z "${HF_TOKEN:-}" ] || printf 'Authorization: Bearer %s\n' "$HF_TOKEN"; } | curl -q -sS -m 60 -H @- -o "$body" -w '%{http_code}' "$ep/api/models/$1/revision/main?blobs=true" 2>/dev/null || true)"
  case "$code" in
    200) ;;
    401 | 403) rm -f "$body"; echo "no Hugging Face does not let this computer see it: a gated or private model needs a Hugging Face token (Settings › Models & providers) and its license accepted on huggingface.co"; return 0 ;;
    404) rm -f "$body"; echo "no Hugging Face has no model $1"; return 0 ;;
    *) rm -f "$body"; echo "no Hugging Face did not answer (HTTP ${code:-none}): try again"; return 0 ;;
  esac
  python3 -I -c '
import json, re, sys
body, quant, man = sys.argv[1:4]
try:
    info = json.load(open(body))
except Exception:
    print("no Hugging Face'"'"'s answer could not be read"); sys.exit(0)
sha = info.get("sha") if isinstance(info, dict) else None
if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
    print("no Hugging Face gave no commit for it"); sys.exit(0)
tag = re.compile(r"(?:^|[^A-Za-z0-9])" + re.escape(quant) + r"(?:[^A-Za-z0-9_]|$)", re.I)
split = re.compile(r"^(.*)-(\d{5})-of-(\d{5})\.gguf$", re.I)
groups = {}
for f in info.get("siblings") or []:
    n = f.get("rfilename") if isinstance(f, dict) else None
    if not isinstance(n, str) or not n.lower().endswith(".gguf") or "mmproj" in n.rsplit("/", 1)[-1].lower() or not tag.search(n):
        continue
    m = split.match(n)
    groups.setdefault((m.group(1), m.group(3)) if m else (n, ""), []).append(f)
if not groups:
    print("no it has no GGUF file for %s" % quant); sys.exit(0)
key = sorted(groups, key=lambda k: (len(k[0]), k))[0]
files = sorted(groups[key], key=lambda f: f["rfilename"])
if key[1] and len(files) != int(key[1]):
    print("no it has %d of the %d parts of %s" % (len(files), int(key[1]), key[0].rsplit("/", 1)[-1][:80])); sys.exit(0)
rows, total = [], 0
for f in files:
    n, lfs = f["rfilename"], f.get("lfs") if isinstance(f.get("lfs"), dict) else {}
    size, h, b = lfs.get("size", f.get("size")), str(lfs.get("sha256") or ""), str(f.get("blobId") or "")
    if not re.fullmatch(r"[A-Za-z0-9._/+-]{1,200}", n) or ".." in n.split("/"):
        print("no a file has a name this stack does not download (%s)" % n[:80]); sys.exit(0)
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0 or not (re.fullmatch(r"[0-9a-f]{64}", h) or (not h and re.fullmatch(r"[0-9a-f]{40}", b))):
        print("no Hugging Face did not give the size and hash of %s" % n[:80]); sys.exit(0)
    rows.append("%s\t%d\t%s\t%s\n" % (n, size, h, b)); total += size
with open(man, "w") as m:
    m.writelines(rows)
print("sha %s\t%s\t%d" % (sha, files[0]["rfilename"], total))
' "$body" "$2" "$3" 2>&1 | tail -n 1 | cut -c1-400
  rm -f "$body"
}
# _local_manifest_bytes MANIFEST REPO_DIR -> the bytes of its files that arrived (each finished blob, or its part)
_local_manifest_bytes() {
  local n=0 name size h b f
  while IFS=$'\t' read -r name size h b; do
    f="$2/blobs/${h:-$b}"
    if [ -f "$f" ]; then n=$((n + $(_rt_bytes "$f"))); elif [ -f "$f.part" ]; then n=$((n + $(_rt_bytes "$f.part"))); fi
  done < "$1"
  echo "$n"
}
# _local_pull_gguf RT REPO QUANT BYTES TOOLS CTX PM LIC — for llama.cpp or LM Studio: vet, download (lib/hf_fetch.py:
# the system's python3 -I, standard library only) into its hub/, add it to the runtime (llama.cpp: models.tsv,
# presets.ini, started again; LM Studio: lms import, its key), register
_local_pull_gguf() {
  local rt="$1" repo="$2" quant="$3" bytes="$4" tools="$5" ctx="$6" pm="$7" lic="$8" hub rd man v why='' sha='' first id logf pid done_b=0 rc=0 stop
  hub="$(rt_dir "$rt")/hub"; rd="$hub/models--${repo//\//--}"; id="$repo:$quant"
  valid_local_entry "$rt:$id" || { _local_job failed "$repo" "$quant" 0 "$bytes" "The model name is one this stack cannot serve."; die "unusable model id"; }
  _local_job pulling "$repo" "$quant" 0 "$bytes" "Finding the $quant files of $repo on Hugging Face"
  man="$(local_dir)/manifest.tsv"; : > "$man"; chmod 600 "$man"
  v="$(HF_TOKEN="$(get_env HF_TOKEN)" _local_gguf_vet "$repo" "$quant" "$man")"
  case "$v" in
    "sha "*) v="${v#sha }"; sha="${v%%$'\t'*}"; v="${v#*$'\t'}"; first="${v%%$'\t'*}"; v="${v#*$'\t'}"; [ "$v" -gt 0 ] 2>/dev/null && bytes="$v" ;;
    "no "*) why="${v#no }" ;;
    *) why="${v:-the check gave no answer}" ;;
  esac
  [ -n "$why" ] || { [[ $sha =~ ^[0-9a-f]{40}$ ]] && [ -n "$first" ]; } || why="the check did not give a revision and a file to download"
  if [ -n "$why" ]; then _local_job failed "$repo" "$quant" 0 "$bytes" "Not downloaded: $why."; die "not downloaded: $why"; fi
  stop="$(_local_stop_asked)"
  if [ -n "$stop" ]; then _local_stopped "$stop" "$rt" "$repo" "$quant" 0 "$bytes"; return 0; fi
  logf="$(local_dir)/pull.log"; : > "$logf"; chmod 600 "$logf"
  mkdir -p "$hub" && chmod 700 "$hub"
  ( export HF_TOKEN; HF_TOKEN="$(get_env HF_TOKEN)"; exec python3 -I "$STACK_DIR/lib/hf_fetch.py" "$repo" "$sha" "$hub" "$man" ) </dev/null > "$logf" 2>&1 &
  pid=$!; printf '%s\n' "$pid" > "$(local_dl_pid_file)"
  _local_speed_reset
  while kill -0 "$pid" 2>/dev/null; do
    done_b="$(_local_manifest_bytes "$man" "$rd")"
    _local_speed "$done_b" "$bytes"
    _local_job pulling "$repo" "$quant" "$done_b" "$bytes" "$(_local_dl_message "$repo:$quant")" "$_LS_RATE" "$_LS_ETA" "$_LS_STALLED"
    sleep "${LOCAL_POLL_S:-1}"
  done
  wait "$pid" || rc=$?
  rm -f "$(local_dl_pid_file)"
  stop="$(_local_stop_asked)"
  if [ "$stop" = cancel ] || { [ "$stop" = pause ] && [ "$rc" -ne 0 ]; }; then _local_stopped "$stop" "$rt" "$repo" "$quant" "$done_b" "$bytes"; return 0; fi
  rm -f "$(local_stop_file)"
  if [ "$rc" -ne 0 ]; then
    _local_job failed "$repo" "$quant" "$done_b" "$bytes" "The download stopped ($(tail -n 2 "$logf" | LC_ALL=C tr -cd ' -~\n' | tr '\n' ' ' | cut -c1-200)). What arrived is kept: Resume continues from it, Cancel deletes it. A gated model needs a Hugging Face token (Settings › Models & providers) and its license accepted on huggingface.co."
    die "the download failed"
  fi
  [ -f "$rd/snapshots/$sha/$first" ] || { _local_job failed "$repo" "$quant" "$done_b" "$bytes" "The download has no $first."; die "the download is incomplete"; }
  _local_job registering "$repo" "$quant" "$bytes" "$bytes" "Adding it to $(rt_name "$rt") and the model gateway (a few seconds)"
  if [ "$rt" = lmstudio ]; then
    rt_lmstudio_model_add "$id" "$repo" "models--${repo//\//--}/snapshots/$sha/$first" "$(cut -f1 "$man" | paste -sd, -)" \
      || { _local_job failed "$repo" "$quant" "$bytes" "$bytes" "Downloaded, but LM Studio did not take it (lms import): ./stack runtimes logs lmstudio. What arrived is kept: download it again to retry."; die "LM Studio did not take it"; }
  else
    rt_llamacpp_model_put "$id" "models--${repo//\//--}/snapshots/$sha/$first" "$ctx" "$(cut -f1 "$man" | paste -sd, -)" \
      || { _local_job failed "$repo" "$quant" "$bytes" "$bytes" "Downloaded, but it could not be added to llama.cpp (.state/runtimes/llamacpp)."; die "llama.cpp did not take it"; }
    rt_llamacpp_reload || { _local_job failed "$repo" "$quant" "$bytes" "$bytes" "Downloaded, but llama.cpp did not answer again after taking it: ./stack runtimes logs llamacpp"; die "llama.cpp did not start again"; }
  fi
  local_registry_put "$rt" "$id" "$repo" "$quant" "$bytes" "$lic" "$([ "$tools" = yes ] && echo 1 || { [ "$tools" = no ] && echo 0 || echo -; })" "$ctx" "$pm" "$sha"
  local_register_apply add "$rt:$id" || { _local_job failed "$repo" "$quant" "$bytes" "$bytes" "Downloaded, but the model gateway did not take it: ./stack local-models status"; die "registration failed"; }
  _local_job done "$repo" "$quant" "$bytes" "$bytes" "Ready: $(local_model_name "$rt:$id") is in Chat, the Code page and the terminal (the first answer waits while it loads)"
  rm -f "$(local_dir)/job.pid"
}

# --- model servers: any OpenAI-compatible endpoint (vLLM, Ollama, LM Studio, llama-server, TGI, another Mac's mlx_lm.server …) ---
# MODEL_SERVERS     name=http(s)://host[:port][/path] [;trust]  — comma list; the URL is stored without /v1 (added when used)
# MODEL_SERVER_KEYS name=key — a secret, never in a URL or an argument (curl reads its header from stdin; the key is in the
#                   gateway's generated config as a model's api_key, which that config's readers can see)
# MODEL_SERVER_MODELS name:model-id or name:* (all it serves) — what is registered, live, as ms/<name>/<id> at $0
# "This computer" is the managed runtime above (its downloads); a server on localhost/127.0.0.1/::1 is THIS computer's
# own, reached from the gateway container as host.docker.internal. ;trust trusts that one server's self-signed certificate.
# --- where a model server may NOT be (SSRF): cloud metadata and link-local targets are refused, whoever asks ---
# Loopback and private addresses stay allowed (that is the point: a model server on this computer or the LAN). Refused: 169.254.0.0/16
# (IMDS), 100.100.100.200 (Alibaba), fd00:ec2::254 (AWS IPv6 IMDS), fe80::/10, 0.0.0.0/8, multicast, broadcast and the reserved 240/4, and the names
# metadata.google.internal, metadata.azure.internal and instance-data. The name is resolved ONCE per probe, every
# address it gave is checked, and curl is pinned to the checked one (--resolve), so DNS cannot change the target between
# the check and the request. The gateway resolves on its own when it calls a model: a server whose name starts giving a
# refused address is taken out of the gateway at the next probe (about a minute); docs/security.md says what is left.
# msrv_target URL -> "ok<TAB>ADDRESS<TAB>HOST<TAB>PORT" (the checked address to pin) or "blocked|numeric|dns<TAB>reason":
# lib/msrv_target.py (python3 -I, standard library) is the one place an address is judged: canonical IP literals only (no
# octal, hex, short or leading-zero forms), every address a name resolves to checked, IPv4 wrapped in IPv6 (mapped,
# compatible, 6to4, Teredo, NAT64) included. No python3: refused (fails closed).
msrv_target() {
  command -v python3 >/dev/null 2>&1 || { printf 'blocked\tpython3 is needed to check a server address\n'; return 0; }
  python3 -I "$STACK_DIR/lib/msrv_target.py" "$1" 2>/dev/null || printf 'blocked\tthe address could not be checked\n'
}

valid_msrv_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,23}$ ]]; }
valid_msrv_entry() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,23}=https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?(\;trust)?$ ]] || [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,23}=https?://\[[0-9A-Fa-f:]+\](:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?(\;trust)?$ ]]; }
valid_msrv_list() {
  local v="$1" e n=0
  [ -z "$v" ] && return 0
  while IFS= read -r e; do e="$(printf '%s' "$e" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"; valid_msrv_entry "$e" || return 1; n=$((n + 1)); done < <(printf '%s\n' "$v" | tr ',' '\n')
  [ "$n" -le 8 ]
}
valid_msrv_keys() { [ -z "$1" ] && return 0; ! printf '%s' "$1" | tr ',' '\n' | grep -vE '^[a-z0-9][a-z0-9-]{0,23}=([0-9a-f]{16}:)?[A-Za-z0-9._~+/=-]{1,200}$' >/dev/null; }
valid_msrv_models() { [ -z "$1" ] || ! printf '%s' "$1" | tr ',' '\n' | grep -vE '^[a-z0-9][a-z0-9-]{0,23}:(\*|[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127})$' >/dev/null; }

# msrv_norm_url URL -> the stored form (scheme://host[:port][/path], no /v1, no trailing slash), or fails: userinfo, query and
# fragments are refused (a key in a URL would be logged)
msrv_norm_url() {
  local u="$1"
  case "$u" in http://* | https://*) ;; *) u="http://$u" ;; esac
  case "$u" in *@* | *\?* | *\#* | *' '*) return 1 ;; esac
  u="${u%/}"; u="${u%/v1}"; u="${u%/}"
  valid_msrv_entry "x=$u" || return 1
  printf '%s\n' "$u"
}
# _msrv_items KEY -> a comma list's items, one per line (the last one ends with a newline too)
_msrv_items() { get_env "$1" | tr ',' '\n' | awk 'NF'; }
msrv_rows() {   # name TAB url TAB trust(1|0)
  _msrv_items MODEL_SERVERS | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | while IFS= read -r e; do
    [ -n "$e" ] && valid_msrv_entry "$e" || continue
    n="${e%%=*}"; u="${e#*=}"; tr_=0; case "$u" in *';trust') tr_=1; u="${u%;trust}" ;; esac
    printf '%s\t%s\t%s\n' "$n" "$u" "$tr_"
  done
}
msrv_url() { msrv_rows | awk -F'\t' -v n="$1" '$1 == n && !d++ { print $2 }'; }
msrv_trust() { msrv_rows | awk -F'\t' -v n="$1" '$1 == n && !d++ { print $3 }'; }
# --- a key is bound to the address it was saved for: MODEL_SERVER_KEYS is name=<16 hex>:<key>, the hex being the first 16
# characters of sha256("<stored address>[;trust]"). Whatever changes MODEL_SERVERS (the form, ./stack config set, the
# portal's generic row, a hand-edited .env) the key stops matching and msrv_key returns nothing: it is sent only to the exact
# address (and trust setting) it was saved for. A key from before this binding (name=key, no hex) cannot be tied to the address it was
# typed for, so it is NOT used: it is ignored and reported ("enter it again"), never silently bound to whatever the
# address is today. (A colon is not in the key alphabet, so the separator is unambiguous.)
_msrv_hash() {   # _msrv_hash URL TRUST(1|0)
  local v="$1"; [ "${2:-0}" != 1 ] || v="$v;trust"
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$v" | shasum -a 256 | cut -c1-16; else printf '%s' "$v" | sha256sum | cut -c1-16; fi
}
# _msrv_key_raw NAME -> the stored value for NAME (hex:key, or a bare old-format key)
_msrv_key_raw() { _msrv_items MODEL_SERVER_KEYS | awk -F= -v n="$1" '$1 == n && !d++ { print substr($0, length(n) + 2) }'; }
# msrv_key_state NAME -> none (no key) | ok | moved (the address changed since) | old (saved before keys were tied to an address)
msrv_key_state() {
  local raw u tr_; raw="$(_msrv_key_raw "$1")"
  [ -n "$raw" ] || { printf 'none\n'; return 0; }
  [[ $raw =~ ^[0-9a-f]{16}:. ]] || { printf 'old\n'; return 0; }
  u="$(msrv_url "$1")"; tr_="$(msrv_trust "$1")"
  if [ -n "$u" ] && [ "${raw%%:*}" = "$(_msrv_hash "$u" "$tr_")" ]; then printf 'ok\n'; else printf 'moved\n'; fi
}
# msrv_key NAME -> the key, only when it is bound to this server's current address; nothing otherwise
msrv_key() { [ "$(msrv_key_state "$1")" = ok ] || return 0; _msrv_key_raw "$1" | cut -d: -f2-; }
# msrv_key_note NAME -> why a stored key is not used (nothing when there is none or it is in use)
msrv_key_note() {
  case "$(msrv_key_state "$1")" in
    moved) printf 'key cleared: the address changed\n' ;;
    old) printf 'key not used: it was saved before keys were tied to an address; enter it again\n' ;;
  esac
}
# _msrv_bound NAME URL TRUST KEY -> the MODEL_SERVER_KEYS entry for it
_msrv_bound() { printf '%s=%s:%s' "$1" "$(_msrv_hash "$2" "$3")" "$4"; }
# msrv_gateway_url NAME -> the base the gateway container uses: localhost, 127.x, ::1 and 0.0.0.0 are THIS computer (the
# container's own loopback is not), reached as host.docker.internal
msrv_gateway_url() {
  local u addr scheme rest hp path host port ghost
  u="$(msrv_url "$1")"; addr="$(msrv_addr_of "$1")"
  [ -n "$u" ] && [ -n "$addr" ] || return 1      # (an address that was never validated is never given to the gateway)
  scheme="${u%%://*}"; rest="${u#*://}"; hp="${rest%%/*}"; path="${rest#"$hp"}"
  case "$hp" in
    \[*\]*) host="${hp%%]*}]"; port="${hp#"$host"}" ;;
    *) host="${hp%%:*}"; port="${hp#"$host"}" ;;
  esac
  case "$addr" in
    127.* | ::1 | ::ffff:127.*) ghost=host.docker.internal ;;                  # this computer (the container's own loopback is not)
    *) if [ "$scheme" = http ]; then case "$addr" in *:*) ghost="[$addr]" ;; *) ghost="$addr" ;; esac; else ghost="$host"; fi ;;   # http: the checked address; https: the name (SNI)
  esac
  printf '%s://%s%s%s/v1\n' "$scheme" "$ghost" "$port" "$path"
}
msrv_addr_of() { awk -F'\t' -v n="$1" '$1 == n && !d++ { print $5 }' "$(msrv_state_file)" 2>/dev/null || true; }
msrv_reached_as() {
  local g a; g="$(msrv_gateway_url "$1")" || { printf 'not checked yet, or refused\n'; return 0; }; a="$(msrv_addr_of "$1")"
  case "$g" in
    *host.docker.internal*) printf 'this computer, reached from the gateway as %s\n' "$g" ;;
    http://*) [ "$g" = "$(msrv_url "$1")/v1" ] && printf '%s\n' "$g" || printf 'reached by the checked address %s (the name is kept for display)\n' "$a" ;;
    *) printf '%s (by name, re-checked about once a minute)\n' "$g" ;;
  esac
}
# msrv_warn URL -> a plain-http warning for a public address (private ranges, localhost and *.local/ts.net are fine)
msrv_warn() {   # msrv_warn URL [TRUST(1|0) [CHECKED_ADDRESS]]
  case "$1" in
    https://*) [ "${2:-0}" = 1 ] && [ -n "${3:-}" ] && ! _msrv_private "$3" && printf 'Self-signed certificate trusted on a public address: it cannot be told apart from an impostor. Prefer a CA-signed certificate.\n'
               return 0 ;;
    http://localhost* | http://127.* | http://\[::1\]* | http://10.* | http://192.168.* | http://172.1[6-9].* | http://172.2[0-9].* | http://172.3[01].* | http://100.* | http://*.local* | http://*.ts.net* | http://*.internal* | http://host.docker.internal*) return 0 ;;
  esac
  printf 'This is plain http to a public address: prompts and answers travel unencrypted. Use https if the server has it.\n'
}
# _msrv_private ADDR -> 0 for a loopback or private address (ADDR in msrv_target's standard form)
_msrv_private() {
  case "$1" in
    127.* | ::1 | ::ffff:127.* | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].* | ::ffff:10.* | ::ffff:192.168.* | fc* | fd*) return 0 ;;
  esac
  return 1
}
# _msrv_classify CURL_RC HTTP -> the reason in words for the first thing that failed
_msrv_classify() {
  case "$1:$2" in
    0:200) return 1 ;;
    6:*) echo "its name does not resolve (DNS) from this computer" ;;
    7:*) echo "connection refused: nothing is listening at that address and port, or a firewall is in the way" ;;
    28:*) echo "no answer in time (the host is down or not reachable from here)" ;;
    35:* | 51:* | 58:* | 59:* | 60:* | 77:*) echo "its TLS certificate is not trusted (self-signed?): add the server with the trust option for this one server" ;;
    0:401 | 0:403) echo "$2: the server wants an API key, or this one is wrong" ;;
    0:404) echo "no /v1/models at that address (is it an OpenAI-compatible server? try without or with a path)" ;;
    0:*) echo "the server answered HTTP $2 to /v1/models" ;;
    *) echo "could not connect (curl error $1)" ;;
  esac
}
# _msrv_loopback ADDR -> 0 for this computer's own address (ADDR in msrv_target's standard form: 127.x.x.x, ::1, ::ffff:127.x.x.x)
_msrv_loopback() { case "$1" in 127.*.*.* | ::1 | ::ffff:127.*.*.*) return 0 ;; esac; return 1; }
# msrv_probe NAME -> prints "ok<TAB>id|ctx;id|ctx<TAB>ADDR" or "down<TAB>reason<TAB>ADDR" (ADDR: the checked address) or "blocked|numeric|dns<TAB>reason<TAB>" ; GET <base>/v1/models, key via stdin config
msrv_probe() {
  local n="$1" u; u="$(msrv_url "$n")"; [ -n "$u" ] || { printf 'down\tno such server\t\n'; return 0; }
  msrv_probe_url "$u" "$(msrv_key "$n")" "$(msrv_trust "$n")"
}
# msrv_probe_url URL KEY TRUST(1|0) [loopback] -> the same three fields for an address that is not saved (yet): what the Add
# form probes. loopback: the password-free Check server — only this computer's own addresses, judged on the address the
# probe is pinned to (so no name can resolve to loopback for the check and elsewhere for the request)
msrv_probe_url() {
  local u="$1" k="$2" tr_="$3" only="${4:-}" http rc=0 f args=() reason ids tgt pin_ph pin_h pin_p addr
  tgt="$(msrv_target "$u")"
  case "$tgt" in
    ok*) IFS=$'\t' read -r _ addr pin_h pin_p <<< "$tgt"; pin_ph="$addr"
         if [ "$only" = loopback ] && ! _msrv_loopback "$addr"; then
           printf 'blocked\t%s is another computer: checking it asks for your portal password\t\n' "$addr"; return 0
         fi
         case "$pin_ph" in *:*) pin_ph="[$pin_ph]" ;; esac
         case "$pin_h" in *[!0-9.]*) case "$pin_h" in *:*) ;; *) args+=(--resolve "$pin_h:$pin_p:$pin_ph") ;; esac ;; esac ;;   # (pinned: DNS cannot change the target now)
    *) printf '%s\t%s\t\n' "${tgt%%$'\t'*}" "${tgt#*$'\t'}"; return 0 ;;   # (blocked, numeric, dns: no address, so nothing registered)
  esac
  f="$(mktemp)"; [ "$tr_" != 1 ] || args+=(-k)
  http="$( { [ -z "$k" ] || printf 'header = "Authorization: Bearer %s"\n' "$k"; } | curl -g -sS -m 8 --max-redirs 0 -o "$f" -w '%{http_code}' -K - "${args[@]+"${args[@]}"}" "$u/v1/models" 2>/dev/null)" || rc=$?
  if reason="$(_msrv_classify "$rc" "${http:-000}")"; then rm -f "$f"; printf 'down\t%s\t%s\n' "$reason" "$addr"; return 0; fi
  ids="$(tr '\n' ' ' < "$f" | LC_ALL=C awk '{
    s = $0; out = ""
    while (match(s, /"id" *: *"[A-Za-z0-9][A-Za-z0-9._:\/@+-]*"/)) {
      id = substr(s, RSTART, RLENGTH); sub(/^"id" *: *"/, "", id); sub(/"$/, "", id)
      s = substr(s, RSTART + RLENGTH); seg = s; if (match(s, /"id" *:/)) seg = substr(s, 1, RSTART)
      ctx = 0; if (match(seg, /"(max_model_len|max_context_length|context_length|context_window)" *: *[0-9]+/)) { c = substr(seg, RSTART, RLENGTH); sub(/^.*: */, "", c); ctx = c + 0 }
      out = out (out == "" ? "" : ";") id "|" ctx
    } print out }')"
  rm -f "$f"
  if [ -z "$ids" ]; then printf 'down\tit answered, but /v1/models lists no models\t%s\n' "$addr"; else printf 'ok\t%s\t%s\n' "$ids" "$addr"; fi
}
msrv_state_file() { printf '%s/servers.tsv\n' "$(local_dir)"; }
# msrv_probe_all -> servers.tsv (name, status, reason-or-models, at) for every server; also the portal's file
msrv_probe_all() {
  local n r out was now pst pdetail paddr; mkdir -p "$(local_dir)"; out="$(mktemp)"
  was="$({ awk -F'\t' '$5 != "" { print $1 }' "$(msrv_state_file)" 2>/dev/null || true; } | sort | paste -sd, -)"
  while IFS=$'\t' read -r n _; do
    [ -n "$n" ] || continue
    r="$(msrv_probe "$n")"
    IFS=$'\t' read -r pst pdetail paddr <<< "$r"
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$pst" "$pdetail" "$(date +%s)" "$paddr" >> "$out"
  done < <(msrv_rows)
  chmod 600 "$out"; mv -f "$out" "$(msrv_state_file)"
  now="$({ awk -F'\t' '$5 != "" { print $1 }' "$(msrv_state_file)" || true; } | sort | paste -sd, -)"
  # (a server whose name started giving a refused address leaves the gateway, or comes back, at once)
  # (in a subshell: a settings change that finds nothing to change ends with an error, which must not end this)
  if [ "$was" != "$now" ] && declare -F config_apply >/dev/null; then
    ( CFG_ORDER=''; cfg_put MODEL_SERVER_MODELS "$(get_env MODEL_SERVER_MODELS)"; config_apply local cli '' ) >/dev/null 2>&1 || true
  fi
}
msrv_status_of() { awk -F'\t' -v n="$1" '$1 == n { print $2 "\t" $3; exit }' "$(msrv_state_file)" 2>/dev/null; }
# msrv_enabled -> TAB rows "name id ctx" for what MODEL_SERVER_MODELS registers (name:* = all the last probe saw)
msrv_enabled() {
  local e n id st
  _msrv_items MODEL_SERVER_MODELS | while IFS= read -r e; do
    [ -n "$e" ] || continue; n="${e%%:*}"; id="${e#*:}"; msrv_url "$n" >/dev/null 2>&1 && [ -n "$(msrv_url "$n")" ] || continue
    st="$(msrv_status_of "$n")"
    [ -n "$(msrv_addr_of "$n")" ] || continue     # (fail closed: only a server whose address passed the check is registered)
    case "${st%%$'\t'*}" in ok | down) ;; *) continue ;; esac
    if [ "$id" = '*' ]; then
      [ "${st%%$'\t'*}" = ok ] && printf '%s' "${st#*$'\t'}" | tr ';' '\n' | awk -F'|' -v n="$n" 'NF >= 2 { print n "\t" $1 "\t" $2 }'
    else
      printf '%s\t%s\t%s\n' "$n" "$id" "$(printf '%s' "${st#*$'\t'}" | tr ';' '\n' | awk -F'|' -v i="$id" '$1 == i { print $2; exit }')"
    fi
  done | awk -F'\t' '!s[$1 "/" $2]++' | head -n "$LOCAL_MODELS_MAX"
}
msrv_yaml() {
  local n id ctx key base note
  while IFS=$'\t' read -r n id ctx; do
    base="$(msrv_gateway_url "$n")" || continue; key="$(msrv_key "$n")"
    [ -n "$key" ] || { note="$(msrv_key_note "$n")"; [ -z "$note" ] || warn "model server $n: $note" >&2; }
    printf '  - model_name: "ms/%s/%s"\n    litellm_params:\n      model: "openai/%s"\n      api_base: "%s"\n      api_key: "%s"\n%s      timeout: 600\n      input_cost_per_token: 0\n      output_cost_per_token: 0\n    model_info:\n      mode: "chat"\n' \
      "$n" "$id" "$id" "$base" "${key:-none}" "$([ "$(msrv_trust "$n")" = 1 ] && printf '      ssl_verify: false\n')"
  done < <(msrv_enabled)
}
# msrv_code_rows -> rows for the Code page: id name vendor compat note max_out context
msrv_code_rows() {
  local n id ctx st mo note
  while IFS=$'\t' read -r n id ctx; do
    st="$(msrv_status_of "$n")"; mo="$LOCAL_MAX_OUT"; case "$ctx" in '' | 0 | *[!0-9]*) ctx=- ;; *) [ "$((ctx / 2))" -ge "$mo" ] || mo=$((ctx / 2)) ;; esac
    note="On $n ($(msrv_reached_as "$n")). Tool use is not known: a self-hosted model may call tools wrongly or not at all; each answer is capped at $LOCAL_MAX_OUT tokens. Free to use."
    [ "${st%%$'\t'*}" != down ] || note="UNAVAILABLE at the last check: ${st#*$'\t'}. $note"
    printf 'ms/%s/%s\t%s\t%s\tuntested\t%s\t%s\t%s\n' "$n" "$id" "$(printf '%s' "$id" | tr -d '\t"\\')" "$n" "$(printf '%s' "$note" | tr -d '\t"\\')" "$mo" "$ctx"
  done < <(msrv_enabled)
}
# msrv_set_list KEY NEW — one settings change (live in LiteLLM)
msrv_put() { CFG_ORDER=''; cfg_put "$1" "$2"; config_apply local cli ''; }
msrv_add() {  # msrv_add NAME URL [--trust] — the key (if any) is given with ./stack local-models server key NAME
  local n="${1:-}" u="${2:-}" trust="${3:-}" cur new ne r w
  valid_msrv_name "$n" || die "the name is lowercase letters, digits and - (at most 24)"
  u="$(msrv_norm_url "$u")" || die "that is not a server address: use http(s)://host[:port] (no user:password@, no query)"
  [ -z "$(msrv_url "$n")" ] || die "there is already a server named $n (./stack local-models server rm $n first)"
  ne="$n=$u"; [ "$trust" != --trust ] || ne="$ne;trust"
  cur="$(get_env MODEL_SERVERS)"; new="${cur:+$cur,}$ne"
  valid_msrv_list "$new" || die "too many servers (8 at most) or an unusable address"
  r="$(msrv_target "$u")"
  case "$r" in blocked* | numeric*) die "refused: ${r#*$'\t'}" ;; esac
  w="$(msrv_warn "$u" "$([ "$trust" = --trust ] && echo 1 || echo 0)" "$(printf '%s' "$r" | cut -f2)")"; [ -z "$w" ] || warn "$w"
  CFG_ORDER=''; cfg_put MODEL_SERVERS "$new"; config_apply local cli ''
  log "added $n ($(msrv_reached_as "$n")); probing"
  msrv_probe_all; local_status_write
  msrv_status_of "$n" | awk -F'\t' '{ printf "  %s: %s\n", $1, $2 }'
}
msrv_rm() {
  local n="${1:-}" keep='' e new='' k2=''
  [ -n "$(msrv_url "$n")" ] || die "no server named $n"
  while IFS= read -r e; do [ -n "$e" ] && [ "${e%%=*}" != "$n" ] && new="${new:+$new,}$e"; done < <(_msrv_items MODEL_SERVERS)
  while IFS= read -r e; do [ -n "$e" ] && [ "${e%%=*}" != "$n" ] && k2="${k2:+$k2,}$e"; done < <(_msrv_items MODEL_SERVER_KEYS)
  while IFS= read -r e; do [ -n "$e" ] && [ "${e%%:*}" != "$n" ] && keep="${keep:+$keep,}$e"; done < <(_msrv_items MODEL_SERVER_MODELS)
  CFG_ORDER=''; cfg_put MODEL_SERVER_MODELS "$keep"; cfg_put MODEL_SERVER_KEYS "$k2"; cfg_put MODEL_SERVERS "$new"
  config_apply local cli ''      # (its models leave the gateway live)
  msrv_probe_all; local_status_write; log "removed $n and unregistered its models"
}
msrv_enable() {  # msrv_enable NAME ID|* | msrv_disable NAME ID|*
  local n="${1:-}" id="${2:-}" cur new
  [ -n "$(msrv_url "$n")" ] || die "no server named $n"
  [[ $id =~ ^(\*|[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127})$ ]] || die "not a model id: $id"
  cur="$(get_env MODEL_SERVER_MODELS)"
  if [ "$3" = on ]; then new="${cur:+$cur,}$n:$id"; else new="$(printf '%s' "$cur" | tr ',' '\n' | grep -vxF "$n:$id" | paste -sd, -)"; fi
  valid_msrv_models "$new" || die "unusable model list"
  msrv_probe_all
  msrv_put MODEL_SERVER_MODELS "$new"; local_status_write
  return 0
}
msrv_set_key() {  # the key is read from the terminal (no echo) or stdin, never from an argument
  local n="${1:-}" k
  [ -n "$(msrv_url "$n")" ] || die "no server named $n"
  if [ -t 0 ]; then printf 'API key for %s (not shown): ' "$n" >&2; read -rs k; echo >&2; else IFS= read -r k; fi
  msrv_store_key "$n" "$k"
}
# msrv_store_key NAME KEY ('' removes it): the key is stored and the gateway reloaded
msrv_store_key() {
  local n="$1" k="$2" new='' e
  [[ $k =~ ^[A-Za-z0-9._~+/=-]{1,200}$ ]] || [ -z "$k" ] || die "that does not look like an API key"
  while IFS= read -r e; do [ -n "$e" ] && [ "${e%%=*}" != "$n" ] && new="${new:+$new,}$e"; done < <(_msrv_items MODEL_SERVER_KEYS)
  [ -z "$k" ] || new="${new:+$new,}$(_msrv_bound "$n" "$(msrv_url "$n")" "$(msrv_trust "$n")" "$k")"
  CFG_ORDER=''; cfg_put MODEL_SERVER_KEYS "$new"; msrv_probe_all; config_apply local cli ''; local_status_write
  log "key for $n $([ -n "$k" ] && echo stored || echo removed)"
  return 0
}

# --- the Settings form (the portal's Add a server / per-server rows): ./stack local-models server apply FILE, FILE being
# op=, name=, url=, trust=, key= (base64), models= (id,id or *), ref= lines (written by the update helper, mode 600, removed here).
# Every call ends with .state/local-models/server-result.json (what the form shows); the key is never in it, in status or in a log.
_msrv_field() { awk -F= -v k="$1" '$1 == k && !d++ { print substr($0, length(k) + 2) }' "$2"; }
# msrv_result REF OP NAME OK(true|false) MESSAGE [STATUS DETAIL WARNING REACHED KEY(true|false) TRUST URL]
msrv_result() {
  local d; d="$(local_dir)"; mkdir -p "$d"
  printf '{"ref":%s,"op":%s,"name":%s,"ok":%s,"message":%s,"status":%s,"detail":%s,"warning":%s,"reached_as":%s,"key":%s,"trust":%s,"url":%s,"at":%s}\n' \
    "$(_local_q "$1" 32)" "$(_local_q "$2" 10)" "$(_local_q "$3" 24)" "$4" "$(_local_q "$5" 400)" "$(_local_q "${6:-}" 8)" "$(_local_q "${7:-}" 2000)" \
    "$(_local_q "${8:-}" 200)" "$(_local_q "${9:-}" 240)" "${10:-false}" "${11:-false}" "$(_local_q "${12:-}" 200)" "$(date +%s)" | _local_put "$(local_dir)/server-result.json"
}
# _msrv_models_for NAME LIST -> MODEL_SERVER_MODELS with NAME's entries replaced by LIST (id,id or *)
_msrv_models_for() {
  local n="$1" list="$2" e out='' i
  while IFS= read -r e; do [ -n "$e" ] && [ "${e%%:*}" != "$n" ] && out="${out:+$out,}$e"; done < <(_msrv_items MODEL_SERVER_MODELS)
  while IFS= read -r i; do [ -n "$i" ] && out="${out:+$out,}$n:$i"; done < <(printf '%s\n' "$list" | tr ',' '\n')
  printf '%s\n' "$out"
}
msrv_apply() {
  local rf="${1:-}" op name url trust key models ref k='' u tr_=0 r st detail addr warn n lockd i=0 msg rc=0 out
  [ -f "$rf" ] || die "no request file"
  op="$(_msrv_field op "$rf")"; name="$(_msrv_field name "$rf")"; url="$(_msrv_field url "$rf")"; trust="$(_msrv_field trust "$rf")"
  key="$(_msrv_field key "$rf")"; models="$(_msrv_field models "$rf")"; ref="$(_msrv_field ref "$rf")"; rm -f "$rf"
  [[ $ref =~ ^[0-9a-f]{8,32}$ ]] || ref=0
  [ "$trust" != true ] || tr_=1
  [ -z "$key" ] || k="$(printf '%s' "$key" | base64 -d 2>/dev/null || true)"
  [[ $k =~ ^[A-Za-z0-9._~+/=-]{0,200}$ ]] || { msrv_result "$ref" "$op" "$name" false "that does not look like an API key"; return 0; }
  lockd="$(local_dir)/server.lock.d"; mkdir -p "$(local_dir)"
  until mkdir "$lockd" 2>/dev/null; do                                     # (one at a time; a lock left by a killed run goes after 2 minutes)
    [ -z "$(find "$lockd" -mmin +2 2>/dev/null)" ] || rmdir "$lockd" 2>/dev/null || true
    i=$((i + 1)); [ "$i" -le 120 ] || { msrv_result "$ref" "$op" "$name" false "another change to the servers is still running; try again"; return 0; }; sleep 1
  done
  case "$op" in
    probe | probe-local)
      u="$(msrv_norm_url "$url")" || { rmdir "$lockd"; msrv_result "$ref" probe "$name" false "that is not a server address: use http(s)://host[:port] (no user:password@, no query)"; return 0; }
      # (a stored key goes only to that server's own saved address: never to a new address typed under its name)
      if [ "$op" = probe ] && [ -z "$k" ] && [ -n "$name" ] && [ "$u" = "$(msrv_url "$name")" ] && [ "$tr_" = "$(msrv_trust "$name")" ]; then k="$(msrv_key "$name")"; fi
      # (probe-local: the helper's password-free Check server — this computer's addresses only)
      r="$(msrv_probe_url "$u" "$k" "$tr_" "$([ "$op" = probe-local ] && echo loopback)")"; IFS=$'\t' read -r st detail addr <<< "$r"
      msrv_result "$ref" probe "$name" true "" "$st" "$detail" "$(msrv_warn "$u" "$tr_" "$addr")" "" "$([ -n "$k" ] && echo true || echo false)" "$([ "$tr_" = 1 ] && echo true || echo false)" "$u" ;;
    *)
      out="$( ( msrv_apply_op "$op" "$name" "$url" "$tr_" "$k" "$models" ) 2>&1 )" || rc=$?
      msg="$(printf '%s\n' "$out" | tail -n 1 | sed -e 's/^xx  //' -e 's/^[[:space:]]*//')"
      if [ "$rc" = 0 ]; then msrv_result "$ref" "$op" "$name" true "$msg"; else msrv_result "$ref" "$op" "$name" false "${msg:-that did not work}"; fi ;;
  esac
  rmdir "$lockd" 2>/dev/null || true
  local_status_write 2>/dev/null || true
}
# msrv_apply_op OP NAME URL TRUST(1|0) KEY MODELS — run in a subshell by msrv_apply (a die ends only it)
msrv_apply_op() {
  local op="$1" n="$2" url="$3" tr_="$4" k="$5" models="$6" u ne cur new old e r st detail addr keys keyout=''
  case "$op" in
    save)     # a new server, or (the name is taken) a changed address for one: its key then goes unless a new one comes with it
      valid_msrv_name "$n" || die "the name is lowercase letters, digits and - (at most 24)"
      u="$(msrv_norm_url "$url")" || die "that is not a server address: use http(s)://host[:port] (no user:password@, no query)"
      ne="$n=$u"; [ "$tr_" != 1 ] || ne="$ne;trust"
      old="$(msrv_url "$n")"; new=''
      if [ -n "$old" ]; then
        while IFS= read -r e; do [ -n "$e" ] || continue; if [ "${e%%=*}" = "$n" ]; then new="${new:+$new,}$ne"; else new="${new:+$new,}$e"; fi; done < <(_msrv_items MODEL_SERVERS)
      else cur="$(get_env MODEL_SERVERS)"; new="${cur:+$cur,}$ne"; fi
      valid_msrv_list "$new" || die "too many servers (8 at most) or an unusable address"
      keys=''; while IFS= read -r e; do [ -n "$e" ] && [ "${e%%=*}" != "$n" ] && keys="${keys:+$keys,}$e"; done < <(_msrv_items MODEL_SERVER_KEYS)
      if [ -n "$k" ]; then keys="${keys:+$keys,}$(_msrv_bound "$n" "$u" "$tr_" "$k")"      # (a key sent with the request is the only one used)
      elif [ -n "$old" ] && [ "$u" = "$old" ] && [ "$tr_" = "$(msrv_trust "$n")" ]; then   # (the same address and trust: its key stays)
        k="$(msrv_key "$n")"; [ -z "$k" ] || keys="${keys:+$keys,}$(_msrv_bound "$n" "$u" "$tr_" "$k")"
      elif [ -n "$old" ] && [ "$u" = "$old" ] && [ -n "$(_msrv_key_raw "$n")" ]; then    # (trust changed: the key is typed again for it)
        keyout='; key cleared: the certificate setting changed'; warn "key for $n cleared: whether its certificate is checked changed — enter the key again"
      elif [ -n "$(_msrv_key_raw "$n")" ]; then keyout='; key cleared: the address changed'; warn "key for $n cleared: the address changed"
      fi                                                                                   # (a changed address without a key: none)
      r="$(msrv_probe_url "$u" "$k" "$tr_")"; IFS=$'\t' read -r st detail addr <<< "$r"
      case "$st" in blocked | numeric | dns) die "refused: $detail" ;; esac
      valid_msrv_models "$(_msrv_models_for "$n" "$models")" || die "unusable model list"
      if [ -z "$addr" ]; then die "that address could not be checked"; fi
      mkdir -p "$(local_dir)"                                                # (its checked address is known before it registers: models need it)
      { { grep -v "^$n"$'\t' "$(msrv_state_file)" 2>/dev/null || true; }; printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$st" "$detail" "$(date +%s)" "$addr"; } | _local_put "$(msrv_state_file)"
      CFG_ORDER=''; cfg_put MODEL_SERVERS "$new"; cfg_put MODEL_SERVER_KEYS "$keys"
      cfg_put MODEL_SERVER_MODELS "$(_msrv_models_for "$n" "$models")"
      config_apply local cli ''
      msrv_probe_all; log "saved $n: $st$keyout" ;;
    models)
      [ -n "$(msrv_url "$n")" ] || die "no server named $n"
      new="$(_msrv_models_for "$n" "$models")"; valid_msrv_models "$new" || die "unusable model list"
      [ "$new" != "$(get_env MODEL_SERVER_MODELS)" ] || { log "nothing to change"; return 0; }
      msrv_probe_all; CFG_ORDER=''; cfg_put MODEL_SERVER_MODELS "$new"; config_apply local cli ''; log "models for $n changed" ;;
    key)
      [ -n "$(msrv_url "$n")" ] || die "no server named $n"
      msrv_store_key "$n" "$k" ;;
    remove)
      msrv_rm "$n" ;;
    *) die "not an operation: $op" ;;
  esac
}

# local_runtime -> "mlx", "dmr", "ollama", "llamacpp", "lmstudio" or "none": the one pulls go to. LOCAL_RUNTIME names one
# (none while it cannot take a download: local_how_text says why); blank or auto: MLX on Apple silicon with uv, else Docker
# Model Runner, else Ollama, else DevOS ADE's llama.cpp, else its LM Studio
local_runtime() {
  case "$(get_env LOCAL_RUNTIME)" in
    mlx) local_mlx_capable && echo mlx || echo none; return 0 ;;
    dmr) [ "$(local_dmr_state)" = ready ] && echo dmr || echo none; return 0 ;;
    ollama) [ "$(local_ollama_state)" = ready ] && echo ollama || echo none; return 0 ;;
    llamacpp) [ "$(local_llamacpp_state)" = ready ] && echo llamacpp || echo none; return 0 ;;
    lmstudio) [ "$(local_lmstudio_state)" = ready ] && echo lmstudio || echo none; return 0 ;;
  esac
  ! local_mlx_capable || { echo mlx; return 0; }
  [ "$(local_dmr_state)" != ready ] || { echo dmr; return 0; }
  [ "$(local_ollama_state)" != ready ] || { echo ollama; return 0; }
  [ "$(local_llamacpp_state)" != ready ] || { echo llamacpp; return 0; }
  [ "$(local_lmstudio_state)" != ready ] || { echo lmstudio; return 0; }
  echo none
}
# _local_ollama_how -> how to have an Ollama running (DevOS ADE's own, from Runtimes; or one of yours)
_local_ollama_how() {
  if declare -F rt_installed >/dev/null && rt_installed ollama; then echo "start it in Settings › Local models › Runtimes (./stack runtimes start ollama)."
  else echo "install it in Settings › Local models › Runtimes (./stack runtimes install ollama), or start an Ollama of yours."; fi
}

# _local_own_how ID -> how to have DevOS ADE's llama.cpp or LM Studio running
_local_own_how() {
  if [ "$("local_${1}_state")" = not-running ]; then echo "start it in Settings › Local models › Runtimes (./stack runtimes start $1)."
  else echo "install it in Settings › Local models › Runtimes (./stack runtimes install $1)."; fi
}

# local_how_text -> one line: how to turn a runtime on (for the portal, and ./stack local-models enable)
local_how_text() {
  local d o; d="$(local_dmr_state)"; o="$(local_ollama_state)"
  case "$(get_env LOCAL_RUNTIME)" in
    ollama) [ "$o" = ready ] || { echo "Downloads go to Ollama (Settings › Local models › Runtimes), which is not running: $(_local_ollama_how)"; return 0; } ;;
    llamacpp | lmstudio) [ "$("local_$(get_env LOCAL_RUNTIME)_state")" = ready ] || { echo "Downloads go to $(rt_name "$(get_env LOCAL_RUNTIME)") (Settings › Local models › Runtimes), which is not running: $(_local_own_how "$(get_env LOCAL_RUNTIME)")"; return 0; } ;;
    mlx) local_mlx_capable || { echo "Downloads go to MLX (Settings › Local models › Runtimes), which needs Apple silicon and uv: brew install uv (or https://docs.astral.sh/uv/)."; return 0; } ;;
  esac
  [ "$(local_mlx_state)" != no-uv ] || { echo "On Apple silicon the models run with MLX, which needs uv: brew install uv (or https://docs.astral.sh/uv/), then download again. Docker Model Runner (Docker Desktop 4.71 or newer) also works."; return 0; }
  case "$d" in
    not-enabled)
      if docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep "Docker Desktop" >/dev/null; then
        echo "Docker Model Runner is built into Docker Desktop but switched off: turn it on in Docker Desktop › Settings › AI, or run ./stack local-models enable."
      else echo "Docker Model Runner is not running: ./stack local-models enable starts it (docker model install-runner)."; fi ;;
    plugin-missing)
      case "$(uname -s)" in
        Linux) echo "Docker Model Runner's plugin is not installed: ./stack local-models enable installs docker-model-plugin (needs sudo), or sudo apt-get install docker-model-plugin / sudo dnf install docker-model-plugin." ;;
        *) echo "This Docker has no model runner: update Docker Desktop, then ./stack local-models enable." ;;
      esac ;;
    not-installed) echo "Docker is not installed here: Docker Model Runner comes with Docker Desktop (or docker-model-plugin on Linux)." ;;
    *) case "$o" in not-running) echo "Ollama is installed but not running: start it (ollama serve, or its app)." ;; *) echo "A model runner is running." ;; esac ;;
  esac
}

# --- the machine: memory and GPU, for "fits this machine" in the portal ---
# local_memory_bytes -> this computer's RAM
local_memory_bytes() {
  local b=''
  case "$(uname -s)" in
    Darwin) b="$(sysctl -n hw.memsize 2>/dev/null || true)" ;;
    *) b="$(awk '/^MemTotal:/ { print $2 * 1024; exit }' /proc/meminfo 2>/dev/null || true)" ;;
  esac
  case "$b" in '' | *[!0-9]*) echo 0 ;; *) echo "$b" ;; esac
}
# local_gpu -> "metal" (Apple silicon: unified memory), "cuda:<VRAM bytes>" (NVIDIA), or "none"
local_gpu() {
  local v
  if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then echo metal; return 0; fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    v="$(_with_deadline 6 nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -dc '0-9' || true)"
    if [ -n "$v" ]; then echo "cuda:$((v * 1048576))"; return 0; fi
  fi
  echo none
}

# --- the registry: what ./stack downloaded ---
# a row: runtime id repo quant bytes license tools context params_m added revision   (TAB; "-" = unknown)
_local_clean() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._:/+-' | cut -c1-"${2:-128}"; }
local_registry_rows() { [ -r "$(local_registry)" ] && grep -v '^#' "$(local_registry)" || true; }
local_registry_put() { # local_registry_put RUNTIME ID REPO QUANT BYTES LICENSE TOOLS CTX PARAMS_M [REVISION]
  local f tmp; f="$(local_registry)"; mkdir -p "$(local_dir)" && chmod 700 "$(local_dir)" 2>/dev/null || true
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  { local_registry_rows | awk -F'\t' -v r="$1" -v i="$2" '!($1 == r && $2 == i)'
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "$(date +%s)" "${10:--}"
  } > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$f"
}
local_registry_drop() { # local_registry_drop RUNTIME ID
  local f tmp; f="$(local_registry)"; [ -f "$f" ] || return 0
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  local_registry_rows | awk -F'\t' -v r="$1" -v i="$2" '!($1 == r && $2 == i)' > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$f"
}
local_registry_row() { local_registry_rows | awk -F'\t' -v r="$1" -v i="$2" '!f && $1 == r && $2 == i { print; f = 1 }'; }
# the registry row of a LOCAL_MODELS entry
local_entry_row() { local_registry_row "${1%%:*}" "${1#*:}"; }

# --- Code page / terminal rows ---
# local_model_compat TOOLS PARAMS_M -> "STATUS<TAB>NOTE": how a local model fares as Claude Code's model, honestly. Claude
# Code needs tool calls; small local models are weak at them and can loop (JON-805 hardened the Llama case): a model
# under 3B parameters, or whose chat template has no tool support, is chat only; under 7B, warned; every local model's
# answer is capped at LOCAL_MAX_OUT tokens so a stuck one stops.
local_model_compat() {
  local tools="$1" pm="$2"
  case "$pm" in '' | - | *[!0-9]*) pm='' ;; esac
  if [ "$tools" = no ]; then
    printf 'chat-only\tIts chat template has no tool-call support, so Claude Code can only chat with it: it cannot read, edit or run anything. Runs on this computer, $0.\n'
  elif [ -n "$pm" ] && [ "$pm" -lt "$LOCAL_TINY_PARAMS_M" ]; then
    printf 'chat-only\tA model this small (about %s billion parameters) calls tools wrongly or repeats itself: use it for chat, or pick one of 7B or more with tool support. Runs on this computer, $0.\n' "$(awk -v m="$pm" 'BEGIN { printf "%.1f", m / 1000 }')"
  elif [ -n "$pm" ] && [ "$pm" -lt "$LOCAL_SMALL_PARAMS_M" ]; then
    printf 'untested\tNot checked with Claude Code. Local models under 7B parameters are weak at its tools: expect wrong or repeated calls. Each answer is capped at %s tokens. Runs on this computer, $0.\n' "$LOCAL_MAX_OUT"
  else
    printf 'untested\tNot checked with Claude Code. Local models are weaker at its tools than the cloud ones (tool use %s); each answer is capped at %s tokens. Runs on this computer, $0.\n' "$([ "$tools" = yes ] && echo "is in its chat template" || echo "is unknown")" "$LOCAL_MAX_OUT"
  fi
}
# local_models_code_rows -> TAB rows for lib/code_models.sh: id name vendor compat note max_out context
local_models_code_rows() {
  local e row rt id repo quant _b _l tools ctx pm name vendor cn mo
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    row="$(local_entry_row "$e")"
    IFS=$'\t' read -r rt id repo quant _b _l tools ctx pm _ <<< "$row"
    [ -n "$row" ] || { id="${e#*:}"; repo="${id#hf.co/}"; repo="${repo%%:*}"; quant="${id##*:}"; tools=-; ctx=-; pm=-; }
    name="$(printf '%s' "${repo#*/}" | sed -e 's/-GGUF$//I' -e 's/-gguf$//')"; [ -n "$name" ] || name="$id"
    [ "$quant" = - ] || name="$name ($quant)"
    vendor="${repo%%/*}"; [ "$vendor" != "$repo" ] || vendor=Local
    cn="$(local_model_compat "$([ "$tools" = 1 ] && echo yes || { [ "$tools" = 0 ] && echo no || echo unknown; })" "$pm")"
    mo="$LOCAL_MAX_OUT"; case "$ctx" in '' | - | *[!0-9]*) ;; *) [ "$((ctx / 2))" -ge "$mo" ] || mo=$((ctx / 2)) ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(local_model_name "$e")" "$(printf '%s' "$name" | tr -d '\t"\\')" "$(printf '%s' "$vendor" | tr -d '\t"\\')" \
      "${cn%%$'\t'*}" "${cn#*$'\t'}" "$mo$([ "$ctx" != - ] && printf '\t%s' "$ctx" || printf '\t-')"
  done < <(local_models_wanted)
  msrv_code_rows
}

# --- LiteLLM ---
# local_models_yaml -> model_list entries (render_litellm_config): each a docker_model_runner/…, ollama_chat/… or openai/…
# (MLX, llama.cpp) deployment (all speak Chat Completions: no Responses API detour), prices 0 (never spend); nothing
# without LOCAL_MODELS
local_models_yaml() {
  local e id name base kind dmr='' ol='' k
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    id="${e#*:}"; name="$(local_model_name "$e")"
    case "$e" in
      mlx:*)
        printf '  - model_name: "%s"\n    litellm_params:\n      model: "openai/%s"\n      api_base: "%s"\n      api_key: "none"\n      timeout: 900\n      input_cost_per_token: 0\n      output_cost_per_token: 0\n    model_info:\n      mode: "chat"\n' \
          "$name" "$id" "$(local_mlx_base)"; continue ;;
      llamacpp:*)
        # (its API key: every request to it needs one — lib/runtimes.sh; the generated config's readers can see it)
        printf '  - model_name: "%s"\n    litellm_params:\n      model: "openai/%s"\n      api_base: "%s"\n      api_key: "%s"\n      timeout: 900\n      input_cost_per_token: 0\n      output_cost_per_token: 0\n    model_info:\n      mode: "chat"\n' \
          "$name" "$id" "$(local_llamacpp_base)" "$(rt_llamacpp_key)"; continue ;;
      lmstudio:*)
        # (LM Studio serves it by the key it gave it: models.tsv; through its gate, with the API key DevOS ADE made for it —
        # lib/runtimes.sh; the generated config's readers can see that key)
        k="$(rt_lmstudio_key "$id")"; [ -n "$k" ] || continue
        printf '  - model_name: "%s"\n    litellm_params:\n      model: "openai/%s"\n      api_base: "%s"\n      api_key: "%s"\n      timeout: 900\n      input_cost_per_token: 0\n      output_cost_per_token: 0\n    model_info:\n      mode: "chat"\n' \
          "$name" "$k" "$(local_lmstudio_base)" "$(rt_api_key lmstudio)"; continue ;;
      dmr:*) [ -n "$dmr" ] || dmr="$(local_dmr_base)"; base="$dmr"; kind=docker_model_runner ;;
      *) [ -n "$ol" ] || ol="$(local_ollama_base)"; base="$ol"; kind=ollama_chat ;;
    esac
    printf '  - model_name: "%s"\n    litellm_params:\n      model: "%s/%s"\n      api_base: "%s"\n      input_cost_per_token: 0\n      output_cost_per_token: 0\n    model_info:\n      mode: "chat"\n' \
      "$name" "$kind" "$id" "$base"
  done < <(local_models_wanted)
  msrv_yaml
}

# --- the portal's file ---
_local_put() { # _local_put FILE < content — atomically, readable by the portal
  local d tmp; d="$(dirname "$1")"
  mkdir -p "$d" 2>/dev/null || return 0
  tmp="$(mktemp "$d/.local.XXXXXX")" || return 0
  if cat > "$tmp"; then chmod 644 "$tmp"; mv -f "$tmp" "$1"; else rm -f "$tmp"; fi
}
_local_q() { printf '"%s"' "$(printf '%s' "$1" | LC_ALL=C tr -d '"\\\000-\037\177' | cut -c1-${2:-300})"; }

# local_runner_ids RUNTIME -> the model ids the runtime lists, one per line
local_runner_ids() {
  case "$1" in
    dmr) _with_deadline 15 docker model list --openai 2>/dev/null | grep -o '"id" *: *"[^"]*"' | sed 's/^"id" *: *"//; s/"$//' ;;
    mlx) ls "$(local_mlx_hub)" 2>/dev/null | sed -n 's/^models--//p' | sed 's/--/\//' ;;
    llamacpp) # (the models whose first file is on disk)
      declare -F rt_llamacpp_models >/dev/null && [ -f "$(rt_llamacpp_models)" ] || return 0
      local i rel _r; while IFS=$'\t' read -r i rel _r; do [ ! -f "$(rt_dir llamacpp)/hub/$rel" ] || printf '%s\n' "$i"; done < "$(rt_llamacpp_models)" ;;
    lmstudio) # (the same, from LM Studio's record)
      declare -F rt_lmstudio_models >/dev/null && [ -f "$(rt_lmstudio_models)" ] || return 0
      local i _k rel _r; while IFS=$'\t' read -r i _k rel _r; do [ ! -f "$(rt_dir lmstudio)/hub/$rel" ] || printf '%s\n' "$i"; done < "$(rt_lmstudio_models)" ;;
    ollama) curl -s -m 8 "$(_local_ollama_url)/api/tags" 2>/dev/null | grep -o '"name" *: *"[^"]*"' | sed 's/^"name" *: *"//; s/"$//' ;;
  esac
}
# local_resolve_id RUNTIME REPO QUANT -> the id the runtime lists for hf.co/REPO:QUANT (matched case-insensitively, with
# or without hf.co/, huggingface.co/), else nothing
local_resolve_id() {
  local want ids; want="$(printf 'hf.co/%s:%s' "$2" "$3" | tr 'A-Z' 'a-z')"
  ids="$(local_runner_ids "$1")" || ids=''
  printf '%s\n' "$ids" | awk -v w="$want" '{ l = tolower($0); sub(/^huggingface\.co\//, "hf.co/", l); if (!f && l == w) { print $0; f = 1 } }'
}

# local_status_write [JOB_JSON] — .state/status/local-models.json: the runtime, the machine, what is downloaded, the job
# _local_result_json -> the last model-server form result (server-result.json: the key is never in it), or null
_local_result_json() {
  local r; r="$(cat "$(local_dir)/server-result.json" 2>/dev/null || true)"
  case "$r" in '{'*'}') printf '%s' "$r" ;; *) printf 'null' ;; esac
}
local_status_write() {
  local d o m l s rt how gpu mem inst='' sep='' row r id repo quant bytes lic tools ctx pm added present ids total=0 job="${1:-}"
  # (a download's once-a-second progress writes reuse the first look at the runtime and the machine)
  if [ "${_LOCAL_FAST:-0}" = 1 ] && [ -n "${_LOCAL_D:-}" ]; then d="$_LOCAL_D"; o="$_LOCAL_O"; m="$_LOCAL_M"; l="$_LOCAL_L"; s="$_LOCAL_S"; gpu="$_LOCAL_GPU"; mem="$_LOCAL_MEM"; how="$_LOCAL_HOW"
  else
    d="$(local_dmr_state)"; o="$(local_ollama_state)"; m="$(local_mlx_state)"; l="$(local_llamacpp_state)"; s="$(local_lmstudio_state)"
    gpu="$(local_gpu)"; mem="$(local_memory_bytes)"
    how=''; { [ "$d" = ready ] || [ "$o" = ready ] || [ "$l" = ready ] || [ "$s" = ready ] || local_mlx_capable; } || how="$(local_how_text)"
    [ "$m" != no-uv ] || how="$(local_how_text)"
    _LOCAL_M="$m"; _LOCAL_D="$d"; _LOCAL_O="$o"; _LOCAL_L="$l"; _LOCAL_S="$s"; _LOCAL_GPU="$gpu"; _LOCAL_MEM="$mem"; _LOCAL_HOW="$how"
  fi
  rt=none   # (as local_runtime, from the states already read)
  case "$(get_env LOCAL_RUNTIME)" in
    mlx) case "$m" in ready | stopped | not-installed) rt=mlx ;; esac ;;
    dmr) [ "$d" != ready ] || rt=dmr ;;
    ollama) [ "$o" != ready ] || rt=ollama ;;
    llamacpp) [ "$l" != ready ] || rt=llamacpp ;;
    lmstudio) [ "$s" != ready ] || rt=lmstudio ;;
    *)
      case "$m" in ready | stopped | not-installed) rt=mlx ;; esac
      [ "$rt" != none ] || [ "$d" != ready ] || rt=dmr
      [ "$rt" != none ] || [ "$o" != ready ] || rt=ollama
      [ "$rt" != none ] || [ "$l" != ready ] || rt=llamacpp
      [ "$rt" != none ] || [ "$s" != ready ] || rt=lmstudio ;;
  esac
  [ "$rt" != none ] || [ -n "$how" ] || how="$(local_how_text)"
  [ -n "$job" ] || job="$(cat "$(local_job_file)" 2>/dev/null || true)"
  case "$job" in '{'*'}') ;; *) job='{"state":"idle"}' ;; esac
  declare -a seen_ids=()
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r r id repo quant bytes lic tools ctx pm added rev <<< "$row"
    present=true
    if [ "${_LOCAL_FAST:-0}" != 1 ] && { { [ "$r" = dmr ] && [ "$d" = ready ]; } || { [ "$r" = ollama ] && [ "$o" = ready ]; } || [ "$r" = mlx ] || [ "$r" = llamacpp ] || [ "$r" = lmstudio ]; }; then
      ids="$(local_runner_ids "$r" || true)"
      printf '%s\n' "$ids" | grep -xF "$id" >/dev/null || present=false
    fi
    case "$bytes" in '' | *[!0-9]*) bytes=0 ;; esac
    total=$((total + bytes))
    inst="$inst$sep{\"runtime\":$(_local_q "$r" 20),\"id\":$(_local_q "$id"),\"name\":$(_local_q "$(local_model_name "$r:$id")"),\"repo\":$(_local_q "$repo" 200),\"quant\":$(_local_q "$quant" 64),\"bytes\":$bytes,\"license\":$(_local_q "$lic" 60),\"tools\":$(_local_q "$tools" 4),\"context\":$(_local_q "$ctx" 12),\"params_m\":$(_local_q "$pm" 12),\"present\":$present,\"registered\":$(local_models_wanted | grep -xF "$r:$id" >/dev/null && echo true || echo false),\"added\":$(_local_q "${added:-0}" 12),\"revision\":$(_local_q "$([[ ${rev:-} =~ ^[0-9a-f]{40}$ ]] && echo "$rev")" 40)}"
    sep=','
  done < <(local_registry_rows)
  local sv='' ssep='' n u tr_ st
  while IFS=$'\t' read -r n u tr_; do
    [ -n "$n" ] || continue; st="$(msrv_status_of "$n")"
    sv="$sv$ssep{\"name\":$(_local_q "$n" 24),\"url\":$(_local_q "$u" 200),\"reached_as\":$(_local_q "$(msrv_reached_as "$n")" 240),\"trust\":$([ "$tr_" = 1 ] && echo true || echo false),\"key\":$([ -n "$(msrv_key "$n")" ] && echo true || echo false),\"status\":$(_local_q "${st%%$'\t'*}" 8),\"detail\":$(_local_q "${st#*$'\t'}" 2000),\"warning\":$(_local_q "$(msrv_warn "$u" "$tr_" "$(msrv_addr_of "$n")")" 200),\"key_note\":$(_local_q "$(msrv_key_note "$n")" 120),\"enabled\":$(_local_q "$(_msrv_items MODEL_SERVER_MODELS | awk -F: -v n="$n" '$1 == n { sub(/^[^:]*:/, ""); printf "%s%s", s, $0; s = ";" }')" 1500)}"
    ssep=','
  done < <(msrv_rows)
  printf '{"at":%s,"runtime":{"kind":"%s","dmr":"%s","ollama":"%s","mlx":"%s","llamacpp":"%s","lmstudio":"%s","how":%s,"command":"./stack local-models enable"},"gpu":%s,"memory_bytes":%s,"disk_bytes":%s,"installed":[%s],"servers":[%s],"result":%s,"job":%s}\n' \
    "$(date +%s)" "$rt" "$d" "$o" "$m" "$l" "$s" "$(_local_q "$how" 400)" "$(_local_q "$gpu" 40)" "$mem" "$total" "$inst" "$sv" "$(_local_result_json)" "$job" | _local_put "$(local_status_file)"
}

# local_models_tick — the update helper, each loop: when the portal asked (local_wanted_file), the file written again,
# at most every 10 seconds (a free look; takes no lock)
local_models_tick() {
  local w last pl; w="$(local_wanted_file)"; last="$(helper_dir)/local-last"; pl="$(helper_dir)/servers-last"
  if [ -n "$(msrv_rows)" ] && [ -z "$(find "$pl" -mmin -1 2>/dev/null)" ]; then   # (model servers: looked at about once a minute)
    : > "$pl"; _with_deadline 60 msrv_probe_all 2>/dev/null || true; _with_deadline 40 local_status_write 2>/dev/null || true
  fi
  [ -e "$w" ] || return 0
  rm -f "$w"
  [ -z "$(find "$last" -mmin -0.15 2>/dev/null)" ] || return 0
  : > "$last"
  _with_deadline 40 local_status_write 2>/dev/null || true
  ! declare -F rt_status_write >/dev/null || _with_deadline 20 rt_status_write 2>/dev/null || true   # (lib/runtimes.sh: the Runtimes panel's)
}

# --- the job ---
# _local_job STATE REPO QUANT DONE TOTAL MESSAGE [RATE ETA STALLED] — job.json (and the portal's file). STATE: pulling,
# registering, removing, done, failed, paused or cancelled; RATE bytes a second, ETA seconds left (-1: not known), STALLED
# seconds since anything arrived
_local_job() {
  local m; m="$(_local_q "$6" 300)"
  printf '{"state":"%s","repo":%s,"quant":%s,"done_bytes":%s,"total_bytes":%s,"rate":%s,"eta":%s,"stalled":%s,"message":%s,"at":%s}\n' \
    "$1" "$(_local_q "$2" 200)" "$(_local_q "$3" 64)" "${4:-0}" "${5:-0}" "${7:-0}" "${8:--1}" "${9:-0}" "$m" "$(date +%s)" > "$(local_job_file).tmp" 2>/dev/null &&
    mv -f "$(local_job_file).tmp" "$(local_job_file)" 2>/dev/null || true
  local_status_write "$(cat "$(local_job_file)" 2>/dev/null)" 2>/dev/null || true
}
# a job runs while job.json says pulling or removing and its pid lives
local_job_running() {
  local pid; pid="$(cat "$(local_dir)/job.pid" 2>/dev/null || true)"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && grep -qE '"state":"(pulling|removing|registering)"' "$(local_job_file)" 2>/dev/null
}

local_stop_file() { printf '%s/stop\n' "$(local_dir)"; }
local_dl_pid_file() { printf '%s/dl.pid\n' "$(local_dir)"; }
_local_json_num() { printf '%s' "$1" | sed -n "s/.*\"$2\":\(-\{0,1\}[0-9][0-9]*\).*/\\1/p" | head -n 1; }
_local_size() { awk -v b="${1:-0}" 'BEGIN { if (b >= 10737418240) printf "%.0f GB", b / 1073741824; else if (b >= 1073741824) printf "%.1f GB", b / 1073741824; else printf "%d MB", b / 1048576 }'; }   # (as the page rounds)

# a download's speed and time left: bytes a second over about the last ten seconds, and the seconds since it last grew.
# _local_speed DONE TOTAL sets _LS_RATE, _LS_ETA (-1: not known) and _LS_STALLED; _local_speed_reset before each download
_local_speed_reset() { _LS_T=(); _LS_B=(); _LS_LAST=-1; _LS_GREW="$(date +%s)"; _LS_RATE=0; _LS_ETA=-1; _LS_STALLED=0; }
_local_speed() {
  local now; now="$(date +%s)"
  [ "$1" -le "$_LS_LAST" ] || { _LS_LAST="$1"; _LS_GREW="$now"; }
  _LS_T+=("$now"); _LS_B+=("$1")
  while [ "${#_LS_T[@]}" -gt 2 ] && [ $((now - _LS_T[0])) -gt 10 ]; do _LS_T=("${_LS_T[@]:1}"); _LS_B=("${_LS_B[@]:1}"); done
  _LS_RATE=0; [ $((now - _LS_T[0])) -le 0 ] || _LS_RATE=$(( ($1 - _LS_B[0]) / (now - _LS_T[0]) ))
  [ "$_LS_RATE" -ge 0 ] || _LS_RATE=0
  _LS_ETA=-1; [ "$_LS_RATE" -le 0 ] || [ "${2:-0}" -le "$1" ] || _LS_ETA=$(( ($2 - $1) / _LS_RATE ))
  _LS_STALLED=$((now - _LS_GREW))
}
# _local_dl_message NAME -> the progress line; after two minutes with nothing new (LOCAL_STALL_S), what is going on and what to do
_local_dl_message() {
  if [ "$_LS_STALLED" -ge "${LOCAL_STALL_S:-120}" ]; then
    printf 'Nothing has arrived for %s: Hugging Face or the connection is slow, and it keeps trying. Pause, then Resume, starts the connections again.' \
      "$([ "$_LS_STALLED" -ge 120 ] && echo "$((_LS_STALLED / 60)) minutes" || echo "$_LS_STALLED seconds")"
  else printf 'Downloading %s' "$1"; fi
}

# --- Pause, Resume and Cancel ---
# ./stack local-models pause|cancel writes the stop file and stops the downloader (dl.pid); the download's own process then
# writes paused or cancelled (_local_stopped). _local_stop_asked -> pause or cancel when one was asked (nothing otherwise).
_local_stop_asked() { local s; s="$(cat "$(local_stop_file)" 2>/dev/null || true)"; case "$s" in pause | cancel) printf '%s\n' "$s" ;; esac; }
# _local_kill_tree PID SIGNAL — PID's children first (a runtime's client under its subshell), then PID
_local_kill_tree() {
  case "$1" in '' | *[!0-9]*) return 0 ;; esac
  pkill "-$2" -P "$1" 2>/dev/null || true; kill "-$2" "$1" 2>/dev/null || true
}
# _local_discard RUNTIME REPO — an unfinished MLX, llama.cpp or LM Studio download's files deleted: never a model this
# stack has whole (that is Remove's; llama.cpp and LM Studio: another quantization of the same repo keeps its files, only
# this one's parts go). Docker Model Runner and Ollama keep their own unfinished parts.
_local_discard() {
  case "$1" in mlx | llamacpp | lmstudio) valid_hf_repo "$2" || return 0 ;; *) return 0 ;; esac
  local d n h b
  if [ "$1" = mlx ]; then d="$(local_mlx_repo_dir "$2")"; else d="$(rt_dir "$1")/hub/models--${2//\//--}"; fi
  if [ -n "$(local_registry_rows | awk -F'\t' -v r="$2" -v t="$1" '$1 == t && tolower($3) == tolower(r)')" ]; then
    [ "$1" != mlx ] && [ -f "$(local_dir)/manifest.tsv" ] || return 0
    while IFS=$'\t' read -r n _ h b; do [[ ${h:-$b} =~ ^[0-9a-f]{40,64}$ ]] && rm -f -- "$d/blobs/${h:-$b}.part"; done < "$(local_dir)/manifest.tsv"
    return 0
  fi
  rm -rf -- "$d"
}
# _local_stopped pause|cancel RUNTIME REPO QUANT DONE TOTAL — the download stopped as asked. Paused keeps what arrived (Resume,
# or the same download again, continues from it); Cancelled deletes it.
_local_stopped() {
  local op="$1" rt="$2" repo="$3" quant="$4" done_b="${5:-0}" total="${6:-0}"
  rm -f "$(local_stop_file)" "$(local_dl_pid_file)"
  if [ "$op" = pause ]; then
    _local_job paused "$repo" "$quant" "$done_b" "$total" "Paused at $(_local_size "$done_b")$([ "$total" -gt 0 ] 2>/dev/null && echo " of $(_local_size "$total")"). Resume continues from there."
  else
    _local_discard "$rt" "$repo"
    local gone=""   # (not a case inside "$(…)": bash 3.2 ends the substitution at a pattern's ")")
    case "$rt" in mlx | llamacpp | lmstudio) gone=": what had arrived was deleted" ;; esac
    _local_job cancelled "$repo" "$quant" 0 "$total" "Cancelled$gone."
  fi
  rm -f "$(local_dir)/job.pid"
}
# _local_job_runtime QUANT -> the runtime the last download went to (job.rt; an MLX one has no quantization)
_local_job_runtime() {
  local r; r="$(cat "$(local_dir)/job.rt" 2>/dev/null || true)"
  case "$r" in mlx | dmr | ollama | llamacpp | lmstudio) echo "$r" ;; *) [ "$1" = mlx ] && echo mlx || echo other ;; esac
}
# local_stop pause|cancel — the running download stopped: pause keeps what arrived, cancel deletes it. Cancel also deletes a
# paused or failed download's part. Waits (seconds) until the download's process says so; one that does not is stopped here.
local_stop() {
  local op="${1:-}" j st repo quant n=0
  case "$op" in pause | cancel) ;; *) die "usage: ./stack local-models pause | cancel" ;; esac
  j="$(cat "$(local_job_file)" 2>/dev/null || true)"; st="$(_local_json_str "$j" state)"
  repo="$(_local_json_str "$j" repo)"; quant="$(_local_json_str "$j" quant)"
  if local_job_running; then
    [ "$st" = pulling ] || die "it is ${st}, which takes seconds and is not stopped halfway"
    printf '%s\n' "$op" > "$(local_stop_file)"
    _local_kill_tree "$(cat "$(local_dl_pid_file)" 2>/dev/null || true)" TERM
    while local_job_running && [ "$n" -lt "${LOCAL_STOP_WAIT:-40}" ]; do sleep 0.5; n=$((n + 1)); done
    if local_job_running; then
      _local_kill_tree "$(cat "$(local_dir)/job.pid" 2>/dev/null || true)" TERM
      _local_kill_tree "$(cat "$(local_dl_pid_file)" 2>/dev/null || true)" KILL
      _local_stopped "$op" "$(_local_job_runtime "$quant")" "$repo" "$quant" "$(_local_json_num "$j" done_bytes)" "$(_local_json_num "$j" total_bytes)"
    fi
    log "$([ "$op" = pause ] && echo Paused || echo Cancelled): $repo"
  elif [ "$op" = cancel ] && [ -n "$repo" ] && { [ "$st" = paused ] || [ "$st" = failed ]; }; then
    _local_stopped cancel "$(_local_job_runtime "$quant")" "$repo" "$quant" 0 "$(_local_json_num "$j" total_bytes)"
    log "Cancelled: $repo"
  else
    log "No download is running"
  fi
}
# local_resume — the paused (or stopped) download again, with what it was started with: it continues from what arrived
local_resume() {
  local st a=(); st="$(_local_json_str "$(cat "$(local_job_file)" 2>/dev/null || true)" state)"
  case "$st" in paused | failed) ;; *) die "no paused download (./stack local-models status)" ;; esac
  read -r -a a < "$(local_dir)/job.args" 2>/dev/null && [ "${#a[@]}" -ge 2 ] || die "what it was started with is gone: download it again from Settings › Local models"
  local_pull "${a[@]}"
}
# _local_job_line -> the download, for ./stack local-models status (nothing when there is none)
_local_job_line() {
  local j st r e; j="$(cat "$(local_job_file)" 2>/dev/null || true)"; st="$(_local_json_str "$j" state)"
  case "$st" in '' | idle) return 0 ;; esac
  r="$(_local_json_num "$j" rate)"; e="$(_local_json_num "$j" eta)"
  printf 'Download:   %s %s:%s, %s of %s%s%s\n            %s\n' "$st" "$(_local_json_str "$j" repo)" "$(_local_json_str "$j" quant)" \
    "$(_local_size "$(_local_json_num "$j" done_bytes)")" "$(_local_size "$(_local_json_num "$j" total_bytes)")" \
    "$([ "$st" = pulling ] && [ "${r:-0}" -gt 0 ] && echo ", $(_local_size "$r")/s")" "$([ "$st" = pulling ] && [ "${e:--1}" -ge 0 ] && echo ", $((e / 60)) min left")" \
    "$(_local_json_str "$j" message)"
}

# _local_progress_bytes FILE -> the bytes a runtime's pull log says are done: the last "<n> <unit>" figure (a "x / y" pair's
# first figure of the last line that has one), in B, KB, MB or GB (decimal and binary spellings alike)
_local_progress_bytes() {
  tr '\r' '\n' < "$1" 2>/dev/null | tail -n 40 | LC_ALL=C awk '
    function mul(u) { u = toupper(u); if (u ~ /^GI?B$/) return 1073741824; if (u ~ /^MI?B$/) return 1048576; if (u ~ /^KI?B$/) return 1024; return 1 }
    { if (match($0, /[0-9]+(\.[0-9]+)? ?([KMG]i?B|B)/)) { s = substr($0, RSTART, RLENGTH); n = s; sub(/ ?[A-Za-z]+$/, "", n); u = s; sub(/^[0-9.]+ ?/, "", u); last = n * mul(u) } }
    END { printf "%d\n", last }'
}

# local_pull REPO QUANT [--bytes N] [--tools yes|no|unknown] [--context N] [--params-m N] [--license L]
local_pull() {
  local repo="${1:-}" quant="${2:-}" bytes=0 tools=unknown ctx=- pm=- lic=- ref rt id rc=0 logf pid done_b=0 val cur stop
  shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    val="${2:-}"
    case "$1" in
      --bytes) [[ $val =~ ^[0-9]{1,13}$ ]] && bytes="$val" ;;
      --tools) case "$val" in yes | no | unknown) tools="$val" ;; esac ;;
      --context) [[ $val =~ ^[0-9]{1,9}$ ]] && ctx="$val" ;;
      --params-m) [[ $val =~ ^[0-9]{1,9}$ ]] && pm="$val" ;;
      --license) [[ $val =~ ^[A-Za-z0-9.+-]{1,40}$ ]] && lic="$val" ;;
    esac
    shift 2 || break
  done
  [ -n "$quant" ] || { local_mlx_capable && quant=mlx; }   # (an MLX model is a whole repo: no quantization to pick)
  valid_hf_repo "$repo" || die "not a Hugging Face repo (org/name): $repo"
  valid_hf_quant "$quant" || die "not a quantization name: $quant"
  mkdir -p "$(local_dir)" && chmod 700 "$(local_dir)"
  ! local_job_running || die "another download is running (./stack local-models status)"
  val="$(cat "$(local_job_file)" 2>/dev/null || true)"
  if [ "$(_local_json_str "$val" state)" = paused ] && [ "$(printf '%s:%s' "$(_local_json_str "$val" repo)" "$(_local_json_str "$val" quant)" | tr 'A-Z' 'a-z')" != "$(printf '%s:%s' "$repo" "$quant" | tr 'A-Z' 'a-z')" ]; then
    die "$(_local_json_str "$val" repo) is paused: resume it (./stack local-models resume) or cancel it (./stack local-models cancel) first"
  fi
  printf '%s\n' "${BASHPID:-$$}" > "$(local_dir)/job.pid"   # (this process, also in a subshell: a forced stop kills only it)
  rm -f "$(local_stop_file)" "$(local_dl_pid_file)"
  printf '%s %s --bytes %s --tools %s --context %s --params-m %s --license %s\n' "$repo" "$quant" "$bytes" "$tools" "$ctx" "$pm" "$lic" > "$(local_dir)/job.args"
  ref="hf.co/$repo:$quant"
  _LOCAL_FAST=0; _LOCAL_D=''
  rt="$(local_runtime)"
  if [ "$rt" = none ]; then
    _local_job failed "$repo" "$quant" 0 "$bytes" "No model runner is running. $(local_how_text)"
    die "no model runner: $(local_how_text)"
  fi
  printf '%s\n' "$rt" > "$(local_dir)/job.rt"
  if [ "$rt" = mlx ]; then
    valid_hf_repo "$repo" || die "not a Hugging Face repo (org/name): $repo"
    _local_pull_mlx "$repo" "$bytes" "$tools" "$ctx" "$pm" "$lic"; return $?
  fi
  case "$rt" in llamacpp | lmstudio) _local_pull_gguf "$rt" "$repo" "$quant" "$bytes" "$tools" "$ctx" "$pm" "$lic"; return $? ;; esac
  _local_job pulling "$repo" "$quant" 0 "$bytes" "Downloading $ref with $([ "$rt" = dmr ] && echo "Docker Model Runner" || echo Ollama)"
  _LOCAL_FAST=1   # (the first look is taken: the progress writes reuse it)
  logf="$(local_dir)/pull.log"; : > "$logf"; chmod 600 "$logf"
  # Pull from Hugging Face only; the token (gated models) reaches the runtime's environment, never an argument or URL
  if [ "$rt" = dmr ]; then
    ( HF_TOKEN="$(get_env HF_TOKEN)" docker model pull "$ref" ) </dev/null > "$logf" 2>&1 &
  else
    ( curl -sS -N -X POST "$(_local_ollama_url)/api/pull" -H 'Content-Type: application/json' -d "{\"model\":\"$ref\",\"stream\":true}" ) </dev/null > "$logf" 2>&1 &
  fi
  pid=$!; printf '%s\n' "$pid" > "$(local_dl_pid_file)"
  _local_speed_reset
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$rt" = dmr ]; then done_b="$(_local_progress_bytes "$logf")"
    else
      # (a pull streams one line per layer: the biggest layer is the model)
      cur="$(tail -n 3000 "$logf" | grep -o '"total":[0-9]*,"completed":[0-9]*' | awk -F'[:,]' '{ if ($2 + 0 > mt) { mt = $2 + 0; mc = $4 + 0 } else if ($2 + 0 == mt) mc = $4 + 0 } END { print mt + 0, mc + 0 }')"
      done_b="${cur#* }"; val="${cur%% *}"; [ "${val:-0}" -le "$bytes" ] 2>/dev/null || bytes="$val"
    fi
    case "$done_b" in '' | *[!0-9]*) done_b=0 ;; esac
    _local_speed "$done_b" "$bytes"
    _local_job pulling "$repo" "$quant" "$done_b" "$bytes" "$(_local_dl_message "$ref")" "$_LS_RATE" "$_LS_ETA" "$_LS_STALLED"
    sleep "${LOCAL_POLL_S:-1}"
  done
  wait "$pid" || rc=$?
  rm -f "$(local_dl_pid_file)"
  _LOCAL_FAST=0
  stop="$(_local_stop_asked)"
  if [ "$stop" = cancel ] || { [ "$stop" = pause ] && [ "$rc" -ne 0 ]; }; then _local_stopped "$stop" "$rt" "$repo" "$quant" "$done_b" "$bytes"; return 0; fi
  rm -f "$(local_stop_file)"
  if [ "$rt" = ollama ] && grep -q '"error"' "$logf" 2>/dev/null; then rc=1; fi
  if [ "$rc" -ne 0 ]; then
    cur="$(tr '\r' '\n' < "$logf" | tail -n 3 | LC_ALL=C tr -cd ' -~\n' | tr '\n' ' ' | cut -c1-200)"
    _local_job failed "$repo" "$quant" 0 "$bytes" "The download failed ($cur). A gated model needs a Hugging Face token (Settings › Models & providers) and its license accepted on huggingface.co."
    die "the download failed"
  fi
  id="$(local_resolve_id "$rt" "$repo" "$quant")"
  [ -n "$id" ] || id="$(printf '%s' "$ref" | tr 'A-Z' 'a-z')"
  valid_local_entry "$rt:$id" || { _local_job failed "$repo" "$quant" 0 "$bytes" "The runtime named the model in a way this stack cannot serve."; die "unusable model id"; }
  local_registry_put "$rt" "$id" "$repo" "$quant" "$bytes" "$lic" "$([ "$tools" = yes ] && echo 1 || { [ "$tools" = no ] && echo 0 || echo -; })" "$ctx" "$pm"
  _local_job registering "$repo" "$quant" "$bytes" "$bytes" "Registering it with the model gateway (a few seconds)"
  local_register_apply add "$rt:$id" || { _local_job failed "$repo" "$quant" "$bytes" "$bytes" "Downloaded, but the model gateway did not take it: ./stack local-models status"; die "registration failed"; }
  _local_job done "$repo" "$quant" "$bytes" "$bytes" "Ready: $(local_model_name "$rt:$id") is in Chat, the Code page and the terminal"
  rm -f "$(local_dir)/job.pid"
}

# local_register_apply add|remove ENTRY — LOCAL_MODELS changed as one settings change (live in LiteLLM: lib/litellm_live.sh)
local_register_apply() {
  local cur new='' e
  cur="$(get_env LOCAL_MODELS)"
  while IFS= read -r e; do [ -n "$e" ] && [ "$e" != "$2" ] && new="${new:+$new,}$e"; done < <(printf '%s\n' "$cur" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ "$1" != add ] || new="${new:+$new,}$2"
  [ "$new" != "$cur" ] || return 0
  CFG_ORDER=''; cfg_put LOCAL_MODELS "$new"
  config_apply local cli ''
}

local_rm() {
  local repo="${1:-}" quant="${2:-mlx}" rt id row e rc=0 rd
  valid_hf_repo "$repo" && valid_hf_quant "$quant" || die "usage: ./stack local-models rm ORG/REPO QUANT"
  row="$(local_registry_rows | awk -F'\t' -v r="$repo" -v q="$quant" '!f && tolower($3) == tolower(r) && tolower($4) == tolower(q) { print; f = 1 }')"
  [ -n "$row" ] || die "$repo:$quant is not a model this stack downloaded"
  IFS=$'\t' read -r rt id _ <<< "$row"; e="$rt:$id"
  ! local_job_running || die "a download is running: wait for it"
  mkdir -p "$(local_dir)"; printf '%s\n' "${BASHPID:-$$}" > "$(local_dir)/job.pid"
  _local_job removing "$repo" "$quant" 0 0 "Removing it from the model gateway"
  local_register_apply remove "$e" || { _local_job failed "$repo" "$quant" 0 0 "The model gateway did not let it go: ./stack local-models status"; die "unregister failed"; }
  _local_job removing "$repo" "$quant" 0 0 "Deleting the files"
  case "$rt" in
    mlx) rd="$(local_mlx_repo_dir "$id")"; rm -rf -- "$rd" || rc=$? ;;
    dmr) _with_deadline 120 docker model rm "$id" >/dev/null 2>&1 || rc=$? ;;
    ollama) curl -sS -m 60 -X DELETE "$(_local_ollama_url)/api/delete" -H 'Content-Type: application/json' -d "{\"model\":\"$id\"}" >/dev/null 2>&1 || rc=$? ;;
    llamacpp) rt_llamacpp_forget "$id" || rc=$? ;;
    lmstudio) rt_lmstudio_forget "$id" || rc=$? ;;
  esac
  if [ "$rc" -ne 0 ]; then
    local how   # (not a case inside "$(…)": bash 3.2 ends the substitution at a pattern's ")")
    case "$rt" in dmr) how="docker model rm $id" ;; llamacpp | lmstudio) how="./stack runtimes status" ;; *) how="ollama rm $id" ;; esac
    _local_job failed "$repo" "$quant" 0 0 "Taken out of the pickers, but the runtime did not delete the files (is it running?): $how"; die "the runtime did not delete it"; fi
  local_registry_drop "$rt" "$id"
  _local_job done "$repo" "$quant" 0 0 "Removed"
  rm -f "$(local_dir)/job.pid"
}

# local_models_enable — switch a runtime on, after asking: Docker Desktop's model runner (TCP 12434 too, which Docker Engine
# has by default), docker-model-plugin and the runner on Linux. Never without a yes.
local_models_enable() {
  local d; d="$(local_dmr_state)"
  case "$d" in
    ready) log "Docker Model Runner is already running"; return 0 ;;
    not-installed) die "Docker is not installed. Docker Model Runner comes with Docker Desktop (https://docs.docker.com/ai/model-runner/); or install Ollama and start it." ;;
    plugin-missing)
      case "$(uname -s)" in
        Linux)
          if command -v apt-get >/dev/null 2>&1; then confirm "Install docker-model-plugin with apt-get (sudo)?" || die "not installed"; sudo apt-get update && sudo apt-get install -y docker-model-plugin
          elif command -v dnf >/dev/null 2>&1; then confirm "Install docker-model-plugin with dnf (sudo)?" || die "not installed"; sudo dnf install -y docker-model-plugin
          else die "install docker-model-plugin with your package manager (https://docs.docker.com/ai/model-runner/get-started/)"; fi ;;
        *) die "this Docker has no model runner: update Docker Desktop (https://docs.docker.com/ai/model-runner/)" ;;
      esac ;;
  esac
  if docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep "Docker Desktop" >/dev/null; then
    confirm "Turn on Docker Desktop's Model Runner (docker desktop enable model-runner --tcp 12434)? This changes a Docker Desktop setting." || die "left off"
    docker desktop enable model-runner --tcp 12434
  else
    confirm "Start Docker Model Runner on this Docker Engine (docker model install-runner)?" || die "left off"
    docker model install-runner
  fi
  [ "$(local_dmr_state)" = ready ] && log "Docker Model Runner is running" || warn "Docker Model Runner is not answering yet: ./stack local-models status"
  local_status_write
}

cmd_local_models() {
  local sub="${1:-status}"; [ $# -eq 0 ] || shift
  case "$sub" in
    status) local_status_write; printf 'Runtime:    %s\n' "$(local_runtime)"; [ "$(local_runtime)" != none ] || printf '            %s\n' "$(local_how_text)"
            printf 'This computer: %s bytes of memory, GPU: %s\n' "$(local_memory_bytes)" "$(local_gpu)"
            printf 'Downloaded:\n'; local_registry_rows | awk -F'\t' '{ printf "  %s  (%s, %s, %s bytes)\n", $2, $1, $4, $5 }'
            printf 'Registered: %s\n' "$(get_env LOCAL_MODELS)"; _local_job_line ;;
    server)
      local ssub="${1:-list}"; [ $# -eq 0 ] || shift
      case "$ssub" in
        add) msrv_add "$@" ;;
        rm) msrv_rm "$@" ;;
        key) msrv_set_key "$@" ;;
        apply) msrv_apply "$@" ;;
        enable) msrv_enable "${1:-}" "${2:-}" on ;;
        disable) msrv_enable "${1:-}" "${2:-}" off ;;
        probe | list) msrv_probe_all; local_status_write
          msrv_rows | while IFS=$'\t' read -r n u t; do printf '%s  %s  %s\n    %s\n' "$n" "$u" "$(msrv_reached_as "$n")" "$(msrv_status_of "$n" | awk -F'\t' '{ print $1 ": " $2 }')"; done ;;
        *) die "usage: ./stack local-models server [list | add NAME URL [--trust] | apply FILE | key NAME | enable NAME ID|* | disable NAME ID|* | rm NAME | probe]" ;;
      esac ;;
    uninstall) local_mlx_uninstall "$@"; log "MLX server and environment removed$([ "${1:-}" = --models ] && echo ", and its models")" ;;
    pull) [ -f "$ENV_FILE" ] || die "run ./stack setup first"; guard_project; local_pull "$@" ;;
    rm) [ -f "$ENV_FILE" ] || die "run ./stack setup first"; guard_project; local_rm "$@" ;;
    enable) local_models_enable ;;
    pause | cancel) local_stop "$sub" ;;
    resume) [ -f "$ENV_FILE" ] || die "run ./stack setup first"; guard_project; local_resume ;;
    *) die "usage: ./stack local-models [status | pull ORG/REPO [QUANT] | pause | resume | cancel | rm ORG/REPO [QUANT] | enable | uninstall [--models]]" ;;
  esac
}
