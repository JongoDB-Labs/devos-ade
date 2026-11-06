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
# the Code page project the Projects widget checks make (JON-1158): its folder in the workspace, its name, and where the terminal opens
PROJ_ROOT, PROJ_NAME = "e2e-term-proj", "E2E Term Project"
PROJ_PATH = f"/workspace/{PROJ_ROOT}"
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
    """The three script hashes the terminal host's policy allows, as 'sha256-…' sources: ttyd's inline page script (the
    Dockerfile's TTYD_PAGE_SCRIPT_SHA256), ttyd-clipboard.js and ttyd-keys.js (each its own sha256, which the Dockerfile's
    TTYD_CLIPBOARD_SCRIPT_SHA256 and TTYD_KEYS_SCRIPT_SHA256 must equal)."""
    try:
        dockerfile = (TERMINAL_SRC / "Dockerfile").read_text()
        own = {"TTYD_CLIPBOARD_SCRIPT_SHA256": (TERMINAL_SRC / "ttyd-clipboard.js").read_bytes(),
               "TTYD_KEYS_SCRIPT_SHA256": (TERMINAL_SRC / "ttyd-keys.js").read_bytes()}
    except OSError as e:
        raise AssertionError(f"cannot read the repo's terminal/ files at {TERMINAL_SRC} (browser.sh mounts them): {e}") from None
    args = {m.group(1): m.group(2) for m in re.finditer(
        r"^ARG (TTYD_PAGE_SCRIPT_SHA256|TTYD_CLIPBOARD_SCRIPT_SHA256|TTYD_KEYS_SCRIPT_SHA256)=(\S+)$", dockerfile, re.M)}
    expect(len(args) == 3, f"terminal/Dockerfile pins {sorted(args)}, not all three script hashes")
    hashes = [f"sha256-{args['TTYD_PAGE_SCRIPT_SHA256']}"]
    for name, script in own.items():
        h = base64.b64encode(hashlib.sha256(script).digest()).decode()
        expect(args[name] == h, f"terminal/Dockerfile pins {name} as {args[name]}, its file hashes to {h}")
        hashes.append(f"sha256-{h}")
    return hashes


