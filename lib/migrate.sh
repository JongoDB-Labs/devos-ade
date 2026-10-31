# shellcheck shell=bash
# The move from "bedrock-now" to "devos-ade" (JON-807, v0.45.0): an install made under the old name keeps its data, its
# settings and its ports, and lives under the new name afterwards. Sourced by lib/commands.sh; bash 3.2.
#
# Called from `./stack update` (migrate_update_hook, once the NEW code is checked out and before anything is built or
# started; migrate_update_finish, after the update's setup) and by hand (`./stack migrate`: status, --now, --rollback,
# --remove-old). docs/upgrade-to-0.45.md tells the person's side; this file is the machine's.
#
# The sequence (each step writes its line to the marker, .state/migrate/marker, and is skipped when already done, so a
# stop at any point is resumed by the next `./stack update` or `./stack migrate --now`):
#   preflight  disk (the old volumes + 10%), the target folder, same file system, no clash with the new name; says the time
#   stop       the old project's containers and networks go (volumes stay); .env pins COMPOSE_PROJECT_NAME to the old
#              name until the copy is verified; ./stack up refuses while the move is half done (migrate_refuse_up)
#   copy       each old volume to its new name in a throwaway container (cp -a: owners, modes, xattrs); verified by file
#              count, bytes, a metadata list and a checksum list; the old volumes are only ever read (:ro)
#   inner      terminal-home: ~/.config/bedrock-now and the .bedrock-now-* folders become the new names (new volume only)
#   env        .env backed up to .env.pre-devos-ade, then rewritten (keys, the default host, the project, pins)
#   images     the old local image tags also get the new names (rollback's snapshot and the first start find them)
#   move       mv OLD NEW (one rename, never a copy: .state/mlx/hf is tens of GB) and OLD becomes a symlink to NEW
#   paths      every absolute path into the old folder is rewritten: records, generated files, symlinks, ~/.local/bin links
#   launchd    plists of the runtimes' agents and of the helper get the new labels and paths (old ones kept aside)
# then the update goes on in a NEW process started from the new folder (the old one's folder name is gone: the update
# helper and ./stack keep running through the symlink, but nothing may hold the old spelling). The helper itself cannot
# be relabelled from inside its own job (bootout would end the update): its new unit is written, and the old unit's
# next start (a shim at the old helper path) switches over while the helper is idle (./stack migrate --finish-helper).
# migrate_update_finish checks health and writes the end of the marker. NOTHING OLD IS DELETED: the old volumes, .env,
# images, plists and the symlink wait for ./stack migrate --remove-old.

# --- the old spellings (compatibility code: docs/internal-names.md lists this file) ---
MG_OLD_PROJECT=bedrock-now;            MG_NEW_PROJECT=devos-ade
MG_OLD_HOST=bedrock-now.localhost;     MG_NEW_HOST=devos-ade.localhost
MG_OLD_PREVIEW=bedrock-now-preview.localhost; MG_NEW_PREVIEW=devos-ade-preview.localhost
MG_OLD_DIRNAME=bedrock-now;            MG_NEW_DIRNAME=devos-ade
MG_OLD_ENV_PREFIX=BEDROCK_NOW_;        MG_NEW_ENV_PREFIX=DEVOS_ADE_
MG_OLD_LABEL=io.bedrock-now.;          MG_NEW_LABEL=io.devos-ade.
MG_OLD_UNIT=bedrock-now-helper;        MG_NEW_UNIT=devos-ade-helper
MG_OLD_EMAIL=admin@bedrock-now.local
MG_OLD_OWNER_LABEL=io.bedrock-now.dir  # the owner marker volume's label (lib/guard.sh): which folder owns the old project
MG_OLD_CONF=bedrock-now;               MG_NEW_CONF=devos-ade            # ~/.config/<name> inside terminal-home
MG_OLD_TRASH=.bedrock-now-trash;       MG_NEW_TRASH=.devos-ade-trash
MG_OLD_TMP=.bedrock-now-tmp;           MG_NEW_TMP=.devos-ade-tmp
MG_NEW_OWNER_LABEL=io.devos-ade.dir; MG_NEW_OWNER_PROJ_LABEL=io.devos-ade.project   # the owner marker the new code looks for: <project>_devos-ade-owner
MG_OLD_HINT=.bedrock-now-claude-md-hint; MG_NEW_HINT=.devos-ade-claude-md-hint        # in ~/.claude-bedrock (and the same folder in terminal-home)
MG_OLD_OPEN=bedrock-now;               MG_NEW_OPEN=devos-ade           # the ./stack open window profile: <this>[-<project>] beside Application Support / ~/.local/share
MG_OLD_TS=bedrock-now                                                   # Tailscale: Service base, node (-node), tag (tag:)
# The test suites' name pair (a throwaway beside a live install): only with the testing switch on
if [ "${DEVOS_ADE_TESTING:-${BEDROCK_NOW_TESTING:-}}" = 1 ] && [ -n "${MG_TEST_OLD_PROJECT:-}" ] && [ -n "${MG_TEST_NEW_PROJECT:-}" ]; then
  MG_OLD_PROJECT="$MG_TEST_OLD_PROJECT"; MG_NEW_PROJECT="$MG_TEST_NEW_PROJECT"
  MG_OLD_HOST="$MG_OLD_PROJECT.localhost"; MG_NEW_HOST="$MG_NEW_PROJECT.localhost"
  MG_OLD_PREVIEW="$MG_OLD_PROJECT-preview.localhost"; MG_NEW_PREVIEW="$MG_NEW_PROJECT-preview.localhost"
  MG_OLD_TS="$MG_OLD_PROJECT"
fi
MG_IMAGE_CPS=100000000   # bytes per second a volume copy is expected to run at (the estimate shown)

# --- WHAT THIS MIGRATION MAY CHANGE (one place; tests/test_migrate.sh asserts it) ---
# Every mutation below goes through one of these checks and refuses anything else: never ~/.local/state/devos-heavy,
# Companion's or Mobile's files, xirp folders, or another Docker project (bn-dev, bne2e-*, a second copy).
#   dir      the install folder (old or new name) and, for the symlink, its parent entry
#   volume   <old project>_* and <new project>_* (exactly: "bedrock-now-2_x" is another project)
#   image    <old project>/* and <new project>/*   network/container: labelled with the old or new project
#   launchd  io.bedrock-now.* / io.devos-ade.* and the runtimes' dev.devos.ade.<runtime>.<sum> in ~/Library/LaunchAgents
#   systemd  bedrock-now-helper-* / devos-ade-helper-* units in the user's unit folder
#   bin      ~/.local/bin/devos-claude and claude-bedrock, only while they link into the install folder
#   config   ~/.config/devos-ade (and the old name) INSIDE the terminal-home volume, never on this computer
#   host     the workspace's and its project folders' trash/tmp folders (TERMINAL_WORKSPACE and one level below), the ./stack open
#            window profile folder, and ~/.claude-bedrock's claude-md-hint marker: exactly the pairs mg_host_targets lists
MG_ALLOWED_KINDS="dir volume image network container launchd systemd bin config host"
MG_FORBIDDEN_NOTE="never: devos-heavy, Companion, Mobile, xirp, other Docker projects"

# mg_allowed KIND VALUE -> 0 when this migration may change VALUE
mg_allowed() {
  local kind="$1" v="$2" b
  case "$kind" in
    dir) [ "$v" = "$MG_OLD_DIR" ] || [ "$v" = "$MG_NEW_DIR" ] || [ "$v" = "${MG_OLD_DIR%/*}/$MG_OLD_DIRNAME" ]; return ;;
    volume) case "$v" in "$MG_OLD_PROJECT"_* | "$MG_NEW_PROJECT"_*) return 0 ;; esac
      [ "${MG_PARTIAL:-0}" = 1 ] && [ -n "${MG_PROJ:-}" ] && case "$v" in "$MG_PROJ"_*) return 0 ;; esac; return 1 ;;
    host) mg_host_targets | awk -F'\t' -v v="$v" '$1 == v || $2 == v { f = 1 } END { exit !f }'; return ;;
    image) case "$v" in "$MG_OLD_PROJECT"/* | "$MG_NEW_PROJECT"/*) return 0 ;; esac; return 1 ;;
    network | container) case "$v" in "$MG_OLD_PROJECT" | "$MG_NEW_PROJECT") return 0 ;; esac; return 1 ;;
    launchd) b="${v##*/}"; b="${b%.plist}"; b="${b%.pre-devos-ade}"; b="${b%.rolled-back}"
      case "$b" in "$MG_OLD_LABEL"* | "$MG_NEW_LABEL"* | dev.devos.ade.*.[0-9]*) ;; *) return 1 ;; esac
      case "$v" in "$(mg_launchagents_dir)"/*) return 0 ;; esac; return 1 ;;
    systemd) b="${v##*/}"; case "$b" in "$MG_OLD_UNIT"-*.service* | "$MG_NEW_UNIT"-*.service*) ;; *) return 1 ;; esac
      case "$v" in "$(mg_systemd_dir)"/*) return 0 ;; esac; return 1 ;;
    bin) case "$v" in "$HOME/.local/bin/devos-claude" | "$HOME/.local/bin/claude-bedrock") return 0 ;; esac; return 1 ;;
    config) case "$v" in .config/"$MG_OLD_CONF" | .config/"$MG_NEW_CONF" | "$MG_OLD_TRASH" | "$MG_NEW_TRASH" | "$MG_OLD_TMP" | "$MG_NEW_TMP") return 0 ;; esac; return 1 ;;
  esac
  return 1
}
# mg_guard KIND VALUE -> dies (nothing more is changed) when VALUE is not on the list
mg_guard() { mg_allowed "$1" "$2" || die "migration: refusing to change $1 '$2': not one of this install's own ($MG_FORBIDDEN_NOTE). Nothing more was changed."; }

mg_launchagents_dir() { printf '%s\n' "${MG_LAUNCHAGENTS_DIR:-${HELPER_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}}"; }
mg_systemd_dir() { printf '%s\n' "${MG_SYSTEMD_DIR:-${HELPER_SYSTEMD_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}}"; }
mg_os() { printf '%s\n' "${MG_OS:-$(uname -s)}"; }

# --- places ---
# mg_init — MG_OLD_DIR (this install's folder, resolved), MG_NEW_DIR (its folder under the new name; the same when its
# name is not the old one), MG_MV (1 when it has to move), MG_DIR (where it is now: the marker's folder)
mg_init() {
  MG_IN_INIT=1
  MG_OLD_DIR="$(cd "$STACK_DIR" && pwd -P)"
  MG_LOGICAL_DIR="$(cd "$STACK_DIR" && pwd)"
  if [ "${MG_OLD_DIR##*/}" = "$MG_OLD_DIRNAME" ]; then MG_NEW_DIR="${MG_OLD_DIR%/*}/$MG_NEW_DIRNAME"; MG_MV=1
  elif [ "${MG_OLD_DIR##*/}" = "$MG_NEW_DIRNAME" ] && [ -f "$(mg_marker_file_at "$MG_OLD_DIR")" ]; then
    # already moved (this process started from the new folder): the old folder is where the symlink was
    MG_NEW_DIR="$MG_OLD_DIR"; MG_OLD_DIR="${MG_OLD_DIR%/*}/$MG_OLD_DIRNAME"; MG_MV=1
  else MG_NEW_DIR="$MG_OLD_DIR"; MG_MV=0; fi
  MG_DIR="$MG_OLD_DIR"; [ -d "$MG_OLD_DIR" ] && [ ! -L "$MG_OLD_DIR" ] || MG_DIR="$MG_NEW_DIR"
  [ -f "$MG_DIR/.env" ] || MG_DIR="$(cd "$STACK_DIR" 2>/dev/null && pwd -P || printf '%s' "$STACK_DIR")"
  # An install of another project (a second copy, bn-dev …) keeps its project, volumes and hostname: a PARTIAL move (names only)
  local cur; cur="$(ENV_FILE="$MG_DIR/.env" get_env COMPOSE_PROJECT_NAME 2>/dev/null || true)"
  MG_PARTIAL=0; MG_PROJ="$MG_OLD_PROJECT"; MG_NEWPROJ="$MG_NEW_PROJECT"
  if [ "$(mg_get mode)" = partial ] || { [ -z "$(mg_get mode)" ] && [ -n "$cur" ] && [ "$cur" != "$MG_OLD_PROJECT" ] && [ "$cur" != "$MG_NEW_PROJECT" ]; }; then
    MG_PARTIAL=1; MG_PROJ="${cur:-$(mg_get project)}"; MG_NEWPROJ="$MG_PROJ"
  fi
  MG_IN_INIT=
}
mg_marker_file_at() { printf '%s/.state/migrate/marker\n' "$1"; }
mg_marker() { [ -n "${MG_DIR:-}" ] || [ -n "${MG_IN_INIT:-}" ] || mg_init; mg_marker_file_at "$MG_DIR"; }
mg_get() { [ -f "$(mg_marker)" ] || return 0; K="$1" awk -F= '$1 == ENVIRON["K"] { v = substr($0, length($1) + 2) } END { printf "%s", v }' "$(mg_marker)"; }
mg_put() {
  local f tmp; f="$(mg_marker)"; mkdir -p "${f%/*}" && chmod 700 "${f%/*}"
  tmp="$(mktemp "$f.XXXXXX")" || die "migration: cannot write $f"
  { [ ! -f "$f" ] || K="$1" awk -F= '$1 != ENVIRON["K"]' "$f"; printf '%s=%s\n' "$1" "$2"; } > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; die "migration: cannot write $f"; }
}
mg_done_p() { [ -n "$(mg_get "step.$1")" ]; }
mg_step_done() { mg_put "step.$1" "$(date +%s)"; }
mg_status() { mg_get status; }

