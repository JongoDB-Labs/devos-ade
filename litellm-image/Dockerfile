# LiteLLM as pinned, with its Python compiled at build time. The upstream image ships its packages as source only (no .pyc),
# so every new container compiled them again before it could answer: about 6 s of a start of ~27 s (JON-1484). Here the
# compiled files are made once, in the image, beside their sources (default timestamp checking: the sources in the image
# never change, so each .pyc stays valid). Nothing writable keeps compiled code and no setting points Python at another
# folder: a process cannot change the bytecode it later runs. Nothing else changes: the base's entrypoint, command, user
# and working folder. Built locally (compose.yaml: <project>/litellm:local, pull_policy never — no registry image can take
# its name), never pushed; ./stack setup, update and up build it, from Docker's cache unless this file or the pin changed
# (an unchanged release, a prepared update and a config-only change rebuild nothing: the cache gives the same image, and
# Compose keeps LiteLLM's container — with Docker's containerd store the cache build's id differs, its content does not,
# and Compose, measured, still keeps the container; a changed pin or Dockerfile is new content and recreates it).
# The pin: compose.yaml passes `image` (the same as this default; tests/test_litellm_image.sh).
ARG image=ghcr.io/berriai/litellm:1.106.3@sha256:74d0696a9f0afcc993c7659d246f0c542f003368298633e852228250779f1032
FROM ${image}
# (what ./stack update checks: the container runs a build on the base image this release pins — lib/versions.sh)
ARG image
LABEL dev.devos-ade.base-image="${image}"
# Every site-packages folder Python itself names (the folder differs between releases of the base). The config folder
# (/app/config, mounted read-only at run time) is not compiled and stays uncached, as before. Compiling only saves time:
# a file that does not compile (compileall exits 1, having compiled the rest) stays source only, as all of them were,
# and never stops setup or an update.
RUN for d in $(python -c 'import site, sysconfig; print(" ".join(dict.fromkeys(site.getsitepackages() + [sysconfig.get_paths()["purelib"]])))'); do \
      python -m compileall -q -j 0 "$d" || echo "devos-ade: some files of $d did not compile: they stay source only"; \
    done
