# shellcheck shell=bash
# lib/prepare.sh (JON-972 phase B): the next release prepared ahead of Update now. A real git origin (local), a stubbed Docker
# (a shell function that keeps the images in a file and logs every call with the Compose project it was given), a stubbed lock
# holder; nothing touches a real Docker, launchd or the network.
. "$STACK_DIR/lib/commands.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

DIG_OLD=sha256:1111111111111111111111111111111111111111111111111111111111111111
DIG_NEW=sha256:2222222222222222222222222222222222222222222222222222222222222222

# _pw — origin with v0.3.0 and v0.4.0 (v0.4.0 pins a newer litellm); this checkout detached at v0.3.0 (as install.sh leaves it),
# the stack "running": <project>/portal:local and the old litellm are images here. The Docker stub:
#   $IMGS   "REF ID" per image;   $DLOG   every call: "<COMPOSE_PROJECT_NAME> docker ARGS"
_pw() {
  local o="$TMP/origin"
  mkdir -p "$o"
  git init -q "$o"
  printf '#!/bin/sh\necho "stack $*"\nexit "${FAKE_STACK_RC:-0}"\n' > "$o/stack"; chmod +x "$o/stack"
  mkdir -p "$o/portal" "$o/shared-mcp" "$o/open-webui"
  for s in portal shared-mcp open-webui; do echo "FROM scratch" > "$o/$s/Dockerfile"; done
  _compose "$DIG_OLD" > "$o/compose.yaml"
  git -C "$o" add . ; git -C "$o" commit -qm one; git -C "$o" tag v0.3.0
  _compose "$DIG_NEW" > "$o/compose.yaml"; git -C "$o" commit -qam two; git -C "$o" tag v0.4.0
  git clone -q "$o" "$TMP/stack"; STACK_DIR="$TMP/stack"
  git -C "$STACK_DIR" -c advice.detachedHead=false checkout -q v0.3.0
  printf 'POSTGRES_PASSWORD=p\nCOMPOSE_PROJECT_NAME=bn-t\nLITELLM_MASTER_KEY=sk-secret\n' > "$ENV_FILE"
  mkdir -p "$STATE_DIR/images" "$(helper_dir)" "$(update_check_dir)" "$STATE_DIR/status"
  export STATE_DIR HELPER_JOB_POLL_S=0 PREPARE_WATCH_S=0.05
  IMGS="$TMP/imgs"; DLOG="$TMP/dlog"; HOLDER="$TMP/holder"; : > "$DLOG"
  printf 'bn-t/portal:local OLDPORTAL\nghcr.io/berriai/litellm:1.0@%s OLDLITELLM\n' "$DIG_OLD" > "$IMGS"
  _seen v0.4.0
  prepare_load() { echo 0.5; }; prepare_cpus() { echo 4; }; prepare_free_mb() { echo 50000; }
  stack_lock_holder() { cat "$HOLDER" 2>/dev/null || true; }
  docker() {
    printf '%s docker %s\n' "${COMPOSE_PROJECT_NAME:-}" "$*" >> "$DLOG"
    case "$1" in
      info) return 0 ;;
      compose)
        case " $* " in
          *" config --images "*)   # the images the compose file in --project-directory names, as Compose prints them
            local dir='' a prev=''
            for a in "$@"; do [ "$prev" != --project-directory ] || dir="$a"; prev="$a"; done
            sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$dir/compose.yaml" | sed "s|\${COMPOSE_PROJECT_NAME:-devos-ade}|${COMPOSE_PROJECT_NAME:-devos-ade}|" ;;
          *" build "*)
            local svc="${*: -1}"
            [ ! -f "$TMP/build-sleeps" ] || { echo "1 update" > "$HOLDER"; sleep 10; }
            [ ! -f "$TMP/build-fails" ] || { echo "ERROR: failed to solve: boom" >&2; return 1; }
            printf '%s/%s:local NEW%s\n' "${COMPOSE_PROJECT_NAME:-devos-ade}" "$svc" "$svc" >> "$IMGS"; echo "sha256:NEW$svc" ;;
        esac ;;
      image)
        case "$2" in
          inspect)
            local fmt='' r id miss=0; shift 2
            [ "$1" != --format ] || { fmt="$2"; shift 2; }
            for r in "$@"; do
              id="$(awk -v r="$r" '$1 == r { print $2 }' "$IMGS" | tail -n 1)"
              if [ -z "$id" ]; then echo "Error response from daemon: No such image: $r" >&2; miss=1; continue; fi
              case "$fmt" in '{{.Size}}') echo 1000000 ;; *) echo "$id" ;; esac
            done
            return "$miss" ;;
          rm) grep -vxF -- "$(awk -v r="$3" '$1 == r' "$IMGS")" "$IMGS" > "$IMGS.n" || true; mv "$IMGS.n" "$IMGS" ;;
        esac ;;
      pull) printf '%s PULLED%s\n' "$2" "$(printf '%s' "$2" | cksum | cut -d' ' -f1)" >> "$IMGS" ;;
      ps) [ ! -f "$TMP/ctr-image" ] || echo ctr1 ;;
      inspect) [ ! -f "$TMP/ctr-image" ] || cat "$TMP/ctr-image" ;;
      volume) return 0 ;;
    esac
    return 0
  }
}
_compose() {   # _compose DIGEST — a compose.yaml with a built image and a pinned one
  printf 'services:\n  portal:\n    build: { context: ./portal }\n    image: ${COMPOSE_PROJECT_NAME:-devos-ade}/portal:local\n'
  printf '  shared-mcp:\n    build: { context: ./shared-mcp }\n    image: ${COMPOSE_PROJECT_NAME:-devos-ade}/shared-mcp:local\n'
  printf '  open-webui:\n    build: { context: ./open-webui }\n    image: ${COMPOSE_PROJECT_NAME:-devos-ade}/open-webui:local\n'
  printf '  litellm:\n    image: ghcr.io/berriai/litellm:1.0@%s\n' "$1"
}
_seen() { printf 'latest=%s\nchecked_at=%s\n' "$1" "$(date +%s)" > "$(update_check_dir)/latest.txt"; }
_new_release() { echo "$1" > "$TMP/origin/x"; git -C "$TMP/origin" add x; git -C "$TMP/origin" commit -qm "$1"; git -C "$TMP/origin" tag "$1"; _seen "$1"; }
_pstate() { _prep_read; echo "$PS_state"; }
_head() { git -C "$STACK_DIR" rev-parse HEAD; }

