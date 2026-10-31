# shellcheck shell=bash
# shellcheck disable=SC2010  # ls | grep -c over our own temp files (plain names)
test_set_env_creates_file_with_mode_600() {
  set_env FOO bar
  assert_eq "$(get_env FOO)" "bar"
  assert_eq "$(ls -l "$ENV_FILE" | cut -c1-10)" "-rw-------"
}

test_set_env_replaces_existing_key_once() {
  printf 'FOO=old\nFOOBAR=keep\nFOO=dupe\n' > "$ENV_FILE"
  set_env FOO new
  assert_eq "$(grep -c '^FOO=' "$ENV_FILE")" "1"
  assert_eq "$(get_env FOO)" "new"
  assert_eq "$(get_env FOOBAR)" "keep"
}

test_set_env_preserves_special_characters() {
  # Backslashes pass through `docker compose --env-file` literally in unquoted values (verified).
  set_env SECRET 'a+b/c=d&f\g@x.y'
  assert_eq "$(get_env SECRET)" 'a+b/c=d&f\g@x.y'
}

test_set_env_accepts_aws_style_secret() {
  set_env AWS_SECRET_ACCESS_KEY 'a+b/c=d'
  assert_eq "$(get_env AWS_SECRET_ACCESS_KEY)" 'a+b/c=d'
}

test_set_env_rejects_compose_unsafe_values() {
  for v in 'a$b' 'a"b' "a'b" 'a`b' 'a #b' "$(printf 'a\t#b')" ' lead' 'trail ' "$(printf 'tab\t')"; do
    if ( set_env BAD "$v" ) 2>"$TMP/err"; then echo "accepted: [$v]" >&2; return 1; fi
    assert_contains "$(cat "$TMP/err")" "BAD"
  done
  assert_eq "$(get_env BAD)" ""
}

test_set_env_cleans_up_tmp_on_failure() {
  set_env A 1
  if ( mv() { return 1; }; set_env A 2 ) 2>/dev/null; then return 1; fi
  assert_eq "$(get_env A)" "1"
  assert_eq "$(ls -A "$TMP" | grep -c '^\.env\.' || true)" "0"
}

test_get_env_missing_key_is_empty() {
  assert_eq "$(get_env NOPE)" ""
}

test_ensure_env_does_not_overwrite() {
  set_env KEEP one
  ensure_env KEEP two
  ensure_env NEW three
  assert_eq "$(get_env KEEP)" "one"
  assert_eq "$(get_env NEW)" "three"
}

test_json_get_extracts_exact_field() {
  out="$(printf '%s' '{"key_alias":"claude-code","key":"sk-abc123","token":"t"}' | json_get key)"
  assert_eq "$out" "sk-abc123"
}

test_gen_hex_length() {
  assert_eq "$(gen_hex 16 | tr -d '\n' | wc -c | tr -d ' ')" "32"
}

test_json_get_returns_first_occurrence() {
  out="$(printf '%s' '{"key":"sk-first","metadata":{"key":"second"}}' | json_get key)"
  assert_eq "$out" "sk-first"
}

test_json_get_does_not_match_suffix_field() {
  out="$(printf '%s' '{"api_key":"nope","key":"yes"}' | json_get key)"
  assert_eq "$out" "yes"
}

test_valid_region() {
  valid_region us-east-1
  valid_region eu-west-2
  if valid_region ''; then return 1; fi
  if valid_region 'us-east-1;rm'; then return 1; fi
  if valid_region 'US-EAST-1'; then return 1; fi
  if valid_region 'a/b'; then return 1; fi
}

test_restore_caller_locale_unsets_when_caller_had_none() {
  out="$(env -u LC_ALL -u _CALLER_LC_ALL_CAPTURED "$BASH" -c '. lib/common.sh; printf "%s|" "$LC_ALL"; restore_caller_locale; printf "%s" "${LC_ALL+set}"')"
  assert_eq "$out" "C|"
}

test_restore_caller_locale_restores_callers_value() {
  out="$(env -u _CALLER_LC_ALL_CAPTURED LC_ALL=en_US.UTF-8 "$BASH" -c '. lib/common.sh; printf "%s|" "$LC_ALL"; restore_caller_locale; printf "%s" "$LC_ALL"')"
  assert_eq "$out" "C|en_US.UTF-8"
}

