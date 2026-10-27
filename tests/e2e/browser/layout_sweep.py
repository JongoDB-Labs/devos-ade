"""Layout sweep: every page and state of the portal and the Code page at many window sizes, in both themes, measured in
the page (layout_measure.js) for what collides or is cut off — text over text, a control or a badge over a title, text
cut by an ellipsis or a box that hides it, a document that scrolls sideways, pointer targets under 24 x 24 px (WCAG 2.2,
2.5.8) and focusable controls no scrolling brings into view.

Two sizes of run:
  fast  widths 320 360 390 600 768 820 1024 1100 1280 1366 1440 1920 at one height (800), both themes, the main pages
        and states: tests/e2e/browser/checks_layout.py runs it as browser/layout-no-overlap in every e2e run
  full  every 40 px from 320 to 1920, heights 600 and 1000, both themes, every state (each Settings section, each step of
        the walkthrough, Activity, search, More, the menus and info panels, the collapsed sidebar, the Code page's
        views and, against its mock backend, a session): tests/e2e/ui-sweep.sh --layout full, for releases

Below 768 px the pages are laid out for phones and measured with touch (pointer: coarse), 768-1099 px as tablets with
touch and (full) as a narrowed desktop window with a mouse, 1100 px and up as a desktop with a mouse. A state opens once
per kind of device and the window is then resized through its widths, as a person resizing it would; a state that a
resize ends (a menu that closes) is said, not measured.

Each finding is kept once, by what collides (its elements' paths: tag, id, test id, first classes), with every size,
theme and state it was seen at, and a cropped screenshot of the first (the two elements outlined: the first in magenta,
the second in cyan). layout-allowlist.json lists the reviewed findings that are not faults, each with its reason.

  findings.json   [{sig, check, kind, allowed, why, a, b, detail, first, seen, widths, heights, themes, states, shot}]
  summary.txt     counts by check and the findings not allowed
  shots/          one PNG per finding
  notes.json      states not reached, states a resize ended

Run inside the e2e suite's Playwright container (ui-sweep.sh, checks_layout.py) or anywhere with Python Playwright:
  python3 layout_sweep.py --origin URL --password-file F [--code URL] [--mock URL] [--mode fast|full] [--out DIR]
                          [--only REGEX] [--jobs N] [--static-dir DIR] [--har-record F | --har-replay F]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

try:
    from playwright.sync_api import Error as PwError
except ImportError:   # (its pure parts — the widths, the allowlist, merging — are tested without Playwright)
    PwError = Exception

HERE = Path(__file__).resolve().parent
MEASURE = (HERE / "layout_measure.js").read_text(encoding="utf-8")
ALLOWLIST = HERE / "layout-allowlist.json"

FULL_WIDTHS = list(range(320, 1921, 40))
FULL_HEIGHTS = [600, 1000]
FAST_WIDTHS = [320, 360, 390, 600, 768, 820, 1024, 1100, 1280, 1366, 1440, 1920]
FAST_HEIGHTS = [800]
THEMES = ["light", "dark"]
PHONE_MAX, RAIL_MAX = 767, 1099
UA_PHONE = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36")
UA_TABLET = ("Mozilla/5.0 (Linux; Android 14; Pixel Tablet) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
# the kinds of device: who measures which widths (full: a desktop window narrowed to a tablet's width too)
DEVICES = {
    "phone": dict(is_mobile=True, has_touch=True, user_agent=UA_PHONE),
    "tablet": dict(is_mobile=True, has_touch=True, user_agent=UA_TABLET),
    "desktop": {},
}
# no transitions or animations: every state is measured as it ends, not while it slides in
STILL = ("*, *::before, *::after { transition-duration: 0s !important; transition-delay: 0s !important; "
         "animation-duration: 0s !important; animation-delay: 0s !important; caret-color: transparent !important; }")


def device_widths(device: str, widths: list[int], mode: str) -> list[int]:
    if device == "phone":
        return [w for w in widths if w <= PHONE_MAX]
    if device == "tablet":
        return [w for w in widths if PHONE_MAX < w <= RAIL_MAX]
    lo = PHONE_MAX if mode == "full" else 1000   # (fast: the desktop at 1024 too, besides the tablet)
    return [w for w in widths if w > lo]


@dataclass
class Cfg:
    origin: str
    password: str
    out: Path
    code: str | None = None          # the Code page's own origin on the stack (unlocked with the password)
    mock: str | None = None          # the Code page against its mock backend (code/web/dev/mock-server.mjs)
    mode: str = "fast"
    widths: list[int] = field(default_factory=list)
    heights: list[int] = field(default_factory=list)
    themes: list[str] = field(default_factory=lambda: list(THEMES))
    only: str = ""                   # a regex on state names
    shots: bool = True
    static_dir: Path | None = None   # serve the portal's /static/* from here (a checkout's files over the stack's)
    har_record: Path | None = None
    har_replay: Path | None = None
    state_dir: Path | None = None    # the throwaway's .state (the update card's states: its update-check answer)
    deadline: float = 0.0            # stop measuring (and say so) after this time.time()
    host_rules: str = ""

    def __post_init__(self):
        self.widths = self.widths or (FULL_WIDTHS if self.mode == "full" else FAST_WIDTHS)
        self.heights = self.heights or (FULL_HEIGHTS if self.mode == "full" else FAST_HEIGHTS)


class Lost(Exception):
    """A state could not be reached (or a resize ended it)."""


# ------------------------------------------------------------------------------------------------------------------
# The run: contexts, states, measurements, findings
# ------------------------------------------------------------------------------------------------------------------

class Sweep:
    def __init__(self, browser, cfg: Cfg):
        self.browser, self.cfg = browser, cfg
        self.out = cfg.out
        (self.out / "shots").mkdir(parents=True, exist_ok=True)
        self.findings: dict[str, dict] = {}
        self.notes: list[dict] = []
        self.counts = {"measurements": 0, "states": 0}
        self.cur = {"state": "-", "device": "-", "w": 0, "h": 0, "theme": "-"}
        self.allow = load_allowlist()
        self.t0 = time.time()
        if cfg.har_record:
            cfg.har_record.mkdir(parents=True, exist_ok=True)

    # --- contexts ---
    def context(self, device: str, w: int, h: int, tour: bool = False):
        kw = dict(DEVICES[device])
        c = self.browser.new_context(locale="en-US", timezone_id="UTC", viewport={"width": w, "height": h}, device_scale_factor=1,
                                     reduced_motion="reduce", color_scheme="light", service_workers="block", **kw,
                                     **({"record_har_path": str(self.cfg.har_record / f"{device}-{os.getpid()}-{int(time.time() * 1000)}.har"),
                                         "record_har_content": "embed"} if self.cfg.har_record else {}))
        o = self.cfg.origin
        if not tour:
            c.add_init_script("(o => { try { if (location.origin === o && !localStorage.getItem('bn.tour')) "
                              "localStorage.setItem('bn.tour', JSON.stringify({open: false})); } catch (e) {} })"
                              f"({json.dumps(o)});")
        if self.cfg.har_replay:
            c.route_from_har(str(self.cfg.har_replay), not_found="fallback")
            saved = self.cfg.har_replay.parent

            def page(route):
                path = urlsplit(route.request.url).path
                f = saved / ("page-login.html" if path == "/login" else "page-index.html")
                if route.request.method == "POST" and path == "/login":
                    wrong = saved / "page-login-wrong.html"
                    if wrong.exists():
                        return route.fulfill(status=200, body=wrong.read_bytes(), headers={"content-type": "text/html; charset=utf-8"})
                    return route.fulfill(status=303, headers={"location": "/"})
                route.fulfill(status=200, body=f.read_bytes(), headers={"content-type": "text/html; charset=utf-8"})
            c.route(re.compile(re.escape(o) + r"/(login)?(\?.*)?$"), page)
        if self.cfg.static_dir:
            sd = self.cfg.static_dir

            def static(route):
                p = urlsplit(route.request.url).path
                f = (sd / p[len("/static/"):]).resolve()
                if not str(f).startswith(str(sd.resolve())) or not f.is_file():
                    return route.fallback()
                ctype = {".css": "text/css", ".js": "text/javascript", ".svg": "image/svg+xml", ".woff2": "font/woff2",
                         ".png": "image/png", ".html": "text/html"}.get(f.suffix, "application/octet-stream")
                route.fulfill(status=200, body=f.read_bytes(), headers={"content-type": ctype, "cache-control": "no-store"})
            c.route(re.compile(re.escape(o) + r"/static/"), static)
        if self.cfg.har_replay:
            # (nothing else of the stack is there: the apps' frames stay empty, their chrome is what is measured)
            c.route(re.compile(r"^https?://(chat|admin|files|terminal)\."), lambda r: r.fulfill(status=200, body="", headers={"content-type": "text/html"}))
        c.add_init_script(f"(() => {{ const s = document.createElement('style'); s.textContent = {json.dumps(STILL)}; "
                          "document.addEventListener('DOMContentLoaded', () => document.head.appendChild(s)); })();")
        p = c.new_page()
        p.set_default_timeout(20000)
        return c, p

    def login(self, p):
        p.goto(self.cfg.origin + "/")
        if "/login" in p.url and p.locator("#password").count():
            p.fill("#password", self.cfg.password)
            p.click("form[action='/login'] button[type=submit]")
        p.wait_for_selector(".shell", timeout=30000)

    # --- measuring ---
    def settle(self, p):
        p.evaluate("() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 30))))")

    def measure_all(self, p, state: str, device: str, widths: list[int], marker: str | None, reopen=None):
        """One state at every size and theme of DEVICE's widths: resize, settle, check the state is still there (a menu
        that a resize closes is opened again by REOPEN), measure."""
        self.counts["states"] += 1
        for h in self.cfg.heights:
            for w in widths:
                if self.cfg.deadline and time.time() > self.cfg.deadline:
                    self.note("deadline", f"stopped at {state} {device} {w}x{h}: the run's time is up")
                    return
                p.set_viewport_size({"width": w, "height": h})
                for theme in self.cfg.themes:
                    p.emulate_media(color_scheme=theme, reduced_motion="reduce")
                    self.settle(p)
                    self.cur.update(state=state, device=device, w=w, h=h, theme=theme)
                    if marker and not p.locator(marker).first.is_visible() and reopen:
                        try:
                            reopen()
                            self.settle(p)
                        except PwError as e:
                            self.note("reopen failed", f"{state} at {device} {w}x{h}: {str(e).splitlines()[0][:160]}")
                    if marker and not p.locator(marker).first.is_visible():
                        self.note("state ended by a resize", f"{state}: {marker} not shown at {device} {w}x{h} {theme}")
                        break
                    try:
                        d = p.evaluate(MEASURE, {"vw": w, "vh": h})
                    except PwError as e:
                        self.note("measure failed", f"{state} {device} {w}x{h} {theme}: {str(e).splitlines()[0][:200]}")
                        continue
                    self.counts["measurements"] += 1
                    self.record(p, d)

    def record(self, p, d: dict):
        c = self.cur
        where = {"state": c["state"], "device": c["device"], "w": c["w"], "h": c["h"], "theme": c["theme"]}
        page = page_of(c["state"])
        for o in d["overlaps"]:
            self.add(p, "overlap", o["kind"], f"{page}|{o['a']['path']}|{o['b']['path']}", where, a=o["a"], b=o["b"],
                     detail=f"{o['kind']}: {o['w']}x{o['h']} px of “{o['a']['text']}” and “{o['b']['text']}”", box=o["at"])
        for o in d["clipped"]:
            if o["meaning"] == "content" or o["intended"]:
                self.counts["clipped content (not a finding)" if o["meaning"] == "content" else "clipped as intended (title kept)"] = \
                    self.counts.get("clipped content (not a finding)" if o["meaning"] == "content" else "clipped as intended (title kept)", 0) + 1
                continue
            self.add(p, "clipped text", o["how"], f"{page}|{o['path']}", where, a=o,
                     detail=f"{o['meaning']} “{o['text']}” {o['how']}: {o['shown']}% shown ({o['have']} of {o['need']} px)", box=o["box"])
        for o in d.get("squeezed", []):
            self.add(p, "squeezed", "scroll area too small", f"{page}|{o['path']}", where, a=o,
                     detail=f"a scrolling area is {o['w']}x{o['h']} px: too small for what it holds (“{o['text']}”)", box=o["box"])
        if d["hscroll"]:
            hs = d["hscroll"]
            top = hs["els"][0] if hs["els"] else {"path": "?", "text": "", "id": -1, "box": None}
            self.add(p, "sideways scroll", "document", f"{page}|{top['path']}", where, a=top,
                     detail=f"the page scrolls {hs['by']} px sideways; widest: " + "; ".join(f"{e['path']} “{e['text']}”" for e in hs["els"][:3]),
                     box=top.get("box"))
        for o in d["small"]:
            self.add(p, "small target", "under 24 px", f"{page}|{o['path']}", where, a=o,
                     detail=f"“{o['text']}” is {o['w']}x{o['h']} px, its 24 px circle meets {o['near']}", box=o["box"])
        for o in d["unreachable"]:
            self.add(p, "unreachable", "focusable out of view", f"{page}|{o['path']}", where, a=o,
                     detail=f"“{o['text']}” can be focused but not scrolled to: {o['why']}", box=o["box"])

    def add(self, p, check: str, kind: str, sig: str, where: dict, a: dict, detail: str, b: dict | None = None, box=None):
        key = f"{check}|{sig}"
        f = self.findings.get(key)
        if f is None:
            # (an entry's sig names the whole signature, its check first — as the summary prints it)
            why = allowed(self.allow, check, key, where["state"])
            f = self.findings[key] = {"sig": key, "check": check, "kind": kind, "allowed": why is not None, "why": why or "",
                                      "a": strip(a), "b": strip(b) if b else None, "detail": detail, "first": dict(where),
                                      "seen": 0, "widths": set(), "heights": set(), "themes": set(), "states": set(), "devices": set(), "shot": ""}
            if self.cfg.shots:
                f["shot"] = self.crop(p, len(self.findings), a, b, box)
        f["seen"] += 1
        f["widths"].add(where["w"]); f["heights"].add(where["h"]); f["themes"].add(where["theme"])
        f["states"].add(where["state"]); f["devices"].add(where["device"])

    def crop(self, p, n: int, a: dict, b: dict | None, box) -> str:
        """A screenshot of the window around the finding (scrolled to it, put back after), its elements outlined."""
        name = f"{n:04d}-{slug(self.cur['state'])}-{self.cur['device']}-{self.cur['w']}x{self.cur['h']}-{self.cur['theme']}.png"
        try:
            r = p.evaluate("""([ia, ib]) => {
              const els = window.__lay || [], A = els[ia], B = ib >= 0 ? els[ib] : null;
              const saved = []; for (let e = A && A.parentElement; e; e = e.parentElement) saved.push([e, e.scrollLeft, e.scrollTop]);
              window.__layScroll = { saved, x: scrollX, y: scrollY };
              if (A) A.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              const box = (e) => { if (!e) return null; const q = e.getBoundingClientRect(); return { l: q.left, t: q.top, r: q.right, b: q.bottom }; };
              const ra = box(A), rb = box(B);
              const mark = (r, color) => { if (!r) return; const d = document.createElement('div'); d.className = '__lay_mark';
                d.style.cssText = `position:fixed;z-index:2147483647;pointer-events:none;left:${r.l - 2}px;top:${r.t - 2}px;width:${r.r - r.l + 4}px;height:${r.b - r.t + 4}px;outline:2px solid ${color};`;
                document.documentElement.appendChild(d); };
              mark(ra, '#e0109e'); mark(rb, '#00b5d8');
              const u = [ra, rb].filter(Boolean); if (!u.length) return null;
              return { l: Math.min(...u.map((q) => q.l)), t: Math.min(...u.map((q) => q.t)), r: Math.max(...u.map((q) => q.r)), b: Math.max(...u.map((q) => q.b)) };
            }""", [a.get("id", -1) if a else -1, b.get("id", -1) if b else -1])
            vw, vh = self.cur["w"], self.cur["h"]
            if r:
                pad = 60
                x0, y0 = max(0, r["l"] - pad), max(0, r["t"] - pad)
                x1, y1 = min(vw, r["r"] + pad), min(vh, r["b"] + pad)
                if x1 - x0 < 40 or y1 - y0 < 40:
                    x0, y0, x1, y1 = 0, 0, vw, vh
            else:
                x0, y0, x1, y1 = 0, 0, vw, vh
            p.screenshot(path=str(self.out / "shots" / name), clip={"x": x0, "y": y0, "width": max(1, x1 - x0), "height": max(1, y1 - y0)},
                         animations="disabled", timeout=15000)
        except PwError as e:
            self.note("screenshot failed", f"{name}: {str(e).splitlines()[0][:200]}")
            name = ""
        finally:
            try:
                p.evaluate("""() => { document.querySelectorAll('.__lay_mark').forEach((d) => d.remove());
                  const s = window.__layScroll; if (s) { for (const [e, x, y] of s.saved) { e.scrollLeft = x; e.scrollTop = y; } scrollTo(s.x, s.y); } }""")
            except PwError:
                pass
        return f"shots/{name}" if name else ""

    def note(self, what: str, detail: str):
        self.notes.append({"what": what, "detail": detail, "at": round(time.time() - self.t0, 1)})
        print(f"  note  {what}: {detail}", flush=True)

    # --- the states, device by device ---
    def run(self, states: list["State"]):
        for st in states:
            if self.cfg.only and not re.search(self.cfg.only, st.name):
                continue
            if st.needs == "code" and not self.cfg.code or st.needs == "mock" and not self.cfg.mock:
                continue
            if st.needs == "stack" and self.cfg.har_replay:
                continue
            for device in st.devices:
                widths = device_widths(device, self.cfg.widths, self.cfg.mode)
                if st.min_w:
                    widths = [w for w in widths if w >= st.min_w]
                if st.max_w:
                    widths = [w for w in widths if w <= st.max_w]
                if not widths:
                    continue
                if self.cfg.deadline and time.time() > self.cfg.deadline:
                    return
                t = time.time()
                c, p = self.context(device, widths[0], self.cfg.heights[0], tour=st.tour)
                try:
                    for step in st.fn(self, p, device):
                        sub, marker, reopen = (*step, None)[:3]
                        if self.cfg.only and not re.search(self.cfg.only, st.name) and not re.search(self.cfg.only, sub):
                            continue
                        self.measure_all(p, sub, device, widths, marker, reopen)
                except Lost as e:
                    self.note("state not reached", f"{st.name} ({device}): {e}")
                except Exception as e:  # noqa: BLE001 — one state's failure is said, the sweep goes on
                    self.note("state not reached", f"{st.name} ({device}): {type(e).__name__}: {str(e).splitlines()[0][:300]}")
                    (self.out / "tracebacks.txt").open("a").write(f"--- {st.name} {device}\n{traceback.format_exc()}\n")
                finally:
                    c.close()
                print(f"  {st.name:<28} {device:<8} {len(widths)} widths  {time.time() - t:5.1f}s  "
                      f"findings {len(self.findings)}", flush=True)

    def result(self) -> dict:
        out = []
        for f in self.findings.values():
            g = dict(f)
            for k in ("widths", "heights", "themes", "states", "devices"):
                g[k] = sorted(g[k])
            out.append(g)
        out.sort(key=lambda f: (f["allowed"], f["check"], f["sig"]))
        return {"findings": out, "notes": self.notes, "counts": self.counts, "secs": round(time.time() - self.t0, 1),
                "mode": self.cfg.mode, "widths": self.cfg.widths, "heights": self.cfg.heights, "themes": self.cfg.themes}


def strip(o: dict | None) -> dict | None:
    if not o:
        return o
    return {k: v for k, v in o.items() if k in ("path", "text", "box", "how", "meaning", "need", "have", "shown", "w", "h", "near", "why")}


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:48]


def page_of(state: str) -> str:
    """The page a state is on (findings of one component on one page are one finding, whatever its state)."""
    for pre in ("signin", "settings", "walkthrough", "code-mock", "code", "activity", "search", "more", "chat", "terminal"):
        if state.startswith(pre):
            return {"code-mock": "code"}.get(pre, pre)
    return "home"


# --- the reviewed allowlist ---

def load_allowlist() -> list[dict]:
    try:
        rows = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [r for r in rows if isinstance(r, dict) and r.get("why")]


def allowed(rows: list[dict], check: str, sig: str, state: str) -> str | None:
    for r in rows:
        if r.get("check") and r["check"] != check:
            continue
        if r.get("sig") and not re.search(r["sig"], sig):
            continue
        if r.get("state") and not re.search(r["state"], state):
            continue
        return r["why"]
    return None


# ------------------------------------------------------------------------------------------------------------------
# States: each a generator over (name, marker) — the page put in that state, then measured at every size
# ------------------------------------------------------------------------------------------------------------------

@dataclass
class State:
    name: str
    fn: object
    devices: tuple = ("phone", "tablet", "desktop")
    needs: str = "portal"     # portal | code (the stack's Code page) | mock (its mock backend) | stack (not in a replay)
    tour: bool = False
    min_w: int = 0
    max_w: int = 0
    fast: bool = True         # in the fast run (the e2e check)


def home(S, p, device):
    S.login(p)
    p.goto(S.cfg.origin + "/#home")
    p.wait_for_selector("#home:not([hidden])")
    p.wait_for_function("() => !/Loading/.test((document.getElementById('updated') || {}).textContent || '')", timeout=20000)
    p.wait_for_timeout(600)


def st_signin(S, p, device):
    p.goto(S.cfg.origin + "/login")
    p.wait_for_selector("#password")
    yield "signin", "#password"
    p.fill("#password", "not the password")
    p.click("form[action='/login'] button[type=submit]")
    p.wait_for_selector(".error, [role=alert]", timeout=15000)
    yield "signin-wrong-password", ".error, [role=alert]"


def st_home(S, p, device):
    home(S, p, device)
    yield "home", "#home"
    p.evaluate("() => document.querySelectorAll('#home details').forEach((d) => { d.open = true; })")
    yield "home-details-open", "#home"


def st_home_collapsed(S, p, device):
    p.add_init_script("try { localStorage.setItem('bn.nav', 'collapsed'); } catch (e) {}")
    home(S, p, device)
    yield "home-sidebar-collapsed", "html.nav-collapsed #home"


def st_update(S, p, device):
    """Home's update card, available (the update check's answer file of the throwaway, put back afterwards)."""
    sd = S.cfg.state_dir
    if not sd or not (sd / "update-check").is_dir():
        raise Lost("no update-check folder of the throwaway to write")
    up = sd / "update-check" / "latest.json"
    saved = up.read_bytes() if up.exists() else None
    now = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
    rels = [{"tag": t, "name": f"{t} — {hl}", "headline": hl, "notes": f"## {t}\n- **layout** release {t} with a longer line of notes to wrap",
             "published_at": now, "url": f"https://github.com/JongoDB-Labs/devos-ade/releases/tag/{t}"}
            for t, hl in (("v99.0.0", "the newest test release, with a headline long enough to wrap on a phone"),
                          ("v98.0.0", "a test release in between"))]
    rec = {"tag": "v99.0.0", "name": "v99.0.0", "notes": rels[0]["notes"], "url": rels[0]["url"], "published_at": now, "checked_at": now,
           "error": None, "images": [], "releases": rels}
    try:
        tmp = up.with_name(".latest.json.layout")
        tmp.write_text(json.dumps(rec)); tmp.chmod(0o644); tmp.replace(up)
        home(S, p, device)
        p.locator("#update-card:not([hidden])").wait_for(timeout=20000)
        p.evaluate("() => document.querySelectorAll('#update-card details').forEach((d) => { d.open = true; })")
        yield "home-update-available", "#update-card"
    finally:
        if saved is None:
            up.unlink(missing_ok=True)
        else:
            up.write_bytes(saved)


def open_more(p):
    p.click("#more-btn")
    p.wait_for_selector("#more-sheet:not([hidden])")


def st_more(S, p, device):
    home(S, p, device)
    open_more(p)
    yield "more-sheet", "#more-sheet .sheet-panel"


def st_activity(S, p, device):
    home(S, p, device)
    if device == "phone":
        open_more(p)
        p.click("#more-activity")
    else:
        p.click("#activity-btn")
    p.wait_for_selector("#activity:not([hidden])", timeout=10000)
    yield "activity", "#activity .act-panel"


def st_search(S, p, device):
    home(S, p, device)
    if device == "phone":
        open_more(p)
        p.click("#more-search")
    else:
        p.click("#search-btn")
    p.wait_for_selector("#search[open]", timeout=10000)
    yield "search-open", "#search[open]"
    p.keyboard.type("update")
    p.wait_for_timeout(1200)
    yield "search-results", "#search[open]"


def settings_sections(S, p) -> list[str]:
    p.goto(S.cfg.origin + "/#settings")
    p.wait_for_selector("#settings:not([hidden]) .set-nav-item", state="attached", timeout=30000)
    p.wait_for_timeout(800)
    return p.eval_on_selector_all(".set-nav-item", "bs => bs.map(b => b.dataset.section)")


def show_section(p, s):
    if p.locator("#set-picker").is_visible():
        p.select_option("#set-picker", s)
    else:
        p.evaluate("s => document.querySelector(`.set-nav-item[data-section=\"${s}\"]`).click()", s)
    p.wait_for_timeout(500)
    # every fold open, every info panel open
    p.evaluate("""s => { const c = document.getElementById('set-' + s) || document.querySelector('#settings');
      c.querySelectorAll('details').forEach((d) => { d.open = true; });
      c.querySelectorAll('.set-info-btn[aria-expanded="false"]').forEach((b) => b.click()); }""", s)
    p.wait_for_timeout(300)


def st_settings(S, p, device):
    S.login(p)
    ids = settings_sections(S, p)
    if not ids:
        raise Lost("no Settings sections")
    yield "settings", "#settings:not([hidden])"
    for s in ids:
        show_section(p, s)
        yield f"settings-{s}", f"#settings:not([hidden])"


def st_settings_main(S, p, device):
    """(fast) Settings' first section and the longest: Models & providers, every fold and info panel open."""
    S.login(p)
    ids = settings_sections(S, p)
    for s in [i for i in ids if i in ("providers", "code")] or ids[:1]:
        show_section(p, s)
        yield f"settings-{s}", "#settings:not([hidden])"


