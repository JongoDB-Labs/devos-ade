"""
title: Make it a project
author: DevOS ADE
description: A button under each answer that carries this chat over to the Code page as a new project (kept on your local git server), where Claude carries on from the conversation and writes the files. Chat itself still cannot touch your files. Installed and updated by ./stack setup.
icon_url: data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwYXRoIGQ9Ik0zIDcuNUExLjUgMS41IDAgMCAxIDQuNSA2aDQuMmwyIDJIMTkuNUExLjUgMS41IDAgMCAxIDIxIDkuNXY4YTEuNSAxLjUgMCAwIDEtMS41IDEuNWgtMTVBMS41IDEuNSAwIDAgMSAzIDE3LjV6Ii8+PHBhdGggZD0iTTEyIDExLjV2NE0xMCAxMy41aDQiLz48L3N2Zz4=
version: 1
"""

# Installed into Open WebUI by ./stack setup (lib/owui.sh) as a global action function with id "make_project".
#
# What it does, and what it deliberately does not. Chat has no workspace, and its sandbox cannot touch your files; that
# stays. This action never writes a file, never calls the portal, the Code page, Forgejo or any API, and holds no key or
# URL of any of them. All it does is read THIS chat (the messages Open WebUI hands every action: the conversation up to
# the answer whose button was clicked) and ask the browser — the Chat page itself, through Open WebUI's own "execute"
# event — to say it to the DevOS ADE page that frames Chat: window.parent.postMessage({type: "bn-chat-handoff", id,
# title, text}). The portal's page (portal/static/code.js) takes it only from the Chat tab's own frame, keeps it for the
# Code page once and for ten minutes (portal/portal/chathandoff.py) and opens the Code page at it; there a dialog shows the
# conversation read-only and nothing is created until you confirm. So the most Open WebUI can do is put a chat in front of
# you that you then open yourself, and a chat over MAX_CHARS is not sent at all (the dialog says it was too big).
#
# Self-contained on purpose: Open WebUI loads this file's text, so it may import only the standard library and pydantic
# (which Open WebUI ships), plus Open WebUI's own chat model, tried once for the chat's title and optional.

import asyncio
import inspect
import json
import re

from pydantic import BaseModel

MAX_CHARS = 200_000      # as the portal's hand-off cap (portal/portal/chathandoff.py MAX_TEXT): over it, nothing is sent
MAX_TITLE = 120
ANSWER_WAIT_S = 20       # how long the Chat page waits for the portal page to say how it went

# What the cost filter (bedrock_cost.py) writes under an answer — "*≈ $0.0069 · 1,240 in / 380 out · Model · chat ≈ $0.04*", a
# free model's, a subscription's — is not part of the conversation. Matched loosely on purpose: a line of only italics that
# starts like one of them.
_FOOTER_RE = re.compile(r"(?m)^[ \t]*\*(?:≈ |free · |on your )[^*\n]*\*[ \t]*$")
# A model's reasoning and tool-call blocks (<details type="reasoning" …>…</details>) are long and not the conversation.
_DETAILS_RE = re.compile(r"<details\b[^>]*>.*?</details>", re.S)
_FENCE_RE = re.compile(r"\n{3,}")

# Run by the Chat page ("execute" gets an async function body). It says the chat to the page that frames it and waits for the
# answer; the payload is a JSON string literal, parsed there, so nothing of the chat is ever code.
_JS = """
const msg = JSON.parse(%s);
if (window.parent === window) return { ok: false, error: 'This page is not inside DevOS ADE. Open Chat from its Chat tab to make a project.' };
const to = (location.ancestorOrigins && location.ancestorOrigins[0]) || '*';
const id = 'h' + Math.random().toString(36).slice(2, 12);
return await new Promise((resolve) => {
  const done = (v) => { window.removeEventListener('message', on); clearTimeout(t); resolve(v); };
  const on = (e) => { if (e.source === window.parent && e.data && e.data.type === 'bn-portal-chat-handoff' && e.data.id === id) done({ ok: e.data.ok === true, tooBig: e.data.tooBig === true, error: String(e.data.error || '').slice(0, 300) }); };
  const t = setTimeout(() => done({ ok: false, error: 'DevOS ADE did not answer. Make sure Chat is open in its Chat tab and the Code page is on.' }), %d);
  window.addEventListener('message', on);
  window.parent.postMessage(Object.assign({ type: 'bn-chat-handoff', id: id }, msg), to);
});
"""


