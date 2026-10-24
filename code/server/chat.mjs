// Your subscriptions as Chat models: an OpenAI-compatible endpoint (GET /v1/models, POST /v1/chat/completions) that
// Open WebUI uses as a connection of its own — through the main Caddy's internal site (caddy:8098, code-on.caddy:
// this container shares no network with Open WebUI), with a key only Open WebUI has (CODE_CHAT_KEY). Each signed-in subscription is a model there (plan-claude, plan-codex …),
// answering in the same chat pane; each answer is the provider's own agent, signed in with its own login, through its
// interface for other apps — the Claude Agent SDK (Claude Code, `--tools=` : no tool), Codex's app server, ACP (Copilot,
// Grok; not Cursor: it has no switch that turns its tools off) — in Chat's own sandbox (subs-chat: the terminal's image and home, no workspace, no project folder),
// in an empty folder of the conversation's own, each tool started with its tools switched off (bn-coded's AGENTS.chat).
// No tool in Chat, whatever a tool's switches let through: every permission request is refused, and at the first sign
// of a tool call (ACP's tool_call or a permission request, a Codex item that is not an answer) the agent's process is
// killed there and then (with what it started), nothing it says after reaches the answer — the answer says so, and
// that agent session is dropped (the chat goes on in a new one). A tool that runs a tool by itself before any sign
// reaches here is not stopped by this: the switches that turn tools off are what keeps them from running. Nothing of a login passes here; what comes back is
// the sandbox's text, sent on as plain text.
//
// A conversation is one of the agent's own sessions, taken up again each turn (its context, compaction and limits are the
// provider's): a conversation is known by its whole history so far — your prompts and its answers, as Open WebUI sends
// them back (a hash: conversations.json in this container's volume) — so the next turn of the same chat finds it, and
// two chats that only share their prompts never share a session; an edited or regenerated message starts a new session
// with the conversation so far as its preface. Open WebUI's own extras (titles, tags, follow-ups) go to its task model,
// never here.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { HARNESSES, chatModelId, toolOfChatModel } from './agents/tools.mjs';
import { AcpAgent, NotSignedIn, UnsafeMode } from './agents/acp.mjs';
import { CodexAgent } from './agents/codex.mjs';
import { said } from './agents/jsonrpc.mjs';
import { quoted, defang, defangMentions } from './agents/quote.mjs';
import { STATE_DIR } from './githosts.mjs';
import { IMAGE_TYPES } from './protocol.mjs';

export const CHAT_PORT = 8096;
const MAX_BODY = 24 << 20;           // a request: the whole conversation (and its images) each time
const MAX_PROMPT = 200000;           // the new message's text
const MAX_PREFACE = 60000;           // the conversation so far, for a new session: its last 60,000 characters
const MAX_SYSTEM = 8000;             // the chat app's instructions (its leading system message)
const MAX_ANSWER = 2 << 20;          // what is sent back of one answer
const MAX_IMAGES = 4, MAX_IMAGE_BYTES = 5 << 20;
const IDLE_MS = 10 * 60000;          // an agent kept for the next turn of its conversation this long
const KEEP_RUNNING = 4;              // agents kept at once (each a process in the sandbox)
const MAX_RECORDS = 500;
// What Claude is told in a Chat conversation (its own system prompt, recorded with the conversation)
export const CHAT_SYSTEM = 'You are Claude, made by Anthropic, answering in a chat app (Open WebUI) on the user\'s own Claude plan. Reply to the conversation in Markdown. You have no tools, files or web access here.';

const obj = (v) => (v !== null && typeof v === 'object' && !Array.isArray(v) ? v : {});
// Open WebUI's own additions to an earlier answer: its reasoning and tool blocks (<details …>), and DevOS ADE's cost line
const stripAnswer = (t) => t.replace(/<details\b[^>]*>[\s\S]*?<\/details>/gi, '').replace(/\n*\*(?:≈ |free · |on your )[^*\n]*\*\s*$/u, '').trim();

