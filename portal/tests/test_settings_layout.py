"""Settings › the page's layout: catalog/settings-layout.tsv (sections, More, parent switches, summaries) as the
portal reads and serves it, the deep links into it (#settings/<section>, #settings/<KEY>), and the page code that
hides a setting while its switch is off. The checks against the real catalog, README and docs need the repository:
in a checkout, or in the test image when portal/test.sh passes it in (BN_REPO_DIR=/repo); a plain
`docker build --target test portal` skips them. tests/test_settings.sh checks the same file from the shell, and
portal/e2e/settings/run.sh every key's controls in a browser."""

import json
import os
import re
from pathlib import Path

import httpx
import pytest
from starlette.testclient import TestClient

from portal import settings as st
from portal.app import STATIC, create_app
from dataclasses import replace

ORIGIN = {"Origin": "http://bedrock-now.localhost"}
API = {"X-Requested-With": "bedrock-now"}
REPO = Path(os.environ.get("BN_REPO_DIR") or Path(__file__).resolve().parents[2])
REAL = REPO / "catalog" / "settings-layout.tsv"
TABLE = REPO / "catalog" / "settings.tsv"
need_repo = pytest.mark.skipif(not (REAL.is_file() and TABLE.is_file() and (REPO / "README.md").is_file()),
                               reason="the repository's catalog/README are not here: portal/test.sh passes them to the test image")

LAYOUT = """# a comment
@account\tAccount & security\tYour password.\tREADME.md#settings
PORTAL_PASSWORD\taccount\tmain\t-\tThe one password.
PORTAL_PASSWORD_HASH\taccount\twith\tPORTAL_PASSWORD\t-
+devices\taccount\tmain\t-\tEvery browser signed in.

@updates\tUpdates & backups\tNew releases.\tdocs/remote.md
BACKUP_NIGHTLY\tupdates\tmain\t-\tBack up every night.
BACKUP_HOUR\tupdates\tmain\tBACKUP_NIGHTLY\tWhen the window starts.
UPDATE_REQUIRE_SIGNED_TAGS\tupdates\tmore\t-\tSigned releases only.
"""


def offline(request):
    raise httpx.ConnectError("offline in tests")


def write(tmp_path, text, name=st.LAYOUT):
    (tmp_path / name).write_text(text, encoding="utf-8")
    st._layout_cache.clear()
    return tmp_path


def test_layout_reads_sections_and_rows_in_the_files_order(tmp_path):
    lay = st.layout(write(tmp_path, LAYOUT))
    assert [s["id"] for s in lay["sections"]] == ["account", "updates"]
    assert lay["sections"][0] == {"id": "account", "title": "Account & security", "lede": "Your password.", "doc": "README.md#settings"}
    assert [r["key"] for r in lay["rows"]] == ["PORTAL_PASSWORD", "PORTAL_PASSWORD_HASH", "+devices", "BACKUP_NIGHTLY", "BACKUP_HOUR",
                                              "UPDATE_REQUIRE_SIGNED_TAGS"]
    rows = {r["key"]: r for r in lay["rows"]}
    assert rows["PORTAL_PASSWORD_HASH"] == {"key": "PORTAL_PASSWORD_HASH", "section": "account", "place": "with",
                                            "parent": "PORTAL_PASSWORD", "summary": ""}
    assert rows["BACKUP_HOUR"]["parent"] == "BACKUP_NIGHTLY" and rows["BACKUP_NIGHTLY"]["parent"] == ""
    assert rows["UPDATE_REQUIRE_SIGNED_TAGS"]["place"] == "more"


def test_layout_drops_what_it_does_not_know(tmp_path):
    bad = "\n".join([
        "@account\tAccount\tok\tjavascript:alert(1)",      # a link only to a page of the repository
        "@account\tAgain\tdup\t-",                          # a section once
        "@nosuch\tNo such section\tx\t-",
        "@updates\t" + "T" * 200 + "\t" + "L" * 900 + "\thttps://evil.example/x",
        "PORTAL_PASSWORD\taccount\tmain\t-\t" + "s" * 500,
        "PORTAL_PASSWORD\taccount\tmore\t-\tdup",            # a key once
        "bad key\taccount\tmain\t-\tx",
        "lower_case\taccount\tmain\t-\tx",
        "+unknown\taccount\tmain\t-\tnot one of the page's own rows",
        "AWS_REGION_NAME\tnosuch\tmain\t-\tx",              # a section the file does not have
        "BUDGET_SETUP\taccount\ttop\t-\tx",                 # main, more or with
        "BUDGET_OPENWEBUI\taccount\tmain\tnot a key\tx",
        "STT_MODEL\taccount\twith\t-\t-",                   # with: always inside another row
        "SHORT\taccount\tmain",                             # five columns
    ])
    lay = st.layout(write(tmp_path, bad))
    assert [s["id"] for s in lay["sections"]] == ["account", "updates"]
    assert lay["sections"][0]["doc"] == "" and lay["sections"][0]["title"] == "Account"
    assert lay["sections"][1]["doc"] == "" and len(lay["sections"][1]["title"]) == 60 and len(lay["sections"][1]["lede"]) == 400
    assert [r["key"] for r in lay["rows"]] == ["PORTAL_PASSWORD"]
    assert len(lay["rows"][0]["summary"]) == 200 and lay["rows"][0]["place"] == "main"


