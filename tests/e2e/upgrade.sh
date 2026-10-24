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
#                    this checkout, and the release to update to is a local tag v0.25.0 on its HEAD plus its working
#                    tree (as run.sh stages it), in the throwaway only.
#   --keep           leave the throwaway running (tests/e2e/upgrade.sh --teardown --project NAME removes it)
#
# 1. stage: a clone of this checkout in tests/e2e/work/PROJECT at --from; .env seeded with the project, free ports
#    (never 80, 443, 3000, 3009, 4000, 8080, 8081, 8090, 8765, 8800), small budgets, the Code page's workspace next to
#    the checkout; ./stack setup there.
# 2. seed: an Open WebUI chat (its API, no model call), one Haiku answer through LiteLLM (spend rows), a file in the
#    shared bucket and one in the workspace, a portal session (its cookie kept).
# 3. record: the project's containers, volumes and their mount points; the keys of Open WebUI's chats, users and
#    files and of LiteLLM's keys and spend rows; .env; the ports; the manifest's id and link scheme.
# 4. update: the throwaway's own update helper (its bin/bedrock-now-helper, in the foreground as tests/e2e/lib.sh runs
#    it) picks up an Update now request (.state/requests/req-<nonce>.json, as the portal writes it).
# 5. check: the release updated to; the folder where it was; the same containers, volumes and mount points; every key
#    recorded still there; .env with nothing removed or changed; the same ports; the session from before still signed
#    in; the chat, the shared file and the workspace file there; the login page, Home and the manifest say DevOS ADE
#    and have no bedrock-now outside the internal names (tests/brand_check.py --stdin); the manifest's id and link
#    scheme as before (the same installed app); ./stack test passes; with --real-github, origin moved to the new name
#    and the update check answering.
# Results: tests/e2e/out/upgrade/results.tsv (and logs/). The throwaway is removed at the end unless --keep.
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
while [ $# -gt 0 ]; do
  case "$1" in
    --aws-env) AWS_ENV_FILE="${2:?}"; shift 2 ;;
    --project) PROJECT="${2:?}"; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --real-github) REAL_GITHUB=1; shift ;;
    --teardown) TEARDOWN_ONLY=1; shift ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (--help)" >&2; exit 2 ;;
  esac
done

. "$HERE/lib.sh"
. "$ROOT/lib/ports.sh"   # port_in_use
valid_project "$PROJECT" || die "--project must be bne2e or bne2e-<letters, digits, ->: $PROJECT (never a real install's)"
OUT="$ROOT/tests/e2e/out/upgrade"; LOGS="$OUT/logs"; RESULTS="$OUT/results.tsv"
WORK="$ROOT/tests/e2e/work/$PROJECT"; mkdir -p "$(dirname "$WORK")" "$LOGS"
STACK="$(cd "$(dirname "$WORK")" && pwd -P)/$(basename "$WORK")"
HOST="$PROJECT.localhost"
command -v docker >/dev/null && docker info >/dev/null 2>&1 || die "Docker is required, and its daemon running"
if [ "$TEARDOWN_ONLY" = 1 ]; then teardown_only; exit 0; fi
[ -n "$AWS_ENV_FILE" ] || die "--aws-env FILE is required (only its AWS_* lines are read)"
load_aws_file "$AWS_ENV_FILE"
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || die "no AWS key in $AWS_ENV_FILE"
git -C "$ROOT" rev-parse -q --verify "refs/tags/$FROM" >/dev/null || die "no tag $FROM in this checkout"
: > "$RESULTS"; START_TS="$(now)"; HELPER_PID=''

st() { # st [--aws] ARGS... — the throwaway's ./stack, clean environment, no terminal
  [ "$(get_env COMPOSE_PROJECT_NAME)" = "$PROJECT" ] || { echo "xx  throwaway .env does not name project $PROJECT" >&2; return 99; }
  if [ "${1:-}" = --aws ]; then
    shift
    ( export AWS_REGION_NAME="${AWS_REGION_NAME:-us-east-1}" COMPOSE_PROJECT_NAME="$PROJECT"
      clean_env AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION_NAME COMPOSE_PROJECT_NAME
      cd "$STACK" && exec "$NOTTY" "$STACK/stack" "$@" </dev/null )
  else ( clean_env; cd "$STACK" && exec "$NOTTY" "$STACK/stack" "$@" </dev/null ); fi
}
check() { # check ID OK MESSAGE — records PASS when OK is 0
  if [ "$2" = 0 ]; then record upgrade "$1" PASS "$(( $(now) - START_TS ))" "$3"; else record upgrade "$1" FAIL "$(( $(now) - START_TS ))" "$3"; fi
}
finish() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [ -z "$HELPER_PID" ] || e2e_helper_stop
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

# --- 1. stage and set up the release before ---
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
  TO=v0.25.0
  git -C "$STACK" -c user.name=e2e -c user.email=e2e@example.invalid tag -a "$TO" -m "$TO (e2e)" e2e-next
