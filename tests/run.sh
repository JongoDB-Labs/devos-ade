#!/usr/bin/env bash
# Minimal bash-3.2 test runner: runs every function named test_* in tests/test_*.sh, each in a fresh subshell with a
# throwaway ENV_FILE, HOME and TMPDIR. Usage: tests/run.sh [-j N] [file-glob]
#   - -j N: N tests at a time (default: one less than this computer's CPUs, at most 8); -j 1: one after another. What
#     it prints does not depend on N: each test's line in the order of its file, then the guards and the counts.
#   - A test that returns 77 is reported as SKIPPED (print the reason to stderr first).
#   - A test file with a syntax error or no test_* functions counts as a failure.
# Child shells use "$BASH" (the interpreter running this script), so `/bin/bash tests/run.sh`
# really exercises bash 3.2 even when a newer bash is first on PATH. Paths reach the child
# via environment variables, never by interpolation into the script text.
set -uo pipefail
exec </dev/null   # no test reads this terminal (or an open pipe) and waits for ever
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
SH="${BASH:-bash}"
jobs=''
case "${1:-}" in
  -j) [ $# -ge 2 ] || { echo "usage: tests/run.sh [-j N] [file-glob]" >&2; exit 2; }; jobs="$2"; shift 2 ;;
  -j?*) jobs="${1#-j}"; shift ;;
esac
if [ -z "$jobs" ]; then
  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
  case "$jobs" in '' | *[!0-9]*) jobs=2 ;; esac
  jobs=$((jobs - 1)); [ "$jobs" -le 8 ] || jobs=8; [ "$jobs" -ge 1 ] || jobs=1
fi
case "$jobs" in '' | *[!0-9]* | 0*) echo "tests/run.sh: -j takes how many tests run at a time (1 or more), not '$jobs'" >&2; exit 2 ;; esac
pattern="${1:-tests/test_*.sh}"
pass=0; fail=0; skip=0

# Isolation from the real machine (a live bedrock-now may run on 127.0.0.1:80/4000/8765): every test child has
# tests/shims first on PATH. docker, aws, tailscale, gh and glab never run for real; curl does, except towards this
# computer (only the closed port 9 there). A refused call is logged to $BN_SHIM_LOG (each test's own, gathered into
# the suite's at the end); any entry fails the suite.
# BN_REAL_DOCKER is for the one test that renders compose.yaml (`docker compose config`: no daemon, no containers).
BN_SHIM_LOG="$(mktemp)"; BN_REAL_CURL="$(command -v curl || echo /usr/bin/curl)"; BN_REAL_DOCKER="$(command -v docker || true)"
# openssl is real too; only its PBKDF2 derivation (600,000 real rounds) is cached for the run (tests/shims/openssl)
BN_REAL_OPENSSL="$(command -v openssl || echo /usr/bin/openssl)"; BN_PBKDF2_CACHE="$(mktemp -d)"
# Every test child gets a home of its own ($TMP/home): nothing a test runs (setup turns the Code page on with
# ~/bedrock-now-workspace; devos-claude makes ~/.claude-bedrock) can touch your real one. Only the real docker of the
# compose-rendering tests still reads its CLI plugins from your Docker config folder (DOCKER_CONFIG).
BN_REAL_DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME:-/nonexistent}/.docker}"
export BN_SHIM_LOG BN_REAL_CURL BN_REAL_DOCKER BN_REAL_OPENSSL BN_PBKDF2_CACHE BN_REAL_DOCKER_CONFIG
# The run's own folder: R/I for test I, its TMPDIR (tests running at the same time never share a temporary folder),
# and beside it what the runner keeps of it (I.job: its file and name; I.stamp, I.shim, I.sec, I.out, I.res); R/done,
# where each test's runner says it has ended
tmp="${TMPDIR:-/tmp}"; tmp="${tmp%/}"
R="$(mktemp -d "$tmp/bn-tests.XXXXXX")" || exit 1
mkfifo "$R/done" || exit 1
# How long each test took on this checkout's last run (seconds, file, test), so the slow ones start first: two tests take
# minutes, more than a tenth of each test slot's share of the suite. Only the order of starting depends on it.
times_file="$tmp/bn-tests-times.$(printf '%s' "$ROOT" | cksum | awk '{ print $1 }')"

