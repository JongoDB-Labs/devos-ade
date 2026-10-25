# shellcheck shell=bash
# Optional Experiential Labs gateway (https://experientiallabs.ai): one OpenAI-compatible API in front of many models,
# paid from the gateway's credits or by your own provider keys connected there (BYOK). Off unless .env holds
# EXPLABS_API_KEY: without one nothing here talks to the network and no xl/… model is rendered. Only .env counts (dc()
# strips EXPLABS_* from the shell's environment).
#
# Data flow, requests joined by model id:
#   GET https://api.experientiallabs.ai/v1/models WITH the key (curl -K -: never on a command line, in a URL or a log):
#     the ids this key may call — the OpenAI list, nothing else (id, object, created, owned_by);
#   GET https://api.experientiallabs.ai/api/models/<id> WITHOUT it (the public catalog, keyless), one per model
#     EXPLABS_MODELS picks, side by side: that model's deployments and the order the gateway tries them in (its default
#     waterfall); the deployment it serves the model on says what the model takes (capabilities: supports_temperature,
#     supports_top_p, supports_tools, chat_max_tokens_field, …) and its list price. (The whole catalog, ~1,000 models
#     and 2.4 MB, took 40-54 s to send on 2026-10-25; one model's answer, 10-25 KB, 15-25 s.)
# → litellm/explabs-models.tsv: every model of the key's list, the chosen ones with their details when the catalog has
# them (one the catalog lacks — an organisation's own model, an alias — has none: fail safe) → EXPLABS_MODELS (a comma
# list of exact gateway ids; blank = qwen3.8-27b) picks the ones rendered into
# litellm/config.yaml as "xl/<id>" → openai/<id> at the gateway. Each sends only the parameters its model takes:
# drop_params plus the model's additional_drop_params, and the output cap under the field it names, max_tokens when it
# names none (LiteLLM's hook, lib/litellm-hooks/bn_hooks.py). A model without metadata — the list could not be read and
# none is cached for this key — runs fail safe: no sampling, penalty or logprob parameter, response_format or
# reasoning_effort (XL_FAILSAFE_DROPS), while tools and the max_tokens cap pass (a model that cannot take one answers
# with a clear 400); ./stack status says so. The key reaches only LiteLLM (os.environ/EXPLABS_API_KEY in the config) and
# api.experientiallabs.ai/v1; the catalog is asked without it, and so without anything about you.
#
# Costs: the gateway reports what each call cost (usage.cost, USD; 0 with usage.is_byok, which your own provider
# bills). LiteLLM's hook books exactly that; the list prices in the config only price a reply without one.
#
# Hooks for other parts of ./stack:
#   explabs_refresh [MAX_AGE_MIN]   read the model list (setup, Settings; ./stack up in the background, 12 h); XL_CHANGED
#   explabs_yaml                    LiteLLM model_list entries (render_litellm_config)
#   explabs_write_portal_json       litellm/explabs-models.json for the portal (render_config)
#   explabs_code_rows               the Code page's and claude-bedrock's rows (lib/code_models.sh)
#   explabs_sync_owui               Open WebUI names and tags (needs a portal session)
#   explabs_cost_prices_entries     Chat's cost line (lib/owui.sh cost_prices_json)
#   explabs_status_line / explabs_summary_line / explabs_costs_section / explabs_models_section
#   setup_explabs / explabs_up_hook / explabs_after_up   setup, and ./stack up before `compose up` / in its portal session

# Where the key goes. Only the test suite (BEDROCK_NOW_TESTING=1, as lib/host.sh) can point this at another server:
# BEDROCK_NOW_TEST_EXPLABS_API in a user's shell is ignored, with a warning (as lib/openrouter.sh's and lib/stt.sh's
# test addresses). The catalog lives beside it.
_xl_api() {
  if [ -n "${BEDROCK_NOW_TEST_EXPLABS_API:-}" ]; then
    if [ "${BEDROCK_NOW_TESTING:-}" = 1 ]; then printf '%s\n' "$BEDROCK_NOW_TEST_EXPLABS_API"; return 0; fi
    test_url_ignored BEDROCK_NOW_TEST_EXPLABS_API "the Experiential Labs key"
  fi
  printf 'https://api.experientiallabs.ai/v1\n'
}
EXPLABS_API="$(_xl_api)"
# xl_api_ok -> 0 when EXPLABS_API may get the key: https, or any address while testing
xl_api_ok() { case "$EXPLABS_API" in https://?*) return 0 ;; esac; [ "${BEDROCK_NOW_TESTING:-}" = 1 ]; }
EXPLABS_CATALOG="${EXPLABS_API%/v1}/api/models"   # one model: $EXPLABS_CATALOG/<id>
XL_HOST="${EXPLABS_API#*://}"; XL_HOST="${XL_HOST%%/*}"
XL_LIST_TIMEOUT=30      # s for the key's list (GET /v1/models: ~23 KB)
XL_MODEL_TIMEOUT=90     # s for one model's details (GET /api/models/<id>: 10-25 KB, 15-25 s on 2026-10-25), all side by side
XL_REFRESH_BUDGET=100   # s for a whole refresh, both kinds of request: what setup or a Settings change waits at most
XL_MODEL_MAX=40         # at most this many models' details per refresh (more chosen: those beyond run fail safe, said)
# curl's --proto: https only, but for the test suite's stand-ins (BEDROCK_NOW_TESTING=1)
_xl_proto() { if [ "${BEDROCK_NOW_TESTING:-}" = 1 ]; then printf '=http,https\n'; else printf '=https\n'; fi; }
EXPLABS_DEFAULT_MODELS=qwen3.8-27b
EXPLABS_KEYS_URL=https://platform.experientiallabs.ai/settings/api-keys
# The request parameters the gateway's metadata decides about: each goes only to a model whose metadata says it takes
# it (unknown = not taken, except tools: they go unless the details say false; the output cap: the field the model
# names, max_tokens when it names none). The rest of a
# request (messages, stream, stop, …) passes as it came.
# shellcheck disable=SC2034  # the reference list: tests/test_explabs.sh holds the hook's XL_OPTIONAL to it
XL_OPTIONAL_PARAMS="temperature top_p top_k frequency_penalty presence_penalty logprobs top_logprobs tools tool_choice parallel_tool_calls functions function_call response_format reasoning_effort max_tokens max_completion_tokens"
# What a model without metadata (fail safe) is never sent: the sampling, penalty and logprob parameters, response_format
# and reasoning_effort (some models refuse them, and the call then fails with all_routes_failed). Its tools and its cap,
# as max_tokens, pass: a model that cannot take them answers with a clear 400 (unsupported_capability /
# unsupported_parameter), which beats a Claude Code that silently cannot use tools or an answer without a cap.
XL_FAILSAFE_DROPS="temperature top_p top_k frequency_penalty presence_penalty logprobs top_logprobs response_format reasoning_effort max_completion_tokens"

xl_cache_tsv() { printf '%s\n' "$STACK_DIR/litellm/explabs-models.tsv"; }
xl_cache_json() { printf '%s\n' "$STACK_DIR/litellm/explabs-models.json"; }
# what the last refresh could not do (one line: epoch TAB reason; no key, ever) and whose key the list was read with
xl_error_file() { printf '%s\n' "$STATE_DIR/explabs-fetch-error"; }
xl_key_mark() { printf '%s\n' "$STATE_DIR/explabs-key.sha256"; }
# ./stack up's refresh in the background: its pid (while it runs), its output, and a mark that it changed the models
xl_bg_pid_file() { printf '%s\n' "$STATE_DIR/explabs-refresh.pid"; }
xl_bg_log() { printf '%s\n' "$STATE_DIR/explabs-refresh.log"; }
xl_pending_file() { printf '%s\n' "$STATE_DIR/explabs-render-pending"; }

# valid_xl_key KEY -> 0 if it looks like a key we can store and send safely: 20-256 letters, digits, - and _
# (the gateway's keys are xpl_ and 40 hex digits today; the gateway itself decides)
valid_xl_key() {
  case "$1" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#1}" -ge 20 ] && [ "${#1}" -le 256 ]
}

# explabs_enabled -> 0 when .env holds a usable key (a malformed one is off, and never sent anywhere)
explabs_enabled() { valid_xl_key "$(get_env EXPLABS_API_KEY)"; }
xl_key_problem() {
  local k; k="$(get_env EXPLABS_API_KEY)"
  [ -z "$k" ] || valid_xl_key "$k" ||
    warn "EXPLABS_API_KEY in .env is not a valid key (20-256 letters, digits, - and _) — Experiential Labs stays off; ./stack config set EXPLABS_API_KEY replaces it"
}

# valid_xl_id ID -> 0 for a gateway model id we can write into YAML and JSON as it is: a letter or digit, then
# letters, digits and . _ : - (the slugs of GET /v1/models; "<slug>:free" for a model's free tier), at most 128
valid_xl_id() {
  case "$1" in '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}
# valid_xl_models VALUE -> 0 for blank or a comma list of gateway ids (an "xl/" before each is accepted)
valid_xl_models() {
  local m rest
  case "$1" in '') return 0 ;; ,* | *, | *,,*) return 1 ;; esac
  rest="$1,"
  while [ -n "$rest" ]; do
    m="${rest%%,*}"; rest="${rest#*,}"; m="${m#xl/}"
    valid_xl_id "$m" || return 1
  done
}

