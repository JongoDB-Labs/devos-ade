// Keeping a project on the built-in git server (keep.mjs, JON-1005): the repository made through Forgejo's API (a stand-in
// answers), its name, a name that is taken, the remote's name (origin, or local beside another), a push only when there are
// commits, the automatic pushes (after a commit, after a turn, in the sweep) and that they never run twice at once or say
// anything when nothing moved, a branch the server refused (noted, left alone, never forced), a No that is remembered, and
// Stop keeping it here. The sandbox is a stand-in that holds a repository's remotes and branches.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { GitHosts, LOCALGIT } from '../server/githosts.mjs';
import { makeMirrors } from '../server/mirrors.mjs';
import { makeGitRemote } from '../server/gitremote.mjs';
import { Projects, localgitRecord } from '../server/projects.mjs';
import { makeKeep, repoSlug, nameOk, urlOf, rejectedText, pointsHome } from '../server/keep.mjs';
import { gitNote } from '../server/gitnote.mjs';
import { SandboxError } from '../server/spawn-client.mjs';
import { tmp } from './helpers.mjs';

const ROOT = tmp('bnkeep');
after(() => fs.rmSync(ROOT, { recursive: true, force: true }));
const CA = fs.readFileSync(path.resolve(import.meta.dirname, '../../tests/fixtures/localgit-ca.pem'), 'utf8');
const LTOK = ['lg', 'tok_', 'K'.repeat(20)].join('');
const sha = (c) => c.repeat(40);
const tick = (ms = 15) => new Promise((r) => setTimeout(r, ms));
const sleepUntil = async (f, ms = 2000) => { for (let t = 0; t < ms && !f(); t += 10) await tick(10); };

// a stand-in sandbox: one repository per folder (remotes, branches, the branch checked out), the ops keep.mjs and the Git panel's
// remote operations use; the server's branches too, for a push that is refused when it has commits the branch does not
function sandbox() {
  const repos = new Map();
  const log = [];
  const server = new Map();   // "remote url" -> Map(branch -> commit)
  let busy = 0, maxBusy = 0, delay = 0, refuse = new Set(), afterLook = null;
  const repo = (r) => {
    if (!repos.has(r)) throw new SandboxError('not a git repository', 'refused');
    return repos.get(r);
  };
  const call = async (req) => {
    log.push(req);
    if (req.op === 'git.remote.state') {
      if (!repos.has(req.repo)) return { result: { repo: false, reason: 'not a git repository' } };
      const g = repos.get(req.repo);
      const head = g.branches[g.branch] ?? null;
      const answer = { result: { repo: true, root: '', branch: g.branch, head, state: null, rewrites: g.rewrites ?? 0,
        remotes: Object.entries(g.remotes).map(([name, url]) => ({ name, urls: [...(g.moreUrls?.[name] ?? []), url].sort((a, b) => (a === url) - (b === url)), pushUrls: g.pushUrls?.[name] ?? [] })),
        branches: Object.entries(g.branches).map(([name, h]) => ({ name, head: h, upstream: null })), remoteBranches: [], remoteHeads: {} } };
      // (a test's change of the repository's configuration right after it was read: the remote is not what the look saw when the plan is made)
      if (afterLook) { const f = afterLook; afterLook = null; f(g); }
      return answer;
    }
    if (req.op === 'git.remote.set') { repo(req.repo).remotes[req.name] = req.url; return { result: { ok: true, added: true } }; }
    if (req.op === 'git.remote.remove') {
      const g = repo(req.repo);
      if (g.remotes[req.name] !== req.url) throw new SandboxError('the remote\'s URL changed since it was shown: look again', 'refused');
      delete g.remotes[req.name];
      return { result: { ok: true } };
    }
    if (req.op === 'git.net') {
      const g = repo(req.repo);
      busy++; maxBusy = Math.max(maxBusy, busy);
      try {
        if (delay) await tick(delay);
        if (refuse.has(req.branch)) throw new SandboxError(`the remote's ${req.dst} has commits this branch does not have: pull first`, 'refused');
        return { result: { ok: true, action: req.action, sha: g.branches[req.branch], upToDate: false, created: true, upstream: true } };
      } finally { busy--; }
    }
    throw new Error(`unexpected ${req.op}`);
  };
  return { call, log, repos, server, get maxBusy() { return maxBusy; }, set delay(v) { delay = v; }, refuse, after: (f) => { afterLook = f; },
    nets: () => log.filter((r) => r.op === 'git.net'),
    make: (r, over = {}) => repos.set(r, { branch: 'main', branches: { main: sha('a') }, remotes: {}, ...over }) };
}

