// A Code page session with one of your subscriptions' agents (Codex, Copilot, Cursor, Grok): the tool runs in the
// sandbox (bn-coded's agent op), in the session's project folder, on its interface for other apps (acp.mjs, codex.mjs),
// signed in with its own login. To the page it is a session like Claude Code's: the same events (its answers, tool
// cards, to-dos), its permission questions as the same cards (the broker), the watchlist after each turn, the same
// folder's files, Git and Review. What it does not have — Claude Code's commands, plugins, MCP switches, budgets in
// dollars (it runs on your plan: its usage is tokens and the plan's own limits) — is refused with a sentence.
import crypto from 'node:crypto';
import { Ring } from '../ring.mjs';
import { LIMITS, IMAGE_TYPES } from '../protocol.mjs';
import { WS, cwdOk } from '../projects.mjs';
import { short, str } from '../validate.mjs';
import { SessionError } from '../session-error.mjs';
import { SandboxError } from '../spawn-client.mjs';
import { HARNESSES } from './tools.mjs';
import { AcpAgent, NotSignedIn, UnsafeMode } from './acp.mjs';
import { CodexAgent, rateLimits } from './codex.mjs';
import { said } from './jsonrpc.mjs';

// tool names the permission broker and the page treat as Claude Code's own (AskUserQuestion: its answers; ExitPlanMode:
// a plan's approval and a mode switch; the others: cards of their own)
const BROKER_SPECIAL = Object.freeze(['AskUserQuestion', 'ExitPlanMode', 'EnterPlanMode', 'TodoWrite', 'Task', 'Agent', 'Skill', 'SlashCommand']);
// the page's modes an agent session takes (never Auto or Bypass: the tools' own "approve everything" modes are never used)
export const AGENT_MODES = Object.freeze(['readOnly', 'plan', 'default', 'acceptEdits']);
const START_MS = 120000;

// Accept edits: why bn-coded's paths.plain found nothing (or a path) plain, as its code (PLAIN_WHY) — in our words alone;
// what the repository named comes apart, as the sandbox's
export const PLAIN_SAID = Object.freeze({
  'git-config-key': 'Accept edits asks for every edit here: this repository\'s git settings include one that can run a program on your computer.',
  'git-config-syntax': 'Accept edits asks for every edit here: this repository\'s git settings are written in a way the page does not read plainly.',
  'git-unreadable': 'Accept edits asks for every edit here: a part of this repository\'s git folder could not be read whole.',
  'gitdir-outside': 'Accept edits asks for every edit here: this repository\'s git folder is outside the workspace, or reached through a link.',
  'guarded-link': 'Accept edits asks for every edit here: a link is named like git\'s or a tool\'s own folder.',
  'nested-repo': 'Accept edits asks for an edit inside another git repository in this folder (or one that would become one).',
  workspace: 'Accept edits asks for every edit in the Workspace itself (it has no trust step): use a project for edits without asking.',
  'host-outer-repo': 'Accept edits asks for every edit here: a repository around this folder of your computer would not be visible to the page.',
  'too-deep': 'Accept edits asks for an edit deeper than 64 folders.',
  timeout: 'Accept edits asks for the rest of these edits: checking them took too long.',
});

export class AgentSession {
  constructor(mgr, { id, harness, model, mode, cwd = WS, ref = null, title = '', preface = null }) {
    this.mgr = mgr;
    this.id = id;
    this.harness = harness;
    this.info0 = HARNESSES[harness];
    this.cwd = cwdOk(cwd) ? cwd : WS;
    this.model = model || null;
    this.mode = AGENT_MODES.includes(mode) ? mode : 'default';
    this.effort = null; this.budget = null; this.inTerminal = null; this.resetTo = null; this.pendingTitle = null;
    this.ref = ref;            // the tool's own session (thread) id, once it has one
    this.hasTranscript = Boolean(ref);
    this.preface = typeof preface === 'string' && preface ? preface : null;   // the conversation carried over, before the first prompt
    this.title = short(title, 80);
    this.ring = new Ring(); this.epoch = '';
    this.state = 'ended'; this.error = null; this.lastActive = Date.now();
    this.agent = null; this.starting = null; this.queue = []; this.running = false;
    this.models = []; this.usage = { input: 0, output: 0, cached: 0, turns: 0 }; this.limits = null;
    // the watchlist (Session's methods: sessions.mjs lends them)
    this.watchRoot = null; this.watchBase = null; this.watchLast = null; this.watchChain = Promise.resolve(); this.watchOff = false;
    this.reverts = new Map();
  }

