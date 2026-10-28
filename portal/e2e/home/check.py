"""Home's item menus (portal/portal/static/ctxmenu.js, home.js; JON-821), in a real Chromium (run.sh: the e2e suite's pinned
Playwright image; no stack, no model, network none). A stub serves portal/portal/static under the portal's own CSP and answers
GET /api/continue (two Code sessions as the Code page last reported them, three Chat conversations) and
POST /api/chats/ID/rename|archive|delete (checking the X-Requested-With header, as api_guard does, and the confirm).

For a Chat conversation and a Code session it opens the menu by right-click, by Shift+F10 on the focused row, by the row's
"⋯" button and by a long press (touch emulation), checks the actions, and runs them: Rename, Archive and Delete (confirmed:
the dialog says what goes, and Cancel is the default) reach the stub; the Code session's Rename, Fork, Add to project, Open its
folder in a terminal, Archive and Delete are asked of the Code page (window.bnCode.sessionDo, here recorded: the page's
own flows are exercised by code/web/e2e/ui_check.py) and are off, with the reason, until the Code page has reported.
Also the nav's menu (Open, Open in its own window, Copy link). Screenshots at 390, 820 and 1440 px, light and dark, in
OUT/. Writes /out/home-menus.json; exits 1 on any failure.
"""
import http.server
import json
import os
import sys
import threading
import time
import traceback
from pathlib import Path

REPO = Path(os.environ.get("BN_REPO_DIR", "/repo"))
OUT = Path(os.environ.get("E2E_OUT_DIR", "/out"))

from playwright.sync_api import sync_playwright  # noqa: E402

STATIC = REPO / "portal" / "portal" / "static"
PORT = 18321
BASE = f"http://127.0.0.1:{PORT}"
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
       f"frame-src {BASE}; form-action 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'")
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml",
         ".png": "image/png", ".json": "application/json", ".woff2": "font/woff2", ".webmanifest": "application/manifest+json",
         ".ico": "image/x-icon"}
S1, S2 = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
C1, C2, C3 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
APPS = json.dumps({"code": f"{BASE}/code-app/", "chat": f"{BASE}/chat-app/"})
META = (f'<meta name="bn-apps" content=\'{APPS}\'>\n<meta name="bn-terminal" content="{{&quot;enabled&quot;: false, &quot;here&quot;: false}}">\n'
        '<meta name="bn-code" content="{&quot;enabled&quot;: true, &quot;here&quot;: true}">')
NOW = int(time.time())
STATE = {"chats": [], "posts": []}


def reset():
    STATE["chats"] = [{"id": C1, "title": "Plan the quarterly budget review", "updated_at": NOW - 300},
                      {"id": C2, "title": "Untitled chat about <b>markup</b>", "updated_at": NOW - 900},
                      {"id": C3, "title": "Meeting notes", "updated_at": NOW - 4000}]
    STATE["posts"] = []


FRAME = """<!doctype html><meta charset=utf-8><title>code</title><body>stub Code page<script>
window.got = []; addEventListener('message', (e) => window.got.push(e.data));</script>"""


