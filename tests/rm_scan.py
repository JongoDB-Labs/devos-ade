"""Finds file removals that take an unquoted expansion ($X, ${X}, $(…), `…`) in shell scripts: such an argument is split
on spaces and globbed, so a path with a space in it (a checkout under "Code Projects") names other files — the review
of v0.27.0 found a trap that removed a sibling folder that way. What it flags:
- `rm` — also as `\\rm`, `/bin/rm`, `/usr/bin/rm` or `env … rm` — with an unquoted expansion among its arguments;
- `xargs … rm` without -0 or -d (xargs splits its input on blanks and reads quotes in it);
- `find` whose first path is an unquoted expansion when the command removes (`-delete`, `-exec rm`);
- the same inside the string given to `eval`, `sh -c` or `bash -c`: a double-quoted one is expanded before it is read
  again as code, so a `$x` in it is unquoted there; a single-quoted one is code as it stands.
Quoted arguments ("$x", "${x:-}") are fine; $$, $!, $? and $# are numbers. Comments, quoted text (messages that mention
`docker volume rm $vols`) and here-documents are not code; the strings given to `trap` are (single-quoted: run as they
are; double-quoted: only their \\$ escapes are expanded when they run). `docker … rm` and the like are other commands.

Usage: python3 -I tests/rm_scan.py FILE... -> one "FILE:LINE: TEXT" per finding; exit 1 when there is any.
"""

import re
import sys

PREFIXES = {"then", "do", "else", "elif", "if", "while", "until", "!", "exec", "command", "sudo", "nohup", "time", "{", "}"}
RM_NAMES = {"rm", "\\rm", "/bin/rm", "/usr/bin/rm"}
SAFE_SPECIALS = ("$$", "$!", "$?", "$#")


def _strings(code, line, pattern):
    """The bodies of the quoted strings that follow PATTERN in LINE (found in its masked CODE): [(quote, body)]."""
    out = []
    for m in re.finditer(pattern, code):
        q, start = m.group("q"), m.end()
        end = line.find(q, start)
        while q == '"' and end > 0 and line[end - 1] == "\\":
            end = line.find(q, end + 1)
        if end > start:
            out.append((q, line[start:end]))
    return out


def mask(line, state):
    """LINE with quoted text masked (each char of it as x, the quotes kept), comments cut; STATE: the quote open at its
    start (None, "'", '"'), returned for the next line. Also the code in it as strings: [(kind, body)] — trap bodies,
    and eval / sh -c / bash -c bodies."""
    out, quote, i = [], state, 0
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
    inner = []
    for q, body in _strings(code, line, r"(?:^|[\s;&|(])trap\s+(?P<q>['\"])"):
        if q == '"':
            # (expanded when the trap is set: only an escaped \$ is expanded when it runs)
            body = re.sub(r"(?<!\\)\$(\{[^}]*\}|\([^)]*\)|\w+)", "SET", body).replace("\\$", "$")
        inner.append(("trap", body))
    for q, body in _strings(code, line, r"(?:^|[\s;&|(])(?:eval|(?:ba)?sh\s+-c)\s+(?P<q>['\"])"):
        if q == '"':
            # (expanded first, then read as code: a $x of it is unquoted there)
            body = body.replace('\\"', '"').replace("\\$", "$").replace("\\\\", "\\")
        inner.append(("eval", body))
    return code, quote, inner


def _command(words):
    """WORDS without what goes before a command's name: keywords, assignments, `env` and its options."""
    words = list(words)
    while words:
        if words[0] in PREFIXES or re.fullmatch(r"\w+=\S*", words[0]):
            words.pop(0)
        elif words[0] == "env":
            words.pop(0)
            while words and (words[0].startswith("-") or re.fullmatch(r"\w+=\S*", words[0])):
                if words.pop(0) in ("-u", "--unset") and words:
                    words.pop(0)
        else:
            break
    return words


def _unquoted(word):
    rest = word
    for s in SAFE_SPECIALS:
        rest = rest.replace(s, "")
    return "$" in rest


def findings(code):
    """The removals of masked CODE that take an unquoted expansion (see the module's doc)."""
    out = []
    for seg in re.split(r"&&|\|\||[;|()`]", code):
        words = _command(seg.split())
        if not words:
            continue
        name = words[0]
        if name in RM_NAMES:
            if any(_unquoted(w) for w in words[1:]):
                out.append(seg.strip())
        elif name == "xargs":
            at = next((i for i, w in enumerate(words) if i and w in RM_NAMES), None)
            if at is not None:
                opts = words[1:at]
                if not any(o in ("--null", "--delimiter") or o.startswith("--delimiter=") or re.fullmatch(r"-[A-Za-z]*[0d][A-Za-z]*\S*", o)
                           for o in opts):
                    out.append(seg.strip() + "   (xargs … rm without -0 or -d)")
        elif name == "find":
            rest = words[1:]
            while rest and rest[0] in ("-H", "-L", "-P"):
                rest.pop(0)
            path = rest[0] if rest else ""
            removes = "-delete" in rest or any(w == "-exec" and i + 1 < len(rest) and rest[i + 1] in RM_NAMES for i, w in enumerate(rest))
            if removes and path and not path.startswith(("'", '"')) and _unquoted(path):
                out.append(seg.strip() + "   (find with an unquoted path, removing)")
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
        code, state, inner = mask(line, state)
        for hit in findings(code):
            hits.append(f"{path}:{start}: {hit}")
        for kind, body in inner:
            icode, _, _ = mask(body, None)
            for hit in findings(icode):
                hits.append(f"{path}:{start}: {kind}: {hit}")
        m = re.search(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", code)   # (not <<<, a here-string)
        if m and state is None:
            heredoc = m.group(2)
    return hits


if __name__ == "__main__":
    found = [h for p in sys.argv[1:] for h in scan(p)]
    print("\n".join(found))
    sys.exit(1 if found else 0)
