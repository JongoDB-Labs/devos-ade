# shellcheck shell=bash
# Web search for Claude Code: its WebSearch tool on every model, not only where the provider runs a search itself.
# Claude Code's WebSearch asks the API for Anthropic's web search, a tool the provider runs. Bedrock runs none (for
# Claude or any other model) and OpenRouter barely does: LiteLLM's web search interception (LiteLLM 1.105.0: its
# WebSearchInterceptionLogger, as the hook's file has it — bn_hooks.web_search — with a search_tools entry, both named
# in litellm/config.yaml) runs the search itself for Bedrock's and OpenRouter's models. A Claude model on Bedrock gets
# LiteLLM's own search tool, and LiteLLM runs each
# search it asks for and hands it the results; for another vendor's model on Bedrock and OpenRouter's, the request
# WebSearch makes on its own (web search its only tool) is answered with the search's results alone, no model call.
# Only the query goes to the backend; what it finds comes back to the model. The Experiential Labs gateway runs its own
# search (lib/explabs.sh): its models are left as they are.
#
# Backends, in this order (WEBSEARCH_BACKEND: blank or auto = the first one set up; off; or one by name):
#   agentcore   Amazon Bedrock AgentCore Web Search: Amazon's own web index, on this stack's AWS key — no other key;
#               the query stays inside AWS. Needs an AgentCore gateway with a web search target (set up once per AWS
#               account by your AWS admin: ./stack websearch aws-setup prints the commands) that this key may use
#               (bedrock-agentcore:InvokeGateway): WEBSEARCH_AGENTCORE_GATEWAY, or found with
#               bedrock-agentcore:ListGateways. $7 per 1,000 searches (+ $0.005 per 1,000 gateway calls).
#   tavily | brave | perplexity   your own key (WEBSEARCH_<NAME>_API_KEY): the query goes to that company
#   searxng     a SearXNG instance of yours (WEBSEARCH_SEARXNG_URL, its JSON output on): the query goes to it, and from
#               there to the search engines it asks
#   builtin     the built-in SearXNG (the default: on unless WEBSEARCH_SEARXNG_BUILTIN=off): a container of this stack
#               ("searxng", compose profile searxng) that only LiteLLM reaches, on a network of their own; its way out is
#               a network of its own (docs/security.md). It asks a few public search engines that answer a server
#               without a key (WEBSEARCH_SEARXNG_ENGINES) from this computer's internet address: free, and they may
#               rate-limit it. Its settings.yml is rendered here (searxng/), its secret is .env's
#               WEBSEARCH_SEARXNG_SECRET (made by setup, passed in its environment only, never printed).
# Auto takes one you set up first, the built-in SearXNG last. None (off, or the built-in one off with nothing else): Claude
# Code's WebSearch says it is not available (lib/litellm-hooks/bn_hooks.py no_web_search), and WebFetch still works.
#
# The checks (one setup or ./stack websearch check, never more than one search):
#   websearch_agentcore_check  before LiteLLM's config is rendered: lib/websearch_probe.py in a one-off container of
#                              LiteLLM's image (the AWS sign-in LiteLLM uses) — free: who this key is, the gateway
#                              (found when none is set) and whether it answers this key and lists a web search tool
#   websearch_search_check     once LiteLLM runs: one search through LiteLLM's /v1/search with the setup key (booked
#                              there, like the model check's requests)
# Both keep their answer in .state/websearch/ and reuse it for a week while nothing they depend on changed.
#
# Files: litellm/web-search.json (render_config: the backend in use, its price per search and the checks' answers —
# the hook reads the backend and books each search at that price; the portal reads it for Settings).
#
# Hooks for other parts of ./stack:
#   websearch_backend / websearch_yaml / websearch_write_json   render_litellm_config (the interception itself is the
#                      hook's: lib/litellm-hooks/bn_hooks.py web_search, for Bedrock's and OpenRouter's models;
#                      LiteLLM's own limit of follow-up model calls per request stays, 3)
#   websearch_before_render / websearch_after_start   setup and ./stack config set (the checks)
#   websearch_status_line / websearch_summary_line   ./stack status, ./stack code status, setup's summary
#   websearch_json   Settings' status line (lib/settings.sh: the snapshot's choices.websearch)
#   websearch_searxng_write / websearch_builtin_services / websearch_builtin_up / websearch_builtin_down
#                    the built-in SearXNG: its settings.yml (render_config, ./stack up), its container in ./stack up's
#                    list, started by setup and ./stack config, removed while it is off
#   cmd_websearch   ./stack websearch status | check | aws-setup

# backend  LiteLLM search_provider  USD per search  the .env key that sets it up  name
# Prices (checked 2026-10 on each one's pricing page): AgentCore's from AWS (aws.amazon.com/bedrock/agentcore/pricing:
# Web Search $7 per 1,000 queries, gateway calls $0.005 per 1,000); the others' pay-as-you-go list prices (Tavily $0.008
# per credit, a basic search one credit; Brave Search $5 per 1,000; Perplexity Search API $5 per 1,000) — a provider's
# free monthly allowance (Tavily's 1,000 credits, Brave's $5) is not known here. SearXNG, yours or the built-in one: $0.
WEBSEARCH_CATALOG='agentcore	agentcore	0.007005	WEBSEARCH_AGENTCORE_GATEWAY	Amazon Bedrock AgentCore Web Search
tavily	tavily	0.008	WEBSEARCH_TAVILY_API_KEY	Tavily
brave	brave	0.005	WEBSEARCH_BRAVE_API_KEY	Brave Search
perplexity	perplexity	0.005	WEBSEARCH_PERPLEXITY_API_KEY	Perplexity Search
searxng	searxng	0	WEBSEARCH_SEARXNG_URL	SearXNG
builtin	searxng	0	WEBSEARCH_SEARXNG_BUILTIN	built-in SearXNG'
# The built-in SearXNG: where LiteLLM reaches it (its service on the websearch network), and the public engines it asks.
# Chosen by testing (2026-10, SearXNG 2026.10.11 in a container, each engine alone and then together, 20 queries two
# seconds apart; tests/test_websearch.sh keeps the list): Startpage (Google's results), Yahoo (Bing's), Yep (Ahrefs' own
# index) and Mojeek (its own) answered; Mojeek rate-limited after ten (then the others answer alone, and SearXNG
# leaves it out for a few minutes). Google, Bing, DuckDuckGo, Brave, Qwant, Wikipedia and Dogpile refused from the first
# query (CAPTCHA, access denied, too many requests): left out. Engines that need a key: never.
WEBSEARCH_SEARXNG_BUILTIN_URL=http://searxng:8080
WEBSEARCH_SEARXNG_ENGINES="startpage yahoo yep mojeek"
WEBSEARCH_SEARXNG_ENGINE_NAMES="Startpage, Yahoo, Yep and Mojeek"
# How long it waits: each engine 4 s (one retry inside it), 8 s at most for a search, LiteLLM 15 s at most for the
# whole call (its own default would be 6000 s): a slow engine never stalls Claude Code
WEBSEARCH_SEARXNG_TIMEOUT=4.0
WEBSEARCH_SEARXNG_MAX_TIMEOUT=8.0
WEBSEARCH_SEARXNG_LITELLM_TIMEOUT=15
WEBSEARCH_TOOL=web-search   # the search_tools entry LiteLLM's interception uses (and /v1/search/web-search; bn_hooks.py SEARCH_TOOL)
# AgentCore Web Search's Regions (2026-10: docs.aws.amazon.com/bedrock-agentcore/latest/devguide/ › Web Search Tool ›
# Availability): a gateway is looked for, and made, in AWS_REGION_NAME when it is one of them, else in us-east-1
WEBSEARCH_REGIONS="us-east-1 us-east-2 us-west-2 eu-west-1 ap-southeast-2 ap-northeast-1 us-gov-west-1"
WEBSEARCH_DEFAULT_TOOL=web-search-tool___WebSearch   # (LiteLLM's default: a target named web-search-tool)
WEBSEARCH_REUSE_MAX_S="${BEDROCK_NOW_WEBSEARCH_MAX_AGE_S:-604800}"
# names the one-time AWS setup gives what it makes (./stack websearch aws-setup)
WEBSEARCH_AWS_ROLE=DevOSADEWebSearchGateway
WEBSEARCH_AWS_GATEWAY=devos-ade-web-search
WEBSEARCH_AWS_POLICY=DevOSADEWebSearch

