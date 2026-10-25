# shellcheck shell=bash
# Optional Experiential Labs gateway (lib/explabs.sh): the model list and its details, the allow-list, what each model
# is sent (the parameters its details let through, fail safe without them), LiteLLM's config, the Code page's and
# Chat's rows, the status lines — and the key, which never shows up anywhere but .env and curl's stdin.
# The gateway answers in two places, and the fixtures are split the same way:
#   tests/fixtures/explabs_v1_models.json  GET /v1/models with the key: the OpenAI list, ids only (id, object, created,
#                                          owned_by) — the real answer's shape, trimmed to seven ids;
#   tests/fixtures/explabs_catalog.json    GET /api/models (keyless): the same seven with their details and prices,
#                                          public catalog fields only.
# Keys are made here, at run time: never a key-like literal in the repository.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/explabs.sh
. "$STACK_DIR/lib/owui.sh"
FIX_V1="$STACK_DIR/tests/fixtures/explabs_v1_models.json"
FIX_CAT="$STACK_DIR/tests/fixtures/explabs_catalog.json"
XL_KEY="xpl_$(printf '%040d' 0 | tr 0 a)"
XL_KEY2="xpl_$(printf '%040d' 0 | tr 0 b)"

# A checkout in $TMP with KEY (default XL_KEY) in .env, plus any more lines.
_xl_env() {
  STACK_DIR="$TMP"; mkdir -p "$TMP/litellm" "$STATE_DIR"
  printf 'EXPLABS_API_KEY=%s\n%s' "${XL_KEY_USE:-$XL_KEY}" "${1:-}" > "$ENV_FILE"
}
# _xl_list CATALOG_JSON V1_JSON -> the cached list as a refresh writes it: the key's ids joined with the catalog's details
_xl_list() {
  xl_ids < "$2" > "$TMP/ids"
  { printf '# fetched_at: 2026-10-24T00:00:00Z\n'; xl_details_tsv < "$1" | xl_join "$TMP/ids"; } > "$TMP/litellm/explabs-models.tsv"
  xl_key_hash "${XL_KEY_USE:-$XL_KEY}" > "$(xl_key_mark)"
}
# ... and the fixtures' list cached as read with that key.
_xl_cached() { _xl_env "${1:-}"; _xl_list "$FIX_CAT" "$FIX_V1"; }

# curl stub, by address: GET …/v1/models (the key on stdin, curl -K -, which goes to $TMP/stdin) answers MODELS_CODE
# (default 200) with V1_BODY (default the fixture); GET …/api/models (keyless) answers CATALOG_CODE with CATALOG_BODY, or
# for offset=N CATALOG_BODY_N when that is set (the next page). Each call's arguments are logged (never the key), with
# "keyed" or "keyless"; CURL_FAIL=1: no answer at all.
_stub_curl() {
  curl() {
    local a prev='' out='' w='' url='' keyed='' code body
    for a in "$@"; do [ "$prev" = -o ] && out="$a"; [ "$prev" = -w ] && w=1; [ "$prev$a" = "-K-" ] && keyed=1; prev="$a"; case "$a" in http*) url="$a" ;; esac; done
    echo "curl $([ -n "$keyed" ] && echo keyed || echo keyless) $*" >> "$TMP/calls"
    [ -z "$keyed" ] || cat >> "$TMP/stdin"
    if [ -n "${CURL_FAIL:-}" ]; then [ -z "$w" ] || printf 000; return 7; fi
    case "$url" in
      */api/models*)
        code="${CATALOG_CODE:-200}"; body="${CATALOG_BODY:-$FIX_CAT}"
        case "$url" in *offset=0) ;; *offset=*) local n="${url##*offset=}" v; v="CATALOG_BODY_$n"; body="${!v:-$body}" ;; esac ;;
      *) code="${MODELS_CODE:-200}"; body="${V1_BODY:-$FIX_V1}" ;;
    esac
    if [ "$code" = 200 ]; then cp "$body" "$out"; else printf '{"error":{"code":"x"}}' > "$out"; fi
    [ -z "$w" ] || printf '%s' "$code"
  }
}

# _assert_no_key TEXT... — not a trace of either key (nor its 40 hex digits) in TEXT
_assert_no_key() {
  local t
  for t in "$@"; do
    assert_not_contains "$t" "$XL_KEY"; assert_not_contains "$t" "$XL_KEY2"
    assert_not_contains "$t" "$(printf '%040d' 0 | tr 0 a)"; assert_not_contains "$t" "aaaaaaaaaaaa"
  done
}

test_the_catalog_gives_each_models_details_and_list_price() {
  local out
  out="$(xl_details_tsv < "$FIX_CAT")"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 7
  # id temperature top_p top_k frequency presence logprobs tools structured reasoning sampling-needs-no-reasoning field
  # max_out context in out cache_read cache_write (nano-USD per million tokens)
  assert_contains "$out" "$(printf 'qwen3.8-27b\t1\t1\t1\t\t\t0\t1\t0\t1\t0\tmax_completion_tokens\t131072\t1000000\t320000000\t2400000000\t40000000\t')"
  assert_contains "$out" "$(printf 'gpt-5.1-codex\t0\t0\t0\t\t\t0\t1\t1\t1\t1\tmax_tokens\t')"
  assert_contains "$out" "$(printf 'claude-fable-5\t1\t1\t1\t\t\t0\t1\t0\t0\t0\t\t128000\t')"
  # a model the catalog names without any details: its id only
  assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "gpt-latest"' | tr -d '\t')" gpt-latest
  # an id we could not write into YAML or JSON as it is never gets through; entries under "models", "items" or in a
  # bare list are read the same
  out="$(printf '{"data":[{"id":"ok-1","supports_tools":true},{"id":"bad id\\"x"},{"id":"-dash"},{"id":"a/b"},{"id":"ok-1"}]}' | xl_details_tsv | cut -f1)"
  assert_eq "$out" ok-1
  for j in '{"models":[{"id":"m-1","supports_tools":false}]}' '{"items":[{"id":"m-1","supports_tools":false}]}' '[{"id":"m-1","supports_tools":false}]'; do
    assert_eq "$(printf '%s' "$j" | xl_details_tsv | cut -f1,8)" "$(printf 'm-1\t0')"
  done
}

# /v1/models is the key's list of ids, never details: the real answer carries id, object, created and owned_by only,
# and even an answer that carried more is read for its ids alone
test_the_keys_list_is_read_for_its_ids_and_nothing_else() {
  assert_eq "$(xl_ids < "$FIX_V1" | tr '\n' ' ')" "chatgpt-image-latest claude-fable-5 deepseek-v4.1-flash gpt-5-mini gpt-5.1-codex gpt-latest qwen3.8-27b "
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))["data"]
assert all(set(m) == {"id", "object", "created", "owned_by"} for m in d), "the fixture is not the real shape"' "$FIX_V1"
  # the catalog's answer handed in as /v1/models: ids, nothing else
  assert_eq "$(xl_ids < "$FIX_CAT" | wc -l | tr -d ' ')" 7
  assert_eq "$(printf '{"data":[{"id":"ok-1"},{"id":"bad id"},{"id":"ok-1"},{"id":"a/b"}]}' | xl_ids)" ok-1
  # a details-bearing answer at /v1/models and no catalog: every model fail safe — nothing of /v1/models becomes details
  _stub_curl; _xl_env 'EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini
