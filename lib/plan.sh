# shellcheck shell=bash
# The plan of a ./stack update: which steps it will take and about how long each takes on this computer, so Home's update
# card and a terminal can say "14 of 31, about a minute left" (JON-978). Sourced by lib/commands.sh.
#
#   .state/update/last-steps.tsv   the steps of the last successful update, in order: LABEL <TAB> SECONDS (or the word
#                                  skipped). Written when an update ends well (plan_run_record), never by a failed one.
#   lib/update-steps.tsv           the same list shipped with the code, measured on the test host: the plan until this
#                                  computer has recorded one of its own.
#   .state/update/run-plan.tsv     the plan this run started with (it does not change while the run goes on)
#   .state/update/run-steps.tsv    the steps this run finished so far: LABEL, SECONDS (or skipped), and why it was skipped
#   .state/update/run-plan.json, run-steps.json   the same as JSON, made once (the plan at the start, a step as it ends), so
#                                  the record a terminal update rewrites after each step is put together without a process
#   .state/update/run-step         the step running now: LABEL, when it started
# A label is compared without its trailing parenthesised part and what follows it ("Services (9) (http://…)" is
# "Services": counts and addresses differ from run to run). Whether a step will be skipped is not known up front (its
# inputs change during the run), so the plan lists every step it had and a step is greyed once the log says it was skipped.
#
# While ./stack update runs (DEVOS_ADE_PLAN_RUN=1, set by plan_run_start, kept by its children and its re-exec), phase_start,
# phase_line and upd_gate leave the run files; in a terminal they also put them into the record Home reads
# (lib/lock.sh _terminal_job_progress), and a terminal that is a TTY gets a one-line bar after each step (plan_bar).
# Everything here is cheap (a few small files, no docker, and per step no process but the clock's) and never fatal: a terminal
# update rewrites its record twice a step, and escaping every label each time cost 35 s over 40 steps.

plan_dir() { printf '%s/update\n' "$STATE_DIR"; }
plan_last_file() { printf '%s/last-steps.tsv\n' "$(plan_dir)"; }
plan_shipped_file() { printf '%s/lib/update-steps.tsv\n' "$STACK_DIR"; }

# plan_norm LABEL -> LABEL without its first " (" and what follows
plan_norm() { printf '%s\n' "${1%% (*}"; }

# plan_load -> the plan, LABEL<TAB>SECONDS|skipped per line: this computer's last update's steps, else the shipped list
plan_load() {
  local f out
  for f in "$(plan_last_file)" "$(plan_shipped_file)"; do
    [ -s "$f" ] || continue
    out="$(awk -F'\t' 'NF >= 2 && $1 != "" && $1 !~ /^#/ && ($2 ~ /^[0-9]+$/ || $2 == "skipped") { print $1 "\t" $2 }' "$f" 2>/dev/null | head -n 80)"
    [ -z "$out" ] || { printf '%s\n' "$out"; return 0; }
  done
  return 0
}

# _plan_jstr VAR TEXT — VAR is TEXT safe inside a JSON string, the way _job_json_str makes it (no quotes, backslashes or
# control characters, at most 300 characters), in the shell itself: no process
_plan_jstr() {
  local t="$2"
  t="${t//\\/}"; t="${t//\"/}"; t="${t//[[:cntrl:]]/}"
  [ "${#t}" -le 300 ] || t="${t:0:300}"
  printf -v "$1" '%s' "$t"
}

# _plan_json -> the plan lines on stdin as [{"label": "Backup", "secs": 4}, …] (a skipped step: 0 s)
_plan_json() {
  local out='' l s j
  while IFS=$'\t' read -r l s; do
    [ -n "$l" ] || continue
    case "$s" in '' | *[!0-9]*) s=0 ;; esac
    _plan_jstr j "$l"
    out="$out${out:+, }{\"label\": \"$j\", \"secs\": $s}"
  done
  printf '[%s]' "$out"
}
plan_json() { plan_load | _plan_json; }

# plan_run_start — a new update run: its plan is fixed now, the run's files start empty and the record Home reads shows the plan
plan_run_start() {
  local d="$STATE_DIR/update"
  mkdir -p "$d" 2>/dev/null || return 0
  rm -f "$d/run-steps.tsv" "$d/run-steps.json" "$d/run-step" 2>/dev/null || true
  plan_load > "$d/run-plan.tsv" 2>/dev/null || true
  _plan_json < "$d/run-plan.tsv" > "$d/run-plan.json" 2>/dev/null || true
  DEVOS_ADE_PLAN_RUN=1; export DEVOS_ADE_PLAN_RUN
  _plan_publish
  return 0
}