websearch_catalog() { printf '%s\n' "$WEBSEARCH_CATALOG"; }
# websearch_probe_src -> the AgentCore check's script (run in LiteLLM's image)
websearch_probe_src() { printf '%s\n' "$STACK_DIR/lib/websearch_probe.py"; }
websearch_backends() { websearch_catalog | cut -f1; }
# _ws_field BACKEND COLUMN(1-5) -> that column of BACKEND's row ("" for an unknown backend)
_ws_field() { websearch_catalog | B="$1" awk -F'\t' -v c="$2" '$1 == ENVIRON["B"] { print $c }'; }
websearch_name() { _ws_field "$1" 5; }
websearch_price() { _ws_field "$1" 3; }
websearch_key() { _ws_field "$1" 4; }

# valid_websearch_backend VALUE -> 0 for blank, auto, off or a backend's name
valid_websearch_backend() {
  case "$1" in '' | auto | off) return 0 ;; esac
  [ -n "$(_ws_field "$1" 1)" ]
}
# valid_websearch_gateway VALUE -> 0 for blank or an AgentCore gateway's MCP URL
valid_websearch_gateway() {
  [ -z "$1" ] && return 0
  [[ $1 =~ ^https://[a-z0-9-]{1,100}\.gateway\.bedrock-agentcore\.[a-z0-9-]{1,30}\.amazonaws\.com/mcp$ ]]
}
# valid_websearch_key VALUE -> 0 for blank or an API key (16-256 letters, digits, - and _)
valid_websearch_key() {
  [ -z "$1" ] && return 0
  case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#1}" -ge 16 ] && [ "${#1}" -le 256 ]
}

# websearch_choice -> auto | off | a backend: what WEBSEARCH_BACKEND says (anything else counts as auto)
websearch_choice() {
  local c; c="$(get_env WEBSEARCH_BACKEND)"
  case "$c" in '' | auto) echo auto ;; off) echo off ;; *) if [ -n "$(_ws_field "$c" 1)" ]; then echo "$c"; else echo auto; fi ;; esac
}

websearch_state_dir() { printf '%s/websearch\n' "$STATE_DIR"; }
_ws_state_file() { printf '%s/%s\n' "$(websearch_state_dir)" "$1"; }   # agentcore | search
# _ws_state FILE KEY -> KEY's value in .state/websearch/FILE ("" when there is none)
_ws_state() { sed -n "s/^$2=//p" "$(_ws_state_file "$1")" 2>/dev/null | head -n 1; }

# websearch_agentcore_region -> where the gateway is looked for (and made): AWS_REGION_NAME when Web Search runs there
websearch_agentcore_region() {
  local r; r="$(get_env AWS_REGION_NAME)"
  case " $WEBSEARCH_REGIONS " in *" $r "*) [ -n "$r" ] && { echo "$r"; return 0; } ;; esac
  echo us-east-1
}

# _ws_agentcore_fp -> what the AgentCore check's answer depends on (hashed): .env's AWS_* lines, the gateway set, the
# region it looks in and the check's own code
_ws_agentcore_fp() {
  { grep -E '^AWS_' "$ENV_FILE" 2>/dev/null || true; printf 'gw=%s\nregion=%s\n' "$(get_env WEBSEARCH_AGENTCORE_GATEWAY)" "$(websearch_agentcore_region)"
    cat "$(websearch_probe_src)" 2>/dev/null || true; } | openssl dgst -sha256 | awk '{ print $NF }'
}
# websearch_agentcore_status -> the AgentCore check's answer while it still stands (ready | denied | no-gateway |
# no-target | unverified), "" when it never ran or something it depends on changed
websearch_agentcore_status() {
  [ "$(_ws_state agentcore fingerprint)" = "$(_ws_agentcore_fp)" ] || return 0
  _ws_state agentcore status
}
# websearch_agentcore_url -> the gateway in use: WEBSEARCH_AGENTCORE_GATEWAY, else the one the check found
websearch_agentcore_url() {
  local u; u="$(get_env WEBSEARCH_AGENTCORE_GATEWAY)"
  if [ -n "$u" ]; then printf '%s\n' "$u"; return 0; fi
  [ -z "$(websearch_agentcore_status)" ] || _ws_state agentcore url
}
# websearch_agentcore_tool -> its web search tool (<target>___WebSearch) as the check listed it, else LiteLLM's default
websearch_agentcore_tool() {
  local t=''
  [ "$(websearch_agentcore_status)" != ready ] || t="$(_ws_state agentcore tool)"
  printf '%s\n' "${t:-$WEBSEARCH_DEFAULT_TOOL}"
}

# websearch_builtin_on -> 0 while the built-in SearXNG is on: WEBSEARCH_SEARXNG_BUILTIN anything but off (blank = on,
# the default; setup writes on). lib/common.sh dc() reads it the same way for the compose profile searxng.
websearch_builtin_on() { ! flag_off "$(get_env WEBSEARCH_SEARXNG_BUILTIN)"; }

# websearch_set_up BACKEND -> 0 when BACKEND can be used: its key or URL is in .env; AgentCore: a gateway (set or found)
# that the last check did not find unusable (ready, unverified — it could not tell — or not checked yet); the built-in
# SearXNG: while it is on
websearch_set_up() {
  case "$1" in
    agentcore)
      [ -n "$(websearch_agentcore_url)" ] || return 1
      case "$(websearch_agentcore_status)" in '' | ready | unverified) return 0 ;; esac
      return 1 ;;
    builtin) websearch_builtin_on ;;
    '') return 1 ;;
    *) [ -n "$(_ws_field "$1" 1)" ] && [ -n "$(get_env "$(websearch_key "$1")")" ] ;;
  esac
}

