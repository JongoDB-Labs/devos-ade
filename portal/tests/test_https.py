"""The portal over HTTPS on this computer (JON-976; lib/tls.sh): PORTAL_HTTPS makes every local origin https (the origin the
portal accepts, the CSP's frame-ancestors, the previews' hosts), the session cookie Secure, and Home offers it once to an
install that never chose and says, once, that the address changed."""

import json
import time
from dataclasses import replace

import httpx
import pytest
from starlette.testclient import TestClient

from portal import activity
from portal.app import create_app
from conftest import PASSWORD_HASH
from portal.config import from_env
from portal.security import COOKIE, cookie_params, unlock_cookie_params

HTTPS_ORIGIN = {"Origin": "https://devos-ade.localhost:8800"}


def offline(request):
    raise httpx.ConnectError("offline in tests")


@pytest.fixture
def https(settings):
    return replace(settings, port=8800, https_raw="true")


def test_the_origins_follow_the_scheme(settings):
    plain = replace(settings, port=8800)
    assert plain.origin() == "http://devos-ade.localhost:8800" and plain.scheme == "http" and not plain.https
    assert replace(settings, port=80).origin("chat") == "http://chat.devos-ade.localhost"
    s = replace(settings, port=8800, https_raw="true")
    assert s.https and s.origin() == "https://devos-ade.localhost:8800"
    assert s.origin("chat") == "https://chat.devos-ade.localhost:8800"
    # https has no ':80' to leave out: port 80 is a port like another there
    assert replace(settings, port=80, https_raw="TRUE").origin() == "https://devos-ade.localhost:80"
    # the remote site is https either way, and keeps its own name
    assert replace(s, remote_mode="tailscale", remote_host="bn.tail1234.ts.net").origin(remote=True) == "https://bn.tail1234.ts.net"
    assert s.app_urls()["chat"].startswith("https://chat.devos-ade.localhost:8800/")
    assert all(o.startswith("https://") for o in s.portal_origins() + s.app_origins())


def test_the_environment_decides(settings):
    env = {"PORTAL_SECRET": "s" * 64, "PORTAL_PASSWORD_HASH": PASSWORD_HASH, "PORTAL_HTTPS": "true", "PORTAL_PORT": "8800"}
    assert from_env(env).https and from_env(env).origin() == "https://devos-ade.localhost:8800"
    for v in ("", "false", "0", "no", "nonsense"):
        assert not from_env({**env, "PORTAL_HTTPS": v}).https
    assert from_env({**env, "PORTAL_HTTPS": ""}).https_raw == "" and from_env({**env, "PORTAL_HTTPS": " false "}).https_raw == "false"


def test_the_session_cookie_is_secure_only_over_https(settings, https):
    assert cookie_params(settings, False)["secure"] is False
    assert cookie_params(https, False) == {"key": COOKIE, "domain": "devos-ade.localhost", "secure": True}
    assert cookie_params(https, False, carry=True)["secure"] is True
    assert unlock_cookie_params("terminal", False)["secure"] is False
    assert unlock_cookie_params("terminal", False, True)["secure"] is True
    assert unlock_cookie_params("code", True)["secure"] is True


def test_login_over_https_sets_a_secure_cookie_and_accepts_only_the_https_origin(https):
    with TestClient(create_app(https, transport=httpx.MockTransport(offline)), base_url="https://devos-ade.localhost:8800", follow_redirects=False) as c:
        r = c.post("/login", data={"password": "correct horse"}, headers={"Origin": "http://devos-ade.localhost:8800"})
        assert r.status_code == 403   # (the old address' origin is no longer the portal's)
        r = c.post("/login", data={"password": "correct horse"}, headers=HTTPS_ORIGIN)
        assert r.status_code == 303
        cookie = r.headers["set-cookie"].lower()
        assert "secure" in cookie and "domain=devos-ade.localhost" in cookie and "samesite=strict" in cookie and "httponly" in cookie
        # the CSP's frame sources and form targets are https origins
        csp = c.get("/").headers["content-security-policy"]
        assert "https://chat.devos-ade.localhost:8800" in csp and "http://" not in csp


def test_login_over_http_is_not_secure(settings):
    with TestClient(create_app(settings, transport=httpx.MockTransport(offline)), base_url="http://devos-ade.localhost", follow_redirects=False) as c:
        r = c.post("/login", data={"password": "correct horse"}, headers={"Origin": "http://devos-ade.localhost"})
        assert r.status_code == 303 and "secure" not in r.headers["set-cookie"].lower()


def test_home_offers_https_once_to_an_install_that_never_chose(settings, tmp_path):
    s = replace(settings, status_dir=tmp_path, port=8800, https_raw="")
    (offer,) = [x for x in activity.items(s, False) if x["kind"] == "https"]
    assert offer["id"] == "https-offer" and offer["data"] == {"offer": True} and offer["notify"] is False
    assert offer["title"] == "Serve the portal over HTTPS" and offer["link"] == "#settings/PORTAL_HTTPS"
    assert "https://devos-ade.localhost:8800" in offer["text"]
    # declined (false) or on (true): not offered again
    assert not [x for x in activity.items(replace(s, https_raw="false"), False) if x["kind"] == "https"]
    assert not [x for x in activity.items(replace(s, https_raw="true"), False) if x["kind"] == "https"]


def test_the_switch_is_announced_once_and_for_two_weeks(settings, tmp_path):
    now = int(time.time())
    s = replace(settings, status_dir=tmp_path, port=8800, https_raw="true")
    (tmp_path / "https-switched.json").write_text(json.dumps({"at": now - 60, "https": True}))
    (it,) = [x for x in activity.items(s, False) if x["kind"] == "https"]
    assert it["id"] == f"https-switched:{now - 60}" and it["title"] == "The portal's address changed"
    assert "https://devos-ade.localhost:8800/" in it["text"] and "sign in again" in it["text"].lower()
    assert "install it again from the new one" in it["text"]
    # ... after two weeks, or when the record is about the other direction, or odd, it is gone
    (tmp_path / "https-switched.json").write_text(json.dumps({"at": now - 15 * 86400, "https": True}))
    assert not [x for x in activity.items(s, False) if x["kind"] == "https"]
    (tmp_path / "https-switched.json").write_text(json.dumps({"at": now - 60, "https": False}))
    assert not [x for x in activity.items(s, False) if x["kind"] == "https"]
    (tmp_path / "https-switched.json").write_text("{not json")
    assert not [x for x in activity.items(s, False) if x["kind"] == "https"]
    # off again: said once as well, with the plain address
    off = replace(s, https_raw="false")
    (tmp_path / "https-switched.json").write_text(json.dumps({"at": now - 60, "https": False}))
    (it,) = [x for x in activity.items(off, False) if x["kind"] == "https"]
    assert "plain HTTP again at http://devos-ade.localhost:8800/" in it["text"]


def test_the_settings_row_and_its_apply_step_exist():
    from pathlib import Path
    repo = Path(__file__).resolve().parents[2]
    rows = {l.split("\t")[0]: l.split("\t") for l in (repo / "catalog" / "settings.tsv").read_text().splitlines() if l and not l.startswith("#")}
    k = rows["PORTAL_HTTPS"]
    assert k[1] == "account" and k[3] == "edit" and k[4] == "bool" and k[5] == "https" and k[6] == "Serve the portal over HTTPS"
    lay = [l for l in (repo / "catalog" / "settings-layout.tsv").read_text().splitlines() if l.startswith("PORTAL_HTTPS\t")]
    assert len(lay) == 1 and lay[0].split("\t")[1:4] == ["account", "main", "-"]
