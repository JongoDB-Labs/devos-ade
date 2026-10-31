"""Every model of the catalog as Claude Code's model (lib/code_models.sh, litellm/code-models.tsv, catalog/code-models.tsv):
the portal's /.bn/models lists every enabled chat model (Claude first) with its provider, vendor, how it works with
Claude Code and whether Settings › Claude Code › Models lists it; LiteLLM's /model/info carries the same as bn_* keys
(the browser terminal's devos-claude reads them) and its hook lowers a request's max_tokens to a model's limit. Live:
a Code page session on another provider's model (the cheapest that "works") round-trips a Bash tool call and its spend
lands under that model; a Haiku session switches to it mid-session (no "Couldn't confirm model"); Llama 3.3 70B (chat
only) answers at all — Bedrock refuses Claude Code's 32,000 max_tokens without the hook. The page: the status bar's quick
actions (28 px+, styled tips with shortcuts) and the model picker in groups with badges; the terminal: devos-claude
--models and Claude Code's /model menu listing the catalog's models; Settings (with the update helper): Anthropic only,
then every model again."""

from __future__ import annotations

import json
import re
import secrets
import time

from playwright.sync_api import expect as see

from common import ENV, Skip, check, expect
from checks_api import lite
from checks_browser import _confirm, _need_helper, _settings_api, _wait_job, goto_setting, login, open_settings, shot
from checks_code import HAIKU, LOCKED_OK, Code, csp_clean, need_haiku, need_on, saved, ui_page
from checks_terminal import new_shell_window, term_text, terminal_frame, type_line, unlock_in, wait_text, wait_xterm


def _models(c) -> dict:
    r = c.api("GET", "/.bn/models")
    expect(r["status"] == 200, f"/.bn/models {r['status']} {r['text'][:200]}")
    return r["json"]


def _other(bn: dict) -> dict | None:
    """The cheapest listed model of another provider on Bedrock that works with Claude Code's tools."""
    ms = [m for m in bn["models"] if m["provider"] == "Bedrock" and m["vendor"] != "Anthropic" and m["compat"] == "works"
          and m["listed"] and m["input_per_mtok"] is not None]
    return min(ms, key=lambda m: (m["input_per_mtok"], m["id"])) if ms else None


def _tool_result(evs, tid):
    return next((e for e in evs if e["type"] == "tool_result" and e.get("id") == tid), None)


def _turn_allowing_bash(c, sid, m, text):
    """A prompt to session SID up to its result, Bash allowed once at each card (a read-only command like echo may run
    without one: Claude Code's own rule). -> (its events, how many cards)"""
    n = len(c.msgs())
    c.request({"type": "prompt", "session": sid, "text": text})
    asked, since = 0, n   # (then from the card answered last)
    while True:
        x = c.wait(lambda y: (y.get("type") == "permission" and y.get("session", sid) == sid)
                   or (y.get("type") == "event" and y.get("session") == sid and y["ev"]["type"] == "result"),
                   "a permission prompt or the result", 150, since=since)
        since = None
        if x.get("type") != "permission":
            return c.events(sid, n), asked
        expect(x["tool"] == "Bash", f"{m['id']} asked for {x['tool']}, not Bash: {json.dumps(x)[:300]}")
        c.request({"type": "permission", "id": x["id"], "session": sid, "decision": "once"})
        asked += 1
        expect(asked <= 3, "more than three permission prompts for one echo")


@check("browser", "code-models-catalog")
def catalog(ctx):
    """/.bn/models and LiteLLM's /model/info: every enabled chat model, Claude first, with compatibility and listing."""
    need_on()
    c = Code(ctx, "code-models-catalog")
    bn = _models(c)
    ms = bn["models"]
    ids = [m["id"] for m in ms]
    expect(ms and ms[0]["id"].startswith("claude-"), f"Claude first: {ids[:4]}")
    claude_end = max(i for i, m in enumerate(ms) if m["vendor"] == "Anthropic" and m["provider"] == "Bedrock")
    expect(all(m["vendor"] == "Anthropic" for m in ms[:claude_end + 1]), f"Claude models together first: {ids}")
    for m in ms:
        expect(m["provider"] in ("Bedrock", "OpenRouter") and m["compat"] in ("works", "chat-only", "fails", "untested"), f"model {m}")
        expect(isinstance(m["listed"], bool) and isinstance(m["free"], bool), f"model {m}")
        if m["free"]:
            expect(m["input_per_mtok"] == 0 and m["output_per_mtok"] == 0, f"a free model is $0: {m}")
    expect(bn["default"] in ids and bn["scope"]["mode"] in ("all", "anthropic", "list"), f"default {bn['default']}, scope {bn['scope']}")
    # the same through LiteLLM (what the browser terminal's devos-claude reads)
    r = lite("GET", "/model/info", key=ENV["LITELLM_MASTER_KEY"])
    expect(r.status == 200, f"/model/info {r.status}")
    info = {d["model_name"]: d["model_info"] for d in r.json()["data"]}
    for m in ms:
        i = info.get(m["id"]) or {}
        expect(i.get("bn_id", m["id"]) == m["id"] and i.get("bn_name") == m["name"] and i.get("bn_compat") == m["compat"] and i.get("bn_code") is m["listed"],
               f"{m['id']}: /model/info says {({k: v for k, v in i.items() if k.startswith('bn_')})}")
    expect(info.get(bn["default"], {}).get("bn_default") is True, f"bn_default not on {bn['default']}")
    other = [m["id"] for m in ms if m["vendor"] != "Anthropic"]
    c.rec.save()
    return (f"{len(ms)} models ({sum(m['listed'] for m in ms)} listed, scope {bn['scope']['mode']}), default {bn['default']}; "
            f"other providers: {', '.join(f'{m}' for m in other) or 'none enabled for this key'}; "
            f"compat {dict((s, sum(m['compat'] == s for m in ms)) for s in ('works', 'chat-only', 'fails', 'untested'))}; /model/info agrees")


