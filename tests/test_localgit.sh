# shellcheck shell=bash
# shellcheck disable=SC2016,SC2329  # literal $ in expected output; stubs are called by the code under test
# The built-in local git server (lib/localgit.sh, JON-810): on by default, the switch, its services and compose files, the
# certificate for the sandbox's TLS listener, the owner account and the Code page's host (the token only on stdin, never on a
# command line), the gateway's egress carve-out (caddy/localgit-gateway-on.caddy: git's paths only), the web site's snippets.
# No test here calls docker; tests/e2e/localgit/run.sh runs the real thing.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/localgit.sh

# --- the switch and what follows it ---

test_on_by_default_off_when_told() {
  printf 'X=1\n' > "$ENV_FILE"
  localgit_on || return 1                                   # blank = on
  assert_eq "$(localgit_services)" forgejo
  for v in on true 1 yes; do printf 'LOCALGIT=%s\n' "$v" > "$ENV_FILE"; localgit_on || { echo "$v is on" >&2; return 1; }; done
  for v in off false 0 no OFF; do
    printf 'LOCALGIT=%s\n' "$v" > "$ENV_FILE"
    ! localgit_on || { echo "$v is off" >&2; return 1; }
    assert_eq "$(localgit_services)" ""
  done
}

test_the_container_is_in_the_services_and_the_profile_while_it_is_on() {
  printf 'X=1\n' > "$ENV_FILE"
  assert_contains " $(optional_services) " " forgejo "
  assert_contains " $(stack_services) " " forgejo "
  docker() { printf '%s\n' "$*" >> "$TMP/docker"; }
  : > "$TMP/docker"; dc ps >/dev/null
  assert_contains "$(cat "$TMP/docker")" "--profile forgejo --env-file"
  assert_contains "$(cat "$TMP/docker")" "BN_LOCALGIT_MODE" 2>/dev/null || true
  printf 'LOCALGIT=off\n' > "$ENV_FILE"
  assert_not_contains " $(optional_services) " " forgejo "
  : > "$TMP/docker"; dc ps >/dev/null; assert_not_contains "$(cat "$TMP/docker")" "forgejo"
  # (a shell's LOCALGIT never decides: .env does; the removal names the profile)
  : > "$TMP/docker"; LOCALGIT=on dc ps >/dev/null; assert_not_contains "$(cat "$TMP/docker")" "forgejo"
  : > "$TMP/docker"; _LG_PROFILE=1 dc rm -sf forgejo >/dev/null; assert_contains "$(cat "$TMP/docker")" "--profile forgejo --env-file $ENV_FILE rm -sf forgejo"
}

test_the_mode_and_the_certificate_folder_reach_compose_through_dc() {
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nenv | grep -E "^(BN_LOCALGIT_MODE|BN_LOCALGIT_TLS)=" | sort\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
  printf 'X=1\n' > "$ENV_FILE"
  out="$(PATH="$TMP/bin:$PATH" BN_LOCALGIT_MODE=evil BN_LOCALGIT_TLS=/evil dc ps)"
  assert_contains "$out" "BN_LOCALGIT_MODE=on"
  assert_contains "$out" "BN_LOCALGIT_TLS=$STATE_DIR/localgit/tls"
  printf 'LOCALGIT=off\n' > "$ENV_FILE"
  assert_contains "$(PATH="$TMP/bin:$PATH" dc ps)" "BN_LOCALGIT_MODE=off"
}

test_the_gateways_listener_needs_the_terminal_and_the_switch() {
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=/w\n' > "$ENV_FILE"
  assert_contains "$(compose_overlays | tr '\n' ' ')" "compose.localgit.yaml"
  # with the sandbox's internet off or direct too: it is not a way to the internet
  for e in off host internet; do
    printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=/w\nTERMINAL_EGRESS=%s\n' "$e" > "$ENV_FILE"
    assert_contains "$(compose_overlays | tr '\n' ' ')" "compose.localgit.yaml"
  done
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=/w\nLOCALGIT=off\n' > "$ENV_FILE"
  assert_not_contains "$(compose_overlays | tr '\n' ' ')" "compose.localgit.yaml"
  printf 'TERMINAL_ENABLED=false\nTERMINAL_WORKSPACE=/w\n' > "$ENV_FILE"
  assert_eq "$(compose_overlays | tr '\n' ' ')" ""
  printf 'X=1\n' > "$ENV_FILE"
  assert_eq "$(compose_overlays | tr '\n' ' ')" ""
}

# --- the certificate ---

test_the_certificate_is_checked_once_an_hour_in_a_shell() {
  # (dc asks at every compose call, some 35 an update: openssl and cmp once, then only while something changed; JON-972)
  command -v openssl >/dev/null 2>&1 || { echo "no openssl" >&2; return 77; }
  printf 'X=1\n' > "$ENV_FILE"
  localgit_tls_ensure || return 1
  local d calls="$TMP/calls" c
  d="$(localgit_tls_dir)"
  openssl() { echo openssl >> "$calls"; command openssl "$@"; }
  cmp() { echo cmp >> "$calls"; command cmp "$@"; }
  : > "$calls"; localgit_tls_ensure; localgit_tls_ensure; ( localgit_tls_ensure ) || return 1
  assert_eq "$(wc -l < "$calls" | tr -d ' ')" 0
  # (checked again: the published copy gone, then changed; the certificate another; the key gone; an hour on; another folder)
  rm -f "$d/ca/tls.crt"; : > "$calls"; localgit_tls_ensure || return 1
  assert_eq "$(grep -c openssl "$calls")" 1; [ -s "$d/ca/tls.crt" ]
  printf 'x\n' >> "$d/ca/tls.crt"; : > "$calls"; localgit_tls_ensure || return 1
  assert_eq "$(grep -c openssl "$calls")" 1; assert_eq "$(cat "$d/ca/tls.crt")" "$(cat "$d/tls.crt")"
  c="$(cat "$d/tls.crt")"
  command openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=gateway -keyout "$d/tls.key" -out "$d/tls.crt" >/dev/null 2>&1
  : > "$calls"; localgit_tls_ensure || return 1
  [ "$(cat "$d/tls.crt")" != "$c" ] && [ "$(grep -c openssl "$calls")" -ge 2 ] || { echo "a certificate ending in 2 days was kept" >&2; return 1; }
  assert_eq "$(cat "$d/ca/tls.crt")" "$(cat "$d/tls.crt")"
  : > "$calls"; localgit_tls_ensure; assert_eq "$(wc -l < "$calls" | tr -d ' ')" 0
  rm -f "$d/tls.key"; : > "$calls"; localgit_tls_ensure || return 1
  [ -s "$d/tls.key" ] && [ "$(grep -c openssl "$calls")" -ge 1 ]
  SECONDS=$((SECONDS + 3600)); : > "$calls"; localgit_tls_ensure || return 1
  assert_eq "$(grep -c openssl "$calls")" 1
  # (SECONDS set back, as lib/helper.sh does: checked again, not trusted for longer)
  SECONDS=100; localgit_tls_ensure; SECONDS=0; : > "$calls"; localgit_tls_ensure || return 1
  assert_eq "$(grep -c openssl "$calls")" 1
  local s="$STATE_DIR"; STATE_DIR="$TMP/other-state"; : > "$calls"; localgit_tls_ensure || return 1
  [ "$(grep -c openssl "$calls")" -ge 1 ] && [ -s "$STATE_DIR/localgit/tls/tls.crt" ]; STATE_DIR="$s"
}

test_dc_checks_the_certificate_once_for_its_calls() {
  command -v openssl >/dev/null 2>&1 || { echo "no openssl" >&2; return 77; }
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=/w\nLOCALGIT_SSO_HEADER=X\n' > "$ENV_FILE"
  local calls="$TMP/calls"
  docker() { printf '%s\n' "$*" >> "$TMP/docker"; }
  openssl() { echo openssl >> "$calls"; command openssl "$@"; }
  : > "$calls"; dc exec -T portal true; dc exec -T portal true; dc up -d portal
  # (the first call made it: openssl's req; the gateway's overlay in every call)
  assert_eq "$(grep -c openssl "$calls")" 1
  assert_eq "$(grep -c 'compose.localgit.yaml' "$TMP/docker")" 3
  : > "$calls"; dc exec -T portal true; assert_eq "$(wc -l < "$calls" | tr -d ' ')" 0
}

test_the_certificate_is_made_once_for_the_name_gateway_and_is_its_own_ca() {
  command -v openssl >/dev/null 2>&1 || { echo "no openssl" >&2; return 77; }
  printf 'X=1\n' > "$ENV_FILE"
  localgit_tls_ensure || return 1
  d="$(localgit_tls_dir)"
  assert_eq "$d" "$STATE_DIR/localgit/tls"
  [ -s "$d/tls.crt" ] && [ -s "$d/tls.key" ] || { echo "no certificate or key" >&2; return 1; }
  assert_contains "$(openssl x509 -in "$d/tls.crt" -noout -subject)" "CN"
  assert_contains "$(openssl x509 -in "$d/tls.crt" -noout -ext subjectAltName 2>/dev/null)" "DNS:gateway"
  assert_contains "$(openssl x509 -in "$d/tls.crt" -noout -ext basicConstraints 2>/dev/null)" "CA:TRUE"
  # git trusts exactly it: the server's own certificate verifies as its own anchor, for the name gateway only
  openssl verify -CAfile "$d/tls.crt" "$d/tls.crt" >/dev/null 2>&1 || { echo "does not verify as its own CA" >&2; return 1; }
  # the gateway's user is another on Linux: readable by everyone, in a folder everyone may enter
  [ "$(perm_of "$d/tls.key")" = 644 ] && [ "$(perm_of "$d/tls.crt")" = 644 ] && [ "$(perm_of "$d")" = 755 ] || { echo "modes $(perm_of "$d/tls.key") $(perm_of "$d/tls.crt") $(perm_of "$d")" >&2; return 1; }
  before="$(cksum < "$d/tls.crt")"
  localgit_tls_ensure || return 1
  assert_eq "$(cksum < "$d/tls.crt")" "$before"            # (kept while it stands)
  # one that ends within a month is made again
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=gateway -keyout "$d/tls.key" -out "$d/tls.crt" >/dev/null 2>&1
  before="$(cksum < "$d/tls.crt")"
  localgit_tls_ensure || return 1
  [ "$(cksum < "$d/tls.crt")" != "$before" ] || { echo "an ending certificate was kept" >&2; return 1; }
  # the sandbox's folder holds the certificate and never the key, and follows the certificate when it is made again
  [ "$(cat "$d/ca/tls.crt")" = "$(cat "$d/tls.crt")" ] || { echo "the sandbox's CA is not the new certificate" >&2; return 1; }
  [ ! -e "$d/ca/tls.key" ] && [ "$(ls "$d/ca" | tr '\n' ' ')" = "tls.crt " ] || { echo "the sandbox's folder: $(ls "$d/ca")" >&2; return 1; }
  [ "$(perm_of "$d/ca/tls.crt")" = 644 ] && [ "$(perm_of "$d/ca")" = 755 ] || { echo "modes of the CA folder" >&2; return 1; }
  # no openssl, no certificate: the overlay is left out rather than a compose file that cannot mount
  rm -rf "$STATE_DIR/localgit"; mkdir -p "$TMP/noopenssl"; printf '#!/bin/sh\nexit 127\n' > "$TMP/noopenssl/openssl"; chmod +x "$TMP/noopenssl/openssl"
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=/w\n' > "$ENV_FILE"
  assert_eq "$(PATH="$TMP/noopenssl:$PATH" compose_overlays | tr '\n' ' ')" "compose.terminal.yaml compose.terminal-proxy.yaml "
}

# --- secrets, the account, the Code page's host ---

test_setup_writes_the_switch_and_a_password_never_printed() {
  : > "$ENV_FILE"
  out="$(localgit_secrets 2>&1)"
  assert_eq "$out" ""
  assert_eq "$(get_env LOCALGIT)" on
  pw="$(get_env LOCALGIT_ADMIN_PASSWORD)"
  [ "${#pw}" -ge 24 ] || { echo "a short password: ${#pw}" >&2; return 1; }
  localgit_secrets; assert_eq "$(get_env LOCALGIT_ADMIN_PASSWORD)" "$pw"   # (kept)
  printf 'LOCALGIT=off\n' > "$ENV_FILE"; localgit_secrets
  assert_eq "$(get_env LOCALGIT)" off                                       # (off stays off)
}

