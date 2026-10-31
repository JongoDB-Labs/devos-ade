"""Browser checks (Chromium): login, Home, Chat (Open WebUI), Admin (LiteLLM), Files (RustFS), phone/tablet layouts,
the installable web app, sign-out. Screenshots mask every credential; network/console logs are redacted."""

from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

from playwright.sync_api import Error as PwError

from common import (CHAT_CSP, CHECKS_RE, ENV, HOST, NET, NETWORK_CHANGED, OUT, PORT, SHOTS, Skip, check, csp_differs, expect, host_of, http, need, origin, portal_login,
                    real_helper_running, redact, url_path)

STATE = Path("/state")
HOME_URL = re.compile("^" + re.escape(origin()) + r"/(#\w*)?$")
CRED_MASK = [".cred", ".tour-cred"]  # Home and the walkthrough show the RustFS access key / LiteLLM user: masked in every screenshot


# --- per-page network / console recorder ---

class Recorder:
    """Every response >= 400, failed request and console error/page error of one page (and its frames)."""

    BENIGN_FAIL = ("net::ERR_ABORTED",)  # navigations and Next.js prefetches cancel requests: not errors
    # Excused on every page (none now: the portal preloads the Code frame only in a browser that has used the Code page
    # before, and each check starts a new context; the code checks excuse its locked 401 themselves, LOCKED_OK)
    # (the Code page's artifact viewer names webrtc 'block' in its policy, which Chromium 140 does not know and says so)
    ALWAYS_OK = (r"Unrecognized Content-Security-Policy directive 'webrtc'",)

    def __init__(self, name: str):
        self.name, self.events = name, []

    def attach(self, page):
        page.on("response", self._resp)
        page.on("requestfailed", self._failed)
        page.on("console", lambda m: self.events.append({"t": "console", "type": m.type, "text": m.text})
                if m.type in ("error", "warning") else None)
        page.on("pageerror", lambda e: self.events.append({"t": "pageerror", "text": str(e)}))
        page.on("websocket", lambda ws: self.events.append({"t": "ws", "url": ws.url}))
        return page

    def _failed(self, r):
        err = r.failure or ""
        if "ERR_NETWORK_CHANGED" in err:
            NETWORK_CHANGED[0] += 1
        self.events.append({"t": "failed", "method": r.method, "url": r.url, "error": err})

    def _resp(self, r):
        self.events.append({"t": "resp", "status": r.status, "method": r.request.method, "url": r.url,
                            "type": r.request.resource_type})

    def mark(self, label: str):
        self.events.append({"t": "mark", "label": label})

    def save(self):
        with (NET / f"{self.name}.jsonl").open("w", encoding="utf-8") as f:
            for e in self.events:
                f.write(redact(json.dumps(e)) + "\n")

    def problems(self, host_filter: str | None = None, allow=(), start: int = 0, end: int | None = None) -> list[str]:
        """4xx/5xx responses, failed requests (not mere aborts), console errors and page errors — optionally only for
        URLs containing host_filter, and only among events[start:end]. allow: regexes of 'STATUS METHOD URL' / message
        strings that are expected. Chrome's own "Failed to load resource: … status of N" console line for an allowed
        (or filtered-out) response is dropped with it."""
        out, excused = [], {}
        for e in self.events[start:end]:
            if e["t"] == "resp" and e["status"] >= 400:
                s = f"{e['status']} {e['method']} {e['url']}"
            elif e["t"] == "failed" and not any(b in e["error"] for b in self.BENIGN_FAIL):
                s = f"FAILED {e['method']} {e['url']} {e['error']}"
            elif e["t"] == "console" and e["type"] == "error":
                s = f"console.error {e['text']}"
            elif e["t"] == "pageerror":
                s = f"pageerror {e['text']}"
            else:
                continue
            skip = (host_filter and e["t"] in ("resp", "failed") and host_filter not in e["url"]) or any(re.search(a, s) for a in (*allow, *self.ALWAYS_OK))
            if skip:
                if e["t"] == "resp":
                    excused[e["status"]] = excused.get(e["status"], 0) + 1
                continue
            m = re.search(r"Failed to load resource: the server responded with a status of (\d+)", s)
            if m and excused.get(int(m.group(1)), 0) > 0:
                excused[int(m.group(1))] -= 1
                continue
            out.append(redact(s)[:300])
        return out

    def responses(self, pattern: str):
        return [e for e in self.events if e["t"] == "resp" and re.search(pattern, e["url"])]


def shot(page, name: str, mask=(), mask_locators=()):
    path = SHOTS / f"{name}.png"
    try:
        page.screenshot(path=str(path), mask=[page.locator(m) for m in list(mask) + CRED_MASK] + list(mask_locators),
                        animations="disabled")
    except Exception:  # noqa: BLE001 — a screenshot never fails a check
        pass
    return f"shots/{name}.png"


def login(page, rec: Recorder | None = None):
    page.goto(origin() + "/")
    page.wait_for_url(re.compile(r"/login"))
    page.fill("#password", ENV["PORTAL_PASSWORD"])
    page.click("form[action='/login'] button[type=submit]")
    page.wait_for_url(HOME_URL)
    page.wait_for_selector(".shell")


