# shellcheck shell=bash
# devos-claude and claude-bedrock, its name before v0.28.0 (docs/internal-names.md): the shim (bin/claude-bedrock,
# terminal/bin/claude-bedrock), the ~/.local/bin links setup and ./stack update make (offer_symlink), an update from a
# v0.27.x layout, and uninstall. Every link is made in the test's own home ($TMP/home), never in yours.
. "$STACK_DIR/lib/commands.sh"
REPO="$STACK_DIR"   # (the checkout under test: its real shims)

# _fake_stack -> $TMP/stack with this checkout's shim and a devos-claude that prints its arguments, one a line, reads
# stdin when asked (FAKE_STDIN=1) and ends with FAKE_RC
_fake_stack() {
  HOME="$TMP/home"; STACK_DIR="$TMP/stack"; mkdir -p "$HOME/.local/bin" "$STACK_DIR/bin"
  cp "$REPO/bin/claude-bedrock" "$STACK_DIR/bin/claude-bedrock"
  cat > "$STACK_DIR/bin/devos-claude" <<'EOS'
#!/usr/bin/env bash
printf 'devos-claude %s\n' "$#"; for a in "$@"; do printf '[%s]\n' "$a"; done
[ "${FAKE_STDIN:-0}" != 1 ] || printf 'stdin %s\n' "$(cat)"
exit "${FAKE_RC:-0}"
EOS
  chmod 755 "$STACK_DIR/bin/devos-claude" "$STACK_DIR/bin/claude-bedrock"
  D="$HOME/.local/bin/devos-claude"; O="$HOME/.local/bin/claude-bedrock"
}

# --- the shim ---

test_shim_runs_devos_claude_with_the_same_arguments_and_exit_code() {
  _fake_stack
  local rc
  rc=0; "$STACK_DIR/bin/claude-bedrock" -p 'two words' '' '*' --resume x > "$TMP/out" 2> "$TMP/err" || rc=$?
  assert_eq "$rc" 0
  assert_eq "$(cat "$TMP/out")" "$(printf 'devos-claude 6\n[-p]\n[two words]\n[]\n[*]\n[--resume]\n[x]')"
  assert_eq "$(cat "$TMP/err")" ""   # nothing of its own
  for code in 1 3 42 130; do
    rc=0; FAKE_RC="$code" "$STACK_DIR/bin/claude-bedrock" --model m > /dev/null 2>&1 || rc=$?
    assert_eq "$rc" "$code"
  done
  assert_eq "$(printf 'piped' | FAKE_STDIN=1 "$STACK_DIR/bin/claude-bedrock" -p)" "$(printf 'devos-claude 1\n[-p]\nstdin piped')"
  # with no arguments: none passed on (not an empty one)
  assert_eq "$("$STACK_DIR/bin/claude-bedrock")" "devos-claude 0"
}

test_shim_follows_links_to_the_devos_claude_beside_it() {
  _fake_stack
  ln -s "$STACK_DIR/bin/claude-bedrock" "$O"                                # ~/.local/bin's absolute link
  mkdir -p "$TMP/rel"; ln -s ../stack/bin/claude-bedrock "$TMP/rel/cb"      # a relative one, and a link to a link
  ln -s "$TMP/rel/cb" "$TMP/rel/cb2"
  for f in "$O" "$TMP/rel/cb" "$TMP/rel/cb2"; do
    assert_eq "$(cd / && "$f" a 'b c')" "$(printf 'devos-claude 2\n[a]\n[b c]')"
  done
  # a devos-claude on PATH is never the one it runs: its own checkout's
  mkdir -p "$TMP/path"; printf '#!/bin/sh\necho wrong\n' > "$TMP/path/devos-claude"; chmod 755 "$TMP/path/devos-claude"
  assert_eq "$(PATH="$TMP/path:$PATH" "$O" x)" "$(printf 'devos-claude 1\n[x]')"
  # in a folder with spaces in its name
  mkdir -p "$TMP/my stack"; cp -R "$STACK_DIR/bin" "$TMP/my stack/"
  assert_eq "$("$TMP/my stack/bin/claude-bedrock" y)" "$(printf 'devos-claude 1\n[y]')"
}

