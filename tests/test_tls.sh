# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2329  # literal ${...} in Caddy patterns; stubs read by the libs
# The portal over HTTPS (JON-976; lib/tls.sh, caddy/tls-*.caddy, compose.https.yaml): the install's CA and site certificate
# (the constraints, the names, the modes), what the CA refuses, renewal, trust and its removal with security / certutil /
# sudo stubbed on PATH (the real ones never run: tests/shims logs a call that gets through to them and fails the suite),
# the failed check that turns HTTPS back off, ./stack https off, the Caddy snippets and that setup asks only at a terminal.
. "$STACK_DIR/lib/commands.sh"

# _tls_env — an install at devos-ade.localhost:8800 in $ENV_FILE, a scratch HOME, and the stubs on PATH: each records its
# arguments in $TMP/calls (security, certutil, sudo, update-ca-*); no docker, no stack running
_tls_env() {
  export ASSUME_YES=1 HOME="$TMP/home"
  mkdir -p "$HOME" "$TMP/bin" "$TMP/deb"
  printf 'PORTAL_SECRET=%s\nPORTAL_HOST=devos-ade.localhost\nPORTAL_PORT=8800\n' "$(printf 's%.0s' $(seq 1 40))" > "$ENV_FILE"
  : > "$TMP/calls"
  local n
  for n in security update-ca-certificates update-ca-trust; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n[ -n "${STUB_%s_RC:-}" ] && exit "$STUB_%s_RC"\nexit 0\n' "$n" "$TMP" "$(echo "$n" | tr 'a-z-' 'A-Z_')" "$(echo "$n" | tr 'a-z-' 'A-Z_')" > "$TMP/bin/$n"
  done
  # security verify-cert answers STUB_VERIFY_RC (default 0)
  printf '#!/bin/sh\necho "security $*" >> "%s/calls"\ncase "$1" in verify-cert) exit "${STUB_VERIFY_RC:-0}" ;; esac\nexit 0\n' "$TMP" > "$TMP/bin/security"
  printf '#!/bin/sh\necho "sudo $*" >> "%s/calls"\nexit 0\n' "$TMP" > "$TMP/bin/sudo"
  # certutil keeps a database marker: -N makes cert9.db, -A records the nickname, -L -n finds it, -D forgets it
  cat > "$TMP/bin/certutil" <<EOF
#!/bin/sh
echo "certutil \$*" >> "$TMP/calls"
db=\${2#sql:}
case " \$* " in
  *" -N "*) mkdir -p "\$db"; : > "\$db/cert9.db" ;;
  *" -A "*) shift; while [ \$# -gt 0 ]; do [ "\$1" = -n ] && { printf '%s\n' "\$2" > "\$db/nick"; break; }; shift; done ;;
  *" -L "*) [ -f "\$db/nick" ] || exit 255 ;;
  *" -D "*) rm -f "\$db/nick" ;;
