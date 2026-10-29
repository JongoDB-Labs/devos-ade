# shellcheck shell=bash
# ./stack subcommands.

# Long-running services, in the order ./stack status lists them.
STACK_BASE_SERVICES="caddy portal open-webui litellm rustfs shared-mcp postgres"
STACK_SERVICES="$STACK_BASE_SERVICES"
# stack_services -> the stack's own services plus the optional ones .env turns on (stt: Bedrock speech-to-text).
# Built from STACK_BASE_SERVICES: callers keep a local STACK_SERVICES, which must not be extended twice.
stack_services() { local extra; extra="$(optional_services)"; printf '%s\n' "$STACK_BASE_SERVICES${extra:+ $extra}"; }
# optional_services -> the services .env turns on besides those: stt (Bedrock speech-to-text), terminal (./stack terminal),
# code (./stack code), searxng (the built-in web search: on unless WEBSEARCH_SEARXNG_BUILTIN=off, lib/websearch.sh), forgejo
# (the built-in git server: on unless LOCALGIT=off, lib/localgit.sh)
optional_services() {
  local out='' x
  for x in "$(stt_services)" "$(terminal_services)" "$(code_services)" "$(websearch_builtin_services)" "$(localgit_services)" "$(runtime_services)"; do [ -z "$x" ] || out="$out${out:+ }$x"; done
  printf '%s\n' "$out"
}

cmd_help() {
  cat <<'EOF'
Usage: ./stack <command> [--yes]

  setup        First-time (or repeat) setup: AWS creds, ports, model probe, keys (< $0.01 Bedrock)
  up | down    Start / stop the stack
  status       Services, health, URLs and disk use (the portal: one login for every browser UI)
               --disk measures disk use now (otherwise reused for 5 minutes)
  versions     Each core service: what runs, what this release pins, the newest upstream
  open         The installed DevOS ADE app, else the portal in your browser, where
               "Install app" installs it (setup and up open it too; BEDROCK_NOW_NO_OPEN=1
               turns that off)
  logs [svc]   Follow logs (litellm, open-webui, rustfs, postgres, shared-mcp, portal, caddy, stt, terminal, code,
               subs-chat, searxng, forgejo)
  test         Smoke-test every service end to end (~$0.0001 Bedrock)
  costs        Bedrock prices for your enabled models + spend per key
  prices       Check Bedrock prices now (public price lists; daily anyway)
               --accept applies a change the safety checks refused
  models       Which models your AWS key can use (last check)
               --recheck re-probes them (< $0.01 Bedrock)
  backup       Databases + buckets + .env → backups/<timestamp>/
               --nightly: the update helper's nightly backup (BACKUP_NIGHTLY; keeps BACKUP_KEEP)
  restore DIR  Restore from a backup directory (then runs test: ~$0.0001 Bedrock)
  update       Backup, new code (git), pinned images, re-run setup (< $0.01 Bedrock)
               --to <tag|branch> picks a version; local changes are never discarded;
               keeps one previous version of each image and removes older ones;
               nothing new: says so and stops (--force re-runs setup anyway)
  clean        Remove this project's old images (lists them first; keeps one previous version)
               --dry-run only lists them
  rollback     Back to the version before the last update: code, data (its backup) and images
  helper       One-click Update / Rollback / Clean on Home (setup offers it): install | uninstall
               | status | auto on [--hour N] | auto off | auto status   (automatic updates: a new
               release installs at night, N:00 to N+3:00 this computer's time; off by default, N=3)
  remote       The portal from your phone/laptop over HTTPS (Tailscale): status | enable tailscale
               | enable domain HOST | disable | test   (docs/remote.md)
  rotate-aws   Replace the AWS access key (then runs test: ~$0.0001 Bedrock)
               --use-instance-role / --use-keys switch between an EC2 IAM role and a key
  serve        Keep the stack up (and a Mac awake: caffeinate) until Ctrl-C; prints the URLs
               --background (macOS) holds it without a terminal, --stop ends that
  ssh-info     How to use devos-claude from your phone over SSH (Tailscale name, apps, tmux)
  openrouter   Optional OpenRouter models: status | set | apply | remove | refresh | list
               | models all|free|paid|<ids>   (no Bedrock calls; see README)
               apply uses the key pasted after OPENROUTER_API_KEY= in .env; set asks for one
  stt          Speech-to-text for the microphone and voice calls: Bedrock (Mistral Voxtral, no key;
               on by default when your AWS key can use it) or OpenAI/Groq (outside Bedrock):
               status | set bedrock [small|mini] | set openai|groq [model] | remove   (see docs/voice.md)
  websearch    Claude Code's WebSearch on every model (LiteLLM runs the search): status | check
               (~$0.007 at most) | aws-setup (AgentCore Web Search's one-time AWS setup, for your admin)
  local-models Models downloaded from Hugging Face and run on this computer (Docker Model Runner, else Ollama):
               status | pull ORG/REPO [QUANT] | pause | resume | cancel | rm ORG/REPO [QUANT] | enable | uninstall [--models]
               server list|add NAME URL [--trust]|key NAME|enable NAME ID|disable NAME ID|rm NAME   (any OpenAI-compatible server)
               (Settings › Models & providers › Local models; Apple silicon runs models with MLX, else Docker Model Runner, else Ollama;
               LOCAL_RUNTIME picks one)
  runtimes     The model runtimes DevOS ADE installs and runs itself (Ollama; macOS natively, Linux as a container):
               status | install ID | start ID | stop ID | uninstall ID | cancel | logs ID [LINES]
  terminal     Claude Code in the browser: a Terminal tab, a sandbox that sees only one folder of yours
               status | enable [--workspace DIR] | disable   (asks for the portal password again)
  code         Claude Code in the browser with a chat: a Code tab with permission prompts, models and
               your files, in the terminal's sandbox (on by default with the terminal; disable keeps it off)
               status | enable [--workspace DIR] | disable   (asks for the portal password again)
  project      Folders of this computer as projects of the Code page, mounted into its sandbox:
               list | add DIR [--read-only] [--hide-path] [--name N] | remove NAME | mode NAME ro|rw | apply
               (each change restarts the sandbox: --now, --when-idle or --later)
  git-host     The Code page's Git hosts from a CLI login on this computer: import gh | import glab
               [--host HOST]   (the token goes to the code container on stdin, never printed; you confirm)
  git-server   The built-in git server (Forgejo): status | mirror list | add push|pull REPO URL | sync | remove
               (mirrors to your connected GitHub / GitLab; its way out to them only while a mirror exists)
  sessions     Your Claude Code and devos-claude sessions on this computer, copied into a project's sandbox
               (only after you allow it here; nothing is written back): list | import --project NAME
               | scan | fetch | consent [--always|--once|--revoke] | suggest   (secrets redacted by default)
               config: your setup (CLAUDE.md, skills, agents, commands, MCP servers, plugins, four settings,
               your Git name and email) brought into the sandbox: config import | scan | open | consent
  subscriptions   Your AI subscriptions' own tools in the sandbox: Claude Code on your Claude plan,
               Codex, Gemini CLI, Copilot, Cursor, Grok — status | login TOOL | logout TOOL (each signs in
               with its own flow there; DevOS ADE never sees the login)
  password     Where the portal password is (PORTAL_PASSWORD in this folder's .env)
               --show prints it (only to a terminal)
  config       Every setting in .env, secrets masked (the portal's Settings tab shows the same):
               list | get KEY | set KEY [KEY…] (asks; hidden for secrets) | apply --stdin
               | check-aws (free) | report | regenerate rustfs|mcp-token
  restart      Restart one service: litellm | open-webui | shared-mcp | stt | rustfs | caddy | searxng | forgejo
  uninstall    Remove the containers, ALL data volumes and this install's built images
               (keeps .env and backups/)

  Commands without a $ note make no Bedrock calls.  ./stack <command> --help shows one command.
  --yes        Accept defaults (non-interactive). AWS creds can come from
               AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION_NAME.
  BEDROCK_NOW_VERBOSE=1 ./stack setup   shows the full docker compose output.
  NO_COLOR=1   turns colours off.
EOF
}

# cmd_help_for COMMAND -> that command's lines of ./stack help (fails for an unknown command)
cmd_help_for() {
  local sect
  sect="$(cmd_help | C="$1" awk '
    /^  [a-z]/ { lab = substr($0, 3); sub(/   .*/, "", lab); n = split(lab, w, /[ |]+/); on = 0
                 for (i = 1; i <= n; i++) if (w[i] == ENVIRON["C"]) on = 1
                 if (on) print; next }
    on && /^               / { print; next }
    { on = 0 }')"
  [ -n "$sect" ] || return 1
  printf 'Usage: ./stack %s [options] [--yes]\n\n%s\n' "$1" "$sect"
}

# cmd_password — ./stack password: where the portal password is; --show prints it, only to a terminal
cmd_password() {
  case "${1:-}" in '' | --show) ;; *) die "usage: ./stack password [--show]" ;; esac
  [ -f "$ENV_FILE" ] && [ -n "$(get_env PORTAL_PASSWORD)" ] || die "no portal password yet — run ./stack setup"
  if [ "${1:-}" = --show ]; then
    _stdout_tty || die "not printing the password: stdout is not a terminal (it is PORTAL_PASSWORD in $(env_file_display))"
    printf '%s\n' "$(get_env PORTAL_PASSWORD)"
    return 0
  fi
  printf 'The portal password is PORTAL_PASSWORD in %s (project %s).\n' "$(env_file_display)" "$(project_name)"
  printf 'Print it: ./stack password --show   Change it: Settings in the portal, or ./stack config set PORTAL_PASSWORD\n'
}

check_prereqs() {
  require_cmd docker "install Docker Desktop (macOS) or Docker Engine (Linux)"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin is required"
  compose_overrides_ok || die "$(compose_too_old)"
  check_docker_daemon
  check_docker_engine
  require_cmd curl; require_cmd openssl; require_cmd awk; require_cmd sed
}

check_docker_daemon() { # dies with an actionable message when `docker info` fails
  local err
  err="$(docker info 2>&1 >/dev/null)" && return 0
  case "$err" in
    *"permission denied"*) die "cannot use the Docker daemon: permission denied on its socket — add yourself to the docker group (sudo usermod -aG docker \$USER, then log out and back in), or use Docker Desktop" ;;
    *) die "the Docker daemon is not running — start Docker Desktop (macOS) or the docker service (Linux: sudo systemctl start docker)" ;;
  esac
}

check_docker_engine() { # Linux: Docker Engine < 28 can expose 127.0.0.1-published ports to the local network
  local ver major
  [ "$(uname -s)" = Linux ] || return 0
  ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"; major="${ver%%.*}"
  case "$major" in '' | *[!0-9]*) return 0 ;; esac
  [ "$major" -ge 28 ] || warn "Docker Engine $ver: versions before 28.0 can let other machines on your local network reach ports published on 127.0.0.1 — please update Docker Engine (https://docs.docker.com/engine/install/)"
}

_docker_rootless() { docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; }

# --- quiet, phased bring-up (BEDROCK_NOW_VERBOSE=1 shows all compose output) ---

fmt_elapsed() { # fmt_elapsed SECONDS -> "16s" / "2m05s"
  local s="${1:-0}"
  if [ "$s" -lt 60 ]; then printf '%ss\n' "$s"; else printf '%dm%02ds\n' $((s / 60)) $((s % 60)); fi
}
phase_line() { printf '%s ready (%s)\n' "$1" "$(fmt_elapsed "$2")"; }   # phase_line LABEL SECONDS
# helper_job — this command runs as a job of the update helper (Home's Update now, the nightly update): its log is what
# Home's progress card reads (lib/helper.sh _job_steps)
helper_job() { [ "${BEDROCK_NOW_JOB_ORIGIN:-}" = helper ] && [ ! -t 2 ]; }
# phase_start LABEL — in a helper job's log, "==> LABEL: starting…" before a phase whose "LABEL ready (…)" line follows:
# Home shows the step that runs and for how long (a terminal shows it on its own line instead; run_phase)
phase_start() { ! helper_job || is_verbose || log "$1: starting…"; }
_now() { date +%s; }
is_verbose() { [ "${BEDROCK_NOW_VERBOSE:-0}" = 1 ]; }

# quiet_compose — for the rest of this command, Compose leaves out its per-container progress lines ("Container x
# Waiting", "… Healthy": dozens per restore) and still prints its errors. BEDROCK_NOW_VERBOSE=1 shows them, and a
# COMPOSE_PROGRESS of your own is kept. compose_quiet_env -> the same as an env(1) argument, for child processes.
quiet_compose() { is_verbose || export COMPOSE_PROGRESS="${COMPOSE_PROGRESS:-quiet}"; }
compose_quiet_env() { is_verbose || printf 'COMPOSE_PROGRESS=%s\n' "${COMPOSE_PROGRESS:-quiet}"; }

# _failed_services SVCS... -> the ones that are not running, or are unhealthy/still starting (all if none match)
_failed_services() {
  local ps s state bad=''
  ps="$(dc ps -a --format '{{.Service}}	{{.State}}	{{.Health}}' 2>/dev/null || true)"
  for s in "$@"; do
    state="$(printf '%s\n' "$ps" | awk -F'\t' -v s="$s" '$1 == s { print $2 "/" $3 }')"
    case "$state" in running/healthy | running/) ;; *) bad="$bad $s" ;; esac
  done
  [ -n "$bad" ] || bad=" $*"
  printf '%s\n' "${bad# }"
}

# run_phase LABEL "SERVICES" CMD... — runs CMD (usually a dc call) with its output hidden, then prints
# "==> LABEL ready (16s)". On failure: the last 30 output lines, the last 30 log lines of each failed
# service, and the ./stack logs hint; then dies. CMD's fd 8 is the phase's own stderr (building, below).
run_phase() {
  local label="$1" svcs="$2" start rc=0 out s failed first pools='' _PHASE_TICK=''
  shift 2
  start="$(_now)"
  [ -t 2 ] || _PHASE_TICK=1   # (no terminal to show "starting…" on: an image build says it is still at work)
  if is_verbose; then
    log "$label: starting…"
    "$@" 8>&2 || rc=$?
  else
    out="$(mktemp)"; _cleanup_on_signal "$out"
    [ ! -t 2 ] || printf '%s==>%s %s: starting…' "$C_GRN" "$C_OFF" "$label" >&2
    phase_start "$label"
    "$@" 8>&2 > "$out" 2>&1 || rc=$?
    [ ! -t 2 ] || printf '\r\033[K' >&2
  fi
  [ -z "${out:-}" ] || _signal_traps_restore
  if [ "$rc" -eq 0 ]; then
    [ -z "${out:-}" ] || rm -f "$out"
    log "$(phase_line "$label" $(($(_now) - start)))"
    return 0
  fi
  warn "$label failed after $(fmt_elapsed $(($(_now) - start)))"
  if [ -n "${out:-}" ]; then
    printf '  --- last 30 lines of output ---\n' >&2; tail -n 30 "$out" | sed 's/^/    /' >&2
    ! declare -F projects_mount_hint >/dev/null || projects_mount_hint "$out"   # lib/projects.sh: a project folder Docker could not mount
    ! grep -q 'address pools have been fully subnetted' "$out" 2>/dev/null || pools=1
    rm -f "$out"
  fi
  # shellcheck disable=SC2086  # word-split the service list on purpose
  failed="$(_failed_services $svcs)"
  for s in $failed; do
    printf '  --- last 30 log lines of %s ---\n' "$s" >&2
    dc logs --no-color --tail 30 "$s" 2>&1 | sed 's/^/    /' >&2 || true
  done
  first="${failed%% *}"
  # (Docker out of address ranges for a new network: said as it is, not as a service's failure)
  [ -z "$pools" ] || die "$label did not come up: Docker has no address range left for another network (docker network ls lists them;" \
    "the networks of stacks you no longer run can go with docker network rm NAME, or Docker's default-address-pools setting gives it more)"
  die "$label did not come up — full logs: ./stack logs ${first:-<service>}   (BEDROCK_NOW_VERBOSE=1 ./stack setup shows all compose output)"
}

# building WHAT CMD... — CMD, an image build (dc build -q says nothing until it ends). In a run_phase with no terminal
# to show "starting…" on (the update helper's jobs, a log), "==> still building WHAT (2m30s)" goes to the phase's own
# stderr every BUILD_TICK_S seconds (150) while CMD runs: a long build on a slow computer is progress to the helper,
# which ends a job whose log says nothing new for 20 minutes (lib/settings_helper.sh) — a build only at its 4 h
# limit. Phases that only wait (up --wait, a restart) stay silent, so a stuck one is still ended at 20 minutes.
# CMD runs as before (in the foreground: Ctrl-C, its status); the ticker beside it is ended with it by KILL to its own
# PID — not a TERM to a process group of its own: a build that ends before the ticker's group exists, or a caller that
# ignores TERM (the ticker inherits that), left `wait` waiting for a ticker that waits for this shell (v0.20.1). KILL
# can be neither missed nor ignored, the PID is ours until waited for, and the ticker's last `sleep 1` ends by itself.
# The ticker stays in the caller's process group (the helper ends a job's group), and ends by itself within a second
# should this shell be gone.
BUILD_TICK_S="${BUILD_TICK_S:-150}"
building() {
  local what="$1" me t rc=0
  shift
  [ -n "${_PHASE_TICK:-}" ] || { "$@"; return; }
  me="$(exec sh -c 'echo "$PPID"')"   # (this shell's PID, a subshell's too: bash 3.2 has no BASHPID)
  _build_ticker "$what" "$me" </dev/null >/dev/null 2>&1 &
  t=$!
  "$@" 8>&- || rc=$?
  kill -KILL "$t" 2>/dev/null || true
  wait "$t" 2>/dev/null || true
  return "$rc"
}
_build_ticker() {   # WHAT PID — building's: a line to fd 8 every BUILD_TICK_S seconds while PID runs
  local start=$SECONDS next=$((SECONDS + BUILD_TICK_S))
  while kill -0 "$2" 2>/dev/null; do
    sleep 1
    [ "$SECONDS" -ge "$next" ] || continue
    next=$((next + BUILD_TICK_S))
    log "still building $1 ($(fmt_elapsed $((SECONDS - start))))" 2>&8 || true
  done
}

# timed_step LABEL CMD... — CMD in this shell (its own messages shown as they are, unlike run_phase's), timed as a step
# of its own: "==> LABEL: starting…" before it in a helper job's log, "==> LABEL ready (16s)" after it — so no stretch
# of setup or an update goes untimed on Home's update card (lib/helper.sh _job_steps), and a terminal sees the time too.
# CMD runs as a plain command: under set -e a failure ends the command right there, as it would without this; where
# set -e is off, a failure is said ("LABEL failed after 16s") and returned.
timed_step() {
  local label="$1" start rc
  shift
  start="$(_now)"; phase_start "$label"
  "$@"; rc=$?
  if [ "$rc" = 0 ]; then log "$(phase_line "$label" $(($(_now) - start)))"
  else warn "$label failed after $(fmt_elapsed $(($(_now) - start)))"; fi
  return "$rc"
}

image_size_mb() { # rough on-disk size of a pinned image, for the first-run download notice
  case "$1" in
    *litellm*) echo 1750 ;; *open-webui*) echo 950 ;; *aws-cli*) echo 680 ;; *pgvector*) echo 660 ;; *rustfs*) echo 360 ;;
    *caddy*) echo 90 ;; *) echo 300 ;;
  esac
}

# missing_images -> compose images not present locally (locally built ones excluded; the bases compose.yaml pins for
# them — Open WebUI's — included: lib/images.sh compose_refs)
missing_images() {
  local img
  { dc config --images 2>/dev/null; compose_refs < "$STACK_DIR/compose.yaml" 2>/dev/null; } | awk '!seen[$0]++' | while IFS= read -r img; do
    case "$img" in '' | */shared-mcp:local | */portal:local | */stt:local | */caddy-dns:local | */terminal:local | */terminal-egress:local | */code:local | */open-webui:local) continue ;; esac
    docker image inspect "$img" >/dev/null 2>&1 || printf '%s\n' "$img"
  done
}

# ensure_images [RERUN_CMD] — downloads missing pinned images up front, with Docker's own progress output.
ensure_images() {
  local rerun="${1:-./stack setup}" missing img n=0 mb=0
  missing="$(missing_images)"
  [ -n "$missing" ] || return 0
  for img in $missing; do n=$((n + 1)); mb=$((mb + $(image_size_mb "$img"))); done
  log "downloading $n image(s) (~$(awk -v m="$mb" 'BEGIN { printf "%.1f", m / 1000 }') GB on disk; on a first run this takes several minutes)"
  for img in $missing; do
    docker pull "$img" || die "could not download $img — check your network / registry access and re-run $rerun"
  done
}


# --- Open WebUI's own image: the pinned Open WebUI with the Python runner's packages (open-webui/) ---

