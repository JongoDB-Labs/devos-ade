// static/updatecheck.js's rows for the update's progress popup (JON-1004): one row for each action in order, the time of each,
// the bars' widths on one scale, the slowest-first order, the summary after it ended and the text Copy timings copies.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain } from "./load.mjs";

const U = load("updatecheck.js").bnUpdateCheck._pure;
const PLAN = [["Backup", 4], ["New code", 0], ["Images", 20], ["Services", 6], ["Terminal", 30]].map(([label, secs]) => ({ label, secs }));
const J = (over = {}) => ({ id: "j1", action: "update", phase: "restarting", step: "", step_started_at: null, steps: [], plan: PLAN, updated_at: 1000, ...over });
const S = (label, took, extra = {}) => ({ label, took, ...extra });
const states = (rows) => plain(rows.map((r) => r.state));

test("took and durations read as the helper writes them", () => {
  assert.equal(U.tookSecs("12s"), 12); assert.equal(U.tookSecs("1m50s"), 110); assert.equal(U.tookSecs("0.4s"), 0.4);
  assert.equal(U.tookSecs("skipped"), null); assert.equal(U.tookSecs(""), null); assert.equal(U.tookSecs(undefined), null);
  assert.equal(U.fmtDur(0.4), "<1s"); assert.equal(U.fmtDur(12), "12s"); assert.equal(U.fmtDur(110), "1m 50s");
  assert.equal(U.fmtDur(120), "2m"); assert.equal(U.fmtDur(3725), "1h 2m"); assert.equal(U.fmtDur(3600), "1h"); assert.equal(U.fmtDur(NaN), "");
});

test("not an update: no rows", () => {
  assert.deepEqual(plain(U.updateRows(null, 1000)), []);
  assert.deepEqual(plain(U.updateRows(J({ action: "rollback", steps: [S("Restore", "3s")] }), 1000)), []);
});

test("a running job: done rows with their time, the running one with its time so far, the rest waiting with the last time", () => {
  const rows = U.updateRows(J({ steps: [S("Backup", "4s"), S("New code (git)", "0s")], step: "images", step_started_at: 988 }), 1000);
  assert.deepEqual(states(rows), ["done", "done", "running", "waiting", "waiting"]);
  assert.deepEqual(plain(rows.map((r) => r.label)), ["Backup", "New code (git)", "Images", "Services", "Terminal"]);
  assert.equal(rows[0].durText, "4s"); assert.equal(rows[1].durText, "<1s");
  assert.equal(rows[2].secs, 12); assert.equal(rows[2].durText, "12s"); assert.equal(rows[2].startedAt, 988);
  assert.equal(rows[2].note, "took 20s last time");
  assert.equal(rows[3].note, "took 6s last time"); assert.equal(rows[3].secs, null);
  assert.equal(rows[4].note, "took 30s last time");
});

test("the running row counts from the clock it is given, never under zero", () => {
  const j = J({ step: "Images", step_started_at: 990 });
  assert.equal(U.updateRows(j, 1075)[0].durText, "1m 25s");
  assert.equal(U.updateRows(j, 980)[0].secs, 0);
  assert.equal(U.updateRows(j, undefined)[0].secs, 10);   // (no clock: the job's own updated_at)
});

test("a running step the plan does not have has no note, and the plan's other steps still wait", () => {
  const rows = U.updateRows(J({ steps: [S("Backup", "4s")], step: "Something new", step_started_at: 995 }), 1000);
  const run = rows.find((r) => r.state === "running");
  assert.equal(run.label, "Something new"); assert.equal(run.note, ""); assert.equal(run.secs, 5);
  assert.deepEqual(plain(rows.filter((r) => r.state === "waiting").map((r) => r.label)), ["New code", "Images", "Services", "Terminal"]);
});

test("a finished step the plan does not have is a row like the others, with no plan to compare", () => {
  const rows = U.updateRows(J({ phase: "done", steps: [S("Backup", "4s"), S("Extra check", "7s")] }), 1000);
  assert.deepEqual(states(rows), ["done", "done"]);
  assert.equal(rows[1].durText, "7s"); assert.equal(rows[1].note, "");
});

test("an empty plan: the steps done and the running one only, nothing waits", () => {
  const rows = U.updateRows(J({ plan: [], steps: [S("Backup", "4s")], step: "Images", step_started_at: 990 }), 1000);
  assert.deepEqual(states(rows), ["done", "running"]);
  assert.equal(rows[1].note, "");
  assert.deepEqual(states(U.updateRows(J({ plan: undefined, steps: [S("Backup", "4s")], phase: "done" }), 1000)), ["done"]);
});

test("an update with no steps yet shows the plan waiting", () => {
  const rows = U.updateRows(J(), 1000);
  assert.deepEqual(states(rows), ["waiting", "waiting", "waiting", "waiting", "waiting"]);
  assert.equal(rows[1].note, "took <1s last time");   // (a step that took no time: New code, 0 s)
});

test("a skipped step is grey with its reason and has no bar", () => {
  const rows = U.updateRows(J({ steps: [S("Backup", "4s"), S("AWS key check", "skipped", { why: "checked in the last 24 hours" })], step: "Images", step_started_at: 999 }), 1000);
  const sk = rows[1];
  assert.equal(sk.state, "skipped"); assert.equal(sk.durText, "skipped"); assert.equal(sk.note, "checked in the last 24 hours"); assert.equal(sk.width, 0); assert.equal(sk.secs, null);
  const bare = U.updateRows(J({ steps: [S("AWS key check", "skipped")] }), 1000)[0];
  assert.equal(bare.note, "");
});

