# shellcheck shell=bash
# Optional Experiential Labs gateway (https://experientiallabs.ai): one OpenAI-compatible API in front of many models,
# paid from the gateway's credits or by your own provider keys connected there (BYOK). Off unless .env holds
# EXPLABS_API_KEY: without one nothing here talks to the network and no xl/… model is rendered. Only .env counts (dc()
# strips EXPLABS_* from the shell's environment).
#
# Data flow, two requests joined by model id:
#   GET https://api.experientiallabs.ai/v1/models WITH the key (curl -K -: never on a command line, in a URL or a log):
#     the ids this key may call — the OpenAI list, nothing else (id, object, created, owned_by);
#   GET https://api.experientiallabs.ai/api/models WITHOUT it (the public catalog, keyless; paged with limit/offset):
#     each model's details — what it takes (supports_temperature, supports_top_p, supports_tools,
#     chat_max_tokens_field, …) — and its list price.
# → litellm/explabs-models.tsv: every model of the key's list, with its catalog details when the catalog has them (an
# entry of the catalog the key may not call is not kept; one of the key's models the catalog lacks — an organisation's
# own model — has none: fail safe) → EXPLABS_MODELS (a comma list of exact gateway ids; blank = qwen3.8-27b) picks the
# ones rendered into
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
#   explabs_refresh [MAX_AGE_MIN]   read the model list (setup, Settings; ./stack up with 720 = 12 h); sets XL_CHANGED
#   explabs_yaml                    LiteLLM model_list entries (render_litellm_config)
#   explabs_write_portal_json       litellm/explabs-models.json for the portal (render_config)
#   explabs_code_rows               the Code page's and claude-bedrock's rows (lib/code_models.sh)
#   explabs_sync_owui               Open WebUI names and tags (needs a portal session)
#   explabs_cost_prices_entries     Chat's cost line (lib/owui.sh cost_prices_json)
#   explabs_status_line / explabs_summary_line / explabs_costs_section / explabs_models_section
#   setup_explabs / explabs_up_hook / explabs_after_up   setup, and ./stack up before `compose up` / in its portal session

