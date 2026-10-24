"""Vendor the Python runner's packages into Open WebUI's image (run once, at build time: open-webui/Dockerfile).

Open WebUI's Python runner (Pyodide, in a sandboxed frame of Chat's page) loads every package from the URL its
pyodide-lock.json names: Pyodide's CDN, which Chat's page never reaches (its policy allows requests to itself only).
This puts the wheels of the packages listed in packages.txt — with their dependencies, from the lock's own
`depends` — next to Pyodide's runtime in /app/build/pyodide/, and points the lock at them by their bare file name
(relative to the runner's indexURL, /pyodide/). Every other package keeps its CDN URL: importing it fails, cleanly.

Nothing is pinned here: the image (its digest, in compose.yaml and the Dockerfile) pins the lock, and the lock pins
each wheel by its sha256. A wheel that cannot be downloaded or does not match is left out, and so is every package
that needs it: the lock keeps their CDN URLs, the build goes on (an offline build gives a working image without them),
and the reason is printed and written to vendored.json (./stack status says it). Nothing downloaded is run: wheels
are bytes put in a folder, for the browser.

Bounds: https URLs only, and a redirect only to https on the same host; DOWNLOAD_TIMEOUT_S for each network
operation and DOWNLOAD_DEADLINE_S for a whole download; FILE_MAX each, TOTAL_MAX in all; a plain file name (NAME),
never one of the folder's own files nor one two packages of the lock name (each left out); downloads go to a temp
folder of their own, and only the folder's wheels and the lock are written there — vendored.json and vendored.txt
(the same, a line a package, for ./stack status) in REPORT_DIR (the Dockerfile's: outside what Open WebUI serves).

Usage: python3 -I vendor.py PYODIDE_DIR PACKAGES_FILE [REPORT_DIR]
"""
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

DOWNLOAD_TIMEOUT_S = 60
DOWNLOAD_DEADLINE_S = 300
FILE_MAX = 40 << 20
TOTAL_MAX = 120 << 20
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,200}\.(whl|zip|tar)$")
SHA = re.compile(r"^[0-9a-f]{64}$")
PKG = re.compile(r"^[a-z0-9][a-z0-9._-]{0,100}$")


def wanted(text):
    """The names in packages.txt: one a line, # comments and blank lines left out, lower case."""
    out = []
    for line in text.splitlines():
        name = line.split("#", 1)[0].strip().lower()
        if name and PKG.match(name) and name not in out:
            out.append(name)
    return out


def closure(packages, names):
    """(order, missing): every package the names need, dependencies first, each once; names the lock lacks."""
    order, missing, seen = [], [], set()

    def visit(name, depth):
        name = name.lower()
        if name in seen:
            return
        seen.add(name)
        p = packages.get(name)
        if not isinstance(p, dict) or depth > 50:
            missing.append(name)
            return
        for dep in p.get("depends") or []:
            if isinstance(dep, str):
                visit(dep, depth + 1)
        order.append(name)

    for n in names:
        visit(n, 0)
    return order, missing


def _origin(url):
    u = urllib.parse.urlsplit(url)
    return (u.scheme, (u.hostname or "").lower(), u.port or 443)