'
  V1_BODY="$FIX_CAT" CATALOG_CODE=503 explabs_refresh 2>/dev/null
  assert_eq "$(xl_selected | cut -f1 | tr '\n' ' ')" "failsafe failsafe "
  assert_eq "$(xl_cached_rows | awk -F'\t' '{ for (i = 2; i <= NF; i++) printf "%s", $i }')" ""   # ids alone
}

# The join: the key's ids decide what is offered, the catalog what each takes. A catalog entry the key may not call is
# not offered; one of the key's models the catalog lacks (an organisation's own) runs fail safe, and ./stack status says
# why although nothing failed
test_the_keys_ids_joined_with_the_catalog() {
  python3 -I -c 'import json, sys
v = json.load(open(sys.argv[1])); v["data"].append({"id": "our-own-model", "object": "model", "created": 0, "owned_by": "org"})
c = json.load(open(sys.argv[2])); c["data"].append({**c["data"][0], "id": "not-for-this-key"})
json.dump(v, open(sys.argv[3], "w")); json.dump(c, open(sys.argv[4], "w"))' "$FIX_V1" "$FIX_CAT" "$TMP/v1.json" "$TMP/cat.json"
  _stub_curl
  _xl_env 'EXPLABS_MODELS=qwen3.8-27b,our-own-model,not-for-this-key
'
  V1_BODY="$TMP/v1.json" CATALOG_BODY="$TMP/cat.json" explabs_refresh 2> "$TMP/err"
  assert_eq "$(xl_selected | cut -f1,2 | tr '\t\n' ': ')" "details:qwen3.8-27b failsafe:our-own-model "
  assert_contains "$(cat "$TMP/err")" "'not-for-this-key' (EXPLABS_MODELS) is not a model your key may call — left out"
  assert_eq "$(xl_cached_rows | cut -f1 | grep -c .)" 8                        # the key's 7 + its own; never not-for-this-key
  [ ! -e "$(xl_error_file)" ]
  assert_contains "$(explabs_status_line)" "1 without model details (the gateway's public catalog has none for it), so fail safe"
}

test_only_what_each_model_takes_is_sent() {
  local y
  _xl_cached 'EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini,gpt-5.1-codex,claude-fable-5,chatgpt-image-latest
'
  y="$(explabs_yaml)"
  # qwen3.8-27b takes sampling and tools; no penalties (unknown), no logprobs or structured output; its cap is
  # max_completion_tokens, so max_tokens is left out (the hook renames a max_tokens it gets)
  assert_contains "$y" "$(printf '  - model_name: "xl/qwen3.8-27b"\n    litellm_params:\n      model: "openai/qwen3.8-27b"\n      api_base: "https://api.experientiallabs.ai/v1"\n      api_key: os.environ/EXPLABS_API_KEY\n      drop_params: true\n      additional_drop_params: ["frequency_penalty", "presence_penalty", "logprobs", "top_logprobs", "response_format", "max_tokens"]')"
  assert_contains "$y" "$(printf '      bn_xl: true\n      bn_xl_max_tokens: "max_completion_tokens"')"
  # gpt-5-mini refuses sampling (temperature, top_p, top_k)
  assert_contains "$y" 'additional_drop_params: ["temperature", "top_p", "top_k", "frequency_penalty", "presence_penalty", "logprobs", "top_logprobs", "max_tokens"]'
  # gpt-5.1-codex takes sampling only with reasoning off: none of it; its cap is max_tokens
  assert_contains "$y" 'additional_drop_params: ["temperature", "top_p", "top_k", "frequency_penalty", "presence_penalty", "logprobs", "top_logprobs", "max_completion_tokens"]'
  # claude-fable-5 names no cap field: the cap goes as max_tokens (never dropped: it is a spend safety); no reasoning effort
  assert_contains "$y" "$(printf '      additional_drop_params: ["frequency_penalty", "presence_penalty", "logprobs", "top_logprobs", "response_format", "reasoning_effort", "max_completion_tokens"]')"
  assert_contains "$(printf '%s\n' "$y" | grep -A 16 '"xl/claude-fable-5"$')" 'bn_xl_max_tokens: "max_tokens"'
  # tools unknown in its details (chatgpt-image-latest: supports_tools null): the tools go, as fail safe
  assert_not_contains "$(printf '%s\n' "$y" | grep -A 7 '"xl/chatgpt-image-latest"')" '"tools"'
  # no model is ever sent without a cap field to take one: max_tokens or max_completion_tokens is always left in
  assert_eq "$(printf '%s\n' "$y" | grep additional_drop_params | grep -c '"max_tokens".*"max_completion_tokens"\|"max_completion_tokens".*"max_tokens"')" 0
  # the list price, per token, exact (only a reply without usage.cost is priced with it)
  assert_contains "$y" "$(printf '      input_cost_per_token: 0.00000032\n      output_cost_per_token: 0.0000024\n      cache_read_input_token_cost: 0.00000004\n')"
  _assert_no_key "$y"
}

# Fail safe: the sampling, penalty and logprob parameters, response_format and reasoning_effort never go; tools and the
# cap (as max_tokens) do — a model that cannot take them answers with a clear 400, never a silent chat-only Claude Code
test_without_details_sampling_goes_and_tools_and_the_cap_stay() {
  local y all
  all='["temperature", "top_p", "top_k", "frequency_penalty", "presence_penalty", "logprobs", "top_logprobs", "response_format", "reasoning_effort", "max_completion_tokens"]'
  # no list at all (it could not be read): the default model, fail safe
  _xl_env
  y="$(explabs_yaml)"
  assert_contains "$y" "$(printf '  - model_name: "xl/qwen3.8-27b"')"
  assert_contains "$y" "additional_drop_params: $all"
  assert_contains "$y" 'bn_xl_max_tokens: "max_tokens"'
  assert_not_contains "$y" '"tools"'; assert_not_contains "$y" '"max_tokens",'
  assert_eq "$(xl_selected | cut -f1)" failsafe
  # the awk rule and XL_FAILSAFE_DROPS (the status line's list) are one list
  assert_eq "$all" "[$(printf '"%s", ' $XL_FAILSAFE_DROPS | sed 's/, $//')]"
  # the Code page: tool use not known, so "not tested" (never "chat only": the tools are sent)
  assert_eq "$(explabs_code_rows | cut -f9)" ""
  # a list read with ANOTHER key (another organisation): not this key's, so fail safe too
  _xl_cached; XL_KEY_USE="$XL_KEY2" _xl_env
  assert_eq "$(xl_selected | cut -f1,2)" "$(printf 'failsafe\tqwen3.8-27b')"
  # a model the list names without details
  XL_KEY_USE='' _xl_cached 'EXPLABS_MODELS=gpt-latest
'
  assert_eq "$(xl_selected | cut -f1)" failsafe
  assert_contains "$(explabs_yaml)" "additional_drop_params: $all"
  # every name of the lists is one the hook may drop (lib/litellm-hooks/bn_hooks.py XL_OPTIONAL)
  for p in $XL_OPTIONAL_PARAMS $XL_FAILSAFE_DROPS; do assert_contains "$(cat "$T_ROOT/lib/litellm-hooks/bn_hooks.py")" "\"$p\""; done
}

