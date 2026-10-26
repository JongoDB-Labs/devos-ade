// static/answers.js's pure parts: what each picker offers — the Terminal tab's (Claude Code on Bedrock, a shell, your
// AI subscriptions' tools, greyed with why when they cannot open here) and the Chat tab's (Open WebUI, Bedrock and
// OpenRouter models, your API keys next, the tools themselves, the subscriptions as Chat models greyed with the
// provider's reason) — the terminal's address with the pickers' words, and the saved choice read back.
import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { load, plain, source } from "./load.mjs";

const A = load("answers.js").bnAnswers._pure;
const tools = [
  { id: "claude", name: "Claude Code", provider: "Anthropic", plan: "your Claude plan", command: "claude-sub", installed: true, signed_in: "yes", kind_words: "Claude Max", chat_model: "no", chat_why: "Coming next." },
  { id: "codex", name: "Codex", provider: "OpenAI", plan: "your ChatGPT plan", command: "codex", installed: true, signed_in: "no", kind_words: "", chat_model: "no", chat_why: "Terms first." },
  { id: "copilot", name: "GitHub Copilot CLI", provider: "GitHub", plan: "your Copilot plan", command: "copilot", installed: true, signed_in: "unknown", kind_words: "", chat_model: "no", chat_why: "No." },
  { id: "cursor", name: "Cursor CLI", provider: "Cursor", plan: "your Cursor plan", command: "cursor-agent", installed: false, signed_in: "no", kind_words: "", chat_model: "no", chat_why: "No." },
  { id: "grok", name: "Grok Build", provider: "xAI", plan: "SuperGrok", command: "grok", installed: null, signed_in: "unknown", kind_words: "", chat_model: "no", chat_why: "No." },
];
const data = { terminal: { here: true }, basics: [{ id: "bedrock", name: "Claude Code (Bedrock)", command: "devos-claude" }, { id: "shell", name: "A shell", command: "bash" }],
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
// (the repository's table: catalog/setup-links.tsv here, /catalog in the image's jstest stage — portal/test.sh passes it.
// Never rows written out here, which drift from it: without the table, the tests that read it skip and say why.)
const TSV = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "..", "..", "catalog", "setup-links.tsv");
const parse = (text) => Object.fromEntries(text.split("\n").filter((l) => l && !l.startsWith("#")).map((l) => l.split("\t")).map(([r, target, where, says]) => [r, { target, where, says }]));
const SETUP = fs.existsSync(TSV) ? parse(fs.readFileSync(TSV, "utf8")) : null;
const TABLE = SETUP ? {} : { skip: `${TSV} is not here (portal/test.sh passes the repository's catalog; a plain docker build does not)` };

