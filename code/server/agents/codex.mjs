// Codex on your ChatGPT plan through its app server (`codex app-server`: the interface OpenAI's own Codex extensions
// use): one process, one thread. Codex's own sandbox is not used — the sandbox container is the boundary, so a turn
// runs with Codex's "external sandbox" policy and asks before anything it does not count as safe ("untrusted"); the
// page's mode decides the rest here (requested()). Its login is Codex's own (`codex login` in the terminal): this side
// only asks whether there is one (account/read), never reads, refreshes or passes it on.
import path from 'node:path';
import { Peer, RpcError, said, TOOL_STOP_MS } from './jsonrpc.mjs';
import { codexStarted, codexCompleted, codexPlan, callId, usageOf } from './map.mjs';
import { NotSignedIn } from './acp.mjs';
import { str, short, int, num } from '../validate.mjs';

const obj = (v) => (v !== null && typeof v === 'object' && !Array.isArray(v) ? v : {});
const arr = (v) => (Array.isArray(v) ? v : []);
const DELTA = 100000;
// What a Chat conversation tells Codex (developer instructions): it answers there, without its tools
export const CHAT_NOTE = 'You are answering in a chat app, not in a project: reply to the conversation in text. You have no files or tools to use here.';
// Chat: the items a turn may have — its answer, its reasoning, its plan; anything else is a tool (a command, a change to
// files, an MCP or web call, an image …), which Chat has none of: the turn is interrupted at its start
const CHAT_ITEMS = new Set(['userMessage', 'agentMessage', 'reasoning', 'plan', 'contextCompaction']);
// the notifications this side has no use for (Codex leaves them out)
const QUIET = ['item/commandExecution/outputDelta', 'item/fileChange/outputDelta', 'item/fileChange/patchUpdated', 'command/exec/outputDelta',
  'thread/realtime/outputAudio/delta', 'rawResponseItem/completed', 'rawResponse/completed', 'fuzzyFileSearch/sessionUpdated'];

export class CodexAgent {
  constructor(proc, { onEvent = () => {}, onPermission = async () => 'deny', log = () => {}, chat = false, clientVersion = '0', plainEdit = async () => false,
    toolStopMs = TOOL_STOP_MS }) {
    Object.assign(this, { tool: 'codex', onEvent, onPermission, log, chat, clientVersion, plainEdit, toolStopMs });
    this.cwd = null;
    this.changes = new Map();   // a fileChange item's id -> the paths it changes (item/started), for its approval
    this.peer = new Peer(proc, { jsonrpc: false, log, onNotify: (m, p) => this.notified(m, p), onRequest: (m, p) => this.requested(m, p) });
    this.threadId = null; this.turnId = null; this.turnDone = null;
    this.models = []; this.model = null; this.modes = []; this.mode = null; this.commands = [];
    this.pageMode = 'default';
    this.usage = null; this.limits = null; this.text = ''; this.thought = '';
    this.toolTried = null; this.interruptWanted = false;
  }

  get closed() { return this.peer.closed; }
  get sessionId() { return this.threadId; }

  async init() {
    await this.peer.request('initialize', { clientInfo: { name: 'code_page', title: 'Code page', version: this.clientVersion },
      capabilities: { experimentalApi: false, requestAttestation: false, optOutNotificationMethods: QUIET } }, { timeoutMs: 60000 });
    this.peer.notify('initialized', {});
    const a = obj(await this.peer.request('account/read', { refreshToken: false }, { timeoutMs: 60000 }));
    if (a.account === null && a.requiresOpenaiAuth !== false) throw new NotSignedIn('Codex is not signed in');
    return this;
  }

  async loadModels() {
    try {
      const r = obj(await this.peer.request('model/list', { limit: 100 }, { timeoutMs: 30000 }));
      // (a model by the slug turn/start takes — its `model`, else its id —, each once)
      const seen = new Set();
      this.models = arr(r.data).map(obj).filter((m) => m.hidden !== true).map((m) => ({ id: typeof m.model === 'string' ? m.model : m.id, name: m.displayName }))
        .filter((m) => typeof m.id === 'string' && /^[\x21-\x7e]{1,200}$/.test(m.id) && !seen.has(m.id) && seen.add(m.id))
        .slice(0, 100).map((m) => ({ id: m.id, name: short(m.name || m.id, 120) }));
    } catch (e) { this.log(`codex: no model list (${said(e.message, 200)})`); }
  }