# xl_wanted -> the ids EXPLABS_MODELS names (blank: the default), one per line, without "xl/", each once
xl_wanted() {
  local v; v="$(get_env EXPLABS_MODELS)"; [ -n "$v" ] || v="$EXPLABS_DEFAULT_MODELS"
  printf '%s\n' "$v" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^xl/##' |
    while IFS= read -r m; do ! valid_xl_id "$m" || printf '%s\n' "$m"; done | awk '!seen[$0]++'
}

# xl_ids < GET /v1/models JSON -> the ids it lists, one per line, each once; only those that are valid_xl_id. Only the
# id is read: this list says which models the key may call, never what they take (the gateway sends no details here).
xl_ids() {
  or_json_flatten | awk -F'\t' '$1 ~ /^data\.[0-9]+\.id$/ && $2 ~ /^[A-Za-z0-9][A-Za-z0-9._:-]*$/ && length($2) <= 128 && !seen[$2]++ { print $2 }'
}

# xl_model_tsv ID < GET /api/models/<id> JSON -> one TAB-separated line: ID temperature top_p top_k frequency_penalty
# presence_penalty logprobs tools structured_output reasoning sampling_requires_reasoning_none max_tokens_field max_out
# context in out cache_read cache_write — the details of the deployment the gateway serves the model on: the first
# active rung of its default waterfall (lowest position) whose deployment is active; without one, the first active
# deployment of its default_provider_ids; without that, the first active one the gateway can route on its own
# (routable). From that deployment's capabilities the supports_* fields as 1 (true), 0 (false) or empty (null, or not
# listed) and the field as max_tokens | max_completion_tokens | empty; its list prices (nano-USD per million tokens) and
# the model's max_output_tokens and context_window as whole numbers or empty. No such deployment: ID and the counts
# alone (fail safe). The indices walked are only those the answer holds, in their order.
xl_model_tsv() {
  or_json_flatten | awk -F'\t' -v OFS='\t' -v id="$1" '
    function b(v) { return v == "true" ? 1 : (v == "false" ? 0 : "") }
    function w(v) { return (v ~ /^[0-9]+$/ && length(v) <= 18) ? v : "" }
    $1 == "model.max_output_tokens" { mo = w($2); next }
    $1 == "model.context_window" { cx = w($2); next }
    $1 ~ /^providers\.[0-9]+\./ {
      split($1, k, "."); i = k[2]; if (!(i in pseen)) { pseen[i] = 1; pord[++np] = i }
      f = substr($1, length("providers." i ".") + 1)
      if (f == "id") pid[i] = $2
      else if (f == "status") pst[i] = $2
      else if (f == "routable") prt[i] = $2
      else if (f ~ /^capabilities\.[a-z_]+$/) cap[i, substr(f, 14)] = $2
      else if (f == "input_nano_usd_per_million") ppi[i] = w($2)
      else if (f == "output_nano_usd_per_million") ppo[i] = w($2)
      else if (f == "cached_input_nano_usd_per_million") ppr[i] = w($2)
      else if (f == "cache_write_input_nano_usd_per_million") ppw[i] = w($2)
      next
    }
    $1 ~ /^default_waterfall\.[0-9]+\./ {
      split($1, k, "."); i = k[2]; if (!(i in rseen)) { rseen[i] = 1; rord[++nr] = i }
      f = substr($1, length("default_waterfall." i ".") + 1)
      if (f == "position") rpos[i] = $2; else if (f == "model_provider_id") rmp[i] = $2; else if (f == "status") rst[i] = $2
      next
    }
    $1 ~ /^default_provider_ids\.[0-9]+$/ { split($1, k, "."); i = k[2]; if (!(i in dseen)) { dseen[i] = 1; dord[++nd] = i }; did[i] = $2 }
    function on(i) { return pst[i] == "active" }
    END {
      for (j = 1; j <= np; j++) { i = pord[j]; if (pid[i] != "" && !(pid[i] in byid)) byid[pid[i]] = i }
      lane = ""; best = ""
      for (j = 1; j <= nr; j++) { r = rord[j]
        if (rst[r] != "active" || rpos[r] !~ /^[0-9]+$/ || !(rmp[r] in byid) || !on(byid[rmp[r]])) continue
        if (best == "" || rpos[r] + 0 < rpos[best] + 0) best = r }
      if (best != "") lane = byid[rmp[best]]
      for (j = 1; j <= nd && lane == ""; j++) { d = did[dord[j]]; if ((d in byid) && on(byid[d])) lane = byid[d] }
      for (j = 1; j <= np && lane == ""; j++) { i = pord[j]; if (on(i) && prt[i] == "true") lane = i }
      if (lane == "") { print id, "", "", "", "", "", "", "", "", "", "", "", mo, cx, "", "", "", ""; exit }
      L = lane; mf = cap[L, "chat_max_tokens_field"]; if (mf != "max_tokens" && mf != "max_completion_tokens") mf = ""
      print id, b(cap[L, "supports_temperature"]), b(cap[L, "supports_top_p"]), b(cap[L, "supports_top_k"]),
        b(cap[L, "supports_frequency_penalty"]), b(cap[L, "supports_presence_penalty"]), b(cap[L, "supports_logprobs"]),
        b(cap[L, "supports_tools"]), b(cap[L, "supports_structured_output"]), b(cap[L, "supports_reasoning"]),
        b(cap[L, "sampling_requires_reasoning_none"]), mf, mo, cx, ppi[L], ppo[L], ppr[L], ppw[L]
    }'
}