def st_modelbrowser(S, p, device):
    """(fast) Browse models (models.js): the rows list, and with a search typed (the toolbar sticky over the rows)."""
    S.login(p)
    p.goto(S.cfg.origin + "/#modelbrowser")
    p.wait_for_selector("#modelbrowser:not([hidden]) .mb-row, #modelbrowser:not([hidden]) .mb-empty", timeout=30000)
    p.wait_for_timeout(500)
    yield "modelbrowser", "#modelbrowser:not([hidden])"
    if p.locator("#mb-search").count():
        p.fill("#mb-search", "claude")
        p.wait_for_timeout(300)
        yield "modelbrowser-search", "#modelbrowser:not([hidden])"


def tour_open(S, p, device, step="welcome"):
    p.add_init_script("(o => { try { if (location.origin === o && !sessionStorage.getItem('lay.tour')) { sessionStorage.setItem('lay.tour', '1');"
                      f" localStorage.setItem('bn.tour', JSON.stringify({{open: true, cur: {json.dumps(step)}, done: ['signin-portal'], skipped: [], seen: []}})); }} }} catch (e) {{}} }})"
                      f"({json.dumps(S.cfg.origin)});")
    home(S, p, device)
    if p.locator("#tour:not([hidden])").count() == 0:
        if device == "phone":
            open_more(p)
            p.click("#more-tour")
        else:
            p.click("#tour-btn")
    p.wait_for_selector("#tour:not([hidden]) #tour-cur", timeout=15000)
    p.wait_for_timeout(400)