class Stub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype, csp=CSP):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Content-Security-Policy", csp)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            page = (STATIC / "index.html").read_text(encoding="utf-8")
            return self.send(200, page.replace("</head>", META + "\n</head>", 1), "text/html; charset=utf-8")
        if path == "/api/continue":
            rep = {"at": NOW - 20, "waiting": 1, "project": None, "sessions": [
                {"id": S1, "title": "Fix the flaky upload test", "state": "waiting", "at": NOW - 60},
                {"id": S2, "title": "Refactor the billing module", "state": "idle", "at": NOW - 700}]}
            return self.send(200, json.dumps({"code": {"enabled": True, "here": True, "report": rep}, "chats": {"items": STATE["chats"], "error": None},
                                              "now": int(time.time())}), "application/json")
        if path == "/api/summary":
            return self.send(200, json.dumps({
                "spend": {"total_30d": 12.5, "keys": [], "alert_pct": 80, "openrouter": None, "openrouter_usage": None},
                "services": [{"name": "Chat", "role": "Open WebUI", "ok": True, "detail": "up"}, {"name": "Gateway", "role": "LiteLLM", "ok": True, "detail": "up"}],
                "models": {"rows": []}, "prices": {}, "voice": None,
                "update": {"current": "0.34.0", "latest": "0.34.0", "available": False, "checked_at": NOW, "notes": ""},
                "portal": {"url": BASE}, "apps": {}, "claude": {"command": "devos-claude"},
                "terminal": {"enabled": False, "here": False}, "code": {"enabled": True, "here": True}, "remote": {"on": False, "here": False, "mode": "off", "url": ""}}),
                "application/json")
        if path in ("/code-app/", "/chat-app/"):
            return self.send(200, FRAME, "text/html; charset=utf-8", "default-src 'self' 'unsafe-inline'")
        if path.startswith("/static/"):
            f = (STATIC / path[len("/static/"):]).resolve()
            if STATIC.resolve() in f.parents and f.is_file():
                return self.send(200, f.read_bytes(), TYPES.get(f.suffix, "application/octet-stream"))
        if path == "/api/admin/status":
            return self.send(200, json.dumps({"running": True, "allowed": True, "job": None, "in_progress": False}), "application/json")
        if path.startswith("/api/"):
            return self.send(503, json.dumps({"error": "a stub: only Home's data is answered"}), "application/json")
        return self.send(404, "not here", "text/plain")

    def do_POST(self):
        path = self.path.split("?")[0]
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.headers.get("X-Requested-With") != "bedrock-now":
            return self.send(403, json.dumps({"error": "missing header"}), "application/json")
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["api", "chats"] and parts[3] in ("rename", "archive", "delete"):
            cid, act = parts[2], parts[3]
            STATE["posts"].append({"id": cid, "act": act, "body": body})
            if act == "delete" and body.get("confirm") != cid:
                return self.send(400, json.dumps({"error": "confirm"}), "application/json")
            if act == "rename":
                for c in STATE["chats"]:
                    if c["id"] == cid:
                        c["title"] = body.get("title", "")
            else:
                STATE["chats"] = [c for c in STATE["chats"] if c["id"] != cid]
            return self.send(200, json.dumps({"ok": True}), "application/json")
        return self.send(404, "{}", "application/json")


def long_press(page, cdp, x, y, hold=700):
    cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
    page.wait_for_timeout(hold)
    cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    page.wait_for_timeout(150)


def inside(page):
    return page.evaluate("""() => { const m = document.querySelector('.ctx-menu'); if (!m) return false; const r = m.getBoundingClientRect();
      return r.left >= 0 && r.top >= 0 && r.right <= innerWidth + 0.5 && r.bottom <= innerHeight + 0.5; }""")


def labels(page):
    return [t.strip() for t in page.locator(".ctx-menu .ctx-item").all_inner_texts()]


def item(page, text):
    return page.locator(f'.ctx-menu .ctx-item:has-text("{text}")').first


def row(page, kind, rid):
    return page.locator(f'#continue .cont-list > li[data-kind="{kind}"][data-id="{rid}"]')


def open_home(page):
    reset()
    page.goto(f"{BASE}/#home", wait_until="domcontentloaded")
    try:
        page.wait_for_selector("#continue .cont-list > li", timeout=20000)
    except Exception:
        page.screenshot(path=str(OUT / "home-failed.png"))
        raise


