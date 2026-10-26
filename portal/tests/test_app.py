from dataclasses import replace

import httpx
import pytest
from starlette.testclient import TestClient

from portal.app import STATIC, create_app
from portal.security import COOKIE, LoginThrottle

ORIGIN = {"Origin": "http://bedrock-now.localhost"}
API = {"X-Requested-With": "bedrock-now"}


def offline(request):
    raise httpx.ConnectError("offline in tests")


@pytest.fixture
def client(settings):
    app = create_app(settings, transport=httpx.MockTransport(offline))
    with TestClient(app, base_url="http://bedrock-now.localhost", follow_redirects=False) as c:
        yield c


def login(client, password="correct horse", next_url="", headers=ORIGIN):
    return client.post("/login", data={"password": password, "next": next_url}, headers=headers)


def test_healthz_and_login_page_are_public(client):
    assert client.get("/healthz").text == "ok"
    r = client.get("/login")
    assert r.status_code == 200 and 'name="password"' in r.text
    assert r.headers["cache-control"] == "no-store"
    assert "frame-ancestors 'none'" in r.headers["content-security-policy"]
    assert r.headers["x-frame-options"] == "DENY"


def test_login_page_escapes_next(client):
    r = client.get("/login", params={"next": '/"><script>x</script>'})
    assert "<script>x" not in r.text
    assert "&quot;&gt;&lt;script&gt;" in r.text


def test_login_sets_scoped_session_cookie(client):
    r = login(client, next_url="http://chat.bedrock-now.localhost/")
    assert r.status_code == 303
    assert r.headers["location"] == "http://chat.bedrock-now.localhost/"
    c = r.headers["set-cookie"]
    assert c.startswith(f"{COOKIE}=")
    for part in ("HttpOnly", "SameSite=strict", "Domain=bedrock-now.localhost", "Path=/", "Max-Age=2592000"):
        assert part.lower() in c.lower()
    assert "secure" not in c.lower()


def test_login_refuses_open_redirect(client):
    r = login(client, next_url="http://evil.com/")
    assert r.status_code == 303 and r.headers["location"] == "/"


def test_login_is_post_only_with_same_origin(client):
    assert login(client, headers={"Origin": "http://evil.com"}).status_code == 403
    assert login(client, headers={}).status_code == 403
    assert login(client, headers={"Origin": "http://chat.bedrock-now.localhost"}).status_code == 403
    assert login(client, headers={"Referer": "http://bedrock-now.localhost/login"}).status_code == 303
    assert client.put("/login").status_code == 405


def test_wrong_password_then_throttled(client):
    for _ in range(LoginThrottle.FREE):
        r = login(client, password="nope")
    assert r.status_code == 401 and "That password is not right." in r.text and "./stack password --show" in r.text
    r = login(client)  # even the right password waits while locked
    assert r.status_code == 429 and int(r.headers["retry-after"]) > 0
    assert COOKIE not in r.headers.get("set-cookie", "")


def test_verify_without_session(client):
    nav = {"Accept": "text/html,application/xhtml+xml", "X-Forwarded-Method": "GET",
           "X-Forwarded-Host": "chat.bedrock-now.localhost", "X-Forwarded-Uri": "/c/1?x=2"}
    r = client.get("/auth/verify", headers=nav)
    assert r.status_code == 302
    assert r.headers["location"] == "http://bedrock-now.localhost/login?next=http%3A%2F%2Fchat.bedrock-now.localhost%2Fc%2F1%3Fx%3D2"
    assert "x-portal-user" not in r.headers
    r = client.get("/auth/verify", headers={**nav, "X-Forwarded-Host": "evil.com"})
    assert r.headers["location"] == "http://bedrock-now.localhost/login"
    assert client.get("/auth/verify", headers={"Accept": "application/json"}).status_code == 401
    assert client.get("/auth/verify", headers={**nav, "X-Forwarded-Method": "POST"}).status_code == 401


def test_verify_ignores_client_supplied_user_header(client):
    r = client.get("/auth/verify", headers={"X-Portal-User": "admin@example.com", "Accept": "application/json"})
    assert r.status_code == 401 and "x-portal-user" not in r.headers


def test_verify_with_session_names_the_admin(client):
    login(client)
    r = client.get("/auth/verify")
    assert r.status_code == 200 and r.headers["x-portal-user"] == "admin@example.com"


