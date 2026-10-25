"""Usage by model, for Home while OpenRouter or Experiential Labs is on: the Equivalent cost view, and OpenRouter's
usage and failures.

Two cost views. Actual: what is charged — Bedrock at its on-demand list prices, paid models at what they cost, free
models $0 (what LiteLLM records, and what budgets count). Equivalent: what the same usage would have cost with no free
tiers — free OpenRouter and Experiential Labs models priced at their paid versions; everything else is already at its
real price, the same in both views:
  - a free OpenRouter model ("or/…:free"): at its paid variant (the same id without ":free", from
    litellm/openrouter-models.tsv, which lists every eligible model, selected or not);
  - an Experiential Labs free tier ("xl/<slug>:free", or a model listed at $0): at its model's prices from the
    gateway's details ./stack caches (litellm/explabs-models.json "paid", portal/explabs.py);
  - a call on a priced xl/… model the gateway reported at $0 and not on your own provider key (usage.cost 0 with
    usage.is_byok false): a promotion, priced at the model's list price. One on your own provider key (is_byok true:
    that provider bills it) stays $0 in both views and is counted as such; so is one whose usage does not say (a
    streamed answer loses is_byok on its way through LiteLLM; Claude Code always streams). LiteLLM's daily rows cannot
    tell these apart, so for each day a model's answered calls were all booked $0, up to XL_SAMPLE of them are read
    from the spend log (its metadata.usage_object is the gateway's usage), and that day's usage is split in their
    proportion. (On a day with paid calls too, its $0 calls stay $0.)
A free model without a paid version stays $0 and is listed as such.

LiteLLM 1.105.0, with the master key (answers cached for a minute — a past day's $0 calls for as long as the portal
runs: they do not change; Home refreshes every 30 seconds):
  GET /user/daily/activity/aggregated?start_date&end_date   per UTC day: breakdown.model_groups["or/…" and "xl/…"]
      .metrics (api_requests, prompt_tokens, completion_tokens, cache_read/creation_input_tokens, spend) and its
      api_key_breakdown by hashed key (sha256 of the key). Budget periods start at UTC midnight, so days are exact.
      The daily rows do not say which model answered a router (or/openrouter/free): it counts as $0, no paid version.
  GET /spend/logs/v2?status_filter=failure (last 24 hours)   metadata.error_information of each failed request
      (OpenRouter only)
  GET /spend/logs/v2?model_group=xl/…&max_spend=0 (one UTC day)   metadata.usage_object.is_byok / .cost
Nothing here runs while both are off; a LiteLLM error leaves Actual as it is and says why.
"""

from __future__ import annotations

import asyncio
import calendar
import hashlib
import re
import time
import weakref
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import httpx

from . import explabs

TIMEOUT = httpx.Timeout(6.0, connect=2.0)
CACHE_SECONDS = 60
FAILURE_HOURS = 24
FAILURE_PAGE = 300   # failed requests read per refresh (the newest); more → "more": true
TOP_MODELS = 5
XL_SAMPLE = 50       # $0 calls read per Experiential Labs model and day to tell a promotion from your own provider key
XL_PARALLEL = 4      # of those reads at a time
XL_DAYS_KEPT = 400   # (model, day) answers remembered
_cache: dict = {}    # name -> (monotonic time, value, what it was asked for)
_xl_days: dict = {}  # (LiteLLM url, model, day) -> (monotonic time, split or None): a past day's for good
_inflight: weakref.WeakKeyDictionary = weakref.WeakKeyDictionary()   # event loop -> {name: (ask, task)}


async def _once(name: str, ask, fetch):
    """FETCH() once for every caller asking the same at the same time (several open Home tabs): they share one
    request and its answer, an error or a slow LiteLLM included. Nothing outlives the request but _cache."""
    running = _inflight.setdefault(asyncio.get_running_loop(), {})
    cur = running.get(name)
    if cur is not None and cur[0] == ask:
        return await asyncio.shield(cur[1])
    task = asyncio.ensure_future(fetch())
    running[name] = (ask, task)
    try:
        return await asyncio.shield(task)   # a caller that goes away does not cancel the others' request
    finally:
        if running.get(name, (None, None))[1] is task:
            del running[name]


