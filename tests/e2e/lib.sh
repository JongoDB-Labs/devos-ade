# shellcheck shell=bash
# Functions of the e2e harness (tests/e2e/run.sh), kept apart so tests/test_e2e_harness.sh can check the safety
# rules (ownership, teardown, reuse, parsing) with a stubbed docker. Sourcing this file runs nothing.
# The caller sets: ROOT (this checkout), PROJECT, STACK (the throwaway checkout), OUT, LOGS, RESULTS.

say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }
now()  { date +%s; }

# valid_project NAME -> 0 for the suite's own project names only: bne2e or bne2e-<lowercase letters/digits/->.
# Anything else (bedrock-now — the default Compose project —, another copy's name) could be a real install; teardown deletes volumes by name.
valid_project() {
  case "$1" in
    bne2e) return 0 ;;
    bne2e-*) case "${1#bne2e-}" in '' | -* | *[!a-z0-9-]*) return 1 ;; esac; return 0 ;;
  esac
  return 1
}

# real_dir DIR -> DIR with symlinks resolved (pwd -P) when it exists, else DIR as given
real_dir() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# --- results: one TSV line per check (suite, id, status PASS|FAIL|SKIP, seconds, message) ---
record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | tr '\t\n\r' '   ' | cut -c1-400)" >> "$RESULTS"
  case "$3" in PASS) printf '  ok    %s\n' "$2" >&2 ;; SKIP) printf '  skip  %s (%s)\n' "$2" "$5" >&2 ;;
    *) printf '  FAIL  %s: %s\n' "$2" "$5" >&2 ;; esac
}

# --- the throwaway's environment: nothing from this shell reaches ./stack except what is listed here ---
KEEP_VARS=" PATH HOME USER LOGNAME TMPDIR DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG DOCKER_CERT_PATH DOCKER_TLS_VERIFY BN_SESSIONS_HOME
  HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy ALL_PROXY all_proxy "
# clean_env [EXTRA...] — in a subshell: unexports every variable except KEEP_VARS and EXTRA (values stay in the
# environment, never on a command line), then sets the throwaway's fixed ones.
clean_env() {
  local v keep
  keep=" $(printf '%s' "$KEEP_VARS $*" | tr '\n' ' ') "
  for v in $(compgen -e); do case "$keep" in *" $v "*) ;; *) unset "$v" 2>/dev/null || true ;; esac; done
  export SHELL=/bin/bash TERM=dumb NO_COLOR=1 BEDROCK_NOW_NO_OPEN=1 LANG=C
}

# load_aws_file FILE — exports AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION_NAME (AWS_REGION) found in
# FILE: only those lines are read; `export ` prefixes, quotes and CR line ends are accepted. Never prints a value.
load_aws_file() {
  local line k v
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION_NAME AWS_REGION
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in "export "*) line="${line#export }"; line="${line#"${line%%[![:space:]]*}"}" ;; esac
    case "$line" in AWS_ACCESS_KEY_ID=* | AWS_SECRET_ACCESS_KEY=* | AWS_REGION_NAME=* | AWS_REGION=*) ;; *) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
    [ -n "$v" ] || continue
    export "$k=$v"
  done < "$1"
  [ -n "${AWS_REGION_NAME:-}" ] || [ -z "${AWS_REGION:-}" ] || export AWS_REGION_NAME="$AWS_REGION"
  return 0
}

# --- the throwaway .env (non-secret keys only through these: ports, host, model names) ---
get_env() { K="$1" awk 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2) } END { printf "%s", v }' "$STACK/.env" 2>/dev/null; }
set_env() {
  local t; t="$(mktemp "$STACK/.env.XXXXXX")" || return 1
  K="$1" V="$2" awk 'index($0, ENVIRON["K"] "=") == 1 { if (!d) print ENVIRON["K"] "=" ENVIRON["V"]; d = 1; next } { print }
    END { if (!d) print ENVIRON["K"] "=" ENVIRON["V"] }' "$STACK/.env" > "$t" && chmod 600 "$t" && mv "$t" "$STACK/.env"
}
# env_has KEY STRING — 0 when STRING contains the value of KEY in the throwaway .env (neither is ever on a command line)
env_has() { K="$1" S="$2" awk 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2) }
  END { exit !(length(v) > 0 && index(ENVIRON["S"], v) > 0) }' "$STACK/.env"; }

