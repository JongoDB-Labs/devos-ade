// The Terminal tab as a page of widgets (JON-946): 1 to 4 terminals in a split, a key bar, the person's quick commands and the
// project folders, each shown, hidden, moved and resized like Home's cards (the model is widgets.js's, a terminal screen in
// it; the server's copy, portal/uilayout.py: GET and PUT /api/ui/layout, with bn.layout.terminal here as a cache read first).
// Until a person customizes it (or on a tablet or phone, which start with the key bar on) the tab is what it always was: the
// one frame of the terminal under Who answers' bar, and this file moves nothing. Customize (in that bar) turns on the page:
//   Terminals   the views — view 1 is the terminal's session "claude", views 2 to 4 each a session grouped with it (view-N:
//               the same windows, its own current one; bn-session view N TOKEN, a token the portal makes on the click that
//               adds one, and asks again for after a reload). Each view's tmux status line is its tab strip. Close only
//               detaches a view: its windows stay. A divider between two views moves their shares (arrows too).
//   Key bar     Esc, Tab, Ctrl and Alt (held for the next key), the arrows, Home/End, PgUp/PgDn, Ctrl-C and Ctrl-b (tmux's
//               prefix), sent to the view that has the keyboard — as messages to its frame, which terminal/ttyd-keys.js (a
//               script of ttyd's page that reads only the window that frames it) turns into keys. A button never takes the
//               keyboard from the terminal.
//   Quick commands  a click types the command into that view; Enter only for one marked "run".
//   Projects    the project folders the pickers know: "Open a shell here" (the launch `open shell TOKEN DIR`) in view 1.
// The frames stay in #frames and are never moved (a moved frame would reload): while the page is on, each is placed over its
// slot in the page, from the slot's box. Text only: nothing is parsed as HTML.
"use strict";

