// static/answers.js's pure parts: what each picker offers — the Terminal tab's (Claude Code on Bedrock, a shell, your
// AI subscriptions' tools, greyed with why when they cannot open here) and the Chat tab's (Open WebUI, Bedrock and
// OpenRouter models, your API keys next, the tools themselves, the subscriptions as Chat models greyed with the
// provider's reason) — the terminal's address with the pickers' words, and the saved choice read back.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load, plain } from "./load.mjs";

const A = load("answers.js").bnAnswers._pure;
const tools = [
  { id: "claude", name: "Claude Code", provider: "Anthropic", plan: "your Claude plan", command: "claude-sub", installed: true, signed_in: "yes", kind_words: "Claude Max", chat_model: "no", chat_why: "Coming next." },
  { id: "codex", name: "Codex", provider: "OpenAI", plan: "your ChatGPT plan", command: "codex", installed: true, signed_in: "no", kind_words: "", chat_model: "no", chat_why: "Terms first." },
  { id: "copilot", name: "GitHub Copilot CLI", provider: "GitHub", plan: "your Copilot plan", command: "copilot", installed: true, signed_in: "unknown", kind_words: "", chat_model: "no", chat_why: "No." },
  { id: "cursor", name: "Cursor CLI", provider: "Cursor", plan: "your Cursor plan", command: "cursor-agent", installed: false, signed_in: "no", kind_words: "", chat_model: "no", chat_why: "No." },
  { id: "grok", name: "Grok Build", provider: "xAI", plan: "SuperGrok", command: "grok", installed: null, signed_in: "unknown", kind_words: "", chat_model: "no", chat_why: "No." },
];
const data = { terminal: { here: true }, basics: [{ id: "bedrock", name: "Claude Code (Bedrock)", command: "claude-bedrock" }, { id: "shell", name: "A shell", command: "bash" }],
  tools, models: [{ id: "claude-haiku-5-5", label: "Claude Haiku 5.5", provider: "Bedrock" }, { id: "or/x", label: "X", provider: "OpenRouter" }] };

test("the Terminal tab: Bedrock and a shell, then each tool with its state; one that cannot open is greyed with why", () => {
  const g = plain(A.terminalOptions(data));
  assert.deepEqual(g.map((x) => x.items.map((i) => i.value)), [["bedrock", "shell"], ["claude", "codex", "copilot", "cursor", "grok"]]);
  const by = Object.fromEntries(g[1].items.map((i) => [i.value, i]));
  assert.equal(by.claude.label, "Claude Code (claude-sub) · signed in · Claude Max");
  assert.equal(by.codex.label, "Codex (codex) · sign in first");
  assert.equal(by.copilot.label, "GitHub Copilot CLI (copilot) · /user in it says who");
  assert.equal(by.grok.label, "Grok Build (grok) · not checked yet");
  assert.equal(by.cursor.disabled, true);
  assert.match(by.cursor.title, /TERMINAL_AI_TOOLS/);
  // the terminal off on this site (remote access without REMOTE_TERMINAL): everything greyed, said why
  const off = plain(A.terminalOptions({ ...data, terminal: { here: false } }));
  assert.ok(off.every((x) => x.items.every((i) => i.disabled)));
  assert.match(off[1].items[0].title, /REMOTE_TERMINAL/);
});

test("the Chat tab: Open WebUI first, the models, your keys next, the tools themselves, and the subscriptions as models greyed", () => {
  const g = plain(A.chatOptions(data));
  assert.deepEqual(g.map((x) => x.label), ["", "Bedrock", "OpenRouter", "Your API keys", "Your AI subscriptions — the tool itself, here", "Your AI subscriptions as Chat models"]);
  assert.equal(g[0].items[0].value, "owui");
  assert.deepEqual(g[1].items.map((i) => i.value), ["model:claude-haiku-5-5"]);
  assert.equal(g[3].items[0].disabled, true);
  assert.deepEqual(g[4].items.map((i) => [i.value, i.disabled]), [["tool:claude", false], ["tool:codex", false], ["tool:copilot", false], ["tool:cursor", true], ["tool:grok", false]]);
  assert.ok(g[5].items.every((i) => i.disabled && i.title));
  assert.equal(g[5].items[1].title, "Terms first.");
});