# redact FILE... — replaces every secret of the throwaway .env (and the AWS key) in each FILE with ***
redact() {
  local f t
  [ -f "$STACK/.env" ] || return 0
  for f in "$@"; do
    [ -f "$f" ] || continue
    t="$(mktemp "$f.XXXXXX")" || continue
    AWSK="${AWS_ACCESS_KEY_ID:-}" AWSS="${AWS_SECRET_ACCESS_KEY:-}" awk '
      BEGIN { if (length(ENVIRON["AWSK"]) >= 8) s[++n] = ENVIRON["AWSK"]; if (length(ENVIRON["AWSS"]) >= 8) s[++n] = ENVIRON["AWSS"] }
      FILENAME == ARGV[1] { i = index($0, "="); k = substr($0, 1, i - 1); v = substr($0, i + 1)
                            if (i > 1 && k ~ /(PASSWORD|SECRET|KEY|TOKEN|SALT)/ && length(v) >= 8) s[++n] = v; next }
      { for (j = 1; j <= n; j++) while ((p = index($0, s[j])) > 0) $0 = substr($0, 1, p - 1) "***" substr($0, p + length(s[j])); print }
    ' "$STACK/.env" "$f" > "$t" 2>/dev/null && chmod 600 "$t" && mv "$t" "$f" || rm -f "$t"
  done
}
# redact_outputs — every log the run wrote (also called on the way out, whatever ended the run)
redact_outputs() {
  local f
  for f in "$LOGS"/*.log "$OUT/browser/run.log" "$OUT/browser/build.log"; do [ -f "$f" ] && redact "$f"; done
  return 0
}

# --- ownership: is project $PROJECT this suite's own? ---
# project_ownership -> sets OWN_STATE (none | ours | foreign) and OWN_WHY. Ours: every container was started from
# $STACK (or from a folder under $ROOT/tests/e2e/work/ that no longer exists — a killed earlier run), and the owner
# marker, if any, names such a folder too. Data volumes without either record are of unknown origin: foreign. A
# Docker query that fails counts as foreign too (fail closed: nothing is torn down on a guess). Never changes anything.
project_ownership() {
  local me work d dirs owner='' vols marker any=0
  OWN_STATE=none; OWN_WHY=''
  me="$(real_dir "$STACK")"; work="$(real_dir "$ROOT/tests/e2e/work")"
  if ! dirs="$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.project.working_dir"}}')" ||
     ! vols="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")" ||
     ! marker="$(docker volume ls -q)"; then
    OWN_STATE=foreign; OWN_WHY="Docker did not answer (docker ps / docker volume ls failed), so project $PROJECT's owner is unknown"
    return 0
  fi
  marker="$(printf '%s\n' "$marker" | grep -xF "${PROJECT}_bedrock-now-owner" || true)"
  if [ -n "$marker" ] && ! owner="$(docker volume inspect --format '{{index .Labels "io.bedrock-now.dir"}}' "${PROJECT}_bedrock-now-owner")"; then
    OWN_STATE=foreign; OWN_WHY="cannot read the owner marker of project $PROJECT"
    return 0
  fi
  dirs="$(printf '%s\n' "$dirs" | sort -u)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    any=1
    if [ -e "$d" ]; then
      [ "$(real_dir "$d")" = "$me" ] && continue
    else
      case "$d" in "$work"/* | "$ROOT/tests/e2e/work"/*) continue ;; esac
    fi
    OWN_STATE=foreign; OWN_WHY="project $PROJECT belongs to $d, not to this suite ($STACK)"
    return 0
  done <<EOF
$dirs
$owner
EOF
  if [ "$any" = 1 ]; then OWN_STATE=ours; OWN_WHY="left by an earlier run of this suite"
  elif [ -n "$vols" ]; then OWN_STATE=foreign; OWN_WHY="project $PROJECT has data volumes of unknown origin ($(printf '%s' "$vols" | tr '\n' ' '))"
  fi
  return 0
}

# claim_project — OWNED=1 when project $PROJECT is free or this suite's own; otherwise dies WITHOUT touching it.
# Teardown does nothing to Docker unless OWNED=1.
OWNED=0
claim_project() {
  project_ownership
  [ "$OWN_STATE" != foreign ] || die "$OWN_WHY — pick another --project (nothing was changed)"
  OWNED=1
}

# teardown — only this project's own things, by exact name, and only once claim_project said it is ours
# folder_users_other_than_project -> the Compose projects other than $PROJECT with containers started from $STACK
# (fails when Docker does not answer)
folder_users_other_than_project() {
  local d out all=''
  for d in "$STACK" "$(real_dir "$STACK")"; do
    out="$(docker ps -a --filter "label=com.docker.compose.project.working_dir=$d" --format '{{.Label "com.docker.compose.project"}}')" || return 1
    all="$all
$out"
  done
  printf '%s\n' "$all" | awk -v p="$PROJECT" 'NF && $0 != p && !s[$0]++ { printf "%s%s", (n++ ? " " : ""), $0 }'
}

# terminal_workspace_dir -> the browser terminal's workspace for the throwaway (--terminal): next to its checkout
terminal_workspace_dir() { printf '%s/%s-workspace\n' "$(dirname "$STACK")" "$PROJECT"; }

# --- the throwaway's update helper (run.sh --helper) ---
# The throwaway's own bin/bedrock-now-helper, run as launchd/systemd would run it after `./stack helper install` —
# but as a child of this run, never as a launchd agent or systemd unit: in its own session (notty: no terminal, and
# its whole process group stops together), with a clean environment plus HELPER_KNOBS, started again after a clean
# exit like launchd/systemd do (it exits after an update/rollback/clean), its output appended to $LOGS/helper.log.
# The caller sets NOTTY. SETTINGS_MIN_INTERVAL_S=5: the settings/* checks make a change every 6 s (the portal takes
# one every 5 s); the helper's default 15 s refuses the next one as "too soon". HELPER_POLL_S stays 3: after a job
# the loop sleeps that long again, so two pick-ups are never less than 5 s apart.
HELPER_KNOBS="SETTINGS_MIN_INTERVAL_S=5"
# shellcheck disable=SC2034  # HELPER_ALIVE and HELPER_RC: set by e2e_helper_stop for run.sh
HELPER_PID=''; HELPER_T0=''; HELPER_ALIVE=''; HELPER_RC=''

# _helper_beat_at -> the heartbeat time of the throwaway's helper (helper.json), if it names a live process
_helper_beat_at() {
  local s pid hb
  s="$(head -c 8192 "$STACK/.state/status/helper.json" 2>/dev/null)" || return 1
  hb="$(printf '%s' "$s" | sed -n 's/.*"heartbeat": \([0-9][0-9]*\).*/\1/p')"
  pid="$(printf '%s' "$s" | sed -n 's/.*"pid": \([0-9][0-9]*\).*/\1/p')"
  [ -n "$hb" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$hb"
}

# e2e_helper_start — starts it and waits (up to 60 s) until its heartbeat is fresh and it offers Settings (what the
# portal checks before it shows Change). Fails when it did not get there or stopped by itself.
e2e_helper_start() {
  local kv names='' hb
  [ -x "$STACK/bin/bedrock-now-helper" ] || { echo "$STACK/bin/bedrock-now-helper is missing" >&2; return 1; }
  _e2e_helper_sweep   # never two helpers on one checkout (one left by a run that was killed with -9)
  for kv in $HELPER_KNOBS; do names="$names ${kv%%=*}"; done
  HELPER_T0="$(now)"; HELPER_ALIVE=''; HELPER_RC=''
  printf '%s e2e: starting %s/bin/bedrock-now-helper in the foreground (%s)\n' "$(date '+%F %T')" "$STACK" "$HELPER_KNOBS" >> "$LOGS/helper.log"
  # shellcheck disable=SC2086,SC2016  # (names: a word list; the loop is the child shell's own script)
  ( for kv in $HELPER_KNOBS; do export "${kv?}"; done
    clean_env $names
    cd "$STACK" && exec "$NOTTY" /bin/bash -c 'while :; do "$1/bin/bedrock-now-helper" "$1" || exit $?
        printf "%s e2e: the helper exited cleanly (it does after an update, rollback or clean): started again, as launchd/systemd do\n" "$(date "+%F %T")"
        sleep 2; done' bedrock-now-e2e-helper "$STACK" ) </dev/null >> "$LOGS/helper.log" 2>&1 &
  HELPER_PID=$!
  for _ in $(seq 1 60); do
    kill -0 "$HELPER_PID" 2>/dev/null || { echo "it stopped by itself (log: $LOGS/helper.log)" >&2; return 1; }
    hb="$(_helper_beat_at)" && [ "$hb" -ge "$HELPER_T0" ] && grep -q '"settings": 1' "$STACK/.state/status/helper-settings.json" 2>/dev/null && return 0
    sleep 1
  done
  echo "no fresh heartbeat with Settings within 60 s (log: $LOGS/helper.log)" >&2
  return 1
}

# _e2e_helper_sweep — stops every process group running this checkout's helper (a command line that ends in
# "STACK/bin/bedrock-now-helper STACK"; never this run's own group): what e2e_helper_stop's own child left, or the
# helper of a run that was killed with -9. (The path goes to awk in the environment: not on a command line it matches.)
_e2e_helper_sweep() {
  local me groups g
  me="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  groups="$(ps -A -ww -o pgid= -o command= 2>/dev/null | M="$STACK/bin/bedrock-now-helper $STACK" awk -v me="$me" '
    { g = $1; sub(/^ *[0-9]+ /, ""); n = length(ENVIRON["M"]) }
    length($0) >= n && substr($0, length($0) - n + 1) == ENVIRON["M"] && g != me && g > 1 && !s[g]++ { print g }')"
  [ -n "$groups" ] || return 0
  for g in $groups; do kill -TERM -- "-$g" 2>/dev/null || true; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    for g in $groups; do kill -0 -- "-$g" 2>/dev/null && break; g=''; done
    [ -n "$g" ] || return 0
    sleep 0.5
  done
  for g in $groups; do kill -KILL -- "-$g" 2>/dev/null || true; done
  return 0
}

# e2e_helper_stop — stops it (TERM to its group through notty, then the sweep), then does what `./stack helper
# uninstall` does to the state: no heartbeat (Home stops offering the buttons at once) and no request left waiting.
# Keeps its last settings / diagnostics logs in $LOGS. Sets HELPER_ALIVE (1: it was still running when stopped) and
# HELPER_RC (its exit status). Safe to call more than once.
# shellcheck disable=SC2034
e2e_helper_stop() {
  local f
  if [ -n "$HELPER_PID" ]; then
    if kill -0 "$HELPER_PID" 2>/dev/null; then
      HELPER_ALIVE=1
      kill -TERM "$HELPER_PID" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$HELPER_PID" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$HELPER_PID" 2>/dev/null && kill -KILL "$HELPER_PID" 2>/dev/null
    else HELPER_ALIVE=0; fi
    HELPER_RC=0; wait "$HELPER_PID" 2>/dev/null || HELPER_RC=$?
    HELPER_PID=''
    printf '%s e2e: helper stopped\n' "$(date '+%F %T')" >> "$LOGS/helper.log"
  fi
  _e2e_helper_sweep
  rm -f "$STACK/.state/status/helper.json" "$STACK/.state/requests"/req-*.json "$STACK/.state/requests"/cfg-*.req \
    "$STACK/.state/requests"/act-*.json 2>/dev/null || true
  for f in last-settings last-diag; do
    [ ! -f "$STACK/.state/helper/$f.log" ] || cp "$STACK/.state/helper/$f.log" "$LOGS/helper-$f.log" 2>/dev/null || true
  done
  return 0
}

# e2e_helper_jobs KIND -> how many jobs of KIND (settings-jobs, diag-jobs) the helper started since e2e_helper_start
e2e_helper_jobs() { awk -v t="${HELPER_T0:-0}" '$1 + 0 >= t' "$STACK/.state/helper/$1" 2>/dev/null | wc -l | tr -d ' '; }

teardown() {
  local img id left others ws net n
  # the throwaway's update helper (--helper), also one a killed run left: only from a checkout this suite created
  [ ! -f "$STACK/.bedrock-now-e2e" ] || _e2e_helper_sweep
  if [ "$OWNED" != 1 ]; then
    warn "teardown: project $PROJECT is not known to be this suite's own — Docker left untouched"
  else
    say "teardown: project $PROJECT"
    # (the suite's git server, --git-server: not compose's; by its name, before its network goes)
    docker rm -f "$PROJECT-gitsrv" >/dev/null 2>&1 || true
    docker compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1 || warn "docker compose -p $PROJECT down failed"
    docker volume rm "${PROJECT}_bedrock-now-owner" >/dev/null 2>&1 || true
    # The browser terminal (--terminal) lives in overlay files that `down` without them does not read: its volume
    # and networks go by name — a network up to 5 times, a second apart (Docker may still hold the endpoint of a
    # container that has just gone; one it never lets go is said below).
    docker volume rm "${PROJECT}_terminal-home" "${PROJECT}_terminal-socket" "${PROJECT}_code-socket" "${PROJECT}_preview-socket" "${PROJECT}_code-state" >/dev/null 2>&1 || true
    for net in "${PROJECT}_terminal" "${PROJECT}_terminal-out" "${PROJECT}_terminal-link" "${PROJECT}_terminal-proxy"; do
      for n in 1 2 3 4 5; do
        docker network rm "$net" >/dev/null 2>&1 && break
        docker network inspect "$net" >/dev/null 2>&1 || break
        [ "$n" = 5 ] || sleep 1
      done
    done
    for img in "$PROJECT/portal:local" "$PROJECT/shared-mcp:local" "$PROJECT/portal:previous" "$PROJECT/shared-mcp:previous" \
               "$PROJECT/caddy-dns:local" "$PROJECT/e2e-playwright:local" "$PROJECT/stt:local" "$PROJECT/stt:previous" \
               "$PROJECT/terminal:local" "$PROJECT/terminal:previous" "$PROJECT/terminal-egress:local" "$PROJECT/terminal-egress:previous" \
               "$PROJECT/code:local" "$PROJECT/code:previous" "$PROJECT/e2e-gitsrv:local"; do
      docker image rm "$img" >/dev/null 2>&1 || true
    done
    for id in $(docker image ls -q --no-trunc --filter dangling=true --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null); do
      docker image rm "$id" >/dev/null 2>&1 || true
    done
    docker rm -f "$PROJECT-playwright" >/dev/null 2>&1 || true
  fi
  # Only a folder this suite created (it carries the marker) is ever deleted — and not while containers of another
  # project were started from it (or Docker cannot say).
  if [ -f "$STACK/.bedrock-now-e2e" ] && ! others="$(folder_users_other_than_project)"; then
    warn "not deleting $STACK: Docker cannot tell which projects use it"
  elif [ -f "$STACK/.bedrock-now-e2e" ] && [ -n "$others" ]; then
    warn "not deleting $STACK: containers of project(s) $others were started from it"
  elif [ -f "$STACK/.bedrock-now-e2e" ]; then chmod -R u+rwX "$STACK" 2>/dev/null; rm -rf "$STACK" || warn "could not delete $STACK"
  elif [ -d "$STACK" ] && [ -z "$(ls -A "$STACK" 2>/dev/null)" ]; then rmdir "$STACK"
  elif [ -e "$STACK" ]; then warn "not deleting $STACK: it was not created by this suite (no .bedrock-now-e2e marker)"; fi
  # The terminal's workspace folder next to the checkout: only when this suite created it (its marker).
  ws="$(terminal_workspace_dir)"
  if [ -f "$ws/.bedrock-now-e2e" ]; then chmod -R u+rwX "$ws" 2>/dev/null; rm -rf "$ws" || warn "could not delete $ws"
  elif [ -e "$ws" ]; then warn "not deleting $ws: it was not created by this suite (no .bedrock-now-e2e marker)"; fi
  [ "$OWNED" = 1 ] || return 0
  left="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT"; docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT"
    docker network ls --format '{{.Name}}' --filter "label=com.docker.compose.project=$PROJECT")"
  if [ -z "$left" ] && [ ! -e "$STACK" ]; then say "teardown complete: no containers, volumes, networks or checkout of $PROJECT left"
  else warn "teardown left something behind: $left $( [ -e "$STACK" ] && echo "$STACK")"; fi
}

# teardown_only — ./run.sh --teardown: refuses (nothing touched) unless the project is this suite's own and its
# checkout, if still there, carries the marker
teardown_only() {
  project_ownership
  [ "$OWN_STATE" != foreign ] || die "--teardown: $OWN_WHY — nothing was removed"
  [ ! -e "$STACK" ] || [ -f "$STACK/.bedrock-now-e2e" ] || [ -z "$(ls -A "$STACK" 2>/dev/null)" ] ||
    die "--teardown: $STACK was not created by this suite (no .bedrock-now-e2e marker) — nothing was removed"
  OWNED=1
  teardown
}

# reuse_check — --reuse only on a kept throwaway that is exactly this suite's, and fully up
REQUIRED_SERVICES="caddy portal open-webui litellm rustfs shared-mcp postgres"
reuse_check() {
  local s ps owner
  [ -f "$STACK/.bedrock-now-e2e" ] || die "--reuse: $STACK is not a kept throwaway of this suite (no marker)"
  [ "$(get_env COMPOSE_PROJECT_NAME)" = "$PROJECT" ] || die "--reuse: $STACK/.env is not for project $PROJECT"
  owner="$(docker volume inspect --format '{{index .Labels "io.bedrock-now.dir"}}' "${PROJECT}_bedrock-now-owner" 2>/dev/null || true)"
  [ -n "$owner" ] && [ "$(real_dir "$owner")" = "$(real_dir "$STACK")" ] ||
    die "--reuse: project $PROJECT is not owned by $STACK (owner: ${owner:-none})"
  ps="$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.service"}}	{{.State}}	{{.Status}}' 2>/dev/null)"
  for s in $REQUIRED_SERVICES; do
    printf '%s\n' "$ps" | awk -F'\t' -v s="$s" '$1 == s && $2 == "running" && $3 !~ /unhealthy|starting/ { f = 1 } END { exit !f }' ||
      die "--reuse: service $s of the kept throwaway is not running and healthy — tests/e2e/run.sh --teardown, then a full run"
  done
  OWNED=1
}