test_the_terminals_shim_is_the_same_file_and_kept_runnable() {
  cmp -s "$REPO/bin/claude-bedrock" "$REPO/terminal/bin/claude-bedrock" || { echo "the two shims differ" >&2; return 1; }
  [ -x "$REPO/bin/claude-bedrock" ] && [ -x "$REPO/terminal/bin/claude-bedrock" ] || { echo "a shim is not executable" >&2; return 1; }
  assert_contains "$(grep -E '^ && chmod 755 /usr/local/bin/devos-claude' "$REPO/terminal/Dockerfile")" "/usr/local/bin/claude-bedrock"
  # only an exec: no output, no other command
  assert_eq "$(grep -cE '^[[:space:]]*(echo|printf|cat)( |$)' "$REPO/bin/claude-bedrock" || true)" 0
  assert_contains "$(tail -n 1 "$REPO/bin/claude-bedrock")" 'exec "$target" "$@"'
  assert_contains "$(cat "$REPO/bin/claude-bedrock")" 'target="$(cd -P "$(dirname "$src")" && pwd)/devos-claude"'
  # the full wrapper is devos-claude (its help names it), not the old name
  assert_contains "$(cat "$REPO/bin/devos-claude")" "devos-claude: Claude Code on AWS Bedrock via DevOS ADE"
  assert_contains "$(cat "$REPO/terminal/bin/devos-claude")" "devos-claude: Claude Code on AWS Bedrock via DevOS ADE, in the browser terminal"
}

# --- setup: both links ---

test_setup_links_both_names_when_you_say_yes() {
  _fake_stack; ASSUME_YES=0; _have_tty() { return 0; }; ask() { echo "${2:-}"; }
  offer_symlink 2> "$TMP/err"
  assert_eq "$(readlink "$D")" "$STACK_DIR/bin/devos-claude"
  assert_eq "$(readlink "$O")" "$STACK_DIR/bin/claude-bedrock"
  assert_contains "$(cat "$TMP/err")" "linked $D"
  assert_contains "$(cat "$TMP/err")" "linked $O (devos-claude's name before v0.28.0: it runs devos-claude)"
  assert_eq "$("$O" --help)" "$(printf 'devos-claude 1\n[--help]')"
  # again: nothing to do, nothing said
  offer_symlink 2> "$TMP/err"
  assert_eq "$(cat "$TMP/err")" ""
}

test_setup_says_no_and_links_neither() {
  _fake_stack; ASSUME_YES=0; _have_tty() { return 0; }; ask() { echo n; }
  offer_symlink 2>/dev/null
  [ ! -e "$D" ] && [ ! -L "$D" ] && [ ! -e "$O" ] && [ ! -L "$O" ] || { echo "linked after a no" >&2; return 1; }
}

test_setup_under_yes_links_nothing_new_on_a_fresh_install() {
  _fake_stack; ASSUME_YES=1
  offer_symlink 2> "$TMP/err"
  [ ! -e "$D" ] && [ ! -L "$D" ] && [ ! -e "$O" ] && [ ! -L "$O" ] || { echo "linked under --yes" >&2; return 1; }
  assert_contains "$(cat "$TMP/err")" "to put devos-claude on your PATH: ln -s $STACK_DIR/bin/devos-claude $D"
}

test_the_old_name_is_never_taken_from_another_checkout_or_a_file() {
  _fake_stack; ASSUME_YES=0; _have_tty() { return 0; }; ask() { echo "${2:-}"; }
  # another checkout that is there (a broken link into a removed one is replaced: see further below)
  mkdir -p "$TMP/elsewhere/bin"; : > "$TMP/elsewhere/bin/claude-bedrock"; ln -s "$TMP/elsewhere/bin/claude-bedrock" "$O"
  offer_symlink 2> "$TMP/err"
  assert_eq "$(readlink "$D")" "$STACK_DIR/bin/devos-claude"
  assert_eq "$(readlink "$O")" "$TMP/elsewhere/bin/claude-bedrock"
  assert_contains "$(cat "$TMP/err")" "left $O alone (it points to $TMP/elsewhere/bin/claude-bedrock); devos-claude is its new name"
  rm -f "$O"; printf '#!/bin/sh\necho mine\n' > "$O"
  ASSUME_YES=1 offer_symlink 2> "$TMP/err"
  assert_eq "$(cat "$O")" "$(printf '#!/bin/sh\necho mine')"
  assert_contains "$(cat "$TMP/err")" "left $O alone (not a link)"
}

# --- ./stack update from v0.27.x: its setup --yes ---

