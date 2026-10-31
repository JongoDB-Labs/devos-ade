"""The optional browser terminal (./stack terminal; tests/e2e/run.sh --terminal turns it on in the throwaway): the
tab follows the setting, the terminal host is locked until the portal password is typed again, then xterm shows the
tmux session (Claude Code in window 1, shell windows with Ctrl-b c) that outlives the browser; its WebSocket refuses
other sites' Origins; on a phone it opens full screen from More; Sign out locks it again. One real devos-claude -p
inside it only with E2E_TERMINAL_CLAUDE=1 (run.sh's claude part). With E2E_TERMINAL_HOSTILE=1 (run.sh, after the
suite: a stand-in listener on ttyd's socket, as code in the sandbox could start one) the terminal host's policy is
checked against it. Every check but the first skips while it is off."""

from __future__ import annotations

import base64
import hashlib
import os
import re
import socket
import time
from pathlib import Path
from urllib.parse import urlencode

from common import ENV, HOST, PORT, TARGET_IP, Skip, check, expect, http, origin
from checks_browser import login, shot

ON = ENV.get("TERMINAL_ENABLED") == "true"
CLAUDE = os.environ.get("E2E_TERMINAL_CLAUDE") == "1"
HOSTILE = os.environ.get("E2E_TERMINAL_HOSTILE") == "1"
# What the main Caddy takes away from whatever answers on ttyd's socket (caddy/Caddyfile, terminal_page)
STRIPPED = ("set-cookie", "clear-site-data", "refresh", "link", "location", "service-worker-allowed",
            "access-control-allow-origin", "access-control-allow-credentials", "report-to", "x-frame-options")
TERM = origin("terminal")
FORM = {"Content-Type": "application/x-www-form-urlencoded"}
HTML = {"Accept": "text/html,application/xhtml+xml"}
# Expected while locked: the unlock page answers 401 (its forward_auth answer), a wrong password 401 again.
LOCKED_OK = [r"^401 (GET|POST) " + re.escape(TERM) + r"/(\.bn/unlock)?$", r"console.error Failed to load resource.*401"]


def need_on():
    if not ON:
        raise Skip("the terminal is off in this throwaway (tests/e2e/run.sh --terminal turns it on)")


def unlock_cookie(session: str) -> str:
    """POST /.bn/unlock on the terminal host as the form does; returns "bn_terminal=…"."""
    r = http("POST", "terminal", "/.bn/unlock", {**FORM, "Origin": TERM}, urlencode({"password": ENV["PORTAL_PASSWORD"]}),
             cookie=session)
    expect(r.status == 303 and r.header("location") == "/", f"unlock: HTTP {r.status} {r.header('location')}")
    c = next((c for c in r.headers_all("set-cookie") if c.startswith("bn_terminal=")), "")
    expect(c, "unlock set no bn_terminal cookie")
    return c


# The stack's terminal/ folder, read-only (tests/e2e/browser.sh mounts it): the pinned hashes come from the repo, so a
# changed script or a new ttyd shows here as well as in the build.
TERMINAL_SRC = Path("/terminal-src")


def expected_script_hashes() -> list[str]:
    """The two script hashes the terminal host's policy allows, as 'sha256-…' sources: ttyd's inline page script (the
    Dockerfile's TTYD_PAGE_SCRIPT_SHA256) and ttyd-clipboard.js (its own sha256, which the Dockerfile's
    TTYD_CLIPBOARD_SCRIPT_SHA256 must equal)."""
    try:
        dockerfile = (TERMINAL_SRC / "Dockerfile").read_text()
        clip = (TERMINAL_SRC / "ttyd-clipboard.js").read_bytes()
    except OSError as e:
        raise AssertionError(f"cannot read the repo's terminal/ files at {TERMINAL_SRC} (browser.sh mounts them): {e}") from None
    args = {m.group(1): m.group(2) for m in re.finditer(r"^ARG (TTYD_PAGE_SCRIPT_SHA256|TTYD_CLIPBOARD_SCRIPT_SHA256)=(\S+)$",
                                                          dockerfile, re.M)}
    expect(len(args) == 2, f"terminal/Dockerfile pins {sorted(args)}, not both script hashes")
    clip_hash = base64.b64encode(hashlib.sha256(clip).digest()).decode()
    expect(args["TTYD_CLIPBOARD_SCRIPT_SHA256"] == clip_hash,
           f"terminal/Dockerfile pins the clipboard script as {args['TTYD_CLIPBOARD_SCRIPT_SHA256']}, its file hashes to {clip_hash}")
    return [f"sha256-{args['TTYD_PAGE_SCRIPT_SHA256']}", f"sha256-{clip_hash}"]


