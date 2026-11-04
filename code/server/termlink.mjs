// The terminal's `project` command (terminal/bin/project) to the Code page (JON-1059). A repository made in the terminal
// becomes a project, and a project can be kept on the built-in git server (keep.mjs), without a new port: the code
// container keeps one connection open to the sandbox's daemon (spawn-client.mjs sandboxBroker, op project.link — always, since
// it grants nothing by itself), and bn-coded relays the command's checked requests down it as ASK frames. This file is this
// side's answer to them, and the code container checks it all again: the folder is a project's by projects.mjs's rules and
// the sandbox's own look (a real folder, never through a link), and nothing here changes a project's trust or settings.
//   info   whether the built-in server is connected (its account, the address of a repository there) and whether the
//          sandbox's git may use it: the same switch as Claude's own git anywhere (Let Claude use this host: on by default for the Local git server, off for every other host)
//   add    a folder of the workspace becomes a project (a record: a name and a folder; one that is a project already is told so)
//   keep   add, then keep it on the built-in git server (a private repository, the remote added, the first push) — only while
//          that switch is on: pushing for the sandbox's git is the same thing that switch lets Claude do, so it is not
//          done without it. The project is added either way, and the answer says what is left to do.
// Page state only; every refusal is a plain sentence the command prints.
import { LOCALGIT } from './githosts.mjs';
import { short } from './validate.mjs';

const RETRY_MS = 5000, RETRY_SLOW_MS = 60000;

/** mayKeep(hosts) -> whether the sandbox's git may use the built-in git server (its host lets Claude use it) */
export const mayKeep = (hosts) => (Array.isArray(hosts) ? hosts : []).some((h) => h?.builtin === LOCALGIT.id && h.claude === true);

/** makeTermLink({open, answer, log}) -> {start(), close()}: keeps the connection open (open: sandboxBroker with op project.link;
 *  answer(q): the answer to one question), opened again after the sandbox restarts. A sandbox older than this page refuses the
 *  op ("unknown op"): looked for again once a minute. */
export function makeTermLink({ open, answer, log = () => {}, retryMs = RETRY_MS, slowMs = RETRY_SLOW_MS }) {
  let conn = null, timer = null, closing = false, opening = false;
  const again = (ms) => { clearTimeout(timer); if (!closing) { timer = setTimeout(() => { void connect(); }, ms); timer.unref?.(); } };
  async function connect() {
    if (closing || conn || opening) return;
    opening = true;
    try {
      const c = await open({ onAsk: answer, op: 'project.link' });
      conn = c;
      c.closed.then(() => { if (conn === c) conn = null; again(retryMs); });
    } catch (e) {
      if (!/unknown op/.test(e?.message || '')) log(`project link: ${short(e?.message, 200)}`);
      again(/unknown op/.test(e?.message || '') ? slowMs : retryMs * 3);
    } finally { opening = false; }
  }
  return {
    start: () => connect(),
    close() { closing = true; clearTimeout(timer); if (conn) { const c = conn; conn = null; c.close(); } },
  };
}

/** makeProjectAnswer({addProject, projects, keeper, mirrors, hosts, now, log}) -> answer(q): the answer to a question
 *  {kind: 'project', op, folder?, name?, repo?} (always an object: {ok: true, …} or {error}) */
export function makeProjectAnswer({ addProject, projects, keeper, mirrors, hosts, log = () => {}, words = () => null }) {
  const said = (e) => ({ error: words(e)?.error || short(e?.message || String(e), 300) });
  const view = () => {
    let owner = null, may = false;
    try { owner = mirrors.owner(); } catch { owner = null; }
    try { may = mayKeep(hosts()); } catch { may = false; }
    return { owner, may };
  };
  // the project of a folder, added when it is not one yet: {project, existing}
  async function ensure(folder, name) {
    const had = projects().list().find((p) => p.root === folder);
    if (had) {
      // (a folder the Code server made a project by itself a moment before — autoproj.mjs, while a page is open — is the user's now:
      // its "Added from the workspace" notice goes, and a name typed here is its name)
      const store = projects();
      try { store.dismissNotice?.(had.id); } catch { /* no notice, or not a project of the list's any more */ }
      if (name && name !== had.name && typeof store.rename === 'function') return { project: store.rename(had.id, name), existing: true };
      return { project: had, existing: true };
    }
    const added = await addProject({ kind: 'folder', folder, ...(name ? { name } : {}) });
    return { project: added.project, existing: false, git: added.git === true };
  }
  return async function answer(q) {
    if (!q || q.kind !== 'project') return {};
    try {
      if (q.op === 'info') {
        const { owner, may } = view();
        return { ok: true, available: owner !== null, mayKeep: may, ...(owner ? { owner, url: `https://${LOCALGIT.host}:${LOCALGIT.port}/${owner}/` } : {}) };
      }
      if (typeof q.folder !== 'string') return { error: 'no folder' };
      if (q.op === 'add') {
        const r = await ensure(q.folder, q.name);
        log(`terminal: ${r.project.name} (${q.folder}) ${r.existing ? 'is a project already' : 'added as a project'}`);
        return { ok: true, id: r.project.id, name: r.project.name, existing: r.existing, ...(r.git !== undefined ? { git: r.git } : {}) };
      }
      if (q.op === 'keep') {
        const { owner, may } = view();
        if (owner === null) return { error: 'the built-in git server is not connected as a Git host: ./stack up connects it' };
        const r = await ensure(q.folder, q.name);
        if (!may) {
          return { ok: true, id: r.project.id, name: r.project.name, existing: r.existing, kept: false,
            note: 'the project is added, but not kept on the local git server: git in this terminal has no login for it. Turn on "Let Claude use this host" for the Local git server (Code page > Git hosts), or use "Keep it on your local git server" in the project\'s Git panel' };
        }
        try {
          const k = await keeper().keep(r.project.id, { ...(q.repo ? { name: q.repo } : {}) });
          return { ok: true, id: r.project.id, name: r.project.name, existing: r.existing, kept: true, repo: k.repo || '' };
        } catch (e) {
          // (already kept: the answer is the same; any other refusal is the project added, not kept, and why)
          if (/keeps this project already/.test(e?.message || '')) return { ok: true, id: r.project.id, name: r.project.name, existing: true, kept: true, repo: (await keeper().view(r.project.id)).repo || '' };
          return { ...said(e), id: r.project.id, name: r.project.name, note: 'the project is added, not kept' };
        }
      }
      return { error: 'unknown request' };
    } catch (e) {
      return said(e);
    }
  };
}
