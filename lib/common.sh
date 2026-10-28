# shellcheck shell=bash
# Shared helpers for ./stack and bin/devos-claude. Must stay bash 3.2-compatible (macOS default shell).

# C locale for every tool we run: macOS awk/printf honour LC_NUMERIC, so a German locale would turn
# 0.0000044 into "0,0000044" in config.yaml and "$4,40" in price labels.
# The caller's locale is remembered so restore_caller_locale can hand it back to user programs.
if [ -z "${_CALLER_LC_ALL_CAPTURED:-}" ]; then
  _CALLER_LC_ALL_CAPTURED=1; _CALLER_LC_ALL_SET="${LC_ALL+1}"; _CALLER_LC_ALL="${LC_ALL-}"
fi
export LC_ALL=C

# restore_caller_locale — undo the C locale before exec'ing a user program (e.g. devos-claude → claude).
restore_caller_locale() {
  if [ -n "$_CALLER_LC_ALL_SET" ]; then export LC_ALL="$_CALLER_LC_ALL"; else unset LC_ALL; fi
}

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${ENV_FILE:-$STACK_DIR/.env}"
STATE_DIR="${STATE_DIR:-$STACK_DIR/.state}"
CATALOG="${CATALOG:-$STACK_DIR/catalog/models.tsv}"
# The project's names (PRODUCT_NAME, PRODUCT_SLUG, PRODUCT_REPO, and its names before v0.25.0).
. "$STACK_DIR/lib/brand.sh"
# shellcheck disable=SC2034  # used by lib/commands.sh
AWS_CLI_IMAGE="amazon/aws-cli:2.37.12"

# color_on FD -> 0 if output on FD should be coloured: a TTY, and NO_COLOR (https://no-color.org) unset/empty.
# Checked at call time, so a function whose stdout is redirected decides for where it really writes.
color_on() { [ -z "${NO_COLOR:-}" ] && [ -t "$1" ]; }

# C_* are for messages on stderr (log/warn/die and progress lines).
if color_on 2; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_OFF=''
fi

# out_colors -> sets O_RED O_GRN O_YEL O_OFF for text written to stdout (tables, summary)
# shellcheck disable=SC2034  # read by the callers, which declare them local
out_colors() {
  if color_on 1; then O_RED=$'\033[31m'; O_GRN=$'\033[32m'; O_YEL=$'\033[33m'; O_OFF=$'\033[0m'
  else O_RED=''; O_GRN=''; O_YEL=''; O_OFF=''; fi
}

# _SIGNAL_HOOK — a function run on INT/TERM (with the signal's name) before the script ends: setup sets one, which says
# what was done, what still runs and how to go on, then exits. Empty: the signal's default (the script just ends).
_SIGNAL_HOOK=''
# _signal_traps_restore — INT/TERM back to the hook (or the default), after a trap of their own
_signal_traps_restore() {
  trap - INT TERM
  if [ -n "$_SIGNAL_HOOK" ]; then
    # shellcheck disable=SC2064  # the hook's name now
    trap "$_SIGNAL_HOOK INT" INT
    # shellcheck disable=SC2064
    trap "$_SIGNAL_HOOK TERM" TERM
  fi
}

# _cleanup_on_signal FILE... — on INT/TERM remove FILEs, then hand the signal on: to _SIGNAL_HOOK, else re-raise it
# (callers end it with _signal_traps_restore once the files are gone).
_cleanup_on_signal() {
  local q; q="$(printf '%q ' "$@")"
  # shellcheck disable=SC2064  # expand the file list now
  trap "rm -f $q; trap - INT; ${_SIGNAL_HOOK:+$_SIGNAL_HOOK INT; }kill -INT \$\$" INT
  # shellcheck disable=SC2064
  trap "rm -f $q; trap - TERM; ${_SIGNAL_HOOK:+$_SIGNAL_HOOK TERM; }kill -TERM \$\$" TERM
}

# on_exit FUNC / off_exit FUNC — cleanups that must run however the script ends (die, error, Ctrl-C, kill).
# Several can be active at once (the LiteLLM config restore during setup's probe, the portal session file,
# a partial backup), so they share one EXIT trap instead of replacing each other's.
# A subshell inherits the list but not the trap: its first on_exit/off_exit starts a list of its own
# (BASH_SUBSHELL), so a subshell's exit never runs its parent's hooks (the lock, a partial backup, a config restore).
_EXIT_HOOKS=' '; _EXIT_LEVEL=0
# _shell_level -> _LEVEL: how deep a subshell this is. bash 3.2 says 0 in the EXIT trap of a $( ) subshell, so the
# hooks use the level their list was built at (a variable, not $(...): that would be a subshell itself)
_shell_level() { if [ -n "${_IN_EXIT_HOOKS:-}" ]; then _LEVEL="$_EXIT_LEVEL"; else _LEVEL="$BASH_SUBSHELL"; fi; }
# (_EXIT_RC: the status the script ends with, for hooks that report it; 0 also after a signal without a trap)
_run_exit_hooks() { _EXIT_RC=$?; local h; _IN_EXIT_HOOKS=1; for h in $_EXIT_HOOKS; do "$h" || true; done; }
_exit_hooks_here() { _shell_level; [ "$_EXIT_LEVEL" = "$_LEVEL" ] || { _EXIT_HOOKS=' '; _EXIT_LEVEL="$_LEVEL"; }; }
on_exit() {
  _exit_hooks_here
  case "$_EXIT_HOOKS" in *" $1 "*) ;; *) _EXIT_HOOKS="$_EXIT_HOOKS$1 " ;; esac
  trap _run_exit_hooks EXIT
}
# The trap itself goes once no hook is left: bash 3.2 can report status 0 from an EXIT trap after a fatal error.
off_exit() {
  _exit_hooks_here
  _EXIT_HOOKS="${_EXIT_HOOKS/ $1 / }"
  [ "$_EXIT_HOOKS" != ' ' ] || trap - EXIT
}

