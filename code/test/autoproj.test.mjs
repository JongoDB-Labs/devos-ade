// Projects made by themselves (code/server/autoproj.mjs, projects.mjs removed/auto, the project list in main.mjs): a repository
// or a project folder made in the workspace is a project without a click; kept on the local git server by the rules; a folder you
// remove is not added again; the first version's "Not now" list is read as removed; failures are said once; and the list wiring.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeAutoProjects, ADD_MAX, MIN_GAP_MS } from '../server/autoproj.mjs';
import { Projects } from '../server/projects.mjs';
import { LOCALGIT } from '../server/githosts.mjs';
import { createServer } from '../server/main.mjs';
import { SandboxError } from '../server/spawn-client.mjs';
import { fakeQuery } from './fake-sdk.mjs';
import { tmp, stubDist } from './helpers.mjs';

const dirOf = (p) => ({ path: p, kind: 'dir' });
// a harness: the real records in a temp folder, a stand-in sandbox, keeper and git hosts
function rig(over = {}) {
  const st = { repos: [], folders: [], owner: 'forge', hosts: [{ builtin: LOCALGIT.id, claude: true }], remotes: {}, keepFails: false, callFails: null, kept: [], logs: [], calls: [], clock: 1_000_000 };
  const store = new Projects({ dir: tmp('bnauto'), now: () => 1_700_000_000_000 });
  const add = async (b) => {
    const p = store.add({ root: b.folder });
    return { project: p, git: st.repos.some((r) => r.path === b.folder) };
  };
  const auto = makeAutoProjects({
    call: async (req) => { st.calls.push(req); if (st.callFails) throw st.callFails; return { result: { repos: st.repos, folders: st.folders } }; },
    projects: () => store, addProject: add,
    keeper: () => ({ keep: async (id, b) => {
      if (st.keepFails) throw new Error('the git server said no');
      const repo = `forge/${b.name}`;
      store.setLocalgit(id, () => ({ state: 'kept', repo, remote: 'origin', auto: true, made: true, pushedAt: null, lastError: null, heads: {}, rejected: {} }));
      st.kept.push(b.name);
      return { repo };
    } }),
    mirrors: { owner: () => st.owner }, hosts: () => st.hosts,
    remoteState: async (rel) => ({ repo: true, remotes: st.remotes[rel] ?? [] }),
    log: (m) => st.logs.push(m), now: () => st.clock, ...over });
  const scan = async () => { st.clock += MIN_GAP_MS + 1; await auto.scan(); };
  return { st, store, auto, scan, rootsOf: () => store.list().filter((p) => !p.workspace).map((p) => p.root).sort() };
}

test('a repository and a project folder of the workspace become projects; not a project, nested, around one, or a file-kind .git', async () => {
  const r = rig();
  r.store.add({ root: 'mine' });
  r.st.repos = [dirOf('rtm-tracker'), dirOf('mine'), dirOf('mine/inner'), dirOf('client/site'), { path: 'wt', kind: 'file' }, dirOf('../etc'), dirOf('.hidden'), dirOf('a\nb')];
  r.st.folders = [{ path: 'web' }, { path: 'mine' }, { path: 'client' }, { path: '.x' }];
  await r.scan();
  assert.deepEqual(r.st.calls[0], { op: 'git.repos', files: true });
  // ('client' holds client/site, a project by then: around one; 'mine' is one already)
  assert.deepEqual(r.rootsOf(), ['client/site', 'mine', 'rtm-tracker', 'web']);
  assert.deepEqual(r.store.notices().map((n) => n.id).length, 3, 'one notice per project added by itself, none for mine');
  await r.scan();
  assert.equal(r.store.list().length, 5, 'a second look adds nothing');
});

test('Remove from Code is remembered; adding by hand forgets it; a folder trashed with its project is free again', async () => {
  const r = rig();
  r.st.repos = [dirOf('a'), dirOf('b')];
  await r.scan();
  const a = r.store.list().find((p) => p.root === 'a');
  r.store.remove(a.id);
  assert.deepEqual(r.store.removedRoots(), ['a']);
  assert.equal(r.store.notices().some((n) => n.id === a.id), false, 'its notice goes with it');
  await r.scan();
  assert.deepEqual(r.rootsOf(), ['b'], 'not added again');
  assert.deepEqual(new Projects({ dir: r.store.dir.replace(/\/projects$/, '') }).removedRoots(), ['a'], 'also after a restart');
  r.store.add({ root: 'a' });                                   // New project / the terminal's project add
  assert.deepEqual(r.store.removedRoots(), []);
  const b = r.store.list().find((p) => p.root === 'b');
  r.store.remove(b.id, { remember: false });                    // its folder went to the trash too
  assert.deepEqual(r.store.removedRoots(), []);
  await r.scan();
  assert.deepEqual(r.rootsOf(), ['a', 'b']);
});