(() => {
  const W = window.bnWidgets && window.bnWidgets._pure;
  if (!W || typeof APP_URLS === "undefined" || !APP_URLS.terminal) return;   // (the terminal is off here, or widgets.js did not load)
  const stage = document.querySelector(".stage"), frames = document.getElementById("frames");
  if (!stage || !frames) return;

  const PAGE = "terminal", CACHE = "bn.layout.terminal", NS = "http://www.w3.org/2000/svg";
  const PHONE = window.matchMedia("(max-width: 767.98px)"), TABLET = window.matchMedia("(max-width: 1099.98px)");
  const REDUCED = window.matchMedia("(prefers-reduced-motion: reduce)");
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
  const UP = "M5 12l5-5 5 5", DOWN = "M5 8l5 5 5-5", NARROW = "M12 5l-5 5 5 5", WIDE = "M8 5l5 5-5 5";
  const EYE_OFF = "M3 3l14 14M8.2 5.2A7.6 7.6 0 0 1 10 5c4 0 6.6 3.4 7.5 5a10 10 0 0 1-2.2 2.7M6 6.3C4.3 7.5 3.2 9.1 2.5 10c.9 1.6 3.5 5 7.5 5 1 0 1.9-.2 2.7-.5M8.6 8.6a2 2 0 0 0 2.8 2.8";
  const HEIGHT_WORD = { auto: "automatic", s: "small", m: "medium", l: "large" }, HEIGHT_SHORT = { auto: "Auto", s: "S", m: "M", l: "L" };
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const termOrigin = (() => { try { return new URL(appUrl("terminal")).origin; } catch (_) { return ""; } })();

  // ---------- what is kept ----------
  const readDevice = () => (PHONE.matches ? "phone" : TABLET.matches ? "tablet" : "desktop");
  let device = readDevice();
  let doc = (() => { try { return W.parseDoc(localStorage.getItem(CACHE)); } catch (_) { return W.parseDoc(null); } })();
  let screen = W.normalizeScreen(device, W.screenEntry(doc, PAGE, device));
  let commands = W.commandsEntry(doc);
  const pending = { screens: {}, commands: undefined };
  let saveT = null, saveBusy = false, saveFailed = false;
  const cacheDoc = () => { try { localStorage.setItem(CACHE, JSON.stringify(doc)); } catch (_) { /* this tab only */ } };
  function keep(dev, s) {
    const t = { ...(doc.pages[PAGE] || {}) };
    if (W.isDefaultScreen(dev, s)) delete t[dev]; else t[dev] = s;
    doc = { version: W.VERSION, pages: { ...doc.pages, [PAGE]: t } };
    cacheDoc();
    pending.screens[dev] = W.isDefaultScreen(dev, s) ? null : s;
    queue();
  }
  function keepCommands(list) {
    const t = { ...(doc.pages[PAGE] || {}) };
    if (list.length) t.commands = list; else delete t.commands;
    doc = { version: W.VERSION, pages: { ...doc.pages, [PAGE]: t } };
    cacheDoc();
    pending.commands = list.length ? list : null;
    queue();
  }
  const queue = () => { clearTimeout(saveT); saveT = setTimeout(flush, 400); };
  async function flush() {
    clearTimeout(saveT); saveT = null;
    if (saveBusy || (!Object.keys(pending.screens).length && pending.commands === undefined)) return;
    saveBusy = true;
    const sent = { screens: { ...pending.screens }, commands: pending.commands };
    const body = JSON.stringify({ version: W.VERSION, pages: { [PAGE]: { ...sent.screens, ...(sent.commands !== undefined ? { commands: sent.commands } : {}) } } });
    try {
      const r = await fetch("/api/ui/layout", { method: "PUT", credentials: "same-origin", cache: "no-store", keepalive: body.length < 60000,
        headers: { "X-Requested-With": "devos-ade", "Content-Type": "application/json" }, body });
      if (r.status === 401) { location.assign("/login"); return; }
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      for (const d of Object.keys(sent.screens)) if (same(pending.screens[d], sent.screens[d])) delete pending.screens[d];
      if (same(pending.commands, sent.commands)) pending.commands = undefined;
      saveFailed = false;
    } catch (_) { saveFailed = true; } finally { saveBusy = false; }
    $("#term-saved").textContent = saveFailed ? "Not saved on this computer: your changes are kept in this browser for now." : "";
    if ((Object.keys(pending.screens).length || pending.commands !== undefined) && !saveFailed) saveT = setTimeout(flush, 100);
  }
  const unsaved = () => Object.keys(pending.screens).length > 0 || pending.commands !== undefined;
  window.addEventListener("pagehide", () => { if (unsaved()) flush(); });
  document.addEventListener("visibilitychange", () => { if (document.hidden && unsaved()) flush(); });

  // ---------- the page ----------
  let editing = false, built = false, current = false;
  const shownWidgets = () => W.shown(screen.widgets);
  // the page is on when something other than the one terminal is asked for (or the person is customizing)
  const engaged = () => editing || !W.isDefaultScreen(device, screen) || shownWidgets().some((e) => e.id !== "terminals");

  const live = h("p", { class: "tp-live", id: "term-live", role: "status", "aria-live": "polite" });
  let sayN = 0;
  function say(msg) {
    if (!msg) return;
    sayN += 1;
    live.textContent = sayN % 2 ? msg : `${msg} `;
    const st = $("#term-status");
    if (st) st.textContent = msg;
  }

  const page = h("section", { id: "term-page", class: "tp", "aria-label": "Terminal", hidden: true });
  const tray = h("section", { id: "term-tray", class: "wg-tray tp-tray", "aria-labelledby": "term-tray-title", hidden: true });
  const grid = h("div", { id: "term-grid", class: "tp-grid" });
  page.append(tray, grid, live);
  stage.insertBefore(page, frames);

  // --- the views: one pane each, its frame placed over the pane's slot ---
  const panes = [];       // {n, el, slot, frame, bar, label, close}
  let focused = 0;        // index in panes: where keys and commands go
  const frameOf = (n) => (n === 1 ? appFrame("terminal") : frames.querySelector(`iframe[data-app="terminal-${n}"]`));
  function viewFrame(n) {
    let f = frameOf(n);
    if (f) return f;
    f = h("iframe", { "data-app": `terminal-${n}`, title: `Terminal ${n}`, allow: "clipboard-read; clipboard-write" });
    f.hidden = true;
    frames.append(f);
    return f;
  }
  // a view's address needs a launch token the portal makes now, on this click or this page load (answers.js launch)
  async function openView(n, f) {
    if (n === 1) { if (!f.src || f.src === "about:blank") f.src = appUrl("terminal"); return; }
    try { f.src = await window.bnAnswers.launch("view", String(n), ""); } catch (e) { if (e.message !== "signed out") toast(`Could not open Terminal ${n}: ${e.message}`); }
  }
  const unused = () => [1, 2, 3, 4].find((n) => !panes.some((p) => p.n === n));
  function makePane(n) {
    const label = h("span", { class: "tp-pane-name", text: `Terminal ${n}` });
    const close = h("button", { type: "button", class: "wg-btn tp-close", "aria-label": `Close terminal ${n}`, title: "Close this view. Its windows stay in the others.", text: "Close" });
    const bar = h("div", { class: "tp-pane-bar" }, label, close);
    const slot = h("div", { class: "tp-slot" });
    const el = h("div", { class: "tp-pane", role: "group", "aria-label": `Terminal ${n}`, "data-view": String(n) }, bar, slot);
    const p = { n, el, slot, frame: viewFrame(n), label, close };
    close.addEventListener("click", () => closeAt(panes.indexOf(p)));
    return p;
  }
  function syncPanes() {
    // the panes the screen asks for: the first `views`, view 1 first (a reload starts again from 1)
    while (panes.length > screen.views) detach(panes.pop());
    while (panes.length < screen.views) {
      const p = makePane(panes.length === 0 ? 1 : unused());
      panes.push(p);
      openView(p.n, p.frame);
    }
    if (focused >= panes.length) focused = panes.length - 1;
  }
  function detach(p) {
    // (a closed view only detaches: its tmux session and windows stay; the first view's frame stays in the page for the tab)
    p.el.remove();
    if (p.n === 1) { p.frame.hidden = true; p.frame.src = "about:blank"; } else p.frame.remove();
  }

  // --- the Terminals widget: add, split, the panes and their dividers ---
  const viewsBox = h("div", { class: "tp-views" });
  const addBtn = h("button", { type: "button", class: "quiet tp-add", id: "term-add", text: "Add a terminal" });
  const splitBox = h("div", { class: "tp-split", role: "radiogroup", "aria-label": "How the terminals are split" },
    ...[["cols", "Side by side"], ["rows", "Stacked"], ["grid", "2 by 2"]].map(([k, t]) =>
      h("button", { type: "button", class: "wg-btn tp-split-b", role: "radio", "data-split": k, "aria-checked": "false", text: t })));
  const termTools = h("div", { class: "tp-tools" }, addBtn, splitBox);
  const dividers = [];
  function paintViews() {
    const a = W.arrange(screen.views, screen.split, screen.weights);
    viewsBox.style.gridTemplateColumns = a.cols; viewsBox.style.gridTemplateRows = a.rows;
    panes.forEach((p, i) => {
      p.el.style.gridColumn = a.cells[i].col; p.el.style.gridRow = a.cells[i].row;
      p.close.hidden = panes.length < 2;
      p.el.classList.toggle("tp-focus", i === focused && panes.length > 1);
      if (i === focused) p.el.setAttribute("aria-current", "true"); else p.el.removeAttribute("aria-current");
    });
    viewsBox.replaceChildren(...panes.map((p) => p.el));
    // dividers between two views (side by side or stacked): moved by dragging or the arrow keys
    dividers.length = 0;
    if (screen.views > 1 && screen.split !== "grid") {
      const w = screen.weights.length === screen.views ? screen.weights : Array(screen.views).fill(50), sum = w.reduce((x, y) => x + y, 0);
      let acc = 0;
      for (let i = 0; i < screen.views - 1; i++) {
        acc += w[i];
        const vert = screen.split === "cols";
        const d = h("div", { class: `tp-div tp-div-${vert ? "v" : "h"}`, role: "separator", tabindex: "0", "aria-orientation": vert ? "vertical" : "horizontal",
          "aria-label": `Resize terminals ${i + 1} and ${i + 2}`, "aria-valuemin": "10", "aria-valuemax": "90", "aria-valuenow": String(Math.round((100 * w[i]) / (w[i] + w[i + 1]))),
          "data-i": String(i) });
        const at = `calc((100% - ${(screen.views - 1) * 6}px) * ${acc / sum} + ${i * 6 + 3}px - 11px)`;
        if (vert) d.style.left = at; else d.style.top = at;
        wireDivider(d, i, vert);
        dividers.push(d);
        viewsBox.append(d);
      }
    }
    addBtn.disabled = device === "phone" || screen.views >= W.VIEWS_MAX;
    addBtn.title = device === "phone" ? "A phone shows one terminal" : screen.views >= W.VIEWS_MAX ? `At most ${W.VIEWS_MAX} terminals` : "A terminal beside this one, with its own window in front";
    splitBox.hidden = screen.views < 2;
    for (const b of splitBox.children) { b.setAttribute("aria-checked", String(b.dataset.split === screen.split)); b.setAttribute("tabindex", b.dataset.split === screen.split ? "0" : "-1"); }
    termTools.hidden = !engaged() || (device === "phone" && !editing);
  }
  function wireDivider(d, i, vert) {
    const move = (delta) => change(W.dragWeights(screen, i, delta), false);
    d.addEventListener("keydown", (ev) => {
      const back = vert ? "ArrowLeft" : "ArrowUp", fwd = vert ? "ArrowRight" : "ArrowDown";
      if (ev.key !== back && ev.key !== fwd) return;
      ev.preventDefault();
      move(ev.key === fwd ? 5 : -5);
      const again = viewsBox.querySelector(`.tp-div[data-i="${i}"]`);
      if (again) again.focus({ preventScroll: true });
    });
    d.addEventListener("pointerdown", (ev) => {
      ev.preventDefault();
      const box = viewsBox.getBoundingClientRect(), total = (vert ? box.width : box.height) - (screen.views - 1) * 6;
      const w0 = screen.weights.length === screen.views ? screen.weights : Array(screen.views).fill(50), sum = w0.reduce((x, y) => x + y, 0);
      const start = screen, from = vert ? ev.clientX : ev.clientY;
      d.setPointerCapture(ev.pointerId);
      document.body.classList.add("tp-dragging");
      const onMove = (m) => {
        const r = W.dragWeights(start, i, (((vert ? m.clientX : m.clientY) - from) / total) * sum);
        if (r.screen !== screen) { screen = r.screen; paintViews(); place(); }
      };
      const end = () => {
        d.removeEventListener("pointermove", onMove); d.removeEventListener("pointerup", end); d.removeEventListener("pointercancel", end);
        document.body.classList.remove("tp-dragging");
        if (screen !== start) { keep(device, screen); say(W.dragWeights(start, i, 0).message || "Terminals resized"); }
      };
      d.addEventListener("pointermove", onMove); d.addEventListener("pointerup", end); d.addEventListener("pointercancel", end);
    });
  }

  // --- the key bar ---
  let ctrl = false, alt = false;
  const keyBtn = (name, text, aria) => h("button", { type: "button", class: "wg-btn tp-key", "data-key": name, "aria-label": aria, text });
  const modBtn = (name, text, aria) => h("button", { type: "button", class: "wg-btn tp-key tp-mod", "data-mod": name, "aria-pressed": "false", "aria-label": aria, text });
  const NAMES = { esc: "Escape", tab: "Tab", up: "Up arrow", down: "Down arrow", left: "Left arrow", right: "Right arrow", home: "Home", end: "End", pgup: "Page up", pgdn: "Page down", "ctrl-c": "Control C, interrupt", "ctrl-b": "Control B, tmux's prefix" };
  const SHOWN = { up: "↑", down: "↓", left: "←", right: "→" };
  const keybar = h("div", { class: "tp-keys", role: "toolbar", "aria-label": "Terminal keys: they go to the terminal you last used" },
    ...W.KEYS.slice(0, 2).map(([k, t]) => keyBtn(k, SHOWN[k] || t, NAMES[k])),
    modBtn("ctrl", "Ctrl", "Control, held for the next key"), modBtn("alt", "Alt", "Alt, held for the next key"),
    ...W.KEYS.slice(2).map(([k, t]) => keyBtn(k, SHOWN[k] || t, NAMES[k])));
  function paintMods() {
    for (const b of keybar.querySelectorAll(".tp-mod")) b.setAttribute("aria-pressed", String(b.dataset.mod === "ctrl" ? ctrl : alt));
  }
  const paneFrame = () => (panes[focused] ? panes[focused].frame : null);
  function post(frame, msg) {
    if (frame && frame.contentWindow && termOrigin) frame.contentWindow.postMessage(msg, termOrigin);
  }
  // after a button: the keyboard goes back to the terminal that had it
  function back() {
    const f = paneFrame();
    if (!f) return;
    f.focus({ preventScroll: true });
    post(f, { type: "focus" });
  }
  function sendMods() { post(paneFrame(), { type: "mods", ctrl, alt }); paintMods(); }
  // a button of the key bar or the commands must not take the keyboard from the terminal (the click still comes)
  const keep0 = (ev) => ev.preventDefault();
  keybar.addEventListener("pointerdown", keep0);
  keybar.addEventListener("mousedown", keep0);
  keybar.addEventListener("click", (ev) => {
    const b = ev.target.closest("button");
    if (!b) return;
    if (b.dataset.mod) {
      if (b.dataset.mod === "ctrl") ctrl = !ctrl; else alt = !alt;
      sendMods();
    } else if (b.dataset.key) {
      post(paneFrame(), { type: "key", key: b.dataset.key });
      ctrl = alt = false; paintMods();
    }
    if (ev.detail > 0) back();   // (a pointer: the terminal has the keyboard again; the keyboard's own Enter stays on its button)
  });
  function setFocus(i) {
    if (i < 0 || i >= panes.length || i === focused) return;
    if (ctrl || alt) { post(paneFrame(), { type: "mods", ctrl: false, alt: false }); ctrl = alt = false; paintMods(); }
    focused = i;
    paintViews();
  }
  window.addEventListener("message", (ev) => {
    const i = panes.findIndex((p) => p.frame.contentWindow === ev.source);
    if (i < 0 || ev.origin !== termOrigin || !ev.data || typeof ev.data !== "object") return;
    if (ev.data.type === "focused") setFocus(i);
    else if (ev.data.type === "mods" && i === focused) { ctrl = ev.data.ctrl === true; alt = ev.data.alt === true; paintMods(); }
  });
  // (a browser that does not say from inside the frame: the portal window loses the focus to the frame)
  window.addEventListener("blur", () => setTimeout(() => setFocus(panes.findIndex((p) => p.frame === document.activeElement)), 0));

  // --- quick commands ---
  const cmdList = h("ul", { class: "tp-cmds", "aria-label": "Quick commands" });
  const cmdNone = h("p", { class: "note tp-none", text: "Save the commands you type often: a click types one into the terminal you last used. Enter is pressed only for the ones marked Run." });
  const cmdAdd = h("button", { type: "button", class: "quiet", id: "tp-cmd-add", text: "Add a command" });
  const cmdMsg = h("p", { class: "tp-form-msg", role: "alert", hidden: true });
  const fName = h("input", { type: "text", id: "tp-cmd-label", maxlength: W.COMMAND_LABEL_MAX, autocomplete: "off", spellcheck: "false" });
  const fText = h("input", { type: "text", id: "tp-cmd-text", maxlength: W.COMMAND_TEXT_MAX, autocomplete: "off", autocapitalize: "off", spellcheck: "false" });
  const fRun = h("input", { type: "checkbox", id: "tp-cmd-run" });
  const form = h("form", { id: "tp-cmd-form", class: "tp-form", hidden: true },
    h("label", { for: "tp-cmd-label", text: "Name" }), fName,
    h("label", { for: "tp-cmd-text", text: "Command" }), fText,
    h("label", { class: "tp-check", for: "tp-cmd-run" }, fRun, " Run it (press Enter after typing it)"),
    cmdMsg,
    h("p", { class: "tp-form-actions" }, h("button", { type: "submit", class: "action primary", text: "Save" }), h("button", { type: "button", class: "quiet", id: "tp-cmd-cancel", text: "Cancel" })));
  let formIndex = null;
  function openForm(index) {
    formIndex = index;
    const c = index == null ? { label: "", text: "", run: false } : commands[index];
    fName.value = c.label; fText.value = c.text; fRun.checked = c.run;
    cmdMsg.hidden = true; form.hidden = false; cmdAdd.hidden = true;
    fName.focus();
  }
  function closeForm(refocus) {
    form.hidden = true; cmdAdd.hidden = false; formIndex = null;
    if (refocus) cmdAdd.focus();
  }
  cmdAdd.addEventListener("click", () => openForm(null));
  $q("#tp-cmd-cancel", form).addEventListener("click", () => closeForm(true));
  form.addEventListener("keydown", (ev) => { if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); closeForm(true); } });
  form.addEventListener("submit", (ev) => {
    ev.preventDefault();
    const r = W.saveCommand(commands, { label: fName.value, text: fText.value, run: fRun.checked }, formIndex);
    if (!r.changed) { cmdMsg.textContent = r.message; cmdMsg.hidden = false; (fName.value.trim() ? fText : fName).focus(); return; }
    commands = r.list; keepCommands(commands); paintCommands(); closeForm(true); say(r.message);
  });
  function $q(s, r = document) { return r.querySelector(s); }
  function paintCommands() {
    cmdList.replaceChildren(...commands.map((c, i) => h("li", { class: "tp-cmd-row", "data-index": String(i) },
      h("button", { type: "button", class: "wg-btn tp-cmd", "data-index": String(i), title: c.text,
        "aria-label": `${c.label}: types ${c.text}${c.run ? " and presses Enter" : ", without Enter"}` }, c.label, c.run ? h("span", { class: "tp-run", "aria-hidden": "true", text: " ⏎" }) : ""),
      h("button", { type: "button", class: "quiet tp-edit", "data-index": String(i), "aria-label": `Edit ${c.label}`, text: "Edit" }),
      h("button", { type: "button", class: "quiet tp-remove", "data-index": String(i), "aria-label": `Remove ${c.label}`, text: "Remove" }))));
    cmdNone.hidden = commands.length > 0;
    cmdList.hidden = commands.length === 0;
    cmdAdd.disabled = commands.length >= W.COMMANDS_MAX && form.hidden;
  }
  cmdList.addEventListener("pointerdown", (ev) => { if (ev.target.closest(".tp-cmd")) ev.preventDefault(); });
  cmdList.addEventListener("mousedown", (ev) => { if (ev.target.closest(".tp-cmd")) ev.preventDefault(); });
  cmdList.addEventListener("click", (ev) => {
    const b = ev.target.closest("button");
    if (!b) return;
    const i = Number(b.dataset.index), c = commands[i];
    if (!c) return;
    if (b.classList.contains("tp-cmd")) { post(paneFrame(), { type: "text", text: c.text, run: c.run === true }); if (ev.detail > 0) back(); }
    else if (b.classList.contains("tp-edit")) openForm(i);
    else if (b.classList.contains("tp-remove")) {
      const r = W.removeCommand(commands, i);
      commands = r.list; keepCommands(commands); paintCommands(); say(r.message);
      (cmdList.querySelector(".tp-cmd") || cmdAdd).focus();
    }
  });

  // --- projects: the folders the pickers know ---
  const projList = h("ul", { class: "tp-projects", "aria-label": "Project folders" });
  const projNone = h("p", { class: "note tp-none", text: "Loading the project folders…" });
  let folders = null;
  async function loadFolders() {
    try {
      const d = await window.bnAnswers.load(false);
      folders = d && Array.isArray(d.folders) ? [{ path: "/workspace", name: "the workspace" }, ...d.folders.filter((f) => f && typeof f.path === "string")] : [];
    } catch (_) { folders = []; }
    paintProjects();
  }
  function paintProjects() {
    if (!folders) return;
    projNone.hidden = folders.length > 1;
    projNone.textContent = "No project folders yet: the Code page's projects and your computer's project folders show here.";
    projList.replaceChildren(...folders.map((f) => h("li", { class: "tp-proj", "data-path": f.path },
      h("span", { class: "tp-proj-name" }, h("strong", { text: f.name || f.path }), h("small", { text: f.path })),
      h("button", { type: "button", class: "quiet tp-open-shell", "data-path": f.path, "aria-label": `Open a shell in ${f.name || f.path}`, text: "Open a shell here" }))));
  }
  projList.addEventListener("click", (ev) => {
    const b = ev.target.closest(".tp-open-shell");
    if (!b) return;
    b.disabled = true;
    window.bnAnswers.launch("open", "shell", b.dataset.path === "/workspace" ? "" : b.dataset.path).then((url) => {
      const first = panes.find((p) => p.n === 1) || panes[0];
      if (first) { first.frame.src = url; setFocus(panes.indexOf(first)); first.frame.focus(); }
      say(`A shell opened in ${b.dataset.path}`);
    }, (e) => { if (e.message !== "signed out") toast(`Could not open it: ${e.message}`); }).finally(() => { b.disabled = false; });
  });

  // --- the widgets, in layout order, with their edit bars ---
  const bodies = {
    terminals: () => [termTools, viewsBox],
    keys: () => [keybar],
    commands: () => [cmdList, cmdNone, cmdAdd, form],
    projects: () => [projNone, projList],
  };
  const els = {};
  const label = (id) => W.titleOf(PAGE, id);
  function widgetEl(id) {
    if (els[id]) return els[id];
    const t = label(id);
    const bar = h("div", { class: "tp-wbar", role: "group", "aria-label": `${t} widget` },
      h("span", { class: "wg-name", text: t }), h("span", { class: "wg-size tp-size", "aria-hidden": "true" }),
      h("button", { type: "button", class: "wg-btn tp-wide", "data-act": "narrow", "aria-label": `Make ${t} narrower`, title: "Narrower" }, icon(NARROW)),
      h("button", { type: "button", class: "wg-btn tp-wide", "data-act": "wide", "aria-label": `Make ${t} wider`, title: "Wider" }, icon(WIDE)),
      h("span", { class: "wg-heights", role: "group", "aria-label": `${t} height` },
        ...W.HEIGHTS.map((k) => h("button", { type: "button", class: "wg-btn wg-h", "data-act": "height", "data-height": k, "aria-pressed": "false", "aria-label": `${t} height: ${HEIGHT_WORD[k]}`,
          title: k === "auto" ? "As tall as its content" : "A set height; more scrolls inside" }, HEIGHT_SHORT[k]))),
      h("button", { type: "button", class: "wg-btn", "data-act": "up", "aria-label": `Move ${t} up`, title: "Move up" }, icon(UP)),
      h("button", { type: "button", class: "wg-btn", "data-act": "down", "aria-label": `Move ${t} down`, title: "Move down" }, icon(DOWN)),
      id === "terminals" ? "" : h("button", { type: "button", class: "wg-btn", "data-act": "hide", "aria-label": `Hide ${t}`, title: "Hide (it comes back from the tray)" }, icon(EYE_OFF)));
    const head = id === "terminals" ? null : h("h2", { class: "tp-title", id: `tp-title-${id}`, text: t });
    const w = h("section", { class: "tp-widget", "data-widget": id, "aria-label": id === "terminals" ? "Terminals" : null, "aria-labelledby": head ? head.id : null },
      bar, ...(head ? [head] : []), ...bodies[id]());
    w.addEventListener("click", (ev) => {
      const b = ev.target.closest("[data-act]");
      if (!b || !bar.contains(b)) return;
      const act = b.dataset.act;
      let r;
      if (act === "up" || act === "down") r = W.moveBy(PAGE, screen.widgets, id, act === "up" ? -1 : 1);
      else if (act === "narrow" || act === "wide") r = W.resizeBy(PAGE, device, screen.widgets, id, act === "wide" ? 1 : -1);
      else if (act === "height") r = W.setHeight(PAGE, screen.widgets, id, b.dataset.height);
      else if (act === "hide") r = W.hide(PAGE, screen.widgets, id);
      if (!r) return;
      change({ screen: { ...screen, widgets: r.list }, message: r.message, changed: r.changed });
      const again = els[id] && els[id].querySelector(`[data-act="${act}"]${b.dataset.height ? `[data-height="${b.dataset.height}"]` : ""}`);
      if (again && !els[id].hidden) again.focus({ preventScroll: true });
      else if (act === "hide") { const add = tray.querySelector(`[data-id="${id}"]`); if (add) add.focus(); }
    });
    els[id] = w;
    return w;
  }

  // a change from the model: kept, drawn, said
  function change(r) {
    if (!r) return;
    if (r.message) say(r.message);
    if (!r.changed) return;
    screen = r.screen;
    keep(device, screen);
    apply();
  }

  // --- the grid and the tray ---
  function paintGrid() {
    const phone = device === "phone";
    grid.classList.toggle("tp-phone", phone);
    grid.classList.toggle("tp-tablet", device === "tablet");
    const nodes = [];
    for (const e of screen.widgets) {
      const w = widgetEl(e.id);
      w.hidden = e.hidden;
      w.style.gridColumn = phone ? "" : `span ${e.span}`;
      const px = e.id === "terminals" ? W.TERMINAL_PX[e.height] : 0;
      viewsBox.style.height = e.id === "terminals" ? (px ? `${px}px` : "") : viewsBox.style.height;
      w.style.maxHeight = e.id !== "terminals" && e.height !== "auto" ? `${W.HEIGHT_REM[e.height]}rem` : "";
      w.style.overflowY = e.id !== "terminals" && e.height !== "auto" ? "auto" : "";
      w.dataset.height = e.height;
      const size = w.querySelector(".tp-size");
      if (size) size.textContent = `${e.span} / ${W.COLS[device]}`;
      for (const b of w.querySelectorAll(".wg-h")) b.setAttribute("aria-pressed", String(b.dataset.height === e.height));
      const bar = w.querySelector(".tp-wbar");
      if (bar) bar.hidden = !editing;
      nodes.push(w);
    }
    grid.replaceChildren(...nodes);
  }
  function paintTray() {
    tray.hidden = !editing;
    if (!editing) return;
    const hidden = screen.widgets.filter((e) => e.hidden);
    const ul = $q("#term-hidden");
    ul.replaceChildren(...hidden.map((e) => h("li", { "data-for": e.id }, h("span", { class: "wg-hidden-name", text: label(e.id) }),
      h("button", { type: "button", class: "quiet", "data-act": "add", "data-id": e.id, "aria-label": `Add back ${label(e.id)}` }, "Add back"))));
    $q("#term-none").hidden = hidden.length > 0;
    ul.hidden = hidden.length === 0;
  }
  function buildTray() {
    tray.append(
      h("div", { class: "wg-tray-head" },
        h("h2", { id: "term-tray-title", tabindex: "-1", text: "Customize the Terminal" }),
        h("p", { class: "wg-tray-actions" }, h("button", { type: "button", class: "quiet", id: "term-reset", text: "Reset to default" }), h("button", { type: "button", class: "action primary", id: "term-done", text: "Done" }))),
      h("p", { class: "note", id: "term-help", text: "Each widget has a bar: move it up or down, make it narrower or wider, pick a height, or hide it. Add a terminal beside this one, and drag the divider between two terminals (or focus it and use the arrow keys) to size them. The key bar goes to the terminal you last used. Escape or Done leaves this. The terminals always show." }),
      h("h3", { class: "wg-tray-sub", id: "term-hidden-title", text: "Hidden widgets" }),
      h("ul", { id: "term-hidden", class: "wg-hidden", "aria-labelledby": "term-hidden-title" }),
      h("p", { class: "note", id: "term-none", text: "Nothing is hidden." }),
      h("p", { class: "wg-status", id: "term-status" }),
      h("p", { class: "note wg-saved", id: "term-saved" }));
    $q("#term-done").addEventListener("click", () => edit(false));
    $q("#term-reset").addEventListener("click", () => {
      screen = W.screenDefaults(device); keep(device, screen); say("The Terminal page is back to its default layout"); apply();
    });
    $q("#term-hidden").addEventListener("click", (ev) => {
      const b = ev.target.closest("[data-act=add]");
      if (!b) return;
      const id = b.dataset.id, r = W.show(PAGE, screen.widgets, id);
      change({ screen: { ...screen, widgets: r.list }, message: r.message, changed: r.changed });
      requestAnimationFrame(() => { const w = els[id], g = w && w.querySelector(".tp-wbar [data-act]"); if (g) g.focus({ preventScroll: true }); });
    });
  }
  addBtn.addEventListener("click", async () => {
    const r = W.addView(device, screen);
    if (!r.changed) { say(r.message); return; }
    screen = r.screen; keep(device, screen);
    syncPanes(); focused = panes.length - 1; apply(); say(r.message);
    if (!editing) back();
  });
  splitBox.addEventListener("click", (ev) => {
    const b = ev.target.closest("[data-split]");
    if (b) change(W.setSplit(screen, b.dataset.split));
  });
  splitBox.addEventListener("keydown", (ev) => {
    if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(ev.key)) return;
    const bs = [...splitBox.children], i = bs.indexOf(document.activeElement);
    if (i < 0) return;
    ev.preventDefault();
    const n = bs[(i + (ev.key === "ArrowLeft" || ev.key === "ArrowUp" ? bs.length - 1 : 1)) % bs.length];
    n.click();
    const now = [...splitBox.children].find((b) => b.dataset.split === n.dataset.split);
    if (now) now.focus();
  });
  function closeAt(i) {
    if (i < 0) return;
    const r = W.closeView(device, screen, i);
    if (!r.changed) { say(r.message); return; }
    detach(panes.splice(i, 1)[0]);
    screen = r.screen; keep(device, screen);
    if (focused >= i && focused > 0) focused -= 1;
    apply(); say(r.message);
    back();
  }

  // --- where the frames go ---
  let placeQ = false;
  const later = () => { if (placeQ) return; placeQ = true; requestAnimationFrame(() => { placeQ = false; place(); }); };
  function place() {
    if (!current || !on) return;
    const box = stage.getBoundingClientRect();
    for (const p of panes) {
      const r = p.slot.getBoundingClientRect(), f = p.frame, s = f.style;
      s.top = `${Math.round(r.top - box.top)}px`; s.left = `${Math.round(r.left - box.left)}px`;
      s.width = `${Math.round(r.width)}px`; s.height = `${Math.round(r.height)}px`; s.right = "auto"; s.bottom = "auto";
      f.hidden = r.width < 2 || r.height < 2;
    }
  }
  function free() {
    for (const f of frames.querySelectorAll('iframe[data-app^="terminal"]')) {
      for (const k of ["top", "left", "width", "height", "right", "bottom"]) f.style[k] = "";
      if (!f.getAttribute("style")) f.removeAttribute("style");
    }
  }
  const ro = typeof ResizeObserver === "function" ? new ResizeObserver(later) : null;

  // --- on and off ---
  let on = false;     // the page is what shows (else the tab is the one frame, as it always was)
  function apply() {
    const want = engaged();
    if (want) {
      syncPanes();
      paintGrid(); paintViews(); paintCommands(); paintTray(); paintProjects(); paintMods();
    }
    if (want !== on) {
      on = want;
      page.hidden = !(on && current);
      if (!on) {
        // back to the plain tab: view 1's frame alone (not reloaded), the other views detached (their sessions stay)
        free();
        while (panes.length) { const p = panes.pop(); p.el.remove(); if (p.n !== 1) p.frame.remove(); }
        const main = appFrame("terminal");
        if (main.src === "about:blank" || !main.src) main.src = appUrl("terminal");
        main.hidden = !current;
      } else if (ro) {
        // (the frames follow their slots: what is above the views — the tray, a widget whose list loaded — moves them
        // without resizing them, so the tray and every widget are watched as well as the page and the views)
        ro.disconnect();
        for (const el of [page, viewsBox, tray, grid, ...grid.children]) ro.observe(el);
      }
    }
    page.hidden = !(on && current);
    page.classList.toggle("tp-editing", editing);
    page.classList.toggle("tp-on", on);
    openBtn.setAttribute("aria-expanded", String(editing));
    if (on && current) later();
  }
  function edit(next) {
    if (next === editing) return;
    editing = next;
    apply();
    if (editing) { $q("#term-tray-title").focus(); say("Customizing the Terminal. Each widget has a bar of buttons: move, narrower, wider, height, hide."); }
    else { say("Done customizing the Terminal"); openBtn.focus({ preventScroll: true }); }
  }
  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "Escape" || !editing || !current || ev.defaultPrevented || document.querySelector("dialog[open]") || !form.hidden) return;
    edit(false);
  });

  // Customize, in Who answers' bar, beside the Terminal's Open
  const openBtn = h("button", { type: "button", class: "quiet", id: "term-customize", "aria-controls": "term-tray", "aria-expanded": "false", text: "Customize" });
  openBtn.addEventListener("click", () => edit(!editing));
  function placeButton() {
    const group = document.getElementById("answers-terminal");
    const wrap = group && group.closest(".answers-group");
    if (wrap && !openBtn.isConnected) wrap.append(openBtn);
  }

  // the tab shown or left
  function onTab(tab) {
    current = tab === "terminal";
    placeButton();
    if (!current) { if (editing) { editing = false; } page.hidden = true; return; }
    if (!built) { built = true; buildTray(); loadFolders(); }
    if (engaged()) { appFrame("terminal"); }
    apply();
    if (on) { for (const p of panes) p.frame.hidden = false; place(); setTimeout(back, 0); }
  }
  document.addEventListener("bn:tab", (e) => onTab(e.detail));
  window.addEventListener("resize", later);
  page.addEventListener("scroll", later, { passive: true });

  // a kind of screen changes (a window resized across a breakpoint, a tablet turned)
  function screenChanged() {
    const d = readDevice();
    if (d === device) return;
    device = d;
    screen = W.normalizeScreen(device, W.screenEntry(doc, PAGE, device));
    if (current) apply();
  }
  PHONE.addEventListener("change", screenChanged); TABLET.addEventListener("change", screenChanged);

  // the server's copy wins over the cache (another browser may have changed it); read once
  (async () => {
    try {
      const r = await fetch("/api/ui/layout", { credentials: "same-origin", cache: "no-store", headers: { "X-Requested-With": "devos-ade" } });
      if (!r.ok) return;
      const d = W.parseDoc(await r.json());
      if (unsaved() || editing) return;
      const s = W.normalizeScreen(device, W.screenEntry(d, PAGE, device)), c = W.commandsEntry(d);
      doc = d; cacheDoc();
      if (same(s, screen) && same(c, commands)) return;
      screen = s; commands = c;
      if (current) apply();
    } catch (_) { /* the cache stands */ }
  })();

  // what the page holds, for the browser suite (tests/e2e/browser/checks_terminal.py) to read
  window.bnTermPage = { screen: () => screen, commands: () => commands, views: () => panes.map((p) => p.n), focused: () => (panes[focused] ? panes[focused].n : 0), on: () => on };

  // the tab may already be showing (this script runs after app.js showed it)
  if (location.hash.replace(/^#/, "").split("/")[0] === "terminal") onTab("terminal");
  placeButton();
  document.addEventListener("DOMContentLoaded", placeButton);
})();
