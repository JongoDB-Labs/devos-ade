"""Chat's "Make it a project" (JON-1060): a chat handed to the Code page as text, once — the store (portal/chathandoff.py),
the portal page's deposit (POST /api/chat-handoff) and the Code page's redeem (POST /.bn/handoff on the code host →
/auth/code-handoff: the code host, its unlock, its own Origin and script)."""

import json
from dataclasses import replace

import httpx
import pytest
from starlette.testclient import TestClient

from portal import chathandoff, code as codepage
from portal.app import create_app
from portal.security import COOKIE, CODE_COOKIE

from test_continue import API, CODE, CODE_HOST, OWN, PORTAL, offline, unlocked

TITLE = "Trip planner"
TEXT = "User: plan a trip\n\nAssistant: where to?"


@pytest.fixture
def cs(settings):
    return replace(settings, terminal=True, code=True)


def _client(s):
    return TestClient(create_app(s, transport=httpx.MockTransport(offline)), base_url=PORTAL, follow_redirects=False)


def deposit(c, tok, body, headers=None, raw=None):
    h = {"Cookie": f"{COOKIE}={tok}", "Origin": PORTAL, **API, **(headers or {})}
    return c.post("/api/chat-handoff", content=raw if raw is not None else json.dumps(body), headers=h)


def redeem(c, tok, ut, hid, host=CODE_HOST, origin=CODE, headers=OWN, raw=None):
    h = {"Host": host, "Cookie": f"{COOKIE}={tok}; {CODE_COOKIE}={ut}", **headers}
    if origin:
        h["Origin"] = origin
    return c.post("/auth/code-handoff", content=raw if raw is not None else json.dumps({"id": hid}), headers=h)


# --- the store ---

def test_a_handoff_is_read_once_by_its_sign_in_within_ten_minutes():
    t = [1000.0]
    hs = chathandoff.Handoffs(clock=lambda: t[0])
    hid = hs.put("me@example.com", TITLE, TEXT)
    assert len(hid) == chathandoff.ID_LEN
    assert hs.take("you@example.com", hid) is None          # not that person's: left where it is
    assert hs.take(None, hid) is None
    assert hs.take("me@example.com", hid) == {"title": TITLE, "text": TEXT}
    assert hs.take("me@example.com", hid) is None           # once
    hid = hs.put(None, TITLE, TEXT)
    t[0] += chathandoff.TTL_S - 1
    assert hs.take("", hid) == {"title": TITLE, "text": TEXT}
    hid = hs.put(None, TITLE, TEXT)
    t[0] += chathandoff.TTL_S
    assert hs.take(None, hid) is None                       # expired
    for bad in (None, 5, "", "x" * 31, "x" * 33, ["a"]):
        assert hs.take(None, bad) is None


def test_the_oldest_goes_when_too_many_wait_and_clear_forgets_all():
    hs = chathandoff.Handoffs(clock=lambda: 1.0)
    ids = [hs.put(None, str(i), "t") for i in range(chathandoff.MAX_KEPT + 2)]
    assert hs.take(None, ids[0]) is None and hs.take(None, ids[1]) is None
    assert hs.take(None, ids[2])["title"] == "2"
    hs.clear()
    assert hs.take(None, ids[-1]) is None


def test_the_body_is_checked_and_capped():
    assert chathandoff.take_body({"title": "T" * 500, "text": "hi"}) == ("T" * chathandoff.MAX_TITLE, "hi")
    assert chathandoff.take_body({"text": "hi"}) == ("", "hi")
    assert chathandoff.take_body({"title": 5, "text": "hi"}) == ("", "hi")
    assert chathandoff.take_body({"text": "x" * (chathandoff.MAX_TEXT + 1)}) == "too-big"
    assert chathandoff.take_body({"text": "x" * chathandoff.MAX_TEXT}) == ("", "x" * chathandoff.MAX_TEXT)
    for bad in (None, [], "x", {}, {"text": 5}, {"text": "  \n"}, {"text": "a\x00b"}):
        assert chathandoff.take_body(bad) is None


# --- the deposit (the portal page) and the redeem (the Code page) ---

def test_deposit_then_redeem_once(cs):
    c = _client(cs)
    tok, ut = unlocked(c)
    r = deposit(c, tok, {"title": TITLE, "text": TEXT})
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store", r.text
    hid = r.json()["id"]
    assert r.json()["expires_in"] == chathandoff.TTL_S and codepage.HANDOFF.fullmatch(hid)
    r = redeem(c, tok, ut, hid)
    assert r.status_code == 200 and r.json() == {"title": TITLE, "text": TEXT}
    r = redeem(c, tok, ut, hid)
    assert r.status_code == 404 and "used already" in r.json()["error"]


