"""Home's item menu for a Chat conversation (static/home.js, static/ctxmenu.js; POST /api/chats/ID/rename|archive|delete,
portal/chatsearch.py): Open WebUI's own calls as the owner — the title checked and passed on, the archive endpoint (it
toggles) asked only for a chat that is not archived, the delete only with the conversation's own id named again — each
behind the portal's session and X-Requested-With, an id of the shape Chat uses, rate-limited, and what Open WebUI says
(no such chat, not allowed, down) said as it is, never a stack trace or a token."""

from dataclasses import replace
from pathlib import Path

import httpx
import pytest
from starlette.testclient import TestClient

from portal.app import create_app
from portal.security import COOKIE

STATIC = Path(__file__).resolve().parents[1] / "portal" / "static"

PW = "correct horse"
PORTAL = "http://bedrock-now.localhost"
API = {"X-Requested-With": "bedrock-now"}
C1 = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
C2 = "1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"


def offline(request):
    raise httpx.ConnectError("offline in tests")


class OWUI:
    """Open WebUI's sign-in and its chat endpoints for one chat each; records every call."""

    def __init__(self, archived=False, status=200):
        self.archived, self.status, self.calls, self.signins = archived, status, [], 0

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auths/signin":
            self.signins += 1
            return httpx.Response(200, json={"token": f"jwt-{self.signins}"})
        assert request.headers["authorization"].startswith("Bearer jwt-")
        body = request.content.decode() if request.content else ""
        self.calls.append((request.method, request.url.path, body))
        if self.status != 200:
            return httpx.Response(self.status, json={"detail": "x"})
        if request.method == "DELETE":
            return httpx.Response(200, json=True)
        if request.url.path.endswith("/archive"):
            self.archived = not self.archived   # (Open WebUI's endpoint toggles)
            return httpx.Response(200, json={"id": C1, "archived": self.archived})
        if request.method == "GET":
            return httpx.Response(200, json={"id": C1, "archived": self.archived})
        return httpx.Response(200, json={"id": C1, "title": "x"})


@pytest.fixture
def cs(settings):
    return replace(settings, terminal=True, code=True)


def signed_in(c):
    r = c.post("/login", data={"password": PW, "next": "/"}, headers={"Origin": PORTAL})
    assert r.status_code == 303, r.text


def client(s, owui):
    c = TestClient(create_app(s, transport=httpx.MockTransport(owui)), base_url=PORTAL, follow_redirects=False)
    return c


def test_rename_passes_a_checked_title_on_as_the_owner(cs):
    ow = OWUI()
    with client(cs, ow) as c:
        signed_in(c)
        r = c.post(f"/api/chats/{C1}/rename", json={"title": "  Trip\x1b[31m planning\n"}, headers=API)
        assert r.status_code == 200 and r.json() == {"ok": True, "title": "Trip [31m planning"}, r.text
        assert ow.calls[-1][0:2] == ("POST", f"/api/v1/chats/{C1}") and '"title":"Trip [31m planning"' in ow.calls[-1][2].replace(" ", "", 0).replace('": "', '":"')
        for bad in ({}, {"title": ""}, {"title": "   "}, {"title": 7}, {"title": None}):
            assert c.post(f"/api/chats/{C1}/rename", json=bad, headers=API).status_code == 400
        assert len(ow.calls) == 1, "nothing was asked of Chat for a bad title"
        long = c.post(f"/api/chats/{C1}/rename", json={"title": "t" * 500}, headers=API)
        assert long.status_code == 200 and len(long.json()["title"]) == 200


def test_archive_asks_first_and_never_toggles_an_archived_chat_back(cs):
    ow = OWUI()
    with client(cs, ow) as c:
        signed_in(c)
        r = c.post(f"/api/chats/{C1}/archive", headers=API)
        assert r.status_code == 200 and r.json() == {"ok": True, "archived": True}
        assert [x[0:2] for x in ow.calls] == [("GET", f"/api/v1/chats/{C1}"), ("POST", f"/api/v1/chats/{C1}/archive")]
        # already archived (a stale row): said as archived, the toggle not called
        r = c.post(f"/api/chats/{C1}/archive", headers=API)
        assert r.json()["archived"] is True and [x[1] for x in ow.calls][-1] == f"/api/v1/chats/{C1}"
        assert ow.archived is True