def _cached(name: str, now: float, ask):
    hit = _cache.get(name)
    return hit[1] if hit and hit[2] == ask and now - hit[0] < CACHE_SECONDS else None


def _f(v: str) -> float | None:
    try:
        return float(v) if v not in ("", "-") else None
    except ValueError:
        return None


def read_catalog(litellm_dir: Path) -> dict:
    """litellm/openrouter-models.tsv (id name context prompt completion cache_read cache_write tier created)
    → {id: {name, in, out, cache_read, cache_write, free}}; {} without a cache."""
    out = {}
    try:
        text = (litellm_dir / "openrouter-models.tsv").read_text(encoding="utf-8")
    except (OSError, ValueError):   # unreadable or not UTF-8: no catalog, every free model $0
        return out
    for line in text.splitlines():
        f = line.rstrip("\r").split("\t")
        if line.startswith("#") or len(f) < 8 or not f[0]:
            continue
        out[f[0]] = {"name": f[1] or f[0], "in": _f(f[3]), "out": _f(f[4]), "cache_read": _f(f[5]),
                     "cache_write": _f(f[6]), "free": f[7] == "free"}
    return out


def is_free(model_id: str, cat: dict) -> bool:
    row = cat.get(model_id)
    return row["free"] if row else model_id.endswith(":free")


def xl_prices(litellm_dir: Path) -> dict | None:
    """The chosen Experiential Labs models → {slug (no "xl/"): {"free": bool, "paid": prices or None}}; None while it is
    off. paid: what Equivalent puts on its free usage — a free tier's are its model's, a priced model's its own."""
    data = explabs.read(litellm_dir)
    if data is None:
        return None
    return {m["id"][3:]: {"free": m["free"] or m["id"].endswith(":free"), "paid": m["paid"]} for m in data["models"]}


def paid_variant(model_id: str, cat: dict) -> dict | None:
    """Prices of the paid version of a free model ("x/y:free" → "x/y"), or None when there is none."""
    if not model_id.endswith(":free"):
        return None
    row = cat.get(model_id[: -len(":free")])
    return row if row and not row["free"] and (row["in"] or row["out"]) else None


def priced(m: dict, p: dict) -> float:
    """USD for metrics M at prices P (per token). prompt_tokens include cache reads/writes (LiteLLM's usage)."""
    pin, pout = p.get("in") or 0.0, p.get("out") or 0.0
    cr, cw = m["cache_read"], m["cache_write"]
    rd = pin if p.get("cache_read") is None else p["cache_read"]
    wr = pin if p.get("cache_write") is None else p["cache_write"]
    return max(m["tokens_in"] - cr - cw, 0) * pin + cr * rd + cw * wr + m["tokens_out"] * pout


# --- budget periods ---

def _months_back(d: datetime, n: int) -> datetime:
    y, mo = divmod(d.month - 1 - n, 12)
    year, month = d.year + y, mo + 1
    return d.replace(year=year, month=month, day=min(d.day, calendar.monthrange(year, month)[1]))


