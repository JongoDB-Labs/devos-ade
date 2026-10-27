"""Send feedback (GET /api/feedback; JON-440 plan A, G1): the addresses of a prefilled, PUBLIC issue on the project's
GitHub repository, one for each kind (Bug, Feature, Other). Nothing is sent from here and nothing is stored: the
browser opens GitHub, and the person reads, edits and submits the issue there. A prefilled address gives this portal no
receipt, so no text of the portal may say the report was sent; it says it opens GitHub.

What the address carries, and only this: the DevOS ADE version, this computer's OS and its Docker Compose version
(what ./stack wrote into STATUS_DIR/version.json: lib/version.sh). Never a path, a repository or project name, a prompt,
a file's contents, a key, an address of this computer or anything from Settings. Each value is checked against a
short allow-list of characters and, failing it, shown as "unknown"; the person can still edit every field on GitHub.

The issue forms are .github/ISSUE_TEMPLATE/{bug,feature,question}.yml in the repository; their field ids version, os
and compose are the query parameters that prefill them. The forms also add the label feedback."""

from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import urlencode

from . import brand, hostfiles

KINDS = {"bug": ("bug.yml", "[Bug] "), "feature": ("feature.yml", "[Feature] "), "other": ("question.yml", "[Other] ")}
ISSUES_NEW = f"https://github.com/{brand.REPO}/issues/new"
VERSION = re.compile(r"[A-Za-z0-9._+-]{1,40}")
OS = re.compile(r"[A-Za-z0-9._ +-]{1,40}")
COMPOSE = re.compile(r"[A-Za-z0-9._+-]{1,40}")
UNKNOWN = "unknown"
PUBLIC_WARNING = ("This opens GitHub with a public issue. Anyone can read it, so leave out keys, passwords, prompts, "
                  "file contents and repository or project names. Nothing leaves this computer until you submit it on GitHub.")


def _word(v, rx: re.Pattern) -> str:
    return v if isinstance(v, str) and rx.fullmatch(v) else UNKNOWN


def facts(status_dir: Path) -> dict:
    """The three facts, from ./stack's version.json (each checked; a missing one is "unknown")."""
    d = hostfiles.read_json(status_dir / "version.json", 64 * 1024)
    return {"version": _word(d.get("version"), VERSION), "os": _word(d.get("os"), OS), "compose": _word(d.get("compose"), COMPOSE)}


def link(kind: str, f: dict) -> str:
    template, title = KINDS[kind]
    q = {"template": template, "title": title, "version": f["version"], "os": f["os"], "compose": f["compose"]}
    return f"{ISSUES_NEW}?{urlencode(q)}"


def payload(status_dir: Path) -> dict:
    f = facts(status_dir)
    return {"repo": brand.REPO, "facts": f, "links": {k: link(k, f) for k in KINDS}, "public_warning": PUBLIC_WARNING}
