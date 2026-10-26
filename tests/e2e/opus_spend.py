"""Spend on Claude Opus in a throwaway's LiteLLM spend log since a moment (the e2e harness's no-opus-spend check).

usage: python3 -I opus_spend.py ENV_FILE SINCE_MS
Reads LITELLM_PORT and LITELLM_MASTER_KEY from the throwaway's .env (the key never reaches a command line or the
output), pages through GET /spend/logs/v2 for the days around SINCE_MS (master key; the endpoint needs a date window)
and prints "SPEND<TAB>MODELS": the summed spend of the rows that started at or after SINCE_MS on a model whose name or
model group names Opus, and those models (comma-separated). Exit 1, saying why on stderr, when LiteLLM does not answer
or answers something else: an unknown reading is an error, never $0.
"""
from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

OPUS = re.compile(r"opus", re.I)
PAGE_SIZE = 100
MAX_PAGES = 200


def env_of(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            k, sep, v = line.rstrip("\n").partition("=")
            if sep and k in ("LITELLM_PORT", "LITELLM_MASTER_KEY"):
                out[k] = v   # (the last one wins, as get_env reads it)
    return out


def started_ms(v) -> int | None:
    if not isinstance(v, str) or not v:
        return None
    try:
        t = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)   # (LiteLLM writes UTC)
    return int(t.timestamp() * 1000)


def main() -> int:
    env_file, since = sys.argv[1], int(sys.argv[2])
    env = env_of(env_file)
    port, key = env.get("LITELLM_PORT", ""), env.get("LITELLM_MASTER_KEY", "")
    if not port.isdigit() or not key:
        print("no LITELLM_PORT or master key in the throwaway's .env", file=sys.stderr)
        return 1
    day0 = (datetime.fromtimestamp(since / 1000, timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
    day1 = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d")
    total, models = 0.0, set()
    for page in range(1, MAX_PAGES + 1):
        url = (f"http://127.0.0.1:{port}/spend/logs/v2?start_date={day0}&end_date={day1}"
               f"&page={page}&page_size={PAGE_SIZE}")
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = json.load(r)
        except (urllib.error.URLError, OSError, ValueError) as e:
            print(f"LiteLLM's /spend/logs/v2 did not answer ({type(e).__name__})", file=sys.stderr)
            return 1
        rows = body.get("data") if isinstance(body, dict) else None
        if not isinstance(rows, list):
            print("LiteLLM's /spend/logs/v2 answered without its data", file=sys.stderr)
            return 1
        for row in rows:
            if not isinstance(row, dict):
                continue
            t = started_ms(row.get("startTime"))
            names = [str(row.get(k) or "") for k in ("model_group", "model")]   # (the stack's name first)
            if t is None or t < since or not any(OPUS.search(n) for n in names):
                continue
            spend = row.get("spend")
            if isinstance(spend, (int, float)) and not isinstance(spend, bool) and spend == spend and spend > 0:
                total += float(spend)
                models.add(next((n for n in names if n and OPUS.search(n)), names[0])[:128])
        pages = body.get("total_pages")
        if not rows or not isinstance(pages, int) or page >= pages:
            break
    print(f"{total:.6f}\t{','.join(sorted(models))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