def period_start(reset_at: str | None, duration: str | None) -> date | None:
    """First UTC day of a key's current budget period: budget_reset_at minus budget_duration, the way LiteLLM
    1.105.0 schedules resets ("30d" and "Nmo" reset on the 1st of a month, "7d" on Mondays, other "Nd" every N
    days, all at 00:00 UTC). None when either is missing or not understood (it is on Actual's path: never raises)."""
    if not reset_at or not duration:
        return None
    m = re.fullmatch(r"\s*(\d+)\s*(mo|[smhdw]?)\s*", duration)
    if not m:
        return None
    try:
        reset = datetime.fromisoformat(reset_at.replace("Z", "+00:00"))
        if reset.tzinfo is None:   # LiteLLM writes UTC
            reset = reset.replace(tzinfo=timezone.utc)
        n, unit = int(m.group(1)), m.group(2) or "s"
        if unit == "w":
            n, unit = n * 7, "d"
        if unit == "mo" or (unit == "d" and n == 30):
            start = _months_back(reset, n if unit == "mo" else 1)
        else:
            start = reset - timedelta(**{{"d": "days", "h": "hours", "m": "minutes", "s": "seconds"}[unit]: n})
        return start.astimezone(timezone.utc).date()
    except (ValueError, OverflowError):   # a date LiteLLM cannot mean, or a duration of a million years
        return None


def key_hash(key: str) -> str:
    """How LiteLLM stores a virtual key (hash_token): sha256 hex."""
    return hashlib.sha256(key.encode()).hexdigest()


# --- LiteLLM ---

def _int(v) -> int:
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0 else 0


def _metrics(raw) -> dict:
    """Answered requests and their tokens. LiteLLM also books an estimate of each failed request's prompt tokens,
    so a burst of 429s would inflate the input side (and Equivalent): it is scaled to the answered share."""
    raw = raw if isinstance(raw, dict) else {}
    spend = raw.get("spend")
    api = _int(raw.get("api_requests"))
    failed = min(_int(raw.get("failed_requests")), api)
    share = (api - failed) / api if failed else 1.0

    def scaled(field):   # rounded half up, like ./stack's awk
        return int(_int(raw.get(field)) * share + 0.5)

    return {"requests": api - failed, "failed": failed,
            "tokens_in": scaled("prompt_tokens"), "tokens_out": _int(raw.get("completion_tokens")),
            "cache_read": scaled("cache_read_input_tokens"), "cache_write": scaled("cache_creation_input_tokens"),
            "spend": float(spend) if isinstance(spend, (int, float)) and not isinstance(spend, bool) else 0.0}


def parse_activity(body) -> list[dict]:
    """The or/… and xl/… model groups of /user/daily/activity/aggregated: [{date, src, model, m: metrics, keys: {hash:
    metrics}}]. src is "or" or "xl"; model the id without that prefix ("google/gemma-4-31b-it:free")."""
    rows = []
    days = body.get("results") if isinstance(body, dict) else None
    for day in days if isinstance(days, list) else []:
        if not isinstance(day, dict) or not isinstance(day.get("date"), str):
            continue
        bd = day.get("breakdown") if isinstance(day.get("breakdown"), dict) else {}
        groups = bd.get("model_groups")
        prefixes = (("or/", "or"), ("xl/", "xl"))
        if not isinstance(groups, dict) or not groups:   # no group breakdown: the deployment names ("openrouter/…";
            # an xl/… model's, "openai/<id>", cannot be told from another provider's)
            groups, prefixes = bd.get("models") if isinstance(bd.get("models"), dict) else {}, (("openrouter/", "or"),)
        for name, g in groups.items():
            prefix, src = next(((p, v) for p, v in prefixes if isinstance(name, str) and name.startswith(p)), (None, None))
            if prefix is None or not isinstance(g, dict):
                continue
            keys = g.get("api_key_breakdown") if isinstance(g.get("api_key_breakdown"), dict) else {}
            rows.append({"date": day["date"][:10], "src": src, "model": name[len(prefix):], "m": _metrics(g.get("metrics")),
                         "keys": {h: _metrics(k.get("metrics") if isinstance(k, dict) else None)
                                  for h, k in keys.items() if isinstance(h, str)}})
    return rows


async def _get(client: httpx.AsyncClient, url: str, master: str, params: dict) -> tuple[object, str | None]:
    try:
        r = await client.get(url, params=params, headers={"Authorization": f"Bearer {master}"}, timeout=TIMEOUT)
    except httpx.HTTPError as e:
        return None, f"LiteLLM did not answer ({type(e).__name__})"
    if r.status_code != 200:
        return None, f"LiteLLM answered HTTP {r.status_code}"
    try:
        return r.json(), None
    except ValueError:
        return None, "LiteLLM sent something that is not JSON"


