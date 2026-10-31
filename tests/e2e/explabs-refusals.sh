#!/usr/bin/env bash
# Opt-in end-to-end check of how the Experiential Labs gateway's refusals reach you (run by hand; not part of
# tests/run.sh, CI or tests/e2e/run.sh). No AWS, no real gateway, no model call that costs anything: a stand-in for the
# gateway (tests/e2e/explabs-mock.py, inside the LiteLLM container on its 127.0.0.1) answers every call. Throwaway
# containers, all named bne2e-xlref-* and labelled io.devos-ade.e2e=explabs-refusals, removed afterwards by those names
# (nothing is pruned), and a volume for the Code page's socket:
#   bne2e-xlref-litellm   LiteLLM (compose.yaml's image) with this checkout's hook and an Experiential Labs config whose
#                         key is one of the stand-in's "mock-nofree-" keys: a key whose model list names no free alias
#                         (the owner's, JON-521). The config still holds xl/deepseek-v4.1-flash:free — rendered while the
#                         list named it — so a call on it reaches the gateway, which refuses it.
#   bne2e-xlref-term      the terminal image (claude, bn-coded) with this checkout's devos-claude and bn-coded.mjs
#   (a run of the code image) this checkout's code/server: Code page sessions through bn-coded
# What it checks (JON-521) — first, the gateway's 403 "The requested model alias is not granted to this identity" reaches every
# caller as a 400 invalid_request_error saying "Your Experiential Labs key isn't allowed to use this model" (LiteLLM's
# hook) — on /v1/messages, Claude Code's, and on Chat Completions; a Code page session shows that sentence with another
# model as the way on (fix: model) and the gateway's words apart, as a provider's (no Git sign-in line); devos-claude -p
# in the terminal says the same and never "Please run /login"; Claude Code never sends a refused prompt again (LiteLLM's own
# router tries a 403 up to twice more: a refusal, free). Then the gateway's one-time 402 when a model's free promotion
# has ended (the stand-in's MOCK_PROMO_ENDED: deepseek-v4.1-flash, qwen3.8-27b, gpt-5-mini): every caller gets a 400
# saying "Experiential Labs: the free promotion for … has ended. From now on its requests are charged to your Experiential
# Labs credits. Send your message again to continue, or pick another model."; nothing sends it again by itself — exactly
# one call at the gateway for the refused prompt, LiteLLM's, the Code page's or devos-claude's —; the next send is
# answered, and LiteLLM books what the gateway reported for it (Actual spend, never $0).
#
#   --terminal-image IMG, --code-image IMG   the images (default: the newest bne2e-cache/terminal and bne2e-cache/code
#                        that tests/e2e/run.sh left; this checkout's changed files are mounted over theirs)
#   --out DIR            results (default tests/e2e/out, gitignored): explabs-refusals.json and the stand-in's record
# Docker runs it: on a machine that shares a heavy-job lock, run the whole script inside that lock.
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
P=bne2e-xlref
VOL=$P-sock; LL=$P-litellm; TC=$P-term; CC=$P-code; NET=$P-net
LABEL=io.devos-ade.e2e=explabs-refusals
OUT="$ROOT/tests/e2e/out"; TIMG=''; CIMG=''
REFUSED=xl/deepseek-v4.1-flash:free   # (the free alias the key's list does not name)
AVOID_PORTS=" 80 443 3000 3009 4000 8080 8081 8090 8765 8787 8788 8800 "
MOCK_PORT=18471
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    --terminal-image) TIMG="${2:?--terminal-image IMG}"; shift 2 ;;
    --code-image) CIMG="${2:?--code-image IMG}"; shift 2 ;;
    -h | --help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/explabs-refusals.sh --help)" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*" >&2; }
