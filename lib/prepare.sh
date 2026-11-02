# shellcheck shell=bash
# shellcheck disable=SC2154  # PS_* and UR_* come from _kv_read (lib/helper.sh)
# Prepare the next release ahead of Update now (JON-972 phase B). Sourced by lib/commands.sh; run by the update helper
# (lib/helper.sh: _prepare_bg in its loop, prepare_update_now_phase at the start of Update now's job).
#
# Once the portal's check (latest.txt) names a release newer than the installed one, the helper prepares it in the
# background, so that Update now only has the switch to make:
#   1. fetch    git fetch --tags origin, then the checks ./stack update makes: the newest release tag, not behind HEAD,
#               a signed tag when UPDATE_REQUIRE_SIGNED_TAGS=true
#   2. unpack   git archive of that commit into .state/update/prepare/src (nothing in the checkout moves: no HEAD, no
#               working tree, no .env, no update record). Removed when the run ends.
#   3. build    each image of the release (the portal, shared-mcp, Open WebUI; the Terminal's and the Code page's while
#               they are on), one at a time, as <project>-prep/<service>:local from that copy and a private copy of .env
#               whose project is <project>-prep. BuildKit's layer cache is shared, so ./stack update's own build of
#               <project>/<service>:local is a cache hit.
#   4. download the images the release's compose files pin by digest and this computer does not have (a tag is never
#               pulled: only a digest never moves a name something uses)
# It runs the CHECKOUT'S OWN scripts over the new release's files as data: no script of the new release runs; building its
# Dockerfiles is what ./stack update does anyway.
#
# Safety, in short (tests/test_prepare.sh):
#   - no <project>/<service>:local or :previous tag, nor any other name the running stack or ./stack rollback uses, is
#     created, moved or removed before the update itself: the builds carry the project <project>-prep, the downloads are
#     digest-pinned, and the clean-up removes names of <project>-prep only (and images it pulled itself, when nothing uses them)
#   - the running stack is not touched (no container starts or stops), and it runs only while no ./stack command holds
#     the lock (lib/lock.sh); it takes no lock itself, and ends the moment one is taken (yields), to go on later
#   - gentle on a busy computer: one image at a time, not started while the processors are PREPARE_START_CPU_PCT (80) % in
#     use or more and paused between steps from PREPARE_STOP_CPU_PCT (90) %, a release only once (the record below), and at
#     most PREPARE_MAX_MB of images and never below PREPARE_MIN_FREE_MB of free disk
#
# .state/update/prepare/state   KEY=value: version, commit, state (preparing | ready | failed | yielded), step, reason, at
#                  images.tsv   ID<TAB>REF of the builds (<project>-prep/…:local)
#                  pulled.tsv   ID<TAB>REF of the downloads that were not here before

prepare_dir() { printf '%s/update/prepare\n' "$STATE_DIR"; }
prepare_state_file() { printf '%s/state\n' "$(prepare_dir)"; }
prepare_log_file() { printf '%s/prepare.log\n' "$(helper_dir)"; }
# the project the builds carry: never the stack's own
prepare_project() { printf '%s-prep\n' "$(project_name)"; }

# prepare_enabled — UPDATE_PREPARE in .env: on unless false/off/0/no
prepare_enabled() { ! flag_off "$(get_env UPDATE_PREPARE)"; }

# --- the record ---

PREP_VERSION=''; PREP_COMMIT=''; PREP_STARTED=''; PREP_WHY=''; PREP_STEP=''; PREP_RC=0
# _prep_state STATE STEP REASON — the record, atomically (a small file of the helper's own; never fatal)
_prep_state() {
  local d f
  d="$(prepare_dir)"; f="$(prepare_state_file)"
  mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null || return 0
  _kv_write "$f" "version=$PREP_VERSION" "commit=$PREP_COMMIT" "state=$1" \
    "step=$(printf '%s' "$2" | tr -d '\000-\037' | head -c 160)" "reason=$(printf '%s' "$3" | tr -d '\000-\037' | head -c 300)" \
    "at=$(date +%s)" "started=${PREP_STARTED:-$(date +%s)}" || true
}
# _prep_read — the record into PS_version, PS_commit, PS_state, PS_step, PS_reason, PS_at (empty without one)
_prep_read() { _kv_read "$(prepare_state_file)" PS version commit state step reason at; case "$PS_at" in *[!0-9]*) PS_at=0 ;; '') PS_at=0 ;; esac; }