# No EXIT trap in the child: bash 3.2 reports exit status 0 from an EXIT trap after fatal
# errors (unbound variable, failed `.`), which would turn real failures into passes.
# shellcheck disable=SC2016,SC2089
CHILD='
TMP=$(mktemp -d)
export STACK_DIR="$T_ROOT" ENV_FILE="$TMP/.env" STATE_DIR="$TMP/.state" BEDROCK_NOW_NO_OPEN=1 PATH="$T_ROOT/tests/shims:$PATH"
# dc() never asks the Compose version in a test (a test that stubs docker would see an extra call): the docs overlay off
export BEDROCK_NOW_COMPOSE_CONTEXTS=0 BEDROCK_NOW_COMPOSE_OVERRIDES=1
export HOME="$TMP/home" DOCKER_CONFIG="$BN_REAL_DOCKER_CONFIG"; mkdir -p "$HOME"
( set -euo pipefail
  . lib/common.sh; . lib/ports.sh; . lib/portal.sh; . lib/models.sh; . lib/prices.sh; . tests/assert.sh
  . "$T_FILE"
  "$T_NAME" )
rc=$?; rm -rf "$TMP"; exit $rc'

# Live-state guard: tests must never touch this checkout's real .env, .state/, litellm/ or backups/.
_live_state() { (cd "$ROOT" && find .env .state litellm backups -type f 2>/dev/null | LC_ALL=C sort | xargs cksum 2>/dev/null) || true; }
live_before="$(_live_state)"
# devos-claude creates ~/.claude-bedrock (its own Claude Code config folder): tests run it with a throwaway HOME.
# Only its appearance is checked — a devos-claude of yours running meanwhile may change what is inside.
cb_home_before=0; [ ! -e "${HOME:-/nonexistent}/.claude-bedrock" ] || cb_home_before=1
# Setup turns the Code page on by default with the workspace ~/devos-ade-workspace (~/bedrock-now-workspace for an
# install made before v0.25.0: lib/terminal.sh terminal_default_workspace): a test that runs it unstubbed must not
# create that folder in your real home.
ws_home_before=0; [ ! -e "${HOME:-/nonexistent}/bedrock-now-workspace" ] || ws_home_before=1
wsn_home_before=0; [ ! -e "${HOME:-/nonexistent}/devos-ade-workspace" ] || wsn_home_before=1
home_watch=''   # (those of them not there before the suite)
[ "$cb_home_before" = 1 ] || home_watch="$home_watch .claude-bedrock"
[ "$ws_home_before" = 1 ] || home_watch="$home_watch bedrock-now-workspace"
[ "$wsn_home_before" = 1 ] || home_watch="$home_watch devos-ade-workspace"
# ~/.local/bin/devos-claude and claude-bedrock, its old name (lib/commands.sh offer_symlink): read only (what each is,
# where it points), never changed — the tests link and unlink in their own home.
_links_state() { local n; for n in devos-claude claude-bedrock; do printf '%s %s|' "$n" "$(ls -ld "${HOME:-/nonexistent}/.local/bin/$n" 2>/dev/null | awk '{ $6 = $7 = $8 = ""; print }')"; done; }
links_before="$(_links_state)"

