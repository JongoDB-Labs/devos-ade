// static/feedback.js's pure parts: only the project's own new-issue address is ever linked, the facts line says what
// is filled in, and no text of the card claims a report was sent (a prefilled address gives no receipt).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const F = load("feedback.js").bnFeedback._pure;

test("only the repository's new-issue address over https is linked", () => {
  const ok = `${F.PREFIX}?template=bug.yml&title=%5BBug%5D+&version=v0.32.2&os=macOS+15.1&compose=2.40.3`;
  assert.equal(F.safeLink(ok), ok);
  for (const bad of ["http://github.com/JongoDB-Labs/devos-ade/issues/new", "https://evil.example/JongoDB-Labs/devos-ade/issues/new",
    "https://github.com/JongoDB-Labs/devos-ade/issues/new/../../../evil", "https://github.com/other/repo/issues/new", "javascript:alert(1)",
    "https://u:p@github.com/JongoDB-Labs/devos-ade/issues/new", "https://github.com/JongoDB-Labs/devos-ade/issues/new#x", "", null, 5, "x".repeat(700)]) {
    assert.equal(F.safeLink(bad), "", String(bad));
  }
});

test("the facts line names only the version, the OS and the Compose version; odd values become unknown", () => {
  assert.equal(F.factsLine({ version: "v0.32.2", os: "macOS 15.1", compose: "2.40.3" }), "DevOS ADE v0.32.2 · macOS 15.1 · Docker Compose 2.40.3");
  assert.equal(F.factsLine(null), "DevOS ADE unknown · unknown · Docker Compose unknown");
  assert.equal(F.factsLine({ version: "x".repeat(60), os: 5 }), "DevOS ADE unknown · unknown · Docker Compose unknown");
});

test("the card says it opens GitHub and that the issue is public, and never claims anything was sent", () => {
  const all = Object.values(F.WORDS).concat(F.KINDS.map((k) => k[1])).join(" ");
  assert.match(F.WORDS.opens, /opens github/i);
  assert.match(F.WORDS.warn, /public/i);
  assert.doesNotMatch(all, /\b(sent|send(s|ing)? (it|your)|delivered|received|reached|submitted for you|thanks for)\b/i);
  assert.equal(JSON.stringify(F.KINDS.map((k) => k[0])), '["bug","feature","other"]');
});