log()  { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn() { printf '%s!!%s  %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
# test_url_ignored NAME WHAT — a test suite's address (BEDROCK_NOW_TEST_OPENROUTER_API, BEDROCK_NOW_TEST_STT_API,
# BEDROCK_NOW_TEST_EXPLABS_API) found without BEDROCK_NOW_TESTING=1: not used, and said (lib/openrouter.sh, lib/stt.sh,
# lib/explabs.sh: only the test suite may change where WHAT, a key, goes)
test_url_ignored() { warn "$1 in your shell is ignored: only the test suite (BEDROCK_NOW_TESTING=1) may change where $2 goes"; }
die()  { _BN_DIE_MSG="$*"; printf '%sxx%s  %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }   # (the message: for Home, lib/lock.sh)

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1${2:+ — $2}"; }

# _with_deadline SECS CMD… -> CMD's status, or 124 when it had not ended SECS seconds later: then it is ended — TERM to
# its process group, KILL 2 s later — and so is anything it started. A watchdog on this computer, for a probe into the
# sandbox: a timeout inside the container binds nothing there (a sandbox process can stop it, SIGSTOP), this does.
# CMD (a command or a function) gets /dev/null as stdin; its stdout and stderr are the caller's. Works under
# set -euo pipefail and bash 3.2 (macOS has no timeout(1)); kills by PID — its own process group's — only.
_with_deadline() {
  local secs="$1" rc=0 dir flag
  shift
  # (the watcher says it fired by making a file — a status alone could not tell a deadline from the command's own —
  # in a folder of this run's own: mktemp -d, mode 700, so nobody else can plant a link where it writes; removed when
  # this returns — if ./stack itself is killed meanwhile, an empty bn-deadline.* folder, maybe with an empty marker,
  # stays: no process outlives it)
  dir="$(mktemp -d "${TMPDIR:-/tmp}/bn-deadline.XXXXXX")" || { warn "cannot make a temporary folder for a deadline"; return 125; }
  flag="$dir/fired"
  { (
    set +e +u +o pipefail
    set -m                                  # (CMD, then the watcher: each in a process group of its own)
    "$@" </dev/null 2>&3 3>&- &
    pid=$!
    ( sleep "$secs"; : > "$flag"; kill -TERM -- "-$pid"; sleep 2; kill -KILL -- "-$pid" ) </dev/null >/dev/null 2>&1 3>&- &
    w=$!
    set +m
    wait "$pid"; r=$?
    kill -KILL -- "-$pid" 2>/dev/null       # (whatever of its group outlived it)
    kill -KILL -- "-$w" 2>/dev/null; wait "$w" 2>/dev/null   # (the watcher and its sleep, at once)
    exit "$r"
  ) 2>/dev/null; } 3>&2 || rc=$?
  if [ -e "$flag" ]; then rc=124; fi
  rm -rf -- "$dir"
  return "$rc"
}
# PROBE_DEADLINE_S: how long ./stack waits on one probe into the sandbox (_probe) before it says it could not check
PROBE_DEADLINE_S="${PROBE_DEADLINE_S:-30}"
# _probe CMD… -> CMD's output, under _with_deadline PROBE_DEADLINE_S; after the deadline its output is "couldn't check
# (timed out after N s)" — never what a check passes on. Always 0.
_probe() {
  local rc=0 out
  out="$(_with_deadline "$PROBE_DEADLINE_S" "$@")" || rc=$?
  if [ "$rc" = 124 ]; then printf "couldn't check (timed out after %s s)" "$PROBE_DEADLINE_S"; else printf '%s' "$out"; fi
  return 0
}

# --- .env access. Never `source` the file: values can contain $, quotes, etc. ---

# get_env KEY -> value (empty if unset). Last occurrence wins, like docker compose.
get_env() {
  [ -f "$ENV_FILE" ] || return 0
  K="$1" awk 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2) } END { printf "%s", v }' "$ENV_FILE"
}

# env_value_problem VALUE -> why set_env would refuse VALUE (nothing, status 1, when it is fine)
env_value_problem() {
  local tab=$'\t'
  case "$1" in
    *$'\n'*) echo "contains a newline" ;;
    *'$'* | *'"'* | *"'"* | *'`'*) echo "contains \$, a quote or a backtick, which docker compose would interpret — use a different value" ;;
    *" #"* | *"$tab#"*) echo "contains whitespace followed by #, which docker compose reads as a comment" ;;
    [[:space:]]* | *[[:space:]]) echo "has leading or trailing whitespace" ;;
    *) return 1 ;;
  esac
}