test('the first version\'s "Not now" list (found) is read as removed and no longer written', async () => {
  const dir = tmp('bnautomig');
  fs.mkdirSync(path.join(dir, 'projects'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'projects/projects.json'), JSON.stringify({ version: 1, projects: [], found: ['fresh', '../etc', 'client/site', 'fresh'] }));
  const store = new Projects({ dir });
  assert.deepEqual(store.removedRoots(), ['fresh', 'client/site']);
  const auto = makeAutoProjects({ call: async () => ({ result: { repos: [dirOf('fresh'), dirOf('other')], folders: [] } }), projects: () => store,
    addProject: async (b) => ({ project: store.add({ root: b.folder }) }), keeper: () => ({}), mirrors: { owner: () => null }, hosts: () => [], remoteState: async () => ({}) });
  await auto.scan();
  assert.deepEqual(store.list().filter((p) => !p.workspace).map((p) => p.root), ['other'], 'a declined folder stays out');
  const file = JSON.parse(fs.readFileSync(path.join(dir, 'projects/projects.json'), 'utf8'));
  assert.equal('found' in file, false);
  assert.deepEqual(file.removed, ['fresh', 'client/site']);
});

test('kept on the local git server: a repository with no remote, server on, switch on, a valid name', async () => {
  const r = rig();
  r.st.repos = [dirOf('rtm-tracker')];
  await r.scan();
  assert.deepEqual(r.st.kept, ['rtm-tracker']);
  assert.equal(r.store.localgit(r.store.list().find((p) => p.root === 'rtm-tracker').id).state, 'kept');
  await r.scan();
  assert.deepEqual(r.st.kept, ['rtm-tracker'], 'once');
});

test('not kept: a remote of its own (decided, so asked no more), a folder without git, the server off, the switch off, a name that is no repository name', async () => {
  const r = rig();
  r.st.repos = [dirOf('cloned')];
  r.st.remotes.cloned = [{ name: 'origin' }];
  r.st.folders = [{ path: 'plain' }];
  await r.scan();
  assert.deepEqual(r.st.kept, [], 'a clone and a non-git folder: added, not kept');
  assert.deepEqual(r.rootsOf(), ['cloned', 'plain']);
  assert.deepEqual(r.store.notices().map((n) => n.tried), [true, false], 'the clone is decided; the plain folder waits for git');
  // the server off, then on: a repository waiting is kept when it can be
  const s = rig();
  s.st.owner = null;
  s.st.repos = [dirOf('app')];
  await s.scan();
  assert.deepEqual(s.st.kept, [], 'server not connected');
  s.st.owner = 'forge'; s.st.hosts = [{ builtin: LOCALGIT.id, claude: false }];
  await s.scan();
  assert.deepEqual(s.st.kept, [], 'the host does not let Claude use it');
  s.st.hosts = [{ builtin: 'other', claude: true }];
  await s.scan();
  assert.deepEqual(s.st.kept, [], 'only the built-in host counts');
  s.st.hosts = [{ builtin: LOCALGIT.id, claude: true }];
  await s.scan();
  assert.deepEqual(s.st.kept, ['app'], 'the switch on later: kept');
  const n = rig();
  n.st.repos = [dirOf('my project'), dirOf('ok.git')];
  await n.scan();
  assert.deepEqual(n.st.kept, [], 'a space, a name ending in .git: not a repository name');
  assert.equal(n.rootsOf().length, 2);
});

test('Start git here: a plain folder that became a repository is kept by the same rule', async () => {
  const r = rig();
  r.st.folders = [{ path: 'site' }];
  await r.scan();
  assert.deepEqual(r.st.kept, []);
  r.st.folders = []; r.st.repos = [dirOf('site')];           // projectGitInit ran in it
  await r.scan();
  assert.deepEqual(r.st.kept, ['site']);
});

test('a keeping that fails is told once and not tried again; one stopped by hand is not kept again', async () => {
  const r = rig();
  r.st.keepFails = true;
  r.st.repos = [dirOf('one')];
  await r.scan(); await r.scan();
  assert.equal(r.st.logs.filter((l) => /not kept/.test(l)).length, 1);
  const k = rig();
  k.st.repos = [dirOf('two')];
  await k.scan();
  const id = k.store.list().find((p) => p.root === 'two').id;
  k.store.setLocalgit(id, () => null);                       // Stop keeping it here
  await k.scan(); await k.scan();
  assert.deepEqual(k.st.kept, ['two'], 'kept once only');
});