def st_walkthrough(S, p, device, every=True):
    tour_open(S, p, device)
    seen = []
    for _ in range(80):
        cur = p.evaluate("() => { const c = document.querySelector('#tour .tour-step.cur'); return c ? c.dataset.step : '' }") or f"n{len(seen)}"
        if cur in seen:
            break
        seen.append(cur)
        yield f"walkthrough-{cur}", f"#tour:not([hidden]) .tour-step.cur[data-step='{cur}']" if not cur.startswith("n") else "#tour:not([hidden])"
        if not every and len(seen) >= 3:
            break
        nxt = p.locator("#tour [data-k=next]")
        if nxt.count() == 0 or not nxt.first.is_visible() or nxt.first.inner_text().strip() == "Finish":
            break
        nxt.first.click()
        p.wait_for_timeout(500)
        if not p.url.startswith(S.cfg.origin):
            p.goto(S.cfg.origin + "/#home")
            p.wait_for_selector("#tour:not([hidden]) #tour-cur", timeout=15000)


def st_walkthrough_fast(S, p, device):
    yield from st_walkthrough(S, p, device, every=False)


def st_walkthrough_collapsed(S, p, device):
    p.add_init_script("try { localStorage.setItem('bn.nav', 'collapsed'); } catch (e) {}")
    tour_open(S, p, device, step="code-open")
    yield "walkthrough-sidebar-collapsed", "#tour:not([hidden])"


