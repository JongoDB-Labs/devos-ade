// static/search.js's pure parts: the Settings and docs entries, the Code tab's frame's answer checked, grouping and
// caps, and untrusted text made visible.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain } from "./load.mjs";

const ctx = load("fuzzy.js", "search.js");
const S = ctx.bnSearch._pure;
const U1 = "11111111-1111-4111-8111-111111111111";

const INDEX = {
  settings: {
    sections: [{ id: "spending", title: "Spending & budgets", lede: "A monthly budget for each key" }, { id: "Bad!", title: "x" }],
    rows: [{ key: "BUDGET_TERMINAL", section: "spending", section_title: "Spending & budgets", title: "Terminal budget", summary: "Monthly limit for the Terminal tab", parent: "" },
      { key: "+backups", section: "updates", section_title: "Updates & backups", title: "Backups (Back up now)", summary: "Back up now", parent: "" },
      { key: "lower_case", section: "x", title: "x" }, { key: "A".repeat(50), section: "x", title: "x" }],
  },
  docs: { pages: [{ file: "README.md", title: "devos-ade", sections: [{ anchor: "costs--budgets", title: "Costs & budgets", level: 2, parent: "", text: "Every key has a budget." },
    { anchor: "bad anchor", title: "x" }] }, { file: "../etc/passwd", title: "x", sections: [] }, { file: "docs/security.md", title: "Security model", sections: [] }] },
};

test("Settings: sections and settings, each opening its place (#settings/<id> or #settings/<KEY>); odd rows dropped", () => {
  const e = plain(S.settingsEntries(INDEX));
  assert.deepEqual(e.map((x) => x.href), ["#settings/spending", "#settings/BUDGET_TERMINAL", "#settings/+backups"]);
  assert.equal(e[1].sub, "Spending & budgets · BUDGET_TERMINAL");
  assert.equal(e[2].sub, "Updates & backups", "the page's own rows have no key to show");
  assert.match(e[1].alt, /BUDGET_TERMINAL Monthly limit/);
  assert.deepEqual(plain(S.settingsEntries(null)), []);
});

test("Docs: the installed release's docs on GitHub (else main), a page and its sections; odd files and anchors dropped", () => {
  const e = plain(S.docEntries(INDEX, "v0.10.0"));
  assert.deepEqual(e.map((x) => x.url), ["https://github.com/JongoDB-Labs/devos-ade/blob/v0.10.0/README.md",
    "https://github.com/JongoDB-Labs/devos-ade/blob/v0.10.0/README.md#costs--budgets",
    "https://github.com/JongoDB-Labs/devos-ade/blob/v0.10.0/docs/security.md"]);
  assert.equal(S.docsBase("v0.10.0-3-gabc1234"), "https://github.com/JongoDB-Labs/devos-ade/blob/main/");
  assert.equal(S.docsBase(""), "https://github.com/JongoDB-Labs/devos-ade/blob/main/");
  assert.equal(S.docsBase("main/../../evil"), "https://github.com/JongoDB-Labs/devos-ade/blob/main/");
});

test("the Code tab's frame's answer: only the one asked for, sessions by UUID, files as clean relative paths", () => {
  const ans = { type: "bn-code-search", id: "abc", sessions: [{ id: U1, title: "notes\u202Etxt.exe" }, { id: "x", title: "y" }, null],
    files: ["src/a.ts", "dir/", "../up", "/abs", "a//b", "ok\u0000", "x".repeat(2000), "./a", "notes/\u200Bhidden.md"], truncated: true };
  const r = plain(S.takeCodeReply(ans, "abc"));
  assert.deepEqual(r.sessions, [{ id: U1, title: "notes⟨U+202E⟩txt.exe" }]);
  assert.deepEqual(r.files.map((f) => f.path), ["src/a.ts", "notes/\u200Bhidden.md"]);
  assert.equal(r.files[1].shown, "notes/⟨U+200B⟩hidden.md");
  assert.equal(r.truncated, true);
  assert.equal(S.takeCodeReply(ans, "other"), null);
  assert.equal(S.takeCodeReply({ ...ans, type: "bn-code-status" }, "abc"), null);
  assert.equal(S.takeCodeReply(null, "abc"), null);
  const many = plain(S.takeCodeReply({ type: "bn-code-search", id: "a", sessions: Array.from({ length: 50 }, () => ({ id: U1, title: "t" })), files: Array.from({ length: 99 }, (_, i) => `f${i}`) }, "a"));
  assert.equal(many.sessions.length, 20);
  assert.equal(many.files.length, 30);
});