def test_no_layout_a_big_one_or_a_link_gives_none(tmp_path):
    empty = {"sections": [], "rows": []}
    assert st.layout(tmp_path) == empty
    write(tmp_path, "#" * (st.MAX_LAYOUT + 1))
    assert st.layout(tmp_path) == empty
    (tmp_path / st.LAYOUT).unlink()
    (tmp_path / "elsewhere.tsv").write_text(LAYOUT)
    os.symlink(tmp_path / "elsewhere.tsv", tmp_path / st.LAYOUT)
    st._layout_cache.clear()
    assert st.layout(tmp_path) == empty


def test_layout_follows_the_file(tmp_path):
    assert len(st.layout(write(tmp_path, LAYOUT))["rows"]) == 6
    (tmp_path / st.LAYOUT).write_text(LAYOUT + "AUTO_UPDATE\tupdates\tmain\t-\tInstall a new release at night.\n")
    assert len(st.layout(tmp_path)["rows"]) == 7   # a new size: read again (an update brings a new layout)


def test_get_settings_carries_the_layout(settings, tmp_path):
    write(settings.catalog_dir, LAYOUT)
    sd = tmp_path / "status"; sd.mkdir()
    with TestClient(create_app(replace(settings, status_dir=sd, request_dir=tmp_path), transport=httpx.MockTransport(offline)),
                    base_url="http://bedrock-now.localhost", follow_redirects=False) as c:
        assert c.get("/api/settings", headers=API).status_code == 401
        assert c.post("/login", data={"password": "correct horse"}, headers=ORIGIN).status_code == 303
        d = c.get("/api/settings", headers=API).json()
    assert [s["id"] for s in d["layout"]["sections"]] == ["account", "updates"] and len(d["layout"]["rows"]) == 6


def test_a_note_is_whole_on_the_page(tmp_path):
    # the full explanation (Details, and the confirmation of a change): Auto mode's is ~1,250 characters
    long = "Auto mode. " * 120
    (tmp_path / "settings.json").write_text(json.dumps({"version": 1, "keys": [
        {"key": "CODE_AUTO_MODE", "group": "advanced", "secret": "-", "policy": "widen-local", "validator": "bool", "apply": "code-env",
         "label": "Auto mode", "note": long, "cli": "x", "present": True, "set": True, "value": "false"},
        {"key": "X_LONG", "group": "advanced", "secret": "-", "policy": "ro", "validator": "-", "apply": "-", "label": "x",
         "note": "n" * 5000, "cli": "x", "present": True, "set": True, "value": ""}]}))
    k = st.by_key(st.snapshot(tmp_path))
    assert k["CODE_AUTO_MODE"]["note"] == long and len(long) > 600
    assert len(k["X_LONG"]["note"]) == st.MAX_NOTE


# --- the real catalog ---

def _table():
    rows = [l.rstrip("\n").split("\t") for l in TABLE.read_text().splitlines() if l and not l.startswith("#")]
    return {r[0]: r for r in rows if r[0] != "key" and len(r) >= 9}


@need_repo
def test_every_key_has_one_place_in_a_known_section():
    st._layout_cache.clear()
    lay = st.layout(REAL.parent)
    table = _table()
    assert [s["id"] for s in lay["sections"]] == list(st.SECTIONS)
    assert all(s["title"] and s["lede"] and s["doc"] for s in lay["sections"])
    keys = [r["key"] for r in lay["rows"] if not r["key"].startswith("+")]
    assert sorted(keys) == sorted(table) and len(keys) == len(set(keys))   # every key of settings.tsv exactly once
    # (the parser drops a row it does not understand: as many rows as the file has)
    lines = [l for l in REAL.read_text().splitlines() if l and not l.startswith(("#", "@"))]
    assert len(lines) == len(lay["rows"])
    assert sorted(r["key"] for r in lay["rows"] if r["key"].startswith("+")) == sorted(st.OWN_ROWS)
    rows = {r["key"]: r for r in lay["rows"]}
    for r in lay["rows"]:
        if r["parent"]:
            p = rows[r["parent"]]
            assert p["section"] == r["section"], r          # a switch of the same section
            assert p["place"] != "with" and (not p["key"].startswith("+") or r["place"] == "with"), r
        if r["place"] == "with":
            assert r["parent"] and not r["summary"], r
        else:
            assert r["summary"] and len(r["summary"]) <= 120 and r["summary"].endswith("."), r   # one plain line


