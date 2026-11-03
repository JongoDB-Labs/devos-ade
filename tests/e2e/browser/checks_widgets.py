"""Home's widgets (JON-946; static/widgets.js, GET and PUT /api/ui/layout), in Chromium against the throwaway: Customize
turns on edit mode (a tray, a bar and edge handles on each card); hide and Add back; move by the keyboard and by a
drag; resize by Shift+arrows and by dragging an edge; the height control; Reset to default; Done and Escape; a reload
keeps the layout (read first from this browser's cache, then from the portal's own copy); a phone's layout and a desktop's
stay apart; a card the person hid stays hidden with news to show, and the header still says an update is available when
the Update card is hidden; the whole flow with the keyboard alone; at every width from 768 px up, no widget on top of
another. Each check puts the saved layout back to the default first and afterwards. No Bedrock calls. Screenshots:
desktop, phone."""

from __future__ import annotations

import json
import re

from common import check, expect, origin
from checks_browser import login, shot

CLEAR = """async () => {
  const r = await fetch('/api/ui/layout', {method: 'PUT', credentials: 'same-origin', headers: {'X-Requested-With': 'devos-ade', 'Content-Type': 'application/json'},
    body: JSON.stringify({version: 1, pages: {home: {desktop: null, tablet: null, phone: null}}})});
  try { localStorage.removeItem('bn.layout'); } catch (e) {}
  return r.status;
}"""
SAVED = """async () => (await fetch('/api/ui/layout', {credentials: 'same-origin', headers: {'X-Requested-With': 'devos-ade'}})).json()"""


def home_ready(page):
    login(page)
    page.wait_for_selector("#home:not([hidden]) .spend")
    page.wait_for_function("() => !/Loading/.test((document.getElementById('updated') || {}).textContent || '')", timeout=30000)
    page.wait_for_function("() => window.bnWidgets && window.bnWidgets.layout", timeout=15000)


def start(page):
    """Signed in, Home up, and no saved layout (the server's copy and this browser's cache)."""
    home_ready(page)
    expect(page.evaluate(CLEAR) == 200, "the layout could not be cleared")
    page.reload()
    page.wait_for_selector("#home:not([hidden]) .spend")
    page.wait_for_function("() => window.bnWidgets && window.bnWidgets.layout")


def order(page) -> list[str]:
    return page.evaluate("() => window.bnWidgets.layout().map((e) => e.id)")


def entry(page, wid: str) -> dict:
    return page.evaluate("(id) => window.bnWidgets.layout().find((e) => e.id === id)", wid)


def saved(page, device: str):
    return page.evaluate(SAVED)["pages"].get("home", {}).get(device)


def say(page) -> str:
    return page.evaluate("() => document.getElementById('wg-live').textContent").replace(" ", " ").strip()


def shown(page, wid: str) -> bool:
    return page.locator(f"[data-widget='{wid}']").first.is_visible()


def wait_saved(page, device: str, pred, what: str):
    for _ in range(40):
        got = saved(page, device)
        if pred(got):
            return got
        page.wait_for_timeout(250)
    raise AssertionError(f"the portal's copy never showed {what}: {saved(page, device)}")


def bar(wid: str, sel: str) -> str:
    return f".wg-ov[data-for='{wid}'] {sel}"


def customize(page):
    page.click("#customize")
    page.wait_for_selector("#widget-tray:not([hidden])")
    page.wait_for_selector(".wg-ov:not([hidden])")


def centre(page, sel: str) -> tuple[float, float]:
    b = page.locator(sel).first.bounding_box()
    return b["x"] + b["width"] / 2, b["y"] + b["height"] / 2


def scroll_to(page, wid: str):
    page.evaluate("(id) => document.querySelector(`[data-widget=\"${id}\"]`).scrollIntoView({block: 'center'})", wid)
    page.wait_for_timeout(200)