let n = 0;
// a whole setup: records, Git hosts (the built-in one connected), a stand-in Forgejo, the Git panel's remote operations, keep
function setup({ connected = true, existsName = null } = {}) {
  const dir = path.join(ROOT, `s${++n}`);
  const hosts = new GitHosts({ dir });
  if (connected) hosts.addLocalGit({ ca: CA, token: LTOK, account: 'devos' });
  const projects = new Projects({ dir, hostsFile: path.join(dir, 'none.json') });
  const sb = sandbox();
  const api = [];
  const fetchImpl = async (url, opts = {}) => {
    const u = new URL(url);
    api.push({ method: opts.method || 'GET', path: u.pathname, headers: opts.headers, body: opts.body ? JSON.parse(opts.body) : null });
    if (opts.method === 'POST' && u.pathname === '/api/v1/user/repos') {
      const taken = existsName !== null && JSON.parse(opts.body).name === existsName;
      return { ok: !taken, status: taken ? 409 : 201, text: async () => JSON.stringify(taken ? { message: 'The repository with the same name already exists.' } : { name: 'x' }) };
    }
    return { ok: false, status: 404, text: async () => '{"message":"not found"}' };
  };
  const mirrors = makeMirrors({ store: hosts, fetchImpl, base: 'http://caddy:8099' });
  const remote = makeGitRemote({ call: sb.call, store: hosts });
  const logs = [];
  const keep = makeKeep({ store: () => projects, remote: () => remote, mirrors, log: (m) => logs.push(m) });
  return { dir, hosts, projects, sb, api, keep, logs, mirrors };
}
const project = (s, name = 'My App', root = 'app', git = {}) => { s.sb.make(root, git); return s.projects.add({ name, root }).id; };

// (the same table is in code/web/test/keep.test.ts: the page and the backend make the same name of a project's)
const SLUGS = [['My App', 'My-App'], ['  café  au lait!! ', 'cafe-au-lait'], ['a/b\\c', 'a-b-c'], ['..hidden.', 'hidden'], ['thing.git', 'thing'], ['x.wiki.git', 'x'],
  ['日本語', 'project'], ['snake_case-and.dots', 'snake_case-and.dots'], ['_lead', 'lead'], ['', 'project'], ['-', 'project'], ['...', 'project'], ['ok-1.2', 'ok-1.2'], ['a.git.wiki', 'a']];
test('the repository name: the project\'s name in the characters Forgejo takes', () => {
  for (const [n, want] of SLUGS) assert.equal(repoSlug(n), want, JSON.stringify(n));
  assert.equal(repoSlug('My App'), 'My-App');
  assert.equal(repoSlug('  café  au lait!! '), 'cafe-au-lait');
  assert.equal(repoSlug('a/b\\c'), 'a-b-c');
  assert.equal(repoSlug('..hidden.'), 'hidden');
  assert.equal(repoSlug('thing.git'), 'thing');
  assert.equal(repoSlug('x.wiki.git'), 'x');
  assert.equal(repoSlug('日本語'), 'project');
  assert.equal(repoSlug('Workspace'), 'Workspace');
  assert.equal(repoSlug('snake_case-and.dots'), 'snake_case-and.dots');
  assert.equal(repoSlug('a'.repeat(300)).length, 100);
  assert.equal(repoSlug('a'.repeat(99) + '-b'), 'a'.repeat(99));   // (cut at 100, and no dash left at the end)
  for (const v of ['My App', 'x', '_lead', 'a'.repeat(300), 'thing.git', '', null]) assert.ok(nameOk(repoSlug(v)), String(v));
  assert.ok(nameOk('a.b_c-d') && !nameOk('-a') && !nameOk('a b') && !nameOk('x.git') && !nameOk('x.WIKI') && !nameOk('') && !nameOk(7));
});