test("untrusted text: control and direction characters made visible, line breaks as spaces, capped; linear time", () => {
  assert.equal(S.shownText("a\nb\tc\u0007d\u2066e\uFEFF", 100), "a b c⟨U+0007⟩d⟨U+2066⟩e⟨U+FEFF⟩");
  assert.equal(S.shownText("x".repeat(500), 120).length, 120);
  const t0 = Date.now();
  S.shownText("\u202E".repeat(200000), 120);
  S.shownText("a\u200B".repeat(200000), 300);
  assert.ok(Date.now() - t0 < 500);
});

test("grouping: each group capped, the group with the best match first; what a source matched itself stays", () => {
  const entries = [
    ...Array.from({ length: 20 }, (_, i) => ({ group: "settings", key: `s${i}`, title: `Budget ${i}`, sub: "", alt: "" })),
    { group: "chats", key: "c1", title: "Trip planning", sub: "", alt: "", prefiltered: true },   // Chat found "budget" in its text
    { group: "docs", key: "d1", title: "Costs & budgets", sub: "README.md", alt: "" },
    { group: "pages", key: "p1", title: "Home", sub: "", alt: "" },
  ];
  const g = plain(S.searchEntries(entries, "budget"));
  assert.deepEqual(Object.keys(g), ["settings", "docs", "chats"], "the best match's group first; Chat's own match last");
  assert.equal(g.settings.shown.length, 8);
  assert.equal(g.settings.more, 12);
  assert.equal(g.chats.shown[0].entry.title, "Trip planning");
  assert.deepEqual(g.docs.shown[0].hits, [8, 9, 10, 11, 12, 13]);
});

test("an exact title in a later group comes before letters scattered through settings", () => {
  const entries = [
    ...Array.from({ length: 5 }, (_, i) => ({ group: "settings", key: `s${i}`, title: `Owner email notes store for both ${i} things`, sub: "", alt: "" })),
    { group: "settings", key: "x", title: "Only some text sharing the letters o n e s t o r e", sub: "", alt: "" },
    { group: "tour", key: "t", title: "One store for both", sub: "", alt: "" },
  ];
  assert.equal(Object.keys(plain(S.searchEntries(entries, "One store for both")))[0], "tour");
});

test("where a setting is changed comes first: a word match in Settings goes above the walkthrough, its section first (UX-22)", () => {
  const entries = [
    { group: "tour", key: "tour:budgets", title: "Budgets", sub: "Walkthrough · Set up", alt: "" },
    { group: "settings", key: "row:ALERT_WEBHOOK_URL", title: "Budget alert webhook", sub: "Spending & budgets · ALERT_WEBHOOK_URL", alt: "" },
    { group: "settings", key: "row:BUDGET_OPENWEBUI", title: "Chat budget", sub: "Spending & budgets · BUDGET_OPENWEBUI", alt: "" },
    { group: "settings", key: "sec:spending", title: "Spending & budgets", sub: "Settings section", alt: "" },
    { group: "docs", key: "doc:x", title: "Budgets", sub: "README.md", alt: "" },
    { group: "pages", key: "p:settings", title: "Settings", sub: "", alt: "" },
  ];
  const g = plain(S.searchEntries(entries, "budget"));
  assert.deepEqual(Object.keys(g), ["settings", "tour", "docs"]);
  assert.deepEqual(g.settings.shown.map((x) => x.entry.title), ["Spending & budgets", "Budget alert webhook", "Chat budget"]);
  // letters scattered through a title are no word match: the exact walkthrough title still leads then
  const loose = plain(S.searchEntries([{ group: "settings", key: "row:X", title: "Big update daily", sub: "", alt: "" },
    { group: "tour", key: "t", title: "Budgets", sub: "", alt: "" }], "budget"));
  assert.equal(Object.keys(loose)[0], "tour");
  // a page of the portal by its own name keeps its place before a setting that merely has the word
  const page = plain(S.searchEntries([{ group: "settings", key: "row:BUDGET_TERMINAL", title: "Terminal budget", sub: "", alt: "" },
    { group: "pages", key: "p:terminal", title: "Terminal", sub: "", alt: "" }, { group: "tour", key: "t", title: "Terminal", sub: "", alt: "" }], "terminal"));
  assert.deepEqual(Object.keys(page), ["pages", "settings", "tour"]);
  assert.equal(S.wordHit("Spending & budgets", "budget"), true);
  assert.equal(S.wordHit("Nobudget here", "budget"), false);
  assert.equal(S.wordHit("Chat budget", "chat budg"), true);
});
