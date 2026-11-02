#!/usr/bin/env bash
# End-to-end check "https-local-portal" (JON-976): the portal served over HTTPS from the install's own name-constrained CA.
# Runs against a KEPT throwaway stack (tests/e2e/run.sh --keep, or --reuse), never another install: only bne2e[-…]
# project names are accepted. Linux only (the CA is trusted through an NSS database; a macOS run would have to touch
# a keychain, which an automated check must not).
#   1. ./stack https on, with HOME set to a throwaway folder: the CA goes into THAT folder's NSS database
#      ($HT/.pki/nssdb), never this computer's system store (-y answers the system-store question with "no").
#   2. curl: https answers on the portal port, plain http on the same port redirects to https.
#   3. openssl: the site certificate verifies with the install's CA; a certificate for evil.example and one for
#      other.localhost, signed by the same CA's key, are refused (the CA's name constraints).
#   4. Chromium in the pinned Playwright container, with a COPY of that NSS database (no ignore_https_errors): the
#      portal login, Chat and Terminal pages load over https, and a wss connection opens (tests/e2e/https_browser.py).
#   5. ./stack https off: plain http answers again, https does not, and .state/tls is gone.
# Results: OUT/https/results.tsv (suite https, id https-local-portal and its steps), logs in OUT/https/.
#   tests/e2e/https.sh --project bne2e-NAME [--out DIR]
# Run it under the heavy lock on the e2e host, after a kept run of tests/e2e/run.sh.
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PW_IMAGE="mcr.microsoft.com/playwright/python:v1.55.0-noble@sha256:640d578aae63cfb632461d1b0aecb01414e4e020864ac3dd45a868dc0eff3078"
PROJECT=bne2e; OUT="$ROOT/tests/e2e/out"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
valid_project "$PROJECT" || die "project '$PROJECT' is not one of this suite's names (bne2e[-name])"
STACK="$ROOT/tests/e2e/work/$PROJECT"
[ -f "$STACK/.env" ] && [ -x "$STACK/stack" ] || die "no kept throwaway at $STACK (run tests/e2e/run.sh --keep first)"
[ "$(uname -s)" = Linux ] || { say "https-local-portal: Linux only (the CA is trusted in an NSS database); skipped"; exit 0; }
for t in certutil openssl curl docker; do command -v "$t" >/dev/null 2>&1 || die "needs $t"; done

OUT="$OUT/https"; mkdir -p "$OUT"; RESULTS="$OUT/results.tsv"; : > "$RESULTS"
HT="$(mktemp -d)"; trap 'rm -rf "$HT"' EXIT
HOSTN="$PROJECT.localhost"; PORT="$(get_env PORTAL_PORT)"
[ -n "$PORT" ] || die "no PORTAL_PORT in $STACK/.env"
T0="$(now)"
step() { # step ID CMD… — records PASS/FAIL under suite https
  local id="$1" t; shift; t="$(now)"
  if "$@" > "$OUT/$id.log" 2>&1; then record https "$id" PASS "$(( $(now) - t ))" ""; else record https "$id" FAIL "$(( $(now) - t ))" "$(tail -n 3 "$OUT/$id.log" | tr '\n' ' ')"; FAILED=1; fi
}
FAILED=0
# the throwaway's own commands: HOME is the throwaway folder, nothing else of this shell leaks in
st() { ( cd "$STACK" && env -i PATH="$PATH" HOME="$HT" USER="${USER:-e2e}" DEVOS_ADE_NO_OPEN=1 TERM=dumb NO_COLOR=1 LANG=C ./stack -y "$@" ); }
CURL=(curl -sS -m 20 --resolve "$HOSTN:$PORT:127.0.0.1")

