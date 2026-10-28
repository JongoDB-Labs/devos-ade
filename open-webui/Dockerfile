# Open WebUI as pinned, with the Python runner's packages vendored into it (vendor.py, packages.txt). Chat's page
# reaches only Open WebUI itself (caddy/Caddyfile chat_csp), so its Python runner (Pyodide, in a sandboxed frame:
# chat_runtime) loads these wheels from /pyodide/ here, never from the CDN its lock names. Built locally (compose.yaml:
# <project>/open-webui:local, pull_policy never — no registry image can take its name), never pushed; ./stack setup,
# update and up build it. The pin: compose.yaml passes `image` (the same as this default; tests/test_openwebui.sh).
ARG image=ghcr.io/open-webui/open-webui:v0.12.4-slim@sha256:41812075aede8ada8497cb2b71c76412978633eee72775bb77796f593d03b677
FROM ${image}
# (what ./stack update checks: the container runs a build on the base image this release pins — lib/versions.sh)
ARG image
LABEL dev.devos-ade.base-image="${image}"
# (./stack passes a new value only to try again what a build before left out — a download that failed; else the
# cached layer stands: the image's lock, and so every wheel, is the same)
ARG BN_VENDOR_TRY=0
USER root
COPY vendor.py packages.txt /tmp/bn-vendor/
# Each wheel from the lock's own URL, checked against the lock's sha256 (vendor.py: bounded, nothing it downloads is
# run); one that fails is left out, said in this build's log and in /opt/bn-vendor (vendored.json, vendored.txt: what
# ./stack status reads — outside what Open WebUI serves) — the build goes on. Pyodide's own console pages go: a page
# of the public route (caddy/Caddyfile chat_runtime) that runs what it is given has no place there.
RUN echo "vendor: try ${BN_VENDOR_TRY}" \
 && python3 -I /tmp/bn-vendor/vendor.py /app/build/pyodide /tmp/bn-vendor/packages.txt /opt/bn-vendor \
 && rm -rf /tmp/bn-vendor \
 && rm -f /app/build/pyodide/console.html /app/build/pyodide/console-v2.html
USER 0:0