def test_the_deposit_is_the_portal_pages_own_request(cs):
    c = _client(cs)
    tok, _ = unlocked(c)
    body = {"title": TITLE, "text": TEXT}
    assert c.post("/api/chat-handoff", content=json.dumps(body), headers={"Origin": PORTAL, **API}).status_code == 401              # no session
    h = {"Cookie": f"{COOKIE}={tok}", "Origin": PORTAL}
    assert c.post("/api/chat-handoff", content=json.dumps(body), headers=h).status_code == 400                                       # no X-Requested-With
    assert deposit(c, tok, body, headers={"Origin": "http://evil.example"}).status_code == 403                                      # another site
    assert deposit(c, tok, None, raw="not json").status_code == 400
    assert deposit(c, tok, {"title": "x"}).status_code == 400                                                                     # no text
    assert deposit(c, tok, body).status_code == 200


def test_a_chat_over_the_cap_is_refused_and_says_so(cs):
    c = _client(cs)
    tok, _ = unlocked(c)
    r = deposit(c, tok, {"title": TITLE, "text": "x" * (chathandoff.MAX_TEXT + 1)})
    assert r.status_code == 413 and r.json()["tooBig"] is True and r.json()["limit"] == chathandoff.MAX_TEXT
    r = deposit(c, tok, None, raw=json.dumps({"text": "x" * (chathandoff.MAX_BODY + 1)}))
    assert r.status_code == 413 and r.json()["tooBig"] is True


def test_the_deposit_needs_the_code_page_on_here(settings):
    c = _client(replace(settings, terminal=True, code=False))
    r = c.post("/login", data={"password": "correct horse", "next": "/"}, headers={"Origin": PORTAL})
    tok = r.headers.get_list("set-cookie")[0].split(";", 1)[0].split("=", 1)[1]
    r = deposit(c, tok, {"title": TITLE, "text": TEXT})
    assert r.status_code == 404 and "off" in r.json()["error"]


def test_deposits_are_a_few_at_a_time(cs):
    c = _client(cs)
    tok, _ = unlocked(c)
    codes = [deposit(c, tok, {"title": TITLE, "text": TEXT}).status_code for _ in range(7)]
    assert codes == [200] * 5 + [429] * 2


def test_the_redeem_is_the_code_pages_own_request_and_nobody_elses(cs):
    c = _client(cs)
    tok, ut = unlocked(c)
    hid = deposit(c, tok, {"title": TITLE, "text": TEXT}).json()["id"]
    assert redeem(c, tok, ut, hid, host="chat.devos-ade.localhost").status_code == 404                                  # not the code host
    assert redeem(c, tok, ut, hid, origin="http://evil.example").status_code == 403                                     # another Origin
    assert redeem(c, tok, ut, hid, origin=None, headers={"X-Requested-With": "bn-code"}).status_code == 403             # no Origin
    assert redeem(c, tok, ut, hid, headers={**OWN, "X-Requested-With": "XMLHttpRequest"}).status_code == 403             # not its script
    assert redeem(c, tok, ut, hid, headers={**OWN, "Sec-Fetch-Site": "cross-site"}).status_code == 403
    assert redeem(c, tok, ut, hid, raw="nope").status_code == 400
    assert redeem(c, tok, ut, hid, raw=json.dumps({"id": hid, "pad": "x" * 2000})).status_code == 413
    h = {"Host": CODE_HOST, "Cookie": f"{COOKIE}={tok}", "Origin": CODE, **OWN}                                        # not unlocked
    assert c.post("/auth/code-handoff", content=json.dumps({"id": hid}), headers=h).status_code == 401
    assert redeem(c, tok, ut, "x" * 32).status_code == 404                                                             # a guess
    assert redeem(c, tok, ut, hid).status_code == 200                                                                  # none of that used it up


def test_sign_out_forgets_what_waits(cs):
    with _client(cs) as c:   # (a lifespan: Sign out sweeps Admin's sessions)
        tok, ut = unlocked(c)
        hid = deposit(c, tok, {"title": TITLE, "text": TEXT}).json()["id"]
        c.post("/logout", headers={"Cookie": f"{COOKIE}={tok}", "Origin": PORTAL})
        tok2, ut2 = unlocked(c)
        assert redeem(c, tok2, ut2, hid).status_code == 404


def test_the_code_pages_deep_link_carries_a_handoff_only_of_the_right_shape():
    dl = codepage.deep_link
    hid = "A" * 16 + "b_-" + "0" * 13
    assert len(hid) == 32
    assert dl(f"/?handoff={hid}") == f"/?handoff={hid}"
    assert dl("/?handoff=too-big") == "/?handoff=too-big" and dl("/?handoff=failed") == "/?handoff=failed"
    for bad in ("short", hid + "x", "../../etc/passwd", hid[:-1] + "+", "%00" * 32, ""):
        assert dl(f"/?handoff={bad}") is None
    assert dl(f"/?handoff={hid}&handoff=failed") == f"/?handoff={hid}"   # once each