# --- the decision ---

test_decision_table() {
  d() { prepare_decision "$@"; }
  assert_eq "$(d off v0.4.0 v0.3.0 '' '' '' '' 0 100 '' 0)" "off"
  assert_eq "$(d on v0.4.0 v0.3.0 main '' '' '' 0 100 '' 0)" "branch"
  assert_eq "$(d on v0.4.0 v0.3.0-2-gabc '' '' '' '' 0 100 '' 0)" "not-release"
  assert_eq "$(d on '' v0.3.0 '' '' '' '' 0 100 '' 0)" "none"                         # no check, or nothing newer
  assert_eq "$(d on v0.3.0 v0.3.0 '' '' '' '' 0 100 '' 0)" "none"
  assert_eq "$(d on v0.4.0 v0.3.0 '' v0.4.0 '' '' 0 100 '' 0)" "rolled-back v0.4.0"   # you went back from it
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' ready v0.4.0 50 100 '' 0)" "ready v0.4.0"     # already prepared: not again
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' ready v0.4.0 50 100 'busy' 1)" "ready v0.4.0"
  assert_eq "$(d on v0.5.0 v0.3.0 '' '' ready v0.4.0 50 100 '' 0)" "run v0.5.0"       # superseded: the newer one is prepared
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' failed v0.4.0 50 100 '' 0)" "failed v0.4.0"   # failed just now: not again at once
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' failed v0.4.0 50 4000 '' 0)" "run v0.4.0"     # an hour later: again
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' failed v0.3.9 50 100 '' 0)" "run v0.4.0"      # (another release's failure)
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' '' '' 0 100 './stack update is running' 0)" "busy v0.4.0"   # the stack lock held
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' '' '' 0 100 '' 1)" "load v0.4.0"              # the computer is busy
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' yielded v0.4.0 50 100 '' 0)" "run v0.4.0"     # stopped before: goes on
  assert_eq "$(d on v0.4.0 v0.3.0 '' '' '' '' 0 100 '' 0)" "run v0.4.0"
}