# The guards, after every test too, so the test that tripped one fails by name (the checks at the end only say that
# the suite did): what it wrote in this checkout's .env, .state/, litellm/ or backups/ — a file, or a temp file made
# and removed there (its folder's time) — even when the bytes stayed the same, a call it made that the shims refused,
# a folder it created in your real home. A write that changes nothing but a time stamp still fails: a test that
# writes there only when the checkout's files differ from what it writes (right after a pull) fails on every run.
# With tests running at the same time, a write in this checkout (or a folder in your home) also fails the others that
# were running when it happened: the suite fails either way, and the test that did it is among those named.
# JOB I — test I (R/I.job: its file, then its name) and its guards: R/I.out and R/I.res, then I on R/done. xargs runs
# it ($SH -c "$JOB" _ I), in this runner's process group, so a test gets the signals a test run one after another gets
# (a shell's background job would start with Ctrl-C ignored).
read -r -d '' JOB <<'EOF' || true
set -uo pipefail
exec </dev/null
R="$BN_RUN_DIR" ROOT="$BN_RUN_ROOT" SH="$BN_RUN_SH" CHILD="$BN_RUN_CHILD" HW="$BN_RUN_HOME_WATCH"
unset BN_RUN_DIR BN_RUN_ROOT BN_RUN_SH BN_RUN_CHILD BN_RUN_HOME_WATCH   # (the test's environment: as before)
i="$1"; t0=$SECONDS
[ -f "$R/$i.job" ] || exit 0
_homes_there() { local w; HT=''; for w in $HW; do [ ! -e "${HOME:-/nonexistent}/$w" ] || HT="$HT $w"; done; }
{ IFS= read -r f; IFS= read -r t; } < "$R/$i.job"
mkdir "$R/$i"; : > "$R/$i.shim"; _homes_there; before="$HT "
: > "$R/$i.stamp"
out="$(TMPDIR="$R/$i" BN_SHIM_LOG="$R/$i.shim" T_ROOT="$ROOT" T_FILE="$f" T_NAME="$t" "$SH" -c "$CHILD" 2>&1)"; rc=$?
g=''
w="$( (cd "$ROOT" && find .env .state litellm backups -newer "$R/$i.stamp" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ') || true)"
[ -z "$w" ] || g="${g}live-state guard: changed in this checkout while it ran: $w
"
[ ! -s "$R/$i.shim" ] || g="${g}isolation guard: refused while it ran:
$(cat "$R/$i.shim")
"
_homes_there
for w in $HT; do
  case "$before" in *" $w "*) ;; *) g="${g}live-state guard: ~/$w appeared in your real home while it ran
" ;; esac
done
[ -z "$g" ] || { rc=1; out="${out:+$out
}${g%
}"; }
case "$rc" in
  0) r=pass; printf 'ok   %s\n' "$t" ;;
  77) r=skip; printf 'skip %s (%s)\n' "$t" "$(printf '%s' "$out" | tail -n 1)" ;;
  *) r="fail $t (${f##*/})"; printf 'FAIL %s\n%s\n' "$t" "$out" | sed 's/^/     /' ;;
esac > "$R/$i.out"
echo "$((SECONDS - t0))" > "$R/$i.sec"; printf '%s\n' "$r" > "$R/$i.res"
echo "$i" > "$R/done"
EOF
BN_RUN_DIR="$R" BN_RUN_ROOT="$ROOT" BN_RUN_SH="$SH" BN_RUN_CHILD="$CHILD" BN_RUN_HOME_WATCH="$home_watch"
# shellcheck disable=SC2090  # (the child's script, as text)
export BN_RUN_DIR BN_RUN_ROOT BN_RUN_SH BN_RUN_CHILD BN_RUN_HOME_WATCH
failed=''   # what failed, for the last line: a test (its file), a test file, a guard
_failed() { failed="${failed:+$failed, }$1"; }

# The list, in order: each test of each file (R/I.job, and a line of R/list), or a file that cannot run (its R/I.out
# and R/I.res at once)
n=0; : > "$R/list"
for f in $pattern; do
  n=$((n + 1))
  if ! err="$("$SH" -n "$f" 2>&1)"; then
    printf 'FAIL %s (syntax error)\n%s\n' "$f" "$err" | sed 's/^/     /' > "$R/$n.out"; printf 'fail %s (syntax error)\n' "$f" > "$R/$n.res"
    continue
  fi
  tests="$(T_FILE="$f" "$SH" -c '. "$T_FILE" >/dev/null 2>&1; declare -F' | awk '$3 ~ /^test_/ { print $3 }')"
  if [ -z "$tests" ]; then
    printf 'FAIL %s (defines no test_* functions)\n' "$f" > "$R/$n.out"; printf 'fail %s (no test_* functions)\n' "$f" > "$R/$n.res"
    continue
  fi
  n=$((n - 1))
  for t in $tests; do n=$((n + 1)); printf '%s\n%s\n' "$f" "$t" > "$R/$n.job"; printf '%s\t%s\t%s\n' "$n" "$f" "$t" >> "$R/list"; done
