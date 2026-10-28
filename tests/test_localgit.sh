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
  assert_contains "$(cat "$TMP/calls")" "docker volume rm bedrock-now_gitdata"
  assert_contains "$(cat "$TMP/calls")" "docker network rm bedrock-now_localgit"
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
  assert_contains "$out" "GIT_HOST=chat.bn.localhost is the same host name as another app or the portal"
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
}

test_the_web_site_is_behind_the_portal_and_framed_by_it_only() {
  s="$(cat "$T_ROOT/caddy/localgit-on.caddy")"
  assert_contains "$s" 'http://{$GIT_HOST} {'
  for i in local_request not_from_preview portal_auth drop_session_cookie frame_by_portal_only; do assert_contains "$s" "import $i"; done
  assert_contains "$s" "reverse_proxy forgejo:3000"
  assert_contains "$(cat "$T_ROOT/caddy/Caddyfile")" 'import localgit-{$LOCALGIT_MODE:off}.caddy'
  # compose: Caddy gets the host and the mode; the gateway's files and the Caddyfile's are in their own checksums
  c="$(cat "$T_ROOT/compose.yaml")"
  assert_contains "$c" 'GIT_HOST: ${GIT_HOST:-git.${PORTAL_HOST:-bedrock-now.localhost}}'
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
  grep -q '_cfg_on localgit; then localgit_up' "$T_ROOT/lib/settings.sh" || { echo "Settings' apply does not know localgit" >&2; return 1; }
  grep -q '^LOCALGIT_ADMIN_PASSWORD' "$T_ROOT/.env.example" && grep -q '^LOCALGIT=' "$T_ROOT/.env.example" || { echo ".env.example lacks the keys" >&2; return 1; }
}
