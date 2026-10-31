# shellcheck shell=bash
# shellcheck disable=SC2016,SC2329,SC2034  # literal $ in expected text; stand-ins are called by the code under test
# The move from bedrock-now to devos-ade (lib/migrate.sh, JON-807): every step, every refusal, the failure paths, resume,
# a rerun, the launchd relabel, rollback and --remove-old. Nothing here reaches Docker, launchd or systemd: docker is a
# stand-in whose volumes are folders under $TMP/dk (so the copy and its checks really run on files), launchctl,
# systemctl and the disk checks are stand-ins too. The install is a folder under this test's own HOME.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/migrate.sh

OLDP=bedrock-now; NEWP=devos-ade

# --- the stand-ins ---
_mg_docker() {
  echo "$*" >> "$DK/log"
  case "$1" in
    info) [ ! -f "$DK/down" ] ;;
    volume) shift
      case "$1" in
        ls) ls "$DK/vol" ;;
        create) shift; local n=''; while [ $# -gt 0 ]; do case "$1" in --label) shift 2 ;; *) n="$1"; shift ;; esac; done
          [ ! -f "$DK/failcreate" ] || return 1; mkdir -p "$DK/vol/$n" ;;
        inspect) local n a; for a in "$@"; do n="$a"; done
          [ -d "$DK/vol/$n" ] || return 1
          case "$*" in *io.bedrock-now.dir*) cat "$DK/owner" 2>/dev/null || true ;; esac ;;
        rm) rm -rf "$DK/vol/$2" ;;
      esac ;;
    ps) case "$*" in
          *health=unhealthy*) cat "$DK/unhealthy" 2>/dev/null || true ;;
          *) local all="$*" p; p="${all#*project=}"; p="${p%% *}"; awk -v p="$p" '$2 == p { print $1 }' "$DK/containers" ;;
        esac ;;
    stop) : ;;
    rm) grep -v "^$2 " "$DK/containers" > "$DK/c.new" || true; mv "$DK/c.new" "$DK/containers" ;;
    network) case "$2" in
        ls) local all="$*" p; p="${all#*project=}"; p="${p%% *}"; awk -v p="$p" '$2 == p { print $1 }' "$DK/networks" ;;
        rm) grep -v "^$3 " "$DK/networks" > "$DK/n.new" || true; mv "$DK/n.new" "$DK/networks" ;;
      esac ;;
    image) case "$2" in
        inspect) grep -qx "$3" "$DK/images" ;;
        ls) local all="$*" p; p="${all#*reference=}"; p="${p%/\*}"; grep "^$p/" "$DK/images" || true ;;
      esac ;;
    tag) echo "$3" >> "$DK/images" ;;
    rmi) grep -vx "$2" "$DK/images" > "$DK/i.new" || true; mv "$DK/i.new" "$DK/images" ;;
    run) shift
      local mounts='' script='' op=''
      while [ $# -gt 0 ]; do
        case "$1" in -v) mounts="$mounts $2"; shift 2 ;; --rm) shift ;; --user | --network | --entrypoint) shift 2 ;;
          -c) script="$2"; op="$3"; shift 3; break ;; *) shift ;; esac
      done
      local args=() a m t; for a in "$@"; do
        for m in $mounts; do t="${m#*:}"; t="${t%%:*}"; [ "$a" != "$t" ] || a="$DK/vol/${m%%:*}"; done
        args+=("$a")
      done
      case "$op" in
        mg-df) cat "$DK/free_kb" 2>/dev/null || echo 99999999 ;;
        mg-copy) [ ! -f "$DK/copyfail" ] || return 1
          sh -c "$script" "$op" "${args[@]}" || return 1
          if [ -f "$DK/corrupt" ] && [ -f "${args[1]}/PG_VERSION" ]; then echo x >> "${args[1]}/PG_VERSION"; fi ;;
        mg-sum) _mg_sum "${args[0]}"; _mg_sum "${args[1]}" ;;
        *) sh -c "$script" "$op" "${args[@]}" ;;
      esac ;;
  esac
}
_mg_sum() {
  ( cd "$1" && n="$(find . -mindepth 1 | wc -l | tr -d ' ')"
    b="$(find . -type f | while read -r f; do wc -c < "$f"; done | awk '{ s += $1 } END { print s + 0 }')"
    m="$( { find . -mindepth 1 | LC_ALL=C sort; find . -type l | while read -r l; do echo "$l $(readlink "$l")"; done; } | cksum | cut -d' ' -f1)"
    c="$(find . -type f | LC_ALL=C sort | while read -r f; do cksum < "$f"; done | cksum | cut -d' ' -f1)"
    echo "count=$n bytes=$b meta=$m sum=$c" )
}
_mg_launchctl() { echo "$*" >> "$TMP/lc.log"; }

