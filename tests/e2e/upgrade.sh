#!/usr/bin/env bash
# Opt-in end-to-end check of the upgrade to this checkout (v0.25.0: bedrock-now becomes DevOS ADE) from an install on
# an earlier release, on a THROWAWAY stack, the way such an install gets it: the portal's Update now (a request the
# update helper picks up), never a direct ./stack update. Run by hand (not part of tests/run.sh); Docker and a real
# AWS key; costs about a cent on Bedrock (setup's probe and smoke test twice, one Haiku answer).
#
#   tests/e2e/upgrade.sh --aws-env FILE [--project bne2e-rebrand-up] [--from v0.24.0] [--keep] [--real-github]
#   tests/e2e/upgrade.sh --teardown [--project bne2e-rebrand-up]
#
#   --from TAG       the release the throwaway starts on (default v0.24.0)
#   --real-github    origin is the project's GitHub address under its OLD name (https://github.com/JongoDB-Labs/
#                    bedrock-now.git, read only): the update fetches through GitHub's redirect and goes to the newest
#                    release there — so only after v0.25.0 is published — and origin must then point at the new name;
#                    the portal's update check is asked once too (api.github.com, the new name). Default: origin is
#                    this checkout, and the release to update to is a local tag on its HEAD plus its working tree (as
#                    run.sh stages it), in the throwaway only: v0.25.0, or, once that release exists, the patch after
#                    the newest release here (a tag the update's fetch never meets).
#   --keep           leave the throwaway running (tests/e2e/upgrade.sh --teardown --project NAME removes it)
#
# 1. stage: a clone of this checkout in tests/e2e/work/PROJECT at --from; .env seeded with the project, free ports
#    (never 80, 443, 3000, 3009, 4000, 8080, 8081, 8090, 8765, 8800), small budgets, the Code page's workspace next to
#    the checkout; ./stack setup there.
# 2. seed: an Open WebUI chat (its API, no model call), one Haiku answer through LiteLLM (spend rows), a file in the
#    shared bucket and one in the workspace, a Code page project whose own settings are trusted (code-state), a file
#    in the sandbox's home (terminal-home), a portal session (its cookie kept).
# 3. record: the project's containers, volumes and their mount points; the keys of Open WebUI's chats, users and
#    files and of LiteLLM's keys and spend rows; .env; the ports; the manifest's id and link scheme.
# 4. update: the throwaway's own update helper (its bin/bedrock-now-helper, in the foreground as tests/e2e/lib.sh runs
#    it) picks up an Update now request (.state/requests/req-<nonce>.json, as the portal writes it).
# 5. check: the release updated to; every step the update's log says is done on Home's card (the helper's status), in
#    order with its time; the folder where it was; no container lost (one the new release adds is said), the same
#    volumes and mount points; every key recorded still there; .env with nothing removed or changed; the same ports;
#    the session from before still signed in; the chat, the shared file, the workspace file and the sandbox's home file there, by content; the Code page
#    project's record and its trust (state, hash, when) as before; the login page, Home and the manifest say DevOS ADE
#    and have no bedrock-now outside the internal names (tests/brand_check.py --stdin); the manifest's id and link
#    scheme as before (the same installed app); ./stack test passes; with --real-github, origin moved to the new name
#    and the update check answering.
# Results: tests/e2e/out/upgrade/results.tsv (and logs/). The throwaway is removed at the end unless --keep.
#
# THE MOVE FROM bedrock-now TO devos-ade (JON-807, lib/migrate.sh): the same run, but from an install whose project is the
# OLD name, in a folder named like the old one, up to this checkout — and the checks are those of the move:
#
#   tests/e2e/upgrade.sh --migrate --aws-env FILE [--from v0.44.4 | v0.38.0] [--then rollback | remove-old] [--keep]
#       the real names: project bedrock-now, host bedrock-now.localhost, then devos-ade. REFUSES on a host where a live
#       bedrock-now or devos-ade install exists (containers, volumes, ~/bedrock-now, ~/devos-ade): run it on the Linux test host.
#   tests/e2e/upgrade.sh --migrate-pair NEWPROJECT --project OLDPROJECT --aws-env FILE ...
#       the test-only name pair (bne2e-…; default bne2e-mig-old -> bne2e-mig-new): lib/migrate.sh takes the pair from
#       MG_TEST_OLD_PROJECT / MG_TEST_NEW_PROJECT with the testing switch on, so it runs beside a live install. The old
#       HOST names (the 308 checks) are the real ones either way: Caddy answers them for any Host header.
#   Run it for --from v0.44.4 AND --from v0.38.0 (the owner's version); a hand-built layout like the owner's is added to the
#   seeded install either way: a partial MLX download (blobs + relative links), LM Studio's records, an `lms import` link,
#   a Code page session record. Asserted: the seeded data; the new hostname answering and the old one's 308 (GET, HEAD,
#   POST, PUT, DELETE; path and query kept; sockets refused; no cookie); the old origin refused as an Origin on the new
#   host; the seeded Open WebUI chat still the user's (same email, no second user); the backup volumes kept and equal;
#   .env.pre-devos-ade; the folder moved by rename (same inode under .state/mlx/hf), the old name a link; relative links
#   unchanged, absolute ones rewritten, no old path left; byte-identical sample files; ports unchanged. --then rollback runs
#   ./stack migrate --rollback and starts the old project from the old code; --then remove-old runs --remove-old --yes.
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC2034  # AVOID_PORTS: read by lib.sh's pick_port
AVOID_PORTS=" 80 443 3000 3009 4000 8080 8081 8090 8765 8800 "
BUDGETS="BUDGET_CLAUDE_CODE=0.04 BUDGET_OPENWEBUI=0.04 BUDGET_SETUP=0.02"
NOTTY="$HERE/notty"
OLD_URL="https://github.com/JongoDB-Labs/bedrock-now.git"
NEW_URL="https://github.com/JongoDB-Labs/devos-ade.git"
PROJECT=bne2e-rebrand-up; FROM=v0.24.0; AWS_ENV_FILE=''; KEEP=0; REAL_GITHUB=0; TEARDOWN_ONLY=0
MIGRATE=0; NEWP=''; THEN=''; FROM_SET=0; PROJECT_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --aws-env) AWS_ENV_FILE="${2:?}"; shift 2 ;;
    --project) PROJECT="${2:?}"; PROJECT_SET=1; shift 2 ;;
    --from) FROM="${2:?}"; FROM_SET=1; shift 2 ;;
    --migrate) MIGRATE=default; shift ;;
    --migrate-pair) MIGRATE=pair; NEWP="${2:?}"; shift 2 ;;
    --then) THEN="${2:?}"; case "$THEN" in rollback | remove-old) ;; *) echo "--then takes rollback or remove-old" >&2; exit 2 ;; esac; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --real-github) REAL_GITHUB=1; shift ;;
    --teardown) TEARDOWN_ONLY=1; shift ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (--help)" >&2; exit 2 ;;
  esac
done