# owui_build — builds <project>/open-webui:local (open-webui/Dockerfile; from Docker's cache unless its inputs
# changed), then records what its Python runner has (python_runner_status). A build whose vendoring could not download
# a package (vendored.txt: "download failed" — a network failure) is tried again by the next one, at most once an
# hour: a new BN_VENDOR_TRY, kept for the builds after it (Docker's cache then holds that result, never the old one).
owui_build() {
  local d try
  d="$(status_dir)"; mkdir -p "$d" 2>/dev/null || true
  # (built already in this command by setup_build_images: with the try it gave the build)
  if built_now open-webui; then try="$_OWUI_TRY"
  else
    try="$(owui_vendor_try)"
    building "Open WebUI's image (with the Python runner's packages)" dc build -q --build-arg "BN_VENDOR_TRY=$try" open-webui || return 1
  fi
  printf '%s\n' "$try" > "$d/python-runner.try" 2>/dev/null || true
  python_runner_status
}
# owui_vendor_try -> the BN_VENDOR_TRY of Open WebUI's next build: the last one's, or the hour's after a download failed
owui_vendor_try() {
  local try
  try="$(cat "$(status_dir)/python-runner.try" 2>/dev/null || true)"
  case "$try" in '' | *[!0-9]*) try=0 ;; esac
  if grep -q 'download failed' "$(status_dir)/python-runner.txt" 2>/dev/null; then try="$(date -u +%Y%m%d%H)"; fi
  printf '%s\n' "$try"
}

# setup_build_images [--sandboxes] — the images setup builds, in one compose call, which builds them side by side
# (Docker's cache makes an unchanged one a matter of seconds): the portal, shared-mcp and Open WebUI. With --sandboxes
# (./stack setup, ./stack update) the browser terminal's, its egress proxy's and the Code page's too, while they are on
# and their folder usable — in a compose call of their own, in the background (lib/steps.sh sandbox_build_start): LiteLLM,
# Open WebUI and the portal come up meanwhile, and the terminal's step waits for them (sandbox_build_wait). Your
# subscriptions' tools are part of the terminal's image: installing them again never holds up Chat or the portal.
# SETUP_BUILT then names what was built (lib/common.sh built_now), and each one's own step takes it as it is. Each image
# is a step of its own on Home's card, with when it was ready and whether it came from Docker's cache or what was built
# again (build_steps). Never fatal: a build that fails names none, and each step builds its own image as before — which
# says the failure where it belongs (setup stops for the stack's own images, not for the terminal's or the Code page's).
# A helper job's log gets "still building" lines while it runs, like a phase's (building).
# shellcheck disable=SC2034  # SETUP_BUILT: read by built_now (lib/common.sh)
setup_build_images() {
  local svcs=(portal shared-mcp open-webui) sbx=() args e out start _PHASE_TICK=''
  SETUP_BUILT=''; _OWUI_TRY="$(owui_vendor_try)"
  args=(--build-arg "BN_VENDOR_TRY=$_OWUI_TRY")
  if [ "${1:-}" = --sandboxes ] && terminal_on && [ -z "$(terminal_why_out)" ]; then
    # (each build argument is its image's alone: no other Dockerfile here declares it)
    terminal_build_args; sbx+=(terminal)
    e="$(terminal_egress_build_service)"; [ -z "$e" ] || sbx+=("$e")
    if code_ready; then fix_checkout_modes; sbx+=(code); fi
    sandbox_build_start "${TERMINAL_BUILD_ARGS[@]}" -- "${sbx[@]}"
  fi
  [ -t 2 ] || _PHASE_TICK=1
  out="$(mktemp)"; start="$(_now)"; phase_start Images
  if building "the images (${svcs[*]})" build_plain "${args[@]}" "${svcs[@]}" 8>&2 > "$out" 2>&1; then
    SETUP_BUILT=" ${svcs[*]} "
    build_steps "$out"; rm -f "$out"
    log "$(phase_line Images $(($(_now) - start)))"
    return 0
  fi
  warn "the images did not build side by side ($(fmt_elapsed $(($(_now) - start)))) — each is built on its own next; the build's last messages:"
  sed 's/^[0-9]* //' "$out" | tail -n 12 | sed 's/^/    /' >&2; rm -f "$out"
  return 0
}

# python_runner_status — the image's vendored.txt (vendor.py: a line a package, ready or left out and why) into
# .state/status/python-runner.txt, once per build (the image's ID is kept beside it): printable ASCII and tabs only,
# at most 400 lines. Never fatal.
python_runner_status() {
  local d img id f
  d="$(status_dir)"; img="$(project_name)/open-webui:local"
  id="$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || true)"
  [ -n "$id" ] || return 0
  [ "$(cat "$d/python-runner.id" 2>/dev/null || true)" != "$id" ] || return 0
  f="$(mktemp "$d/.python-runner.XXXXXX" 2>/dev/null)" || return 0
  # (/opt/bn-vendor: outside what Open WebUI serves — an image of an earlier build had it beside the wheels)
  if docker run --rm --network none --entrypoint cat "$img" /opt/bn-vendor/vendored.txt > "$f" 2>/dev/null ||
     docker run --rm --network none --entrypoint cat "$img" /app/build/pyodide/vendored.txt > "$f" 2>/dev/null; then
    LC_ALL=C tr -cd '\t\n -~' < "$f" | head -n 400 > "$d/python-runner.txt"
    chmod 644 "$d/python-runner.txt" 2>/dev/null || true
    printf '%s\n' "$id" > "$d/python-runner.id"
  fi
  rm -f "$f"
}

# python_runner_line -> "Python runner (Chat): N packages ready; left out: NAME (why), …" (./stack status), or nothing
# before a build said
python_runner_line() {
  local f; f="$(status_dir)/python-runner.txt"
  [ -s "$f" ] || return 0
  awk -F'\t' '$1 == "ready" { n++ } $1 == "left" { l = l (l != "" ? ", " : "") $2 " (" $3 ")" }
    END { printf "Python runner (Chat): %d package%s ready", n, (n == 1 ? "" : "s"); if (l != "") printf "; left out: %s", l; printf "\n" }' "$f" |
    cut -c1-600
}

# fix_checkout_modes — every tracked file and folder readable by all, as a clone made with umask 022 has them. The
# update helper runs with umask 077 (its launchd Umask / systemd UMask), so before this fix an update or rollback it
# ran wrote each new or changed file as 600 (700 for scripts): images built from them (code/: COPY keeps the mode,
# root owns the copy, the container runs as another user) could not read their own sources. Untracked files (.env,
# .state/, backups/) are never touched. Never fatal.
fix_checkout_modes() {
  [ -e "$STACK_DIR/.git" ] || return 0
  ( cd "$STACK_DIR" &&
    git ls-files -z | xargs -0 chmod go+rX 2>/dev/null
    git ls-tree -r -d --name-only -z HEAD | xargs -0 chmod go+rx 2>/dev/null
    chmod go+rx . 2>/dev/null ) || true
  return 0
}

