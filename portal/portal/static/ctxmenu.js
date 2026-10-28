// Item menus (JON-821): the one menu every list item of the portal uses — a Home row, a model, a setting, an Activity item,
// a search result, a sidebar tab. The same actions open three ways: a right-click, the item's ⋯ button (shown on hover and
// focus, always on touch), and a long press on a touch screen; the keyboard opens it too (Shift+F10 or the context-menu key
// on the focused item), moves with the arrows, runs with Enter or Space and closes with Escape, with the focus back on the
// item. Text fields, the terminal and the editor keep the browser's own menu, and so does a link that is not the item.
// Loaded after app.js (el, $, copy, toast) and before the pages that bind menus. Nothing from an API is parsed as HTML:
// every label is set as text; positions go through the CSSOM (the page's CSP has no inline styles).
//
//   bnMenu.bind(root, itemSelector, (item) => actions, { label: (item) => "name", links: false, more: true })
//     root: an element or a selector, listened on once (delegated: redrawn lists need nothing again)
//     actions: [{ id, label, danger, disabled, reason (why it is off: shown under the label), href (opens in a new tab),
//                 hidden, sep (a divider before it), run }] — hidden ones are left out; none left: no menu
//     links: true keeps the menu on a link inside the item (Home's rows are links); false leaves other links alone
//     more: false leaves out the ⋯ button (the phone's tab bar has no room for one)
//   bnMenu.confirm({ title, lines, ok, danger }) -> Promise<boolean>      a dialog that says exactly what happens
//   bnMenu.ask({ title, label, value, ok, max }) -> Promise<string|null>   a one-line text, for Rename
"use strict";