test_the_account_is_made_with_the_password_in_the_environment_only() {
  printf 'LOCALGIT_ADMIN_PASSWORD=Lg9-secretvalue0123456789abcd\nOPENWEBUI_ADMIN_EMAIL=owner@example.com\n' > "$ENV_FILE"
  dc() {
    echo "dc $*" >> "$TMP/calls"
    case "$*" in *"admin user list"*) printf 'ID Username Email IsActive IsAdmin 2FA\n%s\n' "${LIST_ROW:-}" ;; esac
    [ -z "${LG_PW:-}" ] || echo "LG_PW=set" >> "$TMP/calls"
  }
  : > "$TMP/calls"; LIST_ROW=''; localgit_ensure_admin
  assert_contains "$(cat "$TMP/calls")" "forgejo sh -c forgejo admin user create --admin --username"
  assert_contains "$(cat "$TMP/calls")" "-e LG_PW -e LG_EMAIL"
  assert_not_contains "$(cat "$TMP/calls")" "secretvalue"                   # (never on a command line)
  : > "$TMP/calls"; LIST_ROW='1 devos owner@example.com true true false'; localgit_ensure_admin
  assert_contains "$(cat "$TMP/calls")" "change-password"
  assert_not_contains "$(cat "$TMP/calls")" "admin user create"
  assert_not_contains "$(cat "$TMP/calls")" "secretvalue"
}

test_the_code_pages_host_is_handed_over_on_stdin_the_ca_first_the_token_only_for_a_new_host() {
  mkdir -p "$STATE_DIR/localgit/tls"; printf 'CERT-LINE-1\nCERT-LINE-2\n' > "$STATE_DIR/localgit/tls/tls.crt"; : > "$STATE_DIR/localgit/tls/tls.key"
  printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=/w\nCODE_ENABLED=true\n' > "$ENV_FILE"
  code_ready() { return 0; }
  localgit_tls_ensure() { return 0; }
  TOK="tok$(printf 'A%.0s' $(seq 1 20))"
  : > "$TMP/calls"; : > "$TMP/stdin"
  dc() {
    echo "dc $*" >> "$TMP/calls"
    case "$*" in
      "ps -q --status running code") echo abc ;;
      *"import-host.mjs"*) cat > "$TMP/in"; cat "$TMP/in" >> "$TMP/stdin"; echo >> "$TMP/stdin"
        if [ "${HOST_THERE:-0}" = 1 ] || grep -q '"token"' "$TMP/in"; then echo '{"ok":true,"host":{}}'; else echo '{"ok":false,"error":"no token"}'; fi ;;
      *"generate-access-token"*) echo "$TOK" ;;
    esac
  }
  # a new host: the CA alone is refused ("no token"), a token is made and sent with it
  HOST_THERE=0; localgit_register_host || { echo "not registered" >&2; return 1; }
  assert_contains "$(cat "$TMP/calls")" "generate-access-token --username devos --token-name devos-ade-code-"
  assert_contains "$(cat "$TMP/calls")" "--scopes write:repository,read:user --raw"
  assert_not_contains "$(cat "$TMP/calls")" "$TOK"                                     # (never on a command line)
  assert_eq "$(grep -c '"token"' "$TMP/stdin")" 1
  assert_contains "$(cat "$TMP/stdin")" '"source":"localgit"'
  assert_contains "$(cat "$TMP/stdin")" 'CERT-LINE-1\nCERT-LINE-2'
  assert_contains "$(cat "$TMP/stdin")" '"account":"devos"'
  # a host that is there: the CA only, no token made
  : > "$TMP/calls"; : > "$TMP/stdin"; HOST_THERE=1; localgit_register_host || return 1
  assert_not_contains "$(cat "$TMP/calls")" "generate-access-token"
  assert_not_contains "$(cat "$TMP/stdin")" '"token"'
  # no Code page: nothing is attempted
  code_ready() { return 1; }; : > "$TMP/calls"; localgit_register_host
  assert_eq "$(cat "$TMP/calls")" ""
}

test_after_up_says_when_the_container_does_not_run_and_never_fails() {
  printf 'X=1\n' > "$ENV_FILE"
  localgit_secrets
  _lg_running() { return 1; }
  out="$(localgit_after_up 2>&1)"; rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "the built-in git server is not running — ./stack logs forgejo"
  _lg_running() { return 0; }; localgit_ensure_admin() { return 1; }
  out="$(localgit_after_up 2>&1)"; assert_contains "$out" "could not make the git server's owner account"
  printf 'LOCALGIT=off\n' > "$ENV_FILE"; : > "$TMP/calls"; dc() { echo "dc $*" >> "$TMP/calls"; }
  localgit_after_up; assert_eq "$(cat "$TMP/calls")" ""                    # (off: nothing)
}

test_off_removes_the_container_and_keeps_the_volume() {
  printf 'LOCALGIT=off\n' > "$ENV_FILE"
  dc() { echo "dc $*" >> "$TMP/calls"; case "$*" in *"ps -aq forgejo") [ ! -f "$TMP/running" ] || echo abc ;; esac; }
  services_status_write() { :; }
  : > "$TMP/calls"; localgit_remove; assert_not_contains "$(cat "$TMP/calls")" "rm -sf"     # none there: nothing removed
  : > "$TMP/running"; : > "$TMP/calls"; localgit_start
  assert_contains "$(cat "$TMP/calls")" "rm -sf forgejo"
  assert_not_contains "$(cat "$TMP/calls")" " -v"                                                # (the volume stays)
}

test_start_brings_up_the_container_alone_and_says_when_it_does_not_start() {
  printf 'X=1\n' > "$ENV_FILE"
  localgit_tls_ensure() { return 0; }; services_status_write() { :; }
  run_phase() { shift 2; echo "phase $*" >> "$TMP/calls"; "$@"; }
  dc() { echo "dc $*" >> "$TMP/calls"; }
  : > "$TMP/calls"; localgit_start
  assert_contains "$(cat "$TMP/calls")" "phase dc up -d --no-deps --wait forgejo"
  assert_eq "$(get_env LOCALGIT)" on
  [ -n "$(get_env LOCALGIT_ADMIN_PASSWORD)" ] || return 1
  run_phase() { return 1; }
  out="$(localgit_start 2>&1)"; assert_contains "$out" "the built-in git server did not start — ./stack logs forgejo says why"
}

test_uninstall_removes_the_volume_even_while_it_is_off() {
  printf 'LOCALGIT=off\n' > "$ENV_FILE"
  docker() { echo "docker $*" >> "$TMP/calls"; }
  dc() { echo "dc $*" >> "$TMP/calls"; }
  : > "$TMP/calls"; localgit_uninstall_cleanup
  assert_contains "$(cat "$TMP/calls")" "docker volume rm devos-ade_gitdata"
  assert_contains "$(cat "$TMP/calls")" "docker network rm devos-ade_localgit"
  assert_contains "$(sed -n '/^cmd_uninstall() {/,/^}/p' "$T_ROOT/lib/commands.sh")" "localgit_uninstall_cleanup"
}

# --- status, the host name ---

test_status_and_summary_say_where_it_is_and_how_to_sign_in() {
  printf 'PORTAL_HOST=bn.localhost\nPORTAL_PORT=8800\nLOCALGIT_ADMIN_PASSWORD=Lg9-0123456789abcdef0123456789ab\n' > "$ENV_FILE"
  out="$(localgit_status_line)"
  assert_contains "$out" "http://git.bn.localhost:8800"
  assert_contains "$out" "sign in as devos (password: LOCALGIT_ADMIN_PASSWORD in .env)"
  assert_contains "$out" "https://gateway:8093/devos/REPO.git"
  assert_not_contains "$out" "Lg9-0123456789"                                # (the name of the key, never the password)
  assert_contains "$(localgit_summary_line)" "http://git.bn.localhost:8800"
  assert_contains "$(status_url forgejo)" "http://git.bn.localhost:8800"
  printf 'PORTAL_HOST=bn.localhost\nLOCALGIT=off\n' > "$ENV_FILE"
  assert_contains "$(localgit_status_line)" "Git server off (LOCALGIT=off)"
  assert_eq "$(localgit_summary_line)" ""
}

test_the_git_host_name_follows_the_portals_rules() {
  printf 'PORTAL_HOST=bn.localhost\n' > "$ENV_FILE"
  assert_eq "$(app_host git)" "git.bn.localhost"
  printf 'PORTAL_HOST=bn.localhost\nGIT_HOST=code-git.bn.localhost\n' > "$ENV_FILE"
  assert_eq "$(app_host git)" "code-git.bn.localhost"
  check_app_hosts
  printf 'PORTAL_HOST=bn.localhost\nGIT_HOST=chat.bn.localhost\n' > "$ENV_FILE"
  out="$( ( check_app_hosts ) 2>&1 )" || true
  assert_contains "$out" "GIT_HOST=chat.bn.localhost is the same host name as another app or the web app"
  printf 'PORTAL_HOST=bn.localhost\nPORTAL_PORT=8800\n' > "$ENV_FILE"; save_portal_origin
  assert_eq "$(get_env GIT_ORIGIN)" "http://git.bn.localhost:8800"
}

# --- the files: the carve-out lets git's paths through and nothing else ---

test_the_gateways_listener_forwards_git_smart_http_only() {
  g="$(cat "$T_ROOT/caddy/localgit-gateway-on.caddy")"
  assert_contains "$g" "https://:8093 {"
  assert_contains "$g" "bind gateway"                                         # (the sandbox's network alone)
  assert_contains "$g" "tls /etc/bn-localgit/tls.crt /etc/bn-localgit/tls.key"
  assert_contains "$g" 'reverse_proxy @git forgejo:3000'
  assert_contains "$g" "respond 404"
  # the one matcher: owner/repo.git/{info/refs, git-upload-pack, git-receive-pack}
  assert_contains "$g" '@git path_regexp ^/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git/(info/refs|git-upload-pack|git-receive-pack)$'
  assert_eq "$(printf '%s\n' "$g" | grep -c 'reverse_proxy')" 1                # (one upstream, one matcher)
  assert_not_contains "$g" "reverse_proxy forgejo"                               # (never everything)
  # what could pose as a sign-in by the portal or a reverse proxy is stripped; unclean paths are refused
  for h in X-Portal-User X-Portal-Remote X-Portal-Proxy Tailscale-User-Login Cookie X-Webauth-User; do assert_contains "$g" "request_header -$h"; done
  assert_contains "$g" "respond @unclean 404"
  # the main gateway file imports it by the switch compose.localgit.yaml sets (off: the empty file)
  assert_contains "$(cat "$T_ROOT/caddy/terminal-gateway.caddy")" 'import localgit-gateway-{$BN_LOCALGIT_GATEWAY:off}.caddy'
  assert_contains "$(cat "$T_ROOT/caddy/localgit-gateway-off.caddy")" "without the built-in git server"
  # the compose overlay: the TLS folder read-only and never created by Docker, the localgit network, the switch
  c="$(cat "$T_ROOT/compose.localgit.yaml")"
  assert_contains "$c" 'BN_LOCALGIT_GATEWAY: "on"'
  assert_contains "$c" 'source: ${BN_LOCALGIT_TLS:?run ./stack up}'
  assert_contains "$c" "target: /etc/bn-localgit"
  assert_contains "$c" "read_only: true"
  assert_contains "$c" "create_host_path: false"
  assert_contains "$c" "localgit: {}"
  # the sandbox's own git: the certificate's folder alone (never the key's), read-only, for gateway:8093 only (terminal/gitconfig)
  assert_contains "$c" 'source: ${BN_LOCALGIT_TLS:?run ./stack up}/ca'
  assert_contains "$c" "target: /etc/bn-localgit-ca"
  assert_eq "$(grep -c BN_LOCALGIT_TLS "$T_ROOT/compose.localgit.yaml" | tr -d " ")" "2"   # (the gateway's folder and the sandbox's: no third)
  gc="$(cat "$T_ROOT/terminal/gitconfig")"
  assert_contains "$gc" '[http "https://gateway:8093/"]'
  assert_contains "$gc" "sslCAInfo = /etc/bn-localgit-ca/tls.crt"
  assert_eq "$(grep -c 'sslCAInfo' "$T_ROOT/terminal/gitconfig" | tr -d ' ')" "1"
}