  // Chat: Codex started without its tools (bn-coded's chat arguments: no shell, no MCP server, no web search, no apps or
  // plugins), asking before anything it does not count as safe — every question refused and the turn interrupted
  policy() {
    return this.chat ? { approvalPolicy: 'untrusted', sandbox: 'read-only' } : { approvalPolicy: 'untrusted' };
  }

  /** A thread in cwd: the one named (thread/resume) or a new one -> {ref, resumed} */
  async open({ cwd, resume = null, model = null }) {
    this.cwd = cwd;
    const base = { cwd, ...this.policy(), ...(model ? { model } : {}), ...(this.chat ? { developerInstructions: CHAT_NOTE } : {}) };
    let r = null, resumed = false;
    if (resume) {
      try { r = obj(await this.peer.request('thread/resume', { threadId: resume, ...base }, { timeoutMs: 120000 })); resumed = true; } catch (e) {
        this.log(`codex: thread ${short(resume, 40)} not resumed (${said(e.message, 200)}): a new one`);
      }
    }
    if (!r) r = obj(await this.peer.request('thread/start', base, { timeoutMs: 120000 }));
    const t = obj(r.thread);
    if (typeof t.id !== 'string' || !/^[\x21-\x7e]{1,200}$/.test(t.id)) throw new Error('Codex gave no thread id');
    this.threadId = t.id;
    if (typeof r.model === 'string') this.model = short(r.model, 200);
    await this.loadModels();
    return { ref: t.id, resumed };
  }

  async setMode(page) { this.pageMode = page; return null; }
  async chatMode() {}
  async setModel(id) {
    if (this.models.length && !this.models.some((m) => m.id === id)) throw new Error('Codex does not offer that model here');
    this.model = id;   // (taken by the next turn)
  }

  /** One prompt -> {stop, usage}: a turn, until turn/completed. images: [{media_type, data}] */
  async prompt(text, images = []) {
    const input = [...images.map((im) => ({ type: 'image', url: `data:${im.media_type};base64,${im.data}` })), { type: 'text', text, text_elements: [] }];
    this.text = ''; this.thought = ''; this.usage = null; this.toolTried = null; this.interruptWanted = false;
    this.changes.clear();
    const done = new Promise((resolve) => { this.turnDone = resolve; });
    try {
      const sandboxPolicy = this.chat ? undefined : { type: 'externalSandbox', networkAccess: 'enabled' };
      const r = obj(await this.peer.request('turn/start', { threadId: this.threadId, input, ...(this.model ? { model: this.model } : {}),
        approvalPolicy: 'untrusted', ...(this.chat ? {} : { sandboxPolicy }) }, { timeoutMs: 120000 }));
      this.turnId = typeof obj(r.turn).id === 'string' ? r.turn.id : null;
    } catch (e) {
      this.turnDone = null;
      // (Chat: a tool reached for before the turn's id came — the process was killed there and then)
      if (this.toolTried) { this.flush(); return { stop: 'cancelled', usage: usageOf({}), tried: this.toolTried }; }
      throw e;
    }
    const end = await Promise.race([done, this.peer.closed.then(() => ({ status: this.toolTried ? 'interrupted' : 'failed', error: 'Codex ended' }))]);
    this.flush();
    this.turnId = null; this.turnDone = null;
    const u = obj(this.usage);
    const usage = usageOf({ input: u.inputTokens, output: u.outputTokens, cached: u.cachedInputTokens });
    const tried = this.toolTried ? { tried: this.toolTried } : {};
    if (this.toolTried) return { stop: 'cancelled', usage, ...tried };
    if (end.status === 'interrupted') return { stop: 'cancelled', usage, ...tried };
    if (end.status === 'failed') return { stop: 'error', usage, error: end.error || 'Codex reported an error', ...tried };
    return { stop: 'end_turn', usage, ...tried };
  }

