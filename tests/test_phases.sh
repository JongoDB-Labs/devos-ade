# shellcheck shell=bash
# Task A1: quiet, phased bring-up output (lib/commands.sh). Docker is stubbed.
. "$STACK_DIR/lib/commands.sh"

test_fmt_elapsed() {
  assert_eq "$(fmt_elapsed 0)" "0s"
  assert_eq "$(fmt_elapsed 16)" "16s"
  assert_eq "$(fmt_elapsed 59)" "59s"
  assert_eq "$(fmt_elapsed 60)" "1m00s"
  assert_eq "$(fmt_elapsed 125)" "2m05s"
}

test_phase_line() {
  assert_eq "$(phase_line LiteLLM 16)" "LiteLLM ready (16s)"
  assert_eq "$(phase_line "Open WebUI" 75)" "Open WebUI ready (1m15s)"
}

_noisy() { local i; for i in 1 2 3; do echo "compose noise $i"; done; echo "compose err" >&2; }

test_run_phase_quiet_by_default() {
  _now() { echo 100; }
  out="$(BEDROCK_NOW_VERBOSE=0 run_phase LiteLLM litellm _noisy 2>&1)"
  assert_contains "$out" "LiteLLM ready (0s)"
  assert_not_contains "$out" "compose noise"
  assert_not_contains "$out" "compose err"
}

# A helper job's log (Home's progress card reads it, lib/helper.sh _job_steps): each phase says when it starts, and
# setup's steps are named; a terminal or any other run prints neither
test_a_helper_jobs_log_names_each_phase_and_step_as_it_starts() {
  _now() { echo 100; }
  out="$(BEDROCK_NOW_JOB_ORIGIN=helper BEDROCK_NOW_VERBOSE=0 run_phase LiteLLM litellm _noisy 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '')" 2
  assert_eq "$(printf '%s\n' "$out" | head -n 1)" "==> LiteLLM: starting…"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "LiteLLM ready (0s)"
  assert_eq "$(BEDROCK_NOW_JOB_ORIGIN=helper setup_step "checking your AWS key" 2>&1)" "==> doing: checking your AWS key"
  assert_eq "$(BEDROCK_NOW_JOB_ORIGIN=helper phase_start Terminal 2>&1)" "==> Terminal: starting…"
  # not a helper job: nothing more than before
  out="$(BEDROCK_NOW_VERBOSE=0 run_phase LiteLLM litellm _noisy 2>&1)"
  assert_not_contains "$out" "starting"
  assert_eq "$(setup_step "checking your AWS key" 2>&1)" ""
  assert_eq "$(BEDROCK_NOW_JOB_ORIGIN=terminal phase_start Terminal 2>&1)" ""
  # (verbose: run_phase says it already, once)
  out="$(BEDROCK_NOW_JOB_ORIGIN=helper BEDROCK_NOW_VERBOSE=1 run_phase LiteLLM litellm _noisy 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'LiteLLM: starting')" 1
  # the terminal's and the Code page's own phases say it too
  assert_contains "$(sed -n '/^terminal_setup_hook() {/,/^}/p' "$STACK_DIR/lib/terminal.sh")" 'phase_start Terminal'
  assert_contains "$(sed -n '/^code_setup_hook() {/,/^}/p' "$STACK_DIR/lib/code.sh")" 'phase_start "Code page"'
}

test_run_phase_verbose_shows_compose_output() {
  out="$(BEDROCK_NOW_VERBOSE=1 run_phase LiteLLM litellm _noisy 2>&1)"
  assert_contains "$out" "compose noise 2"
  assert_contains "$out" "compose err"
  assert_contains "$out" "LiteLLM ready ("
}

test_run_phase_failure_shows_tail_logs_and_hint() {
  _fail() { local i; for i in $(seq 1 40); do echo "line $i"; done; return 1; }
  dc() { case "$*" in "logs --no-color --tail 30 litellm") echo "litellm says: bad config" ;; ps*) printf 'litellm\texited\t\n' ;; esac; }
  if out="$( (run_phase LiteLLM litellm _fail) 2>&1)"; then echo "should fail" >&2; return 1; fi
  assert_contains "$out" "line 40"
  assert_contains "$out" "line 11"
  assert_not_contains "$out" "line 10
"
  assert_contains "$out" "litellm says: bad config"
  assert_contains "$out" "./stack logs litellm"
  assert_contains "$out" "BEDROCK_NOW_VERBOSE=1"
}

# Docker out of address ranges for a new network: said as it is (how to free some), not as a service that failed
test_run_phase_says_when_docker_has_no_network_range_left() {
  _pools() { echo " Network p_chat-proxy  Error"; echo "failed to create network p_chat-proxy: Error response from daemon: all predefined address pools have been fully subnetted"; return 1; }
  dc() { case "$*" in ps*) printf 'subs-chat\trunning\thealthy\n' ;; esac; }
  if out="$( (run_phase "Chat's sandbox" subs-chat _pools) 2>&1)"; then echo "should fail" >&2; return 1; fi
  assert_contains "$out" "Chat's sandbox did not come up: Docker has no address range left for another network (docker network ls lists them;"
  assert_contains "$out" "docker network rm NAME"
  assert_not_contains "$out" "full logs: ./stack logs"
}