FAILS=0; CHECKS=()
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$*"); }
ok() { printf 'ok    %s\n' "$*" >&2; CHECKS+=("ok	$*"); }
stop() { echo "$1" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$1"); exit "${2:-1}"; }
command -v docker >/dev/null 2>&1 || { echo "needs docker" >&2; exit 2; }

newest() { docker image ls --filter "reference=$1" --format '{{.CreatedAt}}	{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -r | head -n 1 | cut -f2; }
TIMG="${TIMG:-$(newest 'bne2e-cache/terminal')}"; CIMG="${CIMG:-$(newest 'bne2e-cache/code')}"
need_image() { [ -n "$1" ] || { echo "no $2 image: run tests/e2e/run.sh once (it leaves bne2e-cache/$2:…), or pass --$2-image" >&2; exit 2; }; }
need_image "$TIMG" terminal; need_image "$CIMG" code
LIMG="$(sed -n 's/^    image: \(ghcr.io\/berriai\/litellm:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
[ -n "$LIMG" ] || { echo "no LiteLLM image in compose.yaml" >&2; exit 2; }

WORK="$ROOT/tests/e2e/work/$P"
RESULT="$OUT/explabs-refusals.json"; RESULT_DONE=0
_result() {   # the results file: this run's checks, finished or not
  mkdir -p "$OUT" 2>/dev/null || return 0
  printf '%s\n' ${CHECKS[@]+"${CHECKS[@]}"} | python3 -I -c 'import json, sys
checks = [dict(zip(("status", "check"), l.rstrip("\n").split("\t", 1))) for l in sys.stdin if "\t" in l]
print(json.dumps({"finished": sys.argv[1] == "1", "failures": int(sys.argv[2]), "images": sys.argv[3].split(","), "checks": checks}, indent=1))' \
    "$1" "$FAILS" "$TIMG,$CIMG,$LIMG" > "$RESULT" 2>/dev/null || true
}
ours() { [ "$(docker "$1" inspect -f '{{index .'"$2"' "io.devos-ade.e2e"}}' "$3" 2>/dev/null)" = explabs-refusals ]; }
cleanup() {
  local c
  for c in "$CC" "$TC" "$LL"; do ! ours container Config.Labels "$c" || docker rm -f "$c" >/dev/null 2>&1; done
  ! ours volume Labels "$VOL" || docker volume rm "$VOL" >/dev/null 2>&1
  ! ours network Labels "$NET" || docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$WORK"
  [ "$RESULT_DONE" = 1 ] || _result 0
}
for c in "$CC" "$TC" "$LL"; do
  if docker container inspect "$c" >/dev/null 2>&1 && ! ours container Config.Labels "$c"; then echo "a container named $c exists and is not this check's: not touching it" >&2; exit 2; fi
done
for k in "volume:$VOL" "network:$NET"; do
  if docker "${k%%:*}" inspect "${k#*:}" >/dev/null 2>&1 && ! ours "${k%%:*}" Labels "${k#*:}"; then echo "a ${k%%:*} named ${k#*:} exists and is not this check's: not touching it" >&2; exit 2; fi
done
trap cleanup EXIT
trap 'exit 130' INT TERM
cleanup; RESULT_DONE=0   # (whatever an interrupted run left)
mkdir -p "$OUT" "$WORK/litellm" || exit 2
chmod 755 "$WORK" "$WORK/litellm"

# --- this checkout's config: the gateway's models as a refresh cached them while the list still named the free alias ---
STACK_DIR="$ROOT"; ENV_FILE=/dev/null; STATE_DIR="$WORK/state"
export STACK_DIR ENV_FILE STATE_DIR
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
EXPLABS_API="http://127.0.0.1:$MOCK_PORT/v1"; DEVOS_ADE_TESTING=1
# (the key LiteLLM sends: one the stand-in lists no free alias for; made here, never a key-like literal)
XLKEY="mock-nofree-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
get_env() { case "$1" in EXPLABS_API_KEY) printf '%s' "$XLKEY" ;; EXPLABS_MODELS) printf '%s,deepseek-v4.1-flash,qwen3.8-27b,gpt-5-mini' "${REFUSED#xl/}" ;; esac; }
STACK_DIR="$WORK"; mkdir -p "$STATE_DIR"
xl_cache_current() { [ -s "$(xl_cache_tsv)" ]; }
xl_ids < "$ROOT/tests/fixtures/explabs_v1_models.json" > "$WORK/ids"; : > "$WORK/det"
while IFS= read -r id; do
  id="${id%:free}"
  [ ! -r "$ROOT/tests/fixtures/explabs_catalog/$id.json" ] || xl_model_tsv "$id" < "$ROOT/tests/fixtures/explabs_catalog/$id.json" >> "$WORK/det"
