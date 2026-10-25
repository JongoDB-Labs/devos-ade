#!/usr/bin/env bash
# Opt-in end-to-end check of the Experiential Labs gateway (run by hand; not part of tests/run.sh, CI or
# tests/e2e/run.sh): this checkout's rendered LiteLLM config and hook (lib/explabs.sh, lib/litellm-hooks/bn_hooks.py)
# in the LiteLLM image compose.yaml pins, in ONE throwaway container named bne2e-explabs on a free port of 127.0.0.1,
# removed afterwards (by that name; nothing is pruned). No Postgres, no portal, no AWS.
#
#   E2E_EXPLABS_API_KEY=… tests/e2e/explabs.sh    the real gateway: its model list read with the key and its catalog
#                                                 without it (both free), then ONE
#                                                 real completion on qwen3.8-27b (a fraction of a cent of credits)
#   tests/e2e/explabs.sh                          without E2E_EXPLABS_API_KEY: skipped (exit 0), nothing started
#   tests/e2e/explabs.sh --mock                   no key, no gateway: a stand-in (tests/e2e/explabs-mock.py) inside the
#                                                 container answers like it, and records what reached it
#   --out DIR                                     results (default tests/e2e/out, gitignored): explabs.json
#
# What it checks: qwen3.8-27b is in the key's model list (GET /v1/models: ids only) with its details from the catalog
# (GET /api/models/qwen3.8-27b, keyless); the config sends it only what it takes; LiteLLM
# answers "DevOS ADE test OK"; the cost LiteLLM books for the call (x-litellm-response-cost) is the one the gateway
# reported (usage.cost; $0 with usage.is_byok); and the key is nowhere — not in the rendered config, the results, the
# answer, the container's log, this run's output. With --mock also: what the stand-in got (no refused parameter, the
# output cap under max_completion_tokens; as max_tokens for gpt-5.1-codex, which names it), a streamed answer, Claude
# Code's /v1/messages (with extended thinking too: Chat Completions under the model's own id; with thinking and tools
# on xl/gpt-5.5, the Responses API with its cap as max_output_tokens), a BYOK call booked at $0, and a catalog that
# streams slowly (the stand-in on this computer's 127.0.0.1, real curl): timed out, said, the details read before kept.
#
# The key is only ever in this process's environment and the container's: E2E_EXPLABS_API_KEY is read here, handed to
# curl on its stdin (lib/common.sh curl_auth) and to docker as `-e EXPLABS_API_KEY` (the value from the environment,
# never on a command line). Nothing writes it to a file: no .env, no key mark, no log. Docker runs it, so on a
# machine that shares a heavy-job lock, run the whole script inside that lock.
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NAME=bne2e-explabs
OUT="$ROOT/tests/e2e/out"; MOCK=0
AVOID_PORTS=" 80 443 3000 3009 4000 8080 8081 8090 8765 8787 8800 "
MOCK_PORT=18471
while [ $# -gt 0 ]; do
  case "$1" in
    --mock) MOCK=1; shift ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    -h | --help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/explabs.sh --help)" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
ok() { printf 'ok    %s\n' "$*" >&2; }
FAILS=0

KEY="${E2E_EXPLABS_API_KEY:-}"
unset E2E_EXPLABS_API_KEY EXPLABS_API_KEY   # (from here on only $KEY holds it, and only this process)
if [ "$MOCK" = 0 ] && [ -z "$KEY" ]; then
  echo "skip: E2E_EXPLABS_API_KEY is not set (tests/e2e/explabs.sh --mock runs against a stand-in instead)"
  exit 0
fi
if [ "$MOCK" = 1 ]; then KEY="mock-key-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"; fi
case "$KEY" in *[!A-Za-z0-9_-]*) echo "E2E_EXPLABS_API_KEY is not a key (letters, digits, - and _ only)" >&2; exit 2 ;; esac
command -v docker >/dev/null 2>&1 || { echo "needs docker" >&2; exit 2; }

