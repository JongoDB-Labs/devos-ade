// static/updatecheck.js's pure parts for an update that did not finish (JON-996): where Home offers Finish the update and
// Roll back (the failed update's card, or the update card once that card is dismissed), and their words.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain } from "./load.mjs";

const U = load("updatecheck.js").bnUpdateCheck._pure;
const A = (over = {}) => ({ version: "v0.51.1", in_progress: false,
  rollback: { available: true, to: "v0.48.0", backup: "backups/20261102-135514-auto", unfinished: true }, ...over });

test("unfinished: on the failed update's card while it shows, else on the update card", () => {
  assert.equal(U.finishMode(A(), true), "job");
  assert.equal(U.finishMode(A(), false), "card");
});

test("nothing to finish: a finished update, no rollback, a job running, or no helper state", () => {
  assert.equal(U.finishMode(A({ rollback: { available: true, to: "v0.48.0", unfinished: false } }), false), "");
  assert.equal(U.finishMode(A({ rollback: { available: false, unfinished: true } }), false), "");
  assert.equal(U.finishMode(A({ in_progress: true }), false), "");   // (the update it does looks unfinished while it runs)
  assert.equal(U.finishMode(A({ rollback: undefined }), true), "");
  assert.equal(U.finishMode(null, false), "");
});

test("the card names the code in place, the version Roll back goes to and its backup", () => {
  const f = U.finishCard(A(), { available: false, latest: "v0.51.1" });
  assert.equal(f.title, "The last update did not finish");
  assert.equal(f.meta, "You have v0.51.1's code; the update from v0.48.0 did not finish.");
  assert.deepEqual(plain(f.steps), [
    "The steps it did not finish run again: the images, then setup, which restarts the services and checks them.",
    "No new backup: Roll back still goes back to v0.48.0 with backups/20261102-135514-auto.",
  ]);
});

test("a newer release: the card says Update now installs it once the update is finished", () => {
  const f = U.finishCard(A(), { available: true, latest: "v0.52.0" });
  assert.equal(f.steps[f.steps.length - 1], "Then Update now installs v0.52.0.");
});

test("the confirmation says what runs, that no backup is taken, and where Roll back goes", () => {
  assert.equal(U.finishConfirm(A()), "Finish the update to v0.51.1: the steps it did not finish run again (the images, then setup), with no new backup, so Roll back still goes back to v0.48.0. Chat, Admin and Files may be down for a minute or two while the services restart.");
  assert.match(U.finishConfirm(A({ version: "", rollback: { available: true, unfinished: true } })), /^Finish the update to the new version: .* goes back to the previous version\./);
});