# websearch_backend -> the backend LiteLLM's config gets, "" for none: off = none; one by name = that one while its key
# or gateway is there (AgentCore's even when its check found a problem: the error then says what is missing); auto =
# the first set up, in the catalog's order
websearch_backend() {
  local c b
  c="$(websearch_choice)"
  case "$c" in
    off) return 0 ;;
    auto) for b in $(websearch_backends); do if websearch_set_up "$b"; then echo "$b"; return 0; fi; done ;;
    agentcore) [ -z "$(websearch_agentcore_url)" ] || echo agentcore ;;
    *) ! websearch_set_up "$c" || echo "$c" ;;
  esac
  return 0
}

# websearch_yaml -> LiteLLM's search_tools (a top-level key of its config) for the backend in use; nothing without one.
# A key goes as os.environ/… (compose hands only the litellm container the WEBSEARCH_*_API_KEY values); URLs are checked
# values (valid_websearch_gateway, the webhook validator for SearXNG's).
websearch_yaml() {
  local b; b="${1-$(websearch_backend)}"
  [ -n "$b" ] || return 0
  printf '\nsearch_tools:\n  - search_tool_name: "%s"\n    litellm_params:\n      search_provider: "%s"\n' "$WEBSEARCH_TOOL" "$(_ws_field "$b" 2)"
  case "$b" in
    agentcore) printf '      api_base: "%s"\n      tool_name: "%s"\n' "$(websearch_agentcore_url)" "$(websearch_agentcore_tool)" ;;
    searxng) printf '      api_base: "%s"\n' "$(get_env WEBSEARCH_SEARXNG_URL)" ;;
    # (timeout: LiteLLM's bound on the whole call — litellm.asearch's own — over SearXNG's per engine)
    builtin) printf '      api_base: "%s"\n      timeout: %s\n' "$WEBSEARCH_SEARXNG_BUILTIN_URL" "$WEBSEARCH_SEARXNG_LITELLM_TIMEOUT" ;;
    *) printf '      api_key: os.environ/%s\n' "$(websearch_key "$b")" ;;
  esac
}

# websearch_config_stale -> 0 when LiteLLM's config searches with another backend than .env now gives (its search_tools
# block, or none, differs from websearch_yaml's): ./stack up renders it again (a WEBSEARCH_* edited by hand)
websearch_config_stale() {
  local cfg="$STACK_DIR/litellm/config.yaml" have want
  [ -f "$cfg" ] && [ -r "$(bn_hook_src)" ] || return 1
  have="$(awk '/^search_tools:/ { f = 1; print; next } f && /^[^ ]/ { exit } f' "$cfg" | sed '/^[[:space:]]*$/d')"
  want="$(websearch_yaml | sed '/^[[:space:]]*$/d')"
  [ "$have" != "$want" ]
}

# --- the built-in SearXNG -------------------------------------------------------------------------------------------

# websearch_searxng_settings -> its settings.yml: SearXNG's defaults narrowed to WEBSEARCH_SEARXNG_ENGINES (each one on,
# whatever its default), JSON output on, no limiter (only LiteLLM reaches it), no image proxy, autocomplete or favicons
# (nothing it fetches on a page's behalf), short timeouts. No secret in it: server.secret_key comes from SearXNG's
# environment (SEARXNG_SECRET, compose.yaml), so this file is readable by its container (644) and holds nothing to hide.
websearch_searxng_settings() {
  # (IFS as usual: it is also run inside an IFS=$'\037' read's here-string — websearch_check_state's fingerprint)
  local e IFS=$' \t\n'
  cat <<EOF
# The built-in SearXNG of DevOS ADE: rendered by ./stack (lib/websearch.sh websearch_searxng_settings) — edits are
# overwritten. Only LiteLLM reaches it (compose.yaml, docs/security.md); it asks the engines below for Claude Code's
# WebSearch. Its signing key comes from the environment (SEARXNG_SECRET), never from this file.
use_default_settings:
  engines:
    keep_only: [$(printf '%s' "$WEBSEARCH_SEARXNG_ENGINES" | sed 's/ /, /g')]
general:
  debug: false
  instance_name: "DevOS ADE web search"
  enable_metrics: false
search:
  safe_search: 0
  autocomplete: ""
  favicon_resolver: ""
  formats: [html, json]
server:
  limiter: false
  public_instance: false
  image_proxy: false
  method: GET
valkey:
  url: false
outgoing:
  request_timeout: $WEBSEARCH_SEARXNG_TIMEOUT
  max_request_timeout: $WEBSEARCH_SEARXNG_MAX_TIMEOUT
  retries: 1
engines:
EOF
  for e in $WEBSEARCH_SEARXNG_ENGINES; do
    printf '  - name: %s\n    disabled: false\n    inactive: false\n' "$e"
  done
}

# websearch_searxng_dir -> where its settings are (searxng/ of this checkout, mounted read-only at /etc/searxng)
websearch_searxng_dir() { printf '%s/searxng\n' "$STACK_DIR"; }

# websearch_searxng_write [DIR] — settings.yml (and limiter.toml, which SearXNG reads even with the limiter off: an
# empty one, so it says nothing about it) in DIR (default searxng/), each replaced only when it changed, atomically,
# readable by its container (folder 755, files 644). Written whether it is on or not (a file of settings, nothing runs).
# lib/common.sh dc() hands compose its checksum, so a changed file recreates the container. Never fatal.
websearch_searxng_write() {
  local d="${1:-$(websearch_searxng_dir)}" tmp
  mkdir -p "$d" 2>/dev/null && chmod 755 "$d" 2>/dev/null || return 0
  tmp="$(mktemp "$d/.settings.XXXXXX")" || return 0
  websearch_searxng_settings > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  if cmp -s "$tmp" "$d/settings.yml"; then rm -f "$tmp"; else chmod 644 "$tmp"; mv -f "$tmp" "$d/settings.yml" || rm -f "$tmp"; fi
  if [ ! -f "$d/limiter.toml" ] && tmp="$(mktemp "$d/.limiter.XXXXXX")"; then
    printf '# The built-in SearXNG has its limiter off (only LiteLLM reaches it): nothing to set here.\n' > "$tmp" &&
      chmod 644 "$tmp" && mv -f "$tmp" "$d/limiter.toml" || rm -f "$tmp"
  fi
  return 0
}

# websearch_builtin_services -> "searxng" while it is on (lib/commands.sh optional_services: ./stack up's list)
websearch_builtin_services() { ! websearch_builtin_on || echo searxng; }

# websearch_builtin_up — setup and ./stack config: its settings written, its secret made when there is none, then on:
# its container started (recreated when its settings or secret changed); off: removed. Never fatal: a container that
# does not start is said, and its search check says why WebSearch does not work.
websearch_builtin_up() {
  websearch_searxng_write
  if ! websearch_builtin_on; then websearch_builtin_down; return 0; fi
  ensure_env WEBSEARCH_SEARXNG_SECRET "$(gen_hex 32)"
  run_phase "Web search (the built-in SearXNG)" searxng dc up -d --no-deps --wait searxng ||
    warn "the built-in SearXNG did not start — ./stack logs searxng says why; Claude Code's WebSearch fails until it does (./stack websearch status)"
  return 0
}

# websearch_builtin_down — off: its container removed (named with its profile on: off, compose would not see it). Only
# when there is one; never fatal.
websearch_builtin_down() {
  [ -n "$(_WS_SEARXNG_PROFILE=1 dc ps -aq searxng 2>/dev/null)" ] || return 0
  _WS_SEARXNG_PROFILE=1 dc rm -sf searxng >/dev/null 2>&1 || warn "could not remove the built-in SearXNG's container — ./stack down removes it"
}