# --- docker, small ---
mg_old_volumes() { [ "${MG_PARTIAL:-0}" != 1 ] || return 0; docker volume ls -q 2>/dev/null | awk -v p="${MG_OLD_PROJECT}_" 'index($0, p) == 1' | grep -v -- '-owner$' || true; }
mg_new_volumes() { [ "${MG_PARTIAL:-0}" != 1 ] || return 0; docker volume ls -q 2>/dev/null | awk -v p="${MG_NEW_PROJECT}_" 'index($0, p) == 1' || true; }
# mg_new_clash -> the new project's volumes in the move's way: all of them but THIS install's own owner marker. With no project
# in .env, the new code's ./stack update claims its default name, the new one, before the move starts (lib/guard.sh, from the
# dispatcher): that marker names this folder, and the owner step writes it again for the new folder (JON-945).
mg_new_clash() {
  local m="${MG_NEW_PROJECT}_${MG_NEW_DIRNAME}-owner" own
  own="$(docker volume inspect --format "{{index .Labels \"$MG_NEW_OWNER_LABEL\"}}" "$m" 2>/dev/null || true)"
  case "$own" in /*) own="$(cd "$own" 2>/dev/null && pwd -P || printf '%s' "$own")" ;; *) own='' ;; esac
  if [ -n "$own" ] && { [ "$own" = "$MG_OLD_DIR" ] || [ "$own" = "$MG_NEW_DIR" ]; }; then
    mg_new_volumes | grep -vxF -- "$m" || true
  else mg_new_volumes; fi
}
mg_short() { printf '%s\n' "${1#"${MG_OLD_PROJECT}"_}"; }
mg_is_socket_vol() { case "$1" in *-socket) return 0 ;; esac; return 1; }
mg_image() {
  local i="${MG_IMAGE:-}"
  [ -n "$i" ] || i="$(compose_service_image postgres 2>/dev/null || true)"
  [ -n "$i" ] && docker image inspect "$i" >/dev/null 2>&1 || die "migration: no local image to copy with (the postgres image of this release is not here yet: ./stack update pulls it; or set MG_IMAGE). Nothing was changed."
  printf '%s\n' "$i"
}
# mg_run_in IMAGE OP ARGS... (volume mounts in MG_MOUNTS) — a throwaway container, no network, root, the script in $MG_SCRIPT
mg_run_in() {
  local img="$1" w; shift
  # Docker makes a named volume that is not there (empty): a copy of "nothing" must never pass for a copy of the data
  for w in $MG_MOUNTS; do
    [ "$w" != -v ] || continue
    case "${w%%:*}" in /* | */*) continue ;; esac   # (a folder of this computer, not a volume)
    docker volume inspect "${w%%:*}" >/dev/null 2>&1 || { warn "migration: the volume ${w%%:*} is not there"; return 1; }
  done
  # shellcheck disable=SC2086  # MG_MOUNTS: -v options, one word each
  docker run --rm --user 0 --network none --entrypoint sh $MG_MOUNTS "$img" -c "$MG_SCRIPT" "$@"   # ($0 is the op name)
}
MG_SUM_SH='for d in "$1" "$2"; do cd "$d" || exit 1
n=$(find . -mindepth 1 | wc -l | tr -d " ")
b=$(find . -type f -exec stat -c %s {} + | awk "{s+=\$1} END{print s+0}")
m=$(find . -mindepth 1 -printf "%p %m %U %G %y %l\n" | LC_ALL=C sort | sha256sum | cut -d" " -f1)
c=$(find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2 | sha256sum | cut -d" " -f1)
printf "count=%s bytes=%s meta=%s sum=%s\n" "$n" "$b" "$m" "$c"; done'
MG_COPY_SH='cp -a "$1"/. "$2"/'
MG_DU_SH='du -sk "$1" | cut -f1'
MG_DF_SH='df -Pk "$1" | awk "NR==2{print \$4}"'
MG_RBCOPY_SH='find "$2" -mindepth 1 -delete && cp -a "$1"/. "$2"/'
MG_RENAME_SH='cd "$1" || exit 0
ren() { if [ -e "$1" ] && [ ! -e "$2" ]; then mv "$1" "$2"; fi; }
ren ".config/$2" ".config/$3"; for d in . .claude .config; do ren "$d/$4" "$d/$5"; ren "$d/$6" "$d/$7"; done
ren ".claude-bedrock/$8" ".claude-bedrock/$9"'

mg_vol_kb() { MG_MOUNTS="-v $1:/v:ro" MG_SCRIPT="$MG_DU_SH" mg_run_in "${MG_IMG:-$(mg_image)}" mg-du /v 2>/dev/null | tail -n 1; }
mg_total_kb() {
  local v t=0 k
  for v in $(mg_old_volumes); do k="$(mg_vol_kb "$v")"; case "$k" in '' | *[!0-9]*) k=0 ;; esac; t=$((t + k)); done
  printf '%s\n' "$t"
}
mg_eta() { local s=$(($1 * 1024 / MG_IMAGE_CPS + 20)); if [ "$s" -ge 90 ]; then printf 'about %s minutes' $(((s + 59) / 60)); else printf 'under 2 minutes'; fi; }
mg_fmt_kb() { fmt_bytes $(($1 * 1024)); }

# --- the steps ---
MG_STEPS='preflight record stop copy inner host env images move owner paths launchd'   # (in order; each step.X is set when done)
# mg_stopped_at — where a move that is not finished stopped: its first step not done (failed or interrupted alike; a failed_step
# of an earlier try that was resumed is past), and for the copy the volume it was copying
mg_stopped_at() {
  local s v
  for s in $MG_STEPS; do
    mg_done_p "$s" && continue
    v=''; [ "$s" != copy ] || v="$(awk -F= '$1 ~ /^vol\./ && $2 == "copying" { print substr($1, 5); exit }' "$(mg_marker)" 2>/dev/null)"
    printf '%s%s' "$s" "${v:+ ($v)}"; return 0
  done
  printf 'its last step'
}
mg_fail() { # mg_fail STEP MESSAGE — the marker says where it stopped; the old project stays runnable
  mg_put status failed; mg_put failed_step "$1"
  die "migration to $MG_NEW_PROJECT failed at '$1': $2 — your data is untouched (the old volumes were only read). Run ./stack update (or ./stack migrate --now) to resume, or ./stack migrate --rollback to go back. Until then ./stack up refuses to start anything (a half-moved install must not run): the two ways out are ./stack update (it resumes) and ./stack migrate --rollback (it goes back). Your data stays in the old volumes (${MG_OLD_PROJECT}_*), unchanged."
}

