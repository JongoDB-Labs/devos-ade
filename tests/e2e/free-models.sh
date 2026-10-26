#!/usr/bin/env bash
# Opt-in end-to-end check that free models book $0 Actual (run by hand; not part of tests/run.sh, CI or
# tests/e2e/run.sh). No AWS, no real gateway: a stand-in for Experiential Labs (tests/e2e/explabs-mock.py, inside the
# LiteLLM container on its 127.0.0.1) answers every model call. Throwaway containers, a network and a volume, all named
# bne2e-free-* and labelled io.bedrock-now.e2e=free-models, removed afterwards by those names (nothing is pruned):
#   bne2e-free-pg        Postgres (compose.yaml's image): LiteLLM's keys and spend log
#   bne2e-free-litellm   LiteLLM (compose.yaml's image) with this checkout's hook and config for Experiential Labs —
#                        xl/deepseek-v4.1-flash:free (a free tier: the stand-in reports $0) and xl/qwen3.8-27b — plus
#                        claude-haiku-5-5, claude-sonnet-5-5, claude-sonnet-5 and claude-opus-5-5 as PRICED stand-ins:
#                        a request that falls back to a Claude model shows up as spend
#   bne2e-free-term      the terminal image (claude, bn-coded) with this checkout's devos-claude (and the claude-bedrock
#                        shim) and bn-coded.mjs
#   bne2e-free-code      the code image with this checkout's code/server: one Code page session through bn-coded
#   bne2e-free-owui      Open WebUI (this stack's image) with no task model (TASK_MODEL_EXTERNAL blank), as setup
#                        now leaves it
# What it checks, each on a key of its own: a Code page session on xl/deepseek-v4.1-flash:free, a Chat conversation on
# it with its title and tags made, and `devos-claude --model xl/deepseek-v4.1-flash:free -p …` in the terminal all
# answer; everything the stand-in got is for that model (none for a Claude model: Claude Code's background work and
# Chat's titles follow the model); every call is booked to the key it came on, under that key's alias — Chat's three
# (the answer, its title, its tags) to Open WebUI's, which its budget and Home's Chat row count — at $0, none to another
# key or to none; each key's spend stays $0; and Home's Equivalent
# view (portal/portal/usage.py, run against this LiteLLM) prices the same usage at deepseek-v4.1-flash's prices while
# Actual stays $0.
#
#   --terminal-image IMG, --code-image IMG, --owui-image IMG   the images (default: the newest bne2e-cache/terminal,
#                        bne2e-cache/code and bne2e-cache/open-webui that tests/e2e/run.sh left; this checkout's
#                        changed files are mounted over theirs)
#   --out DIR            results (default tests/e2e/out, gitignored): free-models.json, free-models-spend.json (each
#                        spend-log row: the key it was booked to, its alias, tags, end user; the key's hash cut short)
#                        and free-models-standin.json (each call the stand-in got)
# Docker runs it: on a machine that shares a heavy-job lock, run the whole script inside that lock.
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
P=bne2e-free
NET=$P-net; VOL=$P-sock; PG=$P-pg; LL=$P-litellm; TC=$P-term; CC=$P-code; OW=$P-owui
LABEL=io.bedrock-now.e2e=free-models
OUT="$ROOT/tests/e2e/out"; TIMG=''; CIMG=''; OIMG=''
MODEL=xl/deepseek-v4.1-flash:free
AVOID_PORTS=" 80 443 3000 3009 4000 8080 8081 8090 8765 8787 8788 8800 "
MOCK_PORT=18471
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    --terminal-image) TIMG="${2:?--terminal-image IMG}"; shift 2 ;;
    --code-image) CIMG="${2:?--code-image IMG}"; shift 2 ;;
    --owui-image) OIMG="${2:?--owui-image IMG}"; shift 2 ;;
    -h | --help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/free-models.sh --help)" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*" >&2; }
