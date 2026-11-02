# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329  # stubs read by the libs
# lib/plan.sh (JON-978): the plan of a ./stack update (the last successful one's steps, else the list shipped with the code),
# the steps a run takes, the time left, the terminal's record for Home, and the bar a terminal gets.
. "$STACK_DIR/lib/commands.sh"

_json_ok() { ! command -v python3 >/dev/null || python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$1"; }
_plan_of() { printf '%s\n' "$@" > "$TMP/plan.tsv"; }   # lines as LABEL:SECS
_tsv() { local l; for l in "$@"; do printf '%s\t%s\n' "${l%%:*}" "${l#*:}"; done; }

test_a_label_is_compared_without_its_trailing_parenthesised_part() {
  assert_eq "$(plan_norm 'Services (9) (http://127.0.0.1:8765)')" "Services"
  assert_eq "$(plan_norm 'New code (git)')" "New code"
  assert_eq "$(plan_norm 'Backup')" "Backup"
  assert_eq "$(plan_norm 'LiteLLM keys, Admin sign-in')" "LiteLLM keys, Admin sign-in"
}

test_before_any_update_is_recorded_the_plan_is_the_list_shipped_with_the_code() {
  plan_load > "$TMP/p"
  assert_eq "$(wc -l < "$TMP/p" | tr -d ' ')" 21
  assert_eq "$(head -n 1 "$TMP/p")" "$(printf 'Backup\t4')"
  assert_eq "$(tail -n 1 "$TMP/p")" "$(printf 'Finishing\t3')"
  assert_contains "$(cat "$TMP/p")" "$(printf 'Services\t6')"
  assert_contains "$(cat "$TMP/p")" "$(printf 'AWS key check\tskipped')"
  # in the order a nothing-changed update takes them
  assert_eq "$(cut -f1 "$TMP/p" | sed -n '1,3p' | tr '\n' ',')" "Backup,New code,AWS key check,"
  # every label of the shipped list is one the code logs (a timed_step, an upd_gate or a run_phase of the update)
  local l src
  src="$(cat "$STACK_DIR"/lib/*.sh)"
  while IFS=$'\t' read -r l _; do
    case "$src" in *"\"$l"*) ;; *) echo "the shipped plan has a step nothing logs: $l" >&2; return 1 ;; esac
  done < "$TMP/p"
}

test_the_last_updates_steps_are_the_plan_once_there_are_some() {
  mkdir -p "$STATE_DIR/update"
  _tsv "Backup:9" "Images:2" "Voice:skipped" > "$STATE_DIR/update/last-steps.tsv"
  assert_eq "$(plan_load | wc -l | tr -d ' ')" 3
  assert_eq "$(plan_load | head -n 1)" "$(printf 'Backup\t9')"
  # a file with nothing usable in it is no plan: the shipped list
  printf 'nonsense\nBackup\tlots\n' > "$STATE_DIR/update/last-steps.tsv"
  assert_eq "$(plan_load | wc -l | tr -d ' ')" 21
  assert_eq "$(plan_json | head -c 40)" '[{"label": "Backup", "secs": 4}, {"label'
  assert_contains "$(plan_json)" '{"label": "AWS key check", "secs": 0}'   # (skipped: no seconds)
}