@need_repo
def test_sections_hold_what_their_task_needs():
    st._layout_cache.clear()
    rows = {r["key"]: r for r in st.layout(REAL.parent)["rows"]}
    table = _table()
    where = lambda k: (rows[k]["section"], rows[k]["place"], rows[k]["parent"])   # noqa: E731
    # the Code page with Bypass and Auto under it; the terminal with its internet access and Auto mode
    assert where("CODE_ENABLED") == ("code", "main", "") and where("CODE_ALLOW_BYPASS") == ("code", "main", "CODE_ENABLED")
    assert where("CODE_AUTO_MODE") == ("code", "main", "CODE_ENABLED")
    assert where("TERMINAL_AUTO_MODE") == ("code", "main", "TERMINAL_ENABLED") and where("TERMINAL_EGRESS")[0] == "code"
    # every budget with its key, the terminal's too (it was read-only under Advanced)
    for b, k in (("BUDGET_OPENWEBUI", "LITELLM_KEY_OPENWEBUI"), ("BUDGET_CLAUDE_CODE", "LITELLM_KEY_CLAUDE_CODE"),
                 ("BUDGET_TERMINAL", "LITELLM_KEY_TERMINAL"), ("BUDGET_SETUP", "LITELLM_KEY_SETUP")):
        assert rows[b]["section"] == "spending" and where(k) == ("spending", "with", b)
    assert where("BUDGET_TERMINAL") == ("spending", "main", "")
    # Chat's models with Chat, Claude Code's with Claude Code; voice with Chat
    assert rows["CHAT_DEFAULT_MODEL"]["section"] == "chat" and rows["CLAUDE_MODEL_OPUS"]["section"] == "code"
    assert rows["STT_PROVIDER"]["section"] == "chat"
    # every key and sign-in that adds models in one place, Models & providers: each provider's key a card of its own
    # (its models' rows inside it), then your subscriptions, then Search: Claude Code's WebSearch and a card for each of
    # its backends; none of them left in Bedrock (AWS), Chat & voice or Claude Code
    assert [k for k, r in rows.items() if r["section"] == "providers" and r["place"] == "main" and not r["parent"]] == \
        ["AWS_ACCESS_KEY_ID", "OPENROUTER_API_KEY", "EXPLABS_API_KEY", "+subscriptions", "+local-models", "WEBSEARCH_BACKEND", "WEBSEARCH_SEARXNG_BUILTIN",
         "WEBSEARCH_AGENTCORE_GATEWAY", "WEBSEARCH_TAVILY_API_KEY", "WEBSEARCH_BRAVE_API_KEY", "WEBSEARCH_PERPLEXITY_API_KEY", "WEBSEARCH_SEARXNG_URL"]
    assert where("AWS_SECRET_ACCESS_KEY") == ("providers", "with", "AWS_ACCESS_KEY_ID")
    assert where("OPENROUTER_MODELS") == ("providers", "main", "OPENROUTER_API_KEY") and where("EXPLABS_MODELS") == ("providers", "main", "EXPLABS_API_KEY")
    assert where("OPENROUTER_MAX_MODELS") == where("OPENROUTER_INCLUDE_ALIASES") == ("providers", "more", "OPENROUTER_API_KEY")
    assert not [k for k, r in rows.items() if r["section"] in ("aws", "chat", "code") and re.match(r"(AWS_ACCESS|AWS_SECRET|OPENROUTER|EXPLABS)_", k)]
    # remote access's switches only while it is on; nightly backups' window and count only while they are on
    for k in ("TAILSCALE_ALLOWED_LOGIN", "REMOTE_ADMIN_ACTIONS", "REMOTE_TERMINAL"):
        assert where(k) == ("remote", "main", "REMOTE_MODE")
    assert where("REMOTE_PREVIEW") == ("remote", "main", "REMOTE_TERMINAL")
    assert where("BACKUP_HOUR")[2] == where("BACKUP_KEEP")[2] == "BACKUP_NIGHTLY" and where("AUTO_UPDATE_HOUR")[2] == "AUTO_UPDATE"
    # nothing that changes from the page hides in Advanced or About; About is what ./stack writes
    for k, r in rows.items():
        if r["section"] in ("advanced", "about"):
            assert table[k][3] in ("ro", "derived"), k
        if r["section"] == "about":
            assert table[k][3] == "derived", k
    editable = [k for k, t in table.items() if t[3] in ("edit", "local", "on-only", "widen-local", "regen")]
    assert all(rows[k]["place"] in ("main", "more") or k in ("AWS_SECRET_ACCESS_KEY", "STT_API_KEY", "STT_MODEL", "RUSTFS_SECRET_KEY", "GIT_GITHUB_APP_SLUG",
                                                            "CODE_CLAUDE_PLAN", "HF_TOKEN", "MODEL_SERVERS", "MODEL_SERVER_KEYS", "MODEL_SERVER_MODELS")
               for k in editable)
    # the Claude plan switch on Claude's card in Your AI subscriptions (where each tool is connected), not a row of its
    # own
    assert where("CODE_CLAUDE_PLAN") == ("providers", "with", "+subscriptions")
    # Git hosts' sign-in: the apps' IDs under the Code page's More (the GitHub App's name with its client ID)
    assert where("GIT_GITHUB_CLIENT_ID") == ("code", "more", "CODE_ENABLED") and where("GIT_GITLAB_CLIENT_ID") == ("code", "more", "CODE_ENABLED")
    assert where("GIT_GITHUB_APP_SLUG") == ("code", "with", "GIT_GITHUB_CLIENT_ID")
    assert all(table[k][3] == "local" for k in ("GIT_GITHUB_CLIENT_ID", "GIT_GITHUB_APP_SLUG", "GIT_GITLAB_CLIENT_ID"))


