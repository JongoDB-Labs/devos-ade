# shellcheck shell=bash
# shellcheck disable=SC2329  # stubs are called by the code under test
# JON-972: terminal_workspace_check (lib/terminal.sh) folds its paths without a subshell and asks the system's name
# once, and _json_str (lib/helper.sh) gives plain text back without six programs. tests/fixtures/terminal_check_old.sh
# keeps both as they were (v0.68.9), as old_*; each case runs old and new on the same input and compares the output
# and the status, byte for byte.
. "$STACK_DIR/lib/commands.sh"
. "$STACK_DIR/lib/terminal.sh"
. "$STACK_DIR/lib/helper.sh"
. "$STACK_DIR/tests/fixtures/terminal_check_old.sh"

# _same_check PATH — old and new folder checks: the same output and status
_same_check() {
  local o n
  o="$(old_terminal_workspace_check "$1"; printf 'rc=%s' "$?")"
  n="$(_FOLD_OS=''; terminal_workspace_check "$1"; printf 'rc=%s' "$?")"
  [ "$o" = "$n" ] && return 0
  printf 'folder check of [%s]: old [%s], new [%s]\n' "$1" "$o" "$n" >&2
  return 1
}

_tree() {
  export HOME="$TMP/Home Dir"
  mkdir -p "$HOME/.ssh" "$HOME/Library/Mobile Documents/x" "$HOME/Library/Keychains" "$HOME/projects/a b" "$HOME/LIBRARY2" \
    "$TMP/ws/one" "$TMP/tmux-1000/s" "$TMP/plain" "$TMP/ws/o*" "$TMP/[x]" "$TMP/q?" "$TMP/!bang"
  ln -s "$HOME/projects" "$TMP/link-to-projects"; ln -s /tmp "$TMP/link-to-tmp"; ln -s / "$TMP/link-to-root"
  ln -s "$TMP/nowhere" "$TMP/dangling"
}

_paths() {
  printf '%s\n' / /tmp /var/tmp /dev/shm /usr /usr/local /etc /var /var/lib /opt /opt/homebrew /mnt /media /Volumes /srv \
    /srv/docker /proc /root /home /private /System /Library /Applications \
    "$HOME" "$HOME/" "$HOME/.ssh" "$HOME/Library" "$HOME/Library/Keychains" "$HOME/Library/Mobile Documents" \
    "$HOME/Library/Mobile Documents/x" "$HOME/LIBRARY2" "$HOME/projects" "$HOME/projects/a b" "$HOME/projects/../.ssh" \
    "$STACK_DIR" "$STACK_DIR/lib" "$STACK_DIR/.." "$TMP" "$TMP/ws" "$TMP/ws/one" "$TMP/tmux-1000/s" "$TMP/plain" \
    "$TMP/link-to-projects" "$TMP/link-to-tmp" "$TMP/link-to-root" "$TMP/dangling" "$TMP/missing" "$TMP/a:b" "$TMP/a,b" \
    "$TMP/ws/one/" "${TMPDIR:-/tmp}" "" "$TMP/ws/o*" "$TMP/[x]" "$TMP/q?" "$TMP/!bang"
}

test_the_folder_check_answers_every_path_as_before() {
  _tree
  local p bad=0
  while IFS= read -r p; do _same_check "$p" || bad=1; done <<EOF
$(_paths)
EOF
  # (and a path with a newline in it, and one ending in a newline: folded and compared as before)
  mkdir -p "$TMP/new
line"
  _same_check "$TMP/new
line" || bad=1
  _same_check "$TMP/plain
" || bad=1
  return "$bad"
}

test_the_folder_check_answers_as_before_on_macos_too() {
  # (uname says Darwin: every fold lower-cases, through tr, old and new)
  uname() { case "${1:-}" in -s) echo Darwin ;; *) command uname "$@" ;; esac; }
  _tree
  local p bad=0
  while IFS= read -r p; do _same_check "$p" || bad=1; done <<EOF
$(_paths)
$HOME/library/keychains
$HOME/LIBRARY/Mobile Documents/x
$HOME/.SSH
EOF
  return "$bad"
}

test_the_folder_check_answers_as_before_with_odd_homes() {
  _tree
  local bad=0 h
  # (and homes whose names are patterns: a case pattern left unquoted would match more than the folder itself)
  mkdir -p "$TMP/H*me/Library/Keychains" "$TMP/H*me/.ssh" "$TMP/Hxme/Library/Keychains" "$TMP/[H]ome/.ssh"
  for h in / "$TMP" "$TMP/missing" "$STACK_DIR" "$HOME/projects" "$TMP/H*me" "$TMP/[H]ome"; do
    HOME="$h" _same_check "$TMP/ws/one" || bad=1
    HOME="$h" _same_check "$HOME/.ssh" || bad=1
    HOME="$h" _same_check /usr || bad=1
    HOME="$h" _same_check "$TMP/Hxme/Library/Keychains" || bad=1
    HOME="$h" _same_check "$TMP/Hxme" || bad=1
    HOME="$h" _same_check "$TMP/H" || bad=1
  done
  return "$bad"
}