# set_env KEY VALUE -> writes/replaces KEY in $ENV_FILE atomically, keeps mode 600.
# Values must survive docker compose's .env parsing literally, so anything compose would
# interpolate or treat as quoting/comment syntax is rejected (generated secrets are hex,
# AWS keys are [A-Za-z0-9+/], emails are fine; backslashes pass through literally).
set_env() {
  local tmp
  _env_value_check "$1" "$2"
  [ -f "$ENV_FILE" ] || { : > "$ENV_FILE"; }
  chmod 600 "$ENV_FILE"
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")" || die "set_env: cannot create temp file next to $ENV_FILE"
  chmod 600 "$tmp"
  # Values go through ENVIRON, not -v, so awk doesn't interpret backslashes.
  if ! K="$1" V="$2" awk '
    index($0, ENVIRON["K"] "=") == 1 { if (!done) print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }' "$ENV_FILE" > "$tmp" || ! mv "$tmp" "$ENV_FILE"; then
    rm -f "$tmp"
    die "set_env: failed to update $ENV_FILE"
  fi
}

# _env_value_check KEY VALUE — dies unless docker compose reads VALUE literally (set_env's rules)
_env_value_check() {
  local why
  if why="$(env_value_problem "$2")"; then die "set_env: value for $1 $why"; fi
}

# set_env_batch KEY VALUE [KEY VALUE…] -> every pair in ONE atomic write (mode 600 kept); "-KEY ''" removes KEY's
# lines. Every value is checked first, so nothing is written unless all pass. Values reach awk through variables
# exported in a subshell, never through a command line.
set_env_batch() {
  local tmp n=0 i=0 k a=("$@")
  [ $(($# % 2)) -eq 0 ] || die "set_env_batch: KEY VALUE pairs expected"
  while [ "$i" -lt "$#" ]; do
    k="${a[$i]#-}"
    case "$k" in '' | *[!A-Za-z0-9_]*) die "set_env_batch: bad key name" ;; esac
    _env_value_check "$k" "${a[$((i + 1))]}"
    i=$((i + 2))
  done
  [ -f "$ENV_FILE" ] || { : > "$ENV_FILE"; }
  chmod 600 "$ENV_FILE"
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")" || die "set_env: cannot create temp file next to $ENV_FILE"
  chmod 600 "$tmp"
  if ! (
    while [ $# -gt 0 ]; do
      case "$1" in -*) export "SETB_K$n=${1#-}" "SETB_D$n=1" ;; *) export "SETB_K$n=$1" "SETB_D$n=" ;; esac
      export "SETB_V$n=$2"; n=$((n + 1)); shift 2
    done
    export SETB_N="$n"
    awk 'BEGIN { n = ENVIRON["SETB_N"] + 0; for (i = 0; i < n; i++) { k[i] = ENVIRON["SETB_K" i]; v[i] = ENVIRON["SETB_V" i]; d[i] = ENVIRON["SETB_D" i] } }
      { for (i = 0; i < n; i++) if (index($0, k[i] "=") == 1) { if (!d[i] && !w[i]) print k[i] "=" v[i]; w[i] = 1; next }; print }
      END { for (i = 0; i < n; i++) if (!d[i] && !w[i]) print k[i] "=" v[i] }' "$ENV_FILE"
  ) > "$tmp" || ! mv "$tmp" "$ENV_FILE"; then
    rm -f "$tmp"; die "set_env: failed to update $ENV_FILE"
  fi
}

# unset_env KEY -> removes every KEY= line from $ENV_FILE atomically (mode 600 kept); no-op if absent.
unset_env() {
  local tmp
  [ -f "$ENV_FILE" ] || return 0
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")" || die "unset_env: cannot create temp file next to $ENV_FILE"
  chmod 600 "$tmp"
  if ! K="$1" awk 'index($0, ENVIRON["K"] "=") != 1' "$ENV_FILE" > "$tmp" || ! mv "$tmp" "$ENV_FILE"; then
    rm -f "$tmp"; die "unset_env: failed to update $ENV_FILE"
  fi
}

# ensure_env KEY VALUE -> set only if currently empty (makes setup idempotent).
ensure_env() { [ -n "$(get_env "$1")" ] || set_env "$1" "$2"; }

# gen_hex NBYTES -> 2*NBYTES hex chars (openssl is a checked prerequisite).
gen_hex() { openssl rand -hex "${1:-32}"; }

# json_get FIELD < json -> value of the first "FIELD": "string" pair (we avoid a jq dependency).
# Limitations: string values only, no escaped quotes, no commas/braces inside the value;
# nesting is ignored, so the first occurrence in document order wins. FIELD: [A-Za-z0-9_].
json_get() {
  case "$1" in '' | *[!A-Za-z0-9_]*) die "json_get: invalid field name: $1" ;; esac
  tr ',{}' '\n\n\n' | sed -n 's/^[[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# json_num FIELD < json -> the first "FIELD": <number> value, as written (empty if absent or null).
# Same limitations as json_get (first occurrence in document order wins).
json_num() {
  case "$1" in '' | *[!A-Za-z0-9_]*) die "json_num: invalid field name: $1" ;; esac
  tr ',{}' '\n\n\n' | sed -n 's/^[[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9.eE+-]*\).*/\1/p' | head -n 1
}

# date_to_epoch YYYY-MM-DD -> seconds since epoch at 00:00 UTC that day (BSD date, then GNU/BusyBox).
date_to_epoch() {
  case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null || TZ=UTC date -d "$1" +%s 2>/dev/null
}

# valid_region REGION -> 0 if it looks like an AWS region id (lowercase letters, digits, dashes).
# (POSIX classes, not a-z: bash 3.2 ranges follow locale collation and would accept uppercase.)
valid_region() { case "$1" in '' | *[![:lower:][:digit:]-]*) return 1 ;; esac; }