test('Keep it there: a private repository by the API, origin as the remote of a project that has none, and its branch pushed with upstream', async () => {
  const s = setup();
  const id = project(s);
  const v = await s.keep.keep(id, {});
  const post = s.api.find((c) => c.method === 'POST');
  assert.deepEqual([post.path, post.body], ['/api/v1/user/repos', { name: 'My-App', private: true, auto_init: false }]);
  assert.equal(post.headers.Authorization, `token ${LTOK}`);
  assert.equal(s.sb.repos.get('app').remotes.origin, 'https://gateway:8093/devos/My-App.git');
  assert.equal(urlOf('devos', 'My-App'), 'https://gateway:8093/devos/My-App.git');
  assert.equal(`${LOCALGIT.host}:${LOCALGIT.port}`, 'gateway:8093');
  const nets = s.sb.nets();
  assert.deepEqual(nets.map((r) => [r.action, r.repo, r.remote, r.branch, r.dst]), [['publish', 'app', 'origin', 'main', 'main']]);
  assert.equal(nets[0].url, 'https://gateway:8093/devos/My-App.git');
  assert.deepEqual([v.state, v.repo, v.remote, v.auto, v.unpushed, v.lastError], ['kept', 'devos/My-App', 'origin', true, [], null]);
  assert.ok(Number.isInteger(v.pushedAt));
  assert.deepEqual(s.projects.localgit(id).heads, { main: sha('a') });
  assert.ok(!JSON.stringify([v, s.logs]).includes(LTOK));
});

test('a name of your own is checked; one that is taken is a plain 409 and nothing is made, no remote, no record', async () => {
  const s = setup({ existsName: 'taken' });
  const id = project(s);
  await assert.rejects(s.keep.keep(id, { name: 'bad name' }), /repository name of letters/);
  await assert.rejects(s.keep.keep(id, { name: 'x.git' }), /repository name of letters/);
  await assert.rejects(s.keep.keep(id, { name: 'taken' }), (e) => e.status === 409 && e.message === 'devos/taken is taken — pick another name');
  assert.deepEqual(s.sb.repos.get('app').remotes, {});
  assert.equal(s.projects.localgit(id), null);
  assert.deepEqual(s.sb.nets(), []);
  const v = await s.keep.keep(id, { name: 'other-name' });
  assert.equal(v.repo, 'devos/other-name');
});

test('a project that has a remote gets local beside it, pushed without upstream; an existing local is not touched', async () => {
  const s = setup();
  const id = project(s, 'Cloned', 'cloned', { remotes: { origin: 'https://github.com/o/r.git' } });
  const v = await s.keep.keep(id, {});
  assert.deepEqual(Object.keys(s.sb.repos.get('cloned').remotes), ['origin', 'local']);
  assert.equal(s.sb.repos.get('cloned').remotes.origin, 'https://github.com/o/r.git');
  assert.deepEqual(s.sb.nets().map((r) => [r.action, r.remote]), [['push', 'local']]);
  assert.equal(v.remote, 'local');
  const id2 = project(s, 'Two', 'two', { remotes: { origin: 'https://github.com/o/r.git', local: 'https://example.org/x.git' } });
  await assert.rejects(s.keep.keep(id2, {}), (e) => e.status === 409 && /remote named local already/.test(e.message));
  assert.equal(s.sb.repos.get('two').remotes.local, 'https://example.org/x.git');
  assert.equal(s.api.filter((c) => c.method === 'POST').length, 1, 'no repository made for the refused one');
});

test('not a repository, not connected, a read-only folder: refused before anything is made', async () => {
  const s = setup();
  const id = s.projects.add({ name: 'Plain', root: 'plain' }).id;
  await assert.rejects(s.keep.keep(id, {}), (e) => e.status === 409 && /not a git repository yet/.test(e.message));
  assert.equal(s.api.length, 0);
  const off = setup({ connected: false });
  const id2 = project(off);
  await assert.rejects(off.keep.keep(id2, {}), (e) => e.status === 409 && /not connected as a Git host/.test(e.message));
  assert.deepEqual(await off.keep.view(id2), { available: false, owner: null, suggested: 'My-App', state: null });
});

