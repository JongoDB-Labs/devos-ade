# shellcheck shell=bash
# shellcheck disable=SC2329  # stubs are called by the code under test
# JON-972: an update digest (lib/steps.sh upd_hash) reads .env once (_env_snap, as dc does), and _upd_sum runs no awk.
# tests/fixtures/digest_old.sh keeps both as they were, as old_*; each case computes every step's digest old and new on
# the same .env, files and Docker answers, and compares them byte for byte: a digest that changed would run its step again
# on the first update after the release, or skip one that should run.
. "$STACK_DIR/lib/commands.sh"
. "$STACK_DIR/tests/fixtures/digest_old.sh"

_dg_setup() {
  dc() { case "$*" in "ps -q litellm open-webui") printf 'c1\nc2\n' ;; "ps -q code terminal") echo k1 ;; "ps -q forgejo") echo f1 ;; esac; return 0; }
  docker() { case "$1 $2" in "inspect --format") printf '/p-litellm-1 L1 2026-11-01T10:00:00Z\n/p-open-webui-1 O1 2026-11-01T10:00:00Z\n' ;; "volume inspect") echo 2026-10-01T09:00:00Z ;; *) return 1 ;; esac; }
  snapshot_refs() { printf 'P1\t%s/portal:local\nS1\t%s/stt:local\n' "$(project_name)" "$(project_name)"; }
  mkdir -p "$TMP/ws" "$STATE_DIR"
  _DG_STEPS="settings aws prices litellm_config defaults voice stt_service keys setupkey signin syncs searxng gitserver gitafter websearch smoke codedefault"
}

# the .env cases: the terminal, Code page and git server on (compose's overlays, their get_env), the built-in search; a
# name given twice (the last wins), "==", a CR, a name with a dash, a blank value, a key in a comment, an indented key, a
# last line without its newline; and each without the terminal
_dg_envs() {
  local base
  base="$(printf 'COMPOSE_PROJECT_NAME=dg\nLITELLM_PORT=4000\nAWS_REGION_NAME=us-east-1\nLITELLM_KEY_SETUP=sk-a\nLITELLM_KEY_CLAUDE_CODE=sk-b\nOPENWEBUI_API_KEY=sk-d\nLITELLM_DB_ADMIN_READY=true\nWEBSEARCH_BACKEND=auto\nPRICE_UPDATES=true\nSTT_PROVIDER=bedrock')"
  printf '%s\nTERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\nTERMINAL_EGRESS=internet\nLOCALGIT=on\n\0' "$base" "$TMP/ws"
  printf '%s\nTERMINAL_ENABLED=false\nTERMINAL_WORKSPACE=\nCODE_ENABLED=true\nLOCALGIT=off\nWEBSEARCH_SEARXNG_BUILTIN=off\n\0' "$base"
  printf '%s\nAWS_REGION_NAME=eu-west-1\nLITELLM_PORT==4001\nSTT_PROVIDER=openai\r\nA-B=1\nREMOTE_MODE=\n# TERMINAL_ENABLED=true\n  CODE_ENABLED=false\nTERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCOMPOSE_PROJECT_NAME=dg2' "$base" "$TMP/ws"
  printf '\0'
}

# _dg_same LABEL — every step's digest, old and new, on .env as it is now: the same, and the same status
_dg_same() {
  local s o n bad=0
  for s in $_DG_STEPS; do
    # (a stale AWS check or price list adds $RANDOM, so that its step runs: the same seed for both)
    o="$(RANDOM=7; old_upd_hash "$s"; printf 'rc=%s' "$?")"; n="$(RANDOM=7; upd_hash "$s"; printf 'rc=%s' "$?")"
    [ "$o" = "$n" ] || { printf '%s: digest of %s differs: old [%s], new [%s]\n' "$1" "$s" "$o" "$n" >&2; bad=1; }
    case "$n" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) printf '%s: %s gave no digest: [%s]\n' "$1" "$s" "$n" >&2; bad=1 ;; esac
  done
  return "$bad"
}

test_every_digest_is_what_it_was() {
  _dg_setup
  local e i=0 bad=0
  while IFS= read -r -d '' e; do
    i=$((i + 1)); printf '%s' "$e" > "$ENV_FILE"; _dg_same "env $i" || bad=1
  done < <(_dg_envs)
  # (no .env; one that cannot be read; a folder where it would be)
  rm -f "$ENV_FILE"; _dg_same "no .env" || bad=1
  if [ "$(id -u)" != 0 ]; then printf 'TERMINAL_ENABLED=true\n' > "$ENV_FILE"; chmod 000 "$ENV_FILE"; _dg_same "unreadable .env" || bad=1; chmod 600 "$ENV_FILE"; fi
  rm -f "$ENV_FILE"; mkdir "$ENV_FILE"; _dg_same ".env a folder" || bad=1; rmdir "$ENV_FILE"
  return "$bad"
}