@check("browser", "code-session-other-provider")
def other_provider(ctx):
    """A session on another provider's model (the cheapest that works): a Bash tool call round-trips through LiteLLM's
    translation, the spend lands under that model; a Haiku session switches to it and back."""
    need_haiku()
    c = Code(ctx, "code-other-provider")
    bn = _models(c)
    m = _other(bn)
    if not m:
        raise Skip("no model of another provider that works is enabled for this key")
    sid = c.new_session(m["id"], "default")
    # This run's nonce in the command: in the tool call, it shows the prompt's own text reached the model (through
    # LiteLLM's translation). $RANDOM: a number only the shell knows — in the answer, it shows the tool's result did.
    nonce = secrets.token_hex(4)
    evs, asked = _turn_allowing_bash(c, sid, m, f"Use the Bash tool to run exactly this command: echo bn-e2e-{nonce}-$RANDOM — then reply with its output only.")
    use = [e for e in evs if e["type"] == "tool_use" and e["name"] == "Bash"]
    res = _tool_result(evs, use[0]["id"]) if use else None
    text = "".join(e["text"] for e in evs if e["type"] == "text")
    expect(use, f"{m['id']} called no Bash tool: {[e['type'] for e in evs][:30]}")
    expect(f"bn-e2e-{nonce}-" in json.dumps(use[0].get("input")), f"the prompt's nonce {nonce} is not in the call: {json.dumps(use[0].get('input'))[:200]}")
    out = re.search(rf"bn-e2e-{nonce}-[0-9]+", res["text"]) if res and not res["is_error"] else None
    expect(out, f"tool result {res}")
    out = out.group(0)
    nudged = None
    if out not in text:
        # A model may end the turn after the result with no answer, or ask what to do: variance, as long as the result
        # is in its context — asked once more, it must answer from it (a number of a new run of the command counts)
        nudged = text.strip()[:60] or "no text"
        evs2, more = _turn_allowing_bash(c, sid, m, "What did the command print? Reply with its output only.")
        asked += more
        outs = {out} | {x.group(0) for e in evs2 if e["type"] == "tool_result" for x in re.finditer(rf"bn-e2e-{nonce}-[0-9]+", e.get("text") or "")}
        text2 = "".join(e["text"] for e in evs2 if e["type"] == "text")
        expect(any(o in text2 for o in outs), f"answer {text[:200]!r}, asked again {text2[:200]!r}; the command printed {out}")
        evs += evs2
    init = next((e for e in evs if e["type"] == "init"), None)
    expect(init is None or init["model"] == m["id"], f"init model {init and init['model']}")
    # its spend, from LiteLLM's logs, under that model (logged as the provider's model: bedrock/us.openai.gpt-6-luna)
    t0, rows = time.time(), []
    mine = lambda r: m["id"].removeprefix("or/") in r["model"]   # noqa: E731
    while time.time() - t0 < 60:
        rows = (c.api("GET", f"/.bn/spend?session={sid}")["json"] or {}).get("rows") or []
        if any(mine(r) for r in rows):
            break
        c.page.wait_for_timeout(2000)
    spent = sum(r["spend"] for r in rows if mine(r))
    cached = sum(r["cache_read_tokens"] for r in rows if mine(r))
    expect(rows and spent > 0, f"no spend under {m['id']}: {rows[:3]}")
    # a Haiku session switches to it (by its full id; the picker's flag settings spare Claude Code its 5 s check) and back
    # (a Haiku session of its own, in Default: the shared one can be left in another mode by an earlier check — on
    # v0314a it was in Plan, and the model wrote a plan instead of answering)
    sid2 = c.new_session(HAIKU, "default")
    c.request({"type": "attach", "session": sid2, "since": 10 ** 9})
    c.request({"type": "set_model", "session": sid2, "model": m["id"]}, timeout=90)
    evs2 = c.turn(sid2, "Reply with exactly the word: ok")
    models = sorted({e.get("model") for e in evs2 if e["type"] == "text"})
    expect(models == [m["id"]], f"after set_model {m['id']}: text from {models}")
    c.request({"type": "set_model", "session": sid2, "model": HAIKU}, timeout=90)
    c.rec.save()
    said = f"answer {text.strip()[:40]!r}" if not nudged else f"answer without it ({nudged!r}), asked again: {text2.strip()[:40]!r}"
    return (f"{m['name']} ({m['id']}, {m['vendor']}): the prompt's nonce in its Bash call ({asked} card(s)) → {out!r}, {said}; "
            f"spend ${spent:.5f} under it ({cached} prompt-cache tokens read); a Haiku session switched to it (text from {models}) and back")


@check("browser", "code-session-llama-capped")
def llama_capped(ctx):
    """Llama 3.3 70B: Bedrock refuses more than 8,192 output tokens and Claude Code asks for 32,000 — LiteLLM's hook
    (lib/litellm-hooks/bn_hooks.py) lowers it, so the session answers. (Its tool calls, which Bedrock hands back as
    text, are the hook's too: tests/e2e/harness-parity.sh runs them.)"""
    need_haiku()
    c = Code(ctx, "code-llama")
    bn = _models(c)
    m = next((x for x in bn["models"] if x["id"] == "llama-3-3-70b"), None)
    if not m:
        raise Skip("Llama 3.3 70B is not enabled for this key")
    expect(m["compat"] == "works" and m["max_output_tokens"] == 8192, f"llama: {m}")
    sid = c.new_session(m["id"], "default")
    n = len(c.msgs())
    c.request({"type": "prompt", "session": sid, "text": "Reply with exactly the word: pong"})
    # The hook's one job here: lower Claude Code's 32,000 max_tokens ask under Bedrock's 8,192 cap for this model, so the
    # request is accepted instead of refused ("maximum tokens"). That is proved the moment the model answers at all —
    # assistant text or a tool call — with no such refusal. We do NOT wait for the whole turn to finish: a weak model
    # can wander into a tool call that errors and loop (JON-805), with no result in the window though max_tokens was
    # never the problem. If max_tokens were not capped the request is refused, which surfaces as "maximum tokens" in the
    # events (and the model still emits an event, so the wait returns).
    c.wait(lambda msg: msg.get("type") == "event" and msg.get("session") == sid
           and msg.get("ev", {}).get("type") in ("text", "tool_use", "result"), "Llama to start answering", 120, since=n)
    evs = c.events(sid, n)
    blob = json.dumps(evs)
    expect("maximum tokens" not in blob, f"llama: refused for max_tokens — the hook did not cap it: {blob[:400]}")
    text = "".join(e.get("text", "") for e in evs if e["type"] == "text")
    c.api("DELETE", f"/api/sessions/{sid}")   # it may still be looping (JON-805); stop it so it does not 409 later checks
    c.rec.save()
    how = f"answered {text.strip()[:40]!r}" if text.strip() else ("made a tool call" if any(e["type"] == "tool_use" for e in evs) else "started")
    return f"Llama 3.3 70B {how}: LiteLLM's hook capped max_tokens at 8,192 (no 'maximum tokens' refusal; JON-805 tracks the weak-model tool loop)"


