"""Shared plumbing for the e2e browser suite: the throwaway's settings, secret redaction, raw HTTP through Caddy,
check registration and results. Runs inside the Playwright container (tests/e2e/browser.sh)."""

from __future__ import annotations

import http.client as httpclient
import json
import os
import re
import socket
import time
import traceback
from pathlib import Path
from urllib.parse import urlsplit

OUT = Path("/out")
SHOTS = OUT / "shots"
NET = OUT / "net"
for d in (SHOTS, NET):
    d.mkdir(parents=True, exist_ok=True)


def read_env(path: str = "/run/e2e/env") -> dict:
    env = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v  # last one wins, like docker compose
    return env


ENV = read_env()
HOST = os.environ["E2E_HOST"]
PORT = int(os.environ["E2E_PORT"])
LITELLM_PORT = int(os.environ["E2E_LITELLM_PORT"])
MCP_PORT = int(os.environ["E2E_MCP_PORT"])
# the Claude Code version this checkout pins (terminal/claude-code/package.json, read by browser.sh): what the sandbox and
# the Code page say they run
CLAUDE_CODE_VERSION = os.environ.get("E2E_CLAUDE_CODE_VERSION", "")
FILTER = os.environ.get("E2E_FILTER", "")
# tests/e2e/run.sh: E2E_CHECKS narrows every pass further (a focused run that spends less on Bedrock)
CHECKS_RE = os.environ.get("E2E_CHECKS", "")
# tests/e2e/run.sh: E2E_SHARD=K/N — the checks split by file into N parts of about the same time (SHARD_WEIGHTS), this
# pass keeps part K's; settings/* and final/* belong to part 1. K=0: none of them (run.sh's other passes run there).
SHARD = os.environ.get("E2E_SHARD", "")
# Seconds each file's checks took in a full run's main pass (v0.57.0's 057c); a file not listed counts 15 s a check.
# Part 1 also has settings/* with the update helper and final/*: about SHARD_PART1_S more.
SHARD_WEIGHTS = {"checks_browser": 474, "checks_code": 415, "checks_layout": 287, "checks_models": 93, "checks_terminal": 88,
                 "checks_widgets": 31, "checks_activity": 27, "checks_artifact": 21, "checks_preview": 19, "checks_mentions": 17,
                 "checks_run": 15, "checks_git": 13, "checks_api": 8, "checks_voice": 4, "checks_http": 2, "checks_subscriptions": 1}
SHARD_PART1_S = 500
# The app versions the app-specific selectors were written against (compose.yaml pins them; browser.sh passes the
# pinned tags). Checks that drive these UIs skip, saying why, on any other version instead of failing obscurely.
TESTED_WITH = {"open-webui": "v0.12.4-slim", "litellm": "1.106.3", "rustfs": "1.0.3"}
PINNED = {"open-webui": os.environ.get("E2E_OWUI_TAG", ""), "litellm": os.environ.get("E2E_LITELLM_TAG", ""),
          "rustfs": os.environ.get("E2E_RUSTFS_TAG", "")}
# Where the *.HOST names and 127.0.0.1-published ports are reachable from this container.
TARGET_IP = socket.gethostbyname(HOST)
# Published-only-on-127.0.0.1 ports (LiteLLM API, shared-mcp): same address as the portal from here.
API_IP = TARGET_IP

SECRET_KEYS = re.compile(r"(PASSWORD|SECRET|KEY|TOKEN|SALT)")
SECRETS = sorted({v for k, v in ENV.items() if SECRET_KEYS.search(k) and len(v) >= 8}, key=len, reverse=True)
# S3 presigned URLs carry the access key and a signature in the query string; hand-off links and some APIs a token
# or key (t=, token=, key=, …): their values never reach a log.
_AMZ = re.compile(r"(X-Amz-(?:Credential|Signature|Security-Token)=)[^&\s\"']+", re.I)
_QS = re.compile(r"([?&](?:t|token|access_token|id_token|key|api_key|apikey|secret|password|code|sig|signature)=)[^&#\s\"']+", re.I)


def redact(text) -> str:
    s = str(text)
    for v in SECRETS:
        if v in s:
            s = s.replace(v, "***")
    return _QS.sub(r"\1***", _AMZ.sub(r"\1***", s))


