// Widgets (JON-946): a page's cards that each person can show, hide, move and resize. Home first; the Terminal page
// (termpage.js, which uses this file's model) and the Code page take the same engine. Two halves in one file:
//   1. the layout model — pure functions on plain data (a layout is a list of {id, span, height, hidden}, in order):
//      defaults, merge with what was saved, clamping, move, resize, hide, reset, and the sentences that announce each
//      change. No document needed; portal/tests/js/widgets.test.mjs runs them.
//   2. the page: edit mode (a Customize button, a tray of hidden widgets, a bar and edge handles on each widget, the
//      keyboard), the grid, and what is kept — GET and PUT /api/ui/layout (portal/uilayout.py), with localStorage
//      bn.layout only as a cache that is read first so the page does not flash.
// A kind of screen has its own layout: desktop (12 columns, 1100 px and wider), tablet (6, 768-1099 px) and phone (one
// column, under 768 px: show/hide and order only). The same breakpoints as mobile.css, so a layout never changes the
// one for another kind of screen.
// Home looks as it always did until a person customizes: with no saved layout (or one equal to the default) the
// page's own markup and CSS lay it out and this file moves nothing. A saved layout (or edit mode) moves the widgets
// into #widgets, one grid, in layout order; Reset puts them back where the markup has them. Whether a person HIDES a
// widget is separate from a widget hiding ITSELF (Get started after the first run, Maintenance, the Update card without an
// update: their own `hidden` attribute, which this file never touches): a widget the person hid stays hidden even
// with something to show, one they show still hides itself when it has nothing.
// Loaded after home.js and feedback.js (deferred): every widget is in the page by then. Text only: nothing is parsed as HTML.
(function (root) {
  "use strict";

  const VERSION = 1;
  const MAX_BYTES = 32 * 1024;
  const CACHE = "bn.layout";
  const COLS = { desktop: 12, tablet: 6, phone: 1 };
  const HEIGHTS = ["auto", "s", "m", "l"];
  const HEIGHT_REM = { s: 12, m: 20, l: 32 };   // a cap: taller content scrolls inside the card (Auto: as tall as it is)
  const HEIGHT_WORD = { auto: "automatic", s: "small", m: "medium", l: "large" };
  const HEIGHT_SHORT = { auto: "Auto", s: "S", m: "M", l: "L" };
  const ROW = 4, GAP_Y = 20;               // the grid's rows are 4 px; a widget spans as many as its height and the gap need

  // The widgets of each page: id (the data-widget of its element), the name it goes by, its narrowest span on a
  // (desktop, tablet) screen and its default span there. phone: false is a widget that screen does not show. pair: the
  // widget it shares a row with; while that one is not showing, this one (at its default span) fills the row, as the page's own CSS does.
  // portal/uilayout.py has the same table (a test compares them).
  const HOME = [
    { id: "get-started", title: "Get started", min: [4, 3], span: [6, 3], pair: "continue" },
    { id: "continue", title: "Continue", min: [4, 3], span: [6, 3], pair: "get-started" },
    { id: "update-card", title: "Update", min: [6, 4], span: [12, 6] },
    { id: "spend", title: "Bedrock spend", min: [4, 3], span: [5, 3] },
    { id: "models", title: "Models", min: [4, 3], span: [4, 3] },
    { id: "services", title: "Services", min: [3, 2], span: [4, 3] },
    { id: "logins", title: "Sign-ins", min: [3, 2], span: [4, 3] },
    { id: "maint", title: "Maintenance", min: [3, 2], span: [4, 6] },
    { id: "claude", title: "Claude Code in your terminal", min: [3, 2], span: [3, 3], phone: false },
    { id: "feedback", title: "Send feedback", min: [3, 2], span: [3, 3] },
  ];
  // The Terminal page's: the terminals (always there), the key bar (on a phone and a tablet, off on a desktop, where there
  // is a keyboard), the person's quick commands and the project folders (off until asked for). fixed: cannot be hidden;
  // off: the screens where the widget starts hidden.
  const TERMINAL = [
    { id: "terminals", title: "Terminals", min: [4, 3], span: [12, 6], fixed: true },
    { id: "keys", title: "Key bar", min: [4, 3], span: [12, 6], off: ["desktop"] },
    { id: "commands", title: "Quick commands", min: [3, 2], span: [6, 3], off: ["desktop", "tablet", "phone"] },
    { id: "projects", title: "Projects", min: [3, 2], span: [6, 3], off: ["desktop", "tablet", "phone"] },
  ];
  const VIEWS_MAX = 4;
  const SPLITS = ["cols", "rows", "grid"];
  const SPLIT_WORD = { cols: "side by side", rows: "stacked", grid: "in a 2 by 2 grid" };
  const COMMANDS_MAX = 20, COMMAND_LABEL_MAX = 40, COMMAND_TEXT_MAX = 200;
  const NAMES = { home: "Home", terminal: "The Terminal page" };
  // the default order on each kind of screen: today's Home (Get started and Continue, the update, then Bedrock spend
  // beside the short cards, Claude Code and Send feedback at the far side)
  const PAGES = {
    home: {
      widgets: HOME,
      order: {
        desktop: ["get-started", "continue", "update-card", "spend", "services", "claude", "models", "logins", "feedback", "maint"],
        tablet: ["get-started", "continue", "update-card", "spend", "services", "models", "logins", "maint", "claude", "feedback"],
        phone: ["get-started", "continue", "update-card", "spend", "services", "models", "logins", "maint", "feedback"],
      },
    },
    terminal: {
      widgets: TERMINAL,
      order: { desktop: ["terminals", "keys", "commands", "projects"], tablet: ["terminals", "keys", "commands", "projects"], phone: ["terminals", "keys", "commands", "projects"] },
    },
  };

  // ---------- the model: plain data in, plain data out ----------
  const DEVICE_INDEX = { desktop: 0, tablet: 1 };
  const widgetsOf = (page) => (PAGES[page] ? PAGES[page].widgets : []);
  const find = (page, id) => widgetsOf(page).find((w) => w.id === id) || null;
  const titleOf = (page, id) => (find(page, id) || { title: id }).title;
  // the widgets a kind of screen has, in no order
  const available = (page, device) => widgetsOf(page).filter((w) => device !== "phone" || w.phone !== false);
  const minSpan = (w, device) => (device === "phone" ? 1 : Math.min(COLS[device], w.min[DEVICE_INDEX[device]]));
  const maxSpan = (device) => COLS[device];
  const clampSpan = (w, device, n) => {
    n = Number.isFinite(Number(n)) ? Math.round(Number(n)) : maxSpan(device);
    return Math.max(minSpan(w, device), Math.min(maxSpan(device), n));
  };
  const defaultEntry = (w, device) => ({ id: w.id, span: device === "phone" ? 1 : clampSpan(w, device, w.span[DEVICE_INDEX[device]]), height: "auto", hidden: Boolean(w.off && w.off.includes(device)) });
  const defaults = (page, device) => {
    const have = new Map(available(page, device).map((w) => [w.id, w]));
    const ids = PAGES[page].order[device].filter((id) => have.has(id));
    for (const id of have.keys()) if (!ids.includes(id)) ids.push(id);
    return ids.map((id) => defaultEntry(have.get(id), device));
  };
  // normalize(page, device, saved) -> a clean layout from whatever was kept: unknown, repeated or (on this screen)
  // unavailable widgets dropped, spans and heights clamped, hidden a boolean; a widget that is not in it (a later
  // release added it) is appended with its default. Nothing saved: the defaults.
  function normalize(page, device, saved) {
    const have = new Map(available(page, device).map((w) => [w.id, w]));
    const out = [], seen = new Set();
    if (Array.isArray(saved)) {
      for (const e of saved) {
        const w = e && typeof e === "object" ? have.get(e.id) : null;
        if (!w || seen.has(w.id)) continue;
        seen.add(w.id);
        out.push({ id: w.id, span: device === "phone" ? 1 : clampSpan(w, device, e.span), height: HEIGHTS.includes(e.height) ? e.height : "auto", hidden: e.hidden === true && !w.fixed,
          ...(e.sized === true && w.pair && device !== "phone" ? { sized: true } : {}) });
      }
    }
    for (const d of defaults(page, device)) if (!seen.has(d.id)) out.push(d);
    return out;
  }
  // usedSpan(page, device, list, id, gone): the span a widget is laid out with. Its own, except that a widget with a pair
  // that is still at its default span fills the row (all the columns) while the pair is not showing: hidden by the person
  // or in `gone` (ids that hide themselves, e.g. Get started after the first run). A span the person set (`sized`) is kept.
  function usedSpan(page, device, list, id, gone) {
    const e = get(list, id), w = find(page, id);
    if (!e || !w) return 0;
    if (device === "phone") return 1;
    if (w.pair && !e.sized && e.span === defaultEntry(w, device).span) {
      const p = get(list, w.pair);
      if (!p || p.hidden || (gone && gone.includes(w.pair))) return COLS[device];
    }
    return e.span;
  }
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const isDefault = (page, device, list) => same(list, defaults(page, device));
  const shown = (list) => list.filter((e) => !e.hidden);
  const get = (list, id) => list.find((e) => e.id === id) || null;
  const change = (list, id, patch) => list.map((e) => (e.id === id ? { ...e, ...patch } : e));
  const nothing = (list, message) => ({ list, message, changed: false });

  // where a widget is now, in words: "moved after Services", or "moved to the start"
  function placed(page, list, id) {
    const v = shown(list), i = v.findIndex((e) => e.id === id);
    return i <= 0 ? `${titleOf(page, id)} moved to the start` : `${titleOf(page, id)} moved after ${titleOf(page, v[i - 1].id)}`;
  }
  // moveBy(page, list, id, dir): one place earlier (-1) or later (1) among the widgets that are shown
  function moveBy(page, list, id, dir) {
    const v = shown(list), i = v.findIndex((e) => e.id === id), j = i + (dir < 0 ? -1 : 1);
    if (i < 0) return nothing(list, "");
    if (j < 0 || j >= v.length) return nothing(list, `${titleOf(page, id)} is already ${dir < 0 ? "first" : "last"}`);
    const moving = list.find((e) => e.id === id), rest = list.filter((e) => e.id !== id);
    const at = rest.findIndex((e) => e.id === v[j].id);
    const out = rest.slice(0, dir < 0 ? at : at + 1).concat(moving, rest.slice(dir < 0 ? at : at + 1));
    return { list: out, message: placed(page, out, id), changed: true };
  }
  // moveBefore(page, list, id, beforeId): to just before another widget (null: to the end) — what a drag does
  function moveBefore(page, list, id, beforeId) {
    const moving = get(list, id);
    if (!moving || id === beforeId) return nothing(list, "");
    const rest = list.filter((e) => e.id !== id);
    const at = beforeId === null ? rest.length : rest.findIndex((e) => e.id === beforeId);
    if (at < 0) return nothing(list, "");
    const out = rest.slice(0, at).concat(moving, rest.slice(at));
    return same(out, list) ? nothing(list, "") : { list: out, message: placed(page, out, id), changed: true };
  }
  // setSpan(page, device, list, id, span, from): whole columns, clamped; a phone has one column and nothing to resize.
  // FROM is the span it is shown at (usedSpan; default its own). A widget with a pair keeps `sized` once the person sets
  // its width, so a width equal to the default is kept as theirs and does not fill the row again.
  function setSpan(page, device, list, id, span, from) {
    const e = get(list, id), w = find(page, id);
    if (!e || !w || device === "phone") return nothing(list, "");
    const n = clampSpan(w, device, span);
    const msg = `${titleOf(page, id)} is ${n} of ${COLS[device]} columns wide`;
    if (n === (from === undefined ? e.span : from) && (n === e.span || !w.pair)) return nothing(list, msg);
    return { list: change(list, id, w.pair ? { span: n, sized: true } : { span: n }), message: msg, changed: true };
  }
  const resizeBy = (page, device, list, id, delta) => { const e = get(list, id); return e ? setSpan(page, device, list, id, e.span + delta) : nothing(list, ""); };
  function setHeight(page, list, id, height) {
    const e = get(list, id);
    if (!e || !HEIGHTS.includes(height)) return nothing(list, "");
    const msg = `${titleOf(page, id)} height: ${HEIGHT_WORD[height]}`;
    return e.height === height ? nothing(list, msg) : { list: change(list, id, { height }), message: msg, changed: true };
  }
  // heightStep(page, list, id, dir): taller (1) or shorter (-1): S, M, L, then as tall as the content (Auto)
  function heightStep(page, list, id, dir) {
    const e = get(list, id);
    if (!e) return nothing(list, "");
    const ladder = ["s", "m", "l", "auto"], i = ladder.indexOf(e.height) + (dir < 0 ? -1 : 1);
    return setHeight(page, list, id, ladder[Math.max(0, Math.min(ladder.length - 1, i))]);
  }
  function hide(page, list, id) {
    const e = get(list, id);
    if (e && find(page, id).fixed) return nothing(list, `${titleOf(page, id)} always show`);
    return !e || e.hidden ? nothing(list, "") : { list: change(list, id, { hidden: true }), message: `${titleOf(page, id)} hidden`, changed: true };
  }
  // show(page, list, id): add back, where it was in the order
  function show(page, list, id) {
    const e = get(list, id);
    return !e || !e.hidden ? nothing(list, "") : { list: change(list, id, { hidden: false }), message: `${titleOf(page, id)} added back`, changed: true };
  }
  const reset = (page, device) => ({ list: defaults(page, device), message: `${NAMES[page] || "The page"} is back to its default layout`, changed: true });

  // the layout a document holds for a page and screen ({version, pages: {page: {device: [...]}}}); null: none kept
  function entry(doc, page, device) {
    const p = doc && typeof doc === "object" && doc.version === VERSION && doc.pages && typeof doc.pages === "object" ? doc.pages[page] : null;
    return p && typeof p === "object" && Array.isArray(p[device]) ? p[device] : null;
  }
  // parseDoc(text) -> a document from the cache or the server (anything unusable: nothing kept)
  function parseDoc(text) {
    let d = null;
    try { d = typeof text === "string" ? JSON.parse(text) : text; } catch (_) { d = null; }
    return d && typeof d === "object" && d.version === VERSION && d.pages && typeof d.pages === "object" && !Array.isArray(d.pages) ? d : { version: VERSION, pages: {} };
  }
  // the body of a save: this screen's layout, or null (back to the default) when it is the default
  function savePatch(page, device, list) {
    return { version: VERSION, pages: { [page]: { [device]: isDefault(page, device, list) ? null : list } } };
  }
  // what the grid needs of a widget: columns, a height cap, how many 4 px rows it spans for a height in px
  const styleFor = (e, device, span = e.span) => ({ columns: device === "phone" ? "" : `span ${span}`, maxHeight: e.height === "auto" ? "" : `${HEIGHT_REM[e.height]}rem` });
  const rowSpan = (px) => Math.max(1, Math.ceil((px + GAP_Y) / ROW));

  // ---------- the Terminal page: widgets, and the views in the Terminals widget ----------
  // A terminal screen is {widgets, views, split, weights}: the widgets as above, how many terminals (1 to 4; a phone has one),
  // how they are split (cols: side by side, rows: stacked, grid: 2 by 2) and their weights (1 to 100: shares of the width
  // or height). The quick commands belong to the person, not the screen: [{label, text, run}], on every screen.
  const equalWeights = (n) => Array(n).fill(50);
  const screenDefaults = (device) => ({ widgets: defaults("terminal", device), views: 1, split: "cols", weights: [] });
  const whole = (n, low, high, other) => (typeof n === "number" && Number.isFinite(n) ? Math.max(low, Math.min(high, Math.round(n))) : other);
  // normalizeScreen(device, saved) -> a clean screen from whatever was kept (anything unusable: the default)
  function normalizeScreen(device, saved) {
    const s = saved && typeof saved === "object" && !Array.isArray(saved) ? saved : {};
    const views = device === "phone" ? 1 : whole(s.views, 1, VIEWS_MAX, 1);
    const weights = Array.isArray(s.weights) ? s.weights.slice(0, VIEWS_MAX).map((w) => whole(w, 1, 100, 50)) : [];
    return { widgets: normalize("terminal", device, s.widgets), views, split: SPLITS.includes(s.split) ? s.split : "cols", weights: weights.length === views ? weights : [] };
  }
  const isDefaultScreen = (device, s) => same(s, screenDefaults(device));
  const withViews = (s, views, weights, message) => ({ screen: { ...s, views, weights }, message, changed: true });
  const stay = (s, message) => ({ screen: s, message, changed: false });
  // addView(device, screen) / closeView(device, screen, index): one more terminal (a phone keeps one), or one fewer (the
  // first view cannot close while it is the only one); weights go back to equal shares
  function addView(device, s) {
    if (device === "phone") return stay(s, "A phone shows one terminal");
    if (s.views >= VIEWS_MAX) return stay(s, `At most ${VIEWS_MAX} terminals`);
    return withViews(s, s.views + 1, [], `Terminal ${s.views + 1} added`);
  }
  function closeView(device, s, index) {
    if (s.views <= 1 || index < 0 || index >= s.views) return stay(s, "The last terminal cannot be closed");
    return withViews(s, s.views - 1, [], `Terminal ${index + 1} closed; its windows stay in the others`);
  }
  function setSplit(s, split) {
    if (!SPLITS.includes(split)) return stay(s, "");
    return split === s.split ? stay(s, `The terminals are ${SPLIT_WORD[split]}`) : { screen: { ...s, split, weights: [] }, message: `The terminals are now ${SPLIT_WORD[split]}`, changed: true };
  }
  // dragWeights(s, i, delta): the divider after view i moves delta (in weight points); the two beside it keep their sum, and
  // neither goes under 10
  function dragWeights(s, i, delta) {
    if (i < 0 || i >= s.views - 1 || s.split === "grid") return stay(s, "");
    const w = s.weights.length === s.views ? s.weights.slice() : equalWeights(s.views);
    const sum = w[i] + w[i + 1], a = Math.max(10, Math.min(sum - 10, w[i] + Math.round(delta)));
    if (a === w[i]) return stay(s, "");
    w[i] = a; w[i + 1] = sum - a;
    return { screen: { ...s, weights: w }, message: `Terminal ${i + 1} is ${Math.round((100 * a) / w.reduce((x, y) => x + y, 0))} percent`, changed: true };
  }
  // arrange(views, split, weights) -> the grid the views sit in: the tracks (CSS grid templates) and each view's cell
  function arrange(views, split, weights) {
    const w = weights.length === views ? weights : equalWeights(views);
    const fr = (l) => l.map((x) => `${x}fr`).join(" ");
    if (views === 1) return { cols: "1fr", rows: "1fr", cells: [{ col: "1", row: "1" }] };
    if (split === "rows") return { cols: "1fr", rows: fr(w), cells: w.map((_, i) => ({ col: "1", row: String(i + 1) })) };
    if (split === "grid" && views > 2) {
      const cells = [{ col: "1", row: "1" }, { col: "2", row: "1" }, { col: views === 3 ? "1 / 3" : "1", row: "2" }, { col: "2", row: "2" }].slice(0, views);
      return { cols: "1fr 1fr", rows: "1fr 1fr", cells };
    }
    return { cols: fr(w), rows: "1fr", cells: w.map((_, i) => ({ col: String(i + 1), row: "1" })) };
  }
  // a quick command that is not one yet: what is wrong, in words, or "" — the server's limits (uilayout.py commands)
  const printable = (t) => !/[\u0000-\u001F\u007F-\u009F\u2028\u2029]/.test(t);
  function commandProblem(c) {
    const label = c && typeof c.label === "string" ? c.label.trim() : "", text = c && typeof c.text === "string" ? c.text : "";
    if (!label) return "Give it a name";
    if (label.length > COMMAND_LABEL_MAX || !printable(label)) return `A name is at most ${COMMAND_LABEL_MAX} characters`;
    if (!text.trim()) return "Type the command";
    if (text.length > COMMAND_TEXT_MAX) return `A command is at most ${COMMAND_TEXT_MAX} characters`;
    if (!printable(text)) return "A command is one line of printable characters";
    return "";
  }
  const cleanCommand = (c) => ({ label: c.label.trim(), text: c.text, run: c.run === true });
  // normalizeCommands(saved) -> the usable ones, at most COMMANDS_MAX
  const normalizeCommands = (saved) => (Array.isArray(saved) ? saved.filter((c) => c && typeof c === "object" && !commandProblem(c)).slice(0, COMMANDS_MAX).map(cleanCommand) : []);
  function saveCommand(list, c, index) {
    const bad = commandProblem(c);
    if (bad) return { list, message: bad, changed: false };
    if (index == null && list.length >= COMMANDS_MAX) return { list, message: `At most ${COMMANDS_MAX} quick commands`, changed: false };
    const out = list.slice(), one = cleanCommand(c);
    if (index == null) out.push(one); else out[index] = one;
    return { list: out, message: index == null ? `${one.label} added` : `${one.label} saved`, changed: true };
  }
  function removeCommand(list, index) {
    if (index < 0 || index >= list.length) return { list, message: "", changed: false };
    return { list: list.filter((_, i) => i !== index), message: `${list[index].label} removed`, changed: true };
  }
  // the object the document holds for a page and screen ({widgets, views, ...}), and the page's quick commands; null: none kept
  function screenEntry(doc, page, device) {
    const p = doc && typeof doc === "object" && doc.version === VERSION && doc.pages && typeof doc.pages === "object" ? doc.pages[page] : null;
    return p && typeof p === "object" && p[device] && typeof p[device] === "object" && !Array.isArray(p[device]) ? p[device] : null;
  }
  const commandsEntry = (doc) => {
    const p = doc && typeof doc === "object" && doc.version === VERSION && doc.pages && typeof doc.pages === "object" ? doc.pages.terminal : null;
    return p && typeof p === "object" ? normalizeCommands(p.commands) : [];
  };
  // the bodies of a save: this screen (or null: back to the default), and the quick commands (or null: none)
  const savePatchScreen = (device, s) => ({ version: VERSION, pages: { terminal: { [device]: isDefaultScreen(device, s) ? null : s } } });
  const savePatchCommands = (list) => ({ version: VERSION, pages: { terminal: { commands: list.length ? list : null } } });
  // what the key bar sends: the names ttyd-keys.js knows (terminal/ttyd-keys.js has the same table)
  const KEYS = [["esc", "Esc"], ["tab", "Tab"], ["up", "Up"], ["down", "Down"], ["left", "Left"], ["right", "Right"], ["home", "Home"], ["end", "End"],
    ["pgup", "PgUp"], ["pgdn", "PgDn"], ["ctrl-c", "Ctrl-C"], ["ctrl-b", "Ctrl-b"]];
  // the terminals' height in px on the page (Auto: most of the screen, in vh, set by the CSS)
  const TERMINAL_PX = { s: 280, m: 420, l: 640 };

  // --- the Customize tray stays at the top while the page scrolls under it (JON-974) ---
  // Stuck = the 0 px sentinel right before the tray has scrolled out of the top of the scrolling element (a zero-height
  // empty block takes no room and its margins collapse through it, so adding it moves nothing). The tray then compacts to
  // one row (widgets.css, .wg-stuck), and the scroller's scroll-padding-top is the tray's height + a gap, so a handle
  // focused by Tab (or scrolled to) lands below the tray, not under it (WCAG 2.2 SC 2.4.11 Focus Not Obscured).
  const TRAY_GAP = 8;
  const scrollPad = (trayHeight) => (Number.isFinite(trayHeight) && trayHeight > 0 ? Math.ceil(trayHeight) + TRAY_GAP : 0);
  // an observer entry for the sentinel: gone past the top edge (not below the bottom, not merely hidden with the tray)
  const stuckFrom = (e) => !!e && !e.isIntersecting && !!e.rootBounds && !!e.boundingClientRect && e.boundingClientRect.top < e.rootBounds.top;
  // (the Terminal page's tray is the same class and calls this too: scroller is .tp there, #home here; returns the stop)
  function stickTray(tray, scroller) {
    const sentinel = document.createElement("div");
    sentinel.className = "wg-sentinel"; sentinel.setAttribute("aria-hidden", "true");
    tray.before(sentinel);
    const pad = () => { const v = scrollPad(tray.getBoundingClientRect().height); scroller.style.scrollPaddingTop = v ? `${v}px` : ""; };
    let io = null, ro = null;
    if (typeof IntersectionObserver === "function") {
      io = new IntersectionObserver((es) => { for (const e of es) tray.classList.toggle("wg-stuck", stuckFrom(e)); }, { root: scroller, threshold: [0, 1] });
      io.observe(sentinel);
    }
    if (typeof ResizeObserver === "function") { ro = new ResizeObserver(pad); ro.observe(tray); }
    pad();
    return function stop() {
      if (io) io.disconnect();
      if (ro) ro.disconnect();
      sentinel.remove(); tray.classList.remove("wg-stuck"); scroller.style.scrollPaddingTop = "";
    };
  }

  const pure = { TRAY_GAP, scrollPad, stuckFrom, stickTray, VERSION, MAX_BYTES, CACHE, COLS, HEIGHTS, HEIGHT_REM, HOME, TERMINAL, PAGES, available, minSpan, clampSpan, defaults, normalize,
    isDefault, usedSpan, shown, moveBy, moveBefore, setSpan, resizeBy, setHeight, heightStep, hide, show, reset, entry, parseDoc, savePatch, styleFor, rowSpan, titleOf,
    VIEWS_MAX, SPLITS, COMMANDS_MAX, COMMAND_LABEL_MAX, COMMAND_TEXT_MAX, KEYS, TERMINAL_PX, screenDefaults, normalizeScreen, isDefaultScreen, addView, closeView,
    setSplit, dragWeights, arrange, commandProblem, normalizeCommands, saveCommand, removeCommand, screenEntry, commandsEntry, savePatchScreen, savePatchCommands };
  root.bnWidgets = { _pure: pure };
  if (typeof document === "undefined" || typeof document.querySelector !== "function") return;

  // ---------- the page ----------
  const PAGE = "home";
  const home = document.getElementById("home"), host = document.getElementById("widgets"), tray = document.getElementById("widget-tray");
  const openBtn = document.getElementById("customize");
  if (!home || !host || !tray || !openBtn) return;
  const NS = "http://www.w3.org/2000/svg";
  const h = (tag, attrs, ...kids) => {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) if (v !== false && v != null) { if (k === "text") e.textContent = v; else e.setAttribute(k, v === true ? "" : v); }
    e.append(...kids);
    return e;
  };
  const icon = (d) => {
    const s = document.createElementNS(NS, "svg"), p = document.createElementNS(NS, "path");
    s.setAttribute("viewBox", "0 0 20 20"); s.setAttribute("aria-hidden", "true"); p.setAttribute("d", d); s.append(p);
    return s;
  };
  const GRIP = "M7 4.5h.01M13 4.5h.01M7 10h.01M13 10h.01M7 15.5h.01M13 15.5h.01";
  const EYE_OFF = "M3 3l14 14M8.2 5.2A7.6 7.6 0 0 1 10 5c4 0 6.6 3.4 7.5 5a10 10 0 0 1-2.2 2.7M6 6.3C4.3 7.5 3.2 9.1 2.5 10c.9 1.6 3.5 5 7.5 5 1 0 1.9-.2 2.7-.5M8.6 8.6a2 2 0 0 0 2.8 2.8";
  const UP = "M5 12l5-5 5 5";
  const DOWN = "M5 8l5 5 5-5";
  const PHONE = window.matchMedia("(max-width: 767.98px)"), TABLET = window.matchMedia("(max-width: 1099.98px)");
  const REDUCED = window.matchMedia("(prefers-reduced-motion: reduce)");
  const $q = (s, r = document) => r.querySelector(s);

  // --- the widgets in the page, and where the markup has them ---
  const elOf = (id) => home.querySelector(`[data-widget="${id}"]`);
  const widgetEls = () => Array.from(home.querySelectorAll("[data-widget]"));
  // the markup's own order, kept so Reset (and a layout equal to the default) can put every widget back: each parent
  // with its children; a widget is remembered by its id (Send feedback's placeholder is replaced by its card) as {widget},
  // not {id}: the update's progress (<section id="job">) has an id too, and was taken for a widget and dropped on Reset
  const origin = (() => {
    const parents = new Set([host]);
    for (const e of widgetEls()) parents.add(e.parentNode);
    return Array.from(parents).map((p) => ({ parent: p, kids: Array.from(p.children).map((k) => (k.dataset.widget ? { widget: k.dataset.widget } : k)) }));
  })();
  const hostKids = origin[0].kids.filter((k) => !k.widget);
  const wrappers = hostKids.filter((k) => k.querySelector && k.querySelector("[data-widget]"));   // .home-top and .grid: empty while the widgets are in #widgets
  const anchored = hostKids.filter((k) => !wrappers.includes(k));                                      // the update's progress (#job): first, always as wide as the page

  // --- what is kept ---
  let doc = parseDoc((() => { try { return localStorage.getItem(CACHE); } catch (_) { return null; } })());
  const readDevice = () => (PHONE.matches ? "phone" : TABLET.matches ? "tablet" : "desktop");
  let device = readDevice();
  let list = normalize(PAGE, device, entry(doc, PAGE, device));
  let kept = entry(doc, PAGE, device) !== null && !isDefault(PAGE, device, list);   // a saved layout other than the default
  let editing = false, custom = false;
  const pending = {};            // device -> layout | null, not yet saved
  let saveT = null, saveBusy = false, saveFailed = false;
  const cacheDoc = () => { try { localStorage.setItem(CACHE, JSON.stringify(doc)); } catch (_) { /* this tab only */ } };
  const keepLocal = (dev, l) => {
    doc = { version: VERSION, pages: { ...doc.pages, [PAGE]: { ...(doc.pages[PAGE] || {}) } } };
    if (isDefault(PAGE, dev, l)) delete doc.pages[PAGE][dev]; else doc.pages[PAGE][dev] = l;
    cacheDoc();
  };
  async function flush() {
    clearTimeout(saveT); saveT = null;
    const devs = Object.keys(pending);
    if (!devs.length || saveBusy) return;
    saveBusy = true;
    const body = { version: VERSION, pages: { [PAGE]: {} } };
    for (const d of devs) body.pages[PAGE][d] = pending[d];
    const sent = JSON.stringify(body);
    try {
      const r = await fetch("/api/ui/layout", { method: "PUT", credentials: "same-origin", cache: "no-store", keepalive: sent.length < 60000,
        headers: { "X-Requested-With": "devos-ade", "Content-Type": "application/json" }, body: sent });
      if (r.status === 401) { location.assign("/login"); return; }
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      for (const d of devs) if (JSON.stringify(pending[d]) === JSON.stringify(body.pages[PAGE][d])) delete pending[d];
      saveFailed = false;
    } catch (_) { saveFailed = true; } finally { saveBusy = false; }
    status();
    if (Object.keys(pending).length && !saveFailed) saveT = setTimeout(flush, 100);
  }
  function remember(dev, l) {
    keepLocal(dev, l);
    pending[dev] = isDefault(PAGE, dev, l) ? null : l;
    clearTimeout(saveT); saveT = setTimeout(flush, 400);
  }
  window.addEventListener("pagehide", () => { if (Object.keys(pending).length) flush(); });
  document.addEventListener("visibilitychange", () => { if (document.hidden && Object.keys(pending).length) flush(); });

  // --- the words for assistive technology (and the tray's status line) ---
  const live = $q("#wg-live", tray);
  let sayN = 0;
  function say(msg) {
    if (!msg) return;
    sayN += 1;
    live.textContent = sayN % 2 ? msg : `${msg} `;   // (the same words twice in a row are still announced)
  }
  function status() {
    $q("#wg-saved", tray).textContent = saveFailed ? "Not saved on this computer: your changes are kept in this browser for now." : "";
  }

  // --- the grid ---
  const overlays = new Map();     // id -> overlay element (edit mode)
  const ro = typeof ResizeObserver === "function" ? new ResizeObserver(() => later()) : null;
  let laterQ = false;
  function later() { if (laterQ) return; laterQ = true; requestAnimationFrame(() => { laterQ = false; measure(); }); }
  // the span a widget is laid out with now (see usedSpan): the widgets that hide themselves are the ones with a `hidden` attribute
  const gone = () => widgetEls().filter((w) => w.hidden).map((w) => w.dataset.widget);
  const spanOf = (id) => usedSpan(PAGE, device, list, id, gone());
  // the rows each widget spans, and the edit bars where the widgets are (after any resize)
  function measure() {
    if (!custom) return;
    const phone = device === "phone";
    const away = gone();
    for (const e of list) {
      const w = elOf(e.id);
      if (!w) continue;
      const cols = styleFor(e, device, usedSpan(PAGE, device, list, e.id, away)).columns;
      if (w.style.gridColumn !== cols) w.style.gridColumn = cols;
      const ov = overlays.get(e.id);
      if (ov) ov.hidden = e.hidden || w.offsetParent === null;
      // (room at the top of the card for its bar)
      const pad = ov && !ov.hidden ? `${ov.firstElementChild.offsetHeight + 14}px` : "";
      if (w.style.paddingTop !== pad) w.style.paddingTop = pad;
      const rows = phone || e.hidden || w.hidden ? "" : `span ${rowSpan(w.offsetHeight)}`;
      if (w.style.gridRowEnd !== rows) w.style.gridRowEnd = rows;
      if (w.id === "update-card") w.toggleAttribute("data-wide", w.clientWidth >= 720);
    }
    for (const j of anchored) {   // (the update's progress is no widget, but it takes rows too)
      const rows = phone || j.hidden ? "" : `span ${rowSpan(j.offsetHeight)}`;
      if (j.style.gridRowEnd !== rows) j.style.gridRowEnd = rows;
    }
    if (editing) for (const e of list) {
      const w = elOf(e.id), ov = overlays.get(e.id);
      if (!w || !ov || ov.hidden) continue;
      ov.style.left = `${w.offsetLeft}px`; ov.style.top = `${w.offsetTop}px`; ov.style.width = `${w.offsetWidth}px`; ov.style.height = `${w.offsetHeight}px`;
      const size = $q(".wg-size", ov);
      if (size) size.textContent = `${usedSpan(PAGE, device, list, e.id, away)} / ${COLS[device]}`;
    }
  }
  // the hosts' children in layout order, moving only what is out of place
  function place(nodes) {
    let cur = host.firstElementChild;
    for (const n of nodes) { if (n === cur) cur = cur.nextElementSibling; else host.insertBefore(n, cur); }
  }
  function dropOverlays() {
    for (const ov of overlays.values()) ov.remove();
    overlays.clear();
  }
  function enterGrid() {
    if (!editing) dropOverlays();
    host.classList.add("wg-custom");
    host.classList.toggle("wg-phone", device === "phone");
    host.classList.toggle("wg-tablet", device === "tablet");
    host.classList.toggle("wg-desktop", device === "desktop");
    const nodes = [...anchored];
    for (const e of list) {
      const w = elOf(e.id);
      if (!w) continue;
      nodes.push(w);
      if (editing) nodes.push(overlayOf(e.id));
    }
    place([...nodes, ...wrappers]);
    if (ro) ro.observe(host);
    for (const j of anchored) if (ro) ro.observe(j);
    for (const e of list) {
      const w = elOf(e.id);
      if (!w) continue;
      const s = styleFor(e, device, usedSpan(PAGE, device, list, e.id, gone()));
      w.style.gridColumn = s.columns; w.style.maxHeight = s.maxHeight; w.style.overflowY = s.maxHeight ? "auto" : "";
      w.classList.toggle("wg-off", e.hidden);
      w.dataset.wgHeight = e.height;
      w.inert = editing;
      if (ro) ro.observe(w);
    }
  }
  function leaveGrid() {
    if (ro) ro.disconnect();
    dropOverlays();
    host.classList.remove("wg-custom", "wg-phone", "wg-tablet", "wg-desktop");
    for (const j of anchored) j.style.gridRowEnd = "";
    for (const w of widgetEls()) {
      for (const p of ["gridColumn", "gridRowEnd", "maxHeight", "overflowY", "paddingTop"]) w.style[p] = "";
      w.classList.remove("wg-off", "wg-peek"); delete w.dataset.wgHeight; w.removeAttribute("data-wide"); w.inert = false;
      if (!w.getAttribute("style")) w.removeAttribute("style");
    }
    for (const o of origin.slice(1)) o.parent.replaceChildren(...o.kids.map((k) => (k.widget ? elOf(k.widget) : k)).filter(Boolean));
    host.replaceChildren(...origin[0].kids.map((k) => (k.widget ? elOf(k.widget) : k)).filter(Boolean));
  }
  let stopStick = null;
  // the layout on screen: the page's own, or the grid
  function apply() {
    const want = editing || kept;
    const active = document.activeElement;
    if (custom && !want) leaveGrid();
    custom = want;
    home.classList.toggle("wg-editing", editing);
    tray.hidden = !editing;
    // (the sentinel is watched only while the tray shows: a hidden one never intersects and would read as stuck)
    if (editing && !stopStick) stopStick = pure.stickTray(tray, home);
    else if (!editing && stopStick) { stopStick(); stopStick = null; }
    openBtn.setAttribute("aria-expanded", String(editing));
    if (custom) {
      enterGrid();
      measure();
      if (editing) { paintBars(); paintTray(); }
    }
    if (active && active !== document.activeElement && active.isConnected && !active.inert) active.focus({ preventScroll: true });
  }

  // --- edit mode: the bar and handles over each widget ---
  const label = (id) => titleOf(PAGE, id);
  function overlayOf(id) {
    let ov = overlays.get(id);
    if (ov) return ov;
    const t = label(id);
    const grip = h("button", { type: "button", class: "wg-btn wg-grip", "data-act": "grip", "aria-label": `${t}: move, resize or hide`, "aria-describedby": "wg-help",
      "aria-keyshortcuts": "ArrowLeft ArrowRight ArrowUp ArrowDown Shift+ArrowLeft Shift+ArrowRight Shift+ArrowUp Shift+ArrowDown H",
      title: "Drag to move. Arrow keys move it, Shift with the arrows resizes it, H hides it." }, icon(GRIP));
    const heights = h("div", { class: "wg-heights", role: "group", "aria-label": `${t} height` },
      ...HEIGHTS.map((k) => h("button", { type: "button", class: "wg-btn wg-h", "data-act": "height", "data-height": k, "aria-pressed": "false",
        "aria-label": `${t} height: ${HEIGHT_WORD[k]}`, title: k === "auto" ? "As tall as its content" : `At most ${HEIGHT_REM[k]} rem tall; more scrolls inside` }, HEIGHT_SHORT[k])));
    const up = h("button", { type: "button", class: "wg-btn wg-move wg-up", "data-act": "up", "aria-label": `Move ${t} up`, title: "Move up" }, icon(UP));
    const down = h("button", { type: "button", class: "wg-btn wg-move wg-down", "data-act": "down", "aria-label": `Move ${t} down`, title: "Move down" }, icon(DOWN));
    const eye = h("button", { type: "button", class: "wg-btn wg-hide", "data-act": "hide", "aria-label": `Hide ${t}`, title: "Hide (it comes back from the Widgets tray)" }, icon(EYE_OFF));
    const bar = h("div", { class: "wg-bar" }, grip, h("span", { class: "wg-name", text: t }), h("span", { class: "wg-size", "aria-hidden": "true" }), heights, up, down, eye);
    ov = h("div", { class: "wg-ov", role: "group", "aria-label": `${t} widget`, "data-for": id }, bar,
      h("div", { class: "wg-rz wg-rz-e", "aria-hidden": "true", "data-rz": "e" }), h("div", { class: "wg-rz wg-rz-s", "aria-hidden": "true", "data-rz": "s" }),
      h("div", { class: "wg-rz wg-rz-se", "aria-hidden": "true", "data-rz": "se" }));
    overlays.set(id, ov);
    wire(ov, id);
    return ov;
  }
  function paintBars() {
    for (const e of list) {
      const ov = overlays.get(e.id);
      if (!ov) continue;
      for (const b of ov.querySelectorAll(".wg-h")) b.setAttribute("aria-pressed", String(b.dataset.height === e.height));
    }
  }
  function paintTray() {
    const hidden = list.filter((e) => e.hidden), ul = $q("#wg-hidden", tray);
    ul.replaceChildren(...hidden.map((e) => h("li", { "data-for": e.id }, h("span", { class: "wg-hidden-name", text: label(e.id) }),
      h("button", { type: "button", class: "quiet", "data-act": "add", "data-id": e.id, "aria-label": `Add back ${label(e.id)}` }, "Add back"))));
    $q("#wg-none", tray).hidden = hidden.length > 0;
    ul.hidden = hidden.length === 0;
  }
  const focusGrip = (id) => { const g = overlays.get(id) && $q(".wg-grip", overlays.get(id)); if (g && g.offsetParent !== null) g.focus({ preventScroll: true }); else { const m = overlays.get(id) && overlays.get(id).querySelector(".wg-hide, .wg-h"); if (m) m.focus({ preventScroll: true }); } };
  const into = (id) => { const w = elOf(id); if (w && w.offsetParent !== null) w.scrollIntoView({ block: "nearest", behavior: REDUCED.matches ? "auto" : "smooth" }); };

  // a change: the new list, kept, drawn and announced
  function commit(r, focusId) {
    if (!r) return;
    if (r.message) say(r.message);
    if (!r.changed) return;
    list = r.list;
    kept = !isDefault(PAGE, device, list);
    remember(device, list);
    apply();
    if (focusId) { focusGrip(focusId); into(focusId); }
  }

  function wire(ov, id) {
    ov.addEventListener("click", (ev) => {
      const b = ev.target.closest("[data-act]");
      if (!b) return;
      const act = b.dataset.act;
      if (act === "hide") {
        const v = shown(list), i = v.findIndex((e) => e.id === id), next = (v[i + 1] || v[i - 1] || {}).id;
        commit(hide(PAGE, list, id));
        const add = $q(`#wg-hidden [data-id="${id}"]`, tray);
        if (add) add.focus({ preventScroll: true }); else if (next) focusGrip(next);
      } else if (act === "height") commit(setHeight(PAGE, list, id, b.dataset.height), id);
      else if (act === "up" || act === "down") { commit(moveBy(PAGE, list, id, act === "up" ? -1 : 1)); b.focus({ preventScroll: true }); into(id); }
    });
    $q(".wg-grip", ov).addEventListener("keydown", (ev) => {
      if (ev.altKey || ev.ctrlKey || ev.metaKey || device === "phone") return;
      const k = ev.key, s = ev.shiftKey;
      let r = null;
      if (k === "ArrowLeft" || k === "ArrowUp") r = s ? (k === "ArrowLeft" ? setSpan(PAGE, device, list, id, spanOf(id) - 1, spanOf(id)) : heightStep(PAGE, list, id, -1)) : moveBy(PAGE, list, id, -1);
      else if (k === "ArrowRight" || k === "ArrowDown") r = s ? (k === "ArrowRight" ? setSpan(PAGE, device, list, id, spanOf(id) + 1, spanOf(id)) : heightStep(PAGE, list, id, 1)) : moveBy(PAGE, list, id, 1);
      else if ((k === "h" || k === "H") && !s) { ev.preventDefault(); $q('[data-act="hide"]', ov).click(); return; }
      else return;
      ev.preventDefault();
      commit(r, id);
    });
    // drag to move; an edge or a corner to resize (snapping to whole columns, and to S, M, L or Auto)
    ov.addEventListener("pointerdown", (ev) => {
      if (ev.button > 0 || device === "phone") return;
      const grip = ev.target.closest(".wg-grip"), rz = ev.target.closest(".wg-rz");
      if (grip) drag(ev, id); else if (rz) resize(ev, id, rz.dataset.rz);
    });
  }

  let gesture = null;   // {end(cancelled)} while a drag or a resize runs
  // (the pointer is captured by #widgets, which stays put: a widget moved in the page while it is dragged would lose it)
  function track(ev, target, move, end) {
    ev.preventDefault();
    try { target.setPointerCapture(ev.pointerId); } catch (_) { /* fine */ }
    const done = (cancel) => {
      target.removeEventListener("pointermove", move); target.removeEventListener("pointerup", up); target.removeEventListener("pointercancel", cancelled);
      try { target.releasePointerCapture(ev.pointerId); } catch (_) { /* fine */ }
      gesture = null;
      home.classList.remove("wg-gesture");
      end(cancel);
    };
    const up = () => done(false), cancelled = () => done(true);
    target.addEventListener("pointermove", move); target.addEventListener("pointerup", up); target.addEventListener("pointercancel", cancelled);
    gesture = { end: done };
    home.classList.add("wg-gesture");
  }
  function drag(ev, id) {
    const start = list, w = elOf(id), scroller = home;
    let last = { x: ev.clientX, y: ev.clientY }, moved = false, t = null, py = ev.clientY;
    w.classList.add("wg-dragging");
    t = setInterval(() => {   // (near the top or bottom of the page: it scrolls)
      const r = scroller.getBoundingClientRect(), edge = 56;
      if (py < r.top + edge) scroller.scrollTop -= 14; else if (py > r.bottom - edge) scroller.scrollTop += 14;
    }, 30);
    track(ev, host, (m) => {
      py = m.clientY;
      if (Math.hypot(m.clientX - last.x, m.clientY - last.y) < 24 && moved) return;   // (after a move, the pointer travels a little before the next: no flip-flop)
      const over = shown(list).filter((e) => e.id !== id).map((e) => ({ e, r: elOf(e.id).getBoundingClientRect() }))
        .find(({ r }) => m.clientX >= r.left && m.clientX <= r.right && m.clientY >= r.top && m.clientY <= r.bottom);
      if (!over) return;
      // the upper-left half of a widget is "before it", the lower-right half "after it"
      const before = (m.clientX - over.r.left) / over.r.width + (m.clientY - over.r.top) / over.r.height < 1;
      const v = shown(list).filter((e) => e.id !== id), at = v.findIndex((e) => e.id === over.e.id);
      const r = moveBefore(PAGE, list, id, before ? over.e.id : (v[at + 1] ? v[at + 1].id : null));
      if (!r.changed) return;
      list = r.list; moved = true; last = { x: m.clientX, y: m.clientY };
      apply();
    }, (cancel) => {
      clearInterval(t);
      w.classList.remove("wg-dragging");
      if (cancel) { list = start; apply(); return; }
      if (same(list, start)) return;
      kept = !isDefault(PAGE, device, list);
      remember(device, list);
      say(placed(PAGE, list, id));
      apply();
      focusGrip(id);
    });
  }
  function resize(ev, id, edge) {
    const start = list, w = elOf(id), span0 = spanOf(id), x0 = ev.clientX, y0 = ev.clientY, h0 = w.offsetHeight;
    const gap = 24, pitch = (host.clientWidth + gap) / COLS[device];
    const natural = (() => { const was = w.style.maxHeight; w.style.maxHeight = ""; const n = w.scrollHeight; w.style.maxHeight = was; return n; })();
    const px = { s: HEIGHT_REM.s * 16, m: HEIGHT_REM.m * 16, l: HEIGHT_REM.l * 16, auto: Math.max(natural, HEIGHT_REM.l * 16 + 1) };
    track(ev, host, (m) => {
      let r = { list: start };
      if (edge.includes("e")) r = setSpan(PAGE, device, r.list, id, span0 + Math.round((m.clientX - x0) / pitch), span0);
      if (edge.includes("s")) {
        const want = h0 + (m.clientY - y0);
        const best = HEIGHTS.slice().sort((a, b) => Math.abs(px[a] - want) - Math.abs(px[b] - want))[0];
        r = setHeight(PAGE, r.list, id, best);
      }
      if (same(r.list, list)) return;
      list = r.list; apply();
    }, (cancel) => {
      if (cancel) { list = start; apply(); return; }
      if (same(list, start)) return;
      kept = !isDefault(PAGE, device, list);
      remember(device, list);
      const e = get(list, id), was = get(start, id);
      say(e.span !== was.span ? `${label(id)} is ${e.span} of ${COLS[device]} columns wide` : `${label(id)} height: ${HEIGHT_WORD[e.height]}`);
      apply();
    });
  }

  // --- the tray, Customize, Done, Reset, Escape ---
  function edit(on) {
    if (on === editing) return;
    if (!on && gesture) gesture.end(true);
    editing = on;
    if (on) {
      apply();
      const t = $q("#wg-tray-title", tray);
      t.focus({ preventScroll: false });
      say("Customizing Home. Focus a widget's handle: the arrow keys move it, Shift with the arrows resizes it, H hides it.");
    } else {
      kept = !isDefault(PAGE, device, list);
      apply();
      say("Done customizing Home");
      openBtn.focus({ preventScroll: true });
    }
  }
  openBtn.addEventListener("click", () => edit(!editing));
  $q("#wg-done", tray).addEventListener("click", () => edit(false));
  $q("#wg-reset", tray).addEventListener("click", () => {
    const r = reset(PAGE, device);
    list = r.list; kept = false;
    remember(device, list);
    say(r.message);
    apply();
  });
  $q("#wg-hidden", tray).addEventListener("click", (ev) => {
    const b = ev.target.closest("[data-act=add]");
    if (!b) return;
    commit(show(PAGE, list, b.dataset.id), null);
    const id = b.dataset.id;
    requestAnimationFrame(() => { focusGrip(id); into(id); });
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "Escape" || !editing || home.hidden || ev.defaultPrevented || document.querySelector("dialog[open]")) return;
    if (gesture) { gesture.end(true); ev.preventDefault(); return; }
    edit(false);
  });

  // an update the person hid is still announced in Home's header; following that link shows the card for now (not saved)
  function peek(id) {
    const w = elOf(id);
    if (w && w.classList.contains("wg-off")) w.classList.add("wg-peek");
  }

  // --- a kind of screen changes (a window resized across a breakpoint, a tablet turned) ---
  function screen() {
    const d = readDevice();
    if (d === device) return;
    if (gesture) gesture.end(true);
    if (custom) leaveGrid();
    custom = false;
    device = d;
    list = normalize(PAGE, device, entry(doc, PAGE, device));
    kept = entry(doc, PAGE, device) !== null && !isDefault(PAGE, device, list);
    apply();
  }
  PHONE.addEventListener("change", screen); TABLET.addEventListener("change", screen);

  // --- the server's copy: read once Home is up; it wins over the cache (another browser may have changed it) ---
  async function load() {
    try {
      const r = await fetch("/api/ui/layout", { credentials: "same-origin", cache: "no-store", headers: { "X-Requested-With": "devos-ade" } });
      if (!r.ok) return;
      const d = parseDoc(await r.json());
      if (editing || gesture || Object.keys(pending).length) return;
      if (JSON.stringify(d.pages) === JSON.stringify(doc.pages)) return;
      doc = d; cacheDoc();
      list = normalize(PAGE, device, entry(doc, PAGE, device));
      kept = entry(doc, PAGE, device) !== null && !isDefault(PAGE, device, list);
      apply();
    } catch (_) { /* offline: the cache stands */ }
  }

  apply();
  load();
  root.bnWidgets = { _pure: pure, peek, edit, layout: () => list.map((e) => ({ ...e })), device: () => device, editing: () => editing };
})(typeof window !== "undefined" ? window : globalThis);