def page_policy_problems(csp: str) -> list[str]:
    """What the terminal host's Content-Security-Policy (the main Caddy's terminal_page) lacks: [] when all is there —
    ttyd's script, the clipboard script and the keys script by their hashes and nothing else (no 'unsafe-inline', no host), this host
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
    """The visible screen of ttyd's xterm (window.term), one line per row — a row that continues the one above (xterm
    wrapped it: a narrow view) joined to it."""
    return frame.evaluate("""() => { const b = window.term && window.term.buffer.active; if (!b) return '';
        const out = []; for (let i = b.viewportY; i < b.viewportY + window.term.rows; i++) {
          const l = b.getLine(i), t = l ? l.translateToString(true) : '';
          if (l && l.isWrapped && out.length) out[out.length - 1] += t; else out.push(t); } return out.join('\\n'); }""")


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
    # fill the unlock form IF it appears; otherwise the page already unlocked itself from the session (local single
    # sign-on, JON-1140). Callers that need the form (wrong-password checks) set the bn_su loop-guard cookie first.
    try:
        page_or_frame.locator("form[action='/.bn/unlock'] #password").wait_for(timeout=8000)
    except Exception:
        return
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
    # this check exercises the password unlock form (wrong password → error); locally a session would otherwise
    # auto-unlock (JON-1140), so force the form with the loop-guard marker for this host
    page.context.add_cookies([{"name": "bn_su", "value": "1", "url": TERM}])
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
            type_line(page, f, "tmux list-windows -t claude -F '#{window_index}:#W' | tr '\\n' ' '; echo")
            # (INDEX:mark is in the list only: the mark alone is on the screen already, in the line the first browser typed)
            out = wait_text(f, rf"\d+:{re.escape(mark)}", 20)
        rec.save()
    # the list is one line, but other checks' windows (Run, Start, Open in the terminal) can make it wrap in xterm
    names = " ".join(out.split())
    # (the first window — the lowest index, 1 by terminal/tmux.conf's base-index — is bedrock: Claude Code on Bedrock; the tmux
    # session is still claude. By tmux's list, not its status line, which drops the leftmost windows when there are many)
    wins = {int(i): w for i, w in re.findall(r"(?<!\S)(\d+):(\S+)", names)}
    expect(wins and wins[min(wins)] == "bedrock", f"the first window is not bedrock in {names[-300:]!r}")
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
    # local single sign-on (JON-1140): a session alone, locally, auto-unlocks; bn_su forces the password form (remote/fallback)
    r = http("GET", "terminal", "/", HTML, cookie=s)
    expect(r.status == 302 and "/.bn/session-unlock" in (r.header("location") or ""), f"session only auto-unlocks: {r.status}")
    r = http("GET", "terminal", "/", HTML, cookie=s + "; bn_su=1")
    expect(r.status == 401 and "Unlock the terminal" in r.text, f"session + bn_su → form: HTTP {r.status}")
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
    r = page.request.get(origin() + "/api/summary", headers={"X-Requested-With": "devos-ade"})
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
    shot(t, "45-phone-terminal")
    unlock_in(t, ENV["PORTAL_PASSWORD"])   # local SSO auto-unlocks; fills the form only if one appears (JON-1140)
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


# --- the Terminal tab as a page of widgets (JON-946; static/termpage.js, terminal/ttyd-keys.js) ---
# Each check starts from no saved layout (the portal's copy and this browser's cache) and puts it back afterwards. No
# Bedrock calls: the shells are plain bash windows, and view 1's window (Claude Code) is never typed into.

CLEAR_LAYOUT = """async () => {
  const r = await fetch('/api/ui/layout', {method: 'PUT', credentials: 'same-origin', headers: {'X-Requested-With': 'devos-ade', 'Content-Type': 'application/json'},
    body: JSON.stringify({version: 1, pages: {terminal: {desktop: null, tablet: null, phone: null, commands: null}}})});
  try { localStorage.removeItem('bn.layout.terminal'); } catch (e) {}
  return r.status;
}"""
SAVED_LAYOUT = """async () => (await fetch('/api/ui/layout', {credentials: 'same-origin', headers: {'X-Requested-With': 'devos-ade'}})).json()"""
# Where the focus goes from here on, kept in the page (a check that loses the focus says where it went)
FOCUS_LOG = """() => { const t0 = performance.now();
  const d = (e) => !e ? 'null' : e.id ? '#' + e.id : e.tagName.toLowerCase() + (typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\\s+/).join('.') : '') + (e.dataset && e.dataset.app ? `[data-app=${e.dataset.app}]` : '');
  const log = (k, e) => window.__focusLog.push(`${Math.round(performance.now() - t0)}ms ${k} ${d(e)}`);
  window.__focusLog = []; window.__focusSays = d;
  document.addEventListener('focusin', (ev) => log('in', ev.target), true);
  document.addEventListener('focusout', (ev) => log('out', ev.target), true);
  window.addEventListener('blur', () => log('window blur; active', document.activeElement)); }"""
FOCUS_SEEN = "() => `active ${window.__focusSays(document.activeElement)}; ${window.__focusLog.slice(-12).join(', ')}`"


BOXES = """() => [...document.querySelectorAll('.tp-pane')].map((p) => {
  const s = p.querySelector('.tp-slot').getBoundingClientRect(), f = document.querySelector(p.dataset.view === '1' ? 'iframe[data-app=terminal]' : `iframe[data-app=terminal-${p.dataset.view}]`);
  const r = f ? f.getBoundingClientRect() : null;
  return {view: p.dataset.view, slot: [s.left, s.top, s.width, s.height], frame: r && [r.left, r.top, r.width, r.height], hidden: f ? f.hidden : null};
})"""


def reset_layout(page):
    expect(page.evaluate(CLEAR_LAYOUT) == 200, "the Terminal page's layout could not be cleared")


def saved_terminal(page) -> dict:
    return page.evaluate(SAVED_LAYOUT)["pages"].get("terminal", {})


def view_frame(page, n: int, timeout=40):
    """The Frame of the Nth terminal view (1: the Terminal tab's own frame), once it is on the terminal host."""
    sel = "iframe[data-app=terminal]" if n == 1 else f"iframe[data-app=terminal-{n}]"
    t0 = time.time()
    while time.time() - t0 < timeout:
        if page.locator(sel).count():
            f = page.locator(sel).first.element_handle().content_frame()
            if f and f.url.startswith(TERM):
                return f
        page.wait_for_timeout(250)
    raise AssertionError(f"no frame for terminal view {n}")


def open_terminal(ctx, name: str, device: str = "desktop"):
    """A new browser, signed in, no saved layout, the Terminal tab unlocked and showing tmux (a phone gets there from
    More)."""
    page, rec = ctx.page(name, device)
    login(page)
    reset_layout(page)
    page.reload()
    page.wait_for_selector(".sidebar")
    if device == "phone":
        page.click("#more-btn")
        page.click("#more-terminal")
    else:
        page.click(".tab[data-tab=terminal]")
    page.wait_for_selector("iframe[data-app=terminal]", state="attached")
    unlock_in(terminal_frame(page), ENV["PORTAL_PASSWORD"])
    wait_xterm(terminal_frame(page))
    return page, rec


def customize(page):
    page.click("#term-customize")
    page.wait_for_selector("#term-tray:not([hidden])")


def add_back(page, wid: str):
    page.click(f"#term-hidden [data-id={wid}]")
    page.wait_for_selector(f"[data-widget={wid}]:not([hidden])")


# The Projects widget's rows (JON-1158): the workspace, the Code page's projects (the code container's summary, through the
# portal's /api/answers) and the folders of this computer
PANEL_ROWS = """() => [...document.querySelectorAll('.tp-proj')].map((e) => ({path: e.dataset.path, id: e.dataset.id,
  name: e.querySelector('strong').textContent, flags: (e.querySelector('.tp-proj-flags') || {}).textContent || '', gone: e.classList.contains('tp-proj-gone'),
  button: !!e.querySelector('.tp-open-shell:not([disabled])')}))"""
PANEL_ALLOW = [r"^429 GET .*/api/answers", r"^409 .*", r"^404 .*"]   # (transient: the panel polls /api/answers; a window moved under it)


def show_projects_widget(page):
    """The Projects widget on the Terminal page (it is off in the default layout), with its rows."""
    if not page.locator("[data-widget=projects]:not([hidden])").count():
        customize(page)
        add_back(page, "projects")
    page.wait_for_selector(".tp-proj")


def panel_note(page) -> str:
    return page.evaluate("() => { const n = document.querySelector('.tp-none'); return n && !n.hidden ? n.textContent : ''; }")


def wait_panel(page, what: str, pred, timeout=40):
    """The widget's rows once PRED(rows) holds. The page reads the list again when you come back to it (focus): that is sent
    each time, as a person returning from the Code page does."""
    t0, rows = time.time(), []
    while time.time() - t0 < timeout:
        page.evaluate("() => window.dispatchEvent(new Event('focus'))")
        page.wait_for_timeout(900)
        rows = page.evaluate(PANEL_ROWS)
        if pred(rows):
            return rows
    raise AssertionError(f"the Projects panel: {what}; rows {rows}")


def add_terminal(page, n: int):
    """Add a terminal and wait until view N shows tmux, in a window of its own, at a clean prompt: a view's session
    outlives the check that made it (Close only detaches), so what an earlier check left running there (cat -v) is
    ended and the screen cleared."""
    page.click("#term-add")
    page.wait_for_selector(f".tp-pane[data-view='{n}']")
    f = view_frame(page, n)
    wait_xterm(f)
    focus_view(page, n)
    f.locator(".xterm-helper-textarea").focus()
    page.keyboard.press("Control+c")
    page.keyboard.press("Control+l")
    wait_text(f, r"\$ ?$", 15)   # (the prompt: the space after it is there, or not when tmux redrew the line)
    return f


def focus_view(page, n: int):
    """A real click in the view's terminal: it has the keyboard, and the page knows which one."""
    f = view_frame(page, n)
    f.locator(".xterm-screen").click()
    page.wait_for_function("(n) => window.bnTermPage.focused() === n", arg=n, timeout=10000)
    return f


def run_in(page, n: int, line: str):
    f = focus_view(page, n)
    wait_text(f, r"\$ ?$")   # its shell's prompt: keys typed before the terminal is connected are lost
    f.locator(".xterm-helper-textarea").focus()
    page.keyboard.type(line, delay=15)
    page.keyboard.press("Enter")
    return f


def say_live(page) -> str:
    return page.evaluate("() => document.getElementById('term-live').textContent").replace("\u00a0", " ").strip()


@check("browser", "terminal-widgets-default-is-todays-tab")
def widgets_default(ctx):
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-default")
    try:
        expect(page.locator("#term-page").is_hidden(), "the widget page is on without anyone customizing")
        expect(page.locator("#term-customize").is_visible(), "no Customize in Who answers' bar")
        bar_h = page.locator("#answers-bar").bounding_box()["height"]
        stage = page.locator(".stage").bounding_box()
        box = page.locator("iframe[data-app=terminal]").bounding_box()
        expect(abs(box["x"] - stage["x"]) < 1 and abs(box["width"] - stage["width"]) < 1 and abs(box["y"] - (stage["y"] + bar_h)) < 2
               and abs(box["height"] - (stage["height"] - bar_h)) < 2, f"the terminal frame is {box}, not the stage under the bar ({stage}, bar {bar_h})")
        f = terminal_frame(page)
        expect(f.get_by_role("button", name="Paste").is_visible(), "no Paste button in the terminal (today's tab)")
        expect(page.locator("iframe[data-app^=terminal-]").count() == 0, "a second terminal frame without anyone adding one")
        # Customize and Done with no change: the page appears and goes away again, nothing is saved, the frame is not reloaded
        src = page.locator("iframe[data-app=terminal]").get_attribute("src")
        customize(page)
        expect(page.locator("#term-page").is_visible() and page.locator("[data-widget=terminals]").is_visible(), "Customize shows no page")
        expect(page.locator("[data-widget=keys]").is_hidden(), "the key bar is on by default on a desktop")
        page.click("#term-done")
        page.wait_for_selector("#term-page", state="hidden")
        page.wait_for_timeout(1000)
        expect(page.locator("iframe[data-app=terminal]").get_attribute("src") == src, "the terminal frame was reloaded")
        expect(not saved_terminal(page), f"a layout was saved without a change: {saved_terminal(page)}")
        rec.save()
    finally:
        reset_layout(page)
    return "default: no widget page, the one frame under Who answers' bar with its Paste button; Customize then Done saves nothing and does not reload it"


@check("browser", "terminal-widgets-tray-compacts-when-stuck")
def widgets_tray_sticky(ctx):
    """JON-974: the Terminal page's tray is the Home tray's class: stuck to the top it is one row, and the page (.tp) keeps
    scroll-padding for it; both go on Done."""
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-tray-sticky")
    try:
        page.set_viewport_size({"width": 1400, "height": 600})   # (short, so the page under the tray scrolls)
        customize(page)
        page.wait_for_timeout(300)
        top = page.evaluate("() => document.getElementById('term-tray').getBoundingClientRect().height")
        room = page.evaluate("() => { const p = document.getElementById('term-page'); return p.scrollHeight - p.clientHeight; }")
        expect(room > 60, f"the Terminal page cannot scroll ({room} px of room) to test the tray")
        page.evaluate("() => { const p = document.getElementById('term-page'); p.scrollTop = p.scrollHeight; }")
        page.wait_for_function("() => document.getElementById('term-tray').classList.contains('wg-stuck')", timeout=5000)
        page.wait_for_timeout(200)
        stuck = page.evaluate("() => document.getElementById('term-tray').getBoundingClientRect().height")
        expect(stuck <= 90 and stuck < top, f"the stuck tray is {stuck:.0f} px tall (at the top: {top:.0f})")
        expect(page.locator("#term-help").is_hidden() and page.locator("#term-done").is_visible(), "the stuck tray hides the wrong parts")
        pad = page.evaluate("() => parseFloat(document.getElementById('term-page').style.scrollPaddingTop)")
        expect(pad >= stuck + 8 - 1, f"scroll-padding-top is {pad}, the tray is {stuck:.0f} px")
        page.keyboard.press("Escape")
        page.wait_for_selector("#term-page", state="hidden")
        expect(page.locator(".wg-sentinel").count() == 0, "the sentinel was left behind")
        rec.save()
    finally:
        reset_layout(page)
    return f"stuck tray {stuck:.0f} px (at the top {top:.0f}), scroll-padding {pad:.0f}; gone with Done"


@check("browser", "terminal-widgets-views-and-sessions")
def widgets_views(ctx):
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-views")
    try:
        customize(page)
        frames = {n: add_terminal(page, n) for n in (2, 3, 4)}
        expect(page.locator(".tp-pane").count() == 4, "four terminals expected")
        expect(page.locator("#term-add").is_disabled(), "Add a terminal while there are four")
        shot(page, "terminal-widgets-4-views")
        # each view is a session of its own, grouped with claude: its name, and a shell window made current in it
        sessions = {}
        for n in (2, 3, 4):
            run_in(page, n, "echo sess=$(tmux display-message -p '#S') win=$(tmux display-message -p '#W')")
            out = wait_text(frames[n], r"sess=view-\d win=[\w-]+")
            sessions[n] = re.search(r"sess=(view-\d) win=([\w-]+)", out).groups()
            expect(sessions[n][0] == f"view-{n}", f"view {n} is in session {sessions[n][0]}")
        # (shell-N, not "shell": Open a shell here finds the workspace's own shell window by that name)
        expect(all(s[1] == f"shell-{n}" for n, s in sessions.items()), f"the windows made current: {sessions}")
        # a marker typed in view 2 is not in view 3's or view 4's current window (nor in view 1's): each has its own shell
        mark = f"m{os.getpid()}x{int(time.time()) % 10000}"
        run_in(page, 2, f"echo {mark}")
        wait_text(frames[2], rf"^{mark}$")
        page.wait_for_timeout(800)
        for n in (3, 4):
            expect(mark not in term_text(frames[n]), f"the marker typed in view 2 shows in view {n}")
        expect(mark not in term_text(view_frame(page, 1)), "the marker typed in view 2 shows in view 1")
        # ... but the windows are shared: a window made from view 3 is listed from view 2
        run_in(page, 3, f"tmux new-window -d -n w{mark}")
        run_in(page, 2, "tmux list-windows -F '#W' | tr '\\n' ' '; echo")
        wait_text(frames[2], rf"w{mark}", 20)
        # a split that changes: stacked, then 2 by 2; the frames stay over their slots, the terminals refit
        page.click("[data-split=rows]")
        page.wait_for_timeout(600)
        page.click("[data-split=grid]")
        page.wait_for_timeout(600)
        for b in page.evaluate(BOXES):
            expect(b["frame"] and all(abs(a - c) <= 2 for a, c in zip(b["slot"], b["frame"])), f"view {b['view']}'s frame is not over its slot: {b}")
        # a resize: the window made smaller, every frame follows its slot and xterm fits the new size
        cols = {n: frames[n].evaluate("() => window.term.cols") for n in (2, 3, 4)}
        page.set_viewport_size({"width": 1100, "height": 700})   # (still a desktop: under 1100 px the tablet's own arrangement)
        page.wait_for_timeout(1200)
        for b in page.evaluate(BOXES):
            expect(b["frame"] and all(abs(a - c) <= 2 for a, c in zip(b["slot"], b["frame"])), f"after the resize view {b['view']}'s frame is not over its slot: {b}")
        for n in (2, 3, 4):
            c2 = frames[n].evaluate("() => window.term.cols")
            expect(c2 < cols[n], f"view {n} still has {c2} columns after the window got narrower (was {cols[n]})")
        shot(page, "terminal-widgets-grid-resized")
        # closing a view only detaches it: its session and the windows stay
        page.click(".tp-pane[data-view='4'] .tp-close")
        page.wait_for_selector("iframe[data-app=terminal-4]", state="detached")
        run_in(page, 2, "tmux list-sessions -F 'S:#S' | tr '\\n' ' '; echo")
        out = wait_text(frames[2], r"S:view-2")
        expect("S:view-4" in out and "S:claude" in out, f"closing view 4 ended its session: {out[-200:]!r}")
        expect(page.locator(".tp-pane").count() == 3 and not page.locator("#term-add").is_disabled(), "three terminals and Add a terminal again")
        # the layout is kept, and a reload brings the views back with fresh tokens, each in its own session and window
        got = None
        for _ in range(40):
            got = saved_terminal(page).get("desktop")
            if got and got["views"] == 3 and got["split"] == "grid":
                break
            page.wait_for_timeout(250)
        expect(got and got["views"] == 3 and got["split"] == "grid", f"the portal's copy: {got}")
        page.reload()
        page.wait_for_selector(".tp-pane[data-view='3']")
        f2 = view_frame(page, 2)
        wait_xterm(f2)
        expect(page.locator(".tp-pane").count() == 3, "three terminals after a reload")
        tokens = [page.locator(f"iframe[data-app=terminal-{n}]").get_attribute("src") for n in (2, 3)]
        expect(all(re.search(rf"\?arg=view&arg={n}&arg=\d{{10}}-[0-9a-f]{{16}}-[0-9a-f]{{32}}$", t or "") for n, t in zip((2, 3), tokens)), f"the views' addresses: {tokens}")
        wait_text(f2, rf"^{mark}$", 20)
        # (its output line: view 3 made the window w<marker> since, so the name is on its screen and in tmux's status line)
        expect(not re.search(rf"^{mark}$", term_text(view_frame(page, 3)), re.M), "after the reload the marker's output shows in view 3")
        rec.save()
    finally:
        reset_layout(page)
    return "4 views: view-2…4 sessions with a shell window each, a marker typed in one is not in the others, windows shared; split and resize keep every frame over its slot; Close detaches (session stays); the layout and the shells survive a reload"


@check("browser", "terminal-widgets-key-bar-reaches-the-focused-view-only")
def widgets_key_bar(ctx):
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-keys")
    try:
        customize(page)
        add_back(page, "keys")
        f2, f3 = add_terminal(page, 2), add_terminal(page, 3)
        for n in (2, 3):
            run_in(page, n, "cat -vT")   # prints what it is sent: Esc as ^[, Up as ^[[A, Tab as ^I (-T), NUL as ^@
        page.wait_for_timeout(500)
        # a click on a key button leaves the keyboard in the terminal (the page's active element is its frame)
        focus_view(page, 2)
        page.click("[data-key=esc]")
        wait_text(f2, r"\^\[")
        expect(page.evaluate("() => document.activeElement.tagName") == "IFRAME", "the key button took the keyboard from the terminal")
        # (the terminal echoes Esc as ^[ but a Tab as spacing: cat shows ^I once Enter sends it the line). Esc arrives alone:
        # the terminal's report that it has the focus back came after it once, and tmux read the two as Alt with nothing (^[^@)
        page.click("[data-key=tab]")
        # (the Tab is a message to the frame and the Enter a key: the browser may take the key first, so Enter waits for the
        # Tab's echo — the cursor at the next tab stop)
        f2.wait_for_function("() => window.term.buffer.active.cursorX >= 8", timeout=5000)
        page.keyboard.press("Enter")
        wait_text(f2, r"^\^\[\^I$")
        page.wait_for_timeout(600)
        expect("^[" not in term_text(f3) and "^I" not in term_text(f3), "view 3 got the keys sent to view 2")
        focus_view(page, 3)
        page.click("[data-key=up]")
        wait_text(f3, r"\^\[\[A")
        page.wait_for_timeout(400)
        expect("^[[A" not in term_text(f2), "view 2 got the key sent to view 3")
        # Ctrl is held for the next key only
        page.click("[data-mod=ctrl]")
        expect(page.get_attribute("[data-mod=ctrl]", "aria-pressed") == "true", "Ctrl does not show as held")
        page.click("[data-key=up]")
        wait_text(f3, r"\^\[\[1;5A")
        page.wait_for_function("() => document.querySelector('[data-mod=ctrl]').getAttribute('aria-pressed') === 'false'", timeout=5000)
        # Ctrl-b is tmux's prefix: with c it makes a window, in that view's session only (its status line lists it)
        page.click("[data-key=ctrl-c]")   # ends cat -v in view 3
        wait_text(f3, r"\^C|\$ ?$", 10)
        page.click("[data-key=ctrl-b]")
        f3.locator(".xterm-helper-textarea").focus()
        page.keyboard.press("c")
        wait_text(f3, r"^terminal /workspace \$", 15)
        # every button has a name, and a touch target of 44 px where the screen is a touch one (the check on a phone)
        unnamed = page.eval_on_selector_all("[data-widget=keys] button", "els => els.filter((b) => !(b.getAttribute('aria-label') || b.textContent.trim())).length")
        expect(unnamed == 0, f"{unnamed} key bar buttons without a name")
        shot(page, "terminal-widgets-key-bar")
        rec.save()
    finally:
        reset_layout(page)
    return "key bar: Esc, Tab, Up reach only the view that has the keyboard; the keyboard stays in the terminal after a click; Ctrl is held for one key (^[[1;5A) and lets go; Ctrl-C and Ctrl-b work"


@check("browser", "terminal-widgets-quick-commands")
def widgets_commands(ctx):
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-commands")
    try:
        customize(page)
        add_back(page, "commands")
        f2 = add_terminal(page, 2)
        # a command that is not one: refused, in words, nothing saved
        page.click("#tp-cmd-add")
        page.click("#tp-cmd-form button[type=submit]")
        expect(page.locator(".tp-form-msg").inner_text() == "Give it a name", f"the form says {page.locator('.tp-form-msg').inner_text()!r}")
        page.fill("#tp-cmd-label", "Type only")
        page.fill("#tp-cmd-text", "echo qt-$((6*7))")
        page.click("#tp-cmd-form button[type=submit]")
        page.click("#tp-cmd-add")
        page.fill("#tp-cmd-label", "Run it")
        page.fill("#tp-cmd-text", "echo qr-$((6*7))")
        page.check("#tp-cmd-run")
        page.click("#tp-cmd-form button[type=submit]")
        expect(page.locator(".tp-cmd").count() == 2, "two commands expected")
        expect(page.locator(".tp-cmd .tp-run").count() == 1, "only the command marked Run shows the Enter mark")
        # a click types into the view that has the keyboard; Enter only for the one marked Run
        focus_view(page, 2)
        page.click(".tp-cmd >> nth=0")
        wait_text(f2, r"echo qt-\$\(\(6\*7\)\)")
        page.wait_for_timeout(500)
        expect(not re.search(r"^qt-42$", term_text(f2), re.M), "a command not marked Run was run")
        f2.locator(".xterm-helper-textarea").focus()
        page.keyboard.press("Control+u")   # the person clears the line; the next command is typed and run by itself
        focus_view(page, 2)
        page.click(".tp-cmd >> nth=1")
        wait_text(f2, r"^qr-42$")
        # the commands are kept with the layout: the portal's copy, and after a reload
        got = None
        for _ in range(40):
            got = saved_terminal(page).get("commands")
            if got and len(got) == 2:
                break
            page.wait_for_timeout(250)
        expect(got == [{"label": "Type only", "text": "echo qt-$((6*7))", "run": False}, {"label": "Run it", "text": "echo qr-$((6*7))", "run": True}], f"saved: {got}")
        page.reload()
        page.wait_for_selector(".tp-cmd >> nth=1")
        # edit, then remove
        page.click(".tp-edit >> nth=0")
        expect(page.input_value("#tp-cmd-label") == "Type only", "the form does not hold the command to edit")
        page.fill("#tp-cmd-label", "Typed only")
        page.click("#tp-cmd-form button[type=submit]")
        expect(page.locator(".tp-cmd >> nth=0").inner_text().startswith("Typed only"), "the edit was not kept")
        page.click(".tp-remove >> nth=0")
        expect(page.locator(".tp-cmd").count() == 1 and "removed" in say_live(page), f"remove: {say_live(page)!r}")
        # at most 20
        for i in range(19):
            page.click("#tp-cmd-add")
            page.fill("#tp-cmd-label", f"c{i}")
            page.fill("#tp-cmd-text", f"echo {i}")
            page.click("#tp-cmd-form button[type=submit]")
        expect(page.locator(".tp-cmd").count() == 20 and page.locator("#tp-cmd-add").is_disabled(), "the 20th command does not close Add a command")
        expect(page.evaluate("() => document.activeElement.classList.contains('tp-cmd')"), "the focus was lost when Add a command closed")
        shot(page, "terminal-widgets-commands")
        rec.save()
    finally:
        reset_layout(page)
    return "quick commands: refused without a name; a click types into the focused view, Enter only for Run; kept with the layout across a reload; edit, remove, and at most 20"


@check("browser", "terminal-widgets-ignore-messages-from-other-windows")
def widgets_messages(ctx):
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-messages")
    try:
        customize(page)
        f2 = add_terminal(page, 2)
        run_in(page, 2, "cat -v")
        page.wait_for_timeout(500)
        # the terminal's own window, and a sibling frame of the portal that reaches it through window.frames, are not its parent
        f2.evaluate("() => window.postMessage({type: 'text', text: 'HACK-self', run: true}, '*')")
        page.evaluate("""() => {
          const target = document.querySelector('iframe[data-app=terminal-2]').contentWindow;
          const s = document.createElement('iframe');
          s.id = 'sibling'; s.srcdoc = '<script>parent.document.querySelector("iframe[data-app=terminal-2]").contentWindow.postMessage({type: "text", text: "HACK-sibling", run: true}, "*")<\\/script>';
          s.hidden = true; document.body.append(s);
        }""")
        page.wait_for_timeout(1500)
        page.evaluate("() => { const s = document.getElementById('sibling'); if (s) s.remove(); }")
        out = term_text(f2)
        expect("HACK" not in out, f"a message from another window reached the terminal: {out[-200:]!r}")
        # the portal's own, from the page that frames it, does (a quick command and a key)
        page.evaluate("() => document.querySelector('iframe[data-app=terminal-2]').contentWindow.postMessage({type: 'text', text: 'FROM-PARENT'}, new URL(document.querySelector('iframe[data-app=terminal-2]').src).origin)")
        wait_text(f2, r"FROM-PARENT")
        # what is not in the table, or has a control character, is ignored even from the parent
        page.evaluate("""() => { const w = document.querySelector('iframe[data-app=terminal-2]').contentWindow, o = new URL(document.querySelector('iframe[data-app=terminal-2]').src).origin;
          w.postMessage({type: 'key', key: 'enter'}, o); w.postMessage({type: 'key', key: '\\u001b[2J'}, o);
          w.postMessage({type: 'text', text: 'CTRL\\u001b[31m'}, o); w.postMessage({type: 'text', text: 'NEWLINE\\nrm'}, o); w.postMessage({type: 'text', text: 'x'.repeat(4097)}, o); }""")
        page.wait_for_timeout(1000)
        out = term_text(f2)
        expect("CTRL" not in out and "NEWLINE" not in out and "xxxxxxxx" not in out, f"a refused message reached the terminal: {out[-200:]!r}")
        rec.save()
    finally:
        reset_layout(page)
    return "ttyd-keys.js ignores the terminal's own window and a sibling frame of the portal; takes the portal's text; ignores unknown keys, control characters and 4 KB+ from the parent too"


@check("browser", "terminal-widgets-open-a-shell-in-a-project")
def widgets_projects(ctx):
    need_on()
    from checks_code import Code, _drop_projects
    # a project of the Code page (JON-1158): made through its API before the Terminal tab opens (ctx.page closes the other pages)
    c = Code(ctx, "terminal-widgets-projects-code")
    _drop_projects(c, (PROJ_ROOT,))
    r = c.api("POST", "/api/projects", {"kind": "new", "folder": PROJ_ROOT, "name": PROJ_NAME, "git": False})
    expect(r["status"] == 200, f"the Code project: {r['status']} {r['text'][:200]}")
    page, rec = open_terminal(ctx, "terminal-widgets-projects")
    try:
        customize(page)
        add_back(page, "projects")
        page.wait_for_selector(".tp-proj")
        names = page.eval_on_selector_all(".tp-proj", "els => els.map((e) => e.dataset.path)")
        expect(names and names[0] == "/workspace", f"the project list {names}")
        # the Code page's project is listed by its name, with its folder, and the "none yet" note is not shown
        rows = wait_panel(page, f"no row for {PROJ_PATH} named {PROJ_NAME}", lambda rs: any(x["path"] == PROJ_PATH and x["name"] == PROJ_NAME for x in rs))
        names = [x["path"] for x in rows]
        expect(not panel_note(page).startswith("No project"), f"a false 'No project folders' note: {panel_note(page)!r}")
        expect(len(set(names)) == len(names), f"a folder listed twice {names}")
        every = page.eval_on_selector_all(".tp-open-shell", "els => els.map((b) => [b.getAttribute('aria-label'), b.getBoundingClientRect().height])")
        expect(all(a and a.startswith("Open a shell in ") for a, _ in every), f"unnamed buttons {every}")
        target = PROJ_PATH
        page.click(f".tp-open-shell[data-path='{target}']")
        page.wait_for_function("(p) => /arg=open&arg=shell&arg=/.test(document.querySelector('iframe[data-app=terminal]').src) && (p === '/workspace' || document.querySelector('iframe[data-app=terminal]').src.endsWith(encodeURIComponent(p)))",
                               arg=target, timeout=15000)
        f = view_frame(page, 1)
        t0 = time.time()
        while "arg=open" not in f.url and time.time() - t0 < 15:   # (until then it is the old page, about to go)
            page.wait_for_timeout(200)
        wait_xterm(f)
        wait_text(f, r"\$ ?$", 20)
        run_in(page, 1, "echo cwd=$(pwd)")
        wait_text(f, rf"^cwd={re.escape(target)}$", 20)
        shot(page, "terminal-widgets-projects")
        rec.save()
    finally:
        reset_layout(page)
        try:
            _drop_projects(Code(ctx, "terminal-widgets-projects-clean"), (PROJ_ROOT,))
        except Exception:  # noqa: BLE001 — tidying never hides the failure
            pass
    return f"projects: the workspace, the Code page's project {PROJ_NAME} (by name) and the known project folders listed; Open a shell here ({target}) opens a shell window there in view 1"


@check("browser", "terminal-projects-follow-the-code-page")
def projects_follow_code(ctx):
    """JON-1158: the Terminal page's Projects widget is the Code page's list (one source), not a list of its own: a rename shows with the
    same folder, a removed record goes, every project of the Code page is a row, and with no list from Code (Code off) the widget falls back
    to the workspace and the folders of this computer with a note that is true."""
    need_on()
    from checks_code import Code, _drop_projects
    c = Code(ctx, "terminal-projects-follow-code")
    _drop_projects(c, (PROJ_ROOT,))
    r = c.api("POST", "/api/projects", {"kind": "new", "folder": PROJ_ROOT, "name": PROJ_NAME, "git": False})
    expect(r["status"] == 200, f"the Code project: {r['status']} {r['text'][:200]}")
    pid = r["json"]["project"]["id"]
    # (the Code page's own list, as the Code page has it: every project of the workspace that is not gone)
    listed = c.api("GET", "/api/projects")["json"]["projects"]
    code_paths = {x["path"] for x in listed if not x.get("host") and not x.get("gone") and not x.get("workspace")}
    expect(PROJ_PATH in code_paths, f"the project is not in the Code page's list {code_paths}")
    # a second browser for the Terminal tab (a person has both open): the Code client stays where it was
    from checks_journeys import extra_page
    tp, trec = extra_page(ctx, "terminal-projects-follow-code-term")
    login(tp)
    tp.click(".tab[data-tab=terminal]")
    f = terminal_frame(tp)
    if f.locator("h1", has_text="Unlock the terminal").count() or f.locator("#password").count():
        unlock_in(f, ENV["PORTAL_PASSWORD"])
    try:
        show_projects_widget(tp)
        rows = wait_panel(tp, f"{PROJ_PATH} is not listed", lambda rs: any(x["path"] == PROJ_PATH for x in rs))
        # one source: every project of the Code page is a row, and the row for each is named as the Code page names it
        by_path = {x["path"]: x for x in rows}
        expect(code_paths <= set(by_path), f"Code page projects missing from the panel: {sorted(code_paths - set(by_path))}")
        expect(by_path[PROJ_PATH]["name"] == PROJ_NAME and by_path[PROJ_PATH]["id"] == pid, f"the row {by_path[PROJ_PATH]}")
        shot(tp, "terminal-projects-follow-code-1")
        # a rename on the Code page: the panel shows the new name, the same folder
        renamed = PROJ_NAME + "-renamed"
        expect(c.api("POST", f"/api/projects/{pid}", {"name": renamed})["status"] == 200, "rename")
        rows = wait_panel(tp, "the new name is not shown", lambda rs: any(x["path"] == PROJ_PATH and x["name"] == renamed for x in rs))
        expect(sum(1 for x in rows if x["id"] == pid) == 1, f"the renamed project twice {rows}")
        # the record removed (the folder stays): the row goes (or, if the Code page still lists the folder, it is marked missing)
        expect(c.api("DELETE", f"/api/projects/{pid}")["status"] == 200, "remove")
        wait_panel(tp, "the removed project is still listed", lambda rs: not any(x["path"] == PROJ_PATH and not x["gone"] for x in rs))
        # no list from Code (Code off, or the code container has not written it): the workspace and the folders of this computer, and the note
        # says so: the portal's answer without its `projects` field, as it is then
        tp.route("**/api/answers*", _answers_without_projects)
        rows = wait_panel(tp, "no fallback list", lambda rs: bool(rs) and rs[0]["path"] == "/workspace" and all(x["path"] != PROJ_PATH for x in rs))
        note = panel_note(tp)
        expect("Code page is off" in note, f"the note without Code's list: {note!r}")
        expect(not note.startswith("No project folders"), f"the old false note: {note!r}")
        shot(tp, "terminal-projects-follow-code-2")
        problems = [x for x in trec.problems(allow=LOCKED_OK + PANEL_ALLOW) if x.startswith("pageerror") or x.startswith("console.error")]
        trec.save()
        expect(not problems, f"errors on the Terminal page: {problems[:5]}")
    finally:
        try:
            tp.unroute("**/api/answers*")
            reset_layout(tp)
            _drop_projects(c, (PROJ_ROOT,))
            c.api("DELETE", f"/api/fs?path={PROJ_ROOT}")
        except Exception:  # noqa: BLE001 — tidying never hides the failure
            pass
    return "Terminal Projects widget: every Code page project is a row (named as there); a rename shows with the same folder; a removed record's row goes; with no list from Code it falls back to the workspace and the computer's folders with a note that says so, no JS error"


def _answers_without_projects(route):
    """The portal's /api/answers as it is while Code is off (or has not written its list): the same JSON without `projects`."""
    resp = route.fetch()
    try:
        d = resp.json()
        d.pop("projects", None)
        route.fulfill(response=resp, json=d)
    except Exception:  # noqa: BLE001 — not JSON (a 401, a 429): pass it on as it is
        route.fulfill(response=resp)


@check("browser", "terminal-widgets-keyboard-only")
def widgets_keyboard(ctx):
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-kbd")
    try:
        page.focus("#term-customize")
        page.keyboard.press("Enter")
        page.wait_for_selector("#term-tray:not([hidden])")
        expect(page.evaluate("() => document.activeElement.id") == "term-tray-title", "the tray's title does not take the focus")
        # Add back the key bar from the tray with the keyboard, move it above the terminals, hide it again
        page.focus("#term-hidden [data-id=keys]")
        page.keyboard.press("Enter")
        page.wait_for_selector("[data-widget=keys]:not([hidden])")
        expect("added back" in say_live(page), f"live region: {say_live(page)!r}")
        page.focus("[data-widget=keys] [data-act=up]")
        page.keyboard.press("Enter")
        expect("moved" in say_live(page), f"live region: {say_live(page)!r}")
        expect(page.evaluate("() => document.activeElement.getAttribute('data-act')") == "up", "the focus left the Move up button")
        order = page.eval_on_selector_all("#term-grid > [data-widget]", "els => els.map((e) => e.dataset.widget)")
        expect(order[0] == "keys", f"the order {order}")
        # a visible focus ring on a bar button (outline), and every control of the bars has a name
        ring = page.evaluate("() => { const s = getComputedStyle(document.activeElement); return [s.outlineStyle, s.outlineWidth]; }")
        expect(ring[0] != "none" and ring[1] != "0px", f"no focus ring on a focused bar button: {ring}")
        unnamed = page.eval_on_selector_all("#term-page button, #term-page [role=separator]", "els => els.filter((b) => !(b.getAttribute('aria-label') || b.textContent.trim())).map((b) => b.className)")
        expect(not unnamed, f"controls without a name: {unnamed}")
        # a divider between two terminals moves with the arrow keys
        page.evaluate(FOCUS_LOG)
        page.focus("#term-add")
        page.keyboard.press("Enter")
        page.wait_for_selector(".tp-div")
        # (ttyd focuses its terminal as it connects: the new view gives the keyboard back to Add a terminal)
        f2 = view_frame(page, 2)
        wait_xterm(f2)
        page.wait_for_timeout(800)
        expect(page.evaluate("() => document.activeElement.id") == "term-add", f"the new terminal took the keyboard as it connected: {page.evaluate(FOCUS_SEEN)}")
        page.focus(".tp-div")
        before = int(page.get_attribute(".tp-div", "aria-valuenow"))
        page.keyboard.press("ArrowRight")
        after = int(page.get_attribute(".tp-div", "aria-valuenow"))
        expect(after == before + 5, f"the divider went {before} → {after}")
        expect(page.evaluate("() => document.activeElement.classList.contains('tp-div')"), f"the divider lost the focus when it moved: {page.evaluate(FOCUS_SEEN)}")
        # a key button used with the keyboard keeps the focus on the button (a keyboard user is not shut in the terminal)
        page.focus("[data-key=esc]")
        page.keyboard.press("Enter")
        expect(page.evaluate("() => document.activeElement.getAttribute('data-key')") == "esc", f"the Esc button gave the focus away: {page.evaluate(FOCUS_SEEN)}")
        # Escape leaves Customize and gives the focus back to its button
        page.focus("#term-done")
        page.keyboard.press("Escape")
        page.wait_for_selector("#term-tray", state="hidden")
        expect(page.evaluate("() => document.activeElement.id") == "term-customize", "the focus did not return to Customize")
        rec.save()
    finally:
        reset_layout(page)
    return "keyboard alone: Customize with Enter, Add back, Move up (announced), divider arrows, key buttons keep the focus, Escape returns it; every control named; visible focus ring"


@check("browser", "terminal-widgets-nothing-overlaps-or-is-clipped")
def widgets_layout(ctx):
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-layout")
    try:
        customize(page)
        for wid in ("keys", "commands", "projects"):
            add_back(page, wid)
        for n in (2, 3, 4):
            add_terminal(page, n)
        page.click("[data-split=grid]")
        for width, height in ((1440, 900), (1100, 800), (900, 800)):
            page.set_viewport_size({"width": width, "height": height})
            page.wait_for_timeout(900)
            expect(page.evaluate("() => [document.querySelector('.stage').scrollTop, document.querySelector('.stage').scrollLeft]") == [0, 0], f"{width}: the stage was scrolled")
            boxes = page.evaluate(BOXES)
            for b in boxes:
                expect(b["frame"] and all(abs(a - c) <= 2 for a, c in zip(b["slot"], b["frame"])), f"{width}: view {b['view']}'s frame is off its slot: {b}")
            for i, a in enumerate(boxes):
                for b in boxes[i + 1:]:
                    ax, ay, aw, ah = a["frame"]; bx, by, bw, bh = b["frame"]
                    expect(ax + aw <= bx + 1 or bx + bw <= ax + 1 or ay + ah <= by + 1 or by + bh <= ay + 1, f"{width}: frames {a['view']} and {b['view']} overlap")
            # a widget never overlaps another one or the terminals' frames, nothing is wider than the page
            rects = page.evaluate("""() => [...document.querySelectorAll('#term-grid > [data-widget]')].filter((w) => !w.hidden).map((w) => {
              const r = w.getBoundingClientRect(); return {id: w.dataset.widget, box: [r.left, r.top, r.width, r.height], over: w.scrollWidth > w.clientWidth + 1};
            })""")
            for i, a in enumerate(rects):
                expect(not a["over"], f"{width}: {a['id']} is wider than its box (clipped)")
                for b in rects[i + 1:]:
                    ax, ay, aw, ah = a["box"]; bx, by, bw, bh = b["box"]
                    expect(ax + aw <= bx + 1 or bx + bw <= ax + 1 or ay + ah <= by + 1 or by + bh <= ay + 1, f"{width}: {a['id']} and {b['id']} overlap")
            expect(page.evaluate("() => document.documentElement.scrollWidth <= innerWidth + 1 && document.querySelector('#term-page').scrollWidth <= document.querySelector('#term-page').clientWidth + 1"),
                   f"{width}: the page scrolls sideways")
            shot(page, f"terminal-widgets-layout-{width}")
        rec.save()
    finally:
        page.set_viewport_size({"width": 1280, "height": 800})
        reset_layout(page)
    return "all widgets and four terminals at 1440 and 1100 px, the tablet's own arrangement at 900: every frame over its slot, no two frames or widgets overlap, nothing clipped, no sideways scroll, the stage never scrolled"


@check("browser", "terminal-widgets-phone-and-desktop-stay-apart")
def widgets_phone(ctx):
    need_on()
    page, rec = open_terminal(ctx, "terminal-widgets-phone", "phone")
    try:
        # a phone reaches the Terminal from More, as a tab of the portal: one terminal, the key bar on, one column
        expect(page.locator("#term-page").is_visible(), "no widget page on a phone (the key bar is on by default)")
        expect(page.locator("[data-widget=keys]").is_visible() and page.locator("[data-widget=commands]").is_hidden(), "a phone starts with the terminal and the key bar")
        expect(page.locator("#term-add").is_hidden() or page.locator("#term-add").is_disabled(), "Add a terminal on a phone")
        expect(page.locator(".tp-pane").count() == 1, "more than one terminal on a phone")
        frame = page.locator("iframe[data-app=terminal]").bounding_box()
        stage = page.locator(".stage").bounding_box()
        expect(frame["width"] >= stage["width"] - 24 and frame["y"] + frame["height"] <= stage["y"] + stage["height"] + 1, f"the terminal frame is {frame} in the stage {stage}")
        keys = page.eval_on_selector_all("[data-widget=keys] .tp-key", "els => els.map((b) => { const r = b.getBoundingClientRect(); return [r.width, r.height]; })")
        expect(all(w >= 44 and h >= 44 for w, h in keys), f"key bar targets under 44 px: {[k for k in keys if k[0] < 44 or k[1] < 44]}")
        expect(page.evaluate("() => document.documentElement.scrollWidth <= innerWidth + 1"), "the phone's page scrolls sideways")
        shot(page, "terminal-widgets-phone")
        # a key button reaches the terminal (the first window is Claude Code's: Ctrl-b c makes a shell window)
        f = terminal_frame(page)
        page.click("[data-key=ctrl-b]")
        f.locator(".xterm-helper-textarea").focus()
        page.keyboard.press("c")
        wait_text(f, r"^terminal /workspace \$", 15)
        # customize with Move up / Move down at 44 px (no resize edge, no width buttons), hide the key bar: kept for the phone only
        customize(page)
        for sel in ("[data-widget=keys] [data-act=up]", "[data-widget=keys] [data-act=down]", "[data-widget=keys] [data-act=hide]"):
            b = page.locator(sel).bounding_box()
            expect(b and b["width"] >= 44 and b["height"] >= 44, f"{sel} is {b}")
        expect(page.locator("[data-widget=keys] [data-act=wide]").is_hidden(), "width buttons on a phone")
        page.click("[data-widget=keys] [data-act=hide]")
        page.wait_for_selector("[data-widget=keys]", state="hidden")
        got = None
        for _ in range(40):
            got = saved_terminal(page).get("phone")
            if got and any(e["id"] == "keys" and e["hidden"] for e in got["widgets"]):
                break
            page.wait_for_timeout(250)
        expect(got and got["views"] == 1, f"the phone's layout was not kept: {got}")
        expect("desktop" not in saved_terminal(page) and "tablet" not in saved_terminal(page), f"the phone's save touched another screen: {saved_terminal(page)}")
        rec.save()
    finally:
        reset_layout(page)
    return "phone: More → Terminal; one terminal and the key bar on, one column, 44 px targets, a key reaches the terminal; hiding the key bar is kept for the phone alone"


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
    login(page)   # signed in again: the old unlock is void; locally the new session auto-unlocks (JON-1140)
    page.goto(TERM + "/")
    page.wait_for_load_state()
    expect("/login" not in page.url and page.locator("form[action='/.bn/unlock'] #password").count() == 0,
           f"terminal auto-unlocked after re-login → {page.url}")
    rec.save()
    ctx.reset_session()
    return "Sign out → the terminal host sends you to the login; signed in again, the new session unlocks it (no second password)"