@check("browser", "widgets-default-is-todays-home")
def widgets_default(ctx):
    page, rec = ctx.page("widgets-default")
    start(page)
    # nothing customized: the page's own markup lays Home out; the widgets sit where the markup has them
    expect(not page.evaluate("() => document.getElementById('widgets').classList.contains('wg-custom')"), "Home is a grid before anyone customized it")
    expect(page.evaluate("() => !!document.querySelector('.home-top > #continue') && !!document.querySelector('.grid > .col > .spend')"), "the widgets moved")
    expect(page.locator("#widget-tray").is_hidden() and page.locator(".wg-ov").count() == 0, "edit mode without Customize")
    expect(page.locator("#customize").get_attribute("aria-expanded") == "false", "Customize is not collapsed")
    for wid in ("spend", "models", "services", "logins"):
        expect(shown(page, wid), f"{wid} is not shown")
    names = page.eval_on_selector_all("[data-widget]", "els => els.map((e) => e.dataset.widget)")
    expect(set(names) >= {"get-started", "continue", "update-card", "spend", "models", "services", "logins", "maint", "claude", "feedback"}, f"widgets {names}")
    # opening and closing edit mode changes nothing that is kept
    customize(page)
    page.click("#wg-done")
    page.wait_for_selector("#widget-tray", state="hidden")
    expect(not page.evaluate("() => document.getElementById('widgets').classList.contains('wg-custom')"), "Done without a change left the grid on")
    expect(page.evaluate("() => !!document.querySelector('.grid > .col > .spend')"), "Done without a change did not put the widgets back")
    expect(saved(page, "desktop") is None, f"a layout was saved by looking: {saved(page, 'desktop')}")
    # at every width the widgets sit apart: none on top of another (768-960 px put them all in one cell up to 0.45.1)
    for w in (768, 820, 900, 960, 961, 1280, 1440):
        page.set_viewport_size({"width": w, "height": 900})
        page.wait_for_timeout(150)
        on_top = page.evaluate(APART)
        expect(not on_top, f"widgets on top of each other at {w} px: {', '.join(on_top)}")


# the pairs of shown widgets whose boxes overlap (by more than 2 px each way)
APART = """() => {
  const r = [...document.querySelectorAll('#widgets [data-widget]')].filter((e) => e.offsetParent)
    .map((e) => [e.dataset.widget, e.getBoundingClientRect()]).filter(([, q]) => q.width > 0 && q.height > 0);
  const out = [];
  for (let i = 0; i < r.length; i++) for (let j = i + 1; j < r.length; j++) {
    const [a, p] = r[i], [b, q] = r[j];
    if (Math.min(p.right, q.right) - Math.max(p.left, q.left) > 2 && Math.min(p.bottom, q.bottom) - Math.max(p.top, q.top) > 2) out.push(`${a}/${b}`);
  }
  return out;
}"""