@check("browser", "code-ui-models-and-status-bar")
@saved
def ui_models(ctx):
    """The page: the status bar's quick actions (28 px+, a styled tip with the shortcut), the model picker in groups
    with compatibility badges, its search; no Bedrock call."""
    need_on()
    page, rec = ui_page(ctx, "code-ui-models")
    for t in ("sb-terminal", "run-status", "ports-status", "sb-model"):
        el = page.get_by_test_id(t)
        see(el).to_be_visible(timeout=20000)
        box = el.bounding_box()
        expect(box["height"] >= 28 and el.get_attribute("aria-label"), f"{t}: {box}, aria-label {el.get_attribute('aria-label')!r}")
    page.get_by_test_id("run-status").hover()
    see(page.get_by_test_id("tip-run")).to_contain_text("Alt+R", timeout=5000)
    shot(page, "70-code-status-bar-tip")
    page.mouse.move(10, 200)
    page.get_by_test_id("model-picker").click()
    panel = page.locator(".model-panel")
    see(panel).to_be_visible()
    see(page.get_by_test_id("model-group-anthropic")).to_be_visible()
    groups = page.locator(".model-panel .mp-group").evaluate_all("els => els.map((e) => e.dataset.testid)")
    llama = page.get_by_test_id("model-llama-3-3-70b")
    if llama.count():
        see(llama.get_by_test_id("compat-works")).to_have_text("works")
    shot(page, "71-code-model-picker")
    page.get_by_test_id("model-search").fill("haiku")
    see(page.locator(".model-panel .mp-row")).to_have_count(1)
    page.keyboard.press("Escape")
    csp_clean(page, rec)
    return f"status bar actions 28 px+ with tips (Run: Alt+R); picker groups {groups}"


@check("browser", "terminal-devos-claude-models")
def terminal_models(ctx):
    """The browser terminal: devos-claude --models from LiteLLM's /model/info, and Claude Code's /model menu listing the
    catalog's models by name, price and how they work (no model call)."""
    need_on()
    page, rec = ctx.page("terminal-models")
    login(page)
    page.click(".tab[data-tab=terminal]")
    f = terminal_frame(page)
    unlock_in(f, ENV["PORTAL_PASSWORD"])
    f = terminal_frame(page)
    wait_xterm(f)
    new_shell_window(page, f)
    type_line(page, f, "clear; devos-claude --models")
    out = wait_text(f, r"WITH CLAUDE CODE", 30)
    out = wait_text(f, r"devos-claude --model <id or name>", 10)
    expect(re.search(r"^\* claude-", out, re.M) or re.search(r"^\* \S+", out, re.M), f"no default marked: {out[-600:]!r}")
    shot(page, "72-terminal-devos-claude-models")
    listed = [ln.split()[0] for ln in out.splitlines() if re.match(r"^[ *] [a-z]", ln)]
    # Claude Code's /model menu: our rows (replaceBuiltInOptions), no aliases
    type_line(page, f, "clear; devos-claude")
    t0, steps = time.time(), []
    while time.time() - t0 < 90:
        s = term_text(f)
        if "Choose the text style" in s or "Press Enter to continue" in s:
            page.keyboard.press("Enter"); steps.append("onboarding")
        elif "Yes, I trust this folder" in s:
            page.keyboard.press("ArrowDown"); page.keyboard.press("Enter"); steps.append("trust")
        elif re.search(r"^\s*❯\s*$", s, re.M) or "for shortcuts" in s:
            break
        page.wait_for_timeout(700)
    page.keyboard.type("/model", delay=30)
    page.wait_for_timeout(400)
    page.keyboard.press("Enter")
    menu = wait_text(f, r"Select model", 20)
    expect("Default" in menu, f"no Default row: {menu[-800:]!r}")
    expect(not re.search(r"^\s*\d+\.\s+(Opus|Sonnet|Haiku)\s", menu, re.M), f"Claude Code's own alias rows are shown: {menu[-800:]!r}")
    expect(re.search(r"Claude \w+ \d", menu) and "per 1M" in menu, f"no catalog rows with prices: {menu[-800:]!r}")
    shot(page, "73-terminal-model-menu")
    page.keyboard.press("Escape")
    page.wait_for_timeout(300)
    page.keyboard.type("/exit", delay=30)
    page.keyboard.press("Enter")
    rec.save()
    rows = [ln.strip() for ln in menu.splitlines() if re.match(r"^\s*❯?\s*\d+\.", ln)]
    return f"--models listed {len(listed)} ({', '.join(listed[:5])}…); /model menu rows: {rows[:6]}; first start: {steps or 'no questions'}"


