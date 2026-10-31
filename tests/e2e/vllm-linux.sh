#!/usr/bin/env bash
# Opt-in end-to-end check of vLLM as a runtime DevOS ADE installs (JON-829; run by hand on a Linux host, not part of
# tests/run.sh, CI or tests/e2e/run.sh). This checkout's own lib/runtimes.sh and lib/local_models.sh, on a scratch .env and
# state dir as Compose project bne2e-vllm (never an installed stack), install vLLM's REAL image (the CPU build on x86-64
# with AVX2, or the CUDA one when Docker has the NVIDIA runtime) and serve a REAL safetensors model from Hugging Face
# (SmolLM2-135M-Instruct, about 270 MB). One throwaway LiteLLM container (compose.yaml's image, no database; named
# bne2e-vllm-litellm, labelled io.devos-ade.e2e=vllm) joins vLLM's internal network and serves this checkout's rendered
# config. Checks:
#   1  install pulls the image and waits for a model, with no container
#   2  the download is served: vLLM loads it and answers its health check
#   3  its container: no published port, a read-only root, every capability dropped, no-new-privileges, run as you, on
#      bne2e-vllm_vllm alone, which is internal
#   4  its API wants its key: 401 without it and with a wrong one, the model listed with it (asked from inside)
#   5  a chat completion through LiteLLM (the gateway's entry: http://vllm:8000/v1, with the key)
#   6  the log Settings shows never has the key (and whether vLLM's own log printed it)
#   7  it reaches nothing outside its network (huggingface.co, from inside its container)
#   8  Remove stops it and deletes the model's files: it waits for a model again
#   9  Uninstall deletes its folder and its image
# What the host needs: Linux, Docker with Compose, x86-64 with AVX2 (or Docker's NVIDIA runtime), about 2 GB of disk for
# the CPU image (9 GB for the CUDA one) and 300 MB for the model, 6 GB of free memory (vLLM keeps 4 GB for its cache on a
# CPU), outbound access to Docker Hub and huggingface.co. No AWS, no Claude model, nothing on Opus. It makes a Docker
# network: never run it while another end-to-end run uses this Docker (a browser check fails on a network change).
#   --repo ORG/NAME   another small safetensors model (default HuggingFaceTB/SmolLM2-135M-Instruct)
#   --keep-image      leave vLLM's image (Uninstall deletes it; the next run would download it again)
#   --out DIR         results (default tests/e2e/out, gitignored): vllm-linux.json
# Docker runs it: on a machine that shares a heavy-job lock, run the whole script inside that lock.
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
REPO=HuggingFaceTB/SmolLM2-135M-Instruct; OUT="$ROOT/tests/e2e/out"; KEEP_IMAGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo ORG/NAME}"; shift 2 ;;
    --keep-image) KEEP_IMAGE=1; shift ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    -h | --help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/vllm-linux.sh --help)" >&2; exit 2 ;;
  esac
done
say() { printf '==> %s\n' "$*" >&2; }
FAILS=0; CHECKS=()
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILS=$((FAILS + 1)); CHECKS+=("FAIL	$*"); }
ok() { printf 'ok    %s\n' "$*" >&2; CHECKS+=("ok	$*"); }
[ "$(uname -s)" = Linux ] || { echo "vLLM runs on Linux: run this on a Linux host" >&2; exit 2; }
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || { echo "needs docker with compose" >&2; exit 2; }
P=bne2e-vllm; NET="${P}_vllm"; LL="$P-litellm"; LABEL=io.devos-ade.e2e=vllm
WORK="$ROOT/tests/e2e/work/$P"
for c in $(docker ps -aq --filter "label=com.docker.compose.project=$P"); do
  echo "Compose project $P already has containers (an earlier run's?): docker compose -p $P down, then run this again" >&2; exit 2
