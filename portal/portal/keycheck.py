"""Settings' in-form key check: a provider key typed in a form, asked of that provider once, before the password.

The same free call ./stack makes when it checks a key (lib/openrouter.sh or_validate_key, lib/explabs.sh
xl_validate_key, lib/stt.sh stt_validate_key): OpenRouter's GET /api/v1/key, the Experiential Labs gateway's GET
/v1/models, OpenAI's or Groq's GET /models — each with the key as a Bearer token, to that provider's fixed https address
(nothing in the request picks it), no redirect followed, an answer read up to MAX_BYTES, all of it within DEADLINE
seconds. The key is never stored or logged. The update helper still checks it again before anything is saved; this
check only lets the form say at once, next to the field, that a key does not work (and where a new one comes from).

Web search keys (Tavily, Brave, Perplexity) have no free check (a search is what costs), and the AWS key's needs STS
and a Bedrock call signed with it: for those the form checks the shape only, and the helper does the rest.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass

import httpx

DEADLINE = 8.0                          # s for the whole check (the helper's own takes up to 20 s)
TIMEOUT = httpx.Timeout(DEADLINE, connect=4.0)
MAX_BYTES = 2 * 1024 * 1024             # a model list is ~25-60 KB


@dataclass(frozen=True)
class Provider:
    name: str        # in the messages: "OpenRouter rejected this key"
    host: str        # "openrouter.ai did not answer"
    url: str         # the free call
    keys_url: str    # where a key comes from
    lists_models: bool = False   # the answer is the key's model list (data: [...]): how many it can use


OPENROUTER = Provider("OpenRouter", "openrouter.ai", "https://openrouter.ai/api/v1/key", "https://openrouter.ai/settings/keys")
EXPLABS = Provider("Experiential Labs", "api.experientiallabs.ai", "https://api.experientiallabs.ai/v1/models",
                   "https://platform.experientiallabs.ai/settings/api-keys", lists_models=True)
STT = {
    "openai": Provider("OpenAI", "api.openai.com", "https://api.openai.com/v1/models", "https://platform.openai.com/api-keys", lists_models=True),
    "groq": Provider("Groq", "api.groq.com", "https://api.groq.com/openai/v1/models", "https://console.groq.com/keys", lists_models=True),
}
# (a key of these has no free check: the form says so, and the helper checks what it can)
UNCHECKED = ("WEBSEARCH_TAVILY_API_KEY", "WEBSEARCH_BRAVE_API_KEY", "WEBSEARCH_PERPLEXITY_API_KEY")


def provider(key: str, stt_provider: str | None = None) -> Provider | None:
    """The provider a key of KEY is checked with (STT_API_KEY: by STT_PROVIDER), or None."""
    if key == "OPENROUTER_API_KEY":
        return OPENROUTER
    if key == "EXPLABS_API_KEY":
        return EXPLABS
    if key == "STT_API_KEY":
        return STT.get(stt_provider or "")
    return None


# An OpenAI key restricted to some scopes (no "Models: Read") authenticates and is refused listing models: accepted, as
# lib/stt.sh stt_validate_key accepts it (transcription is tested on first use).
_SCOPE = ("missing scope", "insufficient permission", "restricted api key")


def _scoped(body: str) -> bool:
    b = body.lower()
    return any(s in b for s in _SCOPE) or ("permission" in b and "scope" in b)


async def _get(client: httpx.AsyncClient, p: Provider, value: str) -> tuple[int, bytes]:
    req = client.build_request("GET", p.url, headers={"Authorization": f"Bearer {value}", "Accept": "application/json"},
                               timeout=TIMEOUT)
    resp = await client.send(req, stream=True, follow_redirects=False)
    try:
        body = b""
        async for chunk in resp.aiter_bytes():
            body += chunk
            if len(body) > MAX_BYTES:
                break
        return resp.status_code, body[:MAX_BYTES]
    finally:
        await resp.aclose()


def _count(body: bytes) -> int | None:
    try:
        data = json.loads(body)
    except ValueError:
        return None
    items = data.get("data") if isinstance(data, dict) else None
    return len(items) if isinstance(items, list) else None


async def check(client: httpx.AsyncClient, p: Provider, value: str) -> dict:
    """-> {"result": "ok" | "rejected" | "unreachable" | "error", "message", "url" (where a key comes from), "models"
    (how many the key may call, when the answer lists them)}. Never the key, never the provider's own words."""
    out = {"result": "", "message": "", "url": p.keys_url, "models": None}
    try:
        status, body = await asyncio.wait_for(_get(client, p, value), DEADLINE)
    except (asyncio.TimeoutError, httpx.TimeoutException):
        return {**out, "result": "unreachable",
                "message": f"{p.host} did not answer within {int(DEADLINE)} s, so the key is not checked yet."}
    except httpx.HTTPError:
        return {**out, "result": "unreachable", "message": f"Could not reach {p.host} to check the key (network?)."}
    if status == 200:
        n = _count(body) if p.lists_models else None
        said = f"{p.name} accepts this key" + (f": it may use {n} model{'' if n == 1 else 's'}." if n else ".")
        return {**out, "result": "ok", "message": said, "models": n}
    if status == 403 and p in STT.values() and _scoped(body[:2000].decode("utf-8", "replace")):
        return {**out, "result": "ok", "message": f"{p.name} accepts this key (a restricted key: it cannot list models; "
                                                   "transcription is tested on first use)."}
    if status in (401, 403):
        return {**out, "result": "rejected", "message": f"{p.name} rejected this key (HTTP {status})."}
    if status == 429:
        return {**out, "result": "unreachable", "message": f"{p.host} asks to slow down (HTTP 429), so the key is not checked yet."}
    return {**out, "result": "error", "message": f"{p.host} answered HTTP {status} while checking the key."}
