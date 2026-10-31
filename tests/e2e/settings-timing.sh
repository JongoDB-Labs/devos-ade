#!/usr/bin/env bash
# Opt-in end-to-end timing of Settings changes (run by hand; not part of tests/run.sh, CI or tests/e2e/run.sh; JON-533).
# A THROWAWAY DevOS ADE stack (Compose project bne2e-s522 by default, ports of its own, the browser terminal on, the
# Code page off) set up from this checkout — or from --ref REF, to time an older release the same way — with two
# stand-ins: Experiential Labs (tests/e2e/explabs-mock.py on this computer's 127.0.0.1, http: taken only while testing,
# a fake key; its catalog answers gpt-5-mini's details slowly, about 20 s, as the real gateway's did on 2026-10-25) and
# OpenRouter (a fake key: openrouter.ai refuses it and its public model list is used — free, nothing is called). The
# throwaway's own update helper runs in the foreground, as tests/e2e/run.sh --helper runs it. Each kind of change then
# goes through the portal's Settings API as the page sends it (tests/e2e/settings_timing.py) and is timed from the
# request to the helper's Done, with the steps the helper read from its log:
#   budget        BUDGET_SETUP                          xl            EXPLABS_MODELS + gpt-5-mini, then back
#   or            OPENROUTER_MODELS + one model, back   code-models   CODE_DEFAULT_MODEL, then back
#   key           EXPLABS_API_KEY (another fake one)    terminal      TERMINAL_AUTO_MODE, then back
#   websearch     WEBSEARCH_SEARXNG_BUILTIN off, on     remote        REMOTE_ADMIN_ACTIONS on, off
# With targets (the default): a model list in about 5 s with LiteLLM's container kept (its id and start time), one
# restart 20 s at most, nothing over 30 s — and what each did, checked at the source: /v1/models lists the chosen
# models, a call to the new Experiential Labs model reaches the stand-in, the budget is the key's in LiteLLM.
#
#   tests/e2e/settings-timing.sh --aws-env FILE [--ref REF] [--project bne2e-NAME] [--label NAME] [--no-targets]
#                                [--kinds LIST] [--keep | --reuse | --teardown] [--out DIR]
# Costs: setup's model check (1-token requests on Bedrock, < $0.01); every model call afterwards goes to the stand-in.
# Docker runs it: on a machine that shares a heavy-job lock, run it inside that lock. Results: OUT/settings-timing[-LABEL].json,
# OUT/logs/settings-timing[-LABEL]/ (redacted), a table on stderr. Never touches another install: only bne2e[-…]
# projects, their own ports, teardown by exact names (tests/e2e/lib.sh).
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
AVOID_PORTS=" 80 443 3000 3009 4000 8080 8081 8090 8765 8787 8788 8800 "
NOTTY="$HERE/notty"
OUT="$ROOT/tests/e2e/out"; PROJECT=bne2e-s522; AWS_ENV_FILE=''; REF=''; LABEL=''; TARGETS=1
KEEP=0; REUSE=0; TEARDOWN_ONLY=0; KINDS="budget,xl,or,code-models,key,terminal,websearch,remote"
while [ $# -gt 0 ]; do
  case "$1" in
    --aws-env) AWS_ENV_FILE="${2:?--aws-env FILE}"; shift 2 ;;
    --ref) REF="${2:?--ref REF}"; shift 2 ;;
    --project) PROJECT="${2:?--project NAME}"; shift 2 ;;
    --label) LABEL="${2:?--label NAME}"; shift 2 ;;
    --kinds) KINDS="${2:?--kinds LIST}"; shift 2 ;;
    --no-targets) TARGETS=0; shift ;;
    --keep) KEEP=1; shift ;;
    --reuse) REUSE=1; KEEP=1; shift ;;
    --teardown) TEARDOWN_ONLY=1; shift ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    -h | --help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/settings-timing.sh --help)" >&2; exit 2 ;;
  esac
done
case "$LABEL" in '' | [a-z0-9]*) ;; *) echo "--label: lowercase letters, digits and -" >&2; exit 2 ;; esac
case "$LABEL" in *[!a-z0-9-]*) echo "--label: lowercase letters, digits and -" >&2; exit 2 ;; esac