@check("browser", "widgets-customize-desktop")
def widgets_customize_desktop(ctx):
    page, rec = ctx.page("widgets-desktop")
    try:
        start(page)
        customize(page)
        shot(page, "widgets-edit-desktop")
        # every control on a bar and in the tray is named; each shown widget has its bar
        unnamed = page.evaluate("""() => [...document.querySelectorAll('.wg-ov button, #widget-tray button')]
            .filter((b) => !(b.getAttribute('aria-label') || b.textContent || '').trim()).map((b) => b.outerHTML.slice(0, 80))""")
        expect(not unnamed, f"unnamed controls {unnamed}")
        for wid in ("spend", "models", "services", "logins", "claude", "feedback"):
            expect(page.locator(bar(wid, ".wg-grip")).is_visible(), f"no handle on {wid}")
        # hide Services: gone from the page, listed in the tray with Add back
        page.click(bar("services", "[data-act=hide]"))
        expect(not shown(page, "services"), "Services is still shown")
        expect("Services hidden" in say(page), f"announced {say(page)!r}")
        expect(page.locator("#wg-hidden [data-id=services]").is_visible(), "Services is not in the tray")
        # it stays hidden after Done, after a reload (the cache, then the portal's copy), and the portal has it
        page.click("#wg-done")
        expect(not shown(page, "services"), "Done showed Services again")
        wait_saved(page, "desktop", lambda d: d and any(e["id"] == "services" and e["hidden"] for e in d), "Services hidden")
        page.reload()
        page.wait_for_selector("#home:not([hidden]) .spend")
        expect(not shown(page, "services"), "a reload showed Services again")
        expect(page.evaluate("() => document.getElementById('widgets').classList.contains('wg-custom')"), "the saved layout was not applied")
        # the update's progress is no widget: right after the update card in the grid, as in the page's own order
        expect(page.evaluate("() => !!document.querySelector('#widgets > [data-widget=update-card] + #job')"), "the update's progress does not follow the update card in the grid")
        # the person's choice stays: Refresh brings Services new numbers and it stays hidden
        page.click("#refresh")
        page.wait_for_timeout(2500)
        expect(not shown(page, "services"), "Refresh showed a widget the person hid")
        # add it back
        customize(page)
        page.click("#wg-hidden [data-id=services]")
        page.wait_for_selector("[data-widget=services]", state="visible")
        expect("Services added back" in say(page), f"announced {say(page)!r}")
        expect(page.locator("#wg-hidden [data-id=services]").count() == 0, "Services is still in the tray")
        # a card that hides itself stays hidden: Get started after the first run, Maintenance without the helper (each their own `hidden`)
        for wid in ("get-started", "update-card"):
            if page.evaluate("(id) => document.querySelector(`[data-widget=\"${id}\"]`).hidden", wid):
                expect(page.locator(bar(wid, ".wg-grip")).is_hidden(), f"{wid} hides itself yet has a bar")
                expect(not shown(page, wid), f"{wid} hides itself yet shows")
        # Reset puts everything back, and the markup's own layout is back after Done
        page.click(bar("models", "[data-act=hide]"))
        page.click("#wg-reset")
        expect(not any(e["hidden"] for e in page.evaluate("() => window.bnWidgets.layout()")), "Reset left a widget hidden")
        expect("default layout" in say(page), f"announced {say(page)!r}")
        page.click("#wg-done")
        expect(not page.evaluate("() => document.getElementById('widgets').classList.contains('wg-custom')"), "Reset and Done left the grid on")
        expect(page.evaluate("() => !!document.querySelector('.grid > .col > .models')"), "Reset did not put the widgets back")
        # and the update's progress where the markup has it (Reset once dropped it, and Home's Refresh then failed on it)
        expect(page.evaluate("() => !!document.querySelector('#widgets > #update-card + #job')"), "Reset and Done dropped the update's progress")
        page.click("#refresh")
        page.wait_for_timeout(2500)
        expect(page.locator("#load-error").is_hidden(), f"Refresh after Reset and Done failed: {page.locator('#load-error').inner_text()!r}")
        wait_saved(page, "desktop", lambda d: d is None, "nothing")
        shot(page, "widgets-reset-desktop")
    finally:
        page.evaluate(CLEAR)


# Continue's box, from the top left of Home's grid (the page may have scrolled), and the grid's content width (the row it may fill)
CONTINUE_BOX = """() => {
  const b = document.querySelector('[data-widget=continue]').getBoundingClientRect(), h = document.getElementById('widgets'), cs = getComputedStyle(h), g = h.getBoundingClientRect();
  return {top: b.top - g.top, left: b.left - g.left, width: b.width, row: h.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)};
}"""


