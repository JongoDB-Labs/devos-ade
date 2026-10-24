// Projects (the Projects tab, the top bar's project chip): a project is a folder the sandbox sees — the workspace itself
// (the Workspace, always there), a folder of it, or a folder of this computer mounted beside it (./stack project: its
// root is its path in the sandbox, absolute; read-only or not) — with the Code page's record of it, which the code
// container keeps.
// The page names a project by its id only, never by a folder; what comes from the backend is checked here (a folder of
// the workspace by the same rules as the backend's, a name of one line), and a session is shown in the project the
// backend says only when that is a project of the list — else in the Workspace: nothing a list says makes a project.
// Kept free of DOM and network (test/projects.test.ts).
import { goneTopOf, label, hostTopOf } from './text';
import type { SandboxWords, SessionInfo } from './types';
import { PRODUCT } from './brand';

export const WORKSPACE_ID = 'ws';
export const WORKSPACE_PATH = '/workspace';
export const PROJECTS_MAX = 64;
const ID = /^p_[0-9a-f]{8}$/;
// (shown as text, but these would turn it around, break its line or hide in it: controls, direction marks and
// isolates, zero-width and invisible operators, line and paragraph separators, tag characters)
// eslint-disable-next-line no-control-regex
const ODD = /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff\u{e0000}-\u{e007f}]/u;

export type FolderState = 'dir' | 'missing' | 'link' | 'other' | 'unmounted';
/** A project's own Claude Code settings (.claude/settings*.json, .mcp.json): the Workspace's always apply; a project's
 *  only once trusted as they are (none: nothing to trust; changed: trusted once, different now; unverifiable: a file
 *  there cannot be checked — never trusted; unchecked: the sandbox did not say — not applied). */
// recheck: trusted before DevOS ADE read a project's settings the way it does now (projects.mjs's TRUST_EPOCH):
// looked at again first
export type SettingsState = 'workspace' | 'none' | 'trusted' | 'untrusted' | 'changed' | 'recheck' | 'unverifiable' | 'unchecked';
const SETTINGS: SettingsState[] = ['workspace', 'none', 'trusted', 'untrusted', 'changed', 'recheck', 'unverifiable', 'unchecked'];
export const RECHECK_TEXT = `${PRODUCT} reads a project's settings more strictly since you trusted them (the other tools' too) — look at them again`;
export const settingsState = (v: unknown): SettingsState | null => (SETTINGS.includes(v as SettingsState) ? (v as SettingsState) : null);
/** they apply (or there is nothing to apply; null: not said) */
export const settingsApplied = (v: SettingsState | null): boolean => v === null || v === 'workspace' || v === 'none' || v === 'trusted';
/** the state a new session by this harness goes by: Claude Code on Bedrock's (Claude Code's part), Claude on your
 *  plan's (its own plugin record), an agent of your subscriptions' (both parts) */
export const settingsStateFor = (v: { state: SettingsState; planState?: SettingsState; agentState?: SettingsState }, harness?: string | null): SettingsState =>
  !harness || harness === 'bedrock' ? v.state : harness === 'claude' ? (v.planState ?? v.state) : (v.agentState ?? v.state);
/** afterSettingsChoice(choice, harness, agentsComplete) -> whether the new session asked for starts after the settings
 *  dialog (choice: true — you trusted them; false — you stopped trusting them; null — start without them), else why
 *  not, said to you. After Stop trusting nothing starts (it would start without what you just took back, or an agent
 *  would be refused); after a Trust that could not cover the other tools' part, an agent does not either. */
export function afterSettingsChoice(choice: boolean | null, harness?: string | null, agentsComplete?: boolean): { start: boolean; why: string | null } {
  const agent = !!harness && harness !== 'bedrock' && harness !== 'claude';
  if (choice === false) return { start: false, why: 'did not start: you stopped trusting this project\'s settings' };
  if (choice === true && agent && agentsComplete === false) {
    return { start: false, why: 'did not start: the other tools\' settings here are not trusted (they could not all be shown), and an agent needs both parts' };
  }
  return { start: true, why: null };
}
/** holdForSettings(harness, project, state) -> whether a session by this harness in that project waits for its settings
 *  dialog first (the backend would refuse it otherwise: 409): an agent of your subscriptions, in a project (not the
 *  Workspace), whose settings are not applied for it — or could not be read ('failed': the dialog says why). Claude
 *  Code on Bedrock and Claude on your plan start without them, said in their session: never held here. */