# fix_bind_mount_perms — containers read litellm/, postgres/init.sql, caddy/Caddyfile and catalog/ (the portal)
# as non-owner users, so a strict umask (077) on clone must not make them unreadable.
fix_bind_mount_perms() {
  local f
  fix_checkout_modes
  chmod a+rX "$STACK_DIR/litellm" "$STACK_DIR/postgres" "$STACK_DIR/caddy" "$STACK_DIR/catalog"
  chmod 644 "$STACK_DIR/postgres/init.sql" "$STACK_DIR/caddy/Caddyfile" "$STACK_DIR"/catalog/*.tsv
  for f in "$STACK_DIR"/caddy/*.caddy "$STACK_DIR/caddy/Dockerfile"; do [ ! -f "$f" ] || chmod 644 "$f"; done   # remote access
  [ ! -f "$STACK_DIR/litellm/config.yaml" ] || chmod 644 "$STACK_DIR/litellm/config.yaml"
}

# persist_project_name — on the FIRST setup only (no POSTGRES_PASSWORD yet), a COMPOSE_PROJECT_NAME from the
# shell (second copy of the stack) is validated and stored in .env so every later ./stack command targets
# that project. On later runs a different shell value stops setup before anything is changed.
persist_project_name() {
  local want="${COMPOSE_PROJECT_NAME:-}" cur
  if [ -n "$(get_env POSTGRES_PASSWORD)" ]; then
    cur="$(project_name)"
    [ -z "$want" ] || [ "$want" = "$cur" ] ||
      die "this checkout is project '$cur' but COMPOSE_PROJECT_NAME=$want is set in your shell — unset it (or use the other checkout). Nothing was changed."
    return 0
  fi
  [ -n "$want" ] || return 0
  case "$want" in
    [a-z0-9]*) case "$want" in *[!a-z0-9_-]*) die "COMPOSE_PROJECT_NAME must be lowercase letters, digits, - or _ (got '$want')" ;; esac ;;
    *) die "COMPOSE_PROJECT_NAME must start with a lowercase letter or digit (got '$want')" ;;
  esac
  set_env COMPOSE_PROJECT_NAME "$want"
}

# --- one Compose project per checkout: lib/guard.sh (guard_project, guard_uninstall) ---

# aws_cli ARGS... — runs aws-cli in a throwaway container with creds from .env (never on argv).
# AWS_REGION_OVERRIDE=<region> calls a different region than .env's AWS_REGION_NAME (per-model regions).
# AWS_AUTH=instance-role (lib/host.sh): no creds at all, the container uses the EC2 instance role via IMDS.
aws_cli() {
  if uses_instance_role; then
    aws_run_role "${AWS_REGION_OVERRIDE:-$(get_env AWS_REGION_NAME)}" "$@"
  else
    aws_run "$(get_env AWS_ACCESS_KEY_ID)" "$(get_env AWS_SECRET_ACCESS_KEY)" "${AWS_REGION_OVERRIDE:-$(get_env AWS_REGION_NAME)}" "$@"
  fi
}

# aws_run KEY_ID SECRET REGION ARGS... — same, with explicit creds (handed to docker via -e NAME, not argv).
aws_run() {
  local id="$1" secret="$2" region="$3"; shift 3
  AWS_ACCESS_KEY_ID="$id" AWS_SECRET_ACCESS_KEY="$secret" AWS_DEFAULT_REGION="$region" \
    docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION "$AWS_CLI_IMAGE" "$@" </dev/null
}

# _reject_temporary_creds KEY_ID [SESSION_TOKEN] — STS credentials expire within hours and LiteLLM
# would then fail mid-session, so only long-lived IAM user keys (AKIA…) are accepted.
_reject_temporary_creds() {
  case "$1" in ASIA*) ;; *) [ -n "${2:-}" ] || return 0 ;; esac
  die "temporary AWS credentials (an ASIA… key or AWS_SESSION_TOKEN) aren't supported — they expire and LiteLLM would stop working. Use a long-lived IAM user access key (starts with AKIA); if it came from your shell, unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN"
}

# _env_aws_creds_chosen -> 0 if the AWS_* creds exported in this shell should be used: always when
# non-interactive (--yes or no terminal), only after an explicit "y" when someone is at the keyboard.
_env_aws_creds_chosen() {
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || return 1
  if [ "${ASSUME_YES:-0}" = 1 ] || ! _have_tty; then return 0; fi
  # Default Yes only for a long-lived IAM user key (AKIA…, no session token); temporary ones are refused later.
  local yn="[y/N]" def=n
  case "$AWS_ACCESS_KEY_ID" in AKIA*) [ -n "${AWS_SESSION_TOKEN:-}" ] || { yn="[Y/n]"; def=y; } ;; esac
  case "$(ask "found AWS_ACCESS_KEY_ID=$(printf '%s' "$AWS_ACCESS_KEY_ID" | cut -c1-8)… in your environment — use it? $yn" "$def")" in
    [Yy]*) return 0 ;; *) return 1 ;;
  esac
}

setup_aws_creds() {
  local id='' secret='' region arn errf
  setup_instance_role && return 0   # EC2 with an IAM role and no key configured: no keys at all (lib/host.sh)
  region="${AWS_REGION_NAME:-${AWS_REGION:-}}"
  if _env_aws_creds_chosen; then
    id="$AWS_ACCESS_KEY_ID"; secret="$AWS_SECRET_ACCESS_KEY"
    _reject_temporary_creds "$id" "${AWS_SESSION_TOKEN:-}"
  elif [ -n "$(get_env AWS_ACCESS_KEY_ID)" ] && confirm "Keep the AWS key already in .env ($(get_env AWS_ACCESS_KEY_ID | cut -c1-8)…)?"; then
    id="$(get_env AWS_ACCESS_KEY_ID)"; secret="$(get_env AWS_SECRET_ACCESS_KEY)"
  fi
  [ -n "$id" ] || id="$(ask "AWS access key ID" "")"
  [ -n "$secret" ] || [ -z "$id" ] || ! _have_tty || [ "${ASSUME_YES:-0}" = 1 ] || secret="$(ask_secret "AWS secret access key (hidden)")"
  [ -n "$id" ] && [ -n "$secret" ] ||
    die "AWS credentials are required (non-interactive: export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or run ./setup.sh in a terminal; on EC2, attach an IAM role instead — docs/cloud-vm.md)"
  _reject_temporary_creds "$id"
  region="$(ask "AWS region" "${region:-$(get_env AWS_REGION_NAME)}")"; region="${region:-us-east-1}"
  valid_region "$region" || die "invalid AWS region: '$region' (expected something like us-east-1)"
  # Leaving the instance role: the key is proven first, so a bad key never ends role mode (lib/host.sh).
  ! uses_instance_role || verify_key_leaving_role "$id" "$secret" "$region"
  set_env AWS_ACCESS_KEY_ID "$id"; set_env AWS_SECRET_ACCESS_KEY "$secret"; set_env AWS_REGION_NAME "$region"
  unset_env AWS_AUTH
  # (pinned: one that is here already is the one — an update's downloads have just looked at it)
  docker image inspect "$AWS_CLI_IMAGE" >/dev/null 2>&1 || docker pull -q "$AWS_CLI_IMAGE" >/dev/null || die "could not pull $AWS_CLI_IMAGE (network/Docker Hub?)"
  log "verifying AWS credentials…"
  errf="$(mktemp)"
  if ! arn="$(aws_cli sts get-caller-identity --query Arn --output text 2>"$errf")"; then
    arn="$(cat "$errf")"; rm -f "$errf"; die "AWS rejected the credentials: $arn"
  fi
  rm -f "$errf"
  log "authenticated as $arn"
}

setup_ports() {
  migrate_direct_ports
  setup_portal_host
  resolve_portal_port
  resolve_port LITELLM_PORT 4000 litellm 4000
  resolve_port SHARED_MCP_PORT 8765 shared-mcp 8000
}

# litellm_password_ok PASSWORD -> 0 when it meets LiteLLM's default policy: 12+ chars with an upper- and a
# lowercase letter, a digit and a symbol.
litellm_password_ok() {
  [ "${#1}" -ge 12 ] || return 1
  case "$1" in *[[:upper:]]*) ;; *) return 1 ;; esac
  case "$1" in *[[:lower:]]*) ;; *) return 1 ;; esac
  case "$1" in *[[:digit:]]*) ;; *) return 1 ;; esac
  case "$1" in *[![:alnum:]]*) ;; *) return 1 ;; esac
}

# upgrade_litellm_password — runs before LiteLLM starts, so it always starts with a password its policy
# accepts. Older installs have hex passwords: they get a "Bn9-" prefix (once). Anything else that still
# fails the policy is replaced by a new generated one.
upgrade_litellm_password() {
  local pw; pw="$(get_env LITELLM_UI_PASSWORD)"
  litellm_password_ok "$pw" && return 0
  case "$pw" in
    Bn9-*) ;;
    *) if litellm_password_ok "Bn9-$pw"; then
         set_env LITELLM_UI_PASSWORD "Bn9-$pw"
         log "LITELLM_UI_PASSWORD in .env now starts with Bn9- (LiteLLM requires upper/lowercase, a digit and a symbol)"
         return 0
       fi ;;
  esac
  set_env LITELLM_UI_PASSWORD "Bn9-$(gen_hex 12)"
  warn "LITELLM_UI_PASSWORD in .env did not meet LiteLLM's password policy (12+ characters, upper/lowercase, digit, symbol) — generated a new one (see .env)"
}

# A newly generated portal password (first setup, or the first setup after an update from v0.1.x) is shown by
# the next summary that gets printed (marker .state/portal-password-shown), even if this run fails first.
setup_secrets() {
  [ -n "$(get_env PORTAL_PASSWORD)" ] || rm -f "$STATE_DIR/portal-password-shown"
  ensure_env PORTAL_PASSWORD "$(gen_hex 10)"
  ensure_portal_password_hash   # lib/settings.sh: the portal gets the hash, never the password
  ensure_env PORTAL_SECRET "$(gen_hex 32)"
  ensure_env POSTGRES_PASSWORD "$(gen_hex 24)"
  ensure_env LITELLM_MASTER_KEY "sk-$(gen_hex 24)"
  ensure_env LITELLM_SALT_KEY "sk-$(gen_hex 24)"   # never change after first run: encrypts stored creds
  ensure_env LITELLM_UI_PASSWORD "Bn9-$(gen_hex 12)"   # LiteLLM's policy: upper+lower case, digit, symbol
  upgrade_litellm_password
  ensure_env WEBUI_SECRET_KEY "$(gen_hex 32)"
  ensure_env OPENWEBUI_ADMIN_PASSWORD "$(gen_hex 12)"
  ensure_env RUSTFS_ACCESS_KEY "bn-$(gen_hex 6)"
  ensure_env RUSTFS_SECRET_KEY "$(gen_hex 24)"
  ensure_env SHARED_MCP_TOKEN "$(gen_hex 32)"
  remote_ensure_proxy_secret   # Caddy → portal: proves a request came through Caddy (lib/remote.sh)
  ensure_env BUDGET_CLAUDE_CODE 200
  ensure_env BUDGET_OPENWEBUI 50
  ensure_env BUDGET_SETUP 5
  ensure_env LITELLM_STORE_PROMPTS false
  # the built-in SearXNG (lib/websearch.sh): on by default (off stays off), and its own secret (never printed)
  ensure_env WEBSEARCH_SEARXNG_BUILTIN on
  ensure_env WEBSEARCH_SEARXNG_SECRET "$(gen_hex 32)"
  localgit_secrets   # lib/localgit.sh: the built-in git server on by default (off stays off), and its owner account's password
  local email src def typed asked=0
  owner_email_lowercase   # lib/settings.sh: Chat keeps emails in lowercase
  email="$(get_env OPENWEBUI_ADMIN_EMAIL)"
  if [ -n "$email" ]; then
    src="from OPENWEBUI_ADMIN_EMAIL in .env"
  else
    def="$(git config user.email 2>/dev/null || true)"
    if [ -n "$def" ]; then src="from git config"; else def=admin@bedrock-now.local; src="default"; fi
    if [ "${ASSUME_YES:-0}" != 1 ] && _have_tty; then asked=1; fi
    typed="$(ask "Open WebUI admin email" "$def")"
    # Chat (Open WebUI) keeps every email address in lowercase and ignores the case at sign-in, and the Admin
    # (LiteLLM) sign-in uses this address as typed: so it is stored in lowercase
    email="$(printf '%s' "$typed" | tr '[:upper:]' '[:lower:]')"
    case "$email" in *@*.*) set_env OPENWEBUI_ADMIN_EMAIL "$email" ;; *) die "invalid email: $typed" ;; esac
    if [ "$asked" = 1 ]; then   # you just chose it: say only what was changed about it
      src=''
      [ "$typed" = "$email" ] || src="in lowercase: Chat keeps email addresses in lowercase and ignores the case at sign-in"
    else
      src="$src; to use another address, set OPENWEBUI_ADMIN_EMAIL in .env before the first setup, or later in Settings → Owner email"
    fi
  fi
  log "Open WebUI admin: $email${src:+ ($src)}"
}

# --- setup stopped by Ctrl-C (or TERM): what it did, what still runs, and how to go on ---
SETUP_STEP=''; SETUP_DONE=''; SETUP_CODE_DEFAULT=0
# setup_step "probing which models …": doing now (in a helper job's log too, "==> doing: …": Home's progress card)
setup_step() { SETUP_STEP="$1"; ! helper_job || log "doing: $1"; }
setup_done() { SETUP_DONE="${SETUP_DONE:+$SETUP_DONE; }$1"; SETUP_STEP=''; }   # setup_done "Postgres + RustFS started"

# _setup_undo_code_default 1|2 — a Code page this setup turned on by default (code_default_on; 2: the terminal too) and
# that did not settle yet: off again, blank as before (the next setup turns it on again; no failure is counted, unlike
# code_default_settle's), its containers stopped while compose still knows them, the update's record and Home's notice
# without it. (Caddy and the portal may still name it until ./stack setup or ./stack up.) Never fatal.
_setup_undo_code_default() {
  if [ "$1" = 2 ]; then dc rm -sf code subs-chat terminal terminal-gateway >/dev/null 2>&1 || true
  else dc rm -sf code subs-chat >/dev/null 2>&1 || true; fi
  ! declare -F chat_proxy_rm >/dev/null || chat_proxy_rm   # (Chat's own egress proxy too, with host egress: lib/terminal.sh)
  if [ "$1" = 2 ]; then (set_env_batch CODE_ENABLED '' TERMINAL_ENABLED '') 2>/dev/null || true
  else (set_env CODE_ENABLED '') 2>/dev/null || true; fi
  (terminal_remote_sync; code_remote_sync) >/dev/null 2>&1 || true
  if declare -F _record_set >/dev/null && [ -n "$(_record_get code_default 2>/dev/null || true)" ]; then (_record_set code_default '') 2>/dev/null || true; fi
  ! declare -F code_default_notice_clear >/dev/null || code_default_notice_clear
}

# _setup_interrupted INT|TERM — setup's _SIGNAL_HOOK (lib/common.sh): says what was done, which services still run,
# and how to continue (./stack setup) or clean up (./stack down / ./stack uninstall); then ends (130 / 143) and the
# exit hooks run (the lock, a LiteLLM config restore after the model probe). Run by another ./stack command (update's
# setup step), it leaves the "how to go on" to that command.
_setup_interrupted() {
  local how running
  trap '' INT TERM   # a second Ctrl-C does not cut this short
  _SIGNAL_HOOK=''
  case "$1" in INT) how="Ctrl-C" ;; *) how="$1" ;; esac
  printf '\n' >&2
  warn "setup stopped ($how)${SETUP_STEP:+ while $SETUP_STEP}"
  if [ -n "$SETUP_DONE" ]; then printf '    Done: %s.\n' "$SETUP_DONE" >&2; else printf '    Nothing was started yet.\n' >&2; fi
  if [ "${SETUP_CODE_DEFAULT:-0}" != 0 ]; then
    _setup_undo_code_default "$SETUP_CODE_DEFAULT"
    printf '    The Code page, turned on by default in this run, is off again: ./stack setup turns it on (./stack code disable keeps it off).\n' >&2
  fi
  running="$(dc ps --services --status running 2>/dev/null | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/ $//' -e 's/ /, /g' || true)"
  if [ -n "$running" ]; then printf '    Still running: %s.\n' "$running" >&2; else printf '    Nothing of the stack is running.\n' >&2; fi
  if [ -z "${BEDROCK_NOW_LOCK_HELD:-}" ] || [ "$BEDROCK_NOW_LOCK_HELD" = "$$" ]; then
    printf '    To go on: ./stack setup — it keeps .env (your AWS key, ports and passwords) and what was set up.\n' >&2
    if [ -n "$running" ]; then
      printf '    To stop instead: ./stack down (keeps the data); ./stack uninstall removes the containers and data too.\n' >&2
    else
      printf '    To start over instead: ./stack uninstall (removes what setup made; keeps .env), then ./stack setup.\n' >&2
    fi
  fi
  trap - INT TERM
  case "$1" in INT) exit 130 ;; *) exit 143 ;; esac
}

# setup's own steps, each timed as one (cmd_setup)
_setup_settings() {
  setup_ports
  setup_done "ports chosen (the portal: $(portal_url))"; setup_step "asking about remote access"
  setup_remote_choice   # lib/remote.sh: asks once — this computer only (default), or your devices too
  remote_net_preflight  # remote access on: its Docker network usable? else this run goes on without it
  setup_step "writing passwords and settings into .env"
  setup_secrets
  setup_step "asking about OpenRouter and voice"
  setup_openrouter   # optional; lib/openrouter.sh
  setup_explabs      # optional; lib/explabs.sh (no question: Settings or ./stack config set EXPLABS_API_KEY)
  setup_stt          # optional; lib/stt.sh
}
_setup_smoke_test() {
  ensure_portal_reachable   # (the terminal's and the Code page's fronts recreate Caddy too)
  cmd_test
}
_setup_finish() {
  offer_symlink
  offer_helper   # lib/helper.sh: asks once; --yes installs it only with BEDROCK_NOW_HELPER=1
  if [ -n "$SETUP_REMOTE_MODE" ]; then remote_enable "$SETUP_REMOTE_MODE"; else remote_up_hook; fi
  record_setup_commit   # lib/rollback.sh: ./stack update calls "nothing new" only for this commit
  services_status_write   # Home's record of the containers, as setup leaves them (the built-in SearXNG's row)
  write_versions_json || true   # lib/versions.sh: Settings' Core services (never what decides a setup)
  subs_refresh_reap   # lib/subscriptions.sh: what your subscriptions' tools say, asked in the background since they started
}

cmd_setup() {
  check_prereqs
  _SIGNAL_HOOK=_setup_interrupted; _signal_traps_restore   # Ctrl-C: what was done, and how to go on
  SUBS_REFRESH_BG=1   # (lib/subscriptions.sh: what the tools say is asked in the background, while setup goes on)
  [ ! -f "$ENV_FILE" ] || stack_lock setup
  forget_setup_commit   # lib/rollback.sh: written again only if this setup succeeds
  [ -f "$ENV_FILE" ] || { cp "$STACK_DIR/.env.example" "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
  # Never share a Compose project (or its volumes) with another checkout. On a first setup the name may still
  # come from the shell, so check that name before persist_project_name saves it.
  if [ -z "$(get_env POSTGRES_PASSWORD)" ] && [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then guard_project "$COMPOSE_PROJECT_NAME"
  else guard_project; fi
  persist_project_name   # a mismatching shell project name stops setup before any change
  chmod 600 "$ENV_FILE"
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  ensure_portal_dirs; write_version_file   # lib/version.sh: what the portal mounts, and the installed version
  fix_bind_mount_perms
  # (each stretch below is a step of its own on Home's update card, with its time: timed_step, run_phase)
  setup_step "checking your AWS key"
  timed_step "AWS key check" setup_aws_creds
  setup_done "AWS key checked"; setup_step "choosing ports"
  timed_step "Ports and settings in .env" _setup_settings
  setup_done "passwords and settings in .env"
  setup_bringup_and_probe --sandboxes   # (the terminal's and the Code page's images too, in the background meanwhile)
  timed_step "Voice" stt_after_probe    # lib/stt.sh: Bedrock speech-to-text on by default when Voxtral is usable
  websearch_builtin_up    # lib/websearch.sh: the built-in SearXNG up (on by default) or gone (off); never fatal
  timed_step "Web search check" websearch_after_start   # lib/websearch.sh: one search with the backend in use (on the setup key), or why there is none
  timed_step "Git server" localgit_start               # lib/localgit.sh: the built-in git server up (on by default) or gone (off); never fatal
  setup_step "creating keys and starting Open WebUI, the portal and the MCP server"
  setup_keys_and_ui
  write_mcp_config
  setup_done "keys created; Open WebUI, the portal and the MCP server started"
  setup_step "turning on the Code page and its terminal (on by default, unless turned off)"
  timed_step "Code page default" code_default_on   # lib/code.sh: the Code page and its sandbox (the terminal) on by default, unless turned off
  SETUP_CODE_DEFAULT="$CODE_DEFAULT_ON"   # until it settles: a Ctrl-C undoes it (_setup_interrupted)
  setup_step "building and starting the browser terminal and the Code page (the first time about 1.6 GB, a few minutes)"
  terminal_setup_hook   # lib/terminal.sh: the browser terminal, when on — rebuilt with the current keys; never fatal
  code_setup_hook       # lib/code.sh: the Code page, when on (after the terminal: its sandbox) — rebuilt; never fatal
  code_default_settle   # lib/code.sh: a default that did not come up is off again (said); the next setup tries again
  localgit_after_up     # lib/localgit.sh: the git server's owner account and the Code page's host for it, now that both run; never fatal
  SETUP_CODE_DEFAULT=0  # (settled: a Ctrl-C from here on leaves the Code page as it is)
  ! code_ready || setup_done "the terminal and the Code page started"
  setup_step "running the smoke test"
  timed_step "Smoke test" _setup_smoke_test
  setup_done "smoke test passed"; setup_step "finishing (devos-claude link, one-click updates, remote access)"
  timed_step "Finishing" _setup_finish
  _SIGNAL_HOOK=''; _signal_traps_restore   # done: Ctrl-C from here on only skips the summary or the browser
  print_summary
  [ "$(host_os)" != Darwin ] || docker_autostart_hint_weekly   # lib/host.sh: read-only check, at most weekly
  maybe_auto_open
}

# --- setup part 2: bring-up, model probe, virtual keys, Open WebUI ---

# render_config ENABLED_FILE("" = all) [OUT] — atomic: OUT is replaced only if rendering succeeds.
render_config() {
  local out="${2:-$STACK_DIR/litellm/config.yaml}" tmp hook htmp
  tmp="$(mktemp "$out.XXXXXX")" || die "cannot create a temp file next to $out"
  # LiteLLM's hook first, next to the config that will name it (the config names it while its source exists)
  hook="$(dirname "$out")/bn_hooks.py"
  if [ -r "$(bn_hook_src)" ] && ! cmp -s "$(bn_hook_src)" "$hook"; then
    htmp="$(mktemp "$hook.XXXXXX")" && cp "$(bn_hook_src)" "$htmp" && chmod 644 "$htmp" && mv "$htmp" "$hook" ||
      { rm -f "$tmp" "${htmp:-}"; die "could not copy LiteLLM's hook to $hook"; }
  fi
  if ! (render_litellm_config "$1" "$(get_env AWS_REGION_NAME)" "$(get_env LITELLM_STORE_PROMPTS)" \
        "$([ -n "$(get_env ALERT_WEBHOOK_URL)" ] && echo true || echo false)" "$(get_env LITELLM_DB_ADMIN_READY)") > "$tmp"; then
    rm -f "$tmp"; die "could not render $out"
  fi
  # never a config LiteLLM cannot read (a model name with a character YAML refuses): the old one stays
  litellm_config_safe "$tmp" || { rm -f "$tmp"; die "the rendered $out is not valid YAML — kept the previous one (a model name with a character YAML refuses?)"; }
  chmod 644 "$tmp"   # read by the litellm container
  mv "$tmp" "$out"
  # the models of the Code page and devos-claude (lib/code_models.sh), next to the config: the portal, devos-claude
  # and LiteLLM's hook (lib/litellm-hooks/bn_hooks.py) read it
  ! declare -F code_models_write >/dev/null || code_models_write "$1" "$(dirname "$out")/code-models.tsv"
  # the search backend in use and its price per search (lib/websearch.sh), next to it: the hook and the portal read it;
  # and the built-in SearXNG's settings (searxng/), for this checkout's own config
  ! declare -F websearch_write_json >/dev/null || websearch_write_json "$(dirname "$out")/web-search.json"
  ! declare -F websearch_searxng_write >/dev/null || [ "$out" != "$STACK_DIR/litellm/config.yaml" ] || websearch_searxng_write
  # the chosen Experiential Labs models for the portal (lib/explabs.sh; removed while it is off)
  ! declare -F explabs_write_portal_json >/dev/null || [ "$out" != "$STACK_DIR/litellm/config.yaml" ] || explabs_write_portal_json
}

# litellm_ui_user -> the LiteLLM UI login name: the database admin's email once setup created it, else "admin"
litellm_ui_user() {
  if [ "$(get_env LITELLM_DB_ADMIN_READY)" = true ]; then get_env OPENWEBUI_ADMIN_EMAIL; echo; else echo admin; fi
}

valid_budget() { # valid_budget VALUE -> 0 if a plain non-negative number (e.g. 200 or 12.50)
  case "$1" in '' | . | *[!0-9.]* | *.*.*) return 1 ;; esac
}

parse_virtual_key() { # parse_virtual_key < /key/generate JSON -> the sk-… key, or fails
  local k; k="$(json_get key)"
  case "$k" in sk-?*) printf '%s\n' "$k" ;; *) return 1 ;; esac
}

# _pinned PIN_KEY EN -> the model PIN_KEY in .env pins (Settings, ./stack config set) while it is an enabled chat
# model; nothing when unpinned; a warning when the pinned one is no longer enabled (the automatic choice is used)
_pinned() {
  local p w; p="$(get_env "$1")"
  [ -n "$p" ] || return 0
  if grep -qxF "$p" "$2" 2>/dev/null && catalog_rows | P="$p" awk -F'\t' '$1 == ENVIRON["P"] && $2 == "chat" { f = 1 } END { exit !f }'; then
    printf '%s\n' "$p"
  else
    case "$1" in CLAUDE_MODEL_*) w='Claude Code' ;; *) w='Chat & voice' ;; esac
    warn "$1=$p is not a chat model your AWS key can use now — using the automatic choice (Settings → $w)"
  fi
  return 0
}

choose_defaults() { # derive model choices from litellm/enabled-models.txt (pins in .env win while enabled)
  local en="$STACK_DIR/litellm/enabled-models.txt" m p
  p="$(_pinned CLAUDE_MODEL_OPUS "$en")"; set_env CLAUDE_BEDROCK_OPUS_MODEL "${p:-$(first_enabled "$en" claude-opus-5-5 claude-sonnet-5-5 claude-sonnet-4-5)}"
  p="$(_pinned CLAUDE_MODEL_SONNET "$en")"; set_env CLAUDE_BEDROCK_SONNET_MODEL "${p:-$(first_enabled "$en" claude-sonnet-5-5 claude-sonnet-4-5)}"
  p="$(_pinned CLAUDE_MODEL_HAIKU "$en")"; set_env CLAUDE_BEDROCK_HAIKU_MODEL "${p:-$(first_enabled "$en" claude-haiku-5-5 claude-sonnet-4-5)}"
  [ -n "$(get_env CLAUDE_BEDROCK_OPUS_MODEL)" ] || warn "no Claude model is usable with this key — devos-claude will not work"

  # Open WebUI: default chat model, and the model for titles/tags/follow-up suggestions: the one pinned, else none —
  # then Open WebUI asks each chat's own model (TASK_MODEL_EXTERNAL empty: its get_task_model_id keeps the chat's), so
  # a chat on a free model stays free; pin a cheap one (CHAT_TASK_MODEL) to keep them off an expensive chat model
  m="$(first_enabled "$en" claude-sonnet-5-5 claude-sonnet-4-5 claude-haiku-5-5)"
  p="$(_pinned CHAT_DEFAULT_MODEL "$en")"; set_env OWUI_DEFAULT_MODEL "${p:-$m}"
  p="$(_pinned CHAT_TASK_MODEL "$en")"; set_env OWUI_TASK_MODEL "$p"

  # Bedrock-only rule: never let Open WebUI fall back to a local (Hugging Face-downloaded) embedder.
  m="$(first_enabled "$en" cohere-embed-v4 titan-embed-v2)"
  set_env OWUI_EMBED_ENGINE openai; set_env OWUI_EMBED_MODEL "$m"
  [ -n "$m" ] || warn "no Bedrock embedding model is enabled for your key — document upload/RAG in Open WebUI won't work until your AWS admin enables Cohere Embed v4 or Titan Embed v2"

  m="$(first_enabled "$en" cohere-rerank-3-5)"
  if [ -n "$m" ]; then set_env OWUI_HYBRID_SEARCH true; set_env OWUI_RERANK_ENGINE external; set_env OWUI_RERANK_MODEL "$m"
  else set_env OWUI_HYBRID_SEARCH false; set_env OWUI_RERANK_ENGINE ""; set_env OWUI_RERANK_MODEL ""; fi

  m="$(first_enabled "$en" sd3-5-large stable-image-ultra stable-image-core)"
  if [ -n "$m" ]; then set_env OWUI_ENABLE_IMAGES true; set_env OWUI_IMAGE_MODEL "$m"
  else set_env OWUI_ENABLE_IMAGES false; set_env OWUI_IMAGE_MODEL ""; fi
}

# If setup dies while LiteLLM runs the full probing catalog, put the last known-good config back.
_restore_litellm_config() {
  local en="$STACK_DIR/litellm/enabled-models.txt"
  rm -f "$en.new"
  [ -s "$en" ] || return 0
  warn "setup stopped during the model probe — restoring the previous LiteLLM config"
  (render_config "$en" && dc up -d --no-deps --force-recreate litellm >/dev/null 2>&1) || warn "could not restore it; re-run ./stack setup"
}

# --- the model probe, kept while nothing it depends on changed (an update, a setup again) ---
# PROBE_REUSE_MAX_S: how long its answers stand at most (a week: a model your AWS admin enables meanwhile shows by then;
# ./stack models --recheck checks again at once). The mark: .state/models/probe.mark (fingerprint=, at=).
PROBE_REUSE_MAX_S="${BEDROCK_NOW_PROBE_MAX_AGE_S:-604800}"
probe_mark_file() { printf '%s\n' "$STATE_DIR/models/probe.mark"; }
# probe_fingerprint -> a hash of what the probe's answers depend on: .env's AWS_* lines (the key, its region, how it
# signs in — hashed, never kept as they are), the model catalog, LiteLLM's image and the probe's own code
probe_fingerprint() {
  { grep -E '^AWS_' "$ENV_FILE" 2>/dev/null; catalog_rows 2>/dev/null; grep -E 'berriai/litellm' "$STACK_DIR/compose.yaml" 2>/dev/null
    cat "$STACK_DIR/lib/models.sh" 2>/dev/null; } | openssl dgst -sha256 | awk '{ print $NF }'
}
# probe_reusable -> 0 when the last probe's answers still stand: the same fingerprint, younger than PROBE_REUSE_MAX_S,
# and its results still there (litellm/enabled-models.txt, litellm/probe-results.tsv); prints how old they are
probe_reusable() {
  local f fp at age
  f="$(probe_mark_file)"; [ -r "$f" ] || return 1
  [ -s "$STACK_DIR/litellm/enabled-models.txt" ] && [ -s "$STACK_DIR/litellm/probe-results.tsv" ] || return 1
  fp="$(sed -n 's/^fingerprint=//p' "$f")"; at="$(sed -n 's/^at=//p' "$f")"
  case "$at" in '' | *[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - at ))
  [ -n "$fp" ] && [ "$fp" = "$(probe_fingerprint)" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$PROBE_REUSE_MAX_S" ] || return 1
  if [ "$age" -lt 7200 ]; then printf '%s min\n' $((age / 60)); else printf '%s h\n' $((age / 3600)); fi
}
# probe_mark — the probe just answered: its fingerprint and the time (a failure to write it only means a probe next time)
probe_mark() {
  local d tmp
  d="$(dirname "$(probe_mark_file)")"
  mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null && tmp="$(mktemp "$d/.probe.XXXXXX" 2>/dev/null)" || return 0
  printf 'fingerprint=%s\nat=%s\n' "$(probe_fingerprint)" "$(date +%s)" > "$tmp" && mv -f "$tmp" "$(probe_mark_file)" || rm -f "$tmp"
  return 0
}

# setup_bringup_and_probe [--sandboxes] — the images (setup_build_images: --sandboxes, the terminal's and the Code page's
# too), today's prices, LiteLLM's config, Postgres + RustFS and LiteLLM, around a model probe unless its last answers
# still stand. LiteLLM is recreated only when its configuration changed (up_services; config_sums).
setup_bringup_and_probe() {
  local en="$STACK_DIR/litellm/enabled-models.txt" age
  # Every image setup builds, first and side by side; then today's prices before LiteLLM's config is rendered
  # (lib/prices.sh; never fatal): the portal image runs the updater, and one from before an update would not have it.
  ensure_prices_dir
  setup_step "building the images"
  setup_build_images "$@"
  timed_step "Prices" _setup_prices
  # Nothing the probe depends on changed since it last answered (SETUP_REPROBE=1: ./stack models --recheck asks
  # again): LiteLLM starts once, with the models it found, instead of twice around a new probe
  if [ "${SETUP_REPROBE:-0}" != 1 ] && age="$(probe_reusable)"; then
    log "model check: not run again — nothing it depends on changed (the same AWS key, region, model catalog and LiteLLM; the last check $age ago). ./stack models --recheck checks again"
    timed_step "LiteLLM config (model check kept)" render_config "$en"
    setup_step "downloading images"
    timed_step "Image downloads" _setup_downloads
    timed_step "Open WebUI image" _setup_owui_image
    # lib/websearch.sh: AgentCore Web Search's check (free; in LiteLLM's image) when its last answer no longer stands:
    # the config follows the new one
    timed_step "LiteLLM config: web search check, default models" _setup_websearch_render "$en"
    setup_step "starting Postgres + RustFS"
    run_phase "Postgres + RustFS" "postgres rustfs" _up_data_services
    setup_done "Postgres + RustFS started"
    setup_step "starting LiteLLM with the models your key can use"
    run_phase "LiteLLM ($(wc -l < "$en" | tr -d ' ') models)" litellm up_services --no-deps litellm
    timed_step "LiteLLM setup key" ensure_virtual_key LITELLM_KEY_SETUP setup "$(get_env BUDGET_SETUP)"
    setup_done "model check kept"
    return 0
  fi
  log "rendering LiteLLM config with the full catalog for probing"
  on_exit _restore_litellm_config
  timed_step "LiteLLM config (full catalog, for the model check)" render_config ""
  setup_step "downloading images"
  timed_step "Image downloads" _setup_downloads
  timed_step "Open WebUI image" _setup_owui_image
  setup_step "starting Postgres + RustFS"
  run_phase "Postgres + RustFS" "postgres rustfs" _up_data_services
  setup_done "Postgres + RustFS started"
  warn "LiteLLM restarts while probing models; active devos-claude/Open WebUI requests may fail for ~1 min"
  setup_step "starting LiteLLM for the model check"
  run_phase "LiteLLM (full catalog, for probing)" litellm up_services --no-deps litellm
  setup_done "LiteLLM started"
  # Probe and smoke-test spend is booked on its own key, so ./stack costs shows what setup itself cost.
  setup_step "checking which models your AWS key can use"
  timed_step "Model check" _setup_model_check "$en"
  setup_done "model check done"; setup_step "restarting LiteLLM with the models your key can use"
  run_phase "LiteLLM ($(wc -l < "$en" | tr -d ' ') models)" litellm up_services --no-deps litellm
}
# setup_bringup_and_probe's own steps, each timed as one
_setup_prices() {
  if built_now portal || dc build -q portal >/dev/null 2>&1; then refresh_prices 1
  else warn "could not build the portal image yet — prices stay as they are (./stack logs portal after setup)"; fi
}
# (an update's downloads first, which ran side by side with the builds: lib/steps.sh pulls_wait; then any image still
# missing, as on a first setup)
_setup_downloads() { pulls_wait; ensure_images; }
_setup_owui_image() {
  owui_build || die "could not build Open WebUI's image (./stack logs is empty for a build: run ./stack setup again and read its output)"
}
# (the default models from the models found: .env only — before Postgres starts, nothing reads them)
_setup_websearch_render() { if websearch_before_render; then render_config "$1"; fi; choose_defaults; }
_setup_model_check() {
  local en="$1"
  ensure_virtual_key LITELLM_KEY_SETUP setup "$(get_env BUDGET_SETUP)"
  log "probing which models your AWS key can use (chat/embedding/rerank/speech-to-text: 1-token requests, speech-to-text also half a second of audio, < \$0.01 total; images: free check)"
  probe_models "$en.new" "$STACK_DIR/litellm/probe-results.tsv"
  [ -s "$en.new" ] || die "no models are usable with this AWS key — check with your AWS admin"
  mv "$en.new" "$en"
  probe_mark
  # lib/websearch.sh: AgentCore Web Search's check (free; in LiteLLM's image), whose answer the config follows
  if [ "${SETUP_REPROBE:-0}" = 1 ]; then websearch_before_render --force || true; else websearch_before_render || true; fi
  render_config "$en"
  off_exit _restore_litellm_config
  choose_defaults
}

_up_data_services() { dc up -d --wait postgres rustfs && dc up -d rustfs-init; }
_build_and_up_mcp() {
  built_now shared-mcp || building "the shared-mcp image" dc build -q shared-mcp || return 1
  up_services --no-deps shared-mcp
}

# _build_and_up_front SERVICE... — the portal's image (and shared-mcp's, when listed) unless setup built them already,
# then the SERVICEs — Open WebUI, the portal, Caddy… — in one compose call (up_services: each starts as soon as what it
# depends on is up, Open WebUI and the portal side by side; recreated only where something changed). With their
# dependencies: Open WebUI waits for the buckets (rustfs-init) as before. Caddy reads its Caddyfile only at start (its
# admin API is off): config_sums recreates it when that changed. If Docker refuses to publish port 80 after all, falls
# back to 8800 once.
_build_and_up_front() {
  local out rc=0 b=() s
  ensure_portal_password_hash   # lib/settings.sh: the portal starts only with a hash that matches PORTAL_PASSWORD
  # (every Compose this version runs with, 2.24.4 or newer, reads it: only one ./stack setup and update stop for does not)
  compose_reads_contexts || warn "Docker Compose ${_BN_COMPOSE_VERSION:-(this one)} is older than 2.24.4, which $PRODUCT_NAME needs (./stack setup and ./stack update stop for it): the portal is built without its search's docs index (README and docs/ sections) — update Docker Compose"
  for s in portal shared-mcp; do case " $* " in *" $s "*) built_now "$s" || b+=("$s") ;; esac; done
  [ ${#b[@]} -eq 0 ] || building "the ${b[*]} image(s)" dc build -q "${b[@]}" || return 1
  out="$(up_services "$@" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  [ "$rc" -ne 0 ] || return 0
  # Only a refused port 80 (rootless/unprivileged engines) moves the portal — Caddy not running then, its port refused;
  # any other failure is reported.
  [ "$(portal_port)" = 80 ] && [ -z "$(dc ps -q --status running caddy 2>/dev/null)" ] &&
    printf '%s\n' "$out" | grep -qiE 'bind|privileged|port is already allocated|ports are not available' || return 1
  PORTAL_PORT_FELL_BACK=1
  set_env PORTAL_PORT "$PORTAL_FALLBACK_PORT"
  resolve_port PORTAL_PORT "$PORTAL_FALLBACK_PORT" caddy 8080
  save_portal_origin
  up_services "$@" && caddy_up   # the portal: its PORTAL_PORT changed too
}

# up_front SERVICE... — the portal phase of setup: Open WebUI, the portal and Caddy (and shared-mcp, when listed) with
# their new code, settings and Caddyfile, in one phase (Home's progress card: one step)
up_front() {
  local label="Open WebUI + portal" s
  for s in "$@"; do [ "$s" != shared-mcp ] || label="$label + shared-mcp"; done
  PORTAL_PORT_FELL_BACK=0
  run_phase "$label ($(portal_url))" "$*" _build_and_up_front "$@"
  [ "$PORTAL_PORT_FELL_BACK" = 0 ] || warn "Docker could not publish port 80 → using $(portal_port) for the portal (PORTAL_PORT): $(portal_url)"
}

# portal_session_or_die — a portal session for setup's Open WebUI calls (they go through Caddy like a browser).
portal_session_or_die() {
  portal_session_start || {
    portal_session_end
    die "could not sign in to the portal at $(portal_url) (HTTP ${PORTAL_LOGIN_CODE:-?}) — see ./stack logs portal and ./stack logs caddy"
  }
}

ensure_virtual_key() { # ensure_virtual_key ENV_KEY ALIAS BUDGET [ROUTES_JSON]
  # ROUTES_JSON (a JSON list of paths): the only LiteLLM routes the key may call, set on a new key and on every
  # run on an existing one (so older keys get it too); LiteLLM answers 403 to the rest.
  local envk="$1" alias="$2" budget="$3" routes="${4:-}" cur tmp code key soft
  valid_budget "$budget" || die "budget for $alias must be a number of USD, got '$budget' (see BUDGET_* in .env)"
  soft="$(soft_budget_of "$budget")"   # BUDGET_ALERT_PCT (default 80%): LiteLLM alerts there (ALERT_WEBHOOK_URL); only max_budget blocks
  cur="$(get_env "$envk")"
  if [ -n "$cur" ]; then
    # /key/info with the key itself as bearer (keeps the key out of URLs/argv).
    code="$(litellm_key_status "$cur")"
    case "$code" in
      200)
        # keep the key; sync max_budget + soft_budget (budget_duration untouched so the reset date stays put)
        tmp="$(mktemp)"
        code="$(litellm_api POST /key/update "{\"key\":\"$cur\",\"max_budget\":$budget,\"soft_budget\":$soft${routes:+,\"allowed_routes\":$routes}}" "$tmp")"
        [ "$code" = 200 ] || warn "could not update the budget of LiteLLM key '$alias' (HTTP $code): $(head -c 300 "$tmp")"
        rm -f "$tmp"
        log "kept existing LiteLLM key '$alias' (monthly budget \$$budget, resets on the date shown by ./stack costs)"
        return 0 ;;
      401 | 403 | 404) warn "LiteLLM key '$alias' in .env is no longer valid (HTTP $code) — creating a new one" ;;
      *) die "LiteLLM returned HTTP $code while checking key '$alias' — not creating a duplicate; see ./stack logs litellm" ;;
    esac
  fi
  tmp="$(mktemp)"
  code="$(litellm_api POST /key/generate "{\"key_alias\":\"$alias\",\"max_budget\":$budget,\"soft_budget\":$soft,\"budget_duration\":\"30d\"${routes:+,\"allowed_routes\":$routes}}" "$tmp")"
  [ "$code" = 200 ] || { head -c 500 "$tmp" >&2; rm -f "$tmp"; die "could not create LiteLLM key '$alias' (HTTP $code)"; }
  key="$(parse_virtual_key < "$tmp")" || { head -c 300 "$tmp" >&2; rm -f "$tmp"; die "unexpected /key/generate response for '$alias' (no sk- key found)"; }
  set_env "$envk" "$key"
  log "created LiteLLM key '$alias' (monthly budget \$$budget, resets on the date shown by ./stack costs)"
  rm -f "$tmp"
}

# Open WebUI publishes no port: setup reaches it through Caddy with a portal session ($PORTAL_JAR), exactly
# like the browser. Sign-in uses the trusted header Caddy adds for that session (the admin's email).
ensure_openwebui_api_key() {
  local cur tmp token key
  cur="$(get_env OPENWEBUI_API_KEY)"
  # Validity check on an endpoint shared-mcp really uses (v0.12 refuses API keys on /api/v1/auths/:
  # "A human session is required").
  if [ -n "$cur" ] && portal_curl_auth "$cur" chat /api/v1/knowledge/ -fsS -m 30 -o /dev/null 2>/dev/null; then
    log "kept existing Open WebUI API key"; return 0
  fi
  tmp="$(mktemp)"
  # In trusted-header mode Open WebUI ignores the password and signs in the header's user; the form still needs both fields.
  printf '{"email":"","password":""}' |
    portal_curl chat /api/v1/auths/signin -fsS -m 30 -o "$tmp" -H 'Content-Type: application/json' --data-binary @- ||
    { rm -f "$tmp"; die "could not sign in to Open WebUI through the portal as $(get_env OPENWEBUI_ADMIN_EMAIL) — see ./stack logs open-webui"; }
  token="$(json_get token < "$tmp")"
  [ -n "$token" ] || { rm -f "$tmp"; die "Open WebUI sign-in returned no token"; }
  portal_curl_auth "$token" chat /api/v1/auths/api_key -fsS -m 30 -X POST -o "$tmp" || { rm -f "$tmp"; die "could not create Open WebUI API key"; }
  key="$(json_get api_key < "$tmp")"; rm -f "$tmp"
  case "$key" in sk-?*) ;; *) die "unexpected Open WebUI API key response" ;; esac
  set_env OPENWEBUI_API_KEY "$key"
  log "created Open WebUI API key for shared-mcp"
}

setup_keys_and_ui() {
  local mcp_key
  timed_step "LiteLLM keys, Admin sign-in, voice service" _setup_litellm_keys
  # Open WebUI, the portal and Caddy in one compose call, and shared-mcp with them once it has Open WebUI's API key (setup
  # again, an update): compose starts each as soon as what it depends on is up — Open WebUI and the portal side by side
  mcp_key="$(get_env OPENWEBUI_API_KEY)"
  if [ -n "$mcp_key" ]; then up_front open-webui portal caddy shared-mcp; else up_front open-webui portal caddy; fi
  timed_step "Portal sign-in and Chat's API key" _setup_portal_signin
  # shared-mcp on its own when it had no key (a first setup), or its key was just made anew (its environment changed)
  [ -n "$mcp_key" ] && [ "$(get_env OPENWEBUI_API_KEY)" = "$mcp_key" ] || run_phase "shared-mcp" shared-mcp _build_and_up_mcp
  timed_step "Open WebUI syncs (models, prices, banner)" _setup_owui_syncs
}
# setup_keys_and_ui's own steps, each timed as one
_setup_litellm_keys() {
  log "creating LiteLLM virtual keys with monthly budgets"
  ensure_virtual_key LITELLM_KEY_CLAUDE_CODE claude-code "$(get_env BUDGET_CLAUDE_CODE)"
  ensure_virtual_key LITELLM_KEY_OPENWEBUI open-webui "$(get_env BUDGET_OPENWEBUI)"
  alert_pct_mark || true   # lib/settings.sh: all three keys alert at BUDGET_ALERT_PCT now
  setup_litellm_admin
  stt_setup_service   # lib/stt.sh: the stt container (Bedrock speech-to-text) before Open WebUI; never fatal
}
_setup_portal_signin() {
  ensure_portal_reachable   # lib/portal.sh: Docker Desktop forwarding the portal's port to the Caddy it replaced
  portal_session_or_die
  settings_reconcile   # lib/settings.sh: Chat's owner and the Admin sign-in match .env (a change cut short, a restore)
  ensure_openwebui_api_key
}
_setup_owui_syncs() {
  sync_openwebui_models
  openrouter_sync_owui   # optional; lib/openrouter.sh
  explabs_sync_owui      # optional; lib/explabs.sh
  stt_sync_owui          # optional; lib/stt.sh
  owui_install_cost_filter
  sync_budget_banner
  portal_session_end
}

# --- ./stack models ---

# models_recheck — re-runs the model probe (LiteLLM restarts with the full catalog), then recreates the
# services whose settings depend on the enabled models and refreshes the Open WebUI price descriptions.
models_recheck() {
  [ -f "$ENV_FILE" ] && [ -n "$(get_env LITELLM_MASTER_KEY)" ] || die "run ./stack setup first"
  stack_lock models   # lib/lock.sh: the model choices in .env are rewritten
  check_prereqs
  SETUP_REPROBE=1 setup_bringup_and_probe
  stt_after_probe   # lib/stt.sh: Voxtral may have become usable (or not)
  stt_setup_service
  ensure_portal_password_hash
  run_phase "Open WebUI + shared-mcp + portal" "open-webui shared-mcp portal" dc up -d --wait open-webui shared-mcp portal
  portal_session_or_die
  sync_openwebui_models
  openrouter_sync_owui   # optional; lib/openrouter.sh
  explabs_sync_owui      # optional; lib/explabs.sh
  stt_sync_owui          # lib/stt.sh
  owui_install_cost_filter
  portal_session_end
}

cmd_models() {
  local f="$STACK_DIR/litellm/probe-results.tsv" ts bad
  case "${1:-}" in
    --recheck) models_recheck; return ;;
    browse) shift; cmd_models_browse "$@"; return ;;   # the model browser's lists (lib/model_browser.sh)
    '') ;;
    *) die "usage: ./stack models [--recheck | browse [--refresh]]" ;;
  esac
  [ -s "$f" ] || die "no saved model check yet — run ./stack models --recheck (or ./stack setup)"
  ts="$(awk -F'\t' '!/^#/ && NF >= 6 { print $6; exit }' "$f")"
  bad="$(awk -F'\t' '!/^#/ && NF > 0 && NF < 6' "$f" | wc -l | tr -d ' ')"
  [ "$bad" -eq 0 ] || warn "$f looks corrupt ($bad incomplete line(s) skipped) — run ./stack models --recheck"
  printf 'Model access for your AWS key, as checked %s (no Bedrock calls; ./stack models --recheck re-checks, < $0.01)\n\n' "${ts:-at the last setup}"
  awk -F'\t' '/^#/ || NF >= 6' "$f" | models_table
  printf '\n  Prices: %s (the PRICE column shows them)\n' "$(prices_source_text)"
  prices_notes
  openrouter_models_section
  explabs_models_section
}

# --- cost transparency ---

# What Home's Equivalent cost view means (portal/portal/static/app.js says the same; README, docs/openrouter.md)
COST_EQUIVALENT_TEXT="Equivalent: what the same usage would have cost with no free tiers: free OpenRouter and Experiential Labs models priced at their paid versions. Everything else is already at its real price."

_enabled_or_all() { # -> path of enabled-models.txt, or "" (= whole catalog) if setup hasn't probed yet
  local en="$STACK_DIR/litellm/enabled-models.txt"
  if [ -s "$en" ]; then echo "$en"; else echo ""; fi
}

cmd_costs() {
  local en name _ mregion cr age j reset label envk alias tmp total code bw
  [ -f "$ENV_FILE" ] || die "run ./stack setup first"
  en="$(_enabled_or_all)"
  printf 'Bedrock on-demand prices (USD) as of %s — https://aws.amazon.com/bedrock/pricing/\n' "$(prices_as_of)"
  printf '  Source: %s\n' "$(prices_source_text)"
  prices_notes
  [ -n "$en" ] || printf '  (setup has not probed your AWS key yet, so this lists the whole catalog)\n'
  printf '  %-20s %s\n' MODEL PRICE
  while IFS=$'\t' read -r name _ _ _ mregion <&3; do
    is_enabled "$name" "$en" || continue
    label="$(price_label "$name")"; cr="$(price_field "$name" cache_read)"
    [ -z "$cr" ] || label="$label   (cache read $(money "$cr"))"
    case "$mregion" in '' | -) ;; *) label="$label   [$mregion]" ;; esac
    printf '  %-20s %s\n' "$name" "$label"
  done 3< <(catalog_rows)
  printf '\nSpend this budget period (monthly budget per key; each resets on the date shown)\n'
  # + the browser terminal's own key (claude-code-terminal, shown as "terminal") once ./stack terminal made one
  for alias in claude-code open-webui setup $([ -z "$(get_env LITELLM_KEY_TERMINAL)" ] || echo terminal); do
    case "$alias" in claude-code) envk=LITELLM_KEY_CLAUDE_CODE ;; open-webui) envk=LITELLM_KEY_OPENWEBUI ;; terminal) envk=LITELLM_KEY_TERMINAL ;; *) envk=LITELLM_KEY_SETUP ;; esac
    if [ -z "$(get_env "$envk")" ]; then printf '  %-12s no key yet — run ./stack setup\n' "$alias"; continue; fi
    if ! j="$(key_info "$(get_env "$envk")")" || ! label="$(printf '%s' "$j" | spend_text)"; then
      printf '  %-12s unavailable — LiteLLM did not answer (is the stack up? ./stack status)\n' "$alias"; continue
    fi
    reset="$(printf '%s' "$j" | json_get budget_reset_at | cut -c1-10)"
    bw="$(printf '%s' "$j" | budget_warning)" || bw=''
    printf '  %-12s %s%s%s\n' "$alias" "$label" "${reset:+   (resets $reset)}" "${bw:+   $bw}"
  done
  # /global/spend sums LiteLLM's spend log over the last 30 days: every key, including master-key calls.
  tmp="$(mktemp)"
  code="$(litellm_api GET /global/spend "" "$tmp")"
  case "$code" in
    200) total="$(json_num spend < "$tmp")"   # null (no spend logged yet) -> $0.00
         printf '  Total (all keys, last 30 days): %s\n' "$(usd "${total:-0}")" ;;
    000 | '') printf '  Total (all keys, last 30 days): unavailable — LiteLLM did not answer (is the stack up? ./stack status)\n' ;;
    *) printf '  Total (all keys, last 30 days): unavailable (HTTP %s)\n' "$code" ;;
  esac
  rm -f "$tmp"
  openrouter_costs_section
  explabs_costs_section
  if openrouter_enabled || explabs_enabled; then
    printf '\n%s\n  (the "≈ … at paid rates" figures above; Home'"'"'s Spend card switches between Actual and Equivalent)\n' "$COST_EQUIVALENT_TEXT"
  fi
  stt_costs_section
  printf '\nBreakdown by model and day: %s/ui → Usage (portal Admin tab; its sign-in is on the portal Home page)\n' "$(portal_url admin)"
  printf 'Budgets: Settings in the portal, or ./stack config set BUDGET_CLAUDE_CODE (BUDGET_OPENWEBUI, BUDGET_SETUP%s)\n' \
    "$([ -z "$(get_env LITELLM_KEY_TERMINAL)" ] || echo ', BUDGET_TERMINAL')"
  printf 'Alerts at %s%%: Settings → Spending & budgets, or ./stack config set ALERT_WEBHOOK_URL (%s)\n' "$(alert_pct)" \
    "$([ -n "$(get_env ALERT_WEBHOOK_URL)" ] && echo 'webhook set' || echo 'none set')"
  [ "$PRICES_SOURCE" = catalog ] || return 0   # the daily update keeps them current (and says so above when it fails)
  age="$(prices_age_days)"
  if [ -z "$age" ]; then warn "catalog/prices.tsv has no '# as_of:' date — prices may be stale"
  elif [ "$age" -gt 90 ]; then warn "prices are $age days old — check https://aws.amazon.com/bedrock/pricing/ and update catalog/prices.tsv"; fi
}

# Open WebUI model names/prices, the cost filter and budget banners: lib/owui.sh

# The portal password is printed once: by the first summary after setup generated it (first setup, or the first
# setup after an update from v0.1.x); afterwards the summary points at .env so re-runs and updates don't leave
# it in scrollback/logs. The LiteLLM and RustFS sign-ins are on the portal's Home page (copy buttons).
print_summary() {
  local login cb haiku O_RED O_GRN O_YEL O_OFF
  out_colors
  # Shown once, and only to a terminal: a CI or script log never captures it (and it stays unshown until then).
  if [ ! -e "$STATE_DIR/portal-password-shown" ] && [ -n "$(get_env PORTAL_PASSWORD)" ] && _stdout_tty; then
    login="password $(get_env PORTAL_PASSWORD)   (shown once; also PORTAL_PASSWORD in .env)"
    mkdir -p "$STATE_DIR" && : > "$STATE_DIR/portal-password-shown"
  else
    login="password: PORTAL_PASSWORD in $(env_file_display)   (./stack password --show)"
  fi
  cb="$(devos_claude_cmd)"; haiku="$(get_env CLAUDE_BEDROCK_HAIKU_MODEL)"
  cat <<SUMMARY

  ${O_GRN}$PRODUCT_NAME is up.${O_OFF}

  Portal          $(portal_url)   $login
                  Home, Chat (Open WebUI), Admin (LiteLLM) and Files (RustFS) behind one login
  Claude Code     $cb   (plain \`claude\` is unchanged)
SUMMARY
  [ -z "$haiku" ] || printf '  Try it          CLAUDE_BEDROCK_MODEL=%s %s -p "Say hello in five words"   (~$0.02)\n' "$haiku" "$cb"
  cat <<SUMMARY
  LiteLLM API     http://127.0.0.1:$(get_env LITELLM_PORT)   (for tools; keys in .env)
  Costs           ./stack costs             (Bedrock prices as of $(prices_as_of) + spend per key)
  Models          ./stack models            (which models your AWS key can use)
SUMMARY
  openrouter_summary_line
  explabs_summary_line
  stt_summary_line
  websearch_summary_line
  localgit_summary_line
  terminal_summary_line
  code_summary_line
  remote_summary_line
  printf '\n  All credentials live in .env (mode 600).\n'
}

# devos_claude_cmd -> "devos-claude" when that name on PATH runs this checkout's wrapper, else its
# absolute path (shell-quoted), so the summary always shows a command that works as typed.
devos_claude_cmd() {
  local want="$STACK_DIR/bin/devos-claude" found
  found="$(command -v devos-claude 2>/dev/null || true)"
  if [ -n "$found" ] && { [ "$found" = "$want" ] || [ "$(readlink "$found" 2>/dev/null)" = "$want" ]; }; then
    echo devos-claude
  else
    printf '%q\n' "$want"
  fi
}

# --- Claude Code: MCP config for devos-claude + optional symlink ---

write_mcp_config() {
  local f="$STATE_DIR/mcp.json" tmp port token
  port="$(get_env SHARED_MCP_PORT)"; token="$(get_env SHARED_MCP_TOKEN)"
  [ -n "$port" ] && [ -n "$token" ] || die "cannot write $f: SHARED_MCP_PORT/SHARED_MCP_TOKEN missing from $ENV_FILE — re-run ./stack setup"
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  tmp="$(mktemp "$f.XXXXXX")"; chmod 600 "$tmp"
  printf '{"mcpServers":{"bedrock-shared":{"type":"http","url":"http://127.0.0.1:%s/mcp","headers":{"Authorization":"Bearer %s"}}}}\n' \
    "$port" "$token" > "$tmp"
  mv "$tmp" "$f"
}

# offer_symlink — devos-claude on your PATH: ~/.local/bin/devos-claude, a link to this checkout's bin/devos-claude, and
# beside it ~/.local/bin/claude-bedrock (claude-bedrock, its name before v0.28.0): a link to bin/claude-bedrock, a shim
# that runs devos-claude with the same arguments (docs/internal-names.md). Interactive runs ask first. --yes (./stack
# update) creates the devos-claude link only for an install whose ~/.local/bin/claude-bedrock links here (v0.27.x and
# earlier, where the update's checkout has just made that file the shim), and never replaces a link to a different
# checkout or a file: that one is replaced only after an explicit "y".
offer_symlink() {
  local target="$HOME/.local/bin/devos-claude" want="$STACK_DIR/bin/devos-claude" cur old_cur
  cur="$(readlink "$target" 2>/dev/null || true)"
  old_cur="$(readlink "$HOME/.local/bin/claude-bedrock" 2>/dev/null || true)"
  [ "$cur" = "$want" ] && { _link_old_name; return 0; }
  if [ "${ASSUME_YES:-0}" = 1 ] || ! _have_tty; then
    if [ "$old_cur" = "$STACK_DIR/bin/claude-bedrock" ] && [ ! -e "$target" ] && [ ! -L "$target" ]; then
      if ln -s "$want" "$target" 2>/dev/null; then log "linked $target (formerly claude-bedrock, which keeps working: it runs devos-claude now)"
      else warn "could not link $target (to put devos-claude on your PATH: ln -s $want $target)"; fi
    elif [ -n "$cur" ]; then log "left $target alone (it points to $cur)"
    else log "to put devos-claude on your PATH: ln -s $want $target"; fi
    return 0
  fi
  [ -e "$target" ] && ! [ -L "$target" ] && { warn "$target exists and is not a symlink; not touching it"; return 0; }
  if [ -n "$cur" ]; then
    case "$(ask "$target points to $cur (another checkout) — replace it with this one? [y/N]" "n")" in
      [Yy]*) ;; *) log "kept $target → $cur"; return 0 ;;
    esac
  elif ! confirm "Link devos-claude into ~/.local/bin?"; then
    return 0
  fi
  # (a link that cannot be made is a warning: setup and the update go on to their next steps)
  if ! { mkdir -p "$HOME/.local/bin" && ln -sfn "$want" "$target"; } 2>/dev/null; then
    warn "could not link $target (to put devos-claude on your PATH: ln -s $want $target)"
    return 0
  fi
  log "linked $target"
  _link_old_name
  # shellcheck disable=SC2088  # literal ~ in a message
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "~/.local/bin is not on your PATH; add it yourself (setup won't edit shell rc files)" ;; esac
}

# _link_old_name — next to a devos-claude link to this checkout: ~/.local/bin/claude-bedrock, a link to this checkout's
# shim (bin/claude-bedrock), made when nothing has that name. A link to another checkout or a file of yours stays.
_link_old_name() {
  local old="$HOME/.local/bin/claude-bedrock" shim="$STACK_DIR/bin/claude-bedrock" cur
  [ -f "$shim" ] || return 0
  cur="$(readlink "$old" 2>/dev/null || true)"
  [ "$cur" = "$shim" ] && return 0
  # a broken link into an earlier checkout's bin/claude-bedrock (that checkout removed): this checkout's shim replaces it
  if [ -L "$old" ] && [ ! -e "$old" ]; then
    case "$cur" in
      */bin/claude-bedrock)
        if ln -sfn "$shim" "$old" 2>/dev/null; then log "linked $old (it pointed to $cur, which is gone; it runs devos-claude now)"
        else warn "could not link $old (it points to $cur, which is gone)"; fi
        return 0 ;;
    esac
  fi
  if [ -e "$old" ] || [ -L "$old" ]; then
    if [ -n "$cur" ]; then log "left $old alone (it points to $cur); devos-claude is its new name"
    else log "left $old alone (not a link); devos-claude is its new name"; fi
    return 0
  fi
  if ln -s "$shim" "$old" 2>/dev/null; then log "linked $old (devos-claude's name before v0.28.0: it runs devos-claude)"
  else warn "could not link $old, devos-claude's name before v0.28.0 (devos-claude is linked)"; fi
}

