"""Each person's layout of Home and the Terminal page (GET and PUT /api/ui/layout, portal/uilayout.py, static/widgets.js): behind the session and
the custom header, validated strictly, kept in one file in the state dir (atomic, mode 600), per kind of screen."""

import json
import os
import re
import stat
from dataclasses import replace

import httpx
import pytest
from starlette.testclient import TestClient

from portal import uilayout
from portal.app import STATIC, create_app

API = {"X-Requested-With": "devos-ade"}
ORIGIN = {"Origin": "http://devos-ade.localhost"}


def offline(request):
    raise httpx.ConnectError("offline in tests")


@pytest.fixture
def state(tmp_path):
    d = tmp_path / "state"; d.mkdir()
    return d


def make(settings, state_dir, login=True):
    s = replace(settings, state_dir=state_dir)
    c = TestClient(create_app(s, transport=httpx.MockTransport(offline)), base_url="http://devos-ade.localhost", follow_redirects=False)
    c.__enter__()
    if login:
        c.post("/login", data={"password": "correct horse"}, headers=ORIGIN)
    return c


@pytest.fixture
def client(settings, state):
    c = make(settings, state)
    yield c
    c.__exit__(None, None, None)


def doc(**devices):
    return {"version": 1, "pages": {"home": devices}}


def row(wid, span=4, height="auto", hidden=False):
    return {"id": wid, "span": span, "height": height, "hidden": hidden}


def test_it_needs_a_session_and_the_custom_header(settings, state, client):
    assert client.get("/api/ui/layout").status_code == 400
    assert client.put("/api/ui/layout", json=doc()).status_code == 400
    anon = make(settings, state, login=False)
    try:
        assert anon.get("/api/ui/layout", headers=API).status_code == 401
        assert anon.put("/api/ui/layout", json=doc(), headers=API).status_code == 401
    finally:
        anon.__exit__(None, None, None)
    assert not (state / "ui-layout.json").exists()


def test_nothing_saved_is_an_empty_layout_and_never_cached(client):
    r = client.get("/api/ui/layout", headers=API)
    assert r.status_code == 200 and r.json() == {"version": 1, "pages": {}}
    assert r.headers["cache-control"] == "no-store"


def test_a_layout_per_kind_of_screen_round_trips_and_one_never_changes_another(client):
    desk = [row("spend", 5), row("models", 4, "m"), row("feedback", 3, hidden=True)]
    phone = [row("models", 1), row("spend", 1, "s")]
    assert client.put("/api/ui/layout", json=doc(desktop=desk), headers=API).status_code == 200
    r = client.put("/api/ui/layout", json=doc(phone=phone), headers=API)
    assert r.status_code == 200
    got = client.get("/api/ui/layout", headers=API).json()
    assert got == r.json() == doc(desktop=desk, phone=phone)
    assert "tablet" not in got["pages"]["home"]
    tablet = [row("services", 3)]
    client.put("/api/ui/layout", json=doc(tablet=tablet), headers=API)
    # a null puts one screen back to the default; the others stay
    r = client.put("/api/ui/layout", json=doc(desktop=None), headers=API)
    assert r.json() == doc(phone=phone, tablet=tablet)
    client.put("/api/ui/layout", json=doc(phone=None, tablet=None), headers=API)
    assert client.get("/api/ui/layout", headers=API).json() == {"version": 1, "pages": {}}


def test_a_widget_the_portal_does_not_have_is_dropped_and_the_rest_kept(client):
    r = client.put("/api/ui/layout", json=doc(desktop=[row("spend"), row("from-a-later-release"), row("models"), row("spend", 9)]), headers=API)
    assert r.status_code == 200
    assert [e["id"] for e in r.json()["pages"]["home"]["desktop"]] == ["spend", "models"]   # (the first of two spends)


def test_spans_are_clamped_to_the_widgets_minimum_and_the_screens_columns(client):
    r = client.put("/api/ui/layout", json=doc(desktop=[row("spend", 99), row("models", 0), row("services", -3)],
                                              tablet=[row("spend", 12), row("models", 1)], phone=[row("spend", 7)]), headers=API)
    h = r.json()["pages"]["home"]
    assert [e["span"] for e in h["desktop"]] == [12, 4, 3]     # 12 columns; models and services have a narrowest
    assert [e["span"] for e in h["tablet"]] == [6, 3]          # 6 columns
    assert [e["span"] for e in h["phone"]] == [1]              # one column: nothing to resize