test_stale_records_are_turned_off_applied_or_superseded() {
  prepare_stale off v0.3.0 v0.4.0 v0.4.0                 # preparing turned off
  prepare_stale on v0.4.0 v0.4.0 v0.4.0                  # installed: applied
  prepare_stale on v0.4.0 v0.5.0 v0.5.0 && return 1      # (the installed one is older: still wanted)
  prepare_stale on v0.3.0 v0.5.0 v0.4.0                  # a newer release is named: superseded
  ! prepare_stale on v0.3.0 v0.4.0 v0.4.0                # current
  ! prepare_stale on v0.3.0 '' v0.4.0                    # (no check result: kept)
  ! prepare_stale on v0.3.0 v0.4.0 ''                    # (no record)
}

test_the_load_is_compared_with_the_cpu_count() {
  prepare_load() { echo 7.9; }; prepare_cpus() { echo 4; }
  _prep_load_high 2 && return 1                           # 7.9 <= 4 x 2
  prepare_load() { echo 8.1; }
  _prep_load_high 2
  prepare_load() { echo 30; }; prepare_cpus() { echo 12; }
  _prep_load_high 2                                       # 30 > 12 x 2
  _prep_load_high 3 && return 1; true
}

# --- the run ---

test_prepare_builds_under_its_own_name_and_touches_nothing_the_stack_uses() {
  _pw
  head0="$(_head)"; env0="$(cksum < "$ENV_FILE")"; before="$(cat "$IMGS")"
  out="$(prepare_run v0.4.0 2>&1)"
  _prep_read; assert_eq "$PS_state" "ready"
  assert_eq "$PS_version" "v0.4.0"; assert_eq "$PS_commit" "$(git -C "$STACK_DIR" rev-parse v0.4.0)"
  # the builds carry the project bn-t-prep, one at a time, and the downloads are digest-pinned
  assert_contains "$(cat "$STATE_DIR/update/prepare/images.tsv")" "bn-t-prep/portal:local"
  assert_contains "$(cat "$STATE_DIR/update/prepare/images.tsv")" "bn-t-prep/open-webui:local"
  assert_contains "$(cat "$STATE_DIR/update/prepare/pulled.tsv")" "ghcr.io/berriai/litellm:1.0@$DIG_NEW"
  # every Compose call: the prep project, from the unpacked copy; no tag, no removal, no container, no up
  ! grep -E '^bn-t docker compose' "$DLOG" || { echo "a compose call under the stack's own project:" >&2; grep -E '^bn-t docker compose' "$DLOG" >&2; return 1; }
  ! grep -E 'docker (tag|rmi|image rm|image tag)| (up|down|start|stop|restart|rm|run|exec) ' "$DLOG" || { cat "$DLOG" >&2; return 1; }
  assert_eq "$(grep -c ' build ' "$DLOG")" "3"
  grep 'docker compose' "$DLOG" | grep -q -- "-p bn-t-prep " || return 1
  grep 'docker compose' "$DLOG" | grep -q -- "--project-directory $STATE_DIR/update/prepare/src" || return 1
  # what the stack uses is as it was: the :local image, the old pin; .env, HEAD, the tree, no update record, no lock
  assert_eq "$(awk '$1 == "bn-t/portal:local"' "$IMGS")" "bn-t/portal:local OLDPORTAL"
  assert_eq "$(grep -v 'bn-t-prep\|PULLED' "$IMGS")" "$before"
  assert_eq "$(_head)" "$head0"; assert_eq "$(cksum < "$ENV_FILE")" "$env0"
  assert_eq "$(git -C "$STACK_DIR" status --porcelain)" ""
  [ ! -e "$(update_record_file)" ] || return 1
  [ ! -e "$STATE_DIR/lock" ] || return 1
  # the copy and the private .env are gone; the private .env never held the stack's project
  [ ! -e "$STATE_DIR/update/prepare/src" ] && [ ! -e "$STATE_DIR/update/prepare/env" ] || return 1
  # the steps are the log's lines, in the form Home reads
  assert_contains "$out" "==> Prepare: fetch v0.4.0: starting…"
  assert_contains "$out" "==> Prepare: build portal ready ("
  assert_contains "$out" "==> Prepare: download litellm:1.0 ready ("
}