# Where the key goes. Only the test suite (BEDROCK_NOW_TESTING=1, as lib/host.sh) can point this at another server: a
# stray variable in a user's shell never changes it. The catalog lives beside it.
_xl_api() {
  if [ "${BEDROCK_NOW_TESTING:-}" = 1 ] && [ -n "${BEDROCK_NOW_TEST_EXPLABS_API:-}" ]; then printf '%s\n' "$BEDROCK_NOW_TEST_EXPLABS_API"
  else printf 'https://api.experientiallabs.ai/v1\n'; fi
}
EXPLABS_API="$(_xl_api)"
# xl_api_ok -> 0 when EXPLABS_API may get the key: https, or any address while testing
xl_api_ok() { case "$EXPLABS_API" in https://?*) return 0 ;; esac; [ "${BEDROCK_NOW_TESTING:-}" = 1 ]; }
EXPLABS_CATALOG="${EXPLABS_API%/v1}/api/models"
XL_CATALOG_PAGE=500     # entries asked for per catalog page (the gateway may send fewer: the next page starts after them)
XL_CATALOG_PAGES=20     # at most this many pages (10,000 models; the gateway lists ~320)
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

# xl_details_tsv < GET /api/models JSON (the catalog; its entries under "data", "models" or "items", or a bare list)
# -> one TAB-separated line per model: id temperature top_p top_k frequency_penalty presence_penalty logprobs tools
# structured_output reasoning sampling_requires_reasoning_none max_tokens_field max_out context in out cache_read
# cache_write — the supports_* fields as 1 (true), 0 (false) or empty (null, or not listed), the field as max_tokens |
# max_completion_tokens | empty, the counts and the list prices (nano-USD per million tokens, from "pricing") as whole
# numbers or empty. Ids that are not valid_xl_id are left out.
xl_details_tsv() {
  or_json_flatten | awk -F'\t' -v OFS='\t' '
    function b(v) { return v == "true" ? 1 : (v == "false" ? 0 : "") }
    function w(v) { return (v ~ /^[0-9]+$/ && length(v) <= 18) ? v : "" }
    $1 ~ /^(data\.|models\.|items\.)?[0-9]+\./ {
      pre = ""; if (match($1, /^(data|models|items)\./)) { pre = substr($1, 1, RLENGTH) }
      rest = substr($1, length(pre) + 1); k = rest; sub(/\..*/, "", k); i = k; if (!(i in seen)) { seen[i] = 1; ord[++n] = i }
      f = substr(rest, length(k) + 2)
      if (f == "id") id[i] = $2
      else if (f == "supports_temperature") te[i] = b($2)
      else if (f == "supports_top_p") tp[i] = b($2)
      else if (f == "supports_top_k") tk[i] = b($2)
      else if (f == "supports_frequency_penalty") fq[i] = b($2)
      else if (f == "supports_presence_penalty") pp[i] = b($2)
      else if (f == "supports_logprobs") lp[i] = b($2)
      else if (f == "supports_tools") tl[i] = b($2)
      else if (f == "supports_structured_output") so[i] = b($2)
      else if (f == "supports_reasoning") rs[i] = b($2)
      else if (f == "sampling_requires_reasoning_none") sn[i] = b($2)
      else if (f == "chat_max_tokens_field") mf[i] = ($2 == "max_tokens" || $2 == "max_completion_tokens") ? $2 : ""
      else if (f == "maximum_output_tokens") mo[i] = w($2)
      else if (f == "context_window_tokens") cx[i] = w($2)
      else if (f == "pricing.input_nano_usd_per_million_tokens") pi[i] = w($2)
      else if (f == "pricing.output_nano_usd_per_million_tokens") po[i] = w($2)
      else if (f == "pricing.cached_input_nano_usd_per_million_tokens") pr[i] = w($2)
      else if (f == "pricing.cache_creation_input_nano_usd_per_million_tokens") pw[i] = w($2)
    }
    # (only the indices it holds, in their order: a hostile "data.999999999" costs one entry, not a billion steps)
    END { for (j = 1; j <= n; j++) { i = ord[j]; if (id[i] ~ /^[A-Za-z0-9][A-Za-z0-9._:-]*$/ && length(id[i]) <= 128 && !(id[i] in done)) {
      done[id[i]] = 1
      print id[i], te[i], tp[i], tk[i], fq[i], pp[i], lp[i], tl[i], so[i], rs[i], sn[i], mf[i], mo[i], cx[i], pi[i], po[i], pr[i], pw[i] } } }'
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
# xl_join IDS_FILE < xl_details_tsv rows -> one row per id of IDS_FILE (the key's list, in its order): its details row,
# or the id alone when the catalog has none (fail safe). A catalog entry the key's list lacks is not kept.
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

# xl_selected -> one line per model EXPLABS_MODELS picks: STATE then the xl_details_tsv fields. STATE = details (the
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

# xl_fetch_ids OUT KEY -> 0 if OUT now holds the ids the key may call (GET /v1/models with KEY on curl's stdin, the
# answer to a temp file of our own); otherwise XL_ERR says why
xl_fetch_ids() {
  local out="$1" raw code
  XL_ERR=''
  raw="$(mktemp)"
  code="$(curl_auth "$2" --proto '=https' -sS --connect-timeout 10 -m 60 --max-filesize 20000000 -o "$raw" -w '%{http_code}' "$EXPLABS_API/models" 2>/dev/null)" || code=000
  case "$code" in
    200) ;;
    401 | 403) XL_ERR="the gateway rejected the key (HTTP $code) — a new one: $EXPLABS_KEYS_URL" ;;
    000 | '') XL_ERR="could not reach api.experientiallabs.ai" ;;
    *) XL_ERR="api.experientiallabs.ai answered HTTP $code when listing models" ;;
  esac
  if [ -z "$XL_ERR" ]; then
    xl_ids < "$raw" > "$out" || : > "$out"
    if [ ! -s "$out" ] && ! grep -q '"data"[[:space:]]*:[[:space:]]*\[' "$raw"; then XL_ERR="api.experientiallabs.ai sent no model list"; fi
  fi
  rm -f "$raw"
  [ -z "$XL_ERR" ]
}

