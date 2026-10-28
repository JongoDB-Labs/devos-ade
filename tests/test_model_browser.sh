# shellcheck shell=bash
# lib/model_browser.sh: when the update helper reads the model browser's lists (model_browser_tick, each loop).
. "$STACK_DIR/lib/commands.sh"

# _mb_fake — ./stack is a fake that notes each "models browse" it is asked for ($TMP/reads), and the lock is free
_mb_fake() {
  mkdir -p "$TMP/fake" "$(helper_dir)" "$(request_dir)"
  printf '#!/bin/sh\necho "$*" >> "%s/reads"\n' "$TMP" > "$TMP/fake/stack"; chmod +x "$TMP/fake/stack"
  STACK_DIR="$TMP/fake"
  stack_lock_holder() { :; }
}
_mb_reads() { local n; sleep 0.3; n="$(grep -c 'models browse' "$TMP/reads" 2>/dev/null)"; echo "${n:-0}"; }

test_a_stack_with_no_list_read_reads_them_once_by_itself() {
  _mb_fake
  model_browser_tick
  assert_eq "$(_mb_reads)" 1      # the first open of the page finds the lists there
  model_browser_tick
  assert_eq "$(_mb_reads)" 1      # once: after that, only when the page asks
  : > "$(model_browser_wanted_file)"
  model_browser_tick
  assert_eq "$(_mb_reads)" 1      # and a request a moment later waits out MODEL_BROWSER_TICK_MIN
}

test_a_request_reads_the_lists_and_is_spent() {
  _mb_fake; echo 1767225600 > "$(helper_dir)/model-browser-last"; touch -t 202601010000 "$(helper_dir)/model-browser-last"
  : > "$(model_browser_wanted_file)"
  model_browser_tick
  assert_eq "$(_mb_reads)" 1
  [ ! -e "$(model_browser_wanted_file)" ]
}

test_a_request_waits_while_the_stack_is_busy_and_is_not_lost() {
  _mb_fake; echo 1767225600 > "$(helper_dir)/model-browser-last"; touch -t 202601010000 "$(helper_dir)/model-browser-last"
  : > "$(model_browser_wanted_file)"
  stack_lock_holder() { echo "4242 update"; }
  model_browser_tick
  assert_eq "$(_mb_reads)" 0
  [ -e "$(model_browser_wanted_file)" ]   # kept for the next loop
  stack_lock_holder() { :; }
  model_browser_tick
  assert_eq "$(_mb_reads)" 1
}

test_a_request_waits_while_a_read_runs() {
  _mb_fake; echo 1767225600 > "$(helper_dir)/model-browser-last"; touch -t 202601010000 "$(helper_dir)/model-browser-last"
  : > "$(model_browser_wanted_file)"
  sleep 30 & echo "$!" > "$(helper_dir)/model-browser.pid"
  model_browser_tick
  kill "$(cat "$(helper_dir)/model-browser.pid")" 2>/dev/null; wait 2>/dev/null
  assert_eq "$(_mb_reads)" 0
  [ -e "$(model_browser_wanted_file)" ]
}

test_requests_are_read_at_most_every_tick_minutes() {
  _mb_fake; date +%s > "$(helper_dir)/model-browser-last"   # a read just now
  : > "$(model_browser_wanted_file)"
  model_browser_tick
  assert_eq "$(_mb_reads)" 0
  [ ! -e "$(model_browser_wanted_file)" ]   # (read a moment ago: nothing new to read)
}

test_a_helper_folder_that_cannot_be_written_never_reads_every_loop() {
  [ "$(id -u)" != 0 ] || { echo "running as root: cannot make a folder unwritable" >&2; return 77; }
  _mb_fake; chmod 500 "$(helper_dir)"
  model_browser_tick
  chmod 755 "$(helper_dir)"
  assert_eq "$(_mb_reads)" 0
}

# lib/model_browser_bedrock.py against a stand-in boto3 (FAKE_PROFILES: ok or denied); prints its JSON
_mb_reader() {
  local f="$TMP/fakepy"; mkdir -p "$f/boto3" "$f/botocore"
  : > "$f/botocore/__init__.py"
  printf 'class Config:\n    def __init__(self, **k): pass\n' > "$f/botocore/config.py"
  cat > "$f/botocore/exceptions.py" <<'PY'
class BotoCoreError(Exception): pass
class NoCredentialsError(BotoCoreError): pass
class ClientError(Exception):
    def __init__(self, code, op):
        self.response = {"Error": {"Code": code}}
        self.operation_name = op
PY
  cat > "$f/boto3/__init__.py" <<'PY'
import os
from botocore.exceptions import ClientError
FMS = [{"modelId": "anthropic.claude-haiku-4-5-20251001-v1:0", "modelName": "Claude Haiku 4.5", "providerName": "Anthropic",
        "inputModalities": ["TEXT", "IMAGE"], "outputModalities": ["TEXT"], "inferenceTypesSupported": ["INFERENCE_PROFILE"]},
       {"modelId": "amazon.nova-pro-v1:0", "modelName": "Nova Pro", "providerName": "Amazon",
        "inputModalities": ["TEXT"], "outputModalities": ["TEXT"], "inferenceTypesSupported": ["ON_DEMAND"]}]
class _Bedrock:
    def list_foundation_models(self, **k): return {"modelSummaries": FMS}
    def list_inference_profiles(self, **k):
        if os.environ.get("FAKE_PROFILES") == "denied":
            raise ClientError("AccessDeniedException", "ListInferenceProfiles")
        return {"inferenceProfileSummaries": [{"inferenceProfileId": "global.anthropic.claude-haiku-4-5-20251001-v1:0", "status": "ACTIVE",
                "models": [{"modelArn": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"}]}]}
def client(name, **k): return _Bedrock()
PY
  PYTHONPATH="$f" python3 "$STACK_DIR/lib/model_browser_bedrock.py" us-east-1
}

test_bedrock_list_names_the_profile_a_claude_model_is_called_through() {
  out="$(FAKE_PROFILES=ok _mb_reader)"
  assert_contains "$out" '"profiles":"ok"'
  assert_contains "$out" '"id":"global.anthropic.claude-haiku-4-5-20251001-v1:0"'
  assert_contains "$out" '"id":"amazon.nova-pro-v1:0"'
}

test_a_key_that_may_not_list_profiles_still_lists_claude_by_its_usual_profile() {
  out="$(FAKE_PROFILES=denied _mb_reader)"
  assert_contains "$out" '"status":"ok"'
  assert_contains "$out" '"profiles":"denied"'
  # AWS's system-defined profile for the region's geography: us.<model id> (what the catalog calls too)
  assert_contains "$out" '"id":"us.anthropic.claude-haiku-4-5-20251001-v1:0"'
  assert_contains "$out" '"vendor":"Anthropic"'
}
