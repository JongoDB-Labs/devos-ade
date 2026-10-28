#!/usr/bin/env bash
# Opt-in end-to-end check (run by hand; not part of tests/run.sh or CI; JON-815): the REAL Open WebUI image this checkout
# pins (compose.yaml, by digest) with our vendoring layer (open-webui/Dockerfile: the Python runner's wheels), built the
# way ./stack builds it, on its real Postgres, RustFS and LiteLLM, and the Open WebUI API calls lib/owui.sh makes. An Open
# WebUI bump must keep all of it working:
#   - the build succeeds on the pinned base, the image carries the base-image label (what ./stack update checks)
#   - Open WebUI starts healthy; the admin signs in; an API key can be made (ensure_openwebui_api_key)
#   - the model upsert, the cost-filter function, the banners and the config calls of lib/owui.sh get their usual answers
#   - Chat's Python runner: /pyodide/pyodide-lock.json is served and the vendored wheels list is there
# No model call is made and no real key is used. Only the Compose project bne2e-owui, a port of its own on 127.0.0.1.
#
#   tests/e2e/openwebui-pin.sh [--keep] [--port N] [--out DIR]
set -uo pipefail
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROJECT=bne2e-owui
PORT=14056
KEEP=0
OUT="$ROOT/tests/e2e/out"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    *) echo "usage: tests/e2e/openwebui-pin.sh [--keep] [--port N] [--out DIR]" >&2; exit 2 ;;
  esac
done
STACK="$ROOT/tests/e2e/work/$PROJECT"
mkdir -p "$OUT" "$STACK"
LOG="$OUT/openwebui-pin.log"; : > "$LOG"
fails=0
ok()   { printf '  ok    %s\n' "$1" | tee -a "$LOG" >&2; }
bad()  { printf '  FAIL  %s\n' "$1" | tee -a "$LOG" >&2; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got «$2», want «$3»)"; fi; }
have() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no «$3» in «$(printf '%s' "$2" | cut -c1-200)»)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 («$3» is still there)" ;; *) ok "$1" ;; esac; }

# shellcheck disable=SC2317,SC2329  # (the EXIT trap)
teardown() {
  # by exact project name: only this suite's own containers, network and volumes
  ( cd "$STACK" 2>/dev/null && docker compose -p "$PROJECT" --env-file "$STACK/.env" down -v --remove-orphans >> "$LOG" 2>&1 ) || true
}
[ "$KEEP" = 1 ] || trap teardown EXIT

# the throwaway checkout: this tree's files (not .git, not other runs' output), with its own .env
rsync -a --delete --exclude .git --exclude node_modules --exclude 'tests/e2e/work' --exclude 'tests/e2e/out' --exclude .state --exclude backups \
  --exclude '.env' "$ROOT/" "$STACK/" || { echo "xx rsync failed" >&2; exit 1; }
mkdir -p "$STACK/litellm" "$STACK/.state"
rnd() { LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c "${1:-32}"; }
# a made-up key shaped like an access key, assembled here (the literal never exists in the repository)
FAKE_ID="AK""IA$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 16)"
{
  printf 'COMPOSE_PROJECT_NAME=%s\nLITELLM_PORT=%s\nAWS_REGION_NAME=us-east-1\n' "$PROJECT" "$PORT"
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$FAKE_ID" "$(rnd 40)"
  printf 'POSTGRES_PASSWORD=%s\nLITELLM_MASTER_KEY=sk-%s\nLITELLM_SALT_KEY=sk-%s\nLITELLM_UI_PASSWORD=%s\n' "$(rnd)" "$(rnd)" "$(rnd)" "$(rnd 16)"
  printf 'OPENWEBUI_ADMIN_EMAIL=e2e@example.com\nOPENWEBUI_ADMIN_PASSWORD=%s\nRUSTFS_ACCESS_KEY=%s\nRUSTFS_SECRET_KEY=%s\n' "$(rnd 16)" "$(rnd 12)" "$(rnd 24)"
  printf 'SHARED_MCP_TOKEN=%s\nWEBUI_SECRET_KEY=%s\nPORTAL_PASSWORD=%s\n' "$(rnd)" "$(rnd)" "$(rnd 16)"
} > "$STACK/.env"
chmod 600 "$STACK/.env"

