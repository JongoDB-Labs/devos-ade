"""Your AI subscriptions (README "Your AI subscriptions"; portal/portal/answers.py, static/answers.js): the pickers'
JSON lists the six tools of the sandbox, none signed in, and never a login; Settings › Claude Code › Your AI
subscriptions lists them; the walkthrough's step renders. With E2E_SUBSCRIPTIONS=1 (tests/e2e/run.sh --subscriptions)
also: the Terminal tab's Open menu starts Codex in a window of its own — at its own device-code sign-in, which prints its
link and code and is never completed — and Chat's Who answers shows Grok Build itself in place of Open WebUI (at its
own sign-in: a link and a code, never completed), then Open WebUI again. No sign-in is ever finished here."""

from __future__ import annotations

import base64
import json
import os
import re
import socket

from common import ENV, HOST, PORT, TARGET_IP, Skip, check, expect, http
from checks_browser import login, shot
from checks_terminal import TERM, LOCKED_OK, terminal_frame, unlock_cookie, unlock_in, wait_text, wait_xterm

ON = ENV.get("TERMINAL_ENABLED") == "true"
FULL = os.environ.get("E2E_SUBSCRIPTIONS") == "1"
TOOLS = ["claude", "codex", "gemini", "copilot", "cursor", "grok"]
H = {"X-Requested-With": "bedrock-now"}
# the device-code sign-in a tool not signed in starts with (its own text)
CODEX_SIGNIN = r"auth\.openai\.com/codex/device"
GROK_SIGNIN = r"x\.ai/oauth2/device"


def need_on():
    if not ON:
        raise Skip("the terminal is off in this throwaway: no AI tools")


@check("http", "subscriptions-answers")
def answers_api(ctx):
    need_on()
    expect(http("GET", None, "/api/answers", H).status == 401, "/api/answers without a session")
    r = http("GET", None, "/api/answers", H, cookie=ctx.session())
    expect(r.status == 200, f"/api/answers: HTTP {r.status}")
    d = json.loads(r.body)
    expect([t["id"] for t in d["tools"]] == TOOLS, f"tools {[t['id'] for t in d['tools']]}")
    expect(d["terminal"] == {"enabled": True, "here": True}, f"terminal {d['terminal']}")
    expect(all(t["signed_in"] != "yes" for t in d["tools"]), "a tool says it is signed in in a fresh throwaway")
    if d["checked_at"]:
        expect(all(t["installed"] is True and t["version"] for t in d["tools"]), f"not every tool is in the sandbox: {d['tools']}")
    body = r.body.decode("utf-8", "replace")
    for bad in ("sk-ant-", "sk-proj-", "gho_", "ghp_", "refresh_token", "access_token"):
        expect(bad not in body, f"{bad} in /api/answers")
    return f"{len(d['tools'])} tools, checked {'yes' if d['checked_at'] else 'not yet'}: " + \
        ", ".join(f"{t['id']} {t['version'] or '?'} {t['signed_in']}" for t in d["tools"])


@check("browser", "subscriptions-settings-row")
def settings_row(ctx):
    need_on()
    page, rec = ctx.page("subscriptions-settings")
    login(page)
    page.goto(page.url.split("#")[0] + "#settings/+subscriptions")
    row = page.locator("#set-row-subscriptions")
    row.wait_for(timeout=20000)
    items = page.locator("#set-subscriptions li[data-tool]")
    expect(items.count() == len(TOOLS), f"{items.count()} tools listed")
    text = row.inner_text()
    for words in ("Your AI subscriptions", "Codex", "Grok Build", "Check again", "bedrock-now never opens it", "./stack subscriptions"):
        expect(words in text, f"the row lacks {words!r}")
    shot(page, "s1-settings-subscriptions")
    probs = rec.problems()
    rec.save()
    expect(not probs, f"errors: {probs[:6]}")
    return "Settings › Claude Code › Your AI subscriptions: six tools, Check again, ./stack subscriptions"