# websearch_rollback_cleanup — ./stack rollback to a version without the built-in SearXNG (its compose.yaml has no
# searxng service, so it would never stop it): its container removed by its Compose labels (before that version's up),
# and its networks after it (websearch_rollback_network_cleanup). Never fatal.
websearch_rollback_cleanup() {
  local p ids
  p="$(project_name)"
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.service=searxng" 2>/dev/null || true)"
  # shellcheck disable=SC2086  # one id per word
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1 || warn "could not remove the built-in SearXNG's container — remove it with: docker rm -f $p-searxng-1"
}
websearch_rollback_network_cleanup() {
  docker network rm "$(project_name)_websearch" "$(project_name)_websearch-out" >/dev/null 2>&1 || true
}

# _ws_json_str TEXT -> TEXT as a JSON string's inside: no control character, quotes and backslashes escaped
_ws_json_str() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# _ws_url_masked URL -> scheme://host/…: the SearXNG address as Settings shows it (lib/settings.sh, kind u), without
# what may carry a token (a user:password@, the path, the query); "(set)" for one that is no URL
_ws_url_masked() {
  local h
  h="$(printf '%s' "$1" | sed -nE 's#^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)?([^/?#@]+).*#\1\3#p')"
  [ -n "$h" ] || { printf '(set)'; return 0; }
  if [ "$1" = "$h" ]; then printf '%s' "$h"; else printf '%s/…' "$h"; fi
}

# _ws_redact TEXT -> TEXT without the search keys, the setup key, the built-in SearXNG's secret or the SearXNG address
# (whole, or what of it may carry a token: its user:password, password, path and query, and each value of the query): a
# search's error text is kept as the reason Settings' card and ./stack status show, and a backend may echo what it was
# sent
_ws_redact() {
  local t="$1" v u rest auth pq q kv
  local -a parts=()
  for v in "$(get_env WEBSEARCH_TAVILY_API_KEY)" "$(get_env WEBSEARCH_BRAVE_API_KEY)" \
           "$(get_env WEBSEARCH_PERPLEXITY_API_KEY)" "$(setup_key 2>/dev/null)" "$(get_env WEBSEARCH_SEARXNG_SECRET)"; do
    [ "${#v}" -lt 8 ] || t="${t//"$v"/***}"
  done
  u="$(get_env WEBSEARCH_SEARXNG_URL)"
  [ -n "$u" ] || { printf '%s' "$t"; return 0; }
  t="${t//"$u"/$(_ws_url_masked "$u")}"
  rest="${u#*://}"; auth="${rest%%[/?#]*}"; pq="${rest#"$auth"}"
  case "$auth" in *@*)
    v="${auth%@*}"; [ "${#v}" -lt 4 ] || t="${t//"$v"/***}"                               # user:password
    case "$v" in *:*) v="${v#*:}"; [ "${#v}" -lt 4 ] || t="${t//"$v"/***}" ;; esac ;;       # the password
  esac
  [ "${#pq}" -lt 8 ] || t="${t//"$pq"/***}"                                                 # path and query
  case "$pq" in *\?*) q="${pq#*\?}"; q="${q%%#*}"
    [ "${#q}" -lt 8 ] || t="${t//"$q"/***}"
    IFS='&' read -r -a parts <<< "$q"
    for kv in "${parts[@]}"; do v="${kv#*=}"; [ "${#v}" -lt 6 ] || t="${t//"$v"/***}"; done ;;  # each value
  esac
  printf '%s' "$t"
}

# websearch_json -> one JSON object: the backend in use and its price per search (lib/litellm-hooks/bn_hooks.py reads
# them), what WEBSEARCH_BACKEND says, the checks' answers and what to do (fix: lines), the backends set up, and
# AgentCore's own state (its check's answer, its gateway, what makes it usable) — litellm/web-search.json, and
# Settings › Models & providers' search cards (the settings snapshot's choices.websearch)
websearch_json() {
  local b p=0 st why fix='' at line ac='' up='' k eng='' bi=off
  b="$(websearch_backend)"; [ -z "$b" ] || p="$(websearch_price "$b")"
  IFS=$'\037' read -r st why at <<< "$(websearch_check_state "$b")"
  while IFS= read -r line; do [ -z "$line" ] || fix="$fix${fix:+, }\"$(_ws_json_str "$line")\""; done <<< "$(websearch_fix "$b")"
  while IFS= read -r line; do [ -z "$line" ] || ac="$ac${ac:+, }\"$(_ws_json_str "$line")\""; done <<< "$(websearch_agentcore_fix)"
  for k in $(websearch_backends); do ! websearch_set_up "$k" || up="$up${up:+, }\"$k\""; done
  for k in $WEBSEARCH_SEARXNG_ENGINES; do eng="$eng${eng:+, }\"$k\""; done
  ! websearch_builtin_on || bi=on
  printf '{"backend": "%s", "name": "%s", "provider": "%s", "usd_per_query": %s, "choice": "%s", "reason": "%s", "status": "%s", "why": "%s", "checked_at": "%s", "fix": [%s], "set_up": [%s], "builtin": {"state": "%s", "engines": [%s]}, "agentcore": {"status": "%s", "gateway": "%s", "why": "%s", "fix": [%s]}}\n' \
    "$b" "$(_ws_json_str "$(websearch_name "$b")")" "$(_ws_field "$b" 2)" "$p" "$(websearch_choice)" "$(_ws_json_str "$(websearch_reason "$b")")" \
    "$st" "$(_ws_json_str "$why")" "$at" "$fix" "$up" "$bi" "$eng" \
    "$(websearch_agentcore_status)" "$(_ws_json_str "$(websearch_agentcore_url)")" "$(_ws_json_str "$(_ws_state agentcore why)")" "$ac"
}

# websearch_reason [BACKEND] -> why BACKEND (default: the one in use) is the one, in a few words: "auto: no key set up,
# so the built-in SearXNG", "chosen: WEBSEARCH_BACKEND=tavily", … ("" without one: websearch_why_none says why)
websearch_reason() {
  local b="${1-$(websearch_backend)}" c
  [ -n "$b" ] || return 0
  c="$(websearch_choice)"
  if [ "$c" != auto ]; then printf 'chosen: WEBSEARCH_BACKEND=%s\n' "$c"; return 0; fi
  case "$b" in
    agentcore) echo "auto: AgentCore Web Search comes first while its gateway is usable" ;;
    tavily | brave | perplexity) printf 'auto: your %s key, the first one set up\n' "$(websearch_name "$b")" ;;
    searxng) echo "auto: your SearXNG's address (no AgentCore gateway or search key set up)" ;;
    builtin) echo "auto: no key set up, so the built-in SearXNG" ;;
  esac
}

# websearch_write_json [OUT] — websearch_json to OUT (default litellm/web-search.json, next to the config), replaced
# atomically, readable by LiteLLM and the portal (644)
websearch_write_json() {
  local out="${1:-$STACK_DIR/litellm/web-search.json}" tmp
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 0
  tmp="$(mktemp "$out.XXXXXX")" || return 0
  websearch_json > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  chmod 644 "$tmp"; mv "$tmp" "$out"
}