@check("browser", "widgets-continue-fills-the-row-when-alone")
def widgets_continue_alone(ctx):
    page, rec = ctx.page("widgets-alone")
    size = lambda: page.locator(bar("continue", ".wg-size")).inner_text().strip()
    def hide_get_started():   # its own Hide (kept in this browser, as a person's is): it hides itself from then on
        if page.locator("[data-widget=get-started]").is_visible():
            page.click("[data-widget=get-started] .gs-hide")
        page.wait_for_selector("[data-widget=get-started]", state="hidden")
    try:
        start(page)
        hide_get_started()
        page.wait_for_selector("[data-widget=continue]", state="visible")
        before = page.evaluate(CONTINUE_BOX)
        expect(abs(before["width"] - before["row"]) <= 2, f"the default Home does not give Continue the row: {before}")
        # Customize moves the cards into the 12-column grid; Continue (default span 6) keeps the whole row, labelled 12 / 12
        customize(page)
        in_edit = page.evaluate(CONTINUE_BOX)
        expect(abs(in_edit["width"] - in_edit["row"]) <= 2, f"Continue shrank in Customize: {in_edit}")
        expect(size() == "12 / 12", f"size label {size()!r}")
        # another change (hide Models) and Done: Continue is still the whole row, and has not moved from the default page
        page.click(bar("models", "[data-act=hide]"))
        page.click("#wg-done")
        wait_saved(page, "desktop", lambda d: d and any(e["id"] == "models" and e["hidden"] for e in d), "Models hidden")
        expect(page.evaluate("() => document.getElementById('widgets').classList.contains('wg-custom')"), "the saved layout is not applied")
        after = page.evaluate(CONTINUE_BOX)
        expect(abs(after["width"] - after["row"]) <= 2, f"Continue is not the whole row after a change: {after}")
        expect(abs(after["top"] - before["top"]) <= 3 and abs(after["left"] - before["left"]) <= 3, f"Continue moved from the default page: {before} -> {after}")
        # Get started brought back while the page is open (the walkthrough's way): the two share the row again, no reload
        customize(page)
        page.evaluate("() => window.bnGetStarted.open()")
        page.wait_for_function("() => document.querySelector('.wg-ov[data-for=continue] .wg-size').textContent.trim() === '6 / 12'", timeout=5000)
        page.click("#wg-done")
        hide_get_started()
        # a width the person sets is kept, from the span shown: Shift+Left from 12 down to 6, the default, stays at 6
        customize(page)
        page.wait_for_function("() => document.querySelector('.wg-ov[data-for=continue] .wg-size').textContent.trim() === '12 / 12'", timeout=5000)
        page.focus(bar("continue", ".wg-grip"))
        page.keyboard.press("Shift+ArrowLeft")
        expect(entry(page, "continue")["span"] == 11, f"resize did not start from the span shown: {entry(page, 'continue')}")
        for _ in range(5):
            page.keyboard.press("Shift+ArrowLeft")
        got = entry(page, "continue")
        expect(got["span"] == 6 and got.get("sized") is True, f"Shift+Left down to the default width: {got}")
        expect(size() == "6 / 12", f"Continue set to 6 fills the row again: {size()!r}")
    finally:
        page.evaluate(CLEAR)