esac
exit 0
EOF
  chmod +x "$TMP"/bin/*
  PATH="$TMP/bin:$PATH"
  check_prereqs() { :; }
  stack_lock() { :; }
  run_phase() { shift 2; "$@"; }
  dc() { echo "dc $*" >> "$TMP/dc"; return 0; }
  _cfg_stack_running() { return 1; }
}
_darwin() { uname() { echo Darwin; }; }
_linux() { uname() { echo Linux; }; }

_tls_text() { openssl x509 -in "$1" -noout -text; }
_tls_fp() { openssl x509 -in "$1" -noout -fingerprint -sha1 | sed 's/^.*=//; s/://g'; }

# _tls_sign NAME — a certificate for NAME signed by the install's CA (what a thief of the key, or a bug, would make)
_tls_sign() {
  local d="$STATE_DIR/tls" n="$1"
  openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/$n.key" 2>/dev/null
  openssl req -new -key "$TMP/$n.key" -subj "/CN=$n" -out "$TMP/$n.csr" 2>/dev/null
  printf '[v3]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$n" > "$TMP/$n.ext"
  openssl x509 -req -sha256 -days 30 -in "$TMP/$n.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAserial "$d/ca.srl" -CAcreateserial \
    -extfile "$TMP/$n.ext" -extensions v3 -out "$TMP/$n.pem" >/dev/null 2>&1
}

test_ca_is_name_constrained_and_critical() {
  _tls_env
  set_env CHAT_HOST chat.elsewhere.example
  tls_ensure || return 1
  t="$(_tls_text "$STATE_DIR/tls/ca.pem")"
  assert_contains "$t" "CA:TRUE, pathlen:0"
  assert_contains "$t" "prime256v1"
  # (critical, in both openssl's wording)
  printf '%s\n' "$t" | grep -qE "X509v3 Name Constraints: critical" || { echo "name constraints not critical" >&2; return 1; }
  printf '%s\n' "$t" | grep -qE "X509v3 Basic Constraints: critical" || { echo "basic constraints not critical" >&2; return 1; }
  printf '%s\n' "$t" | grep -qE "X509v3 Key Usage: critical" || { echo "key usage not critical" >&2; return 1; }
  assert_contains "$t" "Certificate Sign, CRL Sign"
  assert_contains "$t" "DNS:devos-ade.localhost"
  assert_contains "$t" "DNS:.devos-ade.localhost"
  assert_contains "$t" "DNS:.devos-ade-preview.localhost"
  assert_contains "$t" "DNS:chat.elsewhere.example"   # a configured host outside those
  assert_contains "$t" "CN=DevOS ADE local CA for devos-ade.localhost $(date +%Y-%m-%d)"
  # ten years
  openssl x509 -in "$STATE_DIR/tls/ca.pem" -noout -checkend $((3649 * 86400)) >/dev/null || { echo "CA lives under ten years" >&2; return 1; }
  if openssl x509 -in "$STATE_DIR/tls/ca.pem" -noout -checkend $((3660 * 86400)) >/dev/null; then echo "CA lives over ten years" >&2; return 1; fi
}

test_site_certificate_names_and_lifetime() {
  _tls_env
  set_env FILES_HOST files.elsewhere.example
  tls_ensure || return 1
  t="$(_tls_text "$STATE_DIR/tls/site.pem")"
  assert_contains "$t" "CA:FALSE"
  assert_contains "$t" "TLS Web Server Authentication"
  assert_contains "$t" "prime256v1"
  for n in devos-ade.localhost '*.devos-ade.localhost' '*.devos-ade-preview.localhost' '*.artifact.devos-ade-preview.localhost' files.elsewhere.example; do
    assert_contains "$t" "DNS:$n"
  done
  # 397 days
  openssl x509 -in "$STATE_DIR/tls/site.pem" -noout -checkend $((396 * 86400)) >/dev/null || { echo "site lives under 397 days" >&2; return 1; }
  if openssl x509 -in "$STATE_DIR/tls/site.pem" -noout -checkend $((398 * 86400)) >/dev/null; then echo "site lives over 397 days" >&2; return 1; fi
}

test_keys_are_mode_600_and_the_ca_key_is_not_served() {
  _tls_env
  tls_ensure || return 1
  assert_eq "$(perm_of "$STATE_DIR/tls/ca.key")" 600
  assert_eq "$(perm_of "$STATE_DIR/tls/site.key")" 600
  # Caddy's folder holds the site pair alone (644 in a folder under .state, which is 700: Caddy's user is not yours)
  assert_eq "$(ls "$STATE_DIR/tls/serve" | tr '\n' ' ')" "site.key site.pem "
  assert_eq "$(perm_of "$STATE_DIR")" 700
}

test_the_ca_key_is_in_no_compose_volume() {
  # no compose file names it, and the one overlay that mounts anything of tls mounts the serve folder, read-only
  if grep -h "ca\.key" "$STACK_DIR"/compose*.yaml | grep -v '^[[:space:]]*#' | grep . >/dev/null; then echo "a compose file names ca.key" >&2; return 1; fi
  f="$(cat "$STACK_DIR/compose.https.yaml")"
  assert_contains "$f" 'source: ${BN_TLS_SERVE:?run ./stack up}'
  assert_contains "$f" "target: /etc/bn-tls"
  assert_contains "$f" "read_only: true"
  case "$(grep -c 'source:' "$STACK_DIR/compose.https.yaml")" in 1) ;; *) echo "more than one mount" >&2; return 1 ;; esac
  _tls_env
  tls_ensure || return 1
  # dc's BN_TLS_SERVE is the serve folder, which does not hold the CA key
  [ ! -e "$STATE_DIR/tls/serve/ca.key" ] || return 1
  if grep -q "ca.key" <<<"$(dc_env_probe 2>/dev/null)"; then return 1; fi
}
dc_env_probe() { grep -o 'BN_TLS_SERVE="[^"]*"' "$STACK_DIR/lib/common.sh"; }

test_the_ca_vouches_for_this_install_and_refuses_other_names() {
  _tls_env
  tls_ensure || return 1
  d="$STATE_DIR/tls"
  openssl verify -CAfile "$d/ca.pem" -purpose sslserver "$d/site.pem" >/dev/null 2>&1 || { echo "the site certificate does not verify" >&2; return 1; }
  # names inside the constraints are fine ...
  _tls_sign p5173-abc.devos-ade-preview.localhost
  openssl verify -CAfile "$d/ca.pem" -purpose sslserver "$TMP/p5173-abc.devos-ade-preview.localhost.pem" >/dev/null 2>&1 || { echo "a preview does not verify" >&2; return 1; }
  # ... a name outside them is refused although the same CA signed it
  for n in evil.example other.localhost devos-ade-preview.localhost.evil.example; do
    _tls_sign "$n"
    if openssl verify -CAfile "$d/ca.pem" -purpose sslserver "$TMP/$n.pem" >/dev/null 2>&1; then echo "$n was accepted" >&2; return 1; fi
  done
}

test_site_certificate_is_made_again_under_30_days() {
  _tls_env
  tls_ensure || return 1
  d="$STATE_DIR/tls"; ca1="$(_tls_fp "$d/ca.pem")"; site1="$(_tls_fp "$d/site.pem")"
  tls_ensure || return 1
  assert_eq "$TLS_SITE_NEW" 0; assert_eq "$(_tls_fp "$d/site.pem")" "$site1"
  # a site certificate with 20 days left (signed by the CA, in place of the real one)
  openssl x509 -req -sha256 -days 20 -in <(openssl req -new -key "$d/site.key" -subj "/CN=devos-ade.localhost") -CA "$d/ca.pem" -CAkey "$d/ca.key" \
    -CAserial "$d/ca.srl" -extfile <(printf 'subjectAltName=DNS:devos-ade.localhost\n') -out "$d/site.pem" >/dev/null 2>&1
  tls_ensure || return 1
  assert_eq "$TLS_SITE_NEW" 1; assert_eq "$TLS_CA_NEW" 0
  assert_eq "$(_tls_fp "$d/ca.pem")" "$ca1"   # (the CA stays: nothing to trust again)
  openssl x509 -in "$d/site.pem" -noout -checkend $((30 * 86400)) >/dev/null || return 1
  assert_eq "$(cmp -s "$d/site.pem" "$d/serve/site.pem" && echo same)" same   # (and Caddy's copy follows)
}

test_a_changed_host_renews_and_a_host_outside_the_constraints_needs_a_new_ca() {
  _tls_env
  tls_ensure || return 1
  d="$STATE_DIR/tls"; ca1="$(_tls_fp "$d/ca.pem")"
  # a host the CA already vouches for (under PORTAL_HOST): nothing changes
  set_env CODE_HOST code.devos-ade.localhost
  tls_ensure || return 1
  assert_eq "$TLS_SITE_NEW" 0
  # one outside it: setup and update (--no-new-ca) change nothing and say so ...
  set_env FILES_HOST files.elsewhere.example
  site1="$(_tls_fp "$d/site.pem")"
  rc=0; tls_ensure --no-new-ca || rc=$?
  assert_eq "$rc" 2; assert_eq "$(_tls_fp "$d/site.pem")" "$site1"; assert_eq "$(_tls_fp "$d/ca.pem")" "$ca1"
  # ... ./stack https on makes a new CA (and so asks for the trust again) and a site certificate with the name
  tls_ensure || return 1
  assert_eq "$TLS_CA_NEW" 1
  [ "$(_tls_fp "$d/ca.pem")" != "$ca1" ] || return 1
  assert_contains "$(_tls_text "$d/site.pem")" "DNS:files.elsewhere.example"
  openssl verify -CAfile "$d/ca.pem" -purpose sslserver "$d/site.pem" >/dev/null 2>&1 || return 1
  # the host leaving again: the site certificate follows, the CA stays
  ca2="$(_tls_fp "$d/ca.pem")"; set_env FILES_HOST ''
  tls_ensure --no-new-ca || return 1
  assert_eq "$TLS_SITE_NEW" 1; assert_eq "$(_tls_fp "$d/ca.pem")" "$ca2"
  if _tls_text "$d/site.pem" | grep -q "files.elsewhere.example"; then return 1; fi
}

test_macos_trust_and_removal_run_security_with_these_arguments() {
  _tls_env; _darwin
  tls_ensure || return 1
  d="$STATE_DIR/tls"; kc="$HOME/Library/Keychains/login.keychain-db"
  tls_trust_add 2>/dev/null || return 1
  tls_trust_check || return 1
  tls_trust_remove
  assert_eq "$(cat "$TMP/calls")" "security add-trusted-cert -r trustRoot -p ssl -k $kc $d/ca.pem
security verify-cert -c $d/site.pem -p ssl -s devos-ade.localhost
security delete-certificate -Z $(_tls_fp "$d/ca.pem" | tr 'a-f' 'A-F') -t $kc"
}

test_linux_trust_uses_the_nss_database_and_the_system_store_only_after_a_yes() {
  _tls_env; _linux
  export TLS_DEB_DIR="$TMP/deb"
  tls_ensure || return 1
  d="$STATE_DIR/tls"; db="$HOME/.pki/nssdb"
  # no answer (--yes, no terminal): NSS only, the system command printed
  out="$(tls_trust_add 2>&1)" || return 1
  assert_contains "$out" "sudo cp '$d/ca.pem' '$TMP/deb/devos-ade-devos-ade.localhost.crt' && sudo update-ca-certificates"
  assert_contains "$(cat "$TMP/calls")" "certutil -d sql:$db -N --empty-password"
  assert_contains "$(cat "$TMP/calls")" "certutil -d sql:$db -A -t C,, -n DevOS ADE local CA (devos-ade.localhost) -i $d/ca.pem"
  if grep -q "^sudo\|update-ca" "$TMP/calls"; then echo "the system store was touched without a yes" >&2; return 1; fi
  tls_trust_check || return 1
  # an explicit yes: sudo
  : > "$TMP/calls"; ask() { echo y; }
  tls_trust_add >/dev/null 2>&1 || return 1
  assert_contains "$(cat "$TMP/calls")" "sudo cp $d/ca.pem $TMP/deb/devos-ade-devos-ade.localhost.crt"
  assert_contains "$(cat "$TMP/calls")" "sudo update-ca-certificates"
  # removal: NSS, then the system store after a yes
  : > "$TMP/calls"; : > "$TMP/deb/devos-ade-devos-ade.localhost.crt"
  tls_trust_remove >/dev/null 2>&1
  assert_contains "$(cat "$TMP/calls")" "certutil -d sql:$db -D -n DevOS ADE local CA (devos-ade.localhost)"
  assert_contains "$(cat "$TMP/calls")" "sudo rm -f $TMP/deb/devos-ade-devos-ade.localhost.crt"
  if tls_trust_check; then echo "still trusted after removal" >&2; return 1; fi
}

test_linux_without_certutil_prints_how_and_is_not_trusted() {
  _tls_env; _linux
  rm -f "$TMP/bin/certutil"
  # (the real certutil of this computer, if any, is not the test's: PATH is the stubs and the system's tools alone)
  command -v certutil >/dev/null 2>&1 && { echo "skipped: this computer has a certutil" >&2; return 77; }
  tls_ensure || return 1
  out="$(tls_trust_add 2>&1)" || return 1
  assert_contains "$out" "certutil (libnss3-tools / nss-tools) was not found"
  if tls_trust_check; then echo "trusted without any route" >&2; return 1; fi
}

test_enable_turns_it_on_and_off_again() {
  _tls_env; _darwin
  https_enable 2>/dev/null || return 1
  assert_eq "$(get_env PORTAL_HTTPS)" true
  assert_eq "$(get_env PORTAL_ORIGIN)" "https://devos-ade.localhost:8800"
  assert_eq "$(get_env CHAT_ORIGIN)" "https://chat.devos-ade.localhost:8800"
  assert_eq "$(get_env GIT_ORIGIN)" "https://git.devos-ade.localhost:8800"
  assert_contains "$(compose_overlays)" "compose.https.yaml"
  assert_contains "$(cat "$STATE_DIR/status/https-switched.json")" '"https": true'
  assert_contains "$(https_status)" "HTTPS: on — https://devos-ade.localhost:8800"
  # ./stack https off: plain HTTP again, the files gone, the CA out of the keychain
  fp="$(_tls_fp "$STATE_DIR/tls/ca.pem" | tr 'a-f' 'A-F')"
  https_disable 2>/dev/null || return 1
  assert_eq "$(get_env PORTAL_HTTPS)" false
  assert_eq "$(get_env PORTAL_ORIGIN)" "http://devos-ade.localhost:8800"
  [ ! -e "$STATE_DIR/tls" ] || { echo ".state/tls is still there" >&2; return 1; }
  if compose_overlays | grep -q https; then echo "overlay still on" >&2; return 1; fi
  assert_contains "$(cat "$TMP/calls")" "security delete-certificate -Z $fp -t $HOME/Library/Keychains/login.keychain-db"
  assert_contains "$(cat "$STATE_DIR/status/https-switched.json")" '"https": false'
  assert_contains "$(https_status)" "HTTPS: off — http://devos-ade.localhost:8800"
}

test_a_failed_trust_check_turns_https_back_off() {
  _tls_env; _darwin
  export STUB_VERIFY_RC=1
  out="$(https_enable 2>&1)" && { echo "enable succeeded" >&2; return 1; }
  assert_contains "$out" "HTTPS is off again: this computer does not trust the certificate"
  assert_eq "$(get_env PORTAL_HTTPS)" false
  assert_eq "$(get_env PORTAL_ORIGIN)" "http://devos-ade.localhost:8800"
  if compose_overlays | grep -q https; then return 1; fi
  # the keychain refused (the password prompt cancelled): the same
  security() { echo "security $*" >> "$TMP/calls"; case "$1" in add-trusted-cert | verify-cert) return 1 ;; esac; }
  out="$(https_enable 2>&1)" && return 1
  assert_contains "$out" "HTTPS is off again: the certificate authority was not added"
  assert_eq "$(get_env PORTAL_HTTPS)" false
}

test_a_guard_at_up_turns_off_a_portal_the_computer_stopped_trusting() {
  _tls_env; _darwin
  https_enable 2>/dev/null || return 1
  export STUB_VERIFY_RC=1
  out="$(https_guard 2>&1)"
  assert_contains "$out" "HTTPS is off again: this computer no longer trusts the certificate"
  assert_eq "$(get_env PORTAL_HTTPS)" false
}

test_the_guard_renews_without_a_question() {
  _tls_env; _darwin
  https_enable 2>/dev/null || return 1
  d="$STATE_DIR/tls"; site1="$(_tls_fp "$d/site.pem")"
  openssl x509 -req -sha256 -days 5 -in <(openssl req -new -key "$d/site.key" -subj "/CN=devos-ade.localhost") -CA "$d/ca.pem" -CAkey "$d/ca.key" \
    -CAserial "$d/ca.srl" -extfile <(printf 'subjectAltName=DNS:devos-ade.localhost\n') -out "$d/site.pem" >/dev/null 2>&1
  : > "$TMP/calls"
  ask() { echo "asked" >> "$TMP/calls"; echo n; }
  https_guard 2>/dev/null
  [ "$(_tls_fp "$d/site.pem")" != "$site1" ] || { echo "not renewed" >&2; return 1; }
  if grep -q "add-trusted-cert\|asked" "$TMP/calls"; then echo "renewal asked or trusted again" >&2; return 1; fi
  assert_eq "$(get_env PORTAL_HTTPS)" true
}

test_setup_asks_only_at_a_terminal_and_only_once() {
  _tls_env; _darwin
  https_enable() { echo enable >> "$TMP/calls"; set_env PORTAL_HTTPS true; }
  # --yes, or no terminal: left as it is (empty)
  ASSUME_YES=1; _have_tty() { return 0; }
  https_setup_question; assert_eq "$(get_env PORTAL_HTTPS)" ""
  ASSUME_YES=0; _have_tty() { return 1; }
  https_setup_question; assert_eq "$(get_env PORTAL_HTTPS)" ""
  # an update (--update-mode) never asks
  _have_tty() { return 0; }; UPD_MODE=1
  https_setup_question; assert_eq "$(get_env PORTAL_HTTPS)" ""
  # a terminal in an interactive setup: the question names the keychain; no turns it off for good, yes turns it on
  UPD_MODE=0; q="$TMP/q"
  confirm() { printf '%s\n' "$1" > "$q"; return 1; }
  https_setup_question
  assert_eq "$(get_env PORTAL_HTTPS)" false
  assert_contains "$(cat "$q")" "Serve the portal over HTTPS? This adds a certificate that can only vouch for this install's own addresses to your login keychain; macOS asks for your password."
  confirm() { return 0; }; set_env PORTAL_HTTPS ''
  https_setup_question
  assert_eq "$(get_env PORTAL_HTTPS)" true
  # asked once: a decision in .env is not asked again
  : > "$TMP/calls"; confirm() { echo asked >> "$TMP/calls"; return 0; }
  https_setup_question
  assert_eq "$(cat "$TMP/calls")" ""
}

test_urls_follow_the_scheme() {
  _tls_env
  assert_eq "$(portal_url)" "http://devos-ade.localhost:8800"
  set_env PORTAL_PORT 80
  assert_eq "$(portal_url chat)" "http://chat.devos-ade.localhost"
  set_env PORTAL_HTTPS true
  assert_eq "$(portal_url chat)" "https://chat.devos-ade.localhost:80"   # (https has no default port 80)
  set_env PORTAL_PORT 8800; save_portal_origin
  assert_eq "$(get_env PORTAL_ORIGIN)" "https://devos-ade.localhost:8800"
  # curl through Caddy trusts the install's CA, and only when it is https
  curl() { printf '%s\n' "$*" > "$TMP/curl"; }
  portal_curl '' /healthz -s
  assert_contains "$(cat "$TMP/curl")" "--cacert $STATE_DIR/tls/ca.pem"
  assert_contains "$(cat "$TMP/curl")" "https://devos-ade.localhost:8800/healthz"
  set_env PORTAL_HTTPS false
  portal_curl '' /healthz -s
  if grep -q cacert "$TMP/curl"; then return 1; fi
}

test_the_caddy_snippets_on_and_off() {
  on="$(cat "$STACK_DIR/caddy/tls-on.caddy")"; off="$(cat "$STACK_DIR/caddy/tls-off.caddy")"
  # on: the certificate files compose mounts, the redirect wrapper before tls on the one listener, a plain health port
  assert_contains "$on" "tls /etc/bn-tls/site.pem /etc/bn-tls/site.key"
  assert_eq "$(sed -n '/^(local_listener)/,/^}/p' "$STACK_DIR/caddy/tls-on.caddy" | grep -E 'servers|http_redirect|^\s+tls$' | tr -d '\t' | tr '\n' '|')" "servers :8080 {|http_redirect|tls|"
  assert_contains "$on" "http://:8089 {"
  # off: the same three snippets, empty
  for s in local_tls local_listener local_health; do
    assert_eq "$(sed -n "/^($s) {/,/^}/p" "$STACK_DIR/caddy/tls-off.caddy" | grep -vc '^(\|^}')" 0
    grep -q "^($s) {" "$STACK_DIR/caddy/tls-off.caddy" || { echo "tls-off.caddy lacks $s" >&2; return 1; }
  done
  # the main file: the scheme comes from LOCAL_SCHEME (http while unset), every local site imports local_tls, and the
  # remote sites are not touched
  c="$(cat "$STACK_DIR/caddy/Caddyfile")"
  assert_contains "$c" 'import tls-{$LOCAL_TLS:off}.caddy'
  assert_contains "$c" 'http_port {$HTTP_PORT:8080}'
  for h in PORTAL_HOST CHAT_HOST ADMIN_HOST FILES_HOST; do
    assert_eq "$(grep -c '^{\$LOCAL_SCHEME:http}://{\$'"$h"'} {$' "$STACK_DIR/caddy/Caddyfile")" 1
    assert_contains "$(grep -A1 '^{\$LOCAL_SCHEME:http}://{\$'"$h"'} {$' "$STACK_DIR/caddy/Caddyfile")" "import local_tls"
  done
  for f in terminal-on code-on preview-on artifact-on localgit-on; do
    grep -q 'LOCAL_SCHEME:http}://' "$STACK_DIR/caddy/$f.caddy" || { echo "$f.caddy: no scheme" >&2; return 1; }
    grep -q 'import local_tls' "$STACK_DIR/caddy/$f.caddy" || { echo "$f.caddy: no tls" >&2; return 1; }
  done
  if grep -l 'local_tls\|LOCAL_SCHEME' "$STACK_DIR"/caddy/remote-*.caddy >/dev/null 2>&1; then echo "a remote site follows the local scheme" >&2; return 1; fi
  # compose: the overlay sets what the snippets read, and is added only while it is on
  o="$(cat "$STACK_DIR/compose.https.yaml")"
  for k in 'LOCAL_TLS: "on"' 'LOCAL_SCHEME: https' 'HTTP_PORT: "8089"' 'HTTPS_PORT: "8080"' 'http://127.0.0.1:8089/caddy-health'; do assert_contains "$o" "$k"; done
  _tls_env
  if compose_overlays | grep -q https; then return 1; fi
}

test_the_addresses_in_the_apps_follow_the_scheme() {
  _tls_env
  # the code container's origin and the sandbox's frame sources come from the same variable as Caddy's
  assert_contains "$(cat "$STACK_DIR/compose.code.yaml")" 'CODE_ORIGIN: ${BN_LOCAL_SCHEME:-http}://'
  # ... which dc sets from PORTAL_HTTPS
  assert_contains "$(cat "$STACK_DIR/lib/common.sh")" 'BN_LOCAL_SCHEME="$(flag_on "$(get_env PORTAL_HTTPS)" && echo https || echo http)"'
  assert_contains "$(cat "$STACK_DIR/compose.yaml")" 'PORTAL_HTTPS: ${PORTAL_HTTPS:-}'
}

test_the_commands_exist() {
  assert_contains "$(cmd_help)" "https        The portal over HTTPS on this computer"
  out="$(https_usage)"
  assert_contains "$out" "on        Serves the portal over HTTPS"
  _tls_env
  assert_contains "$(cmd_https status)" "HTTPS: off"
  if (cmd_https nonsense) >/dev/null 2>&1; then return 1; fi
}
