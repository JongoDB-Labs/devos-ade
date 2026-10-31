"""Home's Continue row: what the Code page reports of its sessions (POST /.bn/recent on the code host → /auth/code-recent:
the code host, its unlock, its own Origin and script; checked, capped, plain text, in memory per sign-in) and
/api/continue (that report where the Code page is on for this site, and Chat's newest conversations through Open WebUI's
own list, as the owner) — portal/recent.py."""

import json
import time
from dataclasses import replace

import httpx
import pytest
from starlette.testclient import TestClient

from portal import recent
from portal.app import STATIC, create_app
from portal.security import COOKIE, CODE_COOKIE, REMOTE_CODE_COOKIE

PW = "correct horse"
PORTAL = "http://devos-ade.localhost"
CODE_HOST = "code.devos-ade.localhost"
CODE = f"http://{CODE_HOST}"
API = {"X-Requested-With": "devos-ade"}
OWN = {"X-Requested-With": "bn-code", "Sec-Fetch-Site": "same-origin", "Content-Type": "application/json"}
S1, S2, S3 = "3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8", "4f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8", "5f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8"
C1, C2 = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
NOW_MS = int(time.time() * 1000)


def offline(request):
    raise httpx.ConnectError("offline in tests")


class OWUI:
    """Open WebUI's sign-in (the trusted header) and its list of chats; records what was asked."""

    def __init__(self, rows=None, status=200):
        self.rows = rows if rows is not None else [{"id": C1, "title": "Trip planning", "updated_at": 1800000000, "created_at": 1}]
        self.status, self.lists, self.signins = status, [], 0

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auths/signin":
            assert request.headers["x-portal-user"] == "admin@example.com"
            self.signins += 1
            return httpx.Response(200, json={"token": f"jwt-{self.signins}"})
        if request.url.path == "/api/v1/chats/":
            self.lists.append((request.url.params.get("page"), request.headers.get("authorization")))
            return httpx.Response(self.status, json=self.rows if self.status == 200 else {"detail": "x"})
        return httpx.Response(404)


@pytest.fixture
def cs(settings):
    return replace(settings, terminal=True, code=True)


def _client(s, transport=None):
    return TestClient(create_app(s, transport=transport or httpx.MockTransport(offline)), base_url=PORTAL, follow_redirects=False)


def _cookie(resp, name):
    return next((c for c in resp.headers.get_list("set-cookie") if c.startswith(name + "=")), None)


def unlocked(c):
    r = c.post("/login", data={"password": PW, "next": "/"}, headers={"Origin": PORTAL})
    assert r.status_code == 303, r.text
    tok = _cookie(r, COOKIE).split(";", 1)[0].split("=", 1)[1]
    c.cookies.clear()
    r = c.post("/auth/code-unlock", data={"password": PW}, headers={"Host": CODE_HOST, "Origin": CODE, "Cookie": f"{COOKIE}={tok}"})
    assert r.status_code == 303, r.text
    c.cookies.clear()
    return tok, _cookie(r, CODE_COOKIE).split(";", 1)[0].split("=", 1)[1]


def report(c, body, tok, ut, host=CODE_HOST, origin=CODE, headers=OWN, raw=None):
    h = {"Host": host, "Cookie": f"{COOKIE}={tok}; {CODE_COOKIE}={ut}", **headers}
    if origin:
        h["Origin"] = origin
    return c.post("/auth/code-recent", content=raw if raw is not None else json.dumps(body), headers=h)


def home(c, tok):
    return c.get("/api/continue", headers={**API, "Cookie": f"{COOKIE}={tok}"})


GOOD = {"waiting": 1, "project": {"id": "p_0000aaaa", "name": "ui-sweep"},
        "sessions": [{"id": S1, "state": "waiting", "title": "Fix the test", "at": NOW_MS},
                     {"id": S2, "state": "closed", "title": "Explain the README", "at": NOW_MS - 3600_000}]}


# --- the report, checked ---

