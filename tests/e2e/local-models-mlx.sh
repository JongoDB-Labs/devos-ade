#!/usr/bin/env bash
# Opt-in end-to-end check of local models on Apple silicon (JON-816, the MLX path; run by hand on a Mac, not part of
# tests/run.sh, CI or tests/e2e/run.sh). In a scratch state dir: uv installs the hash-locked mlx-lm
# (catalog/mlx-requirements.lock) into its own venv, one small mlx-community model (Qwen2.5-0.5B-Instruct-4bit, about
# 280 MB) is vetted (no custom code) and downloaded into the scratch HF_HOME, mlx_lm.server runs as a launchd user agent on
# 127.0.0.1 (a random port), and one throwaway LiteLLM container (compose.yaml's image, named bne2e-mlx-litellm, removed
# afterwards) serves the rendered config. Checks: 1 runtime is mlx; 2 downloaded, registered; 3 LiteLLM entry is $0, no
# key; 4 a chat completion goes container -> host.docker.internal -> the server; 5 a tool call comes back as tool_calls;
# 6 booked at $0; 7 the Code page rows say Local, free; 8 removal deletes the files and unregisters; 9 uninstall removes
# the agent, the venv and the models. Needs: Apple silicon, uv, Docker, outbound access to huggingface.co and PyPI,
# about 1.5 GB of disk. Nothing outside the scratch dir stays (the agent is removed by the trap).
#   --repo ORG/NAME   another MLX model (default mlx-community/Qwen2.5-0.5B-Instruct-4bit)   --out DIR
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
REPO=mlx-community/Qwen2.5-0.5B-Instruct-4bit; QUANT=mlx; OUT="$ROOT/tests/e2e/out"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo ORG/NAME}"; shift 2 ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/local-models.sh --help)" >&2; exit 2 ;;
  esac
done
say() { printf '==> %s\n' "$*" >&2; }
FAILS=0; CHECKS=()
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$*"); }
ok() { printf 'ok    %s\n' "$*" >&2; CHECKS+=("ok	$*"); }
command -v docker >/dev/null 2>&1 || { echo "needs docker" >&2; exit 2; }
[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || { echo "this check is for Apple silicon (the GGUF path: tests/e2e/local-models.sh)" >&2; exit 2; }
command -v uv >/dev/null 2>&1 || { echo "needs uv (brew install uv)" >&2; exit 2; }
LL=bne2e-mlx-litellm; LABEL=io.bedrock-now.e2e=local-models
WORK="$ROOT/tests/e2e/work/bne2e-mlx"; PORT=""
cleanup() {
  [ -z "${STATE_DIR:-}" ] || ! declare -F local_mlx_uninstall >/dev/null || local_mlx_uninstall --models >/dev/null 2>&1
  [ "$(docker container inspect -f '{{index .Config.Labels "io.bedrock-now.e2e"}}' "$LL" 2>/dev/null)" != local-models ] || docker rm -f "$LL" >/dev/null 2>&1
  rm -rf "$WORK"
  mkdir -p "$OUT" 2>/dev/null && printf '%s\n' ${CHECKS[@]+"${CHECKS[@]}"} | python3 -I -c 'import json, sys
print(json.dumps({"failures": int(sys.argv[1]), "checks": [dict(zip(("status", "check"), l.rstrip("\n").split("\t", 1))) for l in sys.stdin if "\t" in l]}, indent=1))' "$FAILS" > "$OUT/local-models-mlx.json" 2>/dev/null
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
# a real config apply saves .env, then reloads LiteLLM live (its own test: tests/test_litellm_live.sh); here it saves
# .env only, and the one container is started on the rendered config instead
config_apply() { _cfg_write; CFG_ORDER=''; }
get_env() { K="$1" awk 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2) } END { printf "%s", v }' "$ENV_FILE"; }

LOCAL_MLX_PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"; export LOCAL_MLX_PORT
RT="$(local_runtime)"
if [ "$RT" = none ]; then
  echo "no model runner is running. $(local_how_text)" >&2
  FAILS=1; CHECKS+=("FAIL	no model runner is running"); exit 2
fi
[ "$RT" = mlx ] && ok "1 the runtime is MLX" || { fail "1 the runtime is $RT, not mlx"; exit 1; }

say "pulling hf.co/$REPO:$QUANT with $RT"
LOCAL_POLL_S=2 local_pull "$REPO" "$QUANT" --tools yes --params-m 494 --context 32768 --license apache-2.0 >"$WORK/pull.log" 2>&1 || { fail "2 the download failed: $(tail -n 3 "$WORK/pull.log" | tr '\n' ' ')"; exit 1; }
ENTRY="$(get_env LOCAL_MODELS)"; NAME="$(local_model_name "${ENTRY%%,*}")"
case "$ENTRY" in mlx:*) ok "2 downloaded and registered: LOCAL_MODELS=$ENTRY" ;; *) fail "2 LOCAL_MODELS is '$ENTRY'" ;; esac

