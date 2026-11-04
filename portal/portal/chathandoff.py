"""Chat's "Make it a project" (JON-1060): a chat handed to the Code page as text, once.

Chat has no workspace and its sandbox cannot touch your files, and that stays. What Chat's action does instead is ask
the browser (a small script in Chat's own page, owui/functions/make_project.py) to tell the portal's page, which frames
Chat, "this is the chat": its title and its conversation as text. Open WebUI itself never reaches the portal or the Code
page, and holds no key for either — the hand-off crosses only in the browser, from the Chat frame to the portal page
(static/code.js checks the frame and its origin), and the portal page POSTs it here (POST /api/chat-handoff, the portal
session and X-Requested-With like every /api/ write).

What is kept: the title and the text, in this process's memory only (never on disk, never logged), under a random id
that names nothing, for the sign-in that made it (the Tailscale login on the remote site), for TTL_S seconds, and taken
out by the first reader. The portal page then opens the Code page at ?handoff=<id>; the Code page redeems it with its
own POST /.bn/handoff (Caddy → /auth/code-handoff, after the code host's check), shows the New project dialog with the
conversation read-only, and creates nothing until you confirm. A second redeem, a wrong sign-in, an old or unknown id:
nothing. A chat over MAX_TEXT characters is refused here (and by the page before it sends), and the Code page's dialog
says so. Every character that can hide or reorder text is shown as ⟨U+…⟩ by the Code page, as everything untrusted on it."""

from __future__ import annotations

import secrets
import time

MAX_TEXT = 200_000        # characters of conversation; more is refused ("too big")
MAX_TITLE = 120
MAX_BODY = 1024 * 1024    # bytes of the request (200,000 characters can be 800 KB of UTF-8)
TTL_S = 600               # a hand-off is used within 10 minutes or it is gone
MAX_KEPT = 8              # at most this many wait at once (the oldest goes)
ID_LEN = 32               # secrets.token_urlsafe(24)
# what the Code page's link may carry instead of an id, so that its dialog can say what happened (code.py deep_link keeps the same)
NOTES = ("too-big", "failed")


def clean(v, n: int) -> str:
    """A string of at most N characters, or "" for anything else (the Code page shows the invisible ones as ⟨U+…⟩)."""
    return v[:n] if isinstance(v, str) else ""


def take_body(data) -> tuple[str, str] | str | None:
    """(title, text) of a hand-off the portal page sent, "too-big" when the conversation is over MAX_TEXT, or None when it
    is not one (no text, not strings)."""
    if not isinstance(data, dict) or not isinstance(data.get("text"), str):
        return None
    if len(data["text"]) > MAX_TEXT:
        return "too-big"
    text = data["text"]
    if not text.strip() or "\x00" in text:
        return None
    return clean(data.get("title"), MAX_TITLE).replace("\x00", ""), text


class Handoffs:
    """The hand-offs waiting to be opened, in memory."""

    def __init__(self, clock=time.time):
        self.clock = clock
        self._by: dict[str, dict] = {}

    def _drop_old(self) -> None:
        now = self.clock()
        for k in [k for k, v in self._by.items() if v["exp"] <= now]:
            del self._by[k]

    def put(self, login: str | None, title: str, text: str) -> str:
        """Keeps a hand-off for this sign-in -> its id."""
        self._drop_old()
        while len(self._by) >= MAX_KEPT:
            self._by.pop(next(iter(self._by)))
        hid = secrets.token_urlsafe(ID_LEN * 3 // 4)
        self._by[hid] = {"login": login or "", "title": title, "text": text, "exp": self.clock() + TTL_S}
        return hid

    def take(self, login: str | None, hid) -> dict | None:
        """{title, text} the first time, for the sign-in that made it, within TTL_S; None every other time. A wrong sign-in
        leaves it where it is (it is not that person's to use up)."""
        self._drop_old()
        if not isinstance(hid, str) or len(hid) != ID_LEN:
            return None
        h = self._by.get(hid)
        if h is None or h["login"] != (login or ""):
            return None
        del self._by[hid]
        return {"title": h["title"], "text": h["text"]}

    def clear(self) -> None:
        """Sign out and a new password forget them all."""
        self._by.clear()
