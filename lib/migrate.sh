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
#              name until the copy is verified, so a failure leaves "./stack up" starting the OLD project with its data
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
MG_ALLOWED_KINDS="dir volume image network container launchd systemd bin config"
MG_FORBIDDEN_NOTE="never: devos-heavy, Companion, Mobile, xirp, other Docker projects"

# mg_allowed KIND VALUE -> 0 when this migration may change VALUE
mg_allowed() {
  local kind="$1" v="$2" b
  case "$kind" in
    dir) [ "$v" = "$MG_OLD_DIR" ] || [ "$v" = "$MG_NEW_DIR" ] || [ "$v" = "${MG_OLD_DIR%/*}/$MG_OLD_DIRNAME" ]; return ;;
    volume) case "$v" in "$MG_OLD_PROJECT"_* | "$MG_NEW_PROJECT"_*) return 0 ;; esac; return 1 ;;
    image) case "$v" in "$MG_OLD_PROJECT"/* | "$MG_NEW_PROJECT"/*) return 0 ;; esac; return 1 ;;
    network | container) case "$v" in "$MG_OLD_PROJECT" | "$MG_NEW_PROJECT") return 0 ;; esac; return 1 ;;
    launchd) b="${v##*/}"; b="${b%.plist}"; b="${b%.pre-devos-ade}"
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
  MG_OLD_DIR="$(cd "$STACK_DIR" && pwd -P)"
  MG_LOGICAL_DIR="$(cd "$STACK_DIR" && pwd)"
  if [ "${MG_OLD_DIR##*/}" = "$MG_OLD_DIRNAME" ]; then MG_NEW_DIR="${MG_OLD_DIR%/*}/$MG_NEW_DIRNAME"; MG_MV=1
  elif [ "${MG_OLD_DIR##*/}" = "$MG_NEW_DIRNAME" ] && [ -f "$(mg_marker_file_at "$MG_OLD_DIR")" ]; then
    # already moved (this process started from the new folder): the old folder is where the symlink was
    MG_NEW_DIR="$MG_OLD_DIR"; MG_OLD_DIR="${MG_OLD_DIR%/*}/$MG_OLD_DIRNAME"; MG_MV=1
  else MG_NEW_DIR="$MG_OLD_DIR"; MG_MV=0; fi
  MG_DIR="$MG_OLD_DIR"; [ -d "$MG_OLD_DIR" ] && [ ! -L "$MG_OLD_DIR" ] || MG_DIR="$MG_NEW_DIR"
  [ -f "$MG_DIR/.env" ] || MG_DIR="$(cd "$STACK_DIR" && pwd -P)"
}
mg_marker_file_at() { printf '%s/.state/migrate/marker\n' "$1"; }
mg_marker() { [ -n "${MG_DIR:-}" ] || mg_init; mg_marker_file_at "$MG_DIR"; }
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
mg_old_volumes() { docker volume ls -q 2>/dev/null | awk -v p="${MG_OLD_PROJECT}_" 'index($0, p) == 1' | grep -v -- '-owner$' || true; }
mg_new_volumes() { docker volume ls -q 2>/dev/null | awk -v p="${MG_NEW_PROJECT}_" 'index($0, p) == 1' || true; }
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
  local img="$1"; shift
  # shellcheck disable=SC2086  # MG_MOUNTS: -v options, one word each
  docker run --rm --user 0 --network none --entrypoint sh $MG_MOUNTS "$img" -c "$MG_SCRIPT" "$@"   # ($0 is the op name)
}
MG_SUM_SH='for d in "$1" "$2"; do cd "$d" || exit 1
n=$(find . -mindepth 1 | wc -l | tr -d " ")
b=$(find . -type f -exec stat -c %s {} + | awk "{s+=\$1} END{print s+0}")
m=$(find . -mindepth 1 -printf "%p %m %U %G %y\n" | LC_ALL=C sort | sha256sum | cut -d" " -f1)
c=$(find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2 | sha256sum | cut -d" " -f1)
printf "count=%s bytes=%s meta=%s sum=%s\n" "$n" "$b" "$m" "$c"; done'
MG_COPY_SH='cp -a "$1"/. "$2"/'
MG_DU_SH='du -sk "$1" | cut -f1'
MG_DF_SH='df -Pk "$1" | awk "NR==2{print \$4}"'
MG_RENAME_SH='cd "$1" || exit 0
ren() { if [ -e "$1" ] && [ ! -e "$2" ]; then mv "$1" "$2"; fi; }
ren ".config/$2" ".config/$3"; for d in . .claude .config; do ren "$d/$4" "$d/$5"; ren "$d/$6" "$d/$7"; done'

