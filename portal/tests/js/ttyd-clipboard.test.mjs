// terminal/ttyd-clipboard.js, run in a context of its own with a stand-in page: an OSC 52 write reaches the clipboard
// only just after your own gesture, as plain text, within the size limit; "?" is never answered.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const src = readFileSync(fileURLToPath(new URL("../../../terminal/ttyd-clipboard.js", import.meta.url)), "utf8");

function page() {
  const written = [], listeners = {}, timers = [];
  let now = 1_000_000, handler = null;
  const button = { style: {}, set textContent(v) { this._t = v; }, get textContent() { return this._t; } };
  const term = { parser: { registerOscHandler: (n, f) => { assert.equal(n, 52); handler = f; } }, paste() {}, focus() {} };
  const document = {
    addEventListener: (t, f, capture) => { assert.equal(capture, true); (listeners[t] ||= []).push(f); },
    createElement: () => button, body: { appendChild() {}, removeChild() {} },
  };
  const ctx = vm.createContext({
    document, navigator: { clipboard: { writeText: (t) => { written.push(t); return Promise.resolve(); } } },
    window: { term }, TextDecoder, atob, Uint8Array, Date: { now: () => now },
    setInterval: (f) => { timers.push(f); return 1; }, clearInterval() {}, setTimeout() {},
  });
  vm.runInContext(src, ctx);
  timers[0]();   // ttyd's terminal is there: the handler is registered
  return {
    written, button, listeners, osc: (d) => handler(d),
    gesture: (type, isTrusted = true) => listeners[type].forEach((f) => f({ isTrusted })),
    advance: (ms) => { now += ms; },
  };
}
const b64 = (s) => Buffer.from(s, "utf8").toString("base64");

test("a write with no gesture before it is dropped", () => {
  const p = page();
  assert.equal(p.osc("c;" + b64("rm -rf ~")), true);
  assert.deepEqual(p.written, []);
});

test("a write just after your own mouseup or touchend reaches the clipboard; later, or after a script's event, it does not", () => {
  const p = page();
  for (const type of ["mouseup", "touchend"]) {
    p.gesture(type); p.advance(400);
    p.osc("c;" + b64(type));
  }
  assert.deepEqual(p.written, ["mouseup", "touchend"]);
  p.advance(1600);
  p.osc("c;" + b64("late"));
  p.gesture("mouseup", false);   // dispatched by a script: not a gesture
  p.osc("c;" + b64("untrusted"));
  assert.deepEqual(p.written, ["mouseup", "touchend"]);
});

test("control characters go, tabs and newlines stay, and the button says what was copied", () => {
  const p = page();
  p.gesture("mouseup");
  p.osc("c;" + b64("a\tb\r\nc\x1b[31m\x08\x7f\u0085d\n\r\n"));
  assert.deepEqual(p.written, ["a\tb\r\nc[31md"]);
  assert.equal(p.button.textContent, "Copied 11 characters");
});

test('"?" is never answered, and an empty or malformed write does nothing', () => {
  const p = page();
  p.gesture("mouseup");
  for (const d of ["c;?", "?", "c;", "c;!!notbase64!!"]) assert.equal(p.osc(d), true, d);
  assert.deepEqual(p.written, []);
});

test("a payload over 1 MB of base64 is dropped", () => {
  const p = page();
  p.gesture("mouseup");
  p.osc("c;" + "QUFB".repeat(262145));
  assert.deepEqual(p.written, []);
  p.osc("c;" + b64("ok"));
  assert.deepEqual(p.written, ["ok"]);
});

test("a key alone opens no window", () => {
  const p = page();
  assert.equal(p.listeners.keydown, undefined);
  p.osc("c;" + b64("typed"));
  assert.deepEqual(p.written, []);
});

test("one write per gesture: a second before the next release is dropped", () => {
  const p = page();
  p.gesture("mouseup");
  p.osc("c;" + b64("first"));
  p.osc("c;" + b64("second"));
  assert.deepEqual(p.written, ["first"]);
  p.gesture("touchend");
  p.osc("c;" + b64("third"));
  assert.deepEqual(p.written, ["first", "third"]);
});
