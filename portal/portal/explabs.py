"""Optional Experiential Labs data for Home, Chat's Who answers and the Code page: the chosen models, from
litellm/explabs-models.json (./stack writes it whenever it renders LiteLLM's config: lib/explabs.sh, and removes it while
the gateway is off). The portal never holds the gateway's key and never calls the gateway: what each call cost is
LiteLLM's spend (the cost the gateway reported for it), like every other model's.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

FILE = "explabs-models.json"
MAX_FILE = 512 * 1024
MAX_MODELS = 500
ID = re.compile(r"xl/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
PROVIDER = "Experiential Labs"


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else None


def money(v: float) -> str:
    """Like money in lib/models.sh: $0.22, $0.1375, $10.00."""
    s = f"{v:.4f}"
    while s.endswith("0") and len(s.split(".")[1]) > 2:
        s = s[:-1]
    return f"${s}"


def read(litellm_dir: Path) -> dict | None:
    """The file as Home needs it: {fetched_at, details, error, models: [{id, name, vendor, prompt, completion,
    context, free, failsafe}]}, every field checked; None while Experiential Labs is off (no file) or the file is not
    one ./stack wrote."""
    try:
        path = litellm_dir / FILE
        if path.stat().st_size > MAX_FILE:
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("models"), list):
        return None
    models = []
    for m in data["models"][:MAX_MODELS]:
        if not isinstance(m, dict) or not isinstance(m.get("id"), str) or not ID.fullmatch(m["id"]):
            continue
        name = m.get("name") if isinstance(m.get("name"), str) and ID.fullmatch("xl/" + m["name"]) else m["id"][3:]
        vendor = m.get("vendor") if isinstance(m.get("vendor"), str) and re.fullmatch(r"[A-Za-z0-9. -]{0,40}", m["vendor"]) else ""
        ctx = m.get("context_length")
        models.append({"id": m["id"], "name": name, "vendor": vendor, "prompt": _num(m.get("prompt")),
                       "completion": _num(m.get("completion")),
                       "context": ctx if isinstance(ctx, int) and not isinstance(ctx, bool) and 0 < ctx < 100_000_000 else None,
                       "free": m.get("free") is True, "failsafe": m.get("failsafe") is True})
    fetched = data.get("fetched_at") if isinstance(data.get("fetched_at"), str) and len(data["fetched_at"]) <= 40 else None
    err = data.get("error") if isinstance(data.get("error"), str) else None
    return {"fetched_at": fetched, "details": data.get("details") is True, "error": err[:300] if err else None,
            "models": models}


def price_short(m: dict) -> str:
    """"$0.32/$2.40 /1M" (the list price), "free" or "price unknown"."""
    if m["free"]:
        return "free"
    if m["prompt"] is None or m["completion"] is None:
        return "price unknown"
    return f"{money(m['prompt'] * 1e6)}/{money(m['completion'] * 1e6)} /1M"


def rows(data: dict | None) -> list[dict]:
    """Home's model table rows for the chosen models (provider Experiential Labs; access free or paid)."""
    out = []
    for m in (data or {}).get("models") or []:
        why = "no model details: optional parameters are not sent" if m["failsafe"] else "ok"
        out.append({"name": m["id"], "display": m["name"], "tier": None, "kind": "chat", "enabled": True,
                    "why": "ok (fail safe)" if m["failsafe"] else "ok",
                    "reason": f"Experiential Labs model (EXPLABS_MODELS); {why}", "price": price_short(m),
                    "provider": PROVIDER, "access": "free" if m["free"] else "paid", "icon": None})
    return out


def summary(data: dict | None) -> dict | None:
    """What Home's model note says of it: when the details were read, how many models run fail safe."""
    if data is None:
        return None
    return {"fetched_at": data["fetched_at"], "details": data["details"], "error": data["error"],
            "count": len(data["models"]), "failsafe": sum(1 for m in data["models"] if m["failsafe"])}