mg_step_preflight() {
  local v k need free ws clash
  if [ "$MG_PARTIAL" = 1 ]; then mg_step_preflight_partial; return 0; fi
  [ -n "$(mg_old_volumes)" ] || mg_fail preflight "no volumes of project $MG_OLD_PROJECT"
  clash="$(mg_new_clash)"
  if [ -n "$clash" ]; then
    mg_fail preflight "project $MG_NEW_PROJECT already has volumes ($(printf '%s\n' "$clash" | tr '\n' ' ')), made by an earlier try or another install. Look at them; remove them yourself (docker volume rm …) if they are not wanted. Nothing was changed."
  fi
  if [ "$MG_MV" = 1 ] && ! mg_done_p move; then
    [ ! -e "$MG_NEW_DIR" ] && [ ! -L "$MG_NEW_DIR" ] || mg_fail preflight "$MG_NEW_DIR exists already — move it aside, then run ./stack update again. Nothing was changed."
    [ "$(mg_dev "$MG_OLD_DIR")" = "$(mg_dev "${MG_NEW_DIR%/*}")" ] ||
      mg_fail preflight "$MG_NEW_DIR would be on another file system than $MG_OLD_DIR: moving would copy tens of GB of models. Put the folder on one file system, or move it yourself. Nothing was changed."
  fi
  k="$(mg_total_kb)"; need=$((k + k / 10 + 1))
  MG_MOUNTS="-v $(mg_old_volumes | head -n 1):/v:ro" MG_SCRIPT="$MG_DF_SH" free="$(mg_run_in "$MG_IMG" mg-df /v 2>/dev/null | tail -n 1)"
  case "$free" in '' | *[!0-9]*) mg_fail preflight "cannot read the free disk space" ;; esac
  [ "$free" -ge "$need" ] || mg_fail preflight "not enough disk space: the copy needs $(mg_fmt_kb "$need") (the old volumes $(mg_fmt_kb "$k") plus 10%) and Docker has $(mg_fmt_kb "$free") free. Free some space (./stack clean), then run ./stack update again. Nothing was changed."
  ws="$(du -sk "$MG_DIR/.state" 2>/dev/null | cut -f1 || true)"
  mg_put kb_total "$k"
  # .env as the person had it, before this migration touches it (the first backup stands)
  if [ ! -f "$MG_DIR/.env.pre-devos-ade" ]; then cp -p "$ENV_FILE" "$MG_DIR/.env.pre-devos-ade" && chmod 600 "$MG_DIR/.env.pre-devos-ade" || mg_fail preflight "cannot back .env up"; fi
  log "migration: $MG_OLD_PROJECT → $MG_NEW_PROJECT. Copying $(mg_fmt_kb "$k") of volumes ($(mg_eta "$k")); the folder and ${ws:+its $(mg_fmt_kb "$ws") of }models move by rename, with no copy. Disk free: $(mg_fmt_kb "$free")."
  mg_step_done preflight
}
# a partial move changes names only: no volume copy, so no disk check; the folder move (only when it is ~/bedrock-now) is checked as in the full one
mg_step_preflight_partial() {
  mg_put mode partial; mg_put project "$MG_PROJ"
  if [ "$MG_MV" = 1 ] && ! mg_done_p move; then
    [ ! -e "$MG_NEW_DIR" ] && [ ! -L "$MG_NEW_DIR" ] || mg_fail preflight "$MG_NEW_DIR exists already — move it aside, then run ./stack update again. Nothing was changed."
    [ "$(mg_dev "$MG_OLD_DIR")" = "$(mg_dev "${MG_NEW_DIR%/*}")" ] || mg_fail preflight "$MG_NEW_DIR would be on another file system than $MG_OLD_DIR. Nothing was changed."
  fi
  if [ ! -f "$MG_DIR/.env.pre-devos-ade" ]; then cp -p "$ENV_FILE" "$MG_DIR/.env.pre-devos-ade" && chmod 600 "$MG_DIR/.env.pre-devos-ade" || mg_fail preflight "cannot back .env up"; fi
  log "migration: renaming this install's own names (project $MG_PROJ keeps its volumes, ports and hostname)."
  mg_step_done preflight
}
mg_dev() { stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null; }

mg_step_stop() {
  local c n cur
  if [ "$MG_PARTIAL" = 1 ]; then mg_step_done stop; return 0; fi
  cur="$(get_env COMPOSE_PROJECT_NAME)"
  if [ -z "$cur" ]; then mg_put pinned 1; elif [ "$cur" = "$MG_OLD_PROJECT" ]; then mg_put explicit 1; fi
  [ "$cur" = "$MG_OLD_PROJECT" ] || set_env COMPOSE_PROJECT_NAME "$MG_OLD_PROJECT"   # the old project stays the one ./stack runs until the copy is verified
  for c in $(docker ps -aq --filter "label=com.docker.compose.project=$MG_OLD_PROJECT" 2>/dev/null); do
    mg_guard container "$MG_OLD_PROJECT"; docker stop "$c" >/dev/null 2>&1 || true; docker rm "$c" >/dev/null 2>&1 || true
  done
  for n in $(docker network ls -q --filter "label=com.docker.compose.project=$MG_OLD_PROJECT" 2>/dev/null); do
    mg_guard network "$MG_OLD_PROJECT"; docker network rm "$n" >/dev/null 2>&1 || true
  done
  mg_step_done stop
}

# mg_alive PID -> 0 while the process runs (a finished child nobody has waited for yet is a zombie: kill -0 still answers for it)
mg_alive() { local st; st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"; [ -n "$st" ] && [ "${st#Z}" = "$st" ]; }
mg_progress() { # mg_progress PID NEWVOL TOTAL_KB — a line of progress every few seconds while the copy runs
  local pid="$1" nv="$2" tot="$3" k pct
  while mg_alive "$pid"; do
    sleep "${MG_POLL_S:-3}"
    k="$(MG_MOUNTS="-v $nv:/v:ro" MG_SCRIPT="$MG_DU_SH" mg_run_in "$MG_IMG" mg-du /v 2>/dev/null | tail -n 1)"
    case "$k" in '' | *[!0-9]*) continue ;; esac
    pct=0; [ "$tot" -le 0 ] || pct=$((k * 100 / tot)); [ "$pct" -le 99 ] || pct=99
    log "  $(mg_short_new "$nv"): $(mg_fmt_kb "$k") of $(mg_fmt_kb "$tot") ($pct%)"
  done
}
mg_short_new() { printf '%s\n' "${1#"${MG_NEW_PROJECT}"_}"; }

mg_copy_one() { # mg_copy_one OLDVOL
  local ov="$1" s nv st tot rc=0 pid out a b
  s="$(mg_short "$ov")"; nv="${MG_NEW_PROJECT}_$s"
  mg_guard volume "$ov"; mg_guard volume "$nv"
  st="$(mg_get "vol.$s")"
  [ "$st" != verified ] || { log "  $s: copied and verified before"; return 0; }
  if docker volume inspect "$nv" >/dev/null 2>&1; then
    # ours only (the marker says copying/failed): a partial copy of an interrupted run is made again from the start
    case "$st" in copying | failed | stale) docker volume rm "$nv" >/dev/null 2>&1 || mg_fail copy "cannot remove the partial $nv" ;;
      *) mg_fail copy "volume $nv exists and is not from this migration" ;; esac
  fi
  mg_put "vol.$s" copying
  docker volume create --label "com.docker.compose.project=$MG_NEW_PROJECT" --label "com.docker.compose.volume=$s" "$nv" >/dev/null || mg_fail copy "cannot create $nv"
  if mg_is_socket_vol "$s"; then mg_put "vol.$s" verified; log "  $s: a socket folder, made empty"; return 0; fi
  tot="$(MG_MOUNTS="-v $ov:/v:ro" MG_SCRIPT="$MG_DU_SH" mg_run_in "$MG_IMG" mg-du /v 2>/dev/null | tail -n 1)"; case "$tot" in '' | *[!0-9]*) tot=0 ;; esac
  log "  $s: copying $(mg_fmt_kb "$tot")"
  MG_MOUNTS="-v $ov:/from:ro -v $nv:/to" MG_SCRIPT="$MG_COPY_SH" mg_run_in "$MG_IMG" mg-copy /from /to &
  pid=$!
  mg_progress "$pid" "$nv" "$tot"
  wait "$pid" || rc=$?
  [ "$rc" = 0 ] || { mg_put "vol.$s" failed; mg_fail copy "copying $s failed (status $rc)"; }
  out="$(MG_MOUNTS="-v $ov:/from:ro -v $nv:/to:ro" MG_SCRIPT="$MG_SUM_SH" mg_run_in "$MG_IMG" mg-sum /from /to 2>&1)" || { mg_put "vol.$s" failed; mg_fail copy "could not read $s back to check it"; }
  a="$(printf '%s\n' "$out" | sed -n 1p)"; b="$(printf '%s\n' "$out" | sed -n 2p)"
  if [ -z "$a" ] || [ "$a" != "$b" ]; then
    mg_put "vol.$s" failed; docker volume rm "$nv" >/dev/null 2>&1 || true
    mg_fail copy "the copy of $s does not match the original (original: ${a:-none}; copy: ${b:-none}); the copy was removed"
  fi
  mg_put "vol.$s.sum" "$a"; mg_put "vol.$s" verified
  log "  $s: verified ($(printf '%s' "$a" | sed 's/ meta=.*//'))"
}
mg_step_copy() { local v; if [ "$MG_PARTIAL" = 1 ]; then mg_step_done copy; return 0; fi; for v in $(mg_old_volumes); do mg_copy_one "$v"; done; mg_step_done copy; }

mg_step_inner() { # names inside the NEW terminal-home (never on this computer)
  local nv="${MG_NEWPROJ}_terminal-home"
  docker volume inspect "$nv" >/dev/null 2>&1 || { mg_step_done inner; return 0; }
  mg_allowed config ".config/$MG_NEW_CONF" || die "migration: internal list error"
  mg_guard volume "$nv"
  MG_MOUNTS="-v $nv:/h" MG_SCRIPT="$MG_RENAME_SH" mg_run_in "${MG_IMG:-$(mg_image)}" mg-rename /h "$MG_OLD_CONF" "$MG_NEW_CONF" "$MG_OLD_TRASH" "$MG_NEW_TRASH" "$MG_OLD_TMP" "$MG_NEW_TMP" "$MG_OLD_HINT" "$MG_NEW_HINT" >/dev/null 2>&1 || mg_fail inner "could not rename the sandbox's own folders in $nv"
  mg_sample_check "$nv"
  mg_step_done inner
}
# mg_sample_check NEWVOL — the sandbox home's sample files, the old .config/<old name> (source) against the new one (copy), WHILE the stack is
# down and nothing writes to either; the result is kept in the marker (verify does not look at live files)
mg_sample_check() {
  local a b img="${MG_IMG:-$(mg_image)}"
  a="$(MG_MOUNTS="-v ${MG_OLD_PROJECT}_terminal-home:/v:ro" MG_SCRIPT="$MG_SAMPLE_SH" mg_run_in "$img" mg-sample /v ".config/$MG_OLD_CONF" 2>/dev/null | tail -n 1)"
  b="$(MG_MOUNTS="-v $1:/v:ro" MG_SCRIPT="$MG_SAMPLE_SH" mg_run_in "$img" mg-sample /v ".config/$MG_NEW_CONF" 2>/dev/null | tail -n 1)"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then mg_put sample ok; else mg_put sample "differs (old '$a', new '$b')"; fi
}

# mg_host_targets -> OLD<TAB>NEW pairs on this computer that this install owns (the enumerated 'host' list): the trash/tmp folders of the
# workspace and of the project folders directly in it (the Code page's roots), the ./stack open window profile, the claude-md-hint marker
mg_host_targets() {
  local ws d k base name cfg proj="${MG_PROJ:-$MG_OLD_PROJECT}"
  ws="$(ENV_FILE="${MG_DIR:-$STACK_DIR}/.env" get_env TERMINAL_WORKSPACE 2>/dev/null || true)"
  if [ -n "$ws" ] && [ -d "$ws" ] && [ ! -L "$ws" ]; then
    for k in TRASH TMP; do
      eval "printf '%s\t%s\n' \"\$ws/\$MG_OLD_$k\" \"\$ws/\$MG_NEW_$k\""
    done
    for d in "$ws"/*/; do
      d="${d%/}"; [ -d "$d" ] && [ ! -L "$d" ] || continue
      for k in TRASH TMP; do eval "printf '%s\t%s\n' \"\$d/\$MG_OLD_$k\" \"\$d/\$MG_NEW_$k\""; done
    done
  fi
  case "$(mg_os)" in Darwin) base="$HOME/Library/Application Support" ;; *) base="${XDG_DATA_HOME:-$HOME/.local/share}" ;; esac
  if [ "$proj" = "$MG_OLD_PROJECT" ] || [ "$proj" = "$MG_NEW_PROJECT" ]; then printf '%s\t%s\n' "$base/$MG_OLD_OPEN" "$base/$MG_NEW_OPEN"
  else printf '%s\t%s\n' "$base/$MG_OLD_OPEN-$proj" "$base/$MG_NEW_OPEN-$proj"; fi
  cfg="${CLAUDE_BEDROCK_CONFIG_DIR:-$HOME/.claude-bedrock}"
  printf '%s\t%s\n' "$cfg/$MG_OLD_HINT" "$cfg/$MG_NEW_HINT"
}
# mg_host_rename [back] — renames each pair whose old name exists and new one does not (back: the other way)
mg_host_rename() {
  local a b t
  while IFS="$(printf '\t')" read -r a b; do
    [ -n "$a" ] || continue
    if [ "${1:-}" = back ]; then t="$a"; a="$b"; b="$t"; fi
    if { [ -e "$a" ] || [ -L "$a" ]; } && [ ! -e "$b" ] && [ ! -L "$b" ]; then mg_guard host "$a"; mg_guard host "$b"; mv "$a" "$b" || warn "migration: could not rename $a"; fi
  done <<EOF
$(mg_host_targets)
EOF
}
mg_step_host() { mg_host_rename; mg_step_done host; }
# the owner marker the new code looks for (<project>_devos-ade-owner, label io.devos-ade.dir = the folder): made again, not copied
mg_step_owner() {
  local m="${MG_NEWPROJ}_${MG_NEW_DIRNAME}-owner" cur
  mg_guard volume "$m"
  cur="$(docker volume inspect --format "{{index .Labels \"$MG_NEW_OWNER_LABEL\"}}" "$m" 2>/dev/null || true)"
  if [ "$cur" != "$MG_NEW_DIR" ]; then
    ! docker volume inspect "$m" >/dev/null 2>&1 || docker volume rm "$m" >/dev/null 2>&1 || true
    docker volume create --label "$MG_NEW_OWNER_LABEL=$MG_NEW_DIR" --label "$MG_NEW_OWNER_PROJ_LABEL=$MG_NEWPROJ" "$m" >/dev/null 2>&1 || warn "migration: could not make the owner marker $m (./stack up makes it)"
  fi
  mg_step_done owner
}

# mg_env_xlate FROMPFX TOPFX DOHOST FROMHOST TOHOST FROMPREV TOPREV REVERSE — .env: the prefix of the keys and, when asked, the host names in values.
# REVERSE=1: a key that exists under both spellings keeps the value of the one being renamed (the current one).
mg_env_xlate() {
  local tmp; tmp="$(mktemp "$ENV_FILE.XXXXXX")" || return 1
  OP="$1" NP="$2" DOH="$3" OH="$4" NH="$5" OV="$6" NV="$7" REV="$8" DOV="${9:-$3}" awk '
    BEGIN { op = ENVIRON["OP"]; np = ENVIRON["NP"] }
    { lines[NR] = $0; i = index($0, "="); if (i > 0) { k0 = substr($0, 1, i - 1); have[k0] = 1; if (index(k0, op) == 1) ren[np substr(k0, length(op) + 1)] = 1 } }
    END {
      for (n = 1; n <= NR; n++) {
        l = lines[n]; i = index(l, "="); k = (i > 0) ? substr(l, 1, i - 1) : ""; v = (i > 0) ? substr(l, i + 1) : l
        if (k != "" && ENVIRON["REV"] == "1" && (k in ren)) continue
        if (k != "" && index(k, op) == 1) { nk = np substr(k, length(op) + 1); if (ENVIRON["REV"] != "1" && (nk in have)) continue; k = nk }
        if (ENVIRON["DOV"] == "1" && k != "") {
          while ((p = index(v, ENVIRON["OV"])) > 0) v = substr(v, 1, p - 1) ENVIRON["NV"] substr(v, p + length(ENVIRON["OV"]))
        }
        if (ENVIRON["DOH"] == "1" && k != "") {
          while ((p = index(v, ENVIRON["OH"])) > 0) v = substr(v, 1, p - 1) ENVIRON["NH"] substr(v, p + length(ENVIRON["OH"]))
        }
        if (k != "") print k "=" v; else print l
      }
    }' "$ENV_FILE" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$ENV_FILE" || { rm -f "$tmp"; return 1; }
}
# mg_ts_base -> the Tailscale Service base this install had (lib/remote.sh ts_base before the rename)
mg_ts_base() {
  if [ "$MG_PARTIAL" = 1 ]; then printf '%s-%s\n' "$MG_OLD_TS" "$(printf '%s' "$MG_PROJ" | tr '_' '-' | sed 's/-*$//')"; else printf '%s\n' "$MG_OLD_TS"; fi
}
mg_step_env() {
  local bak="$MG_DIR/.env.pre-devos-ade" ph pd oldp=0 oldv=0 tsb
  [ -f "$ENV_FILE" ] || mg_fail env "no .env"
  if [ ! -f "$bak" ]; then cp -p "$ENV_FILE" "$bak" && chmod 600 "$bak" || mg_fail env "cannot back .env up"; fi   # (made at preflight; here only if that was skipped)
  ph="$(get_env PORTAL_HOST)"
  # (a partial move keeps its hostname: its project name is in it)
  pd="$(get_env PREVIEW_DOMAIN)"
  # (the host and the preview domain are moved each on its own: any other value is kept)
  if [ "$MG_PARTIAL" != 1 ]; then
    { [ -z "$ph" ] || [ "$ph" = "$MG_OLD_HOST" ]; } && oldp=1
    { [ "$pd" = "$MG_OLD_PREVIEW" ] || { [ -z "$pd" ] && [ "$oldp" = 1 ]; }; } && oldv=1
  fi
  mg_env_xlate "$MG_OLD_ENV_PREFIX" "$MG_NEW_ENV_PREFIX" "$oldp" "$MG_OLD_HOST" "$MG_NEW_HOST" "$MG_OLD_PREVIEW" "$MG_NEW_PREVIEW" 0 "$oldv" || mg_fail env "cannot rewrite .env"
  if [ "$MG_PARTIAL" != 1 ]; then
    # The pin made at 'stop' goes now: the copy is verified. An explicit old project name becomes the new one.
    if [ "$(mg_get pinned)" = 1 ]; then unset_env COMPOSE_PROJECT_NAME
    elif [ "$(get_env COMPOSE_PROJECT_NAME)" = "$MG_OLD_PROJECT" ]; then set_env COMPOSE_PROJECT_NAME "$MG_NEW_PROJECT"; fi
  fi
  # The email every store is keyed by: setup wrote it to .env at the first setup (OPENWEBUI_ADMIN_EMAIL), and Open WebUI, LiteLLM and the
  # git server read it from there, so nothing in them changes. A .env without it is pinned to the old default.
  if [ -z "$(get_env OPENWEBUI_ADMIN_EMAIL)" ]; then set_env OPENWEBUI_ADMIN_EMAIL "$MG_OLD_EMAIL"; mg_put email_pinned "$MG_OLD_EMAIL"; fi
  # Tailscale: the Service names, the node and the tag are tailnet-side names (policy, approvals): not renamed here. New installs default to
  # the new names, so an install that had the old defaults must pin them or its remote URL would change.
  if [ "$(get_env REMOTE_MODE)" = tailscale ]; then
    tsb="$(mg_ts_base)"
    [ -n "$(get_env TS_SERVICE)" ] || { set_env TS_SERVICE "$tsb"; mg_put ts_pinned 1; }
    [ -n "$(get_env TS_HOSTNAME)" ] || set_env TS_HOSTNAME "$tsb-node"
    [ -n "$(get_env TS_TAG)" ] || set_env TS_TAG "tag:$MG_OLD_TS"
  fi
  mg_put host_moved "$oldp"
  mg_step_done env
}

mg_step_images() {
  local r t
  # (a partial move keeps its images: they are named <project>/<service>:local, and the project does not change)
  if [ "$MG_PARTIAL" = 1 ]; then mg_step_done images; return 0; fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue; mg_guard image "$r"
    # (every tag, :previous too: the images ./stack rollback goes back to, the same image IDs, offline)
    t="${MG_NEW_PROJECT}/${r#*/}"; docker image inspect "$t" >/dev/null 2>&1 || docker tag "$r" "$t" >/dev/null 2>&1 || true
  done <<EOF
$(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=$MG_OLD_PROJECT/*" 2>/dev/null)
EOF
  mg_record_delete_list
  mg_step_done images
}

mg_step_move() {
  if [ "$MG_MV" = 1 ] && [ ! -d "$MG_NEW_DIR" ]; then
    mg_guard dir "$MG_OLD_DIR"; mg_guard dir "$MG_NEW_DIR"
    [ ! -L "$MG_OLD_DIR" ] || mg_fail move "$MG_OLD_DIR is already a link"
    mv "$MG_OLD_DIR" "$MG_NEW_DIR" || mg_fail move "mv $MG_OLD_DIR $MG_NEW_DIR failed (nothing was copied; look at the folder)"
    ln -s "$MG_NEW_DIR" "$MG_OLD_DIR" || mg_fail move "moved the folder but could not leave the link $MG_OLD_DIR → $MG_NEW_DIR: ln -s $MG_NEW_DIR $MG_OLD_DIR"
  fi
  if [ "$MG_MV" = 1 ] && [ ! -e "$MG_OLD_DIR" ] && [ ! -L "$MG_OLD_DIR" ]; then ln -s "$MG_NEW_DIR" "$MG_OLD_DIR" || mg_fail move "could not leave the link $MG_OLD_DIR → $MG_NEW_DIR"; fi
  if [ "$MG_MV" = 1 ]; then
    MG_DIR="$MG_NEW_DIR"
    STACK_DIR="$MG_NEW_DIR"; ENV_FILE="$MG_NEW_DIR/.env"; STATE_DIR="$MG_NEW_DIR/.state"; export STACK_DIR
  fi
  mg_step_done move
}

# mg_path_re DIR -> DIR as an extended regular expression
mg_path_re() { printf '%s' "$1" | sed 's/[][\.*^$(){}?+|]/\\&/g'; }
# mg_rewrite_text FILE OLD NEW — OLD (as a whole path component: not the start of ".../bedrock-now-workspace") becomes NEW
mg_rewrite_text() {
  local f="$1" o n tmp d; d=$'\001'; o="$(mg_path_re "$2")"; n="$(printf '%s' "$3" | sed 's/[&\]/\\&/g')"
  tmp="$(mktemp "${TMPDIR:-/tmp}/mg.XXXXXX")" || return 1
  if sed -E "s${d}${o}(\$|[^A-Za-z0-9._-])${d}${n}\\1${d}g" "$f" > "$tmp" && ! cmp -s "$f" "$tmp"; then cat "$tmp" > "$f"; fi
  rm -f "$tmp"
}
mg_has_old() { grep -IlE -- "$(mg_path_re "$2")(\$|[^A-Za-z0-9._-])" "$1" >/dev/null 2>&1; }
# mg_rewrite_tree DIR OLD NEW — text records and generated files of the install (not git, backups, models)
mg_rewrite_tree() {
  local root="$1" old="$2" new="$3" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mg_has_old "$f" "$old" || continue
    mg_rewrite_text "$f" "$old" "$new"
  done <<EOF
$(find "$root/.state" "$root/litellm" "$root/searxng" "$root/tailscale" "$root/.env" \( -path '*/mlx/hf' -o -name blobs -o -name .git -o -name node_modules \) -prune -o -type f -size -2048k -print 2>/dev/null)
EOF
}
# mg_relink_tree DIR OLD NEW — symlinks under DIR with an absolute target in OLD
mg_relink_tree() {
  local root="$1" old="$2" new="$3" l t rest
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    t="$(readlink "$l")"
    case "$t" in "$old") rest='' ;; "$old"/*) rest="${t#"$old"}" ;; *) continue ;; esac
    ln -sfn "$new$rest" "$l"
  done <<EOF
$(find "$root" -path "$root/.git" -prune -o -path "$root/backups" -prune -o -type l -print 2>/dev/null)
EOF
}
# mg_skipped_with_path ROOT OLD — files the rewrite does not read (over 2 MB, or binary) that still hold OLD as a path
mg_skipped_with_path() {
  local root="$1" old="$2" f big
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *.db | *.sqlite | *.sqlite3) big=1 ;; *) big=0 ;; esac
    if [ "$big" = 1 ] || [ -n "$(find "$f" -size +2047k 2>/dev/null)" ] || ! grep -Iq . "$f" 2>/dev/null; then
      LC_ALL=C grep -aqE -- "$(mg_path_re "$old")(\$|[^A-Za-z0-9._-])" "$f" 2>/dev/null && printf '%s\n' "$f"
    fi
  done <<EOF
$(find "$root/.state" "$root/litellm" "$root/searxng" "$root/tailscale" \( -path '*/mlx/hf' -o -path '*/hf/hub' -o -path '*/.lmstudio/models' -o -path '*/.lmstudio/.internal' -o -path '*/runtimes/llamacpp/models' -o -path '*/runtimes/vllm/models' -o -path '*/runtimes/*/models' -o -path '*/runtimes/*/hf' -o -name blobs -o -name models -o -name .git -o -name node_modules \) -prune -o -type f ! \( -name '*.gguf' -o -name '*.safetensors' -o -name '*.bin' -o -name '*.npz' -o -name '*.mlx' \) -print 2>/dev/null)
EOF
  return 0
}
# mg_sqlite_rewrite FILE OLD NEW — the text columns of a sqlite file (the Code page's records) that name OLD/… or OLD; one transaction
mg_sqlite_rewrite() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -I - "$1" "$2" "$3" <<'PY' >/dev/null 2>&1
import re, sqlite3, sys
f, o, n = sys.argv[1:4]
# the old path must start the cell or follow a non-path character, and end the cell or be followed by "/" , a quote or another non-path character
pat = re.compile(r"(?<![A-Za-z0-9._/-])" + re.escape(o) + r"(?![A-Za-z0-9._-])")
c = sqlite3.connect(f, isolation_level=None)
try:
    c.execute("pragma wal_checkpoint(TRUNCATE)")
    c.execute("begin immediate")
    for (t,) in c.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%'").fetchall():
        tt = '"%s"' % t.replace('"', '""')
        for col in [r[1] for r in c.execute("pragma table_info(%s)" % tt).fetchall()]:
            q = '"%s"' % col.replace('"', '""')
            for rid, v in c.execute("select rowid, %s from %s where typeof(%s) = 'text' and instr(%s, ?) > 0" % (q, tt, q, q), (o,)).fetchall():
                nv = pat.sub(lambda m: n, v)
                if nv != v:
                    c.execute("update %s set %s = ? where rowid = ?" % (tt, q), (nv, rid))
    c.execute("commit")
except Exception:
    try: c.execute("rollback")
    except Exception: pass
    sys.exit(1)
finally:
    c.close()
if __import__("os").path.exists(f + "-wal") and __import__("os").path.getsize(f + "-wal") > 0:
    sys.exit(2)
PY
}
# mg_paths_left_behind ROOT OLD NEW — after the rewrite: sqlite files are rewritten; any other skipped file still naming OLD is listed (a warning, and a file in the marker's folder)
mg_paths_left_behind() {
  local root="$1" old="$2" new="$3" f list n=0 failed=''
  list="$(mg_skipped_with_path "$root" "$old")"                                       # (once: the models are never read)
  while IFS= read -r f; do
    case "$f" in *.db | *.sqlite | *.sqlite3) mg_sqlite_rewrite "$f" "$old" "$new" || failed="$failed $f" ;; *) continue ;; esac
  done <<EOF
$list
EOF
  mkdir -p "$(mg_rec_dir)"
  # what is still named afterwards: the files the rewrite cannot read, and the sqlite files that were not rewritten
  { printf '%s\n' "$list" | grep -vE '\.(db|sqlite|sqlite3)$' || true; for f in $failed; do printf '%s\n' "$f"; done; } | sed '/^$/d' > "$(mg_rec_dir)/paths-left-behind.txt"
  n="$(grep -c . "$(mg_rec_dir)/paths-left-behind.txt" 2>/dev/null || true)"; n="${n:-0}"
  mg_put paths_left_behind "$n"
  [ -z "$failed" ] || warn "migration: sqlite file(s) NOT rewritten (the old folder is still named in them):$failed"
  [ "$n" -eq 0 ] || warn "migration: $n file(s) too big, binary or not rewritable still name the old folder $old (list: $(mg_rec_dir)/paths-left-behind.txt): $(head -n 5 "$(mg_rec_dir)/paths-left-behind.txt" | tr '\n' ' ')$([ "$n" -le 5 ] || printf '…')"
}
mg_step_paths() {
  local o="$MG_OLD_DIR" n="$MG_NEW_DIR" b
  if [ "$o" != "$n" ]; then
    mg_rewrite_tree "$n" "$o" "$n"
    [ "$MG_LOGICAL_DIR" = "$o" ] || mg_rewrite_tree "$n" "$MG_LOGICAL_DIR" "$n"
    mg_relink_tree "$n" "$o" "$n"
    [ "$MG_LOGICAL_DIR" = "$o" ] || mg_relink_tree "$n" "$MG_LOGICAL_DIR" "$n"
    mg_paths_left_behind "$n" "$o" "$n"
    for b in devos-claude claude-bedrock; do
      if [ "$(readlink "$HOME/.local/bin/$b" 2>/dev/null)" = "$o/bin/$b" ] && [ -e "$n/bin/$b" ]; then
        mg_guard bin "$HOME/.local/bin/$b"; ln -sfn "$n/bin/$b" "$HOME/.local/bin/$b"
      fi
    done
  fi
  mg_step_done paths
}

# --- launchd (macOS) and systemd (Linux) ---
mg_sum() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
mg_under_helper() { [ "${DEVOS_ADE_JOB_ORIGIN:-${BEDROCK_NOW_JOB_ORIGIN:-}}" = helper ]; }
# mg_new_plist_text FILE OLDLABEL NEWLABEL OLDSUM NEWSUM -> the plist with the new label and paths
mg_new_plist_text() {
  local f="$1" ol="$2" nl="$3" t hb tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/mgp.XXXXXX")" || return 1
  sed "s|<string>$ol</string>|<string>$nl</string>|g" "$f" > "$tmp"
  mg_rewrite_text "$tmp" "$MG_OLD_DIR" "$MG_NEW_DIR"
  hb="$MG_NEW_DIR/bin/$MG_NEW_UNIT"
  if [ -f "$hb" ]; then sed "s|/bin/$MG_OLD_UNIT|/bin/$MG_NEW_UNIT|g" "$tmp"; else cat "$tmp"; fi
  rm -f "$tmp"
}
# mg_map_label OLDLABEL -> the new label (io.bedrock-now.helper.<project> -> io.devos-ade.helper.<project>; the project changes only in a full move)
mg_map_label() {
  local r="${1#"$MG_OLD_LABEL"}"
  if [ "$MG_PARTIAL" != 1 ] && [ "${r%."$MG_OLD_PROJECT"}" != "$r" ]; then r="${r%."$MG_OLD_PROJECT"}.$MG_NEW_PROJECT"; fi
  printf '%s%s\n' "$MG_NEW_LABEL" "$r"
}
mg_step_launchd() {
  local la f base ol nl nf uid osum nsum helperp=0 t
  la="$(mg_launchagents_dir)"; uid="$(id -u)"
  osum="$(mg_sum "$MG_OLD_DIR/.state")"; nsum="$(mg_sum "$MG_NEW_DIR/.state")"
  if [ "$(mg_os)" = Darwin ] && [ -d "$la" ]; then
    # this install's own agents only: its helper (the project is in its label) and the runtimes' (the folder's sum is in theirs).
    # io.bedrock-now.helper.<another project> belongs to another install and is never touched.
    for f in "$la/${MG_OLD_LABEL}"*."$MG_PROJ".plist "$la"/dev.devos.ade.*."$osum".plist; do
      [ -f "$f" ] || continue
      mg_guard launchd "$f"
      base="${f##*/}"; ol="${base%.plist}"
      case "$ol" in "$MG_OLD_LABEL"*) nl="$(mg_map_label "$ol")" ;; *) [ "$osum" != "$nsum" ] || continue; nl="${ol%."$osum"}.$nsum" ;; esac
      case "$ol" in "$MG_OLD_LABEL"helper.*) helperp=1 ;; *) helperp=0 ;; esac
      nf="$la/$nl.plist"; mg_guard launchd "$nf"
      if [ ! -f "$nf" ]; then
        t="$(mg_new_plist_text "$f" "$ol" "$nl" "$osum" "$nsum")" || mg_fail launchd "cannot read $f"
        printf '%s\n' "$t" > "$nf.tmp" && chmod 644 "$nf.tmp" && mv "$nf.tmp" "$nf" || mg_fail launchd "cannot write $nf"
      fi
      mg_put "lc.$ol" "$nl"
      if [ "$helperp" = 1 ] && mg_under_helper; then
        mg_put helper pending; mg_put helper_old_label "$ol"; mg_put helper_new_label "$nl"
        mg_helper_shim; continue
      fi
      launchctl bootout "gui/$uid/$ol" >/dev/null 2>&1 || true
      mv "$f" "$f.pre-devos-ade"
      launchctl bootstrap "gui/$uid" "$nf" >/dev/null 2>&1 || warn "launchd could not load $nf (./stack runtimes / ./stack helper install load it again)"
    done
  elif [ "$(mg_os)" = Linux ]; then
    mg_systemd_helper
  fi
  mg_step_done launchd
}
# the helper's shim at its OLD path: the old unit's next start (idle) switches to the new one, then runs the real helper
mg_helper_shim() {
  local s="$MG_NEW_DIR/bin/$MG_OLD_UNIT"
  [ ! -e "$s" ] || return 0
  cat > "$s" <<EOF
#!/bin/bash
# Written by the move to devos-ade (JON-807): the old helper unit starts here once; this switches it to the new unit.
D=$(printf '%q' "$MG_NEW_DIR")
[ ! -x "\$D/stack" ] || "\$D/stack" migrate --finish-helper >/dev/null 2>&1 || true
h="\$D/bin/$MG_NEW_UNIT"; [ -f "\$h" ] || h="\$D/bin/$MG_OLD_UNIT.real"
[ -f "\$h" ] && exec /bin/bash "\$h" "\${@:-\$D}"
exit 0
EOF
  chmod 755 "$s"
  # not a tracked file: git must not see it (the update's clean-tree check ignores untracked files anyway)
  [ ! -d "$MG_NEW_DIR/.git/info" ] || grep -qxF "/bin/$MG_OLD_UNIT" "$MG_NEW_DIR/.git/info/exclude" 2>/dev/null || printf '/bin/%s\n' "$MG_OLD_UNIT" >> "$MG_NEW_DIR/.git/info/exclude"
}
mg_systemd_helper() {
  local d f nf ol nl
  d="$(mg_systemd_dir)"; [ -d "$d" ] || return 0
  for f in "$d/$MG_OLD_UNIT-$MG_PROJ.service"; do
    [ -f "$f" ] || continue
    mg_guard systemd "$f"
    ol="${f##*/}"; nl="$MG_NEW_UNIT-${MG_NEWPROJ}.service"; nf="$d/$nl"; mg_guard systemd "$nf"
    if [ ! -f "$nf" ]; then
      mg_new_plist_text "$f" x x 0 0 | sed "s|$MG_OLD_UNIT-$MG_PROJ|$MG_NEW_UNIT-$MG_NEWPROJ|g" > "$nf.tmp" && chmod 644 "$nf.tmp" && mv "$nf.tmp" "$nf"
    fi
    if mg_under_helper; then mg_put helper pending; mg_put helper_old_label "$ol"; mg_put helper_new_label "$nl"; mg_helper_shim; continue; fi
    mg_systemd_switch "$ol" "$nl" "$f"
  done
}
mg_systemd_switch() {
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now "$2" >/dev/null 2>&1 || warn "systemd could not start $2"
  systemctl --user disable --now "$1" >/dev/null 2>&1 || true
  [ ! -f "$3" ] || mv "$3" "$3.pre-devos-ade"
}
# migrate_finish_helper — the old helper unit's first idle start (bin/<old helper name> shim): load the new unit, end the old
migrate_finish_helper() {
  local uid la ol nl f
  mg_init; [ "$(mg_get helper)" = pending ] || return 0
  ol="$(mg_get helper_old_label)"; nl="$(mg_get helper_new_label)"; uid="$(id -u)"
  if [ "$(mg_os)" = Darwin ]; then
    la="$(mg_launchagents_dir)"; f="$la/$ol.plist"; mg_guard launchd "$la/$nl.plist"
    launchctl bootstrap "gui/$uid" "$la/$nl.plist" >/dev/null 2>&1 || return 1
    mg_put helper done
    [ ! -f "$f" ] || mv "$f" "$f.pre-devos-ade"
    launchctl bootout "gui/$uid/$ol" >/dev/null 2>&1 || true   # (ends this very process: the new helper runs)
  else
    f="$(mg_systemd_dir)/$ol"; mg_put helper done; mg_systemd_switch "$ol" "$nl" "$f"
  fi
}

