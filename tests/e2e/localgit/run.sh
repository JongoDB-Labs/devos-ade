#!/bin/bash
# The built-in local git server (Forgejo; JON-810) against the real compose files, in a throwaway Compose project of its own
# (e2e-localgit, never a stack of yours): no AWS key, no model, no Open WebUI — only what the feature touches: forgejo, the
# terminal's gateway with compose.localgit.yaml, the main Caddy with the git site (and a stand-in for the portal's check).
# Opt-in like tests/e2e (tests/run.sh never starts a container). Docker work belongs under the DevOS heavy lock:
#   python3 .../heavylock.py run --lock ~/.local/state/devos-heavy/heavy.lock --label NAME --timeout 0 -- tests/e2e/localgit/run.sh
# What it proves (each line PASS or FAIL; exit 0 when all pass):
#   ./stack's own functions (lib/common.sh, lib/localgit.sh) make the certificate, start the container healthy, make the owner
#   account (again idempotent) and a repository-scoped token; the settings in effect (no SSH, no registration, private by
#   default, push-create); from a container on the sandbox's internal network ONLY — no internet, a dead egress proxy set,
#   TERMINAL_EGRESS=off — the Code page's real logic (plan, run) and bn-coded's real git: publish (push-create), clone into
#   a second folder, a branch published with its pull-request link, a push, a fetch, a fast-forward pull, a wrong token
#   refused, the token in no .git/config, event or host view; the gateway answers git's paths only (the web UI, the API,
#   raw files: 404; no credential: 401); Forgejo, the internet and github.com are unreachable from that network; the web UI
#   through the main Caddy behind the portal's check, framed by the portal only, other Host names refused; the repository
#   survives a recreated container.
set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$(cd "$HERE/../../.." && pwd)"
P="${E2E_LOCALGIT_PROJECT:-e2e-localgit}"
S="$(mktemp -d "${TMPDIR:-/tmp}/e2e-localgit.XXXXXX")"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: $2; want: $3)"; fi; }
mkdir -p "$S/state" "$S/ws"
cat > "$S/env" <<ENV
COMPOSE_PROJECT_NAME=$P
POSTGRES_PASSWORD=p
RUSTFS_ACCESS_KEY=a
RUSTFS_SECRET_KEY=s
LITELLM_MASTER_KEY=m
LITELLM_SALT_KEY=s
LITELLM_UI_PASSWORD=u
WEBUI_SECRET_KEY=w
OPENWEBUI_ADMIN_EMAIL=owner@example.com
OPENWEBUI_ADMIN_PASSWORD=p
SHARED_MCP_TOKEN=t
PORTAL_HOST=$P.localhost
PORTAL_PORT=$PORT
PORTAL_ORIGIN=http://$P.localhost:$PORT
TERMINAL_ENABLED=true
TERMINAL_WORKSPACE=$S/ws
TERMINAL_EGRESS=off
TERMINAL_PROXY_SECRET=0123456789abcdef0123456789abcdef
LOCALGIT_ADMIN_PASSWORD=Lg9-0123456789abcdef0123456789ab
GIT_ORIGIN=http://git.$P.localhost:$PORT
WEBSEARCH_SEARXNG_BUILTIN=off
ENV
chmod 600 "$S/env"
export STACK_DIR="$W" ENV_FILE="$S/env" STATE_DIR="$S/state"
cd "$W" || exit 2
# shellcheck disable=SC1091
. lib/common.sh; . lib/ports.sh; . lib/portal.sh; . lib/models.sh; . lib/commands.sh; . lib/prices.sh
cleanup() {
  docker rm -f "$P-portal-stub" >/dev/null 2>&1
  _LG_PROFILE=1 dc down -v --remove-orphans >/dev/null 2>&1
  docker volume rm "${P}_gitdata" >/dev/null 2>&1
  docker rmi -f "$P-client" >/dev/null 2>&1
  rm -rf "$S"
}
trap cleanup EXIT
docker info >/dev/null 2>&1 || { echo "needs a running Docker" >&2; exit 2; }

# --- ./stack's own functions ---
check "overlays: the terminal's and the git server's" "$(compose_overlays | tr '\n' ' ')" "compose.terminal.yaml compose.localgit.yaml "
localgit_tls_ensure && [ -s "$S/state/localgit/tls/tls.crt" ] && pass "the certificate for the name gateway is made" || fail "the certificate is made"
openssl x509 -in "$S/state/localgit/tls/tls.crt" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:gateway' && pass "its name is gateway" || fail "its name is gateway"
if dc up -d --no-deps --wait forgejo terminal-gateway caddy > "$S/up.log" 2>&1; then pass "forgejo, the terminal's gateway and Caddy start healthy"
else fail "the services start healthy ($(tail -n 5 "$S/up.log" | tr '\n' ' '))"; dc logs --tail 30 forgejo terminal-gateway caddy; exit 1; fi
localgit_ensure_admin && pass "the owner account is made" || fail "the owner account is made"
check "it is a site admin named devos" "$(_lg_forgejo admin user list 2>/dev/null | awk 'NR > 1 { print $2 " admin=" $5 }')" "devos admin=true"
localgit_ensure_admin && pass "made again: idempotent (the password set again)" || fail "made again"
tok="$(_lg_forgejo admin user generate-access-token --username devos --token-name e2e --scopes "$LOCALGIT_TOKEN_SCOPES" --raw 2>/dev/null | tail -n 1 | tr -d '\r')"
check "a repository-scoped token is made (40 characters)" "${#tok}" 40
ini="$(dc exec -T forgejo sh -c 'cat /var/lib/gitea/app.ini' 2>/dev/null)"
for kv in 'DISABLE_SSH = true' 'START_SSH_SERVER = false' 'DISABLE_REGISTRATION = true' 'REQUIRE_SIGNIN_VIEW = true' 'DEFAULT_PRIVATE = private' 'ENABLE_PUSH_CREATE_USER = true'; do
  printf '%s\n' "$ini" | grep -q "^$kv\$" && pass "forgejo: $kv" || fail "forgejo: $kv"
