// terminal/ttyd-keys.js, run in a context of its own with a stand-in page: a message from the window that frames the
// page puts a key from the fixed table, or text, into the terminal; anything else — another window, another origin, an
// unknown key, a control character, too much text — is ignored without a word.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const src = readFileSync(fileURLToPath(new URL("../../../terminal/ttyd-keys.js", import.meta.url)), "utf8");
const ORIGIN = "https://devos-ade.example";

function page({ ancestors = [ORIGIN], ready = true } = {}) {
  const sent = [], told = [], listeners = {}, docListeners = {};
  const parent = { postMessage: (m, o) => told.push([JSON.parse(JSON.stringify(m)), o]) };
  const term = { input: (d) => sent.push(["input", d]), paste: (t) => sent.push(["paste", t]), focus: () => sent.push(["focus"]) };
  const window = {
    parent, location: { ancestorOrigins: ancestors },
    addEventListener: (t, f) => { (listeners[t] ||= []).push(f); },
  };
  if (ready) window.term = term;
  const document = { addEventListener: (t, f, capture) => { assert.equal(capture, true); (docListeners[t] ||= []).push(f); } };
  vm.runInContext(src, vm.createContext({ window, document, Object }));
  return {
    sent, told, parent, window,
    say: (data, source = parent, origin = ORIGIN) => listeners.message.forEach((f) => f({ data, source, origin })),
    focus: () => listeners.focus.forEach((f) => f({})),
    keydown: (e) => { const ev = { isTrusted: true, isComposing: false, preventDefault() { ev.stopped = true; }, stopImmediatePropagation() { ev.cut = true; }, ...e }; docListeners.keydown.forEach((f) => f(ev)); return ev; },
  };
}

test("each key of the table sends its own sequence", () => {
  const p = page();
  const want = { esc: "\x1b", tab: "\t", up: "\x1b[A", down: "\x1b[B", right: "\x1b[C", left: "\x1b[D", home: "\x1b[H", end: "\x1b[F",
    pgup: "\x1b[5~", pgdn: "\x1b[6~", "ctrl-c": "\x03", "ctrl-b": "\x02" };
  for (const [key, seq] of Object.entries(want)) p.say({ type: "key", key });
  assert.deepEqual(p.sent, Object.values(want).map((s) => ["input", s]));
});

test("a key that is not in the table, or not a word, is ignored", () => {
  const p = page();
  for (const key of ["enter", "ctrl-d", "\x1b[2J", "constructor", "__proto__", "toString", "hasOwnProperty", "", " up", "UP", 3, null, undefined, ["up"], { toString: () => "up" }])
    p.say({ type: "key", key });
  p.say({ type: "key" });
  assert.deepEqual(p.sent, []);
});

test("a message from another window, another origin, or a page with nothing framing it is ignored", () => {
  const p = page();
  p.say({ type: "key", key: "esc" }, { postMessage() {} });
  p.say({ type: "key", key: "esc" }, null);
  p.say({ type: "text", text: "ls" }, { postMessage() {} });
  p.say({ type: "key", key: "esc" }, p.parent, "https://evil.example");
  p.say({ type: "key", key: "esc" }, p.parent, "null");
  assert.deepEqual(p.sent, []);
  // (the window that frames it, from its own origin: through)
  p.say({ type: "key", key: "esc" });
  assert.deepEqual(p.sent, [["input", "\x1b"]]);
  // (not framed at all: its own window is its parent)
  const q = page();
  q.window.parent = q.window;
  q.say({ type: "key", key: "esc" }, q.window);
  assert.deepEqual(q.sent, []);
});

test("a browser without ancestorOrigins still takes only the framing window's messages", () => {
  const p = page({ ancestors: null });
  p.say({ type: "key", key: "tab" }, { postMessage() {} });
  assert.deepEqual(p.sent, []);
  p.say({ type: "key", key: "tab" }, p.parent, "https://anything.example");
  assert.deepEqual(p.sent, [["input", "\t"]]);
  assert.deepEqual(p.told, []);   // (and says nothing back: it does not know who to tell)
});

test("nothing happens before ttyd has made its terminal, and a message with no object does nothing", () => {
  const p = page({ ready: false });
  p.say({ type: "key", key: "esc" });
  for (const d of [null, undefined, "esc", 7, true, []]) p.say(d);
  assert.deepEqual(p.sent, []);
  const q = page();
  for (const d of [null, undefined, "esc", 7, true, [], {}, { type: "reboot" }, { type: "input", data: "x" }, { type: "key", key: "esc", data: "x" }.type]) q.say(d);
  assert.deepEqual(q.sent, []);
});

