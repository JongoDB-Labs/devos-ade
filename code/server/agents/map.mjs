// What a tool of your subscriptions says, as the page's events (protocol.mjs; the same shapes normalize.mjs makes of
// Claude Code's): ACP's session/update and Codex's item notifications. All of it is the sandbox's: every field is
// checked or capped, anything unknown is dropped. Tool calls get the page's own card names where the call is plainly
// one of them (a command: Bash; a file's change with its old and new text: Edit or Write; a read: Read …), else the
// tool's own title.
import crypto from 'node:crypto';
import { str, short, plain, int } from '../validate.mjs';

const TEXT = 200000, DELTA = 100000, RESULT = 100000, LABEL = 200, PATH = 4096;
const obj = (v) => (v !== null && typeof v === 'object' && !Array.isArray(v) ? v : {});
const arr = (v) => (Array.isArray(v) ? v : []);
// a tool call's id as the page keys its cards (validate.mjs ID_RE): the tool's own when it fits, else one made of it
export const callId = (v) => {
  if (typeof v !== 'string' || !v || v.length > 1000) return null;
  return /^[A-Za-z0-9_-]{1,128}$/.test(v) ? v : `c${crypto.createHash('sha256').update(v).digest('hex').slice(0, 40)}`;
};

// contentText(blocks) -> the text of ACP content blocks (or tool call contents): text as it is, anything else named
export function contentText(list, max = RESULT) {
  const out = [];
  for (const b of arr(list).slice(0, 200)) {
    const x = obj(b);
    if (x.type === 'text' && typeof x.text === 'string') out.push(x.text);
    else if (x.type === 'content') out.push(contentText([x.content], max));
    else if (x.type === 'diff') out.push(`[change: ${short(x.path, 300)}]`);
    else if (x.type === 'resource_link') out.push(`[${short(x.name || x.uri, 300)}]`);
    else if (x.type === 'resource' && typeof obj(x.resource).text === 'string') out.push(obj(x.resource).text);
    else if (x.type === 'terminal') out.push('[terminal]');
    else if (typeof x.type === 'string') out.push(`[${short(x.type, 40)}]`);
  }
  return str(out.join('\n'), max);
}

const firstString = (o, keys) => { for (const k of keys) if (typeof o[k] === 'string' && o[k]) return o[k]; return ''; };
// commandOf(raw) -> the command an execute call runs, as one string (a list joined with spaces), or ''
function commandOf(raw) {
  const r = obj(raw);
  const c = r.command ?? r.cmd ?? r.commandLine;
  if (typeof c === 'string') return c;
  if (Array.isArray(c) && c.every((x) => typeof x === 'string')) return c.join(' ');
  return '';
}

// acpCall(state) -> {name, input} of an ACP tool call (its merged tool_call / tool_call_update fields)
export function acpCall(tc) {
  const t = obj(tc);
  const raw = obj(t.rawInput);
  const title = short(t.title, LABEL);
  const kind = typeof t.kind === 'string' ? t.kind : '';
  const diffs = arr(t.content).map(obj).filter((c) => c.type === 'diff' && typeof c.path === 'string' && typeof c.newText === 'string');
  const loc = arr(t.locations).map(obj).find((l) => typeof l.path === 'string');
  if (diffs.length && ['edit', 'delete', 'move', 'other', ''].includes(kind)) {
    const d = diffs[0];
    const more = diffs.length > 1 ? { more: diffs.slice(1, 50).map((x) => short(x.path, PATH)) } : {};
    if (typeof d.oldText !== 'string') return { name: 'Write', input: { file_path: short(d.path, PATH), content: str(d.newText, TEXT), ...more } };
    return { name: 'Edit', input: { file_path: short(d.path, PATH), old_string: str(d.oldText, TEXT), new_string: str(d.newText, TEXT), ...more } };
  }
  if (kind === 'execute') {
    const cmd = commandOf(raw);
    if (cmd) return { name: 'Bash', input: { command: str(cmd, 20000), ...(title ? { description: title } : {}) } };
  }
  if (kind === 'read') {
    const p = firstString(raw, ['path', 'file_path', 'filePath', 'file']) || loc?.path || '';
    if (p) return { name: 'Read', input: { file_path: short(p, PATH) } };
  }
  if (kind === 'search') {
    const q = firstString(raw, ['pattern', 'query', 'regex', 'glob']);
    if (q) return { name: 'Grep', input: { pattern: short(q, 2000), ...(typeof raw.path === 'string' ? { path: short(raw.path, PATH) } : {}) } };
  }
  if (kind === 'fetch') {
    const u = firstString(raw, ['url', 'uri']);
    if (u) return { name: 'WebFetch', input: { url: short(u, 4000) } };
    const q = firstString(raw, ['query', 'q']);
    if (q) return { name: 'WebSearch', input: { query: short(q, 2000) } };
  }
  return { name: title || (kind ? `${kind[0].toUpperCase()}${kind.slice(1, 40)}` : 'Tool'), input: plain(Object.keys(raw).length ? raw : { title }, 64 << 10) };
}

// acpPlan(entries) -> the page's to-do card input (TodoWrite's shape)
export function acpPlan(entries) {
  const st = (s) => (s === 'completed' ? 'completed' : s === 'in_progress' ? 'in_progress' : 'pending');
  return { todos: arr(entries).slice(0, 100).map(obj).filter((e) => typeof e.content === 'string')
    .map((e) => ({ content: short(e.content, 1000), status: st(e.status), activeForm: short(e.content, 1000) })) };
}