test_a_successful_update_records_its_steps_a_failed_one_does_not() {
  mkdir -p "$STATE_DIR/update"
  _now() { echo 100; }
  ( plan_run_start
    phase_start Backup; log "$(phase_line Backup 5)" 2>/dev/null
    log "$(phase_line "Services (9) (http://x)" 7)" 2>/dev/null
    upd_same() { return 0; }; upd_note() { :; }; UPD_MODE=1
    upd_gate voice "Voice" "nothing changed" true 2>/dev/null
    log "$(phase_line "Download litellm:1.0" 30)" 2>/dev/null
    # stopped here: not recorded
  )
  [ ! -e "$STATE_DIR/update/last-steps.tsv" ] || { echo "a run that did not finish left a plan" >&2; return 1; }
  ( plan_run_start
    log "$(phase_line Backup 5)" 2>/dev/null
    log "$(phase_line "Services (9) (http://x)" 7)" 2>/dev/null
    upd_same() { return 0; }; upd_note() { :; }; UPD_MODE=1
    upd_gate voice "Voice" "nothing changed" true 2>/dev/null
    log "$(phase_line "Download litellm:1.0" 30)" 2>/dev/null
    plan_run_record )
  assert_eq "$(cat "$STATE_DIR/update/last-steps.tsv")" "$(printf 'Backup\t5\nServices\t7\nVoice\tskipped')"
  # and it is the plan of the next one
  assert_eq "$(plan_load | wc -l | tr -d ' ')" 3
  # no steps: the last plan stays
  ( plan_run_start; plan_run_record )
  assert_eq "$(wc -l < "$STATE_DIR/update/last-steps.tsv" | tr -d ' ')" 3
  # outside an update run nothing is recorded or kept
  rm -rf "$STATE_DIR/update"
  ( unset DEVOS_ADE_PLAN_RUN; log "$(phase_line Backup 5)" 2>/dev/null; phase_start Backup; plan_run_record )
  [ ! -e "$STATE_DIR/update" ] || { echo "recorded outside an update" >&2; return 1; }
}

test_a_skipped_step_is_recorded_with_its_reason() {
  _now() { echo 100; }; upd_same() { return 0; }; upd_note() { :; }; UPD_MODE=1
  plan_run_start
  upd_gate aws "AWS key check" "the same AWS key was checked in the last 24 hours" true 2>/dev/null
  assert_eq "$(cat "$STATE_DIR/update/run-steps.tsv")" "$(printf 'AWS key check\tskipped\tthe same AWS key was checked in the last 24 hours')"
  assert_contains "$(plan_status_fields)" '"steps": [{"label": "AWS key check", "took": "skipped", "why": "the same AWS key was checked in the last 24 hours"}]'
}

# plan_math PLAN STEPS [RUNNING ELAPSED] -> "DONE TOTAL LEFT"
test_the_time_left_is_what_the_plan_expects_of_the_steps_not_seen_yet() {
  _tsv "Backup:4" "New code:0" "Images:1" "Services:6" "Terminal:20" > "$TMP/plan.tsv"
  : > "$TMP/steps.tsv"
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv")" "0 5 31"
  _tsv "Backup:5" "New code (git):0" > "$TMP/steps.tsv"
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv")" "2 5 27"
  # the running step: what it is expected to take less what it has run
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv" Terminal 8)" "2 5 19"
}

test_a_step_that_runs_long_keeps_a_few_seconds_left_and_the_bar_never_claims_done() {
  _tsv "Backup:4" "Terminal:20" > "$TMP/plan.tsv"
  _tsv "Backup:4" > "$TMP/steps.tsv"
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv" Terminal 19)" "1 2 5"
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv" Terminal 400)" "1 2 5"   # (twice as long as it should: still at least 5)
}

test_a_step_the_plan_does_not_have_counts_as_it_comes() {
  _tsv "Backup:4" "Services:6" > "$TMP/plan.tsv"
  _tsv "Backup:4" "Brand new step:3" > "$TMP/steps.tsv"
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv")" "2 3 6"            # (3 steps now, none of them expected to take time)
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv" Services 2)" "2 3 5"
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv" Another 1)" "2 4 11"   # (running and not in the plan: a few seconds, plus Services)
  # a step that repeats is a step of its own
  _tsv "Backup:4" "Backup:4" > "$TMP/steps.tsv"
  assert_eq "$(plan_math "$TMP/plan.tsv" "$TMP/steps.tsv")" "2 3 6"
}

test_the_time_left_in_words() {
  assert_eq "$(plan_left_words 3)" "a few seconds left"
  assert_eq "$(plan_left_words 14)" "a few seconds left"
  assert_eq "$(plan_left_words 40)" "under a minute left"
  assert_eq "$(plan_left_words 60)" "~1 min left"
  assert_eq "$(plan_left_words 95)" "~2 min left"
  assert_eq "$(plan_left_words 600)" "~10 min left"
}

test_a_terminal_update_puts_its_steps_and_plan_into_the_record_home_reads() {
  mkdir -p "$STATE_DIR/status" "$STATE_DIR/update"; installed_version() { echo v0.9.0; }
  _tsv "Backup:4" "Images:1" "Voice:skipped" > "$STATE_DIR/update/last-steps.tsv"
  (
    DEVOS_ADE_JOB_CMD="update"; stack_lock update
    plan_run_start
    cp "$(terminal_job_file)" "$TMP/at-start"
    _now() { echo 1700000100; }; _plan_now() { PLAN_NOW=1700000100; }   # (the plan's clock: lib/plan.sh _plan_now)
    phase_start Backup
    cp "$(terminal_job_file)" "$TMP/during"
    log "$(phase_line Backup 5)" 2>/dev/null
    upd_same() { return 0; }; upd_note() { :; }; UPD_MODE=1
    upd_gate voice "Voice" "nothing changed" true 2>/dev/null
    phase_start "Services (9)"
    cp "$(terminal_job_file)" "$TMP/later"
    log "$(phase_line "Services (9)" 70)" 2>/dev/null
    _BN_CMD_DONE=1
  )
  # at the start: the plan, nothing done
  assert_contains "$(cat "$TMP/at-start")" '"phase": "running", "message": "Running in a terminal"'
  assert_contains "$(cat "$TMP/at-start")" '"step": "", "step_started_at": null, "steps": [], "plan": [{"label": "Backup", "secs": 4}, {"label": "Images", "secs": 1}, {"label": "Voice", "secs": 0}]'
  _json_ok "$TMP/at-start" || return 1
  # a step running: its name and when it began
  assert_contains "$(cat "$TMP/during")" '"step": "Backup", "step_started_at": 1700000100, "steps": []'
  _json_ok "$TMP/during" || return 1
  assert_contains "$(cat "$TMP/later")" '"step": "Services (9)", "step_started_at": 1700000100, "steps": [{"label": "Backup", "took": "5s"}, {"label": "Voice", "took": "skipped", "why": "nothing changed"}]'
  _json_ok "$TMP/later" || return 1
  # "pid" stays last (the helper's sweep of a stopped command reads it) and the rest of the record is as before
  case "$(cat "$TMP/later")" in *'"pid": '[0-9]*'}') ;; *) echo "pid is not last" >&2; return 1 ;; esac
  assert_contains "$(cat "$TMP/later")" '"action": "update", "command": "update", "phase": "running"'
  # the end: done, with every step and the time it took
  f="$(terminal_job_file)"
  assert_contains "$(cat "$f")" '"phase": "done"'
  assert_contains "$(cat "$f")" '"steps": [{"label": "Backup", "took": "5s"}, {"label": "Voice", "took": "skipped", "why": "nothing changed"}, {"label": "Services (9)", "took": "1m10s"}]'
  _json_ok "$f" || return 1
}

