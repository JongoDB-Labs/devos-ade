#!/bin/bash
# LM Studio's launchd agent (lib/runtimes.sh _rt_lmstudio_plist): llmster, LM Studio's daemon, as its installer put it in
# the stack's folder (HOME is the stack's .state/runtimes/lmstudio/home); its server on 127.0.0.1 at a port chosen now;
# and in front of it the gate (lib/lmstudio-gate.py) on 127.0.0.1:PORT, the only address DevOS ADE gives out: this
# computer's names only, the key made at install, the OpenAI-compatible API only. It ends when llmster or the gate does,
# and launchd starts it again; a stop (launchd's TERM) stops both with it.
#   lmstudio-agent.sh PORT RUNFILE KEYFILE   (RUNFILE: llmster's program, folder and first argument, and the python3 the
#                                             gate runs on, TAB-separated — written at install: launchd's PATH has no
#                                             python3 of yours)
set -u
port="${1:?port}"; run="${2:?llmster.run}"; keyf="${3:?api-key}"; h="$HOME/.lmstudio"
here="$(cd "$(dirname "$0")" && pwd)"
exe=''; cwd=''; arg=''; py=''; hp="$(cd "$HOME" 2>/dev/null && pwd -P)" || hp=/nonexistent   # (the run file's paths are resolved)
IFS=$'\t' read -r exe cwd arg py < "$run" 2>/dev/null || true
case "$exe" in "$hp"/*) ;; *) exe='' ;; esac
case "$cwd" in "$hp"/*) [ -d "$cwd" ] || exe='' ;; *) exe='' ;; esac
[ -n "$exe" ] && [ -f "$exe" ] && [ -x "$exe" ] && [ -x "$h/bin/lms" ] \
  || { echo "lmstudio-agent: no llmster in $h (install LM Studio again: ./stack runtimes install lmstudio)" >&2; exit 1; }
case "$py" in /*) [ -x "$py" ] || py='' ;; *) py='' ;; esac
[ -n "$py" ] && [ -s "$keyf" ] && [ -f "$here/lmstudio-gate.py" ] \
  || { echo "lmstudio-agent: no python3 or key for its gate (install LM Studio again: ./stack runtimes install lmstudio)" >&2; exit 1; }
# LM Studio's own port: a free one, now (never PORT: only the gate is there)
bport="$("$py" -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])' 2>/dev/null)"
case "$bport" in '' | *[!0-9]*) echo "lmstudio-agent: no free port for LM Studio's server" >&2; exit 1 ;; esac
cd "$cwd" || exit 1
if [ "$arg" = . ]; then "$exe" . </dev/null & else "$exe" </dev/null & fi
lpid=$!; gpid=''
trap 'kill $lpid $gpid 2>/dev/null; wait 2>/dev/null; exit 0' TERM INT
# its server, once llmster answers lms (lms finds this llmster alone: the server file it publishes in this HOME)
export LMS_API_SERVER_INFO_PATH="$h/.internal/http-server.json"
n=0
until "$h/bin/lms" server start --port "$bport" --bind 127.0.0.1 </dev/null; do
  n=$((n + 1))
  if [ "$n" -ge 30 ] || ! kill -0 "$lpid" 2>/dev/null; then
    echo "lmstudio-agent: its server did not start on 127.0.0.1:$bport" >&2
    kill "$lpid" 2>/dev/null; wait 2>/dev/null; exit 1
  fi
  sleep 2
done
"$py" -I "$here/lmstudio-gate.py" "$port" "$bport" "$keyf" </dev/null &
gpid=$!
echo "lmstudio-agent: LM Studio's server on 127.0.0.1:$bport, its gate on 127.0.0.1:$port"
while kill -0 "$lpid" 2>/dev/null && kill -0 "$gpid" 2>/dev/null; do sleep 2 & wait $!; done
echo "lmstudio-agent: $(kill -0 "$lpid" 2>/dev/null && echo "its gate" || echo llmster) ended" >&2
kill "$lpid" "$gpid" 2>/dev/null; wait 2>/dev/null; exit 1