test_a_prepared_release_is_not_prepared_again() {
  _pw
  prepare_run v0.4.0 > /dev/null 2>&1
  : > "$DLOG"
  out="$(prepare_run v0.4.0 2>&1)"
  assert_contains "$out" "prepared already"
  ! grep -q ' build \| pull ' "$DLOG" || return 1
  # ... unless a build it made is gone (pruned): then it is prepared again
  grep -v 'bn-t-prep/portal' "$IMGS" > "$IMGS.n"; mv "$IMGS.n" "$IMGS"
  : > "$DLOG"; prepare_run v0.4.0 > /dev/null 2>&1
  grep -q ' build ' "$DLOG"
  _prep_read; assert_eq "$PS_state" "ready"
}

test_a_stack_command_taking_the_lock_ends_the_prepare_and_it_goes_on_later() {
  _pw
  : > "$TMP/build-sleeps"
  s=$SECONDS; rc=0; out="$(prepare_run v0.4.0 2>&1)" || rc=$?
  assert_eq "$rc" "2"; [ $((SECONDS - s)) -lt 8 ] || { echo "the build was not ended" >&2; return 1; }
  _prep_read
  _prep_read; assert_eq "$PS_state" "yielded"
  assert_contains "$PS_reason" "./stack update started"
  [ ! -e "$STATE_DIR/update/prepare/src" ] || return 1
  assert_eq "$(awk '$1 == "bn-t/portal:local"' "$IMGS")" "bn-t/portal:local OLDPORTAL"
  # the lock is free again: the same release goes on and is ready
  rm -f "$TMP/build-sleeps" "$HOLDER"; : > "$DLOG"
  prepare_run v0.4.0 > /dev/null 2>&1
  _prep_read; assert_eq "$PS_state" "ready"
}

test_a_failed_build_is_said_plainly_and_leaves_the_stack_alone() {
  _pw
  : > "$TMP/build-fails"
  rc=0; prepare_run v0.4.0 > /dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1"; _prep_read; assert_eq "$PS_state" "failed"
  assert_contains "$PS_reason" "Prepare: build portal failed"
  assert_contains "$PS_reason" "boom"
  assert_eq "$(awk '$1 == "bn-t/portal:local"' "$IMGS")" "bn-t/portal:local OLDPORTAL"
}

test_the_release_is_checked_the_way_update_checks_it() {
  _pw
  # a signed tag is required: the lightweight tag is not one, nothing is built
  printf 'UPDATE_REQUIRE_SIGNED_TAGS=true\n' >> "$ENV_FILE"
  rc=0; prepare_run v0.4.0 > /dev/null 2>&1 || rc=$?
  _prep_read; assert_eq "$rc" "1"; assert_contains "$PS_reason" "UPDATE_REQUIRE_SIGNED_TAGS=true"
  ! grep -q ' build ' "$DLOG" || return 1
  sed -i.bak '/UPDATE_REQUIRE_SIGNED_TAGS/d' "$ENV_FILE"
  # origin's newest release is not the one the check named: the newest is what update installs, so that is prepared
  _new_release v0.4.1
  prepare_run v0.4.0 > /dev/null 2>&1
  _prep_read; assert_eq "$PS_version" "v0.4.1"; _prep_read; assert_eq "$PS_state" "ready"
  # a checkout ahead of the newest tag is refused (update --to decides), origin gone is said
  git -C "$STACK_DIR" -c advice.detachedHead=false checkout -q v0.4.1; echo x > "$STACK_DIR/y"; git -C "$STACK_DIR" add y; git -C "$STACK_DIR" commit -qm ahead
  prepare_cleanup abandoned
  rc=0; prepare_run v0.4.1 > /dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1"
}