@check("browser", "walkthrough-subscriptions")
def walkthrough_step(ctx):
    page, rec = ctx.page("walkthrough-subscriptions", tour=True)
    login(page)
    page.wait_for_selector("#tour:not([hidden]) #tour-cur", timeout=15000)
    page.evaluate("() => window.bnTour.open('subscriptions')")
    page.locator("#tour .tour-step.cur", has_text="Your AI subscriptions and keys").wait_for(timeout=10000)
    card = page.inner_text("#tour .tour-step.cur")
    for words in ("claude-sub", "Codex", "Copilot", "Cursor", "Grok", "Gemini CLI", "device code login", "bedrock-now never sees it",
                  "backups leave it out", "Who answers", "a model in Open WebUI's menu", "your own API keys"):
        expect(words in card, f"the step lacks {words!r}")
    shot(page, "s2-walkthrough-subscriptions")
    probs = rec.problems()
    rec.save()
    expect(not probs, f"errors: {probs[:6]}")
    return "the walkthrough's Your AI subscriptions and keys step"


@check("browser", "subscriptions-terminal-open")
def terminal_open(ctx):
    need_on()
    if not FULL:
        raise Skip("only with tests/e2e/run.sh --subscriptions (it starts Codex's own sign-in: a request to OpenAI)")
    page, rec = ctx.page("subscriptions-terminal")
    login(page)
    page.click(".tab[data-tab=terminal]")
    f = terminal_frame(page)
    unlock_in(f, ENV["PORTAL_PASSWORD"])
    wait_xterm(terminal_frame(page))
    bar = page.locator("#answers-bar")
    bar.wait_for(timeout=10000)
    values = page.eval_on_selector_all("#answers-terminal option", "os => os.map(o => o.value)")
    expect(values == ["bedrock", "shell"] + TOOLS, f"the Open menu offers {values}")
    page.select_option("#answers-terminal", "codex")
    page.click("#answers-terminal-open")
    # (a launch token the portal made on this click: <iat>-<16 hex>-<32 hex>)
    page.wait_for_function("() => /[?&]arg=open&arg=codex&arg=[0-9]{10}-[0-9a-f]{16}-[0-9a-f]{32}$/.test(document.querySelector('iframe[data-app=terminal]').src)", timeout=15000)
    f = terminal_frame(page)
    wait_xterm(f)
    screen = wait_text(f, CODEX_SIGNIN, 60)
    expect(re.search(r"\bcodex\b", screen), "no codex window in tmux's status line")
    shot(page, "s3-terminal-open-codex")
    probs = rec.problems(allow=LOCKED_OK)
    rec.save()
    expect(not probs, f"errors: {probs[:6]}")
    return "Open › Codex: a window of its own, at Codex's own device-code sign-in (its link shown, never completed)"


def tool_frame(page, timeout_s=30):
    """The Chat tab's frame of the tool, once it has the terminal's address with the Chat words (answers.js sets its src
    and unhides it in one go: for a moment it is still about:blank)."""
    for _ in range(timeout_s * 5):
        f = next((fr for fr in page.frames if fr.url.startswith(TERM) and "arg=chat" in fr.url), None)
        if f is not None:
            return f
        page.wait_for_timeout(200)
    raise AssertionError(f"no frame of the tool at the terminal's address: {[fr.url[:80] for fr in page.frames]}")


