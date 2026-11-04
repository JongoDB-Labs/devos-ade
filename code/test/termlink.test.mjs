// The terminal's `project` command (JON-1059): terminal/bin/project -> the link socket bn-coded keeps (project.link) -> the code
// container's answer (termlink.mjs). The real command and the real socket, with a stand-in code container; the answer's own rules
// (a folder that is a project already, the switch that gates keeping) on fakes of the project records. Also the credential
// helper's line for the built-in git server, and the sandbox's git config for gateway:8093.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { tmp, TERMINAL_DIR } from './helpers.mjs';
import { makeProjectAnswer, makeTermLink, mayKeep } from '../server/termlink.mjs';

const ROOT = tmp('tlink');
const WS = path.join(ROOT, 'ws'), LINK = path.join(ROOT, 'link');
fs.mkdirSync(path.join(WS, 'app/sub'), { recursive: true });
fs.mkdirSync(path.join(WS, '.hidden'));
fs.mkdirSync(path.join(WS, 'plain'));
fs.symlinkSync(path.join(WS, 'app'), path.join(WS, 'viaLink'));
Object.assign(process.env, { BN_CODE_WORKSPACE: WS, BN_PROJECT_TMP: LINK, BN_CODE_SOCK_DIR: path.join(ROOT, 'sock'), BN_CODE_CHILDREN: path.join(ROOT, 'children') });
const coded = await import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));
const CLI = path.join(TERMINAL_DIR, 'bin/project');
const HELPER = path.join(TERMINAL_DIR, 'bin/bn-git-credential');
const ENV = { PATH: process.env.PATH, HOME: ROOT, BN_CODE_WORKSPACE: WS, BN_PROJECT_TMP: LINK, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };

