"""Settings page: per-key policy equivalence, in a real Chromium (run.sh: the e2e suite's pinned Playwright image; no
stack, no AWS, no helper).

A stub serves portal/portal/static under the portal's own CSP and answers /api/settings from the real
catalog/settings.tsv and catalog/settings-layout.tsv through the portal's own code (portal.settings.snapshot and
.layout), with every switch off and with every switch on, on this computer (here.remote false) and on a remote
device (here.remote true, REMOTE_ADMIN_ACTIONS on). It opens every section and every "More settings" from the
section list, then each remaining setting by its address (#settings/<KEY>: the ones under a switch that is off), and
lists each setting's enabled controls. It checks, for every key of settings.tsv:

  - a control that changes something only where the policy is edit, local, on-only, widen-local or regen (never for
    ro, derived or companion keys), and none for a local key on a remote device;
  - on this computer, every changeable key has one (an on-only switch that is on: none, turning it off is a terminal
    step); the keys shown inside another row (a pair's second half, a pin's automatic choice) through that row;
  - a widen-local switch is disabled on a remote device exactly when its next value protects less
    (portal.settings.weakens, the server's own rule), and an on-only switch whenever it is on; the nightly backups
    kept: an option is disabled exactly when it is fewer, remotely;
  - a form with a less protective value on a remote device (a higher budget, a longer session) says so before the
    password is asked for; the same value on this computer reaches the password dialog;
  - without a layout file (a damaged checkout) every changeable key still has its control;
  - a provider key's form (check_keys): Save waits for a key, a "Get a key" link and a format hint under the field, a
    key of the wrong shape or an unchanged value never reaches the password dialog, the provider is asked first (a
    stand-in for POST /api/settings/check-key: rejected → said under the field with a link, the key kept; no answer →
    Save anyway), and a change the helper refuses opens the form again with the key and the reason;
  - no page error and no CSP violation anywhere.
Prints a summary, writes /out/settings-policy.json, exits 1 on any failure.
"""
import http.server
import json
import os
import re
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path

REPO = Path(os.environ.get("BN_REPO_DIR", "/repo"))
OUT = Path(os.environ.get("E2E_OUT_DIR", "/out"))
sys.path.insert(0, str(REPO / "portal"))
from portal import settings as st  # noqa: E402  (the portal's own snapshot reader, layout reader and rules)
from portal import answers as an  # noqa: E402  (the subscriptions' tools, as /api/settings lists them)

from playwright.sync_api import sync_playwright  # noqa: E402

STATIC = REPO / "portal" / "portal" / "static"
PORT = 18301
BASE = f"http://127.0.0.1:{PORT}"
# portal/portal/app.py _security_headers (no app origins here)
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
       "frame-src 'none'; form-action 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'")
CHANGE_POLICIES = ("edit", "local", "on-only", "widen-local", "regen")
ON = {"bool": "true", "on_off": "on", "true_blank": "true"}
OFF = {"bool": "false", "on_off": "off", "true_blank": ""}
SAMPLE = {"budget": "5", "days": "30", "pct": "80", "hour": "3", "keep": "7", "email": "owner@example.com",
          "login": "you@example.com", "stt_provider": "bedrock"}
# read-only switches and modes the page treats as parents (TERMINAL_ENABLED, REMOTE_TERMINAL, REMOTE_MODE …)
RO_ON = {"TERMINAL_ENABLED": "true", "REMOTE_TERMINAL": "true", "REMOTE_MODE": "tailscale",
         "REMOTE_PREVIEW_HOST": "bn-preview.tail1234.ts.net", "TERMINAL_WORKSPACE": "/home/you/work"}


def table():
    rows = []
    for line in (REPO / "catalog" / "settings.tsv").read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        c = line.split("\t")
        if c[0] == "key" or len(c) < 9:
            continue
        rows.append(dict(zip(("key", "group", "secret", "policy", "validator", "apply", "label", "note", "cli"), c)))
    return rows


TABLE = table()
BY_KEY = {r["key"]: r for r in TABLE}


def raw_value(r, state):
    """The .env value of key R with every switch off or on (plain keys only)."""
    v = r["validator"]
    if v in ON:
        return ON[v] if state == "on" else OFF[v]
    if r["key"] in RO_ON:
        return RO_ON[r["key"]] if state == "on" else ""
    return SAMPLE.get(v, "")


