"""lib/hf_fetch.py REPO SHA HUB MANIFEST — a Hugging Face model repo's files at one commit, into the Hugging Face cache
layout (HUB/models--org--name/blobs and snapshots/SHA), where mlx_lm.server finds it offline. lib/local_models.sh uses it
for MLX downloads instead of `hf download`, which deletes a file's unfinished part whenever it stops (huggingface_hub 2.x
names it per process). Here a file downloads into blobs/<etag>.part, a name that stays the same, so a stopped download
(Pause, a crash, a dropped connection) continues where it stopped.

MANIFEST: one line per file, path TAB size TAB sha256 (a large, LFS file) TAB git blob id, written by the vet
(lib/local_models.sh _local_mlx_vet) from the Hub's answer for SHA. Each finished file is checked against it (its size, and
its SHA-256, or its git blob id for a small file); one that does not match is deleted and the download fails.

curl does the transfers: the system's TLS and certificates, a resume at the part's size, and a connection that stalls for
a minute dropped and tried again. The token (HF_TOKEN) reaches curl on stdin as a header, never on a command line, and curl
never sends it on to the host a download redirects to (the Hub's CDN). HF_ENDPOINT (default https://huggingface.co) is the
Hub, as for huggingface_hub; HF_FETCH_WORKERS files at a time (default 4). Standard library only: run with python3 -I.
A dropped connection is tried again by itself, from where it stopped; a refusal (HTTP 401 or 403: a gated or private
model, and no token that can see it) or a file the commit no longer has (404) is not, as trying again cannot change it.
Exit: 0 done, 1 failed, 3 Hugging Face refused a file (why: the last line on stderr, either), 143 stopped by SIGTERM or
SIGINT (the parts are kept).
"""

from __future__ import annotations

import hashlib
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, wait

ENDPOINT = (os.environ.get("HF_ENDPOINT") or "https://huggingface.co").rstrip("/")
WORKERS = max(1, min(8, int(os.environ.get("HF_FETCH_WORKERS") or 4)))
TRIES = 8              # attempts in a row that add nothing before a file's download fails
SPARE = 512 * 1024**2  # free disk kept beyond what the download still needs
WHY = {6: "the Hub's name did not resolve: is this computer online?", 7: "could not connect to the Hub",
       18: "the connection kept dropping", 28: "the connection timed out", 35: "the secure connection failed",
       56: "the connection kept dropping", 92: "the connection kept dropping"}   # (curl's exit codes, in words)
ETAG = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}")

stopping = threading.Event()
_procs: set = set()
_lock = threading.Lock()


class Failed(Exception):
    pass


class Refused(Failed):
    pass


def _stop(_sig, _frame):
    stopping.set()
    with _lock:
        for p in list(_procs):
            try:
                p.terminate()
            except OSError:
                pass


def _size(p: str) -> int:
    try:
        return os.path.getsize(p)
    except OSError:
        return 0


def read_manifest(path: str) -> list:
    """-> [(path, size, sha256, blob)]; a path that could leave the snapshot, or an etag that is not one, refuses it all"""
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            name, size, sha256, blob = (line.split("\t") + ["", "", ""])[:4]
            parts = name.split("/")
            if not name or name.startswith("/") or "\\" in name or "\0" in name or any(p in ("", ".", "..") for p in parts):
                raise Failed(f"the file list names a path that is not allowed: {name[:80]!r}")
            if not size.isdigit() or not (ETAG.fullmatch(sha256) if sha256 else ETAG.fullmatch(blob)):
                raise Failed(f"the file list does not describe {name[:80]!r} (size and hash)")
            rows.append((name, int(size), sha256, blob))
    if not rows:
        raise Failed("the file list is empty")
    return rows


def verify(part: str, size: int, sha256: str, blob: str) -> bool:
    """the size, and the SHA-256 (LFS) or the git blob id (sha1 of "blob <size>\\0" and the content)"""
    if _size(part) != size:
        return False
    h = hashlib.sha256() if sha256 else hashlib.sha1(b"blob %d\0" % size)
    with open(part, "rb") as f:
        while chunk := f.read(8 * 1024 * 1024):
            if stopping.is_set():
                raise Failed("stopped")
            h.update(chunk)
    return h.hexdigest() == (sha256 or blob)