@check("browser", "widgets-move-resize-height")
def widgets_move_resize_height(ctx):
    page, rec = ctx.page("widgets-move")
    try:
        start(page)
        customize(page)
        ids = order(page)
        # the keyboard: ArrowRight on a handle moves the widget one place later, said in words
        page.focus(bar("spend", ".wg-grip"))
        page.keyboard.press("ArrowRight")
        now = order(page)
        expect(now.index("spend") == ids.index("spend") + 1, f"ArrowRight moved spend {ids} -> {now}")
        expect(re.fullmatch(r"Bedrock spend moved after .+", say(page)) is not None, f"announced {say(page)!r}")
        expect(page.evaluate("() => document.activeElement.classList.contains('wg-grip')"), "the focus left the handle")
        page.keyboard.press("ArrowLeft")
        expect(order(page) == ids, "ArrowLeft did not move it back")
        # Shift+arrows resize: two columns wider, and the words say so
        before = entry(page, "spend")["span"]
        page.keyboard.press("Shift+ArrowRight")
        page.keyboard.press("Shift+ArrowRight")
        expect(entry(page, "spend")["span"] == min(12, before + 2), f"span {before} -> {entry(page, 'spend')['span']}")
        expect(re.fullmatch(rf"Bedrock spend is {entry(page, 'spend')['span']} of 12 columns wide", say(page)) is not None, f"announced {say(page)!r}")
        col = page.evaluate("() => getComputedStyle(document.querySelector('[data-widget=spend]')).gridColumnStart")
        expect(col == f"span {entry(page, 'spend')['span']}", f"the grid says {col!r}")
        page.keyboard.press("Shift+ArrowLeft"); page.keyboard.press("Shift+ArrowLeft")
        expect(entry(page, "spend")["span"] == before, "Shift+ArrowLeft did not narrow it")
        # a drag on the handle: Services goes before Bedrock spend (to the upper left half of it). Services' handle is put
        # mid-window: near the top, the tray (sticky while the page scrolls) is over it. Spend is found again once the drag runs
        scroll_to(page, "services")
        sx, sy = centre(page, bar("services", ".wg-grip"))
        top = page.evaluate("([x, y]) => { const e = document.elementFromPoint(x, y); return e && e.closest('.wg-grip') ? 'grip' : (e ? e.id || e.className : 'nothing'); }", [sx, sy])
        expect(top == "grip", f"Services' handle is under {top!r} at {sx:.0f},{sy:.0f}")
        page.mouse.move(sx, sy)
        page.mouse.down()
        page.mouse.move(sx - 40, sy + 10, steps=6)
        b = page.locator("[data-widget=spend]").bounding_box()
        page.mouse.move(b["x"] + b["width"] * 0.25, b["y"] + b["height"] * 0.2, steps=12)
        page.mouse.up()
        now = order(page)
        vh = page.evaluate("() => innerHeight")
        expect(now.index("services") < now.index("spend"), f"the drag did not move Services before spend: {now} "
               f"(handle at {sx:.0f},{sy:.0f}; spend {b}; window height {vh})")
        expect("Services moved" in say(page), f"announced {say(page)!r}")
        wait_saved(page, "desktop", lambda d: d and [e["id"] for e in d].index("services") < [e["id"] for e in d].index("spend"), "the dragged order")
        # resizing by its right edge: two columns wider, snapped to whole columns
        scroll_to(page, "models")
        w0 = entry(page, "models")["span"]
        pitch = page.evaluate("() => (document.getElementById('widgets').clientWidth + 24) / 12")
        hx, hy = centre(page, bar("models", ".wg-rz-e"))
        page.mouse.move(hx, hy)
        page.mouse.down()
        page.mouse.move(hx + pitch * 1.4, hy, steps=8)
        page.mouse.up()
        w1 = entry(page, "models")["span"]
        expect(w1 == min(12, w0 + 1) or w1 == min(12, w0 + 2), f"the edge drag moved models {w0} -> {w1}")
        expect(w1 > w0 or w0 >= 11, f"models did not get wider ({w0} -> {w1})")
        # the height: M caps the card at 20 rem and the card scrolls inside; pressed state follows; Auto lifts the cap
        page.click(bar("models", "[data-height=m]"))
        expect(page.locator(bar("models", "[data-height=m]")).get_attribute("aria-pressed") == "true", "M is not pressed")
        expect(page.evaluate("() => document.querySelector('[data-widget=models]').style.maxHeight") == "20rem", "no 20 rem cap")
        expect("height: medium" in say(page), f"announced {say(page)!r}")
        page.click(bar("models", "[data-height=auto]"))
        expect(page.evaluate("() => document.querySelector('[data-widget=models]').style.maxHeight") == "", "Auto left a cap")
        shot(page, "widgets-moved-desktop")
        # Reset undoes all of it
        page.click("#wg-reset")
        expect(order(page) == ids and entry(page, "models")["span"] == w0, "Reset did not restore the default")
        page.click("#wg-done")
    finally:
        page.evaluate(CLEAR)


