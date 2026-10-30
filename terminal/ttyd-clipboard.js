// The browser terminal's clipboard (JON-546), injected into ttyd's page by ttyd-page.py as its second inline script
// (the main Caddy's Content-Security-Policy allows it by its hash: TTYD_CLIPBOARD_SCRIPT_SHA256 in the Dockerfile,
// terminal_page in caddy/Caddyfile — the same value). ttyd 1.7.7's xterm.js copies what it selects, but with tmux's
// mouse on a plain drag selects in tmux, not in the page, and ttyd has no handler for the escape sequence (OSC 52) by
// which tmux hands a selection to the browser. This is that handler, and a Paste button for places where
// Cmd/Ctrl+V does not reach the terminal (a phone, a browser that keeps the shortcut).
// Anything in the terminal can print an OSC 52, and a program in the sandbox can drive tmux itself, so tmux's own
// setting (set-clipboard external) is not the boundary: this is. A write is honoured only just after your own click,
// touch or key, is cut to plain text, and says that it happened.
(function () {
  "use strict";
  var WINDOW_MS = 1500;      // after a gesture (tmux's double-click select waits 0.3 s before it copies)
  var MAX_BASE64 = 1048576;  // 1 MB of base64
  var last = -Infinity, btn = null, label = "Paste";
  ["mouseup", "touchend", "keydown"].forEach(function (type) {
    document.addEventListener(type, function (e) { if (e.isTrusted) last = Date.now(); }, true);
  });

  function say(t) {
    if (!btn) return;
    btn.textContent = t;
    setTimeout(function () { btn.textContent = label; }, 2500);
  }
  function copy(text) {
    function fallback() {
      // (the way ttyd copies its own selection: a selected textarea and execCommand)
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.style.cssText = "position:fixed;top:0;left:0;opacity:0";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); } catch (_) { /* no permission: nothing more to try */ }
      document.body.removeChild(ta);
      if (window.term) window.term.focus();
    }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).catch(fallback);
    else fallback();
  }

  // OSC 52 ; Pc ; Pd — Pd is the text in base64, or "?" to ask for the clipboard, which is never answered. Always
  // handled (true), so xterm.js does nothing more with it; a write that is not wanted is dropped without a word.
  function osc52(data) {
    var i = data.indexOf(";");
    var b64 = i < 0 ? "" : data.slice(i + 1);
    if (!b64 || b64 === "?" || b64.length > MAX_BASE64) return true;
    if (Date.now() - last > WINDOW_MS) return true;
    try {
      var bin = atob(b64), bytes = new Uint8Array(bin.length);
      for (var k = 0; k < bin.length; k++) bytes[k] = bin.charCodeAt(k);
      // (control characters out, except tab, CR and LF: a pasted escape sequence or backspace could rewrite a command)
      var text = new TextDecoder().decode(bytes).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/g, "");
      if (!text) return true;
      copy(text);
      say("Copied " + text.length + " characters");
    } catch (_) { /* not base64: dropped */ }
    return true;
  }

  function button() {
    var b = document.createElement("button");
    b.type = "button";
    b.textContent = label;
    btn = b;
    b.title = "Paste from the clipboard (Cmd/Ctrl+V does the same)";
    b.style.cssText = "position:fixed;top:4px;right:6px;z-index:10;padding:3px 10px;font:12px ui-monospace,Menlo,monospace;" +
      "color:#f4ecdf;background:#2f4a45;border:1px solid #84c8bf;border-radius:4px;opacity:.55;cursor:pointer";
    b.onfocus = b.onmouseover = function () { b.style.opacity = "1"; };
    b.onblur = b.onmouseout = function () { b.style.opacity = ".55"; };
    // (mousedown would take the terminal's focus before the click; a tap keeps it)
    b.onmousedown = function (e) { e.preventDefault(); };
    b.onclick = function () {
      if (!navigator.clipboard || !navigator.clipboard.readText) return say("No clipboard: Cmd/Ctrl+V");
      navigator.clipboard.readText().then(function (text) {
        if (text) window.term.paste(text);
        window.term.focus();
      }, function () { say("Blocked: Cmd/Ctrl+V"); });
    };
    document.body.appendChild(b);
  }

  // ttyd makes its terminal (window.term) when its page has loaded; this waits for it.
  var tries = 0, timer = setInterval(function () {
    var t = window.term;
    if (t && t.parser && t.paste) {
      clearInterval(timer);
      t.parser.registerOscHandler(52, osc52);
      button();
    } else if (++tries > 300) clearInterval(timer);
  }, 100);
})();