# A piped awk that exits at its first match can kill the command writing into it with SIGPIPE, which pipefail makes a
# failure — at random (it depends on how far the writer got): a settings check once failed 1 run in ~40 that way.
# Lookups read to the end instead ('!f && … { print; f = 1 }'); an awk reading a file of its own may still exit.
test_piped_awk_lookups_never_exit_early() {
  local hits
  hits="$(grep -nE '(^|[^|])\|[^|]*awk [^|]*(\{|;) *exit *\}' "$T_ROOT"/lib/*.sh "$T_ROOT/stack" "$T_ROOT/setup.sh" 2>/dev/null || true)"
  assert_eq "$hits" ""
  # what it guards against, once for real: under pipefail the first match wins and nothing fails
  ( set -o pipefail; v="$(seq 1 200000 | awk '!f && $1 == 3 { print; f = 1 }')"; [ "$v" = 3 ] )
}

# The same with grep -q, which ends at its first match: an e2e check failed that way once (its probe's claude line
# matched, then the writer got SIGPIPE). A piped grep reads to the end ('grep PAT >/dev/null'); grep -f - reads its
# patterns to the end.
test_piped_greps_never_end_early() {
  local hits
  hits="$(grep -nE '(^|[^|])\|[[:space:]]*([A-Z_]+=[^ ]* +)*grep( +-[a-zA-Z]+)* +-[a-zA-Z]*q' "$T_ROOT"/lib/*.sh "$T_ROOT/stack" \
    "$T_ROOT/setup.sh" "$T_ROOT"/tests/e2e/*.sh 2>/dev/null | grep -v -- ' -f - ' || true)"
  assert_eq "$hits" ""
  ( set -o pipefail; seq 1 200000 | grep -x 3 >/dev/null )
}

# A regex's count above 255 (RE_DUP_MAX on macOS: {1,400}) does not compile there, so [[ =~ ]] is false for every value
test_shell_regexes_never_count_above_255() {
  local hits
  hits="$(grep -nE '\{[0-9]*,?(2[6-9][0-9]|25[6-9]|[3-9][0-9]{2}|[0-9]{4,})\}' "$T_ROOT"/lib/*.sh "$T_ROOT/stack" "$T_ROOT/setup.sh" \
    "$T_ROOT"/tests/e2e/*.sh 2>/dev/null | grep -E '=~|grep -[a-zA-Z]*E' || true)"
  assert_eq "$hits" ""
  ! [[ x =~ ^x{1,400}$ ]] || [ "$(uname -s)" != Darwin ]
}

# macOS's bash 3.2 ends "$(case X in a) …" at the pattern's ")": what runs is "case X in a", and the rest is text
test_no_case_inside_a_command_substitution() {
  local hits
  hits="$(grep -nE '\$\(case ' "$T_ROOT"/lib/*.sh "$T_ROOT/stack" "$T_ROOT/setup.sh" "$T_ROOT"/bin/* "$T_ROOT"/tests/e2e/*.sh 2>/dev/null || true)"
  assert_eq "$hits" ""
}

