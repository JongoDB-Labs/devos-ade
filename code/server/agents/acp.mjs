// A tool of your subscriptions on the Agent Client Protocol (Copilot CLI --acp, Cursor CLI acp, Grok Build agent
// stdio): one process, one session. This side is the client: it offers the agent no file system and no terminal of
// its own (the agent reads and writes in the sandbox itself, where it runs), answers its permission requests through
// onPermission, and turns its session/update notifications into the page's events (map.mjs). Its login is the tool's
// own: a session that needs one is "not signed in" here — the tool's own sign-in runs in the terminal, never here.
import { Peer, RpcError, said, TOOL_STOP_MS } from './jsonrpc.mjs';
import { acpCall, acpPlan, callId, contentText, usageOf } from './map.mjs';
import { str, short, int } from '../validate.mjs';
import { HARNESSES } from './tools.mjs';

const obj = (v) => (v !== null && typeof v === 'object' && !Array.isArray(v) ? v : {});
const arr = (v) => (Array.isArray(v) ? v : []);
const TEXT = 200000, DELTA = 100000;
// editPaths(toolCall) -> the absolute paths an edit says it touches (its locations and its diffs), or null when one is
// not absolute or none is named
export function editPaths(tc) {
  const out = [];
  for (const l of arr(tc.locations).map(obj)) out.push(l.path);
  for (const c of arr(tc.content).map(obj)) if (c.type === 'diff') out.push(c.path);
  if (!out.length || out.length > 200 || !out.every((p) => typeof p === 'string' && p.startsWith('/') && p.length <= 4096)) return null;
  return [...new Set(out)];
}
export class NotSignedIn extends Error {}
// an agent in a mode that approves by itself, with no other to leave it for (or one it switched to by itself): its
// session is closed, never prompted in it
export class UnsafeMode extends Error {}
// an agent mode this side never switches to, and never prompts in: one that approves by itself
export const MODE_NEVER = /yolo|autopilot|bypass|full.?access|always|dangerous|auto(?![-_ ]?edit)/i;
// The modes each tool runs in here — the ones that ask before a change or refuse it, by the ids the pinned tool reports
// (anything else, a mode added later included, is never used: the session is moved to one of these, or ends):
//   cursor   Cursor CLI 2026.10.22's ACP modes: agent, plan, ask (its own list, buildModesStateFromCliMode)
//   copilot  Copilot CLI 1.0.103's: the protocol's #agent and #plan (#autopilot turns allow-all on)
//   grok     Grok Build 1.0.67's documented modes that ask: default (ask) and plan — its acceptEdits writes without
//            asking (this side's Accept edits checks each path: never handed to the tool), auto, dontAsk and
//            bypassPermissions never; its ACP ids are not confirmed without a sign-in: an id not here ends the session
const ACP_MODE = 'https://agentclientprotocol.com/protocol/session-modes#';
export const SAFE_MODES = Object.freeze({
  cursor: Object.freeze(['agent', 'plan', 'ask']),
  copilot: Object.freeze([`${ACP_MODE}agent`, `${ACP_MODE}plan`]),
  grok: Object.freeze(['default', 'ask', 'plan']),
});
// the config options known to be about something else than permissions (an allowlist): the model's (Cursor's
// model_config: its parameters) and the thinking level — the mode's is checked as a mode. Any other option (an
// "Auto-run" switch, one a later version adds, whatever its name) must say one of PERM_SAFE's values, or the session is
// moved off it or not used
const OTHER_OPTIONS = new Set(['model', 'model_config', 'thought_level']);
const PERM_SAFE = /^(default|ask|manual|prompt)$/i;
// how long a mode asked for may take to be reported (current_mode_update): not reported, not taken
const MODE_REPORT_MS = 5000;
const UNCONFIRMED = '\0unconfirmed';
// the agent's own login, used where the agent asks a client to name it: Cursor's (after `agent login` in the terminal)
// and the one an agent names as its default (Grok, once signed in) — never a method that starts a sign-in here
const EXISTING_LOGIN = new Set(['cursor_login']);