export function holdForSettings(harness: string | null | undefined, project: { workspace?: boolean } | null | undefined, state: SettingsState | 'failed'): boolean {
  if (!harness || harness === 'bedrock' || harness === 'claude') return false;
  if (!project || project.workspace) return false;
  return state === 'failed' || !settingsApplied(state);
}
/** a session's process: what of its folder's settings it got */
export interface SessionSettings {
  state: SettingsState;
  project: string | null;
}
export function normSessionSettings(v: unknown): SessionSettings | null {
  const o = v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  const state = settingsState(o?.state);
  return o && state ? { state, project: projectIdOk(o.project) ? o.project : null } : null;
}
export interface Project {
  /** ws (the Workspace) or p_ and 8 hex */
  id: string;
  name: string;
  /** its folder in the workspace ('' : the workspace itself) */
  root: string;
  /** /workspace or /workspace/<root> (made here, never the backend's text) */
  path: string;
  created: number | null;
  workspace: boolean;
  /** what the sandbox says of its folder (null: not said) */
  folder: FolderState | null;
  git: boolean | null;
  /** its own Claude Code settings (null: not said) */
  settings: SettingsState | null;
  /** a folder of this computer (./stack project): root and path are its path in the sandbox */
  host?: boolean;
  /** read-only in the sandbox (a folder of this computer) */
  readOnly?: boolean;
  /** at /projects/<name>: its path on this computer kept out of what Claude Code sends the model and off the page (programs
   *  in the sandbox can still find it: /proc/self/mountinfo) */
  hidden?: boolean;
  /** no longer added (./stack removed it): its sessions listed, read only */
  gone?: boolean;
  /** what the running sandbox does not have yet as listed, until it restarts: 'add' (not mounted yet), 'ro' (listed
   *  read-only, still read-write there), 'rw' (listed read-write, still read-only there) — ./stack's word */
  pending?: 'add' | 'ro' | 'rw' | null;
  /** no longer added, but still mounted in the sandbox until it restarts */
  leaving?: boolean;
}
/** Where a session runs and which project it is shown in. */
export interface Where {
  project: string;
  /** /workspace or a folder of it */
  cwd: string;
}

export const projectIdOk = (v: unknown): v is string => v === WORKSPACE_ID || (typeof v === 'string' && ID.test(v));
/** A folder of the workspace a project may be (the backend's rule, projects.mjs rootOk): 1–4 names of 1–100 characters,
 *  none starting with "." or with a space at either end, no slash or backslash, no control or direction-changing
 *  character; at most 160 bytes. */
export function rootOk(v: unknown): v is string {
  if (typeof v !== 'string' || !v || new TextEncoder().encode(v).length > 160 || ODD.test(v) || v.includes('\\')) return false;
  const segs = v.split('/');
  return segs.length <= 4 && segs.every((s) => s.length >= 1 && s.length <= 100 && !s.startsWith('.') && s.trim() === s);
}
export const nameOk = (v: unknown): v is string => typeof v === 'string' && v.trim() === v && v.length >= 1 && v.length <= 80 && !ODD.test(v);
/** A folder of this computer's path in the sandbox as the backend may name it: absolute, plain (no empty, "." or ".."
 *  part), one line, no odd character, not /workspace, around or inside it. */
export function hostPathOk(v: unknown): v is string {
  if (typeof v !== 'string' || !v.startsWith('/') || v === '/' || v.length > 1024 || ODD.test(v) || v.endsWith('/')) return false;
  if (v === WORKSPACE_PATH || v.startsWith(`${WORKSPACE_PATH}/`) || WORKSPACE_PATH.startsWith(`${v}/`)) return false;
  return v.slice(1).split('/').every((x) => x !== '' && x !== '.' && x !== '..');
}
/** A session's working folder as the page takes it: /workspace or a folder of it, or a folder of this computer (or one
 *  in it); absolute, normalized, one line. */
