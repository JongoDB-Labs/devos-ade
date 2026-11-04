"""Tests for Chat's "Make it a project" action (owui/functions/make_project.py). No Open WebUI needed."""

import asyncio
import json
import os
import re
import subprocess
import shutil
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "functions"))

import make_project as mp  # noqa: E402

MSGS = [
    {"role": "system", "content": "be brief"},
    {"role": "user", "content": "I want a tiny CLI that adds two numbers"},
    {"role": "assistant", "content": '<details type="reasoning" done="true"><summary>Thought</summary>\n> hmm\n</details>\nSure: use argparse.\n\n*≈ $0.0069 · 1,240 in / 380 out · Claude Haiku 5.5 · chat ≈ $0.04*'},
    {"role": "user", "content": [{"type": "text", "text": "Call it addem"}, {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}}]},
    {"role": "assistant", "content": ""},
]


def run(coro):
    return asyncio.run(coro)


def test_the_conversation_is_plain_turns_without_system_cost_lines_or_reasoning():
    text, n = mp.conversation(MSGS)
    assert n == 3
    assert text == ("You:\nI want a tiny CLI that adds two numbers\n\nAssistant:\nSure: use argparse.\n\n"
                    "You:\nCall it addem\n[an image was attached here]")
    assert "Haiku" not in text and "hmm" not in text and "be brief" not in text
    for bad in (None, "x", {}, [None, 5, {"role": "tool", "content": "x"}]):
        assert mp.conversation(bad) == ("", 0)


def test_the_cost_line_shapes_are_all_taken_off():
    for foot in ("*≈ $0.0069 · 1,240 in / 380 out · M · chat ≈ $0.04*", "*free · 1,240 in / 380 out · M · chat ≈ $0.04*",
                 "*on your ChatGPT plan · 1,240 in / 380 out · Codex*"):
        assert mp.clean_message("Answer.\n\n" + foot) == "Answer."
    assert mp.clean_message("*emphasis* stays, and so does *≈ about* mid-line text") == "*emphasis* stays, and so does *≈ about* mid-line text"


def test_the_fallback_title_is_the_first_line_of_what_you_said():
    assert mp.fallback_title(MSGS) == "I want a tiny CLI that adds two numbers"
    assert mp.fallback_title([{"role": "user", "content": "x" * 200}]) == "x" * 60
    assert mp.fallback_title([]) == "" and mp.fallback_title(None) == ""


def _payload(code):
    """The JSON the page code parses: the first JSON.parse("…") literal, decoded twice."""
    m = re.search(r"JSON\.parse\((\".*\")\);", code)
    return json.loads(json.loads(m.group(1)))


def test_the_code_the_chat_page_runs_carries_the_chat_as_data_only():
    nasty = 'He said "hi"\n</script><img src=x onerror=alert(1)>  ${x} `y` \\'
    code = mp.js_for("T" * 500, nasty)
    p = _payload(code)
    assert p == {"title": "T" * mp.MAX_TITLE, "text": nasty}
    # the text sits inside one JSON string literal, never in the code's own words
    assert "onerror" not in code.replace(json.dumps(json.dumps(p)), "")
    assert "bn-chat-handoff" in code and "window.parent.postMessage" in code and "ancestorOrigins" in code
    # no fetch, no XHR, no network call from the page's side: it only talks to the page that frames it
    assert "fetch(" not in code and "XMLHttpRequest" not in code and "WebSocket" not in code


def test_a_chat_over_the_cap_sends_no_text():
    p = _payload(mp.js_for("big", "x" * (mp.MAX_CHARS + 1)))
    assert p == {"title": "big", "text": "", "tooBig": True}
    assert _payload(mp.js_for("ok", "x" * mp.MAX_CHARS))["text"] == "x" * mp.MAX_CHARS
    assert mp.MAX_CHARS == 200_000   # the portal's cap (portal/portal/chathandoff.py MAX_TEXT)


def test_the_js_is_valid_javascript():
    node = shutil.which("node")
    if not node:
        return
    code = mp.js_for("t", "hello")
    r = subprocess.run([node, "-e", "new Function('return (async () => {' + require('fs').readFileSync(0, 'utf8') + '})()')"],
                       input=code, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


class Calls:
    def __init__(self, reply):
        self.reply, self.events, self.codes = reply, [], []

    async def emit(self, ev):
        self.events.append(ev)

    async def call(self, ev):
        self.codes.append(ev)
        if isinstance(self.reply, Exception):
            raise self.reply
        return self.reply


def act(calls, body=None, user=None):
    a = mp.Action()
    return run(a.action(body if body is not None else {"messages": MSGS, "chat_id": "local:x"}, user or {"id": "u1"},
                        calls.emit, calls.call))


def notes(calls):
    return [e["data"] for e in calls.events if e["type"] == "notification"]


def test_the_action_asks_the_page_and_says_how_it_went():
    c = Calls({"ok": True})
    assert act(c) is None
    assert len(c.codes) == 1 and c.codes[0]["type"] == "execute"
    p = _payload(c.codes[0]["data"]["code"])
    assert p["title"] == "I want a tiny CLI that adds two numbers" and p["text"].startswith("You:\nI want a tiny CLI")
    assert [n["type"] for n in notes(c)] == ["success"] and "Code page" in notes(c)[0]["content"]
    st = [e["data"]["done"] for e in c.events if e["type"] == "status"]
    assert st == [False, True]   # shown busy, then done


def test_a_chat_too_big_is_said_not_sent():
    c = Calls({"ok": True, "tooBig": True})
    act(c, {"messages": [{"role": "user", "content": "x" * (mp.MAX_CHARS + 5)}]})
    assert _payload(c.codes[0]["data"]["code"])["text"] == ""
    assert "too big" in notes(c)[0]["content"]


def test_failures_are_said_and_never_raised():
    for reply in ({"ok": False, "error": "The Code page is off here."}, None, asyncio.TimeoutError(), RuntimeError("gone")):
        c = Calls(reply)
        assert act(c) is None
        assert notes(c)[0]["type"] == "error" and notes(c)[0]["content"].startswith("Could not hand this chat over.")
    c = Calls({"ok": False, "error": "The Code page is off here."})
    act(c)
    assert "off here" in notes(c)[0]["content"]


def test_an_empty_chat_asks_nothing_of_the_page():
    for body in ({"messages": []}, {"messages": [{"role": "system", "content": "x"}]}, {}):
        c = Calls({"ok": True})
        act(c, body)
        assert c.codes == [] and notes(c)[0]["type"] == "warning"


def test_it_holds_no_url_key_or_network_call_of_its_own():
    src = open(os.path.join(os.path.dirname(__file__), "..", "functions", "make_project.py"), encoding="utf-8").read()
    code = re.sub(r"(?s)^\"\"\".*?\"\"\"", "", src)
    for banned in ("import requests", "import httpx", "import urllib", "import socket", "aiohttp", "http://", "https://", "api_key", "Authorization"):
        assert banned not in code, banned
