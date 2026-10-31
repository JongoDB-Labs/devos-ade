// The Terminal tab's key bar and quick commands (JON-946), injected into ttyd's page by ttyd-page.py as its third inline
// script (the main Caddy's Content-Security-Policy allows it by its hash: TTYD_KEYS_SCRIPT_SHA256 in the Dockerfile,
// terminal_page in caddy/Caddyfile — the same value). The portal's page frames this one (once for each view) and has
// buttons that a phone's on-screen keyboard lacks (Esc, Tab, Ctrl, the arrows, tmux's Ctrl-b) and a person's saved
// commands; they reach the terminal here, as messages.
// Anything on the web can send a message to a window, so this is the boundary: only a message from the window that frames
// this page (event.source === window.parent) is read, and from its origin where the browser says what that is
// (location.ancestorOrigins; only the portal and the Code page may frame this host: frame-ancestors in the Caddyfile).
// What it may say is small and fixed — never a sequence of its own:
//   {type: "key", key: NAME}       a key from the table below, with the modifiers set at that moment
//   {type: "mods", ctrl, alt}      Ctrl and Alt for the next key: one pressed here (or typed in this terminal) uses them up
//   {type: "text", text, run}      up to 4 KB of printable characters and tabs, pasted as the Paste button does; Enter
//                                  after it only when run is true. No escape, no newline, no other control character.
//   {type: "focus"}                the terminal takes the keyboard back (a button was pressed)
// Anything else is ignored without a word. It says back to the frame only that this terminal has the focus and that Ctrl and Alt
// were used up.
(function () {
  "use strict";
  var MAX_TEXT = 4096;
  var CSI = "\x1b[";
  // key -> [what a bare key sends, the final of its modified form, the number of its modified form ("" for a letter-like one)]
  var KEYS = {
    esc: ["\x1b"], tab: ["\t"],
    up: [CSI + "A", "A", 1], down: [CSI + "B", "B", 1], right: [CSI + "C", "C", 1], left: [CSI + "D", "D", 1],
    home: [CSI + "H", "H", 1], end: [CSI + "F", "F", 1], pgup: [CSI + "5~", "~", 5], pgdn: [CSI + "6~", "~", 6],
    "ctrl-c": ["\x03"], "ctrl-b": ["\x02"]
  };
  var CONTROL = /[\u0000-\u0008\u000A-\u001F\u007F-\u009F\u2028\u2029]/;   // (everything but a tab)
  var ctrl = false, alt = false;

  function parentOrigin() {
    var a = window.location.ancestorOrigins;
    return a && a.length ? a[0] : "";
  }
  function tell(msg) {
    // (a browser without ancestorOrigins says nothing back: the page then finds out by itself)
    var o = parentOrigin();
    if (o && window.parent !== window) window.parent.postMessage(msg, o);
  }
  function used() {
    if (!ctrl && !alt) return;
    ctrl = alt = false;
    tell({ type: "mods", ctrl: false, alt: false });
  }

  // a key by name, with the modifiers held: the sequence xterm itself sends (CSI 1;m A for an arrow with Ctrl, m = 1 + Alt 2 + Ctrl 4)
  function sequence(name) {
    if (!Object.prototype.hasOwnProperty.call(KEYS, name)) return null;
    var k = KEYS[name], m = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    if (m === 1 || !k[1]) return alt && !ctrl && (name === "esc" || name === "tab") ? "\x1b" + k[0] : k[0];
    return CSI + (k[1] === "~" ? k[2] : "1") + ";" + m + k[1];
  }
  // a letter typed in this terminal while Ctrl or Alt is held: Ctrl-a … Ctrl-z, Alt as an escape before it
  function typed(e) {
    if (!(ctrl || alt) || !e.isTrusted || e.isComposing || e.ctrlKey || e.altKey || e.metaKey || typeof e.key !== "string" || !/^[A-Za-z]$/.test(e.key)) return;
    var t = window.term;
    if (!t || !t.input) return;
    var c = ctrl ? String.fromCharCode(e.key.toLowerCase().charCodeAt(0) - 96) : e.key;
    e.preventDefault();
    e.stopImmediatePropagation();
    t.input((alt ? "\x1b" : "") + c);
    used();
  }

  function onMessage(e) {
    if (e.source !== window.parent || window.parent === window) return;
    var o = parentOrigin();
    if (o && e.origin !== o) return;
    var d = e.data, t = window.term;
    if (!d || typeof d !== "object" || !t || !t.input || !t.paste) return;
    if (d.type === "key") {
      var s = typeof d.key === "string" ? sequence(d.key) : null;
      if (s === null) return;
      t.input(s);
      used();
    } else if (d.type === "mods") {
      ctrl = d.ctrl === true;
      alt = d.alt === true;
    } else if (d.type === "text") {
      if (typeof d.text !== "string" || !d.text || d.text.length > MAX_TEXT || CONTROL.test(d.text)) return;
      t.paste(d.text);
      if (d.run === true) t.input("\r");
    } else if (d.type === "focus") {
      if (t.focus) t.focus();
    }
  }

  window.addEventListener("message", onMessage);
  window.addEventListener("focus", function () { tell({ type: "focused" }); });
  document.addEventListener("keydown", typed, true);
})();
