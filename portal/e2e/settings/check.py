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
            # the core services (./stack versions): one behind upstream, one that Update now brings
            "versions": {"written_at": 1, "checked": "2026-10-27", "services": [
                {"id": "litellm", "name": "LiteLLM", "running": "1.106.3", "pinned": "1.106.3", "newest": "1.106.5", "state": "behind",
                 "notes": "https://github.com/BerriAI/litellm/releases/tag/v1.106.5"},
                {"id": "rustfs", "name": "RustFS", "running": "1.0.1", "pinned": "1.0.3", "newest": "1.0.3", "state": "pending", "notes": ""},
                {"id": "caddy", "name": "Caddy", "running": "2.11.7", "pinned": "2.11.7", "newest": "2.11.7", "state": "current", "notes": ""}]},
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
        if path == "/api/models/browse":
            return self.send(200, json.dumps(BROWSE), "application/json")
        if path == "/api/local-models":
            body = json.dumps(lm_state())
            LM["gets"].append(body)          # (every answer kept: no key may be in any of them)
            return self.send(200, body, "application/json")
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
        if path == "/api/local-models/probe":    # (Check server of this computer: read-only, no password asked or sent)
            LM["probes"].append(body)
            if not re.match(r"(https?://)?(localhost|127\.\d+\.\d+\.\d+|\[::1\])(:\d+)?(/|$)", body.get("url", "")):
                return self.send(403, json.dumps({"error": "Checking another computer asks for your portal password."}), "application/json")
            return self.send(202, json.dumps(lm_helper({"op": "probe", "url": body.get("url", ""), "key": body.get("key", ""), "trust": body.get("trust")})), "application/json")
        if path == "/api/local-models/change":
            LM["changes"].append(body)
            if not body.get("password"):
                return self.send(403, json.dumps({"error": "a password"}), "application/json")
            if body.get("action") == "local-remove":
                LM["installed"] = [i for i in LM["installed"] if i["repo"] != body.get("repo")]
            return self.send(202, json.dumps({"id": "e2e-lc", "action": body.get("action")}), "application/json")
        if path == "/api/local-models/server":
            LM["posts"].append(body)
            if not body.get("password"):
                return self.send(403, json.dumps({"error": "a password"}), "application/json")
            return self.send(202, json.dumps(lm_helper(body)), "application/json")
        return self.send(404, json.dumps({"error": "a stub"}), "application/json")


# The model-server form's other side: what the portal answers (GET /api/local-models) and what the update helper makes of a
# request (lib/local_models.sh msrv_apply), simplified: a fake network where 10.0.0.5 serves two models, 203.0.113.9 is
# plain http to a public address, "down" in the address is refused, 169.254 is blocked. The key is never in any answer.
LM = {"servers": [], "result": None, "posts": [], "gets": [], "probes": [], "changes": [], "installed": []}
# GET /api/models/browse (the shape portal/model_browser.py produces; two built-in Bedrock models and nothing more)
BROWSE = {"providers": {"bedrock": {"on": True, "key": "BEDROCK_MODELS", "value": "", "at": int(time.time()) - 300, "stale": False, "error": None, "status": "ok", "region": "us-east-1", "rows": [
    {"provider": "bedrock", "id": "claude-haiku-5-5", "source_id": "us.anthropic.claude-haiku-5-5", "name": "Claude Haiku 5.5", "vendor": "Anthropic", "free": False, "in": 0.8, "out": 4.0,
     "context": 200000, "tools": True, "images": True, "compat": "works", "compat_note": "", "enabled": True, "chosen": True, "can": "none", "why": "built in: in every picker", "builtin": True, "lifecycle": "", "note": ""},
    {"provider": "bedrock", "id": "amazon.nova-pro-v1:0", "source_id": "amazon.nova-pro-v1:0", "name": "Nova Pro", "vendor": "Amazon", "free": False, "in": 0.8, "out": 3.2, "context": 300000,
     "tools": True, "images": True, "compat": "untested", "compat_note": "", "enabled": False, "chosen": False, "can": "add", "why": "", "builtin": False, "lifecycle": "", "note": ""}]}},
    "base": "0" * 64, "can_change": True, "why_not": "", "try": False}
