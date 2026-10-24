#!/usr/bin/env bash
# Opt-in UI/UX sweep of a THROWAWAY stack (run by hand; not part of tests/run.sh): a checkout set up under its own
# Compose project and ports, then tests/e2e/browser/ui_sweep.py in the e2e suite's pinned Playwright container — every
# page and state of the portal, Chat, the Code page and the terminal at three widths (1512x900, 820x1180, 390x844) and
# in both themes: screenshots, console errors and failed requests, broken images and icons, the logo, the old name in
# visible text, layout, and every link (external ones paced). Then the throwaway is removed (unless --keep).
#
#   tests/e2e/ui-sweep.sh --aws-env FILE [--src DIR] [--project bne2e-uisweep] [--out DIR] [--keep]
#   tests/e2e/ui-sweep.sh --reuse [--project bne2e-uisweep] [--keep]   the sweep again on a throwaway kept by --keep
#   tests/e2e/ui-sweep.sh --teardown [--project bne2e-uisweep]
#
#   --src DIR   the checkout to set up, at its HEAD (default: this one) — e.g. a detached worktree of a release
#   --out DIR   results (default tests/e2e/out/ui-sweep): sweep/shots/<page>-<state>-<width>-<theme>.png,
#               sweep/findings.tsv and .json, sweep/summary.txt, sweep/links.json, sweep/links-pending-release.json
#   SWEEP_WIDTHS=desktop,tablet,phone  SWEEP_THEMES=light,dark   a smaller sweep
# The sweep reads; what it seeds is the throwaway's own: a project of its workspace (a git repository with a change, its
# own Claude Code settings, not trusted) for the Code page's Projects, Git and trust views. Costs setup's probe only.
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC2034  # AVOID_PORTS: read by lib.sh's pick_port
AVOID_PORTS=" 80 443 3000 3009 4000 8080 8081 8090 8765 8800 "
BUDGETS="BUDGET_CLAUDE_CODE=0.04 BUDGET_OPENWEBUI=0.04 BUDGET_SETUP=0.02"
NOTTY="$HERE/notty"
PROJECT=bne2e-uisweep; SRC="$ROOT"; AWS_ENV_FILE=''; KEEP=0; TEARDOWN_ONLY=0; OUT_DIR=''; REUSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --aws-env) AWS_ENV_FILE="${2:?}"; shift 2 ;;
    --src) SRC="$(cd "${2:?}" && pwd -P)"; shift 2 ;;
    --project) PROJECT="${2:?}"; shift 2 ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --reuse) REUSE=1; shift ;;
    --teardown) TEARDOWN_ONLY=1; shift ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (--help)" >&2; exit 2 ;;
  esac
done

. "$HERE/lib.sh"
. "$ROOT/lib/ports.sh"   # port_in_use
valid_project "$PROJECT" || die "--project must be bne2e or bne2e-<letters, digits, ->: $PROJECT (never a real install's)"
OUT="${OUT_DIR:-$ROOT/tests/e2e/out/ui-sweep}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd -P)"
LOGS="$OUT/logs"; RESULTS="$OUT/results.tsv"; mkdir -p "$LOGS"; : > "$RESULTS"
WORK="$ROOT/tests/e2e/work/$PROJECT"; mkdir -p "$(dirname "$WORK")"
STACK="$(cd "$(dirname "$WORK")" && pwd -P)/$(basename "$WORK")"
HOST="$PROJECT.localhost"
command -v docker >/dev/null && docker info >/dev/null 2>&1 || die "Docker is required, and its daemon running"
if [ "$TEARDOWN_ONLY" = 1 ]; then teardown_only; exit 0; fi
if [ "$REUSE" = 0 ]; then
  [ -n "$AWS_ENV_FILE" ] || die "--aws-env FILE is required (only its AWS_* lines are read)"
  load_aws_file "$AWS_ENV_FILE"
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || die "no AWS key in $AWS_ENV_FILE"
fi
# shellcheck disable=SC2034  # (HELPER_PID: read by lib.sh's teardown)
HELPER_PID=''
trap 'rc=$?; trap - EXIT INT TERM HUP; if [ "$KEEP" = 0 ]; then teardown; else say "kept: tests/e2e/ui-sweep.sh --teardown --project $PROJECT"; fi; exit $rc' EXIT
trap 'warn "interrupted"; exit 130' INT TERM HUP

