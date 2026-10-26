"""Layout: nothing collides or is cut off at the window sizes people use (layout_sweep.py's fast run).

browser/layout-no-overlap measures the main pages and states — sign-in, Home (its folds open; the sidebar collapsed),
More, Activity, search, Settings' Models & providers and Claude Code sections (every fold and info panel open), the
walkthrough's first steps (and beside a collapsed sidebar), the Chat and Terminal tabs' chrome (and a phone's Code tab),
the Code page (as it opens, its model picker, its menu, the Explorer with a file open, Search, Git, Projects, the
terminal panel) — at 320,
360, 390, 600, 768, 820, 1024, 1100, 1280, 1366, 1440 and 1920 px wide (800 high), in light and dark, phones and tablets
with touch. It fails on any finding not in layout-allowlist.json (each entry reviewed, with its reason). Results:
OUT/browser/layout/summary.txt, findings.json and a cropped screenshot per finding.

E2E_LAYOUT=full runs the release sweep instead: every 40 px from 320 to 1920, heights 600 and 1000, every Settings
section and walkthrough step, the update card (about 20 minutes; tests/e2e/ui-sweep.sh --layout full runs it with the
Code page's mock-backend session as well)."""

from __future__ import annotations

import os
from pathlib import Path

import layout_sweep
from common import ENV, OUT, check, expect, origin


@check("browser", "layout-no-overlap")
def layout_no_overlap(ctx):
    mode = "full" if os.environ.get("E2E_LAYOUT", "fast") == "full" else "fast"
    out = OUT / "layout"
    code_on = ENV.get("CODE_ENABLED", "true").strip().lower() not in ("false", "0", "off", "no")
    cfg = layout_sweep.Cfg(origin=origin(), password=ENV["PORTAL_PASSWORD"], out=out, code=origin("code") if code_on else None,
                           mode=mode, state_dir=Path("/state") if Path("/state/update-check").is_dir() else None)
    res = layout_sweep.run(ctx.browser, cfg)
    bad = layout_sweep.write(out, res)
    lost = [n for n in res["notes"] if n["what"] == "state not reached"]
    expect(res["counts"].get("measurements", 0) > 0, "nothing was measured: " + "; ".join(n["detail"] for n in res["notes"][:3]))
    # (a state the check could not reach is a gap in what it covers: said, and a failure)
    expect(not lost, "state(s) not reached: " + "; ".join(n["detail"] for n in lost)[:600])
    expect(not bad, f"{len(bad)} layout finding(s) not in layout-allowlist.json: "
           + "; ".join(f"{f['check']}: {f['detail']} at {f['widths'][0]}–{f['widths'][-1]} px ({f['states'][0]})" for f in bad[:4])
           + (" …" if len(bad) > 4 else "") + " — browser/layout/summary.txt and shots/")
    allowed = sum(1 for f in res["findings"] if f["allowed"])
    return (f"{res['counts']['measurements']} measurements of {res['counts']['states']} states in {res['secs']} s: no finding "
            f"beyond the {allowed} allowed")
