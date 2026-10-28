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
#   survives a recreated container; mirroring: push and pull mirrors to a connected host (a second Forgejo plays GitHub, https with
#   a certificate of this run's own) through Caddy's internal :8099 site, the git server's way out made by ./stack's own function only
#   for that host and taken away with the last mirror, a host that way out was not made for refused, deletes and the admin API not
#   passed by the internal site.
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
  docker rm -f "$P-portal-stub" "$P-remote" "$P-mclient" >/dev/null 2>&1
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
signed="$(curl -s -m 10 -H "Host: $host" -H 'Accept: text/html' "http://127.0.0.1:$PORT/devos/e2e-one")"
printf '%s' "$signed" | grep -q 'user/logout\|data-tooltip-content="devos"\|Sign Out' && pass "the portal's session signs the owner in (no password)" || fail "the owner is signed in through Caddy"
spoof="$(curl -s -m 10 -H "Host: $host" -H 'X-Webauth-User: nobody' "http://127.0.0.1:$PORT/devos/e2e-one" | grep -c 'nobody')"
check "a client's own X-Webauth-User is replaced, never trusted" "$spoof" 0
# Forgejo takes a sign-in header from ANY peer of the localgit network (its trusted-proxy setting does not limit that: measured in
# an earlier version of this suite, a forged header from another container signed in), so the control is the header's secret name:
# a forged plain X-Webauth-User sent straight to Forgejo from another peer signs nobody in
ssoh="$(get_env LOCALGIT_SSO_HEADER)"
case "$ssoh" in X-Bn-Git-*) pass "the sign-in header has a secret name made by ./stack" ;; *) fail "the sign-in header has a secret name ($ssoh)" ;; esac
# (the plain name Forgejo's documentation uses is not the one it takes: a forged copy of it signs nobody in)
direct="$(docker run --rm --network "${P}_localgit" "$P-client" sh -c "curl -s -m 10 -o /tmp/b -w '%{http_code} ' -H 'X-Webauth-User: devos' -H 'Accept: text/html' http://forgejo:3000/devos/e2e-one; grep -c 'user/logout\\|Sign Out' /tmp/b || true" 2>/dev/null | tr '\n' ' ')"
case "$direct" in "303 0 "* | "404 0 "* | "401 0 "*) pass "a forged sign-in header from another peer of the localgit network is not trusted ($direct)" ;; *) fail "a forged sign-in header from another peer is not trusted (got: $direct)" ;; esac
# (the old public fallback name, and a wrong secret, from another peer: not trusted either, and no fallback name exists)
old="$(docker run --rm --network "${P}_localgit" "$P-client" sh -c "curl -s -m 10 -o /tmp/b -w '%{http_code} ' -H 'X-Bn-Git-Unset: devos' -H 'Accept: text/html' http://forgejo:3000/devos/e2e-one; grep -c 'user/logout\\|Sign Out' /tmp/b || true" 2>/dev/null | tr '\n' ' ')"
case "$old" in "303 0 "* | "404 0 "* | "401 0 "*) pass "a forged X-Bn-Git-Unset from another peer is not trusted ($old)" ;; *) fail "a forged X-Bn-Git-Unset from another peer is not trusted (got: $old)" ;; esac
check "the compose file has no fallback name" "$(grep -c 'X-Bn-Git-Unset' "$W/compose.yaml" || true)" 0
check "Forgejo's X-Forwarded-For trust is Caddy's address alone, one hop" "$(dc exec -T forgejo sh -c "grep -E '^REVERSE_PROXY_(TRUSTED_PROXIES|LIMIT)' /var/lib/gitea/app.ini" | tr -d '\r' | tr '\n' ' ')" "REVERSE_PROXY_LIMIT = 1 REVERSE_PROXY_TRUSTED_PROXIES = 10.255.255.238/32 "
check "Caddy has the pinned address on the localgit network" "$(docker inspect -f '{{(index .NetworkSettings.Networks "'"${P}"'_localgit").IPAddress}}' "$(dc ps -q caddy)")" 10.255.255.238
# through Caddy, a client's own copy of the secret name or of the old name is removed: what is signed in is the owner, not what it sent
fake="$(curl -s -m 10 -H "Host: $host" -H "$ssoh: nobody" -H 'X-Bn-Git-Unset: nobody' "http://127.0.0.1:$PORT/devos/e2e-one" | grep -c 'nobody')"
check "a client's own copy of the secret name is replaced at Caddy's web site" "$fake" 0
# the name itself is what signs in: shown to a peer that knows it (this run's Caddy path is the only holder), a control that it works
known="$(docker run --rm --network "${P}_localgit" "$P-client" sh -c "curl -s -m 10 -o /tmp/b -w '%{http_code} ' -H '$ssoh: devos' -H 'Accept: text/html' http://forgejo:3000/devos/e2e-one; grep -c 'user/logout\\|Sign Out' /tmp/b || true" 2>/dev/null | tr '\n' ' ')"
case "$known" in "200 "[1-9]*) pass "(control) a peer that knows the secret name is signed in: the name is the whole control ($known)" ;; *) fail "(control) the secret name signs in ($known)" ;; esac
check "no container but Caddy's and Forgejo's has the name in its environment" "$(docker ps -q --filter "label=com.docker.compose.project=$P" | while read -r c; do docker inspect -f '{{.Name}} {{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -l "$ssoh" >/dev/null 2>&1 && docker inspect -f '{{.Name}}' "$c"; done | sort | tr '\n' ' ')" "/e2e-localgit-caddy-1 /e2e-localgit-forgejo-1 "
login="$(curl -s -m 10 -D "$S/login.hdr" -H "Host: $host" "http://127.0.0.1:$PORT/devos/e2e-one")"
printf '%s' "$login" | grep -q 'Forgejo' && pass "its pages are Forgejo's" || fail "its pages are Forgejo's"
grep -qi '^content-security-policy: frame-ancestors http://'"$P"'.localhost:'"$PORT"'\r\?$' "$S/login.hdr" && pass "framed by the portal only (CSP frame-ancestors)" || fail "framed by the portal only ($(grep -i 'content-security-policy' "$S/login.hdr" | head -n 1))"
grep -qi '^x-frame-options' "$S/login.hdr" && fail "no X-Frame-Options left" || pass "no X-Frame-Options left"
other="$(curl -s -m 10 -H "Host: 127.0.0.1:$PORT" "http://127.0.0.1:$PORT/user/login")"
printf '%s' "$other" | grep -q 'Forgejo' && fail "another Host name never reaches Forgejo" || pass "another Host name never reaches Forgejo (the unknown-host route)"

