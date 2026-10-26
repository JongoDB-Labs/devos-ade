"""Chat conversations for the portal's global search (GET /api/search/chats?q=…): Open WebUI's own search API
(GET /api/v1/chats/search?text=…), asked from here, inside the stack, as the owner — and the newest of them for Home's
Continue row (GET /api/v1/chats/, the same way: portal/recent.py).

How it signs in: exactly as the Chat tab does. Open WebUI trusts the X-Portal-User header for who you are
(WEBUI_AUTH_TRUSTED_EMAIL_HEADER; Caddy sets it from the portal's own answer for every browser request), so the portal
posts /api/v1/auths/signin with X-Portal-User: <the owner email> on the stack's internal network and gets the owner's
session token (a JWT; Open WebUI keeps no session record for it). The token stays in this process's memory — never
logged, never sent to a browser, never on disk — for at most TOKEN_TTL_S (Open WebUI's own lifetime is longer), and is
dropped at the first 401. Nothing about a conversation is kept here either: each search is passed on and its answer
reduced to what the search box shows — the chat's id (a UUID: the Chat tab opens /c/<id>), its title and Open WebUI's
snippet, as plain text (capped, control characters dropped), at most MAX_RESULTS.

The query: at most MAX_QUERY characters, control characters dropped; a few requests a second at most (the page waits
for typing to pause). Over remote access it answers the same as locally: the Chat tab is open there too."""

from __future__ import annotations

import asyncio
import re
import time
from collections import deque

import httpx

from .config import Settings

TIMEOUT = httpx.Timeout(5.0, connect=2.0)
TOKEN_TTL_S = 3600
MAX_QUERY = 64
MAX_RESULTS = 20
MAX_TITLE = 200
MAX_SNIPPET = 200
MAX_ANSWER = 512 * 1024
CHAT_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
PER_SECOND = 4
PER_MINUTE = 60


class SearchError(Exception):
    pass


def clean(v, n: int) -> str:
    """Text from Open WebUI (titles are often written by a model): capped, control characters as spaces, one line."""
    if not isinstance(v, str):
        return ""
    out = "".join(" " if ord(c) < 32 or 0x7F <= ord(c) <= 0x9F else c for c in v[: n * 2])
    return " ".join(out.split())[:n]


def query(raw) -> str:
    """The search text as passed on: a string, control characters dropped, at most MAX_QUERY characters; "" for none."""
    if not isinstance(raw, str):
        return ""
    return "".join(c for c in raw[: MAX_QUERY * 4] if ord(c) >= 32 and c != "\x7f")[:MAX_QUERY].strip()


class RateLimit:
    def __init__(self, clock=time.monotonic):
        self.clock, self.times = clock, deque()

    def take(self) -> bool:
        now = self.clock()
        while self.times and now - self.times[0] > 60:
            self.times.popleft()
        if len(self.times) >= PER_MINUTE or sum(1 for t in self.times if now - t < 1) >= PER_SECOND:
            return False
        self.times.append(now)
        return True


class ChatSearch:
    def __init__(self, settings: Settings, clock=time.monotonic):
        self.s, self.clock = settings, clock
        self._token: str | None = None
        self._token_at = 0.0
        self._lock = asyncio.Lock()
        self.rate = RateLimit(clock)

    async def _signin(self, client: httpx.AsyncClient) -> str:
        try:
            r = await client.post(f"{self.s.openwebui_url}/api/v1/auths/signin", json={"email": "", "password": ""},
                                  headers={"X-Portal-User": self.s.user_email}, timeout=TIMEOUT)
        except httpx.HTTPError as e:
            raise SearchError(f"Chat did not answer ({type(e).__name__})") from None
        if r.status_code != 200:
            raise SearchError(f"Chat refused the portal's sign-in (HTTP {r.status_code})")
        try:
            tok = r.json().get("token")
        except (ValueError, AttributeError):
            tok = None
        if not isinstance(tok, str) or not tok or len(tok) > 4096 or tok.startswith("sk-"):
            raise SearchError("Chat's sign-in answer had no session token")
        return tok

    async def token(self, client: httpx.AsyncClient, fresh: bool = False) -> str:
        async with self._lock:
            if fresh or self._token is None or self.clock() - self._token_at > TOKEN_TTL_S:
                self._token = None
                self._token = await self._signin(client)
                self._token_at = self.clock()
            return self._token

    def forget(self) -> None:
        self._token = None

    async def _rows(self, client: httpx.AsyncClient, path: str, params: dict) -> list:
        """GET PATH of Open WebUI as the owner (a fresh sign-in once after a 401): its answer, a JSON list."""
        for attempt in (0, 1):
            tok = await self.token(client, fresh=attempt == 1)
            try:
                r = await client.get(f"{self.s.openwebui_url}{path}", params=params,
                                     headers={"Authorization": f"Bearer {tok}"}, timeout=TIMEOUT)
            except httpx.HTTPError as e:
                raise SearchError(f"Chat did not answer ({type(e).__name__})") from None
            if r.status_code == 401 and attempt == 0:
                self.forget()
                continue
            if r.status_code != 200:
                if r.status_code == 401:
                    self.forget()
                raise SearchError(f"Chat answered HTTP {r.status_code}")
            if len(r.content) > MAX_ANSWER:
                raise SearchError("Chat's answer was too large")
            try:
                rows = r.json()
            except ValueError:
                raise SearchError("Chat's answer was not JSON") from None
            if not isinstance(rows, list):
                raise SearchError("Chat's answer was not a list")
            return rows
        raise SearchError("Chat refused the portal's session")

    @staticmethod
    def _row(x, snippet: bool) -> dict | None:
        if not isinstance(x, dict) or not isinstance(x.get("id"), str) or not CHAT_ID.fullmatch(x["id"]):
            return None
        upd = x.get("updated_at")
        out = {"id": x["id"], "title": clean(x.get("title"), MAX_TITLE) or "Untitled chat",
               "updated_at": upd if isinstance(upd, int) and not isinstance(upd, bool) and upd > 0 else None}
        if snippet:
            out.update({"snippet": clean(x.get("snippet"), MAX_SNIPPET), "archived": x.get("archived") is True})
        return out

    async def search(self, client: httpx.AsyncClient, q: str) -> list[dict]:
        """[{id, title, snippet, updated_at}] of the owner's chats matching Q (Open WebUI's own matching), newest first."""
        out = []
        for x in await self._rows(client, "/api/v1/chats/search", {"text": q, "page": 1}):
            row = self._row(x, True)
            if row is not None:
                out.append(row)
            if len(out) >= MAX_RESULTS:
                break
        return out

    async def recent(self, client: httpx.AsyncClient, n: int) -> list[dict]:
        """[{id, title, updated_at}] of the owner's N newest chats (Open WebUI's own list, its first page: newest
        first; archived ones are not in it) — Home's Continue row (portal/recent.py)."""
        out = []
        for x in await self._rows(client, "/api/v1/chats/", {"page": 1}):
            row = self._row(x, False)
            if row is not None:
                out.append(row)
            if len(out) >= n:
                break
        return out
