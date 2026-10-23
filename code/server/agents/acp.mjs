// A tool of your subscriptions on the Agent Client Protocol (Copilot CLI --acp, Cursor CLI acp, Grok Build agent
// stdio): one process, one session. This side is the client: it offers the agent no file system and no terminal of
// its own (the agent reads and writes in the sandbox itself, where it runs), answers its permission requests through
// onPermission, and turns its session/update notifications into the page's events (map.mjs). Its login is the tool's
// own: a session that needs one is "not signed in" here — the tool's own sign-in runs in the terminal, never here.
import { Peer, RpcError, said } from './jsonrpc.mjs';
import { acpCall, acpPlan, callId, contentText, usageOf } from './map.mjs';
import { str, short, int } from '../validate.mjs';

const obj = (v) => (v !== null && typeof v === 'object' && !Array.isArray(v) ? v : {});
const arr = (v) => (Array.isArray(v) ? v : []);
const TEXT = 200000, DELTA = 100000;
export class NotSignedIn extends Error {}
// an agent mode this side never switches to: one that approves by itself
export const MODE_NEVER = /yolo|autopilot|bypass|full.?access|always|dangerous|auto(?![-_ ]?edit)/i;
// the agent's own login, used where the agent asks a client to name it: Cursor's (after `agent login` in the terminal)
// and the one an agent names as its default (Grok, once signed in) — never a method that starts a sign-in here
const EXISTING_LOGIN = new Set(['cursor_login']);

export class AcpAgent {
  // proc: sandboxAgent's process. onEvent(ev): the page's events. onPermission({tool, input, kind}) -> 'once' |
  // 'always' | 'deny'. chat: one of Chat's conversations (every permission request is refused there without asking).
  constructor(proc, { tool, onEvent = () => {}, onPermission = async () => 'deny', log = () => {}, chat = false, clientVersion = '0' }) {
    Object.assign(this, { tool, onEvent, onPermission, log, chat, clientVersion });
    this.peer = new Peer(proc, { jsonrpc: true, log, onNotify: (m, p) => this.notified(m, p), onRequest: (m, p) => this.requested(m, p) });
    this.sessionId = null; this.caps = {}; this.authMethods = []; this.defaultAuth = null;
    this.modes = []; this.mode = null; this.models = []; this.model = null; this.commands = [];
    this.calls = new Map();   // toolCallId -> merged state {…, shown}
    this.loading = false;     // a session/load replays the past: not shown again (the page has it)
    this.text = ''; this.thought = '';
    this.pageMode = 'default';
  }

  get closed() { return this.peer.closed; }

