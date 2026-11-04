# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2329  # literal ${...} in patterns; stubs read by the libs
# Your AI subscriptions (./stack subscriptions; lib/subscriptions.sh, terminal/bin/{subscriptions,claude-sub,bn-session},
# the helper's requests): what the sandbox says is kept only as words (a hostile answer — markup, escapes, a token, an id
# twice, more fields — is dropped), the status file for Settings, TERMINAL_AI_TOOLS, the launchers' environments
# (claude-sub never gets the stack's ANTHROPIC_* variables), each tool's own status reduced to a kind (Codex's line with
# part of an API key: only "api-key"), bn-session's words (a fixed list, a nonce once, folders inside the workspace or a
# project folder), the helper's two requests, and one list of tools everywhere. Every vendor tool is a stub here.
. "$STACK_DIR/lib/commands.sh"

_stubs() {
  export HOME="$TMP/home"; mkdir -p "$HOME"
  set_env_batch TERMINAL_ENABLED true
  stack_lock() { :; }
  stack_unlock() { :; }
  export RUNNING=1 TSV='' FOREVER=0 LONG=0 ENDLESS=0
  SX="exec -T -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  dc() {
    echo "dc $*" >> "$TMP/dc"
    case "$*" in
      "ps -q --status running terminal") [ "$RUNNING" != 1 ] || echo t3rm ;;
      # (Chat's sandbox: its own sign-ins)
      "ps -q --status running subs-chat") [ "${CHAT_RUNNING:-1}" != 1 ] || echo ch4t ;;
      "$SX -e BN_SUBS_TIMEOUT=15 subs-chat /usr/local/bin/subscriptions status --tsv") printf '%s' "${CHAT_TSV:-}" ;;
      "$SX subs-chat /usr/local/bin/subscriptions "*) echo "chat: $*" >> "$TMP/dc"; printf 'Open https://auth.openai.com/codex/device\n'; return 0 ;;
      "$SX -e BN_SUBS_TIMEOUT=15 terminal /usr/local/bin/subscriptions status --tsv")
        # (a sandbox that never stops printing: read up to the cap only)
        if [ "$FOREVER" = 1 ]; then printf 'codex\tyes\t0.163.0\tyes\tchatgpt\tcommand\n'; yes 'more more more'; else printf '%s' "$TSV"; fi ;;
      "$SX terminal /usr/local/bin/subscriptions logout "*) echo "logged out" ;;
      "$SX terminal /usr/local/bin/subscriptions login "*)
        # (what reaches its stdin: this terminal's only for the two that ask something back)
        if IFS= read -r typed; then echo "STDIN: $typed" >> "$TMP/dc"; fi
        if [ "$LONG" = 1 ]; then local i=0; while [ "$i" -lt 600 ]; do printf 'xx %0310d\n' "$i"; i=$((i + 1)); done; return 0; fi
        # (one line that never ends: 64 MiB without a newline)
        if [ "$ENDLESS" = 1 ]; then head -c 67108864 /dev/zero | LC_ALL=C tr '\0' x; return 0; fi
        printf '\033]0;owned\007\033]52;c;ZXZpbA==\007Open \033[1mhttps://auth.openai.com/codex/device\033[0m\r\nCode: ABCD-1234\n\033[?1049h\302\233x\n'; return 3 ;;
    esac
    return 0
  }
}

# a stub bin folder for the sandbox's scripts: each vendor command prints what its status would
_sandbox_bin() {
  local b="$TMP/sbin"; mkdir -p "$b" "$TMP/tools"
  printf '#!/bin/sh\nshift\nexec "$@"\n' > "$b/timeout"   # (Debian has timeout; macOS may not)
  printf 'codex 0.163.0\ngemini 0.65.0\ncopilot 1.0.103\ncursor 2026.10.22-27dcf5f\ngrok 1.0.67\n' > "$TMP/tools/VERSIONS"
  cat > "$b/claude-sub" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo "2.1.309 (Claude Code)" ;;
  "auth status") printf '%s\n' "${CLAUDE_STATUS:-{\"loggedIn\":false,\"authMethod\":\"none\"}}"; [ "${CLAUDE_RC:-1}" = 0 ] ;;
esac
EOF
  cat > "$b/codex" <<'EOF'
#!/bin/sh
[ "$*" = "login status" ] && { printf '%s\n' "${CODEX_STATUS:-Not logged in}" >&2; exit 0; }
EOF
  cat > "$b/cursor-agent" <<'EOF'
#!/bin/sh
[ "$*" = "status --format json" ] && printf '%s\n' "${CURSOR_STATUS:-{\"isAuthenticated\":false}}"
EOF
  for t in claude-sub codex cursor-agent timeout; do chmod +x "$b/$t"; done
  export PATH="$b:$PATH" BN_SUBS_BIN="$b" BN_TOOLS_DIR="$TMP/tools" BN_SUBS_TIMEOUT=5
  # (the script's own PATH for status: the sandbox's system folders there; this computer's here, with the stubs)
  export BN_SUBS_PATH="$PATH"
}

test_what_the_sandbox_says_is_kept_only_as_words() {
  local esc out; esc="$(printf '\033]0;owned\007')"
  out="$(printf '%s\n' \
    "$(printf 'codex\tyes\t0.163.0\tyes\tchatgpt\tcommand')" \
    "$(printf 'codex\tyes\t9.9.9\tno\t-\tcommand')" \
    "$(printf 'claude\tyes\t2.1.309\tyes\tsk-ant-oat01-%s\tcommand' "$(printf 'x%.0s' 1 2 3 4 5 6 7 8)")" \
    "$(printf 'gemini\tyes\t0.65.0%s\tyes\tgoogle\tfile' "$esc")" \
    "$(printf 'cursor\tyes\t<b>1</b>\tyes\tcursor\tcommand')" \
    "$(printf 'grok\tyes\t1.0.67\tmaybe\txai\tfile')" \
    "$(printf 'copilot\tyes\t1.0.103\tunknown\t-\tnone\tEXTRA!')" \
    "$(printf 'evil\tyes\t1\tyes\t-\tnone')" \
    "$(printf 'copilot\tno\t-\tyes\tgoogle\tnone')" \
    "$(printf 'grok\tyes\t1.0.67\tyes\tchatgpt\tfile')" \
    "$(printf 'cursor\tyes\t2026.10.22-27dcf5f\tyes\tcursor\tfile')" \
    "$(printf 'copilot\tno\t-\tyes\t-\tnone')" | subs_parse)"
  # (a kind another tool would say — Google for Copilot, ChatGPT for Grok — or another way of telling: not taken)
  assert_eq "$out" '{"id":"codex","account":"","first_name":"","installed":true,"version":"0.163.0","signed_in":"yes","kind":"chatgpt","how":"command"}
{"id":"copilot","account":"","first_name":"","installed":false,"version":"","signed_in":"no","kind":"","how":"none"}'
}

test_the_status_file_says_what_passed_and_whether_the_sandbox_answered() {
  _stubs
  local f
  export TSV="$(printf 'claude\tyes\t2.1.309\tyes\tclaude-max\tcommand\ncodex\tno\t-\tno\t-\tnone\n')"
  subs_refresh
  f="$(subs_status_file)"
  assert_contains "$(cat "$f")" '"terminal":"running","tools":[{"id":"claude","account":"","first_name":"","installed":true,"version":"2.1.309","signed_in":"yes","kind":"claude-max","how":"command"},{"id":"codex","account":"","first_name":"","installed":false'
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 644 ] || return 1
  # nothing that passes: said as an error, no tools
  export TSV='garbage'
  if subs_refresh; then return 1; fi
  assert_contains "$(cat "$f")" '"terminal":"error","tools":[]'
  # not running, off: said, the sandbox never asked
  : > "$TMP/dc"; export RUNNING=0
  if subs_refresh; then return 1; fi
  assert_contains "$(cat "$f")" '"terminal":"down"'
  assert_not_contains "$(cat "$TMP/dc")" "exec"
  set_env TERMINAL_ENABLED false
  if subs_refresh; then return 1; fi
  assert_contains "$(cat "$f")" '"terminal":"off"'
  # a sandbox that prints forever: its first 16 KiB read, inside the deadline — never the whole of it
  set_env TERMINAL_ENABLED true; export RUNNING=1 FOREVER=1
  SUBS_DEADLINE_S=20 subs_refresh || true
  assert_contains "$(cat "$f")" '"terminal":"running","tools":[{"id":"codex","account":"","first_name":"","installed":true'
  # by its path, with the system's PATH: never a program of that name the sandbox's home put first
  assert_contains "$(cat "$TMP/dc")" "dc exec -T -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin -e BN_SUBS_TIMEOUT=15 terminal /usr/local/bin/subscriptions status --tsv"
}

test_stack_subscriptions_prints_its_own_words_and_signs_out_by_tool() {
  _stubs
  local out
  export TSV="$(printf 'codex\tyes\t0.163.0\tyes\tchatgpt\tcommand\ncopilot\tyes\t1.0.103\tunknown\t-\tnone\ngrok\tno\t-\tno\t-\tnone\n')"
  out="$(cmd_subscriptions status)"
  assert_contains "$out" "Codex                            0.163.0              yes — ChatGPT"
  assert_contains "$out" "not known here (/user in Copilot says)"
  assert_contains "$out" "Grok Build                       -                    not in the sandbox (TERMINAL_AI_TOOLS)"
  cmd_subscriptions logout codex >/dev/null
  assert_contains "$(cat "$TMP/dc")" "dc exec -T -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin terminal /usr/local/bin/subscriptions logout codex"
  # a tool that signs out inside itself, an unknown one, a path: refused before the sandbox is asked
  : > "$TMP/dc"
  out="$( (cmd_subscriptions logout copilot) 2>&1)" && return 1
  assert_contains "$out" "/logout"
  out="$( (cmd_subscriptions logout '../../etc') 2>&1)" && return 1
  assert_contains "$out" "no tool or account called"
  assert_not_contains "$(cat "$TMP/dc")" "logout"
}

