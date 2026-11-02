# shellcheck shell=bash
# The portal over HTTPS on this computer (JON-976; README "HTTPS for the portal", docs/security.md "HTTPS on this computer").
# Opt-in: PORTAL_HTTPS=true (Settings › Account & security › Serve the portal over HTTPS, ./stack https on). Without it
# everything is plain HTTP on 127.0.0.1, as before.
#
#   .state/tls/ca.pem, ca.key   this install's own CA: EC P-256, ten years, pathlen 0, and critical name constraints that let
#                               it vouch for this install's names alone (PORTAL_HOST and its subdomains, the previews'
#                               PREVIEW_DOMAIN, and any configured local host outside those). The key is mode 600 and is
#                               never mounted into a container: only this file's functions read it.
#   .state/tls/site.pem, .key   the certificate Caddy serves: EC P-256, 397 days, CA:FALSE, serverAuth, for the names above.
#   .state/tls/serve/           copies of the site certificate and its key, the one folder compose.https.yaml mounts (read-only)
#                               into Caddy. World-readable files in a folder of 755 under .state (700), as
#                               localgit_tls_ensure does: Caddy's user (65534) is not yours.
#   .state/tls/constraints, sans   the lists the files above were made for (what a changed host name is compared with)
#
# The certificates are made here, on the host, with openssl (macOS' LibreSSL and OpenSSL 3 alike: config files, no -addext);
# Caddy never makes one (auto_https stays off). The site certificate is made again, with no question asked, when fewer than
# 30 days are left or the names changed; a name outside the CA's constraints needs a new CA, and so a new trust: that is
# only done by ./stack https on (setup, Settings), where the system's own prompt is the consent.
#
# Trust, only through the user's own action: macOS adds the CA to the login keychain (security add-trusted-cert; macOS asks
# for the password itself), Linux to the user's NSS database (certutil) and, only after an explicit yes, to the system store
# (sudo). Afterwards the computer is asked whether it trusts the site certificate; if not, PORTAL_HTTPS goes back off.
#
# Hooks: https_on / portal_scheme (lib/portal.sh), https_setup_question (setup), https_guard (up, update, setup),
# https_overlay_wanted (lib/common.sh compose_overlays), cmd_https / https_usage (./stack https).

tls_dir() { printf '%s/tls\n' "$STATE_DIR"; }
tls_serve_dir() { printf '%s/serve\n' "$(tls_dir)"; }
tls_login_keychain() { printf '%s/Library/Keychains/login.keychain-db\n' "$HOME"; }
tls_nss_db() { printf '%s/.pki/nssdb\n' "$HOME"; }
tls_ca_nick() { printf 'DevOS ADE local CA (%s)\n' "$(portal_host)"; }
tls_deb_dir() { printf '%s\n' "${TLS_DEB_DIR:-/usr/local/share/ca-certificates}"; }   # (Debian's; Red Hat's anchors: below)
tls_rh_dir() { printf '%s\n' "${TLS_RH_DIR:-/etc/pki/ca-trust/source/anchors}"; }
tls_system_file() { printf '%s/devos-ade-%s.crt\n' "$(tls_deb_dir)" "$(portal_host)"; }
tls_anchor_file() { printf '%s/devos-ade-%s.pem\n' "$(tls_rh_dir)" "$(portal_host)"; }
tls_have_openssl() { command -v openssl >/dev/null 2>&1; }

# tls_preview_domain -> the previews' site, as PREVIEW_DOMAIN would be (set only once the Code page was turned on)
tls_preview_domain() { local d; d="$(get_env PREVIEW_DOMAIN)"; [ -n "$d" ] || d="$(code_preview_domain_name)"; printf '%s\n' "$d"; }

# tls_permitted NAME CONSTRAINT... -> 0 when NAME (a wildcard counts as one label under it) is within a constraint: ".x"
# any name under x, "x" x itself and any name under it (RFC 5280)
tls_permitted() {
  local n="$1" c; shift
  case "$n" in '*.'*) n="w.${n#'*.'}" ;; esac
  for c in "$@"; do
    case "$c" in
      .*) case "$n" in *"$c") return 0 ;; esac ;;
      *) [ "$n" = "$c" ] && return 0; case "$n" in *".$c") return 0 ;; esac ;;
    esac
  done
  return 1
}

