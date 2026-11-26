# shellcheck shell=bash
# shellcheck disable=SC2329,SC2034  # stubs are called by the code under test; HEALTH_EVENTS_MAX is read by lib/health.sh
# JON-972: the quick health_record_write (lib/health.sh) and services_status_write (lib/commands.sh) write the very
# same files as the ones they replaced. tests/fixtures/status_write_old.sh keeps those as they were at 19702f3d
# (old_health_record_write, old_services_status_write); each case here runs old and new on the same inputs in two
# state folders (with `date` stubbed, so the clock is the same) and compares every file byte for byte, the return
# status and the mode. Sequences of two or three writes: the snapshot and the events carry over from one to the next.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/health.sh
. "$STACK_DIR/tests/fixtures/status_write_old.sh"

date() { case "${1:-}" in +%s) printf '%s\n' "$FAKE_NOW" ;; *) command date "$@" ;; esac; }
dc() {
  case "$*" in
    *--format*) [ "${FAKE_DC_RC:-0}" = 0 ] || return 1; printf '%s' "${FAKE_PS:-}" ;;
    *" -q"*) [ "${FAKE_IDS_RC:-0}" = 0 ] || return 1; printf '%s\n' "${FAKE_IDS:-abc123abc123}" ;;
  esac
}
docker() { case "$1" in inspect) printf '%s\n' "${FAKE_INSPECT:-}" ;; esac; }
optional_services() { printf '%s\n' "${FAKE_OPT:-}"; }
FAKE_NOW=1700000000

F0='0001-01-01T00:00:00Z'; F1='2026-10-27T10:00:00Z'; F2='2026-10-27T10:01:00.5Z'

# _id_same LABEL — old's folder against new's: the same files, bytes and modes, and no stray temporary file
_id_same() {
  local f lo ln bad=0
  lo="$(cd "$TMP/id_old" && find . -type f | LC_ALL=C sort)"; ln="$(cd "$TMP/id_new" && find . -type f | LC_ALL=C sort)"
  [ "$lo" = "$ln" ] || { printf '%s: files differ\nold: %s\nnew: %s\n' "$1" "$lo" "$ln" >&2; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cmp -s "$TMP/id_old/$f" "$TMP/id_new/$f" || { printf '%s: %s differs\n--- old\n%s\n--- new\n%s\n' "$1" "$f" "$(cat "$TMP/id_old/$f")" "$(cat "$TMP/id_new/$f")" >&2; bad=1; }
    [ "$(perm_of "$TMP/id_old/$f")" = "$(perm_of "$TMP/id_new/$f")" ] || { printf '%s: %s mode differs\n' "$1" "$f" >&2; bad=1; }
  done <<EOL
$lo
EOL
  return "$bad"
}

# _id_health LABEL PREV EVENTS STEP... — PREV and EVENTS seed container-health.tsv and container-events.tsv (as they
# are, no newline added). A STEP is the LINES argument; "@inspect:TEXT" asks the (stubbed) Docker for TEXT, "@dockerfail"
# a Docker that does not answer, "@noenv" takes .env away.
_id_health() {
  local label="$1" prev="$2" ev="$3" impl step i rcs_old='' rcs_new='' rc; shift 3
  for impl in old new; do
    rm -rf "$TMP/id_$impl"; mkdir -p "$TMP/id_$impl/status"; STATE_DIR="$TMP/id_$impl"; printf 'X=1\n' > "$ENV_FILE"
    FAKE_IDS_RC=0; FAKE_INSPECT=''
    [ -z "$prev" ] || printf '%s' "$prev" > "$STATE_DIR/status/container-health.tsv"
    [ -z "$ev" ] || printf '%s' "$ev" > "$STATE_DIR/status/container-events.tsv"
    i=0
    for step in "$@"; do
      i=$((i + 1)); FAKE_NOW=$((1700000000 + i * 100)); rc=0
      case "$step" in
        @noenv) rm -f "$ENV_FILE"; health_fn "$impl" || rc=$? ;;
        @dockerfail) FAKE_IDS_RC=1; health_fn "$impl" || rc=$?; FAKE_IDS_RC=0 ;;
        @inspect:*) FAKE_INSPECT="${step#@inspect:}"; health_fn "$impl" || rc=$? ;;
        *) printf 'X=1\n' > "$ENV_FILE"; health_fn "$impl" "$step" || rc=$? ;;
      esac
      if [ "$impl" = old ]; then rcs_old="$rcs_old$rc"; else rcs_new="$rcs_new$rc"; fi
    done
    printf 'X=1\n' > "$ENV_FILE"
  done
  assert_eq "$rcs_new" "$rcs_old" || return 1
  case "$rcs_new" in *[1-9]*) printf '%s: a write returned non-zero (%s)\n' "$label" "$rcs_new" >&2; return 1 ;; esac
  _id_same "$label"
}
health_fn() { local impl="$1"; shift; if [ "$impl" = old ]; then old_health_record_write "$@"; else health_record_write "$@"; fi; }