FAILS=0; CHECKS=()
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$*"); }
ok() { printf 'ok    %s\n' "$*" >&2; CHECKS+=("ok	$*"); }
stop() { echo "$1" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$1"); exit "${2:-1}"; }
command -v docker >/dev/null 2>&1 || { echo "needs docker" >&2; exit 2; }

newest() { docker image ls --filter "reference=$1" --format '{{.CreatedAt}}	{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -r | head -n 1 | cut -f2; }
TIMG="${TIMG:-$(newest 'bne2e-cache/terminal')}"; CIMG="${CIMG:-$(newest 'bne2e-cache/code')}"; OIMG="${OIMG:-$(newest 'bne2e-cache/open-webui')}"
need_image() { [ -n "$1" ] || { echo "no $2 image: run tests/e2e/run.sh once (it leaves bne2e-cache/$2:…), or pass --${3:-$2}-image" >&2; exit 2; }; }
need_image "$TIMG" terminal; need_image "$CIMG" code; need_image "$OIMG" open-webui owui
LIMG="$(sed -n 's/^    image: \(ghcr.io\/berriai\/litellm:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
PIMG="$(sed -n 's/^    image: \(pgvector\/pgvector:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
[ -n "$LIMG" ] && [ -n "$PIMG" ] || { echo "no LiteLLM or Postgres image in compose.yaml" >&2; exit 2; }

WORK="$ROOT/tests/e2e/work/$P"
RESULT="$OUT/free-models.json"; RESULT_DONE=0
_result() {   # the results file: this run's checks, finished or not
  mkdir -p "$OUT" 2>/dev/null || return 0
  printf '%s\n' ${CHECKS[@]+"${CHECKS[@]}"} | python3 -I -c 'import json, sys
checks = [dict(zip(("status", "check"), l.rstrip("\n").split("\t", 1))) for l in sys.stdin if "\t" in l]
print(json.dumps({"finished": sys.argv[1] == "1", "failures": int(sys.argv[2]), "images": sys.argv[3].split(","), "checks": checks}, indent=1))' \
    "$1" "$FAILS" "$TIMG,$CIMG,$OIMG,$LIMG,$PIMG" > "$RESULT" 2>/dev/null || true
}
ours() { [ "$(docker "$1" inspect -f '{{index .'"$2"' "io.bedrock-now.e2e"}}' "$3" 2>/dev/null)" = free-models ]; }
cleanup() {
  local c
  for c in "$CC" "$OW" "$TC" "$LL" "$PG"; do ! ours container Config.Labels "$c" || docker rm -f "$c" >/dev/null 2>&1; done
  ! ours volume Labels "$VOL" || docker volume rm "$VOL" >/dev/null 2>&1
  ! ours network Labels "$NET" || docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$WORK"
  [ "$RESULT_DONE" = 1 ] || _result 0
}
for c in "$CC" "$OW" "$TC" "$LL" "$PG"; do
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

# --- this checkout's config: the gateway's models from the fixtures (as a refresh caches them), the stand-in's address ---
STACK_DIR="$ROOT"; ENV_FILE=/dev/null; STATE_DIR="$WORK/state"
export STACK_DIR ENV_FILE STATE_DIR
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
EXPLABS_API="http://127.0.0.1:$MOCK_PORT/v1"; BEDROCK_NOW_TESTING=1
XLKEY="mock-key-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
get_env() { case "$1" in EXPLABS_API_KEY) printf '%s' "$XLKEY" ;; EXPLABS_MODELS) printf '%s,qwen3.8-27b' "${MODEL#xl/}" ;; esac; }
STACK_DIR="$WORK"; mkdir -p "$STATE_DIR"
xl_cache_current() { [ -s "$(xl_cache_tsv)" ]; }
xl_ids < "$ROOT/tests/fixtures/explabs_v1_models.json" > "$WORK/ids"; : > "$WORK/det"
while IFS= read -r id; do
  [ ! -r "$ROOT/tests/fixtures/explabs_catalog/$id.json" ] || xl_model_tsv "$id" < "$ROOT/tests/fixtures/explabs_catalog/$id.json" >> "$WORK/det"