test("a failed job: the step it stopped in is marked failed, nothing runs or waits", () => {
  const rows = U.updateRows(J({ phase: "failed", step: "Services", step_started_at: 990, steps: [S("Backup", "4s"), S("Images", "20s"), S("Services", "1m05s", { failed: true })] }), 1000);
  assert.deepEqual(states(rows), ["done", "done", "failed"]);
  assert.equal(rows[2].durText, "1m 5s"); assert.equal(rows[2].note, "failed"); assert.equal(rows[2].width, 100);
});

test("a finished job: every row done, no running or waiting row, even with a plan step it never reached", () => {
  const rows = U.updateRows(J({ phase: "done", step: "Terminal", steps: [S("Backup", "4s"), S("Images", "20s")] }), 1000);
  assert.deepEqual(states(rows), ["done", "done"]);
});

test("bars: the longest finished action is full width, the others in proportion, none for the running, waiting or skipped", () => {
  const rows = U.updateRows(J({ steps: [S("Backup", "10s"), S("New code", "0s"), S("AWS key check", "skipped"), S("Images", "40s")], step: "Services", step_started_at: 100 }), 1000);
  assert.deepEqual(plain(rows.map((r) => r.width)), [25, 0, 0, 100, 0, 0]);   // (the running Services has run 900 s: still no bar, and it sets no scale)
});

test("a thin bar stays visible for a short action next to a long one", () => {
  const rows = U.updateRows(J({ phase: "done", steps: [S("Backup", "1s"), S("Images", "10m00s")] }), 1000);
  assert.deepEqual(plain(rows.map((r) => r.width)), [2, 100]);
});

test("nothing timed: no bars", () => {
  const rows = U.updateRows(J({ phase: "done", steps: [S("Backup", "0s"), S("Images", "")] }), 1000);
  assert.deepEqual(plain(rows.map((r) => r.width)), [0, 0]);
});

test("sorting: in order leaves the list; slowest first puts the finished by their time, then running, waiting, skipped", () => {
  const rows = U.updateRows(J({ steps: [S("Backup", "4s"), S("AWS key check", "skipped"), S("Images", "40s"), S("Docs", "4s")], step: "Services", step_started_at: 990 }), 1000);
  assert.deepEqual(plain(U.sortRows(rows, "order").map((r) => r.label)), plain(rows.map((r) => r.label)));
  assert.deepEqual(plain(U.sortRows(rows, undefined).map((r) => r.label)), plain(rows.map((r) => r.label)));
  assert.deepEqual(plain(U.sortRows(rows, "slowest").map((r) => r.label)), ["Images", "Backup", "Docs", "Services", "New code", "Terminal", "AWS key check"]);
  assert.equal(rows[0].label, "Backup");   // (the list given is not changed)
});

test("a failed action sorts with the finished ones", () => {
  const rows = U.updateRows(J({ phase: "failed", steps: [S("Backup", "4s"), S("Images", "20s"), S("Services", "1m05s", { failed: true })] }), 1000);
  assert.deepEqual(plain(U.sortRows(rows, "slowest").map((r) => r.label)), ["Services", "Images", "Backup"]);
});

test("no summary while it runs", () => {
  const j = J({ steps: [S("Backup", "4s")], step: "Images", step_started_at: 990 });
  assert.equal(U.summary(j, U.updateRows(j, 1000)), null);
});

test("summary of a finished job: the total and the 3 slowest with their share", () => {
  const j = J({ phase: "done", steps: [S("Backup", "40s"), S("New code", "0s"), S("Images", "1m05s"), S("Setup: services", "3m12s"), S("Smoke test", "3s")] });
  const s = U.summary(j, U.updateRows(j, 1000));
  assert.equal(s.total, 40 + 65 + 192 + 3);
  assert.deepEqual(plain(s.slowest), [{ label: "Setup: services", secs: 192, share: 64 }, { label: "Images", secs: 65, share: 22 }, { label: "Backup", secs: 40, share: 13 }]);
  assert.equal(s.text, "Took 5m. Slowest: Setup: services 3m 12s (64%), Images 1m 5s (22%), Backup 40s (13%).");
});

test("summary of a failed job says so; fewer than 3 timed actions list what there is; skipped ones count for nothing", () => {
  const j = J({ phase: "failed", steps: [S("AWS key check", "skipped", { why: "x" }), S("Backup", "30s"), S("Images", "10s", { failed: true })] });
  const s = U.summary(j, U.updateRows(j, 1000));
  assert.equal(s.text, "Failed after 40s. Slowest: Backup 30s (75%), Images 10s (25%).");
});

test("no summary when nothing was timed", () => {
  const j = J({ phase: "done", steps: [S("Backup", "0s")] });
  assert.equal(U.summary(j, U.updateRows(j, 1000)), null);
  assert.equal(U.summary(J({ phase: "done" }), []), null);
});

test("copy text: one LABEL, TAB, SECONDS line for each action that ran, skipped ones as skipped, then the total", () => {
  const j = J({ phase: "done", steps: [S("Backup", "4s"), S("AWS key check", "skipped", { why: "x" }), S("Services (9) (http://x)", "1m05s"), S("Quick", "0.4s")] });
  assert.equal(U.copyText(U.updateRows(j, 1000)), "Backup\t4\nAWS key check\tskipped\nServices (9) (http://x)\t65\nQuick\t0.4\nTotal\t69.4");
});

test("copy text of a running job leaves out what has not finished; tabs and line breaks in a label are spaces", () => {
  const j = J({ steps: [S("A\tb\nc", "2s")], step: "Images", step_started_at: 990 });
  assert.equal(U.copyText(U.updateRows(j, 1000)), "A b c\t2\nTotal\t2");
  assert.equal(U.copyText([]), "Total\t0");
});