# L SVC RS STATE EXIT HEALTH OOM FIN -> one line of `docker inspect`
L() { printf '%s|%s|%s|%s|%s|%s|%s\n' "$@"; }

test_identity_health_several_containers_and_an_other_one() {
  HEALTH_EVENTS_MAX=50
  local s1 s2 s3
  s1="$(L litellm 0 running 0 healthy false $F0; L portal 0 running 0 healthy false $F0; L caddy 0 running 0 '' false $F0; L my-db 0 running 0 healthy false $F0; L rustfs-init 0 exited 0 '' false $F1)"
  s2="$(L litellm 2 running 0 healthy false $F1; L portal 0 running 0 unhealthy false $F0; L caddy 0 exited 3 '' false $F1; L my-db 4 running 0 unhealthy false $F0; L rustfs-init 0 exited 0 '' false $F1)"
  s3="$(L litellm 0 running 0 healthy false $F0; L portal 0 running 0 unhealthy false $F0; L caddy 0 exited 3 '' false $F1; L my-db 5 exited 9 unhealthy false $F2; L other-thing 1 running 0 healthy false $F0)"
  _id_health seq3 '' '' "$s1" "$s2" "$s3" || return 1
  _id_health same-twice '' '' "$s2" "$s2" "$s2" || return 1
  _id_health recovered-then-unhealthy '' '' "$(L portal 0 running 0 unhealthy false $F0)" "$(L portal 0 running 0 healthy false $F0)" "$(L portal 0 running 0 unhealthy false $F0)" || return 1
  _id_health recreated-count-reset '' '' "$(L litellm 4 running 0 healthy false $F0)" "$(L litellm 0 running 0 healthy false $F0)" "$(L litellm 1 running 0 healthy false $F0)" || return 1
  _id_health two-strangers '' '' "$(L aaa 0 running 0 healthy false $F0; L bbb 0 running 0 healthy false $F0)" "$(L aaa 3 running 0 healthy false $F0; L bbb 1 exited 5 healthy false $F1; L aaa 4 running 0 healthy false $F0)" || return 1
}

test_identity_health_odd_characters_and_fields() {
  HEALTH_EVENTS_MAX=50
  local odd
  odd="$(L 'My App' 1 Running 1 Unhealthy TRUE '2026-10-27 10:00')"$'\n'"$(L 'UPPER' 2 'ex ited' 3 'un healthy' true "$F1")"$'\n'
  odd="$odd$(L 'evil"}' 1 running 0 healthy false "$F0")"$'\n'"$(L 'back\slash' 3 exited 4 healthy false "$F1")"$'\n'
  odd="$odd$(L 'a.b' 1 exited 2 healthy false "$F1")"$'\n'"$(L 'x|y' 2 exited 5 healthy false "$F1")"$'\n'
  odd="$odd$(L litellm 'a"b' 'run"ning' '1\n' 'heal<x>thy' 'tr ue' '20"26-T')"
  _id_health odd '' '' "$odd" "$odd" "$(printf '%s\nlitellm|9|exited|2|unhealthy|true|%s\n' "$odd" "$F2")" || return 1
  _id_health nonnumeric '' '' "$(L litellm abc x running '' false '')" "$(L litellm 1x2 y exited -1 unhealthy true "$F1")" "$(L litellm 1234567890123456 1234567890123 exited 1.5 healthy false "$F2")" || return 1
  _id_health empty-fields '' '' "$(L '' '' '' '' '' '' '')" "$(L litellm '' '' '' '' '' '')" "$(L portal '' exited '' '' '' "$F1")" || return 1
  _id_health long-values '' '' "$(L "$(printf 'a%.0s' $(seq 1 60))" 1 "$(printf 'r%.0s' $(seq 1 60))" 1 healthy false "$(printf '1%.0s' $(seq 1 60))")" || return 1
  _id_health extra-and-missing-fields '' '' 'litellm|1|running|0|healthy|false|2026-10-27T10:00:00Z|extra|more' 'litellm|2|running' 'litellm' 'litellm|3|exited|4|healthy|true' || return 1
  _id_health blank-lines '' '' "$(printf '\n\n%s\n\n%s\n' "$(L litellm 1 running 0 healthy false $F0)" "$(L portal 0 running 0 unhealthy false $F0)")" || return 1
}

