"""Browse models (portal/portal/static/models.js), in a real Chromium (run.sh: the e2e suite's pinned Playwright image;
no stack, no AWS, no helper, no model call, network none). A stub serves portal/portal/static under the portal's own
CSP and answers GET /api/models/browse with a recorded answer in the shape portal/portal/model_browser.py produces — a
Bedrock list (the catalog's models built in, two more addable), an OpenRouter list and an Experiential Labs list (a free
alias among them). It opens #modelbrowser and checks the rows, search and the filters, then screenshots light and dark
at 390, 820 and 1440 px. Writes /out/model-browser.json and the PNGs; exits 1 on any failure. No key is ever in the
page. (The browse logic itself is unit-tested in portal/tests/test_model_browser.py; this image has Playwright but not
the portal's httpx, so the answer is given as data here rather than computed.)
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
PORT = 18311
BASE = f"http://127.0.0.1:{PORT}"
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
       "frame-src 'none'; form-action 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'")
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml",
         ".png": "image/png", ".json": "application/json", ".woff2": "font/woff2", ".webmanifest": "application/manifest+json",
         ".ico": "image/x-icon"}


def _r(provider, source_id, ident, name, vendor, in_, out, context, tools, images, free, compat, enabled, chosen, can,
       why="", builtin=False, lifecycle="", note="", region="", kind="", guessed=False, model_id=""):
    return {"provider": provider, "id": ident, "source_id": source_id, "name": name, "vendor": vendor, "free": free,
            "in": in_, "out": out, "context": context, "tools": tools, "images": images, "compat": compat,
            "compat_note": "", "enabled": enabled, "chosen": chosen, "can": can, "why": why, "builtin": builtin,
            "lifecycle": lifecycle, "note": note, "region": region, "kind": kind, "guessed": guessed, "model_id": model_id}


# A recorded answer in the shape portal/portal/model_browser.py.browse() produces.
AT = int(time.time()) - 480
ANSWER = {
    "providers": {
        "bedrock": {"on": True, "key": "BEDROCK_MODELS", "value": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
                    "at": AT, "stale": False, "error": None, "status": "ok", "region": "us-east-1", "rows": [
            _r("bedrock", "us.anthropic.claude-opus-5-5", "claude-opus-5-5", "Claude Opus 5.5", "Anthropic", 4.0, 20.0,
               1000000, True, True, False, "works", True, True, "none", "built in: in every picker", builtin=True),
            _r("bedrock", "us.anthropic.claude-haiku-5-5", "claude-haiku-5-5", "Claude Haiku 5.5", "Anthropic", 0.8, 4.0,
               200000, True, True, False, "works", True, True, "none", "built in: in every picker", builtin=True),
            _r("bedrock", "us.anthropic.claude-haiku-4-5-20251001-v1:0", "us.anthropic.claude-haiku-4-5-20251001-v1:0",
               "Claude Haiku 4.5", "Anthropic", 0.8, 4.0, 200000, True, True, False, "untested", True, True, "remove"),
            _r("bedrock", "us.meta.llama4-maverick-17b-instruct-v1:0", "us.meta.llama4-maverick-17b-instruct-v1:0",
               "Llama 4 Maverick", "Meta", 0.24, 0.97, 1000000, True, True, False, "untested", False, False, "add"),
            _r("bedrock", "amazon.nova-pro-v1:0", "amazon.nova-pro-v1:0", "Nova Pro", "Amazon", 0.8, 3.2, 300000, True,
               True, False, "untested", False, False, "add"),
            # JON-823: your application inference profile, and models only other regions offer
            _r("bedrock", "app/k3x9q2m7w1ab", "app/k3x9q2m7w1ab", "team-claude-sonnet-production", "Anthropic", 3.0, 15.0,
               200000, True, True, False, "untested", False, False, "add", region="us-east-1", kind="app-profile",
               model_id="anthropic.claude-sonnet-4-5-20250929-v1:0",
               note="Your application inference profile, for anthropic.claude-sonnet-4-5-20250929-v1:0: billed as that model, under your profile's tags."),
            _r("bedrock", "us-east-2/qwen.qwen3-235b-a22b-2507-v1:0", "us-east-2/qwen.qwen3-235b-a22b-2507-v1:0",
               "Qwen3 235B A22B 2507", "Qwen", 0.22, 0.88, 262144, True, False, False, "untested", False, False, "add",
               region="us-east-2", model_id="qwen.qwen3-235b-a22b-2507-v1:0",
               note="Only us-east-2 offers it: your requests go to that region."),
            _r("bedrock", "eu-west-2/mistral.magistral-small-2509", "eu-west-2/mistral.magistral-small-2509",
               "Magistral Small 1.2", "Mistral AI", 0.5, 1.5, 128000, True, True, False, "untested", False, False, "add",
               region="eu-west-2", model_id="mistral.magistral-small-2509",
               note="Only eu-west-2 offers it: your requests go to that region."),
        ], "profiles": "ok", "apps": "ok", "left_out": {"not-text": 2, "embeddings": 1, "variant": 7},
           "regions": {"us-east-1": "ok", "us-east-2": "ok", "us-west-2": "ok", "eu-west-2": "ok", "ap-northeast-1": "ok",
                       "af-south-1": "off", "il-central-1": "off", "me-central-1": "error"}},
        "openrouter": {"on": True, "key": "OPENROUTER_MODELS", "value": "all", "at": AT, "stale": False,
                       "error": None, "status": None, "rows": [
            _r("openrouter", "meta-llama/llama-3.3-70b-instruct", "or/meta-llama/llama-3.3-70b-instruct",
               "Llama 3.3 70B Instruct", "Meta", 0.22, 0.5, 131072, True, False, False, "untested", True, True, "remove"),
            _r("openrouter", "z-ai/glm-5-air:free", "or/z-ai/glm-5-air:free", "GLM 5 Air (free)", "Z.AI", 0.0, 0.0, 131072,
               False, True, True, "chat-only", True, True, "remove"),
            _r("openrouter", "openai/gpt-5-vision", "or/openai/gpt-5-vision", "GPT-5 Vision", "OpenAI", 2.0, 8.0, 400000,
               True, True, False, "untested", False, True, "remove"),
        ], "left_out": {"batch": 71, "not-text": 16, "no-price": 5}},
        "explabs": {"on": True, "key": "EXPLABS_MODELS", "value": "qwen3.8-27b", "at": AT, "stale": False,
                    "error": None, "status": None, "rows": [
            _r("explabs", "qwen3.8-27b", "xl/qwen3.8-27b", "Qwen3.8 27B", "Qwen", 0.32, 2.4, 1000000, True, False, False,
               "untested", True, True, "remove"),
            _r("explabs", "deepseek-v4.1-flash:free", "xl/deepseek-v4.1-flash:free", "DeepSeek V4.1 Flash (free)",
               "DeepSeek", 0.0, 0.0, 393216, True, False, True, "untested", False, False, "add"),
            _r("explabs", "glm-5.3-uncensored", "xl/glm-5.3-uncensored", "GLM-5.3 Uncensored", "Z.ai", 1.4, 4.4, 1048576,
               True, False, False, "untested", False, False, "add"),
        ]},
    },
    "base": "0" * 64, "can_change": True, "why_not": "", "try": True,
}

# The first open on a new stack: Bedrock's list not read yet (the update helper reads it in the background), so the
# answer has only the catalog's models, without a vendor; PENDING["until"] says how long the stub answers so
PENDING = {"until": 0.0, "helper": True}   # helper: False, no update helper to read it (the list says so)
# A key that may not list Bedrock's inference profiles (JON-823): no application profile, the profile ids guessed
DENIED = {"on": False}
GUESSED = "Not confirmed: your AWS key may not list inference profiles, so this is the profile's usual id."


def denied_answer() -> dict:
    a = json.loads(json.dumps(ANSWER))
    br = a["providers"]["bedrock"]
    br.update(profiles="denied", apps="denied",
              rows=[dict(r, guessed=True, note=GUESSED) if r["source_id"].startswith("us.") and not r["builtin"] else r
                    for r in br["rows"] if r["kind"] != "app-profile"])
    return a


def pending_answer() -> dict:
    a = json.loads(json.dumps(ANSWER))
    br = a["providers"]["bedrock"]
    if PENDING.get("explabs_off"):   # a provider without a key: its line says so, with "Add a key"
        a["providers"]["explabs"].update(on=False, rows=[], at=None)
    br.update(at=None, stale=True, reading=PENDING["helper"], status=None, profiles=PENDING.get("profiles"), regions={}, left_out={},
              rows=[dict(r, vendor="", **{"in": None, "out": None}) for r in br["rows"] if r["builtin"]])
    return a


APPS_META = ('<meta name="bn-apps" content="{}">\n<meta name="bn-terminal" content="{&quot;enabled&quot;: false, &quot;here&quot;: false}">\n'
             '<meta name="bn-code" content="{&quot;enabled&quot;: false, &quot;here&quot;: false}">')


class Stub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            page = (STATIC / "index.html").read_text(encoding="utf-8")
            return self.send(200, page.replace("</head>", APPS_META + "\n</head>", 1), "text/html; charset=utf-8")
        if path == "/api/models/browse":
            answer = pending_answer() if time.time() < PENDING["until"] else denied_answer() if DENIED["on"] else ANSWER
            return self.send(200, json.dumps(answer), "application/json")
        if path == "/api/admin/status":
            return self.send(200, json.dumps({"running": True, "allowed": True, "job": None, "in_progress": False}), "application/json")
        if path.startswith("/static/"):
            f = (STATIC / path[len("/static/"):]).resolve()
            if STATIC.resolve() in f.parents and f.is_file():
                return self.send(200, f.read_bytes(), TYPES.get(f.suffix, "application/octet-stream"))
        if path.startswith("/api/"):
            return self.send(503, json.dumps({"error": "a stub: only the model browser answers"}), "application/json")
        return self.send(404, "not here", "text/plain")


def long_press(page, cdp, x, y, hold=700):
    """A finger held on (x, y): touchStart, a wait longer than the menu's 480 ms, touchEnd."""
    cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
    page.wait_for_timeout(hold)
    cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    page.wait_for_timeout(150)