test_the_allow_list_picks_the_models() {
  # blank: only qwen3.8-27b
  _xl_cached
  assert_eq "$(xl_selected | cut -f2)" qwen3.8-27b
  # a list in its own order, xl/ accepted, each once; an id the key may not call is left out (with a list), and a
  # "<slug>:free" takes its slug's details at $0
  _xl_cached 'EXPLABS_MODELS=xl/gpt-5-mini, deepseek-v4.1-flash,nope,gpt-5-mini,deepseek-v4.1-flash:free,bad id
'
  assert_eq "$(xl_selected | cut -f2 | tr '\n' ' ')" "gpt-5-mini deepseek-v4.1-flash deepseek-v4.1-flash:free "
  assert_eq "$(xl_selected | awk -F'\t' '$2 == "deepseek-v4.1-flash:free" { print $1, $3, $16, $17 }')" "details 1 0 0"
  assert_eq "$(xl_missing | tr '\n' ' ')" "nope "
  assert_contains "$(explabs_yaml)" "$(printf '  - model_name: "xl/deepseek-v4.1-flash:free"\n    litellm_params:\n      model: "openai/deepseek-v4.1-flash:free"')"
  assert_contains "$(explabs_yaml | grep -A 12 'deepseek-v4.1-flash:free"$')" "$(printf '      input_cost_per_token: 0\n      output_cost_per_token: 0\n')"
  # no key: nothing, whatever EXPLABS_MODELS says
  printf 'EXPLABS_MODELS=qwen3.8-27b\n' > "$ENV_FILE"
  assert_eq "$(xl_selected)$(explabs_yaml)$(explabs_code_rows)$(explabs_owui_models)$(explabs_cost_prices_entries)" ""
}

test_validators_for_the_key_and_the_models() {
  valid_xl_key "$XL_KEY"; valid_xl_key "test-key-for-the-validator-only"
  ! valid_xl_key ''; ! valid_xl_key 'short-key'; ! valid_xl_key "$XL_KEY x"; ! valid_xl_key "${XL_KEY}\""
  ! valid_xl_key "$(printf '%0257d' 0)"
  valid_xl_models ''; valid_xl_models qwen3.8-27b; valid_xl_models 'xl/qwen3.8-27b,gpt-5-mini,deepseek-v4.1-flash:free'
  ! valid_xl_models 'a,'; ! valid_xl_models ',a'; ! valid_xl_models 'a,,b'; ! valid_xl_models 'a/b'; ! valid_xl_models '-a'
  ! valid_xl_models 'a b'; ! valid_xl_models "a;rm"
  ! setting_validate EXPLABS_API_KEY 'not a key'
  assert_eq "$SV_ERR" "EXPLABS_API_KEY must be an Experiential Labs key (20-256 letters, digits, - and _)"
  ! setting_validate EXPLABS_MODELS 'qwen3.8-27b,'
  assert_contains "$SV_ERR" "EXPLABS_MODELS must be a comma list of the gateway's model ids"
  # the key: a secret nothing shows, changed only from this computer; the models: from anywhere
  assert_eq "$(setting_field EXPLABS_API_KEY 3)/$(setting_field EXPLABS_API_KEY 4)" "S/local"
  assert_eq "$(setting_field EXPLABS_MODELS 3)/$(setting_field EXPLABS_MODELS 4)" "-/edit"
  ! setting_allowed EXPLABS_API_KEY "$XL_KEY" remote
  assert_contains "$SV_ERR" "can only be changed from the computer running"
  setting_allowed EXPLABS_MODELS gpt-5-mini remote
  assert_eq "$(_settings_mask EXPLABS_API_KEY "$XL_KEY")" "(set)"
}

test_a_malformed_key_is_off_and_never_sent() {
  _stub_curl
  STACK_DIR="$TMP"; mkdir -p "$TMP/litellm"
  printf 'EXPLABS_API_KEY=xpl_has spaces in it\n' > "$ENV_FILE"
  ! explabs_enabled
  assert_contains "$(xl_key_problem 2>&1)" "EXPLABS_API_KEY in .env is not a valid key"
  explabs_refresh 2>/dev/null
  assert_eq "$(cat "$TMP/calls" 2>/dev/null)$(explabs_yaml)" ""   # no request, no model
}

# Two requests: the key's list with the key (on curl's stdin only), the catalog without it — nothing about you sent there
test_refresh_reads_the_keys_list_with_the_key_and_the_catalog_without() {
  _stub_curl
  _xl_env 'EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini
'
  explabs_refresh 2> "$TMP/err"
  assert_eq "$(grep -c '^curl keyed ' "$TMP/calls")" 1
  assert_contains "$(grep '^curl keyed ' "$TMP/calls")" "--proto =https"
  assert_contains "$(grep '^curl keyed ' "$TMP/calls")" " https://api.experientiallabs.ai/v1/models"
  # the catalog: keyless, https, paged; the second page adds nothing (the gateway ignored offset or ran out), the end
  assert_eq "$(grep -c '^curl keyless ' "$TMP/calls")" 2
  assert_contains "$(grep '^curl keyless ' "$TMP/calls" | head -n 1)" "--proto =https"
  assert_contains "$(grep '^curl keyless ' "$TMP/calls" | head -n 1)" " https://api.experientiallabs.ai/api/models?limit=500&offset=0"
  assert_not_contains "$(grep '^curl keyless ' "$TMP/calls")" "Authorization"
  assert_eq "$(grep -c 'Authorization' "$TMP/stdin")" 1                       # one keyed request, the key on its stdin
  assert_contains "$(cat "$TMP/stdin")" "Authorization: Bearer $XL_KEY"     # (curl_auth: the header on curl's stdin)
  _assert_no_key "$(cat "$TMP/calls")" "$(cat "$TMP/err")"
  xl_cache_current
  assert_eq "$(ls -l "$(xl_cache_tsv)" | cut -c1-10)/$(ls -l "$(xl_key_mark)" | cut -c1-10)" "-rw-r--r--/-rw-------"
  _assert_no_key "$(cat "$(xl_cache_tsv)")" "$(cat "$(xl_key_mark)")"
  assert_eq "$(xl_selected | cut -f1,2 | tr '\n' ' ')" "$(printf 'details\tqwen3.8-27b details\tgpt-5-mini ')"
  # young enough: no request at all
  : > "$TMP/calls"; explabs_refresh 720
  assert_eq "$(cat "$TMP/calls")" ""
  # another key in .env: read again, whatever the age
  XL_KEY_USE="$XL_KEY2" _xl_env; explabs_refresh 720 2>/dev/null
  assert_contains "$(cat "$TMP/calls")" "/v1/models"
}