done
if docker container inspect "$LL" >/dev/null 2>&1 && [ "$(docker container inspect -f '{{index .Config.Labels "io.devos-ade.e2e"}}' "$LL")" != vllm ]; then echo "a container named $LL exists and is not this check's: not touching it" >&2; exit 2; fi
cleanup() {
  local rc=$? c
  [ "$(docker container inspect -f '{{index .Config.Labels "io.devos-ade.e2e"}}' "$LL" 2>/dev/null)" != vllm ] || docker rm -f "$LL" >/dev/null 2>&1
  for c in $(docker ps -aq --filter "label=com.docker.compose.project=$P"); do docker rm -f "$c" >/dev/null 2>&1; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  { [ "$rc" = 0 ] && [ "$FAILS" = 0 ]; } || for f in install pull rm uninstall failed up; do [ ! -f "$WORK/$f.log" ] || { mkdir -p "$OUT" && cp "$WORK/$f.log" "$OUT/vllm-linux-$f.log"; }; done 2>/dev/null
  rm -rf "$WORK"
  mkdir -p "$OUT" 2>/dev/null && printf '%s\n' ${CHECKS[@]+"${CHECKS[@]}"} | python3 -I -c 'import json, sys
print(json.dumps({"failures": int(sys.argv[1]), "checks": [dict(zip(("status", "check"), l.rstrip("\n").split("\t", 1))) for l in sys.stdin if "\t" in l]}, indent=1))' "$FAILS" > "$OUT/vllm-linux.json" 2>/dev/null
}
trap cleanup EXIT; trap 'exit 130' INT TERM
rm -rf "$WORK"; mkdir -p "$WORK/state" "$WORK/litellm" "$OUT"
LIMG="$(sed -n 's/^    image: \(ghcr.io\/berriai\/litellm:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
[ -n "$LIMG" ] || { echo "no LiteLLM image in compose.yaml" >&2; exit 2; }

# --- this checkout's code, on a scratch .env and state dir ---
STACK_DIR="$ROOT"; ENV_FILE="$WORK/.env"; STATE_DIR="$WORK/state"
printf 'COMPOSE_PROJECT_NAME=%s\nLOCAL_RUNTIME=vllm\nPOSTGRES_PASSWORD=p\nRUSTFS_ACCESS_KEY=a\nRUSTFS_SECRET_KEY=s\nLITELLM_MASTER_KEY=m\nLITELLM_SALT_KEY=s\nLITELLM_UI_PASSWORD=u\nWEBUI_SECRET_KEY=w\nOPENWEBUI_ADMIN_EMAIL=a@b.c\nOPENWEBUI_ADMIN_PASSWORD=p\nSHARED_MCP_TOKEN=t\nLOCALGIT=off\nWEBSEARCH_SEARXNG_BUILTIN=off\n' "$P" > "$ENV_FILE"
export STACK_DIR ENV_FILE STATE_DIR ASSUME_YES=1
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
# a real config apply saves .env, then reloads LiteLLM live; here it saves .env only, and the one container is started on
# the rendered config instead
config_apply() { _cfg_write; CFG_ORDER=''; }
get_env() { K="$1" awk 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2) } END { printf "%s", v }' "$ENV_FILE"; }
WHY="$(rt_why_not vllm)"; [ -z "$WHY" ] || { echo "vLLM does not run here: $WHY" >&2; exit 2; }
D="$(rt_dir vllm)"
# vllm_ask PATH [KEY] -> the HTTP status of GET 127.0.0.1:8000PATH from inside its container, then its body (the key on
# stdin, never an argument)
vllm_ask() {
  printf '%s' "${2:-}" | docker exec -i "$(_RT_PROFILE=vllm dc ps -q vllm)" python3 -I -c '
import sys, urllib.request, urllib.error
k = sys.stdin.read().strip()
r = urllib.request.Request("http://127.0.0.1:8000" + sys.argv[1], headers={"Authorization": "Bearer " + k} if k else {})
try:
    with urllib.request.urlopen(r, timeout=30) as f:
        print(f.status); print(f.read(4000).decode("utf-8", "replace"))
except urllib.error.HTTPError as e:
    print(e.code)' "$1" 2>&1
}

say "installing vLLM $(rt_pinned_version vllm) ($(rt_size vllm))"
( rt_install vllm ) > "$WORK/install.log" 2>&1 || { fail "1 install failed: $(tail -n 3 "$WORK/install.log" | tr '\n' ' ')"; exit 1; }
if [ "$(rt_state vllm)" = waiting ] && [ -z "$(_RT_PROFILE=vllm dc ps -aq vllm 2>/dev/null)" ]; then ok "1 installed $(rt_installed_version vllm)$([ -f "$D/gpu" ] && echo ' (NVIDIA GPUs)' || echo ' (CPU)'): it waits for a model, with no container"
else fail "1 after install: state $(rt_state vllm), containers '$(_RT_PROFILE=vllm dc ps -aq vllm 2>/dev/null)'"; fi

