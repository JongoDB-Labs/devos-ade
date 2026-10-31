#!/usr/bin/env bash
# Opt-in end-to-end check (run by hand; not part of tests/run.sh or CI; JON-815): the REAL LiteLLM image this checkout pins
# (compose.yaml) with its REAL Postgres, our rendered config and our hook (lib/litellm-hooks/bn_hooks.py), and the live
# model-list path of lib/litellm_live.sh against it — the same /model/new and /config/update calls ./stack config makes
# (JON-533). A LiteLLM bump must keep all of it working:
#   - LiteLLM starts on our config with our hook (the hook's bn_* keys are on each model, /v1/models lists the models)
#   - a model added live appears in /v1/models and its model_info without a restart (the container's id and start time stay)
#   - a model removed live goes, a changed one changes; the database rows /model/new left are gone again
#   - LiteLLM's own /get/latest_release_info route still exists (caddy/Caddyfile answers it with null for the admin UI)
# No Bedrock call is made and no real key is used (the AWS key is a made-up one, built here; nothing calls AWS). Only the
# Compose project bne2e-live (postgres + litellm), a port of its own on 127.0.0.1; never another install.
#
#   tests/e2e/litellm-live.sh [--keep] [--port N] [--out DIR]
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROJECT=bne2e-live
PORT=14055
KEEP=0
OUT="$ROOT/tests/e2e/out"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    *) echo "usage: tests/e2e/litellm-live.sh [--keep] [--port N] [--out DIR]" >&2; exit 2 ;;
  esac
done
STACK="$ROOT/tests/e2e/work/$PROJECT"
mkdir -p "$OUT" "$STACK"
LOG="$OUT/litellm-live.log"; : > "$LOG"
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
run_stack() { ( export STACK_DIR="$STACK" ENV_FILE="$STACK/.env" STATE_DIR="$STACK/.state" DEVOS_ADE_NO_OPEN=1
                cd "$STACK" && _libs && "$@" ); }
# run_eval CODE [ARGS…] — CODE (shell text) in that same environment, with ARGS as $1…
run_eval() { local code="$1"; shift
             ( export STACK_DIR="$STACK" ENV_FILE="$STACK/.env" STATE_DIR="$STACK/.state" DEVOS_ADE_NO_OPEN=1
               cd "$STACK" && _libs && eval "$code" ); }

printf '%s\n' claude-haiku-5-5 titan-embed-v2 > "$STACK/.state/enabled-1"
printf '%s\n' claude-haiku-5-5 titan-embed-v2 mistral-large-3 > "$STACK/.state/enabled-2"
printf '%s\n' titan-embed-v2 mistral-large-3 > "$STACK/.state/enabled-3"

echo "==> $(sed -n 's|^    image: \(ghcr.io/berriai/litellm:[^ ]*\)$|\1|p' "$STACK/compose.yaml")" | tee -a "$LOG" >&2
run_stack render_config "$STACK/.state/enabled-1" || { echo "xx could not render the config" >&2; exit 1; }
cp "$STACK/litellm/config.yaml" "$STACK/.state/config-1.yaml"

# up: postgres + litellm, the pinned images (pulled by digest), our config and hook
run_eval 'export $(config_sums | tr "\n" " "); dc up -d --wait postgres litellm' >> "$LOG" 2>&1 || { bad "postgres and litellm start (see $LOG)"; docker compose -p "$PROJECT" --env-file "$STACK/.env" logs litellm 2>&1 | tail -30 >> "$LOG"; exit 1; }
ok "postgres and litellm are up on the pinned images"

cid="$(docker ps -q --no-trunc --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=litellm")"
started="$(docker inspect -f '{{.State.StartedAt}}' "$cid")"
# the pinned image really is the one running (the digest check ./stack update makes)
pinned="$(sed -n 's|^    image: ghcr.io/berriai/litellm:[^@ ]*@\(sha256:[0-9a-f]*\)$|\1|p' "$STACK/compose.yaml")"
img="$(docker inspect -f '{{.Image}}' "$cid")"
have "LiteLLM runs the image this checkout pins (digest)" "$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$img")" "$pinned"
check "LiteLLM's liveliness" "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health/liveliness")" 200