test_setup_run_by_the_update_adds_its_steps_to_its_parents_record() {
  mkdir -p "$STATE_DIR/status"; installed_version() { echo v0.9.0; }
  (
    stack_lock update; plan_run_start
    # the child process: no TERMINAL_JOB of its own, the parent's says whose record it is
    ( TERMINAL_JOB=''; export DEVOS_ADE_TERMINAL_JOB=update; phase_start Terminal; log "$(phase_line Terminal 4)" 2>/dev/null )
    _BN_CMD_DONE=1
    cp "$(terminal_job_file)" "$TMP/rec"
  )
  assert_contains "$(cat "$TMP/rec")" '"steps": [{"label": "Terminal", "took": "4s"}]'
  # a child of a helper job, or of nothing, writes no record
  rm -f "$(terminal_job_file)"
  ( unset DEVOS_ADE_TERMINAL_JOB TERMINAL_JOB; DEVOS_ADE_PLAN_RUN=1; phase_start Terminal; log "$(phase_line Terminal 4)" 2>/dev/null )
  [ ! -e "$(terminal_job_file)" ] || { echo "a record without a terminal job" >&2; return 1; }
}

test_a_terminal_job_that_is_not_an_update_has_no_step_fields() {
  mkdir -p "$STATE_DIR/status"; installed_version() { echo v0.9.0; }
  ( stack_lock code; phase_start X; log "$(phase_line X 1)" 2>/dev/null; _BN_CMD_DONE=1 )
  assert_not_contains "$(cat "$(terminal_job_file)")" '"steps"'
  assert_contains "$(cat "$(terminal_job_file)")" '"version": "v0.9.0", "pid": '
}