# prepare_recover — the helper just started: a run the record says is going on is not (nothing of it survived)
prepare_recover() {
  _prep_read
  [ "$PS_state" = preparing ] || return 0
  PREP_VERSION="$PS_version"; PREP_COMMIT="$PS_commit"
  _prep_state yielded "$PS_step" "the update helper restarted; it goes on later"
}

# --- facts for the decision (tests replace them) ---

# prepare_cpu_busy -> how much of the processors' time was in use over about PREPARE_CPU_SAMPLE_S (1) second, in percent of
# all of them: the time spent waiting for the disk counts as idle. (Not the load average: Linux counts the tasks waiting for
# the disk in it, and a Mac's runs high with many programs open, so both looked busy for good with the processors far from
# full.) 0 when it cannot be read.
prepare_cpu_busy() {
  local a s
  s="${PREPARE_CPU_SAMPLE_S:-1}"; case "$s" in '' | *[!0-9]*) s=1 ;; esac
  if [ -r "${PREPARE_PROC_STAT:-/proc/stat}" ]; then
    a="$(_prep_cpu_ticks)"; sleep "$s"; _prep_busy_pct "$a" "$(_prep_cpu_ticks)"
  elif command -v iostat >/dev/null 2>&1; then
    iostat -n 0 -c 2 -w "$s" 2>/dev/null | _prep_iostat_busy
  else echo 0; fi
}
# _prep_cpu_ticks -> "TOTAL IDLE" of /proc/stat's cpu line: user..steal (guest is counted in user already), idle + iowait
_prep_cpu_ticks() { awk '$1 == "cpu" { t = 0; for (i = 2; i <= 9 && i <= NF; i++) t += $i; print t, $5 + $6; exit }' "${PREPARE_PROC_STAT:-/proc/stat}" 2>/dev/null; }
# _prep_busy_pct "TOTAL IDLE" "TOTAL IDLE" -> the percent in use between the two readings (0 without a difference)
_prep_busy_pct() {
  awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, " "); split(b, y, " "); t = y[1] - x[1]; i = y[2] - x[2]
    if (t <= 0) { print 0; exit } p = int((t - i) * 100 / t + 0.5); print (p < 0 ? 0 : (p > 100 ? 100 : p)) }'
}
# _prep_iostat_busy -> the percent in use of a Mac's iostat -n 0 -c 2 on stdin: 100 - the "id" column of its last line (the
# first counts since the Mac started). (top -l 2 says the same in about 5 s, iostat in 1.)
_prep_iostat_busy() {
  awk '{ for (i = 1; i <= NF; i++) if ($i == "id" && c == 0) c = i } c && $1 ~ /^[0-9]+$/ { v = $c } END { if (c && v != "") { p = 100 - v; print (p < 0 ? 0 : (p > 100 ? 100 : p)) } else print 0 }'
}
# prepare_free_mb -> free space (MB) where .state lives
prepare_free_mb() { df -Pk "$STATE_DIR" 2>/dev/null | awk 'NR == 2 { printf "%d\n", $4 / 1024 }'; }
# _prep_cpu_high PERCENT -> 0 when the processors are PERCENT % in use or more; PREP_CPU: the reading (for the reason)
PREP_CPU=0
_prep_cpu_high() {
  local p="$1"; case "$p" in '' | *[!0-9]*) p=80 ;; esac
  PREP_CPU="$(prepare_cpu_busy)"; case "$PREP_CPU" in '' | *[!0-9]*) PREP_CPU=0 ;; esac
  [ "$PREP_CPU" -ge "$p" ]
}
_prep_cpu_why() { printf 'the computer is busy: its processors are %s%% in use' "$PREP_CPU"; }

