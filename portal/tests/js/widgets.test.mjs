// static/widgets.js's model: a page's layout as plain data — defaults, what was saved merged in, clamping, move, resize,
// height, hide and show, reset, the phone's rules, and the sentences read out for each change. The page half (edit mode,
// the grid) needs a browser: tests/e2e/browser/checks_widgets.py.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain, source } from "./load.mjs";

const W = load("widgets.js").bnWidgets._pure;
const P = "home";
const ids = (l) => l.map((e) => e.id);
const by = (l, id) => l.find((e) => e.id === id);

test("every kind of screen has a default layout with each widget it shows, once", () => {
  const all = plain(W.HOME.map((w) => w.id));
  const sorted = (l) => [...ids(l)].sort();
  assert.deepEqual(plain(sorted(W.defaults(P, "desktop"))), [...all].sort());
  assert.deepEqual(plain(sorted(W.defaults(P, "tablet"))), [...all].sort());
  assert.deepEqual(plain(sorted(W.defaults(P, "phone"))), all.filter((i) => i !== "claude").sort(), "Claude Code in your terminal stays on the desktop (mobile.css)");
  for (const d of ["desktop", "tablet", "phone"]) for (const e of W.defaults(P, d)) {
    assert.equal(e.hidden, false); assert.equal(e.height, "auto");
    assert.ok(e.span >= W.minSpan(W.HOME.find((w) => w.id === e.id), d) && e.span <= W.COLS[d], `${d} ${e.id} ${e.span}`);
  }
});

test("the default is today's Home: Get started and Continue, the update, then spend beside the short cards", () => {
  assert.deepEqual(plain(ids(W.defaults(P, "desktop")).slice(0, 4)), ["get-started", "continue", "update-card", "spend"]);
  assert.equal(by(W.defaults(P, "desktop"), "update-card").span, 12, "as wide as the page");
  assert.equal(by(W.defaults(P, "tablet"), "update-card").span, 6);
  assert.deepEqual(plain(W.defaults(P, "phone").map((e) => e.span)), Array(9).fill(1), "one column");
  assert.deepEqual(plain(W.COLS), { desktop: 12, tablet: 6, phone: 1 });
});

test("nothing saved is the default, and a layout equal to it counts as the default", () => {
  assert.deepEqual(plain(W.normalize(P, "desktop", null)), plain(W.defaults(P, "desktop")));
  assert.deepEqual(plain(W.normalize(P, "desktop", undefined)), plain(W.defaults(P, "desktop")));
  assert.deepEqual(plain(W.normalize(P, "desktop", "junk")), plain(W.defaults(P, "desktop")));
  assert.equal(W.isDefault(P, "desktop", W.defaults(P, "desktop")), true);
  assert.equal(W.isDefault(P, "desktop", W.hide(P, W.defaults(P, "desktop"), "spend").list), false);
});

test("merge: unknown and repeated widgets are dropped, missing ones appended with their default, the saved order kept", () => {
  const saved = [{ id: "models", span: 6, height: "m", hidden: false }, { id: "from-a-later-release", span: 3 }, { id: "spend", span: 5, height: "auto", hidden: true },
    { id: "models", span: 12 }, null, 7, "x", { span: 4 }];
  const out = plain(W.normalize(P, "desktop", saved));
  assert.deepEqual(out.slice(0, 2), [{ id: "models", span: 6, height: "m", hidden: false }, { id: "spend", span: 5, height: "auto", hidden: true }]);
  assert.equal(out.length, W.HOME.length, "every widget once");
  assert.deepEqual(out.slice(2).map((e) => e.id), plain(ids(W.defaults(P, "desktop"))).filter((i) => i !== "models" && i !== "spend"), "the rest, in the default order");
  for (const e of out.slice(2)) assert.deepEqual(e, plain(by(W.defaults(P, "desktop"), e.id)));
});

test("merge: a widget a later release adds comes after what the person arranged", () => {
  const saved = W.defaults(P, "desktop").filter((e) => e.id !== "feedback").reverse();
  const out = W.normalize(P, "desktop", saved);
  assert.equal(out[out.length - 1].id, "feedback");
  assert.equal(by(out, "feedback").hidden, false);
});

test("clamping: spans to the widget's narrowest and the screen's columns, heights to auto/s/m/l, hidden to a boolean", () => {
  const out = W.normalize(P, "desktop", [{ id: "spend", span: 99, height: "xl", hidden: "yes" }, { id: "models", span: 0, height: "L", hidden: 1 },
    { id: "services", span: "7", height: "m", hidden: true }, { id: "logins", span: 3.6 }, { id: "maint", span: -2 }, { id: "claude", span: NaN }]);
  assert.deepEqual(plain(out.slice(0, 6).map((e) => e.span)), [12, 4, 7, 4, 3, 12]);
  assert.deepEqual(plain(out.slice(0, 3).map((e) => e.height)), ["auto", "auto", "m"]);
  assert.deepEqual(plain(out.slice(0, 3).map((e) => e.hidden)), [false, false, true], "only true hides");
  assert.equal(W.clampSpan(W.HOME[0], "tablet", 40), 6);
  assert.equal(W.minSpan(W.HOME.find((w) => w.id === "update-card"), "desktop"), 6);
  assert.equal(W.minSpan(W.HOME.find((w) => w.id === "update-card"), "tablet"), 4);
});