IMAGE="$(sed -n 's/^    image: \(ghcr.io\/berriai\/litellm:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
[ -n "$IMAGE" ] || { echo "no LiteLLM image in compose.yaml" >&2; exit 2; }
WORK="$ROOT/tests/e2e/work/$NAME"
mkdir -p "$OUT" "$WORK" || exit 2
MASTER="sk-e2e-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

# _has_key FILE... -> 0 when any FILE holds the key (the key on grep's stdin as its pattern list: never in argv)
_has_key() { printf '%s\n' "$KEY" | grep -qF -f - "$@" 2>/dev/null; }
_mask() { K="$KEY" awk '{ while ((i = index($0, ENVIRON["K"])) > 0) $0 = substr($0, 1, i - 1) "[key]" substr($0, i + length(ENVIRON["K"])); print }'; }

cleanup() {
  if docker container inspect "$NAME" >/dev/null 2>&1; then
    # (only this script's own container: it carries this label)
    [ "$(docker container inspect -f '{{index .Config.Labels "io.bedrock-now.e2e"}}' "$NAME" 2>/dev/null)" = explabs ] &&
      docker rm -f "$NAME" >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if docker container inspect "$NAME" >/dev/null 2>&1; then
  if [ "$(docker container inspect -f '{{index .Config.Labels "io.bedrock-now.e2e"}}' "$NAME" 2>/dev/null)" = explabs ]; then
    say "removing a $NAME left by an earlier run"; docker rm -f "$NAME" >/dev/null 2>&1
  else
    echo "a container named $NAME exists and is not this check's: not touching it" >&2; trap - EXIT; exit 2
  fi
fi

# --- this checkout's library: the list, the config (the key never in .env: get_env answers it from memory) ---
STACK_DIR="$ROOT"; ENV_FILE=/dev/null; STATE_DIR="$WORK/state"
export STACK_DIR ENV_FILE STATE_DIR
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
# (the stand-in answers on plain http inside the container: lib/explabs.sh takes such an address only while testing)
[ "$MOCK" = 0 ] || { EXPLABS_API="http://127.0.0.1:$MOCK_PORT/v1"; BEDROCK_NOW_TESTING=1; }
get_env() { case "$1" in EXPLABS_API_KEY) printf '%s' "$KEY" ;; EXPLABS_MODELS) printf 'qwen3.8-27b%s' "$([ "$MOCK" = 1 ] && echo ,byok-model,claude-fable-5,gpt-5.1-codex,gpt-5.5)" ;; esac; }
STACK_DIR="$WORK"; mkdir -p "$WORK/litellm" "$STATE_DIR"
xl_cache_current() { [ -s "$(xl_cache_tsv)" ]; }   # (no key mark: not even a hash of the key on disk)

# _render — the cached list read, the config rendered from it into the folder the container mounts, checked
_render() {
  local row
  row="$(xl_selected | awk -F'\t' '$2 == "qwen3.8-27b"')"
  if [ -z "$row" ]; then fail "qwen3.8-27b is not in the model list for this key"; exit 1; fi
  [ "$(printf '%s' "$row" | cut -f1)" = details ] && ok "qwen3.8-27b has its details (the key's list joined with the catalog)" || fail "qwen3.8-27b has no details in the list"
  cp "$ROOT/lib/litellm-hooks/bn_hooks.py" "$WORK/litellm/bn_hooks.py"
  { printf 'model_list:\n'; explabs_yaml
    printf '\nlitellm_settings:\n  drop_params: true\n  use_chat_completions_url_for_anthropic_messages: true\n  callbacks: ["bn_hooks.proxy_handler_instance"]\n'
    printf '\ngeneral_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY\n'; } > "$WORK/litellm/config.yaml.new"
  chmod 644 "$WORK/litellm/"*   # (read by the container's user)
  litellm_config_safe "$WORK/litellm/config.yaml.new" || { fail "the rendered config is not valid YAML"; exit 1; }
  grep -q 'additional_drop_params: \[.*"frequency_penalty".*"max_tokens"\]' "$WORK/litellm/config.yaml.new" &&
    ok "the config leaves out what qwen3.8-27b does not take (frequency_penalty, …) and max_tokens (its cap: max_completion_tokens)" ||
    fail "the config's drops for qwen3.8-27b: $(grep additional_drop_params "$WORK/litellm/config.yaml.new" | head -n 1)"
  _has_key "$WORK/litellm/config.yaml.new" && fail "the key is in the rendered config"
  mv "$WORK/litellm/config.yaml.new" "$WORK/litellm/config.yaml"
}
chmod 755 "$WORK" "$WORK/litellm"

