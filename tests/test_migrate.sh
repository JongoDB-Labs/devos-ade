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
        rm) if [ -f "$DK/rmfail" ] && grep -qx "$2" "$DK/rmfail"; then return 1; fi; rm -rf "$DK/vol/$2" ;;
      esac ;;
    ps) case "$*" in
          *health=unhealthy*) cat "$DK/unhealthy" 2>/dev/null || true ;;
          *status=restarting*) cat "$DK/restarting" 2>/dev/null || true ;;
          *service=postgres*) local all="$*" p; p="${all#*project=}"; p="${p%% *}"; awk -v p="$p" '$2 == p && $3 == "postgres" { print $1 }' "$DK/containers" ;;
          *) local all="$*" p; p="${all#*project=}"; p="${p%% *}"; awk -v p="$p" '$2 == p { print $1 }' "$DK/containers" ;;
        esac ;;
    exec) local cid="$2" proj last; proj="$(awk -v c="$cid" '$1 == c { print $2 }' "$DK/containers")"
      case "$*" in *datname*) cat "$DK/pgdbs-$proj" 2>/dev/null || return 1 ;;
        *) for last; do :; done; cat "$DK/pg-$proj-$last" 2>/dev/null || return 1 ;; esac ;;
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
        mg-fsck) [ ! -f "$DK/nogit" ] || { echo nogit; return 0; }
          sh -c "git() { [ ! -f \"$DK/fsckfail\" ]; }; $script" "$op" "${args[@]}" ;;
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
  printf 'c1 %s postgres\nc2 %s\n' "$OLDP" "$OLDP" > "$DK/containers"; printf 'n1 %s\n' "$OLDP" > "$DK/networks"
  printf '%s/portal:local\n%s/shared-mcp:local\nfake/image:1\n' "$OLDP" "$OLDP" > "$DK/images"
  FORGEJO=codeberg.org/forgejo/forgejo:17.0.1-rootless@sha256:abc; echo "$FORGEJO" >> "$DK/images"
  printf 'services:\n  forgejo:\n    image: %s\n    profiles: ["forgejo"]\n' "$FORGEJO" > "$INST/compose.yaml"
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
  mkdir -p "$INST/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin"; printf "#!/bin/sh\necho llmster 0.0.25\n" > "$INST/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster"; chmod +x "$INST/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster"
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
  assert_eq "$MG_ALLOWED_KINDS" "dir volume image network container launchd systemd bin config host"
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
  assert_eq "$(get_env PREVIEW_DOMAIN)" "$NEWP-preview.localhost"   # (the preview domain moves on its own; any other value is kept)
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
  assert_contains "$(cat "$TMP/out")" "refuses to start anything"
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
  assert_eq "$(get_env NEWDATA)" 1; [ -f "$INST/.env.devos-ade-rolled-back" ]   # (settings changed since the move survive)
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
test_rollback_works_from_a_move_that_stopped_halfway_and_after_remove_old() {
  _mg_env; : > "$DK/corrupt"; _mg_try; [ "$MGRC" != 0 ]
  mg_init; migrate_rollback 2>/dev/null; assert_eq "$(_st)" rolled-back; assert_eq "$(get_env COMPOSE_PROJECT_NAME)" "$OLDP"; _mg_old_untouched
  _mg_env; _mg_run 2>/dev/null; printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null; migrate_remove_old >/dev/null 2>&1
  migrate_rollback > "$TMP/out" 2>&1; assert_eq "$(_st)" rolled-back   # (the old copy having been removed does not stop a rollback)
}
test_rollback_with_nothing_to_go_back_from_says_so() {
  _mg_env; mg_init; ( migrate_rollback ) > "$TMP/out" 2>&1 && return 1; assert_contains "$(cat "$TMP/out")" "nothing to go back from"
}