# --- the whole of phase A, and the update's two hooks ---
# mg_partial_needed -> 0 when an install of another project still has old names of its own: .env keys, a launchd agent or systemd unit of its
# project, a folder named like the old install's, or the host folders/files of the old names
mg_partial_needed() {
  local la a b
  grep -q "^$MG_OLD_ENV_PREFIX" "$MG_DIR/.env" 2>/dev/null && return 0
  [ "$MG_MV" = 1 ] && [ "$MG_OLD_DIR" != "$MG_NEW_DIR" ] && return 0
  la="$(mg_launchagents_dir)"; [ ! -f "$la/${MG_OLD_LABEL}helper.$MG_PROJ.plist" ] || return 0
  [ ! -f "$(mg_systemd_dir)/$MG_OLD_UNIT-$MG_PROJ.service" ] || return 0
  while IFS="$(printf '\t')" read -r a b; do
    [ -z "$a" ] || { { [ -e "$a" ] || [ -L "$a" ]; } && [ ! -e "$b" ] && return 0; }
  done <<EOF
$(mg_host_targets)
EOF
  return 1
}
mg_needed() {
  local st cur own; st="$(mg_status)"
  case "$st" in complete | moved) return 1 ;; running | failed) return 0 ;; esac
  [ -f "$MG_DIR/.env" ] || return 1   # (an install has its .env in its folder)
  [ "$MG_PARTIAL" != 1 ] || { mg_partial_needed && docker info >/dev/null 2>&1; return; }
  cur="$(get_env COMPOSE_PROJECT_NAME)"; { [ -z "$cur" ] || [ "$cur" = "$MG_OLD_PROJECT" ]; } || return 1
  docker info >/dev/null 2>&1 || return 1
  [ -n "$(mg_old_volumes)" ] || return 1
  # Only the checkout that owns the old project moves it (another folder's install of the old name is not this one's)
  own="$(docker volume inspect --format "{{index .Labels \"$MG_OLD_OWNER_LABEL\"}}" "${MG_OLD_PROJECT}_${MG_OLD_DIRNAME}-owner" 2>/dev/null || true)"
  [ -z "$own" ] || [ "$own" = "<no value>" ] || [ "$(cd "$own" 2>/dev/null && pwd -P || printf '%s' "$own")" = "$MG_OLD_DIR" ] || return 1
}
# mg_reverify — a RESUME: whatever the old project did since an earlier try copied a volume (the old stack may have run again) is not in that
# copy. Each volume that was copied is compared with its source again; one that differs is copied afresh, which redoes stop, record and copy.
mg_reverify() {
  local ov s nv out a b stale=0 st
  for ov in $(mg_old_volumes); do
    s="$(mg_short "$ov")"; nv="${MG_NEW_PROJECT}_$s"
    [ "$(mg_get "vol.$s")" = verified ] || continue
    mg_is_socket_vol "$s" && continue
    if ! docker volume inspect "$nv" >/dev/null 2>&1; then mg_put "vol.$s" stale; stale=1; continue; fi
    # (the copy itself may have been changed on purpose since, by the inner step: the SOURCE is compared with what it was when it was copied)
    out="$(MG_MOUNTS="-v $ov:/from:ro" MG_SCRIPT="$MG_SUM_SH" mg_run_in "$MG_IMG" mg-sum /from /from 2>&1)" || out=''
    a="$(printf '%s\n' "$out" | sed -n 1p)"; b="$(mg_get "vol.$s.sum")"
    if [ -z "$a" ] || [ "$a" != "$b" ]; then mg_put "vol.$s" stale; stale=1; log "  $s: changed since it was copied — it is copied again"; fi
  done
  [ "$stale" = 0 ] || for st in record stop copy inner; do mg_put "step.$st" ""; done   # (record counts again what it can: a stopped database is not counted, and then the old copy is kept)
}
mg_phase_a() {
  local resumed=0; [ -z "$(mg_get started)" ] || resumed=1
  [ -n "$(mg_get started)" ] || mg_put started "$(date +%s)"
  mg_put status running; mg_put from_dir "$MG_OLD_DIR"; mg_put to_dir "$MG_NEW_DIR"
  local s
  docker info >/dev/null 2>&1 || mg_fail preflight "Docker is not running"
  MG_IMG="$(mg_image)" || mg_fail preflight "no image to copy with"
  [ "$resumed" = 0 ] || [ "$MG_PARTIAL" = 1 ] || mg_done_p env || mg_reverify
  for s in $MG_STEPS; do
    mg_done_p "$s" || "mg_step_$s"
  done
  mg_put status moved
}