LM_MODELS = [{"id": "qwen/Qwen3-8B", "context": 32768}, {"id": "llama3:8b", "context": None}]


def lm_state():
    return {"known": True, "at": int(time.time()), "stale": False, "wait": False, "can_change": True, "why_not": "", "hf_token_set": False,
            "runtime": {"kind": "none", "how": "No model runner is running on this computer.", "command": "./stack local-models enable", "dmr": "", "ollama": ""},
            "gpu": "none", "memory": 16 * 1024 ** 3, "disk": sum(i["bytes"] for i in LM["installed"]), "installed": LM["installed"], "servers": LM["servers"], "result": LM["result"],
            "job": {"state": "idle", "repo": "", "quant": "", "done_bytes": 0, "total_bytes": 0, "message": "", "at": None}}


def lm_helper(b):
    ref, op, name, url = secrets_ref(), b["op"], b.get("name", ""), b.get("url", "")
    r = {"ref": ref, "op": op, "name": name, "ok": True, "message": "", "status": "", "models": [], "reason": "", "warning": "",
         "key": bool(b.get("key")), "trust": bool(b.get("trust")), "url": url, "at": int(time.time())}
    if op == "probe":
        full = url if "://" in url else "http://" + url
        r["url"] = full
        if "169.254" in full:
            r.update(status="blocked", reason="that address is a cloud-metadata or link-local address, which is never used")
        elif "down" in full:
            r.update(status="down", reason="connection refused: nothing is listening at that address and port, or a firewall is in the way")
        else:
            r.update(status="ok", models=LM_MODELS)
            if "203.0.113" in full:
                r["warning"] = "This is plain http to a public address: prompts and answers travel unencrypted. Use https if the server has it."
    elif op == "save":
        ids = b.get("models") or []
        LM["servers"].append({"name": name, "url": url, "reached_as": url + "/v1", "trust": bool(b.get("trust")), "key": bool(b.get("key")), "up": True,
                              "reason": "", "warning": "", "models": LM_MODELS, "all": ids == ["*"], "enabled": [i for i in ids if i != "*"]})
    else:
        sv = next((x for x in LM["servers"] if x["name"] == name), None)
        if sv is None:
            r.update(ok=False, message=f"no server named {name}")
        elif op == "models":
            ids = b.get("models") or []
            sv["all"], sv["enabled"] = ids == ["*"], [i for i in ids if i != "*"]
        elif op == "key":
            sv["key"] = bool(b.get("key"))
        elif op == "remove":
            LM["servers"].remove(sv)
    LM["result"] = r
    return {"id": "e2e-lm", "op": op, "ref": ref}


def secrets_ref():
    import secrets
    return secrets.token_hex(8)


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
        # (a section with tabs, Models & providers' Keys / Subscriptions / Search: each tab in turn, as the rows of the others are hidden)
        tabs = page.locator(f"#set-{sid} .set-minnav .chip")
        for t in range(max(tabs.count(), 1)):
            if tabs.count():
                tabs.nth(t).click()
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