@need_repo
def test_links_into_settings_name_a_section_or_a_setting():
    st._layout_cache.clear()
    lay = st.layout(REAL.parent)
    places = {s["id"] for s in lay["sections"]} | {r["key"] for r in lay["rows"]}
    found = []
    for f in ("code.js", "index.html", "settings.js", "app.js", "answers.js"):
        found += re.findall(r'#settings/([A-Za-z_+-]+)', (STATIC / f).read_text(encoding="utf-8"))
    tour = (STATIC / "tour.js").read_text(encoding="utf-8")
    names = dict(re.findall(r'"([^"]+)": "([A-Za-z_]+)"', tour[tour.index("const PLACES = {"):tour.index("const settings = (where, place)")]))
    found += list(names.values()) + re.findall(r'settings\("[^"]+", "([A-Za-z_]+)"\)', tour)
    alone = re.findall(r'settings\("([^"]+)"\)', tour)   # settings(WHERE): a place named in PLACES
    assert alone and not [w for w in alone if w not in names], alone
    assert len(found) >= 10
    assert not [p for p in found if p not in places], found


def _anchors(text: str) -> set:
    """GitHub's heading anchors: lower case, punctuation dropped, spaces to hyphens ("Costs & budgets" -> costs--budgets)."""
    out = set()
    for line in text.splitlines():
        m = re.match(r"#{1,6} (.+)", line)
        if m:
            out.add(re.sub(r"[^\w\- ]", "", m.group(1).strip().lower()).replace(" ", "-"))
    return out


@need_repo
def test_learn_more_links_reach_a_heading():
    st._layout_cache.clear()
    for s in st.layout(REAL.parent)["sections"]:
        path, _, frag = s["doc"].partition("#")
        f = REPO / path
        assert f.is_file(), s
        if frag:
            assert frag in _anchors(f.read_text(encoding="utf-8")), f"{s['id']}: {s['doc']} names no heading"


def test_the_page_and_the_server_say_less_protection_the_same_way():
    # a form refuses the less protective direction remotely before the password, in the server's words
    js = _js()
    words = dict(re.findall(r'(\w+): "([a-z ]+)"', js[js.index("const WEAKEN_WORD = {"):js.index("function localOnlyHere(k, value)")]))
    assert words == st._WEAKEN_WORD
    form = js[js.index("const weak = Object.keys(values).find("):js.index("confirmApply(values, `Save ${k.label}?`")]
    assert 'keys[n].policy === "widen-local" && localOnlyHere(keys[n], values[n])' in form
    assert "from the computer running DevOS ADE (the other way works everywhere)" in form


