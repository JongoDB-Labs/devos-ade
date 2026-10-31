"""The optional Code page (./stack code): it needs the terminal (its sandbox); its host needs the session AND a fresh
password unlock of its own (bn_code: a terminal unlock never opens it; it opens the terminal only through the
single-use hand-off), refuses other sites' Origins (and state changes without one), stays off remotely unless
REMOTE_TERMINAL=true and it has a remote name; the portal answers its models (this stack's prices) and a session's
spend (LiteLLM's logs, the terminal key's rows only), and offers the Code tab only while it is on."""

import hashlib
import html
import json
import os
import re
from dataclasses import replace
from pathlib import Path

import httpx
import pytest
from starlette.testclient import TestClient

from portal import code as codepage
from portal.app import STATIC, create_app
from portal.config import from_env
from portal.security import COOKIE, CODE_COOKIE, REMOTE_CODE_COOKIE, TERMINAL_COOKIE, Handoff, TerminalUnlocks, Sessions, safe_next

SECRET = "s" * 64
PW = "correct horse"
PORTAL = "http://devos-ade.localhost"
CODE_HOST = "code.devos-ade.localhost"
CODE = f"http://{CODE_HOST}"
TERM_HOST = "terminal.devos-ade.localhost"
NAV = {"Accept": "text/html,application/xhtml+xml", "X-Forwarded-Method": "GET", "X-Forwarded-Host": CODE_HOST, "X-Forwarded-Uri": "/"}
API = {"X-Forwarded-Method": "GET", "X-Forwarded-Host": CODE_HOST, "X-Forwarded-Uri": "/api/state"}
WS = {"X-Forwarded-Method": "GET", "X-Forwarded-Host": CODE_HOST, "X-Forwarded-Uri": "/ws", "Origin": CODE}
VERIFY = "/auth/verify?app=code"
TN = "tail1234.ts.net"
R_PORTAL, R_CODE_HOST = f"bn.{TN}", f"bn-code.{TN}"
PROXY = "p" * 64
REMOTE = {"X-Portal-Remote": "1", "X-Portal-Proxy": PROXY, "Tailscale-User-Login": "me@example.com"}
SID = "3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8"
TERM_KEY = "sk-terminal-key"


def offline(request):
    raise httpx.ConnectError("offline in tests")


@pytest.fixture
def cs(settings):
    return replace(settings, terminal=True, code=True,
                   keys=settings.keys + (("claude-code-terminal", "Terminal (browser)", TERM_KEY),))


def _client(s, transport=None, base=PORTAL):
    return TestClient(create_app(s, transport=transport or httpx.MockTransport(offline)), base_url=base, follow_redirects=False)


@pytest.fixture
def cc(cs):
    with _client(cs) as c:
        yield c


def _cookie(resp, name):
    return next((c for c in resp.headers.get_list("set-cookie") if c.startswith(name + "=")), None)


def session(c):
    r = c.post("/login", data={"password": PW, "next": "/"}, headers={"Origin": PORTAL})
    assert r.status_code == 303, r.text
    c.cookies.clear()
    return _cookie(r, COOKIE).split(";", 1)[0].split("=", 1)[1]


def unlock(c, tok, password=PW, origin=CODE, host=CODE_HOST, headers=None):
    r = c.post("/auth/code-unlock", data={"password": password},
               headers={"Host": host, "Origin": origin, "Cookie": f"{COOKIE}={tok}", **(headers or {})})
    c.cookies.clear()
    return r


def unlocked(c):
    tok = session(c)
    r = unlock(c, tok)
    assert r.status_code == 303, r.text
    return tok, _cookie(r, CODE_COOKIE).split(";", 1)[0].split("=", 1)[1]