mg_vol_kb() { MG_MOUNTS="-v $1:/v:ro" MG_SCRIPT="$MG_DU_SH" mg_run_in "${MG_IMG:-$(mg_image)}" mg-du /v 2>/dev/null | tail -n 1; }
mg_total_kb() {
  local v t=0 k
  for v in $(mg_old_volumes); do k="$(mg_vol_kb "$v")"; case "$k" in '' | *[!0-9]*) k=0 ;; esac; t=$((t + k)); done
  printf '%s\n' "$t"
}
mg_eta() { local s=$(($1 * 1024 / MG_IMAGE_CPS + 20)); if [ "$s" -ge 90 ]; then printf 'about %s minutes' $(((s + 59) / 60)); else printf 'under 2 minutes'; fi; }
mg_fmt_kb() { fmt_bytes $(($1 * 1024)); }

# --- the steps ---
mg_fail() { # mg_fail STEP MESSAGE — the marker says where it stopped; the old project stays runnable
  mg_put status failed; mg_put failed_step "$1"
  die "migration to $MG_NEW_PROJECT failed at '$1': $2 — your data is untouched (the old volumes were only read). Run ./stack update (or ./stack migrate --now) to resume, or ./stack migrate --rollback to go back. Until then ./stack up starts the old project ($MG_OLD_PROJECT) as before."
}