test("move: one place earlier or later among the widgets shown, hidden ones skipped, and said in words", () => {
  let l = W.defaults(P, "tablet");   // gs, continue, update, spend, services, models, ...
  let r = W.moveBy(P, l, "models", -1);
  assert.equal(r.changed, true);
  assert.deepEqual(plain(ids(r.list).slice(3, 7)), ["spend", "models", "services", "logins"]);
  assert.equal(r.message, "Models moved after Bedrock spend");
  r = W.moveBy(P, l, "services", 1);
  assert.equal(r.message, "Services moved after Models");
  // a hidden widget between them is stepped over
  l = W.hide(P, l, "models").list;
  r = W.moveBy(P, l, "services", 1);
  assert.equal(r.message, "Services moved after Sign-ins");
  assert.deepEqual(plain(ids(r.list).slice(3, 7)), ["spend", "models", "logins", "services"], "the hidden one keeps its place");
  // the ends
  r = W.moveBy(P, W.defaults(P, "tablet"), "get-started", -1);
  assert.equal(r.changed, false); assert.equal(r.message, "Get started is already first");
  const last = ids(W.defaults(P, "tablet")).at(-1);
  assert.equal(W.moveBy(P, W.defaults(P, "tablet"), last, 1).message, "Send feedback is already last");
  assert.equal(W.moveBy(P, W.defaults(P, "tablet"), "get-started", -1).list.length, W.HOME.length);
  assert.equal(W.moveBy(P, l, "nope", 1).changed, false);
  // to the start
  r = W.moveBy(P, W.defaults(P, "tablet").slice(0, 3), "continue", -1);
  assert.equal(r.message, "Continue moved to the start");
});

test("move before another (a drag), or to the end", () => {
  const l = W.defaults(P, "desktop");
  let r = W.moveBefore(P, l, "feedback", "spend");
  assert.deepEqual(plain(ids(r.list).slice(2, 6)), ["update-card", "feedback", "spend", "services"]);
  assert.equal(r.message, "Send feedback moved after Update");
  r = W.moveBefore(P, l, "spend", null);
  assert.equal(ids(r.list).at(-1), "spend");
  assert.equal(W.moveBefore(P, l, "spend", "spend").changed, false);
  assert.equal(W.moveBefore(P, l, "spend", "services").changed, false, "already just before it: nothing to save");
  assert.equal(W.moveBefore(P, l, "spend", "nope").changed, false);
  assert.equal(W.moveBefore(P, l, "nope", "spend").changed, false);
  assert.equal(W.moveBefore(P, l, "continue", "get-started").message, "Continue moved to the start");
});

test("resize: whole columns, clamped to the narrowest and the screen, said as 'N of M columns wide'", () => {
  const l = W.defaults(P, "desktop");
  let r = W.setSpan(P, "desktop", l, "spend", 8);
  assert.equal(by(r.list, "spend").span, 8);
  assert.equal(r.message, "Bedrock spend is 8 of 12 columns wide");
  assert.equal(by(W.setSpan(P, "desktop", l, "spend", 1).list, "spend").span, 4, "never narrower than its narrowest");
  assert.equal(by(W.setSpan(P, "desktop", l, "spend", 40).list, "spend").span, 12);
  assert.equal(W.setSpan(P, "desktop", l, "spend", 5).changed, false, "already 5");
  assert.equal(by(W.resizeBy(P, "desktop", l, "spend", 1).list, "spend").span, 6);
  assert.equal(by(W.resizeBy(P, "desktop", l, "spend", -9).list, "spend").span, 4);
  assert.equal(W.setSpan(P, "tablet", W.defaults(P, "tablet"), "spend", 5).message, "Bedrock spend is 5 of 6 columns wide");
  assert.equal(W.resizeBy(P, "desktop", l, "nope", 1).changed, false);
  assert.deepEqual(plain(l), plain(W.defaults(P, "desktop")), "the input is never changed");
});

test("height: auto, S, M, L; a step taller or shorter goes S, M, L, Auto", () => {
  const l = W.defaults(P, "desktop");
  let r = W.setHeight(P, l, "models", "m");
  assert.equal(by(r.list, "models").height, "m"); assert.equal(r.message, "Models height: medium");
  assert.equal(W.setHeight(P, l, "models", "auto").changed, false);
  assert.equal(W.setHeight(P, l, "models", "huge").changed, false);
  assert.equal(W.setHeight(P, l, "models", "auto").message, "Models height: automatic");
  const at = (h) => W.setHeight(P, l, "models", h).list;
  assert.equal(by(W.heightStep(P, at("s"), "models", 1).list, "models").height, "m");
  assert.equal(by(W.heightStep(P, at("l"), "models", 1).list, "models").height, "auto");
  assert.equal(by(W.heightStep(P, at("auto"), "models", -1).list, "models").height, "l");
  assert.equal(W.heightStep(P, at("s"), "models", -1).changed, false, "S is the shortest");
  assert.equal(W.heightStep(P, l, "models", 1).changed, false, "Auto is the tallest");
  assert.equal(W.styleFor({ span: 5, height: "m" }, "desktop").maxHeight, "20rem");
  assert.equal(W.styleFor({ span: 5, height: "auto" }, "desktop").maxHeight, "");
});