def test_a_height_outside_auto_s_m_l_is_auto(client):
    r = client.put("/api/ui/layout", json=doc(desktop=[row("spend", 5, "xl"), row("models", 4, "L"), row("services", 3, "l")]), headers=API)
    assert [e["height"] for e in r.json()["pages"]["home"]["desktop"]] == ["auto", "auto", "l"]


@pytest.mark.parametrize("body", [
    [], "x", None, {"version": 2, "pages": {}}, {"pages": {}}, {"version": 1}, {"version": 1, "pages": []},
    {"version": 1, "pages": {}, "extra": 1},
    {"version": 1, "pages": {"code": {"desktop": []}}},            # a page the portal does not have (yet)
    {"version": 1, "pages": {"home": {"watch": []}}},               # a screen it does not know
    {"version": 1, "pages": {"home": []}},
    {"version": 1, "pages": {"home": {"desktop": "spend"}}},
    {"version": 1, "pages": {"home": {"desktop": ["spend"]}}},
    {"version": 1, "pages": {"home": {"desktop": [{"id": 3, "span": 4}]}}},
    {"version": 1, "pages": {"home": {"desktop": [{"id": "spend", "span": "4"}]}}},
    {"version": 1, "pages": {"home": {"desktop": [{"id": "spend", "span": 4.5}]}}},
    {"version": 1, "pages": {"home": {"desktop": [{"id": "spend", "span": True}]}}},
    {"version": 1, "pages": {"home": {"desktop": [{"id": "spend", "span": 4, "hidden": "yes"}]}}},
    {"version": 1, "pages": {"home": {"desktop": [{"id": "spend", "span": 4, "hidden": 1}]}}},
    {"version": 1, "pages": {"home": {"desktop": [{"id": "spend", "span": 4, "height": 3}]}}},
    {"version": 1, "pages": {"home": {"desktop": [row("spend")] * 40}}},
])
def test_anything_else_is_refused_and_nothing_is_written(client, state, body):
    r = client.put("/api/ui/layout", json=body, headers=API)
    assert r.status_code == 400 and "error" in r.json()
    assert not (state / "ui-layout.json").exists()


def test_not_json_is_refused(client):
    r = client.put("/api/ui/layout", content=b"{nope", headers={**API, "Content-Type": "application/json"})
    assert r.status_code == 400


def test_a_body_over_the_cap_is_refused_before_it_is_read_whole(client, state):
    big = json.dumps({"version": 1, "pages": {"home": {"desktop": [], "pad": "x" * (uilayout.MAX_BYTES + 10)}}})
    r = client.put("/api/ui/layout", content=big.encode(), headers={**API, "Content-Type": "application/json"})
    assert r.status_code == 413 and not (state / "ui-layout.json").exists()
    assert uilayout.MAX_BYTES == 32 * 1024


def test_the_file_is_written_whole_with_mode_600_and_no_temp_file_is_left(client, state):
    desk = [row("spend", 5), row("models", 4)]
    assert client.put("/api/ui/layout", json=doc(desktop=desk), headers=API).status_code == 200
    f = state / "ui-layout.json"
    assert stat.S_IMODE(os.stat(f).st_mode) == 0o600
    assert json.loads(f.read_text()) == doc(desktop=desk)
    assert not [p for p in state.iterdir() if p.name.endswith(".tmp")]


def test_a_failed_write_leaves_the_old_file_and_says_so(client, state, monkeypatch):
    client.put("/api/ui/layout", json=doc(desktop=[row("spend", 5)]), headers=API)
    before = (state / "ui-layout.json").read_bytes()

    def boom(src, dst):
        raise OSError("disk full")
    monkeypatch.setattr(os, "replace", boom)
    r = client.put("/api/ui/layout", json=doc(desktop=[row("models", 4)]), headers=API)
    assert r.status_code == 503 and "could not be saved" in r.json()["error"]
    assert (state / "ui-layout.json").read_bytes() == before
    assert not [p for p in state.iterdir() if p.name.endswith(".tmp")]