. "$HERE/lib.sh"
. "$ROOT/lib/ports.sh"   # port_in_use
OLDHOST_LEGACY=bedrock-now.localhost   # the old default host: what lib/migrate.sh and caddy/legacy-hosts.caddy move away from
if [ "$MIGRATE" != 0 ]; then
  [ "$FROM_SET" = 1 ] || FROM=v0.44.4
  if [ "$MIGRATE" = default ]; then
    PROJECT=bedrock-now; NEWP=devos-ade; HOST="$OLDHOST_LEGACY"; NEWHOST=devos-ade.localhost
    valid_project() { [ "$1" = bedrock-now ]; }   # (this mode alone may name the real project)
  else
    [ "$PROJECT_SET" = 1 ] || PROJECT=bne2e-mig-old
    [ -n "$NEWP" ] && [ "$NEWP" != "$PROJECT" ] && valid_project "$NEWP" || die "--migrate-pair NEW: bne2e-<letters, digits, -> and not the old project (never a real install's)"
    HOST="$PROJECT.localhost"; NEWHOST="$NEWP.localhost"
    HELPER_KNOBS="$HELPER_KNOBS DEVOS_ADE_TESTING=1 BEDROCK_NOW_TESTING=1 MG_TEST_OLD_PROJECT=$PROJECT MG_TEST_NEW_PROJECT=$NEWP"
    MIG_ENV="DEVOS_ADE_TESTING=1 BEDROCK_NOW_TESTING=1 MG_TEST_OLD_PROJECT=$PROJECT MG_TEST_NEW_PROJECT=$NEWP"
  fi
fi
valid_project "$PROJECT" || die "--project must be bne2e or bne2e-<letters, digits, ->: $PROJECT (never a real install's)"
OUT="$ROOT/tests/e2e/out/upgrade"; LOGS="$OUT/logs"; RESULTS="$OUT/results.tsv"
WORK="$ROOT/tests/e2e/work/$PROJECT"
[ "$MIGRATE" = 0 ] || WORK="$ROOT/tests/e2e/work/$PROJECT-mig/bedrock-now"   # (the folder is named like an old install's: the move renames it)
mkdir -p "$(dirname "$WORK")" "$LOGS"
STACK="$(cd "$(dirname "$WORK")" && pwd -P)/$(basename "$WORK")"
[ "$MIGRATE" != 0 ] || HOST="$PROJECT.localhost"
command -v docker >/dev/null && docker info >/dev/null 2>&1 || die "Docker is required, and its daemon running"
if [ "$TEARDOWN_ONLY" = 1 ]; then teardown_only; exit 0; fi
[ -n "$AWS_ENV_FILE" ] || die "--aws-env FILE is required (only its AWS_* lines are read)"
load_aws_file "$AWS_ENV_FILE"
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || die "no AWS key in $AWS_ENV_FILE"
git -C "$ROOT" rev-parse -q --verify "refs/tags/$FROM" >/dev/null || die "no tag $FROM in this checkout"
: > "$RESULTS"; START_TS="$(now)"; HELPER_PID=''

st() { # st [--aws] ARGS... — the throwaway's ./stack, clean environment, no terminal
  [ "$MIGRATE" != 0 ] || [ "$(get_env COMPOSE_PROJECT_NAME)" = "$PROJECT" ] || { echo "xx  throwaway .env does not name project $PROJECT" >&2; return 99; }
  if [ "${1:-}" = --aws ]; then
    shift
    ( export AWS_REGION_NAME="${AWS_REGION_NAME:-us-east-1}" COMPOSE_PROJECT_NAME="$PROJECT"
      clean_env AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION_NAME COMPOSE_PROJECT_NAME
      cd "$STACK" && exec "$NOTTY" "$STACK/stack" "$@" </dev/null )
  else ( clean_env ${MIG_ENV:+$(printf '%s\n' $MIG_ENV | sed 's/=.*//')}; [ -z "${MIG_ENV:-}" ] || export $MIG_ENV
         cd "$STACK" && exec "$NOTTY" "$STACK/stack" "$@" </dev/null ); fi
}
# migrate_teardown — what the move made: the new project (containers, volumes, images, networks), its folder, the old folder's link
migrate_teardown() {
  local nstack="$STACK" nproj="$PROJECT" img
  [ "$nproj" = "$NEWP" ] && [ -f "$nstack/.bedrock-now-e2e" ] || return 0
  say "teardown: project $nproj (the move's)"
  ( cd "$nstack" && docker compose -p "$nproj" down -v --remove-orphans >/dev/null 2>&1 ) || true
  docker volume ls -q | grep -E "^${nproj}_" | xargs -r docker volume rm >/dev/null 2>&1 || true
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E "^${nproj}/" | xargs -r docker image rm >/dev/null 2>&1 || true
  docker network ls --format '{{.Name}}' | grep -E "^${nproj}_" | xargs -r docker network rm >/dev/null 2>&1 || true
  [ ! -L "$OLD_STACK" ] || rm -f "$OLD_STACK"
  chmod -R u+rwX "$nstack" 2>/dev/null; rm -rf "$nstack"
  STACK="$OLD_STACK"; PROJECT="$OLD_PROJECT"   # (the ordinary teardown now removes the backup volumes of the old project)
}
check() { # check ID OK MESSAGE — records PASS when OK is 0
  if [ "$2" = 0 ]; then record upgrade "$1" PASS "$(( $(now) - START_TS ))" "$3"; else record upgrade "$1" FAIL "$(( $(now) - START_TS ))" "$3"; fi
}
finish() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [ -z "$HELPER_PID" ] || e2e_helper_stop
  if [ "$KEEP" = 0 ] && [ "$MIGRATE" != 0 ] && [ -n "${OLD_STACK:-}" ]; then migrate_teardown; fi
  if [ "$KEEP" = 0 ]; then teardown; else say "kept: tests/e2e/upgrade.sh --teardown --project $PROJECT removes it"; fi
  awk -F'\t' '$3 == "FAIL" { f++ } END { printf "%d checks, %d failed (%s)\n", NR, f + 0, FILENAME }' "$RESULTS" >&2
  exit "$rc"
}
trap finish EXIT
trap 'warn "interrupted"; exit 130' INT TERM HUP