# The catalog page by page (limit/offset) until a page adds no model, whatever size the gateway's pages are
test_the_catalog_is_read_page_by_page() {
  _stub_curl
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))
json.dump({"object": "list", "data": d["data"][:4]}, open(sys.argv[2], "w")); json.dump({"object": "list", "data": d["data"][4:]}, open(sys.argv[3], "w"))
json.dump({"object": "list", "data": []}, open(sys.argv[4], "w"))' "$FIX_CAT" "$TMP/p0.json" "$TMP/p4.json" "$TMP/p7.json"
  _xl_env 'EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini
'
  CATALOG_BODY="$TMP/p0.json" CATALOG_BODY_4="$TMP/p4.json" CATALOG_BODY_7="$TMP/p7.json" explabs_refresh 2>/dev/null
  assert_eq "$(grep '^curl keyless ' "$TMP/calls" | sed 's/.*offset=//' | tr '\n' ' ')" "0 4 7 "
  assert_eq "$(xl_cached_rows | awk -F'\t' '$2 != ""' | wc -l | tr -d ' ')" 6   # every model with its details (gpt-latest has none)
  assert_eq "$(xl_selected | cut -f1 | tr '\n' ' ')" "details details "
}

# The key's list read, the catalog not: the models run fail safe with the reason in ./stack status (the key's list is
# taken: an id it lacks is still left out); details read earlier for this key stay instead
test_the_catalog_failing_while_the_keys_list_works_runs_fail_safe() {
  _stub_curl
  _xl_env 'EXPLABS_MODELS=qwen3.8-27b,nope
'
  CATALOG_CODE=503 explabs_refresh 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "'nope' (EXPLABS_MODELS) is not a model your key may call — left out"
  assert_contains "$(cat "$TMP/err")" "Experiential Labs: api.experientiallabs.ai/api/models answered HTTP 503 — until the details can be read its models are sent no sampling or penalty parameter"
  assert_eq "$(xl_selected | cut -f1,2 | tr '\t\n' ': ')" "failsafe:qwen3.8-27b "
  local st; st="$(explabs_status_line)"
  assert_contains "$st" "Experiential Labs: 1 model (xl/qwen3.8-27b) — all without model details (api.experientiallabs.ai/api/models answered HTTP 503, "
  assert_contains "$st" "so fail safe: none of temperature, top_p"
  assert_contains "$(explabs_yaml)" 'bn_xl_max_tokens: "max_tokens"'
  # a later refresh within 12 h is not skipped while that failure stands: details then
  : > "$TMP/calls"; explabs_refresh 720 2>/dev/null
  assert_contains "$(cat "$TMP/calls")" "/api/models"
  assert_eq "$(xl_selected | cut -f1)" details
  [ ! -e "$(xl_error_file)" ]
  # the catalog fails again: the details read before stay, the status line names the failure
  CATALOG_CODE=500 explabs_refresh 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "api.experientiallabs.ai/api/models answered HTTP 500 — keeping the model details read"
  assert_eq "$(xl_selected | cut -f1)" details
  assert_contains "$(explabs_status_line)" "(the last refresh failed: api.experientiallabs.ai/api/models answered HTTP 500)"
  # an answer of the catalog with no model in it
  printf '{"object":"list","data":[]}' > "$TMP/empty.json"
  rm -f "$(xl_cache_tsv)"; CATALOG_BODY="$TMP/empty.json" explabs_refresh 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "api.experientiallabs.ai/api/models sent no model details"
  assert_eq "$(xl_selected | cut -f1)" failsafe
}

test_a_failed_refresh_keeps_the_list_or_runs_fail_safe_and_says_so() {
  _stub_curl
  # no list yet, no answer: the models run fail safe, said once, and ./stack status says why
  _xl_env
  CURL_FAIL=1 explabs_refresh 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "Experiential Labs: could not reach api.experientiallabs.ai — until the details can be read its models are sent no sampling or penalty parameter"
  assert_eq "$(xl_selected | cut -f1)" failsafe
  local st; st="$(explabs_status_line)"
  assert_contains "$st" "Experiential Labs: 1 model (xl/qwen3.8-27b) — all without model details (could not reach api.experientiallabs.ai, "
  assert_contains "$st" "so fail safe: none of temperature, top_p, top_k, frequency_penalty, presence_penalty, logprobs, top_logprobs, response_format, reasoning_effort is sent (tools and the max_tokens cap are)"
  _assert_no_key "$st" "$(cat "$TMP/err")" "$(cat "$(xl_error_file)")"
  assert_eq "$(ls -l "$(xl_error_file)" | cut -c1-10)" "-rw-------"
  # it works again: details, the error gone
  explabs_refresh 2>/dev/null
  assert_eq "$(xl_selected | cut -f1)" details
  [ ! -e "$(xl_error_file)" ]
  assert_contains "$(explabs_status_line)" "Experiential Labs: 1 model (xl/qwen3.8-27b) — model details read "
  # a rejected key: the list read before with it stays (and the status line names the failure)
  MODELS_CODE=401 explabs_refresh 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "the gateway rejected the key (HTTP 401) — a new one: https://platform.experientiallabs.ai/settings/api-keys — keeping the model details read"
  assert_eq "$(xl_selected | cut -f1)" details
  assert_contains "$(explabs_status_line)" "(the last refresh failed: the gateway rejected the key (HTTP 401)"
  # an answer that is no model list
  printf '<html>maintenance</html>' > "$TMP/page"
  V1_BODY="$TMP/page" explabs_refresh 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "api.experientiallabs.ai sent no model list"
  # off: no status line
  : > "$ENV_FILE"; assert_eq "$(explabs_status_line)" ""
}

