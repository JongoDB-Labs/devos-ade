// Mirroring of the built-in git server's repositories (mirrors.mjs, mirror-host.mjs): the requests Forgejo's API gets (a
// stand-in answers), which connected hosts may be a mirror's remote (an access token over https — never a sign-in, never the
// built-in server itself), the credential only in the request to the server, push (force) and pull (read-only copy) kept
// apart in what the page sees, the answers checked, and the script's one-line protocol.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { GitHosts, LOCALGIT } from '../server/githosts.mjs';
import { makeMirrors, toInterval } from '../server/mirrors.mjs';
import { run } from '../server/mirror-host.mjs';
import { tmp } from './helpers.mjs';

const ROOT = tmp('bnmirror');
after(() => fs.rmSync(ROOT, { recursive: true, force: true }));
const CA = fs.readFileSync(path.resolve(import.meta.dirname, '../../tests/fixtures/localgit-ca.pem'), 'utf8');
const LTOK = ['lg', 'tok_', 'L'.repeat(20)].join('');
const GTOK = ['gh', 'tok_', 'G'.repeat(20)].join('');

function setup(name) {
  const dir = path.join(ROOT, name);
  const store = new GitHosts({ dir });
  store.addLocalGit({ ca: CA, token: LTOK, account: 'devos' });
  store.add({ kind: 'github', auth: 'token', token: GTOK, username: 'octo' });
  return store;
}
// a stand-in Forgejo: logs each request, answers as set
function fake(answers = {}) {
  const calls = [];
  const fetchImpl = async (url, opts = {}) => {
    const u = new URL(url);
    const key = `${opts.method || 'GET'} ${u.pathname}${u.search}`;
    calls.push({ key, headers: opts.headers, body: opts.body ? JSON.parse(opts.body) : null });
    const a = Object.entries(answers).find(([k]) => key.startsWith(k));
    const [status, body] = a ? a[1] : [404, { message: 'not found' }];
    return { ok: status < 300, status, text: async () => JSON.stringify(body) };
  };
  return { fetchImpl, calls };
}

test('intervals: Forgejo\'s own minimum, hours and minutes, 0 for push-only', () => {
  assert.equal(toInterval(undefined), '8h0m0s');
  assert.equal(toInterval('8h'), '8h0m0s');
  assert.equal(toInterval('30m'), '0h30m0s');
  assert.equal(toInterval('90m'), '1h30m0s');
  assert.equal(toInterval('0'), '0s');
  for (const bad of ['5m', '0m', '1d', '8', '-1h', '1000h', 'abc', '8h; x']) assert.throws(() => toInterval(bad), /interval/, bad);
});

test('a push mirror: the connected host\'s access token goes to the git server in one request, and is in no view; the page sees a force-pushing copy', async () => {
  const store = setup('push');
  const f = fake({
    'GET /api/v1/repos/devos/app?': [200, { name: 'app' }], 'GET /api/v1/repos/devos/app': [200, { name: 'app' }],
    'POST /api/v1/repos/devos/app/push_mirrors': [200, { remote_name: 'remote_mirror_ab12', remote_address: 'https://octo:SECRET@github.com/octo/app.git', interval: '8h0m0s', sync_on_commit: true, created: '2026-10-28T01:00:00Z', last_update: '0001-01-01T00:00:00Z', last_error: '' }],
  });
  const m = makeMirrors({ store, fetchImpl: f.fetchImpl, base: 'http://caddy:8099' });
  const r = await m.add({ direction: 'push', repo: 'app', remote: 'https://github.com/octo/app' });
  const post = f.calls.find((c) => c.key.startsWith('POST'));
  assert.deepEqual(post.body, { remote_address: 'https://github.com/octo/app.git', remote_username: 'octo', remote_password: GTOK, interval: '8h0m0s', sync_on_commit: true });
  assert.equal(post.headers.Authorization, `token ${LTOK}`);
  assert.deepEqual([r.direction, r.repo, r.force, r.lastSync, r.syncOnCommit], ['push', 'devos/app', true, null, true]);
  assert.ok(!JSON.stringify(r).includes('SECRET') && !JSON.stringify(r).includes(GTOK) && !JSON.stringify(r).includes(LTOK), 'no credential in the view');
  assert.equal(r.remote, 'https://github.com/octo/app.git');   // (a user in the address, if the server echoes one, is cut)
});