class _SameHost(urllib.request.HTTPRedirectHandler):
    """Redirects only to https on the host the lock named (its port too): anything else is a failed download."""

    def __init__(self, origin):
        super().__init__()
        self.origin = origin

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if _origin(urllib.parse.urljoin(req.full_url, newurl)) != self.origin:
            raise urllib.error.HTTPError(req.full_url, code, "a redirect away from the lock's https host", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_url(url, limit, deadline_s=DOWNLOAD_DEADLINE_S):
    """The bytes at an https URL, at most limit of them (more: an error), each network operation within
    DOWNLOAD_TIMEOUT_S and the whole within deadline_s; redirects only to https on the same host."""
    origin = _origin(url)
    if origin[0] != "https" or not origin[1]:
        raise ValueError("not an https URL")
    end = time.monotonic() + deadline_s
    opener = urllib.request.build_opener(_SameHost(origin))
    with opener.open(url, timeout=DOWNLOAD_TIMEOUT_S) as r:
        chunks, size = [], 0
        while True:
            if time.monotonic() > end:
                raise TimeoutError(f"not done within {deadline_s} s")
            b = r.read(1 << 16)
            if not b:
                break
            size += len(b)
            if size > limit:
                raise ValueError(f"larger than {limit >> 20} MiB")
            chunks.append(b)
        return b"".join(chunks)


def vendor(lock, names, dest, fetch=None, tmp=None):
    """(lock, report): the lock with the vendored packages' file_name made relative, and what was done — each wheel
    downloaded into tmp, checked against the lock's sha256, then moved into dest; a package is vendored only when
    every package it needs is too (else it is left out, its wheel removed, and the lock keeps its CDN URL)."""
    fetch = fetch or fetch_url
    packages = lock.get("packages") if isinstance(lock, dict) else None
    if not isinstance(packages, dict):
        return lock, {"ready": [], "left_out": [{"name": n, "why": "the image's pyodide-lock.json has no packages"} for n in names], "bytes": 0}
    order, missing = closure(packages, names)
    own = set(os.listdir(dest))
    got, why, total = {}, {n: "not in the image's pyodide-lock.json" for n in missing}, 0
    base_of = lambda p: os.path.basename(urllib.parse.urlsplit(p.get("file_name")).path) if isinstance(p, dict) and isinstance(p.get("file_name"), str) else ""  # noqa: E731
    # (a file name two packages of the lock name: neither is vendored — one would take the other's place)
    uses = {}
    for p in packages.values():
        b = base_of(p)
        if b:
            uses[b] = uses.get(b, 0) + 1
    for name in order:
        p = packages[name]
        url, sha = p.get("file_name"), p.get("sha256")
        base = base_of(p)
        if not isinstance(sha, str) or not SHA.match(sha):
            why[name] = "no sha256 in the lock"
            continue
        if not NAME.match(base):
            why[name] = "its file name in the lock is not a plain wheel name"
            continue
        if base in own:
            why[name] = "its file name is one of the runtime's own files"
            continue
        if uses.get(base, 0) > 1:
            why[name] = "its file name is another package's in the lock too"
            continue
        try:
            b = fetch(url, min(FILE_MAX, TOTAL_MAX - total))
        except Exception as e:  # noqa: BLE001 — any failure leaves it out, said
            why[name] = f"download failed ({type(e).__name__}: {plain(str(e), 120)})"
            continue
        if hashlib.sha256(b).hexdigest() != sha:
            why[name] = "its sha256 does not match the lock's"
            continue
        total += len(b)
        path = os.path.join(tmp, base)
        with open(path, "wb") as f:
            f.write(b)
        got[name] = (base, len(b))
    # (a package whose dependencies are not all here would load them from the CDN: left out too)
    ready = []
    for name in order:
        if name not in got:
            continue
        need, absent = closure(packages, [name])
        lacking = [d for d in need if d != name and d not in got] + absent
        if lacking:
            why[name] = "needs " + ", ".join(sorted(lacking)) + ", left out"
            continue
        ready.append(name)
    out = json.loads(json.dumps(lock))
    for name in ready:
        base, _ = got[name]
        shutil.move(os.path.join(tmp, base), os.path.join(dest, base))
        out["packages"][name]["file_name"] = base
    report = {"ready": [{"name": n, "file": got[n][0], "bytes": got[n][1]} for n in ready],
              "left_out": [{"name": n, "why": why[n]} for n in sorted(why)], "bytes": sum(got[n][1] for n in ready)}
    return out, report


def plain(text, n):
    """printable ASCII, at most n characters (what goes into vendored.txt's tab-separated lines and the log)"""
    return re.sub(r"[^ -~]", " ", str(text)).replace("\t", " ")[:n]


def summary(report):
    """vendored.txt: a line a package — ready<TAB>name<TAB>bytes, left<TAB>name<TAB>why — for ./stack status"""
    lines = [f"ready\t{plain(r['name'], 100)}\t{int(r['bytes'])}" for r in report["ready"]]
    lines += [f"left\t{plain(x['name'], 100)}\t{plain(x['why'], 200)}" for x in report["left_out"]]
    return "".join(line + "\n" for line in lines)


def write(dest, name, text):
    path = os.path.join(dest, name)
    tmpf = path + ".bn-new"
    with open(tmpf, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmpf, path)


def main(argv):
    dest, listfile = argv[1], argv[2]
    # (what was done: beside the wheels only when no folder of its own is named — Open WebUI serves dest)
    report_dir = argv[3] if len(argv) > 3 else dest
    os.makedirs(report_dir, mode=0o755, exist_ok=True)
    names = wanted(open(listfile, encoding="utf-8").read())
    lockpath = os.path.join(dest, "pyodide-lock.json")
    try:
        lock = json.load(open(lockpath, encoding="utf-8"))
    except (OSError, ValueError) as e:
        lock = None
        print(f"vendor: no readable pyodide-lock.json ({type(e).__name__}): nothing vendored", flush=True)
    tmp = tempfile.mkdtemp(prefix="bn-pyodide-")
    try:
        new, report = vendor(lock, names, dest, tmp=tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if lock is not None and report["ready"]:
        write(dest, "pyodide-lock.json", json.dumps(new, separators=(",", ":")))
    report = {"version": 1, "pyodide": (lock or {}).get("info") if isinstance(lock, dict) else None, **report}
    write(report_dir, "vendored.json", json.dumps(report, indent=1) + "\n")
    write(report_dir, "vendored.txt", summary(report))
    print(f"vendor: {len(report['ready'])} package(s) ready ({report['bytes'] / 1e6:.1f} MB): "
          + (", ".join(r["name"] for r in report["ready"]) or "none"), flush=True)
    for x in report["left_out"]:
        print(f"vendor: left out {x['name']}: {x['why']}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
