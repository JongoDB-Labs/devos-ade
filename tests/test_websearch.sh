# shellcheck shell=bash
# shellcheck disable=SC2016,SC2329  # literal $ in expected output; stubs are called by the code under test
# Web search for Claude Code (lib/websearch.sh): which backend LiteLLM's web search interception gets, what its config
# and litellm/web-search.json say, AgentCore Web Search's check (lib/websearch_probe.py: its answers, run here with a
# stand-in for LiteLLM's image) and the one search through LiteLLM, the commands an AWS admin runs, and the hook's
# switch (lib/litellm-hooks/bn_hooks.py: WebSearch said to be unavailable only while no backend is set up). No test
# here calls docker, AWS or the network.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/websearch.sh

GW='https://devos-ade-web-search-abc123def4.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp'
# a key-shaped value of no provider, built here (never a literal of one)
KEY="$(printf 'k%.0s' $(seq 1 8))0123456789_-abcdef"
US="$(printf '\037')"   # (websearch_check_state's separator)

# STACK_DIR in $TMP (nothing of this checkout's litellm/ or searxng/ is written); the probe's script and the catalog stay
# the repo's. The built-in SearXNG is off unless WS_BUILTIN says otherwise (most tests here are about the backends you set
# up; WS_BUILTIN= leaves it blank, the default: on)
_ws_env() {
  local repo="$STACK_DIR"
  STACK_DIR="$TMP"; mkdir -p "$TMP/litellm" "$STATE_DIR"
  eval "websearch_probe_src() { printf '%s\\n' '$repo/lib/websearch_probe.py'; }; bn_hook_src() { printf '%s\\n' '$repo/lib/litellm-hooks/bn_hooks.py'; }"
  printf 'claude-big\tchat\tbedrock/invoke/us.anthropic.big\t-\t-\ngpt-x\tchat\tbedrock/us.openai.gpt-x\t-\t-\n' > "$TMP/cat.tsv"
  export CATALOG="$TMP/cat.tsv" PRICES="$repo/none.tsv"
  printf 'AWS_REGION_NAME=us-east-1\nWEBSEARCH_SEARXNG_BUILTIN=%s\n%s' "${WS_BUILTIN-off}" "${1:-}" > "$ENV_FILE"
}
# _probe_says LINES — the AgentCore check's container answers LINES (KEY=VALUE, as lib/websearch_probe.py prints)
_probe_says() {
  PROBE_OUT="$1"
  dc() {   # (logs its arguments, the script it was given as one word: <script>)
    local a out=''
    for a in "$@"; do case "$a" in *$'\n'*) a='<script>' ;; esac; out="$out $a"; done
    echo "dc$out" >> "$TMP/dc"; printf '%s\n' "$PROBE_OUT"
  }
}
_render() { render_litellm_config "" us-east-1 false; }

# --- which backend, and what LiteLLM's config gets ---

test_no_backend_renders_no_search_and_the_hook_alone() {
  _ws_env
  assert_eq "$(websearch_backend)" ""
  cfg="$(_render)"
  assert_not_contains "$cfg" search_tools
  assert_not_contains "$cfg" web_search
  assert_contains "$cfg" '  callbacks: ["bn_hooks.proxy_handler_instance"]'
  websearch_write_json "$TMP/ws.json"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["backend"] == "" and d["status"] == "off" and d["usd_per_query"] == 0, d
assert "no search backend set up" in d["why"] and d["why"].endswith("the built-in SearXNG is off (WEBSEARCH_SEARXNG_BUILTIN=off)"), d
assert len(d["fix"]) == 3 and "aws-setup" in d["fix"][0] and d["fix"][2].endswith("./stack config set WEBSEARCH_SEARXNG_BUILTIN on"), d
assert d["builtin"]["state"] == "off" and d["reason"] == "", d' "$TMP/ws.json"
}

test_a_key_renders_its_search_tool_and_the_interception_for_bedrock_and_openrouter() {
  _ws_env "WEBSEARCH_TAVILY_API_KEY=$KEY
"
  assert_eq "$(websearch_backend)" tavily
  cfg="$(_render)"
  assert_contains "$cfg" "$(printf 'search_tools:\n  - search_tool_name: "web-search"\n    litellm_params:\n      search_provider: "tavily"\n      api_key: os.environ/WEBSEARCH_TAVILY_API_KEY')"
  assert_not_contains "$cfg" "$KEY"   # the key: only in LiteLLM's environment (compose), never in the file
  assert_contains "$cfg" '  callbacks: ["bn_hooks.proxy_handler_instance", "bn_hooks.web_search"]'
  # a config LiteLLM can read (search_tools at the top, the settings under litellm_settings)
  printf '%s\n' "$cfg" > "$TMP/c.yaml"
  litellm_config_safe "$TMP/c.yaml"
  if python3 -I -c 'import yaml' 2>/dev/null; then
    python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1]))
assert d["search_tools"][0]["litellm_params"]["search_provider"] == "tavily", d["search_tools"]
assert d["litellm_settings"]["callbacks"] == ["bn_hooks.proxy_handler_instance", "bn_hooks.web_search"], d["litellm_settings"]' "$TMP/c.yaml"
  fi
  websearch_write_json "$TMP/ws.json"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert (d["backend"], d["provider"], d["usd_per_query"], d["status"]) == ("tavily", "tavily", 0.008, "unchecked"), d' "$TMP/ws.json"
  assert_not_contains "$(cat "$TMP/ws.json")" "$KEY"
}

test_searxng_and_agentcore_go_by_their_url() {
  _ws_env 'WEBSEARCH_SEARXNG_URL=http://host.docker.internal:8888
'
  assert_eq "$(websearch_backend)" searxng
  assert_contains "$(_render)" "$(printf '      search_provider: "searxng"\n      api_base: "http://host.docker.internal:8888"')"
  set_env WEBSEARCH_AGENTCORE_GATEWAY "$GW"
  assert_eq "$(websearch_backend)" agentcore   # AWS's own first (not checked yet: least restrictive)
  assert_contains "$(_render)" "$(printf '      search_provider: "agentcore"\n      api_base: "%s"\n      tool_name: "web-search-tool___WebSearch"' "$GW")"
  assert_eq "$(websearch_price agentcore)" 0.007005
}

test_the_order_off_and_a_backend_by_name() {
  _ws_env "WEBSEARCH_BRAVE_API_KEY=$KEY
WEBSEARCH_PERPLEXITY_API_KEY=$KEY
WEBSEARCH_SEARXNG_URL=https://search.example.org
"
  assert_eq "$(websearch_backend)" brave            # auto: the first set up, in the catalog's order
  set_env WEBSEARCH_BACKEND searxng; assert_eq "$(websearch_backend)" searxng
  set_env WEBSEARCH_BACKEND tavily; assert_eq "$(websearch_backend)" ""   # by name, but no key: none (and why)
  assert_eq "$(websearch_why_none)" "WEBSEARCH_BACKEND=tavily, and WEBSEARCH_TAVILY_API_KEY is not set"
  set_env WEBSEARCH_BACKEND off; assert_eq "$(websearch_backend)" ""
  assert_eq "$(websearch_why_none)" "turned off (WEBSEARCH_BACKEND=off)"
  assert_not_contains "$(_render)" search_tools
  assert_eq "$(websearch_fix "")" ""   # off: nothing to do
  set_env WEBSEARCH_BACKEND auto; assert_eq "$(websearch_backend)" brave
  set_env WEBSEARCH_BACKEND nonsense; assert_eq "$(websearch_choice)" auto
  assert_eq "$(WEBSEARCH_BACKEND=off websearch_choice)" auto   # .env decides, not the shell
}