# --- round 2: the way back keeps what was written since; ./stack rollback; other projects; host names; the owner marker ---
_mg_after_move() { _mg_run 2>/dev/null; printf 'd1 %s\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null; }
test_rollback_copies_the_data_written_since_the_move_back_and_keeps_the_new_volumes_untouched() {
  _mg_env; _mg_after_move
  head -c 4000 /dev/urandom > "$DK/vol/${NEWP}_owui/chat-since-the-move.db"; echo 'row-since' >> "$DK/vol/${NEWP}_pgdata/base/1/1259"
  local want_chat want_pg; want_chat="$(cksum < "$DK/vol/${NEWP}_owui/chat-since-the-move.db")"; want_pg="$(cksum < "$DK/vol/${NEWP}_pgdata/base/1/1259")"
  migrate_rollback 2>/dev/null
  assert_eq "$(cksum < "$DK/vol/${OLDP}_owui/chat-since-the-move.db")" "$want_chat"
  assert_eq "$(cksum < "$DK/vol/${OLDP}_pgdata/base/1/1259")" "$want_pg"
  assert_eq "$(cksum < "$DK/vol/${NEWP}_owui/chat-since-the-move.db")" "$want_chat"     # the new volumes: untouched, kept
  [ -f "$DK/vol/${OLDP}_owui/webui.db" ]
  ! grep -E "^volume rm " "$DK/log" | grep -v "${NEWP}_${NEWP}-owner" | grep -q .      # nothing deleted
  [ -f "$DK/vol/${OLDP}_terminal-home/.config/$OLDP/mcp.json" ] && [ ! -e "$DK/vol/${OLDP}_terminal-home/.config/$NEWP" ]
  assert_eq "$(_st)" rolled-back
}
test_rollback_reverses_the_current_env_not_the_backup() {
  _mg_env; _mg_after_move
  set_env PORTAL_PORT 8899; set_env DEVOS_ADE_NEWKEY yes; set_env LITELLM_PORT 4999
  migrate_rollback 2>/dev/null
  assert_eq "$(get_env PORTAL_PORT)" 8899; assert_eq "$(get_env BEDROCK_NOW_NEWKEY)" yes; assert_eq "$(get_env DEVOS_ADE_NEWKEY)" ""
  assert_eq "$(get_env PORTAL_HOST)" "$OLDP.localhost"; assert_eq "$(get_env COMPOSE_PROJECT_NAME)" "$OLDP"
  assert_eq "$(get_env BEDROCK_NOW_RELEASES_URL)" "https://example.invalid/releases"
  # a PORTAL_HOST the person chose is not touched
  _mg_env; set_env PORTAL_HOST ade.example.test; _mg_after_move; migrate_rollback 2>/dev/null
  assert_eq "$(get_env PORTAL_HOST)" ade.example.test
}
test_a_rollback_copy_that_does_not_verify_stops_with_the_new_volumes_intact_and_resumes() {
  _mg_env; _mg_after_move; echo more >> "$DK/vol/${NEWP}_owui/webui.db"
  : > "$DK/corrupt"; ( migrate_rollback ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "does not match"; assert_contains "$(cat "$TMP/out")" "untouched"
  assert_eq "$(_st)" complete; [ -d "$NEW" ] && [ -L "$INST" ]            # nothing else moved
  rm -f "$DK/corrupt"; migrate_rollback 2>/dev/null; assert_eq "$(_st)" rolled-back
  assert_eq "$(tail -c 5 "$DK/vol/${OLDP}_owui/webui.db")" "more"
}
test_stack_rollback_after_a_move_undoes_the_move_first_then_runs_in_the_old_folder() {
  _mg_env; _mg_after_move
  printf '#!/bin/sh\necho "OLD-STACK $*" > "%s/ran"\n' "$TMP" > "$NEW/stack"; chmod +x "$NEW/stack"
  ( migrate_rollback_first ) > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_eq "$(cat "$TMP/ran")" "OLD-STACK rollback"; [ -d "$INST/.state" ] && [ ! -L "$INST" ]
  assert_eq "$(cat "$INST/.state/migrate/marker.rolled-back-"* | grep -c status=complete)" 1
  # not moved: nothing happens
  _mg_env; mg_init; ( migrate_rollback_first ) > "$TMP/out" 2>&1; assert_eq "$(cat "$TMP/out")" ""
}
test_stack_rollback_refuses_with_the_exact_command_when_the_move_cannot_be_undone() {
  _mg_env; _mg_after_move; printf '#!/bin/sh\ntouch "%s/ran"\n' "$TMP" > "$NEW/stack"; chmod +x "$NEW/stack"
  : > "$DK/corrupt"; ( migrate_rollback_first ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "./stack migrate --rollback"; assert_contains "$(cat "$TMP/out")" "Nothing of the code was changed"; [ ! -e "$TMP/ran" ]
  rm -f "$DK/corrupt"; migrate_remove_old >/dev/null 2>&1
  ( migrate_rollback_first ) > "$TMP/out" 2>&1; [ -e "$TMP/ran" ]                   # the old copy having gone does not stop it
}
test_the_owner_marker_is_made_again_for_the_new_code_and_not_copied() {
  _mg_env; _mg_after_move
  [ -d "$DK/vol/${NEWP}_${NEWP}-owner" ]; grep -q "volume create --label io.devos-ade.dir=$NEW --label io.devos-ade.project=$NEWP ${NEWP}_${NEWP}-owner" "$DK/log"
  [ ! -d "$DK/vol/${NEWP}_${OLDP}-owner" ]
}
_mg_other_project() { # the install of project bn-dev: it has its own volumes, helper and old env keys
  _mg_env; P2=bn-dev
  set_env COMPOSE_PROJECT_NAME "$P2"
  _mg_vol "${P2}_terminal-home"; mkdir -p "$DK/vol/${P2}_terminal-home/.config/$OLDP"; echo '{}' > "$DK/vol/${P2}_terminal-home/.config/$OLDP/mcp.json"
  sed "s/helper\.$OLDP/helper.$P2/g" "$HOME/Library/LaunchAgents/io.$OLDP.helper.$OLDP.plist" > "$HOME/Library/LaunchAgents/io.$OLDP.helper.$P2.plist"
  rm -f "$HOME/Library/LaunchAgents/io.$OLDP.helper.$OLDP.plist"
  printf 'OTHER %s\n' x > /dev/null
}
test_an_install_of_another_project_gets_a_partial_move_names_only() {
  _mg_other_project
  # another install's agent on the same Mac, which must not be touched
  printf '<plist>other</plist>\n' > "$HOME/Library/LaunchAgents/io.$OLDP.helper.zzz.plist"
  _mg_run 2>/dev/null
  assert_eq "$(_get mode)" partial; assert_eq "$(_st)" moved
  assert_eq "$(get_env COMPOSE_PROJECT_NAME)" bn-dev; assert_eq "$(get_env PORTAL_HOST)" "$OLDP.localhost"
  assert_eq "$(get_env DEVOS_ADE_RELEASES_URL)" "https://example.invalid/releases"; assert_eq "$(get_env BEDROCK_NOW_RELEASES_URL)" ""
  [ -f "$NEW/.env.pre-devos-ade" ] && [ -L "$INST" ]                                      # its folder is ~/bedrock-now: it moves
  local la="$HOME/Library/LaunchAgents"
  [ -f "$la/io.$NEWP.helper.bn-dev.plist" ] && [ -f "$la/io.$OLDP.helper.bn-dev.plist.pre-devos-ade" ]
  grep -q "<string>io.$NEWP.helper.bn-dev</string>" "$la/io.$NEWP.helper.bn-dev.plist"
  [ -f "$la/io.$OLDP.helper.zzz.plist" ] && [ ! -f "$la/io.$NEWP.helper.zzz.plist" ]       # another install's agent: untouched
  [ -d "$DK/vol/bn-dev_terminal-home/.config/$NEWP" ] && [ ! -e "$DK/vol/bn-dev_terminal-home/.config/$OLDP" ]
  ! grep -E "volume (create|rm)|^tag |^rmi |^run .*mg-copy" "$DK/log" | grep -v "devos-ade-owner" | grep -q .   # no volume copy, no image change
  [ -d "$DK/vol/${OLDP}_pgdata" ] && [ ! -d "$DK/vol/${NEWP}_pgdata" ]
  migrate_update_finish 2>/dev/null; assert_eq "$(_st)" complete
  assert_contains "$(migrate_backup_line)" ".env.pre-devos-ade"
}
test_a_partial_move_in_a_folder_of_another_name_moves_no_folder_and_a_rollback_undoes_it() {
  _mg_other_project; mkdir -p "$HOME/second"; mv "$INST" "$HOME/second/stack"; INST="$HOME/second/stack"; STACK_DIR="$INST"; ENV_FILE="$INST/.env"; STATE_DIR="$INST/.state"
  _mg_run 2>/dev/null; assert_eq "$(_st)" moved; [ -d "$INST" ] && [ ! -L "$INST" ] && [ ! -e "$HOME/second/devos-ade" ]
  migrate_update_finish 2>/dev/null; set_env DEVOS_ADE_LATER 1
  migrate_rollback 2>/dev/null
  assert_eq "$(get_env BEDROCK_NOW_RELEASES_URL)" "https://example.invalid/releases"; assert_eq "$(get_env BEDROCK_NOW_LATER)" 1
  assert_eq "$(get_env COMPOSE_PROJECT_NAME)" bn-dev
  local la="$HOME/Library/LaunchAgents"; [ -f "$la/io.$OLDP.helper.bn-dev.plist" ] && [ ! -f "$la/io.$NEWP.helper.bn-dev.plist" ]
  [ -d "$DK/vol/bn-dev_terminal-home/.config/$OLDP" ] && [ ! -d "$DK/vol/${NEWP}_pgdata" ]
}
test_a_full_move_leaves_the_helper_agent_of_another_project_alone() {
  _mg_env; printf '<plist>other</plist>\n' > "$HOME/Library/LaunchAgents/io.$OLDP.helper.bn-dev.plist"
  _mg_run 2>/dev/null
  [ -f "$HOME/Library/LaunchAgents/io.$OLDP.helper.bn-dev.plist" ] && [ ! -f "$HOME/Library/LaunchAgents/io.$NEWP.helper.bn-dev.plist" ]
  [ -f "$HOME/Library/LaunchAgents/io.$NEWP.helper.$NEWP.plist" ]
}
test_the_workspace_trash_the_open_profile_and_the_hint_file_are_renamed_inside_the_list_only() {
  _mg_env; mg_init; local ws="$HOME/$OLDP-workspace" cfg="$HOME/.claude-bedrock" prof="$HOME/Library/Application Support"
  mkdir -p "$ws/$MG_OLD_TRASH/a" "$ws/p1/$MG_OLD_TRASH/b" "$ws/p1/src" "$prof/$OLDP" "$cfg" "$ws/deep/er/$MG_OLD_TRASH"
  : > "$cfg/$MG_OLD_HINT"; echo keep > "$ws/p1/$MG_OLD_TRASH/b/f"; mkdir -p "$ws/deep"
  mg_allowed host "$ws/$MG_OLD_TRASH"; mg_allowed host "$ws/p1/$MG_NEW_TRASH"; mg_allowed host "$cfg/$MG_OLD_HINT"
  ! mg_allowed host "$ws/deep/er/$MG_OLD_TRASH"; ! mg_allowed host "$HOME/.ssh"; ! mg_allowed host "$HOME/.local/state/devos-heavy"
  _mg_run 2>/dev/null
  [ -d "$ws/$MG_NEW_TRASH/a" ] && [ ! -e "$ws/$MG_OLD_TRASH" ]; assert_eq "$(cat "$ws/p1/$MG_NEW_TRASH/b/f")" keep
  [ -d "$prof/$NEWP" ] && [ ! -e "$prof/$OLDP" ]; [ -f "$cfg/$MG_NEW_HINT" ] && [ ! -e "$cfg/$MG_OLD_HINT" ]
  [ -d "$ws/deep/er/$MG_OLD_TRASH" ]                                                  # two levels down: not the stack's to rename
  migrate_rollback 2>/dev/null
  [ -d "$ws/$MG_OLD_TRASH/a" ] && [ -f "$cfg/$MG_OLD_HINT" ] && [ -d "$prof/$OLDP" ] && [ -f "$ws/p1/$MG_OLD_TRASH/b/f" ]
}
test_tailscale_defaults_are_pinned_for_a_default_and_for_another_project() {
  _mg_env; set_env REMOTE_MODE tailscale; _mg_run 2>/dev/null
  assert_eq "$(get_env TS_SERVICE)" bedrock-now; assert_eq "$(get_env TS_HOSTNAME)" bedrock-now-node; assert_eq "$(get_env TS_TAG)" tag:bedrock-now
  _mg_other_project; set_env REMOTE_MODE tailscale; set_env TS_TAG tag:mine; _mg_run 2>/dev/null
  assert_eq "$(get_env TS_SERVICE)" bedrock-now-bn-dev; assert_eq "$(get_env TS_TAG)" tag:mine
}
test_the_helper_shim_hands_over_once_and_starts_the_renamed_helper() {
  _mg_env; MG_NEW_DIR="$NEW"; mkdir -p "$TMP/shimdir/bin"; MG_OLD_UNIT_SAVE="$MG_OLD_UNIT"
  mg_init; mkdir -p "$NEW/bin"; : > "$NEW/bin/$MG_NEW_UNIT"; rm -f "$NEW/bin/$MG_OLD_UNIT"
  printf '#!/bin/sh\necho "NEW-HELPER $*" > "%s/h"\n' "$TMP" > "$NEW/bin/$MG_NEW_UNIT"
  printf '#!/bin/sh\necho "$*" >> "%s/fh"\n' "$TMP" > "$NEW/stack"; chmod +x "$NEW/stack"
  mg_helper_shim
  /bin/bash "$NEW/bin/$MG_OLD_UNIT" "$NEW"
  assert_eq "$(cat "$TMP/fh")" "migrate --finish-helper"; assert_eq "$(cat "$TMP/h")" "NEW-HELPER $NEW"
}

# --- round 3: the old copy goes by itself once the cutover is verified (owner decision) ---
_mg_pg_setup() { # the old databases are counted while the old stack runs; the new stack holds the same rows after the copy
  printf 'openwebui\nlitellm\n' > "$DK/pgdbs-$OLDP"; cp "$DK/pgdbs-$OLDP" "$DK/pgdbs-$NEWP"
  printf 'user\t2\nchat\t5\n' > "$DK/pg-$OLDP-openwebui"; printf 'spend\t10\n' > "$DK/pg-$OLDP-litellm"
  cp "$DK/pg-$OLDP-openwebui" "$DK/pg-$NEWP-openwebui"; cp "$DK/pg-$OLDP-litellm" "$DK/pg-$NEWP-litellm"
  _mg_vol "${OLDP}_gitdata"; mkdir -p "$DK/vol/${OLDP}_gitdata/repositories/u/a.git/objects" "$DK/vol/${OLDP}_gitdata/repositories/u/b.git/objects"
  echo ref > "$DK/vol/${OLDP}_gitdata/repositories/u/a.git/HEAD"; echo ref > "$DK/vol/${OLDP}_gitdata/repositories/u/b.git/HEAD"
  mkdir -p "$DK/vol/${OLDP}_terminal-home/.config/$OLDP"; echo '{"k":1}' > "$DK/vol/${OLDP}_terminal-home/.config/$OLDP/settings.json"
}
_mg_up_on_new() { printf 'd1 %s postgres\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null; }
_mg_moved_and_verified() { _mg_env; _mg_pg_setup; _mg_run 2>/dev/null; _mg_up_on_new; }
test_the_old_copy_is_removed_after_every_check_passes_and_the_small_leftovers_wait_for_the_next_update() {
  _mg_env; _mg_pg_setup; local out; _mg_run 2>/dev/null; printf 'd1 %s postgres\n' "$NEWP" >> "$DK/containers"
  out="$(migrate_update_finish 2>&1)"
  assert_contains "$out" "the old copy is removed"; assert_contains "$out" "freed"; assert_contains "$out" "2 user(s), 5 chat(s)"
  assert_eq "$(_st)" complete; assert_eq "$(_get old_copy)" removed
  ! ls "$DK/vol" | grep -q "^${OLDP}_"; ! grep -q "^$OLDP/" "$DK/images"; grep -q "^$NEWP/portal:local" "$DK/images"
  [ -d "$DK/vol/${NEWP}_pgdata" ] && [ -d "$DK/vol/bn-dev_pgdata" ] && [ -d "$DK/vol/${OLDP}-2_pgdata" ]       # the new data and others' volumes stay
  [ -f "$NEW/.env.pre-devos-ade" ] && [ -L "$INST" ]                                                        # these wait
  assert_contains "$(migrate_backup_line)" ".env.pre-devos-ade and the old folder link go with the next update"
  assert_not_contains "$(migrate_backup_line)" "delete"
  # the next update
  mg_init; migrate_update_hook 2>/dev/null
  [ ! -f "$NEW/.env.pre-devos-ade" ] && [ ! -L "$INST" ] && [ ! -e "$HOME/Library/LaunchAgents/io.$OLDP.helper.$OLDP.plist.pre-devos-ade" ]
  [ -f "$HOME/Library/LaunchAgents/io.$NEWP.helper.$NEWP.plist" ] && [ -f "$HOME/.local/state/devos-heavy/heavy.lock" ]
  assert_eq "$(migrate_backup_line)" ""
}
test_each_failed_check_keeps_the_old_copy_and_says_why() {
  local case why
  for case in rows unhealthy restarting uncounted repos fsck nogit noimage sample runtime runtimever copy gone; do
    _mg_env; _mg_pg_setup
    case "$case" in
      uncounted) rm -f "$DK/pgdbs-$OLDP" ;;
      copy) : ;;
      runtimever) mkdir -p "$INST/.state/runtimes/llamacpp/bin"; printf '#!/bin/sh\nexit 0\n' > "$INST/.state/runtimes/llamacpp/bin/llama-server"; chmod +x "$INST/.state/runtimes/llamacpp/bin/llama-server" ;;   # (runs before the move)
    esac
    _mg_run 2>/dev/null; printf 'd1 %s postgres\n' "$NEWP" >> "$DK/containers"
    case "$case" in
      rows) printf 'user\t2\nchat\t4\n' > "$DK/pg-$NEWP-openwebui"; why="chat has 4 rows" ;;
      unhealthy) echo d1 > "$DK/unhealthy"; why=unhealthy ;;
      restarting) echo d1 > "$DK/restarting"; why=restarting ;;
      uncounted) why="not counted" ;;
      repos) rm -rf "$DK/vol/${NEWP}_gitdata/repositories/u/b.git"; why="lists 1 repositories" ;;
      fsck) : > "$DK/fsckfail"; why="git fsck" ;;
      nogit) : > "$DK/nogit"; why="no git in" ;;
      noimage) grep -v forgejo "$DK/images" > "$DK/i.new"; mv "$DK/i.new" "$DK/images"; why="is not on this computer" ;;
      sample) mg_init; mg_put sample "differs (old 'a', new 'b')"; why="sample files" ;;
      runtimever) mkdir -p "$NEW/.state/runtimes/llamacpp/bin"; printf '#!/bin/sh\nexit 3\n' > "$NEW/.state/runtimes/llamacpp/bin/llama-server"; chmod +x "$NEW/.state/runtimes/llamacpp/bin/llama-server"; why="--version does not run" ;;
      runtime) printf '/x/bin/llmster\t%s/nowhere\t.\n' "$NEW" > "$NEW/.state/runtimes/lmstudio/llmster.run"; why="not there" ;;
      copy) mg_init; mg_put "vol.pgdata" copying; why="not marked verified" ;;
      gone) : > /dev/null; docker volume rm "${NEWP}_terminal-home" >/dev/null; rm -rf "$DK/vol/${NEWP}_pgdata"; why="" ;;
    esac
    [ "$case" != gone ] || continue
    migrate_update_finish > "$TMP/out" 2>&1
    assert_contains "$(cat "$TMP/out")" "KEPT"; assert_contains "$(cat "$TMP/out")" "$why"
    [ -d "$DK/vol/${OLDP}_pgdata" ] && [ -d "$DK/vol/${OLDP}_owui" ] && grep -q "^$OLDP/portal:local" "$DK/images" || { echo "$case: the old copy was touched" >&2; return 1; }
    assert_eq "$(_get old_copy)" kept
    ! grep -E "^volume rm ${OLDP}_|^rmi " "$DK/log" || { echo "$case: something was deleted" >&2; return 1; }
    assert_contains "$(migrate_backup_line)" "KEPT"
  done
}
test_verify_tries_again_and_removes_the_old_copy_once_the_check_passes() {
  _mg_env; _mg_pg_setup; _mg_run 2>/dev/null; printf 'd1 %s postgres\n' "$NEWP" >> "$DK/containers"; echo d1 > "$DK/unhealthy"
  migrate_update_finish 2>/dev/null; [ -d "$DK/vol/${OLDP}_pgdata" ]
  rm -f "$DK/unhealthy"; ( cmd_migrate --verify ) > "$TMP/out" 2>&1
  ! ls "$DK/vol" | grep -q "^${OLDP}_"; assert_eq "$(_get old_copy)" removed
}
test_a_rollback_after_the_old_copy_was_removed_brings_the_data_back_from_the_new_volumes() {
  _mg_moved_and_verified; mg_init; migrate_update_hook 2>/dev/null          # the old copy AND the leftovers are gone now
  head -c 3000 /dev/urandom > "$DK/vol/${NEWP}_owui/after.db"; local want; want="$(cksum < "$DK/vol/${NEWP}_owui/after.db")"
  echo 'NEWKEY=1' >> "$ENV_FILE"
  ! ls "$DK/vol" | grep -q "^${OLDP}_"
  migrate_rollback 2>/dev/null
  assert_eq "$(_st)" rolled-back
  assert_eq "$(cksum < "$DK/vol/${OLDP}_owui/after.db")" "$want"; assert_eq "$(cksum < "$DK/vol/${OLDP}_pgdata/base/1/1259")" "$SAMPLE_PG"
  [ -f "$DK/vol/${OLDP}_pgdata/PG_VERSION" ] && [ -d "$DK/vol/${NEWP}_owui" ]
  [ -d "$INST/.state" ] && [ ! -L "$INST" ] && assert_eq "$(get_env NEWKEY)" 1 && assert_eq "$(get_env COMPOSE_PROJECT_NAME)" "$OLDP"
  local la="$HOME/Library/LaunchAgents"; [ -f "$la/io.$OLDP.helper.$OLDP.plist" ] && [ ! -f "$la/io.$NEWP.helper.$NEWP.plist" ]   # made again from the new one
  grep -q "<string>io.$OLDP.helper.$OLDP</string>" "$la/io.$OLDP.helper.$OLDP.plist"; ! grep -q "$NEW" "$la/io.$OLDP.helper.$OLDP.plist"
  [ -d "$DK/vol/${OLDP}_terminal-home/.config/$OLDP" ] && [ ! -d "$DK/vol/${OLDP}_terminal-home/.config/$NEWP" ]
}
test_no_message_tells_the_person_to_delete_anything_or_that_disk_use_grows() {
  local f
  for f in "$STACK_DIR/docs/upgrade-to-0.45.md"; do
    ! grep -qiE "disk use (grows|doubles)|you (must|need to|have to) (delete|remove)|delete (it|them) yourself|remove it when you are sure" "$f"
  done
  _mg_moved_and_verified; ! migrate_backup_line | grep -qiE "must|have to|delete it yourself|yourself"
  ! migrate_status | grep -qiE "must|yourself"
}

