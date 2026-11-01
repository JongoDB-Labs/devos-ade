# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2329  # literal ${...} in patterns; stubs read by the libs
# Setup and ./stack update recreate only the services whose image or configuration changed (JON-499). Compose decides:
# it recreates a container when its service's configuration hash, or its image, differs from the running container's
# (`docker compose config --hash`: the hash `up` compares). ./stack gives it the checksums of the files a service reads
# only at its start (lib/common.sh config_sums), and setup's ups never pass --force-recreate (up_services).
. "$STACK_DIR/lib/commands.sh"

# _hash_stack — a copy of this checkout's compose files, Caddy files and managed settings in $TMP/stack, LiteLLM's
# config and hook and SearXNG's settings of its own, and an .env with the terminal and the Code page on; dc renders
# it with the real docker compose (config only: no daemon, no container)
_hash_stack() {
  [ -n "${BN_REAL_DOCKER:-}" ] && "$BN_REAL_DOCKER" compose version >/dev/null 2>&1 || { echo "no docker compose" >&2; return 77; }
  docker() { case "$*" in *" config --hash "*) "$BN_REAL_DOCKER" "$@" ;; *) echo "unexpected docker $*" >&2; return 97 ;; esac; }
  local real="$STACK_DIR"
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR/litellm" "$STACK_DIR/searxng" "$STACK_DIR/terminal" "$TMP/ws"
  cp "$real"/compose*.yaml "$STACK_DIR/"; cp -R "$real/caddy" "$STACK_DIR/"; cp -R "$real/terminal/managed" "$STACK_DIR/terminal/"
  printf 'model_list: []\n' > "$STACK_DIR/litellm/config.yaml"; printf '# hook v1\n' > "$STACK_DIR/litellm/bn_hooks.py"
  printf 'code-models v1\n' > "$STACK_DIR/litellm/code-models.tsv"; printf 'server:\n  port: 8080\n' > "$STACK_DIR/searxng/settings.yml"
  printf 'POSTGRES_PASSWORD=p\nRUSTFS_ACCESS_KEY=a\nRUSTFS_SECRET_KEY=s\nLITELLM_MASTER_KEY=m\nLITELLM_SALT_KEY=s\nLITELLM_UI_PASSWORD=u\nWEBUI_SECRET_KEY=w\nOPENWEBUI_ADMIN_EMAIL=a@b.c\nOPENWEBUI_ADMIN_PASSWORD=p\nSHARED_MCP_TOKEN=t\nLITELLM_KEY_TERMINAL=sk-term\nTERMINAL_PROXY_SECRET=0123456789abcdef0123456789abcdef\nTERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nTERMINAL_UID=501\nTERMINAL_GID=20\nCODE_ENABLED=true\nCODE_PROXY_SECRET=fedcba9876543210fedcba9876543210\nOWUI_DEFAULT_MODEL=claude-sonnet-5-5\n' "$TMP/ws" > "$ENV_FILE"
}
# _hashes -> "service hash" lines, as compose computes them for `up`
_hashes() { dc config --hash '*' 2>&1 | sort; }
# _changed BEFORE -> the services whose hash differs from BEFORE's (a word each, sorted)
_changed() { _hashes | diff <(printf '%s\n' "$1") - | awk '/^>/ { print $2 }' | sort | tr '\n' ' ' | sed 's/ $//'; }