def test_a_report_is_checked_capped_and_plain_text():
    now = NOW_MS / 1000
    r = recent.take_report({"waiting": 5, "project": {"id": "ws", "name": ""}, "sessions": [
        {"id": S1, "state": "waiting", "title": "notes\u202efdp.exe\nline two\x1b[31m", "at": NOW_MS},
        {"id": "nope", "state": "idle", "title": "x"},                 # not an id
        {"id": S2, "state": "running", "title": "x"},                  # not a state
        {"id": S1, "state": "idle", "title": "again"},                 # the same session twice
        {"id": S3, "state": "idle", "title": ["no"], "at": "soon"},    # no title, no time
        "junk"]}, now)
    assert [s["id"] for s in r["sessions"]] == [S1, S3]
    assert r["sessions"][0]["title"] == "notes⟨U+202E⟩fdp.exe line two⟨U+001B⟩[31m"
    assert r["sessions"][0]["at"] == NOW_MS // 1000 and r["sessions"][1] == {"id": S3, "state": "idle", "title": "", "at": None}
    assert r["waiting"] == 5 and r["project"] == {"id": "ws", "name": "Workspace"}
    # at most 8 sessions, 120 characters a title; a time in the future or long ago, a bad project: left out
    many = recent.take_report({"sessions": [{"id": f"{i:08x}-5d6e-4f70-8192-a3b4c5d6e7f8", "state": "idle", "title": "t" * 500,
                                             "at": NOW_MS + 86400_000} for i in range(30)],
                               "project": {"id": "../etc", "name": "x"}, "waiting": True}, now)
    assert len(many["sessions"]) == recent.MAX_SESSIONS and all(len(s["title"]) == recent.MAX_TITLE for s in many["sessions"])
    assert all(s["at"] is None for s in many["sessions"]) and many["project"] is None and many["waiting"] == 0
    # waiting: never fewer than the sessions that wait
    assert recent.take_report({"sessions": [{"id": S1, "state": "waiting"}, {"id": S2, "state": "waiting"}]}, now)["waiting"] == 2
    for bad in (None, [], "x", {"sessions": "x"}, {"waiting": 1}):
        assert recent.take_report(bad, now) is None


def test_reports_are_kept_per_sign_in_in_memory_and_the_oldest_goes():
    rs = recent.Reports(clock=lambda: 1800000000)
    rs.put(None, {"waiting": 0, "sessions": [], "project": None})
    rs.put("me@example.com", {"waiting": 1, "sessions": [{"id": S1}], "project": {"id": "ws", "name": "Workspace"}})
    assert rs.get("")["at"] == 1800000000 and rs.get("me@example.com")["waiting"] == 1
    got = rs.get("me@example.com"); got["sessions"][0]["id"] = "changed"; got["project"]["name"] = "x"
    assert rs.get("me@example.com")["sessions"][0]["id"] == S1 and rs.get("me@example.com")["project"]["name"] == "Workspace"
    for i in range(recent.MAX_LOGINS + 2):
        rs.put(f"u{i}", {"waiting": 0, "sessions": [], "project": None})
    assert rs.get(None) is None and rs.get(f"u{recent.MAX_LOGINS + 1}") is not None
    rs.clear()
    assert rs.get(f"u{recent.MAX_LOGINS + 1}") is None


def test_burst_takes_n_in_any_window_then_says_when():
    t = [1000.0]
    b = recent.Burst(3, 10, clock=lambda: t[0])
    assert [b.take() for _ in range(3)] == [0, 0, 0]
    assert b.take() == 11                                                       # (the first leaves the window in 10 s)
    t[0] += 4
    assert b.take() == 7
    t[0] += 6.5
    assert b.take() == 0 and b.take() == 0 and b.take() == 0 and b.take() > 0


# --- POST /.bn/recent (Caddy → /auth/code-recent) ---