mg_step_preflight() {
  local v k need free ws
  [ -n "$(mg_old_volumes)" ] || mg_fail preflight "no volumes of project $MG_OLD_PROJECT"
  if [ -n "$(mg_new_volumes)" ]; then
    mg_fail preflight "project $MG_NEW_PROJECT already has volumes ($(mg_new_volumes | tr '\n' ' ')), made by an earlier try or another install. Look at them; remove them yourself (docker volume rm …) if they are not wanted. Nothing was changed."
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
mg_dev() { stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null; }

mg_step_stop() {
  local c n cur
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

mg_progress() { # mg_progress PID NEWVOL TOTAL_KB — a line of progress every few seconds while the copy runs
  local pid="$1" nv="$2" tot="$3" k pct
  while kill -0 "$pid" 2>/dev/null; do
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
    case "$st" in copying | failed) docker volume rm "$nv" >/dev/null 2>&1 || mg_fail copy "cannot remove the partial $nv" ;;
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
  mg_put "vol.$s" verified
  log "  $s: verified ($(printf '%s' "$a" | sed 's/ meta=.*//'))"
}
mg_step_copy() { local v; for v in $(mg_old_volumes); do mg_copy_one "$v"; done; mg_step_done copy; }

mg_step_inner() { # names inside the NEW terminal-home (never on this computer)
  local nv="${MG_NEW_PROJECT}_terminal-home"
  docker volume inspect "$nv" >/dev/null 2>&1 || { mg_step_done inner; return 0; }
  mg_allowed config ".config/$MG_NEW_CONF" || die "migration: internal list error"
  MG_MOUNTS="-v $nv:/h" MG_SCRIPT="$MG_RENAME_SH" mg_run_in "${MG_IMG:-$(mg_image)}" mg-rename /h "$MG_OLD_CONF" "$MG_NEW_CONF" "$MG_OLD_TRASH" "$MG_NEW_TRASH" "$MG_OLD_TMP" "$MG_NEW_TMP" >/dev/null 2>&1 || mg_fail inner "could not rename the sandbox's own folders in $nv"
  # the workspace's and projects' trash folders (bind mounts of this computer: a rename inside folders that are the sandbox's own)
  mg_step_done inner
}

# mg_env_rewrite — .env: keys, host, project, pins. The backup is made once (the first one stands).
mg_step_env() {
  local bak="$MG_DIR/.env.pre-devos-ade" tmp ph oldp k v
  [ -f "$ENV_FILE" ] || mg_fail env "no .env"
  if [ ! -f "$bak" ]; then cp -p "$ENV_FILE" "$bak" && chmod 600 "$bak" || mg_fail env "cannot back .env up"; fi   # (made at preflight; here only if that was skipped)
  ph="$(get_env PORTAL_HOST)"; oldp=0
  { [ -z "$ph" ] || [ "$ph" = "$MG_OLD_HOST" ]; } && oldp=1
  tmp="$(mktemp "$ENV_FILE.XXXXXX")" || mg_fail env "cannot write .env"
  OP="$MG_OLD_ENV_PREFIX" NP="$MG_NEW_ENV_PREFIX" OLDP="$oldp" OH="$MG_OLD_HOST" NH="$MG_NEW_HOST" OV="$MG_OLD_PREVIEW" NV="$MG_NEW_PREVIEW" awk '
    BEGIN { op = ENVIRON["OP"]; np = ENVIRON["NP"] }
    { lines[NR] = $0; i = index($0, "="); if (i > 0) have[substr($0, 1, i - 1)] = 1 }
    END {
      for (n = 1; n <= NR; n++) {
        l = lines[n]; i = index(l, "="); k = (i > 0) ? substr(l, 1, i - 1) : ""; v = (i > 0) ? substr(l, i + 1) : l
        if (k != "" && index(k, op) == 1) { nk = np substr(k, length(op) + 1); if (nk in have) continue; k = nk }
        if (ENVIRON["OLDP"] == "1" && k != "") {
          while ((p = index(v, ENVIRON["OV"])) > 0) v = substr(v, 1, p - 1) ENVIRON["NV"] substr(v, p + length(ENVIRON["OV"]))
          while ((p = index(v, ENVIRON["OH"])) > 0) v = substr(v, 1, p - 1) ENVIRON["NH"] substr(v, p + length(ENVIRON["OH"]))
        }
        if (k != "") print k "=" v; else print l
      }
    }' "$ENV_FILE" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$ENV_FILE" || { rm -f "$tmp"; mg_fail env "cannot rewrite .env"; }
  # The pin made at 'stop' goes now: the copy is verified. An explicit old project name becomes the new one.
  if [ "$(mg_get pinned)" = 1 ]; then unset_env COMPOSE_PROJECT_NAME
  elif [ "$(get_env COMPOSE_PROJECT_NAME)" = "$MG_OLD_PROJECT" ]; then set_env COMPOSE_PROJECT_NAME "$MG_NEW_PROJECT"; fi
  # The email every store is keyed by: setup wrote it to .env at the first setup (OPENWEBUI_ADMIN_EMAIL), and Open WebUI, LiteLLM and the
  # git server read it from there, so nothing in them changes. A .env without it is pinned to the old default.
  if [ -z "$(get_env OPENWEBUI_ADMIN_EMAIL)" ]; then set_env OPENWEBUI_ADMIN_EMAIL "$MG_OLD_EMAIL"; mg_put email_pinned "$MG_OLD_EMAIL"; fi
  # Tailscale: the Service names, the node and the tag are tailnet-side names (policy, approvals): not renamed here
  if [ "$(get_env REMOTE_MODE)" = tailscale ]; then
    [ -n "$(get_env TS_SERVICE)" ] || { set_env TS_SERVICE "$MG_OLD_TS"; mg_put ts_pinned 1; }
    [ -n "$(get_env TS_HOSTNAME)" ] || set_env TS_HOSTNAME "$MG_OLD_TS-node"
    [ -n "$(get_env TS_TAG)" ] || set_env TS_TAG "tag:$MG_OLD_TS"
  fi
  mg_put host_moved "$oldp"
  mg_step_done env
}

mg_step_images() {
  local r t
  while IFS= read -r r; do
    [ -n "$r" ] || continue; mg_guard image "$r"
    t="${MG_NEW_PROJECT}/${r#*/}"; docker image inspect "$t" >/dev/null 2>&1 || docker tag "$r" "$t" >/dev/null 2>&1 || true
  done <<EOF
$(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=$MG_OLD_PROJECT/*" 2>/dev/null)
EOF
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
mg_step_paths() {
  local o="$MG_OLD_DIR" n="$MG_NEW_DIR" b
  if [ "$o" != "$n" ]; then
    mg_rewrite_tree "$n" "$o" "$n"
    [ "$MG_LOGICAL_DIR" = "$o" ] || mg_rewrite_tree "$n" "$MG_LOGICAL_DIR" "$n"
    mg_relink_tree "$n" "$o" "$n"
    [ "$MG_LOGICAL_DIR" = "$o" ] || mg_relink_tree "$n" "$MG_LOGICAL_DIR" "$n"
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
mg_step_launchd() {
  local la f base ol nl nf uid osum nsum helperp=0 t
  la="$(mg_launchagents_dir)"; uid="$(id -u)"
  osum="$(mg_sum "$MG_OLD_DIR/.state")"; nsum="$(mg_sum "$MG_NEW_DIR/.state")"
  if [ "$(mg_os)" = Darwin ] && [ -d "$la" ]; then
    for f in "$la"/${MG_OLD_LABEL}*.plist "$la"/dev.devos.ade.*."$osum".plist; do
      [ -f "$f" ] || continue
      mg_guard launchd "$f"
      base="${f##*/}"; ol="${base%.plist}"
      case "$ol" in "$MG_OLD_LABEL"*) nl="${MG_NEW_LABEL}${ol#"$MG_OLD_LABEL"}"; nl="${nl%."$MG_OLD_PROJECT"}.${MG_NEW_PROJECT}" ;; *) nl="${ol%."$osum"}.$nsum" ;; esac
      case "$ol" in "$MG_OLD_LABEL"helper.*) helperp=1 ;; *) helperp=0 ;; esac
      nf="$la/$nl.plist"; mg_guard launchd "$nf"
      if [ ! -f "$nf" ]; then
        t="$(mg_new_plist_text "$f" "$ol" "$nl" "$osum" "$nsum")" || mg_fail launchd "cannot read $f"
        printf '%s\n' "$t" > "$nf.tmp" && chmod 644 "$nf.tmp" && mv "$nf.tmp" "$nf" || mg_fail launchd "cannot write $nf"
      fi
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
[ -f "\$h" ] && exec /bin/bash "\$h" "\$D" "\$@"
exit 0
EOF
  chmod 755 "$s"
  # not a tracked file: git must not see it (the update's clean-tree check ignores untracked files anyway)
  [ ! -d "$MG_NEW_DIR/.git/info" ] || grep -qxF "/bin/$MG_OLD_UNIT" "$MG_NEW_DIR/.git/info/exclude" 2>/dev/null || printf '/bin/%s\n' "$MG_OLD_UNIT" >> "$MG_NEW_DIR/.git/info/exclude"
}
mg_systemd_helper() {
  local d f nf ol nl
  d="$(mg_systemd_dir)"; [ -d "$d" ] || return 0
  for f in "$d/$MG_OLD_UNIT"-*.service; do
    [ -f "$f" ] || continue
    mg_guard systemd "$f"
    ol="${f##*/}"; nl="$MG_NEW_UNIT-${MG_NEW_PROJECT}.service"; nf="$d/$nl"; mg_guard systemd "$nf"
    if [ ! -f "$nf" ]; then
      mg_new_plist_text "$f" x x 0 0 | sed "s|$MG_OLD_UNIT-$MG_OLD_PROJECT|$MG_NEW_UNIT-$MG_NEW_PROJECT|g" > "$nf.tmp" && chmod 644 "$nf.tmp" && mv "$nf.tmp" "$nf"
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
mg_needed() {
  local st cur own; st="$(mg_status)"
  case "$st" in complete | moved) return 1 ;; running | failed) return 0 ;; esac
  cur="$(get_env COMPOSE_PROJECT_NAME)"; { [ -z "$cur" ] || [ "$cur" = "$MG_OLD_PROJECT" ]; } || return 1
  docker info >/dev/null 2>&1 || return 1
  [ -n "$(mg_old_volumes)" ] || return 1
  # Only the checkout that owns the old project moves it (another folder's install of the old name is not this one's)
  own="$(docker volume inspect --format "{{index .Labels \"$MG_OLD_OWNER_LABEL\"}}" "${MG_OLD_PROJECT}_${MG_OLD_DIRNAME}-owner" 2>/dev/null || true)"
  [ -z "$own" ] || [ "$own" = "<no value>" ] || [ "$(cd "$own" 2>/dev/null && pwd -P || printf '%s' "$own")" = "$MG_OLD_DIR" ] || return 1
}
mg_phase_a() {
  [ -n "$(mg_get started)" ] || mg_put started "$(date +%s)"
  mg_put status running; mg_put from_dir "$MG_OLD_DIR"; mg_put to_dir "$MG_NEW_DIR"
  local s
  docker info >/dev/null 2>&1 || mg_fail preflight "Docker is not running"
  MG_IMG="$(mg_image)" || mg_fail preflight "no image to copy with"
  for s in preflight stop copy inner env images move paths launchd; do
    mg_done_p "$s" || "mg_step_$s"
  done
  mg_put status moved
}