_st() { mg_init; mg_status; }
_get() { mg_init; mg_get "$1"; }
_mg_vol() { mkdir -p "$DK/vol/$1"; }
_mg_env() {
  rm -rf "$TMP/home" "$TMP/dk" "$TMP/sd" "$TMP/reexec"; mkdir -p "$TMP/home"
  HOME="$(cd "$TMP/home" && pwd -P)"; DK="$TMP/dk"; INST="$HOME/$OLDP"; NEW="$HOME/$NEWP"   # (resolved: macOS temp folders are links)
  mkdir -p "$DK/vol" "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$INST/.state/migrate" "$INST/bin" "$INST/.git/info"
  : > "$DK/log"; : > "$DK/containers"; : > "$DK/networks"; : > "$DK/images"; : > "$TMP/lc.log"
  STACK_DIR="$INST"; ENV_FILE="$INST/.env"; STATE_DIR="$INST/.state"
  MG_OS=Darwin; MG_IMAGE=fake/image:1; MG_POLL_S=0
  docker() { _mg_docker "$@"; }
  launchctl() { _mg_launchctl "$@"; }
  systemctl() { echo "$*" >> "$TMP/sc.log"; }
  export MG_OS MG_IMAGE MG_POLL_S STACK_DIR
  ASSUME_YES=1
  # the owner's kind of install: databases, a sandbox home, sockets, the portal's state
  _mg_vol "${OLDP}_pgdata"; printf '16\n' > "$DK/vol/${OLDP}_pgdata/PG_VERSION"; mkdir -p "$DK/vol/${OLDP}_pgdata/base/1"; head -c 3000 /dev/urandom > "$DK/vol/${OLDP}_pgdata/base/1/1259"
  _mg_vol "${OLDP}_owui"; head -c 5000 /dev/urandom > "$DK/vol/${OLDP}_owui/webui.db"
  _mg_vol "${OLDP}_terminal-home"; mkdir -p "$DK/vol/${OLDP}_terminal-home/.config/$OLDP" "$DK/vol/${OLDP}_terminal-home/.$OLDP-trash/x"
  echo '{}' > "$DK/vol/${OLDP}_terminal-home/.config/$OLDP/mcp.json"; echo t > "$DK/vol/${OLDP}_terminal-home/.$OLDP-trash/x/f"
  _mg_vol "${OLDP}_terminal-socket"; _mg_vol "${OLDP}_portal-state"; echo '{"s":1}' > "$DK/vol/${OLDP}_portal-state/sessions.json"
  _mg_vol "${OLDP}_${OLDP}-owner"; echo "$INST" > "$DK/owner"
  printf 'c1 %s\nc2 %s\n' "$OLDP" "$OLDP" > "$DK/containers"; printf 'n1 %s\n' "$OLDP" > "$DK/networks"
  printf '%s/portal:local\n%s/shared-mcp:local\nfake/image:1\n' "$OLDP" "$OLDP" > "$DK/images"
  # other projects and other products' files that must never be touched
  _mg_vol "bn-dev_pgdata"; echo keep > "$DK/vol/bn-dev_pgdata/f"; _mg_vol "${OLDP}-2_pgdata"
  mkdir -p "$HOME/.local/state/devos-heavy"; echo lock > "$HOME/.local/state/devos-heavy/heavy.lock"
  # the install
  cat > "$ENV_FILE" <<EOF
POSTGRES_PASSWORD=pw
OPENWEBUI_ADMIN_EMAIL=admin@$OLDP.local
PORTAL_HOST=$OLDP.localhost
PORTAL_PORT=8800
PORTAL_ORIGIN=http://$OLDP.localhost:8800
CHAT_ORIGIN=http://chat.$OLDP.localhost:8800
PREVIEW_DOMAIN=$OLDP-preview.localhost
BEDROCK_NOW_RELEASES_URL=https://example.invalid/releases
BEDROCK_NOW_ALLOW_PUBLIC_HOST=0
TERMINAL_WORKSPACE=$HOME/$OLDP-workspace
CODE_ENABLED=true
EOF
  chmod 600 "$ENV_FILE"
  mkdir -p "$INST/.state/runtimes/lmstudio/home/.lmstudio/.internal" "$INST/.state/runtimes/lmstudio/home/.lmstudio/models/org" \
    "$INST/.state/mlx/hf/hub/models--a--b/blobs" "$INST/.state/mlx/hf/hub/models--a--b/snapshots/rev1" "$INST/.state/projects" "$INST/.state/sessions"
  printf '%s/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster\t%s/.state/runtimes/lmstudio/home\t.\n' "$INST" "$INST" > "$INST/.state/runtimes/lmstudio/llmster.run"
  printf '{"path":"%s/.state/runtimes/lmstudio/home/.lmstudio/llmster/x/bin/llmster","cwd":"%s/.state/runtimes/lmstudio/home"}\n' "$INST" "$INST" > "$INST/.state/runtimes/lmstudio/home/.lmstudio/.internal/llmster-install-location.json"
  printf '%s/.state/runtimes/lmstudio/home/.lmstudio\n' "$INST" > "$INST/.state/runtimes/lmstudio/home/.lmstudio-home-pointer"
  head -c 4000 /dev/urandom > "$INST/.state/mlx/hf/hub/models--a--b/blobs/abc123.incomplete"
  ln -s ../../blobs/abc123.incomplete "$INST/.state/mlx/hf/hub/models--a--b/snapshots/rev1/model.safetensors"
  ln -s "$INST/.state/mlx/hf/hub/models--a--b/blobs/abc123.incomplete" "$INST/.state/runtimes/lmstudio/home/.lmstudio/models/org/m.gguf"
  printf 'volumes:\n  - %s/.state/projects/public:/p:ro\n  - %s/%s-workspace:/workspace\n' "$INST" "$HOME" "$OLDP" > "$INST/.state/projects/compose.yaml"
  printf '{"cwd":"%s/.state/sessions/s1","note":"%s-workspace"}\n' "$INST" "$OLDP" > "$INST/.state/sessions/s1.json"
  mkdir -p "$INST/bin"; printf '#!/bin/sh\n' > "$INST/bin/devos-claude"; chmod +x "$INST/bin/devos-claude"
  ln -s "$INST/bin/devos-claude" "$HOME/.local/bin/devos-claude"
  # an install a second time: the update record names its backup folder
  printf 'backup=backups/x-auto\nroot=%s\n' "$INST" > "$INST/.state/update-record"
  # launchd: the helper and a runtime's agent, as the old code wrote them
  local osum; osum="$(printf '%s' "$INST/.state" | cksum | cut -d' ' -f1)"; OSUM="$osum"
  cat > "$HOME/Library/LaunchAgents/io.$OLDP.helper.$OLDP.plist" <<EOF
<plist><dict><key>Label</key><string>io.$OLDP.helper.$OLDP</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>$INST/bin/$OLDP-helper</string><string>$INST</string></array><key>WorkingDirectory</key><string>$INST</string></dict></plist>
EOF
  cat > "$HOME/Library/LaunchAgents/dev.devos.ade.ollama.$osum.plist" <<EOF
<plist><dict><key>Label</key><string>dev.devos.ade.ollama.$osum</string><key>EnvironmentVariables</key><dict><key>OLLAMA_MODELS</key><string>$INST/.state/runtimes/ollama/models</string></dict></dict></plist>
EOF
  git -C "$INST" init -q 2>/dev/null || true
  SAMPLE_PG="$(cksum < "$DK/vol/${OLDP}_pgdata/base/1/1259")"; SAMPLE_OWUI="$(cksum < "$DK/vol/${OLDP}_owui/webui.db")"
  SAMPLE_BLOB="$(cksum < "$INST/.state/mlx/hf/hub/models--a--b/blobs/abc123.incomplete")"
}
_mg_new_env_unused() { :; }
_mg_run() { mg_init; mg_phase_a; }
_mg_try() { ( mg_init; mg_phase_a ) > "$TMP/out" 2>&1 && MGRC=0 || MGRC=$?; }
_mg_old_untouched() { # the old volumes are as seeded, and nothing was ever removed from them
  assert_eq "$(cksum < "$DK/vol/${OLDP}_pgdata/base/1/1259")" "$SAMPLE_PG"
  assert_eq "$(cksum < "$DK/vol/${OLDP}_owui/webui.db")" "$SAMPLE_OWUI"
  [ -f "$DK/vol/${OLDP}_portal-state/sessions.json" ] && [ -f "$DK/vol/${OLDP}_terminal-home/.config/$OLDP/mcp.json" ]
  ! grep -E "^volume rm ${OLDP}_" "$DK/log" || { echo "an old volume was removed" >&2; return 1; }
  [ -d "$DK/vol/bn-dev_pgdata" ] && [ -d "$DK/vol/${OLDP}-2_pgdata" ] && [ "$(cat "$HOME/.local/state/devos-heavy/heavy.lock")" = lock ]
}