def st_frame(tab):
    def fn(S, p, device):
        S.login(p)
        p.goto(S.cfg.origin + f"/#{tab}")
        p.wait_for_selector(f"iframe[data-app={tab}]", state="attached", timeout=20000)
        p.wait_for_timeout(2500)
        yield f"{tab}-frame", f"iframe[data-app={tab}]"
    return fn


# --- the Code page on the stack (its own host, unlocked) ---

def code_open(S, p, device):
    S.login(p)
    p.goto(S.cfg.code + "/")
    if p.locator("h1", has_text="Unlock the Code page").count() or p.locator("form[action='/.bn/unlock']").count():
        p.fill("#password", S.cfg.password)
        p.click("form[action='/.bn/unlock'] button[type=submit]")
    code_ready(p)


def code_ready(p):
    p.get_by_test_id("conn").wait_for(timeout=30000)
    p.wait_for_function("() => { const c = document.querySelector('[data-testid=conn]'); return c && /Connected/.test(c.textContent) }", timeout=40000)
    p.wait_for_timeout(1000)


def code_fresh(p, base):
    p.goto(base + "/")
    code_ready(p)
    # (a phone opens on its Projects sheet when there are sessions: closed, the page as it is under it)
    for _ in range(2):
        if p.locator(".sheet:visible, [role=dialog]:visible").count():
            p.keyboard.press("Escape")
            p.wait_for_timeout(250)