# portal URL and curl with the session kept in $OUT/jar
pp() { get_env PORTAL_PORT; }
pcurl() { curl -sS -m 30 --resolve "$HOST:$(pp):127.0.0.1" -b "$OUT/jar" -c "$OUT/jar" "$@"; }
purl() { printf 'http://%s:%s%s\n' "$HOST" "$(pp)" "$1"; }
# owui PY — Python in the throwaway's Open WebUI container, signed in as its admin the way Caddy signs the portal's
# session in (the trusted header with the admin's email; Open WebUI ignores the password then): TOKEN and
# api(method, path, body, token) are defined for PY
owui() {
  ( E2E_OWUI_EMAIL="$(get_env OPENWEBUI_ADMIN_EMAIL)"; export E2E_OWUI_EMAIL
    cd "$STACK" && docker compose -p "$PROJECT" exec -T -e E2E_OWUI_EMAIL open-webui python3 -c "
import json, os, urllib.request
def api(method, path, body=None, token=None, extra=None):
    req = urllib.request.Request('http://127.0.0.1:8080' + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json', **(extra or {}), **({'Authorization': 'Bearer ' + token} if token else {})})
    return json.load(urllib.request.urlopen(req, timeout=30))
TOKEN = api('POST', '/api/v1/auths/signin', {'email': '', 'password': ''}, extra={'X-Portal-User': os.environ['E2E_OWUI_EMAIL']})['token']
$1" ) </dev/null
}
# cexec SERVICE ARGS... — docker exec in the throwaway's container of SERVICE (an overlay's service too)
cexec() {
  local s="$1" id; shift
  id="$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$s" | head -n 1)"
  [ -n "$id" ] || { echo "no $s container in project $PROJECT" >&2; return 1; }
  docker exec -i "$id" "$@"
}
# codeapi METHOD PATH [JSON] — the Code page's own API, asked in its container as the main Caddy asks it (its secret
# header, its own origin); prints the answer, fails on an HTTP error
codeapi() {
  cexec code node -e '
const http = require("http"); const [m, p, b] = process.argv.slice(1); const port = Number(process.env.CODE_PORT || 8095);
const req = http.request({ host: "127.0.0.1", port, method: m, path: p, headers: { "X-Bn-Code-Proxy": process.env.CODE_PROXY_SECRET,
  Origin: `http://127.0.0.1:${port}`, "Content-Type": "application/json" } }, (res) => {
  let d = ""; res.on("data", (c) => { d += c; }); res.on("end", () => { process.stdout.write(d); process.exitCode = res.statusCode < 300 ? 0 : 1; });
});
req.on("error", (e) => { console.error(e.message); process.exitCode = 2; });
if (b) req.write(b);
req.end();' "$@" </dev/null
}
# code_project ID -> the project's record and its settings' trust (state, hash, when), as the Code page shows them
code_project() {
  { codeapi GET /api/projects && echo && codeapi GET "/api/projects/$1/settings"; } | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
projects, settings = json.loads(lines[0]), json.loads(lines[1])
rec = [p for p in projects["projects"] if p.get("id") == sys.argv[1]]
print(json.dumps({"project": {k: rec[0].get(k) for k in ("id", "name", "root")} if rec else None,
                  "trust": {k: settings.get(k) for k in ("state", "hash", "trustedAt")}}, sort_keys=True))' "$1"
}
# psql_keys DB TABLE COLUMN -> the column's values, sorted (the database's own rows, read in the postgres container)
psql_keys() {
  ( cd "$STACK" && docker compose -p "$PROJECT" exec -T postgres psql -U postgres -d "$1" -Atc "SELECT \"$3\" FROM \"$2\" ORDER BY 1" ) </dev/null 2>/dev/null
}
KEYS="openwebui:chat:id openwebui:user:id openwebui:function:id litellm:LiteLLM_VerificationToken:token litellm:LiteLLM_SpendLogs:request_id"
snapshot() { # snapshot DIR — what must survive the update
  local d="$1" k; mkdir -p "$d"
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.service"}}' | sort > "$d/services"
  docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" | sort > "$d/volumes"
  docker volume ls -q | grep -xF "${PROJECT}_bedrock-now-owner" >> "$d/volumes" || true
  while read -r k; do docker volume inspect --format '{{.Name}} {{.Mountpoint}}' "$k"; done < "$d/volumes" > "$d/mounts"
  for k in $KEYS; do psql_keys "${k%%:*}" "$(printf '%s' "$k" | cut -d: -f2)" "${k##*:}" > "$d/keys-${k//:/-}"; done
  sort "$STACK/.env" > "$d/env"
  for k in PORTAL_PORT LITELLM_PORT SHARED_MCP_PORT PORTAL_HOST COMPOSE_PROJECT_NAME TERMINAL_WORKSPACE; do printf '%s=%s\n' "$k" "$(get_env "$k")"; done > "$d/addresses"
  pcurl "$(purl /manifest.webmanifest)" > "$d/manifest.json" || true
  git -C "$STACK" describe --tags --always > "$d/version" 2>/dev/null || true
}


# old_req METHOD HOST PATH [HEADER...] -> "CODE LOCATION SETCOOKIE-COUNT" of the throwaway's Caddy asked for HOST (any Host header
# is answered by the same listener; the body is sent as it would be, nothing is followed)
old_req() {
  local m="$1" h="$2" path="$3" hdr="$OUT/old-req.hdr" code; shift 3
  local args=(); [ "$m" != HEAD ] || args=(-I)
  [ "$m" = HEAD ] || args+=(-X "$m")
  case "$m" in POST | PUT | DELETE) args+=(--data 'k=v') ;; esac
  code="$(curl -sS -m 20 -o /dev/null -D "$hdr" -w '%{http_code}' --resolve "$h:$(pp):127.0.0.1" "${args[@]}" "$@" "http://$h:$(pp)$path" 2>/dev/null || echo 000)"
  printf '%s %s %s\n' "$code" "$(tr -d '\r' < "$hdr" | sed -n 's/^[Ll]ocation: //p' | head -1)" "$(grep -ci '^set-cookie:' "$hdr" || true)"
}
migrate_checks() {
  local m r want h sub vol n k ok left l t a b
  # --- the old hostname: 308 for every method, path and query kept, no cookie
  for m in GET HEAD POST PUT DELETE; do
    r="$(old_req "$m" "$OLDHOST_LEGACY" "/some/path?a=1&b=two")"
    want="308 http://$NEWHOST:$(pp)/some/path?a=1&b=two 0"
    check "old-host-$m" "$([ "$r" = "$want" ] && echo 0 || echo 1)" "$m $OLDHOST_LEGACY -> '$r' (want '$want')"
  done
  for sub in chat admin files code terminal git; do
    r="$(old_req GET "$sub.$OLDHOST_LEGACY" "/x?y=1")"; want="308 http://$sub.$NEWHOST:$(pp)/x?y=1 0"
    check "old-host-$sub" "$([ "$r" = "$want" ] && echo 0 || echo 1)" "$sub.$OLDHOST_LEGACY -> '$r'"
  done
  r="$(old_req POST "chat.$OLDHOST_LEGACY" "/api/v1/chats/new" -H 'Content-Type: application/json')"
  check old-host-api-post-keeps-method "$([ "${r%% *}" = 308 ] && echo 0 || echo 1)" "POST to an old API path: $r"
  # --- WebSockets to the old terminal and code hosts: refused, never upgraded or redirected
  for sub in terminal code; do
    r="$(old_req GET "$sub.$OLDHOST_LEGACY" "/ws" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')"
    check "old-host-websocket-$sub" "$([ "${r%% *}" = 426 ] && ! grep -qi '^sec-websocket-accept' "$OUT/old-req.hdr" && [ "${r##* }" = 0 ] && echo 0 || echo 1)" "$sub upgrade on the old host: $r"
  done
  # --- the old origin is never an acceptable Origin on the new host (a state-changing request)
  for m in POST PUT DELETE; do
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' --resolve "$HOST:$(pp):127.0.0.1" -X "$m" -H "Origin: http://$OLDHOST_LEGACY:$(pp)" \
      -H 'X-Requested-With: devos-ade' -b "$OUT/jar" --data '{}' "http://$HOST:$(pp)/api/update/check" 2>/dev/null || echo 000)"
    check "old-origin-refused-$m" "$(case "$code" in 400 | 403) echo 0 ;; *) echo 1 ;; esac)" "$m on the new host with Origin http://$OLDHOST_LEGACY: $code (want 400 or 403)"
  done
  # --- the seeded Open WebUI chat is still the user's: the same email signs in, sees it, and no second account came
  got="$(owui "print([u.get('email') for u in api('GET', '/api/v1/users/all', None, TOKEN).get('users', [])])" 2>/dev/null)"
  check no-second-user "$(case "$got" in *admin@devos-ade.local*) echo 1 ;; *admin@bedrock-now.local*) echo 0 ;; *) echo 1 ;; esac)" "Open WebUI users: $got"
  # --- the backup: every old volume is still there, untouched, with the marker's word that each copy was verified
  : > "$OUT/old-volumes-missing"
  while read -r vol; do
    [ -n "$vol" ] || continue
    case "$vol" in *-owner) continue ;; esac
    docker volume inspect "$vol" >/dev/null 2>&1 || echo "$vol" >> "$OUT/old-volumes-missing"
  done < "$OUT/before/volumes"
  check backup-volumes-kept "$([ ! -s "$OUT/old-volumes-missing" ] && echo 0 || echo 1)" "missing old volumes: $(tr '\n' ' ' < "$OUT/old-volumes-missing")"
  img="$(docker inspect --format '{{.Config.Image}}' "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=postgres | head -1)" 2>/dev/null)"
  a="$(docker run --rm --network none -v "${OLD_PROJECT}_pgdata:/v:ro" --entrypoint cat "$img" /v/PG_VERSION 2>/dev/null)"
  b="$(docker run --rm --network none -v "${PROJECT}_pgdata:/v:ro" --entrypoint cat "$img" /v/PG_VERSION 2>/dev/null)"
  check backup-pgdata-equal "$([ -n "$a" ] && [ "$a" = "$b" ] && echo 0 || echo 1)" "PG_VERSION old '$a', new '$b'"
  a="$(docker run --rm --network none -v "${OLD_PROJECT}_owui:/v:ro" --entrypoint sh "$img" -c 'cd /v && find . -type f -exec sha256sum {} + | sort -k2 | sha256sum')"
  sleep 3; b="$(docker run --rm --network none -v "${OLD_PROJECT}_owui:/v:ro" --entrypoint sh "$img" -c 'cd /v && find . -type f -exec sha256sum {} + | sort -k2 | sha256sum')"
  check backup-volume-untouched "$([ -n "$a" ] && [ "$a" = "$b" ] && echo 0 || echo 1)" "the old Open WebUI volume reads the same twice, while the new stack runs: $a / $b"
  check backup-env "$([ -f "$STACK/.env.pre-devos-ade" ] && echo 0 || echo 1)" ".env.pre-devos-ade"
  check backup-images "$([ -n "$(docker image ls -q "$OLD_PROJECT/portal:local")" ] && echo 0 || echo 1)" "the old images $OLD_PROJECT/portal:local kept"
  st migrate > "$LOGS/migrate-status.log" 2>&1
  check backup-said "$(grep -q -- '--remove-old' "$LOGS/migrate-status.log" && grep -q "moved to" "$LOGS/migrate-status.log" && echo 0 || echo 1)" "$(tr '\n' ' ' < "$LOGS/migrate-status.log" | cut -c1-200)"
  check marker-complete "$(grep -qx 'status=complete' "$STACK/.state/migrate/marker" && echo 0 || echo 1)" "$(tr '\n' ' ' < "$STACK/.state/migrate/marker" 2>/dev/null | cut -c1-160)"
  # --- the layout like the owner's: moved by rename, byte-identical, relative links as they were, absolute ones rewritten
  ST="$STACK/.state"
  check mlx-moved-not-copied "$([ "$(ls -di "$ST/mlx/hf" | cut -d' ' -f1)" = "$(cat "$OUT/inode-before")" ] && echo 0 || echo 1)" "inode of .state/mlx/hf: before $(cat "$OUT/inode-before"), after $(ls -di "$ST/mlx/hf" | cut -d' ' -f1)"
  ( cd "$ST" && find mlx/hf -type f -exec cksum {} + | LC_ALL=C sort -k3 ) > "$OUT/layout-after.cksum"
  check sample-files-identical "$(cmp -s "$OUT/layout-before.cksum" "$OUT/layout-after.cksum" && echo 0 || echo 1)" "$(wc -l < "$OUT/layout-after.cksum" | tr -d ' ') files under .state/mlx/hf"
  ( cd "$ST/mlx/hf/hub/models--e2e--partial/snapshots/rev1" && readlink config.json model.safetensors ) > "$OUT/links-after"
  check relative-links-unchanged "$(cmp -s "$OUT/links-before" "$OUT/links-after" && echo 0 || echo 1)" "$(tr '\n' ' ' < "$OUT/links-after")"
  t="$(readlink "$ST/runtimes/lmstudio/home/.lmstudio/models/e2e/m.gguf")"
  check absolute-link-rewritten "$([ "$t" = "$ST/mlx/hf/hub/models--e2e--partial/blobs/bbbb2222" ] && [ -e "$ST/runtimes/lmstudio/home/.lmstudio/models/e2e/m.gguf" ] && echo 0 || echo 1)" "lms import link -> $t"
  check lmstudio-records "$(grep -q "^$STACK/.state/runtimes/lmstudio/home/.lmstudio/llmster/" "$ST/runtimes/lmstudio/llmster.run" && grep -q "$STACK/.state/runtimes/lmstudio/home\"" "$ST/runtimes/lmstudio/home/.lmstudio/.internal/llmster-install-location.json" && [ "$(cat "$ST/runtimes/lmstudio/home/.lmstudio-home-pointer")" = "$STACK/.state/runtimes/lmstudio/home/.lmstudio" ] && echo 0 || echo 1)" "llmster.run, install-location.json and the home pointer name $STACK"
  check session-record "$(grep -q "$STACK/.state/sessions/e2e" "$ST/sessions/e2e.json" && echo 0 || echo 1)" "$(cat "$ST/sessions/e2e.json")"
  left="$(grep -rIlF -- "$OLD_STACK" "$STACK" --exclude-dir=.git --exclude-dir=backups --exclude-dir=migrate --exclude=.env.pre-devos-ade 2>/dev/null | head -5 | tr '\n' ' ')"
  while IFS= read -r l; do t="$(readlink "$l")"; case "$t" in "$OLD_STACK" | "$OLD_STACK"/*) left="$left link:$l" ;; esac; done <<EOF
$(find "$STACK" -path "$STACK/.git" -prune -o -type l -print 2>/dev/null)
EOF
  check no-old-path-left "$([ -z "$left" ] && echo 0 || echo 1)" "files or links still naming $OLD_STACK: ${left:-none}"
  # --- then: the way back, or the end of the backup
  case "$THEN" in
    remove-old)
      st migrate --remove-old --yes > "$LOGS/remove-old.log" 2>&1
      check remove-old-lists "$(grep -q "${OLD_PROJECT}_pgdata" "$LOGS/remove-old.log" && echo 0 || echo 1)" "the list names the old volumes"
      left="$(docker volume ls -q | grep -E "^${OLD_PROJECT}_" | tr '\n' ' ')"
      check remove-old-removed "$([ -z "$left" ] && [ ! -f "$STACK/.env.pre-devos-ade" ] && echo 0 || echo 1)" "old volumes left: ${left:-none}"
      check remove-old-keeps-new "$([ -n "$(docker volume ls -q | grep -E "^${PROJECT}_pgdata$")" ] && [ "$(pcurl -o /dev/null -w '%{http_code}' "$(purl /caddy-health)")" != 000 ] && echo 0 || echo 1)" "the new project's volumes and the portal are still there" ;;
    rollback)
      pcurl -o /dev/null "$(purl /)" || true
      st migrate --rollback --yes > "$LOGS/rollback.log" 2>&1; n=$?
      check rollback-ran "$n" "./stack migrate --rollback: exit $n"
      check rollback-folder "$([ -f "$OLD_STACK/.env" ] && [ ! -L "$OLD_STACK" ] && [ ! -e "$STACK" ] && echo 0 || echo 1)" "the install is back at $OLD_STACK"
      STACK="$OLD_STACK"; PROJECT="$OLD_PROJECT"; HOST="$OLD_HOST"
      check rollback-volumes "$([ -z "$(comm -23 <(sort "$OUT/before/volumes") <(docker volume ls -q | sort))" ] && echo 0 || echo 1)" "every old volume still there"
      git -C "$STACK" -c advice.detachedHead=false checkout -q "$FROM" 2>/dev/null; st up --yes > "$LOGS/rollback-up.log" 2>&1; n=$?
      check rollback-old-project-runs "$n" "the old code starts the old project again: exit $n"
      got="$(owui "print(api('GET', '/api/v1/chats/$CHAT_ID', None, TOKEN)['title'])" 2>/dev/null)"
      check rollback-chat-kept "$([ "$got" = e2e-upgrade ] && echo 0 || echo 1)" "the chat on the old project: ${got:-gone}" ;;
  esac
}

# --- 1. stage and set up the release before ---
if [ "$MIGRATE" = default ]; then   # the real names: never beside a live install of either
  live="$( { docker ps -aq --filter label=com.docker.compose.project=bedrock-now; docker ps -aq --filter label=com.docker.compose.project=devos-ade
             docker volume ls -q | grep -E '^(bedrock-now|devos-ade)_' || true
             ls -d "$HOME/bedrock-now" "$HOME/devos-ade" 2>/dev/null || true; } | tr '\n' ' ')"
  [ -z "$live" ] || die "--migrate refuses: a live install of bedrock-now or devos-ade is here ($live). Run it on a host without one (the Linux test host), or use --migrate-pair for the test-only name pair. Nothing was changed."
fi
claim_project
# shellcheck disable=SC2034  # (OWNED: read by teardown)
[ "$OWN_STATE" != ours ] || { warn "project $PROJECT: $OWN_WHY — removing those leftovers first"; teardown; OWNED=1; }
if [ -e "$STACK" ]; then
  [ -f "$STACK/.bedrock-now-e2e" ] || die "$STACK exists and was not created by this suite — nothing was changed"
  chmod -R u+rwX "$STACK"; rm -rf "$STACK"
fi
say "staging $FROM in $STACK"
if [ "$REAL_GITHUB" = 1 ]; then
  ( umask 022; git clone --quiet "$OLD_URL" "$STACK" ) || die "git clone of $OLD_URL failed"
  TO="$(git -C "$STACK" -c versionsort.suffix=- tag -l 'v[0-9]*' --sort=-v:refname | grep -v -- - | sed -n 1p)"
else
  ( umask 022; git clone --quiet --no-hardlinks "$ROOT" "$STACK" ) || die "git clone failed"
  # the release to update to: this checkout's HEAD and working tree, tagged v0.25.0 in the throwaway only
  git -C "$STACK" checkout -q -b e2e-next
  if ! (cd "$ROOT" && git diff --quiet HEAD); then
    ( cd "$ROOT" && git diff HEAD --binary ) | ( umask 022; git -C "$STACK" apply --whitespace=nowarn ) || die "the working tree's changes do not apply"
  fi
  ( cd "$ROOT" && git ls-files --others --exclude-standard -z ) | while IFS= read -r -d '' f; do
    case "$f" in tests/e2e/out/* | tests/e2e/work/*) continue ;; esac
    ( umask 022; mkdir -p "$STACK/$(dirname "$f")" && cp -p "$ROOT/$f" "$STACK/$f" ) || exit 1
  done || die "could not copy the untracked files"
  git -C "$STACK" add -A
  git -C "$STACK" -c user.name=e2e -c user.email=e2e@example.invalid commit -q --allow-empty -m "e2e: the release to update to"
  # (a number no tag of this checkout has, nor ever fetches: v0.25.0 until that release exists, then the patch
  # after the newest release here — origin's tags never collide with it)
  TO="$(git -C "$ROOT" -c versionsort.suffix=- tag -l 'v[0-9]*' --sort=-v:refname | grep -v -- - | sed -n 1p)"
  case "$TO" in v0.[0-9].* | v0.1[0-9].* | v0.2[0-4].* | '') TO=v0.25.0 ;; *) TO="${TO%.*}.$(( ${TO##*.} + 1 ))" ;; esac
  git -C "$STACK" -c user.name=e2e -c user.email=e2e@example.invalid tag -a "$TO" -m "$TO (e2e)" e2e-next
fi
[ -n "$TO" ] || die "no release to update to"
git -C "$STACK" -c advice.detachedHead=false checkout -q "$FROM" || die "cannot check out $FROM"
: > "$STACK/.bedrock-now-e2e"; printf '/.bedrock-now-e2e\n' >> "$STACK/.git/info/exclude"
cp "$STACK/.env.example" "$STACK/.env"; chmod 600 "$STACK/.env"
pick_port P 18580; pick_port L 14580; pick_port M 18965
if [ "$MIGRATE" = default ]; then : ; else set_env COMPOSE_PROJECT_NAME "$PROJECT"; set_env PORTAL_HOST "$HOST"; fi   # (the old default: neither is in .env)
set_env PORTAL_PORT "$P"
set_env LITELLM_PORT "$L"; set_env SHARED_MCP_PORT "$M"
# the email: the owner's own default in the move (every store is keyed by it); an address of the suite otherwise
if [ "$MIGRATE" != 0 ]; then set_env OPENWEBUI_ADMIN_EMAIL "admin@bedrock-now.local"; else set_env OPENWEBUI_ADMIN_EMAIL "e2e-admin@example.com"; fi
for kv in $BUDGETS; do set_env "${kv%%=*}" "${kv#*=}"; done
set_env PORTAL_PASSWORD "$(openssl rand -hex 10)"
seed_cheap_default   # (new sessions on Haiku: no flow falls back to a dearer model — the no-opus-spend check)
WS="$(terminal_workspace_dir)"; ( umask 077; mkdir -p "$WS" ) && : > "$WS/.bedrock-now-e2e"; set_env TERMINAL_WORKSPACE "$WS"
( umask 022; mkdir -p "$STACK/.state/update-check" ); chmod 700 "$STACK/.state"; : > "$STACK/.state/portal-password-shown"
# no GitHub call from the portal before the update (its check counts as done; --real-github asks for one at the end)
printf '{"checked_at": "%s", "error": null}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$STACK/.state/update-check/latest.json"
chmod 644 "$STACK/.state/update-check/latest.json"
say "setup at $FROM (log: $LOGS/setup.log)"
st --aws setup --yes > "$LOGS/setup.log" 2>&1; rc=$?; redact "$LOGS/setup.log"
check setup-before "$rc" "./stack setup at $FROM: exit $rc"
[ "$rc" = 0 ] || die "setup failed — see $LOGS/setup.log"

# --- 2. seed ---
get_env PORTAL_PASSWORD > "$OUT/pw"   # (from a file: never on a command line)
pcurl -o /dev/null -w '%{http_code}' -H "Origin: $(purl '')" --data-urlencode "password@$OUT/pw" "$(purl /login)" > "$OUT/login.code"
rm -f "$OUT/pw"
check signed-in "$([ "$(cat "$OUT/login.code")" = 303 ] && echo 0 || echo 1)" "the portal's sign-in: $(cat "$OUT/login.code")"
CHAT_ID="$(owui "print(api('POST', '/api/v1/chats/new', {'chat': {'title': 'e2e-upgrade', 'messages': []}}, TOKEN)['id'])" 2> "$LOGS/owui-seed.log")"
check chat-made "$([ -n "$CHAT_ID" ] && echo 0 || echo 1)" "Open WebUI chat ${CHAT_ID:-not made (log $LOGS/owui-seed.log)}"
code="$(curl -sS -m 60 -o "$LOGS/haiku.json" -w '%{http_code}' "http://127.0.0.1:$L/v1/chat/completions" \
  -H "Authorization: Bearer $(get_env LITELLM_KEY_CLAUDE_CODE)" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$(get_env CLAUDE_BEDROCK_HAIKU_MODEL)\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"Say ok\"}]}" || true)"
check haiku-answer "$([ "$code" = 200 ] && echo 0 || echo 1)" "a Haiku answer through LiteLLM: HTTP $code"
CANARY="shared/e2e-upgrade/canary.txt"; CANARY_V="kept-$(openssl rand -hex 4)"
( clean_env E2E_CANARY; export E2E_CANARY="$CANARY_V"; cd "$STACK" &&
  docker compose -p "$PROJECT" -f compose.yaml run --rm --no-deps -T -e E2E_CANARY --entrypoint /bin/sh rustfs-init -c \
    'printf %s "$E2E_CANARY" > /tmp/c && aws --endpoint-url http://rustfs:9000 s3 cp --only-show-errors /tmp/c s3://'"$CANARY" ) </dev/null > "$LOGS/canary.log" 2>&1
printf 'kept\n' > "$WS/e2e-upgrade.txt"
# a Code page project (a folder of the workspace) whose own settings are trusted — the record and the trust in the
# code container's code-state volume — and a file in the sandbox's home (the terminal-home volume)
PROJECT_ID="$(codeapi POST /api/projects '{"kind": "new", "folder": "e2e-upgrade-project"}' 2> "$LOGS/code-seed.log" |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["project"]["id"])' 2>> "$LOGS/code-seed.log")"
if [ -n "$PROJECT_ID" ]; then
  mkdir -p "$WS/e2e-upgrade-project/.claude"
  printf '{"permissions": {"allow": ["Bash(ls:*)"]}}\n' > "$WS/e2e-upgrade-project/.claude/settings.json"
  hash="$(codeapi GET "/api/projects/$PROJECT_ID/settings" 2>> "$LOGS/code-seed.log" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("hash") or "")')"
  codeapi POST "/api/projects/$PROJECT_ID/trust" "{\"hash\": \"$hash\"}" > "$LOGS/code-trust.json" 2>> "$LOGS/code-seed.log"
fi
code_project "${PROJECT_ID:-none}" > "$OUT/code-project-before.json" 2>> "$LOGS/code-seed.log"
check code-project-made "$(grep -q '"state": "trusted"' "$OUT/code-project-before.json" && echo 0 || echo 1)" "$(cat "$OUT/code-project-before.json" 2>/dev/null)"
HOME_V="kept-$(openssl rand -hex 4)"
cexec terminal sh -c 'printf %s "$1" > "$HOME/.e2e-upgrade-home"' sh "$HOME_V" 2>> "$LOGS/code-seed.log"
check home-file-made "$([ "$(cexec terminal cat /home/claude/.e2e-upgrade-home 2>/dev/null)" = "$HOME_V" ] && echo 0 || echo 1)" "a file in the sandbox's home"
# the owner's kind of layout (the move only): a partial MLX download with relative links, LM Studio's records, an `lms import`
# link, a Code page session record — all under .state, with absolute paths into this folder where the real ones have them
if [ "$MIGRATE" != 0 ]; then
  ST="$STACK/.state"; HF="$ST/mlx/hf/hub/models--e2e--partial"
  mkdir -p "$HF/blobs" "$HF/snapshots/rev1" "$ST/runtimes/lmstudio/home/.lmstudio/.internal" "$ST/runtimes/lmstudio/home/.lmstudio/models/e2e" "$ST/sessions"
  head -c 300000 /dev/urandom > "$HF/blobs/aaaa1111.incomplete"; head -c 5000 /dev/urandom > "$HF/blobs/bbbb2222"
  ln -s ../../blobs/bbbb2222 "$HF/snapshots/rev1/config.json"; ln -s ../../blobs/aaaa1111.incomplete "$HF/snapshots/rev1/model.safetensors"
  printf '%s/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster\t%s/.state/runtimes/lmstudio/home\t.\n' "$STACK" "$STACK" > "$ST/runtimes/lmstudio/llmster.run"
  printf '{"path":"%s/.state/runtimes/lmstudio/home/.lmstudio/llmster/0.0.25-1/bin/llmster","cwd":"%s/.state/runtimes/lmstudio/home"}\n' "$STACK" "$STACK" > "$ST/runtimes/lmstudio/home/.lmstudio/.internal/llmster-install-location.json"
  printf '%s/.state/runtimes/lmstudio/home/.lmstudio\n' "$STACK" > "$ST/runtimes/lmstudio/home/.lmstudio-home-pointer"
  ln -s "$HF/blobs/bbbb2222" "$ST/runtimes/lmstudio/home/.lmstudio/models/e2e/m.gguf"
  printf '{"cwd":"%s/.state/sessions/e2e","project":"e2e-upgrade-project"}\n' "$STACK" > "$ST/sessions/e2e.json"
  ( cd "$ST" && find mlx/hf -type f -exec cksum {} + | LC_ALL=C sort -k3 ) > "$OUT/layout-before.cksum"
  ( cd "$ST/mlx/hf/hub/models--e2e--partial/snapshots/rev1" && readlink config.json model.safetensors ) > "$OUT/links-before"
  ls -di "$ST/mlx/hf" | cut -d' ' -f1 > "$OUT/inode-before"
  for k in postgres; do :; done
fi
sleep 15   # (LiteLLM writes spend rows in batches)
snapshot "$OUT/before"

# --- 3. Update now: a request for the throwaway's own update helper ---
nonce="$(openssl rand -hex 16)"
mkdir -p "$STACK/.state/requests"
printf '{"action":"update","requested_at":%s,"nonce":"%s"}\n' "$(date +%s)" "$nonce" > "$STACK/.state/requests/req-$nonce.json"
say "Update now ($FROM -> $TO) through the update helper (log: $LOGS/helper.log)"
e2e_helper_start 2> "$LOGS/helper-start.log" || { check helper-started 1 "$(tail -n 2 "$LOGS/helper-start.log" | tr '\n' ' ')"; exit 1; }
for _ in $(seq 1 1800); do   # an update takes minutes (images are rebuilt); at most 30
  s="$(cat "$STACK/.state/status/helper-status.json" 2>/dev/null)"
  case "$s" in *'"action": "update"'*'"finished_at": '[0-9]*) break ;; esac
  sleep 1
done
e2e_helper_stop
cp "$STACK/.state/status/helper-status.json" "$LOGS/helper-status.json" 2>/dev/null || true
s="$(cat "$LOGS/helper-status.json" 2>/dev/null)"
case "$s" in *'"phase": "done"'*) check update-now 0 "the helper's update finished: $(printf '%s' "$s" | sed -n 's/.*"message": "\([^"]*\)".*/\1/p')" ;;
  *) check update-now 1 "the helper's update did not finish well: $s" ;; esac