// run(file, args, {cwd, input, env}) -> {code, out, err}: asynchronously (this process answers the socket the command asks)
const run = (file, args, { cwd = ROOT, input = '', env = ENV } = {}) => new Promise((res) => {
  const p = spawn(process.execPath, [file, ...args], { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
  let out = '', err = '';
  p.stdout.on('data', (d) => (out += d)); p.stderr.on('data', (d) => (err += d));
  p.on('close', (code) => res({ code, out, err }));
  p.stdin.end(input);
});

test('linkRequest: only a real folder of the workspace, short plain fields, three operations', () => {
  const ok = coded.linkRequest({ op: 'add', folder: `${WS}/app`, name: 'My app' });
  assert.deepEqual(ok, { kind: 'project', op: 'add', folder: 'app', name: 'My app' });
  assert.deepEqual(coded.linkRequest({ op: 'keep', folder: `${WS}/app/sub`, repo: 'my-app' }), { kind: 'project', op: 'keep', folder: 'app/sub', repo: 'my-app' });
  assert.deepEqual(coded.linkRequest({ op: 'info' }), { kind: 'project', op: 'info' });
  for (const bad of [
    { op: 'delete', folder: `${WS}/app` }, { op: 'add' }, { op: 'add', folder: '/etc' }, { op: 'add', folder: `${WS}/../etc` }, { op: 'add', folder: WS },
    { op: 'add', folder: `${WS}/.hidden` }, { op: 'add', folder: `${WS}/viaLink` }, { op: 'add', folder: `${WS}/missing` },
    { op: 'add', folder: `${WS}/app`, name: 'two\nlines' }, { op: 'add', folder: `${WS}/app`, name: 'x'.repeat(81) },
    { op: 'keep', folder: `${WS}/app`, repo: '../x' }, { op: 'keep', folder: `${WS}/app`, repo: 'a b' }, null, 'add',
  ]) assert.ok(coded.linkRequest(bad).error, `refused: ${JSON.stringify(bad)}`);
});

test('linkAnswer: known fields only, text as short plain lines', () => {
  const a = coded.linkAnswer({ ok: true, name: 'a‮b\nc', error: 'x'.repeat(900), surprise: 'no', kept: 'yes', repo: 'devos/a' });
  assert.deepEqual(Object.keys(a).sort(), ['error', 'name', 'ok', 'repo']);
  assert.equal(a.name, 'a?b?c');
  assert.equal(a.error.length, 400);
});

// a stand-in code container behind the real link socket: the questions it was asked, and what it answers
async function withLink(answer, fn) {
  const asked = [];
  coded.linkStart(async (q) => { asked.push(q); return answer(q); }, { dir: LINK });
  for (let i = 0; i < 50 && !fs.existsSync(path.join(LINK, 'link.sock')); i++) await new Promise((r) => setTimeout(r, 20));
  try { return await fn(asked); } finally { coded.linkStop(); }
}

test('project add / new / remote through the link socket', async () => {
  const repo = path.join(WS, 'app');
  execFileSync('git', ['init', '--quiet', '--initial-branch=main'], { cwd: repo, env: ENV });
  const answers = (q) => (q.op === 'info' ? { ok: true, available: true, mayKeep: false, owner: 'devos', url: 'https://gateway:8093/devos/' }
    : q.op === 'keep' ? { ok: true, id: 'p_00000001', name: 'app', kept: false, note: 'no login' } : { ok: true, id: 'p_00000001', name: q.name || q.folder, existing: false });
  await withLink(answers, async (asked) => {
    let r = await run(CLI, ['add', '--name', 'My app'], { cwd: repo });
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /Added as a project: My app/);
    assert.deepEqual(asked.at(-1), { kind: 'project', op: 'add', folder: 'app', name: 'My app' });
    r = await run(CLI, ['add', '--keep', '--repo', 'my-app'], { cwd: repo });
    assert.match(r.out, /Not kept on the local git server: no login/);
    assert.deepEqual(asked.at(-1), { kind: 'project', op: 'keep', folder: 'app', repo: 'my-app' });
    // a folder that is not a repository cannot be kept (said before anything is asked)
    const n = asked.length;
    r = await run(CLI, ['add', '--keep', 'plain'], { cwd: WS });
    assert.equal(r.code, 1);
    assert.match(r.err, /not a git repository yet/);
    assert.equal(asked.length, n);
    // outside the workspace, and the workspace itself
    assert.match((await run(CLI, ['add', '/etc'])).err, /not under/);
    assert.match((await run(CLI, ['add', WS])).err, /Workspace project already/);
    // new: the folder, git init on main, then add
    r = await run(CLI, ['new', 'fresh']);
    assert.equal(r.code, 0, r.err);
    assert.ok(fs.existsSync(path.join(WS, 'fresh/.git')));
    assert.equal(execFileSync('git', ['symbolic-ref', '--short', 'HEAD'], { cwd: path.join(WS, 'fresh'), env: ENV }).toString().trim(), 'main');
    assert.deepEqual(asked.at(-1), { kind: 'project', op: 'add', folder: 'fresh' });
    assert.match((await run(CLI, ['new', '../x'])).err, /folder name/);
    // remote: git remote add local, once; the same again says so; another address is not overwritten
    r = await run(CLI, ['remote', 'my-app'], { cwd: repo });
    assert.match(r.out, /Added the remote "local": https:\/\/gateway:8093\/devos\/my-app\.git/);
    assert.match(r.out, /git push -u local main/);
    assert.match(r.out, /Let Claude use this host/);
    assert.equal(execFileSync('git', ['remote', 'get-url', 'local'], { cwd: repo, env: ENV }).toString().trim(), 'https://gateway:8093/devos/my-app.git');
    assert.match((await run(CLI, ['remote', 'my-app'], { cwd: repo })).out, /The remote "local" is/);
    r = await run(CLI, ['remote', 'other'], { cwd: repo });
    assert.equal(r.code, 1);
    assert.match(r.err, /"local" is https:\/\/gateway:8093\/devos\/my-app\.git already/);
    assert.equal((await run(CLI, ['remote'], { cwd: ROOT })).code, 1, 'not in a repository');
  });
});

test('the command says so when the Code page is not connected, and refuses what the Code page refused', async () => {
  let r = await run(CLI, ['add', 'app'], { cwd: WS });
  assert.equal(r.code, 1);
  assert.match(r.err, /not connected to this terminal/);
  await withLink(() => ({ error: 'that folder is the project X already' }), async () => {
    r = await run(CLI, ['add', 'app'], { cwd: WS });
    assert.equal(r.code, 1);
    assert.match(r.err, /project: that folder is the project X already/);
  });
});

test('the link answers at most LINK_PER_MINUTE questions a minute', async () => {
  await withLink(() => ({ ok: true, name: 'a', id: 'p_00000001' }), async () => {
    const sock = path.join(LINK, 'link.sock');
    const net = await import('node:net');
    const one = () => new Promise((res) => {
      let b = '';
      const c = net.connect(sock);
      c.on('data', (d) => (b += d)); c.on('close', () => res(JSON.parse(b)));
      c.write('{"op":"info"}\n');
    });
    let last = null;
    for (let i = 0; i < coded.LINK_PER_MINUTE + 2; i++) last = await one();
    assert.match(last.error, /more than 20 requests a minute/);
  });
});

// --- the code container's answer ---
const fakes = ({ owner = 'devos', claude = false, projects = [], keepFail = null, isGit = true } = {}) => {
  const list = [...projects];
  const calls = { add: [], keep: [] };
  const answer = makeProjectAnswer({
    addProject: async (b) => { calls.add.push(b); const p = { id: `p_0000000${list.length + 1}`, name: b.name || b.folder.split('/').pop(), root: b.folder }; list.push(p); return { project: p, git: isGit }; },
    projects: () => ({ list: () => list }),
    keeper: () => ({ keep: async (id, b) => { calls.keep.push([id, b]); if (keepFail) throw new Error(keepFail); return { repo: `${owner}/${b.name || 'x'}` }; }, view: async () => ({ repo: 'devos/known' }) }),
    mirrors: { owner: () => owner },
    hosts: () => [{ builtin: 'localgit', claude }, { builtin: null, claude: true }],
  });
  return { answer, calls, list };
};

test('answer: info, add (idempotent), and keeping only while the sandbox\'s git may use the server', async () => {
  let f = fakes();
  assert.deepEqual(await f.answer({ kind: 'project', op: 'info' }), { ok: true, available: true, mayKeep: false, owner: 'devos', url: 'https://gateway:8093/devos/' });
  assert.equal((await fakes({ owner: null }).answer({ kind: 'project', op: 'info' })).available, false);
  let a = await f.answer({ kind: 'project', op: 'add', folder: 'app', name: 'App' });
  assert.deepEqual([a.ok, a.name, a.existing, a.git], [true, 'App', false, true]);
  a = await f.answer({ kind: 'project', op: 'add', folder: 'app' });
  assert.deepEqual([a.ok, a.existing], [true, true]);
  assert.equal(f.calls.add.length, 1, 'a project already: not added twice');
  // keep without the switch: the project is added, the answer says what to do, nothing is pushed
  a = await f.answer({ kind: 'project', op: 'keep', folder: 'other' });
  assert.deepEqual([a.ok, a.kept], [true, false]);
  assert.match(a.note, /Let Claude use this host/);
  assert.equal(f.calls.keep.length, 0);
  // with it: kept, under the name asked
  f = fakes({ claude: true });
  a = await f.answer({ kind: 'project', op: 'keep', folder: 'app', repo: 'my-app' });
  assert.deepEqual([a.ok, a.kept, a.repo], [true, true, 'devos/my-app']);
  assert.deepEqual(f.calls.keep[0][1], { name: 'my-app' });
  // a refusal of the keeping: the project stays added, and the reason is told
  f = fakes({ claude: true, keepFail: 'devos/app is on the git server already, so pick another name' });
  a = await f.answer({ kind: 'project', op: 'keep', folder: 'app' });
  assert.match(a.error, /pick another name/);
  assert.match(a.note, /added, not kept/);
  assert.equal(f.list.length, 1);
  // already kept: the same answer as kept
  f = fakes({ claude: true, keepFail: 'devos/known keeps this project already' });
  a = await f.answer({ kind: 'project', op: 'keep', folder: 'app' });
  assert.deepEqual([a.ok, a.kept, a.repo], [true, true, 'devos/known']);
  // the server not connected, unknown requests, a refusal of the page's own rules
  assert.match((await fakes({ owner: null }).answer({ kind: 'project', op: 'keep', folder: 'app' })).error, /not connected/);
  assert.equal((await f.answer({ kind: 'project', op: 'nope', folder: 'app' })).error, 'unknown request');
  assert.deepEqual(await f.answer({ kind: 'cred' }), {});
  const bad = makeProjectAnswer({ addProject: async () => { throw Object.assign(new Error('at most 64 projects: remove one first'), { status: 409 }); }, projects: () => ({ list: () => [] }),
    keeper: () => ({}), mirrors: { owner: () => 'devos' }, hosts: () => [] });
  assert.match((await bad({ kind: 'project', op: 'add', folder: 'x' })).error, /at most 64 projects/);
  assert.equal(mayKeep([{ builtin: 'localgit', claude: true }]), true);
  assert.equal(mayKeep([{ builtin: null, claude: true }, { builtin: 'localgit' }]), false);
});

test('the link is opened again after the sandbox restarts, and a sandbox without the op is looked at slowly', async () => {
  const opened = [];
  let closeFirst;
  const open = async ({ op }) => {
    opened.push(op);
    if (opened.length === 1) return { close() {}, closed: new Promise((r) => { closeFirst = r; }) };
    if (opened.length === 2) throw new Error('refused: unknown op');
    return { close() {}, closed: new Promise(() => {}) };
  };
  const link = makeTermLink({ open, answer: async () => ({}), retryMs: 10, slowMs: 20 });
  await link.start();
  closeFirst();
  for (let i = 0; i < 100 && opened.length < 3; i++) await new Promise((r) => setTimeout(r, 10));
  link.close();
  assert.deepEqual(opened, ['project.link', 'project.link', 'project.link']);
});

// --- the sandbox's git for the built-in server ---
test('bn-git-credential says which switch gives git a login for the local git server, and only for that host', async () => {
  const q = (host) => `protocol=https\nhost=${host}\n\n`;
  let r = await run(HELPER, ['get'], { input: q('gateway:8093'), env: { ...ENV, BN_GIT_TMP: path.join(ROOT, 'none') } });
  assert.equal(r.code, 0);
  assert.match(r.err, /no login for the local git server/);
  assert.match(r.err, /Let Claude use this host/);
  assert.equal(r.out, '');
  r = await run(HELPER, ['get'], { input: q('github.com'), env: { ...ENV, BN_GIT_TMP: path.join(ROOT, 'none') } });
  assert.deepEqual([r.code, r.err, r.out], [0, '', '']);
});

test('the image\'s git config trusts the server\'s certificate for gateway:8093 alone', () => {
  const cfg = path.join(TERMINAL_DIR, 'gitconfig');
  const env = { PATH: process.env.PATH, HOME: ROOT, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: cfg };
  const get = (url) => { try { return execFileSync('git', ['config', '--get-urlmatch', 'http.sslCAInfo', url], { env }).toString().trim(); } catch { return ''; } };
  assert.equal(get('https://gateway:8093/devos/app.git'), '/etc/bn-localgit-ca/tls.crt');
  for (const other of ['https://gateway:8091/x.git', 'https://gateway/x.git', 'https://github.com/o/r.git', 'https://gateway:8094/x.git', 'https://evil.example:8093/x.git']) assert.equal(get(other), '', other);
  // no setting for every host (that would trust the certificate for others)
  const all = execFileSync('git', ['config', '--list'], { env }).toString();
  assert.doesNotMatch(all, /^http\.sslcainfo=/m);
  assert.doesNotMatch(all, /sslverify/i);
});