models="$(api "http://127.0.0.1:$PORT/v1/models")"
have "/v1/models lists claude-haiku-5-5" "$models" '"claude-haiku-5-5"'
info="$(api "http://127.0.0.1:$PORT/model/info")"
have "the hook's model_info reaches LiteLLM (bn_ keys on a model)" "$info" '"bn_'
have "a stable id on each model" "$info" '"id":"bn-claude-haiku-5-5"'

# LiteLLM's own release lookup route (the admin UI's banner): Caddy answers it, but it must still be this route
rel="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/get/latest_release_info")"
case "$rel" in 200) ok "LiteLLM still has /get/latest_release_info (caddy/Caddyfile litellm_no_banner answers it for the UI)" ;; *) bad "LiteLLM's /get/latest_release_info answered $rel (the route moved: caddy/Caddyfile litellm_no_banner)" ;; esac

# live: add a model without a restart
run_stack render_config "$STACK/.state/enabled-2" || bad "render the second config"
out="$(run_eval 'litellm_live_sync "$(litellm_serving_sum "$1")" "$2"; rc=$?; echo "rc=$rc said=$LITELLM_LIVE_SAID err=$LITELLM_LIVE_ERR"' "$cid" "$STACK/.state/config-1.yaml" 2>&1 | tail -n 1)"
have "adding a model goes live (litellm_live_sync: 0)" "$out" "rc=0"
models="$(api "http://127.0.0.1:$PORT/v1/models")"
have "the added model is served at once" "$models" '"mistral-large-3"'
check "LiteLLM was not restarted" "$(docker inspect -f '{{.State.StartedAt}}' "$cid")" "$started"
check "the container is the same one" "$(docker ps -q --no-trunc --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=litellm")" "$cid"
info="$(api "http://127.0.0.1:$PORT/model/info")"
have "the added model has our hook's keys and stable id" "$info" '"id":"bn-mistral-large-3"'
rows="$(docker exec "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=postgres")" psql -U postgres -d litellm -qAt -c "SELECT count(*) FROM \"LiteLLM_ProxyModelTable\" WHERE model_id LIKE 'bn-%'")"
check "no database row of ours is left (config.yaml stays the only record)" "$rows" 0

# live: remove a model
cp "$STACK/litellm/config.yaml" "$STACK/.state/config-2.yaml"
run_stack render_config "$STACK/.state/enabled-3" || bad "render the third config"
out="$(run_eval 'litellm_live_sync "$(litellm_serving_sum "$1")" "$2"; rc=$?; echo "rc=$rc said=$LITELLM_LIVE_SAID err=$LITELLM_LIVE_ERR"' "$cid" "$STACK/.state/config-2.yaml" 2>&1 | tail -n 1)"
have "removing a model goes live (litellm_live_sync: 0)" "$out" "rc=0"
models="$(api "http://127.0.0.1:$PORT/v1/models")"
lacks "the removed model is gone" "$models" '"claude-haiku-5-5"'
have "the others stay" "$models" '"mistral-large-3"'
check "still not restarted" "$(docker inspect -f '{{.State.StartedAt}}' "$cid")" "$started"

# a restart reads config.yaml alone (what ./stack up does): the same list comes back
docker restart "$cid" >> "$LOG" 2>&1
for _ in $(seq 1 90); do [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health/liveliness")" = 200 ] && break; sleep 2; done
models="$(api "http://127.0.0.1:$PORT/v1/models")"
have "after a restart LiteLLM serves config.yaml's models" "$models" '"mistral-large-3"'
lacks "and not the model that was removed" "$models" '"claude-haiku-5-5"'

if [ "$fails" -eq 0 ]; then echo "litellm-live: all checks passed" | tee -a "$LOG" >&2; else echo "litellm-live: $fails FAILED (see $LOG)" | tee -a "$LOG" >&2; fi
[ "$KEEP" = 1 ] && echo "kept: project $PROJECT (docker compose -p $PROJECT down -v removes it)" >&2
exit "$((fails > 0))"
