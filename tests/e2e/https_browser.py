"""Browser half of tests/e2e/https.sh (JON-976): runs in the pinned Playwright container with a copy of the NSS database
that holds the install's own CA (HOME=/tmp, so Chromium reads /tmp/.pki/nssdb). No ignore_https_errors: a certificate
the CA does not vouch for would stop every page here. Checks: the portal login page, the sign-in, Chat and the Terminal
page load over https (each page answers and no certificate error), and a wss connection to Chat opens.
Exits non-zero on the first failed assertion, printing why."""

from __future__ import annotations

import os
import re
import sys

from playwright.sync_api import sync_playwright

HOST = os.environ["E2E_HOST"]
PORT = os.environ["E2E_PORT"]


def env_value(key: str, path: str = "/run/e2e/env") -> str:
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith(key + "="):
                return line.rstrip("\n").split("=", 1)[1]
    raise SystemExit(f"{key} missing from {path}")


def main() -> int:
    password = env_value("PORTAL_PASSWORD")
    base = f"https://{HOST}:{PORT}"
    errors: list[str] = []
    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context()   # (no ignore_https_errors)
        page = ctx.new_page()
        page.on("requestfailed", lambda r: errors.append(f"{r.url}: {r.failure}") if "ERR_CERT" in (r.failure or "") else None)

        resp = page.goto(f"{base}/", wait_until="domcontentloaded")
        assert resp is not None, "no response for the portal"
        page.wait_for_url(re.compile(r"/login"))
        assert page.url.startswith("https://"), f"login page is not https: {page.url}"
        page.fill("#password", password)
        page.click("form[action='/login'] button[type=submit]")
        page.wait_for_url(re.compile(r"^https://[^/]+/($|\?|#)"), timeout=30000)
        cookies = [c for c in ctx.cookies() if c["name"] == "bn_session"]
        assert cookies and cookies[0]["secure"], "the session cookie is not Secure"
        print("ok portal login over https, Secure cookie")

        for name, sub, path in (("chat", "chat", "/"), ("terminal", "terminal", "/")):
            r = page.goto(f"https://{sub}.{HOST}:{PORT}{path}", wait_until="domcontentloaded", timeout=60000)
            assert r is not None and r.status < 400, f"{name} page: {r.status if r else 'no response'}"
            assert page.url.startswith("https://"), f"{name} left https: {page.url}"
            print(f"ok {name} page over https ({r.status})")

        page.goto(f"https://chat.{HOST}:{PORT}/", wait_until="domcontentloaded", timeout=60000)
        got = page.evaluate(
            """(url) => new Promise((resolve) => {
                 const ws = new WebSocket(url); const t = setTimeout(() => resolve('timeout'), 15000);
                 ws.onmessage = (e) => { clearTimeout(t); ws.close(); resolve('msg:' + String(e.data).slice(0, 1)); };
                 ws.onerror = () => { clearTimeout(t); resolve('error'); };
               })""",
            f"wss://chat.{HOST}:{PORT}/ws/socket.io/?EIO=4&transport=websocket")
        assert got == "msg:0", f"wss to Chat: {got} (wanted the engine.io open packet)"
        print("ok wss to Chat")
        assert not errors, f"certificate errors: {errors}"
        browser.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as e:
        print(f"FAIL {e}")
        sys.exit(1)
