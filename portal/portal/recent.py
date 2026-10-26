"""Home's Continue row (static/home.js, GET /api/continue): the Code sessions the Code page last reported, and the newest
Chat conversations.

The Code page's sessions: the portal never reaches the code container — it shares a network with the main Caddy alone,
and answers only what that Caddy brings it after the portal's check (compose.code.yaml). So the Code page itself, open
in a browser that unlocked it (framed by the Code tab, in a tab of its own, on a phone), tells the portal what Home may
show: POST /.bn/recent on the code host, which Caddy routes to /auth/code-recent after the code host's check (a session,
a fresh unlock, no Origin but the code host's own; app.py checks all of it again). What is kept: the session ids, their
state (waiting for you, working, idle, closed), when each was last active, a title as plain text (capped; control
characters dropped, and the invisible or direction-changing ones shown as ⟨U+…⟩ so a title cannot pass for another),
how many wait for you, and the project the page shows (its id and name). In this process's memory only — never on disk,
never logged — one report per sign-in (the Tailscale login on the remote site), the newest replacing the one before;
Sign out and a new password forget them all. Home says how old a report is: one from a page that is not open any more
can be out of date, and a live Code tab's own report (code.js) is newer anyway.

Chat's conversations: Open WebUI's own list of the owner's chats (GET /api/v1/chats/), asked as the global search asks
it (chatsearch.ChatSearch: the owner's session token, in memory only), reduced to an id, a title and a time each, at
most MAX_CHATS, and kept for CHATS_TTL_S so a Home that refreshes every 30 s asks Open WebUI at most every 20 s."""

from __future__ import annotations

import re
import time

import httpx

from . import chatsearch

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
PROJECT_ID = re.compile(r"ws|p_[0-9a-f]{8}")
STATES = ("waiting", "working", "idle", "closed")
MAX_SESSIONS = 8
MAX_TITLE = 120
MAX_PROJECT = 80
MAX_BODY = 16 * 1024
MAX_LOGINS = 8
MAX_CHATS = 5
CHATS_TTL_S = 20
BURST_N, BURST_S = 20, 10   # reports: at most 20 in any 10 s (and 3,600 an hour: app.py)
# C0 and C1 controls; the invisible or direction-changing characters (bidi overrides and isolates, zero-width ones,
# the BOM, tag characters): static/code.js shownTitle shows the same set the same way
INVISIBLE = re.compile("[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff"
                       "\U000e0000-\U000e007f]")


def shown(v, n: int) -> str:
    """A title as Home shows it: a string, at most N characters, line breaks and tabs as spaces, the rest of INVISIBLE as
    ⟨U+XXXX⟩; "" for anything else."""
    if not isinstance(v, str):
        return ""
    t = re.sub(r"[\t\n\r]", " ", v[: n * 2])[:n]
    return INVISIBLE.sub(lambda m: f"⟨U+{ord(m.group(0)):04X}⟩", t).strip()


def _when(v, now: float) -> int | None:
    """A time the page sent (epoch milliseconds) as whole seconds, or None: not a number, before 2020, or in the future."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
        return None
    s = int(v // 1000)
    return s if 1577836800 <= s <= now + 300 else None


def take_report(data, now: float | None = None) -> dict | None:
    """The Code page's report as Home may show it, or None when it is not one: {waiting, sessions: [{id, state, title,
    at}], project: {id, name} | None}. Sessions with a bad id or state are left out; at most MAX_SESSIONS, in the page's
    order (waiting first, then working, then the most recent)."""
    now = time.time() if now is None else now
    if not isinstance(data, dict) or not isinstance(data.get("sessions"), list):
        return None
    out, seen = [], set()
    for x in data["sessions"][: MAX_SESSIONS * 4]:
        if not isinstance(x, dict) or not isinstance(x.get("id"), str) or not UUID.fullmatch(x["id"]) or x["id"] in seen:
            continue
        if x.get("state") not in STATES:
            continue
        seen.add(x["id"])
        out.append({"id": x["id"], "state": x["state"], "title": shown(x.get("title"), MAX_TITLE), "at": _when(x.get("at"), now)})
        if len(out) >= MAX_SESSIONS:
            break
    w = data.get("waiting")
    waiting = min(w, 99) if isinstance(w, int) and not isinstance(w, bool) and w > 0 else 0
    p = data.get("project")
    project = None
    if isinstance(p, dict) and isinstance(p.get("id"), str) and PROJECT_ID.fullmatch(p["id"]):
        project = {"id": p["id"], "name": shown(p.get("name"), MAX_PROJECT) or ("Workspace" if p["id"] == "ws" else "")}
    return {"waiting": max(waiting, sum(1 for s in out if s["state"] == "waiting")), "sessions": out, "project": project}


class Burst:
    """At most N in any S seconds (a sliding window): the Code pages open at once (a phone's, a computer's, a second
    tab) all report the same change at the same moment, which a minimum interval between two reports would refuse."""

    def __init__(self, n: int = BURST_N, s: float = BURST_S, clock=time.monotonic):
        self.n, self.s, self.clock = n, s, clock
        self._times: list[float] = []

    def take(self) -> int:
        """0 when one more fits (counted), else the seconds until one does."""
        now = self.clock()
        self._times = [t for t in self._times if now - t < self.s]
        if len(self._times) >= self.n:
            return int(self.s - (now - self._times[0])) + 1
        self._times.append(now)
        return 0


class Reports:
    """The newest report of each sign-in (None: the local site, or a remote site without a Tailscale identity), in
    memory; at most MAX_LOGINS of them (the oldest goes)."""

    def __init__(self, clock=time.time):
        self.clock = clock
        self._by: dict[str, dict] = {}

    def put(self, login: str | None, report: dict) -> None:
        k = login or ""
        self._by.pop(k, None)
        while len(self._by) >= MAX_LOGINS:
            self._by.pop(next(iter(self._by)))
        self._by[k] = {**report, "at": int(self.clock())}

    def get(self, login: str | None) -> dict | None:
        r = self._by.get(login or "")
        return None if r is None else {**r, "sessions": [dict(s) for s in r["sessions"]],
                                       "project": dict(r["project"]) if r["project"] else None}

    def clear(self) -> None:
        self._by.clear()


class RecentChats:
    """The owner's newest Chat conversations, through ChatSearch's sign-in: [{id, title, updated_at}], newest first."""

    def __init__(self, chats: chatsearch.ChatSearch, clock=time.monotonic):
        self.chats, self.clock = chats, clock
        self._at = 0.0
        self._last: dict | None = None

    async def get(self, client: httpx.AsyncClient) -> dict:
        """{items: [...]} or {items: [], error: "why"} (an answer, not an error status: Home says it and links Chat)."""
        if self._last is not None and self.clock() - self._at < CHATS_TTL_S:
            return self._last
        try:
            items = await self.chats.recent(client, MAX_CHATS)
            out = {"items": items}
        except chatsearch.SearchError as e:
            out = {"items": [], "error": str(e)}
        self._last, self._at = out, self.clock()
        return out