@check("settings", "settings-code-models")
def settings_code_models(ctx):
    """Settings › Claude Code › Models: Anthropic only through the update helper — /.bn/models and LiteLLM's bn_code
    follow — then every model again."""
    need_on()
    _need_helper(ctx)
    page, rec = ctx.page("settings-code-models")
    login(page)
    open_settings(page)
    notes = []
    for val, label in (("anthropic", "Anthropic only"), ("", "All enabled")):
        row = goto_setting(page, "CODE_MODELS")
        btn = row.locator(".set-seg button", has_text=label)
        if btn.get_attribute("aria-pressed") == "true":
            notes.append(f"{label}: already")
            continue
        t0 = time.time()
        btn.click()
        _confirm(page)
        ok, msg = _wait_job(page, 300)
        expect(ok, f"CODE_MODELS={val or 'all'}: {msg}")
        if val == "anthropic":
            row = goto_setting(page, "CODE_MODELS")
            row.scroll_into_view_if_needed()
            shot(page, "74-settings-code-models-anthropic", mask=[".set-value", ".set-adv-value"])
        info = {}
        t1 = time.time()
        while time.time() - t1 < 90:
            r = lite("GET", "/model/info", key=ENV["LITELLM_MASTER_KEY"], timeout=10)
            if r.status == 200:
                info = {d["model_name"]: d["model_info"] for d in r.json()["data"]}
                others = [k for k, v in info.items() if v.get("bn_vendor") and v.get("bn_vendor") != "Anthropic"]
                if not others or all(info[k].get("bn_code") is (val != "anthropic") for k in others):
                    break
            page.wait_for_timeout(2000)
        others = [k for k, v in info.items() if v.get("bn_vendor") and v.get("bn_vendor") != "Anthropic"]
        expect(all(info[k].get("bn_code") is (val != "anthropic") for k in others), f"bn_code after {val or 'all'}: {[(k, info[k].get('bn_code')) for k in others]}")
        notes.append(f"{label} in {time.time() - t0:.0f} s ({len(others)} other models now {'hidden' if val else 'listed'})")
    rec.save()
    return "; ".join(notes)


# ---------------------------------------------------------------- Browse models (JON-520: portal/portal/static/models.js)

def _browse(ctx) -> dict:
    """GET /api/models/browse (the model browser's lists), as the page reads it."""
    from common import http
    r = http("GET", None, "/api/models/browse", {"X-Requested-With": "devos-ade"}, cookie=ctx.session())
    expect(r.status == 200, f"/api/models/browse {r.status} {r.body[:200]}")
    return json.loads(r.body)


@check("browser", "model-browser")
def model_browser(ctx):
    """Browse models (Settings › Models & providers › Browse models): the lists of Bedrock, OpenRouter and Experiential
    Labs read on the computer (never a key in the page), search and the filters, the links from Settings and the Code
    picker. Screenshots light and dark at 390, 820 and 1440 px. No model call."""
    from common import origin
    page, rec = ctx.page("model-browser")
    login(page)
    # the API: Bedrock's list is read on the computer by the update helper (once by itself on a new stack, or when the
    # page asks: settings/model-browser-add checks that read); the page holds no key. In this pass the helper is not
    # running, so a list not read yet shows the catalog's models and says it is read once the helper runs, never
    # "reading it…"
    d = _browse(ctx)
    expect("bedrock" in d["providers"], f"no Bedrock provider: {list(d['providers'])}")
    br = d["providers"]["bedrock"]
    expect(br["on"] and br["rows"], f"Bedrock off or empty: on={br['on']}, {len(br['rows'])} rows")
    expect(not br.get("error"), f"Bedrock's list: {br.get('error')}")
    read, helper_on = bool(br.get("at")), _settings_api(ctx)["helper"]["running"]
    if not read:
        expect(all(r.get("builtin") for r in br["rows"]), "a list not read yet showed models beyond the catalog")
        expect(br.get("reading") is helper_on, f"reading={br.get('reading')!r} with the update helper running={helper_on}")
    claude = [r for r in br["rows"] if r["vendor"] == "Anthropic" or (not read and "claude" in r["name"].lower())]
    expect(claude, "no Anthropic models listed for Bedrock")
    # the page: rows, search narrows, a filter works
    page.goto(origin() + "/#modelbrowser")
    page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=30000)
    if not read:
        say = page.inner_text('#modelbrowser .mb-source[data-provider="bedrock"]')
        want = "reading it on this computer" if helper_on else "read on this computer once the update helper runs"
        expect(want in say, f"Bedrock's list not read yet; the page says {say[:300]!r}")
    rows0 = page.locator("#modelbrowser .mb-row").count()
    expect(rows0 >= len(claude), f"page shows {rows0} rows, API had ≥{len(claude)} Claude")
    # a built-in Claude model says it is in the pickers, not add/removable
    built = page.locator(".mb-row", has=page.locator(".mb-state", has_text=re.compile("picker|Built in"))).first
    see(built).to_be_visible(timeout=10000)
    # screenshots: light and dark at three widths
    names = []
    for w in (390, 820, 1440):
        page.set_viewport_size({"width": w, "height": 900})
        for theme in ("light", "dark"):
            page.emulate_media(color_scheme=theme)
            page.wait_for_timeout(200)
            nm = f"model-browser-{w}-{theme}"
            shot(page, nm, mask_locators=[page.locator(".mb-id")])
            names.append(nm)
    page.emulate_media(color_scheme="light")
    page.set_viewport_size({"width": 1280, "height": 900})
    # search by name narrows the list; clearing restores it
    page.fill("#mb-search", "zzxxqq-nothing")
    page.wait_for_timeout(300)
    expect(page.locator("#modelbrowser .mb-row").count() == 0, "search for nonsense still showed rows")
    page.fill("#mb-search", "claude")
    page.wait_for_timeout(300)
    nclaude = page.locator("#modelbrowser .mb-row").count()
    expect(0 < nclaude <= rows0, f"search 'claude' showed {nclaude} of {rows0}")
    shot(page, "model-browser-search")
    page.fill("#mb-search", "")
    # the "works with Claude Code" filter keeps only models marked works
    wf = page.locator('#modelbrowser [data-filter="works"]')
    if wf.count():
        wf.click()
        page.wait_for_timeout(300)
        bad = page.locator("#modelbrowser .mb-row .mb-compat:not(.mb-compat-works)").count()
        expect(bad == 0, f"the works filter left {bad} non-works rows")
        wf.click()
    # the provider segment narrows to Bedrock
    page.locator('#modelbrowser [data-prov="bedrock"]').click()
    page.wait_for_timeout(200)
    provs = page.locator("#modelbrowser .mb-row .mb-prov").evaluate_all("els => [...new Set(els.map(e => e.textContent))]")
    expect(provs == ["Bedrock"], f"provider filter showed {provs}")
    # the Settings card links here, and the Code picker's "More models…" is wired to it (settings.js / Pickers.tsx)
    page.goto(origin() + "/#settings/providers")
    page.wait_for_selector("#settings:not([hidden])", timeout=20000)
    page.wait_for_timeout(400)
    link = page.locator('#settings a[href="#modelbrowser/bedrock"]').first
    expect(link.count() > 0, "no Browse models link on the Bedrock card")
    rec.save()
    return (f"Bedrock lists {len(br['rows'])} ({len(claude)} Anthropic); OpenRouter on={d['providers']['openrouter']['on']}, "
            f"Experiential on={d['providers']['explabs']['on']}; search/filters work; shots {len(names)}+2")


