"""The model browser (Settings › Models & providers › Browse models, and the Code page's model picker's More models…):
the models each provider could add — Bedrock's, OpenRouter's and Experiential Labs' — with their prices, context, tool
use, image input and how each works as Claude Code's model, which are in the pickers now, and the change of setting
that adds or removes one. Nothing here holds a key of AWS or Experiential Labs:

- Bedrock and Experiential Labs: what ./stack read (lib/model_browser.sh) into STATUS_DIR/model-browser/ — Bedrock's
  ListFoundationModels and ListInferenceProfiles with LiteLLM's own AWS sign-in; the ids the Experiential Labs key may
  call and the gateway's public catalog's pages. Read field by field; a list older than an hour is read again by the
  update helper when this page asks (REQUEST_DIR/models-wanted: no password — a free, read-only listing, at most every
  10 minutes).
- OpenRouter: its public list (GET https://openrouter.ai/api/v1/models, no key: nothing about you is sent), read here
  and kept an hour — while its key is in .env, or when you ask to browse it without one.

A change goes the way of every setting (/api/settings/apply: the password, the update helper, ./stack config apply):
EXPLABS_MODELS, OPENROUTER_MODELS and BEDROCK_MODELS, whose next values plan() works out. Try it (try_model) is one
short request through LiteLLM on the setup key, its cost said first.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

import httpx

from . import hostfiles

DIR = "model-browser"
WANTED = "models-wanted"
MAX_AGE_S = 3600                     # a list older than this is read again (when this page is open)
OR_API = "https://openrouter.ai/api/v1/models"
OR_TIMEOUT = httpx.Timeout(20.0, connect=5.0)
OR_MAX_BYTES = 8 * 1024 * 1024
MAX_FILE = 8 * 1024 * 1024
MAX_PAGES = 4
MAX_ROWS = 2000
COMPAT = ("works", "chat-only", "fails", "untested")
XL_DEFAULT = "qwen3.8-27b"           # lib/explabs.sh EXPLABS_DEFAULT_MODELS: what a blank EXPLABS_MODELS means

OR_ID = re.compile(r"[A-Za-z0-9~][A-Za-z0-9._:~-]*/[A-Za-z0-9._/:~-]+")
XL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
BR_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
MODEL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}")
SETTING = {"bedrock": "BEDROCK_MODELS", "openrouter": "OPENROUTER_MODELS", "explabs": "EXPLABS_MODELS"}
PROVIDER = {"bedrock": "Bedrock", "openrouter": "OpenRouter", "explabs": "Experiential Labs"}

_or_cache: dict = {}


def _text(v, n: int = 80) -> str:
    return "".join(c for c in v if c.isprintable())[:n].strip() if isinstance(v, str) else ""


def _num(v) -> float | None:
    """A price or a count as the provider sends it (a number, or a decimal in a string): None for anything else."""
    if isinstance(v, bool):
        return None
    if isinstance(v, str):
        if not re.fullmatch(r"[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]{1,2})?", v.strip()):
            return None
        v = float(v)
    return float(v) if isinstance(v, (int, float)) and v == v and 0 <= v < 1e9 else None


def _whole(v) -> int | None:
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 < v < 100_000_000 else None


def _nano(v) -> float | None:
    """A gateway price in nano-USD per million tokens (0 allowed, up to ~1e15: Opus output is 20e9) → float, else None."""
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v < 1e15 else None


def _per_m(v) -> float | None:
    """A price per token → per million tokens (plain, no float noise)."""
    n = _num(v)
    return None if n is None else round(n * 1_000_000, 6)


def _read(path: Path, cap: int = MAX_FILE) -> dict:
    return hostfiles.read_json(path, cap)


def _age(at, now: float) -> float | None:
    return now - at if isinstance(at, (int, float)) and not isinstance(at, bool) and at > 0 else None


# --- catalog/code-models.tsv: how a model fares as Claude Code's (first matching row wins; lib/code_models.sh) ---

def compat_rules(catalog_dir: Path) -> list[tuple[str, str, str]]:
    try:
        text = (catalog_dir / "code-models.tsv").read_text(encoding="utf-8")
    except OSError:
        return []
    out = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        c = line.split("\t")
        if len(c) >= 2 and c[0]:
            out.append((c[0], c[1] if c[1] in COMPAT else "untested", _text(c[3], 300) if len(c) >= 4 else ""))
    return out


def compat_of(rules, stack_id: str, tools: bool | None, provider: str) -> tuple[str, str]:
    """(status, note) as lib/code_models.sh says it: a row of catalog/code-models.tsv for the id (or a prefix ending in
    *), else what the provider lists of tool use."""
    for pat, status, note in rules:
        if pat == stack_id or (pat.endswith("*") and stack_id.startswith(pat[:-1])):
            return status, note
    if tools is False:
        return "chat-only", f"{provider} lists no tool use for it: Claude Code could only chat, not read, edit or run anything."
    if tools is True:
        return "untested", f"Not checked with Claude Code here; {provider} lists tool use for it."
    return "untested", "Not checked with Claude Code here: tool use, thinking and prompt caching may not work."


# --- the change of setting that adds or removes one model ---

def _terms(value: str) -> list[str]:
    return [t.strip() for t in (value or "").split(",") if t.strip()]


def plan(provider: str, value: str, model: str, add: bool, *, free: bool | None = None, last: bool = False) -> tuple[str, str] | None:
    """(KEY, the next value) that adds MODEL (the provider's own id: no or/, xl/ or br/) to what VALUE (the setting now)
    enables, or takes it out — None when there is nothing to change. OpenRouter's value keeps its words: all, free, paid
    and a list, plus "-<id>" for one left out of them (lib/openrouter.sh or_select); Experiential Labs' a list (blank:
    qwen3.8-27b, so its last model is never removed here: removing the key does that); Bedrock's a list of the models
    added beyond the catalog."""
    key = SETTING.get(provider)
    if key is None:
        return None
    t = _terms(value)
    if provider == "openrouter":
        t = [x[3:] if x.startswith("or/") else x for x in t] or ["all"]
        words = {x for x in t if x in ("all", "free", "paid")}
        covered = "all" in words or (free is True and "free" in words) or (free is False and "paid" in words)
        if add:
            if f"-{model}" in t:
                t = [x for x in t if x != f"-{model}"]
            elif model in t or covered:
                return None
            else:
                t.append(model)
        else:
            if model not in t and not covered:
                return None
            t = [x for x in t if x != model]
            if covered:
                t.append(f"-{model}")
            if not [x for x in t if not x.startswith("-")]:
                t = [x for x in t if x.startswith("-")] or [f"-{model}"]   # (nothing left: never blank, which is all)
        nxt = ",".join(t)
        return (key, "" if nxt == "all" else nxt) if nxt != (value or "") else None
    if provider == "explabs":
        t = [x[3:] if x.startswith("xl/") else x for x in t] or [XL_DEFAULT]
        if add:
            if model in t:
                return None
            t.append(model)
        else:
            if model not in t or (last or len(t) == 1):
                return None
            t = [x for x in t if x != model]
        return key, ",".join(t)
    # bedrock
    t = [x[3:] if x.startswith("br/") else x for x in t]
    if add:
        if model in t:
            return None
        t.append(model)
    else:
        if model not in t:
            return None
        t = [x for x in t if x != model]
    return key, ",".join(t)


# --- each provider's list, as ./stack read it (or OpenRouter's, read here) ---

def _row(provider, source_id, stack_id, name, vendor, prices, context, tools, images, free=None, note="", lifecycle=""):
    pin = prices.get("in") if prices else None
    pout = prices.get("out") if prices else None
    if free is None:
        free = pin is not None and pout is not None and pin == 0 and pout == 0
    return {"provider": provider, "id": stack_id, "source_id": source_id, "name": name or source_id, "vendor": vendor or "",
            "free": bool(free), "in": pin, "out": pout, "context": context, "tools": tools, "images": images,
            "lifecycle": lifecycle, "note": note}


def openrouter_rows(doc: dict) -> list[dict]:
    """GET /api/v1/models (OpenRouter's public list) → rows: text-out models with a known price (OpenRouter's routers,
    priced -1, and the :batch variants, which only its batch API runs, left out — lib/openrouter.sh or_classify), their
    context, tool use (supported_parameters names tools) and image input (architecture.input_modalities)."""
    out = []
    for m in (doc.get("data") if isinstance(doc, dict) else None) or []:
        if not isinstance(m, dict) or not isinstance(m.get("id"), str) or not OR_ID.fullmatch(m["id"]) or len(m["id"]) > 124:
            continue
        mid = m["id"]
        arch = m.get("architecture") if isinstance(m.get("architecture"), dict) else {}
        outs = arch.get("output_modalities") if isinstance(arch.get("output_modalities"), list) else ["text"]
        ins = arch.get("input_modalities") if isinstance(arch.get("input_modalities"), list) else []
        if mid.endswith(":batch") or outs != ["text"]:
            continue
        pr = m.get("pricing") if isinstance(m.get("pricing"), dict) else {}
        pin, pout = _per_m(pr.get("prompt")), _per_m(pr.get("completion"))
        if pin is None or pout is None:
            continue
        name = _text(m.get("name"))
        vendor = name.split(": ", 1)[0] if ": " in name else mid.split("/", 1)[0].lstrip("~")
        params = m.get("supported_parameters")
        tools = ("tools" in params) if isinstance(params, list) else None
        out.append(_row("openrouter", mid, f"or/{mid}", name.split(": ", 1)[-1] or mid, vendor,
                        {"in": pin, "out": pout}, _whole(m.get("context_length")), tools,
                        ("image" in ins) if ins else None, note="alias" if mid.startswith("~") else ""))
        if len(out) >= MAX_ROWS:
            break
    return out


def explabs_rows(status_dir: Path) -> tuple[list[dict], dict]:
    """The ids the key may call (model-browser/explabs-ids.json), each with what the gateway's public catalog says of
    its model (model-browser/explabs-catalog-N.json; a "<slug>:free" alias: its slug's, at $0): the price of the
    deployment the gateway serves it on (its default providers' first active one, else the first active one), its
    context, tool use and image input. -> (rows, {at, error})"""
    d = status_dir / DIR
    ids_doc = _read(d / "explabs-ids.json", 512 * 1024)
    ids = [x for x in ids_doc.get("ids") or [] if isinstance(x, str) and XL_ID.fullmatch(x)][:MAX_ROWS]
    cat = {}
    for n in range(1, MAX_PAGES + 1):
        page = _read(d / f"explabs-catalog-{n}.json")
        for e in page.get("models") or []:
            m = e.get("model") if isinstance(e, dict) and isinstance(e.get("model"), dict) else None
            if m and isinstance(m.get("slug"), str) and XL_ID.fullmatch(m["slug"]) and m["slug"] not in cat:
                cat[m["slug"]] = e
    out = []
    for i in ids:
        slug = i[: -len(":free")] if i.endswith(":free") else i
        e = cat.get(slug) or {}
        m = e.get("model") if isinstance(e.get("model"), dict) else {}
        provs = [p for p in e.get("providers") or [] if isinstance(p, dict) and p.get("status") == "active"]
        default = [x for x in e.get("default_provider_ids") or [] if isinstance(x, str)]
        lane = next((p for d_ in default for p in provs if p.get("id") == d_), None) or next(iter(provs), None) or {}
        caps = lane.get("capabilities") if isinstance(lane.get("capabilities"), dict) else {}
        pin = _nano(lane.get("input_nano_usd_per_million"))
        pout = _nano(lane.get("output_nano_usd_per_million"))
        prices = {"in": round(pin / 1e9, 6), "out": round(pout / 1e9, 6)} if pin is not None and pout is not None else None
        free = i.endswith(":free") or (prices is not None and prices["in"] == 0 and prices["out"] == 0)
        if i.endswith(":free"):
            prices = {"in": 0.0, "out": 0.0}
        sp = m.get("supported_params") if isinstance(m.get("supported_params"), dict) else {}
        tools = caps.get("supports_tools") if isinstance(caps.get("supports_tools"), bool) else (sp.get("tools") if isinstance(sp.get("tools"), bool) else None)
        ins = m.get("input_modalities") if isinstance(m.get("input_modalities"), list) else []
        outs = m.get("output_modalities") if isinstance(m.get("output_modalities"), list) else ["text"]
        if outs and "text" not in outs:
            continue   # (an image or audio model: not a chat model of the pickers)
        name = _text(m.get("display_name")) or i
        out.append(_row("explabs", i, f"xl/{i}", f"{name} (free)" if i.endswith(":free") and "free" not in name.lower() else name,
                        _text(m.get("maker"), 40), prices, _whole(m.get("context_window")), tools,
                        ("image" in ins) if ins else None, free=free,
                        note="" if e else "the gateway's public catalog has no details for it"))
    meta = {"at": ids_doc.get("at") if isinstance(ids_doc.get("at"), int) else None,
            "error": _text(ids_doc.get("error"), 300) or None}
    return out, meta


def bedrock_rows(status_dir: Path) -> tuple[list[dict], dict]:
    """Bedrock's text models in the region (model-browser/bedrock.json: ListFoundationModels and its inference profiles,
    with LiteLLM's own prices where it knows them). -> (rows, {at, status, why, region})"""
    doc = _read(status_dir / DIR / "bedrock.json", 4 * 1024 * 1024)
    out = []
    for m in doc.get("models") or []:
        if not isinstance(m, dict) or not isinstance(m.get("id"), str) or not BR_ID.fullmatch(m["id"]):
            continue
        pr = m.get("prices") if isinstance(m.get("prices"), dict) else None
        prices = {"in": _num(pr.get("in")), "out": _num(pr.get("out"))} if pr else None
        if prices and (prices["in"] is None or prices["out"] is None):
            prices = None
        out.append(_row("bedrock", m["id"], m["id"], _text(m.get("name")), _text(m.get("vendor"), 40), prices,
                        _whole(m.get("context")), m.get("tools") if isinstance(m.get("tools"), bool) else None,
                        m.get("images") if isinstance(m.get("images"), bool) else None, free=False,
                        lifecycle="legacy" if m.get("lifecycle") == "LEGACY" else ""))
        if len(out) >= MAX_ROWS:
            break
    status = doc.get("status") if doc.get("status") in ("ok", "denied", "error") else None
    return out, {"at": doc.get("at") if isinstance(doc.get("at"), int) else None, "status": status,
                 "why": _text(doc.get("why"), 300), "region": _text(doc.get("region"), 30)}


async def openrouter_list(client: httpx.AsyncClient, now: float | None = None, refresh: bool = False) -> tuple[list[dict], dict]:
    """OpenRouter's public list (no key), kept MAX_AGE_S; refresh reads it again when the copy kept is a minute old.
    -> (rows, {at, error})"""
    now = time.time() if now is None else now
    hit = _or_cache.get("v")
    if hit and now - hit[0] < MAX_AGE_S and not (refresh and now - hit[0] > 60):
        return hit[1], {"at": int(hit[0]), "error": None}
    try:
        r = await client.get(OR_API, timeout=OR_TIMEOUT, headers={"Accept": "application/json"})
        if r.status_code != 200:
            raise ValueError(f"openrouter.ai answered HTTP {r.status_code}")
        if len(r.content) > OR_MAX_BYTES:
            raise ValueError("openrouter.ai sent too much")
        rows = openrouter_rows(r.json())
    except (httpx.HTTPError, ValueError) as e:
        if hit:
            return hit[1], {"at": int(hit[0]), "error": f"kept from before: {_text(str(e), 120) or type(e).__name__}"}
        return [], {"at": None, "error": _text(str(e), 160) if isinstance(e, ValueError) else f"openrouter.ai did not answer ({type(e).__name__})"}
    _or_cache["v"] = (now, rows)
    return rows, {"at": int(now), "error": None}


# --- the stack's own Bedrock catalog: its models are built in (setup checks which the key can use) ---

def catalog_bedrock(catalog_dir: Path, litellm_dir: Path, region: str) -> dict:
    """{the Bedrock id a catalog chat model calls (catalog/models.tsv, {region} filled in): (its name, enabled or why
    not — the last model check, litellm/probe-results.tsv)}"""
    try:
        rows = (catalog_dir / "models.tsv").read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    probe = {}
    try:
        for line in (litellm_dir / "probe-results.tsv").read_text(encoding="utf-8").splitlines():
            c = line.split("\t")
            if len(c) >= 4 and not line.startswith("#"):
                probe[c[0]] = (c[2] == "ENABLED", _text(c[3], 200))
    except OSError:
        pass
    out = {}
    for line in rows:
        c = line.split("\t")
        if line.startswith("#") or len(c) < 3 or c[1] != "chat":
            continue
        bid = re.sub(r"^bedrock/(invoke/|converse/)?", "", c[2]).replace("{region}", region or "")
        on, why = probe.get(c[0], (True, ""))
        out[bid] = {"name": c[0], "enabled": on, "why": why}
    return out


def browse(status_dir: Path, catalog_dir: Path, litellm_dir: Path, values: dict, keys_on: dict, or_rows, or_meta,
           code_rows: list[dict], now: float | None = None) -> dict:
    """The browser's whole answer: per provider its state (on: a key; at: when its list was read; stale: older than an
    hour; why: what went wrong) and its rows, each with how it works as Claude Code's model, whether the pickers have
    it now (enabled), whether the setting names it (chosen: added, waiting for the change to apply or for the list),
    and what can be done with it (add, remove, or none and why). values: the settings' values now; keys_on: which
    provider has a key; code_rows: litellm/code-models.tsv (code.read_code_models), what the pickers list."""
    now = time.time() if now is None else now
    rules = compat_rules(catalog_dir)
    picked = {r["id"] for r in code_rows}
    out = {}
    br, br_meta = bedrock_rows(status_dir)
    cat = catalog_bedrock(catalog_dir, litellm_dir, br_meta.get("region") or "")
    xl, xl_meta = explabs_rows(status_dir)
    lists = {"bedrock": (br, br_meta), "openrouter": (or_rows, or_meta), "explabs": (xl, xl_meta)}
    for prov, (rows, meta) in lists.items():
        value = values.get(SETTING[prov], "")
        terms = {t.split("/", 1)[1] if t.startswith(("or/", "xl/", "br/")) else t for t in _terms(value)}
        if prov == "explabs" and not terms:
            terms = {XL_DEFAULT}
        shown = []
        for r in rows:
            r = dict(r)
            builtin = prov == "bedrock" and r["source_id"] in cat
            if builtin:
                c = cat[r["source_id"]]
                r["id"] = c["name"]
                r["builtin"] = True
            else:
                r["builtin"] = False
            r["compat"], r["compat_note"] = compat_of(rules, r["id"], r["tools"], PROVIDER[prov])
            r["enabled"] = r["id"] in picked
            if prov == "openrouter":
                words = {t for t in terms if t in ("all", "free", "paid")} or ({"all"} if not terms else set())
                r["chosen"] = (r["source_id"] in terms or "all" in words or (r["free"] and "free" in words) or (not r["free"] and "paid" in words)) \
                    and f"-{r['source_id']}" not in terms
            else:
                r["chosen"] = r["source_id"] in terms
            if not keys_on.get(prov):
                r["can"], r["why"] = "none", f"needs {'an' if PROVIDER[prov][0] in 'AEIOU' else 'a'} {PROVIDER[prov]} key"
            elif builtin:
                c = cat[r["source_id"]]
                r["can"], r["why"] = "none", ("built in: in every picker" if c["enabled"] else f"built in, but not available to your AWS key: {c['why'] or 'see Settings › Bedrock'}")
                r["enabled"] = r["enabled"] or c["enabled"]
            elif r["chosen"]:
                lone = prov == "explabs" and len(terms) <= 1
                r["can"], r["why"] = ("none", "the only one: blank means qwen3.8-27b — remove the key to turn it off") if lone else ("remove", "")
            else:
                r["can"], r["why"] = "add", ""
            shown.append(r)
        at = meta.get("at")
        age = _age(at, now)
        out[prov] = {"on": bool(keys_on.get(prov)), "key": SETTING[prov], "value": value, "at": at,
                     "stale": age is None or age > MAX_AGE_S, "error": meta.get("error") or (meta.get("why") if meta.get("status") in ("denied", "error") else None),
                     "status": meta.get("status"), "rows": shown,
                     **({"region": meta.get("region")} if prov == "bedrock" else {})}
    # Bedrock without a list read (or one the key may not read): the catalog's models, so the page still says what it has
    if not out["bedrock"]["rows"]:
        for bid, c in cat.items():
            r = _row("bedrock", bid, c["name"], c["name"], "", None, None, None, None, free=False)
            r.update(builtin=True, enabled=c["enabled"] or c["name"] in picked, chosen=True, can="none",
                     why="built in" if c["enabled"] else f"not available to your AWS key: {c['why']}")
            r["compat"], r["compat_note"] = compat_of(rules, c["name"], None, "Bedrock")
            out["bedrock"]["rows"].append(r)
    return out


# --- Try it: one short request, its cost said first ---

TRY_PROMPT = "Reply with exactly: OK"
TRY_IN_TOKENS = 30            # what the prompt is, at most, with the chat template around it
TRY_MAX_TOKENS = 16
EXPENSIVE_USD = 0.001         # a try estimated above this — or a model priced at $10+ per million output tokens, or an
EXPENSIVE_OUT_PER_M = 10.0    # Opus — runs only after an explicit "yes, on this expensive model"


def try_estimate(row: dict) -> dict:
    """What one Try costs at most on ROW's prices (USD; None when its price is unknown), and whether it needs the
    explicit confirmation of an expensive model."""
    pin, pout = row.get("in"), row.get("out")
    est = None if pin is None or pout is None else round((TRY_IN_TOKENS * pin + TRY_MAX_TOKENS * pout) / 1_000_000, 8)
    expensive = est is None or est > EXPENSIVE_USD or (pout or 0) >= EXPENSIVE_OUT_PER_M or "opus" in str(row.get("id", "")).lower()
    return {"usd": est, "expensive": bool(expensive) and not row.get("free"), "max_tokens": TRY_MAX_TOKENS}


async def try_model(client: httpx.AsyncClient, litellm_url: str, key: str, model: str) -> dict:
    """One request on MODEL through LiteLLM with KEY (the setup key: Home's "Setup and tests" counts it), max_tokens
    TRY_MAX_TOKENS: {ok, text, cost (what LiteLLM booked, USD), status, error}."""
    try:
        r = await client.post(f"{litellm_url}/v1/chat/completions", timeout=httpx.Timeout(60.0, connect=5.0),
                              headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                              content=json.dumps({"model": model, "max_tokens": TRY_MAX_TOKENS, "messages": [{"role": "user", "content": TRY_PROMPT}]}))
    except httpx.HTTPError as e:
        return {"ok": False, "status": 0, "text": "", "cost": None, "error": f"the model gateway did not answer ({type(e).__name__})"}
    cost = _num(r.headers.get("x-litellm-response-cost"))
    try:
        d = r.json()
    except ValueError:
        d = {}
    if r.status_code != 200:
        err = d.get("error") if isinstance(d, dict) else None
        msg = err.get("message") if isinstance(err, dict) else err if isinstance(err, str) else ""
        return {"ok": False, "status": r.status_code, "text": "", "cost": cost, "error": _text(msg, 400) or f"HTTP {r.status_code}"}
    ch = (d.get("choices") or [{}])[0] if isinstance(d.get("choices"), list) and d.get("choices") else {}
    msg = ch.get("message") if isinstance(ch, dict) and isinstance(ch.get("message"), dict) else {}
    return {"ok": True, "status": 200, "text": _text(msg.get("content"), 200), "cost": cost, "error": None}