test_a_change_re_renders_litellm_once_and_says_so() {
  _stub_curl
  _xl_env
  render_config() { echo render >> "$TMP/renders"; }
  : > "$TMP/litellm/config.yaml"
  explabs_refresh 2>/dev/null; assert_eq "$XL_CHANGED/$(cat "$TMP/renders")" "1/render"   # fail safe → details
  : > "$TMP/renders"; explabs_refresh 2>/dev/null; assert_eq "$XL_CHANGED/$(cat "$TMP/renders")" "0/"   # nothing new
  # the gateway changed a model's details (no more temperature for qwen3.8-27b): rendered again
  sed 's/"supports_temperature": true/"supports_temperature": false/' "$FIX_CAT" > "$TMP/changed.json"
  CATALOG_BODY="$TMP/changed.json" explabs_refresh 2>/dev/null; assert_eq "$XL_CHANGED/$(cat "$TMP/renders")" "1/render"
  assert_contains "$(explabs_yaml)" 'additional_drop_params: ["temperature", "frequency_penalty"'
}

test_litellm_config_with_the_gateway_is_valid_yaml_and_holds_no_key() {
  command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' 2>/dev/null || { echo "no PyYAML" >&2; return 77; }
  local cat="$TMP/catalog.tsv" y
  printf 'claude-haiku-5-5\tchat\tbedrock/x\t-\t-\n' > "$cat"
  _xl_cached 'EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini
'
  y="$(CATALOG="$cat" PRICES=/dev/null render_litellm_config "" us-east-1 false)"
  printf '%s\n' "$y" > "$TMP/config.yaml"
  litellm_config_safe "$TMP/config.yaml"
  python3 -I -c '
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
xl = {m["model_name"]: m for m in c["model_list"] if m["model_name"].startswith("xl/")}
assert sorted(xl) == ["xl/gpt-5-mini", "xl/qwen3.8-27b"], sorted(xl)
q = xl["xl/qwen3.8-27b"]
assert q["litellm_params"]["model"] == "openai/qwen3.8-27b" and q["litellm_params"]["api_base"] == "https://api.experientiallabs.ai/v1"
assert q["litellm_params"]["api_key"] == "os.environ/EXPLABS_API_KEY" and q["litellm_params"]["drop_params"] is True
assert "temperature" not in q["litellm_params"]["additional_drop_params"] and "max_tokens" in q["litellm_params"]["additional_drop_params"]
assert q["model_info"]["bn_xl"] is True and q["model_info"]["input_cost_per_token"] == 3.2e-07
# Claude Code'"'"'s /v1/messages to them on Chat Completions (LiteLLM would take its Responses API for openai/ models)
assert c["litellm_settings"]["use_chat_completions_url_for_anthropic_messages"] is True
' "$TMP/config.yaml"
  _assert_no_key "$y"
  # off: neither the models nor the setting
  : > "$ENV_FILE"
  y="$(CATALOG="$cat" PRICES=/dev/null render_litellm_config "" us-east-1 false)"
  assert_not_contains "$y" "xl/"; assert_not_contains "$y" "use_chat_completions_url_for_anthropic_messages"
}

test_the_code_pages_rows_chats_names_and_the_cost_lines_prices() {
  _xl_cached 'EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini,chatgpt-image-latest,deepseek-v4.1-flash:free
'
  local rows
  # id name vendor in out cache_read cache_write (USD per million) free tools max_out context
  rows="$(explabs_code_rows)"
  assert_contains "$rows" "$(printf 'xl/qwen3.8-27b\tqwen3.8-27b\tQwen\t0.32\t2.4\t0.04\t\t0\t1\t131072\t1000000')"
  assert_contains "$rows" "$(printf 'xl/deepseek-v4.1-flash:free\tdeepseek-v4.1-flash:free\tDeepSeek\t0\t0\t\t\t1\t1\t')"
  # the Code page's file: the provider, tool use as its details say (none known: chat only)
  printf 'claude-haiku-5-5\tchat\tbedrock/x\t-\t-\n' > "$TMP/catalog.tsv"
  rows="$(CATALOG="$TMP/catalog.tsv" PRICES=/dev/null CODE_COMPAT=/dev/null CODE_DISPLAY_TSV=/dev/null code_models_rows "")"
  assert_contains "$rows" "$(printf 'xl/qwen3.8-27b\tqwen3.8-27b\tExperiential Labs\tQwen\t0.32\t2.4\t0.04\t-\t0\tuntested\t1\t0\t131072\t1000000\tNot checked with Claude Code here; Experiential Labs lists tool use for it.')"
  assert_contains "$rows" "$(printf 'xl/chatgpt-image-latest\tchatgpt-image-latest\tExperiential Labs\tOpenAI\t5\t32\t-\t-\t0\tuntested\t')"
  assert_contains "$rows" "$(printf 'xl/deepseek-v4.1-flash:free\tdeepseek-v4.1-flash:free\tExperiential Labs\tDeepSeek\t0\t0\t-\t-\t1\t')"
  # Chat: named and tagged as the gateway's; the description says what the list price is
  assert_contains "$(explabs_owui_models)" "$(printf 'xl/qwen3.8-27b\tqwen3.8-27b · Experiential Labs\tExperiential Labs · $0.32 in / $2.40 out per 1M tokens (list price; the gateway bills what each call cost) · 1M context\tExperiential Labs,Qwen')"
  # the cost line: the gateway's own figure for each answer (gateway_cost), these prices only without one
  python3 -I -c 'import json, sys; d = json.loads("{" + sys.argv[1][1:] + "}"); q = d["xl/qwen3.8-27b"]
assert q == {"name": "qwen3.8-27b (Experiential Labs)", "input_cost_per_token": 3.2e-07, "output_cost_per_token": 2.4e-06, "cache_read_input_token_cost": 4e-08, "gateway_cost": True}, q
assert d["xl/deepseek-v4.1-flash:free"]["input_cost_per_token"] == 0' "$(explabs_cost_prices_entries)"
}

# Chat's cost filter gets them with the Bedrock prices (lib/owui.sh cost_prices_json), and loses them with the key
test_chats_cost_filter_prices_them_while_it_is_on() {
  _xl_cached
  printf 'claude-haiku-5-5\tchat\tbedrock/x\t-\t-\n' > "$TMP/catalog.tsv"
  printf 'claude-haiku-5-5\t1\t5\t-\t-\t-\t-\n' > "$TMP/prices.tsv"
  local j; j="$(CATALOG="$TMP/catalog.tsv" PRICES="$TMP/prices.tsv" cost_prices_json)"
  python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); assert d["xl/qwen3.8-27b"]["gateway_cost"] is True and "claude-haiku-5-5" in d, d' "$j"
  _assert_no_key "$j"
  : > "$ENV_FILE"
  assert_not_contains "$(CATALOG="$TMP/catalog.tsv" PRICES="$TMP/prices.tsv" cost_prices_json)" "xl/"
}

test_the_portal_gets_the_models_and_never_the_key() {
  _xl_cached 'EXPLABS_MODELS=qwen3.8-27b,gpt-latest
'
  explabs_write_portal_json
  local f; f="$(xl_cache_json)"
  assert_eq "$(ls -l "$f" | cut -c1-10)" "-rw-r--r--"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))