  get open() { return this.agent !== null; }
  get name() { return this.info0.name; }

  info() {
    return { id: this.id, state: this.state, model: this.model, mode: this.mode, effort: null, title: this.title, open: this.open,
      pending: this.mgr.broker.forSession(this.id).length, lastActive: this.lastActive, error: this.error, epoch: this.epoch, budget: null,
      terminal: false, cwd: this.cwd, settings: null, harness: this.harness, plan: { ...this.usage, limits: this.limits } };
  }
  settingsInfo() { return null; }

  emit(ev) {
    const seq = this.ring.push(ev);
    this.mgr.onEvent(this, seq, ev);
    this.mgr.agentStore?.append(this.id, ev);
  }
  setState(state, error = null) {
    if (this.state === state && this.error === error) return;
    this.state = state; this.error = error;
    this.mgr.onState(this);
  }
  record(fields = {}) {
    this.mgr.agentStore?.put(this.id, { harness: this.harness, ref: this.ref, cwd: this.cwd, title: this.title, model: this.model, ...fields });
  }

  // --- the tool's process ---
  start() {
    if (this.starting) return this.starting;
    this.mgr.makeRoom(this);
    this.ring = new Ring();
    this.epoch = crypto.randomBytes(4).toString('hex');
    this.setState('starting');
    const wr = this.mgr.watchRootOf?.(this.cwd) ?? null;
    if ((wr?.abs ?? WS) !== (this.watchRoot?.abs ?? WS)) { this.watchBase = null; this.watchLast = null; }
    this.watchRoot = wr;
    this.starting = (async () => {
      let agent = null;
      try {
        // (its folder's own settings, Claude Code's and the other tools': trusted or none — asked anew at every start)
        await this.mgr.agentSettingsCheck?.(this.cwd, this.name);
        const proc = this.mgr.spawnAgent({ tool: this.harness, mode: 'code', cwd: this.cwd },
          { onStderr: (s) => this.mgr.logStderr(this.id, `${this.harness} ${this.id.slice(0, 8)} stderr: ${short(s, 300)}`) });
        const opts = { tool: this.harness, log: (m) => this.mgr.log(`${this.harness} ${this.id.slice(0, 8)}: ${m}`), clientVersion: this.mgr.versions?.server ?? '0',
          onEvent: (ev) => this.fromAgent(agent, ev), onPermission: (p) => this.ask(p), plainEdit: (paths) => this.plainEdit(paths) };
        agent = this.info0.kind === 'codex' ? new CodexAgent(proc, opts) : new AcpAgent(proc, opts);
        this.agent = agent;
        await withTimeout(agent.init(), START_MS, proc);
        const r = await withTimeout(agent.open({ cwd: this.cwd, resume: this.ref, model: this.model }), START_MS, proc);
        if (this.ref && !r.resumed) this.emit({ type: 'local', text: `${this.name} could not take up its earlier conversation: this is a new one in the same folder (the page still shows the earlier one).` });
        this.ref = r.ref; this.hasTranscript = true;
        this.models = agent.models;
        if (this.model && this.model !== agent.model && agent.models.some((m) => m.id === this.model)) await agent.setModel(this.model).catch(() => {});
        else this.model = agent.model ?? this.model;
        await agent.setMode(this.mode);
        // (and once more now it has read them: a change made while it started — what it loaded — is never used)
        await this.mgr.agentSettingsCheck?.(this.cwd, this.name);
        this.record();
        this.emit({ type: 'init', model: short(this.model, 128), cwd: this.cwd, permissionMode: this.mode, cliVersion: short(agent.agentVersion, 40),
          tools: [], commands: agent.commands ?? [], skills: [], plugins: [], mcp: [], effort: null, harness: this.harness,
          models: this.models.map((m) => ({ id: m.id, name: m.name })) });
        agent.closed.then((exit) => { if (this.agent === agent) this.ended(agent, exit); });
        this.setState('idle');
        this.lastActive = Date.now();
      } catch (e) {
        if (this.agent === agent) this.agent = null;
        try { agent?.close(); } catch { /* gone */ }
        if (e instanceof SessionError) { this.setState('ended', e.message); throw e; }
        const why = e instanceof NotSignedIn
          ? `${this.name} is not signed in in the sandbox: open a terminal (Open: ${this.name}) and sign in with its own login, then send your prompt again`
          : e instanceof UnsafeMode ? e.message
            : e instanceof SandboxError || e?.code === -32099 ? `could not start ${this.name}: ${short(e.message, 200)}` : `could not start ${this.name}`;
        this.setState('ended', why);
        const ours = e instanceof NotSignedIn || e instanceof UnsafeMode;
        throw new SessionError(why, ours ? 409 : 502, ours || e instanceof SandboxError ? {} : { said: said(e?.message || String(e), 300), saidBy: 'sandbox' });
      } finally { this.starting = null; }
    })();
    return this.starting;
  }