# --- day-2 commands ---

cmd_up() {
  local repriced=0 restart=0 before own=1
  local extra; extra="$(optional_services)"
  local STACK_SERVICES="$STACK_BASE_SERVICES${extra:+ $extra}"   # + stt / terminal while .env turns them on
  [ -f "$ENV_FILE" ] || die "run ./stack setup first"
  # lib/lock.sh: never while a settings change, setup, update or restore writes .env. Released when up returns (not at
  # exit): ./stack serve goes on keeping the machine awake for hours, and must not block everything else meanwhile.
  ! stack_lock_ours || own=0   # (setup, restore and update call up holding the lock: theirs to release)
  stack_lock up
  aws_auth_check   # lib/host.sh: a key in .env, or the instance role on EC2
  check_portal_host "$(portal_host)"
  if remote_on; then remote_ensure_proxy_secret; remote_net_preflight; fi   # lib/remote.sh: before any compose call
  terminal_up_hook     # lib/terminal.sh: its remote name, and a missing workspace folder said out loud
  code_up_hook         # lib/code.sh: its remote name and secret; left out (said) while the terminal is
  projects_up_hook     # lib/projects.sh: the project folders' mounts, each folder checked again (one left out: said)
  save_portal_origin   # Caddy's frame-ancestors follows PORTAL_HOST / PORTAL_PORT edited by hand in .env
  ensure_portal_password_hash   # lib/settings.sh: PORTAL_PASSWORD edited by hand gets a new hash
  owner_email_lowercase         # lib/settings.sh: as Chat keeps it
  settings_pending_check        # a settings change cut short: reconciled below
  ensure_portal_dirs; write_version_file   # lib/version.sh
  ensure_images "./stack up"
  owui_build || die "could not build Open WebUI's image — run ./stack up again and read its output"
  # Prices (lib/prices.sh): refresh if the last check is older than 12 h (fast: LiteLLM's list only, at most
  # 20 s; the portal's daily run does the AWS cross-check). OpenRouter's hook comes next: when its models
  # changed it re-renders (with these prices) and recreates LiteLLM itself, so reprice_litellm_config then finds
  # nothing to change. Otherwise a running LiteLLM is recreated once here, before the rest comes up.
  refresh_prices 12 --no-crosscheck --timeout 20
  # The prices the running config carries, before OpenRouter's hook: if the hook re-renders with newer prices
  # (the portal's daily job updated them), Bedrock's descriptions/tiers must re-sync too (repriced, no restart).
  before="$(config_prices_line)"
  openrouter_up_hook   # optional; refreshes OpenRouter models/prices when a key is set
  explabs_up_hook      # optional; lib/explabs.sh: Experiential Labs' model details when a key is set (12 h)
  [ "$(config_prices_line)" = "$before" ] || repriced=1
  # lib/stt.sh: STT_* edited by hand in .env — re-renders, and a running LiteLLM must pick the change up
  if stt_up_hook && [ -n "$(dc ps -q --status running litellm 2>/dev/null)" ]; then restart=1; fi
  if reprice_litellm_config; then
    repriced=1
    [ -z "$(dc ps -q --status running litellm 2>/dev/null)" ] || restart=1
  fi
  # lib/websearch.sh: WEBSEARCH_* edited by hand in .env (the built-in SearXNG turned off, a key added): LiteLLM's search
  # tool follows, and a running LiteLLM picks it up
  if websearch_config_stale; then
    render_config "$(_enabled_or_all)"
    [ -z "$(dc ps -q --status running litellm 2>/dev/null)" ] || restart=1
  fi
  if [ "$restart" = 1 ]; then
    log "restarting LiteLLM so it uses the new configuration from .env and the price list (~30 s; requests in flight may fail)"
    run_phase "LiteLLM (new configuration)" litellm dc up -d --no-deps --force-recreate --wait litellm
  fi
  stt_before_up   # lib/stt.sh: removes a stt container left from Bedrock speech-to-text
  # lib/websearch.sh: the built-in SearXNG's settings before compose starts it (a changed file recreates it); turned off
  # (WEBSEARCH_SEARXNG_BUILTIN=off by hand in .env), its container goes
  websearch_searxng_write
  if websearch_builtin_on; then ensure_env WEBSEARCH_SEARXNG_SECRET "$(gen_hex 32)"; else websearch_builtin_down; fi
  # lib/localgit.sh: the git server's secret and certificate before compose starts it; turned off by hand in .env, its container goes
  if localgit_on; then localgit_secrets; localgit_tls_ensure || true; else localgit_remove; fi
  # The stack's own services only: the Tailscale sidecar (remote access) is started afterwards without waiting.
  # shellcheck disable=SC2086  # word-split the service list on purpose
  run_phase "$PRODUCT_NAME" "$STACK_SERVICES" dc up -d --wait $STACK_SERVICES
  # lib/stt.sh: Bedrock refusing audio turns Bedrock speech-to-text off once (the notice); the list follows
  stt_up_check; extra="$(optional_services)"; STACK_SERVICES="$STACK_BASE_SERVICES${extra:+ $extra}"
  # lib/websearch.sh: a search backend changed while the stack was stopped is checked now (one search, on the setup key)
  [ ! -f "$STACK_DIR/litellm/config.yaml" ] || { websearch_search_check; websearch_write_json; }
  terminal_after_up   # TERMINAL_EGRESS: what its way out no longer uses goes once the container has left it
  localgit_after_up   # lib/localgit.sh: the git server's owner account and the Code page's host for it (both up now); never fatal
  runtimes_up_hook    # lib/runtimes.sh: the installed runtimes' launchd agents (macOS; Linux's are containers above); never fatal
  localgit_mirror_reconcile   # lib/localgit.sh: the git server's way out follows the mirrors it really has; never fatal
  remote_up_hook
  ensure_portal_reachable   # lib/portal.sh: Docker Desktop forwarding the portal's port to a Caddy it replaced
  # Open WebUI keeps banners in memory only: re-apply the budget banner (through the portal, like setup).
  # The same session updates Open WebUI's prices once: after Bedrock price changes, on_prices_changed (cost
  # filter, which also carries OpenRouter's prices, and model descriptions) plus OpenRouter's label sync if
  # its models changed too; after OpenRouter changes alone, openrouter_after_up.
  if portal_session_start; then
    settings_reconcile; budget_sync_quiet   # lib/settings.sh: sign-ins, budgets and alert thresholds as .env says
    # lib/owui.sh: MODELS_HIDDEN changed while the stack was stopped (one call per model: only when it changed)
    [ "$(models_hidden_applied)" = "$(get_env MODELS_HIDDEN)" ] || owui_apply_hidden
    sync_budget_banner
    stt_after_up   # lib/stt.sh: hides the speech-to-text model after ./stack stt set while stopped
    if [ "$PRICES_CHANGED" = 1 ] || [ "$repriced" = 1 ]; then
      on_prices_changed
      [ "${OR_UP_CHANGED:-0}" != 1 ] || ! declare -F openrouter_sync_owui >/dev/null || openrouter_sync_owui || true
      [ "${XL_UP_CHANGED:-0}" != 1 ] || explabs_sync_owui || true
    else
      openrouter_after_up
      explabs_after_up   # lib/explabs.sh: names, tags and the cost line's prices when its models changed
    fi
  else
    warn "could not sign in to the portal — budget banner and Open WebUI prices not refreshed"
  fi
  portal_session_end
  [ "$own" = 0 ] || stack_unlock
  cmd_status
  maybe_auto_open
}
cmd_down()   { ! declare -F xl_bg_stop >/dev/null || xl_bg_stop; dc down; runtimes_down_hook; }   # (lib/explabs.sh: its background read stops too; lib/runtimes.sh: the runtimes' agents)
cmd_logs() {
  # (the built-in SearXNG while it is off: no container, so nothing to follow — said, not Compose's "no such service")
  case " $* " in *" forgejo "*) localgit_on ||
    die "the built-in git server is off (LOCALGIT=off): no container, no logs — ./stack config set LOCALGIT on turns it on" ;; esac
  case " $* " in *" searxng "*) websearch_builtin_on ||
    die "the built-in SearXNG is off (WEBSEARCH_SEARXNG_BUILTIN=off): no container, no logs — ./stack config set WEBSEARCH_SEARXNG_BUILTIN on turns it on" ;; esac
  dc logs -f --tail=200 "$@"
}
status_url() { # status_url SERVICE -> where to open it (browser UIs: through the portal)
  case "$1" in
    portal) echo "$(portal_url)   (Home: one login for all)" ;;
    caddy) echo "- (serves the portal URLs)" ;;
    open-webui) portal_url chat ;;
    litellm) echo "$(portal_url admin)/ui" ;;
    rustfs) portal_url files ;;
    shared-mcp) echo "http://127.0.0.1:$(get_env SHARED_MCP_PORT)/mcp" ;;
    tailscale) if [ -n "$(remote_url)" ]; then echo "$(remote_url)   (your devices; ./stack remote status)"; else echo "- (./stack remote status)"; fi ;;
    terminal) echo "$(portal_url terminal)   (the Terminal tab; ./stack terminal status)" ;;
    terminal-gateway) echo "- (the terminal's only way into the stack)" ;;
    terminal-egress) echo "- (the terminal's way out: public internet addresses only)" ;;
    chat-egress) echo "- (Chat's way out while the terminal's is direct: public internet addresses only)" ;;
    code) echo "$(portal_url code)   (the Code tab; ./stack code status)" ;;
    searxng) echo "- (the built-in web search, LiteLLM's alone)" ;;
    forgejo) echo "$(portal_url git)   (the built-in git server)" ;;
    ollama) echo "- (local models: LiteLLM's alone; ./stack runtimes status)" ;;
    ollama-gate) echo "http://127.0.0.1:11434   (Ollama's API, for this computer's loopback names only)" ;;
    *) echo "- (internal only)" ;;
  esac
}