test_the_web_site_is_behind_the_portal_and_framed_by_it_only() {
  s="$(cat "$T_ROOT/caddy/localgit-on.caddy")"
  assert_contains "$s" '{$LOCAL_SCHEME:http}://{$GIT_HOST} {'
  for i in local_request not_from_preview portal_auth drop_session_cookie frame_by_portal_only; do assert_contains "$s" "import $i"; done
  assert_contains "$s" "reverse_proxy forgejo:3000"
  assert_contains "$(cat "$T_ROOT/caddy/Caddyfile")" 'import localgit-{$LOCALGIT_MODE:off}.caddy'
  # compose: Caddy gets the host and the mode; the gateway's files and the Caddyfile's are in their own checksums
  c="$(cat "$T_ROOT/compose.yaml")"
  assert_contains "$c" 'GIT_HOST: ${GIT_HOST:-git.${PORTAL_HOST:-devos-ade.localhost}}'
  assert_contains "$c" 'LOCALGIT_MODE: ${BN_LOCALGIT_MODE:-off}'
  mkdir -p "$TMP/co/caddy"; STACK_DIR="$TMP/co"
  for f in Caddyfile terminal-gateway.caddy localgit-on.caddy localgit-off.caddy localgit-gateway-on.caddy localgit-gateway-off.caddy; do echo "$f" > "$TMP/co/caddy/$f"; done
  a="$(config_sums off | grep -E '^BN_(CADDY|GATEWAY)_CONFIG_SUM=')"
  echo changed > "$TMP/co/caddy/localgit-gateway-on.caddy"
  b="$(config_sums off | grep -E '^BN_(CADDY|GATEWAY)_CONFIG_SUM=')"
  assert_eq "$(printf '%s\n' "$a" | grep BN_CADDY)" "$(printf '%s\n' "$b" | grep BN_CADDY)"       # (the main Caddy never restarts for the listener)
  [ "$(printf '%s\n' "$a" | grep BN_GATEWAY)" != "$(printf '%s\n' "$b" | grep BN_GATEWAY)" ] || { echo "the gateway ignores its listener's file" >&2; return 1; }
  echo changed > "$TMP/co/caddy/localgit-on.caddy"
  c2="$(config_sums off | grep BN_CADDY)"
  [ "$c2" != "$(printf '%s\n' "$b" | grep BN_CADDY)" ] || { echo "the main Caddy ignores the git site's file" >&2; return 1; }
}

test_the_container_is_locked_down_and_isolated() {
  s="$(sed -n '/^  forgejo:/,/^  portal:/p' "$T_ROOT/compose.yaml")"
  assert_contains "$s" 'image: codeberg.org/forgejo/forgejo:'
  assert_contains "$s" '-rootless@sha256:'                      # (pinned by digest, rootless)
  assert_contains "$s" 'profiles: ["forgejo"]'
  assert_contains "$s" 'read_only: true'
  assert_contains "$s" 'cap_drop: [ALL]'
  assert_contains "$s" 'no-new-privileges:true'
  assert_contains "$s" 'mem_limit:'
  assert_contains "$s" 'pids_limit:'
  assert_contains "$s" "    networks: [localgit]"               # (no way out to the internet, no other service)
  assert_not_contains "$s" "ports:"
  assert_contains "$s" "gitdata:/var/lib/gitea"
  for kv in 'INSTALL_LOCK: "true"' 'DISABLE_SSH: "true"' 'START_SSH_SERVER: "false"' 'DISABLE_REGISTRATION: "true"' 'REQUIRE_SIGNIN_VIEW: "true"' \
            'DEFAULT_PRIVATE: private' 'ENABLE_PUSH_CREATE_USER: "true"' 'ENABLED: "false"'; do assert_contains "$s" "$kv"; done
  assert_contains "$(sed -n '/^networks:/,/^volumes:/p' "$T_ROOT/compose.yaml")" "  localgit:
    internal: true"
  assert_contains "$(sed -n '/^volumes:/,$p' "$T_ROOT/compose.yaml")" "  gitdata:"
}

test_the_settings_row_and_the_help_know_it() {
  assert_eq "$(setting_field LOCALGIT 4)/$(setting_field LOCALGIT 5)/$(setting_field LOCALGIT 6)" "edit/on_off/localgit"
  assert_contains "$RESTART_SERVICES" forgejo
  printf 'LOCALGIT=off\n' > "$ENV_FILE"; assert_not_contains " $(restart_choices) " " forgejo "
  printf 'X=1\n' > "$ENV_FILE"; assert_contains " $(restart_choices) " " forgejo "
  assert_contains "$(cmd_help)" "searxng | forgejo"
  grep -qE '_cfg_on localgit; then (_cfg_t "[^"]+" )?localgit_up' "$T_ROOT/lib/settings.sh" || { echo "Settings' apply does not know localgit" >&2; return 1; }
  grep -q '^LOCALGIT_ADMIN_PASSWORD' "$T_ROOT/.env.example" && grep -q '^LOCALGIT=' "$T_ROOT/.env.example" || { echo ".env.example lacks the keys" >&2; return 1; }
}

# --- mirroring (./stack git-server mirror …) ---

test_the_mirror_overlay_follows_the_record_and_the_switch() {
  printf 'X=1\n' > "$ENV_FILE"
  assert_not_contains "$(compose_overlays | tr '\n' ' ')" "compose.localgit-mirror.yaml"
  printf 'LOCALGIT_MIRROR_EGRESS=on\nLOCALGIT_MIRROR_HOSTS=github.com\n' > "$ENV_FILE"
  assert_contains "$(compose_overlays | tr '\n' ' ')" "compose.localgit-mirror.yaml"     # (with no terminal too: the git server alone)
  printf 'LOCALGIT_MIRROR_EGRESS=on\nLOCALGIT_MIRROR_HOSTS=\n' > "$ENV_FILE"
  assert_not_contains "$(compose_overlays | tr '\n' ' ')" "compose.localgit-mirror.yaml"  # (no host named: no way out)
  printf 'LOCALGIT_MIRROR_EGRESS=off\nLOCALGIT_MIRROR_HOSTS=github.com\n' > "$ENV_FILE"
  assert_not_contains "$(compose_overlays | tr '\n' ' ')" "compose.localgit-mirror.yaml"
  printf 'LOCALGIT=off\nLOCALGIT_MIRROR_EGRESS=on\nLOCALGIT_MIRROR_HOSTS=github.com\n' > "$ENV_FILE"
  assert_not_contains "$(compose_overlays | tr '\n' ' ')" "compose.localgit-mirror.yaml"  # (off: nothing of it)
  # the file: forgejo on a network of its own to the internet, not internal, and nothing else on it
  c="$(cat "$T_ROOT/compose.localgit-mirror.yaml")"
  assert_contains "$c" "localgit-out: {}"
  assert_not_contains "$(sed -n '/^networks:/,$p' "$T_ROOT/compose.localgit-mirror.yaml" | grep -v '^ *#')" "internal"
  # the names it may reach come from compose.yaml (blank with no mirror), the private-address refusal stays on
  y="$(sed -n '/^  forgejo:/,/^  portal:/p' "$T_ROOT/compose.yaml")"
  assert_contains "$y" 'FORGEJO__migrations__ALLOWED_DOMAINS: ${LOCALGIT_MIRROR_HOSTS:-}'
  assert_contains "$y" 'FORGEJO__migrations__ALLOW_LOCALNETWORKS: "false"'
}

test_the_way_out_follows_the_hosts_and_is_changed_only_when_they_change() {
  printf 'X=1\n' > "$ENV_FILE"
  run_phase() { shift 2; "$@"; }; services_status_write() { :; }
  dc() { echo "dc $*" >> "$TMP/calls"; }
  : > "$TMP/calls"; _lg_mirror_egress_apply "" 2>/dev/null
  assert_eq "$(cat "$TMP/calls")" ""                                          # (nothing there, nothing wanted: nothing done)
  _lg_mirror_egress_apply "github.com" 2>/dev/null
  assert_eq "$(get_env LOCALGIT_MIRROR_HOSTS)/$(get_env LOCALGIT_MIRROR_EGRESS)" "github.com/on"
  assert_contains "$(cat "$TMP/calls")" "up -d --no-deps --wait forgejo"
  : > "$TMP/calls"; _lg_mirror_egress_apply "github.com" 2>/dev/null; assert_eq "$(cat "$TMP/calls")" ""   # (the same: nothing)
  _lg_mirror_egress_apply "github.com,gitlab.com" 2>/dev/null
  assert_eq "$(get_env LOCALGIT_MIRROR_HOSTS)" "github.com,gitlab.com"
  : > "$TMP/calls"; _lg_mirror_egress_apply "" 2>/dev/null
  assert_eq "$(get_env LOCALGIT_MIRROR_HOSTS)/$(get_env LOCALGIT_MIRROR_EGRESS)" "/off"
  assert_contains "$(cat "$TMP/calls")" "up -d --no-deps --wait forgejo"
}

test_reconcile_asks_the_server_and_changes_nothing_it_cannot_ask() {
  printf 'LOCALGIT_MIRROR_EGRESS=on\nLOCALGIT_MIRROR_HOSTS=github.com\nTERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=/w\nCODE_ENABLED=true\n' > "$ENV_FILE"
  code_ready() { return 0; }; _lg_running() { return 0; }; services_status_write() { :; }; run_phase() { shift 2; "$@"; }
  dc() { echo "dc $*" >> "$TMP/calls"; case "$*" in "ps -q --status running code") echo abc ;; esac; }
  _lg_hosts_csv() { return 1; }                                               # (the server cannot be asked)
  : > "$TMP/calls"; localgit_mirror_reconcile
  assert_eq "$(get_env LOCALGIT_MIRROR_HOSTS)" "github.com"
  _lg_hosts_csv() { printf 'gitlab.com'; }                                    # (it has a mirror to gitlab.com only)
  localgit_mirror_reconcile 2>/dev/null
  assert_eq "$(get_env LOCALGIT_MIRROR_HOSTS)" "gitlab.com"
  _lg_hosts_csv() { printf ''; }
  localgit_mirror_reconcile 2>/dev/null
  assert_eq "$(get_env LOCALGIT_MIRROR_EGRESS)" "off"
  code_ready() { return 1; }; : > "$TMP/calls"; localgit_mirror_reconcile; assert_eq "$(cat "$TMP/calls")" ""   # (no Code page: nothing)
}

test_adding_a_mirror_says_what_it_does_asks_makes_the_way_out_first_and_undoes_it_on_failure() {
  printf 'LOCALGIT_MIRROR_EGRESS=off\n' > "$ENV_FILE"
  _lg_code_ready() { return 0; }; stack_lock() { :; }; stack_unlock() { :; }; stack_lock_ours() { return 1; }
  services_status_write() { :; }; run_phase() { shift 2; "$@"; }
  ASK=y; _githost_confirm() { echo "ASKED" >> "$TMP/calls"; [ "$ASK" = y ]; }
  _lg_hosts_csv() { printf 'gitlab.com'; }
  dc() { echo "dc $*" >> "$TMP/calls"; }
  OP_OK=1
  _lg_mirror_op() { echo "op $1" >> "$TMP/calls"; _LG_ANSWER='{"ok":true}'; [ "$OP_OK" = 1 ] || { _LG_ANSWER='{"ok":false,"error":"the git server refused: nope"}'; return 1; }; }
  localgit_mirror_reconcile() { echo "reconcile" >> "$TMP/calls"; }
  : > "$TMP/calls"
  out="$(localgit_mirror_add push app https://github.com/me/app --interval 2h 2>&1)"
  assert_contains "$out" "FORCE-UPDATES the remote's refs"
  assert_contains "$out" "handed to Forgejo"
  assert_contains "$out" "limited to: gitlab.com"
  assert_contains "$out" "github.com"
  c="$(tr '\n' '|' < "$TMP/calls")"
  assert_contains "$c" 'ASKED|'
  # the allowed names first (the existing hosts and the new one), the mirror after
  a="${c%%up -d --no-deps --wait forgejo*}"; assert_not_contains "$a" "op {"
  assert_eq "$(get_env LOCALGIT_MIRROR_HOSTS)" "gitlab.com,github.com"
  assert_contains "$c" '"op":"add","direction":"push","repo":"app","remote":"https://github.com/me/app","syncOnCommit":true,"interval":"2h"'
  # a mirror the server refused: the way out is reconciled with the mirrors there are, and it is said
  : > "$TMP/calls"; OP_OK=0
  out="$(localgit_mirror_add pull src https://github.com/me/src 2>&1)" && { echo "a refused mirror said ok" >&2; return 1; }
  assert_contains "$out" "no mirror made: the git server refused: nope"
  assert_contains "$(cat "$TMP/calls")" "reconcile"
  # not confirmed: nothing is made, no way out
  : > "$TMP/calls"; set_env LOCALGIT_MIRROR_HOSTS ''; ASK=n
  out="$(localgit_mirror_add push app https://github.com/me/app 2>&1)" && return 1
  assert_contains "$out" "No mirror made."
  assert_not_contains "$(cat "$TMP/calls")" "op {"
  assert_eq "$(get_env LOCALGIT_MIRROR_HOSTS)" ""
}