done < "$WORK/ids"
{ printf '# fetched_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; xl_free_rows "$WORK/ids" < "$WORK/det" | xl_join "$WORK/ids"; } > "$(xl_cache_tsv)"
cp "$ROOT/lib/litellm-hooks/bn_hooks.py" "$WORK/litellm/bn_hooks.py"
{ printf 'model_list:\n'; explabs_yaml
  # (the Claude models Claude Code's background work would ask: refused by the stand-in, never answered)
  for m in claude-haiku-5-5 claude-sonnet-5-5 claude-opus-5-5; do
    printf '  - model_name: "%s"\n    litellm_params:\n      model: "openai/claude-stand-in"\n      api_base: "http://127.0.0.1:%s/v1"\n      api_key: "stand-in"\n' "$m" "$MOCK_PORT"
    printf '    model_info:\n      mode: "chat"\n'
  done
  printf '\nlitellm_settings:\n  drop_params: true\n  use_chat_completions_url_for_anthropic_messages: true\n  callbacks: ["bn_hooks.proxy_handler_instance"]\n'
  printf '\ngeneral_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY\n'; } > "$WORK/litellm/config.yaml"
grep -q "model_name: \"$REFUSED\"" "$WORK/litellm/config.yaml" || stop "the config does not hold $REFUSED"
mkdir -p "$WORK/mock" && cp "$HERE/explabs-mock.py" "$WORK/mock/mock.py" && cp "$ROOT/tests/fixtures/explabs_v1_models.json" "$WORK/mock/v1.json" &&
  cp -R "$ROOT/tests/fixtures/explabs_catalog" "$WORK/mock/catalog" || exit 2
cp "$HERE/explabs-refusals-code.mjs" "$WORK/drive.mjs"
chmod -R a+rX "$WORK/litellm" "$WORK/mock" "$WORK/drive.mjs"

free_port() {
  local p="$1"
  while port_in_use "$p" || case "$AVOID_PORTS" in *" $p "*) true ;; *) false ;; esac; do p=$((p + 1)); done
  printf '%s\n' "$p"
}
MASTER="sk-e2e-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

# --- the containers ---
docker network create --label "$LABEL" "$NET" >/dev/null || stop "could not make the network $NET"
docker volume create --label "$LABEL" "$VOL" >/dev/null || stop "could not make the volume $VOL"
LPORT="$(free_port 18590)"
say "LiteLLM ($LIMG) with the stand-in, on 127.0.0.1:$LPORT"
EXPLABS_API_KEY="$XLKEY" LITELLM_MASTER_KEY="$MASTER" docker run -d --name "$LL" --label "$LABEL" --network "$NET" --network-alias litellm \
  -p "127.0.0.1:$LPORT:4000" -v "$WORK/litellm:/app/config:ro" -v "$WORK/mock:/mock:ro" \
  -e EXPLABS_API_KEY -e LITELLM_MASTER_KEY -e STORE_MODEL_IN_DB=False -e LITELLM_LOCAL_MODEL_COST_MAP=True \
  -e MOCK_PROMO_ENDED="deepseek-v4.1-flash qwen3.8-27b gpt-5-mini" --entrypoint sh "$LIMG" -c \
  "PY=\$(command -v python3 || command -v python); \$PY /mock/mock.py $MOCK_PORT /tmp/reqs.jsonl /mock/v1.json /mock/catalog & exec litellm --config /app/config/config.yaml --port 4000" \
  >/dev/null || stop "could not start $LL"
up=0
for _ in $(seq 1 120); do
  [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$LPORT/health/readiness" 2>/dev/null)" = 200 ] && { up=1; break; }
  docker container inspect -f '{{.State.Running}}' "$LL" 2>/dev/null | grep true >/dev/null || break
  sleep 2
done
[ "$up" = 1 ] || { docker logs --tail 30 "$LL" 2>&1 | sed "s/$MASTER/[master]/g" >&2; stop "LiteLLM did not come up"; }
ok "LiteLLM is up with this checkout's hook and an Experiential Labs key whose list names no free alias"

# standin_calls MODEL -> how many calls the stand-in got for MODEL (its id at the gateway) so far
standin_calls() {
  docker exec "$LL" cat /tmp/reqs.jsonl 2>/dev/null | python3 -I -c 'import json, sys
print(sum(1 for l in sys.stdin if l.strip() and (json.loads(l).get("body") or {}).get("model") == sys.argv[1]))' "$1"
}
# post PATH BODY OUT -> HTTP status of LiteLLM's answer (the master key on curl's stdin)
post() { curl_auth "$MASTER" -sS -m 60 -X POST -H 'Content-Type: application/json' --data-binary "$2" -o "$3" -w '%{http_code}' "http://127.0.0.1:$LPORT$1" 2>/dev/null; }