  async init() {
    const r = obj(await this.peer.request('initialize', {
      protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: 'code-page', title: 'Code page', version: this.clientVersion },
    }, { timeoutMs: 60000 }));
    this.caps = obj(r.agentCapabilities);
    this.authMethods = arr(r.authMethods).map(obj).filter((m) => typeof m.id === 'string').map((m) => m.id).slice(0, 20);
    const d = obj(r._meta).defaultAuthMethodId;
    this.defaultAuth = typeof d === 'string' && this.authMethods.includes(d) ? d : null;
    this.agentVersion = short(obj(r.agentInfo).version || obj(r._meta).agentVersion, 40);
    return this;
  }

  // the session's modes and models as the agent reported them (session/new, session/load)
  takeSession(r) {
    const m = obj(r.modes);
    this.modes = arr(m.availableModes).map(obj).filter((x) => typeof x.id === 'string' && /^[\x21-\x7e]{1,100}$/.test(x.id))
      .slice(0, 30).map((x) => ({ id: x.id, name: short(x.name || x.id, 100), description: short(x.description, 300) }));
    if (typeof m.currentModeId === 'string') this.mode = m.currentModeId;
    const ms = obj(r.models);
    let models = arr(ms.availableModels).map(obj).filter((x) => typeof x.modelId === 'string')
      .map((x) => ({ id: x.modelId, name: short(x.name || x.modelId, 120) }));
    let current = typeof ms.currentModelId === 'string' ? ms.currentModelId : null;
    // (or a config option of the model category)
    const opt = arr(r.configOptions).map(obj).find((o) => o.category === 'model' && Array.isArray(o.options));
    if (!models.length && opt) {
      models = arr(opt.options).map(obj).filter((x) => typeof x.value === 'string').map((x) => ({ id: x.value, name: short(x.name || x.value, 120) }));
      if (typeof opt.currentValue === 'string') current = opt.currentValue;
      this.modelOption = typeof opt.id === 'string' ? opt.id : null;
    }
    this.models = models.filter((x) => /^[\x21-\x7e]{1,200}$/.test(x.id)).slice(0, 200);
    if (current) this.model = short(current, 200);
  }

  async withLogin(fn) {
    try { return await fn(); } catch (e) {
      if (!(e instanceof RpcError) || !/auth/i.test(`${e.message} ${JSON.stringify(e.data ?? '')}`)) throw e;
      const method = this.authMethods.find((m) => EXISTING_LOGIN.has(m)) ?? this.defaultAuth;
      if (!method) throw new NotSignedIn(said(e.message, 200));
      try { await this.peer.request('authenticate', { methodId: method }, { timeoutMs: 60000 }); } catch (e2) { throw new NotSignedIn(said(e2.message, 200)); }
      try { return await fn(); } catch (e3) {
        if (e3 instanceof RpcError && /auth/i.test(e3.message)) throw new NotSignedIn(said(e3.message, 200));
        throw e3;
      }
    }
  }

  /** A session in cwd: the one named (session/load, where the agent offers it) or a new one -> {ref, resumed} */
  async open({ cwd, resume = null }) {
    if (resume && this.caps.loadSession === true) {
      this.loading = true;
      try {
        const r = obj(await this.withLogin(() => this.peer.request('session/load', { sessionId: resume, cwd, mcpServers: [] }, { timeoutMs: 120000 })));
        this.sessionId = resume;
        this.takeSession(r);
        this.firstMode ??= this.mode;
        return { ref: resume, resumed: true };
      } catch (e) {
        if (e instanceof NotSignedIn) throw e;
        this.log(`${this.tool}: session ${short(resume, 40)} not resumed (${said(e.message, 200)}): a new one`);
      } finally { this.loading = false; this.calls.clear(); }
    }
    const r = obj(await this.withLogin(() => this.peer.request('session/new', { cwd, mcpServers: [] }, { timeoutMs: 120000 })));
    if (typeof r.sessionId !== 'string' || !/^[\x21-\x7e]{1,200}$/.test(r.sessionId)) throw new Error(`${this.tool} gave no session id`);
    this.sessionId = r.sessionId;
    this.takeSession(r);
    this.firstMode ??= this.mode;
    return { ref: r.sessionId, resumed: false };
  }

  // the page's mode as one of the agent's: Plan and Read only to its planning or asking mode where it has one (this side
  // refuses changes in them either way: requested()), Manual and Accept edits to the one it started in
  agentModeFor(page) {
    const ok = this.modes.filter((m) => !MODE_NEVER.test(`${m.id} ${m.name}`));
    const find = (re) => ok.find((m) => re.test(m.id) || re.test(m.name));
    if (page === 'plan') return find(/plan/i) ?? find(/^ask$|read/i) ?? null;
    if (page === 'readOnly') return find(/^ask$|read.?only|^read/i) ?? find(/plan/i) ?? null;
    if (this.firstMode && ok.some((m) => m.id === this.firstMode)) return this.firstMode;
    return find(/^(agent|default|code|build|interactive)$/i) ?? null;
  }

  async setMode(page) {
    this.pageMode = page;
    const m = this.agentModeFor(page);
    const id = typeof m === 'string' ? m : m?.id;
    if (!id || id === this.mode || !this.sessionId) return this.mode;
    try {
      await this.peer.request('session/set_mode', { sessionId: this.sessionId, modeId: id }, { timeoutMs: 30000 });
      this.mode = id;
    } catch (e) { this.log(`${this.tool}: mode ${short(id, 40)} not set: ${said(e.message, 200)}`); }
    return this.mode;
  }

  // Chat: the agent's asking mode where it has one (Cursor's ask: questions and answers, read only); else its own
  async chatMode() {
    const m = this.modes.find((x) => /^ask$/i.test(x.id) || /^ask$/i.test(x.name));
    if (!m || m.id === this.mode || !this.sessionId) return;
    try { await this.peer.request('session/set_mode', { sessionId: this.sessionId, modeId: m.id }, { timeoutMs: 30000 }); this.mode = m.id; } catch { /* its own mode */ }
  }

  async setModel(id) {
    if (!this.models.some((m) => m.id === id)) throw new Error(`${this.tool} does not offer that model here`);
    if (this.modelOption) await this.peer.request('session/set_config_option', { sessionId: this.sessionId, configId: this.modelOption, value: id }, { timeoutMs: 30000 });
    else await this.peer.request('session/set_model', { sessionId: this.sessionId, modelId: id }, { timeoutMs: 30000 });
    this.model = id;
  }

  /** One prompt -> {stop, usage}; the answer streams as events meanwhile. images: [{media_type, data}] */
  async prompt(text, images = []) {
    const blocks = [];
    if (obj(this.caps.promptCapabilities).image === true) for (const im of images) blocks.push({ type: 'image', mimeType: im.media_type, data: im.data });
    blocks.push({ type: 'text', text });
    this.text = ''; this.thought = '';
    let r;
    try {
      r = obj(await this.peer.request('session/prompt', { sessionId: this.sessionId, prompt: blocks }, { timeoutMs: 6 * 3600000 }));
    } finally { this.flush(); }
    const u = obj(r.usage);
    const usage = usageOf({ input: u.inputTokens ?? u.input_tokens, output: u.outputTokens ?? u.output_tokens, cached: u.cachedReadTokens ?? u.cachedInputTokens ?? u.cache_read_input_tokens });
    const stop = ['end_turn', 'max_tokens', 'max_turn_requests', 'refusal', 'cancelled'].includes(r.stopReason) ? r.stopReason : 'end_turn';
    return { stop, usage };
  }

  cancel() { if (this.sessionId) this.peer.notify('session/cancel', { sessionId: this.sessionId }); }
  close() { this.peer.kill(); }

  // the text and thinking streamed since the last tool call, as whole blocks (what the history keeps)
  flush() {
    if (this.thought) this.onEvent({ type: 'thinking', text: str(this.thought, DELTA), parent: null });
    if (this.text) this.onEvent({ type: 'text', text: str(this.text, TEXT), model: short(this.model, 128), parent: null });
    this.text = ''; this.thought = '';
  }

  notified(method, p) {
    if (method !== 'session/update' || this.loading || (this.sessionId && p.sessionId !== this.sessionId)) return;
    const u = obj(p.update);
    switch (u.sessionUpdate) {
      case 'agent_message_chunk': {
        const t = contentText([u.content], DELTA);
        if (!t) return;
        if (this.text.length < TEXT) this.text += t;
        this.onEvent({ type: 'delta', text: t, parent: null });
        return;
      }
      case 'agent_thought_chunk': {
        const t = contentText([u.content], DELTA);
        if (!t) return;
        if (this.thought.length < DELTA) this.thought += t;
        this.onEvent({ type: 'thinking_delta', text: t, parent: null });
        return;
      }
      case 'tool_call':
      case 'tool_call_update': this.call(u); return;
      case 'plan':
        this.flush();
        this.onEvent({ type: 'tool_use', id: callId(`plan-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`), name: 'TodoWrite', input: acpPlan(u.entries), parent: null });
        return;
      case 'available_commands_update':
        this.commands = arr(u.availableCommands).map(obj).filter((c) => typeof c.name === 'string').slice(0, 200).map((c) => short(c.name, 100));
        return;
      case 'current_mode_update':
        if (typeof u.currentModeId === 'string') this.mode = short(u.currentModeId, 100);
        return;
      case 'usage_update': {
        const used = int(u.used, 0, 1e12), size = int(u.size, 0, 1e12);
        if (used !== null) this.context = { used, size };
        return;
      }
      default:
    }
  }

  // a tool call: shown once its kind is known well enough (an edit: once its change is there, or it runs, or it asks),
  // its result when it completes or fails
  call(u) {
    const id = typeof u.toolCallId === 'string' ? u.toolCallId : null;
    if (!id || (!this.calls.has(id) && this.calls.size >= 2000)) return;
    const prev = this.calls.get(id) ?? { shown: false };
    const next = { ...prev };
    for (const k of ['title', 'kind', 'status', 'content', 'locations', 'rawInput', 'rawOutput']) if (u[k] !== undefined) next[k] = u[k];
    this.calls.set(id, next);
    const pid = callId(id);
    const editish = ['edit', 'delete', 'move'].includes(next.kind);
    const hasDiff = arr(next.content).some((c) => obj(c).type === 'diff');
    const going = ['in_progress', 'completed', 'failed'].includes(next.status);
    if (!next.shown && (!editish || hasDiff || going)) this.show(id, next);
    if (next.shown && !next.done && (next.status === 'completed' || next.status === 'failed')) {
      next.done = true;
      const text = contentText(arr(next.content).filter((c) => obj(c).type !== 'diff')) || (typeof next.rawOutput === 'string' ? str(next.rawOutput, 100000) : '');
      this.onEvent({ type: 'tool_result', id: pid, text, is_error: next.status === 'failed', parent: null });
    }
  }
  show(id, state) {
    this.flush();
    state.shown = true;
    const c = acpCall(state);
    this.onEvent({ type: 'tool_use', id: callId(id), name: c.name, input: c.input, parent: null });
  }

  // the agent's own requests: its permission questions (answered per the page's mode, or by you in the page); no file
  // system, no terminal of this side's
  async requested(method, p) {
    if (method !== 'session/request_permission') throw new RpcError(-32601, 'not offered by this client');
    const opts = arr(p.options).map(obj).filter((o) => typeof o.optionId === 'string');
    const pick = (...kinds) => { for (const k of kinds) { const o = opts.find((x) => x.kind === k); if (o) return { outcome: { outcome: 'selected', optionId: o.optionId } }; } return { outcome: { outcome: 'cancelled' } }; };
    const tc = obj(p.toolCall);
    const id = typeof tc.toolCallId === 'string' ? tc.toolCallId : null;
    const merged = { ...(id ? this.calls.get(id) : {}), ...tc };
    if (id && !merged.shown && this.calls.size < 2000) { this.calls.set(id, merged); this.show(id, merged); }
    if (this.chat) return pick('reject_once', 'reject_always');
    const kind = typeof merged.kind === 'string' ? merged.kind : 'other';
    const changes = ['edit', 'delete', 'move', 'execute'].includes(kind) || arr(merged.content).some((c) => obj(c).type === 'diff');
    if ((this.pageMode === 'readOnly' || this.pageMode === 'plan') && (changes || !['read', 'search', 'think', 'fetch'].includes(kind))) {
      this.onEvent({ type: 'local', text: `${this.pageMode === 'plan' ? 'Plan' : 'Read only'}: ${short(merged.title || kind, 120)} was refused without asking.` });
      return pick('reject_once', 'reject_always');
    }
    if (this.pageMode === 'acceptEdits' && ['edit', 'delete', 'move'].includes(kind)) return pick('allow_once');
    const c = acpCall(merged);
    const answer = await this.onPermission({ tool: c.name, input: c.input, kind, always: opts.some((o) => o.kind === 'allow_always') });
    if (answer === 'always') return pick('allow_always', 'allow_once');
    if (answer === 'once') return pick('allow_once');
    return pick('reject_once', 'reject_always');
  }
}