def test_a_damaged_or_hand_edited_file_is_the_defaults_not_an_error(client, state):
    f = state / "ui-layout.json"
    f.write_text("{not json")
    assert client.get("/api/ui/layout", headers=API).json() == {"version": 1, "pages": {}}
    f.write_text(json.dumps(doc(desktop=[row("spend", 99, "huge"), row("nope")])))
    assert client.get("/api/ui/layout", headers=API).json() == doc(desktop=[row("spend", 12)])
    f.write_text(" " * (uilayout.MAX_BYTES + 1))
    assert client.get("/api/ui/layout", headers=API).json() == {"version": 1, "pages": {}}


def test_without_a_state_dir_it_reads_empty_and_says_a_save_is_not_kept(settings):
    c = make(settings, None)
    try:
        assert c.get("/api/ui/layout", headers=API).json() == {"version": 1, "pages": {}}
        r = c.put("/api/ui/layout", json=doc(desktop=[row("spend")]), headers=API)
        assert r.status_code == 503
    finally:
        c.__exit__(None, None, None)


def test_the_widget_table_is_the_scripts():
    js = (STATIC / "widgets.js").read_text(encoding="utf-8")
    for const, page in (("HOME", "home"), ("TERMINAL", "terminal")):
        table = js[js.index(f"const {const} = ["):]
        table = table[:table.index("];")]
        rows = re.findall(r'id: "([a-z-]+)", title: "[^"]*", min: \[(\d+), (\d+)\]', table)
        assert {i: (int(a), int(b)) for i, a, b in rows} == uilayout.PAGES[page], page
    assert 'fixed: true' in js[js.index("const TERMINAL = ["):].split("];")[0] and uilayout.FIXED == {"terminal": ("terminals",)}
    assert re.search(r"VIEWS_MAX = 4", js) and uilayout.VIEWS_MAX == 4 and re.search(r'SPLITS = \["cols", "rows", "grid"\]', js) and uilayout.SPLITS == ("cols", "rows", "grid")
    assert re.search(r"COMMANDS_MAX = 20, COMMAND_LABEL_MAX = 40, COMMAND_TEXT_MAX = 200", js)
    assert (uilayout.COMMANDS_MAX, uilayout.COMMAND_LABEL_MAX, uilayout.COMMAND_TEXT_MAX) == (20, 40, 200)
    assert re.search(r"const COLS = \{ desktop: 12, tablet: 6, phone: 1 \}", js) and uilayout.DEVICES == {"desktop": 12, "tablet": 6, "phone": 1}
    assert re.search(r'const HEIGHTS = \["auto", "s", "m", "l"\]', js) and uilayout.HEIGHTS == ("auto", "s", "m", "l")
    assert re.search(r"const MAX_BYTES = 32 \* 1024", js)


def test_the_page_loads_the_engine_after_home_and_feedback_and_keeps_the_csp_clean():
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    order = [html.index(f'src="/static/{f}"') for f in ("home.js", "feedback.js", "widgets.js")]
    assert order == sorted(order)
    assert 'href="/static/widgets.css"' in html
    assert " style=" not in html and not re.search(r"\son[a-z]+=", html)


def test_every_widget_is_marked_in_homes_markup_and_the_old_wrappers_stay():
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    marked = re.findall(r'data-widget="([a-z-]+)"', html)
    assert sorted(marked) == sorted(uilayout.PAGES["home"])
    # Customize in the header; the tray and its live region; the anchored parts are not widgets
    head = html[html.index('<header class="home-head">'):html.index("</header>")]
    assert 'id="customize"' in head and 'aria-controls="widget-tray"' in head
    assert 'id="wg-live"' in html and 'role="status"' in html.split('id="wg-live"')[1][:60]
    for anchored in ('id="load-error"', 'id="install-note"', 'id="app-note"', 'id="job"'):
        assert anchored in html and not re.search(rf'{anchored}[^>]*data-widget', html)
    # today's wrappers (JON-812) are still there, inside #widgets
    inner = html[html.index('<div id="widgets"'):]
    assert inner.index('class="home-top"') < inner.index('id="update-card"') < inner.index('id="job"') < inner.index('class="grid"')
    feedback = (STATIC / "feedback.js").read_text(encoding="utf-8")
    assert 'dataset.widget = "feedback"' in feedback   # (Send feedback's card replaces its placeholder)


# --- the Terminal page (JON-946): its screens are objects, and the quick commands are the person's on every screen ---

def tdoc(**kw):
    return {"version": 1, "pages": {"terminal": kw}}


def trow(wid, span=12, height="auto", hidden=False):
    return row(wid, span, height, hidden)