/** messages -> {system, turns: [{role, text}], prompt, images} or {error} (the last message must be yours) */
export function readMessages(list) {
  if (!Array.isArray(list) || !list.length || list.length > 2000) return { error: 'messages: a list of 1 to 2,000' };
  const turns = [];
  const system = [];
  let images = [];
  for (const m of list) {
    const o = obj(m);
    const role = o.role;
    let text = '';
    const imgs = [];
    if (typeof o.content === 'string') text = o.content;
    else if (Array.isArray(o.content)) {
      for (const p of o.content.slice(0, 100)) {
        const q = obj(p);
        if (q.type === 'text' && typeof q.text === 'string') text += (text ? '\n' : '') + q.text;
        else if (q.type === 'image_url') {
          const url = typeof q.image_url === 'string' ? q.image_url : obj(q.image_url).url;
          const mm = typeof url === 'string' ? /^data:(image\/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+/]+={0,2})$/.exec(url) : null;
          if (mm && IMAGE_TYPES.includes(mm[1]) && mm[2].length * 3 / 4 <= MAX_IMAGE_BYTES) imgs.push({ media_type: mm[1], data: mm[2] });
        }
      }
    }
    // (the chat app's instructions: its system or developer messages before the conversation's first turn only — one
    // later in the list is not the app's, and is left out; capped)
    if (role === 'system' || role === 'developer') { if (text && !turns.length) system.push(text); continue; }
    if (role !== 'user' && role !== 'assistant') continue;   // (tool messages: there are no tools here)
    turns.push({ role, text: role === 'assistant' ? stripAnswer(text) : text });
    if (role === 'user') images = imgs;
  }
  const last = turns[turns.length - 1];
  if (!last || last.role !== 'user' || !last.text.trim()) return { error: 'the last message must be yours, with some text' };
  if (last.text.length > MAX_PROMPT) return { error: 'that message is too long' };
  const sys = system.join('\n\n');
  return { system: sys.length > MAX_SYSTEM ? `${sys.slice(0, MAX_SYSTEM)}… (more of the chat app's instructions not passed on)` : sys, turns,
    prompt: last.text, images: images.slice(0, MAX_IMAGES) };
}

// the key of a conversation as far as its sessions go: the tool and its turns so far — who said each, and what
// (whitespace kept apart; an answer as Open WebUI sends it back: stripAnswer)
export const convKey = (tool, turns) => crypto.createHash('sha256')
  .update(JSON.stringify([tool, ...turns.map((t) => [t.role === 'assistant' ? 'a' : 'u', String(t.text).replace(/\s+/g, ' ').trim()])])).digest('hex').slice(0, 40);

// firstPrompt(system, turns, prompt) -> what a new session's first prompt says: the chat app's instructions (Open WebUI's
// system prompt: yours, as instructions — its tag-like delimiters defanged all the same), the conversation so far
// quoted for context only (agents/quote.mjs: its last MAX_PREFACE characters), then your new message
export function firstPrompt(system, turns, prompt) {
  const q = quoted(turns.slice(0, -1).map((t) => ({ who: t.role, text: t.text })), { max: MAX_PREFACE });
  const head = system ? `Instructions from the chat app:\n${defang(system)}` : '';
  if (!q && !head) return prompt;
  return [head, q ?? 'The user\'s message:', prompt].filter(Boolean).join('\n\n');
}

/** The record of which conversation is which session (conversations.json, mode 600, the most recent MAX_RECORDS). */
export class ChatStore {
  constructor({ file = path.join(STATE_DIR, 'chat', 'conversations.json'), now = () => Date.now() } = {}) {
    this.file = file; this.now = now; this.map = null;
  }
  load() {
    if (this.map) return this.map;
    this.map = new Map();
    let rows = [];
    try { rows = JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { rows = []; }
    for (const r of Array.isArray(rows) ? rows : []) {
      if (r && /^[0-9a-f]{40}$/.test(r.key) && Object.hasOwn(HARNESSES, r.tool) && /^[0-9a-f]{32}$/.test(r.folder) && (r.ref === null || /^[\x21-\x7e]{1,200}$/.test(r.ref))) {
        this.map.set(r.key, { key: r.key, tool: r.tool, folder: r.folder, ref: r.ref, at: Number(r.at) || 0 });
      }
    }
    return this.map;
  }
  get(key) { return this.load().get(key) ?? null; }
  // a conversation's session after a turn: under its new key (the old one goes: a regenerate starts anew); rec null: the
  // session is forgotten (the next turn starts a new one, with the conversation so far quoted)
  move(oldKey, rec) {
    const m = this.load();
    if (oldKey) m.delete(oldKey);
    if (rec) m.set(rec.key, { ...rec, at: this.now() });
    while (m.size > MAX_RECORDS) m.delete([...m.values()].sort((a, b) => a.at - b.at)[0].key);
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
      const tmp = `${this.file}.${crypto.randomBytes(6).toString('hex')}`;
      fs.writeFileSync(tmp, JSON.stringify([...m.values()]), { mode: 0o600, flag: 'wx' });
      fs.renameSync(tmp, this.file);
    } catch { /* best effort: the conversation then starts a new session next time */ }
  }
}

