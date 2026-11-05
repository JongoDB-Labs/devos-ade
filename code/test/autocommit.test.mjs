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
const diff = (path, lines, extra = {}) => ({ files: [{ path, status: 'modified', binary: false, symlink: false, hunks: [{ lines: lines.map((l) => `+${l}`) }], ...extra }] });

function fakeGit({ unstaged = [], untracked = [], staged = [], files = {}, extra = {} } = {}) {
  const calls = { stage: [], commit: [], file: [] };
  const git = {
    calls,
    status: async () => ({ repo: true, branch: 'feat', detached: false, state: null, conflicts: [], truncated: false, staged, unstaged, untracked, ...extra }),
    file: async (repo, o) => { calls.file.push(o); return files[`${o.scope}:${o.path ?? ''}`] ?? { files: [] }; },
    stage: async (repo, paths) => { calls.stage.push(paths); return { ok: true }; },
    commit: async (repo, message) => { calls.commit.push(message); return { ok: true, head: 'a'.repeat(40) }; },
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
  const git = fakeGit({ unstaged: [ent('src/a.js')], untracked: [{ path: 'src/new.js' }], files: { 'unstaged:src/a.js': diff('src/a.js', ['const a = 1;']) } });
  const out = await autoCommit({ git, repo: '' });
  assert.equal(out.committed, true);
  assert.deepEqual(git.calls.stage, [['src/a.js', 'src/new.js']]);
  assert.equal(git.calls.commit.length, 1);
  assert.match(git.calls.commit[0], new RegExp(`\\n\\n${TRAILER}\\n$`));
  assert.match(git.calls.commit[0], /src\/a\.js, src\/new\.js/);
});

test('files that are staged already are committed too, and scanned', async () => {
  const ok = fakeGit({ staged: [ent('x.txt')], files: { 'staged:': diff('x.txt', ['fine']) } });
  assert.equal((await autoCommit({ git: ok, repo: '' })).committed, true);
  assert.equal(ok.calls.stage.length, 0);
  const bad = fakeGit({ staged: [ent('x.txt')], files: { 'staged:': diff('x.txt', [`token = "${GH}"`]) } });
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
  for (const p of ['.env', '.env.local', 'app/.env.production', 'k.pem', 'a/b.key', 'x.p12', 'x.pfx', 'x.keystore', 'id_rsa', 'id_ed25519', '.netrc', 'h/.ssh/config', 'aws-credentials', 'credentials.json', 'my-secret-token.json']) {
    assert.equal(credentialPath(p), true, p);
  }
  for (const p of ['.env.example', '.env.sample', '.env.template', 'id_rsa.pub', 'package.json', '.npmrc', 'src/token.ts', 'README.md', 'tsconfig.json', 'keyboard.js']) {
    assert.equal(credentialPath(p), false, p);
  }
});

test('a deleted .env is not a secret being committed', async () => {
  const git = fakeGit({ unstaged: [{ path: '.env', code: 'D' }] });
  assert.equal((await autoCommit({ git, repo: '' })).committed, true);
});

test('a source file with a secret-shaped token (by content): no commit, the value is not in the notice', async () => {
  const git = fakeGit({ unstaged: [ent('src/a.js'), ent('src/cfg.js')],
    files: { 'unstaged:src/cfg.js': diff('src/cfg.js', [`const token = "${GH}";`]) } });
  const out = await autoCommit({ git, repo: '' });
  assert.equal(out.committed, false);
  assert.match(out.paused, /src\/cfg\.js/);
  assert.ok(!out.paused.includes(GH));
  assert.equal(git.calls.stage.length, 0);
  assert.equal(git.calls.commit.length, 0);
  const keyBlock = fakeGit({ untracked: [{ path: 'notes.txt' }], files: { 'untracked:notes.txt': diff('notes.txt', ['-----BEGIN RSA PRIVATE KEY-----', 'MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu', '-----END RSA PRIVATE KEY-----']) } });
  assert.equal((await autoCommit({ git: keyBlock, repo: '' })).committed, false);
});

test('a clean package.json edit and .npmrc are committed (not blocked by name)', async () => {
  const git = fakeGit({ unstaged: [ent('package.json'), ent('.npmrc')],
    files: { 'unstaged:package.json': diff('package.json', ['  "version": "1.2.4",', '  "scripts": { "test": "node --test" }']), 'unstaged:.npmrc': diff('.npmrc', ['registry=https://registry.npmjs.org/']) } });
  assert.equal((await autoCommit({ git, repo: '' })).committed, true);
});

test('a token in an .npmrc is caught by content', async () => {
  const git = fakeGit({ unstaged: [ent('.npmrc')], files: { 'unstaged:.npmrc': diff('.npmrc', [`//registry.npmjs.org/:_authToken=${['npm', '_', 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'].join('')}`]) } });
  assert.equal((await autoCommit({ git, repo: '' })).committed, false);
});

test('an ignored file is not in the status, so it is never staged; binaries are not scanned', async () => {
  const git = fakeGit({ unstaged: [ent('logo.png')], files: { 'unstaged:logo.png': { files: [{ path: 'logo.png', binary: true, hunks: [] }] } } });
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