if [ "$MOCK" = 1 ]; then
  # the stand-in's answers, split as the gateway's are: its /v1/models from the shape of the real one (ids only), one
  # catalog answer per model (tests/fixtures/explabs_catalog/); both plus a model whose calls it answers as on your own
  # provider key
  mkdir -p "$WORK/catalog"; cp "$ROOT/tests/fixtures/explabs_catalog/"*.json "$WORK/catalog/" || exit 2
  sed 's/"qwen3\.8-27b"/"byok-model"/g' "$WORK/catalog/qwen3.8-27b.json" > "$WORK/catalog/byok-model.json"
  # (and a GPT-5.4-or-later name, which LiteLLM moves to the Responses API with thinking and tools: gpt-5-mini's details)
  sed 's/"gpt-5-mini"/"gpt-5.5"/g' "$WORK/catalog/gpt-5-mini.json" > "$WORK/catalog/gpt-5.5.json"
  python3 -I -c 'import json, sys
v = json.load(open(sys.argv[1]))
v["data"] += [{"id": i, "object": "model", "created": 0, "owned_by": "exp"} for i in ("byok-model", "gpt-5.5")]
json.dump(v, open(sys.argv[2], "w"))' "$ROOT/tests/fixtures/explabs_v1_models.json" "$WORK/v1.json" || exit 2
  cp "$HERE/explabs-mock.py" "$WORK/mock.py"; chmod 755 "$WORK/catalog"; chmod 644 "$WORK/v1.json" "$WORK/catalog/"*.json "$WORK/mock.py"

  # --- the catalog streaming slowly, as it did on 2026-10-25: this checkout's own refresh (real curl) against the
  # stand-in on this computer's 127.0.0.1 (http: lib/explabs.sh takes it only while testing), each read limited to 3 s
  HPORT=18520
  while port_in_use "$HPORT" || case "$AVOID_PORTS" in *" $HPORT "*) true ;; *) false ;; esac; do HPORT=$((HPORT + 1)); done
  python3 -I "$WORK/mock.py" "$HPORT" "$WORK/host-reqs.jsonl" "$WORK/v1.json" "$WORK/catalog" "$WORK/slow" 2>/dev/null &
  HPID=$!
  for _ in $(seq 1 20); do [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HPORT/api/models/qwen3.8-27b" 2>/dev/null)" = 200 ] && break; sleep 0.5; done
  (
    EXPLABS_API="http://127.0.0.1:$HPORT/v1"; EXPLABS_CATALOG="http://127.0.0.1:$HPORT/api/models"; XL_HOST="127.0.0.1:$HPORT"
    BEDROCK_NOW_TESTING=1; XL_MODEL_TIMEOUT=3
    explabs_refresh 2>/dev/null
    [ "$(xl_selected | awk -F'\t' '$2 == "qwen3.8-27b" { print $1 }')" = details ] || { echo "qwen3.8-27b has no details from the stand-in"; exit 1; }
    printf 'qwen3.8-27b\n' > "$WORK/slow"
    t0=$SECONDS; explabs_refresh 2> "$WORK/slow.err"; t=$((SECONDS - t0))
    grep -q "timed out after 3 s reading the details of qwen3.8-27b from 127.0.0.1:$HPORT — keeping the model details read before" "$WORK/slow.err" ||
      { echo "the slow catalog said: $(head -c 300 "$WORK/slow.err")"; exit 1; }
    [ "$t" -le 6 ] || { echo "the slow catalog held the refresh $t s"; exit 1; }
    [ "$(xl_selected | awk -F'\t' '$2 == "qwen3.8-27b" { print $1 }')" = details ] || { echo "the cached details went"; exit 1; }
  ) > "$WORK/slow.out" 2>&1 &&
    ok "a catalog that streams slowly: timed out after 3 s with that said, the details read before kept" ||
    fail "the slow catalog: $(cat "$WORK/slow.out")"
  kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
  rm -f "$(xl_cache_tsv)" "$(xl_error_file)" "$WORK/slow"
