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
#   --long-path (with each of these) stages the throwaway under a deliberately long folder name with no break in it,
#               so every path the pages show (the sign-in hint, Settings, Home, the walkthrough) has to wrap
#   --layout fast|full   the layout sweep (tests/e2e/browser/layout_sweep.py) in place of the UI sweep: what collides or
#               is cut off at many window sizes, in both themes. fast: 12 widths, the main pages (as the e2e check
#               browser/layout-no-overlap runs it); full, for releases: every 40 px from 320 to 1920 at heights 600 and
#               1000, every state (each Settings section and walkthrough step, Activity, search, More, the menus, info
#               panels, the collapsed sidebar, the Code page's views), and a session of the Code page against its mock
#               backend when code/web has a build and node_modules/ws (npm ci; npm run build). Results: OUT/layout/
#               findings.json, summary.txt, shots/ (one cropped PNG per finding). LAYOUT_JOBS=3 browsers at a time;
#               LAYOUT_ONLY=REGEX (state names); LAYOUT_MINUTES=N stops measuring after N minutes. Exit 1 when a finding
#               is not in tests/e2e/browser/layout-allowlist.json.
#
#   --compare REF (a tag such as v0.44.3; with --aws-env, and --src/--project/--out/--long-path as above) the UI control
#               inventory across releases: sweeps a detached worktree of REF, then the candidate (--src, default this
#               checkout), with the same widths and themes, and diffs what a user could see and click (JON-869). Both
#               stacks are swept by THIS checkout's ui_sweep.py (an older one does not record controls); only the stack
#               under test comes from REF. Results: OUT/compare/{ref,candidate}/ (as a plain run: run/sweep/controls.json,
#               ...), OUT/compare/inventory-diff.json and the summary on stdout. Exit 1 when a control of REF is gone,
#               disabled or unnamed in the candidate (or a whole state is) unless tests/e2e/browser/ui-removed.json
#               declares it: [{"state": glob of <page>-<state>-<width>-<theme>, "control": "role:name" or "#id" or "*",
#               "why": "...", "changelog": "vX.Y.Z"}] — an entry without why or changelog is rejected. Names are
#               normalized (numbers, times, versions, ids). The Home states with an update available and the update
#               helper running, late or absent are swept for this. tests/e2e/ui_inventory_diff.py OLD NEW is the diff alone.
#
#   --src DIR   the checkout to set up, at its HEAD (default: this one) — e.g. a detached worktree of a release
#   --out DIR   results (default tests/e2e/out/ui-sweep): sweep/shots/<page>-<state>-<width>-<theme>.png,
#               sweep/findings.tsv and .json, sweep/summary.txt, sweep/links.json, sweep/links-pending-release.json
#   SWEEP_WIDTHS=desktop,tablet,phone  SWEEP_THEMES=light,dark   a smaller sweep
#   SWEEP_ONLY=code,off_pages          just those parts (signin portal off_pages walkthrough code errors manifest links)
#   SWEEP_SIZES=desktop=1440x900,tablet=834x1194   other viewports for those widths (e.g. a design review's)
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
PROJECT=bne2e-uisweep; SRC="$ROOT"; AWS_ENV_FILE=''; KEEP=0; TEARDOWN_ONLY=0; OUT_DIR=''; REUSE=0; LONG=0; LAYOUT=''; COMPARE=''
while [ $# -gt 0 ]; do
  case "$1" in
    --aws-env) AWS_ENV_FILE="${2:?}"; shift 2 ;;
    --src) SRC="$(cd "${2:?}" && pwd -P)"; shift 2 ;;
    --project) PROJECT="${2:?}"; shift 2 ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --reuse) REUSE=1; shift ;;
    --long-path) LONG=1; shift ;;
    --layout) LAYOUT="${2:?}"; case "$LAYOUT" in fast | full) ;; *) echo "--layout takes fast or full" >&2; exit 2 ;; esac; shift 2 ;;
    --compare) COMPARE="${2:?}"; shift 2 ;;
    --teardown) TEARDOWN_ONLY=1; shift ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (--help)" >&2; exit 2 ;;
  esac
done