def menu_inside(page):
    """The open menu's box lies inside the viewport."""
    return page.evaluate("""() => { const m = document.querySelector('.ctx-menu'); if (!m) return false; const r = m.getBoundingClientRect();
      return r.left >= 0 && r.top >= 0 && r.right <= innerWidth + 0.5 && r.bottom <= innerHeight + 0.5; }""")


def menus(pw, result):
    """Item menus (ctxmenu.js, JON-821) on a model row: right-click, Shift+F10 on the focused button, a long press."""
    out = {}
    browser = pw.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1280, "height": 900})
    page = ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(f"{BASE}/#modelbrowser", wait_until="domcontentloaded")
    page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=20000)
    row = page.locator('#modelbrowser .mb-row[data-id="amazon.nova-pro-v1:0"]')
    row.scroll_into_view_if_needed()
    page.wait_for_timeout(700)   # (smooth scrolling: the menu closes on a scroll)
    row.click(button="right")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    labels = page.locator(".ctx-menu .ctx-item").all_inner_texts()
    out["right_click_items"] = labels
    out["right_click_ok"] = any("Add to my pickers" in l for l in labels) and any("Copy model id" in l for l in labels) and menu_inside(page)
    # a model that is not added has no Try it: shown off, with the reason
    out["try_off"] = page.locator('.ctx-menu .ctx-item[aria-disabled="true"]').count() >= 1 and "Add the model first" in page.inner_text(".ctx-menu")
    page.screenshot(path=str(OUT / "model-menu-1280.png"))
    result["shots"].append("model-menu-1280.png")
    page.keyboard.press("Escape")
    out["esc_closes"] = page.locator(".ctx-menu").count() == 0
    # the keyboard: Shift+F10 on the focused row button opens it, arrows move, Escape closes and the focus is back
    btn = row.locator(".mb-actions button").first
    btn.focus()
    page.keyboard.press("Shift+F10")
    page.wait_for_selector(".ctx-menu", timeout=3000)
    page.keyboard.press("ArrowDown")
    first_focus = page.evaluate("() => document.activeElement && document.activeElement.className")
    page.keyboard.press("Escape")
    back = page.evaluate("() => document.activeElement && document.activeElement.textContent")
    out["keyboard_ok"] = "ctx-item" in (first_focus or "") and (back or "").strip() == "Add" and page.locator(".ctx-menu").count() == 0
    # the ⋯ button on hover
    row.hover()
    more = row.locator(".ctx-more")
    out["more_button"] = more.count() == 1 and more.is_visible()
    more.click()
    page.wait_for_selector(".ctx-menu", timeout=3000)
    page.locator('.ctx-menu .ctx-item:has-text("Copy model id")').click()
    out["menu_closed_after_action"] = page.locator(".ctx-menu").count() == 0
    # the text field keeps the browser's own menu
    page.locator("#mb-search").click(button="right")
    out["field_keeps_browser_menu"] = page.locator(".ctx-menu").count() == 0
    result["errors"] += errors
    browser.close()
    # touch: a long press opens it, the ⋯ is always there, and it fits a phone
    browser = pw.chromium.launch()
    ctx = browser.new_context(viewport={"width": 390, "height": 844}, has_touch=True, is_mobile=True)
    page = ctx.new_page()
    cdp = ctx.new_cdp_session(page)
    page.goto(f"{BASE}/#modelbrowser", wait_until="domcontentloaded")
    page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=20000)
    row = page.locator('#modelbrowser .mb-row[data-id="amazon.nova-pro-v1:0"]')
    row.scroll_into_view_if_needed()
    page.wait_for_timeout(700)   # (smooth scrolling: the menu closes on a scroll)
    box = row.bounding_box()
    out["touch_more_visible"] = row.locator(".ctx-more").is_visible()
    long_press(page, cdp, box["x"] + 60, box["y"] + 20)
    out["long_press_ok"] = page.locator(".ctx-menu").count() == 1 and menu_inside(page)
    page.screenshot(path=str(OUT / "model-menu-390.png"))
    result["shots"].append("model-menu-390.png")
    browser.close()
    result["menus"] = out
    result["menus_ok"] = all(v for k, v in out.items() if k not in ("right_click_items",))