# prepare_decision ON LATEST INSTALLED BRANCH ROLLED_BACK STATE VERSION AT NOW BUSY CPUHIGH -> "STATE [VERSION]": what the
# helper does about the release LATEST names (no clock, file or git access of its own: tests/test_prepare.sh). First match:
#   off | branch | not-release (only a release install prepares) | none (nothing newer) | rolled-back V (you went back from it)
#   | ready V (prepared already) | failed V (it failed within the last PREPARE_RETRY_S, 1 h) | busy V (BUSY says why)
#   | load V (the processors are busy) | run V (a different V than a record's: that one is superseded and removed first)
prepare_decision() {
  local on="$1" latest="$2" inst="$3" br="$4" rb="$5" st="$6" pv="$7" pat="${8:-0}" now="$9" busy="${10:-}" high="${11:-0}" retry
  retry="${PREPARE_RETRY_S:-3600}"; case "$retry" in '' | *[!0-9]*) retry=3600 ;; esac
  [ "$on" = on ] || { echo off; return 0; }
  [ -z "$br" ] || { echo branch; return 0; }
  _is_release "$inst" || { echo not-release; return 0; }
  if [ -z "$latest" ] || ! version_newer "$latest" "$inst"; then echo none; return 0; fi
  [ "$rb" != "$latest" ] || { echo "rolled-back $latest"; return 0; }
  [ "$st" = ready ] && [ "$pv" = "$latest" ] && { echo "ready $latest"; return 0; }
  [ "$st" = failed ] && [ "$pv" = "$latest" ] && [ $((now - pat)) -lt "$retry" ] && { echo "failed $latest"; return 0; }
  [ -z "$busy" ] || { echo "busy $latest"; return 0; }
  [ "$high" != 1 ] || { echo "load $latest"; return 0; }
  echo "run $latest"
}

# prepare_stale ON INSTALLED LATEST VERSION -> 0 when a record of VERSION should be removed: preparing is off, VERSION is not
# newer than the installed one (it was applied, here or elsewhere), or LATEST is another release (superseded)
prepare_stale() {
  [ -n "$4" ] || return 1
  [ "$1" = on ] || return 0
  version_newer "$4" "$2" || return 0
  [ -z "$3" ] || [ "$3" = "$4" ] || ! version_newer "$3" "$4" || return 0
  return 1
}

# _prepare_busy -> why not now ("" = it can): a ./stack command holds the lock, a job of the helper's runs, the last update
# did not finish, or Docker is not running
_prepare_busy() {
  local holder
  holder="$(stack_lock_holder)"
  if [ -n "$holder" ]; then echo "./stack ${holder#* } is running"; return 0; fi
  if _status_in_progress; then echo "another action is still running"; return 0; fi
  if update_unfinished; then echo "the last update did not finish"; return 0; fi
  docker info >/dev/null 2>&1 || echo "Docker is not running"
}

# --- clean-up ---