def test_a_terminal_screen_round_trips_with_its_views_split_weights_and_the_commands(client):
    body = tdoc(desktop={"widgets": [trow("terminals"), trow("keys", 6), trow("commands", 6, "m"), trow("projects", 6, hidden=True)],
                         "views": 3, "split": "grid", "weights": [60, 40]},
                phone={"widgets": [trow("terminals", 1), trow("keys", 1)], "views": 1},
                commands=[{"label": "Tests", "text": "npm test", "run": True}, {"label": "Status", "text": "git status", "run": False}])
    r = client.put("/api/ui/layout", json=body, headers=API)
    assert r.status_code == 200
    got = client.get("/api/ui/layout", headers=API).json()["pages"]["terminal"]
    assert got["desktop"] == {"widgets": [trow("terminals"), trow("keys", 6), trow("commands", 6, "m"), trow("projects", 6, hidden=True)],
                              "views": 3, "split": "grid", "weights": [60, 40]}
    assert got["phone"] == {"widgets": [trow("terminals", 1), trow("keys", 1)], "views": 1, "split": "cols", "weights": []}
    assert got["commands"] == body["pages"]["terminal"]["commands"]
    # a screen saved alone leaves the others and the commands as they were; null puts one back to the default
    client.put("/api/ui/layout", json=tdoc(tablet={"views": 2}), headers=API)
    got = client.get("/api/ui/layout", headers=API).json()["pages"]["terminal"]
    assert set(got) == {"desktop", "phone", "tablet", "commands"} and got["tablet"]["views"] == 2 and got["tablet"]["widgets"] == []
    client.put("/api/ui/layout", json=tdoc(desktop=None, commands=None), headers=API)
    assert set(client.get("/api/ui/layout", headers=API).json()["pages"]["terminal"]) == {"phone", "tablet"}


def test_the_terminals_widget_cannot_be_hidden_and_the_numbers_are_clamped(client):
    body = tdoc(desktop={"widgets": [trow("terminals", 2, hidden=True), trow("nonsense"), trow("keys", 99)], "views": 9, "split": "diagonal",
                         "weights": [0, 500, 50]},
                phone={"views": 4})
    client.put("/api/ui/layout", json=body, headers=API)
    got = client.get("/api/ui/layout", headers=API).json()["pages"]["terminal"]
    assert got["desktop"] == {"widgets": [trow("terminals", 4), trow("keys", 12)], "views": 4, "split": "cols", "weights": [1, 100, 50]}
    assert got["phone"]["views"] == 1   # (a phone has one view)
    client.put("/api/ui/layout", json=tdoc(desktop={"views": -3}), headers=API)
    assert client.get("/api/ui/layout", headers=API).json()["pages"]["terminal"]["desktop"]["views"] == 1


@pytest.mark.parametrize("screen", [
    [trow("terminals")],                                   # (the Terminal page's screen is an object)
    "views",
    {"views": "2"}, {"views": 2.5}, {"views": True}, {"views": None},
    {"split": 3}, {"split": ["cols"]},
    {"weights": "50"}, {"weights": [50] * 5}, {"weights": ["a"]}, {"weights": [True]}, {"weights": [1.5]},
    {"widgets": "terminals"}, {"widgets": [trow("terminals")] * 40}, {"widgets": [7]},
    {"widgets": [], "extra": 1}, {"commands": []},          # (the commands are the page's, not a screen's)
])
def test_a_terminal_screen_that_is_anything_else_is_refused(client, state, screen):
    r = client.put("/api/ui/layout", json=tdoc(desktop=screen), headers=API)
    assert r.status_code == 400 and "error" in r.json()
    assert not (state / "ui-layout.json").exists()


def cmd(label="Tests", text="npm test", run=False):
    return {"label": label, "text": text, "run": run}


def test_quick_commands_are_kept_within_their_limits(client, state):
    ok = [cmd("a" * 40, "x" * 200, True), cmd("é 日本", "echo é 日本 😀"), cmd("x", "y")] + [cmd(f"c{i}", f"echo {i}") for i in range(17)]
    assert len(ok) == 20
    assert client.put("/api/ui/layout", json=tdoc(commands=ok), headers=API).status_code == 200
    assert client.get("/api/ui/layout", headers=API).json()["pages"]["terminal"]["commands"] == ok
    # an empty list is none kept
    client.put("/api/ui/layout", json=tdoc(commands=[]), headers=API)
    assert "terminal" not in client.get("/api/ui/layout", headers=API).json()["pages"]


