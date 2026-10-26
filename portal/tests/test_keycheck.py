"""Settings' in-form key check (portal/keycheck.py, POST /api/settings/check-key): the shape first, then one free call to
the key's provider at its fixed address, before the password — never stored, never logged, never on a remote device for a
key that could send data elsewhere. Fake keys are built here at run time."""

import asyncio
import json
import logging
from dataclasses import replace

import httpx
import pytest
from starlette.testclient import TestClient

from portal import keycheck
from portal.app import create_app
from test_settings import API, H, KEYS, ORIGIN, PROXY, R_ORIGIN, REMOTE, helper_up, row, write_snapshot

OR_KEY = "-".join(("sk", "or", "v1", "e2" * 20))        # the shape of an OpenRouter key; not one
XL_KEY = "xl" + "0123456789" * 3
STT_KEY = "_".join(("gsk", "q" * 30))
KEYS_HERE = [*KEYS, row("OPENROUTER_API_KEY", "openrouter", "h", "local", "or_key", "openrouter", set=False),
             row("WEBSEARCH_TAVILY_API_KEY", "websearch", "h", "local", "ws_key", "websearch", set=False)]


class Provider:
    """A stand-in for every provider: answers each request with ANSWER (status, body) or raises it; records each."""

    def __init__(self, answer=(200, {"data": {"label": "x"}})):
        self.answer, self.seen = answer, []

    def __call__(self, request: httpx.Request):
        self.seen.append(request)
        if isinstance(self.answer, Exception):
            raise self.answer
        status, body = self.answer
        return httpx.Response(status, content=json.dumps(body).encode() if not isinstance(body, bytes) else body)


@pytest.fixture
def client(settings, tmp_path):
    def make(provider, remote=False, admin_actions=True):
        sd, rq = tmp_path / "status", tmp_path / "requests"
        sd.mkdir(exist_ok=True); rq.mkdir(exist_ok=True)
        write_snapshot(sd, KEYS_HERE); helper_up(sd)
        s = replace(settings, status_dir=sd, request_dir=rq)
        if remote:
            s = replace(s, remote_mode="tailscale", remote_host="bn.tail1234.ts.net", proxy_secret=PROXY,
                        remote_admin_actions=admin_actions,
                        remote_app_hosts={"chat": "bn-chat.tail1234.ts.net", "admin": "bn-admin.tail1234.ts.net",
                                          "files": "bn-files.tail1234.ts.net"})
        c = TestClient(create_app(s, transport=httpx.MockTransport(provider)), follow_redirects=False,
                       base_url="https://bn.tail1234.ts.net" if remote else "http://bedrock-now.localhost")
        c.__enter__()
        head = {**R_ORIGIN, **REMOTE} if remote else ORIGIN
        assert c.post("/login", data={"password": "correct horse"}, headers=head).status_code == 303
        return c
    return make


def check(c, key, value, headers=H, **more):
    return c.post("/api/settings/check-key", content=json.dumps({"key": key, "value": value, **more}), headers=headers)


def test_a_good_openrouter_key_is_asked_of_openrouter_once_at_its_fixed_address(client, caplog):
    p = Provider()
    c = client(p)
    with caplog.at_level(logging.INFO):
        r = check(c, "OPENROUTER_API_KEY", f"  {OR_KEY} ")
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    assert r.json() == {"result": "ok", "message": "OpenRouter accepts this key.", "url": "https://openrouter.ai/settings/keys",
                        "models": None}
    assert [str(x.url) for x in p.seen] == ["https://openrouter.ai/api/v1/key"]
    assert p.seen[0].headers["authorization"] == f"Bearer {OR_KEY}"   # (trimmed, as a change trims it)
    assert OR_KEY not in caplog.text and OR_KEY not in r.text        # never logged, never echoed


def test_a_rejected_key_says_so_with_where_a_key_comes_from(client):
    c = client(Provider((401, {"error": {"message": f"No auth credentials found for {OR_KEY}"}})))
    d = check(c, "OPENROUTER_API_KEY", OR_KEY).json()
    assert d["result"] == "rejected" and d["message"] == "OpenRouter rejected this key (HTTP 401)."
    assert d["url"] == "https://openrouter.ai/settings/keys"
    assert OR_KEY not in json.dumps(d)   # (the provider's own words, which may quote the key, are never passed on)


def test_the_gateway_and_speech_to_text_count_the_models_the_key_may_use(client):
    p = Provider((200, {"data": [{"id": "a"}, {"id": "b"}, {"id": "c"}]}))
    d = check(client(p), "EXPLABS_API_KEY", XL_KEY).json()
    assert d["result"] == "ok" and d["models"] == 3 and d["message"] == "Experiential Labs accepts this key: it may use 3 models."
    assert d["url"] == "https://platform.experientiallabs.ai/settings/api-keys"
    d = check(client(p), "STT_API_KEY", STT_KEY, provider="groq").json()   # (another portal: its own rate limit)
    assert d["result"] == "ok" and d["url"] == "https://console.groq.com/keys"
    assert [str(x.url) for x in p.seen] == ["https://api.experientiallabs.ai/v1/models", "https://api.groq.com/openai/v1/models"]