. "$HERE/lib.sh"
. "$ROOT/lib/ports.sh"   # port_in_use
if [ -n "$COMPARE" ]; then   # the sweep twice (REF, then the candidate) and the diff; each run is this script, as a plain run
  { [ -z "$LAYOUT" ] && [ "$REUSE$TEARDOWN_ONLY" = 00 ]; } || die "--compare does not combine with --layout, --reuse or --teardown"
  [ -n "$AWS_ENV_FILE" ] || die "--aws-env FILE is required"
  git -C "$ROOT" rev-parse --verify -q "$COMPARE^{commit}" >/dev/null || die "--compare: no such tag or commit: $COMPARE"
  CMP="${OUT_DIR:-$ROOT/tests/e2e/out/ui-sweep}/compare"; mkdir -p "$CMP"; CMP="$(cd "$CMP" && pwd -P)"
  REFWT="$ROOT/tests/e2e/work/compare-ref-$$"; mkdir -p "$(dirname "$REFWT")"
  trap 'git -C "$ROOT" worktree remove --force "$REFWT" >/dev/null 2>&1; rm -rf "$REFWT"' EXIT
  git -C "$ROOT" worktree add -q --detach "$REFWT" "$COMPARE" || die "cannot make a worktree of $COMPARE"
  rm -rf "$CMP/ref" "$CMP/candidate" "$CMP/inventory-diff.json"
  more=(); [ "$LONG" = 0 ] || more=(--long-path)
  say "compare: sweeping $COMPARE ($(git -C "$REFWT" rev-parse --short HEAD))"
  "$HERE/ui-sweep.sh" --aws-env "$AWS_ENV_FILE" --src "$REFWT" --project "$PROJECT" --out "$CMP/ref" ${more[@]+"${more[@]}"}
  say "compare: sweeping the candidate ($(git -C "$SRC" rev-parse --short HEAD))"
  "$HERE/ui-sweep.sh" --aws-env "$AWS_ENV_FILE" --src "$SRC" --project "$PROJECT" --out "$CMP/candidate" ${more[@]+"${more[@]}"}
  for w in ref candidate; do [ -s "$CMP/$w/run/sweep/controls.json" ] || die "the $w sweep wrote no controls.json (see $CMP/$w/logs and run/sweep.log)"; done
  python3 "$HERE/ui_inventory_diff.py" "$CMP/ref/run/sweep/controls.json" "$CMP/candidate/run/sweep/controls.json" --out "$CMP"
  exit $?
