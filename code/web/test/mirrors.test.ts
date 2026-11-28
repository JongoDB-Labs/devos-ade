// JON-970: the Git hosts dialog's mirrors (api.ts): requests go to the portal (POST /.bn/sessions) with the web app password and a
// connected host by its id and a path — never an address or a token; the answers are checked; a request's note is cut text.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mirrorAdd, mirrorSync, mirrorChange, mirrorRemove, importRequestState, normGitMirror } from '../src/api';

const sent: { url: string; method: string; body: unknown }[] = [];
function answer(body: unknown, status = 202) {
  (globalThis as unknown as { fetch: unknown }).fetch = async (url: string, init: RequestInit) => {
    sent.push({ url, method: init.method ?? 'GET', body: init.body ? JSON.parse(String(init.body)) : undefined });
    return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  };
}
const N = 'a'.repeat(32);
const H = 'h_0123456789ab';

test('every mirror request goes to the portal with the password; fixed fields; the repository is the name on the built-in server', async () => {
  answer({ request: N });
  assert.equal(await mirrorAdd({ direction: 'push', repo: 'app', host: H, path: 'me/app', interval: '2h', syncOnCommit: false }, 'pw'), N);
  assert.equal(await mirrorAdd({ direction: 'pull', repo: 'up', host: H, path: 'g/up', interval: '', syncOnCommit: true }, 'pw'), N);
  await mirrorSync('devos/app', 'push', 'pw');
  await mirrorSync('devos/up', 'pull', 'pw');
  await mirrorChange('devos/app', 'm1', { interval: '30m' }, 'pw');
  await mirrorChange('devos/app', 'm1', { syncOnCommit: true }, 'pw');
  await mirrorRemove('devos/app', 'm1', 'pw');
  assert.deepEqual(sent.map((x) => [x.url, x.method]), Array(7).fill(['/.bn/sessions', 'POST']));
  assert.deepEqual(sent.map((x) => x.body), [
    { action: 'git-mirror-add', direction: 'push', repo: 'app', host: H, path: 'me/app', interval: '2h', sync: 'no', password: 'pw' },
    { action: 'git-mirror-add', direction: 'pull', repo: 'up', host: H, path: 'g/up', password: 'pw' },
    { action: 'git-mirror-sync', direction: 'push', repo: 'app', password: 'pw' },
    { action: 'git-mirror-sync', direction: 'pull', repo: 'up', password: 'pw' },
    { action: 'git-mirror-change', repo: 'app', name: 'm1', interval: '30m', password: 'pw' },
    { action: 'git-mirror-change', repo: 'app', name: 'm1', sync: 'yes', password: 'pw' },
    { action: 'git-mirror-remove', repo: 'app', name: 'm1', password: 'pw' },
  ]);
});

test('what is not a host id, a repository path, an interval or a name is refused before anything is sent; no token or address field exists', async () => {
  sent.length = 0;
  answer({ request: N });
  const ok = { direction: 'push' as const, repo: 'app', host: H, path: 'me/app', interval: '', syncOnCommit: true };
  for (const bad of [{ host: 'github.com' }, { path: 'https://github.com/me/app' }, { path: '../x' }, { path: 'me/app --x' }, { repo: '../x' }, { repo: 'a/b' }, { interval: '5x' }, { interval: '1000h' }, { direction: 'both' }]) {
    await assert.rejects(mirrorAdd({ ...ok, ...bad } as never, 'pw'), /bad request|mirror|interval/, JSON.stringify(bad));
  }
  await assert.rejects(mirrorChange('devos/app', '../x', { interval: '2h' }, 'pw'), /bad request/);
  await assert.rejects(mirrorChange('devos/app', 'm1', {}, 'pw'), /nothing to change/);
  await assert.rejects(mirrorRemove('devos/app', 'm 1', 'pw'), /bad request/);
  await assert.rejects(mirrorSync('app', 'push', 'pw'), /bad request/);
  assert.equal(sent.length, 0);
  assert.ok(!JSON.stringify(Object.keys(ok)).includes('token'));
});

test('a mirror carries its name (push only), and a request keeps a note: one cut line of text', async () => {
  const ok = { direction: 'push', repo: 'devos/app', name: 'remote_mirror_ab12', remote: 'https://github.com/o/app.git', interval: '8h0m0s', syncOnCommit: true, lastSync: null, lastError: null };
  assert.equal(normGitMirror(ok)!.name, 'remote_mirror_ab12');
  assert.equal(normGitMirror({ ...ok, name: '../x' })!.name, null);
  assert.equal(normGitMirror({ ...ok, direction: 'pull', name: null })!.name, null);
  answer({ id: N, state: 'failed', why: 'mirror', note: 'the git server refused: no\nway <b>x</b>' }, 200);
  const r = await importRequestState(N);
  assert.deepEqual([r?.state, r?.why], ['failed', 'mirror']);
  assert.equal((r as unknown as { note: string }).note, 'the git server refused: no way <b>x</b>');
});
