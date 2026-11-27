// Chat's "Make it a project" on the portal's side (static/code.js chatHandoff): what it takes from the Chat frame, what it
// sends the portal, how it answers the frame and where it opens the Code tab. code.js runs here against a page of stubs.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import { STATIC, plain } from "./load.mjs";

const CHAT = "http://chat.devos-ade.localhost", CODE = "http://code.devos-ade.localhost";
const ID = "A".repeat(32);

const stub = () => { const o = { append() {}, before() {}, after() {}, addEventListener() {}, closest: () => o, replaceChildren() {}, setAttribute() {}, hidden: false, textContent: "" }; return o; };

function page({ here = true, fetchReply } = {}) {
  const listeners = [], shown = [], posted = [], fetches = [], frames = {};
  const chatWin = { postMessage: (m, o) => posted.push([m, o]) };
  const codeFrame = { src: "", hidden: false, contentWindow: {}, dataset: { app: "code" }, addEventListener() {} };
  frames.chat = { contentWindow: chatWin };
  frames.code = codeFrame;
  const ctx = vm.createContext({
    console, URL, JSON, Promise, Date, Math, Object, String, Boolean, Number, Array, RegExp, setTimeout, clearTimeout, WeakSet, Error, Blob: class {},
    APP_URLS: { chat: CHAT + "/", code: CODE + "/" }, appUrl: (t) => ({ chat: CHAT + "/", code: CODE + "/" })[t],
    $: stub, el: stub, PAGES: [], showTab: (t) => shown.push(t), copy() {}, toast() {}, api: async () => ({}),
    appFrame: (t) => frames[t],
    localStorage: { getItem: () => null, setItem() {} },
    document: {
      querySelector: (q) => (q === 'meta[name="bn-code"]' ? { content: JSON.stringify({ here, enabled: true }) }
        : q === '#frames iframe[data-app="chat"]' ? frames.chat : q === '#frames iframe[data-app="code"]' ? frames.code : null),
      querySelectorAll: () => [], addEventListener() {}, createElementNS: () => ({ setAttribute() {}, append() {} }),
    },
    window: { addEventListener: (t, f) => { if (t === "message") listeners.push(f); }, matchMedia: () => ({ matches: false }), bnMobile: null },
    fetch: async (url, init) => { fetches.push([url, init]); return fetchReply(url, init); },
  });
  ctx.window.window = ctx.window;
  vm.runInContext(fs.readFileSync(path.join(STATIC, "code.js"), "utf8"), ctx, { filename: "code.js" });
  const send = async (data, { origin = CHAT, source = chatWin } = {}) => {
    for (const f of listeners) await f({ origin, source, data });
  };
  return { send, shown, posted, fetches, codeFrame, chatWin };
}

const ok = (body, status = 200) => async () => ({ ok: status < 400, status, json: async () => body });
const msg = (extra = {}) => ({ type: "bn-chat-handoff", id: "abc123", title: "Trip", text: "You:\nhi", ...extra });

test("a chat from the Chat frame is deposited and the Code tab opens at its id", async () => {
  const p = page({ fetchReply: ok({ id: ID, expires_in: 600 }) });
  await p.send(msg());
  assert.equal(p.fetches.length, 1);
  const [url, init] = p.fetches[0];
  assert.equal(url, "/api/chat-handoff");
  assert.equal(init.method, "POST");
  assert.equal(init.headers["X-Requested-With"], "devos-ade");
  assert.deepEqual(JSON.parse(init.body), { title: "Trip", text: "You:\nhi" });
  assert.deepEqual(plain(p.posted), [[{ type: "bn-portal-chat-handoff", id: "abc123", ok: true }, CHAT]]);
  assert.deepEqual(plain(p.shown), ["code"]);
  assert.equal(p.codeFrame.src, `${CODE}/?handoff=${ID}`);
});

test("only the Chat tab's own frame, from Chat's origin, is heard", async () => {
  const p = page({ fetchReply: ok({ id: ID }) });
  await p.send(msg(), { origin: "http://evil.example" });
  await p.send(msg(), { source: {} });
  await p.send({ ...msg(), type: "bn-code-status" });
  await p.send(msg({ id: "bad id!" }));
  assert.equal(p.fetches.length, 0);
  assert.equal(p.posted.length, 0);
  assert.deepEqual(plain(p.shown), []);
});

