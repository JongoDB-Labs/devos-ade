# shellcheck shell=bash
# The models of the Code page and devos-claude (lib/code_models.sh): every enabled chat model of the catalog and the
# enabled OpenRouter ones, how each fares as Claude Code's model (catalog/code-models.tsv), Settings › Claude Code ›
# Models (CODE_MODELS, CODE_DEFAULT_MODEL), litellm/code-models.tsv and LiteLLM's bn_* model_info.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/openrouter.sh and lib/code_models.sh
FIXJ="$STACK_DIR/tests/fixtures/openrouter_models.json"

# A catalog of its own: two Anthropic models, a Meta one, a Mistral one, an embedder and a speech model; their names,
# prices and compatibility rows; STACK_DIR in $TMP (nothing of this checkout's litellm/ is read or written).
_cm_env() {
  local repo="$STACK_DIR"
  STACK_DIR="$TMP"; mkdir -p "$TMP/litellm" "$TMP/catalog"
  printf 'claude-big\tchat\tbedrock/invoke/us.anthropic.big\t-\t-\nclaude-small\tchat\tbedrock/invoke/us.anthropic.small\t-\t-\nllama-x\tchat\tbedrock/us.meta.llama-x\t-\t-\nmistral-y\tchat\tbedrock/mistral.y\t-\t-\nemb\tembedding\tbedrock/emb\t-\t-\nvox\tstt\tbedrock/vox\t-\t-\n' > "$TMP/cat.tsv"
  printf '# name\tdisplay_name\ticon\ttags\nclaude-big\tClaude Big\t-\tAnthropic\nclaude-small\tClaude Small\t-\tAnthropic\nllama-x\tLlama X\t-\tMeta,Open\nmistral-y\tMistral "Y"\t-\t-\n' > "$TMP/disp.tsv"
  printf '# name\tin\tout\tcr\tcw\timg\tq\nclaude-big\t4.40\t22.00\t0.22\t5.50\t-\t-\nclaude-small\t0.11\t0.55\t0.011\t0.1375\t-\t-\nllama-x\t0.72\t0.72\t-\t-\t-\t-\n' > "$TMP/prices.tsv"
  printf '# pattern\tstatus\tmax_out\tnote\nclaude-*\tworks\t-\tAnthropic.\nllama-x\tchat-only\t8192\tText tool calls.\nor/meta-llama/*\tfails\t4096\tOurs wins.\n' > "$TMP/compat.tsv"
  export CATALOG="$TMP/cat.tsv" CODE_DISPLAY_TSV="$TMP/disp.tsv" PRICES="$TMP/prices.tsv" CODE_COMPAT="$TMP/compat.tsv"
  printf 'CLAUDE_BEDROCK_OPUS_MODEL=claude-big\n%s' "${1:-}" > "$ENV_FILE"
  : "$repo"
}
_or_cache() {
  printf 'OPENROUTER_API_KEY=sk-or-v1-abc\n' >> "$ENV_FILE"
  { printf '# fetched_at: 2026-10-12T00:00:00Z\n'; or_models_tsv < "$FIXJ" | or_classify; } > "$TMP/litellm/openrouter-models.tsv"
}
_col() { awk -F'\t' -v c="$1" -v id="$2" '$1 == id { print $c }'; }

test_rows_every_enabled_chat_model_with_names_vendors_prices_and_compat() {
  _cm_env
  printf 'claude-big\nclaude-small\nllama-x\nmistral-y\nemb\nvox\n' > "$TMP/en"
  out="$(code_models_rows "$TMP/en")"
  assert_eq "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "claude-big claude-small llama-x mistral-y "   # chat only: no embedder, no speech
  assert_eq "$(printf '%s\n' "$out" | _col 0 llama-x | cut -f2-15)" "$(printf 'Llama X\tBedrock\tMeta\t0.72\t0.72\t-\t-\t0\tchat-only\t1\t0\t8192\t-\tText tool calls.')"
  assert_eq "$(printf '%s\n' "$out" | _col 2 mistral-y)" 'Mistral Y'          # quotes never reach YAML or JSON
  assert_eq "$(printf '%s\n' "$out" | _col 4 mistral-y)" Other               # no vendor tag
  assert_eq "$(printf '%s\n' "$out" | _col 5 mistral-y)" -                   # no price
  assert_eq "$(printf '%s\n' "$out" | _col 10 mistral-y)" untested           # no compat row
  assert_eq "$(printf '%s\n' "$out" | _col 12 claude-big)" 1                 # the main model is the default
  printf 'claude-small\nllama-x\n' > "$TMP/en"
  out="$(code_models_rows "$TMP/en")"
  assert_eq "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "claude-small llama-x "
  assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '$12 == 1 { print $1 }')" claude-small   # main not enabled: the first listed
}

test_scope_all_anthropic_and_a_list_and_the_default_always_listed() {
  _cm_env 'CODE_MODELS=anthropic
'
  out="$(code_models_rows "")"
  assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '$11 == 1 { print $1 }' | tr '\n' ' ')" "claude-big claude-small "
  _cm_env 'CODE_MODELS=llama-x, mistral-y ,nope
CODE_DEFAULT_MODEL=claude-small
'
  out="$(code_models_rows "")"
  assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '$11 == 1 { print $1 }' | tr '\n' ' ')" "claude-small llama-x mistral-y "   # + the default
  assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '$12 == 1 { print $1 }')" claude-small
  _cm_env 'CODE_DEFAULT_MODEL=not-enabled
'
  assert_eq "$(code_models_rows "" | awk -F'\t' '$12 == 1 { print $1 }')" claude-big   # not enabled: as blank
  assert_eq "$(CODE_MODELS=x code_models_scope)" all   # .env decides, not the shell
}