def snapshot(state):
    """The snapshot ./stack would write (lib/settings.sh settings_snapshot_write), read back by the portal's code."""
    keys = []
    for r in TABLE:
        row = {k: r[k] for k in ("key", "group", "secret", "policy", "validator", "apply", "label", "note", "cli")}
        if r["secret"] in ("-", "s"):
            row["value"] = raw_value(r, state)
            row["present"], row["set"] = True, bool(row["value"])
        else:   # a secret: set while the switches are on (the OpenRouter key turns its options on), never its value
            is_set = state == "on" or r["key"] in ("PORTAL_PASSWORD", "LITELLM_UI_PASSWORD", "RUSTFS_ACCESS_KEY",
                                                   "RUSTFS_SECRET_KEY", "SHARED_MCP_TOKEN", "LITELLM_KEY_SETUP")
            row["present"], row["set"] = True, is_set
            if is_set and r["secret"] in ("k", "h", "u"):
                row["hint"] = "…abcd"
        keys.append(row)
    d = tempfile.mkdtemp()
    Path(d, "settings.json").write_text(json.dumps({
        "version": 1, "written_at": int(time.time()), "base": "a" * 64, "remote_on": state == "on", "last_change": None,
        "choices": {"stt_models": {"bedrock": ["voxtral-small"], "openai": ["gpt-4o-mini-transcribe"], "groq": []},
                    "stt_bedrock_ready": ["voxtral-small"], "restart": ["litellm"],
                    "chat_models": [["claude-haiku-5-5", "Claude Haiku 5.5"], ["claude-opus-5-5", "Claude Opus 5.5"]],
                    "code_workspace": "/home/you/work",
                    # Settings › Claude Code › Models: [id, name, provider, vendor, compat, free, listed]
                    "code_models": [["claude-opus-5-5", "Claude Opus 5.5", "Bedrock", "Anthropic", "works", False, True, "$4.40/$22.00 per 1M"],
                                    ["claude-haiku-5-5", "Claude Haiku 5.5", "Bedrock", "Anthropic", "works", False, True],
                                    ["llama-3-3-70b", "Llama 3.3 70B", "Bedrock", "Meta", "chat-only", False, True],
                                    ["mistral-large-3", "Mistral Large 3", "Bedrock", "Mistral", "works", False, True, "$0.50/$1.50 per 1M"],
                                    ["or/google/gemma-4-31b-it:free", "Gemma 4 31B (free)", "OpenRouter", "Google", "untested", True, True],
                                    ["or/meta-llama/llama-3.3-70b-instruct", "Llama 3.3 70B Instruct", "OpenRouter", "Meta", "untested", False, True],
                                    ["xl/qwen3.8-27b", "qwen3.8-27b", "Experiential Labs", "Qwen", "untested", False, True, "$0.32/$2.40 per 1M"]]},
        "keys": keys}))
    snap = st.snapshot(Path(d))
    assert snap and len(snap["keys"]) == len(TABLE), "the portal did not read the snapshot"
    return snap


SNAP = {"off": snapshot("off"), "on": snapshot("on")}
LAYOUT = st.layout(REPO / "catalog")
assert LAYOUT["sections"] and LAYOUT["rows"], "the portal did not read catalog/settings-layout.tsv"
MODE = {"state": "off", "remote": False, "layout": True}


def settings_json():
    on = MODE["state"] == "on"
    return {"available": True, "snapshot": SNAP[MODE["state"]], "layout": LAYOUT if MODE["layout"] else {"sections": [], "rows": []},
            "helper": {"running": True, "heartbeat_at": int(time.time()), "settings": True, "diagnostics": list(st.DIAG_ACTIONS),
                       "in_progress": False, "job": None},
            "here": {"remote": MODE["remote"], "allowed": True}, "apps": {}, "user": "owner@example.com",
            # (Your AI subscriptions: the catalog's tools, not checked yet — the row a setting may be shown inside)
            "subscriptions": an.tools(REPO / "catalog", Path(tempfile.mkdtemp())),
            "backups": {"written_at": None, "backups": [], "nightly": {"on": on, "hour": 2, "keep": 7}},
            "remote": {"on": on, "mode": "tailscale" if on else "off", "url": "https://bn.tail1234.ts.net" if on else ""}}