# migrate_refuse_up — ./stack up / setup while the move is half done: the old project must not run on volumes that are being copied, nor the
# new one on a copy that is not complete. Two ways out are named.
migrate_refuse_up() {
  mg_init
  case "$(mg_status)" in running | failed) ;; *) return 0 ;; esac
  die "the move to the name $MG_NEW_PROJECT is not finished (stopped at: $(mg_stopped_at)), so nothing is started. Either: ./stack update   (resumes it), or: ./stack migrate --rollback   (goes back)."
}

# migrate_unfinished -> 0 while a move is started and not complete (./stack update has it to finish, also with no new version)
migrate_unfinished() {
  mg_init
  case "$(mg_status)" in running | failed | moved) return 0 ;; esac
  return 1
}

# migrate_update_hook — in ./stack update, with the new code checked out, before images and setup
migrate_update_hook() {
  mg_init
  mg_remove_leftovers
  mg_needed || return 0
  if [ "$MG_PARTIAL" = 1 ]; then log "update: renaming this install's own names to devos-ade (project $MG_PROJ, its volumes and address stay)"
  else log "update: moving this install from the name $MG_OLD_PROJECT to $MG_NEW_PROJECT (your data is copied, the old copy is kept)"; fi
  mg_phase_a
  if [ "$MG_MV" = 1 ] && [ "$MG_NEW_DIR" != "$MG_OLD_DIR" ]; then
    log "update: continuing from $MG_NEW_DIR"
    cd "$MG_NEW_DIR" || return 1
    if [ "${ASSUME_YES:-0}" = 1 ]; then exec "$MG_NEW_DIR/stack" update --yes; else exec "$MG_NEW_DIR/stack" update; fi
  fi
  return 0
}

# migrate_update_finish — after the update's setup: the stack runs as the new project; check it and write the end
migrate_update_finish() {
  mg_init
  [ "$(mg_status)" = moved ] || return 0
  local bad
  if [ "$MG_PARTIAL" = 1 ]; then mg_put status complete; mg_put finished "$(date +%s)"; log "This install now uses the DevOS ADE names (project $MG_PROJ and its address are unchanged). Its old .env is kept as .env.pre-devos-ade."; return 0; fi
  bad="$(docker ps -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" --filter health=unhealthy 2>/dev/null || true)"
  [ -z "$bad" ] || warn "migration: a container of $MG_NEW_PROJECT is unhealthy (./stack status); the old copy of your data is kept (./stack migrate --rollback goes back)"
  [ -n "$(docker ps -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" 2>/dev/null || true)" ] || { warn "migration: nothing of $MG_NEW_PROJECT runs yet — ./stack up; the migration is finished when it does (./stack migrate)"; return 0; }
  mg_put status complete; mg_put finished "$(date +%s)"
  log "DevOS ADE now lives at http://$(portal_host) (the old address forwards there). Sign in again once there, and install the app again from the new address."
  mg_verify_and_clean
  migrate_backup_line | sed 's/^/    /' >&2
  return 0
}

# migrate_backup_line — what is kept from before the move, for ./stack status, the update's end and Home
migrate_backup_line() {
  mg_init
  case "$(mg_status)" in complete | moved) ;; *) return 0 ;; esac
  [ -z "$(mg_get old_removed)" ] || return 0
  if [ "$MG_PARTIAL" = 1 ]; then printf 'This install now uses the DevOS ADE names; the old .env is kept as .env.pre-devos-ade until the next update removes it.\n'; return 0; fi
  case "$(mg_get old_copy)" in
    removed) [ -z "$(mg_get leftovers_removed)" ] || return 0
      printf 'The move to %s was verified and the old copy was removed (%s freed). .env.pre-devos-ade and the old folder link go with the next update.\n' "$MG_NEW_PROJECT" "$(mg_fmt_kb "$(mg_get freed_kb)")" ;;
    kept) printf 'The old copy of the install (the %s_* volumes, %s) was KEPT because a check failed: %s. ./stack migrate --verify tries again; ./stack migrate --rollback goes back; ./stack migrate --remove-old removes it.\n' "$MG_OLD_PROJECT" "$(mg_fmt_kb "$(mg_get kb_total)")" "$(mg_get verify_failed)" ;;
    removing) printf 'Removing the old copy (%s_*) stopped before it was done; what is left is on a list. ./stack migrate --verify continues.\n' "$MG_OLD_PROJECT" ;;
    *) printf 'The move to %s is not verified yet; the old copy (%s) is removed once it is: ./stack migrate --verify\n' "$MG_NEW_PROJECT" "$(mg_fmt_kb "$(mg_get kb_total)")" ;;
  esac
}