test("Open WebUI's address for a new chat with a model", () => {
  assert.equal(A.chatSrc("http://chat.bedrock-now.localhost/?x=1#y", "or/x:free"), "http://chat.bedrock-now.localhost/?models=or%2Fx%3Afree");
  assert.equal(A.chatSrc("http://chat.bedrock-now.localhost/", ""), "http://chat.bedrock-now.localhost/");
  assert.equal(A.terminalSrc, undefined, "the page never builds the terminal's words itself: the portal does, with a launch token");
});

test("the saved choice is read back checked", () => {
  assert.deepEqual(plain(A.parseSaved(JSON.stringify({ chat: "tool:codex", folder: "/workspace/app" }))), { chat: "tool:codex", folder: "/workspace/app" });
  for (const bad of [null, "{", "[]", JSON.stringify({ chat: "javascript:x", folder: "rel" }), JSON.stringify({ chat: "tool:../x", folder: "/a\nb" })]) {
    assert.deepEqual(plain(A.parseSaved(bad)), { chat: "owui", folder: "" }, String(bad));
  }
});

test("the Chat tab: your subscriptions as models while they can answer (Open WebUI's own model ids), else greyed with why", () => {
  const g = plain(A.chatOptions({ ...data, plan_models: [{ id: "plan-codex", tool: "codex", label: "Codex · your ChatGPT plan", ok: true, why: "" },
    { id: "plan-claude", tool: "claude", label: "Claude Code · your Claude plan", ok: false, why: "off: Settings" }] }));
  const models = g.find((x) => x.label === "Your AI subscriptions as Chat models").items;
  assert.deepEqual(models.slice(0, 2).map((i) => [i.value, i.disabled]), [["model:plan-codex", false], ["model:plan-claude", true]]);
  assert.match(models[1].label, /off: Settings$/);
  assert.match(models[0].title, /no \$/);
  // one that lacks only Chat's own sign-in: "Sign in for Chat…", a choice that goes to Settings' row (never a model)
  const s = plain(A.chatOptions({ ...data, plan_models: [{ id: "plan-grok", tool: "grok", label: "Grok · x", ok: false, why: "Sign in for Chat…", signin: true },
    { id: "plan-x", tool: "../x", label: "X", ok: false, why: "w", signin: true }] })).find((x) => x.label === "Your AI subscriptions as Chat models").items;
  assert.deepEqual(s.slice(0, 2).map((i) => [i.value, i.disabled]), [["signin:grok", false], ["model:plan-x", true]]);
  assert.match(s[0].label, /Sign in for Chat…$/);
});

// --- greyed items go where they are turned on (catalog/setup-links.tsv, served as the answers' `setup`) ---
import fs from "node:fs";
import path from "node:path";
// (the repository's table where it is here — the image's test stage has none: the same rows, written out)
const TSV = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "..", "..", "catalog", "setup-links.tsv");
const parse = (text) => Object.fromEntries(text.split("\n").filter((l) => l && !l.startsWith("#")).map((l) => l.split("\t")).map(([r, target, says]) => [r, { target, says }]));
const SETUP = fs.existsSync(TSV) ? parse(fs.readFileSync(TSV, "utf8")) : {
  "terminal-off": { target: "setting:TERMINAL_ENABLED", says: "The browser terminal is off: Settings › Claude Code › Browser terminal turns it on." },
  "terminal-remote-off": { target: "setting:REMOTE_TERMINAL", says: "Not over remote access: Settings › Remote access › …" },
  "tool-left-out": { target: "setting:TERMINAL_AI_TOOLS", says: "Not in the sandbox: Settings › Claude Code › Tools in the sandbox puts it in." },
  "code-off": { target: "setting:CODE_ENABLED", says: "Needs the Code page: Settings › Claude Code › Code page turns it on." },
  "chat-egress-off": { target: "setting:TERMINAL_EGRESS", says: "Off while the sandbox has no internet: Settings › Claude Code › Sandbox internet access." },
  "claude-plan-off": { target: "setting:CODE_CLAUDE_PLAN", says: "Off: Settings › Claude Code › Your AI subscriptions › Use my Claude plan in the Code page and Chat." },
  "chat-signin": { target: "signin:chat", says: "Sign in for Chat: Settings › Claude Code › Your AI subscriptions shows how." },
  "openrouter-off": { target: "setting:OPENROUTER_API_KEY", says: "OpenRouter's models need your OpenRouter key: Settings › Chat & voice › OpenRouter API key." },
};

