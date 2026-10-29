#!/bin/bash
# LM Studio's launchd agent (lib/runtimes.sh _rt_lmstudio_plist): llmster, LM Studio's daemon, as its installer put it in
# the stack's folder (HOME is the stack's .state/runtimes/lmstudio/home), then its server on 127.0.0.1:PORT only, with
# no CORS. It ends when llmster does, and launchd starts it again; a stop (launchd's TERM) stops llmster with it. Nothing
# but bash: launchd's PATH has no python3 of yours.
#   lmstudio-agent.sh PORT RUNFILE   (RUNFILE: llmster's program, folder and first argument, TAB-separated — written at
#                                     install, from what its installer recorded)
set -u
port="${1:?port}"; run="${2:?llmster.run}"; h="$HOME/.lmstudio"
exe=''; cwd=''; arg=''; hp="$(cd "$HOME" 2>/dev/null && pwd -P)" || hp=/nonexistent   # (the run file's paths are resolved)
IFS=$'\t' read -r exe cwd arg < "$run" 2>/dev/null || true
case "$exe" in "$hp"/*) ;; *) exe='' ;; esac
case "$cwd" in "$hp"/*) [ -d "$cwd" ] || exe='' ;; *) exe='' ;; esac
[ -n "$exe" ] && [ -f "$exe" ] && [ -x "$exe" ] && [ -x "$h/bin/lms" ] \
  || { echo "lmstudio-agent: no llmster in $h (install LM Studio again: ./stack runtimes install lmstudio)" >&2; exit 1; }
cd "$cwd" || exit 1
if [ "$arg" = . ]; then "$exe" . </dev/null & else "$exe" </dev/null & fi
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; exit 0' TERM INT
# its server, once llmster answers lms (lms finds this llmster alone: the server file it publishes in this HOME)
export LMS_API_SERVER_INFO_PATH="$h/.internal/http-server.json"
n=0
until "$h/bin/lms" server start --port "$port" --bind 127.0.0.1 </dev/null; do
  n=$((n + 1))
  if [ "$n" -ge 30 ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "lmstudio-agent: its server did not start on 127.0.0.1:$port" >&2
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; exit 1
  fi
  sleep 2
done
wait "$pid"