export class AcpAgent {
  // proc: sandboxAgent's process. onEvent(ev): the page's events. onPermission({tool, input, kind}) -> 'once' |
  // 'always' | 'deny'. chat: one of Chat's conversations (every permission request is refused there without asking).
  // plainEdit(paths) -> whether a change to these paths may go through without asking (Accept edits: session.mjs)
  constructor(proc, { tool, onEvent = () => {}, onPermission = async () => 'deny', log = () => {}, chat = false, clientVersion = '0', plainEdit = async () => false,
    toolStopMs = TOOL_STOP_MS }) {
    Object.assign(this, { tool, onEvent, onPermission, log, chat, clientVersion, plainEdit, toolStopMs });
    this.peer = new Peer(proc, { jsonrpc: true, log, onNotify: (m, p) => this.notified(m, p), onRequest: (m, p) => this.requested(m, p) });
    this.sessionId = null; this.caps = {}; this.authMethods = []; this.defaultAuth = null;
    this.modes = []; this.mode = null; this.models = []; this.model = null; this.commands = [];
    this.modesFromSession = false; this.modeConfig = null; this.modeOpt = null; this.permOpts = new Map();
    this.modeWait = null;     // a mode asked for, until the agent reports it: {id, resolve}
    this.calls = new Map();   // toolCallId -> merged state {…, shown}
    this.loading = false;     // a session/load replays the past: not shown again (the page has it)
    this.text = ''; this.thought = '';
    this.pageMode = 'default';
    this.unsafe = null;       // the name of a mode that approves by itself the agent switched to: the session ends
    this.prompting = false;
    this.toolTried = null;    // Chat: the tool the agent reached for in this turn (the turn is stopped at once)
  }

