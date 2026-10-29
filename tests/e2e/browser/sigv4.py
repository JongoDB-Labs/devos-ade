"""AWS Signature Version 4 for a GET, with the standard library only: the e2e checks that read AWS's own lists to hold
the page to them (checks_models.py model-browser-complete, model-browser-bedrock-profiles). Read-only, free calls;
the key never leaves this module (no log, no message names it)."""

from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import urllib.error
import urllib.parse
import urllib.request


def _mac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def _q(v) -> str:
    return urllib.parse.quote(str(v), safe="-_.~")


def get(service: str, region: str, host: str, path: str, query: dict, key_id: str, secret: str, token: str = "",
        timeout: float = 20.0) -> tuple[int, dict]:
    """GET https://HOST/PATH?QUERY signed for SERVICE in REGION -> (HTTP status, the JSON answer), or on a refusal
    (status, {"__type": AWS's error type}), or (0, {"__type": "unreachable (…)"}) when the host does not answer (a
    region without the service). PATH: plain segments only (no character that needs encoding)."""
    now = datetime.datetime.now(datetime.timezone.utc)
    amz, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    qs = "&".join(f"{_q(k)}={_q(v)}" for k, v in sorted(query.items()))
    headers = {"host": host, "x-amz-date": amz, **({"x-amz-security-token": token} if token else {})}
    signed = ";".join(sorted(headers))
    canonical = "\n".join(["GET", path, qs, "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed,
                           hashlib.sha256(b"").hexdigest()])
    scope = f"{day}/{region}/{service}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    k = _mac(_mac(_mac(_mac(("AWS4" + secret).encode(), day), region), service), "aws4_request")
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    send = {k2: v for k2, v in headers.items() if k2 != "host"}
    send["authorization"] = f"AWS4-HMAC-SHA256 Credential={key_id}/{scope}, SignedHeaders={signed}, Signature={sig}"
    req = urllib.request.Request(f"https://{host}{path}{'?' + qs if qs else ''}", headers=send)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        body = e.read()[:4000]
        try:
            out = json.loads(body or b"{}")
        except ValueError:
            out = {}
        # (AWS's REST APIs say the error's type in a header; the body's message names the account: not kept)
        return e.code, {"__type": e.headers.get("x-amzn-ErrorType") or (out.get("__type") if isinstance(out, dict) else "") or ""}
    except (urllib.error.URLError, OSError) as e:
        return 0, {"__type": f"unreachable ({type(getattr(e, 'reason', e)).__name__})"}


def bedrock(region: str, path: str, query: dict, env: dict) -> tuple[int, dict]:
    """A Bedrock control-plane list in REGION with the stack's AWS key (ENV: its .env)."""
    return get("bedrock", region, f"bedrock.{region}.amazonaws.com", path, query, env.get("AWS_ACCESS_KEY_ID", ""),
               env.get("AWS_SECRET_ACCESS_KEY", ""), env.get("AWS_SESSION_TOKEN", ""))


def error_code(answer: dict) -> str:
    """AWS's error type of a refused call ("AccessDeniedException"), without its namespace or detail."""
    t = answer.get("__type") or ""
    return t.rsplit("#", 1)[-1].split(":", 1)[0] if isinstance(t, str) else ""