@check("settings", "model-browser-add")
def model_browser_add(ctx):
    """Add a model from the browser, then remove it — the change goes through ./stack config apply (the update helper),
    and the model then shows enabled in the pickers' source (/api/models/browse reads litellm/code-models.tsv). A Bedrock
    model the key can use but the catalog does not carry (no model call); skipped if the list offers none to add."""
    from common import http, origin
    _need_helper(ctx)
    # the helper reads Bedrock's list by itself (a new stack's first read, or the page asked): its models beyond the
    # catalog arrive, Anthropic's named as such
    t0 = time.time()
    while True:
        d = _browse(ctx)
        br = d["providers"]["bedrock"]
        if br.get("at") or br.get("error") or time.time() - t0 > 180:
            break
        time.sleep(3)
    expect(br.get("at") and not br.get("error"), f"the update helper did not read Bedrock's list in {time.time() - t0:.0f} s: {br.get('error') or 'not read yet'}")
    expect(any(r["vendor"] == "Anthropic" for r in br["rows"]), "no Anthropic models in Bedrock's list as read")
    if not d["can_change"]:
        raise Skip(f"changes not available: {d['why_not']}")
    add = next((r for r in d["providers"]["bedrock"]["rows"] if r["can"] == "add"), None)
    if add is None:
        raise Skip("the Bedrock list offers no model to add beyond the catalog (all built in, or the key may not list)")
    mid = add["id"]
    page, rec = ctx.page("model-browser-add")
    login(page)
    page.goto(origin() + "/#modelbrowser")
    page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=30000)
    row = page.locator(f'#modelbrowser .mb-row[data-id="{mid}"]')
    row.scroll_into_view_if_needed()
    row.locator('button[data-act="add"]').click()
    page.wait_for_selector("#mb-confirm[open]", timeout=10000)
    page.fill("#mb-confirm-password", ENV["PORTAL_PASSWORD"])
    page.click("#mb-confirm-ok")
    # the helper applies it and only LiteLLM restarts; the page polls /api/admin/status and reloads the lists
    ok = False
    for _ in range(120):
        page.wait_for_timeout(2000)
        b = _browse(ctx)
        r = next((x for x in b["providers"]["bedrock"]["rows"] if x["id"] == mid), None)
        if r and (r["enabled"] or r["chosen"]) and r["can"] == "remove":
            ok = True
            break
        if page.locator("#mb-job.bad").count():
            raise AssertionError(f"the helper refused: {page.inner_text('#mb-job')[:200]}")
    expect(ok, f"{mid} did not become enabled/removable within ~4 min")
    # it is in BEDROCK_MODELS now
    s = json.loads(http("GET", None, "/api/settings", {"X-Requested-With": "devos-ade"}, cookie=ctx.session()).body)
    bm = next((k.get("value", "") for k in s["snapshot"]["keys"] if k["key"] == "BEDROCK_MODELS"), "")
    expect(mid in bm, f"BEDROCK_MODELS is {bm!r}, not holding {mid}")
    shot(page, "model-browser-added")
    # remove it again
    row = page.locator(f'#modelbrowser .mb-row[data-id="{mid}"]')
    row.scroll_into_view_if_needed()
    row.locator('button[data-act="remove"]').click()
    page.wait_for_selector("#mb-confirm[open]", timeout=10000)
    page.fill("#mb-confirm-password", ENV["PORTAL_PASSWORD"])
    page.click("#mb-confirm-ok")
    gone = False
    for _ in range(120):
        page.wait_for_timeout(2000)
        b = _browse(ctx)
        r = next((x for x in b["providers"]["bedrock"]["rows"] if x["id"] == mid), None)
        if r and r["can"] == "add" and not r["chosen"]:
            gone = True
            break
    expect(gone, f"{mid} was not removed within ~4 min")
    rec.save()
    return f"added {mid} (→ BEDROCK_MODELS, enabled in the pickers), then removed it; only LiteLLM restarted"


# --- JON-823: the page against each provider's own list, read in the same run ---

KNOWN_BEDROCK_REGIONS = ("us-east-1", "us-east-2", "us-west-2", "ca-central-1", "sa-east-1", "eu-central-1", "eu-west-1",
                         "eu-west-2", "eu-west-3", "ap-northeast-1", "ap-south-1", "ap-southeast-1", "ap-southeast-2")
OR_ID = re.compile(r"[A-Za-z0-9~][A-Za-z0-9._:~-]*/[A-Za-z0-9._/:~-]+")      # portal/portal/model_browser.py OR_ID
XL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
XL_API = "https://api.experientiallabs.ai"
PAGE_ROWS = 60                                                                  # models.js PAGE: rows drawn at a time