test_a_sign_in_here_shows_the_sandboxs_words_as_plain_text_only() {
  _stubs
  local out rc=0
  # (codex: nothing of this terminal's reaches the sandbox — what is typed here stays here)
  out="$(printf 'typed\n' | cmd_subscriptions login codex 2>&1)" || rc=$?
  assert_eq "$rc" 3
  assert_eq "$out" "sandbox│ Open https://auth.openai.com/codex/device
sandbox│ Code: ABCD-1234
sandbox│ x"
  ! printf '%s' "$out" | LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" || { echo "a control reached this terminal" >&2; return 1; }
  assert_not_contains "$(cat "$TMP/dc")" "STDIN:"
  # Claude Code reads the code you paste (said first), and only it and Copilot get this terminal's input
  : > "$TMP/dc"
  out="$(printf 'the-code\n' | cmd_subscriptions login claude 2>&1)" || true
  assert_contains "$out" "(What you type here now goes to Claude Code (your Claude plan)'s own sign-in in the sandbox, and nowhere else.)"
  assert_contains "$(cat "$TMP/dc")" "STDIN: the-code"
  # long lines cut, and after 400 lines no more is read
  export LONG=1
  out="$(cmd_subscriptions login cursor 2>&1)" || true
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 401
  assert_eq "$(printf '%s\n' "$out" | head -n 1 | sed 's/^sandbox│ //' | LC_ALL=C awk '{ print length($0) }')" 300
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "sandbox│ (more not shown)"
  export LONG=0
  # one line without end: at most SUBS_STREAM_MAX bytes reach awk (its memory stays small), one line of 300 shown
  export ENDLESS=1
  out="$(cmd_subscriptions login cursor 2>&1)" || true
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
  assert_eq "$(printf '%s\n' "$out" | sed 's/^sandbox│ //' | LC_ALL=C awk '{ print length($0) }')" 300
  export ENDLESS=0
  assert_eq "$(grep -c 'head -c "$SUBS_STREAM_MAX" | subs_plain_stream' "$STACK_DIR/lib/subscriptions.sh")" 3
  # Gemini CLI signs in inside its own screen: said, the sandbox not asked
  : > "$TMP/dc"
  out="$( (cmd_subscriptions login gemini) 2>&1)" && return 1
  assert_contains "$out" "Terminal tab"
  assert_not_contains "$(cat "$TMP/dc")" "login"
}

test_terminal_ai_tools_reaches_the_image_build_as_known_names_only() {
  assert_eq "$(subs_tools_arg)" all
  set_env TERMINAL_AI_TOOLS none; assert_eq "$(subs_tools_arg)" none
  set_env TERMINAL_AI_TOOLS 'Codex,copilot,codex'; assert_eq "$(subs_tools_arg)" codex,copilot
  set_env TERMINAL_AI_TOOLS 'codex,evil;rm,grok'; assert_eq "$(subs_tools_arg 2>/dev/null)" codex,grok
  assert_contains "$(subs_tools_arg 2>&1 >/dev/null)" "no tool called evil;rm"
  set_env TERMINAL_AI_TOOLS 'nothing-known'; assert_eq "$(subs_tools_arg 2>/dev/null)" all
  # terminal_build passes it as a build argument
  dc() { echo "dc $*" >> "$TMP/dc"; }
  building() { shift; "$@"; }
  set_env TERMINAL_AI_TOOLS cursor
  terminal_build >/dev/null 2>&1 || true
  assert_contains "$(cat "$TMP/dc")" "--build-arg BN_AI_TOOLS=cursor terminal"
}

test_each_tool_in_the_sandbox_says_only_signed_in_and_which_kind() {
  command -v jq >/dev/null 2>&1 || { echo "jq is not installed here (the sandbox has it)" >&2; return 77; }
  _sandbox_bin
  local out key
  key="sk-proj-$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"
  out="$(CLAUDE_STATUS='{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"x@example.com"}' CLAUDE_RC=0 \
    CODEX_STATUS="API key configured - ${key:0:8}***${key: -5}" CURSOR_STATUS='{"isAuthenticated":true,"userInfo":{"email":"x@example.com"}}' \
    bash "$STACK_DIR/terminal/bin/subscriptions" status --tsv)"
  assert_eq "$(printf '%s\n' "$out" | grep '^claude')" "$(printf 'claude\tyes\t2.1.309\tyes\tclaude-max\tcommand\t-')"
  assert_eq "$(printf '%s\n' "$out" | grep '^codex')" "$(printf 'codex\tyes\t0.163.0\tyes\tapi-key\tcommand\t-')"
  assert_eq "$(printf '%s\n' "$out" | grep '^cursor')" "$(printf 'cursor\tyes\t2026.10.22-27dcf5f\tyes\tcursor\tcommand\t-')"
  assert_eq "$(printf '%s\n' "$out" | grep '^copilot')" "$(printf 'copilot\tyes\t1.0.103\tunknown\t-\tnone\t-')"
  # never part of a key, an email: only the words
  assert_not_contains "$out" "sk-proj"
  assert_not_contains "$out" "example.com"
  # no login file: not signed in; a login file (never opened: unreadable here): signed in
  assert_eq "$(printf '%s\n' "$out" | grep '^grok')" "$(printf 'grok\tyes\t1.0.67\tno\t-\tfile\t-')"
  mkdir -p "$HOME/.grok" "$HOME/.gemini"; printf 'x' > "$HOME/.grok/auth.json"; chmod 000 "$HOME/.grok/auth.json"
  printf 'x' > "$HOME/.gemini/oauth_creds.json"; chmod 000 "$HOME/.gemini/oauth_creds.json"
  out="$(bash "$STACK_DIR/terminal/bin/subscriptions" status --tsv)"
  assert_eq "$(printf '%s\n' "$out" | grep '^grok')" "$(printf 'grok\tyes\t1.0.67\tyes\txai\tfile\t-')"
  assert_eq "$(printf '%s\n' "$out" | grep '^gemini')" "$(printf 'gemini\tyes\t0.65.0\tyes\tgoogle\tfile\t-')"
  # a Gemini that uses your own key (its settings say so): not known here
  printf '{"security":{"auth":{"selectedType":"gemini-api-key"}}}' > "$HOME/.gemini/settings.json"
  out="$(bash "$STACK_DIR/terminal/bin/subscriptions" status --tsv)"
  assert_eq "$(printf '%s\n' "$out" | grep '^gemini')" "$(printf 'gemini\tyes\t0.65.0\tunknown\tapi-key\tfile\t-')"
  chmod 600 "$HOME/.grok/auth.json" "$HOME/.gemini/oauth_creds.json"
  # a tool left out of the image (TERMINAL_AI_TOOLS): not installed
  printf 'codex 0.163.0\n' > "$TMP/tools/VERSIONS"
  out="$(bash "$STACK_DIR/terminal/bin/subscriptions" status --tsv)"
  assert_eq "$(printf '%s\n' "$out" | grep '^cursor')" "$(printf 'cursor\tno\t-\tno\t-\tnone\t-')"
  # and what ./stack keeps of all of it passes its own check
  assert_eq "$(printf '%s\n' "$out" | subs_parse | wc -l | tr -d ' ')" 6
}

test_claude_sub_runs_the_image_claude_without_the_stacks_variables() {
  local stub="$TMP/claude" out
  cat > "$stub" <<'EOF'
#!/bin/sh
if [ "$1" = --help ]; then printf 'Usage: claude\n\nCommands:\n  auth            Manage authentication\n  mcp             Configure MCP servers\n'; exit 0; fi
env | sort
echo "ARGS: $*"
EOF
  chmod +x "$stub"
  mkdir -p "$HOME/.config/devos-ade"; echo '{}' > "$HOME/.config/devos-ade/mcp.json"
  printf '#!/bin/sh\necho "tmux $*" >> "%s/tmux.log"\n' "$TMP" > "$TMP/tmux-stub"; chmod +x "$TMP/tmux-stub"
  export BN_TMUX_BIN="$TMP/tmux-stub"; unset TMUX TMUX_PANE
  out="$(env ANTHROPIC_BASE_URL=http://gateway:8091 ANTHROPIC_AUTH_TOKEN=sk-terminal ANTHROPIC_MODEL=m ANTHROPIC_DEFAULT_OPUS_MODEL=o \
    ANTHROPIC_API_KEY=k CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_OAUTH_TOKEN=t CLAUDE_BEDROCK_OPUS_MODEL=b CLAUDE_CONFIG_DIR=/elsewhere \
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 SHARED_MCP_TOKEN=s \
    DISABLE_LOGIN_COMMAND=1 DISABLE_UPGRADE_COMMAND=1 DISABLE_EXTRA_USAGE_COMMAND=1 ENABLE_CLAUDEAI_MCP_SERVERS=false BN_CODE_AUTO_MODE=true \
    HTTPS_PROXY=http://egress:3128 NODE_USE_ENV_PROXY=1 MY_OWN=kept BN_CLAUDE_BIN="$stub" bash "$STACK_DIR/terminal/bin/claude-sub" hello)"
  assert_not_contains "$out" "ANTHROPIC_"
  assert_not_contains "$out" "CLAUDE_CODE_USE_BEDROCK"
  assert_not_contains "$out" "CLAUDE_CODE_OAUTH_TOKEN"
  assert_not_contains "$out" "CLAUDE_BEDROCK_"
  assert_not_contains "$out" "SHARED_MCP_TOKEN"
  assert_not_contains "$out" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
  # (what keeps Claude Code on Bedrock off a Claude account: /login and the plan's commands and connectors are yours here)
  assert_not_contains "$out" "DISABLE_LOGIN_COMMAND"
  assert_not_contains "$out" "DISABLE_UPGRADE_COMMAND"
  assert_not_contains "$out" "DISABLE_EXTRA_USAGE_COMMAND"
  assert_not_contains "$out" "ENABLE_CLAUDEAI_MCP_SERVERS"
  assert_not_contains "$out" "BN_CODE_AUTO_MODE"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$HOME/.claude-subscription"
  assert_contains "$out" "DISABLE_AUTOUPDATER=1"
  assert_contains "$out" "HTTPS_PROXY=http://egress:3128"
  assert_contains "$out" "MY_OWN=kept"
  # the stack's shared MCP server: not given (Chat's knowledge bases, the shared bucket would reach your plan) …
  assert_contains "$out" "ARGS: --settings={\"disableAutoMode\":\"disable\"} hello"
  assert_not_contains "$out" "mcp-config"
  [ -d "$HOME/.claude-subscription" ] || return 1
  # … unless you ask for it in that shell, said each time
  out="$(CLAUDE_SUB_STACK_MCP=1 BN_CLAUDE_BIN="$stub" bash "$STACK_DIR/terminal/bin/claude-sub" hello 2>&1)"
  assert_contains "$out" "ARGS: --mcp-config=$HOME/.config/devos-ade/mcp.json --settings={\"disableAutoMode\":\"disable\"} hello"
  assert_contains "$out" "claude-sub: CLAUDE_SUB_STACK_MCP=1 — the stack's shared MCP server"
  # what it writes (its folder made here) is private
  assert_eq "$(stat -c %a "$HOME/.claude-subscription" 2>/dev/null || stat -f %Lp "$HOME/.claude-subscription")" 700
  # a subcommand (auth status, login, logout) gets nothing added; auto mode on: not turned off
  out="$(BN_CLAUDE_BIN="$stub" bash "$STACK_DIR/terminal/bin/claude-sub" auth status)"
  assert_contains "$out" "ARGS: auth status"
  out="$(TERMINAL_AUTO_MODE=true BN_CLAUDE_BIN="$stub" bash "$STACK_DIR/terminal/bin/claude-sub")"
  assert_not_contains "$out" "disableAutoMode"
  # in tmux: its pane marked as one of your subscriptions' tools
  TMUX=/tmp/t,1,0 TMUX_PANE=%9 BN_CLAUDE_BIN="$stub" bash "$STACK_DIR/terminal/bin/claude-sub" >/dev/null
  assert_eq "$(cat "$TMP/tmux.log")" "tmux set-option -p -t %9 @bn-sub 1"
}