def test_forged_cookie_is_rejected(client):
    client.cookies.set(COOKIE, "eyJ2IjoxfQ.forged.sig", domain="bedrock-now.localhost")
    assert client.get("/auth/verify").status_code == 401


def test_logout_revokes_sessions(client):
    login(client)
    token = client.cookies.get(COOKIE)
    assert client.post("/logout", headers={"Origin": "http://evil.com"}).status_code == 403
    r = client.post("/logout", headers=ORIGIN)
    assert r.status_code == 303 and r.headers["location"] == "http://bedrock-now.localhost/login"
    client.cookies.set(COOKIE, token, domain="bedrock-now.localhost")  # a copied cookie is dead too
    assert client.get("/auth/verify").status_code == 401


def _app_client(settings):
    return TestClient(create_app(settings, transport=httpx.MockTransport(offline)),
                      base_url="http://bedrock-now.localhost", follow_redirects=False)


def test_logout_survives_a_portal_restart(settings, tmp_path):
    s = replace(settings, state_dir=tmp_path / "state")
    (tmp_path / "state").mkdir()
    with _app_client(s) as c:
        login(c)
        token = c.cookies.get(COOKIE)
        assert c.post("/logout", headers=ORIGIN).status_code == 303
    with _app_client(s) as c:  # a new process: the container restarted
        c.cookies.set(COOKIE, token, domain="bedrock-now.localhost")
        assert c.get("/auth/verify").status_code == 401
        login(c)
        assert c.get("/auth/verify").status_code == 200


FORM = {**ORIGIN, "Content-Type": "application/x-www-form-urlencoded"}


def test_login_refuses_oversized_body(client):
    r = client.post("/login", content=b"password=" + b"a" * 9000, headers=FORM)
    assert r.status_code == 413


def test_login_refuses_body_without_content_length(client):
    def chunked():
        yield b"password=correct+horse"
    r = client.post("/login", content=chunked(), headers=FORM)
    assert r.status_code == 411
    assert COOKIE not in r.cookies


def test_login_refuses_malformed_content_length(client):
    r = client.post("/login", content=b"password=correct+horse", headers={**FORM, "Content-Length": "+22"})
    assert r.status_code == 411


def test_index_requires_session(client):
    r = client.get("/")
    assert r.status_code == 302 and r.headers["location"] == "http://bedrock-now.localhost/login"
    login(client)
    r = client.get("/")
    assert r.status_code == 200 and 'id="home"' in r.text
    csp = r.headers["content-security-policy"]
    assert "frame-src http://chat.bedrock-now.localhost http://admin.bedrock-now.localhost http://files.bedrock-now.localhost" in csp
    assert "script-src 'self'" in csp and "unsafe-inline" not in csp


def test_static_assets_load(client):
    for path in ("/static/app.js", "/static/app.css", "/static/login.css", "/static/logo.svg", "/favicon.svg"):
        assert client.get(path).status_code == 200, path


def test_static_assets_are_revalidated_so_an_update_never_mixes_old_and_new(client):
    r = client.get("/static/app.js")
    assert r.headers["cache-control"] == "no-cache" and r.headers.get("etag")
    again = client.get("/static/app.js", headers={"If-None-Match": r.headers["etag"]})
    assert again.status_code == 304 and again.headers["cache-control"] == "no-cache"
    assert client.get("/static/missing.js").status_code == 404


PNG = b"\x89PNG\r\n\x1a\n"


def test_icon_route(client, settings):
    for p in ("claude-color.png", "or/grok.png"):
        (settings.catalog_dir / "icons" / p).parent.mkdir(parents=True, exist_ok=True)
        (settings.catalog_dir / "icons" / p).write_bytes(PNG)
    r = client.get("/icons/claude-color.png")
    assert r.status_code == 200 and r.headers["content-type"] == "image/png" and r.content == PNG
    assert client.get("/icons/or/grok.png").status_code == 200
    assert client.get("/icons/missing.png").status_code == 404
    assert client.get("/icons/..%2Fdisplay.tsv").status_code == 404

