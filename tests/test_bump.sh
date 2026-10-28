# shellcheck shell=bash
. "$STACK_DIR/lib/commands.sh"
# bin/bump-core-services: the maintainer's bump tool, against faked GitHub / registry answers (no network).
# The cases are in tests/test_bump_core_services.py (Python unittest); this runs them in the suite.

test_bump_core_services_unit_tests_pass() {
  command -v python3 >/dev/null 2>&1 || { echo "python3 is not installed" >&2; return 77; }
  local out
  out="$(python3 -I "$STACK_DIR/tests/test_bump_core_services.py" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  assert_contains "$out" "OK"
}

test_bump_core_services_check_shape_and_help() {
  command -v python3 >/dev/null 2>&1 || return 77
  assert_contains "$(python3 -I "$STACK_DIR/bin/bump-core-services" --help)" "--check"
  [ -x "$STACK_DIR/bin/bump-core-services" ] || { echo "bin/bump-core-services is not executable" >&2; return 1; }
}

# every pin the tool rewrites is a digest pin now, and the manifest names the services ./stack versions lists
test_core_service_pins_all_carry_a_digest() {
  local id ref
  for id in postgres rustfs rustfs-init litellm open-webui searxng caddy; do
    ref="$(compose_service_image "$id")"
    case "$ref" in *@sha256:????????????????????????????????????????????????????????????????) ;; *) echo "$id: pin has no digest: $ref" >&2; return 1 ;; esac
  done
}