def check_services(page, failures, label):
    """Settings › Updates & backups › Core services: one line, the versions folded under it, the plain sentence per service."""
    page.evaluate("k => { location.hash = '#settings'; location.hash = '#settings/' + k; }", "+services")
    row = page.locator("#settings .set-row[data-own='+services']")
    row.wait_for(state="visible", timeout=10000)
    text = row.inner_text()
    if "1 not on this release's pinned version" not in text:
        failures.append(f"{label}: Core services does not say what Update now brings: {text[:200]}")
    table = row.locator("table")
    if table.is_visible():
        failures.append(f"{label}: Core services shows its table before Versions is opened (Settings must stay uncluttered)")
    if row.bounding_box()["height"] > 170:
        failures.append(f"{label}: Core services is {row.bounding_box()['height']:.0f}px tall folded")
    row.locator("summary", has_text="Versions").click()
    body = table.inner_text()
    for want in ("LiteLLM", "newer upstream exists (1.106.5); the next DevOS ADE release will bring it", "Update now brings it to 1.0.3", "current"):
        if want not in body:
            failures.append(f"{label}: Core services' table lacks {want!r}: {body[:300]}")
    page.screenshot(path=str(OUT / "settings-core-services.png"), clip=row.bounding_box())


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


def check_servers(page, failures, label):
    """Settings > Models & providers > Local models: This computer first; add a server (address, name, key, trust only for
    https) -> check it from the helper's side -> the models it serves each with a box -> add; the row's per-model
    switches, Edit key, Remove; the key in no answer and not on the page; the card scrolls inside, the page does not grow."""
    KEY = "secretkey" + "0123456789"
    PWD = "correct horse"
    LM.update(servers=[], result=None, posts=[], gets=[], probes=[], changes=[], installed=[])

    def ask(ok_text):
        page.wait_for_selector("#set-confirm[open]", timeout=5000)
        page.fill("#set-confirm-password", PWD)
        page.click("#set-confirm-ok")

    def check_server(here=False):   # Check server: this computer with no password dialog (nothing but the address, trust and key
        page.click("#ms-check")     # goes); another computer asks for the password first
        if not here:
            ask("Check")
            return
        page.wait_for_timeout(150)
        if page.locator("#set-confirm[open]").count():
            failures.append(f"{label}: Check server of this computer opened the password dialog")

    page.goto(BASE + "/#settings")
    page.wait_for_selector("#settings .set-card:not([hidden])", timeout=20000)
    page.click(".set-nav-item[data-section='providers']")
    page.click("#set-providers .set-minnav .chip[data-group='local models']")
    page.wait_for_selector("#lm-server-list", timeout=10000)
    first = page.eval_on_selector("#lm-server-list > li:first-child", "e => e.dataset.serverRow")
    if first != "this-computer":
        failures.append(f"{label}: the first row of the servers is {first!r}, not this computer")
    # the form: trust only for https
    page.fill("#ms-url", "10.0.0.5:8000")
    page.fill("#ms-key", KEY)
    if page.locator("#ms-trust-row").is_visible():
        failures.append(f"{label}: the trust option is shown for an http address")
    page.fill("#ms-url", "https://nas.lan:8443")
    if not page.locator("#ms-trust-row").is_visible():
        failures.append(f"{label}: the trust option is not shown for an https address")
    if page.get_attribute("#ms-key", "type") != "password":
        failures.append(f"{label}: the key field is not a password field")
    # a refused address says why, and Save is not offered
    page.fill("#ms-url", "169.254.169.254")
    check_server()
    page.wait_for_selector("#ms-probe.bad", timeout=10000)
    if "cloud-metadata" not in page.inner_text("#ms-probe") or page.locator("#ms-save").is_enabled():
        failures.append(f"{label}: a blocked address is not refused inline: {page.inner_text('#ms-probe')[:200]!r}")
    # this computer: no password
    page.fill("#ms-url", "localhost:11434")
    check_server(here=True)
    page.wait_for_selector("#ms-probe.good", timeout=10000)
    page.fill("#ms-url", "10.0.0.5:8000")
    check_server()
    page.wait_for_selector("#ms-probe.good", timeout=10000)
    boxes = page.locator("#ms-models input[type=checkbox]")
    checked = [boxes.nth(i).is_checked() for i in range(boxes.count())]
    if checked != [True, True]:
        failures.append(f"{label}: the found models are not all ticked by default: {checked}")
    if "32k" not in page.inner_text("#ms-models"):
        failures.append(f"{label}: the context length is not shown: {page.inner_text('#ms-models')!r}")
    if page.locator("#ms-warn").count():
        failures.append(f"{label}: a private address got the plain-http warning")
    # a public plain-http address shows the warning before saving
    page.fill("#ms-url", "203.0.113.9:8000")
    check_server()
    page.wait_for_selector("#ms-warn", timeout=10000)
    if "plain http" not in page.inner_text("#ms-warn"):
        failures.append(f"{label}: the plain-http warning is {page.inner_text('#ms-warn')!r}")
    # a server that is down
    page.fill("#ms-url", "down.example.org")
    check_server()
    page.wait_for_function("() => /Not reachable/.test(document.querySelector('#ms-probe')?.innerText || '')", timeout=10000)
    # the good one: untick one model, name it, add it
    page.fill("#ms-url", "10.0.0.5:8000"); page.fill("#ms-name", "lab")
    check_server()
    page.wait_for_selector("#ms-probe.good", timeout=10000)
    page.locator("#ms-models input[data-model='llama3:8b']").uncheck()
    if "1 model" not in page.inner_text("#ms-save"):
        failures.append(f"{label}: the Add button does not count the ticked models: {page.inner_text('#ms-save')!r}")
    page.click("#ms-save"); ask("Add server")
    row = page.locator("[data-server-row=lab]")
    row.wait_for(state="visible", timeout=10000)
    save = next((p for p in LM["posts"] if p["op"] == "save"), None)
    if not save or save["models"] != ["qwen/Qwen3-8B"] or save["key"] != KEY or save["name"] != "lab" or save["password"] != PWD:
        failures.append(f"{label}: the save request is {save}")
    if page.locator("#ms-probe").count():
        failures.append(f"{label}: the probe result stays after the server was added")
    on = row.locator("input[data-model='qwen/Qwen3-8B']").is_checked(), row.locator("input[data-model='llama3:8b']").is_checked()
    if on != (True, False):
        failures.append(f"{label}: the new row shows its models {on}, expected (True, False)")
    # a per-model switch, applied once
    row.locator("input[data-model='llama3:8b']").check()
    row.locator("[data-act=server-models]").click(); ask("Apply")
    page.wait_for_function("() => !document.querySelector('[data-act=server-models]')", timeout=10000)
    mod = next((p for p in LM["posts"] if p["op"] == "models"), None)
    if not mod or sorted(mod["models"]) != ["llama3:8b", "qwen/Qwen3-8B"]:
        failures.append(f"{label}: the models request is {mod}")
    # Edit key: never shown, sent once
    row.locator("[data-act=server-key]").click()
    row.locator(".lm-keyin").fill("newkey" + "7654321")
    row.get_by_role("button", name="Save key").click(); ask("Save key")
    page.wait_for_function("() => !document.querySelector('.lm-keyin')", timeout=10000)
    # Remove asks once, then the row is gone
    row.locator("[data-act=server-remove]").click(); ask("Remove")
    page.wait_for_function("() => !document.querySelector('[data-server-row=lab]')", timeout=10000)
    ops = [p["op"] for p in LM["posts"]]
    if len(LM["probes"]) != 1 or any("password" in p or not p.get("url", "").startswith(("localhost", "http://localhost")) for p in LM["probes"]):
        failures.append(f"{label}: a password-free check went to another computer or carried a password: {LM['probes']}")
    others = [p for p in LM["posts"] if p["op"] == "probe"]
    if len(others) != 5 or any(p.get("password") != PWD for p in others):
        failures.append(f"{label}: another computer's check did not go with the password: {others}")
    if ops.count("remove") != 1 or "key" not in ops:
        failures.append(f"{label}: the form sent {ops}")
    everything = "\n".join(LM["gets"]) + page.inner_text("#lm-servers")
    for secret in (KEY, "newkey" + "7654321"):
        if secret in everything:
            failures.append(f"{label}: a key came back from the portal or is on the page")
    # the card scrolls inside; the page does not grow sideways at a phone's width
    page.set_viewport_size({"width": 390, "height": 800})
    page.wait_for_timeout(150)
    if page.evaluate("() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1"):
        failures.append(f"{label}: the servers card makes the page wider than the screen at 390 px")
    page.set_viewport_size({"width": 1280, "height": 900})


