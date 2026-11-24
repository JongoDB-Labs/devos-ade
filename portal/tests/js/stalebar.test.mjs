// static/stalebar.js's pure part: when an open page is out of date (JON-1127). The page's build is in its
// <meta name="bn-build">; /api/admin/status answers the running one.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

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