def esc(p, n=2):
    for _ in range(n):
        p.keyboard.press("Escape")
        p.wait_for_timeout(150)


def code_menu(p, device, item) -> bool:
    if device == "phone" and p.get_by_test_id("phone-menu-btn").count():
        p.get_by_test_id("phone-menu-btn").click()
        p.wait_for_timeout(300)
        it = p.get_by_test_id(f"phone-menu-{item}")
    else:
        p.get_by_test_id("more-menu").click()
        p.wait_for_timeout(300)
        it = p.get_by_test_id(f"menu-{item}")
    if it.count() == 0:
        esc(p)
        return False
    it.first.click()
    p.wait_for_timeout(1000)
    return True


def code_states(prefix):
    def fn(S, p, device):
        base = S.cfg.code if prefix == "code" else S.cfg.mock
        if prefix == "code":
            code_open(S, p, device)
        else:
            code_fresh(p, base)
        yield f"{prefix}-page", "[data-testid=conn]"

        def phone():
            return p.get_by_test_id("phone-menu-btn").first.is_visible() if p.get_by_test_id("phone-menu-btn").count() else False

        # the model picker open (phones: from their menu) — a resize closes it: opened again at each size
        def picker():
            esc(p)
            if phone():
                p.get_by_test_id("phone-menu-btn").click()
                p.wait_for_timeout(300)
                p.get_by_test_id("phone-menu").get_by_test_id("model-picker").first.click()
            else:
                p.get_by_test_id("model-picker").first.click()
            p.wait_for_timeout(600)
        picker()
        yield f"{prefix}-model-picker", "[data-testid=model-search]:visible, [data-testid=who-answers]:visible", picker
        esc(p)

        # the ⋯ menu (phones: their menu) open
        def menu():
            esc(p)
            if phone():
                p.get_by_test_id("phone-menu-btn").click()
            else:
                p.get_by_test_id("more-menu").click()
            p.wait_for_timeout(400)
        menu()
        yield f"{prefix}-menu-open", "[data-testid=phone-menu]:visible, [data-testid=menu-palette]:visible", menu
        esc(p)
        # the side panels (Explorer, Search, Git, Projects), a file open
        code_fresh(p, base)
        for side, testid in (("files", "side-files"), ("search", "side-search"), ("git", "side-git"), ("projects", "side-sessions")):
            b = p.get_by_test_id(testid)
            if device == "phone":
                if side == "files" and p.get_by_test_id("phone-files").count():
                    p.get_by_test_id("phone-files").click()
                elif side in ("git", "projects", "search"):
                    if not code_menu(p, device, {"projects": "projects", "git": "git", "search": "search"}[side]):
                        continue
                else:
                    continue
            elif b.count() and b.first.is_visible():
                b.first.click()
            else:
                continue
            p.wait_for_timeout(900)
            yield f"{prefix}-side-{side}", None
            if side == "files":
                tree = p.get_by_test_id("file-tree")
                f = tree.locator(".tree-row").filter(has_text=re.compile(r"README\.md$")).first if tree.count() else None
                if f is not None and f.count():
                    f.click()
                    p.wait_for_timeout(1500)
                    yield f"{prefix}-file-open", None
            if device == "phone":
                esc(p)
                code_fresh(p, base)
        # the terminal panel (the chrome around its frame)
        t = p.get_by_test_id("toggle-terminal")
        if device != "phone" and t.count() and t.first.is_visible():
            t.first.click()
            p.wait_for_timeout(2500)
            yield f"{prefix}-terminal-panel", "[data-testid=terminal]"
    return fn