# --- prompts (respect ASSUME_YES=1 for --yes / non-interactive) ---
_have_tty() { { : > /dev/tty; } 2>/dev/null; }
_stdout_tty() { [ -t 1 ]; }   # stdout is a terminal (not a pipe or a log file)
ask() { # ask "Prompt" "default" -> answer on stdout
  local ans=''
  if [ "${ASSUME_YES:-0}" = 1 ] || ! _have_tty; then printf '%s\n' "${2:-}"; return; fi
  printf '%s%s: ' "$1" "${2:+ [$2]}" > /dev/tty
  IFS= read -r ans < /dev/tty || true
  printf '%s\n' "${ans:-${2:-}}"
}
ask_secret() { # ask_secret "Prompt" -> answer on stdout, no echo (echo restored on Ctrl-C)
  local ans='' old_int old_term
  _have_tty || die "$1: no terminal; set it via environment instead"
  old_int="$(trap -p INT)"; old_term="$(trap -p TERM)"
  # (it runs in a $(...) subshell: the Ctrl-C reaches the calling shell too, whose own trap or hook then runs)
  trap 'stty echo < /dev/tty 2>/dev/null; printf "\n" > /dev/tty; exit 130' INT TERM
  printf '%s: ' "$1" > /dev/tty
  stty -echo < /dev/tty; IFS= read -r ans < /dev/tty || true; stty echo < /dev/tty
  trap - INT TERM
  [ -z "$old_int" ] || eval "$old_int"
  [ -z "$old_term" ] || eval "$old_term"
  printf '\n' > /dev/tty
  printf '%s\n' "$ans"
}
confirm() { # confirm "Question?" -> 0 yes / 1 no (default yes)
  case "$(ask "$1 [Y/n]" "y")" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

# --- docker compose wrapper pinned to this checkout ---
DEFAULT_PROJECT=bedrock-now   # = `name:` in compose.yaml

# project_name -> this checkout's Compose project: COMPOSE_PROJECT_NAME from .env (setup stores it there for a
# second copy), else the default. A shell COMPOSE_PROJECT_NAME never repoints an existing checkout.
project_name() { local p; p="$(get_env COMPOSE_PROJECT_NAME)"; printf '%s\n' "${p:-$DEFAULT_PROJECT}"; }

# env_file_display -> this checkout's .env as a person would type it: $HOME shortened to ~ (the portal's login
# page names it, so a second copy's password is looked up in the right folder)
env_file_display() {
  local h="${HOME%/}" f="$ENV_FILE"
  if [ -n "$h" ]; then case "$f" in "$h"/*) f="~${f#"$h"}" ;; esac; fi
  printf '%s\n' "$f"
}

# dc ARGS... — docker compose for this checkout. -p and the COMPOSE_PROJECT_NAME seen by compose's own
# interpolation are both forced to project_name, so a stray shell value is ignored (with one warning).
dc() {
  local p; p="$(project_name)"
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ] && [ "$COMPOSE_PROJECT_NAME" != "$p" ] && [ -z "${_DC_PROJECT_WARNED:-}" ]; then
    warn "COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME in your shell is ignored: this checkout is project '$p' (from .env or the default)"
    _DC_PROJECT_WARNED=1
  fi
  # Compose lets shell variables beat --env-file: OpenRouter, Experiential Labs, speech-to-text and the search keys are
  # opt-in via .env only, so an OPENROUTER_*, EXPLABS_*, STT_* or WEBSEARCH_* in your shell never switches them on (or
  # keeps them on after a remove).
  # (A subshell, not `env -u`: same effect on docker's environment, and tests can still stub docker.)
  # The same for AWS: .env decides the key (or none, with AWS_AUTH=instance-role) and the region, never the shell
  # (./stack warns once per command when your shell's key differs: warn_shell_aws_ignored in lib/host.sh).
  local f=() o
  # the portal's docs index (compose.portal-docs.yaml): only where this Docker Compose reads additional_contexts
  if compose_reads_contexts; then f+=(-f "$STACK_DIR/compose.portal-docs.yaml"); fi
  for o in $(compose_overlays); do
    case "$o" in @projects) f+=(-f "$STATE_DIR/projects/compose.yaml") ;; *) f+=(-f "$STACK_DIR/$o") ;; esac
  done
  # The Code page's container mounts the project folders' public list (compose.code.yaml: the folder, read-only, never
  # created by Docker): there before compose needs it (lib/projects.sh writes its roots.json)
  if flag_on "$(get_env CODE_ENABLED)"; then mkdir -p "$STATE_DIR/projects/public" 2>/dev/null && chmod 700 "$STATE_DIR/projects" 2>/dev/null || true; fi
  # Bedrock speech-to-text: its container is in the "stt" profile (lib/stt.sh), so down/ps/logs include it too.
  if [ "${_STT_PROFILE:-}" = 1 ] || [ "$(get_env STT_PROVIDER)" = bedrock ]; then f+=(--profile stt); fi
  # The built-in SearXNG (lib/websearch.sh): in the "searxng" profile, on unless WEBSEARCH_SEARXNG_BUILTIN=off
  if [ "${_WS_SEARXNG_PROFILE:-}" = 1 ] || ! flag_off "$(get_env WEBSEARCH_SEARXNG_BUILTIN)"; then f+=(--profile searxng); fi
  # The built-in git server, Forgejo (lib/localgit.sh): in the "forgejo" profile, on unless LOCALGIT=off
  if [ "${_LG_PROFILE:-}" = 1 ] || ! flag_off "$(get_env LOCALGIT)"; then f+=(--profile forgejo); fi
  # the checksums of the configuration files the services read only at their start (config_sums, below): every compose
  # call passes the same ones, so none recreates a service whose files did not change, and each recreates one whose did
  local policy sums; policy="$(claude_policy)"; sums="$(config_sums "$policy")"
  # The browser terminal too: an exported TERMINAL_WORKSPACE must never decide what the container sees.
  ( unset OPENROUTER_API_KEY OPENROUTER_MODELS OPENROUTER_MAX_MODELS EXPLABS_API_KEY EXPLABS_MODELS STT_PROVIDER STT_API_KEY STT_MODEL OWUI_STT_ENGINE \
      WEBSEARCH_TAVILY_API_KEY WEBSEARCH_BRAVE_API_KEY WEBSEARCH_PERPLEXITY_API_KEY WEBSEARCH_SEARXNG_SECRET WEBSEARCH_SEARXNG_BUILTIN \
      LOCALGIT LOCALGIT_ADMIN_PASSWORD GIT_HOST GIT_ORIGIN BN_LOCALGIT_MODE BN_LOCALGIT_TLS \
      OWUI_STT_BASE_URL STT_BEDROCK_MODEL COMPOSE_PROFILES \
      AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION_NAME \
      TERMINAL_ENABLED TERMINAL_WORKSPACE TERMINAL_EGRESS TERMINAL_EGRESS_ALLOW TERMINAL_EGRESS_DENY TERMINAL_HOST TERMINAL_UID TERMINAL_GID TERMINAL_MEM_LIMIT \
      REMOTE_TERMINAL REMOTE_TERMINAL_HOST CODE_ENABLED CODE_HOST CODE_PROXY_SECRET REMOTE_CODE_HOST PREVIEW_DOMAIN PREVIEW_PROXY_SECRET CODE_ALLOW_BYPASS \
      CODE_AUTO_MODE TERMINAL_AUTO_MODE GIT_GITHUB_CLIENT_ID GIT_GITHUB_APP_SLUG GIT_GITLAB_CLIENT_ID CODE_CLAUDE_PLAN CODE_CHAT_KEY
    # (and the BN_*_SUM of config_sums: only ./stack sets them, never this shell)
    while IFS='=' read -r o p_sum; do [ -z "$o" ] || export "$o=$p_sum"; done <<SUMS
$sums
SUMS
    # which of terminal/managed/*.json the sandbox gets as Claude Code's managed settings (read-only): from .env alone
    TERMINAL_CLAUDE_POLICY="$policy" BN_PROJECTS_PUBLIC="$STATE_DIR/projects/public" \
    BN_LOCALGIT_TLS="$STATE_DIR/localgit/tls" BN_LOCALGIT_MODE="$(flag_off "$(get_env LOCALGIT)" && echo off || echo on)" \
    BEDROCK_NOW_ENV_DISPLAY="$(env_file_display)" COMPOSE_PROJECT_NAME="$p" docker compose -p "$p" --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.yaml" ${f[@]+"${f[@]}"} \
      --env-file "$ENV_FILE" "$@" )
}

# --- configuration files read at a service's start: their checksums, for compose's own change detection ---
# Compose recreates a service's container only when the service's configuration (compose files, .env's values) or its
# image changed — never for a mounted file's content. So each file a service reads only when it starts has its
# checksum in that service's environment (compose files: BN_CONFIG_SUM, or SearXNG's BN_SETTINGS_SUM): a file ./stack
# renders again (LiteLLM's config.yaml, SearXNG's settings.yml) or an update brings (the Caddyfile, LiteLLM's hook, the
# sandboxes' managed settings) then changes exactly that service's configuration, and compose recreates it — and only
# it — at the next `up` that includes it. setup and ./stack update rely on that instead of recreating services each time.
#   BN_LITELLM_CONFIG_SUM    litellm           litellm/config.yaml and its hook, bn_hooks.py (the hook reads
#                                              code-models.tsv and web-search.json again by itself when they change)
#   BN_CADDY_CONFIG_SUM      caddy             caddy/Caddyfile and the caddy/*.caddy it imports (Caddy's admin API is off:
#                                              it reads them only at start)
#   BN_GATEWAY_CONFIG_SUM    terminal-gateway  caddy/terminal-gateway.caddy and the localgit-gateway-*.caddy it imports
#   BN_SEARXNG_SETTINGS_SUM  searxng           searxng/settings.yml (the built-in web search)
#   BN_TERMINAL_POLICY_SUM   terminal          terminal/managed/<policy>.json, Claude Code's managed settings (a mount of
#                                              one file: once git replaced it, a running container no longer sees it)
#   BN_CHAT_POLICY_SUM       subs-chat         terminal/managed/chat.json, the same for Chat's sandbox
# Not here, as each is read again where it is used: the portal's litellm/, catalog/ and .state files, the Code page's
# project list, Tailscale's serve.json (containerboot watches it); postgres/init.sql is read once, by a new database.
# config_sums [POLICY] -> NAME=SUM lines (POLICY: claude_policy's answer, when the caller has it already)
config_sums() {
  local policy="${1:-}" c=() g
  [ -n "$policy" ] || policy="$(claude_policy)"
  for g in "$STACK_DIR"/caddy/*.caddy; do case "${g##*/}" in terminal-gateway.caddy | localgit-gateway-*.caddy) ;; *) c+=("${g##*/}") ;; esac; done
  printf 'BN_LITELLM_CONFIG_SUM=%s\n' "$(litellm_compose_sum)"
  printf 'BN_CADDY_CONFIG_SUM=%s\n' "$(files_sum "$STACK_DIR/caddy" Caddyfile ${c[@]+"${c[@]}"})"
  printf 'BN_GATEWAY_CONFIG_SUM=%s\n' "$(files_sum "$STACK_DIR/caddy" terminal-gateway.caddy localgit-gateway-on.caddy localgit-gateway-off.caddy)"
  # (as v0.31.0 gave it: the checksum alone, so an update to this version leaves an unchanged SearXNG running)
  g=''; [ ! -f "$STACK_DIR/searxng/settings.yml" ] || g="$(cksum < "$STACK_DIR/searxng/settings.yml" | awk '{ print $1 }')"
  printf 'BN_SEARXNG_SETTINGS_SUM=%s\n' "$g"
  printf 'BN_TERMINAL_POLICY_SUM=%s\n' "$(files_sum "$STACK_DIR/terminal/managed" "$policy.json")"
  printf 'BN_CHAT_POLICY_SUM=%s\n' "$(files_sum "$STACK_DIR/terminal/managed" chat.json)"
}
# LiteLLM's model list changes without a restart (lib/litellm_live.sh): once it has taken a config.yaml live, that
# file is what it serves although it did not start with it. litellm_live_sum_file then holds "SUM BASE": the checksum of
# that config.yaml (with its hook) and the BN_CONFIG_SUM of the container that took it. While config.yaml is still
# that one, BN_LITELLM_CONFIG_SUM stays BASE: Compose recreates LiteLLM for a config it does not serve yet, never for one
# it was given live. Any other config.yaml (rendered and not given to it live) has its own checksum again.
litellm_live_sum_file() { printf '%s\n' "$STATE_DIR/litellm-live.sum"; }
litellm_config_sum_now() { files_sum "$STACK_DIR/litellm" config.yaml bn_hooks.py; }
litellm_compose_sum() {
  local s live='' base=''
  s="$(litellm_config_sum_now)"
  [ ! -r "$(litellm_live_sum_file)" ] || read -r live base < "$(litellm_live_sum_file)" 2>/dev/null || true
  if [ -n "$s" ] && [ "$live" = "$s" ] && [ -n "$base" ]; then s="$base"; fi
  printf '%s\n' "$s"
}
# files_sum DIR NAME... -> "CRC-BYTES" (cksum) of the names and contents of DIR's files NAME… that exist, in the order
# given; nothing when none exists
files_sum() {
  local d="$1" n=() x
  shift
  for x in "$@"; do [ ! -f "$d/$x" ] || n+=("$x"); done
  [ ${#n[@]} -gt 0 ] || return 0
  ( cd "$d" && cksum "${n[@]}" 2>/dev/null ) | cksum | awk '{ print $1 "-" $2 }'
}

# SETUP_BUILT — the images setup built side by side in this command (lib/commands.sh setup_build_images: " portal
# shared-mcp … "): each one's own step takes it as it is. built_now SERVICE -> 0 for those.
SETUP_BUILT=''; _OWUI_TRY=''
built_now() { case "$SETUP_BUILT" in *" $1 "*) return 0 ;; esac; return 1; }

# up_services [OPTION...] SERVICE... — `dc up -d --wait` of the SERVICEs in one compose call: compose starts each as
# soon as what it depends on is up (side by side where nothing is between them), and recreates a container only where
# its image or its configuration changed — with config_sums (above), the files it reads at its start too. The
# others keep running, untouched. setup and ./stack update bring the stack up through here, never with --force-recreate.
# One exception: a listed container that runs unhealthy is recreated all the same (up --wait would only wait on it).
up_services() {
  local a opts=() svcs=() sick
  for a in "$@"; do case "$a" in -*) opts+=("$a") ;; *) svcs+=("$a") ;; esac; done
  sick="$(dc ps --format '{{.Service}} {{.Health}}' "${svcs[@]}" 2>/dev/null | awk '$2 == "unhealthy" { printf "%s ", $1 }' || true)"
  # shellcheck disable=SC2086  # (a service a word)
  [ -z "$sick" ] || dc up -d --no-deps --force-recreate $sick || return
  dc up -d --wait ${opts[@]+"${opts[@]}"} "${svcs[@]}"
}