say "downloading $REPO and serving it (its first start can take minutes)"
T0="$(date +%s)"
( LOCAL_POLL_S=2 local_pull "$REPO" safetensors --tools no --params-m 135 --context 8192 --license apache-2.0 ) > "$WORK/pull.log" 2>&1 \
  || { fail "2 the download or its start failed: $(tail -n 3 "$WORK/pull.log" | tr '\n' ' ')"
       if [ -s "$D/failed.log" ]; then say "the log of that start:"; tail -n 60 "$D/failed.log" >&2; cp "$D/failed.log" "$WORK/failed.log"; fi
       [ ! -s "$D/up.log" ] || cp "$D/up.log" "$WORK/up.log"; exit 1; }
if [ "$(rt_vllm_serving)" = "$REPO" ] && [ "$(rt_state vllm)" = running ] && [ -n "$(_rt_version vllm)" ]; then
  ok "2 served $REPO after $(($(date +%s) - T0)) s: $(grep -E '^(max-model-len|tool-call-parser):' "$D/etc/serve.yaml" | tr '\n' ' ')"
else fail "2 serving '$(rt_vllm_serving)', state $(rt_state vllm)"; fi
C="$(_RT_PROFILE=vllm dc ps -q vllm)"

# --- the container ---
INS="$(docker inspect "$C" | python3 -I -c '
import json, sys
c = json.load(sys.stdin)[0]; h = c["HostConfig"]
print("ports=%s ro=%s capdrop=%s nnp=%s user=%s nets=%s" % (
    bool(h.get("PortBindings")) or any(v for v in (c["NetworkSettings"].get("Ports") or {}).values()),
    h.get("ReadonlyRootfs"), ",".join(h.get("CapDrop") or []), any("no-new-privileges" in o for o in h.get("SecurityOpt") or []),
    c["Config"].get("User"), ",".join(sorted(c["NetworkSettings"]["Networks"]))))')"
WANT="ports=False ro=True capdrop=ALL nnp=True user=$(cat "$D/user") nets=$NET"
if [ "$INS" = "$WANT" ] && [ "$(docker network inspect -f '{{.Internal}}' "$NET")" = true ]; then ok "3 its container: $INS, an internal network"
else fail "3 its container: $INS (wanted $WANT; internal: $(docker network inspect -f '{{.Internal}}' "$NET" 2>&1))"; fi

# --- its key ---
K="$(rt_api_key vllm)"
A1="$(vllm_ask /v1/models | head -n 1)"; A2="$(vllm_ask /v1/models "$(printf '0%.0s' $(seq 64))" | head -n 1)"; A3="$(vllm_ask /v1/models "$K")"
if [ "$A1" = 401 ] && [ "$A2" = 401 ] && [ "$(printf '%s\n' "$A3" | head -n 1)" = 200 ] && printf '%s' "$A3" | grep -F "\"$REPO\"" >/dev/null; then ok "4 its API: 401 without its key and with a wrong one; with it, $REPO listed"
else fail "4 its API: no key $A1, a wrong key $A2, its key $(printf '%s' "$A3" | head -c 200 | tr '\n' ' ')"; fi

# --- LiteLLM on this checkout's rendered config, on vLLM's network ---
NAME="$(local_model_name "$(get_env LOCAL_MODELS)")"
{ printf 'model_list:\n'; local_models_yaml; printf 'litellm_settings:\n  drop_params: true\n'; } > "$WORK/litellm/config.yaml"
grep -F 'api_base: "http://vllm:8000/v1"' "$WORK/litellm/config.yaml" >/dev/null || fail "5 the rendered entry has no vLLM address: $(grep -v api_key "$WORK/litellm/config.yaml")"
chmod 755 "$WORK" "$WORK/litellm"; chmod 644 "$WORK/litellm/config.yaml"   # (its key is this run's, deleted with it)
MK="sk-e2e-$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')"
LITELLM_MASTER_KEY="$MK" docker run -d --name "$LL" -e LITELLM_MASTER_KEY -e LITELLM_LOCAL_MODEL_COST_MAP=True --label "$LABEL" --network "$NET" \
  -v "$WORK/litellm/config.yaml:/app/config.yaml:ro" "$LIMG" --config /app/config.yaml --port 4000 >/dev/null || { fail "5 LiteLLM did not start"; exit 1; }