test('failures are logged once; an older sandbox is told once; looks do not pile up', async () => {
  const r = rig();
  r.st.callFails = new SandboxError('the sandbox closed the connection');
  await r.scan(); await r.scan(); await r.scan();
  assert.equal(r.st.logs.length, 1);
  r.st.callFails = new SandboxError('unknown op', 'refused');
  await r.scan(); await r.scan();
  assert.equal(r.st.logs.filter((l) => /older/.test(l)).length, 1);
  // one look at a time, and none within the gap of the last
  const q = rig();
  q.st.clock += MIN_GAP_MS + 1;
  await Promise.all([q.auto.scan(), q.auto.scan(), q.auto.scan()]);
  assert.equal(q.st.calls.length, 1);
  await q.auto.scan();
  assert.equal(q.st.calls.length, 1, 'within the gap');
  await q.auto.scan({ force: true });
  assert.equal(q.st.calls.length, 2);
});

test('at most ADD_MAX projects per look', async () => {
  const r = rig();
  r.st.repos = Array.from({ length: ADD_MAX + 5 }, (_, i) => dirOf(`r${String(i).padStart(2, '0')}`));
  await r.scan();
  assert.equal(r.rootsOf().length, ADD_MAX);
  await r.scan();
  assert.equal(r.rootsOf().length, ADD_MAX + 5);
});

// --- the list: GET /api/projects looks first, and says what was added; the notice is dismissed; Remove from Code is remembered ---
test('GET /api/projects adds what the workspace holds first and lists the notices; dismiss keeps the project; DELETE is remembered', async () => {
  const SECRET = 'ab'.repeat(16);
  const state = { repos: [dirOf('rtm-tracker')], folders: [{ path: 'web' }] };
  const answers = {
    'git.repos': () => ({ result: { repos: state.repos, folders: state.folders } }),
    'project.check': (req) => ({ result: { roots: req.roots.map((x) => ({ root: x, type: 'dir', git: x.endsWith('rtm-tracker'), real: x, settings: null, settingsVerifiable: true })) } }),
    'sessions.list': () => ({ result: { sessions: [] } }), 'sessions.running': () => ({ result: { running: false } }), 'ws.sensitive': () => ({ result: { files: [] } }),
  };
  const call = async (req) => { const a = answers[req.op]; if (!a) throw new SandboxError('unknown op', 'refused'); return a(req); };
  const dist = stubDist('bnautodist');
  const store = new Projects({ dir: tmp('bnautoapi') });
  const srv = createServer({ secret: SECRET, query: fakeQuery(), spawn: () => {}, call, distDir: dist, logger: () => {}, projects: store, autoProjectMs: 0 });
  await new Promise((r) => srv.server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${srv.server.address().port}`;
  const req = async (method, p, body) => {
    const r = await fetch(base + p, { method, headers: { 'X-Bn-Code-Proxy': SECRET, ...(body !== undefined ? { 'Content-Type': 'application/json', Origin: base } : method !== 'GET' ? { Origin: base } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined });
    return { status: r.status, json: await r.json().catch(() => null) };
  };
  try {
    let r = await req('GET', '/api/projects');
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.projects.filter((p) => !p.workspace).map((p) => p.root).sort(), ['rtm-tracker', 'web']);
    assert.deepEqual(r.json.added.map((a) => a.id).sort(), r.json.projects.filter((p) => !p.workspace).map((p) => p.id).sort());
    assert.ok(r.json.added.every((a) => a.kept === null && a.declined === false));
    const web = r.json.projects.find((p) => p.root === 'web'), rtm = r.json.projects.find((p) => p.root === 'rtm-tracker');
    // dismiss: the notice goes, the project stays; twice is fine; a bad id is refused
    r = await req('POST', '/api/projects/added/dismiss', { id: web.id });
    assert.deepEqual(r.json, { ok: true, dismissed: true });
    assert.equal((await req('POST', '/api/projects/added/dismiss', { id: web.id })).json.dismissed, false);
    assert.equal((await req('POST', '/api/projects/added/dismiss', { id: '../x' })).status, 400);
    r = await req('GET', '/api/projects');
    assert.deepEqual(r.json.added.map((a) => a.id), [rtm.id]);
    assert.ok(r.json.projects.some((p) => p.id === web.id));
    // Remove from Code: gone, and not added again by the next look
    assert.equal((await req('DELETE', `/api/projects/${rtm.id}`)).status, 200);
    r = await req('GET', '/api/projects');
    assert.deepEqual(r.json.projects.filter((p) => !p.workspace).map((p) => p.root), ['web']);
    assert.deepEqual(r.json.added, []);
    // the old routes are gone
    assert.equal((await req('GET', '/api/projects/found')).status, 404);
  } finally {
    srv.mgr.closeAll(); srv.wss.close(); srv.server.closeAllConnections?.(); srv.server.close(); srv.closeGit(); fs.rmSync(dist, { recursive: true, force: true });
  }
});