test_identity_health_exit_oom_and_finished_time_rules() {
  HEALTH_EVENTS_MAX=50
  local n=0 st code oom fin steps
  for code in 0 1 3 137 143 255 ''; do
    for oom in true false ''; do
      for fin in "$F0" "$F1" '' '0001-xx'; do
        n=$((n + 1))
        _id_health "exit-$code-$oom-$fin" '' '' "$(L litellm 0 running 0 healthy false $F0)" "$(L litellm 0 exited "$code" healthy "$oom" "$fin")" "$(L litellm 0 exited "$code" healthy "$oom" "$fin")" || return 1
      done
    done
  done
  # a finished time that stays, then changes; the state not exited; the first look
  steps="$(L litellm 0 exited 1 '' false $F1)"
  _id_health fin-unchanged '' '' "$steps" "$steps" "$(L litellm 0 exited 1 '' false $F2)" || return 1
  _id_health fin-not-exited '' '' "$(L litellm 0 running 1 '' false $F1)" "$(L litellm 0 created 1 '' true $F2)" || return 1
  _id_health fin-first-look-0001 '' '' "$(L litellm 0 exited 1 '' true $F0)" || return 1
  _id_health fin-dirty '' '' "$(L litellm 0 exited 1 '' false 'ab2026-10-27T10:00:00Zxyz|q')" "$(L litellm 0 exited 1 '' false '2026-10-27T10:00:00Z')" || return 1
}

test_identity_health_previous_snapshot_and_events_file() {
  local prev ev i
  prev="litellm|1|running|0|healthy|false|$F0"$'\n'"litellm|9|exited|3|unhealthy|false|$F1"$'\n'"portal|2|exited|5|healthy|false|$F1"$'\n'"my|1|x|0|y|false|"$'\n'"short"$'\n'"nopipe"$'\n'"caddy||x|0||false|"$'\n'"rustfs|5|running|0|healthy|false|2026|x"$'\n'
  HEALTH_EVENTS_MAX=50
  _id_health dup-keys "$prev" '' "$(L litellm 2 running 0 healthy false $F0; L portal 2 exited 5 unhealthy false $F1; L caddy 1 running 0 healthy false $F0; L rustfs 6 exited 7 healthy false 2026)" "$(L litellm 2 running 0 unhealthy false $F0)" || return 1
  _id_health prev-no-trailing-newline "litellm|1|running|0|healthy|false|$F0" '' "$(L litellm 3 running 0 healthy false $F0)" || return 1
  ev=''
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ev="$ev$((1690000000 + i))|portal|restart|$i|0"$'\n'; done
  for HEALTH_EVENTS_MAX in 5 12 50 0; do
    _id_health "long-events-$HEALTH_EVENTS_MAX" '' "$ev" "$(L litellm 0 running 0 healthy false $F0)" "$(L litellm 3 exited 1 unhealthy false $F1)" || return 1
    _id_health "long-events-quiet-$HEALTH_EVENTS_MAX" '' "$ev" "$(L litellm 0 running 0 healthy false $F0)" || return 1
  done
  HEALTH_EVENTS_MAX=5
  # events rows that are not ours: empty time, words, extra fields, no newline at the end (read leaves that line out)
  ev=$'|x|y|1|2\nabc|My Svc|KIND|1x|2\n1|a|b|c|4|5|6\n7\n\n8|portal|restart|2|0\n9|portal|exit|0|3|4'
  _id_health odd-events '' "$ev" "$(L litellm 0 running 0 healthy false $F0)" "$(L litellm 2 running 0 healthy false $F0)" || return 1
  _id_health odd-events-quiet '' "$ev" "$(L litellm 0 running 0 healthy false $F0)" || return 1
  _id_health odd-events-ends-in-newline '' "$ev"$'\n' "$(L litellm 0 running 0 healthy false $F0)" || return 1
  _id_health events-file-empty '' $'\n' "$(L litellm 0 running 0 healthy false $F0)" || return 1
}

