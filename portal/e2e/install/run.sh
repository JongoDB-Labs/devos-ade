#!/usr/bin/env bash
# Opt-in end-to-end check, run by hand (not part of tests/run.sh or CI: it builds a ~1 GB image and needs Docker).
# Installs the portal as a web app in a throwaway Chromium (Debian's current package; check.py prints its
# version) inside a container and checks that ./stack open finds and opens it. Touches nothing outside Docker:
# no browser profile, no ~/Applications, no ports. Its two image tags (unique to the run) are removed afterwards.
# Usage: portal/e2e/install/run.sh [OUT_DIR]   (OUT_DIR, if given, receives a screenshot of the installed app)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../../.." && pwd)"
BASE=devos-ade-portal-e2e-base-$$; E2E=devos-ade-portal-e2e-$$
trap 'docker rmi -f "$E2E" "$BASE" >/dev/null 2>&1 || true' EXIT
# (the test stage with the repository's files its tests check, as portal/test.sh builds it; without them, those tests skip)
docker build -q --target test --build-context repo="$root" -t "$BASE" "$root/portal" >/dev/null
docker build -q --build-arg BASE="$BASE" -t "$E2E" "$here" >/dev/null
out=()
if [ -n "${1:-}" ]; then mkdir -p "$1"; out=(-v "$(cd "$1" && pwd):/out"); fi
docker run --rm "${out[@]+"${out[@]}"}" \
  -e PORTAL_PASSWORD="correct horse" -e PORTAL_SECRET="$(printf 's%.0s' $(seq 1 48))" \
  -e PORTAL_HOST=devos-ade.localhost -e PORTAL_PORT=8000 -e PRICE_UPDATES=false -e UPDATE_CHECK=false \
  -e PORTAL_STATE_DIR=/tmp/state -e PORTAL_CATALOG_DIR=/tmp/catalog -e PORTAL_LITELLM_DIR=/tmp/litellm \
  -v "$root/portal/portal:/app/portal:ro" -v "$root:/stack:ro" \
  "$E2E" python /check.py