@check("browser", "subscriptions-chat-embed")
def chat_embed(ctx):
    need_on()
    if not FULL:
        raise Skip("only with tests/e2e/run.sh --subscriptions (it starts Grok Build's own sign-in: a request to xAI)")
    page, rec = ctx.page("subscriptions-chat")
    login(page)
    page.click(".tab[data-tab=chat]")
    page.locator("#answers-chat").wait_for(timeout=15000)
    opts = page.eval_on_selector_all("#answers-chat option", "os => os.map(o => [o.value, o.disabled])")
    vals = dict(opts)
    expect(vals.get("owui") is False, "no Open WebUI entry")
    expect(any(v.startswith("model:") and not d for v, d in opts), "no Bedrock model entry")
    expect(all(vals.get(f"tool:{t}") is False for t in TOOLS), f"the tools are not all offered: {opts}")
    # as Chat models: each the catalog offers as one, greyed until it can answer (none signed in; Claude: its switch off) —
    # Copilot, which cannot say, listed; Gemini CLI planned through your own key
    for t in ("claude", "codex", "cursor", "grok"):
        expect(vals.get(f"model:plan-{t}") is True, f"{t} as a Chat model is not greyed out (not signed in): {opts}")
    expect(vals.get("model:plan-copilot") is False, f"Copilot as a Chat model is not listed: {opts}")
    expect(vals.get("as-model:gemini") is True, f"Gemini CLI as a Chat model is not greyed out (planned): {opts}")
    page.select_option("#answers-chat", "tool:grok")
    page.wait_for_selector("iframe[data-app=chat-tool]:not([hidden])", timeout=10000)
    expect(page.locator("iframe[data-app=chat]").is_hidden(), "Open WebUI still shows with a tool chosen")
    f = tool_frame(page)
    unlock_in(f, ENV["PORTAL_PASSWORD"])
    f = tool_frame(page)
    f.locator(".xterm").wait_for(timeout=30000)
    wait_text(f, GROK_SIGNIN, 60)
    note = page.inner_text("#answers-chat-note")
    expect("Grok Build itself" in note and "never sees it" in note, f"the note says {note!r}")
    shot(page, "s4-chat-embedded-grok")
    page.select_option("#answers-chat", "owui")
    page.wait_for_selector("iframe[data-app=chat]:not([hidden])", timeout=10000)
    expect(page.locator("iframe[data-app=chat-tool]").is_hidden(), "the tool still shows after choosing Open WebUI")
    probs = rec.problems(allow=LOCKED_OK + [r"^401 GET " + re.escape(TERM) + r"/\?arg="])
    rec.save()
    expect(not probs, f"errors: {probs[:6]}")
    return "Chat › Who answers › Grok Build: the tool itself in place of Open WebUI (unlocked in place, at its own device-code sign-in), then Open WebUI again"


def ws_status(cookie: str, path: str) -> int:
    """ttyd's WebSocket handshake at PATH through Caddy, from the terminal's own Origin: the HTTP status only."""
    key = base64.b64encode(os.urandom(16)).decode()
    lines = [f"GET {path} HTTP/1.1", f"Host: terminal.{HOST}:{PORT}", "Upgrade: websocket", "Connection: Upgrade",
             "Sec-WebSocket-Version: 13", f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Protocol: tty", f"Cookie: {cookie}",
             f"Origin: {TERM}"]
    s = socket.create_connection((TARGET_IP, PORT), timeout=15)
    try:
        s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = s.recv(1024).decode("latin-1")
    finally:
        s.close()
    m = re.match(r"HTTP/1\.[01] (\d{3})", head)
    return int(m.group(1)) if m else 0