# --- ports: the first free one at or above START (never AVOID_PORTS, never one already chosen) ---
CHOSEN=' '
pick_port() { # pick_port VAR START — sets VAR (no subshell, so CHOSEN is kept)
  local p="$2"
  while port_in_use "$p" || case "$AVOID_PORTS$CHOSEN" in *" $p "*) true ;; *) false ;; esac; do
    p=$((p + 1)); [ "$p" -le $(($2 + 200)) ] || die "no free port in $2..$(($2 + 200))"
  done
  CHOSEN="$CHOSEN$p "
  eval "$1=$p"
}

# link_state -> what ~/.local/bin/claude-bedrock is: the link target and a checksum of the file it points to
link_state() {
  local link="$HOME/.local/bin/claude-bedrock"
  if [ -L "$link" ]; then printf 'symlink -> %s (%s)\n' "$(readlink "$link")" "$(cksum < "$link" 2>/dev/null | awk '{ print $1 "/" $2 }')"
  elif [ -e "$link" ]; then printf 'file (%s)\n' "$(cksum < "$link" | awk '{ print $1 "/" $2 }')"
  else echo absent; fi
}

# perm_of PATH -> octal mode (GNU stat first: BSD stat -f means something else on Linux)
perm_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- spend: LiteLLM's /global/spend. A restore puts the spend log back to the backup's, so the run's spend is
# summed piecewise: spend_cut before such a step, spend_resume after it. ---
SPEND_ACC=0; SPEND_MARK=''; SPEND_ERR=''
spend_now() {
  local lp mk
  lp="$(get_env LITELLM_PORT)"
  mk="$(awk 'index($0, "LITELLM_MASTER_KEY=") == 1 { v = substr($0, 20) } END { printf "%s", v }' "$STACK/.env")"
  [ -n "$lp" ] && [ -n "$mk" ] || return 0
  printf 'header = "Authorization: Bearer %s"\n' "$mk" | curl -sS -m 20 -K - "http://127.0.0.1:$lp/global/spend" 2>/dev/null |
    sed -n 's/.*"spend"[[:space:]]*:[[:space:]]*\([0-9.eE+-]*\).*/\1/p' | head -n 1
}
# Every reading must answer: a missed one sets SPEND_ERR, and spend_total then prints nothing (the guard FAILs).
_spend_read() { local s; s="$(spend_now)"; case "$s" in '' | *[!0-9.eE+-]*) return 1 ;; esac; printf '%s\n' "$s"; }
spend_start() { SPEND_MARK="$(_spend_read)" || SPEND_ERR="${SPEND_ERR:+$SPEND_ERR, }start"; }
spend_cut() {
  local s
  s="$(_spend_read)" || { SPEND_ERR="${SPEND_ERR:+$SPEND_ERR, }before a restore or at the end"; return 0; }
  SPEND_ACC="$(awk -v a="$SPEND_ACC" -v s="$s" -v m="${SPEND_MARK:-0}" 'BEGIN { d = s - m; if (d < 0) d = 0; printf "%.6f", a + d }')"
}
spend_resume() { SPEND_MARK="$(_spend_read)" || SPEND_ERR="${SPEND_ERR:+$SPEND_ERR, }after a restore"; }
spend_total() { spend_cut; [ -z "$SPEND_ERR" ] || { printf 'unanswered: %s\n' "$SPEND_ERR" >&2; return 1; }; printf '%.4f\n' "$SPEND_ACC"; }
spend_ok() { awk -v s="${1:-0}" -v l="$2" 'BEGIN { exit !(s + 0 < l + 0) }'; }