test_validators() {
  for v in '' auto off agentcore tavily brave perplexity searxng builtin; do valid_websearch_backend "$v" || { echo "refused: $v" >&2; return 1; }; done
  for v in google AUTO 'tavily,brave' ' off' Builtin; do ! valid_websearch_backend "$v" || { echo "taken: $v" >&2; return 1; }; done
  valid_websearch_gateway "" && valid_websearch_gateway "$GW"
  for v in "${GW/https/http}" "$GW/x" 'https://evil.example/mcp' "${GW%/mcp}.evil.example/mcp" 'https://a.gateway.bedrock-agentcore.us-east-1.amazonaws.com.evil.example/mcp'; do
    ! valid_websearch_gateway "$v" || { echo "taken: $v" >&2; return 1; }
  done
  valid_websearch_key "" && valid_websearch_key "$KEY"
  for v in short 'a b c d e f g h i j' "$KEY\"" "$(printf 'x%.0s' $(seq 1 257))"; do ! valid_websearch_key "$v" || { echo "taken: $v" >&2; return 1; }; done
  . "$STACK_DIR/lib/settings.sh"
  setting_validate WEBSEARCH_BACKEND off && setting_validate WEBSEARCH_AGENTCORE_GATEWAY "$GW" && setting_validate WEBSEARCH_TAVILY_API_KEY "$KEY"
  setting_validate WEBSEARCH_BACKEND builtin && setting_validate WEBSEARCH_SEARXNG_BUILTIN off && setting_validate WEBSEARCH_SEARXNG_BUILTIN on
  ! setting_validate WEBSEARCH_SEARXNG_BUILTIN true
  assert_contains "$SV_ERR" "must be on or off"
  ! setting_validate WEBSEARCH_AGENTCORE_GATEWAY https://evil.example/mcp
  assert_contains "$SV_ERR" "must be an AgentCore gateway's MCP URL"
  # every web search key applies through ./stack config's websearch step
  CFG_ORDER="WEBSEARCH_BACKEND WEBSEARCH_SEARXNG_URL WEBSEARCH_SEARXNG_BUILTIN"; assert_eq "$(_cfg_classes)" " websearch "
}

# --- AgentCore Web Search's check (lib/websearch_probe.py in LiteLLM's image; here its answers) ---

test_agentcore_ready_found_by_itself_and_reused_while_it_stands() {
  _ws_env
  _probe_says "status=ready
url=$GW
tool=amazon-web-search___WebSearch
account=111122223333
principal=user/someone
region=us-east-1"
  websearch_before_render
  assert_eq "$(cat "$TMP/dc")" "dc run --rm --no-deps -T --entrypoint python litellm -I -c <script> us-east-1"
  assert_eq "$(websearch_agentcore_status)" ready
  assert_eq "$(websearch_backend)" agentcore   # no setting: the gateway it found
  assert_contains "$(_render)" "$(printf '      api_base: "%s"\n      tool_name: "amazon-web-search___WebSearch"' "$GW")"
  : > "$TMP/dc"; ! websearch_before_render; assert_eq "$(cat "$TMP/dc")" ""   # reused: no second container (1: nothing new)
  websearch_before_render --force; assert_contains "$(cat "$TMP/dc")" "dc run"
  : > "$TMP/dc"; set_env AWS_ACCESS_KEY_ID "$KEY"   # another key: its answer no longer stands
  assert_eq "$(websearch_agentcore_status)" ""
  websearch_before_render; assert_contains "$(cat "$TMP/dc")" "dc run"
  : > "$TMP/dc"; set_env WEBSEARCH_BACKEND tavily; ! websearch_before_render --force; assert_eq "$(cat "$TMP/dc")" ""   # not wanted: no check
  set_env WEBSEARCH_BACKEND off; ! websearch_before_render --force; assert_eq "$(cat "$TMP/dc")" ""
}

test_agentcore_denied_says_the_permission_and_the_command_for_the_admin() {
  _ws_env "WEBSEARCH_SEARXNG_URL=https://search.example.org
"
  _probe_says "status=denied
url=$GW
account=111122223333
principal=user/someone
region=us-east-1
why=bedrock-agentcore:InvokeGateway"
  websearch_before_render
  assert_eq "$(websearch_backend)" searxng   # auto: the next one set up
  set_env WEBSEARCH_SEARXNG_URL ''
  assert_eq "$(websearch_backend)" ""
  assert_contains "$(websearch_why_none)" "may not use (bedrock-agentcore:InvokeGateway)"
  fix="$(websearch_fix "")"
  assert_contains "$fix" "your AWS admin lets this key use the gateway devos-ade-web-search-abc123def4"
  assert_contains "$fix" "aws iam put-user-policy --user-name someone --policy-name DevOSADEWebSearch --policy-document '"
  assert_contains "$fix" '"Action":"bedrock-agentcore:InvokeGateway","Resource":"arn:aws:bedrock-agentcore:us-east-1:111122223333:gateway/devos-ade-web-search-abc123def4"'
  # the policy is valid JSON
  printf '%s\n' "$fix" | sed -n "s/.*--policy-document '\(.*\)'$/\1/p" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); assert d["Statement"][1]["Action"] == "bedrock-agentcore:ListGateways", d'
  # Settings gets the same, as JSON (the policy's quotes escaped)
  websearch_write_json "$TMP/ws.json"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["status"] == "off" and "InvokeGateway" in d["why"], d