# Home's progress card: every step the update's log says is done ("==> LABEL ready (T)", as lib/helper.sh _job_steps
# reads them) is in the helper's status — what Home lists — in that order and each with its time, and none is left
# running. A helper of this version or later (its log's lines carry their time, "20:02:40 ==> …") lists the whole job,
# from the backup to what's new; an older one — the helper of the version updated FROM runs the update — the steps
# after the log's last "update: N/4" line. The steps' table goes to $OUT/steps.tsv (label, time).
cp "$STACK/.state/helper/last-update.log" "$LOGS/update-job.log" 2>/dev/null; redact "$LOGS/update-job.log"
python3 - "$LOGS/update-job.log" "$LOGS/helper-status.json" "$OUT/steps.tsv" > "$OUT/steps.check" 2>&1 <<'PY'
import json, re, sys
STAMP = re.compile(r"^[0-2][0-9]:[0-5][0-9]:[0-5][0-9] ")
raw = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8", errors="replace")]
stamped = bool(raw) and all(STAMP.match(l) for l in raw if l.strip())
lines = [STAMP.sub("", l) for l in raw]
if stamped:
    start, cap = -1, 80
else:
    start, cap = max([i for i, l in enumerate(lines) if re.match(r"^==> (update: [1-4]/4|rollback: [1-3]/3)", l)], default=-1), 40
