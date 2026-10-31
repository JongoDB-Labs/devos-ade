// The optional browser terminal (./stack terminal): the Terminal tab — in the sidebar on a big screen, full screen
// from More on a phone — and the second line of Home's Claude Code card. Loaded last (deferred, after app.js and
// mobile.js; shares their $, el, appUrl and APP_URLS) and adds its elements before DOMContentLoaded, so app.js binds
// the tab like the others. The tab frames terminal.<host> like any app: while the terminal is locked, that host
// itself answers with the "Unlock the terminal" form (the portal password again), in the tab and full screen alike.
"use strict";

(() => {
  const state = (() => {
    try { return JSON.parse(document.querySelector('meta[name="bn-terminal"]').content) || {}; } catch (_) { return {}; }
  })();
  const here = Boolean(state.here && APP_URLS.terminal);
  const NS = "http://www.w3.org/2000/svg";
  const icon = (d) => {
    const s = document.createElementNS(NS, "svg"), p = document.createElementNS(NS, "path");
    s.setAttribute("viewBox", "0 0 20 20"); s.setAttribute("aria-hidden", "true"); p.setAttribute("d", d); s.append(p);
    return s;
  };
  const PROMPT = "M3.5 5.5h13a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-13a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1zM6 8.5l2.5 2-2.5 2M10.5 13h3.5";
  const POPOUT = "M11 4h5v5M16 4l-7 7M14 12v4H4V6h4";

  // Sidebar: after the other apps, before Settings and More (the phone's bottom bar hides it; mobile.css), with a
  // pop-out like the other apps.
  function addTab() {
    const settings = $(".tabs .tab[data-tab=settings]");
    const before = settings ? settings.closest("li") : $(".tabs .more-item");
    if (!before) return;
    before.before(el("li", { class: "terminal-item" },
      el("button", { type: "button", class: "tab", "data-tab": "terminal" }, icon(PROMPT), "Terminal"),
      el("a", { class: "popout", "data-app": "terminal", href: appUrl("terminal"), target: "_blank", rel: "noopener",
        title: "Open Terminal in its own window", "aria-label": "Open Terminal in its own window" }, icon(POPOUT))));
  }

  // Phone: under More. The Terminal tab here (termpage.js: one terminal and a key bar for Esc, Tab, Ctrl and the arrows); the
  // terminal itself, full screen in a new tab, with the other apps that open that way.
  function addSheetLink() {
    const tools = $("#more-sheet .sheet-tools"), list = $("#more-sheet .sheet-links");
    if (tools) tools.prepend(el("li", {}, el("a", { class: "sheet-link", href: "#terminal", id: "more-terminal" }, "Terminal",
      el("span", { text: "Claude Code with a key bar: Esc, Tab, Ctrl and the arrows. Closing it keeps your session." }))));
    if (list) list.append(el("li", {}, el("a", { class: "sheet-link", "data-app": "terminal", href: appUrl("terminal"), target: "_blank",
      rel: "noopener" }, "Terminal, full screen", el("span", { text: "Without the key bar. An external keyboard helps." }))));
  }

  // Home's "Claude Code in your terminal" card: where else it runs.
  function cardLine() {
    const card = $("section.claude");
    if (!card) return;
    let line;
    if (here) {
      const open = el("button", { type: "button", class: "linkish", text: "Terminal tab" });
      open.addEventListener("click", () => showTab("terminal"));
      line = el("p", { class: "note terminal-line" }, "Or in the browser: the ", open,
        ". It runs in a sandbox that sees only your workspace folder, and asks for the portal password again.");
    } else if (state.enabled) {
      line = el("p", { class: "note terminal-line" }, "Or in the browser: the Terminal tab is off for remote access (",
        el("code", { text: "REMOTE_TERMINAL=true" }), " in ", el("code", { text: ".env" }), " turns it on: ",
        el("a", { href: "#settings/REMOTE_TERMINAL", "data-setup": "terminal-remote-off", text: "Settings › Remote access" }), ").");
    } else {
      line = el("p", { class: "note terminal-line" }, "Or in the browser: ", el("code", { text: "./stack terminal enable" }),
        " adds a Terminal tab (Claude Code in a sandbox; only the folder you choose).");
    }
    card.append(line);
  }

  if (here) { addTab(); addSheetLink(); }
  cardLine();
})();