done < "$WORK/ids"
{ printf '# fetched_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; xl_join "$WORK/ids" < "$WORK/det"; } > "$(xl_cache_tsv)"
cp "$ROOT/lib/litellm-hooks/bn_hooks.py" "$WORK/litellm/bn_hooks.py"
{ printf 'model_list:\n'; explabs_yaml
  # (the Claude models Claude Code and Chat would fall back to: priced, so a request that reached one is spend)
  for m in claude-haiku-5-5 claude-sonnet-5-5 claude-sonnet-5 claude-opus-5-5; do
    printf '  - model_name: "%s"\n    litellm_params:\n      model: "openai/claude-stand-in"\n      api_base: "http://127.0.0.1:%s/v1"\n      api_key: "stand-in"\n' "$m" "$MOCK_PORT"
    printf '    model_info:\n      mode: "chat"\n      input_cost_per_token: 0.000001\n      output_cost_per_token: 0.000005\n'
  done
  printf '\nlitellm_settings:\n  drop_params: true\n  use_chat_completions_url_for_anthropic_messages: true\n  callbacks: ["bn_hooks.proxy_handler_instance"]\n'
  printf '\ngeneral_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY\n  proxy_batch_write_at: 2\n'; } > "$WORK/litellm/config.yaml"
explabs_write_portal_json   # litellm/explabs-models.json, as ./stack writes it for the portal
[ -s "$WORK/litellm/explabs-models.json" ] || stop "explabs_write_portal_json wrote nothing"
python3 -I -c 'import json, sys; m = {x["id"]: x for x in json.load(open(sys.argv[1]))["models"]}["xl/deepseek-v4.1-flash:free"]
assert m["free"] and m["paid"]["prompt"] == 3e-07, m' "$WORK/litellm/explabs-models.json" &&
  ok "the portal's model file prices the free tier's usage at deepseek-v4.1-flash's prices" || fail "the portal's model file: $(head -c 400 "$WORK/litellm/explabs-models.json")"
mkdir -p "$WORK/mock" && cp "$HERE/explabs-mock.py" "$WORK/mock/mock.py" && cp "$ROOT/tests/fixtures/explabs_v1_models.json" "$WORK/mock/v1.json" &&
  cp -R "$ROOT/tests/fixtures/explabs_catalog" "$WORK/mock/catalog" || exit 2
cp "$HERE/free-models-code.mjs" "$WORK/drive.mjs"
chmod -R a+rX "$WORK/litellm" "$WORK/mock" "$WORK/drive.mjs"

free_port() {
  local p="$1"
  while port_in_use "$p" || case "$AVOID_PORTS" in *" $p "*) true ;; *) false ;; esac; do p=$((p + 1)); done
  printf '%s\n' "$p"
}
MASTER="sk-e2e-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
PGPW="pg-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
OWPW="ow-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"

# --- the containers ---
docker network create --label "$LABEL" "$NET" >/dev/null || stop "could not make the network $NET"
docker volume create --label "$LABEL" "$VOL" >/dev/null || stop "could not make the volume $VOL"
say "Postgres ($PIMG)"
docker run -d --name "$PG" --label "$LABEL" --network "$NET" --network-alias postgres \
  -e POSTGRES_PASSWORD="$PGPW" -e POSTGRES_DB=litellm "$PIMG" >/dev/null || stop "could not start $PG"