test_identity_health_no_answer_no_env_no_containers() {
  HEALTH_EVENTS_MAX=50
  local a b
  a="$(L litellm 0 running 0 healthy false $F0)"; b="$(L litellm 2 running 0 unhealthy false $F0)"
  _id_health empty-first '' '' '' || return 1
  _id_health empty-after "$a" '' "$b" '' $'\n\n' || return 1
  _id_health noenv-first '' '' @noenv "$a" || return 1
  _id_health noenv-between '' '' "$a" @noenv "$b" || return 1
  _id_health docker-fail '' '' "$a" @dockerfail "$b" || return 1
  _id_health inspect-lines '' '' "@inspect:$a" "@inspect:$b" @dockerfail "@inspect:" "@inspect:$b" || return 1
}

# a fixed pseudo-random run: the same inputs every time (RANDOM is seeded)
test_identity_health_random_sequences() {
  local P_SVC P_NUM P_STATE P_EXIT P_HEALTH P_OOM P_FIN
  P_SVC=(litellm portal caddy rustfs-init searxng stranger 'My App' UPPER 'evil"}' 'back\slash' 'a.b' 'x|y' '' db-1 db-2 vllm)
  P_NUM=(0 0 0 1 2 3 5 '' abc 1x2 00 123456789012345 7)
  P_STATE=(running running exited exited created Exited 'ex ited' '' paused)
  P_EXIT=(0 0 1 3 137 143 '' x 255 -1)
  P_HEALTH=(healthy healthy unhealthy unhealthy '' none starting Unhealthy)
  P_OOM=(false false true true '' TRUE 1)
  P_FIN=("$F0" "$F0" "$F1" "$F1" "$F2" '' garbage '0001-x' '2026-10-27T10:00:00.123456789Z' 'a|b')
  HEALTH_EVENTS_MAX=7
  RANDOM=20261125
  local run step steps k nl line fields suffix
  for run in $(seq 1 70); do
    steps=()
    for step in 1 2 3; do
      line=''
      for k in $(seq 1 $((1 + RANDOM % 4))); do
        fields="${P_SVC[RANDOM % ${#P_SVC[@]}]}|${P_NUM[RANDOM % ${#P_NUM[@]}]}|${P_STATE[RANDOM % ${#P_STATE[@]}]}|${P_EXIT[RANDOM % ${#P_EXIT[@]}]}|${P_HEALTH[RANDOM % ${#P_HEALTH[@]}]}|${P_OOM[RANDOM % ${#P_OOM[@]}]}|${P_FIN[RANDOM % ${#P_FIN[@]}]}"
        case $((RANDOM % 12)) in 0) fields="${fields%|*|*|*}" ;; 1) fields="$fields|extra|more" ;; esac
        line="$line${line:+$'\n'}$fields"
        [ $((RANDOM % 10)) -ne 0 ] || line="$line"$'\n'
      done
      steps[${#steps[@]}]="$line"
    done
    [ $((RANDOM % 4)) -ne 0 ] || steps[1]="${steps[0]}"   # the same look twice
    _id_health "random-$run" '' '' "${steps[0]}" "${steps[1]}" "${steps[2]}" || return 1
  done
}

# _id_services LABEL STEP... — services_status_write (and, through it, the health record) old and new; a STEP is "arg:PS"
# (PS given), "ps:PS" (asked of Docker), "opt:LIST" (the optional services now on), "inspect:LINES", "dockerfail", "noenv"
_id_services() {
  local label="$1" impl step i rc rcs_old='' rcs_new=''; shift
  HEALTH_EVENTS_MAX=50
  for impl in old new; do
    rm -rf "$TMP/id_$impl"; mkdir -p "$TMP/id_$impl/status"; STATE_DIR="$TMP/id_$impl"; printf 'X=1\n' > "$ENV_FILE"
    FAKE_DC_RC=0; FAKE_IDS_RC=0; FAKE_OPT=''; FAKE_PS=''; FAKE_INSPECT=''
    i=0
    for step in "$@"; do
      i=$((i + 1)); FAKE_NOW=$((1700000000 + i * 100)); rc=0
      case "$step" in
        arg:*) printf 'X=1\n' > "$ENV_FILE"; services_fn "$impl" "${step#arg:}" || rc=$? ;;
        ps:*) printf 'X=1\n' > "$ENV_FILE"; FAKE_PS="${step#ps:}"; services_fn "$impl" || rc=$? ;;
        opt:*) FAKE_OPT="${step#opt:}"; i=$((i - 1)) ;;
        inspect:*) FAKE_INSPECT="${step#inspect:}"; i=$((i - 1)) ;;
        dockerfail) FAKE_DC_RC=1; services_fn "$impl" || rc=$?; FAKE_DC_RC=0 ;;
        noenv) rm -f "$ENV_FILE"; services_fn "$impl" "x" || rc=$? ;;
      esac
      if [ "$impl" = old ]; then rcs_old="$rcs_old$rc"; else rcs_new="$rcs_new$rc"; fi
    done
    printf 'X=1\n' > "$ENV_FILE"
  done
  assert_eq "$rcs_new" "$rcs_old" || return 1
  _id_same "$label"
}
services_fn() { local impl="$1"; shift; if [ "$impl" = old ]; then old_services_status_write "$@"; else services_status_write "$@"; fi; }

