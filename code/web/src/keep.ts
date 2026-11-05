// Keeping a project on the built-in git server (the Git panel's offer and its "Kept on your local git server" part, the New
// project dialog's box; backend: code/server/keep.mjs), kept free of DOM and network (test/keep.test.ts): the answer of
// GET /api/projects/:id/keep checked, the repository's name as the backend makes it of a project's, when the offer and the box
// are shown, what the box sends, and the portal's Git page addresses the buttons go to.
import { label } from './text';

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Obj) : null);
const OWNER = /^[A-Za-z0-9][A-Za-z0-9._@+-]{0,99}$/;
const REPO = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const BRANCH = /^[A-Za-z0-9_][A-Za-z0-9._/+-]{0,199}$/;
const RESERVED = /\.(git|wiki|rss|atom)$/i;

/** What the backend says of a project and the built-in git server. state: null — not asked yet; declined — "Not for this project". */
export interface KeepView {
  /** the built-in git server is connected as a Git host (otherwise there is nothing to keep it on) */
  available: boolean;
  owner: string | null;
  /** the repository name the project's name makes */
  suggested: string;
  state: 'kept' | 'declined' | null;
  /** kept: owner/name, and the remote it was added as in the project's repository */
  repo: string | null;
  remote: string | null;
  /** the repository exists on the server (the first push with commits makes it) */
  made: boolean;
  auto: boolean;
  /** commit my work at the end of each agent turn (off until asked for) */
  autoCommit: boolean;
  /** when it was last pushed (ms), or null */
  pushedAt: number | null;
  lastError: string | null;
  /** a push is on its way now */
  busy: boolean;
  /** the branches not pushed yet (null: git was not asked just now) */
  unpushed: string[] | null;
  /** what the server refused, as the backend words it ("main: the local git server has commits this project doesn't — pull first") */
  rejected: string[];
}

/** repoSlug(name) -> a repository name Forgejo takes, made of a project's name (the backend's repoSlug, the same: a test keeps them
 *  equal): letters, digits, . _ -, at most 100, starting with a letter or digit, not ending in .git, .wiki, .rss or .atom. */
export function repoSlug(name: unknown): string {
  const trim = (t: string) => t.replace(/^[^A-Za-z0-9]+/, '').replace(/[-.]+$/, '');
  let s = trim(String(name ?? '').normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9_.-]+/g, '-').replace(/-{2,}/g, '-')).slice(0, 100);
  s = trim(s);
  while (RESERVED.test(s)) s = trim(s.replace(RESERVED, ''));
  return s || 'project';
}
/** Whether v is a repository name the backend takes. */
export const repoNameOk = (v: unknown): v is string => typeof v === 'string' && REPO.test(v) && !RESERVED.test(v);

/** normKeep(v) -> the answer checked, or null when it does not fit. */
export function normKeep(v: unknown): KeepView | null {
  const o = obj(v);
  if (!o) return null;
  const owner = typeof o.owner === 'string' && OWNER.test(o.owner) ? o.owner : null;
  const state = o.state === 'kept' || o.state === 'declined' ? o.state : null;
  const repo = typeof o.repo === 'string' && /^[A-Za-z0-9][A-Za-z0-9._@+-]{0,99}\/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(o.repo) ? o.repo : null;
  if (state === 'kept' && !repo) return null;
  const list = (x: unknown, max: number, ok: (s: string) => boolean): string[] => (Array.isArray(x) ? x.slice(0, max).filter((s): s is string => typeof s === 'string' && ok(s)).map((s) => label(s, 300)) : []);
  return {
    available: o.available === true && owner !== null,
    owner,
    suggested: repoNameOk(o.suggested) ? o.suggested : 'project',
    state,
    repo: state === 'kept' ? repo : null,
    made: state === 'kept' && o.made === true,
    remote: state === 'kept' && typeof o.remote === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(o.remote) ? o.remote : null,
    auto: o.auto !== false,
    autoCommit: state === 'kept' && o.autoCommit === true,
    pushedAt: typeof o.pushedAt === 'number' && Number.isFinite(o.pushedAt) && o.pushedAt > 0 ? o.pushedAt : null,
    lastError: typeof o.lastError === 'string' && o.lastError ? label(o.lastError, 400) : null,
    busy: o.busy === true,
    unpushed: Array.isArray(o.unpushed) ? list(o.unpushed, 100, (s) => BRANCH.test(s)) : null,
    rejected: list(o.rejected, 100, (s) => s.length <= 400),
  };
}

/** Whether the Git panel offers to keep the project: the built-in server is there, nothing was answered yet (or you asked from the
 *  menu: `asked`), and the panel shows the project's own repository (its folder is the repository — not one around it or inside it). */
export function offerShown(k: KeepView | null, found: 'self' | 'above' | 'inside' | null, isRepo: boolean, asked = false): boolean {
  return !!k && k.available && isRepo && found === 'self' && (k.state === null || (asked && k.state === 'declined'));
}
/** Whether the panel shows the "Kept on your local git server" part. */
export const keptShown = (k: KeepView | null, found: 'self' | 'above' | 'inside' | null, isRepo: boolean): k is KeepView => !!k && k.state === 'kept' && isRepo && found === 'self';

/** The New project dialog's box: shown when the built-in server is there (for an empty folder, a clone, a folder of the workspace;
 *  not for a folder of this computer), on by default. */
export const boxShown = (available: boolean | null, kind: 'empty' | 'clone' | 'folder' | 'computer'): boolean => available === true && kind !== 'computer';

/** What the dialog sends to make the project (POST /api/projects). A kept empty folder is a repository, so git init is implied. */
export function newProjectBody(kind: 'empty' | 'folder', folder: string, o: { git: boolean; keep: boolean }): { kind: 'new' | 'folder'; folder: string; git?: boolean; keep?: boolean } {
  return kind === 'empty' ? { kind: 'new', folder, git: o.git || o.keep, ...(o.keep ? { keep: true } : {}) } : { kind: 'folder', folder, ...(o.keep ? { keep: true } : {}) };
}

/** The portal's Git page for a kept repository: its place after #git/ — the repository, or its issues or pull requests — or null. */
export function gitPlace(repo: string | null, sub: '' | 'issues' | 'pulls' = ''): string | null {
  if (!repo || !/^[A-Za-z0-9][A-Za-z0-9._@+-]{0,99}\/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(repo)) return null;
  return sub ? `${repo}/${sub}` : repo;
}
/** The portal's address of that place (a tab of its own: where this page is not framed by the portal), or null. */
export function gitPlaceUrl(portalOrigin: string | null | undefined, place: string | null): string | null {
  if (!portalOrigin || !place) return null;
  try {
    const u = new URL(portalOrigin);
    return u.protocol === 'http:' || u.protocol === 'https:' ? `${u.origin}/#git/${place}` : null;
  } catch {
    return null;
  }
}

/** The one line under "Kept on your local git server": when it was last pushed and what has not been pushed yet. */
export function keptLine(k: KeepView, ago: (t: number) => string): string {
  const when = k.pushedAt ? `Last pushed ${ago(k.pushedAt)}.` : 'Nothing pushed yet.';
  if (k.unpushed === null) return when;
  if (!k.unpushed.length) return `${when} Everything is pushed.`;
  const names = k.unpushed.slice(0, 5).map((b) => label(b, 60)).join(', ');
  return `${when} Not pushed yet: ${names}${k.unpushed.length > 5 ? ` and ${k.unpushed.length - 5} more` : ''}.`;
}