# migrate_update_hook — in ./stack update, with the new code checked out, before images and setup
migrate_update_hook() {
  mg_init
  mg_needed || return 0
  log "update: moving this install from the name $MG_OLD_PROJECT to $MG_NEW_PROJECT (your data is copied, the old copy is kept)"
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
  bad="$(docker ps -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" --filter health=unhealthy 2>/dev/null || true)"
  [ -z "$bad" ] || warn "migration: a container of $MG_NEW_PROJECT is unhealthy (./stack status); the old copy of your data is kept (./stack migrate --rollback goes back)"
  [ -n "$(docker ps -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" 2>/dev/null || true)" ] || { warn "migration: nothing of $MG_NEW_PROJECT runs yet — ./stack up; the migration is finished when it does (./stack migrate)"; return 0; }
  mg_put status complete; mg_put finished "$(date +%s)"
  log "DevOS ADE now lives at http://$(portal_host) (the old address forwards there). Sign in again once there, and install the app again from the new address."
  migrate_backup_line | sed 's/^/    /' >&2
  return 0
}

# migrate_backup_line — what is kept from before the move, for ./stack status, the update's end and Home
migrate_backup_line() {
  mg_init
  case "$(mg_status)" in complete | moved) ;; *) return 0 ;; esac
  [ -z "$(mg_get old_removed)" ] || return 0
  printf 'Backup of the install before the move to %s: the %s_* volumes (%s), .env.pre-devos-ade, the old folder link and images. Remove it when you are sure: ./stack migrate --remove-old\n' \
    "$MG_NEW_PROJECT" "$MG_OLD_PROJECT" "$(mg_fmt_kb "$(mg_get kb_total)")"
}

