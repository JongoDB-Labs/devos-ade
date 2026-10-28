#!/usr/bin/env bash
# Opt-in end-to-end check of local models (JON-816; run by hand, not part of tests/run.sh, CI or tests/e2e/run.sh).
# A REAL runtime on this machine (Docker Model Runner first, Ollama second) pulls a tiny GGUF from Hugging Face
# (SmolLM2-135M-Instruct, Q4_K_M, about 105 MB), and this checkout's own lib/local_models.sh registers it. One throwaway
# LiteLLM container (compose.yaml's image, no database, nothing else; named bne2e-local-litellm, labelled
# io.bedrock-now.e2e=local-models, removed afterwards by that name) serves this checkout's rendered config. Checks:
#   1  a runtime answers (else: says how to enable it, and exits 2)       2  the download registers LOCAL_MODELS
#   3  LiteLLM's config has the model at $0 (input and output cost 0)       4  a chat completion goes through LiteLLM
#   5  the Code page's rows (lib/code_models.sh) list it as provider Local, free, never priced
#   6  the answer is booked at $0 (x-litellm-response-cost)                 7  removal unregisters it and deletes the files
# What the host needs: Docker; Docker Model Runner (Docker Desktop: `docker desktop enable model-runner --tcp 12434`;
# Linux Docker Engine: `apt-get install docker-model-plugin` or `dnf install docker-model-plugin`, then `docker model
# install-runner`, TCP 12434) OR Ollama (reachable from containers as host.docker.internal:11434, so it must listen on
# 0.0.0.0, or set LOCAL_OLLAMA_URL for the host side and LOCAL_OLLAMA_BASE for LiteLLM's); outbound access to
# huggingface.co; about 150 MB of disk; no GPU needed (CPU is fine). No AWS, no Claude model, nothing on Opus.
#   --repo ORG/NAME --quant Q   another tiny GGUF (default bartowski/SmolLM2-135M-Instruct-GGUF Q4_K_M)
#   --out DIR                   results (default tests/e2e/out, gitignored): local-models.json
# Docker runs it: on a machine that shares a heavy-job lock, run the whole script inside that lock.
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
REPO=bartowski/SmolLM2-135M-Instruct-GGUF; QUANT=Q4_K_M; OUT="$ROOT/tests/e2e/out"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo ORG/NAME}"; shift 2 ;;
    --quant) QUANT="${2:?--quant Q}"; shift 2 ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/local-models.sh --help)" >&2; exit 2 ;;
  esac
done
say() { printf '==> %s\n' "$*" >&2; }
FAILS=0; CHECKS=()
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$*"); }
ok() { printf 'ok    %s\n' "$*" >&2; CHECKS+=("ok	$*"); }
command -v docker >/dev/null 2>&1 || { echo "needs docker" >&2; exit 2; }
LL=bne2e-local-litellm; LABEL=io.bedrock-now.e2e=local-models
WORK="$ROOT/tests/e2e/work/bne2e-local"; PORT=""
cleanup() {
  [ "$(docker container inspect -f '{{index .Config.Labels "io.bedrock-now.e2e"}}' "$LL" 2>/dev/null)" != local-models ] || docker rm -f "$LL" >/dev/null 2>&1
  rm -rf "$WORK"
  mkdir -p "$OUT" 2>/dev/null && printf '%s\n' ${CHECKS[@]+"${CHECKS[@]}"} | python3 -I -c 'import json, sys
print(json.dumps({"failures": int(sys.argv[1]), "checks": [dict(zip(("status", "check"), l.rstrip("\n").split("\t", 1))) for l in sys.stdin if "\t" in l]}, indent=1))' "$FAILS" > "$OUT/local-models.json" 2>/dev/null
}
if docker container inspect "$LL" >/dev/null 2>&1 && [ "$(docker container inspect -f '{{index .Config.Labels "io.bedrock-now.e2e"}}' "$LL")" != local-models ]; then echo "a container named $LL exists and is not this check's: not touching it" >&2; exit 2; fi
trap cleanup EXIT; trap 'exit 130' INT TERM
docker rm -f "$LL" >/dev/null 2>&1 || true
mkdir -p "$WORK/state" "$WORK/litellm" "$OUT"
LIMG="$(sed -n 's/^    image: \(ghcr.io\/berriai\/litellm:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
[ -n "$LIMG" ] || { echo "no LiteLLM image in compose.yaml" >&2; exit 2; }

# --- this checkout's code, on a scratch .env and state dir (never an installed stack) ---
STACK_DIR="$ROOT"; ENV_FILE="$WORK/.env"; STATE_DIR="$WORK/state"; : > "$ENV_FILE"
export STACK_DIR ENV_FILE STATE_DIR
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
# the config apply of a real stack is LiteLLM's live reload (its own test: tests/test_litellm_live.sh); here the one
# container is started on the rendered config instead
config_apply() { :; }
get_env() { K="$1" awk 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2) } END { printf "%s", v }' "$ENV_FILE"; }