async def activity(client: httpx.AsyncClient, litellm_url: str, master: str, start: date, end: date,
                   now: float | None = None) -> tuple[list[dict] | None, str | None]:
    now = time.monotonic() if now is None else now
    ask = (litellm_url, start, end)
    rows = _cached("activity", now, ask)
    if rows is not None:
        return rows, None

    async def fetch():
        body, err = await _get(client, f"{litellm_url}/user/daily/activity/aggregated", master,
                               {"start_date": start.isoformat(), "end_date": end.isoformat()})
        if err:
            return None, err   # not cached: asked again on the next refresh
        got = parse_activity(body)
        _cache["activity"] = (now, got, ask)
        return got, None

    return await _once("activity", ask, fetch)


# --- Experiential Labs: $0 calls on a priced model ---

def zero_days(rows: list[dict], xl: dict) -> list[tuple[str, str]]:
    """(model, day) of every day a priced xl/… model (one with list prices) answered calls that were all booked $0."""
    out = set()
    for r in rows:
        x = xl.get(r["model"]) if r["src"] == "xl" else None
        if x and not x["free"] and x["paid"] and r["m"]["requests"] and r["m"]["spend"] == 0:
            out.add((r["model"], r["date"]))
    return sorted(out)


def parse_zero_calls(body) -> dict | None:
    """A /spend/logs/v2 page of one model's $0 calls → the shares of {"byok": your own provider key (usage.is_byok
    true), "promo": a promotion (the gateway reported usage.cost 0 with is_byok false), "unknown": the rest (a streamed
    answer's usage without is_byok, or none the gateway sent)}; None for an empty page."""
    data = body.get("data") if isinstance(body, dict) else None
    n = byok = promo = 0
    for row in data if isinstance(data, list) else []:
        if not isinstance(row, dict):
            continue
        n += 1
        md = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
        u = md.get("usage_object") if isinstance(md.get("usage_object"), dict) else {}
        c = u.get("cost")
        if u.get("is_byok") is True:
            byok += 1
        elif u.get("is_byok") is False and isinstance(c, (int, float)) and not isinstance(c, bool) and c == 0:
            promo += 1
    return {"byok": byok / n, "promo": promo / n, "unknown": (n - byok - promo) / n} if n else None


async def zero_splits(client: httpx.AsyncClient, litellm_url: str, master: str, pairs: list[tuple[str, str]],
                      today: date, now: float | None = None) -> dict:
    """{(model, day): parse_zero_calls(…)} for PAIRS (zero_days): up to XL_SAMPLE of that model's $0 calls that day, the
    newest. A past day is read once, today once a minute; a day LiteLLM did not answer for is left out (its calls stay
    $0, and are not counted as your own provider key's) and asked again on the next refresh."""
    now = time.monotonic() if now is None else now
    out, todo = {}, []
    for model, d in pairs:
        hit = _xl_days.get((litellm_url, model, d))
        if hit and (d < today.isoformat() or now - hit[0] < CACHE_SECONDS):
            out[(model, d)] = hit[1]
        else:
            todo.append((model, d))
    gate = asyncio.Semaphore(XL_PARALLEL)

    async def one(model: str, d: str):
        async with gate:
            body, err = await _get(client, f"{litellm_url}/spend/logs/v2", master, {
                "start_date": f"{d} 00:00:00", "end_date": f"{d} 23:59:59", "model_group": f"xl/{model}",
                "max_spend": "0", "status_filter": "success", "page_size": str(XL_SAMPLE),
                "exclude_internal_health_checks": "true"})
        if err:
            return
        out[(model, d)] = got = parse_zero_calls(body)
        _xl_days[(litellm_url, model, d)] = (now, got)
        while len(_xl_days) > XL_DAYS_KEPT:
            _xl_days.pop(next(iter(_xl_days)))

    await asyncio.gather(*(one(m, d) for m, d in todo))
    return {k: v for k, v in out.items() if v is not None}


