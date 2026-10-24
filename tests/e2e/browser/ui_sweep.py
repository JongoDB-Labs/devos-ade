"""UI/UX sweep of a throwaway stack (tests/e2e/ui-sweep.sh runs it in the e2e suite's Playwright container): every page
and state of the portal, Chat, the Code page and the terminal, at three widths and in both themes — screenshots, and
what is broken: console errors and warnings, failed or refused requests and CSP violations, broken images and icons,
the logo (the mark this checkout ships), visible text naming the old product name, layout (sideways scroll, controls
cut off or covered, empty cards, unnamed controls), and every link (internal: answered; in-page: there; external: a GET,
paced). Writes /out/sweep: shots/<page>-<state>-<width>-<theme>.png, findings.json, findings.tsv, summary.txt.

Reads only; the states it fakes are the browser's own (a rewritten page, a dispatched event) or the update check's
answer file (/state/update-check/latest.json, put back afterwards)."""

from __future__ import annotations

import hashlib
import json
import os
import re
import struct
import sys
import time
import traceback
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urldefrag, urlsplit

from playwright.sync_api import Error as PwError
from playwright.sync_api import sync_playwright

from common import ENV, HOST, PORT, TARGET_IP, origin, redact

sys.path.insert(0, "/repo/tests")
import brand_check  # noqa: E402 — the repository's allowlist of internal names (docs/internal-names.md)