for _ in $(seq 1 60); do docker exec "$PG" pg_isready -h 127.0.0.1 -U postgres -d litellm >/dev/null 2>&1 && break; sleep 1; done
LPORT="$(free_port 18560)"
say "LiteLLM ($LIMG) with the stand-in, on 127.0.0.1:$LPORT"
EXPLABS_API_KEY="$XLKEY" LITELLM_MASTER_KEY="$MASTER" docker run -d --name "$LL" --label "$LABEL" --network "$NET" --network-alias litellm \
  -p "127.0.0.1:$LPORT:4000" -v "$WORK/litellm:/app/config:ro" -v "$WORK/mock:/mock:ro" -v "$ROOT/portal/portal:/e2e/portal/portal:ro" \
  -e EXPLABS_API_KEY -e LITELLM_MASTER_KEY -e LITELLM_SALT_KEY="sk-salt-e2e" -e STORE_MODEL_IN_DB=False -e LITELLM_LOCAL_MODEL_COST_MAP=True \
  -e DATABASE_URL="postgresql://postgres:$PGPW@postgres:5432/litellm" --entrypoint sh "$LIMG" -c \
  "PY=\$(command -v python3 || command -v python); \$PY /mock/mock.py $MOCK_PORT /tmp/reqs.jsonl /mock/v1.json /mock/catalog & exec litellm --config /app/config/config.yaml --port 4000" \
  >/dev/null || stop "could not start $LL"
up=0
for _ in $(seq 1 120); do
  [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$LPORT/health/readiness" 2>/dev/null)" = 200 ] && { up=1; break; }
  docker container inspect -f '{{.State.Running}}' "$LL" 2>/dev/null | grep -q true || break
  sleep 2
done
[ "$up" = 1 ] || { docker logs --tail 30 "$LL" 2>&1 | sed "s/$MASTER/[master]/g" >&2; stop "LiteLLM did not come up"; }
ok "LiteLLM is up with this checkout's hook, the Experiential Labs config and its database"

# api METHOD PATH [BODY] -> the answer (the master key on curl's stdin)
api() { curl_auth "$MASTER" -sS -m 30 -X "$1" -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "http://127.0.0.1:$LPORT$2" 2>/dev/null; }
newkey() { api POST /key/generate "{\"key_alias\":\"$1\",\"max_budget\":1}" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["key"])'; }
KCODE="$(newkey e2e-code)" && KTERM="$(newkey e2e-terminal)" && KCHAT="$(newkey e2e-chat)" || stop "could not make the three keys"
[ -n "$KCODE" ] && [ -n "$KTERM" ] && [ -n "$KCHAT" ] || stop "a key came back empty"
ok "three keys: e2e-code (the Code page), e2e-terminal (devos-claude), e2e-chat (Open WebUI)"

say "the terminal ($TIMG): bn-coded with this checkout's bn-coded.mjs and devos-claude"
# (as compose.terminal.yaml sets it up; bn-terminal's first-run file, then bn-coded alone). As the image's own user: ./stack
# builds it with yours (TERMINAL_UID), and the new volume takes /run/bn-code's owner from the image when first mounted
docker run -d --name "$TC" --label "$LABEL" --network "$NET" -v "$VOL:/run/bn-code" \
  -v "$ROOT/terminal/bin/bn-coded.mjs:/usr/local/bin/bn-coded.mjs:ro" -v "$ROOT/terminal/bin/devos-claude:/usr/local/bin/devos-claude:ro" \
  -v "$ROOT/terminal/bin/claude-bedrock:/usr/local/bin/claude-bedrock:ro" \
  -e ANTHROPIC_BASE_URL=http://litellm:4000 -e ANTHROPIC_AUTH_TOKEN="$KCODE" -e ANTHROPIC_MODEL=claude-opus-5-5 \
  -e ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5 -e ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5-5 -e ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-5 \
  -e CLAUDE_BEDROCK_OPUS_MODEL=claude-opus-5-5 -e CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e DISABLE_AUTOUPDATER=1 -e TERMINAL_AUTO_MODE=false -e API_TIMEOUT_MS=60000 --entrypoint sh "$TIMG" -c \
  'printf "{\"hasCompletedOnboarding\":true,\"theme\":\"dark\"}\n" > "$HOME/.claude.json"; exec node /usr/local/bin/bn-coded.mjs' >/dev/null || stop "could not start $TC"
