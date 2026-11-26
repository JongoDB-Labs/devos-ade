# shellcheck shell=bash
# shellcheck disable=SC2329,SC2034  # stubs are called by the code under test; UM_OS is read by the uname stub
# JON-972: optional_services runs the terminal's folder check once for the list (terminal_ready, _TERMINAL_READY_MEMO),
# runtime_services asks the system's name once, and _phys runs pwd in its own subshell (exec). tests/fixtures/
# services_list_old.sh keeps them as they were (v0.68.10), as old_*; each case runs old and new on the same .env and
# folders and compares the output and the status, byte for byte.
. "$STACK_DIR/lib/commands.sh"
. "$STACK_DIR/lib/terminal.sh"
. "$STACK_DIR/tests/fixtures/services_list_old.sh"

UM_OS=Linux
uname() { case "${1:-}" in -s) echo "$UM_OS" ;; *) command uname "$@" ;; esac; }

_tree() {
  export HOME="$TMP/home"
  mkdir -p "$HOME/projects/ws" "$HOME/.ssh" "$TMP/ws"
}

# _same_list LABEL — old and new optional_services, on .env as it is now: the same line and status
_same_list() {
  local o n
  o="$(_FOLD_OS=''; old_optional_services; printf 'rc=%s' "$?")"
  n="$(_FOLD_OS=''; optional_services; printf 'rc=%s' "$?")"
  [ "$o" = "$n" ] && return 0
  printf '%s (%s): old [%s], new [%s]\n' "$1" "$UM_OS" "$o" "$n" >&2
  return 1
}

# the .env lines each case starts from: the terminal (on or off, its folder fine, gone, refused), the Code page, the
# terminal's way out, speech-to-text, the git server, the built-in search
_envs() {
  local ws
  for ws in "$HOME/projects/ws" "$TMP/ws" "$HOME/gone" "$HOME" "$HOME/.ssh" /tmp "$STACK_DIR" ""; do
    printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\n\0' "$ws"
    printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=false\nTERMINAL_EGRESS=host\n\0' "$ws"
    printf 'TERMINAL_ENABLED=false\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\n\0' "$ws"
  done
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\nTERMINAL_EGRESS=host\nSTT_PROVIDER=bedrock\nLOCALGIT=off\nWEBSEARCH_SEARXNG_BUILTIN=off\n\0' "$HOME/projects/ws"
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\nTERMINAL_EGRESS=none\nSTT_PROVIDER=local\n\0' "$HOME/projects/ws"
  printf '\0'
}

test_the_services_list_is_what_it_was() {
  _tree
  local e os bad=0
  for os in Linux Darwin; do
    UM_OS="$os"
    while IFS= read -r -d '' e; do
      printf '%s' "$e" > "$ENV_FILE"
      _same_list "$(printf '%s' "$e" | tr '\n' ' ')" || bad=1
    done < <(_envs)
  done
  # (with the runtimes installed: Linux lists their containers, macOS none)
  mkdir -p "$STATE_DIR/runtimes/ollama" "$STATE_DIR/runtimes/llamacpp"
  echo 0.40.11 > "$STATE_DIR/runtimes/ollama/installed"; echo b1 > "$STATE_DIR/runtimes/llamacpp/installed"
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\n' "$HOME/projects/ws" > "$ENV_FILE"
  for os in Linux Darwin FreeBSD; do UM_OS="$os"; _same_list "runtimes installed" || bad=1; done
  UM_OS=Linux
  assert_contains " $(optional_services) " " ollama ollama-gate llamacpp "
  # (no .env at all)
  rm -f "$ENV_FILE"; _same_list "no .env" || bad=1
  return "$bad"
}