KEY="$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$STACK/.env")"
api() { curl -s -m 30 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$@"; }

# the libraries ./stack itself sources, in its order (commands.sh alone lacks common.sh's variables)
_libs() { local l; for l in common ports portal models commands guard open owui prices; do . "$STACK/lib/$l.sh"; done; }
# lib/commands.sh in a subshell of its own: the throwaway's ./stack functions, never this shell's environment
run_stack() { ( export STACK_DIR="$STACK" ENV_FILE="$STACK/.env" STATE_DIR="$STACK/.state" BEDROCK_NOW_NO_OPEN=1
                cd "$STACK" && _libs && "$@" ); }
# run_eval CODE [ARGS…] — CODE (shell text) in that same environment, with ARGS as $1…
run_eval() { local code="$1"; shift
             ( export STACK_DIR="$STACK" ENV_FILE="$STACK/.env" STATE_DIR="$STACK/.state" BEDROCK_NOW_NO_OPEN=1
               cd "$STACK" && _libs && eval "$code" ); }


echo "==> $(sed -n 's|^        image: \(ghcr.io/open-webui/[^ ]*\)$|\1|p' "$STACK/compose.yaml")" | tee -a "$LOG" >&2
printf '%s\n' claude-haiku-5-5 titan-embed-v2 > "$STACK/.state/enabled-1"
run_stack render_config "$STACK/.state/enabled-1" || { echo "xx could not render the config" >&2; exit 1; }

# build open-webui (our layer on the pinned base) and bring up what it depends on
run_eval 'export $(config_sums | tr "\n" " "); dc build open-webui && dc up -d --wait postgres litellm rustfs rustfs-init open-webui' >> "$LOG" 2>&1 \
  || { bad "the Open WebUI image builds and starts (see $LOG)"; docker compose -p "$PROJECT" --env-file "$STACK/.env" logs open-webui 2>&1 | tail -40 >> "$LOG"; exit 1; }
ok "the Open WebUI image builds on the pinned base and starts healthy"

cid="$(docker ps -q --no-trunc --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=open-webui")"
pinned="$(sed -n 's|^        image: ghcr.io/open-webui/open-webui:[^@ ]*@\(sha256:[0-9a-f]*\)$|\1|p' "$STACK/compose.yaml")"
have "the image's base-image label names the pinned digest" "$(docker image inspect -f '{{index .Config.Labels "dev.devos-ade.base-image"}}' "$(docker inspect -f '{{.Image}}' "$cid")")" "$pinned"
# the version Open WebUI itself reports (/api/config): the package's own metadata is not installed in the image
ver="$(docker exec "$cid" python3 -c 'import json,urllib.request; print(json.load(urllib.request.urlopen("http://localhost:8080/api/config", timeout=30))["version"])' 2>/dev/null || true)"
have "Open WebUI reports the pinned version" "$ver" "0.12.4"

# the API, from inside the container (Caddy is not part of this project)
cat > "$STACK/.state/owui_call.py" <<'PY'
import json, sys, urllib.request, urllib.error
method, path, token = sys.argv[1], sys.argv[2], sys.argv[3]
body = sys.argv[4] if len(sys.argv) > 4 else None
who = sys.argv[5] if len(sys.argv) > 5 else None
req = urllib.request.Request("http://localhost:8080" + path, data=body.encode() if body else None, method=method)
req.add_header("Content-Type", "application/json")
if token: req.add_header("Authorization", "Bearer " + token)
if who: req.add_header("X-Portal-User", who)   # as Caddy sends it after the portal's sign-in (WEBUI_AUTH_TRUSTED_EMAIL_HEADER)
try:
    r = urllib.request.urlopen(req, timeout=30); print(r.status, r.read().decode()[:4000])
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode()[:500])
PY
docker cp "$STACK/.state/owui_call.py" "$cid:/tmp/owui_call.py" >/dev/null
call() { docker exec "$cid" python3 /tmp/owui_call.py "$@" 2>&1; }
code_of() { printf '%s' "${1%% *}"; }
body_of() { printf '%s' "${1#* }"; }