else
  say "reading the key's model list (GET /v1/models, with the key) and the chosen models' details (GET /api/models/<id>, keyless)"
  rc=0; t0=$SECONDS; xl_fetch_models "$(xl_cache_tsv)" "$KEY" || rc=$?
  say "read in $((SECONDS - t0)) s"
  case "$rc" in 0) ;; 2) fail "the catalog's details could not be read: $XL_ERR" ;; *) echo "the model list could not be read: $XL_ERR" >&2; exit 1 ;; esac
  _render
fi

# --- the container ---
PORT=18490
while port_in_use "$PORT" || case "$AVOID_PORTS" in *" $PORT "*) true ;; *) false ;; esac; do PORT=$((PORT + 1)); done
say "starting $NAME ($IMAGE) on 127.0.0.1:$PORT"
args=(-d --name "$NAME" --label io.bedrock-now.e2e=explabs -p "127.0.0.1:$PORT:4000" -v "$WORK/litellm:/app/config:ro"
      -e EXPLABS_API_KEY -e LITELLM_MASTER_KEY -e LITELLM_LOCAL_MODEL_COST_MAP=True)
if [ "$MOCK" = 1 ]; then
  # the stand-in first; LiteLLM once the config is there (rendered from what the stand-in answered)
  args+=(-v "$WORK/mock.py:/mock/mock.py:ro" -v "$WORK/v1.json:/mock/v1.json:ro" -v "$WORK/catalog:/mock/catalog:ro"
         --entrypoint sh "$IMAGE" -c
         "PY=\$(command -v python3 || command -v python); \$PY /mock/mock.py $MOCK_PORT /tmp/reqs.jsonl /mock/v1.json /mock/catalog & while [ ! -s /app/config/config.yaml ]; do sleep 1; done; exec litellm --config /app/config/config.yaml --port 4000")
else
  args+=("$IMAGE" --config /app/config/config.yaml --port 4000)
fi
EXPLABS_API_KEY="$KEY" LITELLM_MASTER_KEY="$MASTER" docker run "${args[@]}" >/dev/null || { echo "could not start $NAME" >&2; exit 1; }