// sse(res, chunk): one Server-Sent Event of the stream
const sse = (res, o) => res.write(`data: ${JSON.stringify(o)}\n\n`);

/**
 * createChatServer({key, status, planAllowed, egressOff, spawnAgent, query, spawn, store, log}) -> http.Server
 *   egressOff: TERMINAL_EGRESS=off — the sandbox has no internet: no Chat model then (Chat's sandbox has no network
 *   either: compose.code-offline.yaml), each refused with why. With TERMINAL_EGRESS=host Chat's sandbox goes out through
 *   an egress proxy of its own (compose.code-egress.yaml): its models answer as with the proxy's way
 *   status() -> {tools: {id: {installed, signed}}} (agents/status.mjs)
 *   spawnAgent({tool, mode: 'chat', chat}) -> a process (spawn-client's sandboxAgent)
 *   query: the Agent SDK's query; spawn: its spawnClaudeCodeProcess (sandboxProcess, with {plan, chat})
 */
export const EGRESS_OFF = 'Your subscriptions are not Chat models while the sandbox has no internet (Settings › Claude Code › Sandbox internet access: Off): they could not reach their providers.';
export function createChatServer({ key, status, planAllowed = false, egressOff = false, spawnAgent, query, spawn, store = new ChatStore(), log = () => {},
  clientVersion = '0', sandboxChatDir = process.env.BN_SANDBOX_CHAT_DIR || '/home/claude/.bn-chat' }) {
  if (!/^[0-9a-f]{32,}$/.test(key || '')) throw new Error('CODE_CHAT_KEY missing or weak (32+ hex characters)');
  const want = Buffer.from(`Bearer ${key}`);
  const authed = (req) => {
    const got = Buffer.from(String(req.headers.authorization || ''));
    return got.length === want.length && crypto.timingSafeEqual(got, want);
  };
  const running = new Map();   // folder -> {agent, tool, busy, timer, at}

  const send = (res, code, body) => {
    res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(body));
  };
  const fail = (res, code, message) => send(res, code, { error: { message, type: code >= 500 ? 'server_error' : 'invalid_request_error' } });

  // which models Open WebUI lists: the subscriptions whose tool is here and says it is signed in (Copilot cannot say:
  // listed while it is there); Claude only while Settings' switch is on
  async function models() {
    if (egressOff) return [];
    const st = await status();
    const out = [];
    for (const h of Object.values(HARNESSES)) {
      const t = st?.tools?.[h.id];
      if (h.noChat || !t?.installed || t.signed === 'no') continue;
      if (h.id === 'claude' && (planAllowed !== true || t.signed !== 'yes')) continue;
      out.push({ id: chatModelId(h.id), object: 'model', created: 0, owned_by: h.plan, name: `${h.name} · ${h.plan}` });
    }
    return out;
  }

  function release(folder) {
    const r = running.get(folder);
    if (!r) return;
    running.delete(folder);
    clearTimeout(r.timer);
    try { r.agent.close(); } catch { /* gone */ }
  }
  function keep(folder, r) {
    clearTimeout(r.timer);
    r.timer = setTimeout(() => release(folder), IDLE_MS);
    r.timer.unref?.();
  }
  // room for one more agent: the least recently used idle one goes; none idle: refused
  function room() {
    if (running.size < KEEP_RUNNING) return true;
    const idle = [...running.entries()].filter(([, r]) => !r.busy).sort((a, b) => a[1].at - b[1].at);
    if (!idle.length) return false;
    release(idle[0][0]);
    return true;
  }

  // one turn with an ACP or Codex agent: kept running for the conversation's next turn
  async function agentTurn({ tool, folder, ref, text, images, out, signal }) {
    let r = running.get(folder);
    if (r?.busy) throw Object.assign(new Error('this conversation is still answering its last message'), { status: 409 });
    if (!r) {
      if (!room()) throw Object.assign(new Error('too many conversations with your subscriptions are answering at once: try again in a moment'), { status: 503 });
      const proc = spawnAgent({ tool, mode: 'chat', chat: folder }, { onStderr: (s) => log(`chat ${tool} stderr: ${said(s, 200)}`) });
      const opts = { tool, chat: true, clientVersion, log: (m) => log(`chat ${tool}: ${m}`), onEvent: (ev) => r?.onEvent?.(ev) };
      const agent = HARNESSES[tool].kind === 'codex' ? new CodexAgent(proc, opts) : new AcpAgent(proc, opts);
      r = { agent, tool, busy: true, at: Date.now(), timer: null, ref: null };
      running.set(folder, r);
      try {
        await agent.init();
        const o = await agent.open({ cwd: `${sandboxChatDir}/${folder}`, resume: ref });
        r.ref = o.ref;
        r.resumed = o.resumed;
        await agent.chatMode();
      } catch (e) { release(folder); throw e; }
      agent.closed.then(() => { if (running.get(folder) === r) { running.delete(folder); clearTimeout(r.timer); } });
    }
    r.busy = true; r.at = Date.now();
    let streamed = false;
    r.onEvent = (ev) => {
      if (r.agent.toolTried) return;   // (nothing after a tool's first sign: the agent is being killed)
      if (ev.type === 'delta') { streamed = true; out.text(ev.text); } else if (ev.type === 'thinking_delta') out.thought(ev.text);
      else if (ev.type === 'text') { if (!streamed) out.text(ev.text); streamed = false; }
    };
    const abort = () => r.agent.cancel();
    signal.addEventListener('abort', abort, { once: true });
    try {
      const res = await r.agent.prompt(text, images);
      // a tool reached for (and stopped): this session is not used again — whatever the tool did or saw stays out of
      // the conversation's next turns, which start a new session
      if (res.tried) release(folder);
      return { ref: r.ref, usage: res.usage, stop: res.stop, error: res.error, tried: res.tried ?? null, fresh: Boolean(ref) && !r.resumed };
    } finally {
      signal.removeEventListener('abort', abort);
      r.busy = false; r.onEvent = null;
      if (running.get(folder) === r) keep(folder, r);
    }
  }

  // one turn with Claude on your plan: the Agent SDK, Claude Code in the sandbox in the conversation's folder, no tool
  async function claudeTurn({ folder, ref, text, images, out, signal }) {
    const abortController = new AbortController();
    signal.addEventListener('abort', () => abortController.abort(), { once: true });
    const content = images.length ? [...images.map((im) => ({ type: 'image', source: { type: 'base64', media_type: im.media_type, data: im.data } })), { type: 'text', text }] : text;
    async function* input() {
      yield { type: 'user', message: { role: 'user', content }, parent_tool_use_id: null, session_id: '', origin: { kind: 'human' } };
    }
    const options = {
      pathToClaudeCodeExecutable: '/usr/local/bin/claude',
      spawnClaudeCodeProcess: (o) => spawn(o, { plan: true, chat: folder, onStderr: (s) => log(`chat claude stderr: ${said(s, 200)}`) }),
      env: {}, cwd: `${sandboxChatDir}/${folder}`,
      systemPrompt: { type: 'custom', prompt: CHAT_SYSTEM, snapshot: true },
      tools: [], settingSources: [], strictMcpConfig: true, includePartialMessages: true,
      permissionMode: 'default', canUseTool: async () => ({ behavior: 'deny', message: 'There are no tools in this chat.' }),
      abortController,
      ...(ref ? { resume: ref } : {}),
    };
    let sessionId = ref, usage = null, streamed = false, error = null;
    for await (const m of query({ prompt: input(), options })) {
      if (m?.type === 'system' && m.subtype === 'init' && typeof m.session_id === 'string') sessionId = m.session_id;
      else if (m?.type === 'stream_event') {
        const d = m.event?.type === 'content_block_delta' ? m.event.delta : null;
        if (d?.type === 'text_delta' && typeof d.text === 'string') { streamed = true; out.text(d.text); } else if (d?.type === 'thinking_delta' && typeof d.thinking === 'string') out.thought(d.thinking);
      } else if (m?.type === 'assistant' && !streamed) {
        for (const b of Array.isArray(m.message?.content) ? m.message.content : []) if (b?.type === 'text' && typeof b.text === 'string') out.text(b.text);
      } else if (m?.type === 'assistant') streamed = false;
      else if (m?.type === 'rate_limit_event' && m.rate_limit_info?.status === 'rejected') error = 'your Claude plan\'s usage limit is reached';
      else if (m?.type === 'result') {
        const u = obj(m.usage);
        usage = { input_tokens: (u.input_tokens | 0) + (u.cache_creation_input_tokens | 0), output_tokens: u.output_tokens | 0, cache_read_input_tokens: u.cache_read_input_tokens | 0 };
        if (m.is_error === true) error = error || (typeof m.result === 'string' ? said(m.result, 300) : 'Claude Code reported an error');
      }
    }
    return { ref: typeof sessionId === 'string' && /^[0-9a-f-]{36}$/.test(sessionId) ? sessionId : null, usage, stop: error ? 'error' : 'end_turn', error };
  }

  async function completions(req, res, body) {
    const tool = toolOfChatModel(body.model);
    if (!tool) return fail(res, 404, 'no such model here');
    if (egressOff) return fail(res, 409, EGRESS_OFF);
    const st = await status();
    const t = st?.tools?.[tool];
    const h = HARNESSES[tool];
    if (tool === 'claude' && planAllowed !== true) return fail(res, 403, 'Claude on your plan is off: Settings › Claude Code › Your AI subscriptions has the switch');
    if (!t?.installed) return fail(res, 404, `${h.name} is not in the sandbox (Settings › Claude Code › More › Tools in the sandbox)`);
    if (t.signed === 'no') return fail(res, 409, `${h.name} is not signed in: open the Terminal tab (Open › ${h.name}) and sign in with its own sign-in, then ask again`);
    const msgs = readMessages(body.messages);
    if (msgs.error) return fail(res, 400, msgs.error);
    const before = msgs.turns.slice(0, -1);
    const oldKey = convKey(tool, before);
    const rec = before.length ? store.get(oldKey) : null;
    const folder = rec && rec.tool === tool ? rec.folder : crypto.randomBytes(16).toString('hex');
    const ref = rec && rec.tool === tool ? rec.ref : null;
    // a new session: the conversation so far (quoted) and the chat app's instructions before your message; an @ that
    // would attach a file (@~/.codex/auth.json …) shown as ＠ in all of it — pasted text is not yours to mean it
    const text = defangMentions(rec ? msgs.prompt : firstPrompt(msgs.system, msgs.turns, msgs.prompt));
    const stream = body.stream === true;
    const id = `chatcmpl-${crypto.randomBytes(12).toString('hex')}`, created = Math.floor(Date.now() / 1000);
    let answer = '', thinking = '', sent = 0, started = false, spoken = '';
    const head = () => {
      if (started || !stream) return;
      started = true;
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', 'x-accel-buffering': 'no' });
      sse(res, { id, object: 'chat.completion.chunk', created, model: body.model, choices: [{ index: 0, delta: { role: 'assistant', content: '' }, finish_reason: null }] });
    };
    const out = {
      text: (s) => {
        if (typeof s !== 'string' || !s || sent >= MAX_ANSWER) return;
        const piece = s.slice(0, MAX_ANSWER - sent);
        sent += piece.length;
        spoken += piece;
        if (stream) { head(); sse(res, { id, object: 'chat.completion.chunk', created, model: body.model, choices: [{ index: 0, delta: { content: piece }, finish_reason: null }] }); } else answer += piece;
      },
      thought: (s) => {
        if (typeof s !== 'string' || !s || sent >= MAX_ANSWER) return;
        sent += s.length;
        if (stream) { head(); sse(res, { id, object: 'chat.completion.chunk', created, model: body.model, choices: [{ index: 0, delta: { reasoning_content: s }, finish_reason: null }] }); } else thinking += s;
      },
    };
    const ac = new AbortController();
    res.on('close', () => { if (!res.writableFinished) ac.abort(); });
    let r;
    try {
      r = tool === 'claude' ? await claudeTurn({ folder, ref, text, images: msgs.images, out, signal: ac.signal })
        : await agentTurn({ tool, folder, ref, text, images: msgs.images, out, signal: ac.signal });
    } catch (e) {
      const msg = e instanceof NotSignedIn ? `${h.name} is not signed in: open the Terminal tab (Open › ${h.name}) and sign in with its own sign-in, then ask again`
        : e instanceof UnsafeMode ? e.message
          : e?.status ? e.message : `${h.name} did not answer (${said(e?.message || String(e), 200)})`;
      log(`chat ${tool}: ${said(e?.message || String(e), 300)}`);
      if (started) { sse(res, { error: { message: msg } }); res.end('data: [DONE]\n\n'); return undefined; }
      return fail(res, e instanceof NotSignedIn || e instanceof UnsafeMode ? 409 : e?.status || 502, msg);
    }
    // the conversation's session, under the prompts it has had now — or, a tool reached for, none (said in the answer)
    if (r.tried) {
      store.move(rec ? oldKey : null, null);
      // (never the tool's own title in the answer: words the agent chose, as markdown — the log has it)
      out.text(`${sent ? '\n\n' : ''}*${h.name} reached for one of its tools and was stopped: in Chat it has none. This chat goes on in a new session of it. To work with files, use ${h.name} in the Code page.*`);
    } else if (r.ref) store.move(rec ? oldKey : null, { key: convKey(tool, [...msgs.turns, { role: 'assistant', text: stripAnswer(spoken) }]), tool, folder, ref: r.ref });
    const u = r.usage ?? { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0 };
    const usage = { prompt_tokens: u.input_tokens + u.cache_read_input_tokens, completion_tokens: u.output_tokens, total_tokens: u.input_tokens + u.cache_read_input_tokens + u.output_tokens };
    if (r.stop === 'error' && !sent && !r.tried) {
      const msg = `${h.name} reported: ${said(r.error || 'an error', 300)}`;
      if (started) { sse(res, { error: { message: msg } }); res.end('data: [DONE]\n\n'); return undefined; }
      return fail(res, 502, msg);
    }
    if (stream) {
      head();
      sse(res, { id, object: 'chat.completion.chunk', created, model: body.model, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage });
      res.end('data: [DONE]\n\n');
      return undefined;
    }
    return send(res, 200, { id, object: 'chat.completion', created, model: body.model,
      choices: [{ index: 0, message: { role: 'assistant', content: answer, ...(thinking ? { reasoning_content: thinking } : {}) }, finish_reason: 'stop' }], usage });
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://chat');
      if (!authed(req)) return fail(res, 401, 'a key is needed');
      if (url.pathname === '/v1/models' && req.method === 'GET') return send(res, 200, { object: 'list', data: await models() });
      if (url.pathname === '/v1/chat/completions' && req.method === 'POST') {
        const len = req.headers['content-length'];
        if (len !== undefined && (!/^[0-9]{1,12}$/.test(len) || Number(len) > MAX_BODY)) return fail(res, 413, 'request too large');
        const chunks = []; let size = 0;
        for await (const c of req) { size += c.length; if (size > MAX_BODY) return fail(res, 413, 'request too large'); chunks.push(c); }
        let body;
        try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return fail(res, 400, 'not JSON'); }
        if (!body || typeof body !== 'object' || Array.isArray(body)) return fail(res, 400, 'a JSON object, please');
        return await completions(req, res, body);
      }
      return fail(res, 404, 'not found');
    } catch (e) {
      log(`chat: ${said(e?.message || String(e), 300)}`);
      if (!res.headersSent) return fail(res, 500, 'internal error');
      try { res.end(); } catch { /* gone */ }
      return undefined;
    }
  });
  server.closeAgents = () => { for (const f of [...running.keys()]) release(f); };
  return server;
}
