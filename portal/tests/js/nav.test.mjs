// static/nav.js's pure parts: the stored choice read back (bn.nav: collapsed, or anything else — expanded), the key
// that switches it (Ctrl+\ or ⌘\, not a held key, not \ alone) and what the button says.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain } from "./load.mjs";

const N = load("nav.js").bnNav._pure;

test("the stored choice: only \"collapsed\" collapses; nothing stored, blocked storage or junk is expanded", () => {
  assert.equal(N.KEY, "bn.nav");
  assert.equal(N.parse("collapsed"), true);
  for (const v of [null, undefined, "", "expanded", "Collapsed", "true", "1", "{\"collapsed\":true}"]) assert.equal(N.parse(v), false, String(v));
});

test("the key: Ctrl+\\ or ⌘\\ (by the key, or the key where \\ is on a US keyboard), never a held key or \\ alone", () => {
  const k = (o) => N.isToggleKey({ key: "\\", code: "Backslash", ctrlKey: false, metaKey: false, repeat: false, ...o });
  assert.equal(k({ ctrlKey: true }), true);
  assert.equal(k({ metaKey: true }), true);
  assert.equal(k({ ctrlKey: true, code: "IntlBackslash" }), true, "a layout's own \\ key");
  assert.equal(k({ ctrlKey: true, key: "#" }), true, "the US \\ key on another layout");
  assert.equal(k({ ctrlKey: true, shiftKey: true, key: "|" }), true, "Shift does not matter");
  assert.equal(k({}), false, "\\ alone types a backslash");
  assert.equal(k({ ctrlKey: true, repeat: true }), false, "held down: one switch");
  assert.equal(k({ ctrlKey: true, key: "b", code: "KeyB" }), false, "Ctrl/⌘+B is the Code page's (its explorer)");
  assert.equal(k({ metaKey: true, key: "k", code: "KeyK" }), false, "Ctrl/⌘+K is Search");
  assert.equal(N.isToggleKey(null), false);
});

test("the button's tooltip says what a click does and the key for it; aria-keyshortcuts in its own spelling", () => {
  assert.deepEqual(plain(N.labels(false, false)), { title: "Collapse the sidebar (Ctrl+\\)", keys: "Control+\\" });
  assert.deepEqual(plain(N.labels(true, false)), { title: "Expand the sidebar (Ctrl+\\)", keys: "Control+\\" });
  assert.deepEqual(plain(N.labels(true, true)), { title: "Expand the sidebar (⌘\\)", keys: "Meta+\\" });
});

// --- the Git tab (JON-979): the nav item git.js adds, after Files, with a pop-out, and a link under More on a phone ---
import { source } from "./load.mjs";

const G = load("git.js").bnGit._pure;

test("the Git item: a tab named Git with a pop-out in its own window, after Files, framing git.<host> like the other apps", () => {
  const js = source("git.js");
  assert.deepEqual(plain(G.NAV), { tab: "git", label: "Git", item: "git-item", title: "Git — your local git server",
    popout: "Open Git in its own window", note: "Your local git server: repositories, branches, pull requests" });
  // sidebar: after the Files item; the pop-out is the app's own address in a new window, opened without the opener
  assert.match(js, /files = \$\("\.tabs \.tab\[data-tab=files\]"\)/);
  assert.match(js, /after\.after\(li\)/);
  assert.match(js, /class: "popout", "data-app": "git", href: appUrl\("git"\), target: "_blank", rel: "noopener"/);
  // the phone's More sheet carries it (the bottom bar has no room): a #git link before Settings
  assert.match(js, /href: "#git", id: "more-git"/);
  assert.match(js, /settings\.closest\("li"\)\.before\(li\)/);
  // while the git server is off here: the tab stays, muted with an "off" pill, and shows a page of the portal's own, no frame
  assert.match(js, /class: `\$\{NAV\.item\} off`/);
  assert.match(js, /PAGES\.push\("git"\)/);
});

test("the Git tab is loaded, shown by the shell, hidden from the phone's bottom bar and its frame is named", () => {
  const html = source("index.html"), app = source("app.js"), css = source("mobile.css");
  assert.match(html, /<script src="\/static\/git\.js" defer><\/script>/);
  assert.ok(html.indexOf("/static/app.js") < html.indexOf("/static/git.js") && html.indexOf("/static/mobile.js") < html.indexOf("/static/git.js"), "after app.js and mobile.js");
  assert.match(app, /\["terminal", "code", "git"\]\.includes\(tab\) && APP_URLS\[tab\]/);
  assert.match(app, /const FRAME_TITLES = \{ git: "Git — your local git server" \}/);
  assert.match(css, /\.tabs \.terminal-item, \.tabs \.git-item \{ display: none; \}/);
});