fi
valid_project "$PROJECT" || die "--project must be bne2e or bne2e-<letters, digits, ->: $PROJECT (never a real install's)"
OUT="${OUT_DIR:-$ROOT/tests/e2e/out/ui-sweep}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd -P)"
LOGS="$OUT/logs"; RESULTS="$OUT/results.tsv"; mkdir -p "$LOGS"; : > "$RESULTS"
WORK="$ROOT/tests/e2e/work/$PROJECT"
[ "$LONG" = 0 ] || WORK="$ROOT/tests/e2e/work/ADeliberatelyLongInstallFolderNameWithNoBreakForTheUISweep/$PROJECT"
mkdir -p "$(dirname "$WORK")"
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
LONG_OPT=''; [ "$LONG" = 0 ] || LONG_OPT=' --long-path'
trap 'rc=$?; trap - EXIT INT TERM HUP; if [ "$KEEP" = 0 ]; then teardown; else say "kept: tests/e2e/ui-sweep.sh --teardown --project $PROJECT$LONG_OPT"; fi; exit $rc' EXIT
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
    [ -f "$STACK/.devos-ade-e2e" ] || die "$STACK exists and was not created by this suite — nothing was changed"
    chmod -R u+rwX "$STACK"; rm -rf "$STACK"
  fi
  REV="$(git -C "$SRC" rev-parse HEAD)" || die "$SRC is not a checkout"
  say "staging $SRC at ${REV:0:7} in $STACK"
  ( umask 022; git clone --quiet --no-hardlinks "$SRC" "$STACK" ) || die "git clone failed"
  git -C "$STACK" -c advice.detachedHead=false checkout -q --detach "$REV" || die "cannot check out $REV"
  : > "$STACK/.devos-ade-e2e"; printf '/.devos-ade-e2e\n' >> "$STACK/.git/info/exclude"
  cp "$STACK/.env.example" "$STACK/.env"; chmod 600 "$STACK/.env"
  pick_port P 18780; pick_port L 14780; pick_port M 19165
  set_env COMPOSE_PROJECT_NAME "$PROJECT"; set_env PORTAL_HOST "$HOST"; set_env PORTAL_PORT "$P"
  set_env LITELLM_PORT "$L"; set_env SHARED_MCP_PORT "$M"; set_env OPENWEBUI_ADMIN_EMAIL "you@example.com"
  for kv in $BUDGETS; do set_env "${kv%%=*}" "${kv#*=}"; done
  set_env PORTAL_PASSWORD "$(openssl rand -hex 10)"
  seed_cheap_default   # (new sessions on Haiku: no flow falls back to a dearer model)
  WS="$(terminal_workspace_dir)"; ( umask 077; mkdir -p "$WS" ) && : > "$WS/.devos-ade-e2e"; set_env TERMINAL_WORKSPACE "$WS"
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
if [ -n "$LAYOUT" ]; then
  # the layout sweep; the Code page's mock backend too when code/web has a build and ws (served by the container's own
  # Node, as code/web/e2e/run.sh does; ws from the folder node_modules/ws really is, for a linked node_modules)
  web=(); mockopt=(); WEB="$ROOT/code/web"; WS_DIR="$(cd "$WEB/node_modules/ws" 2>/dev/null && pwd -P)"
  if [ -f "$WEB/dist/index.html" ] && [ -n "$WS_DIR" ]; then web=(-v "$WEB:/web:ro" -v "$WS_DIR:/node_modules/ws:ro"); mockopt=(--mock-web /web); else
    warn "code/web has no build or no node_modules/ws: the Code page's session against its mock backend is left out"; fi
  mkdir -p "$OUT/layout"
  say "the layout sweep ($LAYOUT; log: $OUT/layout/sweep.log)"
  docker rm -f "$PROJECT-layout" >/dev/null 2>&1 || true
  docker run --rm --name "$PROJECT-layout" --init --shm-size=2g "${opts[@]}" ${web[@]+"${web[@]}"} \
    -e E2E_HOST="$HOST" -e E2E_PORT="$P" -e E2E_LITELLM_PORT="$L" -e E2E_MCP_PORT="$M" \
    -e LAYOUT_JOBS="${LAYOUT_JOBS:-3}" -e LAYOUT_ONLY="${LAYOUT_ONLY:-}" -e LAYOUT_MINUTES="${LAYOUT_MINUTES:-0}" \
    -e LAYOUT_HAR="${LAYOUT_HAR:-}" \
    -v "$STACK/.env:/run/e2e/env:ro" -v "$HERE/browser:/suite:ro" -v "$OUT/layout:/out/layout" -v "$OUT/run:/out" \
    -v "$STACK/.state/status:/state/status:ro" -v "$STACK/.state/update-check:/state/update-check" \
    "$PROJECT/e2e-playwright:local" python3 -u /suite/layout_sweep.py --mode "$LAYOUT" --out /out/layout \
      ${mockopt[@]+"${mockopt[@]}"} > "$OUT/layout/sweep.log" 2>&1
  rc=$?
  redact "$OUT/layout/sweep.log"
  tail -n 40 "$OUT/layout/sweep.log" >&2
  exit "$rc"
fi
say "the sweep ($(echo "${SWEEP_WIDTHS:-desktop,tablet,phone}" | tr , ' '), ${SWEEP_THEMES:-light,dark}; log: $OUT/run/sweep.log)"
docker rm -f "$PROJECT-playwright" >/dev/null 2>&1 || true
docker run --rm --name "$PROJECT-playwright" --init --shm-size=1g "${opts[@]}" \
  -e E2E_HOST="$HOST" -e E2E_PORT="$P" -e E2E_LITELLM_PORT="$L" -e E2E_MCP_PORT="$M" \
  -e SWEEP_WIDTHS="${SWEEP_WIDTHS:-desktop,tablet,phone}" -e SWEEP_THEMES="${SWEEP_THEMES:-light,dark}" -e SWEEP_ONLY="${SWEEP_ONLY:-}" -e SWEEP_SIZES="${SWEEP_SIZES:-}" \
  -e SWEEP_NEW_LOGO_SHA="$NEW_LOGO" -e SWEEP_OLD_LOGO_SHA="$OLD_LOGO" -e SWEEP_STACK_PATH="$STACK" -e SWEEP_HOME="$HOME" \
  -v "$STACK/.env:/run/e2e/env:ro" -v "$HERE/browser:/suite:ro" -v "$OUT/run:/out" \
  -v "$STACK/.state/status:/state/status" -v "$STACK/.state/update-check:/state/update-check" \
  -v "$ROOT:/repo:ro" -v "$STACK:/stack:ro" \
  "$PROJECT/e2e-playwright:local" python3 -u /suite/ui_sweep.py > "$OUT/run/sweep.log" 2>&1
rc=$?
redact "$OUT/run/sweep.log"; redact_outputs
tail -n 40 "$OUT/run/sweep.log" >&2
exit "$rc"