test('a push only when there are commits: an empty repository is kept, and the first commit is pushed', async () => {
  const s = setup();
  const id = project(s, 'Fresh', 'fresh', { branches: {}, branch: 'main' });
  const v = await s.keep.keep(id, {});
  assert.deepEqual(s.sb.nets(), []);
  assert.deepEqual([v.state, v.pushedAt, v.unpushed], ['kept', null, []]);
  s.sb.repos.get('fresh').branches.main = sha('b');
  s.keep.committed('fresh');
  await sleepUntil(() => s.sb.nets().length === 1);
  assert.deepEqual(s.sb.nets().map((r) => [r.action, r.branch]), [['publish', 'main']]);
});

test('after a commit in the Git panel: the branches that moved are pushed to branches of the same name; nothing moved, nothing said', async () => {
  const s = setup();
  const id = project(s, 'App', 'app', { branches: { main: sha('a'), side: sha('1') } });
  await s.keep.keep(id, {});
  assert.deepEqual(s.sb.nets().map((r) => [r.action, r.branch]).sort(), [['publish', 'main'], ['push', 'side']]);
  const before = s.sb.log.length;
  s.keep.committed('app');
  await tick(60);
  assert.deepEqual(s.sb.log.slice(before).map((r) => r.op), ['git.remote.state'], 'only a look: no plan, no push, no write');
  const g = s.sb.repos.get('app');
  g.branches.main = sha('b');
  const stamp = s.projects.localgit(id).pushedAt;
  await tick(5);
  s.keep.committed('app');
  await sleepUntil(() => s.sb.nets().length === 3);
  assert.deepEqual(s.sb.nets().slice(2).map((r) => [r.action, r.branch]), [['publish', 'main']]);
  assert.deepEqual(s.projects.localgit(id).heads, { main: sha('b'), side: sha('1') });
  assert.ok(s.projects.localgit(id).pushedAt >= stamp);
  // another repository's commit, or a project that is not kept: nothing
  const n0 = s.sb.log.length;
  s.keep.committed('elsewhere');
  s.keep.committed('');
  await tick(40);
  assert.equal(s.sb.log.length, n0);
});

test('pushes never run twice at once for a project: many triggers while one runs are one more look, not a second push', async () => {
  const s = setup();
  const id = project(s);
  await s.keep.keep(id, {});
  s.sb.delay = 40;
  const g = s.sb.repos.get('app');
  g.branches.main = sha('b');
  for (let i = 0; i < 6; i++) s.keep.committed('app');
  g.branches.main = sha('c');   // (a commit while the push runs: the one more look pushes it)
  for (let i = 0; i < 4; i++) { s.keep.turnEnded('/workspace/app'); await tick(5); }
  await sleepUntil(() => s.projects.localgit(id).heads.main === sha('c'));
  await tick(150);
  assert.equal(s.sb.maxBusy, 1);
  assert.ok(s.sb.nets().length <= 3, `${s.sb.nets().length} pushes`);
  assert.equal(s.projects.localgit(id).heads.main, sha('c'));
});

test('after a session\'s turn ends in the project (or a folder of it); a project with automatic pushes off, or another one, is left alone', async () => {
  const s = setup();
  const id = project(s);
  const other = project(s, 'Other', 'other');
  await s.keep.keep(id, {});
  s.sb.repos.get('app').branches.main = sha('b');
  s.sb.repos.get('other').branches.main = sha('b');
  s.keep.turnEnded('/workspace/other');   // (not kept)
  s.keep.turnEnded('/etc');
  s.keep.turnEnded(null);
  await tick(40);
  assert.equal(s.sb.nets().length, 1);
  s.keep.turnEnded('/workspace/app/src');
  await sleepUntil(() => s.sb.nets().length === 2);
  assert.deepEqual(s.sb.nets()[1].branch, 'main');
  assert.equal(s.projects.localgit(other), null);
  // off: no automatic push, a push now still goes
  const v = await s.keep.setAuto(id, false);
  assert.equal(v.auto, false);
  s.sb.repos.get('app').branches.main = sha('c');
  s.keep.turnEnded('/workspace/app');
  s.keep.committed('app');
  await tick(50);
  assert.equal(s.sb.nets().length, 2);
  await s.keep.sweep();
  assert.equal(s.sb.nets().length, 2, 'the sweep leaves it too');
  const p = await s.keep.pushNow(id);
  assert.equal(s.sb.nets().length, 3);
  assert.deepEqual(p.unpushed, []);
  await assert.rejects(s.keep.setAuto(id, 'yes'), /true or false/);
  const on = await s.keep.setAuto(id, true);
  assert.equal(on.auto, true);
});

