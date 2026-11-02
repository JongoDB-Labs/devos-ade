"""The Git page's search (JON-979): /api/search/git asks the built-in git server's API (Forgejo: repos/search, repos/issues/search)
from the portal server with a read-only token that stays in the portal container — portal/gitsearch.py. The client's requests
(query building, caps, timeouts, errors), the token never leaving the portal (no answer, page, static file, summary or
setting shows it), the endpoint needing the portal session, the git server being off, and the config that carries it."""

import json
import os
from dataclasses import replace
from pathlib import Path

import httpx
import pytest
from starlette.testclient import TestClient

from portal import gitsearch
from portal.app import STATIC, create_app
from portal.config import from_env

ORIGIN = {"Origin": "http://devos-ade.localhost"}
API = {"X-Requested-With": "devos-ade"}
TOKEN = "gt" + "q" * 38   # (a fake, made here: never a literal that looks like a key)


def offline(request):
    raise httpx.ConnectError("offline in tests")


def repo(name, desc="", **kw):
    return {"id": 1, "name": name.split("/")[1], "full_name": name, "description": desc, "private": False, "archived": False,
            "owner": {"login": name.split("/")[0]}, **kw}


def issue(n, title, repo_name="devos/notes", pr=False, state="open"):
    x = {"id": n, "number": n, "title": title, "state": state, "body": "never shown", "html_url": "http://evil.example/x",
         "repository": {"id": 1, "name": repo_name.split("/")[1], "owner": repo_name.split("/")[0], "full_name": repo_name}}
    if pr:
        x["pull_request"] = {"merged": False}
    return x


class Forgejo:
    """A transport that is the git server's search API, recording what it was asked."""

    def __init__(self, repos=None, issues=None, status=200, body=None):
        self.calls = []
        self.repos = [repo("devos/notes", "Meeting notes")] if repos is None else repos
        self.issues = [issue(12, "Fix notes"), issue(13, "Add search", pr=True)] if issues is None else issues
        self.status, self.body = status, body

    def __call__(self, request):
        self.calls.append(request)
        if self.status != 200:
            return httpx.Response(self.status, text="nope")
        if self.body is not None:
            return httpx.Response(200, content=self.body)
        if request.url.path == "/api/v1/repos/search":
            return httpx.Response(200, json={"ok": True, "data": self.repos})
        if request.url.path == "/api/v1/repos/issues/search":
            return httpx.Response(200, json=self.issues)
        return httpx.Response(404)


def on(settings, **kw):
    return replace(settings, git=True, git_token=TOKEN, **kw)


def client(s, transport=None, login=True):
    c = TestClient(create_app(s, transport=transport or httpx.MockTransport(offline)), base_url="http://devos-ade.localhost",
                   follow_redirects=False)
    c.__enter__()
    if login:
        c.post("/login", data={"password": "correct horse"}, headers=ORIGIN)
    return c


# --- the client's requests ---

def test_it_asks_the_two_search_paths_with_get_and_the_token_in_one_header_only(settings):
    f = Forgejo()
    c = client(on(settings), httpx.MockTransport(f))
    r = c.get("/api/search/git?q=notes", headers=API)
    assert r.status_code == 200, r.text
    assert sorted(x.url.path for x in f.calls) == ["/api/v1/repos/issues/search", "/api/v1/repos/search"]
    assert all(x.method == "GET" and x.url.host == "caddy" and x.url.port == 8099 and x.url.scheme == "http" for x in f.calls)
    for x in f.calls:
        assert x.headers["authorization"] == f"token {TOKEN}"
        assert TOKEN not in str(x.url) and not x.content   # (never in an address or a body)
    by = {x.url.path: dict(x.url.params) for x in f.calls}
    assert by["/api/v1/repos/search"] == {"q": "notes", "limit": "8", "sort": "updated", "order": "desc"}
    assert by["/api/v1/repos/issues/search"] == {"q": "notes", "limit": "8", "state": "all"}


def test_the_query_goes_on_encoded_and_cleaned_of_control_characters_and_capped(settings):
    f = Forgejo()
    c = client(on(settings), httpx.MockTransport(f))
    c.get("/api/search/git?q=" + "a%26limit%3D500%20b%00c%0Ad", headers=API)
    q = {x.url.path: x.url.params["q"] for x in f.calls}
    assert set(q.values()) == {"a&limit=500 bcd"}
    assert all(x.url.params["limit"] == "8" for x in f.calls)   # (a limit typed in the text is text)
    f.calls.clear()
    c.get("/api/search/git?q=" + "z" * 500, headers=API)
    assert {len(x.url.params["q"]) for x in f.calls} == {64}


