// static/updatecheck.js's progress bar for an update (JON-978): steps done of the plan, the time left, the words for a screen
// reader, and the announcement once for each step. lib/plan.sh has the same arithmetic for a terminal (tests/test_plan.sh).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain, source } from "./load.mjs";

const U = load("updatecheck.js").bnUpdateCheck._pure;
const PLAN = [["Backup", 4], ["New code", 0], ["Images", 1], ["Services", 6], ["Terminal", 20]].map(([label, secs]) => ({ label, secs }));
const J = (over = {}) => ({ id: "j1", action: "update", phase: "restarting", step: "", step_started_at: null, steps: [], plan: PLAN, updated_at: 1000, ...over });
const done = (...l) => l.map((label) => ({ label, took: "1s" }));

test("nothing done: every step to come, the plan's seconds left", () => {
  const p = U.progress(J());
  assert.equal(p.done, 0); assert.equal(p.total, 5); assert.equal(p.left, 31); assert.equal(p.pct, 0);
  assert.equal(p.valuetext, "Starting, 5 steps, less than a minute left");
});

test("steps done and one running: the number, the label and the time left", () => {
  const p = U.progress(J({ steps: done("Backup", "New code (git)"), step: "Terminal", step_started_at: 992, updated_at: 1000 }));
  assert.equal(p.done, 2); assert.equal(p.total, 5); assert.equal(p.stepNo, 3);
  assert.equal(p.left, 12 + 1 + 6);   // Terminal: 20 - 8 s run; Images and Services still to come
  assert.equal(p.valuenow, 3); assert.equal(p.valuemax, 5);
  assert.equal(p.valuetext, "Step 3 of 5, Terminal, less than a minute left");
  assert.equal(p.text, "Step 3 of 5 · Terminal · under a minute left");
  assert.deepEqual(plain(p.todo), [{ label: "Images", secs: 1 }, { label: "Services", secs: 6 }]);
});

test("a label with a count or an address matches the plan's step without it", () => {
  const p = U.progress(J({ steps: done("Backup", "New code (git)", "Images"), step: "Services (9) (http://127.0.0.1:8765)", step_started_at: 995, updated_at: 1000 }));
  assert.equal(p.total, 5); assert.equal(p.label, "Services"); assert.equal(p.left, 5 + 20);   // Services: 6 - 5 s = 1, but at least 5; Terminal 20
  assert.deepEqual(plain(p.todo), [{ label: "Terminal", secs: 20 }]);
});

test("a step that runs long keeps a few seconds left, and the bar stays short of done", () => {
  const p = U.progress(J({ steps: done("Backup", "New code", "Images", "Services"), step: "Terminal", step_started_at: 100, updated_at: 1000 }));
  assert.equal(p.left, 5); assert.equal(p.valuetext, "Step 5 of 5, Terminal, a few seconds left");
  assert.equal(p.pct, 98);   // 4 steps and 0.9 of the fifth, of 5: never 100 until the job is done
  assert.ok(p.pct < 100);
});

test("a step the plan does not have counts as it comes", () => {
  const p = U.progress(J({ steps: done("Backup", "Brand new step"), step: "Another new one", step_started_at: 999, updated_at: 1000 }));
  assert.equal(p.total, 7); assert.equal(p.done, 2); assert.equal(p.stepNo, 3);
  assert.equal(p.left, 5 + 0 + 1 + 6 + 20);   // the running one (expected 0): a few seconds; New code still to come at 0
  // a step that repeats is a step of its own
  assert.equal(U.progress(J({ steps: done("Backup", "Backup") })).total, 6);
});

test("a skipped step counts as a step done", () => {
  const p = U.progress(J({ steps: [{ label: "Backup", took: "4s" }, { label: "New code", took: "skipped", why: "nothing new" }], step: "Images", step_started_at: 1000 }));
  assert.equal(p.done, 2); assert.equal(p.stepNo, 3);
});

test("the job is done: 100 %, whatever the plan said", () => {
  const p = U.progress(J({ phase: "done", steps: done("Backup", "New code", "Images", "Services") }));
  assert.equal(p.pct, 100); assert.equal(p.finished, true); assert.equal(p.valuenow, p.valuemax);
  assert.equal(p.valuetext, "Done, 4 steps");   // (the steps it took: the plan's Terminal was not reached)
  assert.deepEqual(plain(p.todo.map((x) => x.label)), ["Terminal"]);   // (the card hides the list of what is still to come)
  assert.equal(U.progress(J({ phase: "done", steps: done("A", "B", "C", "D", "E", "F", "G") })).valuenow, 7);   // more steps than planned: all of them
});

test("no plan at all: the steps as they come", () => {
  const p = U.progress(J({ plan: [], steps: done("Backup"), step: "Images", step_started_at: 995 }));
  assert.equal(p.total, 2); assert.equal(p.stepNo, 2); assert.equal(p.left, 5);
  assert.equal(U.progress(J({ plan: [], steps: [], step: "" })), null);
});