# The rules, in awk (one copy for the config, the Code page's rows and the tests):
#   xl_drops(fail safe 1/0, row fields 2..12) -> what to leave out of a request to that model, space-separated: with
#     details, every parameter of XL_OPTIONAL_PARAMS its metadata does not say it takes (unknown = not taken; tools only
#     on an explicit false: a model that cannot take them answers with a clear 400), sampling
#     too when it takes sampling only with reasoning off, and the output-cap field it does not name (when it names none:
#     max_completion_tokens, the cap goes as max_tokens); fail safe, XL_FAILSAFE_DROPS
#   xl_cap(field) -> the field the output cap goes under: the one the model names, else max_tokens
#   xl_shift(NANO, K) -> a whole number of nano-USD moved K places: per token (15) or per million tokens (9), exact
# shellcheck disable=SC2016  # awk source, not shell
XL_AWK='
function xl_drops(fs, te, tp, tk, fq, pp, lp, tl, so, rs, sn, mf,   d) {
  if (fs == 1) return "temperature top_p top_k frequency_penalty presence_penalty logprobs top_logprobs response_format reasoning_effort max_completion_tokens"
  d = ""
  if (te != "1" || sn == "1") d = d " temperature"
  if (tp != "1" || sn == "1") d = d " top_p"
  if (tk != "1" || sn == "1") d = d " top_k"
  if (fq != "1") d = d " frequency_penalty"
  if (pp != "1") d = d " presence_penalty"
  if (lp != "1") d = d " logprobs top_logprobs"
  if (tl == "0") d = d " tools tool_choice parallel_tool_calls functions function_call"
  if (so != "1") d = d " response_format"
  if (rs != "1") d = d " reasoning_effort"
  d = d (xl_cap(mf) == "max_tokens" ? " max_completion_tokens" : " max_tokens")
  return substr(d, 2)
}
function xl_cap(mf) { return mf == "max_completion_tokens" ? mf : "max_tokens" }
function xl_shift(v, k,   s) {
  if (v !~ /^[0-9]+$/) return ""
  s = v; while (length(s) <= k) s = "0" s
  s = substr(s, 1, length(s) - k) "." substr(s, length(s) - k + 1)
  sub(/0+$/, "", s); sub(/\.$/, "", s); sub(/^0+/, "", s)
  if (s == "") s = "0"; if (substr(s, 1, 1) == ".") s = "0" s
  return s
}
function xl_vendor(id) {
  if (id ~ /^claude/) return "Anthropic"
  if (id ~ /^(gpt|chatgpt|codex|o[0-9])/) return "OpenAI"
  if (id ~ /^(gemini|gemma)/) return "Google"
  if (id ~ /^qwen/) return "Qwen"
  if (id ~ /^deepseek/) return "DeepSeek"
  if (id ~ /^llama/) return "Meta"
  if (id ~ /^(mistral|ministral|codestral|devstral|magistral)/) return "Mistral"
  if (id ~ /^grok/) return "xAI"
  if (id ~ /^glm/) return "Z.ai"
  if (id ~ /^kimi/) return "Moonshot"
  return ""
}'

xl_key_hash() { printf '%s' "$1" | openssl dgst -sha256 | awk '{ print $NF }'; }
# xl_join IDS_FILE < xl_model_tsv rows -> one row per id of IDS_FILE (the key's list, in its order): its details row,
# or the id alone when there is none (not chosen, or the catalog has none: fail safe). A row the key's list lacks is not
# kept.
xl_join() {
  awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { want[++n] = $1; next } !($1 in row) { row[$1] = $0 }
    END { for (i = 1; i <= n; i++) print ((want[i] in row) ? row[want[i]] : want[i]) }' "$1" -
}

# xl_cache_current -> 0 when the cached list was read with the key .env holds now (another key: another
# organisation, other models)
xl_cache_current() {
  local f m; f="$(xl_cache_tsv)"; m="$(xl_key_mark)"
  [ -s "$f" ] && [ -r "$m" ] && [ "$(head -c 64 "$m")" = "$(xl_key_hash "$(get_env EXPLABS_API_KEY)")" ]
}
xl_cached_rows() { local f; f="$(xl_cache_tsv)"; [ -r "$f" ] || return 0; grep -v '^#' "$f" || true; }
xl_fetched_at() { local f; f="$(xl_cache_tsv)"; [ -r "$f" ] || return 0; sed -n 's/^# fetched_at: //p' "$f" | head -n 1; }

# xl_selected -> one line per model EXPLABS_MODELS picks: STATE then the xl_model_tsv fields. STATE = details (the
# cached list for this key has its details) or failsafe (no list for this key, or no details for it in the list:
# XL_FAILSAFE_DROPS). With a list, an id it does not have is left out (the gateway would refuse it); "<slug>:free"
# takes its slug's details, at $0. Empty without a key.
xl_selected() {
  local have=0 rows
  explabs_enabled || return 0
  if xl_cache_current; then have=1; rows="$(xl_cached_rows)"; else rows=''; fi
  xl_wanted | H="$have" R="$rows" awk -F'\t' -v OFS='\t' '
    BEGIN { n = split(ENVIRON["R"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], c, "\t"); if (c[1] != "") row[c[1]] = l[i] } }
    { id = $1; base = id; free = sub(/:free$/, "", base)
      # (a model the list names without any details: as fail safe as one it does not know)
      if (id in row) { split(row[id], c, "\t"); print (bare(c) ? "failsafe" : "details"), row[id]; next }
      if (!free && ENVIRON["H"] == 1) next
      # a free tier: its slug'"'"'s details (or none), its prices $0 (fields 15-18: in out cache_read cache_write)
      for (i = 2; i <= 18; i++) c[i] = ""
      if (free && (base in row)) split(row[base], c, "\t")
      else if (ENVIRON["H"] == 1) next
      if (free) { c[15] = 0; c[16] = 0; c[17] = ""; c[18] = "" }
      s = id; for (i = 2; i <= 18; i++) s = s OFS c[i]
      print ((free && (base in row) && !bare(c)) ? "details" : "failsafe"), s }
    function bare(c,  i) { for (i = 2; i <= 12; i++) if (c[i] != "") return 0; return 1 }'
}
# xl_missing -> the ids EXPLABS_MODELS names that the list read for this key does not have (nothing without a list)
xl_missing() {
  xl_cache_current || return 0
  xl_wanted | R="$(xl_cached_rows | cut -f1)" awk 'BEGIN { n = split(ENVIRON["R"], l, "\n"); for (i = 1; i <= n; i++) have[l[i]] = 1 }
    { b = $1; sub(/:free$/, "", b) } !($1 in have) && !(b in have)'
}

# xl_yaml_entries < xl_selected -> LiteLLM model_list entries (render_litellm_config's indentation). model_info carries
# the list prices (only a reply without usage.cost is priced with them), bn_xl (the hook knows its own) and the output
# cap's field (bn_xl_max_tokens), which the hook moves a cap sent under the other name to.
xl_yaml_entries() {
  awk -F'\t' -v base="$EXPLABS_API" "$XL_AWK"'
    { id = $2
      printf "  - model_name: \"xl/%s\"\n    litellm_params:\n      model: \"openai/%s\"\n      api_base: \"%s\"\n", id, id, base
      printf "      api_key: os.environ/EXPLABS_API_KEY\n      drop_params: true\n"
      n = split(xl_drops($1 == "failsafe", $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13), d, " "); s = ""
      for (i = 1; i <= n; i++) s = s (i > 1 ? ", " : "") "\"" d[i] "\""
      printf "      additional_drop_params: [%s]\n    model_info:\n      mode: \"chat\"\n", s
      if (xl_shift($16, 15) != "") printf "      input_cost_per_token: %s\n", xl_shift($16, 15)
      if (xl_shift($17, 15) != "") printf "      output_cost_per_token: %s\n", xl_shift($17, 15)
      if (xl_shift($18, 15) != "") printf "      cache_read_input_token_cost: %s\n", xl_shift($18, 15)
      if (xl_shift($19, 15) != "") printf "      cache_creation_input_token_cost: %s\n", xl_shift($19, 15)
      printf "      bn_xl: true\n      bn_xl_max_tokens: \"%s\"\n", xl_cap($13)
    }'
}

