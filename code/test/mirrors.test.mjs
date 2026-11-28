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
    calls.push({ key, headers: opts.headers, body: opts.body ? (() => { try { return JSON.parse(opts.body); } catch { return opts.body; } })() : null });
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

test('create makes an empty private repository for a kept project the way a first push does (a receive-pack request with no commands, as the owner), looks that it is there, and a refusal or a repository that did not appear is said', async () => {
  const f = fake({ 'POST /devos/kept-app.git/git-receive-pack': [200, {}], 'GET /api/v1/repos/devos/kept-app': [200, { private: true, empty: true }] });
  const m = makeMirrors({ store: setup('create'), fetchImpl: f.fetchImpl, base: 'http://caddy:8099' });
  const made = await m.create('kept-app');
  assert.deepEqual(made, { owner: 'devos', name: 'kept-app', repo: 'devos/kept-app' });
  assert.deepEqual(f.calls.map((c) => c.key), ['POST /devos/kept-app.git/git-receive-pack', 'GET /api/v1/repos/devos/kept-app']);
  assert.equal(f.calls[0].body, '0000');
  assert.equal(f.calls[0].headers.Authorization, `Basic ${Buffer.from(`devos:${LTOK}`).toString('base64')}`);
  assert.equal(f.calls[0].headers['Content-Type'], 'application/x-git-receive-pack-request');
  const refused = fake({ 'POST /devos/kept-app.git/git-receive-pack': [403, {}] });
  await assert.rejects(makeMirrors({ store: setup('create2'), fetchImpl: refused.fetchImpl, base: 'http://caddy:8099' }).create('kept-app'), (e) => e.status === 502 && /would not make devos\/kept-app \(HTTP 403\)/.test(e.message));
  const absent = fake({ 'POST /devos/kept-app.git/git-receive-pack': [200, {}] });   // (answered, and no repository: push-to-create is off there)
  await assert.rejects(makeMirrors({ store: setup('create3'), fetchImpl: absent.fetchImpl, base: 'http://caddy:8099' }).create('kept-app'), (e) => e.status === 502 && /did not make devos\/kept-app/.test(e.message));
  await assert.rejects(makeMirrors({ store: setup('create4'), fetchImpl: refused.fetchImpl, base: 'http://caddy:8099' }).create('../x'), (e) => e.status === 400);
  assert.equal(refused.calls.length, 1, 'the bad name sent nothing');
});

test('protect asks for the default branch, then makes the one rule that refuses a force-push and a deletion of it (pushes left open, no allow-list); a rule there already is done, any other refusal is said', async () => {
  const f = fake({ 'GET /api/v1/repos/devos/kept-app': [200, { default_branch: 'trunk' }], 'POST /api/v1/repos/devos/kept-app/branch_protections': [201, {}] });
  const m = makeMirrors({ store: setup('protect'), fetchImpl: f.fetchImpl, base: 'http://caddy:8099' });
  assert.equal(await m.protect('kept-app'), 'trunk');
  assert.deepEqual(f.calls.map((c) => c.key), ['GET /api/v1/repos/devos/kept-app', 'POST /api/v1/repos/devos/kept-app/branch_protections']);
  const b = f.calls[1].body;
  assert.equal(b.rule_name, 'trunk'); assert.equal(b.enable_push, true); assert.equal(b.enable_push_whitelist, false);
  assert.deepEqual(b.push_whitelist_usernames ?? [], []);
  const dup = fake({ 'GET /api/v1/repos/devos/kept-app': [200, {}], 'POST /api/v1/repos/devos/kept-app/branch_protections': [403, { message: 'Branch protection already exist' }] });
  assert.equal(await makeMirrors({ store: setup('protect2'), fetchImpl: dup.fetchImpl, base: 'http://caddy:8099' }).protect('kept-app'), 'main', 'no default branch said: main');
  const no = fake({ 'GET /api/v1/repos/devos/kept-app': [200, { default_branch: 'main' }], 'POST /api/v1/repos/devos/kept-app/branch_protections': [403, { message: 'not an admin' }] });
  await assert.rejects(makeMirrors({ store: setup('protect3'), fetchImpl: no.fetchImpl, base: 'http://caddy:8099' }).protect('kept-app'), (e) => /not an admin/.test(e.message));
  // a default branch that is not a plain name (a glob, a bad character) is refused, and nothing is protected in its place
  for (const bad of ['a*', 'x y', '-lead', 'a[b]']) {
    const g = fake({ 'GET /api/v1/repos/devos/kept-app': [200, { default_branch: bad }] });
    await assert.rejects(makeMirrors({ store: setup('protect4' + bad.length + bad[0]), fetchImpl: g.fetchImpl, base: 'http://caddy:8099' }).protect('kept-app'), (e) => /not a plain branch name/.test(e.message), bad);
    assert.deepEqual(g.calls.map((c) => c.key), ['GET /api/v1/repos/devos/kept-app'], `${bad}: no rule was sent`);
  }
  assert.equal(await makeMirrors({ store: setup('protect5'), fetchImpl: fake({ 'GET /api/v1/repos/devos/kept-app': [200, { default_branch: '' }] }).fetchImpl, base: 'http://caddy:8099' }).defaultBranch('kept-app'), null);
  await assert.rejects(m.protect('../x'), (e) => e.status === 400);
});