test_the_other_launchers_keep_updates_off_and_say_when_a_tool_is_left_out() {
  local b="$TMP/tools" out t
  for t in codex/bin copilot cursor gemini grok; do mkdir -p "$b/$t"; done
  mkdir -p "$b/gemini/node_modules/.bin"
  for f in codex/bin/codex copilot/copilot cursor/cursor-agent gemini/node_modules/.bin/gemini grok/grok; do
    printf '#!/bin/sh\necho "ARGS: $*"\nenv | grep -E "^(COPILOT_[A-Z_]*|NO_BROWSER|NO_OPEN_BROWSER|NODE_DISABLE_COMPILE_CACHE|GROK_DISABLE_AUTOUPDATER|GH_TOKEN|ANTHROPIC_[A-Z_]*|CLAUDE_CODE_[A-Z_]*|CLAUDE_BEDROCK_[A-Z_]*|CLAUDE_CONFIG_DIR|SHARED_MCP_TOKEN|BN_MCP_URL|AWS_[A-Z_]*)=" | sort\necho "umask $(umask)"\n' > "$b/$f"; chmod +x "$b/$f"
  done
  export BN_TOOLS_DIR="$b"
  # (a tmux of the test's own: the launchers mark the pane they run in, never this computer's tmux)
  printf '#!/bin/sh\necho "tmux $*" >> "%s/tmux.log"\n' "$TMP" > "$TMP/tmux-stub"; chmod +x "$TMP/tmux-stub"
  export BN_TMUX_BIN="$TMP/tmux-stub"; unset TMUX TMUX_PANE
  # the stack's own variables never reach them (a key of yours for the tool itself does); what they write is private
  local stack_env=(ANTHROPIC_BASE_URL=http://gateway:8091 ANTHROPIC_AUTH_TOKEN=sk-terminal CLAUDE_BEDROCK_OPUS_MODEL=b CLAUDE_CODE_USE_BEDROCK=1
    CLAUDE_CONFIG_DIR=/x SHARED_MCP_TOKEN=s BN_MCP_URL=http://gateway:8091/mcp AWS_SECRET_ACCESS_KEY=a)
  out="$(env "${stack_env[@]}" GH_TOKEN=yours bash "$STACK_DIR/terminal/bin/copilot" login)"
  assert_eq "$out" "ARGS: login
COPILOT_AUTO_UPDATE=false
COPILOT_PKG_CACHE_HOME=$b/copilot/cache
GH_TOKEN=yours
umask 0077"
  assert_eq "$(env "${stack_env[@]}" bash "$STACK_DIR/terminal/bin/cursor-agent" status)" "ARGS: --disable-auto-update status
NODE_DISABLE_COMPILE_CACHE=1
NO_OPEN_BROWSER=1
umask 0077"
  assert_eq "$(env "${stack_env[@]}" bash "$STACK_DIR/terminal/bin/grok" logout)" "ARGS: --no-auto-update logout
GROK_DISABLE_AUTOUPDATER=1
umask 0077"
  assert_eq "$(env "${stack_env[@]}" bash "$STACK_DIR/terminal/bin/gemini" --version)" "ARGS: --version
NO_BROWSER=true
umask 0077"
  assert_eq "$(env "${stack_env[@]}" bash "$STACK_DIR/terminal/bin/codex" login --device-auth)" "ARGS: --disable daemon_auto_start --disable in_app_updates login --device-auth
umask 0077"
  # in tmux, each marks its pane as one of your subscriptions' tools (the Code page's @terminal leaves it alone) —
  # except while `subscriptions status` asks them (BN_SUB_NOMARK)
  [ ! -e "$TMP/tmux.log" ] || { echo "a launcher outside tmux marked a pane" >&2; return 1; }
  for t in codex copilot cursor-agent gemini grok; do TMUX=/tmp/t,1,0 TMUX_PANE=%7 bash "$STACK_DIR/terminal/bin/$t" x >/dev/null; done
  assert_eq "$(sort -u "$TMP/tmux.log")" "tmux set-option -p -t %7 @bn-sub 1"
  assert_eq "$(wc -l < "$TMP/tmux.log" | tr -d ' ')" 5
  : > "$TMP/tmux.log"
  TMUX=/tmp/t,1,0 TMUX_PANE=%7 BN_SUB_NOMARK=1 bash "$STACK_DIR/terminal/bin/codex" x >/dev/null
  [ ! -s "$TMP/tmux.log" ] || return 1
  rm "$b/codex/bin/codex"
  out="$(bash "$STACK_DIR/terminal/bin/codex" 2>&1)" && return 1
  assert_contains "$out" "not in this sandbox (left out by TERMINAL_AI_TOOLS in .env"
  assert_contains "$out" "or its download failed when the image was built: $b/SKIPPED"
  # the Gemini CLI's system settings (they outrank the user's) only turn its auto-update off
  assert_eq "$(tr -d ' \n' < "$STACK_DIR/terminal/tools/gemini-settings.json")" '{"general":{"enableAutoUpdate":false,"enableAutoUpdateNotification":false}}'
}

test_bn_session_takes_only_its_words() {
  command -v jq >/dev/null 2>&1 || { echo "jq is not installed here (the sandbox has it)" >&2; return 77; }
  local b="$TMP/bin" ws="$TMP/ws" proj="$TMP/proj"
  mkdir -p "$b" "$ws/sub" "$proj/inner" "$TMP/elsewhere"
  ws="$(cd "$ws" && pwd -P)"; proj="$(cd "$proj" && pwd -P)"
  # tmux: records what it was asked; "claude" exists once made
  # (and the sessions made: -d with -s NAME, as ensure and the grouped sessions make them)
  # (windows: new-window -P prints an id (@1, @2 ...), and a window option @bn-open set on it is listed by list-windows)
  cat > "$b/tmux" <<EOF
#!/bin/sh
echo "tmux \$*" >> "$TMP/tmux"
case "\$1" in
  has-session) [ -f "$TMP/made.\${3#=}" ]; exit \$? ;;
  new-session) if [ "\$2" = -d ]; then n=; for a in "\$@"; do [ "\$p" = -s ] && n="\$a"; p="\$a"; done; touch "$TMP/made.\$n"; fi; exit 0 ;;
  new-window) for a in "\$@"; do [ "\$a" = -P ] && { n=\$(( \$(cat "$TMP/wn" 2>/dev/null || echo 0) + 1 )); echo \$n > "$TMP/wn"; echo "@\$n"; }; done; exit 0 ;;
  set-option) [ "\$2" = -w ] && [ "\$5" = @bn-open ] && echo "\${4#*:} \$6" >> "$TMP/wins"; exit 0 ;;
  list-windows) cat "$TMP/wins" 2>/dev/null; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$b/tmux"
  # (the sandbox's sha256sum; here whichever this computer has)
  local real_sum; real_sum="$(command -v sha256sum || true)"
  if [ -n "$real_sum" ]; then printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_sum" > "$b/sha256sum"; else printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$b/sha256sum"; fi
  chmod +x "$b/sha256sum"
  _run() { : > "$TMP/tmux"; env PATH="$b:$PATH" BN_SESSION_STATE="$TMP/state" BN_CODE_WORKSPACE="$ws" BN_CODE_ROOTS="[\"$proj\"]" bash "$STACK_DIR/terminal/bin/bn-session" "$@"; cat "$TMP/tmux"; }
  # (a launch token's form: <iat>-<16 hex>-<32 hex>; whether one is valid is the portal's gate's to say)
  local M=0123456789abcdef0123456789abcdef now; now="$(date +%s)"
  local N1="$now-0123456789abcdef-$M" N2="$((now - 1))-fedcba9876543210-$M" N3="$((now - 2))-00112233445566aa-$M" out
  local OLD="$((now - 700))-0123456789abcdef-$M" AHEAD="$((now + 120))-0123456789abcdef-$M"
  local N1x="$now-1111111111111111-$M" N4="$now-4444444444444444-$M" N5="$now-5555555555555555-$M"
  # no words, wrong words, a nonce that is not one, a folder elsewhere, too many: the plain attach
  for args in "" "evil codex $N1" "open evil $N1" "open codex nothex" "open codex 0123456789abcdef" "open codex 1792760000-0123456789abcdef-short" \
    "open codex $N1 $TMP/elsewhere" "open codex $N1 $ws/../elsewhere" "open codex $N1 relative" "open codex $N1 $ws extra"; do
    # shellcheck disable=SC2086
    out="$(_run $args)"
    assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux new-session -A -s claude -n bedrock -c $ws devos-claude; exec bash"
  done
  [ ! -d "$TMP/state/$N1" ] || { echo "a refused request used its nonce" >&2; return 1; }
  # a token made more than 10 minutes ago (or ahead of this clock): nothing starts, the terminal is only attached
  for tok in "$OLD" "$AHEAD"; do
    out="$(_run open codex "$tok")"
    assert_not_contains "$out" "new-window"
    assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux attach-session -t =claude"
  done
  # open: a window of the tool, made current; the same nonce again only attaches
  out="$(_run open codex "$N1")"
  assert_contains "$out" "tmux new-window -d -P -F #{window_id} -t =claude: -n codex -c $ws /usr/local/bin/subscriptions open codex; exec bash"
  assert_contains "$out" "tmux set-option -w -t =claude:@1 @bn-open codex"
  assert_contains "$out" "tmux set-option -w -t =claude:@1 @bn-suffix "
  assert_contains "$out" "tmux set-option -p -t =claude:@1 @bn-sub 1"
  assert_contains "$out" "tmux select-window -t =claude:@1"
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux attach-session -t =claude"
  out="$(_run open codex "$N1")"
  assert_not_contains "$out" "new-window"
  # a window is found by its option @bn-open, not by its name (subscriptions open renames it: claude-max): a fresh token
  # selects the window that is there and makes none, whatever it is called now
  local N6="$now-6666666666666666-$M"
  out="$(_run open codex "$N6")"
  assert_not_contains "$out" "new-window"
  assert_contains "$out" "tmux list-windows -t =claude -F #{window_id} #{@bn-open}"
  assert_contains "$out" "tmux select-window -t =claude:@1"
  # a folder below the workspace, a project folder (its own name in the window's, and a short hash of its path)
  local h; h="$(printf '%s' "$proj/inner" | "$b/sha256sum" | cut -c1-6)"
  out="$(_run open grok "$N2" "$proj/inner")"
  assert_contains "$out" "-n grok-inner-$h -c $proj/inner /usr/local/bin/subscriptions open grok"
  assert_contains "$out" "@bn-open grok@$h"
  assert_contains "$out" "@bn-suffix -inner-$h"
  # a shell (or Claude Code on Bedrock) is no subscription's tool: its window is not marked
  out="$(_run open shell "$N5")"
  assert_contains "$out" "-n shell -c $ws /usr/local/bin/subscriptions open shell"
  assert_not_contains "$out" "@bn-sub"
  # Claude on your plan's window is named after what runs in it: claude until `subscriptions open` knows (claude-max); the
  # first window is bedrock
  out="$(_run open claude "$N1x")"
  assert_contains "$out" "-n claude -c $ws /usr/local/bin/subscriptions open claude; exec bash"
  assert_contains "$out" "@bn-open claude"
  # another account: TOOL-NAME, found by TOOL:NAME; Bedrock and a shell take no account
  local A1="$now-a1a1a1a1a1a1a1a1-$M" A2="$now-a2a2a2a2a2a2a2a2-$M" A3="$now-a3a3a3a3a3a3a3a3-$M"
  out="$(_run open claude:work "$A1")"
  assert_contains "$out" "-n claude-work -c $ws /usr/local/bin/subscriptions open claude:work; exec bash"
  assert_contains "$out" "@bn-open claude:work"
  assert_contains "$out" "@bn-sub 1"
  out="$(_run chat codex:personal-2 "$A2")"
  assert_contains "$out" "-n codex-personal-2 -c $ws /usr/local/bin/subscriptions open codex:personal-2; exec bash"
  for args in "open bedrock:x $A3" "open shell:x $A3" "open claude: $A3" "open claude:Work $A3" "open claude:-w $A3" "open claude:a_b $A3" \
    "open claude:abcdefghijklmnopqrstu $A3" "open claude:a:b $A3" "open evil:work $A3" "add claude:work $A3" "add shell $A3" "add bedrock $A3" "add claude $A3 $ws"; do
    # shellcheck disable=SC2086
    out="$(_run $args)"
    case "$out" in *new-window*) echo "refused words made a window: $args -> $out" >&2; return 1 ;; esac
    assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux new-session -A -s claude -n bedrock -c $ws devos-claude; exec bash"
  done
  [ ! -d "$TMP/state/$A3" ] || { echo "a refused account used its nonce" >&2; return 1; }
  # add: a window running `subscriptions add TOOL` (it asks for the name), found by "add:TOOL", marked as a tool's
  out="$(_run add grok "$A3")"
  assert_contains "$out" "-n grok-new -c $ws /usr/local/bin/subscriptions add grok; exec bash"
  assert_contains "$out" "@bn-open add:grok"
  assert_contains "$out" "@bn-sub 1"
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux attach-session -t =claude"
  # rename, remove, logout (Settings' account rows): the command in a window of its own, found by "MODE:TOOL"; remove and
  # logout need an account name, a shell and Bedrock have none
  local R1="$now-b1b1b1b1b1b1b1b1-$M" R2="$now-b2b2b2b2b2b2b2b2-$M" R3="$now-b3b3b3b3b3b3b3b3-$M"
  out="$(_run rename claude:work "$R1")"
  assert_contains "$out" "-n claude-work-rename -c $ws /usr/local/bin/subscriptions rename claude:work; exec bash"
  assert_contains "$out" "@bn-open rename:claude:work"
  out="$(_run remove codex:personal "$R2")"
  assert_contains "$out" "/usr/local/bin/subscriptions remove codex:personal; exec bash"
  assert_contains "$out" "@bn-open remove:codex:personal"
  for args in "remove codex $R3" "logout codex $R3" "rename shell $R3" "remove bedrock:x $R3" "remove evil:x $R3" "rename claude:Work $R3" "remove codex:x $R3 $ws"; do
    # shellcheck disable=SC2086
    out="$(_run $args)"
    case "$out" in *new-window*) echo "refused words made a window: $args -> $out" >&2; return 1 ;; esac
  done
  out="$(_run logout grok:alt "$R3")"
  assert_contains "$out" "/usr/local/bin/subscriptions logout grok:alt; exec bash"
  # a folder with "#" (tmux reads -c as a format) and a "." in its name (a pane in a target): doubled, mapped
  mkdir -p "$ws/a#b.c"
  out="$(_run open codex "$N4" "$ws/a#b.c")"
  h="$(printf '%s' "$ws/a#b.c" | "$b/sha256sum" | cut -c1-6)"
  assert_contains "$out" "-n codex-a-b-c-$h -c $ws/a##b.c /usr/local/bin/subscriptions open codex"
  # chat: a session of its own grouped with "claude", without a status line
  h="$(printf '%s' "$ws/sub" | "$b/sha256sum" | cut -c1-6)"
  out="$(_run chat gemini "$N3" "$ws/sub")"
  assert_contains "$out" "tmux new-session -d -t =claude -s chat-gemini-sub-$h"
  assert_contains "$out" "tmux set-option -t =chat-gemini-sub-$h: status off"
  assert_contains "$out" "-n gemini-sub-$h -c $ws/sub"
  assert_contains "$out" "tmux select-window -t =chat-gemini-sub-$h:@"
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux attach-session -t =chat-gemini-sub-$h"
  # view N (the Terminal tab's views 2 to 4): a session grouped with "claude" (its status line kept: it is the view's tab
  # strip), a new shell window made current in it — shell-N, not the workspace's "shell" that Open a shell here finds by
  # its name — then the attach
  local V1="$now-aaaaaaaaaaaaaaaa-$M" V2="$now-bbbbbbbbbbbbbbbb-$M" V3="$now-cccccccccccccccc-$M" V4="$now-dddddddddddddddd-$M"
  out="$(_run view 2 "$V1")"
  assert_contains "$out" "tmux new-session -d -t =claude -s view-2"
  assert_contains "$out" "tmux new-window -t =view-2: -n shell-2 -c $ws exec bash"
  assert_not_contains "$out" "status off"
  assert_not_contains "$out" "select-window"
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux attach-session -t =view-2"
  # a reconnect (the same token, or a fresh one on a reload) only attaches to what is there
  for tok in "$V1" "$V2"; do
    out="$(_run view 2 "$tok")"
    assert_not_contains "$out" "new-window"
    assert_not_contains "$out" "new-session -d -t"
    assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux attach-session -t =view-2"
  done
  # the other views are sessions of their own
  out="$(_run view 4 "$V3")"
  assert_contains "$out" "tmux new-session -d -t =claude -s view-4"
  assert_contains "$out" "tmux new-window -t =view-4: -n shell-4 -c $ws exec bash"
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux attach-session -t =view-4"
  # a token acts once: a view that is gone does not come back on its old token (the plain attach), a new one makes it
  rm -f "$TMP/made.view-4"
  out="$(_run view 4 "$V3")"
  assert_not_contains "$out" "new-window"
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux new-session -A -s claude -n bedrock -c $ws devos-claude; exec bash"
  out="$(_run view 4 "$V4")"
  assert_contains "$out" "tmux new-session -d -t =claude -s view-4"
  # N out of range, not a number, a folder or a fourth word, a token of the wrong form or too old, a view with no TOKEN: the
  # plain attach, nothing made
  rm -f "$TMP/made.view-"*
  for args in "view 1 $N1" "view 5 $N1" "view 0 $N1" "view 22 $N1" "view x $N1" "view - $N1" "view 2 nothex" "view 2 $OLD" "view 2 $AHEAD" "view 2" "view 2 $N1 $ws" \
    "view 2 $N1 extra"; do
    # shellcheck disable=SC2086
    out="$(_run $args)"
    assert_not_contains "$out" "new-window"
    assert_not_contains "$out" "-s view-"
    assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "tmux new-session -A -s claude -n bedrock -c $ws devos-claude; exec bash"
  done
  # (the words refused before the token is looked at: it is not used up)
  local VX="$now-eeeeeeeeeeeeeeee-$M"
  _run view 5 "$VX" > /dev/null; _run view 1 "$VX" > /dev/null
  [ ! -d "$TMP/state/$VX" ] || { echo "a refused view used its nonce" >&2; return 1; }
}