# explabs_yaml -> model_list entries for the chosen models; nothing without a key. Called by render_litellm_config.
explabs_yaml() {
  explabs_enabled || return 0
  if ! xl_api_ok; then warn "Experiential Labs: $EXPLABS_API is not https — no xl/ model is rendered"; return 0; fi
  xl_selected | xl_yaml_entries
}

# explabs_code_rows -> for lib/code_models.sh, one line per chosen model: id ("xl/…") name vendor in out cache_read
# cache_write (USD per million tokens, empty when unknown) free tools max_out context — tools 1 or 0 as its details
# say, empty when they do not say or fail safe (the tools are sent, untested)
explabs_code_rows() {
  explabs_enabled || return 0
  xl_selected | awk -F'\t' -v OFS='\t' "$XL_AWK"'
    { free = ($16 != "" && $17 != "" && $16 + 0 == 0 && $17 + 0 == 0) ? 1 : 0
      tools = ($1 == "failsafe" || ($9 != "1" && $9 != "0")) ? "" : $9
      print "xl/" $2, $2, xl_vendor($2), xl_shift($16, 9), xl_shift($17, 9), xl_shift($18, 9), xl_shift($19, 9), free, tools, $14, $15 }'
}

# xl_price_text IN OUT (USD per token) -> "$0.32 in / $2.40 out per 1M tokens", "free" or "price unknown"
xl_price_text() {
  if [ -z "$1" ] || [ -z "$2" ]; then echo 'price unknown'; return 0; fi
  awk -v p="$1" -v c="$2" 'BEGIN { if (p + 0 == 0 && c + 0 == 0) { print "free"; exit } printf "%s %s\n", p * 1000000, c * 1000000 }' |
    { read -r a b || true; if [ -z "${b:-}" ]; then echo "${a:-free}"; else printf '%s in / %s out per 1M tokens\n' "$(money "$a")" "$(money "$b")"; fi; }
}

# explabs_write_portal_json — litellm/explabs-models.json for the portal (Home's model list, Chat's Who answers and the
# Code page): the chosen models with their list prices (USD per token), whether each runs on the gateway's details or
# fail safe, and when the list was read. Removed while Experiential Labs is off. No key in it, ever.
explabs_write_portal_json() {
  local f tmp
  f="$(xl_cache_json)"
  if ! explabs_enabled; then rm -f "$f"; return 0; fi
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  tmp="$(mktemp "$f.XXXXXX")" || return 0
  xl_selected | FA="$(xl_fetched_at)" CUR="$(xl_cache_current && echo 1 || echo 0)" ERR="$(xl_error_text | tr -d '"\\')" \
    awk -F'\t' "$XL_AWK"'
    function num(v) { return v == "" ? "null" : v }
    { pin = xl_shift($16, 15); pout = xl_shift($17, 15)
      r[++n] = sprintf("{\"id\":\"xl/%s\",\"name\":\"%s\",\"vendor\":\"%s\",\"prompt\":%s,\"completion\":%s,\"context_length\":%s,\"free\":%s,\"failsafe\":%s}",
        $2, $2, xl_vendor($2), num(pin), num(pout), num($15), (pin != "" && pout != "" && pin + 0 == 0 && pout + 0 == 0) ? "true" : "false", ($1 == "failsafe" ? "true" : "false")) }
    END {
      printf "{\"fetched_at\":%s,\"details\":%s,\"error\":%s,\"models\":[", (ENVIRON["CUR"] == 1 && ENVIRON["FA"] != "" ? "\"" ENVIRON["FA"] "\"" : "null"),
        (ENVIRON["CUR"] == 1 ? "true" : "false"), (ENVIRON["ERR"] != "" ? "\"" ENVIRON["ERR"] "\"" : "null")
      for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "," : ""), r[i]
      print "]}"
    }' > "$tmp" || { rm -f "$tmp"; return 0; }
  chmod 644 "$tmp"; mv "$tmp" "$f"
}

# xl_curl_why RC CONNECT_TIME LIMIT WHAT -> what went wrong reading WHAT, in words, from curl's exit code RC (the
# connect time it reported tells a connection that never came from an answer too slow to finish within LIMIT s)
xl_curl_why() {
  case "$1" in
    6) printf 'could not resolve %s (DNS)' "$XL_HOST" ;;
    7) printf 'could not connect to %s' "$XL_HOST" ;;
    28) if [ -z "$(printf '%s' "${2:-0}" | tr -d '0.')" ]; then printf 'timed out connecting to %s' "$XL_HOST"
        else printf 'timed out after %s s reading %s from %s' "$3" "$4" "$XL_HOST"; fi ;;
    35 | 51 | 53 | 54 | 58 | 59 | 60 | 66 | 77 | 80 | 82 | 83 | 90 | 91) printf 'a TLS error with %s (curl exit %s)' "$XL_HOST" "$1" ;;
    63) printf '%s sent too much for %s' "$XL_HOST" "$4" ;;
    *) printf 'could not read %s from %s (curl exit %s)' "$4" "$XL_HOST" "$1" ;;
  esac
}

# xl_fetch_ids OUT KEY -> 0 if OUT now holds the ids the key may call (GET /v1/models with KEY on curl's stdin, the
# answer to a temp file of our own); otherwise XL_ERR says why
xl_fetch_ids() {
  local out="$1" raw w='' rc=0 code tc
  XL_ERR=''
  raw="$(mktemp)"; XL_TMPS="${XL_TMPS:-} $raw"
  w="$(curl_auth "$2" --proto "$(_xl_proto)" -sS --connect-timeout 10 -m "$XL_LIST_TIMEOUT" --max-filesize 20000000 -o "$raw" -w '%{http_code} %{time_connect}' "$EXPLABS_API/models" 2>/dev/null)" || rc=$?
  code="${w%% *}"; tc="${w#* }"; [ "$tc" != "$w" ] || tc=''
  if [ "$rc" != 0 ]; then XL_ERR="$(xl_curl_why "$rc" "$tc" "$XL_LIST_TIMEOUT" "the model list")"
  else
    case "$code" in
      200) ;;
      401 | 403) XL_ERR="the gateway rejected the key (HTTP $code) — a new one: $EXPLABS_KEYS_URL" ;;
      *) XL_ERR="$XL_HOST answered HTTP ${code:-?} when listing models" ;;
    esac
  fi
  if [ -z "$XL_ERR" ]; then
    xl_ids < "$raw" > "$out" || : > "$out"
    if [ ! -s "$out" ] && ! grep -q '"data"[[:space:]]*:[[:space:]]*\[' "$raw"; then XL_ERR="$XL_HOST sent no model list"; fi
  fi
  rm -f "$raw"
  [ -z "$XL_ERR" ]
}

# _xl_fetch_one ID PREFIX — one model's catalog answer (GET /api/models/ID, keyless) into PREFIX.json, and
# "curl's exit code, the HTTP status, the connect time" into PREFIX.st
_xl_fetch_one() {
  local rc=0 w=''
  w="$(curl --proto "$(_xl_proto)" -sS --connect-timeout 10 -m "${XL_MODEL_LIMIT:-$XL_MODEL_TIMEOUT}" --max-filesize 5000000 -o "$2.json" -w '%{http_code} %{time_connect}' "$EXPLABS_CATALOG/$1" 2>/dev/null)" || rc=$?
  printf '%s %s\n' "$rc" "${w:-000}" > "$2.st"
}