if [ "$MOCK" = 1 ]; then
  # _get URL OUT — the stand-in's answer, asked from inside the container (it listens there only); a made-up bearer
  _get() {
    docker exec "$NAME" sh -c 'PY=$(command -v python3 || command -v python); $PY -c "import sys, urllib.request as u
sys.stdout.write(u.urlopen(u.Request(sys.argv[1], headers={\"Authorization\": \"Bearer stand-in\"}), timeout=10).read().decode())" "$1"' _ "$1" > "$2" 2>/dev/null
  }
  for _ in $(seq 1 30); do _get "http://127.0.0.1:$MOCK_PORT/v1/models" "$WORK/got-v1.json" && break; sleep 1; done
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))["data"]
assert d and all(set(m) == {"id", "object", "created", "owned_by"} for m in d), d[:2]' "$WORK/got-v1.json" &&
    ok "the stand-in's /v1/models lists ids only, as the gateway's does" || fail "the stand-in's /v1/models: $(head -c 300 "$WORK/got-v1.json")"
  # never details from /v1/models: read as a catalog answer it gives an id alone
  [ -z "$(xl_model_tsv x < "$WORK/got-v1.json" | cut -f2-12 | tr -d '\t\n')" ] && ok "nothing in /v1/models is taken for model details" || fail "/v1/models parsed as details"
  xl_ids < "$WORK/got-v1.json" > "$WORK/ids"; : > "$WORK/det"
  # each chosen model's catalog answer, as the refresh asks for it
  for id in $(xl_wanted); do
    _get "http://127.0.0.1:$MOCK_PORT/api/models/$id" "$WORK/got-$id.json" && xl_model_tsv "$id" < "$WORK/got-$id.json" >> "$WORK/det"
  done
  { printf '# fetched_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; xl_join "$WORK/ids" < "$WORK/det"; } > "$(xl_cache_tsv)"
  _render
fi
up=0
for _ in $(seq 1 90); do
  if [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health/liveliness" 2>/dev/null)" = 200 ]; then up=1; break; fi
  docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true || break
  sleep 2
done
if [ "$up" != 1 ]; then
  fail "LiteLLM did not come up"; docker logs --tail 40 "$NAME" 2>&1 | _mask >&2; exit 1
fi
ok "LiteLLM is up with the rendered config and the hook"

# _call PATH BODY_FILE OUT_PREFIX -> HTTP status; the answer in OUT_PREFIX.json, its headers in OUT_PREFIX.h (the master
# key on curl's stdin)
_call() {
  curl_auth "$MASTER" -sS -m 180 -D "$3.h" -o "$3.json" -w '%{http_code}' -H 'Content-Type: application/json' \
    -H 'anthropic-version: 2023-06-01' --data-binary "@$2" "http://127.0.0.1:$PORT$1" 2>/dev/null || true
}
# _check_cost OUT_PREFIX LABEL — the cost LiteLLM booked (x-litellm-response-cost) is the one the gateway reported
_check_cost() {
  python3 -I - "$1.json" "$1.h" "$2" <<'PY'
import json, sys
body, head, label = json.load(open(sys.argv[1])), open(sys.argv[2]).read(), sys.argv[3]
def header(name):
    return next((float(l.split(":", 1)[1]) for l in head.splitlines() if l.lower().startswith(name + ":")), None)
booked = header("x-litellm-response-cost")
u = body.get("usage") or {}
want = 0.0 if u.get("is_byok") is True else u.get("cost")
# LiteLLM leaves its cost header out for a $0 call: then the figure its cost calculator read first (the hook's)
if booked is None and want == 0:
    booked = header("llm_provider-x-litellm-response-cost")
ok = isinstance(want, (int, float)) and booked is not None and abs(booked - want) < 1e-12
print(json.dumps({"label": label, "reported": u.get("cost"), "is_byok": u.get("is_byok"), "booked": booked, "ok": ok}))
sys.exit(0 if ok else 1)
PY
}

printf '%s' '{"model":"xl/qwen3.8-27b","messages":[{"role":"user","content":"Reply with exactly: DevOS ADE test OK"}],"temperature":0.2,"frequency_penalty":0.1,"max_tokens":300}' > "$WORK/one.req"
say "one completion on xl/qwen3.8-27b"
code="$(_call /v1/chat/completions "$WORK/one.req" "$WORK/one")"
results=()
if [ "$code" = 200 ] && python3 -I -c 'import json, sys; c = json.load(open(sys.argv[1]))["choices"][0]["message"]["content"]; sys.exit(0 if "DevOS ADE test OK" in (c or "") else 1)' "$WORK/one.json"; then
  ok "it answered \"DevOS ADE test OK\""
else
  fail "the completion (HTTP $code): $(head -c 600 "$WORK/one.json" 2>/dev/null | _mask)"
fi
if r="$(_check_cost "$WORK/one" completion)"; then ok "LiteLLM booked what the gateway reported: $r"; else fail "the booked cost: $r"; fi
results+=("$r")
grep -i '^llm_provider-x-gateway-provider:' "$WORK/one.h" | head -n 1 | sed 's/^/      /' >&2 || true

if [ "$MOCK" = 1 ]; then
  docker exec "$NAME" cat /tmp/reqs.jsonl > "$WORK/reqs.jsonl" 2>/dev/null || : > "$WORK/reqs.jsonl"
  python3 -I -c 'import json, sys; b = json.loads(open(sys.argv[1]).readline())["body"]
assert "frequency_penalty" not in b and "max_tokens" not in b and b.get("max_completion_tokens") == 300 and b.get("temperature") == 0.2, b' "$WORK/reqs.jsonl" &&
    ok "the stand-in got only what qwen3.8-27b takes, the cap as max_completion_tokens" || fail "what the stand-in got: $(head -c 400 "$WORK/reqs.jsonl")"
  printf '%s' '{"model":"xl/byok-model","messages":[{"role":"user","content":"hi"}]}' > "$WORK/byok.req"
  _call /v1/chat/completions "$WORK/byok.req" "$WORK/byok" >/dev/null
  if r="$(_check_cost "$WORK/byok" byok)" && printf '%s' "$r" | grep -q '"booked": 0.0'; then ok "a call on your own provider key is booked at \$0"; else fail "BYOK: $r"; fi
  results+=("$r")
  printf '%s' '{"model":"xl/qwen3.8-27b","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hi"}]}' > "$WORK/stream.req"
  _call /v1/chat/completions "$WORK/stream.req" "$WORK/stream" >/dev/null
  grep -q '"cost": *0.00042' "$WORK/stream.json" && grep -q 'test OK' "$WORK/stream.json" &&
    ok "a streamed answer carries the gateway's cost in its last chunk" || fail "the stream: $(tail -c 300 "$WORK/stream.json")"
  printf '%s' '{"model":"xl/qwen3.8-27b","max_tokens":32000,"temperature":0.7,"top_k":40,"messages":[{"role":"user","content":"hi"}]}' > "$WORK/msg.req"
  code="$(_call /v1/messages "$WORK/msg.req" "$WORK/msg")"
  # (its x-litellm-response-cost header is LiteLLM's own estimate for the Anthropic-shaped answer; what LiteLLM books
  # for it is the gateway's figure, as for the completion above — tests/test_explabs.sh and the hook's tests)
  docker exec "$NAME" cat /tmp/reqs.jsonl > "$WORK/reqs.jsonl" 2>/dev/null || : > "$WORK/reqs.jsonl"
  [ "$code" = 200 ] && grep -q 'test OK' "$WORK/msg.json" && tail -n 1 "$WORK/reqs.jsonl" | grep -q '"path": "/v1/chat/completions"' &&
    tail -n 1 "$WORK/reqs.jsonl" | grep -q '"max_completion_tokens": 32000' &&
    ok "Claude Code's /v1/messages: answered through the gateway's Chat Completions, its cap as max_completion_tokens" ||
    fail "/v1/messages (HTTP $code): $(head -c 300 "$WORK/msg.json" | _mask) — the gateway got: $(tail -n 1 "$WORK/reqs.jsonl" | head -c 300)"
  # a model that takes max_tokens under an o-series or GPT-5 name: LiteLLM would rename the cap max_completion_tokens
  printf '%s' '{"model":"xl/gpt-5.1-codex","max_tokens":300,"messages":[{"role":"user","content":"hi"}]}' > "$WORK/codex.req"
  code="$(_call /v1/chat/completions "$WORK/codex.req" "$WORK/codex")"
  docker exec "$NAME" cat /tmp/reqs.jsonl > "$WORK/reqs.jsonl" 2>/dev/null || : > "$WORK/reqs.jsonl"
  [ "$code" = 200 ] && tail -n 1 "$WORK/reqs.jsonl" | python3 -I -c 'import json, sys
b = json.loads(sys.stdin.read())["body"]; sys.exit(0 if b.get("model") == "gpt-5.1-codex" and b.get("max_tokens") == 300 and "max_completion_tokens" not in b else 1)' &&
    ok "xl/gpt-5.1-codex (its details: max_tokens) got its cap as max_tokens" ||
    fail "xl/gpt-5.1-codex (HTTP $code): $(head -c 300 "$WORK/codex.json" | _mask) — the gateway got: $(tail -n 1 "$WORK/reqs.jsonl" | head -c 300)"
  # GPT-5.4 and later with thinking and tools: LiteLLM moves the call to the gateway's Responses API after the hook;
  # the cap goes along (as max_output_tokens)
  printf '%s' '{"model":"xl/gpt-5.5","max_tokens":32000,"thinking":{"type":"enabled","budget_tokens":4096},"tools":[{"name":"Read","description":"read a file","input_schema":{"type":"object","properties":{"p":{"type":"string"}}}}],"messages":[{"role":"user","content":"hi"}]}' > "$WORK/resp.req"
  code="$(_call /v1/messages "$WORK/resp.req" "$WORK/resp")"
  docker exec "$NAME" cat /tmp/reqs.jsonl > "$WORK/reqs.jsonl" 2>/dev/null || : > "$WORK/reqs.jsonl"
  [ "$code" = 200 ] && tail -n 1 "$WORK/reqs.jsonl" | python3 -I -c 'import json, sys
d = json.loads(sys.stdin.read()); b = d["body"]
sys.exit(0 if d["path"] == "/v1/responses" and b.get("model") == "gpt-5.5" and b.get("max_output_tokens") == 32000 else 1)' &&
    ok "/v1/messages with thinking and tools on xl/gpt-5.5: the gateway's Responses API, the cap as max_output_tokens 32000" ||
    fail "xl/gpt-5.5 with thinking and tools (HTTP $code): $(head -c 300 "$WORK/resp.json" | _mask) — the gateway got: $(tail -n 1 "$WORK/reqs.jsonl" | head -c 400)"
  # with extended thinking on, LiteLLM names the model openai/responses/<id>: the hook keeps it on Chat Completions under
  # the id the gateway knows
  printf '%s' '{"model":"xl/claude-fable-5","max_tokens":32000,"thinking":{"type":"enabled","budget_tokens":4096},"messages":[{"role":"user","content":"hi"}]}' > "$WORK/think.req"
  code="$(_call /v1/messages "$WORK/think.req" "$WORK/think")"
  docker exec "$NAME" cat /tmp/reqs.jsonl > "$WORK/reqs.jsonl" 2>/dev/null || : > "$WORK/reqs.jsonl"
  [ "$code" = 200 ] && grep -q 'test OK' "$WORK/think.json" && tail -n 1 "$WORK/reqs.jsonl" | python3 -I -c 'import json, sys
d = json.loads(sys.stdin.read()); sys.exit(0 if d["path"] == "/v1/chat/completions" and d["body"].get("model") == "claude-fable-5" else 1)' &&
    ok "/v1/messages with extended thinking on xl/claude-fable-5: Chat Completions, under the model's own id" ||
    fail "/v1/messages with thinking (HTTP $code): $(head -c 300 "$WORK/think.json" | _mask) — the gateway got: $(tail -n 1 "$WORK/reqs.jsonl" | head -c 300)"
fi

# --- the key, nowhere ---
docker logs "$NAME" > "$WORK/container.log" 2>&1 || true
leak=''
for f in "$WORK/litellm/config.yaml" "$WORK/container.log" "$WORK"/*.json "$WORK"/*.h "$WORK"/*.req; do
  [ -e "$f" ] || continue
  if _has_key "$f"; then leak="$leak ${f#"$WORK"/}"; fi
done
if [ -n "$leak" ]; then fail "the key is in:$leak"; else ok "the key is in none of the config, the answers, their headers or the container's log"; fi
rm -f "$WORK/container.log"

summary="$(printf '%s\n' "${results[@]}" | python3 -I -c 'import json, sys
print(json.dumps({"mode": sys.argv[1], "model": "xl/qwen3.8-27b", "image": sys.argv[2], "failures": int(sys.argv[3]),
                  "calls": [json.loads(l) for l in sys.stdin if l.strip()]}, indent=1))' "$([ "$MOCK" = 1 ] && echo mock || echo gateway)" "$IMAGE" "$FAILS")"
printf '%s\n' "$summary" > "$OUT/explabs.json"
if _has_key "$OUT/explabs.json"; then rm -f "$OUT/explabs.json"; fail "the results held the key (removed)"; fi
say "results: $OUT/explabs.json"
if [ "$FAILS" -gt 0 ]; then printf '\n%d check(s) failed\n' "$FAILS"; exit 1; fi
printf '\nall checks passed\n'