# --- 1. LiteLLM itself: a 400 in plain words, on Claude Code's API and on Chat Completions ---
say "LiteLLM's answer for $REFUSED"
code="$(post /v1/messages "{\"model\":\"$REFUSED\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" "$WORK/msg.json")"
if [ "$code" = 400 ] && grep -q "Your Experiential Labs key isn't allowed to use this model ($REFUSED)" "$WORK/msg.json" && grep -q invalid_request_error "$WORK/msg.json"; then
  ok "/v1/messages: 400 invalid_request_error, \"Your Experiential Labs key isn't allowed to use this model\" (not the gateway's 403)"
else fail "/v1/messages: HTTP $code $(head -c 400 "$WORK/msg.json")"; fi
code="$(post /v1/chat/completions "{\"model\":\"$REFUSED\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" "$WORK/cc.json")"
if [ "$code" = 400 ] && grep -q "Your Experiential Labs key isn't allowed to use this model" "$WORK/cc.json"; then ok "/v1/chat/completions: 400 in the same words"
else fail "/v1/chat/completions: HTTP $code $(head -c 400 "$WORK/cc.json")"; fi
# (LiteLLM's router tries a 403 again itself — num_retries, 2 by default — on a refusal that costs nothing; never more)
n="$(standin_calls "${REFUSED#xl/}")"
if [ "$n" -ge 2 ] && [ "$n" -le 6 ]; then ok "the gateway got $n call(s) for the 2 requests (LiteLLM's own retries of a free 403 at most)"
else fail "the gateway got $n call(s) for ${REFUSED#xl/} (want 2 to 6)"; fi

say "the terminal ($TIMG): bn-coded with this checkout's bn-coded.mjs and devos-claude"
docker run -d --name "$TC" --label "$LABEL" --network "$NET" -v "$VOL:/run/bn-code" \
  -v "$ROOT/terminal/bin/bn-coded.mjs:/usr/local/bin/bn-coded.mjs:ro" -v "$ROOT/terminal/bin/devos-claude:/usr/local/bin/devos-claude:ro" \
  -v "$ROOT/terminal/bin/claude-bedrock:/usr/local/bin/claude-bedrock:ro" \
  -e ANTHROPIC_BASE_URL=http://litellm:4000 -e ANTHROPIC_AUTH_TOKEN="$MASTER" -e ANTHROPIC_MODEL=claude-haiku-5-5 \
  -e ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5 -e ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5-5 -e ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-5 \
  -e CLAUDE_BEDROCK_OPUS_MODEL=claude-opus-5-5 -e CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e DISABLE_AUTOUPDATER=1 -e TERMINAL_AUTO_MODE=false -e API_TIMEOUT_MS=60000 --entrypoint sh "$TIMG" -c \
  'printf "{\"hasCompletedOnboarding\":true,\"theme\":\"dark\"}\n" > "$HOME/.claude.json"; exec node /usr/local/bin/bn-coded.mjs' >/dev/null || stop "could not start $TC"
for _ in $(seq 1 30); do docker exec "$TC" test -S /run/bn-code/coded.sock 2>/dev/null && break; sleep 1; done
docker exec "$TC" test -S /run/bn-code/coded.sock 2>/dev/null || { docker logs --tail 20 "$TC" >&2; stop "bn-coded did not listen"; }
TUSER="$(docker exec "$TC" sh -c 'echo "$(id -u):$(id -g)"' 2>/dev/null)"   # (the code container runs as the same user)
case "$TUSER" in [0-9]*:[0-9]*) ;; *) stop "could not read the terminal's user" ;; esac
ok "bn-coded listens in the terminal (Claude Code $(docker exec "$TC" claude --version 2>/dev/null | head -n 1))"

# code_session MODEL TIMES -> the driver's JSON line (a Code page session on MODEL, TIMES prompts)
code_session() {
  docker run --rm --name "$CC" --label "$LABEL" --network none --user "$TUSER" -v "$VOL:/run/bn-code:ro" \
    -v "$ROOT/code/server:/opt/code/server:ro" -v "$WORK/drive.mjs:/opt/code/e2e-explabs-refusals.mjs:ro" -w /opt/code \
    --entrypoint node "$CIMG" /opt/code/e2e-explabs-refusals.mjs "$1" "$2" 2> "$WORK/code.err" | tail -n 1
}