done
check "forgejo runs as its own user, not root" "$(dc exec -T forgejo id -u 2>/dev/null | tr -d '\r')" 1000
check "its network is the internal one alone" "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(dc ps -q forgejo)")" "${P}_localgit "
check "the localgit network is internal" "$(docker network inspect -f '{{.Internal}}' "${P}_localgit")" true
mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$(dc ps -q forgejo)" | awk '{ print $1 }')"
printf 'info forgejo memory at rest: %s\n' "$mem"

# --- the sandbox's side: only the internal terminal network, no internet ---
docker build -q -t "$P-client" "$HERE" >/dev/null 2>&1 && pass "the client image (node, git) is built" || { fail "the client image is built"; exit 1; }
E2E_GIT_TOKEN="$tok" E2E_GIT_CA="$(cat "$S/state/localgit/tls/tls.crt")" docker run --rm --network "${P}_terminal" -e "E2E_GIT_WEB=http://git.$P.localhost:$PORT" \
  -e E2E_GIT_TOKEN -e E2E_GIT_CA -v "$W":/repo:ro -v "$HERE/client.mjs":/client.mjs:ro "$P-client" node /client.mjs > "$S/client.log" 2>&1
rc=$?
grep -E '^(ok|FAIL) ' "$S/client.log" | sed -e 's/^ok   /PASS /' -e 's/^FAIL /FAIL /' | cut -c1-220
[ "$rc" = 0 ] && pass "the client container's checks all passed" || { fail "the client container exited $rc"; tail -n 20 "$S/client.log"; }
auth="Authorization: token $tok"
check "the server has both branches" "$(dc exec -T forgejo curl -s -H "$auth" http://127.0.0.1:3000/api/v1/repos/devos/e2e-one/branches | python3 -c 'import sys, json; print(" ".join(sorted(b["name"] for b in json.load(sys.stdin))))')" "feature/x main"
check "the repository is private, main its default" "$(dc exec -T forgejo curl -s -H "$auth" http://127.0.0.1:3000/api/v1/repos/devos/e2e-one | python3 -c 'import sys, json; d = json.load(sys.stdin); print(d["private"], d["default_branch"])')" "True main"

# --- the web UI through the main Caddy, behind the portal's check (a stand-in answers it: this suite has no portal) ---
docker run -d --name "$P-portal-stub" --network "${P}_default" --network-alias portal "$P-client" node -e \
  "require('http').createServer((q,r)=>{r.writeHead(200,{'X-Portal-User':'owner@example.com'});r.end('ok')}).listen(8000)" >/dev/null 2>&1
sleep 2
host="git.$P.localhost:$PORT"
home="$(curl -s -m 10 -w '\n%{http_code}' -H "Host: $host" -H 'Accept: text/html' "http://127.0.0.1:$PORT/")"
[ "$(printf '%s' "$home" | tail -n 1)" = 200 ] && printf '%s' "$home" | grep -q 'Forgejo' && pass "the web UI answers through Caddy (Forgejo's page)" || fail "the web UI answers through Caddy ($(printf '%s' "$home" | tail -n 1))"
login="$(curl -s -m 10 -D "$S/login.hdr" -H "Host: $host" "http://127.0.0.1:$PORT/user/login")"
printf '%s' "$login" | grep -q 'Forgejo' && pass "its sign-in page is Forgejo's" || fail "its sign-in page is Forgejo's"
grep -qi '^content-security-policy: frame-ancestors http://'"$P"'.localhost:'"$PORT"'\r\?$' "$S/login.hdr" && pass "framed by the portal only (CSP frame-ancestors)" || fail "framed by the portal only ($(grep -i 'content-security-policy' "$S/login.hdr" | head -n 1))"
grep -qi '^x-frame-options' "$S/login.hdr" && fail "no X-Frame-Options left" || pass "no X-Frame-Options left"
other="$(curl -s -m 10 -H "Host: 127.0.0.1:$PORT" "http://127.0.0.1:$PORT/user/login")"
printf '%s' "$other" | grep -q 'Forgejo' && fail "another Host name never reaches Forgejo" || pass "another Host name never reaches Forgejo (the unknown-host route)"

# --- persistence: the volume keeps the repositories ---
dc up -d --no-deps --force-recreate --wait forgejo >/dev/null 2>&1
check "the repository survives a recreated container" "$(dc exec -T forgejo curl -s -H "$auth" http://127.0.0.1:3000/api/v1/repos/devos/e2e-one | python3 -c 'import sys, json; print(json.load(sys.stdin)["full_name"])')" devos/e2e-one
# --- off: the container and the site go, the volume stays ---
set_env LOCALGIT off
dc rm -sf forgejo >/dev/null 2>&1; _LG_PROFILE=1 dc rm -sf forgejo >/dev/null 2>&1
check "LOCALGIT=off: no forgejo in the services" "$(optional_services | tr ' ' '\n' | grep -c '^forgejo$')" 0
check "LOCALGIT=off: no git listener overlay" "$(compose_overlays | tr '\n' ' ')" "compose.terminal.yaml "
docker volume inspect "${P}_gitdata" >/dev/null 2>&1 && pass "its repositories stay in the volume" || fail "its repositories stay in the volume"
printf '\n%s\n' "$([ "$fails" = 0 ] && echo 'every check passed' || echo "$fails failed")"
[ "$fails" = 0 ]
