# shellcheck shell=bash
# shellcheck disable=SC2329  # stubs are called by the code under test
# `dc port SERVICE PORT` from Docker's own list (one docker call) as Compose prints it, JON-972; anything that list may
# not say as Compose would asks Compose. (tests/run.sh sets DEVOS_ADE_PS_VIA_COMPOSE=1 for the other tests' docker
# stubs; these unset it.) Against Compose itself on a live stack: tests/e2e/upgrade.sh, dc-port-as-compose.
. "$STACK_DIR/lib/commands.sh"

# _port_docker — PORTS_<service> is what Docker lists for the service's containers (one line a container)
_port_docker() {
  unset DEVOS_ADE_PS_VIA_COMPOSE
  printf 'X=1\n' > "$ENV_FILE"
  docker() {
    local all="$*" v
    echo "docker $*" >> "$TMP/calls"
    case "$1" in
      ps) case "$all" in "ps --no-trunc --filter label=com.docker.compose.project=$(project_name) --filter label=com.docker.compose.service="*" --filter label=com.docker.compose.oneoff=False --format {{.Ports}}") ;; *) return 9 ;; esac
        [ -z "${PS_DOWN:-}" ] || return 1
        v="${all#*com.docker.compose.service=}"; v="PORTS_${v%% *}"; v="${v//-/_}"
        [ -z "${!v:-}" ] || printf '%s\n' "${!v}" ;;
      compose) echo "COMPOSE"; return 0 ;;
    esac
  }
  : > "$TMP/calls"
}

test_dc_port_answers_from_dockers_list_as_compose_prints_it() {
  _port_docker
  local PORTS_litellm='127.0.0.1:4000->4000/tcp' PORTS_caddy='127.0.0.1:80->8080/tcp' PORTS_shared_mcp='0.0.0.0:8765->8000/tcp, [::]:8765->8000/tcp' \
    PORTS_postgres='5432/tcp' PORTS_two='127.0.0.1:9000->9000/tcp, 127.0.0.1:9001->9001/udp, 127.0.0.1:9001->9001/tcp'
  assert_eq "$(dc port litellm 4000; echo "rc=$?")" "$(printf '127.0.0.1:4000\nrc=0')"
  assert_eq "$(dc port caddy 8080)" "127.0.0.1:80"
  assert_eq "$(dc port shared-mcp 8000)" "0.0.0.0:8765"            # (the first: v4, then v6, the same host port)
  assert_eq "$(dc port two 9001)" "127.0.0.1:9001"                 # (its tcp, not its udp)
  # (v6 as Compose prints it: the address unbracketed, as Docker's API has it; older Dockers list it so already)
  assert_eq "$(PORTS_v6='[::]:4000->4000/tcp' dc port v6 4000)" ":::4000"
  assert_eq "$(PORTS_v6=':::4000->4000/tcp, 0.0.0.0:4000->4000/tcp' dc port v6 4000)" ":::4000"
  assert_eq "$(PORTS_v6='[::1]:4000->4000/tcp' dc port v6 4000)" "::1:4000"
  assert_eq "$(PORTS_udp='127.0.0.1:4000->4000/udp' dc port udp 4000; echo "rc=$?")" "rc=1"   # (a udp port only: none)
  # nothing, status 1: a port it does not publish, one it only exposes, a service with no running container
  assert_eq "$(dc port litellm 4001; echo "rc=$?")" "rc=1"
  assert_eq "$(dc port postgres 5432; echo "rc=$?")" "rc=1"
  assert_eq "$(dc port forgejo 3000; echo "rc=$?")" "rc=1"
  assert_not_contains "$(cat "$TMP/calls")" "docker compose"
  # resolve_port's and the portal's questions, the way they ask them
  dc port litellm 4000 2>/dev/null | grep ":4000\$" >/dev/null
  dc port caddy 8080 2>/dev/null | grep ':80$' >/dev/null
  if dc port caddy 8080 2>/dev/null | grep ':8080$' >/dev/null; then return 1; fi
}

test_dc_port_asks_compose_for_what_dockers_list_may_not_say_as_compose_would() {
  _port_docker
  local PORTS_range='127.0.0.1:4000-4002->4000-4002/tcp' PORTS_twice='127.0.0.1:4000->4000/tcp, 127.0.0.1:4100->4000/tcp' \
    PORTS_scaled="$(printf '127.0.0.1:4000->4000/tcp\n127.0.0.1:4001->4000/tcp')" PORTS_odd='127.0.0.1:x->4000/tcp' PORTS_litellm='127.0.0.1:4000->4000/tcp'
  local f
  for f in "port range 4001" "port twice 4000" "port scaled 4000" "port odd 4000" "port Bad/name 4000" "port -h 4000" \
    "port litellm 04000" "port litellm 4000/udp" "port --index 2 litellm 4000" "port --protocol udp litellm 4000" "port litellm"; do
    # shellcheck disable=SC2086  # the form, a word an argument
    assert_eq "$(dc $f)" "COMPOSE"
  done
  assert_eq "$(DEVOS_ADE_PS_VIA_COMPOSE=1 dc port litellm 4000)" "COMPOSE"
  assert_eq "$(PS_DOWN=1 dc port litellm 4000)" "COMPOSE"          # (docker failing: Compose says what it says)
  # (a range that does not hold the port: still Compose's, as a range is never read here)
  assert_eq "$(PORTS_range='127.0.0.1:5000-5002->5000-5002/tcp' dc port range 4000)" "COMPOSE"
}

test_dc_port_restores_allexport_and_reads_no_compose_files() {
  _port_docker
  local PORTS_litellm='127.0.0.1:4000->4000/tcp' r
  compose_overlays() { echo "overlays read" >> "$TMP/calls"; }
  set -a; r="$(dc port litellm 4000)"; case $- in *a*) ;; *) r=off ;; esac; set +a
  assert_eq "$r" "127.0.0.1:4000"
  assert_not_contains "$(cat "$TMP/calls")" "overlays read"
  assert_eq "$(grep -c '^docker ' "$TMP/calls")" 1
}