# --- failures ---

FAILURE_KINDS = {
    "daily_limit": ("Free models: daily request limit reached",
                    "The count starts over with the next UTC day; buying at least $10 of OpenRouter credits raises "
                    "the limit from 50 to 1,000 free requests a day."),
    "upstream_busy": ("This model is busy upstream (HTTP 429)",
                      "Its provider is rate-limiting everyone, not you: retry shortly, pick another free model, or use "
                      "the free router or/openrouter/free."),
    "rate_limit": ("Rate limited (HTTP 429)",
                   "This key sent too many requests in a short time (free models allow 20 a minute): wait a minute, "
                   "or pick another model."),
    "credits": ("Not enough OpenRouter credits (HTTP 402)",
                "Paid models need credits: openrouter.ai/settings/credits — or ./stack openrouter models free."),
    "data_policy": ("No endpoint matches your OpenRouter privacy settings (HTTP 404)",
                    "Free models need \"Allow free endpoints that train on request data\" at openrouter.ai/settings/privacy."),
    "key": ("OpenRouter rejected the key (HTTP 401)",
            "Paste a new key into .env and run ./stack openrouter apply (or ./stack openrouter set)."),
    "budget": ("This app's monthly budget is used up",
               "Raise its BUDGET_* in .env, then ./stack setup — or wait for the reset date shown above."),
}


def classify(code: str, text: str) -> str:
    t = text.lower()
    if "budget" in t and "exceeded" in t:
        return "budget"
    if code == "429" or re.search(r"rate[- ]limit", t):
        # In this order: OpenRouter's own daily free limit; the model's provider throttling everyone ("…is
        # temporarily rate-limited upstream…", "Provider returned error"); any other daily wording; the key's rate.
        if "free-models-per-day" in t:
            return "daily_limit"
        if "upstream" in t or "provider returned error" in t:
            return "upstream_busy"
        return "daily_limit" if re.search(r"per[- ]day|daily", t) else "rate_limit"
    if code == "402" or "insufficient credits" in t or "more credits" in t:
        return "credits"
    if "data policy" in t:
        return "data_policy"
    if code == "401" or "user not found" in t:
        return "key"
    return "other"


def _field(text: str, name: str) -> str | None:
    """The string value of "NAME": "…" (JSON) or 'NAME': '…' (a Python repr, as LiteLLM sometimes logs it)."""
    m = re.search(r'"%s"\s*:\s*"((?:[^"\\]|\\.)*)"' % name, text) or re.search(r"'%s'\s*:\s*'((?:[^'\\]|\\.)*)'" % name, text)
    return m.group(1).replace('\\"', '"').replace("\\'", "'") if m else None