# _plan_now — PLAN_NOW is the clock's seconds: date once in a process, then the shell's own SECONDS from there (no process)
_plan_now() {
  [ -n "${_PLAN_T0:-}" ] || { _PLAN_T0="$(date +%s)"; _PLAN_S0=$SECONDS; }
  PLAN_NOW=$((_PLAN_T0 + SECONDS - _PLAN_S0))
}

plan_step_begin() { # plan_step_begin LABEL — phase_start's
  [ "${DEVOS_ADE_PLAN_RUN:-}" = 1 ] || return 0
  _plan_now
  printf '%s\t%s\n' "$1" "$PLAN_NOW" > "$STATE_DIR/update/run-step" 2>/dev/null || return 0
  _plan_publish
}
plan_step_end() { # plan_step_end LABEL SECONDS|skipped [WHY] — phase_line's, and upd_gate's for a step it skipped
  local d cur why="${3:-}" secs="$2" took jl jw
  [ "${DEVOS_ADE_PLAN_RUN:-}" = 1 ] || return 0
  d="$STATE_DIR/update"
  why="${why//[[:cntrl:]]/}"
  printf '%s\t%s\t%s\n' "$1" "$secs" "$why" >> "$d/run-steps.tsv" 2>/dev/null || return 0
  # (its JSON, made once: _plan_fields only joins these)
  if [ "$secs" = skipped ]; then took=skipped
  else case "$secs" in '' | *[!0-9]*) secs=0 ;; esac
    if [ "$secs" -lt 60 ]; then took="${secs}s"; else printf -v took '%dm%02ds' $((secs / 60)) $((secs % 60)); fi
  fi
  _plan_jstr jl "$1"; _plan_jstr jw "$why"
  printf '{"label": "%s", "took": "%s"%s}\n' "$jl" "$took" "${jw:+, \"why\": \"$jw\"}" >> "$d/run-steps.json" 2>/dev/null || true
  cur=''; if [ -f "$d/run-step" ]; then IFS=$'\t' read -r cur _ < "$d/run-step" || cur=''; fi
  [ "$cur" != "$1" ] || rm -f "$d/run-step" 2>/dev/null || true
  _plan_publish
}

# _plan_publish — Home's record of this terminal update gets the new step (lib/lock.sh)
_plan_publish() { ! declare -F _terminal_job_progress >/dev/null || _terminal_job_progress || true; return 0; }

# _plan_fields — PLAN_FIELDS is the record's step fields: "step": "Images", "step_started_at": 1700000000, "steps": [{"label",
# "took", "why"}], "plan": [{"label", "secs"}] — what the helper's status has too (lib/helper.sh). Empty outside an update run.
# Shell builtins only (the JSON was made as each piece came: plan_run_start, plan_step_end). plan_status_fields prints them.
PLAN_FIELDS=''
_plan_fields() {
  local d cur='' at='' steps='' n=0 line plan='[]' jc
  PLAN_FIELDS=''
  [ "${DEVOS_ADE_PLAN_RUN:-}" = 1 ] || return 0
  d="$STATE_DIR/update"; [ -f "$d/run-plan.tsv" ] || return 0
  if [ -f "$d/run-step" ]; then IFS=$'\t' read -r cur at < "$d/run-step" 2>/dev/null || true; fi
  case "$at" in '' | *[!0-9]*) at=null ;; esac
  [ -n "$cur" ] || at=null
  if [ -f "$d/run-steps.json" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n + 1)); [ "$n" -le 80 ] || break
      steps="$steps${steps:+, }$line"
    done < "$d/run-steps.json"
  fi
  if [ -s "$d/run-plan.json" ]; then IFS= read -r plan < "$d/run-plan.json" || true; fi
  [ -n "$plan" ] || plan='[]'
  _plan_jstr jc "$cur"
  PLAN_FIELDS="\"step\": \"$jc\", \"step_started_at\": $at, \"steps\": [$steps], \"plan\": $plan"
}
plan_status_fields() { _plan_fields; printf '%s' "$PLAN_FIELDS"; }