// parseDiff(text) -> unified-diff hunks as the page's edit cards take them ({oldStart, oldLines, newStart, newLines,
// lines}); complete false when something was cut
export function parseDiff(text, maxChars = 200000) {
  const hunks = [];
  let cur = null, left = maxChars, complete = true;
  for (const line of String(text ?? '').split('\n').slice(0, 20000)) {
    const h = /^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@/.exec(line);
    if (h) {
      if (hunks.length >= 500) { complete = false; break; }
      cur = { oldStart: Number(h[1]), oldLines: h[2] === undefined ? 1 : Number(h[2]), newStart: Number(h[3]), newLines: h[4] === undefined ? 1 : Number(h[4]), lines: [] };
      hunks.push(cur);
      continue;
    }
    if (!cur || !/^[ +\\-]/.test(line) || line.startsWith('\\')) continue;
    if (left - line.length < 0) { complete = false; break; }
    left -= line.length + 1;
    cur.lines.push(str(line, 4000));
  }
  return { hunks, complete };
}

const CODEX_STATUS_ERR = ['failed', 'declined'];
// codexStarted(item) -> page events for an item Codex started (tool calls; messages come whole at their end)
export function codexStarted(item) {
  const it = obj(item), id = callId(it.id);
  if (!id) return [];
  switch (it.type) {
    case 'commandExecution':
      return [{ type: 'tool_use', id, name: 'Bash', input: { command: str(it.command, 20000), ...(typeof it.cwd === 'string' ? { description: `in ${short(it.cwd, 300)}` } : {}) }, parent: null }];
    case 'fileChange':
      return arr(it.changes).slice(0, 50).map(obj).filter((c) => typeof c.path === 'string').map((c, i) => ({
        type: 'tool_use', id: callId(`${id}_${i}`), name: obj(c.kind).type === 'add' ? 'Write' : 'Edit',
        input: { file_path: short(c.path, PATH), ...(obj(c.kind).type === 'add' ? { content: '' } : {}) }, parent: null }));
    case 'mcpToolCall':
      return [{ type: 'tool_use', id, name: `mcp__${short(it.server, 60).replace(/[^A-Za-z0-9_-]/g, '_')}__${short(it.tool, 60).replace(/[^A-Za-z0-9_-]/g, '_')}`, input: plain(it.arguments ?? {}, 64 << 10), parent: null }];
    case 'webSearch':
      return [{ type: 'tool_use', id, name: 'WebSearch', input: { query: short(it.query, 2000) }, parent: null }];
    default: return [];
  }
}
// codexCompleted(item, model) -> page events for an item Codex finished
export function codexCompleted(item, model = '') {
  const it = obj(item), id = callId(it.id);
  switch (it.type) {
    case 'agentMessage': return typeof it.text === 'string' && it.text ? [{ type: 'text', text: str(it.text, TEXT), model: short(model, 128), parent: null }] : [];
    case 'reasoning': {
      const t = [...arr(it.summary), ...arr(it.content)].filter((x) => typeof x === 'string').join('\n\n');
      return t ? [{ type: 'thinking', text: str(t, DELTA), parent: null }] : [];
    }
    case 'commandExecution': {
      if (!id) return [];
      const out = typeof it.aggregatedOutput === 'string' ? it.aggregatedOutput : '';
      const code = int(it.exitCode, -1e6, 1e6);
      const err = CODEX_STATUS_ERR.includes(it.status) || (code !== null && code !== 0);
      const note = it.status === 'declined' ? '(declined)' : code !== null && code !== 0 ? `(exit code ${code})` : '';
      return [{ type: 'tool_result', id, text: str([out, note].filter(Boolean).join('\n'), RESULT), is_error: err, parent: null }];
    }
    case 'fileChange': {
      if (!id) return [];
      const err = CODEX_STATUS_ERR.includes(it.status);
      return arr(it.changes).slice(0, 50).map(obj).filter((c) => typeof c.path === 'string').map((c, i) => {
        const d = parseDiff(c.diff);
        return { type: 'tool_result', id: callId(`${id}_${i}`), text: err ? `(${short(it.status, 20)})` : '', is_error: err, parent: null,
          edit: { path: short(c.path, PATH), original: null, hunks: d.hunks, complete: d.complete, created: obj(c.kind).type === 'add' } };
      });
    }
    case 'mcpToolCall': {
      if (!id) return [];
      const e = obj(it.error), r = obj(it.result);
      const text = typeof e.message === 'string' ? e.message : contentText(r.content);
      return [{ type: 'tool_result', id, text: str(text, RESULT), is_error: it.status === 'failed' || typeof e.message === 'string', parent: null }];
    }
    case 'webSearch': return id ? [{ type: 'tool_result', id, text: '', is_error: false, parent: null }] : [];
    default: return [];
  }
}

// codexPlan(params) -> the page's to-do card input from turn/plan/updated ({plan: [{step, status}]})
export function codexPlan(p) {
  const st = (s) => (s === 'completed' ? 'completed' : s === 'inProgress' || s === 'in_progress' ? 'in_progress' : 'pending');
  return { todos: arr(obj(p).plan).slice(0, 100).map(obj).filter((e) => typeof e.step === 'string')
    .map((e) => ({ content: short(e.step, 1000), status: st(e.status), activeForm: short(e.step, 1000) })) };
}

// usage of a turn in the page's shape (normalize.mjs usage()): input / output tokens and the cached part
export function usageOf({ input = 0, output = 0, cached = 0 } = {}) {
  const n = (v) => int(v, 0, 1e12) ?? 0;
  return { input_tokens: n(input), output_tokens: n(output), cache_read_input_tokens: n(cached), cache_creation_input_tokens: 0 };
}