assert d["fix"][1].startswith("aws iam put-user-policy --user-name someone") and json.loads(d["fix"][1].split(" --policy-document ")[1].strip("'"'"'")), d' "$TMP/ws.json"
  # set by name: used anyway (its error says what is missing)
  set_env WEBSEARCH_BACKEND agentcore; assert_eq "$(websearch_backend)" agentcore
  # an instance role: put-role-policy
  _probe_says "status=denied
url=$GW
account=111122223333
principal=role/ec2-devos
why=bedrock-agentcore:InvokeGateway"
  websearch_before_render --force
  assert_contains "$(websearch_user_policy_cmd 'arn:x')" "aws iam put-role-policy --role-name ec2-devos --policy-name DevOSADEWebSearch"
}

test_agentcore_no_gateway_and_no_target_and_unverified() {
  _ws_env
  _probe_says "status=no-gateway
account=111122223333
principal=user/someone
region=us-east-1
why=bedrock-agentcore:ListGateways"
  websearch_before_render
  assert_eq "$(websearch_backend)" ""
  assert_contains "$(websearch_why_none)" "this AWS key may not look for one (bedrock-agentcore:ListGateways)"
  assert_contains "$(websearch_fix "")" "./stack websearch aws-setup prints the commands"
  assert_contains "$(websearch_status)" "AgentCore   no gateway: none set, and this key may not look for one"
  _probe_says "status=no-target
url=$GW
account=111122223333
principal=user/someone"
  websearch_before_render --force
  assert_eq "$(websearch_backend)" ""
  fix="$(websearch_fix "")"
  assert_contains "$fix" "adds a web search target to the gateway devos-ade-web-search-abc123def4"
  assert_contains "$fix" "create-gateway-target --region us-east-1 --gateway-identifier devos-ade-web-search-abc123def4 --name web-search-tool"
  # a gateway URL that names no gateway (AWS: 404): said, and not used by auto
  set_env WEBSEARCH_AGENTCORE_GATEWAY "$GW"
  _probe_says "status=no-gateway
url=$GW
why=not found"
  websearch_before_render --force
  assert_eq "$(websearch_backend)" ""
  assert_eq "$(websearch_why_none)" "no search backend set up: WEBSEARCH_AGENTCORE_GATEWAY names no AgentCore gateway that exists; the built-in SearXNG is off (WEBSEARCH_SEARXNG_BUILTIN=off)"
  assert_contains "$(NO_COLOR=1 websearch_status)" "AgentCore   no gateway at $GW (it does not exist)"
  # could not tell (no answer, a container that did not start, garbage): kept as unverified, never turned off
  set_env WEBSEARCH_AGENTCORE_GATEWAY "$GW"
  for out in "status=unverified
why=URLError: timed out" "garbage" ""; do
    _probe_says "$out"; websearch_before_render --force
    assert_eq "$(websearch_agentcore_status)" unverified
    assert_eq "$(websearch_backend)" agentcore
  done
  # a probe line holding a quote or a backslash never reaches the state or the JSON
  _probe_says 'status=unverified
why=bad "quote" \ here'
  websearch_before_render --force
  assert_eq "$(_ws_state agentcore why)" "bad quote  here"
}

test_aws_setup_prints_the_admins_commands_with_this_keys_account() {
  _ws_env
  _probe_says "status=no-gateway
account=111122223333
principal=user/someone
region=us-east-1
why=none in us-east-1"
  websearch_before_render
  out="$(websearch_aws_setup)"
  assert_contains "$out" "aws iam create-role --role-name DevOSADEWebSearchGateway --assume-role-policy-document"
  assert_contains "$out" '"aws:SourceAccount":"111122223333"'
  assert_contains "$out" '"Action":"bedrock-agentcore:InvokeWebSearch","Resource":"arn:aws:bedrock-agentcore:us-east-1:aws:tool/web-search.v1"'
  assert_contains "$out" "aws bedrock-agentcore-control create-gateway --region us-east-1 --name devos-ade-web-search --role-arn arn:aws:iam::111122223333:role/DevOSADEWebSearchGateway --protocol-type MCP --authorizer-type AWS_IAM"
  assert_contains "$out" '"connectorId":"web-search"'
  assert_contains "$out" "aws iam put-user-policy --user-name someone"
  # every policy document in it is valid JSON
  printf '%s\n' "$out" | grep -o "'{[^']*}'" | tr -d "'" | while IFS= read -r j; do printf '%s' "$j" | python3 -I -c 'import json, sys; json.load(sys.stdin)' || exit 1; done
  # a region without Web Search: us-east-1
  set_env AWS_REGION_NAME eu-central-1; assert_eq "$(websearch_agentcore_region)" us-east-1
  set_env AWS_REGION_NAME eu-west-1; assert_eq "$(websearch_agentcore_region)" eu-west-1
  # before any check: placeholders, never a guess
  rm -rf "$(websearch_state_dir)"
  assert_contains "$(websearch_aws_setup)" "arn:aws:iam::ACCOUNT_ID:role/DevOSADEWebSearchGateway"
  assert_contains "$(websearch_aws_setup)" "--user-name YOUR_IAM_USER"
}

# --- the one search through LiteLLM ---

test_the_search_check_classifies_what_litellm_answered() {
  _ws_env
  printf '{"object":"search","results":[{"title":"t","url":"https://example.com","snippet":"s"}]}' > "$TMP/b"
  assert_eq "$(websearch_classify tavily 200 "$TMP/b")" "$(printf 'ok\t')"
  printf '{"error":{"message":"AgentCoreException - User: arn:aws:iam::1:user/u is not authorized to perform: bedrock-agentcore:InvokeGateway on resource"}}' > "$TMP/b"
  assert_eq "$(websearch_classify agentcore 500 "$TMP/b")" "$(printf 'failed\tAWS refused bedrock-agentcore:InvokeGateway')"
  printf '{"error":{"message":"AgentCore web search tool error: Failed to obtain execution role credentials"}}' > "$TMP/b"
  assert_eq "$(websearch_classify agentcore 502 "$TMP/b")" "$(printf "failed\tAWS refused bedrock-agentcore:InvokeWebSearch (the gateway's role)")"
  printf '{"error":{"message":"Unauthorized: invalid API key"}}' > "$TMP/b"
  assert_eq "$(websearch_classify brave 401 "$TMP/b")" "$(printf 'failed\tBrave Search refused the key (HTTP 401)')"
  assert_eq "$(websearch_classify tavily 000 /nonexistent)" "$(printf 'unverified\tLiteLLM did not answer')"
  printf 'rate limited' > "$TMP/b"
  assert_eq "$(websearch_classify tavily 429 "$TMP/b" | cut -f1)" unverified
}

test_a_search_error_never_keeps_a_key_or_the_searxng_address() {
  # (Settings' card and ./stack status show the reason: a backend may echo what it was sent, in what it answers)
  local u='https://sxuser:sxpass1234@search.example.org/sx?token=searchtoken1&lang=en' out v
  _ws_env "WEBSEARCH_TAVILY_API_KEY=$KEY
LITELLM_KEY_SETUP=sk-setup-test0123
WEBSEARCH_SEARXNG_URL=$u
"
  printf '{"error":{"message":"bad request: key %s via sk-setup-test0123"}}' "$KEY" > "$TMP/b"
  out="$(websearch_classify tavily 400 "$TMP/b")"
  assert_contains "$out" "$(printf 'failed\tHTTP 400: ')"
  assert_contains "$out" 'key *** via ***'
  for v in "$KEY" sk-setup-test0123; do assert_not_contains "$out" "$v"; done
  printf 'searx at %s failed; sxuser:sxpass1234, then sxpass1234 alone, /sx?token=searchtoken1&lang=en and searchtoken1' "$u" > "$TMP/b"
  out="$(websearch_classify searxng 502 "$TMP/b")"
  for v in sxpass1234 searchtoken1 /sx; do assert_not_contains "$out" "$v"; done
  assert_contains "$out" "searx at https://search.example.org/… failed"
  printf '{"object":"search","answer":"none for %s"}' "$KEY" > "$TMP/b"
  out="$(websearch_classify tavily 200 "$TMP/b")"
  assert_contains "$out" "$(printf 'failed\tno results: ')"; assert_not_contains "$out" "$KEY"
  # what to do, and what is sent where: the address as Settings shows it
  set_env WEBSEARCH_BACKEND searxng
  mkdir -p "$(websearch_state_dir)"
  printf 'backend=searxng\nstatus=failed\nwhy=HTTP 502\nat=%s\nfingerprint=%s\n' "$(date +%s)" "$(_ws_search_fp searxng)" > "$(_ws_state_file search)"
  out="$(websearch_fix searxng; NO_COLOR=1 websearch_status)"
  assert_contains "$out" "your SearXNG (https://search.example.org/…) must answer /search?q=test&format=json"
  assert_contains "$out" "to your SearXNG (https://search.example.org/…)"
  for v in sxuser sxpass1234 searchtoken1; do assert_not_contains "$out" "$v"; done
  # a reason kept before this redaction (v0.30.0): redacted as it is read
  printf 'backend=searxng\nstatus=failed\nwhy=HTTP 502: %s\nat=%s\nfingerprint=%s\n' "$u" "$(date +%s)" "$(_ws_search_fp searxng)" > "$(_ws_state_file search)"
  out="$(websearch_check_state searxng; NO_COLOR=1 websearch_status_line)"
  assert_contains "$out" "HTTP 502: https://search.example.org/…"
  for v in sxuser sxpass1234 searchtoken1; do assert_not_contains "$out" "$v"; done
  assert_eq "$(_ws_url_masked https://search.example.org)" https://search.example.org
  assert_eq "$(_ws_url_masked not-a-url)" '(set)'
}

test_the_search_check_runs_once_with_the_setup_key_and_is_reused() {
  _ws_env "WEBSEARCH_TAVILY_API_KEY=$KEY
LITELLM_KEY_SETUP=sk-setup-test
LITELLM_PORT=9
"
  litellm_call() { echo "$*" >> "$TMP/calls"; printf '{"results":[{"url":"https://example.com"}]}' > "$5"; printf 200; }
  websearch_search_check
  assert_contains "$(cat "$TMP/calls")" 'sk-setup-test POST /v1/search/web-search {"query":"Amazon Web Services","max_results":1} '
  assert_eq "$(websearch_check_state tavily | cut -d "$US" -f1)" ok
  # (an empty reason stays a field of its own: the date is the check's)
  assert_contains "$(NO_COLOR=1 websearch_status_line)" "Web search for Claude Code: Tavily (\$0.008 a search at its list price, on your Tavily account; checked $(date -u +%Y-%m-%d))"
  websearch_write_json "$TMP/ws.json"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["why"] == "" and d["checked_at"].startswith("20"), d' "$TMP/ws.json"
  websearch_search_check; assert_eq "$(wc -l < "$TMP/calls" | tr -d ' ')" 1   # reused
  websearch_search_check --force; assert_eq "$(wc -l < "$TMP/calls" | tr -d ' ')" 2
  set_env WEBSEARCH_TAVILY_API_KEY "${KEY}x"   # a new key: checked again
  assert_eq "$(websearch_check_state tavily | cut -d "$US" -f1)" unchecked
  litellm_call() { echo "$*" >> "$TMP/calls"; printf '{"error":{"message":"Unauthorized"}}' > "$5"; printf 401; }
  websearch_search_check
  assert_eq "$(websearch_check_state tavily | cut -d "$US" -f1,2)" "failed${US}Tavily refused the key (HTTP 401)"
  assert_contains "$(websearch_status_line)" "Web search for Claude Code: Tavily does not work — Tavily refused the key (HTTP 401)"
  assert_contains "$(websearch_fix tavily)" "./stack config set WEBSEARCH_TAVILY_API_KEY"
  # no backend: no search
  : > "$TMP/calls"; set_env WEBSEARCH_BACKEND off; websearch_search_check --force; assert_eq "$(cat "$TMP/calls")" ""
}

test_status_says_what_is_sent_where_and_what_it_costs() {
  _ws_env "WEBSEARCH_SEARXNG_URL=https://search.example.org
"
  out="$(NO_COLOR=1 websearch_status)"
  assert_contains "$out" "Web search for Claude Code: SearXNG (free: your own SearXNG; not checked)"
  assert_contains "$out" "Sent        only the search query, to your SearXNG (https://search.example.org)"
  assert_contains "$out" "Backend     WEBSEARCH_BACKEND=auto: agentcore – tavily – brave – perplexity – searxng ✓ (in use)"
  set_env WEBSEARCH_AGENTCORE_GATEWAY "$GW"
  out="$(NO_COLOR=1 websearch_status)"
  assert_contains "$out" "Amazon Bedrock AgentCore Web Search (\$0.007 a search, on your AWS bill"
  assert_contains "$out" "it stays inside AWS"
  assert_contains "$(websearch_summary_line)" "Web search      Amazon Bedrock AgentCore Web Search for Claude Code's WebSearch"
  assert_contains "$(cmd_help)" "websearch    Claude Code's WebSearch on every model"
}

# --- the hook (lib/litellm-hooks/bn_hooks.py): WEB_SEARCH_OFF only without a backend; each search booked at its price ---

test_litellm_hook_leaves_web_search_to_litellm_with_a_backend_and_registers_its_price() {
  command -v python3 >/dev/null 2>&1 || return 77
  mkdir -p "$TMP/h/litellm/integrations"
  # a stand-in for LiteLLM: register_model records what it was given
  printf 'registered = []\ndef register_model(d):\n    registered.append(d)\n' > "$TMP/h/litellm/__init__.py"
  printf '' > "$TMP/h/litellm/integrations/__init__.py"
  printf 'class CustomLogger:\n    pass\n' > "$TMP/h/litellm/integrations/custom_logger.py"
  cp "$STACK_DIR/lib/litellm-hooks/bn_hooks.py" "$TMP/h/bn_hooks.py"
  { printf '# x\n# id\n'
    printf 'gpt-x\tG\tBedrock\tOpenAI\t1\t1\t-\t-\t0\tworks\t1\t0\t-\t-\t-\n'
    printf 'claude-big\tC\tBedrock\tAnthropic\t1\t1\t-\t-\t0\tworks\t1\t1\t-\t-\t-\n'
    printf 'or/a/b\tO\tOpenRouter\ta\t1\t1\t-\t-\t0\tuntested\t1\t0\t-\t-\t-\n'; } > "$TMP/h/code-models.tsv"
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, copy, json, os, time, litellm, bn_hooks as h
ws = {"type": "web_search_20250305", "name": "web_search", "max_uses": 8}
req = {"max_tokens": 32000, "stream": True, "messages": [{"role": "user", "content": "Perform a web search for the query: x"}], "tools": [ws]}
run = lambda d: asyncio.run(h.proxy_handler_instance.async_pre_call_hook(None, None, d, "anthropic_messages"))
f = os.path.join(os.path.dirname(h.__file__), "web-search.json")
n_writes = [0]
def write(doc):
    with open(f, "w") as o:
        o.write(doc if isinstance(doc, str) else json.dumps(doc))
    n_writes[0] += 1
    t = time.time() + n_writes[0]
    os.utime(f, (t, t))   # (a new stamp each time)
# no file, a file that names none, one that is not JSON, an odd backend: WebSearch said to be unavailable (v0.28.2)
for doc in (None, {"backend": ""}, "{", {"backend": "Bad Name!"}, {"backend": ["x"]}):
    if doc is not None:
        write(doc)
    for model in ("gpt-x", "claude-big", "or/a/b"):
        assert run({**copy.deepcopy(req), "model": model})["max_tokens"] == 200, (doc, model)
# a backend: the request as it came (the interception of LiteLLM searches), and its price registered
write({"backend": "agentcore", "provider": "agentcore", "usd_per_query": 0.007005})
for model in ("gpt-x", "claude-big", "or/a/b"):
    d = {**copy.deepcopy(req), "model": model}
    assert run(copy.deepcopy(d)) == d, model
assert litellm.registered[-1] == {"agentcore/search": {"input_cost_per_query": 0.007005, "litellm_provider": "agentcore", "mode": "search"}}, litellm.registered
# the built-in SearXNG (the default): its searches booked at $0, WebSearch left to the interception
write({"backend": "builtin", "provider": "searxng", "usd_per_query": 0})
for model in ("gpt-x", "claude-big", "or/a/b"):
    d = {**copy.deepcopy(req), "model": model}
    assert run(copy.deepcopy(d)) == d, model
assert litellm.registered[-1] == {"searxng/search": {"input_cost_per_query": 0.0, "litellm_provider": "searxng", "mode": "search"}}, litellm.registered
# a price that is no price: not registered (the one LiteLLM has stands), the backend still used
n = len(litellm.registered)
for bad in (-1, 5, "0.1", True, float("nan")):
    write({"backend": "tavily", "provider": "tavily", "usd_per_query": bad})
    assert run({**copy.deepcopy(req), "model": "gpt-x"})["tools"] == [ws]
assert len(litellm.registered) == n, litellm.registered
'
}

# --- lib/websearch_probe.py itself, with stand-ins for boto3/botocore and the gateway's answers (no AWS call) ---

test_the_probe_answers_ready_denied_no_target_no_gateway_and_unverified() {
  command -v python3 >/dev/null 2>&1 || return 77
  mkdir -p "$TMP/p/boto3" "$TMP/p/botocore"
  cat > "$TMP/p/boto3/__init__.py" <<'PY'
import botocore.exceptions as be
STATE = {"creds": True, "gateways": [], "list": "ok"}
class _Creds:
    def get_frozen_credentials(self):
        return self
class _Sts:
    def get_caller_identity(self):
        return {"Account": "111122223333", "Arn": "arn:aws:iam::111122223333:user/team/someone"}
class _Control:
    def list_gateways(self, **kw):
        if STATE["list"] == "denied":
            raise be.ClientError({"Error": {"Code": "AccessDeniedException"}}, "ListGateways")
        return {"items": STATE["gateways"]}
class Session:
    def get_credentials(self):
        return _Creds() if STATE["creds"] else None
    def client(self, name, region_name=None, config=None):
        return _Sts() if name == "sts" else _Control()
PY
  printf '' > "$TMP/p/botocore/__init__.py"
  printf 'class Config:\n    def __init__(self, **kw):\n        pass\n' > "$TMP/p/botocore/config.py"
  printf 'class ClientError(Exception):\n    def __init__(self, response, op):\n        self.response = response\nclass UnknownServiceError(Exception):\n    pass\n' > "$TMP/p/botocore/exceptions.py"
  cp "$STACK_DIR/lib/websearch_probe.py" "$TMP/p/websearch_probe.py"
  PYTHONPATH="$TMP/p" GW="$GW" python3 -c '
import contextlib, io, json, os, sys, boto3, websearch_probe as p
GW = os.environ["GW"]
def answer(code, doc):
    p._signed = lambda *a, **k: (code, doc if isinstance(doc, str) else json.dumps(doc))
def run(*argv):
    sys.argv = ["-c", *argv]
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        p.main()
    return dict(l.split("=", 1) for l in out.getvalue().splitlines())
tools = {"jsonrpc": "2.0", "id": 1, "result": {"tools": [{"name": "other___Thing"}, {"name": "web-search-tool___WebSearch"}]}}
answer(200, tools)
assert run("us-east-1", GW) == {"status": "ready", "url": GW, "tool": "web-search-tool___WebSearch", "account": "111122223333",
                                 "principal": "user/someone", "region": "us-east-1", "why": ""}, run("us-east-1", GW)
# Streamable HTTP: the answer as server-sent events
answer(200, "event: message\ndata: " + json.dumps(tools) + "\n\n")
assert run("us-east-1", GW)["tool"] == "web-search-tool___WebSearch"
answer(403, {"message": "Insufficient permissions"})
r = run("us-east-1", GW); assert (r["status"], r["why"]) == ("denied", "bedrock-agentcore:InvokeGateway"), r
answer(200, {"jsonrpc": "2.0", "id": 1, "result": {"tools": [{"name": "other___Thing"}]}})
assert run("us-east-1", GW)["status"] == "no-target"
# a gateway that does not exist (AWS says so before it checks the permission: HTTP 404, MCP error -32004)
answer(404, {"jsonrpc": "2.0", "id": 1, "error": {"code": -32004, "message": "Resource not found - Requested gateway does not exist"}})
r = run("us-east-1", GW); assert (r["status"], r["why"]) == ("no-gateway", "not found"), r
answer(500, "boom")
r = run("us-east-1", GW); assert r["status"] == "unverified" and "HTTP 500" in r["why"], r
# no gateway given: one found in the region (READY, IAM sign-in, MCP), or none, or this key may not list them
answer(200, tools)
boto3.STATE["gateways"] = [{"gatewayId": "other-gw", "status": "CREATING", "authorizerType": "AWS_IAM", "protocolType": "MCP"},
                           {"gatewayId": "jwt-gw", "status": "READY", "authorizerType": "CUSTOM_JWT", "protocolType": "MCP"},
                           {"gatewayId": "devos-ade-web-search-abc123def4", "status": "READY", "authorizerType": "AWS_IAM", "protocolType": "MCP"}]
r = run("us-east-1"); assert (r["status"], r["url"]) == ("ready", GW), r
boto3.STATE["gateways"] = []
r = run("eu-west-1"); assert (r["status"], r["why"], r["region"]) == ("no-gateway", "none in eu-west-1", "eu-west-1"), r
boto3.STATE["list"] = "denied"
r = run("us-east-1"); assert (r["status"], r["why"], r["account"]) == ("no-gateway", "bedrock-agentcore:ListGateways", "111122223333"), r
# not a gateway URL, no credentials: said, never a crash
assert run("us-east-1", "https://evil.example/mcp")["status"] == "no-gateway"
boto3.STATE["creds"] = False
assert run("us-east-1", GW)["status"] == "unverified"
# what it prints: no line break, no quote, no backslash in a value
out = io.StringIO()
with contextlib.redirect_stdout(out):
    p.say(why="a\nb \"c\" \\d")
assert out.getvalue() == "why=a b '"'"'c'"'"' /d\n", out.getvalue()
'
}

# the hook's web_search: LiteLLM's interception for Bedrock and OpenRouter with the search tool web-search; the request
# Claude Code's WebSearch makes, answered by the search alone, keeps Anthropic's search tool for LiteLLM to answer with
# its blocks (LiteLLM 1.105.0 has made it its own tool by then: Claude Code counted no search); nothing else changed
test_litellm_hook_web_search_keeps_anthropics_blocks_for_the_search_alone() {
  command -v python3 >/dev/null 2>&1 || return 77
  mkdir -p "$TMP/h/litellm/integrations/websearch_interception"
  printf '' > "$TMP/h/litellm/__init__.py"; printf '' > "$TMP/h/litellm/integrations/__init__.py"
  printf 'class CustomLogger:\n    pass\n' > "$TMP/h/litellm/integrations/custom_logger.py"
  printf '' > "$TMP/h/litellm/integrations/websearch_interception/__init__.py"
  cat > "$TMP/h/litellm/integrations/websearch_interception/handler.py" <<'PY'
WEBSEARCH_EMIT_NATIVE_BLOCKS_KEY = "_websearch_interception_emit_native_blocks"
class WebSearchInterceptionLogger:
    def __init__(self, enabled_providers=None, search_tool_name=None, max_agentic_loops=None):
        self.enabled_providers, self.search_tool_name = enabled_providers, search_tool_name
    async def try_short_circuit_search(self, model, messages, tools, custom_llm_provider, kwargs=None):
        return {"model": model, "tools": tools, "provider": custom_llm_provider}
PY
  printf 'def is_anthropic_native_web_search_tool(t):\n    return str(t.get("type", "")).startswith("web_search_")\n' > "$TMP/h/litellm/integrations/websearch_interception/tools.py"
  cp "$STACK_DIR/lib/litellm-hooks/bn_hooks.py" "$TMP/h/bn_hooks.py"
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, bn_hooks as h
w = h.web_search
assert (w.enabled_providers, w.search_tool_name) == (["bedrock", "openrouter"], "web-search"), vars(w)
ours = {"name": "litellm_web_search", "input_schema": {"type": "object"}}
native = {"type": "web_search_20250305", "name": "web_search"}
go = lambda tools, kw: asyncio.run(w.try_short_circuit_search("gpt-x", [], tools, "bedrock", kwargs=kw))["tools"]
mark = {"_websearch_interception_emit_native_blocks": True}
assert go([ours], mark) == [ours, native]          # made LiteLLM s own: Anthropic s search added back, for its blocks
assert go([ours], {}) == [ours] and go([ours], None) == [ours]   # a request that never had it: as it came
assert go([native], mark) == [native] and go([], mark) == [] and go(None, mark) is None
'
  # another LiteLLM, without the interception: None, never an error at import (the pinned one, 1.105.0, has it)
  rm -rf "$TMP/h/litellm/integrations/websearch_interception"
  PYTHONPATH="$TMP/h" python3 -c 'import bn_hooks as h; assert h.web_search is None'
}

# the Code page's WebSearch card links the hook's sentence to where a backend is set up (code/web: ToolCard.tsx
# WEB_SEARCH_OFF): the sentence the hook writes is the one it looks for
test_the_code_page_knows_the_hooks_sentence() {
  command -v python3 >/dev/null 2>&1 || return 77
  python3 -I - "$STACK_DIR/code/web/src/components/ToolCard.tsx" "$STACK_DIR/lib/litellm-hooks/bn_hooks.py" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.search(r"export const WEB_SEARCH_OFF = /(.+)/;", src).group(1)
hook = re.search(r'^WEB_SEARCH_OFF = "(.+)"$', open(sys.argv[2], encoding="utf-8").read(), re.M).group(1)
for model in ("gpt-6-luna", "or/openai/gpt-oss-120b:free", "claude-haiku-5-5"):
    assert re.search(pat, hook.format(model=model)), (pat, hook)
PY
}

# --- the built-in SearXNG (the default): auto's last choice, its settings, its container, its secret ---

test_the_built_in_searxng_is_the_default_without_a_key() {
  WS_BUILTIN='' _ws_env   # (blank: the default, on)
  assert_eq "$(websearch_backend)" builtin
  cfg="$(_render)"
  assert_contains "$cfg" "$(printf 'search_tools:\n  - search_tool_name: "web-search"\n    litellm_params:\n      search_provider: "searxng"\n      api_base: "http://searxng:8080"\n      timeout: 15')"
  assert_contains "$cfg" '  callbacks: ["bn_hooks.proxy_handler_instance", "bn_hooks.web_search"]'
  printf '%s\n' "$cfg" > "$TMP/c.yaml"; litellm_config_safe "$TMP/c.yaml"
  websearch_write_json "$TMP/ws.json"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))
assert (d["backend"], d["name"], d["provider"], d["usd_per_query"], d["choice"]) == ("builtin", "built-in SearXNG", "searxng", 0, "auto"), d
assert d["reason"] == "auto: no key set up, so the built-in SearXNG" and d["set_up"] == ["builtin"], d
assert d["builtin"] == {"state": "on", "engines": ["startpage", "yahoo", "yep", "mojeek"]}, d["builtin"]' "$TMP/ws.json"
  out="$(NO_COLOR=1 websearch_status)"
  assert_contains "$out" "Web search for Claude Code: built-in SearXNG (free; not checked)"
  assert_contains "$out" "Sent        only the search query, to the built-in SearXNG (a container only LiteLLM reaches) and from there to Startpage, Yahoo, Yep and Mojeek, from this computer's internet address: they may rate-limit it"
  assert_contains "$out" "Cost        free; booked on the LiteLLM key"
  assert_contains "$out" "Why         auto: no key set up, so the built-in SearXNG"
  assert_contains "$out" "Backend     WEBSEARCH_BACKEND=auto: agentcore – tavily – brave – perplexity – searxng – builtin ✓ (in use)"
  assert_contains "$out" "Built-in    SearXNG on (WEBSEARCH_SEARXNG_BUILTIN): free, no key; it asks Startpage, Yahoo, Yep and Mojeek"
  assert_contains "$(websearch_summary_line)" "Web search      built-in SearXNG for Claude Code's WebSearch"
  assert_eq "$(websearch_fix builtin)" ""   # nothing to do while it works
  # on by name too (what setup writes)
  set_env WEBSEARCH_SEARXNG_BUILTIN on; assert_eq "$(websearch_backend)" builtin
  # the hook: a search booked at $0 (searxng/search), WebSearch never said to be unavailable
  assert_eq "$(sed -n 's/.*"usd_per_query": \([0-9.]*\),.*/\1/p' "$TMP/ws.json")" 0
}

