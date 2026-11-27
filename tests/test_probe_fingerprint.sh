# shellcheck shell=bash
# JON-1429: the model check's fingerprint follows the CODE of lib/models.sh, not its text, so a comment-only edit does
# not make the next update check the models again. A mark written with the old (whole-file text) fingerprint still counts
# for one release. The files the fingerprint reads live in $TMP/stack: a copy of lib/models.sh the tests edit.
. "$STACK_DIR/lib/commands.sh"

fail() { echo "$*" >&2; exit 1; }   # (each test runs in a subshell of its own)
_pf_setup() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR/litellm" "$STACK_DIR/lib"
  cp "$T_ROOT/lib/models.sh" "$STACK_DIR/lib/models.sh"
  CATALOG="$TMP/models.tsv"; printf 'big\tchat\tbedrock/x\t-\t-\n' > "$CATALOG"
  printf 'services:\n  litellm:\n    image: ghcr.io/berriai/litellm:1.105.0\n' > "$STACK_DIR/compose.yaml"
  printf 'big\n' > "$STACK_DIR/litellm/enabled-models.txt"; printf 'big\tchat\tENABLED\n' > "$STACK_DIR/litellm/probe-results.tsv"
  printf 'AWS_REGION_NAME=us-east-1\nPORTAL_PASSWORD=pw\n' > "$ENV_FILE"
  STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
}
_pf_write_mark() { # _pf_write_mark FINGERPRINT [AGE_S]
  mkdir -p "$(dirname "$(probe_mark_file)")"
  printf 'fingerprint=%s\nat=%s\n' "$1" "$(( $(date +%s) - ${2:-60} ))" > "$(probe_mark_file)"
}

test_a_comment_only_edit_of_models_sh_keeps_the_fingerprint() {
  _pf_setup; a="$(probe_fingerprint)"
  [ -n "$a" ] || fail "no fingerprint"
  printf '# a new comment line on its own\n' >> "$STACK_DIR/lib/models.sh"
  sed -i.bak 's|^\(catalog_rows() {.*\)$|\1   # a trailing comment on a code line|' "$STACK_DIR/lib/models.sh"
  /usr/bin/grep -q 'a trailing comment on a code line' "$STACK_DIR/lib/models.sh" || fail "the test's own edit did not apply"
  assert_eq "$(probe_fingerprint)" "$a"
}
test_a_code_edit_of_models_sh_changes_the_fingerprint() {
  _pf_setup; a="$(probe_fingerprint)"
  sed -i.bak 's|^kind_short() { case "\$1" in embedding) echo embed|kind_short() { case "$1" in embedding) echo embedding|' "$STACK_DIR/lib/models.sh"
  /usr/bin/grep -q 'echo embedding ;;' "$STACK_DIR/lib/models.sh" || fail "the test's own edit did not apply"
  [ "$(probe_fingerprint)" != "$a" ] || fail "a code edit left the fingerprint as it was"
}
test_an_edit_of_a_top_level_assignment_of_models_sh_changes_the_fingerprint() {
  _pf_setup; a="$(probe_fingerprint)"
  sed -i.bak "s|^BEDROCK_APP_LINE='|BEDROCK_APP_LINE='x|" "$STACK_DIR/lib/models.sh"
  [ "$(probe_fingerprint)" != "$a" ] || fail "BEDROCK_APP_LINE is part of the code and changed nothing"
}
test_a_changed_aws_line_changes_the_fingerprint() {
  _pf_setup; a="$(probe_fingerprint)"
  printf 'AWS_REGION_NAME=eu-west-1\nPORTAL_PASSWORD=pw\n' > "$ENV_FILE"
  [ "$(probe_fingerprint)" != "$a" ] || fail "an AWS_ change left the fingerprint as it was"
  printf 'AWS_REGION_NAME=us-east-1\nPORTAL_PASSWORD=other\n' > "$ENV_FILE"
  assert_eq "$(probe_fingerprint)" "$a"   # a line that is not AWS_ changes nothing
}
test_the_caller_s_shell_does_not_change_the_fingerprint() {
  # one bash prints the code, in a clean environment: a terminal's own bash, its exported values and functions, or a
  # stub of a models.sh function in the calling shell change nothing
  _pf_setup; a="$(probe_fingerprint)"
  code="$(probe_models_code)"   # (not piped into grep -q: its early exit would fail the pipe)
  case "$code" in *"kind_short ()"*) ;; *) fail "the code of lib/models.sh was not printed" ;; esac
  b="$(export BEDROCK_APP_LINE=changed; kind_short() { echo stub; }; export -f kind_short; BASH=/nonexistent; probe_fingerprint)"
  assert_eq "$b" "$a"
}
test_a_mark_with_the_new_fingerprint_is_reusable() {
  _pf_setup; _pf_write_mark "$(probe_fingerprint)"
  probe_reusable > /dev/null || fail "refused a mark with today's fingerprint"
}
test_a_mark_with_the_legacy_fingerprint_is_reusable() {
  _pf_setup; _pf_write_mark "$(probe_fingerprint_legacy)"
  probe_reusable > /dev/null || fail "refused a mark with the old whole-file fingerprint"
}
test_a_mark_with_neither_fingerprint_is_refused() {
  _pf_setup; _pf_write_mark "0000000000000000000000000000000000000000000000000000000000000000"
  ! probe_reusable > /dev/null || fail "accepted a mark with an unknown fingerprint"
}
test_a_legacy_mark_keeps_the_age_rules() {
  _pf_setup; _pf_write_mark "$(probe_fingerprint_legacy)" $((9 * 86400))
  ! probe_reusable > /dev/null || fail "a nine day old legacy mark was kept outside an update"
  UPD_MODE=1; probe_reusable > /dev/null || fail "an update refused a nine day old legacy mark"
}
test_probe_mark_writes_the_new_fingerprint() {
  _pf_setup; probe_mark
  assert_eq "$(sed -n 's/^fingerprint=//p' "$(probe_mark_file)")" "$(probe_fingerprint)"
  [ "$(probe_fingerprint)" != "$(probe_fingerprint_legacy)" ] || fail "the new fingerprint equals the legacy one"
}