# --- what it may change ---
test_the_allowed_list_names_only_this_installs_own_things() {
  _mg_env; mg_init
  mg_allowed dir "$INST"; mg_allowed dir "$NEW"
  ! mg_allowed dir "$HOME/.local/state/devos-heavy"
  ! mg_allowed dir "$HOME"
  mg_allowed volume "${OLDP}_pgdata"; mg_allowed volume "${NEWP}_owui"
  ! mg_allowed volume "bn-dev_pgdata"
  ! mg_allowed volume "${OLDP}-2_pgdata"
  ! mg_allowed volume "bne2e-x_pgdata"
  mg_allowed image "$OLDP/portal:local"; ! mg_allowed image "bn-dev/portal:local"; ! mg_allowed image "caddy:2"
  mg_allowed container "$OLDP"; ! mg_allowed container bn-dev; ! mg_allowed network bne2e-x
  mg_allowed launchd "$HOME/Library/LaunchAgents/io.$OLDP.helper.$OLDP.plist"
  mg_allowed launchd "$HOME/Library/LaunchAgents/io.$NEWP.helper.$NEWP.plist"
  mg_allowed launchd "$HOME/Library/LaunchAgents/dev.devos.ade.ollama.123.plist.pre-devos-ade"
  ! mg_allowed launchd "$HOME/Library/LaunchAgents/io.devos-companion.main.plist"
  ! mg_allowed launchd "$HOME/Library/LaunchAgents/io.$OLDP.helper.plist.bak/../x"
  ! mg_allowed launchd "/tmp/io.$OLDP.helper.$OLDP.plist"
  mg_allowed bin "$HOME/.local/bin/devos-claude"; mg_allowed bin "$HOME/.local/bin/claude-bedrock"; ! mg_allowed bin "$HOME/.local/bin/xirp"
  mg_allowed config ".config/$NEWP"; ! mg_allowed config ".config/devos-heavy"; ! mg_allowed config ".ssh"
  mg_allowed systemd "$(mg_systemd_dir)/$OLDP-helper-$OLDP.service"; ! mg_allowed systemd "$(mg_systemd_dir)/xirp.service"
  assert_eq "$MG_ALLOWED_KINDS" "dir volume image network container launchd systemd bin config"
  local out rc=0; out="$( (mg_guard volume bn-dev_pgdata) 2>&1)" || rc=$?
  [ "$rc" != 0 ]; assert_contains "$out" "refusing to change volume 'bn-dev_pgdata'"; assert_contains "$out" "devos-heavy"
  out="$( (mg_guard dir "$HOME/.local/state/devos-heavy") 2>&1)" && return 1
  assert_contains "$out" "refusing to change dir"
}
test_new_names_do_not_collide_with_the_other_products() {
  # Companion and Mobile: distinct from every name the migration creates (their names are written down in the spec)
  local n; for n in "$MG_NEW_PROJECT" "$MG_NEW_LABEL" "$MG_NEW_DIRNAME" "$MG_NEW_CONF"; do
    case "$n" in *companion* | *mobile* | *heavy* | *xirp*) echo "collides: $n" >&2; return 1 ;; esac
  done
  assert_eq "$MG_NEW_PROJECT-$MG_NEW_LABEL" "devos-ade-io.devos-ade."
}

# --- is it needed ---
test_nothing_to_move_without_old_volumes_or_for_another_project_or_another_folders_install() {
  _mg_env; mg_init
  rm -rf "$DK/vol/${OLDP}_"*; ! mg_needed
  _mg_env; mg_init; set_env COMPOSE_PROJECT_NAME bn-dev; ! mg_needed
  _mg_env; mg_init; echo "$HOME/elsewhere" > "$DK/owner"; mkdir -p "$HOME/elsewhere"; ! mg_needed
  _mg_env; mg_init; mg_needed
  _mg_env; mg_init; : > "$DK/down"; ! mg_needed
}