# compose_contexts_ok VERSION -> 0 for a Docker Compose version (2.40.3-desktop.1, v2.17.0) that reads a service's
# build.additional_contexts: 2.17 or newer. Anything unreadable counts as older.
compose_contexts_ok() {
  local v="${1#v}" maj min
  maj="${v%%.*}"; v="${v#*.}"; min="${v%%.*}"; min="${min%%[!0-9]*}"
  case "$maj" in '' | *[!0-9]*) return 1 ;; esac
  case "$min" in '' | *[!0-9]*) return 1 ;; esac
  [ "$maj" -gt 2 ] || { [ "$maj" -eq 2 ] && [ "$min" -ge 17 ]; }
}

# compose_version_ge VERSION MAJ MIN PATCH -> 0 for a Docker Compose version (2.40.3-desktop.1, v2.24.4,
# 2.24.6+ds1-0ubuntu1) at least MAJ.MIN.PATCH. Anything unreadable counts as older.
compose_version_ge() {
  local v="${1#v}" a b c
  a="${v%%.*}"; v="${v#*.}"; [ "$v" != "$1" ] || return 1
  b="${v%%.*}"; c=0
  case "$v" in *.*) c="${v#*.}"; c="${c%%[!0-9]*}" ;; esac
  b="${b%%[!0-9]*}"
  case "$a" in '' | *[!0-9]*) return 1 ;; esac
  case "$b" in '' | *[!0-9]*) return 1 ;; esac
  [ -n "$c" ] || c=0
  [ "$a" -gt "$2" ] && return 0; [ "$a" -lt "$2" ] && return 1
  [ "$b" -gt "$3" ] && return 0; [ "$b" -lt "$3" ] && return 1
  [ "$c" -ge "$4" ]
}

