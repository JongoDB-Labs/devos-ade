// The Code page's record of its sessions with your subscriptions' agents (Codex, Copilot, Cursor, Grok): which tool,
// its own session (or thread) id, the folder, a title — and what the page showed of each (its finished blocks: your
// prompts, the answers, the tool cards; never the streaming pieces), so its history opens without starting the tool.
// The tool keeps its own record of the conversation in the sandbox (its resume uses that); this one is the page's.
// Kept in this container's own volume (code-state: /var/lib/bn-code/agents/, a folder of mode 700, files of mode 600),
// at most MAX_SESSIONS sessions (the oldest go) and MAX_BYTES of events each (the oldest go).
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { STATE_DIR } from '../githosts.mjs';
import { isUuid, short } from '../validate.mjs';
import { harnessOk } from './tools.mjs';

export const MAX_SESSIONS = 300, MAX_BYTES = 2 << 20;
const KEPT = new Set(['user', 'text', 'thinking', 'tool_use', 'tool_result', 'result', 'local', 'error', 'watch']);
const REF = /^[\x21-\x7e]{1,200}$/;

export class AgentStore {
  constructor({ dir = path.join(STATE_DIR, 'agents'), now = () => Date.now() } = {}) {
    this.dir = dir; this.now = now;
    this.index = null;   // id -> row, read on first use
  }

  load() {
    if (this.index) return this.index;
    this.index = new Map();
    let rows = [];
    try { rows = JSON.parse(fs.readFileSync(path.join(this.dir, 'index.json'), 'utf8')); } catch { rows = []; }
    for (const r of Array.isArray(rows) ? rows : []) {
      if (r && isUuid(r.id) && harnessOk(r.harness) && r.harness !== 'bedrock' && (r.ref === null || REF.test(r.ref)) && typeof r.cwd === 'string') {
        this.index.set(r.id, { id: r.id, harness: r.harness, ref: r.ref, cwd: r.cwd, title: short(r.title, 200), model: short(r.model, 200) || null,
          created: Number(r.created) || 0, modified: Number(r.modified) || 0, size: Number(r.size) || 0 });
      }
    }
    return this.index;
  }

  save() {
    fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    const tmp = path.join(this.dir, `.index-${crypto.randomBytes(6).toString('hex')}`);
    fs.writeFileSync(tmp, JSON.stringify([...this.load().values()]), { mode: 0o600, flag: 'wx' });
    fs.renameSync(tmp, path.join(this.dir, 'index.json'));
  }

  list() { return [...this.load().values()].sort((a, b) => b.modified - a.modified); }
  get(id) { return isUuid(id) ? this.load().get(id) ?? null : null; }

  /** a session's row, made or changed (fields: harness, ref, cwd, title, model) */
  put(id, fields) {
    if (!isUuid(id)) return null;
    const idx = this.load();
    const now = this.now();
    const row = { ...(idx.get(id) ?? { id, created: now, size: 0, title: '', model: null, ref: null }), ...fields, modified: now };
    idx.set(id, row);
    // the oldest go (and their events)
    if (idx.size > MAX_SESSIONS) for (const r of [...idx.values()].sort((a, b) => a.modified - b.modified).slice(0, idx.size - MAX_SESSIONS)) this.remove(r.id, { save: false });
    try { this.save(); } catch { /* best effort: the next change writes it again */ }
    return row;
  }

  file(id) { return path.join(this.dir, `${id}.jsonl`); }

  /** one finished event of the page's, kept for the session's history */
  append(id, ev) {
    if (!isUuid(id) || !ev || !KEPT.has(ev.type)) return;
    const row = this.load().get(id);
    if (!row) return;
    const line = `${JSON.stringify(ev)}\n`;
    try {
      fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
      fs.appendFileSync(this.file(id), line, { mode: 0o600 });
      row.size += line.length;
      if (row.size > MAX_BYTES) this.trim(id, row);
    } catch { /* best effort */ }
  }

  // the oldest events go until the file is at most three quarters of MAX_BYTES
  trim(id, row) {
    const lines = fs.readFileSync(this.file(id), 'utf8').split('\n').filter(Boolean);
    let size = lines.reduce((n, l) => n + l.length + 1, 0);
    while (lines.length && size > (MAX_BYTES * 3) / 4) size -= lines.shift().length + 1;
    const tmp = path.join(this.dir, `.trim-${crypto.randomBytes(6).toString('hex')}`);
    fs.writeFileSync(tmp, lines.map((l) => `${l}\n`).join(''), { mode: 0o600, flag: 'wx' });
    fs.renameSync(tmp, this.file(id));
    row.size = size;
    row.truncated = true;
  }

  /** -> {events, truncated} (the page's history of it) */
  events(id) {
    const row = this.get(id);
    if (!row) return null;
    let text = '';
    try { text = fs.readFileSync(this.file(id), 'utf8'); } catch { text = ''; }
    const events = [];
    for (const l of text.split('\n')) {
      if (!l) continue;
      try { const e = JSON.parse(l); if (e && typeof e === 'object' && KEPT.has(e.type)) events.push(e); } catch { /* a cut line */ }
    }
    return { events, truncated: row.truncated === true };
  }

  remove(id, { save = true } = {}) {
    if (!isUuid(id)) return;
    this.load().delete(id);
    try { fs.unlinkSync(this.file(id)); } catch { /* none */ }
    if (save) { try { this.save(); } catch { /* best effort */ } }
  }
}