test_every_test_runs_with_a_home_of_its_own() {
  # tests/run.sh: setup (the Code page's ~/bedrock-now-workspace) or devos-claude (~/.claude-bedrock) run by a test
  # must never reach your real home folder
  case "$HOME" in "$TMP"/*) ;; *) echo "HOME is $HOME, not under $TMP" >&2; return 1 ;; esac
  [ -d "$HOME" ] || return 1
}

# _with_deadline: a watchdog on this computer (a timeout inside the sandbox binds nothing there)
test_with_deadline_passes_a_quick_command_through() {
  local rc=0 out
  out="$(_with_deadline 5 sh -c 'echo out; echo err >&2; exit 3' 2>"$TMP/err")" || rc=$?
  assert_eq "$rc" 3
  assert_eq "$out" out
  assert_eq "$(cat "$TMP/err")" err
  out="$(_with_deadline 5 sh -c 'cat; echo done')"   # (stdin: /dev/null — never the caller's)
  assert_eq "$out" done
}

test_with_deadline_ends_a_command_that_ignores_term_and_all_it_started() {
  local rc=0 t0 out p c
  t0="$(date +%s)"
  out="$(_with_deadline 1 sh -c 'echo $$ > "$1/leader"; sleep 30 & echo $! > "$1/child"; trap "" TERM; echo started; wait' sh "$TMP")" || rc=$?
  assert_eq "$rc" 124
  assert_eq "$out" started
  [ "$(( $(date +%s) - t0 ))" -le 8 ] || { echo "took $(( $(date +%s) - t0 )) s" >&2; return 1; }
  p="$(cat "$TMP/leader")"; c="$(cat "$TMP/child")"
  sleep 0.3
  if kill -0 "$p" 2>/dev/null || kill -0 "$c" 2>/dev/null; then echo "left running: $p $c" >&2; return 1; fi
}

test_with_deadline_ends_a_stopped_function_too() {
  # (a sandbox process can SIGSTOP a probe: the watchdog here is not inside it)
  local rc=0 t0
  hang() { sh -c 'echo $$ > "$1/stopped"; kill -STOP $$' sh "$TMP"; }
  t0="$(date +%s)"
  _with_deadline 1 hang || rc=$?
  assert_eq "$rc" 124
  [ "$(( $(date +%s) - t0 ))" -le 8 ] || return 1
  sleep 0.3
  ! kill -0 "$(cat "$TMP/stopped")" 2>/dev/null || { echo "a stopped process left" >&2; return 1; }
  assert_eq "$(_probe sh -c 'echo fine')" fine
  PROBE_DEADLINE_S=1
  assert_eq "$(_probe hang)" "couldn't check (timed out after 1 s)"
}

test_with_deadline_writes_only_in_a_folder_of_its_own() {
  # (its marker lives in a fresh mktemp -d folder, mode 700: a link planted in a shared temporary folder is never
  # followed; nothing is left behind)
  local t="$TMP/tmpdir" mode rc=0
  mkdir -p "$t"; printf 'precious\n' > "$TMP/target"
  for n in bn-deadline.fired bn-deadline.XXXXXX fired; do ln -s "$TMP/target" "$t/$n"; done
  mode="$(TMPDIR="$t" _with_deadline 5 sh -c 'for d in "$TMPDIR"/bn-deadline.*/; do stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d"; done')"
  assert_eq "$mode" 700
  TMPDIR="$t" _with_deadline 1 sleep 10 || rc=$?
  assert_eq "$rc" 124
  assert_eq "$(cat "$TMP/target")" precious
  assert_eq "$(find "$t" -name 'bn-deadline.*' -type d | grep -c . || true)" 0
}