# compose_overrides_ok -> 0 when this machine's Docker Compose reads the !override and !reset tags of the compose files
# (2.24.4 or newer: Chat's sandbox's network, remote access under your own domain); BEDROCK_NOW_COMPOSE_OVERRIDES=1|0
# decides instead (tests/run.sh sets 1). _BN_COMPOSE_VERSION keeps the version for the message.
compose_overrides_ok() {
  case "${BEDROCK_NOW_COMPOSE_OVERRIDES:-}" in 0) return 1 ;; 1) return 0 ;; esac
  [ -n "${_BN_COMPOSE_VERSION:-}" ] || _BN_COMPOSE_VERSION="$(docker compose version --short 2>/dev/null || true)"
  compose_version_ge "$_BN_COMPOSE_VERSION" 2 24 4
}
compose_too_old() {
  printf 'Docker Compose %s is older than 2.24.4, which %s needs (its compose files use !override and !reset): update Docker Desktop (on Linux, the docker-compose-plugin) and run this again' \
    "${_BN_COMPOSE_VERSION:-(this one)}" "$PRODUCT_NAME"
}

# compose_reads_contexts -> 0 when this machine's Docker Compose reads build.additional_contexts, which the portal's
# docs index needs (compose.portal-docs.yaml). Asked once per command (./stack asks before anything else; the answer
# is exported to the commands it runs); BEDROCK_NOW_COMPOSE_CONTEXTS=1|0 decides instead (tests/run.sh sets 0).
# _BN_COMPOSE_VERSION keeps the version for the message of an older one.
compose_reads_contexts() {
  case "${BEDROCK_NOW_COMPOSE_CONTEXTS:-}" in 0) return 1 ;; 1) return 0 ;; esac
  if [ -z "${_BN_COMPOSE_CTX:-}" ]; then
    _BN_COMPOSE_VERSION="$(docker compose version --short 2>/dev/null || true)"
    _BN_COMPOSE_CTX=no
    if compose_contexts_ok "$_BN_COMPOSE_VERSION"; then _BN_COMPOSE_CTX=yes; fi
    export _BN_COMPOSE_CTX _BN_COMPOSE_VERSION
  fi
  [ "$_BN_COMPOSE_CTX" = yes ]
}