check "/health" "$(code_of "$(call GET /health '')")" 200
cfg="$(call GET /api/config '')"; check "/api/config" "$(code_of "$cfg")" 200
have "/api/config names the version" "$cfg" '"version"'
# the stack signs the admin in by the trusted header Caddy sets after the portal's sign-in, never by a password form
r="$(call POST /api/v1/auths/signin '' '{"email":"","password":""}' e2e@example.com)"
check "the admin signs in by the trusted header (/api/v1/auths/signin)" "$(code_of "$r")" 200
tok="$(body_of "$r" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
r="$(call POST /api/v1/auths/api_key "$tok")"
check "an API key can be made (/api/v1/auths/api_key)" "$(code_of "$r")" 200
key="$(body_of "$r" | sed -n 's/.*"api_key":"\([^"]*\)".*/\1/p')"
have "the API key has the usual shape" "$key" "sk-"

check "an unknown model is a 401/404 answer, not an error (/api/v1/models/model)" "$(code_of "$(call GET '/api/v1/models/model?id=nope' "$key")")" 404
mid="bne2e-model"
r="$(call POST /api/v1/models/create "$key" "{\"id\":\"$mid\",\"base_model_id\":\"claude-haiku-5-5\",\"name\":\"E2E\",\"meta\":{\"description\":\"d\",\"tags\":[{\"name\":\"t\"}]},\"params\":{},\"is_active\":true}")"
check "a model is created (/api/v1/models/create)" "$(code_of "$r")" 200
r="$(call GET "/api/v1/models/model?id=$mid" "$key")"
check "the model reads back" "$(code_of "$r")" 200
r="$(call POST /api/v1/models/model/update "$key" "{\"id\":\"$mid\",\"base_model_id\":\"claude-haiku-5-5\",\"name\":\"E2E 2\",\"meta\":{\"description\":\"d\"},\"params\":{},\"is_active\":true}")"
check "the model updates (/api/v1/models/model/update)" "$(code_of "$r")" 200
have "the update stuck" "$(call GET "/api/v1/models/model?id=$mid" "$key")" "E2E 2"

fn_src="$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$STACK/owui/functions/bedrock_cost.py")"
r="$(call POST /api/v1/functions/create "$key" "{\"id\":\"e2e_cost\",\"name\":\"E2E cost\",\"content\":$fn_src,\"meta\":{\"description\":\"x\"}}")"
check "the cost filter function installs (/api/v1/functions/create)" "$(code_of "$r")" 200
check "its valves read back" "$(code_of "$(call GET /api/v1/functions/id/e2e_cost/valves "$key")")" 200
check "it toggles (/toggle)" "$(code_of "$(call POST /api/v1/functions/id/e2e_cost/toggle "$key" '{}')")" 200
check "it toggles global (/toggle/global)" "$(code_of "$(call POST /api/v1/functions/id/e2e_cost/toggle/global "$key" '{}')")" 200
check "the banners read (/api/v1/configs/banners)" "$(code_of "$(call GET /api/v1/configs/banners "$key")")" 200
check "the banners write" "$(code_of "$(call POST /api/v1/configs/banners "$key" '{"banners":[]}')")" 200

# Chat's Python runner: the wheels vendored into the image
have "pyodide's lock is served (Chat's Python runner)" "$(call GET /pyodide/pyodide-lock.json '' | cut -c1-60)" "200"
v="$(docker exec "$cid" sh -c 'cat /opt/bn-vendor/vendored.json 2>/dev/null | head -c 200')"
have "the vendored wheels list is there" "$v" "{"
lacks "pyodide's console page is gone" "$(docker exec "$cid" sh -c 'ls /app/build/pyodide' 2>&1)" "console.html"

echo
if [ "$fails" -eq 0 ]; then echo "openwebui-pin: all checks passed"; else echo "openwebui-pin: $fails check(s) FAILED (log: $LOG)"; exit 1; fi