// --- JON-970: the Git hosts dialog names a connected host by id and a path; the token stays here ---
const hostId = (store, host) => store.list().find((h) => h.host === host).id;

test('resolve: a connected host\'s id and a path give the https address and the host name; never a token; refused for an unknown id, a sign-in, the built-in host, a bad path', () => {
  const store = setup('resolve');
  const m = makeMirrors({ store, fetchImpl: fake().fetchImpl });
  const gh = hostId(store, 'github.com');
  const r = m.resolve({ host: gh, path: 'octo/app' });
  assert.deepEqual(r, { host: 'github.com', label: 'GitHub', remote: 'https://github.com/octo/app.git' });
  assert.ok(!JSON.stringify(r).includes(GTOK));
  assert.equal(m.resolve({ host: gh, path: 'octo/app.git' }).remote, 'https://github.com/octo/app.git');
  const bad = (b, re) => assert.throws(() => m.resolve(b), re, JSON.stringify(b));
  bad({ host: 'h_000000000000', path: 'o/r' }, /not a connected git host/);
  bad({ host: store.read().hosts.find((h) => h.builtin).id, path: 'o/r' }, /built-in git server itself/);
  bad({ host: gh, path: '../x' }, /repository/);
  bad({ host: gh, path: 'o/r?x=1' }, /repository/);
  bad({ host: gh, path: 'o//r' }, /repository/);
  bad({ host: gh, path: '' }, /repository/);
  bad({ host: 'nope', path: 'o/r' }, /not a connected git host/);
  store.addOAuth({ kind: 'gitlab', host: 'gitlab.com', oauth: { source: 'signed-in', clientId: 'cid', accessToken: GTOK, refreshToken: `${GTOK}r`, account: 'g' } });
  bad({ host: hostId(store, 'gitlab.com'), path: 'g/r' }, /connected with a sign-in/);
});

test('add by host id and path: the same request to the git server as by address, the token only in it', async () => {
  const store = setup('addhost');
  const f = fake({ 'GET /api/v1/repos/devos/app': [200, { name: 'app' }], 'POST /api/v1/repos/devos/app/push_mirrors': [200, { remote_name: 'm9', remote_address: 'https://github.com/octo/app.git', interval: '1h0m0s', sync_on_commit: false }] });
  const m = makeMirrors({ store, fetchImpl: f.fetchImpl });
  const r = await m.add({ direction: 'push', repo: 'app', host: hostId(store, 'github.com'), path: 'octo/app', interval: '1h', syncOnCommit: false });
  const post = f.calls.find((c) => c.key.startsWith('POST'));
  assert.deepEqual(post.body, { remote_address: 'https://github.com/octo/app.git', remote_username: 'octo', remote_password: GTOK, interval: '1h0m0s', sync_on_commit: false });
  assert.ok(!JSON.stringify(r).includes(GTOK));
  // a host id with a URL as well: refused (one way to name the remote)
  await assert.rejects(m.add({ direction: 'push', repo: 'app', host: hostId(store, 'github.com'), path: 'o/r', remote: 'https://github.com/o/r' }), /one of/);
});