test_the_default_is_sonnet_unless_settings_name_one_never_opus_by_default() {
  # (a new session — the Code page's, devos-claude's here and in the browser terminal — starts on Settings' default for
  # new sessions while it names an enabled model, else the Sonnet slot, else the main model)
  _cm_env 'CLAUDE_BEDROCK_SONNET_MODEL=claude-small
'
  printf 'claude-big\nclaude-small\nllama-x\n' > "$TMP/en"
  assert_eq "$(code_models_rows "$TMP/en" | awk -F'\t' '$12 == 1 { print $1 }')" claude-small
  code_models_write "$TMP/en"
  assert_eq "$(code_models_start | tr '\t' ' ')" "claude-small sonnet"
  assert_eq "$(code_models_default)" claude-small
  assert_eq "$(code_models_why sonnet)" "Settings › Claude Code › Default model for new sessions is blank, so the Sonnet slot (CLAUDE_MODEL_SONNET)"
  table="$(code_models_table "")"
  assert_contains "$table" "* claude-small"
  assert_not_contains "$table" "* claude-big"
  assert_contains "$table" "* Default for new sessions: Claude Small (claude-small): Settings › Claude Code › Default model for new sessions is blank, so the Sonnet slot"
  assert_contains "$(CLAUDE_BEDROCK_MODEL=llama-x code_models_table "")" "CLAUDE_BEDROCK_MODEL=llama-x in your environment starts devos-claude on that one instead"
  # LiteLLM's model_info says which and why (the browser terminal's devos-claude --models)
  yaml="$(printf '  - model_name: "claude-small"\n    model_info:\n      mode: "chat"\n' | code_models_inject "$TMP/litellm/code-models.tsv")"
  assert_contains "$yaml" "$(printf '      bn_default: true\n      bn_default_why: "sonnet"')"
  # Settings name one: that one
  printf 'CODE_DEFAULT_MODEL=llama-x\n' >> "$ENV_FILE"
  assert_eq "$(code_models_rows "$TMP/en" | awk -F'\t' '$12 == 1 { print $1 }')" llama-x
  assert_eq "$(code_models_start | tr '\t' ' ')" "llama-x settings"   # (.env now, before ./stack writes the file again)
  assert_eq "$(code_models_why settings)" "Settings › Claude Code › Default model for new sessions (CODE_DEFAULT_MODEL)"
  # one that is not enabled: as blank, said so
  sed -i.bak 's/^CODE_DEFAULT_MODEL=.*/CODE_DEFAULT_MODEL=gone-model/' "$ENV_FILE"
  assert_eq "$(code_models_rows "$TMP/en" | awk -F'\t' '$12 == 1 { print $1 }')" claude-small
  assert_eq "$(code_models_start | tr '\t' ' ')" "claude-small sonnet"
  assert_eq "$(code_models_why sonnet)" "Settings › Claude Code › Default model for new sessions names gone-model, which is not enabled, so the Sonnet slot (CLAUDE_MODEL_SONNET)"
  # no Sonnet enabled: the main model; neither: the first listed
  printf 'claude-big\nllama-x\n' > "$TMP/en"
  sed -i.bak '/^CODE_DEFAULT_MODEL=/d' "$ENV_FILE"
  assert_eq "$(code_models_rows "$TMP/en" | awk -F'\t' '$12 == 1 { print $1 }')" claude-big
  code_models_write "$TMP/en"
  assert_eq "$(code_models_start | tr '\t' ' ')" "claude-big main"
  printf 'llama-x\nmistral-y\n' > "$TMP/en"
  code_models_write "$TMP/en"
  assert_eq "$(code_models_start | tr '\t' ' ')" "llama-x first"
}

test_openrouter_rows_free_at_zero_tools_and_the_output_cap() {
  _cm_env; _or_cache
  out="$(code_models_rows "")"
  free="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "or/google/gemma-4-31b-it:free"')"
  assert_eq "$(printf '%s' "$free" | cut -f2-14)" "$(printf 'Gemma 4 31B (free)\tOpenRouter\tGoogle\t0\t0\t-\t-\t1\tuntested\t1\t0\t32768\t262144')"
  assert_contains "$(printf '%s' "$free" | cut -f15)" "OpenRouter lists tool use"
  paid="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "or/anthropic/claude-haiku-5.5"')"
  assert_eq "$(printf '%s' "$paid" | cut -f4-9)" "$(printf 'Anthropic\t0.1\t0.5\t0.01\t0.125\t0')"
  # a row of ours wins over OpenRouter's (status and cap); no "~" alias ids (the code server refuses them)
  assert_eq "$(printf '%s\n' "$out" | _col 10 or/meta-llama/llama-3.3-70b-instruct)" fails
  assert_eq "$(printf '%s\n' "$out" | _col 13 or/meta-llama/llama-3.3-70b-instruct)" 4096
  assert_not_contains "$out" "~anthropic"
  printf 'OPENROUTER_INCLUDE_ALIASES=true\n' >> "$ENV_FILE"   # listed by OpenRouter's selection, still never a model here
  assert_not_contains "$(code_models_rows "")" "~anthropic"
  sed -i.bak '/^OPENROUTER_INCLUDE_ALIASES=/d' "$ENV_FILE"
  # anthropic scope: OpenRouter's Anthropic models count too
  printf 'CODE_MODELS=anthropic\n' >> "$ENV_FILE"
  assert_eq "$(code_models_rows "" | awk -F'\t' '$11 == 1 && $3 == "OpenRouter" { print $1 }')" "or/anthropic/claude-haiku-5.5"
  # no key: no OpenRouter rows
  printf 'CLAUDE_BEDROCK_OPUS_MODEL=claude-big\n' > "$ENV_FILE"
  assert_not_contains "$(code_models_rows "")" "or/"
}

test_write_inject_resolve_and_the_picker() {
  _cm_env; _or_cache
  code_models_write ""
  f="$TMP/litellm/code-models.tsv"
  assert_eq "$(sed -n 2p "$f")" "# scope: all"
  assert_eq "$(ls -l "$f" | cut -c1-10)" "-rw-r--r--"
  # LiteLLM's model_info: the bn_* keys after each chat model's mode
  yaml="$(printf '  - model_name: "llama-x"\n    model_info:\n      mode: "chat"\n  - model_name: "emb"\n    model_info:\n      mode: "embedding"\n  - model_name: "or/google/gemma-4-31b-it:free"\n    model_info:\n      mode: "chat"\n' | code_models_inject "$f")"
  assert_contains "$yaml" "$(printf '      mode: "chat"\n      bn_id: "llama-x"\n      bn_name: "Llama X"\n      bn_vendor: "Meta"\n      bn_compat: "chat-only"\n      bn_code: true\n  - model_name: "emb"')"
  assert_contains "$yaml" "$(printf '      bn_name: "Gemma 4 31B (free)"\n      bn_vendor: "Google"\n      bn_compat: "untested"\n      bn_code: true')"
  assert_eq "$(printf '%s\n' "$yaml" | grep -c 'bn_default: true')" 0   # claude-big is the default, not in this YAML
  assert_eq "$(code_model_resolve claude-big)" claude-big
  assert_eq "$(code_model_resolve 'LLAMA X')" llama-x
  assert_eq "$(code_model_resolve google/gemma-4-31b-it:free)" or/google/gemma-4-31b-it:free
  assert_eq "$(code_model_resolve opus)" claude-big
  assert_eq "$(code_model_resolve nope)" ""
  assert_eq "$(code_models_default)" claude-big
  j="$(code_picker_json "" 1)"
  printf '%s' "$j" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); o = d["modelPicker"]["options"]
assert d["disableAutoMode"] == "disable" and d["modelPicker"]["replaceBuiltInOptions"] is True, d
assert o[0] == {"model": "claude-big", "label": "Claude Big", "description": "Anthropic · $4.40/$22.00 per 1M · works"}, o[0]
assert {"model": "or/google/gemma-4-31b-it:free", "label": "Gemma 4 31B (free) · OpenRouter", "description": "Google · free ($0) · not tested"} in o'
  assert_not_contains "$(code_picker_json "" 0)" disableAutoMode
  # at most CODE_PICKER_MAX rows, the default always among them
  CODE_PICKER_MAX=3 code_picker_json "" 0 | python3 -I -c 'import json, sys; o = json.load(sys.stdin)["modelPicker"]["options"]; assert len(o) == 3 and o[0]["model"] == "claude-big", o'
  table="$(code_models_table "")"
  assert_contains "$table" "* claude-big"
  assert_contains "$table" "chat only (no tools) · Meta on Bedrock"
}