  get closed() { return this.peer.closed; }
  modeName(id) { return short(this.modes.find((m) => m.id === id)?.name || id || 'no', 100); }
  never(id) { return typeof id === 'string' && MODE_NEVER.test(`${id} ${this.modes.find((m) => m.id === id)?.name ?? ''}`); }
  // safe(id) -> one of this tool's modes that ask (SAFE_MODES), and nothing about it says it approves by itself
  safe(id) { return typeof id === 'string' && (SAFE_MODES[this.tool] ?? []).includes(id) && !this.never(id); }
  // what makes the session's mode unsafe now (its name, for the error), or null: the mode it reports (a mode, or a
  // config option of the mode category: both, when it gives both) is one of SAFE_MODES, and a config option about
  // permissions says default or ask — none reported, for a tool that has them: unsafe too
  unsafeNow() {
    const current = [this.mode, this.modeOpt].filter((x) => x !== null && x !== undefined);
    if (!current.length) return 'no';
    const bad = current.find((x) => !this.safe(x));
    if (bad !== undefined) return this.modeName(bad);
    for (const [, o] of this.permOpts) if (!PERM_SAFE.test(o.value ?? '')) return short(`${o.name}: ${o.value ?? '?'}`, 100);
    return null;
  }
  // takeConfig(configOptions) — the agent's config options as it reports them (session/new, a set_config_option's
  // answer, config_option_update): its mode where it gives one that way, and those about permissions
  takeConfig(list) {
    if (!Array.isArray(list)) return false;
    const opts = list.map(obj).filter((o) => typeof o.id === 'string');
    const mo = opts.find((o) => o.category === 'mode' && Array.isArray(o.options));
    if (mo) {
      this.modeConfig = mo.id;
      this.modeOpt = typeof mo.currentValue === 'string' ? short(mo.currentValue, 100) : null;
      if (!this.modesFromSession) {
        this.modes = arr(mo.options).map(obj).filter((x) => typeof x.value === 'string' && /^[\x21-\x7e]{1,100}$/.test(x.value)).slice(0, 30)
          .map((x) => ({ id: x.value, name: short(x.name || x.value, 100), description: short(x.description, 300) }));
      }
    }
    this.permOpts = new Map(opts.filter((o) => o !== mo && !OTHER_OPTIONS.has(o.category))
      .map((o) => [o.id, { name: short(o.name || o.id, 60), value: typeof o.currentValue === 'string' ? o.currentValue : null,
        options: arr(o.options).map(obj).map((x) => x.value).filter((x) => typeof x === 'string') }]));
    return Boolean(mo);
  }

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
    this.modesFromSession = this.modes.length > 0;
    this.mode = typeof m.currentModeId === 'string' ? short(m.currentModeId, 100) : null;
    this.takeConfig(r.configOptions);
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
        // (the past replayed — it came before the answer: what the agent reports from now on is the session's, its
        // mode's report to leaving an unsafe one included)
        this.loading = false;
        this.sessionId = resume;
        this.takeSession(r);
        await this.leaveUnsafe();
        this.firstMode ??= this.mode ?? this.modeOpt;
        return { ref: resume, resumed: true };
      } catch (e) {
        if (e instanceof NotSignedIn || e instanceof UnsafeMode) throw e;
        this.log(`${this.tool}: session ${short(resume, 40)} not resumed (${said(e.message, 200)}): a new one`);
      } finally { this.loading = false; this.calls.clear(); }
    }
    const r = obj(await this.withLogin(() => this.peer.request('session/new', { cwd, mcpServers: [] }, { timeoutMs: 120000 })));
    if (typeof r.sessionId !== 'string' || !/^[\x21-\x7e]{1,200}$/.test(r.sessionId)) throw new Error(`${this.tool} gave no session id`);
    this.sessionId = r.sessionId;
    this.takeSession(r);
    await this.leaveUnsafe();
    this.firstMode ??= this.mode ?? this.modeOpt;
    return { ref: r.sessionId, resumed: false };
  }

  // a session in a mode that is not one of SAFE_MODES (the agent's own default, a resumed session's, one added later,
  // none reported), or with a permissions option that approves by itself: moved at once to a safe one — the page's,
  // else any other the agent offers — taken only once the agent reports it; none, or it does not report it: closed
  async leaveUnsafe() {
    if (!this.unsafeNow()) return;
    const was = this.unsafeNow();
    let ok = true;
    if ([this.mode, this.modeOpt].some((x) => x !== null && x !== undefined && !this.safe(x)) || (this.mode === null && this.modeOpt === null)) {
      const m = this.agentModeFor(this.pageMode);
      const to = (typeof m === 'string' ? m : m?.id) ?? this.modes.find((x) => this.safe(x.id))?.id ?? null;
      ok = to ? await this.askMode(to) : false;
    }
    for (const [id, o] of ok ? this.permOpts : []) {
      if (PERM_SAFE.test(o.value ?? '')) continue;
      const v = o.options.find((x) => PERM_SAFE.test(x));
      if (v) await this.askConfig(id, v);
    }
    if (!ok || this.unsafe || this.unsafeNow()) {
      this.close();
      throw new UnsafeMode(`${HARNESSES[this.tool]?.name ?? this.tool} started in ${was === 'no' ? 'no mode it reported' : `its "${was}" mode`}, not one this page uses (one that asks before changes), and did not leave it: not used (its own settings in the terminal choose its default mode)`);
    }
  }
  // askMode(id) -> whether the agent went to that mode: taken only once it reports it — a current_mode_update (or a
  // config option of the mode category) naming it, or a config option's answer — within MODE_REPORT_MS. One naming
  // another mode meanwhile, no report in time, an error: false (the callers close the session)
  async askMode(id) {
    try {
      if (this.modeConfig && !this.modesFromSession) { await this.askConfig(this.modeConfig, id); return this.modeOpt === id && this.safe(id); }
      const reported = new Promise((resolve) => {
        this.modeWait = { id, resolve };
        const t = setTimeout(() => resolve(false), MODE_REPORT_MS);
        t.unref?.();
      });
      await this.peer.request('session/set_mode', { sessionId: this.sessionId, modeId: id }, { timeoutMs: 30000 });
      const ok = await reported;
      if (!ok) this.log(`${this.tool}: mode ${short(id, 40)} asked for, not reported as such: not taken`);
      return ok;
    } catch (e) { this.log(`${this.tool}: mode ${short(id, 40)} not set: ${said(e.message, 200)}`); return false; } finally { this.modeWait = null; }
  }
  // askConfig(configId, value) — a config option set; its answer is the agent's options as they are now (taken)
  async askConfig(configId, value) {
    try {
      const r = obj(await this.peer.request('session/set_config_option', { sessionId: this.sessionId, configId, value }, { timeoutMs: 30000 }));
      this.takeConfig(r.configOptions);
    } catch (e) { this.log(`${this.tool}: ${short(configId, 40)} not set: ${said(e.message, 200)}`); }
  }
  // reported(mode) — a mode the agent says it is in (current_mode_update, a mode config option's update): a mode asked
  // for is taken only when it is that one, and allowed; anything else ends the wait as not taken. Then checkMode().
  reported(mode) {
    const w = this.modeWait;
    if (w) w.resolve(mode === w.id && this.safe(mode));
    this.checkMode(w && mode === w.id && this.safe(mode));
  }
  // checkMode(asked) — a mode (or permissions option) the agent reports itself in now that is not one of SAFE_MODES:
  // the turn under way is stopped there and then (the process killed), the session ends (prompt()). asked: the mode
  // just reported is the allowed one asked for (what is left — a permissions option — is leaveUnsafe's to set)
  checkMode(asked = false) {
    const bad = this.unsafeNow();
    if (!bad || this.unsafe || !this.sessionId || asked) return;
    this.unsafe = bad;
    if (this.prompting) this.peer.kill('SIGKILL');
  }
  unsafeError() {
    const what = this.unsafe === UNCONFIRMED ? 'did not confirm the mode it was asked to go to'
      : `switched itself to ${this.unsafe === 'no' ? 'no mode it reports' : `its "${this.unsafe}" mode`}, not one this page uses (one that asks before changes)`;
    return new UnsafeMode(`${HARNESSES[this.tool]?.name ?? this.tool} ${what}: its turn was stopped and its session closed (your next prompt starts it again)`);
  }

  // the page's mode as one of the agent's: Plan and Read only to its planning or asking mode where it has one (this side
  // refuses changes in them either way: requested()), Manual and Accept edits to the one it started in
  agentModeFor(page) {
    const ok = this.modes.filter((m) => this.safe(m.id));
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
    if (!id || id === (this.modesFromSession ? this.mode : this.modeOpt) || !this.sessionId || !this.safe(id)) return this.mode ?? this.modeOpt;
    // (the page's own mode decides what it lets through either way — requested(): a mode not reported changes nothing)
    // (not reported as asked: never a turn in a mode not known — the session ends, the next prompt starts a new one)
    if (!(await this.askMode(id))) { this.unsafe ??= this.unsafeNow() ?? UNCONFIRMED; this.close(); }
    this.checkMode();
    return this.mode ?? this.modeOpt;
  }

  // Chat: the agent's asking mode where it has one (Cursor's ask: questions and answers, read only); else its own
  async chatMode() {
    const m = this.modes.find((x) => (/^ask$/i.test(x.id) || /^ask$/i.test(x.name)) && this.safe(x.id));
    if (!m || m.id === this.mode || !this.sessionId) return;
    if (!(await this.askMode(m.id))) { this.close(); throw new UnsafeMode(`${HARNESSES[this.tool]?.name ?? this.tool} did not go to its asking mode: not used`); }
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
    this.text = ''; this.thought = ''; this.toolTried = null;
    // never a turn in a mode that approves by itself (the agent's own switch to one ends the session: notified())
    if (this.unsafe || this.unsafeNow()) { this.unsafe ??= this.unsafeNow(); this.close(); throw this.unsafeError(); }
    let r;
    this.prompting = true;
    try {
      r = obj(await this.peer.request('session/prompt', { sessionId: this.sessionId, prompt: blocks }, { timeoutMs: 6 * 3600000 }));
    } catch (e) {
      // (Chat: a tool reached for — the process was killed there and then: the turn ends with what came before it)
      if (this.toolTried) return { stop: 'cancelled', usage: usageOf({}), tried: this.toolTried };
      if (this.unsafe) { this.close(); throw this.unsafeError(); }
      throw e;
    } finally { this.prompting = false; this.flush(); }
    if (this.unsafe) { this.close(); throw this.unsafeError(); }
    const u = obj(r.usage);
    const usage = usageOf({ input: u.inputTokens ?? u.input_tokens, output: u.outputTokens ?? u.output_tokens, cached: u.cachedReadTokens ?? u.cachedInputTokens ?? u.cache_read_input_tokens });
    const stop = ['end_turn', 'max_tokens', 'max_turn_requests', 'refusal', 'cancelled'].includes(r.stopReason) ? r.stopReason : 'end_turn';
    return { stop, usage, ...(this.toolTried ? { tried: this.toolTried } : {}) };
  }

  cancel() { if (this.sessionId) this.peer.notify('session/cancel', { sessionId: this.sessionId }); }
  // Chat: the first sign of a tool — the process (and all it started: its own process group in the sandbox) is killed
  // there and then, not asked to stop, and nothing it says after reaches the answer (notified() drops it)
  stopTool(title) {
    if (this.toolTried) return;
    this.toolTried = title;
    this.log(`${this.tool}: reached for a tool in Chat (${title}): killed`);
    this.peer.kill('SIGKILL');
    // (the turn waits for its end at most TOOL_STOP_MS: what it started may hold its output open)
    setTimeout(() => { if (!this.peer.done) this.peer.drop(); }, this.toolStopMs).unref?.();
  }
  close() { this.peer.kill(); }

  // the text and thinking streamed since the last tool call, as whole blocks (what the history keeps)
  flush() {
    if (this.thought) this.onEvent({ type: 'thinking', text: str(this.thought, DELTA), parent: null });
    if (this.text) this.onEvent({ type: 'text', text: str(this.text, TEXT), model: short(this.model, 128), parent: null });
    this.text = ''; this.thought = '';
  }

  notified(method, p) {
    if (method !== 'session/update' || this.loading || this.toolTried || (this.sessionId && p.sessionId !== this.sessionId)) return;
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
      case 'tool_call_update':
        // Chat: no tool, whatever the agent's own switches let through — the turn is stopped at the first sign of one
        // (before it asks, or runs it), its answer says so, and chat.mjs drops this session (a new one next time)
        if (this.chat) { this.stopTool(short(u.title || u.kind || 'a tool', 120)); return; }
        this.call(u);
        return;
      case 'plan':
        this.flush();
        this.onEvent({ type: 'tool_use', id: callId(`plan-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`), name: 'TodoWrite', input: acpPlan(u.entries), parent: null });
        return;
      case 'available_commands_update':
        this.commands = arr(u.availableCommands).map(obj).filter((c) => typeof c.name === 'string').slice(0, 200).map((c) => short(c.name, 100));
        return;
      case 'current_mode_update':
        if (typeof u.currentModeId !== 'string') return;
        this.mode = short(u.currentModeId, 100);
        this.reported(this.mode);
        return;
      // its config options as they are now (a mode given that way, permissions): the same check
      case 'config_option_update':
        if (this.takeConfig(u.configOptions)) this.reported(this.modeOpt); else this.checkMode();
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
    // Chat: refused without a word to you, and the turn stopped; a session gone to a mode that approves by itself: refused
    if (this.chat) { this.stopTool(short(tc.title || tc.kind || 'a tool', 120)); return pick('reject_once', 'reject_always'); }
    if (this.unsafe) return pick('reject_once', 'reject_always');
    const id = typeof tc.toolCallId === 'string' ? tc.toolCallId : null;
    const merged = { ...(id ? this.calls.get(id) : {}), ...tc };
    if (id && !merged.shown && this.calls.size < 2000) { this.calls.set(id, merged); this.show(id, merged); }
    const kind = typeof merged.kind === 'string' ? merged.kind : 'other';
    const changes = ['edit', 'delete', 'move', 'execute'].includes(kind) || arr(merged.content).some((c) => obj(c).type === 'diff');
    if ((this.pageMode === 'readOnly' || this.pageMode === 'plan') && (changes || !['read', 'search', 'think', 'fetch'].includes(kind))) {
      this.onEvent({ type: 'local', text: `${this.pageMode === 'plan' ? 'Plan' : 'Read only'}: ${short(merged.title || kind, 120)} was refused without asking.` });
      return pick('reject_once', 'reject_always');
    }
    // Accept edits: an edit or a delete goes through without asking only when every path it names is a plain file of
    // the session's folder outside git's and the tools' own configuration (plainEdit) — a move (its destination not
    // always said), a path not named, or anything else: asked
    if (this.pageMode === 'acceptEdits' && ['edit', 'delete'].includes(kind)) {
      const paths = editPaths(merged);
      if (paths && await this.plainEdit(paths)) return pick('allow_once');
    }
    const c = acpCall(merged);
    const answer = await this.onPermission({ tool: c.name, input: c.input, kind, always: opts.some((o) => o.kind === 'allow_always') });
    if (answer === 'always') return pick('allow_always', 'allow_once');
    if (answer === 'once') return pick('allow_once');
    return pick('reject_once', 'reject_always');
  }
}