test("a chat over the cap, or one the portal refuses as too big, opens the Code page's own explanation", async () => {
  let p = page({ fetchReply: ok({}) });
  await p.send(msg({ tooBig: true, text: "" }));
  assert.equal(p.fetches.length, 0);
  assert.equal(p.codeFrame.src, `${CODE}/?handoff=too-big`);
  assert.deepEqual(plain(p.posted[0][0]), { type: "bn-portal-chat-handoff", id: "abc123", ok: true, tooBig: true });
  p = page({ fetchReply: ok({}) });
  await p.send(msg({ text: "x".repeat(200001) }));
  assert.equal(p.fetches.length, 0);
  assert.equal(p.codeFrame.src, `${CODE}/?handoff=too-big`);
  p = page({ fetchReply: ok({ error: "too big", tooBig: true }, 413) });
  await p.send(msg());
  assert.equal(p.codeFrame.src, `${CODE}/?handoff=too-big`);
});

test("an empty chat, a refusal and a portal that does not answer are told to the frame, and nothing opens", async () => {
  let p = page({ fetchReply: ok({ id: ID }) });
  await p.send(msg({ text: "  \n" }));
  assert.match(p.posted[0][0].error, /nothing in this chat/);
  p = page({ fetchReply: ok({ error: "Too many hand-offs: again in 3 s." }, 429) });
  await p.send(msg());
  assert.equal(p.posted[0][0].ok, false);
  assert.match(p.posted[0][0].error, /Too many/);
  p = page({ fetchReply: ok({ id: "not an id" }) });
  await p.send(msg());
  assert.equal(p.posted[0][0].ok, false);
  p = page({ fetchReply: async () => { throw new Error("offline"); } });
  await p.send(msg());
  assert.match(p.posted[0][0].error, /did not answer/);
  assert.equal(p.codeFrame.src, "");
});

test("while the Code page is off here, nothing is deposited and the frame is told", async () => {
  const p = page({ here: false, fetchReply: ok({ id: ID }) });
  await p.send(msg());
  assert.equal(p.fetches.length, 0);
  assert.equal(p.posted[0][0].ok, false);
  assert.match(p.posted[0][0].error, /Code page is off/);
});

// --- (JON-1158) where the chat went: the Code page says the project, the Chat frame is told its name for its own id ---
const done = (extra = {}) => ({ type: "bn-code-handoff-done", handoff: ID, project: "Trip planner", ...extra });

test("the project a hand-off went to is told to the Chat frame, for its own id, once", async () => {
  const p = page({ fetchReply: ok({ id: ID }) });
  await p.send(msg());
  p.posted.length = 0;
  await p.send(done(), { origin: CODE, source: p.codeFrame.contentWindow });
  assert.deepEqual(plain(p.posted), [[{ type: "bn-portal-chat-filed", id: "abc123", project: "Trip planner" }, CHAT]]);
  await p.send(done({ project: "Again" }), { origin: CODE, source: p.codeFrame.contentWindow });
  assert.equal(p.posted.length, 1);
});

test("only the Code tab's own frame, for a hand-off this page made, with a name, is heard", async () => {
  const p = page({ fetchReply: ok({ id: ID }) });
  await p.send(msg());
  p.posted.length = 0;
  await p.send(done(), { origin: "http://evil.example", source: p.codeFrame.contentWindow });
  await p.send(done(), { origin: CODE, source: {} });
  await p.send(done(), { origin: CHAT, source: p.chatWin });
  await p.send(done({ handoff: "B".repeat(32) }), { origin: CODE, source: p.codeFrame.contentWindow });
  await p.send(done({ handoff: "bad" }), { origin: CODE, source: p.codeFrame.contentWindow });
  await p.send(done({ project: 7 }), { origin: CODE, source: p.codeFrame.contentWindow });
  assert.equal(p.posted.length, 0);
  await p.send(done({ project: " ‮\u0007 " }), { origin: CODE, source: p.codeFrame.contentWindow });
  assert.equal(p.posted.length, 0);   // (a name of nothing visible: not filed, and the hand-off is used up)
  await p.send(done(), { origin: CODE, source: p.codeFrame.contentWindow });
  assert.equal(p.posted.length, 0);
});

test("the name told is cleaned and capped", async () => {
  const p = page({ fetchReply: ok({ id: ID }) });
  await p.send(msg());
  p.posted.length = 0;
  await p.send(done({ project: "  Trip‮\n  planner " + "x".repeat(200) }), { origin: CODE, source: p.codeFrame.contentWindow });
  const told = p.posted[0][0].project;
  assert.ok(told.startsWith("Trip planner x") && told.length === 80, told);
});

test("a refused hand-off is never filed", async () => {
  const p = page({ fetchReply: ok({ error: "nope" }, 500) });
  await p.send(msg());
  p.posted.length = 0;
  await p.send(done(), { origin: CODE, source: p.codeFrame.contentWindow });
  assert.equal(p.posted.length, 0);
});