test_an_unchanged_service_is_not_recreated_and_a_changed_mounted_config_is() {
  _hash_stack || return
  local h
  h="$(_hashes)"
  assert_contains "$h" "terminal-gateway "; assert_contains "$h" "searxng "; assert_contains "$h" "subs-chat "
  # nothing changed: every hash the same (compose recreates nothing); a rendered file written again the same, too
  assert_eq "$(_changed "$h")" ""
  printf 'model_list: []\n' > "$STACK_DIR/litellm/config.yaml.new"; mv "$STACK_DIR/litellm/config.yaml.new" "$STACK_DIR/litellm/config.yaml"
  assert_eq "$(_changed "$h")" ""
  # each file a service reads only at its start, changed: that service, and only it
  printf 'model_list: [x]\n' > "$STACK_DIR/litellm/config.yaml"; assert_eq "$(_changed "$h")" litellm
  h="$(_hashes)"; printf '# hook v2\n' > "$STACK_DIR/litellm/bn_hooks.py"; assert_eq "$(_changed "$h")" litellm
  # (what LiteLLM's hook reads again by itself, when it changes: no restart)
  h="$(_hashes)"; printf 'code-models v2\n' > "$STACK_DIR/litellm/code-models.tsv"; assert_eq "$(_changed "$h")" ""
  printf '\n# new\n' >> "$STACK_DIR/caddy/Caddyfile"; assert_eq "$(_changed "$h")" caddy
  h="$(_hashes)"; printf '\n# new\n' >> "$STACK_DIR/caddy/code-on.caddy"; assert_eq "$(_changed "$h")" caddy
  h="$(_hashes)"; printf '\n# new\n' >> "$STACK_DIR/caddy/terminal-gateway.caddy"; assert_eq "$(_changed "$h")" terminal-gateway
  h="$(_hashes)"; printf 'search:\n  formats: [json]\n' >> "$STACK_DIR/searxng/settings.yml"; assert_eq "$(_changed "$h")" searxng
  # Claude Code's managed settings, a mount of one file: the policy in use (off.json) recreates the terminal; another
  # policy's file nothing; Chat's own, Chat's sandbox
  h="$(_hashes)"; printf '{"x": 1}\n' > "$STACK_DIR/terminal/managed/off.json"; assert_eq "$(_changed "$h")" terminal
  h="$(_hashes)"; printf '{"x": 2}\n' > "$STACK_DIR/terminal/managed/on.json"; assert_eq "$(_changed "$h")" ""
  printf '{"x": 3}\n' > "$STACK_DIR/terminal/managed/chat.json"; assert_eq "$(_changed "$h")" subs-chat
  # a file replaced by a new one of the same content (git checkout, mv): nothing
  h="$(_hashes)"; cp "$STACK_DIR/caddy/Caddyfile" "$TMP/C"; rm "$STACK_DIR/caddy/Caddyfile"; mv "$TMP/C" "$STACK_DIR/caddy/Caddyfile"
  assert_eq "$(_changed "$h")" ""
}

test_a_changed_env_value_or_image_recreates_the_services_that_use_it() {
  _hash_stack || return
  local h
  h="$(_hashes)"
  # an .env value: the services whose configuration names it (Open WebUI's default model; the terminal's key, which the
  # portal shows too)
  sed -i.bak 's/^OWUI_DEFAULT_MODEL=.*/OWUI_DEFAULT_MODEL=claude-opus-5-5/' "$ENV_FILE"; assert_eq "$(_changed "$h")" open-webui
  h="$(_hashes)"; sed -i.bak 's/^LITELLM_KEY_TERMINAL=.*/LITELLM_KEY_TERMINAL=sk-new/' "$ENV_FILE"; assert_eq "$(_changed "$h")" "portal terminal"
  # Settings' auto mode switch: another managed-settings file for the terminal (its mount's source and its checksum)
  h="$(_hashes)"; printf 'TERMINAL_AUTO_MODE=true\n' >> "$ENV_FILE"; assert_eq "$(_changed "$h")" terminal
  # an image pinned anew (an update's compose.yaml): that service. (An image built here keeps its name and gets a new
  # ID: compose compares the container's image with it at each up — setup builds every image before its ups.)
  h="$(_hashes)"; sed -i.bak -E 's#(ghcr.io/berriai/litellm:)[0-9.]+#\19.99.9#' "$STACK_DIR/compose.yaml"
  assert_eq "$(_changed "$h")" litellm
}