def _browse_q(ctx, q: str) -> tuple[int, dict]:
    from common import http
    r = http("GET", None, f"/api/models/browse?{q}", {"X-Requested-With": "devos-ade"}, cookie=ctx.session())
    try:
        return r.status, json.loads(r.body)
    except ValueError:
        return r.status, {}


def _fresh(ctx, wait_s: int = 480) -> dict:
    """Read again (?refresh=1, as the page's button): the update helper reads every list again and the portal OpenRouter's
    (its public list too, without a key). -> the browse answer once each list with a key was read in the last 5 minutes."""
    t0 = time.time()
    asked = 0.0
    while True:
        if time.time() - asked > 130:      # (the portal takes a Read again every 2 minutes, the helper every minute)
            _browse_q(ctx, "refresh=1&openrouter=public")
            asked = time.time()
        st, d = _browse_q(ctx, "openrouter=public")
        expect(st == 200, f"/api/models/browse {st}")
        stale = [k for k, p in d["providers"].items() if (p["on"] or k == "openrouter") and (not p.get("at") or p["at"] < t0 - 300)]
        if not stale:
            return d
        expect(time.time() - t0 < wait_s, f"Read again: not read again in {wait_s} s: {stale}")
        time.sleep(5)


def _url_json(url: str, headers: dict | None = None, timeout: float = 40.0) -> tuple[int, dict]:
    import urllib.error
    import urllib.request
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/json", **(headers or {})}), timeout=timeout) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, {}


def _model_of(r: dict) -> str:
    """The foundation model a Bedrock row is (its model_id; a row of the catalog's, before a list was read, has none)."""
    return r.get("model_id") or r["source_id"]


def _left_out(m: dict) -> str | None:
    """Why lib/model_browser_bedrock.py leaves a model of ListFoundationModels out (its documented reasons), or None."""
    mid = m.get("modelId") or ""
    outs = [x.lower() for x in m.get("outputModalities") or []]
    ins = [x.lower() for x in m.get("inputModalities") or []]
    if outs != ["text"] or "text" not in ins:
        return "not-text"
    if re.search(r"embed|rerank", mid):
        return "embeddings"
    if mid.count(":") > 1:
        return "variant"
    kinds = m.get("inferenceTypesSupported") or []
    if "ON_DEMAND" not in kinds and "INFERENCE_PROFILE" not in kinds:
        return "provisioned"
    return None


def _profiles(region: str) -> tuple[int, str, set, dict]:
    """ListInferenceProfiles (system-defined) in REGION: (status, error code, ACTIVE profile ids, model id -> profiles)."""
    import sigv4
    ids, serves, token = set(), {}, None
    for _ in range(10):
        st, a = sigv4.bedrock(region, "/inference-profiles", {"typeEquals": "SYSTEM_DEFINED", "maxResults": 1000, **({"nextToken": token} if token else {})}, ENV)
        if st != 200:
            return st, sigv4.error_code(a), ids, serves
        for p in a.get("inferenceProfileSummaries") or []:
            if p.get("status") != "ACTIVE":
                continue
            ids.add(p.get("inferenceProfileId"))
            for m in p.get("models") or []:
                arn = m.get("modelArn") or ""
                if "foundation-model/" in arn:
                    serves.setdefault(arn.rsplit("/", 1)[1], set()).add(p.get("inferenceProfileId"))
        token = a.get("nextToken")
        if not token:
            break
    return 200, "", ids, serves


def _bedrock_complete(br: dict) -> tuple[list[str], str]:
    """Every text model Bedrock offers this key, in the stack's region and in every other region read, against the page:
    each listed, or left out for a documented reason. -> (what is wrong, what was compared)"""
    import sigv4
    home, bad = br["region"], []
    st, a = sigv4.bedrock(home, "/foundation-models", {"byOutputModality": "TEXT"}, ENV)
    expect(st == 200, f"ListFoundationModels in {home}: HTTP {st} {sigv4.error_code(a)}")
    pst, _, _, serves = _profiles(home)
    rows = br["rows"]
    here = {_model_of(r) for r in rows if r.get("kind") != "app-profile" and r.get("region") in (home, "", None)}
    anywhere = {_model_of(r) for r in rows if r.get("kind") != "app-profile"}
    counts: dict = {}
    due_here = set()    # (the models the stack's region should list: checked there, not again per other region)
    for m in a.get("modelSummaries") or []:
        mid = m.get("modelId") or ""
        why = _left_out(m)
        if why is None and "ON_DEMAND" not in (m.get("inferenceTypesSupported") or []) and pst == 200 and mid not in serves:
            why = "provisioned"   # (only through a profile, and no profile serves it)
        if why:
            counts[why] = counts.get(why, 0) + 1
            continue
        due_here.add(mid)
        if mid not in here:
            bad.append(f"{home}: {mid} is offered and not listed")
    raw_ids = {m.get("modelId") for m in a.get("modelSummaries") or []}
    bad += [f"{home}: {r['source_id']} is listed but Bedrock does not offer {_model_of(r)}" for r in rows
            if r.get("kind") != "app-profile" and r.get("region") in (home, "", None) and _model_of(r) not in raw_ids]
    if not (br.get("left_out") or {}).get("cap"):
        lo = {k: v for k, v in (br.get("left_out") or {}).items() if k != "cap"}
        if lo != counts:
            bad.append(f"{home}: the page says it left out {lo}, Bedrock's own list gives {counts}")
    # every other region the page read: the models it offers that the stack's region does not, each listed once
    regions = br.get("regions") or {}
    missing = [r for r in KNOWN_BEDROCK_REGIONS if r not in regions]
    if missing:
        bad.append(f"regions never read: {missing} (read: {sorted(regions)})")
    others = [r for r, s in regions.items() if s == "ok" and r != home]
    extra, unlisted = 0, {}     # (unlisted: model -> the regions that offer it; one message per model)
    for region in others:
        serves_r, profiles_ok = None, False
        st, a = sigv4.bedrock(region, "/foundation-models", {"byOutputModality": "TEXT"}, ENV)
        if st != 200:
            bad.append(f"{region}: the page read it, ListFoundationModels now answers HTTP {st} {sigv4.error_code(a)}")
            continue
        for m in a.get("modelSummaries") or []:
            mid = m.get("modelId") or ""
            if _left_out(m) or mid in due_here or mid in anywhere:
                continue
            if "ON_DEMAND" not in (m.get("inferenceTypesSupported") or []):
                if serves_r is None:
                    pst_r, _, _, serves_r = _profiles(region)
                    profiles_ok = pst_r == 200
                if profiles_ok and mid not in serves_r:
                    continue    # (no profile serves it there)
            unlisted.setdefault(mid, []).append(region)
        extra += sum(1 for r in rows if r.get("region") == region)
    bad += [f"{mid} is offered in {', '.join(rs)} (the stack's region does not) and not listed" for mid, rs in unlisted.items()]
    errs = [r for r, s in regions.items() if s == "error"]
    said = (f"Bedrock: {home} {len(here)} listed ({sum(counts.values())} left out: {counts}); {len(others)} other regions read"
            f"{f' ({len(errs)} not answering: {errs})' if errs else ''}, {extra} models only they offer")
    return bad, said