want = [(m.group(1), m.group(2)) for m in (re.match(r"^==> (.*) ready \((.*)\)$", l) for l in lines[start + 1:]) if m][:cap]
st = json.load(open(sys.argv[2]))
got = [(s["label"], s["took"]) for s in st.get("steps") or []]
assert want, "the update's log names no step"
assert got == want, f"Home lists {got}, the log says {want}"
assert not st.get("step"), f"a step left running: {st.get('step')}"
untimed = [l for l, t in got if not re.fullmatch(r"[0-9]{1,4}m[0-9]{2}s|[0-9]{1,4}s", t or "")]
assert not untimed, f"steps without their time: {untimed}"
if stamped:
    assert any(l == "Backup" for l, _ in got) and any(l.startswith("Smoke test") for l, _ in got), "the whole job's steps (the backup, the smoke test)"
with open(sys.argv[3], "w") as f:
    for l, t in got:
        f.write(f"{l}\t{t}\n")
print(f"{len(got)} steps on Home's card ({'the whole job, a stamped log' if stamped else 'after the last update: N/4 line, an older helper'}), each with its time: " + ", ".join(f"{l} {t}" for l, t in got))
PY
check home-card-steps "$?" "$(tail -n 1 "$OUT/steps.check")"

# --- 4. after ---
if [ "$MIGRATE" != 0 ]; then   # from here on it is the new project, in the new folder, on the new host (the old folder is a link)
  OLD_STACK="$STACK"; OLD_PROJECT="$PROJECT"; OLD_HOST="$HOST"
  STACK="$(dirname "$OLD_STACK")/devos-ade"; PROJECT="$NEWP"; HOST="$NEWHOST"