T=$'\t'
test_identity_services_json() {
  local full odd
  full="$(printf 'caddy\trunning\thealthy\nportal\trunning\thealthy\nopen-webui\trunning\thealthy\nlitellm\trunning\thealthy\nrustfs\trunning\thealthy\nshared-mcp\trunning\t\npostgres\trunning\thealthy\nsearxng\trunning\thealthy\nforgejo\texited\t\nstt\trunning\tstarting\n')"
  _id_services full "arg:$full" || return 1
  _id_services asked-of-docker "ps:$full" || return 1
  _id_services optional-on "opt:searxng forgejo stt terminal code" "arg:$full" "opt:" "arg:$full" || return 1
  _id_services missing-from-ps "arg:$(printf 'caddy\trunning\thealthy\nportal\texited\t\n')" "opt:searxng" "arg:$(printf 'caddy\trunning\thealthy\n')" || return 1
  _id_services duplicate-row "arg:$(printf 'caddy\trunning\thealthy\ncaddy\texited\tunhealthy\nportal\texited\t\nportal\trunning\thealthy\n')" || return 1
  _id_services duplicate-in-list "opt:caddy searxng searxng" "arg:$full" || return 1
  odd="$(printf 'caddy\tRunning\tHealthy\nportal\trun"ning\thea\\lthy<x>\nopen-webui\tstate with  spaces-and-dashes\tx y-z\nlitellm\t%s\t%s\nrustfs\t\t\nshared-mcp\n\tpostgres\tx\n\nsearxng\trunning"},{\thealthy\\n<x>\n' "$(printf 'abcdefghij%.0s' 1 2 3)" "$(printf 'z-%.0s' $(seq 1 20))")"
  _id_services odd-characters "opt:searxng" "arg:$odd" || return 1
  _id_services short-rows "arg:$(printf 'caddy\nportal\trunning\nopen-webui\t\t\nlitellm\t\thealthy\n')" || return 1
  _id_services crlf "arg:$(printf 'caddy\trunning\thealthy\r\nportal\r\n')" || return 1
  _id_services empty-ps 'arg:' 'ps:' || return 1
  _id_services docker-fails "ps:$full" dockerfail "arg:$(printf 'caddy\trunning\t\n')" noenv "arg:$full" || return 1
  _id_services first-then-changes "arg:$(printf 'caddy\trunning\thealthy\n')" "arg:$(printf 'caddy\texited\t\n')" "arg:$(printf 'caddy\trunning\thealthy\n')" || return 1
}

test_identity_services_also_writes_the_health_record() {
  local ps in1 in2
  ps="$(printf 'caddy\trunning\thealthy\nportal\trunning\tunhealthy\n')"
  in1="$(L litellm 0 running 0 healthy false $F0; L portal 0 running 0 healthy false $F0; L mine 0 running 0 healthy false $F0)"
  in2="$(L litellm 3 running 0 healthy false $F0; L portal 0 running 0 unhealthy false $F0; L mine 1 exited 2 healthy false $F1)"
  _id_services with-health "inspect:$in1" "arg:$ps" "inspect:$in2" "arg:$ps" "ps:$ps" "inspect:" "arg:$ps" || return 1
  # (the health record was written: not just equal because both wrote nothing)
  assert_contains "$(cat "$TMP/id_new/status/container-health.json")" '"kind": "restart", "count": 3'
}