def verify(c, cookies, headers=NAV):
    return c.get(VERIFY, headers={**headers, "Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items())})


# --- settings ---

def test_code_needs_the_terminal_and_has_its_own_host():
    base = {"PORTAL_PASSWORD": "pw", "PORTAL_SECRET": "x" * 40, "PORTAL_HOST": "bn.localhost", "PORTAL_PORT": "8800"}
    assert not from_env({**base, "CODE_ENABLED": "true"}).code_on()       # no terminal: no Code page
    s = from_env({**base, "CODE_ENABLED": "true", "TERMINAL_ENABLED": "true"})
    assert s.code_on() and s.app_urls()["code"] == "http://code.bn.localhost:8800/"
    assert "http://code.bn.localhost:8800" in s.app_origins()
    assert from_env({**base, "TERMINAL_ENABLED": "true", "CODE_ENABLED": "true", "CODE_HOST": "IDE.localhost"}).origin("code") == "http://ide.localhost:8800"
    off = from_env({**base, "TERMINAL_ENABLED": "true"})
    assert not off.code_on() and "code" not in off.app_urls()


def test_remote_code_needs_the_terminals_switch_and_its_name():
    base = {"PORTAL_PASSWORD": "pw", "PORTAL_SECRET": "x" * 40, "REMOTE_MODE": "tailscale", "REMOTE_HOST": R_PORTAL,
            "TERMINAL_ENABLED": "true", "REMOTE_TERMINAL_HOST": f"bn-terminal.{TN}", "CODE_ENABLED": "true", "REMOTE_CODE_HOST": R_CODE_HOST}
    assert not from_env(base).code_on(remote=True)
    on = from_env({**base, "REMOTE_TERMINAL": "true"})
    assert on.code_on(remote=True) and on.app_urls(remote=True)["code"] == f"https://{R_CODE_HOST}/"
    assert not from_env({**base, "REMOTE_TERMINAL": "true", "REMOTE_CODE_HOST": ""}).code_on(remote=True)
    assert not from_env({**base, "REMOTE_TERMINAL": "true", "REMOTE_TERMINAL_HOST": ""}).code_on(remote=True)


def test_login_may_return_to_the_code_host_only_while_it_is_on(settings, cs):
    assert safe_next(f"{CODE}/", cs) == f"{CODE}/"
    assert safe_next(f"{CODE}/", settings) == "/"


def _meta(page, name):
    m = re.search(rf'<meta name="{name}" content="([^"]*)">', page)
    return json.loads(html.unescape(m.group(1)))


def test_code_page_is_framed_only_when_on(settings, cs):
    # (the tab is always there: code.js — while off, a page of the portal's own with no frame; the code host is offered
    # only while the Code page is on here)
    for s, want in ((settings, False), (replace(settings, terminal=True), False), (cs, True)):
        with _client(s) as c:
            tok = session(c)
            r = c.get("/", headers={"Cookie": f"{COOKIE}={tok}"})
            assert ("code" in _meta(r.text, "bn-apps")) is want
            assert _meta(r.text, "bn-code") == {"enabled": s.code, "here": want}
            assert 'src="/static/code.js"' in r.text
            assert (CODE in r.headers["content-security-policy"]) is want   # frame-src: the Code tab's frame
            summary = c.get("/api/summary", headers={"Cookie": f"{COOKIE}={tok}", "X-Requested-With": "devos-ade"}).json()
            assert summary["code"] == {"enabled": s.code, "here": want, "notice": None} and ("code" in summary["apps"]) is want


def test_code_tab_sits_under_chat_and_in_the_phones_tab_bar():
    js = open("portal/static/code.js", encoding="utf-8").read()
    assert '.tabs .tab[data-tab=chat]' in js and "after.after(" in js
    assert "e.origin !== codeOrigin" in js
    # a phone: a tab of the bottom bar (Home · Chat · Code · More), framed like Chat — never a new tab from More
    assert "#more-sheet" not in js and "window.open(" not in js and "addSheetLink" not in js
    mobile = open("portal/static/mobile.js", encoding="utf-8").read()
    assert '"code"' not in mobile.split("DESKTOP_ONLY", 1)[1].split("\n", 1)[0]
    assert 'defaultTab: () => "home",' in mobile
    css = open("portal/static/mobile.css", encoding="utf-8").read()
    phone = css[css.index("/* ---------- Phones ---------- */"):]
    hidden = phone[phone.index(".tabs li:has("):].split("\n", 1)[0]
    assert ".code-item" not in hidden and ".terminal-item" in hidden and "grid-auto-flow: column" in phone
    assert ".tabs .tab-badge" in phone and ".tabs .tab-off" in phone
    assert "innerHTML" not in js


def test_code_tab_is_always_there_and_explains_itself_while_off():
    js = open("portal/static/code.js", encoding="utf-8").read()
    app = open("portal/static/app.js", encoding="utf-8").read()
    mobile = open("portal/static/mobile.js", encoding="utf-8").read()
    # the tab whatever the state (on a phone too: a tab of the bottom bar); the frame, its badge, the preload and the
    # code host only while on
    tail = js[js.rindex("\n  addTab();\n"):]
    assert tail.startswith("\n  addTab();\n")
    assert "if (here) { listen(); routes(); window.addEventListener(\"load\", preload, { once: true }); } else offPage();" in tail
    add = js[js.index("function addTab()"):js.index("// --- deep links into the Code page ---")]
    off = add[add.index("if (!here) {"):]
    off = off[:off.index("return;")]
    assert 'class: "code-item off"' in off and 'class: "tab-off", text: "off"' in off and '"data-label": "Code (off)"' in off
    assert "appUrl(" not in off and "badge" not in off and "popout" not in off
    # while off, "code" is a page of the portal (app.js PAGES: a section of that id, no frame), on a phone too
    page = js[js.index("function offPage()"):js.index("// The folder Claude would see")]
    assert 'PAGES.push("code")' in page and 'id: "code"' in page and "appUrl(" not in page and "appFrame(" not in page
    for words in ("Turn on in Settings", "on the computer running DevOS ADE", './stack code enable', "./stack code enable --workspace DIR",
                  'code("~/devos-ade-workspace"), ", or ", code("~/bedrock-now-workspace"),', '" on an install that already has it"',
                  "its own key and budget", "Manual mode", "Bypass permissions and Auto mode stay off",
                  "portal password again", "TERMINAL_EGRESS=off", "public internet addresses only", "not this computer's own services",
                  "Sandbox internet access", "reload this page", "REMOTE_TERMINAL=true", "./stack up",
                  "off for remote access"):
        assert words in page, words
    assert "turnOn.addEventListener(\"click\", toSettings)" in page
    # Settings, at the Code page's switch: its address (#settings/CODE_ENABLED: settings.js goTo)
    go = js[js.index("function toSettings()"):js.index("const settingsLink")]
    assert "location.hash = SWITCH" in go and 'const SWITCH = "#settings/CODE_ENABLED";' in js
    # the folder as Settings names it, asked from the portal's own API when the page shows (never the code host)
    fill = js[js.index("async function fillFolder()"):js.index("// Home's \"Claude Code in your terminal\" card")]
    assert 'api("/api/settings")' in fill and "TERMINAL_WORKSPACE" in fill and "code_workspace" in fill and "textContent" in fill
    assert "const PAGES = [\"home\", \"settings\", \"modelbrowser\"];" in app
    assert "for (const p of PAGES) { const s = document.getElementById(p); if (s) s.hidden = tab !== p; }" in app
    # (in the icon rail its tooltip: "Code (off)"; a tab's name is its own words, never its badge's count)
    assert "!PAGES.includes(tab) ? \"chat\" : tab" in mobile and "b.dataset.label || ownText(b)" in mobile
    assert "filter((n) => n.nodeType === 3)" in mobile
    css = open("portal/static/app.css", encoding="utf-8").read()
    assert ".code-item.off .tab svg" in css and ".tab-off" in css and ".code-off-page" in css
    assert "innerHTML" not in js


def test_a_greyed_item_of_the_code_page_opens_settings_from_the_code_tabs_own_frame_only():
    # (catalog/setup-links.tsv: the Code page's {type: "bn-code-setup", place} — Settings at that place, nothing else)
    js = open("portal/static/code.js", encoding="utf-8").read()
    handler = js.split('e.data.type !== "bn-code-setup") return;', 1)
    assert len(handler) == 2
    check = handler[0].rsplit('window.addEventListener("message", (e) => {', 1)[1]
    assert "e.origin !== codeOrigin" in check and "e.source !== f.contentWindow" in check
    body = handler[1].split("});", 1)[0]
    # (a reason the portal knows, its place from the portal's own list — never one the frame names — and the portal's
    # own address for it: the hash of its Settings place, never a URL)
    assert 'if (typeof reason !== "string" || !Object.hasOwn(CODE_SETUP, reason)) return;' in body
    assert "e.data.place" not in js and "const hash = `#settings/${CODE_SETUP[reason]}`;" in body
    assert body.count("location.hash = hash") == 1 and "location.href" not in body and "assign(" not in body
    # the list: each reason's place as catalog/setup-links.tsv has it
    table = Path(os.environ.get("BN_REPO_DIR") or Path(__file__).resolve().parents[2]) / "catalog" / "setup-links.tsv"
    lst = dict(re.findall(r'"([a-z-]+)": "([A-Z][A-Z0-9_]+|\+[a-z-]+)"', js.split("const CODE_SETUP = Object.freeze({", 1)[1].split("});", 1)[0]))
    assert len(lst) >= 8
    if table.exists():
        rows = {l.split("\t")[0]: l.split("\t")[1] for l in table.read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")}
        assert {r: f"setting:{p}" for r, p in lst.items()} == {r: rows[r] for r in lst}, lst
        # every reason the Code page can send (any of the table's reasons its sources name — a SetupReason is always
        # written out somewhere: a greyed item's, a link's, a harness status's) whose place is a Settings row is in
        # the list: none is dropped by the portal on its way
        code = table.parent.parent / "code"
        if code.is_dir():
            sent = set()
            for f in code.rglob("*"):
                if f.suffix not in (".ts", ".tsx", ".mjs", ".js") or "node_modules" in f.parts or "test" in f.parts or "dist" in f.parts or f.name == "setuplinks.ts":
                    continue
                text = f.read_text(encoding="utf-8", errors="replace")
                sent |= {r for r in rows if re.search(r"""['"`]%s['"`]""" % re.escape(r), text)}
            wanted = {r for r in sent if rows[r].startswith("setting:")}
            assert len(wanted) >= 8 and wanted <= set(lst), sorted(wanted - set(lst))


def test_code_tabs_frame_is_made_when_idle_for_its_badge_on_phones_too():
    js = open("portal/static/code.js", encoding="utf-8").read()
    app = open("portal/static/app.js", encoding="utf-8").read()
    # one way to make an app's frame (hidden until its tab shows it): the tab and the idle preload share it
    assert "function appFrame(tab)" in app and "f.hidden = true;" in app and 'appFrame(tab).hidden = false' in app
    pre = js.split("function preload()", 1)[1].split("\n  }\n", 1)[0]
    # only in a browser that has used the Code page — on a phone too (the tab bar's badge, the needs-you banner)
    assert "if (!used()) return;" in pre and "767" not in pre
    # "used": set when the code host's own page reports (after the origin check), kept in localStorage
    handler = js.split('window.addEventListener("message", (e) => {', 1)[1].split("});", 1)[0]
    check, rest = handler.split("return;", 1)
    assert "e.origin !== codeOrigin" in check and rest.lstrip().startswith("markUsed();")
    # only the Code tab's own frame (the one appFrame("code") makes), not just any window of the code host
    assert "e.source !== f.contentWindow" in check and '#frames iframe[data-app="code"]' in js
    assert 'const USED = "bn.code.used";' in js and 'localStorage.getItem(USED) === "1"' in js and 'localStorage.setItem(USED, "1")' in js
    # a session in Bypass permissions: the badge turns red with the CLI's marker (text only)
    assert 'badge.classList.toggle("bypass", bypass);' in rest and 'bypass ? "⏵⏵" : ""' in rest and "e.data.bypass === true" in rest
    assert ".tab-badge.bypass" in open("portal/static/app.css", encoding="utf-8").read()
    assert "requestIdleCallback(make" in pre and 'appFrame("code")' in pre
    assert 'window.addEventListener("load", preload, { once: true })' in js.rsplit("if (here) {", 1)[1].split("\n", 1)[0]


def test_the_code_tab_on_a_phone_lands_on_the_session_that_waits_and_a_session_opens_in_place():
    js = open("portal/static/code.js", encoding="utf-8").read()
    app = open("portal/static/app.js", encoding="utf-8").read()
    routes = js[js.index("function routes()"):js.index("// --- the Code tab while the Code page is off here")]
    # shown again on a phone, once the page runs: told so, to the code host's origin only (it shows the session that
    # waits for you, its card in view: code/web app.ts showWaiting); nothing else is sent
    shown = routes[routes.index('document.addEventListener("bn:tab"'):routes.index('document.addEventListener("bn:place"')]
    assert 'e.detail !== "code"' in shown and '"(max-width: 767.98px)"' in shown and "window.bnCode.ready()" in shown
    assert 'postMessage({ type: "bn-portal-shown" }, origin)' in shown and "\"*\"" not in js
    # the portal's #code/<session id> (a notification's address): app.js hands the place on, code.js takes a session id only
    assert 'new CustomEvent("bn:place", { detail: { tab, place: place.join("/") } })' in app
    place = routes[routes.index('document.addEventListener("bn:place"'):]
    assert 'd.tab === "code"' in place and "UUID.test(d.place)" in place and "openLink({ session: d.place })" in place
    # a session in place (no reload, no unlock again) once the page runs; else its deep link through the frame
    link = js[js.index("function openLink(params)"):js.index("// the framed page's Git hosts uses")]
    assert 'postMessage({ type: "bn-portal-session", id: params.session }, new URL(appUrl("code")).origin)' in link
    assert "UUID.test(params.session)" in link and 'appFrame("code").src = linkTo(params);' in link and "window.open" not in link


# --- /auth/verify?app=code ---

def test_code_host_is_404_while_off(settings):
    with _client(replace(settings, terminal=True)) as c:
        r = verify(c, {COOKIE: session(c)})
        assert r.status_code == 404 and "./stack code enable" in r.text


def test_without_a_session_the_login(cc):
    r = verify(cc, {})
    assert r.status_code == 302 and r.headers["location"].startswith(f"{PORTAL}/login?next=http%3A%2F%2Fcode.")
    assert verify(cc, {}, API).status_code == 401


def test_a_session_alone_shows_the_code_pages_unlock_form(cc):
    tok = session(cc)
    r = verify(cc, {COOKIE: tok})
    assert r.status_code == 401 and "Unlock the Code page" in r.text and 'action="/.bn/unlock"' in r.text
    csp = r.headers["content-security-policy"]
    assert f"frame-ancestors {PORTAL}" in csp and "default-src 'none'" in csp
    r = verify(cc, {COOKIE: tok}, API)
    assert r.status_code == 401 and "Code page locked" in r.text


def test_session_and_unlock_open_it_and_the_websocket(cc):
    tok, ut = unlocked(cc)
    for h in (NAV, API, WS):
        r = verify(cc, {COOKIE: tok, CODE_COOKIE: ut}, h)
        assert r.status_code == 200 and r.headers["x-portal-user"] == "admin@example.com"
    assert verify(cc, {CODE_COOKIE: ut}, API).status_code == 401   # never instead of the session


def test_the_terminals_unlock_never_opens_the_code_page_and_back(cc):
    tok = session(cc)
    # a terminal unlock issued by this very portal, under the code cookie's name: refused (another salt)
    term = cc.post("/auth/terminal-unlock", data={"password": PW},
                   headers={"Host": TERM_HOST, "Origin": f"http://{TERM_HOST}", "Cookie": f"{COOKIE}={tok}"})
    cc.cookies.clear()
    tt = _cookie(term, TERMINAL_COOKIE).split(";", 1)[0].split("=", 1)[1]
    assert verify(cc, {COOKIE: tok, CODE_COOKIE: tt}, API).status_code == 401
    _, ct = unlocked(cc)
    r = cc.get("/auth/verify?app=terminal", headers={"X-Forwarded-Method": "GET", "X-Forwarded-Host": TERM_HOST, "X-Forwarded-Uri": "/",
                                                    "Cookie": f"{COOKIE}={tok}; {TERMINAL_COOKIE}={ct}"})
    assert r.status_code == 401


def test_other_sites_origins_and_bare_state_changes_are_refused(cc):
    tok, ut = unlocked(cc)
    jar = {COOKIE: tok, CODE_COOKIE: ut}
    for origin in ("http://evil.example", PORTAL, f"http://{TERM_HOST}", "null", f"{CODE}:8080"):
        assert verify(cc, jar, {**WS, "Origin": origin}).status_code == 403, origin
        assert verify(cc, jar, {**API, "Origin": origin}).status_code == 403, origin
    ws = dict(WS); del ws["Origin"]
    assert verify(cc, jar, ws).status_code == 403          # a WebSocket without an Origin
    for m in ("POST", "PUT", "DELETE"):                     # a change without one
        assert verify(cc, jar, {**API, "X-Forwarded-Method": m}).status_code == 403, m
        assert verify(cc, jar, {**API, "X-Forwarded-Method": m, "Origin": CODE}).status_code == 200, m
    assert verify(cc, jar, API).status_code == 200          # a GET without one (fetch sends none for same-origin GETs)


def test_unlock_checks_host_origin_session_and_password(cc):
    tok = session(cc)
    assert unlock(cc, tok, origin="http://evil.example").status_code == 403
    # only on the code host itself (the terminal host has its own form, /auth/terminal-unlock)
    assert unlock(cc, tok, host=TERM_HOST, origin=f"http://{TERM_HOST}").status_code == 404
    assert unlock(cc, tok, host="chat.devos-ade.localhost").status_code == 404
    r = unlock(cc, tok, password="wrong")
    assert r.status_code == 401 and "not right" in r.text and "Unlock the Code page" in r.text
    r = cc.post("/auth/code-unlock", data={"password": PW}, headers={"Host": CODE_HOST, "Origin": CODE})
    assert r.status_code == 302 and "/login" in r.headers["location"]
    r = unlock(cc, tok)
    c = _cookie(r, CODE_COOKIE)
    assert r.status_code == 303 and r.headers["location"] == "/"
    assert "HttpOnly" in c and "SameSite=strict" in c and "Domain" not in c and "Max-Age=43200" in c


# --- deep links (?session, ?prompt): kept through the unlock form, rebuilt from what checks out ---

def test_deep_links_are_rebuilt_from_what_checks_out():
    dl = codepage.deep_link
    assert dl(f"/?session={SID}") == f"/?session={SID}"
    assert dl(f"/?session={SID.upper()}&prompt=fix+the+bug") == f"/?session={SID}&prompt=fix+the+bug"
    assert dl("/?prompt=%3Cimg%20src%3Dx%3E%0Anext") == "/?prompt=%3Cimg+src%3Dx%3E%0Anext"
    assert dl("/?other=1&prompt=hi") == "/?prompt=hi"                     # unknown parameters dropped
    assert dl("/?prompt=a&prompt=b") == "/?prompt=a"                      # once each
    # the Git panel's dialogs (Settings › Claude Code › Git hosts, Activity, the walkthrough): hosts or clone, nothing else
    assert dl("/?git=hosts") == "/?git=hosts" and dl("/?git=clone") == "/?git=clone"
    assert dl("/?git=clone&git=hosts") == "/?git=clone"
    for bad in ("/?git=", "/?git=push", "/?git=HOSTS", "/?git=hosts%00", "/?git=../x"):
        assert dl(bad) is None, bad
    assert dl("/?git=clone&url=https://evil.example/x.git") == "/?git=clone"   # (no URL travels with it)
    # Home's New session: a new session's start, in a project of the page's list (its id's shape only)
    assert dl("/?new=1&project=p_0000aaaa") == "/?new=1&project=p_0000aaaa" and dl("/?project=ws") == "/?project=ws"
    for bad in ("/?new=0", "/?new=yes", "/?project=../etc", "/?project=p_XYZ", "/?project=p_0000aaaa0"):
        assert dl(bad) is None, bad
    for bad in (None, "", "/", "/api/state?session=x", "//evil.example/?prompt=x", "/x?prompt=a", "?prompt=a", "/?session=../../etc",
                "/?prompt=", "/?prompt=a%00b", "/?" + "a=1&" * 20, "/?prompt=" + "a" * 70000):
        assert dl(bad) is None, bad
    long = dl("/?prompt=" + "a" * 5000)
    assert long == "/?prompt=" + "a" * 4000                              # capped as the page caps it
    huge = dl(f"/?session={SID}&prompt=" + "%E2%80%AE" * 3000)           # too long once encoded: the session stays
    assert huge == f"/?session={SID}"
    assert dl("/?prompt=" + "%E2%80%AE" * 3000) is None


def test_the_unlock_form_carries_a_deep_link_and_unlocking_goes_there(cc):
    tok = session(cc)
    r = verify(cc, {COOKIE: tok}, {**NAV, "X-Forwarded-Uri": f"/?session={SID}&prompt=%22%3E%3Cscript%3Ex%3C%2Fscript%3E&evil=1"})
    assert r.status_code == 401
    m = re.search(r'<input type="hidden" name="next" value="([^"]*)">', r.text)
    assert m, r.text
    assert "<script>" not in r.text and m.group(1) == f"/?session={SID}&amp;prompt=%22%3E%3Cscript%3Ex%3C%2Fscript%3E"
    # the form posts it back: the redirect goes there (rebuilt, never as posted)
    r = cc.post("/auth/code-unlock", data={"password": PW, "next": f"/?session={SID}&prompt=hi%0Athere"},
                headers={"Host": CODE_HOST, "Origin": CODE, "Cookie": f"{COOKIE}={tok}"})
    cc.cookies.clear()
    assert r.status_code == 303 and r.headers["location"] == f"/?session={SID}&prompt=hi%0Athere"
    r = cc.post("/auth/code-unlock", data={"password": PW, "next": "/?git=hosts"}, headers={"Host": CODE_HOST, "Origin": CODE, "Cookie": f"{COOKIE}={tok}"})
    cc.cookies.clear()
    assert r.status_code == 303 and r.headers["location"] == "/?git=hosts"   # (Open Git hosts on a locked Code page)
    for bad in ("https://evil.example/?prompt=x", "//evil.example/?session=" + SID, "/\\evil.example", "/api/sessions?x=1", "javascript:alert(1)"):
        r = cc.post("/auth/code-unlock", data={"password": PW, "next": bad}, headers={"Host": CODE_HOST, "Origin": CODE, "Cookie": f"{COOKIE}={tok}"})
        cc.cookies.clear()
        assert r.status_code == 303 and r.headers["location"] == "/", bad
    # a wrong password keeps it in the form; a page without a deep link has none
    r = cc.post("/auth/code-unlock", data={"password": "wrong", "next": "/?prompt=hi"}, headers={"Host": CODE_HOST, "Origin": CODE, "Cookie": f"{COOKIE}={tok}"})
    cc.cookies.clear()
    assert 'name="next" value="/?prompt=hi"' in r.text
    assert 'name="next"' not in verify(cc, {COOKIE: tok}).text
    # too many form fields: no deep link, still a normal answer
    r = cc.post("/auth/code-unlock", data={"password": "wrong", **{f"f{i}": "x" for i in range(9)}}, headers={"Host": CODE_HOST, "Origin": CODE, "Cookie": f"{COOKIE}={tok}"})
    cc.cookies.clear()
    assert r.status_code == 401


def test_the_terminals_unlock_form_carries_no_deep_link(cs):
    with _client(cs) as c:
        tok = session(c)
        r = c.get("/auth/verify?app=terminal", headers={"Accept": "text/html", "X-Forwarded-Method": "GET", "X-Forwarded-Host": TERM_HOST,
                                                        "X-Forwarded-Uri": f"/?session={SID}", "Cookie": f"{COOKIE}={tok}"})
        assert r.status_code == 401 and 'name="next"' not in r.text and "{{next}}" not in r.text


def test_what_the_code_page_reports_is_checked_and_shown_as_text():
    # code.js takes the framed page's report (its origin, its frame), checked; Home's Continue row (home.js) shows it,
    # and what the portal kept of the page's own report (/api/continue), as text
    js = (STATIC / "code.js").read_text(encoding="utf-8")
    links = js[js.index("// --- deep links into the Code page ---"):js.index("function listen()")]
    for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"):
        assert sink not in js, sink
    assert "UUID.test(x.id)" in links and ".slice(0, 120)" in links and ".slice(0, 8)" in links
    assert 'u.searchParams.set(k, v)' in links and "openLink({ session: id })" in js and 'openLink({ new: "1", project:' in js
    # titles: invisible and direction-changing characters shown as ⟨U+…⟩, as the Code page shows them
    assert "title: typeof x.title === \"string\" ? shownTitle(x.title)" in links
    for f in ("code.js", "home.js"):
        src = (STATIC / f).read_text(encoding="utf-8")
        inv = src.split("const INVISIBLE = ", 1)[1].split("\n", 1)[0]
        for c in ("\\u202a-\\u202e", "\\u2066-\\u2069", "\\u200b-\\u200f", "\\ufeff", "\\u{e0000}-\\u{e007f}", "\\u0000-\\u001f", "\\u007f-\\u009f"):
            assert c in inv or c.replace("\\u202a-", "\\u2028-") in inv, (f, c)
        assert inv.endswith("/gu;") and "`⟨U+${c.codePointAt(0).toString(16).toUpperCase().padStart(4, \"0\")}⟩`" in src, f
    assert "e.origin !== codeOrigin" in js   # only the code host's page may report
    home = (STATIC / "home.js").read_text(encoding="utf-8")
    assert 'api("/api/continue")' in home and 'document.addEventListener("bn:code-status"' in home
    assert "UUID.test(s.id)" in home and "UUID.test(c.id)" in home
    app = (STATIC / "app.js").read_text(encoding="utf-8")
    assert 'new CustomEvent("bn:summary", { detail: d })' in app


def test_unlock_is_off_while_the_code_page_is(settings):
    with _client(replace(settings, terminal=True)) as c:
        assert unlock(c, session(c)).status_code == 404


def test_sign_out_locks_it_again(cc):
    tok, ut = unlocked(cc)
    assert verify(cc, {COOKIE: tok, CODE_COOKIE: ut}, API).status_code == 200
    cc.post("/logout", headers={"Origin": PORTAL, "Cookie": f"{COOKIE}={tok}"})
    tok2 = session(cc)
    assert verify(cc, {COOKIE: tok2, CODE_COOKIE: ut}, API).status_code == 401


def test_remote_off_unless_shared_and_its_own_cookie_there(settings):
    rs = replace(settings, terminal=True, code=True, remote_mode="tailscale", remote_host=R_PORTAL, proxy_secret=PROXY,
                 remote_app_hosts={"terminal": f"bn-terminal.{TN}"}, remote_terminal=True)
    with _client(rs) as c:
        r = c.get(VERIFY, headers={**API, **REMOTE, "X-Forwarded-Host": R_CODE_HOST})
        assert r.status_code == 403 and "REMOTE_TERMINAL" in r.text
    on = replace(rs, remote_app_hosts={"terminal": f"bn-terminal.{TN}", "code": R_CODE_HOST})
    with _client(on) as c:
        r = c.post("/login", data={"password": PW, "next": "/"}, headers={"Origin": f"https://{R_PORTAL}", "Host": R_PORTAL, **REMOTE})
        tok = _cookie(r, "__Host-bn_session").split(";", 1)[0].split("=", 1)[1]
        c.cookies.clear()
        r = c.post("/auth/code-unlock", data={"password": PW}, headers={"Host": R_CODE_HOST, "Origin": f"https://{R_CODE_HOST}",
                                                                      "Cookie": f"__Host-bn_session={tok}", **REMOTE})
        c.cookies.clear()
        ck = _cookie(r, REMOTE_CODE_COOKIE)
        assert r.status_code == 303 and "Secure" in ck and "Domain" not in ck
        ut = ck.split(";", 1)[0].split("=", 1)[1]
        r = c.get(VERIFY, headers={**API, **REMOTE, "X-Forwarded-Host": R_CODE_HOST, "Cookie": f"__Host-bn_session={tok}; {REMOTE_CODE_COOKIE}={ut}"})
        assert r.status_code == 200


# --- /.bn/models and /.bn/spend (Caddy → /auth/code-models, /auth/code-spend) ---

def _guarded(c, path, tok, ut, host=CODE_HOST, origin=None):
    h = {"Host": host, "Cookie": f"{COOKIE}={tok}; {CODE_COOKIE}={ut}"}
    if origin:
        h["Origin"] = origin
    return c.get(path, headers=h)


def test_models_and_spend_need_the_code_host_a_session_and_its_unlock(cc):
    tok, ut = unlocked(cc)
    for path in ("/auth/code-models", f"/auth/code-spend?session={SID}"):
        assert cc.get(path, headers={"Host": CODE_HOST, "Cookie": f"{COOKIE}={tok}"}).status_code == 401
        assert _guarded(cc, path, tok, ut, host="devos-ade.localhost").status_code == 404
        assert _guarded(cc, path, tok, ut, origin="http://evil.example").status_code == 403


def test_models_are_this_stacks_claude_models_with_its_prices(cs):
    (cs.litellm_dir / "probe-results.tsv").write_text(
        "claude-opus-5-5\tchat\tENABLED\tok\t$4.40/$22\t2026-10-15\n"
        "claude-haiku-5-5\tchat\tENABLED\tok\t$0.11/$0.55\t2026-10-15\n"
        "claude-sonnet-4-5\tchat\tDISABLED\tno model access\t-\t2026-10-15\n"
        "gpt-6-sol\tchat\tENABLED\tok\t-\t2026-10-15\n"
        "cohere-embed-v4\tembedding\tENABLED\tok\t-\t2026-10-15\n", encoding="utf-8")
    (cs.catalog_dir / "prices.tsv").write_text(
        "# as_of: 2026-10-12\nclaude-opus-5-5\t4.40\t22.00\t0.22\t5.50\t-\t-\nclaude-haiku-5-5\t0.11\t0.55\t0.011\t0.1375\t-\t-\n", encoding="utf-8")
    s = replace(cs, claude_models={"opus": "claude-opus-5-5", "sonnet": "", "haiku": "claude-haiku-5-5"})
    with _client(s) as c:
        tok, ut = unlocked(c)
        r = _guarded(c, "/auth/code-models", tok, ut)
        assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
        d = r.json()
        assert [m["id"] for m in d["models"]] == ["claude-opus-5-5", "claude-haiku-5-5"]
        opus = d["models"][0]
        assert opus["alias"] == "opus" and opus["prices"] == {"in": 4.4, "out": 22.0, "cache_read": 0.22, "cache_write": 5.5}
        assert (opus["name"], opus["input_per_mtok"], opus["output_per_mtok"], opus["cache_read_per_mtok"], opus["cache_write_per_mtok"]) == \
            ("claude-opus-5-5", 4.4, 22.0, 0.22, 5.5)
        assert opus["cache_write_30k"] == 0.165
        assert d["aliases"] == {"opus": "claude-opus-5-5", "haiku": "claude-haiku-5-5"} and d["default"] == "claude-opus-5-5"
        assert "(claude-opus-5-5 $0.165, claude-haiku-5-5 $0.004)" in d["note"], d["note"]


CODE_TSV = (
    "# GENERATED by ./stack (lib/code_models.sh) — do not edit.\n# scope: anthropic\n"
    "# id\tname\tprovider\tvendor\tin\tout\tcache_read\tcache_write\tfree\tcompat\tlisted\tdefault\tmax_out\tcontext\tnote\n"
    "claude-haiku-5-5\tClaude Haiku 5.5\tBedrock\tAnthropic\t0.11\t0.55\t0.011\t0.1375\t0\tworks\t1\t0\t-\t-\tAnthropic's own.\n"
    "llama-3-3-70b\tLlama 3.3 70B\tBedrock\tMeta\t0.72\t0.72\t-\t-\t0\tchat-only\t0\t0\t8192\t-\tAnswers, but no tools.\n"
    "claude-opus-5-5\tClaude Opus 5.5\tBedrock\tAnthropic\t4.40\t22.00\t0.22\t5.50\t0\tworks\t1\t1\t-\t-\t-\n"
    "mistral-large-3\tMistral Large 3\tBedrock\tMistral\t0.50\t1.50\t-\t-\t0\tworks\t1\t0\t-\t-\tTools work.\n"
    "or/google/gemma-4-31b-it:free\tGemma 4 31B (free)\tOpenRouter\tGoogle\t0\t0\t-\t-\t1\tuntested\t1\t0\t32768\t262144\tNot checked.\n"
    "or/meta-llama/llama-3.3-70b-instruct\tLlama 3.3 70B Instruct\tOpenRouter\tMeta\t0.22\t0.5\t0.11\t-\t0\tbogus\t1\t0\t16384\t131072\t-\n"
    "bad id\tX\tBedrock\tA\t1\t1\t-\t-\t0\tworks\t1\t0\t-\t-\t-\n"
    "gpt-6-luna\tGPT-6 Luna\tAzure\tOpenAI\t1\t1\t-\t-\t0\tworks\t1\t0\t-\t-\t-\n"
    "short\trow\n")


def test_models_are_every_model_of_code_models_tsv_with_compat_and_free_at_zero(cs):
    (cs.litellm_dir / "code-models.tsv").write_text(CODE_TSV, encoding="utf-8")
    # Bedrock's prices: the daily list in use wins over the file (as Home); OpenRouter's come from the file
    (cs.catalog_dir / "prices.tsv").write_text("# as_of: 2026-10-12\nclaude-opus-5-5\t5.00\t25.00\t0.50\t6.25\t-\t-\n", encoding="utf-8")
    s = replace(cs, claude_models={"opus": "claude-opus-5-5", "sonnet": "", "haiku": "claude-haiku-5-5"}, openrouter_api_key="sk-or-v1-abc")
    with _client(s) as c:
        tok, ut = unlocked(c)
        d = _guarded(c, "/auth/code-models", tok, ut).json()
        ids = [m["id"] for m in d["models"]]
        # Claude first (opus, haiku: the slots' order), then the rest as ./stack listed them; bad rows left out
        assert ids == ["claude-opus-5-5", "claude-haiku-5-5", "llama-3-3-70b", "mistral-large-3", "or/google/gemma-4-31b-it:free",
                       "or/meta-llama/llama-3.3-70b-instruct"], ids
        by = {m["id"]: m for m in d["models"]}
        assert by["claude-opus-5-5"]["prices"] == {"in": 5.0, "out": 25.0, "cache_read": 0.5, "cache_write": 6.25}
        assert by["claude-haiku-5-5"]["input_per_mtok"] == 0.11 and by["claude-haiku-5-5"]["cache_write_per_mtok"] == 0.1375
        llama = by["llama-3-3-70b"]
        assert (llama["provider"], llama["vendor"], llama["compat"], llama["listed"], llama["max_output_tokens"], llama["note"]) == \
            ("Bedrock", "Meta", "chat-only", False, 8192, "Answers, but no tools.")
        assert llama["cache_write_per_mtok"] is None and llama["cache_write_30k"] is None
        free = by["or/google/gemma-4-31b-it:free"]
        assert free["free"] is True and free["prices"] == {"in": 0.0, "out": 0.0, "cache_read": None, "cache_write": None}
        assert (free["provider"], free["context"], free["compat"]) == ("OpenRouter", 262144, "untested")
        assert by["or/meta-llama/llama-3.3-70b-instruct"]["compat"] == "untested"   # an unknown word is untested
        assert by["or/meta-llama/llama-3.3-70b-instruct"]["cache_read_per_mtok"] == 0.11
        assert d["default"] == "claude-opus-5-5" and d["scope"] == {"mode": "anthropic", "listed": 5, "total": 6}
        assert d["settings_default"] == "claude-opus-5-5"   # (a header that does not name CODE_DEFAULT_MODEL: the marked row)
        assert "Claude Opus 5.5 $0.188" in d["note"] and "free models cost $0" in d["note"]
        # which providers have a key (the picker's greyed "add it here" items: Settings › Models & providers)
        assert d["providers"] == {"openrouter": True, "explabs": False}
    # without OpenRouter's key its models are gone at once (the file follows at the next render), and the picker says
    # where the key goes in
    with _client(replace(s, openrouter_api_key="")) as c:
        tok, ut = unlocked(c)
        d = _guarded(c, "/auth/code-models", tok, ut).json()
        assert not [m for m in d["models"] if m["provider"] == "OpenRouter"] and d["providers"]["openrouter"] is False


def test_models_default_falls_back_to_a_listed_one(cs):
    rows = CODE_TSV.replace("\t1\t1\t-\t-\t-\n", "\t0\t0\t-\t-\t-\n")   # opus neither listed nor the default
    (cs.litellm_dir / "code-models.tsv").write_text(rows, encoding="utf-8")
    s = replace(cs, claude_models={"opus": "claude-opus-5-5", "sonnet": "", "haiku": "claude-haiku-5-5"})
    with _client(s) as c:
        tok, ut = unlocked(c)
        d = _guarded(c, "/auth/code-models", tok, ut).json()
        assert d["default"] == "claude-haiku-5-5" and not next(m for m in d["models"] if m["id"] == "claude-opus-5-5")["listed"]


SONNET_ROW = "claude-sonnet-5-5\tClaude Sonnet 5.5\tBedrock\tAnthropic\t2.20\t11.00\t0.22\t2.75\t0\tworks\t1\t0\t-\t-\t-\n"


def _header(default: str) -> str:
    return ("# GENERATED by ./stack (lib/code_models.sh) — do not edit. Settings › Claude Code › Models: CODE_MODELS=anthropic "
            f"CODE_DEFAULT_MODEL={default}\n")


def test_models_default_is_sonnet_unless_settings_name_one(cs):
    """A new session starts on Sonnet (the Sonnet slot: the current Sonnet), never on Opus by default: Settings' default
    for new sessions (CODE_DEFAULT_MODEL) when it names a listed model, else Sonnet, else the main model."""
    aliases = {"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5"}
    body = CODE_TSV.split("\n", 1)[1] + SONNET_ROW   # (the rows: ./stack marked Opus, the main model)
    s = replace(cs, claude_models=aliases)

    def ask(text):
        (cs.litellm_dir / "code-models.tsv").write_text(text, encoding="utf-8")
        with _client(s) as c:
            tok, ut = unlocked(c)
            d = _guarded(c, "/auth/code-models", tok, ut).json()
        return d["default"], d["settings_default"]

    # CODE_DEFAULT_MODEL blank: ./stack marks the main model (devos-claude's default), the Code page starts on Sonnet
    assert ask(_header("") + body) == ("claude-sonnet-5-5", None)
    # one that is not enabled counts as blank (./stack marked Opus again)
    assert ask(_header("claude-not-there") + body) == ("claude-sonnet-5-5", None)
    # Settings name one: that one (./stack marks it)
    named = body.replace("\t0\tworks\t1\t1\t", "\t0\tworks\t1\t0\t").replace(
        "claude-haiku-5-5\tClaude Haiku 5.5\tBedrock\tAnthropic\t0.11\t0.55\t0.011\t0.1375\t0\tworks\t1\t0",
        "claude-haiku-5-5\tClaude Haiku 5.5\tBedrock\tAnthropic\t0.11\t0.55\t0.011\t0.1375\t0\tworks\t1\t1")
    assert ask(_header("claude-haiku-5-5") + named) == ("claude-haiku-5-5", "claude-haiku-5-5")
    # Settings name Opus itself: Opus
    assert ask(_header("claude-opus-5-5") + body) == ("claude-opus-5-5", "claude-opus-5-5")
    # no Sonnet enabled: the main model, as before
    assert ask(_header("") + CODE_TSV.split("\n", 1)[1]) == ("claude-opus-5-5", None)
    # before ./stack wrote the file: the enabled Claude models — Sonnet first among them as the default
    (cs.litellm_dir / "code-models.tsv").unlink()
    (cs.litellm_dir / "probe-results.tsv").write_text(
        "claude-opus-5-5\tchat\tENABLED\tok\t-\t2026-10-15\nclaude-sonnet-5-5\tchat\tENABLED\tok\t-\t2026-10-15\n", encoding="utf-8")
    with _client(s) as c:
        tok, ut = unlocked(c)
        d = _guarded(c, "/auth/code-models", tok, ut).json()
    assert (d["default"], d["settings_default"]) == ("claude-sonnet-5-5", None)


def _litellm(pages, calls):
    def handler(request):
        calls.append(request)
        if request.url.path == "/key/info":
            assert request.headers["authorization"] == f"Bearer {TERM_KEY}"
            return httpx.Response(200, json={"info": {"spend": 1.25, "max_budget": 50, "budget_reset_at": "2026-11-01T00:00:00Z"}})
        assert request.url.path == "/spend/logs/session/ui" and request.headers["authorization"] == "Bearer sk-master"
        page = int(request.url.params["page"])
        return pages(page, request)
    return httpx.MockTransport(handler)


def test_spend_is_the_sessions_rows_of_the_terminal_key_only(cs):
    mine = hashlib.sha256(TERM_KEY.encode()).hexdigest()
    rows = {1: [{"api_key": mine, "spend": 0.0039, "model": "claude-haiku-5-5", "startTime": "2026-10-15T10:00:01Z", "prompt_tokens": 3,
                 "completion_tokens": 5, "total_tokens": 8, "status": "success", "metadata": {"usage_object": {"cache_creation_input_tokens": 26000}}},
                {"api_key": "someone-elses-hash", "spend": 9.99, "model": "x", "startTime": "2026-10-15T10:00:00Z"}],
            2: [{"api_key": mine, "spend": 0.0004, "model": "claude-haiku-5-5", "startTime": "2026-10-15T10:00:00Z", "total_tokens": "NaN",
                 "prompt_tokens": -3}]}
    calls = []
    t = _litellm(lambda p, req: httpx.Response(200, json={"data": rows[p], "total": 3, "page": p, "page_size": 100, "total_pages": 2}), calls)
    with _client(cs, transport=t) as c:
        tok, ut = unlocked(c)
        r = _guarded(c, f"/auth/code-spend?session={SID}", tok, ut)
        assert r.status_code == 200, r.text
        d = r.json()
        assert d["session"] == SID and d["requests"] == 2 and d["total"] == 0.0043
        assert [x["startTime"] for x in d["rows"]] == ["2026-10-15T10:00:00+00:00", "2026-10-15T10:00:01+00:00"]
        r1 = d["rows"][1]
        assert (r1["tokens"], r1["input_tokens"], r1["output_tokens"], r1["cache_read_tokens"], r1["cache_write_tokens"]) == (8, 3, 5, 0, 26000)
        assert d["rows"][0]["tokens"] == 0 and d["rows"][0]["input_tokens"] == 0
        assert d["key"] == {"alias": "claude-code-terminal", "spend": 1.25, "max_budget": 50, "reset_at": "2026-11-01T00:00:00Z", "error": None}
        q = [x for x in calls if x.url.path.startswith("/spend")][0]
        assert q.url.params["session_id"] == f"code-{SID}"
        for bad in ("../../etc", "", f"{SID}x", SID.upper()):
            assert _guarded(c, f"/auth/code-spend?session={bad}", tok, ut).status_code == 400, bad


def test_spend_says_when_litellm_fails(cs):
    for resp in (httpx.Response(500, text="boom"), httpx.Response(200, text="not json"), httpx.Response(200, json={"nodata": 1})):
        t = _litellm(lambda p, req, resp=resp: resp, [])
        with _client(cs, transport=t) as c:
            tok, ut = unlocked(c)
            r = _guarded(c, f"/auth/code-spend?session={SID}", tok, ut)
            assert r.status_code == 502 and r.json()["error"]
    with _client(replace(cs, keys=cs.keys[:-1])) as c:
        tok, ut = unlocked(c)
        assert _guarded(c, f"/auth/code-spend?session={SID}", tok, ut).status_code == 503


def test_the_terminals_unlock_form_may_be_framed_by_the_code_page(settings, cs):
    for s, framed in ((replace(settings, terminal=True), False), (cs, True)):
        with _client(s) as c:
            tok = session(c)
            r = c.get("/auth/verify?app=terminal", headers={"Accept": "text/html", "X-Forwarded-Method": "GET", "X-Forwarded-Host": TERM_HOST,
                                                           "X-Forwarded-Uri": "/", "Cookie": f"{COOKIE}={tok}"})
            assert r.status_code == 401 and "Unlock the terminal" in r.text
            fa = r.headers["content-security-policy"].split("frame-ancestors ", 1)[1]
            assert fa == (f"{PORTAL} {CODE}" if framed else PORTAL), fa


def test_unlock_tokens_are_bound_to_their_app():
    s = Sessions(SECRET, "pw-hash")
    term, code = TerminalUnlocks(SECRET, s), TerminalUnlocks(SECRET, s, app="code")
    assert code.valid(code.issue()) and term.valid(term.issue())
    assert not code.valid(term.issue()) and not term.valid(code.issue())


# --- one unlock for both: the Code page's terminal panel (/.bn/terminal → the terminal host's /.bn/unlock-callback) ---

SAME = {"Sec-Fetch-Site": "same-origin"}
TERM = f"http://{TERM_HOST}"


def _handoff(c, tok, ut, headers=SAME, host=CODE_HOST):
    return c.get("/auth/code-terminal", headers={"Host": host, "Cookie": f"{COOKIE}={tok}; {CODE_COOKIE}={ut}", **headers})


def _callback(c, url, tok, host=TERM_HOST, extra=None):
    path = url.split(TERM, 1)[1] if url.startswith(TERM) else url
    q = path.split("?", 1)[1] if "?" in path else ""
    return c.get(f"/auth/terminal-unlock-callback?{q}", headers={"Host": host, "Cookie": f"{COOKIE}={tok}", **(extra or {})})


def test_the_code_pages_unlock_opens_the_terminal_once(cc):
    tok, ut = unlocked(cc)
    r = _handoff(cc, tok, ut)
    assert r.status_code == 303 and r.headers["location"].startswith(f"{TERM}/.bn/unlock-callback?t=")
    assert r.headers["referrer-policy"] == "no-referrer" and r.headers["cache-control"] == "no-store"
    url = r.headers["location"]
    r = _callback(cc, url, tok)
    assert r.status_code == 303 and r.headers["location"] == "/", r.text
    assert r.headers["referrer-policy"] == "no-referrer" and r.headers["cache-control"] == "no-store"
    ck = _cookie(r, TERMINAL_COOKIE)
    assert ck and "HttpOnly" in ck and "Domain" not in ck and "SameSite=strict" in ck
    age = int(re.search(r"Max-Age=(\d+)", ck).group(1))
    assert 12 * 3600 - 60 <= age <= 12 * 3600   # what is left of the Code page's unlock, not a new 12 hours
    term_ut = ck.split(";", 1)[0].split("=", 1)[1]
    cc.cookies.clear()
    r = cc.get("/auth/verify?app=terminal", headers={"X-Forwarded-Method": "GET", "X-Forwarded-Host": TERM_HOST, "X-Forwarded-Uri": "/",
                                                    "Cookie": f"{COOKIE}={tok}; {TERMINAL_COOKIE}={term_ut}"})
    assert r.status_code == 200
    # single use: the same link again is refused
    r = _callback(cc, url, tok)
    assert r.status_code == 401 and TERMINAL_COOKIE not in r.headers.get("set-cookie", "")


def test_the_hand_off_needs_the_code_unlock_the_page_itself_and_the_terminal(cc, cs, settings):
    tok, ut = unlocked(cc)
    assert _handoff(cc, tok, "nope").status_code == 401                          # no Code page unlock
    assert cc.get("/auth/code-terminal", headers={"Host": CODE_HOST, **SAME}).status_code == 401
    for h in ({}, {"Sec-Fetch-Site": "same-site"}, {"Sec-Fetch-Site": "cross-site"}, {"Sec-Fetch-Site": "none"}):
        assert _handoff(cc, tok, ut, headers=h).status_code == 403, h            # typed in, or another site's link
    assert _handoff(cc, tok, ut, headers={**SAME, "Origin": "http://evil.example"}).status_code == 403
    assert _handoff(cc, tok, ut, host=TERM_HOST).status_code == 404              # only on the code host
    with _client(replace(cs, code=False)) as c:                                   # the Code page off: nothing here
        t2 = session(c)
        assert _handoff(c, t2, ut).status_code == 404


TYPED = {"Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document", "Sec-Fetch-User": "?1"}


def test_an_address_typed_or_bookmarked_opens_the_terminal_too(cc):
    """A navigation the person started in the browser (typed, a bookmark, the history): Sec-Fetch-Site none with Mode
    navigate, Dest document and User ?1 — what browsers send only for that. The same hand-off as from the Code page."""
    tok, ut = unlocked(cc)
    r = _handoff(cc, tok, ut, headers=TYPED)
    assert r.status_code == 303 and r.headers["location"].startswith(f"{TERM}/.bn/unlock-callback?t="), r.text
    r = _callback(cc, r.headers["location"], tok)
    assert r.status_code == 303 and _cookie(r, TERMINAL_COOKIE)
    # still the session and the Code page's unlock first
    assert _handoff(cc, tok, "nope", headers=TYPED).status_code == 401
    assert cc.get("/auth/code-terminal", headers={"Host": CODE_HOST, **TYPED}).status_code == 401
    # ?open= without a launch token: the terminal still asks "Open … here?" (an address makes no token, typed or not)
    from urllib.parse import unquote
    from portal import answers
    r = cc.get("/auth/code-terminal", params={"open": "shell"},
               headers={"Host": CODE_HOST, "Cookie": f"{COOKIE}={tok}; {CODE_COOKIE}={ut}", **TYPED})
    assert r.status_code == 303 and "&next=" in r.headers["location"], r.text
    assert answers.ASK_TOKEN in unquote(r.headers["location"])


def test_every_other_kind_of_request_gets_the_card_not_the_hand_off(cc):
    tok, ut = unlocked(cc)
    kinds = {
        "cross-site (another site's link)": {**TYPED, "Sec-Fetch-Site": "cross-site"},
        "same-site (another of the portal's hosts)": {**TYPED, "Sec-Fetch-Site": "same-site"},
        "none without the user's gesture (?1)": {k: v for k, v in TYPED.items() if k != "Sec-Fetch-User"},
        "none, ?0": {**TYPED, "Sec-Fetch-User": "?0"},
        "none, not a navigation (a fetch)": {**TYPED, "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty"},
        "none, in a frame": {**TYPED, "Sec-Fetch-Dest": "iframe"},
        "none alone": {"Sec-Fetch-Site": "none"},
        "no Sec-Fetch-* at all": {},
        "an unknown value": {**TYPED, "Sec-Fetch-Site": "None"},
    }
    for why, h in kinds.items():
        r = _handoff(cc, tok, ut, headers=h)
        assert r.status_code == 403, why
        assert TERMINAL_COOKIE not in r.headers.get("set-cookie", "") and "location" not in r.headers, why
        assert r.headers["content-type"].startswith("text/html"), why
        assert "Open the terminal from the Code page" in r.text and 'href="/" id="terminal-to-code"' in r.text, why
        assert "DevOS ADE" in r.text and "/static/login.css" in r.text, why
        csp = r.headers["content-security-policy"]
        assert "default-src 'none'" in csp and "form-action 'none'" in csp and "frame-ancestors 'self'" in csp, csp
        assert "script-src" not in csp and r.headers["cache-control"] == "no-store", why
        assert r.headers["x-content-type-options"] == "nosniff", why


def test_the_hand_off_rule_reads_the_fetch_metadata_exactly():
    from portal.app import from_the_code_page_or_typed as ok
    assert ok({"sec-fetch-site": "same-origin"})
    assert ok({"sec-fetch-site": "none", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document", "sec-fetch-user": "?1"})
    for h in ({}, {"sec-fetch-site": "cross-site"}, {"sec-fetch-site": "same-site"}, {"sec-fetch-site": "none"},
              {"sec-fetch-site": "none", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document"},
              {"sec-fetch-site": "none", "sec-fetch-mode": "nested-navigate", "sec-fetch-dest": "document", "sec-fetch-user": "?1"},
              {"sec-fetch-site": "none", "sec-fetch-mode": "navigate", "sec-fetch-dest": "iframe", "sec-fetch-user": "?1"},
              {"sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document", "sec-fetch-user": "?1"}):
        assert not ok(h), h


def test_the_callback_refuses_bad_foreign_and_unsigned_tokens(cs):
    with _client(cs) as c:
        tok, ut = unlocked(c)
        url = _handoff(c, tok, ut).headers["location"]
        assert _callback(c, "/x?t=garbage", tok).status_code == 401
        assert _callback(c, "/x", tok).status_code == 401
        # on another host (the code host): not answered there at all
        r = c.get(f"/auth/terminal-unlock-callback?{url.split('?', 1)[1]}", headers={"Host": CODE_HOST, "Cookie": f"{COOKIE}={tok}"})
        assert r.status_code == 404
        # without the session (local): the login, no unlock
        r = _callback(c, url, "")
        assert r.status_code == 302 and "/login" in r.headers["location"] and TERMINAL_COOKIE not in r.headers.get("set-cookie", "")
    # a token of another kind (a session hand-off, signed with its own salt) never redeems here
    bad = Handoff(SECRET, Sessions(SECRET, cs.password_hash).fingerprint).issue(TERM_HOST, 1e9, None)
    with _client(cs) as c:
        tok = session(c)
        assert _callback(c, f"/x?t={bad}", tok).status_code == 401


def test_unlock_hand_off_tokens_expire_are_single_use_and_bound_to_their_host():
    clock = {"t": 1_000_000.0}
    fp = Sessions(SECRET, "pw-hash").fingerprint
    h = Handoff(SECRET, fp, clock=lambda: clock["t"], salt="devos-ade.portal.code-terminal")
    t = h.issue(TERM_HOST, clock["t"] - 10, "me@example.com", s=clock["t"] - 100)
    assert h.redeem(t, CODE_HOST) is None                         # wrong audience
    d = h.redeem(t, TERM_HOST)
    assert d and d["iat"] == clock["t"] - 10 and d["s"] == clock["t"] - 100 and d["u"] == "me@example.com"
    assert h.redeem(t, TERM_HOST) is None                         # replay
    t2 = h.issue(TERM_HOST, clock["t"], None)
    clock["t"] += 61
    assert h.redeem(t2, TERM_HOST) is None                        # expired (60 s)
    # another password: void at once; minted before a restart: void
    assert Handoff(SECRET, "other-fp", clock=lambda: clock["t"], salt="devos-ade.portal.code-terminal").redeem(
        h.issue(TERM_HOST, clock["t"], None), TERM_HOST) is None
    later = Handoff(SECRET, fp, clock=lambda: clock["t"] + 1, salt="devos-ade.portal.code-terminal")
    assert later.redeem(h.issue(TERM_HOST, clock["t"], None), TERM_HOST) is None
    # the session hand-off's tokens are not these (another salt)
    assert h.redeem(Handoff(SECRET, fp, clock=lambda: clock["t"]).issue(TERM_HOST, clock["t"], None), TERM_HOST) is None


def test_an_unlock_with_a_carried_time_ends_when_that_one_does():
    clock = {"t": 2_000_000.0}
    s = Sessions(SECRET, "pw-hash", clock=lambda: clock["t"])
    term = TerminalUnlocks(SECRET, s, clock=lambda: clock["t"])
    tok = term.issue(None, iat=clock["t"] - 11 * 3600)
    assert term.valid(tok)
    clock["t"] += 3601                                           # 12 hours after the Code page's unlock
    assert not term.valid(tok)
    assert not term.valid(term.issue(None, iat=clock["t"] + 60))   # never from the future


def test_sign_out_ends_what_the_hand_off_would_give(cs):
    with _client(cs) as c:
        tok, ut = unlocked(c)
        url = _handoff(c, tok, ut).headers["location"]
        c.post("/logout", headers={"Origin": PORTAL, "Cookie": f"{COOKIE}={tok}"})
        c.cookies.clear()
        r = _callback(c, url, tok)
        assert r.status_code in (302, 401) and TERMINAL_COOKIE not in r.headers.get("set-cookie", "")


def test_the_hand_off_on_the_remote_site_needs_its_switch_and_sets_that_hosts_session(settings):
    r_term = f"bn-terminal.{TN}"
    rs = replace(settings, terminal=True, code=True, remote_mode="tailscale", remote_host=R_PORTAL, proxy_secret=PROXY,
                 remote_app_hosts={"terminal": r_term, "code": R_CODE_HOST}, remote_terminal=True)
    with _client(rs) as c:
        r = c.post("/login", data={"password": PW, "next": "/"}, headers={"Origin": f"https://{R_PORTAL}", "Host": R_PORTAL, **REMOTE})
        tok = _cookie(r, "__Host-bn_session").split(";", 1)[0].split("=", 1)[1]
        c.cookies.clear()
        r = c.post("/auth/code-unlock", data={"password": PW}, headers={"Host": R_CODE_HOST, "Origin": f"https://{R_CODE_HOST}",
                                                                      "Cookie": f"__Host-bn_session={tok}", **REMOTE})
        c.cookies.clear()
        ut = _cookie(r, REMOTE_CODE_COOKIE).split(";", 1)[0].split("=", 1)[1]
        r = c.get("/auth/code-terminal", headers={"Host": R_CODE_HOST, "Cookie": f"__Host-bn_session={tok}; {REMOTE_CODE_COOKIE}={ut}",
                                                  **SAME, **REMOTE})
        assert r.status_code == 303 and r.headers["location"].startswith(f"https://{r_term}/.bn/unlock-callback?t="), r.text
        q = r.headers["location"].split("?", 1)[1]
        r = c.get(f"/auth/terminal-unlock-callback?{q}", headers={"Host": r_term, **REMOTE})   # no session cookie on this host yet
        assert r.status_code == 303, r.text
        cks = r.headers.get_list("set-cookie")
        assert any(x.startswith("__Host-bn_terminal=") and "Secure" in x for x in cks), cks
        assert any(x.startswith("__Host-bn_session=") for x in cks), cks   # the host's session too, as the session hand-off does
    # REMOTE_TERMINAL off: no remote terminal, no hand-off there
    with _client(replace(rs, remote_terminal=False)) as c:
        assert c.get("/auth/terminal-unlock-callback?t=x", headers={"Host": r_term, **REMOTE}).status_code == 404
        assert c.get("/auth/code-terminal", headers={"Host": R_CODE_HOST, **SAME, **REMOTE}).status_code == 404


def test_an_update_nobody_watched_is_said_once_in_activity(tmp_path):
    from portal import code as cp
    now = 1_800_000_000
    f = tmp_path / "code-default.json"
    assert cp.default_notice(tmp_path, now) is None
    f.write_text(json.dumps({"at": now - 60, "workspace": "/home/me/bedrock-now-workspace", "egress": True, "terminal": True}))
    assert cp.default_notice(tmp_path, now) == {"at": now - 60, "workspace": "/home/me/bedrock-now-workspace", "egress": True, "egress_mode": "internet",
                                               "terminal": True}
    for mode in ("internet", "host", "off"):
        f.write_text(json.dumps({"at": now - 60, "workspace": "/w", "egress": mode != "off", "egress_mode": mode, "terminal": False}))
        assert cp.default_notice(tmp_path, now)["egress_mode"] == mode
    f.write_text(json.dumps({"at": now - 60, "workspace": "/w", "egress": False, "egress_mode": "<b>", "terminal": False}))
    assert cp.default_notice(tmp_path, now)["egress_mode"] == "off"
    # stale (30 days), from the future, odd values: nothing
    for bad in ({"at": now - 31 * 86400, "workspace": "/w", "egress": True}, {"at": now + 3600, "workspace": "/w", "egress": True},
                {"at": "1", "workspace": "/w", "egress": True}, {"at": True, "workspace": "/w", "egress": True},
                {"at": now, "workspace": "relative", "egress": True}, {"at": now, "workspace": "/w\n<b>", "egress": True},
                {"at": now, "workspace": "/w", "egress": "yes"}, {"at": now, "workspace": "/" + "a" * 2000, "egress": False}):
        f.write_text(json.dumps(bad))
        assert cp.default_notice(tmp_path, now) is None, bad
    f.write_text("{not json")
    assert cp.default_notice(tmp_path, now) is None
    # no longer a banner on Home (code.js): an item in Activity (portal/activity.py, static/activity.js) with Keep and
    # Turn off; a Keep pressed on the old banner still counts (the same localStorage key)
    js = open("portal/static/code.js", encoding="utf-8").read()
    assert "defaultNotice" not in js and "code-default-notice" not in js
    act = open("portal/static/activity.js", encoding="utf-8").read()
    assert 'act("Keep", () => dismiss(it), "action")' in act and 'act("Turn off", () => go("#settings/CODE_ENABLED"), "action")' in act
    assert 'const NOTICE_SEEN = "bn.code.defaultNotice"' in act and "localStorage.setItem(NOTICE_SEEN, String(it.data.at))" in act
    assert "localStorage.getItem(NOTICE_SEEN) === String(it.data.at)" in act and "innerHTML" not in act


# --- /.bn/sessions (Caddy → /auth/code-sessions): what the Import sheet asks of the computer — the password checked
# --- here, the helper's request written here (ses-<nonce>.json: fixed fields, never a path); the code container never
# --- sees the password ---

def _sessions_dirs(s, tmp_path, actions=("sessions-scan", "sessions-fetch", "sessions-suggest", "sessions-copy"), screen=True, running=True):
    import time
    sd, rd = tmp_path / "status", tmp_path / "requests"
    sd.mkdir(parents=True, exist_ok=True)
    rd.mkdir(parents=True, exist_ok=True)
    if running:
        (sd / "helper.json").write_text(json.dumps({"heartbeat": int(time.time()), "pid": 1, "version": "v0.21.0", "rollback": {"available": False}}))
    (sd / "helper-settings.json").write_text(json.dumps({"settings": 1, "diagnostics": [], "sessions": list(actions), "screen": screen,
                                                        "written_at": int(time.time())}))
    return replace(s, status_dir=sd, request_dir=rd)


def _ses(c, body, tok, ut, host=CODE_HOST, origin=CODE, cookie=CODE_COOKIE, extra=None):
    h = {"Host": host, "Cookie": f"{COOKIE}={tok}; {cookie}={ut}", "Content-Type": "application/json", **SAME, **(extra or {})}
    if origin:
        h["Origin"] = origin
    return c.post("/auth/code-sessions", content=json.dumps(body), headers=h)


def _ses_files(s):
    return sorted(p.name for p in s.request_dir.iterdir() if p.name.startswith("ses-"))


def test_sessions_requests_need_the_code_host_its_unlock_its_origin_and_the_password(cs, tmp_path):
    s = _sessions_dirs(cs, tmp_path)
    with _client(s) as c:
        tok, ut = unlocked(c)
        body = {"action": "sessions-scan", "project": "p_0000aaaa", "tool": "both", "password": PW}
        r = c.post("/auth/code-sessions", content=json.dumps(body), headers={"Host": CODE_HOST, "Cookie": f"{COOKIE}={tok}", "Origin": CODE})
        assert r.status_code == 401
        assert _ses(c, body, tok, ut, host="devos-ade.localhost").status_code == 404
        assert _ses(c, body, tok, ut, origin="http://evil.example").status_code == 403
        assert _ses(c, body, tok, ut, origin=None).status_code == 403
        assert _ses(c, body, tok, ut, extra={"Sec-Fetch-Site": "cross-site"}).status_code == 403
        r = _ses(c, {**body, "password": "wrong"}, tok, ut)
        assert r.status_code == 403 and "not right" in r.json()["error"]
        assert _ses_files(s) == []
        r = _ses(c, {**body, "path": "/etc"}, tok, ut)
        assert r.status_code == 202, r.text
        n = r.json()["request"]
        assert _ses_files(s) == [f"ses-{n}.json"]
        line = (s.request_dir / f"ses-{n}.json").read_text()
        assert re.fullmatch(r'\{"action":"sessions-scan","requested_at":[0-9]+,"nonce":"' + n + r'","auth":"[A-Za-z0-9+/]+=*","origin":"local","project":"p_0000aaaa","tool":"both"\}\n', line), line
        assert "/etc" not in line
        assert (s.request_dir / f"ses-{n}.json").stat().st_mode & 0o777 == 0o640


def test_sessions_requests_each_field_checked_never_a_path(cs, tmp_path):
    s = _sessions_dirs(cs, tmp_path)
    with _client(s) as c:
        tok, ut = unlocked(c)
        sid, dig, scan = "3f2a7c1e-9b4d-4e8a-a1c2-0d9e8f7a6b5c", "d" * 64, "a" * 32
        good = [
            ({"action": "sessions-fetch", "project": "p_0000aaaa", "scan": scan, "rows": [1, 3]}, '"scan":"' + scan + '","rows":"1,3"}'),
            ({"action": "sessions-suggest"}, '"origin":"local"}'),
            ({"action": "sessions-copy", "project": "p_0000aaaa", "session": sid, "digest": dig, "thinking": "keep",
              "keep": ["main#0123456789abcdef", "subagents/agent-1.jsonl#fedcba9876543210"]},
             f'"session":"{sid}","digest":"{dig}","thinking":"keep","outputs":"out","keep":"main#0123456789abcdef,subagents/agent-1.jsonl#fedcba9876543210"}}'),
            # (its tool outputs too, asked for on the sheet)
            ({"action": "sessions-copy", "project": "p_0000aaaa", "session": sid, "digest": dig, "outputs": "in", "keep": ["main#0123456789abcdef"]},
             f'"session":"{sid}","digest":"{dig}","thinking":"default","outputs":"in","keep":"main#0123456789abcdef"}}'),
            # (nothing kept: only the tool outputs — from another device they come only so)
            ({"action": "sessions-copy", "project": "p_0000aaaa", "session": sid, "digest": dig, "outputs": "in", "keep": []},
             f'"session":"{sid}","digest":"{dig}","thinking":"default","outputs":"in","keep":""}}'),
        ]
        for body, tail in good:
            import time
            time.sleep(2.1)   # (one request every 2 s)
            r = _ses(c, {**body, "password": PW}, tok, ut)
            assert r.status_code == 202, (body, r.text)
            assert (s.request_dir / f"ses-{r.json()['request']}.json").read_text().endswith(tail + "\n")
        bad = [
            {"action": "rm"}, {"action": "sessions-scan", "project": "../x"}, {"action": "sessions-scan", "project": "p_0000aaaa", "tool": "codex"},
            {"action": "sessions-fetch", "project": "p_0000aaaa", "scan": scan, "rows": []}, {"action": "sessions-fetch", "project": "p_0000aaaa", "scan": scan, "rows": ["1;rm"]},
            {"action": "sessions-fetch", "project": "p_0000aaaa", "scan": scan, "rows": list(range(1, 52))}, {"action": "sessions-fetch", "project": "p_0000aaaa", "scan": "/etc", "rows": [1]},
            {"action": "sessions-copy", "project": "p_0000aaaa", "session": sid, "digest": dig, "keep": []},
            {"action": "sessions-copy", "project": "p_0000aaaa", "session": sid, "digest": dig, "outputs": "out", "keep": []},
            {"action": "sessions-copy", "project": "p_0000aaaa", "session": sid, "digest": dig, "keep": ["../../etc#0123456789abcdef"]},
            {"action": "sessions-copy", "project": "p_0000aaaa", "session": sid, "digest": "x", "keep": ["main#0123456789abcdef"]},
            {"action": "sessions-copy", "project": "p_0000aaaa", "session": "x", "digest": dig, "keep": ["main#0123456789abcdef"]},
            {"action": "sessions-copy", "project": "p_0000aaaa", "session": sid, "digest": dig, "outputs": "all", "keep": ["main#0123456789abcdef"]},
        ]
        before = _ses_files(s)
        for body in bad:
            time.sleep(0.01)
            r = _ses(c, {**body, "password": PW}, tok, ut)
            assert r.status_code in (400, 429), (body, r.status_code)
        assert _ses_files(s) == before


def test_sessions_requests_need_the_helper_and_over_remote_access_never_a_look(cs, tmp_path, settings):
    with _client(_sessions_dirs(cs, tmp_path, running=False)) as c:
        tok, ut = unlocked(c)
        r = _ses(c, {"action": "sessions-suggest", "password": PW}, tok, ut)
        assert r.status_code == 503 and "not running" in r.json()["error"]
    with _client(_sessions_dirs(cs, tmp_path / "old", actions=("sessions-revoke",))) as c:
        tok, ut = unlocked(c)
        r = _ses(c, {"action": "sessions-suggest", "password": PW}, tok, ut)
        assert r.status_code == 409 and "refreshes it" in r.json()["error"]
    with _client(_sessions_dirs(cs, tmp_path / "noscreen", screen=False)) as c:
        tok, ut = unlocked(c)
        assert _ses(c, {"action": "sessions-suggest", "password": PW}, tok, ut).status_code == 409
    # over remote access: a look and suggestions refused; a read of a look allowed on the computer goes, said remote
    rs = replace(settings, terminal=True, code=True, remote_mode="tailscale", remote_host=R_PORTAL, proxy_secret=PROXY,
                 remote_app_hosts={"terminal": f"bn-terminal.{TN}", "code": R_CODE_HOST}, remote_terminal=True)
    rs = _sessions_dirs(rs, tmp_path / "remote")
    with _client(rs) as c:
        r = c.post("/login", data={"password": PW, "next": "/"}, headers={"Origin": f"https://{R_PORTAL}", "Host": R_PORTAL, **REMOTE})
        tok = _cookie(r, "__Host-bn_session").split(";", 1)[0].split("=", 1)[1]
        c.cookies.clear()
        r = c.post("/auth/code-unlock", data={"password": PW}, headers={"Host": R_CODE_HOST, "Origin": f"https://{R_CODE_HOST}",
                                                                      "Cookie": f"__Host-bn_session={tok}", **REMOTE})
        c.cookies.clear()
        ut = _cookie(r, REMOTE_CODE_COOKIE).split(";", 1)[0].split("=", 1)[1]
        kw = {"host": R_CODE_HOST, "origin": f"https://{R_CODE_HOST}", "extra": {**REMOTE, "Cookie": f"__Host-bn_session={tok}; {REMOTE_CODE_COOKIE}={ut}"}}
        for act in ("sessions-scan", "sessions-suggest"):
            r = _ses(c, {"action": act, "project": "p_0000aaaa", "password": PW}, tok, ut, **kw)
            assert r.status_code == 403 and "Only on the computer" in r.json()["error"], r.text
        r = _ses(c, {"action": "sessions-fetch", "project": "p_0000aaaa", "scan": "a" * 32, "rows": [2], "password": PW}, tok, ut, **kw)
        assert r.status_code == 202, r.text
        assert '"origin":"remote"' in (rs.request_dir / f"ses-{r.json()['request']}.json").read_text()


# --- Bring your setup: setup-scan, setup-fetch, setup-copy — the same door, fixed fields, never a path; a look and an
# --- open only on the computer itself ---

def test_setup_requests_each_field_checked_never_a_path(cs, tmp_path):
    import time
    acts = ("sessions-scan", "sessions-fetch", "sessions-suggest", "sessions-copy", "setup-scan", "setup-fetch", "setup-copy")
    s = _sessions_dirs(cs, tmp_path, actions=acts)
    with _client(s) as c:
        tok, ut = unlocked(c)
        dig, scan, k1, k2 = "d" * 64, "a" * 32, "s_0123456789abcdef", "s_fedcba9876543210"
        good = [
            ({"action": "setup-scan", "project": "-", "tool": "all"}, '"origin":"local","project":"-","tool":"all"}'),
            ({"action": "setup-scan", "project": "p_0000aaaa", "tool": "git"}, '"project":"p_0000aaaa","tool":"git"}'),
            ({"action": "setup-fetch", "scan": scan, "rows": [1, 7, 100]}, '"scan":"' + scan + '","rows":"1,7,100"}'),
            ({"action": "setup-copy", "units": [k1, k2], "digest": dig, "mode": "append", "conflict": "replace", "keep": ["v#0123456789abcdef", "f12#fedcba9876543210"]},
             f'"units":"{k1}+{k2}","digest":"{dig}","mode":"append","conflict":"replace","keep":"v#0123456789abcdef,f12#fedcba9876543210"}}'),
            # (nothing kept: a copy from another device of what lets Claude act without asking — the password checked here)
            ({"action": "setup-copy", "units": [k1], "digest": dig, "keep": []}, f'"units":"{k1}","digest":"{dig}","mode":"replace","conflict":"leave","keep":""}}'),
        ]
        for body, tail in good:
            time.sleep(2.1)   # (one request every 2 s)
            r = _ses(c, {**body, "password": PW}, tok, ut)
            assert r.status_code == 202, (body, r.text)
            line = (s.request_dir / f"ses-{r.json()['request']}.json").read_text()
            assert line.endswith(tail + "\n"), line
        bad = [
            {"action": "setup-scan", "project": "/home/me", "tool": "all"}, {"action": "setup-scan", "project": "-", "tool": "ssh"},
            {"action": "setup-scan", "project": "-"},
            {"action": "setup-fetch", "scan": scan, "rows": []}, {"action": "setup-fetch", "scan": scan, "rows": list(range(1, 102))},
            {"action": "setup-fetch", "scan": "../x", "rows": [1]}, {"action": "setup-fetch", "scan": scan, "rows": ["~/.ssh"]},
            {"action": "setup-copy", "units": [k1], "digest": dig},
            {"action": "setup-copy", "units": ["../x"], "digest": dig, "keep": ["v#0123456789abcdef"]},
            {"action": "setup-copy", "units": [k1] * 2, "digest": dig, "keep": ["v#0123456789abcdef"]},
            {"action": "setup-copy", "units": [k1, k2, "s_0000000000000000", "s_1111111111111111", "s_2222222222222222"], "digest": dig, "keep": ["v#0123456789abcdef"]},
            {"action": "setup-copy", "units": [k1], "digest": dig, "keep": ["main#0123456789abcdef"]},
            {"action": "setup-copy", "units": [k1], "digest": dig, "mode": "overwrite", "keep": ["v#0123456789abcdef"]},
            {"action": "setup-copy", "units": [k1], "digest": dig, "conflict": "force", "keep": ["v#0123456789abcdef"]},
            {"action": "setup-copy", "units": k1, "digest": dig, "keep": ["v#0123456789abcdef"]},
        ]
        before = _ses_files(s)
        for body in bad:
            r = _ses(c, {**body, "password": PW}, tok, ut)
            assert r.status_code in (400, 429), (body, r.status_code)
        assert _ses_files(s) == before


def test_setup_over_remote_access_never_a_look_or_an_open_a_copy_said_remote(cs, tmp_path, settings):
    acts = ("setup-scan", "setup-fetch", "setup-copy")
    with _client(_sessions_dirs(cs, tmp_path / "old", actions=("sessions-scan",))) as c:
        tok, ut = unlocked(c)
        r = _ses(c, {"action": "setup-scan", "project": "-", "tool": "all", "password": PW}, tok, ut)
        assert r.status_code == 409 and "your setup" in r.json()["error"]
    with _client(_sessions_dirs(cs, tmp_path / "noscreen", actions=acts, screen=False)) as c:
        tok, ut = unlocked(c)
        r = _ses(c, {"action": "setup-scan", "project": "-", "tool": "all", "password": PW}, tok, ut)
        assert r.status_code == 409 and "sessions config import" in r.json()["error"]
    rs = replace(settings, terminal=True, code=True, remote_mode="tailscale", remote_host=R_PORTAL, proxy_secret=PROXY,
                 remote_app_hosts={"terminal": f"bn-terminal.{TN}", "code": R_CODE_HOST}, remote_terminal=True)
    rs = _sessions_dirs(rs, tmp_path / "remote", actions=acts)
    with _client(rs) as c:
        r = c.post("/login", data={"password": PW, "next": "/"}, headers={"Origin": f"https://{R_PORTAL}", "Host": R_PORTAL, **REMOTE})
        tok = _cookie(r, "__Host-bn_session").split(";", 1)[0].split("=", 1)[1]
        c.cookies.clear()
        r = c.post("/auth/code-unlock", data={"password": PW}, headers={"Host": R_CODE_HOST, "Origin": f"https://{R_CODE_HOST}",
                                                                      "Cookie": f"__Host-bn_session={tok}", **REMOTE})
        c.cookies.clear()
        ut = _cookie(r, REMOTE_CODE_COOKIE).split(";", 1)[0].split("=", 1)[1]
        kw = {"host": R_CODE_HOST, "origin": f"https://{R_CODE_HOST}", "extra": {**REMOTE, "Cookie": f"__Host-bn_session={tok}; {REMOTE_CODE_COOKIE}={ut}"}}
        for body in ({"action": "setup-scan", "project": "-", "tool": "all"}, {"action": "setup-fetch", "scan": "a" * 32, "rows": [1]}):
            r = _ses(c, {**body, "password": PW}, tok, ut, **kw)
            assert r.status_code == 403 and "Only on the computer" in r.json()["error"], r.text
        assert _ses_files(rs) == []
        r = _ses(c, {"action": "setup-copy", "units": ["s_0123456789abcdef"], "digest": "d" * 64, "keep": ["v#0123456789abcdef"], "password": PW}, tok, ut, **kw)
        assert r.status_code == 202, r.text
        assert '"origin":"remote"' in (rs.request_dir / f"ses-{r.json()['request']}.json").read_text()