# tls_local_hosts -> the portal's and every app's host name on this computer, one per line, each once
tls_local_hosts() {
  local s
  { for s in '' chat admin files git terminal code; do app_host "$s"; done; } | awk '!seen[$0]++'
}

# tls_constraints -> what the CA may vouch for (DNS names, one per line): the portal host, its subdomains, the previews' site,
# and each configured local host outside those
tls_constraints() {
  local h pd base
  h="$(portal_host)"; pd="$(tls_preview_domain)"
  printf '%s\n.%s\n.%s\n' "$h" "$h" "$pd"
  while IFS= read -r base; do
    tls_permitted "$base" "$h" ".$h" ".$pd" || printf '%s\n' "$base"
  done <<EOF
$(tls_local_hosts)
EOF
}

# tls_sans -> the site certificate's names, one per line
tls_sans() {
  local h pd base
  h="$(portal_host)"; pd="$(tls_preview_domain)"
  printf '%s\n*.%s\n*.%s\n*.artifact.%s\n' "$h" "$h" "$pd" "$pd"
  while IFS= read -r base; do
    tls_permitted "$base" "$h" ".$h" ".$pd" || printf '%s\n' "$base"
  done <<EOF
$(tls_local_hosts)
EOF
}

# _tls_join PREFIX -> stdin's lines as PREFIXa,PREFIXb (a config file's list)
_tls_join() { awk -v p="$1" 'NR > 1 { printf "," } { printf "%s%s", p, $0 } END { print "" }'; }

# tls_ca_make — a new CA in .state/tls (the key first, mode 600; the old files replaced together)
tls_ca_make() {
  local d tmp cfg nc h today
  d="$(tls_dir)"; h="$(portal_host)"; today="$(date +%Y-%m-%d)"
  ( umask 077; mkdir -p "$d" ) || return 1
  chmod 700 "$STATE_DIR" "$d" 2>/dev/null || true
  tmp="$(mktemp -d "$d/.new.XXXXXX")" || return 1
  cfg="$tmp/ca.cnf"
  nc="$(tls_constraints | _tls_join 'permitted;DNS:')"
  cat > "$cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
O = DevOS ADE
CN = DevOS ADE local CA for $h $today
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical,$nc
EOF
  ( umask 077
    openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/ca.key" >/dev/null 2>&1 &&
    openssl req -new -x509 -sha256 -days 3650 -key "$tmp/ca.key" -config "$cfg" -out "$tmp/ca.pem" >/dev/null 2>&1 ) || { rm -rf "$tmp"; return 1; }
  chmod 600 "$tmp/ca.key"; chmod 644 "$tmp/ca.pem"
  rm -f "$d/site.pem" "$d/site.key" "$d/ca.srl"   # (a site certificate is the old CA's: made again below)
  mv "$tmp/ca.key" "$d/ca.key" && mv "$tmp/ca.pem" "$d/ca.pem" || { rm -rf "$tmp"; return 1; }
  tls_constraints > "$d/constraints"
  rm -rf "$tmp"
}

