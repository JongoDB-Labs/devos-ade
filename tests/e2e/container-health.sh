#!/usr/bin/env bash
# Synthetic-failure fixture for local container health (JON-440 G4, lib/health.sh), with REAL disposable containers:
# three tiny containers carrying a throwaway Compose project's labels that exit with code 3, restart by themselves and
# go unhealthy. Asserts lib/health.sh counts each, and that the portal's Activity feed (portal/activity.py) shows them.
# The stack's own services are never touched: only containers of the throwaway project "bnhealthfx<pid>" are made and,
# at the end (also on failure), removed. No model, no network use beyond an image already on this computer.
#
# Run under the DevOS heavy lock (exit 75: busy, retry later):
#   python3 ~/.claude/skills/apple-app-submission/scripts/heavylock.py run --lock ~/.local/state/devos-heavy/heavy.lock \
#     --label ade-jon440 --timeout 0 -- tests/e2e/container-health.sh
# FIXTURE_IMAGE: any local image with /bin/sh (default: bedrock-now/portal:local, else the first local image that works).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"; P="bnhealthfx$$"; TMP="$(mktemp -d)"; fails=0
cleanup() { docker ps -a -q --filter "label=com.docker.compose.project=$P" | xargs docker rm -f >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
IMG="${FIXTURE_IMAGE:-bedrock-now/portal:local}"
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "no local image $IMG (set FIXTURE_IMAGE)" >&2; exit 2; }
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
run() { # run SERVICE [docker run flags…] -- command…
  local svc="$1"; shift
  docker run -d --name "$P-$svc" --label "com.docker.compose.project=$P" --label "com.docker.compose.service=$svc" \
    --entrypoint /bin/sh "$@" >/dev/null
}
run fx-exit --no-healthcheck "$IMG" -c 'exit 3'
run fx-restart --no-healthcheck --restart on-failure:3 "$IMG" -c 'exit 1'
run fx-unhealthy --health-cmd "exit 1" --health-interval 1s --health-timeout 2s --health-retries 1 --health-start-period 1ms "$IMG" -c "sleep 120"
run fx-ok --no-healthcheck "$IMG" -c 'sleep 120'
for _ in $(seq 1 30); do   # until the restarts ran out and the health check had its say
  [ "$(docker inspect -f '{{.RestartCount}}' "$P-fx-restart")" = 3 ] && [ "$(docker inspect -f '{{.State.Health.Status}}' "$P-fx-unhealthy")" = unhealthy ] && break
  sleep 1
done

# lib/health.sh against that project, in a throwaway state folder (never this checkout's .state)
export STACK_DIR="$ROOT" ENV_FILE="$TMP/.env" STATE_DIR="$TMP/.state" BEDROCK_NOW_NO_OPEN=1
printf 'COMPOSE_PROJECT_NAME=%s\n' "$P" > "$ENV_FILE"; mkdir -p "$STATE_DIR"
# shellcheck disable=SC1091
. lib/common.sh; . lib/ports.sh; . lib/portal.sh; . lib/models.sh; . lib/prices.sh
. "$ROOT/lib/commands.sh"
health_record_write
J="$(health_json_file)"
ev() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(sum(1 for e in d["events"] if e["service"] == sys.argv[2] and e["kind"] == sys.argv[3] and (e["count"], e["exit_code"]) == (int(sys.argv[4]), int(sys.argv[5]))))' "$J" "$@"; }
[ "$(ev fx-exit exit 0 3)" = 1 ] && ok "exit code 3 recorded" || bad "exit code 3 not recorded"
[ "$(ev fx-restart restart 3 1)" = 1 ] && ok "3 restarts counted" || bad "restarts not counted: $(cat "$J")"
[ "$(ev fx-unhealthy unhealthy 0 0)" = 1 ] && ok "unhealthy turn recorded" || bad "unhealthy not recorded"
[ "$(python3 -I -c 'import json, sys; print(sum(1 for e in json.load(open(sys.argv[1]))["events"] if e["service"] == "fx-ok"))' "$J")" = 0 ] && ok "the healthy one has no events" || bad "healthy container has events"
before="$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["events"]))' "$J")"
health_record_write
[ "$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["events"]))' "$J")" = "$before" ] && ok "a second look counts nothing twice" || bad "events counted twice"

# the portal's Activity shows them
mkdir -p "$TMP/status" && cp "$J" "$TMP/status/container-health.json"
out="$(cd portal && python3 -c '
import sys, time
sys.path.insert(0, ".")
from pathlib import Path
from portal import activity
for i in activity.health_items(Path(sys.argv[1]), time.time()): print(i["level"], i["title"])' "$TMP/status" 2>&1)"
miss=''
for w in "bad fx-exit exited with code 3" "warn fx-restart restarted 3 times" "warn fx-unhealthy became unhealthy"; do
  case "$out" in *"$w"*) ;; *) miss="$miss [$w]" ;; esac
done
[ -z "$miss" ] && ok "Activity lists exit, restarts and unhealthy" || bad "Activity is missing$miss: $out"
cleanup; trap - EXIT
[ -z "$(docker ps -a -q --filter "label=com.docker.compose.project=$P")" ] && ok "fixture containers removed" || bad "fixture containers left"
[ "$fails" = 0 ] && echo "container-health e2e: all ok" || { echo "container-health e2e: $fails failed"; exit 1; }