# --- the old copy is removed by itself once the cutover is verified (owner decision, JON-807 item 11) ---
# Row counts of every table of every database of the OLD Postgres, read while the old stack still runs (before it is stopped)
MG_PGQ_SH=$(cat <<'EOS'
psql -U "${POSTGRES_USER:-postgres}" -d "$1" -Atc "select table_name || E'\t' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1"
EOS
)
MG_PGDB_SH=$(cat <<'EOS'
psql -U "${POSTGRES_USER:-postgres}" -d postgres -Atc "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1"
EOS
)
MG_REPOS_SH='find "$1" -type d -name "*.git" -prune | wc -l | tr -d " "'
MG_FSCK_SH='command -v git >/dev/null 2>&1 || { echo nogit; exit 0; }
find "$1" -type d -name "*.git" -prune | { n=0; bad=0; while IFS= read -r r; do n=$((n + 1))
if [ -f "$r/HEAD" ] && [ -d "$r/objects" ]; then git -c safe.directory="*" --git-dir="$r" fsck --connectivity-only >/dev/null 2>&1 || bad=$((bad + 1))
else bad=$((bad + 1)); fi; done; echo "$n $bad"; }'
MG_SAMPLE_SH='cd "$1/$2" 2>/dev/null || { echo none; exit 0; }
find . -type f | LC_ALL=C sort | head -n 20 | while IFS= read -r f; do cksum < "$f"; done | cksum'

mg_pg_container() { docker ps -q --filter "label=com.docker.compose.project=$1" --filter "label=com.docker.compose.service=postgres" 2>/dev/null | head -n 1; }
# mg_pg_counts PROJECT DB -> "table<TAB>rows" lines (empty and failing when the database cannot be read)
mg_pg_counts() {
  local c; c="$(mg_pg_container "$1")"; [ -n "$c" ] || return 1
  docker exec "$c" sh -c "$MG_PGQ_SH" sh "$2" 2>/dev/null
}
mg_pg_dbs() { local c; c="$(mg_pg_container "$1")"; [ -n "$c" ] || return 1; docker exec "$c" sh -c "$MG_PGDB_SH" 2>/dev/null; }
mg_rec_dir() { printf '%s/.state/migrate\n' "$MG_DIR"; }

# step 'record': before the old stack stops, what its databases hold (the new stack is compared with it). A stack that is not running
# cannot be counted: nothing is deleted then (the old copy stays; ./stack migrate says so).
mg_step_record() {
  local db out dir n=0
  if [ "$MG_PARTIAL" = 1 ]; then mg_step_done record; return 0; fi
  dir="$(mg_rec_dir)"; mkdir -p "$dir"
  if declare -F rt_state >/dev/null; then
    for db in $(ls "$MG_DIR/.state/runtimes" 2>/dev/null); do [ "$(rt_state "$db" 2>/dev/null)" != running ] || mg_put "rt.$db" running; done
  fi
  # which installed runtimes' programs run now (rtok.ID 1 or 0): after the move a 0 is said, not counted — one that did not
  # run before is not the move's doing. Only a recorded 0 relaxes the check: no rtok.ID (a marker of an earlier build) is strict.
  for db in "$MG_DIR"/.state/runtimes/*/ "$MG_DIR/.state/mlx/"; do
    [ -d "$db" ] || continue; db="${db%/}"
    if mg_rt_ok "${db##*/}" "$db"; then mg_put "rtok.${db##*/}" 1; else mg_put "rtok.${db##*/}" 0; fi
  done
  for db in $(mg_pg_dbs "$MG_OLD_PROJECT"); do
    out="$(mg_pg_counts "$MG_OLD_PROJECT" "$db")" && [ -n "$out" ] || { n=-1; break; }
    printf '%s\n' "$out" > "$dir/pgrows-$db.tsv"; n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then mg_put pg_recorded 1; log "  recorded the row counts of $n database(s) of $MG_OLD_PROJECT (checked after the move, before the old copy is removed)"
  else mg_put pg_recorded 0; log "  the old databases could not be counted (is the stack running?): the old copy will be kept, not removed"; fi
  mg_step_done record
}

# mg_verify_cutover -> 0 when everything is as before; else MG_VERIFY_WHY says what failed (nothing is deleted then)
# mg_rt_bin ID DIR — the program of an installed runtime (empty when this kind has none to run)
mg_rt_bin() {
  case "$1" in
    lmstudio) awk -F'\t' 'NR == 1 { print $1 }' "$2/llmster.run" 2>/dev/null ;;
    llamacpp) for b in "$2/bin/llama-server" "$2/llama-server"; do [ -e "$b" ] && { printf '%s\n' "$b"; break; }; done ;;
    vllm) [ ! -e "$2/venv/bin/python" ] || printf '%s\n' "$2/venv/bin/python" ;;
    mlx) [ ! -e "$2/venv/bin/python" ] || printf '%s\n' "$2/venv/bin/python" ;;
  esac
}
# mg_run_limited SECONDS CMD… — a version command must not hang the update
mg_run_limited() {
  local t="$1" pid i=0; shift
  "$@" >/dev/null 2>&1 & pid=$!
  while mg_alive "$pid"; do [ "$i" -lt "$((t * 5))" ] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; }; sleep 0.2; i=$((i + 1)); done
  wait "$pid"
}
# mg_rt_ok ID DIR -> 0 when the runtime's program runs from DIR (its version command; MLX: mlx_lm imports), 1 when not
# (MG_RT_WHY says why), 2 when there is nothing to run (no program found)
mg_rt_ok() {
  local id="$1" d="$2" bin
  bin="$(mg_rt_bin "$id" "$d")"; MG_RT_WHY=''
  [ -n "$bin" ] || return 2
  [ -x "$bin" ] || { MG_RT_WHY="runtime $id: its program $bin is not there or cannot run"; return 1; }
  if [ "$id" = mlx ]; then
    mg_run_limited 20 "$bin" -I -c 'import mlx_lm' || { MG_RT_WHY="runtime mlx: $bin cannot import mlx_lm from the moved folder"; return 1; }
    return 0
  fi
  mg_run_limited 20 "$bin" --version || { MG_RT_WHY="runtime $id: $bin --version does not run from the moved folder"; return 1; }
}
# mg_check_runtimes — each installed runtime's program that ran before the update (rtok.ID, step 'record') runs from the moved
# folder, and a runtime that was running before the update is running after it. One that did not run before is said, not counted.
mg_check_runtimes() {
  local d id k r
  for d in "$MG_DIR"/.state/runtimes/*/ "$MG_DIR/.state/mlx/"; do
    [ -d "$d" ] || continue; d="${d%/}"; id="${d##*/}"
    [ "$id" != mlx ] || [ -e "$d/venv/bin/python" ] || continue
    r=0; mg_rt_ok "$id" "$d" || r=$?
    case "$r" in
      2) # (nothing was checked: said, never counted as checked; an empty folder of a runtime that is not installed is nothing)
        [ -n "$(ls -A "$d" 2>/dev/null)" ] && { MG_VERIFY_NOTE="${MG_VERIFY_NOTE:+$MG_VERIFY_NOTE; }runtime $id: its program was not found, so it was not checked"; warn "migration: runtime $id: its program was not found, so it was not checked"; } ;;
      1) [ "$(mg_get "rtok.$id")" = 0 ] || { MG_VERIFY_WHY="$MG_RT_WHY"; return 1; }
        MG_VERIFY_NOTE="${MG_VERIFY_NOTE:+$MG_VERIFY_NOTE; }$MG_RT_WHY (it did not run before the update either)"
        warn "migration: $MG_RT_WHY — it did not run before the update either, so the move is not why" ;;
    esac
  done
  for k in $(grep '^rt\.' "$(mg_marker)" 2>/dev/null | cut -d= -f1); do
    id="${k#rt.}"
    [ "$(mg_get "$k")" = running ] || continue
    ! declare -F rt_state >/dev/null || [ "$(rt_state "$id")" = running ] || { MG_VERIFY_WHY="runtime $id was running before the update and is not running after it"; return 1; }
  done
  return 0
}
mg_verify_cutover() {
  local s st f db new old t n o ids bad r cwd img gimg oldrepos newrepos a b rec users_old users_new chats_old chats_new
  MG_VERIFY_WHY=''; MG_VERIFY_NOTE=''
  [ "$MG_PARTIAL" != 1 ] || { MG_VERIFY_WHY="a partial move has no old volumes"; return 1; }
  # 1. every copy matched
  for s in $(mg_old_volumes); do
    st="$(mg_get "vol.$(mg_short "$s")")"; [ "$st" = verified ] || { MG_VERIFY_WHY="the copy of ${s#"${MG_OLD_PROJECT}"_} is not marked verified ($st)"; return 1; }
  done
  # 2. every service healthy on the new project
  ids="$(docker ps -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" 2>/dev/null || true)"
  [ -n "$ids" ] || { MG_VERIFY_WHY="nothing of $MG_NEW_PROJECT is running"; return 1; }
  bad="$(docker ps -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" --filter health=unhealthy 2>/dev/null || true)"
  [ -z "$bad" ] || { MG_VERIFY_WHY="a service of $MG_NEW_PROJECT is unhealthy"; return 1; }
  bad="$(docker ps -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" --filter status=restarting 2>/dev/null || true)"
  [ -z "$bad" ] || { MG_VERIFY_WHY="a service of $MG_NEW_PROJECT keeps restarting"; return 1; }
  # 3. the databases on the running stack hold at least the rows the old ones held (nothing is missing)
  [ "$(mg_get pg_recorded)" = 1 ] || { MG_VERIFY_WHY="the old databases were not counted before the move (the stack was not running)"; return 1; }
  rec="$(mg_rec_dir)"; users_old=''; chats_old=''
  for f in "$rec"/pgrows-*.tsv; do
    [ -f "$f" ] || continue; db="${f##*/pgrows-}"; db="${db%.tsv}"
    new="$(mg_pg_counts "$MG_NEW_PROJECT" "$db")" && [ -n "$new" ] || { MG_VERIFY_WHY="the database $db cannot be read on $MG_NEW_PROJECT"; return 1; }
    while IFS="$(printf '\t')" read -r t o; do
      [ -n "$t" ] || continue
      n="$(printf '%s\n' "$new" | awk -F'\t' -v t="$t" '$1 == t { print $2 }')"
      case "$n" in '' | *[!0-9]*) MG_VERIFY_WHY="table $db.$t is missing on $MG_NEW_PROJECT"; return 1 ;; esac
      [ "$n" -ge "$o" ] || { MG_VERIFY_WHY="table $db.$t has $n rows on $MG_NEW_PROJECT, the old one had $o"; return 1; }
      if [ "$db" = openwebui ]; then case "$t" in user) users_old="$o"; users_new="$n" ;; chat) chats_old="$o"; chats_new="$n" ;; esac; fi
    done < "$f"
  done
  [ -z "$users_old" ] || MG_VERIFY_NOTE="Open WebUI: $users_new user(s), $chats_new chat(s) (before: $users_old, $chats_old)"
  # 4. the git server's repositories are all listed
  img="${MG_IMG:-$(mg_image)}"
  oldrepos="$(MG_MOUNTS="-v ${MG_OLD_PROJECT}_gitdata:/v:ro" MG_SCRIPT="$MG_REPOS_SH" mg_run_in "$img" mg-repos /v 2>/dev/null | tail -n 1)"
  newrepos="$(MG_MOUNTS="-v ${MG_NEW_PROJECT}_gitdata:/v:ro" MG_SCRIPT="$MG_REPOS_SH" mg_run_in "$img" mg-repos /v 2>/dev/null | tail -n 1)"
  if docker volume inspect "${MG_NEW_PROJECT}_gitdata" >/dev/null 2>&1 && docker volume inspect "${MG_OLD_PROJECT}_gitdata" >/dev/null 2>&1; then
    case "$oldrepos$newrepos" in '' | *[!0-9]*) MG_VERIFY_WHY="the git server's repositories cannot be counted"; return 1 ;; esac
    [ "$newrepos" -ge "$oldrepos" ] || { MG_VERIFY_WHY="the git server lists $newrepos repositories, the old one had $oldrepos"; return 1; }
    # (run in the git server's own image, which has git; none here, or no git in it: the check FAILS and the old copy is kept)
    gimg="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(codeberg.org\/forgejo\/forgejo[^[:space:]#]*\).*/\1/p' "$MG_DIR/compose.yaml" 2>/dev/null | head -n 1)"
    [ -n "$gimg" ] && docker image inspect "$gimg" >/dev/null 2>&1 || { MG_VERIFY_WHY="git fsck cannot run: the git server's image (${gimg:-not named in compose.yaml}) is not on this computer"; return 1; }
    a="$(MG_MOUNTS="-v ${MG_NEW_PROJECT}_gitdata:/v:ro" MG_SCRIPT="$MG_FSCK_SH" mg_run_in "$gimg" mg-fsck /v 2>/dev/null | tail -n 1)"
    case "$a" in nogit) MG_VERIFY_WHY="git fsck cannot run: no git in $gimg"; return 1 ;; *" 0") ;; *) MG_VERIFY_WHY="git fsck on the moved repositories: ${a:-no answer} (repositories, damaged)"; return 1 ;; esac
  fi
  # 5. sample files of the sandbox's home match (the old .config/<old name> against the new one)
  # (compared at the inner step, with the stack down: mg_sample_check)
  if docker volume inspect "${MG_NEW_PROJECT}_terminal-home" >/dev/null 2>&1; then
    [ "$(mg_get sample)" = ok ] || { MG_VERIFY_WHY="sample files of the sandbox's home did not match when they were copied: $(mg_get sample)"; return 1; }
  fi
  # 6. the runtimes' records name places that exist in the moved folder
  for f in "$MG_DIR"/.state/runtimes/*/llmster.run; do
    [ -f "$f" ] || continue
    cwd="$(awk -F'\t' 'NR == 1 { print $2 }' "$f")"
    [ -z "$cwd" ] || [ -d "$cwd" ] || { MG_VERIFY_WHY="a runtime's record ($f) names $cwd, which is not there"; return 1; }
    ! grep -qF -- "$MG_OLD_DIR/" "$f" || [ "$MG_OLD_DIR" = "$MG_NEW_DIR" ] || { MG_VERIFY_WHY="a runtime's record ($f) still names the old folder"; return 1; }
  done
  mg_check_runtimes || return 1
  for f in "$MG_DIR"/.state/runtimes/*/home/.lmstudio-home-pointer; do
    [ -f "$f" ] || continue; [ -d "$(head -n 1 "$f")" ] || { MG_VERIFY_WHY="LM Studio's home pointer names a folder that is not there"; return 1; }
  done
  return 0
}

