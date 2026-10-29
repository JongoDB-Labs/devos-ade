# shellcheck shell=bash
# lib/model_browser.sh: when the update helper reads the model browser's lists (model_browser_tick, each loop).
. "$STACK_DIR/lib/commands.sh"

# _mb_fake — ./stack is a fake that notes each "models browse" it is asked for ($TMP/reads), and the lock is free;
# _mb_reads waits for the read the tick started in the background, by its pid (not a fixed while: a busy computer is
# slow; and it runs in $( ), where "wait" cannot see the test's own jobs)
_mb_fake() {
  mkdir -p "$TMP/fake" "$(helper_dir)" "$(request_dir)"
  printf '#!/bin/sh\necho "$*" >> "%s/reads"\n' "$TMP" > "$TMP/fake/stack"; chmod +x "$TMP/fake/stack"
  STACK_DIR="$TMP/fake"
  stack_lock_holder() { :; }
}
_mb_reads() {
  local n i=0 pid; pid="$(cat "$(helper_dir)/model-browser.pid" 2>/dev/null || true)"
  while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  n="$(grep -c 'models browse' "$TMP/reads" 2>/dev/null)"; echo "${n:-0}"
}

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

# JON-823: Read again on the page ("force" in the request): every list read again (--refresh), a minute after the last
test_read_again_reads_every_list_again_and_waits_only_a_minute() {
  _mb_fake; date +%s > "$(helper_dir)/model-browser-last"; touch -t 202601010000 "$(helper_dir)/model-browser-last"
  printf 'force' > "$(model_browser_wanted_file)"
  model_browser_tick
  assert_eq "$(_mb_reads)" 1
  assert_contains "$(cat "$TMP/reads")" 'models browse --refresh'
  # read a moment ago: a second Read again waits out the minute (spent, not kept)
  printf 'force' > "$(model_browser_wanted_file)"
  model_browser_tick
  assert_eq "$(_mb_reads)" 1
  [ ! -e "$(model_browser_wanted_file)" ]
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

# lib/model_browser_bedrock.py against a stand-in boto3; prints what it printed. FAKE_PROFILES: ok or denied (both
# kinds of ListInferenceProfiles); FAKE_GET: what GetInferenceProfile answers — denied (default), ok, or missing (no us.
# profile, a global. one). Regions: us-east-1 (the stack's), us-west-2 (Writer, through a us. profile; Nova again),
# eu-west-1 (a model only there), ap-south-2 (not turned on for the account).
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
def fm(mid, name, vendor, kinds, ins=("TEXT",), outs=("TEXT",)):
    return {"modelId": mid, "modelName": name, "providerName": vendor, "inputModalities": list(ins), "outputModalities": list(outs),
            "inferenceTypesSupported": list(kinds)}
HAIKU = "anthropic.claude-haiku-4-5-20251001-v1:0"
FMS = {
    "us-east-1": [fm(HAIKU, "Claude Haiku 4.5", "Anthropic", ["INFERENCE_PROFILE"], ins=("TEXT", "IMAGE")),
                  fm("amazon.nova-pro-v1:0", "Nova Pro", "Amazon", ["ON_DEMAND"]),
                  fm("amazon.titan-embed-text-v2:0", "Titan Embeddings", "Amazon", ["ON_DEMAND"], outs=("EMBEDDING",)),
                  fm("anthropic.claude-x-v1:0:200k", "Claude X", "Anthropic", ["PROVISIONED"]),
                  fm("meta.llama-old-v1:0", "Llama Old", "Meta", ["PROVISIONED"])],
    "us-west-2": [fm("amazon.nova-pro-v1:0", "Nova Pro", "Amazon", ["ON_DEMAND"]),
                  fm("writer.palmyra-x5-v1:0", "Palmyra X5", "Writer", ["INFERENCE_PROFILE"])],
    "eu-west-1": [fm("mistral.eu-only-v1:0", "Mistral EU", "Mistral AI", ["ON_DEMAND"])],
}
SYS = {"us-east-1": [("global.anthropic.claude-haiku-4-5-20251001-v1:0", HAIKU)],
       "us-west-2": [("us.writer.palmyra-x5-v1:0", "writer.palmyra-x5-v1:0")]}
ARN = "arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/a1b2c3d4e5f6"
def denied(op): return ClientError("AccessDeniedException", op)
class _Bedrock:
    def __init__(self, region): self.region = region
    def list_foundation_models(self, **k):
        if self.region == "ap-south-2":
            raise ClientError("UnrecognizedClientException", "ListFoundationModels")
        return {"modelSummaries": FMS.get(self.region, [])}
    def list_inference_profiles(self, typeEquals, **k):
        if os.environ.get("FAKE_PROFILES") == "denied":
            raise denied("ListInferenceProfiles")
        if typeEquals == "APPLICATION":
            return {"inferenceProfileSummaries": [{"inferenceProfileId": "a1b2c3d4e5f6", "inferenceProfileArn": ARN, "status": "ACTIVE",
                    "inferenceProfileName": "Team Haiku", "models": [{"modelArn": f"arn:aws:bedrock:us-east-1::foundation-model/{HAIKU}"}]}]} if self.region == "us-east-1" else {}
        return {"inferenceProfileSummaries": [{"inferenceProfileId": p, "status": "ACTIVE", "models": [{"modelArn": f"arn:aws:bedrock:{self.region}::foundation-model/{m}"}]}
                                              for p, m in SYS.get(self.region, [])]}
    def get_inference_profile(self, inferenceProfileIdentifier):
        how = os.environ.get("FAKE_GET", "denied")
        if how == "denied":
            raise denied("GetInferenceProfile")
        if how == "missing" and inferenceProfileIdentifier.startswith("us."):
            raise ClientError("ResourceNotFoundException", "GetInferenceProfile")
        return {"inferenceProfileId": inferenceProfileIdentifier, "status": "ACTIVE"}
class Session:
    def get_available_regions(self, service): return ["ap-south-2", "eu-west-1", "us-east-1", "us-west-2"]
def client(name, region_name=None, **k): return _Bedrock(region_name)
PY
  PYTHONPATH="$f" python3 "$STACK_DIR/lib/model_browser_bedrock.py" us-east-1
}
_mb_list() { printf '%s\n' "$1" | head -n 1; }