# --- the checks -------------------------------------------------------------------------------------------------------

# websearch_before_render [--force] — the AgentCore check, before LiteLLM's config is rendered, when AgentCore may be
# the backend (WEBSEARCH_BACKEND auto or agentcore): its answer decides whether auto picks it. Reused while it stands
# (websearch_agentcore_status, a week at most) unless --force. 0 when it ran (the config may follow a new answer), 1
# when not. Never fatal: no answer = unverified.
websearch_before_render() {
  local force="${1:-}" c at age
  c="$(websearch_choice)"
  [ "$c" = auto ] || [ "$c" = agentcore ] || return 1
  if [ "$force" != --force ] && [ -n "$(websearch_agentcore_status)" ]; then
    at="$(_ws_state agentcore at)"; case "$at" in '' | *[!0-9]*) at=0 ;; esac
    age=$(( $(date +%s) - at ))
    [ "$age" -lt 0 ] || [ "$age" -ge "$WEBSEARCH_REUSE_MAX_S" ] || return 1
  fi
  websearch_agentcore_check
  return 0
}

# websearch_agentcore_check — lib/websearch_probe.py in a one-off container of LiteLLM's image, with LiteLLM's own AWS
# sign-in (compose's environment: .env's key or the instance role), its answer to .state/websearch/agentcore
websearch_agentcore_check() {
  local d tmp out region gw
  d="$(websearch_state_dir)"; mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null || return 0
  region="$(websearch_agentcore_region)"; gw="$(get_env WEBSEARCH_AGENTCORE_GATEWAY)"
  # (the script as an argument, not on stdin: _with_deadline gives the command /dev/null; the deadline bounds a run
  # whose network hangs — the probe's own calls give up after 20 s each)
  out="$(_with_deadline 120 dc run --rm --no-deps -T --entrypoint python litellm -I -c "$(cat "$(websearch_probe_src)")" \
    "$region" ${gw:+"$gw"} 2>/dev/null)" || true
  # (only the lines the probe prints: KEY=VALUE, its own keys)
  out="$(printf '%s\n' "$out" | grep -E '^(status|url|tool|account|principal|region|why)=[ -~]*$' | LC_ALL=C tr -d '"\\' || true)"
  case "$(printf '%s\n' "$out" | sed -n 's/^status=//p' | head -n 1)" in
    ready | denied | no-gateway | no-target | unverified) ;;
    *) out="status=unverified
region=$region
why=the check did not run (LiteLLM's image could not start a container)" ;;
  esac
  tmp="$(mktemp "$d/.agentcore.XXXXXX")" || return 0
  { printf '%s\n' "$out"; printf 'at=%s\nfingerprint=%s\n' "$(date +%s)" "$(_ws_agentcore_fp)"; } > "$tmp" && mv -f "$tmp" "$(_ws_state_file agentcore)" || rm -f "$tmp"
}

# _ws_search_fp BACKEND -> what the search check's answer depends on (hashed): the backend, its key or URL, and for
# AgentCore the gateway, its tool and .env's AWS_* lines
_ws_search_fp() {
  { printf 'backend=%s\nset=%s\n' "$1" "$(get_env "$(websearch_key "$1")")"
    [ "$1" != agentcore ] || { printf 'gw=%s\ntool=%s\n' "$(websearch_agentcore_url)" "$(websearch_agentcore_tool)"; grep -E '^AWS_' "$ENV_FILE" 2>/dev/null || true; }
    # (the built-in SearXNG: its settings — another list of engines is checked again)
    [ "$1" != builtin ] || websearch_searxng_settings
  } | openssl dgst -sha256 | awk '{ print $NF }'
}

# websearch_check_state BACKEND -> "STATUS<US>WHY<US>CHECKED_AT" (US: the unit separator, \037 — a field may be empty,
# which a tab, a whitespace to read, would fold away) of the last search check with BACKEND as it is set up now: ok |
# failed | unverified; "unchecked" before one; "off" without a backend (WHY: why none is used)
websearch_check_state() {
  local b="$1" st at
  if [ -z "$b" ]; then printf 'off\037%s\037\n' "$(websearch_why_none)"; return 0; fi
  if [ "$(_ws_state search backend)" = "$b" ] && [ "$(_ws_state search fingerprint)" = "$(_ws_search_fp "$b")" ]; then
    st="$(_ws_state search status)"; at="$(_ws_state search at)"
    case "$at" in '' | *[!0-9]*) at='' ;; *) at="$(date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" ;; esac
    # (redacted again as it is read: a reason v0.30.0 kept before it redacted them stands for up to a week)
    printf '%s\037%s\037%s\n' "${st:-unchecked}" "$(_ws_redact "$(_ws_state search why)")" "$at"
    return 0
  fi
  printf 'unchecked\037\037\n'
}

# websearch_search_check [--force] — one search through LiteLLM (its /v1/search/web-search, with the setup key: the
# search is booked there) with the backend in use; its answer to .state/websearch/search. Reused while it stands (the
# same backend as set up now, ok, a week at most) unless --force. Needs LiteLLM running; never fatal.
websearch_search_check() {
  local force="${1:-}" b d tmp code body st why at age
  b="$(websearch_backend)"; [ -n "$b" ] || return 0
  if [ "$force" != --force ] && [ "$(websearch_check_state "$b" | cut -d "$(printf '\037')" -f1)" = ok ]; then
    at="$(_ws_state search at)"; case "$at" in '' | *[!0-9]*) at=0 ;; esac
    age=$(( $(date +%s) - at ))
    [ "$age" -ge 0 ] && [ "$age" -lt "$WEBSEARCH_REUSE_MAX_S" ] && return 0
  fi
  d="$(websearch_state_dir)"; mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null || return 0
  body="$(mktemp)"
  code="$(litellm_call "$(setup_key)" POST "/v1/search/$WEBSEARCH_TOOL" '{"query":"Amazon Web Services","max_results":1}' "$body")"
  IFS=$'\t' read -r st why <<< "$(websearch_classify "$b" "$code" "$body")"
  rm -f "$body"
  tmp="$(mktemp "$d/.search.XXXXXX")" || return 0
  printf 'backend=%s\nstatus=%s\nwhy=%s\nat=%s\nfingerprint=%s\n' "$b" "$st" "$why" "$(date +%s)" "$(_ws_search_fp "$b")" > "$tmp" &&
    mv -f "$tmp" "$(_ws_state_file search)" || rm -f "$tmp"
}

