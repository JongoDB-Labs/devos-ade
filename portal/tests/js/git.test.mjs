// static/git.js's pure parts (JON-979): which places of the built-in git server an address can open (#git/<owner>/<repo>[/issues
// | /pulls | /src/…]) and where in the frame they go; nothing outside those shapes is ever loaded from an address.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain } from "./load.mjs";

const G = load("git.js").bnGit._pure;

test("places: a repository, its issues and pull requests (with a number), and a file or branch; the front page for none", () => {
  assert.equal(G.gitPath(""), "");
  assert.equal(G.gitPath(undefined), "");
  assert.equal(G.gitPath("devos/notes"), "/devos/notes");
  assert.equal(G.gitPath("devos/notes.v2"), "/devos/notes.v2");
  assert.equal(G.gitPath("devos/notes/issues"), "/devos/notes/issues");
  assert.equal(G.gitPath("devos/notes/issues/12"), "/devos/notes/issues/12");
  assert.equal(G.gitPath("devos/notes/pulls"), "/devos/notes/pulls");
  assert.equal(G.gitPath("devos/notes/pulls/3"), "/devos/notes/pulls/3");
  assert.equal(G.gitPath("devos/notes/src/branch/main/lib/a%20b.txt"), "/devos/notes/src/branch/main/lib/a%20b.txt");
  assert.equal(G.gitPath("devos/notes/src/tag/v1.2.0"), "/devos/notes/src/tag/v1.2.0");
  assert.equal(G.gitPath("explore/code?q=budget"), "/explore/code?q=budget");
});

test("places: anything else is refused, not loaded", () => {
  for (const p of ["devos", "devos/", "/devos/notes", "devos//notes", "../notes", "devos/..", "devos/./issues", "devos/notes/issues/x", "devos/notes/issues/1/2",
    "devos/notes/issues/12345678901", "devos/notes/settings", "devos/notes/src", "devos/notes/src/branch", "devos/notes/src/other/main",
    "devos/notes/src/branch/../x", "devos/notes/src/branch/%2e%2e/x", "devos/notes/src/branch/a%2Fb", "devos/notes/src/branch/a%5Cb", "devos/notes/src/branch/a%00",
    "devos/notes/raw/branch/main/x", "devos/notes.git", "admin/settings", "user/settings", "explore/repos", "api/v1", "-/admin", "devos/notes?x=1", "devos/notes#top",
    "devos/no tes", "devos/notes/src/branch/" + "a/".repeat(20), "x".repeat(700), "explore/code?q=a b", "explore/code?q=", "explore/code?q=%2e%2e%2f",
    "http://evil.example/x", "javascript:alert(1)", "devos\\notes"]) {
    assert.equal(G.gitPath(p), null, p);
  }
});

test("addresses: the git server's own origin only, whatever BASE's path", () => {
  assert.equal(G.gitUrl("devos/notes/issues/4", "http://git.devos-ade.localhost/"), "http://git.devos-ade.localhost/devos/notes/issues/4");
  assert.equal(G.gitUrl("", "http://git.devos-ade.localhost:8800/"), "http://git.devos-ade.localhost:8800/");
  assert.equal(G.gitUrl("devos/notes", "http://git.devos-ade.localhost:8800/some/where"), "http://git.devos-ade.localhost:8800/devos/notes");
  assert.equal(G.gitUrl("//evil.example/x", "http://git.devos-ade.localhost/"), null);
  assert.equal(G.gitUrl("devos/notes", "not a url"), null);
});

test("what a search result opens: a repository, or an issue or a pull request of it (a number is a number)", () => {
  assert.equal(G.placeOf({ repo: "devos/notes" }), "devos/notes");
  assert.equal(G.placeOf({ repo: "devos/notes", number: 12, pr: false }), "devos/notes/issues/12");
  assert.equal(G.placeOf({ repo: "devos/notes", number: 13, pr: true }), "devos/notes/pulls/13");
  assert.equal(G.placeOf({ repo: "devos/notes", number: "13" }), "devos/notes");
  assert.equal(G.placeOf({ repo: "../x" }), null);
  assert.equal(G.placeOf(null), null);
});

test("the page's name and where its off page leads (catalog/setup-links.tsv git-off)", () => {
  assert.equal(G.TITLE, "Git — your local git server");
  assert.equal(G.SWITCH, "#settings/LOCALGIT");
});

test("untrusted segments: dot segments and encoded separators fail", () => {
  assert.equal(G.segmentOk("main"), true);
  assert.equal(G.segmentOk("a%20b"), true);
  for (const s of ["", ".", "..", "%2e", "%2E%2e", "a%2fb", "a%5cb", "%", "%zz", "a b", "a\u0000b", "x".repeat(201)]) assert.equal(G.segmentOk(s), false, s);
  assert.equal(plain(G.NAV).tab, "git");
});