test_render_config_writes_the_file_and_litellm_gets_the_bn_keys_and_the_hook() {
  _cm_env 'CODE_MODELS=claude-small
'
  printf 'AWS_REGION_NAME=us-east-1\n' >> "$ENV_FILE"
  printf 'claude-big\nclaude-small\nllama-x\n' > "$TMP/en"
  mkdir -p "$TMP/lib/litellm-hooks"; printf '# the hook\n' > "$TMP/lib/litellm-hooks/bn_hooks.py"
  render_config "$TMP/en"
  assert_eq "$(cat "$TMP/litellm/bn_hooks.py")" "# the hook"   # copied next to the config that names it
  assert_eq "$(ls -l "$TMP/litellm/bn_hooks.py" | cut -c1-10)" "-rw-r--r--"
  cfg="$(cat "$TMP/litellm/config.yaml")"
  assert_contains "$cfg" "$(printf '      bn_id: "claude-big"\n      bn_name: "Claude Big"\n      bn_vendor: "Anthropic"\n      bn_compat: "works"\n      bn_code: true\n      bn_default: true')"
  assert_contains "$cfg" "$(printf '      bn_name: "Llama X"\n      bn_vendor: "Meta"\n      bn_compat: "chat-only"\n      bn_code: false')"
  # (the hook, and with the built-in SearXNG — on by default — LiteLLM's web search interception as the hook has it)
  assert_contains "$cfg" '  callbacks: ["bn_hooks.proxy_handler_instance", "bn_hooks.web_search"]'
  assert_eq "$(_code_rows "$TMP/litellm/code-models.tsv" | awk -F'\t' '$11 == 1 { print $1 }' | tr '\n' ' ')" "claude-big claude-small "
  rm "$TMP/lib/litellm-hooks/bn_hooks.py"
  render_config "$TMP/en"
  assert_not_contains "$(cat "$TMP/litellm/config.yaml")" callbacks   # no hook source, no hook (LiteLLM would not start)
}

test_validators_for_the_settings() {
  for v in '' all anthropic claude-big 'claude-big,or/google/gemma-4-31b-it:free' 'llama-x,mistral-y'; do valid_code_models "$v" || { echo "refused: $v" >&2; return 1; }; done
  for v in ',a' 'a,' 'a,,b' 'a b' 'a;b' 'a"b'; do ! valid_code_models "$v" || { echo "taken: $v" >&2; return 1; }; done
  for v in '' claude-big or/google/gemma-4-31b-it:free; do valid_code_model "$v" || { echo "refused: $v" >&2; return 1; }; done
  for v in '-x' 'a b' 'a,b' "$(printf 'x%.0s' $(seq 1 129))"; do ! valid_code_model "$v" || { echo "taken: $v" >&2; return 1; }; done
  . "$STACK_DIR/lib/settings.sh"
  setting_validate CODE_MODELS 'anthropic' && setting_validate CODE_DEFAULT_MODEL 'or/x/y:free'
  ! setting_validate CODE_MODELS 'a b'
  assert_contains "$SV_ERR" "CODE_MODELS must be all, anthropic or a comma list of model ids"
}

# the hook: max_tokens lowered to a model's limit from code-models.tsv, nothing else, never an error
test_litellm_hook_caps_max_tokens_from_code_models() {
  command -v python3 >/dev/null 2>&1 || return 77
  mkdir -p "$TMP/h/litellm/integrations"
  printf '' > "$TMP/h/litellm/__init__.py"; printf '' > "$TMP/h/litellm/integrations/__init__.py"
  printf 'class CustomLogger:\n    pass\n' > "$TMP/h/litellm/integrations/custom_logger.py"
  cp "$STACK_DIR/lib/litellm-hooks/bn_hooks.py" "$TMP/h/bn_hooks.py"
  printf '# x\n# id\nllama-x\tL\tBedrock\tMeta\t1\t1\t-\t-\t0\tchat-only\t1\t0\t8192\t-\t-\nclaude-big\tC\tBedrock\tAnthropic\t1\t1\t-\t-\t0\tworks\t1\t1\t-\t-\t-\n' > "$TMP/h/code-models.tsv"
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, bn_hooks as h
d = asyncio.run(h.proxy_handler_instance.async_pre_call_hook(None, None, {"model": "llama-x", "max_tokens": 32000, "thinking": {"type": "enabled", "budget_tokens": 16000}}, "anthropic_messages"))
assert d["max_tokens"] == 8192 and d["thinking"]["budget_tokens"] == 4096, d
assert h.cap_request({"model": "llama-x", "max_tokens": 100})["max_tokens"] == 100
assert h.cap_request({"model": "claude-big", "max_tokens": 64000})["max_tokens"] == 64000
assert h.cap_request({"model": "llama-x", "max_completion_tokens": 9000})["max_completion_tokens"] == 8192
assert asyncio.run(h.proxy_handler_instance.async_pre_call_hook(None, None, {"model": ["odd"], "max_tokens": "x"}, "x")) == {"model": ["odd"], "max_tokens": "x"}
assert asyncio.run(h.proxy_handler_instance.async_pre_call_hook(None, None, None, "x")) is None
'
}

# the hook: Claude Code's running token count after a tool result left out for another vendor's model on Bedrock
# (LiteLLM would make it an "Operator note" after the result, which GPT-6 sometimes answers with nothing); kept for
# Claude, for OpenRouter and for a model the file does not list; every other message as it came
test_litellm_hook_drops_token_counts_for_other_vendors_on_bedrock() {
  command -v python3 >/dev/null 2>&1 || return 77
  mkdir -p "$TMP/h/litellm/integrations"
  printf '' > "$TMP/h/litellm/__init__.py"; printf '' > "$TMP/h/litellm/integrations/__init__.py"
  printf 'class CustomLogger:\n    pass\n' > "$TMP/h/litellm/integrations/custom_logger.py"
  cp "$STACK_DIR/lib/litellm-hooks/bn_hooks.py" "$TMP/h/bn_hooks.py"
  { printf '# x\n# id\n'
    printf 'gpt-x\tG\tBedrock\tOpenAI\t1\t1\t-\t-\t0\tworks\t1\t0\t-\t-\t-\n'
    printf 'claude-big\tC\tBedrock\tAnthropic\t1\t1\t-\t-\t0\tworks\t1\t1\t-\t-\t-\n'
    printf 'or/a/b\tO\tOpenRouter\ta\t1\t1\t-\t-\t0\tuntested\t1\t0\t-\t-\t-\n'; } > "$TMP/h/code-models.tsv"
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, copy, bn_hooks as h
env = "# Environment\nPlatform: linux\n\n<total_tokens>15000000 tokens left</total_tokens>"
msgs = [{"role": "user", "content": [{"type": "text", "text": "run echo hi"}]},
        {"role": "system", "content": env},
        {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "echo hi"}}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "hi"}]},
        {"role": "system", "content": "<total_tokens>14984242 tokens left</total_tokens>"},
        {"role": "assistant", "content": "hi"},
        {"role": "user", "content": "again"},
        {"role": "system", "content": [{"type": "text", "text": "\n<total_tokens>14000000 tokens left</total_tokens>\n"}]}]