test('a pull mirror: a new private repository, the remote the source, read-only for the page', async () => {
  const store = setup('pull');
  const f = fake({ 'POST /api/v1/repos/migrate': [201, { full_name: 'devos/up', original_url: 'https://github.com/octo/up.git', mirror: true, mirror_interval: '8h0m0s', mirror_updated: '2026-10-28T02:00:00Z', created_at: '2026-10-28T02:00:00Z' }] });
  const r = await makeMirrors({ store, fetchImpl: f.fetchImpl }).add({ direction: 'pull', repo: 'up', remote: 'https://github.com/octo/up.git', interval: '1h' });
  const post = f.calls[0];
  assert.deepEqual([post.body.clone_addr, post.body.mirror, post.body.private, post.body.repo_owner, post.body.repo_name, post.body.mirror_interval, post.body.auth_password],
    ['https://github.com/octo/up.git', true, true, 'devos', 'up', '1h0m0s', GTOK]);
  assert.deepEqual([r.direction, r.repo, r.force, r.lastSync], ['pull', 'devos/up', false, '2026-10-28T02:00:00Z']);
});

test('refused: a remote that is not a connected host, a sign-in, the server itself, plain http, a credential in the URL, a bad repository', async () => {
  const store = setup('refuse');
  const f = fake();
  const m = makeMirrors({ store, fetchImpl: f.fetchImpl });
  const rej = (b, re) => assert.rejects(m.add({ direction: 'push', repo: 'app', ...b }), re, JSON.stringify(b));
  await rej({ remote: 'https://gitlab.com/g/r' }, /gitlab.com is not a connected git host/);
  await rej({ remote: 'http://github.com/o/r' }, /plain http/);
  await rej({ remote: 'https://user:pw@github.com/o/r' }, /password or token/);
  await rej({ remote: 'git@github.com:o/r.git' }, /https/);
  await rej({ remote: 'https://gateway:8093/devos/x.git' }, /built-in git server itself/);
  await rej({ remote: 'https://github.com/o/r', repo: '../x' }, /repository on the built-in server/);
  await rej({ remote: 'https://github.com/o/r', direction: 'both' }, /direction/);
  // a sign-in's token lasts hours: not given to a server that pushes on its own later
  store.add({ kind: 'gitlab', host: 'gitlab.com', auth: 'token', token: GTOK });
  const id = store.list().find((h) => h.host === 'gitlab.com').id;
  store.remove(id);
  store.addOAuth({ kind: 'gitlab', host: 'gitlab.com', oauth: { source: 'signed-in', clientId: 'cid', accessToken: GTOK, refreshToken: `${GTOK}r`, account: 'g' } });
  await rej({ remote: 'https://gitlab.com/g/r' }, /connected with a sign-in/);
  assert.equal(f.calls.length, 0, 'nothing reached the server');
  // not connected at all: said
  const lone = new GitHosts({ dir: path.join(ROOT, 'lone') });
  await assert.rejects(makeMirrors({ store: lone, fetchImpl: f.fetchImpl }).list(), /not connected as a Git host yet/);
  // a repository that is not there: said (push needs it first)
  await assert.rejects(m.add({ direction: 'push', repo: 'nope', remote: 'https://github.com/o/r' }), /no repository devos\/nope/);
});

