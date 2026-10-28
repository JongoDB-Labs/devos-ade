// tests/e2e/localgit/run.sh's mirroring client (a container on the stack's default network, where Caddy's internal :8099 site
// is): the code container's real mirror logic (mirrors.mjs, the Git hosts store with the built-in host and a connected remote
// host with an access token) against the real git server and a second Forgejo that plays GitHub (https, a CA of the run's own).
import fs from 'node:fs';
import path from 'node:path';
const R = '/repo';
const ROOT = fs.mkdtempSync('/tmp/lgm-');
process.env.BN_CODE_STATE = ROOT;
const { GitHosts } = await import(`${R}/code/server/githosts.mjs`);
const { makeMirrors } = await import(`${R}/code/server/mirrors.mjs`);
const store = new GitHosts({ dir: ROOT });
store.addLocalGit({ ca: process.env.E2E_GIT_CA, token: process.env.E2E_GIT_TOKEN, account: 'devos' });
store.add({ kind: 'other', host: 'remote-git', port: 3000, auth: 'token', username: 'rem', token: process.env.E2E_REMOTE_TOKEN, label: 'Remote', ca: process.env.E2E_REMOTE_CA });
store.add({ kind: 'other', host: 'example.com', auth: 'token', username: 'x', token: 'abcdefgh12345678', label: 'Example' });
const m = makeMirrors({ store, base: 'http://caddy:8099' });
let n = 0;
const ok = (c, msg) => { n++; if (!c) { console.log(`FAIL ${msg}`); process.exitCode = 1; } else console.log(`ok   ${msg}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fails = async (p, re) => { try { await p; return false; } catch (e) { return re.test(e.message) ? true : `wrong error: ${e.message}`; } };
const rem = async (method, p, body) => {
  const r = await fetch(`https://remote-git:3000/api/v1${p}`, { method, headers: { Authorization: `token ${process.env.E2E_REMOTE_TOKEN}`, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, json: await r.json().catch(() => null) };
};
// a push mirror of e2e-one (made by the git client stage) to the remote's empty repository
const made = await m.add({ direction: 'push', repo: 'e2e-one', remote: 'https://remote-git:3000/rem/copy', syncOnCommit: true });
ok(made.direction === 'push' && made.force === true && made.repo === 'devos/e2e-one', `push mirror made: ${JSON.stringify(made)}`);
ok(!JSON.stringify(made).includes(process.env.E2E_REMOTE_TOKEN), 'its view has no credential');
await m.sync({ repo: 'e2e-one' });
let branches = [];
for (let i = 0; i < 30 && !branches.includes('feature/x'); i++) { await sleep(2000); branches = ((await rem('GET', '/repos/rem/copy/branches')).json || []).map((b) => b.name); }
ok(branches.includes('main') && branches.includes('feature/x'), `the remote has the branches after the sync: ${branches}`);
let l = await m.list();
const pm = l.find((x) => x.direction === 'push');
ok(pm && pm.lastSync && !pm.lastError, `list: last sync ${pm && pm.lastSync}, no error`);
// a pull mirror of the remote's other repository
const seed = await rem('POST', '/user/repos', { name: 'src', auto_init: true, default_branch: 'main' });
ok(seed.status === 201, `the remote's src repository exists (${seed.status})`);
const pulled = await m.add({ direction: 'pull', repo: 'pulled', remote: 'https://remote-git:3000/rem/src', interval: '1h' });
ok(pulled.direction === 'pull' && pulled.force === false, `pull mirror made: ${JSON.stringify(pulled)}`);
await sleep(3000);
l = await m.list();
const pl = l.find((x) => x.direction === 'pull');
ok(pl && pl.repo === 'devos/pulled' && pl.interval === '1h0m0s', `list shows the pull mirror: ${JSON.stringify(pl)}`);
const readme = await fetch('http://caddy:8099/api/v1/repos/devos/pulled', { headers: { Authorization: `token ${process.env.E2E_GIT_TOKEN}` } }).then((r) => r.json());
ok(readme.mirror === true && readme.private === true, 'the pulled repository is a private mirror');
// the mirrors' hosts, for the way out
ok(JSON.stringify(await m.hosts()) === JSON.stringify(['remote-git']), `hosts: ${JSON.stringify(await m.hosts())}`);
// refused by the server: a host that is not among its allowed names (the way out was made for remote-git only)
const bad = await fails(m.add({ direction: 'push', repo: 'e2e-one', remote: 'https://example.com/o/r' }), /the git server refused/);
ok(bad === true, `a host the way out was not made for is refused by the server: ${bad}`);
// what the internal site does not pass
const p = (method, u, body) => fetch(`http://caddy:8099${u}`, { method, headers: { Authorization: `token ${process.env.E2E_GIT_TOKEN}` }, body }).then((r) => r.status);
ok(await p('DELETE', '/api/v1/repos/devos/e2e-one') === 404, 'deleting a repository is not passed (404)');
ok(await p('GET', '/api/v1/admin/users') === 404, 'the admin API is not passed (404)');
ok(await p('GET', '/api/v1/user') === 404, 'the account API is not passed (404)');
ok(await p('GET', '/devos/e2e-one') === 404, 'the web UI is not on it (404)');
// removing the push mirror
const name = pm.name;
await m.remove({ repo: 'e2e-one', name });
ok(!(await m.list()).some((x) => x.direction === 'push'), 'the push mirror is removed');
console.log(`${n} checks`);