# mg_sync — the marker and its folder reach the disk (a power cut after the first removal must find "verified" there)
mg_sync() { sync 2>/dev/null || true; }
# mg_record_delete_list — the exact list that may be deleted (volumes with their sizes, image tags), written once, at the end of the copy work:
# del.N=KIND|KB|NAME. Nothing outside it is ever removed by the automatic clean-up.
mg_record_delete_list() {
  local kind name kb n=0 list
  [ "$MG_PARTIAL" != 1 ] || return 0
  [ -z "$(mg_get del.n)" ] || return 0
  list="$(mg_remove_list | awk -F'\t' '$1 == "volume" || $1 == "image"')"
  while IFS="$(printf '\t')" read -r kind name kb; do
    [ -n "$kind" ] || continue; n=$((n + 1)); mg_put "del.$n" "$kind|${kb:-0}|$name"
  done <<EOF
$list
EOF
  mg_put del.n "$n"
}
# mg_delete_old_copy — the old project's volumes and the old image tags, after mg_verify_cutover passed. The launchd/systemd leftovers,
# .env.pre-devos-ade and the old folder link wait for the next update (migrate_update_hook).
mg_delete_old_copy() {
  local n i v kind rest kb name tot=0 nv=0 ni=0 failed=0
  [ -n "$(mg_get del.n)" ] || mg_record_delete_list
  n="$(mg_get del.n)"; n="${n:-0}"; i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1)); v="$(mg_get "del.$i")"; [ -n "$v" ] || continue
    [ "$(mg_get "delok.$i")" != 1 ] || continue
    kind="${v%%|*}"; rest="${v#*|}"; kb="${rest%%|*}"; name="${rest#*|}"
    case "$kind" in
      volume) mg_guard volume "$name"
        if ! docker volume inspect "$name" >/dev/null 2>&1 || docker volume rm "$name" >/dev/null 2>&1; then
          mg_put "delok.$i" 1; log "  removed volume $name ($i of $n)"
        else warn "migration: could not remove volume $name (it stays on the list)"; failed=$((failed + 1)); fi ;;
      image) mg_guard image "$name"
        if ! docker image inspect "$name" >/dev/null 2>&1 || docker rmi "$name" >/dev/null 2>&1; then
          mg_put "delok.$i" 1; log "  removed image tag $name ($i of $n)"
        else warn "migration: could not remove image tag $name (it stays on the list)"; failed=$((failed + 1)); fi ;;
    esac
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1)); [ "$(mg_get "delok.$i")" = 1 ] || continue; v="$(mg_get "del.$i")"; kind="${v%%|*}"; rest="${v#*|}"; kb="${rest%%|*}"
    case "$kind" in volume) nv=$((nv + 1)); tot=$((tot + ${kb:-0})) ;; image) ni=$((ni + 1)) ;; esac
  done
  mg_put old_volumes_removed "$nv"; mg_put freed_kb "$tot"
  if [ "$failed" = 0 ]; then
    mg_put old_copy removed
    log "the move to $MG_NEW_PROJECT is verified; the old copy is removed: $nv volume(s) and $ni image tag(s), $(mg_fmt_kb "$tot") freed${MG_VERIFY_NOTE:+ ($MG_VERIFY_NOTE)}"
  else
    mg_put old_copy removing
    warn "migration: $failed item(s) of the old copy could not be removed and are still on the list; ./stack migrate --verify continues"
  fi
}

# mg_verify_and_clean — migrate_update_finish and ./stack migrate --verify
mg_verify_and_clean() {
  local i
  [ "$(mg_get old_copy)" != removed ] || return 0
  # Once the checks are written down as passed, deleting has started or may start: no check is run again, a resume only continues the deletes
  if [ "$(mg_get verified)" = 1 ]; then mg_delete_old_copy; return 0; fi
  if mg_verify_cutover; then
    for i in 1 2 3 4 5 6; do mg_put "chk.$i" ok; done
    mg_put verify_failed ''; mg_put verify_note "$MG_VERIFY_NOTE"
    mg_record_delete_list
    mg_put verified 1; mg_sync                       # (written to the disk BEFORE the first removal)
    mg_delete_old_copy
  else
    mg_put old_copy kept; mg_put verify_failed "$MG_VERIFY_WHY"
    warn "migration: the old copy is KEPT, nothing was deleted: $MG_VERIFY_WHY. Your data is in the $MG_NEW_PROJECT volumes. ./stack migrate --verify tries the checks again; ./stack migrate --rollback goes back; ./stack migrate --remove-old deletes the old copy even so."
  fi
}

# the leftovers of the move go with the NEXT update (the update that finished the move has status 'complete' only at its end)
mg_remove_leftovers() {
  local f
  [ "$(mg_status)" = complete ] && [ -z "$(mg_get leftovers_removed)" ] || return 0
  [ "$(mg_get old_copy)" = removed ] || return 0
  [ ! -f "$MG_DIR/.env.pre-devos-ade" ] || rm -f "${MG_DIR:?}/.env.pre-devos-ade"
  # (the old folder's link stays while the helper's shim still points through it: migrate --finish-helper has not run yet)
  if [ -L "$MG_OLD_DIR" ] && [ "$MG_OLD_DIR" != "$MG_NEW_DIR" ] && [ "$(mg_get helper)" != pending ]; then mg_guard dir "$MG_OLD_DIR"; rm -f "${MG_OLD_DIR:?}"; fi
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue; mg_guard launchd "$f" 2>/dev/null || mg_guard systemd "$f"; rm -f "${f:?}"
  done <<EOF
$(mg_pre_files)
EOF
  if [ "$(mg_get helper)" = pending ]; then log "update: removed the leftovers of the move to $MG_NEW_PROJECT except the old folder's link (the update helper still needs it; the next update removes it)"; return 0; fi
  mg_put leftovers_removed "$(date +%s)"
  log "update: removed the leftovers of the move to $MG_NEW_PROJECT (.env.pre-devos-ade, the old folder link, the old launchd files)"
}

# --- ./stack migrate ---
migrate_usage() {
  cat <<EOF
usage: ./stack migrate [--now | --verify | --rollback | --remove-old [--yes] | --finish-helper]
  (none)         the state of the move from $MG_OLD_PROJECT to $MG_NEW_PROJECT
  --now          run (or resume) the move by hand; ./stack update does this by itself
  --verify       check the moved install again and, when everything matches, remove the old copy (the update does this by itself)
  --rollback     go back to $MG_OLD_PROJECT: its folder, .env, launchd names; the current data is copied back (the $MG_NEW_PROJECT volumes stay, unused)
  --remove-old   remove the old copy now, even when a check failed (lists it, asks)
EOF
}
migrate_status() {
  mg_init
  case "$(mg_status)" in
    '') if mg_needed; then echo "not moved yet: this install is still the project $MG_OLD_PROJECT. ./stack update moves it ($(mg_eta "$(mg_total_kb 2>/dev/null || echo 0)"))."; else echo "nothing to move: this install is not under the old name $MG_OLD_PROJECT."; fi ;;
    running | failed) echo "the move is not finished (stopped at: $(mg_stopped_at)). ./stack update or ./stack migrate --now resumes it; ./stack migrate --rollback goes back." ;;
    moved) echo "moved to $MG_NEW_PROJECT; the update that started it has not finished (./stack update)." ;;
    rolled-back) echo "rolled back to $MG_OLD_PROJECT. The unused $MG_NEW_PROJECT volumes are still there." ;;
    complete) echo "moved to $MG_NEW_PROJECT on $(date -r "$(mg_get finished)" '+%F %T' 2>/dev/null || date -d "@$(mg_get finished)" '+%F %T' 2>/dev/null)."; migrate_backup_line ;;
  esac
}

# mg_pre_files — the .pre-devos-ade files THIS install made (its own labels, from the marker; its own systemd unit): never another install's
mg_pre_files() {
  local la k f; la="$(mg_launchagents_dir)"
  for k in $(grep '^lc\.' "$(mg_marker)" 2>/dev/null | cut -d= -f1); do
    f="$la/${k#lc.}.plist.pre-devos-ade"; [ ! -f "$f" ] || printf '%s\n' "$f"
  done
  f="$(mg_systemd_dir)/$MG_OLD_UNIT-$MG_PROJ.service.pre-devos-ade"; [ ! -f "$f" ] || printf '%s\n' "$f"
  return 0
}
mg_remove_list() { # the backup's contents, one per line: KIND<TAB>NAME<TAB>KB
  local v f k
  for v in $(mg_old_volumes) "${MG_OLD_PROJECT}_${MG_OLD_DIRNAME}-owner"; do
    docker volume inspect "$v" >/dev/null 2>&1 || continue
    k=0; case "$v" in *-owner) ;; *) k="$(MG_IMG="${MG_IMG:-$(mg_image)}" mg_vol_kb "$v")" ;; esac
    printf 'volume\t%s\t%s\n' "$v" "${k:-0}"
  done
  docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=$MG_OLD_PROJECT/*" 2>/dev/null | while IFS= read -r v; do [ -z "$v" ] || printf 'image\t%s\t0\n' "$v"; done
  [ ! -f "$MG_DIR/.env.pre-devos-ade" ] || printf 'file\t%s\t0\n' "$MG_DIR/.env.pre-devos-ade"
  [ ! -L "$MG_OLD_DIR" ] || [ "$MG_OLD_DIR" = "$MG_NEW_DIR" ] || [ "$(mg_get helper)" = pending ] || printf 'link\t%s\t0\n' "$MG_OLD_DIR"
  while IFS= read -r f; do [ -z "$f" ] || printf 'file\t%s\t0\n' "$f"; done <<EOF
$(mg_pre_files)
EOF
  return 0
}
migrate_remove_old() {
  mg_init
  case "$(mg_status)" in complete) ;; *) die "./stack migrate --remove-old: the move has not finished (./stack migrate says where it is). Nothing was removed." ;; esac
  [ -z "$(mg_get old_removed)" ] || { log "the backup was removed before"; return 0; }
  local list kind name kb tot=0 failed=0
  list="$(mg_remove_list)"
  [ -n "$list" ] || { log "no backup left to remove"; mg_put old_removed "$(date +%s)"; return 0; }
  printf 'This deletes the backup of your install from before the move:\n'
  printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r kind name kb; do printf '  %-7s %s%s\n' "$kind" "$name" "$([ "${kb:-0}" -gt 0 ] && printf '  (%s)' "$(mg_fmt_kb "$kb")")"; done
  while IFS="$(printf '\t')" read -r kind name kb; do tot=$((tot + ${kb:-0})); done <<EOF
$list
EOF
  printf 'In all %s. Your current data lives in the %s_* volumes and is not touched.\n' "$(mg_fmt_kb "$tot")" "$MG_NEW_PROJECT"
  if [ "${ASSUME_YES:-0}" != 1 ]; then confirm "Remove it for good?" || die "aborted — nothing was removed"; fi
  while IFS="$(printf '\t')" read -r kind name kb; do
    case "$kind" in
      volume) mg_guard volume "$name"; docker volume rm "$name" >/dev/null 2>&1 || { warn "could not remove volume $name (it is still there)"; failed=$((failed + 1)); } ;;
      image) mg_guard image "$name"; docker rmi "$name" >/dev/null 2>&1 || { warn "could not remove image tag $name (it is still there)"; failed=$((failed + 1)); } ;;
      file) case "$name" in */.env.pre-devos-ade) rm -f "$name" ;; *) mg_guard launchd "$name" 2>/dev/null || mg_guard systemd "$name"; rm -f "$name" ;; esac ;;
      link) mg_guard dir "$name"; rm -f "$name" ;;
    esac
  done <<EOF