# --- the built-in git server (lib/localgit.sh has the rest) ---
# localgit_on -> 0 while the built-in git server is on: LOCALGIT anything but off (blank = on, the default)
localgit_on() { ! flag_off "$(get_env LOCALGIT)"; }
# localgit_overlay_wanted -> 0 while the sandbox's gateway should also serve it (compose.localgit.yaml): it is on, and so is
# the terminal (the sandbox's gateway exists then) — and its certificate is there
localgit_overlay_wanted() {
  localgit_on && flag_on "$(get_env TERMINAL_ENABLED)" && [ -n "$(get_env TERMINAL_WORKSPACE)" ] && localgit_tls_ensure
}
localgit_tls_dir() { printf '%s/localgit/tls\n' "$STATE_DIR"; }

# localgit_tls_ensure -> 0 with a certificate for the name "gateway" in .state/localgit/tls (tls.crt, tls.key): made once, made
# again a month before it ends. World-readable files in a folder of 755: the gateway's user (the terminal's) is not yours on
# Linux, and what they protect is the sandbox's git to one internal service, whose CA (this very certificate) only the code
# container hands to git. A self-signed certificate that is its own CA (basicConstraints CA:TRUE): git trusts exactly it.
localgit_tls_ensure() {
  local d crt key cfg rc=0
  d="$(localgit_tls_dir)"; crt="$d/tls.crt"; key="$d/tls.key"
  if [ -s "$crt" ] && [ -s "$key" ] && openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null 2>&1; then return 0; fi
  command -v openssl >/dev/null 2>&1 || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  cfg="$(mktemp)" || return 1
  cat > "$cfg" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = gateway
[v3]
subjectAltName = DNS:gateway
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = serverAuth
EOF
  if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -config "$cfg" \
      -keyout "$key.new" -out "$crt.new" >/dev/null 2>&1; then
    chmod 644 "$key.new" "$crt.new"; chmod 755 "$d" "$STATE_DIR/localgit" 2>/dev/null || true
    mv "$key.new" "$key" && mv "$crt.new" "$crt" || rc=1
  else rc=1; rm -f "$key.new" "$crt.new"; fi
  rm -f "$cfg"
  return "$rc"
}