@check("http", "subscriptions-a-link-alone-starts-nothing")
def link_alone(ctx):
    """An address with the pickers' words and no launch token made on a click — a link from anywhere — starts nothing:
    the terminal host asks "Open … here?" (its own form), and the WebSocket that would start the tool is refused."""
    need_on()
    sess = ctx.session()
    unlock = unlock_cookie(sess).split(";", 1)[0]
    cookie = f"{sess}; {unlock}"
    fake = "1792760000-0123456789abcdef-" + "0" * 32
    r = http("GET", "terminal", f"/?arg=open&arg=shell&arg={fake}", {"Accept": "text/html"}, cookie=cookie)
    expect(r.status == 403 and "Open A shell here?" in r.text and 'action="/.bn/launch"' in r.text, f"HTTP {r.status}: {r.text[:200]!r}")
    for path in (f"/ws?arg=open&arg=shell&arg={fake}", f"/ws?x=1;arg=open;arg=shell;arg={fake}", "/ws?arg%3Dopen&arg%3Dshell&arg%3D" + fake):
        expect(ws_status(cookie, path) == 403, f"WebSocket {path}: not refused")
    expect(ws_status(cookie, "/ws") == 101, "the plain WebSocket no longer opens")
    # a token made on a click (the portal's own page): its words open
    r = http("POST", None, "/api/terminal/launch", {"X-Requested-With": "bedrock-now", "Content-Type": "application/json", "Origin": origin_portal()},
             json.dumps({"mode": "open", "tool": "shell"}), cookie=sess)
    expect(r.status == 200, f"/api/terminal/launch: HTTP {r.status}")
    url = json.loads(r.body)["url"]
    expect(ws_status(cookie, "/ws" + url.split(TERM, 1)[1][1:]) == 101, "a launch token made on a click does not open")
    return "a link alone: the question page, its WebSockets refused (also ;-separated and %-encoded words); with a token from a click: open"


def origin_portal() -> str:
    from common import origin
    return origin()


@check("browser", "subscriptions-code-harness")
def code_harness(ctx):
    """The Code page's Who answers: the subscriptions listed with whether each can start (none signed in here); a Copilot
    session started for real — Copilot's own ACP mode in the sandbox, in the project's folder — ends at its sign-in
    ("not signed in", its own sign-in in the terminal); Claude on your plan refused while its switch is off; the picker
    shows them greyed with why."""
    need_on()
    if not FULL:
        raise Skip("only with tests/e2e/run.sh --subscriptions (it starts the tools' own agents in the sandbox)")
    if ENV.get("CODE_ENABLED") != "true":
        raise Skip("the Code page is off in this throwaway")
    from checks_code import Code, ui_page
    from playwright.sync_api import expect as see
    c = Code(ctx, "subscriptions-code-harness")
    r = c.api("GET", "/api/harnesses?fresh=1")
    expect(r["status"] == 200, f"/api/harnesses: {r}")
    hs = {h["id"]: h for h in r["json"]["harnesses"]}
    expect(list(hs) == ["claude", "codex", "copilot", "cursor", "grok"], f"harnesses {list(hs)}")
    expect(hs["codex"]["signed"] == "no" and hs["copilot"]["signed"] == "unknown" and hs["claude"]["allowed"] is False, f"{hs}")
    r = c.api("POST", "/api/sessions", {"harness": "claude", "mode": "default"})
    expect(r["status"] == 409 and "Claude on your plan is off" in json.dumps(r["json"]), f"Claude on your plan: {r}")
    r = c.api("POST", "/api/sessions", {"harness": "copilot", "mode": "default"})
    expect(r["status"] == 200, f"a Copilot session: {r}")
    sid = r["json"]["id"]
    c.send({"type": "attach", "session": sid, "since": 0})
    st = c.wait(lambda m: m.get("type") == "session_state" and m.get("session") == sid and m.get("state") == "ended", "the Copilot session's end", 120)
    expect("GitHub Copilot is not signed in in the sandbox" in (st.get("error") or ""), f"its state: {st}")
    expect(st.get("harness") == "copilot", f"its harness: {st}")
    # the picker: Who answers, each subscription with whether it can start
    page, rec = ui_page(ctx, "subscriptions-code-picker")
    page.get_by_test_id("model-picker").click()
    group = page.get_by_test_id("who-answers")
    see(group).to_be_visible(timeout=10000)
    see(page.get_by_test_id("harness-codex")).to_contain_text("sign in first")
    see(page.get_by_test_id("harness-claude")).to_contain_text("off")
    shot(page, "s5-code-who-answers")
    page.keyboard.press("Escape")
    return "Who answers: five subscriptions listed (none signed in); Copilot's real ACP agent started and ended at \"not signed in\"; Claude on your plan off (409)"