def test_only_the_code_pages_own_script_on_its_host_unlocked_may_report(cs):
    with _client(cs) as c:
        tok, ut = unlocked(c)
        r = c.post("/auth/code-recent", content=json.dumps(GOOD), headers={"Host": CODE_HOST, "Cookie": f"{COOKIE}={tok}", "Origin": CODE, **OWN})
        assert r.status_code == 401                                              # not unlocked
        assert report(c, GOOD, tok, ut, host="devos-ade.localhost").status_code == 404
        assert report(c, GOOD, tok, ut, origin="http://evil.example").status_code == 403
        assert report(c, GOOD, tok, ut, origin=None).status_code == 403
        assert report(c, GOOD, tok, ut, headers={**OWN, "X-Requested-With": "devos-ade"}).status_code == 403
        assert report(c, GOOD, tok, ut, headers={**OWN, "Sec-Fetch-Site": "same-site"}).status_code == 403
        assert home(c, tok).json()["code"]["report"] is None                     # nothing was taken
        assert report(c, None, tok, ut, raw="{not json").status_code == 400
        assert report(c, {"sessions": "x"}, tok, ut).status_code == 400
        assert report(c, None, tok, ut, raw=json.dumps({"sessions": [], "pad": "x" * recent.MAX_BODY})).status_code == 413
        r = report(c, GOOD, tok, ut)
        assert r.status_code == 204 and not r.content
        # two Code pages report the same change at the same moment: both taken; 20 in any 10 s at most
        assert all(report(c, GOOD, tok, ut).status_code == 204 for _ in range(recent.BURST_N - 1))
        r = report(c, GOOD, tok, ut)
        assert r.status_code == 429 and 1 <= int(r.headers["retry-after"]) <= recent.BURST_S


def test_home_gets_the_last_report_while_the_code_page_is_on_here_and_sign_out_forgets_it(cs):
    with _client(cs) as c:
        tok, ut = unlocked(c)
        assert report(c, GOOD, tok, ut).status_code == 204
        d = home(c, tok).json()
        assert d["code"]["enabled"] is True and d["code"]["here"] is True and isinstance(d["now"], int)
        rep = d["code"]["report"]
        assert rep["waiting"] == 1 and rep["project"] == {"id": "p_0000aaaa", "name": "ui-sweep"} and abs(rep["at"] - d["now"]) < 5
        assert [(s["id"], s["state"], s["title"]) for s in rep["sessions"]] == [(S1, "waiting", "Fix the test"), (S2, "closed", "Explain the README")]
        # the custom header and a session, as every /api/ request
        assert c.get("/api/continue", headers={"Cookie": f"{COOKIE}={tok}"}).status_code == 400
        assert c.get("/api/continue", headers=API).status_code == 401
        # Sign out: what the page reported is gone
        c.post("/logout", headers={"Origin": PORTAL, "Cookie": f"{COOKIE}={tok}"})
        tok2 = unlocked(c)[0]
        assert home(c, tok2).json()["code"]["report"] is None


def test_no_code_sessions_where_the_code_page_is_off(settings):
    with _client(settings) as c:
        r = c.post("/login", data={"password": PW, "next": "/"}, headers={"Origin": PORTAL})
        tok = _cookie(r, COOKIE).split(";", 1)[0].split("=", 1)[1]
        c.cookies.clear()
        d = home(c, tok).json()
        assert d["code"] == {"enabled": False, "here": False, "report": None}
        assert c.post("/auth/code-recent", content=json.dumps(GOOD), headers={"Host": CODE_HOST, "Origin": CODE, **OWN}).status_code == 404


# --- Chat's newest conversations ---

