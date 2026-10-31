#!/usr/bin/env python3
"""Compare two UI control inventories (controls.json of ui_sweep.py, JON-869): what a user could see and click in OLD and
cannot in NEW.

  ui_inventory_diff.py OLD/controls.json NEW/controls.json [--allow tests/e2e/browser/ui-removed.json] [--out DIR]

Per state key (<page>-<state>-<width>-<theme>) present in both, a control of OLD's visible set is LOST when NEW's has no
match (by id when both have one, else by role + normalized name), DISABLED when NEW's match is disabled and OLD's was
not, UNNAMED when NEW's match has no accessible name and OLD's had one; an id that is visible in OLD and only present-
but-hidden in NEW is lost too (the same control, found by its id). A state key of OLD absent from NEW is LOST STATE.
New controls are listed only. Exit 1 when anything is not covered by the allowlist: a JSON list of
{"state": glob, "control": "role:name" or "#id", "why": "...", "changelog": "vX.Y.Z"}; an entry without why or changelog
is rejected (exit 2). "control" may be "*" for a whole state. Writes inventory-diff.json (next to NEW, or in --out)."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

KINDS = ("lost", "disabled", "unnamed", "lost-state")


def load_allow(path: Path | None) -> list[dict]:
    """The allowlist's entries; ValueError names an entry that lacks state, control, why or changelog (vX.Y.Z)."""
    if path is None or not path.exists():
        return []
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        raise ValueError(f"{path}: expected a list of entries")
    for i, e in enumerate(data):
        for k in ("state", "control", "why", "changelog"):
            if not isinstance(e, dict) or not str(e.get(k, "")).strip():
                raise ValueError(f"{path}: entry {i} has no {k!r} (every declared removal says why and in which release's changelog)")
        if not re.fullmatch(r"v\d+\.\d+\.\d+\S*", e["changelog"].strip()):
            raise ValueError(f"{path}: entry {i}: changelog {e['changelog']!r} is not a release tag like v0.45.1")
    return data


def label(c: dict) -> str:
    """A control as an allowlist names it: #id when it has one (in a frame: host#id), else role:name."""
    frame = c.get("frame", "")
    return f"{frame}#{c['id']}" if c.get("id") else f"{c['role']}:{c['name']}"


def _names(c: dict) -> set[str]:
    out = {f"{c['role']}:{c['name']}"}
    if c.get("id"):
        out |= {f"#{c['id']}", label(c)}
    return out


def covered(allow: list[dict], problem: dict) -> dict | None:
    for e in allow:
        if fnmatch.fnmatchcase(problem["state"], e["state"]) and (e["control"] == "*" or e["control"] in problem["names"]):
            return e
    return None


def _match(c: dict, pool: list[dict]) -> dict | None:
    """C's counterpart in POOL: the same id (and frame) when both have one, else the same role and name."""
    if c.get("id"):
        for n in pool:
            if n.get("id") == c["id"] and n.get("frame", "") == c.get("frame", ""):
                return n
    for n in pool:
        if not (c.get("id") and n.get("id")) and n["role"] == c["role"] and n["name"] == c["name"] and n.get("frame", "") == c.get("frame", ""):
            return n
    for n in pool:   # an id that changed but the control kept its role and name
        if n["role"] == c["role"] and n["name"] == c["name"] and n.get("frame", "") == c.get("frame", ""):
            return n
    return None


def diff(old: dict, new: dict) -> dict:
    """{"problems": [{kind, state, control, detail}], "new": [{state, control}]}: allowlisting is applied by the caller."""
    problems: list[dict] = []
    added: list[dict] = []
    for key in sorted(old):
        if key not in new:
            problems.append({"kind": "lost-state", "state": key, "control": "*", "names": ["*"], "detail": "the whole state is absent from NEW"})
            continue
        ov, nv = old[key].get("visible", []), new[key].get("visible", [])
        nhid = {h for h in new[key].get("hidden_ids", [])}
        for c in ov:
            m = _match(c, nv)
            if m is None:
                where = " (still in the page, hidden)" if c.get("id") and f"{c.get('frame', '')}#{c['id']}" in nhid else ""
                problems.append({"kind": "lost", "state": key, "control": label(c), "names": sorted(_names(c)), "detail": f"{c['role']} {c['name']!r} is no longer visible{where}"})
                continue
            if c["name"] and not m["name"]:
                problems.append({"kind": "unnamed", "state": key, "control": label(c), "names": sorted(_names(c)), "detail": f"{c['role']} {c['name']!r} lost its accessible name"})
            if m["disabled"] and not c["disabled"]:
                problems.append({"kind": "disabled", "state": key, "control": label(c), "names": sorted(_names(c)), "detail": f"{c['role']} {c['name']!r} is now disabled"})
        for c in nv:
            if _match(c, ov) is None:
                added.append({"state": key, "control": label(c)})
    return {"problems": problems, "new": added}


def run(old: dict, new: dict, allow: list[dict]) -> dict:
    d = diff(old, new)
    unallowed, allowed = [], []
    for p in d["problems"]:
        e = covered(allow, p)
        (allowed if e else unallowed).append({**p, **({"allowed_by": e} if e else {})})
    return {"problems": unallowed, "allowed": allowed, "new": d["new"], "states": [len(old), len(new)]}


def summary(res: dict) -> str:
    out = [f"ui inventory: {res['states'][0]} states in OLD, {res['states'][1]} in NEW"]
    for title, rows in (("NOT ALLOWED", res["problems"]), ("allowed (declared on purpose)", res["allowed"])):
        if rows:
            out.append(f"\n{title}: {len(rows)}")
            for p in rows:
                why = f"  [{p['allowed_by']['changelog']}: {p['allowed_by']['why']}]" if "allowed_by" in p else ""
                out.append(f"  {p['kind']:<10} {p['state']}  {p['control']}  {p['detail']}{why}")
    if res["new"]:
        out.append(f"\nnew controls (info only): {len(res['new'])}")
        out += [f"  {n['state']}  {n['control']}" for n in res["new"][:40]]
        if len(res["new"]) > 40:
            out.append(f"  ... and {len(res['new']) - 40} more (inventory-diff.json)")
    out.append("\nFAIL: a control disappeared, was disabled or lost its name; declare it in tests/e2e/browser/ui-removed.json if on purpose"
               if res["problems"] else "\nok: nothing a user could use was lost")
    return "\n".join(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("old", type=Path)
    ap.add_argument("new", type=Path)
    ap.add_argument("--allow", type=Path, default=Path(__file__).resolve().parent / "browser" / "ui-removed.json")
    ap.add_argument("--out", type=Path, help="where inventory-diff.json goes (default: next to NEW)")
    a = ap.parse_args(argv)
    try:
        allow = load_allow(a.allow)
    except (ValueError, json.JSONDecodeError) as e:
        print(f"allowlist rejected: {e}", file=sys.stderr)
        return 2
    try:
        old, new = json.loads(a.old.read_text()), json.loads(a.new.read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"cannot read an inventory: {e}", file=sys.stderr)
        return 2
    res = run(old, new, allow)
    out = (a.out or a.new.parent)
    out.mkdir(parents=True, exist_ok=True)
    (out / "inventory-diff.json").write_text(json.dumps(res, indent=1))
    print(summary(res))
    return 1 if res["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