@check("browser", "widgets-keyboard-only")
def widgets_keyboard_only(ctx):
    page, rec = ctx.page("widgets-keys")
    try:
        start(page)
        page.focus("#customize")
        page.keyboard.press("Enter")
        page.wait_for_selector("#widget-tray:not([hidden])")
        expect(page.evaluate("() => document.activeElement.id") == "wg-tray-title", "the focus did not go to the tray")
        # Tab reaches a widget's handle, with a visible focus ring
        for _ in range(40):
            page.keyboard.press("Tab")
            if page.evaluate("() => document.activeElement.classList.contains('wg-grip')"):
                break
        else:
            raise AssertionError("Tab never reached a widget's handle")
        wid = page.evaluate("() => document.activeElement.closest('.wg-ov').dataset.for")
        ring = page.evaluate("() => { const e = document.activeElement, s = getComputedStyle(e); return [s.outlineStyle, s.outlineWidth]; }")
        expect(ring[0] != "none" and ring[1] != "0px", f"no visible focus on the handle {ring}")
        ids = order(page)
        i = ids.index(wid)
        page.keyboard.press("ArrowRight")
        expect(order(page) != ids, f"ArrowRight did not move {wid}")
        page.keyboard.press("ArrowLeft")
        expect(order(page) == ids, "ArrowLeft did not move it back")
        # H hides it (the focus moves to its Add back button); Enter on that adds it back
        page.keyboard.press("h")
        expect(entry(page, wid)["hidden"], f"H did not hide {wid}")
        expect(page.evaluate("() => document.activeElement.dataset.act") == "add", "the focus did not go to Add back")
        page.keyboard.press("Enter")
        page.wait_for_function("(id) => !window.bnWidgets.layout().find((e) => e.id === id).hidden", arg=wid)
        # Escape leaves edit mode and the focus goes back to Customize
        page.keyboard.press("Escape")
        page.wait_for_selector("#widget-tray", state="hidden")
        expect(page.evaluate("() => document.activeElement.id") == "customize", "the focus did not go back to Customize")
        expect(page.locator(".wg-ov").count() == 0, "bars left after Escape")
    finally:
        page.evaluate(CLEAR)


UNDER = """() => {
  const a = document.activeElement, r = a.getBoundingClientRect(), hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
  return {grip: a.classList.contains('wg-grip'), top: r.top, onIt: !!(hit && hit.closest('.wg-grip') === a), hit: hit ? hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '') : null,
    tray: document.getElementById('widget-tray').getBoundingClientRect().bottom};
}"""


@check("browser", "widgets-tray-compacts-and-never-covers-a-handle")
def widgets_tray_sticky(ctx):
    """JON-974: the Customize tray sticks to the top; once stuck it is one row (<= 90 px, not ~240), the scroller keeps
    scroll-padding for it, and every handle reached backwards with Shift+Tab (it scrolls in from above) lands below it."""
    page, rec = ctx.page("widgets-tray-sticky")
    try:
        start(page)
        customize(page)
        top = page.evaluate("() => document.getElementById('widget-tray').getBoundingClientRect().height")
        expect(not page.evaluate("() => document.getElementById('widget-tray').classList.contains('wg-stuck')"), "the tray is compact at the top of the page")
        page.evaluate("() => { const h = document.getElementById('home'); h.scrollTop = 700; }")
        page.wait_for_function("() => document.getElementById('widget-tray').classList.contains('wg-stuck')", timeout=5000)
        page.wait_for_timeout(200)
        stuck = page.evaluate("() => document.getElementById('widget-tray').getBoundingClientRect().height")
        expect(stuck <= 90 and stuck < top, f"the stuck tray is {stuck:.0f} px tall (at the top: {top:.0f}), not one row")
        expect(page.locator("#wg-help").is_hidden() and page.locator("#wg-tray-title").is_visible() and page.locator("#wg-done").is_visible(),
               "the stuck tray hides the wrong parts")
        pad = page.evaluate("() => parseFloat(document.getElementById('home').style.scrollPaddingTop)")
        expect(pad >= stuck + 8 - 1, f"scroll-padding-top is {pad}, the tray is {stuck:.0f} px")
        # the status line is still there for a screen reader
        expect(page.evaluate("() => getComputedStyle(document.getElementById('wg-live')).display") != "none", "the live region was taken out")
        # backwards from the bottom: each handle that scrolls in from above has to be pressable
        page.evaluate("() => { const h = document.getElementById('home'); h.scrollTop = h.scrollHeight; const g = [...document.querySelectorAll('.wg-grip')]; g[g.length - 1].focus(); }")
        page.wait_for_timeout(300)
        seen = 0
        for _ in range(80):
            page.keyboard.press("Shift+Tab")
            page.wait_for_timeout(60)
            got = page.evaluate(UNDER)
            if not got["grip"]:
                continue
            seen += 1
            expect(got["onIt"] and got["top"] >= got["tray"] - 1, f"a focused handle is under the tray: {got}")
        expect(seen >= 4, f"only {seen} handles were reached with Shift+Tab")
        # Done (the tray goes away): the padding and the sentinel go with it
        page.click("#wg-done")
        page.wait_for_selector("#widget-tray", state="hidden")
        left = page.evaluate("() => [document.getElementById('home').style.scrollPaddingTop, document.querySelectorAll('.wg-sentinel').length]")
        expect(left == ["", 0], f"left behind after Done: {left}")
        rec.save()
    finally:
        page.evaluate(CLEAR)
    return f"stuck tray {stuck:.0f} px (at the top {top:.0f}), scroll-padding {pad:.0f}, {seen} handles reached backwards, none under it"