done
# The order they start in: those that took at least a tenth of a slot's share of the whole on the last run (a times file
# of this user's only), slowest first, then the others in the list's order (their lines are printed as they end)
_times_ours() { [ -f "$times_file" ] && [ ! -L "$times_file" ] && [ -O "$times_file" ]; }
{ ! _times_ours || cat "$times_file"; } > "$R/times.last" 2>/dev/null
m=0
while read -r i; do m=$((m + 1)); order[m]="$i"; done < <(
  awk -F'\t' -v j="$jobs" 'FILENAME == ARGV[1] { s[$2 "\t" $3] = $1 + 0; next }
    { k = $2 "\t" $3; h[FNR] = (k in s) ? s[k] : 0; id[FNR] = $1; sum += h[FNR]; n = FNR }
    END { for (x = 1; x <= n; x++) print ((sum > 0 && h[x] * j * 10 >= sum) ? h[x] : 0) "\t" id[x] }' \
    "$R/times.last" "$R/list" | sort -s -t "$(printf '\t')" -k1,1nr | cut -f2)

# _printer — each test's lines in the list's order as soon as it and every one before it have ended (each says so on
# R/done; "end" there: xargs is done, and a test without a result fails), then the counts in R/counts
_printer() {
  local shown=0 i x r t l f over=0; local -a ended
  exec 3<>"$R/done"
  while :; do
    while [ "$shown" -lt "$n" ]; do
      x=$((shown + 1))
      [ -f "$R/$x.res" ] || break
      [ ! -f "$R/$x.job" ] || [ -n "${ended[$x]:-}" ] || break
      shown="$x"
      read -r r t < "$R/$x.res"
      case "$r" in
        pass) pass=$((pass + 1)); IFS= read -r l < "$R/$x.out"; printf '%s\n' "$l" ;;
        skip) skip=$((skip + 1)); IFS= read -r l < "$R/$x.out"; printf '%s\n' "$l" ;;
        *) fail=$((fail + 1)); _failed "$t"; cat "$R/$x.out" ;;
      esac
    done
    [ "$over" = 0 ] || break
    IFS= read -r i <&3 || break
    if [ "$i" = end ]; then   # (a test whose runner ended without its result, or one never started: never a pass)
      over=1; x=$((shown + 1))
      while [ "$x" -le "$n" ]; do
        if [ -f "$R/$x.job" ] && [ ! -f "$R/$x.res" ]; then
          { IFS= read -r f; IFS= read -r t; } < "$R/$x.job"
          if [ -d "$R/$x" ]; then printf '     FAIL %s\n     the runner of this test ended without its result\n' "$t"
          else printf '     FAIL %s\n     not run: the run stopped before it\n' "$t"; fi > "$R/$x.out"
          printf 'fail %s (%s)\n' "$t" "${f##*/}" > "$R/$x.res"
        fi
        ended[x]=1; x=$((x + 1))
      done
    else ended[i]=1; fi
  done
  printf '%s %s %s\n%s\n' "$pass" "$skip" "$fail" "$failed" > "$R/counts"
}
# Ctrl-C (the tests get it too, as one after another) or a TERM: everything this run started ends, its files go
_stop() {
  local p
  p="$(ps -A -o pid= -o ppid= 2>/dev/null | awk -v r="$$" '{ p[$1] = $2 } END { t[r] = 1
    do { c = 0; for (x in p) if (!(x in t) && (p[x] in t)) { t[x] = 1; c = 1 } } while (c); for (x in t) if (x != r) print x }')"
  # shellcheck disable=SC2086  # (process ids, a word each)
  [ -z "$p" ] || kill -TERM $p 2>/dev/null
  rm -rf "${R:?}" "${BN_PBKDF2_CACHE:?}"; rm -f "$BN_SHIM_LOG"
}
trap '_stop; exit 130' INT
trap '_stop; exit 143' TERM HUP
exec 3<>"$R/done"   # (the runner's own end of R/done: saying "end" there never waits)
_printer & printer=$!
# Up to $jobs tests at a time, in the order above
if [ "$m" -gt 0 ]; then
  k=1; while [ "$k" -le "$m" ]; do printf '%s\n' "${order[$k]}"; k=$((k + 1)); done > "$R/order"
  xargs -n 1 -P "$jobs" "$SH" -c "$JOB" _ < "$R/order" 3>&-