run = lambda d: asyncio.run(h.proxy_handler_instance.async_pre_call_hook(None, None, d, "anthropic_messages"))
d = run({"model": "gpt-x", "max_tokens": 32000, "messages": copy.deepcopy(msgs)})
assert d["messages"] == [msgs[i] for i in (0, 1, 2, 3, 5, 6)] and d["max_tokens"] == 32000, d   # the environment stays
for model in ("claude-big", "or/a/b", "unlisted"):
    assert run({"model": model, "messages": copy.deepcopy(msgs)})["messages"] == msgs, model
# a count as the first message, among other text, with a second block, or from the user: kept
other = [{"role": "system", "content": "<total_tokens>1 tokens left</total_tokens>"}, msgs[0],
         {"role": "system", "content": "<total_tokens>1 tokens left</total_tokens> and more"},
         {"role": "system", "content": [{"type": "text", "text": "<total_tokens>1 tokens left</total_tokens>"}, {"type": "text", "text": "x"}]},
         {"role": "user", "content": "<total_tokens>1 tokens left</total_tokens>"}]
assert run({"model": "gpt-x", "messages": copy.deepcopy(other)})["messages"] == other
# odd shapes: unchanged, never an error
for d in ({"model": "gpt-x", "messages": "x"}, {"model": "gpt-x", "messages": [None, 3, {"role": "system"}, {"role": "system", "content": [None]}]},
          {"model": ["gpt-x"], "messages": msgs}):
    assert run(copy.deepcopy(d)) == d, d
'
}

_hook_models() {
  mkdir -p "$TMP/h/litellm/integrations"
  printf '' > "$TMP/h/litellm/__init__.py"; printf '' > "$TMP/h/litellm/integrations/__init__.py"
  printf 'class CustomLogger:\n    pass\n' > "$TMP/h/litellm/integrations/custom_logger.py"
  cp "$STACK_DIR/lib/litellm-hooks/bn_hooks.py" "$TMP/h/bn_hooks.py"
  { printf '# x\n# id\n'
    printf 'gpt-x\tG\tBedrock\tOpenAI\t1\t1\t-\t-\t0\tworks\t1\t0\t-\t-\t-\n'
    printf 'claude-big\tC\tBedrock\tAnthropic\t1\t1\t-\t-\t0\tworks\t1\t1\t-\t-\t-\n'
    printf 'or/a/b\tO\tOpenRouter\ta\t1\t1\t-\t-\t0\tuntested\t1\t0\t-\t-\t-\n'
    printf 'xl/q\tQ\tExperiential Labs\tQwen\t1\t1\t-\t-\t0\tuntested\t1\t0\t-\t-\t-\n'; } > "$TMP/h/code-models.tsv"
}

# the hook: the Read tool's image, which Bedrock's Converse refuses inside a tool result for another vendor's model
# ("This model doesn't support the image field for user messages"), moved after the results in the same user message,
# under a line naming its call; the results' text, their order and every other block kept; Claude, OpenRouter and
# Experiential Labs (LiteLLM moves it itself for an OpenAI-shaped provider) unchanged
test_litellm_hook_moves_tool_result_images_for_other_vendors_on_bedrock() {
  command -v python3 >/dev/null 2>&1 || return 77
  _hook_models
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, copy, bn_hooks as h
img = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="}}
msgs = [{"role": "user", "content": "look at red.png and a.txt"},
        {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "red.png"}},
                                          {"type": "tool_use", "id": "t2", "name": "Read", "input": {"file_path": "a.txt"}}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": [img], "cache_control": {"type": "ephemeral"}},
                                     {"type": "tool_result", "tool_use_id": "t2", "content": [{"type": "text", "text": "alpha"}, img]},
                                     {"type": "text", "text": "<system-reminder>x</system-reminder>"}]}]