test("greyed items: each a choice that goes where it is turned on, saying where — none dead, none greyed while the table has its reason", TABLE, () => {
  const pm = [{ id: "plan-claude", tool: "claude", label: "Claude · your Claude plan", ok: false, why: "w", reason: "claude-plan-off" },
    { id: "plan-codex", tool: "codex", label: "Codex · ChatGPT", ok: false, why: "w", reason: "code-off" },
    { id: "plan-grok", tool: "grok", label: "Grok · x", ok: false, why: "w", reason: "chat-egress-off" },
    { id: "plan-copilot", tool: "copilot", label: "Copilot · x", ok: false, why: "w", reason: "tool-left-out" }];
  const all = [];
  for (const term of [{ here: true }, { here: false, reason: "terminal-off" }, { here: false, reason: "terminal-remote-off" }]) {
    const d = { ...data, terminal: term, setup: SETUP, plan_models: pm, openrouter: false, explabs: false, models: data.models.filter((m) => m.provider !== "OpenRouter") };
    all.push(...plain(A.terminalOptions(d)).flatMap((g) => g.items), ...plain(A.chatOptions(d)).flatMap((g) => g.items));
  }
  const greyed = all.filter((i) => i.disabled);
  // (left greyed: what no setting turns on — your own keys, next; a tool that is no Chat model)
  assert.ok(greyed.every((i) => i.value === "keys" || i.value.startsWith("as-model:")), JSON.stringify(greyed.map((i) => i.value)));
  const setups = all.filter((i) => i.value.startsWith("setup:"));
  const reasons = new Set(setups.map((i) => i.value.split(":")[1]));
  assert.deepEqual([...reasons].sort(), ["chat-egress-off", "claude-plan-off", "code-off", "explabs-off", "openrouter-off", "terminal-off", "terminal-remote-off", "tool-left-out"]);
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
  assert.equal(A.setupOf({ setup: { x: { target: "javascript:alert(1)", where: "Settings", says: "s" } } }, "x"), null);
  assert.equal(A.setupOf({ setup: { x: { target: "setting:lower", where: "Settings", says: "s" } } }, "x"), null);
  assert.equal(A.setupOf({ setup: {} }, "toString"), null);
  assert.equal(A.setupOf({ setup: { x: { target: "setting:CODE_MODELS", where: "Settings", says: "s" } } }, "nope"), null);
  // (without the table: greyed as before, saying why)
  const g = plain(A.terminalOptions({ ...data, terminal: { here: false } })).flatMap((x) => x.items);
  assert.ok(g.every((i) => i.disabled && !i.value.startsWith("setup:")));
});