export function cwdOk(v: unknown): v is string {
  if (typeof v !== 'string' || v.length > 1024 || /[\x00-\x1f\x7f]/.test(v)) return false;
  if (v === WORKSPACE_PATH) return true;
  const top = v.startsWith(`${WORKSPACE_PATH}/`) ? WORKSPACE_PATH : hostTopOf(v);
  if (!top) return false;
  return v === top || v.slice(top.length + 1).split('/').every((s) => s !== '' && s !== '.' && s !== '..');
}
export const pathOf = (root: string): string => (root.startsWith('/') ? root : root ? `${WORKSPACE_PATH}/${root}` : WORKSPACE_PATH);
export const WORKSPACE: Project = Object.freeze({ id: WORKSPACE_ID, name: 'Workspace', root: '', path: WORKSPACE_PATH, created: null, workspace: true, folder: null, git: null,
  settings: null });

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Obj) : null);
const FOLDERS: FolderState[] = ['dir', 'missing', 'link', 'other', 'unmounted'];

/** One project of GET /api/projects, checked; null when it does not fit (a folder outside the workspace, a bad id). */
export function normProject(v: unknown): Project | null {
  const o = obj(v);
  if (!o || !projectIdOk(o.id)) return null;
  const folder = FOLDERS.includes(o.folder as FolderState) ? (o.folder as FolderState) : null;
  const git = typeof o.git === 'boolean' ? o.git : null;
  const settings = settingsState(o.settings);
  if (o.id === WORKSPACE_ID) return { ...WORKSPACE, folder, git, settings: settings === null ? null : 'workspace' };
  // a folder of this computer: its path in the sandbox (the backend's list is ./stack's, checked there too)
  if (o.host === true) {
    if (!hostPathOk(o.root)) return null;
    const name = nameOk(o.name) ? o.name : label(o.root.split('/').pop(), 80);
    return { id: o.id, name, root: o.root, path: o.root, created: null, workspace: false, folder, git, settings: settings === 'workspace' ? null : settings,
      host: true, readOnly: o.mode === 'ro', hidden: o.hidden === true, gone: o.gone === true,
      pending: o.pending === 'add' || o.pending === 'ro' || o.pending === 'rw' ? o.pending : null, leaving: o.gone === true && o.leaving === true };
  }
  if (!rootOk(o.root)) return null;
  const created = typeof o.created === 'number' && Number.isFinite(o.created) && o.created > 0 ? o.created : null;
  const name = nameOk(o.name) ? o.name : label(o.root.split('/').pop(), 80);
  return { id: o.id, name, root: o.root, path: pathOf(o.root), created, workspace: false, folder, git, settings: settings === 'workspace' ? null : settings };
}
/** The list: the Workspace first (always there), then each project once (by id and by folder), at most 64 more. */
export function normProjects(list: unknown): Project[] {
  const out: Project[] = [];
  const ids = new Set<string>();
  const roots = new Set<string>();
  for (const v of Array.isArray(list) ? list.slice(0, 200) : []) {
    const p = normProject(v);
    if (!p || ids.has(p.id) || roots.has(p.root)) continue;
    if (!p.workspace && out.filter((x) => !x.workspace).length >= PROJECTS_MAX) break;
    ids.add(p.id);
    roots.add(p.root);
    out.push(p);
  }
  const ws = out.find((p) => p.workspace) ?? { ...WORKSPACE };
  // (no two folders of this computer around each other: the second goes)
  const kept: Project[] = [];
  for (const p of out.filter((x) => !x.workspace)) {
    if (p.host && kept.some((k) => k.host && (k.root === p.root || k.root.startsWith(`${p.root}/`) || p.root.startsWith(`${k.root}/`)))) continue;
    kept.push(p);
  }
  return [ws, ...kept];
}
/** The folders of this computer the sandbox sees now (not those no longer added): their paths, for text.ts setHostTops. */
export const liveHostTops = (projects: Project[]): string[] => projects.filter((p) => p.host && !p.gone).map((p) => p.root);
/** …and those of them added read-only (text.ts readOnlyTopOf: the page edits, stages and commits nothing there). */
export const readOnlyTops = (projects: Project[]): string[] => projects.filter((p) => p.host && !p.gone && p.readOnly).map((p) => p.root);
/** …and those no longer added (text.ts goneTopOf: a listed session may have run there; nothing else of the page is). */
export const goneTops = (projects: Project[]): string[] => projects.filter((p) => p.host && p.gone).map((p) => p.root);
/** A session's folder in a folder of this computer no longer added (absolute, plain) — a session listed read only. */
export function goneCwdOk(v: unknown): v is string {
  if (typeof v !== 'string' || v.length > 1024 || /[\x00-\x1f\x7f]/.test(v)) return false;
  const top = goneTopOf(v);
  return !!top && (v === top || v.slice(top.length + 1).split('/').every((s) => s !== '' && s !== '.' && s !== '..'));
}

