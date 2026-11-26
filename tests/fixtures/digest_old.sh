# shellcheck shell=bash
# upd_hash and _upd_sum as they were before .env was read once a digest (v0.68.11 candidate 968150cc, lib/steps.sh), as
# old_*: tests/test_digest_identity.sh compares them with the new ones. Generated from git; not edited by hand.
old_upd_sum() { openssl dgst -sha256 2>/dev/null | awk '{ print $NF }'; }
old_upd_hash() {
  local t h t0=''
  [ -z "$_UPD_PROF" ] || t0="$(_ms_now)"
  t="$(mktemp)" || return 1
  { printf 'v1 %s %s\n' "$(project_name)" "$STACK_DIR"; "upd_in_$1" || true; } > "$t" 2>/dev/null
  h="$(old_upd_sum < "$t")"
  ! upd_trace_on || _upd_trace "${UPD_TRACE_ROLE:-note}" "$1" "$t"
  rm -f "$t"
  [ -z "$t0" ] || _upd_prof_digest "$t0" "$1"
  printf '%s\n' "$h"
}