test("a menu's change never acts: every choice — a greyed item, a sign-in for Chat, a model, a tool — acts only from the button beside the menu", async () => {
  const { source } = await import("./load.mjs");
  const js = source("answers.js");
  // (the change listener's body, to its own closing: a one-line one or a block)
  const handler = (sel) => /^([\s\S]*?)\}\);/.exec(js.split(`${sel}.addEventListener("change", () => {`)[1])[1];
  for (const sel of ["tSelect", "cSelect"]) {
    const h = handler(sel);
    assert.ok(!/goSetup\(|goHash\(|location\.hash|bnSubsChatSignin|launch\(|openTool\(|useChat\(|\.src\s*=|save\(\)/.test(h), `${sel}'s change acts: ${h}`);
  }
  assert.match(js.split('cGo.addEventListener("click", () => {')[1].split("\n  });")[0], /useChat\(v\)/);
  // (the folder a tool works in: kept, and the tool starts again there only from its button)
  const f = handler("cFolder");
  assert.ok(!/goSetup\(|goHash\(|launch\(|openTool\(|useChat\(|\.src\s*=/.test(f), `cFolder's change acts: ${f}`);
  assert.match(f, /cReopen\.hidden = false/);
  assert.match(js.split('cReopen.addEventListener("click", () => {')[1].split("\n  });")[0], /openTool\(id\)/);
  // (the buttons do)
  assert.match(js.split('tOpen.addEventListener("click", () => {')[1].split("\n  });")[0], /goSetup\(tSelect\.value\)/);
  assert.match(js.split('cGo.addEventListener("click", () => {')[1].split("\n  });")[0], /goSetup\(v\)[\s\S]*bnSubsChatSignin/);
});

test("Settings on arrival: a Chat sign-in asked for takes the focus; a row of the page's own never focuses a switch inside it", async () => {
  const { source } = await import("./load.mjs");
  const go = source("settings.js").split("function goTo(place) {")[1].split("\n  }\n")[0];
  // (taken by the arrival it was asked for alone: Your AI subscriptions, nothing inside it named)
  assert.match(go, /const chat = chatAsk\.take\(key === "\+subscriptions" && !inner\);/);
  assert.match(go, /const sw = !signin && \(inner \|\| !key\.startsWith\("\+"\)\) \?/);
  assert.match(go, /\(signin \|\| sw \|\| at\)\.focus/);
  assert.doesNotMatch(source("settings.js"), /chatSigninWanted|chatSignin\b/);
});

// chatAsk, as settings.js has it, in a context of its own: a window and a clock of the test's
function chatAsk() {
  const js = source("settings.js");
  const body = js.split("// chatAsk:begin")[1].split("// chatAsk:end")[0];
  const ctx = vm.createContext({ window: {}, Date: { now: () => ctx.now }, now: 1000 });
  vm.runInContext(`${body}; this.chatAsk = chatAsk;`, ctx);
  return ctx;
}

test("a Chat sign-in asked for goes to its own arrival alone: Sign in for Chat, back, the Claude-plan item — the switch, not the sign-in", () => {
  const c = chatAsk();
  const { chatAsk: ask, window } = c;
  // Sign in for Chat… (Codex): answers.js asks, Settings draws the row (its command shown), goTo takes it — once
  window.bnSubsChatSignin = "codex";
  assert.equal(ask.shown(), "codex");
  assert.equal(ask.take(true), "codex");
  assert.equal(window.bnSubsChatSignin, "");
  c.now += 1000;
  assert.equal(ask.shown(), "codex", "a redraw a moment later still shows its command");
  assert.equal(ask.take(true), "", "a second arrival does not take it again");
  // (taken, then back to Chat: leaving Settings drops it — settings.js's bn:tab)
  window.bnSubsChatSignin = "grok";
  assert.equal(ask.take(true), "grok");
  ask.drop(); window.bnSubsChatSignin = "";
  // the Claude-plan item at once (within the few seconds): #settings/CODE_CLAUDE_PLAN — a row inside Your AI
  // subscriptions: goTo's inner is set, so nothing is taken and nothing shows; its switch takes the focus
  assert.equal(ask.shown(), "");
  assert.equal(ask.take(false), "");
  // (even were it still asked for: an arrival with a row inside named ignores it and drops it)
  window.bnSubsChatSignin = "codex";
  assert.equal(ask.take(false), "");
  assert.equal(ask.shown(), "");
  assert.equal(window.bnSubsChatSignin, "");
  // the window starts when goTo takes it, not when the row is drawn
  window.bnSubsChatSignin = "codex";
  c.now += 60000;
  assert.equal(ask.shown(), "codex");
  assert.equal(ask.take(true), "codex");
  c.now += 4900;
  assert.equal(ask.shown(), "codex");
  c.now += 200;
  assert.equal(ask.shown(), "", "a few seconds from goTo, then gone");
  // (a tool name that is not one: nothing)
  window.bnSubsChatSignin = "Codex<x>";
  assert.equal(ask.shown(), "");
  assert.equal(ask.take(true), "");
});

test("leaving Settings drops a Chat sign-in asked for", () => {
  const js = source("settings.js");
  const tab = js.split('document.addEventListener("bn:tab", (e) => {')[1].split("\n  });")[0];
  assert.match(tab, /if \(e\.detail === "settings"\) load\(\)\.then\(placeFromAddress\);\s*else \{ chatAsk\.drop\(\); window\.bnSubsChatSignin = "";/);
});

test("Your AI subscriptions: each tool's Sign out and Copy, and each sandbox's Check again, has a name of its own (the tool's, and which sign-in)", () => {
  const js = source("settings.js");
  const row = js.split("function subscriptionsRow(r) {")[1].split("\n  function ")[0];
  const names = [...row.matchAll(/"aria-label": `([^`]+)`|setAttribute\("aria-label", name\)|copyButton\(cmd, `([^`]+)`\)|`(Check again: [^`]+)`|"(Check again: [^"]+)"/g)]
    .map((m) => m[1] || m[2] || m[3] || m[4]).filter(Boolean);
  for (const want of ["Sign out: ${t.name} in the sandbox (terminal and Code page)", "Sign out: ${t.name} for Chat",
    "Check again: every tool in the sandbox (terminal and Code page)", "Check again: every tool for Chat",
    "Copy ${t.name}'s Chat sign-in command"]) {
    assert.ok(names.includes(want), `${want} — not in ${JSON.stringify(names)}`);
  }
  // (every button of a tool's row named: no bare "Sign out" or "Check again" without its tool)
  assert.match(row, /const checkButton = \(action, title, body, name\) => \{[\s\S]*?if \(name\) b\.setAttribute\("aria-label", name\);/);
  assert.equal([...row.matchAll(/checkButton\("subscriptions-check(-chat)?",/g)].length, 2);
  assert.equal([...row.matchAll(/text: "Sign out", "data-act": "subscriptions-signout(-chat)?",\s*"aria-label": `Sign out: \$\{t\.name\}/g)].length, 2);
  assert.match(js, /function copyButton\(cmd, name\) \{[\s\S]*?if \(name\) b\.setAttribute\("aria-label", name\);/);
  // (and the row's other two Copy buttons: the Claude plan's command, ./stack subscriptions — none bare)
  assert.match(row, /cliLine\(pk, "On the computer running DevOS ADE, in a terminal: ", "Copy the command for Use my Claude plan in the Code page and Chat"\)/);
  assert.match(row, /copyButton\("\.\/stack subscriptions", "Copy the command \.\/stack subscriptions"\)/);
  assert.equal([...row.matchAll(/copyButton\(([^)]*)\)/g)].filter((m) => !m[1].includes(",")).length, 0, "a Copy without a name");
  assert.match(js, /function cliLine\(k, lead, name\) \{[\s\S]*?copyButton\(cmd, name\)\);/);
});

test("the button beside a menu is named for where it goes — Go to Settings › …; Open, with no name of its own, otherwise", TABLE, () => {
  const d = { ...data, setup: SETUP };
  assert.equal(A.setupOf(d, "claude-plan-off").where, SETUP["claude-plan-off"].where);
  assert.equal(A.goLabelOf(d, "setup:claude-plan-off:claude"), "Go to Settings");
  assert.equal(A.goNameOf(d, "setup:claude-plan-off:claude"), "Go to Settings › Models & providers › Claude Code › Use my Claude plan");
  assert.equal(A.goNameOf(d, "signin:codex"), "Go to Settings › Models & providers › Your AI subscriptions › Chat");
  for (const r of Object.keys(SETUP)) {
    const v = `setup:${r}:codex`, label = A.goLabelOf(d, v), name = A.goNameOf(d, v);
    assert.ok(label === "Go to Settings" || label === "Open it to sign in", `${r}: ${label}`);
    assert.equal(name, `${label === "Go to Settings" ? "Go to" : "Open it to sign in:"} ${SETUP[r].where}`, r);
    assert.ok(SETUP[r].where.startsWith("Settings ›") || label === "Open it to sign in", `${r}: ${SETUP[r].where}`);
  }
  // (any other choice: its own words, no name; a table without where: the words name it)
  for (const v of ["bedrock", "codex", "model:x", "tool:grok", "owui", "", "setup:nope:codex"]) assert.equal(A.goNameOf(d, v), "", v);
  assert.equal(A.goLabelOf(d, "model:x"), "");
  assert.equal(A.goNameOf({ setup: { "claude-plan-off": { target: "setting:CODE_CLAUDE_PLAN", says: "s" } } }, "setup:claude-plan-off:claude"), "");
});

test("the Terminal's button: its words and its accessible name follow the choice — and the tab shown again sets both", TABLE, () => {
  const js = source("answers.js");
  const body = js.split("const tLabel = () => {")[1].split("\n  };")[0];
  // tLabel as answers.js has it, on a button of the test's: an aria-label wins over the words for a screen reader
  const btn = { textContent: "", attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, removeAttribute(k) { delete this.attrs[k]; } };
  const sel = { value: "" };
  const d = { ...data, setup: SETUP };
  const ctx = vm.createContext({ tOpen: btn, tSelect: sel, goLabel: (v) => A.goLabelOf(d, v), goName: (v) => A.goNameOf(d, v) });
  vm.runInContext(`this.tLabel = () => {${body}\n};`, ctx);
  const accName = () => btn.attrs["aria-label"] || btn.textContent;
  sel.value = "setup:tool-left-out:codex";
  ctx.tLabel();
  assert.equal(btn.textContent, "Go to Settings");
  assert.equal(accName(), `Go to ${SETUP["tool-left-out"].where}`);
  // a tool that opens: "Open", its name the words again — never the greyed item's left behind
  sel.value = "codex";
  ctx.tLabel();
  assert.equal(btn.textContent, "Open");
  assert.equal(accName(), "Open");
  // the tab shown again (onTab) sets both through tLabel, not the words alone
  const onTab = js.split("async function onTab(tab) {")[1].split("\n  }\n")[0];
  assert.match(onTab, /fill\(tSelect, terminalOptions\(d\), tLast\);\s*tLabel\(\);/);
  assert.doesNotMatch(js, /tOpen\.textContent = goLabel/);
  // Chat's button: the same name from goName
  assert.match(js.split('cSelect.addEventListener("change", () => {')[1].split("\n  });")[0], /cGo\.setAttribute\("aria-label", goName\(v\) \|\| go\)/);
});

test("chat picker: Experiential Labs' models as a group next to OpenRouter's; without its key, the choice that goes where it goes in", TABLE, () => {
  const on = plain(A.chatOptions({ ...data, setup: SETUP, explabs: true,
    models: [...data.models, { id: "xl/qwen3.8-27b", label: "qwen3.8-27b", provider: "Experiential Labs" }] }));
  const xl = on.find((x) => x.label === "Experiential Labs");
  assert.deepEqual(xl.items.map((i) => [i.value, i.disabled]), [["model:xl/qwen3.8-27b", false]]);
  assert.deepEqual(on.map((x) => x.label).slice(1, 4), ["Bedrock", "OpenRouter", "Experiential Labs"]);
  const off = plain(A.chatOptions({ ...data, setup: SETUP, explabs: false })).find((x) => x.label === "Experiential Labs");
  assert.equal(off.items.length, 1);
  const it = off.items[0];
  assert.deepEqual([it.value, it.disabled, it.title], ["setup:explabs-off:", false, SETUP["explabs-off"].says]);
  assert.equal(it.label, `Experiential Labs models — ${SETUP["explabs-off"].says}`);
  assert.match(it.label, /add it in Settings › Models & providers › Experiential Labs/);
  // it goes to Settings at the key's row, its button named for it
  assert.deepEqual(plain(A.setupPlace(A.setupOf({ setup: SETUP }, "explabs-off"), "")), { hash: "#settings/EXPLABS_API_KEY" });
  assert.equal(A.goLabelOf({ setup: SETUP }, it.value), "Go to Settings");
  // it only points to Settings: no address of the gateway, and never a saved choice (a reload is back on Open WebUI)
  assert.doesNotMatch(JSON.stringify(off), /experientiallabs|https?:|xl\//);
  assert.equal(A.parseSaved(JSON.stringify({ chat: it.value })).chat, "owui");
  // an older portal (no explabs field): nothing at all
  assert.ok(!plain(A.chatOptions({ ...data, setup: SETUP })).some((x) => x.label === "Experiential Labs"));
});

test("a phone's closed Chat menu shows the choice's name only; the menu lists each in full", () => {
  assert.equal(A.shortLabel("Open WebUI — its own model menu"), "Open WebUI");
  assert.equal(A.shortLabel("Claude Code · your Claude plan — Sign in for Chat…"), "Claude Code");
  assert.equal(A.shortLabel("Claude Haiku 5.5"), "Claude Haiku 5.5");
  assert.equal(A.shortLabel("— odd"), "— odd", "nothing before the separator: the whole");
  assert.equal(A.shortLabel(""), "");
  assert.equal(A.shortLabel(null), "");
  assert.equal(A.shortLabel("x".repeat(100)).length, 60);
});