test_auto_takes_what_you_set_up_first_and_the_built_in_searxng_last() {
  WS_BUILTIN=on _ws_env
  assert_eq "$(websearch_backend)" builtin
  set_env WEBSEARCH_SEARXNG_URL https://search.example.org
  assert_eq "$(websearch_backend)" searxng; assert_eq "$(websearch_reason)" "auto: your SearXNG's address (no AgentCore gateway or search key set up)"
  set_env WEBSEARCH_PERPLEXITY_API_KEY "$KEY"; assert_eq "$(websearch_backend)" perplexity
  set_env WEBSEARCH_BRAVE_API_KEY "$KEY"; assert_eq "$(websearch_backend)" brave
  set_env WEBSEARCH_TAVILY_API_KEY "$KEY"; assert_eq "$(websearch_backend)" tavily
  assert_eq "$(websearch_reason)" "auto: your Tavily key, the first one set up"
  set_env WEBSEARCH_AGENTCORE_GATEWAY "$GW"; assert_eq "$(websearch_backend)" agentcore
  assert_eq "$(websearch_reason)" "auto: AgentCore Web Search comes first while its gateway is usable"
  # AgentCore's gateway unusable (its check: this key may not use it): the next one
  _probe_says "status=denied
url=$GW
why=bedrock-agentcore:InvokeGateway"
  websearch_before_render --force; assert_eq "$(websearch_backend)" tavily
  for k in WEBSEARCH_AGENTCORE_GATEWAY WEBSEARCH_TAVILY_API_KEY WEBSEARCH_BRAVE_API_KEY WEBSEARCH_PERPLEXITY_API_KEY WEBSEARCH_SEARXNG_URL; do set_env "$k" ''; done
  rm -rf "$(websearch_state_dir)"
  assert_eq "$(websearch_backend)" builtin
  # by name: the built-in one even with a key set up; off: none, the built-in one on or not
  set_env WEBSEARCH_TAVILY_API_KEY "$KEY"; set_env WEBSEARCH_BACKEND builtin
  assert_eq "$(websearch_backend)" builtin; assert_eq "$(websearch_reason)" "chosen: WEBSEARCH_BACKEND=builtin"
  set_env WEBSEARCH_BACKEND off; assert_eq "$(websearch_backend)" ""; assert_not_contains "$(_render)" search_tools
  assert_eq "$(websearch_fix "")" ""
  # the built-in one off: auto has only what you set up; by name, none (and why)
  set_env WEBSEARCH_BACKEND auto; set_env WEBSEARCH_SEARXNG_BUILTIN off
  assert_eq "$(websearch_backend)" tavily
  set_env WEBSEARCH_TAVILY_API_KEY ''; assert_eq "$(websearch_backend)" ""
  assert_contains "$(websearch_why_none)" "; the built-in SearXNG is off (WEBSEARCH_SEARXNG_BUILTIN=off)"
  assert_contains "$(NO_COLOR=1 websearch_status)" "Built-in    SearXNG off (WEBSEARCH_SEARXNG_BUILTIN=off): no container"
  set_env WEBSEARCH_BACKEND builtin; assert_eq "$(websearch_backend)" ""
  assert_eq "$(websearch_why_none)" "WEBSEARCH_BACKEND=builtin, and the built-in SearXNG is off (WEBSEARCH_SEARXNG_BUILTIN=off)"
  # any spelling of off is off; anything else (a typo included) leaves it on
  for v in OFF false 0 no; do set_env WEBSEARCH_SEARXNG_BUILTIN "$v"; ! websearch_builtin_on || { echo "on with $v" >&2; return 1; }; done
  for v in on true yes '' bogus; do set_env WEBSEARCH_SEARXNG_BUILTIN "$v"; websearch_builtin_on || { echo "off with $v" >&2; return 1; }; done
}