def test_without_a_layout_every_setting_keeps_its_row():
    # a damaged checkout: one section of ordinary rows (not the read-only list), pairs inside their rows, own rows
    js = _js()
    fb = js[js.index("function fallbackLayout() {"):js.index("// The layout from catalog/settings-layout.tsv")]
    assert 'section: "all", place: "main"' in fb and 'place: "with", parent: FALLBACK_WITH[k]' in fb
    assert '"+devices", "+models", "+backups", "+test", "+check-aws", "+report", "+restart", "+git-hosts"' in fb
    assert 'if (!(l.sections || []).length) l = fallbackLayout();' in js
    assert 'const list = s.id === "advanced" || s.id === "about";' in js   # "all" renders rows


# --- the page code (string checks: the portal's tests run no browser; tests/e2e/browser/checks_browser.py does) ---

def _js(name="settings.js"):
    return (STATIC / name).read_text(encoding="utf-8")


def test_the_address_keeps_a_place_inside_a_page():
    app = _js("app.js")
    show = app[app.index("function showTab(tab) {"):app.index("// --- formatting ---")]
    assert 'const [name, ...place] = String(tab || "").split("/");' in show and "tab = name;" in show
    # only a page of the portal keeps it (an app's tab never), and only through replaceState: no new history entry
    assert 'const hash = place.length && PAGES.includes(tab) ? `#${tab}/${place.join("/")}` : `#${tab}`;' in show
    js = _js()
    go = js[js.index("function goTo(place) {"):js.index("// --- what is shown")]
    # a section id or a key the layout knows; a key shown inside another row opens that row; nothing else is used
    assert "if (sectionOf(part)) sec = part;" in go and "KEY_NAME.test(part)" in go and "&& rowOf[part]" in go
    assert 'rowOf[key].place === "with"' in go and "more.open = true;" in go and 'classList.add("set-forced")' in go
    # (the same names as every setup link's target: answers.py, answers.js and the Code page's setuplinks.ts)
    assert "const KEY_NAME = /^[A-Z][A-Z0-9_]{1,60}$/;" in js
    from portal import answers
    assert "[A-Z][A-Z0-9_]{1,60}" in answers.SETUP_TARGET.pattern
    assert "[A-Z][A-Z0-9_]{1,60}" in _js("answers.js")
    ts = REPO / "code" / "web" / "src" / "setuplinks.ts"
    assert not ts.is_file() or "[A-Z][A-Z0-9_]{1,60}" in ts.read_text()
    assert 'history.replaceState(null, "", `#settings/${id}`)' in js and "history.pushState" not in js


def test_a_setting_shows_only_while_its_switch_is_on():
    js = _js()
    on = js[js.index("function isOn(key) {"):js.index("function showError(msg)")]
    # true or on; for other values, set and not off (REMOTE_MODE: tailscale or domain); a secret: set
    assert "return v !== \"\" && !OFF_VALUES.includes(v);" in on and "if (!plain(k)) return Boolean(k.set);" in on
    assert "return isOn(r.parent) && parentsOn(rowOf[r.parent], depth + 1);" in on   # the whole chain of switches
    view = js[js.index("function applyView() {"):js.index("function helperBox()")]
    # hidden unless opened by an address, or itself a switch that is on (Bypass allowed while the Code page is off)
    assert 'd.hidden = off && !selfOn && !d.classList.contains("set-forced");' in view
    assert "const selfOn = off && switchedOn(keys[d.dataset.key]);" in view
    assert '["bool", "on_off", "true_blank"].includes(k.validator) && ON_VALUES.includes(lower(k.value))' in js
    assert "d.hidden = !(hit || inner);" in view                                  # a search shows it anyway
    assert "Applies while" in js


def test_switches_keep_the_rules_of_the_chips_they_replace():
    js = _js()
    t = js[js.index("function toggle(k, v, labelId) {"):js.index("// OpenRouter's model set")]
    assert 'role: "switch", "aria-checked": String(cur === on)' in t and '"aria-labelledby": labelId' in t
    # off for on-only keys, and for the less protective direction of a widen-local key on a remote device
    assert 'b.disabled = !canChange() || (k.policy === "on-only" && other !== on) || localOnlyHere(k, other);' in t
    assert "confirmApply({ [k.key]: other }" in t   # a change asks for the password like every other


def test_the_page_stays_inside_the_csp():
    # no HTML parsed from strings, no style attribute (the CSP has no 'unsafe-inline'), no code built from strings
    # (the names below are only searched for: none of them may appear in the page code)
    for name in ("settings.js", "app.js", "tour.js"):
        js = _js(name)
        for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "style:", 'setAttribute("style"', "new Function"):
            assert sink not in js, (name, sink)
    js = _js()
    assert 'try { localStorage.setItem(SECTION_MEMO, id); } catch (_)' in js   # the last section: best effort only


