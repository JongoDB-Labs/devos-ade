// static/stalebar.js's pure part: when an open page is out of date (JON-1127). The page's build is in its
// <meta name="bn-build">; /api/admin/status answers the running one.
import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { load, source } from "./load.mjs";

const S = load("stalebar.js").bnStale._pure;

test("stale only when the server names a different, non-empty build", () => {
  assert.equal(S.isStale("aaaa", "bbbb"), true);
  assert.equal(S.isStale("aaaa", "aaaa"), false);
  for (const theirs of [undefined, null, "", 0, 5, {}, []]) assert.equal(S.isStale("aaaa", theirs), false);
});

test("a page that has no build of its own (an old server) is never told it is stale", () => {
  assert.equal(S.isStale("", "bbbb"), false);
  assert.equal(S.isStale(undefined, "bbbb"), false);
});

test("app.js still compiles with the build constant (a duplicate global name would stop the whole page)", () => {
  assert.doesNotThrow(() => new vm.Script(source("app.js"), { filename: "app.js" }));
});

// check() against a stub page: the bar once, never twice, nothing without its element, nothing when the builds match
function page({ withBar = true } = {}) {
  const cls = new Set(), props = {}, listeners = {};
  const text = { textContent: "" }, btn = { hidden: true, addEventListener: (t, f) => { listeners[t] = f; } };
  const bar = {
    classList: { add: (c) => cls.add(c) }, getBoundingClientRect: () => ({ height: 41.2 }),
    querySelector: (s) => (s === ".stale-text" ? text : s === "#stale-reload" ? btn : null),
  };
  const sizers = [];
  const win = {};
  const ctx = vm.createContext({
    console, window: win, location: { reloads: 0, reload() { this.reloads++; } },
    ResizeObserver: class { constructor(f) { sizers.push(f); } observe() {} },
    document: {
      getElementById: (id) => (id === "stale-bar" && withBar ? bar : id === "stale-reload" ? btn : null),
      documentElement: { classList: { add: (c) => cls.add(`html:${c}`) }, style: { setProperty: (k, v) => { props[k] = v; } } },
    },
  });
  vm.runInContext(source("stalebar.js"), ctx, { filename: "stalebar.js" });
  return { api: win.bnStale, cls, props, text, btn, sizers, ctx, listeners };
}

test("check(): a different build shows the bar with its words, the Reload button and the page's offset", () => {
  const p = page();
  p.api.check("bbbb", "aaaa");
  assert.equal(p.text.textContent, "DevOS ADE was updated. Reload this page to use the new version.");
  assert.equal(p.btn.hidden, false);
  assert.ok(p.cls.has("on") && p.cls.has("html:stale-open"));
  assert.equal(p.props["--stale-h"], "42px");
  assert.equal(p.sizers.length, 1);
});

test("check(): shown once; the next stale call changes nothing", () => {
  const p = page();
  p.api.check("bbbb", "aaaa");
  p.text.textContent = "kept";
  p.api.check("cccc", "aaaa");
  assert.equal(p.text.textContent, "kept");
  assert.equal(p.sizers.length, 1);
});

test("check(): nothing when the builds match, or there is no #stale-bar", () => {
  const same = page();
  same.api.check("aaaa", "aaaa");
  assert.equal(same.text.textContent, "");
  assert.equal(same.cls.size, 0);
  const none = page({ withBar: false });
  assert.doesNotThrow(() => none.api.check("bbbb", "aaaa"));
  assert.equal(none.cls.size, 0);
});

test("the Reload button reloads the page; _setBuild replaces the page's own build", () => {
  const p = page();
  p.listeners.click();
  assert.equal(p.ctx.location.reloads, 1);
  p.api._setBuild("stale");
  p.api.check("aaaa", "aaaa");
  assert.ok(p.cls.has("on"));
});