ask_litellm() {   # ask_litellm -> the answer's text (the master key and the request on stdin)
  python3 -I -c 'import json, sys; print(json.dumps({"key": sys.argv[1], "body": {"model": sys.argv[2], "max_tokens": 24, "messages": [{"role": "user", "content": "Say hello in three words."}]}}))' "$MK" "$NAME" \
  | docker exec -i "$LL" python3 -I -c '
import json, sys, time, urllib.request, urllib.error
q = json.load(sys.stdin)
for _ in range(90):
    try:
        urllib.request.urlopen("http://127.0.0.1:4000/health/liveliness", timeout=3); break
    except Exception:
        time.sleep(2)
r = urllib.request.Request("http://127.0.0.1:4000/v1/chat/completions", json.dumps(q["body"]).encode(),
                           {"Authorization": "Bearer " + q["key"], "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(r, timeout=300) as f:
        print(json.load(f)["choices"][0]["message"]["content"].strip()[:200])
except urllib.error.HTTPError as e:
    print("HTTP %d: %s" % (e.code, e.read(300).decode("utf-8", "replace"))); sys.exit(1)' 2>&1
}
if ANS="$(ask_litellm)" && [ -n "$ANS" ]; then ok "5 a chat completion through LiteLLM on $NAME: $(printf '%s' "$ANS" | tr '\n' ' ' | cut -c1-80)"
else fail "5 no answer through LiteLLM: $ANS $(docker logs --tail 5 "$LL" 2>&1 | rt_key_redact | tr '\n' ' ' | cut -c1-300)"; fi

# --- its log ---
RAW="$(docker logs "$C" 2>&1 | grep -cF "$K" || true)"
if rt_logs_text vllm 2000 | grep -F "$K" >/dev/null; then fail "6 the log Settings shows has its key"
else ok "6 the log Settings shows has no key (vLLM's own log printed it $RAW time(s))"; fi

# --- nothing outside ---
OUTSIDE="$(docker exec "$C" python3 -I -c '
import socket
try:
    socket.create_connection(("huggingface.co", 443), timeout=10); print("reached")
except OSError as e:
    print("refused: %s" % e.__class__.__name__)' 2>&1)"
case "$OUTSIDE" in refused:*) ok "7 from its container huggingface.co is not reachable ($OUTSIDE)" ;; *) fail "7 from its container: $OUTSIDE" ;; esac

# --- Remove, Uninstall ---
say "removing it"
SNAP="$D/hub/models--${REPO//\//--}"
( local_rm "$REPO" safetensors ) > "$WORK/rm.log" 2>&1 || fail "8 Remove: $(tail -n 3 "$WORK/rm.log" | tr '\n' ' ')"
if [ "$(rt_state vllm)" = waiting ] && [ -z "$(_RT_PROFILE=vllm dc ps -aq vllm 2>/dev/null)" ] && [ ! -e "$SNAP" ] && [ -z "$(get_env LOCAL_MODELS)" ]; then ok "8 Remove stopped it and deleted $REPO: it waits for a model again"
else fail "8 after Remove: state $(rt_state vllm), files $([ -e "$SNAP" ] && echo left || echo gone), LOCAL_MODELS '$(get_env LOCAL_MODELS)'"; fi
IMG="$(_RT_PROFILE=vllm dc config --images vllm 2>/dev/null)"
( if [ "$KEEP_IMAGE" = 1 ]; then docker() { [ "${1:-} ${2:-}" != "image rm" ] || return 0; command docker "$@"; }; fi   # (--keep-image: all of Uninstall but that)
  rt_uninstall vllm ) > "$WORK/uninstall.log" 2>&1 || fail "9 Uninstall: $(tail -n 3 "$WORK/uninstall.log" | tr '\n' ' ')"
if docker image inspect "$IMG" >/dev/null 2>&1; then LEFT=1; else LEFT=0; fi
if [ -n "$IMG" ] && [ ! -e "$D" ] && [ "$(rt_state vllm)" = not-installed ] && [ "$LEFT" = "$KEEP_IMAGE" ]; then ok "9 Uninstall deleted its folder$([ "$KEEP_IMAGE" = 1 ] && echo " (its image kept: --keep-image)" || echo " and its image ($IMG)")"
else fail "9 after Uninstall: folder $([ -e "$D" ] && echo left || echo gone), image '$IMG' $([ "$LEFT" = 1 ] && echo left || echo gone)"; fi
[ "$FAILS" -eq 0 ] && { echo "vLLM: all checks passed" >&2; exit 0; } || exit 1