for _ in $(seq 1 30); do docker exec "$TC" test -S /run/bn-code/coded.sock 2>/dev/null && break; sleep 1; done
docker exec "$TC" test -S /run/bn-code/coded.sock 2>/dev/null || { docker logs --tail 20 "$TC" >&2; stop "bn-coded did not listen"; }
CLAUDE_V="$(docker exec "$TC" claude --version 2>/dev/null | head -n 1)"
TUSER="$(docker exec "$TC" sh -c 'echo "$(id -u):$(id -g)"' 2>/dev/null)"   # (the code container runs as the same user)
case "$TUSER" in [0-9]*:[0-9]*) ;; *) stop "could not read the terminal's user" ;; esac
ok "bn-coded listens in the terminal (Claude Code ${CLAUDE_V:-?})"

# --- 1. a Code page session on the free model ---
say "a Code page session on $MODEL ($CIMG, this checkout's code/server)"
code_out="$(docker run --rm --name "$CC" --label "$LABEL" --network none --user "$TUSER" -v "$VOL:/run/bn-code:ro" \
  -v "$ROOT/code/server:/opt/code/server:ro" -v "$WORK/drive.mjs:/opt/code/e2e-free-models.mjs:ro" -w /opt/code \
  --entrypoint node "$CIMG" /opt/code/e2e-free-models.mjs "$MODEL" 2> "$WORK/code.err")"
if printf '%s' "$code_out" | python3 -I -c 'import json, sys; d = json.loads(sys.stdin.read().strip().splitlines()[-1]); sys.exit(0 if d["ok"] and d["model"] == sys.argv[1] else 1)' "$MODEL"; then
  ok "the Code page session on $MODEL answered"
else
  fail "the Code page session: $(printf '%s' "$code_out" | tail -c 600) $(tail -c 400 "$WORK/code.err")"
fi

# --- 2. devos-claude in the terminal, with its own key ---
say "devos-claude --model $MODEL -p … in the terminal"
term_out="$(docker exec -e ANTHROPIC_AUTH_TOKEN="$KTERM" -w /workspace "$TC" timeout 180 devos-claude --model "$MODEL" -p 'Reply with exactly: DevOS ADE test OK' 2> "$WORK/term.err")"
case "$term_out" in
  *'DevOS ADE test OK'*) ok "devos-claude --model $MODEL answered ($(grep -m1 'experiential labs' "$WORK/term.err" | head -c 160))" ;;
  *) fail "devos-claude: $(printf '%s' "$term_out" | tail -c 300) $(tail -c 400 "$WORK/term.err")" ;;
esac

# --- 3. a Chat conversation, its title and tags: Open WebUI with no task model ---
OPORT="$(free_port 18580)"
say "Open WebUI ($OIMG) on 127.0.0.1:$OPORT"
docker run -d --name "$OW" --label "$LABEL" --network "$NET" -p "127.0.0.1:$OPORT:8080" \
  -e WEBUI_SECRET_KEY="e2e-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" -e WEBUI_ADMIN_EMAIL=admin@example.com \
  -e WEBUI_ADMIN_PASSWORD="$OWPW" -e WEBUI_ADMIN_NAME=Admin -e ENABLE_SIGNUP=false -e ENABLE_PERSISTENT_CONFIG=false \
  -e ENABLE_OLLAMA_API=false -e ENABLE_OPENAI_API=true -e OPENAI_API_BASE_URL=http://litellm:4000/v1 -e OPENAI_API_KEY="$KCHAT" \
  -e TASK_MODEL_EXTERNAL= -e ENABLE_TITLE_GENERATION=true -e ENABLE_TAGS_GENERATION=true -e ENABLE_FOLLOW_UP_GENERATION=true \
  -e RAG_EMBEDDING_ENGINE=openai -e RAG_OPENAI_API_BASE_URL=http://litellm:4000/v1 -e RAG_OPENAI_API_KEY="$KCHAT" \
  -e ENABLE_WEB_SEARCH=false -e OFFLINE_MODE=true -e ANONYMIZED_TELEMETRY=false -e DO_NOT_TRACK=true -e SCARF_NO_ANALYTICS=true \
  -e ENABLE_VERSION_UPDATE_CHECK=false "$OIMG" >/dev/null || stop "could not start $OW"