@need_repo
def test_models_and_providers_a_card_for_each_key_and_sign_in():
    # Settings › Models & providers: each key's card is its own row (its policy, form and remote rule kept), named for
    # its provider, with its state, how many models it adds and where you pick which — a place the layout knows
    st._layout_cache.clear()
    rows = {r["key"]: r for r in st.layout(REAL.parent)["rows"]}
    table = _table()
    js = _js()
    assert 'AWS_ACCESS_KEY_ID: "Bedrock", OPENROUTER_API_KEY: "OpenRouter", EXPLABS_API_KEY: "Experiential Labs"' in js
    provs = dict(re.findall(r'(\w+): \{ models: "[^"]+", pick: \["([^"]+)"', js[js.index("const PROVIDERS = {"):js.index("const GROUP_HEAD")]))
    # (and Search's: Claude Code's WebSearch, then a card for each backend — what it adds, not models: the next test)
    search = [k for k in rows if k.startswith("WEBSEARCH_")]
    assert sorted(provs) == sorted(k for k, r in rows.items() if r["section"] == "providers" and r["place"] == "main" and not r["parent"]
                                   and not k.startswith("+") and k not in search)
    for key, pick in provs.items():
        assert table[key][3] == "local", key          # keys stay on this computer: never changed from your devices
        assert pick in rows, (key, pick)
    card = js[js.index("function providerRow(k, r) {"):js.index("// --- the Code page")]
    assert "const rw = row(k, r);" in card
    assert '"Sends nothing until it has a key; then its models are in every picker."' in card
    assert "`Adds ${models.length} model${models.length === 1 ? \"\" : \"s\"}" in card and 'href: "#settings/CODE_MODELS"' in card
    # (its one action: Add key, else Replace key — the form removes it)
    assert 'text: PROVIDERS[k.key] ? (PROVIDERS[k.key].button || ["Replace key", "Add key"])[k.set ? 0 : 1]' in js
    # your subscriptions: a card each, in a grid; the pickers each answers in — the Code page's as types.ts has them
    subs = js[js.index("function subscriptionsRow(r) {"):js.index("function sessionDays()")]
    assert 'el("li", { class: "set-prov", "data-tool": t.id }' in subs and 'provState(st[0], tone)' in subs
    agents = json.loads(re.search(r"const SUBS_CODE_AGENTS = (\[[^\]]*\]);", js).group(1))
    ts = REPO / "code" / "web" / "src" / "types.ts"
    if ts.is_file():
        ids = re.search(r"export const HARNESS_IDS: readonly Harness\[\] = \[([^\]]*)\];", ts.read_text()).group(1)
        assert agents == [x.strip().strip("'") for x in ids.split(",") if x.strip().strip("'") != "bedrock"]
    # their old places say where they are now, with a link (MOVED: a section, the row it names, and where)
    moved = js[js.index("const MOVED = {"):js.index("let data = null;")]
    for sec, place in re.findall(r'(\w+): \[\["([^"]+)"', moved):
        assert sec in st.SECTIONS and rows[place]["section"] == "providers" and sec != "providers", (sec, place)
    assert {"aws", "chat", "code"} <= set(re.findall(r'(\w+): \[\["', moved))