def mock_session(S, p, device):
    """A session of the Code page's mock backend: an answer with a table, then an edit waiting for permission."""
    import urllib.request
    try:
        urllib.request.urlopen(urllib.request.Request(S.cfg.mock + "/__mock/reset", method="POST", data=b""), timeout=5).read()
    except OSError:
        pass
    p.goto(S.cfg.mock + "/")
    code_ready(p)
    box = p.get_by_test_id("prompt")
    box.fill("Explain how this project is organised")
    box.press("Enter")
    p.get_by_test_id("turn-end").first.wait_for(timeout=30000)
    box.fill("Please fix get() so it uses the retry policy")
    box.press("Enter")
    p.get_by_test_id("permission").wait_for(timeout=30000)
    p.wait_for_timeout(800)
    yield "code-mock-session-permission", "[data-testid=permission]"
    p.get_by_test_id("perm-once").click()
    p.get_by_test_id("turn-end").nth(1).wait_for(timeout=30000)
    p.wait_for_timeout(800)
    yield "code-mock-session-answered", "[data-testid=composer]"
    box.fill("run the tests")
    box.press("Enter")
    p.wait_for_timeout(2500)
    yield "code-mock-session-tool", "[data-testid=composer]"
    for keys in ("Control+k", "Meta+k"):   # (the palette's shortcut: Ctrl+K, ⌘K on a Mac)
        p.keyboard.press(keys)
        p.wait_for_timeout(600)
        if p.locator("[data-testid=cp-item]").count():
            break
    if p.locator("[data-testid=cp-item]").count():
        yield "code-mock-palette", "[data-testid=cp-item]"