fi
snapshot "$OUT/after"
check version "$(grep -qx "$TO" "$OUT/after/version" && echo 0 || echo 1)" "installed $(cat "$OUT/after/version"), want $TO"
if [ "$MIGRATE" = 0 ]; then
  check same-folder "$([ "$(real_dir "$STACK")" = "$(cd "$WORK" && pwd -P)" ] && [ -f "$STACK/.env" ] && echo 0 || echo 1)" "still in $STACK"
else
  check folder-moved "$([ -f "$STACK/.env" ] && [ -L "$OLD_STACK" ] && [ "$(real_dir "$OLD_STACK")" = "$(real_dir "$STACK")" ] && echo 0 || echo 1)" "$OLD_STACK is a link to $STACK"
fi
# (the services: none lost; one the new release adds — v0.31.0's built-in SearXNG — is said)
lost="$(comm -23 "$OUT/before/services" "$OUT/after/services" | tr '\n' ' ')"; new="$(comm -13 "$OUT/before/services" "$OUT/after/services" | tr '\n' ' ')"
check same-services "$([ -z "$lost" ] && echo 0 || echo 1)" "lost: ${lost:-none}; added by the new release: ${new:-none}"
if [ "$MIGRATE" = 0 ]; then
for f in volumes mounts addresses; do
  check "same-$f" "$(cmp -s "$OUT/before/$f" "$OUT/after/$f" && echo 0 || echo 1)" "$(diff "$OUT/before/$f" "$OUT/after/$f" | head -5 | tr '\n' ' ')"