def test_delete_needs_the_conversations_own_id_named_again(cs):
    ow = OWUI()
    with client(cs, ow) as c:
        signed_in(c)
        for body in ({}, {"confirm": True}, {"confirm": C2}, {"confirm": ""}):
            assert c.post(f"/api/chats/{C1}/delete", json=body, headers=API).status_code == 400
        assert not [x for x in ow.calls if x[0] == "DELETE"], "nothing deleted without the confirmation"
        r = c.post(f"/api/chats/{C1}/delete", json={"confirm": C1}, headers=API)
        assert r.status_code == 200 and r.json() == {"ok": True, "deleted": C1}
        assert ow.calls[-1][0:2] == ("DELETE", f"/api/v1/chats/{C1}")


def test_the_portals_session_and_its_header_are_needed_and_the_id_is_a_chats(cs):
    ow = OWUI()
    with client(cs, ow) as c:
        for what, body in (("rename", {"title": "x"}), ("archive", None), ("delete", {"confirm": C1})):
            assert c.post(f"/api/chats/{C1}/{what}", json=body, headers=API).status_code == 401   # signed out
        signed_in(c)
        for what, body in (("rename", {"title": "x"}), ("archive", None), ("delete", {"confirm": C1})):
            assert c.post(f"/api/chats/{C1}/{what}", json=body).status_code == 400              # no X-Requested-With
            assert c.post(f"/api/chats/not-a-chat/{what}", json=body, headers=API).status_code == 400
            assert c.post(f"/api/chats/..%2F..%2Fadmin/{what}", json=body, headers=API).status_code in (400, 404)
        assert c.post(f"/api/chats/{C1}/rename", content="{no", headers={**API, "Content-Type": "application/json"}).status_code == 400
        assert not [x for x in ow.calls], "Open WebUI was asked about none of those"


@pytest.mark.parametrize("status,words", [(404, "no such conversation"), (403, "does not let you"), (500, "HTTP 500")])
def test_what_open_webui_says_is_said_plainly(cs, status, words):
    with client(cs, OWUI(status=status)) as c:
        signed_in(c)
        r = c.post(f"/api/chats/{C1}/rename", json={"title": "x"}, headers=API)
        assert words in r.json()["error"] and r.status_code == (status if status in (404, 403) else 502)
        assert "jwt" not in r.text


def test_chat_down_is_an_error_not_a_crash(cs):
    with client(cs, offline) as c:
        signed_in(c)
        r = c.post(f"/api/chats/{C1}/delete", json={"confirm": C1}, headers=API)
        assert r.status_code == 502 and "did not answer" in r.json()["error"]


def test_a_change_drops_the_kept_list_so_home_shows_it_at_once(cs):
    class Both(OWUI):
        def __call__(self, request):
            if request.url.path == "/api/v1/chats/" and request.method == "GET":
                self.lists = getattr(self, "lists", 0) + 1
                return httpx.Response(200, json=[{"id": C1, "title": "Trip", "updated_at": 1800000000}])
            return super().__call__(request)
    ow = Both()
    with client(cs, ow) as c:
        signed_in(c)
        assert c.get("/api/continue", headers=API).status_code == 200
        c.get("/api/continue", headers=API)
        assert ow.lists == 1, "kept for a few seconds"
        c.post(f"/api/chats/{C1}/rename", json={"title": "New"}, headers=API)
        c.get("/api/continue", headers=API)
        assert ow.lists == 2


def test_a_burst_of_changes_is_slowed(cs):
    with client(cs, OWUI()) as c:
        signed_in(c)
        codes = [c.post(f"/api/chats/{C1}/rename", json={"title": f"t{i}"}, headers=API).status_code for i in range(8)]
        assert codes[:4] == [200] * 4 and 429 in codes


# --- the front end's shared menu (static/ctxmenu.js): loaded, and built the way the portal's CSP needs ---
def test_index_loads_the_menu_assets_before_the_pages_that_use_it():
    html = (STATIC / "index.html").read_text()
    assert '/static/ctxmenu.css' in html
    js = html.index('/static/ctxmenu.js')
    for page in ("home.js", "models.js", "settings.js", "activity.js", "mobile.js"):
        assert js < html.index(f'/static/{page}'), page


def test_menu_code_builds_nodes_without_html_or_inline_styles():
    for name in ("ctxmenu.js", "home.js"):
        src = (STATIC / name).read_text()
        assert "innerHTML" not in src and "insertAdjacentHTML" not in src, name
        assert 'setAttribute("style"' not in src and "cssText" not in src, name
