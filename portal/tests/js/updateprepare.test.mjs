// static/updatecheck.js's pure parts for the update card's "prepared ahead" line (lib/prepare.sh; the heartbeat's "prepare" as
// /api/admin/status gives it) and the Prepare stage of an Update now that had to prepare first.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain, source } from "./load.mjs";

const U = load("updatecheck.js").bnUpdateCheck._pure;
const P = (over = {}) => ({ supported: true, enabled: true, state: "ready", version: "v0.5.0", step: "", reason: "", at: 1800000000, ...over });

test("ready: says the release is downloaded and built, and that Update now is quick", () => {
  assert.equal(U.prepareLine(P(), "v0.5.0"), "Ready: v0.5.0 is downloaded and built. Update now takes about half a minute.");
  assert.equal(U.prepareLine(P(), ""), "Ready: v0.5.0 is downloaded and built. Update now takes about half a minute.");
});

test("preparing: names the step and says nothing changes on this install yet", () => {
  const t = U.prepareLine(P({ state: "preparing", step: "Prepare: build open-webui" }), "v0.5.0");
  assert.equal(t, "Preparing v0.5.0 in the background: build open-webui. Nothing changes on your install until you update.");
  assert.equal(U.prepareLine(P({ state: "preparing" }), "v0.5.0"), "Preparing v0.5.0 in the background. Nothing changes on your install until you update.");
});

test("failed: said plainly, with the reason, and that Update now still works", () => {
  const t = U.prepareLine(P({ state: "failed", reason: "Prepare: build portal failed: ERROR: failed to solve: boom. " }), "v0.5.0");
  assert.equal(t, "Preparing v0.5.0 failed: Prepare: build portal failed: ERROR: failed to solve: boom. Update now still works; it does that work itself.");
  assert.equal(U.prepareLine(P({ state: "failed" }), "v0.5.0"), "Preparing v0.5.0 failed. Update now still works; it does that work itself.");
});

test("paused: a ./stack command took the lock or the computer is busy; it goes on by itself", () => {
  const t = U.prepareLine(P({ state: "yielded", step: "Prepare: build portal", reason: "./stack update started" }), "v0.5.0");
  assert.equal(t, "Preparing v0.5.0 is paused (./stack update started). It goes on by itself; Update now also does it.");
});

test("not started yet: the computer is busy; it starts by itself", () => {
  const t = U.prepareLine(P({ state: "yielded", reason: "the computer is busy: its processors are 93% in use" }), "v0.5.0");
  assert.equal(t, "Preparing v0.5.0 has not started (the computer is busy: its processors are 93% in use). It starts by itself; Update now also does it.");
});

test("nothing is said for: turned off, a helper without it, no record, another release than the newest, nonsense", () => {
  assert.equal(U.prepareLine(P({ enabled: false }), "v0.5.0"), "");
  assert.equal(U.prepareLine(P({ supported: false }), "v0.5.0"), "");
  assert.equal(U.prepareLine(P({ state: "" }), "v0.5.0"), "");
  assert.equal(U.prepareLine(P({ version: "v0.4.0" }), "v0.5.0"), "");          // superseded: the newest is not that one
  assert.equal(U.prepareLine(P({ version: "<b>v0.5.0</b>" }), ""), "");
  assert.equal(U.prepareLine(P({ state: "weird" }), "v0.5.0"), "");
  for (const x of [null, undefined, "x", 5, []]) assert.equal(U.prepareLine(x, "v0.5.0"), "");
});

test("an Update now that prepared first shows the Prepare stage; one that did not, does not", () => {
  assert.equal(U.preparedFirst({ action: "update", phase: "preparing", steps: [] }), true);
  assert.equal(U.preparedFirst({ action: "update", phase: "backing-up", steps: [{ label: "Prepare: build portal", took: "9s" }] }), true);
  assert.equal(U.preparedFirst({ action: "update", phase: "downloading", step: "Prepare: download litellm:1.0", steps: [] }), true);
  assert.equal(U.preparedFirst({ action: "update", phase: "restarting", steps: [{ label: "Backup", took: "3s" }] }), false);
  assert.equal(U.preparedFirst({ action: "rollback", phase: "preparing" }), false);
  assert.equal(U.preparedFirst(null), false);
});

test("Home's card uses them: the hint line, the confirmation's wording and the Prepare stage", () => {
  const app = source("app.js");
  assert.match(app, /bnUpdateCheck\._pure\.prepareLine\(a\.prepare/);
  assert.match(app, /its images are already downloaded and built/);
  assert.match(app, /\["preparing", "Prepare \(download and build\)"\]/);
  assert.match(app, /about half a minute/);
});
