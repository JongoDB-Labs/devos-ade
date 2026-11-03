// Keep a project on the built-in git server (Forgejo; lib/localgit.sh, JON-1005): the Code page asks once per project, and
// when you say yes it makes a private repository for it on the server (Forgejo's API, through the mirrors.mjs route to Caddy's
// internal site), adds it as a remote of the project's repository and pushes — then keeps pushing by itself: after a commit
// made in the Git panel, after a session's turn in the project, and every 10 minutes for what moved meanwhile.
// The pushes are the Git panel's own (gitremote.mjs plan and run: the same URL rules, credential and CA as Publish), one
// branch at a time to the branch of that name, never forced. A branch the server would not take — it has commits the project
// does not — is noted and left alone until it moves; nothing on the server is ever overwritten. One push run per project at
// a time, and a run with nothing to push says nothing. The answer (kept, or not for this project) is in the project
// records (projects.mjs), by project id: the project's folder itself is the repository kept — its record names the
// repository, the remote, the commit each branch had when last pushed, and the branches the server refused.
import { HostError, LOCALGIT } from './githosts.mjs';
import { short } from './validate.mjs';

const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const RESERVED = /\.(git|wiki|rss|atom)$/i;
const HEX = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
export const SWEEP_MS = 10 * 60000;
const PER_RUN = 20;
const err = (status, m) => new HostError(status, m);

/** repoSlug(name) -> a repository name Forgejo takes (letters, digits, . _ -; at most 100; starting with a letter or digit; not
 *  ending in .git, .wiki, .rss or .atom) made of a project's name: other characters become one dash. */
export function repoSlug(name) {
  const trim = (t) => t.replace(/^[^A-Za-z0-9]+/, '').replace(/[-.]+$/, '');
  let s = trim(String(name ?? '').normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9_.-]+/g, '-').replace(/-{2,}/g, '-')).slice(0, 100);
  s = trim(s);
  while (RESERVED.test(s)) s = trim(s.replace(RESERVED, ''));
  return s || 'project';
}
/** nameOk(v) -> whether v is a repository name Forgejo takes (as repoSlug makes them). */
export const nameOk = (v) => typeof v === 'string' && NAME.test(v) && !RESERVED.test(v);
/** urlOf(owner, name) -> the repository's address as the sandbox reaches it (the gateway's git listener: githosts.mjs LOCALGIT) */
export const urlOf = (owner, name) => `https://${LOCALGIT.host}:${LOCALGIT.port}/${owner}/${name}.git`;
/** pointsHome(rm, owner, name) -> whether a remote of the project's repository (as git.remote.state lists it) is the one made here, and
 *  nothing else: exactly one URL, the repository's address, and no push URL or the same one. An automatic push confirms nothing with
 *  anybody, so it goes only where this says so. */
export function pointsHome(rm, owner, name) {
  const url = urlOf(owner, name);
  const push = Array.isArray(rm?.pushUrls) ? rm.pushUrls : [];
  return !!rm && Array.isArray(rm.urls) && rm.urls.length === 1 && rm.urls[0] === url && (push.length === 0 || (push.length === 1 && push[0] === url));
}
/** astrayText(remote) -> what the panel says when a remote does not point at the local git server any more */
export const astrayText = (remote) => `the remote ${remote} no longer points at your local git server, so automatic pushes stopped: check it, then turn them on again`;
/** rejectedText(branch) -> what the panel says of a branch the server would not take */
export const rejectedText = (branch) => `${branch}: the local git server has commits this project doesn't — pull first`;