# --- ./stack migrate ---
migrate_usage() {
  cat <<EOF
usage: ./stack migrate [--now | --rollback | --remove-old [--yes] | --finish-helper]
  (none)         the state of the move from $MG_OLD_PROJECT to $MG_NEW_PROJECT, and what is kept as the backup
  --now          run (or resume) the move by hand; ./stack update does this by itself
  --rollback     go back to $MG_OLD_PROJECT: its folder, .env, launchd names and volumes (the new volumes stay, unused)
  --remove-old   delete the backup: the old volumes, .env.pre-devos-ade, the old folder link, images (lists and asks)
EOF
}
migrate_status() {
  mg_init
  case "$(mg_status)" in
    '') if mg_needed; then echo "not moved yet: this install is still the project $MG_OLD_PROJECT. ./stack update moves it ($(mg_eta "$(mg_total_kb 2>/dev/null || echo 0)"))."; else echo "nothing to move: this install is not under the old name $MG_OLD_PROJECT."; fi ;;
    running | failed) echo "the move is not finished (stopped at: $(mg_get failed_step)). ./stack update or ./stack migrate --now resumes it; ./stack migrate --rollback goes back." ;;
    moved) echo "moved to $MG_NEW_PROJECT; the update that started it has not finished (./stack update)." ;;
    rolled-back) echo "rolled back to $MG_OLD_PROJECT. The unused $MG_NEW_PROJECT volumes are still there." ;;
    complete) echo "moved to $MG_NEW_PROJECT on $(date -r "$(mg_get finished)" '+%F %T' 2>/dev/null || date -d "@$(mg_get finished)" '+%F %T' 2>/dev/null)."; migrate_backup_line ;;
  esac
}

