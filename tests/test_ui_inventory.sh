# shellcheck shell=bash
# The UI control inventory and its diff between releases (JON-869): the cases are in tests/test_ui_inventory.py (unittest).

test_ui_inventory_unit_tests_pass() {
  command -v python3 >/dev/null 2>&1 || { echo "python3 is not installed" >&2; return 77; }
  local out
  out="$(python3 -I "$STACK_DIR/tests/test_ui_inventory.py" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  assert_contains "$out" "OK"
}