# --- 2. a Code page session on the refused alias ---
say "a Code page session on $REFUSED ($CIMG, this checkout's code/server)"
before="$(standin_calls "${REFUSED#xl/}")"
code_session "$REFUSED" 1 > "$WORK/code1.json"
if python3 -I - "$WORK/code1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
t = d["turns"][0]
e = [x for x in t["errors"] if x["message"] == "Your Experiential Labs key isn't allowed to use this model"]
assert e, t
assert e[0]["fix"] == "model" and e[0]["provider"] is True, e
assert "isn't allowed to use this model" in (e[0]["said"] or ""), e   # (the words apart: Claude Code's, from the hook)
assert t["result"]["is_error"] and "/login" not in json.dumps(d), d
assert not any(x["message"] == "The model's provider refused the key" for x in t["errors"]), t
PY
then ok "the Code page says \"Your Experiential Labs key isn't allowed to use this model\", with another model as the way on, the words apart as a provider's"
else fail "the Code page session: $(head -c 700 "$WORK/code1.json") $(tail -c 300 "$WORK/code.err")"; fi
n=$(( $(standin_calls "${REFUSED#xl/}") - before ))
if [ "$n" -ge 1 ] && [ "$n" -le 3 ]; then ok "the Code page's prompt: one request of Claude Code's ($n call(s) at the gateway with LiteLLM's own retries of a free 403)"
else fail "the Code page's prompt reached the gateway $n time(s) (want 1 to 3: Claude Code tried again)"; fi

# --- 3. devos-claude in the terminal ---
say "devos-claude --model $REFUSED -p … in the terminal"
before="$(standin_calls "${REFUSED#xl/}")"
term_out="$(docker exec -w /workspace "$TC" timeout 180 devos-claude --model "$REFUSED" -p 'Reply with exactly: DevOS ADE test OK' 2>&1)"
printf '%s\n' "$term_out" > "$WORK/term.out"
case "$term_out" in
  *'/login'*) fail "devos-claude asks for /login: $(printf '%s' "$term_out" | tail -c 400)" ;;
  *"Your Experiential Labs key isn't allowed to use this model"*) ok "devos-claude says \"Your Experiential Labs key isn't allowed to use this model\" (no /login)" ;;
  *) fail "devos-claude: $(printf '%s' "$term_out" | tail -c 500)" ;;
esac
n=$(( $(standin_calls "${REFUSED#xl/}") - before ))
if [ "$n" -ge 1 ] && [ "$n" -le 3 ]; then ok "devos-claude's prompt: one request of Claude Code's ($n call(s) at the gateway with LiteLLM's own retries of a free 403)"
else fail "devos-claude's prompt reached the gateway $n time(s) (want 1 to 3: Claude Code tried again)"; fi

# --- 4. the gateway's one-time notice that a free promotion has ended: said, never sent again by itself ---
PROMO_SAID="the free promotion for"
CHARGED="From now on its requests are charged to your Experiential Labs credits. Send your message again to continue, or pick another model."
# (LiteLLM itself, on Chat Completions: the 400 in plain words, one call at the gateway; the next is answered and charged)
say "LiteLLM's answer for xl/gpt-5-mini, whose free promotion has ended"
code="$(post /v1/chat/completions '{"model":"xl/gpt-5-mini","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' "$WORK/p1.json")"
n="$(standin_calls gpt-5-mini)"
if [ "$code" = 400 ] && grep -q "Experiential Labs: $PROMO_SAID" "$WORK/p1.json" && grep -qF "$CHARGED" "$WORK/p1.json" && [ "$n" = 1 ]; then
  ok "LiteLLM: 400 "Experiential Labs: the free promotion for … has ended …", and the gateway asked once (no retry)"
else fail "LiteLLM on the ended promotion: HTTP $code, $n call(s): $(head -c 400 "$WORK/p1.json")"; fi
cost="$(curl_auth "$MASTER" -sS -m 60 -X POST -H 'Content-Type: application/json' --data-binary '{"model":"xl/gpt-5-mini","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
  -D "$WORK/p2.h" -o "$WORK/p2.json" -w '%{http_code}' "http://127.0.0.1:$LPORT/v1/chat/completions" 2>/dev/null)"
booked="$(tr -d '\r' < "$WORK/p2.h" | sed -n 's/^x-litellm-response-cost: //Ip' | head -n 1)"
if [ "$cost" = 200 ] && python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "${booked:-0}" 2>/dev/null; then
  ok "sent again, it is answered and booked at what the gateway reported (\$$booked: Actual spend, not \$0)"
