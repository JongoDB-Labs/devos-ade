// A project's own Claude Code configuration: everything under its .claude/ — settings.json and settings.local.json
// (hooks, permission rules, env, a default mode, helper commands …), and the skills, commands, agents, output styles …
// whose front matter can grant tools (allowed-tools), declare hooks or MCP servers — and .mcp.json (MCP servers it
// starts). Claude Code started by the SDK applies what it finds in its folder with no trust step (the terminal's claude
// asks whether to trust a folder first): a cloned repository's SessionStart hook would run, its allow rules or a skill's
// allowed-tools would silence the page's permission cards. So a session in a project's folder starts with your own
// settings only (the sandbox's ~/.claude) — and only the stack's own MCP server — until you trusted exactly these files:
// the page shows what they set, and the project's record keeps their hash (bn-coded's project.settings). Changed since
// (a pull adding an agent): not applied again until you look again. A folder with neither a .claude/ holding a file nor
// a .mcp.json needs nothing (a lone CLAUDE.md is read as instructions; it grants nothing). The Workspace (/workspace
// itself) keeps applying its own, as before projects: it is the folder you chose for the sandbox. Everything here came
// from the sandbox: shown as text, capped.
// Other tools' configuration in the folder (.codex/, .cursor/, .grok/, .gemini/, .copilot/, .agents/, everything of
// .github/ but files GitHub alone reads, a lsp.json, .vscode/mcp.json, Claude Code's plugins; and above it to the git
// root, with the .claude/ settings and plugins Grok and Copilot load there: placeOf) is listed and hashed with it — one
// trust for the folder — and shown whole: your subscriptions' agents read it as it is, with no flag that turns it off, so an
// agent session starts in a project's folder only while that trust holds (SessionManager.agentSettingsCheck).
import crypto from 'node:crypto';
import { short, str } from './validate.mjs';
import { WS, WORKSPACE_ID, absOf, TRUST_EPOCH } from './projects.mjs';

export const ALL_SOURCES = Object.freeze(['user', 'project', 'local']);
export const USER_SOURCES = Object.freeze(['user']);
const SHA = /^[0-9a-f]{64}$/;
export const SETTINGS_FILES = Object.freeze(['.claude/settings.json', '.claude/settings.local.json']);
const TYPES = ['file', 'link', 'big', 'other'];
export const FILES_MAX = 500;
// a name bn-coded may list (bn-coded from before rows said where they came from): the project's own .mcp.json, its
// .claude (a link, not a folder) or a path under it — relative —, or a path under a .claude above it, absolute in
// /workspace; one line, no "." or ".." part
const segsOk = (segs) => segs.every((x) => x !== '' && x !== '.' && x !== '..');
const legacyNameOk = (n) => n.toLowerCase() === '.mcp.json'
  || (!n.startsWith('/') && n.split('/')[0].toLowerCase() === '.claude' && segsOk(n.split('/')))
  || (n.startsWith(`${WS}/`) && n.slice(WS.length + 1).toLowerCase().split('/').includes('.claude') && segsOk(n.slice(WS.length + 1).split('/')));
// Where a row came from, as bn-coded says (at: '' for the project's folder itself, else the folder above it that was
// read; surface: what was read there, named as in that folder) — checked against the row's name and the project's
// folder, and the only thing that says whose configuration a row is: never a search of its name. The surfaces, in
// lower case, and whose they are (null: Claude Code's): the .claude/ tree (above the folder: its six trees, or a
// .claude that is no folder), .mcp.json, and the other tools' (bn-coded's AGENT_TREES …: your subscriptions' agents
// read them, in the folder and above it to the git root).
const CLAUDE_TREES = ['commands', 'agents', 'output-styles', 'skills', 'workflows', 'routines'];
const AGENT_TOOLS_OF = { '.codex': 'Codex', '.cursor': 'Cursor', '.grok': 'Grok', '.gemini': 'Gemini CLI', '.copilot': 'GitHub Copilot',
  '.agents': 'Codex, Cursor, Grok and GitHub Copilot' };
// Claude Code plugins and settings other tools load: a project's own .claude/plugins/ (Grok: their hooks, .mcp.json and
// .lsp.json), and above it .claude/settings*.json and .claude/plugins/ (Grok and Copilot read them there; Claude Code
// does not)
const CLAUDE_PLUGINS = 'Grok and GitHub Copilot (Claude Code plugins)', CLAUDE_ABOVE = 'Grok and GitHub Copilot';
// surfaceOf(kind, above) -> {tool, single} for a surface bn-coded lists (single: one entry, a file or a link — the row's
// name is the surface itself), or undefined
function surfaceOf(kind, above) {
  if (kind === '.claude') return { tool: null, single: above };   // (above: a .claude that is no folder, as an entry of its own)
  if (kind.startsWith('.claude/')) {
    if (!above) return undefined;   // (the project's own .claude/ is read whole: its surface is .claude)
    const t = kind.slice(8);
    if (CLAUDE_TREES.includes(t)) return { tool: null, single: false };
    if (t === 'plugins') return { tool: CLAUDE_PLUGINS, single: false };
    if (t === 'settings.json' || t === 'settings.local.json') return { tool: CLAUDE_ABOVE, single: true };
    return undefined;
  }
  if (kind === '.mcp.json') return { tool: above ? 'other tools (a folder above)' : null, single: true };
  if (Object.hasOwn(AGENT_TOOLS_OF, kind)) return { tool: AGENT_TOOLS_OF[kind], single: false };
  if (kind === '.github') return { tool: 'GitHub Copilot', single: true };
  if (/^\.github\/[^/]+$/.test(kind)) return { tool: 'GitHub Copilot', single: false };
  if (kind === '.vscode' || kind === '.vscode/mcp.json') return { tool: 'VS Code (older GitHub Copilot CLIs)', single: true };
  if (kind === 'lsp.json' || kind === '.lsp.json') return { tool: 'GitHub Copilot and Grok', single: true };
  return undefined;
}
/** placeOf(row, root) -> {tool} (whose configuration it is; null: Claude Code's), or null when the row's at, surface and
 *  name do not fit together for a project in root — then nothing of the listing can be trusted */
export function placeOf(f, root) {
  if (typeof f.surface !== 'string' || typeof f.at !== 'string' || f.surface.length > 300 || f.at.length > 1024 || !segsOk(f.surface.split('/'))) return null;
  const kind = f.surface.toLowerCase();
  const s = surfaceOf(kind, f.at !== '');
  if (!s) return null;
  if (f.at !== '') {
    // a real folder above the project's, in the workspace (the workspace itself included)
    if (!(f.at === WS || (f.at.startsWith(`${WS}/`) && segsOk(f.at.slice(WS.length + 1).split('/')))) || typeof root !== 'string' || !root.startsWith(`${f.at}/`)) return null;
  }
  const base = f.at ? `${f.at}/${f.surface}` : f.surface;
  if (s.single ? f.name !== base : f.name !== base && !f.name.startsWith(`${base}/`)) return null;
  if (!segsOk(f.name.slice(f.at ? f.at.length + 1 : 0).split('/'))) return null;
  // (the project's own .claude/plugins/: other tools load them — shown whole, as theirs)
  if (kind === '.claude' && f.at === '' && f.name.toLowerCase().startsWith('.claude/plugins/')) return { tool: CLAUDE_PLUGINS };
  return { tool: s.tool };
}