@need_repo
def test_search_a_card_for_claude_codes_websearch_and_each_backend():
    # Settings › Models & providers › Search (lib/websearch.sh): Claude Code's WebSearch — the backend it searches with
    # now, its check and what to do — then a card for each backend, AWS's own first; each says what it adds (real
    # results for WebSearch) instead of a count of models, where the query goes and what it costs; all of them local
    st._layout_cache.clear()
    rows = {r["key"]: r for r in st.layout(REAL.parent)["rows"]}
    table = _table()
    js = _js()
    search = [k for k, r in rows.items() if k.startswith("WEBSEARCH_") and r["section"] == "providers"]
    assert search[0] == "WEBSEARCH_BACKEND" and search[1] == "WEBSEARCH_SEARXNG_BUILTIN"
    # (the built-in SearXNG's secret: with the other generated secrets, never a card)
    assert rows["WEBSEARCH_SEARXNG_SECRET"]["section"] == "advanced" and table["WEBSEARCH_SEARXNG_SECRET"][2:4] == ["S", "ro"]
    assert 'WEBSEARCH_BACKEND: "Search",' in js   # (its group's head)
    provs = js[js.index("const PROVIDERS = {"):js.index("const GROUP_HEAD")]
    for k in search:
        assert f"{k}: " in provs, k
        assert table[k][3] == "local", k   # what is searched with, and where the queries go: from this computer only
    for b, k in (("builtin", "WEBSEARCH_SEARXNG_BUILTIN"), ("agentcore", "WEBSEARCH_AGENTCORE_GATEWAY"), ("tavily", "WEBSEARCH_TAVILY_API_KEY"),
                 ("brave", "WEBSEARCH_BRAVE_API_KEY"), ("perplexity", "WEBSEARCH_PERPLEXITY_API_KEY"), ("searxng", "WEBSEARCH_SEARXNG_URL")):
        assert f'{k}: wsCard("{b}",' in provs, k
    card = js[js.index("function wsCard(b, where, cost, button) {"):js.index("function providerRow(k, r) {")]
    assert "webSearch().set_up.includes(b)" in card and '["Needs your AWS admin", "warn"]' in card
    # the built-in SearXNG: its switch (on by default: blank shows on), In use / On · not in use / Off
    assert table["WEBSEARCH_SEARXNG_BUILTIN"][4] == "on_off" and table["WEBSEARCH_SEARXNG_BUILTIN"][5] == "websearch"
    assert 'const DEFAULT_ON = new Set(["WEBSEARCH_SEARXNG_BUILTIN"]);' in js
    assert '["On · not in use", "off"] : ["Off", "off"]' in card
    # the WebSearch card says which one and why (lib/websearch.sh websearch_reason)
    assert "w.reason ? ` (${w.reason})`" in js[js.index("function wsChoiceAdds() {"):js.index("function wsChoiceOff()")]
    # each option's info: cost (a price only with its pricing page linked and the month it was checked), what is sent (the
    # query only), reliability and privacy, where its key comes from — every option has one, every link an https one
    info = js[js.index("const WS_INFO = {"):js.index("const extLink")]
    names = re.findall(r"^    (\w+): \{$", info, re.M)
    assert names == ["builtin", "agentcore", "tavily", "brave", "perplexity", "searxng"], names
    for b in names:
        block = info[info.index(f"    {b}: {{"):]
        block = block[:block.index("\n    },")]
        assert "cost:" in block and "sent:" in block and "steady:" in block and "get:" in block, b
        assert "never your conversation" in block or b == "builtin", b
        if "$" in block.split("sent:")[0]:   # a price: its page, and when it was checked
            assert "pricing: [" in block and "${WS_CHECKED}" in block, b
    assert 'const WS_CHECKED = "as of Oct 2026";' in js
    assert "Only the search query, never your conversation or files: from this computer to" in info
    for url in re.findall(r'"(https?://[^"]+)"', info):
        assert url.startswith("https://"), url
    assert set(re.findall(r'"https://([^/"]+)', info)) == {"docs.searxng.org", "aws.amazon.com", "www.tavily.com", "app.tavily.com", "brave.com",
                                                          "api-dashboard.search.brave.com", "docs.perplexity.ai", "console.perplexity.ai"}
    assert "${REPO}README.md#web-search-for-claude-code" in info
    # the info button: a real button that says what it opens, keyboard (Escape) and screen readers (aria-expanded,
    # aria-controls, a labelled region), opened by a click or a tap — never on hover alone; external links in a new tab
    widget = js[js.index("function wsInfo(b) {"):js.index("const provState")]
    for want in ('el("button", { type: "button", class: "set-info-btn", "aria-expanded": "false", "aria-controls": id,',
                 '"aria-label": `About ${name}: cost, what is sent, privacy`', 'role: "region"', 'hidden: true',
                 'btn.addEventListener("click", () => show(panel.hidden));', 'e.key === "Escape"', "btn.focus();"):
        assert want in widget, want
    assert "mouseover" not in widget and "mouseenter" not in widget
    assert 'const extLink = ([text, href]) => el("a", { href, target: "_blank", rel: "noopener noreferrer", text });' in js
    prow = js[js.index("function providerRow(k, r) {"):js.index("// --- the Code page")]
    assert "const info = p.backend ? wsInfo(p.backend) : null;" in prow
    css = _js("settings.css")
    assert ".set-info-btn:focus-visible" in css and ".set-ws-info[hidden] { display: none; }" in css
    assert re.search(r"@media \(pointer: coarse\) \{[^}]*\}[^@]*\.set-info-btn::after \{ content: \"\"; position: absolute; inset: -10px; \}", css)
    # the commands for your AWS admin as code, each with its Copy button
    lines = js[js.index("function wsLines(lines) {"):js.index("function wsChoiceState")]
    assert 'el("code", { text: line })' in lines and "copyButton(line" in lines
    # its forms: a choice of the backend, a key's (with Remove), the gateway's URL, SearXNG's URL (not the webhook's words)
    form = js[js.index("function openForm(r, k) {"):js.index("function genPassword()")]
    assert 'k.validator === "ws_backend"' in form and 'k.validator === "ws_gateway"' in form and '|| k.validator === "ws_key"' in form
    assert 'sx ? "Remove the URL" : "Remove the webhook"' in form