# --- round 4 ---
test_the_old_address_is_forwarded_only_while_the_stack_does_not_serve_it_itself() {
  _mg_env; assert_eq "$(legacy_hosts_mode)" off                                    # the old host is the stack's own: Caddy must not define it twice
  : > "$DK/corrupt"; _mg_try; [ "$MGRC" != 0 ]; assert_eq "$(legacy_hosts_mode)" off  # a failure before the env step: still the old host
  rm -f "$DK/corrupt"; _mg_env; _mg_after_move; assert_eq "$(legacy_hosts_mode)" on
  assert_eq "$(get_env PORTAL_HOST)" "$NEWP.localhost"; assert_eq "$(get_env PREVIEW_DOMAIN)" "$NEWP-preview.localhost"
  migrate_rollback 2>/dev/null; assert_eq "$(legacy_hosts_mode)" off; assert_eq "$(get_env PREVIEW_DOMAIN)" "$OLDP-preview.localhost"
  _mg_env; set_env PORTAL_HOST ade.example.test; set_env PREVIEW_DOMAIN mine-preview.localhost; _mg_run 2>/dev/null
  assert_eq "$(get_env PREVIEW_DOMAIN)" mine-preview.localhost; assert_eq "$(legacy_hosts_mode)" on
  _mg_env; set_env PORTAL_HOST ade.example.test; set_env PREVIEW_DOMAIN "$OLDP-preview.localhost"; _mg_run 2>/dev/null   # the preview alone was the old one
  assert_eq "$(get_env PREVIEW_DOMAIN)" "$NEWP-preview.localhost"; assert_eq "$(get_env PORTAL_HOST)" ade.example.test
}