# No rm takes an unquoted expansion ($X, ${X}, $(…)) in ./stack's scripts: split on spaces and globbed, such an
# argument removes other files when a path has a space in it — a checkout under "Code Projects" and a folder "Code"
# beside it (tests/rm_scan.py: what it reads as code, trap strings included). First the scanner on cases of each kind.
test_no_rm_takes_an_unquoted_expansion() {
  command -v python3 >/dev/null 2>&1 || return 77
  local f files=() out
  # shellcheck disable=SC2016  # the cases are shell text
  # (one finding a line: rm and its other names, behind wrappers or a bare eval, xargs … rm without -0 or -d, a
  # removing find with an unquoted path or an -exec rm with an unquoted argument, and each inside trap, eval, sh -c and
  # bash -c strings)
  printf '%s\n' 'rm -rf $X' 'rm -f ${X}' 'rm -rf $(ls)' 'x=$(rm -f $y)' '[ -z "$x" ] || rm -rf $x' 'rm -f "$a" ${b:+"$b"}' \
    "trap 'rm -rf \${T:-}; exit' TERM" 'trap "rm -f \$late" INT' \
    '\rm -rf $X' '/bin/rm -f ${X}' '/usr/bin/rm -rf $(ls)' 'env LC_ALL=C rm -f $y' \
    'find . -name x | xargs rm -f' 'printf "%s\n" "$a" | xargs -r rm -f --' \
    "find \$dir -name '*.tmp' -delete" 'find $dir -type f -exec rm -f {} \;' \
    'eval "rm -rf $x"' 'sh -c "rm -f $f"' "bash -c 'rm -rf \$1' _ \"\$p\"" \
    'find "$d" -exec rm -rf $X \;' 'eval rm -rf $X' 'nice -n 5 rm -f $x' 'timeout 10 rm -rf $x' 'busybox rm -rf $x' \
    'command rm -f $x' 'sudo -u root rm -rf $x' 'exec rm -f $x' > "$TMP/bad.sh"
  # shellcheck disable=SC2016
  printf '%s\n' 'rm -f "$a" "${b}" -- "$(c)"' 'rm -rf -- "$d"' 'docker rm -f $ids' 'echo "docker volume rm $vols"' \
    '# rm -rf $comment' 'rm -f /tmp/x.$$' 'trap "rm -f $q; kill -INT \$\$" INT' 'cat <<EOF' 'rm -rf $text' 'EOF' 'done <<< "$plan"' \
    'rm -f "$z"' '\rm -rf -- "$X"' 'env LC_ALL=C rm -f "$y"' 'find . -name x -print0 | xargs -0 rm -f' \
    "printf '%s\\n' \"\$a\" | xargs -d '\\n' rm -f --" "find \"\$dir\" -name '*.tmp' -delete" 'find "$dir" -type f -exec rm -f {} \;' \
    'find $dir -name x -print' 'eval "rm -rf \"\$x\""' "sh -c 'rm -f \"\$1\"' _ \"\$f\"" \
    'find "$d" -exec rm -rf "$X" \;' 'find "$d" -exec rm -rf {} +' 'nice -n 5 rm -f "$x"' 'timeout 10 rm -rf "$x"' \
    'busybox rm -rf "$x"' 'command rm -f "$x"' 'sudo -u root rm -rf "$x"' 'exec rm -f "$x"' 'timeout 5 docker rm -f $ids' > "$TMP/good.sh"
  out="$(python3 -I "$T_ROOT/tests/rm_scan.py" "$TMP/bad.sh")" || true
  assert_eq "$(printf '%s\n' "$out" | grep -c .)" "$(grep -c . "$TMP/bad.sh")"
  python3 -I "$T_ROOT/tests/rm_scan.py" "$TMP/good.sh"
  for f in "$T_ROOT"/lib/*.sh "$T_ROOT"/stack "$T_ROOT"/install.sh "$T_ROOT"/setup.sh "$T_ROOT"/bin/* "$T_ROOT"/terminal/bin/*; do
    [ -f "$f" ] && head -n 1 "$f" | grep -qE '^#!.*sh|shellcheck shell=' && files+=("$f")
  done
  [ "${#files[@]}" -gt 30 ]
  out="$(python3 -I "$T_ROOT/tests/rm_scan.py" "${files[@]}")" || { printf 'rm with an unquoted expansion:\n%s\n' "$out" >&2; return 1; }
}

# --- the old name's environment, for one release: BEDROCK_NOW_X becomes DEVOS_ADE_X when that is unset ---

test_env_fallback_takes_the_old_name_when_the_new_one_is_unset() {
  local out
  # (the vars are set in the subshell's environment with export, then the function runs)
  out="$( (unset DEVOS_ADE_CODE_UPDATED DEVOS_ADE_LOCK_HELD
    export BEDROCK_NOW_CODE_UPDATED=1 BEDROCK_NOW_LOCK_HELD=4242; env_fallback_old_names
    printf '%s|%s|%s' "${DEVOS_ADE_CODE_UPDATED-unset}" "${DEVOS_ADE_LOCK_HELD-unset}" "${BEDROCK_NOW_LOCK_HELD-gone}") )"
  assert_eq "$out" "1|4242|gone"
  # exported: a child process sees it
  assert_eq "$( (export BEDROCK_NOW_VERBOSE=1; unset DEVOS_ADE_VERBOSE; env_fallback_old_names; env | grep '^DEVOS_ADE_VERBOSE=') )" "DEVOS_ADE_VERBOSE=1"
}

test_env_fallback_never_overrides_a_new_name_even_an_empty_one() {
  assert_eq "$( (export BEDROCK_NOW_NO_OPEN=1 DEVOS_ADE_NO_OPEN=0; env_fallback_old_names; printf '%s' "$DEVOS_ADE_NO_OPEN") )" "0"
  assert_eq "$( (export BEDROCK_NOW_NO_OPEN=1 DEVOS_ADE_NO_OPEN=; env_fallback_old_names; printf '[%s]' "$DEVOS_ADE_NO_OPEN") )" "[]"
}

test_env_fallback_leaves_other_names_and_runs_in_stack_first() {
  assert_eq "$( (export BEDROCK_NOWHERE=1 BEDROCK_NOW=2; unset DEVOS_ADE_WHERE; env_fallback_old_names; printf '%s|%s' "${DEVOS_ADE_WHERE-unset}" "${BEDROCK_NOWHERE-gone}") )" "unset|1"
  assert_contains "$(cat "$T_ROOT/stack")" "env_fallback_old_names"
}