test_the_built_in_searxngs_settings_file() {
  WS_BUILTIN='' _ws_env
  websearch_searxng_write "$TMP/sx"
  assert_eq "$(perm_of "$TMP/sx")" 755
  assert_eq "$(perm_of "$TMP/sx/settings.yml")" 644
  assert_eq "$(perm_of "$TMP/sx/limiter.toml")" 644
  f="$(cat "$TMP/sx/settings.yml")"
  assert_not_contains "$f" secret_key   # (from its environment only)
  assert_contains "$f" "keep_only: [startpage, yahoo, yep, mojeek]"
  # keyless engines only, none of those that refused a server in testing (lib/websearch.sh WEBSEARCH_SEARXNG_ENGINES)
  assert_eq "$WEBSEARCH_SEARXNG_ENGINES" "startpage yahoo yep mojeek"
  for e in google bing duckduckgo brave qwant wikipedia dogpile 'google cse' 'yandex api' 'wolframalpha_api' marginalia; do
    assert_not_contains " $WEBSEARCH_SEARXNG_ENGINES " " $e "
  done
  if python3 -I -c 'import yaml' 2>/dev/null; then
    python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1]))
assert d["search"]["formats"] == ["html", "json"] and d["search"]["autocomplete"] == "" and d["search"]["favicon_resolver"] == "", d["search"]
assert d["server"] == {"limiter": False, "public_instance": False, "image_proxy": False, "method": "GET"}, d["server"]
assert d["outgoing"] == {"request_timeout": 4.0, "max_request_timeout": 8.0, "retries": 1}, d["outgoing"]
assert d["use_default_settings"] == {"engines": {"keep_only": ["startpage", "yahoo", "yep", "mojeek"]}}, d["use_default_settings"]
assert d["engines"] == [{"name": e, "disabled": False, "inactive": False} for e in ("startpage", "yahoo", "yep", "mojeek")], d["engines"]
assert d["general"]["enable_metrics"] is False and d["valkey"] == {"url": False}, d' "$TMP/sx/settings.yml"
  fi
  # the same settings: the file is left as it is (its checksum, which compose sees, too)
  touch -t 202001010000 "$TMP/sx/settings.yml"; before="$(ls -l "$TMP/sx/settings.yml")"
  websearch_searxng_write "$TMP/sx"; assert_eq "$(ls -l "$TMP/sx/settings.yml")" "$before"
  # LiteLLM bounds the whole search well under Claude Code's patience, SearXNG each engine under that
  [ "${WEBSEARCH_SEARXNG_TIMEOUT%.*}" -lt "${WEBSEARCH_SEARXNG_MAX_TIMEOUT%.*}" ] && [ "${WEBSEARCH_SEARXNG_MAX_TIMEOUT%.*}" -lt "$WEBSEARCH_SEARXNG_LITELLM_TIMEOUT" ]
  # render_config writes the checkout's own (searxng/ next to litellm/), whether it is on or not
  render_config "" >/dev/null 2>&1
  assert_eq "$(cat "$TMP/searxng/settings.yml")" "$f"
  ls "$TMP/litellm/config.yaml" >/dev/null
}