def test_rows_are_reduced_to_what_the_search_shows_and_odd_ones_dropped(settings):
    f = Forgejo(repos=[repo("devos/notes", "line\nbreak \x1b[31m" + "d" * 500, private=True), repo("devos/old", archived=True),
                       repo("../etc/passwd"), repo("devos/.."), repo("devos/x.git"), {"full_name": 5}, "x", None],
                issues=[issue(1, "Title‮" + "t" * 500), issue(2, "A PR", pr=True, state="closed"), issue(0, "zero"), issue(3, "other", repo_name="a b/c"),
                        {"number": True, "title": "bool", "repository": {"full_name": "a/b"}}, {"number": 4, "title": "", "repository": {"full_name": "devos/notes"}}, 7])
    r = client(on(settings), httpx.MockTransport(f)).get("/api/search/git?q=x", headers=API).json()
    assert [x["repo"] for x in r["repos"]] == ["devos/notes", "devos/old"]
    assert r["repos"][0]["private"] is True and r["repos"][1]["archived"] is True
    d = r["repos"][0]["description"]
    assert len(d) == gitsearch.MAX_DESCRIPTION and "\n" not in d and "\x1b" not in d
    assert [(x["number"], x["pr"], x["state"]) for x in r["issues"]] == [(1, False, "open"), (2, True, "closed"), (4, False, "open")]
    assert len(r["issues"][0]["title"]) == gitsearch.MAX_TITLE and "‮" in r["issues"][0]["title"]   # (the page makes it visible)
    assert r["issues"][2]["title"] == "#4"
    # nothing else of the git server's answer is passed on (no body, no addresses)
    assert set(r["issues"][0]) == {"repo", "number", "title", "pr", "state"} and set(r["repos"][0]) == {"repo", "description", "private", "archived"}
    assert "evil.example" not in json.dumps(r) and "never shown" not in json.dumps(r)


def test_results_are_capped_per_group(settings):
    f = Forgejo(repos=[repo(f"devos/r{i}") for i in range(40)], issues=[issue(i + 1, f"i{i}") for i in range(40)])
    r = client(on(settings), httpx.MockTransport(f)).get("/api/search/git?q=r", headers=API).json()
    assert len(r["repos"]) == gitsearch.MAX_REPOS == 8 and len(r["issues"]) == gitsearch.MAX_ISSUES == 8


# --- timeouts and errors: an answer with "error", never a failed request, never the token ---

@pytest.mark.parametrize("make,words", [
    (lambda req: (_ for _ in ()).throw(httpx.ConnectError("refused " + TOKEN)), "did not answer (ConnectError)"),
    (lambda req: (_ for _ in ()).throw(httpx.ReadTimeout("slow " + TOKEN)), "did not answer (ReadTimeout)"),
    (lambda req: httpx.Response(401, text=TOKEN), "refused the portal's search token (HTTP 401)"),
    (lambda req: httpx.Response(403, text="forbidden " + TOKEN), "refused the portal's search token (HTTP 403)"),
    (lambda req: httpx.Response(500, text="boom " + TOKEN), "answered HTTP 500"),
    (lambda req: httpx.Response(302, headers={"location": "http://evil.example/"}), "answered HTTP 302"),
    (lambda req: httpx.Response(200, text="<html>" + TOKEN), "not JSON"),
    (lambda req: httpx.Response(200, content=b"[" + b" " * (gitsearch.MAX_ANSWER + 1) + b"]"), "too large"),
    (lambda req: httpx.Response(200, json={"ok": True, "data": "x"}), "not what a search gives"),
    (lambda req: httpx.Response(200, json={"no": "data"}), "not what a search gives"),
])
def test_a_failure_is_an_answer_with_an_error_and_empty_lists(settings, make, words):
    c = client(on(settings), httpx.MockTransport(make))
    r = c.get("/api/search/git?q=x", headers=API)
    assert r.status_code == 200 and words in r.json()["error"] and r.json()["repos"] == [] and r.json()["issues"] == [], r.text
    assert TOKEN not in r.text and "evil.example" not in r.text


def test_the_timeouts_are_short():
    assert gitsearch.TIMEOUT.connect <= 2 and gitsearch.TIMEOUT.read <= 5


def test_either_ask_failing_fails_the_search(settings):
    def one(request):
        return httpx.Response(500) if request.url.path.endswith("issues/search") else httpx.Response(200, json={"data": [repo("a/b")]})
    r = client(on(settings), httpx.MockTransport(one)).get("/api/search/git?q=x", headers=API).json()
    assert "HTTP 500" in r["error"] and r["repos"] == []