test_the_helper_takes_check_and_sign_out_by_tool_never_more() {
  _stubs
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR"
  printf '#!/bin/sh\necho "$*" >> "$CALLS"\n' > "$STACK_DIR/stack"; chmod +x "$STACK_DIR/stack"
  export CALLS="$TMP/calls" HELPER_JOB_POLL_S=0 DIAG_MIN_INTERVAL_S=0
  set_env_batch PORTAL_PASSWORD 'correct horse battery'
  mkdir -p "$(request_dir)" "$(helper_dir)"; chmod 700 "$(helper_dir)"
  ensure_portal_password_hash
  _ra() { printf '{"action":"%s","requested_at":%s,"nonce":"%s","auth":"%s"%s}' "$2" "$(date +%s)" "$1" "$(printf 'correct horse battery' | openssl base64 -A)" "$3" > "$(request_dir)/act-$1.json"; }
  _ra 11111111111111111111111111111111 subscriptions-check ''; settings_poll_once 2>/dev/null
  _ra 22222222222222222222222222222222 subscriptions-signout ',"tool":"codex"'; settings_poll_once 2>/dev/null
  assert_eq "$(cat "$CALLS")" "subscriptions status
subscriptions logout codex"
  assert_contains "$(cat "$(helper_status_file)")" "Codex signed out in the sandbox"
  # Copilot and Gemini sign out inside them; no path, no other field, no check with a tool
  _ra 33333333333333333333333333333333 subscriptions-signout ',"tool":"copilot"'
  if settings_poll_once 2>/dev/null; then return 1; fi
  _ra 44444444444444444444444444444444 subscriptions-signout ',"tool":"../../x"'
  if settings_poll_once 2>/dev/null; then return 1; fi
  _ra 55555555555555555555555555555555 subscriptions-check ',"tool":"codex"'
  if settings_poll_once 2>/dev/null; then return 1; fi
  assert_eq "$(wc -l < "$CALLS" | tr -d ' ')" 2
  # Chat's own: its check, and a sign-out for Chat of a Chat model with a sign-out command (never Cursor, never Copilot)
  _ra 66666666666666666666666666666666 subscriptions-check-chat ''; settings_poll_once 2>/dev/null
  _ra 77777777777777777777777777777777 subscriptions-signout-chat ',"tool":"grok"'; settings_poll_once 2>/dev/null
  assert_eq "$(tail -n 2 "$CALLS")" "subscriptions status --chat
subscriptions logout grok --chat"
  assert_contains "$(cat "$(helper_status_file)")" "Grok Build signed out for Chat"
  _ra 88888888888888888888888888888888 subscriptions-signout-chat ',"tool":"cursor"'
  if settings_poll_once 2>/dev/null; then return 1; fi
  _ra 99999999999999999999999999999999 subscriptions-signout-chat ',"tool":"copilot"'
  if settings_poll_once 2>/dev/null; then return 1; fi
  assert_eq "$(wc -l < "$CALLS" | tr -d ' ')" 4
  settings_helper_tick 2>/dev/null || true
  assert_contains "$(cat "$(settings_capability_file)")" '"subscriptions": ["subscriptions-check","subscriptions-signout","subscriptions-check-chat","subscriptions-signout-chat"]'
  assert_eq "$(_job_deadline subscriptions-check)" "300 0"
}