test_the_mirror_commands_refuse_what_is_not_theirs() {
  _lg_code_ready() { return 0; }
  for args in "push" "push app" "sideways app https://github.com/o/r" "push 'a b' https://github.com/o/r" "push app http://github.com/o/r" "push app git@github.com:o/r.git" \
              "push -x https://github.com/o/r" "push app https://github.com/o/r --interval 5x" "push app https://github.com/o/r --bogus"; do
    out="$(eval "localgit_mirror_add $args" 2>&1)" && { echo "accepted: $args" >&2; return 1; }
  done
  out="$(localgit_mirror_sync '' 2>&1)" && return 1; assert_contains "$out" "usage: ./stack git-server mirror sync"
  out="$(localgit_mirror_remove app 2>&1)" && return 1; assert_contains "$out" "usage: ./stack git-server mirror remove"
  assert_contains "$(cmd_help)" "git-server   The built-in git server (Forgejo)"
  assert_contains "$("$BASH" "$STACK_DIR/stack" git-server --help 2>&1)" "Usage: ./stack git-server status"
  assert_contains "$(localgit_mirror_usage)" "FORCE-UPDATES"
  assert_contains "$(localgit_mirror_usage)" "A normal remote you fetch from and push to is a different thing"
}

# --- JON-970: the Git hosts dialog's requests, through the update helper, run these same commands ---

_lg_stubs_for_the_dialog() {
  printf 'LOCALGIT_MIRROR_EGRESS=off\n' > "$ENV_FILE"
  _lg_code_ready() { return 0; }; stack_lock() { :; }; stack_unlock() { :; }; stack_lock_ours() { return 1; }
  services_status_write() { :; }; run_phase() { shift 2; "$@"; }
  ASSUME_YES=1
  _lg_hosts_csv() { printf 'gitlab.com'; }
  dc() { echo "dc $*" >> "$TMP/calls"; }
  OP_OK=1
  _lg_mirror_op() {
    echo "op $1" >> "$TMP/calls"
    case "$1" in
      *'"op":"resolve"'*) _LG_ANSWER='{"ok":true,"host":"github.com","label":"GitHub","remote":"https://github.com/me/app.git"}' ;;
      *) _LG_ANSWER='{"ok":true}' ;;
    esac
    [ "$OP_OK" = 1 ] || { _LG_ANSWER='{"ok":false,"error":"the git server refused: nope"}'; return 1; }
  }
  localgit_mirror_reconcile() { echo "reconcile" >> "$TMP/calls"; }
  _ss_code() { local a; for a in "$@"; do case "$a" in --secs | 30) ;; *) printf '%s ' "$a" >> "$TMP/told"; ;; esac; done; echo >> "$TMP/told"; }
  : > "$TMP/calls"; : > "$TMP/told"
}

test_a_mirror_made_from_the_dialog_names_a_host_by_id_and_a_path_and_never_an_address_or_a_token() {
  _lg_stubs_for_the_dialog
  out="$(localgit_mirror_add push app --host h_0123456789ab --path me/app --interval 2h 2>&1)"
  c="$(tr '\n' '|' < "$TMP/calls")"
  # the host's name comes from the code container (resolve), before the way out; the add then carries the address it gave
  assert_contains "$c" 'op {"op":"resolve","host":"h_0123456789ab","path":"me/app"}|'
  assert_eq "$(get_env LOCALGIT_MIRROR_HOSTS)" "gitlab.com,github.com"
  assert_contains "$c" '"op":"add","direction":"push","repo":"app","remote":"https://github.com/me/app.git","syncOnCommit":true,"interval":"2h"'
  assert_contains "$out" "Mirror made: push app"
  # what is not an id or a path is refused before anything is asked of the container
  : > "$TMP/calls"
  for args in "push app --host nope --path me/app" "push app --host h_0123456789ab --path ../x" "push app --host h_0123456789ab" "push app --path me/app" \
              "push app --host h_0123456789ab --path me/app https://github.com/me/app" "push app --host h_0123456789ab --path 'a b'"; do
    out="$(eval "localgit_mirror_add $args" 2>&1)" && { echo "accepted: $args" >&2; return 1; }
  done
  assert_eq "$(cat "$TMP/calls")" ""
}

test_a_mirror_changed_from_the_dialog_keeps_the_way_out_and_says_what_it_asked() {
  _lg_stubs_for_the_dialog
  out="$(localgit_mirror_change app remote_mirror_ab12 --interval 2h --no-sync-on-commit 2>&1)"
  assert_contains "$(cat "$TMP/calls")" '{"op":"change","repo":"app","name":"remote_mirror_ab12","interval":"2h","syncOnCommit":false}'
  assert_contains "$out" "Mirror remote_mirror_ab12 of app changed"
  : > "$TMP/calls"; localgit_mirror_change app m1 --sync-on-commit >/dev/null 2>&1
  assert_contains "$(cat "$TMP/calls")" '{"op":"change","repo":"app","name":"m1","syncOnCommit":true}'
  : > "$TMP/calls"
  for args in "" "app" "app m1 --interval 5x" "app m1 --bogus" "'a b' m1" "app m1 --interval"; do
    out="$(eval "localgit_mirror_change $args" 2>&1)" && { echo "accepted: $args" >&2; return 1; }
  done
  assert_not_contains "$(cat "$TMP/calls")" "op {"
  OP_OK=0; out="$(localgit_mirror_change app m1 --interval 2h 2>&1)" && return 1
  assert_contains "$out" "not changed: the git server refused: nope"
  assert_contains "$(localgit_mirror_usage)" "mirror change REPO NAME"
  assert_contains "$(localgit_mirror_usage)" "--host ID --path OWNER/REPO"
}

test_a_request_from_the_page_is_told_done_or_failed_with_the_reason_and_never_a_credential() {
  _lg_stubs_for_the_dialog
  local n=0123456789abcdef0123456789abcdef
  localgit_mirror_cmd sync app --request "$n" >/dev/null 2>&1
  assert_contains "$(cat "$TMP/told")" "request --id $n --state done --action git-mirror-sync"
  assert_contains "$(cat "$TMP/calls")" '{"op":"sync","repo":"app","direction":"push"}'
  # a failure: the helper is told failed, why "mirror", and the words (the code container cleaned them)
  : > "$TMP/told"; OP_OK=0
  ( localgit_mirror_cmd remove app m1 --request "$n" ) >"$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/told")" "request --id $n --state failed --why mirror --action git-mirror-remove --note not removed: the git server refused: nope"
  assert_contains "$(cat "$TMP/out")" "sessions-result: failed"
  # a bad request id is no request: the command runs, nothing is told
  : > "$TMP/told"; OP_OK=1
  localgit_mirror_cmd sync app --request nonsense >/dev/null 2>&1 || true
  assert_eq "$(cat "$TMP/told")" ""
}

test_the_web_site_signs_the_owner_in_only_after_the_portal_and_the_sandboxs_paths_remove_the_header() {
  s="$(cat "$T_ROOT/caddy/localgit-on.caddy")"
  # the header is set in the proxy block of the site that imports portal_auth, after it (route order), and nowhere else
  assert_eq "$(printf '%s\n' "$s" | grep -c 'header_up {$LOCALGIT_SSO_HEADER} devos')" 1
  site="$(printf '%s\n' "$s" | sed -n '/^{\$LOCAL_SCHEME:http}:\/\/{\$GIT_HOST} {/,/^}/p')"
  assert_contains "$site" 'header_up {$LOCALGIT_SSO_HEADER} devos'
  [ "$(printf '%s\n' "$site" | grep -n 'import portal_auth' | cut -d: -f1)" -lt "$(printf '%s\n' "$site" | grep -n 'header_up {$LOCALGIT_SSO_HEADER}' | cut -d: -f1)" ] || { echo "the header is set before the web app's check" >&2; return 1; }
  # the other ways to Forgejo remove one a client sent
  for f in caddy/localgit-gateway-on.caddy; do assert_contains "$(cat "$T_ROOT/$f")" "request_header -X-Webauth-User"; done
  mirrors="$(printf '%s\n' "$s" | sed -n '/^http:\/\/:8099 {/,/^}/p')"
  assert_contains "$mirrors" "request_header -X-Webauth-User"
  assert_contains "$mirrors" "request_header -X-Bn-Git-*"
  assert_contains "$(cat "$T_ROOT/caddy/localgit-gateway-on.caddy")" "request_header -X-Bn-Git-*"
  # the web site strips the whole family before it sets its own (a step of its own: Caddy deletes after it sets within one block)
  assert_contains "$site" "request_header -X-Bn-Git-*"
  assert_not_contains "$mirrors" "header_up"
  # the internal site: reads, a migration and the mirror paths — never a delete of a repository, the admin or the account API
  assert_contains "$mirrors" "method GET"
  assert_contains "$mirrors" "path /api/v1/repos/migrate"
  assert_contains "$mirrors" 'push_mirrors(/[A-Za-z0-9._-]+)?|push_mirrors-sync|mirror-sync'
  assert_not_contains "$mirrors" "admin"
  # (and, for the portal's Git search, the two GET searches — a matcher of their own, GET and those paths only)
  assert_eq "$(printf '%s\n' "$mirrors" | grep -c 'reverse_proxy')" 6
  # (and the one POST of git's that makes an empty repository for a kept project: that path, that method and that content type only)
  assert_contains "$(printf '%s\n' "$mirrors" | sed -n '/@create {/,/}/p')" "method POST"
  assert_contains "$(printf '%s\n' "$mirrors" | sed -n '/@create {/,/}/p')" 'git-receive-pack$'
  assert_contains "$(printf '%s\n' "$mirrors" | sed -n '/@create {/,/}/p')" "header Content-Type application/x-git-receive-pack-request"
  assert_contains "$mirrors" "reverse_proxy @create forgejo:3000"
  # (and the one POST that protects a kept repository's default branch: that method and that path only — no read, change or delete of a rule)
  assert_contains "$(printf '%s\n' "$mirrors" | sed -n '/@protect {/,/}/p')" "method POST"
  assert_contains "$(printf '%s\n' "$mirrors" | sed -n '/@protect {/,/}/p')" 'path_regexp ^/api/v1/repos/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/branch_protections$'
  assert_not_contains "$(printf '%s\n' "$mirrors" | sed -n '/@protect {/,/}/p')" "method GET"
  assert_contains "$mirrors" "reverse_proxy @protect forgejo:3000"
  assert_contains "$(printf '%s\n' "$mirrors" | sed -n '/@search {/,/}/p')" "method GET"
  assert_contains "$(printf '%s\n' "$mirrors" | sed -n '/@search {/,/}/p')" "path /api/v1/repos/search /api/v1/repos/issues/search"
  assert_contains "$mirrors" "reverse_proxy @search forgejo:3000"
  y="$(sed -n '/^  forgejo:/,/^  portal:/p' "$T_ROOT/compose.yaml")"
  assert_contains "$y" 'FORGEJO__service__ENABLE_REVERSE_PROXY_AUTHENTICATION: ${LOCALGIT_SSO_ON:-false}'
  assert_contains "$y" 'FORGEJO__service__ENABLE_REVERSE_PROXY_AUTO_REGISTRATION: "false"'
  assert_contains "$y" 'FORGEJO__service__ENABLE_REVERSE_PROXY_AUTHENTICATION_API: "false"'
  }