test_a_digest_reads_env_once() {
  _dg_setup
  local n="$TMP/reads"
  _dg_envs | { IFS= read -r -d '' e; printf '%s' "$e"; } > "$ENV_FILE"
  # (get_env's own awk, by its program; _upd_keys' one awk for the five keys is not one)
  awk() { case "${1:-}" in 'index($0, ENVIRON["K"] "=") == 1'*) echo x >> "$n" ;; esac; command awk "$@"; }
  : > "$n"; old_upd_hash smoke > /dev/null; local old_n; old_n="$(wc -l < "$n" | tr -d ' ')"
  : > "$n"; upd_hash smoke > /dev/null; local new_n; new_n="$(wc -l < "$n" | tr -d ' ')"
  [ "$old_n" -ge 10 ] || { echo "the old digest read .env only $old_n times: the test no longer sees what it was for" >&2; return 1; }
  assert_eq "$new_n" 0
}

test_the_snapshot_is_the_digests_alone_and_a_write_in_it_is_read() {
  _dg_setup
  printf 'COMPOSE_PROJECT_NAME=dg\nX_ONE=1\n' > "$ENV_FILE"
  # (an input that writes .env in the middle: it reads what it wrote, old and new)
  upd_in_dgw() { get_env X_ONE; echo; set_env X_ONE 2; get_env X_ONE; echo; }
  local o n
  o="$(old_upd_hash dgw)"; printf 'COMPOSE_PROJECT_NAME=dg\nX_ONE=1\n' > "$ENV_FILE"; n="$(upd_hash dgw)"
  assert_eq "$n" "$o"
  # (called directly, not in $( ): nothing of it is left in this shell; a later get_env reads the file as it is then)
  printf 'COMPOSE_PROJECT_NAME=dg\nX_ONE=1\n' > "$ENV_FILE"
  upd_hash settings > /dev/null
  assert_eq "${_dc_env_snap:-unset}" unset
  printf 'COMPOSE_PROJECT_NAME=dg\nX_ONE=3\n' > "$ENV_FILE"
  assert_eq "$(get_env X_ONE)" 3
}

test_the_sum_is_what_awk_gave() {
  local f="$TMP/in" s bad=0 o n
  printf 'some input\n' > "$f"
  assert_eq "$(_upd_sum < "$f")" "$(old_upd_sum < "$f")"
  assert_eq "$(: | _upd_sum)" "$(: | old_upd_sum)"
  # (what openssl may print: OpenSSL 3, 1.1, LibreSSL, nothing, a failure; and what it never prints, still as awk read it)
  for s in 'SHA2-256(stdin)= 0123abcd' '(stdin)= 0123abcd' '0123abcd' '' '   ' ' x' 'x  ' "$(printf 'a\tb')" "$(printf 'a b\nc d')" "$(printf 'a\rb c')"; do
    openssl() { [ -z "$OS_OUT" ] || printf '%s\n' "$OS_OUT"; return "${OS_RC:-0}"; }
    o="$(OS_OUT="$s" old_upd_sum < "$f"; printf 'rc=%s' "$?")"; n="$(OS_OUT="$s" _upd_sum < "$f"; printf 'rc=%s' "$?")"
    [ "$o" = "$n" ] || { printf '_upd_sum of [%s]: old [%s], new [%s]\n' "$s" "$o" "$n" >&2; bad=1; }
    o="$(OS_OUT="$s" OS_RC=1 old_upd_sum < "$f"; printf 'rc=%s' "$?")"; n="$(OS_OUT="$s" OS_RC=1 _upd_sum < "$f"; printf 'rc=%s' "$?")"
    [ "$o" = "$n" ] || { printf '_upd_sum of [%s], openssl failing: old [%s], new [%s]\n' "$s" "$o" "$n" >&2; bad=1; }
  done
  unset -f openssl
  # (no awk for what openssl prints)
  awk() { echo x >> "$TMP/awk"; command awk "$@"; }
  : > "$TMP/awk"; _upd_sum < "$f" > /dev/null; assert_eq "$(wc -l < "$TMP/awk" | tr -d ' ')" 0
  return "$bad"
}