# config_sums: one line a service, a checksum of names and contents (nothing for a file that is not there), the
# terminal's for the policy Settings chose
test_config_sums_cover_each_file_read_at_start() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR/litellm" "$STACK_DIR/caddy" "$STACK_DIR/terminal/managed"
  : > "$ENV_FILE"
  local a b
  a="$(config_sums)"
  assert_eq "$(printf '%s\n' "$a" | cut -d= -f1 | tr '\n' ' ')" "BN_LITELLM_CONFIG_SUM BN_CADDY_CONFIG_SUM BN_GATEWAY_CONFIG_SUM BN_OLLAMA_GATE_CONFIG_SUM BN_SEARXNG_SETTINGS_SUM BN_TERMINAL_POLICY_SUM BN_CHAT_POLICY_SUM "
  assert_eq "$(printf '%s\n' "$a" | cut -d= -f2 | tr -d '\n')" ""   # no file yet: no checksum
  printf 'a\n' > "$STACK_DIR/caddy/Caddyfile"; printf 'b\n' > "$STACK_DIR/terminal/managed/off.json"; printf 'c\n' > "$STACK_DIR/terminal/managed/on.json"
  a="$(config_sums)"
  assert_contains "$a" "BN_TERMINAL_POLICY_SUM=$(files_sum "$STACK_DIR/terminal/managed" off.json)"
  printf 'TERMINAL_AUTO_MODE=true\n' > "$ENV_FILE"
  assert_contains "$(config_sums)" "BN_TERMINAL_POLICY_SUM=$(files_sum "$STACK_DIR/terminal/managed" on.json)"
  # (the same bytes under another name is another file)
  assert_eq "$(files_sum "$STACK_DIR/caddy" Caddyfile | grep -c '^[0-9]*-[0-9]*$')" 1
  printf 'a\n' > "$STACK_DIR/caddy/x.caddy"
  [ "$(files_sum "$STACK_DIR/caddy" Caddyfile)" != "$(files_sum "$STACK_DIR/caddy" x.caddy)" ] || { echo "names not in the checksum" >&2; return 1; }
  # every dc call passes them (so no call sees a configuration without them, which would recreate a service)
  docker() { env | grep '^BN_.*_SUM=' | sort > "$TMP/env"; }
  dc ps
  assert_eq "$(cut -d= -f1 "$TMP/env" | tr '\n' ' ')" "BN_CADDY_CONFIG_SUM BN_CHAT_POLICY_SUM BN_GATEWAY_CONFIG_SUM BN_LITELLM_CONFIG_SUM BN_OLLAMA_GATE_CONFIG_SUM BN_SEARXNG_SETTINGS_SUM BN_TERMINAL_POLICY_SUM "
  assert_contains "$(cat "$TMP/env")" "BN_CADDY_CONFIG_SUM=$(files_sum "$STACK_DIR/caddy" Caddyfile x.caddy)"
}

# up_services: one compose call for the services listed, never --force-recreate, except for a container that runs
# unhealthy (up --wait would only wait on it): recreated first, alone
test_up_services_lets_compose_decide_and_recreates_only_an_unhealthy_one() {
  dc() { echo "dc $*" >> "$TMP/dc"; case "$*" in "ps --format"*) printf 'portal healthy\ncaddy unhealthy\nopen-webui \n' ;; esac; return 0; }
  up_services --no-deps portal caddy open-webui || return 1
  assert_eq "$(cat "$TMP/dc")" "dc ps --format {{.Service}} {{.Health}} portal caddy open-webui
dc up -d --no-deps --force-recreate caddy
dc up -d --wait --no-deps portal caddy open-webui"
  dc() { echo "dc $*" >> "$TMP/dc"; case "$*" in "ps --format"*) printf 'litellm healthy\n' ;; "up -d --wait"*) return 3 ;; esac; return 0; }
  : > "$TMP/dc"
  if up_services litellm; then echo "a failed up passed" >&2; return 1; fi
  assert_eq "$(cat "$TMP/dc")" "dc ps --format {{.Service}} {{.Health}} litellm
dc up -d --wait litellm"
}