test_an_origin_that_cannot_be_reached_is_a_failure_with_its_reason() {
  _pw
  git -C "$STACK_DIR" remote set-url origin "$TMP/nowhere"
  rc=0; prepare_run v0.4.0 > /dev/null 2>&1 || rc=$?
  _prep_read; assert_eq "$rc" "1"; assert_contains "$PS_reason" "could not fetch from origin"
  ! grep -q ' build ' "$DLOG" || return 1
}

test_too_little_disk_or_too_many_images_stop_it() {
  _pw
  prepare_free_mb() { echo 100; }
  rc=0; prepare_run v0.4.0 > /dev/null 2>&1 || rc=$?
  _prep_read; assert_eq "$rc" "1"; assert_contains "$PS_reason" "only 100 MB of disk is free"
  ! grep -q ' build ' "$DLOG" || return 1
  prepare_free_mb() { echo 50000; }
  PREPARE_MAX_MB=0 prepare_run v0.4.0 > /dev/null 2>&1 || true
  # (each stubbed image is 1 MB: a cap of 0 MB ends the run after the first build)
  _prep_read; assert_eq "$PS_state" "failed"; assert_contains "$PS_reason" "PREPARE_MAX_MB"
}

test_a_tag_that_is_not_pinned_is_never_pulled() {
  _pw
  printf '  other:\n    image: example.com/x:latest\n' >> "$TMP/origin/compose.yaml"
  git -C "$TMP/origin" commit -qam third; git -C "$TMP/origin" tag v0.4.1; _seen v0.4.1
  prepare_run v0.4.1 > "$TMP/out" 2>&1
  assert_contains "$(cat "$TMP/out")" "example.com/x:latest is not pinned by a digest: left for the update"
  ! grep -q 'docker pull example.com' "$DLOG" || return 1
  grep -q "docker pull ghcr.io/berriai/litellm:1.0@$DIG_NEW" "$DLOG" || return 1
}

test_the_terminal_and_the_code_page_images_are_built_under_the_same_name() {
  _pw
  terminal_on() { return 0; }; terminal_why_out() { :; }; terminal_egress_build_service() { echo terminal-egress; }; code_ready() { return 0; }
  PREP_SRC="$TMP/stack"; PREP_ENV="$ENV_FILE"
  assert_eq "$(_prep_ctx _prep_services | tr '\n' ' ')" "portal shared-mcp open-webui terminal terminal-egress code "
  terminal_build_args() { TERMINAL_BUILD_ARGS=(--build-arg APT_REFRESH=2026-44); }
  : > "$DLOG"
  prepare_run v0.4.0 > /dev/null 2>&1
  _prep_read; assert_eq "$PS_state" "ready"
  grep -q 'docker compose.* build -q --build-arg APT_REFRESH=2026-44 terminal$' "$DLOG" || { cat "$DLOG" >&2; return 1; }
  grep ' build ' "$DLOG" | grep -vq '^bn-t-prep ' && return 1
  assert_contains "$(cat "$STATE_DIR/update/prepare/images.tsv")" "bn-t-prep/code:local"
  assert_eq "$(awk '$1 == "bn-t/code:local" || $1 == "bn-t/terminal:local"' "$IMGS")" ""
}

# --- the helper's tick ---

_tick() { prepare_tick > "$TMP/tick.out" 2>&1; }

test_tick_prepares_a_newer_release_once() {
  _pw
  _tick
  _prep_read; assert_eq "$PS_state" "ready"
  assert_contains "$(cat "$(prepare_log_file)")" "==> Prepare: build portal ready ("
  : > "$DLOG"; _tick
  ! grep -q ' build \| pull \| fetch' "$DLOG" || return 1     # once per release
}