  cancel() {
    if (this.threadId && this.turnId) this.peer.request('turn/interrupt', { threadId: this.threadId, turnId: this.turnId }, { timeoutMs: 15000 }).catch(() => {});
    else this.interruptWanted = true;
  }
  // Chat: the first sign of a tool — the process (and all it started) is killed there and then, not interrupted, and
  // nothing it says after reaches the answer (notified() drops it)
  stopTool(what) {
    if (this.toolTried) return;
    this.toolTried = what;
    this.log(`codex: reached for a tool in Chat (${what}): killed`);
    this.peer.kill('SIGKILL');
    // (the turn waits for its end at most TOOL_STOP_MS: what it started may hold its output open)
    setTimeout(() => { if (!this.peer.done) this.peer.drop(); }, this.toolStopMs).unref?.();
  }
  close() { this.peer.kill(); }

  flush() {
    if (this.thought) this.onEvent({ type: 'thinking', text: str(this.thought, DELTA), parent: null });
    if (this.text) this.onEvent({ type: 'text', text: str(this.text, 200000), model: short(this.model, 128), parent: null });
    this.text = ''; this.thought = '';
  }

  notified(method, p) {
    if (this.toolTried || (p.threadId !== undefined && p.threadId !== this.threadId)) return;
    switch (method) {
      case 'item/agentMessage/delta':
        if (typeof p.delta === 'string' && p.delta) { if (this.text.length < 200000) this.text += p.delta; this.onEvent({ type: 'delta', text: str(p.delta, DELTA), parent: null }); }
        return;
      case 'item/reasoning/summaryTextDelta':
      case 'item/reasoning/textDelta':
        if (typeof p.delta === 'string' && p.delta) { if (this.thought.length < DELTA) this.thought += p.delta; this.onEvent({ type: 'thinking_delta', text: str(p.delta, DELTA), parent: null }); }
        return;
      case 'item/started': {
        const it = obj(p.item);
        if (this.chat) {
          if (!CHAT_ITEMS.has(it.type)) this.stopTool(short(typeof it.type === 'string' ? it.type : 'a tool', 60));
          return;
        }
        if (it.type === 'fileChange' && typeof it.id === 'string' && this.changes.size < 500) this.changes.set(it.id, changePaths(it, this.cwd));
        const evs = codexStarted(p.item);
        if (evs.length) this.flush();
        for (const ev of evs) this.onEvent(ev);
        return;
      }
      case 'item/completed': {
        const it = obj(p.item);
        // (Chat: a tool seen only once it is done — no item/started came for it — is a tool's sign all the same)
        if (this.chat && !CHAT_ITEMS.has(it.type)) { this.stopTool(short(typeof it.type === 'string' ? it.type : 'a tool', 60)); return; }
        // (a message or reasoning streamed already: its deltas are its text; the whole one only when none came)
        if (it.type === 'agentMessage' || it.type === 'reasoning') {
          if ((it.type === 'agentMessage' && this.text) || (it.type === 'reasoning' && this.thought)) { this.flush(); return; }
        }
        for (const ev of codexCompleted(it, this.model ?? '')) this.onEvent(ev);
        return;
      }
      case 'turn/plan/updated':
        this.flush();
        this.onEvent({ type: 'tool_use', id: callId(`plan-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`), name: 'TodoWrite', input: codexPlan(p), parent: null });
        return;
      case 'thread/tokenUsage/updated': this.usage = obj(obj(p.tokenUsage).last); return;
      case 'account/rateLimits/updated': this.limits = rateLimits(p.rateLimits); return;
      case 'turn/completed': {
        const t = obj(p.turn);
        const status = ['completed', 'interrupted', 'failed'].includes(t.status) ? t.status : 'completed';
        this.turnDone?.({ status, error: said(obj(t.error).message || '', 500) });
        return;
      }
      case 'error': {
        if (p.willRetry === true) { this.onEvent({ type: 'status', status: 'requesting' }); return; }
        this.onEvent({ type: 'error', message: 'Codex reported an error', text: 'Codex reported an error', said: said(obj(p.error).message, 300), saidBy: 'claude' });
        return;
      }
      default:
    }
  }