test_the_sign_in_header_has_a_secret_name_only_caddy_and_forgejo_know() {
  # (Forgejo's trusted-proxy setting does not limit who may send it — tests/e2e/localgit proves a forged header from another peer
  # signs in — so the control is the name: a secret of ./stack's, in the environments of Caddy and Forgejo alone)
  y="$(sed -n '/^  forgejo:/,/^  portal:/p' "$T_ROOT/compose.yaml")"
  assert_contains "$y" 'FORGEJO__security__REVERSE_PROXY_AUTHENTICATION_USER: ${LOCALGIT_SSO_HEADER:-}'
  assert_not_contains "$y" 'REVERSE_PROXY_AUTHENTICATION_USER: X-Webauth-User'
  assert_contains "$(sed -n '/^  caddy:/,/^  [a-z-]*:$/p' "$T_ROOT/compose.yaml")" 'LOCALGIT_SSO_HEADER: ${LOCALGIT_SSO_HEADER:-}'
  # fail closed: no public fallback name anywhere, and the sign-in is off by default (and without a secret)
  assert_not_contains "$(cat "$T_ROOT/compose.yaml" "$T_ROOT/caddy/localgit-on.caddy" "$T_ROOT/lib/localgit.sh" "$T_ROOT/lib/common.sh")" "X-Bn-Git-Unset"
  assert_not_contains "$(cat "$T_ROOT/compose.yaml")" 'ENABLE_REVERSE_PROXY_AUTHENTICATION: "true"'
  # the second layer: Forgejo's X-Forwarded-For trust is Caddy's fixed address alone, one hop, never a wildcard
  assert_contains "$y" 'FORGEJO__security__REVERSE_PROXY_TRUSTED_PROXIES: ${LOCALGIT_CADDY_IP:-10.255.255.238}/32'
  assert_contains "$y" 'FORGEJO__security__REVERSE_PROXY_LIMIT: "1"'
  assert_not_contains "$y" 'TRUSTED_PROXIES: "*"'
  assert_contains "$(cat "$T_ROOT/compose.yaml")" 'ipv4_address: ${LOCALGIT_CADDY_IP:-10.255.255.238}'
  assert_contains "$(cat "$T_ROOT/compose.yaml")" 'subnet: ${LOCALGIT_SUBNET:-10.255.255.224/28}'
  assert_not_contains "$(cat "$T_ROOT/compose.yaml")" 'ipv4_address: 10.255.255.238'   # the address is never fixed in the file
  assert_contains "$(cat "$T_ROOT/caddy/localgit-on.caddy")" 'header_up {$LOCALGIT_SSO_HEADER} devos'
  for f in portal terminal litellm open-webui shared-mcp postgres rustfs searxng stt code; do
    assert_not_contains "$(sed -n "/^  $f:/,/^  [a-z-]*:\$/p" "$T_ROOT/compose.yaml")" "LOCALGIT_SSO_HEADER" || { echo "$f gets the secret name" >&2; return 1; }
  done
  assert_not_contains "$(cat "$T_ROOT/compose.terminal.yaml" "$T_ROOT/compose.code.yaml" "$T_ROOT/compose.localgit.yaml")" "LOCALGIT_SSO_HEADER"
  : > "$ENV_FILE"; localgit_secrets
  h="$(get_env LOCALGIT_SSO_HEADER)"
  case "$h" in X-Bn-Git-????????????????????????????????) ;; *) echo "not a secret name: $h" >&2; return 1 ;; esac
  localgit_secrets; assert_eq "$(get_env LOCALGIT_SSO_HEADER)" "$h"
  # never passed on from the shell: .env decides, and every dc call makes the secret and turns the sign-in on only with it
  printf 'X=1\n' > "$ENV_FILE"; mkdir -p "$TMP/bin"; printf '#!/bin/sh\nenv | grep "^LOCALGIT_SSO_" || true\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
  out="$(PATH="$TMP/bin:$PATH" LOCALGIT_SSO_HEADER=evil LOCALGIT_SSO_ON=true dc ps)"
  assert_not_contains "$out" "evil"
  assert_contains "$out" "LOCALGIT_SSO_ON=true"
  assert_contains "$out" "LOCALGIT_SSO_HEADER=$(get_env LOCALGIT_SSO_HEADER)"
  case "$(get_env LOCALGIT_SSO_HEADER)" in X-Bn-Git-????????????????????????????????) ;; *) echo "dc made no secret" >&2; return 1 ;; esac
  # no secret (and the switch off, so none is made): the sign-in is off
  printf 'LOCALGIT=off\n' > "$ENV_FILE"
  out="$(PATH="$TMP/bin:$PATH" LOCALGIT_SSO_ON=true dc ps)"
  assert_contains "$out" "LOCALGIT_SSO_ON=false"
  assert_eq "$(get_env LOCALGIT_SSO_HEADER)" ""
}

# --- the portal's Git search token (JON-979): read-only, in .env, in the portal container alone ---

test_the_search_token_is_made_with_the_narrowest_scopes_kept_in_env_mode_600_and_never_on_a_command_line() {
  printf 'X=1\n' > "$ENV_FILE"; chmod 644 "$ENV_FILE"
  TOK="gt$(printf 'q%.0s' $(seq 1 38))"
  : > "$TMP/calls"
  dc() {
    echo "dc $*" >> "$TMP/calls"
    case "$*" in
      *"generate-access-token"*) echo "$TOK" ;;
      *"curl"*) cat >> "$TMP/stdin" ;;
    esac
  }
  assert_eq "$LOCALGIT_READ_SCOPES" "read:repository,read:issue"
  localgit_read_token_ensure || { echo "no token made" >&2; return 1; }
  assert_contains "$(cat "$TMP/calls")" "generate-access-token --username devos --token-name devos-ade-search-"
  assert_contains "$(cat "$TMP/calls")" "--scopes read:repository,read:issue --raw"
  assert_not_contains "$(cat "$TMP/calls")" "write:"                       # (nothing that changes a repository)
  assert_not_contains "$(cat "$TMP/calls")" "$TOK"                         # (never on a command line)
  assert_eq "$(get_env LOCALGIT_READ_TOKEN)" "$TOK"
  assert_eq "$(perm_of "$ENV_FILE")" 600
  assert_eq "$_LG_READ_TOKEN_NEW" 1
}

test_the_search_token_is_kept_while_the_server_accepts_it_and_made_again_when_it_does_not() {
  TOK="gt$(printf 'q%.0s' $(seq 1 38))"; NEW="gt$(printf 'n%.0s' $(seq 1 38))"
  printf 'LOCALGIT_READ_TOKEN=%s\n' "$TOK" > "$ENV_FILE"
  : > "$TMP/calls"; : > "$TMP/stdin"; ACCEPT=1
  dc() {
    echo "dc $*" >> "$TMP/calls"
    case "$*" in
      *"generate-access-token"*) echo "$NEW" ;;
      *"curl"*) cat >> "$TMP/stdin"; [ "$ACCEPT" = 1 ] ;;
    esac
  }
  localgit_read_token_ensure || return 1
  assert_not_contains "$(cat "$TMP/calls")" "generate-access-token"           # (kept)
  assert_eq "$_LG_READ_TOKEN_NEW" ""
  assert_eq "$(get_env LOCALGIT_READ_TOKEN)" "$TOK"
  # the check puts the token on curl's stdin as a header line: not in the arguments
  assert_contains "$(cat "$TMP/stdin")" "Authorization: token $TOK"
  assert_not_contains "$(cat "$TMP/calls")" "$TOK"
  assert_contains "$(cat "$TMP/calls")" "curl -fsS -o /dev/null -K - http://127.0.0.1:3000/api/v1/repos/search?limit=1"
  # a token the server refuses (the volume was removed and made again): a new one
  ACCEPT=0; localgit_read_token_ensure || return 1
  assert_eq "$(get_env LOCALGIT_READ_TOKEN)" "$NEW"
  assert_eq "$_LG_READ_TOKEN_NEW" 1
  # the command printing nothing: .env keeps what it had, and it is said by the failure
  printf 'LOCALGIT_READ_TOKEN=%s\n' "$TOK" > "$ENV_FILE"; ACCEPT=0
  dc() { case "$*" in *"curl"*) cat >/dev/null; return 1 ;; *"generate-access-token"*) return 1 ;; esac; }
  ! localgit_read_token_ensure || { echo "a failed token counted as made" >&2; return 1; }
  assert_eq "$(get_env LOCALGIT_READ_TOKEN)" "$TOK"
}

test_after_up_recreates_the_portal_only_for_a_new_token_and_says_when_there_is_none() {
  printf 'X=1\n' > "$ENV_FILE"
  _lg_running() { return 0; }; localgit_ensure_admin() { return 0; }; localgit_register_host() { return 0; }
  : > "$TMP/calls"
  up_services() { echo "up_services $*" >> "$TMP/calls"; }
  localgit_read_token_ensure() { _LG_READ_TOKEN_NEW=1; return 0; }
  localgit_after_up
  assert_contains "$(cat "$TMP/calls")" "up_services --no-deps portal"
  : > "$TMP/calls"; localgit_read_token_ensure() { _LG_READ_TOKEN_NEW=''; return 0; }
  localgit_after_up; assert_eq "$(cat "$TMP/calls")" ""                        # (a token that stands: nothing restarts)
  localgit_read_token_ensure() { return 1; }
  out="$(localgit_after_up 2>&1)"; rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "could not make the token the web app's Git search uses"
  printf 'LOCALGIT=off\n' > "$ENV_FILE"; : > "$TMP/calls"; localgit_read_token_ensure() { echo ensure >> "$TMP/calls"; }
  localgit_after_up; assert_eq "$(cat "$TMP/calls")" ""                        # (off: nothing)
}

test_the_search_token_reaches_the_portal_container_and_no_other_service() {
  # the portal's environment holds it (and the mode and the API address to use it with) ...
  p="$(sed -n '/^  portal:/,/^  caddy:/p' "$T_ROOT/compose.yaml")"
  assert_contains "$p" 'LOCALGIT_READ_TOKEN: ${LOCALGIT_READ_TOKEN:-}'
  assert_contains "$p" 'LOCALGIT_MODE: ${BN_LOCALGIT_MODE:-off}'
  assert_contains "$p" 'LOCALGIT_API_URL: http://caddy:8099'
  # ... and no other service of compose.yaml or any overlay does: not the terminal, the Code page, the sandbox's gateway, Forgejo
  # itself (it makes the token, the stack hands it over), Caddy, Chat or the rest
  n="$(grep -c 'LOCALGIT_READ_TOKEN' "$T_ROOT/compose.yaml")"
  assert_eq "$n" 1
  for f in "$T_ROOT"/compose.*.yaml; do assert_not_contains "$(cat "$f")" "LOCALGIT_READ_TOKEN" || { echo "$f holds the token" >&2; return 1; }; done
  for f in terminal code terminal-gateway forgejo caddy litellm open-webui shared-mcp postgres rustfs searxng stt; do
    assert_not_contains "$(sed -n "/^  $f:/,/^  [a-z-]*:\$/p" "$T_ROOT/compose.yaml")" "LOCALGIT_READ_TOKEN" || { echo "$f holds the token" >&2; return 1; }
  done
  # no env_file anywhere: .env is not handed to a container whole
  assert_not_contains "$(cat "$T_ROOT"/compose*.yaml)" "env_file"
  # nothing in the code, terminal or sandbox sources names it
  assert_not_contains "$(cat "$T_ROOT"/terminal/*.sh 2>/dev/null; cat "$T_ROOT"/code/server/*.mjs 2>/dev/null)" "LOCALGIT_READ_TOKEN"
}

test_the_search_token_is_not_taken_from_the_shell_and_not_printed() {
  printf 'LOCALGIT_READ_TOKEN=fromenv\n' > "$ENV_FILE"; mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nenv | grep -E "^LOCALGIT_(READ_TOKEN|CODE_INDEXER)=" | sort || true\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
  # compose reads .env itself (--env-file); a shell's value never beats it
  out="$(PATH="$TMP/bin:$PATH" LOCALGIT_READ_TOKEN=evil LOCALGIT_INDEXER=true dc ps)"
  assert_not_contains "$out" "evil"
  assert_not_contains "$out" "LOCALGIT_INDEXER"
  # setup's and status's output name the key, never the value
  TOK="gt$(printf 'q%.0s' $(seq 1 38))"; printf 'LOCALGIT_READ_TOKEN=%s\nLOCALGIT_ADMIN_PASSWORD=Lg9-0123456789abcdef0123456789ab\n' "$TOK" > "$ENV_FILE"
  assert_not_contains "$(localgit_status_line; localgit_summary_line)" "$TOK"
  # the catalog and .env.example know the key as a secret, read-only
  grep -qE '^LOCALGIT_READ_TOKEN	advanced	S	ro	' "$T_ROOT/catalog/settings.tsv" || { echo "settings.tsv: not a read-only secret" >&2; return 1; }
  grep -q '^LOCALGIT_READ_TOKEN=' "$T_ROOT/.env.example" || { echo ".env.example lacks the key" >&2; return 1; }
}