up=0
for _ in $(seq 1 120); do
  [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$OPORT/health" 2>/dev/null)" = 200 ] && { up=1; break; }
  docker container inspect -f '{{.State.Running}}' "$OW" 2>/dev/null | grep -q true || break
  sleep 2
done
if [ "$up" != 1 ]; then fail "Open WebUI did not come up: $(docker logs --tail 15 "$OW" 2>&1 | tail -c 600)"
else
  # (its admin from WEBUI_ADMIN_*; the token on curl's stdin from here on)
  tok="$(curl -sS -m 20 -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:$OPORT/api/v1/auths/signin" 2>/dev/null <<< "{\"email\":\"admin@example.com\",\"password\":\"$OWPW\"}" |
    python3 -I -c 'import json, sys; print(json.load(sys.stdin)["token"])' 2>/dev/null)"
  ow() { curl_auth "$tok" -sS -m 120 -H 'Content-Type: application/json' --data-binary "$2" -o "$WORK/$3.json" -w '%{http_code}' "http://127.0.0.1:$OPORT$1" 2>/dev/null; }
  msgs='[{"role":"user","content":"Reply with exactly: DevOS ADE test OK"}]'
  code="$(ow /api/chat/completions "{\"model\":\"$MODEL\",\"stream\":false,\"messages\":$msgs}" chat)"
  if [ "$code" = 200 ] && grep -q 'DevOS ADE test OK' "$WORK/chat.json"; then ok "a Chat conversation on $MODEL answered"
  else fail "the Chat conversation (HTTP $code): $(head -c 400 "$WORK/chat.json" 2>/dev/null)"; fi
  both="[{\"role\":\"user\",\"content\":\"Reply with exactly: DevOS ADE test OK\"},{\"role\":\"assistant\",\"content\":\"DevOS ADE test OK\"}]"
  for task in title tags; do
    code="$(ow "/api/v1/tasks/$task/completions" "{\"model\":\"$MODEL\",\"messages\":$both}" "$task")"
    [ "$code" = 200 ] && ok "Chat's $task task ran (HTTP 200)" || fail "Chat's $task task (HTTP $code): $(head -c 300 "$WORK/$task.json" 2>/dev/null)"
  done
fi

# --- what LiteLLM booked: every request on the free model at $0, each key's spend $0 ---
# (what the stand-in got: every call that reached a model, whichever key it came on)
docker exec "$LL" cat /tmp/reqs.jsonl > "$WORK/reqs.jsonl" 2>/dev/null || : > "$WORK/reqs.jsonl"
python3 -I -c 'import json, sys
ms = [json.loads(l)["body"].get("model") for l in open(sys.argv[1]) if l.strip()]
bad = sorted({m for m in ms if m != sys.argv[2]})
print(len(ms), ",".join(bad) or "-")' "$WORK/reqs.jsonl" "${MODEL#xl/}" > "$WORK/standin.txt"
read -r n bad < "$WORK/standin.txt"
[ "$n" -gt 0 ] && [ "$bad" = - ] && ok "the stand-in got $n request(s), all for ${MODEL#xl/}" || fail "the stand-in got $n request(s); other models: $bad"

say "waiting for LiteLLM's spend log (a row for each of the $n calls)"
today="$(date -u +%Y-%m-%d)"
logs() { api GET "/spend/logs/v2?start_date=$today%2000:00:00&end_date=$today%2023:59:59&page_size=200" > "$WORK/logs.json"; }
for _ in $(seq 1 45); do
  logs
  python3 -I -c 'import json, sys; sys.exit(0 if len(json.load(open(sys.argv[1]))["data"]) >= int(sys.argv[2]) else 1)' "$WORK/logs.json" "$n" 2>/dev/null && break
  sleep 2