turn_on() { st https on; }
https_answers() {
  local code; code="$("${CURL[@]}" --cacert "$STACK/.state/tls/ca.pem" -o /dev/null -w '%{http_code}' "https://$HOSTN:$PORT/healthz")" || return 1
  [ "$code" = 200 ] || { echo "https /healthz: $code"; return 1; }
}
http_redirects() {
  local out; out="$("${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "http://$HOSTN:$PORT/")" || return 1
  case "$out" in 30[1278]\ https://"$HOSTN":"$PORT"/*) ;; *) echo "plain http on the same port: $out"; return 1 ;; esac
}
chain_and_constraints() {
  local tls="$STACK/.state/tls" w="$HT/chain"; mkdir -p "$w"
  openssl verify -CAfile "$tls/ca.pem" -purpose sslserver "$tls/site.pem" || return 1
  local n
  for n in evil.example other.localhost; do   # leaves for names outside the constraints, signed with the CA's own key
    openssl ecparam -name prime256v1 -genkey -noout -out "$w/$n.key" || return 1
    openssl req -new -key "$w/$n.key" -subj "/CN=$n" -out "$w/$n.csr" || return 1
    printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$n" > "$w/$n.ext"
    openssl x509 -req -in "$w/$n.csr" -CA "$tls/ca.pem" -CAkey "$tls/ca.key" -CAcreateserial -CAserial "$w/ca.srl" -days 2 -out "$w/$n.pem" -extfile "$w/$n.ext" || return 1
    if openssl verify -CAfile "$tls/ca.pem" -purpose sslserver -verify_hostname "$n" "$w/$n.pem" > "$w/$n.out" 2>&1; then echo "$n was accepted by the install's CA"; return 1; fi
    grep -qi "permitted subtree" "$w/$n.out" || { echo "$n refused for another reason:"; cat "$w/$n.out"; return 1; }
  done
}
browser() {
  local image="$PROJECT/e2e-playwright:local"; mkdir -p "$OUT/browser" "$HT/nss-copy"
  docker build -q --build-arg PW_IMAGE="$PW_IMAGE" -t "$image" "$HERE" > "$OUT/browser-build.log" 2>&1 || { echo "docker build of the Playwright runner failed"; return 1; }
  cp -R "$HT/.pki/nssdb/." "$HT/nss-copy/" && chmod -R a+rX "$HT/nss-copy"
  local opts=(--network host --user "$(id -u):$(id -g)" -e HOME=/tmp) h
  for h in "$HOSTN" "chat.$HOSTN" "terminal.$HOSTN"; do opts+=(--add-host "$h:127.0.0.1"); done
  docker run --rm --name "$PROJECT-https-playwright" --init --shm-size=1g "${opts[@]}" \
    -e E2E_HOST="$HOSTN" -e E2E_PORT="$PORT" \
    -v "$STACK/.env:/run/e2e/env:ro" -v "$HERE/https_browser.py:/suite/https_browser.py:ro" \
    -v "$HT/nss-copy:/tmp/.pki/nssdb" -v "$OUT/browser:/out" \
    "$image" python3 -u /suite/https_browser.py
}
turn_off() {
  st https off || return 1
  local code
  code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "http://$HOSTN:$PORT/healthz")" || return 1
  [ "$code" = 200 ] || { echo "http /healthz after off: $code"; return 1; }
  if "${CURL[@]}" -k -o /dev/null "https://$HOSTN:$PORT/healthz" 2>/dev/null; then echo "https still answers after off"; return 1; fi
  [ ! -e "$STACK/.state/tls" ] || { echo ".state/tls still exists"; return 1; }
  [ -z "$(certutil -L -d "sql:$HT/.pki/nssdb" 2>/dev/null | grep -i 'DevOS ADE local CA')" ] || { echo "CA still in the NSS database"; return 1; }
}

step https-on turn_on
if [ "$FAILED" = 0 ]; then
  step https-answers https_answers
  step http-redirects http_redirects
  step chain-and-name-constraints chain_and_constraints
  step browser-pages-and-wss browser
fi
step https-off turn_off
if [ "$FAILED" = 0 ]; then record https https-local-portal PASS "$(( $(now) - T0 ))" "all steps passed"; else record https https-local-portal FAIL "$(( $(now) - T0 ))" "see $OUT/*.log"; fi
cat "$RESULTS" >&2
exit "$FAILED"
