#!/bin/sh
# The sandbox's own AI tools (terminal/Dockerfile's ai-tools stage; README "Your AI subscriptions"): each provider's
# unmodified command-line client, pinned here and checked before anything of it is kept — npm packages by `npm ci`
# against their lockfile (SHA-512 per tarball, the platform's native package included; no install scripts run), release
# tarballs by SHA-256: Codex's and Copilot's as their GitHub releases list them, Cursor's as DevOS ADE saw it on
# 2026-10-23 (Cursor publishes no checksum: a file that changed since is not kept). Nothing here signs in, and nothing
# is changed in what is installed. Each lands in /out/<tool>/, owned by root and read-only to everyone else, and
# /out/VERSIONS says which version. A tool whose download or check fails is left out of the image — said here and in
# /out/SKIPPED (its launcher says so too) — and the others are kept.
#
#   BN_AI_TOOLS   all (default) | none | a comma list of codex, gemini, copilot, cursor, grok — TERMINAL_AI_TOOLS in .env
#                 (Claude Code is always in the image: it is the sandbox's own)
#
# Installed once per pin: each tool, once installed and checked, is kept in the build's own cache (BN_TOOLS_CACHE: the
# Dockerfile's RUN --mount=type=cache), under the hash of what it is — its pinned version and checksums, or its
# package.json and lockfile, the platform and, for the npm ones, the base image's Node (tool_key). The next build takes
# it from there as long as that hash is the same: an edit of this script or of npm's network flags (which makes Docker
# run this stage again) costs a copy, never a download; only a new pin installs that tool again — and only that tool.
# The tools install side by side, each in its own folders. Nothing is changed in what is kept: the checks below run on
# /out every time. (The cache is the builder's own, like its layers: whoever can change it can change any image.)
set -eu

TOOLS_ALL="codex gemini copilot cursor grok"
TOOLS_SRC="${BN_TOOLS_SRC:-/tmp/tools}"
CACHE="${BN_TOOLS_CACHE:-/var/cache/bn-tools}"
RES=/tmp/bn-tools-res
# (what a tool's folder holds and how it is made: one more when that changes, so nothing kept from before is taken)
TOOLS_LAYOUT=1

# fetch URL SHA256 FILE — the file, kept only when its SHA-256 is the pinned one
fetch() {
  curl -fsSL --retry 3 -o "$3" "$1" || { echo "ai-tools: $1 could not be downloaded" >&2; return 1; }
  echo "$2  $3" | sha256sum -c - >/dev/null 2>&1 || { echo "ai-tools: $1 is not the file pinned here (SHA-256 differs)" >&2; return 1; }
}
# npm_tool NAME — terminal/tools/NAME's lockfile, as is
npm_tool() {
  mkdir -p "/out/$1"
  cp "$TOOLS_SRC/$1/package.json" "$TOOLS_SRC/$1/package-lock.json" "/out/$1/"
  (cd "/out/$1" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error --fetch-retries=5 --fetch-retry-maxtimeout=120000 --fetch-timeout=300000 --cache "/tmp/npm-cache-$1")
}