done
# Each row, by the key it was booked to: LiteLLM keeps a key's sha256 (api_key) and its alias (metadata). The rows go to
# the results without either key: the hash cut to 12 characters, a key's own alias beside it.
KC="$KCODE" KT="$KTERM" KH="$KCHAT" python3 -I - "$WORK/logs.json" "$MODEL" "$OUT/free-models-spend.json" > "$WORK/booked.txt" <<'PY'
import hashlib, json, os, sys
rows, model, dump = json.load(open(sys.argv[1]))["data"], sys.argv[2], sys.argv[3]
keys = {hashlib.sha256(os.environ[v].encode()).hexdigest(): a for v, a in (("KC", "e2e-code"), ("KT", "e2e-terminal"), ("KH", "e2e-chat"))}
out, by = [], {}
for r in rows:
    md = r.get("metadata") if isinstance(r.get("metadata"), dict) else {}
    key = keys.get(r.get("api_key"), "another key" if r.get("api_key") else "no key")
    row = {"key": key, "api_key": str(r.get("api_key") or "")[:12], "alias": md.get("user_api_key_alias"),
           "model_group": r.get("model_group"), "call_type": r.get("call_type"), "status": r.get("status") or md.get("status"),
           "spend": r.get("spend"), "end_user": r.get("end_user"), "request_tags": r.get("request_tags"),
           "session_id": r.get("session_id"), "user_agent": md.get("user_agent"), "startTime": r.get("startTime")}
    out.append(row); by.setdefault(key, []).append(row)
json.dump(out, open(dump, "w"), indent=1)
for key in ("e2e-code", "e2e-terminal", "e2e-chat", "another key", "no key"):
    got = by.get(key, [])
    others = sorted({str(x["model_group"]) for x in got if x["model_group"] != model})
    aliases = sorted({str(x["alias"]) for x in got if x["alias"] != key})
    print(key, len(got), sum(float(x["spend"] or 0) for x in got), ",".join(others) or "-", ",".join(aliases) or "-",
          sum(1 for x in got if x["status"] not in (None, "success")), sep="\t")
PY
# every call booked to the key it came on, under that key's alias: Chat's three — the answer, its title, its tags — on
# Open WebUI's (its budget, Home's Chat row); none to another key or to none
while IFS=$'\t' read -r key rows spend others aliases failed; do
  case "$key" in
    'another key' | 'no key') [ "$rows" = 0 ] && ok "no row booked to $key" || fail "$rows row(s) booked to $key ($OUT/free-models-spend.json)" ;;
    *) want=1; [ "$key" != e2e-chat ] || want=3
       if [ "$rows" -ge "$want" ] && { [ "$key" != e2e-chat ] || [ "$rows" = 3 ]; } && [ "$others" = - ] && [ "$aliases" = - ] && [ "$failed" = 0 ] &&
          python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) == 0 else 1)' "$spend"; then
         ok "$key: $rows request(s) booked to its key and alias, every one on $MODEL at \$0"
       else
         fail "$key: $rows row(s) (want $([ "$key" = e2e-chat ] && echo 3 || echo 'at least 1')), \$$spend, other models: $others, other aliases: $aliases, failed: $failed ($OUT/free-models-spend.json)"
       fi ;;
  esac