/** checkFiles(project.settings' RESULT, root) -> {files: [{name, type, size, sha256, target, text, at, tool}], ok}: ok
 *  false when the list does not fit what bn-coded lists for a project in root (a bad name, a row whose place does not
 *  fit its name, rows that say where they came from beside rows that do not, the same name twice, out of order, too
 *  many): then unverifiable */
export function checkFiles(r, root) {
  const rows = Array.isArray(r?.files) ? r.files : [];
  let ok = rows.length <= FILES_MAX;
  const placed = rows.some((f) => f && typeof f === 'object' && (f.surface !== undefined || f.at !== undefined));
  const files = [];
  for (const f of rows.slice(0, FILES_MAX)) {
    const nameShape = f && typeof f === 'object' && typeof f.name === 'string' && f.name.length <= 1024 && !/[\x00-\x1f\x7f]/.test(f.name);
    const place = !nameShape ? null : placed ? placeOf(f, root) : legacyNameOk(f.name) ? { tool: null } : null;
    if (!place || (files.length && files.at(-1).name >= f.name)) { ok = false; continue; }
    files.push({
      name: f.name, type: TYPES.includes(f.type) ? f.type : 'other', size: Number.isInteger(f.size) && f.size >= 0 ? f.size : null,
      sha256: SHA.test(f.sha256 ?? '') ? f.sha256 : null, target: typeof f.target === 'string' ? short(f.target, 1000) : null,
      text: typeof f.text === 'string' && f.text.length <= 256 << 10 ? f.text : null, at: placed ? f.at : null, tool: place.tool,
    });
  }
  return { files, ok };
}

const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : null);
// keys whose value is a program Claude Code runs (a string, or {command})
const COMMAND_KEYS = ['apiKeyHelper', 'awsAuthRefresh', 'awsCredentialExport', 'gcpAuthRefresh', 'otelHeadersHelper', 'statusLine', 'fileSuggestion',
  'subagentStatusLine'];
const MCP_KEYS = ['enableAllProjectMcpServers', 'enabledMcpjsonServers', 'disabledMcpjsonServers'];
const KNOWN = new Set(['$schema', 'hooks', 'permissions', 'env', ...COMMAND_KEYS, ...MCP_KEYS]);
const PERM_KNOWN = new Set(['allow', 'ask', 'deny', 'defaultMode', 'additionalDirectories']);
// what the page shows of them: at most this many entries per section, this many characters per value — beyond that
// the summary is incomplete, and incomplete settings are never trusted (nothing you were not shown can apply)
export const LIST_MAX = 200, TEXT_MAX = 2000;
// another tool's file is shown whole up to this many characters (beyond: not trustable)
export const TOOL_TEXT_MAX = 16000;
// A value of the trust summary that could hide something in plain sight: any character but printable ASCII, a tab or a
// line break (the page shows each as ⟨U+XXXX⟩), a run of 20+ whitespace characters, more than 60 of them in all, or
// more than 5 lines — the page folds it until you open it in full, and Trust waits for that.
// --- the trust summary's text rule: the same lines in code/web/src/projects.ts (tests/test_code.sh compares them) ---
const NOT_PLAIN = /[^\x20-\x7e\t\n]/;
const looksHidden = (t) => NOT_PLAIN.test(t) || /\s{20,}/.test(t) || (t.match(/\s/g) ?? []).length > 60 || (t.match(/\n/g) ?? []).length > 5;
// --- end of the rule ---
export const careful = (t) => typeof t === 'string' && looksHidden(t);
// the front matter keys of a skill, command, agent … that grant or change something (tools, hooks, MCP servers, the
// permission mode, the model) — shown for every .md file under a .claude/; the rest of such a file is instructions
const GRANT_KEYS = new Set(['allowed-tools', 'allowedtools', 'allowed_tools', 'disallowed-tools', 'disallowedtools', 'disallowed_tools', 'tools', 'hooks',
  'mcpservers', 'mcp-servers', 'mcp_servers', 'permissionmode', 'permission-mode', 'permission_mode', 'model']);
