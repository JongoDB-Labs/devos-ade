# shellcheck shell=bash
# rb_try URL MAXTIME — one DNS-rebinding probe through the sandbox's egress proxy, run inside the terminal container
# (run.sh sends this file ahead of terminal_probe's script, and alone for a retry). One line:
#   proxy-rebind-try<TAB>URL<TAB>curl's exit<TAB>HTTP code (000: none)<TAB>the proxy's X-Bn-Egress header (-: none)<TAB>the
#   start of the body (-: none)
# lib.sh rebind_class reads it. No field is ever empty (a tab-separated read would shift the rest).
rb_try() {
  local b h code rc eg body
  b="$(mktemp)"; h="$(mktemp)"
  code="$(env -u NO_PROXY -u no_proxy curl -g -x http://egress:3128 -s -m "$2" -o "$b" -D "$h" -w '%{http_code}' "$1")"; rc=$?
  eg="$(awk -F': *' 'tolower($1) == "x-bn-egress" { sub(/\r$/, "", $2); print $2; exit }' "$h")"
  body="$(head -c 300 "$b" | tr '\t\r\n' '   ')"
  rm -f "$b" "$h"
  printf 'proxy-rebind-try\t%s\t%s\t%s\t%s\t%s\n' "$1" "$rc" "${code:-000}" "${eg:--}" "${body:--}"
}