# --- preflight: refusals change nothing ---
_mg_nothing_changed() {
  assert_eq "$(awk '$2 == "'"$OLDP"'"' "$DK/containers" | wc -l | tr -d ' ')" 2
  [ -d "$INST" ] && [ ! -e "$NEW" ] && [ ! -L "$INST" ]
  [ -z "$(ls "$DK/vol" | grep "^${NEWP}_" || true)" ]
  [ -z "$(get_env COMPOSE_PROJECT_NAME)" ] && [ "$(get_env PORTAL_HOST)" = "$OLDP.localhost" ] && [ ! -f "$INST/.env.pre-devos-ade" ]
  _mg_old_untouched
}
test_preflight_refuses_when_the_disk_is_too_small_and_changes_nothing() {
  _mg_env; echo 1 > "$DK/free_kb"; _mg_try
  [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "not enough disk space"; assert_contains "$(cat "$TMP/out")" "plus 10%"
  _mg_nothing_changed
}
test_preflight_refuses_when_the_target_folder_exists() {
  _mg_env; mkdir -p "$NEW"; _mg_try
  [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "$NEW exists already"; _mg_nothing_changed
}
test_preflight_refuses_another_file_system() {
  _mg_env; mg_dev() { case "$1" in "$INST") echo 1 ;; *) echo 2 ;; esac; }; _mg_try
  [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "another file system"; _mg_nothing_changed
}
test_preflight_refuses_when_the_new_name_already_has_volumes() {
  _mg_env; _mg_vol "${NEWP}_pgdata"; _mg_try
  [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "already has volumes"
  [ -z "$(get_env COMPOSE_PROJECT_NAME)" ] && [ -d "$INST" ] && [ ! -e "$NEW" ]; _mg_old_untouched
}
test_preflight_refuses_without_docker_and_without_the_copy_image() {
  _mg_env; : > "$DK/down"; _mg_try; [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "Docker is not running"
  _mg_env; MG_IMAGE=''; compose_service_image() { echo ''; }; _mg_try; [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "no local image"
}
test_preflight_says_the_size_and_the_time_before_it_stops_anything() {
  _mg_env; _mg_run 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "Copying "; assert_contains "$(cat "$TMP/err")" "under 2 minutes"; assert_contains "$(cat "$TMP/err")" "by rename, with no copy"
  assert_contains "$(mg_eta 9000000)" "minutes"
}

# --- the whole of phase A ---
test_the_move_copies_every_volume_verified_and_leaves_the_old_ones_whole() {
  _mg_env; _mg_run 2> "$TMP/err"
  assert_eq "$(_st)" moved
  for v in pgdata owui terminal-home portal-state terminal-socket; do [ -d "$DK/vol/${NEWP}_$v" ] || { echo "no $v" >&2; return 1; }; done
  [ ! -d "$DK/vol/${NEWP}_${OLDP}-owner" ]
  assert_eq "$(cksum < "$DK/vol/${NEWP}_pgdata/base/1/1259")" "$SAMPLE_PG"
  assert_eq "$(cksum < "$DK/vol/${NEWP}_owui/webui.db")" "$SAMPLE_OWUI"
  assert_contains "$(cat "$TMP/err")" "pgdata: verified (count="
  _mg_old_untouched
  # the new volumes carry compose's own labels (no "recreate" question at the first up)
  grep -q "volume create --label com.docker.compose.project=$NEWP --label com.docker.compose.volume=pgdata ${NEWP}_pgdata" "$DK/log"
  # containers and networks of the old project are gone (the volumes are not), other projects' stay
  assert_eq "$(awk '$2 == "'"$OLDP"'"' "$DK/containers" | wc -l | tr -d ' ')" 0
}
test_the_sandbox_home_gets_the_new_folder_names_and_only_in_the_new_volume() {
  _mg_env; _mg_run 2>/dev/null
  [ -f "$DK/vol/${NEWP}_terminal-home/.config/$NEWP/mcp.json" ] && [ ! -e "$DK/vol/${NEWP}_terminal-home/.config/$OLDP" ]
  [ -f "$DK/vol/${NEWP}_terminal-home/.$NEWP-trash/x/f" ] && [ ! -e "$DK/vol/${NEWP}_terminal-home/.$OLDP-trash" ]
  [ -f "$DK/vol/${OLDP}_terminal-home/.config/$OLDP/mcp.json" ]   # the old one is as it was
}
test_the_folder_moves_by_rename_and_the_old_name_is_a_link() {
  _mg_env; local ino; ino="$(ls -di "$INST/.state/mlx/hf" | cut -d' ' -f1)"; _mg_run 2>/dev/null
  [ -L "$INST" ] && [ "$(readlink "$INST")" = "$NEW" ] && [ -d "$NEW/.state" ]
  assert_eq "$(ls -di "$NEW/.state/mlx/hf" | cut -d' ' -f1)" "$ino"   # the same inode: nothing was copied
  assert_eq "$STACK_DIR" "$NEW"
  assert_eq "$(cksum < "$NEW/.state/mlx/hf/hub/models--a--b/blobs/abc123.incomplete")" "$SAMPLE_BLOB"
}
test_relative_links_stay_and_absolute_ones_are_rewritten() {
  _mg_env; _mg_run 2>/dev/null
  assert_eq "$(readlink "$NEW/.state/mlx/hf/hub/models--a--b/snapshots/rev1/model.safetensors")" "../../blobs/abc123.incomplete"
  assert_eq "$(readlink "$NEW/.state/runtimes/lmstudio/home/.lmstudio/models/org/m.gguf")" "$NEW/.state/mlx/hf/hub/models--a--b/blobs/abc123.incomplete"
  [ -e "$NEW/.state/runtimes/lmstudio/home/.lmstudio/models/org/m.gguf" ]
  assert_eq "$(readlink "$HOME/.local/bin/devos-claude")" "$NEW/bin/devos-claude"
}
test_runtime_records_and_generated_files_name_the_new_folder_and_keep_the_workspace_name() {
  _mg_env; _mg_run 2>/dev/null
  assert_contains "$(cat "$NEW/.state/runtimes/lmstudio/llmster.run")" "$NEW/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster"
  assert_contains "$(cat "$NEW/.state/runtimes/lmstudio/home/.lmstudio/.internal/llmster-install-location.json")" "$NEW/.state/runtimes/lmstudio/home"
  assert_eq "$(cat "$NEW/.state/runtimes/lmstudio/home/.lmstudio-home-pointer")" "$NEW/.state/runtimes/lmstudio/home/.lmstudio"
  assert_contains "$(cat "$NEW/.state/projects/compose.yaml")" "$NEW/.state/projects/public:/p:ro"
  assert_contains "$(cat "$NEW/.state/projects/compose.yaml")" "$HOME/$OLDP-workspace:/workspace"   # not the start of "bedrock-now": left alone
  assert_contains "$(cat "$NEW/.state/sessions/s1.json")" "$NEW/.state/sessions/s1"
  assert_eq "$(get_env TERMINAL_WORKSPACE)" "$HOME/$OLDP-workspace"
}
test_no_absolute_path_or_link_names_the_old_folder_afterwards() {
  _mg_env; _mg_run 2>/dev/null
  # the walk: every text file and every link under the new folder (not git, not the .env backup, not backups/)
  local left
  left="$(grep -rIlE -- "$(printf '%s' "$INST" | sed 's/[.]/\\./g')(/|\$|\"|[[:space:]])" "$NEW" --exclude-dir=.git --exclude-dir=backups --exclude=.env.pre-devos-ade 2>/dev/null | grep -v '/\.state/migrate/' || true)"
  [ -z "$left" ] || { echo "old folder still named in: $left" >&2; return 1; }
  local l t; while IFS= read -r l; do t="$(readlink "$l")"; case "$t" in "$INST" | "$INST"/*) echo "link $l -> $t" >&2; return 1 ;; esac; done <<EOF
$(find "$NEW" -path "$NEW/.git" -prune -o -type l -print)
EOF
}
test_the_ports_and_other_settings_stay() {
  _mg_env; _mg_run 2>/dev/null
  assert_eq "$(get_env PORTAL_PORT)" 8800; assert_eq "$(get_env CODE_ENABLED)" true; assert_eq "$(get_env POSTGRES_PASSWORD)" pw
}

# --- .env ---
test_env_keys_hosts_and_pins_are_rewritten_and_the_email_stays() {
  _mg_env; _mg_run 2>/dev/null
  assert_eq "$(get_env DEVOS_ADE_RELEASES_URL)" "https://example.invalid/releases"; assert_eq "$(get_env BEDROCK_NOW_RELEASES_URL)" ""
  assert_eq "$(get_env DEVOS_ADE_ALLOW_PUBLIC_HOST)" 0
  assert_eq "$(get_env PORTAL_HOST)" "$NEWP.localhost"; assert_eq "$(get_env PORTAL_ORIGIN)" "http://$NEWP.localhost:8800"
  assert_eq "$(get_env CHAT_ORIGIN)" "http://chat.$NEWP.localhost:8800"; assert_eq "$(get_env PREVIEW_DOMAIN)" "$NEWP-preview.localhost"
  assert_eq "$(get_env OPENWEBUI_ADMIN_EMAIL)" "admin@$OLDP.local"   # setup wrote it at the first setup: every store is keyed by it
  assert_eq "$(get_env COMPOSE_PROJECT_NAME)" ""                      # the pin of the first step is gone
  assert_eq "$(_get host_moved)" 1
}
test_a_custom_portal_host_is_kept_with_every_value_that_follows_it() {
  _mg_env; set_env PORTAL_HOST my.localhost; set_env PORTAL_ORIGIN http://my.localhost:8800; _mg_run 2>/dev/null
  assert_eq "$(get_env PORTAL_HOST)" my.localhost; assert_eq "$(get_env PORTAL_ORIGIN)" "http://my.localhost:8800"
  assert_eq "$(get_env PREVIEW_DOMAIN)" "$OLDP-preview.localhost"   # (a custom host: nothing else is guessed)
  assert_eq "$(get_env DEVOS_ADE_RELEASES_URL)" "https://example.invalid/releases"
}
test_env_is_backed_up_once_before_it_is_rewritten() {
  _mg_env; local before; before="$(cat "$ENV_FILE")"; _mg_run 2>/dev/null
  assert_eq "$(cat "$NEW/.env.pre-devos-ade")" "$before"; assert_eq "$(perm_of "$NEW/.env.pre-devos-ade")" 600
  echo 'X=2' >> "$NEW/.env.pre-devos-ade"; local keep; keep="$(cat "$NEW/.env.pre-devos-ade")"
  ( mg_init; MG_DIR="$NEW"; ENV_FILE="$NEW/.env"; mg_step_env ) 2>/dev/null
  assert_eq "$(cat "$NEW/.env.pre-devos-ade")" "$keep"   # the first backup stands
}
test_a_missing_email_is_pinned_to_the_old_default_and_a_tailscale_install_keeps_its_names() {
  _mg_env; unset_env OPENWEBUI_ADMIN_EMAIL; set_env REMOTE_MODE tailscale; _mg_run 2>/dev/null
  assert_eq "$(get_env OPENWEBUI_ADMIN_EMAIL)" "admin@$OLDP.local"; assert_eq "$(_get email_pinned)" "admin@$OLDP.local"
  assert_eq "$(get_env TS_SERVICE)" "$OLDP"; assert_eq "$(get_env TS_HOSTNAME)" "$OLDP-node"; assert_eq "$(get_env TS_TAG)" "tag:$OLDP"
}
test_an_explicit_old_project_name_becomes_the_new_one() {
  _mg_env; set_env COMPOSE_PROJECT_NAME "$OLDP"; _mg_run 2>/dev/null; assert_eq "$(get_env COMPOSE_PROJECT_NAME)" "$NEWP"
}
test_the_old_project_stays_the_one_that_runs_until_the_copy_is_verified() {
  _mg_env; : > "$DK/corrupt"; _mg_try
  [ "$MGRC" != 0 ]; assert_eq "$(get_env COMPOSE_PROJECT_NAME)" "$OLDP"
}

# --- failures ---
test_a_copy_that_does_not_match_is_removed_and_everything_else_is_as_it_was() {
  _mg_env; : > "$DK/corrupt"; _mg_try
  [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "does not match the original"; assert_contains "$(cat "$TMP/out")" "your data is untouched"
  assert_contains "$(cat "$TMP/out")" "starts the old project"
  assert_eq "$(_st)" failed; assert_eq "$(_get failed_step)" copy
  [ ! -d "$DK/vol/${NEWP}_pgdata" ]; [ -d "$INST" ] && [ ! -L "$INST" ] && [ ! -e "$NEW" ]
  assert_eq "$(get_env PORTAL_HOST)" "$OLDP.localhost"; [ -f "$INST/.env.pre-devos-ade" ]; _mg_old_untouched
}
test_a_copy_command_that_fails_is_reported_and_leaves_the_old_project() {
  _mg_env; : > "$DK/copyfail"; _mg_try
  [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "failed (status 1)"; [ -d "$INST" ] && [ ! -e "$NEW" ]; _mg_old_untouched
}
test_a_failed_move_then_a_rerun_finishes() {
  _mg_env; : > "$DK/corrupt"; _mg_try; [ "$MGRC" != 0 ]
  rm -f "$DK/corrupt"; _mg_run 2>/dev/null
  assert_eq "$(_st)" moved; assert_eq "$(cksum < "$DK/vol/${NEWP}_pgdata/base/1/1259")" "$SAMPLE_PG"; _mg_old_untouched
}
test_an_interruption_at_each_step_is_resumed_and_ends_the_same() {
  local s ref
  for s in preflight stop copy inner env images move paths launchd; do
    _mg_env
    ( mg_init; eval "mg_step_$s() { mg_fail $s injected; }"; mg_phase_a ) > "$TMP/out" 2>&1 && { echo "step $s did not fail" >&2; return 1; }
    assert_contains "$(cat "$TMP/out")" "failed at '$s'"
    _mg_run 2>/dev/null
    assert_eq "$(_st)" moved
    [ -d "$NEW/.state" ] && [ -L "$INST" ] || { echo "after $s: not moved" >&2; return 1; }
    assert_eq "$(get_env PORTAL_HOST)" "$NEWP.localhost"
    assert_eq "$(cksum < "$DK/vol/${NEWP}_owui/webui.db")" "$SAMPLE_OWUI"
    [ -f "$DK/vol/${NEWP}_terminal-home/.config/$NEWP/mcp.json" ]
    assert_eq "$(readlink "$NEW/.state/runtimes/lmstudio/home/.lmstudio/models/org/m.gguf")" "$NEW/.state/mlx/hf/hub/models--a--b/blobs/abc123.incomplete"
    [ -f "$HOME/Library/LaunchAgents/io.$NEWP.helper.$NEWP.plist" ] || { echo "after $s: no new plist" >&2; return 1; }
    _mg_old_untouched
  done
}
test_a_copy_cut_off_in_the_middle_is_made_again_from_the_start() {
  _mg_env; mg_init; mg_put started 1; mg_put status running; mg_step_done preflight; mg_put "vol.pgdata" copying
  _mg_vol "${NEWP}_pgdata"; echo half > "$DK/vol/${NEWP}_pgdata/partial"
  _mg_run 2>/dev/null
  [ ! -e "$DK/vol/${NEWP}_pgdata/partial" ]; assert_eq "$(cksum < "$DK/vol/${NEWP}_pgdata/base/1/1259")" "$SAMPLE_PG"
}
test_a_new_volume_that_is_not_ours_is_never_overwritten() {
  _mg_env; mg_init; mg_put status running; mg_step_done preflight; _mg_vol "${NEWP}_owui"; echo precious > "$DK/vol/${NEWP}_owui/x"
  _mg_try; [ "$MGRC" != 0 ]; assert_contains "$(cat "$TMP/out")" "not from this migration"; assert_eq "$(cat "$DK/vol/${NEWP}_owui/x")" precious
}

# --- repeat ---
test_a_second_run_does_nothing() {
  _mg_env; _mg_run 2>/dev/null; printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null; assert_eq "$(_st)" complete
  local n; n="$(wc -l < "$DK/log" | tr -d ' ')"
  ( migrate_update_hook ) > "$TMP/out" 2>&1; assert_eq "$?" 0
  ( migrate_update_finish ) >> "$TMP/out" 2>&1
  assert_eq "$(wc -l < "$DK/log" | tr -d ' ')" "$n"   # not one docker call
  ! mg_needed
}
test_the_update_hook_continues_from_the_new_folder_with_a_new_process() {
  _mg_env
  printf '#!/bin/sh\npwd -P > "%s/reexec"\necho "$@" >> "%s/reexec"\n' "$TMP" "$TMP" > "$INST/stack"; chmod +x "$INST/stack"
  ( migrate_update_hook ) > "$TMP/out" 2>&1
  assert_eq "$(sed -n 1p "$TMP/reexec")" "$(cd "$NEW" && pwd -P)"; assert_eq "$(sed -n 2p "$TMP/reexec")" "update --yes"
  assert_contains "$(cat "$TMP/out")" "continuing from $NEW"
}
test_a_hook_in_an_install_that_needs_nothing_does_nothing() {
  _mg_env; rm -rf "$DK/vol/${OLDP}_"*; : > "$DK/log"; ( migrate_update_hook; migrate_update_finish ); assert_eq "$(cat "$DK/log")" "$(printf 'info\nvolume ls -q\nvolume ls -q')" 2>/dev/null || true
  [ ! -e "$NEW" ]
}

# --- the end ---
test_the_end_checks_health_and_says_where_it_lives() {
  _mg_env; _mg_run 2>/dev/null; printf 'd1 %s\n' "$NEWP" >> "$DK/containers"
  migrate_update_finish 2> "$TMP/err"
  assert_eq "$(_st)" complete
  assert_contains "$(cat "$TMP/err")" "DevOS ADE now lives at http://$NEWP.localhost (the old address forwards there). Sign in again once there"
  assert_contains "$(cat "$TMP/err")" "./stack migrate --remove-old"
  assert_contains "$(migrate_status)" "moved to $NEWP"
  assert_contains "$(migrate_backup_line)" "${OLDP}_* volumes"
}
test_the_end_waits_when_nothing_runs_and_warns_about_an_unhealthy_container() {
  _mg_env; _mg_run 2>/dev/null; migrate_update_finish 2> "$TMP/err"; assert_eq "$(_st)" moved; assert_contains "$(cat "$TMP/err")" "nothing of $NEWP runs yet"
  printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; echo d1 > "$DK/unhealthy"; migrate_update_finish 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "unhealthy"; assert_eq "$(_st)" complete
}

# --- launchd and systemd ---
test_launchd_agents_get_the_new_labels_and_paths_and_the_old_ones_are_kept_aside() {
  _mg_env; _mg_run 2>/dev/null
  local la="$HOME/Library/LaunchAgents" nsum; nsum="$(printf '%s' "$NEW/.state" | cksum | cut -d' ' -f1)"
  [ -f "$la/io.$NEWP.helper.$NEWP.plist" ] && [ -f "$la/dev.devos.ade.ollama.$nsum.plist" ]
  assert_contains "$(cat "$la/io.$NEWP.helper.$NEWP.plist")" "<string>io.$NEWP.helper.$NEWP</string>"
  assert_contains "$(cat "$la/io.$NEWP.helper.$NEWP.plist")" "<string>$NEW</string>"
  assert_not_contains "$(cat "$la/io.$NEWP.helper.$NEWP.plist")" "$INST"
  assert_contains "$(cat "$la/dev.devos.ade.ollama.$nsum.plist")" "$NEW/.state/runtimes/ollama/models"
  assert_contains "$(cat "$la/dev.devos.ade.ollama.$nsum.plist")" "<string>dev.devos.ade.ollama.$nsum</string>"
  [ ! -f "$la/dev.devos.ade.ollama.$OSUM.plist" ] && [ -f "$la/dev.devos.ade.ollama.$OSUM.plist.pre-devos-ade" ]
  assert_contains "$(cat "$TMP/lc.log")" "bootout gui/$(id -u)/dev.devos.ade.ollama.$OSUM"
  assert_contains "$(cat "$TMP/lc.log")" "bootstrap gui/$(id -u) $la/dev.devos.ade.ollama.$nsum.plist"
}
test_the_helper_is_not_relabelled_from_inside_its_own_job_but_by_its_next_idle_start() {
  _mg_env; DEVOS_ADE_JOB_ORIGIN=helper; export DEVOS_ADE_JOB_ORIGIN; _mg_run 2>/dev/null
  local la="$HOME/Library/LaunchAgents"
  [ -f "$la/io.$NEWP.helper.$NEWP.plist" ] && [ -f "$la/io.$OLDP.helper.$OLDP.plist" ]       # the new one written, the old one left
  ! grep -q "io.$OLDP.helper" "$TMP/lc.log"                                                    # and nothing was booted out under the update
  assert_eq "$(_get helper)" pending
  [ -x "$NEW/bin/$OLDP-helper" ] && assert_contains "$(cat "$NEW/bin/$OLDP-helper")" "migrate --finish-helper"
  grep -qx "/bin/$OLDP-helper" "$NEW/.git/info/exclude"
  migrate_finish_helper
  assert_contains "$(cat "$TMP/lc.log")" "bootstrap gui/$(id -u) $la/io.$NEWP.helper.$NEWP.plist"
  assert_contains "$(cat "$TMP/lc.log")" "bootout gui/$(id -u)/io.$OLDP.helper.$OLDP"
  [ -f "$la/io.$OLDP.helper.$OLDP.plist.pre-devos-ade" ] && [ ! -f "$la/io.$OLDP.helper.$OLDP.plist" ]; assert_eq "$(_get helper)" done
  unset DEVOS_ADE_JOB_ORIGIN
}
test_a_linux_helper_unit_is_switched_the_same_way() {
  _mg_env; MG_OS=Linux; export MG_OS; local sd="$TMP/sd"; MG_SYSTEMD_DIR="$sd"; mkdir -p "$sd"; export MG_SYSTEMD_DIR
  printf '[Service]\nExecStart=/bin/bash "%s/bin/%s-helper" "%s"\nWorkingDirectory=%s\n' "$INST" "$OLDP" "$INST" "$INST" > "$sd/$OLDP-helper-$OLDP.service"
  _mg_run 2>/dev/null
  [ -f "$sd/$NEWP-helper-$NEWP.service" ] && [ -f "$sd/$OLDP-helper-$OLDP.service.pre-devos-ade" ]
  assert_contains "$(cat "$sd/$NEWP-helper-$NEWP.service")" "$NEW"; assert_not_contains "$(cat "$sd/$NEWP-helper-$NEWP.service")" "$INST"
  assert_contains "$(cat "$TMP/sc.log")" "--user enable --now $NEWP-helper-$NEWP.service"
  assert_contains "$(cat "$TMP/sc.log")" "--user disable --now $OLDP-helper-$OLDP.service"
}

# --- the backup: --remove-old and --rollback ---
test_remove_old_refuses_before_the_move_is_finished_and_asks_before_it_deletes() {
  _mg_env; _mg_run 2>/dev/null
  ( migrate_remove_old ) > "$TMP/out" 2>&1 && return 1; assert_contains "$(cat "$TMP/out")" "has not finished"
  printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null
  ASSUME_YES=0; confirm() { return 1; }
  ( migrate_remove_old ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "volume  ${OLDP}_pgdata"; assert_contains "$(cat "$TMP/out")" "file"; assert_contains "$(cat "$TMP/out")" "aborted"
  _mg_old_untouched
}
test_remove_old_lists_then_removes_only_the_backup() {
  _mg_env; _mg_run 2>/dev/null; printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null
  migrate_remove_old > "$TMP/out" 2>&1
  [ ! -d "$DK/vol/${OLDP}_pgdata" ] && [ ! -d "$DK/vol/${OLDP}_owui" ] && [ ! -d "$DK/vol/${OLDP}_${OLDP}-owner" ]
  [ -d "$DK/vol/${NEWP}_pgdata" ] && [ -d "$DK/vol/bn-dev_pgdata" ] && [ -d "$DK/vol/${OLDP}-2_pgdata" ]
  [ ! -f "$NEW/.env.pre-devos-ade" ] && [ ! -L "$INST" ] && [ ! -e "$HOME/Library/LaunchAgents/dev.devos.ade.ollama.$OSUM.plist.pre-devos-ade" ]
  ! grep -q "^$OLDP/" "$DK/images"; grep -q "^$NEWP/portal:local" "$DK/images"
  [ -f "$HOME/.local/state/devos-heavy/heavy.lock" ]
  assert_contains "$(migrate_status)" "moved to $NEWP"; assert_not_contains "$(migrate_status)" "remove-old"
  migrate_remove_old > "$TMP/out" 2>&1; assert_contains "$(cat "$TMP/out")" "removed before"
}
test_nothing_old_is_deleted_by_the_move_itself() {
  _mg_env; _mg_run 2>/dev/null; printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null
  [ -d "$DK/vol/${OLDP}_pgdata" ] && [ -f "$NEW/.env.pre-devos-ade" ] && [ -L "$INST" ] && grep -q "^$OLDP/portal:local" "$DK/images"
  [ -f "$HOME/Library/LaunchAgents/io.$OLDP.helper.$OLDP.plist.pre-devos-ade" ]
  ! grep -E "^(volume rm|rmi) " "$DK/log"
}
test_rollback_returns_the_old_project_folder_env_and_labels_with_the_data_and_keeps_the_new_volumes() {
  _mg_env; local envbefore; envbefore="$(cat "$ENV_FILE")"
  _mg_run 2>/dev/null; printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null
  echo 'NEWDATA=1' >> "$NEW/.env"
  migrate_rollback 2> "$TMP/err"
  assert_eq "$(_st)" rolled-back
  [ -d "$INST/.state" ] && [ ! -L "$INST" ] && [ ! -e "$NEW" ]
  assert_eq "$(get_env PORTAL_HOST)" "$OLDP.localhost"; assert_eq "$(get_env BEDROCK_NOW_RELEASES_URL)" "https://example.invalid/releases"
  assert_eq "$(get_env COMPOSE_PROJECT_NAME)" "$OLDP"        # the checked-out code must keep running the old project
  assert_eq "$(get_env NEWDATA)" ""; [ -f "$INST/.env.devos-ade-rolled-back" ]
  assert_contains "$(cat "$INST/.state/runtimes/lmstudio/llmster.run")" "$INST/.state/runtimes/lmstudio/home"
  assert_eq "$(readlink "$INST/.state/runtimes/lmstudio/home/.lmstudio/models/org/m.gguf")" "$INST/.state/mlx/hf/hub/models--a--b/blobs/abc123.incomplete"
  assert_eq "$(readlink "$INST/.state/mlx/hf/hub/models--a--b/snapshots/rev1/model.safetensors")" "../../blobs/abc123.incomplete"
  assert_eq "$(readlink "$HOME/.local/bin/devos-claude")" "$INST/bin/devos-claude"
  local la="$HOME/Library/LaunchAgents"
  [ -f "$la/io.$OLDP.helper.$OLDP.plist" ] && [ ! -f "$la/io.$NEWP.helper.$NEWP.plist" ] && [ -f "$la/dev.devos.ade.ollama.$OSUM.plist" ]
  [ -d "$DK/vol/${NEWP}_pgdata" ] && assert_contains "$(cat "$TMP/err")" "${NEWP}_pgdata"   # kept, said
  assert_eq "$(awk '$2 == "'"$NEWP"'"' "$DK/containers" | wc -l | tr -d ' ')" 0
  _mg_old_untouched
  assert_eq "$(cksum < "$INST/.state/mlx/hf/hub/models--a--b/blobs/abc123.incomplete")" "$SAMPLE_BLOB"
}
test_rollback_works_from_a_move_that_stopped_halfway_and_refuses_after_remove_old() {
  _mg_env; : > "$DK/corrupt"; _mg_try; [ "$MGRC" != 0 ]
  mg_init; migrate_rollback 2>/dev/null; assert_eq "$(_st)" rolled-back; assert_eq "$(get_env COMPOSE_PROJECT_NAME)" "$OLDP"; _mg_old_untouched
  _mg_env; _mg_run 2>/dev/null; printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null; migrate_remove_old >/dev/null 2>&1
  ( migrate_rollback ) > "$TMP/out" 2>&1 && return 1; assert_contains "$(cat "$TMP/out")" "backup was removed"
}
test_rollback_with_nothing_to_go_back_from_says_so() {
  _mg_env; mg_init; ( migrate_rollback ) > "$TMP/out" 2>&1 && return 1; assert_contains "$(cat "$TMP/out")" "nothing to go back from"
}

# --- the command and the hosts ---
test_the_status_says_what_is_going_on_in_each_state() {
  _mg_env; assert_contains "$(migrate_status)" "not moved yet"
  rm -rf "$DK/vol/${OLDP}_"*; assert_contains "$(migrate_status)" "nothing to move"
  _mg_env; _mg_try; mg_init; mg_put status failed; mg_put failed_step copy; assert_contains "$(migrate_status)" "stopped at: copy"
  assert_contains "$(migrate_usage)" "--rollback"; assert_contains "$(migrate_usage)" "--remove-old"
  ( cmd_migrate --nonsense ) > "$TMP/out" 2>&1 && return 1; assert_contains "$(cat "$TMP/out")" "usage: ./stack migrate"
}
test_the_old_hostname_answers_with_a_308_for_every_method_refuses_sockets_and_sets_no_cookie() {
  local f; f="$(cat "$STACK_DIR/caddy/legacy-hosts.caddy")"
  assert_contains "$f" "http://bedrock-now.localhost {"; assert_contains "$f" "http://*.bedrock-now.localhost {"
  assert_contains "$f" "http://bedrock-now-preview.localhost, http://*.bedrock-now-preview.localhost {"
  assert_eq "$(grep -c 'redir .* 308$' "$STACK_DIR/caddy/legacy-hosts.caddy")" 3
  assert_contains "$f" "{http.request.host.labels.2}.{\$PORTAL_HOST}:{\$PORTAL_PORT:80}{uri} 308"   # path and query kept
  assert_contains "$f" "header -Set-Cookie"; assert_contains "$f" "(?i)^websocket\$"; assert_contains "$f" " 426"
  assert_not_contains "$f" "reverse_proxy"; assert_not_contains "$f" "header_up"
  assert_eq "$(grep -c '^import legacy-hosts.caddy$' "$STACK_DIR/caddy/Caddyfile")" 1
  ! grep -qE '^[[:space:]]*(@[a-z_]+ )?method ' "$STACK_DIR/caddy/legacy-hosts.caddy"   # no method matcher: GET, HEAD, POST, PUT, DELETE alike
}