test("greyed items: each a choice that goes where it is turned on, saying where — none dead, none greyed while the table has its reason", () => {
  const pm = [{ id: "plan-claude", tool: "claude", label: "Claude · your Claude plan", ok: false, why: "w", reason: "claude-plan-off" },
    { id: "plan-codex", tool: "codex", label: "Codex · ChatGPT", ok: false, why: "w", reason: "code-off" },
    { id: "plan-grok", tool: "grok", label: "Grok · x", ok: false, why: "w", reason: "chat-egress-off" },
    { id: "plan-copilot", tool: "copilot", label: "Copilot · x", ok: false, why: "w", reason: "tool-left-out" }];
  const all = [];
  for (const term of [{ here: true }, { here: false, reason: "terminal-off" }, { here: false, reason: "terminal-remote-off" }]) {
    const d = { ...data, terminal: term, setup: SETUP, plan_models: pm, openrouter: false, models: data.models.filter((m) => m.provider !== "OpenRouter") };
    all.push(...plain(A.terminalOptions(d)).flatMap((g) => g.items), ...plain(A.chatOptions(d)).flatMap((g) => g.items));
  }
  const greyed = all.filter((i) => i.disabled);
  // (left greyed: what no setting turns on — your own keys, next; a tool that is no Chat model)
  assert.ok(greyed.every((i) => i.value === "keys" || i.value.startsWith("as-model:")), JSON.stringify(greyed.map((i) => i.value)));
  const setups = all.filter((i) => i.value.startsWith("setup:"));
  const reasons = new Set(setups.map((i) => i.value.split(":")[1]));
  assert.deepEqual([...reasons].sort(), ["chat-egress-off", "claude-plan-off", "code-off", "openrouter-off", "terminal-off", "terminal-remote-off", "tool-left-out"]);
  for (const i of setups) {
    const r = i.value.split(":")[1];
    assert.ok(Object.hasOwn(SETUP, r), r);
    assert.equal(i.title, SETUP[r].says);
    assert.ok(i.label.endsWith(SETUP[r].says), i.label);   // (its words say where it goes)
    assert.ok(A.setupPlace(A.setupOf({ setup: SETUP }, r), i.value.split(":")[2]), `${r}: a place to go`);
  }
  // Sign in for Chat… says where too
  const sign = plain(A.chatOptions({ ...data, setup: SETUP, plan_models: [{ id: "plan-grok", tool: "grok", label: "Grok · x", ok: false, why: "w", reason: "chat-signin", signin: true }] }))
    .flatMap((g) => g.items).find((i) => i.value === "signin:grok");
  assert.equal(sign.title, SETUP["chat-signin"].says);
});

test("where a greyed item goes: Settings at its row, Chat's sign-in row for that tool, or the tool itself in the terminal", () => {
  assert.deepEqual(plain(A.setupPlace({ target: "setting:CODE_CLAUDE_PLAN" }, "claude")), { hash: "#settings/CODE_CLAUDE_PLAN" });
  assert.deepEqual(plain(A.setupPlace({ target: "signin:chat" }, "codex")), { hash: "#settings/+subscriptions", chat: "codex" });
  assert.deepEqual(plain(A.setupPlace({ target: "signin:chat" }, "../x")), { hash: "#settings/+subscriptions", chat: "" });
  assert.deepEqual(plain(A.setupPlace({ target: "signin:terminal" }, "codex")), { open: "codex" });
  assert.equal(A.setupPlace({ target: "signin:terminal" }, ""), null);
  assert.equal(A.setupPlace(null, "codex"), null);
  // (the table's rows checked: a target of another kind, a missing reason, an inherited name — none)
  assert.equal(A.setupOf({ setup: { x: { target: "javascript:alert(1)", says: "s" } } }, "x"), null);
  assert.equal(A.setupOf({ setup: { x: { target: "setting:lower", says: "s" } } }, "x"), null);
  assert.equal(A.setupOf({ setup: {} }, "toString"), null);
  assert.equal(A.setupOf({ setup: SETUP }, "nope"), null);
  // (without the table: greyed as before, saying why)
  const g = plain(A.terminalOptions({ ...data, terminal: { here: false } })).flatMap((x) => x.items);
  assert.ok(g.every((i) => i.disabled && !i.value.startsWith("setup:")));
});