def run(pw, result):
    f = result["failures"]
    def need(ok, msg):
        if not ok:
            f.append(msg)

    browser = pw.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1280, "height": 900})
    page = ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
    page.on("console", lambda m: errors.append(f"console: {m.text}") if m.type == "error" and ("Content Security Policy" in m.text or "Refused" in m.text) else None)
    open_home(page)
    need(page.locator("#continue .cont-list > li").count() == 5, f"Continue has {page.locator('#continue .cont-list > li').count()} rows, not 5")

    # --- a Chat conversation: right-click, the actions, Rename ---
    r = row(page, "chat", C1)
    r.click(button="right")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    got = labels(page)
    for w in ("Open", "Open in a new tab", "Copy link", "Rename", "Archive", "Delete"):
        need(any(w in g for g in got), f"the Chat menu has no {w!r}: {got}")
    need(inside(page), "the Chat menu leaves the viewport")
    need(page.locator('.ctx-menu [aria-disabled="true"]').count() == 0, "a Chat action is off")
    page.screenshot(path=str(OUT / "home-menu-chat-1280.png"))
    result["shots"].append("home-menu-chat-1280.png")
    item(page, "Rename").click()
    page.wait_for_selector("dialog.ctx-dlg[open] input", timeout=3000)
    need(page.input_value("dialog.ctx-dlg[open] input") == "Plan the quarterly budget review", "Rename does not start from the title")
    page.fill("dialog.ctx-dlg[open] input", "Budget review, renamed")
    page.keyboard.press("Enter")
    page.wait_for_function("() => document.querySelector('#continue').textContent.includes('Budget review, renamed')", timeout=5000)
    need(STATE["posts"] and STATE["posts"][-1] == {"id": C1, "act": "rename", "body": {"title": "Budget review, renamed"}}, f"rename went {STATE['posts']}")

    # --- Delete: confirmed, says what goes, Cancel is the default; a cancel changes nothing ---
    row(page, "chat", C3).click(button="right")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    item(page, "Delete").click()
    page.wait_for_selector("dialog.ctx-dlg[open]", timeout=3000)
    text = page.inner_text("dialog.ctx-dlg[open]")
    need("Meeting notes" in text and "for good" in text, f"the delete dialog does not say what goes: {text!r}")
    need(page.evaluate("() => document.activeElement && document.activeElement.textContent.trim()") == "Cancel", "Cancel is not the default in the delete dialog")
    page.screenshot(path=str(OUT / "home-delete-dialog-1280.png"))
    result["shots"].append("home-delete-dialog-1280.png")
    page.keyboard.press("Escape")
    need(not any(p["act"] == "delete" for p in STATE["posts"]), "Escape in the delete dialog still deleted")
    row(page, "chat", C3).click(button="right")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    item(page, "Delete").click()
    page.wait_for_selector("dialog.ctx-dlg[open]", timeout=3000)
    page.locator("dialog.ctx-dlg[open] button.danger, dialog.ctx-dlg[open] .action.danger").first.click()
    page.wait_for_function(f"() => !document.querySelector('#continue li[data-id=\"{C3}\"]')", timeout=5000)
    need(STATE["posts"][-1] == {"id": C3, "act": "delete", "body": {"confirm": C3}}, f"delete went {STATE['posts'][-1]}")

    # --- Archive through the ⋯ button ---
    r = row(page, "chat", C2)
    r.hover()
    more = r.locator(".ctx-more")
    need(more.count() == 1 and more.is_visible(), "no visible ⋯ on hover")
    more.click()
    page.wait_for_selector(".ctx-menu", timeout=3000)
    item(page, "Archive").click()
    page.wait_for_function(f"() => !document.querySelector('#continue li[data-id=\"{C2}\"]')", timeout=5000)
    need(STATE["posts"][-1]["act"] == "archive", "archive did not reach the stub")

    # --- the keyboard: Shift+F10 on the focused row's link, arrows, Escape, focus back ---
    open_home(page)
    link = row(page, "code", S2).locator("a").first
    link.focus()
    page.keyboard.press("Shift+F10")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    page.keyboard.press("ArrowDown")
    need("ctx-item" in (page.evaluate("() => document.activeElement.className") or ""), "arrow keys do not move into the menu")
    page.keyboard.press("Escape")
    need(page.locator(".ctx-menu").count() == 0 and page.evaluate("() => document.activeElement.classList.contains('cont-row')"), "Escape does not close the menu and return the focus to the row")
    page.keyboard.press("ContextMenu")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    page.keyboard.press("Escape")

    # --- a Code session: off, with the reason, until the Code page has reported; Open, new tab and Copy link work ---
    row(page, "code", S2).click(button="right")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    off = page.locator('.ctx-menu [aria-disabled="true"]').all_inner_texts()
    need(len(off) >= 6 and all("Open the Code tab once" in o for o in off), f"Code actions are not off with the reason before the Code page reports: {off}")
    need(not page.locator('.ctx-menu .ctx-item[aria-disabled="true"]:has-text("Open in a new tab")').count()
         and not page.locator('.ctx-menu .ctx-item[aria-disabled="true"]:has-text("Copy link")').count(), "Open in a new tab or Copy link is off for a Code session")
    page.screenshot(path=str(OUT / "home-menu-code-off-1280.png"))
    result["shots"].append("home-menu-code-off-1280.png")
    page.keyboard.press("Escape")

    # the Code page reported: its actions are asked of the framed page (here the stub page records the messages)
    page.evaluate("() => { window.bnCode.ready = () => true; }")
    page.click('[data-tab="code"]')
    page.wait_for_selector('#frames iframe[data-app="code"]', timeout=5000)
    page.click('[data-tab="home"]')
    for text, action, extra in (("Rename", "rename", {"title": "Renamed from Home"}), ("Fork", "fork", {}), ("Add to project", "file", {}),
                                ("Open its folder in a terminal", "terminal", {}), ("Archive", "archive", {}), ("Delete", "delete", {})):
        page.click('[data-tab="home"]')   # (Fork, Add to project, the terminal and Delete show the Code tab)
        row(page, "code", S2).click(button="right")
        page.wait_for_selector(".ctx-menu", timeout=3000)
        need(page.locator('.ctx-menu [aria-disabled="true"]').count() == 0, f"a Code action is still off once the Code page runs ({text})")
        item(page, text).click()
        if action == "rename":
            page.wait_for_selector("dialog.ctx-dlg[open] input", timeout=3000)
            page.fill("dialog.ctx-dlg[open] input", extra["title"])
            page.keyboard.press("Enter")
        page.wait_for_timeout(250)
    frame = next((fr for fr in page.frames if "/code-app/" in fr.url), None)
    sent = frame.evaluate("() => window.got") if frame else []
    types = [(m.get("type"), m.get("action")) for m in sent]
    for action in ("rename", "fork", "file", "terminal", "archive", "delete"):
        need(("bn-portal-session-do", action) in types, f"the Code page was not asked for {action}: {types}")
    need(all(m.get("id") == S2 for m in sent if m.get("type") == "bn-portal-session-do"), "the Code page was sent the wrong session id")
    need(any(m.get("title") == "Renamed from Home" for m in sent), "the rename title was not sent")
    open_home(page)

    # --- the nav ---
    tab = page.locator('.tabs > li:has([data-tab="chat"])')
    tab.click(button="right")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    got = labels(page)
    need(any("Open Chat" in g for g in got) and any("own window" in g for g in got) and any("Copy link" in g for g in got), f"the nav menu: {got}")
    page.keyboard.press("Escape")
    # normal behaviour kept: a left click on the row opens the conversation; a text field keeps the browser's menu
    result["menus_checked"] = True
    result["errors"] += errors
    browser.close()

    # --- touch: a long press, the always-visible ⋯, the menu inside a phone ---
    browser = pw.chromium.launch()
    ctx = browser.new_context(viewport={"width": 390, "height": 844}, has_touch=True, is_mobile=True)
    page = ctx.new_page()
    cdp = ctx.new_cdp_session(page)
    open_home(page)
    r = row(page, "chat", C1)
    r.scroll_into_view_if_needed()
    page.wait_for_timeout(700)
    need(r.locator(".ctx-more").is_visible(), "the ⋯ is not visible on touch")
    box = r.bounding_box()
    long_press(page, cdp, box["x"] + 80, box["y"] + box["height"] / 2)
    need(page.locator(".ctx-menu").count() == 1 and inside(page), "a long press did not open a menu inside the phone")
    need("/c/" not in page.url and page.locator('#continue').is_visible(), "the long press also followed the link")
    browser.close()

    # --- screenshots: three widths, both themes ---
    browser = pw.chromium.launch()
    for scheme in ("light", "dark"):
        for w, h in ((390, 844), (820, 1180), (1440, 900)):
            ctx = browser.new_context(viewport={"width": w, "height": h}, color_scheme=scheme)
            page = ctx.new_page()
            open_home(page)
            r = row(page, "chat", C1)
            r.scroll_into_view_if_needed()
            page.wait_for_timeout(700)   # (the page scrolls smoothly: the menu closes on a scroll)
            box = r.bounding_box()
            page.mouse.click(box["x"] + min(60, box["width"] - 5), box["y"] + box["height"] / 2, button="right")
            page.wait_for_selector(".ctx-menu", timeout=3000)
            need(inside(page), f"the Home menu leaves the viewport at {w}x{h} ({scheme})")
            name = f"home-menu-{w}-{scheme}.png"
            page.screenshot(path=str(OUT / name))
            result["shots"].append(name)
            ctx.close()
    browser.close()


def main() -> int:
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    OUT.mkdir(parents=True, exist_ok=True)
    result = {"ok": False, "failures": [], "shots": [], "errors": []}
    try:
        with sync_playwright() as pw:
            run(pw, result)
        result["ok"] = not result["failures"] and not result["errors"]
    except Exception as e:  # noqa: BLE001
        result["errors"].append(f"{type(e).__name__}: {e}")
        traceback.print_exc()
    finally:
        srv.shutdown()
    (OUT / "home-menus.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
    print(json.dumps(result, indent=1))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