# xl_fetch_details OUT -> 0 if OUT now holds the catalog's details rows (GET /api/models, keyless: no key and nothing
# about you is sent; page after page — limit/offset — until one adds no model, at most XL_CATALOG_PAGES); otherwise
# XL_ERR says why
xl_fetch_details() {
  local out="$1" raw page code off=0 n=0 before
  XL_ERR=''
  raw="$(mktemp)"; page="$(mktemp)"; : > "$out"
  while [ "$n" -lt "$XL_CATALOG_PAGES" ]; do
    n=$((n + 1))
    code="$(curl --proto '=https' -sS --connect-timeout 10 -m 60 --max-filesize 20000000 -o "$raw" -w '%{http_code}' "$EXPLABS_CATALOG?limit=$XL_CATALOG_PAGE&offset=$off" 2>/dev/null)" || code=000
    case "$code" in
      200) ;;
      000 | '') XL_ERR="could not read the model details from api.experientiallabs.ai/api/models"; break ;;
      *) XL_ERR="api.experientiallabs.ai/api/models answered HTTP $code"; break ;;
    esac
    xl_details_tsv < "$raw" > "$page" || : > "$page"
    before="$(wc -l < "$out" | tr -d ' ')"
    # (a gateway that ignores offset sends the same page again: nothing new, the end)
    cut -f1 "$out" | awk -F'\t' 'FILENAME == ARGV[1] { have[$1] = 1; next } !($1 in have)' - "$page" >> "$out"
    [ "$(wc -l < "$out" | tr -d ' ')" -gt "$before" ] || break
    off=$((off + $(wc -l < "$page" | tr -d ' ')))
  done
  rm -f "$raw" "$page"
  if [ -z "$XL_ERR" ] && [ ! -s "$out" ]; then XL_ERR="api.experientiallabs.ai/api/models sent no model details"; fi
  [ -z "$XL_ERR" ]
}

