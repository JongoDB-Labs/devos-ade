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
    # (JON-1158) one network call from the page's side, to Open WebUI's own API on its own origin (filing the chat), with the
    # sign-in it keeps itself: no other address, no token read or sent by hand, no XHR or socket
    assert code.count("fetch(") == 1 and "fetch('/api/v1/' + p, { method: m, credentials: 'same-origin'" in code
    assert "http" not in code.replace("http://", "") and "//" not in re.sub(r"/\*.*?\*/", "", code.replace("'//'", ""))
    assert "localStorage" not in code and "Authorization" not in code and "XMLHttpRequest" not in code and "WebSocket" not in code


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


def test_the_timeout_text_points_at_a_reload_after_an_update():   # JON-1127
    code = mp.js_for("T", "hello")
    assert ("DevOS ADE did not answer. If it was just updated, reload DevOS ADE; and make sure Chat is open in its "
            "Chat tab and the Code page is on.") in code


# --- (JON-1158) the chat filed under the project it went to: the page's code run in Node against a stub window ---
_HARNESS = r"""
const code = require('fs').readFileSync(0, 'utf8');
const sc = JSON.parse(process.argv[1]);
const listeners = new Set(), posted = [], calls = [];
const emit = (e) => { for (const f of [...listeners]) f(e); };
const parent = { postMessage: (m) => { posted.push(m); setTimeout(() => emit({ source: parent, data: { type: 'bn-portal-chat-handoff', id: m.id, ...sc.reply } }), 0); } };
const window = { parent, addEventListener: (t, f) => listeners.add(f), removeEventListener: (t, f) => listeners.delete(f) };
const fetch = async (url, init) => {
  calls.push([url, init.method, init.body ? JSON.parse(init.body) : null, init.credentials]);
  if (url === '/api/v1/folders/' && init.method === 'GET') return { ok: true, json: async () => sc.folders };
  if (url === '/api/v1/folders/' && init.method === 'POST') return sc.createFails ? { ok: false, json: async () => ({}) } : { ok: true, json: async () => ({ id: 'new1', name: JSON.parse(init.body).name }) };
  return { ok: true, json: async () => ({}) };
};
const run = new Function('window', 'location', 'fetch', 'return (async () => {' + code + '})()');
(async () => {
  const res = await run(window, { ancestorOrigins: ['http://portal.example'] }, fetch);
  const hid = posted.length ? posted[0].id : null;
  for (const m of sc.msgs || []) {
    emit({ source: m.other ? {} : parent, data: { type: m.type || 'bn-portal-chat-filed', id: m.id === '$' ? hid : m.id, project: m.project } });
    await new Promise((r) => setTimeout(r, 20));
  }
  console.log(JSON.stringify({ res, calls, left: listeners.size }));
  process.exit(0);
})();
"""
CID = "8f1c2d3e-aaaa-bbbb-cccc-111122223333"


def _page(scenario, chat_id=CID):
    node = shutil.which("node")
    if not node:
        return None
    sc = {"reply": {"ok": True}, "folders": [], "msgs": [], **scenario}
    r = subprocess.run([node, "-e", _HARNESS, json.dumps(sc)], input=mp.js_for("t", "hello", chat_id), capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_told_where_it_went_the_chat_is_filed_in_a_new_folder_of_that_name():
    out = _page({"msgs": [{"id": "$", "project": "Trip planner"}]})
    if out is None:
        return
    assert out["res"] == {"ok": True, "tooBig": False, "error": ""}
    assert out["calls"] == [["/api/v1/folders/", "GET", None, "same-origin"], ["/api/v1/folders/", "POST", {"name": "Trip planner"}, "same-origin"],
                            [f"/api/v1/chats/{CID}/folder", "POST", {"folder_id": "new1"}, "same-origin"]]
    assert out["left"] == 0   # (heard once: nothing listens after)


def test_a_folder_of_that_name_at_the_top_is_used_not_a_nested_one():
    out = _page({"folders": [{"id": "n1", "name": "Trip", "parent_id": "p0"}, {"id": "f1", "name": "Trip", "parent_id": None}],
                 "msgs": [{"id": "$", "project": "  Trip\n"}]})
    if out is None:
        return
    assert [c[:3] for c in out["calls"]] == [["/api/v1/folders/", "GET", None], [f"/api/v1/chats/{CID}/folder", "POST", {"folder_id": "f1"}]]


def test_only_the_framing_page_saying_this_hand_offs_id_files_it_and_only_once():
    out = _page({"msgs": [{"id": "$", "project": "X", "other": True}, {"id": "hzzzzzzzz", "project": "X"},
                          {"id": "$", "project": "X", "type": "bn-portal-chat-handoff"}, {"id": "$", "project": "Real"},
                          {"id": "$", "project": "Again"}]})
    if out is None:
        return
    names = [c[2]["name"] for c in out["calls"] if c[:2] == ["/api/v1/folders/", "POST"]]
    assert names == ["Real"] and len(out["calls"]) == 3


def test_nothing_is_filed_for_a_temporary_chat_a_refused_hand_off_a_blank_name_or_a_folder_not_made():
    for scenario, chat_id in (({"msgs": [{"id": "$", "project": "X"}]}, "local:abc"), ({"msgs": [{"id": "$", "project": "X"}]}, 'a"b'),
                              ({"reply": {"ok": False, "error": "off"}, "msgs": [{"id": "$", "project": "X"}]}, CID),
                              ({"reply": {"ok": True, "tooBig": True}, "msgs": [{"id": "$", "project": "X"}]}, CID),
                              ({"msgs": [{"id": "$", "project": " \u0001 "}]}, CID)):
        out = _page(scenario, chat_id)
        if out is None:
            return
        assert out["calls"] == [], (scenario, chat_id, out)
        assert out["left"] == 0
    out = _page({"createFails": True, "msgs": [{"id": "$", "project": "X"}]})
    assert [c[:2] for c in out["calls"]] == [["/api/v1/folders/", "GET"], ["/api/v1/folders/", "POST"]]   # (no move into nothing)


def test_the_chat_id_goes_in_as_data_and_only_a_real_one():
    assert f'JSON.parse("\\"{CID}\\"")' in mp.js_for("t", "h", CID)
    for bad in ("local:x", "", None, "a\"b", "x" * 65, "../etc"):
        assert "const chatId = JSON.parse(\"null\");" in mp.js_for("t", "h", bad), bad