test_tick_waits_while_a_stack_command_holds_the_lock_and_while_the_computer_is_busy() {
  _pw
  echo "4242 update" > "$HOLDER"; _tick
  [ ! -f "$(prepare_state_file)" ] || return 1; ! grep -q ' build ' "$DLOG" || return 1
  rm -f "$HOLDER"; prepare_load() { echo 30; }; _tick                          # load 30 on 4 CPUs
  [ ! -f "$(prepare_state_file)" ] || return 1; ! grep -q ' build ' "$DLOG" || return 1
  prepare_load() { echo 3; }; _tick
  _prep_read; assert_eq "$PS_state" "ready"
}

test_tick_does_nothing_when_turned_off_and_removes_what_it_made() {
  _pw
  _tick; _prep_read; assert_eq "$PS_state" "ready"
  printf 'UPDATE_PREPARE=false\n' >> "$ENV_FILE"; : > "$DLOG"
  _tick
  [ ! -f "$(prepare_state_file)" ] || return 1
  grep -q 'docker image rm bn-t-prep/portal:local' "$DLOG" || return 1
  ! grep -q ' build ' "$DLOG" || return 1
  assert_eq "$(awk '$1 == "bn-t/portal:local"' "$IMGS")" "bn-t/portal:local OLDPORTAL"
  # its download goes too: nothing uses it
  ! grep -q "litellm:1.0@$DIG_NEW" "$IMGS" || return 1
  grep -q "litellm:1.0@$DIG_OLD" "$IMGS" || return 1                            # the running version's stays
}

test_tick_skips_a_branch_checkout_and_a_release_you_rolled_back() {
  _pw
  git -C "$STACK_DIR" checkout -q -B work v0.3.0; _tick
  [ ! -f "$(prepare_state_file)" ] || return 1
  git -C "$STACK_DIR" -c advice.detachedHead=false checkout -q v0.3.0
  mkdir -p "$STATE_DIR/update"; printf 'result=rolled-back\nto_version=v0.4.0\n' > "$(update_record_file)"; _tick
  [ ! -f "$(prepare_state_file)" ] || return 1
}

test_tick_replaces_what_a_newer_release_supersedes() {
  _pw
  _tick; _prep_read; assert_eq "$PS_state" "ready"; assert_eq "$PS_version" "v0.4.0"
  _new_release v0.5.0; : > "$DLOG"
  _tick
  _prep_read; assert_eq "$PS_state" "ready"; assert_eq "$PS_version" "v0.5.0"
  grep -q 'docker image rm bn-t-prep/portal:local' "$DLOG" || return 1           # v0.4.0's builds went first
  assert_eq "$(grep -c 'bn-t-prep/portal:local' "$IMGS")" "1"
  assert_eq "$(awk '$1 == "bn-t/portal:local"' "$IMGS")" "bn-t/portal:local OLDPORTAL"
}

test_tick_drops_a_prepared_release_that_is_installed_now() {
  _pw
  _tick; git -C "$STACK_DIR" -c advice.detachedHead=false checkout -q v0.4.0; : > "$DLOG"
  _tick
  [ ! -f "$(prepare_state_file)" ] || return 1
  # installed: its downloads are the installed version's, kept
  grep -q "litellm:1.0@$DIG_NEW" "$IMGS" || return 1
  assert_eq "$(awk '$1 == "bn-t/portal:local"' "$IMGS")" "bn-t/portal:local OLDPORTAL"
}

# --- the apply ---