# xl_fetch_details OUT IDS_FILE [OLD_ROWS] -> 0 if OUT now holds a details row (xl_model_tsv) for each id of IDS_FILE
# the catalog has (GET /api/models/<id>, keyless: no key and nothing about you is sent; all at once, each within
# XL_MODEL_LIMIT s, default XL_MODEL_TIMEOUT; at most XL_MODEL_MAX ids; an id the catalog does not know — HTTP 404: an
# organisation's own model, an alias — has none, and runs fail safe); otherwise XL_ERR says what failed, and an id
# whose read failed keeps its row of OLD_ROWS (the cached list read with this key) when that has details
xl_fetch_details() {
  local out="$1" dir n=0 i id p pids='' rc code tc e err='' errs=0 lim="${XL_MODEL_LIMIT:-$XL_MODEL_TIMEOUT}" more=0
  XL_ERR=''; : > "$out"
  dir="$(mktemp -d)" || { XL_ERR="could not make a temporary folder"; return 1; }
  XL_TMPS="${XL_TMPS:-} $dir"
  while IFS= read -r id; do
    valid_xl_id "$id" || continue
    if [ "$n" -ge "$XL_MODEL_MAX" ]; then more=$((more + 1)); continue; fi
    n=$((n + 1))
    printf '%s\n' "$id" > "$dir/$n.id"
    _xl_fetch_one "$id" "$dir/$n" &
    pids="$pids $!"
  done < "$2"
  for p in $pids; do wait "$p" 2>/dev/null || true; done
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1)); id="$(cat "$dir/$i.id")"; e=''
    rc=1; code=''; tc=''; [ ! -r "$dir/$i.st" ] || read -r rc code tc < "$dir/$i.st" || true
    if [ "$rc" != 0 ]; then e="$(xl_curl_why "$rc" "$tc" "$lim" "the details of $id")"
    else
      case "$code" in
        200) if grep -q '"model"[[:space:]]*:' "$dir/$i.json" 2>/dev/null; then xl_model_tsv "$id" < "$dir/$i.json" >> "$out"
             else e="$XL_HOST sent no details for $id"; fi ;;
        404) ;;
        *) e="$XL_HOST answered HTTP ${code:-?} for the details of $id" ;;
      esac
    fi
    [ -n "$e" ] || continue
    errs=$((errs + 1)); [ -n "$err" ] || err="$e"
    if [ -n "${3:-}" ] && [ -r "$3" ]; then
      awk -F'\t' -v id="$id" '$1 == id { for (i = 2; i <= 12; i++) if ($i != "") { print; break } }' "$3" >> "$out"
    fi
  done
  rm -rf "$dir"
  if [ "$errs" -gt 1 ]; then err="$err (and $((errs - 1)) more)"; fi
  # (the ones beyond XL_MODEL_MAX: not read, and said so — never as if the catalog had nothing for them)
  if [ "$more" -gt 0 ]; then err="${err:+$err; }only the first $XL_MODEL_MAX chosen models' details are read: $more more run fail safe"; fi
  XL_ERR="$err"
  [ -z "$XL_ERR" ]
}

# xl_fetch_models OUT KEY -> the cached list in OUT (with a fetched_at header): 0 with the key's ids and the details of
# the chosen ones; 2 with the ids and the details that could be read — some could not (XL_ERR says why; those run fail
# safe unless the list cached for this key had theirs); 1 when the key's list could not be read (XL_ERR; OUT untouched)
xl_fetch_models() {
  local out="$1" ids det want old='' rc=0 t0 left
  ids="$(mktemp)"; det="$(mktemp)"; want="$(mktemp)"; t0="$(date +%s)"; XL_TMPS="${XL_TMPS:-} $ids $det $want"
  if ! xl_fetch_ids "$ids" "$2"; then rm -f "$ids" "$det" "$want"; return 1; fi
  # one deadline for the whole refresh: the details get what the list left of XL_REFRESH_BUDGET (at least 5 s), at most
  # XL_MODEL_TIMEOUT
  left=$((XL_REFRESH_BUDGET - ($(date +%s) - t0))); [ "$left" -ge 5 ] || left=5
  [ "$left" -le "$XL_MODEL_TIMEOUT" ] || left="$XL_MODEL_TIMEOUT"
  # the chosen models the key may call (a free tier: its model's details)
  xl_wanted | sed 's/:free$//' | awk 'FILENAME == ARGV[1] { have[$1] = 1; next } ($1 in have) && !seen[$1]++' "$ids" - > "$want"
  if xl_cache_current; then old="$(mktemp)"; XL_TMPS="$XL_TMPS $old"; xl_cached_rows > "$old"; fi
  XL_MODEL_LIMIT="$left" xl_fetch_details "$det" "$want" "$old" || rc=2
  { printf '# fetched_at: %s\n# source: %s/models (the ids, as listed for your key) and %s/<id> (the chosen ones'"'"' details)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EXPLABS_API" "$EXPLABS_CATALOG"
    printf '# id\ttemperature\ttop_p\ttop_k\tfrequency_penalty\tpresence_penalty\tlogprobs\ttools\tstructured_output\treasoning\tsampling_requires_reasoning_none\tmax_tokens_field\tmax_out\tcontext\tin\tout\tcache_read\tcache_write\n'
    xl_join "$ids" < "$det"; } > "$out"
  rm -f "$ids" "$det" "$want" ${old:+"$old"}
  return "$rc"
}

# xl_validate_key KEY -> 0 if the gateway accepts KEY (GET /v1/models: free); otherwise XL_ERR says why
xl_validate_key() {
  local tmp
  valid_xl_key "$1" || { XL_ERR="that does not look like an Experiential Labs key (20-256 letters, digits, - and _)"; return 1; }
  tmp="$(mktemp)"
  if xl_fetch_ids "$tmp" "$1"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; return 1
}

# xl_cache_has_details -> 0 when the cached list holds any model's details
# (read to the end: an awk that exits early can kill the writer with SIGPIPE, which pipefail turns into a failure)
xl_cache_has_details() { xl_cached_rows | awk -F'\t' '!f { for (i = 2; i <= 12; i++) if ($i != "") f = 1 } END { exit !f }'; }

# xl_error_text -> what the last refresh could not do ("" when it worked)
xl_error_text() { local f; f="$(xl_error_file)"; [ -r "$f" ] || return 0; cut -f2- "$f" | head -n 1 | cut -c1-300; }
xl_error_at() { local f; f="$(xl_error_file)"; [ -r "$f" ] || return 0; cut -f1 "$f" | head -n 1; }
_xl_signature() { xl_selected; get_env EXPLABS_API_KEY | openssl dgst -sha256; }

# xl_fresh MAX_AGE_MIN -> 0 when the cached list needs no refresh: younger than that, read with this key and
# completely (no failure since, and details for every chosen model)
xl_fresh() {
  [ ! -e "$(xl_error_file)" ] && xl_cache_current && [ -n "$(find "$(xl_cache_tsv)" -mmin "-$1" 2>/dev/null)" ] &&
    [ "$(xl_failsafe_count)" = 0 ]
}