test_run_phase_failure_logs_only_unhealthy_services() {
  _fail() { return 1; }
  dc() {
    case "$*" in
      ps*) printf 'postgres\trunning\thealthy\nlitellm\trunning\tunhealthy\n' ;;
      "logs --no-color --tail 30 "*) local a="$*"; echo "LOGS ${a##* }" ;;
    esac
  }
  if out="$( (run_phase stack "postgres litellm" _fail) 2>&1)"; then return 1; fi
  assert_contains "$out" "LOGS litellm"
  assert_not_contains "$out" "LOGS postgres"
  assert_contains "$out" "./stack logs litellm"
}

test_building_says_it_is_still_at_work_only_in_a_phase_with_no_terminal() {
  # (dc build -q says nothing until it ends: in a log, a long build says it is still at work; its status is the build's)
  local out rc
  _quiet_build() { sleep 2.5; echo built; return "$1"; }
  BUILD_TICK_S=1
  # outside run_phase: CMD alone, no line
  rc=0; out="$(building "the x image" _quiet_build 3 2>&1)" || rc=$?
  assert_eq "$rc" 3
  assert_eq "$out" "built"
  # in a phase whose stderr is no terminal (this test's: a pipe): a line a second while it builds, then "ready"
  # (seconds as they come: a busy computer may say one late)
  out="$(run_phase "X image (build)" x building "the x image" _quiet_build 0 2>&1)"
  [ "$(printf '%s\n' "$out" | grep -c '^==> still building the x image ([0-9]s)$')" -ge 2 ] || { echo "$out" >&2; return 1; }
  assert_contains "$out" "==> X image (build) ready ("
  assert_not_contains "$out" "built"   # (the build's own output stays hidden, as before)
  # a failed build: its status, the failure said as before
  dc() { case "$*" in ps*) printf 'x\texited\t\n' ;; esac; }
  if out="$( (run_phase "X image (build)" x building "the x image" _quiet_build 1) 2>&1)"; then return 1; fi
  assert_contains "$out" "still building the x image"
  assert_contains "$out" "X image (build) failed after"
  assert_contains "$out" "built"
  # a phase that only waits says nothing while it waits
  out="$(run_phase "X (start)" x sleep 2.5 2>&1)"
  assert_not_contains "$out" "still"
  unset BUILD_TICK_S
}

test_building_never_waits_for_good_for_its_ticker() {
  # (v0.20.1 stopped the ticker with a TERM to a process group of its own: a build that ended before that group existed,
  # or a caller that ignores TERM, left building waiting for a ticker that waited for it — an update could hang)
  local d="$TMP/never" pid n m
  mkdir -p "$d"
  cat > "$d/run.sh" <<'RUN'
set -euo pipefail
. "$STACK_DIR/lib/common.sh"; . "$STACK_DIR/lib/commands.sh"
_PHASE_TICK=1; BUILD_TICK_S=150
exec 8>/dev/null
[ "$1" != ignore ] || trap '' TERM
for i in $(seq 1 "$2"); do building x true; done
echo done
RUN
  for m in "fast 300" "ignore 50"; do
    # shellcheck disable=SC2086  # (mode and count)
    bash "$d/run.sh" $m > "$d/out" 2>&1 & pid=$!
    n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; echo "building hung ($m)" >&2; return 1; fi
    wait "$pid"
    assert_eq "$(cat "$d/out")" done
  done
}

test_missing_images_skips_local_builds_and_present_images() {
  dc() { printf 'pgvector/pgvector:0.8.7-pg17\nghcr.io/berriai/litellm:1.105.0\nbedrock-now/shared-mcp:local\nbedrock-now/open-webui:local\n'; }
  # (compose.yaml's own references: the bases of its local builds too — Open WebUI's — each once)
  compose_refs() { printf 'ghcr.io/berriai/litellm:1.105.0\nghcr.io/open-webui/open-webui:v9-slim@sha256:%064d\nbedrock-now/open-webui:local\n' 0; }
  docker() { case "$*" in "image inspect pgvector/pgvector:0.8.7-pg17") return 0 ;; *) return 1 ;; esac; }
  assert_eq "$(missing_images | tr '\n' ' ')" "ghcr.io/berriai/litellm:1.105.0 ghcr.io/open-webui/open-webui:v9-slim@sha256:$(printf '%064d' 0) "
}

test_ensure_images_announces_size_and_pulls_only_missing() {
  missing_images() { printf 'ghcr.io/berriai/litellm:1.105.0\nghcr.io/open-webui/open-webui:v0.12.0-slim\n'; }
  docker() { echo "docker $*" >> "$TMP/calls"; }
  ensure_images 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "downloading 2 image(s) (~2.7 GB"
  assert_contains "$(cat "$TMP/err")" "several minutes"
  assert_eq "$(tr '\n' ';' < "$TMP/calls")" "docker pull ghcr.io/berriai/litellm:1.105.0;docker pull ghcr.io/open-webui/open-webui:v0.12.0-slim;"
}

test_ensure_images_silent_when_nothing_missing() {
  missing_images() { :; }
  docker() { echo "docker $*" >> "$TMP/calls"; }
  assert_eq "$(ensure_images 2>&1)" ""
  [ ! -f "$TMP/calls" ]
}

test_ensure_images_pull_failure_is_actionable() {
  missing_images() { echo rustfs/rustfs:1.0.1; }
  docker() { return 1; }
  if out="$( (ensure_images) 2>&1)"; then return 1; fi
  assert_contains "$out" "could not download rustfs/rustfs:1.0.1"
}
