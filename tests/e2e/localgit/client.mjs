// tests/e2e/localgit/run.sh's client: it runs in a container on the sandbox's internal "terminal" network only (no internet,
// a dead egress proxy in its environment): bn-coded's real git operations and the code container's real remote logic
// (makeGitRemote and the Git hosts store, the host handed over as ./stack hands it) against the built-in git server, through
// the terminal gateway's TLS listener. /repo is the checkout (read-only); the run's certificate and token come in the environment.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { spawnSync, execFileSync } from 'node:child_process';
const R = '/repo';
const ROOT = fs.mkdtempSync('/tmp/lgc-');
const WS = path.join(ROOT, 'ws'), HOME = path.join(ROOT, 'home'), STATE = path.join(ROOT, 'state');
for (const d of [WS, HOME, STATE]) fs.mkdirSync(d);
Object.assign(process.env, { BN_CODE_WORKSPACE: WS, BN_CODE_SOCK_DIR: path.join(ROOT, 'sock'), BN_CODE_CHILDREN: path.join(ROOT, 'children'), HOME,
  BN_GIT_CREDENTIAL: `${R}/terminal/bin/bn-git-credential`, BN_GIT_TMP: path.join(ROOT, 'g'), BN_CODE_STATE: STATE });
// a proxy that would fail every request: proves the local server is never sent through the egress proxy
process.env.HTTPS_PROXY = 'http://127.0.0.1:9'; process.env.TERMINAL_EGRESS = 'off';
const coded = await import(`${R}/terminal/bin/bn-coded.mjs`);
const { FrameParser, frame, T } = await import(`${R}/code/server/frames.mjs`);
const { GitHosts } = await import(`${R}/code/server/githosts.mjs`);
const { makeGitRemote } = await import(`${R}/code/server/gitremote.mjs`);
const server = coded.start();
await new Promise((r) => (server.listening ? r() : server.once('listening', r)));
const SOCK = path.join(ROOT, 'sock', 'coded.sock');
function op(req, onAsk = async () => ({}), { timeoutMs = 120000 } = {}) {
  return new Promise((resolve, reject) => {
    const c = net.connect(SOCK), parser = new FrameParser(64 << 20), frames = [];
    const timer = setTimeout(() => { c.destroy(); reject(new Error('no answer')); }, timeoutMs);
    c.on('connect', () => c.write(frame(T.OPEN, req)));
    c.on('error', () => {});
    c.on('data', (d) => { for (const [t, p] of parser.push(d)) { frames.push([t, p]);
      if (t === T.ASK) { const q = JSON.parse(p.toString('utf8')); Promise.resolve(onAsk(q)).then((a) => { if (!c.destroyed) c.write(frame(T.ANSWER, { ...(a || {}), id: q.id })); }); } } });
    c.on('close', () => { clearTimeout(timer); const r = frames.find(([t]) => t === T.RESULT || t === T.ERROR);
      const v = r ? JSON.parse(r[1].toString('utf8')) : { none: true }; resolve({ result: r && r[0] === T.ERROR ? { error: v.error } : v, frames }); });
  });
}
let n = 0;
const ok = (c, m) => { n++; if (!c) { console.log(`FAIL ${m}`); process.exitCode = 1; } else console.log(`ok   ${m}`); };
// 1. the host, as ./stack hands it over (import-host.mjs, source localgit)
const ca = process.env.E2E_GIT_CA, token = process.env.E2E_GIT_TOKEN;   // (a throwaway token of this run, and the gateway's certificate)
const imp = spawnSync(process.execPath, [`${R}/code/server/import-host.mjs`], { input: JSON.stringify({ source: 'localgit', ca, account: 'devos', token }), encoding: 'utf8' });
ok(imp.status === 0 && JSON.parse(imp.stdout).host.created === true, `host registered: ${imp.stdout.trim()}`);
const store = new GitHosts({ dir: STATE });
const remote = makeGitRemote({ call: (req, opts = {}) => op(req, opts.onAsk, { timeoutMs: opts.timeoutMs }), store, webOrigin: process.env.E2E_GIT_WEB });
const URL = 'https://gateway:8093/devos/e2e-one.git';
const git = (cwd, ...a) => execFileSync('git', ['-c', 'user.email=t@x.invalid', '-c', 'user.name=t', '-c', 'commit.gpgSign=false', ...a], { cwd, stdio: ['ignore', 'pipe', 'pipe'] }).toString();
// 2. a local repository in the sandbox's workspace, its remote the local server; publish (push-create) from the panel
const A = path.join(WS, 'a'); fs.mkdirSync(A); git(A, 'init', '-q', '-b', 'main');
fs.writeFileSync(path.join(A, 'README.md'), '# e2e\n'); git(A, 'add', '.'); git(A, 'commit', '-qm', 'first');
git(A, 'remote', 'add', 'origin', URL);
let pl = await remote.plan({ repo: 'a', action: 'publish' });
ok(pl.host && pl.host.label === 'Local git server' && /HTTPS token 'Local git server'/.test(pl.summary), `plan: ${pl.summary}`);
let r = await remote.run({ planId: pl.planId });
ok(r.ok === true && r.created === true, `publish main to the local server: ${JSON.stringify(r)}`);
// 3. clone it into a second folder (a "second session"), commit, push a branch, open-a-PR link
let cp = await remote.clonePlan({ url: URL, target: 'b' });
r = await remote.run({ planId: cp.planId });
ok(r.ok === true && fs.existsSync(path.join(WS, 'b', 'README.md')), `clone into b/: ${JSON.stringify(r)}`);
const B = path.join(WS, 'b');
git(B, 'checkout', '-qb', 'feature/x'); fs.writeFileSync(path.join(B, 'f.txt'), 'x\n'); git(B, 'add', '.'); git(B, 'commit', '-qm', 'feature');
pl = await remote.plan({ repo: 'b', action: 'publish' }); r = await remote.run({ planId: pl.planId });
ok(r.ok === true && r.prLink === `${process.env.E2E_GIT_WEB}/devos/e2e-one/compare/feature/x`, `publish feature/x: prLink ${r.prLink}`);
// 4. main moves on in b, pushed; a fast-forward pull in a
git(B, 'checkout', '-q', 'main'); fs.writeFileSync(path.join(B, 'g.txt'), 'g\n'); git(B, 'add', '.'); git(B, 'commit', '-qm', 'second on main');
pl = await remote.plan({ repo: 'b', action: 'push' }); r = await remote.run({ planId: pl.planId });
ok(r.ok === true, `push main from b: ${JSON.stringify(r)}`);
pl = await remote.plan({ repo: 'a', action: 'fetch' }); r = await remote.run({ planId: pl.planId });
ok(r.ok === true, 'fetch in a');
pl = await remote.plan({ repo: 'a', action: 'pull' }); r = await remote.run({ planId: pl.planId });
ok(r.ok === true && r.updated === true && fs.existsSync(path.join(A, 'g.txt')), `ff pull in a: ${JSON.stringify(r)}`);
// 5. the token is in no clone's config and the events say what happened, never the token
ok(!fs.readFileSync(path.join(A, '.git/config'), 'utf8').includes(token) && !fs.readFileSync(path.join(B, '.git/config'), 'utf8').includes(token), 'the token is in no .git/config');
ok(!JSON.stringify(store.events(50)).includes(token) && !JSON.stringify(store.list()).includes(token), 'the token is in no event or host view');
// 6. a wrong token is refused (the credential question answered with another)
const bad = await op({ op: 'git.net', repo: 'a', action: 'fetch', remote: 'origin', url: URL, auth: { kind: 'token', ca } }, async () => ({ username: 'devos', password: `${token}x` }));
ok(bad.result && bad.result.ok !== true, `a wrong token is refused: ${JSON.stringify(bad.result).slice(0, 160)}`);
// 7. the gateway lets only git through, and the sandbox's network has nothing else
const sh = (c) => spawnSync('sh', ['-c', c], { encoding: 'utf8' }).stdout.trim();
fs.writeFileSync('/tmp/gw.crt', ca);
const code = (u, x = '') => sh(`curl -s -m 8 -o /dev/null -w '%{http_code}' --noproxy '*' --cacert /tmp/gw.crt ${x} ${u}`);
ok(code('https://gateway:8093/') === '404', 'the web UI is not on the gateway (404)');
ok(code('https://gateway:8093/api/v1/version') === '404', 'the API is not on the gateway (404)');
ok(code('https://gateway:8093/devos/e2e-one.git/info/refs?service=git-upload-pack') === '401', 'git without a credential: 401 (private)');
ok(code('https://gateway:8093/devos/e2e-one/raw/branch/main/README.md', `-u devos:${token}`) === '404', 'raw file paths are not git: 404');
ok(sh("curl -s -m 5 -o /dev/null -w '%{http_code}' --noproxy '*' http://forgejo:3000/ ; true") === '000', 'forgejo itself does not resolve from the sandbox network');
ok(sh("curl -s -m 5 -o /dev/null -w '%{http_code}' --noproxy '*' https://1.1.1.1/ ; true") === '000', 'no internet from the sandbox network');
ok(sh("curl -s -m 5 -o /dev/null -w '%{http_code}' --noproxy '*' https://github.com/ ; true") === '000', 'no github.com from the sandbox network');
console.log(`${n} checks`);
server.close();
process.exit(process.exitCode || 0);