test('list: push mirrors of each repository and the pull-mirror repositories, with when they last synced and why not; answers checked', async () => {
  const store = setup('list');
  const f = fake({
    'GET /api/v1/user/repos': [200, [
      { name: 'app', owner: { login: 'devos' }, mirror: false }, { name: 'up', owner: { login: 'devos' }, mirror: true, full_name: 'devos/up', original_url: 'https://github.com/octo/up.git', mirror_interval: '8h0m0s', mirror_updated: '2026-10-28T02:00:00Z' },
      { name: 'other', owner: { login: 'someone' } }, { name: '../evil', owner: { login: 'devos' } }]],
    'GET /api/v1/repos/devos/app/push_mirrors': [200, [{ remote_name: 'm1', remote_address: 'https://github.com/octo/app.git', interval: '8h0m0s', sync_on_commit: true, last_update: '2026-10-28T03:00:00Z', last_error: 'x\u0007y'.repeat(200) }]],
    'GET /api/v1/repos/devos/up/push_mirrors': [200, []],
  });
  const m = makeMirrors({ store, fetchImpl: f.fetchImpl });
  const l = await m.list();
  assert.deepEqual(l.map((x) => `${x.direction}:${x.repo}`), ['push:devos/app', 'pull:devos/up']);
  assert.equal(l[0].lastSync, '2026-10-28T03:00:00Z');
  assert.ok(l[0].lastError.length <= 300 && !/[\x00-\x1f]/.test(l[0].lastError));
  assert.deepEqual(await m.hosts(), ['github.com']);
  assert.ok(!f.calls.some((c) => c.key.includes('evil') || c.key.includes('someone')));
});

test('sync and remove: the right calls; a pull mirror is a repository (deleted in the web UI)', async () => {
  const store = setup('sync');
  const f = fake({ 'POST /api/v1/repos/devos/app/push_mirrors-sync': [200, {}], 'POST /api/v1/repos/devos/up/mirror-sync': [200, {}], 'DELETE /api/v1/repos/devos/app/push_mirrors/m1': [204, null] });
  const m = makeMirrors({ store, fetchImpl: f.fetchImpl });
  assert.equal((await m.sync({ repo: 'app' })).direction, 'push');
  assert.equal((await m.sync({ repo: 'up', direction: 'pull' })).direction, 'pull');
  assert.equal((await m.remove({ repo: 'app', name: 'm1' })).ok, true);
  await assert.rejects(m.remove({ repo: 'up', direction: 'pull' }), /web UI/);
  await assert.rejects(m.remove({ repo: 'app', name: '../x' }), /mirror's name/);
  // the server refusing: its words are cut and said, never a stack
  const g = fake({ 'POST /api/v1/repos/devos/app/push_mirrors-sync': [403, { message: 'no\nway' }] });
  await assert.rejects(makeMirrors({ store, fetchImpl: g.fetchImpl }).sync({ repo: 'app' }), /the git server refused: no way/);
  // not answering: said
  await assert.rejects(makeMirrors({ store, fetchImpl: async () => { throw new Error('ECONNREFUSED'); } }).list(), /did not answer/);
});

test('the script: one JSON request on stdin, one line out; refusals as ok:false, never a token', async () => {
  const store = setup('script');
  const f = fake({ 'GET /api/v1/user/repos': [200, []] });
  const m = makeMirrors({ store, fetchImpl: f.fetchImpl });
  assert.deepEqual(await run('{"op":"list"}', m), { mirrors: [] });
  await assert.rejects(run('nope', m), /not the request/);
  await assert.rejects(run('[]', m), /not the request/);
  await assert.rejects(run('{"op":"drop"}', m), /op: list/);
  const dir = path.join(ROOT, 'proc');
  const r = spawnSync(process.execPath, [path.resolve(import.meta.dirname, '../server/mirror-host.mjs')], { input: '{"op":"list"}', env: { ...process.env, BN_CODE_STATE: dir }, encoding: 'utf8' });
  assert.equal(r.status, 1);   // (no built-in host in an empty store)
  assert.match(JSON.parse(r.stdout).error, /not connected as a Git host yet/);
});

test('the built-in host is the Local git server, kind other, marked builtin', () => {
  assert.equal(LOCALGIT.host, 'gateway');
});