done
else
  # the volumes carry the new project's name (the sockets' and the owner marker's too); the mount points follow; the ports stay
  norm() { sed "s/^${OLD_PROJECT}_/${PROJECT}_/; s#/${OLD_PROJECT}_#/${PROJECT}_#g; s/bedrock-now-owner/devos-ade-owner/" "$1" | LC_ALL=C sort; }
  lostv="$(comm -23 <(norm "$OUT/before/volumes" | grep -v -- '-owner$') <(norm "$OUT/after/volumes" | grep -v -- '-owner$') | tr '\n' ' ')"
  check volumes-copied "$([ -z "$lostv" ] && echo 0 || echo 1)" "a volume of the old name without its new one: ${lostv:-none}"
  grep -E '^(PORTAL_PORT|LITELLM_PORT|SHARED_MCP_PORT|TERMINAL_WORKSPACE)=' "$OUT/before/addresses" > "$OUT/ports-before"
  grep -E '^(PORTAL_PORT|LITELLM_PORT|SHARED_MCP_PORT|TERMINAL_WORKSPACE)=' "$OUT/after/addresses" > "$OUT/ports-after"
  check ports-unchanged "$(cmp -s "$OUT/ports-before" "$OUT/ports-after" && echo 0 || echo 1)" "$(diff "$OUT/ports-before" "$OUT/ports-after" | head -3 | tr '\n' ' ')"
fi
for k in $KEYS; do
  f="keys-${k//:/-}"; n="$(wc -l < "$OUT/before/$f" | tr -d ' ')"
  gone="$(comm -23 "$OUT/before/$f" "$OUT/after/$f" | wc -l | tr -d ' ')"
  check "rows-$f" "$([ "$n" -gt 0 ] && [ "$gone" = 0 ] && echo 0 || echo 1)" "$n row(s) before, $gone gone"
done
removed="$(comm -23 "$OUT/before/env" "$OUT/after/env" | sed 's/=.*//' | tr '\n' ' ')"
added="$(comm -13 "$OUT/before/env" "$OUT/after/env" | sed 's/=.*//' | tr '\n' ' ')"
if [ "$MIGRATE" = 0 ]; then
check env-kept "$([ -z "$removed" ] && echo 0 || echo 1)" "removed or changed: ${removed:-none}; added: ${added:-none}"
code="$(pcurl -o /dev/null -w '%{http_code}' -H 'X-Requested-With: bedrock-now' "$(purl /api/summary)")"
check still-signed-in "$([ "$code" = 200 ] && echo 0 || echo 1)" "the session from before: /api/summary $code"
else
  # .env: the backup is the .env from before; nothing is lost but renamed keys and the old default host; the email is unchanged
  python3 - "$OUT/before/env" "$STACK/.env" "$STACK/.env.pre-devos-ade" > "$OUT/env.check" 2>&1 <<'PY'
