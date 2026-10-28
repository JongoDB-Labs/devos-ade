#!/usr/bin/env bash
# Opt-in end-to-end check of model servers (JON-816; run by hand, not part of tests/run.sh, CI or tests/e2e/run.sh): any
# OpenAI-compatible server added by IP. A fake one (tests/e2e/fake-openai.py, in a throwaway container named
# bne2e-msrv-fake on Docker's default network, wanting an API key) is added with ./stack's own lib/local_models.sh by the
# container's IP, all its models are enabled, one throwaway LiteLLM container (bne2e-msrv-litellm) serves the rendered
# config, and: 1 the probe lists the model with its context; 2 a probe without the key says 401; 3 a chat completion goes
# through LiteLLM to the server by IP; 4 it is booked at $0; 5 the Code page's rows list it as Local and free;
# 6 a server that is stopped is said to be "connection refused"; 7 removing the server unregisters its models and its key.
# Needs: Docker on LINUX (the host reaches the container's IP directly; on Docker Desktop for Mac a container's IP is not
# reachable from the host, so use the localhost mapping check in tests/test_local_models.sh instead). The Linux host also
# needs outbound access to pull the LiteLLM image if it is not there. --out DIR (default tests/e2e/out).
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; OUT="$ROOT/tests/e2e/out"
[ "${1:-}" != --out ] || OUT="${2:?--out DIR}"
FK=bne2e-msrv-fake; LL=bne2e-msrv-litellm; LABEL=io.bedrock-now.e2e=model-servers
WORK="$ROOT/tests/e2e/work/bne2e-msrv"; FAILS=0
ok() { printf 'ok    %s\n' "$*" >&2; }
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
command -v docker >/dev/null 2>&1 || { echo "needs docker" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "run this on a Linux Docker host (see the header)" >&2; exit 2; }
cleanup() { docker rm -f "$FK" "$LL" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
for c in "$FK" "$LL"; do
  if docker container inspect "$c" >/dev/null 2>&1 && [ "$(docker container inspect -f '{{index .Config.Labels "io.bedrock-now.e2e"}}' "$c")" != model-servers ]; then echo "$c exists and is not this check's" >&2; exit 2; fi
done
trap cleanup EXIT; cleanup; mkdir -p "$WORK/litellm" "$WORK/state" "$OUT"; chmod 755 "$WORK" "$WORK/litellm"
LIMG="$(sed -n 's/^    image: \(ghcr.io\/berriai\/litellm:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
KEYV="e2e-key-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --name "$FK" --label "$LABEL" -e FAKE_KEY="$KEYV" -v "$HERE/fake-openai.py:/fake.py:ro" --entrypoint python3 "$LIMG" /fake.py >/dev/null || { fail "the fake server did not start"; exit 1; }
# (the address on its network: Docker 29 dropped the old top-level .NetworkSettings.IPAddress)
IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$FK" | awk '{ print $1 }')"
[ -n "$IP" ] || { fail "the fake server has no address on Docker's network"; exit 1; }
STACK_DIR="$ROOT"; ENV_FILE="$WORK/.env"; STATE_DIR="$WORK/state"; : > "$ENV_FILE"; export STACK_DIR ENV_FILE STATE_DIR
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
config_apply() { _cfg_write; CFG_ORDER=''; }   # (.env saved; a real stack then reloads LiteLLM live, tests/test_litellm_live.sh: here one container is started on the rendered config)
get_env() { K="$1" awk 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2) } END { printf "%s", v }' "$ENV_FILE"; }
cfg_put() { grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.n"; printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE.n"; mv "$ENV_FILE.n" "$ENV_FILE"; }
for _ in $(seq 1 30); do curl -s -m 2 -o /dev/null "http://$IP:8000/v1/models" && break; sleep 1; done
msrv_add fake "http://$IP:8000" >/dev/null 2>&1
st="$(msrv_probe fake)"; case "$st" in down*401*) ok "2 without the key the probe says: ${st#*$'\t'}" ;; *) fail "2 probe without key: $st" ;; esac
printf '%s\n' "$KEYV" | msrv_set_key fake >/dev/null 2>&1
st="$(msrv_status_of fake)"; case "$st" in ok*fake/tiny-chat\|8192*) ok "1 the probe lists fake/tiny-chat with its context" ;; *) fail "1 the probe: $st" ;; esac
msrv_enable fake '*' on >/dev/null 2>&1
{ printf 'model_list:\n'; local_models_yaml; } > "$WORK/litellm/config.yaml"; chmod 644 "$WORK/litellm/config.yaml"
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
MK="sk-e2e-$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')"   # (LiteLLM 1.106 does not start without a strong master key)
LITELLM_MASTER_KEY="$MK" docker run -d --name "$LL" -e LITELLM_MASTER_KEY --label "$LABEL" -p "127.0.0.1:$PORT:4000" -v "$WORK/litellm/config.yaml:/app/config.yaml:ro" "$LIMG" --config /app/config.yaml --port 4000 >/dev/null
for _ in $(seq 1 90); do curl -fsS -m 3 "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break; sleep 2; done
curl -sS -m 60 -D "$WORK/hdr" -o "$WORK/body" -H 'Content-Type: application/json' -H "Authorization: Bearer $MK" -d '{"model":"ms/fake/fake/tiny-chat","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}' "http://127.0.0.1:$PORT/v1/chat/completions"
if grep -q "Hello from the fake server" "$WORK/body"; then ok "3 a chat completion went through LiteLLM to the server by IP"; ANSWERED=1
else fail "3 no answer: $(head -c 300 "$WORK/body") $(docker logs --tail 5 "$LL" 2>&1 | tr '\n' ' ')"; fi
# (LiteLLM 1.106 leaves x-litellm-response-cost out when it is 0; -original is there whenever a cost was worked out)
COST="$(tr -d '\r' < "$WORK/hdr" | sed -n 's/^[Xx]-[Ll]itellm-[Rr]esponse-[Cc]ost: *//p' | head -n 1)"
ORIG="$(tr -d '\r' < "$WORK/hdr" | sed -n 's/^[Xx]-[Ll]itellm-[Rr]esponse-[Cc]ost-[Oo]riginal: *//p' | head -n 1)"
if [ -z "${ANSWERED:-}" ]; then fail "4 nothing answered, so nothing was booked"
elif [ -n "$ORIG" ] && awk -v c="$ORIG" -v d="${COST:-0}" 'BEGIN { exit !(c + 0 == 0 && d + 0 == 0) }'; then ok "4 booked at \$0 (cost ${COST:-0}, worked out as $ORIG)"
else fail "4 the answer was booked at '${COST:-none}' (worked out as '${ORIG:-nothing}'), not \$0"; fi
R="$(code_models_rows "" 2>/dev/null | awk -F'\t' '$1 == "ms/fake/fake/tiny-chat"')"
{ [ "$(printf '%s' "$R" | cut -f3)" = Local ] && [ "$(printf '%s' "$R" | cut -f9)" = 1 ]; } && ok "5 the Code page lists it as Local and free" || fail "5 rows: '$R'"
docker stop "$FK" >/dev/null; st="$(msrv_probe fake)"
case "$st" in down*refused* | down*"no answer"*) ok "6 a stopped server is said so: ${st#*$'\t'}" ;; *) fail "6 stopped server: $st" ;; esac
msrv_rm fake >/dev/null 2>&1
{ [ -z "$(get_env MODEL_SERVERS)" ] && [ -z "$(get_env MODEL_SERVER_KEYS)" ] && [ -z "$(local_models_yaml)" ]; } && ok "7 removed: the server, its key and its models are gone" || fail "7 something is left"
[ "$FAILS" -eq 0 ] && { echo "model servers: all checks passed" >&2; exit 0; } || exit 1