OUT = Path("/out/sweep")
SHOTS = OUT / "shots"
SHOTS.mkdir(parents=True, exist_ok=True)
REPO, STACK = Path("/repo"), Path("/stack")
STATE = Path("/state")
WIDTHS = {
    "desktop": {"viewport": {"width": 1512, "height": 900}},
    "tablet": {"viewport": {"width": 820, "height": 1180}, "is_mobile": True, "has_touch": True, "device_scale_factor": 2,
               "user_agent": "Mozilla/5.0 (Linux; Android 14; Pixel Tablet) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"},
    "phone": {"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True, "device_scale_factor": 2,
              "user_agent": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"},
}
ONLY_WIDTHS = [w for w in os.environ.get("SWEEP_WIDTHS", "desktop,tablet,phone").split(",") if w in WIDTHS]
THEMES = [t for t in os.environ.get("SWEEP_THEMES", "light,dark").split(",") if t in ("light", "dark")]
# SWEEP_ONLY=code,off_pages,…: just those parts (signin portal off_pages walkthrough code errors manifest links); all when empty
ONLY = {x for x in os.environ.get("SWEEP_ONLY", "").split(",") if x}


def wanted(part: str) -> bool:
    return not ONLY or part in ONLY
CODE = origin("code")
TERM = origin("terminal")
PORTAL_TABS = {"home", "chat", "code", "admin", "files", "settings", "terminal"}
NEW_LOGO = os.environ.get("SWEEP_NEW_LOGO_SHA", "")
# The throwaway's folder on this computer (the sign-in hint names its .env, Settings its workspace): a path of the
# machine running the sweep, whatever its folders are called — taken out before the text is checked
STACK_PATH = os.environ.get("SWEEP_STACK_PATH", "")
HOME_PATH = os.environ.get("SWEEP_HOME", "")
OUR_HOSTS = {HOST, f"code.{HOST}", f"terminal.{HOST}"}   # (the layout checks: our pages, not Open WebUI's, LiteLLM's, RustFS's)


def local_paths_out(text: str) -> str:
    if STACK_PATH:
        parent = STACK_PATH.rsplit("/", 1)[0]
        text = text.replace(parent, "<work>")
        if HOME_PATH and parent.startswith(HOME_PATH + "/"):
            text = text.replace("~" + parent[len(HOME_PATH):], "<work>")
    return text
OLD_LOGO = os.environ.get("SWEEP_OLD_LOGO_SHA", "")

FINDINGS: list[dict] = []
LINKS: dict[str, dict] = {}       # url -> {where, text}
IMAGES: dict[str, dict] = {}      # url -> {where}
CUR = {"page": "-", "state": "-", "width": "-", "theme": "-"}
COUNTS: dict[str, int] = {}


def where() -> str:
    return f"{CUR['page']}/{CUR['state']} {CUR['width']} {CUR['theme']}"


def find(check: str, detail: str, **extra):
    FINDINGS.append({"check": check, **CUR, "detail": redact(str(detail))[:600], **{k: redact(v) for k, v in extra.items()}})


def count(check: str, n: int = 1):
    COUNTS[check] = COUNTS.get(check, 0) + n


CSP_GUARD = """(() => { try { window.__csp = []; document.addEventListener('securitypolicyviolation', (e) =>
  window.__csp.push(e.violatedDirective + ' ' + (e.blockedURI || '') + ' ' + (e.sample || '').slice(0, 80))); } catch (e) {} })();"""

COLLECT = r"""() => {
  const clipped = (e, r) => { const x = r.left + r.width / 2, y = r.top + r.height / 2;
    for (let p = e.parentElement; p && p !== document.documentElement; p = p.parentElement) { const s = getComputedStyle(p);
      if (/(auto|scroll|hidden|clip)/.test(s.overflowX + s.overflowY)) { const q = p.getBoundingClientRect(); if (x < q.left || x > q.right || y < q.top || y > q.bottom) return true; } }
    return false; };
  const vis = (e) => { if (!e || !e.getBoundingClientRect) return false; const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
    if (e.checkVisibility && !e.checkVisibility({ contentVisibilityAuto: true, opacityProperty: true, visibilityProperty: true })) return false;
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity || '1') > 0.05 && !clipped(e, r); };
  const desc = (e) => { const id = e.id ? '#' + e.id : ''; const t = e.getAttribute('data-testid') ? `[data-testid=${e.getAttribute('data-testid')}]` : '';
    const c = (e.className && typeof e.className === 'string') ? '.' + e.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
    return (e.tagName.toLowerCase() + id + t + c + ' "' + ((e.innerText || e.value || '').trim().replace(/\s+/g, ' ').slice(0, 40)) + '"'); };
  const accname = (e) => {
    const al = e.getAttribute('aria-label'); if (al && al.trim()) return al;
    const lb = e.getAttribute('aria-labelledby'); if (lb) { const t = lb.split(/\s+/).map(i => (document.getElementById(i) || {}).textContent || '').join(' ').trim(); if (t) return t; }
    if (e.labels && e.labels.length && [...e.labels].some(l => l.textContent.trim())) return 'label';
    const t = (e.innerText || '').trim(); if (t) return t;
    if (e.title && e.title.trim()) return e.title;
    if (['submit', 'button', 'reset'].includes(e.type) && e.value) return e.value;
    if (e.placeholder) return e.placeholder;
    const img = e.querySelector && e.querySelector('img[alt]:not([alt=""]), svg title'); if (img) return img.alt || img.textContent;
    return ''; };
  const W = window.innerWidth;
  const scroller = (e) => { for (let p = e.parentElement; p && p !== document.body; p = p.parentElement) { const o = getComputedStyle(p).overflowX; if (o === 'auto' || o === 'scroll' || o === 'hidden' || o === 'clip') return true; } return false; };
  const inter = [...document.querySelectorAll('button, [role=button], a[href], input:not([type=hidden]), select, textarea, summary')];
  const shown = inter.filter(vis);
  const dialogs = [...document.querySelectorAll('dialog[open], [role=dialog]:not([hidden]), .sheet:not([hidden]), #tour:not([hidden]), [role=menu], [role=listbox]')].filter(vis);
  const top = dialogs.length ? dialogs[dialogs.length - 1] : null;
  const covered = [];
  for (const e of shown) {
    if (top && !top.contains(e)) continue;
    const r = e.getBoundingClientRect(); if (r.top < 0 || r.left < 0 || r.bottom > innerHeight || r.right > W || r.width < 4 || r.height < 4) continue;
    const x = r.left + r.width / 2, y = r.top + r.height / 2; const t = document.elementFromPoint(x, y);
    if (t && t !== e && !e.contains(t) && !t.contains(e) && !(t.closest && t.closest('[role=tooltip], .toast, .tooltip'))) covered.push(desc(e) + ' under ' + desc(t));
  }
  // Past its box: a run of text whose line boxes end outside the nearest box around it (a card, a dialog, a note, a code
  // chip: an ancestor with a border, a background or a shadow), or an in-flow element wider than that box; a scroller
  // on the way (overflow auto, scroll, hidden, clip) ends the search, as its content may be wider by design.
  const memo = new Map();
  const kind = (e) => { if (memo.has(e)) return memo.get(e); const s = getComputedStyle(e); let k = '';
    if (/(auto|scroll|hidden|clip)/.test(s.overflowX)) k = 'scroll';
    else if (s.display !== 'inline' && s.display !== 'contents' && (e.tagName === 'DIALOG' || e.getAttribute('role') === 'dialog'
      || parseFloat(s.borderLeftWidth) > 0 || parseFloat(s.borderRightWidth) > 0 || s.boxShadow !== 'none'
      || !/^(transparent|rgba\(0, 0, 0, 0\))$/.test(s.backgroundColor))) k = 'box';
    memo.set(e, k); return k; };
  const boxOf = (e) => { for (let p = e; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
    const k = kind(p); if (k === 'scroll') return null; if (k === 'box') return p; } return null; };
  const spill = [], spilt = new Set();
  const tw = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT,
    { acceptNode: (n) => (n.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT) });
  for (let n = tw.nextNode(); n && spill.length < 30; n = tw.nextNode()) {
    const el = n.parentElement; if (!el || spilt.has(el) || ['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'OPTION'].includes(el.tagName)) continue;
    const box = boxOf(el); if (!box) continue;
    const range = document.createRange(); range.selectNodeContents(n);
    const b = box.getBoundingClientRect();
    const r = [...range.getClientRects()].find((q) => q.width > 0 && (q.right > b.right + 1 || q.left < b.left - 1));
    if (r && vis(el)) { spilt.add(el); spill.push(`${desc(el)} runs ${Math.round(Math.max(r.right - b.right, b.left - r.left))} px past ${desc(box)}`); }
  }
  for (const e of document.querySelectorAll('body *')) {
    if (spill.length >= 30) break;
    const s = getComputedStyle(e); if (s.position === 'absolute' || s.position === 'fixed' || s.display === 'inline' || s.display === 'contents' || s.float !== 'none') continue;
    const box = e.parentElement && boxOf(e.parentElement); if (!box) continue;
    const r = e.getBoundingClientRect(), b = box.getBoundingClientRect();
    if (r.width > 0 && (r.right > b.right + 1 || r.left < b.left - 1) && !spilt.has(e) && vis(e)) {
      spilt.add(e); spill.push(`${desc(e)} is ${Math.round(Math.max(r.right - b.right, b.left - r.left))} px wider than ${desc(box)}`); }
  }
  const bgs = new Set();
  for (const e of document.querySelectorAll('body *')) { const b = getComputedStyle(e).backgroundImage;
    if (b && b.includes('url(')) for (const m of b.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/g)) { try { bgs.add(new URL(m[1], location.href).href); } catch (_) {} } }
  return {
    url: location.href, title: document.title, text: (document.title || '') + '\n' + (document.body ? document.body.innerText : ''),
    imgs: [...document.images].map(i => ({ src: i.currentSrc || i.src, nw: i.naturalWidth, complete: i.complete, vis: vis(i), alt: i.getAttribute('alt') })),
    bgs: [...bgs],
    links: [...document.querySelectorAll('a[href]')].map(a => ({ href: a.href, raw: a.getAttribute('href'), text: (a.innerText || a.getAttribute('aria-label') || a.title || '').trim().slice(0, 80), vis: vis(a) })),
    icons: [...document.querySelectorAll('link[rel~=icon], link[rel=apple-touch-icon], link[rel=manifest]')].map(l => ({ rel: l.rel, href: l.href, sizes: l.getAttribute('sizes') })),
    unnamed: shown.filter(e => !accname(e)).map(desc).slice(0, 40),
    overflow: document.scrollingElement ? document.scrollingElement.scrollWidth - W : 0,
    outside: shown.filter(e => { const r = e.getBoundingClientRect(); return (r.right > W + 2 || r.left < -2) && !scroller(e); }).map(desc).slice(0, 30),
    covered: covered.slice(0, 30),
    spill,
    empty: [...document.querySelectorAll('section, .card, [class*="-card"]')].filter(vis).filter(e => !e.innerText.trim() && !e.querySelector('img, svg, canvas, iframe, video, input, textarea')).map(desc).slice(0, 20),
    brand: (() => { const i = document.querySelector('.brand img'); return i ? { src: i.currentSrc || i.src, vis: vis(i), nw: i.naturalWidth } : null; })(),
    csp: (window.__csp || []).slice(0, 30),
    ids: [...document.querySelectorAll('[id], a[name]')].map(e => e.id || e.getAttribute('name')).slice(0, 5000),
  };
}"""


def frames_of(page, hosts: tuple[str, ...] = ()):
    out = [page.main_frame]
    for f in page.frames:
        if f is page.main_frame or not f.url or f.url.startswith(("about:", "data:", "blob:")):
            continue
        if not hosts or urlsplit(f.url).hostname in hosts:
            out.append(f)
    return out


def shot(page, name: str, full: bool = True):
    fn = SHOTS / f"{CUR['page']}-{name}-{CUR['width']}-{CUR['theme']}.png".replace("/", "_")
    try:
        page.screenshot(path=str(fn), full_page=full, timeout=30000)
    except PwError:
        try:
            page.screenshot(path=str(fn), full_page=False, timeout=30000)
        except PwError as e:
            find("screenshot", f"{name}: {e}")
    count("screenshots")


def capture(page, state: str, full: bool = True, frame_hosts: tuple[str, ...] = (), shot_it: bool = True):
    """Screenshot PAGE, then check its document and the frames of FRAME_HOSTS."""
    CUR["state"] = state
    page.wait_for_timeout(400)
    if shot_it:
        shot(page, state, full)
    for f in frames_of(page, frame_hosts):
        try:
            d = f.evaluate(COLLECT)
        except PwError as e:
            find("collect", f"{f.url[:120]}: {str(e)[:200]}")
            continue
        top = f is page.main_frame
        label = f"{CUR['page']}/{state}" + ("" if top else f" (frame {urlsplit(d['url']).hostname})")
        count("documents checked")
        # visible text naming the old product name (beyond the internal names the allowlist names)
        for hit in brand_check.check_text(REPO, label, local_paths_out(d["text"])):
            find("old name in visible text", hit, frame=d["url"][:120])
        count("text checks")
        for i in d["imgs"]:
            if not i["src"] or i["src"].startswith("data:"):
                continue
            IMAGES.setdefault(i["src"], {"where": where()})
            if i["complete"] and i["nw"] == 0 and i["vis"]:
                find("broken image", f"{i['src'][:160]} (alt {i['alt']!r})", frame=d["url"][:120])
        for b in d["bgs"]:
            if not b.startswith("data:"):
                IMAGES.setdefault(b, {"where": where(), "bg": True})
        for ic in d["icons"]:
            IMAGES.setdefault(ic["href"], {"where": where(), "icon": ic["rel"]})
        for ln in d["links"]:
            href = ln["href"]
            if href.startswith(("javascript:", "mailto:", "blob:", "data:")):
                continue
            base, frag = urldefrag(href)
            if frag and base == urldefrag(d["url"])[0]:
                count("in-page anchors")
                tabs = top and urlsplit(d["url"]).hostname == HOST and (frag in PORTAL_TABS or frag.startswith(("settings", "code", "terminal")))
                if not tabs and frag not in d["ids"]:
                    find("in-page anchor missing", f"#{frag} ({ln['text']!r})", frame=d["url"][:120])
                continue
            LINKS.setdefault(href, {"where": where(), "text": ln["text"]})
        ours = urlsplit(d["url"]).hostname in OUR_HOSTS
        if top and CUR["width"] == "phone" and d["overflow"] > 2:
            find("sideways scroll at phone width", f"{d['overflow']} px wider than the viewport")
        for x in d["outside"] if ours else []:
            find("cut off", x, frame=d["url"][:120])
        for x in d["covered"] if ours else []:
            find("covered", x, frame=d["url"][:120])
        for x in d["spill"] if ours else []:
            find("past its box", local_paths_out(x), frame=d["url"][:120])
        for x in d["empty"] if ours else []:
            find("empty container", x, frame=d["url"][:120])
        for x in d["unnamed"] if ours else []:
            find("no accessible name", x, frame=d["url"][:120])
        for x in d["csp"]:
            find("CSP violation", x, frame=d["url"][:120])
        if top and urlsplit(d["url"]).hostname == HOST and CUR["page"] not in ("error",):
            check_logo(d)


LOGO_SEEN: dict[str, str] = {}


def check_logo(d):
    b = d["brand"]
    if not b:
        if CUR["page"] in ("portal", "signin"):
            find("logo missing", f"no .brand img on {d['url'][:100]}")
        return
    count("logos checked")
    if not b["vis"] and not (CUR["width"] == "phone" and CUR["page"] in ("portal", "walkthrough")):   # (phones: the sidebar is the tab bar)
        find("logo not visible", b["src"])
    if b["nw"] == 0:
        find("logo broken", b["src"])
    LOGO_SEEN.setdefault(b["src"], where())


def attach(ctx):
    def on_console(m):
        if m.type in ("error", "warning"):
            t, u = m.text, (m.location or {}).get("url", "")
            if CUR["page"] == "error" or (" 401 " in t and urlsplit(u).hostname in (f"code.{HOST}", f"terminal.{HOST}")) \
                    or (CUR["state"] == "wrong-password" and " 401 " in t):
                return   # (locked until unlocked: the unlock page; a deliberate refusal)
            third = urlsplit(u).hostname not in OUR_HOSTS if u else False
            find("console " + m.type + (" (third-party app)" if third else ""), t[:400], url=u[:160])
    ctx.on("console", on_console)

    def on_response(r):
        try:
            st = r.status
        except Exception:  # noqa: BLE001
            return
        # (the deliberate ones: the error and refusal pages, a wrong password)
        locked = st == 401 and urlsplit(r.url).hostname in (f"code.{HOST}", f"terminal.{HOST}") and urlsplit(r.url).path in ("/", "")
        if st >= 400 and CUR["page"] != "error" and not locked and not (CUR["state"] == "wrong-password" and st == 401):
            find(f"HTTP {st}", f"{r.request.method} {r.url[:200]}")

    ctx.on("response", on_response)

    def on_failed(rq):
        err = rq.failure or ""
        if "ERR_ABORTED" in err:
            return   # (a load the page itself ended: switching tabs or pages, a frame given a new address)
        find("request failed", f"{rq.method} {rq.url[:200]}: {err}")
    ctx.on("requestfailed", on_failed)


def new_ctx(browser, width, theme, tour=False):
    c = browser.new_context(locale="en-US", timezone_id="UTC", color_scheme=theme, **WIDTHS[width])
    c.add_init_script(CSP_GUARD)
    if not tour:
        c.add_init_script("(o => { try { if (location.origin === o && !localStorage.getItem('bn.tour')) "
                          "localStorage.setItem('bn.tour', JSON.stringify({open: false})); } catch (e) {} })"
                          f"({json.dumps(origin())});")
    attach(c)
    p = c.new_page()
    p.set_default_timeout(30000)
    return c, p


def login(page):
    page.goto(origin() + "/")
    page.wait_for_url(re.compile(r"/login"))
    page.fill("#password", ENV["PORTAL_PASSWORD"])
    page.click("form[action='/login'] button[type=submit]")
    page.wait_for_selector(".shell")


def step(name, fn, *a):
    """One state: its failure is a finding (the state could not be reached), never the end of the sweep."""
    try:
        fn(*a)
    except Exception as e:  # noqa: BLE001
        find("state not reached", f"{name}: {type(e).__name__}: {str(e).splitlines()[0][:300]}")
        (OUT / "tracebacks.txt").open("a").write(f"--- {where()} {name}\n{traceback.format_exc()}\n")


# --- the portal ---

def sweep_signin(browser, width, theme):
    c, p = new_ctx(browser, width, theme)
    CUR["page"] = "signin"
    p.goto(origin() + "/login")
    p.wait_for_selector("#password")
    capture(p, "default")
    CUR["state"] = "wrong-password"
    p.fill("#password", "not the password")
    p.click("form[action='/login'] button[type=submit]")
    p.wait_for_selector(".error, [role=alert]", timeout=15000)
    capture(p, "wrong-password")
    c.close()


def home_ready(p):
    p.goto(origin() + "/#home")
    p.wait_for_selector("#home:not([hidden])")
    p.wait_for_timeout(2500)


def write_latest(rec):
    path = STATE / "update-check" / "latest.json"
    tmp = path.with_name(".latest.json.sweep")
    tmp.write_text(json.dumps(rec))
    tmp.chmod(0o644)
    tmp.replace(path)


def sweep_portal(browser, width, theme):
    c, p = new_ctx(browser, width, theme)
    CUR["page"] = "portal"
    login(p)
    home_ready(p)
    step("home", capture, p, "home")
    # the update card's states (the update check's answer file, put back afterwards)
    up = STATE / "update-check" / "latest.json"
    saved = up.read_bytes() if up.exists() else None
    now = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
    try:
        inst = json.loads((STATE / "status" / "version.json").read_text()).get("version", "v0.0.0")
    except Exception:  # noqa: BLE001
        inst = "v0.0.0"
    rels = [{"tag": t, "name": f"{t} — {h}", "headline": h, "notes": f"## {t}\n- **sweep** release {t}", "published_at": now,
             "url": f"https://github.com/JongoDB-Labs/devos-ade/releases/tag/{t}"}
            for t, h in (("v99.0.0", "the newest test release"), ("v98.0.0", "a test release in between"))]
    states = {
        "update-available": {"tag": "v99.0.0", "name": "v99.0.0", "notes": rels[0]["notes"], "url": rels[0]["url"], "published_at": now,
                             "checked_at": now, "error": None, "images": [], "releases": rels},
        "update-uptodate": {"tag": inst.split("-")[0], "name": inst, "notes": "", "url": "", "published_at": now, "checked_at": now,
                            "error": None, "images": [], "releases": []},
        "update-could-not-check": {"checked_at": now, "error": "api.github.com did not answer (ConnectError)", "error_at": now},
        "update-rate-limited": {"checked_at": now, "error": "api.github.com refused: its limit of requests for this address is used up (HTTP 403)",
                                "error_at": now, "refused": True, "limited": True, "retry_at": now},
    }
    try:
        for name, rec in states.items():
            def one(name=name, rec=rec):
                write_latest(rec)
                p.click("#refresh") if p.locator("#refresh").is_visible() else p.reload()
                p.wait_for_timeout(2500)
                if name == "update-available":
                    p.locator("#update-card:not([hidden])").wait_for(timeout=15000)
                    p.locator("#update-card").scroll_into_view_if_needed()
                capture(p, name)
            step(name, one)
    finally:
        if saved is None:
            up.unlink(missing_ok=True)
        else:
            up.write_bytes(saved)
    # Install app offered (what Chrome does when the app becomes installable)
    def install():
        home_ready(p)
        p.evaluate("""() => { const e = new Event('beforeinstallprompt'); e.prompt = () => {};
            e.userChoice = Promise.resolve({outcome: 'dismissed'}); e.preventDefault = () => {}; window.dispatchEvent(e); }""")
        p.wait_for_timeout(800)
        capture(p, "install-offered")
    step("install-offered", install)

    def activity():
        home_ready(p)
        if width == "phone":
            p.click("#more-btn")
            p.wait_for_selector("#more-sheet:not([hidden])")
            capture(p, "more-sheet", full=False)
            p.click("#more-activity")
        else:
            p.click("#activity-btn")
        p.wait_for_selector("#activity:not([hidden])", timeout=10000)
        capture(p, "activity", full=False)
        p.keyboard.press("Escape")
    step("activity", activity)

    def search():
        home_ready(p)
        if width == "phone":
            p.click("#more-btn")
            p.wait_for_selector("#more-sheet:not([hidden])")
            p.click("#more-search")
        else:
            p.click("#search-btn")
        p.wait_for_selector("#search[open]", timeout=10000)
        capture(p, "search-open", full=False)
        for q in ("update", "rename", "workspace", "DevOS"):
            p.keyboard.press("Control+a")
            p.keyboard.type(q)
            p.wait_for_timeout(1200)
            capture(p, f"search-{q.lower()}", full=False)
        p.keyboard.press("Escape")
    step("search", search)

    def settings():
        p.goto(origin() + "/#settings")
        p.wait_for_selector("#settings:not([hidden]) .set-nav-item", state="attached", timeout=30000)
        p.wait_for_timeout(1500)
        capture(p, "settings")
        ids = p.eval_on_selector_all(".set-nav-item", "bs => bs.map(b => b.dataset.section)")
        count("settings sections", len(ids))
        for s in ids:
            def one(s=s):
                if p.locator("#set-picker").is_visible():   # (phones: the section picker)
                    p.select_option("#set-picker", s)
                else:
                    p.evaluate("s => document.querySelector(`.set-nav-item[data-section=\"${s}\"]`).click()", s)
                p.wait_for_timeout(600)
                p.evaluate("s => { const c = document.getElementById('set-' + s); if (c) c.querySelectorAll('details').forEach(d => d.open = true); }", s)
                p.wait_for_timeout(300)
                capture(p, f"settings-{s}")
            step(f"settings-{s}", one)
    step("settings", settings)

    def chat():
        p.goto(origin() + "/#chat")
        p.wait_for_selector("iframe[data-app=chat]", timeout=20000)
        fl = p.frame_locator("iframe[data-app=chat]")
        fl.locator("#chat-input").wait_for(timeout=60000)
        p.wait_for_timeout(1500)
        capture(p, "chat", full=False, frame_hosts=(f"chat.{HOST}",))
        opts = p.eval_on_selector_all("#answers-chat option", "os => os.map(o => [o.textContent.trim(), o.disabled])") \
            if p.locator("#answers-chat").count() else []
        (OUT / f"who-answers-{width}-{theme}.json").write_text(json.dumps(opts, indent=1))
        count("who answers entries", len(opts))
        for text, _ in opts:
            for hit in brand_check.check_text(REPO, "who-answers", text):
                find("old name in visible text", hit)
        try:
            fl.locator("#model-selector-model-button").click(timeout=15000)
            p.wait_for_timeout(1200)
            capture(p, "chat-model-menu", full=False, frame_hosts=(f"chat.{HOST}",))
            p.keyboard.press("Escape")
        except PwError as e:
            find("state not reached", f"chat model menu: {str(e).splitlines()[0][:200]}")
    step("chat", chat)

    for tab, sub in (("admin", "admin"), ("files", "files")):
        if width == "phone":
            continue   # (phones open Admin and Files in a tab of their own, not in a frame of the portal)

        def app(tab=tab, sub=sub):
            p.goto(origin() + f"/#{tab}")
            p.wait_for_selector(f"iframe[data-app={tab}]", timeout=20000)
            p.wait_for_timeout(8000)
            capture(p, tab, full=False, frame_hosts=(f"{sub}.{HOST}",))
        step(tab, app)

    def terminal():
        if width == "phone":
            return   # (phones: the portal has no Terminal tab; mobile.js shows Chat instead)
        p.goto(origin() + "/#terminal")
        p.wait_for_selector("iframe[data-app=terminal]", timeout=20000)
        f = None
        for _ in range(60):
            f = next((fr for fr in p.frames if fr.url.startswith(TERM)), None)
            if f:
                break
            p.wait_for_timeout(500)
        if f is None:
            raise AssertionError("no terminal frame")
        f.locator("h1", has_text="Unlock the terminal").wait_for(timeout=20000)
        capture(p, "terminal-unlock", full=False, frame_hosts=(f"terminal.{HOST}",))
        f.fill("#password", ENV["PORTAL_PASSWORD"])
        f.click("form[action='/.bn/unlock'] button[type=submit]")
        p.wait_for_timeout(1500)
        f = next((fr for fr in p.frames if fr.url.startswith(TERM)), f)
        f.locator(".xterm").wait_for(timeout=40000)
        p.wait_for_timeout(3000)
        capture(p, "terminal", full=False, frame_hosts=(f"terminal.{HOST}",))
    step("terminal", terminal)

    def code_tab():
        if width == "phone":
            return   # (phones: no Code tab in the portal either; the Code page is swept on its own host)
        p.goto(origin() + "/#code")
        p.wait_for_selector("iframe[data-app=code]", timeout=20000)
        p.wait_for_timeout(4000)
        capture(p, "code-tab", full=False, frame_hosts=(f"code.{HOST}",))
    step("code-tab", code_tab)
    c.close()


def sweep_off_pages(browser, width, theme):
    """The Code tab's and the terminal's off pages: Home's own page with its bn-code / bn-terminal state saying off."""
    c, p = new_ctx(browser, width, theme)
    CUR["page"] = "portal"
    login(p)

    def rewrite(route):
        r = route.fetch()
        body = r.text()
        body = re.sub(r'<meta name="bn-code" content="[^"]*">', '<meta name="bn-code" content="{}">', body)
        body = re.sub(r'<meta name="bn-terminal" content="[^"]*">', '<meta name="bn-terminal" content="{}">', body)
        route.fulfill(response=r, body=body)
    p.route(lambda u: u.startswith(origin() + "/") and urlsplit(u).path == "/", rewrite)
    for tab in ("code", "terminal"):
        def one(tab=tab):
            p.goto(origin() + f"/?sweep={tab}-off#{tab}")
            p.wait_for_timeout(2500)
            capture(p, f"{tab}-off")
        step(f"{tab}-off", one)
    c.close()


def sweep_walkthrough(browser, width, theme):
    c, p = new_ctx(browser, width, theme, tour=True)
    CUR["page"] = "walkthrough"
    c.add_init_script("(o => { try { if (location.origin === o && !sessionStorage.getItem('sweep.tour')) { sessionStorage.setItem('sweep.tour', '1');"
                      " localStorage.setItem('bn.tour', JSON.stringify({open: true, cur: 'welcome'})); } } catch (e) {} })"
                      f"({json.dumps(origin())});")
    login(p)
    home_ready(p)
    if p.locator("#tour:not([hidden])").count() == 0:
        if width == "phone":
            p.click("#more-btn")
            p.wait_for_selector("#more-sheet:not([hidden])")
            p.click("#more-tour")
        else:
            p.click("#tour-btn")
    p.wait_for_selector("#tour:not([hidden]) #tour-cur", timeout=15000)
    seen = []
    for _ in range(80):
        cur = p.evaluate("() => { const c = document.querySelector('#tour .tour-step.cur'); return c ? c.dataset.step : '' }") or f"n{len(seen)}"
        if cur in seen:
            break
        seen.append(cur)
        p.wait_for_timeout(500)
        capture(p, f"step-{len(seen):02d}-{cur}", full=False)
        nxt = p.locator("#tour [data-k=next]")
        if nxt.count() == 0 or not nxt.first.is_visible() or nxt.first.inner_text().strip() == "Finish":
            break
        nxt.first.click()
        p.wait_for_timeout(700)
        if not p.url.startswith(origin()):   # (a step that opened another page: back to the portal)
            p.goto(origin() + "/#home")
    count("walkthrough steps", len(seen))
    c.close()


# --- the Code page (its own host, unlocked) ---

def code_open(browser, width, theme):
    c, p = new_ctx(browser, width, theme)
    login(p)
    p.goto(CODE + "/")
    p.locator("h1", has_text="Unlock the Code page").wait_for(timeout=20000)
    CUR["page"] = "code"
    capture(p, "unlock")
    p.fill("#password", ENV["PORTAL_PASSWORD"])
    p.click("form[action='/.bn/unlock'] button[type=submit]")
    p.get_by_test_id("conn").wait_for(timeout=30000)
    p.wait_for_function("() => { const c = document.querySelector('[data-testid=conn]'); return c && /Connected/.test(c.textContent) }", timeout=40000)
    p.wait_for_timeout(1500)
    return c, p


def esc(p, n=2):
    for _ in range(n):
        p.keyboard.press("Escape")
        p.wait_for_timeout(200)


def menu(p, width, item):
    """Open a ⋯ menu entry (desktop/tablet) or the phone's menu entry."""
    if width == "phone" and p.get_by_test_id("phone-menu-btn").count():
        p.get_by_test_id("phone-menu-btn").click()
        p.wait_for_timeout(400)
        it = p.get_by_test_id(f"phone-menu-{item}")
    else:
        p.get_by_test_id("more-menu").click()
        p.wait_for_timeout(300)
        it = p.get_by_test_id(f"menu-{item}")
    if it.count() == 0:   # (an entry this width's menu does not have)
        esc(p, 2)
        return False
    it.first.click()
    p.wait_for_timeout(1200)
    return True


def code_fresh(p):
    """The Code page as it opens (a dialog left open by one state never covers the next)."""
    p.goto(CODE + "/")
    p.wait_for_function("() => { const c = document.querySelector('[data-testid=conn]'); return c && /Connected/.test(c.textContent) }", timeout=40000)
    p.wait_for_timeout(1200)


def sweep_code(browser, width, theme):
    c, p = code_open(browser, width, theme)
    capture(p, "page")

    def projects():
        code_fresh(p)
        if width == "phone":
            menu(p, width, "projects")
        else:
            p.get_by_test_id("side-sessions").click()
        p.wait_for_timeout(1200)
        capture(p, "projects")
        row = p.get_by_test_id("project").filter(has_text="ui-sweep")
        if not row.count():
            find("state not reached", "trust dialog: the seed project ui-sweep is not listed")
            return
        if row.first.get_by_test_id("project-new-session").count() == 0 and row.first.get_by_test_id("project-toggle").count():
            row.first.get_by_test_id("project-toggle").click()
            p.wait_for_timeout(600)
        row.first.get_by_test_id("project-new-session").click()
        p.get_by_test_id("settings-dialog").wait_for(timeout=15000)
        p.wait_for_timeout(800)
        capture(p, "trust-dialog")
    step("projects", projects)

    def files():
        code_fresh(p)
        sf = p.get_by_test_id("side-files")
        if sf.count() and sf.first.is_visible():
            sf.first.click()
        elif p.get_by_role("button", name="Files").count():
            p.get_by_role("button", name="Files").first.click()
        else:
            find("state not reached", "files: no Explorer or Files at this width")
            return
        p.wait_for_timeout(1000)
        capture(p, "files")
        row = p.get_by_test_id("file-tree").get_by_text("ui-sweep", exact=True)
        if row.count():
            row.first.click()
            p.wait_for_timeout(800)
            f = p.get_by_test_id("file-tree").get_by_text("README.md", exact=True)
            if f.count():
                f.first.click()
                p.wait_for_timeout(2000)
                capture(p, "file-open")
    step("files", files)

    def git():
        code_fresh(p)
        if width == "phone":
            menu(p, width, "git")
        else:
            p.keyboard.press("Control+Shift+G")
        p.get_by_test_id("git-panel").wait_for(timeout=15000)
        p.wait_for_timeout(1200)
        capture(p, "git-panel")
        hosts = p.get_by_test_id("git-hosts-open")
        if hosts.count():
            hosts.first.click()
            p.wait_for_timeout(1500)
            capture(p, "git-hosts")
            dlg = p.get_by_role("dialog").filter(has_text="Git hosts").last
            add = dlg.get_by_role("button", name=re.compile(r"Connect a git host", re.I))
            if add.count():
                add.first.click()
                p.wait_for_timeout(1200)
                capture(p, "git-host-connect")
                apps = [u for u in LINKS if "github.com/apps/" in u]
                (OUT / "app-links.txt").open("a").write("".join(f"{where()} {u}\n" for u in apps))
    step("git", git)

    def term():
        code_fresh(p)
        t = p.get_by_test_id("toggle-terminal")
        if t.count() and t.first.is_visible():
            t.first.click()
            p.wait_for_timeout(5000)
            capture(p, "terminal-panel", full=False, frame_hosts=(f"terminal.{HOST}",))
        elif width != "phone":   # (phones: the Session sheet's "Open the terminal" opens a tab of its own)
            find("state not reached", "the terminal panel: no toggle-terminal at this width")
    step("terminal-panel", term)

    def model():
        code_fresh(p)
        if width == "phone":
            p.get_by_test_id("phone-menu-btn").click()
            p.wait_for_timeout(400)
            p.get_by_test_id("phone-menu").get_by_test_id("model-picker").first.click()
        else:
            p.get_by_test_id("model-picker").first.click()
        p.wait_for_timeout(1200)
        capture(p, "model-picker")
    step("model-picker", model)

    for item in ("palette", "new-project", "review", "run", "ports", "budget", "permissions", "memory", "mcp", "plugins", "setup", "notify", "export"):
        def one(item=item):
            code_fresh(p)
            if menu(p, width, item):
                capture(p, f"menu-{item}")
        step(f"menu-{item}", one)
    c.close()


# --- error and refusal pages ---

def sweep_errors(browser, width, theme):
    c, p = new_ctx(browser, width, theme)
    CUR["page"] = "error"
    login(p)
    for name, url in (("portal-404", origin() + "/no-such-page"), ("unknown-host", f"http://nosuch.{HOST}:{PORT}/"),
                      ("code-host-signed-out", CODE + "/"), ("chat-host-signed-out", origin("chat") + "/")):
        def one(name=name, url=url):
            if name.endswith("signed-out"):
                c2, p2 = new_ctx(browser, width, theme)
                p2.goto(url)
                p2.wait_for_timeout(1500)
                capture(p2, name)
                c2.close()
                return
            try:
                p.goto(url)
            except PwError as e:
                find("page failed", f"{name}: {str(e).splitlines()[0][:200]}")
            p.wait_for_timeout(1200)
            capture(p, name)
        step(name, one)
    # Caddy's refusals (a cross-site request to an app's host): their body text
    for name, url, hdr in (("same-site-guard", origin("chat") + "/api/config", {"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "cors", "Origin": "http://evil.example"}),
                           ("api-without-session", origin() + "/api/summary", {"X-Requested-With": "bedrock-now"})):
        def one(name=name, url=url, hdr=hdr):
            CUR["state"] = name
            c3 = browser.new_context()
            r = c3.request.get(url, headers=hdr, max_redirects=0)
            body = r.text()[:4000]
            (OUT / f"refusal-{name}.txt").write_text(f"HTTP {r.status}\n{body}")
            count("refusal bodies")
            for hit in brand_check.check_text(REPO, f"refusal {name}", body):
                find("old name in visible text", hit)
            c3.close()
        step(name, one)
    c.close()


# --- the manifest and the icons (once) ---

def png_size(b: bytes):
    if b[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", b[16:24])


def sources(path: Path) -> dict:
    out = {}
    try:
        for line in path.read_text().splitlines():
            if line and not line.startswith("#"):
                h, n = line.split()
                out[n] = h
    except OSError:
        pass
    return out


def sweep_manifest(browser):
    CUR.update(page="manifest", state="-", width="-", theme="-")
    c = browser.new_context()
    attach(c)
    p = c.new_page()
    login(p)
    r = c.request.get(origin() + "/manifest.webmanifest")
    m = r.json()
    (OUT / "manifest.json").write_text(json.dumps(m, indent=1))
    new_src = sources(REPO / "portal/portal/static/icons/SOURCES")
    stack_src = sources(STACK / "portal/portal/static/icons/SOURCES")
    count("manifest checks")
    if "bedrock" in m.get("name", "").lower() or "bedrock" in m.get("short_name", "").lower():
        find("manifest name", f"name {m.get('name')!r}, short_name {m.get('short_name')!r}")
    rows = []
    urls = [i["src"] for i in m.get("icons", [])] + [s for sc in m.get("shortcuts", []) for s in [i["src"] for i in sc.get("icons", [])]]
    urls += ["/favicon.svg", "/favicon.ico", "/icons/app-touch-180.png", "/icons/app-16.png", "/icons/app-32.png", "/icons/app-48.png", "/static/logo.svg"]
    html = []
    for u in dict.fromkeys(urls):
        full = u if u.startswith("http") else origin() + u
        rr = c.request.get(full)
        b = rr.body()
        sha = hashlib.sha256(b).hexdigest()
        name = urlsplit(full).path.lstrip("/").replace("static/", "")
        size = png_size(b)
        ctype = rr.headers.get("content-type", "")
        decl = next((i.get("sizes") for i in m.get("icons", []) if i["src"] == u), None)
        rec = {"url": u, "status": rr.status, "type": ctype, "bytes": len(b), "png": size, "declared": decl, "sha256": sha[:16],
               "new_mark": any(h == sha for h in new_src.values()), "this_checkout": any(h == sha for h in stack_src.values())}
        if name.endswith("logo.svg") or name == "favicon.svg":
            rec["new_mark"] = sha == NEW_LOGO
            rec["old_mark"] = sha == OLD_LOGO
        rows.append(rec)
        count("icons fetched")
        if rr.status != 200 or not len(b):
            find("icon broken", f"{u}: HTTP {rr.status}, {len(b)} bytes")
        elif not (ctype.startswith("image/") or "svg" in ctype):
            find("icon type", f"{u}: {ctype}")
        elif decl and size and f"{size[0]}x{size[1]}" != decl:
            find("icon size", f"{u}: {size[0]}x{size[1]}, manifest says {decl}")
        if rr.status == 200 and ctype.startswith("image/png"):
            import base64
            html.append(f'<figure><img src="data:image/png;base64,{base64.b64encode(b).decode()}" style="max-width:256px"><figcaption>{name} {size}</figcaption></figure>')
    (OUT / "icons.json").write_text(json.dumps(rows, indent=1))
    c.close()
    c2 = browser.new_context()
    p2 = c2.new_page()
    p2.set_content("<body style='font:13px sans-serif;display:flex;flex-wrap:wrap;gap:16px;background:#ddd'>" + "".join(html) + "</body>")
    p2.screenshot(path=str(SHOTS / "manifest-icons.png"), full_page=True)
    c2.close()


# --- links: internal (answered, as the signed-in browser asks), external (a paced GET), the docs index ---

DOCS_REPO = "https://github.com/JongoDB-Labs/devos-ade/blob/"   # (search.js: REPO)
GH = re.compile(r"^https://(?:github\.com|raw\.githubusercontent\.com)/JongoDB-Labs/(devos-ade|bedrock-now)\b", re.I)


def get(url: str, method="GET"):
    req = urllib.request.Request(url, method=method, headers={"User-Agent": "Mozilla/5.0 (devos-ade ui sweep)"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.geturl(), r.read(4 * 1024 * 1024).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, url, ""
    except Exception as e:  # noqa: BLE001
        return 0, url, f"{type(e).__name__}: {e}"


def check_links(browser):
    CUR.update(page="links", state="-", width="-", theme="-")
    c, p = code_open(browser, "desktop", "light")   # (signed in on every host, the Code page unlocked)
    internal = {u: w for u, w in LINKS.items() if (urlsplit(u).hostname or "").endswith(HOST)}
    external = {u: w for u, w in LINKS.items() if u not in internal and u.startswith("http")}
    pending, results = [], []
    lp = c.new_page()   # (each internal link as the browser follows it: a navigation, its own headers)
    for u, w in sorted(internal.items()):
        count("internal links")
        try:
            resp = lp.goto(u, wait_until="domcontentloaded", timeout=30000)
            st = resp.status if resp else 0
            if st == 401 and urlsplit(u).hostname in (f"code.{HOST}", f"terminal.{HOST}") and "Unlock" in lp.content():
                st = "200 (its unlock page)"
        except PwError as e:
            msg = str(e).splitlines()[0]
            st = "200 (a download)" if "Download is starting" in msg else f"failed: {msg[:120]}"
        results.append({"url": u, "status": st, **w})
        if not str(st).startswith("200"):
            find("internal link", f"{u} -> {st} ({w['text']!r}, first on {w['where']})")
    # images seen on the pages, as the browser fetched them
    for u, w in sorted(IMAGES.items()):
        if not u.startswith("http") or urlsplit(u).hostname not in OUR_HOSTS:
            continue
        count("images fetched")
        try:
            r = c.request.get(u)
            b, ct = r.body(), r.headers.get("content-type", "")
            if r.status != 200 or not b:
                find("image fetch", f"{u} -> HTTP {r.status}, {len(b)} bytes (first on {w['where']})")
            elif not (ct.startswith("image/") or "svg" in ct or ("manifest" in str(w.get("icon")) and "json" in ct)):
                find("image type", f"{u}: {ct} (first on {w['where']})")
        except PwError as e:
            find("image fetch", f"{u}: {str(e).splitlines()[0][:120]}")
    # the docs index the portal's search shows: each file's page once (paced), and each anchor on it
    try:
        # (as search.js builds them: the installed release's tag on GitHub, else main; each file, each section's anchor)
        idx = c.request.get(origin() + "/api/search/index", headers={"X-Requested-With": "bedrock-now"}).json()
        try:
            inst = json.loads((STATE / "status" / "version.json").read_text()).get("version", "")
        except Exception:  # noqa: BLE001
            inst = ""
        base = DOCS_REPO + (inst if re.fullmatch(r"v\d{1,4}\.\d{1,4}\.\d{1,4}", inst or "") else "main") + "/"
        n = 0
        for pg in ((idx.get("docs") or {}).get("pages") or []):
            external.setdefault(base + pg["file"], {"where": "docs index", "text": str(pg.get("title", ""))[:80]})
            n += 1
            for sec in pg.get("sections") or []:
                external.setdefault(f"{base}{pg['file']}#{sec['anchor']}", {"where": "docs index", "text": str(sec.get("title", ""))[:80]})
                n += 1
        count("docs index links", n)
    except Exception as e:  # noqa: BLE001
        find("docs index", f"{type(e).__name__}: {e}")
    c.close()
    pages: dict[str, tuple[int, str, str]] = {}
    for u, w in sorted(external.items()):
        base, frag = urldefrag(u)
        count("external links")
        if re.search(r"/releases/tag/v9[789]\.0\.0$", base):
            continue   # (the update card's states: the sweep's own made-up releases)
        if base not in pages:
            time.sleep(1.0)
            pages[base] = get(base)
            for wait in (5, 15, 30):
                if pages[base][0] not in (429, 503, 0):
                    break
                time.sleep(wait)
                pages[base] = get(base)
        st, final, body = pages[base]
        rec = {"url": u, "status": st, "final": final, **w}
        results.append(rec)
        names_release = re.search(r"v0\.25\.0", u) is not None
        gh = GH.match(u)
        anchor_ok = True
        if frag and st == 200 and "github.com" in base:
            anchor_ok = f"user-content-{frag.lower()}" in body or f'id="{frag}"' in body
        blob = re.match(r"https://github\.com/JongoDB-Labs/devos-ade/blob/main/(.+)$", base)
        if names_release and st != 200:
            pending.append({**rec, "why": "names v0.25.0 (not tagged yet)"})
        elif blob and st == 404 and (STACK / blob.group(1)).exists():
            pending.append({**rec, "why": "a file of this checkout not on GitHub's main yet (pushed with the release)"})
        elif st != 200:
            if gh and gh.group(1).lower() == "devos-ade":
                find("GitHub link", f"{u} -> {st} (first on {w['where']})")
            elif st in (401, 403, 429, 999):
                find("external link unverifiable", f"{u} -> {st} (first on {w['where']})")
            else:
                find("external link", f"{u} -> {st} (first on {w['where']})")
        elif not anchor_ok:
            pending.append({**rec, "why": f"#{frag} not on GitHub's main yet (pushed with the release?)"})
        if gh and gh.group(1).lower() == "bedrock-now":
            find("old repository link", f"{u} -> {st} {final} (first on {w['where']})", severity="info")
    (OUT / "links.json").write_text(json.dumps(results, indent=1))
    (OUT / "links-pending-release.json").write_text(json.dumps(pending, indent=1))
    count("links pending the release", len(pending))


def docs_static():
    """The links in the README and docs/ of the checkout the stack runs: a relative link to a file that is there, its
    anchor among the file's headings (GitHub's rule: portal/searchindex.py), an external one into the paced GETs."""
    CUR.update(page="docs", state="-", width="-", theme="-")
    sys.path.insert(0, str(STACK / "portal"))
    try:
        from portal.searchindex import slug
    except Exception:  # noqa: BLE001
        slug = None
    files = [STACK / "README.md", *sorted((STACK / "docs").glob("*.md"))]
    anchors = {}
    for f in files:
        heads = re.findall(r"^#{1,6}\s+(.+?)\s*#*\s*$", f.read_text(encoding="utf-8"), re.M)
        if slug:
            seen, out = {}, set()
            for h in heads:
                s = slug(h)
                n = seen.get(s, 0)
                out.add(s if n == 0 else f"{s}-{n}")
                seen[s] = n + 1
            anchors[f.relative_to(STACK).as_posix()] = out
    link = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
    for f in files:
        rel = f.relative_to(STACK).as_posix()
        for m in link.finditer(f.read_text(encoding="utf-8")):
            u = m.group(1)
            count("docs links")
            if u.startswith(("http://", "https://")):
                LINKS.setdefault(u, {"where": f"docs {rel}", "text": ""})
                continue
            if u.startswith("mailto:"):
                continue
            path, _, frag = u.partition("#")
            target = (f.parent / path).resolve() if path else f
            try:
                trel = target.relative_to(STACK.resolve()).as_posix()
            except ValueError:
                trel = target.as_posix()
            if path and not target.exists():
                find("docs link", f"{rel}: {u} — no such file")
            elif frag and slug and trel in anchors and frag not in anchors[trel]:
                find("docs anchor", f"{rel}: {u} — no heading with that anchor in {trel}")


def main() -> int:
    t0 = time.time()
    with sync_playwright() as pw:
        args = [f"--host-resolver-rules=MAP {HOST} {TARGET_IP}, MAP *.{HOST} {TARGET_IP}"]
        browser = pw.chromium.launch(args=args)
        try:
            if wanted("manifest"):
                sweep_manifest(browser)
        except Exception as e:  # noqa: BLE001
            find("state not reached", f"manifest: {e}")
        for width in ONLY_WIDTHS:
            for theme in THEMES:
                CUR.update(width=width, theme=theme)
                print(f"sweep: {width} {theme} ({int(time.time() - t0)} s)", flush=True)
                for fn in (sweep_signin, sweep_portal, sweep_off_pages, sweep_walkthrough, sweep_code, sweep_errors):
                    if not wanted(fn.__name__.removeprefix("sweep_")):
                        continue
                    CUR.update(page=fn.__name__.removeprefix("sweep_"), state="-")
                    try:
                        fn(browser, width, theme)
                    except Exception as e:  # noqa: BLE001
                        find("state not reached", f"{fn.__name__}: {type(e).__name__}: {str(e).splitlines()[0][:300]}")
                        (OUT / "tracebacks.txt").open("a").write(f"--- {where()} {fn.__name__}\n{traceback.format_exc()}\n")
        try:
            if wanted("links"):
                docs_static()
                check_links(browser)
        except Exception as e:  # noqa: BLE001
            find("state not reached", f"links: {type(e).__name__}: {e}")
            (OUT / "tracebacks.txt").open("a").write(f"--- links\n{traceback.format_exc()}\n")
        browser.close()
    (OUT / "findings.json").write_text(json.dumps(FINDINGS, indent=1))
    with (OUT / "findings.tsv").open("w") as fh:
        fh.write("check\tpage\tstate\twidth\ttheme\tdetail\n")
        for f in FINDINGS:
            fh.write("\t".join(str(f.get(k, "")).replace("\t", " ").replace("\n", " ") for k in ("check", "page", "state", "width", "theme", "detail")) + "\n")
    by = {}
    for f in FINDINGS:
        by[f["check"]] = by.get(f["check"], 0) + 1
    lines = [f"ui sweep: {int(time.time() - t0)} s", "", "checked:"] + [f"  {k}: {v}" for k, v in sorted(COUNTS.items())] + \
            ["", "findings by check:"] + [f"  {k}: {v}" for k, v in sorted(by.items(), key=lambda kv: -kv[1])] + \
            ["", "logos seen:"] + [f"  {k} (first: {v})" for k, v in LOGO_SEEN.items()]
    (OUT / "summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