# status_table < "service<TAB>state<TAB>health<TAB>exit code" lines (dc ps -a --format) -> SERVICE STATE HEALTH URL
# (the SERVICE column as wide as the longest name listed, at least 11: terminal-gateway is 16)
status_table() {
  local ps s row state health sc hc w=11 O_RED O_GRN O_YEL O_OFF
  local extra; extra="$(optional_services)"
  local STACK_SERVICES="$STACK_BASE_SERVICES${extra:+ $extra}"
  out_colors
  ps="$(cat)"
  STACK_SERVICES="$STACK_SERVICES $(remote_on && echo tailscale || true)"
  for s in $STACK_SERVICES; do [ "${#s}" -le "$w" ] || w="${#s}"; done
  printf '  %-*s %-12s %-10s %s\n' "$w" SERVICE STATE HEALTH URL
  for s in $STACK_SERVICES; do
    row="$(printf '%s\n' "$ps" | awk -F'\t' -v s="$s" '!f && $1 == s { print $2 "\t" $3; f = 1 }')"
    state="${row%%	*}"; health="${row#*	}"
    [ -n "$row" ] || { state="not created"; health=''; }
    [ -n "$health" ] || health='-'
    sc="$O_RED"; [ "$state" = running ] && sc="$O_GRN"
    case "$health" in healthy) hc="$O_GRN" ;; unhealthy) hc="$O_RED" ;; -) hc='' ;; *) hc="$O_YEL" ;; esac
    printf '  %-*s %s%-12s%s %s%-10s%s %s\n' "$w" "$s" "$sc" "$state" "$O_OFF" "$hc" "$health" "$O_OFF" "$(status_url "$s")"
  done
  row="$(printf '%s\n' "$ps" | awk -F'\t' '$1 == "rustfs-init" && $4 != "" && $4 != "0" { print $4 }')"
  [ -z "$row" ] || warn "bucket setup (rustfs-init) exited with code $row — see ./stack logs rustfs-init"
}

# services_status_file -> .state/status/services.json: ./stack's record of its containers, for the portal (read-only)
services_status_file() { printf '%s/services.json\n' "$(status_dir)"; }
SERVICES_STATUS_EVERY_S=60   # the update helper rewrites it at most this often (services_status_tick)
# services_status_write [PS] — services.json: each service ./stack status lists (the optional ones only while .env turns
# them on: no searxng while WEBSEARCH_SEARXNG_BUILTIN=off), its state and health as Docker Compose has them, and when.
# Home's Services take the built-in SearXNG's from there (portal/summary.py): the portal shares no network with it and
# Caddy has no route to it (compose.yaml), so the portal cannot ask SearXNG itself. PS: `dc ps -a --format` lines
# (service<TAB>state<TAB>health…), else asked here; a Docker that does not answer writes nothing. Never fatal.
services_status_write() {
  local d f tmp ps s row state health out='' extra
  [ -f "$ENV_FILE" ] || return 0
  if [ $# -gt 0 ]; then ps="$1"
  else ps="$(dc ps -a --format '{{.Service}}	{{.State}}	{{.Health}}' 2>/dev/null)" || return 0; fi
  d="$(status_dir)"; mkdir -p "$d" 2>/dev/null || return 0
  f="$(services_status_file)"
  extra="$(optional_services 2>/dev/null || true)"
  for s in $STACK_BASE_SERVICES $extra; do
    row="$(printf '%s\n' "$ps" | awk -F'\t' -v s="$s" '!f && $1 == s { print $2 "\t" $3; f = 1 }')"
    state="${row%%	*}"; health="${row#*	}"
    [ -n "$row" ] || { state="not created"; health=''; }
    # (Docker's own words — running, exited, healthy, starting …: lowercase letters, spaces and dashes only)
    state="$(printf '%s' "$state" | LC_ALL=C tr -cd 'a-z -' | cut -c1-24)"
    health="$(printf '%s' "$health" | LC_ALL=C tr -cd 'a-z -' | cut -c1-24)"
    out="$out${out:+, }{\"service\": \"$s\", \"state\": \"$state\", \"health\": \"$health\"}"
  done
  tmp="$(mktemp "$d/.services.XXXXXX" 2>/dev/null)" || return 0
  { printf '{"version": 1, "written_at": %s, "services": [%s]}\n' "$(date +%s)" "$out" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$f"; } 2>/dev/null ||
    rm -f "$tmp"
  ! declare -F health_record_write >/dev/null || health_record_write || true   # lib/health.sh: restarts, exit codes, unhealthy (local)
  return 0
}
# services_status_tick — the update helper, every loop: the record ./stack keeps (setup, up and status write it)
# again once it is SERVICES_STATUS_EVERY_S old, so Home's Services follow a container that stops or turns unhealthy
# between ./stack commands; no record yet, nothing (the stack was never set up or started here). Never fatal.
services_status_tick() {
  local at now
  at="$(sed -n 's/^{"version": 1, "written_at": \([0-9]*\),.*/\1/p' "$(services_status_file)" 2>/dev/null | head -n 1 || true)"
  [ -n "$at" ] || return 0
  now="$(date +%s)"
  if [ "$at" -le "$now" ] && [ $((now - at)) -lt "$SERVICES_STATUS_EVERY_S" ]; then return 0; fi
  services_status_write
  ! declare -F runtimes_watch >/dev/null || runtimes_watch || true   # lib/runtimes.sh: a runtime that ended, stopped answering or answers again
}

# shellcheck disable=SC2120  # arguments come from the ./stack dispatcher
cmd_status() {
  local ps upd py xl vl fresh='' O_RED O_GRN O_YEL O_OFF
  case "${1:-}" in '') ;; --disk) fresh=--fresh ;; *) die "usage: ./stack status [--disk]   (--disk: measure disk use now)" ;; esac
  out_colors
  check_docker_daemon   # a stopped daemon would otherwise look like "not created" everywhere
  ps="$(dc ps -a --format '{{.Service}}	{{.State}}	{{.Health}}	{{.ExitCode}}' 2>/dev/null || true)"
  printf '%s\n' "$ps" | status_table
  services_status_write "$ps"   # (the same answer, for Home's Services)
  if ! printf '%s\n' "$ps" | grep -q '	running	'; then
    printf '\n  The stack is not running — start it with ./stack up\n'
  else
    printf '\n  Open %s (one login: PORTAL_PASSWORD in .env)   LiteLLM API: http://127.0.0.1:%s\n' "$(portal_url)" "$(get_env LITELLM_PORT)"
    printf '  Logs: ./stack logs <service>   Costs: ./stack costs   Models: ./stack models\n'
    ! remote_on || printf '  Remote: %s   (./stack remote status)\n' "$(remote_url || true)"
  fi
  printf '  %s\n' "$(disk_line_cached $fresh)"   # names ./stack clean when it would free something
  if update_unfinished; then   # lib/rollback.sh: its pull or setup failed, or it was stopped
    printf '  %sThe last update did not finish — ./stack update finishes it, ./stack rollback goes back%s\n' "$O_YEL" "$O_OFF"
  elif upd="$(update_available)"; then
    printf '  %sUpdate available: %s%s (you have %s) — ./stack update   (release notes on Home)\n' "$O_YEL" "$upd" "$O_OFF" "$(installed_version)"
  fi
  printf '  %s\n' "$(helper_status_line)"   # lib/helper.sh: one-click and automatic updates
  vl="$(versions_status_line 2>/dev/null || true)"; [ -z "$vl" ] || printf '  %s\n' "$vl"   # lib/versions.sh
  write_versions_json 2>/dev/null || true   # (Settings' Core services)
  py="$(python_runner_line)"; [ -z "$py" ] || printf '  %s\n' "$py"   # lib/owui.sh: what Chat's Python runner can import
  # lib/explabs.sh: its models, and when they run without model details (fail safe: no sampling parameters)
  xl="$(explabs_status_line)"; [ -z "$xl" ] || printf '  %s\n' "$xl"
  [ ! -f "$ENV_FILE" ] || printf '  %s\n' "$(websearch_status_line)"   # lib/websearch.sh: Claude Code's WebSearch
  [ ! -f "$ENV_FILE" ] || localgit_status_line   # lib/localgit.sh: the built-in git server
  # lib/stt.sh: Bedrock speech-to-text turned off because AWS refuses its audio — said until a voice choice is made
  ! stt_notice_on || printf '  %sVoice: %s%s\n' "$O_YEL" "$STT_REFUSED_NOTICE" "$O_OFF"
}

