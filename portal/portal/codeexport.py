"""Export to Files: a Code project's zip (made in the Code page's sandbox, downloaded by the browser from the code host,
size-capped there) lands in the Files app (RustFS) as an object of its own bucket, for the owner to download there.

The path is browser -> portal -> RustFS: the Code page runs on its own host and cannot read the Files console's
credentials (they sit in the files host's localStorage) nor call RustFS across origins, and the code container has no
way to RustFS at all (and gets none). The Code page hands the zip to the portal that frames it (postMessage, checked on
both ends: static/code.js); the portal posts it to /api/code-export, which writes it with the RustFS key pair the portal
already holds (the one it signs the Files console in with) — only ever into the bucket below, only under a name made of
safe characters ending .zip, only a zip, one at a time. The request is streamed (never held whole here) and its length
is capped. Nothing is listed, read or deleted by this route.
"""

from __future__ import annotations

import datetime
import hashlib
import hmac
import re
from collections.abc import AsyncIterator
from urllib.parse import quote, urlsplit

import httpx

from .appsso import _sign, _xml_values
from .config import Settings

BUCKET = "code-exports"                                   # shows in the Files app as its own bucket
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,115}\.zip")
# a zip of at most this size (the Code page caps the files at 200 MiB before compression; a stored zip is a little larger)
MAX_BYTES = 220 << 20
ZIP_MAGIC = (b"PK\x03\x04", b"PK\x05\x06")
REGION = "us-east-1"


class ExportError(Exception):
    def __init__(self, message: str, status: int = 502) -> None:
        super().__init__(message)
        self.status = status


def s3_headers(method: str, url: str, access: str, secret: str, now: datetime.datetime, payload: str = "UNSIGNED-PAYLOAD",
               length: int | None = None, extra: dict[str, str] | None = None) -> dict[str, str]:
    """AWS Signature V4 for an S3 request (path-style, the key's characters need no escaping: NAME) with PAYLOAD
    (UNSIGNED-PAYLOAD: the body is streamed, so never hashed here) — and EXTRA signed headers (lower-case names)."""
    parts = urlsplit(url)
    amz, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    signed = {"host": parts.netloc, "x-amz-content-sha256": payload, "x-amz-date": amz, **(extra or {})}
    if length is not None:
        signed["content-length"] = str(length)
    names = ";".join(sorted(signed))
    canonical = "\n".join([method, quote(parts.path, safe="/-_.~"), "", "".join(f"{k}:{signed[k]}\n" for k in sorted(signed)), names, payload])
    scope = f"{day}/{REGION}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    k = _sign(_sign(_sign(_sign(("AWS4" + secret).encode(), day), REGION), "s3"), "aws4_request")
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    out = {"X-Amz-Date": amz, "X-Amz-Content-Sha256": payload,
           "Authorization": f"AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={names}, Signature={sig}"}
    for key, value in (extra or {}).items():
        out[key] = value
    return out


def _why(r: httpx.Response) -> str:
    code = _xml_values(r.text[:65536]).get("Code", "")
    return f"HTTP {r.status_code}" + (f", {code}" if re.fullmatch(r"[A-Za-z]{1,64}", code) else "")


async def ensure_bucket(http: httpx.AsyncClient, s: Settings, clock=None) -> None:
    """The bucket exists (made when it does not; the stack's own buckets are never touched)."""
    url = f"{s.rustfs_url.rstrip('/')}/{BUCKET}"
    now = datetime.datetime.now(datetime.timezone.utc) if clock is None else datetime.datetime.fromtimestamp(clock(), datetime.timezone.utc)
    h = s3_headers("PUT", url, s.rustfs_access_key, s.rustfs_secret_key, now, payload=hashlib.sha256(b"").hexdigest(), length=0)
    try:
        r = await http.put(url, content=b"", headers=h, timeout=20)
    except httpx.HTTPError as e:
        raise ExportError(f"Files (RustFS) did not answer ({type(e).__name__}). ./stack status shows whether it runs.") from None
    if r.status_code == 200 or (r.status_code == 409 and "BucketAlready" in r.text[:2000]):
        return
    raise ExportError(f"Files (RustFS) would not make the {BUCKET} bucket ({_why(r)}).")


async def put_zip(http: httpx.AsyncClient, s: Settings, name: str, length: int, body: AsyncIterator[bytes], clock=None) -> str:
    """Streams BODY (exactly LENGTH bytes, a zip) to BUCKET/NAME. Returns the key. ExportError for anything refused."""
    if not NAME.fullmatch(name):
        raise ExportError("that name is not one an export can have", 400)
    if not 22 <= length <= MAX_BYTES:
        raise ExportError(f"a zip of {length} bytes is not one this export takes (at most {MAX_BYTES >> 20} MiB)", 413)
    await ensure_bucket(http, s, clock)
    url = f"{s.rustfs_url.rstrip('/')}/{BUCKET}/{name}"
    now = datetime.datetime.now(datetime.timezone.utc) if clock is None else datetime.datetime.fromtimestamp(clock(), datetime.timezone.utc)
    # (a name is made of the project and the second: the same name again is the same export)
    h = s3_headers("PUT", url, s.rustfs_access_key, s.rustfs_secret_key, now, length=length, extra={"content-type": "application/zip"})
    h["Content-Length"] = str(length)
    sent = 0

    async def checked() -> AsyncIterator[bytes]:
        nonlocal sent
        async for chunk in body:
            if sent == 0 and not chunk.startswith(ZIP_MAGIC):
                raise ExportError("that is not a zip", 400)
            sent += len(chunk)
            if sent > length:
                raise ExportError("more bytes than the announced length", 400)
            yield chunk
        if sent != length:
            raise ExportError("fewer bytes than the announced length", 400)

    try:
        r = await http.put(url, content=checked(), headers=h, timeout=httpx.Timeout(30.0, read=600.0, write=600.0))
    except httpx.HTTPError as e:
        if isinstance(e.__cause__, ExportError):
            raise e.__cause__ from None
        raise ExportError(f"Files (RustFS) did not take the zip ({type(e).__name__}).") from None
    except ExportError:
        raise
    if r.status_code != 200:
        raise ExportError(f"Files (RustFS) refused the zip ({_why(r)}).")
    return f"{BUCKET}/{name}"
