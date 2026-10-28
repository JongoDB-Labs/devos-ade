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

test_the_web_site_signs_the_owner_in_only_after_the_portal_and_the_sandboxs_paths_remove_the_header() {
  s="$(cat "$T_ROOT/caddy/localgit-on.caddy")"
  # the header is set in the proxy block of the site that imports portal_auth, after it (route order), and nowhere else
  assert_eq "$(printf '%s\n' "$s" | grep -c 'header_up {$LOCALGIT_SSO_HEADER} devos')" 1
  site="$(printf '%s\n' "$s" | sed -n '/^http:\/\/{\$GIT_HOST} {/,/^}/p')"
  assert_contains "$site" 'header_up {$LOCALGIT_SSO_HEADER} devos'
  [ "$(printf '%s\n' "$site" | grep -n 'import portal_auth' | cut -d: -f1)" -lt "$(printf '%s\n' "$site" | grep -n 'header_up {$LOCALGIT_SSO_HEADER}' | cut -d: -f1)" ] || { echo "the header is set before the portal's check" >&2; return 1; }
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
  assert_eq "$(printf '%s\n' "$mirrors" | grep -c 'reverse_proxy')" 3
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
  assert_contains "$y" 'FORGEJO__security__REVERSE_PROXY_TRUSTED_PROXIES: 10.255.255.238/32'
  assert_contains "$y" 'FORGEJO__security__REVERSE_PROXY_LIMIT: "1"'
  assert_not_contains "$y" 'TRUSTED_PROXIES: "*"'
  assert_contains "$(cat "$T_ROOT/compose.yaml")" 'ipv4_address: 10.255.255.238'
  assert_contains "$(cat "$T_ROOT/compose.yaml")" 'subnet: 10.255.255.224/28'
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