# dc() — the "searxng" profile while it is on, the settings' checksum in compose's environment (a changed file recreates
# it); ./stack up's services; off: no profile, no service, and its container removed
test_the_built_in_searxngs_container_follows_its_switch() {
  WS_BUILTIN='' _ws_env
  docker() { printf '%s | sum=%s\n' "$*" "${BN_SEARXNG_SETTINGS_SUM:-}" >> "$TMP/docker"; case "$*" in *" ps -aq searxng") [ ! -f "$TMP/running" ] || echo abc123 ;; esac; }
  websearch_searxng_write
  dc ps >/dev/null
  assert_contains "$(cat "$TMP/docker")" "--profile searxng --env-file"
  assert_contains "$(cat "$TMP/docker")" " | sum=$(cksum < "$TMP/searxng/settings.yml" | awk '{ print $1 }')"
  assert_contains " $(optional_services) " " searxng "
  assert_eq "$(websearch_builtin_services)" searxng
  assert_contains "$(status_url searxng)" "the built-in web search, LiteLLM's alone"
  # (a shell's WEBSEARCH_SEARXNG_BUILTIN never decides: .env does)
  : > "$TMP/docker"; WEBSEARCH_SEARXNG_BUILTIN=off dc ps >/dev/null; assert_contains "$(cat "$TMP/docker")" "--profile searxng"
  set_env WEBSEARCH_SEARXNG_BUILTIN off
  : > "$TMP/docker"; dc ps >/dev/null
  assert_not_contains "$(cat "$TMP/docker")" "searxng"
  assert_not_contains " $(optional_services) " " searxng "
  # off: its container goes, named with the profile on; none there: nothing removed
  : > "$TMP/docker"; websearch_builtin_down
  assert_not_contains "$(cat "$TMP/docker")" "rm -sf"
  : > "$TMP/running"; : > "$TMP/docker"; websearch_builtin_down
  assert_contains "$(cat "$TMP/docker")" "--profile searxng --env-file $ENV_FILE rm -sf searxng"
  # websearch_builtin_up: off → removed; on → started (its secret made first, when there is none)
  run_phase() { shift 2; "$@"; }
  : > "$TMP/docker"; websearch_builtin_up 2>/dev/null
  assert_contains "$(cat "$TMP/docker")" "rm -sf searxng"
  assert_eq "$(get_env WEBSEARCH_SEARXNG_SECRET)" ""
  set_env WEBSEARCH_SEARXNG_BUILTIN on; : > "$TMP/docker"; websearch_builtin_up 2>/dev/null
  assert_contains "$(cat "$TMP/docker")" "--profile searxng --env-file $ENV_FILE up -d --no-deps --wait searxng"
  [ -z "${WEBSEARCH_SEARXNG_SECRET:-}" ] && [ "$(get_env WEBSEARCH_SEARXNG_SECRET | tr -d '0-9a-f' | wc -c | tr -d ' ')" = 0 ] && [ "$(get_env WEBSEARCH_SEARXNG_SECRET | wc -c | tr -d ' ')" = 64 ]
  # a container that does not start: said, never fatal
  run_phase() { return 1; }
  out="$(websearch_builtin_up 2>&1)"; assert_contains "$out" "the built-in SearXNG did not start — ./stack logs searxng says why"
}