run = lambda d: asyncio.run(h.proxy_handler_instance.async_pre_call_hook(None, None, d, "anthropic_messages"))
out = run({"model": "gpt-x", "max_tokens": 9, "messages": copy.deepcopy(msgs)})["messages"]
assert out[:2] == msgs[:2], out
assert out[2]["content"] == [
    {"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "(its image is in the message below)"}], "cache_control": {"type": "ephemeral"}},
    {"type": "tool_result", "tool_use_id": "t2", "content": [{"type": "text", "text": "alpha"}]},
    {"type": "text", "text": "[The image output of tool call t1]"}, img,
    {"type": "text", "text": "[The image output of tool call t2]"}, img,
    {"type": "text", "text": "<system-reminder>x</system-reminder>"}], out[2]
for model in ("claude-big", "or/a/b", "xl/q", "unlisted"):
    assert run({"model": model, "messages": copy.deepcopy(msgs)})["messages"] == msgs, model
# no image, a string result, odd shapes: as they came
for m in ([{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": "text"}]}],
          [{"role": "user", "content": [{"type": "tool_result", "content": [None, 3]}]}], [None, "x", {"role": "user"}]):
    assert run({"model": "gpt-x", "messages": copy.deepcopy(m)})["messages"] == m, m
'
}

# the hook: Claude Code's WebSearch (Anthropic's web_search tool, which the provider runs) for a model whose provider runs
# none — Bedrock's (LiteLLM refuses it for Claude; another vendor's model answered from memory as though it had
# searched) and OpenRouter's — becomes a request for one plain sentence saying so: no tools, no thinking, a short answer
# (the WebSearch tool hands it to the model as its result); Experiential Labs (the gateway searches) and other requests
# as they came
test_litellm_hook_says_web_search_is_not_available() {
  command -v python3 >/dev/null 2>&1 || return 77
  _hook_models
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, copy, bn_hooks as h
ws = {"type": "web_search_20250305", "name": "web_search", "max_uses": 8}
req = {"max_tokens": 32000, "stream": True, "system": [{"type": "text", "text": "You are an assistant for performing a web search tool use"}],
       "messages": [{"role": "user", "content": "Perform a web search for the query: IANA example domain"}],
       "tools": [ws], "tool_choice": {"type": "auto"}, "thinking": {"type": "enabled", "budget_tokens": 2048}, "metadata": {"user_id": "u"}}
run = lambda d: asyncio.run(h.proxy_handler_instance.async_pre_call_hook(None, None, d, "anthropic_messages"))
for model in ("gpt-x", "claude-big", "or/a/b"):
    out = run({**copy.deepcopy(req), "model": model})
    line = f"Web search isn'"'"'t available for {model} in DevOS ADE. Use WebFetch with a URL."
    assert out == {"model": model, "max_tokens": 200, "stream": True, "metadata": {"user_id": "u"},
                   "system": "No web search can run here. Reply with exactly the line between the markers, word for word, and nothing else.\n<<<\n" + line + "\n>>>",
                   "messages": [{"role": "user", "content": "Reply now."}]}, out
# the gateway that searches, a model the file does not list, other tools (also next to web_search: a session turn is
# never replaced), no tools, odd shapes: as they came
read = {"name": "Read", "input_schema": {"type": "object"}}
for d in ({**req, "model": "xl/q"}, {**req, "model": "unlisted"}, {**req, "model": "gpt-x", "tools": [read]},
          {**req, "model": "gpt-x", "tools": [read, ws]}, {**req, "model": "claude-big", "tools": [ws, read]}, {**req, "model": "gpt-x", "tools": []},
          {**req, "model": "gpt-x", "tools": "web_search"}, {**req, "model": "gpt-x", "tools": [None, 3, {"type": 7}]}, {**req, "model": ["gpt-x"]}):
    assert run(copy.deepcopy(d)) == d, d
assert run(None) is None
'
}

# the hook: Llama on Bedrock — Bedrock hands its tool call back as the text Llama wrote (Meta's documented form), which
# becomes toolUse blocks only when the whole answer is calls of offered tools with every required argument; an unknown
# tool, JSON that does not parse, a word around the call, a call in a code block (one a user asked to see), a missing
# argument or anything not in that form stays text; several calls become several blocks, all or none
test_litellm_hook_reads_llama_tool_calls_written_as_text() {
  command -v python3 >/dev/null 2>&1 || return 77
  _hook_models
  PYTHONPATH="$TMP/h" python3 -c '
import copy, json, re, bn_hooks as h
schema = lambda *req, **props: {"type": "object", "properties": {k: {"type": "string"} for k in (*req, *props)}, "required": list(req)}
tools = {"Bash": schema("command", description=1), "Read": schema("file_path", limit=1), "TaskList": {"type": "object", "properties": {}}}
call = lambda name, args, **kw: json.dumps({"type": "function", "name": name, "parameters": args, **kw})
bash = {"command": "echo $((6*7))", "description": "Calculate the product of 6 and 7"}
read = {"file_path": "/workspace/a.txt", "limit": "2000"}
T = h.text_tool_calls
# what Bedrock returned for Claude Code s requests, as it came; without "type"; Meta s marks around it; white space
assert T(call("Bash", bash), tools) == [("Bash", bash)]
assert T(json.dumps({"name": "Read", "parameters": read}), tools) == [("Read", read)]
assert T("<|python_tag|>" + call("Bash", bash) + "<|eom_id|>", tools) == [("Bash", bash)]
assert T("\n  " + call("TaskList", {}) + "<|eot_id|>\n", tools) == [("TaskList", {})]
assert T("<function=Read>" + json.dumps(read) + "</function>", tools) == [("Read", read)]
# (the values are the model s: Claude Code checks them against the schema, as for any model s call)
assert T(call("Read", {"file_path": {"type": "string", "value": "a.txt"}}), tools) == [("Read", {"file_path": {"type": "string", "value": "a.txt"}})]
# several calls: each a block, in order — apart by white space or one ";" (the <function> form: white space)
two = [("Read", read), ("Read", {"file_path": "b.txt"})]
for text in (call(*two[0]) + "\n" + call(*two[1]), call(*two[0]) + "; " + call(*two[1]), call(*two[0]) + call(*two[1]),
             "<function=Read>" + json.dumps(read) + "</function>\n<function=Read>{\"file_path\": \"b.txt\"}</function>"):
    assert T(text, tools) == two, text
# what stays text
refused = {
    "an unknown tool": call("Delete", {"path": "a.txt"}),
    "a tool of another request": call("Write", {"file_path": "a", "content": "b"}),
    "bad JSON": call("Bash", bash)[:-1],
    "bad JSON in a function tag": "<function=Bash>{\"command\": \"ls\"</function>",
    "words before": "I will run it now: " + call("Bash", bash),
    "words after": call("Bash", bash) + " That prints 42.",
    "words between two calls": call(*two[0]) + " and then " + call(*two[1]),
    "a code block the user asked to see": "```json\n" + call("Bash", bash) + "\n```",
    "a code block alone": "```\n" + call("Bash", bash) + "\n```",
    "a missing argument": call("Bash", {"description": "no command"}),
    "arguments as a string": json.dumps({"type": "function", "name": "Bash", "parameters": json.dumps(bash)}),
    "no arguments": json.dumps({"type": "function", "name": "Bash"}),
    "another field": call("Bash", bash, id="call_1"),
    "another type": json.dumps({"type": "tool", "name": "Bash", "parameters": bash}),
    "OpenAI s shape": json.dumps({"name": "Bash", "arguments": bash}),
    "a list of calls (not Meta s form)": json.dumps([{"name": "Read", "parameters": read}]),
    "one bad call of two": call(*two[0]) + "\n" + call("Delete", {}),
    "a trailing ;": call("Bash", bash) + ";",
    "two ;": call(*two[0]) + ";;" + call(*two[1]),
    "a function tag and words": "<function=Bash>" + json.dumps(bash) + "</function> done",
    "an unknown function tag": "<function=Delete>{}</function>",
    "a plain answer": "42", "a JSON answer": "{\"answer\": 42}", "a string": "\"Bash\"", "nothing": "  ", "a mark alone": "<|python_tag|>",
}
for why, text in refused.items():
    assert T(text, tools) is None, why
assert T(call("Bash", bash), {}) is None and T(None, tools) is None and T(3, tools) is None

# Bedrock s answer: one text block that is the calls, ended there (end_turn) -> toolUse blocks and stopReason tool_use;
# the rest of the answer as it came
spec = lambda name: {"toolSpec": {"name": name, "description": "d", "inputSchema": {"json": tools[name]}}}
request = {"system": [{"text": "s"}], "messages": [{"role": "user", "content": [{"text": "run it"}]}],
           "toolConfig": {"tools": [spec("Bash"), spec("Read"), spec("TaskList")]}, "inferenceConfig": {"maxTokens": 8192}}
answer = {"output": {"message": {"role": "assistant", "content": [{"text": call("Bash", bash)}]}}, "stopReason": "end_turn",
          "usage": {"inputTokens": 19216, "outputTokens": 43, "totalTokens": 19259}, "metrics": {"latencyMs": 900}}
assert h.offered_tools(request) == tools
out = h.converse_tool_calls(request, copy.deepcopy(answer))
use = out["output"]["message"]["content"]
assert len(use) == 1 and use[0]["toolUse"]["name"] == "Bash" and use[0]["toolUse"]["input"] == bash, out
assert re.fullmatch(r"tooluse_[A-Za-z0-9]{22}", use[0]["toolUse"]["toolUseId"]), use
assert out["stopReason"] == "tool_use" and out["usage"] == answer["usage"] and out["metrics"] == answer["metrics"]
assert out["output"]["message"]["role"] == "assistant"
pair = copy.deepcopy(answer); pair["output"]["message"]["content"] = [{"text": call(*two[0]) + "\n" + call(*two[1])}]
blocks = h.converse_tool_calls(request, pair)["output"]["message"]["content"]
assert [(b["toolUse"]["name"], b["toolUse"]["input"]) for b in blocks] == two and blocks[0]["toolUse"]["toolUseId"] != blocks[1]["toolUse"]["toolUseId"]
# as it came: cut short (max_tokens), more than one block, a toolUse already, prose, no tools offered, odd shapes
for change in (lambda a: a.update(stopReason="max_tokens"), lambda a: a["output"]["message"]["content"].append({"text": "x"}),
               lambda a: a["output"]["message"].update(content=[{"toolUse": {"toolUseId": "t", "name": "Bash", "input": bash}}]),
               lambda a: a["output"]["message"].update(content=[{"text": "Done: " + call("Bash", bash)}]),
               lambda a: a["output"]["message"].update(content=[{"text": call("Bash", bash), "extra": 1}]),
               lambda a: a.update(output=None), lambda a: a.pop("stopReason")):
    a = copy.deepcopy(answer); change(a)
    assert h.converse_tool_calls(request, a) is None, a
assert h.converse_tool_calls({k: v for k, v in request.items() if k != "toolConfig"}, answer) is None
assert h.converse_tool_calls(request, None) is None and h.converse_tool_calls(None, answer) is None
assert h.offered_tools({"toolConfig": {"tools": [None, {"toolSpec": {"name": 3}}, {"toolSpec": {"name": "x"}}]}}) == {"x": {}}
'
}

# the hook: a call with tools to Llama on Bedrock (Converse) goes through LiteLLM's own client, its answer read on the
# way back (above): the same call reaches Bedrock; a 200 Converse answer that is Llama's tool call comes back as toolUse
# (a response of the same kind, without the old length); a streamed call, an error, another endpoint, another answer
# come back as they were; any other model, a call without tools or with a client of its own, another call type: as
# they came
test_litellm_hook_gives_llama_on_bedrock_a_client_that_reads_its_tool_calls() {
  command -v python3 >/dev/null 2>&1 || return 77
  _hook_models
  mkdir -p "$TMP/h/litellm/llms/custom_httpx"
  printf '' > "$TMP/h/litellm/llms/__init__.py"; printf '' > "$TMP/h/litellm/llms/custom_httpx/__init__.py"
  cat > "$TMP/h/litellm/llms/custom_httpx/http_handler.py" <<'PY'
import json


class AsyncHTTPHandler:
    def __init__(self, timeout=None):
        self.timeout, self.calls, self.answer = timeout, [], None

    async def post(self, url, data=None, json=None, params=None, headers=None, timeout=None, stream=False, logging_obj=None):
        self.calls.append({"url": url, "data": data, "headers": headers, "stream": stream})
        return self.answer


class Response:
    def __init__(self, status_code, headers=None, content=b"", request=None):
        self.status_code, self.headers, self.content, self.request = status_code, dict(headers or {}), content, request

    def json(self):
        return json.loads(self.content)


CLIENTS = {}


def get_async_httpx_client(llm_provider, params=None, shared_session=None):
    return CLIENTS.setdefault((llm_provider, repr(params)), AsyncHTTPHandler(**(params or {})))
PY
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, copy, json, bn_hooks as h
from litellm.llms.custom_httpx import http_handler as hh
hook = lambda kw, ct="acompletion": asyncio.run(h.proxy_handler_instance.async_pre_call_deployment_hook(copy.deepcopy(kw), ct))
tools = [{"type": "function", "function": {"name": "Bash", "parameters": {"type": "object", "required": ["command"]}}}]
kw = {"model": "bedrock/us.meta.llama3-3-70b-instruct-v1:0", "messages": [{"role": "user", "content": "run it"}], "tools": tools,
      "stream": True, "max_tokens": 8192, "client": None, "model_info": {"bn_id": "llama-3-3-70b"}}
out = hook(kw)
client = out.pop("client")
assert isinstance(client, hh.AsyncHTTPHandler) and out == {k: v for k, v in kw.items() if k != "client"}, out
inner = hh.CLIENTS[("bedrock", "None")]   # (a streamed call: LiteLLM s default client)
url = "https://bedrock-runtime.us-east-1.amazonaws.com/model/us.meta.llama3-3-70b-instruct-v1%3A0/converse"
request = {"messages": [{"role": "user", "content": [{"text": "run it"}]}], "inferenceConfig": {"maxTokens": 8192},
           "toolConfig": {"tools": [{"toolSpec": {"name": "Bash", "inputSchema": {"json": {"type": "object", "required": ["command"]}}}}]}}
text = json.dumps({"type": "function", "name": "Bash", "parameters": {"command": "echo hi"}})
answer = {"output": {"message": {"role": "assistant", "content": [{"text": text}]}}, "stopReason": "end_turn", "usage": {"inputTokens": 9, "outputTokens": 3}}
def bedrock(status=200, body=answer, headers=None):
    inner.answer = hh.Response(status, headers or {"Content-Type": "application/json", "Content-Length": "999", "x-amzn-RequestId": "r1"},
                               json.dumps(body).encode(), request="the request")
    return inner.answer
post = lambda u=url, **k: asyncio.run(client.post(u, **{"headers": {"h": "v"}, "data": json.dumps(request), **k}))
# a Converse answer that is the call: toolUse, the rest as it came, the call as LiteLLM made it
bedrock()
r = post(stream=False, logging_obj=None)
got = r.json()
assert type(r) is hh.Response and r.status_code == 200 and r.request == "the request", r
assert r.headers == {"Content-Type": "application/json", "x-amzn-RequestId": "r1"}, r.headers
assert got["stopReason"] == "tool_use" and got["usage"] == answer["usage"], got
assert [(b["toolUse"]["name"], b["toolUse"]["input"]) for b in got["output"]["message"]["content"]] == [("Bash", {"command": "echo hi"})]
assert inner.calls[-1] == {"url": url, "data": json.dumps(request), "headers": {"h": "v"}, "stream": False}, inner.calls[-1]
# (LiteLLM s non-streamed call names the URL: post(url=…))
bedrock()
assert asyncio.run(client.post(url=url, data=json.dumps(request).encode())).json()["stopReason"] == "tool_use"
# as they were: a streamed call, an error, ConverseStream, another model s URL, another answer, a body that is not JSON
for kind, call in (("stream", lambda: post(stream=True)), ("error", lambda: post()), ("converse-stream", lambda: post(url[:-8] + "converse-stream")),
                   ("another model", lambda: post(url.replace("meta.llama3-3-70b", "openai.gpt-6-luna"))),
                   ("prose", lambda: post()), ("not JSON", lambda: post(data="{nope")), ("no tools", lambda: post(data=json.dumps({"messages": []})))):
    sent = bedrock(400 if kind == "error" else 200, {**answer, "output": {"message": {"role": "assistant", "content": [{"text": "Hello."}]}}} if kind == "prose" else answer)
    assert call() is sent, kind
# a call that is not a call to Llama on Bedrock with tools, or has a client: as it came
for other in ({**kw, "model": "bedrock/us.openai.gpt-6-luna"}, {**kw, "model": "bedrock/invoke/us.meta.llama3-3-70b-instruct-v1:0"},
              {**kw, "tools": None}, {**kw, "tools": []}, {**kw, "client": "LiteLLM s"}, {**kw, "model": "openrouter/meta-llama/llama-3.3-70b-instruct"},
              {**kw, "model": ["bedrock/us.meta.llama"]}):
    assert hook(other) == other, other
assert hook(kw, "aembedding") == kw and hook(kw, "anthropic_messages") == kw
# the model named apart from its provider, a call that is not streamed (its timeout s client)
plain = hook({**kw, "model": "us.meta.llama3-3-70b-instruct-v1:0", "custom_llm_provider": "bedrock", "stream": False, "timeout": 600.0})
assert isinstance(plain["client"], hh.AsyncHTTPHandler) and plain["client"]._bn_inner is not inner
assert asyncio.run(h.proxy_handler_instance.async_pre_call_deployment_hook(None, "acompletion")) is None
'
}

# the hook: Bedrock refuses, for Llama alone, a turn with tool results and text ("Conversation blocks and tool result
# blocks cannot be provided in the same turn"), which LiteLLM makes of the results and the reminders after them: that
# text (a system message under LiteLLM's note) goes at the end of the last result; a message with an image, an answer,
# the next turn and any other model as they came
test_litellm_hook_keeps_llama_tool_results_turns_alone() {
  command -v python3 >/dev/null 2>&1 || return 77
  _hook_models
  PYTHONPATH="$TMP/h" python3 -c '
import asyncio, copy, bn_hooks as h
note = "Operator note (not from the user): the following was originally a mid-conversation system-role reminder."
call = lambda *ids: {"role": "assistant", "content": None, "tool_calls": [{"id": i, "type": "function", "function": {"name": "Read", "arguments": "{}"}} for i in ids]}
msgs = [{"role": "system", "content": "You are Claude Code."}, {"role": "user", "content": "read a and b"},
        {"role": "system", "content": "<system-reminder>early</system-reminder>"},
        call("t1", "t2"), {"role": "tool", "tool_call_id": "t1", "content": "alpha"},
        {"role": "tool", "tool_call_id": "t2", "content": [{"type": "text", "text": "beta", "cache_control": {"type": "ephemeral"}}]},
        {"role": "user", "content": [{"type": "text", "text": "<system-reminder>a.txt changed</system-reminder>"}, {"type": "text", "text": ""}]},
        {"role": "system", "content": [{"type": "text", "text": "Agent aa7 finished."}]},
        {"role": "assistant", "content": "a and b"}, {"role": "user", "content": "now c"}, call("t3"),
        {"role": "tool", "tool_call_id": "t3", "content": "gamma"}, {"role": "system", "content": "<system-reminder>late</system-reminder>"}]
run = lambda kw: asyncio.run(h.proxy_handler_instance.async_pre_call_deployment_hook(copy.deepcopy(kw), "acompletion"))
kw = {"model": "bedrock/us.meta.llama3-3-70b-instruct-v1:0", "messages": msgs, "stream": True}
out = run(kw)["messages"]
assert out == [*msgs[:5],
               {"role": "tool", "tool_call_id": "t2", "content": [{"type": "text", "text": "beta", "cache_control": {"type": "ephemeral"}},
                                                                  {"type": "text", "text": "<system-reminder>a.txt changed</system-reminder>"},
                                                                  {"type": "text", "text": note}, {"type": "text", "text": "Agent aa7 finished."}]},
               *msgs[8:11],
               {"role": "tool", "tool_call_id": "t3", "content": [{"type": "text", "text": "gamma"}, {"type": "text", "text": note},
                                                                  {"type": "text", "text": "<system-reminder>late</system-reminder>"}]}], out
assert run(kw)["messages"] == out   # (the same every time: a later turn keeps the earlier ones as they were)
# as they came: a message with an image after the results (Llama takes none: Bedrock says so), any other model, no results
img = [call("t1"), {"role": "tool", "tool_call_id": "t1", "content": "x"},
       {"role": "user", "content": [{"type": "text", "text": "[The image output of tool call t1]"}, {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}}]}]
assert run({**kw, "messages": img})["messages"] == img
for model in ("bedrock/us.openai.gpt-6-luna", "bedrock/mistral.mistral-large-3-675b-instruct", "openrouter/meta-llama/llama-3.3-70b-instruct"):
    assert run({**kw, "model": model}) == {**kw, "model": model}, model
plain = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}, {"role": "system", "content": "s"}, {"role": "user", "content": "x"}]
assert run({**kw, "messages": plain})["messages"] == plain
assert h.results_alone([{"role": "tool", "content": None}, {"role": "user", "content": "x"}]) == [{"role": "tool", "content": [{"type": "text", "text": "x"}]}]
assert h.results_alone([None, 3, {"role": "tool"}]) == [None, 3, {"role": "tool"}]
assert run({**kw, "messages": "x"}) == {**kw, "messages": "x"}
'
}