(() => {
  const LONG_MS = 480, SLOP = 10;
  const NS = "http://www.w3.org/2000/svg";
  const OWN = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], .xterm, .cm-editor';
  const DOTS = "M5 10h.01M10 10h.01M15 10h.01";
  let menu = null, back = null, held = 0;

  const dots = () => {
    const s = document.createElementNS(NS, "svg"), p = document.createElementNS(NS, "path");
    s.setAttribute("viewBox", "0 0 20 20"); s.setAttribute("aria-hidden", "true"); p.setAttribute("d", DOTS); s.append(p);
    return s;
  };
  const focusable = (item) => {
    if (item.tabIndex >= 0) return item;
    return item.querySelector('a[href], button:not(.ctx-more):not(:disabled), [tabindex="0"], input:not([type=hidden])') || item.querySelector(".ctx-more") || item;
  };

  // --- the menu itself ---
  function close(refocus = true) {
    if (!menu) return;
    const m = menu, f = back;
    menu = null; back = null;
    m.remove();
    for (const b of document.querySelectorAll(".ctx-more[aria-expanded=true]")) b.setAttribute("aria-expanded", "false");
    document.removeEventListener("pointerdown", onOutside, true);
    document.removeEventListener("scroll", onScroll, true);
    window.removeEventListener("resize", onResize);
    document.removeEventListener("bn:tab", onResize);
    if (refocus && f && f.isConnected) f.focus({ preventScroll: true });
  }
  const onOutside = (e) => { if (menu && !menu.contains(e.target)) close(false); };
  const onScroll = (e) => { if (menu && !(e.target instanceof Node && menu.contains(e.target))) close(false); };
  const onResize = () => close(false);

  function place(x, y) {
    const vw = document.documentElement.clientWidth, vh = window.innerHeight;
    const w = Math.min(menu.offsetWidth, vw - 16), h = Math.min(menu.offsetHeight, vh - 16);
    menu.style.maxHeight = `${vh - 16}px`;
    menu.style.left = `${Math.max(8, Math.min(x, vw - w - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(y, vh - h - 8))}px`;
  }

  function onKey(e) {
    const items = [...menu.querySelectorAll('[role="menuitem"]')];
    const i = items.indexOf(document.activeElement);
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length].focus(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
    else if (e.key === "Home") { e.preventDefault(); items[0].focus(); }
    else if (e.key === "End") { e.preventDefault(); items[items.length - 1].focus(); }
    else if (e.key === "Tab") close();
    else if ((e.key === "Enter" || e.key === " ") && i >= 0) { e.preventDefault(); items[i].click(); }
  }

  // open(x, y, actions, from, name): the menu at a point (kept inside the window), the first item focused; FROM is the
  // control the focus goes back to
  function open(x, y, actions, from, name) {
    close(false);
    const list = actions.filter((a) => a && !a.hidden);
    if (!list.length) return null;
    const m = el("div", { class: "ctx-menu", role: "menu", "aria-label": name ? `Actions for ${name}` : "Actions", tabindex: "-1" });
    for (const a of list) {
      if (a.sep) m.append(el("div", { class: "ctx-sep", role: "separator" }));
      const b = el("button", { type: "button", class: `ctx-item${a.danger ? " danger" : ""}${a.disabled ? " is-disabled" : ""}`, role: "menuitem", "data-act": a.id || "" });
      b.append(el("span", { class: "ctx-label", text: a.label }));
      if (a.disabled) {
        b.setAttribute("aria-disabled", "true");
        if (a.reason) b.append(el("span", { class: "ctx-why", text: a.reason }));
      }
      b.addEventListener("click", (e) => {
        e.stopPropagation();
        if (a.disabled) return;
        close();
        if (a.href) window.open(a.href, "_blank", "noopener,noreferrer");
        else if (a.run) Promise.resolve().then(a.run).catch((err) => toast(`${a.label}: ${err && err.message ? err.message : "did not work"}`));
      });
      m.append(b);
    }
    // (inside an open dialog when there is one: the search box is modal, anything outside it is inert)
    (document.querySelector("dialog[open]") || document.body).append(m);
    menu = m; back = from || null;
    place(x, y);
    m.addEventListener("keydown", onKey);
    m.addEventListener("contextmenu", (e) => e.preventDefault());
    document.addEventListener("pointerdown", onOutside, true);
    document.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onResize);
    document.addEventListener("bn:tab", onResize);
    (m.querySelector('[role="menuitem"]:not([aria-disabled])') || m.querySelector('[role="menuitem"]')).focus({ preventScroll: true });
    return m;
  }

  // --- binding to a list ---
  function bind(rootArg, itemSel, getActions, opts = {}) {
    const root = typeof rootArg === "string" ? document.querySelector(rootArg) : rootArg;
    if (!root) return;
    const nameOf = (item) => (opts.label ? opts.label(item) : "") || "";
    const itemOf = (t) => {
      if (!(t instanceof Element)) return null;
      const item = t.closest(itemSel);
      if (!item || !root.contains(item)) return null;
      if (t.closest(OWN)) return null;
      const link = t.closest("a[href]");
      if (link && link !== item && !opts.links && item.contains(link)) return null;   // a link inside it: the browser's own menu
      return item;
    };
    const show = (item, x, y, from) => {
      let acts;
      try { acts = getActions(item); } catch (_) { acts = []; }
      return open(x, y, acts || [], from || focusable(item), nameOf(item));
    };
    root.addEventListener("contextmenu", (e) => {
      const item = itemOf(e.target);
      if (!item || e.defaultPrevented) return;
      if (e.clientX === 0 && e.clientY === 0 && e.detail === 0) return;   // (a keyboard's: its keydown places the menu)
      e.preventDefault(); e.stopPropagation();
      show(item, e.clientX, e.clientY, focusable(item));
    });
    root.addEventListener("keydown", (e) => {
      if (!(e.key === "ContextMenu" || (e.key === "F10" && e.shiftKey))) return;
      const item = itemOf(e.target);
      if (!item) return;
      e.preventDefault(); e.stopPropagation();
      const f = document.activeElement instanceof HTMLElement && item.contains(document.activeElement) ? document.activeElement : item;
      const r = f.getBoundingClientRect();
      show(item, Math.min(r.left + 24, r.right - 4), r.top + Math.min(r.height, 28), f);
    });
    // a long press (touch and pen; a mouse has the right button)
    let timer = null, start = null, pressed = null;
    const stop = () => { clearTimeout(timer); timer = null; };
    root.addEventListener("pointerdown", (e) => {
      if (e.pointerType === "mouse" || e.button !== 0) return;
      const item = itemOf(e.target);
      if (!item || e.target.closest(".ctx-more")) return;
      stop(); start = { x: e.clientX, y: e.clientY }; pressed = item;
      timer = setTimeout(() => { timer = null; held = Date.now(); show(pressed, start.x, start.y); }, LONG_MS);
    });
    root.addEventListener("pointermove", (e) => { if (timer && Math.hypot(e.clientX - start.x, e.clientY - start.y) > SLOP) stop(); });
    root.addEventListener("pointerup", stop);
    root.addEventListener("pointercancel", stop);
    // the lift of a long press is not a tap on the item (nor on a link in it)
    root.addEventListener("click", (e) => { if (Date.now() - held < 700 && itemOf(e.target)) { e.preventDefault(); e.stopPropagation(); } }, true);
    if (opts.more === false) return;
    // the ⋯ button in each item, put there as items come and go
    const mark = () => {
      for (const item of root.querySelectorAll(itemSel)) {
        if (item.querySelector(":scope > .ctx-more")) continue;
        item.classList.add("has-ctx");
        const b = el("button", { type: "button", class: "ctx-more", "aria-haspopup": "menu", "aria-expanded": "false", "aria-label": `Actions${nameOf(item) ? ` for ${nameOf(item)}` : ""}`, title: "Actions (or right-click)" });
        b.append(dots());
        b.addEventListener("click", (e) => {
          e.preventDefault(); e.stopPropagation();
          if (menu && b.getAttribute("aria-expanded") === "true") { close(); return; }
          const r = b.getBoundingClientRect();
          if (show(item, r.right - 8, r.bottom + 4, b)) b.setAttribute("aria-expanded", "true");
        });
        // (not a tap on the item behind it)
        b.addEventListener("pointerdown", (e) => e.stopPropagation());
        item.append(b);
      }
    };
    let queued = false;
    new MutationObserver(() => { if (!queued) { queued = true; queueMicrotask(() => { queued = false; mark(); }); } }).observe(root, { childList: true, subtree: true });
    mark();
  }

  // --- the two small dialogs: say exactly what happens, ask for a name ---
  function dialogShell(title) {
    const d = el("dialog", { class: "ctx-dlg", "aria-labelledby": "ctx-dlg-title" });
    const f = el("form", { method: "dialog" });
    f.append(el("h2", { id: "ctx-dlg-title", text: title }));
    d.append(f);
    document.body.append(d);
    return { d, f };
  }
  function confirmDialog({ title, lines = [], ok = "OK", danger = false }) {
    return new Promise((resolve) => {
      const { d, f } = dialogShell(title);
      for (const l of lines) f.append(el("p", { text: l }));
      const cancel = el("button", { type: "button", class: "quiet", text: "Cancel" });
      const go = el("button", { type: "submit", class: `action ${danger ? "danger" : "primary"}`, "data-act": "confirm", text: ok });
      f.append(el("p", { class: "ctx-dlg-buttons" }, cancel, go));
      let done = false;
      const end = (v) => { if (done) return; done = true; d.close(); d.remove(); resolve(v); };
      cancel.addEventListener("click", () => end(false));
      f.addEventListener("submit", (e) => { e.preventDefault(); end(true); });
      d.addEventListener("cancel", (e) => { e.preventDefault(); end(false); });
      d.showModal();
      cancel.focus();   // (Delete is never the default: Enter on the dialog cancels)
    });
  }
  function askDialog({ title, label = "Name", value = "", ok = "Save", max = 200 }) {
    return new Promise((resolve) => {
      const { d, f } = dialogShell(title);
      const input = el("input", { type: "text", maxlength: String(max), autocomplete: "off", spellcheck: "false", "aria-label": label });
      input.value = value;
      f.append(el("label", { class: "ctx-ask" }, el("span", { text: label }), input));
      const cancel = el("button", { type: "button", class: "quiet", text: "Cancel" });
      const go = el("button", { type: "submit", class: "action primary", "data-act": "ask-ok", text: ok });
      f.append(el("p", { class: "ctx-dlg-buttons" }, cancel, go));
      let done = false;
      const end = (v) => { if (done) return; done = true; d.close(); d.remove(); resolve(v); };
      cancel.addEventListener("click", () => end(null));
      f.addEventListener("submit", (e) => { e.preventDefault(); const t = input.value.trim(); if (t && !/[\u0000-\u001f\u007f]/.test(t)) end(t); });
      d.addEventListener("cancel", (e) => { e.preventDefault(); end(null); });
      d.showModal();
      input.select();
    });
  }

  window.bnMenu = { bind, open, close, confirm: confirmDialog, ask: askDialog, current: () => menu };
})();
