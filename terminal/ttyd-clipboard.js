// The browser terminal's clipboard (JON-546), injected into ttyd's page by ttyd-page.py as its second inline script
// (the main Caddy's Content-Security-Policy allows it by its hash: TTYD_CLIPBOARD_SCRIPT_SHA256 in the Dockerfile,
// terminal_page in caddy/Caddyfile — the same value). ttyd 1.7.7's xterm.js copies what it selects, but with tmux's
// mouse on a plain drag selects in tmux, not in the page, and ttyd has no handler for the escape sequence (OSC 52) by
// which tmux hands a selection to the browser. This is that handler, and a Paste button for places where
// Cmd/Ctrl+V does not reach the terminal (a phone, a browser that keeps the shortcut).
(function () {
  "use strict";
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

  // OSC 52 ; Pc ; Pd — Pd is the text in base64, or "?" to ask for the clipboard, which is never answered.
  function osc52(data) {
    var i = data.indexOf(";");
    var b64 = i < 0 ? "" : data.slice(i + 1);
    if (!b64 || b64 === "?") return true;
    try {
      var bin = atob(b64), bytes = new Uint8Array(bin.length);
      for (var k = 0; k < bin.length; k++) bytes[k] = bin.charCodeAt(k);
      copy(new TextDecoder().decode(bytes));
    } catch (_) { /* not base64: dropped */ }
    return true;
  }

  function button() {
    var b = document.createElement("button");
    b.type = "button";
    b.textContent = "Paste";
    b.title = "Paste from the clipboard (Cmd/Ctrl+V does the same)";
    b.style.cssText = "position:fixed;top:4px;right:6px;z-index:10;padding:3px 10px;font:12px ui-monospace,Menlo,monospace;" +
      "color:#f4ecdf;background:#2f4a45;border:1px solid #84c8bf;border-radius:4px;opacity:.55;cursor:pointer";
    b.onfocus = b.onmouseover = function () { b.style.opacity = "1"; };
    b.onblur = b.onmouseout = function () { b.style.opacity = ".55"; };
    // (mousedown would take the terminal's focus before the click; a tap keeps it)
    b.onmousedown = function (e) { e.preventDefault(); };
    b.onclick = function () {
      function say(t) { b.textContent = t; setTimeout(function () { b.textContent = "Paste"; }, 2500); }
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