st() { # the throwaway's ./stack, clean environment, no terminal
  [ "$(get_env COMPOSE_PROJECT_NAME)" = "$PROJECT" ] || { echo "xx  throwaway .env does not name project $PROJECT" >&2; return 99; }
  ( export AWS_REGION_NAME="${AWS_REGION_NAME:-us-east-1}" COMPOSE_PROJECT_NAME="$PROJECT"
    clean_env AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION_NAME COMPOSE_PROJECT_NAME
    cd "$STACK" && exec "$NOTTY" "$STACK/stack" "$@" </dev/null )
}
cexec() { local s="$1" id; shift
  id="$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$s" | head -n 1)"
  [ -n "$id" ] || { echo "no $s container" >&2; return 1; }; docker exec -i "$id" "$@"; }
codeapi() { # METHOD PATH [JSON]: the Code page's own API, asked in its container as the main Caddy asks it
  cexec code node -e '
const http = require("http"); const [m, p, b] = process.argv.slice(1); const port = Number(process.env.CODE_PORT || 8095);
const req = http.request({ host: "127.0.0.1", port, method: m, path: p, headers: { "X-Bn-Code-Proxy": process.env.CODE_PROXY_SECRET,
  Origin: `http://127.0.0.1:${port}`, "Content-Type": "application/json" } }, (res) => {
  let d = ""; res.on("data", (c) => { d += c; }); res.on("end", () => { process.stdout.write(d); process.exitCode = res.statusCode < 300 ? 0 : 1; }); });
req.on("error", (e) => { console.error(e.message); process.exitCode = 2; }); if (b) req.write(b); req.end();' "$@" </dev/null
}

if [ "$REUSE" = 1 ]; then
  reuse_check   # a kept throwaway of this suite, every service up; OWNED=1
  P="$(get_env PORTAL_PORT)"; L="$(get_env LITELLM_PORT)"; M="$(get_env SHARED_MCP_PORT)"
  say "reusing the throwaway in $STACK"
else
  # --- stage and set up the checkout (its HEAD) ---
  claim_project
  # shellcheck disable=SC2034  # (OWNED: read by teardown)
  [ "$OWN_STATE" != ours ] || { warn "project $PROJECT: $OWN_WHY — removing those leftovers first"; teardown; OWNED=1; }
  if [ -e "$STACK" ]; then
    [ -f "$STACK/.bedrock-now-e2e" ] || die "$STACK exists and was not created by this suite — nothing was changed"
    chmod -R u+rwX "$STACK"; rm -rf "$STACK"
  fi
  REV="$(git -C "$SRC" rev-parse HEAD)" || die "$SRC is not a checkout"
  say "staging $SRC at ${REV:0:7} in $STACK"
  ( umask 022; git clone --quiet --no-hardlinks "$SRC" "$STACK" ) || die "git clone failed"
  git -C "$STACK" -c advice.detachedHead=false checkout -q --detach "$REV" || die "cannot check out $REV"
  : > "$STACK/.bedrock-now-e2e"; printf '/.bedrock-now-e2e\n' >> "$STACK/.git/info/exclude"
  cp "$STACK/.env.example" "$STACK/.env"; chmod 600 "$STACK/.env"
  pick_port P 18780; pick_port L 14780; pick_port M 19165
  set_env COMPOSE_PROJECT_NAME "$PROJECT"; set_env PORTAL_HOST "$HOST"; set_env PORTAL_PORT "$P"
  set_env LITELLM_PORT "$L"; set_env SHARED_MCP_PORT "$M"; set_env OPENWEBUI_ADMIN_EMAIL "you@example.com"
  for kv in $BUDGETS; do set_env "${kv%%=*}" "${kv#*=}"; done
  set_env PORTAL_PASSWORD "$(openssl rand -hex 10)"
  WS="$(terminal_workspace_dir)"; ( umask 077; mkdir -p "$WS" ) && : > "$WS/.bedrock-now-e2e"; set_env TERMINAL_WORKSPACE "$WS"
  ( umask 022; mkdir -p "$STACK/.state/update-check" ); chmod 700 "$STACK/.state"; : > "$STACK/.state/portal-password-shown"
  printf '{"checked_at": "%s", "error": null}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$STACK/.state/update-check/latest.json"
  chmod 644 "$STACK/.state/update-check/latest.json"
  say "setup (log: $LOGS/setup.log)"
  st setup --yes > "$LOGS/setup.log" 2>&1 || { redact "$LOGS/setup.log"; die "setup failed — see $LOGS/setup.log"; }
  redact "$LOGS/setup.log"

  # --- the Code page's views need something to show: a project with files, git history, a change and its own settings ---
  d="$WS/ui-sweep"
  pid="$(codeapi POST /api/projects '{"kind": "new", "folder": "ui-sweep"}' 2> "$LOGS/seed.log" | python3 -c 'import json, sys; print(json.load(sys.stdin)["project"]["id"])' 2>> "$LOGS/seed.log")"
  [ -n "$pid" ] || warn "the Code page project was not made (log $LOGS/seed.log): its views will be said as not reached"
  mkdir -p "$d/src" "$d/.claude"
  printf '# ui-sweep\n\nA project of the sweep.\n' > "$d/README.md"
  printf 'export const answer = 42;\n' > "$d/src/main.js"
  printf '{"permissions": {"allow": ["Bash(ls:*)"]}}\n' > "$d/.claude/settings.json"
  ( cd "$d" && { [ -d .git ] || git init -q; } && git add -A && git -c user.name=sweep -c user.email=sweep@example.invalid commit -q -m "sweep: first" ) >> "$LOGS/seed.log" 2>&1
  printf 'export const answer = 43;\n' > "$d/src/main.js"