# websearch_classify BACKEND HTTP_STATUS BODY_FILE -> "STATUS<TAB>WHY" for a search through LiteLLM: ok with a result;
# failed when the backend or AWS refused (WHY: the permission AWS names, or what the backend said); unverified without
# an answer (it may work: never a reason to turn it off)
websearch_classify() {
  local b="$1" code="$2" text lower perm
  text="$(head -c 4000 "$3" 2>/dev/null | LC_ALL=C tr -c ' -~' ' ' | tr -d '"\\' || true)"
  text="$(_ws_redact "$text")"   # (kept as the reason: never what the backend was sent)
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$code" in
    200) if printf '%s' "$text" | grep -qE 'results ?: ?\[ ?\{|results ?: ?\[[^]]'; then printf 'ok\t\n'
         elif [ "$b" = builtin ]; then printf 'failed\tits search engines answered nothing (they may be refusing this computer'"'"'s address for now)\n'
         else printf 'failed\tno results: %s\n' "$(printf '%s' "$text" | cut -c1-160)"; fi
         return 0 ;;
    000 | '') printf 'unverified\tLiteLLM did not answer\n'; return 0 ;;
  esac
  perm="$(printf '%s' "$text" | grep -oE 'bedrock-agentcore:[A-Za-z]+' | head -n 1 || true)"
  if [ -n "$perm" ]; then printf 'failed\tAWS refused %s\n' "$perm"; return 0; fi
  case "$lower" in
    *"execution role"* | *invokewebsearch*) printf 'failed\tAWS refused bedrock-agentcore:InvokeWebSearch (the gateway'"'"'s role)\n'; return 0 ;;
    *"insufficient permissions"* | *accessdenied* | *"not authorized"*) [ "$b" != agentcore ] || { printf 'failed\tAWS refused bedrock-agentcore:InvokeGateway\n'; return 0; } ;;
  esac
  case "$code" in
    401 | 403) [ "$b" = agentcore ] || [ "$b" = searxng ] || [ "$b" = builtin ] || { printf 'failed\t%s refused the key (HTTP %s)\n' "$(websearch_name "$b")" "$code"; return 0; } ;;
    429) printf 'unverified\t%s is busy or out of searches right now (HTTP 429)\n' "$(websearch_name "$b")"; return 0 ;;
  esac
  case "$lower" in
    *"api key"* | *api_key* | *unauthorized* | *"invalid key"*) [ "$b" = agentcore ] || [ "$b" = builtin ] || { printf 'failed\t%s refused the key\n' "$(websearch_name "$b")"; return 0; } ;;
  esac
  printf 'failed\tHTTP %s: %s\n' "$code" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//' | cut -c1-200)"
}

# websearch_after_start [--force] — once LiteLLM runs with the backend in use: the search check, then
# litellm/web-search.json again with its answer, and one line about it (setup, ./stack config set, ./stack websearch
# check)
websearch_after_start() {
  [ -f "$STACK_DIR/litellm/config.yaml" ] || return 0
  websearch_search_check "${1:-}"
  websearch_write_json
  websearch_report
}

# websearch_report — the setup line: on (and how its check went), or why it is off and what turns it on
websearch_report() {
  local b st why
  b="$(websearch_backend)"
  IFS=$'\037' read -r st why _ <<< "$(websearch_check_state "$b")"
  if [ -z "$b" ]; then
    log "Web search for Claude Code: off — $why. Claude Code's WebSearch says so; WebFetch works (./stack websearch status)"
    websearch_fix "" | sed 's/^/    /' >&2
    return 0
  fi
  case "$st" in
    ok) log "Web search for Claude Code: on — $(websearch_name "$b") ($(websearch_price_words "$b")); checked: it answers" ;;
    unverified | unchecked) log "Web search for Claude Code: on — $(websearch_name "$b") ($(websearch_price_words "$b")); not checked${why:+: $why}" ;;
    *) warn "Web search for Claude Code: $(websearch_name "$b") does not work yet — $why. Claude Code's WebSearch says why when it is used"
       websearch_fix "$b" | sed 's/^/    /' >&2 ;;
  esac
}

# websearch_price_words BACKEND -> "$0.007 a search, on your AWS bill", "free", …
websearch_price_words() {
  local p; p="$(websearch_price "$1")"
  case "$1" in
    agentcore) printf '%s a search, on your AWS bill\n' "$(money "$p")" ;;
    searxng) printf 'free: your own SearXNG\n' ;;
    builtin) printf 'free\n' ;;
    *) printf '%s a search at its list price, on your %s account\n' "$(money "$p")" "$(websearch_name "$1")" ;;
  esac
}

# websearch_why_none -> why no backend is used (WEBSEARCH_BACKEND, or what AgentCore's check found)
# (auto finds none only while the built-in SearXNG is off: said last)
websearch_why_none() {
  local c st off='; the built-in SearXNG is off (WEBSEARCH_SEARXNG_BUILTIN=off)'
  c="$(websearch_choice)"
  case "$c" in
    off) echo "turned off (WEBSEARCH_BACKEND=off)"; return 0 ;;
    agentcore) echo "WEBSEARCH_BACKEND=agentcore, and no AgentCore gateway is set or found"; return 0 ;;
    builtin) echo "WEBSEARCH_BACKEND=builtin, and the built-in SearXNG is off (WEBSEARCH_SEARXNG_BUILTIN=off)"; return 0 ;;
    auto) ;;
    *) echo "WEBSEARCH_BACKEND=$c, and $(websearch_key "$c") is not set"; return 0 ;;
  esac
  st="$(websearch_agentcore_status)"
  case "$st:$(_ws_state agentcore why)" in
    denied:*) echo "no search backend set up: AgentCore Web Search found a gateway this AWS key may not use (bedrock-agentcore:InvokeGateway)$off" ;;
    no-target:*) echo "no search backend set up: the AgentCore gateway has no web search target$off" ;;
    no-gateway:bedrock-agentcore:ListGateways) echo "no search backend set up: no AgentCore gateway is set, and this AWS key may not look for one (bedrock-agentcore:ListGateways)$off" ;;
    "no-gateway:not found") echo "no search backend set up: WEBSEARCH_AGENTCORE_GATEWAY names no AgentCore gateway that exists$off" ;;
    no-gateway:*) echo "no search backend set up: no AgentCore gateway with a web search target in $(websearch_agentcore_region), and no search key or SearXNG URL$off" ;;
    *) echo "no search backend set up (an AgentCore gateway, a search key or a SearXNG URL)$off" ;;
  esac
}

# --- what to do -------------------------------------------------------------------------------------------------------

# _ws_principal -> "user NAME" | "role NAME" (this AWS key, as the AgentCore check saw it) or ""
_ws_principal() { _ws_state agentcore principal | sed -n -E 's#^(user|role)/([A-Za-z0-9+=,.@_-]+)$#\1 \2#p'; }
_ws_account() { local a; a="$(_ws_state agentcore account)"; case "$a" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) echo "$a" ;; *) echo ACCOUNT_ID ;; esac; }
# _ws_gateway_id URL -> the gateway's id in its URL
_ws_gateway_id() { printf '%s\n' "$1" | sed -n 's#^https://\([a-z0-9-]*\)\.gateway\.bedrock-agentcore\..*#\1#p'; }
_ws_url_region() { printf '%s\n' "$1" | sed -n 's#^https://[a-z0-9-]*\.gateway\.bedrock-agentcore\.\([a-z0-9-]*\)\.amazonaws\.com/mcp$#\1#p'; }