# --- LiteLLM on this checkout's rendered config ---
{ printf 'model_list:\n'; local_models_yaml; printf 'litellm_settings:\n  drop_params: true\n'; } > "$WORK/litellm/config.yaml"
if grep -q 'input_cost_per_token: 0$' "$WORK/litellm/config.yaml" && grep -q 'output_cost_per_token: 0$' "$WORK/litellm/config.yaml" && [ "$(grep 'api_key' "$WORK/litellm/config.yaml" | tr -d ' ')" = 'api_key:"none"' ]; then ok "3 LiteLLM's entry for $NAME is \$0 and needs no key (the placeholder \"none\")"; else fail "3 the rendered entry is wrong: $(cat "$WORK/litellm/config.yaml")"; fi
chmod 755 "$WORK" "$WORK/litellm"; chmod 644 "$WORK/litellm/config.yaml"
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
MK="sk-e2e-$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')"   # (LiteLLM 1.106 does not start without a strong master key)
LITELLM_MASTER_KEY="$MK" docker run -d --name "$LL" -e LITELLM_MASTER_KEY --label "$LABEL" --add-host host.docker.internal:host-gateway -p "127.0.0.1:$PORT:4000" \
  -v "$WORK/litellm/config.yaml:/app/config.yaml:ro" "$LIMG" --config /app/config.yaml --port 4000 >/dev/null || { fail "4 LiteLLM did not start"; exit 1; }
for _ in $(seq 1 90); do curl -fsS -m 3 "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break; sleep 2; done
HDR="$WORK/hdr"; BODY="$WORK/body"
BODYJ="$(python3 -I -c 'import json, sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 24, "messages": [{"role": "user", "content": "Say hello in three words."}]}))' "$NAME")"
if curl -sS -m 300 -D "$HDR" -o "$BODY" -H 'Content-Type: application/json' -H "Authorization: Bearer $MK" -d "$BODYJ" "http://127.0.0.1:$PORT/v1/chat/completions" \
  && python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["choices"][0]["message"]["content"].strip()' "$BODY" 2>/dev/null; then
  ok "4 a chat completion went through LiteLLM on $NAME"; ANSWERED=1
else fail "4 no answer through LiteLLM: $(head -c 300 "$BODY" 2>/dev/null) $(docker logs --tail 5 "$LL" 2>&1 | tr '\n' ' ')"; fi
TOOLJ="$(python3 -I -c 'import json, sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 80, "messages": [{"role": "user", "content": "What is the weather in Paris? Use the tool."}], "tools": [{"type": "function", "function": {"name": "get_weather", "description": "weather", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]}))' "$NAME")"
if curl -sS -m 300 -H 'Content-Type: application/json' -H "Authorization: Bearer $MK" -d "$TOOLJ" "http://127.0.0.1:$PORT/v1/chat/completions" | python3 -I -c 'import json, sys; d = json.load(sys.stdin)["choices"][0]; assert d["finish_reason"] == "tool_calls" or d["message"].get("tool_calls")' 2>/dev/null; then ok "5 a tool call came back as tool_calls"; else fail "5 no tool call through LiteLLM"; fi
# (LiteLLM 1.106 leaves x-litellm-response-cost out when it is 0; -original is there whenever a cost was worked out)
COST="$(tr -d '\r' < "$HDR" | sed -n 's/^[Xx]-[Ll]itellm-[Rr]esponse-[Cc]ost: *//p' | head -n 1)"
ORIG="$(tr -d '\r' < "$HDR" | sed -n 's/^[Xx]-[Ll]itellm-[Rr]esponse-[Cc]ost-[Oo]riginal: *//p' | head -n 1)"
if [ -z "${ANSWERED:-}" ]; then fail "6 nothing answered, so nothing was booked"
elif [ -n "$ORIG" ] && awk -v c="$ORIG" -v d="${COST:-0}" 'BEGIN { exit !(c + 0 == 0 && d + 0 == 0) }'; then ok "6 the answer is booked at \$0 (cost ${COST:-0}, worked out as $ORIG)"
else fail "6 the answer was booked at '${COST:-none}' (worked out as '${ORIG:-nothing}'), not \$0"; fi

# --- the Code page's rows (what /.bn/models serves) ---
ROWS="$(code_models_rows "" 2>/dev/null | awk -F'\t' -v n="$NAME" '$1 == n')"
if [ -n "$ROWS" ] && [ "$(printf '%s' "$ROWS" | cut -f3)" = Local ] && printf '%s' "$ROWS" | awk -F'\t' '{ exit !($9 == 1) }'; then ok "7 the Code page lists $NAME as Local and free"; else fail "7 the Code page rows: '$ROWS'"; fi

say "removing it"
local_rm "$REPO" "$QUANT" >"$WORK/rm.log" 2>&1 && [ -z "$(get_env LOCAL_MODELS)" ] && [ -z "$(local_registry_rows)" ] || fail "8 removal: $(tail -n 3 "$WORK/rm.log" | tr '\n' ' ')"
[ ! -d "$(local_mlx_repo_dir "$REPO")" ] && ok "8 removed: unregistered and the files are gone" || fail "8 the files are still there"
local_mlx_uninstall --models
[ ! -e "$(local_mlx_dir)" ] && ! launchctl print "gui/$(id -u)/$(local_mlx_label)" >/dev/null 2>&1 && ok "9 uninstall removed the agent, the venv and the models" || fail "9 uninstall left something"
[ "$FAILS" -eq 0 ] && { echo "mlx: all checks passed" >&2; exit 0; } || exit 1