test_code_search_follows_the_indexer_switch_in_forgejo_and_the_portal() {
  y="$(sed -n '/^  forgejo:/,/^  portal:/p' "$T_ROOT/compose.yaml")"
  assert_contains "$y" 'FORGEJO__indexer__REPO_INDEXER_ENABLED: ${LOCALGIT_INDEXER:-false}'   # (off unless asked for)
  assert_contains "$(sed -n '/^  portal:/,/^  caddy:/p' "$T_ROOT/compose.yaml")" 'LOCALGIT_INDEXER: ${LOCALGIT_INDEXER:-false}'
  grep -q '^LOCALGIT_INDEXER=' "$T_ROOT/.env.example" || { echo ".env.example lacks the key" >&2; return 1; }
}

# --- the git server's own network: LOCALGIT_SUBNET, and Caddy's address derived from it (like REMOTE_SUBNET) ---

test_localgit_subnet_defaults_stay_the_values_installs_have() {
  printf 'X=1\n' > "$ENV_FILE"
  assert_eq "$(localgit_subnet)" 10.255.255.224/28
  assert_eq "$(localgit_caddy_ip "$(localgit_subnet)")" 10.255.255.238
  printf 'LOCALGIT_SUBNET=10.254.3.16/28\n' > "$ENV_FILE"
  assert_eq "$(localgit_subnet)" 10.254.3.16/28
  assert_eq "$(localgit_caddy_ip 10.254.3.16/28)" 10.254.3.30
  assert_eq "$(localgit_caddy_ip 10.99.0.0/24)" 10.99.0.254
  # compose: the variable forms, each with the old value as its default
  local c; c="$(cat "$T_ROOT/compose.yaml")"
  assert_contains "$c" '${LOCALGIT_SUBNET:-10.255.255.224/28}'
  assert_contains "$c" '${LOCALGIT_CADDY_IP:-10.255.255.238}/32'
  assert_contains "$c" 'ipv4_address: ${LOCALGIT_CADDY_IP:-10.255.255.238}'
}

test_localgit_subnet_must_be_a_24_to_28_without_host_bits() {
  valid_localgit_subnet 10.255.255.224/28 && valid_localgit_subnet 10.254.3.16/28 && valid_localgit_subnet 10.99.0.0/24 || return 1
  local n
  for n in 10.255.255.248/29 10.255.255.232/28 10.254.3.17/28 10.0.0.0/16 10.0.0.0/8 10.254.3.16 10.254.3.16/ abc 10.254.3.300/28 10.254.3.16/28/1 ''; do
    if valid_localgit_subnet "$n"; then echo "accepted '$n'" >&2; return 1; fi
  done
  printf 'LOCALGIT_SUBNET=10.254.3.17/28\n' > "$ENV_FILE"
  assert_contains "$(localgit_net_ok)" "not an IPv4 network from /24 to /28 without host bits"
  printf 'LOCALGIT_SUBNET=10.255.255.248/29\n' > "$ENV_FILE"
  assert_contains "$(localgit_net_ok)" "LOCALGIT_SUBNET=10.255.255.248/29"
}

test_localgit_net_ok_names_the_colliding_network_and_a_free_slash_28() {
  printf 'COMPOSE_PROJECT_NAME=bn\nLOCALGIT_SUBNET=10.255.255.224/28\n' > "$ENV_FILE"
  docker() {
    case "$1" in
      network) case "$2" in ls) printf 'a\nb\nc\n' ;;
               inspect) printf 'bridge 172.17.0.0/16 \nbn_localgit 10.255.255.224/28 \nbn2_localgit 10.255.255.224/28 \ncorp_vpn 10.0.0.0/8 fd00::/64 \n' ;; esac ;;
    esac
  }
  out="$(localgit_net_ok)" && { echo "should collide" >&2; return 1; }
  assert_contains "$out" "overlaps Docker network bn2_localgit (10.255.255.224/28)"   # another stack's, not its own bn_localgit
  assert_contains "$out" "LOCALGIT_SUBNET in .env to a free /28"
  set_env LOCALGIT_SUBNET 10.254.3.16/28
  docker() { case "$2" in ls) echo a ;; inspect) printf 'bridge 172.17.0.0/16 \nbn_localgit 10.255.255.224/28 \nbn2_localgit 10.254.8.0/28 \n' ;; esac; }
  localgit_net_ok || return 1
  docker() { case "$2" in ls) echo a ;; inspect) printf 'bn_localgit 10.254.3.16/28 \n' ;; esac; }
  localgit_net_ok || return 1   # its own network does not count
  docker() { case "$2" in ls) echo a ;; inspect) printf 'other 10.254.3.0/24 \n' ;; esac; }
  assert_contains "$(localgit_net_ok)" "overlaps Docker network other (10.254.3.0/24)"
  docker() { return 1; }
  localgit_net_ok || return 1   # no Docker answer: nothing to collide with
}

test_localgit_subnet_must_not_overlap_the_remote_one_while_remote_is_on() {
  docker() { return 1; }
  printf 'REMOTE_MODE=tailscale\nREMOTE_SUBNET=10.99.0.0/24\nLOCALGIT_SUBNET=10.99.0.16/28\n' > "$ENV_FILE"
  assert_contains "$(localgit_net_ok)" "overlaps REMOTE_SUBNET 10.99.0.0/24"
  printf 'REMOTE_MODE=off\nREMOTE_SUBNET=10.99.0.0/24\nLOCALGIT_SUBNET=10.99.0.16/28\n' > "$ENV_FILE"
  localgit_net_ok || return 1
}

test_localgit_preflight_writes_caddys_address_for_a_set_subnet_and_stops_on_a_bad_one() {
  docker() { return 1; }
  printf 'LOCALGIT_SUBNET=10.254.3.16/28\n' > "$ENV_FILE"
  localgit_net_preflight
  assert_eq "$(get_env LOCALGIT_CADDY_IP)" 10.254.3.30
  set_env LOCALGIT_SUBNET 10.254.3.17/28
  out="$( (localgit_net_preflight) 2>&1)" && { echo "should stop" >&2; return 1; }
  assert_contains "$out" "without host bits"
  assert_eq "$(get_env LOCALGIT_CADDY_IP)" 10.254.3.30   # left as it was
}

test_localgit_default_path_never_calls_docker_and_leaves_env_alone() {
  docker() { echo "docker called: $*" >&2; return 99; }
  printf 'X=1\n' > "$ENV_FILE"
  localgit_net_ok || return 1
  localgit_net_preflight || return 1
  assert_eq "$(cat "$ENV_FILE")" "X=1"   # no LOCALGIT_CADDY_IP added to an existing install
  printf 'LOCALGIT_CADDY_IP=10.254.3.30\n' > "$ENV_FILE"
  localgit_net_preflight || return 1
  assert_eq "$(get_env LOCALGIT_CADDY_IP)" 10.255.255.238   # a stale one is put back
  printf 'LOCALGIT_CADDY_IP=10.255.255.238\n' > "$ENV_FILE"
  localgit_net_preflight || return 1
  assert_eq "$(cat "$ENV_FILE")" "LOCALGIT_CADDY_IP=10.255.255.238"
}

test_localgit_a_set_subnet_still_gets_the_docker_overlap_check() {
  printf 'COMPOSE_PROJECT_NAME=bn\nLOCALGIT_SUBNET=10.254.3.16/28\n' > "$ENV_FILE"
  docker() { case "$2" in ls) echo a ;; inspect) printf 'other 10.254.3.0/24 \n' ;; esac; }
  out="$( (localgit_net_preflight) 2>&1)" && { echo "should stop" >&2; return 1; }
  assert_contains "$out" "overlaps Docker network other (10.254.3.0/24)"
}

# --- the restore's script and the backup space check (JON-1145); the script is run by sh against temp folders, no Docker ---

_lg_mkvol() { # a volume with old contents, and a backup folder holding a good archive of a different set
  VOL="$TMP/vol"; BK="$TMP/bk"; SRC="$TMP/src"
  rm -rf "$VOL" "$BK" "$SRC"; mkdir -p "$VOL/git/repositories/old" "$BK" "$SRC/git/repositories/new" "$SRC/gitea"
  echo "old-head" > "$VOL/git/repositories/old/HEAD"; echo "old-ini" > "$VOL/app.ini"; echo "hid" > "$VOL/.hidden"
  echo "new-head" > "$SRC/git/repositories/new/HEAD"; echo "new-ini" > "$SRC/app.ini"; echo "newhid" > "$SRC/.dot"
  chmod 640 "$SRC/app.ini"
  tar -C "$SRC" -czf "$BK/gitdata.tar.gz" .
}
_lg_run() { V="$VOL" B="$BK" sh -c "$(_lg_restore_script "$1")" 2> "$TMP/lg.err"; }
_lg_snap() { (cd "$VOL" && find . -type f -exec cksum {} + | sort; find . | sort) | cksum; }

test_the_restore_script_replaces_the_contents_and_leaves_no_working_folder() {
  _lg_mkvol; chmod 600 "$BK/gitdata.tar.gz"
  _lg_run all || { cat "$TMP/lg.err" >&2; return 1; }
  assert_eq "$(cat "$VOL/app.ini")" "new-ini"
  assert_eq "$(cat "$VOL/git/repositories/new/HEAD")" "new-head"
  assert_eq "$(cat "$VOL/.dot")" "newhid"
  assert_eq "$([ -e "$VOL/git/repositories/old" ] || [ -e "$VOL/.hidden" ] && echo old || echo gone)" "gone"
  assert_eq "$([ -e "$VOL/.restore-new" ] || [ -e "$VOL/.restore-old" ] && echo left || echo none)" "none"
  assert_eq "$(find "$VOL" -name app.ini -perm 640 | wc -l | tr -d ' ')" "1"   # the archive's modes kept
}

test_a_damaged_archive_leaves_the_old_contents_byte_identical_and_no_staging_folder() {
  _lg_mkvol
  head -c 40 /dev/urandom > "$TMP/pad"
  # a big enough member so the gzip stream has a data section to cut after the headers
  head -c 300000 /dev/urandom > "$SRC/git/big.pack"; tar -C "$SRC" -czf "$BK/gitdata.tar.gz" .
  local size; size="$(wc -c < "$BK/gitdata.tar.gz" | tr -d ' ')"
  head -c $((size / 2)) "$BK/gitdata.tar.gz" > "$TMP/cut.tgz"; mv "$TMP/cut.tgz" "$BK/gitdata.tar.gz"
  local before; before="$(_lg_snap)"
  if _lg_run all; then echo "a cut archive was accepted" >&2; return 1; fi
  assert_contains "$(cat "$TMP/lg.err")" "NOT changed"
  assert_eq "$(_lg_snap)" "$before"
  assert_eq "$(cat "$VOL/app.ini")" "old-ini"
  assert_eq "$(ls -A "$VOL" | /usr/bin/grep -c 'restore' || true)" "0"
  # the same through the check step alone
  _lg_mkvol; head -c 300000 /dev/urandom > "$SRC/big"; tar -C "$SRC" -czf "$BK/gitdata.tar.gz" .
  size="$(wc -c < "$BK/gitdata.tar.gz" | tr -d ' ')"; head -c $((size / 2)) "$BK/gitdata.tar.gz" > "$TMP/cut.tgz"; mv "$TMP/cut.tgz" "$BK/gitdata.tar.gz"
  if _lg_run stage; then return 1; fi
  assert_eq "$(ls -A "$VOL" | /usr/bin/grep -c 'restore' || true)" "0"
}