# host_folders_parent -> where --host-folders makes its two folders: E2E_HOST_FOLDERS_DIR, else
# ROOT/tests/e2e/work/PROJECT-host-folders (gitignored) — never under --out, which may be a temporary folder that
# ./stack project rightly refuses. Either one must not exist yet: the suite makes it and removes it at the end.
host_folders_parent() { printf '%s\n' "${E2E_HOST_FOLDERS_DIR:-$ROOT/tests/e2e/work/$PROJECT-host-folders}"; }
# host_sessions_parent -> where --host-sessions makes its folder and its fake home: E2E_HOST_SESSIONS_DIR, else
# ROOT/tests/e2e/work/PROJECT-host-sessions (gitignored); as host_folders_parent: new, made and removed by the suite
host_sessions_parent() { printf '%s\n' "${E2E_HOST_SESSIONS_DIR:-$ROOT/tests/e2e/work/$PROJECT-host-sessions}"; }
# host_config_parent -> where --host-config makes its fake home: E2E_HOST_CONFIG_DIR, else ROOT/tests/e2e/work/PROJECT-host-config
# (gitignored); new, made and removed by the suite
host_config_parent() { printf '%s\n' "${E2E_HOST_CONFIG_DIR:-$ROOT/tests/e2e/work/$PROJECT-host-config}"; }
# host_folders_refused DIR -> why ./stack project would refuse a folder in DIR by its path alone (this checkout's own
# rules, lib/projects.sh _project_path_rules: a temporary folder, a folder of sockets, a .claude part that is not a
# Claude Code worktree, a Time Machine backup) — printed, 0; 1 when it would not. DIR need not exist yet: it is read
# as the nearest folder above it that does, as that resolves, and the rest.
host_folders_refused() {
  local d="$1" base phys why
  base="$d"; while [ ! -d "$base" ]; do base="$(dirname "$base")"; done
  phys="$(cd "$base" && /bin/pwd -P)${d#"$base"}"
  why="$(STACK_DIR="$ROOT" ENV_FILE=/nonexistent bash -c '. "$STACK_DIR/lib/common.sh" && . "$STACK_DIR/lib/terminal.sh" &&
    . "$STACK_DIR/lib/projects.sh" && _project_path_rules "$1"' _ "$phys/app" 2>/dev/null)" && return 1
  printf '%s\n' "${why:-its path breaks a rule of ./stack project}"
}