# the tray's stuck class flips over a second, with the page scrolled past the tray's sentinel by half the room the tray
# gives up when it compacts (one row is at most 90 px): one flip at most, then it holds
FLIPS = """async () => {
  const home = document.getElementById('home'), tray = document.getElementById('widget-tray'), s = document.querySelector('.wg-sentinel');
  const full = tray.getBoundingClientRect().height;
  home.scrollTop = s.getBoundingClientRect().top - home.getBoundingClientRect().top + home.scrollTop + Math.max(20, (full - 90) / 2);
  let flips = 0;
  const mo = new MutationObserver(() => { flips++; });
  mo.observe(tray, {attributes: true, attributeFilter: ['class']});
  await new Promise((r) => setTimeout(r, 1000));
  mo.disconnect();
  return {flips, full: Math.round(full), stuck: tray.classList.contains('wg-stuck'), scrollTop: Math.round(home.scrollTop)};
}"""


@check("browser", "widgets-tray-holds-still-at-the-edge")
def widgets_tray_still(ctx):
    """Scrolled just past where the tray sticks, it sticks and stays: compacting gives up ~200 px, and the page moving up
    under it made the browser's scroll anchoring scroll back as far, unstick it, and so on every frame (Reset and Done
    never still enough to click: widgets-customize-desktop, 2026-11-03). The tray keeps that room as a margin now."""
    page, rec = ctx.page("widgets-tray-still")
    seen = []
    try:
        start(page)
        customize(page)
        for vw, vh in ((1400, 900), (1280, 800)):
            page.set_viewport_size({"width": vw, "height": vh})
            page.evaluate("() => { document.getElementById('home').scrollTop = 0; }")
            page.wait_for_timeout(300)
            got = page.evaluate(FLIPS)
            expect(got["flips"] <= 1 and got["stuck"], f"{vw}x{vh}: the tray flipped {got['flips']} times in a second at the edge ({got})")
            page.click("#wg-reset", timeout=5000)   # (still enough to click)
            seen.append(f"{vw}x{vh} {got['flips']} flip(s)")
        page.click("#wg-done", timeout=5000)
        page.wait_for_selector("#widget-tray", state="hidden")
        expect(page.evaluate("() => document.getElementById('widget-tray').style.marginBottom") == "", "the tray kept its margin after Done")
        rec.save()
    finally:
        page.evaluate(CLEAR)
    return "; ".join(seen)


