"""The project's names, in one place for the portal: the same values as lib/brand.sh (tests/test_brand.sh checks that
they agree). Since v0.25.0 the project is DevOS ADE (formerly bedrock-now); its internal names stayed as they were —
the hosts, cookie names, signing salts, X-Requested-With, the installed app's id and link scheme:
docs/internal-names.md.

  NAME          the name a person reads (page titles, texts, the installed web app's name: webapp.py)
  SLUG          the name where a space cannot go (user agents)
  REPO          the project's GitHub repository (the update check: updates.py)
  LEGACY_NAME   the name before v0.25.0
  LEGACY_REPO   the repository's name before v0.25.0: GitHub redirects it to REPO; updates.py takes both
"""

NAME = "DevOS ADE"
SLUG = "devos-ade"
REPO = "JongoDB-Labs/devos-ade"
LEGACY_NAME = "bedrock-now"
LEGACY_REPO = "JongoDB-Labs/bedrock-now"