def _text_of(content):
    """A message's text: a string, or the text parts of a list (an image or a file becomes a short marker)."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    out = []
    for part in content:
        if isinstance(part, str):
            out.append(part)
        elif isinstance(part, dict):
            if part.get("type") == "text" and isinstance(part.get("text"), str):
                out.append(part["text"])
            elif part.get("type") in ("image_url", "image"):
                out.append("[an image was attached here]")
            elif part.get("type") not in (None, "text"):
                out.append("[an attachment was here]")
    return "\n".join(out)


def clean_message(text):
    """An answer without the cost line under it and without its reasoning blocks."""
    t = _DETAILS_RE.sub("", text or "")
    t = _FOOTER_RE.sub("", t)
    return _FENCE_RE.sub("\n\n", t).strip()


def conversation(messages):
    """The chat as plain text: 'You:' and 'Assistant:' turns, in order, each cleaned; system messages and empty turns left
    out. -> (text, number of turns)."""
    turns = []
    for m in messages if isinstance(messages, list) else []:
        if not isinstance(m, dict) or m.get("role") not in ("user", "assistant"):
            continue
        t = clean_message(_text_of(m.get("content")))
        if t:
            turns.append(("You" if m["role"] == "user" else "Assistant", t))
    return "\n\n".join("%s:\n%s" % (who, t) for who, t in turns), len(turns)


def fallback_title(messages):
    """The first line of the first thing you said, when Open WebUI will not say the chat's title."""
    for m in messages if isinstance(messages, list) else []:
        if isinstance(m, dict) and m.get("role") == "user":
            t = clean_message(_text_of(m.get("content")))
            if t:
                return t.splitlines()[0][:60].strip()
    return ""


def js_for(title, text):
    """The code the Chat page runs for this hand-off (over MAX_CHARS: it says so and sends no text)."""
    msg = {"title": title[:MAX_TITLE]}
    if len(text) > MAX_CHARS:
        msg["tooBig"] = True
        msg["text"] = ""
    else:
        msg["text"] = text
    return _JS % (json.dumps(json.dumps(msg)), ANSWER_WAIT_S * 1000)


async def _chat_title(chat_id, user_id):
    """The chat's title as Open WebUI keeps it (this user's chat only), or "" — its model's methods are asked defensively:
    a version that moved them just gets the first-line title."""
    if not isinstance(chat_id, str) or not chat_id or chat_id.startswith("local:") or not user_id:
        return ""
    try:
        from open_webui.models.chats import Chats  # noqa: PLC0415 — only inside Open WebUI

        chat = Chats.get_chat_by_id_and_user_id(chat_id, user_id)
        if inspect.isawaitable(chat):
            chat = await chat
        if chat is None:
            return ""
        title = getattr(chat, "title", None)
        if not isinstance(title, str) or not title:
            title = (getattr(chat, "chat", None) or {}).get("title")
        return title.strip() if isinstance(title, str) and title.strip() != "New Chat" else ""
    except Exception:  # noqa: BLE001 — optional
        return ""


class Action:
    class Valves(BaseModel):
        pass

    def __init__(self):
        self.valves = self.Valves()

    async def action(self, body, __user__=None, __event_emitter__=None, __event_call__=None):
        async def say(kind, content):
            if __event_emitter__:
                await __event_emitter__({"type": "notification", "data": {"type": kind, "content": content}})

        messages = (body or {}).get("messages")
        text, turns = conversation(messages)
        if not turns or __event_call__ is None:
            await say("warning", "There is nothing in this chat to make a project from yet.")
            return None
        title = await _chat_title((body or {}).get("chat_id"), (__user__ or {}).get("id")) or fallback_title(messages)
        if __event_emitter__:
            await __event_emitter__({"type": "status", "data": {"description": "Handing this chat to the Code page…", "done": False}})
        try:
            res = await asyncio.wait_for(__event_call__({"type": "execute", "data": {"code": js_for(title, text)}}), ANSWER_WAIT_S + 10)
        except Exception:  # noqa: BLE001 — a page that is gone, a timeout
            res = None
        if __event_emitter__:
            await __event_emitter__({"type": "status", "data": {"description": "", "done": True, "hidden": True}})
        if isinstance(res, dict) and res.get("ok"):
            await say("success", "This chat is too big to hand over: the Code page says so." if res.get("tooBig")
                      else "Opened in the Code page: check the project's name there, then create it.")
        else:
            why = res.get("error") if isinstance(res, dict) and res.get("error") else "DevOS ADE did not answer."
            await say("error", "Could not hand this chat over. " + str(why))
        return None