def page_policy_problems(csp: str) -> list[str]:
    """What the terminal host's Content-Security-Policy (the main Caddy's terminal_page) lacks: [] when all is there —
    ttyd's script and the clipboard script by their hashes and nothing else (no 'unsafe-inline', no host), this host
    only, forms only to the unlock, framed by the portal only."""
    host = f"terminal.{HOST}"
    want = ["default-src 'none'", f"connect-src 'self' ws://{host}:* wss://{host}:*", "style-src 'unsafe-inline'",
            f"form-action {host}:*/.bn/unlock", "base-uri 'none'", "object-src 'none'",
            # the portal, and the Code page's terminal panel (a name that serves nothing while it is off)
            f"frame-ancestors {origin()} {origin('code') if ENV.get('CODE_ENABLED') == 'true' else 'http://code.invalid'}"]
    parts = [p.strip() for p in csp.split(";")]
    probs = [w for w in want if w not in parts]
    scripts = [p.split() for p in parts if p.split()[:1] == ["script-src"]]
    want_hashes = sorted(f"'{h}'" for h in expected_script_hashes())
    if len(scripts) != 1 or sorted(scripts[0][1:]) != want_hashes:
        probs.append(f"script-src: not exactly {' '.join(want_hashes)} (got {scripts})")
    return probs