RT="$(local_runtime)"
if [ "$RT" = none ]; then
  echo "no model runner is running. $(local_how_text)" >&2
  FAILS=1; CHECKS+=("FAIL	no model runner is running"); exit 2
fi
ok "1 a runtime answers: $RT"

say "pulling hf.co/$REPO:$QUANT with $RT"
LOCAL_POLL_S=2 local_pull "$REPO" "$QUANT" --tools no --params-m 135 --context 8192 --license apache-2.0 >"$WORK/pull.log" 2>&1 || { fail "2 the download failed: $(tail -n 3 "$WORK/pull.log" | tr '\n' ' ')"; exit 1; }
ENTRY="$(get_env LOCAL_MODELS)"; NAME="$(local_model_name "${ENTRY%%,*}")"
case "$ENTRY" in dmr:* | ollama:*) ok "2 downloaded and registered: LOCAL_MODELS=$ENTRY" ;; *) fail "2 LOCAL_MODELS is '$ENTRY'" ;; esac

# --- LiteLLM on this checkout's rendered config ---
{ printf 'model_list:\n'; local_models_yaml; printf 'litellm_settings:\n  drop_params: true\n'; } > "$WORK/litellm/config.yaml"
if grep -q 'input_cost_per_token: 0$' "$WORK/litellm/config.yaml" && grep -q 'output_cost_per_token: 0$' "$WORK/litellm/config.yaml" && ! grep -q 'api_key' "$WORK/litellm/config.yaml"; then ok "3 LiteLLM's entry for $NAME is $0 and needs no key"; else fail "3 the rendered entry is wrong: $(cat "$WORK/litellm/config.yaml")"; fi
chmod 755 "$WORK" "$WORK/litellm"; chmod 644 "$WORK/litellm/config.yaml"
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
docker run -d --name "$LL" --label "$LABEL" --add-host host.docker.internal:host-gateway -p "127.0.0.1:$PORT:4000" \
  -v "$WORK/litellm/config.yaml:/app/config.yaml:ro" "$LIMG" --config /app/config.yaml --port 4000 >/dev/null || { fail "4 LiteLLM did not start"; exit 1; }
for _ in $(seq 1 90); do curl -fsS -m 3 "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break; sleep 2; done
HDR="$WORK/hdr"; BODY="$WORK/body"
BODYJ="$(python3 -I -c 'import json, sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 24, "messages": [{"role": "user", "content": "Say hello in three words."}]}))' "$NAME")"
if curl -sS -m 300 -D "$HDR" -o "$BODY" -H 'Content-Type: application/json' -d "$BODYJ" "http://127.0.0.1:$PORT/v1/chat/completions" \
  && python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["choices"][0]["message"]["content"].strip()' "$BODY" 2>/dev/null; then
  ok "4 a chat completion went through LiteLLM on $NAME"
else fail "4 no answer through LiteLLM: $(head -c 300 "$BODY" 2>/dev/null) $(docker logs --tail 5 "$LL" 2>&1 | tr '\n' ' ')"; fi
COST="$(tr -d '\r' < "$HDR" | sed -n 's/^[Xx]-[Ll]itellm-[Rr]esponse-[Cc]ost: *//p' | head -n 1)"
if [ -z "$COST" ] || awk -v c="$COST" 'BEGIN { exit !(c + 0 == 0) }'; then ok "6 the answer is booked at \$0 (cost header '${COST:-none}')"; else fail "6 the answer cost $COST"; fi

# --- the Code page's rows (what /.bn/models serves) ---
ROWS="$(code_models_rows "" 2>/dev/null | awk -F'\t' -v n="$NAME" '$1 == n')"
if [ -n "$ROWS" ] && [ "$(printf '%s' "$ROWS" | cut -f3)" = Local ] && printf '%s' "$ROWS" | awk -F'\t' '{ exit !($9 == 1) }'; then ok "5 the Code page lists $NAME as Local and free"; else fail "5 the Code page rows: '$ROWS'"; fi

say "removing it"
local_rm "$REPO" "$QUANT" >"$WORK/rm.log" 2>&1 && [ -z "$(get_env LOCAL_MODELS)" ] && [ -z "$(local_registry_rows)" ] || fail "7 removal: $(tail -n 3 "$WORK/rm.log" | tr '\n' ' ')"
if [ "$RT" = dmr ]; then GONE=1; docker model list --openai 2>/dev/null | grep -qi "$(printf '%s' "$QUANT")" && grep -qi "$REPO" <(docker model list --openai 2>/dev/null) && GONE=0
else GONE=1; curl -fsS -m 10 "$(_local_ollama_url)/api/tags" 2>/dev/null | grep -qi "$REPO" && GONE=0; fi
[ "${GONE:-0}" = 1 ] && ok "7 removed: unregistered and the runtime no longer has it" || fail "7 the runtime still lists $REPO"
[ "$FAILS" -eq 0 ] && { echo "local models: all checks passed" >&2; exit 0; } || exit 1