fi
[ -n "$TO" ] || die "no release to update to"
git -C "$STACK" -c advice.detachedHead=false checkout -q "$FROM" || die "cannot check out $FROM"
: > "$STACK/.bedrock-now-e2e"; printf '/.bedrock-now-e2e\n' >> "$STACK/.git/info/exclude"
cp "$STACK/.env.example" "$STACK/.env"; chmod 600 "$STACK/.env"
pick_port P 18580; pick_port L 14580; pick_port M 18965
set_env COMPOSE_PROJECT_NAME "$PROJECT"; set_env PORTAL_HOST "$HOST"; set_env PORTAL_PORT "$P"
set_env LITELLM_PORT "$L"; set_env SHARED_MCP_PORT "$M"; set_env OPENWEBUI_ADMIN_EMAIL "e2e-admin@example.com"
for kv in $BUDGETS; do set_env "${kv%%=*}" "${kv#*=}"; done
set_env PORTAL_PASSWORD "$(openssl rand -hex 10)"
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

# --- 4. after ---
snapshot "$OUT/after"
check version "$(grep -qx "$TO" "$OUT/after/version" && echo 0 || echo 1)" "installed $(cat "$OUT/after/version"), want $TO"
check same-folder "$([ "$(real_dir "$STACK")" = "$(cd "$WORK" && pwd -P)" ] && [ -f "$STACK/.env" ] && echo 0 || echo 1)" "still in $STACK"
for f in services volumes mounts addresses; do
  check "same-$f" "$(cmp -s "$OUT/before/$f" "$OUT/after/$f" && echo 0 || echo 1)" "$(diff "$OUT/before/$f" "$OUT/after/$f" | head -5 | tr '\n' ' ')"
done
for k in $KEYS; do
  f="keys-${k//:/-}"; n="$(wc -l < "$OUT/before/$f" | tr -d ' ')"
  gone="$(comm -23 "$OUT/before/$f" "$OUT/after/$f" | wc -l | tr -d ' ')"
  check "rows-$f" "$([ "$n" -gt 0 ] && [ "$gone" = 0 ] && echo 0 || echo 1)" "$n row(s) before, $gone gone"
done
removed="$(comm -23 "$OUT/before/env" "$OUT/after/env" | sed 's/=.*//' | tr '\n' ' ')"
added="$(comm -13 "$OUT/before/env" "$OUT/after/env" | sed 's/=.*//' | tr '\n' ' ')"
check env-kept "$([ -z "$removed" ] && echo 0 || echo 1)" "removed or changed: ${removed:-none}; added: ${added:-none}"
code="$(pcurl -o /dev/null -w '%{http_code}' -H 'X-Requested-With: bedrock-now' "$(purl /api/summary)")"
check still-signed-in "$([ "$code" = 200 ] && echo 0 || echo 1)" "the session from before: /api/summary $code"
got="$(owui "print(api('GET', '/api/v1/chats/$CHAT_ID', None, TOKEN)['title'])" 2>/dev/null)"
check chat-kept "$([ "$got" = e2e-upgrade ] && echo 0 || echo 1)" "the chat: ${got:-gone}"
got="$( ( clean_env; cd "$STACK" && docker compose -p "$PROJECT" -f compose.yaml run --rm --no-deps -T --entrypoint /bin/sh rustfs-init -c \
  'aws --endpoint-url http://rustfs:9000 s3 cp --only-show-errors s3://'"$CANARY"' -' ) </dev/null 2>/dev/null)"
check shared-file-kept "$([ "$got" = "$CANARY_V" ] && echo 0 || echo 1)" "the shared bucket's file: ${got:-gone}"
check workspace-file-kept "$([ "$(cat "$WS/e2e-upgrade.txt" 2>/dev/null)" = kept ] && echo 0 || echo 1)" "the workspace file"
# the pages say DevOS ADE, and nothing but internal names say bedrock-now
pcurl "$(purl /)" > "$OUT/home.html"; curl -sS -m 30 --resolve "$HOST:$(pp):127.0.0.1" "$(purl /login)" > "$OUT/login.html"
for pg in login home; do
  t="$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$OUT/$pg.html" | head -1)"
  # (the throwaway's own path is on the page — the sign-in hint names its .env —, and this checkout's path may hold
  # the old name: it is taken out first)
  left="$(STACK="$STACK" python3 -c 'import os, sys; t = sys.stdin.read(); s = os.environ["STACK"]; h = os.path.expanduser("~")
print(t.replace(s, "STACK").replace("~" + s[len(h):] if s.startswith(h + "/") else s, "STACK"))' < "$OUT/$pg.html" |
    python3 "$ROOT/tests/brand_check.py" --stdin "$pg")"
  ok=1; case "$t" in *"DevOS ADE"*) [ -n "$left" ] || ok=0 ;; esac
  check "page-$pg" "$ok" "title '$t'${left:+; old name: $(printf '%s' "$left" | head -3 | tr '\n' ' ')}"
done
python3 - "$OUT/before/manifest.json" "$OUT/after/manifest.json" "$PROJECT" "$(pp)" > "$OUT/manifest.check" 2>&1 <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
want = f"DevOS ADE ({sys.argv[3]}, port {sys.argv[4]})"
assert b["name"] == want, f"name {b['name']!r}, want {want!r}"
assert b["id"] == a["id"] == "/", f"id {a['id']!r} -> {b['id']!r}"
assert b["protocol_handlers"] == a["protocol_handlers"], f"link scheme {a['protocol_handlers']} -> {b['protocol_handlers']}"
print(f"name {a['name']!r} -> {b['name']!r}; id and link scheme kept")
PY
check manifest "$?" "$(tail -n 1 "$OUT/manifest.check")"
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