def ws_handshake(cookie: str | None, origin_hdr: str | None) -> int:
    """ttyd's WebSocket handshake through Caddy (GET /ws, Upgrade): the HTTP status line only, then hang up."""
    key = base64.b64encode(os.urandom(16)).decode()
    lines = ["GET /ws HTTP/1.1", f"Host: terminal.{HOST}:{PORT}", "Upgrade: websocket",
             "Connection: Upgrade", "Sec-WebSocket-Version: 13", f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Protocol: tty"]
    if cookie:
        lines.append(f"Cookie: {cookie}")
    if origin_hdr:
        lines.append(f"Origin: {origin_hdr}")
    s = socket.create_connection((TARGET_IP, PORT), timeout=15)
    try:
        s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = b""
        while b"\r\n" not in head and len(head) < 4096:
            chunk = s.recv(1024)
            if not chunk:
                break
            head += chunk
    finally:
        s.close()
    m = re.match(rb"HTTP/1\.1 (\d{3})", head)
    expect(m, f"no HTTP status from the WebSocket handshake: {head[:80]!r}")
    return int(m.group(1))


def term_text(frame) -> str:
    """The visible screen of ttyd's xterm (window.term), one line per row."""
    return frame.evaluate("""() => { const b = window.term && window.term.buffer.active; if (!b) return '';
        const out = []; for (let i = b.viewportY; i < b.viewportY + window.term.rows; i++) {
          const l = b.getLine(i); out.push(l ? l.translateToString(true) : ''); } return out.join('\\n'); }""")


def locate_line(frame, want: str):
    """Where the screen's row that reads exactly `want` is, from xterm's buffer (the renderer draws no text we could
    find in the DOM): {row (0 = top of the screen), cols, left, top, cw, ch} in the frame's CSS pixels, or None. The
    last such row; the cell size is the screen element's box over rows and columns, so it holds for any renderer, and
    tmux's status line (the bottom row) or a scrolled view only change `row`."""
    return frame.evaluate("""(want) => { const t = window.term; if (!t) return null; const b = t.buffer.active;
        let row = -1; for (let i = 0; i < t.rows; i++) { const l = b.getLine(b.viewportY + i);
          if (l && l.translateToString(true).trim() === want) row = i; }
        if (row < 0) return null;
        const s = t.element && t.element.querySelector('.xterm-screen'); if (!s) return null;
        const r = s.getBoundingClientRect(); if (!r.width || !r.height) return null;
        return {row, cols: t.cols, left: r.left, top: r.top, cw: r.width / t.cols, ch: r.height / t.rows}; }""", want)


def wait_text(frame, pattern: str, timeout: float = 30) -> str:
    t0, txt = time.time(), ""
    while time.time() - t0 < timeout:
        txt = term_text(frame)
        if re.search(pattern, txt, re.M):
            return txt
        time.sleep(0.25)
    raise AssertionError(f"terminal never showed /{pattern}/; last screen: {txt[-400:]!r}")


def terminal_frame(page, timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        for f in page.frames:
            if f.url.startswith(TERM):
                return f
        page.wait_for_timeout(250)
    raise AssertionError("no terminal frame")


def unlock_in(page_or_frame, password: str):
    page_or_frame.locator("h1", has_text="Unlock the terminal").wait_for(timeout=20000)
    page_or_frame.fill("#password", password)
    page_or_frame.click("form[action='/.bn/unlock'] button[type=submit]")


def wait_xterm(frame):
    frame.locator(".xterm").wait_for(timeout=30000)
    t0 = time.time()
    while time.time() - t0 < 20 and not frame.evaluate("() => !!(window.term && window.term.buffer)"):
        time.sleep(0.25)
    return wait_text(frame, r"DevOS ADE", 30)   # tmux's status line


def type_line(page, frame, text: str):
    frame.locator(".xterm-helper-textarea").focus()
    page.keyboard.type(text, delay=15)
    page.keyboard.press("Enter")


def new_shell_window(page, frame):
    frame.locator(".xterm-helper-textarea").focus()
    page.keyboard.press("Control+b")
    page.keyboard.press("c")
    wait_text(frame, r"^terminal /workspace \$", 15)


@check("browser", "terminal-tab-follows-the-setting")
def tab_setting(ctx):
    page, rec = ctx.page("terminal-tab")
    login(page)
    page.wait_for_selector("#home:not([hidden])")
    tab = page.locator(".tab[data-tab=terminal]")
    line = page.inner_text("section.claude .terminal-line")
    if not ON:
        expect(tab.count() == 0, "a Terminal tab while the terminal is off")
        expect("./stack terminal enable" in line, f"Claude Code card: {line!r}")
        page.evaluate("location.hash = '#terminal'")   # a bookmarked #terminal: Home instead
        page.locator(".tab[data-tab=home][aria-current=page]").wait_for(timeout=10000)
        rec.save()
        return "off: no tab, #terminal falls back to Home, the card says ./stack terminal enable"
    expect(tab.is_visible() and "Terminal tab" in line, f"tab visible {tab.is_visible()}, card {line!r}")
    pop = page.locator(".popout[data-app=terminal]").get_attribute("href")
    expect(pop == TERM + "/", f"pop-out {pop}")
    rec.save()
    return "on: Terminal tab (pop-out to the terminal host) and the card's line"


@check("browser", "terminal-locked-then-unlocked")
def locked_then_unlocked(ctx):
    need_on()
    page, rec = ctx.page("terminal-desktop")
    login(page)
    page.click(".tab[data-tab=terminal]")
    page.wait_for_selector("iframe[data-app=terminal]")
    expect(page.locator("iframe[data-app=terminal]").get_attribute("src") == TERM + "/", "terminal frame src")
    f = terminal_frame(page)
    f.locator("h1", has_text="Unlock the terminal").wait_for(timeout=20000)
    shot(page, "40-terminal-locked")
    unlock_in(f, "definitely-wrong")
    f.locator(".error[role=alert]", has_text="not right").wait_for(timeout=10000)
    f = terminal_frame(page)
    unlock_in(f, ENV["PORTAL_PASSWORD"])
    f = terminal_frame(page)
    screen = wait_xterm(f)
    page.wait_for_timeout(1500)   # Claude Code's first screen in window 1
    shot(page, "41-terminal-desktop", mask=["#password"])
    new_shell_window(page, f)
    type_line(page, f, "echo ok-$((6*7)) && claude --version && pwd")
    out = wait_text(f, r"\(Claude Code\)", 30)
    expect(re.search(r"^ok-42$", out, re.M), f"no ok-42 in {out[-300:]!r}")
    expect(re.search(r"^/workspace$", out, re.M), "pwd is not /workspace")
    version = re.search(r"([0-9.]+) \(Claude Code\)", out).group(1)
    shot(page, "42-terminal-shell")
    probs = rec.problems(allow=LOCKED_OK)
    rec.save()
    expect(not probs, f"errors: {probs}")
    return f"locked (unlock form) → wrong password refused → unlocked → xterm + tmux; shell window: echo ok, Claude Code {version}"


@check("browser", "terminal-session-survives-the-browser")
def survives(ctx):
    need_on()
    mark = f"e2e-{os.getpid()}-{int(time.time()) % 100000}"
    for step in ("leave", "come back"):
        page, rec = ctx.page(f"terminal-reattach-{step.replace(' ', '-')}")   # a new browser context each time
        login(page)
        page.click(".tab[data-tab=terminal]")
        f = terminal_frame(page)
        unlock_in(f, ENV["PORTAL_PASSWORD"])
        f = terminal_frame(page)
        wait_xterm(f)
        if step == "leave":   # a window named after this run, then the browser goes away
            type_line(page, f, f"tmux new-window -d -n {mark}")
            page.wait_for_timeout(500)
        else:
            type_line(page, f, "tmux list-windows -F '#W' | tr '\\n' ' '; echo")
            out = wait_text(f, re.escape(mark), 20)
        rec.save()
    # the list is one line, but other checks' windows (Run, Start, Open in the terminal) can make it wrap in xterm
    names = " ".join(out.split())
    expect(re.search(r"\bclaude\b", names), f"no claude window in {names[-300:]!r}")
    return f"a window made in one browser ({mark}) is still there from the next one: {names[-120:]}"


def clipboard_read(frame) -> str:
    return frame.evaluate("() => navigator.clipboard.readText()")


def clipboard_write(frame, text: str):
    frame.evaluate("t => navigator.clipboard.writeText(t)", text)


@check("browser", "terminal-clipboard")
def clipboard(ctx):
    """JON-546: a plain drag over terminal output reaches the clipboard (tmux's OSC 52 → ttyd-clipboard.js, which says
    "Copied N characters" on the Paste button); an OSC 52 the shell prints itself does not (no gesture, and tmux drops
    it); the Paste button pastes the clipboard into the shell; and the terminal host's Content-Security-Policy refuses
    none of it."""
    need_on()
    page, rec = ctx.page("terminal-clipboard")
    for o in (TERM, origin()):   # (the frame's origin, and the portal that embeds it)
        page.context.grant_permissions(["clipboard-read", "clipboard-write"], origin=o)
    login(page)
    page.click(".tab[data-tab=terminal]")
    f = terminal_frame(page)
    unlock_in(f, ENV["PORTAL_PASSWORD"])
    f = terminal_frame(page)
    wait_xterm(f)
    new_shell_window(page, f)
    button = f.locator("button[title^='Paste from the clipboard']")
    try:
        button.wait_for(timeout=10000)
    except Exception as e:  # noqa: BLE001
        raise AssertionError(f"step 0 (setup): no Paste button in the terminal's page: {e}") from None
    f.locator(".xterm-helper-textarea").focus()
    try:
        clipboard_write(f, "jon546-probe")
        probe = clipboard_read(f)
    except Exception as e:  # noqa: BLE001
        raise Skip(f"this headless Chromium gives the page no clipboard even with the permissions granted: {str(e)[:120]}")
    if probe != "jon546-probe":
        raise Skip(f"this headless Chromium's clipboard does not read back what the page wrote ({probe!r})")

    # 1. copy: drag over the output line, no modifier
    type_line(page, f, "printf 'jon546-%s\\n' copy-check")
    wait_text(f, r"^jon546-copy-check$", 15)
    pos = locate_line(f, "jon546-copy-check")
    expect(pos, "step 1 (copy): the output line jon546-copy-check is in no row of xterm's buffer (the screen)")
    fb = page.locator("iframe[data-app=terminal]").bounding_box()
    expect(fb, "step 1 (copy): no box for the terminal's frame")
    x0 = fb["x"] + pos["left"] + pos["cw"] * 0.5
    x1 = fb["x"] + pos["left"] + pos["cw"] * min(len("jon546-copy-check") + 3, pos["cols"]) - pos["cw"] * 0.5
    y = fb["y"] + pos["top"] + pos["ch"] * (pos["row"] + 0.5)
    page.mouse.move(x0, y)
    page.mouse.down()
    page.mouse.move((x0 + x1) / 2, y, steps=8)
    page.mouse.move(x1, y, steps=8)
    page.mouse.up()
    t0, got, said = time.time(), "", ""
    while time.time() - t0 < 3:
        said = button.inner_text()
        got = clipboard_read(f)
        if "jon546-copy-check" in got and said.startswith("Copied"):
            break
        page.wait_for_timeout(150)
    expect("jon546-copy-check" in got, f"step 1 (copy): after a plain drag the clipboard holds {got!r}")
    expect(said.startswith("Copied"), f"step 1 (copy): the Paste button says {said!r}, not 'Copied N characters'")

    # 2. no copy without a gesture: the shell prints an OSC 52 itself
    clipboard_write(f, "jon546-marker")
    f.locator(".xterm-helper-textarea").focus()
    type_line(page, f, "printf '\\033]52;c;%s\\a' \"$(printf evil | base64)\"; echo osc-done-$((6*7))")
    wait_text(f, r"osc-done-42$", 15)
    page.wait_for_timeout(2500)   # past the page's window after the last gesture
    got = clipboard_read(f)
    expect(got == "jon546-marker", f"step 2 (no copy without a gesture): a printed OSC 52 changed the clipboard to {got!r}")
    # (and one tmux itself sends, as a program that drives tmux could make it: `set-buffer -w`; tmux's set-clipboard
    # external lets that through, so only the page's gate stops it)
    type_line(page, f, "sleep 2; tmux set-buffer -w evil-tmux; echo setbuf-done-$((6*7))")
    wait_text(f, r"setbuf-done-42$", 15)
    page.wait_for_timeout(1000)
    got = clipboard_read(f)
    expect(got == "jon546-marker", f"step 2 (no copy without a gesture): tmux's own OSC 52 (set-buffer -w) changed the clipboard to {got!r}")

    # 3. paste: the Paste button puts the clipboard into the shell
    clipboard_write(f, "echo jon546-paste-check")
    button.click()
    page.wait_for_timeout(300)
    page.keyboard.press("Enter")
    try:
        wait_text(f, r"^jon546-paste-check$", 10)
    except AssertionError as e:
        raise AssertionError(f"step 3 (paste): {e}") from None
    shot(page, "44-terminal-clipboard")

    # 4. the policy refused nothing
    csp = [e["text"] for e in rec.events if e["t"] in ("console", "pageerror") and re.search(r"Refused to|Content Security Policy", e["text"])
           and "directive 'webrtc'" not in e["text"]]
    rec.save()
    expect(not csp, f"step 4 (CSP): {csp[:3]}")
    return "a plain drag copied the output line (Paste button: 'Copied N characters'); a printed OSC 52 left the clipboard alone; Paste pasted; no CSP violation"


@check("browser", "terminal-devos-claude-inside")
def claude_inside(ctx):
    need_on()
    if not CLAUDE:
        raise Skip("only with the claude part (one Claude Code request, ~$0.02)")
    haiku = ENV.get("CLAUDE_BEDROCK_HAIKU_MODEL")
    if not haiku:
        raise Skip("no Haiku model enabled")
    page, rec = ctx.page("terminal-claude")
    login(page)
    page.click(".tab[data-tab=terminal]")
    f = terminal_frame(page)
    unlock_in(f, ENV["PORTAL_PASSWORD"])
    f = terminal_frame(page)
    wait_xterm(f)
    new_shell_window(page, f)
    # its stream (to a file): the mode Claude Code started in — the image's managed settings turn auto mode off, so
    # a session without a mode starts in default (Manual), not auto — and the answer
    type_line(page, f, f'clear; CLAUDE_BEDROCK_MODEL={haiku} devos-claude -p "Reply with exactly the word: ok" --max-turns 1 '
                       '--output-format stream-json --verbose > /tmp/e2e-cb.jsonl; jq -r \'select(.type == "system" and .subtype == "init") '
                       '| "mode: " + .permissionMode\' /tmp/e2e-cb.jsonl; jq -r \'select(.type == "result") | .result\' /tmp/e2e-cb.jsonl')
    wait_text(f, r"^session: (?!tallying)", 150)   # the final line replaces "session: tallying cost…"
    out = wait_text(f, r"^mode: \S+", 20)
    expect(re.search(r"^bedrock · " + re.escape(haiku), out, re.M), f"no launch line: {out[-500:]!r}")
    mode = re.search(r"^mode: (\S+)", out, re.M).group(1)
    expect(mode == "default", f"claude started in {mode!r} mode, not default (auto mode should be off): {out[-300:]!r}")
    out = wait_text(f, r"^ok\.?$", 10)
    cost = re.search(r"^session: (.*)$", out, re.M).group(1)
    expect(re.match(r"(<?\$[0-9.]+ \(terminal key|no spend booked yet)", cost), f"session line {cost!r}")
    launch = re.search(r"^bedrock · .*$", out, re.M).group(0)
    shot(page, "43-terminal-devos-claude")
    rec.save()
    return f"{launch[:110]} → ok, started in default mode (auto off); session: {cost}"


@check("http", "terminal-origin-and-unlock-enforced")
def enforced(ctx):
    need_on()
    r = http("GET", "terminal", "/", HTML)
    loc = r.header("location") or ""
    expect(r.status == 302 and loc.startswith(origin() + "/login?next="), f"no session: {r.status} {loc}")
    expect(ws_handshake(None, TERM) == 401, "WebSocket without a session")
    s = ctx.session()
    r = http("GET", "terminal", "/", HTML, cookie=s)
    expect(r.status == 401 and "Unlock the terminal" in r.text, f"session only: HTTP {r.status}")
    csp = r.header("content-security-policy") or ""
    expect(f"frame-ancestors {origin()}" in csp and r.header("x-frame-options") is None, f"unlock page CSP {csp}")
    expect(ws_handshake(s, TERM) == 401, "WebSocket with a session but no unlock")
    body = urlencode({"password": ENV["PORTAL_PASSWORD"]})
    for o in ("http://evil.example", origin(), origin("chat")):
        r = http("POST", "terminal", "/.bn/unlock", {**FORM, "Origin": o}, body, cookie=s)
        expect(r.status == 403 and not r.headers_all("set-cookie"), f"unlock from Origin {o}: HTTP {r.status}")
    r = http("POST", "terminal", "/.bn/unlock", FORM, body, cookie=s)
    expect(r.status == 403, f"unlock without Origin/Referer: HTTP {r.status}")
    r = http("POST", "terminal", "/.bn/unlock", {**FORM, "Origin": TERM}, "password=" + "x" * 20000, cookie=s)
    expect(r.status == 413, f"20 KB unlock body: HTTP {r.status}")
    c = unlock_cookie(s)
    low = c.lower()
    for attr in ("httponly", "samesite=strict", "path=/", "max-age=43200"):
        expect(attr in low, f"unlock cookie lacks {attr}")
    expect("domain=" not in low and "secure" not in low, f"unlock cookie not host-only/plain: {c.split(';', 1)[1]}")
    both = f"{s}; {c.split(';', 1)[0]}"
    r = http("GET", "terminal", "/", HTML, cookie=both)
    probs = page_policy_problems(r.header("content-security-policy") or "")
    expect(r.status == 200 and not probs and r.header("x-frame-options") is None,
           f"unlocked: HTTP {r.status}, CSP lacks {probs}: {r.header('content-security-policy')}")
    got = {o: ws_handshake(both, o) for o in (TERM, "http://evil.example", origin(), None)}
    expect(got == {TERM: 101, "http://evil.example": 403, origin(): 403, None: 403}, f"WebSocket by Origin: {got}")
    # the unlock is the terminal host's alone: a forged one, or the cookie without the session, opens nothing
    expect(ws_handshake(f"{s}; bn_terminal=forged.value.sig", TERM) == 401, "forged unlock cookie")
    expect(ws_handshake(c.split(";", 1)[0], TERM) == 401, "unlock cookie without a session")
    return ("no session → login; session only → unlock form (401, framed by the portal only), WebSocket 401; unlock refuses "
            "foreign/portal/app/no Origin and 20 KB; cookie host-only HttpOnly Strict 12 h; unlocked: ttyd's page with the "
            "terminal host's CSP (its two scripts' hashes only), WebSocket 101 from the terminal's own Origin, 403 from another "
            "site, the portal or none")


@check("browser", "terminal-hostile-upstream")
def hostile(ctx):
    need_on()
    if not HOSTILE:
        raise Skip("only with run.sh's stand-in on ttyd's socket (its result: browser/terminal-hostile-upstream@hostile)")
    page, rec = ctx.page("terminal-hostile")
    login(page)
    page.goto(TERM + "/")
    unlock_in(page, ENV["PORTAL_PASSWORD"])
    page.locator("#stub").wait_for(timeout=20000)   # the stand-in answers, through the gateway, after the real unlock
    resp = page.goto(TERM + "/")
    page.locator("#stub").wait_for(timeout=10000)
    hdrs = resp.all_headers()
    left = [h for h in STRIPPED if h in hdrs]
    expect(not left, f"the stand-in's headers got through: {left}")
    probs = page_policy_problems(hdrs.get("content-security-policy", ""))
    expect(not probs, f"CSP lacks {probs}: {hdrs.get('content-security-policy')}")
    expect(page.evaluate("() => window.pwned === undefined && document.title !== 'pwned'"), "the stand-in's script ran")
    page.evaluate("() => document.getElementById('steal').submit()")
    page.wait_for_timeout(1500)
    expect(page.url.startswith(TERM), f"its form posted away: {page.url}")
    csp = [e["text"] for e in rec.events if e["t"] == "console" and "Content Security Policy" in e["text"]]
    expect(any("script" in m for m in csp), f"no CSP violation for its script in the console: {csp}")
    expect(any("form-action" in m for m in csp), f"no form-action violation in the console: {csp}")
    names = {c["name"] for c in page.context.cookies()}
    expect(not names & {"bn_stub", "bn_stub_wide"}, f"its cookies were set: {sorted(names)}")
    r = page.request.get(origin() + "/api/summary", headers={"X-Requested-With": "bedrock-now"})
    expect(r.status == 200, f"the portal session after its Clear-Site-Data: HTTP {r.status}")
    shot(page, "47-terminal-stand-in")
    rec.save()
    return (f"a stand-in on ttyd's socket: its page arrives with the terminal host's CSP; its script blocked and its form "
            f"stopped ({len(csp)} CSP violations in the console); none of {len(STRIPPED)} headers (Set-Cookie, "
            "Clear-Site-Data, Refresh, Link, CORS …) through; no cookie planted; the portal session intact")


@check("browser", "terminal-phone-full-screen")
def phone(ctx):
    need_on()
    page, rec = ctx.page("terminal-phone", device="phone")
    login(page)
    page.click(".tab[data-tab=chat]")   # a phone's first sign-in opens Home, not Chat
    page.wait_for_selector("iframe[data-app=chat]", timeout=20000)
    expect(not page.locator(".tab[data-tab=terminal]").is_visible(), "Terminal in the phone's bottom bar")
    page.click("#more-btn")
    page.wait_for_selector("#more-sheet:not([hidden])")
    link = page.locator("#more-sheet .sheet-link[data-app=terminal]")
    expect(link.get_attribute("href") == TERM + "/" and link.get_attribute("target") == "_blank", "More → Terminal link")
    shot(page, "44-phone-more-terminal")
    with page.context.expect_page() as pop:
        link.click()
    t = pop.value
    # (a blank terminal says whether its socket opened, closed or never came)
    sockets = []
    t.on("websocket", lambda w: (sockets.append(f"open {w.url}"), w.on("close", lambda _w: sockets.append(f"closed {w.url}")),
                                 w.on("socketerror", lambda e: sockets.append(f"error {e}"))))
    t.wait_for_load_state()
    t.locator("h1", has_text="Unlock the terminal").wait_for(timeout=20000)
    shot(t, "45-phone-terminal-locked")
    unlock_in(t, ENV["PORTAL_PASSWORD"])
    try:
        wait_xterm(t)
    except AssertionError as e:
        shot(t, "fail-phone-terminal")
        raise AssertionError(f"{e}; sockets: {sockets or 'none'}; page {t.url}") from None
    new_shell_window(t, t.main_frame)
    type_line(t, t.main_frame, "echo phone-$((6*7)); claude --version")
    wait_text(t.main_frame, r"\(Claude Code\)", 20)
    cols = t.evaluate("() => window.term.cols")
    expect(30 <= cols <= 60, f"{cols} columns on a 390 px wide phone (no viewport for the page?)")
    t.wait_for_timeout(500)
    shot(t, "46-phone-terminal")
    rec.save()
    return f"phone: not in the bottom bar; More → Terminal opens it full screen → unlock → xterm ({cols} columns); a shell window runs commands"


@check("final", "terminal-locked-after-sign-out")
def sign_out(ctx):
    need_on()
    page, rec = ctx.page("terminal-sign-out")
    login(page)
    page.click(".tab[data-tab=terminal]")
    f = terminal_frame(page)
    unlock_in(f, ENV["PORTAL_PASSWORD"])
    wait_xterm(terminal_frame(page))
    page.click(".sidebar .logout button")
    page.wait_for_url(re.compile(r"/login$"))
    page.goto(TERM + "/")
    expect("/login" in page.url and page.url.startswith(origin()), f"terminal after Sign out → {page.url}")
    login(page)   # signed in again: the old unlock is void, the form is back
    page.goto(TERM + "/")
    page.locator("h1", has_text="Unlock the terminal").wait_for(timeout=20000)
    rec.save()
    ctx.reset_session()
    return "Sign out → the terminal host sends you to the login; signed in again, it asks for the password again"
