// static/widgets.js's model: a page's layout as plain data — defaults, what was saved merged in, clamping, move, resize,
// height, hide and show, reset, the phone's rules, and the sentences read out for each change. The page half (edit mode,
// the grid) needs a browser: tests/e2e/browser/checks_widgets.py.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
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

test("the script keeps within the portal's rules: no inline HTML, no regular expression built at run time, a 32 KB cap like the server", () => {
  const src = source("widgets.js");
  for (const sink of ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function", "new RegExp"]) assert.ok(!src.includes(sink), sink);
  assert.equal(W.MAX_BYTES, 32 * 1024);
});

// ---------- the Terminal page ----------

const T = "terminal";

test("the Terminal page: the terminals always, the key bar on a tablet and a phone, the rest when asked for", () => {
  for (const d of ["desktop", "tablet", "phone"]) {
    const l = W.defaults(T, d);
    assert.deepEqual(plain(ids(l)), ["terminals", "keys", "commands", "projects"]);
    assert.equal(by(l, "terminals").hidden, false);
    assert.equal(by(l, "commands").hidden, true);
    assert.equal(by(l, "projects").hidden, true);
  }
  assert.equal(by(W.defaults(T, "desktop"), "keys").hidden, true, "a desktop has a keyboard");
  assert.equal(by(W.defaults(T, "tablet"), "keys").hidden, false);
  assert.equal(by(W.defaults(T, "phone"), "keys").hidden, false);
  assert.deepEqual(plain(W.shown(W.defaults(T, "desktop")).map((e) => e.id)), ["terminals"], "today's Terminal tab: the terminal alone");
  assert.equal(by(W.defaults(T, "desktop"), "terminals").span, 12);
  assert.equal(by(W.defaults(T, "tablet"), "terminals").span, 6);
  assert.deepEqual(plain(W.defaults(T, "phone").map((e) => e.span)), [1, 1, 1, 1]);
});

test("the terminals cannot be hidden, even by a saved layout; the others can", () => {
  const l = W.defaults(T, "desktop");
  const r = W.hide(T, l, "terminals");
  assert.equal(r.changed, false);
  assert.equal(r.message, "Terminals always show");
  assert.equal(W.hide(T, W.show(T, l, "keys").list, "keys").changed, true);
  const saved = [{ id: "terminals", span: 12, height: "auto", hidden: true }, { id: "projects", span: 6, hidden: false }];
  const n = W.normalize(T, "desktop", saved);
  assert.equal(by(n, "terminals").hidden, false);
  assert.deepEqual(plain(ids(n)), ["terminals", "projects", "keys", "commands"], "what was saved first, the rest after with their defaults");
  assert.equal(by(n, "keys").hidden, true);
  assert.equal(by(n, "projects").hidden, false);
  assert.equal(W.reset(T, "desktop").message, "The Terminal page is back to its default layout");
});

test("the terminal widgets move and resize like Home's", () => {
  let l = W.show(T, W.defaults(T, "desktop"), "keys").list;
  l = W.show(T, l, "commands").list;
  const m = W.moveBy(T, l, "commands", -1);
  assert.deepEqual(plain(ids(m.list).slice(0, 3)), ["terminals", "commands", "keys"]);
  assert.equal(m.message, "Quick commands moved after Terminals");
  assert.equal(W.setSpan(T, "desktop", l, "commands", 1).list.find((e) => e.id === "commands").span, 3, "no narrower than 3");
  assert.equal(W.setSpan(T, "desktop", l, "terminals", 1).list.find((e) => e.id === "terminals").span, 4);
  assert.equal(W.setSpan(T, "tablet", W.defaults(T, "tablet"), "terminals", 1).list.find((e) => e.id === "terminals").span, 3);
});

test("a terminal screen: nothing saved is the default, and a screen equal to it counts as the default", () => {
  for (const d of ["desktop", "tablet", "phone"]) {
    assert.deepEqual(plain(W.normalizeScreen(d, null)), plain(W.screenDefaults(d)));
    assert.deepEqual(plain(W.normalizeScreen(d, "junk")), plain(W.screenDefaults(d)));
    assert.deepEqual(plain(W.normalizeScreen(d, [])), plain(W.screenDefaults(d)));
    assert.equal(W.isDefaultScreen(d, W.normalizeScreen(d, {})), true);
  }
  assert.equal(W.screenDefaults("desktop").views, 1);
  assert.equal(W.screenDefaults("desktop").split, "cols");
  assert.deepEqual(plain(W.savePatchScreen("desktop", W.screenDefaults("desktop"))), { version: 1, pages: { terminal: { desktop: null } } });
  const two = W.addView("desktop", W.screenDefaults("desktop")).screen;
  assert.deepEqual(plain(W.savePatchScreen("desktop", two)), { version: 1, pages: { terminal: { desktop: plain(two) } } });
});

test("a terminal screen is clamped: views 1 to 4 (one on a phone), a known split, weights 1 to 100 for as many views", () => {
  const n = (d, s) => plain(W.normalizeScreen(d, s));
  assert.equal(n("desktop", { views: 9 }).views, 4);
  assert.equal(n("desktop", { views: 0 }).views, 1);
  assert.equal(n("desktop", { views: "3" }).views, 1, "a number only");
  assert.equal(n("desktop", { views: 2.6 }).views, 3);
  assert.equal(n("desktop", { views: true }).views, 1);
  assert.equal(n("phone", { views: 3 }).views, 1);
  assert.equal(n("desktop", { split: "rows" }).split, "rows");
  assert.equal(n("desktop", { split: "diagonal" }).split, "cols");
  assert.deepEqual(n("desktop", { views: 2, weights: [0, 500] }).weights, [1, 100]);
  assert.deepEqual(n("desktop", { views: 2, weights: [60] }).weights, [], "not one for each view: equal shares");
  assert.deepEqual(n("desktop", { views: 3, weights: [30, "x", 20] }).weights, [30, 50, 20]);
});

test("add a terminal and close one: 2 to 4 on a big screen, one on a phone, the last never closes", () => {
  let s = W.screenDefaults("desktop");
  for (const want of [2, 3, 4]) {
    const r = W.addView("desktop", s);
    assert.equal(r.changed, true); assert.equal(r.screen.views, want); assert.equal(r.message, `Terminal ${want} added`);
    s = r.screen;
  }
  const full = W.addView("desktop", s);
  assert.equal(full.changed, false); assert.equal(full.message, "At most 4 terminals");
  const less = W.closeView("desktop", s, 1);
  assert.equal(less.screen.views, 3); assert.equal(less.message, "Terminal 2 closed; its windows stay in the others");
  assert.deepEqual(plain(W.closeView("desktop", W.screenDefaults("desktop"), 0)), { screen: plain(W.screenDefaults("desktop")), message: "The last terminal cannot be closed", changed: false });
  assert.equal(W.addView("phone", W.screenDefaults("phone")).changed, false);
  assert.equal(W.addView("phone", W.screenDefaults("phone")).message, "A phone shows one terminal");
  assert.equal(W.closeView("desktop", s, 7).changed, false);
});

test("the split: side by side, stacked or 2 by 2, and the dividers move the shares of the two views beside them", () => {
  let s = W.addView("desktop", W.screenDefaults("desktop")).screen;
  const r = W.setSplit(s, "rows");
  assert.equal(r.screen.split, "rows"); assert.equal(r.message, "The terminals are now stacked");
  assert.equal(W.setSplit(s, "rows").changed, true);
  assert.equal(W.setSplit(r.screen, "rows").changed, false);
  assert.equal(W.setSplit(s, "sideways").changed, false);
  const d = W.dragWeights(s, 0, 20);
  assert.deepEqual(plain(d.screen.weights), [70, 30]); assert.equal(d.message, "Terminal 1 is 70 percent");
  assert.deepEqual(plain(W.dragWeights(d.screen, 0, 500).screen.weights), [90, 10], "neither under 10");
  assert.deepEqual(plain(W.dragWeights(d.screen, 0, -500).screen.weights), [10, 90]);
  assert.equal(W.dragWeights(s, 1, 5).changed, false, "no divider after the last view");
  assert.equal(W.dragWeights(W.setSplit(s, "grid").screen, 0, 5).changed, false, "a grid is even");
  const three = W.addView("desktop", d.screen).screen;
  assert.deepEqual(plain(three.weights), [], "a new view: equal shares again");
});

test("arrange: where each view sits for each split", () => {
  const a = (v, s, w = []) => plain(W.arrange(v, s, w));
  assert.deepEqual(a(1, "cols"), { cols: "1fr", rows: "1fr", cells: [{ col: "1", row: "1" }] });
  assert.deepEqual(a(2, "cols"), { cols: "50fr 50fr", rows: "1fr", cells: [{ col: "1", row: "1" }, { col: "2", row: "1" }] });
  assert.deepEqual(a(2, "cols", [70, 30]).cols, "70fr 30fr");
  assert.deepEqual(a(3, "rows", [20, 30, 50]), { cols: "1fr", rows: "20fr 30fr 50fr", cells: [{ col: "1", row: "1" }, { col: "1", row: "2" }, { col: "1", row: "3" }] });
  assert.deepEqual(a(4, "grid").cells, [{ col: "1", row: "1" }, { col: "2", row: "1" }, { col: "1", row: "2" }, { col: "2", row: "2" }]);
  assert.deepEqual(a(3, "grid").cells[2], { col: "1 / 3", row: "2" }, "the third spans the bottom");
  assert.deepEqual(a(2, "grid"), a(2, "cols"), "two in a grid are side by side");
  assert.deepEqual(a(2, "cols", [70]).cols, "50fr 50fr", "weights for another number of views: equal shares");
});

test("quick commands: a name of up to 40 characters, one printable line of up to 200, at most 20, run only when marked", () => {
  const ok = { label: "Tests", text: "npm test", run: true };
  assert.equal(W.commandProblem(ok), "");
  assert.equal(W.commandProblem({ label: " ", text: "x" }), "Give it a name");
  assert.equal(W.commandProblem({ label: "a", text: "  " }), "Type the command");
  assert.equal(W.commandProblem({ label: "a".repeat(41), text: "x" }), "A name is at most 40 characters");
  assert.equal(W.commandProblem({ label: "a".repeat(40), text: "x".repeat(200) }), "");
  assert.equal(W.commandProblem({ label: "a", text: "x".repeat(201) }), "A command is at most 200 characters");
  for (const text of ["ls\n", "a\x1b[0m", "a\tb", "x\u0085", "a\u2028b", "x\x00"]) assert.equal(W.commandProblem({ label: "a", text }), "A command is one line of printable characters", text);
  assert.equal(W.commandProblem({ label: 5, text: "x" }), "Give it a name");
  assert.equal(W.commandProblem(null), "Give it a name");
  let l = [];
  const added = W.saveCommand(l, { label: "  Tests ", text: "npm test", run: "yes" });
  assert.deepEqual(plain(added.list), [{ label: "Tests", text: "npm test", run: false }], "run is true or false; the name trimmed");
  assert.equal(added.message, "Tests added");
  l = W.saveCommand(added.list, ok).list;
  assert.equal(W.saveCommand(l, { label: "Tests2", text: "npm test:2" }, 0).message, "Tests2 saved");
  assert.deepEqual(plain(W.saveCommand(l, { label: "Tests2", text: "npm test:2" }, 0).list[0]), { label: "Tests2", text: "npm test:2", run: false });
  assert.equal(W.saveCommand(l, { label: "", text: "x" }).changed, false);
  assert.equal(W.removeCommand(l, 0).message, "Tests removed");
  assert.equal(W.removeCommand(l, 0).list.length, 1);
  assert.equal(W.removeCommand(l, 9).changed, false);
  for (let i = l.length; i < 20; i++) l = W.saveCommand(l, { label: `c${i}`, text: `echo ${i}` }).list;
  assert.equal(l.length, 20);
  const more = W.saveCommand(l, { label: "one more", text: "x" });
  assert.equal(more.changed, false); assert.equal(more.message, "At most 20 quick commands");
  assert.equal(W.saveCommand(l, { label: "edit", text: "x" }, 3).changed, true, "an edit is not one more");
});

test("quick commands from the cache or the server: the usable ones, no more than 20", () => {
  const many = Array.from({ length: 30 }, (_, i) => ({ label: `c${i}`, text: `echo ${i}`, run: i % 2 === 0 }));
  assert.equal(W.normalizeCommands(many).length, 20);
  assert.deepEqual(plain(W.normalizeCommands([{ label: "a", text: "b" }, { label: "", text: "b" }, null, "x", { label: "c", text: "d\ne" }])), [{ label: "a", text: "b", run: false }]);
  assert.deepEqual(plain(W.normalizeCommands("junk")), []);
  const doc = { version: 1, pages: { terminal: { commands: [{ label: "a", text: "b", run: true }], desktop: { views: 2 } } } };
  assert.deepEqual(plain(W.commandsEntry(doc)), [{ label: "a", text: "b", run: true }]);
  assert.deepEqual(plain(W.commandsEntry(null)), []);
  assert.deepEqual(plain(W.commandsEntry({ version: 2, pages: doc.pages })), []);
  assert.deepEqual(plain(W.screenEntry(doc, T, "desktop")), { views: 2 });
  assert.equal(W.screenEntry(doc, T, "phone"), null);
  assert.equal(W.screenEntry(doc, T, "commands"), null, "the commands are no screen");
  assert.deepEqual(plain(W.savePatchCommands([{ label: "a", text: "b", run: false }])), { version: 1, pages: { terminal: { commands: [{ label: "a", text: "b", run: false }] } } });
  assert.deepEqual(plain(W.savePatchCommands([])), { version: 1, pages: { terminal: { commands: null } } }, "none is saved as none");
});

test("the key bar offers exactly the names ttyd-keys.js knows", () => {
  const keys = readFileSync(fileURLToPath(new URL("../../../terminal/ttyd-keys.js", import.meta.url)), "utf8");
  const table = keys.slice(keys.indexOf("var KEYS = {"), keys.indexOf("};", keys.indexOf("var KEYS = {")));
  const known = [...table.matchAll(/(?:^|[\s,{])"?([a-z][a-z-]*)"?: \[/g)].map((m) => m[1]).sort();
  assert.deepEqual(plain(W.KEYS.map((k) => k[0]).sort()), known);
  assert.equal(W.KEYS.every((k) => typeof k[1] === "string" && k[1]), true);
});

test("the terminal page's limits are the server's", () => {
  assert.deepEqual(plain([W.VIEWS_MAX, W.COMMANDS_MAX, W.COMMAND_LABEL_MAX, W.COMMAND_TEXT_MAX]), [4, 20, 40, 200]);
  assert.deepEqual(plain(W.SPLITS), ["cols", "rows", "grid"]);
});

test("the Terminal page's script keeps within the portal's rules and sends only what ttyd-keys.js reads", () => {
  const src = source("termpage.js");
  for (const sink of ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function", "new RegExp"]) assert.ok(!src.includes(sink), sink);
  assert.ok(src.includes("postMessage(msg, termOrigin)") && !src.includes('postMessage(msg, "*")'), "a message goes to the terminal host's origin only");
  const sent = new Set([...src.matchAll(/post\((?:paneFrame\(\)|f), \{ type: "([a-z]+)"/g)].map((m) => m[1]));
  assert.deepEqual([...sent].sort(), ["focus", "key", "mods", "text"]);
  const keys = readFileSync(fileURLToPath(new URL("../../../terminal/ttyd-keys.js", import.meta.url)), "utf8");
  for (const t of sent) assert.ok(keys.includes(`d.type === "${t}"`), `ttyd-keys.js reads ${t}`);
});