def every_model(pw, result):
    """JON-823 on a phone and a desktop: Bedrock's line counts the other regions' models and the regions read; the Not
    listed sentences; Region › other regions shows only rows marked with a region; your profile is found by name; nothing
    wider than the screen. Then a key that may not list profiles: the guessed ids marked Not confirmed, and counted."""
    out, ok = {}, True
    browser = pw.chromium.launch()
    for w in (390, 1280):
        page = browser.new_page(viewport={"width": w, "height": 900})
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"{BASE}/#modelbrowser", wait_until="domcontentloaded")
        page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=20000)
        src = page.inner_text('#modelbrowser .mb-source[data-provider="bedrock"]')
        left = [page.locator(f'#modelbrowser [data-testid="mb-left-out-{k}"]').count() for k in ("bedrock", "openrouter")]
        page.select_option("#mb-region", "other")
        page.wait_for_timeout(200)
        n_other = page.locator("#modelbrowser .mb-row").count()
        page.locator("#modelbrowser .mb-row").first.scroll_into_view_if_needed()
        plain = page.locator("#modelbrowser .mb-row:not(:has(.mb-region))").count()
        wide = page.evaluate("() => document.documentElement.scrollWidth - window.innerWidth")
        page.screenshot(path=str(OUT / f"model-browser-regions-{w}.png"))
        result["shots"].append(f"model-browser-regions-{w}.png")
        page.select_option("#mb-region", "")
        page.fill("#mb-search", "team-claude")
        page.wait_for_timeout(200)
        mine = page.locator("#modelbrowser .mb-row", has_text="Your profile").count()
        page.locator("#modelbrowser .mb-row").first.scroll_into_view_if_needed()
        page.screenshot(path=str(OUT / f"model-browser-your-profile-{w}.png"))
        result["shots"].append(f"model-browser-your-profile-{w}.png")
        good = ("2 more that only other regions offer" in src and "5 regions read, 2 not turned on for your account, 1 not answering" in src
                and left == [1, 1] and n_other == 2 and plain == 0 and mine == 1 and wide <= 0 and not errors)
        out[w] = {"source": src, "left_out": left, "other": n_other, "plain": plain, "your_profile": mine, "wider": wide,
                  "errors": errors, "ok": good}
        ok = ok and good
        page.close()
    DENIED["on"] = True
    try:
        page = browser.new_page(viewport={"width": 390, "height": 900})
        page.goto(f"{BASE}/#modelbrowser", wait_until="domcontentloaded")
        page.wait_for_selector('#modelbrowser [data-testid="mb-profiles-note"]', timeout=20000)
        note = page.inner_text('#modelbrowser [data-testid="mb-profiles-note"]')
        page.fill("#mb-search", "not confirmed")
        page.wait_for_timeout(200)
        n = page.locator("#modelbrowser .mb-row").count()
        badged = page.locator("#modelbrowser .mb-row .mb-guessed").count()
        page.locator("#modelbrowser .mb-row").first.scroll_into_view_if_needed()
        wide = page.evaluate("() => document.documentElement.scrollWidth - window.innerWidth")
        page.screenshot(path=str(OUT / "model-browser-not-confirmed-390.png"))
        result["shots"].append("model-browser-not-confirmed-390.png")
        good = (n == 2 and badged == 2 and "2 marked Not confirmed" in note and "application inference profiles are not listed" in note
                and wide <= 0)
        out["denied"] = {"note": note, "rows": n, "badged": badged, "wider": wide, "ok": good}
        ok = ok and good
    finally:
        DENIED["on"] = False
        browser.close()
    result["every_model"] = out
    result["every_model_ok"] = ok