test('the sweep: every kept project whose branches moved since its last push, one after another', async () => {
  const s = setup();
  const a = project(s, 'A', 'a');
  const b = project(s, 'B', 'b');
  const c = project(s, 'C', 'c');
  await s.keep.keep(a, {});
  await s.keep.keep(b, {});
  const n0 = s.sb.nets().length;
  s.sb.repos.get('a').branches.main = sha('b');
  s.sb.repos.get('c').branches.main = sha('b');   // (not kept)
  await s.keep.sweep();
  assert.deepEqual(s.sb.nets().slice(n0).map((r) => r.repo), ['a']);
  const n1 = s.sb.nets().length;
  await s.keep.sweep();
  assert.equal(s.sb.nets().length, n1, 'nothing moved: nothing sent');
  assert.equal(s.projects.localgit(c), null);
  // the sweep runs by itself on a timer, and stops
  s.keep.start(20);
  s.sb.repos.get('b').branches.main = sha('d');
  await sleepUntil(() => s.sb.nets().length === n1 + 1);
  s.keep.close();
  assert.equal(s.sb.nets()[n1].repo, 'b');
});

test('a branch the server refused (it has commits this project does not): noted and shown, left alone, tried again once it moves or on Push now, never forced', async () => {
  const s = setup();
  const id = project(s, 'App', 'app', { branches: { main: sha('a'), side: sha('1') } });
  await s.keep.keep(id, {});
  const g = s.sb.repos.get('app');
  g.branches.main = sha('b');
  g.branches.side = sha('2');
  s.sb.refuse.add('main');
  s.keep.committed('app');
  await sleepUntil(() => Object.keys(s.projects.localgit(id).rejected).length === 1);
  const rec = s.projects.localgit(id);
  assert.deepEqual(rec.rejected, { main: sha('b') });
  assert.equal(rec.heads.side, sha('2'), 'the other branch went');
  assert.equal(rec.heads.main, sha('a'), 'the refused one is still what it was');
  assert.equal(rec.lastError, null, 'a refusal is not a failure of the pushes');
  let v = await s.keep.view(id);
  assert.deepEqual(v.rejected, ['main: the local git server has commits this project doesn\'t — pull first']);
  assert.equal(rejectedText('main'), v.rejected[0]);
  assert.deepEqual(v.unpushed, ['main']);
  // (automatic: not again while the branch is where it was)
  const n = s.sb.nets().length;
  await s.keep.sweep();
  s.keep.turnEnded('/workspace/app');
  await tick(50);
  assert.equal(s.sb.nets().length, n);
  // Push now tries it again
  await s.keep.pushNow(id);
  assert.equal(s.sb.nets().length, n + 1);
  assert.equal(s.sb.nets()[n].branch, 'main');
  // pulled (the branch moved): it goes through
  s.sb.refuse.clear();
  g.branches.main = sha('e');
  await s.keep.sweep();
  v = await s.keep.view(id);
  assert.deepEqual([v.rejected, v.unpushed], [[], []]);
  // never forced: the plans and the pushes have no force in them, and a refused push is never retried with one
  for (const r of s.sb.nets()) {
    assert.ok(['push', 'publish'].includes(r.action));
    assert.ok(!Object.keys(r).some((k) => /force|lease/i.test(k)) && !/^\+/.test(String(r.branch)), JSON.stringify(r));
  }
});