def test_api_requires_session_and_header(client):
    assert client.get("/api/logins", headers=API).status_code == 401
    login(client)
    assert client.get("/api/logins").status_code == 400
    r = client.get("/api/logins", headers=API)
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    d = r.json()
    assert d["admin"] == {"url": "http://admin.bedrock-now.localhost/ui/", "username": "admin", "password": "ui-pass",
                          "manual": "http://admin.bedrock-now.localhost/ui/login/?sso=off"}
    assert d["files"]["username"] == "bn-access" and d["files"]["password"] == "rustfs-secret"


def test_secrets_never_in_html(client):
    login(client)
    for path in ("/", "/login", "/static/app.js"):
        body = client.get(path).text
        for secret in ("ui-pass", "rustfs-secret", "sk-master", "sk-cc", "correct horse"):
            assert secret not in body


def test_summary_survives_everything_down(client):
    login(client)
    d = client.get("/api/summary", headers=API).json()
    assert {s["id"] for s in d["services"]} == {"litellm", "postgres", "open-webui", "rustfs", "shared-mcp"}
    assert not any(s["ok"] for s in d["services"])
    assert d["spend"]["total_30d"] is None and "did not answer" in d["spend"]["total_error"]
    assert "sk-" not in str(d)


def test_cookie_domain_follows_portal_host(settings):
    app = create_app(replace(settings, host="bn-dev.localhost", port=8800))
    with TestClient(app, base_url="http://bn-dev.localhost:8800", follow_redirects=False) as c:
        r = c.post("/login", data={"password": "correct horse"}, headers={"Origin": "http://bn-dev.localhost:8800"})
        assert r.status_code == 303 and "domain=bn-dev.localhost" in r.headers["set-cookie"].lower()


def test_price_update_task_runs_only_when_enabled(settings, monkeypatch):
    from portal import prices
    started = []

    async def fake_loop(paths, region, **kw):
        started.append((paths.prices_dir, region))

    monkeypatch.setattr(prices, "daily_loop", fake_loop)
    for enabled in (False, True):
        app = create_app(replace(settings, price_updates=enabled, aws_region="eu-west-1"), transport=httpx.MockTransport(offline))
        with TestClient(app, base_url="http://bedrock-now.localhost") as c:
            assert c.get("/healthz").text == "ok"
    assert started == [(settings.prices_dir, "eu-west-1")]


# --- where the password lives (PORTAL_ENV_FILE / PORTAL_PROJECT, passed by ./stack at compose time) ---

def _where_client(settings, **kw):
    return TestClient(create_app(replace(settings, **kw), transport=httpx.MockTransport(offline)),
                      base_url="http://bedrock-now.localhost", follow_redirects=False)


FORGOT = "Forgot it? Run <code>./stack password --show</code> in"


def test_wrong_password_says_so_once_and_the_hint_names_the_command_and_this_install(settings):
    with _where_client(settings, env_file="~/code/bn-dev/.env", project="bn-dev") as c:
        r = login(c, password="nope")
        assert r.status_code == 401
        # the error says it plainly; where the password comes from is said once, in the hint: the command, not a file
        assert '<p class="error" id="login-error" role="alert">That password is not right.</p>' in r.text
        assert r.text.count("~/code/bn-dev") == 1 and ".env" not in r.text and "PORTAL_PASSWORD" not in r.text
        hint = f"{FORGOT} <code>~/code/bn-dev</code> (project bn-dev). You stay signed in for 30 days."
        assert hint in r.text and hint in c.get("/login").text
        # the field names the error and the hint; without login.js its Show button stays hidden
        assert 'aria-describedby="login-error login-hint"' in r.text and 'aria-describedby="login-hint"' in c.get("/login").text
        assert '<button type="button" class="pw-toggle" id="pw-toggle" aria-controls="password" hidden>Show</button>' in r.text
        assert '<script src="/static/login.js' in r.text


def test_install_location_is_escaped(settings):
    with _where_client(settings, env_file="~/<b>x</b>/.env", project="p<i>") as c:
        r = login(c, password="nope")
        assert "<b>x</b>" not in r.text and "&lt;b&gt;x&lt;/b&gt;" in r.text and "p&lt;i&gt;" in r.text


def test_wrong_password_falls_back_without_a_location(client):
    r = login(client, password="nope")
    assert f"{FORGOT} your DevOS ADE folder." in r.text and "That password is not right." in r.text
    assert "{{" not in client.get("/login").text


def test_the_login_script_is_the_show_button_only():
    js = (STATIC / "login.js").read_text()
    assert "fetch" not in js and "localStorage" not in js and "innerHTML" not in js