# When the up would change nothing, there is none (JON-972): each service it would bring up runs, healthy, with the
# configuration hash and the image compose would give it now, under the same networks' configuration and networks as
# the last up of the same services. (tests/run.sh sets DEVOS_ADE_UP_ALWAYS=1 for the other tests; these unset it.)
# _up_stack: a stack of four — portal and caddy (with health checks), litellm (none), rustfs-init (a one-shot, done)
_up_stack() {
  unset DEVOS_ADE_UP_ALWAYS
  ROWS='portal|c1|running|Up 2 minutes (healthy)|hp
caddy|c2|running|Up 2 minutes (healthy)|hc
litellm|c3|running|Up 3 minutes|hl
rustfs-init|c4|exited|Exited (0) 3 minutes ago|hr'
  HASHES='caddy hc
litellm hl
portal hp
rustfs-init hr'
  NETDEF='  default:
    name: p_default'
  NETS='n1'
  CI='c1 sha256:i1 p/portal:local
c2 sha256:i2 caddy:2
c3 sha256:i3 litellm:1
c4 sha256:i4 aws:2'
  II='p/portal:local sha256:i1
caddy:2 sha256:i2
litellm:1 sha256:i3
aws:2 sha256:i4'
  # (the services: section of its configuration differs each time: what their hashes are for)
  dc() {
    echo "dc $*" >> "$TMP/dc"
    case "$*" in
      "ps --format"*) shift 3; local s; for s in "$@"; do printf '%s\n' "$ROWS" | awk -F'|' -v s="$s" '$1 == s { print $1, ($4 ~ /\(unhealthy\)/ ? "unhealthy" : $4 ~ /\(healthy\)/ ? "healthy" : "") }'; done ;;
      "config --hash *") printf '%s\n' "$HASHES" ;;
      config) printf 'name: p\nservices:\n  portal:\n    image: p/portal:local %s\nnetworks:\n%s\n' "$RANDOM" "$NETDEF" ;;
    esac
    return 0
  }
  docker() {
    local a
    case "$1 $2" in
      "ps -a") printf '%s\n' "$ROWS" ;;
      "network ls") printf '%s\n' $NETS ;;
      "container inspect") shift 4; for a in "$@"; do printf '%s\n' "$CI" | awk -v c="$a" '$1 == c { print $2, $3 }'; done ;;
      "image inspect") shift 4; for a in "$@"; do printf '%s\n' "$II" | awk -v t="$a" '$1 == t { print $2; f = 1 } END { exit !f }' || return 1; done ;;
      *) echo "unexpected docker $*" >&2; return 97 ;;
    esac
  }
}
# _ups ARG... -> how many `dc up` up_services made (it passes)
_ups() { : > "$TMP/dc"; up_services "$@" >/dev/null || { echo "up_services $* failed" >&2; return 1; }; grep -c '^dc up' "$TMP/dc" || true; }

test_up_services_makes_no_compose_call_when_nothing_would_change() {
  _up_stack
  # the first up of these services: compose's (nothing recorded yet); the next, none — Docker's answers alone
  assert_eq "$(_ups --no-deps portal caddy)" 1
  assert_eq "$(head -n 1 "$STATE_DIR/up-converged" | wc -w | tr -d ' ')" 2
  assert_eq "$(_ups --no-deps portal caddy)" 0
  assert_eq "$(grep -c '^dc up\|^dc config' "$TMP/dc")" 2
  # other services, or the same in another call: compose's, the first time
  assert_eq "$(_ups --no-deps litellm)" 1; assert_eq "$(_ups --no-deps litellm)" 0; assert_eq "$(_ups --no-deps portal caddy)" 0
  # a configuration that changed: compose's (for the services it is about only)
  HASHES="${HASHES/caddy hc/caddy hc2}"
  assert_eq "$(_ups --no-deps portal caddy)" 1; assert_eq "$(_ups --no-deps litellm)" 0
  HASHES="${HASHES/caddy hc2/caddy hc}"
  # a rebuilt image (its name gives another ID now), and one gone: compose's
  II="${II/sha256:i1/sha256:i1b}"; assert_eq "$(_ups --no-deps portal caddy)" 1
  II="${II/p\/portal:local sha256:i1b/}"; assert_eq "$(_ups --no-deps portal caddy)" 1
  II="p/portal:local sha256:i1
$II"
  assert_eq "$(_ups --no-deps portal caddy)" 0
  # a container still starting, stopped or gone, two of one service: compose's
  ROWS="${ROWS/Up 2 minutes (healthy)|hp/Up 2 seconds (health: starting)|hp}"; assert_eq "$(_ups --no-deps portal caddy)" 1
  ROWS="${ROWS/c1|running|Up 2 seconds (health: starting)/c1|exited|Exited (0) 1 second ago}"; assert_eq "$(_ups --no-deps portal caddy)" 1
  ROWS="${ROWS/portal|c1|exited|Exited (0) 1 second ago|hp/}"; assert_eq "$(_ups --no-deps portal caddy)" 1
  ROWS="portal|c1|running|Up 2 minutes (healthy)|hp
portal|c9|running|Up 2 minutes (healthy)|hp
$ROWS"
  assert_eq "$(_ups --no-deps portal caddy)" 1
  ROWS="${ROWS/portal|c9|running|Up 2 minutes (healthy)|hp/}"; assert_eq "$(_ups --no-deps portal caddy)" 0
  # the networks' configuration changed, or a network was made again: compose's, then none again
  NETDEF="$NETDEF
    internal: true"
  assert_eq "$(_ups --no-deps portal caddy)" 1; assert_eq "$(_ups --no-deps portal caddy)" 0
  NETS='n1b'; assert_eq "$(_ups --no-deps portal caddy)" 1; assert_eq "$(_ups --no-deps portal caddy)" 0
  # (litellm's last up was with the networks before: compose's for it too)
  assert_eq "$(_ups --no-deps litellm)" 1
  # an option it does not know, or DEVOS_ADE_UP_ALWAYS=1: compose's, every time
  assert_eq "$(_ups --no-deps --force-recreate caddy)" 1; assert_eq "$(_ups --no-deps --force-recreate caddy)" 1
  DEVOS_ADE_UP_ALWAYS=1; assert_eq "$(_ups --no-deps portal caddy)" 1; unset DEVOS_ADE_UP_ALWAYS
}