def test_a_restricted_openai_key_is_accepted_as_lib_stt_accepts_it(client):
    c = client(Provider((403, {"error": {"message": "You have insufficient permissions for this operation. Missing scopes: model.read"}})))
    d = check(c, "STT_API_KEY", "-".join(("sk", "proj", "z" * 30)), provider="openai").json()
    assert d["result"] == "ok" and "restricted key" in d["message"]


def test_a_provider_that_does_not_answer_says_so_within_the_deadline(client, monkeypatch):
    c = client(Provider(httpx.ConnectTimeout("slow")))
    d = check(c, "OPENROUTER_API_KEY", OR_KEY).json()
    assert d["result"] == "unreachable" and d["message"] == f"openrouter.ai did not answer within {int(keycheck.DEADLINE)} s, so the key is not checked yet."


def test_the_deadline_covers_the_whole_check():
    async def slow(request):
        await asyncio.sleep(5)
        return httpx.Response(200, content=b"{}")

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(slow)) as cl:
            return await keycheck.check(cl, keycheck.OPENROUTER, OR_KEY)
    old = keycheck.DEADLINE
    keycheck.DEADLINE = 0.2
    try:
        d = asyncio.run(run())
    finally:
        keycheck.DEADLINE = old
    assert d["result"] == "unreachable" and "did not answer within" in d["message"]


def test_shape_first_never_asking_the_provider_for_a_bad_one(client):
    p = Provider()
    c = client(p)
    r = check(c, "OPENROUTER_API_KEY", "has spaces so not a key")
    assert r.status_code == 400 and r.json()["fields"] == {"OPENROUTER_API_KEY": "must be an OpenRouter key (sk-or-…; letters, digits, - and _)"}
    r = check(c, "OPENROUTER_API_KEY", "   ")
    assert r.status_code == 400 and r.json()["error"] == "Enter the new key."
    assert check(c, "EXPLABS_API_KEY", "short").status_code == 400
    assert p.seen == []


def test_a_key_without_a_free_check_is_only_shape_checked(client):
    p = Provider()
    c = client(p)
    d = check(c, "WEBSEARCH_TAVILY_API_KEY", "tvly-" + "a" * 20).json()
    assert d["result"] == "unchecked"
    d = check(c, "STT_API_KEY", STT_KEY, provider="bedrock").json()
    assert d["result"] == "unchecked"
    assert p.seen == []


def test_only_provider_keys_and_only_through_the_front_door(client):
    p = Provider()
    c = client(p)
    for key in ("BUDGET_SETUP", "PORTAL_PASSWORD", "AWS_SECRET_ACCESS_KEY", "NOPE"):
        assert check(c, key, "x" * 30).status_code == 400, key
    assert check(c, "OPENROUTER_API_KEY", OR_KEY, headers=ORIGIN).json()["error"] == "missing X-Requested-With"
    assert check(c, "OPENROUTER_API_KEY", OR_KEY, headers={**API, "Origin": "http://evil.example"}).status_code == 403
    assert c.post("/api/settings/check-key", content="x" * 3000, headers=H).status_code == 413
    assert c.post("/api/settings/check-key", content="[1]", headers=H).status_code == 400
    assert p.seen == []
    c.cookies.clear()
    assert check(c, "OPENROUTER_API_KEY", OR_KEY).status_code == 401


def test_one_check_a_second(client):
    p = Provider()
    c = client(p)
    assert check(c, "OPENROUTER_API_KEY", OR_KEY).json()["result"] == "ok"
    r = check(c, "OPENROUTER_API_KEY", OR_KEY)
    assert r.status_code == 429 and r.headers["retry-after"]
    assert len(p.seen) == 1


RH = {**R_ORIGIN, **API, **REMOTE, "Content-Type": "application/json"}


def test_never_from_a_remote_device_for_a_key_that_could_send_data_elsewhere(client):
    p = Provider()
    c = client(p, remote=True, admin_actions=True)
    r = check(c, "OPENROUTER_API_KEY", OR_KEY, headers=RH)
    assert r.status_code == 403 and "computer running DevOS ADE" in r.json()["error"]
    c = client(p, remote=True, admin_actions=False)
    r = check(c, "OPENROUTER_API_KEY", OR_KEY, headers=RH)
    assert r.status_code == 403 and "REMOTE_ADMIN_ACTIONS" in r.json()["error"]
    assert p.seen == []