fi

# --- the sweep, in the e2e suite's Playwright image ---
PW_IMAGE="$(sed -n 's/^PW_IMAGE="\(.*\)"$/\1/p' "$HERE/run.sh")"
docker build -q --build-arg PW_IMAGE="$PW_IMAGE" -t "$PROJECT/e2e-playwright:local" "$HERE" > "$LOGS/build.log" 2>&1 || die "the Playwright image did not build ($LOGS/build.log)"
NEW_LOGO="$(shasum -a 256 < "$ROOT/portal/portal/static/logo.svg" | cut -d' ' -f1)"
OLD_LOGO="$(git -C "$ROOT" show 49d7e83:portal/portal/static/logo.svg 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
opts=()
if [ "$(uname -s)" = Linux ]; then opts=(--network host --user "$(id -u):$(id -g)" -e HOME=/tmp); target=127.0.0.1; else target=host-gateway; fi
for h in "$HOST" "chat.$HOST" "admin.$HOST" "files.$HOST" "terminal.$HOST" "code.$HOST" "nosuch.$HOST"; do opts+=(--add-host "$h:$target"); done
mkdir -p "$OUT/run"
say "the sweep ($(echo "${SWEEP_WIDTHS:-desktop,tablet,phone}" | tr , ' '), ${SWEEP_THEMES:-light,dark}; log: $OUT/run/sweep.log)"
docker rm -f "$PROJECT-playwright" >/dev/null 2>&1 || true
docker run --rm --name "$PROJECT-playwright" --init --shm-size=1g "${opts[@]}" \
  -e E2E_HOST="$HOST" -e E2E_PORT="$P" -e E2E_LITELLM_PORT="$L" -e E2E_MCP_PORT="$M" \
  -e SWEEP_WIDTHS="${SWEEP_WIDTHS:-desktop,tablet,phone}" -e SWEEP_THEMES="${SWEEP_THEMES:-light,dark}" \
  -e SWEEP_NEW_LOGO_SHA="$NEW_LOGO" -e SWEEP_OLD_LOGO_SHA="$OLD_LOGO" -e SWEEP_STACK_PATH="$STACK" -e SWEEP_HOME="$HOME" \
  -v "$STACK/.env:/run/e2e/env:ro" -v "$HERE/browser:/suite:ro" -v "$OUT/run:/out" \
  -v "$STACK/.state/status:/state/status:ro" -v "$STACK/.state/update-check:/state/update-check" \
  -v "$ROOT:/repo:ro" -v "$STACK:/stack:ro" \
  "$PROJECT/e2e-playwright:local" python3 -u /suite/ui_sweep.py > "$OUT/run/sweep.log" 2>&1
rc=$?
redact "$OUT/run/sweep.log"; redact_outputs
tail -n 40 "$OUT/run/sweep.log" >&2
exit "$rc"