_MASKS = (
    (r"\bsk-[A-Za-z0-9_-]{3,}", "[key]"),
    (r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b", "[AWS key]"),
    (r"arn:aws[^\s\"',]*", "arn:aws:…"),
    (r"\b[0-9a-fA-F]{64}\b", "[hash]"),            # LiteLLM's 401s carry the key's hash ("Key Hash (Token) =…")
    (r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+", "[email]"),
    (r"\b\d{12}\b", "[account]"),                  # AWS account ids
)


def short_error(text: str) -> str:
    """One readable line from LiteLLM's error message: the provider's own "message" when there is one (its
    metadata.raw when the message is only "Provider returned error"), with keys, AWS access keys, ARNs, account
    ids, key hashes and emails masked; at most 140 characters."""
    msg = _field(text, "message")
    if msg and msg.strip().lower() == "provider returned error":
        msg = _field(text, "raw") or msg
    s = msg if msg else text
    s = re.sub(r"^(litellm\.)?\w+(Error|Exception):\s*", "", s.strip())
    for pattern, mask in _MASKS:
        s = re.sub(pattern, mask, s)
    s = " ".join(s.split())
    return s if len(s) <= 140 else s[:139] + "…"


def _utc_iso(v) -> str | None:
    """LiteLLM's startTime as ISO 8601 with an explicit UTC offset (a naive time is UTC), or None."""
    if not isinstance(v, str):
        return None
    try:
        t = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).astimezone(timezone.utc).isoformat(timespec="seconds")


def parse_failures(body) -> tuple[list[dict], bool]:
    """Failed requests to or/… models in a /spend/logs/v2 page → [{at, model, code, text}], and whether the page
    was full (more failures than were read)."""
    data = body.get("data") if isinstance(body, dict) else None
    data = data if isinstance(data, list) else []
    total = body.get("total") if isinstance(body, dict) else None
    out = []
    for row in data:
        if not isinstance(row, dict):
            continue
        md = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
        ei = md.get("error_information") if isinstance(md.get("error_information"), dict) else {}
        group = row.get("model_group") if isinstance(row.get("model_group"), str) else ""
        provider = row.get("custom_llm_provider") or ei.get("llm_provider") or ""
        if not group.startswith("or/") and provider != "openrouter":
            continue
        out.append({"at": _utc_iso(row.get("startTime")), "model": group, "code": str(ei.get("error_code") or ""),
                    "text": str(ei.get("error_message") or ei.get("error_class") or "")})
    more = isinstance(total, int) and total > len(data)
    return out, more


def group_failures(rows: list[dict]) -> list[dict]:
    """Failures by kind (other errors by status and message), most frequent first, each with a one-line fix."""
    groups: dict = {}
    for r in rows:
        kind = classify(r["code"], r["text"])
        detail = short_error(r["text"]) if kind == "other" else ""
        g = groups.setdefault((kind, r["code"] if kind == "other" else "", detail), {
            "kind": kind, "count": 0, "status": r["code"] or None, "last_at": None, "models": [],
            "label": FAILURE_KINDS[kind][0] if kind in FAILURE_KINDS else (f"HTTP {r['code']}" if r["code"] else "Error"),
            "fix": FAILURE_KINDS[kind][1] if kind in FAILURE_KINDS else detail,
        })
        g["count"] += 1
        if r["at"] and (g["last_at"] is None or r["at"] > g["last_at"]):
            g["last_at"] = r["at"]
        if r["model"] and r["model"] not in g["models"] and len(g["models"]) < 3:
            g["models"].append(r["model"])
    return sorted(groups.values(), key=lambda g: -g["count"])


async def failures(client: httpx.AsyncClient, litellm_url: str, master: str, now_utc: datetime,
                   now: float | None = None) -> dict:
    now = time.monotonic() if now is None else now
    out = _cached("failures", now, litellm_url)
    if out is not None:
        return out

    async def fetch():
        fmt = "%Y-%m-%d %H:%M:%S"
        body, err = await _get(client, f"{litellm_url}/spend/logs/v2", master, {
            "start_date": (now_utc - timedelta(hours=FAILURE_HOURS)).strftime(fmt), "end_date": now_utc.strftime(fmt),
            "status_filter": "failure", "page_size": str(FAILURE_PAGE), "exclude_internal_health_checks": "true"})
        if err:
            return {"hours": FAILURE_HOURS, "count": None, "more": False, "groups": [], "error": err}
        rows, more = parse_failures(body)
        got = {"hours": FAILURE_HOURS, "count": len(rows), "more": more, "groups": group_failures(rows), "error": None}
        _cache["failures"] = (now, got, litellm_url)
        return got

    return await _once("failures", litellm_url, fetch)


# --- what Home gets ---

def _bucket() -> dict:
    return {"requests": 0, "tokens_in": 0, "tokens_out": 0, "cost": 0.0, "equivalent": 0.0}


def _add(b: dict, m: dict, equivalent: float) -> None:
    b["requests"] += m["requests"]
    b["tokens_in"] += m["tokens_in"]
    b["tokens_out"] += m["tokens_out"]
    b["cost"] += m["spend"]
    b["equivalent"] += m["spend"] + equivalent


def _part(n: int, share: float) -> int:
    return n if share == 1 else int(n * share + 0.5)


def free_part(r: dict, cat: dict, xl: dict, splits: dict) -> tuple[float, dict | None, float, float]:
    """Of parse_activity row R: (the share that is free usage, the prices Equivalent puts on it or None, the share
    that ran on your own provider key, the share booked $0 without saying why). SPLITS: zero_splits' answer."""
    if r["src"] == "or":
        free = is_free(r["model"], cat)
        return (1.0, paid_variant(r["model"], cat), 0.0, 0.0) if free else (0.0, None, 0.0, 0.0)
    x = xl.get(r["model"])
    if r["model"].endswith(":free") or (x and x["free"]):
        base = xl.get(r["model"].removesuffix(":free"))   # (a free tier no longer chosen: its model's, if chosen)
        return 1.0, (x or {}).get("paid") or (base["paid"] if base and not base["free"] else None), 0.0, 0.0
    sp = splits.get((r["model"], r["date"]))
    return (sp["promo"], x["paid"], sp["byok"], sp["unknown"]) if sp and x else (0.0, None, 0.0, 0.0)


def summarize(rows: list[dict], cat: dict, today: date, start30: date, windows: dict, actual_total: float | None,
              key_spend: dict, xl: dict | None = None, splits: dict | None = None) -> tuple[dict, dict]:
    """(spend.equivalent, spend.openrouter_usage without failures) from parse_activity rows.
    WINDOWS: {alias: (key hash, first day of its budget period)}; KEY_SPEND: {alias: actual spend or None}; XL:
    xl_prices(); SPLITS: zero_splits(). OpenRouter's usage counts or/… rows only."""
    xl, splits = xl or {}, splits or {}
    t, s30 = today.isoformat(), start30.isoformat()
    usage = {"today": {"free": _bucket(), "paid": _bucket()}, "days_30": {"free": _bucket(), "paid": _bucket()}}
    per_model: dict = {}
    keys = {a: {"extra": 0.0, "free_requests": 0, "free_tokens_in": 0, "free_tokens_out": 0} for a in windows}
    no_paid, extra_30d, byok_30d, unknown_30d = set(), 0.0, 0, 0
    f30 = {"requests": 0, "tokens_in": 0, "tokens_out": 0}
    for r in rows:
        share, pv, byok, unknown = free_part(r, cat, xl, splits)
        free = share > 0
        eq = priced(r["m"], pv) * share if pv else 0.0
        if free and not pv and r["m"]["requests"]:
            no_paid.add(r["model"] if r["src"] == "or" else f"xl/{r['model']}")
        if r["date"] >= s30:
            byok_30d += _part(r["m"]["requests"], byok)
            unknown_30d += _part(r["m"]["requests"], unknown)
            if free:
                extra_30d += eq
                for f in f30:
                    f30[f] += _part(r["m"][f], share)
            if r["src"] == "or":
                kind = "free" if free else "paid"
                _add(usage["days_30"][kind], r["m"], eq)
                if r["date"] == t:
                    _add(usage["today"][kind], r["m"], eq)
                pm = per_model.setdefault(r["model"], {**_bucket(), "free": free})
                _add(pm, r["m"], eq)
        if not free:
            continue
        for alias, (h, start) in windows.items():
            km = r["keys"].get(h)
            if km and r["date"] >= start.isoformat():
                k = keys[alias]
                k["extra"] += priced(km, pv) * share if pv else 0.0
                k["free_requests"] += _part(km["requests"], share)
                k["free_tokens_in"] += _part(km["tokens_in"], share)
                k["free_tokens_out"] += _part(km["tokens_out"], share)
    for alias, k in keys.items():
        actual = key_spend.get(alias)
        k["spend"] = None if actual is None else actual + k["extra"]
    equivalent = {
        "total_30d": None if actual_total is None else actual_total + extra_30d, "extra_30d": extra_30d,
        "free_requests_30d": f30["requests"], "free_tokens_in_30d": f30["tokens_in"], "free_tokens_out_30d": f30["tokens_out"],
        "byok_requests_30d": byok_30d, "zero_unknown_requests_30d": unknown_30d, "keys": keys, "no_paid_variant": sorted(no_paid), "error": None,
    }
    top = sorted(per_model.items(), key=lambda kv: (-kv[1]["requests"], -(kv[1]["tokens_in"] + kv[1]["tokens_out"]), kv[0]))
    usage["top"] = [{"id": f"or/{mid}", "name": (cat.get(mid) or {}).get("name") or mid, "access": "free" if b["free"] else "paid",
                     "requests": b["requests"], "tokens_in": b["tokens_in"], "tokens_out": b["tokens_out"],
                     "cost": b["cost"], "equivalent": b["equivalent"],
                     "no_paid_variant": b["free"] and not paid_variant(mid, cat)}
                    for mid, b in top[:TOP_MODELS]]
    usage["error"] = None
    return equivalent, usage


def unavailable(err: str, fails: dict | None = None, openrouter: bool = True) -> tuple[dict, dict | None]:
    """(spend.equivalent, spend.openrouter_usage) that only say why they are missing; Home then shows Actual.
    (No OpenRouter usage at all while OpenRouter is off.)"""
    fails = fails or {"hours": FAILURE_HOURS, "count": None, "more": False, "groups": [], "error": err}
    return ({"total_30d": None, "extra_30d": None, "keys": {}, "no_paid_variant": [], "error": err},
            {"today": None, "days_30": None, "top": [], "error": err, "failures": fails} if openrouter else None)


async def build(client: httpx.AsyncClient, s, sp: dict, now_utc: datetime | None = None) -> tuple[dict | None, dict | None]:
    """(spend.equivalent, spend.openrouter_usage) for /api/summary: (None, None) while OpenRouter and Experiential Labs
    are both off; the usage is None while OpenRouter is. SP: summary.spend()'s result (key rows with period_start,
    total_30d)."""
    xl = xl_prices(s.litellm_dir)
    on_or = bool(s.openrouter_api_key)
    if not on_or and xl is None:
        return None, None
    now_utc = now_utc or datetime.now(timezone.utc)
    today = now_utc.date()
    start30 = today - timedelta(days=30)   # /global/spend: "startTime" >= CURRENT_DATE - 30 days
    by_alias = {alias: key for alias, _label, key in s.keys}
    windows, key_spend = {}, {}
    for row in sp.get("keys") or []:
        key = by_alias.get(row["alias"])
        if not key or row.get("error"):
            continue
        try:
            start = date.fromisoformat(row["period_start"]) if row.get("period_start") else start30
        except ValueError:
            start = start30
        windows[row["alias"]] = (key_hash(key), start)
        key_spend[row["alias"]] = row.get("spend")
    first = min([start30] + [w[1] for w in windows.values()])
    if on_or:
        (rows, err), fails = await asyncio.gather(
            activity(client, s.litellm_url, s.litellm_master_key, first, today),
            failures(client, s.litellm_url, s.litellm_master_key, now_utc))
    else:
        (rows, err), fails = await activity(client, s.litellm_url, s.litellm_master_key, first, today), None
    if err:
        return unavailable(err, fails, on_or)
    splits = await zero_splits(client, s.litellm_url, s.litellm_master_key, zero_days(rows, xl), today) if xl else {}
    equivalent, usage = summarize(rows, read_catalog(s.litellm_dir), today, start30, windows,
                                  sp.get("total_30d") if not sp.get("total_error") else None, key_spend, xl, splits)
    if not on_or:
        return equivalent, None
    usage["failures"] = fails
    return equivalent, usage
