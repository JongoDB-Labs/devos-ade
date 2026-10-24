// One JSON-RPC connection over a process's stdin/stdout, a JSON object per line: the interface for other apps that the
// tools of your subscriptions speak (ACP: Copilot, Cursor, Grok; Codex's app server, the same shapes without the
// "jsonrpc" member). Everything that comes back is the sandbox's: a line longer than maxLine ends the process, an
// answer must match a request of ours, the tool's own requests get an answer only from onRequest (anything else:
// "not supported"), and at most MAX_THEIRS of them wait at once.
export class RpcError extends Error {
  constructor(code, message, data = null) {
    super(message);
    this.code = Number.isInteger(code) ? code : -32603;
    this.data = data;
  }
}

export const MAX_LINE = 16 << 20;
const MAX_THEIRS = 16;
const ENDED = -32099;

const plainObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
// (a message's text as it may be logged or shown: one line of printable characters, cut short)
export const said = (v, n = 300) => String(v ?? '').replace(/[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g, ' ').trim().slice(0, n);

export class Peer {
  /** proc: {stdin, stdout, on('exit'), kill()} (spawn-client's sandboxAgent). jsonrpc: send the "jsonrpc" member. */
  constructor(proc, { jsonrpc = true, onNotify = () => {}, onRequest = null, log = () => {}, maxLine = MAX_LINE } = {}) {
    Object.assign(this, { proc, jsonrpc, onNotify, onRequest, log, maxLine });
    this.next = 1;
    this.pending = new Map();   // id -> {resolve, reject, timer, method}
    this.theirs = 0;
    this.buf = '';
    this.done = false;
    this.exit = null;
    this.closed = new Promise((r) => { this.closedResolve = r; });
    proc.stdout.setEncoding?.('utf8');
    proc.stdout.on('data', (d) => this.data(typeof d === 'string' ? d : d.toString('utf8')));
    proc.stdout.on('error', () => {});
    proc.stdin.on?.('error', () => {});
    proc.on('exit', (code, signal) => this.ended({ code, signal }));
    proc.on('error', (e) => this.ended({ code: null, signal: null, error: e }));
  }

  data(s) {
    if (this.done) return;
    this.buf += s;
    let i;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 1);
      if (line.trim()) this.line(line);
      if (this.done) return;
    }
    if (this.buf.length > this.maxLine) {
      this.log(`an over-long line from the tool (${this.buf.length} characters): stopped`);
      this.kill();
    }
  }

  line(line) {
    let m;
    try { m = JSON.parse(line); } catch { this.log(`not JSON from the tool: ${said(line, 120)}`); return; }
    if (!plainObj(m)) return;
    const hasId = typeof m.id === 'number' || typeof m.id === 'string';
    if (typeof m.method === 'string') {
      if (hasId) this.theirRequest(m);
      else {
        try { this.onNotify(m.method, plainObj(m.params) ? m.params : {}); } catch (e) { this.log(`${said(m.method, 60)}: ${said(e?.message || e)}`); }
      }
      return;
    }
    if (!hasId) return;
    const p = this.pending.get(m.id);
    if (!p) return;   // (an answer to nothing of ours)
    this.pending.delete(m.id);
    clearTimeout(p.timer);
    if (plainObj(m.error)) p.reject(new RpcError(m.error.code, said(m.error.message || 'error', 500), m.error.data ?? null));
    else p.resolve(m.result);
  }

  async theirRequest(m) {
    const answer = (body) => this.send({ id: m.id, ...body });
    if (!this.onRequest || this.theirs >= MAX_THEIRS) { answer({ error: { code: -32601, message: 'not supported here' } }); return; }
    this.theirs++;
    try {
      const result = await this.onRequest(m.method, plainObj(m.params) ? m.params : {});
      answer({ result: result === undefined ? null : result });
    } catch (e) {
      answer({ error: { code: e instanceof RpcError ? e.code : -32603, message: e instanceof RpcError ? e.message : 'refused' } });
    } finally { this.theirs--; }
  }

  send(msg) {
    if (this.done) return false;
    try { this.proc.stdin.write(`${JSON.stringify(this.jsonrpc ? { jsonrpc: '2.0', ...msg } : msg)}\n`); return true; } catch { return false; }
  }

  /** -> the result; rejects with RpcError (the tool's error, a timeout, the process ended) */
  request(method, params = {}, { timeoutMs = 120000 } = {}) {
    if (this.done) return Promise.reject(new RpcError(ENDED, 'the tool is not running'));
    const id = this.next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new RpcError(-32098, `${method}: no answer in ${Math.round(timeoutMs / 1000)} s`)); }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, timer, method });
      if (!this.send({ id, method, params })) { this.pending.delete(id); clearTimeout(timer); reject(new RpcError(ENDED, 'the tool is not running')); }
    });
  }

  notify(method, params = {}) { return this.send({ method, params }); }

  ended(info) {
    if (this.done) return;
    this.done = true;
    this.exit = info;
    for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(new RpcError(ENDED, 'the tool ended')); }
    this.pending.clear();
    this.closedResolve(info);
  }

  kill(signal = 'SIGTERM') {
    try { this.proc.kill(signal); } catch { /* gone */ }
    try { this.proc.stdin.end(); } catch { /* gone */ }
  }
  // drop() — no more waiting for the tool: its connection to the sandbox closed (bn-coded kills what is left), and
  // every request still waiting ended now
  drop() {
    try { this.proc.destroy?.(); } catch { /* gone */ }
    this.ended({ code: null, signal: 'SIGKILL', dropped: true });
  }
}
// Chat: how long a turn waits after a tool's first sign for the killed agent's end (bn-coded's EXIT) before it stops
// waiting — what the agent started could hold its output open
export const TOOL_STOP_MS = 10000;

export const isEnded = (e) => e instanceof RpcError && e.code === ENDED;