test('a push that cannot go is shown as the last error (when you asked for it), and cleared by the next push that works', async () => {
  const s = setup();
  const id = project(s);
  await s.keep.keep(id, {});
  const g = s.sb.repos.get('app');
  const remotes = g.remotes;
  g.remotes = {};   // the remote has gone from the repository
  g.branches.main = sha('b');
  await s.keep.sweep();
  assert.equal(s.projects.localgit(id).lastError, null, 'an automatic look that cannot push says nothing on the record');
  const v = await s.keep.pushNow(id);
  assert.match(v.lastError, /the remote origin is gone/);
  g.remotes = remotes;
  const ok = await s.keep.pushNow(id);
  assert.deepEqual([ok.lastError, ok.unpushed], [null, []]);
});

test('No for this project is remembered (also by a new start), is not asked again, and Keep it there still works from the menu', async () => {
  const s = setup();
  const id = project(s);
  assert.equal((await s.keep.view(id)).state, null);
  const v = await s.keep.decline(id);
  assert.deepEqual([v.state, v.available, v.suggested], ['declined', true, 'My-App']);
  const again = new Projects({ dir: s.dir, hostsFile: path.join(ROOT, 'none.json') });
  assert.deepEqual(again.localgit(id), { state: 'declined' });
  assert.equal(s.api.length, 0, 'nothing was made');
  const kept = await s.keep.keep(id, {});
  assert.equal(kept.state, 'kept');
  await assert.rejects(s.keep.decline(id), (e) => e.status === 409 && /stop keeping it first/.test(e.message));
  await assert.rejects(s.keep.decline('p_00000000'), (e) => e.status === 404);
  // the Workspace can be answered for too
  const ws = await s.keep.decline('ws');
  assert.equal(ws.state, 'declined');
});

test('Stop keeping it here: the remote goes, the record becomes a No, the repository stays on the server (no delete is sent); a remote pointed elsewhere is left', async () => {
  const s = setup();
  const id = project(s);
  await s.keep.keep(id, {});
  const r = await s.keep.stop(id);
  assert.deepEqual(r, { ok: true, repo: 'devos/My-App', removed: true });
  assert.deepEqual(s.sb.repos.get('app').remotes, {});
  assert.deepEqual(s.projects.localgit(id), { state: 'declined' });
  assert.ok(!s.api.some((c) => c.method === 'DELETE'));
  assert.equal((await s.keep.view(id)).state, 'declined');
  await assert.rejects(s.keep.stop(id), (e) => e.status === 409);
  // kept again, then the remote was pointed elsewhere by hand
  const v = await s.keep.keep(id, { name: 'again' });
  assert.equal(v.state, 'kept');
  s.sb.repos.get('app').remotes[v.remote] = 'https://example.org/else.git';
  const r2 = await s.keep.stop(id);
  assert.deepEqual([r2.removed, s.sb.repos.get('app').remotes[v.remote]], [false, 'https://example.org/else.git']);
  assert.deepEqual(s.projects.localgit(id), { state: 'declined' });
});

test('a push in progress when Stop comes does not bring the record back', async () => {
  const s = setup();
  const id = project(s);
  await s.keep.keep(id, {});
  s.sb.delay = 60;
  s.sb.repos.get('app').branches.main = sha('b');
  s.keep.committed('app');
  await sleepUntil(() => s.sb.log.some((r) => r.op === 'git.net') && s.sb.nets().length >= 2);
  await s.keep.stop(id);
  await tick(150);
  assert.deepEqual(s.projects.localgit(id), { state: 'declined' });
});