def test_no_token_yet_is_said_and_nothing_is_asked(settings):
    f = Forgejo()
    r = client(replace(settings, git=True, git_token=""), httpx.MockTransport(f)).get("/api/search/git?q=x", headers=API).json()
    assert "no search token" in r["error"] and f.calls == []


# --- the session, the header, the query, the pace ---

def test_the_endpoint_needs_the_portal_session_and_the_custom_header(settings):
    f = Forgejo()
    s = on(settings)
    anon = client(s, httpx.MockTransport(f), login=False)
    assert anon.get("/api/search/git?q=x", headers=API).status_code == 401
    assert anon.get("/api/search/git?q=x").status_code == 401
    c = client(s, httpx.MockTransport(f))
    assert c.get("/api/search/git?q=x").status_code == 400   # the custom header
    assert c.get("/api/search/git?q=x", headers={**API, "Origin": "http://evil.example"}).status_code == 200   # (a read: like the chat search)
    assert len([x for x in f.calls if x.url.host == "caddy"]) == 2   # (the one that was refused, and anonymous ones, asked nothing)
    f.calls.clear()
    assert anon.post("/api/search/git?q=x", headers=API).status_code in (401, 405) and [x for x in f.calls if x.url.host == "caddy"] == []


def test_the_query_is_required(settings):
    f = Forgejo()
    c = client(on(settings), httpx.MockTransport(f))
    for q in ("", "%20%20", "%00"):
        r = c.get(f"/api/search/git?q={q}", headers=API)
        assert r.status_code == 400 and r.json()["repos"] == [], q
    assert c.get("/api/search/git", headers=API).status_code == 400
    assert f.calls == []


def test_a_few_searches_a_second_at_most(settings):
    c = client(on(settings), httpx.MockTransport(Forgejo()))
    codes = [c.get(f"/api/search/git?q=t{i}", headers=API).status_code for i in range(6)]
    assert codes[:4] == [200] * 4 and codes[-1] == 429


# --- the git server being off ---

def test_with_the_git_server_off_nothing_is_asked_and_the_answer_says_so(settings):
    f = Forgejo()
    # off in the environment: even a token left in .env is dropped by the config
    s = from_env(_env(LOCALGIT_MODE="off", LOCALGIT_READ_TOKEN=TOKEN))
    assert s.git is False and s.git_token == ""
    r = client(s, httpx.MockTransport(f)).get("/api/search/git?q=x", headers=API)
    assert r.status_code == 200 and r.json() == {"off": True, "repos": [], "issues": []}
    assert [x for x in f.calls if x.url.host == "caddy"] == []
    # and a direct use of the client says it too
    with pytest.raises(gitsearch.SearchError, match="off"):
        import asyncio
        asyncio.run(gitsearch.GitSearch(settings).search(httpx.AsyncClient(transport=httpx.MockTransport(f)), "x"))


def test_the_remote_site_has_no_git_page_and_no_search(settings):
    s = on(settings, remote_mode="tailscale", remote_host="bn.tail1234.ts.net")
    assert s.git_on(False) is True and s.git_on(True) is False
    assert "git" in s.app_urls(False) and "git" not in s.app_urls(True)


# --- the token never leaves the portal ---

def test_the_token_is_in_no_answer_page_or_static_file(settings):
    f = Forgejo()
    s = on(settings)
    c = client(s, httpx.MockTransport(f))
    bodies = [c.get("/").text, c.get("/api/summary", headers=API).text, c.get("/api/search/git?q=notes", headers=API).text,
              c.get("/api/search/index", headers=API).text, c.get("/api/answers", headers=API).text, c.get("/api/settings", headers=API).text,
              c.get("/api/search/git?q=x", headers={}).text, c.get("/login").text]
    assert all(TOKEN not in b for b in bodies)
    assert TOKEN not in repr(s) and TOKEN not in str(s)
    # the static files are the same for everyone: a file may not name the variable's value, and no script reads it from anywhere
    for p in STATIC.rglob("*"):
        if p.is_file() and p.suffix in (".js", ".html", ".css", ".json", ".svg", ".webmanifest"):
            assert TOKEN not in p.read_text(encoding="utf-8", errors="replace"), p
    for p in (STATIC / "git.js", STATIC / "search.js", STATIC / "app.js", STATIC / "index.html"):
        assert "LOCALGIT_READ_TOKEN" not in p.read_text(encoding="utf-8")
    # the browser's own requests carry no Authorization of the git server's kind
    assert "authorization" not in {k.lower() for k in c.get("/api/search/git?q=x", headers=API).headers}