def test_details_in_the_pages_words_and_a_footer_for_the_terminal():
    # UX-13: a setting's Details says it in plain words (the catalog's notes), then "For the terminal": its .env name and
    # the command — the key names only there; badges name what restarts in the page's words
    js = _js("settings.js")
    frame = js[js.index("function frame(k, r, opts = {}) {"):js.index("// finish ROW")]
    assert "forTerminal([k.key, ...(withOf[k.key] || [])])" in frame and "term.append(cliLine(k))" in frame
    helper = js[js.index("function forTerminal(names, ...more) {"):js.index("const PHONE = ")]
    assert '"For the terminal"' in helper and '"In .env: "' in helper and "set-envkey" in helper
    assert '"litellm-cfg": ["the model gateway"]' in js and "Restarts LiteLLM" not in js and "From .env as of" not in js
    # the visible sections' notes: no .env value words ("true =", "blank =") — those of Advanced and About may keep them
    layout = {c[0]: c[1] for c in (l.split("\t") for l in (REPO / "catalog" / "settings-layout.tsv").read_text(encoding="utf-8").splitlines())
              if len(c) >= 2 and not c[0].startswith(("#", "@"))}
    for line in (REPO / "catalog" / "settings.tsv").read_text(encoding="utf-8").splitlines():
        c = line.split("\t")
        if line.startswith("#") or len(c) < 9 or c[0] == "key" or layout.get(c[0]) in ("advanced", "about", None):
            continue
        assert not re.search(r"(^|[ (])(true|false|blank|Blank|on|off|1) = ", c[7]), (c[0], c[7][:80])
        assert not re.search(r"\.env\b(?!rc)", c[7]), (c[0], c[7][:80])   # (.envrc is a file Claude may touch)


def test_a_phones_section_is_a_short_list_of_cards():
    # UX-13: on a phone each row's words fold under its Details (the same disclosure); its name, value and control stay
    js = _js("settings.js")
    assert 'const PHONE = window.matchMedia("(max-width: 767.98px)");' in js
    assert "compact(c);" in js[js.index("function card(s) {"):js.index("// blocks CONTAINER ROWS")]
    rule = js[js.index("function compactRow(rw) {"):js.index("function compact(root) {")]
    assert 'if (n.matches(KEEP)) continue;' in rule and "foldInto(rw, fold" in rule
    keep = js.split("const KEEP = ", 1)[1].split("\n", 1)[0]
    for k in (".set-label", ".set-value", ".set-actions", ".set-form", ".set-remote"):
        assert k in keep, k
    assert 'PHONE.addEventListener("change", () => { if (data) render(); });' in js


def test_core_services_row_reads_versions_json_and_refuses_odd_values(tmp_path):
    (tmp_path / "versions.json").write_text(json.dumps({"version": 1, "written_at": 5, "checked": "2026-10-27", "services": [
        {"id": "litellm", "name": "LiteLLM", "running": "1.106.3", "pinned": "1.106.3", "newest": "1.106.5", "state": "behind",
         "notes": "https://github.com/BerriAI/litellm/releases/tag/v1.106.5"},
        {"id": "Bad Id", "name": "x"},
        {"id": "rustfs", "name": "<b>RustFS</b>", "running": "1.0.1 && rm", "pinned": "1.0.3", "newest": "1.0.4", "state": "weird", "notes": "javascript:alert(1)"}]}))
    v = st.versions(tmp_path)
    assert v["checked"] == "2026-10-27" and [s["id"] for s in v["services"]] == ["litellm", "rustfs"]
    assert v["services"][0]["state"] == "behind" and v["services"][0]["notes"].startswith("https://github.com/")
    bad = v["services"][1]
    assert bad["name"] == "rustfs" and bad["running"] == "" and bad["state"] == "current" and bad["notes"] == ""
    assert st.versions(tmp_path / "none") == {"written_at": None, "checked": "", "services": []}
