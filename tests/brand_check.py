#!/usr/bin/env python3
"""The product's old name where a person reads it: every occurrence of bedrock-now (bedrock now, bedrock_now,
BedrockNow, BEDROCK_NOW, in any case) in the repository's files outside the tests must be an internal name — one the
allowlist of docs/internal-names.md matches (its table's Pattern column: a regular expression each, the old name
inside what it matches) — or an exemption of tests/fixtures/brand-allow.txt (a file, the text on its line that holds
the old name, and why it stays). CHANGELOG.md's entries before v0.25.0 are history: only its header and the entries
from v0.25.0 on are read. docs/internal-names.md itself (the list of the names that stay) is not read.

Usage: tests/brand_check.py [--root DIR] [PATH-PREFIX...]
  Prints each occurrence left (path:line: text) and exits 1 when there is one; with no PATH-PREFIX also each
  exemption that no longer matches anything (stale). PATH-PREFIX limits the look to files under it (a surface).
       tests/brand_check.py --stdin LABEL < PAGE
  The same look at a text (a page the stack served: tests/e2e/upgrade.sh), with the patterns only.
Reads the files git knows of, and new ones it does not ignore (git ls-files --cached --others --exclude-standard).
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

OLD = re.compile(r"bedrock[-_ ]?now", re.I)
# The tests: their fixtures are internal names, and what they assert is checked where it is shown.
SKIP = ("tests/", "portal/tests/", "code/test/", "code/web/test/", "code/web/e2e/", "portal/e2e/")
DOC = "docs/internal-names.md"
ALLOW = "tests/fixtures/brand-allow.txt"
# A row of the allowlist table: | name | `pattern` | why | (a "|" of the pattern written \| in the table)
ROW = re.compile(r"^\|[^|]*\|\s*`([^`]+)`\s*\|")
RELEASE = re.compile(r"^## \[(\d+)\.(\d+)\.(\d+)\]")


def patterns(root: Path) -> list[re.Pattern]:
    out = []
    for line in (root / DOC).read_text(encoding="utf-8").splitlines():
        m = ROW.match(line)
        if m:
            out.append(re.compile(m.group(1).replace("\\|", "|")))
    if not out:
        raise SystemExit(f"{DOC}: no patterns found (a table row: | name | `pattern` | why |)")
    return out


def exemptions(root: Path) -> list[tuple[str, str, str]]:
    out = []
    for n, line in enumerate((root / ALLOW).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3 or not all(p.strip() for p in parts) or not OLD.search(parts[1]):
            raise SystemExit(f"{ALLOW}:{n}: want PATH<TAB>TEXT WITH THE OLD NAME<TAB>WHY, got: {line!r}")
        out.append((parts[0], parts[1], parts[2]))
    return out


def files(root: Path) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                         capture_output=True, check=True).stdout
    return sorted({p for p in out.decode("utf-8", "surrogateescape").split("\0") if p})


def changelog_lines(lines: list[str]) -> list[str]:
    """CHANGELOG.md's lines up to its first entry of a release before v0.25.0 (the rest: blank)."""
    for i, line in enumerate(lines):
        m = RELEASE.match(line)
        if m and tuple(map(int, m.groups())) < (0, 25, 0):
            return lines[:i] + [""] * (len(lines) - i)
    return lines


def spans(rx: re.Pattern, text: str) -> list[tuple[int, int]]:
    return [m.span() for m in rx.finditer(text)]


def check(root: Path, prefixes: list[str]) -> tuple[list[str], list[str]]:
    pats, allow = patterns(root), exemptions(root)
    used = [False] * len(allow)
    left = []
    for path in files(root):
        if path.startswith(SKIP) or path == DOC or (prefixes and not path.startswith(tuple(prefixes))):
            continue
        f = root / path
        try:
            data = f.read_bytes()
        except OSError:
            continue   # (listed but gone: a deleted file not yet staged)
        if b"\0" in data[:8192]:
            continue   # binary
        lines = data.decode("utf-8", "replace").splitlines()
        if path == "CHANGELOG.md":
            lines = changelog_lines(lines)
        mine = [(i, a) for i, a in enumerate(allow) if a[0] == path]
        for n, line in enumerate(lines, 1):
            occ = spans(OLD, line)
            if not occ:
                continue
            covered = [s for p in pats for s in spans(p, line)]
            for i, (_, text, _) in mine:
                at = [(m.start(), m.start() + len(text)) for m in re.finditer(re.escape(text), line)]
                if at:
                    used[i] = True
                    covered += at
            if any(not any(a <= s and e <= b for a, b in covered) for s, e in occ):
                left.append(f"{path}:{n}: {line.strip()[:200]}")
    stale = [f"{ALLOW}: {p}\t{t}" for (p, t, _), u in zip(allow, used) if not u and (not prefixes or p.startswith(tuple(prefixes)))]
    return left, stale


def check_text(root: Path, label: str, text: str) -> list[str]:
    pats = patterns(root)
    left = []
    for n, line in enumerate(text.splitlines(), 1):
        covered = [s for p in pats for s in spans(p, line)]
        if any(not any(a <= s and e <= b for a, b in covered) for s, e in spans(OLD, line)):
            left.append(f"{label}:{n}: {line.strip()[:200]}")
    return left


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parent.parent
    if argv[:1] == ["--root"]:
        root, argv = Path(argv[1]).resolve(), argv[2:]
    if argv[:1] == ["--stdin"] and len(argv) == 2:
        left = check_text(root, argv[1], sys.stdin.read())
        print("\n".join(left)) if left else None
        return 1 if left else 0
    left, stale = check(root, argv)
    for line in left:
        print(line)
    for line in stale if not argv else []:
        print(f"stale exemption (matches nothing): {line}")
    if left or (stale and not argv):
        print(f"{len(left)} occurrence(s) of the old name left, {len(stale)} stale exemption(s): change the text to "
              f"DevOS ADE, or — for an internal name — add a pattern to {DOC} or an exemption to {ALLOW}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