# prepare_cleanup WHY — removes what a prepare made. WHY: applied (the update installed it: the downloads stay, they are
# the installed version's now), superseded | disabled | abandoned (the downloads that nothing uses go too). Names of the
# <project>-prep project only: a recorded name outside it is never removed. Never fatal.
prepare_cleanup() {
  local d pp ref id used others plan prot
  d="$(prepare_dir)"; pp="$(prepare_project)"
  [ -d "$d" ] || return 0
  if [ -f "$d/images.tsv" ]; then
    while IFS='	' read -r id ref; do
      case "$ref" in "$pp"/*:local) docker image rm "$ref" >/dev/null 2>&1 || true ;; esac
    done < "$d/images.tsv"
  fi
  if [ "$1" != applied ] && [ -s "$d/pulled.tsv" ]; then
    # (never forced, and not an image a container, another checkout or this one's snapshots and compose files use)
    if used="$(images_used_by_containers 2>/dev/null)" && others="$(images_of_other_checkouts 2>/dev/null)"; then
      prot="$(printf '%s\n%s\n' "$used" "$others"; project_refs | snapshot_refs | cut -f1; _ids "$(images_dir)/before.tsv" "$(images_dir)/previous.tsv")"
      plan="$(cleanup_plan '' "$(cat "$d/pulled.tsv")" "$prot")"
      while IFS='	' read -r id ref; do
        [ -n "$id" ] || continue
        case "$ref" in *@sha256:*) docker image rm "$ref" >/dev/null 2>&1 || true ;; esac
      done <<EOF
$plan
EOF
    fi
  fi
  rm -rf "$d/src" "$d/env" "$d/step.out" "$d/images.tsv" "$d/pulled.tsv" "$d/state" 2>/dev/null || true
  PREP_VERSION=''; PREP_COMMIT=''
}

# prepare_after_update — ./stack update, once the new version runs: a record of a release that is installed now (not newer than
# it) is removed, its downloads kept. A release newer than the one just installed stays prepared.
prepare_after_update() {
  _prep_read
  [ -n "$PS_version" ] || return 0
  version_newer "$PS_version" "$(installed_version)" || prepare_cleanup applied
}

# --- the run ---

# prepare_is_ready COMMIT -> 0 when COMMIT is prepared: its record says ready and its builds are all still here
prepare_is_ready() {
  local d got want
  d="$(prepare_dir)"; _prep_read
  [ "$PS_state" = ready ] && [ -n "$1" ] && [ "$PS_commit" = "$1" ] && [ -s "$d/images.tsv" ] || return 1
  want="$(LC_ALL=C sort "$d/images.tsv")"
  got="$(cut -f2 "$d/images.tsv" | snapshot_refs | LC_ALL=C sort)"
  [ "$want" = "$got" ]
}

# _prep_ctx CMD… — CMD in the new release's copy and the private .env (a subshell: the checkout's own functions over the
# release's files as data)
_prep_ctx() { ( STACK_DIR="$PREP_SRC"; ENV_FILE="$PREP_ENV"; "$@" ); }

# _prep_watch PID — waits for PID; the stack lock taken ends it (and what it started): returns 2 (PREP_WHY says so), else 0
# with its exit status in PREP_RC
_prep_watch() {
  local pid="$1" p holder
  while kill -0 "$pid" 2>/dev/null; do
    holder="$(stack_lock_holder)"
    if [ -n "$holder" ]; then
      PREP_WHY="./stack ${holder#* } started"
      for p in $(_status_tick_tree "$pid"); do kill "$p" 2>/dev/null || true; done
      wait "$pid" 2>/dev/null || true
      return 2
    fi
    sleep "${PREPARE_WATCH_S:-1}"
  done
  PREP_RC=0; wait "$pid" || PREP_RC=$?
  return 0
}

# _prep_step LABEL CMD… — one step of the run: "==> LABEL: starting…" and "==> LABEL ready (12s)" in the log (the lines Home's
# update card reads: lib/helper.sh _job_steps), the record's step, CMD watched (_prep_watch). 0 done, 1 failed (PREP_WHY),
# 2 yielded (PREP_WHY)
_prep_step() {
  local label="$1" start out w
  shift
  start="$(date +%s)"; PREP_STEP="$label"
  _prep_state preparing "$label" ""
  printf '==> %s: starting…\n' "$label"
  out="$(prepare_dir)/step.out"
  "$@" </dev/null > "$out" 2>&1 &
  w=0; _prep_watch $! || w=$?
  if [ "$w" = 2 ]; then
    printf '==> %s (stopped) ready (%s)\n' "$label" "$(fmt_elapsed $(($(date +%s) - start)))"; return 2
  fi
  if [ "$PREP_RC" = 0 ]; then
    printf '==> %s ready (%s)\n' "$label" "$(fmt_elapsed $(($(date +%s) - start)))"; return 0
  fi
  PREP_WHY="$label failed: $(tail -n 3 "$out" 2>/dev/null | tr '\n' ' ' | tr -d '\000-\037"\\' | head -c 240)"
  printf '==> %s (failed) ready (%s)\n' "$label" "$(fmt_elapsed $(($(date +%s) - start)))"
  return 1
}

_prepare_fetch() { PREPARE_NO_BEAT=1 _auto_fetch; }
_prepare_unpack() {
  rm -rf "$PREP_SRC"; mkdir -p "$PREP_SRC" || return 1
  git -C "$STACK_DIR" archive --format=tar "$PREP_COMMIT" | ( umask 022; tar -xf - -C "$PREP_SRC" )
}
# _prep_services — in the new release's context: the images setup builds (lib/commands.sh setup_build_images)
_prep_services() {
  local e
  printf '%s\n' portal shared-mcp open-webui
  if terminal_on && [ -z "$(terminal_why_out)" ]; then
    echo terminal
    e="$(terminal_egress_build_service)"; [ -z "$e" ] || echo "$e"
    ! code_ready || echo code
  fi
}
# _prep_build_one SERVICE — in the context: its build with the arguments setup gives it (so the cache is the same)
_prep_build_one() {
  case "$1" in
    open-webui) dc build -q --build-arg "BN_VENDOR_TRY=$(owui_vendor_try)" open-webui ;;
    terminal) terminal_build_args; dc build -q "${TERMINAL_BUILD_ARGS[@]}" terminal ;;
    *) dc build -q "$1" ;;
  esac
}
# _prep_pull REF — a download (a ref already here is not asked for again)
_prep_pull() { docker pull "$1"; }

# prepare_run HINT — prepares the newest release (HINT: the one latest.txt names). 0 ready, 1 failed, 2 stopped (the lock was
# taken, or the computer is busy: it goes on later). PREP_FOREGROUND=1: Update now's own first step (no processor check).
# The record says which; the log lines are the steps.
prepare_run() {
  local rc=0
  PREP_WHY=''; PREP_STEP=''; PREP_STARTED="$(date +%s)"
  PREP_SRC="$(prepare_dir)/src"; PREP_ENV="$(prepare_dir)/env"
  _prepare_run_inner "$1" || rc=$?
  rm -rf "$PREP_SRC" "$PREP_ENV" "$(prepare_dir)/step.out" 2>/dev/null || true
  case "$rc" in
    0) ;;
    2) _prep_state yielded "$PREP_STEP" "$PREP_WHY"; printf 'prepare: stopped, goes on later: %s\n' "$PREP_WHY" ;;
    *) _prep_state failed "$PREP_STEP" "$PREP_WHY"; printf 'prepare: failed: %s\n' "$PREP_WHY" ;;
  esac
  return "$rc"
}
_prepare_run_inner() {
  local hint="$1" newest inst free min max d pp svc id total=0 size ref pulled=0 rc old_commit
  d="$(prepare_dir)"; pp="$(prepare_project)"
  mkdir -p "$d" && chmod 700 "$d" || { PREP_WHY="cannot write $d"; return 1; }
  min="${PREPARE_MIN_FREE_MB:-10240}"; max="${PREPARE_MAX_MB:-8192}"
  case "$min" in '' | *[!0-9]*) min=10240 ;; esac; case "$max" in '' | *[!0-9]*) max=8192 ;; esac
  free="$(prepare_free_mb)"
  case "$free" in '' | *[!0-9]*) ;; *) [ "$free" -ge "$min" ] || { PREP_WHY="only $free MB of disk is free here (it needs $min MB to prepare ahead)"; return 1; } ;; esac
  [ -e "$STACK_DIR/.git" ] || { PREP_WHY="this is not a git checkout"; return 1; }
  # prepared already (a tag never moves): nothing to fetch or build, and the record stays as it is
  _prep_read; old_commit="$PS_commit"
  if [ "$PS_state" = ready ] && [ "$PS_version" = "$hint" ] && prepare_is_ready "$PS_commit"; then
    printf 'prepare: %s is prepared already\n' "$hint"; return 0
  fi
  PREP_VERSION="$hint"; PREP_COMMIT=''
  _prep_step "Prepare: fetch $hint" _prepare_fetch || { rc=$?; [ "$rc" = 2 ] || PREP_WHY="could not fetch from origin (network?) — nothing was prepared"; return "$rc"; }
  # --- what ./stack update would install, and its checks (update_checkout) ---
  newest="$(newest_release_tag "$STACK_DIR")"; inst="$(installed_version)"
  [ -n "$newest" ] || { PREP_WHY="no release tags found on origin"; return 1; }
  version_newer "$newest" "$inst" || { PREP_WHY="origin's newest release is $newest, which is not newer than the installed $inst"; return 1; }
  PREP_VERSION="$newest"
  git -C "$STACK_DIR" merge-base --is-ancestor HEAD "$newest" 2>/dev/null || { PREP_WHY="this checkout is ahead of $newest (./stack update --to <ref> decides)"; return 1; }
  if _signed_tags_required; then
    git -C "$STACK_DIR" rev-parse -q --verify "refs/tags/$newest" >/dev/null 2>&1 || { PREP_WHY="UPDATE_REQUIRE_SIGNED_TAGS=true: '$newest' is not a tag"; return 1; }
    git -C "$STACK_DIR" verify-tag "$newest" >/dev/null 2>&1 || { PREP_WHY="UPDATE_REQUIRE_SIGNED_TAGS=true: the signature of tag $newest could not be verified (git verify-tag $newest)"; return 1; }
  fi
  PREP_COMMIT="$(git -C "$STACK_DIR" rev-parse -q --verify "$newest^{commit}" 2>/dev/null)" || { PREP_WHY="$newest is not a commit here"; return 1; }
  # another release's builds and downloads (superseded) go first; the same release's downloads of an earlier, stopped run stay
  # recorded (they are removed with it)
  if [ -n "$old_commit" ] && [ "$old_commit" != "$PREP_COMMIT" ]; then prepare_cleanup superseded; PREP_VERSION="$newest"; fi
  rm -f "$d/images.tsv"
  # --- the release's files, and a private .env for its project ---
  _prep_step "Prepare: unpack $newest" _prepare_unpack || return $?
  ( umask 077; { grep -v '^COMPOSE_PROJECT_NAME=' "$ENV_FILE" 2>/dev/null || true; printf 'COMPOSE_PROJECT_NAME=%s\n' "$pp"; } > "$PREP_ENV" ) || { PREP_WHY="cannot write the private copy of .env"; return 1; }
  chmod 600 "$PREP_ENV" 2>/dev/null || true
  # --- the builds, one at a time ---
  for svc in $(_prep_ctx _prep_services 2>/dev/null); do
    if [ "${PREP_FOREGROUND:-0}" != 1 ] && _prep_cpu_high "${PREPARE_STOP_CPU_PCT:-90}"; then PREP_WHY="$(_prep_cpu_why)"; return 2; fi
    _prep_step "Prepare: build $svc" _prep_ctx _prep_build_one "$svc" || return $?
    id="$(_image_id "$pp/$svc:local")"
    [ -n "$id" ] || { PREP_WHY="the build of $svc left no image"; return 1; }
    printf '%s\t%s\n' "$id" "$pp/$svc:local" >> "$d/images.tsv"
    size="$(docker image inspect --format '{{.Size}}' "$pp/$svc:local" 2>/dev/null || echo 0)"; case "$size" in '' | *[!0-9]*) size=0 ;; esac
    total=$((total + size / 1000000))
    [ "$total" -le "$max" ] || { PREP_WHY="the images would use more than $max MB (PREPARE_MAX_MB)"; return 1; }
  done
  # --- the downloads: digest-pinned images that are not here ---
  for ref in $(_prep_ctx update_pull_refs 2>/dev/null); do
    case "$ref" in *@sha256:*) ;; *) printf 'prepare: %s is not pinned by a digest: left for the update\n' "$ref"; continue ;; esac
    pull_needed "$ref" || continue
    if [ "${PREP_FOREGROUND:-0}" != 1 ] && _prep_cpu_high "${PREPARE_STOP_CPU_PCT:-90}"; then PREP_WHY="$(_prep_cpu_why)"; return 2; fi
    _prep_step "Prepare: download $(image_short "$ref")" _prep_pull "$ref" || return $?
    id="$(_image_id "$ref")"
    [ -z "$id" ] || { printf '%s\t%s\n' "$id" "$ref" >> "$d/pulled.tsv"; LC_ALL=C sort -u "$d/pulled.tsv" > "$d/pulled.tsv.n" && mv "$d/pulled.tsv.n" "$d/pulled.tsv"; }
    pulled=$((pulled + 1))
  done
  PREP_STEP=''
  _prep_state ready "" ""
  printf 'prepare: %s is ready (%s built, %s downloaded)\n' "$newest" "$(wc -l < "$d/images.tsv" 2>/dev/null | tr -d ' ')" "$pulled"
  return 0
}

# --- the helper's side ---

# prepare_tick — the helper's loop, every PREPARE_CHECK_S (a subshell, in the background): the clean-up of an old record, then
# the decision, then the run. Output goes to .state/helper/prepare.log (the last run's).
prepare_tick() {
  local on latest inst br rb now d busy high log rc
  set +e; trap - EXIT
  on=off; prepare_enabled && on=on
  _prep_read; PREP_VERSION="$PS_version"; PREP_COMMIT="$PS_commit"
  inst="$(installed_version)"; latest="$(latest_release_seen)"
  br="$(git -C "$STACK_DIR" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  _kv_read "$(update_record_file)" UR result to_version rolled_back_version
  rb="$UR_rolled_back_version"; [ -n "$rb" ] || [ "$UR_result" != rolled-back ] || rb="$UR_to_version"
  now="$(date +%s)"
  if [ -n "$PS_version" ] && prepare_stale "$on" "$inst" "$latest" "$PS_version"; then
    if [ "$on" != on ]; then d=disabled; elif ! version_newer "$PS_version" "$inst"; then d=applied; else d=superseded; fi
    prepare_cleanup "$d"; _prep_read
  fi
  [ "$on" = on ] || return 0
  high=0; ! _prep_cpu_high "${PREPARE_START_CPU_PCT:-80}" || high=1
  d="$(prepare_decision "$on" "$latest" "$inst" "$br" "$rb" "$PS_state" "$PS_version" "$PS_at" "$now" '' "$high")"
  if [ "${d%% *}" = run ]; then
    busy="$(_prepare_busy)"
    d="$(prepare_decision "$on" "$latest" "$inst" "$br" "$rb" "$PS_state" "$PS_version" "$PS_at" "$now" "$busy" "$high")"
  fi
  if [ "${d%% *}" = load ]; then
    # not started: the record says why (Home's card, ./stack helper status), as a stopped run's does; one of the same
    # release keeps its commit and step (what it built is kept)
    PREP_VERSION="${d#* }"; PREP_COMMIT=''; PREP_STARTED=''
    [ "$PS_version" != "$PREP_VERSION" ] || PREP_COMMIT="$PS_commit"
    _prep_state yielded "$([ "$PS_version" = "$PREP_VERSION" ] && printf '%s' "$PS_step")" "$(_prep_cpu_why)"
    return 0
  fi
  [ "${d%% *}" = run ] || return 0
  log="$(prepare_log_file)"
  { : > "$log" && chmod 600 "$log"; } 2>/dev/null || log=/dev/null
  rc=0; PREP_FOREGROUND=0 prepare_run "${d#* }" >> "$log" 2>&1 || rc=$?
  return "$rc"
}

# prepare_update_now_phase — Update now's first step (lib/helper.sh _job_run): the newest release the portal's check names,
# prepared before the update starts when it is not yet (its steps are the job's, with their times). A prepare that fails is
# said and the update goes on without it (it does all the work itself). Nothing for a branch, a non-release, nothing newer, or
# UPDATE_PREPARE=off.
prepare_update_now_phase() {
  local target
  target="$(prepare_update_now_target)" || return 0
  PREP_FOREGROUND=1 prepare_run "$target" || printf '%s\n' "Preparing ahead did not finish; the update does that work itself."
  return 0
}
# prepare_update_now_target -> the release Update now prepares first (fails: none)
prepare_update_now_target() {
  local inst latest br c
  prepare_enabled || return 1
  inst="$(installed_version)"; _is_release "$inst" || return 1
  br="$(git -C "$STACK_DIR" symbolic-ref -q --short HEAD 2>/dev/null || true)"; [ -z "$br" ] || return 1
  latest="$(latest_release_seen)"; [ -n "$latest" ] && version_newer "$latest" "$inst" || return 1
  c="$(git -C "$STACK_DIR" rev-parse -q --verify "$latest^{commit}" 2>/dev/null || true)"
  if [ -n "$c" ] && prepare_is_ready "$c"; then return 1; fi
  printf '%s\n' "$latest"
}

# prepare_apply_note — ./stack update, before its images step: says when the release was prepared ahead
prepare_apply_note() {
  local head
  head="$(git -C "$STACK_DIR" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)"
  [ -n "$head" ] && prepare_is_ready "$head" || return 0
  log "update: prepared ahead — the images of $(installed_version) were built and downloaded before this click, so the builds are cache hits and the downloads are done"
}