# plan_run_record — the update ended well: its steps are the next update's plan (only then: a failed or stopped one is not a
# plan). Download steps are left out: one per image, named by version and side by side, they are not a stretch of time.
plan_run_record() {
  local d tmp
  [ "${DEVOS_ADE_PLAN_RUN:-}" = 1 ] || return 0
  d="$STATE_DIR/update"; [ -s "$d/run-steps.tsv" ] || return 0
  tmp="$d/.last-steps.$$"
  if awk -F'\t' '$1 != "" && $1 !~ /^Download / { l = $1; sub(/ \(.*$/, "", l); print l "\t" $2 }' "$d/run-steps.tsv" > "$tmp" 2>/dev/null &&
     [ -s "$tmp" ] && mv -f "$tmp" "$(plan_last_file)" 2>/dev/null; then :; else rm -f "$tmp" 2>/dev/null || true; fi
  return 0
}

# plan_math PLAN STEPS [RUNNING_LABEL ELAPSED_S] -> "DONE TOTAL LEFT": the steps finished, the steps there are (the plan's, and
# each one the plan did not have as it comes), and the seconds left: what the plan expects for its steps not seen yet, plus for
# the running one what it expects less the time it has run, but at least PLAN_MIN_LEFT_S (a step that runs long never reads 0).
# The same numbers as the portal's (portal/portal/static/updatecheck.js progress).
PLAN_MIN_LEFT_S=5
plan_math() {
  awk -F'\t' -v cur="${3:-}" -v el="${4:-0}" -v min="$PLAN_MIN_LEFT_S" '
    function norm(l,  i) { i = index(l, " ("); return i ? substr(l, 1, i - 1) : l }
    function find(l,  i) { for (i = 1; i <= n; i++) if (!used[i] && pl[i] == l) return i; return 0 }
    FILENAME == ARGV[1] { if ($1 != "") { n++; pl[n] = norm($1); ps[n] = ($2 ~ /^[0-9]+$/) ? $2 + 0 : 0 } next }
    $1 != "" { done++; i = find(norm($1)); if (i) used[i] = 1; else extra++ }
    END {
      left = 0; total = n + extra
      if (cur != "") {
        i = find(norm(cur)); ex = 0
        if (i) { used[i] = 1; ex = ps[i] } else total++
        r = ex - el; if (r < min) r = min
        left += r
      }
      for (i = 1; i <= n; i++) if (!used[i]) left += ps[i]
      printf "%d %d %d\n", done, total, left
    }' "$1" "$2"
}

# plan_left_words SECONDS -> "a few seconds left" | "under a minute left" | "~2 min left"
plan_left_words() {
  local s="$1" m
  if [ "$s" -lt 15 ]; then echo "a few seconds left"
  elif [ "$s" -lt 60 ]; then echo "under a minute left"
  else m=$(((s + 30) / 60)); echo "~$m min left"; fi
}

# plan_bar — after a step on a terminal: [████████░░░░] 14/31 · Images · ~1 min left. Nothing without a TTY, so a helper job's
# log (read by lib/helper.sh _job_steps) and a pipe get no extra lines.
_plan_tty() { [ -t 2 ]; }
plan_bar() {
  local d out nd total left label full i bar=''
  [ "${DEVOS_ADE_PLAN_RUN:-}" = 1 ] || return 0
  _plan_tty || return 0
  d="$STATE_DIR/update"; [ -f "$d/run-plan.tsv" ] && [ -s "$d/run-steps.tsv" ] || return 0
  label="$(tail -n 1 "$d/run-steps.tsv" | cut -f1)"
  out="$(plan_math "$d/run-plan.tsv" "$d/run-steps.tsv")" || return 0
  # shellcheck disable=SC2086  # three numbers
  set -- $out; nd="$1"; total="$2"; left="$3"
  [ "$total" -gt 0 ] || return 0
  full=$((nd * 12 / total)); [ "$full" -le 12 ] || full=12
  for ((i = 0; i < 12; i++)); do if [ "$i" -lt "$full" ]; then bar="$bar█"; else bar="$bar░"; fi; done
  printf '[%s] %s/%s · %s · %s\n' "$bar" "$nd" "$total" "$(plan_norm "$label")" "$(plan_left_words "$left")" >&2
}