assert d["details"] is True and d["fetched_at"] == "2026-10-24T00:00:00Z" and d["error"] is None
assert [m["id"] for m in d["models"]] == ["xl/qwen3.8-27b", "xl/gpt-latest"]
assert d["models"][0] == {"id": "xl/qwen3.8-27b", "name": "qwen3.8-27b", "vendor": "Qwen", "prompt": 3.2e-07, "completion": 2.4e-06, "context_length": 1000000, "free": False, "failsafe": False}
assert d["models"][1]["failsafe"] is True and d["models"][1]["prompt"] is None' "$f"
  _assert_no_key "$(cat "$f")"
  : > "$ENV_FILE"; explabs_write_portal_json; [ ! -e "$f" ]   # off: gone
}

test_the_shells_explabs_variables_never_reach_compose() {
  EXPLABS_API_KEY="$XL_KEY" EXPLABS_MODELS=gpt-5-mini
  export EXPLABS_API_KEY EXPLABS_MODELS
  docker() { env | grep '^EXPLABS_' || true; }
  assert_eq "$(dc config)" ""
}

test_costs_status_and_summary_lines() {
  _xl_cached 'EXPLABS_MODELS=qwen3.8-27b,deepseek-v4.1-flash:free,gpt-latest
'
  local out
  out="$(LITELLM_MASTER_KEY='' explabs_costs_section)"
  assert_contains "$out" "  xl/qwen3.8-27b                       list price \$0.32 in / \$2.40 out per 1M tokens"
  assert_contains "$out" "  xl/deepseek-v4.1-flash:free          free"
  assert_contains "$out" "  xl/gpt-latest                        price unknown"
  assert_contains "$out" "On your own provider key (BYOK) the provider bills you and the gateway charges \$0: such calls count \$0 here."
  assert_contains "$(explabs_summary_line)" "Experiential Labs 3 models (xl/qwen3.8-27b, xl/deepseek-v4.1-flash:free, xl/gpt-latest)"
  assert_contains "$(explabs_models_section)" "./stack config set EXPLABS_MODELS"
  _assert_no_key "$out" "$(explabs_summary_line)" "$(explabs_models_section)" "$(explabs_status_line)"
  : > "$ENV_FILE"
  assert_contains "$(explabs_costs_section)" "Experiential Labs: off — ./stack config set EXPLABS_API_KEY"
  assert_eq "$(explabs_summary_line)$(explabs_models_section)" ""
}

test_setup_adds_the_paste_in_lines_once() {
  STACK_DIR="$TMP"
  printf 'POSTGRES_PASSWORD=p\n' > "$ENV_FILE"
  setup_explabs 2>/dev/null
  assert_eq "$(grep -c '^EXPLABS_API_KEY=$' "$ENV_FILE")/$(grep -c '^EXPLABS_MODELS=$' "$ENV_FILE")" "1/1"
  assert_contains "$(cat "$ENV_FILE")" "./stack config set EXPLABS_API_KEY asks for the key"
  setup_explabs 2>/dev/null
  assert_eq "$(grep -c '^EXPLABS_API_KEY=' "$ENV_FILE")" 1
  # .env.example has them for new installs
  assert_eq "$(grep -c '^EXPLABS_API_KEY=$' "$T_ROOT/.env.example")/$(grep -c '^EXPLABS_MODELS=$' "$T_ROOT/.env.example")" "1/1"
}

test_up_renders_again_when_the_key_was_removed_by_hand() {
  STACK_DIR="$TMP"; mkdir -p "$TMP/litellm"
  : > "$ENV_FILE"
  printf 'model_list:\n  - model_name: "xl/qwen3.8-27b"\n' > "$TMP/litellm/config.yaml"
  render_config() { echo render >> "$TMP/calls"; }
  dc() { echo "dc $*" >> "$TMP/calls"; [ "$*" != "ps -q litellm" ] || echo abc; }
  explabs_up_hook 2>/dev/null
  assert_eq "$XL_UP_CHANGED" 1
  assert_contains "$(cat "$TMP/calls")" "render"
  assert_contains "$(cat "$TMP/calls")" "dc up -d --no-deps --force-recreate litellm"
  # no key and nothing of it in the config: nothing at all
  : > "$TMP/calls"; printf 'model_list: []\n' > "$TMP/litellm/config.yaml"
  explabs_up_hook; assert_eq "$(cat "$TMP/calls")/$XL_UP_CHANGED" "/0"
}

# LiteLLM's hook (lib/litellm-hooks/bn_hooks.py), with a stand-in for LiteLLM's CustomLogger: the output cap under the
# field the model takes (in extra_body) and the parameters its details refuse left out — only for the gateway's models, only on their
# Chat Completions calls; the cost LiteLLM books is the gateway's (usage.cost), $0 on your own provider key
_hook() {
  command -v python3 >/dev/null 2>&1 || return 77
  mkdir -p "$TMP/h/litellm/integrations"
  printf '' > "$TMP/h/litellm/__init__.py"; printf '' > "$TMP/h/litellm/integrations/__init__.py"
  printf 'class CustomLogger:\n    pass\n' > "$TMP/h/litellm/integrations/custom_logger.py"
  cp "$STACK_DIR/lib/litellm-hooks/bn_hooks.py" "$TMP/h/bn_hooks.py"
}