// makeKeep({store, remote, mirrors}) -> the API of keeping (main.mjs routes): store() — the project records (projects.mjs);
// remote() — gitremote.mjs's API (state, remoteSet, remoteRemove, plan, run); mirrors — mirrors.mjs (owner, nameFree)
export function makeKeep({ store, remote, mirrors, now = () => Date.now(), log = () => {} }) {
  const running = new Map();   // project id -> the run in progress
  const again = new Set();     // project ids asked to push again while a run was in progress
  let timer = null;
  const rootOf = (id) => {
    const r = store().rootOf(id);
    if (!r) throw err(404, 'no such project (it was removed?)');
    return r;
  };
  const failText = (e) => (e?.said ? `${short(e.message, 200)}: ${short(e.said, 300)}` : short(e?.message || String(e), 300));

  // view(id) -> what the Git panel shows: whether keeping is possible and what the answer was; for a kept project, where it is,
  // when it was last pushed, which branches have not been, and which the server refused (git read just now; null: not said)
  async function view(id) {
    const p = store().get(id);
    if (!p) throw err(404, 'no such project (it was removed?)');
    const owner = mirrors.owner();
    const rec = store().localgit(id);
    const out = { available: owner !== null, owner, suggested: repoSlug(p.name), state: rec?.state ?? null };
    if (rec?.state !== 'kept') return out;
    Object.assign(out, { repo: rec.repo, made: !!rec.pushedAt || Object.keys(rec.heads).length > 0, remote: rec.remote, auto: rec.auto, pushedAt: rec.pushedAt, lastError: rec.lastError, busy: running.has(id), unpushed: null,
      rejected: Object.keys(rec.rejected).map(rejectedText) });
    try {
      const st = await remote().state(rootOf(id).rel);
      if (st.repo) {
        const moved = st.branches.filter((b) => b.head && rec.heads[b.name] !== b.head);
        out.unpushed = moved.map((b) => b.name);
        out.rejected = moved.filter((b) => rec.rejected[b.name] === b.head).map((b) => rejectedText(b.name));
      }
    } catch { /* not said: the record's word stands */ }
    return out;
  }

  // keep(id, {name, auto}) -> the view: the name checked (on the server already, or held by another kept project: 409, nothing
  // changed), its remote added (origin when the project has none, else local), and what it has pushed. The first push that has
  // commits makes the repository (push to create); a project without commits is kept and its repository appears with its first.
  async function keep(id, b = {}) {
    const owner = mirrors.owner();
    if (owner === null) throw err(409, 'the built-in git server is not connected as a Git host yet: ./stack up connects it');
    const had = store().localgit(id);
    if (had?.state === 'kept') throw err(409, `${had.repo} keeps this project already`);
    const root = rootOf(id);
    if (root.mode === 'ro') throw err(400, 'a read-only folder cannot be kept: git has to add a remote to it');
    const p = store().get(id);
    const name = b.name === undefined || b.name === null || b.name === '' ? repoSlug(p.name) : b.name;
    if (!nameOk(name)) throw err(400, 'a repository name of letters, digits, . _ and - (at most 100, starting with a letter or digit, not ending in .git or .wiki)');
    const st = await remote().state(root.rel);
    if (!st.repo) throw err(409, 'it is not a git repository yet: start one first (Connect a git repository)');
    const remoteName = st.remotes.length ? 'local' : 'origin';
    if (st.remotes.some((r) => r.name === remoteName)) throw err(409, `this repository has a remote named ${remoteName} already: rename it in the terminal first`);
    const made = await mirrors.nameFree(name);
    for (const other of store().keptIds()) if (other !== id && store().localgit(other)?.repo === made.repo) throw err(409, `${made.repo} is on the git server already, so pick another name`);
    await remote().remoteSet({ repo: root.rel, name: remoteName, url: urlOf(made.owner, made.name) });
    store().setLocalgit(id, () => ({ state: 'kept', repo: made.repo, remote: remoteName, auto: b.auto !== false, pushedAt: null, lastError: null, heads: {}, rejected: {} }));
    log(`keep: ${p.name} is kept as ${made.repo} (remote ${remoteName})`);
    await sync(id, { manual: true });
    return view(id);
  }

  // sync(id, {manual}) -> {pushed: [branch…], error?}: the branches that moved since their last push, each pushed to the branch of
  // that name. While a run is in progress another asked for is one more look when it ends, not a second push at once.
  function sync(id, opts = {}) {
    if (running.has(id)) { again.add(id); return running.get(id); }
    const run = (async () => {
      try {
        const out = await syncOnce(id, opts);
        for (let n = 0; again.delete(id) && n < 3; n++) out.pushed.push(...(await syncOnce(id, {})).pushed);
        return out;
      } finally { running.delete(id); again.delete(id); }
    })();
    running.set(id, run);
    return run;
  }
  // (a failure to look is noted on the record only when you asked for the push: an automatic one stays quiet about it, in the log)
  function note(id, rec, text, manual) {
    if (manual && rec.lastError !== text) store().setLocalgit(id, (cur) => (cur?.state === 'kept' && cur.repo === rec.repo ? { ...cur, lastError: text } : cur));
    return { pushed: [], error: text };
  }
  // astray(id, rec) — the remote is not the repository made here any more: nothing is pushed, automatic pushes are turned off (the
  // project stays kept, and the panel says why), and the push you ask for by hand is the Git panel's own, which shows the URL
  function astray(id, rec) {
    const text = astrayText(rec.remote);
    store().setLocalgit(id, (cur) => (cur?.state === 'kept' && cur.repo === rec.repo ? { ...cur, auto: false, lastError: text } : cur));
    log(`keep ${id}: ${text}`);
    return { pushed: [], error: text };
  }
  async function syncOnce(id, { manual = false } = {}) {
    const rec = store().localgit(id);
    if (rec?.state !== 'kept') return { pushed: [] };
    let root, st;
    try {
      root = rootOf(id);
      st = await remote().state(root.rel);
    } catch (e) {
      log(`keep ${id}: ${short(e?.message, 200)}`);
      return note(id, rec, failText(e), manual);
    }
    if (!st.repo) return note(id, rec, 'this folder is not a git repository any more', manual);
    const rm = st.remotes.find((r) => r.name === rec.remote);
    if (!rm) return note(id, rec, `the remote ${rec.remote} is gone: stop keeping it here, then keep it again`, manual);
    // (nothing is confirmed with anybody here: the remote must still be exactly the repository made on the built-in server — one URL,
    // no other push URL, and no URL rewrite in the repository's configuration, which could send a push elsewhere)
    const owner = mirrors.owner() ?? rec.repo.split('/')[0];
    const name = rec.repo.split('/')[1];
    if (!pointsHome(rm, owner, name) || st.rewrites > 0) return astray(id, rec);
    // (a branch the server refused is left alone until it moves — or until you push now)
    const moved = st.branches.filter((b) => b.head && rec.heads[b.name] !== b.head && (manual || rec.rejected[b.name] !== b.head));
    if (!moved.length) {
      if (manual && rec.lastError) store().setLocalgit(id, (cur) => (cur?.state === 'kept' && cur.repo === rec.repo ? { ...cur, lastError: null } : cur));
      return { pushed: [] };
    }
    moved.sort((a, c) => (c.name === st.branch) - (a.name === st.branch));
    const heads = {}, rejected = {}, pushed = [];
    let error = null;
    for (const b of moved.slice(0, PER_RUN)) {
      // (the branch checked out, to origin: it tracks that one too; every other branch goes without tracking)
      const action = rec.remote === 'origin' && b.name === st.branch ? 'publish' : 'push';
      try {
        const pl = await remote().plan({ action, repo: root.rel, remote: rec.remote, branch: b.name });
        // (the remote may have changed since it was read: the plan names the URL the push goes to, and the host whose credential it gets)
        if (pl.url !== urlOf(owner, name) || pl.host?.builtin !== LOCALGIT.id) return astray(id, rec);
        const r = await remote().run({ planId: pl.planId });
        if (r?.ok !== true) throw new Error('the push did not go through');
        heads[b.name] = HEX.test(r.sha ?? '') ? r.sha : b.head;
        pushed.push(b.name);
      } catch (e) {
        if (/has commits this branch does not have/.test(`${e?.said ?? ''} ${e?.message ?? ''}`)) { rejected[b.name] = b.head; continue; }
        error = failText(e);
        log(`keep ${id}: ${error}`);
        break;
      }
    }
    const here = new Map(st.branches.map((b) => [b.name, b.head]));
    store().setLocalgit(id, (cur) => {
      if (cur?.state !== 'kept' || cur.repo !== rec.repo) return cur;
      const all = { ...cur.heads, ...heads };
      const keepHeads = Object.fromEntries(Object.entries(all).filter(([k]) => here.has(k)));
      // (a refusal stands while the branch is still at the commit it was refused at)
      const refused = Object.fromEntries(Object.entries({ ...cur.rejected, ...rejected }).filter(([k, c]) => here.get(k) === c && !pushed.includes(k)));
      return { ...cur, heads: keepHeads, rejected: refused, pushedAt: pushed.length ? now() : cur.pushedAt, lastError: error };
    });
    return error ? { pushed, error } : { pushed };
  }

  const asKept = (id, fn) => {
    const rec = store().localgit(id);
    if (rec?.state !== 'kept') throw err(409, 'this project is not kept on the local git server');
    return fn(rec);
  };
  // pushNow(id) -> the view after a push of everything that moved (the branches the server refused tried again too)
  async function pushNow(id) {
    asKept(id, () => null);
    await sync(id, { manual: true });
    return view(id);
  }
  // setAuto(id, on) -> the view: automatic pushes on or off (on: one push at once)
  async function setAuto(id, on) {
    if (typeof on !== 'boolean') throw err(400, 'on: true or false');
    asKept(id, () => store().setLocalgit(id, (cur) => (cur?.state === 'kept' ? { ...cur, auto: on } : cur)));
    if (on) trigger(id);
    return view(id);
  }
  // decline(id) -> the view: not for this project, and not asked again (it can still be kept from the Git panel's menu)
  async function decline(id) {
    store().setLocalgit(id, (cur) => {
      if (cur?.state === 'kept') throw err(409, `${cur.repo} keeps this project: stop keeping it first`);
      return { state: 'declined' };
    });
    return view(id);
  }
  // stop(id) -> {ok, repo, removed}: the remote goes from the project's repository (when it is still the one made here) and the
  // project is not kept any more — and not asked about again. The repository stays on the server, with everything pushed.
  async function stop(id) {
    const rec = store().localgit(id);
    if (rec?.state !== 'kept') throw err(409, 'this project is not kept on the local git server');
    await running.get(id)?.catch(() => {});
    const root = rootOf(id);
    const st = await remote().state(root.rel);
    const rm = st.repo ? st.remotes.find((r) => r.name === rec.remote) : null;
    let removed = false;
    const owner = mirrors.owner() ?? rec.repo.split('/')[0];
    if (pointsHome(rm, owner, rec.repo.split('/')[1])) {
      await remote().remoteRemove({ repo: root.rel, name: rec.remote, url: rm.urls[0] });
      removed = true;
    }
    store().setLocalgit(id, () => ({ state: 'declined' }));
    log(`keep: ${rec.repo} no longer keeps ${id}`);
    return { ok: true, repo: rec.repo, removed };
  }

  // --- the automatic pushes ---
  function trigger(id) {
    let rec = null;
    try { rec = store().localgit(id); } catch { return; }
    if (rec?.state === 'kept' && rec.auto) sync(id).catch((e) => log(`keep ${id}: ${short(e?.message, 200)}`));
  }
  /** committed(repo) — a commit was made from the Git panel in this repository folder of the workspace */
  function committed(repo) {
    try { for (const id of store().keptIds()) if (store().rootOf(id)?.rel === (repo ?? '')) trigger(id); } catch (e) { log(`keep: ${short(e?.message, 200)}`); }
  }
  /** turnEnded(cwd) — a session's turn ended in this working folder */
  function turnEnded(cwd) {
    try { if (typeof cwd === 'string') { const p = store().folderOf(cwd); if (p?.id) trigger(p.id); } } catch (e) { log(`keep: ${short(e?.message, 200)}`); }
  }
  /** keptRepo(cwd) -> 'owner/name' when the project a working folder is in is kept (automatic pushes on), else null — for Claude's git note */
  function keptRepo(cwd) {
    try {
      const rec = store().localgit(store().folderOf(cwd)?.id);
      return rec?.state === 'kept' && rec.auto ? rec.repo : null;
    } catch { return null; }
  }
  // sweep() — every kept project with automatic pushes on, one after another: what moved since its last push goes
  async function sweep() {
    let ids = [];
    try { ids = store().keptIds(); } catch { return; }
    for (const id of ids) {
      try { const rec = store().localgit(id); if (rec?.state === 'kept' && rec.auto) await sync(id); } catch (e) { log(`keep ${id}: ${short(e?.message, 200)}`); }
    }
  }
  function start(ms = SWEEP_MS) {
    clearInterval(timer);
    timer = setInterval(() => { void sweep(); }, ms);
    timer.unref?.();
  }
  const close = () => { clearInterval(timer); timer = null; };

  return { view, keep, pushNow, setAuto, decline, stop, sync, committed, turnEnded, keptRepo, sweep, start, close };
}