test_the_stage_step_alone_changes_nothing_and_the_swap_then_completes_it() {
  _lg_mkvol
  local before; before="$(_lg_snap)"
  _lg_run stage || { cat "$TMP/lg.err" >&2; return 1; }
  assert_eq "$(cat "$VOL/app.ini")" "old-ini"
  [ -d "$VOL/.restore-new" ] || return 1
  _lg_run swap || { cat "$TMP/lg.err" >&2; return 1; }
  assert_eq "$(cat "$VOL/app.ini")" "new-ini"
  assert_eq "$(ls -A "$VOL" | /usr/bin/grep -c 'restore' || true)" "0"
  # a swap with nothing staged fails and changes nothing
  _lg_mkvol; before="$(_lg_snap)"
  if _lg_run swap; then return 1; fi
  assert_eq "$(_lg_snap)" "$before"
}

test_a_leftover_staging_or_holding_folder_is_cleaned_and_never_served() {
  _lg_mkvol
  mkdir -p "$VOL/.restore-new/junk" "$VOL/.restore-old/zz"; echo x > "$VOL/.restore-new/junk/f"; echo y > "$VOL/.restore-old/zz/g"
  _lg_run all || { cat "$TMP/lg.err" >&2; return 1; }
  assert_eq "$(cat "$VOL/app.ini")" "new-ini"
  assert_eq "$(find "$VOL" -name f -o -name g | wc -l | tr -d ' ')" "0"
  assert_eq "$(ls -A "$VOL" | /usr/bin/grep -c 'restore' || true)" "0"
  # leftovers are also cleaned when the new archive then fails: the old contents stay, the leftovers go
  _lg_mkvol; mkdir -p "$VOL/.restore-new/junk"; printf 'not a tar' > "$BK/gitdata.tar.gz"
  if _lg_run all; then return 1; fi
  assert_eq "$(cat "$VOL/app.ini")" "old-ini"
  assert_eq "$(ls -A "$VOL" | /usr/bin/grep -c 'restore' || true)" "0"
}

_space_stubs() { # newest backup = $1 KB, free = $2 KB, git volume = $3 KB (empty = git server off/no volume)
  mkdir -p "$STACK_DIR/backups/20260101-000000"
  du() { printf '%s\t%s\n' "$_SP_KB" "$2"; }
  df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nx 1 1 %s 1%% /\n' "$_SP_FREE"; }
  localgit_volume_kb() { [ -z "$_SP_GIT" ] || echo "$_SP_GIT"; }
  _SP_KB="$1"; _SP_FREE="$2"; _SP_GIT="$3"
}

test_the_backup_space_check_counts_the_git_volume() {
  STACK_DIR="$TMP/stack"
  _space_stubs 10240 30000 ""                      # twice 10 MB = 20 MB fits in 30 MB
  ( _backup_space_check ) 2>/dev/null || { echo "a backup that fits was refused" >&2; return 1; }
  _space_stubs 10240 30000 5120                    # + 5 MB of repositories = 25 MB, fits
  ( _backup_space_check ) 2>/dev/null || { echo "a backup with the git share that fits was refused" >&2; return 1; }
  _space_stubs 10240 30000 20480                   # + 20 MB = 40 MB: only the git volume tips it over
  out="$( (_backup_space_check) 2>&1)" && { echo "should refuse" >&2; return 1; }
  assert_contains "$out" "git server's repositories"
  assert_contains "$out" "not enough free disk space"
  _space_stubs 10240 10000 ""                      # git off: the old message, unchanged
  out="$( (_backup_space_check) 2>&1)" && { echo "should refuse" >&2; return 1; }
  assert_not_contains "$out" "git server"
  assert_contains "$out" "9 MB free, and one needs about 11 MB (twice that is kept free)"
}

test_the_git_volume_alone_is_checked_before_a_first_backup() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR/backups"
  df() { printf 'h\nx 1 1 1000 1%% /\n'; }; localgit_volume_kb() { echo 5000; }
  if ( _backup_space_check ) 2>/dev/null; then echo "a first backup that cannot fit was accepted" >&2; return 1; fi
  localgit_volume_kb() { :; }
  ( _backup_space_check ) 2>/dev/null || return 1   # git off, no backup yet: as before
}

test_the_volume_size_is_read_in_a_read_only_throwaway_container_only_when_the_git_server_is_on() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR"; sed -n '/^  forgejo:/,/^    image:/p' "$T_ROOT/compose.yaml" > "$STACK_DIR/compose.yaml"
  : > "$TMP/dk"
  docker() { echo "$*" >> "$TMP/dk"; case "$1 $2" in "volume inspect") return 0 ;; "run --rm") echo 4096 ;; esac; }
  printf 'LOCALGIT=on\n' > "$ENV_FILE"
  assert_eq "$(localgit_volume_kb)" 4096
  assert_contains "$(cat "$TMP/dk")" ":/v:ro"
  assert_contains "$(cat "$TMP/dk")" "du -sk /v"
  : > "$TMP/dk"; printf 'LOCALGIT=off\n' > "$ENV_FILE"
  assert_eq "$(localgit_volume_kb)" ""
  assert_eq "$(cat "$TMP/dk")" ""
}

test_a_restore_that_stops_after_staging_removes_the_staged_copy_and_one_that_swapped_does_not() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR" "$TMP/bk"; sed -n '/^  forgejo:/,/^    image:/p' "$T_ROOT/compose.yaml" > "$STACK_DIR/compose.yaml"
  printf 'LOCALGIT=on\n' > "$ENV_FILE"
  : > "$TMP/dk"
  # (each case in its own bash, which runs its EXIT trap the way ./stack does when a later restore step dies)
  ( docker() { echo "$*" >> "$TMP/dk"; return 0; }; dc() { :; }
    localgit_stage_restore "$TMP/bk" || exit 3
    exit 1 ) 2>/dev/null || :
  assert_contains "$(cat "$TMP/dk")" "rm -rf /v/.restore-new /v/.restore-old"
  : > "$TMP/dk"
  ( docker() { echo "$*" >> "$TMP/dk"; return 0; }; dc() { :; }
    localgit_stage_restore "$TMP/bk" || exit 3
    localgit_restore_from "$TMP/bk" staged || exit 4
    exit 1 ) 2>/dev/null || :
  assert_not_contains "$(cat "$TMP/dk")" "rm -rf /v/.restore-new /v/.restore-old"
  : > "$TMP/dk"
  ( docker() { echo "$*" >> "$TMP/dk"; case "$1" in run) return 1 ;; esac; return 0; }; dc() { :; }
    localgit_stage_restore "$TMP/bk" && exit 5
    exit 1 ) 2>/dev/null || :
  assert_not_contains "$(cat "$TMP/dk")" "rm -rf /v/.restore-new /v/.restore-old"   # a stage that failed cleaned up itself
}

# --- JON-1145 round 2: a killed swap loses nothing; failing renames; names with spaces; free space; the space check's paths ---

_lg_shim() { # _lg_shim NAME BODY — a command in $TMP/shim ahead of the real one (the script runs with this PATH)
  mkdir -p "$TMP/shim"; printf '#!/bin/sh\n%s\n' "$2" > "$TMP/shim/$1"; chmod +x "$TMP/shim/$1"
}
_lg_run_p() { PATH="$TMP/shim:$PATH" V="$VOL" B="$BK" sh -c "$(_lg_restore_script "$1")" 2> "$TMP/lg.err"; }
_lg_tree() { (cd "$VOL" && find . | sort; find . -type f -exec cat {} + | cksum) | cksum; }

# a volume cut off in phase 1: some old entries aside in .restore-old, the rest still at the top, .restore-new staged
_lg_cut_phase1() {
  _lg_mkvol; mkdir -p "$VOL/.restore-old" "$VOL/.restore-new"
  mv "$VOL/app.ini" "$VOL/.restore-old/"                           # set aside before the kill
  tar -C "$VOL/.restore-new" -xzf "$BK/gitdata.tar.gz"
}
# cut off in phase 2: every old entry aside, the marker written, one new entry moved in, the rest still in .restore-new
_lg_cut_phase2() {
  _lg_mkvol; mkdir -p "$VOL/.restore-old" "$VOL/.restore-new"
  mv "$VOL/git" "$VOL/app.ini" "$VOL/.hidden" "$VOL/.restore-old/"
  tar -C "$VOL/.restore-new" -xzf "$BK/gitdata.tar.gz"
  : > "$VOL/.restore-swapping"; mv "$VOL/.restore-new/app.ini" "$VOL/"
}

test_a_swap_cut_off_in_phase_one_puts_the_old_entries_back_before_anything_is_removed() {
  _lg_cut_phase1
  printf 'not a tar' > "$BK/gitdata.tar.gz"                # a BAD archive now: the old data must come back, not vanish
  if _lg_run stage; then return 1; fi
  assert_eq "$(cat "$VOL/app.ini")" "old-ini"
  assert_eq "$(cat "$VOL/git/repositories/old/HEAD")" "old-head"
  assert_eq "$(cat "$VOL/.hidden")" "hid"
  assert_eq "$(ls -A "$VOL" | /usr/bin/grep -c 'restore' || true)" "0"
  _lg_cut_phase1                                           # and with a GOOD one, the restore then completes
  _lg_run all || { cat "$TMP/lg.err" >&2; return 1; }
  assert_eq "$(cat "$VOL/app.ini")" "new-ini"
  assert_eq "$([ -e "$VOL/.hidden" ] && echo old || echo gone)" "gone"
}

test_a_swap_cut_off_in_phase_two_is_finished_forward_with_a_good_or_a_bad_archive() {
  local k
  for k in good bad; do
    _lg_cut_phase2
    [ "$k" = good ] || printf 'not a tar' > "$BK/gitdata.tar.gz"
    if [ "$k" = bad ]; then _lg_run stage && return 1; fi
    [ "$k" = bad ] || { _lg_run stage || { cat "$TMP/lg.err" >&2; return 1; }; }
    # the interrupted restore's copy is complete, the old data is not served, nothing is left over
    assert_eq "$(cat "$VOL/app.ini")" "new-ini"
    assert_eq "$(cat "$VOL/git/repositories/new/HEAD")" "new-head"
    assert_eq "$(cat "$VOL/.dot")" "newhid"
    assert_eq "$([ -e "$VOL/.hidden" ] || [ -e "$VOL/git/repositories/old" ] && echo old || echo gone)" "gone"
    assert_eq "$(ls -A "$VOL" | /usr/bin/grep -c 'restore' || true)" "$([ "$k" = good ] && echo 1 || echo 0)"   # (a good stage leaves its own new staging folder)
  done
}

test_a_recovery_that_cannot_finish_deletes_nothing() {
  _lg_cut_phase1
  echo file > "$VOL/app.ini.d"; mkdir -p "$VOL/.restore-old/app.ini.d/x"; echo keep > "$VOL/.restore-old/app.ini.d/x/f"   # a name taken at the top: the old one cannot go back
  _lg_run stage && return 1
  assert_contains "$(cat "$TMP/lg.err")" "NOTHING was deleted"
  assert_eq "$(cat "$VOL/.restore-old/app.ini.d/x/f")" "keep"
  [ -d "$VOL/.restore-new" ] || return 1
}

test_a_failing_rename_in_either_phase_leaves_the_volume_exactly_as_it_was() {
  local n before
  for n in 1 2 3 4 5 6; do   # the Nth mv fails: phase 1 for the early ones, phase 2 for the later ones
    _lg_mkvol; _lg_run stage || return 1; rm -f "$TMP/mvcount"
    _lg_shim mv "c=\$(cat '$TMP/mvcount' 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > '$TMP/mvcount'; [ \$c -eq $n ] && exit 1; exec /bin/mv \"\$@\""
    # (staged already: the volume to compare is old contents + the staged folder)
    before="$(_lg_tree)"
    if _lg_run_p swap; then echo "mv $n did not fail the swap" >&2; return 1; fi
    rm -f "$TMP/shim/mv"
    assert_contains "$(cat "$TMP/lg.err")" "NOT changed"
    assert_eq "$(cat "$VOL/app.ini")" "old-ini"
    assert_eq "$(cat "$VOL/.hidden")" "hid"
    assert_eq "$(cat "$VOL/git/repositories/old/HEAD")" "old-head"
    assert_eq "$([ -e "$VOL/.restore-old" ] || [ -e "$VOL/.restore-swapping" ] || [ -e "$VOL/.dot" ] && echo mess || echo clean)" "clean"
    : "$before"
  done
}