# Names that YAML refuses or a terminal acts on (C1 controls such as U+009B, CSI; U+2028; bidi overrides; U+FFFE) never
# reach LiteLLM's config, the model list or a terminal; a config that is not valid YAML is never put in place
test_unsafe_model_names_never_reach_yaml_or_a_terminal() {
  _cm_env
  c1="$(printf '\302\233')"; ls2028="$(printf '\342\200\250')"; rlo="$(printf '\342\200\256')"; fffe="$(printf '\357\277\276')"; esc="$(printf '\033')"
  # OpenRouter's list: or_classify drops them
  out="$(printf 'a/b\tBad%s31mName%s x%sy%s\t1\t0\t0\t\t\ttext\t1\t1\t\n' "$c1" "$ls2028" "$rlo" "$fffe" | or_classify | cut -f2)"
  assert_eq "$out" "Bad31mName xy"
  # a cache edited by hand (or an older one): code_models_rows drops them too, and so does every reader of the file
  printf 'OPENROUTER_API_KEY=sk-or-v1-abc\n' >> "$ENV_FILE"
  printf '# fetched_at: x\na/b\tVendor: N%s1%s\t1\t0\t0\t\t\tfree\t1\t1\t\nc/d\tCafé %sOK\t1\t0\t0\t\t\tfree\t1\t1\t\n' "$c1" "$esc" "$rlo" > "$TMP/litellm/openrouter-models.tsv"
  code_models_write ""
  f="$TMP/litellm/code-models.tsv"
  ! LC_ALL=C grep -q "$(printf '\302[\200-\237]')" "$f" || { echo "C1 in the file" >&2; return 1; }
  ! LC_ALL=C grep -q "$(printf '\033')" "$f" || { echo "ESC in the file" >&2; return 1; }
  assert_eq "$(_col 2 or/a/b < "$f")" "N1"
  assert_eq "$(_col 2 or/c/d < "$f")" "Café OK"
  # LiteLLM's model_info: a name only when it is plain ASCII (the id stands in otherwise)
  yaml="$(printf '  - model_name: "or/c/d"\n    model_info:\n      mode: "chat"\n  - model_name: "or/a/b"\n    model_info:\n      mode: "chat"\n' | code_models_inject "$f")"
  assert_contains "$yaml" "$(printf '      bn_id: "or/c/d"\n      bn_vendor: "c"\n      bn_compat:')"
  assert_contains "$yaml" '      bn_name: "N1"'
  assert_not_contains "$yaml" "Café"
  # the host's table and /model menu: nothing a terminal acts on, even from a file edited by hand
  printf 'x/y\tE%s[2Jvil%s\tOpenRouter\tV%s]0;t\t0\t0\t-\t-\t1\tuntested\t1\t0\t-\t-\t-\n' "$esc" "$c1" "$esc" >> "$f"
  t="$(code_models_table "" all; code_picker_json "" 0)"
  ! printf '%s' "$t" | LC_ALL=C grep -q "$(printf '\033')" || { echo "ESC reaches the terminal" >&2; return 1; }
  ! printf '%s' "$t" | LC_ALL=C grep -q "$(printf '\302[\200-\237]')" || { echo "C1 reaches the terminal" >&2; return 1; }
  # the last guard: a config YAML would refuse is never put in place (the previous one stays)
  printf 'model_list:\n  - model_name: "ok"\n' > "$TMP/good.yaml"; litellm_config_safe "$TMP/good.yaml"
  for bad in "$c1" "$ls2028" "$fffe" "$(printf '\001')" "$(printf '\377')"; do
    printf 'model_list:\n  - model_name: "x%sy"\n' "$bad" > "$TMP/bad.yaml"
    ! litellm_config_safe "$TMP/bad.yaml" || { echo "taken: $(printf '%s' "$bad" | od -An -c)" >&2; return 1; }
  done
  printf 'AWS_REGION_NAME=us-east-1\n' >> "$ENV_FILE"; printf 'old config\n' > "$TMP/litellm/config.yaml"
  litellm_config_safe() { return 1; }
  if (render_config "") 2> "$TMP/err"; then return 1; fi
  assert_contains "$(cat "$TMP/err")" "not valid YAML — kept the previous one"
  assert_eq "$(cat "$TMP/litellm/config.yaml")" "old config"
}