test_the_list_checks_the_terminals_folder_once() {
  _tree
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\n' "$HOME/projects/ws" > "$ENV_FILE"
  local n="$TMP/checks"
  eval "$(declare -f terminal_workspace_check | sed '1s/terminal_workspace_check/twc_real/')"
  terminal_workspace_check() { echo x >> "$n"; twc_real "$@"; }
  old_terminal_workspace_check_v06810() { echo x >> "$n"; twc_real "$@"; }
  : > "$n"; old_optional_services > /dev/null; assert_eq "$(wc -l < "$n" | tr -d ' ')" 2   # (the test still sees what it was for)
  : > "$n"; assert_eq "$(optional_services)" "terminal-egress terminal-gateway terminal code subs-chat searxng forgejo"
  assert_eq "$(wc -l < "$n" | tr -d ' ')" 1
  # the answer is the list's own: outside it, terminal_ready checks again each time
  : > "$n"; terminal_ready; terminal_ready; assert_eq "$(wc -l < "$n" | tr -d ' ')" 2
  # and a folder refused now is refused in the list too (the memo is the check's answer, not a guess)
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\n' "$HOME" > "$ENV_FILE"
  assert_eq "$(optional_services)" "searxng forgejo"
  # (a local of the list: nothing is left behind in the shell that asked, so a later answer is a fresh check)
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\n' "$HOME/projects/ws" > "$ENV_FILE"
  optional_services > /dev/null
  assert_eq "${_TERMINAL_READY_MEMO:-unset}" unset
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\n' "$HOME" > "$ENV_FILE"
  if terminal_ready; then echo "terminal_ready kept the list's answer" >&2; return 1; fi
}

test_runtime_services_asks_the_systems_name_once() {
  local n="$TMP/uname" os bad=0 ids
  uname() { echo x >> "$n"; case "${1:-}" in -s) echo "$UM_OS" ;; *) command uname "$@" ;; esac; }
  for ids in "" "ollama" "ollama llamacpp vllm"; do
    rm -rf "$STATE_DIR/runtimes"; local id
    for id in $ids; do mkdir -p "$STATE_DIR/runtimes/$id"; echo 1 > "$STATE_DIR/runtimes/$id/installed"; done
    for os in Linux Darwin Other; do
      UM_OS="$os"
      [ "$(old_runtime_services; echo "rc=$?")" = "$(runtime_services; echo "rc=$?")" ] || { echo "runtime_services differ: [$ids] $os" >&2; bad=1; }
    done
  done
  UM_OS=Linux; : > "$n"; runtime_services > /dev/null; assert_eq "$(wc -l < "$n" | tr -d ' ')" 1
  # shellcheck disable=SC2086  # (the ids, a word each)
  : > "$n"; old_runtime_services > /dev/null; assert_eq "$(wc -l < "$n" | tr -d ' ')" "$(set -- $RUNTIME_IDS; echo "$#")"   # (was: once a runtime)
  return "$bad"
}

test_phys_gives_what_it_gave() {
  _tree
  mkdir -p "$TMP/real/a b" "$TMP/closed"; ln -s "$TMP/real" "$TMP/link"; ln -s "$TMP/nowhere" "$TMP/dangling"; : > "$TMP/file"
  local p bad=0
  for p in / /tmp "$HOME" "$TMP/real" "$TMP/real/a b" "$TMP/link" "$TMP/link/a b" "$TMP/link/../link" "$TMP/dangling" "$TMP/file" \
    "$TMP/missing" "" "$TMP/real/" "$TMP/closed"; do
    [ "$(old_phys "$p"; echo "rc=$?")" = "$(_phys "$p"; echo "rc=$?")" ] || { echo "_phys [$p] differs" >&2; bad=1; }
  done
  # (a folder it may not enter: empty, status 0, as before)
  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$TMP/closed"
    [ "$(old_phys "$TMP/closed"; echo "rc=$?")" = "$(_phys "$TMP/closed"; echo "rc=$?")" ] || bad=1
    assert_eq "$(_phys "$TMP/closed")" ""
    chmod 755 "$TMP/closed"
  fi
  return "$bad"
}