done < "$WORK/booked.txt"
for k in "e2e-code:$KCODE" "e2e-terminal:$KTERM" "e2e-chat:$KCHAT"; do
  s="$(curl_auth "${k#*:}" -sS -m 10 "http://127.0.0.1:$LPORT/key/info" 2>/dev/null | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["info"]["spend"])' 2>/dev/null)"
  [ "$s" = 0.0 ] || [ "$s" = 0 ] && ok "${k%%:*}: the key's spend (Actual) is \$0" || fail "${k%%:*}: the key's spend is ${s:-unknown}"
done
# (the stand-in's record beside it, for a row that went astray: each call's path and model, and whether it said who)
python3 -I -c 'import json, sys
out = []
for l in open(sys.argv[1]):
    if l.strip():
        d = json.loads(l); b = d.get("body") or {}
        out.append({"path": d.get("path"), "model": b.get("model"), "stream": b.get("stream"), "user": "user" in b, "metadata": "metadata" in b,
                    "first_message": str(((b.get("messages") or [{}])[0] or {}).get("content", ""))[:80]})
json.dump(out, open(sys.argv[2], "w"), indent=1)' "$WORK/reqs.jsonl" "$OUT/free-models-standin.json" 2>/dev/null || true

# --- Home's Equivalent view against this LiteLLM: the same usage priced, Actual $0 ---
say "Home's Equivalent view (portal/portal/usage.py) against this LiteLLM"
for _ in $(seq 1 30); do
  api GET "/user/daily/activity/aggregated?start_date=$today&end_date=$today" > "$WORK/act.json"
  grep -q "\"$MODEL\"" "$WORK/act.json" && break; sleep 2
done
eq="$(docker exec -e PYTHONPATH=/e2e/portal -e M="$MASTER" -e KC="$KCODE" -e KT="$KTERM" -e KH="$KCHAT" "$LL" sh -c 'PY=$(command -v python3 || command -v python); $PY -c "
import asyncio, json, os, types
from pathlib import Path
import httpx
from portal import usage
keys = ((\"e2e-code\", \"Code\", os.environ[\"KC\"]), (\"e2e-terminal\", \"Terminal\", os.environ[\"KT\"]), (\"e2e-chat\", \"Chat\", os.environ[\"KH\"]))
s = types.SimpleNamespace(openrouter_api_key=\"\", litellm_dir=Path(\"/app/config\"), keys=keys, litellm_url=\"http://127.0.0.1:4000\", litellm_master_key=os.environ[\"M\"])
sp = {\"keys\": [{\"alias\": a, \"spend\": 0.0, \"period_start\": None} for a, _, _ in keys], \"total_30d\": 0.0}
async def go():
    async with httpx.AsyncClient() as c:
        return await usage.build(c, s, sp)
e, u = asyncio.run(go())
print(json.dumps({\"equivalent\": e, \"openrouter_usage\": u}))
"' 2> "$WORK/eq.err")"
if printf '%s' "$eq" | python3 -I -c 'import json, sys
d = json.loads(sys.stdin.read()); e = d["equivalent"]
assert d["openrouter_usage"] is None and e["error"] is None, d
assert e["extra_30d"] > 0 and e["total_30d"] == e["extra_30d"] and e["free_requests_30d"] >= 5, e
assert e["byok_requests_30d"] == 0 and e["no_paid_variant"] == [], e
assert all(k["extra"] > 0 for k in e["keys"].values()), e["keys"]
print("%d free requests, ≈ $%.6f at deepseek-v4.1-flash prices" % (e["free_requests_30d"], e["extra_30d"]))' > "$WORK/eq.txt" 2>&1; then
  ok "Equivalent: $(cat "$WORK/eq.txt"); Actual \$0 (OpenRouter off: its usage block stays off)"
else
  fail "Equivalent: $(cat "$WORK/eq.txt" | tail -c 500) $(tail -c 300 "$WORK/eq.err")"
fi

# --- nothing of the keys in the results ---
_result 1; RESULT_DONE=1
for k in "$MASTER" "$KCODE" "$KTERM" "$KCHAT" "$XLKEY"; do
  for f in "$RESULT" "$OUT/free-models-spend.json" "$OUT/free-models-standin.json"; do
    if grep -qF -- "$k" "$f" 2>/dev/null; then RESULT_DONE=0; fail "a key was in $(basename "$f") (removed)"; rm -f "$f"; fi
  done
done
say "results: $RESULT"
if [ "$FAILS" -gt 0 ]; then printf '\n%d check(s) failed\n' "$FAILS"; exit 1; fi
printf '\nall checks passed\n'