STATES = [
    State("signin", st_signin, needs="portal"),
    State("home", st_home),
    State("home-sidebar-collapsed", st_home_collapsed, devices=("desktop",), min_w=1100),
    State("home-update-available", st_update, needs="stack", fast=False),
    State("more-sheet", st_more, devices=("phone",)),
    State("activity", st_activity),
    State("search", st_search),
    State("settings", st_settings, fast=False),
    State("settings-main", st_settings_main),
    State("modelbrowser", st_modelbrowser),
    State("walkthrough", st_walkthrough, tour=True, fast=False),
    State("walkthrough-first", st_walkthrough_fast, tour=True),
    State("walkthrough-sidebar-collapsed", st_walkthrough_collapsed, devices=("desktop",), tour=True, min_w=1100),
    State("chat-frame", st_frame("chat")),
    State("terminal-frame", st_frame("terminal"), devices=("tablet", "desktop")),
    State("code-frame", st_frame("code"), devices=("tablet", "desktop"), fast=False),
    # (a phone's Code tab: a tab of its bottom bar, framed — the bar with Code current, in the fast run too)
    State("code-tab-phone", st_frame("code"), devices=("phone",), needs="code"),
    State("code", code_states("code"), needs="code"),
    State("code-mock", code_states("code-mock"), needs="mock", fast=False),
    State("code-mock-session", mock_session, needs="mock"),
]


def states_for(mode: str) -> list[State]:
    return [s for s in STATES if mode == "full" or s.fast]


# ------------------------------------------------------------------------------------------------------------------
# Writing the results
# ------------------------------------------------------------------------------------------------------------------

def merge(parts: list[dict]) -> dict:
    """Workers' results as one: a finding seen by several is one, its sizes and states joined."""
    by: dict[str, dict] = {}
    out = {"findings": [], "notes": [], "counts": {}, "secs": 0}
    for r in parts:
        out["notes"] += r["notes"]
        out["secs"] = max(out["secs"], r["secs"])
        for k, v in r["counts"].items():
            out["counts"][k] = out["counts"].get(k, 0) + v
        for f in r["findings"]:
            g = by.get(f["sig"])
            if g is None:
                by[f["sig"]] = dict(f)
                continue
            g["seen"] += f["seen"]
            for k in ("widths", "heights", "themes", "states", "devices"):
                g[k] = sorted(set(g[k]) | set(f[k]))
            if not g["shot"]:
                g["shot"] = f["shot"]
    out["findings"] = sorted(by.values(), key=lambda f: (f["allowed"], f["check"], f["sig"]))
    for k in ("mode", "widths", "heights", "themes"):
        out[k] = parts[0].get(k) if parts else None
    return out


def write(out: Path, res: dict) -> list[dict]:
    (out / "findings.json").write_text(json.dumps(res, indent=1, default=sorted), encoding="utf-8")
    bad = [f for f in res["findings"] if not f["allowed"]]
    lines = [f"layout sweep ({res.get('mode')}): {res['counts'].get('measurements', 0)} measurements of {res['counts'].get('states', 0)} "
             f"states in {res['secs']} s; {len(res['findings'])} distinct findings, {len(bad)} not allowed", ""]
    by: dict[str, int] = {}
    for f in res["findings"]:
        k = f"{f['check']} ({f['kind']})" + (" [allowed]" if f["allowed"] else "")
        by[k] = by.get(k, 0) + 1
    lines += [f"  {n:4d}  {k}" for k, n in sorted(by.items())] + [""]
    for f in bad:
        w = f["widths"]
        lines.append(f"- {f['check']}: {f['detail']}")
        lines.append(f"    {f['sig']}")
        lines.append(f"    widths {w[0]}–{w[-1]} ({len(w)}), heights {f['heights']}, {'/'.join(f['themes'])}, states {', '.join(f['states'][:6])}"
                     f"{' …' if len(f['states']) > 6 else ''}; {f['shot']}")
    for n in res["notes"]:
        lines.append(f"note: {n['what']}: {n['detail']}")
    (out / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / "notes.json").write_text(json.dumps(res["notes"], indent=1), encoding="utf-8")
    return bad


def run(browser, cfg: Cfg, states: list[State] | None = None) -> dict:
    s = Sweep(browser, cfg)
    s.run(states if states is not None else states_for(cfg.mode))
    return s.result()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--origin", help="the portal's origin (default: the e2e throwaway's, from /run/e2e/env)")
    ap.add_argument("--password-file", help="a file holding the portal password (default: the throwaway's .env)")
    ap.add_argument("--code", help="the Code page's origin on the stack (default: code.<host>, if --origin was not given)")
    ap.add_argument("--no-code", action="store_true")
    ap.add_argument("--mock", help="the Code page against its mock backend (an origin)")
    ap.add_argument("--mode", choices=("fast", "full"), default=os.environ.get("LAYOUT_MODE", "fast"))
    ap.add_argument("--out", default=os.environ.get("LAYOUT_OUT", "/out/layout"))
    ap.add_argument("--only", default=os.environ.get("LAYOUT_ONLY", ""))
    ap.add_argument("--widths", default=os.environ.get("LAYOUT_WIDTHS", ""))
    ap.add_argument("--heights", default=os.environ.get("LAYOUT_HEIGHTS", ""))
    ap.add_argument("--themes", default=os.environ.get("LAYOUT_THEMES", ""))
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("LAYOUT_JOBS", "1")))
    ap.add_argument("--worker", default="", help=argparse.SUPPRESS)
    ap.add_argument("--mock-web", help="start the Code page's mock backend from this code/web folder (its dist/ and ws)")
    ap.add_argument("--static-dir")
    ap.add_argument("--har-record", default=os.environ.get("LAYOUT_HAR", ""))
    ap.add_argument("--har-replay")
    ap.add_argument("--state-dir", default=os.environ.get("LAYOUT_STATE_DIR", "/state" if Path("/state/update-check").is_dir() else ""))
    ap.add_argument("--minutes", type=float, default=float(os.environ.get("LAYOUT_MINUTES", "0")))
    ap.add_argument("--no-shots", action="store_true")
    a = ap.parse_args(argv)

    rules = ""
    if a.origin:
        origin = a.origin.rstrip("/")
        password = Path(a.password_file).read_text().strip() if a.password_file else ""
        code = None if a.no_code else (a.code.rstrip("/") if a.code else None)
    else:   # inside the e2e suite's container: the throwaway's settings
        sys.path.insert(0, str(HERE))
        from common import ENV, HOST, TARGET_IP, origin as o_of
        origin, password = o_of(), ENV["PORTAL_PASSWORD"]
        code = None if a.no_code or ENV.get("CODE_ENABLED", "true") == "false" else o_of("code")
        rules = f"MAP {HOST} {TARGET_IP}, MAP *.{HOST} {TARGET_IP}"
    mock = (a.mock or "").rstrip("/") or None
    mock_proc = None
    if a.mock_web and not a.worker:
        mock, mock_proc = start_mock(Path(a.mock_web))
        argv = list(argv if argv is not None else sys.argv[1:])
        argv = [x for i, x in enumerate(argv) if x != "--mock-web" and (i == 0 or argv[i - 1] != "--mock-web")]
        if mock:
            argv += ["--mock", mock]
    out = Path(a.out)
    if a.worker:
        out = out / "parts" / a.worker.replace("/", "-of-")
    out.mkdir(parents=True, exist_ok=True)
    cfg = Cfg(origin=origin, password=password, out=out, code=code, mock=mock, mode=a.mode,
              widths=[int(w) for w in a.widths.split(",") if w.strip()], heights=[int(h) for h in a.heights.split(",") if h.strip()],
              themes=[t for t in a.themes.split(",") if t in THEMES] or list(THEMES), only=a.only, shots=not a.no_shots,
              static_dir=Path(a.static_dir) if a.static_dir else None, har_record=Path(a.har_record) if a.har_record else None,
              har_replay=Path(a.har_replay) if a.har_replay else None, state_dir=Path(a.state_dir) if a.state_dir else None,
              deadline=time.time() + a.minutes * 60 if a.minutes else 0.0, host_rules=rules)
    states = states_for(cfg.mode)

    try:
        return sweep_main(a, argv, cfg, states, out, rules)
    finally:
        if mock_proc:
            mock_proc.terminate()


