# shellcheck shell=bash
# shellcheck disable=SC2329,SC2034  # stubs are called by the code under test; fails/slow/slow_list are cmd_test's, read by _check
# JON-972: the smoke checks' groups run side by side (lib/commands.sh _test_checks, _test_group), speech-to-text's last and
# alone. tests/fixtures/test_checks_old.sh keeps _test_checks as it was (v0.68.12), the groups one after the other, as
# old_test_checks; with every group stubbed, both print the same lines and reach the same counts.
. "$STACK_DIR/lib/commands.sh"
. "$STACK_DIR/tests/fixtures/test_checks_old.sh"

# _sg_setup — .env for the LiteLLM and shared-mcp checks; curl, curl_auth and litellm_key_status answer as SG_* say; every
# other group prints what SG_<GROUP> holds (lines: ok LABEL | fail LABEL | slow LABEL | warn TEXT | die TEXT | sleep S |
# child S, a program of its own that sleeps, then notes its end | false), and notes its start and end in $TMP/order
_sg_setup() {
  printf 'LITELLM_PORT=4000\nSHARED_MCP_PORT=8765\nCLAUDE_BEDROCK_HAIKU_MODEL=haiku-x\nLITELLM_KEY_SETUP=sk-s\nLITELLM_KEY_CLAUDE_CODE=sk-c\nLITELLM_KEY_OPENWEBUI=sk-o\nLITELLM_KEY_TERMINAL=sk-t\nOWUI_EMBED_MODEL=embed-x\nSHARED_MCP_TOKEN=tok\n' > "$ENV_FILE"
  mkdir -p "$STATE_DIR"; : > "$TMP/order"
  curl() {
    local a; for a in "$@"; do case "$a" in
      */health/liveliness) echo "${SG_ALIVE:-200}"; return 0 ;;
      */healthz) echo 200; return 0 ;;
      */mcp) echo 401; return 0 ;;
    esac; done; echo 000
  }
  curl_auth() {
    local a; for a in "$@"; do case "$a" in
      */v1/messages) echo "${SG_MSG:-200}"; return 0 ;;
      */v1/embeddings) echo 200; return 0 ;;
      */mcp) printf '{"tools":[{"name":"search_knowledge"}]}\n'; return 0 ;;
    esac; done; echo 000
  }
  litellm_key_status() { case "$1" in sk-o) echo "${SG_KEY_O:-200}" ;; *) echo 200 ;; esac; }
  _test_portal() { _sg_group portal "${SG_PORTAL:-}"; }
  stt_test_checks() { _sg_group stt "${SG_STT:-}"; }
  terminal_test_checks() { _sg_group terminal "${SG_TERMINAL:-}"; }
  projects_test_checks() { _sg_group projects "${SG_PROJECTS:-}"; }
  code_test_checks() { _sg_group code "${SG_CODE:-}"; }
}
_sg_group() {
  local w a
  echo "start $1" >> "$TMP/order"
  while read -r w a; do
    case "$w" in
      ok) _check "$1: $a" x x ;;
      fail) _check "$1: $a" got want ;;
      slow) _check "$1: $a" "couldn't check (timed out after 20 s)" want ;;
      warn) warn "$1: $a" ;;
      die) die "$1: $a" ;;
      sleep) sleep "$a" ;;
      child) sh -c 'sleep "$1"; echo "child-end $2" >> "$3"' _ "$a" "$1" "$TMP/order" ;;
      false) false ;;
    esac
  done <<EOF
$2
EOF
  echo "end $1" >> "$TMP/order"
}

# _sg_run FUNC — FUNC's stdout, stderr, status and counts, in a subshell (smoke_slow_ok as cmd_test's first pass sets it)
_sg_run() {
  ( fails=0; slow=0; slow_list=''; smoke_slow_ok=1; PROBE_LONGER=''
    "$1" > "$TMP/run.out" 2> "$TMP/run.err"; rc=$?
    printf 'rc=%s fails=%s slow=%s\n[%s]\n' "$rc" "$fails" "$slow" "$slow_list"
    printf -- '--- out\n'; cat "$TMP/run.out"; printf -- '--- err\n'; sed 's/\x1b\[[0-9;]*m//g' "$TMP/run.err" )
}

_sg_same() {
  local o n
  o="$(_sg_run old_test_checks)"; n="$(_sg_run _test_checks)"
  [ "$o" = "$n" ] && return 0
  printf '%s: old and new differ\n--- old\n%s\n--- new\n%s\n' "$1" "$o" "$n" >&2
  return 1
}