test_litellm_hook_sends_each_gateway_model_only_what_it_takes() {
  _hook || return $?
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, copy, enum, bn_hooks as h
class CallTypes(enum.Enum):
    acompletion = "acompletion"
    anthropic_messages = "anthropic_messages"
run = lambda kw, ct=CallTypes.acompletion: asyncio.run(h.proxy_handler_instance.async_pre_call_deployment_hook(kw, ct))
mi = {"bn_xl": True, "bn_xl_max_tokens": "max_completion_tokens"}
drops = ["frequency_penalty", "logprobs", "top_logprobs", "response_format", "max_tokens", "messages", "model"]
kw = {"model": "openai/qwen3.8-27b", "messages": [{"role": "user", "content": "hi"}], "model_info": mi, "additional_drop_params": drops,
      "max_tokens": 32000, "temperature": 0.3, "frequency_penalty": 0.5, "logprobs": True, "extra_body": {"top_logprobs": 2, "keep": 1}}
out = run(copy.deepcopy(kw))
# the cap under its field, in extra_body (LiteLLM renames a top-level max_tokens for o-series and GPT-5 names)
assert "max_tokens" not in out and "max_completion_tokens" not in out, out
assert out["temperature"] == 0.3 and "frequency_penalty" not in out and "logprobs" not in out, out
assert out["extra_body"] == {"keep": 1, "max_completion_tokens": 32000}, out          # extra_body dropped from too
assert out["messages"] == kw["messages"] and out["model"] == kw["model"], out          # never anything but XL_OPTIONAL
# a cap already under its field wins; the other way round for a max_tokens model (o4-mini, gpt-5.1-codex)
assert run({**copy.deepcopy(kw), "max_completion_tokens": 100})["extra_body"]["max_completion_tokens"] == 100
mi_mt = {"bn_xl": True, "bn_xl_max_tokens": "max_tokens"}
mt = run({"model": "openai/o4-mini", "model_info": mi_mt, "max_completion_tokens": 50})
assert mt == {"model": "openai/o4-mini", "model_info": mi_mt, "extra_body": {"max_tokens": 50}}, mt
assert run({"model": "openai/o4-mini", "model_info": mi_mt, "max_tokens": 7, "extra_body": None})["extra_body"] == {"max_tokens": 7}
# no cap asked: none added
assert run({"model": "openai/x", "model_info": mi_mt}) == {"model": "openai/x", "model_info": mi_mt}
# anything failing here: the request exactly as it came, its cap where it was
class Odd(dict):
    def keys(self): raise RuntimeError("odd")
odd = {"model": "openai/x", "model_info": mi_mt, "max_tokens": 9, "additional_drop_params": ["top_k"], "extra_body": Odd(a=1)}
assert run(odd) is odd and odd["max_tokens"] == 9 and "max_tokens" not in odd["extra_body"], odd
# not on LiteLLM'"'"'s own anthropic_messages call (it needs Anthropic'"'"'s max_tokens), nor for another model, nor odd shapes
assert run(copy.deepcopy(kw), CallTypes.anthropic_messages) == kw
other = {"model": "bedrock/x", "model_info": {"id": "1"}, "max_tokens": 9, "temperature": 1, "additional_drop_params": ["temperature"]}
assert run(copy.deepcopy(other)) == other
for odd in ({"model_info": "x"}, {"model_info": {"bn_xl": "yes"}, "max_tokens": 1}, {"model_info": {"bn_xl": True}, "additional_drop_params": "max_tokens", "max_tokens": 1}):
    assert run(copy.deepcopy(odd)) == odd, odd
assert run(None) is None and run(["x"]) == ["x"]
'
}

# Claude Code with extended thinking on: LiteLLM renames the model openai/responses/<id> (for OpenAI's Responses API)
# and shapes reasoning_effort for it; the gateway gets the id it knows, on Chat Completions, and a plain effort
test_litellm_hook_keeps_a_thinking_request_on_the_models_own_id() {
  _hook || return $?
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, copy, enum, bn_hooks as h
class CallTypes(enum.Enum):
    acompletion = "acompletion"
run = lambda kw: asyncio.run(h.proxy_handler_instance.async_pre_call_deployment_hook(kw, CallTypes.acompletion))
mi = {"bn_xl": True, "bn_xl_max_tokens": "max_tokens"}
out = run({"model": "openai/responses/claude-fable-5", "model_info": mi, "reasoning_effort": {"effort": "high", "summary": "detailed"}})
assert out["model"] == "openai/claude-fable-5" and out["reasoning_effort"] == "high", out
assert run({"model": "responses/gemini-3.7-flash", "custom_llm_provider": "openai", "model_info": mi})["model"] == "gemini-3.7-flash"
out = run({"model": "openai/responses/claude-fable-5", "model_info": mi, "reasoning_effort": {"summary": "auto"}})
assert "reasoning_effort" not in out, out                                               # no effort in it: none sent
# a plain id, an effort already plain, an id holding "responses/" elsewhere: as they came
for kw in ({"model": "openai/claude-fable-5", "model_info": mi, "reasoning_effort": "low"},
           {"model": "openai/acme/responses/x", "model_info": mi, "reasoning_effort": {"effort": "low"}}):
    assert run(copy.deepcopy(kw)) == kw, kw
# another deployment (OpenAI itself, were there one): LiteLLM'"'"'s rule stands
other = {"model": "openai/responses/gpt-5", "model_info": {"id": "1"}, "reasoning_effort": {"effort": "high"}}
assert run(copy.deepcopy(other)) == other
'
}

test_litellm_hook_books_the_cost_the_gateway_reported() {
  _hook || return $?
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, math, bn_hooks as h
class Usage:
    def __init__(self, **kw): self.__dict__.update(kw)
class Resp:
    def __init__(self, usage, hidden=None): self.usage = usage; self._hidden_params = {} if hidden is None else hidden
xl = {"model": "openai/qwen3.8-27b", "model_info": {"bn_xl": True}}
post = lambda req, r: asyncio.run(h.proxy_handler_instance.async_post_call_success_deployment_hook(req, r, None))
H = "llm_provider-x-litellm-response-cost"
r = post(xl, Resp(Usage(prompt_tokens=58, completion_tokens=48, cost=0.00013376, is_byok=False), {"additional_headers": {"llm_provider-x-gateway-provider": "experiential_cloud"}}))
assert r._hidden_params["additional_headers"] == {"llm_provider-x-gateway-provider": "experiential_cloud", H: 0.00013376}, r._hidden_params
# your own provider key: $0, whatever cost says
assert post(xl, Resp(Usage(cost=0.002, is_byok=True)))._hidden_params["additional_headers"][H] == 0.0
# a usage dict works too
assert post(xl, Resp({"cost": 0.5}))._hidden_params["additional_headers"][H] == 0.5
# no figure, or not a usable one: nothing booked here (LiteLLM prices it from the config)
for u in (Usage(), Usage(cost=None), Usage(cost="0.1"), Usage(cost=True), Usage(cost=-1), Usage(cost=math.inf), Usage(cost=float("nan")), None):
    assert "additional_headers" not in post(xl, Resp(u))._hidden_params, u
# another model: never
assert post({"model": "bedrock/x", "model_info": {}}, Resp(Usage(cost=1.0)))._hidden_params == {}
# odd shapes: unchanged, never an error
class NoHidden: usage = Usage(cost=1.0)
assert isinstance(post(xl, NoHidden()), NoHidden)
assert post(None, Resp(Usage(cost=1.0)))._hidden_params == {}
assert post(xl, None) is None
'
}