def _openrouter_complete(rows: list[dict], left_out: dict | None = None) -> tuple[list[str], str]:
    """OpenRouter's public list, read now, against the page: every model listed, or left out for a documented reason
    (an id the stack cannot use, a :batch variant, not text out, no price); the page's "Not listed" counts (LEFT_OUT)
    the same as the list gives."""
    st, raw = _url_json("https://openrouter.ai/api/v1/models")
    expect(st == 200, f"openrouter.ai/api/v1/models: HTTP {st}")
    page = {r["source_id"] for r in rows}
    bad, counts = [], {}

    def price(v):
        try:
            return float(v) >= 0 if isinstance(v, (int, float, str)) and str(v).strip() not in ("", "-1") else False
        except ValueError:
            return False
    for m in raw.get("data") or []:
        mid = m.get("id") or ""
        arch = m.get("architecture") or {}
        pr = m.get("pricing") or {}
        why = ("id" if not OR_ID.fullmatch(mid) or len(mid) > 124 else "batch" if mid.endswith(":batch")
               else "not-text" if (arch.get("output_modalities") or ["text"]) != ["text"]
               else "no-price" if not (price(pr.get("prompt")) and price(pr.get("completion"))) else None)
        if why:
            counts[why] = counts.get(why, 0) + 1
        elif mid not in page:
            bad.append(f"OpenRouter: {mid} is offered and not listed")
    if len(rows) >= 2000:
        bad = []   # (the page's limit: said on the page)
    elif left_out is not None and left_out != counts:
        bad.append(f"OpenRouter: the page says it left out {left_out}, OpenRouter's own list gives {counts}")
    return bad, f"OpenRouter: {len(page)} listed of {len(raw.get('data') or [])} ({counts} left out)"


def _explabs_complete(rows: list[dict]) -> tuple[list[str], str]:
    """The ids the Experiential Labs key may call (GET /v1/models with it, now) against the page: each listed, or left
    out because the gateway's catalog says it does not answer in text."""
    key = ENV.get("EXPLABS_API_KEY", "")
    st, raw = _url_json(f"{XL_API}/v1/models", {"Authorization": f"Bearer {key}"})
    if st in (401, 403):
        return [], "Experiential Labs: the key is a test key the real gateway does not take (not compared)"
    expect(st == 200, f"{XL_API}/v1/models: HTTP {st}")
    page = {r["source_id"] for r in rows}
    ids = [m.get("id") for m in raw.get("data") or [] if isinstance(m, dict)]
    bad, left = [], 0
    for i in ids:
        if not isinstance(i, str) or not XL_ID.fullmatch(i):
            left += 1
            continue
        if i in page:
            continue
        slug = i[: -len(":free")] if i.endswith(":free") else i
        cst, c = _url_json(f"{XL_API}/api/models/{slug}")
        outs = ((c.get("model") or c) if isinstance(c, dict) else {}).get("output_modalities") if cst == 200 else None
        if isinstance(outs, list) and outs and "text" not in outs:
            left += 1
            continue
        bad.append(f"Experiential Labs: {i} may be called with the key and is not listed")
    return bad, f"Experiential Labs: {len(page)} listed of the key's {len(ids)} ({left} left out: no text out)"