test_a_resume_copies_again_a_volume_that_changed_since_it_was_copied_and_up_refuses_meanwhile() {
  _mg_env; : > "$DK/corrupt"; _mg_try; [ "$MGRC" != 0 ]; rm -f "$DK/corrupt"
  mg_init; ( migrate_refuse_up ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "./stack update"; assert_contains "$(cat "$TMP/out")" "./stack migrate --rollback"
  assert_contains "$(cat "$TMP/out")" "(stopped at: copy"
  # the copy of owui was verified before the failure at pgdata: now the old owui changes
  [ "$(mg_get "vol.owui")" = verified ] || { echo "owui not verified" >&2; return 1; }
  printf 'newer' >> "$DK/vol/${OLDP}_owui/webui.db"
  _mg_run > "$TMP/out" 2>&1
  assert_contains "$(cat "$TMP/out")" "changed since it was copied"
  assert_eq "$(cksum < "$DK/vol/${NEWP}_owui/webui.db")" "$(cksum < "$DK/vol/${OLDP}_owui/webui.db")"
  assert_eq "$(_st)" moved; ( migrate_refuse_up ) > /dev/null 2>&1   # moved: up is allowed
}

test_a_move_that_was_killed_says_the_step_and_volume_it_stopped_at() {
  # (killed during the copy: no failed_step is written; one of an earlier try that was resumed is past)
  _mg_env; mg_init
  mg_put status running; mg_put failed_step preflight; mg_put step.preflight 1; mg_put step.record 1; mg_put step.stop 1
  mg_put vol.owui verified; mg_put vol.terminal-home copying
  ( migrate_refuse_up ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "(stopped at: copy (terminal-home))"
  mg_put step.copy 1; mg_put vol.terminal-home verified
  ( migrate_refuse_up ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "(stopped at: inner)"
}

test_the_deletes_come_from_a_recorded_list_after_the_checks_are_on_disk_and_a_failed_one_stays_on_it() {
  _mg_env; _mg_pg_setup; _mg_run 2>/dev/null; mg_init
  [ "$(mg_get del.n)" -ge 4 ] || { echo "no delete list at copy time" >&2; return 1; }              # volumes and image tags
  grep -q "^del\.[0-9]*=volume|[0-9]*|${OLDP}_pgdata$" "$(mg_marker)" && grep -q "^del\.[0-9]*=image|0|$OLDP/portal:local$" "$(mg_marker)"
  printf 'd1 %s postgres\n' "$NEWP" >> "$DK/containers"
  printf '%s_owui\n' "$OLDP" > "$DK/rmfail"                                                   # one volume cannot be removed
  migrate_update_finish > "$TMP/out" 2>&1
  assert_contains "$(cat "$TMP/out")" "could not remove volume ${OLDP}_owui"
  assert_eq "$(_get verified)" 1; assert_eq "$(_get chk.6)" ok; assert_eq "$(_get old_copy)" removing
  [ -d "$DK/vol/${OLDP}_owui" ] && [ ! -d "$DK/vol/${OLDP}_pgdata" ]                           # reported, not "removed"; the rest went
  assert_contains "$(migrate_backup_line)" "stopped before it was done"
  # a resume continues the deletes and never runs a check: break one the checks would catch
  echo d1 > "$DK/unhealthy"; rm -f "$DK/rmfail"; : > "$DK/log"
  ( cmd_migrate --verify ) > "$TMP/out" 2>&1
  ! ls "$DK/vol" | grep -q "^${OLDP}_"; assert_eq "$(_get old_copy)" removed
  ! grep -q "^ps " "$DK/log" || { echo "a check ran during the resume" >&2; return 1; }
}
test_a_volume_that_is_missing_is_never_made_by_a_helper_container() {
  _mg_env; MG_IMG=fake/image:1; MG_MOUNTS="-v ${OLDP}_nowhere:/from:ro"; MG_SCRIPT=true
  ! mg_run_in "$MG_IMG" mg-sum /from /from 2>"$TMP/err"; assert_contains "$(cat "$TMP/err")" "${OLDP}_nowhere is not there"
  ! grep -q "^run " "$DK/log"; [ ! -d "$DK/vol/${OLDP}_nowhere" ]
}
test_only_this_installs_launchd_files_are_cleaned_and_rolled_back_beside_a_migrated_other_install() {
  _mg_moved_and_verified
  local la="$HOME/Library/LaunchAgents" f
  # another install (bn-dev), already migrated: its kept-aside files carry its own labels
  printf '<plist>other helper</plist>\n' > "$la/io.$OLDP.helper.bn-dev.plist.pre-devos-ade"
  printf '<plist>other rt</plist>\n' > "$la/dev.devos.ade.lmstudio.4242424242.plist.pre-devos-ade"
  ( mg_init; mg_pre_files ) > "$TMP/mine"
  ! grep -q "bn-dev\|4242424242" "$TMP/mine"; grep -q "helper\.$OLDP\.plist\.pre-devos-ade" "$TMP/mine"
  mg_init; ( mg_remove_list ) > "$TMP/list"; ! grep -q "bn-dev\|4242424242" "$TMP/list"
  migrate_update_hook 2>/dev/null                                                              # the leftovers of THIS install go
  [ -f "$la/io.$OLDP.helper.bn-dev.plist.pre-devos-ade" ] && [ -f "$la/dev.devos.ade.lmstudio.4242424242.plist.pre-devos-ade" ]
  [ ! -e "$la/io.$OLDP.helper.$OLDP.plist.pre-devos-ade" ]
  migrate_rollback 2>/dev/null
  [ -f "$la/io.$OLDP.helper.bn-dev.plist.pre-devos-ade" ] && [ -f "$la/dev.devos.ade.lmstudio.4242424242.plist.pre-devos-ade" ] && [ ! -f "$la/io.$OLDP.helper.bn-dev.plist" ]
}
test_the_old_folder_link_stays_while_the_helper_is_pending_and_the_leftovers_finish_after() {
  _mg_moved_and_verified; mg_init; mg_put helper pending
  migrate_update_hook 2>"$TMP/err" >"$TMP/out"
  [ -L "$INST" ] && [ ! -f "$NEW/.env.pre-devos-ade" ]; assert_eq "$(_get leftovers_removed)" ""
  mg_put helper done; migrate_update_hook 2>/dev/null >&2
  [ ! -L "$INST" ]; [ -n "$(_get leftovers_removed)" ]
}
test_the_previous_build_images_carry_over_under_the_new_name_and_come_back_on_rollback() {
  _mg_env; printf '%s/portal:previous\n' "$OLDP" >> "$DK/images"; _mg_pg_setup; _mg_run 2>/dev/null
  grep -qx "$NEWP/portal:previous" "$DK/images"; printf 'd1 %s postgres\n' "$NEWP" >> "$DK/containers"; migrate_update_finish 2>/dev/null
  ! grep -q "^$OLDP/" "$DK/images"                                                               # the old tags went
  migrate_rollback 2>/dev/null
  grep -qx "$OLDP/portal:previous" "$DK/images"; grep -qx "$NEWP/portal:previous" "$DK/images"   # the same image, named for the old code again
}
test_a_stack_rollback_of_a_half_finished_move_undoes_it_after_the_env_step_and_only_then() {
  _mg_env; : > "$DK/corrupt"; _mg_try; [ "$MGRC" != 0 ]; mg_init                              # failed at copy: env step not done
  ( migrate_rollback_first ) > "$TMP/out" 2>&1; assert_eq "$(cat "$TMP/out")" ""             # nothing to undo yet: the code rollback goes on
  _mg_env; mg_init; for s in preflight record stop copy inner host env; do mg_step_done "$s"; done; mg_put status failed; mg_put failed_step images
  printf '#!/bin/sh\ntouch %s/ran\n' "$TMP" > "$INST/stack"; chmod +x "$INST/stack"
  ( migrate_rollback_first ) > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_contains "$(cat "$TMP/out")" "undoing that first"; assert_eq "$(_st)" rolled-back
}
test_the_checks_name_the_symlink_targets_and_the_runtime_that_stopped() {
  assert_contains "$MG_SUM_SH" '%p %m %U %G %y %l'
  _mg_moved_and_verified
  mg_init; mg_put rt.lmstudio running; rt_state() { echo stopped; }
  mg_put old_copy ''; mg_put verified ''; mg_put status complete
  ( mg_verify_cutover ) > /dev/null 2>&1 && return 1
  mg_verify_cutover || true; assert_contains "$MG_VERIFY_WHY" "was running before the update and is not running after it"
  rt_state() { echo running; }; mg_verify_cutover || { echo "WHY: $MG_VERIFY_WHY" >&2; return 1; }
}
test_files_the_rewrite_cannot_read_that_still_name_the_old_folder_are_listed_and_a_sqlite_file_is_rewritten() {
  _mg_env
  head -c 3000000 /dev/zero | tr '\0' 'a' > "$INST/.state/big.log"; printf '%s/x\n' "$INST" >> "$INST/.state/big.log"
  printf 'bin\000\001%s/y\000' "$INST" > "$INST/.state/blob.dat"
  mkdir -p "$INST/.state/code"
  python3 -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table s(id integer, cwd text)"); c.execute("insert into s values (1, ?)", (sys.argv[2]+"/work",)); c.execute("insert into s values (2, ?)", (sys.argv[2]+"-other/work",)); c.commit()' "$INST/.state/code/sessions.db" "$INST"
  _mg_run > "$TMP/out" 2>&1
  assert_contains "$(cat "$TMP/out")" "too big, binary or not rewritable"; assert_eq "$(_get paths_left_behind)" 2
  grep -q "big.log" "$NEW/.state/migrate/paths-left-behind.txt" && grep -q "blob.dat" "$NEW/.state/migrate/paths-left-behind.txt"
  assert_eq "$(python3 -I -c 'import sqlite3,sys; print(";".join(r[0] for r in sqlite3.connect(sys.argv[1]).execute("select cwd from s order by id")))' "$NEW/.state/code/sessions.db")" "$NEW/work;$INST-other/work"
}

test_an_mlx_venv_keeps_working_after_the_move_and_the_link_is_gone() {
  _mg_env
  local v="$INST/.state/mlx/venv"
  mkdir -p "$v/bin" "$v/lib/python3.12/site-packages" "$INST/.state/mlx/hf/hub/models--a--b/blobs"
  printf 'home = /opt/py/bin\nuv = 0.9\nprompt = %s/.state/mlx/venv\n' "$INST" > "$v/pyvenv.cfg"
  printf '#!%s/.state/mlx/venv/bin/python\nprint(1)\n' "$INST" > "$v/bin/mlx_lm.server"; chmod +x "$v/bin/mlx_lm.server"
  printf '#!/bin/sh\nexit 0\n' > "$v/bin/python-real"; chmod +x "$v/bin/python-real"; ln -s "$INST/.state/mlx/venv/bin/python-real" "$v/bin/python"
  printf '%s/src\n' "$INST" > "$v/lib/python3.12/site-packages/x.pth"
  head -c 100 /dev/urandom > "$INST/.state/mlx/hf/hub/models--a--b/blobs/w.safetensors"; printf '%s/' "$INST" >> "$INST/.state/mlx/hf/hub/models--a--b/blobs/w.safetensors"
  local lbl; lbl="dev.devos.ade.mlx.$(mg_sum "$INST/.state")"
  printf '<plist><string>%s</string><string>%s/.state/mlx/venv/bin/mlx_lm.server</string><string>%s/.state/mlx/hf</string></plist>\n' "$lbl" "$INST" "$INST" > "$HOME/Library/LaunchAgents/$lbl.plist"
  _mg_run > "$TMP/out" 2>&1; assert_eq "$(_st)" moved
  rm -f "$INST"                                                                   # the next update removes the link
  head -n 1 "$NEW/.state/mlx/venv/bin/mlx_lm.server" | grep -qx "#!$NEW/.state/mlx/venv/bin/python"
  grep -q "$NEW/.state/mlx/venv" "$NEW/.state/mlx/venv/pyvenv.cfg"; grep -q "^$NEW/src$" "$NEW/.state/mlx/venv/lib/python3.12/site-packages/x.pth"
  assert_eq "$(readlink "$NEW/.state/mlx/venv/bin/python")" "$NEW/.state/mlx/venv/bin/python-real"
  local nl; nl="$(mg_get "lc.$lbl")"; [ -n "$nl" ] || nl="$(grep "^lc\.$lbl=" "$NEW/.state/migrate/marker" | cut -d= -f2)"
  grep -q "$NEW/.state/mlx/venv/bin/mlx_lm.server" "$HOME/Library/LaunchAgents/$nl.plist"; grep -q "$NEW/.state/mlx/hf" "$HOME/Library/LaunchAgents/$nl.plist"
  ! grep -q "$INST" "$HOME/Library/LaunchAgents/$nl.plist"
  # models are not read by the left-behind scan
  assert_eq "$(_get paths_left_behind)" 0
  # the check runs the venv's python with the import: it ran before the move, so one that fails now keeps the old copy
  assert_eq "$(_get rtok.mlx)" 1
  printf '#!/bin/sh\nexit 3\n' > "$NEW/.state/mlx/venv/bin/python-real"
  mg_init; MG_DIR="$NEW"; MG_VERIFY_WHY=''; ! mg_check_runtimes 2>/dev/null
  assert_contains "$MG_VERIFY_WHY" "cannot import mlx_lm"
  printf '#!/bin/sh\nexit 0\n' > "$NEW/.state/mlx/venv/bin/python-real"; mg_check_runtimes
  # one that did not run before the move either is said, not a reason to keep it
  printf '#!/bin/sh\nexit 3\n' > "$NEW/.state/mlx/venv/bin/python-real"; mg_put rtok.mlx 0
  MG_VERIFY_NOTE=''; mg_check_runtimes 2>/dev/null; assert_contains "$MG_VERIFY_NOTE" "it did not run before the update either"
}
test_a_runtime_that_did_not_run_before_the_move_is_said_and_never_keeps_the_old_copy() {
  # (an LM Studio install left half done before the update: its record names a program that was never there)
  _mg_env; _mg_pg_setup
  rm -f "$INST/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster"
  _mg_run 2>/dev/null; printf 'd1 %s postgres\n' "$NEWP" >> "$DK/containers"
  assert_eq "$(_get rtok.lmstudio)" 0
  migrate_update_finish > "$TMP/out" 2>&1
  assert_eq "$(_get old_copy)" removed
  assert_contains "$(cat "$TMP/out")" "runtime lmstudio: its program $NEW/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster is not there or cannot run — it did not run before the update either"
}
test_a_runtime_that_ran_before_the_move_is_recorded_and_must_run_after_it() {
  _mg_env; _mg_pg_setup; _mg_run 2>/dev/null
  assert_eq "$(_get rtok.lmstudio)" 1
}
test_a_marker_that_does_not_say_whether_a_runtime_ran_before_keeps_the_old_copy_when_it_fails() {
  # (a move started by an earlier build of the migrator has no rtok.ID: a runtime that fails after it is counted)
  _mg_env; _mg_pg_setup; _mg_run 2>/dev/null; printf 'd1 %s postgres\n' "$NEWP" >> "$DK/containers"
  grep -v '^rtok\.' "$NEW/.state/migrate/marker" > "$TMP/m"; cat "$TMP/m" > "$NEW/.state/migrate/marker"
  rm -f "$NEW/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster"
  migrate_update_finish > "$TMP/out" 2>&1
  assert_contains "$(cat "$TMP/out")" "KEPT"; assert_contains "$(cat "$TMP/out")" "runtime lmstudio"
  assert_eq "$(_get old_copy)" kept
}
test_a_runtime_whose_program_cannot_be_found_is_said_not_counted_as_checked() {
  _mg_moved_and_verified; mkdir -p "$NEW/.state/runtimes/llamacpp"; echo x > "$NEW/.state/runtimes/llamacpp/note"
  mg_init; MG_VERIFY_NOTE=''; mg_check_runtimes 2> "$TMP/err" || true; assert_contains "$(cat "$TMP/err")" "runtime llamacpp: its program was not found, so it was not checked"
}
test_sqlite_rewrite_has_a_left_boundary_handles_json_and_wal_and_reports_failures_by_name() {
  _mg_env
  python3 -I -c 'import sqlite3,sys; o=sys.argv[2]; c=sqlite3.connect(sys.argv[1]); c.execute("create table s(cwd text)")
for v in (o+"/w", "x"+o+"/w", "{\"p\":\""+o+"\"}", "a="+o+"/z", "/other"+o+"/q", o+"-two/w"): c.execute("insert into s values (?)", (v,))
c.commit()' "$INST/.state/a.db" "$INST"
  # a damaged sqlite file: its header (with the NUL every sqlite file has, so no text rewrite reads it), then the old path
  printf 'SQLite format 3\000%s/' "$INST" > "$INST/.state/bad.db"; head -c 20 /dev/urandom >> "$INST/.state/bad.db"
  _mg_run > "$TMP/out" 2>&1
  assert_contains "$(cat "$TMP/out")" "NOT rewritten"; assert_contains "$(cat "$TMP/out")" "bad.db"
  assert_eq "$(python3 -I -c 'import sqlite3,sys; print("|".join(r[0] for r in sqlite3.connect(sys.argv[1]).execute("select cwd from s order by rowid")))' "$NEW/.state/a.db")" "$NEW/w|x$INST/w|{\"p\":\"$NEW\"}|a=$NEW/z|/other$INST/q|$INST-two/w"
}

# --- the command and the hosts ---
test_the_status_says_what_is_going_on_in_each_state() {
  _mg_env; assert_contains "$(migrate_status)" "not moved yet"
  rm -rf "$DK/vol/${OLDP}_"*; assert_contains "$(migrate_status)" "nothing to move"
  _mg_env; : > "$DK/corrupt"; _mg_try; [ "$MGRC" != 0 ]; rm -f "$DK/corrupt"; mg_init; assert_contains "$(migrate_status)" "stopped at: copy"
  assert_contains "$(migrate_usage)" "--rollback"; assert_contains "$(migrate_usage)" "--remove-old"
  ( cmd_migrate --nonsense ) > "$TMP/out" 2>&1 && return 1; assert_contains "$(cat "$TMP/out")" "usage: ./stack migrate"
}
test_the_old_hostname_answers_with_a_308_for_every_method_refuses_sockets_and_sets_no_cookie() {
  local f; f="$(cat "$STACK_DIR/caddy/legacy-on.caddy")"
  assert_contains "$f" "http://bedrock-now.localhost {"; assert_contains "$f" "http://*.bedrock-now.localhost {"
  assert_contains "$f" "http://bedrock-now-preview.localhost {"; assert_contains "$f" "http://*.bedrock-now-preview.localhost {"
  assert_contains "$f" "redir http://{\$PREVIEW_DOMAIN:preview.invalid}:{\$PORTAL_PORT:80}{uri} 308"      # the apex has no subdomain label
  assert_eq "$(grep -c 'redir .* 308$' "$STACK_DIR/caddy/legacy-on.caddy")" 4
  assert_contains "$f" "{http.request.host.labels.2}.{\$PORTAL_HOST}:{\$PORTAL_PORT:80}{uri} 308"   # path and query kept
  assert_contains "$f" "header -Set-Cookie"; assert_contains "$f" "(?i)^websocket\$"; assert_contains "$f" " 426"
  assert_not_contains "$f" "reverse_proxy"; assert_not_contains "$f" "header_up"
  assert_eq "$(grep -c '^import legacy-{\$LEGACY_HOSTS:off}.caddy$' "$STACK_DIR/caddy/Caddyfile")" 1
  ! grep -qE '^[[:space:]]*(@[a-z_]+ )?method ' "$STACK_DIR/caddy/legacy-on.caddy"   # no method matcher: GET, HEAD, POST, PUT, DELETE alike
}