else fail "sent again: HTTP $cost, booked ${booked:-nothing}: $(head -c 300 "$WORK/p2.json")"; fi

# (a Code page session: the first prompt refused with the notice, the second — sent by you — answered)
say "a Code page session on xl/deepseek-v4.1-flash, whose free promotion has ended: two prompts"
code_session xl/deepseek-v4.1-flash 2 > "$WORK/code2.json"
docker exec "$LL" cat /tmp/reqs.jsonl > "$WORK/reqs.jsonl" 2>/dev/null || : > "$WORK/reqs.jsonl"
if python3 -I - "$WORK/code2.json" "$WORK/reqs.jsonl" "$CHARGED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
t1, t2 = d["turns"]
e = [x for x in t1["errors"] if x["fix"] == "model" and x["provider"]]
assert e and e[0]["message"].startswith("Experiential Labs: the free promotion for this model has ended.") and e[0]["message"].endswith(sys.argv[3]), t1
assert "GLM" in (e[0]["said"] or "") or "free promotion" in (e[0]["said"] or ""), e   # (the gateway's words, apart)
assert t1["result"]["is_error"] and not t1["result"]["ok"], t1
assert t2["result"]["ok"] and not t2["errors"], t2                                       # (sent again: answered)
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
first = [c for c in calls if (c.get("body") or {}).get("model") == "deepseek-v4.1-flash" and c["t"] * 1000 <= t1["endedAt"]]
assert len(first) == 1, len(first)                                                      # (never sent again by itself)
PY
then ok "the Code page says the promotion ended, that sending again is charged (another model as the way on); one call at the gateway; sent again, answered"
else fail "the Code page session on the ended promotion: $(head -c 900 "$WORK/code2.json") $(tail -c 300 "$WORK/code.err")"; fi

# (devos-claude in the terminal: the same notice, never /login; sent again, answered)
say "devos-claude --model xl/qwen3.8-27b -p … twice"
out1="$(docker exec -w /workspace "$TC" timeout 180 devos-claude --model xl/qwen3.8-27b -p 'Reply with exactly: DevOS ADE test OK' 2>&1)"
n1="$(standin_calls qwen3.8-27b)"
out2="$(docker exec -w /workspace "$TC" timeout 180 devos-claude --model xl/qwen3.8-27b -p 'Reply with exactly: DevOS ADE test OK' 2>&1)"
printf '%s\n---\n%s\n' "$out1" "$out2" > "$WORK/term2.out"
case "$out1" in
  *'/login'*) fail "devos-claude asks for /login on the ended promotion: $(printf '%s' "$out1" | tail -c 400)" ;;
  *"$PROMO_SAID"*"$CHARGED"*) [ "$n1" = 1 ] && ok "devos-claude says the promotion ended and that sending again is charged; one call at the gateway" ||
      fail "devos-claude's refused prompt reached the gateway $n1 time(s) (want 1)" ;;
  *) fail "devos-claude on the ended promotion: $(printf '%s' "$out1" | tail -c 500)" ;;
esac
case "$out2" in *'DevOS ADE test OK'*) ok "devos-claude, sent again: answered" ;; *) fail "devos-claude sent again: $(printf '%s' "$out2" | tail -c 400)" ;; esac

# (the stand-in's record beside the results: each call's path, model and whether it was keyed)
docker exec "$LL" cat /tmp/reqs.jsonl 2>/dev/null | python3 -I -c 'import json, sys
out = [{"path": d.get("path"), "model": (d.get("body") or {}).get("model"), "bearer": d.get("bearer")} for d in (json.loads(l) for l in sys.stdin if l.strip())]
json.dump(out, open(sys.argv[1], "w"), indent=1)' "$OUT/explabs-refusals-standin.json" 2>/dev/null || true
# the key is nowhere in what this run keeps
if printf '%s\n' "$XLKEY" | grep -qF -f - "$OUT/explabs-refusals-standin.json" "$WORK/msg.json" "$WORK/cc.json" "$WORK/code1.json" "$WORK/term.out" \
     "$WORK/p1.json" "$WORK/p2.json" "$WORK/code2.json" "$WORK/term2.out" 2>/dev/null; then
  fail "the stand-in key is in a result file"
else ok "the gateway key is in no result"; fi

_result 1; RESULT_DONE=1
say "$( [ "$FAILS" = 0 ] && echo "all checks passed" || echo "$FAILS check(s) failed") — $RESULT"
[ "$FAILS" = 0 ]