  // plainEdit(paths) -> whether a change to these paths (absolute, as the agent names them) may go through without
  // asking in Accept edits: each one in the session's folder, outside .git/, .github, .vscode, .claude, .mcp.json and
  // every tool's own configuration, no link on its way, and the repository's git config plainly harmless (bn-coded's
  // paths.plain, in the sandbox — its why, when nothing is plain there, said once in the session). Anything it cannot
  // say: no — the page asks.
  async plainEdit(paths) {
    if (!Array.isArray(paths) || !paths.length || paths.length > 200 || typeof this.mgr.plainPaths !== 'function') return false;
    try {
      const r = await this.mgr.plainPaths(this.cwd, paths);
      // (why, as a code: said once in our own words — what the repository named, apart, as the sandbox's)
      const codes = [r?.why, ...(Array.isArray(r?.each) ? r.each : [])].filter((c) => typeof c === 'string' && Object.hasOwn(PLAIN_SAID, c));
      this.plainSaid ??= new Set();
      for (const c of new Set(codes)) {
        if (this.plainSaid.has(c)) continue;
        this.plainSaid.add(c);
        const detail = c === r.why && typeof r.detail === 'string' ? r.detail.replace(/[^\x20-\x7e]/g, '?').slice(0, 200) : '';
        this.emit({ type: 'local', text: PLAIN_SAID[c], ...(detail ? { said: detail, saidBy: 'sandbox' } : {}) });
      }
      return Array.isArray(r?.plain) && r.plain.length === paths.length && r.plain.every((x) => x === true);
    } catch (e) { this.mgr.log(`${this.harness} ${this.id.slice(0, 8)}: paths not checked (${short(e?.message || String(e), 200)}): asked`); return false; }
  }

  fromAgent(agent, ev) {
    if (this.agent !== agent) return;
    this.lastActive = Date.now();
    this.emit(ev);
  }

  ended(agent, exit) {
    this.agent = null;
    this.mgr.broker.cancelSession(this.id);
    const failed = exit && (exit.signal || (exit.code !== 0 && exit.code !== null));
    if (this.running) this.emit({ type: 'error', message: `${this.name} stopped`, text: `${this.name} stopped` });
    this.setState('ended', failed && this.running ? `${this.name} stopped` : null);
  }

