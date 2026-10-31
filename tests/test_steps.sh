# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329  # stubs read by the libs
# lib/steps.sh and the timed steps of setup and ./stack update (Home's update card: every stretch a step with its time):
# the image downloads (side by side; one pinned by its digest that is here already is not asked for), what a build
# says of each image (from Docker's cache, or what was built again; the subscription tools' stage), the sandboxes'
# images in the background, timed_step, and the key the subscription tools are kept under (terminal/tools/install.sh
# tool_key: what is installed, never the script's text or npm's flags). Docker is stubbed.
. "$STACK_DIR/lib/commands.sh"

# --- timed steps ---

test_a_timed_step_says_when_it_starts_and_how_long_it_took() {
  _now() { echo 100; }
  out="$(DEVOS_ADE_JOB_ORIGIN=helper timed_step "Smoke test" echo "its own words" 2>&1)"
  assert_eq "$out" "$(printf '==> Smoke test: starting…\nits own words\n==> Smoke test ready (0s)')"
  # not a helper job: its words and its time
  out="$(timed_step "Smoke test" echo "its own words" 2>&1)"
  assert_eq "$out" "$(printf 'its own words\n==> Smoke test ready (0s)')"
  # a failure where set -e is off: said, and returned
  if out="$(timed_step "Smoke test" false 2>&1)"; then echo "a failure must be returned" >&2; return 1; fi
  assert_contains "$out" "Smoke test failed after 0s"
  assert_not_contains "$out" "ready"
  # variables it sets stay set (the same shell, never a subshell)
  _set_it() { SET_BY_STEP=yes; }
  timed_step "Set" _set_it 2>/dev/null; assert_eq "${SET_BY_STEP:-}" yes
  # under set -e a failure ends the command right there, as without timed_step
  # (a shell of its own: in the test's, set -e is off — bash ignores it inside a function run as a condition)
  out="$("$BASH" -c 'set -e; . "$STACK_DIR/lib/commands.sh"; timed_step Stops false; echo "went on"' 2>&1)" || true
  assert_not_contains "$out" "went on"
}

# Every stretch of setup and of ./stack update is a step of its own: nothing between them goes untimed on Home's card
test_setup_and_update_time_each_of_their_stretches() {
  local c
  c="$(sed -n '/^cmd_setup() {/,/^}/p' "$STACK_DIR/lib/commands.sh")"
  for want in 'timed_step "AWS key check" setup_aws_creds' 'timed_step "Ports and settings in .env" _setup_settings' \
              'timed_step "Voice" stt_after_probe' 'timed_step "Web search check" websearch_after_start' \
              'timed_step "Code page default" code_default_on' 'timed_step "Smoke test" _setup_smoke_test' 'timed_step "Finishing" _setup_finish'; do
    assert_contains "$c" "$want"
  done
  c="$(sed -n '/^setup_bringup_and_probe() {/,/^}/p' "$STACK_DIR/lib/commands.sh")"
  for want in 'timed_step "Prices" _setup_prices' 'timed_step "Image downloads" _setup_downloads' 'timed_step "Open WebUI image" _setup_owui_image' \
              'timed_step "LiteLLM config: web search check, default models"' 'timed_step "LiteLLM setup key"' 'timed_step "Model check" _setup_model_check'; do
    assert_contains "$c" "$want"
  done
  c="$(sed -n '/^setup_keys_and_ui() {/,/^}/p' "$STACK_DIR/lib/commands.sh")"
  for want in 'timed_step "LiteLLM keys, Admin sign-in, voice service"' 'timed_step "Portal sign-in and Chat'"'"'s API key"' 'timed_step "Open WebUI syncs (models, prices, banner)"'; do
    assert_contains "$c" "$want"
  done
  c="$(sed -n '/^cmd_update() {/,/^}/p' "$STACK_DIR/lib/commands.sh")"
  for want in 'timed_step "Backup" _update_backup' 'timed_step "New code (git)" update_checkout' 'timed_step "Image downloads started" pulls_start' \
              'timed_step "Old images cleaned up" _update_cleanup' 'timed_step "What'"'"'s new" update_whats_new'; do
    assert_contains "$c" "$want"
  done
  assert_contains "$(sed -n '/^terminal_setup_hook() {/,/^}/p' "$STACK_DIR/lib/terminal.sh")" 'timed_step "Terminal: its key and project folders"'
  c="$(sed -n '/^code_setup_hook() {/,/^}/p' "$STACK_DIR/lib/code.sh")"
  assert_contains "$c" 'timed_step "Chat'"'"'s sandbox" _subs_chat_up'
  assert_contains "$c" 'timed_step "Open WebUI with your subscriptions" _code_owui_up'
}