/** The project a session is shown in: the one the backend says when it is in the list, else the Workspace. */
export function projectFor(id: string, where: Record<string, Where>, projects: Project[]): string {
  const w = where[id];
  return w && projects.some((p) => p.id === w.project) ? w.project : WORKSPACE_ID;
}
/** The project whose folder holds a working folder (the deepest one), else the Workspace — what the backend decides for
 *  a session nobody filed by hand (used for one this page starts, before the list says). */
export function projectOfCwd(cwd: string, projects: Project[]): string {
  let best: Project | null = null;
  for (const p of projects) if (!p.workspace && (cwd === p.path || cwd.startsWith(`${p.path}/`)) && (!best || p.root.length > best.root.length)) best = p;
  return best?.id ?? WORKSPACE_ID;
}

/** A project's sessions for the Projects tab: the ones open in this page (by id, the order they were opened) and the
 *  others the backend lists (newest first), each project's own. */
export interface ProjectSessions {
  open: string[];
  recent: SessionInfo[];
}
export function sessionsByProject(projects: Project[], open: string[], listed: SessionInfo[], where: Record<string, Where>): Record<string, ProjectSessions> {
  const out: Record<string, ProjectSessions> = {};
  for (const p of projects) out[p.id] = { open: [], recent: [] };
  const openSet = new Set(open);
  for (const id of open) out[projectFor(id, where, projects)].open.push(id);
  for (const s of listed) if (!openSet.has(s.id)) out[projectFor(s.id, where, projects)].recent.push(s);
  return out;
}

/** A path of the workspace as an @-mention for a session that runs in `cwd`: relative to that folder when it is in it
 *  (as Claude Code resolves a mention), else its absolute path in the sandbox. */
export function mentionPath(wsPath: string, cwd: string): string {
  // (a page path: relative to the workspace, or absolute in a folder of this computer)
  const abs = wsPath.startsWith('/') ? wsPath : wsPath ? `${WORKSPACE_PATH}/${wsPath}` : WORKSPACE_PATH;
  if (cwd === WORKSPACE_PATH && !wsPath.startsWith('/')) return wsPath;
  const slash = abs.endsWith('/');
  const dir = slash ? abs.slice(0, -1) : abs;
  if (dir === cwd) return slash ? './' : '.';
  return abs.startsWith(`${cwd}/`) ? abs.slice(cwd.length + 1) : abs;
}
/** A path typed after @ (relative to the session's folder, or absolute in /workspace) as a path of the workspace — null
 *  for one outside it (or with a "." or ".." part). */