test_up_services_without_no_deps_needs_the_whole_stack_unchanged() {
  _up_stack
  assert_eq "$(_ups caddy)" 1; assert_eq "$(_ups caddy)" 0
  # a one-shot of the stack that is done counts as up; one that failed, or a service with no container: compose's
  ROWS="${ROWS/Exited (0)/Exited (1)}"; assert_eq "$(_ups caddy)" 1
  ROWS="${ROWS/Exited (1)/Exited (0)}"; assert_eq "$(_ups caddy)" 0
  HASHES="$HASHES
searxng hs"
  assert_eq "$(_ups caddy)" 1
  HASHES="${HASHES%$'\n'searxng hs}"; assert_eq "$(_ups caddy)" 0
  # another service's configuration changed (compose would recreate it, if caddy depends on it): compose's
  HASHES="${HASHES/litellm hl/litellm hl2}"; assert_eq "$(_ups caddy)" 1
  HASHES="${HASHES/litellm hl2/litellm hl}"; assert_eq "$(_ups caddy)" 0
  # a one-shot listed (compose would run it again): compose's
  assert_eq "$(_ups rustfs-init)" 1; assert_eq "$(_ups rustfs-init)" 1
  # one listed runs unhealthy: recreated, as before
  ROWS="${ROWS/caddy|c2|running|Up 2 minutes (healthy)/caddy|c2|running|Up 2 minutes (unhealthy)}"
  assert_eq "$(_ups caddy)" 2
}

# _up_model: the configuration other than the services (the networks, the volumes: what a service's hash leaves out),
# and only that. With the real docker compose (config only).
test_the_configurations_checksum_reads_all_but_its_services() {
  _hash_stack || return
  docker() { case "$*" in *" config"*) "$BN_REAL_DOCKER" "$@" ;; *) echo "unexpected docker $*" >&2; return 97 ;; esac; }
  local m
  m="$(_up_model)"; [ -n "$m" ] || { echo "no checksum" >&2; return 1; }
  assert_eq "$(_up_model)" "$m"
  # a service's configuration changed (its hash tells): the same
  printf 'model_list: [x]\n' > "$STACK_DIR/litellm/config.yaml"; assert_eq "$(_up_model)" "$m"
  # a network's: another
  awk '{ print } /^  websearch-out:$/ { print "    internal: true" }' "$STACK_DIR/compose.yaml" > "$TMP/compose.yaml"
  mv "$TMP/compose.yaml" "$STACK_DIR/compose.yaml"
  [ "$(_up_model)" != "$m" ] || { echo "a network's change left the checksum the same" >&2; return 1; }
}

# Setup's and update's bring-up: nothing forced. Each group of services in one compose call: LiteLLM; Open WebUI, the
# portal, Caddy and shared-mcp; the terminal with what fronts it; the gateway and the Code page.
test_setups_bring_up_never_forces_a_recreate() {
  local f body
  for f in setup_bringup_and_probe setup_keys_and_ui _build_and_up_front up_front _build_and_up_mcp; do
    body="$(sed -n "/^$f() {/,/^}/p" "$STACK_DIR/lib/commands.sh")"
    [ -n "$body" ] || { echo "no $f" >&2; return 1; }
    assert_not_contains "$body" "force-recreate"
  done
  for f in terminal_setup_hook _terminal_build_and_up _terminal_up _terminal_front terminal_build; do
    body="$(sed -n "/^$f() {/,/^}/p" "$STACK_DIR/lib/terminal.sh")"; [ -n "$body" ] || { echo "no $f" >&2; return 1; }
    assert_not_contains "$body" "force-recreate"
  done
  for f in code_setup_hook _subs_chat_up _code_up _code_front; do
    body="$(sed -n "/^$f() {/,/^}/p" "$STACK_DIR/lib/code.sh")"; [ -n "$body" ] || { echo "no $f" >&2; return 1; }
    assert_not_contains "$body" "force-recreate"
  done
  assert_not_contains "$(sed -n '/^caddy_up() {/,/^}/p' "$STACK_DIR/lib/portal.sh")" "force-recreate"
  # (Caddy is recreated by force in one place only: ensure_portal_reachable, for Docker's port forward)
  assert_eq "$(grep -c 'force-recreate' "$STACK_DIR/lib/portal.sh")" 1
}