# One tool each (run in a subshell that stops at its first failure: the tool is then left out, the others stay)
tool_codex() {
  # OpenAI's Codex CLI: the static (musl) binary of the release, renamed to codex as its README says
  v="$CODEX_VERSION"
  if [ "$arch" = amd64 ]; then a=x86_64; sum="$CODEX_SHA256_AMD64"; else a=aarch64; sum="$CODEX_SHA256_ARM64"; fi
  fetch "https://github.com/openai/codex/releases/download/rust-v$v/codex-$a-unknown-linux-musl.tar.gz" "$sum" /tmp/codex.tgz
  mkdir -p /out/codex /tmp/codex
  tar --no-same-owner -xzf /tmp/codex.tgz -C /tmp/codex "codex-$a-unknown-linux-musl"
  install -m 755 "/tmp/codex/codex-$a-unknown-linux-musl" /out/codex/codex
  /out/codex/codex --version | grep -qx "codex-cli $v"
  echo "codex $v" > "$RES/codex.version"
}
tool_copilot() {
  # GitHub's Copilot CLI: the release's standalone binary. At its first run it unpacks its own package (its
  # JavaScript, ~220 MB) into a cache folder and runs it from there: done here, into the image (copilot/cache), so the
  # code it runs is never in the sandbox's writable home (the launcher points COPILOT_PKG_CACHE_HOME there)
  v="$COPILOT_VERSION"
  if [ "$arch" = amd64 ]; then a=x64; sum="$COPILOT_SHA256_AMD64"; else a=arm64; sum="$COPILOT_SHA256_ARM64"; fi
  fetch "https://github.com/github/copilot-cli/releases/download/v$v/copilot-linux-$a.tar.gz" "$sum" /tmp/copilot.tgz
  mkdir -p /out/copilot/cache
  tar --no-same-owner -xzf /tmp/copilot.tgz -C /out/copilot copilot
  chmod 755 /out/copilot/copilot
  COPILOT_AUTO_UPDATE=false COPILOT_PKG_CACHE_HOME=/out/copilot/cache HOME=/tmp/copilot-home /out/copilot/copilot --version | grep -q "CLI $v\."
  ls /out/copilot/cache/pkg/linux-"$a"/"$v"/.extraction-complete >/dev/null
  echo "copilot $v" > "$RES/copilot.version"
}
tool_cursor() {
  # Cursor's CLI: the package its own installer (cursor.com/install) downloads, for this version
  v="$CURSOR_VERSION"
  if [ "$arch" = amd64 ]; then a=x64; sum="$CURSOR_SHA256_AMD64"; else a=arm64; sum="$CURSOR_SHA256_ARM64"; fi
  fetch "https://downloads.cursor.com/lab/$v/linux/$a/agent-cli-package.tar.gz" "$sum" /tmp/cursor.tgz
  mkdir -p /tmp/cursor
  tar --no-same-owner -xzf /tmp/cursor.tgz -C /tmp/cursor
  mv /tmp/cursor/dist-package /out/cursor
  NODE_DISABLE_COMPILE_CACHE=1 HOME=/tmp/cursor-home /out/cursor/cursor-agent --version 2>/dev/null | grep -qx "$v"
  echo "cursor $v" > "$RES/cursor.version"
}
tool_gemini() {
  npm_tool gemini
  v="$(node -p 'require("/out/gemini/node_modules/@google/gemini-cli/package.json").version')"
  echo "gemini $v" > "$RES/gemini.version"
}
tool_grok() {
  # its npm package ships the binary brotli-compressed; its own postinstall unpacks it into ~/.grok/bin at first run (a
  # home folder the sandbox can write, and its updater's place). Unpacked here instead, the same way, into the
  # read-only image: grok/grok is what the launcher runs
  npm_tool grok
  v="$(node -p 'require("/out/grok/node_modules/@xai-official/grok/package.json").version')"
  if [ "$arch" = amd64 ]; then a=x64; else a=arm64; fi
  node -e 'const fs = require("fs"), zlib = require("zlib");
    fs.writeFileSync(process.argv[2], zlib.brotliDecompressSync(fs.readFileSync(process.argv[1])), { mode: 0o755 });' \
    "/out/grok/node_modules/@xai-official/grok-linux-$a/bin/grok.br" /out/grok/grok
  GROK_DISABLE_AUTOUPDATER=1 HOME=/tmp/grok-home /out/grok/grok --version 2>/dev/null | grep -q "$v"
  echo "grok $v" > "$RES/grok.version"
}

# sha256 < DATA -> its SHA-256 (hex)
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

# tool_key TOOL ARCH -> the hash of what is installed for TOOL on ARCH (amd64 | arm64): its pinned version and both
# checksums (Codex, Copilot, Cursor), or its package.json and lockfile and the Node it is installed with (Gemini CLI,
# Grok Build). Never this script's text, nor npm's or curl's flags: those change how, not what.
tool_key() {
  { echo "layout $TOOLS_LAYOUT"; echo "tool $1"; echo "arch $2"
    case "$1" in
      codex) echo "$CODEX_VERSION $CODEX_SHA256_AMD64 $CODEX_SHA256_ARM64" ;;
      copilot) echo "$COPILOT_VERSION $COPILOT_SHA256_AMD64 $COPILOT_SHA256_ARM64" ;;
      cursor) echo "$CURSOR_VERSION $CURSOR_SHA256_AMD64 $CURSOR_SHA256_ARM64" ;;
      gemini | grok) echo "node ${BN_TOOLS_NODE:-$(node --version 2>/dev/null)}"; cat "$TOOLS_SRC/$1/package.json" "$TOOLS_SRC/$1/package-lock.json" ;;
      *) return 1 ;;
    esac; } | sha256
}

# install_one TOOL — TOOL into /out/TOOL: from the cache when its key is there ("kept"), else installed and checked by
# tool_TOOL ("installed") and then kept in the cache for the next build (best effort: a cache that cannot take it only
# costs that build a download). Its VERSIONS line in $RES/TOOL.version, how in $RES/TOOL.how. Of each tool the cache
# keeps the two newest keys.
install_one() {
  t="$1"; key="$(tool_key "$t" "$arch")"; c="$CACHE/$t/$key"
  if [ -f "$c/.complete" ] && [ -s "$c/version" ] && cp -a "$c/out" "/out/$t" 2>/dev/null; then
    cp "$c/version" "$RES/$t.version"; echo kept > "$RES/$t.how"; touch "$c" "$c/.complete"   # (the newest used: kept longest)
    return 0
  fi
  rm -rf "/out/$t"
  (set -e; "tool_$t")
  echo installed > "$RES/$t.how"
  if mkdir -p "$CACHE/$t" 2>/dev/null; then
    rm -rf "$c.new"
    if mkdir -p "$c.new" && cp -a "/out/$t" "$c.new/out" && cp "$RES/$t.version" "$c.new/version" && : > "$c.new/.complete"; then
      rm -rf "$c"; mv "$c.new" "$c" || rm -rf "$c.new"
    else rm -rf "$c.new"; fi
    # shellcheck disable=SC2010,SC2012  # (the cache's own folder names: hex)
    ls -1t "$CACHE/$t" 2>/dev/null | grep -Ev '\.new$' | tail -n +3 | while IFS= read -r old; do rm -rf "${CACHE:?}/$t/$old"; done
  fi
  return 0
}