def origin(sub: str | None = None) -> str:
    return f"http://{(sub + '.') if sub else ''}{HOST}:{PORT}"


def host_of(sub: str | None) -> str:
    return f"{(sub + '.') if sub else ''}{HOST}"


# What Chat's site may make the browser fetch (caddy/Caddyfile chat_csp; tests/test_portal.sh keeps this copy the same)
CHAT_CSP = ("frame-ancestors {origin}; img-src 'self' data: blob:; media-src 'self' data: blob:; frame-src 'self' blob:; object-src 'none'; "
            "form-action 'self'; base-uri 'self'; connect-src 'self' ws://{host}:* wss://{host}:*; font-src 'self' data:; "
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; default-src 'self' data: blob:")


def csp_differs(served: str, wanted: str) -> list[str]:
    """The directives of the policy wanted that the one served lacks or gives other sources (the first of one given twice
    counts, as for browsers), and every other directive served that would widen it: one that widens one of them
    (script-src-elem, worker-src, child-src …) or one with a source other than a keyword, data: or blob: (a host, *,
    http:, https:). Another directive that only narrows it may come with it (sandbox, trusted-types, one added later
    with keywords alone): that does not break a check (lib/portal.sh chat_csp_check: the same rule)."""
    def parse(p):
        out = {}
        for d in (p or "").split(";"):
            parts = d.split()
            if parts and parts[0].lower() not in out:
                out[parts[0].lower()] = " ".join(parts[1:])
        return out
    have, want = parse(served), parse(wanted)
    bad = [k for k, v in want.items() if have.get(k) != v]
    # (and nothing else that widens it: a directive that would widen one of them, or another with *, http:, https: or a
    # host — only keywords, data: and blob:; lib/portal.sh chat_csp_check: the same)
    widening = {"script-src-elem", "script-src-attr", "style-src-elem", "style-src-attr", "worker-src", "child-src", "fenced-frame-src", "prefetch-src"}
    no_sources = {"sandbox", "report-to", "upgrade-insecure-requests", "block-all-mixed-content", "require-trusted-types-for", "trusted-types"}
    for k, v in have.items():
        if k in want or k in no_sources:
            continue
        # (report-uri: only paths of the page's own origin — a report carries what was refused; / and then neither /
        # nor \, and no \ anywhere: browsers read /\host/ as //host/)
        if k == "report-uri":
            if not v.split() or any(len(t) < 2 or t[0] != "/" or t[1] == "/" or "\\" in t for t in v.split()):
                bad.append(k)
            continue
        if k in widening or any(not (t.startswith("'") and t.endswith("'")) and t not in ("data:", "blob:") for t in v.split()):
            bad.append(k)
    return bad


class Resp:
    def __init__(self, status: int, headers: list[tuple[str, str]], body: bytes):
        self.status, self.headers_list, self.body = status, headers, body

    def header(self, name: str) -> str | None:
        for k, v in self.headers_list:
            if k.lower() == name.lower():
                return v
        return None

    def headers_all(self, name: str) -> list[str]:
        return [v for k, v in self.headers_list if k.lower() == name.lower()]

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", "replace")

    def json(self):
        return json.loads(self.body)


def _connect(ip: str, port: int, timeout: float) -> httpclient.HTTPConnection:
    """A connected HTTPConnection. Only the TCP connect is retried, 3 × 10 s (Docker Desktop's host-gateway
    forwarding once left a connect hanging for 30 s in a full run): nothing has been sent yet, so a retry never
    repeats a request."""
    last = None
    for attempt in range(3):
        conn = httpclient.HTTPConnection(ip, port, timeout=min(timeout, 10))
        try:
            conn.connect()
            conn.sock.settimeout(timeout)
            return conn
        except (TimeoutError, ConnectionRefusedError, ConnectionResetError, OSError) as e:
            last = e
            conn.close()
            time.sleep(1 + attempt)
    raise last


def http(method: str, sub: str | None, path: str, headers: dict | None = None, body: bytes | str | None = None,
         cookie: str | None = None, port: int | None = None, host_header: str | None = None, ip: str | None = None,
         timeout: float = 30) -> Resp:
    """One raw HTTP request to Caddy (or another published port) with exactly the headers given (no redirects,
    no cookie jar): Host is <sub>.HOST:PORT unless host_header says otherwise."""
    p = port or PORT
    conn = _connect(ip or TARGET_IP, p, timeout)
    h = {"Host": host_header or f"{host_of(sub)}:{p}", "Connection": "close"}
    if cookie:
        h["Cookie"] = cookie
    h.update(headers or {})
    if isinstance(body, str):
        body = body.encode()
    conn.request(method, path, body=body, headers=h)
    r = conn.getresponse()
    try:
        data = r.read()
    except httpclient.IncompleteRead as e:   # the server answered and closed early (e.g. a refused oversize body)
        data = e.partial
    out = Resp(r.status, r.getheaders(), data)
    conn.close()
    return out


def portal_login() -> str:
    """Logs in through Caddy like the login form; returns the "bn_session=…" cookie pair."""
    from urllib.parse import urlencode
    body = urlencode({"password": ENV["PORTAL_PASSWORD"], "next": "/"})
    r = http("POST", None, "/login", {"Origin": origin(), "Content-Type": "application/x-www-form-urlencoded"}, body)
    if r.status != 303:
        raise AssertionError(f"portal login: HTTP {r.status}")
    for c in r.headers_all("set-cookie"):
        if c.startswith("bn_session="):
            return c.split(";", 1)[0]
    raise AssertionError("portal login: no bn_session cookie")


# --- checks and results ---

class Skip(Exception):
    pass


def real_helper_running() -> bool:
    """A real update helper writes its heartbeat (with its pid) every few seconds into the mounted status folder: the
    checks that fake one, or that need it absent, skip then (the settings/* checks use the real one)."""
    try:
        beat = json.loads(Path("/state/status/helper.json").read_text())
    except (OSError, ValueError):
        return False
    return isinstance(beat.get("pid"), int) and isinstance(beat.get("heartbeat"), int) and time.time() - beat["heartbeat"] < 30


def need(app: str) -> None:
    """Skip the calling check when compose.yaml pins another version of APP than the selectors were written for."""
    if PINNED.get(app) != TESTED_WITH[app]:
        raise Skip(f"{app} is pinned at {PINNED.get(app) or '?'}; this check's selectors were written for "
                   f"{TESTED_WITH[app]} — update tests/e2e/browser for it")


CHECKS: list[tuple[str, str, object]] = []
RESULTS = OUT / "results.tsv"
# Called after every check as fn(ctx, ok) (ok: it passed; failed or skipped: not): a module whose checks can leave
# something on the stack that would fail the checks after it puts it right here (checks_code: the Code page's
# sessions). What it says is printed under the check's line (run.log); it never changes a result.
AFTER: list = []
# Until v0.57.0 Chromium on Linux shared the test host's network (--network host), so any container starting or stopping
# changed its interfaces, and it cancelled what it was loading: net::ERR_NETWORK_CHANGED (v0.39.0's and v0.42.0's
# settings-page; v0.57.0's first four-stage run). It has a network of its own now (browser-net.sh; E2E_BROWSER_NET=host:
# the old way). checks_browser.Recorder still counts each; a check that fails after one is tried once more (try_twice).
NETWORK_CHANGED = [0]


def check(suite: str, cid: str):
    def deco(fn):
        CHECKS.append((suite, cid, fn))
        return fn
    return deco


def after_check(fn):
    AFTER.append(fn)
    return fn


TAG = os.environ.get("E2E_TAG", "")   # a repeated browser run (e.g. after ./stack stt remove) names its results id@TAG


def _record(suite: str, cid: str, status: str, secs: float, msg: str) -> None:
    msg = redact(msg).replace("\t", " ").replace("\n", " ")[:400]
    cid = f"{cid}@{TAG}" if TAG else cid
    with RESULTS.open("a", encoding="utf-8") as f:
        f.write(f"{suite}\t{cid}\t{status}\t{int(secs)}\t{msg}\n")
    print(f"  {status:<5} {suite}/{cid}: {msg}", flush=True)


def try_twice(run, changed, between) -> tuple[str, str, str, str]:
    """RUN() -> (status, message), raising on a failure. A failure while the test host's network changed (CHANGED():
    how many times Chromium has said so) is tried once more, after BETWEEN(the first failure). -> (status, message,
    traceback or "", the first try's failure or "")"""
    first = ""
    for attempt in (1, 2):
        seen = changed()
        try:
            status, msg = run()
            return status, msg, "", first
        except Exception as e:  # noqa: BLE001 — every failure becomes a FAIL line
            failed, tb = f"{type(e).__name__}: {e}", traceback.format_exc()
            if attempt == 2 or changed() == seen:
                return "FAIL", failed, tb, first
            first = failed
            between(first)
    raise AssertionError("unreachable")


def said_twice(first: str, msg: str) -> str:
    """The message of a check that took a second try: it quotes the first try's failure, redacted before it is cut (a
    secret cut in two is no longer the secret, and redact would miss what is left of it)."""
    return f"on a second try (the first was cut off by the test host's network changing: {redact(first)[:120]}): {msg}"


def _tidy(ctx, suite: str, cid: str, ok: bool) -> None:
    for after in AFTER:
        try:
            said = after(ctx, ok)
        except Exception as e:  # noqa: BLE001 — tidying up never changes a result: said, and the next check runs
            said = f"tidying up failed: {type(e).__name__}: {e}"
        if said:
            print(f"  {'tidy':<5} {suite}/{cid}: {redact(said).replace(chr(10), ' ')[:600]}", flush=True)


def shard_parts(checks, n: int) -> dict[str, int]:
    """Each file of the checks -> its part (1..n): the heaviest first, each to the part with the least time so far
    (part 1 starting at SHARD_PART1_S); the same for every part, as it reads all the checks, not the selected ones."""
    weight: dict[str, float] = {}
    for _, _, fn in checks:
        m = fn.__module__
        weight[m] = SHARD_WEIGHTS[m] if m in SHARD_WEIGHTS else weight.get(m, 0) + 15
    load = [0.0] * (n + 1)
    load[1] = SHARD_PART1_S
    parts = {}
    for m in sorted(weight, key=lambda m: (-weight[m], m)):
        k = min(range(1, n + 1), key=lambda i: (load[i], i))
        parts[m] = k
        load[k] += weight[m]
    return parts


def in_shard(checks, shard: str):
    """The test for E2E_SHARD=K/N (all when empty): a check of part K (settings/* and final/*: part 1)."""
    if not shard:
        return lambda c: True
    m = re.fullmatch(r"(\d+)/(\d+)", shard)
    if not m or int(m.group(2)) < 1 or int(m.group(1)) > int(m.group(2)):
        raise SystemExit(f"E2E_SHARD={shard!r}: want K/N with 0 <= K <= N")
    k, n = int(m.group(1)), int(m.group(2))
    parts = shard_parts(checks, n)
    return lambda c: k == 1 if c[0] in ("settings", "final") else parts[c[2].__module__] == k


def run_all(ctx) -> int:
    fails = 0
    mine = in_shard(CHECKS, SHARD)
    selected = [c for c in CHECKS if (not FILTER or re.search(FILTER, f"{c[0]}/{c[1]}")) and (not CHECKS_RE or re.search(CHECKS_RE, f"{c[0]}/{c[1]}"))
                and mine(c)]
    (OUT / "expected.txt").write_text(f"{len(selected)}\n", encoding="ascii")   # run.sh: every check must report
    for suite, cid, fn in selected:
        t0 = time.time()

        def run(fn=fn):
            try:
                return "PASS", fn(ctx) or "ok"
            except Skip as e:
                return "SKIP", str(e)

        def between(first, suite=suite, cid=cid):
            print(f"  {'again':<5} {suite}/{cid}: the test host's network changed during it: {redact(first)[:300]}", flush=True)
            _tidy(ctx, suite, cid, False)

        status, msg, tb, first = try_twice(run, lambda: NETWORK_CHANGED[0], between)
        if first:
            msg = said_twice(first, msg)
        if status == "FAIL":
            fails += 1
            (OUT / "tracebacks").mkdir(exist_ok=True)
            (OUT / "tracebacks" / f"{suite}-{cid}.txt").write_text(redact(tb), encoding="utf-8")
        _record(suite, cid, status, time.time() - t0, msg)
        _tidy(ctx, suite, cid, status == "PASS")
    return fails


def expect(cond, msg: str):
    if not cond:
        raise AssertionError(msg)


def url_path(url: str) -> str:
    u = urlsplit(url)
    return u.path + (f"?{u.query}" if u.query else "")
