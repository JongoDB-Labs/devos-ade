// Projects made by themselves (JON-1059): a git repository or a project folder that appears in the workspace — an agent made it in
// the Terminal, you cloned it there — is a project of the Code page without a click, and is kept on the built-in git server when
// it can be. Looked for whenever the Code page lists the projects and every 45 s while a page is connected (main.mjs); one look at a
// time, at most one per MIN_GAP_MS, bounded: bn-coded's git.repos (files: true) lists at most 50 repositories (two levels down) and 50
// folders (the workspace's direct children, no link followed), this adds at most ADD_MAX projects and keeps at most KEEP_MAX per look.
//   what becomes a project   a repository (git.repos, a real .git folder), or a direct child of the workspace that is no repository
//                            and holds a common project file (package.json, pyproject.toml, go.mod …)
//   what never does          a folder that is a project already, is inside one or around one, or that you removed from the Code page
//                            (projects.mjs removed — remembered, also what "Not now" of the first version left)
//   kept on the local git server   a repository with no remote of its own, while the built-in server is connected as a Git host, its
//                            host lets Claude use it (the same switch the terminal's git needs) and the folder's name is a repository name;
//                            one with a remote (a clone) is added, not kept — its line offers Keep it on your local git server; a
//                            folder without git is added, not kept — its line offers Start git here, and once git is there the same rule applies
// Nothing here changes a project's trust or settings; a failure is logged once (the same words again are not).
import { rootOk, nameOk as projectNameOk } from './projects.mjs';
import { nameOk as repoNameOk } from './keep.mjs';
import { mayKeep } from './termlink.mjs';
import { short } from './validate.mjs';

export const AUTO_MS = 45000, MIN_GAP_MS = 3000, ADD_MAX = 10, KEEP_MAX = 5;

/** makeAutoProjects({call, projects, addProject, keeper, mirrors, hosts, remoteState, log, now}) -> {scan(), running}
 *  projects() — the store (projects.mjs); addProject(b) — api.addProject; keeper() — keep.mjs's API (keep); mirrors.owner() — the built-in
 *  server's account or null; hosts() — the git hosts (githosts.mjs); remoteState(rel) — gitremote.mjs's state ({repo, remotes}) */
export function makeAutoProjects({ call, projects, addProject, keeper, mirrors, hosts, remoteState, log = () => {}, now = () => Date.now() }) {
  let inflight = null, last = 0;
  const told = new Set();   // failures already logged
  const once = (key, text) => { if (told.has(key)) return; if (told.size > 50) told.clear(); told.add(key); log(`autoproj: ${short(text, 240)}`); };
  const unknownOp = (e) => /unknown op/.test(e?.message || '');
  const under = (r, top) => r === top || r.startsWith(`${top}/`);

  async function look() {
    let res;
    try {
      res = (await call({ op: 'git.repos', files: true }, { timeoutMs: 15000 })).result;
    } catch (e) {
      // (a sandbox older than this page does not know the field or the op: nothing to look at until it restarts — said once)
      if (unknownOp(e)) { once('old', 'the sandbox is older than this Code page: no automatic projects until it restarts'); return; }
      once(`look:${e?.message}`, `looking at the workspace: ${e?.message || e}`);
      return;
    }
    told.delete('old');
    const repos = (Array.isArray(res?.repos) ? res.repos : []).filter((r) => r && r.kind === 'dir' && rootOk(r.path)).map((r) => r.path);
    const plain = Array.isArray(res?.folders) ? res.folders.filter((f) => f && rootOk(f.path)).map((f) => f.path) : [];
    const store = projects();
    const roots = store.list().filter((p) => !p.workspace && !p.host && !p.gone).map((p) => p.root);
    const removed = new Set(store.removedRoots());
    const clash = (r) => roots.some((x) => under(x, r) || under(r, x));
    let added = 0;
    for (const folder of [...repos, ...plain]) {
      if (added >= ADD_MAX) break;
      if (removed.has(folder) || clash(folder)) continue;
      try {
        const a = await addProject({ kind: 'folder', folder });
        store.addNotice(a.project.id);
        roots.push(folder);
        added++;
        log(`autoproj: ${folder} is a project (found in the workspace)`);
      } catch (e) {
        // (a 409: it became a project, or there is no room, meanwhile — not worth a line each time)
        if (e?.status !== 409) once(`add:${folder}:${e?.message}`, `${folder}: not added: ${e?.message || e}`);
      }
    }
    await keepThem(new Set(repos));
  }

  // keepThem(repos) — the projects told of that are not decided yet: kept when the rule says, else left (a switch turned on later counts)
  async function keepThem(repos) {
    const todo = store().notices().filter((n) => !n.tried);
    if (!todo.length) return;
    let owner = null, may = false;
    try { owner = mirrors.owner(); may = mayKeep(hosts()); } catch { owner = null; }
    if (owner === null || !may) return;
    let kept = 0;
    for (const n of todo) {
      if (kept >= KEEP_MAX) break;
      const p = store().get(n.id);
      if (!p || p.host || !repos.has(p.root) || !projectNameOk(p.name) || !repoNameOk(p.name)) continue;
      if (store().localgit(n.id)) { store().noticeTried(n.id); continue; }   // (kept, or declined, by hand meanwhile)
      try {
        const st = await remoteState(p.root);
        if (!st?.repo) continue;
        if (st.remotes.length) { store().noticeTried(n.id); continue; }   // a remote of its own: added, not kept (its line offers it)
        kept++;
        store().noticeTried(n.id);
        const k = await keeper().keep(n.id, { name: p.name });
        log(`autoproj: ${p.name} is kept as ${k.repo}`);
      } catch (e) {
        once(`keep:${n.id}:${e?.message}`, `${p.name}: not kept: ${e?.message || e}`);
      }
    }
  }
  const store = () => projects();

  /** scan({force}) -> a promise of the look: one at a time (callers meanwhile share it); within MIN_GAP_MS of the last, nothing */
  function scan({ force = false } = {}) {
    if (inflight) return inflight;
    if (!force && now() - last < MIN_GAP_MS) return Promise.resolve();
    inflight = look().catch((e) => once(`scan:${e?.message}`, `${e?.message || e}`)).finally(() => { inflight = null; last = now(); });
    return inflight;
  }
  return { scan, get running() { return inflight !== null; } };
}