TYPES = {".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".html": "text/html"}


class Stub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            page = (STATIC / "index.html").read_text(encoding="utf-8")
            meta = ('<meta name="bn-apps" content="{}">\n<meta name="bn-app-scheme" content="">\n'
                    '<meta name="bn-terminal" content="{&quot;enabled&quot;: false, &quot;here&quot;: false}">\n'
                    '<meta name="bn-code" content="{&quot;enabled&quot;: false, &quot;here&quot;: false}">')
            return self.send(200, page.replace("</head>", meta + "\n</head>", 1), "text/html; charset=utf-8")
        if path == "/api/settings":
            return self.send(200, json.dumps(settings_json()), "application/json")
        if path.startswith("/static/"):
            f = (STATIC / path[len("/static/"):]).resolve()
            if STATIC.resolve() in f.parents and f.is_file():
                return self.send(200, f.read_bytes(), TYPES.get(f.suffix, "application/octet-stream"))
        if path == "/api/admin/status" and STUB["job"]:
            return self.send(200, json.dumps({"running": True, "allowed": True, "job": STUB["job"], "in_progress": False,
                                              "finished": STUB["finished"]}), "application/json")
        if path.startswith("/api/"):
            return self.send(503, json.dumps({"error": "a stub: only /api/settings answers"}), "application/json")
        return self.send(404, "not here", "text/plain")

    def do_POST(self):
        """The key check before the password (a stand-in provider: a key with "bad" in it is rejected, one with "slow"
        gets no answer in time) and a change (202; its job then fails as STUB["fail"] says)."""
        path = self.path.split("?")[0]
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if path == "/api/settings/check-key":
            STUB["checks"].append(body)
            v = body.get("value", "")
            if "late" in v:   # (an answer that takes a while: the form may be cancelled or edited meanwhile)
                time.sleep(1.5)
            if "bad" in v:
                d = {"result": "rejected", "message": "OpenRouter rejected this key (HTTP 401).", "url": "https://openrouter.ai/settings/keys", "models": None}
            elif "slow" in v:
                d = {"result": "unreachable", "message": "openrouter.ai did not answer within 8 s, so the key is not checked yet.",
                     "url": "https://openrouter.ai/settings/keys", "models": None}
            else:
                d = {"result": "ok", "message": "OpenRouter accepts this key.", "url": "https://openrouter.ai/settings/keys", "models": None}
            return self.send(200, json.dumps(d), "application/json")
        if path == "/api/settings/apply":
            STUB["applied"].append(body)
            STUB["job"] = {"id": "e2e-job", "action": "settings", "phase": "failed", "message": STUB["fail"]}
            if STUB["hide"]:   # (the helper started its nightly backup right after: the change's result is among the finished)
                STUB["finished"] = [{**STUB["job"], "finished_at": int(time.time())}]
                STUB["job"] = {"id": "nightly-1", "action": "backup-nightly", "phase": "running", "message": "Nightly backup", "started_at": int(time.time())}
            return self.send(202, json.dumps({"id": "e2e-job", "keys": list((body.get("set") or {}).keys())}), "application/json")
        return self.send(404, json.dumps({"error": "a stub"}), "application/json")


STUB = {"checks": [], "applied": [], "job": None, "hide": False, "finished": [],
        "fail": "OPENROUTER_API_KEY: OpenRouter rejected the key (HTTP 401) — create one at https://openrouter.ai/settings/keys — nothing was changed"}


# --- the page ---

COLLECT = """(sel) => {
  // (a setting's row; a row of the page's own (data-own), whose settings are its blocks with data-for; such a block)
  const one = (r) => {
    const acts = r.querySelector(':scope > .set-actions') || r.querySelector(':scope > .set-project-actions');
    const env = r.querySelector('.set-envkey code');   // "In .env: KEY · the keys shown inside the row"
    const o = { key: r.dataset.key || r.dataset.own || r.dataset.for, switch: null, selects: [], change: [], diag: [], reveal: [],
      visible: r.offsetParent !== null,
      inside: env ? env.textContent.split(' · ').slice(1) : r.dataset.own ? [...r.querySelectorAll('[data-for]')].map((e) => e.dataset.for) : [] };
    if (!acts) return o;
    for (const sw of acts.querySelectorAll('[role=switch]')) o.switch = { enabled: !sw.disabled, on: sw.getAttribute('aria-checked') === 'true' };
    for (const s of acts.querySelectorAll('select')) o.selects.push({ enabled: !s.disabled, options: [...s.options].map((x) => [x.value, x.disabled]) });
    for (const b of acts.querySelectorAll('button.action')) (b.dataset.act ? o.diag : o.change).push([b.textContent, !b.disabled]);
    for (const b of acts.querySelectorAll('.set-seg button')) o.change.push([b.textContent, !b.disabled]);
    for (const b of acts.querySelectorAll('button.copy[data-reveal]')) o.reveal.push([b.dataset.reveal, !b.disabled]);
    return o;
  };
  return [...document.querySelectorAll(sel)].map(one);
}"""


def changes(o):
    return bool((o["switch"] and o["switch"]["enabled"]) or any(s["enabled"] for s in o["selects"]) or any(e for _, e in o["change"]))


def ctx_values(state):
    return {k["key"]: k.get("value", "") for k in SNAP[state]["keys"]}


def expected_switch(key, state, remote):
    """(enabled, on) of KEY's switch as the policy says (portal.settings.weakens is the server's rule)."""
    r = BY_KEY[key]
    vals = ctx_values(state)
    v = vals.get(key, "")
    on_v, off_v = ON[r["validator"]], OFF[r["validator"]]
    cur_on = bool(vals.get("REMOTE_PREVIEW_HOST")) if key == "REMOTE_PREVIEW" else v == on_v
    nxt = off_v if cur_on else on_v
    enabled = True
    if r["policy"] == "on-only" and cur_on:
        enabled = False
    if remote and r["policy"] == "widen-local" and st.weakens(key, nxt, v, vals):
        enabled = False
    if r["policy"] not in CHANGE_POLICIES:
        enabled = False
    return enabled, cur_on


def walk(page, failures, label):
    """Every section from the list and every More, then every setting not seen by its address. -> {KEY: controls}"""
    page.goto(BASE + "/#settings")
    page.wait_for_selector("#settings .set-card:not([hidden])", timeout=20000)
    seen = {}
    sections = page.eval_on_selector_all(".set-nav .set-nav-item", "els => els.map(e => e.dataset.section)")
    if MODE["layout"] and sections != [s["id"] for s in LAYOUT["sections"]]:
        failures.append(f"{label}: the section list is {sections}")
    for sid in sections:
        page.click(f".set-nav-item[data-section='{sid}']")
        page.wait_for_selector(f"#set-{sid}:not([hidden])")
        page.evaluate("() => document.querySelectorAll('#settings details.set-more').forEach((d) => { d.open = true; })")
        for o in page.evaluate(COLLECT, f"#set-{sid} .set-row[data-key], #set-{sid} .set-adv-item[data-key], #set-{sid} .set-row[data-own], "
                                        f"#set-{sid} .set-row[data-own] [data-for]"):
            if o["visible"]:
                seen[o["key"]] = o
    rows = [r for r in (LAYOUT["rows"] if MODE["layout"] else []) if not r["key"].startswith("+") and r["place"] != "with"]
    for r in rows:
        if r["key"] in seen:
            continue
        if not r["parent"]:
            failures.append(f"{label}: {r['key']} ({r['section']}, {r['place']}) not shown in its section")
        page.evaluate("k => { location.hash = '#settings'; location.hash = '#settings/' + k; }", r["key"])
        sel = f"#settings .set-row[data-key={r['key']}], #settings .set-adv-item[data-key={r['key']}], #settings [data-for={r['key']}]"
        page.wait_for_selector(sel, state="visible", timeout=10000)
        seen[r["key"]] = page.evaluate(COLLECT, sel)[0]
    # a setting shown inside one of the page's own rows (+subscriptions' Claude plan switch), not seen in its section (that
    # row under a switch that is off): by its address too, and the own row it lands in
    for r in (LAYOUT["rows"] if MODE["layout"] else []):
        if r["place"] != "with" or not r["parent"].startswith("+") or r["key"] in seen:
            continue
        page.evaluate("k => { location.hash = '#settings'; location.hash = '#settings/' + k; }", r["key"])
        sel = f"#settings [data-for={r['key']}]"
        page.wait_for_selector(sel, state="visible", timeout=10000)
        seen[r["key"]] = page.evaluate(COLLECT, sel)[0]
        own = page.evaluate(COLLECT, f"#settings .set-row[data-own='{r['parent']}']")
        if own:
            seen.setdefault(r["parent"], own[0])
    return seen


def check_controls(seen, state, remote, failures, label, layout=True):
    # the keys a row shows inside it: as its "In .env:" line names them (and, with a layout, as the layout says)
    with_parent = {k: o["key"] for o in seen.values() for k in o["inside"]}
    if layout:
        for r in LAYOUT["rows"]:
            if r["place"] == "with" and with_parent.get(r["key"]) != r["parent"]:
                failures.append(f"{label}: {r['key']} is not listed inside {r['parent']}'s row")
    for key, r in BY_KEY.items():
        if key in with_parent and key not in seen:
            host = seen.get(with_parent[key])
            if host is None:
                failures.append(f"{label}: {key}: neither its row nor {with_parent[key]}'s is on the page")
            elif not remote and r["policy"] in CHANGE_POLICIES and not changes(host):
                failures.append(f"{label}: {key} ({r['policy']}): {with_parent[key]}'s row has no control for it")
            continue
        o = seen.get(key)
        if o is None:
            failures.append(f"{label}: {key} is not on the page")
            continue
        p, ch = r["policy"], changes(o)
        if ch and p not in CHANGE_POLICIES:
            failures.append(f"{label}: {key} ({p}) has a control that changes it: {o}")
        if ch and remote and p == "local":
            failures.append(f"{label}: {key} (local) can be changed from a remote device: {o}")
        if o["switch"]:
            want, cur_on = expected_switch(key, state, remote)
            if o["switch"]["enabled"] != want or o["switch"]["on"] != cur_on:
                failures.append(f"{label}: {key} ({p}) switch {o['switch']}, policy says enabled={want} on={cur_on}")
        elif not remote and p in CHANGE_POLICIES and not ch:
            failures.append(f"{label}: {key} ({p}) has no control on this computer: {o}")
        if key == "TERMINAL_EGRESS":   # three choices; remotely only those that do not open it further
            cur = st.egress_mode(ctx_values(state).get(key, ""))
            got = dict(o["change"])
            for val, chip in (("internet", "Internet only"), ("host", "+ this computer"), ("off", "Off")):
                want = not (remote and val != cur and st.weakens(key, val, cur))
                if got.get(chip) is not want:
                    failures.append(f"{label}: TERMINAL_EGRESS choice {chip!r} enabled={got.get(chip)}, policy says {want}")
        if key == "BACKUP_KEEP" and o["selects"]:
            cur = ctx_values(state)["BACKUP_KEEP"] or "7"
            for val, disabled in o["selects"][0]["options"]:
                want = remote and val != cur and st.weakens("BACKUP_KEEP", val, cur)
                if disabled != want:
                    failures.append(f"{label}: BACKUP_KEEP option {val} disabled={disabled}, policy says {want}")
        for rk, enabled in o["reveal"]:
            if rk not in st.REVEAL:
                failures.append(f"{label}: {key} offers to reveal {rk}, which the portal never reveals")


def check_forms(page, remote, failures, label):
    """A less protective value typed in a form: refused before the password remotely, asked for locally."""
    for key, weaker, safer in (("BUDGET_OPENWEBUI", "500", "1"), ("PORTAL_SESSION_DAYS", "60", "7"), ("BUDGET_ALERT_PCT", "95", "60")):
        page.evaluate("k => { location.hash = '#settings'; location.hash = '#settings/' + k; }", key)
        row = page.locator(f"#settings .set-row[data-key={key}]")
        row.wait_for(state="visible", timeout=10000)
        for value, refused in ((weaker, remote), (safer, False)):
            row.locator(".set-actions .action", has_text=re.compile("Change|Set")).first.click()
            form = row.locator(".set-form")
            form.locator("input").first.fill(value)
            form.locator("button[type=submit]").click()
            page.wait_for_timeout(150)
            dialog = page.locator("#set-confirm[open]").count() == 1
            err = form.locator(".error:not([hidden])")
            said = err.count() == 1 and "from the computer running DevOS ADE" in err.inner_text()
            if refused and (dialog or not said):
                failures.append(f"{label}: {key}={value} remotely: dialog={dialog}, said={said}")
            if not refused and (not dialog or said):
                failures.append(f"{label}: {key}={value}: dialog={dialog}, refused={said}")
            if dialog:
                page.click("#set-confirm-cancel")
            if form.count():
                form.locator("button", has_text="Cancel").click()


def check_keys(page, failures, label):
    """A provider key's form (UX-05): Save waits for a key, a key of the wrong shape and an unchanged value never reach
    the password dialog, the provider is asked first (a rejected key: said under the field with a link to where keys
    come from, the key kept; no answer: Save anyway), and a change the helper refuses opens the form again with the key
    and the reason. Fake keys are made here at run time."""
    def open_key(key, button):
        page.evaluate("k => { location.hash = '#settings'; location.hash = '#settings/' + k; }", key)
        row = page.locator(f"#settings .set-row[data-key={key}]")
        row.wait_for(state="visible", timeout=10000)
        row.locator(":scope > .set-actions button.action", has_text=button).click()
        return row, row.locator(".set-form")

    def said(form):
        e = form.locator(":scope > .error")
        return e.inner_text() if e.count() and e.is_visible() else ""

    prefix = "-".join(("sk", "or", "v1", ""))
    row, form = open_key("OPENROUTER_API_KEY", "Replace key")
    save, field = form.locator("button[type=submit]"), form.locator("input[type=password]")
    if not save.is_disabled():
        failures.append(f"{label}: OpenRouter's Save is enabled with an empty key")
    link = form.locator(".set-getkey a")
    if link.count() != 1 or link.get_attribute("href") != "https://openrouter.ai/settings/keys" or link.get_attribute("target") != "_blank":
        failures.append(f"{label}: no Get a key link under OpenRouter's field: {link.count()}")
    if field.get_attribute("placeholder") != "sk-or-v1-…":
        failures.append(f"{label}: OpenRouter's field has no format hint: {field.get_attribute('placeholder')!r}")
    if form.locator("button", has_text="Remove the key").count() != 1:
        failures.append(f"{label}: Remove the key is not its own button")
    page.screenshot(path=str(OUT / "settings-key-empty.png"), clip=row.bounding_box())
    # the wrong shape: said under the field, nothing asked
    field.fill("has spaces so not a key")
    save.click()
    page.wait_for_timeout(200)
    if "must be an OpenRouter key" not in said(form) or page.locator("#set-confirm[open]").count() or STUB["checks"]:
        failures.append(f"{label}: a key of the wrong shape: said {said(form)!r}, checks {len(STUB['checks'])}")
    if field.get_attribute("aria-invalid") != "true":
        failures.append(f"{label}: the field is not marked invalid")
    # rejected by the provider: under the field, with the link, the key kept, no password dialog
    bad = prefix + "bad" + "0" * 30
    field.fill(bad)
    save.click()
    form.locator(":scope > .error a").wait_for(timeout=5000)
    err = said(form)
    a = form.locator(":scope > .error a")
    if ("OpenRouter rejected this key" not in err or a.get_attribute("href") != "https://openrouter.ai/settings/keys"
            or field.input_value() != bad or page.locator("#set-confirm[open]").count()):
        failures.append(f"{label}: a rejected key: {err!r}, link {a.get_attribute('href')}, kept {field.input_value() == bad}")
    if not STUB["checks"] or STUB["checks"][-1] != {"key": "OPENROUTER_API_KEY", "value": bad}:
        failures.append(f"{label}: the check asked {STUB['checks'][-1:]}")
    page.screenshot(path=str(OUT / "settings-key-rejected.png"), clip=row.bounding_box())
    # no answer in time: said, and Save anyway goes on to the password without asking again
    field.fill(prefix + "slow" + "0" * 30)
    save.click()
    page.wait_for_function("() => document.querySelector('#settings .set-form button[type=submit]').textContent === 'Save anyway'", timeout=5000)
    n = len(STUB["checks"])
    if "did not answer within 8 s" not in said(form):
        failures.append(f"{label}: no answer in time: {said(form)!r}")
    save.click()
    page.wait_for_selector("#set-confirm[open]", timeout=5000)
    if len(STUB["checks"]) != n:
        failures.append(f"{label}: Save anyway asked the provider again")
    page.click("#set-confirm-cancel")
    # an answer that comes after the form was edited, or cancelled: no password dialog for what is no longer there
    late = prefix + "late" + "0" * 30
    field.fill(late)
    save.click()
    page.wait_for_timeout(300)
    field.fill(late + "1")
    page.wait_for_timeout(2000)
    if page.locator("#set-confirm[open]").count():
        failures.append(f"{label}: an edit while the key was checked still opened the password dialog")
        page.click("#set-confirm-cancel")
    field.fill(late)
    save.click()
    page.wait_for_timeout(300)
    form.locator("button", has_text="Cancel").click()
    page.wait_for_timeout(2000)
    if page.locator("#set-confirm[open]").count():
        failures.append(f"{label}: Cancel while the key was checked still opened the password dialog")
        page.click("#set-confirm-cancel")
    row, form = open_key("OPENROUTER_API_KEY", "Replace key")
    save, field = form.locator("button[type=submit]"), form.locator("input[type=password]")
    # accepted: the password dialog; the helper then refuses it: the form again, the key in it, the reason under it
    good = prefix + "good" + "0" * 30
    field.fill(good)
    save.click()
    page.wait_for_selector("#set-confirm[open]", timeout=5000)
    if "OpenRouter accepts this key" not in form.locator(".set-check").inner_text():
        failures.append(f"{label}: an accepted key is not said: {form.locator('.set-check').inner_text()!r}")
    page.fill("#set-confirm-password", "the portal password")
    page.click("#set-confirm-ok")
    page.wait_for_function("() => { const e = document.querySelector('#settings .set-row[data-key=OPENROUTER_API_KEY] > .set-form > .error');"
                           " return e && !e.hidden && /Not saved/.test(e.textContent); }", timeout=15000)
    form = page.locator("#settings .set-row[data-key=OPENROUTER_API_KEY] > .set-form")
    err = said(form)
    if (not err.startswith("Not saved: OpenRouter rejected the key (HTTP 401)") or "Nothing was changed." not in err
            or form.locator(":scope > .error a").get_attribute("href") != "https://openrouter.ai/settings/keys"
            or form.locator("input[type=password]").input_value() != good or not page.locator("#set-job").is_hidden()):
        failures.append(f"{label}: the helper's refusal: {err!r}, the key kept {form.locator('input[type=password]').input_value() == good}")
    if STUB["applied"][-1]["set"] != {"OPENROUTER_API_KEY": good}:
        failures.append(f"{label}: the change sent {list(STUB['applied'][-1]['set'])}")
    page.screenshot(path=str(OUT / "settings-key-helper-refused.png"),
                    clip=page.locator("#settings .set-row[data-key=OPENROUTER_API_KEY]").bounding_box())
    form.locator("button", has_text="Cancel").click()
    STUB["job"] = None
    # the same refusal when the helper started another job at once after it (a nightly backup a change turned on in its
    # window): the change's result is found among the helper's finished jobs, not lost behind the newer one's status
    STUB["hide"] = True
    row, form = open_key("OPENROUTER_API_KEY", "Replace key")
    form.locator("input[type=password]").fill(good)
    form.locator("button[type=submit]").click()
    page.wait_for_selector("#set-confirm[open]", timeout=5000)
    page.fill("#set-confirm-password", "the portal password")
    page.click("#set-confirm-ok")
    try:
        page.wait_for_function("() => { const e = document.querySelector('#settings .set-row[data-key=OPENROUTER_API_KEY] > .set-form > .error');"
                               " return e && !e.hidden && /Not saved: OpenRouter rejected/.test(e.textContent); }", timeout=15000)
    except Exception:  # noqa: BLE001
        failures.append(f"{label}: a change's result behind a newer job of the helper is never shown: {page.inner_text('#set-job')[:200]!r}")
    form = page.locator("#settings .set-row[data-key=OPENROUTER_API_KEY] > .set-form")
    if form.count():
        form.locator("button", has_text="Cancel").click()
    STUB.update(hide=False, job=None, finished=[])
    # the AWS key: Save once both halves are there; a temporary key is refused before the password
    row, form = open_key("AWS_ACCESS_KEY_ID", "Replace key")
    save = form.locator("button[type=submit]")
    form.locator("input").nth(0).fill("ASIA" + "X" * 16)
    if not save.is_disabled():
        failures.append(f"{label}: the AWS key's Save is enabled with half a key")
    form.locator("input").nth(1).fill("s" * 40)
    save.click()
    page.wait_for_timeout(200)
    if "temporary key" not in said(form) or page.locator("#set-confirm[open]").count():
        failures.append(f"{label}: a temporary AWS key: {said(form)!r}")
    if form.locator(".set-getkey a").get_attribute("href") != "https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html":
        failures.append(f"{label}: the AWS key has no Get a key link")
    form.locator("button", has_text="Cancel").click()
    # a web search key: its Get a key link is its info panel's; no check request (a search costs)
    n = len(STUB["checks"])
    row, form = open_key("WEBSEARCH_TAVILY_API_KEY", "Replace key")
    if form.locator(".set-getkey a").get_attribute("href") != "https://app.tavily.com/":
        failures.append(f"{label}: Tavily has no Get a key link")
    form.locator("input[type=password]").fill("tvly-" + "a" * 20)
    form.locator("button[type=submit]").click()
    page.wait_for_selector("#set-confirm[open]", timeout=5000)
    page.click("#set-confirm-cancel")
    if len(STUB["checks"]) != n:
        failures.append(f"{label}: a web search key was sent to a check")
    if form.count():
        form.locator("button", has_text="Cancel").click()
    # an unchanged value: no password dialog
    row, form = open_key("BUDGET_OPENWEBUI", re.compile("Change|Set"))
    form.locator("input").first.fill(ctx_values("on")["BUDGET_OPENWEBUI"])
    form.locator("button[type=submit]").click()
    page.wait_for_timeout(200)
    if "nothing to save" not in said(form) or page.locator("#set-confirm[open]").count():
        failures.append(f"{label}: an unchanged budget: {said(form)!r}")
    form.locator("button", has_text="Cancel").click()


def check_code_models(page, failures, label):
    """Settings › Claude Code › Models: All enabled · Anthropic only · Pick… (a filtered checklist in groups), and the
    default model's select in groups; screenshots for the record."""
    page.evaluate("k => { location.hash = '#settings'; location.hash = '#settings/' + k; }", "CODE_MODELS")
    row = page.locator("#settings .set-row[data-key=CODE_MODELS]")
    row.wait_for(state="visible", timeout=10000)
    chips = row.locator(".set-seg button").all_inner_texts()
    if chips != ["All enabled", "Anthropic only", "Pick…"]:
        failures.append(f"{label}: CODE_MODELS offers {chips}")
    if "7 enabled chat models, 3 of them checked" not in row.inner_text():
        failures.append(f"{label}: CODE_MODELS does not say how many models work: {row.inner_text()[:200]}")
    page.screenshot(path=str(OUT / "settings-code-models.png"), clip=row.bounding_box())
    row.locator(".set-seg button", has_text="Pick…").click()
    form = row.locator(".set-form")
    heads = form.locator(".set-code-head").all_text_contents()
    if heads != ["Anthropic (Bedrock)", "Other providers on Bedrock", "OpenRouter: free", "OpenRouter: paid", "Experiential Labs"]:
        failures.append(f"{label}: the checklist's groups are {heads}")
    form.locator("input[type=search]").fill("free")
    visible = [x for x in form.locator("label.set-radio").all() if x.is_visible()]
    if len(visible) != 1 or "Gemma 4 31B (free)" not in visible[0].inner_text():
        failures.append(f"{label}: the filter 'free' shows {[x.inner_text() for x in visible]}")
    form.locator("input[type=search]").fill("")
    page.screenshot(path=str(OUT / "settings-code-models-pick.png"), clip=row.bounding_box())
    form.locator("button[type=submit]").click()
    page.wait_for_timeout(150)
    if "Pick at least one model" not in form.locator(".error").inner_text():
        failures.append(f"{label}: an empty list is not refused before the password")
    form.locator("label.set-radio", has_text="Llama 3.3 70B").first.locator("input").check()
    form.locator("button[type=submit]").click()
    page.wait_for_timeout(150)
    if page.locator("#set-confirm[open]").count() != 1:
        failures.append(f"{label}: a list with a model does not reach the password dialog")
    else:
        page.click("#set-confirm-cancel")
    if form.count():
        form.locator("button", has_text="Cancel").click()
    page.evaluate("k => { location.hash = '#settings'; location.hash = '#settings/' + k; }", "CODE_DEFAULT_MODEL")
    row = page.locator("#settings .set-row[data-key=CODE_DEFAULT_MODEL]")
    row.wait_for(state="visible", timeout=10000)
    row.locator(".set-actions .action", has_text=re.compile("Change|Set")).first.click()
    groups = row.locator(".set-form select optgroup").evaluate_all("els => els.map((e) => e.label)")
    if groups != ["Anthropic (Bedrock)", "Other providers on Bedrock", "OpenRouter: free", "OpenRouter: paid", "Experiential Labs"]:
        failures.append(f"{label}: CODE_DEFAULT_MODEL's select groups are {groups}")
    # the confirmation names the model's price and how it works
    row.locator(".set-form select").select_option("mistral-large-3")
    row.locator(".set-form button[type=submit]").click()
    page.wait_for_selector("#set-confirm[open]", timeout=5000)
    said = page.inner_text("#set-confirm")
    if "Mistral Large 3 (mistral-large-3): $0.50/$1.50 per 1M, works with Claude Code" not in said:
        failures.append(f"{label}: CODE_DEFAULT_MODEL's confirmation does not name the price: {said[:300]!r}")
    page.click("#set-confirm-cancel")
    if row.locator(".set-form").count():
        row.locator(".set-form button", has_text="Cancel").click()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    failures, summary = [], {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        runs = [("off", False, True), ("on", False, True), ("off", True, True), ("on", True, True), ("off", False, False)]
        for state, remote, layout in runs:
            MODE.update(state=state, remote=remote, layout=layout)
            label = f"{'remote' if remote else 'local'}/{state}{'' if layout else '/no-layout'}"
            ctx = browser.new_context(viewport={"width": 1280, "height": 900})
            ctx.add_init_script("try { localStorage.setItem('bn.tour', JSON.stringify({open: false, cur: 'welcome', done: [], skipped: [], base: {}})); } catch (_) {}")
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e, errors=errors: errors.append(f"pageerror: {e}"))
            page.on("console", lambda m, errors=errors: errors.append(f"console: {m.text}")
                    if m.type == "error" and ("Content Security Policy" in m.text or "Refused" in m.text) else None)
            try:
                seen = walk(page, failures, label)
                check_controls(seen, state, remote, failures, label, layout)
                if layout and state == "off":
                    check_forms(page, remote, failures, label)
                if layout and state == "off" and not remote:
                    check_code_models(page, failures, label)
                if layout and state == "on" and not remote:   # (every key set: Replace key, and Remove the key)
                    check_keys(page, failures, label)
                summary[label] = {"settings": len(seen), "changeable": sum(1 for o in seen.values() if changes(o))}
            except Exception:  # noqa: BLE001
                failures.append(f"{label}: {traceback.format_exc(limit=3)}")
                page.screenshot(path=str(OUT / f"settings-policy-{label.replace('/', '-')}.png"), full_page=True)
            failures += [f"{label}: {e}" for e in errors]
            ctx.close()
        browser.close()
    srv.shutdown()
    (OUT / "settings-policy.json").write_text(json.dumps({"summary": summary, "failures": failures}, indent=2))
    for k, v in summary.items():
        print(f"  {k:<18} {v['settings']} settings on the page, {v['changeable']} with a control that changes them")
    if failures:
        print(f"FAIL: {len(failures)}")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print(f"ok: every key of settings.tsv ({len(TABLE)}) has controls only where its policy allows, local and remote, "
          "switches off and on, and without the layout file")


if __name__ == "__main__":
    main()
