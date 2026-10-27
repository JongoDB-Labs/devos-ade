"""Export to Files (portal/codeexport.py, /api/code-export): the Code page's zip is streamed to RustFS's own bucket with the
key pair the portal holds — only a zip, only a safe name, length-checked, capped, one at a time, behind the session."""

import hashlib
import io
import re
import zipfile

import httpx
import pytest
from starlette.testclient import TestClient

from portal import codeexport
from portal.app import create_app
from portal.security import COOKIE

PORTAL = "http://bedrock-now.localhost"
GUARD = {"X-Requested-With": "bedrock-now", "Origin": PORTAL}


def make_zip(n: int = 3) -> bytes:
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        for i in range(n):
            z.writestr(f"src/f{i}.txt", f"file {i}\n" * 100)
    return b.getvalue()


class Rustfs:
    """RustFS's S3 port as the portal reaches it: buckets and objects, with the signature checked in its own way."""

    def __init__(self):
        self.calls, self.objects, self.buckets, self.fail = [], {}, set(), None

    def __call__(self, request: httpx.Request) -> httpx.Response:
        assert request.url.host == "rustfs", request.url
        body = request.read()
        self.calls.append((request.method, request.url.path, dict(request.headers), len(body)))
        auth = request.headers.get("authorization", "")
        assert auth.startswith("AWS4-HMAC-SHA256 Credential=bn-access/"), auth
        assert "rustfs-secret" not in str(request.headers)
        signed = re.search(r"SignedHeaders=([^,]+)", auth).group(1).split(";")
        assert {"host", "x-amz-content-sha256", "x-amz-date"} <= set(signed)
        if self.fail:
            return httpx.Response(self.fail, text="<Error><Code>AccessDenied</Code><Message>x</Message></Error>")
        parts = request.url.path.strip("/").split("/", 1)
        if len(parts) == 1:
            if parts[0] in self.buckets:
                return httpx.Response(409, text="<Error><Code>BucketAlreadyOwnedByYou</Code></Error>")
            self.buckets.add(parts[0])
            return httpx.Response(200)
        assert parts[0] in self.buckets
        self.objects[tuple(parts)] = body
        return httpx.Response(200, headers={"ETag": '"x"'})


@pytest.fixture
def rustfs():
    return Rustfs()


@pytest.fixture
def client(settings, rustfs):
    from dataclasses import replace
    s = replace(settings, code=True, terminal=True)
    with TestClient(create_app(s, transport=httpx.MockTransport(rustfs)), base_url=PORTAL, follow_redirects=False) as c:
        r = c.post("/login", data={"password": "correct horse"}, headers={"Origin": PORTAL})
        assert r.status_code == 303, r.text
        yield c


def post(c, name, data, headers=None, **kw):
    return c.post(f"/api/code-export?name={name}", content=data, headers={**GUARD, **(headers or {})}, **kw)


def test_a_zip_lands_in_its_bucket_under_its_name(client, rustfs):
    z = make_zip()
    r = post(client, "my-app-20261027-101500.zip", z)
    assert r.status_code == 200, r.text
    assert r.json() == {"ok": True, "bucket": "code-exports", "key": "my-app-20261027-101500.zip", "size": len(z)}
    assert rustfs.objects[("code-exports", "my-app-20261027-101500.zip")] == z
    assert rustfs.buckets == {"code-exports"}, "only its own bucket is made, the stack's are not touched"
    put = [c for c in rustfs.calls if c[0] == "PUT" and c[1].count("/") == 2][0]
    assert put[2]["content-type"] == "application/zip" and put[2]["x-amz-content-sha256"] == "UNSIGNED-PAYLOAD"
    assert put[2]["content-length"] == str(len(z))
    # a second export: the bucket is there already (409 from RustFS is fine)
    assert post(client, "my-app-20261027-101501.zip", z).status_code == 200


@pytest.mark.parametrize("name", ["../x.zip", "a/b.zip", "x.txt", ".hidden.zip", "a b.zip", "x" * 200 + ".zip", "", "x.zip%00", "a.zip/../b.zip"])
def test_only_safe_names_ending_zip(client, rustfs, name):
    r = post(client, name, make_zip())
    assert r.status_code == 400, (name, r.text)
    assert not rustfs.calls and not rustfs.objects


def test_only_a_zip_with_the_announced_length(client, rustfs):
    assert post(client, "a.zip", b"not a zip at all, but long enough to pass").status_code == 400
    assert not rustfs.objects
    assert post(client, "a.zip", b"PK\x03\x04").status_code == 413, "shorter than any zip"
    too_big = codeexport.MAX_BYTES + 1
    r = client.post("/api/code-export?name=a.zip", content=b"PK\x03\x04" + b"x" * 30, headers={**GUARD, "Content-Length": str(too_big)})
    assert r.status_code in (400, 413), r.text   # (the length is checked before a byte is read)
    assert not rustfs.objects


def test_behind_the_session_and_the_page_s_own_request(client, rustfs, settings):
    z = make_zip()
    assert post(client, "a.zip", z, headers={"X-Requested-With": ""}).status_code == 400
    assert post(client, "a.zip", z, headers={"Origin": "http://evil.example"}).status_code == 403
    client.cookies.clear()
    assert post(client, "a.zip", z).status_code == 401
    assert not rustfs.calls


def test_off_when_the_code_page_is_off(settings, rustfs):
    with TestClient(create_app(settings, transport=httpx.MockTransport(rustfs)), base_url=PORTAL, follow_redirects=False) as c:
        c.post("/login", data={"password": "correct horse"}, headers={"Origin": PORTAL})
        assert post(c, "a.zip", make_zip()).status_code == 404
    assert not rustfs.calls


def test_rustfs_says_no_or_is_away(client, rustfs):
    rustfs.fail = 403
    r = post(client, "a.zip", make_zip())
    assert r.status_code == 502 and "AccessDenied" in r.json()["error"] and "rustfs-secret" not in r.text
    rustfs.fail = None

    def down(request):
        raise httpx.ConnectError("down")
    rustfs.__class__.__call__, saved = (lambda self, req: down(req)), rustfs.__class__.__call__
    try:
        r = post(client, "a.zip", make_zip())
    finally:
        rustfs.__class__.__call__ = saved
    assert r.status_code == 502 and "did not answer" in r.json()["error"]


def test_signature_v4_is_the_documented_one():
    """A known-answer check of s3_headers against the AWS documentation's PUT-object example (Signature V4)."""
    import datetime
    now = datetime.datetime(2013, 5, 24, tzinfo=datetime.timezone.utc)
    h = codeexport.s3_headers("PUT", "http://examplebucket.s3.amazonaws.com/test$file.text", "AKIA" + "IOSFODNN7EXAMPLE",
                              "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", now,
                              payload=hashlib.sha256(b"Welcome to Amazon S3.").hexdigest(),
                              extra={"x-amz-storage-class": "REDUCED_REDUNDANCY", "date": "Fri, 24 May 2013 00:00:00 GMT"})
    assert h["Authorization"].endswith("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