test("hide and show: the person's choice, kept in place; show puts it back where it was", () => {
  const l = W.defaults(P, "desktop");
  let r = W.hide(P, l, "update-card");
  assert.equal(by(r.list, "update-card").hidden, true); assert.equal(r.message, "Update hidden");
  assert.deepEqual(plain(ids(r.list)), plain(ids(l)), "same order");
  assert.equal(W.hide(P, r.list, "update-card").changed, false);
  const back = W.show(P, r.list, "update-card");
  assert.equal(back.message, "Update added back");
  assert.deepEqual(plain(back.list), plain(l));
  assert.equal(W.show(P, l, "update-card").changed, false);
  assert.equal(W.hide(P, l, "nope").changed, false);
  assert.deepEqual(plain(W.shown(r.list).map((e) => e.id)).includes("update-card"), false);
  // a hidden widget is not a place to move to
  assert.equal(W.moveBy(P, r.list, "update-card", 1).changed, false);
});

test("reset: the default for this screen, whatever was done", () => {
  let l = W.defaults(P, "tablet");
  l = W.hide(P, W.setSpan(P, "tablet", W.moveBy(P, l, "models", -1).list, "spend", 5).list, "feedback").list;
  assert.equal(W.isDefault(P, "tablet", l), false);
  const r = W.reset(P, "tablet");
  assert.deepEqual(plain(r.list), plain(W.defaults(P, "tablet")));
  assert.equal(r.message, "Home is back to its default layout");
});

test("the phone: one column, so no widths; order, hide and height only; Claude Code is not offered", () => {
  const l = W.defaults(P, "phone");
  assert.equal(W.setSpan(P, "phone", l, "spend", 4).changed, false);
  assert.equal(W.resizeBy(P, "phone", l, "spend", 1).changed, false);
  assert.equal(W.moveBy(P, l, "models", -1).changed, true);
  assert.equal(W.hide(P, l, "models").changed, true);
  const out = W.normalize(P, "phone", [{ id: "spend", span: 9, height: "s" }, { id: "claude", span: 3 }]);
  assert.equal(by(out, "spend").span, 1, "a width saved for another screen never widens a phone");
  assert.equal(by(out, "spend").height, "s");
  assert.equal(by(out, "claude"), undefined);
  assert.equal(W.styleFor({ span: 1, height: "auto" }, "phone").columns, "");
  assert.equal(W.styleFor({ span: 5, height: "auto" }, "desktop").columns, "span 5");
});

test("each screen's layout is its own: the document keeps one per screen and a save names one", () => {
  const doc = { version: 1, pages: { home: { desktop: [{ id: "spend", span: 6, height: "auto", hidden: false }] } } };
  assert.equal(W.entry(doc, P, "desktop").length, 1);
  assert.equal(W.entry(doc, P, "phone"), null);
  assert.equal(W.entry(doc, "code", "desktop"), null);
  assert.equal(W.entry({ version: 2, pages: doc.pages }, P, "desktop"), null);
  assert.equal(W.entry(null, P, "desktop"), null);
  const custom = W.hide(P, W.defaults(P, "phone"), "models").list;
  assert.deepEqual(plain(W.savePatch(P, "phone", custom)), { version: 1, pages: { home: { phone: plain(custom) } } });
  assert.deepEqual(plain(W.savePatch(P, "phone", W.defaults(P, "phone"))), { version: 1, pages: { home: { phone: null } } }, "the default is saved as 'none'");
});

test("what the cache or the server hands back: only a usable document is kept", () => {
  assert.deepEqual(plain(W.parseDoc("{not json")), { version: 1, pages: {} });
  assert.deepEqual(plain(W.parseDoc(null)), { version: 1, pages: {} });
  assert.deepEqual(plain(W.parseDoc('{"version":2,"pages":{}}')), { version: 1, pages: {} });
  assert.deepEqual(plain(W.parseDoc('{"version":1,"pages":[]}')), { version: 1, pages: {} });
  assert.deepEqual(plain(W.parseDoc({ version: 1, pages: { home: {} } })), { version: 1, pages: { home: {} } });
});

test("rows: a card spans as many 4 px rows as it is tall plus the 20 px gap", () => {
  assert.equal(W.rowSpan(0), 5);
  assert.equal(W.rowSpan(100), 30);
  assert.equal(W.rowSpan(101), 31);
});

test("the script keeps within the portal's rules: no inline HTML, no regular expression built at run time, a 16 KB cap like the server", () => {
  const src = source("widgets.js");
  for (const sink of ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function", "new RegExp"]) assert.ok(!src.includes(sink), sink);
  assert.equal(W.MAX_BYTES, 16 * 1024);
});