test('change: the new push mirror is made first, then the old one deleted; a refused new one leaves the old; the page can change the interval and on-every-push only', async () => {
  const store = setup('change');
  const old = { remote_name: 'm1', remote_address: 'https://github.com/octo/app.git', interval: '8h0m0s', sync_on_commit: true };
  const f = fake({ 'GET /api/v1/repos/devos/app/push_mirrors': [200, [old]], 'POST /api/v1/repos/devos/app/push_mirrors': [200, { ...old, remote_name: 'm2', interval: '2h0m0s', sync_on_commit: false }],
    'DELETE /api/v1/repos/devos/app/push_mirrors/m1': [204, null] });
  const m = makeMirrors({ store, fetchImpl: f.fetchImpl });
  const r = await m.change({ repo: 'app', name: 'm1', interval: '2h', syncOnCommit: false });
  assert.deepEqual(f.calls.map((c) => c.key), ['GET /api/v1/repos/devos/app/push_mirrors', 'POST /api/v1/repos/devos/app/push_mirrors', 'DELETE /api/v1/repos/devos/app/push_mirrors/m1']);
  const post = f.calls[1].body;
  assert.deepEqual([post.remote_address, post.remote_password, post.interval, post.sync_on_commit], ['https://github.com/octo/app.git', GTOK, '2h0m0s', false]);
  assert.deepEqual([r.name, r.interval, r.syncOnCommit], ['m2', '2h0m0s', false]);
  // omitted fields keep what the mirror has
  const g = fake({ 'GET /api/v1/repos/devos/app/push_mirrors': [200, [old]], 'POST /api/v1/repos/devos/app/push_mirrors': [200, old], 'DELETE /api/v1/repos/devos/app/push_mirrors/m1': [204, null] });
  await makeMirrors({ store, fetchImpl: g.fetchImpl }).change({ repo: 'app', name: 'm1' });
  assert.deepEqual([g.calls[1].body.interval, g.calls[1].body.sync_on_commit], ['8h0m0s', true]);
  // the server refuses the new one: the old is not deleted
  const h = fake({ 'GET /api/v1/repos/devos/app/push_mirrors': [200, [old]], 'POST /api/v1/repos/devos/app/push_mirrors': [403, { message: 'already exists' }] });
  await assert.rejects(makeMirrors({ store, fetchImpl: h.fetchImpl }).change({ repo: 'app', name: 'm1', interval: '3h' }), /the git server refused: already exists/);
  assert.ok(!h.calls.some((c) => c.key.startsWith('DELETE')));
  // no such mirror; a bad name; a bad interval; a remote that is no longer a connected host: nothing sent
  await assert.rejects(m.change({ repo: 'app', name: 'zz', interval: '2h' }), /no mirror zz/);
  await assert.rejects(m.change({ repo: 'app', name: '../x' }), /mirror's name/);
  await assert.rejects(m.change({ repo: 'app', name: 'm1', interval: '5m' }), /interval/);
  const gone = fake({ 'GET /api/v1/repos/devos/app/push_mirrors': [200, [{ ...old, remote_address: 'https://gitlab.com/g/r.git' }]] });
  await assert.rejects(makeMirrors({ store, fetchImpl: gone.fetchImpl }).change({ repo: 'app', name: 'm1', interval: '2h' }), /not a connected git host/);
  assert.deepEqual(gone.calls.map((c) => c.key), ['GET /api/v1/repos/devos/app/push_mirrors']);
});

test('no credential in any error: the server echoing a connected host\'s token (or the built-in one) is cut before it leaves', async () => {
  const store = setup('scrub');
  const echo = fake({ 'GET /api/v1/repos/devos/app': [200, {}], 'POST /api/v1/repos/devos/app/push_mirrors': [400, { message: `bad credentials ${GTOK} for https://octo:${GTOK}@github.com/o/r and ${LTOK}` }] });
  const m = makeMirrors({ store, fetchImpl: echo.fetchImpl });
  await assert.rejects(m.add({ direction: 'push', repo: 'app', host: hostId(store, 'github.com'), path: 'o/r' }), (e) => {
    assert.ok(!e.message.includes(GTOK) && !e.message.includes(LTOK), e.message);
    assert.match(e.message, /the git server refused: bad credentials/);
    return true;
  });
  const l = fake({ 'GET /api/v1/user/repos': [200, [{ name: 'app', owner: { login: 'devos' } }]], 'GET /api/v1/repos/devos/app/push_mirrors': [200, [{ remote_name: 'm1', remote_address: 'https://github.com/o/r.git', last_error: `push failed with ${GTOK}` }]] });
  const out = await makeMirrors({ store, fetchImpl: l.fetchImpl }).list();
  assert.ok(!JSON.stringify(out).includes(GTOK) && /push failed with/.test(out[0].lastError));
});

test('the script: resolve, add by host id, change; the answers never hold a token', async () => {
  const store = setup('script2');
  const old = { remote_name: 'm1', remote_address: 'https://github.com/octo/app.git', interval: '8h0m0s', sync_on_commit: true };
  const f = fake({ 'GET /api/v1/repos/devos/app/push_mirrors': [200, [old]], 'POST /api/v1/repos/devos/app/push_mirrors': [200, { ...old, remote_name: 'm2' }], 'DELETE /api/v1/repos/devos/app/push_mirrors/m1': [204, null] });
  const m = makeMirrors({ store, fetchImpl: f.fetchImpl });
  const gh = hostId(store, 'github.com');
  const r = await run(JSON.stringify({ op: 'resolve', host: gh, path: 'octo/app' }), m);
  assert.deepEqual(r, { host: 'github.com', label: 'GitHub', remote: 'https://github.com/octo/app.git' });
  const c = await run(JSON.stringify({ op: 'change', repo: 'app', name: 'm1', interval: '4h' }), m);
  assert.equal(c.mirror.name, 'm2');
  assert.ok(!JSON.stringify([r, c]).includes(GTOK));
});