# Open WebUI: names "<id> · Experiential Labs", tags Experiential Labs and the vendor; a name or tag of your own stays;
# its own entries that are no longer offered go (also once the key went), OpenRouter's and yours are never touched
test_open_webui_names_tags_and_cleans_up_only_its_own() {
  command -v python3 >/dev/null || return 77
  _xl_cached 'EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini
OPENWEBUI_API_KEY=sk-ow
'
  _owui_get() { echo "GET $1" >> "$TMP/owui"; printf '%s' "${OWUI_BASE:-[]}" > "$2"; echo 200; }
  _owui_post() { echo "POST $1 $2" >> "$TMP/owui"; echo 200; }
  _owui_py() { local s="$1"; shift; python3 -c "$s" "$@"; }
  OWUI_BASE='[{"id":"xl/qwen3.8-27b","name":"My Qwen","meta":{"tags":[{"name":"mine"}],"bedrock_now":"explabs"}},
 {"id":"xl/old-model","name":"old-model · Experiential Labs","meta":{"bedrock_now":"explabs"}},
 {"id":"or/a/b","name":"B · OpenRouter","meta":{"bedrock_now":"openrouter"}},
 {"id":"xl/hand-made","name":"mine","meta":{}}]'
  local out imp; out="$(explabs_sync_owui 2>&1)"
  assert_contains "$out" "Open WebUI: Experiential Labs models named and tagged (2 updated, 0 unchanged, 1 removed)"
  imp="$(grep '^POST /api/v1/models/import ' "$TMP/owui" | cut -d' ' -f3-)"
  assert_eq "$(printf '%s' "$imp" | python3 -c 'import json, sys
m = {x["id"]: x for x in json.load(sys.stdin)["models"]}
print(m["xl/qwen3.8-27b"]["name"], [t["name"] for t in m["xl/qwen3.8-27b"]["meta"]["tags"]], m["xl/gpt-5-mini"]["name"], m["xl/gpt-5-mini"]["meta"]["bedrock_now"])')" \
    "My Qwen ['Experiential Labs', 'Qwen', 'mine'] gpt-5-mini · Experiential Labs explabs"
  assert_contains "$(cat "$TMP/owui")" 'POST /api/v1/models/model/delete {"id": "xl/old-model"}'
  assert_not_contains "$(cat "$TMP/owui")" "or/a/b"; assert_not_contains "$(cat "$TMP/owui")" "xl/hand-made"
  [ -e "$STATE_DIR/explabs-owui-synced" ]
  _assert_no_key "$(cat "$TMP/owui")" "$out"
  # the key went: its entries go with it, the marker too
  printf 'OPENWEBUI_API_KEY=sk-ow\n' > "$ENV_FILE"; : > "$TMP/owui"
  OWUI_BASE='[{"id":"xl/qwen3.8-27b","name":"My Qwen","meta":{"bedrock_now":"explabs"}}]'
  explabs_sync_owui 2>/dev/null
  assert_contains "$(cat "$TMP/owui")" 'POST /api/v1/models/model/delete {"id": "xl/qwen3.8-27b"}'
  [ ! -e "$STATE_DIR/explabs-owui-synced" ]
  # never synced and off: no request at all
  : > "$TMP/owui"; explabs_sync_owui; assert_eq "$(cat "$TMP/owui")" ""
}

# LiteLLM's use_chat_completions_url_for_anthropic_messages is one switch for every openai/ deployment: rendered for
# Experiential Labs' models, it must never reach another openai/ chat model unseen. The whole config as ./stack renders
# it — the real catalog, OpenRouter's models, OpenAI speech-to-text (an openai/ model too, but no chat one) — holds
# no openai/ chat model but the gateway's; a catalog or provider that adds one fails here first
test_the_messages_switch_reaches_no_openai_chat_model_but_the_gateways() {
  command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' 2>/dev/null || { echo "no PyYAML" >&2; return 77; }
  _xl_cached "EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini
OPENROUTER_API_KEY=sk-or-v1-$(printf '%032d' 0)
STT_PROVIDER=openai
STT_API_KEY=sk-$(printf '%040d' 0)
"
  { printf '# fetched_at: 2026-10-24T00:00:00Z\n'; or_models_tsv < "$T_ROOT/tests/fixtures/openrouter_models.json" | or_classify; } > "$TMP/litellm/openrouter-models.tsv"
  CATALOG="$T_ROOT/catalog/models.tsv" PRICES="$T_ROOT/catalog/prices.tsv" render_litellm_config "" us-east-1 false > "$TMP/config.yaml"
  python3 -I -c '
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
assert c["litellm_settings"]["use_chat_completions_url_for_anthropic_messages"] is True
models = c["model_list"]
assert any(m["model_name"].startswith("or/") for m in models) and any(m["model_name"] == "stt" for m in models), "the render left OpenRouter or speech-to-text out"
openai = [m for m in models if str(m["litellm_params"]["model"]).startswith("openai/")]
chat = [m["model_name"] for m in openai if (m.get("model_info") or {}).get("mode", "chat") == "chat"]
other = [n for n in chat if not n.startswith("xl/")]
assert not other, "openai/ chat models beside the gateway'"'"'s, which use_chat_completions_url_for_anthropic_messages would move: %s" % other
assert sorted(chat) == ["xl/gpt-5-mini", "xl/qwen3.8-27b"], chat
' "$TMP/config.yaml"
}

# Tools: left out only when the details say false; null (not said) sends them, as fail safe does — a model that cannot
# take them answers with a clear 400, where silently losing them would leave Claude Code chat-only. The other nulls
# (sampling, penalties, logprobs, response_format, reasoning_effort) stay left out.
test_tools_go_unless_the_details_say_false() {
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); q = next(m for m in d["data"] if m["id"] == "qwen3.8-27b")
d["data"] += [{**q, "id": "tools-null", "supports_tools": None, "supports_temperature": None}, {**q, "id": "tools-false", "supports_tools": False}]
json.dump(d, open(sys.argv[2], "w"))
json.dump({"object": "list", "data": [{"id": m["id"], "object": "model", "created": 0, "owned_by": "exp"} for m in d["data"]]}, open(sys.argv[3], "w"))' "$FIX_CAT" "$TMP/tools.json" "$TMP/tools-v1.json"
  _xl_env 'EXPLABS_MODELS=tools-null,tools-false
'
  _xl_list "$TMP/tools.json" "$TMP/tools-v1.json"
  local y n f
  y="$(explabs_yaml)"
  n="$(printf '%s\n' "$y" | grep -A 6 '"xl/tools-null"$' | grep additional_drop_params)"
  f="$(printf '%s\n' "$y" | grep -A 6 '"xl/tools-false"$' | grep additional_drop_params)"
  assert_not_contains "$n" '"tools"'
  assert_contains "$n" '"temperature"'          # a null sampling field: still left out
  assert_contains "$f" '"tools", "tool_choice", "parallel_tool_calls", "functions", "function_call"'
  # the Code page: null tools "not tested" (they are sent), false "chat only"
  printf 'claude-haiku-5-5\tchat\tbedrock/x\t-\t-\n' > "$TMP/catalog.tsv"
  local rows; rows="$(CATALOG="$TMP/catalog.tsv" PRICES=/dev/null CODE_COMPAT=/dev/null CODE_DISPLAY_TSV=/dev/null code_models_rows "")"
  assert_eq "$(printf '%s\n' "$rows" | awk -F'\t' '$1 ~ /^xl\// { print $1, $10 }' | tr '\n' ' ')" "xl/tools-null untested xl/tools-false chat-only "
}