@pytest.mark.parametrize("commands", [
    [cmd()] * 21,
    [cmd("a" * 41)], [cmd("")], [cmd(text="x" * 201)], [cmd(text="")],
    [cmd(text="ls\n")], [cmd(text="a\nb")], [cmd(text="\x1b[31m")], [cmd(text="a\tb")], [cmd(text="x\x00")], [cmd(text="a\u2028b")], [cmd(text="a\u200bb")],
    [cmd("a\nb")], [cmd("\x07")],
    [{"label": "a", "text": "b", "run": "true"}], [{"label": "a", "text": "b", "run": 1}], [{"label": "a", "text": "b", "extra": 1}],
    [{"label": "a"}], [{"text": "b"}], [{"label": 1, "text": "b"}], [{"label": "a", "text": ["b"]}],
    ["npm test"], [None], "npm test", {"label": "a", "text": "b"}, 7,
])
def test_a_quick_command_that_is_not_one_is_refused(client, state, commands):
    r = client.put("/api/ui/layout", json=tdoc(commands=commands), headers=API)
    assert r.status_code == 400 and "error" in r.json()
    assert not (state / "ui-layout.json").exists()


def test_a_run_flag_is_optional_and_false_without_it(client):
    client.put("/api/ui/layout", json=tdoc(commands=[{"label": "a", "text": "b"}]), headers=API)
    assert client.get("/api/ui/layout", headers=API).json()["pages"]["terminal"]["commands"] == [cmd("a", "b", False)]


def test_commands_belong_to_the_terminal_page_alone(client, state):
    r = client.put("/api/ui/layout", json=doc(commands=[row("spend")]), headers=API)
    assert r.status_code == 400 and not (state / "ui-layout.json").exists()
    r = client.put("/api/ui/layout", json={"version": 1, "pages": {"code": {"desktop": []}}}, headers=API)
    assert r.status_code == 400


def test_a_damaged_terminal_entry_in_the_file_is_the_defaults_not_an_error(client, state):
    (state / "ui-layout.json").write_text(json.dumps(tdoc(desktop={"views": "many"})))
    assert client.get("/api/ui/layout", headers=API).json() == {"version": 1, "pages": {}}
    (state / "ui-layout.json").write_text(json.dumps(tdoc(commands=[cmd(text="a\nb")])))
    assert client.get("/api/ui/layout", headers=API).json() == {"version": 1, "pages": {}}


def test_the_most_a_person_can_keep_fits_the_file(client, state):
    pad = [cmd("l" * 40, "t" * 200, True) for _ in range(20)]
    screens = {d: {"widgets": [trow("terminals"), trow("keys"), trow("commands"), trow("projects")], "views": 4, "split": "grid", "weights": [25] * 4}
               for d in ("desktop", "tablet")}
    body = {"version": 1, "pages": {"home": {d: [row(w) for w in uilayout.PAGES["home"]] for d in ("desktop", "tablet", "phone")},
                                    "terminal": {**screens, "phone": {"widgets": [trow("terminals", 1)]}, "commands": pad}}}
    assert client.put("/api/ui/layout", json=body, headers=API).status_code == 200
    assert (state / "ui-layout.json").stat().st_size < uilayout.MAX_BYTES


def test_the_terminal_page_loads_after_the_engine_and_its_widgets_are_built_by_the_script():
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    order = [html.index(f'src="/static/{f}"') for f in ("answers.js", "widgets.js", "termpage.js")]
    assert order == sorted(order)
    assert 'href="/static/termpage.css"' in html
    # (the markup has none of its widgets: the script builds them, so Home's one-table check of data-widget stays Home's)
    assert not set(uilayout.PAGES["terminal"]) & set(re.findall(r'data-widget="([a-z-]+)"', html))
    js = (STATIC / "termpage.js").read_text(encoding="utf-8")
    for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"):
        assert sink not in js, sink
    # nothing it sends to a terminal frame but the four messages ttyd-keys.js reads, and only to the terminal host's origin
    assert sorted(set(re.findall(r'post\((?:paneFrame\(\)|f), \{ type: "([a-z]+)"', js))) == ["focus", "key", "mods", "text"]
    assert "postMessage(msg, termOrigin)" in js and 'postMessage(msg, "*")' not in js
    assert 'launch("view", String(n), "")' in js
