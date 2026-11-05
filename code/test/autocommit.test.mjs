// The end-of-turn commit of a kept project (autocommit.mjs, keep.mjs; JON-1139): nothing on a clean tree, one commit marked
// by a trailer otherwise, never a secret (by name or by content) — and then nothing at all — never an ignored file, and the
// push that follows is keep.mjs's own. The sandbox's git is a stand-in.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { autoCommit, credentialPath, TRAILER, PAUSED } from '../server/autocommit.mjs';
import { makeKeep } from '../server/keep.mjs';
import { localgitRecord } from '../server/projects.mjs';

// fake secrets are built here, never written whole
const GH = ['ghp', '_', 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8'].join('');
const ent = (path, extra = {}) => ({ path, code: 'M', ...extra });
const entry = (path, lines = [], extra = {}) => ({ path, status: 'modified', binary: false, symlink: false, cut: false, bad: false, hunks: [{ lines: lines.map((l) => `+${l}`) }], ...extra });

// a stand-in for the sandbox's git: lines — path -> the added lines of its diff; binary — paths git calls binary; answer(o) — a
// test's own answer to a git.file call (undefined: the usual one); beforeCommit() — something that happens after the staging
function fakeGit({ unstaged = [], untracked = [], staged = [], lines = {}, binary = [], answer = null, extra = {}, stageFails = false, beforeCommit = null } = {}) {
  const calls = { stage: [], unstage: [], commit: [], file: [] };
  const index = new Set(staged.map((x) => x.path));
  const mk = (p) => entry(p, lines[p] ?? [], binary.includes(p) ? { binary: true, hunks: [] } : {});
  const git = {
    calls, index,
    status: async () => ({ repo: true, branch: 'feat', detached: false, state: null, conflicts: [], truncated: false, staged, unstaged, untracked, ...extra }),
    file: async (repo, o) => {
      calls.file.push(o);
      const a = answer?.(o);
      if (a !== undefined) return a;
      return { files: o.scope === 'staged' && !o.path ? [...index].map(mk) : [mk(o.path)] };
    },
    stage: async (repo, paths) => {
      calls.stage.push(paths);
      if (stageFails && calls.stage.length === 2) throw new Error('index.lock exists');
      for (const p of paths) index.add(p);
      return { ok: true };
    },
    unstage: async (repo, paths) => { calls.unstage.push(paths); for (const p of paths) index.delete(p); return { ok: true }; },
    commit: async (repo, message) => { if (beforeCommit) beforeCommit(); calls.commit.push(message); return { ok: true, head: 'a'.repeat(40) }; },
  };
  return git;
}

test('a clean tree is no commit', async () => {
  const git = fakeGit();
  assert.deepEqual(await autoCommit({ git, repo: '' }), { committed: false, clean: true });
  assert.equal(git.calls.commit.length, 0);
  assert.equal(git.calls.stage.length, 0);
});

test('a dirty tree: the files staged by name, one commit with the trailer, nothing amended', async () => {
  const git = fakeGit({ unstaged: [ent('src/a.js')], untracked: [{ path: 'src/new.js' }], lines: { 'src/a.js': ['const a = 1;'] } });
  const out = await autoCommit({ git, repo: '' });
  assert.equal(out.committed, true);
  assert.deepEqual(git.calls.stage, [['src/a.js', 'src/new.js']]);
  assert.equal(git.calls.commit.length, 1);
  assert.match(git.calls.commit[0], new RegExp(`\\n\\n${TRAILER}\\n$`));
  assert.match(git.calls.commit[0], /src\/a\.js, src\/new\.js/);
});

test('files that are staged already are committed too, and scanned', async () => {
  const ok = fakeGit({ staged: [ent('x.txt')], lines: { 'x.txt': ['fine'] } });
  assert.equal((await autoCommit({ git: ok, repo: '' })).committed, true);
  assert.equal(ok.calls.stage.length, 0);
  const bad = fakeGit({ staged: [ent('x.txt')], lines: { 'x.txt': [`token = "${GH}"`] } });
  const out = await autoCommit({ git: bad, repo: '' });
  assert.equal(out.committed, false);
  assert.match(out.paused, /x\.txt/);
  assert.equal(bad.calls.commit.length, 0);
});

test('a .env by name: no commit at all, not even of the other files, and the notice says which', async () => {
  const git = fakeGit({ unstaged: [ent('src/a.js')], untracked: [{ path: '.env' }] });
  const out = await autoCommit({ git, repo: '' });
  assert.equal(out.committed, false);
  assert.ok(out.paused.startsWith(PAUSED));
  assert.match(out.paused, /\.env/);
  assert.match(out.paused, /commit manually/);
  assert.equal(git.calls.stage.length, 0);
  assert.equal(git.calls.commit.length, 0);
});

test('credential file names', () => {
  for (const p of ['.env', '.env.local', 'app/.env.production', 'k.pem', 'a/b.key', 'x.p12', 'x.pfx', 'x.keystore', 'id_rsa', 'id_ed25519', '.netrc', 'h/.ssh/config', 'aws-credentials', 'credentials.json', 'my-secret-token.json', '.ENV', '.Env.local', '.envrc', 'prod.tfvars', 'terraform.tfstate', 'secrets.yml', 'config/secrets.json', '.pgpass', 'k.p8', 'a.jks', 'a.ppk', '.htpasswd', 'kubeconfig', 'server.key.bak', 'cert.pem~', '.env.orig', 'id_rsa.bak']) {
    assert.equal(credentialPath(p), true, p);
  }
  for (const p of ['.env.example', '.env.sample', '.env.template', 'id_rsa.pub', 'package.json', '.npmrc', 'src/token.ts', 'README.md', 'tsconfig.json', 'keyboard.js', '.env.example.bak', 'id_rsa.pub', 'app.jsx']) {
    assert.equal(credentialPath(p), false, p);
  }
});

test('a deleted .env is not a secret being committed', async () => {
  const git = fakeGit({ unstaged: [{ path: '.env', code: 'D' }] });
  assert.equal((await autoCommit({ git, repo: '' })).committed, true);
});

test('a source file with a secret-shaped token (by content): no commit, the value is not in the notice', async () => {
  const git = fakeGit({ unstaged: [ent('src/a.js'), ent('src/cfg.js')], lines: { 'src/cfg.js': [`const token = "${GH}";`] } });
  const out = await autoCommit({ git, repo: '' });
  assert.equal(out.committed, false);
  assert.match(out.paused, /src\/cfg\.js/);
  assert.ok(!out.paused.includes(GH));
  assert.equal(git.calls.stage.length, 0);
  assert.equal(git.calls.commit.length, 0);
  const keyBlock = fakeGit({ untracked: [{ path: 'notes.txt' }], lines: { 'notes.txt': ['-----BEGIN RSA PRIVATE KEY-----', 'MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu', '-----END RSA PRIVATE KEY-----'] } });
  assert.equal((await autoCommit({ git: keyBlock, repo: '' })).committed, false);
});

test('a clean package.json edit and .npmrc are committed (not blocked by name)', async () => {
  const git = fakeGit({ unstaged: [ent('package.json'), ent('.npmrc')],
    lines: { 'package.json': ['  "version": "1.2.4",', '  "scripts": { "test": "node --test" }'], '.npmrc': ['registry=https://registry.npmjs.org/'] } });
  assert.equal((await autoCommit({ git, repo: '' })).committed, true);
});

test('a token in an .npmrc is caught by content', async () => {
  const git = fakeGit({ unstaged: [ent('.npmrc')], lines: { '.npmrc': [`//registry.npmjs.org/:_authToken=${['npm', '_', 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'].join('')}`] } });
  assert.equal((await autoCommit({ git, repo: '' })).committed, false);
});

test('an ignored file is not in the status, so it is never staged; binaries are not scanned', async () => {
  const git = fakeGit({ unstaged: [ent('logo.png')], binary: ['logo.png'] });
  const out = await autoCommit({ git, repo: '' });
  assert.equal(out.committed, true);
  assert.deepEqual(git.calls.stage.flat(), ['logo.png']);
});

test('a merge in progress, a detached head, conflicts, or too many files: paused, nothing committed', async () => {
  for (const extra of [{ state: 'merge' }, { detached: true }, { conflicts: [{ path: 'a', code: 'UU' }] }, { truncated: true }]) {
    const git = fakeGit({ unstaged: [ent('a.js')], extra });
    const out = await autoCommit({ git, repo: '' });
    assert.equal(out.committed, false);
    assert.ok(out.paused, JSON.stringify(extra));
    assert.equal(git.calls.commit.length, 0);
  }
});

test('150 files are staged in groups', async () => {
  const many = Array.from({ length: 150 }, (_, i) => ent(`f${i}.txt`));
  const git = fakeGit({ unstaged: many });
  assert.equal((await autoCommit({ git, repo: '' })).committed, true);
  assert.deepEqual(git.calls.stage.map((g) => g.length), [100, 50]);
});

const KEY = ['-----BEGIN RSA PRIVATE KEY-----', 'MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu', '-----END RSA PRIVATE KEY-----'];

test('fails closed: a file git.file could not give whole is a pause, never a commit', async () => {
  const big = (o) => (o.path === 'big.txt' ? { files: [], truncated: true } : undefined);   // (an untracked file over 256 KiB, a key inside)
  const g1 = fakeGit({ untracked: [{ path: 'big.txt' }, { path: 'ok.txt' }], answer: big });
  const o1 = await autoCommit({ git: g1, repo: '' });
  assert.equal(o1.committed, false);
  assert.match(o1.paused, /big\.txt could not be checked/);
  assert.equal(g1.calls.stage.length, 0);
  assert.equal(g1.calls.commit.length, 0);
  // a line over 10,000 characters: the key after the cut is not seen
  const g2 = fakeGit({ unstaged: [ent('long.js')], answer: () => ({ files: [entry('long.js', ['x'.repeat(10001)], { cut: true })] }) });
  const o2 = await autoCommit({ git: g2, repo: '' });
  assert.equal(o2.committed, false);
  assert.match(o2.paused, /long\.js/);
  assert.equal(g2.calls.commit.length, 0);
  // a patch over 2 MiB
  const g3 = fakeGit({ unstaged: [ent('a.js')], answer: () => ({ files: [entry('a.js', ['x'])], truncated: true }) });
  assert.equal((await autoCommit({ git: g3, repo: '' })).committed, false);
  // a file git.file gave no entry for (a wanted path that is not a deletion or a binary)
  const g4 = fakeGit({ unstaged: [ent('lost.js')], answer: () => ({ files: [] }) });
  assert.equal((await autoCommit({ git: g4, repo: '' })).committed, false);
  // malformed
  const g5 = fakeGit({ unstaged: [ent('odd.js')], answer: () => ({ files: [entry('odd.js', [], { bad: true })] }) });
  assert.equal((await autoCommit({ git: g5, repo: '' })).committed, false);
  // a staged diff cut
  const g6 = fakeGit({ staged: [ent('s.js')], answer: () => ({ files: [], truncated: true }) });
  assert.equal((await autoCommit({ git: g6, repo: '' })).committed, false);
  // a real binary stays allowed, and so does a deletion
  const g7 = fakeGit({ unstaged: [ent('logo.png'), { path: 'old.js', code: 'D' }], binary: ['logo.png'] });
  assert.equal((await autoCommit({ git: g7, repo: '' })).committed, true);
});

test('the staged files are checked once more, whole, before the commit: a file staged meanwhile with a secret is caught', async () => {
  const g = fakeGit({ unstaged: [ent('a.js')], lines: { 'a.js': ['ok'], 'late.txt': KEY } });
  g.stage = ((stage) => async (repo, paths) => { const r = await stage(repo, paths); g.index.add('late.txt'); return r; })(g.stage);
  const out = await autoCommit({ git: g, repo: '' });
  assert.equal(out.committed, false);
  assert.ok(out.paused);
  assert.equal(g.calls.commit.length, 0);
  assert.ok(!g.index.has('a.js'), 'what was staged here is put back');
});

test('the staged set that is not the vetted set is a pause (an extra clean file too), and the final scan must be whole', async () => {
  const g = fakeGit({ unstaged: [ent('a.js')], lines: { 'a.js': ['ok'] } });
  g.stage = ((stage) => async (repo, paths) => { const r = await stage(repo, paths); g.index.add('extra.txt'); return r; })(g.stage);
  const out = await autoCommit({ git: g, repo: '' });
  assert.equal(out.committed, false);
  assert.match(out.paused, /not what was checked/);
  const g2 = fakeGit({ unstaged: [ent('a.js')], answer: (o) => (o.scope === 'staged' ? { files: [entry('a.js')], truncated: true } : undefined) });
  assert.equal((await autoCommit({ git: g2, repo: '' })).committed, false);
  assert.equal(g2.calls.commit.length, 0);
});

test('a stage that fails midway puts back what was staged, says why, and commits nothing', async () => {
  const many = Array.from({ length: 150 }, (_, i) => ent(`f${i}.txt`));
  const g = fakeGit({ unstaged: many, stageFails: true });
  const out = await autoCommit({ git: g, repo: '' });
  assert.equal(out.committed, false);
  assert.match(out.error, /could not stage.*index\.lock/);
  assert.equal(g.index.size, 0, 'nothing is left staged');
  assert.equal(g.calls.commit.length, 0);
  // a file you staged yourself stays staged
  const g2 = fakeGit({ staged: [ent('mine.txt')], unstaged: many, stageFails: true });
  await autoCommit({ git: g2, repo: '' });
  assert.deepEqual([...g2.index], ['mine.txt']);
});

test('a throw in finding the project folder is told on the record, and the push step still runs', async () => {
  const k = keepWith({ git: fakeGit({ unstaged: [ent('a.js')] }) });
  const store = k.store;
  store.rootOf = () => { throw new Error('no such project'); };
  let looked = 0;
  const localgit = store.localgit;
  store.localgit = (...a) => { looked++; return localgit(...a); };
  await k.keep.turnEnded('/w');
  assert.match(k.rec().lastError, /Auto-sync could not commit/);
  assert.ok(looked >= 3, 'trigger (the push) still ran after the commit step failed');
});

// --- keep.mjs: the toggle, and the turn's end ---
function keepWith({ git, rec = {}, onPush = () => {} } = {}) {
  let r = localgitRecord({ state: 'kept', repo: 'me/proj', remote: 'origin', autoCommit: true, heads: {}, rejected: {}, ...rec });
  const logs = [];
  const store = {
    localgit: () => r, get: () => ({ id: 'ws', name: 'p' }), keptIds: () => ['ws'], folderOf: () => ({ id: 'ws' }), rootOf: () => ({ rel: '', mode: 'rw' }),
    setLocalgit: (id, fn) => { r = localgitRecord(fn(r)); return r; },
  };
  const pushes = [];
  const remote = { state: async () => { pushes.push('look'); return { repo: false }; } };
  const keep = makeKeep({ store: () => store, remote: () => remote, mirrors: { owner: () => 'me' }, git, log: (m) => logs.push(m) });
  return { keep, store, pushes, logs, rec: () => r };
}

test('the record: autoCommit is false unless it is true', () => {
  assert.equal(localgitRecord({ state: 'kept', repo: 'me/p', remote: 'origin' }).autoCommit, false);
  assert.equal(localgitRecord({ state: 'kept', repo: 'me/p', remote: 'origin', autoCommit: 'yes' }).autoCommit, false);
  assert.equal(localgitRecord({ state: 'kept', repo: 'me/p', remote: 'origin', autoCommit: true }).autoCommit, true);
});

test('setAutoCommit: set, persisted, checked', async () => {
  const k = keepWith({ git: fakeGit(), rec: { autoCommit: false } });
  assert.equal(k.rec().autoCommit, false);
  assert.equal((await k.keep.setAutoCommit('ws', true)).autoCommit, true);
  assert.equal(k.rec().autoCommit, true);
  await assert.rejects(k.keep.setAutoCommit('ws', 'on'), /true or false/);
  assert.equal((await k.keep.setAutoCommit('ws', false)).autoCommit, false);
});

test('turn ended, on, dirty: one commit, then the push look; clean: no second commit', async () => {
  const git = fakeGit({ unstaged: [ent('a.js')] });
  const k = keepWith({ git });
  await k.keep.turnEnded('/w');
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(git.calls.commit.length, 1);
  assert.ok(k.pushes.length >= 1, 'the push run follows');
  const clean = fakeGit();
  const k2 = keepWith({ git: clean });
  await k2.keep.turnEnded('/w');
  assert.equal(clean.calls.commit.length, 0);
});

test('turn ended, off: nothing is committed', async () => {
  const git = fakeGit({ unstaged: [ent('a.js')] });
  const k = keepWith({ git, rec: { autoCommit: false } });
  await k.keep.turnEnded('/w');
  assert.equal(git.calls.commit.length, 0);
  assert.equal(git.calls.file.length, 0);
});

test('a pause is told on the record, and taken off by a later good turn; a .env turn does not push', async () => {
  const git = fakeGit({ untracked: [{ path: '.env' }] });
  const k = keepWith({ git });
  await k.keep.turnEnded('/w');
  assert.match(k.rec().lastError, /^Auto-sync paused this turn/);
  assert.equal(git.calls.commit.length, 0);
  git.status = async () => ({ repo: true, branch: 'm', detached: false, state: null, conflicts: [], truncated: false, staged: [], unstaged: [ent('a.js')], untracked: [] });
  await k.keep.turnEnded('/w');
  assert.equal(k.rec().lastError, null);
  assert.equal(git.calls.commit.length, 1);
});

test('two turns ending at once make one commit each in turn, never at the same time', async () => {
  let live = 0, max = 0;
  const git = fakeGit({ unstaged: [ent('a.js')] });
  const commit = git.commit;
  git.commit = async (...a) => { live++; max = Math.max(max, live); await new Promise((r) => setTimeout(r, 10)); live--; return commit(...a); };
  const k = keepWith({ git });
  await Promise.all([k.keep.turnEnded('/w'), k.keep.turnEnded('/w')]);
  assert.equal(max, 1);
});