test_the_groups_say_and_count_what_they_said_one_after_the_other() {
  _sg_setup
  local bad=0
  _sg_same "all pass" || bad=1
  SG_PORTAL=$'ok login page\nok chat loads' SG_STT='ok voice' SG_TERMINAL=$'ok gateway\nok sandbox' SG_PROJECTS='ok folder' SG_CODE=$'ok unlock\nok previews' \
    _sg_same "every group" || bad=1
  SG_KEY_O=401 SG_PORTAL=$'ok login page\nfail chat loads' SG_CODE=$'fail unlock\nok previews' SG_STT='fail voice' \
    _sg_same "failures in four groups" || bad=1
  SG_MSG=000 SG_TERMINAL=$'slow gateway\nok sandbox' SG_CODE=$'slow previews\nslow unlock' SG_PROJECTS='slow folder' \
    _sg_same "slow in three groups" || bad=1
  SG_PORTAL=$'warn a warning\nok login page' SG_STT=$'warn voice falls back\nok voice' SG_CODE='warn code says' \
    _sg_same "warnings" || bad=1
  SG_ALIVE=000 SG_TERMINAL=$'slow gateway\nfail sandbox' SG_STT='slow voice' _sg_same "slow and failed" || bad=1
  return "$bad"
}

test_the_groups_run_side_by_side_the_projects_first_and_speech_to_text_last() {
  _sg_setup
  local t0 t1
  # (what every dc call makes sure of first: once, before any group)
  localgit_sso_ensure() { echo ensure >> "$TMP/order"; }
  t0=$SECONDS
  SG_PORTAL='sleep 3' SG_TERMINAL='sleep 3' SG_CODE='sleep 3' SG_STT='sleep 1' _sg_run _test_checks > /dev/null
  t1=$SECONDS
  # (one after the other: 10 s; side by side about 4)
  [ $((t1 - t0)) -le 7 ] || { echo "the groups took $((t1 - t0)) s: not side by side" >&2; return 1; }
  # the projects' first and alone, speech-to-text's once every other group has ended
  assert_eq "$(sed -n 1,3p "$TMP/order" | tr '\n' ' ')" "ensure start projects end projects "
  assert_eq "$(grep -c ensure "$TMP/order")" 1
  assert_eq "$(awk '/^start stt$/ { print NR }' "$TMP/order")" 10
  assert_eq "$(sed -n 1,9p "$TMP/order" | grep -c '^end ')" 4
}

test_a_term_or_a_ctrl_c_ends_the_groups_with_what_they_started() {
  _sg_setup
  local sig pid
  mkdir -p "$TMP/t"
  for sig in TERM INT; do
    : > "$TMP/order"
    # (the checks in a process group of their own, in front, as setup is: a terminal's Ctrl-C goes to that group, the
    # helper's TERM too)
    set -m
    ( fails=0; slow=0; slow_list=''; SG_PORTAL='child 3' SG_TERMINAL='child 3' SG_CODE='child 3' SG_STT='ok voice' \
        TMPDIR="$TMP/t" _test_checks > /dev/null 2>&1 ) &
    pid=$!
    set +m
    sleep 1
    kill -"$sig" -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 4
    assert_eq "$(grep -c '^start ' "$TMP/order")" 4   # (projects, portal, terminal, code: not speech-to-text)
    assert_eq "$(grep -c 'end' "$TMP/order")" 1      # (the projects' only: no group, and no program one started, went on)
    assert_eq "$(find "$TMP/t" -mindepth 1 | wc -l | tr -d ' ')" 0
  done
}

test_a_group_that_dies_ends_the_checks_with_its_words_said_once() {
  _sg_setup
  local out
  mkdir -p "$TMP/t"
  # (setup's own hooks are on_exit's, as this one)
  _sg_msg() { printf '\nmsg=[%s]\n' "${_BN_DIE_MSG:-}"; }
  out="$( ( on_exit _sg_msg
    fails=0; slow=0; slow_list=''; smoke_slow_ok=1
    SG_PORTAL='ok login page' SG_CODE=$'ok unlock\ndie no portal secret' SG_TERMINAL='ok gateway' TMPDIR="$TMP/t" _test_checks 2>&1
    echo "after rc=$?" ) )" || true
  assert_eq "$(find "$TMP/t" -mindepth 1 | wc -l | tr -d ' ')" 0
  assert_contains "$out" "msg=[code: no portal secret]"
  assert_not_contains "$out" "after rc="
  assert_eq "$(printf '%s\n' "$out" | grep -c 'code: no portal secret')" 2   # (said once, plus the trap's line)
  # (the other groups were said, in their order)
  assert_contains "$out" "  ok    portal: login page"
  assert_contains "$out" "  ok    terminal: gateway"
  assert_contains "$out" "  ok    code: unlock"
}

