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
       why="", builtin=False, lifecycle="", note=""):
    return {"provider": provider, "id": ident, "source_id": source_id, "name": name, "vendor": vendor, "free": free,
            "in": in_, "out": out, "context": context, "tools": tools, "images": images, "compat": compat,
            "compat_note": "", "enabled": enabled, "chosen": chosen, "can": can, "why": why, "builtin": builtin,
            "lifecycle": lifecycle, "note": note}


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
        ]},
        "openrouter": {"on": True, "key": "OPENROUTER_MODELS", "value": "all", "at": AT, "stale": False,
                       "error": None, "status": None, "rows": [
            _r("openrouter", "meta-llama/llama-3.3-70b-instruct", "or/meta-llama/llama-3.3-70b-instruct",
               "Llama 3.3 70B Instruct", "Meta", 0.22, 0.5, 131072, True, False, False, "untested", True, True, "remove"),
            _r("openrouter", "z-ai/glm-5-air:free", "or/z-ai/glm-5-air:free", "GLM 5 Air (free)", "Z.AI", 0.0, 0.0, 131072,
               False, True, True, "chat-only", True, True, "remove"),
            _r("openrouter", "openai/gpt-5-vision", "or/openai/gpt-5-vision", "GPT-5 Vision", "OpenAI", 2.0, 8.0, 400000,
               True, True, False, "untested", False, True, "remove"),
        ]},
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
PENDING = {"until": 0.0}


def pending_answer() -> dict:
    a = json.loads(json.dumps(ANSWER))
    br = a["providers"]["bedrock"]
    br.update(at=None, stale=True, reading=True, status=None,
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
            return self.send(200, json.dumps(pending_answer() if time.time() < PENDING["until"] else ANSWER), "application/json")
        if path == "/api/admin/status":
            return self.send(200, json.dumps({"running": True, "allowed": True, "job": None, "in_progress": False}), "application/json")
        if path.startswith("/static/"):
            f = (STATIC / path[len("/static/"):]).resolve()
            if STATIC.resolve() in f.parents and f.is_file():
                return self.send(200, f.read_bytes(), TYPES.get(f.suffix, "application/octet-stream"))
        if path.startswith("/api/"):
            return self.send(503, json.dumps({"error": "a stub: only the model browser answers"}), "application/json")
        return self.send(404, "not here", "text/plain")


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
        result["ok"] = (result["rows"] >= 5 and result.get("narrow_ok") and result.get("filter_ok") and result.get("first_open_ok")
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