def test_from_env_reads_the_install_location():
    from portal.config import from_env
    s = from_env({"PORTAL_PASSWORD": "p", "PORTAL_SECRET": "s" * 32, "PORTAL_ENV_FILE": " ~/bn/.env ", "PORTAL_PROJECT": "bn-dev"})
    assert (s.env_file, s.project) == ("~/bn/.env", "bn-dev")
    assert s.install_folder() == "~/bn"
    s = from_env({"PORTAL_PASSWORD": "p", "PORTAL_SECRET": "s" * 32})
    assert s.install_folder() == ""
    s = from_env({"PORTAL_PASSWORD": "p", "PORTAL_SECRET": "s" * 32, "PORTAL_ENV_FILE": "/elsewhere/my.env"})
    assert s.install_folder() == ""   # (an env file elsewhere: the generic words)


def test_favicon_ico_is_public_and_the_png(client):
    r = client.get("/favicon.ico", follow_redirects=False)
    assert r.status_code == 200 and r.headers["content-type"] == "image/png" and r.headers["cache-control"] == "no-cache"


# --- the error pages (UX-10): the sign-in card's design, a way back, nothing of the request shown back ---

def _strict(r):
    csp = r.headers["content-security-policy"]
    assert "default-src 'none'" in csp and "script-src" not in csp and "frame-ancestors 'none'" in csp and "form-action 'none'" in csp
    assert r.headers["x-frame-options"] == "DENY" and r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["cache-control"] == "no-store" and r.headers["referrer-policy"] == "no-referrer"
    assert "<script" not in r.text and "{{" not in r.text


def test_a_page_that_is_not_there_is_the_404_page_with_home_and_search(client):
    r = client.get("/no-such-page/%3Cscript%3E?q=%22%3E%3Cb%3Ex", headers={"Accept": "text/html,application/xhtml+xml"})
    assert r.status_code == 404 and r.headers["content-type"].startswith("text/html")
    _strict(r)
    assert "This page does not exist" in r.text and "404 · Not found" in r.text
    assert '<a class="pill-link primary" href="/">Go to Home</a>' in r.text and 'href="/?search">Search</a>' in r.text
    assert "no-such-page" not in r.text and "<b>x" not in r.text and "&lt;b&gt;" not in r.text   # (nothing of the address)
    for f in ("tokens.css", "fonts.css", "login.css", "logo.svg"):   # the sign-in page's own files: the same design
        assert f'"/static/{f}' in r.text
    # anything but a page load keeps the plain words
    for path, accept in (("/api/no-such", "application/json"), ("/static/no-such.css", "text/css,*/*;q=0.1"), ("/nope", "*/*")):
        r = client.get(path, headers={"Accept": accept})
        assert r.status_code == 404 and r.text == "Not Found" and r.headers["x-content-type-options"] == "nosniff", path
    assert client.post("/no-such-page", headers={"Accept": "text/html"}).text == "Not Found"


def test_an_unknown_host_names_the_portal_and_nothing_it_was_asked(settings):
    with _where_client(settings, port=8800) as c:
        r = c.get("/auth/unknown-host?site=local", headers={"Host": "evil.example:8800", "Accept": "text/html", "X-Forwarded-Host": "evil.example"})
        assert r.status_code == 404
        _strict(r)
        assert "Not an address of DevOS ADE" in r.text and "evil.example" not in r.text
        assert '<a class="pill-link primary" href="http://bedrock-now.localhost:8800/">Go to DevOS ADE</a>' in r.text
        assert "On this computer, DevOS ADE is at <code>http://bedrock-now.localhost:8800</code>." in r.text
        assert 'href="/static/fonts.css"' in r.text   # (Caddy hands these over under that name too: same origin, the fonts load)
        # the remote site's catch-all names the remote portal, once remote access is on; before, this computer's
        assert "http://bedrock-now.localhost:8800/" in c.get("/auth/unknown-host?site=remote").text
        assert c.post("/auth/unknown-host?site=local").status_code == 405
    rs = replace(settings, remote_mode="tailscale", remote_host="bn.tail1234.ts.net")
    with _where_client(rs) as c:
        r = c.get("/auth/unknown-host?site=remote")
        assert 'href="https://bn.tail1234.ts.net/"' in r.text and "Over remote access, DevOS ADE is at" in r.text