  // a permission question of the tool's: the page's card (Allow once, Always for this session, Deny)
  async ask({ tool: asked, input, always }) {
    // (the broker's own tools — a plan's approval, a question's answers, Claude Code's tools — never named by an agent:
    // whatever it says, such a name is an agent tool's, prefixed)
    const tool = BROKER_SPECIAL.includes(asked) ? `Tool: ${asked}` : asked;
    // "Always": the tool's own "allow always" for this kind of call — shown as <tool>:<call> (no rule file of Claude Code's)
    const sugg = always ? [{ type: 'addRules', rules: [{ toolName: `${this.harness}:${short(tool, 100)}`.replace(/[^A-Za-z0-9_.:*-]/g, '_').slice(0, 200) }], behavior: 'allow', destination: 'session' }] : [];
    const r = await this.mgr.broker.ask(this.id, tool, input, { suggestions: sugg });
    if (r?.behavior !== 'allow') return 'deny';
    return Array.isArray(r.updatedPermissions) && r.updatedPermissions.length ? 'always' : 'once';
  }

  /** A prompt typed in the page: queued behind a turn under way; the tool started first when it is not running. */
  prompt({ text, images = [], uuid }) {
    if (typeof text !== 'string' || !text.trim() || text.length > LIMITS.maxPromptChars) throw new SessionError('empty or too long prompt');
    if (!Array.isArray(images) || images.length > LIMITS.maxImages) throw new SessionError(`at most ${LIMITS.maxImages} images`);
    for (const im of images) {
      if (!im || !IMAGE_TYPES.includes(im.media_type) || typeof im.data !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(im.data)) throw new SessionError('bad image');
      if (im.data.length * 3 / 4 > LIMITS.maxImageBytes) throw new SessionError('image too large');
    }
    if (text.startsWith('/')) throw new SessionError(`${this.name} sessions have no slash commands here: type your request in words (its own commands work in the terminal)`);
    const id = /^[0-9a-f-]{36}$/.test(String(uuid)) ? uuid : crypto.randomUUID();
    if (!this.title) { this.title = short(text, 80); this.record(); }
    this.queue.push({ text, images: images.map((im) => ({ media_type: im.media_type, data: im.data })) });
    this.emit({ type: 'user', text: str(text, 200000), uuid: id, images: images.length });
    this.setState('busy');
    this.lastActive = Date.now();
    void this.drain();
  }

  async drain() {
    if (this.running) return;
    this.running = true;
    try {
      while (this.queue.length) {
        const next = this.queue.shift();
        const t0 = Date.now();
        try {
          if (!this.agent) await this.start();
          else {
            // (its folder's own settings, asked again before every turn: changed or no longer trusted since it started — a
            // pull, an edit, Stop trusting —, the tool ends here, before it reads them again)
            try { await this.mgr.agentSettingsCheck?.(this.cwd, this.name); } catch (e) { this.close('settings'); throw e; }
          }
          this.setState('busy');
          if (this.mgr.watcher && !this.watchOff) await this.watchStart();
          const text = this.preface ? `${this.preface}\n\n${next.text}` : next.text;
          this.preface = null;
          const r = await this.agent.prompt(text, next.images);
          this.usage.input += r.usage.input_tokens; this.usage.output += r.usage.output_tokens; this.usage.cached += r.usage.cache_read_input_tokens; this.usage.turns++;
          if (this.info0.kind === 'codex' && this.agent?.limits) this.limits = this.agent.limits;
          if (r.stop === 'error') this.emit({ type: 'error', message: `${this.name} reported an error`, text: `${this.name} reported an error`, said: said(r.error, 300), saidBy: 'claude' });
          this.emit({ type: 'result', subtype: r.stop === 'error' ? 'error_during_execution' : r.stop === 'cancelled' ? 'other' : 'success', is_error: r.stop === 'error',
            turns: 1, duration: Date.now() - t0, usage: r.usage, consumed: [], text: r.stop === 'cancelled' ? 'Stopped.' : r.stop === 'refusal' ? `${this.name} declined to answer.` : '' });
          this.record();
        } catch (e) {
          const msg = e instanceof SessionError || e instanceof UnsafeMode ? e.message : `${this.name}: ${short(e?.message || String(e), 300)}`;
          this.emit({ type: 'error', message: msg, text: msg, ...(e?.said ? { said: e.said, saidBy: e.saidBy } : {}) });
          this.emit({ type: 'result', subtype: 'error_during_execution', is_error: true, turns: 0, duration: Date.now() - t0, usage: null, consumed: [], text: '' });
        } finally {
          if (this.mgr.watcher && !this.watchOff) this.watchEnd();
        }
      }
    } finally {
      this.running = false;
      if (this.state === 'busy' || this.state === 'starting') this.setState(this.agent ? 'idle' : 'ended', this.agent ? null : this.error);
      this.mgr.onState(this);
    }
  }