[ "${BN_TOOLS_LIB:-}" != 1 ] || return 0 2>/dev/null || exit 0   # (tests: the functions only)

want="$(printf '%s' "${BN_AI_TOOLS:-all}" | tr 'A-Z,' 'a-z ')"
case " $want " in
  *" all "*) want="$TOOLS_ALL" ;;
  *" none "*) want="" ;;
esac
for t in $want; do
  case " $TOOLS_ALL " in *" $t "*) ;; *) echo "BN_AI_TOOLS: no tool called '$t' (one of: $TOOLS_ALL, all, none)" >&2; exit 1 ;; esac
done

case "$(dpkg --print-architecture)" in
  amd64) arch=amd64 ;;
  arm64) arch=arm64 ;;
  *) echo "ai-tools: no pinned checksums for $(dpkg --print-architecture)" >&2; exit 1 ;;
esac
mkdir -p /out "$RES"
: > /out/VERSIONS
: > /out/SKIPPED

# Side by side, one tool each (in a subshell that stops at its first failure: the tool is then left out, the others
# stay); its words in $RES/TOOL.log, shown afterwards in the usual order
for t in $want; do
  # (not in an if: a condition would turn the subshell's set -e off)
  ( set +e; (set -e; install_one "$t") > "$RES/$t.log" 2>&1; echo "$?" > "$RES/$t.rc" ) &
done
wait
installed=''; kept=''
for t in $want; do
  cat "$RES/$t.log" 2>/dev/null || true
  rc="$(cat "$RES/$t.rc" 2>/dev/null || echo 1)"
  if [ "$rc" = 0 ] && [ -s "$RES/$t.version" ]; then
    cat "$RES/$t.version" >> /out/VERSIONS
    if [ "$(cat "$RES/$t.how" 2>/dev/null)" = kept ]; then kept="$kept $t"; else installed="$installed $t"; fi
  else
    rm -rf "/out/$t"
    echo "$t" >> /out/SKIPPED
    echo "ai-tools: $t is LEFT OUT of this image (its download or its check failed, above); the other tools are kept. ./stack update tries again." >&2
  fi
done
rm -rf "$RES"
# (./stack reads this line: Home's update card says what was installed and what was kept — lib/steps.sh build_report)
echo "ai-tools: installed:${installed:- none}; kept:${kept:- none}"
# everything root's, read-only to the sandbox's user (whatever owner a tarball recorded) — links too (-h) —, nothing
# setuid or setgid; a link's own mode bits mean nothing (always rwx on Linux): its target is what counts, so every link
# is relative and leads to something there, inside /out (one to /home/claude, /tmp or a folder outside would hand what
# runs to whatever is there, and a folder outside is never walked here). A check that cannot run fails the build.
chown -hR 0:0 /out
chmod -R a+rX,go-w,ug-s /out
bad="$(find /out \( ! -user 0 -o ! -group 0 -o \( ! -type l \( -perm -g+w -o -perm -o+w \) \) -o \( ! -type d ! -type l -perm /6000 \) \) -print)" || {
  echo "ai-tools: /out could not be checked" >&2; exit 1; }
if [ -n "$bad" ]; then echo "ai-tools: a file in /out is not root's alone, or setuid/setgid: $(printf '%s' "$bad" | head -n 1)" >&2; exit 1; fi
# shellcheck disable=SC2016  # (the script is the -c argument: its own $1)
find /out -type l -exec sh -c '
  for l; do
    t="$(readlink "$l")" || { echo "ai-tools: link $l cannot be read" >&2; exit 1; }
    case "$t" in /*) echo "ai-tools: $l is an absolute link ($t)" >&2; exit 1 ;; esac
    r="$(readlink -e "$l")" || { echo "ai-tools: $l leads nowhere ($t)" >&2; exit 1; }
    case "$r" in /out/*) ;; *) echo "ai-tools: $l leads out of /out ($r)" >&2; exit 1 ;; esac
    # (and as written, its own path read without following any link: a ../.. that only lands back in /out through
    # another link is not one that stays in it)
    s="$(realpath -m -s "$(dirname "$l")/$t")" || { echo "ai-tools: $l cannot be read as a path ($t)" >&2; exit 1; }
    case "$s" in /out/*) ;; *) echo "ai-tools: $l points out of /out as written ($t)" >&2; exit 1 ;; esac
  done' sh {} + || { echo "ai-tools: a link in /out is not one that stays in it" >&2; exit 1; }
cat /out/VERSIONS