_check() { # _check LABEL GOT WANT — uses the caller's `fails` counter. GOT is what a check read (often what a
  # container — the sandbox among them — answered): shown as printable ASCII only, at most 160 characters, quoted
  # apart («…»), never as this computer's own words or controls; the helper's job message takes the label alone
  local got
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; return 0; fi
  got="$(printf '%s' "${2:-nothing}" | LC_ALL=C tr -c ' -~' ' ' | cut -c1-160)"
  printf '  FAIL  %s (got «%s», want %s)\n' "$1" "$got" "$3"; fails=$((fails + 1))
}
_skip() { printf '  skip  %s (%s)\n' "$1" "$2"; }

# _hdr NAME < curl -D headers -> the value of header NAME (case-insensitive; CR stripped; empty if absent)
_hdr() { tr -d '\r' | N="$1" awk -F': ' '!f && tolower($1) == tolower(ENVIRON["N"]) { sub(/^[^:]*: /, ""); print; f = 1 }'; }

# _test_portal — the browser path: Caddy + portal login + the three apps behind it (uses cmd_test's `fails`).
# Open WebUI publishes no port, so its checks go through Caddy too. The session cookie lives in a mode-600 file
# in .state/ and is deleted at the end.
_test_portal() {
  local code hdr loc csp origin opus
  origin="$(portal_url)"; opus="$(get_env CLAUDE_BEDROCK_OPUS_MODEL)"; hdr="$(mktemp)"
  # shellcheck disable=SC2034  # read by portal_curl (lib/portal.sh)
  PORTAL_JAR=''
  code="$(portal_curl '' /login -s -m 10 -o /dev/null -w '%{http_code}' || true)"
  _check "portal login page ($origin)" "$code" 200
  code="$(portal_curl chat / -s -m 10 -o /dev/null -D "$hdr" -w '%{http_code}' -H 'Accept: text/html' || true)"
  loc="$(_hdr location < "$hdr")"
  _check "chat without a session → login" "$code ${loc%%\?*}" "302 $origin/login"
  code="$(portal_curl chat /api/v1/auths/signin -s -m 10 -o /dev/null -w '%{http_code}' -H 'X-Portal-User: '"$(get_env OPENWEBUI_ADMIN_EMAIL)" \
    -H 'Content-Type: application/json' -d '{"email":"","password":""}' || true)"
  _check "spoofed X-Portal-User without a session is refused" "$code" 401
  code="$(portal_curl nope / -s -m 10 -o /dev/null -w '%{http_code}' || true)"
  _check "unknown host name is refused" "$code" 404
  # Chat's one public route (Caddyfile chat_runtime: Open WebUI's Python runner's static files), and only it
  code="$(portal_curl chat /pyodide/pyodide.js -s -m 10 -o /dev/null -D "$hdr" -w '%{http_code}' -H 'Origin: null' || true)"
  _check "chat's Python runner files without a session (/pyodide/)" "$code $(_hdr access-control-allow-origin < "$hdr")" "200 *"
  code="$(portal_curl chat /pyodide/a/b.js -s -m 10 -o /dev/null -w '%{http_code}' -H 'Accept: application/json' || true)"
  _check "anything else under /pyodide/ needs a session" "$code" 401
  if ! portal_session_start; then
    _check "portal login (PORTAL_PASSWORD)" "${PORTAL_LOGIN_CODE:-}" 303
    _skip "checks behind the portal login" "login failed"
    portal_session_end; rm -f "$hdr"; return 0
  fi
  _check "portal login (PORTAL_PASSWORD)" 303 303
  code="$(portal_curl '' /login?next=http://evil.example/ -s -m 10 -o /dev/null -D "$hdr" -w '%{http_code}' || true)"
  _check "login refuses a foreign next= (no open redirect)" "$code $(_hdr location < "$hdr")" "303 /"
  code="$(portal_curl '' /api/summary -s -m 30 -o /dev/null -w '%{http_code}' -H 'X-Requested-With: bedrock-now' || true)"
  _check "portal Home data (/api/summary)" "$code" 200
  code="$(portal_curl chat /health -s -m 10 -o /dev/null -w '%{http_code}' || true)"
  _check "open-webui health (chat.)" "$code" 200
  if [ -n "$opus" ]; then
    code="$(portal_curl_auth "$(get_env OPENWEBUI_API_KEY)" chat /api/models -s -m 60 2>/dev/null | grep -c "\"$opus\"" || true)"
    _check "open-webui sees litellm models" "$([ "${code:-0}" -gt 0 ] && echo yes || echo no)" yes
  else
    _skip "open-webui sees litellm models" "no Claude model enabled"
  fi
  # (Open WebUI's site also limits what an answer can make the browser fetch — images, media, frames, requests, forms:
  # chat_csp — and sends no Referer)
  local want_csp ref want_ref bad
  for k in chat:/ admin:/ui/ files:/rustfs/console/; do
    code="$(portal_curl "${k%%:*}" "${k#*:}" -s -m 20 -o /dev/null -D "$hdr" -w '%{http_code}' || true)"
    csp="$(_hdr content-security-policy < "$hdr")"; ref=''; want_ref=''
    want_csp="frame-ancestors $origin"
    # (Chat: each of its directives there with exactly its sources — chat_csp_check —, and no Referer)
    if [ "${k%%:*}" = chat ]; then
      want_csp="Chat's policy"
      if bad="$(chat_csp_check "$csp" "$origin" "$(app_host chat)")"; then csp="Chat's policy"; else csp="$bad differs in: $csp"; fi
      ref="|$(_hdr referrer-policy < "$hdr")"; want_ref='|no-referrer'
    fi
    _check "${k%%:*}. loads, framable only by the portal" "$code|$csp|$(_hdr x-frame-options < "$hdr")$ref" "200|$want_csp|$want_ref"
  done
  portal_session_end; rm -f "$hdr"
}

# Every probe below is `|| true` inside its substitution: under set -e/pipefail a transport error or a
# grep without match must turn into a FAIL line, not silently end the test run.
cmd_test() {
  local fails=0 tmp lp mp code haiku opus sk alias envk k
  [ -f "$ENV_FILE" ] || die "run ./stack setup first"
  tmp="$(mktemp)"; lp="$(get_env LITELLM_PORT)"; mp="$(get_env SHARED_MCP_PORT)"
  haiku="$(get_env CLAUDE_BEDROCK_HAIKU_MODEL)"; opus="$(get_env CLAUDE_BEDROCK_OPUS_MODEL)"
  sk="$(get_env LITELLM_KEY_SETUP)"

  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$lp/health/liveliness" || true)"
  _check "litellm alive" "$code" 200
  # Free: every virtual key is checked with /key/info. Paid (~$0.0001): the calls below use the setup key only.
  for alias in claude-code open-webui setup $([ -z "$(get_env LITELLM_KEY_TERMINAL)" ] || echo claude-code-terminal); do
    case "$alias" in claude-code) envk=LITELLM_KEY_CLAUDE_CODE ;; open-webui) envk=LITELLM_KEY_OPENWEBUI ;; claude-code-terminal) envk=LITELLM_KEY_TERMINAL ;; *) envk=LITELLM_KEY_SETUP ;; esac
    k="$(get_env "$envk")"
    if [ -n "$k" ]; then code="$(litellm_key_status "$k")"; else code=missing; fi
    _check "LiteLLM key '$alias' is valid" "$code" 200
  done
  if [ -n "$haiku" ] && [ -n "$sk" ]; then
    code="$(curl_auth "$sk" -s -m 120 -o "$tmp" -w '%{http_code}' -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d "{\"model\":\"$haiku\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" "http://127.0.0.1:$lp/v1/messages" || true)"
    _check "anthropic /v1/messages ($haiku)" "$code" 200
    code="$(curl_auth "$sk" -s -m 120 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d "{\"model\":\"$haiku\",\"max_tokens\":5,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" "http://127.0.0.1:$lp/v1/messages" || true)"
    _check "anthropic streaming" "$code" 200
  elif [ -z "$haiku" ]; then
    _skip "anthropic /v1/messages" "no Claude model enabled"
  else
    _skip "anthropic /v1/messages" "no setup key — run ./stack setup"
  fi
  if [ -n "$(get_env OWUI_EMBED_MODEL)" ] && [ -n "$sk" ]; then
    code="$(curl_auth "$sk" -s -m 120 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
      -d "{\"model\":\"$(get_env OWUI_EMBED_MODEL)\",\"input\":\"ping\"}" "http://127.0.0.1:$lp/v1/embeddings" || true)"
    _check "embeddings ($(get_env OWUI_EMBED_MODEL))" "$code" 200
  elif [ -z "$(get_env OWUI_EMBED_MODEL)" ]; then
    _skip "embeddings" "no embedding model enabled"
  else
    _skip "embeddings" "no setup key — run ./stack setup"
  fi
  _test_portal
  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$mp/healthz" || true)"
  _check "shared-mcp health" "$code" 200
  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$mp/mcp" || true)"
  _check "shared-mcp rejects no token" "$code" 401
  code="$(curl_auth "$(get_env SHARED_MCP_TOKEN)" -s -m 30 -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "http://127.0.0.1:$mp/mcp" 2>/dev/null | grep -o '"search_knowledge"' | head -n1 || true)"
  _check "shared-mcp lists tools" "$code" '"search_knowledge"'
  stt_test_checks   # lib/stt.sh: Bedrock speech-to-text, when on (~$0.00005)
  terminal_test_checks   # lib/terminal.sh: the browser terminal's checks, when on (no Bedrock calls)
  projects_test_checks   # lib/projects.sh: the sandbox sees each project folder, read-only where chosen
  code_test_checks       # lib/code.sh: the Code page's checks, when on (no Bedrock calls)
  rm -f "$tmp"
  [ "$fails" -eq 0 ] || die "$fails check(s) failed — see ./stack logs"
  log "all checks passed"
}

# --- backup / restore / update / rotate-aws / uninstall ---

# s3_job HOST_DIR MODE SCRIPT — runs aws-cli (the rustfs-init service: RustFS creds, stack network) with
# HOST_DIR mounted at /backup (MODE "ro" = read-only; ":z" relabels for SELinux, a no-op elsewhere).
# Runs as the calling user so files in backups/ stay deletable on Linux — except on rootless Docker, where
# container root already maps to the calling user. HOME=/tmp gives aws-cli a writable cache dir.
s3_job() {
  local user=()
  _docker_rootless || user=(--user "$(id -u):$(id -g)")
  dc run --rm --no-deps ${user[@]+"${user[@]}"} -e HOME=/tmp -v "$1:/backup:${2:+$2,}z" \
    --entrypoint /bin/sh rustfs-init -c "$3"
}

# Postgres + RustFS must be running for backup/restore (harmless if they already are).
_data_services_up() {
  dc up -d --wait postgres rustfs >/dev/null 2>&1 || die "could not start postgres/rustfs — see ./stack logs postgres"
}

# A failed backup must not leave a half-written directory behind (globals: the EXIT trap outlives locals).
_BACKUP_PARTIAL=''
_cleanup_partial_backup() { [ -z "$_BACKUP_PARTIAL" ] || rm -rf "$_BACKUP_PARTIAL"; }

# shellcheck disable=SC2120  # arguments come from the ./stack dispatcher
cmd_backup() {
  local own=1
  [ -f "$ENV_FILE" ] || die "nothing to back up — run ./stack setup first"
  ! stack_lock_ours || own=0   # (restore, rollback and clean ask for one holding their own lock)
  stack_lock backup   # lib/lock.sh: ./stack up must not recreate Postgres or RustFS halfway
  case "${1:-}" in
    '') [ $# -eq 0 ] || die "usage: ./stack backup [--nightly | --portal]"; _backup_named "" ;;
    # the update helper's nightly backup (BACKUP_NIGHTLY=on): backups/<timestamp>-nightly/, the newest BACKUP_KEEP kept
    --nightly) [ $# -eq 1 ] || die "usage: ./stack backup [--nightly | --portal]"; _backup_named nightly; prune_backups nightly "$(backup_keep)" ;;
    # Back up now in the portal's Settings (through the update helper): backups/<timestamp>-portal/, the newest 5 kept
    --portal) [ $# -eq 1 ] || die "usage: ./stack backup [--nightly | --portal]"; _backup_named portal; prune_backups portal "$PORTAL_BACKUPS_KEEP" ;;
    *) die "usage: ./stack backup [--nightly | --portal]   (writes backups/<timestamp>/)" ;;
  esac
  write_backups_json   # lib/settings.sh: the list Settings shows
  [ "$own" = 0 ] || stack_unlock
}

PORTAL_BACKUPS_KEEP=5   # backups made from the portal (Back up now): the newest 5 are kept