# explabs_refresh [MAX_AGE_MIN] — PUBLIC HOOK: read the key's model list and the chosen models' details. With
# MAX_AGE_MIN, a list that is xl_fresh is kept without any network call; one that is not is read again (setup and
# Settings wait for it; ./stack up runs it in the background: explabs_up_hook). A model whose details could not be read
# keeps those read before with this key, or runs fail safe until a refresh works (warning; ./stack status says so); the
# key's list failing keeps the whole list read before with it. It never fails. When the chosen models or their details
# changed it re-renders litellm/config.yaml (when setup has rendered one) and sets XL_CHANGED=1: the caller then
# recreates LiteLLM and, with a portal session, runs explabs_sync_owui. In the background (XL_BACKGROUND=1) it renders
# nothing and leaves xl_pending_file for the next ./stack up instead. In the foreground it first stops a background
# refresh (whose result would come from the same or an older .env) and takes the refresh lock (_xl_lock);
# _explabs_refresh reads.
# shellcheck disable=SC2120  # MAX_AGE_MIN: lib/settings.sh passes it
explabs_refresh() {
  local rc=0
  XL_TMPS=''
  explabs_enabled || { rm -f "$(xl_error_file)"; XL_CHANGED=0; return 0; }
  if [ -n "${1:-}" ] && xl_fresh "$1"; then XL_CHANGED=0; return 0; fi
  xl_bg_stop
  _xl_lock 30 || warn "Experiential Labs: another refresh of the model list is still running — reading it anyway"
  _explabs_refresh "$@" || rc=$?
  _xl_unlock
  return "$rc"
}

# _explabs_refresh [MAX_AGE_MIN] — the refresh itself (explabs_refresh, or the background one: xl_refresh_in_background).
# The key and EXPLABS_MODELS it reads for are recorded at its start: what it writes is marked as read with that key, and
# is dropped (said) when either has changed in .env meanwhile — a slow read never stands for a newer key or choice.
_explabs_refresh() {
  local f tmp before m rc=0 key khash models
  XL_CHANGED=0; XL_ERR=''
  if ! explabs_enabled; then rm -f "$(xl_error_file)"; return 0; fi
  f="$(xl_cache_tsv)"; mkdir -p "$(dirname "$f")" "$STATE_DIR"
  if [ -n "${1:-}" ] && xl_fresh "$1"; then return 0; fi
  key="$(get_env EXPLABS_API_KEY)"; khash="$(xl_key_hash "$key")"; models="$(get_env EXPLABS_MODELS)"
  before="$(_xl_signature)"
  tmp="$(mktemp "$f.XXXXXX")" || return 0
  XL_TMPS="${XL_TMPS:-} $tmp"
  xl_fetch_models "$tmp" "$key" || rc=$?
  if [ "$(xl_key_hash "$(get_env EXPLABS_API_KEY)")" != "$khash" ] || [ "$(get_env EXPLABS_MODELS)" != "$models" ]; then
    rm -f "$tmp"
    log "Experiential Labs: the key or EXPLABS_MODELS changed while the model list was read — that read is dropped (the next one reads for the new ones)"
    return 0
  fi
  case "$rc" in
    0 | 2)
      chmod 644 "$tmp"; mv "$tmp" "$f"
      ( umask 077; printf '%s\n' "$khash" > "$(xl_key_mark)" )
      if [ "$rc" = 0 ]; then rm -f "$(xl_error_file)"; else _xl_record_error; fi
      xl_missing | while IFS= read -r m; do warn "Experiential Labs: '$m' (EXPLABS_MODELS) is not a model your key may call — left out"; done
      if [ "$rc" = 2 ]; then
        if [ "$(xl_failsafe_count)" = 0 ]; then warn "Experiential Labs: $XL_ERR — keeping the model details read before"
        else warn "Experiential Labs: $XL_ERR — until the details can be read its models are sent no sampling or penalty parameter (temperature, top_p, …), only tools and the max_tokens cap (./stack up or Settings tries again)"; fi
      fi ;;
    *)
      rm -f "$tmp"; _xl_record_error
      if xl_cache_current && xl_cache_has_details; then warn "Experiential Labs: $XL_ERR — keeping the model details read $(xl_fetched_at)"
      else warn "Experiential Labs: $XL_ERR — until the details can be read its models are sent no sampling or penalty parameter (temperature, top_p, …), only tools and the max_tokens cap (./stack up or Settings tries again)"; fi ;;
  esac
  [ "$before" != "$(_xl_signature)" ] || return 0
  XL_CHANGED=1
  if [ "${XL_BACKGROUND:-}" = 1 ]; then : > "$(xl_pending_file)"; return 0; fi
  [ ! -f "$STACK_DIR/litellm/config.yaml" ] || render_config "$(_enabled_or_all)"
}
_xl_record_error() { ( umask 077; printf '%s\t%s\n' "$(date +%s)" "$XL_ERR" > "$(xl_error_file)" ); }

# xl_counts -> "1 model (xl/qwen3.8-27b)" / "2 models" / "no model"
xl_counts() {
  xl_selected | awk -F'\t' '{ n++; if (n <= 3) l = l (n > 1 ? ", " : "") "xl/" $2 }
    END { if (!n) { print "no model"; exit } printf "%d model%s (%s%s)\n", n, (n == 1 ? "" : "s"), l, (n > 3 ? ", …" : "") }'
}
# xl_failsafe_count -> how many chosen models run fail safe now
xl_failsafe_count() { xl_selected | awk -F'\t' '$1 == "failsafe" { n++ } END { print n + 0 }'; }

# explabs_status_line — ./stack status: one line while Experiential Labs is on, saying when the models run fail safe
explabs_status_line() {
  local O_YEL O_OFF fs at why bg
  # shellcheck disable=SC2034  # set by out_colors; unused here
  local O_RED O_GRN
  explabs_enabled || return 0
  out_colors
  fs="$(xl_failsafe_count)"; at="$(xl_error_at)"; bg=''
  ! xl_bg_running || bg='; a refresh is under way in the background'
  if [ "$fs" -gt 0 ]; then
    # (no failure: the gateway's public catalog has no details for it — an organisation's own model, say)
    why="$(xl_error_text)"; [ -n "$why" ] || why="the gateway's public catalog has none for $([ "$fs" = 1 ] && echo it || echo them)"
    printf '%sExperiential Labs: %s — %s without model details (%s%s), so fail safe: none of %s is sent (tools and the max_tokens cap are); ./stack up or Settings tries again%s%s\n' \
      "$O_YEL" "$(xl_counts)" "$([ "$fs" = "$(xl_selected | grep -c .)" ] && echo all || echo "$fs")" "$why" \
      "${at:+, $(date -r "$at" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$at" '+%Y-%m-%d %H:%M' 2>/dev/null)}" \
      "$(printf '%s' "${XL_FAILSAFE_DROPS% max_completion_tokens}" | tr ' ' ',' | sed 's/,/, /g')" "$bg" "$O_OFF"
  elif [ -n "$at" ]; then
    why="$(xl_error_text)"
    printf '%sExperiential Labs: %s — the model details read before stay (the last refresh failed%s)%s%s\n' "$O_YEL" "$(xl_counts)" "${why:+: $why}" "$bg" "$O_OFF"
  elif [ -e "$(xl_pending_file)" ]; then
    # (read in the background, not yet in LiteLLM's config)
    printf 'Experiential Labs: %s — model details read %s; ./stack up applies them%s\n' "$(xl_counts)" "$(xl_fetched_at)" "$bg"
  else
    printf 'Experiential Labs: %s — model details read %s%s\n' "$(xl_counts)" "$(xl_fetched_at)" "$bg"
  fi
}

# explabs_summary_line — print_summary: one line while it is on
explabs_summary_line() {
  explabs_enabled || return 0
  printf '  Experiential Labs %s   (./stack status)\n' "$(xl_counts)"
}

# explabs_models_section — ./stack models: under the Bedrock table
explabs_models_section() {
  explabs_enabled || return 0
  printf '\nExperiential Labs: %s, EXPLABS_MODELS=%s\n' "$(xl_counts)" "$(get_env EXPLABS_MODELS)"
  printf '  ./stack config set EXPLABS_MODELS changes the set (exact gateway ids, comma-separated)\n'
}