# _v027_checkout -> a git checkout at $TMP/stack whose first commit is the v0.27.x layout (bin/claude-bedrock: the
# full wrapper, linked from ~/.local/bin as setup made it) and whose second ($NEW) is this version's (bin/devos-claude,
# and bin/claude-bedrock the shim) — ./stack update's checkout moves from one to the other
_v027_checkout() {
  HOME="$TMP/home"; STACK_DIR="$TMP/stack"; mkdir -p "$HOME/.local/bin" "$STACK_DIR/bin"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  git -C "$STACK_DIR" init -q
  printf '#!/usr/bin/env bash\n# Launch Claude Code against AWS Bedrock via this stack (v0.27.x)\necho "old wrapper $*"\n' > "$STACK_DIR/bin/claude-bedrock"
  chmod 755 "$STACK_DIR/bin/claude-bedrock"
  git -C "$STACK_DIR" add -A && git -C "$STACK_DIR" commit -qm v0.27.1
  git -C "$STACK_DIR" mv bin/claude-bedrock bin/devos-claude
  printf '#!/usr/bin/env bash\nprintf "devos-claude %%s\\n" "$*"\nexit "${FAKE_RC:-0}"\n' > "$STACK_DIR/bin/devos-claude"
  cp "$REPO/bin/claude-bedrock" "$STACK_DIR/bin/claude-bedrock"
  git -C "$STACK_DIR" add -A && git -C "$STACK_DIR" commit -qm v0.28.0
  NEW="$(git -C "$STACK_DIR" rev-parse HEAD)"
  git -C "$STACK_DIR" checkout -q HEAD~1   # the install as v0.27.1 left it
  D="$HOME/.local/bin/devos-claude"; O="$HOME/.local/bin/claude-bedrock"
}

test_update_from_v027_adds_devos_claude_and_the_old_link_runs_the_shim() {
  _v027_checkout
  ln -s "$STACK_DIR/bin/claude-bedrock" "$O"
  assert_eq "$("$O" hi)" "old wrapper hi"
  git -C "$STACK_DIR" checkout -q "$NEW"   # ./stack update's checkout
  [ -x "$STACK_DIR/bin/devos-claude" ] || { echo "the update's checkout has no devos-claude" >&2; return 1; }
  # right after the checkout, before setup: the old link already runs the shim, and so devos-claude
  assert_eq "$("$O" hi 'a b')" "devos-claude hi a b"
  ASSUME_YES=1 offer_symlink 2> "$TMP/err"   # (./stack update runs ./stack setup --yes)
  assert_eq "$(readlink "$D")" "$STACK_DIR/bin/devos-claude"
  assert_eq "$(readlink "$O")" "$STACK_DIR/bin/claude-bedrock"
  assert_contains "$(cat "$TMP/err")" "linked $D (formerly claude-bedrock, which keeps working: it runs devos-claude now)"
  assert_eq "$("$D" x)" "devos-claude x"
  local rc=0; FAKE_RC=5 "$O" x > /dev/null || rc=$?
  assert_eq "$rc" 5
  # and again (the next update): nothing changes, nothing said
  ASSUME_YES=1 offer_symlink 2> "$TMP/err"
  assert_eq "$(cat "$TMP/err")" ""
}

test_update_never_replaces_a_devos_claude_of_yours_or_another_checkouts() {
  _v027_checkout
  ln -s "$STACK_DIR/bin/claude-bedrock" "$O"
  git -C "$STACK_DIR" checkout -q "$NEW"
  ln -s /elsewhere/bin/devos-claude "$D"
  ASSUME_YES=1 offer_symlink 2> "$TMP/err"
  assert_eq "$(readlink "$D")" "/elsewhere/bin/devos-claude"
  assert_contains "$(cat "$TMP/err")" "left $D alone (it points to /elsewhere/bin/devos-claude)"
  rm -f "$D"; printf 'mine\n' > "$D"
  ASSUME_YES=1 offer_symlink 2>/dev/null
  assert_eq "$(cat "$D")" "mine"
  # an install whose claude-bedrock link is another checkout's: this update links nothing
  rm -f "$D" "$O"; ln -s /elsewhere/bin/claude-bedrock "$O"
  ASSUME_YES=1 offer_symlink 2>/dev/null
  [ ! -e "$D" ] && [ ! -L "$D" ] || { echo "linked devos-claude for another checkout's install" >&2; return 1; }
}

test_update_with_devos_claude_linked_adds_the_old_name() {
  _fake_stack; ln -s "$STACK_DIR/bin/devos-claude" "$D"
  ASSUME_YES=1 offer_symlink 2>/dev/null
  assert_eq "$(readlink "$O")" "$STACK_DIR/bin/claude-bedrock"
}

test_setup_and_update_reach_offer_symlink() {
  # setup's finishing step links them; ./stack update finishes with ./stack setup --yes (in its own process)
  assert_contains "$(declare -f cmd_setup _setup_finish)" "offer_symlink"
  assert_contains "$(declare -f cmd_update)" '"$STACK_DIR/stack" setup --yes'
}