# --- image downloads ---

_pull_stubs() {
  export PRESENT=" pgvector/pgvector:0.8.7-pg17 caddy:2.11.7-alpine@sha256:aaaa " FAIL=''
  docker() {
    case "$1 $2" in
      "image inspect") case "$PRESENT" in *" $3 "*) return 0 ;; esac; return 1 ;;
    esac
    case "$1" in
      pull) echo "pull $2" >> "$TMP/pulls"; case " $FAIL " in *" $2 "*) echo "toomanyrequests: rate limit"; return 1 ;; esac; echo "Status: Downloaded newer image for $2" ;;
    esac
    return 0
  }
  dc() {
    case "$*" in
      "config --images") printf '%s\n' bn-t/portal:local ghcr.io/berriai/litellm:1.105.0 pgvector/pgvector:0.8.7-pg17 \
        caddy:2.11.7-alpine@sha256:aaaa searxng/searxng:1@sha256:bbbb ghcr.io/berriai/litellm:1.105.0 bn-t/terminal:local ;;
    esac
  }
  project_name() { echo bn-t; }
}

test_an_update_downloads_side_by_side_and_skips_digest_pins_that_are_here() {
  _pull_stubs
  # a tag is asked again (a rebuilt image under it); a digest that is here never is
  pull_needed ghcr.io/berriai/litellm:1.105.0 || return 1
  pull_needed pgvector/pgvector:0.8.7-pg17 || return 1
  if pull_needed caddy:2.11.7-alpine@sha256:aaaa; then echo "a digest pin that is here was asked again" >&2; return 1; fi
  pull_needed searxng/searxng:1@sha256:bbbb || return 1
  # the list: compose's images, once each, without this install's own builds
  assert_eq "$(update_pull_refs | tr '\n' ' ')" "ghcr.io/berriai/litellm:1.105.0 pgvector/pgvector:0.8.7-pg17 caddy:2.11.7-alpine@sha256:aaaa searxng/searxng:1@sha256:bbbb "
  assert_eq "$(image_short ghcr.io/berriai/litellm:1.105.0)|$(image_short caddy:2.11.7-alpine@sha256:aaaa)" "litellm:1.105.0|caddy:2.11.7-alpine"
  pulls_start 2> "$TMP/start"
  assert_contains "$(cat "$TMP/start")" "downloading 3 image(s) side by side while setup builds (1 here already, pinned by digest)"
  # setup waits for them, then says each one's time
  DEVOS_ADE_PULLS_DIR="$PULLS_DIR" DEVOS_ADE_PULLS_PID="$PULLS_PID" pulls_wait 2> "$TMP/wait"
  assert_eq "$(sort "$TMP/pulls" | tr '\n' ' ')" "pull ghcr.io/berriai/litellm:1.105.0 pull pgvector/pgvector:0.8.7-pg17 pull searxng/searxng:1@sha256:bbbb "
  for want in "Download litellm:1.105.0 ready (" "Download pgvector:0.8.7-pg17 ready (" "Download searxng:1 ready (" \
              "here already, pinned by digest (not asked again): caddy:2.11.7-alpine"; do
    assert_contains "$(cat "$TMP/wait")" "$want"
  done
  [ ! -e "$PULLS_DIR" ] || { echo "the downloads' folder was left" >&2; return 1; }
  # setup run by itself (no update): nothing to wait for
  assert_eq "$(pulls_wait 2>&1)" ""
}