  need() { throw new SessionError(`not offered for ${this.name} sessions (it is Claude Code's)`, 409); }
  // (what the page and the server ask of every session, which has no meaning here)
  noteSpent() {}
  budgetRestart() { return false; }
  settingsRestart() { return false; }
  gitRestart() { return false; }
  get exited() { return this.agent ? this.agent.closed : Promise.resolve(); }
  async mcpReconnect() { this.need(); }
  async mcpToggle() { this.need(); }
  async rewindFiles() { this.need(); }
  async reloadPlugins() { this.need(); }
  async interrupt() { this.queue = []; this.agent?.cancel(); }
  status() { this.emit({ type: 'status', status: '', permissionMode: this.mode, model: this.model }); this.mgr.onState(this); }
  async setModel(model) {
    if (typeof model !== 'string' || !/^[\x21-\x7e]{1,200}$/.test(model)) throw new SessionError('bad model');
    if (this.agent) {
      try { await this.agent.setModel(model); } catch (e) { throw new SessionError(short(e?.message || String(e), 300), 409); }
    } else if (this.models.length && !this.models.some((m) => m.id === model)) throw new SessionError(`${this.name} does not offer that model here`);
    this.model = model;
    this.record();
    this.status();
  }
  async setMode(raw) {
    const mode = raw === 'dontAsk' ? 'readOnly' : raw;
    if (!AGENT_MODES.includes(mode)) throw new SessionError(`${this.name} sessions take Read only, Plan, Manual or Accept edits`);
    this.mode = mode;
    if (this.agent) await this.agent.setMode(mode).catch(() => null);
    this.status();
    return { mode };
  }
  async setEffort() { throw new SessionError(`${this.name} sessions have no effort setting here`); }
  setBudget() { throw new SessionError(`${this.name} sessions run on ${this.info0.plan}: no budget in dollars (its usage counts against the plan's own limits)`, 409); }
  allowBlocked() { throw new SessionError(`not offered for ${this.name} sessions`, 409); }
  async toTerminal() { throw new SessionError(`${this.name} sessions are not handed to the terminal yet: open ${this.name} there and resume it with its own command`, 409); }
  async stopTask() { throw new SessionError(`not offered for ${this.name} sessions`, 409); }

  close(reason = 'closed') {
    const a = this.agent;
    if (!a) return;
    this.agent = null; this.queue = [];
    this.mgr.broker.cancelSession(this.id);
    try { a.close(); } catch { /* gone */ }
    this.emit({ type: 'local', text: reason === 'idle' ? `Closed after ${LIMITS.idleMinutes} idle minutes; your next prompt takes it up again.`
      : reason === 'settings' ? `${this.name} ended: its folder's own settings changed or are no longer trusted.` : `${this.name} closed; a prompt takes it up again.` });
    this.setState('ended');
  }
}

function withTimeout(p, ms, proc) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => { try { proc?.kill?.('SIGTERM'); } catch { /* gone */ } reject(new Error(`no answer in ${ms / 1000} s`)); }, ms);
    t.unref?.();
    p.then((v) => { clearTimeout(t); resolve(v); }, (e) => { clearTimeout(t); reject(e); });
  });
}

export { rateLimits };