mg_remove_list() { # the backup's contents, one per line: KIND<TAB>NAME<TAB>KB
  local v la f k
  for v in $(mg_old_volumes) "${MG_OLD_PROJECT}_${MG_OLD_DIRNAME}-owner"; do
    docker volume inspect "$v" >/dev/null 2>&1 || continue
    k=0; case "$v" in *-owner) ;; *) k="$(MG_IMG="${MG_IMG:-$(mg_image)}" mg_vol_kb "$v")" ;; esac
    printf 'volume\t%s\t%s\n' "$v" "${k:-0}"
  done
  docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=$MG_OLD_PROJECT/*" 2>/dev/null | while IFS= read -r v; do [ -z "$v" ] || printf 'image\t%s\t0\n' "$v"; done
  [ ! -f "$MG_DIR/.env.pre-devos-ade" ] || printf 'file\t%s\t0\n' "$MG_DIR/.env.pre-devos-ade"
  [ ! -L "$MG_OLD_DIR" ] || [ "$MG_OLD_DIR" = "$MG_NEW_DIR" ] || printf 'link\t%s\t0\n' "$MG_OLD_DIR"
  la="$(mg_launchagents_dir)"
  for f in "$la"/*.pre-devos-ade "$(mg_systemd_dir)"/*.pre-devos-ade; do [ -f "$f" ] && printf 'file\t%s\t0\n' "$f"; done
  return 0
}
migrate_remove_old() {
  mg_init
  case "$(mg_status)" in complete) ;; *) die "./stack migrate --remove-old: the move has not finished (./stack migrate says where it is). Nothing was removed." ;; esac
  [ -z "$(mg_get old_removed)" ] || { log "the backup was removed before"; return 0; }
  local list kind name kb tot=0
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
      volume) mg_guard volume "$name"; docker volume rm "$name" >/dev/null 2>&1 || warn "could not remove volume $name" ;;
      image) mg_guard image "$name"; docker rmi "$name" >/dev/null 2>&1 || true ;;
      file) case "$name" in */.env.pre-devos-ade) rm -f "$name" ;; *) mg_guard launchd "$name" 2>/dev/null || mg_guard systemd "$name"; rm -f "$name" ;; esac ;;
      link) mg_guard dir "$name"; rm -f "$name" ;;
    esac
  done <<EOF
$list
EOF
  mg_put old_removed "$(date +%s)"
  log "the backup is removed (about $(mg_fmt_kb "$tot") freed)"
}