test_update_says_when_the_release_was_prepared_ahead_and_then_cleans_up() {
  _pw
  prepare_run v0.4.0 > /dev/null 2>&1
  assert_eq "$(prepare_apply_note 2>&1)" ""                                       # (HEAD is still v0.3.0: not that release)
  git -C "$STACK_DIR" -c advice.detachedHead=false checkout -q v0.4.0            # ./stack update's checkout
  assert_contains "$(prepare_apply_note 2>&1)" "prepared ahead"
  # the downloads are done: ./stack update's own pull list skips them (pinned by digest, here already)
  pull_needed "ghcr.io/berriai/litellm:1.0@$DIG_NEW" && return 1
  # a build of <project>/…:local happens at update; then the update's end removes the prep names, not the downloads
  printf 'bn-t/portal:local NEWPORTAL\n' >> "$IMGS"; : > "$DLOG"
  prepare_after_update
  [ ! -f "$(prepare_state_file)" ] || return 1
  grep -q 'docker image rm bn-t-prep/portal:local' "$DLOG" || return 1
  ! grep -q 'docker image rm bn-t/' "$DLOG" || return 1
  ! grep -q 'docker image rm ghcr' "$DLOG" || return 1
  grep -q "litellm:1.0@$DIG_NEW" "$IMGS" || return 1
}

test_an_update_leaves_a_newer_prepared_release_alone() {
  _pw
  _new_release v0.5.0
  prepare_run v0.5.0 > /dev/null 2>&1
  git -C "$STACK_DIR" -c advice.detachedHead=false checkout -q v0.4.0; : > "$DLOG"
  prepare_after_update
  _prep_read; assert_eq "$PS_state" "ready"; ! grep -q 'image rm' "$DLOG" || return 1
}

test_cleanup_never_removes_a_name_outside_the_prep_project_or_an_image_in_use() {
  _pw
  prepare_run v0.4.0 > /dev/null 2>&1
  # a record that was tampered with names the stack's own images: they are not touched
  printf 'OLDPORTAL\tbn-t/portal:local\nX\tbn-t/portal:previous\nY\tbn-t-prep/portal:local\n' > "$STATE_DIR/update/prepare/images.tsv"
  # a container runs the downloaded image: it stays
  printf '%s\n' "PULLED$(printf '%s' "ghcr.io/berriai/litellm:1.0@$DIG_NEW" | cksum | cut -d' ' -f1)" > "$TMP/ctr-image"
  : > "$DLOG"
  prepare_cleanup superseded
  ! grep -q 'image rm bn-t/' "$DLOG" || { cat "$DLOG" >&2; return 1; }
  grep -q 'image rm bn-t-prep/portal:local' "$DLOG" || return 1
  ! grep -q "image rm ghcr.io/berriai/litellm:1.0@$DIG_NEW" "$DLOG" || return 1
  assert_eq "$(awk '$1 == "bn-t/portal:local"' "$IMGS")" "bn-t/portal:local OLDPORTAL"
}

# --- Update now ---

test_update_now_on_a_release_not_prepared_prepares_it_first_with_its_steps_in_the_log() {
  _pw
  log="$TMP/job.log"; rc=0
  _job_run update > "$log" 2>&1 || rc=$?
  assert_eq "$rc" "0"
  c="$(cat "$log")"
  assert_contains "$c" "==> Prepare: fetch v0.4.0: starting…"
  assert_contains "$c" "==> Prepare: build open-webui ready ("
  assert_contains "$c" "stack update --yes"
  case "$c" in *"Prepare: fetch"*"stack update --yes"*) ;; *) echo "the prepare did not come first" >&2; return 1 ;; esac
  # the card's steps are read from that log
  JOB_ID=job1; JOB_STEPS_ID=''; JOB_STEPS_SIZE=''; _job_steps "$log"
  assert_contains "$JOB_STEPS_JSON" '"label": "Prepare: build portal", "took": '
  assert_contains "$JOB_STEPS_JSON" '"label": "Prepare: download litellm:1.0"'
  _prep_read; assert_eq "$PS_state" "ready"
}