fi
echo end >&3
wait "$printer"; exec 3>&-
{ read -r pass skip fail; IFS= read -r failed; } < "$R/counts"
# What the shims refused, test after test (a call made after its test was judged is still caught here), and each
# test's time for the next run (those of tests not run this time kept)
i=1; while [ "$i" -le "$n" ]; do [ ! -s "$R/$i.shim" ] || cat "$R/$i.shim" >> "$BN_SHIM_LOG"; i=$((i + 1)); done
awk -F'\t' -v r="$R" '{ f = r "/" $1 ".sec"; if ((getline s < f) > 0) print s "\t" $2 "\t" $3; close(f) }' "$R/list" > "$R/times"
if [ -s "$R/times" ] && { [ ! -e "$times_file" ] || _times_ours; }; then
  awk -F'\t' 'FILENAME == ARGV[1] { s[$2 "\t" $3] = 1; print; next } { k = $2 "\t" $3 } !(k in s)' "$R/times" "$R/times.last" > "$R/times.all" &&
    mv -f "$R/times.all" "$times_file" 2>/dev/null || true
fi
rm -rf "${R:?}"
if [ "$(_live_state)" != "$live_before" ]; then
  fail=$((fail + 1)); _failed "live-state guard"
  printf 'FAIL live-state guard: the suite modified real files in .env/.state/litellm/backups:\n'
  # (cksum lines are "CRC SIZE PATH": the paths only)
  { printf '%s\n' "$live_before"; _live_state; } | awk 'NF { c[$0]++ } END { for (l in c) if (c[l] == 1) { sub(/^[^ ]+ [^ ]+ /, "", l); print "     " l } }' | LC_ALL=C sort -u
fi
if [ "$cb_home_before" = 0 ] && [ -e "${HOME:-/nonexistent}/.claude-bedrock" ]; then
  fail=$((fail + 1)); _failed "live-state guard (~/.claude-bedrock)"
  printf 'FAIL live-state guard: the suite created ~/.claude-bedrock in your real home (remove it)\n'
fi
if [ "$ws_home_before" = 0 ] && [ -e "${HOME:-/nonexistent}/bedrock-now-workspace" ]; then
  fail=$((fail + 1)); _failed "live-state guard (~/bedrock-now-workspace)"
  printf 'FAIL live-state guard: the suite created ~/bedrock-now-workspace in your real home (remove it)\n'
fi
if [ "$wsn_home_before" = 0 ] && [ -e "${HOME:-/nonexistent}/devos-ade-workspace" ]; then
  fail=$((fail + 1)); _failed "live-state guard (~/devos-ade-workspace)"
  printf 'FAIL live-state guard: the suite created ~/devos-ade-workspace in your real home (remove it)\n'
fi
if [ "$(_links_state)" != "$links_before" ]; then
  fail=$((fail + 1)); _failed "live-state guard (~/.local/bin)"
  printf 'FAIL live-state guard: the suite changed ~/.local/bin/devos-claude or ~/.local/bin/claude-bedrock in your real home\n'
fi
if [ -s "$BN_SHIM_LOG" ]; then
  fail=$((fail + 1)); _failed "isolation guard"
  printf 'FAIL isolation guard: tests called real docker/aws/tailscale/gh/glab or curl to this computer\n'
  sed 's/^/     /' "$BN_SHIM_LOG"
else
  printf 'isolation guard: no real docker/aws/tailscale/gh/glab call and no curl to this computer\n'
fi
rm -f "$BN_SHIM_LOG"; rm -rf "${BN_PBKDF2_CACHE:?}"
printf '\n%d passed, %d skipped, %d failed%s\n' "$pass" "$skip" "$fail" "${failed:+: $failed}"
[ "$fail" -eq 0 ]