def test_an_error_text_never_holds_the_token_or_the_address_it_was_sent_to(settings):
    def boom(request):
        raise httpx.ConnectError(f"{request.url} {request.headers['authorization']}")
    r = client(on(settings), httpx.MockTransport(boom)).get("/api/search/git?q=x", headers=API)
    assert TOKEN not in r.text and "caddy" not in r.text and "8099" not in r.text


# --- the config and the page that carry it ---

def _env(**kw):
    e = {"PORTAL_SECRET": "s" * 64, "PORTAL_PASSWORD": "correct horse", "PORTAL_HOST": "devos-ade.localhost"}
    e.update(kw)
    return e


def test_config_reads_the_mode_the_host_the_api_and_the_token_from_the_environment():
    s = from_env(_env(LOCALGIT_MODE="on", LOCALGIT_READ_TOKEN=f" {TOKEN} ", LOCALGIT_API_URL="http://caddy:8099/", GIT_HOST="Code-Git.devos-ade.localhost"))
    assert s.git is True and s.git_token == TOKEN and s.git_api_url == "http://caddy:8099"
    assert s.origin("git") == "http://code-git.devos-ade.localhost" and s.app_urls()["git"] == "http://code-git.devos-ade.localhost/"
    assert "http://code-git.devos-ade.localhost" in s.app_origins()
    d = from_env(_env(LOCALGIT_MODE="on"))
    assert d.app_urls()["git"] == "http://git.devos-ade.localhost/" and d.git_token == "" and d.git_code_indexer is False
    assert from_env(_env(LOCALGIT_MODE="on", LOCALGIT_INDEXER="true")).git_code_indexer is True
    for off in ({}, {"LOCALGIT_MODE": "off"}, {"LOCALGIT_MODE": ""}, {"LOCALGIT_MODE": "yes"}):
        o = from_env(_env(**off, LOCALGIT_READ_TOKEN=TOKEN, LOCALGIT_INDEXER="true"))
        assert o.git is False and o.git_token == "" and o.git_code_indexer is False and "git" not in o.app_urls()
        assert not any("git." in x for x in o.app_origins())


def test_the_page_carries_the_git_state_and_frames_the_git_host(settings):
    c = client(on(settings), httpx.MockTransport(Forgejo()))
    r = c.get("/")
    assert '<meta name="bn-git" content="{&quot;enabled&quot;: true, &quot;here&quot;: true, &quot;code_search&quot;: false}">' in r.text
    assert '"git": "http://git.devos-ade.localhost/"' in r.text.replace("&quot;", '"')
    assert "http://git.devos-ade.localhost" in r.headers["content-security-policy"].split("frame-src")[1].split(";")[0]
    assert '<script src="/static/git.js" defer></script>' in r.text
    off = client(settings).get("/")
    assert '&quot;enabled&quot;: false, &quot;here&quot;: false' in off.text
    assert "git.devos-ade.localhost" not in off.headers["content-security-policy"]


def test_the_search_page_asks_the_git_endpoint_from_two_characters_and_builds_text_only():
    js = (STATIC / "search.js").read_text(encoding="utf-8")
    assert "/api/search/git?q=${encodeURIComponent(text)}" in js and "waitT = setTimeout(() => { askCode(q); askChats(q); askGit(q); }, WAIT_MS)" in js
    assert "if (q.length < MIN_ASYNC)" in js and "const MIN_ASYNC = 2" in js
    for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"):
        assert sink not in js, sink
    # a failed search is one "Search in Git" entry that opens the Git tab
    assert 'title: "Search in Git"' in js and 'window.bnGit.open("")' in js
    # only where the Git tab is on here
    assert "if (!gitHere()) return;" in js


def test_git_js_builds_text_only_and_loads_only_the_known_shapes():
    js = (STATIC / "git.js").read_text(encoding="utf-8")
    for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"):
        assert sink not in js, sink
    assert 'document.addEventListener("bn:place"' in js and "gitUrl(d.place, appUrl(\"git\"))" in js


def test_the_off_page_leads_to_the_setting_the_setup_links_name():
    js = (STATIC / "git.js").read_text(encoding="utf-8")
    assert 'const SWITCH = "#settings/LOCALGIT";' in js
    table = Path(os.environ.get("BN_REPO_DIR") or Path(__file__).resolve().parents[2]) / "catalog" / "setup-links.tsv"
    if table.exists():
        rows = {f[0]: f for f in (l.split("\t") for l in table.read_text(encoding="utf-8").splitlines() if l and not l.startswith("#"))}
        assert rows["git-off"][1] == "setting:LOCALGIT" and "Local git server" in rows["git-off"][2]


def test_the_phones_more_sheet_names_git_in_its_search_tagline():
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    assert "Settings, Code sessions, chats, Git, the walkthrough, docs" in html