test_the_folder_check_asks_the_systems_name_once() {
  _tree
  local calls="$TMP/uname-calls"
  uname() { echo x >> "$calls"; command uname "$@"; }
  # (/usr/local: past every list to the system folders; a folder in a temporary one is answered after a few folds)
  : > "$calls"; ( old_terminal_workspace_check /usr/local > /dev/null ) || true; local old_n; old_n="$(wc -l < "$calls" | tr -d ' ')"
  : > "$calls"; ( _FOLD_OS=''; terminal_workspace_check /usr/local > /dev/null ) || true; local new_n; new_n="$(wc -l < "$calls" | tr -d ' ')"
  [ "$old_n" -gt 20 ] || { echo "the old check asked only $old_n times: the test no longer sees what it was for" >&2; return 1; }
  assert_eq "$new_n" 1
  # (macOS too, where each fold still runs tr: the name is asked once all the same)
  uname() { echo x >> "$calls"; case "${1:-}" in -s) echo Darwin ;; *) command uname "$@" ;; esac; }
  : > "$calls"; ( _FOLD_OS=''; terminal_workspace_check /usr/local > /dev/null ) || true
  assert_eq "$(wc -l < "$calls" | tr -d ' ')" 1
}

# _same_json TEXT — old and new _json_str: the same bytes (a trailing newline too) and status
_same_json() {
  local o n
  o="$(old_json_str "$1"; printf 'x%s' "$?")"
  n="$(_json_str "$1"; printf 'x%s' "$?")"
  [ "$o" = "$n" ] && return 0
  printf '_json_str of [%s]: old [%s], new [%s]\n' "$1" "$o" "$n" >&2
  return 1
}

_json_cases() {
  local s300 s301 i
  s300=''; for i in $(seq 1 30); do s300="${s300}abcdefghi."; done; s301="${s300}z"
  printf '%s\0' '' a 'plain words' 'v1.2.3' 'https://example.test/a?b=c&d=e#f' "abc${s300:3}" "$s300" "$s301" \
    'say "hi"' 'back\slash' "$(printf 'tab\there')" "$(printf 'new\nline')" "$(printf 'cr\rhere')" "$(printf 'bell\a!')" \
    'caf'"$(printf '\303\251')" "$(printf 'cut \303')" "$(printf 'emoji \360\237\230\200')" "$(printf 'bad \377\376')" \
    '[brackets]' 'a]b' '!bang' '^caret' 'dollar $HOME' 'back`tick`' "it's" '<lt>gt' '{brace}' 'pi|pe' 'a-b' '-lead' 'a*b?c' \
    'per%cent' 'semi;colon' 'amp&' '(paren)' 'tilde~' 'hash#' '   spaces   ' "$(printf '%299s' x)" "$(printf '%300s' x)" \
    "$(printf '%301s' x)" "${s300}é" "$(for i in $(seq 1 150); do printf '\303\251'; done)" "$(for i in $(seq 1 100); do printf 'a\303\251'; done)"
}

test_json_str_gives_what_it_gave() {
  local s bad=0 loc u
  # (in C and in a UTF-8 locale, where there is one: iconv and the shell's length follow it)
  u="$(locale -a 2>/dev/null | LC_ALL=C grep -iE '^(c|en_us)\.utf-?8$' | head -n 1)"
  for loc in C ${u:+"$u"}; do
    while IFS= read -r -d '' s; do LC_ALL="$loc" _same_json "$s" || bad=1; done < <(_json_cases)
  done
  # (nocasematch on: the plain set is matched as it is written either way)
  shopt -s nocasematch
  while IFS= read -r -d '' s; do _same_json "$s" || bad=1; done < <(_json_cases)
  shopt -u nocasematch
  # (and 300 strings of random bytes from the plain set, a quote, a backslash, a tab and a high byte)
  local i
  for i in $(seq 1 300); do
    s="$(LC_ALL=C awk -v seed="$i" 'BEGIN { srand(seed); c = "aZ09 ._:/@+=,~%#&()?;*-\"\\\t]![^$`<>{}|\303\251"; n = int(rand() * 40)
      for (j = 0; j < n; j++) printf "%s", substr(c, int(rand() * length(c)) + 1, 1) }')"
    _same_json "$s" || bad=1
  done
  return "$bad"
}

test_json_str_runs_no_program_for_plain_text() {
  local calls="$TMP/calls"
  tr() { echo tr >> "$calls"; command tr "$@"; }
  head() { echo head >> "$calls"; command head "$@"; }
  iconv() { echo iconv >> "$calls"; command iconv "$@"; }
  : > "$calls"
  assert_eq "$(_json_str 'claude-sonnet-5-5 1.2.3 https://example.test/x?y=1')" 'claude-sonnet-5-5 1.2.3 https://example.test/x?y=1'
  assert_eq "$(awk 'END { print NR }' "$calls")" 0
  # (anything else still goes through them)
  : > "$calls"; assert_eq "$(_json_str 'say "hi"')" 'say hi'
  [ "$(awk 'END { print NR }' "$calls")" -gt 0 ] || { echo "a quote did not go through the pipeline" >&2; return 1; }
}

test_fold_into_gives_what_a_subshell_of_fold_gives() {
  # (the helper itself, beyond the check's paths: trailing and inner newlines, spaces, empty; Linux and macOS)
  local x v os bad=0
  for os in Linux Darwin; do
    uname() { case "${1:-}" in -s) echo "$UM_OS" ;; *) command uname "$@" ;; esac; }
    UM_OS="$os"; _FOLD_OS=''
    for x in '' / '/Ab C' "$(printf '/a\nb')" "$(printf '/a\n')
" "$(printf '/a\n\n\n')x" '/A/' "$(printf '/t\tab')"; do
      _fold_into v "$x"
      [ "$v" = "$(_fold "$x")" ] || { printf '%s: _fold_into [%s] gave [%s], $(_fold) [%s]\n' "$os" "$x" "$v" "$(_fold "$x")" >&2; bad=1; }
    done
    x="$(printf '/a\n\n')"; x="$x
"; _fold_into v "$x"; [ "$v" = /a ] || { echo "$os: trailing newlines kept: [$v]" >&2; bad=1; }
  done
  return "$bad"
}