# _backup_space_check — refuses a backup that would not fit: at least twice the newest backup's size must be free
# (a full disk stops the databases too)
_backup_space_check() {
  local last='' d kb free
  for d in "$STACK_DIR"/backups/*/; do [ -d "$d" ] || continue; case "$d" in *.partial/) ;; *) last="$d" ;; esac; done   # newest last
  [ -n "$last" ] || return 0
  kb="$(du -sk "$last" 2>/dev/null | cut -f1 || true)"; case "$kb" in '' | *[!0-9]*) return 0 ;; esac
  free="$(df -Pk "$STACK_DIR/backups" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"; case "$free" in '' | *[!0-9]*) return 0 ;; esac
  [ "$free" -ge $((kb * 2)) ] ||
    die "not enough free disk space for a backup: $((free / 1024)) MB free, and one needs about $((kb / 1024 + 1)) MB (twice that is kept free) — delete old backups in backups/ first"
}

# _backup_named SUFFIX — writes backups/<ts>[-SUFFIX]/ and sets LAST_BACKUP (backups/<ts>…) for callers
# that want to name it in messages. ./stack update uses SUFFIX=auto so it can prune its own backups.
_backup_named() {
  local dir tmp db
  [ -f "$ENV_FILE" ] || die "nothing to back up — run ./stack setup first"
  _backup_space_check
  dir="$STACK_DIR/backups/$(date +%Y%m%d-%H%M%S)${1:+-$1}"; tmp="$dir.partial"
  mkdir -p "$tmp"; chmod 700 "$STACK_DIR/backups" "$tmp"
  _BACKUP_PARTIAL="$tmp"; on_exit _cleanup_partial_backup
  _data_services_up
  for db in litellm openwebui; do
    if ! dc exec -T postgres pg_dump -U postgres -Fc "$db" > "$tmp/$db.dump"; then
      die "could not dump database $db — the incomplete backup was removed; is postgres healthy? ./stack status"
    fi
  done
  mkdir -p "$tmp/s3/openwebui" "$tmp/s3/shared"
  s3_job "$tmp" "" 'set -e; for b in openwebui shared; do aws --endpoint-url http://rustfs:9000 s3 sync --only-show-errors s3://$b /backup/s3/$b; done' ||
    die "could not copy the object-store buckets — the incomplete backup was removed; see ./stack logs rustfs"
  cp "$ENV_FILE" "$tmp/.env"   # encrypted DB fields need the same secrets
  # the project folders of this computer (lib/projects.sh: the list, not the folders themselves)
  [ ! -f "$(projects_file)" ] || cp "$(projects_file)" "$tmp/project-folders.tsv"
  chmod -R go-rwx "$tmp"       # dumps hold chats, hashed keys and encrypted credentials
  mv "$tmp" "$dir"
  _BACKUP_PARTIAL=''; off_exit _cleanup_partial_backup
  LAST_BACKUP="${dir#"$STACK_DIR"/}"
  log "backup written to ${dir#"$STACK_DIR"/} ($(du -sh "$dir" 2>/dev/null | cut -f1 | tr -d ' ')) — databases, buckets and a copy of .env (contains secrets; keep it private)"
}

# _restore_key_trio BACKUP_DIR — the restored databases only know the keys that existed at backup time, so
# the matching LiteLLM virtual keys and Open WebUI API key come back from the backup's .env.
_restore_key_trio() {
  local k v n=0
  [ -f "$1/.env" ] || { warn "the backup has no .env — run ./stack setup --yes after the restore to recreate the keys"; return 0; }
  for k in LITELLM_KEY_CLAUDE_CODE LITELLM_KEY_OPENWEBUI LITELLM_KEY_SETUP OPENWEBUI_API_KEY; do
    v="$(ENV_FILE="$1/.env" get_env "$k")"
    if [ -z "$v" ]; then
      warn "$k is missing from the backup's .env — run ./stack setup --yes after the restore to create a new one"; continue
    fi
    [ "$v" = "$(get_env "$k")" ] || { set_env "$k" "$v"; n=$((n + 1)); }
  done
  # The browser terminal's key (lib/terminal.sh), when there is one: the backup's, or none — ./stack up and
  # ./stack terminal enable then make a new one for the restored database.
  v="$(ENV_FILE="$1/.env" get_env LITELLM_KEY_TERMINAL)"
  [ "$v" = "$(get_env LITELLM_KEY_TERMINAL)" ] || { set_env LITELLM_KEY_TERMINAL "$v"; n=$((n + 1)); }
  log "restored the backup's keys (LiteLLM virtual keys, Open WebUI API key) into .env ($n changed)"
}

# _is_backup DIR -> 0 when DIR holds both database dumps ./stack backup writes
_is_backup() { [ -f "$1/litellm.dump" ] && [ -f "$1/openwebui.dump" ]; }

# backup_dir_arg DIR -> the backup DIR names, as an absolute path: an absolute DIR as given; a relative one from the
# current folder, or else inside this checkout — every message says "./stack restore backups/<ts>" and ./stack can
# be run from any folder (e.g. ~/devos-ade/stack restore …). Dies when a relative DIR is a backup in both places
# and they are different folders. Prints DIR unchanged when it is no backup at all (the caller prints its usage).
backup_dir_arg() {
  local d="$1" here='' there=''
  case "$d" in '' | /*) printf '%s\n' "$d"; return 0 ;; esac
  if _is_backup "$d"; then here="$(cd "$d" && pwd -P)"; fi
  if _is_backup "$STACK_DIR/$d"; then there="$(cd "$STACK_DIR/$d" && pwd -P)"; fi
  [ -z "$here" ] || [ -z "$there" ] || [ "$here" = "$there" ] ||
    die "ambiguous backup path '$d': it is $here (from this folder) and also $there (in this checkout) — pass an absolute path. Nothing was changed."
  printf '%s\n' "${here:-${there:-$d}}"
}

# _validate_backup DIR — before anything is stopped or dropped: both bucket folders are there, and each dump is an
# archive pg_restore (inside the postgres container) can list, with at least one entry. A damaged or empty backup
# must never get as far as DROP DATABASE.
_validate_backup() {
  local dir="$1" b db n
  for b in openwebui shared; do
    [ -d "$dir/s3/$b" ] || die "$dir has no s3/$b folder, so it is not a complete ./stack backup — nothing was changed"
  done
  # First that commands run in the postgres container at all: a failing exec must not read as an unreadable dump.
  dc exec -T postgres true </dev/null >/dev/null 2>&1 ||
    die "cannot run commands in the postgres container (./stack status; ./stack logs postgres) — nothing was changed"
  for db in litellm openwebui; do
    n="$(dc exec -T postgres pg_restore --list < "$dir/$db.dump" 2>/dev/null | grep -c '^[0-9]' || true)"
    [ "${n:-0}" -gt 0 ] ||
      die "$dir/$db.dump is not a readable database dump (pg_restore --list finds nothing in it) — nothing was changed"
  done
}

cmd_restore() {
  local dir db k hint
  dir="$(backup_dir_arg "${1:-}")" || exit 1
  case "${dir%/}" in *.partial) die "${dir%/} is an incomplete backup (it failed or is still being written) — pick a complete one from backups/" ;; esac
  [ -n "$dir" ] && _is_backup "$dir" ||
    die "usage: ./stack restore backups/<timestamp>   (a directory written by ./stack backup)"
  [ -f "$ENV_FILE" ] || die "run ./stack setup first (on a new machine: copy the backup's .env to ./.env, run ./stack setup, then restore)"
  stack_lock restore
  ! declare -F xl_bg_stop >/dev/null || xl_bg_stop   # (lib/explabs.sh: its background read would write a list the restore replaces)
  quiet_compose
  dir="$(cd "$dir" && pwd -P)"
  log "backup to restore: $dir"
  if [ -f "$dir/.env" ]; then
    for k in LITELLM_SALT_KEY WEBUI_SECRET_KEY LITELLM_MASTER_KEY; do
      [ "$(ENV_FILE="$dir/.env" get_env "$k")" = "$(get_env "$k")" ] ||
        warn "$k differs from the backup's .env — stored credentials/sessions may not work after restoring; to restore exactly, copy $dir/.env over .env first"
    done
  fi
  [ "${ASSUME_YES:-0}" = 1 ] || _have_tty ||
    die "restore replaces all data; re-run with --yes to do it non-interactively — nothing was changed"
  _data_services_up
  _validate_backup "$dir"
  warn "restore REPLACES all current chats, knowledge bases, files, LiteLLM keys and spend history with $dir"
  confirm "Restore $dir now?" || die "aborted — nothing was changed"
  if confirm "Take a backup of the current state first?"; then
    cmd_backup
    hint="your pre-restore state is in $LAST_BACKUP — run ./stack restore $LAST_BACKUP"
  else
    warn "no pre-restore backup — if this restore fails, the current data cannot be recovered"
    hint="no pre-restore backup was taken (you declined it), so fix the cause and re-run ./stack restore ${dir#"$STACK_DIR"/}"
  fi
  _data_services_up
  log "stopping Open WebUI, LiteLLM and shared-mcp while the databases are replaced"
  dc stop open-webui litellm shared-mcp
  for db in litellm openwebui; do
    dc exec -T postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
      -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" -c "CREATE DATABASE \"$db\"" >/dev/null ||
      die "could not recreate database $db (services are stopped); $hint"
    dc exec -T postgres pg_restore -U postgres -d "$db" --no-owner --exit-on-error < "$dir/$db.dump" ||
      die "pg_restore of $db failed, the databases are only partly restored (services are stopped); $hint"
  done
  # Each bucket becomes an exact copy of the backup's folder. `aws s3 sync` alone cannot do that: uploading, it
  # skips a file of unchanged size unless the file is NEWER than the object, and a backup's files keep the objects'
  # dates from backup time — a file overwritten since then with the same size would keep its new content. So
  # `cp --recursive` first uploads every file whatever its size or date (objects are replaced in place: the bucket
  # is never empty), then `sync --delete` removes the objects the backup does not have (it uploads nothing more:
  # each object now has its file's size and a newer date; were the clocks off, it would only upload a file again).
  # Unlike re-dating a copy of the backup first, this needs no extra disk space and no clocks that agree.
  # No bucket folder in the backup: the bucket is emptied.
  s3_job "$dir" ro 'set -e; S3="aws --endpoint-url http://rustfs:9000"
    for b in openwebui shared; do
      if [ -d /backup/s3/$b ]; then
        $S3 s3 cp --recursive --only-show-errors /backup/s3/$b s3://$b
        $S3 s3 sync --delete --only-show-errors /backup/s3/$b s3://$b
      else $S3 s3 rm --recursive --only-show-errors s3://$b; fi
    done' || die "restoring the object-store buckets failed (databases are restored, services are stopped); $hint"
  _restore_key_trio "$dir"
  # the project folders' list as it was (each folder checked again before the sandbox sees it: projects_up_hook)
  if [ -f "$dir/project-folders.tsv" ]; then
    projects_write "$(cat "$dir/project-folders.tsv")"; projects_sync >/dev/null 2>&1 || true
    log "restored the list of project folders (./stack project list)"
  fi
  ensure_portal_password_hash   # lib/settings.sh: a .env copied from an older backup has no PORTAL_PASSWORD_HASH yet
  write_mcp_config
  # .env may have changed: recreate the containers that read these keys, then start everything else.
  remote_net_preflight
  # (Chat's own egress proxy, should the restored .env no longer make it Chat's way out: gone before any up)
  ! declare -F chat_proxy_leave >/dev/null || chat_proxy_leave
  log "starting the services again (waits until each one is healthy)"
  dc up -d --wait --force-recreate open-webui shared-mcp
  # shellcheck disable=SC2046  # word-split the service list on purpose
  dc up -d --wait $(stack_services)
  remote_up_hook
  ensure_portal_reachable   # lib/portal.sh: Docker Desktop forwarding the portal's port to the Caddy it replaced
  settings_reconcile_with_session   # lib/settings.sh: the backup's databases may carry an older owner email or Admin password
  log "restored $dir; running the smoke test (if keys fail, ./stack setup --yes re-validates them)"
  cmd_test
}

# prune_auto_backups KEEP — keeps the newest KEEP backups/*-auto directories (made by ./stack update) and, however
# old, the one the update record names (what ./stack rollback restores, lib/rollback.sh); manual backups and
# incomplete (*.partial) ones are never touched.
prune_auto_backups() {
  local keep="$1" d i=0 removed=0 all=() rec
  rec="$(_record_get backup)"; rec="${rec%/}"
  for d in "$STACK_DIR"/backups/*-auto; do [ -d "$d" ] && all+=("$d"); done   # glob order = oldest first
  while [ $((${#all[@]} - i)) -gt "$keep" ]; do
    [ -n "$rec" ] && [ "${all[$i]}" = "$STACK_DIR/$rec" ] || { rm -rf "${all[$i]}"; removed=$((removed + 1)); }
    i=$((i + 1))
  done
  [ "$removed" -eq 0 ] ||
    log "removed $removed old automatic backup(s); ./stack update keeps the newest $keep and the one ./stack rollback needs (manual backups are never pruned)"
  write_backups_json
}

# newest_release_tag GIT_DIR -> newest vX.Y.Z tag, pre-releases (anything with "-") excluded.
# install.sh has its own copy (latest_release_tag); tests/test_update_git.sh checks both agree.
newest_release_tag() {
  git -C "$1" -c versionsort.suffix=- tag -l 'v[0-9]*' --sort=-v:refname | grep -v -- '-' | sed -n '1p' || true
}

# (umask 022: what git writes into the checkout must be readable as a clone's is, also when the update helper — umask
# 077 — runs ./stack update; see fix_checkout_modes)
_git() { ( umask 022; git -C "$STACK_DIR" "$@" ); }
_require_clean_tree() { # ./stack update never starts (no backup, no pruning) over local changes to tracked files
  [ -e "$STACK_DIR/.git" ] || return 0
  [ -z "$(_git status --porcelain --untracked-files=no)" ] ||
    die "this checkout has local changes to tracked files — commit or stash them (git stash), then re-run ./stack update. Nothing was changed."
}
# _rollback_cmd COMMIT [BRANCH] -> the git command that puts the code back; branch users stay on their branch
_rollback_cmd() {
  if [ -n "${2:-}" ]; then printf 'git -C %q switch -C %q %s' "$STACK_DIR" "$2" "$1"
  else printf 'git -C %q checkout %s' "$STACK_DIR" "$1"; fi
}

# _signed_tags_required — UPDATE_REQUIRE_SIGNED_TAGS=true in .env: ./stack update only checks out a release tag
# whose signature git verify-tag accepts (trusted keys: docs/security.md#code-provenance)
_signed_tags_required() { [ "$(get_env UPDATE_REQUIRE_SIGNED_TAGS)" = true ]; }

# update_nothing_new [REF] -> 0 when ./stack update would leave the code exactly as it is (fetches first): the last
# successful setup ran on HEAD (setup_ran_on_head, lib/rollback.sh), and HEAD is already the target update_checkout
# would pick, in the same state (a branch up to date with its origin branch, or a detached HEAD at the tag/commit). Whatever it cannot tell (no git, no network, an unknown ref, a branch that
# follows another remote, a switch between a branch and a tag) counts as something to do: update_checkout decides.
update_nothing_new() {
  local to="${1:-}" head branch up target
  [ -e "$STACK_DIR/.git" ] || return 1
  setup_ran_on_head || return 1   # the last successful setup ran on other code (or none is recorded): every step
  _git fetch --quiet --tags origin 2>/dev/null || return 1
  _UPDATE_FETCHED=1   # update_checkout does not fetch a second time
  origin_follow_rename   # lib/repo_rename.sh: origin to the repository's new name, once it exists
  head="$(_git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  branch="$(_git symbolic-ref -q --short HEAD || true)"
  if [ -n "$branch" ]; then
    # on a branch: git pull --ff-only (--to the same branch: checkout, then the same pull)
    [ -z "$to" ] || [ "$to" = "$branch" ] || return 1
    ! _signed_tags_required || return 1   # a branch cannot be verified: update_checkout refuses it and says why
    [ "$(_git config "branch.$branch.remote" 2>/dev/null || true)" = origin ] || return 1
    up="$(_git rev-parse -q --verify "$branch@{upstream}^{commit}" 2>/dev/null)" || return 1
    _git merge-base --is-ancestor "$up" "$head"   # nothing to fast-forward
    return
  fi
  if [ -n "$to" ]; then
    ! _git show-ref -q --verify "refs/heads/$to" || return 1   # a local branch: checkout would attach HEAD to it
    ! _signed_tags_required || return 1   # update_checkout checks that it is a signed tag
    target="$to"
  else
    target="$(newest_release_tag "$STACK_DIR")"; [ -n "$target" ] || return 1
  fi
  [ "$(_git rev-parse -q --verify "$target^{commit}" 2>/dev/null)" = "$head" ]
}

# update_checkout [REF] — moves this checkout to newer code; sets CODE_CHANGED=1 when HEAD moved.
#   on a branch: git pull --ff-only;  on a tag / detached HEAD (install.sh): the newest release tag, never
#   older than HEAD;  REF given (--to): exactly that tag/branch/commit. Local changes to tracked files stop it.
update_checkout() {
  local to="${1:-}" branch target before cur
  CODE_CHANGED=0
  if [ ! -e "$STACK_DIR/.git" ]; then warn "$STACK_DIR is not a git checkout — skipping the code update (images and setup still run)"; return 0; fi
  _require_clean_tree
  before="$(_git rev-parse HEAD)"; cur="$(_git describe --tags --always 2>/dev/null || echo "$before")"
  if [ "${_UPDATE_FETCHED:-0}" != 1 ]; then
    _git fetch --quiet --tags origin || die "could not fetch updates from origin (network?) — the code was not changed"
    origin_follow_rename   # lib/repo_rename.sh
  fi
  branch="$(_git symbolic-ref -q --short HEAD || true)"
  if [ -n "$to" ]; then
    target="$to"
  elif [ -n "$branch" ] && _signed_tags_required; then
    die "UPDATE_REQUIRE_SIGNED_TAGS=true: a branch cannot be verified — use ./stack update --to <signed tag> (the code was not changed)"
  elif [ -n "$branch" ]; then
    _git pull --quiet --ff-only || die "could not fast-forward branch $branch (it has diverged from origin) — the code was not changed; merge it yourself or use ./stack update --to <tag>"
    if [ "$(_git rev-parse HEAD)" = "$before" ]; then log "branch $branch is already up to date"
    else log "updated branch $branch: $cur → $(_git describe --tags --always)"; CODE_CHANGED=1; fi
    return 0
  else
    target="$(newest_release_tag "$STACK_DIR")"
    [ -n "$target" ] || die "no release tags found on origin — use ./stack update --to main"
    _git merge-base --is-ancestor HEAD "$target" ||
      die "your checkout is ahead of $target — use ./stack update --to <ref> (the code was not changed)"
  fi
  if _signed_tags_required; then
    _git rev-parse -q --verify "refs/tags/$target" >/dev/null ||
      die "UPDATE_REQUIRE_SIGNED_TAGS=true: '$target' is not a tag — the code was not changed"
    _git verify-tag "$target" >/dev/null 2>&1 ||
      die "UPDATE_REQUIRE_SIGNED_TAGS=true: the signature of tag $target could not be verified (git verify-tag $target; docs/security.md#code-provenance) — the code was not changed"
    log "tag $target: signature verified"
  fi
  _git -c advice.detachedHead=false checkout --quiet "$target" ||
    die "could not check out '$target' (see git's message above) — the code was not changed"
  if [ -n "$(_git symbolic-ref -q HEAD || true)" ]; then
    _git pull --quiet --ff-only || die "could not fast-forward $target — merge it yourself"
  fi
  if [ "$(_git rev-parse HEAD)" = "$before" ]; then log "already on $target"; return 0; fi
  log "updating $cur → $target"
  CODE_CHANGED=1
}

# _update_reexec_genuine — BEDROCK_NOW_CODE_UPDATED=1 counts only in the process ./stack update exec'd itself into
# (exec keeps the pid): it holds the update lock (BEDROCK_NOW_LOCK_HELD = $$). A version from before the lock (v0.2.1
# and older) passes no lock: then the commit it came from must be a real one other than HEAD, with its complete
# pre-update backup from the last hour.
_update_reexec_genuine() {
  local from="${BEDROCK_NOW_UPDATE_FROM:-}" b="${BEDROCK_NOW_UPDATE_BACKUP:-}"
  [ "${BEDROCK_NOW_CODE_UPDATED:-0}" = 1 ] || return 1
  if [ -n "${BEDROCK_NOW_LOCK_HELD:-}" ]; then
    [ "$BEDROCK_NOW_LOCK_HELD" = "$$" ] && [ "$(head -c 20 "$(lock_dir)/pid" 2>/dev/null)" = "$$" ]
    return
  fi
  case "$from" in '' | *[!0-9a-f]*) return 1 ;; esac
  case "$b" in *..* | *[[:space:]]*) return 1 ;; backups/?*-auto) ;; *) return 1 ;; esac
  [ -e "$STACK_DIR/.git" ] && _git cat-file -e "$from^{commit}" 2>/dev/null || return 1
  [ "$(_git rev-parse HEAD)" != "$(_git rev-parse "$from^{commit}")" ] || return 1
  _is_backup "$STACK_DIR/$b" && [ -n "$(find "$STACK_DIR/$b" -maxdepth 0 -mmin -60 2>/dev/null)" ]
}

# ./stack update: 1/4 backup (current code) → 2/4 code → [re-exec new code] → 3/4 images → 4/4 setup.
# The re-exec gets BEDROCK_NOW_CODE_UPDATED=1, the backup dir, the previous commit and branch, so a later failure
# can tell you exactly how to go back. Nothing new (update_nothing_new): it says so and stops before the backup
# (exit 0); --force runs every step anyway (re-runs setup: model probe, LiteLLM restart, smoke test).
# An update that moved the code but did not finish (update_unfinished: pull or setup failed, or it was stopped) is
# finished first: images and setup, with no new backup or snapshot, so ./stack rollback keeps going back to the
# version and backup it recorded (--to moves the code on first, e.g. to a fix; BEDROCK_NOW_UPDATE_FINISHING=1).
# The record is written right after the checkout, before the exec, so a stop at any point after it counts as such.
cmd_update() {
  local to='' backup from='' branch='' hint moved=0 force=0 finishing=0 reexec=0 yes=() pullenv=() usage="usage: ./stack update [--to <tag|branch>] [--force]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) case "${2:-}" in '' | -*) die "$usage" ;; esac; to="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) die "$usage" ;;
    esac
  done
  [ -f "$ENV_FILE" ] || die "run ./stack setup first"
  # (this version's compose files need Docker Compose 2.24.4: said before anything changes — after an update from an
  # earlier version, before its setup runs; ./stack update then finishes it once Compose is updated)
  compose_overrides_ok || die "$(compose_too_old)"
  if [ "${BEDROCK_NOW_CODE_UPDATED:-0}" = 1 ]; then   # before stack_lock, which would take the lock as ours
    if _update_reexec_genuine; then reexec=1
    else   # e.g. v0.1.1 or a stale v0.2.1 hand-over: the code may have moved, so nothing is skipped
      warn "BEDROCK_NOW_CODE_UPDATED=1 in the environment is ignored (./stack update sets it only for itself) — running every step"
      force=1
    fi
  fi
  stack_lock update   # lib/lock.sh: one update/rollback/clean/restore/setup at a time (kept across the re-exec)
  ! declare -F xl_bg_stop >/dev/null || xl_bg_stop   # (lib/explabs.sh: a background read of the model details)
  [ "${ASSUME_YES:-0}" != 1 ] || yes=(--yes)
  if [ "$reexec" = 0 ] && update_unfinished; then
    _require_clean_tree
    finishing=1; moved=1
    from="$(_record_get from)"; branch="$(_record_get branch)"; backup="$(_record_get backup)"
    log "update: the last update (from $(_record_get from_version)) did not finish — finishing it; no new backup: ./stack rollback still goes back with $backup"
    hint="./stack update finishes it, or ./stack rollback goes back (by hand: $(_rollback_cmd "$from" "$branch") && ./stack restore $backup)"
    if [ -n "$to" ]; then
      log "update: 2/4 code (git)"
      timed_step "New code (git)" update_checkout "$to"
      [ "$CODE_CHANGED" != 1 ] ||
        exec env BEDROCK_NOW_CODE_UPDATED=1 BEDROCK_NOW_UPDATE_FINISHING=1 BEDROCK_NOW_UPDATE_BACKUP="$backup" \
          BEDROCK_NOW_UPDATE_FROM="$from" BEDROCK_NOW_UPDATE_BRANCH="$branch" "$STACK_DIR/stack" update ${yes[@]+"${yes[@]}"}
    fi
  elif [ "$reexec" = 0 ]; then
    _require_clean_tree
    if [ "$force" = 0 ] && update_nothing_new "$to"; then
      log "already on $(installed_version) — nothing to update (./stack update --force re-runs setup)"
      offer_helper --after-update   # lib/helper.sh: one-click updates, so this needs no terminal next time
      return 0
    fi
    log "update: 1/4 backup"
    timed_step "Backup" _update_backup
    backup="$LAST_BACKUP"
    if [ -e "$STACK_DIR/.git" ]; then from="$(_git rev-parse HEAD)"; branch="$(_git symbolic-ref -q --short HEAD || true)"; fi
    log "update: 2/4 code (git)"
    timed_step "New code (git)" update_checkout "$to"
    if [ "$CODE_CHANGED" = 1 ]; then
      # What ./stack rollback needs, now that the code moved: a stop before the new code runs is an unfinished update.
      update_record_write "$from" "$branch" "$backup"
      # Continue in a fresh process so images and setup run with the NEW scripts.
      exec env -u BEDROCK_NOW_UPDATE_FINISHING BEDROCK_NOW_CODE_UPDATED=1 BEDROCK_NOW_UPDATE_BACKUP="$backup" \
        BEDROCK_NOW_UPDATE_FROM="$from" BEDROCK_NOW_UPDATE_BRANCH="$branch" "$STACK_DIR/stack" update ${yes[@]+"${yes[@]}"}
    fi
    hint="./stack update runs it again; your pre-update backup is $backup (./stack restore $backup)"
  else
    backup="${BEDROCK_NOW_UPDATE_BACKUP:-}"; from="${BEDROCK_NOW_UPDATE_FROM:-}"; branch="${BEDROCK_NOW_UPDATE_BRANCH:-}"
    moved=1
    # finishing an unfinished update (set by the exec above): only while the record says so
    [ "${BEDROCK_NOW_UPDATE_FINISHING:-0}" != 1 ] || [ "$(_record_get result)" != running ] || finishing=1
    log "update: 1/4 backup and 2/4 code done (backup: ${backup:-none})"
    hint="./stack update finishes it, or ./stack rollback goes back (by hand: $(_rollback_cmd "$from" "$branch") && ./stack restore $backup)"
  fi
  # Only an update that moved the code is a new version: an update with nothing new keeps the rollback record
  # and the previous version's images exactly as they are. Finishing an update: its record and snapshot stand.
  if [ "$moved" = 1 ] && [ "$finishing" = 0 ]; then
    # What ./stack rollback needs (lib/rollback.sh), recorded before anything but the code has changed (already
    # written by this version before the exec; an older version's ./stack update did not).
    update_record_write "$from" "$branch" "$backup"
    # The images in use now (the old version's): kept after the update as the one previous version (lib/images.sh).
    timed_step "Images of the version before kept (for rollback)" images_snapshot_before "$from"
  elif [ "$finishing" = 1 ] && [ ! -f "$(images_dir)/before.tsv" ]; then
    # stopped before it: setup has not run, so :local is still the old build
    timed_step "Images of the version before kept (for rollback)" images_snapshot_before "$from"
  fi
  # The images compose.yaml pins: all at once, in the background (lib/steps.sh pulls_start), while setup builds; setup
  # waits for them before it starts anything with them (pulls_wait), and a download that fails stops it there. When
  # the list cannot be read, one compose call here as before.
  log "update: 3/4 images (downloading the versions pinned in compose.yaml, side by side, while setup builds)"
  PULLS_DIR=''; PULLS_PID=''
  if ! timed_step "Image downloads started" pulls_start; then
    PULLS_DIR=''; PULLS_PID=''
    timed_step "Image downloads" dc pull --ignore-buildable || {
      [ "$?" -lt 128 ] || die "update stopped during 3/4 images — $hint"   # Ctrl-C: Compose ends with 128 + the signal
      die "image pull failed or was stopped (network/registry?) — $hint"
    }
  fi
  [ -z "$PULLS_DIR" ] || pullenv=(BEDROCK_NOW_PULLS_DIR="$PULLS_DIR" BEDROCK_NOW_PULLS_PID="$PULLS_PID")
  log "update: 4/4 setup (non-interactive; keeps .env, keys and AWS creds)"
  # Separate process (keeps set -e working inside setup); AWS creds and the optional OpenRouter settings come
  # from .env, never from this shell (a removed OpenRouter key stays removed).
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_REGION_NAME -u AWS_REGION \
    -u OPENROUTER_API_KEY -u OPENROUTER_MODELS -u OPENROUTER_MAX_MODELS -u BEDROCK_NOW_OPENROUTER_FROM_ENV \
    -u EXPLABS_API_KEY -u EXPLABS_MODELS \
    -u STT_PROVIDER -u STT_API_KEY -u STT_MODEL -u BEDROCK_NOW_STT_FROM_ENV \
    -u COMPOSE_PROJECT_NAME -u BEDROCK_NOW_CODE_UPDATED -u BEDROCK_NOW_UPDATE_BACKUP -u BEDROCK_NOW_UPDATE_FROM -u BEDROCK_NOW_UPDATE_BRANCH \
    -u BEDROCK_NOW_UPDATE_FINISHING -u BEDROCK_NOW_PULLS_DIR -u BEDROCK_NOW_PULLS_PID \
    ${pullenv[@]+"${pullenv[@]}"} "$STACK_DIR/stack" setup --yes ||
    die "update: setup failed (see the messages above) — $hint"
  # Every service this update recreated runs the image this release pins (by digest); one that does not fails the update
  # the way a failed setup does: the record stays "running", so ./stack rollback goes back (lib/versions.sh)
  timed_step "Services run the pinned images" update_verify_images ||
    die "update: a service is not running the image this release pins (see above) — $hint"
  if [ "$moved" != 1 ]; then
    log "update: done (no new version; ./stack rollback still goes back to the version before the last real update)"
    offer_helper --after-update; return 0
  fi
  update_record_done
  # Only now that the new version runs: remove what the update before this one replaced (keeps one previous).
  timed_step "Old images cleaned up" _update_cleanup
  [ -z "$from" ] || log "updated to $(installed_version). Something wrong? ./stack rollback goes back (code, data and images)"
  timed_step "What's new" update_whats_new "$from"
  offer_helper --after-update   # lib/helper.sh: asks (default yes) unless declined before
}
# cmd_update's own steps, each timed as one
_update_backup() { _backup_named auto; prune_auto_backups 5; }
_update_cleanup() { images_after_update || warn "could not clean up old images — ./stack clean tries again"; return 0; }

# releases_between FROM_COMMIT -> one line per release the update brought, newest first: "v0.9.0 — Git panel and Run &
# test" (each release tag's own subject line), the releases after the one FROM_COMMIT is (or follows) up to HEAD's;
# at most 10, then "… and N older"
releases_between() {
  local from cur t subj n=0 more=0
  [ -e "$STACK_DIR/.git" ] && [ -n "${1:-}" ] || return 0
  from="$(_git describe --tags --abbrev=0 "$1" 2>/dev/null || true)"; cur="$(installed_version)"
  _semver "$from" >/dev/null 2>&1 && _semver "$cur" >/dev/null 2>&1 || return 0
  for t in $(newest_release_tags); do
    version_newer "$t" "$from" || continue
    ! version_newer "$t" "$cur" || continue
    n=$((n + 1)); [ "$n" -le 10 ] || { more=$((more + 1)); continue; }
    subj="$(_git for-each-ref --format='%(objecttype) %(contents:subject)' "refs/tags/$t" 2>/dev/null | sed -n 's/^tag //p' | head -n 1 | tr -d '\000-\037')"
    # at most 120 characters, cut at a word (never inside a word, nor inside a character where bash counts bytes)
    [ "${#subj}" -le 120 ] || { subj="${subj:0:119}"; subj="${subj% *}"; subj="${subj%[,;:]} …"; }
    case "$subj" in "$t"*) printf '%s\n' "$subj" ;; '') printf '%s\n' "$t" ;; *) printf '%s — %s\n' "$t" "$subj" ;; esac
  done
  [ "$more" = 0 ] || printf '… and %s older\n' "$more"
}
# newest_release_tags -> every vX.Y.Z tag, newest first (pre-releases excluded; see newest_release_tag)
newest_release_tags() { _git -c versionsort.suffix=- tag -l 'v[0-9]*' --sort=-v:refname 2>/dev/null | grep -v -- '-' || true; }

# service_moves FROM_COMMIT -> one line per core service whose pinned version the update moved: "LiteLLM 1.105.0 → 1.106.3"
service_moves() {
  local old id a b tmp
  [ -e "$STACK_DIR/.git" ] && [ -n "${1:-}" ] || return 0
  tmp="$(mktemp)" || return 0
  if git -C "$STACK_DIR" show "$1:compose.yaml" > "$tmp" 2>/dev/null; then
    for id in $(core_service_ids); do
      a="$(ref_version "$(compose_service_image "$id" "$tmp")")"; b="$(ref_version "$(compose_service_image "$id")")"
      [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || continue
      printf '%s %s → %s\n' "$(_core_field "$id" 2)" "$a" "$b"
    done
  fi
  rm -f "$tmp"; old=''; return 0
}

# update_whats_new [FROM_COMMIT] — after an update to a new version: each release it brought, with its headline (all of
# them, when it jumped over several), then a few lines: voice, the Code page (while on: it is on by default now), the
# sandbox's internet (once, from a version before its egress proxy), remote
# access and updates (each with the command that changes it, the last two only while off: the one-click helper, or on
# a release its automatic updates) and the release notes
update_whats_new() {
  local tag rels n
  tag="$( [ ! -e "$STACK_DIR/.git" ] || _git describe --tags --exact-match HEAD 2>/dev/null || true)"
  rels="$(releases_between "${1:-}")"; n="$(printf '%s' "$rels" | grep -c '^v' || true)"
  if [ "${n:-0}" -gt 1 ]; then printf "\nWhat's new in %s (%s releases since %s):\n" "$(installed_version)" "$n" "$(_git describe --tags --abbrev=0 "$1" 2>/dev/null)"
  else printf "\nWhat's new in %s:\n" "$(installed_version)"; fi
  [ -z "$rels" ] || printf '%s\n' "$rels" | sed 's/^/  /'
  service_moves "${1:-}" | sed 's/^/  Service update: /'
  if stt_enabled; then printf '  Voice: %s speech-to-text is on (./stack stt status)\n' "$(stt_provider_label "$(stt_provider)")"
  elif stt_notice_on; then printf '  Voice: %s\n' "$STT_REFUSED_NOTICE"
  elif stt_bedrock_refused; then printf '  Voice: browser speech only — ./stack stt set openai|groq turns on speech-to-text with your own key (docs/voice.md)\n'
  else printf '  Voice: browser speech only — ./stack stt set bedrock turns on Bedrock speech-to-text (docs/voice.md)\n'; fi
  ! code_ready || printf '  Code page: on — the Code tab, Claude Code in the browser (sandbox folder %s); ./stack code disable turns it off\n' "$(get_env TERMINAL_WORKSPACE)"
  # the sandbox's way out changed under an update from a version without the egress proxy (v0.10.0 and earlier):
  # said once, with the way back. An older install's TERMINAL_EGRESS=on (or blank) is the new default; nothing to edit.
  if terminal_on && [ -n "${1:-}" ] && [ -e "$STACK_DIR/.git" ] && ! _git cat-file -e "$1:terminal/egress/bn-egress.mjs" 2>/dev/null; then
    case "$(terminal_egress_mode)" in
      internet) printf "  Sandbox internet: public addresses only now, through an egress proxy — this computer's services and your network are closed to it (Settings › Claude Code › Sandbox internet access: \"+ this computer\" opens them again)\n" ;;
      host) printf '  Sandbox internet: TERMINAL_EGRESS=host keeps this computer'"'"'s services and your network open to it (internet, the new default, closes them)\n' ;;
    esac
  fi
  remote_on || printf '  Remote access: off — ./stack remote enable tailscale (docs/remote.md)\n'
  if ! helper_installed; then printf '  One-click updates from Home: ./stack helper install\n'
  elif [ -n "$tag" ] && ! auto_on; then printf '  Automatic updates: off — ./stack helper auto on installs new releases at night\n'; fi
  if [ "${n:-0}" -gt 1 ]; then printf '  Release notes: %s\n' "$BEDROCK_NOW_RELEASES_URL"
  else case "$tag" in v[0-9]*) case "$tag" in *[!A-Za-z0-9._-]*) ;; *) printf '  Release notes: %s/tag/%s\n' "$BEDROCK_NOW_RELEASES_URL" "$tag" ;; esac ;; esac; fi
  return 0
}

cmd_rotate_aws() {
  local id secret region arn errf old old_auth old_secret
  [ -f "$ENV_FILE" ] || die "run ./stack setup first"
  stack_lock rotate-aws   # lib/lock.sh: .env is written below
  case "${1:-}" in   # instance-role mode: lib/host.sh
    '') if uses_instance_role; then instance_role_rotate_info; return 0; fi ;;
    --use-keys) ;;
    --use-instance-role) rotate_to_instance_role; return 0 ;;
    *) die "unknown option: $1 (./stack rotate-aws [--use-keys | --use-instance-role])" ;;
  esac
  id=''; secret=''
  if _env_aws_creds_chosen; then   # env creds: always non-interactively, only on "y" interactively
    id="$AWS_ACCESS_KEY_ID"; secret="$AWS_SECRET_ACCESS_KEY"
    _reject_temporary_creds "$id" "${AWS_SESSION_TOKEN:-}"
  elif [ "${ASSUME_YES:-0}" != 1 ] && _have_tty; then
    id="$(ask "New AWS access key ID" "")"
    [ -z "$id" ] || secret="$(ask_secret "New AWS secret access key (hidden)")"
  fi
  [ -n "$id" ] && [ -n "$secret" ] ||
    die "both a key ID and a secret are required (non-interactive: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY) — .env was NOT changed"
  _reject_temporary_creds "$id"
  old="$(get_env AWS_ACCESS_KEY_ID)"
  [ "$id" != "$old" ] || warn "that is the key already in .env — re-verifying it anyway"
  region="$(get_env AWS_REGION_NAME)"; region="${region:-us-east-1}"
  log "verifying the new key with AWS before changing anything…"
  errf="$(mktemp)"
  if ! arn="$(aws_run "$id" "$secret" "$region" sts get-caller-identity --query Arn --output text 2>"$errf")"; then
    arn="$(tr '\n' ' ' < "$errf")"; rm -f "$errf"
    die "AWS rejected the new key: $arn — .env was NOT changed; the old key is still in use. Check the values and re-run ./stack rotate-aws"
  fi
  rm -f "$errf"
  log "new key authenticated as $arn"
  # Bedrock itself, before switching (free: a deliberately invalid request): a key without Bedrock access never
  # replaces a working one.
  _prove_bedrock "$region" ".env was NOT changed; the old key is still in use" "$id" "$secret" || exit 1
  old_auth="$(get_env AWS_AUTH)"; old_secret="$(get_env AWS_SECRET_ACCESS_KEY)"
  set_env_batch AWS_ACCESS_KEY_ID "$id" AWS_SECRET_ACCESS_KEY "$secret" -AWS_AUTH ''
  log "restarting LiteLLM with the new key…"
  dc up -d --wait litellm ||   # env changed → the container is recreated with the new key
    _restore_aws_settings "$old_auth" "$old" "$old_secret" "LiteLLM did not come up with the new key"
  ( cmd_test ) || _restore_aws_settings "$old_auth" "$old" "$old_secret" "the smoke test failed with the new key"
  if [ -n "$old" ]; then log "rotated. Remember to deactivate the old key ($old) in IAM, or ask your AWS admin to."
  else log "now using the access key $(printf '%s' "$id" | cut -c1-8)… instead of the instance role."; fi
}

cmd_uninstall() {
  local target="$HOME/.local/bin/devos-claude"
  warn "This deletes all containers AND data volumes (chats, knowledge bases, files, spend history) and this install's built images."
  # (the project's name before v0.25.0 is taken too)
  case "$(ask "Type '$PRODUCT_SLUG' to confirm" "")" in "$PRODUCT_SLUG" | "$PRODUCT_LEGACY_NAME") ;; *) die "aborted — nothing was removed" ;; esac
  if confirm "Take a backup first?"; then cmd_backup; fi
  ! declare -F xl_bg_stop >/dev/null || xl_bg_stop   # (lib/explabs.sh: a background read of the model details)
  dc down -v --remove-orphans
  localgit_uninstall_cleanup   # lib/localgit.sh: its repositories' volume, also while it is off (compose does not see it then)
  code_uninstall_cleanup       # lib/code.sh: its network, socket volume and image (before the terminal's)
  terminal_uninstall_cleanup   # lib/terminal.sh: its volume, networks and image, also while it is off
  projects_uninstall_cleanup   # lib/projects.sh: the generated files (the list stays; the folders are never touched)
  ! declare -F local_mlx_uninstall >/dev/null || local_mlx_uninstall --models   # lib/local_models.sh: the MLX server agent, its venv and models
  ! declare -F runtimes_uninstall_all >/dev/null || runtimes_uninstall_all     # lib/runtimes.sh: the runtimes it installed and their models (an Ollama of yours stays)
  sessions_uninstall_cleanup   # lib/sessions.sh: the Code page's request folder and the looks (what you allowed stays)
  local_builds_remove          # lib/images.sh: <project>/portal:local, …:previous, by exact name (never a prune)
  ! helper_installed || helper_uninstall
  if [ "$(readlink "$target" 2>/dev/null)" = "$STACK_DIR/bin/devos-claude" ]; then rm -f "$target"; log "removed the $target link"; fi
  # its old name: the link to this checkout's shim (bin/claude-bedrock); another checkout's or a file of yours stays
  target="$HOME/.local/bin/claude-bedrock"
  if [ "$(readlink "$target" 2>/dev/null)" = "$STACK_DIR/bin/claude-bedrock" ]; then rm -f "$target"; log "removed the $target link"; fi
  log "removed. .env and backups/ were kept (they contain secrets) — delete this folder yourself if you're done."
  # devos-claude's own Claude Code folder (settings, plugins, sessions): yours, possibly shared by other copies.
  # The default one and the one CLAUDE_BEDROCK_CONFIG_DIR names in this shell — each only as lib/claude_config.sh
  # resolves it in lean mode, so this never points at ~/.claude, your home folder or / ("delete it yourself").
  local cb_dir cb_seen='' cb_env
  for cb_env in "${CLAUDE_BEDROCK_CONFIG_DIR:-}" ''; do
    cb_dir="$(CLAUDE_BEDROCK_USE_MY_CONFIG=0 CLAUDE_BEDROCK_CONFIG_DIR="$cb_env" claude_config_resolve 2>/dev/null &&
      [ "$CB_CONFIG_MODE" = lean ] && printf '%s' "$CB_CONFIG_DIR")" || continue
    [ -n "$cb_dir" ] && [ -d "$cb_dir" ] && [ "$cb_dir" != "$cb_seen" ] || continue
    cb_seen="$cb_dir"
    log "$(claude_config_show "$cb_dir") (devos-claude's Claude Code settings and sessions) was kept — delete it yourself if you're done."
  done
}

# One update/rollback/clean/restore/setup at a time (.state/lock).
. "$STACK_DIR/lib/lock.sh"
# Optional OpenRouter provider (setup step, ./stack openrouter, costs/models/summary sections).
. "$STACK_DIR/lib/openrouter.sh"
# Optional Experiential Labs gateway (xl/… models; Settings and ./stack config set EXPLABS_API_KEY; status lines).
. "$STACK_DIR/lib/explabs.sh"
# The models of the Code page and devos-claude: litellm/code-models.tsv and their bn_* model_info (render_config).
. "$STACK_DIR/lib/code_models.sh"
# The model browser's lists (Settings › Models & providers › Browse models): ./stack models browse (lib/model_browser.sh).
. "$STACK_DIR/lib/model_browser.sh"
# Local models (Hugging Face GGUFs on Docker Model Runner or Ollama, served through LiteLLM): ./stack local-models.
. "$STACK_DIR/lib/local_models.sh"
# The model runtimes DevOS ADE installs, runs and watches itself (Ollama): ./stack runtimes.
. "$STACK_DIR/lib/runtimes.sh"
# Optional speech-to-text for Open WebUI's voice calls (setup step, ./stack stt, costs/summary lines).
. "$STACK_DIR/lib/stt.sh"
# Web search for Claude Code's WebSearch on every model (LiteLLM's web search interception; ./stack websearch).
. "$STACK_DIR/lib/websearch.sh"
# The built-in local git server (Forgejo): its container, certificate, owner account and the Code page's host for it.
. "$STACK_DIR/lib/localgit.sh"
# Image cleanup and disk usage (./stack update, ./stack clean, ./stack status).
. "$STACK_DIR/lib/images.sh"
# The core services' versions (./stack versions, status, Settings) and the digest check at the end of ./stack update.
. "$STACK_DIR/lib/versions.sh"
# The slow parts of setup and an update, side by side and timed: image downloads, builds, the sandboxes' images.
. "$STACK_DIR/lib/steps.sh"
# Installed version, the portal's release check, and the .state folders the portal mounts.
. "$STACK_DIR/lib/version.sh"
# origin follows the project's repository to its new name on GitHub (./stack update, once).
. "$STACK_DIR/lib/repo_rename.sh"
# ./stack rollback (back to the version before the last update).
. "$STACK_DIR/lib/rollback.sh"
# Local container health: restart counts, exit codes and unhealthy transitions for Activity (JON-440 G4; never sent).
. "$STACK_DIR/lib/health.sh"
# The optional host helper (one-click Update / Rollback / Clean from the portal): ./stack helper.
. "$STACK_DIR/lib/helper.sh"
# Settings (./stack config, ./stack restart, the snapshot for the portal) and the helper's settings requests.
. "$STACK_DIR/lib/settings.sh"
# LiteLLM's model list changed without a restart (its model admin API: a settings change, a catalog read again).
. "$STACK_DIR/lib/litellm_live.sh"
. "$STACK_DIR/lib/settings_helper.sh"
# EC2 instance role, ./stack serve (keep the Mac awake), ./stack ssh-info.
. "$STACK_DIR/lib/host.sh"
# Remote access from your devices (./stack remote; Tailscale sidecar, remote Caddy site).
. "$STACK_DIR/lib/remote.sh"
# The browser terminal (./stack terminal; Claude Code in a sandbox container, the portal's Terminal tab; on by default).
. "$STACK_DIR/lib/terminal.sh"
# The Code page (./stack code; Claude Code with a chat and files, in the terminal's sandbox; the Code tab; on by default).
. "$STACK_DIR/lib/code.sh"
# Folders of this computer as Code page projects (./stack project): their mounts into the sandbox.
. "$STACK_DIR/lib/projects.sh"
# Your Claude Code and devos-claude sessions on this computer, copied into the sandbox (./stack sessions; the helper's
# Code page requests).
. "$STACK_DIR/lib/sessions.sh"
# Bring your setup: your Claude Code setup and Git name and email on this computer, copied into the sandbox (./stack
# sessions config).
. "$STACK_DIR/lib/sessions_config.sh"
# Its Git hosts from a gh / glab login on this computer (./stack git-host import).
. "$STACK_DIR/lib/githost.sh"
# Your AI subscriptions' own tools in the sandbox (./stack subscriptions): what each says of its own login.
. "$STACK_DIR/lib/subscriptions.sh"
# devos-claude's own Claude Code config folder (./stack uninstall names it; bin/devos-claude uses it).
. "$STACK_DIR/lib/claude_config.sh"