test_a_download_that_fails_stops_setup_before_anything_runs_its_image() {
  _pull_stubs; FAIL="ghcr.io/berriai/litellm:1.105.0"
  pulls_start 2>/dev/null
  if out="$( (DEVOS_ADE_PULLS_DIR="$PULLS_DIR" DEVOS_ADE_PULLS_PID="$PULLS_PID" pulls_wait) 2>&1)"; then echo "a failed download must stop setup" >&2; return 1; fi
  assert_contains "$out" "could not download ghcr.io/berriai/litellm:1.105.0 — its last words:"
  assert_contains "$out" "toomanyrequests: rate limit"
  assert_contains "$out" "image download failed (network/registry?): ghcr.io/berriai/litellm:1.105.0 — nothing was started with this version's images yet"
  assert_contains "$out" "Download pgvector:0.8.7-pg17 ready ("
  # the download process gone before it finished (the update stopped): what has no result counts as failed
  _pull_stubs
  pulls_start 2>/dev/null; wait "$PULLS_PID" 2>/dev/null
  rm -f "$PULLS_DIR/done" "$PULLS_DIR/1.res"
  if out="$( (DEVOS_ADE_PULLS_DIR="$PULLS_DIR" DEVOS_ADE_PULLS_PID=999999 pulls_wait) 2>&1)"; then echo "an unfinished download must stop setup" >&2; return 1; fi
  assert_contains "$out" "image download failed (network/registry?): ghcr.io/berriai/litellm:1.105.0"
}

# setup waits for the downloads before Postgres and LiteLLM start (they are the first to run a new image), and an
# update hands them to its setup
test_setup_waits_for_the_downloads_before_it_starts_anything() {
  local c
  c="$(sed -n '/^setup_bringup_and_probe() {/,/^}/p' "$STACK_DIR/lib/commands.sh")"
  [ "$(printf '%s\n' "$c" | grep -n '_setup_downloads' | head -n 1 | cut -d: -f1)" -lt "$(printf '%s\n' "$c" | grep -n '_up_data_services' | head -n 1 | cut -d: -f1)" ] ||
    { echo "Postgres starts before the downloads are waited for" >&2; return 1; }
  assert_contains "$(sed -n '/^_setup_downloads() /p' "$STACK_DIR/lib/commands.sh")" "pulls_wait; ensure_images"
  c="$(sed -n '/^cmd_update() {/,/^}/p' "$STACK_DIR/lib/commands.sh")"
  assert_contains "$c" 'pullenv=(DEVOS_ADE_PULLS_DIR="$PULLS_DIR" DEVOS_ADE_PULLS_PID="$PULLS_PID")'
  assert_contains "$c" '-u DEVOS_ADE_PULLS_DIR -u DEVOS_ADE_PULLS_PID'
}

# --- builds ---

_plain_build() {   # BuildKit's plain output of a build, stamped (seconds since it began), as build_plain writes it
  cat <<'EOF'
0 #1 [internal] load local bake definitions
0 #1 DONE 0.0s
0 #2 [portal internal] load build definition from Dockerfile
0 #2 DONE 0.0s
1 #7 [portal runtime 3/8] RUN pip install --no-cache-dir -r requirements.txt
1 #7 CACHED
1 #8 [shared-mcp runtime 2/4] COPY server.py /app/
2 #8 DONE 0.4s
3 #9 [terminal ai-tools 4/4] RUN --mount=type=cache,id=devos-ade-ai-tools,target=/var/cache/bn-tools,sharing=locked sh /tmp/tools/install.sh
50 #9 41.20 ai-tools: installed: gemini; kept: codex copilot cursor grok
51 #9 DONE 47.9s
52 #10 [terminal 2/20] RUN apt-get -o Acquire::Retries=5 update && apt-get install -y curl git
60 #10 DONE 8.1s
2 #11 [portal] exporting to image
2 #11 naming to docker.io/bn-t/portal:local done
2 #11 DONE 0.1s
5 #12 [shared-mcp] exporting to image
5 #12 naming to docker.io/bn-t/shared-mcp:local done
70 #13 [terminal] exporting to image
71 #13 naming to docker.io/bn-t/terminal:local done
71 #13 DONE 1.0s
EOF
}