# compose_overlays -> extra compose files for this checkout: remote access (REMOTE_MODE in .env, lib/remote.sh)
# adds the Tailscale sidecar, and own-domain mode also the Caddy build with a DNS plugin; the browser terminal
# (TERMINAL_ENABLED=true, lib/terminal.sh) its container, and its way out to the internet (TERMINAL_EGRESS, read by
# egress_mode below): the egress proxy (internet, the default), the sandbox on the internet itself
# (host) or none (off); the Code page (CODE_ENABLED=true, lib/code.sh) its container, only together with the terminal
# (its sandbox). The project folders' generated file (.state/projects/compose.yaml, lib/projects.sh) comes after the
# terminal's (@projects).
compose_overlays() {
  if [ "${REMOTE_DEGRADED:-0}" != 1 ]; then   # remote network unusable this run (lib/remote.sh remote_net_preflight)
    case "$(get_env REMOTE_MODE)" in
      tailscale) echo compose.tailscale.yaml ;;
      domain) echo compose.tailscale.yaml compose.domain.yaml ;;
    esac
  fi
  # (Without a folder in TERMINAL_WORKSPACE compose could not even read that file: it is left out, and ./stack up
  # says why — lib/terminal.sh terminal_up_hook.)
  if flag_on "$(get_env TERMINAL_ENABLED)" && [ -n "$(get_env TERMINAL_WORKSPACE)" ]; then
    echo compose.terminal.yaml
    # the project folders of this computer (lib/projects.sh generates it while there are any): @projects is
    # .state/projects/compose.yaml for dc (a word: a checkout's path may have spaces)
    [ ! -f "$STATE_DIR/projects/compose.yaml" ] || echo @projects
    case "$(egress_mode "$(get_env TERMINAL_EGRESS)")" in
      internet) echo compose.terminal-proxy.yaml ;;
      host) echo compose.terminal-egress.yaml ;;
    esac
    # the built-in git server as the sandbox's git host: the gateway's TLS listener (lib/localgit.sh)
    ! localgit_overlay_wanted || echo compose.localgit.yaml
    if flag_on "$(get_env CODE_ENABLED)"; then
      echo compose.code.yaml
      # (Chat's sandbox's way out: the terminal's proxy; with the direct one, a proxy of its own; none with none —
      # compose.code.yaml subs-chat)
      case "$(egress_mode "$(get_env TERMINAL_EGRESS)")" in
        internet) echo compose.code-proxy.yaml ;;
        host) echo compose.code-egress.yaml ;;
        *) echo compose.code-offline.yaml ;;
      esac
    fi
  fi
  return 0
}

# flag_on VALUE / flag_off VALUE -> 0 for true|1|yes|on / false|0|no|off, in any case (the portal reads its
# switches the same way: portal/portal/config.py _on)
_flag() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }
flag_on() { case "$(_flag "$1")" in true | 1 | yes | on) return 0 ;; esac; return 1; }
# auto_reviewer_text -> what Claude Code's auto mode reviewer runs on here and about what it costs: the stack's Haiku
# while it is a Claude Haiku (CLAUDE_CODE_AUTO_MODE_MODEL: terminal/bin/bn-coded.mjs reviewerModel, both devos-claude
# wrappers), else Sonnet 5.5 (Claude Code's claude-sonnet-5, the catalog's alias)
auto_reviewer_text() {
  local h; h="$(get_env CLAUDE_BEDROCK_HAIKU_MODEL)"
  case "$h" in
    claude-haiku-*) printf '%s; ~$0.006 per 5 minutes in use\n' "$h" ;;
    *) printf 'Sonnet 5.5; ~$0.13 per 5 minutes in use\n' ;;
  esac
}
flag_off() { case "$(_flag "$1")" in false | 0 | no | off) return 0 ;; esac; return 1; }

# egress_mode VALUE -> internet | host | off: TERMINAL_EGRESS as the stack reads it (portal/portal/settings.py
# egress_mode and code/server/main.mjs read it the same way). internet, the default (blank, and the old on values:
# true/1/yes/on, which meant the internet): through the egress proxy, public addresses only; host: the sandbox on the
# internet itself, this computer's services and your network included (how v0.10.0 and earlier always did it); off
# (false/0/no/off): neither. Anything else reads as the default (lib/terminal.sh terminal_flag_warnings says so).
egress_mode() {
  case "$(_flag "$1")" in
    host) echo host ;;
    false | 0 | no | off) echo off ;;
    *) echo internet ;;
  esac
}

# claude_policy -> off | code-auto | on: the browser terminal's Claude Code managed settings, terminal/managed/<it>.json,
# from the two auto mode switches in .env (compose.terminal.yaml mounts that file read-only; managed settings outrank
# every other tier, so the sandbox never chooses or writes them):
#   off        both switches off: auto mode off for every claude in the sandbox
#   on         TERMINAL_AUTO_MODE: nothing set, Claude Code decides as anywhere else
#   code-auto  only CODE_AUTO_MODE: auto mode available (the Code page switches its sessions to it; managed settings
#              would win over the page), the terminal's claude starts in Manual and its Plan mode asks
claude_policy() {
  if flag_on "$(get_env TERMINAL_AUTO_MODE)"; then echo on
  elif flag_on "$(get_env CODE_AUTO_MODE)"; then echo code-auto
  else echo off; fi
}

# curl with a bearer token that never appears in `ps` output (token is fed via -K stdin).
curl_auth() { # curl_auth TOKEN curl-args...
  local token="$1"; shift
  printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -K - "$@"
}

# claude_subcommands < `claude --help` output -> one subcommand name per line ("plugin|plugins" → both).
claude_subcommands() {
  awk '/^Commands:/ { f = 1; next } f && /^[^ ]/ { f = 0 }
       f && /^  [a-z]/ { n = split($1, a, "|"); for (i = 1; i <= n; i++) print a[i] }'
}