# explabs_costs_section — ./stack costs: each chosen model's list price, and how its spend is booked
explabs_costs_section() {
  local id pin pout p
  printf '\nExperiential Labs'
  if ! explabs_enabled; then printf ': off — ./stack config set EXPLABS_API_KEY (or Settings › Chat & voice) adds a key\n'; return 0; fi
  printf ' (prompts go to api.experientiallabs.ai and the model provider; spend is what the gateway reports per call, in the keys above)\n'
  while IFS=$'\t' read -r id pin pout; do
    p="$(xl_price_text "${pin#-}" "${pout#-}")"; case "$p" in '$'*) p="list price $p" ;; esac
    printf '  %-36s %s\n' "xl/$id" "$p"
  done < <(xl_selected | awk -F'\t' -v OFS='\t' "$XL_AWK"'{ a = xl_shift($16, 15); b = xl_shift($17, 15); print $2, (a == "" ? "-" : a), (b == "" ? "-" : b) }')
  printf '  On your own provider key (BYOK) the provider bills you and the gateway charges $0: such calls count $0 here.\n'
}

# explabs_owui_models -> one line per chosen model for Open WebUI (TAB-separated: id, name, description, tags), like
# openrouter_owui_models (no logo: Open WebUI's own)
explabs_owui_models() {
  explabs_enabled || return 0
  xl_selected | awk -F'\t' "$XL_AWK"'
    function money(v,  s) { s = sprintf("%.4f", v); while (s ~ /\.[0-9][0-9][0-9]+$/ && s ~ /0$/) s = substr(s, 1, length(s) - 1); return "$" s }
    # (or_ctx_label: 128K, 1M)
    function ctxl(c,  v, u) {
      if (c !~ /^[0-9]+$/ || c + 0 == 0) return ""
      if (c >= 1000000) { v = (c % 1048576 == 0) ? c / 1048576 : c / 1000000; u = "M" } else { v = (c % 1024 == 0) ? c / 1024 : c / 1000; u = "K" }
      return (v == int(v) ? int(v) : sprintf("%.1f", v)) u " context"
    }
    { pin = xl_shift($16, 15); pout = xl_shift($17, 15)
      desc = "Experiential Labs · "
      if (pin == "" || pout == "") desc = desc "price unknown"
      else if (pin + 0 == 0 && pout + 0 == 0) desc = desc "free"
      else desc = desc money(pin * 1000000) " in / " money(pout * 1000000) " out per 1M tokens (list price; the gateway bills what each call cost)"
      if (ctxl($15) != "") desc = desc " · " ctxl($15)
      if ($1 == "failsafe") desc = desc " · no model details yet: no sampling parameters are sent"
      v = xl_vendor($2)
      printf "xl/%s\t%s · Experiential Labs\t%s\tExperiential Labs%s\n", $2, $2, desc, (v != "" ? "," v : "") }'
}

# explabs_cost_prices_entries -> ',"xl/<id>":{"name":"<id> (Experiential Labs)","input_cost_per_token":…,…,"gateway_cost":true}'
# for every chosen model with a list price, appended by cost_prices_json: Chat's cost line uses the cost the gateway
# reported for the answer (usage.cost; $0 on your own provider key) and these prices only without one
explabs_cost_prices_entries() {
  explabs_enabled || return 0
  xl_selected | awk -F'\t' "$XL_AWK"'
    { o = ""
      if (xl_shift($16, 15) != "") o = o ",\"input_cost_per_token\":" xl_shift($16, 15)
      if (xl_shift($17, 15) != "") o = o ",\"output_cost_per_token\":" xl_shift($17, 15)
      if (xl_shift($18, 15) != "") o = o ",\"cache_read_input_token_cost\":" xl_shift($18, 15)
      if (xl_shift($19, 15) != "") o = o ",\"cache_creation_input_token_cost\":" xl_shift($19, 15)
      printf ",\"xl/%s\":{\"name\":\"%s (Experiential Labs)\"%s,\"gateway_cost\":true}", $2, $2, o }'
}

# explabs_sync_owui — names ("<id> · Experiential Labs"), tags (Experiential Labs and the vendor) and price descriptions
# of the chosen models in Open WebUI's picker, with lib/openrouter.sh's comparison (OR_OWUI_SYNC_PY, given this
# provider's marker, id prefix, name suffix and tags): one GET, then imports for new or changed entries, and a delete
# per entry it created that is no longer offered (also after the key went). Needs a portal session. Never fatal.
explabs_sync_owui() {
  local tmp code plan line models n_imp=0 n_del=0 bad=0 unchanged=0 marker="$STATE_DIR/explabs-owui-synced"
  [ -n "$(get_env OPENWEBUI_API_KEY)" ] || return 0
  explabs_enabled || [ -e "$marker" ] || return 0
  tmp="$(mktemp)"
  code="$(_owui_get /api/v1/models/base "$tmp")"
  if [ "$code" != 200 ]; then
    rm -f "$tmp"; warn "Open WebUI: could not list models (HTTP $code) — Experiential Labs names/tags not updated; the next ./stack up retries"; return 0
  fi
  models="$(explabs_owui_models)"
  if ! plan="$({ [ -z "$models" ] || printf '%s\n' "$models"; printf '%s\n' '---icons---' '---existing---'; cat "$tmp"; } |
      _owui_py "$OR_OWUI_SYNC_PY" "" explabs xl/ " · Experiential Labs" "Experiential Labs" 2>/dev/null)"; then
    rm -f "$tmp"; warn "Open WebUI: could not compare the Experiential Labs models — names/tags not updated"; return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      "IMPORT "*)
        code="$(_owui_post /api/v1/models/import "${line#IMPORT }" "$tmp")"
        if [ "$code" = 200 ]; then n_imp=$((n_imp + $(printf '%s' "$line" | grep -o '"id": "xl/' | wc -l))); else bad=$((bad + 1)); fi ;;
      "DELETE "*)
        code="$(_owui_post /api/v1/models/model/delete "${line#DELETE }" "$tmp")"
        if [ "$code" = 200 ]; then n_del=$((n_del + 1)); else bad=$((bad + 1)); fi ;;
      "UNCHANGED "*) unchanged="${line#UNCHANGED }" ;;
    esac
  done <<< "$plan"
  rm -f "$tmp"
  if [ "$bad" -gt 0 ]; then
    warn "Open WebUI: $bad Experiential Labs model update(s) failed — the models still work; the next ./stack up retries"
  elif explabs_enabled; then
    mkdir -p "$STATE_DIR"; : > "$marker"
    log "Open WebUI: Experiential Labs models named and tagged ($n_imp updated, $unchanged unchanged, $n_del removed)"
  else
    rm -f "$marker"; [ "$n_del" -eq 0 ] || log "Open WebUI: removed $n_del Experiential Labs model entries"
  fi
}

# _xl_owui_refresh — inside a portal session: Open WebUI's names and tags, then the cost line's prices. Never fatal.
_xl_owui_refresh() {
  explabs_sync_owui || true
  ! declare -F owui_install_cost_filter >/dev/null || owui_install_cost_filter || true
}

# The paste-in lines for .env (new installs get them from .env.example; setup adds them to older ones).
XL_ENV_HINT='# Optional Experiential Labs gateway (README › Optional: Experiential Labs): ./stack config set EXPLABS_API_KEY asks for the key'