test_a_group_that_ends_early_counts_as_a_failure() {
  _sg_setup
  local out
  # (set -e, as setup runs: a check that stops its group with a status)
  out="$( ( set -e; fails=0; slow=0; slow_list=''; smoke_slow_ok=1
    SG_PROJECTS=$'ok folder\nfalse\nok never' _test_checks; echo "fails=$fails" ) 2>&1 )"
  assert_contains "$out" "  ok    projects: folder"
  assert_not_contains "$out" "projects: never"
  assert_contains "$out" "  FAIL  the projects checks ended before they were done"
  assert_contains "$out" "fails=1"
}

test_the_checks_wait_for_their_own_groups_only_and_leave_nothing() {
  _sg_setup
  local n
  mkdir -p "$TMP/t"
  # (a job of the shell that runs the checks, as setup has: never waited for)
  n="$( ( sleep 6 & bg=$!; t0=$SECONDS; fails=0; slow=0; slow_list=''
    TMPDIR="$TMP/t" _test_checks > /dev/null 2>&1; echo $((SECONDS - t0)); kill "$bg" 2>/dev/null || true ) )"
  [ "$n" -lt 5 ] || { echo "the checks waited for a job of their caller's ($n s)" >&2; return 1; }
  assert_eq "$(find "$TMP/t" -mindepth 1 | wc -l | tr -d ' ')" 0
}

test_a_group_leaves_the_list_once_it_was_waited_for() {
  _sg_setup
  # (_test_checks_stop signals only groups not waited for yet: while the second is waited for, the first is not listed)
  local log="$TMP/waits" a b
  ( wait() { echo "${_TC_PIDS:-}" >> "$log"; builtin wait "$@"; }
    _TC_PIDS=''; fails=0; slow=0; slow_list=''; d="$TMP/g"; mkdir -p "$d"
    _test_group "$d" one true; a=$!; _test_group "$d" two true; b=$!
    printf '%s %s\n' "$a" "$b" > "$TMP/pids"; _test_wait; echo "after [${_TC_PIDS:-}]" >> "$log" )
  read -r a b < "$TMP/pids"
  assert_eq "$(sed -n 1p "$log" | tr -s ' ' | sed 's/^ //')" "$a $b"
  assert_eq "$(sed -n 2p "$log")" "$b"
  assert_eq "$(sed -n 3p "$log")" "after []"
}

test_a_groups_exit_hooks_are_its_own() {
  _sg_setup
  # (setup's hooks, the stack lock's among them, never run when a group ends; a group's own do)
  _sg_parent_hook() { echo parent >> "$TMP/hooks"; }
  _sg_group_hook() { echo group >> "$TMP/hooks"; }
  code_test_checks() { on_exit _sg_group_hook; _check "code: unlock" x x; }
  : > "$TMP/hooks"
  ( on_exit _sg_parent_hook; fails=0; slow=0; slow_list=''; _test_checks > /dev/null 2>&1; echo checked >> "$TMP/hooks" )
  assert_eq "$(tr '\n' ' ' < "$TMP/hooks")" "group checked parent "
}

test_bashs_setpgid_line_on_the_way_into_the_background_is_not_said_its_other_words_are() {
  _sg_setup
  # JON-1432: bash 3.2 on macOS now and then says "child setpgid (N to N): Operation not permitted" as a group goes into
  # the background, before the group's own 2> applies: on the caller's stderr, so setup's and Update now's output. The
  # group is in its own process group all the same. 3000 groups that end at once say it a few times (most runs) where
  # this bash does; where it never does, this passes without telling anything.
  local i=0 err
  err="$( ( _TC_PIDS=''; fails=0; slow=0; slow_list=''; d="$TMP/g"; mkdir -p "$d"
    while [ "$i" -lt 3000 ]; do
      _test_group "$d" "g$i" true; i=$((i + 1))
      [ $((i % 50)) -ne 0 ] || _test_wait
    done
    _test_wait ) 2>&1 >/dev/null )"
  assert_not_contains "$err" "setpgid"
  # what bash says then, but that line, is said (a fork retry, say), on stderr
  printf 'x: child setpgid (41 to 41): Operation not permitted\nx: fork: retry: Resource temporarily unavailable\n' > "$TMP/f.fork"
  assert_eq "$(_test_fork_said "$TMP/f.fork" 2>&1 >/dev/null)" "x: fork: retry: Resource temporarily unavailable"
  assert_eq "$(_test_fork_said "$TMP/f.fork" 2>/dev/null)" ""
  assert_eq "$(_test_fork_said "$TMP/none.fork" 2>&1)" ""
}