export function workspacePath(p: string, cwd: string): string | null {
  if (typeof p !== 'string' || !p || p.length > 4096 || p.includes('\0')) return null;
  const abs = p.startsWith('/') ? p : `${cwd}/${p}`;
  // (in a folder of this computer: the page's path is the absolute one)
  const top = hostTopOf(abs);
  if (top) {
    const tail = abs.slice(top.length).replace(/^\//, '');
    const segs = (tail.endsWith('/') ? tail.slice(0, -1) : tail).split('/');
    return tail && segs.some((x) => x === '' || x === '.' || x === '..') ? null : abs.endsWith('/') ? abs.slice(0, -1) : abs;
  }
  if (abs !== WORKSPACE_PATH && !abs.startsWith(`${WORKSPACE_PATH}/`)) return null;
  const rest = abs === WORKSPACE_PATH ? '' : abs.slice(WORKSPACE_PATH.length + 1);
  const parts = (rest.endsWith('/') ? rest.slice(0, -1) : rest).split('/');
  if (rest && parts.some((x) => x === '' || x === '.' || x === '..')) return null;
  return rest;
}
/** A path of the workspace is in a project's folder (the Workspace: every path). */
export const inProject = (wsPath: string, root: string): boolean => !root || wsPath === root || wsPath.startsWith(`${root}/`);
/** A path of the workspace as the project shows it (relative to its folder). */
export const shownIn = (wsPath: string, root: string): string => (root && wsPath.startsWith(`${root}/`) ? wsPath.slice(root.length + 1) : wsPath);

/** GET /api/projects/ID/settings: a project's own Claude Code settings — what they set (text only), their hash. */
export interface SettingsFile {
  /** .mcp.json, or a path under .claude/ (or another tool's: .codex/, .github/ …) */
  name: string;
  /** name: a folder no tool here reads, listed by its name alone */
  type: 'file' | 'link' | 'big' | 'other' | 'name';
  size: number | null;
  target: string | null;
}
/** A hook or an MCP server: the friendly line, its whole entry (canonical JSON), whether it names more than one of
 *  a command, a URL and a prompt, and whether it needs a careful look (long whitespace runs, many lines). */
export interface SettingsEntry {
  json: string;
  mixed: boolean;
  careful: boolean;
}
export interface SettingsSummary {
  hooks: ({ file: string; event: string; matcher: string; command: string } & SettingsEntry)[];
  allow: string[];
  ask: string[];
  deny: string[];
  defaultMode: string | null;
  directories: string[];
  env: { file: string; name: string; value: string }[];
  commands: { file: string; key: string; command: string }[];
  mcp: { file: string; key: string; value: string }[];
  mcpServers: ({ name: string; run: string } & SettingsEntry)[];
  other: { file: string; key: string; value: string }[];
  notes: { file: string; note: string }[];
  /** every file under .claude/ but the two settings files, with the front matter keys that grant something */
  files: { name: string; size: number | null; grants: { key: string; value: string }[] }[];
  /** other tools' files in the folder (.codex/, .cursor/, .github/hooks/ …: your subscriptions' agents read them), whole */
  tools: { file: string; tool: string; text: string; careful: boolean }[];
  /** the plugins the settings turn on (each installed in the sandbox: its version) or off */
  plugins: { file: string; id: string; on: boolean; version: string | null; planVersion: string | null }[];
  /** every key and value of the files is above, whole (else: never trustable — what was left out, in `missing`) */
  complete: boolean;
  missing: string[];
  /** the other tools' part shown whole too (else Trust covers Claude Code's part alone: agents do not start there) */
  agentsComplete: boolean;
  agentsMissing: string[];
}

// A value of the trust summary that could hide something in plain sight: any character but printable ASCII, a tab or a
// line break (shown as ⟨U+XXXX⟩), a run of 20+ whitespace characters, more than 60 of them in all, or more than 5 lines.
// --- the trust summary's text rule: the same lines in code/server/trust.mjs (tests/test_code.sh compares them) ---
const NOT_PLAIN = /[^\x20-\x7e\t\n]/;
const looksHidden = (t: string): boolean => NOT_PLAIN.test(t) || /\s{20,}/.test(t) || (t.match(/\s/g) ?? []).length > 60 || (t.match(/\n/g) ?? []).length > 5;
// --- end of the rule ---
/** The dialog folds such a value until you open it in full, and Trust waits for that (the backend's careful flag, by
 *  the same rule). */
export const needsLook = (t: string): boolean => looksHidden(t);
/** A value as the trust dialog shows it: printable ASCII as is; ⏎ for a line break, → for a tab, · for each space of a
 *  run of 3 or more; every other character as ⟨U+XXXX⟩ — nothing hides behind a character you cannot see or tell apart,
 *  or on a line out of sight. */
export const visibleWs = (t: string): string =>
  t.replace(/ {3,}|[^\x20-\x7e]/gu, (m) => (m[0] === ' ' ? '·'.repeat(m.length) : m === '\n' ? '⏎' : m === '\t' ? '→'
    : `⟨U+${(m.codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, '0')}⟩`));
export interface SettingsView {
  project: string;
  path: string;
  state: SettingsState;
  /** Claude on your plan's state (its own plugin record) — reason plan-plugins: a plugin they turn on is not installed there */
  planState: SettingsState;
  planReason: string | null;
  /** an agent of your subscriptions': both parts (Claude Code's and the other tools') */
  agentState: SettingsState;
  /** what trusting them names (null: nothing that can be trusted) */
  hash: string | null;
  trustedAt: number | null;
  files: SettingsFile[];
  /** rows the backend listed past the first FILES_MAX (both parts together can have more): not listed here, said so */
  filesMore: number;
  summary: SettingsSummary;
  /** why not all of them could be shown, in the sandbox's own words (not one of bn-coded's): apart (SandboxSaid) */
  said: SandboxWords | null;
}
const FILE_TYPES = ['file', 'link', 'big', 'other', 'name'];
const FILES_MAX = 500;
// the backend shows at most 200 entries a section and 2,000 characters a value (with its own "… more characters not
// shown"): anything beyond that here, too, makes the summary incomplete — never trustable
const LIST_MAX = 200, TEXT_MAX = 2100;
// (another tool's file: shown whole up to 16,000 characters, its "… more characters not shown" beside)
const TOOL_TEXT_MAX = 16100;
/** The backend's view of a project's settings, checked (everything as text); null when it does not fit. Nothing is cut
 *  silently: whatever does not fit makes it incomplete. */
export function normSettingsView(v: unknown): SettingsView | null {
  const o = obj(v);
  const state = settingsState(o?.state);
  if (!o || !state || !projectIdOk(o.project)) return null;
  // (what does not fit: cut — Claude Code's part, which the hash needs whole —, or agentCut while the other tools' own
  // notes and tools are read: their part alone)
  let cut = false, agentCut = false, theirs = false;
  const mark = () => { if (theirs) agentCut = true; else cut = true; };
  const one = (x: unknown, max = 300): string => { if (typeof x !== 'string') return ''; if (x.length > max) mark(); return label(x, max); };
  // (a value as it is — the dialog shows every character but printable ASCII as an escape: visibleWs)
  const many = (x: unknown): string => { if (typeof x !== 'string') return ''; if (x.length > TEXT_MAX) mark(); return x.slice(0, TEXT_MAX); };
  const rows = <T>(x: unknown, f: (r: Obj) => T): T[] => {
    if (!Array.isArray(x)) return [];
    if (x.length > LIST_MAX) mark();
    return x.slice(0, LIST_MAX).map((r) => (obj(r) ? f(obj(r) as Obj) : null)).filter((r): r is T => r !== null);
  };
  const texts = (x: unknown): string[] => {
    if (!Array.isArray(x)) return [];
    if (x.length > LIST_MAX) cut = true;
    return x.slice(0, LIST_MAX).filter((r) => typeof r === 'string').map(many);
  };
  // (an older backend without the whole entry: what it showed is all there is — never complete)
  const entry = (r: Obj): SettingsEntry => {
    if (typeof r.json !== 'string') cut = true;
    const json = many(r.json);
    return { json, mixed: r.mixed === true, careful: r.careful === true || needsLook(json) };
  };
  const s = obj(o.summary) ?? {};
  const toolRow = (t: Obj) => {
    const text = typeof t.text === 'string' ? t.text : '';
    if (text.length > TOOL_TEXT_MAX) mark();
    const shown = text.slice(0, TOOL_TEXT_MAX);
    return { file: many(t.file), tool: one(t.tool, 60), text: shown, careful: t.careful === true || needsLook(shown) };
  };
  const noteRow = (x: Obj) => ({ file: many(x.file), note: one(x.note, 1200) });
  // (the other tools' part's own notes and tools, each within the page's cut of its own: shown with Claude Code's)
  theirs = true;
  const agentNotes = rows(s.agentNotes, noteRow), agentTools = rows(s.agentTools, toolRow);
  theirs = false;
  const summary: SettingsSummary = {
    hooks: rows(s.hooks, (h) => ({ file: one(h.file, 60), event: one(h.event, 200), matcher: many(h.matcher), command: many(h.command), ...entry(h) })),
    allow: texts(s.allow), ask: texts(s.ask), deny: texts(s.deny),
    defaultMode: typeof s.defaultMode === 'string' ? many(s.defaultMode) : null,
    directories: texts(s.directories),
    env: rows(s.env, (e) => ({ file: one(e.file, 60), name: many(e.name), value: many(e.value) })),
    commands: rows(s.commands, (c) => ({ file: one(c.file, 60), key: one(c.key, 60), command: many(c.command) })),
    mcp: rows(s.mcp, (c) => ({ file: one(c.file, 60), key: one(c.key, 60), value: many(c.value) })),
    mcpServers: rows(s.mcpServers, (m) => ({ name: many(m.name), run: many(m.run), ...entry(m) })),
    other: rows(s.other, (x) => ({ file: one(x.file, 60), key: many(x.key), value: many(x.value) })),
    notes: [...rows(s.notes, noteRow), ...agentNotes],
    plugins: rows(s.plugins, (x) => ({ file: one(x.file, 60), id: many(x.id), on: x.on === true, version: typeof x.version === 'string' ? many(x.version) : null,
      planVersion: typeof x.planVersion === 'string' ? many(x.planVersion) : null })),
    files: (() => {
      if (!Array.isArray(s.files)) return [];
      if (s.files.length > FILES_MAX) cut = true;
      return s.files.slice(0, FILES_MAX).map((f) => obj(f)).filter((f): f is Obj => !!f)
        .map((f) => ({ name: many(f.name), size: typeof f.size === 'number' && f.size >= 0 ? f.size : null, grants: rows(f.grants, (g) => ({ key: many(g.key), value: many(g.value) })) }));
    })(),
    tools: [...rows(s.tools, toolRow), ...agentTools],
    complete: false,
    missing: Array.isArray(s.missing) ? s.missing.slice(0, 20).filter((x) => typeof x === 'string').map((x) => label(x, 200)) : [],
    agentsComplete: false,
    agentsMissing: Array.isArray(s.agentsMissing) ? s.agentsMissing.slice(0, 20).filter((x) => typeof x === 'string').map((x) => label(x, 200)) : [],
  };
  summary.complete = s.complete === true && !cut;
  // (an older backend without the split: the other tools' files were in the one part)
  summary.agentsComplete = (s.agentsComplete === undefined ? s.complete === true : s.agentsComplete === true) && !cut && !agentCut;
  if (cut) summary.missing.push('more than this page shows');
  if (cut || agentCut) summary.agentsMissing.push('more than this page shows');
  return {
    project: o.project, path: cwdOk(o.path) ? o.path : WORKSPACE_PATH, state,
    planState: settingsState(o.planState) ?? state, planReason: o.planReason === 'plan-plugins' ? 'plan-plugins' : null,
    agentState: settingsState(o.agentState) ?? state,
    // (a hash to trust only with a summary shown whole)
    hash: summary.complete && typeof o.hash === 'string' && /^[0-9a-f]{64}$/.test(o.hash) ? o.hash : null,
    trustedAt: typeof o.trustedAt === 'number' && Number.isFinite(o.trustedAt) && o.trustedAt > 0 ? o.trustedAt : null,
    files: Array.isArray(o.files) ? o.files.slice(0, FILES_MAX).map((f) => obj(f)).filter((f): f is Obj => !!f && typeof f.name === 'string' && FILE_TYPES.includes(f.type as string))
      .map((f) => ({ name: f.name as string, type: f.type as SettingsFile['type'], size: typeof f.size === 'number' && f.size >= 0 ? f.size : null, target: typeof f.target === 'string' ? label(f.target, 300) : null }))
      : [],
    filesMore: Array.isArray(o.files) ? Math.max(0, o.files.length - FILES_MAX) : 0,
    summary,
    said: typeof o.said === 'string' && o.said ? { said: label(o.said, 300), by: 'sandbox' } : null,
  };
}
