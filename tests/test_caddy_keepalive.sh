# shellcheck shell=bash
# JON-1414: Caddy lets an idle connection to a service go after 2 s, before the service does (uvicorn and Node close
# theirs after 5 s; Caddy kept them 2 minutes, so a POST sent on one the service was closing got 502). Every
# reverse_proxy and forward_auth in caddy/ imports upstream_keepalive, and each Caddy's own configuration (the main one,
# the terminal's gateway, Ollama's gate) defines it, the same. Checked against Caddy itself (each mode adapted: every
# proxy handler with a 2 s idle timeout, the rest as before) when the fix was made; here, the text that keeps it so.

_ka_files() { ls "$STACK_DIR"/caddy/Caddyfile "$STACK_DIR"/caddy/*.caddy; }

test_every_proxy_block_lets_an_idle_connection_go_first() {
  local f bad=0 n=0 out
  for f in $(_ka_files); do
    # (a directive's line, then its block's first line: the import, one tab further in)
    out="$(awk -v F="${f##*/}" '
      want != "" { if ($0 != want) printf "%s:%d: %s has no import upstream_keepalive as its first line\n", F, NR - 1, dir; want = ""; next }
      /^[ \t]*(reverse_proxy|forward_auth)([ \t]|$)/ {
        n++; dir = $0; sub(/^[ \t]*/, "", dir)
        if ($0 !~ /\{[ \t]*$/) { printf "%s:%d: %s has no block\n", F, NR, dir; next }
        ind = $0; sub(/[^ \t].*$/, "", ind); want = ind "\timport upstream_keepalive"
      }
      END { print "count " n + 0 }' "$f")"
    n=$((n + $(printf '%s\n' "$out" | sed -n 's/^count //p')))
    if printf '%s\n' "$out" | grep -v '^count ' | grep . >&2; then bad=1; fi
  done
  # (every proxy of every configuration: 66 when the rule was added; fewer would mean the check reads nothing)
  [ "$n" -ge 66 ] || { echo "only $n proxy directives found in caddy/" >&2; bad=1; }
  return "$bad"
}

test_each_caddy_defines_the_rule_once_and_the_same() {
  local f d first='' bad=0
  for f in Caddyfile terminal-gateway.caddy ollama-gate.caddy; do
    d="$(awk '/^\(upstream_keepalive\) \{$/ { on = 1 } on { print } on && /^\}$/ { exit }' "$STACK_DIR/caddy/$f")"
    [ -n "$d" ] || { echo "$f does not define upstream_keepalive" >&2; bad=1; continue; }
    assert_eq "$(grep -c '^(upstream_keepalive)' "$STACK_DIR/caddy/$f")" 1
    [ -n "$first" ] || first="$d"
    [ "$d" = "$first" ] || { echo "$f defines upstream_keepalive otherwise than the Caddyfile" >&2; bad=1; }
  done
  assert_eq "$first" "$(printf '(upstream_keepalive) {\n\ttransport http {\n\t\tkeepalive 2s\n\t}\n}')"
  # (no other file defines it: the main configuration imports the rest, and a second definition is an error)
  assert_eq "$(grep -l '^(upstream_keepalive)' $(_ka_files) | sed 's#.*/##' | sort | tr '\n' ' ')" "Caddyfile ollama-gate.caddy terminal-gateway.caddy "
  # the definition comes before the first proxy that imports it (Caddy reads a snippet before its first use)
  for f in Caddyfile terminal-gateway.caddy ollama-gate.caddy; do
    awk '/^\(upstream_keepalive\)/ { exit 0 } /import upstream_keepalive/ { exit 1 }' "$STACK_DIR/caddy/$f" ||
      { echo "$f imports upstream_keepalive before it defines it" >&2; bad=1; }
  done
  return "$bad"
}

test_no_proxy_has_a_transport_of_its_own() {
  # (a second transport in a block would replace the rule's: one change to the rule must reach every proxy)
  local hits
  hits="$(grep -nE '^[[:space:]]*transport[[:space:]]' $(_ka_files) | grep -v $'^[^:]*:[0-9]*:\ttransport http {$' || true)"
  assert_eq "$hits" ""
  assert_eq "$(grep -cE '^[[:space:]]*transport[[:space:]]' $(_ka_files) | awk -F: '{ s += $NF } END { print s }')" 3
}