@check("browser", "widgets-phone-and-desktop-stay-apart")
def widgets_phone_apart(ctx):
    page, rec = ctx.page("widgets-phone", "phone")
    try:
        start(page)
        customize(page)
        shot(page, "widgets-edit-phone")
        # a phone: one column, Move up / Move down and Hide; no drag handle and no resize edges
        expect(page.locator(bar("models", "[data-act=down]")).is_visible() and page.locator(bar("models", "[data-act=up]")).is_visible(), "no Move up / Move down")
        expect(page.locator(bar("models", ".wg-grip")).is_hidden() and page.locator(bar("models", ".wg-rz-e")).is_hidden(), "a phone shows a drag handle or a resize edge")
        expect(page.locator(bar("models", "[data-act=down]")).bounding_box()["height"] >= 43, "Move down is under 44 px")
        expect(page.locator(".wg-ov[data-for=claude]").count() == 0, "Claude Code in your terminal is offered on a phone")
        ids = order(page)
        page.click(bar("models", "[data-act=down]"))
        now = order(page)
        expect(now.index("models") == ids.index("models") + 1, f"Move down {ids} -> {now}")
        expect("Models moved after" in say(page), f"announced {say(page)!r}")
        page.click(bar("services", "[data-act=hide]"))
        expect(not shown(page, "services"), "Hide did nothing")
        spans = {e["span"] for e in page.evaluate("() => window.bnWidgets.layout()")}
        expect(spans == {1}, f"a phone has columns: {spans}")
        page.click("#wg-done")
        got = wait_saved(page, "phone", lambda d: d and any(e["id"] == "services" and e["hidden"] for e in d), "Services hidden on the phone")
        expect(saved(page, "desktop") is None and saved(page, "tablet") is None, "a phone's layout was saved for another screen")
        expect(all(e["span"] == 1 for e in got), "the phone's saved spans are not 1")
        # the same sign-in on a desktop: untouched; and back on the phone it is as left
        page2, rec2 = ctx.page("widgets-phone-desktop", "desktop")
        home_ready(page2)
        expect(shown(page2, "services") and not page2.evaluate("() => document.getElementById('widgets').classList.contains('wg-custom')"),
               "the phone's layout reached the desktop")
        expect(saved(page2, "phone") is not None, "the phone's layout was lost")
        page2.evaluate(CLEAR)
    finally:
        try:
            page.evaluate(CLEAR)
        except Exception:  # noqa: BLE001
            pass


@check("browser", "widgets-update-card-hidden-still-announced")
def widgets_update_hidden(ctx):
    page, rec = ctx.page("widgets-update")

    def fake(route):
        resp = route.fetch()
        data = resp.json()
        up = data.get("update") or {}
        up.update(available=True, latest="v99.0.0", installed=up.get("installed") or "v0.0.0", checking=False, published_at=None, url="",
                  releases=[], estimate={"download_mb": 0, "downtime_min": 3})
        data["update"] = up
        route.fulfill(response=resp, json=data)
    page.route(re.compile(re.escape(origin()) + r"/api/summary$"), fake)
    try:
        start(page)
        page.wait_for_selector("#update-card:not([hidden])")
        customize(page)
        page.click(bar("update-card", "[data-act=hide]"))
        page.click("#wg-done")
        wait_saved(page, "desktop", lambda d: d and any(e["id"] == "update-card" and e["hidden"] for e in d), "the Update card hidden")
        expect(not shown(page, "update-card"), "the Update card is still shown")
        # the header still says it: the version label and the release line
        page.wait_for_function("() => /Update available/.test(document.getElementById('release-line').innerText)", timeout=15000)
        expect(page.locator("#release-line .rl-link").is_visible(), "no Update available link with the card hidden")
        # following it shows the card (for now: nothing is saved by it)
        page.click("#release-line .rl-link")
        page.wait_for_selector("#update-card", state="visible")
        expect(saved(page, "desktop") and any(e["id"] == "update-card" and e["hidden"] for e in saved(page, "desktop")), "peeking un-hid the card for good")
        shot(page, "widgets-update-peek")
    finally:
        page.unroute(re.compile(re.escape(origin()) + r"/api/summary$"))
        page.evaluate(CLEAR)