# --- persistence: the volume keeps the repositories ---
dc up -d --no-deps --force-recreate --wait forgejo >/dev/null 2>&1
check "the repository survives a recreated container" "$(dc exec -T forgejo curl -s -H "$auth" http://127.0.0.1:3000/api/v1/repos/devos/e2e-one | python3 -c 'import sys, json; print(json.load(sys.stdin)["full_name"])')" devos/e2e-one
# --- mirroring: Forgejo's own repository mirroring to a connected host, the way out only while a mirror exists ---
# (a second Forgejo plays GitHub: https, a certificate of this run's own, on the network the git server gets only for a mirror)
nets() { docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(dc ps -q forgejo)" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }
check "before a mirror the git server has the internal network alone" "$(nets)" "${P}_localgit "
mkdir -p "$S/remote"
rcfg="$S/remote/c.cnf"; printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=remote-git\n[v3]\nsubjectAltName=DNS:remote-git\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=serverAuth\n' > "$rcfg"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -config "$rcfg" -keyout "$S/remote/tls.key" -out "$S/remote/tls.crt" >/dev/null 2>&1
chmod 644 "$S/remote"/tls.*
# (the git server trusts that one certificate for the remote: a test-only file of the projects overlay ./stack reads while it exists)
mkdir -p "$S/state/projects"
printf 'services:\n  forgejo:\n    environment:\n      SSL_CERT_FILE: /var/lib/gitea/remote-ca.pem\n      GIT_SSL_CAINFO: /var/lib/gitea/remote-ca.pem\n' > "$S/state/projects/compose.yaml"
_lg_mirror_egress_apply remote-git > "$S/egress.log" 2>&1 && pass "the way out is made for remote-git (./stack's own function)" || { fail "the way out is made ($(tail -n 3 "$S/egress.log" | tr '\n' ' '))"; }
check "while a mirror exists: the internal network and a way out of its own" "$(nets)" "${P}_localgit ${P}_localgit-out "
check "the way out is not internal" "$(docker network inspect -f '{{.Internal}}' "${P}_localgit-out")" false
check "the allowed names are the mirrors' hosts only" "$(dc exec -T forgejo sh -c 'grep ALLOWED_DOMAINS /var/lib/gitea/app.ini' | tr -d '\r')" "ALLOWED_DOMAINS = remote-git"
RIMG="$(dc config --images 2>/dev/null | grep forgejo | head -n 1)"
docker rm -f "$P-remote" >/dev/null 2>&1
docker create --name "$P-remote" --network "${P}_localgit-out" --network-alias remote-git -e GITEA_APP_INI=/var/lib/gitea/app.ini -e FORGEJO__security__INSTALL_LOCK=true \
  -e FORGEJO__database__DB_TYPE=sqlite3 -e FORGEJO__server__PROTOCOL=https -e FORGEJO__server__CERT_FILE=/certs/tls.crt -e FORGEJO__server__KEY_FILE=/certs/tls.key \
  -e FORGEJO__server__ROOT_URL=https://remote-git:3000/ -e FORGEJO__server__DISABLE_SSH=true -e FORGEJO__server__START_SSH_SERVER=false \
  -e FORGEJO__repository__ENABLE_PUSH_CREATE_USER=true -e FORGEJO__service__DISABLE_REGISTRATION=true "$RIMG" >/dev/null 2>&1 || fail "the stand-in remote is created"
docker cp "$S/remote" "$P-remote:/certs" >/dev/null 2>&1
docker start "$P-remote" >/dev/null 2>&1 || fail "the stand-in remote starts"
for i in $(seq 1 60); do docker exec "$P-remote" curl -ksf https://localhost:3000/api/healthz >/dev/null 2>&1 && break; sleep 1; done
docker exec "$P-remote" forgejo admin user create --admin --username rem --email rem@example.com --password 'Rem9-0123456789abcdef' --must-change-password=false >/dev/null 2>&1
rtok="$(docker exec "$P-remote" forgejo admin user generate-access-token --username rem --token-name m --scopes all --raw 2>/dev/null | tail -n 1 | tr -d '\r')"
check "the stand-in remote has an account and a token" "${#rtok}" 40
docker exec "$P-remote" curl -ks -H "Authorization: token $rtok" -H 'Content-Type: application/json' -d '{"name":"copy","private":true}' https://localhost:3000/api/v1/user/repos >/dev/null 2>&1
docker cp "$S/remote/tls.crt" "$(dc ps -q forgejo):/var/lib/gitea/remote-ca.pem" >/dev/null 2>&1
dc restart forgejo >/dev/null 2>&1; for i in $(seq 1 60); do dc exec -T forgejo curl -fsS http://127.0.0.1:3000/api/healthz >/dev/null 2>&1 && break; sleep 1; done
# (the client is on the default network, where Caddy's :8099 site is, and on the stand-in's network, to read the remote it checks)
export E2E_GIT_TOKEN="$tok" E2E_GIT_CA="$(cat "$S/state/localgit/tls/tls.crt")" E2E_REMOTE_TOKEN="$rtok" E2E_REMOTE_CA="$(cat "$S/remote/tls.crt")"
docker rm -f "$P-mclient" >/dev/null 2>&1
docker create --name "$P-mclient" --network "${P}_default" -e E2E_GIT_TOKEN -e E2E_GIT_CA -e E2E_REMOTE_TOKEN -e E2E_REMOTE_CA -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
  -v "$W":/repo:ro -v "$HERE/mirror.mjs":/mirror.mjs:ro "$P-client" node /mirror.mjs >/dev/null 2>&1
docker network connect "${P}_localgit-out" "$P-mclient" >/dev/null 2>&1
docker start -a "$P-mclient" > "$S/mirror.log" 2>&1
mrc=$?
docker rm -f "$P-mclient" >/dev/null 2>&1
unset E2E_GIT_TOKEN E2E_GIT_CA E2E_REMOTE_TOKEN E2E_REMOTE_CA
grep -E '^(ok|FAIL) ' "$S/mirror.log" | sed -e 's/^ok   /PASS /' | cut -c1-230
[ "$mrc" = 0 ] && pass "the mirror client's checks all passed" || { fail "the mirror client exited $mrc"; tail -n 15 "$S/mirror.log"; dc logs --tail 25 forgejo 2>&1 | tail -n 25; }
# a pull mirror is a repository: it stays until deleted; the way out follows the mirrors that really exist (here: its host)
dc exec -T forgejo curl -s -X DELETE -H "$auth" http://127.0.0.1:3000/api/v1/repos/devos/pulled >/dev/null 2>&1
_lg_mirror_egress_apply "" > "$S/egress2.log" 2>&1 && pass "no mirror left: the way out is taken away (./stack's own function)" || fail "the way out is taken away"
check "after the last mirror: the internal network alone again" "$(nets)" "${P}_localgit "
check "and no allowed names are left in its settings" "$(dc exec -T forgejo sh -c 'grep "ALLOWED_DOMAINS" /var/lib/gitea/app.ini' | tr -d '\r')" "ALLOWED_DOMAINS = "
check "the stand-in remote is no longer reachable from the git server" "$(dc exec -T forgejo sh -c "curl -ks -m 4 -o /dev/null -w '%{http_code}' https://remote-git:3000/ ; true" | tr -d '\r')" 000
rm -f "$S/state/projects/compose.yaml"
docker rm -f "$P-remote" >/dev/null 2>&1

# --- off: the container and the site go, the volume stays ---
set_env LOCALGIT off
dc rm -sf forgejo >/dev/null 2>&1; _LG_PROFILE=1 dc rm -sf forgejo >/dev/null 2>&1
check "LOCALGIT=off: no forgejo in the services" "$(optional_services | tr ' ' '\n' | grep -c '^forgejo$')" 0
check "LOCALGIT=off: no git listener overlay" "$(compose_overlays | tr '\n' ' ')" "compose.terminal.yaml "
docker volume inspect "${P}_gitdata" >/dev/null 2>&1 && pass "its repositories stay in the volume" || fail "its repositories stay in the volume"
printf '\n%s\n' "$([ "$fails" = 0 ] && echo 'every check passed' || echo "$fails failed")"
[ "$fails" = 0 ]