def start_mock(web: Path):
    """The Code page's mock backend (code/web/dev/mock-server.mjs) on 127.0.0.1:8195, with the Node that ships with
    Playwright's driver (as code/web/e2e/ui_check.py starts it)."""
    import playwright
    import urllib.request
    node = os.path.join(os.path.dirname(playwright.__file__), "driver", "node")
    url = "http://127.0.0.1:8195"
    proc = subprocess.Popen([node, str(web / "dev" / "mock-server.mjs"), "--port", "8195", "--host", "127.0.0.1"],
                            env=dict(os.environ, MOCK_QUIET="1"), stdout=subprocess.DEVNULL)
    for _ in range(100):
        try:
            urllib.request.urlopen(url + "/api/state", timeout=1).read()
            return url, proc
        except OSError:
            time.sleep(0.1)
    proc.terminate()
    print("the Code page's mock backend did not start: its states are left out", file=sys.stderr)
    return None, None


def sweep_main(a, argv, cfg: Cfg, states: list[State], out: Path, rules: str) -> int:
    if cfg.har_record and not a.worker:
        save_pages(cfg, out, rules)
    if a.jobs > 1 and not a.worker:
        # workers: the states dealt round-robin (each worker its own browser), then one result
        procs = []
        for i in range(a.jobs):
            cmd = [sys.executable, "-u", __file__, *[x for x in (argv if argv is not None else sys.argv[1:])], "--worker", f"{i}/{a.jobs}", "--jobs", "1"]
            procs.append(subprocess.Popen(cmd))
        rc = max(p.wait() for p in procs)
        parts = []
        for i in range(a.jobs):
            d = out / "parts" / f"{i}-of-{a.jobs}"
            try:
                parts.append(json.loads((d / "findings.json").read_text()))
            except (OSError, ValueError):
                print(f"worker {i} wrote no results", file=sys.stderr)
                rc = rc or 1
        res = merge(parts)
        for f in res["findings"]:
            if f["shot"]:
                for i in range(a.jobs):
                    src = out / "parts" / f"{i}-of-{a.jobs}" / f["shot"]
                    if src.exists():
                        dst = out / "shots" / f"{i}-{Path(f['shot']).name}"
                        (out / "shots").mkdir(exist_ok=True)
                        dst.write_bytes(src.read_bytes())
                        f["shot"] = f"shots/{dst.name}"
                        break
        bad = write(out, res)
        print(f"layout sweep: {len(res['findings'])} findings, {len(bad)} not allowed; {out}/summary.txt", flush=True)
        return rc or (1 if bad else 0)
    if a.worker:
        # (the states that share the Code page's mock backend in one worker: one resets it)
        i, n = (int(x) for x in a.worker.split("/"))
        mocks = [s for s in states if s.needs == "mock"]
        rest = [s for s in states if s.needs != "mock"]
        mine = [s for k, s in enumerate(rest) if (k + 1) % n == i]
        states = (mocks if i == 0 else []) + mine

    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        args = [f"--host-resolver-rules={rules}"] if rules else []
        browser = pw.chromium.launch(args=args)
        res = run(browser, cfg, states)
        browser.close()
    bad = write(out, res)
    print(f"layout sweep: {len(res['findings'])} findings, {len(bad)} not allowed; {out}/summary.txt", flush=True)
    return 0 if a.worker or not bad else 1


def save_pages(cfg: Cfg, out: Path, rules: str):
    """(--har-record) The portal's own pages as served, signed out and signed in: a replay (--har-replay) answers / and
    /login with these, the rest from the recorded HAR files."""
    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        b = pw.chromium.launch(args=[f"--host-resolver-rules={rules}"] if rules else [])
        c = b.new_context()
        p = c.new_page()
        (out / "page-login.html").write_bytes(c.request.get(cfg.origin + "/login").body())
        p.goto(cfg.origin + "/login")
        p.fill("#password", cfg.password)
        p.click("form[action='/login'] button[type=submit]")
        p.wait_for_selector(".shell")
        r = c.request.get(cfg.origin + "/")
        (out / "page-index.html").write_bytes(r.body())
        # (the sign-in page saying a password was wrong: a new context, so the session above is not signed out)
        c2 = b.new_context()
        r = c2.request.post(cfg.origin + "/login", form={"password": "not the password", "next": "/"}, headers={"Origin": cfg.origin}, max_redirects=0)
        (out / "page-login-wrong.html").write_bytes(r.body())
        b.close()


if __name__ == "__main__":
    sys.exit(main())