# --- terminal-isolation's "a public site is reachable" side, steady against this computer's DNS ---
# The sandbox reaches public sites through its egress proxy, which asks Docker's DNS — this computer's resolver. When
# that answers a public name with a private or loopback address for a while, the proxy rightly refuses it, and the
# public probes fail for a reason that is not the sandbox's. Only these probes are tried again; the proxy's refusals
# (this computer, private addresses, DNS rebinding) are judged once, as they come, in run.sh.
E2E_PUBLIC_HOSTS='registry.npmjs.org example.com pypi.org files.pythonhosted.org github.com'
E2E_PUBLIC_EXPECT='internet=200
proxy-public=200 200
node-fetch=200
npm-install=ok
pip-download=1
git-https=1
git-ssh=1'

# public_probe_bad PROBE -> " key:value" for each public probe that PROBE (lines "key<TAB>value") has not as it must be
public_probe_bad() {
  local kv k got out=''
  while IFS= read -r kv; do
    k="${kv%%=*}"
    got="$(printf '%s\n' "$1" | awk -F'\t' -v k="$k" '$1 == k && !f { print $2; f = 1 }')"
    [ "$got" = "${kv#*=}" ] || out="$out $k:$got"
  done <<< "$E2E_PUBLIC_EXPECT"
  printf '%s' "$out"
}