# websearch_user_policy_cmd GATEWAY_ARN_OR_STAR -> the one command that lets this key use (and find) the gateway: an IAM
# change, for your AWS admin to run (DevOS ADE never changes IAM)
websearch_user_policy_cmd() {
  local who kind name
  who="$(_ws_principal)"; kind="${who%% *}"; name="${who#* }"
  [ -n "$who" ] || { kind=user; name=YOUR_IAM_USER; }
  printf "aws iam put-%s-policy --%s-name %s --policy-name %s --policy-document '%s'\n" "$kind" "$kind" "$name" "$WEBSEARCH_AWS_POLICY" \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"bedrock-agentcore:InvokeGateway\",\"Resource\":\"$1\"},{\"Effect\":\"Allow\",\"Action\":\"bedrock-agentcore:ListGateways\",\"Resource\":\"*\"}]}"
}

# websearch_aws_setup -> the one-time AWS setup of AgentCore Web Search, as commands for your AWS admin (with this key's
# account, region and IAM user filled in when the check saw them): the gateway's service role, the gateway, its web
# search target, and this key's permission to use and find it. Nothing here runs them.
websearch_aws_setup() {
  local r a gw
  r="$(websearch_agentcore_region)"; a="$(_ws_account)"; gw="$WEBSEARCH_AWS_GATEWAY"
  cat <<EOF
# Amazon Bedrock AgentCore Web Search for DevOS ADE: once per AWS account, by an IAM admin of it (AWS CLI 2.35.7+)
# 1. The gateway's service role: AgentCore takes it on to run the searches (its trust: this account's gateways only)
aws iam create-role --role-name $WEBSEARCH_AWS_ROLE --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"$a"},"ArnLike":{"aws:SourceArn":"arn:aws:bedrock-agentcore:$r:$a:gateway/$gw-*"}}}]}'
aws iam put-role-policy --role-name $WEBSEARCH_AWS_ROLE --policy-name WebSearch --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"bedrock-agentcore:InvokeGateway","Resource":"arn:aws:bedrock-agentcore:$r:$a:gateway/*"},{"Effect":"Allow","Action":"bedrock-agentcore:InvokeWebSearch","Resource":"arn:aws:bedrock-agentcore:$r:aws:tool/web-search.v1"}]}'
# 2. The gateway (IAM sign-in: only keys allowed below can use it) — note its gatewayId — and its web search target
aws bedrock-agentcore-control create-gateway --region $r --name $gw --role-arn arn:aws:iam::$a:role/$WEBSEARCH_AWS_ROLE --protocol-type MCP --authorizer-type AWS_IAM
aws bedrock-agentcore-control create-gateway-target --region $r --gateway-identifier GATEWAY_ID --name web-search-tool --target-configuration '{"mcp":{"connector":{"source":{"connectorId":"web-search"},"configurations":[{"name":"WebSearch","parameterValues":{}}]}}}' --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]'
# 3. This AWS key may use the gateway (and find it); then ./stack websearch check
$(websearch_user_policy_cmd "arn:aws:bedrock-agentcore:$r:$a:gateway/GATEWAY_ID")
EOF
}

# websearch_agentcore_fix -> what makes AgentCore Web Search usable with this key, as its check found it (lines; nothing
# while it is ready)
websearch_agentcore_fix() {
  local url gid r
  case "$(websearch_agentcore_status)" in
    ready) ;;
    denied) url="$(_ws_state agentcore url)"; gid="$(_ws_gateway_id "$url")"; r="$(_ws_url_region "$url")"
            echo "AgentCore Web Search: your AWS admin lets this key use the gateway $gid (an IAM change; then ./stack websearch check):"
            websearch_user_policy_cmd "arn:aws:bedrock-agentcore:$r:$(_ws_account):gateway/$gid" ;;
    no-target) url="$(_ws_state agentcore url)"; gid="$(_ws_gateway_id "$url")"
               echo "AgentCore Web Search: your AWS admin adds a web search target to the gateway $gid (then ./stack websearch check):"
               websearch_aws_setup | grep 'create-gateway-target' | sed "s/GATEWAY_ID/$gid/" ;;
    *) echo "AgentCore Web Search (no other key; \$7 per 1,000 searches): your AWS admin sets it up once — ./stack websearch aws-setup prints the commands" ;;
  esac
}

# websearch_fix BACKEND -> what turns web search on, or makes BACKEND work (lines; nothing when there is nothing to do)
websearch_fix() {
  local b="$1" st why url gid r a
  if [ -z "$b" ]; then
    [ "$(websearch_choice)" != off ] || return 0
    websearch_agentcore_fix
    case "$(websearch_agentcore_status)" in
      denied | no-target) ;;
      *) echo "or your own search key or SearXNG: ./stack config set WEBSEARCH_TAVILY_API_KEY (or _BRAVE_, _PERPLEXITY_) | WEBSEARCH_SEARXNG_URL" ;;
    esac
    websearch_builtin_on || echo "or the built-in SearXNG (free, no key): ./stack config set WEBSEARCH_SEARXNG_BUILTIN on"
    return 0
  fi
  IFS=$'\037' read -r st why _ <<< "$(websearch_check_state "$b")"
  [ "$st" = failed ] || return 0
  case "$b:$why" in
    agentcore:*InvokeGateway*)
      url="$(websearch_agentcore_url)"; gid="$(_ws_gateway_id "$url")"; r="$(_ws_url_region "$url")"; a="$(_ws_account)"
      echo "your AWS admin lets this key use the gateway (an IAM change; then ./stack websearch check):"
      websearch_user_policy_cmd "arn:aws:bedrock-agentcore:$r:$a:gateway/$gid" ;;
    agentcore:*InvokeWebSearch*)
      r="$(_ws_url_region "$(websearch_agentcore_url)")"
      echo "your AWS admin gives the gateway's service role bedrock-agentcore:InvokeWebSearch on arn:aws:bedrock-agentcore:$r:aws:tool/web-search.v1 (an IAM change; ./stack websearch aws-setup, step 1, has the policy; then ./stack websearch check)" ;;
    agentcore:*) echo "./stack websearch check tries again; ./stack logs litellm has LiteLLM's side" ;;
    searxng:*) echo "your SearXNG ($(_ws_url_masked "$(get_env WEBSEARCH_SEARXNG_URL)")) must answer /search?q=test&format=json from LiteLLM's container (JSON output on in its settings.yml: search.formats); then ./stack websearch check" ;;
    builtin:*) echo "./stack logs searxng says why; ./stack websearch check tries again. Search engines may refuse this computer's address for a while: a Tavily, Brave or Perplexity key gives steadier results (./stack config set WEBSEARCH_TAVILY_API_KEY)" ;;
    *) echo "a new key: ./stack config set $(websearch_key "$b") (then it is checked again)" ;;
  esac
}

# --- status ------------------------------------------------------------------------------------------------------------

# websearch_status_line [--short] -> one line for ./stack status (--short: without its "Web search for Claude Code: ",
# for ./stack code status)
websearch_status_line() {
  local b st why at p='Web search for Claude Code: ' O_YEL O_OFF
  # shellcheck disable=SC2034  # set by out_colors; unused here
  local O_RED O_GRN
  out_colors
  [ "${1:-}" != --short ] || p=''
  b="$(websearch_backend)"
  IFS=$'\037' read -r st why at <<< "$(websearch_check_state "$b")"
  if [ -z "$b" ]; then printf '%soff — %s (./stack websearch status)\n' "$p" "$why"; return 0; fi
  case "$st" in
    ok) printf '%s%s (%s; checked %s)\n' "$p" "$(websearch_name "$b")" "$(websearch_price_words "$b")" "${at%%T*}" ;;
    failed) printf '%s%s%s does not work — %s (./stack websearch status)%s\n' "$O_YEL" "$p" "$(websearch_name "$b")" "$why" "$O_OFF" ;;
    *) printf '%s%s (%s; not checked%s)\n' "$p" "$(websearch_name "$b")" "$(websearch_price_words "$b")" "${why:+: $why}" ;;
  esac
}