@check("settings", "model-browser-complete")
def model_browser_complete(ctx):
    """Browse models lists every model each key can use, as the provider's own list says, read in the same run: Bedrock
    (ListFoundationModels in the stack's region and in every other region the page read, signed with the stack's key),
    OpenRouter (its public list) and Experiential Labs (the key's /v1/models). A model missing from the page fails unless
    it is left out for a documented reason (lib/model_browser_bedrock.py: not text in and out, embeddings, a context
    variant, provisioned throughput only; OpenRouter: :batch, no price, not text out); the page's "Not listed" counts
    must match. Then the page: the Region filter, Not confirmed, the left-out sentence. Read-only, free calls; no model
    call."""
    from common import origin
    _need_helper(ctx)
    d = _fresh(ctx)
    bad, said = [], []
    br = d["providers"]["bedrock"]
    if br["on"] and ENV.get("AWS_ACCESS_KEY_ID") and ENV.get("AWS_SECRET_ACCESS_KEY"):
        expect(br.get("status") == "ok", f"Bedrock's list: {br.get('status')} {br.get('error')}")
        b, s = _bedrock_complete(br)
        bad += b; said.append(s)
    else:
        said.append("Bedrock: no AWS key in .env (an instance role): not compared")
    b, s = _openrouter_complete(d["providers"]["openrouter"]["rows"], d["providers"]["openrouter"].get("left_out"))
    bad += b; said.append(s)
    if d["providers"]["explabs"]["on"] and ENV.get("EXPLABS_API_KEY"):
        b, s = _explabs_complete(d["providers"]["explabs"]["rows"])
        bad += b; said.append(s)
    else:
        said.append("Experiential Labs: no key (not compared)")
    expect(not bad, f"{len(bad)} not as the providers list them: " + "; ".join(bad[:12]))
    # the page says the same: Bedrock's regions and what it left out, the Region filter, Not confirmed
    page, rec = ctx.page("model-browser-complete")
    login(page)
    page.goto(origin() + "/#modelbrowser")
    page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=30000)
    page.locator('#modelbrowser [data-prov="bedrock"]').click()
    src = page.inner_text('#modelbrowser .mb-source[data-provider="bedrock"]')
    if br.get("left_out"):
        expect(page.locator('[data-testid="mb-left-out-bedrock"]').count() == 1, f"no Not listed sentence: {src[:300]!r}")
    other = [r for r in br["rows"] if r.get("region") and r["region"] != br["region"]]
    if other:
        expect("only other regions offer" in src, f"the Bedrock line does not count the other regions' models: {src[:300]!r}")
        page.select_option("#mb-region", "other")
        page.wait_for_timeout(300)
        n = page.locator("#modelbrowser .mb-row").count()
        plain = page.locator("#modelbrowser .mb-row:not(:has(.mb-region))").count()
        expect(n == min(len(other), PAGE_ROWS) and plain == 0, f"Region › other regions: {n} rows ({plain} without a region), {len(other)} expected")
        shot(page, "model-browser-other-regions")
        page.select_option("#mb-region", "")
    guessed = [r for r in br["rows"] if r.get("guessed")]
    if guessed:
        page.fill("#mb-search", "not confirmed")
        page.wait_for_timeout(300)
        n = page.locator("#modelbrowser .mb-row").count()
        expect(n == min(len(guessed), PAGE_ROWS), f"search 'not confirmed': {n} rows, {len(guessed)} guessed")
        expect(page.locator("#modelbrowser .mb-row .mb-guessed").count() == n, "a guessed row without its Not confirmed badge")
        page.fill("#mb-search", "")
    rec.save()
    return "; ".join(said)


@check("settings", "model-browser-bedrock-profiles")
def model_browser_bedrock_profiles(ctx):
    """Bedrock's Claude ids are the real inference profiles: with a key that may list them (bedrock:ListInferenceProfiles),
    every profile id the page offers in the stack's region is an ACTIVE one of that list, Claude's among them, and none
    is guessed; with a key that may not, the page says so, and each id it could not confirm is marked Not confirmed (the
    row, its badge, and the line that says how many). Which case this is comes from AWS, asked in the same run."""
    from common import origin
    _need_helper(ctx)
    if not (ENV.get("AWS_ACCESS_KEY_ID") and ENV.get("AWS_SECRET_ACCESS_KEY")):
        raise Skip("no AWS key in .env (an instance role): AWS cannot be asked from here")
    d = _fresh(ctx)
    br = d["providers"]["bedrock"]
    expect(br["on"] and br.get("status") == "ok", f"Bedrock's list: {br.get('status')} {br.get('error')}")
    home = br["region"]
    rows = [r for r in br["rows"] if r.get("kind") != "app-profile" and r.get("region") in (home, "", None)]
    prof = [r for r in rows if r.get("model_id") and r["source_id"] != r["model_id"]]   # (called through a profile)
    claude = [r for r in prof if "anthropic." in r["source_id"]]
    expect(claude, f"no Claude profile id in {home}'s list")
    st, code, active, _ = _profiles(home)
    if st == 200:
        expect(br.get("profiles") == "ok", f"AWS lets the key list profiles; the page says {br.get('profiles')!r}")
        unknown = [r["source_id"] for r in prof if r["source_id"] not in active]
        expect(not unknown, f"profile ids that are not ACTIVE profiles in {home}: {unknown[:8]}")
        guessed = [r["source_id"] for r in br["rows"] if r.get("guessed")]
        expect(not guessed, f"guessed with a key that may list profiles: {guessed[:8]}")
        return f"the key may list profiles: {len(prof)} profile ids in {home}, every one ACTIVE in ListInferenceProfiles ({len(claude)} Claude); none guessed"
    expect(st in (400, 403) and "AccessDenied" in code, f"ListInferenceProfiles in {home}: HTTP {st} {code}")
    expect(br.get("profiles") == "denied", f"AWS refuses the key ({code}); the page says profiles={br.get('profiles')!r}")
    guessed = [r for r in prof if r.get("guessed")]
    expect(all("Not confirmed" in r["note"] for r in guessed), "a guessed row without its Not confirmed note")
    page, rec = ctx.page("model-browser-bedrock-profiles")
    login(page)
    page.goto(origin() + "/#modelbrowser")
    page.wait_for_selector("#modelbrowser:not([hidden]) .mb-row", timeout=30000)
    note = page.inner_text('[data-testid="mb-profiles-note"]')
    expect("may not list inference profiles" in note, f"the profiles note: {note[:300]!r}")
    if guessed:
        expect(f"{len([r for r in br['rows'] if r.get('guessed')])} marked Not confirmed" in note, f"the note does not count the guesses: {note[:300]!r}")
        page.locator('#modelbrowser [data-prov="bedrock"]').click()
        page.fill("#mb-search", "claude not confirmed")
        page.wait_for_timeout(300)
        expect(page.locator("#modelbrowser .mb-row .mb-guessed").count() >= 1, "no Claude row shows Not confirmed")
        shot(page, "model-browser-not-confirmed")
    rec.save()
    return (f"the key may not list profiles ({code}): {len(guessed)} of {len(prof)} profile ids in {home} marked Not confirmed "
            f"({len(prof) - len(guessed)} confirmed with GetInferenceProfile), and the page says why")