# tls_site_make — a new site certificate from the CA (397 days), published for Caddy in .state/tls/serve
tls_site_make() {
  local d tmp cfg ext sans h
  d="$(tls_dir)"; h="$(portal_host)"
  [ -s "$d/ca.pem" ] && [ -s "$d/ca.key" ] || return 1
  tmp="$(mktemp -d "$d/.new.XXXXXX")" || return 1
  sans="$(tls_sans | _tls_join 'DNS:')"
  cfg="$tmp/site.cnf"; ext="$tmp/site.ext"
  cat > "$cfg" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
O = DevOS ADE
CN = $h
EOF
  cat > "$ext" <<EOF
[v3_leaf]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = $sans
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
  ( umask 077
    openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/site.key" >/dev/null 2>&1 &&
    openssl req -new -sha256 -key "$tmp/site.key" -config "$cfg" -out "$tmp/site.csr" >/dev/null 2>&1 &&
    openssl x509 -req -sha256 -days 397 -in "$tmp/site.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAserial "$d/ca.srl" -CAcreateserial \
      -extfile "$ext" -extensions v3_leaf -out "$tmp/site.pem" >/dev/null 2>&1 ) || { rm -rf "$tmp"; return 1; }
  chmod 600 "$tmp/site.key"; chmod 644 "$tmp/site.pem"
  mv "$tmp/site.key" "$d/site.key" && mv "$tmp/site.pem" "$d/site.pem" || { rm -rf "$tmp"; return 1; }
  tls_sans > "$d/sans"
  rm -rf "$tmp"
  tls_serve_publish
}

# tls_serve_publish — the site certificate and key as Caddy reads them (see the header: the one folder compose mounts)
tls_serve_publish() {
  local d s
  d="$(tls_dir)"; s="$(tls_serve_dir)"
  mkdir -p "$s" || return 1
  cp "$d/site.pem" "$s/site.pem.new" && cp "$d/site.key" "$s/site.key.new" || return 1
  chmod 644 "$s/site.pem.new" "$s/site.key.new"; chmod 755 "$s" "$d" "$STATE_DIR" 2>/dev/null || true
  chmod 700 "$STATE_DIR" 2>/dev/null || true   # (the world cannot reach a folder under it; Docker mounts the folder itself)
  mv "$s/site.pem.new" "$s/site.pem" && mv "$s/site.key.new" "$s/site.key"
}

# tls_ca_covers -> 0 while every name the site certificate needs is within the CA's constraints (the list it was made with)
tls_ca_covers() {
  local d n cons=()
  d="$(tls_dir)"; [ -s "$d/constraints" ] || return 1
  while IFS= read -r n; do [ -z "$n" ] || cons+=("$n"); done < "$d/constraints"
  while IFS= read -r n; do tls_permitted "$n" "${cons[@]}" || return 1; done <<EOF
$(tls_sans)
EOF
}

# tls_site_current -> 0 while the site certificate is there, for the names wanted now, with 30 days or more left
tls_site_current() {
  local d; d="$(tls_dir)"
  [ -s "$d/site.pem" ] && [ -s "$d/site.key" ] && [ -s "$d/sans" ] || return 1
  [ "$(cat "$d/sans")" = "$(tls_sans)" ] || return 1
  openssl x509 -in "$d/site.pem" -noout -checkend 2592000 >/dev/null 2>&1
}

# tls_ensure [--no-new-ca] -> 0 with a CA and a current site certificate. TLS_CA_NEW=1 afterwards: a new CA was made (it
# needs trusting); TLS_SITE_NEW=1: a new site certificate. --no-new-ca (setup and update, which ask nothing): a name the CA
# cannot vouch for is left as it is and said (return 2).
tls_ensure() {
  local d; d="$(tls_dir)"; TLS_CA_NEW=0; TLS_SITE_NEW=0
  tls_have_openssl || { warn "HTTPS needs openssl, which was not found"; return 1; }
  if [ ! -s "$d/ca.pem" ] || [ ! -s "$d/ca.key" ] || ! tls_ca_covers || ! openssl x509 -in "$d/ca.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
    if [ "${1:-}" = --no-new-ca ] && [ -s "$d/ca.pem" ]; then return 2; fi
    tls_ca_make || { warn "could not make the certificate authority"; return 1; }
    TLS_CA_NEW=1
  fi
  if [ "$TLS_CA_NEW" = 1 ] || ! tls_site_current; then
    tls_site_make || { warn "could not make the site certificate"; return 1; }
    TLS_SITE_NEW=1
  fi
  [ -s "$(tls_serve_dir)/site.pem" ] || tls_serve_publish
  return 0
}

# --- trust ---

# tls_ca_sha1 -> the CA's SHA-1 fingerprint as security -Z takes it: 40 hex digits, upper case
tls_ca_sha1() {
  openssl x509 -in "$(tls_dir)/ca.pem" -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//; s/://g' | tr '[:lower:]' '[:upper:]'
}

# tls_trust_add -> adds the CA where this computer's browsers look, through the user's own action: macOS shows its password
# prompt; the system store on Linux only after an explicit yes. 1 when nothing was added.
tls_trust_add() {
  local ca db nick cmd sysf
  ca="$(tls_dir)/ca.pem"
  if [ "$(uname -s)" = Darwin ]; then
    log "adding the certificate authority to your login keychain — macOS asks for your password"
    security add-trusted-cert -r trustRoot -p ssl -k "$(tls_login_keychain)" "$ca"
    return
  fi
  db="$(tls_nss_db)"; nick="$(tls_ca_nick)"
  if command -v certutil >/dev/null 2>&1; then
    [ -f "$db/cert9.db" ] || { mkdir -p "$db" && certutil -d "sql:$db" -N --empty-password; } || return 1
    certutil -d "sql:$db" -D -n "$nick" >/dev/null 2>&1 || true
    certutil -d "sql:$db" -A -t "C,," -n "$nick" -i "$ca" || return 1
    log "added the certificate authority to your NSS database ($db): Chrome, Chromium and Firefox profiles that use it"
  else
    warn "certutil (libnss3-tools / nss-tools) was not found: browsers that read your NSS database cannot be told to trust the certificate"
  fi
  sysf="$(tls_system_file)"
  if [ -d "$(tls_deb_dir)" ]; then cmd="sudo cp '$ca' '$sysf' && sudo update-ca-certificates"
  else cmd="sudo cp '$ca' '$(tls_anchor_file)' && sudo update-ca-trust extract"; fi
  case "$(ask "Also add it to the system store (needs sudo; for curl, git and Firefox with system roots)? [y/N]" n)" in
    [Yy]*)
      if [ -d "$(tls_deb_dir)" ]; then sudo cp "$ca" "$sysf" && sudo update-ca-certificates
      else sudo cp "$ca" "$(tls_anchor_file)" && sudo update-ca-trust extract; fi || warn "the system store was not changed"
      ;;
    *) log "not added to the system store; to do it yourself: $cmd" ;;
  esac
  return 0
}