import sys
def load(p): return dict(l.rstrip("\n").split("=", 1) for l in open(p) if "=" in l and not l.startswith("#"))
before, after, backup = load(sys.argv[1]), load(sys.argv[2]), load(sys.argv[3])
assert backup == before, "the backup is not the .env from before: " + str(sorted(set(backup.items()) ^ set(before.items()))[:4])
lost = []
for k, v in before.items():
    nk = "DEVOS_ADE_" + k[len("BEDROCK_NOW_"):] if k.startswith("BEDROCK_NOW_") else k
    if nk not in after: lost.append(k)
assert not lost or lost == ["COMPOSE_PROJECT_NAME"], f"keys lost: {lost}"
assert after["OPENWEBUI_ADMIN_EMAIL"] == before["OPENWEBUI_ADMIN_EMAIL"] == "admin@bedrock-now.local", "the owner email changed"
print("backup equals the .env before; no key lost but the renamed; owner email kept")
PY
  check env-migrated "$?" "$(tail -n 1 "$OUT/env.check")"
  check port-host-new "$([ "$(get_env PORTAL_HOST)" = "$HOST" ] || [ -z "$(get_env PORTAL_HOST)" ] && echo 0 || echo 1)" "PORTAL_HOST $(get_env PORTAL_HOST), want $HOST"
  # the new origin is a new site: everyone signs in once there (the old session is not honoured), and signing in works
  code="$(pcurl -o /dev/null -w '%{http_code}' -H 'X-Requested-With: devos-ade' "$(purl /api/summary)")"
  check new-origin-needs-sign-in "$([ "$code" != 200 ] && echo 0 || echo 1)" "/api/summary on the new host with the old session's jar: $code"
  get_env PORTAL_PASSWORD > "$OUT/pw"
  code="$(pcurl -o /dev/null -w '%{http_code}' -H "Origin: $(purl '')" --data-urlencode "password@$OUT/pw" "$(purl /login)")"; rm -f "$OUT/pw"
  check new-origin-signs-in "$([ "$code" = 303 ] && echo 0 || echo 1)" "sign-in on the new host: $code"
  migrate_checks
fi
got="$(owui "print(api('GET', '/api/v1/chats/$CHAT_ID', None, TOKEN)['title'])" 2>/dev/null)"
check chat-kept "$([ "$got" = e2e-upgrade ] && echo 0 || echo 1)" "the chat: ${got:-gone}"
got="$( ( clean_env; cd "$STACK" && docker compose -p "$PROJECT" -f compose.yaml run --rm --no-deps -T --entrypoint /bin/sh rustfs-init -c \
  'aws --endpoint-url http://rustfs:9000 s3 cp --only-show-errors s3://'"$CANARY"' -' ) </dev/null 2>/dev/null)"
check shared-file-kept "$([ "$got" = "$CANARY_V" ] && echo 0 || echo 1)" "the shared bucket's file: ${got:-gone}"
check workspace-file-kept "$([ "$(cat "$WS/e2e-upgrade.txt" 2>/dev/null)" = kept ] && echo 0 || echo 1)" "the workspace file"
code_project "${PROJECT_ID:-none}" > "$OUT/code-project-after.json" 2>> "$LOGS/code-after.log"
check code-project-kept "$(grep -q '"state": "trusted"' "$OUT/code-project-after.json" && cmp -s "$OUT/code-project-before.json" "$OUT/code-project-after.json" && echo 0 || echo 1)" \
  "before $(cat "$OUT/code-project-before.json" 2>/dev/null), after $(cat "$OUT/code-project-after.json" 2>/dev/null)"
got="$(cexec terminal cat /home/claude/.e2e-upgrade-home 2>/dev/null)"
check home-file-kept "$([ "$got" = "$HOME_V" ] && echo 0 || echo 1)" "the sandbox's home file: ${got:-gone}"
# the pages say DevOS ADE, and nothing but internal names say bedrock-now
pcurl "$(purl /)" > "$OUT/home.html"; curl -sS -m 30 --resolve "$HOST:$(pp):127.0.0.1" "$(purl /login)" > "$OUT/login.html"
for pg in login home; do
  t="$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$OUT/$pg.html" | head -1)"
  # (the throwaway's own path is on the page — the sign-in hint names its .env —, and this checkout's path may hold
  # the old name: it is taken out first). A tool that fails fails the check: never read as "nothing left".
  rc=0
  STACK="$STACK" python3 -c 'import os, sys; t = sys.stdin.read(); s = os.environ["STACK"]; h = os.path.expanduser("~")
print(t.replace(s, "STACK").replace("~" + s[len(h):] if s.startswith(h + "/") else s, "STACK"))' < "$OUT/$pg.html" > "$OUT/$pg.txt" || rc=3
  left=''; [ "$rc" != 0 ] || { left="$(python3 "$ROOT/tests/brand_check.py" --stdin "$pg" < "$OUT/$pg.txt")" || rc=$?; }
  case "$rc" in 0 | 1) ;; *) left="the page check itself failed (exit $rc)" ;; esac
  ok=1; case "$t" in *"DevOS ADE"*) [ "$rc" = 0 ] && ok=0 ;; esac
  check "page-$pg" "$ok" "title '$t'${left:+; old name: $(printf '%s' "$left" | head -3 | tr '\n' ' ')}"
done
[ "$MIGRATE" = 0 ] && python3 - "$OUT/before/manifest.json" "$OUT/after/manifest.json" "$PROJECT" "$(pp)" > "$OUT/manifest.check" 2>&1 <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
want = f"DevOS ADE ({sys.argv[3]}, port {sys.argv[4]})"
assert b["name"] == want, f"name {b['name']!r}, want {want!r}"
assert b["id"] == a["id"] == "/", f"id {a['id']!r} -> {b['id']!r}"
assert b["protocol_handlers"] == a["protocol_handlers"], f"link scheme {a['protocol_handlers']} -> {b['protocol_handlers']}"
print(f"name {a['name']!r} -> {b['name']!r}; id and link scheme kept")
PY
[ "$MIGRATE" != 0 ] || check manifest "$?" "$(tail -n 1 "$OUT/manifest.check")"
st test > "$LOGS/test-after.log" 2>&1; rc=$?; redact "$LOGS/test-after.log"
check stack-test-after "$([ "$rc" = 0 ] && grep -q 'all checks passed' "$LOGS/test-after.log" && echo 0 || echo 1)" "./stack test: exit $rc"
if [ "$REAL_GITHUB" = 1 ]; then
  o="$(git -C "$STACK" remote get-url origin)"
  check origin-moved "$([ "$o" = "$NEW_URL" ] && echo 0 || echo 1)" "origin is $o (want $NEW_URL)"
  pcurl -o /dev/null -X POST -H 'X-Requested-With: bedrock-now' -H "Origin: $(purl '')" "$(purl /api/update/check)"
  sleep 10
  u="$(pcurl -H 'X-Requested-With: bedrock-now' "$(purl /api/summary)" | python3 -c 'import json, sys; u = json.load(sys.stdin)["update"]; print(u.get("error") or "", u.get("latest") or "")')"
  check update-check "$([ -z "${u%% *}" ] && [ -n "${u#* }" ] && echo 0 || echo 1)" "error '${u%% *}', latest '${u#* }'"
fi
! grep -q "	FAIL	" "$RESULTS"
