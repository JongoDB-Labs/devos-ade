# shellcheck shell=bash
# shellcheck disable=SC2034  # read by the libs that source this
# The project's names, in one place (sourced by lib/common.sh). Each layer has its own copy of the same values
# (portal/portal/brand.py, code/server/brand.mjs, code/web/src/brand.ts, install.sh; tests/test_brand.sh checks that
# they agree). Since v0.25.0 the project is DevOS ADE (formerly bedrock-now); its internal names stayed as they were —
# the Compose project and volumes, the hosts, BEDROCK_NOW_*, the helper's labels, ./stack: docs/internal-names.md.
#   PRODUCT_NAME         the name a person reads (the installed web app's name too: portal_app_name, lib/portal.sh)
#   PRODUCT_SLUG         the name where a space cannot go (a new install's folder, a user agent)
#   PRODUCT_REPO         the project's GitHub repository
#   PRODUCT_LEGACY_NAME  the name before v0.25.0: ./stack open also finds an app installed under it (the browser keeps
#                        an installed app's old name until you accept the new one), and uninstall takes it too
#   PRODUCT_LEGACY_REPO  the repository's name before v0.25.0: GitHub redirects it to PRODUCT_REPO, and
#                        lib/repo_rename.sh moves an origin still there (portal/portal/updates.py has both names too)
PRODUCT_NAME="DevOS ADE"
PRODUCT_SLUG="devos-ade"
PRODUCT_REPO="JongoDB-Labs/devos-ade"
PRODUCT_LEGACY_NAME="bedrock-now"
PRODUCT_LEGACY_REPO="JongoDB-Labs/bedrock-now"