# not_public ADDR -> 0 for an address no public name has: IPv4 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12,
# 192.0.0/24, 192.0.2/24, 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, 224/3; IPv6 ::, ::1, fc00::/7,
# fe80::/10, ff00::/8 and the IPv4-mapped form of the IPv4 ones. 1 for any other address (or not an address).
not_public() {
  local a o1 o2 o3 o4
  a="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
  case "$a" in
    ::ffff:*.*.*.*) a="${a#::ffff:}" ;;
    :: | ::1 | fc*:* | fd*:* | fe[89ab]*:* | ff*:*) return 0 ;;
    *:*) return 1 ;;
  esac
  case "$a" in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
  IFS=. read -r o1 o2 o3 o4 <<< "$a"
  case "$o3.$o4" in .* | *. | *.*.*) return 1 ;; esac
  if [ "$o1" -eq 0 ] || [ "$o1" -eq 10 ] || [ "$o1" -eq 127 ] || [ "$o1" -ge 224 ]; then return 0; fi
  if [ "$o1" -eq 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; then return 0; fi
  if [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then return 0; fi
  case "$o1.$o2" in 169.254 | 192.168 | 198.18 | 198.19) return 0 ;; esac
  case "$o1.$o2.$o3" in 192.0.0 | 192.0.2 | 198.51.100 | 203.0.113) return 0 ;; esac
  return 1
}