def check_browse(page, failures, label):
    """Browse models with the models you run yourself (JON-816): the two entry points, a downloaded model and each saved
    server's models listed next to the providers' with Add / Remove, Download from Hugging Face and Add a model server
    opening the Settings form in a panel (localhost filled in; Check server asks for no password; saving asks for one),
    the filters, an empty state that says what to do, and screenshots at desktop and phone width (OUT/shots-browse)."""
    PWD = "correct horse"
    shots = OUT / "shots-browse"
    shots.mkdir(parents=True, exist_ok=True)
    LM.update(servers=[], result=None, posts=[], gets=[], probes=[], changes=[],
              installed=[{"runtime": "dmr", "id": "hf.co/acme/tiny-GGUF:Q4_K_M", "name": "lm/acme/tiny-GGUF:q4_k_m", "repo": "acme/tiny-GGUF", "quant": "Q4_K_M",
                          "bytes": 800 * 1024 ** 2, "license": "apache-2.0", "tools": "yes", "present": True, "registered": True}])

    def shot(name, at=None):
        if at:
            page.evaluate("(sel) => document.querySelector(sel).scrollIntoView({block: 'start'})", at)
            page.wait_for_timeout(100)
        page.screenshot(path=str(shots / f"{name}.png"), full_page=at is None)

    def ask():
        page.wait_for_selector("#set-confirm[open]", timeout=5000)
        page.fill("#set-confirm-password", PWD)
        page.click("#set-confirm-ok")

    page.set_viewport_size({"width": 1280, "height": 900})
    page.goto(BASE + "/?browse=1#modelbrowser")
    page.wait_for_selector("#modelbrowser:not([hidden]) #mb-own", timeout=20000)
    page.wait_for_selector(".mb-row[data-provider=local]", timeout=10000)
    for sel, text in (("#mb-own-download", "Download from Hugging Face"), ("#mb-own-server", "Add a model server (localhost by default)")):
        if page.locator(sel).count() != 1 or text not in page.inner_text(sel):
            failures.append(f"{label}: the entry point {sel} is missing or says {page.inner_text(sel) if page.locator(sel).count() else None!r}")
    row = page.locator(".mb-row[data-id='lm/acme/tiny-GGUF:q4_k_m']")
    if row.count() != 1 or "Remove" not in row.inner_text() or "free" not in row.inner_text():
        failures.append(f"{label}: the downloaded model is not listed with Remove and its price: {row.inner_text() if row.count() else None!r}")
    if "On this computer" not in page.inner_text("#modelbrowser .mb-provs") or "Model servers" not in page.inner_text("#modelbrowser .mb-provs"):
        failures.append(f"{label}: the filters have no local and server chips")
    shot("1-browse-desktop")
    # Add a model server: localhost is the default, Check server needs no password
    page.click("#mb-own-server")
    page.wait_for_selector("#mb-own-panel #ms-url", timeout=5000)
    if page.input_value("#ms-url") != "localhost:11434":
        failures.append(f"{label}: the address does not default to localhost: {page.input_value('#ms-url')!r}")
    if page.evaluate("document.activeElement && document.activeElement.id") != "ms-url" or not page.evaluate("document.querySelector('#mb-own-panel').contains(document.activeElement)"):
        failures.append(f"{label}: the address field is not focused")
    if "No model servers yet" not in page.inner_text("#mb-own-panel"):
        failures.append(f"{label}: no empty state for the servers: {page.inner_text('#mb-own-panel')[:300]!r}")
    shot("2-add-server-desktop")
    page.click("#mb-own-panel #ms-check")
    page.wait_for_selector("#mb-own-panel #ms-probe.good", timeout=10000)
    if page.locator("#set-confirm[open]").count() or len(LM["probes"]) != 1 or "password" in LM["probes"][0]:
        failures.append(f"{label}: Check server asked for a password: {LM['probes']}")
    shot("3-check-server-desktop")
    page.click("#mb-own-panel #ms-save"); ask()
    page.wait_for_selector(".mb-row[data-id='ms/localhost/qwen/Qwen3-8B']", timeout=10000)
    srow = page.locator(".mb-row[data-id='ms/localhost/qwen/Qwen3-8B']")
    if "In your pickers" not in srow.inner_text() or "Model server" not in srow.inner_text():
        failures.append(f"{label}: a server's model row says {srow.inner_text()!r}")
    save = next((x for x in LM["posts"] if x["op"] == "save"), None)
    if not save or not save.get("password"):
        failures.append(f"{label}: the save did not ask for the password: {save}")
    # Remove / Add on a server's model: the same affordance, one password
    srow.locator("button[data-act=remove]").click(); ask()
    page.wait_for_function("() => document.querySelector(\".mb-row[data-id='ms/localhost/qwen/Qwen3-8B'] button[data-act=add]\")", timeout=10000)
    shot("4-browse-with-server-desktop")
    # Download from Hugging Face: the search is there and focused
    page.click("#mb-own-download")
    page.wait_for_function("() => document.activeElement && document.activeElement.id === 'lm-search' && document.querySelector('#mb-own-panel').contains(document.activeElement)", timeout=5000)
    if not page.evaluate("document.querySelector('#mb-own-panel #lm-find').open"):
        failures.append(f"{label}: Download from Hugging Face did not open the search")
    shot("5-download-desktop")
    # removing the downloaded model asks for the password; then the filter's empty state says what to do
    row.locator("button[data-act=remove]").click(); ask()
    page.wait_for_function("() => !document.querySelector(\".mb-row[data-provider=local]\")", timeout=10000)
    page.click("#mb-own-close")
    page.click("[data-prov=local]")
    if "Download from Hugging Face" not in page.inner_text("#mb-list"):
        failures.append(f"{label}: the empty local list does not say what to do: {page.inner_text('#mb-list')!r}")
    if not any(c.get("password") and c.get("action") == "local-remove" for c in LM["changes"]):
        failures.append(f"{label}: removing a local model did not ask for the password: {LM['changes']}")
    page.click("[data-prov=all]")
    # the link from the Code picker: #modelbrowser/add opens the panel with both ways
    page.goto(BASE + "/?browse=2#modelbrowser/add")
    page.wait_for_selector("#mb-own-panel #lm-box #ms-url", timeout=10000)
    if page.locator("#mb-own-panel #lm-find").count() != 1:
        failures.append(f"{label}: the add panel has no download part")
    # a phone: nothing wider than the screen, the entry points and the form readable
    page.set_viewport_size({"width": 390, "height": 800})
    page.wait_for_timeout(200)
    shot("6-add-panel-phone", "#mb-own-panel")
    shot("6b-add-panel-phone-form", "#mb-own-panel #ms-url")
    if page.evaluate("() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1"):
        failures.append(f"{label}: Browse models is wider than the screen at 390 px")
    page.click("#mb-own-close")
    shot("7-browse-phone")
    if page.evaluate("() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1"):
        failures.append(f"{label}: Browse models is wider than the screen at 390 px (panel closed)")
    page.set_viewport_size({"width": 1280, "height": 900})


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
                    check_services(page, failures, label)
                    check_servers(page, failures, label)
                    check_browse(page, failures, label)
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
