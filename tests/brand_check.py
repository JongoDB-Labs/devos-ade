#!/usr/bin/env python3
"""The old names where a person reads them: the product's, bedrock-now (bedrock now, bedrock_now, BedrockNow,
BEDROCK_NOW, in any case), and its Claude Code command's, claude-bedrock (now devos-claude; claude_bedrock,
ClaudeBedrock, CLAUDE_BEDROCK, in any case). Every occurrence in the repository's files outside the tests must be an
internal name — one an allowlist of docs/internal-names.md matches (a table for each old name, under its own heading: a
regular expression each, the old name inside what it matches, and the files it may match in) — or an exemption of
tests/fixtures/brand-allow.txt (a file, the text on its line that holds the old name, and why it stays). CHANGELOG.md's
entries of the releases before the rename are history (before v0.25.0 for bedrock-now, before v0.28.0 for
claude-bedrock): only its header and the entries from then on are read. docs/internal-names.md itself (the list of the
names that stay) is not read.

Usage: tests/brand_check.py [--root DIR] [PATH-PREFIX...]
  Prints each occurrence left (path:line: text) and exits 1 when there is one; with no PATH-PREFIX also each pattern
  and each exemption that no longer matches anything (stale). PATH-PREFIX limits the look to files under it.
       tests/brand_check.py --stdin LABEL < PAGE
  The same look at a text (a page the stack served: tests/e2e/upgrade.sh), with the patterns that may match anywhere.
  Exit status: 0 nothing left, 1 something left, 2 the check itself could not run.
Reads the files git knows of, and new ones it does not ignore (git ls-files --cached --others --exclude-standard).
"""

from __future__ import annotations

import fnmatch
import re
import subprocess
import sys
from pathlib import Path

# The guard's own files name the old spellings on purpose (the allowlist, the exemptions, the check, its test); the
# tests are read like any other file: what they assert is what ships.
DOC = "docs/internal-names.md"
ALLOW = "tests/fixtures/brand-allow.txt"
SELF = (DOC, ALLOW, "tests/brand_check.py", "tests/test_brand.sh", "tests/fixtures/internal-names.tsv")
# CHANGELOG.md is history for the product's old name (its entries name it as it was called); the Claude Code
# command's old name is read from v0.28.0 on, as before
HISTORY = {"bedrock-now": "CHANGELOG.md"}
# The Claude Code command's old name (claude-bedrock) is not read in the tests: their fixtures use it as an internal name
SKIP_CLAUDE = ("tests/", "portal/tests/", "code/test/", "code/web/test/", "code/web/e2e/", "portal/e2e/")
# A row of the allowlist table: | name | `pattern` | files | why | — files: globs (`lib/*.sh`, `compose*.yaml`, a
# comma between), or `*` for any file; a "|" of the pattern is written \| in the table
ROW = re.compile(r"^\|[^|]*\|\s*`((?:[^`\\]|\\.)+)`\s*\|\s*([^|]+?)\s*\|")
RELEASE = re.compile(r"^## \[(\d+)\.(\d+)\.(\d+)\]")


class Name:
    """An old name: how it is spelled (any case), the heading of its allowlist in docs/internal-names.md, and the
    release from which CHANGELOG.md is read for it (the entries before: history)."""

    def __init__(self, label: str, rx: str, heading: str, since: tuple[int, int, int]):
        self.label, self.rx, self.heading, self.since = label, re.compile(rx, re.I), heading, since


NAMES = (
    Name("bedrock-now", r"bedrock[-_ ]?now", "## The allowlist", (0, 25, 0)),
    Name("claude-bedrock", r"claude[-_ ]?bedrock", "## The allowlist of claude-bedrock", (0, 28, 0)),
)
OLD = NAMES[0].rx   # (the product's old name)


class Pattern:
    def __init__(self, rx: str, files: str):
        self.text = rx
        self.rx = re.compile(rx.replace("\\|", "|"))
        self.globs = [g.strip().strip("`") for g in files.split(",") if g.strip()]
        self.used = False

    def applies(self, path: str) -> bool:
        return any(g == "*" or fnmatch.fnmatchcase(path, g) for g in self.globs)


def patterns(root: Path) -> dict[str, list[Pattern]]:
    """Each old name's patterns: a table row belongs to the old name whose heading (a `## ` line) is the last one
    above it; rows above every such heading, to the first old name (bedrock-now)."""
    out: dict[str, list[Pattern]] = {n.label: [] for n in NAMES}
    name = NAMES[0].label
    for line in (root / DOC).read_text(encoding="utf-8").splitlines():
        for n in NAMES:
            if line.strip() == n.heading:
                name = n.label
        m = ROW.match(line)
        if m:
            out[name].append(Pattern(m.group(1), m.group(2)))
    if not out[NAMES[0].label]:
        raise SystemExit(f"{DOC}: no patterns found (a table row: | name | `pattern` | files | why |)")
    return out