test_a_terminal_gets_a_bar_after_each_step_and_a_log_gets_none() {
  _tsv "Backup:4" "Images:1" "Services:6" "Terminal:20" > "$TMP/pl"
  mkdir -p "$STATE_DIR/update"
  _now() { echo 100; }
  plan_run_start
  cp "$TMP/pl" "$STATE_DIR/update/run-plan.tsv"
  _plan_tty() { return 0; }
  out="$( { log "$(phase_line Backup 4)"; log "$(phase_line "Images" 1)"; } 2>&1 )"
  assert_contains "$out" "==> Backup ready (4s)"
  assert_contains "$out" "[███░░░░░░░░░] 1/4 · Backup · under a minute left"
  assert_contains "$out" "[██████░░░░░░] 2/4 · Images · under a minute left"
  # the bar follows the line it is about
  assert_eq "$(printf '%s\n' "$out" | sed -n '1p')" "==> Backup ready (4s)"
  # not a TTY: the lines and nothing else, as the helper's job log and a pipe have them
  _plan_tty() { return 1; }
  out="$( { DEVOS_ADE_JOB_ORIGIN=helper timed_step Smoke true; log "$(phase_line Services 6)"; } 2>&1 )"
  assert_eq "$out" "$(printf '==> Smoke: starting…\n==> Smoke ready (0s)\n==> Services ready (6s)')"
  # a command that is no update run has no bar either
  _plan_tty() { return 0; }
  out="$( { unset DEVOS_ADE_PLAN_RUN; log "$(phase_line Backup 4)"; } 2>&1 )"
  assert_eq "$out" "==> Backup ready (4s)"
}

test_the_bar_is_cheap_a_step_costs_milliseconds() {
  plan_run_start
  local t0 t1 i
  t0="$(date +%s)"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do phase_start "Step $i"; phase_line "Step $i" 1 >/dev/null; done
  t1="$(date +%s)"
  [ $((t1 - t0)) -le 3 ] || { echo "20 steps took $((t1 - t0)) s" >&2; return 1; }
}

test_a_terminal_updates_record_costs_milliseconds_a_step_and_stays_readable_to_the_portal() {
  # a terminal update rewrites its record twice a step: escaping every label each time once cost 35 s over 40 steps
  mkdir -p "$STATE_DIR/status"; installed_version() { echo v0.9.0; }
  local t0 t1 i
  (
    umask 077   # (yours may be: the record is still the portal's to read)
    DEVOS_ADE_JOB_CMD="update"; stack_lock update
    plan_run_start
    t0="$(date +%s)"
    for i in $(seq 1 40); do phase_start "Step number $i"; log "$(phase_line "Step number $i" 1)" 2>/dev/null; done
    t1="$(date +%s)"
    [ $((t1 - t0)) -le 8 ] || { echo "40 steps with the record took $((t1 - t0)) s" >&2; exit 1; }
    _BN_CMD_DONE=1
  ) || return 1
  _json_ok "$(terminal_job_file)" || return 1
  assert_contains "$(cat "$(terminal_job_file)")" '{"label": "Step number 40", "took": "1s"}'
  assert_eq "$(ls -l "$(terminal_job_file)" | cut -c1-10)" "-rw-r--r--"
  assert_eq "$(find "$STATE_DIR/status" -name '.terminal-job.*' | wc -l | tr -d ' ')" 0   # (no temporary file left)
}