# tls_trust_remove -> takes the CA out again (it asks before the system store); 0 even when it was not there
tls_trust_remove() {
  local ca db nick sysf anchor sha
  ca="$(tls_dir)/ca.pem"; [ -s "$ca" ] || return 0
  if [ "$(uname -s)" = Darwin ]; then
    sha="$(tls_ca_sha1)"
    [ -z "$sha" ] || security delete-certificate -Z "$sha" -t "$(tls_login_keychain)" >/dev/null 2>&1 || true
    return 0
  fi
  db="$(tls_nss_db)"; nick="$(tls_ca_nick)"
  if command -v certutil >/dev/null 2>&1 && [ -f "$db/cert9.db" ]; then certutil -d "sql:$db" -D -n "$nick" >/dev/null 2>&1 || true; fi
  sysf="$(tls_system_file)"; anchor="$(tls_anchor_file)"
  if [ -f "$sysf" ] || [ -f "$anchor" ]; then
    case "$(ask "Take it out of the system store too (needs sudo)? [y/N]" n)" in
      [Yy]*) if [ -f "$sysf" ]; then sudo rm -f "$sysf" && sudo update-ca-certificates --fresh; else sudo rm -f "$anchor" && sudo update-ca-trust extract; fi ;;
      *) log "left in the system store; to remove it: sudo rm '$([ -f "$sysf" ] && echo "$sysf" || echo "$anchor")' and update the store" ;;
    esac
  fi
  return 0
}

# tls_trust_check -> 0 when this computer trusts the site certificate for the portal's name. macOS asks the system
# (security verify-cert); Linux verifies the chain with the CA (openssl verify) and wants a trust route: the NSS database
# holding the CA, or the system store verifying it alone.
tls_trust_check() {
  local d db
  d="$(tls_dir)"; [ -s "$d/site.pem" ] && [ -s "$d/ca.pem" ] || return 1
  if [ "$(uname -s)" = Darwin ]; then
    security verify-cert -c "$d/site.pem" -p ssl -s "$(portal_host)" >/dev/null 2>&1
    return
  fi
  openssl verify -CAfile "$d/ca.pem" -purpose sslserver "$d/site.pem" >/dev/null 2>&1 || return 1
  db="$(tls_nss_db)"
  if command -v certutil >/dev/null 2>&1 && [ -f "$db/cert9.db" ] && certutil -d "sql:$db" -L -n "$(tls_ca_nick)" >/dev/null 2>&1; then return 0; fi
  openssl verify -purpose sslserver "$d/site.pem" >/dev/null 2>&1
}