def link(snap: str, name: str, dest: str) -> None:
    """snapshots/SHA/<name> -> the blob, relative, as huggingface_hub lays it out (replaced atomically)"""
    path = os.path.join(snap, *name.split("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rel = os.path.relpath(dest, os.path.dirname(path))
    tmp = f"{path}.{os.getpid()}.lnk"
    try:
        os.remove(tmp)
    except FileNotFoundError:
        pass
    os.symlink(rel, tmp)
    os.replace(tmp, path)


def curl(url: str, part: str, have: int, token: str) -> tuple:
    """-> (curl's exit code, the HTTP status of the last answer, 0 for none)"""
    args = ["curl", "-q", "-sS", "-f", "-L", "--max-redirs", "5", "--connect-timeout", "30",
            "--speed-limit", "1024", "--speed-time", "60", "-H", "@-", "-o", part, "-w", "%{http_code}"]
    if url.startswith("https://"):
        args[1:1] = ["--proto", "=https", "--proto-redir", "=https"]
    if have:
        args += ["-C", str(have)]
    p = subprocess.Popen(args + [url], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with _lock:
        _procs.add(p)
    if stopping.is_set():
        p.terminate()
    try:
        out, err = p.communicate((f"Authorization: Bearer {token}\n" if token else "").encode())
    finally:
        with _lock:
            _procs.discard(p)
    if p.returncode and not stopping.is_set():
        sys.stderr.write(err.decode("utf-8", "replace")[-300:])
    code = out.decode("ascii", "replace").strip()[-3:]
    return p.returncode, int(code) if code.isdigit() else 0


def fetch(repo: str, sha: str, blobs: str, snap: str, row: tuple, token: str) -> None:
    name, size, sha256, blob = row
    dest = os.path.join(blobs, sha256 or blob)
    if _size(dest) == size and os.path.isfile(dest):   # (a blob is renamed into place only once checked)
        link(snap, name, dest)
        return
    part = dest + ".part"
    url = f"{ENDPOINT}/{repo}/resolve/{sha}/{urllib.parse.quote(name)}"
    idle, rc, code = 0, 0, 0
    while True:
        if stopping.is_set():
            return
        have = _size(part)
        if have > size:                        # (not this file: start it again)
            os.remove(part)
            have = 0
        if have < size or not os.path.exists(part):
            if size == 0:
                open(part, "wb").close()
            else:
                rc, code = curl(url, part, have, token)
                if code in (401, 403):
                    raise Refused(f"Hugging Face refused {name} (HTTP {code})")
                if code == 404:
                    raise Failed(f"Hugging Face no longer has {name} at the commit that was checked (HTTP 404)")
                if rc == 33:                   # (the server would not resume: start the file again)
                    os.remove(part)
        if stopping.is_set():
            return
        now = _size(part)
        if now >= size and os.path.exists(part):
            break
        idle = 0 if now > have else idle + 1
        if idle >= TRIES:
            why = f"Hugging Face answered HTTP {code}" if rc == 22 and code else WHY.get(rc)
            raise Failed(f"{name}: no progress after {TRIES} tries ({why + ', ' if why else ''}curl exit {rc})")
        for _ in range(min(30, 2 ** idle) * 10):
            if stopping.is_set():
                return
            time.sleep(0.1)
    if not verify(part, size, sha256, blob):
        os.remove(part)
        raise Failed(f"{name}: what arrived does not match the hash Hugging Face gives for it, so it was deleted")
    os.replace(part, dest)
    link(snap, name, dest)


def main(argv: list) -> int:
    if len(argv) != 5:
        sys.stderr.write("usage: hf_fetch.py REPO SHA HUB MANIFEST\n")
        return 2
    repo, sha, hub, manifest = argv[1:]
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        if not REPO.fullmatch(repo) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise Failed("not a repo and commit")
        rows = read_manifest(manifest)
        root = os.path.join(hub, "models--" + repo.replace("/", "--"))
        blobs, snap = os.path.join(root, "blobs"), os.path.join(root, "snapshots", sha)
        os.makedirs(blobs, exist_ok=True)
        os.makedirs(snap, exist_ok=True)
        left = sum(max(0, s - _size(os.path.join(blobs, (h or b) + ".part"))) for _, s, h, b in rows
                   if _size(os.path.join(blobs, h or b)) != s)
        st = os.statvfs(blobs)
        if st.f_bavail * st.f_frsize < left + SPARE:
            raise Failed(f"not enough free disk: it needs {left / 1024**3:.1f} GB more, and {st.f_bavail * st.f_frsize / 1024**3:.1f} GB is free")
        token = os.environ.get("HF_TOKEN", "")
        failure = None
        with ThreadPoolExecutor(WORKERS) as pool:   # (small files first: the config and tokenizer are there in seconds)
            pending = {pool.submit(fetch, repo, sha, blobs, snap, r, token) for r in sorted(rows, key=lambda r: r[1])}
            while pending:
                done, pending = wait(pending, timeout=0.5)
                for f in done:
                    e = f.exception()
                    if e is not None and failure is None and str(e) != "stopped":
                        failure = e
                        _stop(None, None)   # (one file failing fails the download: the others stop, their parts kept)
        if failure is not None:
            raise failure if isinstance(failure, Failed) else Failed(f"{type(failure).__name__}: {failure}")
        if stopping.is_set():
            return 143
    except Failed as e:
        sys.stderr.write(f"\n{e}\n")
        return 143 if str(e) == "stopped" else 3 if isinstance(e, Refused) else 1
    except OSError as e:
        sys.stderr.write(f"\n{e.strerror or e}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