test("text is pasted as the Paste button does; Enter follows only when run is true", () => {
  const p = page();
  p.say({ type: "text", text: "git status" });
  p.say({ type: "text", text: "ls -la\tfoo", run: false });
  p.say({ type: "text", text: "npm test", run: true });
  p.say({ type: "text", text: "pwd", run: "true" });
  p.say({ type: "text", text: "date", run: 1 });
  assert.deepEqual(p.sent, [["paste", "git status"], ["paste", "ls -la\tfoo"], ["paste", "npm test"], ["input", "\r"], ["paste", "pwd"], ["paste", "date"]]);
});

test("text with a control character, no text, or too much text is ignored", () => {
  const p = page();
  const bad = ["ls\n", "ls\r", "a\x1b[31m", "\x1b", "x\x00", "a\x03b", "\x7f", "a\u0085b", "a b", "a b", "a\u009bb", "line1\nline2", "", 5, null, ["ls"], { toString: () => "ls" }, "x".repeat(4097)];
  for (const text of bad) p.say({ type: "text", text, run: true });
  assert.deepEqual(p.sent, []);
  p.say({ type: "text", text: "x".repeat(4096) });
  assert.deepEqual(p.sent, [["paste", "x".repeat(4096)]]);
  // (printable means printable: accents, CJK and emoji are text)
  p.say({ type: "text", text: "echo é 日本 😀" });
  assert.equal(p.sent.length, 2);
});

test("focus gives the terminal the keyboard back, and says nothing more", () => {
  const p = page();
  p.say({ type: "focus" });
  assert.deepEqual(p.sent, [["focus"]]);
});

test("Ctrl and Alt are held for the next key only: the modified sequences xterm sends", () => {
  const p = page();
  p.say({ type: "mods", ctrl: true, alt: false });
  p.say({ type: "key", key: "up" });
  p.say({ type: "key", key: "up" });   // (used up)
  p.say({ type: "mods", ctrl: true, alt: true });
  p.say({ type: "key", key: "pgdn" });
  p.say({ type: "mods", ctrl: false, alt: true });
  p.say({ type: "key", key: "left" });
  p.say({ type: "mods", ctrl: false, alt: true });
  p.say({ type: "key", key: "esc" });
  p.say({ type: "mods", ctrl: false, alt: true });
  p.say({ type: "key", key: "tab" });
  p.say({ type: "mods", ctrl: true, alt: false });
  p.say({ type: "key", key: "home" });
  assert.deepEqual(p.sent, [["input", "\x1b[1;5A"], ["input", "\x1b[A"], ["input", "\x1b[6;7~"], ["input", "\x1b[1;3D"],
    ["input", "\x1b\x1b"], ["input", "\x1b\t"], ["input", "\x1b[1;5H"]]);
  // (and the page is told each time that they were used up)
  assert.equal(p.told.length, 6);
  assert.deepEqual(p.told[0], [{ type: "mods", ctrl: false, alt: false }, ORIGIN]);
  // truthy is not true
  const q = page();
  q.say({ type: "mods", ctrl: "yes", alt: 1 });
  q.say({ type: "key", key: "up" });
  assert.deepEqual(q.sent, [["input", "\x1b[A"]]);
});

test("Ctrl held, then a letter typed in the terminal: that Ctrl-letter, once", () => {
  const p = page();
  p.say({ type: "mods", ctrl: true, alt: false });
  const e = p.keydown({ key: "C" });
  assert.deepEqual(p.sent, [["input", "\x03"]]);
  assert.ok(e.stopped && e.cut, "xterm does not also type the letter");
  const again = p.keydown({ key: "c" });
  assert.ok(!again.stopped);
  assert.deepEqual(p.sent, [["input", "\x03"]]);
  p.say({ type: "mods", ctrl: false, alt: true });
  p.keydown({ key: "f" });
  assert.deepEqual(p.sent.at(-1), ["input", "\x1bf"]);
  // not for a script's key event, a composition, a chord, or a key that is not a letter
  p.say({ type: "mods", ctrl: true, alt: false });
  for (const e2 of [{ key: "a", isTrusted: false }, { key: "a", isComposing: true }, { key: "a", ctrlKey: true }, { key: "Enter" }, { key: "1" }, { key: "ab" }, { key: "Unidentified" }]) assert.ok(!p.keydown(e2).stopped);
  assert.equal(p.sent.length, 2);
});

test("it says to the frame that it has the focus, to the frame's origin only", () => {
  const p = page();
  p.focus();
  assert.deepEqual(p.told, [[{ type: "focused" }, ORIGIN]]);
  const q = page({ ancestors: [] });
  q.focus();
  assert.deepEqual(q.told, []);
});

test("it cannot do more than the table: no eval, no network, no markup, no storage", () => {
  for (const bad of ["eval(", "new Function", "fetch(", "XMLHttpRequest", "WebSocket", "innerHTML", "document.write", "localStorage", "cookie", "</script"])
    assert.ok(!src.includes(bad), bad);
  assert.ok(!src.includes("\r"), "no carriage returns: the pinned hash is over the text as served");
});