# --- turning it on and off ---

# https_unsupported -> prints why and returns 0 on a computer this does not run on
https_unsupported() {
  case "$(uname -s)" in Darwin | Linux) ;; *) echo "HTTPS for the portal is made for macOS and Linux"; return 0 ;; esac
  tls_have_openssl || { echo "openssl was not found"; return 0; }
  return 1
}

# https_overlay_wanted -> 0 while Caddy should serve the site certificate (compose.https.yaml): it is on, and the files are there
https_overlay_wanted() { https_on && [ -s "$(tls_serve_dir)/site.pem" ] && [ -s "$(tls_serve_dir)/site.key" ]; }

# https_fail_off WHY — turned back off, said plainly: a portal this computer does not trust is never left on
https_fail_off() {
  set_env PORTAL_HTTPS false
  save_portal_origin
  https_apply || true
  warn "HTTPS is off again: $1"
  warn "the portal is plain HTTP on $(portal_url) as before"
}

# https_apply — Caddy, the portal and the apps that name the portal's address, with the scheme .env holds now (one Compose
# call; only those whose configuration changed are recreated). With the stack stopped only .env changes.
https_apply() {
  local svc
  if ! declare -F _cfg_stack_running >/dev/null || ! _cfg_stack_running; then return 0; fi
  svc="portal open-webui caddy"
  [ -z "$(dc ps -q --status running forgejo 2>/dev/null)" ] || svc="$svc forgejo"
  [ -z "$(dc ps -q --status running code 2>/dev/null)" ] || svc="$svc code"
  # shellcheck disable=SC2086  # the service list, word-split on purpose
  run_phase "Restart · the portal over $(portal_scheme)" "$svc" dc up -d --no-deps --wait $svc || return 1
  ensure_portal_reachable
}