test_bedrock_list_names_the_profile_a_claude_model_is_called_through() {
  out="$(FAKE_PROFILES=ok _mb_reader)"
  assert_contains "$out" '"profiles":"ok"'
  assert_contains "$out" '"id":"global.anthropic.claude-haiku-4-5-20251001-v1:0"'
  assert_contains "$out" '"id":"amazon.nova-pro-v1:0"'
  assert_not_contains "$out" '"guessed":true'
}

test_a_key_that_may_not_list_profiles_still_lists_claude_by_its_usual_profile_marked_not_confirmed() {
  out="$(FAKE_PROFILES=denied _mb_reader)"
  assert_contains "$out" '"status":"ok"'
  assert_contains "$out" '"profiles":"denied"'
  # AWS's system-defined profile for the region's geography: us.<model id> (what the catalog calls too), a guess
  assert_contains "$out" '"id":"us.anthropic.claude-haiku-4-5-20251001-v1:0"'
  assert_contains "$out" '"vendor":"Anthropic"'
  assert_eq "$(_mb_list "$out" | python3 -c 'import json,sys; print([m["guessed"] for m in json.load(sys.stdin)["models"] if m["model_id"].startswith("anthropic.")])')" "[True]"
}

test_a_guessed_profile_is_confirmed_or_dropped_when_the_key_may_ask_about_it() {
  # GetInferenceProfile answers (free): the us. profile exists, so it is no guess
  out="$(FAKE_PROFILES=denied FAKE_GET=ok _mb_reader)"
  assert_contains "$out" '"id":"us.anthropic.claude-haiku-4-5-20251001-v1:0"'
  assert_not_contains "$out" '"guessed":true'
  # AWS has no us. one: the global. one, confirmed
  out="$(FAKE_PROFILES=denied FAKE_GET=missing _mb_reader)"
  assert_contains "$out" '"id":"global.anthropic.claude-haiku-4-5-20251001-v1:0"'
  assert_not_contains "$out" '"id":"us.anthropic.claude-haiku'
  assert_not_contains "$out" '"guessed":true'
}

test_other_regions_add_only_the_models_this_region_does_not_offer() {
  out="$(FAKE_PROFILES=ok _mb_reader)"
  # Writer only in us-west-2 (through its us. profile), Mistral EU only in eu-west-1: "<region>/<id>"; Nova once, here
  assert_contains "$out" '"id":"us-west-2/us.writer.palmyra-x5-v1:0"'
  assert_contains "$out" '"id":"eu-west-1/mistral.eu-only-v1:0"'
  assert_contains "$out" '"region":"eu-west-1"'
  assert_eq "$(printf '%s' "$out" | grep -o '"model_id":"amazon.nova-pro-v1:0"' | wc -l | tr -d ' ')" 1
  # a region the account has not turned on: off, not an error; every region looked at is said (its own geography first)
  assert_contains "$out" '"regions":{"us-east-1":"ok","us-west-2":"ok","ap-south-2":"off","eu-west-1":"ok"}'
  # what this region leaves out, by reason: the embedder, the context variant, the provisioned-only model
  assert_contains "$out" '"left_out":{"not-text":1,"variant":1,"provisioned":1}'
}

test_your_application_profile_is_listed_by_name_and_its_arn_only_on_its_own_line() {
  out="$(FAKE_PROFILES=ok _mb_reader)"
  assert_contains "$(_mb_list "$out")" '"id":"app/a1b2c3d4e5f6"'
  assert_contains "$(_mb_list "$out")" '"name":"Team Haiku"'
  assert_contains "$(_mb_list "$out")" '"kind":"app-profile"'
  # the ARN names the account: never in the list the portal reads
  assert_not_contains "$(_mb_list "$out")" 'arn:'
  assert_not_contains "$(_mb_list "$out")" '111122223333'
  assert_eq "$(printf '%s\n' "$out" | sed -n 2p | LC_ALL=C grep -cE "$BEDROCK_APP_LINE")" 1
}