# host_dns_answers NAME... -> "NAME ADDR ..." per name as this computer's resolver answers it now ("NAME -": none) —
# dscacheutil on macOS (the system resolver, which Docker Desktop's DNS asks), getent ahosts elsewhere
host_dns_answers() {
  local n a
  for n in "$@"; do
    case "$(uname -s)" in
      Darwin) a="$(dscacheutil -q host -a name "$n" 2>/dev/null | awk '$1 == "ip_address:" || $1 == "ipv6_address:" { print $2 }')" ;;
      *) a="$(getent ahosts "$n" 2>/dev/null | awk '{ print $1 }')" ;;
    esac
    a="$(printf '%s\n' "$a" | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ *$//')"
    printf '%s %s\n' "$n" "${a:--}"
  done
}

# public_dns_problem ANSWERS NAME... < EGRESS-LOG -> "this computer's DNS answered NAME with ADDR" (and 0) when the
# egress proxy refused one of the NAMEs for the address it resolved to ("NAME resolves to ADDR: …" in its log), or
# ANSWERS (host_dns_answers' lines) has one of them at an address no public name has; nothing (and 1) otherwise
public_dns_problem() {
  local answers="$1" hit n a x; shift
  hit="$(awk -v names=" $* " '/"event":"refused"/ && / resolves to / {
      h = $0; if (!sub(/.*"host":"/, "", h)) next; sub(/".*/, "", h)
      a = $0; if (!sub(/.*"address":"/, "", a)) next; sub(/".*/, "", a)
      if (!f && index(names, " " h " ")) { print h " " a; f = 1 } }')"
  if [ -z "$hit" ]; then
    while read -r n a; do
      case " $* " in *" $n "*) ;; *) continue ;; esac
      for x in $a; do not_public "$x" && { hit="$n $x"; break 2; }; done
    done <<< "$answers"
  fi
  [ -n "$hit" ] || return 1
  printf "this computer's DNS answered %s with %s\n" "${hit%% *}" "${hit#* }"
}

# public_probe_steady PROBE LOG -> 0 when the public probes are as they must be. PROBE prints their "key<TAB>value"
# lines; LOG SINCE prints the egress proxy's log from SINCE (unix seconds). A try that fails is tried again — at most
# E2E_PUBLIC_RETRIES (3) more times, E2E_PUBLIC_GAP_S (15) s apart — only while public_dns_problem finds this
# computer's DNS answering a public name privately (E2E_HOST_DNS: the resolver, host_dns_answers); any other failure
# is final at once. Sets PUBLIC_OUT (the last try's lines), PUBLIC_LOG (every try's, with this computer's answers),
# PUBLIC_TRIES, PUBLIC_DNS (the finding at the last try; empty when it passed) and PUBLIC_DNS_SEEN (the first finding).
public_probe_steady() {
  local probe="$1" logf="$2" since answers elog
  PUBLIC_TRIES=0; PUBLIC_DNS=''; PUBLIC_DNS_SEEN=''; PUBLIC_LOG=''; PUBLIC_OUT=''
  while :; do
    since="$(( $(date +%s) - 1 ))"
    PUBLIC_OUT="$("$probe" 2>&1)"; PUBLIC_TRIES=$((PUBLIC_TRIES + 1))
    # shellcheck disable=SC2086  # the names, one word each
    answers="$("${E2E_HOST_DNS:-host_dns_answers}" $E2E_PUBLIC_HOSTS)"
    PUBLIC_LOG="$PUBLIC_LOG# public probes, try $PUBLIC_TRIES
$PUBLIC_OUT
$(printf '%s\n' "$answers" | sed "s/^/# this computer's DNS: /")
"
    [ -n "$(public_probe_bad "$PUBLIC_OUT")" ] || { PUBLIC_DNS=''; return 0; }
    elog="$("$logf" "$since" 2>&1)" || true
    # shellcheck disable=SC2086
    PUBLIC_DNS="$(public_dns_problem "$answers" $E2E_PUBLIC_HOSTS <<< "$elog")" || PUBLIC_DNS=''
    [ -n "$PUBLIC_DNS_SEEN" ] || PUBLIC_DNS_SEEN="$PUBLIC_DNS"
    [ -n "$PUBLIC_DNS" ] && [ "$PUBLIC_TRIES" -le "${E2E_PUBLIC_RETRIES:-3}" ] || return 1
    sleep "${E2E_PUBLIC_GAP_S:-15}"
  done
}

# rebind_dns_problem RESULTS ANSWERS -> "this computer's DNS answered NAME with ADDR, not IP" when every DNS-rebinding
# probe that was not refused (a 0 in RESULTS, one per name, in order) had a name this computer's resolver did not
# answer with the address in that name (ANSWERS: host_dns_answers' lines for those names, in the same order): those
# probes tested nothing. Nothing (and 1) when one of them did get its address — then the proxy let it through.
rebind_dns_problem() {
  local -a r; local i=0 n a note=''
  read -r -a r <<< "$1"
  while read -r n a; do
    [ -n "$n" ] || continue
    if [ "${r[$i]:-}" = 0 ]; then
      case " $a " in *" ${n%.nip.io} "*) return 1 ;; esac
      [ -n "$note" ] || note="this computer's DNS answered $n with ${a:--}, not ${n%.nip.io}"
    fi
    i=$((i + 1))
  done <<< "$2"
  [ -n "$note" ] || return 1
  printf '%s\n' "$note"
}