def test_chats_come_from_open_webuis_own_list_as_the_owner_and_are_kept_a_little_while(cs):
    ow = OWUI(rows=[{"id": C1, "title": "Trip\nplanning\x1b[31m", "updated_at": 1800000000}, {"id": "not-a-uuid", "title": "x"},
                    {"id": C2, "title": "", "updated_at": True}] + [{"id": f"{i:08x}-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "title": f"c{i}"} for i in range(9)])
    with _client(cs, httpx.MockTransport(ow)) as c:
        tok, _ = unlocked(c)
        d = home(c, tok).json()
        chats = d["chats"]["items"]
        assert len(chats) == recent.MAX_CHATS and "error" not in d["chats"]
        assert chats[0] == {"id": C1, "title": "Trip planning [31m", "updated_at": 1800000000}
        assert chats[1] == {"id": C2, "title": "Untitled chat", "updated_at": None}
        assert ow.lists == [("1", "Bearer jwt-1")] and "jwt-" not in json.dumps(d)
        home(c, tok)
        assert len(ow.lists) == 1          # (kept CHATS_TTL_S)


def test_chat_down_is_said_not_an_error_status(cs):
    with _client(cs, httpx.MockTransport(OWUI(status=500))) as c:
        tok, _ = unlocked(c)
        r = home(c, tok)
        assert r.status_code == 200 and r.json()["chats"] == {"items": [], "error": "Chat answered HTTP 500"}
    with _client(cs) as c:   # offline
        tok, _ = unlocked(c)
        assert "Chat did not answer" in home(c, tok).json()["chats"]["error"]


def test_recent_chats_are_cached():
    now = {"t": 1000.0}

    class Fake:
        n = 0

        async def recent(self, client, n):
            Fake.n += 1
            return [{"id": C1, "title": "x", "updated_at": None}]
    import asyncio
    rc = recent.RecentChats(Fake(), clock=lambda: now["t"])
    asyncio.run(rc.get(None)); asyncio.run(rc.get(None))
    assert Fake.n == 1
    now["t"] += recent.CHATS_TTL_S + 1
    asyncio.run(rc.get(None))
    assert Fake.n == 2


def test_home_page_scripts_build_text_only():
    js = (STATIC / "home.js").read_text(encoding="utf-8")
    for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "DOMParser", "eval(", "new Function"):
        assert sink not in js, sink
    assert '"use strict"' in js
    # every storage access is inside try/catch: blocked storage must not break the page
    import re
    for m in re.finditer(r"localStorage\.\w+", js):
        before = js[:m.start()]
        assert before.rfind("try {") > before.rfind("}"), m.group(0)


def test_home_opens_with_get_started_and_continue_and_the_walkthrough_beside_them(cs):
    with _client(cs) as c:
        tok, _ = unlocked(c)
        page = c.get("/", headers={"Cookie": f"{COOKIE}={tok}"}).text
    # home.js after code.js (window.bnCode) and before tour.js (a first visit leaves the walkthrough closed for it)
    order = [page.index(f'src="/static/{f}"') for f in ("app.js", "mobile.js", "code.js", "home.js", "tour.js")]
    assert order == sorted(order)
    # Get started and Continue first: before the update card and the operations (spend, services, models)
    first = [page.index(x) for x in ('id="get-started"', 'id="continue"', 'id="update-card"', 'class="grid"')]
    assert first == sorted(first)
    for tag in page.split("<")[1:]:
        if 'id="get-started"' in tag or 'id="continue"' in tag:
            assert " hidden" in tag, tag
    # the models table folded under one line; Services one line (mobile.js healthLine) on every screen
    assert '<details class="models-more" id="models-more">' in page and 'id="models-line"' in page
    css = (STATIC / "mobile.css").read_text(encoding="utf-8")
    assert ".tabs .more-item { display: none; }" in css and ".services:not(.expanded) #services { display: none; }" in css


def test_get_started_has_five_steps_ticked_by_what_the_portal_sees():
    js = (STATIC / "home.js").read_text(encoding="utf-8")
    import re
    assert re.findall(r'\{ id: "([a-z]+)", title:', js) == ["signin", "models", "code", "code", "chat", "budget"]
    # each from real state: models enabled, a Code session the page reported (or the Code key's spend), a chat in
    # Chat (or its key's spend), a budget changed from its default (or kept on purpose)
    for words in ('r.enabled && r.kind === "chat"', "rep && rep.sessions.length", 'spendOf("claude-code-terminal")', "chats > 0",
                  'spendOf("open-webui")', "gs.budgets || changed === true", 'api("/api/settings")'):
        assert words in js, words
    # hidden for good in this browser (kept defensively), brought back by the walkthrough; its Full walkthrough opens it
    assert 'const KEY = "bn.getstarted"' in js and 'window.bnTour.open("welcome")' in js and "window.bnGetStarted = {" in js
    tour = (STATIC / "tour.js").read_text(encoding="utf-8")
    assert "window.bnGetStarted.open()" in tour and "window.bnGetStarted.hidden()" in tour