test_a_build_says_when_each_image_was_ready_and_what_was_built_again() {
  _plain_build > "$TMP/build"
  assert_eq "$(build_report < "$TMP/build")" "$(printf 'portal\t2\t0\t\t0\nshared-mcp\t5\t1\tCOPY server.py /app/\t0\nterminal\t71\t2\tRUN sh /tmp/tools/install.sh\t47\ntools\t-\t1\tinstalled: gemini; kept: codex copilot cursor grok\t47')"
  out="$(build_steps "$TMP/build" 2>&1)"
  assert_contains "$out" "==> Image portal (from Docker's cache) ready (2s)"
  assert_contains "$out" "==> Image shared-mcp (rebuilt from COPY server.py /app/, 0s) ready (5s)"
  assert_contains "$out" "==> Image terminal (rebuilt from RUN sh /tmp/tools/install.sh, 47s) ready (1m11s)"
  assert_contains "$out" "==> Subscription tools (installed: gemini; kept: codex copilot cursor grok) ready (47s)"
  # the tools' stage from Docker's cache: nothing ran
  sed -e 's/^50 #9 41.20 .*$//' -e 's/^51 #9 DONE 47.9s$/3 #9 CACHED/' "$TMP/build" > "$TMP/build2"
  assert_contains "$(build_steps "$TMP/build2" 2>&1)" "==> Subscription tools (pinned, unchanged) ready (0s)"
  # an output it cannot read: no step, no error
  printf 'something else entirely\n' > "$TMP/build3"
  assert_eq "$(build_steps "$TMP/build3" 2>&1)" ""
}

test_the_sandboxes_images_build_in_the_background_and_the_terminal_waits_for_them() {
  BUILD_TICK_S=150
  build_plain() { echo "$*" > "$TMP/args"; sleep 1; _plain_build; }
  SETUP_BUILT=' portal shared-mcp open-webui '
  sandbox_build_start --build-arg APT_REFRESH=2026-44 -- terminal terminal-egress code
  [ -n "$SANDBOX_BUILD_PID" ] || return 1
  # (meanwhile setup goes on; the images are not taken as built yet)
  if built_now terminal; then echo "taken as built before the build ended" >&2; return 1; fi
  out="$(sandbox_build_wait 2>&1; printf '|%s|' "$SETUP_BUILT")"
  assert_eq "$(cat "$TMP/args")" "--build-arg APT_REFRESH=2026-44 terminal terminal-egress code"
  assert_contains "$out" "==> Image terminal (rebuilt from RUN sh /tmp/tools/install.sh, 47s) ready (1m11s)"
  assert_contains "$out" "==> Sandbox images ready ("
  assert_contains "$out" "| portal shared-mcp open-webui terminal terminal-egress code |"
  # a build that failed: said; each image is built on its own next
  build_plain() { echo "0 ERROR: failed to solve"; return 1; }
  SETUP_BUILT=' portal '
  sandbox_build_start -- terminal
  out="$(sandbox_build_wait 2>&1; printf '|%s|' "$SETUP_BUILT")"
  assert_contains "$out" "the sandbox's images did not build side by side — each is built on its own next"
  assert_contains "$out" "ERROR: failed to solve"
  assert_contains "$out" "| portal |"
  # setup waits for it before the terminal's own step, and a build of its own never runs beside it
  assert_contains "$(sed -n '/^terminal_setup_hook() {/,/^}/p' "$STACK_DIR/lib/terminal.sh")" "sandbox_build_wait"
  assert_contains "$(sed -n '/^terminal_build() {/,/^}/p' "$STACK_DIR/lib/terminal.sh")" 'sandbox_build_wait'
  assert_contains "$(sed -n '/^code_build() {/,/^}/p' "$STACK_DIR/lib/code.sh")" 'sandbox_build_wait'
  # a setup that ends before it collected the build waits for it (no build of this run names an image after it)
  assert_contains "$(sed -n '/^sandbox_build_start() {/,/^}/p' "$STACK_DIR/lib/steps.sh")" "on_exit _sandbox_build_reap"
}