$list
EOF
  if [ "$failed" -gt 0 ]; then warn "$failed item(s) could not be removed and are still there: run ./stack migrate --remove-old again"; return 0; fi
  mg_put old_removed "$(date +%s)"
  log "the backup is removed (about $(mg_fmt_kb "$tot") freed)"
}

# mg_rb_copy_one NEWVOL — the way back for one volume: the CURRENT data of the new volume is copied over the old one and checked as on the way
# forward. The new volume is not touched (it stays as the aside copy). Resumable: a volume the marker calls verified is not copied again.
mg_rb_copy_one() {
  local nv="$1" s ov out a b rc=0
  s="${nv#"${MG_NEW_PROJECT}_"}"; ov="${MG_OLD_PROJECT}_$s"
  mg_guard volume "$nv"; mg_guard volume "$ov"
  [ "$(mg_get "rb.$s")" != verified ] || { log "  $s: copied back and verified before"; return 0; }
  docker volume inspect "$ov" >/dev/null 2>&1 || docker volume create --label "com.docker.compose.project=$MG_OLD_PROJECT" --label "com.docker.compose.volume=$s" "$ov" >/dev/null || die "migration: cannot create $ov. Nothing else was changed."
  if mg_is_socket_vol "$s"; then mg_put "rb.$s" verified; return 0; fi
  log "  $s: copying the current data back"
  MG_MOUNTS="-v $nv:/from:ro -v $ov:/to" MG_SCRIPT="$MG_RBCOPY_SH" mg_run_in "$MG_IMG" mg-copy /from /to || rc=$?
  [ "$rc" = 0 ] || die "migration: copying $s back failed (status $rc). The $MG_NEW_PROJECT volumes are untouched; run ./stack migrate --rollback again."
  out="$(MG_MOUNTS="-v $nv:/from:ro -v $ov:/to:ro" MG_SCRIPT="$MG_SUM_SH" mg_run_in "$MG_IMG" mg-sum /from /to 2>&1)" || die "migration: could not read $s back to check it. The $MG_NEW_PROJECT volumes are untouched; run ./stack migrate --rollback again."
  a="$(printf '%s\n' "$out" | sed -n 1p)"; b="$(printf '%s\n' "$out" | sed -n 2p)"
  [ -n "$a" ] && [ "$a" = "$b" ] || die "migration: the copy of $s back does not match the current data (current: ${a:-none}; copy: ${b:-none}). The $MG_NEW_PROJECT volumes are untouched and hold everything; run ./stack migrate --rollback again."
  mg_put "rb.$s" verified
  log "  $s: verified ($(printf '%s' "$a" | sed 's/ meta=.*//'))"
}

migrate_rollback() {
  mg_init
  case "$(mg_status)" in complete | moved | failed | running) ;; *) die "./stack migrate --rollback: nothing to go back from (./stack migrate says where things are)" ;; esac
  if [ "$MG_PARTIAL" = 1 ]; then log "migration: going back to the old names of this install"
  else log "migration: going back to $MG_OLD_PROJECT (the data written since the move is copied back; the $MG_NEW_PROJECT volumes are kept, unused)"; fi
  local c n f la uid osum nsum ol nl b v h
  uid="$(id -u)"
  if [ "$MG_PARTIAL" != 1 ]; then
    for c in $(docker ps -aq --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" 2>/dev/null); do mg_guard container "$MG_NEW_PROJECT"; docker stop "$c" >/dev/null 2>&1 || true; docker rm "$c" >/dev/null 2>&1 || true; done
    for n in $(docker network ls -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" 2>/dev/null); do docker network rm "$n" >/dev/null 2>&1 || true; done
    MG_IMG="${MG_IMG:-$(mg_image)}"
    for v in $(mg_new_volumes | grep -v -- '-owner$'); do mg_rb_copy_one "$v"; done
  fi
  if [ "$MG_PARTIAL" != 1 ]; then
    # the build ./stack rollback goes back to: <new>/<service>:previous gets its old name again (a tag only: the same image, offline)
    while IFS= read -r f; do
      [ -n "$f" ] || continue; nl="${MG_OLD_PROJECT}/${f#*/}"
      docker image inspect "$nl" >/dev/null 2>&1 || { mg_guard image "$nl"; docker tag "$f" "$nl" >/dev/null 2>&1 || warn "migration: could not name $nl again"; }
    done <<EOF
$(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=$MG_NEW_PROJECT/*" 2>/dev/null | grep ':previous$' || true)
EOF
  fi
  la="$(mg_launchagents_dir)"; osum="$(mg_sum "$MG_OLD_DIR/.state")"; nsum="$(mg_sum "$MG_NEW_DIR/.state")"
  if [ "$(mg_os)" = Darwin ] && [ -d "$la" ]; then
    # only what this migration made: the new plist of each old one kept aside (and the helper's pending one), then the old ones back
    for f in $(mg_pre_files); do
      [ -f "$f" ] || continue; mg_guard launchd "$f"
      ol="${f##*/}"; ol="${ol%.plist.pre-devos-ade}"
      case "$ol" in "$MG_OLD_LABEL"*) nl="$(mg_map_label "$ol")" ;; *) nl="${ol%."$osum"}.$nsum" ;; esac
      launchctl bootout "gui/$uid/$nl" >/dev/null 2>&1 || true; rm -f "${la:?}/${nl:?}.plist"
      mv "$f" "${f%.pre-devos-ade}"; launchctl bootstrap "gui/$uid" "${f%.pre-devos-ade}" >/dev/null 2>&1 || true
    done
    # the old files are gone once the next update removed the leftovers: made again from the new ones
    for f in $(grep '^lc\.' "$(mg_marker)" 2>/dev/null | cut -d= -f1); do
      ol="${f#lc.}"; nl="$(mg_get "$f")"
      if [ ! -f "$la/$ol.plist" ] && [ -f "$la/$nl.plist" ]; then
        mg_guard launchd "$la/$ol.plist"; sed -e "s|<string>$nl</string>|<string>$ol</string>|g" -e "s|/bin/$MG_NEW_UNIT|/bin/$MG_OLD_UNIT|g" "$la/$nl.plist" > "$la/$ol.plist.tmp" &&
          mv "$la/$ol.plist.tmp" "$la/$ol.plist"; mg_rewrite_text "$la/$ol.plist" "$MG_NEW_DIR" "$MG_OLD_DIR"
        launchctl bootout "gui/$uid/$nl" >/dev/null 2>&1 || true; rm -f "${la:?}/${nl:?}.plist"
        launchctl bootstrap "gui/$uid" "$la/$ol.plist" >/dev/null 2>&1 || true
      fi
    done
    nl="$(mg_get helper_new_label)"
    if [ -n "$nl" ] && [ -f "$la/$nl.plist" ]; then mg_guard launchd "$la/$nl.plist"; launchctl bootout "gui/$uid/$nl" >/dev/null 2>&1 || true; rm -f "${la:?}/${nl:?}.plist"; fi
  elif [ "$(mg_os)" = Linux ]; then
    h="$(mg_systemd_dir)"; nl="$(mg_get helper_new_label)"; [ -n "$nl" ] || nl="$MG_NEW_UNIT-$MG_NEWPROJ.service"
    ol="$MG_OLD_UNIT-$MG_PROJ.service"
    if [ -f "$h/$nl" ]; then
      mg_guard systemd "$h/$nl"; systemctl --user disable --now "$nl" >/dev/null 2>&1 || true; rm -f "${h:?}/${nl:?}"
      [ ! -f "$h/$ol.pre-devos-ade" ] || { mg_guard systemd "$h/$ol"; mv "$h/$ol.pre-devos-ade" "$h/$ol"; }
      systemctl --user daemon-reload >/dev/null 2>&1 || true; systemctl --user enable --now "$ol" >/dev/null 2>&1 || true
    fi
  fi
  if [ "$MG_MV" = 1 ] && [ "$MG_NEW_DIR" != "$MG_OLD_DIR" ] && [ -d "$MG_NEW_DIR" ]; then
    mg_rewrite_tree "$MG_NEW_DIR" "$MG_NEW_DIR" "$MG_OLD_DIR"; mg_relink_tree "$MG_NEW_DIR" "$MG_NEW_DIR" "$MG_OLD_DIR"
    for b in devos-claude claude-bedrock; do
      [ "$(readlink "$HOME/.local/bin/$b" 2>/dev/null)" = "$MG_NEW_DIR/bin/$b" ] && { mg_guard bin "$HOME/.local/bin/$b"; ln -sfn "$MG_OLD_DIR/bin/$b" "$HOME/.local/bin/$b"; }
    done
    [ ! -L "$MG_OLD_DIR" ] || rm -f "${MG_OLD_DIR:?}"
    mg_guard dir "$MG_NEW_DIR"; mv "$MG_NEW_DIR" "$MG_OLD_DIR" || die "migration: could not move $MG_NEW_DIR back to $MG_OLD_DIR"
    rm -f "${MG_OLD_DIR:?}/bin/$MG_OLD_UNIT" 2>/dev/null || true
    MG_DIR="$MG_OLD_DIR"; STACK_DIR="$MG_OLD_DIR"; ENV_FILE="$MG_OLD_DIR/.env"; STATE_DIR="$MG_OLD_DIR/.state"
  fi
  # .env: reversed from the CURRENT file (what was changed since the move stays); the one from before the move is kept as it was
  cp -p "$ENV_FILE" "$MG_DIR/.env.devos-ade-rolled-back" 2>/dev/null || true
  if [ "$MG_PARTIAL" = 1 ]; then mg_env_xlate "$MG_NEW_ENV_PREFIX" "$MG_OLD_ENV_PREFIX" 0 x x x x 1
  else
    h=0; [ "$(get_env PORTAL_HOST)" != "$MG_NEW_HOST" ] || h=1
    v=0; [ "$(get_env PREVIEW_DOMAIN)" != "$MG_NEW_PREVIEW" ] || v=1
    mg_env_xlate "$MG_NEW_ENV_PREFIX" "$MG_OLD_ENV_PREFIX" "$h" "$MG_NEW_HOST" "$MG_OLD_HOST" "$MG_NEW_PREVIEW" "$MG_OLD_PREVIEW" 1 "$v"
    set_env COMPOSE_PROJECT_NAME "$MG_OLD_PROJECT"   # the checked-out code would otherwise start the new name; ./stack rollback goes back to the old code
  fi
  # names inside the volume of terminal-home and on this computer, back
  v="${MG_PROJ}_terminal-home"
  if docker volume inspect "$v" >/dev/null 2>&1; then
    mg_guard volume "$v"
    MG_MOUNTS="-v $v:/h" MG_SCRIPT="$MG_RENAME_SH" mg_run_in "${MG_IMG:-$(mg_image)}" mg-rename /h "$MG_NEW_CONF" "$MG_OLD_CONF" "$MG_NEW_TRASH" "$MG_OLD_TRASH" "$MG_NEW_TMP" "$MG_OLD_TMP" "$MG_NEW_HINT" "$MG_OLD_HINT" >/dev/null 2>&1 || warn "migration: could not rename the sandbox's folders back in $v"
  fi
  mg_host_rename back
  mv "$(mg_marker)" "$(mg_marker).rolled-back-$(date +%s)" 2>/dev/null || true   # a new try starts from the beginning
  mg_put status rolled-back
  if [ "$MG_PARTIAL" = 1 ]; then log "back to the old names in $MG_DIR (.env reversed from the current one; the one from before is .env.pre-devos-ade). Next: ./stack rollback goes back to the earlier code."
  else log "back to $MG_OLD_PROJECT in $MG_DIR, with the data written since the move (.env reversed from the current one; the one from before the move is .env.pre-devos-ade). The $MG_NEW_PROJECT volumes are left as they were ($(mg_new_volumes | tr '\n' ' ')). Next: ./stack rollback goes back to the earlier code."; fi
}

# migrate_rollback_first — ./stack rollback of the code, when the install was moved to the new name: the old code knows only the old names, so
# the move is undone first (migrate_rollback), then ./stack rollback starts again from the old folder. Refuses with the exact command otherwise.
migrate_rollback_first() {
  local old
  mg_init
  case "$(mg_status)" in complete | moved) ;; failed | running) mg_done_p env || return 0 ;; *) return 0 ;; esac
  log "rollback: this install was moved to the new name; undoing that first (./stack migrate --rollback)"
  old="$MG_OLD_DIR"   # (the folder this install goes back to; the one we may be standing in is gone afterwards)
  ( migrate_rollback ) || die "./stack rollback: the move to the new name could not be undone (see above). Nothing of the code was changed. Fix that, then run: ./stack migrate --rollback   and after it: ./stack rollback"
  cd "$old" && ASSUME_YES=1 exec "$old/stack" rollback   # (confirmed already: it asks once)
}

cmd_migrate() {
  case "${1:-}" in
    '') migrate_status ;;
    --now) mg_init; mg_needed || { migrate_status; return 0; }; stack_lock migrate; mg_phase_a
      log "moved. The rest of the update: cd $MG_NEW_DIR && ./stack update --force" ;;
    --rollback) stack_lock migrate; migrate_rollback ;;
    --verify) stack_lock migrate; mg_init; case "$(mg_status)" in complete) mg_verify_and_clean; migrate_backup_line ;; *) die "./stack migrate --verify: the move has not finished (./stack migrate says where it is)" ;; esac ;;
    --remove-old) migrate_remove_old ;;
    --finish-helper) migrate_finish_helper ;;
    -h | --help) migrate_usage ;;
    *) die "$(migrate_usage)" ;;
  esac
}