# websearch_summary_line -> setup's summary line
websearch_summary_line() {
  local b; b="$(websearch_backend)"
  if [ -n "$b" ]; then printf '  Web search      %s for Claude Code'"'"'s WebSearch   (./stack websearch status)\n' "$(websearch_name "$b")"
  else printf '  Web search      off for Claude Code'"'"'s WebSearch   (./stack websearch status turns it on)\n'; fi
}

websearch_status() {
  local b c st why at k sel
  b="$(websearch_backend)"; c="$(websearch_choice)"
  IFS=$'\037' read -r st why at <<< "$(websearch_check_state "$b")"
  websearch_status_line
  if [ -n "$b" ]; then
    case "$b" in
      agentcore) printf '  Sent        only the search query, to Amazon Bedrock AgentCore Web Search in your AWS account (gateway %s); it stays inside AWS\n' "$(websearch_agentcore_url)" ;;
      searxng) printf '  Sent        only the search query, to your SearXNG (%s) and from there to the search engines it asks\n' "$(_ws_url_masked "$(get_env WEBSEARCH_SEARXNG_URL)")" ;;
      builtin) printf '  Sent        only the search query, to the built-in SearXNG (a container only LiteLLM reaches) and from there to %s, from this computer'"'"'s internet address: they may rate-limit it (a key gives steadier results)\n' "$WEBSEARCH_SEARXNG_ENGINE_NAMES" ;;
      *) printf '  Sent        only the search query, to %s with your key\n' "$(websearch_name "$b")" ;;
    esac
    printf '  Cost        %s; booked on the LiteLLM key of the session that searched, like its model'"'"'s spend\n' "$(websearch_price_words "$b")"
    printf '  Why         %s\n' "$(websearch_reason "$b")"
  fi
  printf '  Backend     WEBSEARCH_BACKEND=%s:' "$c"
  for k in $(websearch_backends); do
    sel=''; [ "$k" != "$b" ] || sel=' (in use)'
    if websearch_set_up "$k"; then printf ' %s ✓%s' "$k" "$sel"
    else printf ' %s –' "$k"; fi
  done
  printf '\n'
  if websearch_builtin_on; then printf '  Built-in    SearXNG on (WEBSEARCH_SEARXNG_BUILTIN): free, no key; it asks %s\n' "$WEBSEARCH_SEARXNG_ENGINE_NAMES"
  else printf '  Built-in    SearXNG off (WEBSEARCH_SEARXNG_BUILTIN=off): no container\n'; fi
  case "$(websearch_agentcore_status)" in
    ready) printf '  AgentCore   gateway %s answers this key (tool %s)\n' "$(_ws_state agentcore url)" "$(_ws_state agentcore tool)" ;;
    denied) printf '  AgentCore   gateway %s: this key may not use it (bedrock-agentcore:InvokeGateway)\n' "$(_ws_state agentcore url)" ;;
    no-target) printf '  AgentCore   gateway %s has no web search target\n' "$(_ws_state agentcore url)" ;;
    no-gateway)
      case "$(_ws_state agentcore why)" in
        bedrock-agentcore:ListGateways) printf '  AgentCore   no gateway: none set, and this key may not look for one (bedrock-agentcore:ListGateways)\n' ;;
        'not found') printf '  AgentCore   no gateway at %s (it does not exist)\n' "$(get_env WEBSEARCH_AGENTCORE_GATEWAY)" ;;
        *) printf '  AgentCore   no gateway with a web search target in %s\n' "$(websearch_agentcore_region)" ;;
      esac ;;
    unverified) printf '  AgentCore   not verified: %s\n' "$(_ws_state agentcore why)" ;;
  esac
  if [ -n "$(websearch_fix "$b")" ]; then printf '  To do       '; websearch_fix "$b" | sed '2,$s/^/              /'; fi
  printf '  Settings    ./stack config set WEBSEARCH_BACKEND (auto | off | %s), WEBSEARCH_SEARXNG_BUILTIN (on | off), WEBSEARCH_AGENTCORE_GATEWAY, WEBSEARCH_TAVILY_API_KEY, …\n' "$(websearch_backends | paste -sd'|' - | sed 's/|/ | /g')"
}

websearch_usage() {
  cat <<'EOF'
Usage: ./stack websearch [status | check | aws-setup]
  status      Which backend Claude Code's WebSearch uses, what it sends where, what it costs, what to do
  check       Check again: AgentCore's gateway and permission (free), then one search (~$0.007 at most,
              on the setup key); LiteLLM restarts when the backend changes
  aws-setup   The one-time AWS setup of AgentCore Web Search, as commands for your AWS admin (none runs here)
Backends: WEBSEARCH_BACKEND=auto (blank: the first set up of agentcore, tavily, brave, perplexity, searxng, else the
built-in SearXNG, builtin) | off | one of them. Keys and URLs: ./stack config set WEBSEARCH_AGENTCORE_GATEWAY |
WEBSEARCH_TAVILY_API_KEY | WEBSEARCH_BRAVE_API_KEY | WEBSEARCH_PERPLEXITY_API_KEY | WEBSEARCH_SEARXNG_URL; the
built-in SearXNG (free, on by default): WEBSEARCH_SEARXNG_BUILTIN=on|off. README: "Web search for Claude Code".
EOF
}

cmd_websearch() {
  local cfg before
  [ -f "$ENV_FILE" ] || die "run ./stack setup first"
  case "${1:-status}" in
    status) [ $# -le 1 ] || die "usage: ./stack websearch status"; websearch_status ;;
    aws-setup) [ $# -le 1 ] || die "usage: ./stack websearch aws-setup"; websearch_aws_setup ;;
    check)
      [ $# -le 1 ] || die "usage: ./stack websearch check"
      stack_lock websearch   # lib/lock.sh: not while an update/setup/restore changes the stack
      [ -n "$(get_env LITELLM_MASTER_KEY)" ] && [ -f "$STACK_DIR/litellm/config.yaml" ] || die "run ./stack setup first"
      log "checking AgentCore Web Search (free: who this key is, its gateway, its permission)"
      websearch_before_render --force || true
      cfg="$STACK_DIR/litellm/config.yaml"; before="$(cat "$cfg")"
      render_config "$(_enabled_or_all)"
      if ! _cfg_stack_running; then websearch_write_json; websearch_status; log "the stack is stopped: ./stack up applies it (and checks one search)"; return 0; fi
      [ "$(cat "$cfg")" = "$before" ] || run_phase "LiteLLM (web search)" litellm dc up -d --no-deps --force-recreate --wait litellm
      websearch_builtin_up   # the built-in SearXNG up (or gone, while it is off) before its search
      websearch_after_start --force ;;
    -h | --help | help) websearch_usage ;;
    *) websearch_usage >&2; exit 2 ;;
  esac
}