# its secret: made once (setup), kept, in .env and in its container's environment only — never printed by setup, status,
# the checks, ./stack config list or Settings' snapshot, never in its settings file, LiteLLM's config or web-search.json
test_the_built_in_searxngs_secret_is_never_printed() {
  WS_BUILTIN='' _ws_env
  docker() { :; }
  run_phase() { shift 2; "$@"; }
  out="$(websearch_builtin_up 2>&1; websearch_builtin_up 2>&1)"
  sec="$(get_env WEBSEARCH_SEARXNG_SECRET)"
  [ "${#sec}" = 64 ] || { echo "no secret made" >&2; return 1; }
  websearch_builtin_up 2>/dev/null; assert_eq "$(get_env WEBSEARCH_SEARXNG_SECRET)" "$sec"   # kept
  litellm_call() { printf '{"results":[{"url":"https://example.com"}]}' > "$5"; printf 200; }
  render_config "" >/dev/null 2>&1
  out="$out$(websearch_status 2>&1; websearch_status_line 2>&1; websearch_report 2>&1; websearch_after_start --force 2>&1; websearch_json 2>&1; websearch_summary_line 2>&1)"
  . "$T_ROOT/lib/settings.sh"
  out="$out$(config_list 2>&1)"
  settings_snapshot_write >/dev/null 2>&1 || true
  for f in "$TMP/searxng/settings.yml" "$TMP/searxng/limiter.toml" "$TMP/litellm/config.yaml" "$TMP/litellm/web-search.json" "$(settings_snapshot_file)"; do
    [ ! -f "$f" ] || out="$out$(cat "$f")"
  done
  [ -s "$(settings_snapshot_file)" ] || { echo "no settings snapshot written" >&2; return 1; }
  assert_contains "$(cat "$(settings_snapshot_file)")" WEBSEARCH_SEARXNG_SECRET
  assert_not_contains "$out" "$sec"
  assert_not_contains "$out" "${sec:0:16}"
  # an error text that held it (a SearXNG that echoed it): redacted before it is kept or shown
  assert_eq "$(_ws_redact "error near $sec here")" "error near *** here"
  printf '{"error":{"message":"bad %s"}}' "$sec" > "$TMP/b"
  assert_not_contains "$(websearch_classify builtin 500 "$TMP/b")" "$sec"
  # compose: in the searxng service's environment, nowhere else (SearXNG's own placeholder without one: it refuses it)
  assert_eq "$(grep -v '^ *#' "$T_ROOT/compose.yaml" | grep -c 'WEBSEARCH_SEARXNG_SECRET')" 1
  assert_contains "$(cat "$T_ROOT/compose.yaml")" 'SEARXNG_SECRET: ${WEBSEARCH_SEARXNG_SECRET:-ultrasecretkey}'
  for f in "$T_ROOT"/compose.*.yaml; do assert_not_contains "$(cat "$f")" SEARXNG; done
}