test('the records: checked when read, gone with the project, and the Workspace\'s own', () => {
  const s = setup();
  const id = project(s);
  assert.deepEqual(localgitRecord({ state: 'declined', junk: 1 }), { state: 'declined' });
  assert.equal(localgitRecord({ state: 'kept', repo: '../x', remote: 'origin' }), null);
  assert.equal(localgitRecord({ state: 'kept', repo: 'devos/x', remote: '-bad' }), null);
  assert.equal(localgitRecord({ state: 'maybe' }), null);
  const rec = localgitRecord({ state: 'kept', repo: 'devos/x', remote: 'origin', pushedAt: 5, lastError: 'a\nb', heads: { main: 'z', ok: sha('a'), '../x': sha('a') }, rejected: 'x' });
  assert.deepEqual(rec, { state: 'kept', repo: 'devos/x', remote: 'origin', auto: true, pushedAt: 5, lastError: null, heads: { ok: sha('a') }, rejected: {} });
  assert.throws(() => s.projects.setLocalgit(id, () => ({ state: 'kept', repo: 'nope', remote: 'origin' })), /not a record/);
  assert.throws(() => s.projects.setLocalgit('p_00000000', () => ({ state: 'declined' })), /no such project/);
  assert.throws(() => s.projects.setLocalgit('bad', () => ({ state: 'declined' })), /bad project id/);
  s.projects.setLocalgit('ws', () => ({ state: 'declined' }));
  s.projects.setLocalgit(id, () => ({ state: 'declined' }));
  assert.deepEqual(s.projects.keptIds(), []);
  // a hand-edited file: a record that does not fit is dropped, the rest stays
  const f = s.projects.jsonFile;
  const j = JSON.parse(fs.readFileSync(f, 'utf8'));
  j.localgit.p_00000001 = { state: 'kept', repo: 'bad' };
  j.localgit.nonsense = { state: 'declined' };
  fs.writeFileSync(f, JSON.stringify(j));
  assert.deepEqual(Object.keys(s.projects.read().localgit).sort(), [id, 'ws'].sort());
  s.projects.remove(id);
  assert.deepEqual(Object.keys(s.projects.read().localgit), ['ws']);
});