# xl_env_placeholder — setup: an .env without an EXPLABS_API_KEY line gets XL_ENV_HINT and empty EXPLABS_API_KEY= and
# EXPLABS_MODELS= lines. Any line already there stays exactly as it is.
xl_env_placeholder() {
  local tmp
  [ -f "$ENV_FILE" ] || return 0
  ! grep -Eq '^[[:space:]]*(export[[:space:]]+)?EXPLABS_API_KEY[[:space:]]*=' "$ENV_FILE" || return 0
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")" || return 0
  chmod 600 "$tmp"
  { cat "$ENV_FILE"; [ -z "$(tail -c 1 "$ENV_FILE")" ] || echo
    printf '%s\nEXPLABS_API_KEY=\n' "$XL_ENV_HINT"
    grep -q '^EXPLABS_MODELS=' "$ENV_FILE" || printf 'EXPLABS_MODELS=\n'; } > "$tmp" && mv "$tmp" "$ENV_FILE" && return 0
  rm -f "$tmp"
}

# setup_explabs — setup step: the paste-in lines, and with a key in .env the model list (setup renders the config after
# this). No question: the key comes from Settings or ./stack config set EXPLABS_API_KEY. Never fatal.
setup_explabs() {
  xl_env_placeholder
  xl_key_problem
  explabs_enabled || return 0
  explabs_refresh
  log "Experiential Labs: $(xl_counts)"
}

# xl_bg_running -> 0 while ./stack up's refresh runs in the background (its pid file names a live process, written
# within the last 10 minutes: a stale file never blocks the next one)
xl_bg_running() {
  local f; f="$(xl_bg_pid_file)"
  [ -n "$(find "$f" -mmin -10 2>/dev/null)" ] && kill -0 "$(head -c 12 "$f" | tr -cd '0-9')" 2>/dev/null
}

# One refresh at a time: a lock folder under .state holding its process's pid. _xl_lock WAIT_S [PID] -> 0 when it is
# taken for PID (default this process; a lock whose process is gone is taken over), 1 when another live one still holds
# it after WAIT_S seconds. _xl_unlock — let it go.
xl_lock_dir() { printf '%s\n' "$STATE_DIR/explabs-refresh.lock"; }
_xl_lock() {
  local d n=0 p; d="$(xl_lock_dir)"; mkdir -p "$STATE_DIR"
  while ! mkdir "$d" 2>/dev/null; do
    p="$(head -c 12 "$d/pid" 2>/dev/null | tr -cd '0-9')" || p=""
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$d"; continue; fi   # (its process is gone)
    if [ "$n" -ge "$(($1 * 4))" ]; then
      [ -z "$p" ] || return 1
      rm -rf "$d"; continue   # (no pid in it after the wait: left half-made)
    fi
    n=$((n + 1)); sleep 0.25
  done
  printf '%s\n' "${2:-$$}" > "$d/pid"
}
_xl_unlock() { rm -rf "$(xl_lock_dir)"; }

# _xl_kill_tree PID — PID and every process under it, by their pids (TERM): a background refresh and its curls
_xl_kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _xl_kill_tree "$c"; done
  kill -TERM "$1" 2>/dev/null || true
}

# xl_bg_stop — PUBLIC HOOK: stops ./stack up's background refresh if one runs (by its recorded pid: what it read so far
# goes, its temp files with it), and its lock. (A foreground refresh, ./stack down, update, restore, uninstall.)
xl_bg_stop() {
  local f p n=0; f="$(xl_bg_pid_file)"
  p="$(head -c 12 "$f" 2>/dev/null | tr -cd '0-9')" || p=""
  [ -n "$p" ] || return 0
  if kill -0 "$p" 2>/dev/null; then
    _xl_kill_tree "$p"
    while kill -0 "$p" 2>/dev/null && [ "$n" -lt 40 ]; do n=$((n + 1)); sleep 0.25; done
    log "Experiential Labs: stopped the background read of the model details"
  fi
  rm -f "$f"
  [ "$(head -c 12 "$(xl_lock_dir)/pid" 2>/dev/null | tr -cd '0-9')" != "$p" ] || _xl_unlock
}

# xl_refresh_in_background — _explabs_refresh on its own, so ./stack up never waits on the gateway's catalog (one
# model's details took 15-25 s on 2026-10-25): what it reads is used from the next ./stack up or Settings change.
# One at a time (the refresh lock, taken for it here); its output goes to xl_bg_log; stopped, it removes its temp files.
xl_refresh_in_background() {
  local pidf p; pidf="$(xl_bg_pid_file)"
  if xl_bg_running || ! _xl_lock 0 "$$"; then log "Experiential Labs: the model details are being read already"; return 0; fi
  (
    trap '' HUP
    # (stopped: its temp files, its lock and its pid file go)
    trap 'rm -rf ${XL_TMPS:-}; _xl_unlock; rm -f "$(xl_bg_pid_file)"; exit 143' TERM INT
    XL_TMPS=''
    XL_BACKGROUND=1 _explabs_refresh > "$(xl_bg_log)" 2>&1 || true
    _xl_unlock; rm -f "$(xl_bg_pid_file)"
  ) < /dev/null > /dev/null 2>&1 &
  p=$!
  printf '%s\n' "$p" > "$pidf"; printf '%s\n' "$p" > "$(xl_lock_dir)/pid"
  log "Experiential Labs: reading the model details in the background (the ones read $(xl_fetched_at) stay until it is done)"
}

# xl_config_matches -> 0 when litellm/config.yaml holds exactly the xl/ models EXPLABS_MODELS picks now
xl_config_matches() {
  local cfg="$STACK_DIR/litellm/config.yaml"
  [ ! -f "$cfg" ] && return 0
  [ "$(sed -n 's/^  - model_name: "\(xl\/[^"]*\)"$/\1/p' "$cfg" | sort)" = "$(xl_selected | awk -F'\t' '{ print "xl/" $2 }' | sort)" ]
}

# explabs_up_hook — ./stack up, before `compose up`. With no list read with this key yet, it reads one and waits (each
# request bounded: XL_LIST_TIMEOUT, XL_MODEL_TIMEOUT). With one, it never waits on the network: it renders what a
# background refresh brought since the last up (xl_pending_file) or a change of EXPLABS_MODELS made by hand in .env (a
# new model fail safe until its details come), and starts a background refresh when the list is not xl_fresh for 12 h.
# With no key, a config that still holds xl/ models (the key was removed by hand) is rendered again. A running LiteLLM
# whose models changed is recreated (the `compose up --wait` that follows waits for it). Remembers the change for
# explabs_after_up.
explabs_up_hook() {
  XL_UP_CHANGED=0; XL_CHANGED=0
  if explabs_enabled; then
    if ! xl_cache_current; then
      explabs_refresh
    else
      if [ -e "$(xl_pending_file)" ] || ! xl_config_matches; then
        rm -f "$(xl_pending_file)"; XL_CHANGED=1
        [ ! -f "$STACK_DIR/litellm/config.yaml" ] || render_config "$(_enabled_or_all)"
      fi
      xl_fresh 720 || xl_refresh_in_background
    fi
  elif grep -q '^  - model_name: "xl/' "$STACK_DIR/litellm/config.yaml" 2>/dev/null; then
    render_config "$(_enabled_or_all)"; XL_CHANGED=1
  else
    return 0
  fi
  [ "$XL_CHANGED" = 1 ] || return 0
  XL_UP_CHANGED=1
  [ -z "$(dc ps -q litellm 2>/dev/null)" ] || dc up -d --no-deps --force-recreate litellm >/dev/null 2>&1 || warn "could not restart LiteLLM with the new Experiential Labs models"
}

# explabs_after_up — ./stack up, inside its portal session: Open WebUI's names, tags and prices when the hook saw changes
explabs_after_up() { [ "${XL_UP_CHANGED:-0}" != 1 ] || _xl_owui_refresh; }