# --- terminal-isolation's DNS-rebinding probes: refused for the address, or a FAIL; only no answer is asked again ---
# (tests/e2e/rebind-try.sh makes each answer's line; run.sh sends the first three with terminal_probe, after its
# fresh log window, and any retry alone)

# rebind_class RC CODE EGRESS BODY -> what one DNS-rebinding probe got through the egress proxy (curl's exit, the HTTP
# code, the proxy's X-Bn-Egress header, the start of the body):
#   refused   403 from the proxy, "… resolves to ADDR: …": refused for the address the name resolves to — what must be
#   dns       the proxy found no address for the name ("does not resolve"): nip.io unreachable, not checked (as before)
#   noanswer  no HTTP answer at all (curl failed: no proxy, a timeout), or the proxy's own lookup timed out (504
#             "looking up NAME timed out"): nothing reached, nothing refused — asked again
#   reached   any 2xx or 3xx, or an answer that is not the proxy's (no X-Bn-Egress): the target was reached
#   other     any other answer of the proxy's (a refusal for another reason, an address that did not answer …)
rebind_class() {
  local rc="$1" code="$2" eg="$3" body="$4"
  case "$code" in 2??|3??) echo reached; return ;; ''|000) echo noanswer; return ;; esac
  case "$eg" in refused|failed) ;; *) echo reached; return ;; esac
  case "$eg:$code:$body" in
    refused:403:*' resolves to '*) echo refused ;;
    failed:502:*' does not resolve'*) echo dns ;;
    failed:504:*'looking up '*' timed out'*) echo noanswer ;;
    *) echo other ;;
  esac
}

# _rebind_state < LINES -> "URL CLASS CODE" for each "proxy-rebind-try" line
_rebind_state() {
  local tag url rc code eg body
  while IFS=$'\t' read -r tag url rc code eg body; do
    [ "$tag" = proxy-rebind-try ] || continue
    printf '%s %s %s\n' "$url" "$(rebind_class "$rc" "$code" "$eg" "$body")" "${code:-000}"
  done
}

# rebind_steady PROBE FIRST -> the DNS-rebinding probes' verdict. FIRST: their first lines (rebind-try.sh's, one per
# URL, in order); PROBE URL MAXTIME prints one such line again. A URL with no answer (noanswer) is asked again — at most
# E2E_REBIND_RETRIES (3) more times, E2E_REBIND_GAP_S (10) s apart, E2E_REBIND_MAX_TIME (30) s each; any other answer
# is final at once (a reached target fails without a retry). Sets REBIND_RB (one word per URL, as before: 1 refused,
# dns, 0 anything else), REBIND_BAD (" NAME:CLASS(CODE)" for each not refused or dns), REBIND_NOTE (the environment
# note when every such one is a remaining no-answer, else empty), REBIND_TRIES and REBIND_LOG (every try's lines).
# shellcheck disable=SC2034  # REBIND_*: set for the caller (run.sh)
rebind_steady() {
  local probe="$1" state next url cls code u0 line round=0 na='' strict='' host
  REBIND_LOG="$2"; REBIND_RB=''; REBIND_BAD=''; REBIND_NOTE=''
  state="$(printf '%s\n' "$2" | _rebind_state)"
  while printf '%s\n' "$state" | grep -q ' noanswer ' && [ "$round" -lt "${E2E_REBIND_RETRIES:-3}" ]; do
    round=$((round + 1))
    sleep "${E2E_REBIND_GAP_S:-10}"
    next=''
    while read -r url cls code; do
      [ -n "$url" ] || continue
      if [ "$cls" = noanswer ]; then
        u0="$url"
        line="$("$probe" "$url" "${E2E_REBIND_MAX_TIME:-30}" 2>&1)"
        REBIND_LOG="$REBIND_LOG
# DNS rebinding, try $((round + 1))
$line"
        read -r url cls code <<< "$(printf '%s\n' "$line" | _rebind_state)"
        [ "$url" = "$u0" ] || { url="$u0"; cls=noanswer; code=000; }
      fi
      next="$next$url $cls $code
"
    done <<< "$state"
    state="$next"
  done
  REBIND_TRIES=$((round + 1))
  while read -r url cls code; do
    [ -n "$url" ] || continue
    host="${url#*://}"; host="${host%%/*}"
    case "$cls" in
      refused) REBIND_RB="${REBIND_RB}1 " ;;
      dns) REBIND_RB="${REBIND_RB}dns " ;;
      noanswer) REBIND_RB="${REBIND_RB}0 "; REBIND_BAD="$REBIND_BAD $host:no-answer"; [ -n "$na" ] || na="$host" ;;
      *) REBIND_RB="${REBIND_RB}0 "; REBIND_BAD="$REBIND_BAD $host:$cls($code)"; strict=1 ;;
    esac
  done <<< "$state"
  if [ -n "$na" ] && [ -z "$strict" ]; then
    REBIND_NOTE="the proxy did not answer for $na (its DNS lookup timed out?): an environment problem, rerun"
  fi
  return 0
}