# xl_fetch_models OUT KEY -> the cached list in OUT (with a fetched_at header): 0 with the key's ids and the catalog's
# details; 2 with the ids alone — the catalog could not be read (XL_ERR says why), every model fail safe; 1 when the
# key's list could not be read (XL_ERR; OUT untouched)
xl_fetch_models() {
  local out="$1" ids det rc=0
  ids="$(mktemp)"; det="$(mktemp)"
  if ! xl_fetch_ids "$ids" "$2"; then rm -f "$ids" "$det"; return 1; fi
  xl_fetch_details "$det" || rc=2
  { printf '# fetched_at: %s\n# source: %s/models (the ids, as listed for your key) and %s (their details)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EXPLABS_API" "$EXPLABS_CATALOG"
    printf '# id\ttemperature\ttop_p\ttop_k\tfrequency_penalty\tpresence_penalty\tlogprobs\ttools\tstructured_output\treasoning\tsampling_requires_reasoning_none\tmax_tokens_field\tmax_out\tcontext\tin\tout\tcache_read\tcache_write\n'
    xl_join "$ids" < "$det"; } > "$out"
  rm -f "$ids" "$det"
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

# explabs_refresh [MAX_AGE_MIN] — PUBLIC HOOK: read the key's model list and the catalog's details. With MAX_AGE_MIN, a
# list younger than that, read with this key and completely (no failure since, and details for every chosen model), is
# kept without any network call (./stack up: 720); one that is not is read again at the next ./stack up or Settings
# change. A failure keeps a list read with this key with its details (warning), or leaves the models fail
# safe until a refresh works (warning; ./stack status says so); it never fails. The catalog alone failing still takes
# the key's new list of ids, fail safe, unless details read before for this key can stay. When the chosen models or
# their details changed it re-renders litellm/config.yaml (when setup has rendered one) and sets XL_CHANGED=1: the
# caller then recreates LiteLLM and, with a portal session, runs explabs_sync_owui.
explabs_refresh() {
  local f tmp before m rc=0
  XL_CHANGED=0; XL_ERR=''
  if ! explabs_enabled; then rm -f "$(xl_error_file)"; return 0; fi
  f="$(xl_cache_tsv)"; mkdir -p "$(dirname "$f")" "$STATE_DIR"
  if [ -n "${1:-}" ] && [ ! -e "$(xl_error_file)" ] && xl_cache_current && [ -n "$(find "$f" -mmin "-$1" 2>/dev/null)" ] &&
    [ "$(xl_failsafe_count)" = 0 ]; then return 0; fi
  before="$(_xl_signature)"
  tmp="$(mktemp "$f.XXXXXX")" || return 0
  xl_fetch_models "$tmp" "$(get_env EXPLABS_API_KEY)" || rc=$?
  if [ "$rc" = 2 ] && xl_cache_current && xl_cache_has_details; then rc=3; fi   # (details read before stay)
  case "$rc" in
    0 | 2)
      chmod 644 "$tmp"; mv "$tmp" "$f"
      ( umask 077; xl_key_hash "$(get_env EXPLABS_API_KEY)" > "$(xl_key_mark)" )
      if [ "$rc" = 0 ]; then rm -f "$(xl_error_file)"; else _xl_record_error; fi
      xl_missing | while IFS= read -r m; do warn "Experiential Labs: '$m' (EXPLABS_MODELS) is not a model your key may call — left out"; done
      [ "$rc" = 0 ] || warn "Experiential Labs: $XL_ERR — until the details can be read its models are sent no sampling or penalty parameter (temperature, top_p, …), only tools and the max_tokens cap (./stack up or Settings tries again)" ;;
    *)
      rm -f "$tmp"; _xl_record_error
      if xl_cache_current && xl_cache_has_details; then warn "Experiential Labs: $XL_ERR — keeping the model details read $(xl_fetched_at)"
      else warn "Experiential Labs: $XL_ERR — until the details can be read its models are sent no sampling or penalty parameter (temperature, top_p, …), only tools and the max_tokens cap (./stack up or Settings tries again)"; fi ;;
  esac
  [ "$before" != "$(_xl_signature)" ] || return 0
  XL_CHANGED=1
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
  local O_YEL O_OFF fs at why
  # shellcheck disable=SC2034  # set by out_colors; unused here
  local O_RED O_GRN
  explabs_enabled || return 0
  out_colors
  fs="$(xl_failsafe_count)"; at="$(xl_error_at)"
  if [ "$fs" -gt 0 ]; then
    # (no failure: the gateway's public catalog has no details for it — an organisation's own model, say)
    why="$(xl_error_text)"; [ -n "$why" ] || why="the gateway's public catalog has none for $([ "$fs" = 1 ] && echo it || echo them)"
    printf '%sExperiential Labs: %s — %s without model details (%s%s), so fail safe: none of %s is sent (tools and the max_tokens cap are); ./stack up or Settings tries again%s\n' \
      "$O_YEL" "$(xl_counts)" "$([ "$fs" = "$(xl_selected | grep -c .)" ] && echo all || echo "$fs")" "$why" \
      "${at:+, $(date -r "$at" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$at" '+%Y-%m-%d %H:%M' 2>/dev/null)}" \
      "$(printf '%s' "${XL_FAILSAFE_DROPS% max_completion_tokens}" | tr ' ' ',' | sed 's/,/, /g')" "$O_OFF"
  elif [ -n "$at" ]; then
    why="$(xl_error_text)"
    printf '%sExperiential Labs: %s — model details read %s (the last refresh failed%s)%s\n' "$O_YEL" "$(xl_counts)" "$(xl_fetched_at)" "${why:+: $why}" "$O_OFF"
  else
    printf 'Experiential Labs: %s — model details read %s\n' "$(xl_counts)" "$(xl_fetched_at)"
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

# explabs_up_hook — ./stack up, before `compose up`: read the list unless one younger than 12 h was read completely with
# this key (explabs_refresh); with no key, a config that still holds xl/ models (the key was removed by hand) is
# rendered again. A running LiteLLM whose models changed is recreated (the `compose up --wait` that follows waits for
# it). Remembers the change for explabs_after_up.
explabs_up_hook() {
  XL_UP_CHANGED=0
  if explabs_enabled; then
    explabs_refresh 720
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