# Settings' list of the models (the snapshot's choices): each with its price, a free one at $0, never an unusable id
test_settings_choices_name_each_models_price() {
  . "$STACK_DIR/lib/settings.sh"
  _cm_env
  printf '# x\nllama-x\tLlama X\tBedrock\tMeta\t0.72\t0.72\t-\t-\t0\tchat-only\t1\t0\t8192\t-\t-\nor/a/b:free\tB\tOpenRouter\tA\t0\t0\t-\t-\t1\tuntested\t0\t0\t-\t-\t-\nor/~a/x\tX\tOpenRouter\tA\t1\t1\t-\t-\t0\tworks\t1\t0\t-\t-\t-\n' > "$TMP/litellm/code-models.tsv"
  out="$(_settings_code_models)"
  assert_eq "$out" '["llama-x", "Llama X", "Bedrock", "Meta", "chat-only", false, true, "$0.72/$0.72 per 1M"], ["or/a/b:free", "B", "OpenRouter", "A", "untested", true, false, "free ($0)"]'
}

# JON-520: extra Bedrock models the browser adds beyond the catalog (BEDROCK_MODELS) are rendered into LiteLLM and show
# in the Code page's rows (devos-claude --models reads these) with their compat from catalog/code-models.tsv
test_added_bedrock_models_render_and_show_in_the_code_rows() {
  _cm_env 'BEDROCK_MODELS=us.anthropic.claude-haiku-4-5-20251001-v1:0,meta.llama4-x-v1:0'
  # the ids BEDROCK_MODELS names, valid, each once (an ARN is dropped; a catalog id is never double-rendered)
  assert_eq "$(bedrock_extra_wanted | tr '\n' ' ')" "us.anthropic.claude-haiku-4-5-20251001-v1:0 meta.llama4-x-v1:0 "
  ! valid_bedrock_extra_id 'arn:aws:bedrock:us-east-1::foundation-model/x'; valid_bedrock_extra_id 'us.anthropic.claude-haiku-4-5-20251001-v1:0'
  # rendered as their own model_list entries (converse path, the region), no price in the config (LiteLLM prices them)
  local yaml; yaml="$(bedrock_extra_yaml us-east-1)"
  assert_contains "$yaml" "$(printf '  - model_name: "us.anthropic.claude-haiku-4-5-20251001-v1:0"\n    litellm_params:\n      model: "bedrock/converse/us.anthropic.claude-haiku-4-5-20251001-v1:0"')"
  assert_contains "$yaml" 'aws_region_name: os.environ/AWS_REGION_NAME'
  # the Code page rows: both added models, provider Bedrock, vendor from the id, compat from the catalog (claude-* works)
  printf 'claude-big\n' > "$TMP/en"
  out="$(code_models_rows "$TMP/en")"
  assert_contains "$(printf '%s\n' "$out" | cut -f1)" us.anthropic.claude-haiku-4-5-20251001-v1:0
  assert_contains "$(printf '%s\n' "$out" | cut -f1)" meta.llama4-x-v1:0
  assert_eq "$(printf '%s\n' "$out" | _col 3 us.anthropic.claude-haiku-4-5-20251001-v1:0)" Bedrock
  assert_eq "$(printf '%s\n' "$out" | _col 4 us.anthropic.claude-haiku-4-5-20251001-v1:0)" Anthropic
  assert_eq "$(printf '%s\n' "$out" | _col 10 us.anthropic.claude-haiku-4-5-20251001-v1:0)" untested   # a raw id does not match claude-* (honest: not checked)
  assert_eq "$(printf '%s\n' "$out" | _col 4 meta.llama4-x-v1:0)" Meta
  # a catalog model named in BEDROCK_MODELS is not double-rendered (its name and its bedrock id are both excluded)
  printf 'CLAUDE_BEDROCK_OPUS_MODEL=claude-big\nBEDROCK_MODELS=claude-big,us.anthropic.big\n' > "$ENV_FILE"
  assert_eq "$(bedrock_extra_wanted)" ""
}

