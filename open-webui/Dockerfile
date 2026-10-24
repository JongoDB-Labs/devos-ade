# Open WebUI as pinned, with the Python runner's packages vendored into it (vendor.py, packages.txt). Chat's page
# reaches only Open WebUI itself (caddy/Caddyfile chat_csp), so its Python runner (Pyodide, in a sandboxed frame:
# chat_runtime) loads these wheels from /pyodide/ here, never from the CDN its lock names. Built locally (compose.yaml:
# <project>/open-webui:local, pull_policy never — no registry image can take its name), never pushed; ./stack setup,
# update and up build it. The pin: compose.yaml passes `image` (the same as this default; tests/test_openwebui.sh).
ARG image=ghcr.io/open-webui/open-webui:v0.12.0-slim@sha256:a1edc483ff9e92c974875ca8a10c76ea7c9d462835cff1f1215318873f14f0ee
FROM ${image}
# (./stack passes a new value only to try again what a build before left out — a download that failed; else the
# cached layer stands: the image's lock, and so every wheel, is the same)
ARG BN_VENDOR_TRY=0
USER root
COPY vendor.py packages.txt /tmp/bn-vendor/
# Each wheel from the lock's own URL, checked against the lock's sha256 (vendor.py: bounded, nothing it downloads is
# run); one that fails is left out, said in this build's log and in vendored.json — the build goes on
RUN echo "vendor: try ${BN_VENDOR_TRY}" \
 && python3 -I /tmp/bn-vendor/vendor.py /app/build/pyodide /tmp/bn-vendor/packages.txt \
 && rm -rf /tmp/bn-vendor
USER 0:0
