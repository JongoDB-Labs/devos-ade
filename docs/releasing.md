# Releasing DevOS ADE

For maintainers. Users never run any of this: `./stack update` (and Home's **Update now**) only pulls what a release
already pins.

## Every release brings the core services to their newest tested versions

The pins in `compose.yaml`, the Dockerfiles, the sandbox tools' ARGs and the pip locks lag upstream unless somebody moves
them, and users cannot move them: an update brings a service exactly to what its release pins. So **every release runs
`bin/bump-core-services` first**, and service drift alone justifies a patch release.

```bash
bin/bump-core-services --check     # what would move: changes nothing (exit 3: something would)
bin/bump-core-services             # move it: the pins, ARGs, digests, hash locks and catalog/core-services.tsv
```

Python 3 only (and `uv`, for the pip locks; `GITHUB_TOKEN` raises GitHub's API limit). It prints an old → new table with
release-note links; read the notes of every service that moved.

What it does, per pin:

- **Cooldown.** The newest stable upstream release that is **at least 3 days old** (`--cooldown-days`; `--now` sets the
  clock). Fast-moving AI projects have shipped compromised or broken releases that were pulled within days; waiting
  keeps those out. Pre-releases and drafts never count. A pin never moves backwards.
- **Security exception.** A release whose notes announce security fixes (a CVE or GHSA id, "security advisory", "security
  fix") is taken at once, and the table says why. Words like "improved security" do not count.
- **Digests.** Every image is pinned as `name:tag@sha256:…` (the multi-arch index). A release that stays the same keeps
  its digest; base images (`python:3.12-slim`, `alpine:3.24`) keep their tag and only move their digest, once the tag's
  last push is past the cooldown.
- **Rewrites.** `compose.yaml`, `compose.terminal.yaml`, `compose.tailscale.yaml`, `open-webui/Dockerfile`,
  `caddy/Dockerfile`, `tests/caddy-validate.sh`, the python/node/alpine bases of `portal/`, `shared-mcp/`, `stt/`,
  `code/` and `terminal/`, terminal/Dockerfile's `CODEX_`, `COPILOT_`, `TTYD_` and `GH_` versions with the SHA-256 of
  each file (downloaded and hashed), the versions the e2e suite is run with (`tests/e2e/browser/common.py`), and the
  three `requirements.txt` locks (`uv pip compile --generate-hashes --exclude-newer <cooldown>`).
- **Holds.** `HOLDS` in the tool lists a pin that is reported but never rewritten (Tailscale: remote access needs a real
  tailnet to test). Remove the entry once it is tested.
- **Not covered:** Cursor CLI (no release feed or checksum) and the npm tools' lockfiles (`terminal/claude-code`,
  `terminal/tools/*`): move those by hand.

`catalog/core-services.tsv` records the newest stable upstream release of each core service (even when the cooldown held
it back): `./stack versions` and Settings → Updates & backups → *Core services* show it as "newest upstream", next to
what runs and what the release pins. Commit it with the bump.

## The checklist

1. `bin/bump-core-services`, read the release notes of what moved, and commit the result.
2. Build and test with the new pins: the unit suites (`tests/run.sh`, `portal/test.sh`, the Code page's tests, which all
   build their images), `tests/test_litellm_live.sh` against the new LiteLLM (model-list changes must still apply live
   through its admin API), and the e2e stages on the Linux test host.
3. Move the changelog's `[Unreleased]` entries under the new version (a service move is a user-facing change: say which
   versions) and tag. Patch release for drift and fixes, minor for a feature.
4. Check the update path: after `./stack update`, `./stack versions` shows every service running what the release pins
   (the update itself fails otherwise and `./stack rollback` goes back).

## Why a failed check is not a skipped step

`./stack update` ends by comparing every recreated container's image digest with `compose.yaml`
(`update_verify_images`, lib/versions.sh). A service on another image fails the update the way a failed setup does:
its record stays *running*, so the next `./stack update` finishes it and `./stack rollback` goes back.
