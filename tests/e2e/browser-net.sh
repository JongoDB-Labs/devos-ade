# shellcheck shell=bash
# shellcheck disable=SC2034  # (BNET_OPTS, BNET_CMD: read by the scripts that source this)
# browser-net.sh — the Linux browser's own network, sourced by browser.sh, ui-sweep.sh and https.sh (browser/relay.py
# says why: on the test host's network, Chromium cancels what it loads when any run's Docker network or container comes
# or goes — ERR_NETWORK_CHANGED). The container is on Docker's default bridge, a network of its own that nothing of a
# run changes; the stack's ports on the host's 127.0.0.1 reach it through Unix sockets (relay.py host / inside), under
# the same numbers on its own 127.0.0.1, so its URLs, Host headers and certificates are the ones it had.
#
#   browser_net_start PORT...   -> BNET_OPTS (docker run options) and BNET_CMD (what the container's command runs under);
#                                  1 when the relay did not start (said)
#   browser_net_stop            the relay ended and its folder gone (also when nothing was started)
# On macOS (Docker Desktop: host-gateway) nothing changes. E2E_BROWSER_NET=host: the test host's network, as before
# v0.57.0 (and with it, ERR_NETWORK_CHANGED beside other runs).
BNET_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BNET_OPTS=(); BNET_CMD=(); BNET_DIR=''; BNET_PID=''
browser_net_start() {
  BNET_OPTS=(); BNET_CMD=(); BNET_DIR=''; BNET_PID=''
  [ "$(uname -s)" = Linux ] || return 0
  if [ "${E2E_BROWSER_NET:-own}" = host ]; then BNET_OPTS=(--network host); return 0; fi
  local p ports=()
  for p in "$@"; do
    case "$p" in '') ;; *[!0-9]*) echo "browser-net: not a port: '$p'" >&2; return 1 ;; *) ports+=("$p") ;; esac
  done
  [ "${#ports[@]}" -gt 0 ] || { echo "browser-net: no ports" >&2; return 1; }
  # (in /tmp, not TMPDIR: a Unix socket's path is at most 108 bytes)
  BNET_DIR="$(mktemp -d /tmp/bne2e-net.XXXXXX)" || { echo "browser-net: no folder for the relay's sockets" >&2; return 1; }
  chmod 700 "$BNET_DIR"
  python3 -I "$BNET_HERE/browser/relay.py" host "$BNET_DIR" "${ports[@]}" > "$BNET_DIR/relay.log" 2>&1 &
  BNET_PID=$!
  for _ in $(seq 1 100); do
    grep -q '^ready$' "$BNET_DIR/relay.log" 2>/dev/null && break
    kill -0 "$BNET_PID" 2>/dev/null || break
    sleep 0.1
  done
  if ! grep -q '^ready$' "$BNET_DIR/relay.log" 2>/dev/null; then
    echo "browser-net: the relay did not start: $(tail -n 3 "$BNET_DIR/relay.log" 2>/dev/null)" >&2
    browser_net_stop; return 1
  fi
  BNET_OPTS=(--network bridge -v "$BNET_DIR:/relay")
  BNET_CMD=(python3 -I /suite/relay.py inside /relay "${ports[@]}" --)
}
browser_net_stop() {
  if [ -n "$BNET_PID" ]; then kill "$BNET_PID" 2>/dev/null; wait "$BNET_PID" 2>/dev/null; fi
  if [ -n "$BNET_DIR" ] && [ -d "$BNET_DIR" ]; then
    rm -f "$BNET_DIR"/*.sock "$BNET_DIR/relay.log"; rmdir "$BNET_DIR" 2>/dev/null
  fi
  BNET_PID=''; BNET_DIR=''
  return 0
}