test_the_search_check_and_the_status_lines_say_built_in_searxng() {
  WS_BUILTIN='' _ws_env "LITELLM_KEY_SETUP=sk-setup-test
LITELLM_PORT=9
"
  litellm_call() { echo "$*" >> "$TMP/calls"; printf '{"object":"search","results":[{"title":"t","url":"https://example.com","snippet":"s"}]}' > "$5"; printf 200; }
  websearch_search_check
  assert_contains "$(cat "$TMP/calls")" 'sk-setup-test POST /v1/search/web-search {"query":"Amazon Web Services","max_results":1} '
  assert_eq "$(NO_COLOR=1 websearch_status_line)" "Web search for Claude Code: built-in SearXNG (free; checked $(date -u +%Y-%m-%d))"
  assert_eq "$(NO_COLOR=1 websearch_status_line --short)" "built-in SearXNG (free; checked $(date -u +%Y-%m-%d))"
  assert_contains "$(websearch_report 2>&1)" "Web search for Claude Code: on — built-in SearXNG (free); checked: it answers"
  # another engine list: checked again
  WEBSEARCH_SEARXNG_ENGINES="startpage yahoo"; assert_eq "$(websearch_check_state builtin | cut -d "$US" -f1)" unchecked
  WEBSEARCH_SEARXNG_ENGINES="startpage yahoo yep mojeek"; assert_eq "$(websearch_check_state builtin | cut -d "$US" -f1)" ok
  # every engine refusing this computer: no results — said so, with what to do (never "the key")
  litellm_call() { printf '{"object":"search","results":[]}' > "$5"; printf 200; }
  websearch_search_check --force
  assert_eq "$(websearch_check_state builtin | cut -d "$US" -f1,2)" "failed${US}its search engines answered nothing (they may be refusing this computer's address for now)"
  assert_contains "$(NO_COLOR=1 websearch_status_line)" "Web search for Claude Code: built-in SearXNG does not work — its search engines answered nothing"
  assert_contains "$(websearch_fix builtin)" "./stack logs searxng says why"
  assert_contains "$(websearch_fix builtin)" "a Tavily, Brave or Perplexity key gives steadier results"
  # SearXNG down (LiteLLM's 500 for the connection): failed, its words; never "refused the key"
  printf '{"error":{"message":"litellm.APIConnectionError: All connection attempts failed"}}' > "$TMP/b"
  assert_contains "$(websearch_classify builtin 500 "$TMP/b")" "$(printf 'failed\tHTTP 500: ')"
  printf '{"error":{"message":"Unauthorized"}}' > "$TMP/b"
  assert_not_contains "$(websearch_classify builtin 401 "$TMP/b")" "refused the key"
  # ./stack code status prints the same line, short; ./stack status the whole one
  assert_contains "$(cat "$T_ROOT/lib/code.sh")" "printf '  Web search %s\\n' \"\$(websearch_status_line --short)\""
  assert_contains "$(cat "$T_ROOT/lib/commands.sh")" "printf '  %s\\n' \"\$(websearch_status_line)\""
}

# compose.yaml as Docker Compose renders it (no daemon): the service hardened like the others, its networks (LiteLLM and
# SearXNG alone on websearch; SearXNG alone on websearch-out; never the default network, no port), with every overlay on
test_compose_renders_the_built_in_searxng_isolated() {
  [ -n "${BN_REAL_DOCKER:-}" ] && "$BN_REAL_DOCKER" compose version >/dev/null 2>&1 || { echo "no docker compose" >&2; return 77; }
  docker() { case "$*" in *" config --format json") "$BN_REAL_DOCKER" "$@" ;; *) echo "unexpected docker $*" >&2; return 97 ;; esac; }
  mkdir -p "$TMP/ws"
  printf 'POSTGRES_PASSWORD=p\nRUSTFS_ACCESS_KEY=a\nRUSTFS_SECRET_KEY=s\nLITELLM_MASTER_KEY=m\nLITELLM_SALT_KEY=s\nLITELLM_UI_PASSWORD=u\nWEBUI_SECRET_KEY=w\nOPENWEBUI_ADMIN_EMAIL=a@b.c\nOPENWEBUI_ADMIN_PASSWORD=p\nSHARED_MCP_TOKEN=t\nTERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\nSTT_PROVIDER=bedrock\nWEBSEARCH_SEARXNG_SECRET=%s\n' "$TMP/ws" "$(printf 'f%.0s' $(seq 1 64))" > "$ENV_FILE"
  out="$(dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
s = d["services"]; x = s["searxng"]
assert x["image"].startswith("searxng/searxng:20") and "@sha256:" in x["image"], x["image"]
assert x["user"] == "977:977" and x["read_only"] is True and x["cap_drop"] == ["ALL"] and x["security_opt"] == ["no-new-privileges:true"], x
assert x["restart"] == "unless-stopped" and x["pids_limit"] == 128 and int(x["mem_limit"]) == 512 * 1024 * 1024, x
assert sorted(t.split(":")[0] for t in x["tmpfs"]) == ["/tmp", "/var/cache/searxng"], x["tmpfs"]
assert "ports" not in x and "expose" not in x, x
assert sorted(x["networks"]) == ["websearch", "websearch-out"], x["networks"]
assert x["healthcheck"]["test"][-1] == "http://127.0.0.1:8080/healthz", x["healthcheck"]
assert [(v["type"], v["source"].rsplit("/", 1)[-1], v["target"], v.get("read_only")) for v in x["volumes"]] == [("bind", "searxng", "/etc/searxng", True)], x["volumes"]
assert x["environment"]["SEARXNG_SECRET"] == "f" * 64, "the secret from .env"
assert {"host.docker.internal=192.0.2.1", "host.docker.internal=100::1"} <= set(x["extra_hosts"]) or {"host.docker.internal:192.0.2.1"} <= set(x["extra_hosts"]), x["extra_hosts"]
on = lambda n: sorted(k for k, v in s.items() if n in (v.get("networks") or {}))
assert on("websearch") == ["litellm", "searxng"], on("websearch")
assert on("websearch-out") == ["searxng"], on("websearch-out")
assert d["networks"]["websearch"]["internal"] is True and not d["networks"]["websearch-out"].get("internal"), d["networks"]
for name in ("terminal", "code", "subs-chat", "portal", "open-webui", "caddy", "shared-mcp", "stt", "terminal-gateway", "terminal-egress"):
    assert not set(s[name].get("networks") or {}) & {"websearch", "websearch-out"}, name
# nothing it could be reached through: no Caddy site names it
'
  for f in "$T_ROOT"/caddy/*; do assert_not_contains "$(cat "$f")" searxng; done
  # without its secret: SearXNG's own placeholder, which it refuses to start with (never an empty key)
  sed -i.bak '/^WEBSEARCH_SEARXNG_SECRET=/d' "$ENV_FILE"
  assert_contains "$(dc config --format json)" '"SEARXNG_SECRET": "ultrasecretkey"'
  # off: no searxng service at all (LiteLLM keeps its empty websearch network)
  printf 'WEBSEARCH_SEARXNG_BUILTIN=off\n' >> "$ENV_FILE"
  out="$(dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); assert "searxng" not in d["services"], sorted(d["services"])'
}

# ./stack up after WEBSEARCH_* was edited by hand in .env (the built-in SearXNG turned off, a key added): LiteLLM's config
# no longer matches — rendered again (and LiteLLM restarted); matching, left alone
test_up_renders_again_when_the_search_backend_changed_by_hand() {
  WS_BUILTIN='' _ws_env
  render_config "" >/dev/null 2>&1
  ! websearch_config_stale || { echo "stale right after a render" >&2; return 1; }
  set_env WEBSEARCH_SEARXNG_BUILTIN off
  websearch_config_stale
  render_config "" >/dev/null 2>&1
  ! websearch_config_stale; assert_not_contains "$(cat "$TMP/litellm/config.yaml")" search_tools
  set_env WEBSEARCH_TAVILY_API_KEY "$KEY"; websearch_config_stale
  render_config "" >/dev/null 2>&1; ! websearch_config_stale
  assert_contains "$(cat "$TMP/litellm/config.yaml")" 'search_provider: "tavily"'
  set_env WEBSEARCH_TAVILY_API_KEY ''; set_env WEBSEARCH_SEARXNG_BUILTIN on; websearch_config_stale
  # (cmd_up does it before the stack comes up)
  assert_contains "$(sed -n '/^cmd_up() {/,/^}/p' "$T_ROOT/lib/commands.sh")" 'if websearch_config_stale; then'
}