def main() -> int:
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    OUT.mkdir(parents=True, exist_ok=True)
    result = {"ok": False, "rows": 0, "shots": [], "errors": []}
    try:
        with sync_playwright() as pw:
            for theme in ("light", "dark"):
                browser = pw.chromium.launch()
                ctx = browser.new_context(color_scheme=theme, viewport={"width": 1280, "height": 900})
                page = ctx.new_page()
                errors = []
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
                page.goto(f"{BASE}/#modelbrowser", wait_until="domcontentloaded")
                page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=20000)
                rows = page.locator("#modelbrowser .mb-row").count()
                result["rows"] = rows
                # search narrows; the "works with Claude Code" filter keeps only those; the provider segment narrows
                page.fill("#mb-search", "claude")
                page.wait_for_timeout(200)
                nclaude = page.locator("#modelbrowser .mb-row").count()
                page.fill("#mb-search", "")
                page.wait_for_timeout(100)
                page.locator('#modelbrowser [data-filter="works"]').click()
                page.wait_for_timeout(150)
                nonworks = page.locator("#modelbrowser .mb-row .mb-compat:not(.mb-compat-works)").count()
                page.locator('#modelbrowser [data-filter="works"]').click()
                page.wait_for_timeout(100)
                for w in (390, 820, 1440):
                    page.set_viewport_size({"width": w, "height": 900})
                    page.wait_for_timeout(200)
                    name = f"model-browser-{w}-{theme}.png"
                    page.screenshot(path=str(OUT / name))
                    result["shots"].append(name)
                if theme == "light":
                    page.set_viewport_size({"width": 1280, "height": 900})
                    page.fill("#mb-search", "free")
                    page.wait_for_timeout(200)
                    page.screenshot(path=str(OUT / "model-browser-search.png"))
                    result["shots"].append("model-browser-search.png")
                    result["narrow_ok"] = 0 < nclaude <= rows
                    result["filter_ok"] = nonworks == 0
                css = [e for e in errors if "Content Security Policy" in e or "Refused to" in e]
                result["errors"] += css
                browser.close()
            # the first open: the list arrives while you type in the search, and the page shows it by itself
            browser = pw.chromium.launch()
            page = browser.new_page(viewport={"width": 1280, "height": 900})
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            PENDING["until"] = time.time() + 6
            page.goto(f"{BASE}/#modelbrowser", wait_until="domcontentloaded")
            page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=20000)
            first = page.inner_text('#modelbrowser .mb-source[data-provider="bedrock"]')
            page.click("#mb-search")
            page.keyboard.type("Nova")
            arrived = True
            try:
                page.wait_for_selector("#modelbrowser .mb-row:has-text('Nova Pro')", timeout=20000)
            except Exception:  # noqa: BLE001
                arrived = False
            later = page.inner_text('#modelbrowser .mb-source[data-provider="bedrock"]')
            focus = page.evaluate("() => [document.activeElement && document.activeElement.id, document.activeElement && document.activeElement.value]")
            page.screenshot(path=str(OUT / "model-browser-first-open.png"))
            result["shots"].append("model-browser-first-open.png")
            result["first_open"] = {"before": first, "after": later, "arrived": arrived, "focus": focus}
            result["first_open_ok"] = ("reading it on this computer" in first and arrived and "read" in later
                                       and "reading" not in later and focus == ["mb-search", "Nova"])
            result["errors"] += errors
            browser.close()
            # no update helper: nothing reads the list, so it says when it will be read, never "reading it…"
            browser = pw.chromium.launch()
            page = browser.new_page(viewport={"width": 390, "height": 900})
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            PENDING.update(until=time.time() + 60, helper=False, explabs_off=True)
            page.goto(f"{BASE}/#modelbrowser", wait_until="domcontentloaded")
            page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=20000)
            said = page.inner_text('#modelbrowser .mb-source[data-provider="bedrock"]')
            page.screenshot(path=str(OUT / "model-browser-no-helper.png"))
            # every link and button on the source lines is a 24 px target (the layout sweep's rule: WCAG 2.5.8)
            small = page.evaluate("""() => [...document.querySelectorAll('#modelbrowser .mb-source a, #modelbrowser .mb-source button')]
              .map((e) => [e.textContent.trim(), Math.round(e.getBoundingClientRect().height)]).filter(([, h]) => h < 24)""")
            result["targets"] = small
            result["targets_ok"] = not small and page.locator('#modelbrowser .mb-source a', has_text="Add a key").count() > 0
            # and a key that may not list Bedrock's inference profiles: said, with the permission that gives the exact list
            PENDING.update(profiles="denied")
            page.reload(wait_until="domcontentloaded")
            page.wait_for_selector('#modelbrowser [data-testid="mb-profiles-note"]', timeout=20000)
            note = page.inner_text('#modelbrowser [data-testid="mb-profiles-note"]')
            page.screenshot(path=str(OUT / "model-browser-profiles-denied.png"))
            result["shots"].append("model-browser-profiles-denied.png")
            result["profiles_note_ok"] = "bedrock:ListInferenceProfiles" in note
            PENDING.update(profiles=None, explabs_off=False)
            result["shots"].append("model-browser-no-helper.png")
            PENDING.update(until=0.0, helper=True)
            result["no_helper"] = said
            result["no_helper_ok"] = "read on this computer once the update helper runs" in said and "reading it" not in said
            result["errors"] += errors
            browser.close()
            menus(pw, result)
            every_model(pw, result)
        result["ok"] = (result.get("menus_ok") and result.get("every_model_ok") and result["rows"] >= 5 and result.get("narrow_ok") and result.get("filter_ok") and result.get("first_open_ok")
                        and result.get("no_helper_ok") and result.get("profiles_note_ok") and result.get("targets_ok")
                        and not result["errors"])
    except Exception as e:  # noqa: BLE001
        result["errors"].append(f"{type(e).__name__}: {e}")
        traceback.print_exc()
    finally:
        srv.shutdown()
    (OUT / "model-browser.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
    print(json.dumps(result, indent=1))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
