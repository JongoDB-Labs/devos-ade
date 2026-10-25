"""Finds `rm` commands that take an unquoted expansion ($X, ${X}, $(…), `…`) in shell scripts: such an argument is split
on spaces and globbed, so a path with a space in it (a checkout under "Code Projects") names other files — the review
of v0.27.0 found a trap that removed a sibling folder that way. Quoted arguments ("$x", "${x:-}") are fine; $$, $!, $?
and $# are numbers. Comments, quoted text (messages that mention `docker volume rm $vols`) and here-documents are not
code; the strings given to `trap` are (single-quoted: run as they are; double-quoted: their \\$ escapes run later).
`docker … rm` and the like are other commands, not file removal.

Usage: python3 -I tests/rm_scan.py FILE... -> one "FILE:LINE: TEXT" per finding; exit 1 when there is any.
"""

import re
import sys

PREFIXES = {"then", "do", "else", "elif", "if", "while", "until", "!", "exec", "command", "sudo", "nohup", "time", "{", "}"}
SAFE_SPECIALS = ("$$", "$!", "$?", "$#")


def mask(line, state):
    """LINE with quoted text masked (each char of it as x, the quotes kept), comments cut; STATE: the quote open at its
    start (None, "'", '"'), returned for the next line. Also the bodies of trap strings found in it."""
    out, quote, i, traps = [], state, 0, []
    while i < len(line):
        c = line[i]
        if quote == "'":
            if c == "'":
                quote = None
                out.append(c)
            else:
                out.append("x")
        elif quote == '"':
            if c == "\\" and i + 1 < len(line):
                out.append("xx")
                i += 1
            elif c == '"':
                quote = None
                out.append(c)
            else:
                out.append("x")
        else:
            if c == "#" and (i == 0 or line[i - 1] in " \t;&|("):
                break
            if c == "\\" and i + 1 < len(line):
                out.append(line[i:i + 2])
                i += 1
            elif c in "'\"":
                quote = c
                out.append(c)
            else:
                out.append(c)
        i += 1
    code = "".join(out)
    for m in re.finditer(r"(?:^|[\s;&|(])trap\s+(['\"])", code):
        q, start = m.group(1), m.end()
        end = line.find(q, start)
        while q == '"' and end > 0 and line[end - 1] == "\\":
            end = line.find(q, end + 1)
        if end > start:
            body = line[start:end]
            if q == '"':
                # (expanded when the trap is set: only an escaped \$ is expanded when it runs)
                body = re.sub(r"(?<!\\)\$(\{[^}]*\}|\([^)]*\)|\w+)", "SET", body).replace("\\$", "$")
            traps.append(body)
    return code, quote, traps


def findings(code):
    """The rm commands of masked CODE that take an unquoted expansion."""
    out = []
    for seg in re.split(r"&&|\|\||[;|()`]", code):
        words = seg.split()
        while words and (words[0] in PREFIXES or re.fullmatch(r"\w+=\S*", words[0])):
            words.pop(0)
        if not words or words[0] != "rm":
            continue
        for w in words[1:]:
            rest = w
            for s in SAFE_SPECIALS:
                rest = rest.replace(s, "")
            if "$" in rest:
                out.append(seg.strip())
                break
    return out


def scan(path):
    hits = []
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    state, heredoc, n, pending, start = None, None, 0, "", 0
    for raw in lines:
        n += 1
        if heredoc:
            if raw.lstrip("\t") == heredoc:
                heredoc = None
            continue
        if not pending:
            start = n
        if raw.endswith("\\") and state is None:
            pending += raw[:-1] + " "
            continue
        line, pending = pending + raw, ""
        code, state, traps = mask(line, state)
        for hit in findings(code):
            hits.append(f"{path}:{start}: {hit}")
        for body in traps:
            tcode, _, _ = mask(body, None)
            for hit in findings(tcode):
                hits.append(f"{path}:{start}: trap: {hit}")
        m = re.search(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", code)   # (not <<<, a here-string)
        if m and state is None:
            heredoc = m.group(2)
    return hits


if __name__ == "__main__":
    found = [h for p in sys.argv[1:] for h in scan(p)]
    print("\n".join(found))
    sys.exit(1 if found else 0)