test_names_with_spaces_and_a_star_survive_the_swap_and_a_failed_one() {
  _lg_mkvol; echo a > "$VOL/old name"; echo b > "$VOL/*"; echo c > "$VOL/-dash"
  echo n > "$SRC/new name"; echo m > "$SRC/*"; tar -C "$SRC" -czf "$BK/gitdata.tar.gz" .
  _lg_run stage || { cat "$TMP/lg.err" >&2; return 1; }
  _lg_shim mv 'c=$(cat '"$TMP/mvcount"' 2>/dev/null || echo 0); c=$((c+1)); echo $c > '"$TMP/mvcount"'; [ $c -eq 8 ] && exit 1; exec /bin/mv "$@"'
  rm -f "$TMP/mvcount"; _lg_run_p swap && return 1
  rm -f "$TMP/shim/mv"
  assert_eq "$(cat "$VOL/old name")" a; assert_eq "$(cat "$VOL/*")" b; assert_eq "$(cat "$VOL/-dash")" c
  assert_eq "$([ -e "$VOL/new name" ] && echo leaked || echo clean)" clean
  _lg_run all || { cat "$TMP/lg.err" >&2; return 1; }   # (a failed swap removes its staged copy: stage again)
  assert_eq "$(cat "$VOL/new name")" n; assert_eq "$(cat "$VOL/*")" m
  assert_eq "$([ -e "$VOL/old name" ] || [ -e "$VOL/-dash" ] && echo old || echo gone)" gone
}

test_the_restore_refuses_when_the_unpacked_archive_would_not_fit_the_free_space() {
  _lg_mkvol; head -c 2000000 /dev/zero > "$SRC/big"; tar -C "$SRC" -czf "$BK/gitdata.tar.gz" .   # ~2 MB unpacked
  _lg_shim df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\nx 1 1 %s 1%% /\n" 262500'   # 256.4 MB free: the margin leaves ~0
  local before; before="$(_lg_tree)"
  if _lg_run_p stage; then echo "accepted with no room" >&2; return 1; fi
  assert_contains "$(cat "$TMP/lg.err")" "not enough free space to unpack the git server's archive"
  assert_contains "$(cat "$TMP/lg.err")" "nothing was changed"
  assert_eq "$(_lg_tree)" "$before"
  _lg_shim df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\nx 1 1 %s 1%% /\n" 900000'
  _lg_run_p stage || { cat "$TMP/lg.err" >&2; return 1; }
  rm -f "$TMP/shim/df"
}

test_the_unpacked_size_is_read_from_the_listing_with_spaces_in_names() {
  _lg_mkvol; head -c 3000000 /dev/zero > "$SRC/a name with  spaces"; tar -C "$SRC" -czf "$BK/gitdata.tar.gz" .
  local kb; kb="$(V="$VOL" B="$BK" sh -c "$(_lg_restore_script stage | sed '$d')
unpacked_kb")"
  [ "${kb:-0}" -ge 2900 ] && [ "${kb:-0}" -le 3100 ] || { echo "size read as [$kb]" >&2; return 1; }
}

test_the_space_check_skips_the_volume_job_when_there_is_plenty_of_room() {
  STACK_DIR="$TMP/stack"; _space_stubs 10240 9000000 5120; printf 'LOCALGIT=on\n' > "$ENV_FILE"
  : > "$STACK_DIR/backups/20260101-000000/gitdata.tar.gz"   # the newest backup holds the repositories: its size covers them
  : > "$TMP/jobs"; localgit_volume_kb() { echo job >> "$TMP/jobs"; echo 5120; }
  ( _backup_space_check ) 2>/dev/null || return 1
  assert_eq "$(wc -l < "$TMP/jobs" | tr -d ' ')" 0
  rm -f "$STACK_DIR/backups/20260101-000000/gitdata.tar.gz"   # no copy of them in it (the git server was off then): measure
  ( _backup_space_check ) 2>/dev/null || return 1
  assert_eq "$(wc -l < "$TMP/jobs" | tr -d ' ')" 1
  : > "$TMP/jobs"; printf 'LOCALGIT=off\n' > "$ENV_FILE"   # git server off now: nothing to measure
  ( _backup_space_check ) 2>/dev/null || return 1
  assert_eq "$(wc -l < "$TMP/jobs" | tr -d ' ')" 0
  printf 'LOCALGIT=on\n' > "$ENV_FILE"; : > "$STACK_DIR/backups/20260101-000000/gitdata.tar.gz"; : > "$TMP/jobs"
  _space_stubs 10240 1050000 5120                  # under 4x + 1 GiB: the job runs
  localgit_volume_kb() { echo job >> "$TMP/jobs"; echo 5120; }
  ( _backup_space_check ) 2>/dev/null || return 1
  assert_eq "$(wc -l < "$TMP/jobs" | tr -d ' ')" 1
}

test_the_git_volume_counts_once_not_twice_with_the_newest_backups_own_archive_left_out() {
  STACK_DIR="$TMP/stack"; _space_stubs 30000 100000 20000   # backup 30 MB, of which the git archive 20 MB (du stub: same for any path)
  printf x > "$STACK_DIR/backups/20260101-000000/gitdata.tar.gz"
  du() { case "$2" in *gitdata.tar.gz) echo 20000 ;; *) echo 30000 ;; esac; }
  # twice (30000-20000) + 20000 = 40000 KB fits in 100000; counted naively it would be 2*30000+20000 = 80000, also fits: tighten
  df() { printf 'h\nx 1 1 45000 1%% /\n'; }
  ( _backup_space_check ) 2>/dev/null || { echo "git counted more than once" >&2; return 1; }
  df() { printf 'h\nx 1 1 39000 1%% /\n'; }
  ( _backup_space_check ) 2>/dev/null && { echo "should refuse" >&2; return 1; }
  return 0
}

test_the_first_backup_message_does_not_speak_of_a_newest_backup() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR/backups"
  df() { printf 'h\nx 1 1 1000 1%% /\n'; }; localgit_volume_kb() { echo 5000; }
  out="$( (_backup_space_check) 2>&1)" && return 1
  assert_contains "$out" "git server's repositories alone take about"
  assert_not_contains "$out" "newest backup"
  assert_not_contains "$out" "(0 MB"
}

test_the_volume_size_job_mounts_an_empty_folder_of_its_own_not_the_backups() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR/backups/b1"; sed -n '/^  forgejo:/,/^    image:/p' "$T_ROOT/compose.yaml" > "$STACK_DIR/compose.yaml"
  : > "$TMP/dk"; docker() { echo "$*" >> "$TMP/dk"; case "$1 $2" in "volume inspect") return 0 ;; "run --rm") echo 4096 ;; esac; }
  printf 'LOCALGIT=on\n' > "$ENV_FILE"
  assert_eq "$(localgit_volume_kb)" 4096
  assert_not_contains "$(cat "$TMP/dk")" "$STACK_DIR/backups"
  assert_contains "$(cat "$TMP/dk")" "$STACK_DIR/.state/lg-size:/backup"
  assert_eq "$(ls -A "$STACK_DIR/.state/lg-size" | wc -l | tr -d ' ')" 0
}

# the swap's end: every new entry in place, the old copy being removed (the longest step), then the staged folder, the marker
_lg_cut_end() {  # _lg_cut_end with-new|without-new — killed while .restore-old was being removed
  _lg_mkvol; mkdir -p "$VOL/.restore-old" "$VOL/.restore-new"
  mv "$VOL/git" "$VOL/app.ini" "$VOL/.hidden" "$VOL/.restore-old/"
  tar -C "$VOL/.restore-new" -xzf "$BK/gitdata.tar.gz"
  : > "$VOL/.restore-swapping"
  for e in "$VOL/.restore-new"/* "$VOL/.restore-new"/.dot; do mv "$e" "$VOL/"; done
  rm -rf "$VOL/.restore-old/git"                                # part of the old copy already gone
  [ "$1" = with-new ] || rm -rf "$VOL/.restore-new"
}

test_a_swap_killed_while_removing_the_old_copy_is_finished_not_undone() {
  local k
  for k in with-new without-new; do
    _lg_cut_end "$k"
    printf 'not a tar' > "$BK/gitdata.tar.gz"                   # a bad archive next: the finished copy must stay, nothing stuck
    _lg_run stage && return 1
    assert_not_contains "$(cat "$TMP/lg.err")" "NOTHING was deleted"
    assert_eq "$(cat "$VOL/app.ini")" "new-ini"
    assert_eq "$(cat "$VOL/git/repositories/new/HEAD")" "new-head"
    assert_eq "$([ -e "$VOL/.hidden" ] && echo old || echo gone)" "gone"
    assert_eq "$(ls -A "$VOL" | /usr/bin/grep -c 'restore' || true)" "0"
  done
}

test_the_swap_removes_its_marker_only_after_the_old_copy() {
  _lg_mkvol
  _lg_shim rm 'case "$*" in *.restore-old*) exit 1 ;; esac; exec /bin/rm "$@"'   # the old copy cannot be removed
  _lg_run_p all || { cat "$TMP/lg.err" >&2; return 1; }
  assert_eq "$(cat "$VOL/app.ini")" "new-ini"
  [ -e "$VOL/.restore-swapping" ] || { echo "the marker went before the old copy" >&2; return 1; }
  /bin/rm -f "$TMP/shim/rm"
  _lg_run stage || { cat "$TMP/lg.err" >&2; return 1; }        # the next restore finishes it forward
  assert_eq "$(cat "$VOL/app.ini")" "new-ini"
  assert_eq "$([ -e "$VOL/.restore-old" ] || [ -e "$VOL/.restore-swapping" ] && echo left || echo none)" "none"
}

test_the_unpacked_size_counts_whole_blocks_for_many_small_files() {
  _lg_mkvol; mkdir -p "$SRC/objects"; local i=0
  while [ $i -lt 200 ]; do printf 'x%s' "$i" > "$SRC/objects/o$i"; i=$((i + 1)); done   # 200 tiny loose objects
  tar -C "$SRC" -czf "$BK/gitdata.tar.gz" .
  local kb; kb="$(V="$VOL" B="$BK" sh -c "$(_lg_restore_script stage | sed '$d')
unpacked_kb")"
  [ "${kb:-0}" -ge 800 ] || { echo "200 small files read as [$kb] KB, not at least 200 blocks of 4 KB" >&2; return 1; }
}

test_only_one_restore_job_runs_on_the_volume_at_a_time() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR" "$TMP/bk"; sed -n '/^  forgejo:/,/^    image:/p' "$T_ROOT/compose.yaml" > "$STACK_DIR/compose.yaml"
  printf 'LOCALGIT=on\n' > "$ENV_FILE"; : > "$TMP/dk"
  ( docker() { echo "$*" >> "$TMP/dk"; return 0; }; dc() { :; }
    localgit_stage_restore "$TMP/bk" && localgit_restore_from "$TMP/bk" staged ) 2>/dev/null || return 1
  assert_eq "$(/usr/bin/grep -c -- "run --rm --name $(project_name)-git-restore " "$TMP/dk")" 2   # stage and swap, both named
  : > "$TMP/dk"                                              # an earlier restore's container still there: refused, nothing run
  ( docker() { echo "$*" >> "$TMP/dk"; case "$1" in ps) echo 0123abcd ;; esac; return 0; }; dc() { :; }
    localgit_stage_restore "$TMP/bk" && exit 5; localgit_restore_from "$TMP/bk" staged && exit 6; exit 0 ) 2> "$TMP/err" || return 1
  assert_not_contains "$(cat "$TMP/dk")" "run --rm"
  assert_contains "$(cat "$TMP/err")" "an earlier restore's job"
}

test_a_backup_that_cannot_fit_even_without_the_repositories_is_refused_without_the_volume_job() {
  STACK_DIR="$TMP/stack"; _space_stubs 10240 5000 5120; printf 'LOCALGIT=on\n' > "$ENV_FILE"
  : > "$TMP/jobs"; localgit_volume_kb() { echo job >> "$TMP/jobs"; echo 5120; }
  local out; if out="$( (_backup_space_check) 2>&1)"; then echo "accepted with 5 MB free" >&2; return 1; fi
  assert_contains "$out" "not enough free disk space for a backup"
  assert_eq "$(wc -l < "$TMP/jobs" | tr -d ' ')" 0
}