# The front of setup: Open WebUI, the portal, Caddy and — with its key already there — shared-mcp in one compose call;
# on a first setup (no key yet) shared-mcp after the key is made, and again only when the key is new
test_setup_starts_open_webui_the_portal_and_shared_mcp_together() {
  ensure_virtual_key() { :; }; alert_pct_mark() { :; }; setup_litellm_admin() { :; }; stt_setup_service() { :; }
  ensure_portal_reachable() { :; }; portal_session_or_die() { :; }; settings_reconcile() { :; }; sync_openwebui_models() { :; }
  openrouter_sync_owui() { :; }; explabs_sync_owui() { :; }; stt_sync_owui() { :; }; owui_install_cost_filter() { :; }
  sync_budget_banner() { :; }; portal_session_end() { :; }; ensure_portal_password_hash() { :; }; compose_reads_contexts() { :; }
  run_phase() { echo "PHASE $1" >> "$TMP/calls"; shift 2; "$@"; }
  dc() { case "$*" in "ps --format"*) ;; *) echo "dc $*" >> "$TMP/calls" ;; esac; return 0; }
  ensure_openwebui_api_key() { :; }
  printf 'OPENWEBUI_API_KEY=sk-owui\nPORTAL_PORT=80\nPORTAL_HOST=x.localhost\n' > "$ENV_FILE"
  SETUP_BUILT=" portal shared-mcp open-webui "
  setup_keys_and_ui 2>/dev/null || return 1
  assert_eq "$(cat "$TMP/calls")" "PHASE Open WebUI + portal + shared-mcp (http://x.localhost)
dc up -d --wait open-webui portal caddy shared-mcp"
  # a first setup: no key yet — shared-mcp on its own once it is made (its image built then, unless setup built it)
  printf 'PORTAL_PORT=80\nPORTAL_HOST=x.localhost\n' > "$ENV_FILE"; : > "$TMP/calls"; SETUP_BUILT=''
  ensure_openwebui_api_key() { set_env OPENWEBUI_API_KEY sk-new; }
  setup_keys_and_ui 2>/dev/null || return 1
  assert_eq "$(cat "$TMP/calls")" "PHASE Open WebUI + portal (http://x.localhost)
dc build -q portal
dc up -d --wait open-webui portal caddy
PHASE shared-mcp
dc build -q shared-mcp
dc up -d --wait --no-deps shared-mcp"
  # the key there, but made anew (Open WebUI refused it): shared-mcp again, with it
  printf 'OPENWEBUI_API_KEY=sk-old\nPORTAL_PORT=80\nPORTAL_HOST=x.localhost\n' > "$ENV_FILE"; : > "$TMP/calls"; SETUP_BUILT=" portal shared-mcp "
  setup_keys_and_ui 2>/dev/null || return 1
  assert_eq "$(grep -c '^PHASE shared-mcp$' "$TMP/calls")" 1
  assert_eq "$(tail -n 1 "$TMP/calls")" "dc up -d --wait --no-deps shared-mcp"
}