# JON-520: adding two Experiential Labs models (EXPLABS_MODELS, as the browser's Add does) shows both in the Code rows
test_two_added_experiential_models_show_in_the_code_rows() {
  . "$STACK_DIR/lib/explabs.sh" 2>/dev/null || true
  _cm_env 'EXPLABS_API_KEY=xpl_000000000000000000000000000000000000test
EXPLABS_MODELS=qwen3.8-27b,gpt-5-mini'
  # the gateway's list cached (as a refresh writes it) for this key: both chosen models with details
  mkdir -p "$TMP/litellm"
  xl_ids < "$T_ROOT/tests/fixtures/explabs_v1_models.json" > "$TMP/ids"; : > "$TMP/det"
  while IFS= read -r id; do id="${id%:free}"; [ ! -r "$T_ROOT/tests/fixtures/explabs_catalog/$id.json" ] || xl_model_tsv "$id" < "$T_ROOT/tests/fixtures/explabs_catalog/$id.json" >> "$TMP/det"; done < "$TMP/ids"
  { printf '# fetched_at: 2026-10-24T00:00:00Z\n'; xl_free_rows "$TMP/ids" < "$TMP/det" | xl_join "$TMP/ids"; } > "$TMP/litellm/explabs-models.tsv"
  mkdir -p "$(dirname "$(xl_key_mark)")"; xl_key_hash "$(get_env EXPLABS_API_KEY)" > "$(xl_key_mark)"
  printf 'claude-big\n' > "$TMP/en"
  out="$(code_models_rows "$TMP/en")"
  assert_contains "$(printf '%s\n' "$out" | cut -f1)" xl/qwen3.8-27b
  assert_contains "$(printf '%s\n' "$out" | cut -f1)" xl/gpt-5-mini
  assert_eq "$(printf '%s\n' "$out" | _col 3 xl/qwen3.8-27b)" "Experiential Labs"
}