migrate_rollback() {
  mg_init
  case "$(mg_status)" in complete | moved | failed | running) ;; *) die "./stack migrate --rollback: nothing to go back from (./stack migrate says where things are)" ;; esac
  [ -z "$(mg_get old_removed)" ] || die "./stack migrate --rollback: the backup was removed (--remove-old); there is nothing to go back to"
  log "migration: going back to $MG_OLD_PROJECT (the $MG_NEW_PROJECT volumes are kept, unused)"
  local c n f la uid osum nsum ol nl b
  uid="$(id -u)"
  for c in $(docker ps -aq --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" 2>/dev/null); do mg_guard container "$MG_NEW_PROJECT"; docker stop "$c" >/dev/null 2>&1 || true; docker rm "$c" >/dev/null 2>&1 || true; done
  for n in $(docker network ls -q --filter "label=com.docker.compose.project=$MG_NEW_PROJECT" 2>/dev/null); do docker network rm "$n" >/dev/null 2>&1 || true; done
  la="$(mg_launchagents_dir)"; osum="$(mg_sum "$MG_OLD_DIR/.state")"; nsum="$(mg_sum "$MG_NEW_DIR/.state")"
  if [ "$(mg_os)" = Darwin ]; then
    for f in "$la"/${MG_NEW_LABEL}*.plist "$la"/dev.devos.ade.*."$nsum".plist; do
      [ -f "$f" ] || continue; mg_guard launchd "$f"
      nl="${f##*/}"; nl="${nl%.plist}"; launchctl bootout "gui/$uid/$nl" >/dev/null 2>&1 || true; rm -f "$f"
    done
    for f in "$la"/*.pre-devos-ade; do
      [ -f "$f" ] || continue; mg_guard launchd "$f"; mv "$f" "${f%.pre-devos-ade}"
      launchctl bootstrap "gui/$uid" "${f%.pre-devos-ade}" >/dev/null 2>&1 || true
    done
  fi
  if [ "$MG_MV" = 1 ] && [ "$MG_NEW_DIR" != "$MG_OLD_DIR" ] && [ -d "$MG_NEW_DIR" ]; then
    mg_rewrite_tree "$MG_NEW_DIR" "$MG_NEW_DIR" "$MG_OLD_DIR"; mg_relink_tree "$MG_NEW_DIR" "$MG_NEW_DIR" "$MG_OLD_DIR"
    for b in devos-claude claude-bedrock; do
      [ "$(readlink "$HOME/.local/bin/$b" 2>/dev/null)" = "$MG_NEW_DIR/bin/$b" ] && { mg_guard bin "$HOME/.local/bin/$b"; ln -sfn "$MG_OLD_DIR/bin/$b" "$HOME/.local/bin/$b"; }
    done
    [ ! -L "$MG_OLD_DIR" ] || rm -f "$MG_OLD_DIR"
    mg_guard dir "$MG_NEW_DIR"; mv "$MG_NEW_DIR" "$MG_OLD_DIR" || die "migration: could not move $MG_NEW_DIR back to $MG_OLD_DIR"
    rm -f "$MG_OLD_DIR/bin/$MG_OLD_UNIT" 2>/dev/null || true
    MG_DIR="$MG_OLD_DIR"; STACK_DIR="$MG_OLD_DIR"; ENV_FILE="$MG_OLD_DIR/.env"; STATE_DIR="$MG_OLD_DIR/.state"
  fi
  if [ -f "$MG_DIR/.env.pre-devos-ade" ]; then
    cp -p "$ENV_FILE" "$MG_DIR/.env.devos-ade-rolled-back" 2>/dev/null || true
    cp -p "$MG_DIR/.env.pre-devos-ade" "$ENV_FILE"
  fi
  set_env COMPOSE_PROJECT_NAME "$MG_OLD_PROJECT"   # the checked-out code would otherwise start the new name; ./stack rollback goes back to the old code
  mv "$(mg_marker)" "$(mg_marker).rolled-back-$(date +%s)" 2>/dev/null || true   # a new try starts from the beginning
  mg_put status rolled-back
  log "back to $MG_OLD_PROJECT in $MG_DIR (.env restored; the one from before is .env.devos-ade-rolled-back). Unused volumes of $MG_NEW_PROJECT: $(mg_new_volumes | tr '\n' ' ')— kept; docker volume rm them yourself if you want. Next: ./stack rollback goes back to the earlier code."
}

cmd_migrate() {
  case "${1:-}" in
    '') migrate_status ;;
    --now) mg_init; mg_needed || { migrate_status; return 0; }; stack_lock migrate; mg_phase_a
      log "moved. The rest of the update: cd $MG_NEW_DIR && ./stack update --force" ;;
    --rollback) stack_lock migrate; migrate_rollback ;;
    --remove-old) migrate_remove_old ;;
    --finish-helper) migrate_finish_helper ;;
    -h | --help) migrate_usage ;;
    *) die "$(migrate_usage)" ;;
  esac
}