# https_notice_write — .state/status/https-switched.json: when the address changed, for Home's one notice
https_notice_write() {
  local d f tmp
  d="$(status_dir)"; f="$d/https-switched.json"
  mkdir -p "$d" 2>/dev/null || return 0
  tmp="$(mktemp "$d/.https-switched.XXXXXX")" 2>/dev/null || return 0
  printf '{"at": %s, "https": %s}\n' "$(date +%s)" "$(https_on && echo true || echo false)" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

# https_enable — PORTAL_HTTPS=true: the certificates, the trust, the check, then Caddy and the apps
https_enable() {
  local why
  if why="$(https_unsupported)"; then die "$why"; fi
  [ -n "$(get_env PORTAL_PASSWORD)" ] || [ -n "$(get_env PORTAL_SECRET)" ] || die "run ./stack setup first"
  tls_ensure || die "could not make the certificates"
  if tls_trust_check; then
    log "this computer already trusts the certificate"
  else
    tls_trust_add || { https_fail_off "the certificate authority was not added to this computer's trust (refused or failed)"; return 1; }
    tls_trust_check || { https_fail_off "this computer does not trust the certificate after adding it ($(uname -s) said no) — the portal stays plain HTTP"; return 1; }
  fi
  set_env PORTAL_HTTPS true
  save_portal_origin
  https_notice_write
  https_apply || die "the portal did not come back over HTTPS — ./stack https off turns it off again"
  log "the portal is served over HTTPS: $(portal_url)"
  log "sign in again there, and install the app again from the new address; $(portal_url) replaces $(printf '%s' "$(portal_url)" | sed 's/^https/http/')"
}

# https_disable — PORTAL_HTTPS=false: plain HTTP again, the CA out of the trust (it asks first), .state/tls deleted
https_disable() {
  local was=0
  https_on && was=1
  if [ -s "$(tls_dir)/ca.pem" ]; then
    if [ "${ASSUME_YES:-0}" = 1 ] || confirm "Remove the certificate authority from this computer's trust and delete $(tls_dir)?"; then
      tls_trust_remove
      rm -rf "$(tls_dir)"
    else
      log "kept the certificate authority in your trust and .state/tls; ./stack https off again removes them"
    fi
  fi
  set_env PORTAL_HTTPS false
  save_portal_origin
  [ "$was" = 0 ] || https_notice_write
  https_apply || die "the portal did not come back — see ./stack logs caddy"
  log "the portal is plain HTTP again: $(portal_url)"
}

# https_guard — at setup, up and update: a certificate that is due is made again without a question (and the new one
# published; Caddy is recreated by Compose, the files being in its configuration), and the portal that this computer no longer
# trusts is turned off
https_guard() {
  https_on || return 0
  local rc=0
  tls_ensure --no-new-ca || rc=$?
  if [ "$rc" = 2 ]; then
    warn "a host name of this install is outside what its HTTPS certificate authority may vouch for: ./stack https on makes a new one (and asks to trust it)"
  elif [ "$rc" != 0 ]; then
    https_fail_off "the certificates could not be made again"; return 0
  fi
  tls_trust_check || https_fail_off "this computer no longer trusts the certificate (the certificate authority was removed from your keychain or NSS database?) — ./stack https on adds it again"
}

# https_setup_question — interactive setup, once: PORTAL_HTTPS is asked when it was never decided; --yes, no terminal or an
# answer already in .env leave it as it is
https_setup_question() {
  [ -z "$(get_env PORTAL_HTTPS)" ] && [ "${UPD_MODE:-0}" != 1 ] || return 0
  [ "${ASSUME_YES:-0}" != 1 ] && _have_tty || return 0
  if https_unsupported >/dev/null; then return 0; fi
  if confirm "Serve the portal over HTTPS? This adds a certificate that can only vouch for this install's own addresses to your login keychain; macOS asks for your password."; then
    https_enable || true
  else
    set_env PORTAL_HTTPS false
    log "the portal stays plain HTTP; ./stack https on turns HTTPS on later"
  fi
}

https_status() {
  local d
  d="$(tls_dir)"
  if ! https_on; then
    printf 'HTTPS: off — %s (./stack https on)\n' "$(portal_url)"
    return 0
  fi
  printf 'HTTPS: on — %s\n' "$(portal_url)"
  if [ -s "$d/site.pem" ]; then
    printf '  Certificate   %s (until %s)\n' "$(openssl x509 -in "$d/site.pem" -noout -subject 2>/dev/null | sed 's/^subject= *//')" \
      "$(openssl x509 -in "$d/site.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    printf '  Authority     %s\n' "$(openssl x509 -in "$d/ca.pem" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
    if tls_trust_check; then printf '  Trusted       yes, by this computer\n'; else printf '  Trusted       NO — ./stack https on adds the authority again\n'; fi
  else
    printf '  Certificate   missing — ./stack https on makes it\n'
  fi
}

https_usage() {
  cat <<'EOF'
Usage: ./stack https <command>

  status    On or off, the address, the certificate and whether this computer trusts it
  on        Serves the portal over HTTPS on this computer: makes a certificate authority that can only vouch for this
            install's own addresses (.state/tls), adds it to your login keychain (macOS asks for your password) or your
            NSS database (Linux; the system store only after a yes), checks that the computer trusts it, then restarts
            Caddy and the apps with the https address. A computer that does not trust it keeps plain HTTP.
  off       Plain HTTP again; removes the authority from the keychain or NSS database (it asks first) and deletes .state/tls

  .env: PORTAL_HTTPS=true | false (Settings › Account & security › Serve the portal over HTTPS). The address changes:
  sign in again, and install the app again from the new address.
EOF
}

cmd_https() {
  local sub="${1:-status}"; [ $# -eq 0 ] || shift
  case "$sub" in
    status) [ $# -eq 0 ] || die "usage: ./stack https status"; https_status ;;
    on | enable) [ $# -eq 0 ] || die "usage: ./stack https on"; https_enable ;;
    off | disable) [ $# -eq 0 ] || die "usage: ./stack https off"; https_disable ;;
    help | -h | --help) https_usage ;;
    *) https_usage >&2; die "unknown: ./stack https $sub" ;;
  esac
}