test("the server's clock measures a running step when the record is written once a step", () => {
  const job = J({ steps: done("Backup"), step: "Terminal", step_started_at: 900, updated_at: 900 });
  assert.equal(U.progress(job).left, 20 + 1 + 6);   // (without it: the record's own time, nothing run yet)
  assert.equal(U.progress(job, 910).left, 10 + 1 + 6);
  assert.equal(U.progress(job, 960).left, 5 + 1 + 6);
});

test("not an update, or nonsense: no bar", () => {
  assert.equal(U.progress(J({ action: "rollback" })), null);
  for (const x of [null, undefined, "x", 5, []]) assert.equal(U.progress(x), null);
  const p = U.progress(J({ plan: [null, 3, { label: 5 }, { label: "Backup", secs: "x" }], steps: [null, { label: "Backup" }] }));
  assert.equal(p.total, 1);
});

test("the time left in words", () => {
  assert.equal(U.leftWords(3).long, "a few seconds left");
  assert.equal(U.leftWords(40).long, "less than a minute left");
  assert.equal(U.leftWords(40).short, "under a minute left");
  assert.equal(U.leftWords(60).long, "about 1 minute left");
  assert.equal(U.leftWords(95).long, "about 2 minutes left");
  assert.equal(U.leftWords(95).short, "~2 min left");
});

test("aria: the words a screen reader gets name the step, how many, and the time left", () => {
  const p = U.progress(J({ steps: done(...Array(13).fill("Images")), plan: Array.from({ length: 31 }, (_, i) => ({ label: i < 14 ? "Images" : `S${i}`, secs: 3 })), step: "Images", step_started_at: 1000 }));
  assert.equal(p.valuenow, 14); assert.equal(p.valuemax, 31);
  assert.match(p.valuetext, /^Step 14 of 31, Images, /);
  assert.match(U.progress(J({ plan: [{ label: "Images", secs: 70 }], step: "Images", step_started_at: 1000 })).valuetext, /^Step 1 of 1, Images, about 1 minute left$/);
});

test("a polite announcement once for each step, none when only the time changed", () => {
  const at = (n, extra = {}) => U.progress(J({ steps: done(...Array(n).fill("Backup")), step: "Images", step_started_at: 990, ...extra }));
  let a = U.announce("", at(2), "j1");
  assert.equal(a.key, "j1:3"); assert.match(a.say, /^Step 3 of /);
  a = U.announce(a.key, at(2, { updated_at: 1010 }), "j1");   // the same step, a poll later
  assert.equal(a.say, ""); assert.equal(a.key, "j1:3");
  a = U.announce(a.key, at(3), "j1");
  assert.equal(a.key, "j1:4"); assert.match(a.say, /^Step 4 of /);
  a = U.announce(a.key, U.progress(J({ phase: "done", steps: done("Backup") })), "j1");
  assert.equal(a.key, "j1:done"); assert.equal(a.say, "Done, 1 step");
  a = U.announce("j1:3", at(2), "j2");   // another job
  assert.notEqual(a.say, "");
  assert.deepEqual(plain(U.announce("x", null, "j1")), { key: "", say: "" });
});

test("the card's markup: a progressbar with its range, its words hidden from the live region, and a live region of its own", () => {
  const html = source("index.html");
  assert.match(html, /id="job-bar"[^>]*role="progressbar"[^>]*aria-valuemin="0"[^>]*aria-valuemax="1"[^>]*aria-valuenow="0"/);
  assert.match(html, /id="job-progress-text"[^>]*aria-hidden="true"/);
  assert.match(html, /id="job-progress-live"[^>]*aria-live="polite"/);
  const js = source("app.js");
  for (const attr of ["aria-valuemin", "aria-valuemax", "aria-valuenow", "aria-valuetext"]) assert.ok(js.includes(`"${attr}"`), attr);
  assert.ok(js.includes("U.announce(progressKey"));
  const css = source("app.css");
  assert.match(css, /\.job-bar-fill[^}]*var\(--accent\)/);   // the tokens, so dark mode follows
  assert.match(css, /prefers-reduced-motion[^}]*\.job-bar-fill/);
});

test("a step that failed is the last one listed, marked failed, with how long it ran (JON-996)", () => {
  assert.deepEqual(plain(U.stepItem({ label: "Smoke test", took: "2m45s", failed: true })), { cls: "failed", text: "Smoke test · 2m45s · failed" });
  assert.deepEqual(plain(U.stepItem({ label: "Smoke test", took: "", failed: true })), { cls: "failed", text: "Smoke test · failed" });
  assert.deepEqual(plain(U.stepItem({ label: "Images", took: "9s" })), { cls: "", text: "Images · 9s" });
  assert.deepEqual(plain(U.stepItem({ label: "Images", took: "skipped", why: "no change" })), { cls: "skipped", text: "Images · skipped (no change)" });
});

test("Home's card uses it, and styles a failed step", () => {
  assert.match(source("app.js"), /U\.stepItem|bnUpdateCheck\._pure\.stepItem/);
  assert.match(source("app.css"), /\.job-done li\.failed/);
});