# --- the subscription tools: installed again only when what is installed changes ---

# _tool_key TOOL ARCH [VAR=VALUE…] — terminal/tools/install.sh's tool_key over $TMP/tools (a copy), with the
# Dockerfile's pins
_tool_key() {
  local t="$1" a="$2"; shift 2
  ( eval "$(sed -nE 's/^ARG ((CODEX|COPILOT|CURSOR)_[A-Z0-9_]*)=(.*)$/export \1=\3/p' "$STACK_DIR/terminal/Dockerfile")"
    export BN_TOOLS_LIB=1 BN_TOOLS_SRC="$TMP/tools" BN_TOOLS_NODE=v24.21.0
    for kv in "$@"; do export "${kv?}"; done
    . "$TMP/tools/install.sh"; tool_key "$t" "$a" )
}

test_the_subscription_tools_are_kept_under_what_is_installed_never_the_scripts_text() {
  local t k before=''
  rm -rf "$TMP/tools"; cp -R "$STACK_DIR/terminal/tools" "$TMP/tools"
  for t in codex copilot cursor gemini grok; do
    k="$(_tool_key "$t" amd64)"
    printf '%s' "$k" | grep -Eqx '[0-9a-f]{64}' || { echo "$t: no key ($k)" >&2; return 1; }
    before="$before $t=$k"
  done
  # the same again: the same keys
  for t in codex copilot cursor gemini grok; do assert_contains "$before" " $t=$(_tool_key "$t" amd64)"; done
  # an edit of the script — npm's and curl's network flags, a comment: no tool is installed again
  sed -e 's/--fetch-retries=5/--fetch-retries=9/' -e 's/curl -fsSL --retry 3/curl -fsSL --retry 7/' "$STACK_DIR/terminal/tools/install.sh" > "$TMP/tools/install.sh"
  printf '\n# a comment\n' >> "$TMP/tools/install.sh"
  ! cmp -s "$STACK_DIR/terminal/tools/install.sh" "$TMP/tools/install.sh" || return 1
  for t in codex copilot cursor gemini grok; do assert_contains "$before" " $t=$(_tool_key "$t" amd64)"; done
  # a new pin: that tool alone
  k="$(_tool_key codex amd64 CODEX_VERSION=9.9.9)"; assert_not_contains "$before" " codex=$k"
  assert_contains "$before" " gemini=$(_tool_key gemini amd64 CODEX_VERSION=9.9.9)"
  k="$(_tool_key copilot amd64 COPILOT_SHA256_ARM64=0000)"; assert_not_contains "$before" " copilot=$k"
  # a new lockfile: that tool alone
  printf '\n' >> "$TMP/tools/gemini/package-lock.json"
  assert_not_contains "$before" " gemini=$(_tool_key gemini amd64)"
  assert_contains "$before" " grok=$(_tool_key grok amd64)"
  cp "$STACK_DIR/terminal/tools/gemini/package-lock.json" "$TMP/tools/gemini/package-lock.json"
  assert_contains "$before" " gemini=$(_tool_key gemini amd64)"
  # another platform, or another Node for the npm ones: installed again; the binaries do not depend on Node
  assert_not_contains "$before" " codex=$(_tool_key codex arm64)"
  assert_not_contains "$before" " grok=$(_tool_key grok amd64 BN_TOOLS_NODE=v26.0.0)"
  assert_contains "$before" " cursor=$(_tool_key cursor amd64 BN_TOOLS_NODE=v26.0.0)"
  # the Dockerfile's stage keeps them in its own cache, and the script says what it installed and what it kept
  assert_contains "$(cat "$STACK_DIR/terminal/Dockerfile")" "RUN --mount=type=cache,id=devos-ade-ai-tools,target=/var/cache/bn-tools,sharing=locked sh /tmp/tools/install.sh"
  assert_contains "$(cat "$STACK_DIR/terminal/tools/install.sh")" 'echo "ai-tools: installed:${installed:- none}; kept:${kept:- none}"'
}