# Port 80 refused (a rootless engine): only when Caddy is what did not start with it does the portal move to 8800
test_the_front_moves_the_portal_only_for_caddys_refused_port() {
  ensure_portal_password_hash() { :; }; compose_reads_contexts() { :; }; save_portal_origin() { :; }
  ensure_portal_reachable() { :; }
  resolve_port() { :; }
  printf 'PORTAL_PORT=80\n' > "$ENV_FILE"; SETUP_BUILT=" portal "
  # (Caddy refused port 80 until the portal moved; not running then)
  dc() { echo "dc $*" >> "$TMP/dc"; case "$*" in "up -d --wait open-webui portal caddy") [ "$(get_env PORTAL_PORT)" != 80 ] ||
    { echo "Error: ports are not available: listen tcp 127.0.0.1:80: bind: permission denied"; return 1; } ;; esac; return 0; }
  PORTAL_PORT_FELL_BACK=0
  _build_and_up_front open-webui portal caddy > /dev/null 2>&1 || return 1
  assert_eq "$PORTAL_PORT_FELL_BACK" 1; assert_eq "$(get_env PORTAL_PORT)" 8800
  assert_contains "$(cat "$TMP/dc")" "dc up -d --wait caddy"   # (caddy_up: then the port forward checked)
  # Caddy running (it was not what failed): the failure is reported, the port kept
  printf 'PORTAL_PORT=80\n' > "$ENV_FILE"; PORTAL_PORT_FELL_BACK=0
  dc() { echo "dc $*" >> "$TMP/dc"; case "$*" in "up -d --wait open-webui portal caddy") echo "bind source path does not exist"; return 1 ;; "ps -q --status running caddy") echo cid ;; esac; return 0; }
  if _build_and_up_front open-webui portal caddy > /dev/null 2>&1; then echo "another failure passed" >&2; return 1; fi
  assert_eq "$PORTAL_PORT_FELL_BACK" 0
}

# Every image setup builds, in one compose call (side by side); each step then takes its image as it is. A build that
# fails names none: each step builds its own as before (and says its failure where it belongs).
test_setup_builds_every_image_side_by_side_once() {
  dc() { echo "dc $*" >> "$TMP/dc"; return 0; }
  terminal_on() { return 0; }; terminal_why_out() { :; }; code_ready() { return 0; }; fix_checkout_modes() { :; }
  subs_tools_arg() { echo all; }
  printf 'TERMINAL_EGRESS=internet\n' > "$ENV_FILE"
  setup_build_images --sandboxes 2> "$TMP/err" || return 1
  # (the sandboxes' images in a build of their own, in the background — lib/steps.sh — collected at the terminal's step)
  sandbox_build_wait 2>> "$TMP/err"
  assert_eq "$(sort "$TMP/dc")" "$(printf '%s\n' "dc --progress plain build --build-arg APT_REFRESH=$(date -u +%G-%V) --build-arg BN_AI_TOOLS=all terminal terminal-egress code" \
    "dc --progress plain build --build-arg BN_VENDOR_TRY=0 portal shared-mcp open-webui" | sort)"
  assert_eq "$SETUP_BUILT" " portal shared-mcp open-webui terminal terminal-egress code "
  assert_contains "$(cat "$TMP/err")" "Images ready ("
  assert_contains "$(cat "$TMP/err")" "Sandbox images ready ("
  # its steps build nothing more
  : > "$TMP/dc"
  python_runner_status() { :; }
  owui_build && terminal_build && code_build || return 1
  ensure_portal_password_hash() { :; }; compose_reads_contexts() { :; }
  _build_and_up_front open-webui portal caddy shared-mcp > /dev/null || return 1
  assert_eq "$(grep -c '^dc build' "$TMP/dc")" 0
  # without --sandboxes (./stack models --recheck): the stack's own images only
  : > "$TMP/dc"; setup_build_images 2>/dev/null
  assert_eq "$(cat "$TMP/dc")" "dc --progress plain build --build-arg BN_VENDOR_TRY=0 portal shared-mcp open-webui"
  [ -z "$SANDBOX_BUILD_PID" ] || { echo "a background build without --sandboxes" >&2; return 1; }
  # the builds fail: none is taken as built, so each step builds its own
  dc() { echo "dc $*" >> "$TMP/dc"; case "$*" in *" terminal terminal-egress code") echo "failed to solve: terminal"; return 1 ;;
    *" portal shared-mcp open-webui") echo "failed to solve: portal"; return 1 ;; esac; return 0; }
  : > "$TMP/dc"; setup_build_images --sandboxes 2> "$TMP/err" || return 1
  sandbox_build_wait 2>> "$TMP/err"
  assert_eq "$SETUP_BUILT" ""
  assert_contains "$(cat "$TMP/err")" "each is built on its own next"
  assert_contains "$(cat "$TMP/err")" "failed to solve: terminal"
  assert_contains "$(cat "$TMP/err")" "failed to solve: portal"
  owui_build; terminal_build; code_build
  assert_contains "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=0 open-webui"
  assert_contains "$(cat "$TMP/dc")" "dc build -q --build-arg APT_REFRESH=$(date -u +%G-%V) --build-arg BN_AI_TOOLS=all terminal"
  assert_contains "$(cat "$TMP/dc")" "dc build -q code"
}