test_the_sandboxs_managed_settings_never_set_a_login_an_environment_or_a_hook() {
  command -v jq >/dev/null 2>&1 || { echo "jq is not installed here" >&2; return 77; }
  local f
  for f in "$STACK_DIR"/terminal/managed/*.json; do
    jq -e 'type == "object"' "$f" >/dev/null || { echo "$f: not a JSON object" >&2; return 1; }
    # (they outrank every other settings tier, claude-sub's too: an env, a key helper, a hook or a forced login there
    # would reach your plan's Claude Code)
    [ -z "$(jq -r '[paths | map(tostring) | join(".")] | .[]' "$f" | grep -E '(^|\.)(env|apiKeyHelper|hooks|forceLoginMethod|forceLoginOrgUUID|awsAuthRefresh|awsCredentialExport)(\.|$)')" ] ||
      { echo "$f sets an env, a key helper, a hook or a login" >&2; return 1; }
  done
}

test_one_list_of_tools_everywhere() {
  local cat_ids sbx_ids py_ids lib_ids
  cat_ids="$(awk -F'\t' '!/^#/ && $1 != "id" && NF { print $1 }' "$STACK_DIR/catalog/ai-tools.tsv" | tr '\n' ' ')"
  sbx_ids="$(sed -n "/^TABLE='/,/'\$/p" "$STACK_DIR/terminal/bin/subscriptions" | sed "s/^TABLE='//" | cut -d'|' -f1 | tr '\n' ' ')"
  py_ids="$(sed -n 's/^TOOL_IDS = (\(.*\))$/\1/p' "$STACK_DIR/portal/portal/answers.py" | tr -d '",' )"
  lib_ids="$SUBS_TOOLS"
  assert_eq "$cat_ids" "claude codex gemini copilot cursor grok "
  assert_eq "$sbx_ids" "$cat_ids"
  assert_eq "$py_ids " "$cat_ids"
  assert_eq "$lib_ids " "$cat_ids"
  # the optional ones are what the image's build stage knows; the sign-out ones what the catalog says
  assert_contains "$(cat "$STACK_DIR/terminal/tools/install.sh")" "TOOLS_ALL=\"$SUBS_OPTIONAL\""
  assert_eq "$(awk -F'\t' '!/^#/ && $1 != "id" && $6 == "cli" { print $1 }' "$STACK_DIR/catalog/ai-tools.tsv" | tr '\n' ' ')" "$SUBS_SIGNOUT "
  # bn-session's words and the portal's (answers.TERMINAL_TOOLS): the same
  assert_contains "$(cat "$STACK_DIR/terminal/bin/bn-session")" '  claude | codex | gemini | copilot | cursor | grok) ;;'
  assert_contains "$(cat "$STACK_DIR/portal/portal/answers.py")" 'TERMINAL_TOOLS = ("bedrock", "claude", "codex", "gemini", "copilot", "cursor", "grok", "shell")'
  # the Code page's and Chat's (code/server/agents/tools.mjs): the catalog's tools but Gemini (Google's plans stopped working in
  # its CLI; follow-up), Chat's the catalog's chat_model column — each with the models its tool offers (plan-<tool>--<model>)
  local code_ids chat_ids
  code_ids="$(cd "$STACK_DIR/code" && node --input-type=module -e "import { HARNESSES } from './server/agents/tools.mjs'; console.log(Object.keys(HARNESSES).join(' '))")"
  chat_ids="$(cd "$STACK_DIR/code" && node --input-type=module -e "import { HARNESSES } from './server/agents/tools.mjs'; console.log(Object.values(HARNESSES).filter((h) => !h.noChat).map((h) => h.id).join(' '))")"
  assert_eq "$code_ids" "$(printf '%s' "$cat_ids" | tr ' ' '\n' | grep -vx gemini | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$chat_ids" "$(awk -F'\t' '!/^#/ && $1 != "id" && $7 == "yes" { print $1 }' "$STACK_DIR/catalog/ai-tools.tsv" | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$(cd "$STACK_DIR/code" && node --input-type=module -e "import { chatModelId, parseChatModel } from './server/agents/tools.mjs'; const i = chatModelId('copilot', 'gpt-5.1'); console.log(i, JSON.stringify(parseChatModel(i)))")" \
    'plan-copilot--gpt-5.1 {"tool":"copilot","model":"gpt-5.1"}'
}

test_the_image_pins_every_tool_it_downloads() {
  local d="$STACK_DIR/terminal/Dockerfile" t
  for t in CODEX COPILOT CURSOR; do
    assert_contains "$(cat "$d")" "ARG ${t}_VERSION="
    grep -Eq "^ARG ${t}_SHA256_AMD64=[0-9a-f]{64}$" "$d" || { echo "$t: no SHA-256 for amd64" >&2; return 1; }
    grep -Eq "^ARG ${t}_SHA256_ARM64=[0-9a-f]{64}$" "$d" || { echo "$t: no SHA-256 for arm64" >&2; return 1; }
  done
  # the npm ones by their lockfiles: one exact version, an integrity for every package
  for t in gemini grok; do
    grep -q '"lockfileVersion": 3' "$STACK_DIR/terminal/tools/$t/package-lock.json" || return 1
    [ "$(grep -c '"resolved"' "$STACK_DIR/terminal/tools/$t/package-lock.json")" = "$(grep -c '"integrity": "sha512-' "$STACK_DIR/terminal/tools/$t/package-lock.json")" ] || return 1
    grep -Eq '": "[0-9]+\.[0-9]+\.[0-9]+"$' "$STACK_DIR/terminal/tools/$t/package.json" || return 1
  done
  # every npm package from the npm registry itself (the lockfiles of the tools, the sandbox's Claude Code, the Code page's)
  local lf
  for lf in terminal/tools/gemini terminal/tools/grok terminal/claude-code code; do
    [ -z "$(grep -o '"resolved": "[^"]*"' "$STACK_DIR/$lf/package-lock.json" | grep -v '"resolved": "https://registry.npmjs.org/')" ] ||
      { echo "$lf/package-lock.json: a package from elsewhere than registry.npmjs.org" >&2; return 1; }
  done
  # everything of theirs root's in the image (whatever owner a tarball recorded), checked at the build's end; one tool
  # that fails is left out (said), not the image
  assert_contains "$(cat "$d")" "COPY --from=ai-tools --chown=0:0 /out/ /usr/local/lib/bn-tools/"
  assert_contains "$(cat "$STACK_DIR/terminal/tools/install.sh")" 'chown -hR 0:0 /out'
  # nothing setuid/setgid; every link relative and leading inside /out (readlink -e: there); a find that fails, fails
  i="$(cat "$STACK_DIR/terminal/tools/install.sh")"
  for want in '-perm /6000' 'ug-s' 'case "$t" in /*)' 'r="$(readlink -e "$l")" ||' 'case "$r" in /out/*) ;;' '-print)" || {' "sh {} + || {" \
              's="$(realpath -m -s "$(dirname "$l")/$t")" ||' 'case "$s" in /out/*) ;;'; do
    assert_contains "$i" "$want"
  done
  # the link check itself, on a folder of its own (where this computer's realpath reads paths as written: GNU's):
  # a link that lands in it only through a link outside it — inside as resolved, outside as written — is refused
  if realpath -m -s / >/dev/null 2>&1 && readlink -e / >/dev/null 2>&1; then
    local o chk
    o="$(cd "$TMP" && pwd -P)/out"   # (its real path: what readlink -e answers)
    mkdir -p "$o/a" "$o/stuff"; : > "$o/stuff/file"
    ln -s "$o/stuff" "$TMP/elsewhere"
    ln -s ../stuff/file "$o/a/ok"
    chk="$(sed -n "/^find \/out -type l -exec sh -c '/,/sh {} + ||/p" "$STACK_DIR/terminal/tools/install.sh" | sed "s#/out#$o#g; s/ || {.*$//")"
    sh -c "$chk" 2>/dev/null || { echo "a link that stays in it was refused" >&2; return 1; }
    ln -s ../../elsewhere/file "$o/a/sly"
    if sh -c "$chk" 2>/dev/null; then echo "a link out as written was taken" >&2; return 1; fi
  fi
  # (the build stage's /bin/sh is dash: the check is POSIX sh)
  if command -v dash >/dev/null 2>&1; then dash -n "$STACK_DIR/terminal/tools/install.sh" || return 1; fi
  [ "$(grep -c 'tar ' "$STACK_DIR/terminal/tools/install.sh")" = "$(grep -c 'tar --no-same-owner ' "$STACK_DIR/terminal/tools/install.sh")" ] || return 1
  assert_contains "$(cat "$STACK_DIR/terminal/tools/install.sh")" 'is LEFT OUT of this image'
  # Copilot's own package unpacked into the image at build (never run from the writable home)
  assert_contains "$(cat "$STACK_DIR/terminal/tools/install.sh")" 'COPILOT_PKG_CACHE_HOME=/out/copilot/cache'
  # downloads only from the providers' own places, each checked before it is kept; no install script runs
  assert_contains "$(cat "$STACK_DIR/terminal/tools/install.sh")" 'sha256sum -c -'
  assert_contains "$(cat "$STACK_DIR/terminal/tools/install.sh")" 'npm ci --ignore-scripts'
  [ -z "$(grep -oE 'https://[^"/ ]+' "$STACK_DIR/terminal/tools/install.sh" | sort -u | grep -vxE 'https://(github\.com|downloads\.cursor\.com)')" ] || return 1
  # ttyd hands the pickers' words to bn-session (as arguments, never a shell)
  assert_contains "$(cat "$STACK_DIR/terminal/bin/bn-terminal")" "--check-origin --url-arg"
}

test_chat_has_sign_ins_of_its_own_asked_and_made_in_its_sandbox_alone() {
  _stubs
  local out f
  set_env CODE_ENABLED true
  # its status: Chat's sandbox asked, its Chat tools alone kept (a Cursor or Gemini line there is not a Chat model's), in
  # a file of its own
  export TSV="$(printf 'codex\tyes\t0.163.0\tyes\tchatgpt\tcommand\n')"
  export CHAT_TSV="$(printf 'codex\tyes\t0.163.0\tno\t-\tcommand\ncursor\tyes\t1\tyes\tcursor\tcommand\ngrok\tyes\t1.0.67\tno\t-\tfile\n')"
  out="$(cmd_subscriptions status --chat)"
  assert_contains "$out" "Chat's own sign-ins"
  assert_contains "$out" "no — ./stack subscriptions login codex --chat"
  assert_not_contains "$out" "Cursor"
  f="$(SUBS_WHERE=chat subs_status_file)"
  assert_contains "$f" "subscriptions-chat.json"
  assert_contains "$(cat "$f")" '"terminal":"running","tools":[{"id":"codex","account":"","first_name":"","installed":true,"version":"0.163.0","signed_in":"no"'
  assert_not_contains "$(cat "$f")" "cursor"
  # the terminal's file untouched by it; both asked by a plain status, each in its own sandbox
  : > "$TMP/dc"
  out="$(cmd_subscriptions status)"
  assert_contains "$out" "yes — ChatGPT"
  assert_contains "$out" "Chat's own sign-ins"
  assert_contains "$(cat "$TMP/dc")" "terminal /usr/local/bin/subscriptions status --tsv"
  assert_contains "$(cat "$TMP/dc")" "subs-chat /usr/local/bin/subscriptions status --tsv"
  assert_contains "$(cat "$(subs_status_file)")" '"signed_in":"yes"'
  # a sign-in for Chat: in Chat's sandbox, never the terminal's
  : > "$TMP/dc"
  out="$(cmd_subscriptions login codex --chat 2>&1)"
  assert_contains "$out" "For Chat: Codex's own sign-in, in Chat's sandbox"
  assert_contains "$out" "sandbox│ Open https://auth.openai.com/codex/device"
  assert_contains "$(cat "$TMP/dc")" "subs-chat /usr/local/bin/subscriptions login codex"
  assert_not_contains "$(cat "$TMP/dc")" "terminal /usr/local/bin/subscriptions login"
  # not a Chat model (Cursor, Gemini CLI): refused before anything is asked; Copilot's sign-out: said how
  : > "$TMP/dc"
  out="$( (cmd_subscriptions login cursor --chat) 2>&1)" && return 1
  assert_contains "$out" "Cursor CLI is not a Chat model"
  out="$( (cmd_subscriptions logout copilot --chat) 2>&1)" && return 1
  assert_contains "$out" "subs-chat-copilot"
  assert_not_contains "$(cat "$TMP/dc")" "login"
  # the Code page off: Chat's sandbox is too — said
  set_env CODE_ENABLED false
  out="$( (cmd_subscriptions login codex --chat) 2>&1)" && return 1
  assert_contains "$out" "./stack code enable"
  out="$( (cmd_subscriptions status --chat) 2>&1)" && return 1
  assert_contains "$out" "Chat's sandbox is off"
}

# --- several accounts a tool (JON-1052): ids TOOL / TOOL:NAME, folders in ~/.subscriptions/TOOL/NAME, windows named after them

test_accounts_are_made_listed_renamed_and_removed_and_each_is_asked_as_itself() {
  command -v jq >/dev/null 2>&1 || { echo "jq is not installed here (the sandbox has it)" >&2; return 77; }
  _sandbox_bin
  # (the stub codex tells accounts apart by BN_SUB_ACCOUNT, as the real launcher does by CODEX_HOME)
  cat > "$TMP/sbin/codex" <<'EOF'
#!/bin/sh
[ "$*" = "login status" ] && { if [ -n "${BN_SUB_ACCOUNT:-}" ]; then printf '%s\n' "${CODEX_STATUS_ACCT:-Not logged in}" >&2; else printf '%s\n' "${CODEX_STATUS:-Not logged in}" >&2; fi; exit 0; }
[ "$*" = logout ] && { echo "codex logout for [${BN_SUB_ACCOUNT:-}]" >> "$TMP/codex.log"; exit 0; }
exit 0
EOF
  export TMP BN_SUBS_ROOT="$HOME/.subscriptions"
  local S="$STACK_DIR/terminal/bin/subscriptions" out
  # nobody signs in again: the first account is the tool itself; no other until one is added
  assert_eq "$(bash "$S" accounts codex | awk '{ print $1 }')" "codex"
  # add: the name asked (or given), the folder private and a real one, then that account's own sign-in
  out="$(printf 'work\n' | bash "$S" add codex 2>&1)"
  assert_contains "$out" "A name for this Codex account"
  assert_contains "$out" "Account codex:work made"
  assert_contains "$out" "Codex · work is not signed in here yet"
  [ -d "$BN_SUBS_ROOT/codex/work" ] && [ ! -L "$BN_SUBS_ROOT/codex/work" ] || { echo "no folder" >&2; return 1; }
  assert_eq "$(stat -c %a "$BN_SUBS_ROOT/codex/work" 2>/dev/null || stat -f %Lp "$BN_SUBS_ROOT/codex/work")" 700
  assert_eq "$(stat -c %a "$BN_SUBS_ROOT/codex" 2>/dev/null || stat -f %Lp "$BN_SUBS_ROOT/codex")" 700
  bash "$S" add codex personal >/dev/null 2>&1
  assert_eq "$(bash "$S" accounts codex | awk '{ print $1 }' | tr '\n' ' ')" "codex codex:personal codex:work "
  # refused: a name that is not one, one in use, a TOOL:NAME, a tool that is not there, the ninth account
  for bad in 'Work' '-x' 'a_b' 'a.b' 'abcdefghijklmnopqrstu' '../x' 'a:b' ''; do
    out="$(bash "$S" add codex "$bad" 2>&1 </dev/null)" && { echo "add took '$bad'" >&2; return 1; }
  done
  assert_contains "$(bash "$S" add codex work 2>&1)" "has an account called 'work' already"
  assert_contains "$(bash "$S" add codex:x y 2>&1)" "usage: subscriptions add TOOL"
  assert_contains "$(bash "$S" add evil x 2>&1)" "no tool called 'evil'"
  assert_contains "$(bash "$S" add bedrock x 2>&1)" "no tool called 'bedrock'"
  local i; for i in 1 2 3 4 5; do mkdir -p "$BN_SUBS_ROOT/codex/a$i"; done
  assert_eq "$(bash "$S" accounts codex | wc -l | tr -d ' ')" 8
  assert_contains "$(bash "$S" add codex ninth 2>&1)" "has 8 accounts, the most there can be"
  [ ! -e "$BN_SUBS_ROOT/codex/ninth" ] || return 1
  rm -rf "${BN_SUBS_ROOT:?}/codex/a1" "${BN_SUBS_ROOT:?}/codex/a2" "${BN_SUBS_ROOT:?}/codex/a3" "${BN_SUBS_ROOT:?}/codex/a4" "${BN_SUBS_ROOT:?}/codex/a5"
  # a link, a file, a name that is not one: not an account (and never reached through a link)
  mkdir -p "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$BN_SUBS_ROOT/codex/linked"; : > "$BN_SUBS_ROOT/codex/afile"; mkdir "$BN_SUBS_ROOT/codex/Bad_Name"
  assert_eq "$(bash "$S" accounts codex | awk '{ print $1 }' | tr '\n' ' ')" "codex codex:personal codex:work "
  assert_contains "$(bash "$S" open codex:linked 2>&1)" "has no account called 'linked'"
  # the table: one row an account, the TSV id column TOOL or TOOL:NAME, the first account's name (or -) as a seventh column
  out="$(CODEX_STATUS='Logged in using ChatGPT' CODEX_STATUS_ACCT='Logged in using ChatGPT' bash "$S" status --tsv)"
  assert_eq "$(printf '%s\n' "$out" | grep '^codex' | cut -f1,2,4,5,6 | tr '\t' ',' | tr '\n' ' ')" "codex,yes,yes,chatgpt,command codex:personal,yes,yes,chatgpt,command codex:work,yes,yes,chatgpt,command "
  assert_eq "$(printf '%s\n' "$out" | grep '^codex' | awk -F'\t' '{ print NF }' | tr '\n' ' ')" "7 6 6 "
  assert_eq "$(printf '%s\n' "$out" | grep -c '^claude')" 1
  # each account is asked as itself: signed in for the first, not for work
  out="$(CODEX_STATUS='Logged in using ChatGPT' bash "$S" status --tsv | grep '^codex')"
  assert_eq "$(printf '%s\n' "$out" | cut -f1,4 | tr '\t' ',' | tr '\n' ' ')" "codex,yes codex:personal,no codex:work,no "
  out="$(CODEX_STATUS='Logged in using ChatGPT' bash "$S" status)"
  assert_contains "$out" "Codex · work"
  assert_contains "$out" "no — subscriptions login codex:work"
  # rename: the folder moves; the first account's name is a file of its own, and no other account takes it
  assert_contains "$(bash "$S" rename codex:work office 2>&1)" "codex:work is codex:office now"
  [ -d "$BN_SUBS_ROOT/codex/office" ] && [ ! -e "$BN_SUBS_ROOT/codex/work" ] || return 1
  assert_contains "$(bash "$S" rename codex main 2>&1)" 'The first Codex account is called "main"'
  assert_eq "$(cat "$BN_SUBS_ROOT/codex/.first-name")" main
  assert_eq "$(bash "$S" status --tsv | grep '^codex	' | cut -f7)" main
  assert_contains "$(bash "$S" rename codex:office main 2>&1)" "has an account called 'main' already" || true
  assert_contains "$(bash "$S" rename codex:office personal 2>&1)" "has an account called 'personal' already"
  assert_contains "$(bash "$S" rename codex:office 'Bad Name' 2>&1)" "is not an account name"
  assert_contains "$(bash "$S" add codex main 2>&1)" "is the name of the first Codex account already"
  assert_contains "$(bash "$S" accounts codex)" "Codex · main (the first account)"
  # a name file that is not a name is not one
  printf 'Not A Name!\n' > "$BN_SUBS_ROOT/codex/.first-name"
  assert_eq "$(bash "$S" status --tsv | grep '^codex	' | cut -f7)" "-"
  printf 'main\n' > "$BN_SUBS_ROOT/codex/.first-name"
  # remove: the first cannot go; N (or nothing) keeps it; y signs it out with the tool's own sign-out, then the folder goes
  assert_contains "$(printf 'y\n' | bash "$S" remove codex 2>&1)" "cannot be removed"
  assert_contains "$(printf 'y\n' | bash "$S" remove codex:nothere 2>&1)" "has no account called 'nothere'"
  assert_contains "$(printf 'n\n' | bash "$S" remove codex:office 2>&1)" "Nothing removed"
  assert_contains "$(bash "$S" remove codex:office 2>&1 </dev/null)" "Nothing removed"
  [ -d "$BN_SUBS_ROOT/codex/office" ] || return 1
  : > "$TMP/codex.log"
  out="$(printf 'y\n' | bash "$S" remove codex:office 2>&1)"
  assert_contains "$out" "Removed codex:office"
  [ ! -e "$BN_SUBS_ROOT/codex/office" ] || return 1
  assert_eq "$(cat "$TMP/codex.log")" "codex logout for [office]"
  [ -d "$BN_SUBS_ROOT/codex/personal" ] || return 1
  # sign-in and -out take the id too
  assert_contains "$(bash "$S" logout codex:nothere 2>&1)" "has no account called 'nothere'"
  : > "$TMP/codex.log"; bash "$S" logout codex:personal >/dev/null 2>&1
  assert_eq "$(cat "$TMP/codex.log")" "codex logout for [personal]"
  : > "$TMP/codex.log"; bash "$S" logout codex >/dev/null 2>&1
  assert_eq "$(cat "$TMP/codex.log")" "codex logout for []"
  assert_contains "$(bash "$S" login 'codex:../x' 2>&1)" "is not an account name"
  assert_contains "$(bash "$S" open bedrock:x 2>&1 </dev/null)" "no account" || true
}

test_a_window_is_named_after_what_runs_in_it() {
  command -v jq >/dev/null 2>&1 || { echo "jq is not installed here (the sandbox has it)" >&2; return 77; }
  _sandbox_bin
  export BN_SUBS_ROOT="$HOME/.subscriptions" TMP
  local S="$STACK_DIR/terminal/bin/subscriptions" out
  # (a tmux of the test's own: it answers the window's folder suffix and records the rename)
  cat > "$TMP/tmux-stub" <<'EOF'
#!/bin/sh
echo "tmux $*" >> "$TMP/tmux.log"
case "$1" in show-options) printf '%s\n' "${SUFFIX:-}" ;; esac
exit 0
EOF
  chmod +x "$TMP/tmux-stub"
  export BN_TMUX_BIN="$TMP/tmux-stub" TMUX=/tmp/t,1,0 TMUX_PANE=%5
  mkdir -p "$BN_SUBS_ROOT/codex/work"
  # an account: TOOL-NAME, signed in or not
  : > "$TMP/tmux.log"; bash "$S" open codex:work >/dev/null 2>&1 </dev/null || true
  assert_contains "$(cat "$TMP/tmux.log")" "tmux rename-window -t %5 codex-work"
  # the first account without a name: the tool and its kind once known (codex-chatgpt), nothing before
  : > "$TMP/tmux.log"; CODEX_STATUS='Logged in using ChatGPT' bash "$S" open codex >/dev/null 2>&1 </dev/null || true
  assert_contains "$(cat "$TMP/tmux.log")" "tmux rename-window -t %5 codex-chatgpt"
  : > "$TMP/tmux.log"; CODEX_STATUS='API key configured - sk-abc***xyz' bash "$S" open codex >/dev/null 2>&1 </dev/null || true
  assert_contains "$(cat "$TMP/tmux.log")" "tmux rename-window -t %5 codex-api-key"
  : > "$TMP/tmux.log"; bash "$S" open codex >/dev/null 2>&1 </dev/null || true
  assert_not_contains "$(cat "$TMP/tmux.log")" "rename-window"
  # Claude's kinds already start with claude-; a kind that is not known leaves the name alone
  : > "$TMP/tmux.log"; CLAUDE_STATUS='{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}' CLAUDE_RC=0 bash "$S" open claude >/dev/null 2>&1 </dev/null || true
  assert_contains "$(cat "$TMP/tmux.log")" "tmux rename-window -t %5 claude-max"
  : > "$TMP/tmux.log"; CLAUDE_STATUS='{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"other"}' CLAUDE_RC=0 bash "$S" open claude >/dev/null 2>&1 </dev/null || true
  assert_contains "$(cat "$TMP/tmux.log")" "tmux rename-window -t %5 claude-ai"
  # the first account's own name wins; a window in a folder keeps its folder part
  printf 'main\n' > "$BN_SUBS_ROOT/codex/.first-name"
  : > "$TMP/tmux.log"; SUFFIX=-inner-0a1b2c CODEX_STATUS='Logged in using ChatGPT' bash "$S" open codex >/dev/null 2>&1 </dev/null || true
  assert_contains "$(cat "$TMP/tmux.log")" "tmux show-options -wqv -t %5 @bn-suffix"
  assert_contains "$(cat "$TMP/tmux.log")" "tmux rename-window -t %5 codex-main-inner-0a1b2c"
  # letters, digits, _ and - only, whatever the suffix says
  : > "$TMP/tmux.log"; SUFFIX='-a.b:c#d' bash "$S" open codex:work >/dev/null 2>&1 </dev/null || true
  assert_contains "$(cat "$TMP/tmux.log")" "tmux rename-window -t %5 codex-work-abcd"
  # not in tmux: no rename; Bedrock and a shell are not renamed (and take no account)
  : > "$TMP/tmux.log"; env -u TMUX -u TMUX_PANE bash "$S" open codex:work >/dev/null 2>&1 </dev/null || true
  assert_not_contains "$(cat "$TMP/tmux.log")" "rename-window"
  # add: the window found by "add:TOOL" becomes the account's (found by TOOL:NAME), named after it
  : > "$TMP/tmux.log"; printf 'travel\n' | bash "$S" add codex >/dev/null 2>&1 || true
  assert_contains "$(cat "$TMP/tmux.log")" "tmux set-option -w -t %5 @bn-open codex:travel"
  assert_contains "$(cat "$TMP/tmux.log")" "tmux rename-window -t %5 codex-travel"
}

test_each_launcher_runs_the_account_it_is_told_in_that_accounts_folder_only() {
  local b="$TMP/tools" r="$HOME/.subscriptions" out t
  mkdir -p "$b/codex/bin" "$b/copilot" "$b/cursor" "$b/gemini/node_modules/.bin" "$b/grok"
  local f
  for f in codex/bin/codex copilot/copilot cursor/cursor-agent gemini/node_modules/.bin/gemini grok/grok; do
    printf '#!/bin/sh\nenv | grep -E "^(CODEX_HOME|GEMINI_CLI_HOME|COPILOT_HOME|GROK_HOME|XDG_CONFIG_HOME|BN_SUB_ACCOUNT)=" | sort\n' > "$b/$f"; chmod +x "$b/$f"
  done
  local cl="$TMP/claude"; printf '#!/bin/sh\nif [ "$1" = --help ]; then printf "Usage: claude\\n\\nCommands:\\n  auth  x\\n"; exit 0; fi\nenv | grep -E "^(CLAUDE_CONFIG_DIR|BN_SUB_ACCOUNT)=" | sort\n' > "$cl"; chmod +x "$cl"
  export BN_TOOLS_DIR="$b" BN_CLAUDE_BIN="$cl" BN_SUBS_ROOT="$r"; unset TMUX TMUX_PANE
  local pair var tool
  # (tool, launcher, the variable it reads — confirmed in each pinned version: README "Your AI subscriptions")
  for pair in claude:claude-sub:CLAUDE_CONFIG_DIR codex:codex:CODEX_HOME gemini:gemini:GEMINI_CLI_HOME copilot:copilot:COPILOT_HOME \
      cursor:cursor-agent:XDG_CONFIG_HOME grok:grok:GROK_HOME; do
    tool="${pair%%:*}"; var="${pair##*:}"; pair="${pair#*:}"; pair="${pair%%:*}"
    mkdir -p "$r/$tool/work"
    # an account: its own folder in the tool's variable
    out="$(BN_SUB_ACCOUNT=work bash "$STACK_DIR/terminal/bin/$pair" x 2>&1)"
    assert_contains "$out" "$var=$r/$tool/work"
    assert_contains "$out" "BN_SUB_ACCOUNT=work"
    # none: the first account, exactly as before (no variable set; claude-sub its own folder)
    out="$(bash "$STACK_DIR/terminal/bin/$pair" x 2>&1)"
    if [ "$tool" = claude ]; then assert_contains "$out" "CLAUDE_CONFIG_DIR=$HOME/.claude-subscription"; else assert_not_contains "$out" "$var="; fi
    out="$(BN_SUB_ACCOUNT= bash "$STACK_DIR/terminal/bin/$pair" x 2>&1)"
    if [ "$tool" = claude ]; then assert_contains "$out" "CLAUDE_CONFIG_DIR=$HOME/.claude-subscription"; else assert_not_contains "$out" "$var="; fi
    # refused (exit 2, nothing run): a name that is not one, a folder that is not there, a link, a path
    for bad in 'Work' '../work' 'a/b' '-w' 'nothere' 'abcdefghijklmnopqrstu' 'linked' 'a b'; do
      out="$(BN_SUB_ACCOUNT="$bad" bash "$STACK_DIR/terminal/bin/$pair" x 2>&1)" && { echo "$pair took account '$bad'" >&2; return 1; }
      assert_contains "$out" "no account called"
      assert_not_contains "$out" "$var="
    done
  done
  # a link in place of the account's folder, or of the tool's: refused
  mkdir -p "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$r/codex/linked"
  out="$(BN_SUB_ACCOUNT=linked bash "$STACK_DIR/terminal/bin/codex" x 2>&1)" && return 1
  assert_contains "$out" "no account called 'linked'"
  rm "$r/codex/linked"; mv "$r/codex" "$TMP/codex-real"; ln -s "$TMP/codex-real" "$r/codex"
  out="$(BN_SUB_ACCOUNT=work bash "$STACK_DIR/terminal/bin/codex" x 2>&1)" && return 1
  assert_contains "$out" "no account called 'work'"
  # the stack's variables are still left out beside it
  rm "$r/codex"; mv "$TMP/codex-real" "$r/codex"
  out="$(ANTHROPIC_AUTH_TOKEN=k BN_SUB_ACCOUNT=work bash "$STACK_DIR/terminal/bin/codex" x 2>&1)"
  assert_not_contains "$out" "ANTHROPIC"
  assert_contains "$out" "CODEX_HOME=$r/codex/work"
}

test_the_host_reads_accounts_as_words_and_caps_them() {
  local out i rows
  rows="$(printf '%s\n' \
    "$(printf 'codex\tyes\t0.163.0\tyes\tchatgpt\tcommand\tmain')" \
    "$(printf 'codex:work\tyes\t0.163.0\tno\t-\tcommand')" \
    "$(printf 'codex:work\tyes\t0.163.0\tyes\tchatgpt\tcommand')" \
    "$(printf 'codex:Bad\tyes\t0.163.0\tyes\tchatgpt\tcommand')" \
    "$(printf 'codex:a:b\tyes\t0.163.0\tyes\tchatgpt\tcommand')" \
    "$(printf 'codex:\tyes\t0.163.0\tyes\tchatgpt\tcommand')" \
    "$(printf 'codex:-x\tyes\t0.163.0\tyes\tchatgpt\tcommand')" \
    "$(printf 'codex:abcdefghijklmnopqrstu\tyes\t0.163.0\tyes\tchatgpt\tcommand')" \
    "$(printf 'codex:x\tyes\t0.163.0\tyes\tchatgpt\tcommand\tmain')" \
    "$(printf 'evil:x\tyes\t1\tyes\t-\tnone')" \
    "$(printf 'bedrock:x\tyes\t1\tyes\t-\tnone')" \
    "$(printf 'grok:ok\tyes\t1.0.67\tyes\tchatgpt\tfile')" \
    "$(printf 'grok:ok2\tyes\t1.0.67\tyes\txai\tfile')" \
    "$(printf 'cursor\tyes\t1\tno\t-\tcommand\tBad Name')" \
    "$(printf 'gemini\tyes\t0.65.0\tno\t-\tfile\t-')" | subs_parse)"
  assert_eq "$rows" '{"id":"codex","account":"","first_name":"main","installed":true,"version":"0.163.0","signed_in":"yes","kind":"chatgpt","how":"command"}
{"id":"codex","account":"work","first_name":"","installed":true,"version":"0.163.0","signed_in":"no","kind":"","how":"command"}
{"id":"grok","account":"ok2","first_name":"","installed":true,"version":"1.0.67","signed_in":"yes","kind":"xai","how":"file"}
{"id":"gemini","account":"","first_name":"","installed":true,"version":"0.65.0","signed_in":"no","kind":"","how":"file"}'
  # at most 8 accounts a tool, the first among them
  out="$( { printf 'claude\tyes\t2.1.309\tyes\tclaude-max\tcommand\t-\n'; for i in 1 2 3 4 5 6 7 8 9 10; do printf 'claude:a%s\tyes\t2.1.309\tno\t-\tcommand\n' "$i"; done; } | subs_parse | wc -l | tr -d ' ')"
  assert_eq "$out" 8
  # ids: a tool, or TOOL:NAME
  subs_valid_id codex && subs_valid_id codex:work && subs_valid_id grok:a-1 || return 1
  for bad in '' codex: :work codex:Work codex:-a codex:a:b codex:a_b codex:abcdefghijklmnopqrstu evil evil:work 'codex:a b' 'codex:../x' 'codex:a;b'; do
    ! subs_valid_id "$bad" || { echo "subs_valid_id took '$bad'" >&2; return 1; }
  done
}

test_stack_subscriptions_takes_an_account_id_and_shows_each_account() {
  _stubs
  local out
  set_env CODE_ENABLED true
  export TSV="$(printf 'codex\tyes\t0.163.0\tyes\tchatgpt\tcommand\tmain\ncodex:work\tyes\t0.163.0\tno\t-\tcommand\ngrok\tno\t-\tno\t-\tnone\t-\n')"
  out="$(cmd_subscriptions status)"
  assert_contains "$out" "Codex · main"
  assert_contains "$out" "yes — ChatGPT"
  assert_contains "$out" "Codex · work"
  assert_contains "$out" "no — ./stack subscriptions login codex:work"
  assert_contains "$(cat "$(subs_status_file)")" '"id":"codex","account":"work","first_name":""'
  # the line `./stack terminal status` prints: tools in the sandbox (the first accounts), accounts signed in
  assert_contains "$(subs_status_line)" "1 in the sandbox, 1 signed in"
  # sign in and out by account: the id reaches the sandbox; a bad one is refused before it is asked
  : > "$TMP/dc"
  cmd_subscriptions logout codex:work >/dev/null
  assert_contains "$(cat "$TMP/dc")" "terminal /usr/local/bin/subscriptions logout codex:work"
  cmd_subscriptions login codex:work >/dev/null 2>&1 || true
  assert_contains "$(cat "$TMP/dc")" "terminal /usr/local/bin/subscriptions login codex:work"
  : > "$TMP/dc"
  for bad in 'codex:Work' 'codex:a b' 'codex:../x' 'evil:x' 'codex:'; do
    out="$( (cmd_subscriptions login "$bad") 2>&1)" && return 1
    assert_contains "$out" "no tool or account called"
  done
  assert_not_contains "$(cat "$TMP/dc")" "login"
  # Gemini and Copilot sign in and out inside themselves, for an account too
  out="$( (cmd_subscriptions logout copilot:work) 2>&1)" && return 1
  assert_contains "$out" "/logout"
  # Chat has one account a tool: its status keeps the first accounts only, and no :NAME is taken for it
  export CHAT_TSV="$(printf 'codex\tyes\t0.163.0\tno\t-\tcommand\t-\ncodex:work\tyes\t0.163.0\tyes\tchatgpt\tcommand\n')"
  cmd_subscriptions status --chat >/dev/null || true
  assert_not_contains "$(cat "$(SUBS_WHERE=chat subs_status_file)")" '"account":"work"'
  out="$( (cmd_subscriptions login codex:work --chat) 2>&1)" && return 1
  assert_contains "$out" "Chat's sandbox has one account a tool"
}

test_a_named_cursor_account_keeps_gh_glab_and_gits_identity_where_they_were() {
  local b="$TMP/tools" r="$HOME/.subscriptions" out
  mkdir -p "$b/cursor" "$r/cursor/work" "$HOME/.config/git"
  printf '#!/bin/sh\nenv | grep -E "^(XDG_CONFIG_HOME|GH_CONFIG_DIR|GLAB_CONFIG_DIR|GIT_CONFIG_[A-Z]*_?[0-9]*|GIT_CONFIG_COUNT)=" | sort\n' > "$b/cursor/cursor-agent"; chmod +x "$b/cursor/cursor-agent"
  export BN_TOOLS_DIR="$b" BN_SUBS_ROOT="$r"; unset TMUX TMUX_PANE GH_CONFIG_DIR GLAB_CONFIG_DIR GIT_CONFIG_COUNT XDG_CONFIG_HOME
  local L="$STACK_DIR/terminal/bin/cursor-agent"
  # the first account: exactly as it was (nothing set)
  out="$(bash "$L" x 2>&1)"; assert_eq "$out" ""
  # a named account: gh and glab stay in the old config folder; git's identity file is not lost (no file: no include)
  out="$(BN_SUB_ACCOUNT=work bash "$L" x 2>&1)"
  assert_contains "$out" "XDG_CONFIG_HOME=$r/cursor/work"
  assert_contains "$out" "GH_CONFIG_DIR=$HOME/.config/gh"
  assert_contains "$out" "GLAB_CONFIG_DIR=$HOME/.config/glab-cli"
  assert_not_contains "$out" "GIT_CONFIG"
  printf '[user]\n\tname = x\n' > "$HOME/.config/git/config"
  out="$(BN_SUB_ACCOUNT=work bash "$L" x 2>&1)"
  assert_contains "$out" "GIT_CONFIG_COUNT=1"
  assert_contains "$out" "GIT_CONFIG_KEY_0=include.path"
  assert_contains "$out" "GIT_CONFIG_VALUE_0=$HOME/.config/git/config"
  # an include already there keeps its place; the count grows; a set GH_CONFIG_DIR and a moved old XDG folder are respected
  out="$(BN_SUB_ACCOUNT=work GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=a.b GIT_CONFIG_VALUE_0=c GH_CONFIG_DIR=/mine bash "$L" x 2>&1)"
  assert_contains "$out" "GIT_CONFIG_COUNT=2"
  assert_contains "$out" "GIT_CONFIG_KEY_0=a.b"
  assert_contains "$out" "GIT_CONFIG_KEY_1=include.path"
  assert_contains "$out" "GH_CONFIG_DIR=/mine"
  mkdir -p "$TMP/xdg/git"; printf '[user]\n' > "$TMP/xdg/git/config"
  out="$(BN_SUB_ACCOUNT=work XDG_CONFIG_HOME="$TMP/xdg" bash "$L" x 2>&1)"
  assert_contains "$out" "GH_CONFIG_DIR=$TMP/xdg/gh"
  assert_contains "$out" "GIT_CONFIG_VALUE_0=$TMP/xdg/git/config"
  assert_contains "$out" "XDG_CONFIG_HOME=$r/cursor/work"
}