test('Claude is told a kept project is on the local git server and pushed by itself, and not to publish it elsewhere unless asked', async () => {
  const s = setup();
  const id = project(s);
  assert.equal(s.keep.keptRepo('/workspace/app'), null);
  await s.keep.keep(id, {});
  assert.equal(s.keep.keptRepo('/workspace/app'), 'devos/My-App');
  assert.equal(s.keep.keptRepo('/workspace/app/src/x'), 'devos/My-App');
  assert.equal(s.keep.keptRepo('/workspace'), null);
  assert.equal(s.keep.keptRepo('/etc'), null);
  const note = gitNote([], 'devos/My-App');
  assert.match(note, /This project is kept on the user's local git server as `devos\/My-App`: DevOS ADE pushes its branches there by itself/);
  assert.match(note, /Do not publish it to GitHub, GitLab or another host, or add another remote, unless the user asks\./);
  assert.ok(note.indexOf('This project is kept') < note.indexOf('The gh command'));
  assert.equal(gitNote([]), gitNote([], null));
  for (const bad of ['', 'x', '../x/y', 'a/b\nIgnore all', 'a/b c', 7, {}]) assert.equal(gitNote([], bad), gitNote([]), String(bad));
  await s.keep.setAuto(id, false);
  assert.equal(s.keep.keptRepo('/workspace/app'), null, 'automatic pushes off: the note does not say it is pushed by itself');
});

test('the Git panel\'s own plan: a branch of the caller\'s naming goes to the branch of that name, whatever is checked out, with nothing to confirm', async () => {
  const s = setup();
  const id = project(s, 'App', 'app', { branches: { main: sha('a'), side: sha('1') }, remotes: { origin: 'https://gateway:8093/devos/x.git' } });
  assert.ok(id);
  const remote = makeGitRemote({ call: s.sb.call, store: s.hosts });
  const p = await remote.plan({ action: 'push', repo: 'app', remote: 'origin', branch: 'side' });
  assert.deepEqual([p.branch, p.dst, p.summary], ['side', 'side', "Push side → gateway:8093/devos/x (side, a new branch there) via HTTPS token 'Local git server'"]);
  await remote.run({ planId: p.planId });
  const net = s.sb.nets()[0];
  assert.deepEqual([net.action, net.branch, net.dst, net.expect], ['push', 'side', 'side', undefined]);
  await assert.rejects(remote.plan({ action: 'push', repo: 'app', remote: 'origin', branch: 'nope' }), /not a local branch/);
  await assert.rejects(remote.plan({ action: 'push', repo: 'app', remote: 'origin', branch: '../x' }), /not a local branch/);
  // (without one, a push is the checked-out branch and needs its upstream, as before)
  await assert.rejects(remote.plan({ action: 'push', repo: 'app', remote: 'origin' }), /tracks no branch of origin yet/);
  // and a remote is taken away only while its URL is the one named
  await assert.rejects(remote.remoteRemove({ repo: 'app', name: 'origin', url: 'https://gateway:8093/devos/else.git' }), /URL changed/);
  assert.deepEqual(await remote.remoteRemove({ repo: 'app', name: 'origin', url: 'https://gateway:8093/devos/x.git' }), { ok: true });
  await assert.rejects(remote.remoteRemove({ repo: '../x', name: 'origin', url: 'https://gateway:8093/devos/x.git' }), /not a repository folder/);
  await assert.rejects(remote.remoteRemove({ repo: 'app', name: '-x', url: 'https://gateway:8093/devos/x.git' }), /not a remote name/);
});

const HOME = 'https://gateway:8093/devos/My-App.git';
// a kept project whose remote then changed: no push, automatic pushes off (it stays kept), the reason on the record
async function astray(change, { afterLook = false } = {}) {
  const s = setup();
  const id = project(s);
  await s.keep.keep(id, {});
  const before = s.sb.nets().length;
  const g = s.sb.repos.get('app');
  g.branches.main = sha('b');
  if (afterLook) s.sb.after(change); else change(g);
  const out = await s.keep.sync(id);
  assert.equal(s.sb.nets().length, before, 'nothing was pushed');
  const rec = s.projects.localgit(id);
  assert.deepEqual([rec.state, rec.auto], ['kept', false]);
  assert.equal(rec.lastError, 'the remote origin no longer points at your local git server, so automatic pushes stopped: check it, then turn them on again');
  assert.equal(out.error, rec.lastError);
  assert.ok(s.logs.some((l) => /no longer points at your local git server/.test(l)));
  // automatic pushes are off now: a commit starts nothing
  s.keep.committed('app');
  await tick(50);
  assert.equal(s.sb.nets().length, before);
  assert.equal((await s.keep.view(id)).auto, false);
}
test('a remote repointed to another host: nothing is pushed, automatic pushes stop, and the project says why', () => astray((g) => { g.remotes.origin = 'https://evil.example/x/My-App.git'; }));
test('a push URL added to the remote: nothing is pushed', () => astray((g) => { g.pushUrls = { origin: ['https://evil.example/x.git'] }; }));
test('a second URL on the remote: nothing is pushed', () => astray((g) => { g.moreUrls = { origin: ['https://evil.example/x.git'] }; }));
test('a URL rewrite (url.<x>.pushInsteadOf) in the repository\'s configuration: nothing is pushed', () => astray((g) => { g.rewrites = 1; }));
test('a remote that changes between the look and the plan (the plan names another URL): nothing is pushed', () => astray((g) => { g.remotes.origin = 'https://gateway:8093/devos/other.git'; }, { afterLook: true }));

test('a remote that is still the repository made here, with the same push URL, still pushes', async () => {
  const s = setup();
  const id = project(s);
  await s.keep.keep(id, {});
  const g = s.sb.repos.get('app');
  g.pushUrls = { origin: [HOME] };
  g.branches.main = sha('b');
  const out = await s.keep.sync(id);
  assert.deepEqual(out.pushed, ['main']);
  assert.deepEqual([s.projects.localgit(id).auto, s.projects.localgit(id).lastError], [true, null]);
  assert.equal(pointsHome({ urls: [HOME], pushUrls: [] }, 'devos', 'My-App'), true);
  assert.equal(pointsHome({ urls: [HOME, HOME], pushUrls: [] }, 'devos', 'My-App'), false);
  assert.equal(pointsHome({ urls: [HOME], pushUrls: ['x'] }, 'devos', 'My-App'), false);
  assert.equal(pointsHome(undefined, 'devos', 'My-App'), false);
});