# --- uninstall: both links, only this checkout's ---

test_uninstall_removes_both_links_of_this_checkout_only() {
  _fake_stack; printf 'X=1\n' > "$ENV_FILE"
  dc() { :; }; docker() { :; }; ask() { echo "devos-ade"; }; confirm() { return 1; }
  ln -s "$STACK_DIR/bin/devos-claude" "$D"; ln -s "$STACK_DIR/bin/claude-bedrock" "$O"
  cmd_uninstall 2> "$TMP/err"
  [ ! -e "$D" ] && [ ! -L "$D" ] && [ ! -e "$O" ] && [ ! -L "$O" ] || { echo "a link was not removed" >&2; return 1; }
  assert_contains "$(cat "$TMP/err")" "removed the $D link"
  assert_contains "$(cat "$TMP/err")" "removed the $O link"
  [ -f "$STACK_DIR/bin/claude-bedrock" ] && [ -f "$STACK_DIR/bin/devos-claude" ] || { echo "removed a file of the checkout" >&2; return 1; }
  # another checkout's links and files of yours stay
  ln -s /elsewhere/bin/devos-claude "$D"; printf 'mine\n' > "$O"
  cmd_uninstall 2> "$TMP/err"
  assert_eq "$(readlink "$D")" "/elsewhere/bin/devos-claude"
  assert_eq "$(cat "$O")" "mine"
  assert_not_contains "$(cat "$TMP/err")" "removed the"
}

test_a_link_that_cannot_be_made_never_stops_setup_or_an_update() {
  _fake_stack; ln -s "$STACK_DIR/bin/devos-claude" "$D"; chmod 555 "$HOME/.local/bin"
  local rc=0
  ( set -e; ASSUME_YES=1 offer_symlink; echo after > "$TMP/after" ) 2> "$TMP/err" || rc=$?
  chmod 755 "$HOME/.local/bin"
  assert_eq "$rc/$(cat "$TMP/after" 2>/dev/null)" "0/after"
  assert_contains "$(cat "$TMP/err")" "could not link $O"
  # the update's link of devos-claude, the same
  rm -f "$D"; ln -s "$STACK_DIR/bin/claude-bedrock" "$O"; chmod 555 "$HOME/.local/bin"; rm -f "$TMP/after"; rc=0
  ( set -e; ASSUME_YES=1 offer_symlink; echo after > "$TMP/after" ) 2> "$TMP/err" || rc=$?
  chmod 755 "$HOME/.local/bin"
  assert_eq "$rc/$(cat "$TMP/after" 2>/dev/null)" "0/after"
  assert_contains "$(cat "$TMP/err")" "could not link $D"
}

test_an_interactive_setup_goes_on_when_the_link_cannot_be_made() {
  _fake_stack; ASSUME_YES=0; _have_tty() { return 0; }; ask() { echo "${2:-}"; }; chmod 555 "$HOME/.local/bin"
  local rc=0
  ( set -e; offer_symlink; echo after > "$TMP/after" ) 2> "$TMP/err" || rc=$?
  chmod 755 "$HOME/.local/bin"
  assert_eq "$rc/$(cat "$TMP/after" 2>/dev/null)" "0/after"
  assert_contains "$(cat "$TMP/err")" "could not link $D"
}

test_shim_stops_when_devos_claude_is_a_link_to_the_shim_itself() {
  _fake_stack; rm -f "$STACK_DIR/bin/devos-claude"; ln -s claude-bedrock "$STACK_DIR/bin/devos-claude"
  local rc=0
  "$STACK_DIR/bin/claude-bedrock" --version > /dev/null 2> "$TMP/err" || rc=$?
  assert_eq "$rc" 127
  assert_contains "$(cat "$TMP/err")" "is this file itself, not devos-claude"
}

test_a_broken_old_name_link_into_a_removed_checkout_is_replaced() {
  _fake_stack; ln -s "$STACK_DIR/bin/devos-claude" "$D"; ln -s "$TMP/gone/bin/claude-bedrock" "$O"
  ASSUME_YES=1 offer_symlink 2> "$TMP/err"
  assert_eq "$(readlink "$O")" "$STACK_DIR/bin/claude-bedrock"
  assert_contains "$(cat "$TMP/err")" "it pointed to $TMP/gone/bin/claude-bedrock, which is gone"
  # a broken link of yours to something else stays as it is
  rm -f "$O"; ln -s "$TMP/elsewhere/my-tool" "$O"
  ASSUME_YES=1 offer_symlink 2> "$TMP/err"
  assert_eq "$(readlink "$O")" "$TMP/elsewhere/my-tool"
}