  // Codex's own requests: its approvals (answered per the page's mode, or by you in the page). Nothing about its login
  // (account/chatgptAuthTokens/refresh …) is ever answered here.
  async requested(method, p) {
    const decline = { decision: 'decline' };
    if (method !== 'item/commandExecution/requestApproval' && method !== 'item/fileChange/requestApproval') throw new RpcError(-32601, 'not offered by this client');
    if (this.chat) { this.stopTool(method === 'item/fileChange/requestApproval' ? 'a change to files' : 'a command'); return decline; }
    const edit = method === 'item/fileChange/requestApproval';
    if (this.pageMode === 'readOnly' || this.pageMode === 'plan') {
      this.onEvent({ type: 'local', text: `${this.pageMode === 'plan' ? 'Plan' : 'Read only'}: ${edit ? 'a change to files' : 'a command'} was refused without asking.` });
      return decline;
    }
    // Accept edits: a change goes through without asking only when every path it changes is a plain file of the session's
    // folder outside git's and the tools' own configuration (plainEdit) — never one asking for a folder of its own to
    // write in (grantRoot), never one whose paths were not said (asked)
    const paths = edit && typeof p.itemId === 'string' ? this.changes.get(p.itemId) ?? null : null;
    if (edit && this.pageMode === 'acceptEdits' && p.grantRoot === undefined && paths && await this.plainEdit(paths)) return { decision: 'accept' };
    const tool = edit ? 'Edit' : 'Bash';
    const input = edit ? { file_path: short(p.grantRoot || paths?.join(', ') || '(the change above)', 4096), ...(p.grantRoot ? { description: `asks to write anywhere under ${short(p.grantRoot, 300)}${p.reason ? ` — ${short(p.reason, 300)}` : ''}` } : p.reason ? { description: short(p.reason, 500) } : {}) }
      : { command: str(p.command ?? '', 20000), ...(typeof p.cwd === 'string' ? { description: `in ${short(p.cwd, 300)}${p.reason ? ` — ${short(p.reason, 300)}` : ''}` } : {}) };
    const answer = await this.onPermission({ tool, input, kind: edit ? 'edit' : 'execute', always: true });
    if (answer === 'always') return { decision: 'acceptForSession' };
    if (answer === 'once') return { decision: 'accept' };
    return decline;
  }
}

// changePaths(fileChange item, cwd) -> the absolute paths it changes (a move's destination too; a relative one taken in
// cwd), or null when one is not a path
export function changePaths(it, cwd) {
  const out = [];
  for (const c of arr(it.changes).map(obj)) {
    out.push(c.path);
    const mv = obj(c.kind).move_path ?? obj(c.kind).movePath;
    if (mv !== undefined && mv !== null) out.push(mv);
  }
  if (!out.length || out.length > 200 || !out.every((x) => typeof x === 'string' && x && x.length <= 4096 && !x.includes('\0'))) return null;
  if (out.some((x) => !x.startsWith('/')) && (typeof cwd !== 'string' || !cwd.startsWith('/'))) return null;
  return [...new Set(out.map((x) => (x.startsWith('/') ? x : path.posix.resolve(cwd, x))))];
}

// rateLimits(snapshot) -> [{label, usedPercent, resetsAt}]: Codex's plan limits as it reports them (5-hour, weekly …)
export function rateLimits(s) {
  const out = [];
  for (const [k, w] of [['primary', obj(obj(s).primary)], ['secondary', obj(obj(s).secondary)]]) {
    const used = num(w.usedPercent, 0, 1000);
    if (used === null) continue;
    const mins = int(w.windowDurationMins, 1, 1e7);
    const label = mins === null ? k : mins % 10080 === 0 ? `${mins / 10080 === 1 ? 'weekly' : `${mins / 10080}-week`}` : mins % 1440 === 0 ? `${mins / 1440}-day` : mins % 60 === 0 ? `${mins / 60}-hour` : `${mins}-minute`;
    const resets = int(w.resetsAt, 0, 1e13);
    out.push({ label, usedPercent: Math.round(used), resetsAt: resets === null ? null : resets < 1e11 ? resets * 1000 : resets });
  }
  return out.length ? out : null;
}