def exemptions(root: Path) -> list[tuple[str, str, str]]:
    out = []
    for n, line in enumerate((root / ALLOW).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3 or not all(p.strip() for p in parts) or not any(o.rx.search(parts[1]) for o in NAMES):
            raise SystemExit(f"{ALLOW}:{n}: want PATH<TAB>TEXT WITH AN OLD NAME<TAB>WHY, got: {line!r}")
        out.append((parts[0], parts[1], parts[2]))
    return out


def files(root: Path) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                         capture_output=True, check=True).stdout
    return sorted({p for p in out.decode("utf-8", "surrogateescape").split("\0") if p})


def changelog_lines(lines: list[str], since: tuple[int, int, int] = NAMES[0].since) -> list[str]:
    """CHANGELOG.md's lines up to its first entry of a release before SINCE (the rest: blank)."""
    for i, line in enumerate(lines):
        m = RELEASE.match(line)
        if m and tuple(map(int, m.groups())) < since:
            return lines[:i] + [""] * (len(lines) - i)
    return lines


def spans(rx: re.Pattern, text: str) -> list[tuple[int, int]]:
    return [m.span() for m in rx.finditer(text)]


def uncovered(line: str, pats: list[Pattern], extra=(), old: re.Pattern = OLD) -> bool:
    """True when an occurrence of the old name OLD on LINE lies outside what the patterns (and the EXTRA spans)
    match; marks the patterns that covered one as used."""
    occ = spans(old, line)
    if not occ:
        return False
    covered = [(s, p) for p in pats for s in spans(p.rx, line)] + [(s, None) for s in extra]
    left = False
    for s, e in occ:
        hit = [p for (a, b), p in covered if a <= s and e <= b]
        left = left or not hit
        for p in hit:
            if p is not None:
                p.used = True
    return left


def check(root: Path, prefixes: list[str]) -> tuple[list[str], list[str]]:
    pats, allow = patterns(root), exemptions(root)
    used = [False] * len(allow)
    left = []
    for path in files(root):
        if path in SELF or (prefixes and not path.startswith(tuple(prefixes))):
            continue
        try:
            data = (root / path).read_bytes()
        except OSError:
            continue   # (listed but gone: a deleted file not yet staged)
        if b"\0" in data[:8192]:
            continue   # binary
        text = data.decode("utf-8", "replace").splitlines()
        for name in NAMES:
            if HISTORY.get(name.label) == path or (name.label == "claude-bedrock" and path.startswith(SKIP_CLAUDE)):
                continue
            lines = changelog_lines(text, name.since) if path == "CHANGELOG.md" else text
            mine = [(i, a) for i, a in enumerate(allow) if a[0] == path and name.rx.search(a[1])]
            here = [p for p in pats[name.label] if p.applies(path)]
            for n, line in enumerate(lines, 1):
                if not name.rx.search(line):
                    continue
                extra = []
                for i, (_, t, _) in mine:
                    at = [(m.start(), m.start() + len(t)) for m in re.finditer(re.escape(t), line)]
                    if at:
                        used[i] = True
                        extra += at
                if uncovered(line, here, extra, name.rx):
                    left.append(f"{path}:{n}: {line.strip()[:200]}")
    stale = [f"{ALLOW}: {p}\t{t}" for (p, t, _), u in zip(allow, used) if not u and (not prefixes or p.startswith(tuple(prefixes)))]
    if not prefixes:
        # (a pattern for files that are not in the tree — another branch's, not merged yet — cannot be stale)
        tree = files(root)
        stale += [f"{DOC}: the pattern `{p.text}`" for n in NAMES for p in pats[n.label]
                  if not p.used and any(p.applies(f) for f in tree)]
    return sorted(set(left), key=left.index), stale


def check_text(root: Path, label: str, text: str) -> list[str]:
    pats = patterns(root)
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if any(uncovered(line, [p for p in pats[o.label] if "*" in p.globs], (), o.rx) for o in NAMES):
            out.append(f"{label}:{n}: {line.strip()[:200]}")
    return out


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parent.parent
    if argv[:1] == ["--root"]:
        root, argv = Path(argv[1]).resolve(), argv[2:]
    if argv[:1] == ["--stdin"] and len(argv) == 2:
        left = check_text(root, argv[1], sys.stdin.read())
        if left:
            print("\n".join(left))
        return 1 if left else 0
    left, stale = check(root, argv)
    for line in left:
        print(line)
    for line in stale:
        print(f"stale (matches nothing): {line}")
    if left or stale:
        print(f"{len(left)} occurrence(s) of an old name left, {len(stale)} stale pattern(s) or exemption(s): change "
              f"the text to DevOS ADE (bedrock-now) or devos-claude (claude-bedrock), or — for an internal name — add a "
              f"pattern to {DOC} or an exemption to {ALLOW}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit as e:
        # (a malformed allowlist: the check could not run — never "nothing left")
        sys.exit(e.code if isinstance(e.code, int) else (print(e.code, file=sys.stderr) or 2))
    except Exception as e:  # noqa: BLE001
        print(f"brand_check: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