// a plain YAML scalar this page shows as it is: no indicator first (flow, anchor, alias, tag, block, quote, comment,
// directive …), no ": " or " #" inside, no tab — anything else a YAML parser could read differently
const PLAIN = /^(?![-?:,[\]{}#&*!|>'"%@`])(?!.*(?:: | #|\t))[^\t]*$/;
// a value that changes the structure YAML reads (a flow collection, a block scalar, an anchor, an alias, a tag, an
// explicit key) — never plain, whatever its key
const STRUCTURAL = /^[{[|>&*!?]|\t/;
// --- Claude Code's own reading of a Markdown file's front matter, mirrored (2.1.296, its binary:
// ---   function Gb(e){return e.charCodeAt(0)===65279?e.slice(1):e}
// ---   Pv=/^---\s*\n([\s\S]*?)---\s*\n?/      used when e.indexOf("---",3) >= 0, on Gb(e)
// --- ): one BOM off; "---"; any run of whitespace as JavaScript's \s knows it (spaces, tabs, CRs, \f, \v, NBSP, U+2028,
// --- U+3000, blank lines …) that holds a line feed — the block starts after the last line feed of that run —; the
// --- block ends at the FIRST "---" after it, wherever that is (inside a value too). Its YAML parser reads the block (a
// --- CR alone is a line break there); a block it cannot read gives no front matter at all. Done here by a scan, not
// --- that regular expression (whose \s* before an unclosed block is quadratic): the same block, in linear time. ---
const WS_CHAR = /\s/;
/** ccFrontMatterBlock(text) -> the front matter block Claude Code reads (its text), or null when it reads none */
export function ccFrontMatterBlock(t) {
  const m = ccFrontMatter(t);
  return m ? m.block : null;
}
/** ccFrontMatter(text) -> {block, body} — the block Claude Code reads and where its body starts in the text (si's
 *  content: after the closing --- and the whitespace its \s*\n? takes, all of it), or null */
export function ccFrontMatter(t) {
  const bom = t.charCodeAt(0) === 0xfeff ? 1 : 0;
  const s = bom ? t.slice(1) : t;
  if (!s.startsWith('---') || s.indexOf('---', 3) < 0) return null;
  let i = 3, lastNl = -1;
  while (i < s.length && WS_CHAR.test(s[i])) { if (s[i] === '\n') lastNl = i; i++; }
  if (lastNl < 0) return null;
  const close = s.indexOf('---', lastNl + 1);
  if (close < 0) return null;
  let e = close + 3;
  while (e < s.length && WS_CHAR.test(s[e])) e++;
  return { block: s.slice(lastNl + 1, close), body: bom + e };
}
// the block as this page reads front matter plainly: "---" (spaces or tabs after it) on the first line, the block to a
// line that is "---" (spaces or tabs after it)
const STRICT = /^\uFEFF?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/;
const BLOCK_MAX = 64 << 10;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\x00-\x08\x0b\x0c\x0e-\x1f\x85]/;   // (Claude Code reads no front matter of more than 64 KiB in an untrusted folder)
// readBlock(block) -> {keys: [{key, value, list}], plain}: top-level `key: value` lines and `key:` with `  - item`
// lines, one pass; anything else is not plain (a key twice — told by a set —, a structural value, a continuation …)
function readBlock(block) {
  const keys = [], seen = new Set();
  let cur = null, plain = true;
  // (a CR alone is a line break to YAML: split there too — and not plain, a page shows it differently)
  if (/\r(?!\n)/.test(block)) plain = false;
  for (const raw of block.split(/\r\n|\r|\n/)) {
    let e = raw.length;
    while (e > 0 && raw[e - 1] === ' ') e--;
    const line = raw.slice(0, e);
    if (!line || /^[ ]*#/.test(line)) continue;
    const k = /^([A-Za-z][A-Za-z0-9_-]*):(?: (.*))?$/.exec(line);
    if (k) {
      const v = (k[2] ?? '').trim();
      const lower = k[1].toLowerCase();
      const grant = GRANT_KEYS.has(lower);
      if (seen.has(lower) || STRUCTURAL.test(v) || (grant && v && !PLAIN.test(v))) plain = false;
      seen.add(lower);
      cur = { key: k[1], value: v, list: v === '' ? [] : null };
      keys.push(cur);
      continue;
    }
    const item = /^[ ]+- (.*)$/.exec(line);
    const iv = item ? item[1].trim() : '';
    if (item && cur?.list && !STRUCTURAL.test(iv) && (!GRANT_KEYS.has(cur.key.toLowerCase()) || PLAIN.test(iv))) { cur.list.push(iv); continue; }
    plain = false;   // a continuation, an indented mapping, a tab, a flow collection …
  }
  return { keys, plain };
}
/** frontMatter(text) -> {grants: [{key, value}], plain}: the grant keys of a .md file's front matter (matched in any
 *  case), each value as YAML gives it (a scalar, or a block list joined with ", ") — read in the block Claude Code reads
 *  (ccFrontMatterBlock) and, where this page's plain reading finds another block, in that one too: a grant either way is
 *  listed. plain false — what Claude Code reads cannot be told here, never trusted — when the text starts with --- (after
 *  a BOM) and anything is off: no block Claude Code would read, not the same block both ways (another opener — a \f,
 *  an NBSP, a U+2028, blank lines, a CR alone —, a "---" inside a value, a closer not on a line of its own), a block of
 *  more than 64 KiB, or anything but top-level `key: value` lines and `key:` with `  - item` lines (flow style, block
 *  scalars, anchors, aliases, tags, explicit or quoted keys, multi-line scalars, a key twice), or a grant key's value
 *  not a plain scalar (quoted, ": " or " #" inside). Linear in the text. */
export function frontMatter(t) {
  // (every BOM before it: Claude Code takes one off — two or more before a --- is never plain, its grants read anyway)
  let b = 0;
  while (t.charCodeAt(b) === 0xfeff) b++;
  if (b > 1) return t.startsWith('---', b) ? { grants: frontMatter(t.slice(b)).grants, plain: false } : { grants: [], plain: true };
  const s = b ? t.slice(1) : t;
  if (!s.startsWith('---')) return { grants: [], plain: true };
  const cc = ccFrontMatterBlock(t);
  const strict = STRICT.exec(t);
  let plain = cc !== null && strict !== null && cc.replace(/\r\n/g, '\n').trim() === strict[1].replace(/\r\n/g, '\n').trim() && cc.length <= BLOCK_MAX;
  const grants = [], said = new Set();
  for (const block of [cc, strict && strict[1] !== cc ? strict[1] : null]) {
    if (block === null) continue;
    // (a control character but a tab or a line break, or a NEL — a line break to some YAML parsers: never plain)
    if (CONTROL.test(block)) plain = false;
    const r = readBlock(block.length > BLOCK_MAX ? block.slice(0, BLOCK_MAX) : block);
    if (!r.plain) plain = false;
    for (const x of r.keys) {
      if (!GRANT_KEYS.has(x.key.toLowerCase())) continue;
      const g = { key: x.key, value: x.list?.length ? x.list.join(', ') : x.value };
      const id = `${g.key.toLowerCase()}\0${g.value}`;
      if (!said.has(id)) { said.add(id); grants.push(g); }
    }
  }
  return { grants, plain };
}
// --- the shell commands a skill's or command's text runs when it is used (Claude Code 2.1.296, its binary:
// ---   gVn=/```!\s*\n?([\s\S]*?)\n?```/g          a fenced block opened by ```!
// ---   hVn=/(?<=^|\s)!`([^`]+)`/gm               an inline !`…` after a line's start or whitespace — read on the text
// ---                                               with inline code blanked first: /`[^`\n]+`/g not after ! or `
// ---   each command trimmed, CRLF as LF; an empty one skipped. Its blanking, whole:
// ---   function cOe(e){return e.replace(/`[^`\n]+`/g,(n,r)=>{let s=e[r-1];return s==="!"||s==="`"?n:"`"+vi(" ",
// ---     n.length-2)+"`"})}  — a span after ! or ` is kept as it is, and consumed all the same)
// --- — mirrored here by scans, in linear time (the fenced pattern's \s* before an unclosed block is quadratic): every
// --- command Claude Code would run is listed; a fenced block with no closing ``` (which runs nothing there) is listed too.
// --- And read a second way, the union listed: with a span right after ! or ` not matched at all (a reading by a
// --- lookbehind, /(?<![!`])`[^`\n]+`/g — the scan goes on inside it) — a command that reading finds and Claude Code's
// --- does not is an extra line; one a later Claude Code would run, were its blanking to change so, is never missed.
// blankInlineCode(text, passOver) -> the text with each inline code span (`…` on one line, matched left to right as a
// regular expression does) as spaces, but one right after ! or ` kept as it is — passOver true: that span consumed all
// the same (cOe(text), Claude Code's); false: not matched there, the scan going on at the next backtick
function blankInlineCode(s, passOver = true) {
  let out = '', from = 0;
  for (let i = s.indexOf('`'); i >= 0; ) {
    const after = s[i - 1] === '!' || s[i - 1] === '`';
    if (after && !passOver) { i = s.indexOf('`', i + 1); continue; }
    let j = i + 1;
    while (j < s.length && s[j] !== '`' && s[j] !== '\n') j++;
    if (j < s.length && s[j] === '`' && j > i + 1) {
      if (!after) { out += `${s.slice(from, i + 1)}${' '.repeat(j - i - 1)}`; from = j; }
      i = s.indexOf('`', j + 1);
    } else i = s.indexOf('`', i + 1);
  }
  return out + s.slice(from);
}
/** shellBlocks(text, max) -> {list: [{kind: 'fenced' | 'open' | 'inline', command, at}], more}: the shell commands
 *  Claude Code runs (in the sandbox, as the session) each time the skill or command is used, before the model reads its
 *  text — inline ones by both readings of inline code, the union (one found both ways at the same place, once); each
 *  whole (never cut: a caller that cannot show one whole says so); the first max of them, more when there are more (a
 *  caller says so). 'open': a ```! block with no closing ``` — Claude Code runs nothing there; listed all the same */
export function shellBlocks(text, max = 1000) {
  const t = String(text), out = [], seen = new Set();
  let more = false;
  const add = (kind, c, at) => {
    const cmd = c.trim().replaceAll('\r\n', '\n');
    if (!cmd || seen.has(`${at}\0${cmd}`)) return;
    seen.add(`${at}\0${cmd}`);
    if (out.length < max) out.push({ kind, command: cmd, at }); else more = true;
  };
  // scan(s, from) — the commands of s (its places counted from 'from' in the text)
  const scan = (s, from) => {
    for (let at = s.indexOf('```!'); at >= 0 && !more; ) {
      const close = s.indexOf('```', at + 4);
      add(close < 0 ? 'open' : 'fenced', s.slice(at + 4, close < 0 ? s.length : close), from + at);
      if (close < 0) break;
      at = s.indexOf('```!', close + 3);
    }
    // (each reading's blanked text keeps the text's length: a command's place is the same in both)
    for (const passOver of s.includes('!`') ? [true, false] : []) {
      const b = blankInlineCode(s, passOver);
      for (let at = b.indexOf('!`'); at >= 0 && !more; ) {
        if (at > 0 && !WS_CHAR.test(b[at - 1])) { at = b.indexOf('!`', at + 1); continue; }
        const end = b.indexOf('`', at + 2);
        if (end < 0) break;
        if (end === at + 2) { at = b.indexOf('!`', at + 1); continue; }
        add('inline', b.slice(at + 2, end), from + at);
        at = b.indexOf('!`', end + 1);
      }
    }
  };
  // the whole text — and, where Claude Code reads front matter, its body alone, as Claude Code scans it (si's content):
  // a !` left open in the front matter cannot hide a command of the body
  scan(t, 0);
  const fm = ccFrontMatter(t);
  if (fm && fm.body > 0) scan(t.slice(fm.body), fm.body);
  return { list: out, more };
}
// Plugins and plugin marketplaces another tool's file declares: the plugins' own folders (their hooks, MCP and
// language servers) are not listed here, so a listing with one is incomplete — never trusted. Found by what the tools
// read, not by its spelling: a JSON (or JSONC) file is parsed and every key at every depth looked at, in any case (a key
// spelled with \u escapes is the same key once parsed); a .json that does not parse, even as JSONC, cannot be looked
// at (incomplete too). There is no TOML or YAML parser here: such a file is searched whole, and one with anything that
// could spell a key otherwise than as written — a backslash anywhere (an escape: \u, \x, \N, a folded line …), and in
// YAML a complex key (?), a merge (<<), an alias as a key or a tag — cannot be looked at. A marketplace.json is one by
// its name. The raw text's "marketplace": key is a trigger as well, never the only one. (Claude Code's own settings
// follow a narrower rule: summarize.)
const PLUGIN_KEY = /plugin|marketplace/i;
// a line break as JSONC parsers read one (jsonc-parser: \n, \r, U+2028, U+2029)
const JSONC_BREAK = /[\n\r\u2028\u2029]/;
// stripJsonc(t) -> the text without // and /* */ comments and trailing commas (outside strings), or null: a comment
// left open, or a line break JSON parsers and JSONC parsers do not agree on — a CR alone, U+2028 or U+2029 — outside a
// string (what one tool reads as the end of a comment another reads as part of it)
export function stripJsonc(t) {
  // (runs of plain text kept as slices, joined once: linear in the text)
  const parts = [];
  let i = 0, from = 0;
  while (i < t.length) {
    const c = t[i];
    if (c === '"') {
      let j = i + 1;
      while (j < t.length && t[j] !== '"') j += t[j] === '\\' ? 2 : 1;
      i = j + 1; continue;
    }
    if ((c === '\r' && t[i + 1] !== '\n') || c === '\u2028' || c === '\u2029') return null;
    if (c === '/' && t[i + 1] === '/') {
      parts.push(t.slice(from, i));
      while (i < t.length && !JSONC_BREAK.test(t[i])) i++;
      from = i; continue;
    }
    if (c === '/' && t[i + 1] === '*') {
      const e = t.indexOf('*/', i + 2);
      if (e < 0 || /\r(?!\n)|[\u2028\u2029]/.test(t.slice(i, e))) return null;
      parts.push(t.slice(from, i), ' ');
      i = e + 2; from = i; continue;
    }
    i++;
  }
  parts.push(t.slice(from));
  const out = parts.join('');
  // (a comma before a closing bracket, outside strings: the second pass, comments gone)
  const res = [];
  let k = 0, start = 0;
  while (k < out.length) {
    const c = out[k];
    if (c === '"') {
      let j = k + 1;
      while (j < out.length && out[j] !== '"') j += out[j] === '\\' ? 2 : 1;
      k = j + 1; continue;
    }
    if (c === ',') {
      let j = k + 1;
      while (j < out.length && /\s/.test(out[j])) j++;
      if (out[j] === '}' || out[j] === ']') { res.push(out.slice(start, k)); start = k + 1; }
    }
    k++;
  }
  res.push(out.slice(start));
  return res.join('');
}
// pluginKeyIn(v) -> the first key (at any depth) that names plugins or a marketplace, or null
export function pluginKeyIn(v, depth = 0) {
  if (depth > 100) return '(nested deeper than this page looks)';
  if (Array.isArray(v)) { for (const x of v) { const k = pluginKeyIn(x, depth + 1); if (k) return k; } return null; }
  if (v && typeof v === 'object') {
    for (const [k, x] of Object.entries(v)) {
      if (PLUGIN_KEY.test(k)) return k;
      const r = pluginKeyIn(x, depth + 1);
      if (r) return r;
    }
  }
  return null;
}
// parseJsonc(t) -> {v}, or null: the text as JSON with JSONC's comments and trailing commas (stripJsonc first: one that
// is only JSON comes out the same)
export const parseJsonc = (t) => {
  const s = stripJsonc(t);
  if (s === null) return null;
  try { return { v: JSON.parse(s) }; } catch { return null; }
};
// TOML and YAML: what could spell a key otherwise than as written (no parser here to read it)
const YAML_ODD = [[/\\/, 'a backslash (an escape or a folded line)'], [/(^|[\s{,[-])\?(\s|$)/m, 'a complex key (?)'], [/<</, 'a merge key (<<)'],
  [/(^|[\s{,[?-])\*[^\s,[\]{}]+\s*:/m, 'an alias as a key'], [/(^|[\s{,[?:-])!/m, 'a tag']];
/** pluginsOf(name, text) -> {key: what declares plugins or a marketplace, or null; unreadable: why it cannot be looked
 *  at, or null} — for another tool's file */
export function pluginsOf(name, text) {
  const base = String(name).toLowerCase().split('/').pop();
  if (base === 'marketplace.json') return { key: 'a marketplace.json', unreadable: null };
  const raw = /"(extraKnownMarketplaces|marketplaces?)"\s*:/i.test(text) ? 'marketplace' : null;
  if (/\.jsonc?$/.test(base)) {
    const p = parseJsonc(text);
    if (!p) return { key: raw, unreadable: 'not valid JSON or JSONC (or a line break the tools read differently: a CR alone, U+2028, U+2029)' };
    let k = null;
    try { k = pluginKeyIn(p.v); } catch { k = '(could not be looked at)'; }
    return { key: k ?? raw, unreadable: null };
  }
  if (/\.(toml|ya?ml)$/.test(base)) {
    const odd = (base.endsWith('.toml') ? YAML_ODD.slice(0, 1) : YAML_ODD).find(([re]) => re.test(text));
    const m = text.match(PLUGIN_KEY);
    return { key: m ? m[0] : raw, unreadable: odd ? `${odd[1]}: a key could be spelled otherwise than as written, and this page has no ${base.endsWith('.toml') ? 'TOML' : 'YAML'} parser to read it` : null };
  }
  return { key: raw, unreadable: null };
}
// Claude Code's own plugin keys in a project's .claude/settings*.json (2.1.309 reads them at the top level; in any case
// here): a marketplace the project adds (extraKnownMarketplaces, and its alias additionalMarketplaces) is code nobody
// here has looked at — never trusted; enabledPlugins turns plugins on — each one installed in the sandbox is listed
// (its id and version are in the hash: bn-coded's plugins), one that is not could be fetched — never trusted
const CC_MARKETPLACE_KEYS = ['extraknownmarketplaces', 'additionalmarketplaces'];
const CC_ENABLED_KEY = 'enabledplugins';
// Plugin keys that are harmless in a project's file (shown as they are, under Other settings): pluginConfigs — the
// options of plugins already turned on (values a plugin reads, not a plugin or a place to fetch one from);
// strictKnownMarketplaces and its alias allowedMarketplaces — read from managed settings only, and only narrow which
// marketplaces may be added. Any other key naming plugins or a marketplace, at any depth: never trusted.
const CC_PLUGIN_HARMLESS = ['pluginconfigs', 'strictknownmarketplaces', 'allowedmarketplaces'];

// canonical(v) -> JSON with sorted keys (every field, whatever the friendly line shows)
const canonical = (v) => JSON.stringify(v, (k, x) => (x && typeof x === 'object' && !Array.isArray(x) ? Object.fromEntries(Object.keys(x).sort().map((key) => [key, x[key]])) : x));

/** summarize(files) -> what they set, all of it or said to be incomplete — files: [{name, size, grants: [{key, value}]}]
 *  every file under .claude/ but the two settings files, with its front matter keys that grant something; {hooks: [{file, event, matcher, command,
 *  json, mixed, careful}], allow, ask, deny, defaultMode, directories, env: [{file, name, value}], commands: [{file,
 *  key, command}], mcp: [{file, key, value}], mcpServers: [{file, name, run, json, mixed, careful}], other: [{file,
 *  key, value}], notes: [{file, note}], plugins: [{file, id, on, version}] (the plugins the settings turn on, each
 *  installed in the sandbox, or off), complete, missing: [why …], careful} — complete: every key and value of the
 *  files is in it, whole (no list or value cut, no hidden character, no file that could not be read as JSON). A hook
 *  and an MCP server come with their whole entry as canonical JSON (json: every field, sorted), a friendly line beside
 *  it (command, run), mixed when it names more than one of a command, a URL and a prompt; careful: values with long
 *  runs of whitespace or many lines (the page asks you to look at them in full). plugins: what the sandbox says of the
 *  plugins the settings turn on ({list: [{id, installed, versions}], registry}: checkPlugins), or null when it said
 *  nothing (then a plugin turned on is never trusted). */
export function summarize(files, plugins = null, planPlugins = null) {
  const out = { hooks: [], allow: [], ask: [], deny: [], defaultMode: null, directories: [], env: [], commands: [], mcp: [], mcpServers: [], other: [], notes: [],
    files: [], tools: [], plugins: [], complete: true, missing: [], careful: 0 };
  const why = new Map();
  const incomplete = (reason) => { out.complete = false; why.set(reason, (why.get(reason) ?? 0) + 1); };
  // text(v) -> a value as the page shows it (a string as is; anything else as JSON), whole or said
  const text = (v) => {
    let t;
    try { t = typeof v === 'string' ? v : JSON.stringify(v) ?? String(v); } catch { incomplete('a value that cannot be shown'); return '?'; }
    if (careful(t)) out.careful++;
    if (t.length > TEXT_MAX) { incomplete(`a value over ${TEXT_MAX.toLocaleString('en')} characters`); return `${t.slice(0, TEXT_MAX)}… (${t.length - TEXT_MAX} more characters not shown)`; }
    return t;
  };
  const add = (section, item) => {
    if (out[section].length >= LIST_MAX) { incomplete(`more than ${LIST_MAX} entries in one section`); return; }
    out[section].push(item);
  };
  for (const f of files) {
    const note = (t) => out.notes.push({ file: f.name, note: t });
    // (names as a case-insensitive workspace reads them: .CLAUDE/settings.json is .claude/settings.json)
    const lower = f.name.toLowerCase();
    const tool = f.tool ?? null;   // (checkFiles: from where it was read, never from its name)
    const settings = !tool && !f.at && (lower === '.mcp.json' || SETTINGS_FILES.includes(lower));
    // every other file under a .claude/ is listed — each text file with the front matter keys that grant something,
    // whatever its name (one that starts with --- but does not read plainly: not trustable)
    if (!settings && !tool) {
      const fm = f.text !== null ? frontMatter(f.text) : { grants: [], plain: true };
      if (!fm.plain) { note('front matter this page cannot read the way Claude Code does (only `key: value` lines and `- item` lists)'); incomplete('front matter beyond plain key: value lines'); }
      // (and the shell commands Claude Code runs each time a skill or command is used: !`…` and ```! blocks — listed with
      // its grants, whatever the file)
      // — every one shown whole, or the summary incomplete: never one that runs but is not shown)
      const shell = f.text !== null ? shellBlocks(f.text, LIST_MAX) : { list: [], more: false };
      if (shell.more) incomplete(`more than ${LIST_MAX} shell commands in one file`);
      if (shell.list.some((x) => x.command.length > TEXT_MAX)) incomplete('a shell command too long to show');
      out.files.push({ name: text(f.name), size: f.size, grants: [...fm.grants.map((g) => ({ key: text(g.key), value: text(g.value) })),
        ...shell.list.map((x) => ({ key: x.kind === 'inline' ? 'runs in a shell when used (!`…`)' : 'runs in a shell when used (```!)', value: text(x.command) }))] });
    }
    if (f.type === 'link') note(`a link to ${f.target ?? '?'}${f.text === null ? ' (not read: outside the workspace, or not a file)' : ''}`);
    if (f.type === 'big') { note('too large to show (over 256 KiB)'); incomplete('a file too large to show'); continue; }
    if (f.type === 'other') { note('not a file it could read (a FIFO, a folder through a link …)'); incomplete('a file that could not be read'); continue; }
    if (f.text === null) { note('not shown (not text, or too much in all)'); incomplete('a file that could not be shown'); continue; }
    // another tool's file: shown whole (its hooks, MCP servers and rules in its own format), up to TOOL_TEXT_MAX
    if (tool) {
      const whole = f.text.length <= TOOL_TEXT_MAX;
      if (!whole) incomplete(`another tool's file over ${TOOL_TEXT_MAX.toLocaleString('en')} characters`);
      // (plugins or a plugin marketplace the repository declares: their folders are not looked at here — never trusted;
      // a .json that cannot be parsed cannot be looked at either)
      const pl = pluginsOf(f.name, f.text);
      if (pl.unreadable) { note(`${pl.unreadable}: what it declares cannot be looked at here`); incomplete('another tool\'s file this page cannot read the way the tool does'); }
      if (pl.key) {
        // (Claude Code's settings in a folder above: Claude Code does not read them there; Grok and Copilot do)
        note(tool === CLAUDE_ABOVE ? `a settings file above this project, in ${short(f.at || '?', 300)}, turns on plugins (${short(pl.key, 100)}) — Grok and Copilot read it, and what they install isn't checked here`
          : `declares plugins or a plugin marketplace (${short(pl.key, 100)}): the plugins it points at are not looked at here`);
        incomplete('plugins or a plugin marketplace declared in the project');
      }
      const t = whole ? f.text : `${f.text.slice(0, TOOL_TEXT_MAX)}… (${f.text.length - TOOL_TEXT_MAX} more characters not shown)`;
      if (careful(t)) out.careful++;
      add('tools', { file: f.name, tool, text: t, careful: careful(t) });
      continue;
    }
    if (!settings) continue;
    let v;
    try { v = JSON.parse(f.text); } catch { note('not valid JSON (Claude Code may still read parts of it)'); incomplete('a file that is not valid JSON'); continue; }
    if (!obj(v)) { note('not a JSON object'); incomplete('a file that is not a JSON object'); continue; }
    if (lower === '.mcp.json') {
      if (v.mcpServers !== undefined && !obj(v.mcpServers)) add('other', { file: f.name, key: 'mcpServers', value: text(v.mcpServers) });
      for (const [name, c] of Object.entries(obj(v.mcpServers) ?? {})) {
        const sv = obj(c);
        // the friendly line (what it runs, or where it connects) — and always the whole entry beside it
        const run = !sv ? '' : typeof sv.command === 'string' ? [sv.command, ...(Array.isArray(sv.args) ? sv.args : [])].map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ')
          : typeof sv.url === 'string' ? sv.url : '';
        const mixed = Boolean(sv) && ['command', 'url'].filter((k) => sv[k] !== undefined).length > 1;
        const json = text(canonical(c));
        add('mcpServers', { file: f.name, name: text(name), run: text(run), json, mixed, careful: careful(json) || careful(run) });
      }
      // (GitHub Copilot also reads servers at the top level of a .mcp.json: shown as MCP servers, said whose)
      for (const k of Object.keys(v).filter((k) => k !== 'mcpServers')) {
        const sv = obj(v[k]);
        if (sv && (typeof sv.command === 'string' || typeof sv.url === 'string')) {
          const run = typeof sv.command === 'string' ? [sv.command, ...(Array.isArray(sv.args) ? sv.args : [])].map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ') : sv.url;
          const json = text(canonical(sv));
          add('mcpServers', { file: f.name, name: text(`${k} (at the top level: GitHub Copilot starts it)`), run: text(run), json, mixed: false, careful: careful(json) || careful(run) });
        } else add('other', { file: f.name, key: text(k), value: text(v[k]) });
      }
      continue;
    }
    if (v.hooks !== undefined && !obj(v.hooks)) add('other', { file: f.name, key: 'hooks', value: text(v.hooks) });
    for (const [event, list] of Object.entries(obj(v.hooks) ?? {})) {
      if (!Array.isArray(list)) { add('hooks', { file: f.name, event: text(event), matcher: '', command: text(list) }); continue; }
      for (const m of list) {
        const hs = Array.isArray(m?.hooks) ? m.hooks : null;
        const matcher = m?.matcher === undefined ? '' : text(m.matcher);
        if (!hs) { add('hooks', { file: f.name, event: text(event), matcher, command: text(m) }); continue; }
        for (const h of hs) {
          const o = obj(h);
          // the friendly line (the command, URL or prompt it runs) — and always the whole entry beside it
          const head = !o ? '' : typeof o.command === 'string' ? o.command : typeof o.url === 'string' ? o.url : typeof o.prompt === 'string' ? `(prompt) ${o.prompt}` : '';
          const mixed = Boolean(o) && ['command', 'url', 'prompt'].filter((k) => o[k] !== undefined).length > 1;
          const json = text(canonical(h));
          add('hooks', { file: f.name, event: text(event), matcher, command: text(head), json, mixed, careful: careful(json) || careful(head) });
        }
      }
    }
    if (v.permissions !== undefined && !obj(v.permissions)) add('other', { file: f.name, key: 'permissions', value: text(v.permissions) });
    const perms = obj(v.permissions) ?? {};
    for (const k of ['allow', 'ask', 'deny']) {
      if (perms[k] === undefined) continue;
      if (!Array.isArray(perms[k])) { add('other', { file: f.name, key: `permissions.${k}`, value: text(perms[k]) }); continue; }
      for (const r of perms[k]) add(k, text(r));
    }
    if (perms.defaultMode !== undefined) out.defaultMode = text(perms.defaultMode);
    if (perms.additionalDirectories !== undefined) {
      if (Array.isArray(perms.additionalDirectories)) for (const d of perms.additionalDirectories) add('directories', text(d));
      else add('other', { file: f.name, key: 'permissions.additionalDirectories', value: text(perms.additionalDirectories) });
    }
    for (const k of Object.keys(perms).filter((k) => !PERM_KNOWN.has(k))) add('other', { file: f.name, key: `permissions.${text(k)}`, value: text(perms[k]) });
    if (v.env !== undefined && !obj(v.env)) add('other', { file: f.name, key: 'env', value: text(v.env) });
    for (const [name, value] of Object.entries(obj(v.env) ?? {})) add('env', { file: f.name, name: text(name), value: text(value) });
    for (const k of COMMAND_KEYS) if (v[k] !== undefined) add('commands', { file: f.name, key: k, command: text(typeof v[k] === 'string' ? v[k] : v[k]) });
    for (const k of MCP_KEYS) if (v[k] !== undefined) add('mcp', { file: f.name, key: k, value: text(v[k]) });
    // Claude Code's plugin keys (top level, any case): a marketplace the project adds — never trusted; the plugins it turns
    // on — each one installed in the sandbox listed, one that is not never trusted
    for (const k of Object.keys(v)) {
      const low = k.toLowerCase();
      if (CC_MARKETPLACE_KEYS.includes(low)) {
        note(`adds a plugin marketplace (${short(k, 60)}): its plugins are code nobody here has looked at — not trustable`);
        incomplete('a plugin marketplace the project adds');
      }
      if (low !== CC_ENABLED_KEY) continue;
      const x = v[k];
      const list = Array.isArray(x) ? x.map((id) => [id, true]) : obj(x) ? Object.entries(x) : null;
      if (!list) { note(`${short(k, 60)} is not a list of plugins`); incomplete('plugins turned on in a form this page does not read'); add('other', { file: f.name, key: text(k), value: text(x) }); continue; }
      for (const [id, on] of list) {
        if (typeof id !== 'string') { note(`${short(k, 60)} names something that is not a plugin id`); incomplete('plugins turned on in a form this page does not read'); continue; }
        // (turned off: nothing runs — listed as such)
        if (on === false) { add('plugins', { file: f.name, id: text(id), on: false, version: null }); continue; }
        const got = plugins?.list.find((p) => p.id === id);
        if (!plugins || plugins.registry === 'unreadable') {
          note(`turns on plugin ${short(id, 200)}: the sandbox's list of installed plugins could not be read`);
          incomplete('a plugin turned on, and the sandbox\'s installed plugins could not be read');
        } else if (!got?.installed) {
          note(`turns on plugin ${short(id, 200)}, which is not installed in the sandbox: Claude Code could fetch it — not trustable`);
          incomplete('a plugin the project turns on that is not installed in the sandbox');
        } else {
          const vtext = (x) => text(x.versions.map((w) => [w.version ?? '?', w.commit ? `(${w.commit.slice(0, 12)})` : ''].join(' ').trim()).join(', '));
          const onPlan = planPlugins?.list.find((p) => p.id === id);
          // (Claude on your plan: its own record — not installed there, its sessions start without these settings)
          if (planPlugins && (planPlugins.registry === 'unreadable' || !onPlan?.installed)) {
            note(`turns on plugin ${short(id, 200)}, which Claude on your plan has not installed: its sessions here start with your own settings only`);
          }
          add('plugins', { file: f.name, id: text(id), on: true, version: vtext(got), planVersion: onPlan?.installed ? vtext(onPlan) : null });
        }
      }
    }
    // and anything else that names plugins or a marketplace, at any depth (a key of a later Claude Code, an env variable
    // that steers how plugins load …): never trusted — but the keys above, already looked at, and CC_PLUGIN_HARMLESS
    for (const k of Object.keys(v)) {
      const low = k.toLowerCase();
      if (low === CC_ENABLED_KEY || CC_MARKETPLACE_KEYS.includes(low) || CC_PLUGIN_HARMLESS.includes(low)) continue;
      let found = null;
      try { found = PLUGIN_KEY.test(k) ? k : pluginKeyIn(v[k]); } catch { found = '(could not be looked at)'; }
      if (found) {
        note(`names plugins or a marketplace (${short(k, 60)}${found !== k ? ` › ${short(found, 60)}` : ''}): not something this page reads — not trustable`);
        incomplete('a setting about plugins this page does not read');
      }
    }
    for (const k of Object.keys(v).filter((k) => !KNOWN.has(k) && k.toLowerCase() !== CC_ENABLED_KEY)) add('other', { file: f.name, key: text(k), value: text(v[k]) });
  }
  out.missing = [...why].map(([reason, n]) => (n > 1 ? `${reason} (${n} times)` : reason));
  return out;
}

/** The state of a folder's own settings: workspace (always applied) | none (no such file) | trusted | untrusted (never
 *  trusted) | changed (trusted once, different now) | unverifiable (a file there could not be read whole as text — a
 *  link out of the workspace, too large, a FIFO —, so no hash covers what Claude Code would read: never trusted) |
 *  unchecked (the sandbox did not say: not applied). */
export const APPLIED = Object.freeze(['workspace', 'none', 'trusted']);
// recheck: trusted before bedrock-now read Claude Code settings the way it does now (a trust of an earlier epoch,
// projects.mjs TRUST_EPOCH) — not applied until you look at them again, whatever they hold
export const stateOf = ({ workspace = false, present, hash, trust, verifiable = true }) => {
  if (workspace) return 'workspace';
  if (!present) return 'none';
  if (!verifiable || !hash) return 'unverifiable';
  if (trust && trust.epoch !== TRUST_EPOCH) return 'recheck';
  if (trust && trust.hash === hash) return 'trusted';
  return trust ? 'changed' : 'untrusted';
};
export const RECHECK_TEXT = 'bedrock-now reads a project\'s settings more strictly since you trusted them (the other tools\' too) — look at them again';
const sha256 = (b) => crypto.createHash('sha256').update(b).digest('hex');
/** hashOf(files, plugins) -> the hash bn-coded's settingsFiles makes, from the checked rows and the plugins the
 *  settings turn on with what the sandbox has of them (checkPlugins; null when none: the files' alone) — null when
 *  there is no file */
export const hashOf = (files, plugins = null) => {
  if (!files.length) return null;
  const rows = files.map((f) => [f.name, f.type, f.sha256 ?? null, f.target ?? null]);
  return sha256(JSON.stringify(plugins ? { files: rows, plugins: plugins.list, registry: plugins.registry } : rows));
};
const PLUGIN_ID = /^[\x20-\x7e]{1,300}$/;
const vstr = (x) => x === null || (typeof x === 'string' && x.length <= 100);
const pluginList = (l, registry) => {
  const ok = Array.isArray(l) && l.length <= 200 && ['ok', 'none', 'unreadable'].includes(registry)
    && l.every((p, i) => p && typeof p === 'object' && typeof p.id === 'string' && PLUGIN_ID.test(p.id) && (i === 0 || l[i - 1].id < p.id)
      && typeof p.installed === 'boolean' && Array.isArray(p.versions) && p.versions.length <= 20 && p.installed === p.versions.length > 0
      && p.versions.every((w) => w && typeof w === 'object' && vstr(w.version) && vstr(w.commit)));
  return ok ? { list: l.map((p) => ({ id: p.id, installed: p.installed, versions: p.versions.map((w) => ({ version: w.version, commit: w.commit })) })), registry } : null;
};
/** checkPlugins(project.settings' RESULT) -> {plugins: {list: [{id, installed, versions: [{version, commit}]}], registry:
 *  ok|none|unreadable} or null (none said), planPlugins (the same plugins in Claude on your plan's own record), ok}: ok
 *  false when what it says does not fit (then unverifiable) */
export function checkPlugins(r) {
  if (r?.plugins === undefined && r?.registry === undefined && r?.planPlugins === undefined && r?.planRegistry === undefined) return { plugins: null, planPlugins: null, ok: true };
  const plugins = pluginList(r.plugins, r.registry), planPlugins = pluginList(r.planPlugins, r.planRegistry);
  // (the same plugins, the ones the settings turn on, in both)
  if (!plugins || !planPlugins || plugins.list.map((p) => p.id).join('\n') !== planPlugins.list.map((p) => p.id).join('\n')) return { plugins: null, planPlugins: null, ok: false };
  return { plugins, planPlugins, ok: true };
}
// planMissing(planPlugins) -> whether Claude on your plan lacks a plugin the settings turn on (or its record could not
// be read)
const planMissing = (pp) => Boolean(pp) && (pp.registry === 'unreadable' || pp.list.some((p) => !p.installed));

/** What a session says when its folder's own settings are not applied (a `local` event at its process's start). */
export function withheldText(d) {
  if (d.reason === 'plan-plugins') return 'This project turns on plugins Claude on your plan hasn\'t installed — started with your own settings only (of MCP servers, only the stack\'s own). Install them in Claude on your plan (claude-sub in the terminal), then trust the project\'s settings again: its ⋯ › Claude Code settings….';
  const what = 'its own Claude Code configuration (everything under .claude/ — settings, skills, commands, agents … — and .mcp.json; with it, its CLAUDE.md)';
  const why = 'its hooks, permission rules, granted tools, environment and MCP servers could run commands or silence the permission cards';
  if (d.state === 'unverifiable') return `This ${d.project ? 'project' : 'folder'}'s ${what.slice(4)} are not applied in this session: one of these files cannot be checked (a link out of the workspace, too large to show, or not a file), so they cannot be trusted either. Your own settings apply; of MCP servers, only the stack's own (bedrock-shared).`;
  if (d.state === 'unchecked') return `This folder's ${what.slice(4)} are not applied in this session: the sandbox did not say what they hold. Your own settings apply; of MCP servers, only the stack's own (bedrock-shared).`;
  const how = d.project ? 'Review them: the project\'s ⋯ › Claude Code settings… — once you trust them, Claude Code here restarts with them at your next prompt.'
    : 'To review and trust them, make this folder a project (New project › A folder in the workspace).';
  const since = d.state === 'changed' ? ': they changed since you trusted them' : d.state === 'recheck' ? `: ${RECHECK_TEXT}` : '';
  return `This ${d.project ? 'project' : 'folder'}'s ${what.slice(4)} are not applied in this session${since} — ${why}. Your own settings apply; of MCP servers, only the stack's own (bedrock-shared). ${how}`;
}

/** makeTrust({call, store, log}) — what a Claude Code process started in a folder gets of the folder's own settings
 *  (decided anew before every start: never cached), the page's view of a project's settings, trust and untrust. */
// bn-coded's own reasons for not showing a project's settings whole (project.settings' over: its fixed texts and the
// shapes with its limits in them): as they are; anything else is the sandbox's words, apart (code/test checks every
// over bn-coded writes matches)
export const OVER = new RegExp('^(more than \\d+ MiB in all|too much to show|a folder that could not be read|folders more than \\d+ deep|more than \\d+ files'
  + '|a linked git worktree or a submodule( above it)? \\(Claude Code reads another checkout\'s configuration then\\))$');

// confirmOf(read) -> what trusting a project's settings confirms: their hash (the files, and the plugins they turn on as
// the sandbox has them), and — with plugins turned on — Claude on your plan's too (the same plugins as its own record
// has them): the dialog shows both, so a change to either between it and Trust is a change. No plugin: the hash itself.
const confirmOf = (r) => (r.hash === null ? null : r.planPlugins ? sha256(JSON.stringify({ hash: r.hash, planHash: r.planHash })) : r.hash);

export function makeTrust({ call, store, log = () => {} }) {
  // each project's state as last looked at (a start's decision, the dialog, a trust) — for the list only; a decision is
  // always made anew
  const known = new Map();
  const note = (id, state) => { if (id && id !== WORKSPACE_ID) { if (known.size >= 500 && !known.has(id)) known.clear(); known.set(id, state); } };
  const recordAt = (cwd) => store().list().find((p) => p.id !== WORKSPACE_ID && absOf(p.root) === cwd) ?? null;
  // read(abs, {text}) -> {files, present, hash, verifiable}: with the texts (the dialog, a trust), the hash recomputed
  // here from what was shown — each text's own SHA-256 checked against the one the sandbox gave — so a trusted hash
  // covers exactly the texts the page showed; without (a session's start: the hash alone, cheap), the sandbox's hash of
  // the same files, compared with the trusted one
  async function read(abs, { text = true } = {}) {
    const { result } = await call({ op: 'project.settings', ...(abs === WS ? {} : { root: abs }), ...(text ? {} : { text: false }) }, { timeoutMs: 20000 });
    const { files, ok } = checkFiles(result, abs);
    const { plugins, planPlugins, ok: pok } = checkPlugins(result);
    for (const f of files) if (f.text !== null && (!f.sha256 || sha256(Buffer.from(f.text, 'utf8')) !== f.sha256)) f.text = null;
    const present = files.length > 0 || !ok || (result?.over !== null && result?.over !== undefined);
    const hash = hashOf(files, plugins), planHash = planPlugins ? hashOf(files, planPlugins) : hash;
    const verifiable = ok && pok && present && result?.verifiable === true && !result?.over && hash !== null && result?.hash === hash
      && (!planPlugins || result?.planHash === planHash)
      && files.every((f) => (f.type === 'file' || f.type === 'link') && (!text || f.text !== null));
    return { files, plugins, planPlugins, present, hash: verifiable ? hash : null, planHash: verifiable ? planHash : null, verifiable,
      over: typeof result?.over === 'string' ? short(result.over, 200) : null };
  }
  /** decide(cwd) -> {state, sources, strictMcp, project, hash, plan}: what a Claude Code process started there now gets
   *  — plan: the same for Claude on your plan (its own plugin record: a trust holds for it only while the plugins the
   *  settings turn on are installed there too, as trusted; reason plan-plugins when they are not). Anything that cannot
   *  be decided (the records, the sandbox): not applied. */
  async function decide(cwd) {
    if (cwd === WS) {
      const ws = { state: 'workspace', sources: ALL_SOURCES, strictMcp: false, project: WORKSPACE_ID, hash: null };
      return { ...ws, plan: { ...ws } };
    }
    let rec = null;
    const of = (state, hash, extra = {}) => ({ state, project: rec?.id ?? null, sources: APPLIED.includes(state) ? ALL_SOURCES : USER_SOURCES,
      strictMcp: !APPLIED.includes(state), hash, ...extra });
    try {
      rec = recordAt(cwd);
      const r = await read(cwd, { text: false });
      const state = stateOf({ present: r.present, hash: r.hash, trust: rec?.trust, verifiable: r.verifiable });
      note(rec?.id, state);
      // Claude on your plan: the trust's own plan hash (none recorded: the same as its hash — no plugin then)
      const planTrust = rec?.trust ? { ...rec.trust, hash: rec.trust.planHash === undefined ? rec.trust.hash : rec.trust.planHash } : rec?.trust;
      let pstate = stateOf({ present: r.present, hash: r.planHash, trust: planTrust, verifiable: r.verifiable });
      const missing = planMissing(r.planPlugins);
      // (a plugin turned on that it has not installed: never applied for it, whatever the trust — said why)
      if (missing && !['unverifiable', 'none'].includes(pstate)) pstate = 'untrusted';
      // (not applied: your own settings, and of MCP servers only the stack's own — whatever Claude Code would read)
      return { ...of(state, r.hash), plan: of(pstate, r.planHash, missing ? { reason: 'plan-plugins' } : {}) };
    } catch (e) {
      log(`settings of ${short(cwd, 200)}: not checked (${short(e?.message || String(e), 200)}): not applied`);
      const no = { state: 'unchecked', project: rec?.id ?? null, sources: USER_SOURCES, strictMcp: true, hash: null };
      return { ...no, plan: { ...no } };
    }
  }
  /** view(rec) -> GET /api/projects/ID/settings: the files, what they set, the hash to trust, the state — and, when
   *  bn-coded's reason for not showing them all is not one of its own (OVER), the sandbox's words apart (said) */
  async function view(rec) {
    const abs = absOf(rec.root);
    const r = await read(abs);
    const state = stateOf({ workspace: rec.id === WORKSPACE_ID, present: r.present, hash: r.hash, trust: rec.trust, verifiable: r.verifiable });
    const summary = summarize(r.files, r.plugins, r.planPlugins);
    const own = r.over && OVER.test(r.over);
    if (r.over) { summary.complete = false; summary.missing.push(own ? r.over : 'a reason of the sandbox\'s own (below)'); }
    note(rec.id, state);
    return {
      // (a hash to trust only for settings the summary shows whole: nothing you were not shown can apply)
      project: rec.id, path: abs, state, hash: state === 'workspace' || !summary.complete ? null : confirmOf(r), trustedAt: rec.trust?.at ?? null,
      files: r.files.map(({ name, type, size, target }) => ({ name, type, size, target })),
      summary,
      ...(r.over && !own ? { said: r.over, saidBy: 'sandbox' } : {}),
    };
  }
  /** trust(rec, hash) — only the files exactly as the page showed them (a conflict when they changed since, when there
   *  are none, or when they cannot be verified) */
  async function trust(rec, hash) {
    const r = await read(absOf(rec.root));
    if (!r.present) return { conflict: 'this project has no settings of its own (nothing to trust)' };
    if (!r.verifiable) return { conflict: 'its settings cannot be checked (a file there is a link out of the workspace, too large to show, or not a file): they are never trusted' };
    // (what the dialog showed — the files, the plugins as the sandbox and Claude on your plan have them — exactly)
    if (r.hash === null || confirmOf(r) !== hash) return { conflict: 'its settings changed since you looked: review them again' };
    const sm = summarize(r.files, r.plugins, r.planPlugins);
    if (!sm.complete) return { conflict: `its settings cannot all be shown here (${sm.missing.join('; ')}): they are not trusted — shorten them, or use the folder without them` };
    // (Claude on your plan: the same trust while its own record has every plugin they turn on — else none for it)
    store().trust(rec.id, r.hash, r.planPlugins ? (planMissing(r.planPlugins) ? null : r.planHash) : undefined);
    note(rec.id, 'trusted');
    return { conflict: null };
  }
  const untrust = async (rec) => { store().trust(rec.id, null); known.delete(rec.id); };
  return { decide, view, trust, untrust, known: (id) => known.get(id) ?? null };
}