test_update_now_on_a_prepared_release_starts_at_once_and_a_failed_prepare_does_not_stop_it() {
  _pw
  prepare_run v0.4.0 > /dev/null 2>&1
  : > "$DLOG"
  out="$(_job_run update 2>&1)"
  assert_eq "$(printf '%s' "$out" | sed 's/^[0-9:]* //')" "stack update --yes"
  ! grep -q ' build \| pull ' "$DLOG" || return 1
  # not prepared and the build fails: said, and the update runs
  prepare_cleanup abandoned; : > "$TMP/build-fails"
  out="$(_job_run update 2>&1)"
  assert_contains "$out" "Preparing ahead did not finish; the update does that work itself."
  assert_contains "$out" "stack update --yes"
  _prep_read; assert_eq "$PS_state" "failed"
  # the update's own exit status is the job's
  FAKE_STACK_RC=3; export FAKE_STACK_RC
  rc=0; _job_run update > /dev/null 2>&1 || rc=$?
  assert_eq "$rc" "3"
}

test_update_now_prepares_nothing_for_other_jobs_a_branch_or_when_turned_off() {
  _pw
  out="$(_job_run rollback 2>&1)"; assert_eq "$(printf '%s' "$out" | sed 's/^[0-9:]* //')" "stack rollback --yes"
  printf 'UPDATE_PREPARE=off\n' >> "$ENV_FILE"
  out="$(_job_run update 2>&1)"; assert_eq "$(printf '%s' "$out" | sed 's/^[0-9:]* //')" "stack update --yes"
  sed -i.bak '/UPDATE_PREPARE/d' "$ENV_FILE"
  git -C "$STACK_DIR" checkout -q -B work v0.3.0
  out="$(_job_run update 2>&1)"; assert_eq "$(printf '%s' "$out" | sed 's/^[0-9:]* //')" "stack update --yes"
  ! grep -q ' build ' "$DLOG" || return 1
}

# --- the helper's loop, and what Home is told ---

test_stopping_a_background_prepare_marks_it_stopped() {
  _pw
  PREP_VERSION=v0.4.0; PREP_COMMIT=abc; _prep_state preparing "Prepare: build portal" ""
  sleep 30 & HELPER_PREP_PID=$!
  _prepare_running
  _prepare_stop
  _prep_read; assert_eq "$PS_state" "yielded"; [ -z "$HELPER_PREP_PID" ] || return 1
  ! kill -0 $! 2>/dev/null || { kill $!; return 1; }
}

test_a_run_the_record_says_is_going_on_is_not_after_the_helper_restarts() {
  _pw
  PREP_VERSION=v0.4.0; PREP_COMMIT=abc; _prep_state preparing "Prepare: download litellm:1.0" ""
  prepare_recover
  _prep_read; assert_eq "$PS_state" "yielded"
}

test_the_heartbeat_tells_home_what_is_prepared() {
  _pw
  helper_heartbeat
  assert_contains "$(cat "$(helper_beat_file)")" '"prepare": {"enabled": true, "state": "", "version": "", "step": "", "reason": "", "at": null}}'
  prepare_run v0.4.0 > /dev/null 2>&1
  helper_heartbeat
  assert_contains "$(cat "$(helper_beat_file)")" '"prepare": {"enabled": true, "state": "ready", "version": "v0.4.0", "step": "", "reason": "", "at": '
  printf 'UPDATE_PREPARE=false\n' >> "$ENV_FILE"; helper_heartbeat
  assert_contains "$(cat "$(helper_beat_file)")" '"prepare": {"enabled": false,'
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["prepare"]["state"] == "ready" and d["auto"]["on"] is False and "switch" in d["auto"]' "$(helper_beat_file)"
  fi
}

test_the_setting_is_in_the_catalog_and_on_by_default() {
  grep -q '^UPDATE_PREPARE	updates	-	edit	bool	' "$T_ROOT/catalog/settings.tsv"
  grep -q '^UPDATE_PREPARE	updates	more	' "$T_ROOT/catalog/settings-layout.tsv"
  grep -q '^UPDATE_PREPARE=true' "$T_ROOT/.env.example"
  _pw; prepare_enabled
  printf 'UPDATE_PREPARE=false\n' >> "$ENV_FILE"; prepare_enabled && return 1
  sed -i.bak 's/UPDATE_PREPARE=false/UPDATE_PREPARE=/' "$ENV_FILE"; prepare_enabled     # blank = on
}