def frame_of(page, sub: str, timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        for f in page.frames:
            if f.url.startswith(origin(sub)):
                return f
        page.wait_for_timeout(250)
    raise AssertionError(f"no {sub} frame")


# --- login page and Home ---

@check("browser", "login-page")
def login_page(ctx):
    page, rec = ctx.page("login-page")
    page.goto(origin() + "/")
    page.wait_for_url(re.compile(r"/login"))
    expect(page.title() == "Sign in · DevOS ADE", f"title {page.title()!r}")
    icons = page.eval_on_selector_all("link[rel=icon], link[rel=manifest], link[rel=apple-touch-icon]", "els => els.map(e => e.href)")
    expect(len(icons) == 4, f"head links {icons}")
    for href in icons:  # pre-login: every icon/manifest the page links must load without a session
        r = page.request.get(href)
        expect(r.status == 200, f"{href} -> {r.status} before login")
    # forgot it: the command that prints it, in this install's folder (UX-11); a Show button for the password
    hint = page.inner_text(".hint")
    expect(hint.startswith("Forgot it? Run ./stack password --show in ") and ".env" not in hint, f"the hint {hint!r}")
    toggle = page.locator("#pw-toggle")
    expect(toggle.is_visible() and toggle.inner_text() == "Show" and toggle.get_attribute("aria-label") == "Show password", "no Show button")
    shot(page, "01-login")
    page.fill("#password", "definitely-wrong")
    toggle.click()
    expect(page.get_attribute("#password", "type") == "text" and toggle.inner_text() == "Hide", "Show did not show the password")
    toggle.click()
    expect(page.get_attribute("#password", "type") == "password", "Hide did not hide it again")
    page.click("form[action='/login'] button[type=submit]")
    page.wait_for_selector(".error[role=alert]")
    err = page.inner_text(".error")
    expect(err == "That password is not right." and page.inner_text("body").count("./stack password --show") == 1,
           f"wrong-password message {err!r} (said plainly; the hint once)")
    shot(page, "02-login-wrong-password")
    page.fill("#password", ENV["PORTAL_PASSWORD"])
    page.click("form[action='/login'] button[type=submit]")
    page.wait_for_url(HOME_URL)
    page.wait_for_selector("#home")
    probs = rec.problems(allow=[r"^401 POST .*/login$", r"console.error Failed to load resource.*401"])
    rec.save()
    expect(not probs, f"errors: {probs}")
    return f"title, 4 icon/manifest links load pre-login, wrong password → {err[:60]!r}, right → Home"


@check("browser", "next-redirect-after-login")
def next_redirect(ctx):
    page, rec = ctx.page("next-redirect")
    page.goto(origin("chat") + "/")          # not signed in: Caddy → portal login with next=chat…
    page.wait_for_url(re.compile(r"/login\?next="))
    expect("next=http%3A%2F%2Fchat." in page.url, f"login URL {page.url}")
    page.fill("#password", ENV["PORTAL_PASSWORD"])
    page.click("form[action='/login'] button[type=submit]")
    page.wait_for_url(origin("chat") + "/**", timeout=30000)
    page.goto(origin() + "/login?next=" + "http%3A%2F%2Fevil.example%2F")
    page.wait_for_url(HOME_URL)
    rec.save()
    return "chat → login → back on chat; signed-in /login?next=evil → Home"


@check("browser", "home-dashboard")
def home(ctx):
    page, rec = ctx.page("home")
    login(page)
    page.locator("#updated", has_text="Updated").wait_for(timeout=30000)
    # Services: one line ("All 5 services running") that opens the list
    page.locator(".health-line", has_text="services running").wait_for(timeout=30000)
    expect(page.locator("#services").is_hidden(), "the service list is not folded under its line")
    page.click(".health-line")
    page.wait_for_selector("#services li")
    summary = page.evaluate("""() => fetch('/api/summary', {headers: {'X-Requested-With': 'devos-ade'}}).then(r => r.json())""")
    # 5, plus the speech-to-text container while Bedrock speech-to-text is on, the built-in SearXNG and the built-in git
    # server (Forgejo) while each is on (their state and health from ./stack's record: .state/status/services.json)
    want_svc = len(summary["services"])
    sx_on = (ENV.get("WEBSEARCH_SEARXNG_BUILTIN") or "on").lower() not in ("off", "false", "no", "0")
    lg_on = (ENV.get("LOCALGIT") or "on").lower() not in ("off", "false", "no", "0")
    expect(want_svc == 5 + (1 if summary["voice"]["on"] and summary["voice"]["provider"] == "bedrock" else 0) + sx_on + lg_on,
           f"/api/summary lists {want_svc} services (built-in SearXNG {sx_on}, git server {lg_on})")
    up = page.locator("#services li.up").count()
    total = page.locator("#services li").count()
    expect(total == want_svc and up == want_svc, f"services {up}/{total} up: {page.inner_text('#services')}")
    for on, name, role in ((sx_on, "SearXNG", "web search (built-in)"), (lg_on, "Forgejo", "git server (built-in)")):
        if on:
            row = page.locator("#services li", has_text=name)
            expect(row.count() == 1, f"{row.count()} rows for {name}: {page.inner_text('#services')!r}")
            txt = row.inner_text()
            expect(role in txt and "ready" in txt, f"the built-in {name}'s row: {txt!r}")
    # (each key named for where its spend comes from: devos-claude in your terminal, Chat, setup, the Code page and
    # the browser terminal)
    labels = ("devos-claude (your terminal)", "Open WebUI", "Setup") + (("Code page & browser terminal",) if ENV.get("LITELLM_KEY_TERMINAL") else ())
    expect(page.locator("#meters li.meter").count() == len(labels), f"{len(labels)} spend meters")
    meters = page.inner_text("#meters")
    for label in labels:
        expect(label.lower() in meters.lower(), f"meter {label} missing: {meters[:200]}")
    tot = page.inner_text("#total")
    expect(re.match(r"^(\$\d|<\$0\.0001)", tot), f"total {tot!r}")
    # The model table against the portal's own data (names, prices and statuses come from the catalog and the
    # model check, so nothing is hard-coded here): one row per model, every name, every price, logos.
    want_rows = summary["models"]["rows"]
    # the card's one line, its table folded under it
    line = page.inner_text("#models-line")
    expect(re.match(rf"^{sum(1 for m in want_rows if m['enabled'])} of {len(want_rows)} models? enabled", line), f"models line {line!r}")
    expect(page.locator("#models-more").get_attribute("open") is None, "the models table is not folded")
    page.click("#models-more > summary")
    rows = page.locator("#models tr")
    expect(rows.count() == len(want_rows), f"{rows.count()} model rows, the portal knows {len(want_rows)}")
    text = page.inner_text("#models")
    missing = [m["display"] for m in want_rows if m["display"] not in text]
    expect(not missing, f"model table lacks {missing}")
    noprice = [m["display"] for m in want_rows if m["enabled"] and m.get("price") and m["price"] not in text]
    expect(not noprice, f"prices missing for {noprice}")
    expect(page.locator("#models img").count() > 0, "no provider icons")
    enabled = sum(1 for m in want_rows if m["enabled"])
    page.click("#enabled-only")
    page.locator("#enabled-only[aria-pressed=true]").wait_for()
    vis = page.locator("#models tr:visible").count()
    expect(vis == enabled, f"Enabled only shows {vis} rows, {enabled} models are enabled")
    page.click("#enabled-only")
    # Admin and Files sign you in automatically: their own sign-ins are folded away under Credentials (the fallback)
    title = page.inner_text("#logins-title")
    expect("sign you in automatically" in title and page.locator("#logins").is_hidden(), f"sign-ins card: {title!r}, not folded")
    page.click("#logins-more summary")
    creds = page.eval_on_selector_all(".cred", "els => els.map(e => e.textContent)")
    expect(creds == [ENV["LITELLM_UI_USER"], ENV["RUSTFS_ACCESS_KEY"]], "sign-ins do not show the .env users")
    forms = page.eval_on_selector_all("a.form-link", "els => els.map(e => e.getAttribute('href'))")
    expect(forms == [origin("admin") + "/ui/login/?sso=off", origin("files") + "/rustfs/console/auth/login/?sso=off"],
           f"links to the apps' own forms: {forms}")
    expect(page.inner_text("#claude-cmd") == "devos-claude", "claude command")
    expect(page.locator("#update-card").is_hidden(), "update card visible without an update")
    # The four Copy buttons put each sign-in on the clipboard (granted); the passwords are never in the page.
    page.context.grant_permissions(["clipboard-read", "clipboard-write"], origin=origin())
    for login_, field, key in (("admin", "username", "LITELLM_UI_USER"), ("admin", "password", "LITELLM_UI_PASSWORD"),
                               ("files", "username", "RUSTFS_ACCESS_KEY"), ("files", "password", "RUSTFS_SECRET_KEY")):
        page.evaluate("navigator.clipboard.writeText('')")
        page.click(f"button.copy[data-login={login_}][data-field={field}]")
        clip, t0 = "", time.time()
        while time.time() - t0 < 5 and not clip:
            clip = page.evaluate("navigator.clipboard.readText()")
            if not clip:
                page.wait_for_timeout(100)
        expect(clip == ENV[key], f"Copy {login_} {field} did not copy {key}")
    page.evaluate("navigator.clipboard.writeText('')")
    html = page.content()
    expect(ENV["RUSTFS_SECRET_KEY"] not in html and ENV["LITELLM_UI_PASSWORD"] not in html, "a password is in the page")
    shot(page, "03-home")
    probs = rec.problems()
    rec.save()
    expect(not probs, f"errors: {probs}")
    return (f"{want_svc}/{want_svc} services{' (the built-in SearXNG among them)' if sx_on else ''}, {len(labels)} meters, total {tot}, {len(want_rows)} models (names, prices, logos; Enabled only → {enabled}), "
            "automatic sign-in card with the credentials folded away: 4 Copy buttons, 2 links to the apps' own forms")


def _write_json(path: Path, data: dict):
    tmp = path.with_name("." + path.name + ".e2e")
    tmp.write_text(json.dumps(data), encoding="utf-8")
    tmp.chmod(0o644)
    tmp.replace(path)


@check("browser", "home-update-card-states")
def update_card(ctx):
    if real_helper_running():
        raise Skip("a real update helper is running: this check fakes its heartbeat")
    up = STATE / "update-check" / "latest.json"
    beat = STATE / "status" / "helper.json"
    saved = up.read_bytes() if up.exists() else None
    page, rec = ctx.page("update-card")
    login(page)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    states = []
    try:
        # 1. newer releases: three of them since the installed version (a jump over several names each one: the
        # rehearsal's v0.4.1 → v0.9.0 showed only v0.9.0's notes)
        rels = [{"tag": t, "name": f"{t} — {h}", "headline": h,
                 "notes": f"## {t}\n- **fake** release {t} for the e2e suite\n<script>alert(1)</script>",
                 "url": f"https://github.com/JongoDB-Labs/devos-ade/releases/tag/{t}", "published_at": now}
                for t, h in (("v99.0.0", "the newest fake release"), ("v98.0.0", "a fake release in between"),
                             ("v97.0.0", "the oldest fake release"))]
        _write_json(up, {"tag": "v99.0.0", "name": "v99.0.0 (e2e)", "notes": rels[0]["notes"], "url": rels[0]["url"],
                         "published_at": now, "checked_at": now, "error": None, "images": ["ghcr.io/berriai/litellm:9.9.9"],
                         "releases": rels})
        page.click("#refresh")
        page.wait_for_selector("#update-card:not([hidden])", timeout=15000)
        meta = page.inner_text("#update-meta")
        expect("v99.0.0" in page.inner_text("#update-card"), f"card lacks the tag: {meta}")
        # when it was checked is said once, in the line above the card (with Check for updates), not again in the card
        expect("Checked" not in meta and "checked just now" in page.inner_text("#release-line"), f"the card's meta {meta!r}")
        expect(page.inner_text("#update-cmd") == "./stack update" and page.locator("#update-cmd").is_visible(), "update command")
        expect(page.locator("#update-now").is_hidden(), "Update now shown without the helper")
        expect(page.locator("#update-cli").is_hidden(), "the terminal command folded away without the helper (it is the way then)")
        heads = page.eval_on_selector_all("#update-releases li", "ls => ls.map(l => l.innerText.replace(/\\s+/g, ' '))")
        expect(heads == ["v99.0.0 the newest fake release", "v98.0.0 a fake release in between", "v97.0.0 the oldest fake release"],
               f"one line per release, newest first: {heads}")
        title = page.inner_text("#update-releases-title")
        expect(re.fullmatch(r"What's new: 3 releases since v\d+\.\d+\.\d+\S*", title), f"releases title {title!r}")
        # the core services the update moves, on one line inside the card under What's new (JON-815)
        svc = page.inner_text("#update-services") if page.locator("#update-services").is_visible() else ""
        expect(svc.startswith("Core services: LiteLLM ") and "\u2192 9.9.9" in svc, f"the update card lists the service moves: {svc!r}")
        page.click(".update-notes summary")
        opened = page.eval_on_selector_all("#update-notes details.release", "ds => ds.map(d => d.open)")
        expect(opened == [True, False, False], f"the newest open, the others folded: {opened}")
        expect("fake" in page.inner_text("#update-notes"), "release notes not rendered")
        expect(page.locator("#update-notes script").count() == 0, "notes rendered as HTML")
        page.click("#update-releases li:nth-child(2) button")   # a headline opens its notes
        page.locator('#update-notes details.release[data-tag="v98.0.0"][open]').wait_for(timeout=5000)
        expect("release v98.0.0" in page.inner_text("#update-notes"), "v98.0.0's notes not shown")
        label = page.locator("#version").get_attribute("aria-label") or ""
        expect("release check: just now" in label, f"the version label does not say when it checked: {label!r}")
        shot(page, "04-home-update-available")
        states.append("available: 3 releases listed, newest open")
        # 2. with the update helper running (fake heartbeat): Update now → password → a request file for the helper
        _write_json(beat, {"heartbeat": int(time.time()), "version": "e2e", "rollback": {"available": False}})
        page.reload()  # Home asks for the helper's state at load and every 30 s
        page.wait_for_selector("#update-now:not([hidden])", timeout=15000)
        expect(page.locator("#maint").is_visible(), "Maintenance card hidden while the helper runs")
        # Update now leads; the command is folded under it ("From a terminal instead", closed) (UX-20)
        order = page.evaluate("""() => { const a = document.querySelector('#update-now'), f = document.querySelector('#update-cli');
            return { first: Boolean(a.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_FOLLOWING), open: f.open, hidden: f.hidden,
                     inside: Boolean(f.querySelector('#update-cmd')), summary: f.querySelector('summary').textContent }; }""")
        expect(order == {"first": True, "open": False, "hidden": False, "inside": True, "summary": "From a terminal instead"},
               f"the update card's order: {order}")
        expect(page.inner_text("#update-hint").startswith("The update helper runs it on this computer"), f"hint {page.inner_text('#update-hint')!r}")
        before = set((STATE / "requests").glob("req-*.json"))
        page.click("#update-now")
        page.wait_for_selector("#confirm[open]")
        text = page.inner_text("#confirm-text")
        expect(re.match(r"Update to v99\.0\.0 \(the newest release at the last check, [^)]+\): a backup first", text), f"confirm: {text!r}")
        summary = page.evaluate("""() => fetch('/api/summary', {headers: {'X-Requested-With': 'devos-ade'}}).then(r => r.json())""")
        if summary["terminal"]["enabled"]:   # the update recreates the terminal's container: its tmux session ends
            expect("The Terminal's container is recreated: its tmux windows close" in text, f"confirm: {text!r}")
        if summary["code"]["enabled"]:
            expect("Code page sessions resume from their transcripts" in text, f"confirm: {text!r}")
        page.fill("#confirm-password", ENV["PORTAL_PASSWORD"])
        page.click("#confirm-ok")
        t0 = time.time()
        new = set()
        while time.time() - t0 < 10 and not new:
            new = set((STATE / "requests").glob("req-*.json")) - before
            page.wait_for_timeout(250)
        expect(new, "no request file for the helper after Update now")
        req = json.loads(next(iter(new)).read_text())
        expect(req["action"] == "update" and re.fullmatch(r"[0-9a-f]{32}", req["nonce"]), f"request {req}")
        shot(page, "05-home-update-requested", mask=["#confirm-password"])
        for f in new:
            f.unlink()
        states.append("helper request")
        # 3. the check failed / the latest release is the installed one: no card
        beat.unlink()
        _write_json(up, {"tag": "v0.0.1", "checked_at": now, "error": "e2e: GitHub did not answer", "error_at": now})
        page.click("#refresh")
        page.locator("#update-card").wait_for(state="hidden", timeout=15000)
        states.append("hidden on error/older")
    finally:
        if beat.exists():
            beat.unlink()
        if saved is None:
            up.unlink(missing_ok=True)
        else:
            up.write_bytes(saved)
        for f in (STATE / "requests").glob("req-*.json"):
            f.unlink()
    rec.save()
    return "; ".join(states)


@check("browser", "home-update-check-button")
def update_check_button(ctx):
    """Check for updates (static/updatecheck.js, POST /api/update/check): the line in Home's header and in Settings ›
    Updates & backups, in each state, from latest.json as the portal writes it (no GitHub here: the run's latest.json
    counts as just checked). A click's answers come from a route in this browser (the portal would ask GitHub);
    what the portal itself answers without asking GitHub is asked for real: GitHub's limit (429 limit, nothing asked)
    and every refusal before it (signed out, no X-Requested-With, another Origin, a preview's Origin).
    Every status written after a click is a newer check (a checked_at of its own, as the portal's checks write): the page
    lets a click's answer outrank an older status for 15 s, and says a click's "try again in 20 s" only while the status
    is the one it answered. Nothing here lets the throwaway's portal check for real (its records are fresh, so Home asks
    for none; the only real click is refused under GitHub's limit): the steps check latest.json is still theirs."""
    up = STATE / "update-check" / "latest.json"
    saved = up.read_bytes() if up.exists() else None
    page, rec = ctx.page("update-check")
    login(page)
    api = re.compile(r"/api/update/check$")
    states, pending = [], []
    now = datetime.now(timezone.utc)
    iso = lambda t: t.isoformat(timespec="seconds")   # noqa: E731
    fresh = lambda: datetime.now(timezone.utc) + timedelta(seconds=1)   # noqa: E731  (a check after the last one)
    summary = lambda: page.evaluate("""() => fetch('/api/summary', {headers: {'X-Requested-With': 'devos-ade'}}).then(r => r.json())""")  # noqa: E731
    line = page.locator("#release-line")

    def state(want, timeout=15000):
        page.locator(f'#release-line[data-state="{want}"]').wait_for(timeout=timeout)
        return " ".join(line.inner_text().split())

    try:
        inst = summary()["update"]["installed"] or ""
        m = re.match(r"v\d+\.\d+\.\d+", inst)
        expect(m, f"the installed version {inst!r} is not a release or a build after one (./stack setup records it)")
        tag = m.group(0)
        rel = lambda t: {"tag": t, "name": t, "headline": f"the fake release {t}", "notes": f"- fake {t}",   # noqa: E731
                         "url": f"https://github.com/JongoDB-Labs/devos-ade/releases/tag/{t}", "published_at": iso(now)}
        current = {"tag": tag, "name": tag, "checked_at": iso(now), "error": None, "releases": [rel(tag)], "by": "daily"}
        newer = {**current, "tag": "v99.0.0", "name": "v99.0.0", "releases": [rel("v99.0.0"), rel(tag)], "by": "manual",
                 "images": []}
        # 1. up to date (or, for an install that is not a release, the newest release), just checked
        _write_json(up, current)
        page.click("#refresh")
        want = "current"
        text = state(want)
        expect(text.startswith("Up to date · checked just now"), f"line {text!r}")
        btn = page.locator("#release-line .rl-check")
        expect(page.locator("#release-line .rl-state[aria-live=polite]").count() == 1, "the result is not announced")
        # why, and that nothing about this install is sent: under About this check (visible, by touch and keyboard too),
        # and the button's description
        page.click("#release-line .rl-more summary")
        why = page.locator("#release-line .rl-why")
        wtext = why.inner_text() if why.is_visible() else ""
        expect("is the newest release" in wtext and "public list of DevOS ADE releases" in wtext
               and "sends nothing about this install" in wtext, f"About this check: {wtext!r}")
        expect(btn.get_attribute("aria-describedby") == why.get_attribute("id"), "the button is not described by About this check")
        page.click("#release-line .rl-more summary")
        shot(page, "04b-home-update-check-up-to-date")
        states.append(f"{want}: {text}")
        # 2. a click: Checking… while the portal asks (the answer held here), then a newer release — the card, scrolled to
        _write_json(up, newer)
        avail = summary()["update"]
        _write_json(up, current)
        page.click("#refresh")
        state(want)
        page.route(api, lambda route: pending.append(route))
        btn.click()
        text = state("checking", 5000)
        expect(text.startswith("Checking for updates…") and btn.get_attribute("aria-disabled") == "true", f"checking: {text!r}")
        t0 = time.time()
        while not pending and time.time() - t0 < 5:
            page.wait_for_timeout(50)
        expect(len(pending) == 1, f"{len(pending)} requests for one click")
        expect(page.evaluate("document.activeElement && document.activeElement.classList.contains('rl-check')"), "the button lost the focus")
        shot(page, "04c-home-update-check-checking")
        _write_json(up, newer)   # (what the portal's check would have saved: Home's next summary agrees)
        pending.pop().fulfill(status=200, content_type="application/json", headers={"Cache-Control": "no-store"},
                              body=json.dumps({"started": True, "checking": False, "update": {**avail, "checking": False}}))
        text = state("available")
        expect(text.startswith("Update available — v99.0.0 · checked just now"), f"available: {text!r}")
        page.wait_for_selector("#update-card:not([hidden])", timeout=5000)
        page.wait_for_timeout(1200)   # (a smooth scroll)
        # (scrolled to: its top near the top of the window — or, where the page is too short for that, the page scrolled
        # as far as it goes with the card in view)
        top, at_end, bottom = page.evaluate("""() => {
            const card = document.querySelector('#update-card'), r = card.getBoundingClientRect();
            let el = card.parentElement;
            while (el && !(el.scrollHeight > el.clientHeight + 1 && /(auto|scroll)/.test(getComputedStyle(el).overflowY))) el = el.parentElement;
            const sc = el || document.scrollingElement;
            return [r.top, sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 2, r.bottom];
        }""")
        expect(top < 80 or (at_end and 0 <= top < page.viewport_size["height"] and bottom > 0),
               f"the update card was not scrolled to: its top at {top} (scrolled to the end: {at_end})")
        shot(page, "04d-home-update-check-found")
        states.append("click: checking → v99.0.0, card scrolled to")
        # 3. a second click at once: the portal's floor (its answer, here from the route)
        page.unroute(api)
        page.route(api, lambda route: route.fulfill(status=429, content_type="application/json", headers={"Retry-After": "20"},
                                                    body=json.dumps({"error": "Checked a moment ago: try again in 20 s.", "reason": "again",
                                                                     "retry_after": 20, "update": {**avail, "checking": False}})))
        btn.click()
        text = state("again", 5000)
        expect(text.startswith("Checked a moment ago — try again in 20 s"), f"again: {text!r}")
        page.unroute(api)
        states.append("again: " + text)
        # 4. GitHub could not be reached (a newer check: the click's "try again in 20 s" gives way to it at once)
        t4 = iso(fresh())
        _write_json(up, {**current, "checked_at": t4, "error": "api.github.com did not answer (ConnectError)", "error_at": t4})
        page.click("#refresh")
        text = state("error")
        expect(text.startswith("GitHub could not be reached — try again later"), f"error: {text!r}")
        expect(btn.get_attribute("aria-disabled") is None, "the button waits after an unreachable GitHub")
        states.append("unreachable")
        # 5. GitHub's limit: said with the time, the button waits — and the portal itself refuses to ask before then
        t5 = fresh()
        reset = t5 + timedelta(minutes=14)
        _write_json(up, {**current, "checked_at": iso(t5), "error": "api.github.com refused: its limit of requests for this address is used up (HTTP 403)",
                         "error_at": iso(t5), "refused": True, "limited": True, "retry_at": iso(reset)})
        page.click("#refresh")
        text = state("limit")
        expect(re.match(r"GitHub's limit for this hour — try again after \d{1,2}:\d\d", text) and btn.get_attribute("aria-disabled") == "true",
               f"limit: {text!r}")
        seen = len(rec.responses(r"/api/update/check$"))
        btn.click(force=True)   # (aria-disabled: it waits, and nothing is sent)
        page.wait_for_timeout(500)
        expect(len(rec.responses(r"/api/update/check$")) == seen, "a click while GitHub's limit holds was sent")
        shot(page, "04e-home-update-check-limit")
        # Ctrl+K's Check for updates while it holds: says why, sends nothing
        page.keyboard.press("Control+k")
        page.wait_for_selector("#search[open]", timeout=5000)
        page.fill("#search-input", "check for updates")
        page.locator("#search-list .search-opt", has_text="Check for updates").first.wait_for(timeout=10000)
        page.keyboard.press("Enter")
        page.locator("#toast.show", has_text="GitHub's limit for this hour").wait_for(timeout=5000)
        page.wait_for_timeout(500)
        expect(len(rec.responses(r"/api/update/check$")) == seen, "Ctrl+K's Check for updates was sent under GitHub's limit")
        real = page.evaluate("""() => fetch('/api/update/check', {method: 'POST', headers: {'X-Requested-With': 'devos-ade'}})
            .then(async (r) => ({status: r.status, retry: r.headers.get('Retry-After'), body: await r.json()}))""")
        b = real["body"]
        expect(real["status"] == 429 and b.get("reason") == "limit" and 600 <= b.get("retry_after", 0) <= 841
               and real["retry"] == str(b["retry_after"]), f"the portal's answer under GitHub's limit: {real['status']} {b}")
        expect(json.loads(up.read_text()).get("checked_at") == iso(t5), "the portal asked GitHub under its limit")
        states.append(f"limit: {text}; the portal: 429 limit, retry in {b['retry_after']} s")
        # 6. the endpoint's door, for real (each refused before anything is asked)
        cookie = portal_login()
        xrw = {"X-Requested-With": "devos-ade", "Content-Length": "0"}
        door = {
            "signed out": http("POST", None, "/api/update/check", {**xrw, "Origin": origin()}).status,
            "no X-Requested-With": http("POST", None, "/api/update/check", {"Origin": origin(), "Content-Length": "0"}, cookie=cookie).status,
            "another site": http("POST", None, "/api/update/check", {**xrw, "Origin": "http://evil.example"}, cookie=cookie).status,
            "an app's host": http("POST", None, "/api/update/check", {**xrw, "Origin": origin("chat")}, cookie=cookie).status,
        }
        pv = http("POST", None, "/api/update/check", {**xrw, "Origin": f"http://p3000-e2e.{ENV.get('PREVIEW_DOMAIN') or 'preview.invalid'}:{PORT}",
                                                      "Sec-Fetch-Site": "same-site", "Sec-Fetch-Mode": "cors"}, cookie=cookie)
        door["a preview"] = pv.status
        expect(door == {"signed out": 401, "no X-Requested-With": 400, "another site": 403, "an app's host": 403, "a preview": 403},
               f"refusals {door}")
        if ENV.get("PREVIEW_DOMAIN"):   # (without one, the portal's own Origin check refused it)
            expect("same-site guard" in (pv.header("X-Bn-Refused") or ""), f"a preview's POST was not refused by Caddy's guard: {pv.header('X-Bn-Refused')!r}")
        expect(json.loads(up.read_text()).get("checked_at") == iso(t5), "a refused request asked GitHub")
        states.append("door: " + ", ".join(f"{k} {v}" for k, v in door.items()))
        # 7. Settings › Updates & backups › Daily release check: the same line
        page.goto(origin() + "/#settings/UPDATE_CHECK")
        row = page.locator("#settings .set-row[data-key=UPDATE_CHECK]")
        row.wait_for(state="visible", timeout=20000)
        row.locator('.release-line[data-state="limit"] .rl-check').wait_for(timeout=10000)
        rtext = " ".join(row.locator(".release-line").inner_text().split())
        expect(rtext.startswith("GitHub's limit for this hour — try again after"), f"Settings: {rtext!r}")
        shot(page, "04f-settings-update-check")
        states.append("Settings row")
        expect(json.loads(up.read_text()).get("checked_at") == iso(t5), "latest.json changed under GitHub's limit")
        # 8. Ctrl+K: "Check for updates" runs it from anywhere, on Home (the answer from the route)
        _write_json(up, {**current, "checked_at": iso(fresh())})
        page.evaluate("() => refresh()")   # (Home's summary, as every 30 s: GitHub's limit is over)
        row.locator('.release-line[data-state="current"]').wait_for(timeout=10000)
        cur = {**summary()["update"], "checking": False}
        routed = []
        page.route(api, lambda route: (routed.append(1), route.fulfill(status=200, content_type="application/json",
                                       body=json.dumps({"started": True, "checking": False, "update": cur}))))
        page.keyboard.press("Control+k")
        page.wait_for_selector("#search[open]", timeout=5000)
        page.fill("#search-input", "check for updates")
        page.locator("#search-list .search-opt", has_text="Check for updates").first.wait_for(timeout=10000)
        page.keyboard.press("Enter")
        page.wait_for_selector("#home:not([hidden])", timeout=10000)
        text = state(want)
        expect(len(routed) == 1, f"Ctrl+K's Check for updates sent {len(routed)} requests")
        expect(page.evaluate("document.activeElement && document.activeElement.classList.contains('rl-check')"), "⌘K did not lead to the line")
        page.unroute(api)
        states.append(f"Ctrl+K → Home: {text}")
        probs = rec.problems(allow=[r"^429 POST .*/api/update/check$"])
        expect(not probs, f"errors: {probs}")
        # 9. a phone: the line in Home's header, its button a 44 px target, no sideways scroll
        page2, rec2 = ctx.page("update-check-phone", device="phone")
        login(page2)
        page2.click(".tab[data-tab=home]")
        page2.locator('#release-line[data-state]:not([data-state="none"])').wait_for(timeout=15000)
        box = page2.locator("#release-line .rl-check").bounding_box()
        wide = page2.evaluate("[document.documentElement.scrollWidth, innerWidth]")
        expect(box and box["height"] >= 43.5 and wide[0] <= wide[1], f"phone: button {box}, width {wide}")
        shot(page2, "04g-phone-update-check")
        rec2.save()
        states.append("phone")
    finally:
        for r in pending:
            try:
                r.abort()
            except Exception:  # noqa: BLE001
                pass
        try:
            page.unroute(api)
        except Exception:  # noqa: BLE001
            pass
        if saved is None:
            up.unlink(missing_ok=True)
        else:
            up.write_bytes(saved)
    rec.save()
    return "; ".join(states)


@check("browser", "home-update-last-job-and-reconnecting")
def update_last_job_and_reconnecting(ctx):
    """Home's last job is the newest of any origin (a ./stack command run in a terminal records one too); an update says it
    runs in the background and shows the step that runs with its time so far and the steps done (Settings says an update
    is finishing); while it restarts the portal, the job card says so calmly, with the time so far, instead of an error
    banner; when it ends, "Updated to …" and Settings without its notice."""
    if real_helper_running():
        raise Skip("a real update helper is running: this check fakes its heartbeat and its job")
    st = STATE / "status"
    files = {n: st / n for n in ("helper.json", "helper-status.json", "terminal-job.json")}
    saved = {n: f.read_bytes() for n, f in files.items() if f.exists()}
    page, rec = ctx.page("update-reconnecting")
    login(page)
    api = re.compile(r"/api/")
    states = []
    try:
        now = int(time.time())
        # 1. a rollback from Home, then ./stack code enable in a terminal: the terminal's is newer, so it shows
        _write_json(files["helper-status.json"], {"id": "e" * 32, "action": "rollback", "phase": "done", "message": "Rolled back to v0.4.1",
                                                  "started_at": now - 600, "updated_at": now - 500, "finished_at": now - 500,
                                                  "version": "v0.4.1", "trigger": "request"})
        _write_json(files["terminal-job.json"], {"id": f"t-{now - 60}-1", "action": "code", "command": "code enable", "phase": "done",
                                                 "message": "", "started_at": now - 60, "updated_at": now - 5,
                                                 "finished_at": now - 5, "version": "v0.9.0", "pid": 1})
        page.reload()
        page.wait_for_selector("#job:not([hidden])", timeout=15000)
        expect(page.inner_text("#job-title") == "./stack code enable finished", f"last job: {page.inner_text('#job-title')!r}")
        expect(page.inner_text("#job-origin").startswith("Run in a terminal · "), f"origin: {page.inner_text('#job-origin')!r}")
        shot(page, "06a-home-last-job-from-a-terminal")
        states.append("newest job: ./stack code enable (terminal)")
        # 2. an update from Home, restarting the services (heartbeat and job faked) ...
        _write_json(files["helper.json"], {"heartbeat": int(time.time()), "version": "e2e", "rollback": {"available": False}})
        t = int(time.time())
        _write_json(files["helper-status.json"], {"id": "f" * 32, "action": "update", "phase": "restarting",
                                                  "message": "Restarting the services and checking them", "started_at": now - 40,
                                                  "updated_at": t, "finished_at": None, "version": "", "trigger": "request",
                                                  "step": "Terminal", "step_started_at": t - 130,
                                                  "steps": [{"label": "Postgres + RustFS", "took": "1m50s"}, {"label": "Open WebUI", "took": "17s"}]})
        page.reload()
        page.locator("#job-title", has_text="in progress").wait_for(timeout=15000)
        # ... in the background, the step that runs and for how long, the ones done with their time
        expect(page.inner_text("#job-step") == "Terminal, 2 min so far", f"step: {page.inner_text('#job-step')!r}")
        expect(page.inner_text("#job-done").split("\n") == ["Postgres + RustFS · 1m50s", "Open WebUI · 17s"], f"done: {page.inner_text('#job-done')!r}")
        expect(page.inner_text("#job-note").startswith("Updating in the background: keep working, or close DevOS ADE."), f"note: {page.inner_text('#job-note')!r}")
        shot(page, "06b-home-update-steps")
        states.append("update: Terminal, 2 min so far; 2 steps done; in the background")
        # ... and Settings says an update is finishing
        page.goto(page.url.split("#")[0] + "#settings")
        page.locator("#settings-updating:not([hidden])").wait_for(timeout=15000)
        expect(page.inner_text("#settings-updating") == "An update is finishing: new settings appear when it's done.", page.inner_text("#settings-updating"))
        shot(page, "06c-settings-update-finishing")
        states.append("Settings: an update is finishing")
        page.goto(page.url.split("#")[0] + "#home")
        page.locator("#job-title", has_text="in progress").wait_for(timeout=15000)
        # ... and the portal away (every /api/ request fails, as while it restarts): reconnecting, with the time so far
        page.route(api, lambda route: route.abort())
        page.locator("#job-reconnect:not([hidden])").wait_for(timeout=15000)
        t0 = page.inner_text("#job-reconnect-time")
        page.wait_for_timeout(2500)
        t1 = page.inner_text("#job-reconnect-time")
        expect(re.fullmatch(r"\d+:\d\d", t1) and t1 != t0, f"elapsed time {t0!r} → {t1!r}")
        expect("reconnecting" in page.inner_text("#job-reconnect-text"), page.inner_text("#job-reconnect-text"))
        expect(page.locator("#load-error").is_hidden(), "an error banner while the portal restarts")
        shot(page, "06-home-update-reconnecting")
        states.append(f"portal away: reconnecting {t1}")
        # 3. back
        page.unroute(api)
        page.locator("#job-reconnect-text", has_text="Reconnected: the portal was away for").wait_for(timeout=15000)
        states.append("back: " + page.inner_text("#job-reconnect-text"))
        # 4. done: "Updated to …", no step running; every step of the whole update with its time, from the backup to
        # what's new (lib/helper.sh _job_steps: a helper of this version reads them all, up to 80); Settings' notice gone
        t = int(time.time())
        whole = [("Backup", "9s"), ("New code (git)", "2s"), ("Images of the version before kept (for rollback)", "1s"),
                 ("Image downloads started", "1s"), ("AWS key check", "3s"), ("Ports and settings in .env", "1s"),
                 ("Image portal (from Docker's cache)", "2s"), ("Image open-webui (rebuilt from RUN echo \"vendor: try 0\" && pyth…, 41s)", "44s"),
                 ("Images", "45s"), ("Prices", "2s"), ("LiteLLM config (model check kept)", "0s"), ("Download litellm:1.105.0", "1m10s"),
                 ("Image downloads", "25s"), ("Open WebUI image", "1s"), ("LiteLLM config: web search check, default models", "0s"),
                 ("Postgres + RustFS", "8s"), ("LiteLLM (13 models)", "26s"), ("LiteLLM setup key", "1s"), ("Voice", "0s"),
                 ("Web search (the built-in SearXNG)", "5s"), ("Web search check", "6s"), ("LiteLLM keys, Admin sign-in, voice service", "2s"),
                 ("Open WebUI + portal + shared-mcp (http://devos-ade.localhost)", "11s"), ("Portal sign-in and Chat's API key", "3s"),
                 ("Open WebUI syncs (models, prices, banner)", "9s"), ("Code page default", "0s"), ("Terminal: its key and project folders", "1s"),
                 ("Subscription tools (installed: codex; kept: copilot cursor gemini grok)", "38s"), ("Image terminal (rebuilt from RUN sh /tmp/tools/install.sh, 38s)", "2m05s"),
                 ("Image code (from Docker's cache)", "3s"), ("Sandbox images", "40s"), ("Terminal", "9s"), ("Code page", "9s"), ("Chat's sandbox", "4s"),
                 ("Open WebUI with your subscriptions", "1s"), ("Smoke test", "12s"), ("Finishing", "2s"), ("Old images cleaned up", "6s"), ("What's new", "0s")]
        _write_json(files["helper-status.json"], {"id": "f" * 32, "action": "update", "phase": "done", "message": "Updated to v9.9.9",
                                                  "started_at": now - 40, "updated_at": t, "finished_at": t, "version": "v9.9.9",
                                                  "trigger": "request", "step": "", "step_started_at": None,
                                                  "steps": [{"label": l, "took": tk} for l, tk in whole]})
        page.locator("#job-title", has_text="finished").wait_for(timeout=15000)
        expect(page.inner_text("#job-message") == "Updated to v9.9.9", f"message: {page.inner_text('#job-message')!r}")
        expect(page.locator("#job-step").is_hidden(), "a step shown after the update ended")
        shown = [x.strip() for x in page.locator("#job-done li").all_inner_texts()]
        expect(shown == [f"{l} · {tk}" for l, tk in whole], f"the update's steps on its card: {shown!r}")
        shot(page, "06d-home-update-every-step-timed")
        states.append(f"done: all {len(shown)} steps of the update on the card, each with its time")
        page.goto(page.url.split("#")[0] + "#settings")
        page.wait_for_selector("#settings-title", timeout=15000)
        expect(page.locator("#settings-updating").count() == 0 or page.locator("#settings-updating").is_hidden(), "Settings still says an update is finishing")
        states.append("done: Updated to v9.9.9; Settings' notice gone")
    finally:
        try:
            page.unroute(api)
        except Exception:  # noqa: BLE001
            pass
        for n, f in files.items():
            if n in saved:
                f.write_bytes(saved[n])
            else:
                f.unlink(missing_ok=True)
    rec.save()
    return "; ".join(states)


@check("browser", "home-auto-update-switch")
def auto_switch(ctx):
    if real_helper_running():
        raise Skip("a real update helper is running: this check fakes its heartbeat")
    up = STATE / "update-check" / "latest.json"
    beat = STATE / "status" / "helper.json"
    saved = up.read_bytes() if up.exists() else None
    page, rec = ctx.page("auto-switch")
    login(page)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    auto = {"on": False, "hour": 3, "state": "off", "target": "", "reason": "Off: new releases wait for you.",
            "next_window": int(time.time()) + 3600, "last": {"version": "", "result": "", "at": None}}
    states = []
    try:
        # 1. no helper: Maintenance says how to turn one-click updates on (the one command, Copy)
        page.wait_for_selector("#helper-off:not([hidden])", timeout=15000)
        expect(page.locator("#maint #helper-off").count() == 1, "the hint is not in Maintenance without an update")
        expect(page.inner_text("#helper-off-title") == "One-click updates are off", page.inner_text("#helper-off-title"))
        expect(page.inner_text("#helper-cmd") == "./stack helper install", "helper command")
        expect(page.locator("#auto-row").is_hidden() and page.locator("#maint-actions").is_hidden(), "actions without a helper")
        states.append("no helper: hint in Maintenance")
        # ... and in the update card while an update is available
        _write_json(up, {"tag": "v99.0.0", "name": "v99.0.0 (e2e)", "notes": "e2e", "checked_at": now, "error": None,
                         "url": "https://github.com/JongoDB-Labs/devos-ade/releases/tag/v99.0.0"})
        page.click("#refresh")
        page.wait_for_selector("#update-card #helper-off:not([hidden])", timeout=15000)
        expect(page.locator("#maint").is_hidden(), "Maintenance shown twice")
        shot(page, "05a-home-one-click-off")
        states.append("hint in the update card")
        # the version label under the brand: the installed version, a dot and the release notes while one is available
        label = page.locator("#version")
        expect(label.is_visible() and re.fullmatch(r"v\d+\.\d+\.\d+", label.locator(".v-tag").inner_text()),
               f"version label: {label.inner_text()!r}")
        page.locator("#version .v-dot").wait_for(timeout=5000)
        expect("update available: v99.0.0" in (label.get_attribute("aria-label") or ""), "label lacks the update")
        page.click("#version")
        page.locator(".update-notes[open]").wait_for(timeout=5000)
        states.append(f"version label {label.inner_text()!r} → release notes")
        # 2. a helper with automatic updates off: Off | Nightly; Nightly → password → an auto-on request
        def fresh_beat(a=auto):  # the portal trusts a heartbeat for 30 s
            _write_json(beat, {"heartbeat": int(time.time()), "version": "e2e", "rollback": {"available": False}, "auto": a})
        fresh_beat()
        page.reload()
        page.wait_for_selector("#auto-row:not([hidden])", timeout=15000)
        expect(page.locator("#auto-toggle [data-auto=off]").get_attribute("aria-pressed") == "true", "Off not pressed")
        expect(page.locator("#helper-off").is_hidden(), "hint shown with a helper")
        before = set((STATE / "requests").glob("req-*.json"))
        page.click("#auto-toggle [data-auto=on]")
        page.wait_for_selector("#confirm[open]")
        expect("Turn on automatic updates" in page.inner_text("#confirm-title"), "confirm title")
        page.fill("#confirm-password", ENV["PORTAL_PASSWORD"])
        page.click("#confirm-ok")
        t0, new = time.time(), set()
        while time.time() - t0 < 45 and not new:
            new = set((STATE / "requests").glob("req-*.json")) - before
            err = page.locator("#confirm-error")
            if not new and err.is_visible():
                # the portal allows one request every 30 s, and the previous check just made one: as a person would,
                # wait the time the dialog names and confirm again
                m = re.search(r"wait (\d+) s", err.inner_text())
                expect(m, f"the switch was refused: {err.inner_text()}")
                # (the fake heartbeat kept fresh meanwhile — the portal trusts one for 30 s, and the wait can be that
                # long — and the dialog opened again from the switch if it closed: on a slower host it was gone by then)
                end = time.time() + int(m.group(1)) + 1
                while time.time() < end:
                    fresh_beat()
                    page.wait_for_timeout(max(0, min(5.0, end - time.time())) * 1000)
                fresh_beat()
                if not page.locator("#confirm-ok").is_visible():
                    # (Home asks for the helper's status every 30 s and trusts a heartbeat for 30 s: an ask that came
                    # while the fake one was nearly 30 s old leaves the switch disabled until the next — v0313a's
                    # slower run clicked it then and waited out the click's 30 s. Kept fresh until Home has seen it.)
                    on, t_en = page.locator("#auto-toggle [data-auto=on]"), time.time()
                    while on.is_disabled() and time.time() - t_en < 45:
                        fresh_beat()
                        page.wait_for_timeout(1000)
                    page.click("#auto-toggle [data-auto=on]")
                    page.wait_for_selector("#confirm[open]")
                    page.fill("#confirm-password", ENV["PORTAL_PASSWORD"])
                page.click("#confirm-ok")
                t0 = time.time()   # (the wait above is not the request's time)
            page.wait_for_timeout(250)
        expect(new, "no request file for the helper after Nightly")
        req = json.loads(next(iter(new)).read_text())
        expect(req["action"] == "auto-on", f"request {req}")
        for f in new:
            f.unlink()
        states.append("Nightly → auto-on request")
        # 3. the helper reports it on, with the release waiting for the window: the update card says when
        fresh_beat({**auto, "on": True, "state": "wait", "target": "v99.0.0",
                    "reason": "v99.0.0 installs automatically between 03:00 and 06:00 (this computer's time), after a backup."})
        page.reload()
        page.locator("#auto-toggle [data-auto=on][aria-pressed=true]").wait_for(timeout=15000)
        hint = page.inner_text("#update-hint")
        expect(hint == "Will install automatically tonight between 03:00 and 06:00 (this computer's time) — or Update now.",
               f"update hint: {hint}")
        shot(page, "05b-home-automatic-updates-on")
        states.append("on: update card says tonight")
    finally:
        if beat.exists():
            beat.unlink()
        if saved is None:
            up.unlink(missing_ok=True)
        else:
            up.write_bytes(saved)
        for f in (STATE / "requests").glob("req-*.json"):
            f.unlink()
    rec.save()
    return "; ".join(states)


@check("browser", "pwa-installable")
def pwa(ctx):
    page, rec = ctx.page("pwa")
    login(page)
    reg = page.evaluate("""async () => { const r = await Promise.race([navigator.serviceWorker.ready,
        new Promise(res => setTimeout(() => res(null), 10000))]); return r ? r.scope : null; }""")
    expect(reg == origin() + "/", f"service worker scope {reg}")
    cdp = page.context.new_cdp_session(page)
    errs = cdp.send("Page.getInstallabilityErrors")["installabilityErrors"]
    expect(not errs, f"installability errors: {errs}")
    expect(page.locator("[data-install]").count() == 2, "two Install app buttons")
    expect(all(b.is_hidden() for b in page.locator("[data-install]").all()), "Install shown before the browser offers it")
    # What Chrome does when the app becomes installable: the buttons and the note appear.
    page.evaluate("""() => { const e = new Event('beforeinstallprompt'); e.prompt = () => {};
        e.userChoice = Promise.resolve({outcome: 'dismissed'}); e.preventDefault = () => {}; window.dispatchEvent(e); }""")
    page.wait_for_selector(".install-btn:not([hidden])", timeout=5000)
    expect(page.locator("#install-note").is_visible(), "install note hidden after beforeinstallprompt")
    shot(page, "06-home-install-offered")
    rec.save()
    return f"service worker at {reg}, no installability errors, Install app appears on beforeinstallprompt"


# --- installed or not: Install app vs Open in the app (install.js) ---
# Headless Chromium cannot install a web app, so each state is set up the way the browser would report it: display
# mode, the browser's brand, navigator.getInstalledRelatedApps, beforeinstallprompt, the app's bn.app mark. Every
# Install / Open element that becomes visible is recorded from the first byte on, so a flash of the wrong one fails.

APP_WATCH = """window.__seen = []; window.__states = [];
  new MutationObserver((ms) => { for (const m of ms) { const n = m.target;
    if (n.nodeType === 1 && n.matches('[data-install], #install-note, [data-open-app], #app-note') && !n.hidden)
      __seen.push([n.matches('[data-install], #install-note') ? 'install' : 'open', Math.round(performance.now())]); } })
    .observe(document, { subtree: true, attributes: true, attributeFilter: ['hidden'] });
  document.addEventListener('bn:app', (e) => __states.push(e.detail));"""
# In the app window; window.__leaveApp() turns it into a browser tab (Chrome's "Open in Chrome").
STANDALONE = """window.__standalone = true; const mm = window.matchMedia.bind(window); const ls = [];
  window.matchMedia = (q) => (/display-mode: *standalone/.test(q) ? { media: q, get matches() { return window.__standalone; },
    addEventListener: (t, f) => ls.push(f), removeEventListener() {}, addListener: (f) => ls.push(f), removeListener() {} } : mm(q));
  window.__leaveApp = () => { window.__standalone = false; ls.forEach((f) => f({ matches: false })); };"""


def chrome(version: int = 140, android: bool = False) -> str:
    """The brand install.js trusts getInstalledRelatedApps from (Google Chrome / Microsoft Edge 140+)."""
    data = {"brands": [{"brand": "Google Chrome", "version": str(version)}, {"brand": "Chromium", "version": str(version)}],
            "mobile": android, "platform": "Android" if android else "Linux"}
    return f"Object.defineProperty(Navigator.prototype, 'userAgentData', {{ configurable: true, get: () => ({json.dumps(data)}) }});"


# Installed while window.__installed is not false.
INSTALLED = ("Object.defineProperty(Navigator.prototype, 'getInstalledRelatedApps', { configurable: true, value: async () => "
             "(window.__installed === false ? [] : [{ platform: 'webapp', url: o + '/manifest.webmanifest', id: o + '/' }]) });")
NOT_INSTALLED = "Object.defineProperty(Navigator.prototype, 'getInstalledRelatedApps', { configurable: true, value: async () => [] });"
NO_API = "delete Navigator.prototype.getInstalledRelatedApps;"
MARKED = "localStorage.setItem('bn.app', '1');"   # the installed app ran here once
BIP_SOON = ("if (location.pathname === '/') setTimeout(() => { const e = new Event('beforeinstallprompt', { cancelable: true }); "
            "e.prompt = () => {}; e.userChoice = Promise.resolve({ outcome: 'dismissed' }); dispatchEvent(e); }, 300);")
OPEN_LINKS = "[...document.querySelectorAll('[data-open-app]')].filter(a => !a.hidden).map(a => a.getAttribute('href'))"
NOTE_TEXT = "document.getElementById('app-note-text').textContent"
APP_STATE = "document.documentElement.dataset.appState"
OPENED = "Opened in the app. You can close this tab."
TABS = ("home", "chat", "admin", "files")


def _app_page(ctx, name: str, setup: str, device: str = "desktop", tour: bool = False):
    page, rec = ctx.page(name, device=device, tour=tour)
    page.context.add_init_script(f"(o => {{ if (location.origin === o) {{ {APP_WATCH} {setup} }} }})({json.dumps(origin())});")
    login(page)
    return page, rec


def _settled(page, ms: int = 3000) -> dict:
    """What install.js decided once DECIDE_MS (2 s) is well over."""
    page.wait_for_timeout(ms)
    return page.evaluate("() => ({ state: " + APP_STATE + ", seen: __seen, states: __states, "
                         "mark: localStorage.getItem('bn.app'), install: [...document.querySelectorAll('[data-install]')]"
                         ".filter(b => !b.hidden).length, open: " + OPEN_LINKS + ", "
                         "installNote: !document.getElementById('install-note').hidden, appNote: !document.getElementById('app-note').hidden })")


def _side(page):
    """Another window of the same site that runs no portal script (the manifest): for the app's answer and mark."""
    p = page.context.new_page()
    p.goto(origin() + "/manifest.webmanifest")
    return p


def _answer(side, nonce: str):
    """What the installed app does after a launch from a link: answer the nonce (BroadcastChannel bn.app)."""
    side.evaluate("n => { const c = new BroadcastChannel('bn.app'); c.postMessage({ opened: n }); setTimeout(() => c.close(), 500); }", nonce)


def _no_errors(rec, label: str):
    errs = [e for e in rec.events if e["t"] == "pageerror"]
    rec.save()
    expect(not errs, f"[{label}] page errors {errs}")


@check("browser", "pwa-installed-or-not")
def pwa_app_states(ctx):
    out = []

    # 1. Inside the installed app: neither button, ever; it marks the site for the browser's tabs.
    page, rec = _app_page(ctx, "pwa-standalone", STANDALONE + chrome() + INSTALLED)
    got = _settled(page)
    expect(got["state"] == "app" and got["seen"] == [] and got["mark"] == "1", f"[in the app] {got}")
    scheme = page.evaluate("() => document.querySelector('meta[name=\"bn-app-scheme\"]').content")
    manifest = json.loads(page.evaluate("() => fetch('/manifest.webmanifest').then(r => r.text())"))
    expect(scheme == manifest["protocol_handlers"][0]["protocol"] and re.fullmatch(r"web\+devosade[a-z]{8}", scheme),
           f"scheme {scheme!r} (the manifest's, a throwaway's own)")
    # A launch from a tab's Open in the app (cold start): /?open=<link> becomes /#<tab> and the nonce is answered once.
    side = _side(page)
    side.evaluate("() => { window.__acks = []; const c = new BroadcastChannel('bn.app'); c.onmessage = (e) => __acks.push(e.data.opened); }")
    page.goto(origin() + "/?open=" + quote(f"{scheme}://open?tab=chat&n=e2e1", safe=""))
    page.locator(".tab[data-tab=chat][aria-current=page]").wait_for(timeout=10000)
    expect(page.url == origin() + "/#chat", f"[cold start] URL {page.url}")
    side.wait_for_function("() => __acks.includes('e2e1')", timeout=5000)
    page.wait_for_timeout(1000)
    expect(side.evaluate("() => __acks") == ["e2e1"], f"[cold start] answers {side.evaluate('() => __acks')}")
    # Hostile launch URLs: no error, a real tab, the query gone, no answer.
    for bad in ("/?open=web+x://open?tab=constructor&n=x", "/?open=javascript:alert(1)", "/?open=%3Cimg%3E",
                "/?open=" + quote(f"{scheme}://open?tab=chat&n=" + "a" * 4096, safe="")):
        page.goto(origin() + bad)
        page.wait_for_selector(".tab[aria-current=page]")
        page.wait_for_timeout(300)
        where = page.evaluate("() => [location.search, document.querySelector('.tab[aria-current=page]').dataset.tab]")
        expect(where[0] == "" and where[1] in TABS, f"[hostile {bad[:40]}] {where}")
    expect(side.evaluate("() => __acks") == ["e2e1"], f"[hostile] answered {side.evaluate('() => __acks')}")
    # "Open in Chrome": the app window becomes a tab, which offers to open the app again at once (it was the app a
    # moment ago: no waiting for the browser's answer or for DECIDE_MS).
    page.goto(origin() + "/#home")
    page.wait_for_selector(".tab[aria-current=page]")
    now = page.evaluate(f"() => {{ window.__leaveApp(); return [{APP_STATE}, {OPEN_LINKS}.length]; }}")
    expect(now == ["open", 2], f"[app → tab] {now}")
    side.close()
    _no_errors(rec, "in the app")
    out.append("app: nothing, mark, cold start+1 answer, 4 hostile ok, →tab: Open")

    # 2. A tab, and the browser lists the app as installed: Open in the app (sidebar + Home note), never Install.
    page, rec = _app_page(ctx, "pwa-installed-tab", chrome() + INSTALLED)
    got = _settled(page)
    expect(got["state"] == "open" and got["install"] == 0 and not got["installNote"] and got["appNote"], f"[installed] {got}")
    expect(got["seen"] and all(k == "open" for k, _ in got["seen"]), f"[installed] Install flashed: {got['seen']}")
    expect(got["mark"] == "1", f"[installed] bn.app {got['mark']!r}")
    expect(len(got["open"]) == 2 and all(h.startswith(f"{scheme}://open?tab=home&n=") for h in got["open"]), f"[installed] links {got['open']}")
    expect(page.evaluate(NOTE_TEXT) == "Use it in its own window instead of this tab.", f"note {page.evaluate(NOTE_TEXT)!r}")
    shot(page, "06b-home-open-in-app")
    # A click: "Opening…", and the app's answer turns it into "you can close this tab". (Headless Chromium has no
    # handler for the scheme, so the click itself goes nowhere: the answer is sent the way the app would.)
    page.click("#app-note [data-open-app]")
    href = page.get_attribute("#app-note [data-open-app]", "href")
    expect(page.evaluate(NOTE_TEXT).startswith("Opening DevOS ADE"), f"after click: {page.evaluate(NOTE_TEXT)!r}")
    side = _side(page)
    _answer(side, "not-this-one")
    page.wait_for_timeout(500)
    expect(page.evaluate(NOTE_TEXT).startswith("Opening"), "a foreign nonce counted as the answer")
    _answer(side, href.rsplit("&n=", 1)[1])
    page.wait_for_function(f"() => {NOTE_TEXT} === {json.dumps(OPENED)}", timeout=5000)
    shot(page, "06c-home-opened-in-app")
    # From another tab of the portal the link names that tab; without an answer, the other ways in.
    page.evaluate("() => history.replaceState(null, '', '#chat')")
    page.click(".sidebar [data-open-app]")
    href = page.get_attribute(".sidebar [data-open-app]", "href")
    expect(href.startswith(f"{scheme}://open?tab=chat&n="), f"sidebar link from #chat: {href}")
    page.wait_for_function(f"() => {NOTE_TEXT}.startsWith(\"Didn't open?\")", timeout=9000)
    note = page.evaluate(NOTE_TEXT)
    expect("Dock" in note and "./stack open" in note and "Open in app" in note, f"fallback {note!r}")
    _answer(side, href.rsplit("&n=", 1)[1])   # a late answer (the user took a while with the browser's questions)
    page.wait_for_function(f"() => {NOTE_TEXT} === {json.dumps(OPENED)}", timeout=5000)
    # Not now: the note goes (and stays gone after a reload); the sidebar link stays.
    page.click("#app-note-later")
    expect(page.locator("#app-note").is_hidden() and page.locator(".sidebar [data-open-app]").is_visible(), "Not now")
    page.reload()
    page.wait_for_selector(".sidebar [data-open-app]:not([hidden])", timeout=10000)
    expect(page.locator("#app-note").is_hidden(), "the dismissed note came back after a reload")
    # Uninstalled elsewhere while this tab stays open: when it comes back into view it asks again.
    page.evaluate("() => { window.__installed = false; document.dispatchEvent(new Event('visibilitychange')); }")
    page.wait_for_function(f"() => {APP_STATE} === 'none'", timeout=3000)
    got = _settled(page, 300)
    expect(got["open"] == [] and got["install"] == 0 and got["mark"] is None, f"[uninstalled while open] {got}")
    side.close()
    _no_errors(rec, "installed")
    out.append("installed: 2 links, answer/late/fallback, Not now, uninstall seen on return")

    # 3. Installed from another tab while this one offered Install: the app's mark appears, Open replaces Install.
    page, rec = _app_page(ctx, "pwa-installed-elsewhere", BIP_SOON)
    got = _settled(page)
    expect(got["state"] == "install" and got["install"] == 2, f"[before] {got}")
    side = _side(page)
    side.evaluate("() => localStorage.setItem('bn.app', '1')")
    page.wait_for_function(f"() => {APP_STATE} === 'open'", timeout=3000)
    got = _settled(page, 300)
    expect(got["install"] == 0 and not got["installNote"] and len(got["open"]) == 2, f"[installed elsewhere] {got}")
    side.close()
    # appinstalled in this tab: nothing for SETTLE_MS (Chrome moves the tab into the app window), then Open.
    page.reload()
    page.wait_for_function(f"() => {APP_STATE} === 'install'", timeout=5000)
    t0 = page.evaluate("() => { __seen.length = 0; dispatchEvent(new Event('appinstalled')); return performance.now(); }")
    expect(page.evaluate(APP_STATE) == "none", f"[appinstalled] at once: {page.evaluate(APP_STATE)}")
    page.wait_for_function(f"() => {APP_STATE} === 'open'", timeout=4000)
    first = min(t for k, t in page.evaluate("() => __seen") if k == "open")
    expect(first - t0 >= 1400, f"[appinstalled] Open after {first - t0:.0f} ms")
    _no_errors(rec, "installed elsewhere")
    out.append(f"other tab installs: Install→Open; appinstalled: Open after {first - t0:.0f} ms")

    # 4. The app's mark is still there but the browser offers to install: it was uninstalled. Install wins, the
    #    mark goes, Open never shows (a browser that cannot answer, so only the mark and the event say anything).
    page, rec = _app_page(ctx, "pwa-uninstalled-tab", NO_API + MARKED + BIP_SOON)
    got = _settled(page)
    expect(got["state"] == "install" and got["install"] == 2 and got["installNote"] and not got["open"] and not got["appNote"], f"[uninstalled] {got}")
    expect(all(k == "install" for k, _ in got["seen"]) and got["mark"] is None, f"[uninstalled] seen {got['seen']}, mark {got['mark']!r}")
    _no_errors(rec, "uninstalled")
    out.append("mark+bip: Install, mark cleared")

    # 5. Browsers whose answer is not trusted, with the mark and no install offer: Open in the app after DECIDE_MS
    #    (2 s), and the mark stays: no API (another Chromium), and Chrome 139 (an empty list for every web app).
    for label, setup in (("no API", NO_API), ("Chrome 139", chrome(139) + NOT_INSTALLED)):
        page, rec = _app_page(ctx, "pwa-marked-" + label.replace(" ", "-").lower(), setup + MARKED)
        got = _settled(page)
        expect(got["state"] == "open" and len(got["open"]) == 2 and got["install"] == 0 and got["mark"] == "1", f"[{label}] {got}")
        first = min(t for _, t in got["seen"])
        expect(all(k == "open" for k, _ in got["seen"]) and first >= 1900, f"[{label}] shown at {first} ms: {got['seen']}")
        _no_errors(rec, label)
        out.append(f"{label}+mark: Open at {first} ms")

    # 6. Neither installed nor installable (Chrome 140 says no; a stale mark goes): nothing, ever.
    page, rec = _app_page(ctx, "pwa-neither", chrome() + NOT_INSTALLED + MARKED)
    got = _settled(page)
    expect(got["state"] == "none" and got["seen"] == [] and got["mark"] is None, f"[neither] {got}")
    expect(got["states"] == ["none"], f"[neither] states {got['states']}")
    _no_errors(rec, "neither")
    out.append("neither: nothing, mark cleared")

    # 7. The walkthrough's Extras step offers Open in the app, also right after a reload on that step.
    page, rec = _app_page(ctx, "pwa-walkthrough-extras", chrome() + INSTALLED +
                          "localStorage.setItem('bn.tour', JSON.stringify({ open: true, cur: 'extras' }));", tour=True)
    for when in ("first load", "reload"):
        if when == "reload":
            page.reload()
        page.wait_for_selector("#tour [data-k=open-app]", timeout=10000)
    _no_errors(rec, "walkthrough")
    out.append("Extras: Open (+reload)")

    # 8. Android (phone): installed, but there is no link to launch it: the note says where it is, no button.
    page, rec = _app_page(ctx, "pwa-installed-phone", chrome(android=True) + INSTALLED, device="phone")
    page.click(".tab[data-tab=home]")
    page.wait_for_selector("#app-note:not([hidden])", timeout=10000)
    got = _settled(page, 1000)
    note = page.evaluate(NOTE_TEXT)
    expect(got["open"] == [] and got["install"] == 0 and "home screen" in note and "Open in app" in note, f"[phone] {got} {note!r}")
    shot(page, "14b-phone-installed-note")
    _no_errors(rec, "phone")
    out.append("Android: note, no link")
    return "; ".join(out)


# --- Chat (Open WebUI in the portal's frame) ---

def chat_frame(page, query: str = ""):
    page.click(".tab[data-tab=chat]")
    page.wait_for_selector("iframe[data-app=chat]")
    if query:
        page.evaluate("u => document.querySelector('iframe[data-app=chat]').src = u", origin("chat") + "/" + query)
    fl = page.frame_locator("iframe[data-app=chat]")
    fl.locator("#chat-input").wait_for(timeout=45000)
    return fl, frame_of(page, "chat")


def owui_api(frame, path: str, method="GET", body=None):
    """Open WebUI's API from its frame (its token). A GET or DELETE is asked again (once the frame has loaded) when the
    frame navigated while it ran — the portal gives the frame a new address to open a conversation; a POST never is."""
    for attempt in range(3):
        try:
            return frame.evaluate("""async ([p, m, b]) => { const r = await fetch(p, {method: m, headers: {Authorization: 'Bearer ' +
                localStorage.token, 'Content-Type': 'application/json'}, body: b ? JSON.stringify(b) : undefined});
                return {status: r.status, body: await r.text()}; }""", [path, method, body])
        except PwError as e:
            if method not in ("GET", "DELETE") or "Execution context was destroyed" not in str(e) or attempt == 2:
                raise
            frame.wait_for_load_state("load", timeout=30000)


@check("browser", "chat-loads-models")
def chat_models(ctx):
    need("open-webui")
    page, rec = ctx.page("chat-models")
    login(page)
    fl, f = chat_frame(page)
    expect(page.locator("iframe[data-app=chat]").get_attribute("src") == origin("chat") + "/", "chat frame src")
    r = owui_api(f, "/api/models")
    expect(r["status"] == 200, f"/api/models {r['status']}")
    models = {m["id"]: m for m in json.loads(r["body"])["data"]}
    rows = {m["name"]: m for m in ctx.enabled_rows()}
    enabled = list(rows)
    default_icon = f.evaluate("""async () => { const r = await fetch('/static/favicon.png'); return (await r.arrayBuffer()).byteLength; }""")
    bad = []
    for mid in enabled:
        m = models.get(mid)
        if m is None:
            bad.append(f"{mid} missing")
            continue
        meta = (m.get("info") or {}).get("meta") or {}
        if rows[mid].get("kind") == "chat":
            if not re.search(r" · \${1,3}$", m["name"]):
                bad.append(f"{mid} name {m['name']!r}")
            if not re.search(r"\$[0-9.]+ in / \$[0-9.]+ out per 1M tokens", meta.get("description") or ""):
                bad.append(f"{mid} description {meta.get('description')!r}")
            img = f.evaluate("""async id => { const r = await fetch('/api/v1/models/model/profile/image?id=' + encodeURIComponent(id),
                {headers: {Authorization: 'Bearer ' + localStorage.token}}); const b = new Uint8Array(await r.arrayBuffer());
                return [r.status, r.headers.get('content-type'), b.length, Array.from(b.slice(0, 4))]; }""", mid)
            if img[0] != 200 or img[1] != "image/png" or img[3] != [137, 80, 78, 71] or img[2] == default_icon:
                bad.append(f"{mid} logo {img[:3]}")
        elif not meta.get("hidden"):
            bad.append(f"helper model {mid} not hidden")
    expect(not bad, "; ".join(bad))
    sel = fl.locator("#model-selector-model-button").get_attribute("aria-label")
    default = models[ENV["OWUI_DEFAULT_MODEL"]]["name"]
    expect(default in (sel or ""), f"default model {sel!r}, want {default!r}")
    shot(page, "07-chat")
    probs = rec.problems(allow=[r"No token found in localStorage"])
    rec.save()
    expect(not probs, f"errors: {probs}")
    return f"{len(enabled)} models: friendly names with tiers, prices, logos; helpers hidden; default {default}"


@check("browser", "chat-images-own-only")
def chat_images(ctx):
    """Open WebUI's site loads images from itself only (img-src 'self' data: blob:, caddy/Caddyfile chat_csp): what it
    shows itself — its logo, the models' icons, avatars — still loads, with no CSP error; an image of another site (what
    an answer could carry a sign-in's words out in) is refused, and so are a video, a frame and a request to another
    site. An artifact (a sandboxed srcdoc frame, as Open WebUI's Artifacts panel makes one, with its IFRAME_CSP written
    into the document's <head>): its request, image, script and style sheet from another site refused — also when the
    document hides its <head> in a comment, so that Open WebUI's policy lands there (Chat's own policy holds them then)
    —, none of them requested; its frame navigating itself to another site refused (the embedding page's frame-src), a
    popup and the top page's navigation refused (its sandbox), nothing requested; html code blocks open there only on a
    click (detectArtifacts off)."""
    need("open-webui")
    page, rec = ctx.page("chat-images")
    # (every request the page or a frame of it makes to another site: none may go out — DevTools lists one the policy
    # blocked too, failed as blocked: what counts is an answer, or a failure that is not the policy's)
    out = []
    page.context.on("response", lambda r: out.append(r.url) if "example.com" in r.url else None)
    blocked = lambda f: (f or "").lower() in ("csp", "net::err_blocked_by_csp")   # noqa: E731 — the policy's own block
    page.context.on("requestfailed", lambda r: out.append(f"{r.url} ({r.failure})") if "example.com" in r.url and not blocked(r.failure) else None)
    login(page)
    fl, f = chat_frame(page)
    csp = f.evaluate("async () => (await fetch(location.href, {cache: 'no-store'})).headers.get('content-security-policy') || ''")
    # (each of Chat's directives as Caddy sends them, exactly: one loosened — img-src with https: — is a failure)
    differs = csp_differs(csp, CHAT_CSP.format(origin=origin(), host=host_of("chat")))
    expect(not differs, f"Open WebUI's CSP: {', '.join(differs)} missing or other in {csp!r}")
    page.wait_for_timeout(3000)
    broken = f.evaluate("""() => [...document.images].filter((i) => i.complete && i.naturalWidth === 0 && i.src)
        .map((i) => i.src.slice(0, 120))""")
    expect(not broken, f"images of Open WebUI's own that did not load: {broken[:6]}")
    refused = f.evaluate("""() => new Promise((r) => {
        document.addEventListener('securitypolicyviolation', (e) => r(e.violatedDirective), { once: true });
        const i = new Image(); i.src = 'https://example.com/bn-e2e.png?' + Date.now(); document.body.append(i);
        setTimeout(() => r(null), 8000); })""")
    expect(refused and refused.startswith("img-src"), f"an image of another site was not refused: {refused!r}")
    # a video, a frame and a request to another site: refused too
    for kind, want in (("video", "media-src"), ("iframe", "frame-src"), ("fetch", "connect-src")):
        got = f.evaluate("""(kind) => new Promise((r) => {
            const on = (e) => { if (String(e.blockedURI).includes('example.com')) { document.removeEventListener('securitypolicyviolation', on); r(e.violatedDirective); } };
            document.addEventListener('securitypolicyviolation', on);
            const u = 'https://example.com/bn-e2e-' + kind + '?' + Date.now();
            if (kind === 'fetch') fetch(u).catch(() => {});
            else { const x = document.createElement(kind); x.src = u; document.body.append(x); }
            setTimeout(() => r(null), 8000); })""", kind)
        expect(got and got.startswith(want), f"a {kind} of another site was not refused by {want}: {got!r}")
    # an artifact, as Open WebUI's Artifacts panel frames one (its sandbox, IFRAME_CSP written in after the first <head>)
    art = f.evaluate("""async () => {
        const auth = { headers: { Authorization: 'Bearer ' + localStorage.token } };
        const cfg = await (await fetch('/api/config', auth)).json();
        const user = await (await fetch('/api/v1/users' + '/user/settings', auth)).json();   // (your settings, with the defaults)
        const csp = (cfg && cfg.ui && cfg.ui.iframe_csp) || '';
        const run = (html) => new Promise((r) => {
            const x = document.createElement('iframe');
            x.setAttribute('sandbox', 'allow-scripts allow-downloads allow-forms');
            const tag = '<meta http-equiv="Content-Security-Policy" content="' + csp.replace(/"/g, '&quot;') + '">';
            const i = html.indexOf('<head>');
            x.srcdoc = i !== -1 ? html.slice(0, i + 6) + tag + html.slice(i + 6) : tag + html;
            const on = (e) => { if (e.source === x.contentWindow) { window.removeEventListener('message', on); x.remove(); r(e.data); } };
            window.addEventListener('message', on);
            document.body.append(x);
            setTimeout(() => r('no answer'), 12000);
        });
        // (each directive as reported, its -elem / -attr form as the directive itself)
        const probe = '<script>const seen = [];'
            + "document.addEventListener('securitypolicyviolation', (e) => seen.push(e.effectiveDirective.replace(/-(elem|attr)$/, '')));"
            + "fetch('https://example.com/bn-e2e-artifact?' + Date.now()).catch(() => {});"
            + "const i = new Image(); i.src = 'https://example.com/bn-e2e-artifact.png?' + Date.now(); document.body.append(i);"
            + "const sc = document.createElement('script'); sc.src = 'https://example.com/bn-e2e-artifact.js?' + Date.now(); document.body.append(sc);"
            + "const ln = document.createElement('link'); ln.rel = 'stylesheet'; ln.href = 'https://example.com/bn-e2e-artifact.css?' + Date.now(); document.head.append(ln);"
            + "const pf = document.createElement('link'); pf.rel = 'prefetch'; pf.href = 'https://example.com/bn-e2e-artifact-prefetch?' + Date.now(); document.head.append(pf);"
            + "setTimeout(() => parent.postMessage([...new Set(seen)].sort().join(','), '*'), 3000);<" + "/script>";
        // its own frame sent elsewhere, a popup, the top page: what Chat's page sees of the first (its frame-src is the
        // embedding page's rule), what the artifact sees of the other two (its sandbox)
        const nav = () => new Promise((r) => {
            const seen = [];
            // (a navigation's report names the origin alone, not its path)
            const on = (e) => { if (String(e.blockedURI).includes('example.com')) seen.push(e.effectiveDirective); };
            document.addEventListener('securitypolicyviolation', on);
            const x = document.createElement('iframe');
            x.setAttribute('sandbox', 'allow-scripts allow-downloads allow-forms');
            let said = null;
            const msg = (e) => { if (e.source === x.contentWindow) said = e.data; };
            window.addEventListener('message', msg);
            x.srcdoc = '<!--<head>--><html><body><script>'
                + "var bnPop = 'none'; try { bnPop = window.open('https://example.com/bn-e2e-pop?' + Date.now()) ? 'opened' : 'refused'; } catch (e) { bnPop = 'refused'; }"
                + "var bnTop = 'none'; try { window.top.location.href = 'https://example.com/bn-e2e-top?' + Date.now(); bnTop = 'tried'; } catch (e) { bnTop = 'refused'; }"
                + "parent.postMessage({ pop: bnPop, top: bnTop }, '*');"
                + "setTimeout(() => { location.href = 'https://example.com/bn-e2e-nav?' + Date.now(); }, 300);<" + "/script></body></html>";
            document.body.append(x);
            setTimeout(() => { document.removeEventListener('securitypolicyviolation', on); window.removeEventListener('message', msg);
                let still = null; try { still = x.contentDocument === null ? 'opaque' : 'here'; } catch (e) { still = 'opaque'; }
                x.remove(); r({ seen, said, still }); }, 4000);
        });
        return { csp, detect: user && user.ui ? user.ui.detectArtifacts : undefined,
            plain: await run('<html><head></head><body>' + probe + '</body></html>'),
            hidden: await run('<!--<head>--><html><body>' + probe + '</body></html>'), nav: await nav() };
    }""")
    expect("connect-src 'none'" in art["csp"], f"Open WebUI's IFRAME_CSP: {art['csp']!r}")
    expect(art["detect"] is False, f"detectArtifacts by default: {art['detect']!r}")
    for k in ("plain", "hidden"):
        got = set(str(art[k]).split(","))
        expect({"connect-src", "img-src", "script-src", "style-src"} <= got,
               f"an artifact ({k} <head>): refused {art[k]!r}, want its request, image, script and style sheet from another site refused")
    # (a prefetch: default-src, Chat's — the hidden one shows it; with IFRAME_CSP, its own default-src 'none' first)
    expect("default-src" in set(str(art["hidden"]).split(",")), f"an artifact's prefetch to another site: not refused ({art['hidden']!r})")
    nav = art["nav"]
    page.wait_for_timeout(1000)
    went = [u for u in out if "bn-e2e-nav" in u]
    said_nav = [e.get("text", "")[:200] for e in rec.events if e.get("t") == "console" and "frame" in e.get("text", "") and "example.com" in e.get("text", "")]
    expect("frame-src" in (nav.get("seen") or []) and not went,
           f"an artifact sending its own frame to another site: {nav}; requested {went[:2]}; the console: {said_nav[:3]}")
    expect((nav.get("said") or {}).get("pop") == "refused", f"an artifact's popup: {nav}")
    page.wait_for_timeout(1000)
    expect(page.url.startswith(origin()), f"the top page was navigated: {page.url}")
    sent = [u for u in out if "bn-e2e-" in u]
    expect(not sent, f"requested all the same: {sent[:6]}")
    shot(page, "07b-chat-images")
    # (Chromium's own words for what the sandbox refused: the top page's navigation, a popup)
    sandboxed = [r"Unsafe attempt to initiate navigation", r"allow-top-navigation", r"allow-popups"]
    probs = rec.problems(allow=[r"No token found in localStorage", r"example\.com/bn-e2e", r"Content Security Policy", *sandboxed])
    own = [p for p in rec.problems(allow=[r"No token found in localStorage", r"example\.com/bn-e2e", *sandboxed]) if "Content Security Policy" in p and "example.com" not in p]
    rec.save()
    expect(not own, f"CSP refused something of Open WebUI's own: {own[:4]}")
    expect(not probs, f"errors: {probs}")
    return ("Open WebUI's site: images, media, frames, requests, scripts and style sheets from itself only — its own load, another "
            "site's are refused, none requested; an artifact's too (its <head> hidden or not), and its frame cannot be sent to another "
            "site, nor a popup opened or the top page moved; artifacts open on a click")


def _owui_chat(f, md: str, title: str) -> str:
    """A conversation made through Open WebUI's own API (no model call): a question and MD as its answer; its id."""
    import uuid
    now = int(time.time())
    uid, aid = str(uuid.uuid4()), str(uuid.uuid4())
    # (no "models" on the question: an empty list would make it a question to several models, shown side by side)
    msgs = {uid: {"id": uid, "parentId": None, "childrenIds": [aid], "role": "user", "content": "show me", "timestamp": now},
            aid: {"id": aid, "parentId": uid, "childrenIds": [], "role": "assistant", "content": md, "model": "", "modelName": "",
                  "done": True, "timestamp": now}}
    chat = {"title": title, "models": [], "params": {}, "history": {"messages": msgs, "currentId": aid},
            "messages": [msgs[uid], msgs[aid]], "tags": [], "timestamp": now * 1000}
    r = owui_api(f, "/api/v1/chats/new", "POST", {"chat": chat})
    expect(r["status"] == 200, f"new chat {r['status']} {r['body'][:200]}")
    return json.loads(r["body"])["id"]


@check("browser", "chat-own-page-under-policy")
def chat_own_page(ctx):
    """Open WebUI's own page under Chat's policy (caddy/Caddyfile chat_csp: scripts, styles, workers and WebAssembly
    from itself only): an answer with a highlighted code block, a Mermaid diagram and an html block opened in the
    Artifacts panel by its Preview button (detectArtifacts is off) — each works, with no CSP error of Open WebUI's own;
    and a sandboxed frame made as Open WebUI's Python runner makes its own requests Open WebUI's pyodide.js with no CSP
    violation (the policy allows it; the runner itself: browser/chat-python-runner and the checks after it). No model
    call: the conversation is made through Open WebUI's own API."""
    import secrets
    need("open-webui")
    page, rec = ctx.page("chat-own-page")
    login(page)
    fl, f = chat_frame(page)
    tag = f"bnpolicy{secrets.token_hex(4)}"
    md = ("Here they are.\n\n```python\nprint(6 * 7)\n```\n\n```mermaid\ngraph TD\n  A[bnstart] --> B[bnend]\n```\n\n"
          f"```html\n<html><head></head><body><h1 id=\"bnart\">artifact {tag}</h1></body></html>\n```\n")
    cid = _owui_chat(f, md, f"Policy {tag}")
    done = []
    try:
        start = len(rec.events)
        fl, f = chat_frame(page, f"c/{cid}")

        def step(what, fn):
            try:
                return fn()
            except PwError as e:
                shot(page, "07c-chat-own-page-" + re.sub(r"[^a-z0-9]+", "-", what.lower())[:30])
                raise AssertionError(f"{what}: {str(e).splitlines()[0][:160]}; shown: {f.evaluate('() => document.body.innerText.slice(-400)')!r}; "
                                     f"errors: {rec.problems(start=start)[:8]}") from e
        step("the conversation", lambda: f.wait_for_function("t => document.body.innerText.includes(t)", arg="Here they are.", timeout=30000))
        # highlighted code (highlight.js, or the code editor)
        step("highlighted code", lambda: fl.locator(".hljs, .cm-editor").first.wait_for(timeout=20000))
        done.append("code highlighted")
        # Mermaid: the diagram drawn (its nodes' words in an svg)
        step("the Mermaid diagram", lambda: f.wait_for_function(
            "() => [...document.querySelectorAll('svg')].some((s) => s.textContent.includes('bnstart') && s.textContent.includes('bnend'))", timeout=45000))
        done.append("Mermaid diagram")
        # the Python runner's way of loading Pyodide (a sandboxed frame of its own, an opaque origin, asking for Open
        # WebUI's pyodide.js): the policy lets the request go — a frame made the same way requests the script with no
        # CSP violation (Chat's public route answers it: chat-python-runtime-public-and-exact)
        v = f.evaluate("""() => new Promise((r) => {
            const x = document.createElement('iframe'); x.setAttribute('sandbox', 'allow-scripts'); x.style.display = 'none';
            const on = (e) => { if (e.source === x.contentWindow) { window.removeEventListener('message', on); x.remove(); r(e.data); } };
            window.addEventListener('message', on);
            x.srcdoc = '<!doctype html><html><head><script>const seen = [];'
              + "document.addEventListener('securitypolicyviolation', (e) => seen.push(e.effectiveDirective));<" + "/script>"
              + '<script src="' + location.origin + '/pyodide/pyodide.js"><' + '/script></head><body><script>'
              + "setTimeout(() => parent.postMessage(seen.join(',') || 'none', '*'), 1500);<" + "/script></body></html>";
            document.body.append(x); setTimeout(() => r('no answer'), 8000); })""")
        expect(v == "none", f"Chat's policy refuses Open WebUI's own script in a sandboxed frame: {v!r}")
        done.append("Pyodide's script allowed in a sandboxed frame")
        # the artifact: opened by its Preview, in the Artifacts panel's sandboxed frame, with Open WebUI's policy in it
        fl.locator("button.run-code-button", has_text="Preview").first.click()
        art = fl.frame_locator("iframe[title='Content']")
        step("the artifact", lambda: art.locator("#bnart").wait_for(timeout=30000))
        expect(tag in art.locator("#bnart").inner_text(), "the artifact's text")
        srcdoc = fl.locator("iframe[title='Content']").first.get_attribute("srcdoc") or ""
        expect("connect-src 'none'" in srcdoc, "Open WebUI's IFRAME_CSP is not in the artifact's document")
        done.append("artifact opened in the Artifacts panel")
        shot(page, "07c-chat-own-page")
        page.wait_for_timeout(2000)
        own = [x for x in rec.problems(start=start, allow=[r"No token found in localStorage"]) if "Content Security Policy" in x or "securitypolicyviolation" in x]
        expect(not own, f"CSP refused something of Open WebUI's own: {own[:6]}")
    finally:
        try:
            owui_api(f, f"/api/v1/chats/{cid}", "DELETE")
        except Exception:  # noqa: BLE001 — the frame went away: the conversation stays (a test one)
            pass
    # (the frame made as the Python runner's, without the session cookie: above)
    # (and Open WebUI's Artifacts panel reaching into its own sandboxed frame — an opaque origin — on load: its own
    # error, whatever the policy)
    probs = rec.problems(allow=[r"No token found in localStorage", r"^401 GET \S+/pyodide/pyodide\.js",
                                r"Failed to read a named property 'addEventListener' from 'Window': Blocked a frame with origin"])
    rec.save()
    expect(not probs, f"errors: {probs}")
    return "; ".join(done) + " — no CSP error of Open WebUI's own"


def _run_python(ctx, name: str, code: str, want: str, shot_name: str):
    """A conversation whose answer is CODE in a Python block, made through Open WebUI's own API (no model call); its
    Run clicked, then (page, rec, mark, shown) once the block shows WANT on a line of its own, or an error (the runner's
    stderr), or 180 s passed. Skips when the admin turned code execution off (no Run button). The conversation is
    deleted afterwards (cleanup: called by the check through the returned function)."""
    import secrets
    need("open-webui")
    page, rec = ctx.page(name)
    login(page)
    fl, f = chat_frame(page)
    tag = f"bnpy{secrets.token_hex(4)}"
    cid = _owui_chat(f, f"Here it is.\n\n```python\n{code}\n```\n", f"Python {tag}")

    def cleanup():
        try:
            owui_api(f, f"/api/v1/chats/{cid}", "DELETE")
        except Exception:  # noqa: BLE001 — the frame went away: the conversation stays (a test one)
            pass
    try:
        fl, f = chat_frame(page, f"c/{cid}")
        f.wait_for_function("t => document.body.innerText.includes(t)", arg="Here it is.", timeout=30000)
        run = fl.locator("button.run-code-button", has_text="Run")
        if not run.count():
            raise Skip("Python runner not offered (code execution off)")
        mark = len(rec.events)
        run.first.click()
        try:
            f.wait_for_function("""w => document.body.innerText.split('\\n').some((l) => l.trim() === w)
                || /Error|Traceback|loadPyodide is not defined/.test(document.body.innerText.split('Here it is.').pop())""",
                                arg=want, timeout=180000)
        except PwError:
            pass
        page.wait_for_timeout(1500)
        shot(page, shot_name)
        shown = f.evaluate("() => document.body.innerText.split('Here it is.').pop()")
        return page, rec, mark, shown, cleanup
    except BaseException:
        cleanup()
        raise


def _away(events) -> list[str]:
    """The requests (answered or refused) to a host that is not one of the stack's own (HOST and its subdomains)."""
    from urllib.parse import urlsplit
    out = []
    for e in events:
        if e.get("t") in ("resp", "failed") and not e["url"].startswith(("data:", "blob:")):
            h = (urlsplit(e["url"]).hostname or "").lower()
            if h != HOST and not h.endswith("." + HOST):
                out.append(e["url"])
    return out


def _line(shown: str, want: str) -> bool:
    return any(x.strip() == want for x in shown.splitlines())


@check("browser", "chat-python-runner")
def chat_python_runner(ctx):
    """Open WebUI's Python runner: a Python block's Run prints 42. The runner runs Pyodide in a sandboxed frame of its
    own (an opaque origin: no cookie, Origin: null), which loads Pyodide's runtime and micropip from /pyodide/ — Chat's
    one public route (caddy/Caddyfile chat_runtime), served from our Open WebUI image (open-webui/: the wheels vendored
    into it, so nothing comes from another host). Before v0.25.1 the frame got the portal's 401 for pyodide.js. No model
    call."""
    page, rec, mark, shown, cleanup = _run_python(ctx, "chat-python-runner", "print(6 * 7)", "42", "07d-chat-python-runner")
    try:
        own = [x for x in rec.problems(start=mark) if "/pyodide/" in x]
        if not _line(shown, "42"):
            raise AssertionError(f"the Python runner did not print 42: {shown[-300:]!r}; its /pyodide/ answers: {own[:6]}; "
                                 f"errors: {rec.problems(start=mark)[:6]}")
        loaded = sorted({e["url"].rsplit("/", 1)[1] for e in rec.events[mark:] if e.get("t") == "resp" and "/pyodide/" in e["url"] and e["status"] == 200})
        expect(any(n.startswith("micropip-") for n in loaded), f"micropip not loaded from /pyodide/: {loaded}")
        away = _away(rec.events[mark:])
        expect(not away, f"the runner asked another host: {away[:4]}")
        rec.save()
        return f"Python run in the browser (Pyodide): 42 — loaded from Chat itself: {', '.join(loaded)}"
    finally:
        cleanup()


@check("browser", "chat-python-numpy")
def chat_python_numpy(ctx):
    """A vendored package works: `import numpy` in a Python block (Open WebUI installs it through micropip, from the
    wheel our image vendors under /pyodide/), and its answer is printed. No request leaves Chat."""
    code = "import numpy as np\nprint(int(np.arange(7).sum()) * 2)"
    page, rec, mark, shown, cleanup = _run_python(ctx, "chat-python-numpy", code, "42", "07e-chat-python-numpy")
    try:
        expect(_line(shown, "42"), f"numpy did not answer 42: {shown[-300:]!r}; errors: {rec.problems(start=mark)[:6]}")
        wheel = [e["url"] for e in rec.events[mark:] if e.get("t") == "resp" and "/pyodide/numpy-" in e["url"] and e["status"] == 200]
        expect(wheel, "numpy's wheel was not loaded from /pyodide/")
        away = _away(rec.events[mark:])
        expect(not away, f"the runner asked another host: {away[:4]}")
        rec.save()
        return "import numpy: 42, its wheel from /pyodide/"
    finally:
        cleanup()


@check("browser", "chat-python-not-vendored")
def chat_python_not_vendored(ctx):
    """A package our image does not vendor stays out of reach: `import requests` makes Open WebUI install it through
    micropip, whose lock names Pyodide's CDN for it — Chat's policy refuses that (connect-src: Chat itself only), so the
    block shows an error, the browser says it refused (a CSP violation), and no request to the CDN goes out."""
    page, rec, mark, shown, cleanup = _run_python(ctx, "chat-python-not-vendored", "import requests\nprint('bnrequests')", "bnrequests",
                                                  "07f-chat-python-not-vendored")
    try:
        expect(not _line(shown, "bnrequests"), "a package that is not vendored was imported")
        cdn = [e for e in rec.events[mark:] if e.get("t") in ("resp", "failed") and "cdn.jsdelivr.net" in e.get("url", "")]
        answered = [e["url"] for e in cdn if e["t"] == "resp"]
        expect(not answered, f"a request to the CDN was answered: {answered[:3]}")
        refused = [e for e in cdn if e["t"] == "failed" and "csp" in (e.get("error") or "").lower()]
        said = [e["text"] for e in rec.events[mark:] if e.get("t") == "console" and "cdn.jsdelivr.net" in e.get("text", "")
                and ("Content Security Policy" in e["text"] or "Refused to connect" in e["text"])]
        expect(refused or said, f"no CSP refusal seen for the CDN: {[e.get('error') for e in cdn][:3]} {rec.problems(start=mark)[:4]}")
        rec.save()
        return f"import requests: not available — the CDN refused by Chat's policy ({'blocked: csp' if refused else 'a CSP violation'}), nothing answered"
    finally:
        cleanup()


def _last_answer(f):
    return f.evaluate("() => { const m = [...document.querySelectorAll('.chat-assistant')]; return m.length ? m[m.length-1].innerText : null }")


@check("browser", "chat-streamed-answer")
def chat_send(ctx):
    need("open-webui")
    model = ENV.get("CLAUDE_BEDROCK_HAIKU_MODEL") or ENV.get("OWUI_TASK_MODEL")
    if not model:
        raise Skip("no Haiku model enabled")
    page, rec = ctx.page("chat-send")
    login(page)
    fl, f = chat_frame(page, f"?models={model}")
    sel = fl.locator("#model-selector-model-button").get_attribute("aria-label") or ""
    expect("Haiku" in sel, f"selected {sel!r}")
    # Every DOM change of the answer is recorded in the frame, so streaming is seen however fast the poll below is.
    f.evaluate("""() => { window.__bnLens = []; new MutationObserver(() => {
        const m = [...document.querySelectorAll('.chat-assistant')]; if (!m.length) return;
        const t = m[m.length - 1].innerText; if (!t.includes('≈') && t.trim()) window.__bnLens.push(t.length);
      }).observe(document.body, {subtree: true, childList: true, characterData: true}); }""")
    fl.locator("#chat-input").click()
    fl.locator("#chat-input").press_sequentially("Count from 1 to 40, numbers only, separated by spaces.")
    fl.locator("#chat-input").press("Enter")
    seen, t0 = [], time.time()
    while time.time() - t0 < 90:
        txt = _last_answer(f)
        if txt and (not seen or seen[-1] != txt):
            seen.append(txt)
        if txt and "≈" in txt:
            break
        page.wait_for_timeout(100)
    expect(seen, "no answer within 90 s")
    final = seen[-1]
    expect("40" in final, f"answer {final[:120]!r}")
    m = re.search(r"≈ (<?\$[0-9.,]+) · ([0-9,]+) in / ([0-9,]+) out · ([^·]+) · chat ≈", final)
    expect(m, f"no cost footer in {final[-160:]!r}")
    # Open WebUI batches screen updates, so a fast model may show a single partial answer before the whole one:
    # one shorter length before the longest is enough to prove streaming.
    lens = sorted(set(f.evaluate("window.__bnLens")))
    expect(len(lens) >= 2, f"answer arrived in one piece: no streaming observed (partial lengths {lens})")
    expect(any(e["t"] == "ws" for e in rec.events), "no WebSocket (socket.io) connection")
    # the task model (OWUI_TASK_MODEL) titles the new chat
    cid = re.search(r"/c/([0-9a-f-]{36})", f.url)
    expect(cid, f"no chat id in {f.url}")
    title, t0 = "", time.time()
    while time.time() - t0 < 45:
        r = owui_api(f, f"/api/v1/chats/{cid.group(1)}")
        title = json.loads(r["body"]).get("title", "") if r["status"] == 200 else ""
        if title and title != "New Chat":
            break
        page.wait_for_timeout(500)
    expect(title and title != "New Chat", f"chat not titled by the task model (title {title!r})")
    shot(page, "08-chat-answer")
    probs = rec.problems(allow=[r"No token found in localStorage"])
    rec.save()
    expect(not probs, f"errors: {probs}")
    return f"{model}: streamed in {len(lens)} growing steps, footer {m.group(0)[:70]}, titled {title[:30]!r}"


@check("browser", "chat-file-upload-rag")
def chat_rag(ctx):
    need("open-webui")
    model = ENV.get("CLAUDE_BEDROCK_HAIKU_MODEL") or ENV.get("OWUI_TASK_MODEL")
    if not ENV.get("OWUI_EMBED_MODEL") or not model:
        raise Skip("no embedding or Haiku model enabled")
    page, rec = ctx.page("chat-rag")
    login(page)
    fl, f = chat_frame(page, f"?models={model}")
    code = f"MAGENTA-OTTER-{int(time.time()) % 1000}"
    doc = (f"devos-ade e2e test document.\n\nThe secret codeword for this test is {code}.\n"
           "Nothing else in this file matters.\n").encode()
    fl.locator("input[type=file]:not(#camera-input)").first.set_input_files(
        files=[{"name": "e2e-codeword.txt", "mimeType": "text/plain", "buffer": doc}])
    # the upload is stored (RustFS) and embedded (Bedrock embeddings via LiteLLM) before it can be asked about
    fl.locator("text=e2e-codeword.txt").first.wait_for(timeout=30000)
    fid, status, t0 = None, "", time.time()
    while time.time() - t0 < 90 and status != "completed":
        if fid is None:
            r = owui_api(f, "/api/v1/files/")
            items = json.loads(r["body"]) if r["status"] == 200 else []
            items = items.get("items", []) if isinstance(items, dict) else items
            fid = next((i["id"] for i in items if (i.get("filename") or i.get("meta", {}).get("name")) == "e2e-codeword.txt"), None)
        if fid:
            r = owui_api(f, f"/api/v1/files/{fid}/process/status")
            status = json.loads(r["body"]).get("status", "") if r["status"] == 200 else ""
            expect(status != "failed", f"processing the upload failed: {r['body'][:200]}")
        if status != "completed":
            page.wait_for_timeout(500)
    expect(status == "completed", f"upload not processed within 90 s (file {fid}, status {status!r})")
    ctx.rag_file = fid
    fl.locator("#chat-input").click()
    fl.locator("#chat-input").press_sequentially("What is the secret codeword in the attached file? Reply with the codeword only.")
    fl.locator("#chat-input").press("Enter")
    t0, final = time.time(), ""
    while time.time() - t0 < 120:
        final = _last_answer(f) or ""
        if "≈" in final:
            break
        page.wait_for_timeout(250)
    shot(page, "09-chat-rag")
    expect("≈" in final, f"no complete answer within 120 s ({final[:120]!r})")
    expect(code in final, f"answer {final[:160]!r} lacks {code}")
    probs = rec.problems(allow=[r"No token found in localStorage"])
    rec.save()
    expect(not probs, f"errors: {probs}")
    return f"uploaded a .txt (processed: embedded with {ENV['OWUI_EMBED_MODEL']}), {model} answered {code}"


# --- Admin (LiteLLM UI) and Files (RustFS console): the portal signs you in (portal/portal/appsso.py) ---

# (LiteLLM's Notifications button: in its top bar at every width, where its menu folds away on a phone)
SSO_DONE = {"admin": 'role=button[name="Notifications"]', "files": "text=Create Bucket"}
SSO_FORM = {"admin": "input[name=username]", "files": "input[placeholder='Please enter account']"}
# What LiteLLM's own Logout leaves in its page until its form replaces it (nothing the owner sees): the session it has
# just revoked answers 401 on whichever of LiteLLM's API routes the dashboard still asks — requests in flight and
# refetches, so which ones is timing (/key/list, /v2/guardrails/list, …) — and the new page cuts off the rest ("Failed
# to fetch"). Its pages and the portal's hand-off are never excused, and nothing before the Logout is.
AFTER_OWN_LOGOUT_OK = [r"^401 [A-Z]+ " + re.escape(origin("admin")) + r"/(?!ui(/|\?|$)|\.bn/)",
                       r"console.error Failed to .*Failed to fetch"]


def sso_signed_in(page, scope, rec, app: str, where: str, label: str = "") -> str:
    """APP in SCOPE (its frame, or its own page), signed in by the portal: its dashboard appears and its own sign-in
    form never does, the hand-off went through /.bn/sso on the app's own host, and no password, key or app session is
    in any URL the browser loaded. Returns a short description."""
    done, form = scope.locator(SSO_DONE[app]).first, scope.locator(SSO_FORM[app]).first
    t0 = time.time()
    while True:
        if form.count() and form.is_visible():
            shot(page, f"{label or app}-own-form", mask_locators=[scope.locator("input")])
            raise AssertionError(f"[{where}] {app}'s own sign-in form showed (see shots/{label or app}-own-form.png)")
        if done.count() and done.is_visible():
            break
        if time.time() - t0 > 45:
            shot(page, f"{label or app}-not-signed-in", mask_locators=[scope.locator("input")])
            raise AssertionError(f"[{where}] not signed in within 45 s (see shots/{label or app}-not-signed-in.png)")
        page.wait_for_timeout(250)
    hops = [e for e in rec.responses("^" + re.escape(origin(app)) + r"/\.bn/sso\?") if e["method"] == "GET"]
    expect(not hops or hops[-1]["status"] in (200, 303), f"[{where}] the automatic sign-in on {origin(app)} answered {hops[-1:]}")
    secrets = [ENV["LITELLM_UI_PASSWORD"], ENV["RUSTFS_SECRET_KEY"], ENV["PORTAL_PASSWORD"]]
    secrets += [c["value"] for c in page.context.cookies(origin(app)) if c["name"] == "token"]
    if app == "files":   # the console's credentials from the hand-off (temporary ones), where it keeps its own
        f = frame_of(page, "files") if scope is not page else page
        creds = f.evaluate("JSON.parse(localStorage.getItem('auth.credentials') || '{}')")
        expect(creds.get("SessionToken") and creds.get("Expiration") and creds.get("AccessKeyId") != ENV["RUSTFS_ACCESS_KEY"],
               f"[{where}] no temporary console credentials stored")
        secrets += [creds["SecretAccessKey"], creds["SessionToken"]]
        trace = "temporary credentials in the console's storage"
    else:   # the marker only /.bn/sso sets
        trace = "the bn_sso marker" if any(c["name"] == "bn_sso" for c in page.context.cookies(origin(app))) else ""
    # A new window's first requests come before its recorder is attached: then the hand-off's own trace has to do.
    expect(hops or trace, f"[{where}] no automatic sign-in on {origin(app)} (no /.bn/sso, no trace of one)")
    leaked = [e["url"][:80] for e in rec.events if e.get("url") and any(v and v in e["url"] for v in secrets)]
    expect(not leaked, f"[{where}] a password, key or session in a URL: {leaked}")
    how = f"{len(hops)} hand-off{'s' if len(hops) != 1 else ''}" if hops else f"before the window was watched: {trace}"
    return f"{where}: signed in by the portal ({how}), no form"


def drop_pass(page):
    """Expires the files host's pass cookie (a load seconds after a hand-off goes straight through) and nothing else.
    (Not clear_cookies(name=…): Chromium clears every cookie and adds the others back, and requests in flight meanwhile
    go out without the session.)"""
    page.context.add_cookies([{"name": "bn_sso_pass", "value": "", "domain": host_of("files"), "path": "/", "expires": 1}])


def _admin_loads(events) -> list[str]:
    """The Admin host's page loads (frame or window) among EVENTS: "status path" each."""
    return [f"{e['status']} {url_path(e['url'])}" for e in events
            if e["t"] == "resp" and e.get("type") == "document" and e["url"].startswith(origin("admin") + "/")]


def litellm_logout(page, fl, rec, label: str) -> int:
    """LiteLLM's own Logout (account menu) in the Admin frame FL: its own form shows (?sso=off), never a new automatic
    sign-in. Returns where the page's events from the click on start (rec.events[i:]); on failure says where LiteLLM
    went instead."""
    menu = fl.get_by_role("button", name=re.compile(r"^Account menu"))
    fold = fl.get_by_role("button", name="Open navigation")
    menu.or_(fold).first.wait_for()
    if not menu.count():   # a phone: LiteLLM's menu, with the account in it, is folded away
        fold.click()
    menu.click()
    logout = fl.get_by_text(re.compile(r"^(Log ?out|Sign ?out)$", re.I)).first
    logout.wait_for()
    since = len(rec.events)
    logout.click()
    try:
        fl.locator(SSO_FORM["admin"]).wait_for(timeout=30000)
    except Exception as e:  # noqa: BLE001 — explained below
        shot(page, f"{label}-after-logout", mask_locators=[fl.locator("input")])
        where = url_path(frame_of(page, "admin").url)
        raise AssertionError(f"LiteLLM's Logout: no form within 30 s ({type(e).__name__}), the frame is at {where}; page "
                             f"loads since the click: {_admin_loads(rec.events[since:]) or 'none'} "
                             f"(see shots/{label}-after-logout.png)") from None
    after = rec.events[since:]
    loads = _admin_loads(after)
    expect(not any("/.bn/sso" in x for x in loads), f"LiteLLM's Logout went through the automatic sign-in: {loads}")
    expect("sso=off" in frame_of(page, "admin").url, f"after LiteLLM's Logout: {frame_of(page, 'admin').url}")
    return since


@check("browser", "admin-litellm-ui")
def admin_ui(ctx):
    need("litellm")
    page, rec = ctx.page("admin")
    login(page)
    page.click(".tab[data-tab=admin]")
    fl = page.frame_locator("iframe[data-app=admin]")
    how = sso_signed_in(page, fl, rec, "admin", "Admin tab (portal frame)", "admin-frame")
    tok = [c for c in page.context.cookies(origin("admin")) if c["name"] == "token"]
    expect(tok and not tok[0]["httpOnly"] and tok[0]["sameSite"] == "Lax" and tok[0]["domain"] == host_of("admin"),
           f"LiteLLM's token cookie: {[(c['domain'], c['httpOnly'], c['sameSite']) for c in tok]}")
    mark = [c for c in page.context.cookies(origin("admin")) if c["name"] == "bn_sso"]
    expect(mark and mark[0]["httpOnly"] and mark[0]["sameSite"] == "Strict", f"sign-in marker: {mark}")
    shot(page, "11-admin-signed-in")
    f = frame_of(page, "admin")
    t0 = time.time()
    row = lambda alias, text: re.search(rf"(?m)^{re.escape(alias)}\s*$", text)   # its row's first line (not claude-code-terminal)
    while time.time() - t0 < 30 and not row("claude-code", f.inner_text("body")):
        page.wait_for_timeout(500)
    body = f.inner_text("body")
    for alias, budget in (("claude-code", ENV["BUDGET_CLAUDE_CODE"]), ("open-webui", ENV["BUDGET_OPENWEBUI"]),
                          ("setup", ENV["BUDGET_SETUP"])):
        m = row(alias, body)
        expect(m, f"key {alias} not listed")
        i = m.start()
        m = re.search(r"of \$([0-9][0-9,]*(?:\.[0-9]+)?)", body[i:i + 400])   # "… $0.0004 of $50" in its row
        shown = m.group(1).replace(",", "") if m else ""
        # LiteLLM's key table shows budgets in whole dollars (the throwaway's $0.04 reads "$0"): compare at that precision
        ok = bool(shown) and (abs(float(shown) - float(budget)) < 1e-9 if "." in shown else abs(float(shown) - float(budget)) < 1)
        expect(ok, f"{alias}: budget shown {shown or 'nowhere'}, want {budget}")
    shot(page, "12-admin-keys")
    # LiteLLM's own Logout ends its session and shows its own form (PROXY_LOGOUT_URL: ?sso=off), not a new sign-in
    keys_before = tok[0]["value"]
    at = litellm_logout(page, fl, rec, "admin-frame")
    after = [c["value"] for c in page.context.cookies(origin("admin")) if c["name"] == "token"]
    expect(keys_before not in after, "LiteLLM's Logout left its session cookie")
    shot(page, "12a-admin-own-logout", mask_locators=[fl.locator("input")])
    # nothing on the admin host may fail until the Logout; after it, only what the session it revoked leaves behind
    probs = rec.problems(host_filter="admin.", allow=[r"console.error Failed to .*Failed to fetch"], end=at)
    probs += rec.problems(host_filter="admin.", allow=AFTER_OWN_LOGOUT_OK, start=at)
    rec.save()
    expect(not probs, f"errors: {probs}")
    return (f"{how}; token cookie host-only, Lax, readable by the dashboard; marker HttpOnly, Strict; Virtual Keys with "
            "claude-code/open-webui/setup and their budgets; LiteLLM's Logout → its own form")


@check("browser", "admin-litellm-logout-early")
def admin_logout_early(ctx):
    """LiteLLM's Logout before its UI has its own settings (PROXY_LOGOUT_URL comes with them: a slow LiteLLM, or Logout
    right after the page loads) reloads the page it is on instead; the portal sends that load to LiteLLM's form as well,
    never into a new automatic sign-in. The settings request is refused here, so this path runs every time. Admin opened
    again (the portal page reloaded) signs in as before."""
    need("litellm")
    page, rec = ctx.page("admin-logout-early")
    ui_settings = re.compile("^" + re.escape(origin("admin")) + r"/sso/get/ui_settings")
    page.route(ui_settings, lambda route: route.abort())
    login(page)
    page.click(".tab[data-tab=admin]")
    fl = page.frame_locator("iframe[data-app=admin]")
    sso_signed_in(page, fl, rec, "admin", "Admin tab, LiteLLM without its settings", "admin-early")
    at = litellm_logout(page, fl, rec, "admin-early")
    reloaded = [x for x in _admin_loads(rec.events[at:]) if x.startswith("302 /ui")]
    expect(reloaded, "LiteLLM's Logout went to its form by itself although its settings never came: this check no "
                     "longer covers the reload (LiteLLM changed?)")
    shot(page, "12c-admin-logout-early", mask_locators=[fl.locator("input")])
    # Admin opened again: the portal page reloaded makes the frame anew — a load by the portal, not by LiteLLM's page
    page.unroute(ui_settings)
    since = len(rec.events)
    page.reload()
    page.wait_for_selector(".shell")
    if not page.locator("iframe[data-app=admin]").is_visible():
        page.click(".tab[data-tab=admin]")
    fl.locator(SSO_DONE["admin"]).first.wait_for(timeout=45000)
    again = [x for x in _admin_loads(rec.events[since:]) if "/.bn/sso" in x]
    expect(len(again) == 1 and again[0].startswith("303 "), f"Admin opened again: automatic sign-ins {again}")
    # the settings request refused on purpose throughout; before the Logout and after Admin is opened again nothing
    # else may fail, in between only what the session the Logout revoked leaves behind
    refused = [r"FAILED GET .*/sso/get/ui_settings ", r"console.error Failed to load resource: net::ERR_FAILED",
               r"console.error Failed to .*Failed to fetch"]
    probs = rec.problems(host_filter="admin.", allow=refused, end=at)
    probs += rec.problems(host_filter="admin.", allow=refused + AFTER_OWN_LOGOUT_OK, start=at, end=since)
    probs += rec.problems(host_filter="admin.", allow=refused, start=since)
    rec.save()
    expect(not probs, f"errors: {probs}")
    return (f"Logout before LiteLLM's settings: it reloads ({reloaded[0]}) → the portal sends it to its own form, no "
            "automatic sign-in; Admin opened again: signed in by the portal")


@check("browser", "admin-litellm-popout")
def admin_popout(ctx):
    need("litellm")
    page, rec = ctx.page("admin-popout")
    login(page)
    with page.context.expect_page() as pop:
        page.click("a.popout[data-app=admin]")
    win = rec.attach(pop.value)
    how = sso_signed_in(win, win, rec, "admin", "Admin pop-out window", "admin-popout")
    shot(win, "12b-admin-popout")
    probs = rec.problems(host_filter="admin.", allow=[r"console.error Failed to .*Failed to fetch"])
    rec.save()
    expect(not probs, f"errors: {probs}")
    return how


@check("browser", "admin-litellm-own-sign-in-form")
def admin_form(ctx):
    """The fallback: Home's Credentials fold links LiteLLM's own form (?sso=off), which still signs in with the pair in
    .env, as the walkthrough names it (Username, Password, Login)."""
    need("litellm")
    page, rec = ctx.page("admin-form")
    login(page)
    page.click("#logins-more summary")
    link = page.locator("a.form-link[data-form=admin]")
    link.wait_for(timeout=10000)
    href = link.get_attribute("href")
    expect(href == origin("admin") + "/ui/login/?sso=off" and link.get_attribute("target") == "_blank", f"Its sign-in form → {href}")
    shot(page, "13-home-credentials")
    with page.context.expect_page() as pop:
        link.click()
    win = rec.attach(pop.value)
    win.locator(SSO_FORM["admin"]).wait_for(timeout=45000)
    expect(not rec.responses(r"/\.bn/sso\?"), "LiteLLM's own form went through the automatic sign-in")
    labels = " ".join(win.locator("label").all_inner_texts())
    submit = win.locator("button[type=submit]").first.inner_text().strip()
    expect("Username" in labels and "Password" in labels and re.fullmatch(r"(?i)log ?in", submit),
           f"LiteLLM's sign-in form: labels {labels!r}, button {submit!r}")
    win.fill(SSO_FORM["admin"], ENV["LITELLM_UI_USER"])
    win.fill("input[name=password]", ENV["LITELLM_UI_PASSWORD"])
    shot(win, "13a-admin-own-form", mask=["input"])
    win.click("button[type=submit]")
    win.locator(SSO_DONE["admin"]).first.wait_for(timeout=45000)
    rec.save()
    return f"Home → Credentials → {url_path(href)}: LiteLLM's form ({labels!r}, {submit!r}) signs in with the .env pair"


# --- Files (RustFS console) ---

RUSTFS_FILE = f"e2e-probe-{int(time.time())}.txt"


def rshot(page, scope, name: str):
    """A screenshot of the RustFS console with its sign-in hidden: the console shows the access key (user menu) and
    the login form holds both keys — both are masked."""
    return shot(page, name, mask_locators=[scope.get_by_text(ENV["RUSTFS_ACCESS_KEY"]), scope.locator("input")])
RUSTFS_BODY = b"hello from the devos-ade e2e suite (rustfs console)"


def rustfs_flow(page, scope, rec, label: str, where: str) -> list[str]:
    """The full RustFS console flow in SCOPE (the page or the Files frame): signed in by the portal, buckets, open
    shared, upload, download, delete, the console's own Logout (its form), then a reload signs in again. Returns the
    steps done; raises on the first failing step."""
    steps = []
    acct = scope.locator(SSO_FORM["files"])
    rec.mark("rustfs: automatic sign-in")
    sso_signed_in(page, scope, rec, "files", where, label)
    steps.append("signed in by the portal")
    for bucket in ("openwebui", "shared"):   # the list loads after the "Create Bucket" button: wait for each row
        try:
            scope.locator("tr", has_text=bucket).first.wait_for(timeout=20000)
        except Exception:
            rshot(page, scope, f"{label}-no-{bucket}")
            raise AssertionError(f"[{where}] bucket {bucket} not listed (see shots/{label}-no-{bucket}.png)")
    steps.append("buckets")
    rshot(page, scope, f"{label}-buckets")
    scope.get_by_text("shared", exact=True).first.click()
    scope.locator("text=Upload File/Folder").first.wait_for(timeout=20000)
    steps.append("open bucket")
    scope.get_by_text("Upload File/Folder").first.click()
    scope.locator("input[name=upload-files]").set_input_files(
        files=[{"name": RUSTFS_FILE, "mimeType": "text/plain", "buffer": RUSTFS_BODY}])
    with page.expect_response(lambda r: RUSTFS_FILE in r.url and r.request.method == "PUT", timeout=30000):
        scope.get_by_role("button", name="Start Upload").click()
    rec.mark("rustfs: upload")
    scope.locator("tr", has_text=RUSTFS_FILE).first.wait_for(timeout=30000)
    puts = [e for e in rec.responses(r"/shared/" + re.escape(RUSTFS_FILE)) if e["method"] == "PUT"]
    expect(puts and puts[-1]["status"] == 200, f"[{where}] upload PUT: {puts}")
    steps.append("upload")
    page.keyboard.press("Escape")
    rshot(page, scope, f"{label}-uploaded")
    scope.get_by_label(f"Actions: {RUSTFS_FILE}").click()
    with page.expect_download(timeout=30000) as dl:
        scope.get_by_role("menuitem", name="Download").click()
    data = Path(dl.value.path()).read_bytes()
    expect(data == RUSTFS_BODY, f"[{where}] downloaded {len(data)} bytes, not the uploaded content")
    steps.append("download")
    scope.get_by_label(f"Actions: {RUSTFS_FILE}").click()
    scope.get_by_role("menuitem", name="Delete").click()
    rec.mark("rustfs: delete")
    confirm = scope.get_by_role("button", name=re.compile(r"^(Delete|Confirm|OK)$"))
    confirm.last.click()
    t0 = time.time()
    while time.time() - t0 < 20 and scope.locator("tr", has_text=RUSTFS_FILE).count():
        page.wait_for_timeout(300)
    expect(not scope.locator("tr", has_text=RUSTFS_FILE).count(), f"[{where}] object still listed after Delete")
    dels = [e for e in rec.responses(re.escape(RUSTFS_FILE)) if e["method"] in ("DELETE", "POST")]
    expect(dels and all(e["status"] in (200, 204) for e in dels), f"[{where}] delete requests {dels}")
    steps.append("delete")
    scope.get_by_label("User menu").click()
    scope.get_by_role("menuitem", name=re.compile(r"Log ?out|Sign ?out", re.I)).click()
    rec.mark("rustfs: logout")
    acct.wait_for(timeout=20000)   # the console's own Logout: its own form (client-side, no new sign-in)
    steps.append("logout (its form)")
    f = frame_of(page, "files") if scope is not page else page
    drop_pass(page)   # (a reload seconds after a hand-off would go straight through)
    mints = len(rec.responses(r"/\.bn/sso\?mint=1&"))
    f.goto(f.url)   # a reload of that page: the portal signs in again, with new credentials (Logout cleared them)
    rec.mark("rustfs: reload")
    sso_signed_in(page, scope, rec, "files", where + " after a reload", label + "-again")
    expect(len(rec.responses(r"/\.bn/sso\?mint=1&")) == mints + 1, f"[{where}] no new credentials after the console's Logout")
    steps.append("reload: signed in again")
    return steps


def _rustfs_check(ctx, name: str, in_frame: bool):
    need("rustfs")
    page, rec = ctx.page(name)
    login(page)
    if in_frame:
        page.click(".tab[data-tab=files]")
        page.wait_for_selector("iframe[data-app=files]")
        scope = page.frame_locator("iframe[data-app=files]")
        where = "Files tab (portal frame)"
    else:
        with page.context.expect_page() as pop:
            page.click("a.popout[data-app=files]")
        page = rec.attach(pop.value)
        scope = page
        where = "Files pop-out window"
    steps = []
    try:
        steps = rustfs_flow(page, scope, rec, name, where)
    finally:
        rec.save()
        rshot(page, scope, f"{name}-end")
    # Every request to the files host must have worked: no CORS, Host or signature errors, no 4xx/5xx.
    probs = rec.problems(host_filter="files.", allow=[
        r"401 GET .*/rustfs/admin/v3/.*",  # the console probes its session (after its own Logout)
        # its own sign-in page (after its Logout) prefetches its server-config page, which RustFS answers 401 without
        # credentials (upstream)
        r"401 GET .*/rustfs/console/config/__next\..*\.txt\?_rsc=",
        r"400 GET .*\?(retention|legal-hold)=$",  # object details on a bucket without object lock (upstream)
    ])
    expect(not probs, f"[{where}] after {'/'.join(steps)}: {probs[:6]}")
    return f"{where}: " + " → ".join(steps) + " (no failed requests or console errors)"


@check("browser", "files-rustfs-in-portal-frame")
def files_frame(ctx):
    return _rustfs_check(ctx, "files-frame", in_frame=True)


@check("browser", "files-rustfs-popout")
def files_popout(ctx):
    return _rustfs_check(ctx, "files-popout", in_frame=False)


RUSTFS_PAGES = ("browser", "table-catalog", "access-keys", "policies", "users", "user-groups", "import-export", "status",
                "rebalance", "pool-decommission", "events", "replication", "lifecycle", "site-replication", "tiers",
                "events-target", "audit-target", "sse", "oidc", "settings", "license")


@check("browser", "files-rustfs-console-pages")
def files_pages(ctx):
    """Signed in to the console by the portal (Files tab): every page of its sidebar, and browsing the openwebui
    bucket (the files Open WebUI stored, e.g. the RAG upload) down to an object's details."""
    need("rustfs")
    page, rec = ctx.page("files-pages")
    login(page)
    page.click(".tab[data-tab=files]")
    fl = page.frame_locator("iframe[data-app=files]")
    sso_signed_in(page, fl, rec, "files", "Files tab (portal frame)", "files-pages")
    # The console still asks for the account (its user policy) after its dashboard shows: a reload in the middle
    # cancels that, and the console logs "Failed to fetch user policy" (v0.42.0's run). Its first load finishes first.
    try:
        frame_of(page, "files").wait_for_load_state("networkidle", timeout=15000)
    except PwError:
        pass
    # a reload uses the credentials it has (from this portal session and key pair): no new ones
    mints = len(rec.responses(r"/\.bn/sso\?mint=1&"))
    drop_pass(page)
    frame_of(page, "files").goto(origin("files") + "/rustfs/console/")
    sso_signed_in(page, fl, rec, "files", "Files tab reloaded", "files-pages-reload")
    expect(len(rec.responses(r"/\.bn/sso\?mint=1&")) == mints, "a reload of the console made new credentials")
    empty, visited = [], 0
    for name in RUSTFS_PAGES:
        link = fl.locator(f"a[href$='/rustfs/console/{name}/'], a[href$='/rustfs/console/{name}']")
        if not link.count():
            empty.append(f"{name}: no link")
            continue
        rec.mark(f"page {name}")
        link.first.click()
        # the page is there once the frame shows its URL and its main area has content
        f, n, t0 = frame_of(page, "files"), 0, time.time()
        while time.time() - t0 < 20:
            f = frame_of(page, "files")
            n = len(fl.locator("#main-content").inner_text().strip()) if f.url.rstrip("/").endswith("/" + name) else 0
            if n >= 20:
                break
            page.wait_for_timeout(200)
        if n < 20:
            empty.append(f"{name}: empty or not reached")
        visited += 1
    rshot(page, fl, "files-pages-last")
    fl.locator("a[href$='/rustfs/console/browser/']").first.click()
    fl.get_by_text("openwebui", exact=True).first.click()
    fl.locator("text=Upload File/Folder").first.wait_for(timeout=20000)
    rows = fl.locator("tbody tr")
    detail = "openwebui bucket"
    if getattr(ctx, "rag_file", None):   # the chat upload of chat-file-upload-rag is stored here
        row = fl.locator("tbody tr", has_text="e2e-codeword.txt")
        row.first.wait_for(timeout=20000)
        detail += ": holds the chat upload e2e-codeword.txt"
        row.first.locator("button.text-primary").first.click()
        fl.locator("text=Object Details").first.wait_for(timeout=20000)
        detail += ", object details open"
    else:
        rows.first.wait_for(timeout=20000)
        detail += f": {rows.count()} row(s)"
    rshot(page, fl, "files-openwebui-bucket")
    rec.save()
    # Rebalance / Pool Decommission ask /rustfs/admin/v3/rebalance/status, which a single-pool RustFS answers 404
    # (the pages then say "Unsupported"): upstream behaviour, not a devos-ade problem.
    # Object details ask for ?retention= and ?legal-hold=, which a bucket without object lock answers 400 (the
    # panel then shows them empty): upstream console behaviour as well.
    probs = rec.problems(host_filter="files.", allow=[r"404 GET .*/rustfs/admin/v3/rebalance/status",
                                                      r"400 GET .*\?(retention|legal-hold)=$"])
    expect(not empty, f"pages without content: {empty}")
    expect(not probs, f"errors: {probs[:6]}")
    return f"{visited} console pages load without errors; {detail}"


@check("browser", "files-rustfs-own-sign-in-form")
def files_form(ctx):
    """The fallback: the console's own form (?sso=off, linked from Home's Credentials) still signs in with the key
    pair from .env, as the walkthrough names it (Account, Key, Login)."""
    need("rustfs")
    page, rec = ctx.page("files-form")
    login(page)
    page.click("#logins-more summary")
    link = page.locator("a.form-link[data-form=files]")
    link.wait_for(timeout=10000)
    href = link.get_attribute("href")
    expect(href == origin("files") + "/rustfs/console/auth/login/?sso=off", f"Its sign-in form → {href}")
    page.goto(href)
    acct = page.locator(SSO_FORM["files"])
    acct.wait_for(timeout=45000)
    expect(not rec.responses(r"/\.bn/sso\?"), "the console's own form went through the automatic sign-in")
    expect(page.get_by_role("button", name="Login", exact=True).count() == 1, "RustFS has no Login button")
    labels = page.locator("label").all_inner_texts()
    expect("Account" in labels and "Key" in labels, f"RustFS's sign-in labels {labels}")
    acct.fill(ENV["RUSTFS_ACCESS_KEY"])
    page.locator("input[placeholder='Please enter key']").fill(ENV["RUSTFS_SECRET_KEY"])
    rshot(page, page, "files-own-form")
    page.get_by_role("button", name="Login", exact=True).click()
    page.locator(SSO_DONE["files"]).first.wait_for(timeout=30000)
    rec.save()
    return f"{url_path(href)}: the console's form (Account, Key, Login) signs in with the .env key pair"


@check("browser", "apps-portal-login-first")
def apps_portal_login_first(ctx):
    """A browser without a portal session gets the portal's login on the Admin and Files hosts (never the apps' own
    forms); signing in there returns to the app, signed in to it as well."""
    need("litellm")
    need("rustfs")
    page, rec = ctx.page("apps-portal-login-first")
    seen = []
    for app, path in (("admin", "/ui/"), ("files", "/rustfs/console/")):
        page.goto(origin(app) + path)
        page.wait_for_url(re.compile("^" + re.escape(origin()) + r"/login\?next="), timeout=20000)
        expect(page.locator("#password").count() == 1 and page.locator(SSO_FORM[app]).count() == 0, f"{app}: not the portal's login")
        seen.append(app)
    shot(page, "14-apps-portal-login-first")
    page.fill("#password", ENV["PORTAL_PASSWORD"])   # on files' redirect: back to the console afterwards
    page.click("form[action='/login'] button[type=submit]")
    page.wait_for_url(re.compile("^" + re.escape(origin("files"))), timeout=30000)
    a = sso_signed_in(page, page, rec, "files", "Files after the portal's login", "files-after-login")
    page.goto(origin("admin") + "/ui/")
    b = sso_signed_in(page, page, rec, "admin", "Admin, same browser", "admin-after-login")
    rec.save()
    return f"no session → portal login on {' and '.join(seen)}; then {a}; {b}"


# --- the same-site guard (caddy/Caddyfile not_from_preview) ---

@check("browser", "same-site-guard")
def same_site_guard(ctx):
    """Every app host refuses a script's request from another host of the same site — what a preview over remote access
    is (every Service of a tailnet is one site), and what the stack's own hosts are to each other here. From a page of
    another host of the site with no policy of its own (Caddy's own health answer, /caddy-health, on any name under the site),
    signed in: fetches to the portal, Files and the Code page, a no-cors POST and a form post to Admin — each with the
    session cookie (same-site: SameSite=Strict sends it), each refused by Caddy before the app; a plain image from the
    portal passes (page loads too: every other check here runs with the guard on); an opaque origin (a sandboxed frame
    the page makes) is refused too. From the Chat page, Chat's own policy (caddy/Caddyfile chat_csp) stops the same
    image, fetch and form post, and a style sheet from the portal, before anything goes out (a securitypolicyviolation
    each, nothing sent): it allows no load from another host, so its 200 control is an image of Open WebUI's own
    (same-origin). Chromium reports no response for a fetch whose answer CORS refuses, so the raw network events (CDP)
    are read."""
    page, rec = ctx.page("same-site-guard")
    login(page)
    urls, sent, got = {}, {}, {}

    def watch(pg):
        cdp = pg.context.new_cdp_session(pg)
        cdp.send("Network.enable")
        cdp.on("Network.requestWillBeSent", lambda e: urls.setdefault(e["request"]["url"], e["requestId"]))
        cdp.on("Network.requestWillBeSentExtraInfo", lambda e: sent.__setitem__(e["requestId"], {k.lower(): v for k, v in (e.get("headers") or {}).items()}))
        cdp.on("Network.responseReceivedExtraInfo", lambda e: got.__setitem__(e["requestId"], (e.get("statusCode"), {k.lower(): v for k, v in (e.get("headers") or {}).items()})))
        return cdp

    # (a host of the site no app answers: Caddy's own health answer there, no policy — the page a preview's script would
    # be on; the unknown host's own page has a strict policy of its own since UX-10, which would stop these first)
    src = origin("bn-guard-src") + "/caddy-health"
    page.goto(src)
    page.wait_for_load_state("load")
    cdp = watch(page)
    targets = {"portal fetch": origin() + "/api/summary?bn-guard=1", "files fetch": origin("files") + "/rustfs/console/?bn-guard=1",
               "admin no-cors POST": origin("admin") + "/key/generate?bn-guard=1",
               # (Check for updates: were it let through, the portal would still refuse it — no X-Requested-With)
               "portal update-check no-cors POST": origin() + "/api/update/check?bn-guard=1"}
    if (ENV.get("CODE_ENABLED") or "").lower() == "true":
        targets["code fetch"] = origin("code") + "/api/state?bn-guard=1"
    form_url = origin("admin") + "/key/delete?bn-guard=form"
    img_url = origin() + "/static/logo.svg?bn-guard=img"
    run_js = """async ([t, formUrl, imgUrl]) => {
        for (const [k, u] of Object.entries(t)) {
          try { await fetch(u, k.includes('POST') ? { method: 'POST', mode: 'no-cors', credentials: 'include', body: 'x' } : { credentials: 'include' }); }
          catch (e) { /* refused: no CORS answer */ }
        }
        // a form post (a page load, but POST) into a hidden frame
        const f = document.createElement('iframe'); f.name = 'bnguard'; f.hidden = true; document.body.append(f);
        const form = document.createElement('form'); form.method = 'post'; form.target = 'bnguard'; form.action = formUrl;
        document.body.append(form); form.submit();
        // the control: a plain image from another host of the site passes the guard
        await new Promise((r) => { const i = new Image(); i.onload = i.onerror = r; i.src = imgUrl; });
    }"""
    page.evaluate(run_js, [targets, form_url, img_url])
    page.wait_for_timeout(2500)
    seen = {}
    for what, u in [*targets.items(), ("admin form post", form_url), ("control image", img_url)]:
        rid = urls.get(u)
        h = sent.get(rid) or {}
        st, rh = got.get(rid) or (None, {})
        expect(rid is not None and h and st is not None, f"{what}: no request/response seen ({rid}, {bool(h)}, {st})")
        expect(h.get("sec-fetch-site") == "same-site", f"{what}: Sec-Fetch-Site {h.get('sec-fetch-site')!r}")
        expect("bn_session=" in (h.get("cookie") or ""), f"{what}: the session cookie was not even sent (the check would prove nothing)")
        refused = rh.get("x-bn-refused") or ""
        if what == "control image":
            expect(st == 200 and not refused, f"the control (a same-site image from the portal): {st} {refused!r}")
        else:
            expect(st == 403 and "same-site guard" in refused, f"{what}: {st} X-Bn-Refused {refused!r}")
        seen[what] = st
    # an opaque origin — a sandboxed frame the page makes (no allow-same-origin): Origin null, Sec-Fetch-Site cross-site;
    # refused too (a frame of another process: Playwright's own events see it)
    opaque = {}
    page.on("response", lambda r: opaque.setdefault(r.url, r) if "bn-guard=null" in r.url else None)
    null_post, null_form = origin("admin") + "/key/generate?bn-guard=null", origin("admin") + "/key/delete?bn-guard=null-form"
    page.evaluate("""([p, f]) => { const fr = document.createElement('iframe'); fr.setAttribute('sandbox', 'allow-scripts allow-forms'); fr.hidden = true;
        fr.srcdoc = '<!doctype html><script>fetch(' + JSON.stringify(p) + ', { method: "POST", mode: "no-cors", credentials: "include", body: "x" })'
          + '.finally(() => { const fo = document.createElement("form"); fo.method = "post"; fo.action = ' + JSON.stringify(f) + ';'
          + ' document.body.append(fo); fo.submit(); });<' + '/script>';
        document.body.append(fr); }""", [null_post, null_form])
    page.wait_for_timeout(2500)
    for what, u in (("opaque no-cors POST", null_post), ("opaque form post", null_form)):
        r = opaque.get(u)
        refused = (r.header_value("x-bn-refused") if r else None) or ""
        expect(r is not None and r.status == 403 and "opaque origin" in refused, f"{what}: {r.status if r else 'not seen'} {refused!r}")
        seen[what] = r.status
    cdp.detach()
    # From the Chat page: its own policy stops the image, the fetch, the form post and a style sheet from the portal
    # before anything is sent (a securitypolicyviolation each, no request); the control, an image of Open WebUI's own
    # (same-origin), loads (200)
    page.goto(origin("chat") + "/")
    page.wait_for_load_state("load")
    watch(page)
    chat_img, chat_fetch, chat_form = (origin() + "/static/logo.svg?bn-guard=chat-img", origin() + "/api/summary?bn-guard=chat-fetch",
                                       origin("admin") + "/key/delete?bn-guard=chat-form")
    chat_css = origin() + "/static/login.css?bn-guard=chat-css"
    chat_own = origin("chat") + "/static/favicon.png?bn-guard=chat-own"
    blocked = page.evaluate("""async ([img, f, form, css, own]) => {
        const seen = [];
        document.addEventListener('securitypolicyviolation', (e) => seen.push([e.violatedDirective.split(' ')[0], String(e.blockedURI)]));
        try { await fetch(f, { credentials: 'include' }); } catch (e) { /* refused */ }
        await new Promise((r) => { const i = new Image(); i.onload = i.onerror = r; i.src = img; });
        const fr = document.createElement('iframe'); fr.name = 'bnguardchat'; fr.hidden = true; document.body.append(fr);
        const fo = document.createElement('form'); fo.method = 'post'; fo.target = 'bnguardchat'; fo.action = form; document.body.append(fo); fo.submit();
        await new Promise((r) => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.onload = l.onerror = r; l.href = css; document.head.append(l); });
        // (the control: an image of Open WebUI's own — same-origin — loads)
        await new Promise((r) => { const i = new Image(); i.onload = i.onerror = r; i.src = own; });
        await new Promise((r) => setTimeout(r, 1500));
        return seen;
    }""", [chat_img, chat_fetch, chat_form, chat_css, chat_own])
    page.wait_for_timeout(1000)
    by = {}
    for d, u in blocked:
        by.setdefault(u.split("?bn-guard=")[-1] if "?bn-guard=" in u else u, d)
    for tag, want, u in (("chat-img", "img-src", chat_img), ("chat-fetch", "connect-src", chat_fetch), ("chat-form", "form-action", chat_form),
                         ("chat-css", "style-src-elem", chat_css)):
        expect(by.get(tag) == want, f"Chat's policy: {tag} not refused by {want} ({blocked})")
        # (DevTools lists a request the policy blocked too — as blocked: nothing of it went on the wire)
        rid = urls.get(u)
        expect(rid is None or (rid not in sent and rid not in got), f"Chat's policy: {tag} was sent all the same")
        seen[f"Chat: {tag}"] = want
    rid = urls.get(chat_own)
    st, rh = got.get(rid) or (None, {})
    expect(rid is not None and st == 200 and not rh.get("x-bn-refused") and (sent.get(rid) or {}).get("sec-fetch-site") == "same-origin",
           f"the control from Chat (an image of Open WebUI's own): {st} {rh.get('x-bn-refused')!r}")
    seen["Chat: control own image"] = st
    rec.save()
    return (f"from a same-site page of no app's, with the session cookie: "
            f"{', '.join(f'{k} {v}' for k, v in seen.items() if k != 'control image' and not k.startswith('Chat'))} (Caddy's guard, X-Bn-Refused); "
            f"the control, a same-site image from the portal: {seen['control image']}; from the Chat page, its policy refuses the image, "
            f"the fetch, the form post and a style sheet before they are sent (it allows no load from another host); its own image loads: {seen['Chat: control own image']}")


# --- phone / tablet ---

# the tabs a phone's bottom bar shows, in order (More as "more")
PHONE_BAR = """els => els.filter((li) => getComputedStyle(li).display !== 'none')
  .map((li) => { const b = li.querySelector('.tab, .more-btn'); return b.classList.contains('more-btn') ? 'more' : b.dataset.tab; })"""


@check("browser", "phone-layout-390x844")
def phone(ctx):
    page, rec = ctx.page("phone", device="phone")
    login(page)
    page.wait_for_selector("#home:not([hidden])", timeout=20000)  # phones start on Home
    expect(page.locator(".tab[data-tab=home]").get_attribute("aria-current") == "page", "Home is not the first tab")
    expect(page.locator("iframe[data-app=chat]").count() == 0, "Chat loaded before its tab was opened")
    # Home · Chat · Code · More: Code is a tab of the bar (its page's frame, or while it is off its page of the portal)
    bar_tabs = page.eval_on_selector_all(".tabs > li", PHONE_BAR)
    expect(bar_tabs == ["home", "chat", "code", "more"], f"the phone's tab bar {bar_tabs}")
    vis = {t: page.locator(f".tab[data-tab={t}]").is_visible() for t in ("admin", "files", "settings", "terminal")}
    expect(not any(vis.values()), f"in the bar: {vis}")
    bar = page.locator(".sidebar").bounding_box()
    expect(bar and bar["y"] + bar["height"] >= 844 - 2 and bar["width"] >= 380, f"tab bar not at the bottom: {bar}")
    for t in ("home", "chat", "code"):
        b = page.locator(f".tab[data-tab={t}]").bounding_box()
        expect(b["height"] >= 44 and b["width"] >= 88, f"the {t} tab is {b['width']}x{b['height']}")
    page.click("#more-btn")
    page.wait_for_selector("#more-sheet:not([hidden])")
    expect(page.inner_text("#more-title") == "More", f"the sheet is titled {page.inner_text('#more-title')!r}")
    expect(page.inner_text("#more-newtab") == "In a new tab", "no In a new tab heading")
    links = page.eval_on_selector_all("#more-sheet .sheet-link[data-app]", "els => els.map(a => [a.dataset.app, a.href, a.target])")
    want = [["admin", origin("admin") + "/ui/api-keys/", "_blank"], ["files", origin("files") + "/rustfs/console/", "_blank"]]
    if ENV.get("TERMINAL_ENABLED") == "true":   # the browser terminal (--terminal): full screen from More
        want.append(["terminal", origin("terminal") + "/", "_blank"])
    expect(links == want, f"More links {links}")
    expect(page.locator("#more-sheet .code-off-link").count() == 0, "Code in More (it is a tab of the bar)")
    expect(page.locator("#more-sheet .sheet-tools .sheet-link[data-page=settings]").is_visible(), "no Settings in More")
    expect(page.locator(".sheet-logout button").is_visible(), "no Sign out in More")
    shot(page, "13-phone-more")
    page.click("#more-close")
    page.locator(".health-line", has_text="services running").wait_for(timeout=30000)
    shot(page, "14-phone-home")
    page.click(".tab[data-tab=chat]")
    page.wait_for_selector("iframe[data-app=chat]:not([hidden])", timeout=20000)
    # Chat's Who answers: a visible label, the choice's name whole ("Open WebUI ▾"), every choice in full in the menu
    page.wait_for_function("() => document.querySelectorAll('#answers-chat option').length > 0", timeout=20000)
    expect(page.locator("label[for=answers-chat]").is_visible() and page.inner_text("label[for=answers-chat]") == "Who answers", "no visible Who answers label")
    pick = page.eval_on_selector(".answers-pick-text", "e => [e.textContent, e.scrollWidth <= e.clientWidth, e.getBoundingClientRect().right <= innerWidth]")
    expect(pick == ["Open WebUI", True, True], f"the phone's Chat menu shows {pick}")
    expect(page.eval_on_selector("#answers-chat option[value=owui]", "o => o.textContent") == "Open WebUI — its own model menu", "the menu's option is not whole")
    shot(page, "14b-phone-chat-who-answers")
    page.evaluate("location.hash = '#admin'")  # a bookmarked #admin on a phone: Chat instead
    page.locator(".tab[data-tab=chat][aria-current=page]").wait_for(timeout=10000)
    expect(page.locator("iframe[data-app=admin]").count() == 0, "Admin frame opened on a phone")
    expect(page.locator(".tab[data-tab=chat]").get_attribute("aria-current") == "page", "#admin did not fall back to Chat")
    rec.save()
    return ("starts on Home; bottom bar Home/Chat/Code/More (44 px+); More: Settings, Activity, Search; Admin+Files under In a new tab; "
            "health line; Chat's Who answers: a visible label and 'Open WebUI' whole")


@check("browser", "tablet-layout-820x1180")
def tablet(ctx):
    page, rec = ctx.page("tablet", device="tablet")
    login(page)
    page.wait_for_selector("#home:not([hidden])")
    vis = {t: page.locator(f".tab[data-tab={t}]").is_visible() for t in ("home", "chat", "admin", "files", "settings")}
    expect(all(vis.values()), f"tabs visible {vis}")
    expect(not page.locator("#more-btn").is_visible(), "More shown on a tablet")
    side = page.locator(".sidebar").bounding_box()
    expect(side and side["width"] < 120 and side["height"] > 900, f"not a narrow rail: {side}")
    page.click(".tab[data-tab=settings]")   # a page of the portal, not a frame
    page.wait_for_selector("#settings:not([hidden]) .set-head", timeout=15000)
    page.click(".tab[data-tab=files]")
    page.wait_for_selector("iframe[data-app=files]")
    expect(page.locator("#settings").is_hidden(), "Settings still shown over Files")
    shot(page, "15-tablet-files")
    rec.save()
    return "icon rail with Home/Chat/Admin/Files/Settings, no More; Settings opens as a page, Files in the frame"


# --- the sidebar collapsed to its icons (nav.js): desktops only; tablets keep the rail, phones the tab bar ---

NAV_CSP = ("(() => { window.__csp = []; document.addEventListener('securitypolicyviolation', "
           "(e) => __csp.push(e.violatedDirective + ' ' + e.blockedURI)); })();")


def _stored_nav(page, value: str):
    """bn.nav holds VALUE when the portal first loads in this context (and is left to the page after that)."""
    page.context.add_init_script(f"(o => {{ try {{ if (location.origin === o && !sessionStorage.getItem('bn-e2e-nav')) {{ "
                                 f"localStorage.setItem('bn.nav', {json.dumps(value)}); sessionStorage.setItem('bn-e2e-nav', '1'); }} }} "
                                 f"catch (e) {{}} }})({json.dumps(origin())});")


@check("browser", "sidebar-collapse")
def sidebar_collapse(ctx):
    page, rec = ctx.page("sidebar-collapse")
    page.context.add_init_script(NAV_CSP)
    login(page)
    page.wait_for_selector("#home:not([hidden])")
    toggle = page.locator("#nav-toggle")
    toggle.wait_for()
    wide = _settled_width(page, ".sidebar")
    expect(round(wide["width"]) == 200, f"expanded: {wide}")
    expect(toggle.get_attribute("aria-expanded") == "true" and toggle.get_attribute("title") == "Collapse the sidebar (Ctrl+\\)",
           f"button {toggle.get_attribute('aria-expanded')} {toggle.get_attribute('title')!r}")
    shot(page, "16-sidebar-expanded")
    toggle.click()
    rail = _settled_width(page, ".sidebar")
    expect(round(rail["width"]) == 76, f"collapsed: {rail}")
    expect(toggle.get_attribute("aria-expanded") == "false" and toggle.get_attribute("title").startswith("Expand the sidebar"), "button state")
    expect(page.evaluate("document.activeElement.id") == "nav-toggle", "the focus left the button")
    expect(page.evaluate("localStorage.getItem('bn.nav')") == "collapsed", "not remembered")
    tips = page.eval_on_selector_all(".tab", "els => els.filter(e => e.offsetParent).map(e => [e.dataset.tab, e.title, e.textContent.trim()])")
    expect(len(tips) >= 5 and all(t and n for _, t, n in tips), f"each icon: a tooltip and a name {tips}")
    for sel in ("#search-btn", "#activity-btn", "#tour-btn", ".version-label"):
        expect(page.locator(f".sidebar {sel}").first.is_visible(), f"{sel} not in the rail")
    shot(page, "17-sidebar-collapsed")
    page.click(".tab[data-tab=chat]")
    page.wait_for_selector("iframe[data-app=chat]:not([hidden])")
    frame = _settled_width(page, "iframe[data-app=chat]")
    expect(round(frame["width"]) == 1400 - 76, f"Chat's frame {frame} (the window: 1400)")
    shot(page, "18-sidebar-collapsed-chat")
    # a reload: collapsed from the first paint (no slide), still on Chat
    page.reload()
    page.wait_for_selector("iframe[data-app=chat]:not([hidden])")
    first = page.evaluate("document.querySelector('.sidebar').getBoundingClientRect().width")
    expect(round(first) == 76 and toggle.get_attribute("aria-expanded") == "false", f"after a reload: {first} px")
    # the key, with the focus in the portal: back and forth
    page.click(".tab[data-tab=home]")
    page.keyboard.press("Control+Backslash")
    expect(round(_settled_width(page, ".sidebar")["width"]) == 200, "Ctrl+\\ did not expand it")
    page.keyboard.press("Control+Backslash")
    expect(round(_settled_width(page, ".sidebar")["width"]) == 76, "Ctrl+\\ did not collapse it")
    # each icon's name on keyboard focus as well as on hover: Tab from the button through the rail, each control with
    # a title (its hover tooltip) shows the same words beside it (mobile.css: ::before, out of the rail)
    page.focus("#nav-toggle")
    named, seen = [], set()
    for _ in range(30):
        page.keyboard.press("Tab")
        f = page.evaluate("""() => { const a = document.activeElement;
          if (!a || !a.closest('.sidebar') || !a.getClientRects().length) return null;
          const b = getComputedStyle(a, '::before');
          return { id: a.dataset.tab || a.id || a.className.split(' ')[0] || a.textContent.trim(), title: a.title, content: b.content,
                   pos: b.position, left: parseFloat(b.left), w: a.getBoundingClientRect().width,
                   icon: a.matches('.tab, .side-search, .bell-btn, .tour-btn, .install-btn, .nav-toggle') }; }""")
        if not f or f["id"] in seen:
            break
        seen.add(f["id"])
        if not f["icon"]:   # (the version and Sign out show their words in the rail)
            continue
        named.append(f["id"])
        expect(f["title"] and f["content"] == json.dumps(f["title"], ensure_ascii=False) and f["pos"] == "absolute" and f["left"] > f["w"],
               f"{f['id']}: no name beside it on focus ({f})")
    expect({"home", "chat", "admin", "files", "settings", "search-btn", "tour-btn"} <= set(named), f"focus names: only {named}")
    expect((page.get_attribute("#tour-btn", "title") or "").startswith("Walkthrough: "), f"the walkthrough's button: {page.get_attribute('#tour-btn', 'title')!r}")
    # the Code tab with the rail: its icon named, its frame (or its off page) takes the room; Ctrl+\ from its button
    code_tab = page.locator(".tab[data-tab=code]")
    code_note = "no Code tab"
    if code_tab.count():
        off = page.locator(".code-item.off").count() > 0
        expect(code_tab.get_attribute("title") == ("Code (off)" if off else "Code"), f"the Code tab's name: {code_tab.get_attribute('title')!r}")
        code_tab.click()
        sel = "#code:not([hidden])" if off else "iframe[data-app=code]:not([hidden])"
        page.wait_for_selector(sel, timeout=20000)
        expect(code_tab.get_attribute("aria-current") == "page", "the Code tab is not the current one")
        cw = _settled_width(page, sel)["width"]
        expect(round(cw) == 1400 - 76, f"the Code {'page' if off else 'frame'}: {cw} px beside the rail (the window: 1400)")
        shot(page, "19a-sidebar-collapsed-code")
        code_tab.focus()
        page.keyboard.press("Control+Backslash")
        ew = _settled_width(page, sel)["width"]
        expect(round(_settled_width(page, ".sidebar")["width"]) == 200 and round(ew) == 1400 - 200, f"Ctrl+\\ on Code: sidebar, {ew} px")
        page.keyboard.press("Control+Backslash")
        expect(round(_settled_width(page, ".sidebar")["width"]) == 76 and round(_settled_width(page, sel)["width"]) == 1400 - 76,
               "Ctrl+\\ on Code did not collapse it again")
        code_note = f"the Code tab ({'off page' if off else 'frame'} {cw:.0f} px, named, Ctrl+\\ both ways there)"
        page.click(".tab[data-tab=home]")
    # the walkthrough beside the icons: the tablets' card; Escape closes it, the focus back on its button
    page.click("#tour-btn")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    card = page.locator("#tour").bounding_box()
    side = _settled_width(page, ".sidebar")
    expect(round(side["width"]) == 76 and card["x"] >= side["width"] and card["width"] <= 361, f"card {card} beside {side}")
    shot(page, "19-sidebar-collapsed-walkthrough")
    page.keyboard.press("Escape")
    page.wait_for_selector("#tour", state="hidden")
    expect(page.evaluate("document.activeElement.id") == "tour-btn", "Escape: the focus did not return to the button")
    v = page.evaluate("window.__csp")
    # (the Code tab's frame, still locked: its unlock page answers 401 — checks_code.py LOCKED_OK)
    probs = rec.problems(allow=FRAME_NOISE + [r"^401 (GET|POST) " + re.escape(origin("code")) + r"/(\.bn/unlock)?$"])
    rec.save()
    expect(not v and not probs, f"CSP violations {v[:4]}, errors {probs[:6]}")

    # tablets and phones: as before, whatever this browser chose on a desktop
    page, rec = ctx.page("sidebar-collapse-tablet", device="tablet")
    page.context.add_init_script(NAV_CSP)
    _stored_nav(page, "collapsed")
    login(page)
    page.wait_for_selector("#home:not([hidden])")
    t_side = page.locator(".sidebar").bounding_box()
    expect(t_side["width"] < 120 and not page.locator("#nav-toggle").is_visible(), f"tablet: {t_side}, the button shown")
    expect(page.locator(".tab[data-tab=settings]").get_attribute("title") == "Settings", "tablet: no tooltip")
    probs, v = rec.problems(), page.evaluate("window.__csp")
    rec.save()
    expect(not v and not probs, f"tablet: CSP violations {v[:4]}, errors {probs[:6]}")
    page, rec = ctx.page("sidebar-collapse-phone", device="phone")
    page.context.add_init_script(NAV_CSP)
    _stored_nav(page, "collapsed")
    login(page)
    # (a phone's sign-in lands on Home since v0.32.0, no longer in Chat: the tab bar is what this step looks at)
    page.wait_for_selector("#more-btn", state="visible", timeout=20000)
    bar = page.locator(".sidebar").bounding_box()
    expect(bar["y"] + bar["height"] >= 844 - 2 and bar["width"] >= 380 and not page.locator("#nav-toggle").is_visible(),
           f"phone: the tab bar {bar}, the button shown")
    expect(page.locator("#more-btn").is_visible(), "phone: no More")
    probs, v = rec.problems(allow=FRAME_NOISE), page.evaluate("window.__csp")
    rec.save()
    expect(not v and not probs, f"phone: CSP violations {v[:4]}, errors {probs[:6]}")
    return (f"button (aria-expanded, tooltip with Ctrl+\\) folds the {wide['width']:.0f} px sidebar to a {rail['width']:.0f} px rail: "
            f"icons with tooltips and names, Search, Activity, version and walkthrough kept; Chat's frame {frame['width']:.0f} px; "
            f"kept across a reload (no slide); Ctrl+\\ both ways; each icon's name beside it on keyboard focus ({len(named)}: "
            f"{', '.join(named)}); {code_note}; the walkthrough a card beside it, Escape back to its button; "
            f"tablet ({t_side['width']:.0f} px rail, no button) and phone (tab bar) unchanged; no CSP violation")


# --- the walkthrough (tour.js): desktop sidebar section, tablet card, phone sheet ---

# 24 steps everywhere (Your AI subscriptions and keys among them); where the Code page is on, its 9 steps and Connect a
# git host (else one on how to turn it on); with the browser terminal, its step and What the sandbox can reach
# (tour.js: when)
TOUR_TERM = ENV.get("TERMINAL_ENABLED") == "true"
TOUR_CODE = TOUR_TERM and (ENV.get("CODE_ENABLED") or "").lower() == "true"
TOUR_STEPS = 24 + (11 if TOUR_CODE else 1) + (2 if TOUR_TERM else 0)
# The walkthrough as a browser that went through it before this version left it (the step ids of v0.4–v0.12): the steps
# it never saw are New — the Code page's (or the step on turning it on), What the sandbox can reach, the API step, Your
# AI subscriptions and keys, Activity and search, Updates, From your phone.
OLD_TOUR_IDS = ["welcome", "aws", "openrouter", "voice", "claude-setup", "budgets", "extras", "signin-portal", "signin-chat",
                "signin-admin", "signin-files", "home", "chat", "voice-use", "docs", "claude", "terminal", "code", "shared", "admin", "done"]
TOUR_NEW = 5 + (12 if TOUR_CODE else 1) + (1 if TOUR_TERM and not TOUR_CODE else 0)
# What the app frames may log by themselves while they load, before their own sign-in (as in the Chat and Files
# checks): not the walkthrough's doing.
FRAME_NOISE = [r"^401 GET " + re.escape(origin("files")) + r"/rustfs/admin/v3/",
               r"^console\.error .*No token found in localStorage"]
# What a reload of the portal cuts off: the requests still in flight in the app frames (Admin's dashboard and Chat keep
# asking their servers for a while after they open), which those pages report as "TypeError: Failed to fetch". Excused
# only between the check's own reload and its end (_reload): before and after it, the same line is a failure.
CUT_OFF_BY_RELOAD = r"^console\.error .*TypeError: Failed to fetch"


def _reload(page, rec):
    """page.reload(), the span it takes marked in REC (_problems_outside_reloads)."""
    rec.mark("reload")
    page.reload()
    rec.mark("reloaded")


def _problems_outside_reloads(rec, allow) -> list[str]:
    """rec.problems(allow=ALLOW), with the requests a reload of the check's own cut off (CUT_OFF_BY_RELOAD) excused
    between its "reload" and "reloaded" marks — and nothing else excused anywhere."""
    out, start, inside = [], 0, False
    for i, e in enumerate(rec.events):
        if e["t"] == "mark" and e["label"] in ("reload", "reloaded"):
            out += rec.problems(allow=[*allow, CUT_OFF_BY_RELOAD] if inside else allow, start=start, end=i)
            start, inside = i, e["label"] == "reload"
    return out + rec.problems(allow=[*allow, CUT_OFF_BY_RELOAD] if inside else allow, start=start)


def _summaries(rec, since: int) -> int:
    """How many /api/summary answers the page got after event number SINCE."""
    return sum(1 for e in rec.events[since:] if e["t"] == "resp" and e["url"].startswith(origin() + "/api/summary"))


def _cur(page) -> str:
    return page.evaluate("() => { const c = document.querySelector('#tour .tour-step.cur'); return c ? c.dataset.step : '' }")


def _to_step(page, step: str):
    page.wait_for_function("s => { const c = document.querySelector('#tour .tour-step.cur'); return c && c.dataset.step === s }",
                           arg=step, timeout=10000)


def _settled_width(page, sel: str, timeout=5) -> dict:
    """The bounding box of SEL once its width stopped changing (the sidebar animates for 0.2 s)."""
    last, t0 = None, time.time()
    while time.time() - t0 < timeout:
        box = page.locator(sel).bounding_box()
        if last and box and abs(box["width"] - last["width"]) < 0.5:
            return box
        last = box
        page.wait_for_timeout(150)
    return last


def _clipboard_after(page, click_sel: str) -> str:
    page.evaluate("navigator.clipboard.writeText('')")
    page.click(click_sel)
    clip, t0 = "", time.time()
    while time.time() - t0 < 5 and not clip:
        clip = page.evaluate("navigator.clipboard.readText()")
        if not clip:
            page.wait_for_timeout(100)
    return clip


def gs_shown(page, timeout=15000):
    """Wait for Home's Get started card; True when all five steps are ticked ('You're set up': the card keeps its head and
    CSS collapses the steps, display:none), False on the first-install state where the steps show. A fresh stack is the
    second; the full stage, run late, is the first. Either way the step elements exist. Home draws the card before its
    numbers come in (a step or two not ticked yet) and again after, so one look takes whichever state it shows then: two
    looks could see steps to do, then wait for steps the second draw had folded away (v0440b's walkthrough)."""
    state = page.wait_for_function("""() => {
        const c = document.querySelector('#get-started:not([hidden])'), s = c && c.querySelector('.gs-step');
        return s ? (c.classList.contains('all-done') ? 'done' : s.checkVisibility() ? 'steps' : '') : '';
    }""", timeout=timeout).json_value()
    if state == "done":
        expect("You're set up" in page.text_content("#get-started .gs-head h2"), "all-done but the head does not say You're set up")
    return state == "done"


@check("browser", "walkthrough")
def walkthrough(ctx):
    page, rec = ctx.page("walkthrough", tour=True)   # a first visit: no walkthrough state yet
    login(page)
    # a first visit: Home's Get started (five steps) is the first run, the walkthrough closed beside it — its Full
    # walkthrough opens it, at the start
    gs_shown(page)
    page.wait_for_timeout(500)
    expect(page.locator("#tour").is_hidden(), "the walkthrough opened by itself on a first visit (Get started is the first run now)")
    page.click("#get-started .gs-tour")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur", timeout=15000)
    expect(_cur(page) == "welcome", f"opened on {_cur(page)!r}, not welcome")
    expect(page.locator("#tour-btn").is_hidden(), "the sidebar button shows while the walkthrough is open")
    # A section of the sidebar: the sidebar widens, the stage (Home, the app frames) starts where it ends.
    side = _settled_width(page, ".sidebar")
    stage = page.locator(".stage").bounding_box()
    panel = page.locator("#tour").bounding_box()
    open_w = side["width"]
    expect(open_w >= 330, f"sidebar {open_w} px wide with the walkthrough open")
    expect(stage["x"] >= side["x"] + side["width"] - 1, f"stage at x={stage['x']}, sidebar ends at {side['x'] + side['width']}")
    expect(panel["x"] + panel["width"] <= stage["x"] + 1 and panel["height"] > 300, f"panel {panel} vs stage x={stage['x']}")
    shot(page, "w01-walkthrough-desktop")
    steps = page.eval_on_selector_all("#tour .tour-step", "els => els.map(e => e.dataset.step)")
    expect(len(steps) == TOUR_STEPS, f"{len(steps)} steps listed")
    secs = [" ".join(t.split()) for t in page.eval_on_selector_all("#tour .tour-sec-name", "els => els.map(e => e.textContent)")]
    expect(secs == ["1. Set up", "2. Your apps (one sign-in)", "3. Chat", "4. Code with Claude", "5. Your own tools", "6. Keep it running"],
           f"sections {secs}")
    # a first visit: nothing is marked New, the button counts steps (not new ones)
    expect(page.locator("#tour .tour-new, #tour .tour-badge.new, #tour .tour-newline").count() == 0, "a first visit sees New marks")
    expect("new" not in page.inner_text("#tour-count"), f"the button says {page.inner_text('#tour-count')!r} on a first visit")

    # Set up: Next walks through; the AWS step counts the enabled chat models from /api/summary and is done by itself.
    page.click("#tour [data-k=next]")
    _to_step(page, "aws")
    page.locator("#tour .tour-step.cur .tour-status.ok", has_text="chat model").wait_for(timeout=40000)
    aws = page.inner_text("#tour .tour-step.cur .tour-status")
    expect(page.locator("#tour .tour-step.cur.done").count() == 1, "the AWS step is not marked done")
    # With Home on screen, Home's own 30 s refresh feeds the step: no second /api/summary every 30 s.
    since = len(rec.events)
    page.wait_for_timeout(65000)
    asked = _summaries(rec, since)
    expect(asked <= 3, f"{asked} /api/summary requests in 65 s with Home visible and the walkthrough on a live step")
    for want in ("openrouter", "voice", "claude-setup", *(["git-hosts"] if TOUR_CODE else []), "budgets"):
        page.click("#tour [data-k=next]")
        _to_step(page, want)
    page.locator("#tour .tour-step.cur li", has_text="a month").first.wait_for(timeout=40000)   # each key's budget
    shot(page, "w02-walkthrough-budgets")
    for want in ("extras", "signin-portal", "signin-chat"):
        page.click("#tour [data-k=next]")
        _to_step(page, want)

    # Chat: Open Chat shows the frame (beside the walkthrough, not under it) and the step is done by itself.
    page.click("#tour [data-k=open-chat]")
    page.wait_for_selector("iframe[data-app=chat]:not([hidden])")
    page.locator("#tour .tour-step.cur.done").wait_for(timeout=5000)
    frame = page.locator("iframe[data-app=chat]").bounding_box()
    side = _settled_width(page, ".sidebar")
    expect(frame["x"] >= side["x"] + side["width"] - 1, f"chat frame at x={frame['x']} under the sidebar ({side})")
    shot(page, "w03-walkthrough-chat")

    # Admin and Files: "Automatic" — Open signs in and the step is done by itself, like Chat. Their own sign-in is
    # folded away (the fallback): the user name / access key as text, user and password through Copy (never in the
    # page), and a link to the app's own form.
    page.context.grant_permissions(["clipboard-read", "clipboard-write"], origin=origin())
    page.click("#tour [data-k=next]")
    _to_step(page, "signin-admin")
    sec = " ".join(page.inner_text("#tour [data-k=sec-1]").split())
    expect("Your apps (one sign-in)" in sec, f"the second section reads {sec!r}")
    badge = page.inner_text("#tour .tour-step.cur .tour-badges")
    expect("Automatic" in badge, f"Admin's badge {badge!r}")
    fold = page.inner_text("#tour [data-k=fallback-admin] summary")
    expect(fold == "Credentials (for the API or if automatic sign-in fails)", f"Admin's fold reads {fold!r}")
    expect(page.locator("#tour .tour-step.cur .tour-cred").is_hidden(), "the Admin sign-in is not folded away")
    page.click("#tour [data-k=fallback-admin] summary")
    page.locator("#tour .tour-cred", has_text=ENV["LITELLM_UI_USER"]).wait_for(timeout=10000)
    expect(_clipboard_after(page, "#tour [data-k=copy-admin-user]") == ENV["LITELLM_UI_USER"], "Copy username")
    expect(_clipboard_after(page, "#tour [data-k=copy-admin-pass]") == ENV["LITELLM_UI_PASSWORD"], "Copy password")
    form = page.get_attribute("#tour a[data-k=form-admin]", "href")
    expect(form == origin("admin") + "/ui/login/?sso=off", f"Its sign-in form → {form}")
    page.click("#tour [data-k=open-admin]")
    need("litellm")
    sso_signed_in(page, page.frame_locator("iframe[data-app=admin]"), rec, "admin", "walkthrough: Open Admin", "w-admin")
    page.locator("#tour .tour-step.cur.done").wait_for(timeout=5000)
    shot(page, "w04-walkthrough-admin")
    page.click("#tour [data-k=next]")
    _to_step(page, "signin-files")
    page.click("#tour [data-k=fallback-files] summary")
    page.locator("#tour .tour-cred", has_text=ENV["RUSTFS_ACCESS_KEY"]).wait_for(timeout=10000)
    expect(_clipboard_after(page, "#tour [data-k=copy-files-user]") == ENV["RUSTFS_ACCESS_KEY"], "Copy access key")
    expect(_clipboard_after(page, "#tour [data-k=copy-files-pass]") == ENV["RUSTFS_SECRET_KEY"], "Copy secret key")
    page.evaluate("navigator.clipboard.writeText('')")
    html = page.content()
    expect(ENV["RUSTFS_SECRET_KEY"] not in html and ENV["LITELLM_UI_PASSWORD"] not in html, "a password is in the page")
    page.click("#tour [data-k=open-files]")
    need("rustfs")
    sso_signed_in(page, page.frame_locator("iframe[data-app=files]"), rec, "files", "walkthrough: Open Files", "w-files")
    page.locator("#tour .tour-step.cur.done").wait_for(timeout=5000)
    page.emulate_media(color_scheme="dark")
    shot(page, "w05-walkthrough-files-dark", mask=["iframe[data-app=files]"])
    page.emulate_media(color_scheme="light")

    # Reload: still open, on the same step, with the same progress.
    done = page.inner_text("#tour .tour-prog")
    _reload(page, rec)
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    expect(_cur(page) == "signin-files", f"after a reload on {_cur(page)!r}")
    expect(page.inner_text("#tour .tour-prog") == done, f"progress {page.inner_text('#tour .tour-prog')!r}, was {done!r}")

    # Close: back to the button with the progress; the sidebar narrows again; it stays closed across a reload.
    page.click("#tour .tour-x")
    page.wait_for_selector("#tour", state="hidden")
    label = " ".join(page.inner_text("#tour-btn").split())
    expect(re.search(rf"Walkthrough\s*·\s*\d+/{TOUR_STEPS}", label), f"button reads {label!r}")
    side = _settled_width(page, ".sidebar")
    expect(side["width"] <= 210, f"sidebar still {side['width']} px wide")
    shot(page, "w06-walkthrough-closed")
    _reload(page, rec)
    page.wait_for_selector("#tour-btn:not([hidden])")
    expect(page.locator("#tour").is_hidden(), "the walkthrough reopened by itself after being closed")
    page.click("#tour-btn")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    expect(_cur(page) == "signin-files", f"reopened on {_cur(page)!r}")

    # A reload on "Chat: pick a model and ask" with the Chat tab in front (Home is not refreshing): the step asks for
    # the summary itself, leaves "Checking…" and keeps the open-webui key's spend as its starting point.
    page.click("#tour [data-k=sec-2]")
    page.click("#tour [data-k=go-chat]")
    _to_step(page, "chat")
    page.click("#tour [data-k=open-chat]")
    page.wait_for_selector("iframe[data-app=chat]:not([hidden])")
    _reload(page, rec)
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    expect(_cur(page) == "chat" and page.locator("iframe[data-app=chat]").is_visible(), "not back on Chat at the chat step")
    page.wait_for_function("() => { const s = document.querySelector('#tour .tour-step.cur .tour-status'); "
                           "return s && !/Checking/.test(s.textContent) }", timeout=10000)
    chat_status = page.inner_text("#tour .tour-step.cur .tour-status")
    saved = page.evaluate("() => JSON.parse(localStorage.getItem('bn.tour'))")
    expect(isinstance((saved.get("base") or {}).get("chat:open-webui"), (int, float)), f"no spend baseline of the Chat step: {saved.get('base')}")

    # Skip moves on and can be undone; Finish lists what is still open; Start over begins again.
    page.click("#tour [data-k=next]")
    _to_step(page, "voice-use")
    page.click("#tour [data-k=skip]")
    _to_step(page, "docs")
    expect(page.locator("#tour .tour-step[data-step=voice-use].skipped").count() == 1, "Skip did not mark the step skipped")
    page.click("#tour [data-k=back]")
    _to_step(page, "voice-use")
    page.click("#tour [data-k=undo]")
    page.locator("#tour .tour-step.cur [data-k=skip]").wait_for(timeout=5000)
    expect(page.locator("#tour .tour-step[data-step=voice-use].skipped").count() == 0, "Undo left the step skipped")
    page.click("#tour [data-k=sec-5]")   # (Keep it running: the last step)
    page.click("#tour [data-k=go-done]")
    _to_step(page, "done")
    page.click("#tour [data-k=next]")   # Finish
    page.locator("#tour #tour-cur", has_text="still open").wait_for(timeout=5000)
    shot(page, "w10-walkthrough-finished")
    page.click("#tour [data-k=restart]")
    _to_step(page, "welcome")
    left = int(re.match(r"\d+", page.inner_text("#tour .tour-prog")).group(0))
    expect(left <= 4, f"Start over left {left} steps done")
    probs = _problems_outside_reloads(rec, FRAME_NOISE)
    rec.save()
    expect(not probs, f"errors: {probs[:6]}")
    return (f"a first visit: Get started, the walkthrough closed; its Full walkthrough opens it as a section of the {open_w:.0f} px sidebar (closed: {side['width']:.0f} px), beside the frames; {aws.strip()!r}; "
            f"{asked} summaries in 65 s; Next through Set up; Open Chat/Admin/Files → signed in automatically, done; their "
            f"own sign-ins folded away, shown and copied; reload keeps the step; closed → {label!r}, stays closed; reload on Chat → "
            f"{chat_status.strip()[:40]!r}; skip/undo/finish/start over")


@check("browser", "home-get-started")
def get_started(ctx):
    """Home's Get started (home.js): a first visit's five steps — sign in, a model provider, Code, Chat, a budget — each
    ticked by what the portal sees (or, for the budgets, kept as they are on purpose), first on Home with the walkthrough
    closed beside it; Full walkthrough opens the walkthrough; Hide puts it away for good in this browser, and the
    walkthrough brings it back. On a phone too."""
    page, rec = ctx.page("get-started", tour=True)   # a first visit
    login(page)
    gs_shown(page)
    ids = page.eval_on_selector_all("#get-started .gs-step", "els => els.map(e => e.dataset.step)")
    expect(ids == ["signin", "models", "code", "chat", "budget"], f"steps {ids}")
    expect(page.locator("#get-started .gs-step[data-step=signin].done").count() == 1, "Sign in is not ticked")
    page.locator("#get-started .gs-step[data-step=models].done").wait_for(state="attached", timeout=40000)   # Bedrock's chat models
    expect("chat model" in page.text_content("#get-started .gs-step[data-step=models]"), "the models step does not say how many")
    # first on Home: Get started, then Continue, then the operations (spend, services, models)
    tops = page.evaluate("() => ['#get-started', '#continue', '.grid'].map(s => document.querySelector(s).getBoundingClientRect().top)")
    expect(tops == sorted(tops), f"Home's order {tops}")
    expect(page.locator("#tour").is_hidden(), "the walkthrough opened by itself on a first visit")
    shot(page, "gs01-get-started")
    # the budgets: ticked once one differs from its default, or kept as they are
    budget = page.locator("#get-started .gs-step[data-step=budget]")
    page.wait_for_timeout(3000)   # (the settings it reads)
    if "done" not in (budget.get_attribute("class") or ""):
        budget.locator("button", has_text="Keep these").click()
    page.locator("#get-started .gs-step[data-step=budget].done").wait_for(state="attached", timeout=10000)
    prog = page.inner_text("#get-started .gs-prog")
    # Full walkthrough: the walkthrough, at its start
    page.click("#get-started .gs-tour")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur", timeout=10000)
    expect(_cur(page) == "welcome", f"Full walkthrough opened {_cur(page)!r}")
    page.click("#tour .tour-x")
    # Hide: gone, also after a reload; the walkthrough brings it back
    page.click("#get-started .gs-hide")
    page.wait_for_selector("#get-started", state="hidden")
    _reload(page, rec)
    page.wait_for_selector("#continue:not([hidden])", timeout=15000)
    expect(page.locator("#get-started").is_hidden(), "Get started came back after a reload")
    expect(page.evaluate("() => JSON.parse(localStorage.getItem('bn.getstarted')).hidden") is True, "not kept hidden")
    page.click("#tour-btn")
    page.click("#tour [data-k=get-started-head]")
    gs_shown(page, 10000)
    # a phone: on Home too
    ppage, prec = ctx.page("get-started-phone", device="phone", tour=True)
    login(ppage)
    ppage.click(".tab[data-tab=home]")
    gs_shown(ppage)
    width = ppage.evaluate("document.querySelector('#home').scrollWidth")
    expect(width <= 392, f"phone: Home scrolls sideways ({width}px)")
    shot(ppage, "gs02-get-started-phone")
    probs = _problems_outside_reloads(rec, FRAME_NOISE) + prec.problems(allow=FRAME_NOISE)
    rec.save(); prec.save()
    expect(not probs, f"errors: {probs[:6]}")
    return f"five steps, first on Home, the walkthrough closed; {prog!r}; Full walkthrough → welcome; Hide kept across a reload, brought back by the walkthrough; phone"


@check("browser", "walkthrough-tablet")
def walkthrough_tablet(ctx):
    page, rec = ctx.page("walkthrough-tablet", device="tablet", tour=True)
    login(page)
    page.wait_for_selector("#tour-btn:not([hidden])", timeout=15000)
    expect(page.locator("#tour").is_hidden(), "the walkthrough opened by itself on a first visit (Get started is the first run now)")
    page.click("#tour-btn")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur", timeout=15000)
    rail = page.locator(".sidebar").bounding_box()
    card = page.locator("#tour").bounding_box()
    expect(rail["width"] < 120, f"not a rail: {rail}")
    expect(card["x"] >= rail["x"] + rail["width"] and card["width"] <= 361, f"card {card} vs rail {rail}")
    expect(card["y"] + card["height"] <= 1180 - 8 and card["height"] <= 0.76 * 1180, f"card {card}")
    expect(page.locator("#tour-btn").is_visible(), "no Walkthrough button in the rail")
    shot(page, "w07-walkthrough-tablet")
    page.keyboard.press("Escape")
    page.wait_for_selector("#tour", state="hidden")
    expect(page.evaluate("document.activeElement.id") == "tour-btn", "focus did not return to the button")
    # Open Admin from the card: the card steps aside, so it does not cover LiteLLM (signed in by the portal).
    page.click("#tour-btn")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    page.click("#tour [data-k=sec-1]")
    page.click("#tour [data-k=go-signin-admin]")
    _to_step(page, "signin-admin")
    # (every toast shown from here on is recorded: one stays 1.8 s and the next can replace it, so on a slow run the
    # compass hint came and went before a wait for it began — v0313b)
    page.evaluate("""() => { const t = document.querySelector('#toast'); window.__bnToasts = [];
        new MutationObserver(() => { if (t.classList.contains('show')) window.__bnToasts.push(t.textContent); })
          .observe(t, { attributes: true, childList: true, characterData: true, subtree: true }); }""")
    page.click("#tour [data-k=open-admin]")
    page.wait_for_function("() => (window.__bnToasts || []).some((m) => m.includes('compass button'))", timeout=5000)
    page.wait_for_selector("#tour", state="hidden", timeout=5000)
    need("litellm")
    keys = page.frame_locator("iframe[data-app=admin]").locator(SSO_DONE["admin"]).first
    sso_signed_in(page, page.frame_locator("iframe[data-app=admin]"), rec, "admin", "tablet: Open Admin", "w-tablet-admin")
    box = keys.bounding_box()
    covered = page.evaluate("([x, y]) => { const e = document.elementFromPoint(x, y); return !e || !!e.closest('#tour'); }",
                           [box["x"] + box["width"] / 2, box["y"] + box["height"] / 2])
    expect(not covered, "the walkthrough covers LiteLLM")
    rec.save()
    return (f"a {card['width']:.0f}×{card['height']:.0f} card next to the {rail['width']:.0f} px rail; Escape closes it; "
            "Open Admin moves it aside (LiteLLM, signed in, is free)")


@check("browser", "walkthrough-phone")
def walkthrough_phone(ctx):
    page, rec = ctx.page("walkthrough-phone", device="phone", tour=True)
    login(page)
    # a first visit on a phone: Home, with Get started at its top (window.bnWelcome is Get started's: the first run is
    # its five steps); the walkthrough stays closed — it would cover Home — and opens from More
    page.wait_for_selector("#home:not([hidden])", timeout=20000)
    gs_shown(page)
    page.wait_for_timeout(500)
    expect(page.locator("#tour").is_hidden(), "the walkthrough opened by itself on a phone's first visit")
    bar = page.locator(".sidebar").bounding_box()
    shot(page, "w07-walkthrough-phone-first-visit")
    page.click("#more-btn")
    page.wait_for_selector("#more-sheet:not([hidden])")
    expect(page.locator("#more-tour").is_visible(), "no Walkthrough in More")
    page.click("#more-tour")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    expect(page.locator("#more-sheet").is_hidden(), "More stayed open")
    page.wait_for_timeout(300)   # the sheet slides in
    sheet = page.locator("#tour").bounding_box()
    expect(abs(sheet["y"] + sheet["height"] - bar["y"]) <= 2 and sheet["width"] >= 380, f"sheet {sheet} vs tab bar {bar}")
    for k in ("back", "next"):
        b = page.locator(f"#tour [data-k={k}]").bounding_box()
        expect(b and b["y"] >= sheet["y"] and b["y"] + b["height"] <= bar["y"] + 1 and b["height"] >= 44, f"{k} {b} vs the sheet {sheet} and the tab bar {bar}")
    # the step's Back and Next: pinned to the sheet's bottom, above the tab bar, while its text scrolls (UX-14)
    nav = page.locator("#tour .tour-card > .tour-nav").bounding_box()
    expect(nav and nav["y"] + nav["height"] <= bar["y"] + 1 and nav["y"] >= sheet["y"], f"Back/Next {nav} vs sheet {sheet} and tab bar {bar}")
    nxt = page.locator("#tour [data-k=next]").bounding_box()
    hit = page.evaluate("([x, y]) => { const e = document.elementFromPoint(x, y); return !!(e && e.closest('[data-k=next]')); }",
                        [nxt["x"] + nxt["width"] / 2, nxt["y"] + nxt["height"] / 2])
    expect(hit, "Next is covered (by the tab bar, or the sheet's edge)")
    shot(page, "w08-walkthrough-phone")
    page.click("#tour [data-k=sec-1]")   # open "Your apps (one sign-in)", jump to Admin
    page.click("#tour [data-k=go-signin-admin]")
    _to_step(page, "signin-admin")
    a = page.locator("#tour a[data-k=open-admin]")
    expect(a.count() == 1, "Open Admin is not a link on a phone")
    href, target = a.get_attribute("href"), a.get_attribute("target")
    expect(href == origin("admin") + "/ui/api-keys/" and target == "_blank", f"Open Admin → {href} ({target})")
    page.click("#tour [data-k=fallback-admin] summary")
    page.locator("#tour .tour-cred", has_text=ENV["LITELLM_UI_USER"]).wait_for(timeout=10000)
    shot(page, "w09-walkthrough-phone-admin")
    # the new tab lands in LiteLLM signed in, and the step is done
    need("litellm")
    with page.context.expect_page() as pop:
        a.click()
    win = rec.attach(pop.value)
    sso_signed_in(win, win, rec, "admin", "phone: Open Admin (new tab)", "w-phone-admin")
    shot(win, "w09b-walkthrough-phone-admin-tab")
    win.close()
    page.locator("#tour .tour-step.cur.done").wait_for(timeout=5000)
    page.keyboard.press("Escape")
    page.wait_for_selector("#tour", state="hidden")
    # Left open, it still starts closed on the next load (it would cover the tab shown).
    page.click("#more-btn")
    page.click("#more-tour")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    page.reload()
    page.wait_for_selector("#home:not([hidden])", timeout=20000)
    page.wait_for_selector("#tour-btn:not([hidden])", state="attached")
    expect(page.locator("#tour").is_hidden(), "the walkthrough opened by itself after a reload on a phone")
    rec.save()
    return ("a first visit: Home with Get started, the walkthrough closed; More → Walkthrough opens a sheet above the tab bar, "
            "Back and Next pinned in view above it; closed after a reload; Open Admin is a new-tab link that lands signed in "
            "(step done); Escape closes")


def _seed_tour(page, state: dict):
    """bn.tour holds STATE when the portal first loads in this context (and is left to the page after that)."""
    page.context.add_init_script(f"(o => {{ try {{ if (location.origin === o && !localStorage.getItem('bn.tour')) "
                                 f"localStorage.setItem('bn.tour', {json.dumps(json.dumps(state))}); }} catch (e) {{}} }})({json.dumps(origin())});")


def _tour_btn(page) -> str:
    return " ".join(page.inner_text("#tour-btn").split())


@check("browser", "walkthrough-new-since")
def walkthrough_new(ctx):
    """A browser that went through the walkthrough of an earlier version (bn.tour without a list of the steps it saw):
    not opened again; the button says how many steps are new, each is marked New until opened."""
    page, rec = ctx.page("walkthrough-new", tour=True)
    _seed_tour(page, {"open": False, "cur": "", "done": OLD_TOUR_IDS, "skipped": [], "base": {}})
    login(page)
    page.wait_for_selector("#tour-btn:not([hidden])")
    page.wait_for_timeout(500)
    expect(page.locator("#tour").is_hidden(), "the walkthrough opened by itself for a browser that went through it before")
    label = _tour_btn(page)
    expect(label == f"Walkthrough {TOUR_NEW} new", f"the button reads {label!r}, not 'Walkthrough {TOUR_NEW} new'")
    expect("has-new" in (page.get_attribute("#tour-btn", "class") or ""), "the button is not marked")
    shot(page, "w11-walkthrough-new-button")
    page.click("#tour-btn")
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    head = page.inner_text("#tour #tour-cur")
    expect(head == f"{TOUR_NEW} new steps since you last looked", f"the finished view says {head!r}")
    marked = page.eval_on_selector_all("#tour .tour-step .tour-new", "els => els.map(e => e.closest('.tour-step').dataset.step)")
    want = ["git-hosts", "code-open", "code-clone", "api", "activity", "updates", "phone"] if TOUR_CODE else ["code-off", "api", "updates"]
    expect(all(w in marked for w in want), f"New on {marked}")
    expect(not any(w in marked for w in ("welcome", "aws", "chat", "shared", "admin")), f"New on old steps: {marked}")
    shot(page, "w12-walkthrough-new-open")
    page.click("#tour [data-k=first-new-card]")
    first = "git-hosts" if TOUR_CODE else "code-off"
    _to_step(page, first)
    expect(page.locator("#tour .tour-step.cur .tour-badge.new").count() == 1,
           "the card of the step just opened lacks its New badge (it keeps it until the next load)")
    expect(page.inner_text("#tour-count") == f"{TOUR_NEW - 1} new", f"after opening one: {page.inner_text('#tour-count')!r}")
    page.reload()
    page.wait_for_selector("#tour:not([hidden]) #tour-cur")
    expect(page.inner_text("#tour-count") == f"{TOUR_NEW - 1} new", f"after a reload: {page.inner_text('#tour-count')!r}")
    expect(page.locator("#tour .tour-step.cur .tour-badge.new").count() == 0, "a step opened before is New again after a reload")
    saved = page.evaluate("() => JSON.parse(localStorage.getItem('bn.tour'))")
    expect(first in saved.get("seen", []) and "welcome" in saved["seen"], f"seen {saved.get('seen')}")
    # the phone's More says it too
    page2, rec2 = ctx.page("walkthrough-new-phone", device="phone", tour=True)
    _seed_tour(page2, {"open": False, "cur": "", "done": OLD_TOUR_IDS, "skipped": [], "base": {}})
    login(page2)
    page2.wait_for_selector("#tour-btn:not([hidden])", state="attached")
    page2.click("#more-btn")
    page2.wait_for_selector("#more-sheet:not([hidden])")
    note = page2.inner_text("#more-tour-note")
    expect(note.startswith(f"{TOUR_NEW} new steps since you last looked"), f"More says {note!r}")
    shot(page2, "w13-walkthrough-new-phone-more")
    probs = rec.problems(allow=FRAME_NOISE) + rec2.problems(allow=FRAME_NOISE)
    rec.save(); rec2.save()
    expect(not probs, f"errors: {probs[:6]}")
    return (f"not opened again; button {label!r}; {head!r}; New on {len(marked)} steps; one opened → {TOUR_NEW - 1} new, "
            f"kept across a reload; phone More: {note!r}")


@check("browser", "walkthrough-git-hosts")
def walkthrough_git_hosts(ctx):
    """The Connect a git host step's Open Git hosts: the Code tab, unlocked, at its Git hosts dialog (?git=hosts); the
    step then shows how many hosts the Code page reports (a number only)."""
    from checks_code import CODE, LOCKED_OK, code_frame, unlock_page
    if not TOUR_CODE:
        raise Skip("the Code page is off in this throwaway: no Connect a git host step")
    page, rec = ctx.page("walkthrough-git-hosts", tour=True)
    login(page)
    page.wait_for_selector("#tour-btn:not([hidden])", timeout=15000)
    page.evaluate("() => window.bnTour.open('git-hosts')")
    _to_step(page, "git-hosts")
    card = page.inner_text("#tour .tour-step.cur")
    for words in ("Connect a git host…", "Sign in with GitHub", "Sign in with GitLab", "./stack git-host import gh", "Contents: Read and write",
                  "read_repository", "write_repository", "SSH key", "Test connection", "Let Claude use this host", "only from the computer running DevOS ADE"):
        expect(words in card, f"the step lacks {words!r}")
    shot(page, "w14-walkthrough-git-hosts")
    page.click("#tour [data-k=open-git-hosts]")
    page.wait_for_selector("iframe[data-app=code]:not([hidden])")
    f = code_frame(page)
    unlock_page(f)
    f = code_frame(page)
    dlg = f.locator("[data-testid=git-hosts-dialog]")
    dlg.wait_for(timeout=30000)
    expect("git=" not in f.url, f"the deep link stayed in the frame's address: {f.url}")
    # the frame reported its count (a number only): no host is connected in this throwaway (the git server's checks,
    # which add and remove some, run later; the built-in git server's own host is not one you connected), and the step
    # says so
    page.wait_for_function("() => window.bnCode && window.bnCode.gitHosts() !== null", timeout=20000)
    n = page.evaluate("() => window.bnCode.gitHosts()")
    expect(n == 0, f"the Code page reports {n!r} Git hosts")
    page.locator("#tour .tour-step.cur .tour-status", has_text="git host").wait_for(timeout=20000)
    status = page.inner_text("#tour .tour-step.cur .tour-status").strip()
    expect(status == "No git host is connected yet.", f"the step says {status!r}")
    shot(page, "w15-walkthrough-git-hosts-dialog")
    # again, with the Code tab running: the dialog opens in place — the page is not reloaded (unsaved edits stay)
    f.evaluate("() => { window.__bnStay = 1; }")
    dlg.get_by_role("button", name="Close").click()
    dlg.wait_for(state="hidden", timeout=10000)
    page.click("#tour [data-k=open-git-hosts]")
    dlg.wait_for(timeout=15000)
    expect(f.evaluate("() => window.__bnStay === 1"), "the Code page was reloaded to open Git hosts")
    # (the locked Code page answers its unlock form with 401, here for the deep link's address)
    probs = rec.problems(allow=FRAME_NOISE + LOCKED_OK + [r"^401 GET " + re.escape(CODE) + r"/\?git=hosts$"])
    rec.save()
    expect(not probs, f"errors: {probs[:6]}")
    return (f"Open Git hosts → the Code tab, unlocked, its Git hosts dialog (the link kept through the unlock); the step: {status!r} "
            f"({n} hosts reported); again with the tab running: in place, no reload")


@check("browser", "walkthrough-api-step")
def walkthrough_api(ctx):
    """The models from your own code: the throwaway's own LiteLLM port (from the Settings snapshot), the examples with
    YOUR_KEY, and no secret of .env anywhere in the page."""
    page, rec = ctx.page("walkthrough-api", tour=True)
    login(page)
    page.wait_for_selector("#tour-btn:not([hidden])", timeout=15000)
    page.evaluate("() => window.bnTour.open('api')")
    _to_step(page, "api")
    port = os.environ["E2E_LITELLM_PORT"]
    base = f"http://127.0.0.1:{port}"
    page.locator("#tour .tour-step.cur .tour-cmd code", has_text=base).wait_for(timeout=20000)
    expect(page.inner_text("#tour .tour-step.cur .tour-cmd code").strip() == base, "the API's address")
    expect(port != "4000", "the throwaway's LiteLLM port is the default one (the check would not tell a hard-coded port)")
    for k in ("openai", "anthropic"):
        page.click(f"#tour [data-k=snip-{k}] summary")
    snips = page.eval_on_selector_all("#tour .tour-snip pre", "els => els.map(e => e.textContent)")
    expect(len(snips) == 3, f"{len(snips)} examples")
    expect(snips[0].startswith(f"curl {base}/v1/chat/completions") and "Bearer YOUR_KEY" in snips[0], f"curl: {snips[0][:120]!r}")
    expect(f'base_url="{base}/v1", api_key="YOUR_KEY"' in snips[1], "the openai example")
    expect(f'base_url="{base}", api_key="YOUR_KEY"' in snips[2], "the anthropic example")
    model = ENV.get("CLAUDE_BEDROCK_HAIKU_MODEL") or "claude-haiku-5-5"
    expect(all(f'"{model}"' in t for t in snips), f"the examples do not name {model}")
    # (Home's Credentials shows the RustFS access key and the LiteLLM user as text, by design: not secrets of this kind)
    html = page.content()
    leaked = [k for k in (*SECRET_ENV, "LITELLM_KEY_TERMINAL", "OPENROUTER_API_KEY", "AWS_ACCESS_KEY_ID")
              if len(ENV.get(k) or "") >= 8 and ENV[k] in html]
    expect(not leaked, f"in the page: {leaked}")
    shot(page, "w16-walkthrough-api")
    page.context.grant_permissions(["clipboard-read", "clipboard-write"], origin=origin())
    expect(_clipboard_after(page, "#tour [data-k=copy-api-base]") == base, "Copy of the address")
    page.evaluate("navigator.clipboard.writeText('')")
    # what the step names in Admin: Virtual Keys › + Create New Key, with Optional Settings and a budget (LiteLLM's UI)
    need("litellm")
    page.click("#tour [data-k=open-admin]")
    fl = page.frame_locator("iframe[data-app=admin]")
    sso_signed_in(page, fl, rec, "admin", "walkthrough: the API step's Open Admin", "w-api-admin")
    create = fl.get_by_role("button", name=re.compile(r"Create New Key")).first
    create.wait_for(timeout=30000)
    btn = " ".join(create.inner_text().split())
    expect(btn == "+ Create New Key", f"Admin's button reads {btn!r} (the step and the README say + Create New Key)")
    create.click()
    fl.get_by_text("Optional Settings").first.wait_for(timeout=15000)
    fl.get_by_text("Optional Settings").first.click()
    fl.get_by_text(re.compile(r"Max Budget")).first.wait_for(timeout=15000)
    shot(page, "w17-walkthrough-api-admin-create-key")
    probs = rec.problems(allow=FRAME_NOISE)
    rec.save()
    expect(not probs, f"errors: {probs[:6]}")
    return (f"{base} (LITELLM_PORT of the throwaway), 3 examples with YOUR_KEY and {model}, no secret in the page; Admin: "
            f"Virtual Keys › {btn} › Optional Settings › Max Budget")


@check("browser", "walkthrough-storage")
def walkthrough_storage(ctx):
    """Whatever bn.tour holds, or when storage refuses, the page works (Home's Continue row there) and the walkthrough —
    closed at first: Get started is the first run — opens on Welcome."""
    hostile = json.dumps({"cur": "constructor", "done": "x", "base": {"open-webui": "1e9"}})
    cases = (("garbled", "localStorage.setItem('bn.tour', '{')", True),
             ("hostile", f"localStorage.setItem('bn.tour', {json.dumps(hostile)})", True),
             ("getItem throws", "Storage.prototype.getItem = function () { throw new Error('blocked') }", True),
             ("blocked", "Storage.prototype.getItem = Storage.prototype.setItem = function () { throw new Error('blocked') }", False))
    out = []
    for i, (name, js, _opens) in enumerate(cases):   # (each case now: closed at first, opened by its button)
        page, rec = ctx.page(f"walkthrough-storage-{i}", tour=True)
        page.context.add_init_script(f"(o => {{ if (location.origin === o) {{ {js}; }} }})({json.dumps(origin())});")
        login(page)
        page.wait_for_selector("#tour-btn:not([hidden])", state="attached")
        page.wait_for_selector("#continue:not([hidden])", timeout=15000)
        page.wait_for_timeout(500)
        expect(page.locator("#tour").is_hidden(), f"[{name}] opened by itself (Get started is the first run)")
        page.click("#tour-btn")
        page.wait_for_selector("#tour:not([hidden]) #tour-cur")
        expect(_cur(page) == "welcome", f"[{name}] opened on {_cur(page)!r}")
        if name == "hostile":
            saved = page.evaluate("() => JSON.parse(localStorage.getItem('bn.tour'))")
            expect(saved["cur"] == "welcome" and saved["base"] == {} and "signin-portal" in saved["done"], f"[{name}] saved {saved}")
        probs = rec.problems()
        rec.save()
        expect(not probs, f"[{name}] errors: {probs[:4]}")
        out.append(f"{name} → closed, opens on click on Welcome")
    return "; ".join(out)


# --- Settings (with the update helper running: tests/e2e/run.sh --helper runs the throwaway's bin/devos-ade-helper
# in the foreground for them) ---
# They change real credentials of the throwaway, so they run after the other browser checks (suite "settings") and
# keep ENV in step themselves: the container's copy of .env is a single-file mount that a rewritten .env never reaches.

SECRET_ENV = ("PORTAL_PASSWORD", "PORTAL_PASSWORD_HASH", "PORTAL_SECRET", "LITELLM_MASTER_KEY", "LITELLM_SALT_KEY",
              "AWS_SECRET_ACCESS_KEY", "RUSTFS_SECRET_KEY", "LITELLM_UI_PASSWORD", "SHARED_MCP_TOKEN", "POSTGRES_PASSWORD",
              "WEBUI_SECRET_KEY", "LITELLM_KEY_CLAUDE_CODE", "LITELLM_KEY_OPENWEBUI", "LITELLM_KEY_SETUP", "OPENWEBUI_API_KEY",
              "PORTAL_PROXY_SECRET", "OPENWEBUI_ADMIN_PASSWORD")
_last_apply = [0.0]
OWUI_USERS = "/api/v1/users"   # Open WebUI's account API


def _settings_api(ctx) -> dict:
    from common import http
    r = http("GET", None, "/api/settings", {"X-Requested-With": "devos-ade"}, cookie=ctx.session())
    expect(r.status == 200, f"/api/settings {r.status}")
    return json.loads(r.body)


def _need_helper(ctx) -> dict:
    d = _settings_api(ctx)
    if not (d["helper"]["running"] and d["helper"]["settings"]):
        if os.environ.get("E2E_HELPER_ON") == "1":   # run.sh --helper started it for these checks: missing is a failure
            raise AssertionError(f"run.sh --helper started the update helper, but the portal sees running={d['helper']['running']}, "
                                 f"settings={d['helper']['settings']} (see out/logs/helper.log)")
        raise Skip("no update helper with settings is running (tests/e2e/run.sh --helper runs these)")
    return d


def settings_drawn(page, timeout=30000):
    """Wait for Settings drawn from /api/settings' last answer. Every load of it — the tab shown, a link to a place in
    it, Reload, a change the helper finished — draws the whole page anew (its rows replaced); settings.js marks #settings
    aria-busy from the load's start until then. A row found before that may be gone when it is used ("Element is not
    attached to the DOM")."""
    page.wait_for_function("() => !document.querySelector('#settings[aria-busy]')", timeout=timeout)


def open_settings(page, place=None):
    page.click(".tab[data-tab=settings]")   # (the tab shown: settings.js loads the page again, aria-busy at once)
    page.wait_for_selector("#settings .set-card:not([hidden])", timeout=20000)
    settings_drawn(page)
    if place:
        goto_setting(page, place)


def goto_setting(page, place):
    """Settings at a section or a setting, as a link does (#settings/<section> or #settings/<KEY>): the section shown,
    More unfolded or a setting whose switch is off shown anyway. Returns the setting's row (or the section) of the page
    drawn last: the address change shows Settings again (the portal's hashchange), which loads it again — this waits
    for the hashchange (the load has then begun: aria-busy) and then for the page drawn from its answer."""
    page.evaluate("""p => new Promise((done) => {
        addEventListener('hashchange', () => done(), {once: true});   // (after the portal's own listener)
        setTimeout(done, 5000);
        location.hash = '#settings'; location.hash = '#settings/' + p; })""", place)
    settings_drawn(page)
    if re.fullmatch(r"[A-Z][A-Z0-9_]+", place):
        row = page.locator(f"#settings .set-row[data-key={place}], #settings .set-adv-item[data-key={place}]").first
    else:
        row = page.locator(f"#set-{place}")
    row.wait_for(state="visible", timeout=20000)
    return row


def _switch(row):
    """The On/Off switch of a settings row: (its locator, whether it is on)."""
    sw = row.locator("[role=switch]").first
    return sw, sw.get_attribute("aria-checked") == "true"


def _confirm(page, password=None, wait_sent=True):
    page.wait_for_selector("#set-confirm[open]", timeout=10000)
    page.fill("#set-confirm-password", password or ENV["PORTAL_PASSWORD"])
    wait = 6 - (time.time() - _last_apply[0])   # the portal takes one change every 5 s
    if wait > 0:
        page.wait_for_timeout(int(wait * 1000))
    page.click("#set-confirm-ok")
    _last_apply[0] = time.time()
    if not wait_sent:
        return
    # Sent once the dialog closes: settings.js then shows the new job in the same tick. Until then the panel may still
    # show the previous job's result, which _wait_job must not take for this one.
    try:
        page.wait_for_selector("#set-confirm:not([open])", state="attached", timeout=30000)
    except Exception:  # noqa: BLE001
        raise AssertionError(f"not sent: {page.inner_text('#set-confirm-error') or 'the dialog stayed open'}") from None
    form_err = page.locator("#settings .set-form .error:not([hidden])")
    expect(form_err.count() == 0, f"refused by the portal: {form_err.first.inner_text() if form_err.count() else ''}")


def _wait_job(page, timeout=240):
    """The helper's answer to the last change: (ok, message). A change made in a form that fails comes back as that form
    again, with the reason under its field ("Not saved: …"; the box at the top then goes)."""
    try:
        page.wait_for_selector("#set-job:not([hidden]) .job-message.good, #set-job:not([hidden]) .job-message.bad, "
                               "#settings .set-form > .error:not([hidden])", timeout=timeout * 1000)
    except Exception:  # noqa: BLE001 — say what the page shows instead of a bare timeout
        shown = page.evaluate("""() => [...document.querySelectorAll('#set-confirm[open] .error, #settings .set-form .error, #set-job')]
            .filter(n => !n.hidden && n.textContent.trim()).map(n => n.textContent.trim().slice(0, 160))""")
        shot(page, "settings-job-timeout", mask=[".set-value", ".set-adv-value"])
        raise AssertionError(f"no result from the helper within {timeout} s; the page shows: {shown or 'nothing'}")
    # settings.js loads the page again in the same tick it shows the result (aria-busy already set): its rows are
    # replaced once that answers (and a failed form's change opens that form again then)
    settings_drawn(page)
    page.wait_for_timeout(150)
    inline = page.locator("#settings .set-form > .error:not([hidden])")
    if inline.count() and inline.first.inner_text().startswith("Not saved:"):
        return False, inline.first.inner_text()
    return page.locator("#set-job .job-message.good").count() > 0, page.inner_text("#set-job-message")


def _change(page, key, fill: dict, password=None, timeout=240):
    """Change → fill the form → Save → password → wait for the helper. -> (ok, message)"""
    row = goto_setting(page, key)
    row.locator(".set-actions .action", has_text=re.compile("Change|Set")).first.click()
    for sel, value in fill.items():
        row.locator(sel).fill(value)
    row.locator(".set-form button[type=submit]").click()
    _confirm(page, password)
    return _wait_job(page, timeout)


def _lite_key_info(key):
    from checks_api import lite
    r = lite("GET", "/key/info", key=key)
    expect(r.status == 200, f"/key/info {r.status}")
    return r.json()["info"]


@check("browser", "settings-without-helper")
def settings_without_helper(ctx):
    d = _settings_api(ctx)
    if d["helper"]["running"]:
        raise Skip("an update helper is running (the settings/* checks cover that case)")
    page, rec = ctx.page("settings-no-helper")
    login(page)
    open_settings(page)
    expect(page.locator("#settings .set-helper.helper-off").is_visible(), "no hint that changes need the helper")
    expect("./stack helper install" in page.inner_text("#settings .set-helper"), "helper command missing")
    expect(page.locator("#settings .set-card").count() == 12, f"{page.locator('#settings .set-card').count()} sections")
    expect(page.locator("#settings .set-actions .action:not([disabled])", has_text="Change").count() == 0, "Change works without a helper")
    expect(page.locator("#settings [role=switch]:not([disabled])").count() == 0, "a switch works without a helper")
    goto_setting(page, "BUDGET_SETUP")   # (under More)
    expect("./stack config set BUDGET_SETUP" in page.inner_text("#set-spending"), "no terminal command next to a budget")
    html = page.content()
    leaked = [k for k in SECRET_ENV if len(ENV.get(k, "")) >= 8 and ENV[k] in html]
    expect(not leaked, f"secret values in the page: {leaked}")
    shot(page, "17-settings-no-helper")
    probs = rec.problems()
    rec.save()
    expect(not probs, f"errors: {probs}")
    return "read-only without the helper: the install hint, every section, ./stack config set per field; no secret in the page"


@check("browser", "settings-sections")
def settings_sections(ctx):
    """The Settings page's sections (no helper needed: nothing changes): one section at a time from the list, the
    address follows; links open a section or a setting (More unfolded, a setting whose switch is off shown with why);
    search and "Changed from default" across every section; the phone's picker."""
    d = _settings_api(ctx)
    page, rec = ctx.page("settings-sections")
    login(page)
    # Home's budget note links to the section
    page.wait_for_selector("#home:not([hidden])")
    page.click("#home a[href='#settings/spending']")
    page.wait_for_selector("#set-spending:not([hidden])", timeout=20000)
    settings_drawn(page)   # (a link: the page is loaded and drawn again)
    expect(page.evaluate("location.hash") == "#settings/spending", f"address {page.evaluate('location.hash')}")
    nav = page.locator(".set-nav .set-nav-item")
    expect(nav.count() == 12, f"{nav.count()} sections in the list")
    expect(page.locator(".set-nav-item[aria-current=true]").inner_text() == "Spending & budgets", "the list does not mark the section")
    # the list: one section at a time, the address follows (a reload comes back to it)
    page.locator(".set-nav-item", has_text="Claude Code").click()
    page.wait_for_selector("#set-code:not([hidden])")
    expect(page.locator("#settings .set-card:not([hidden])").count() == 1, "more than one section shown")
    expect(page.evaluate("location.hash") == "#settings/code", f"address {page.evaluate('location.hash')}")
    page.reload()
    page.wait_for_selector("#set-code:not([hidden])", timeout=20000)
    settings_drawn(page)
    # a setting under More: unfolded, scrolled to
    row = goto_setting(page, "BUDGET_SETUP")
    expect(page.locator("#set-spending details.set-more[open]").count() == 1, "More not unfolded for a setting in it")
    expect(row.is_visible(), "BUDGET_SETUP not shown")
    # a setting whose switch is off: hidden in its section, shown by a link with why
    keys = {k["key"]: k for k in d["snapshot"]["keys"]}
    off = keys.get("BACKUP_NIGHTLY", {}).get("value") != "on"
    goto_setting(page, "updates")
    if off:
        expect(page.locator("#settings .set-row[data-key=BACKUP_HOUR]").is_hidden(), "the backup window shows while nightly backups are off")
        goto_setting(page, "BACKUP_HOUR")
        expect("Applies while Nightly backups is on." in page.inner_text("#set-updates"), "no 'Applies while' for a hidden setting")
    # search: every section with a match, grouped; Clear goes back to the section
    page.fill("#set-find", "budget")
    page.wait_for_timeout(200)
    n_found = page.locator("#settings .set-card:not([hidden])").count()
    expect(n_found >= 2 and page.locator("#set-spending:not([hidden])").count() == 1, f"search: {n_found} sections")
    expect(page.locator("#set-spending .set-row[data-key=BUDGET_TERMINAL]").is_visible(), "search: the terminal's budget not found")
    expect(not page.locator("#settings .set-row[data-key=PORTAL_PASSWORD]").is_visible(), "search: a setting that does not match")
    shot(page, "17b-settings-search")
    page.click("#set-find-clear")
    expect(page.locator("#settings .set-card:not([hidden])").count() == 1 and page.input_value("#set-find") == "", "Clear did not end the search")
    # "Changed from default": only settings whose value differs from .env.example's
    page.click("#set-changed")
    page.wait_for_timeout(200)
    changed = page.eval_on_selector_all("#settings .set-card:not([hidden]) .set-dep:not([hidden]) > .set-row[data-key]:not(.set-ghost)", "els => els.map(e => e.dataset.key)")
    differs = lambda k: bool(keys.get(k, {}).get("value", "").strip()) and "default" in keys[k] and keys[k]["value"].strip() != keys[k]["default"].strip()  # noqa: E731
    inside = {}   # a row also counts as changed for the (not derived) keys shown inside it, e.g. STT_MODEL in Speech-to-text
    for r in d["layout"]["rows"]:
        if r["place"] == "with" and keys.get(r["key"], {}).get("policy") != "derived":
            inside.setdefault(r["parent"], []).append(r["key"])
    bad = [k for k in changed if not any(differs(x) for x in [k, *inside.get(k, [])])]
    expect(not bad, f"shown as changed but not: {bad}")
    page.click("#set-changed")
    # a link to a setting from the walkthrough's address grammar, from another tab
    page.click(".tab[data-tab=home]")
    page.evaluate("location.hash = '#settings/CODE_ENABLED'")
    page.wait_for_selector("#set-code:not([hidden]) .set-row[data-key=CODE_ENABLED]", timeout=20000)
    settings_drawn(page)   # (the list's buttons below: of the page drawn last)
    # keyboard: the list's buttons, then the section's heading
    page.locator(".set-nav-item", has_text="Files & sharing").focus()
    page.keyboard.press("Enter")
    page.wait_for_selector("#set-files:not([hidden])")
    expect(page.evaluate("document.activeElement && document.activeElement.id") == "set-files-title", "focus not on the section's heading")
    probs = rec.problems()
    rec.save()
    # a phone: the picker (a new browser context: the desktop page above closes)
    ppage, prec = ctx.page("settings-sections-phone", device="phone")
    login(ppage)
    ppage.evaluate("location.hash = '#settings/remote'")
    ppage.wait_for_selector("#set-remote:not([hidden])", timeout=20000)
    settings_drawn(ppage)   # (the picker below: of the page drawn last)
    expect(ppage.input_value("#set-picker") == "remote", "phone: the picker does not show the section")
    ppage.select_option("#set-picker", "updates")
    ppage.wait_for_selector("#set-updates:not([hidden])")
    expect(ppage.evaluate("location.hash") == "#settings/updates", "phone: the address does not follow the picker")
    probs += prec.problems()
    prec.save()
    expect(not probs, f"errors: {probs}")
    return (f"12 sections, one at a time; Home → Spending & budgets; More unfolds for BUDGET_SETUP; "
            f"{'a hidden dependent shown with why; ' if off else ''}search 'budget' → {n_found} sections; "
            f"Changed from default → {len(changed)} settings; keyboard to the heading; phone picker")


@check("browser", "settings-providers")
def settings_providers(ctx):
    """Settings › Models & providers (no helper needed: nothing changes): a card for every key and sign-in that adds
    models — Bedrock, OpenRouter, Experiential Labs, each of Your AI subscriptions — and Search's (Claude Code's
    WebSearch, each of its backends), each with its state, what it adds and its one action (a key's form opens and is cancelled; a tool's Sign in is never pressed: it starts
    the provider's own sign-in); the old places say where they went, and a greyed item of Chat's Who answers leads to
    its card (catalog/setup-links.tsv)."""
    d = _settings_api(ctx)
    keys = {k["key"]: k for k in d["snapshot"]["keys"]}
    models = d["snapshot"]["choices"].get("code_models") or []
    can = bool(d["helper"]["running"] and d["helper"]["settings"] and d["here"]["allowed"])
    page, rec = ctx.page("settings-providers")
    login(page)
    open_settings(page, "providers")
    sec = page.locator("#set-providers")
    expect(page.locator(".set-nav-item[aria-current=true]").inner_text() == "Models & providers", "the list does not mark the section")
    heads = [x.strip() for x in sec.locator(".set-group-head").all_text_contents()]
    expect(heads == ["Keys", "Subscriptions", "Local models", "Search"], f"the groups' heads: {heads}")
    # (JON-812) the groups are tabs, one at a time: Keys first; the others' cards are not shown until their tab is
    tab_names = [x.strip() for x in sec.locator(".set-minnav .chip").all_text_contents()]
    expect(tab_names == heads and sec.locator(".set-minnav .chip[aria-pressed=true]").inner_text() == "Keys", f"the tabs: {tab_names}")
    expect(sec.locator("#set-subscriptions").is_hidden() and sec.locator(".set-dep[data-key=WEBSEARCH_BACKEND]").is_hidden(),
           "the Subscriptions and Search cards show on the Keys tab")
    said = []
    for key, name, prov in (("AWS_ACCESS_KEY_ID", "Bedrock", "Bedrock"), ("OPENROUTER_API_KEY", "OpenRouter", "OpenRouter"),
                            ("EXPLABS_API_KEY", "Experiential Labs", "Experiential Labs")):
        card = sec.locator(f".set-dep.set-prov > .set-row[data-key={key}]")
        expect(card.count() == 1, f"{name}: no card")
        expect(card.locator(".set-name").first.inner_text() == name, f"{key}'s card is not named {name}")
        k = keys[key]
        on = bool(k.get("set")) or (key == "AWS_ACCESS_KEY_ID" and keys.get("AWS_AUTH", {}).get("value") == "instance-role")
        state = card.locator(".set-prov-state").inner_text()
        adds = card.locator(".set-prov-adds").inner_text()
        n = sum(1 for m in models if m[2] == prov)
        if on:
            expect(state.startswith("On"), f"{name}: state {state!r} with its key")
            expect((f"Adds {n} model" in adds) if n else ("Adds no models yet" in adds), f"{name}: {adds!r} ({n} models in the snapshot)")
        else:
            expect(state == "Not set up" and "Sends nothing until it has a key" in adds, f"{name}: {state!r} {adds!r} without its key")
        # its one action: Add key or Replace key (from this computer: these checks run there), enabled with the helper
        btn = card.locator(":scope > .set-actions button.action:not([data-act])")
        want = "Replace key" if k.get("set") else "Add key"
        expect(btn.count() == 1 and btn.inner_text() == want, f"{name}: its action is {btn.all_inner_texts()}, not {want}")
        expect(btn.is_enabled() == can, f"{name}: {want} enabled={btn.is_enabled()} with the helper {'on' if can else 'off'}")
        if can:
            btn.click()
            form = card.locator(".set-form")
            expect(form.locator("input[type=password]").count() >= 1, f"{name}: the form has no field for the key")
            form.locator("button", has_text="Cancel").click()
        said.append(f"{name}: {state}, {want}")
    # your subscriptions: a card each, with its state, the pickers it answers in and its next step
    sec.locator(".set-minnav .chip", has_text="Subscriptions").click()
    tools = (d.get("subscriptions") or {}).get("tools") or []
    cards = sec.locator("#set-subscriptions > li.set-prov[data-tool]")
    expect(cards.count() == len(tools) and len(tools) >= 6, f"{cards.count()} subscription cards for {len(tools)} tools")
    term_here = page.evaluate("() => typeof APP_URLS !== 'undefined' && Boolean(APP_URLS.terminal)")
    for t in tools:
        c = sec.locator(f"#set-subscriptions > li[data-tool={t['id']}]")
        state = c.locator(".set-prov-state").inner_text()
        expect(state, f"{t['id']}: no state")
        if t["installed"] is True and t["signed_in"] == "yes":
            expect(state.startswith("signed in"), f"{t['id']}: {state!r}")
        expect(c.locator(".set-prov-adds").inner_text().startswith("Adds "), f"{t['id']}: no line of what it adds")
        step = c.locator("[data-where=terminal] [data-act]").first
        act = step.get_attribute("data-act")
        if t["installed"] is False:
            expect(act == "subscriptions-left-out", f"{t['id']}: left out of the sandbox, next step {act}")
        elif not term_here:
            expect(act == "subscriptions-terminal-off", f"{t['id']}: the terminal is off here, next step {act}")
        else:
            expect(act == "subscriptions-open" and step.inner_text() == ("Open in the terminal" if t["signed_in"] == "yes" else "Sign in"),
                   f"{t['id']}: next step {act} {step.inner_text()!r}")
    # Search: Claude Code's WebSearch (the backend in use and why, or why none) and a card for each option (lib/websearch.sh:
    # the snapshot's choices.websearch) — the built-in SearXNG first (its switch), then the others — each with its state,
    # what it adds, its one action (a form, cancelled; the built-in one's switch) and its info button (what it costs and
    # sends, how steady and private it is, where its key comes from: opened by a click, closed by Escape)
    sec.locator(".set-minnav .chip", has_text="Search").click()
    ws = d["snapshot"]["choices"].get("websearch") or {}
    for key, name, b in (("WEBSEARCH_BACKEND", "Web search", ""), ("WEBSEARCH_SEARXNG_BUILTIN", "Built-in SearXNG", "builtin"),
                         ("WEBSEARCH_AGENTCORE_GATEWAY", "AgentCore Web Search", "agentcore"), ("WEBSEARCH_TAVILY_API_KEY", "Tavily", "tavily"),
                         ("WEBSEARCH_BRAVE_API_KEY", "Brave Search", "brave"), ("WEBSEARCH_PERPLEXITY_API_KEY", "Perplexity", "perplexity"),
                         ("WEBSEARCH_SEARXNG_URL", "Your own SearXNG", "searxng")):
        card = sec.locator(f".set-dep.set-prov > .set-row[data-key={key}]")
        expect(card.count() == 1, f"{name}: no card")
        expect(card.locator(".set-name").first.inner_text() == name, f"{key}'s card is not named {name}")
        state = card.locator(".set-prov-state").inner_text()
        adds = card.locator(".set-prov-adds").inner_text()
        if key == "WEBSEARCH_BACKEND":
            expect((state in ("On", "Needs a step")) if ws.get("backend") else state == "Off", f"{name}: {state!r} with backend {ws.get('backend')!r}")
            expect(("WebSearch searches with" in adds) if ws.get("backend") else ("WebSearch says it is not available" in adds), f"{name}: {adds!r}")
            if ws.get("reason"):
                expect(ws["reason"] in adds, f"{name}: {adds!r} says not why ({ws['reason']!r})")
        elif b == "builtin":
            expect(state in ("In use", "In use · needs a step", "On · not in use", "Off"), f"{name}: state {state!r}")
            expect((state.startswith("In use")) == (ws.get("backend") == "builtin"), f"{name}: {state!r} with backend {ws.get('backend')!r}")
            expect(("only the query goes to" in adds) if ws.get("backend") == "builtin" else bool(adds), f"{name}: {adds!r}")
        else:
            expect(state in ("In use", "In use · needs a step", "Set up", "Not set up", "Needs your AWS admin"), f"{name}: state {state!r}")
            expect("the queries" in adds, f"{name}: {adds!r} says not where the queries go")
        if b == "builtin":
            sw = card.locator(":scope > .set-actions button.switch[role=switch]")
            expect(sw.count() == 1 and sw.get_attribute("aria-checked") == ("true" if ws.get("builtin", {}).get("state") != "off" else "false"),
                   f"{name}: its switch {sw.count()} {sw.first.get_attribute('aria-checked') if sw.count() else None}")
            expect(sw.is_enabled() == can, f"{name}: its switch enabled with the helper {'on' if can else 'off'}")
        else:
            btn = card.locator(":scope > .set-actions button.action:not([data-act])")
            expect(btn.count() == 1 and btn.is_enabled() == can, f"{name}: its action {btn.all_inner_texts()}, enabled with the helper {'on' if can else 'off'}")
            if can:
                btn.click()
                form = card.locator(".set-form")
                expect(form.locator("input, select").count() >= 1, f"{name}: the form has no field")
                form.locator("button", has_text="Cancel").click()
        if b:
            info = card.locator(".set-label button.set-info-btn")
            expect(info.count() == 1 and info.get_attribute("aria-expanded") == "false", f"{name}: no closed info button")
            panel = card.locator(f"#set-ws-info-{b}")
            expect(panel.count() == 1 and panel.is_hidden() and info.get_attribute("aria-controls") == f"set-ws-info-{b}", f"{name}: its info panel")
            expect((info.get_attribute("aria-label") or "").startswith("About ") and "cost, what is sent, privacy" in info.get_attribute("aria-label"),
                   f"{name}: info button's label {info.get_attribute('aria-label')!r}")
            info.click()
            expect(panel.is_visible() and info.get_attribute("aria-expanded") == "true", f"{name}: the info panel did not open")
            dts = panel.locator("dt").all_inner_texts()
            expect([t.upper() for t in dts[:3]] == ["COST", "WHAT IS SENT", "RELIABILITY AND PRIVACY"] and len(dts) == 4, f"{name}: info {dts}")
            body = panel.inner_text()
            expect("search query" in body, f"{name}: the info says not what is sent: {body[:200]!r}")
            for a in panel.locator("a").all():
                href = a.get_attribute("href") or ""
                expect(href.startswith("https://") and a.get_attribute("target") == "_blank" and "noopener" in (a.get_attribute("rel") or ""),
                       f"{name}: info link {href!r}")
            cost = panel.locator("dd").first
            if "$" in cost.inner_text():   # a price: the month it was checked, and its pricing page
                expect("as of Oct 2026" in cost.inner_text() and cost.locator("a", has_text="pricing").count() == 1, f"{name}: a price without its page or month: {cost.inner_text()!r}")
            info.focus()
            page.keyboard.press("Escape")
            expect(panel.is_hidden() and info.get_attribute("aria-expanded") == "false", f"{name}: Escape left the info open")
        said.append(f"{name}: {state}")
    shot(page, "17c-settings-providers")
    # the old places say where they went, and their links land on the card
    goto_setting(page, "aws")
    link = page.locator("#set-aws .set-moved a")
    expect(link.count() == 1 and link.get_attribute("href") == "#settings/AWS_ACCESS_KEY_ID", "Bedrock (AWS): no link to the AWS key's card")
    link.click()
    page.wait_for_selector("#set-providers:not([hidden]) .set-row[data-key=AWS_ACCESS_KEY_ID]", timeout=20000)
    settings_drawn(page)
    for sid, place in (("chat", "OPENROUTER_API_KEY"), ("code", "+subscriptions")):
        goto_setting(page, sid)
        expect(page.locator(f"#set-{sid} .set-moved a[href='#settings/{place}']").count() == 1, f"{sid}: no link to {place}")
    # a greyed item leads to its card: Chat's Who answers without OpenRouter's (or Experiential Labs') key
    off = next((r for r, k in (("openrouter-off", "OPENROUTER_API_KEY"), ("explabs-off", "EXPLABS_API_KEY")) if not keys[k].get("set")), None)
    if off:
        target = "OPENROUTER_API_KEY" if off == "openrouter-off" else "EXPLABS_API_KEY"
        page.click(".tab[data-tab=chat]")
        page.locator("#answers-chat").wait_for(timeout=15000)
        page.wait_for_function("v => [...document.querySelectorAll('#answers-chat option')].some((o) => o.value === v)", arg=f"setup:{off}:", timeout=20000)
        page.select_option("#answers-chat", f"setup:{off}:")
        expect((page.get_attribute("#answers-chat-go", "aria-label") or "").startswith("Go to Settings › Models & providers ›"),
               "the button's name does not say Models & providers")
        page.click("#answers-chat-go")
        page.wait_for_selector(f"#set-providers:not([hidden]) .set-row[data-key={target}]", timeout=20000)
        expect(page.evaluate("location.hash") == f"#settings/{target}", f"not the card's address: {page.evaluate('location.hash')}")
        said.append(f"Chat's {off} → its card")
    probs = rec.problems()
    rec.save()
    expect(not probs, f"errors: {probs}")
    # a phone: Settings' section is a short list of cards — each row's words (its summary, badges, notes, the terminal
    # command) folded under its Details, its name, value and control in view; Details in the page's words, the
    # setting's .env name only in its footer for the terminal; Models & providers' groups as a bar of links
    ppage, prec = ctx.page("settings-providers-phone", device="phone")
    login(ppage)
    ppage.evaluate("location.hash = '#settings/providers'")
    ppage.wait_for_selector("#set-providers:not([hidden])", timeout=20000)
    heights = {}
    for sec in ("providers", "code"):
        ppage.evaluate(f"location.hash = '#settings/{sec}'")
        ppage.wait_for_selector(f"#set-{sec}:not([hidden])", timeout=20000)
        ppage.wait_for_timeout(500)
        loose = ppage.locator(f"#set-{sec} .set-row > .set-main > .set-sum, #set-{sec} .set-row > .set-cli").count()
        expect(loose == 0, f"phone: {loose} summaries or terminal lines of {sec} not folded under Details")
        heights[sec] = ppage.evaluate("() => document.querySelector('#settings').scrollHeight")
        if sec == "providers":
            groups = ppage.eval_on_selector_all("#set-providers .set-minnav button", "els => els.map(e => e.textContent)")
            expect(groups == ["Keys", "Subscriptions", "Local models", "Search"], f"phone: the groups' bar {groups}")
    row = ppage.locator("#set-code .set-row[data-key=CODE_ENABLED]")
    row.locator(":scope > details.set-details > summary").click()
    det = row.locator(":scope > details.set-details").inner_text()
    # (inner_text as shown: the footer's heading is in capitals)
    expect("for the terminal" in det.lower() and "CODE_ENABLED" in det and "true =" not in det, f"phone: the Code page's Details: {det[-300:]!r}")
    shot(ppage, "22b-settings-phone-code-details", mask=[".set-value", ".set-adv-value"])
    probs = prec.problems()
    prec.save()
    expect(not probs, f"phone errors: {probs[:6]}")
    said.append(f"phone: sections folded to their cards (Models & providers {heights['providers']} px, Claude Code {heights['code']} px), Details in the page's words")
    return "; ".join(said) + f"; {len(tools)} subscription cards; Bedrock (AWS), Chat & voice and Claude Code link here"


# Each row with a control: [key, row, its name line, its control, its summary, its info panel (open), what it adds] as
# {left, top, right, bottom, width}; null for a piece it does not have
NARROW_ROWS = """(sec) => { const box = (e) => { if (!e || !e.getClientRects().length) return null; const r = e.getBoundingClientRect();
    return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, max: parseFloat(getComputedStyle(e).maxWidth) || 1e6 }; };
  // the inline size its @container set-dep query sees (a setting in a column of a wide card: its content box)
  const cw = (c) => { if (!c) return null; const s = getComputedStyle(c); return c.clientWidth - parseFloat(s.paddingLeft) - parseFloat(s.paddingRight); };
  return [...document.querySelectorAll(sec + ' .set-row')].filter((r) => r.getClientRects().length).map((r) => {
    const a = r.querySelector(':scope > .set-actions');
    return [r.dataset.key || r.dataset.own, box(r), box(r.querySelector('.set-label')), a && a.children.length ? box(a) : null,
            box(r.querySelector('.set-sum')), box(r.querySelector('.set-ws-info:not([hidden])')), box(r.querySelector('.set-prov-adds')),
            cw(r.closest('.set-rows > .set-dep'))]; })
    .filter((x) => x[3]); }"""


@check("browser", "settings-narrow-cards")
def settings_narrow_cards(ctx):
    """Settings' cards on a phone and a tablet: each setting's control (a switch, Change, Add key, Set the gateway) under
    its name line, and its words the card's full width — not squeezed beside the control; on a desktop the control
    stays beside them, except in a column under 520 px (a wide card's tabs, two or three across: @container set-dep),
    where it goes under the name as on a phone. Models & providers (the built-in SearXNG's info open) and Claude Code
    (its switches)."""
    said = []
    for device, narrow in (("phone", True), ("tablet", True), ("desktop", False)):
        page, rec = ctx.page(f"settings-narrow-{device}", device=device)
        login(page)
        rows = []
        for sec in ("providers", "code"):
            page.evaluate(f"location.hash = '#settings/{sec}'")
            page.wait_for_selector(f"#set-{sec}:not([hidden]) .set-row", timeout=20000)
            settings_drawn(page)
            # Models & providers shows one group at a time (Keys, Subscriptions, Local models, Search: its tabs): each in turn
            groups = page.eval_on_selector_all(f"#set-{sec} .set-minnav .chip", "els => els.map(e => e.dataset.group)") or [None]
            for g in groups:
                if g:
                    page.click(f'#set-{sec} .set-minnav .chip[data-group="{g}"]')
                    page.wait_for_selector(f'#set-{sec} .set-tabbed[data-group="{g}"]')
                    # one group at a time: no block of another group shows under this tab
                    others = page.evaluate("""([sec, g]) => [...document.querySelectorAll(`#set-${sec} .set-tabbed > [data-group]`)]
                      .filter((e) => e.dataset.group !== g && e.getClientRects().length).map((e) => e.dataset.key || e.dataset.group)""", [sec, g])
                    expect(not others, f"{device}: the {g} tab also shows {others[:6]}")
                info = page.locator(f"#set-{sec} .set-row[data-key=WEBSEARCH_SEARXNG_BUILTIN] .set-info-btn")
                panel = "#set-providers .set-row[data-key=WEBSEARCH_SEARXNG_BUILTIN] .set-ws-info"
                # (its info open once: the button toggles it, so not pressed again where it is open already)
                if sec == "providers" and info.count() and info.first.is_visible() and page.locator(f"{panel}[hidden]").count():
                    info.first.click()
                    page.wait_for_selector(f"{panel}:not([hidden])")
                rows += page.evaluate(NARROW_ROWS, f"#set-{sec}")
                shot(page, f"17c-settings-narrow-{device}-{sec}" + (f"-{g.replace(' ', '-')}" if g else ""))
        expect(len(rows) >= 8, f"{device}: only {len(rows)} rows with a control")
        bad = []
        cols = 0
        for key, row, label, act, summ, info, adds, cw in rows:
            stack = narrow or (cw is not None and cw < 520)
            cols += not narrow and stack
            if stack:
                # under the name line, at the row's left; every piece of text as wide as the row (within 2 px)
                if not (label and act["top"] >= label["bottom"] - 1 and abs(act["left"] - row["left"]) < 2):
                    bad.append(f"{key}: control {act} not under its name {label}")
                if summ and act["bottom"] > summ["top"] + 1:
                    bad.append(f"{key}: control below its summary")
                # (as wide as the row, or as its own max-width: 70ch)
                for what, b in (("summary", summ), ("info panel", info), ("adds", adds)):
                    if b and b["width"] < min(row["width"], b["max"]) - 2:
                        bad.append(f"{key}: its {what} {b['width']:.0f} of {row['width']:.0f} px")
            elif not (label and act["left"] >= label["right"] - 1 and act["top"] < label["bottom"]):
                bad.append(f"{key}: desktop control {act} not beside its name {label}")
        expect(not bad, f"{device}: {bad[:6]}")
        w = next((r[1]["width"] for r in rows if r[0] == "WEBSEARCH_SEARXNG_BUILTIN"), 0)
        probs = rec.problems()
        rec.save()
        expect(not probs, f"{device}: errors {probs[:6]}")
        said.append(f"{device}: {len(rows)} rows, the control {'under the name, the words full width' if narrow else 'beside them'}"
                    + (f" ({cols} in a column under 520 px: under the name)" if cols else "")
                    + f" (the built-in SearXNG's row {w:.0f} px)")
    return "; ".join(said)


@check("browser", "error-pages")
def error_pages(ctx):
    """UX-10: a page of the portal that is not there, and a name that is not this install's — each in the sign-in card's
    design (its tokens and fonts, which load: the unknown name gets the portal's public files under that name), with a
    way back that works (Go to Home; Search opens the search; Go to DevOS ADE), no console error and no CSP violation."""
    page, rec = ctx.page("error-pages")
    login(page)
    fonts = """async () => { await document.fonts.ready;
        return ['600 20px "DevOS Serif"', '400 15px "DevOS Sans"'].every((f) => document.fonts.check(f))
          && [...document.fonts].some((f) => f.family.replace(/"/g, '') === 'DevOS Serif' && f.status === 'loaded'); }"""
    # the portal's 404: Home and Search
    page.goto(origin() + "/no-such-page")
    page.wait_for_selector("main.error-panel h1")
    expect(page.inner_text("h1") == "This page does not exist", f"404 title {page.inner_text('h1')!r}")
    expect(page.evaluate(fonts), "the 404 page's fonts did not load")
    shot(page, "error-portal-404")
    page.locator("a.pill-link", has_text="Search").click()
    page.wait_for_selector("#search[open]", timeout=15000)
    page.keyboard.press("Escape")
    page.goto(origin() + "/no-such-page")
    page.locator("a.pill-link", has_text="Go to Home").click()
    page.wait_for_selector("#home:not([hidden])", timeout=15000)
    # a name that is not this install's (any name under the site: Caddy's catch-all)
    other = f"http://nosuch.{HOST}:{PORT}/some/path?x=1"
    page.goto(other)
    page.wait_for_selector("main.error-panel h1")
    expect(page.inner_text("h1") == "Not an address of DevOS ADE" and "nosuch" not in page.content(), "the unknown host's page")
    expect(page.evaluate(fonts), "the unknown host's fonts did not load")
    shot(page, "error-unknown-host")
    page.locator("a.pill-link", has_text="Go to DevOS ADE").click()
    page.wait_for_url(re.compile("^" + re.escape(origin()) + "/"), timeout=15000)
    page.wait_for_selector(".shell", timeout=15000)
    probs = rec.problems(allow=[r"^404 GET " + re.escape(origin()) + "/no-such-page$", r"^404 GET http://nosuch\."])
    rec.save()
    expect(not probs, f"errors: {probs}")
    return "portal 404 and unknown host: the sign-in card's design, its fonts loaded; Search, Go to Home and Go to DevOS ADE work"


@check("settings", "settings-page")
def settings_page(ctx):
    d = _need_helper(ctx)
    page, rec = ctx.page("settings-page")
    login(page)
    open_settings(page)
    expect(page.locator("#settings .set-card").count() == 12, f"{page.locator('#settings .set-card').count()} sections, not twelve")
    expect(page.locator("#settings .set-card:not([hidden])").count() == 1, "more than one section shown at a time")
    expect(page.locator("#settings .set-helper").is_hidden(), "the helper hint shows while the helper runs")
    goto_setting(page, "advanced")
    for k in ("LITELLM_SALT_KEY", "POSTGRES_PASSWORD", "PORTAL_HOST", "COMPOSE_PROJECT_NAME"):
        expect(page.locator(f"#set-advanced .set-adv-item[data-key={k}]").count() == 1, f"Advanced lacks {k}")
    goto_setting(page, "about")
    expect(page.locator("#set-about .set-adv-item[data-key=OWUI_EMBED_MODEL]").count() == 1, "About this install lacks OWUI_EMBED_MODEL")
    html = page.content()
    leaked = [k for k in SECRET_ENV if len(ENV.get(k, "")) >= 8 and ENV[k] in html]
    expect(not leaked, f"secret values in the page: {leaked}")
    expect(d["snapshot"]["base"] and len(d["snapshot"]["keys"]) >= 86, "snapshot")
    expect(len(d["layout"]["sections"]) == 12 and len(d["layout"]["rows"]) >= 120, "layout")
    goto_setting(page, "account")
    shot(page, "18-settings-desktop", mask=[".set-value", ".set-adv-value"])
    page.emulate_media(color_scheme="dark")
    page.wait_for_timeout(300)
    shot(page, "19-settings-desktop-dark", mask=[".set-value", ".set-adv-value"])
    goto_setting(page, "spending")
    shot(page, "20-settings-budgets-dark", mask=[".set-value", ".set-adv-value"])
    page.emulate_media(color_scheme="light")
    # a phone: Settings opens from More, as a page of the portal; the section picker instead of the list
    ppage, prec = ctx.page("settings-phone", device="phone")
    login(ppage)
    ppage.click("#more-btn")
    ppage.click("#more-sheet .sheet-link[data-page=settings]")
    ppage.wait_for_selector("#settings .set-card:not([hidden])", timeout=20000)
    settings_drawn(ppage)
    expect(ppage.locator("#settings").is_visible() and ppage.locator("#more-sheet").is_hidden(), "phone: Settings not shown")
    expect(ppage.locator("#set-picker").is_visible() and ppage.locator(".set-nav").is_hidden(), "phone: no section picker")
    width = ppage.evaluate("document.querySelector('#settings').scrollWidth")
    expect(width <= 392, f"phone: the page scrolls sideways ({width}px)")
    shot(ppage, "21-settings-phone", mask=[".set-value", ".set-adv-value"])
    ppage.select_option("#set-picker", "chat")
    ppage.locator("#set-chat .set-row[data-key=STT_PROVIDER]").wait_for(timeout=10000)
    expect(ppage.locator("#settings .set-card:not([hidden])").count() == 1, "phone: more than one section shown")
    shot(ppage, "22-settings-phone-voice", mask=[".set-value", ".set-adv-value"])
    probs = rec.problems() + prec.problems()
    rec.save(); prec.save()
    expect(not probs, f"errors: {probs}")
    return "12 sections, one at a time; Advanced and About list the rest; no secret in the page; desktop light/dark and phone (picker) render"


@check("settings", "settings-key-check")
def settings_key_check(ctx):
    """UX-05 with the real portal and update helper (fake keys made here: what they reach costs nothing). OpenRouter's
    form: Save waits for a key; the key is asked of openrouter.ai by the portal before the password — a fake one is
    rejected within seconds, said under the field with where keys come from, the key kept, no password dialog. The AWS
    key: a fake pair goes through the password to the helper, whose free check refuses it; the form opens again with
    the key ID in it and the helper's reason under it, nothing changed."""
    import secrets as sec
    import string
    d = _need_helper(ctx)
    base = d["snapshot"]["base"]
    page, rec = ctx.page("settings-key-check")
    login(page)
    open_settings(page)
    row = goto_setting(page, "OPENROUTER_API_KEY")
    row.locator(":scope > .set-actions button.action:not([data-act])").click()
    form = row.locator(".set-form")
    save, field = form.locator("button[type=submit]"), form.locator("input[type=password]")
    expect(save.is_disabled(), "OpenRouter's Save is enabled with an empty key")
    expect(form.locator(".set-getkey a").get_attribute("href") == "https://openrouter.ai/settings/keys", "no Get a key link")
    fake = "-".join(("sk", "or", "v1", sec.token_hex(32)))
    field.fill(fake)
    t0 = time.time()
    save.click()
    form.locator(":scope > .error:not([hidden])").wait_for(timeout=20000)
    took = time.time() - t0
    err = form.locator(":scope > .error").inner_text()
    if "did not answer" in err or "Could not reach" in err:
        said = f"openrouter.ai not reachable from the portal here ({err[:80]!r}), said in {took:.1f} s"
        expect(save.inner_text() == "Save anyway", f"no Save anyway after no answer: {save.inner_text()!r}")
    else:
        expect(err.startswith("OpenRouter rejected this key (HTTP 401).") and "Nothing was saved." in err, f"a fake OpenRouter key: {err!r}")
        expect(form.locator(":scope > .error a").get_attribute("href") == "https://openrouter.ai/settings/keys", "no link in the error")
        said = f"a fake OpenRouter key rejected by openrouter.ai in {took:.1f} s, under the field"
    expect(took < 12, f"the check took {took:.1f} s")
    expect(field.input_value() == fake and page.locator("#set-confirm[open]").count() == 0, "the key was not kept, or the password asked")
    shot(page, "24-settings-key-rejected", mask=[".set-value", ".set-adv-value"])
    form.locator("button", has_text="Cancel").click()
    # the AWS key: the helper's own check refuses a fake pair; the form comes back with it and why
    row = goto_setting(page, "AWS_ACCESS_KEY_ID")
    row.locator(":scope > .set-actions button.action:not([data-act])").click()
    form = row.locator(".set-form")
    kid = "AKIA" + "".join(sec.choice(string.ascii_uppercase + string.digits) for _ in range(16))
    secret = "".join(sec.choice(string.ascii_letters + string.digits) for _ in range(40))
    form.locator("input").nth(0).fill(kid)
    expect(form.locator("button[type=submit]").is_disabled(), "the AWS key's Save is enabled with half a key")
    form.locator("input").nth(1).fill(secret)
    form.locator("button[type=submit]").click()
    _confirm(page)
    ok, msg = _wait_job(page, 240)
    expect(not ok, f"a fake AWS key was saved: {msg}")
    form = page.locator("#settings .set-row[data-key=AWS_ACCESS_KEY_ID] > .set-form")
    expect(form.count() == 1 and msg.startswith("Not saved:"), f"the form did not come back with the reason: {msg!r}")
    expect(form.locator("input").nth(0).input_value() == kid, "the key ID typed was not kept")
    expect(page.locator("#set-job").is_hidden(), "the reason is also in the box at the top")
    expect(_settings_api(ctx)["snapshot"]["base"] == base, ".env changed")
    shot(page, "25-settings-aws-key-refused", mask=[".set-value", ".set-adv-value", "#settings .set-form input"])
    form.locator("button", has_text="Cancel").click()
    probs = rec.problems()
    rec.save()
    expect(not probs, f"errors: {probs}")
    return f"{said}; a fake AWS key: the helper refused it, the form back with the key ID and {msg[:90]!r}; .env unchanged"


@check("settings", "settings-budget-change")
def settings_budget(ctx):
    _need_helper(ctx)
    page, rec = ctx.page("settings-budget")
    login(page)
    open_settings(page)
    new = "0.03" if ENV["BUDGET_SETUP"] != "0.03" else "0.025"
    t0 = time.time()
    ok, msg = _change(page, "BUDGET_SETUP", {"input": new})
    expect(ok, f"budget change failed: {msg}")
    secs = time.time() - t0
    info = _lite_key_info(ENV["LITELLM_KEY_SETUP"])
    expect(abs(float(info["max_budget"]) - float(new)) < 1e-9, f"LiteLLM max_budget {info['max_budget']}, want {new}")
    ENV["BUDGET_SETUP"] = new
    page.wait_for_selector(f"#settings .set-row[data-key=BUDGET_SETUP] .set-value[data-value='{new}']", state="attached", timeout=15000)
    goto_setting(page, "BUDGET_SETUP")
    shot(page, "23-settings-budget-saved", mask=[".set-value", ".set-adv-value"])
    rec.save()
    return f"BUDGET_SETUP → {new} in .env and in LiteLLM (max_budget) in {secs:.0f} s, no restart; message: {msg}"


@check("settings", "settings-reveal-copies")
def settings_reveal(ctx):
    _need_helper(ctx)
    page, rec = ctx.page("settings-reveal")
    login(page)
    page.context.grant_permissions(["clipboard-read", "clipboard-write"], origin=origin())
    open_settings(page)
    page.evaluate("navigator.clipboard.writeText('')")
    goto_setting(page, "SHARED_MCP_TOKEN").locator(".set-actions .copy").first.click()
    _confirm(page)
    clip, t0 = "", time.time()
    while time.time() - t0 < 5 and not clip:
        clip = page.evaluate("navigator.clipboard.readText()")
        page.wait_for_timeout(100)
    expect(clip == ENV["SHARED_MCP_TOKEN"], "Reveal did not copy SHARED_MCP_TOKEN")
    page.evaluate("navigator.clipboard.writeText('')")
    from common import http
    r = http("POST", None, "/api/settings/reveal", {"X-Requested-With": "devos-ade", "Origin": origin(), "Content-Type": "application/json"},
             json.dumps({"key": "AWS_SECRET_ACCESS_KEY", "password": ENV["PORTAL_PASSWORD"]}), cookie=ctx.session())
    expect(r.status == 403, f"AWS_SECRET_ACCESS_KEY revealed? HTTP {r.status}")
    rec.save()
    return "Reveal (password again) copies the MCP token; the AWS secret is never revealed (403)"


@check("settings", "settings-litellm-password")
def settings_litellm_password(ctx):
    need("litellm")
    _need_helper(ctx)
    page, rec = ctx.page("settings-litellm-pw")
    login(page)
    open_settings(page)
    new = f"Set-E2e-{int(time.time()) % 100000}!a9"
    old = ENV["LITELLM_UI_PASSWORD"]
    ok, msg = _change(page, "LITELLM_UI_PASSWORD", {"input[id$=-a]": new, "input[id$=-b]": new})
    expect(ok, f"LiteLLM password change failed: {msg}")
    ENV["LITELLM_UI_PASSWORD"] = new
    from checks_api import lite
    good = lite("POST", "/v2/login", body={"username": ENV["LITELLM_UI_USER"], "password": new})
    bad = lite("POST", "/v2/login", body={"username": ENV["LITELLM_UI_USER"], "password": old})
    expect(good.status == 200, f"new password: HTTP {good.status}")
    expect(bad.status != 200, "the old password still signs in")
    # and the Admin tab still signs in by itself: the portal restarted with the new password
    page.click(".tab[data-tab=admin]")
    sso_signed_in(page, page.frame_locator("iframe[data-app=admin]"), rec, "admin", "Admin after the change", "settings-admin")
    shot(page, "24-settings-admin-new-password", mask=["iframe[data-app=admin]"])
    rec.save()
    return (f"LITELLM_UI_PASSWORD changed in LiteLLM at once: the new one signs in, the old one is refused; the Admin tab "
            f"still signs in automatically; {msg}")


@check("settings", "settings-owner-email")
def settings_owner_email(ctx):
    need("open-webui")
    _need_helper(ctx)
    page, rec = ctx.page("settings-email")
    login(page)
    fl, f = chat_frame(page)
    title = f"e2e-settings-keep-{int(time.time())}"
    r = owui_api(f, "/api/v1/chats/new", "POST", {"chat": {"title": title, "messages": []}})
    expect(r["status"] == 200, f"new chat {r['status']}")
    me = json.loads(owui_api(f, "/api/v1/auths/")["body"])
    open_settings(page)
    new = f"owner-{int(time.time()) % 100000}@example.com"
    ok, msg = _change(page, "OPENWEBUI_ADMIN_EMAIL", {"input": new}, timeout=300)
    expect(ok, f"owner email change failed: {msg}")
    ENV["OPENWEBUI_ADMIN_EMAIL"] = new
    ENV["LITELLM_UI_USER"] = new
    # a new browser, signed in through the portal: the same account, still admin, with its chat
    page2, rec2 = ctx.page("settings-email-after")
    login(page2)
    fl2, f2 = chat_frame(page2)
    me2 = json.loads(owui_api(f2, "/api/v1/auths/")["body"])
    expect(me2["id"] == me["id"] and me2["email"] == new and me2["role"] == "admin", f"signed in as {me2.get('email')} ({me2.get('role')})")
    chats = json.loads(owui_api(f2, "/api/v1/chats/list")["body"])
    expect(any(c.get("title") == title for c in chats), "the chat made before the change is gone")
    users = json.loads(owui_api(f2, OWUI_USERS + "/all")["body"])["users"]
    expect(not [u for u in users if u.get("role") == "pending"], f"a stray pending account: {[u['email'] for u in users]}")
    from checks_api import lite
    expect(lite("POST", "/v2/login", body={"username": new, "password": ENV["LITELLM_UI_PASSWORD"]}).status == 200,
           "the Admin (LiteLLM) sign-in does not take the new email")
    shot(page2, "25-settings-email-chat-kept")
    rec.save(); rec2.save()
    return f"owner email migrated: same Chat account ({me['id'][:8]}…), still admin, chat kept, no stray account; Admin sign-in = new email; {msg}"


def _cfg_file(lines: list[str], base: str, origin_: str = "local") -> str:
    import base64
    import secrets as sec
    nonce = sec.token_hex(16)
    b64 = lambda v: base64.b64encode(v.encode()).decode()  # noqa: E731
    body = "\n".join(["devos-ade-settings 1", f"nonce {nonce}", f"requested_at {int(time.time())}", f"base {base}",
                      f"origin {origin_}", f"auth {b64(ENV['PORTAL_PASSWORD'])}"] + [f"set {k} {b64(v)}" for k, v in lines] + ["end", ""])
    tmp = STATE / "requests" / f".cfg-{nonce}.tmp"
    tmp.write_text(body, encoding="ascii")
    tmp.chmod(0o640)
    tmp.replace(STATE / "requests" / f"cfg-{nonce}.req")
    return nonce


def _helper_answer(nonce: str, timeout=120) -> dict:
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            st = json.loads((STATE / "status" / "helper-status.json").read_text())
            if st.get("id") == nonce and st.get("phase") in ("done", "failed"):
                return st
        except (OSError, ValueError):
            pass
        time.sleep(1)
    raise AssertionError(f"the helper did not answer request {nonce[:8]}…")


@check("settings", "settings-helper-refusals")
def settings_refusals(ctx):
    d = _need_helper(ctx)
    base = d["snapshot"]["base"]
    # a remote-marked request for the AWS key: only ever from the computer running DevOS ADE
    st = _helper_answer(_cfg_file([("AWS_ACCESS_KEY_ID", "AKIAABCDEFGHIJKLMNOP"), ("AWS_SECRET_ACCESS_KEY", "a" * 40)], base, "remote"))
    expect(st["phase"] == "failed" and "computer running DevOS ADE" in st["message"], f"remote AWS key: {st['message']}")
    time.sleep(2)
    # a request made against an older .env (another change, or an edit by hand, in between)
    st2 = _helper_answer(_cfg_file([("BUDGET_SETUP", "0.04")], "0" * 64))
    expect(st2["phase"] == "failed" and "changed on disk" in st2["message"], f"stale base: {st2['message']}")
    expect(_settings_api(ctx)["snapshot"]["base"] == base, ".env changed after a refused request")
    expect(not list((STATE / "requests").glob("cfg-*")), "a request file was left behind")
    return f"helper refused a remote AWS key ({st['message'][:70]}…) and a stale base ({st2['message'][:60]}…); .env unchanged"


@check("settings", "settings-back-up-now")
def settings_backup(ctx):
    _need_helper(ctx)
    page, rec = ctx.page("settings-backup")
    login(page)
    open_settings(page, "updates")
    page.locator("#set-updates .set-actions .action", has_text="Back up now").click()
    _confirm(page)
    ok, msg = _wait_job(page, 180)
    expect(ok and "Backup written: backups/" in msg and msg.split()[2].rstrip().endswith("-portal"), f"backup: {msg}")
    shot(page, "26-settings-backup", mask=[".set-value", ".set-adv-value"])
    rec.save()
    return msg


def _owui_upload(f, name: str, text: str) -> dict:
    """Uploads a small text file through Open WebUI (its S3 storage is RustFS) and returns its record."""
    return f.evaluate("""async ([n, t]) => { const fd = new FormData(); fd.append('file', new File([t], n, {type: 'text/plain'}));
        const r = await fetch('/api/v1/files/?process=false', {method: 'POST', headers: {Authorization: 'Bearer ' + localStorage.token}, body: fd});
        return {status: r.status, body: await r.text()}; }""", [name, text])


def _owui_download(f, fid: str) -> dict:
    return f.evaluate("""async id => { const r = await fetch('/api/v1/files/' + id + '/content', {headers: {Authorization: 'Bearer ' + localStorage.token}});
        return {status: r.status, body: await r.text()}; }""", fid)


@check("settings", "settings-regenerate-rustfs")
def settings_regen_rustfs(ctx):
    need("open-webui")
    _need_helper(ctx)
    page, rec = ctx.page("settings-regen")
    login(page)
    fl, f = chat_frame(page)
    text = f"kept across a new RustFS key pair {int(time.time())}"
    up = _owui_upload(f, "e2e-regen-before.txt", text)
    expect(up["status"] == 200, f"upload before: {up['status']} {up['body'][:120]}")
    fid = json.loads(up["body"])["id"]
    old_access = page.evaluate("fetch('/api/logins', {headers: {'X-Requested-With': 'devos-ade'}}).then(r => r.json())")["files"]["username"]
    open_settings(page)
    goto_setting(page, "RUSTFS_ACCESS_KEY").locator(".set-actions .action", has_text="Regenerate").click()
    _confirm(page)
    ok, msg = _wait_job(page, 300)
    expect(ok, f"regenerate failed: {msg}")
    page2, rec2 = ctx.page("settings-regen-after")
    login(page2)
    new_logins = page2.evaluate("fetch('/api/logins', {headers: {'X-Requested-With': 'devos-ade'}}).then(r => r.json())")["files"]
    expect(new_logins["username"] != old_access and new_logins["username"].startswith("bn-"), "Home still shows the old Files sign-in")
    ENV["RUSTFS_ACCESS_KEY"], ENV["RUSTFS_SECRET_KEY"] = new_logins["username"], new_logins["password"]
    fl2, f2 = chat_frame(page2)
    got = _owui_download(f2, fid)
    expect(got["status"] == 200 and got["body"] == text, f"the file uploaded before: HTTP {got['status']}")
    up2 = _owui_upload(f2, "e2e-regen-after.txt", "a new upload with the new pair")
    expect(up2["status"] == 200, f"upload after: {up2['status']} {up2['body'][:120]}")
    page2.click(".tab[data-tab=files]")   # Files signs in by itself with the new pair
    sso_signed_in(page2, page2.frame_locator("iframe[data-app=files]"), rec2, "files", "Files after the new pair", "settings-files")
    rec.save(); rec2.save()
    return (f"new RustFS pair ({msg}); a file stored before still downloads, a new Chat upload works, Home shows the new "
            "sign-in, Files still signs in automatically")


def _local_hour_of_helper() -> int:
    """The hour on the computer running the helper (its windows use that clock): from the heartbeat's next update
    window, which starts at AUTO_UPDATE_HOUR local time."""
    # (the helper replaces the file by a rename every few seconds: through Docker Desktop's file sharing a read can
    # miss it for a moment)
    for attempt in range(20):
        try:
            beat = json.loads((STATE / "status" / "helper.json").read_text())
            break
        except (FileNotFoundError, ValueError):
            if attempt == 19:
                raise
            time.sleep(0.5)
    a = beat.get("auto") or {}
    if not isinstance(a.get("next_window"), int) or not isinstance(a.get("hour"), int):
        raise Skip("this helper's heartbeat has no update window to read the local time from")
    offset = (a["hour"] * 3600 - a["next_window"] % 86400) % 86400
    return int(((time.time() + offset) % 86400) // 3600)


@check("settings", "settings-nightly-backup-and-list")
def settings_nightly(ctx):
    _need_helper(ctx)
    page, rec = ctx.page("settings-nightly")
    login(page)
    open_settings(page)
    now_h = _local_hour_of_helper()
    before = {b["name"] for b in _settings_api(ctx)["backups"]["backups"]}
    keys = {k["key"]: k for k in _settings_api(ctx)["snapshot"]["keys"]}
    # a window that includes now but is not the current one (each window gets one backup: an earlier run may have had it)
    cur = keys.get("BACKUP_HOUR", {}).get("value") or "2"
    hour = next(h for h in (now_h, (now_h - 1) % 24, (now_h - 2) % 24) if str(h) != cur)
    # on first: the window and how many to keep show under the switch only while it is on
    sw, on = _switch(goto_setting(page, "BACKUP_NIGHTLY"))
    expect(on or page.locator("#settings .set-row[data-key=BACKUP_HOUR]").is_hidden(), "the backup window shows while nightly backups are off")
    if not on:   # (an earlier, interrupted run may have left it on)
        sw.click()
        _confirm(page)
        ok, msg = _wait_job(page)
        expect(ok, f"BACKUP_NIGHTLY: {msg}")
        # the page reads the settings again after the job: the window's row then belongs to a switch that is on
        page.wait_for_selector("#settings .set-row[data-key=BACKUP_NIGHTLY] [role=switch][aria-checked=true]", state="attached", timeout=30000)
    def new_nightly(secs):
        t0, found = time.time(), []
        while time.time() - t0 < secs and not found:
            found = [b for b in _settings_api(ctx)["backups"]["backups"] if b["kind"] == "nightly" and b["name"] not in before]
            if not found:
                time.sleep(3)
        return found

    def helper_idle(secs=180):   # the helper refuses a change while an action runs ("Another action is still running")
        t0 = time.time()
        while _settings_api(ctx)["helper"]["in_progress"]:
            expect(time.time() - t0 < secs, f"the update helper still busy after {secs} s")
            time.sleep(2)

    nightly = []
    # Turned on inside its own window (BACKUP_HOUR 2 and a run between 2:00 and 5:00), the helper starts that window's
    # backup at once: wait for it, and move the window only when it had its backup already (a reused throwaway)
    if cur.isdigit() and now_h in {(int(cur) + i) % 24 for i in range(3)}:
        nightly = new_nightly(180)
    at = int(cur) if nightly else hour   # (the window the backup came from)
    if not nightly and cur != str(hour):
        helper_idle()
        goto_setting(page, "BACKUP_HOUR").locator("select").first.select_option(str(hour))
        _confirm(page)
        ok, msg = _wait_job(page)
        expect(ok, f"BACKUP_HOUR: {msg}")
    nightly = nightly or new_nightly(180)
    expect(nightly, "no nightly backup within 3 minutes of turning it on in its window")
    helper_idle()   # (the backup is listed before its action ends)
    goto_setting(page, "updates")
    # Reload reads /api/settings again and then draws the page anew: wait for that, so nothing below holds a row of the
    # page it replaces
    page.click("#set-reload")
    settings_drawn(page)
    page.wait_for_selector(f"#settings .set-backups td:text-is('{nightly[0]['name']}')", timeout=20000)
    kinds = page.inner_text("#settings .set-backups")
    expect("nightly" in kinds, f"backup list: {kinds[:200]}")
    if not CHECKS_RE:   # (in a full run, the Back up now check made one before this one)
        expect("Back up now" in kinds, f"backup list: {kinds[:200]}")
    page.locator("#settings .set-row[data-key=BACKUP_NIGHTLY]").scroll_into_view_if_needed()
    shot(page, "26b-settings-backup-list", mask=[".set-value", ".set-adv-value"])
    sw, on = _switch(goto_setting(page, "BACKUP_NIGHTLY"))
    expect(on, "nightly backups do not show as on")
    sw.click()
    _confirm(page)
    ok, msg = _wait_job(page)
    expect(ok, f"BACKUP_NIGHTLY off: {msg}")
    rec.save()
    return f"nightly backups on at {at:02d}:00 (local) → {nightly[0]['name']} ({nightly[0]['bytes']} bytes) in the list with Back up now's"


@check("settings", "settings-portal-password")
def settings_portal_password(ctx):
    _need_helper(ctx)
    # another device signed in before the change (a raw HTTP session: ctx.page closes earlier browser contexts)
    old_cookie = ctx.session().split("=", 1)[1]
    page, rec = ctx.page("settings-portal-pw")
    login(page)
    open_settings(page)
    new = f"e2e-new-portal-pw-{int(time.time()) % 100000}"
    ok, msg = _change(page, "PORTAL_PASSWORD", {"input[id$=-a]": new, "input[id$=-b]": new}, timeout=240)
    expect(ok, f"portal password change failed: {msg}")
    ENV["PORTAL_PASSWORD"] = new
    ctx.reset_session()
    # this browser stays signed in (carry-over cookie, swapped for a normal session)
    shot(page, "27a-settings-portal-password-saved", mask=[".set-value", ".set-adv-value"])
    page.goto(origin() + "/#home")
    page.wait_for_url(HOME_URL, timeout=20000)
    page.locator("#updated", has_text="Updated").wait_for(timeout=20000)
    names = {c["name"] for c in page.context.cookies()}
    expect("bn_session" in names and "bn_session_next" not in names, f"cookies after the change: {names}")
    from common import http
    r = http("GET", None, "/api/summary", {"X-Requested-With": "devos-ade"}, cookie=f"bn_session={old_cookie}")
    expect(r.status == 401, f"the other device is still signed in (HTTP {r.status})")
    expect(ctx.session(), "cannot sign in with the new password")
    shot(page, "27-settings-portal-password-kept", mask=[".set-value", ".set-adv-value", ".cred"])
    rec.save()
    return f"PORTAL_PASSWORD changed: this browser stays signed in, another device's session is refused; {msg}"


# --- sign out (last: it revokes every session) ---

@check("final", "sign-out-all-hosts")
def sign_out(ctx):
    import base64
    from checks_api import lite
    page, rec = ctx.page("sign-out")
    login(page)
    page.click(".tab[data-tab=chat]")
    frame_of(page, "chat")
    # Admin and Files opened (signed in by the portal) before signing out
    page.click(".tab[data-tab=admin]")
    page.frame_locator("iframe[data-app=admin]").locator(SSO_DONE["admin"]).first.wait_for(timeout=45000)
    page.click(".tab[data-tab=files]")
    page.frame_locator("iframe[data-app=files]").locator(SSO_DONE["files"]).first.wait_for(timeout=45000)
    tok = [c["value"] for c in page.context.cookies(origin("admin")) if c["name"] == "token"]
    expect(tok, "no LiteLLM session from the automatic sign-in")
    body = tok[0].split(".")[1]
    ui_key = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))["key"]
    expect(lite("GET", "/key/info", key=ui_key).status == 200, "the Admin session's key does not work before Sign out")
    # and a UI session from LiteLLM's own sign-in (its API here) ends too
    r = lite("POST", "/v2/login", body={"username": ENV["LITELLM_UI_USER"], "password": ENV["LITELLM_UI_PASSWORD"]})
    body = r.json()["token"].split(".")[1]
    form_key = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))["key"]
    expect(lite("GET", "/key/info", key=form_key).status == 200, "LiteLLM's own session does not work before Sign out")
    page.click(".tab[data-tab=chat]")
    page.click(".sidebar .logout button")
    page.wait_for_url(re.compile(r"/login$"))
    bad = []
    for sub, path in ((None, "/"), ("chat", "/"), ("admin", "/ui/"), ("files", "/rustfs/console/")):
        page.goto(origin(sub) + path)
        if "/login" not in page.url or not page.url.startswith(origin()):
            bad.append(f"{sub or 'portal'} → {page.url}")
    expect(not bad, "still reachable after Sign out: " + ", ".join(bad))
    t0, st, st2 = time.time(), 0, 0
    while time.time() - t0 < 20 and 200 in ((st := lite("GET", "/key/info", key=ui_key).status),
                                            (st2 := lite("GET", "/key/info", key=form_key).status)):
        time.sleep(1)
    expect(st in (401, 403), f"the Admin session's LiteLLM key still works after Sign out (HTTP {st})")
    expect(st2 in (401, 403), f"LiteLLM's own UI session still works after Sign out (HTTP {st2})")
    shot(page, "16-signed-out")
    rec.save()
    ctx.reset_session()
    return ("Sign out → login; portal, chat, admin and files (opened and signed in before) all send the browser back to "
            f"the login; every Admin session is revoked in LiteLLM, the portal's and LiteLLM's own (HTTP {st}, {st2})")