# shellcheck source=tests/e2e/lib.sh
. "$HERE/lib.sh"
# shellcheck source=lib/ports.sh
. "$ROOT/lib/ports.sh"
valid_project "$PROJECT" || { echo "--project: only bne2e or bne2e-<lowercase letters, digits, ->" >&2; exit 2; }
command -v docker >/dev/null && docker info >/dev/null 2>&1 || die "Docker is not running"
mkdir -p "$OUT" || exit 2
OUT="$(cd "$OUT" && pwd -P)"
STACK="$ROOT/tests/e2e/work/$PROJECT"; mkdir -p "$(dirname "$STACK")"
STACK="$(cd "$(dirname "$STACK")" && pwd -P)/$(basename "$STACK")"
SUFFIX="${LABEL:+-$LABEL}"
LOGS="$OUT/logs/settings-timing$SUFFIX"; mkdir -p "$LOGS"
RESULTS="$LOGS/results.tsv"; : > "$RESULTS"
HOST="$PROJECT.localhost"

if [ "$TEARDOWN_ONLY" = 1 ]; then teardown_only; exit 0; fi
if [ -n "$AWS_ENV_FILE" ]; then [ -r "$AWS_ENV_FILE" ] || die "cannot read --aws-env $AWS_ENV_FILE"; load_aws_file "$AWS_ENV_FILE"; fi
[ "$REUSE" = 1 ] || { [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; } || die "no AWS key: pass --aws-env FILE"

# --- the Experiential Labs stand-in: this computer's 127.0.0.1 (./stack reads its list there; LiteLLM's container
# reaches it through a relay settings_timing.py starts in it) ---
MOCK_DIR="$LOGS/mock"; mkdir -p "$MOCK_DIR/catalog"
cp "$ROOT/tests/fixtures/explabs_catalog/"*.json "$MOCK_DIR/catalog/"
cp "$ROOT/tests/fixtures/explabs_v1_models.json" "$MOCK_DIR/v1.json"; : > "$MOCK_DIR/slow"; : > "$MOCK_DIR/reqs.jsonl"
pick_port XL_PORT 18530
python3 -I "$HERE/explabs-mock.py" "$XL_PORT" "$MOCK_DIR/reqs.jsonl" "$MOCK_DIR/v1.json" "$MOCK_DIR/catalog" "$MOCK_DIR/slow" \
  2> "$MOCK_DIR/mock.err" &
MOCK_PID=$!
for _ in $(seq 1 20); do [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$XL_PORT/api/models/qwen3.8-27b" 2>/dev/null)" = 200 ] && break; sleep 0.5; done
TEST_VARS="DEVOS_ADE_TESTING DEVOS_ADE_TEST_EXPLABS_API"
export DEVOS_ADE_TESTING=1 DEVOS_ADE_TEST_EXPLABS_API="http://127.0.0.1:$XL_PORT/v1"
# shellcheck disable=SC2034  # (lib.sh's helper start reads it)
HELPER_KNOBS="SETTINGS_MIN_INTERVAL_S=1 DEVOS_ADE_TESTING=1 DEVOS_ADE_TEST_EXPLABS_API=http://127.0.0.1:$XL_PORT/v1"

finish() {
  local rc=$?
  e2e_helper_stop >/dev/null 2>&1 || true
  kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null
  for f in "$LOGS"/*.log "$OUT/settings-timing$SUFFIX.json"; do [ -f "$f" ] && redact "$f"; done
  if [ "$KEEP" = 1 ]; then say "kept: $STACK (project $PROJECT) — tests/e2e/settings-timing.sh --project $PROJECT --teardown removes it"
  elif [ "${OWNED:-0}" = 1 ]; then teardown; fi
  exit "$rc"
}
trap finish EXIT
trap 'warn "interrupted"; exit 130' INT TERM HUP

# st [--aws] ARGS… — the throwaway's ./stack in a clean environment (the stand-ins' addresses and the AWS key only when
# asked), without a terminal (notty)
st() {
  [ "$(get_env COMPOSE_PROJECT_NAME)" = "$PROJECT" ] || { echo "xx  the throwaway .env does not name project $PROJECT" >&2; return 99; }
  if [ "${1:-}" = --aws ]; then
    shift
    # shellcheck disable=SC2086
    ( export PATH="$HERE/docker-reuse:$PATH" E2E_REAL_DOCKER="$(command -v docker)" E2E_IMAGE_TREE="${E2E_IMAGE_TREE:-}" E2E_IMAGE_LOG="$LOGS/image-cache.log"
      export AWS_REGION_NAME="${AWS_REGION_NAME:-us-east-1}" COMPOSE_PROJECT_NAME="$PROJECT"
      clean_env AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION_NAME COMPOSE_PROJECT_NAME E2E_REAL_DOCKER E2E_IMAGE_TREE E2E_IMAGE_LOG $TEST_VARS
      cd "$STACK" && exec "$NOTTY" "$STACK/stack" "$@" </dev/null )
  else
    # shellcheck disable=SC2086
    ( clean_env $TEST_VARS; cd "$STACK" && exec "$NOTTY" "$STACK/stack" "$@" </dev/null )
  fi
}

stage() {
  local pp lp mp tws f
  say "staging $STACK from ${REF:-this working tree}"
  claim_project
  [ "$OWN_STATE" != ours ] || { warn "project $PROJECT: $OWN_WHY — removing those leftovers first"; teardown; }
  if [ -e "$STACK" ]; then
    [ -f "$STACK/.devos-ade-e2e" ] || [ -z "$(ls -A "$STACK" 2>/dev/null)" ] || die "$STACK was not created by this suite"
    chmod -R u+rwX "$STACK" 2>/dev/null; rm -rf "$STACK"
  fi
  ( umask 022; git clone --quiet --no-hardlinks "$ROOT" "$STACK" ) || die "git clone failed"
  : > "$STACK/.devos-ade-e2e"; printf '/.devos-ade-e2e\n' >> "$STACK/.git/info/exclude"
  if [ -n "$REF" ]; then
    git -C "$STACK" -c advice.detachedHead=false checkout -q "$(git -C "$ROOT" rev-parse "$REF^{commit}")" || die "no such ref: $REF"
  else
    if ! (cd "$ROOT" && git diff --quiet HEAD); then
      ( cd "$ROOT" && git diff HEAD --binary ) | ( umask 022; git -C "$STACK" apply --whitespace=nowarn ) || die "the working tree's changes do not apply"
    fi
    ( cd "$ROOT" && git ls-files --others --exclude-standard -z ) | while IFS= read -r -d '' f; do
      case "$f" in tests/e2e/out/* | tests/e2e/work/*) continue ;; esac
      ( umask 022; mkdir -p "$STACK/$(dirname "$f")" && cp -p "$ROOT/$f" "$STACK/$f" ) || exit 1
    done || die "could not copy the untracked files"
    git -C "$STACK" add -A
    git -C "$STACK" -c user.name=devos-ade-e2e -c user.email=e2e@example.invalid commit -q -m "e2e: working tree" --allow-empty
  fi
  cp "$STACK/.env.example" "$STACK/.env"; chmod 600 "$STACK/.env"
  pick_port pp 18580; pick_port lp 14580; pick_port mp 18965
  set_env COMPOSE_PROJECT_NAME "$PROJECT"; set_env PORTAL_HOST "$HOST"; set_env PORTAL_PORT "$pp"
  set_env LITELLM_PORT "$lp"; set_env SHARED_MCP_PORT "$mp"
  set_env OPENWEBUI_ADMIN_EMAIL "e2e-admin@example.com"
  set_env BUDGET_CLAUDE_CODE 0.04; set_env BUDGET_OPENWEBUI 0.04; set_env BUDGET_SETUP 0.02; set_env BUDGET_TERMINAL 0.04
  set_env PORTAL_PASSWORD "$(openssl rand -hex 10)"
  seed_cheap_default
  # the terminal on (a terminal setting is one of the kinds), the Code page off (not timed here: its own image)
  tws="$(terminal_workspace_dir)"
  [ ! -e "$tws" ] || [ -f "$tws/.devos-ade-e2e" ] || die "$tws exists and was not created by this suite"
  ( umask 077; mkdir -p "$tws" ) && : > "$tws/.devos-ade-e2e"
  set_env TERMINAL_WORKSPACE "$tws"; set_env CODE_ENABLED false; set_env TERMINAL_ENABLED true
  # the stand-ins' fake keys (made here; the stand-in takes any)
  set_env EXPLABS_API_KEY "xpl_$(openssl rand -hex 20)"; set_env EXPLABS_MODELS qwen3.8-27b
  set_env OPENROUTER_API_KEY "sk-or-v1-$(openssl rand -hex 32)"; set_env OPENROUTER_MODELS "openai/gpt-4o-mini"
  ( umask 022; mkdir -p "$STACK/.state/update-check" ); chmod 700 "$STACK/.state"; : > "$STACK/.state/portal-password-shown"
  printf '{"checked_at": "%s", "error": null}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$STACK/.state/update-check/latest.json"
  chmod 644 "$STACK/.state/update-check/latest.json"
  E2E_IMAGE_TREE="$(git -C "$STACK" rev-parse 'HEAD^{tree}')"
}

if [ "$REUSE" = 1 ]; then
  reuse_check; say "reusing $STACK"
else
  stage
  say "setup (a few minutes; log: $LOGS/setup.log)"
  t0="$(now)"
  st --aws setup --yes > "$LOGS/setup.log" 2>&1 || { redact "$LOGS/setup.log"; tail -n 40 "$LOGS/setup.log" >&2; die "setup failed"; }
  redact "$LOGS/setup.log"
  record setup setup PASS "$(( $(now) - t0 ))" "$(tail -n 1 "$LOGS/setup.log")"
  # (the suite's image cache is shared with tests/e2e/run.sh and other runs: read and added to here, never pruned)
fi
for k in PORTAL_PORT LITELLM_PORT SHARED_MCP_PORT; do case "$AVOID_PORTS" in *" $(get_env "$k") "*) die "a reserved port ($k)" ;; esac; done
spend_start

# the OpenRouter model to add: one of its public list (as setup cached it) that is not chosen already
OR_ADD="$(awk -F'\t' '!/^#/ && $1 != "openai/gpt-4o-mini" && $8 == "paid" && $1 ~ /^[a-z0-9-]+\/[a-z0-9.-]+$/ { print $1; exit }' "$STACK/litellm/openrouter-models.tsv" 2>/dev/null)"
[ -n "$OR_ADD" ] || warn "no OpenRouter model list cached (openrouter.ai not reachable?): the or kind will fail"
# from here on gpt-5-mini's details come slowly, as a model the gateway's catalog is asked about for the first time
printf 'gpt-5-mini\n' > "$MOCK_DIR/slow"

say "the throwaway's update helper"
e2e_helper_start || die "the helper did not start"

say "timing: $KINDS"
rc=0
( clean_env E2E_HOST E2E_PORT E2E_PW E2E_LITELLM_PORT E2E_STACK E2E_PROJECT E2E_KINDS E2E_OUT E2E_MOCK_LOG E2E_XL_PORT E2E_OR_ADD E2E_TARGETS E2E_LABEL
  E2E_HOST="$HOST" E2E_PORT="$(get_env PORTAL_PORT)" E2E_PW="$(get_env PORTAL_PASSWORD)" E2E_LITELLM_PORT="$(get_env LITELLM_PORT)" \
  E2E_STACK="$STACK" E2E_PROJECT="$PROJECT" E2E_KINDS="$KINDS" E2E_OUT="$OUT/settings-timing$SUFFIX.json" \
  E2E_MOCK_LOG="$MOCK_DIR/reqs.jsonl" E2E_XL_PORT="$XL_PORT" E2E_OR_ADD="$OR_ADD" E2E_TARGETS="$TARGETS" E2E_LABEL="${LABEL:-${REF:-working-tree}}" \
  exec python3 -I "$HERE/settings_timing.py" ) 2> >(tee "$LOGS/timing.log" >&2) || rc=$?
e2e_helper_stop

# spend by model (LiteLLM's spend log of the throwaway, since setup): setup's probe, and the stand-in's fake costs
python3 -I - "$STACK/.env" <<'PY' > "$LOGS/spend-by-model.log" 2>&1 || true
import json, sys, urllib.request
env = dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[1]) if "=" in l and not l.startswith("#"))
req = urllib.request.Request(f"http://127.0.0.1:{env['LITELLM_PORT']}/spend/logs?summarize=false", headers={"Authorization": "Bearer " + env["LITELLM_MASTER_KEY"]})
rows = json.load(urllib.request.urlopen(req, timeout=60))
by = {}
for r in rows if isinstance(rows, list) else []:
    m = r.get("model") or r.get("model_group") or "?"
    by[m] = by.get(m, 0.0) + float(r.get("spend") or 0)
for m, s in sorted(by.items(), key=lambda x: -x[1]):
    print(f"{s:.6f}\t{m}")
PY
say "spend by model (USD; xl/… is the stand-in's fake cost):"; sed 's/^/  /' "$LOGS/spend-by-model.log" >&2
total="$(spend_total 2>/dev/null || echo '?')"; say "spend in this run (LiteLLM): \$$total"
exit "$rc"
