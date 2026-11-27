// bn-coded's git.heads (JON-1430): the branch checked out and its commit, for up to 100 repositories, read from the files under
// each repository's .git — no git process, no link followed. Real temporary repositories: a loose ref, a packed ref, no commit
// yet, a detached HEAD, a .git that is a link or a file leading out, a worktree, a folder outside the workspace, too many
// repositories, and an answer that holds nothing but repo, branch, head and error.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { tmp, talk, open, result, TERMINAL_DIR } from './helpers.mjs';

const ROOT = tmp('bnheads');
const WS = path.join(ROOT, 'ws'), HOME = path.join(ROOT, 'home'), SOCKDIR = path.join(ROOT, 'sock'), OUT = path.join(ROOT, 'outside');
for (const d of [WS, HOME, OUT]) fs.mkdirSync(d, { recursive: true });
Object.assign(process.env, { BN_CODE_WORKSPACE: WS, BN_CODE_SOCK_DIR: SOCKDIR, BN_CODE_CHILDREN: path.join(ROOT, 'children'), HOME, CLAUDE_CONFIG_DIR: path.join(HOME, '.claude'),
  BN_CODE_ROOTS: JSON.stringify([WS]) });
const coded = await import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));
const GIT = ['/usr/bin', '/usr/local/bin', '/bin', '/opt/homebrew/bin'].map((d) => path.join(d, 'git')).find((f) => fs.existsSync(f));
let server;
const SOCK = path.join(SOCKDIR, 'coded.sock');
before(async () => { server = coded.start(); await new Promise((r) => (server.listening ? r() : server.once('listening', r))); });
after(() => { server.close(); fs.rmSync(ROOT, { recursive: true, force: true }); });
const call = async (req) => result(await talk(SOCK, [open(req)]));
const ENV = { PATH: process.env.PATH, HOME, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_AUTHOR_NAME: 'T', GIT_AUTHOR_EMAIL: 't@example.invalid', GIT_COMMITTER_NAME: 'T', GIT_COMMITTER_EMAIL: 't@example.invalid' };
const git = (cwd, ...a) => execFileSync(GIT, a, { cwd, env: ENV }).toString().trim();
const repo = (name, { commit = true } = {}) => {
  const d = path.join(WS, name);
  fs.mkdirSync(d, { recursive: true });
  git(d, 'init', '-q', '--initial-branch=main');
  if (commit) { fs.writeFileSync(path.join(d, 'a.txt'), 'a'); git(d, 'add', 'a.txt'); git(d, 'commit', '-q', '-m', 'one'); }
  return d;
};
const heads = async (repos) => (await call({ op: 'git.heads', repos })).heads;

test('a loose ref: the branch and its commit, read without git, in the order asked', async () => {
  const d = repo('loose');
  const d2 = repo('loose2');
  const sha = git(d, 'rev-parse', 'HEAD'), sha2 = git(d2, 'rev-parse', 'HEAD');
  assert.ok(fs.existsSync(path.join(d, '.git/refs/heads/main')), 'the commit is a loose ref');
  assert.deepEqual(await heads(['loose2', 'loose']), [{ repo: 'loose2', branch: 'main', head: sha2 }, { repo: 'loose', branch: 'main', head: sha }]);
});

test('a branch with a slash in its name, and a packed ref', async () => {
  const d = repo('packed');
  git(d, 'checkout', '-q', '-b', 'feat/x');
  const sha = git(d, 'rev-parse', 'HEAD');
  assert.deepEqual(await heads(['packed']), [{ repo: 'packed', branch: 'feat/x', head: sha }]);
  git(d, 'pack-refs', '--all');
  assert.ok(!fs.existsSync(path.join(d, '.git/refs/heads/feat/x')), 'packed: no loose file');
  assert.deepEqual(await heads(['packed']), [{ repo: 'packed', branch: 'feat/x', head: sha }]);
  // a new commit is a loose ref again, and it wins over the packed one
  fs.writeFileSync(path.join(d, 'b.txt'), 'b'); git(d, 'add', 'b.txt'); git(d, 'commit', '-q', '-m', 'two');
  assert.deepEqual(await heads(['packed']), [{ repo: 'packed', branch: 'feat/x', head: git(d, 'rev-parse', 'HEAD') }]);
});

test('no commit yet: the branch, head null; a detached HEAD: branch null, head null', async () => {
  repo('empty', { commit: false });
  assert.deepEqual(await heads(['empty']), [{ repo: 'empty', branch: 'main', head: null }]);
  const d = repo('detached');
  git(d, 'checkout', '-q', '--detach');
  assert.deepEqual(await heads(['detached']), [{ repo: 'detached', branch: null, head: null }]);
});

test('.git a link is not followed (an error), and a .git file leading outside the root is an error', async () => {
  const real = repo('real-for-link');
  fs.mkdirSync(path.join(WS, 'linked'));
  fs.symlinkSync(path.join(real, '.git'), path.join(WS, 'linked/.git'));
  const out = path.join(OUT, 'other');
  fs.mkdirSync(out);
  git(out, 'init', '-q', '--initial-branch=main');
  fs.mkdirSync(path.join(WS, 'pointing'));
  fs.writeFileSync(path.join(WS, 'pointing/.git'), `gitdir: ${path.join(out, '.git')}\n`);
  fs.mkdirSync(path.join(WS, 'dotdot'));
  fs.writeFileSync(path.join(WS, 'dotdot/.git'), 'gitdir: ../../outside/other/.git\n');
  const r = await heads(['linked', 'pointing', 'dotdot']);
  assert.deepEqual(r.map((x) => Object.keys(x).sort()), [['error', 'repo'], ['error', 'repo'], ['error', 'repo']]);
  assert.deepEqual(r.map((x) => x.repo), ['linked', 'pointing', 'dotdot']);
});

test('a link inside .git (HEAD, a ref, packed-refs) is not followed either', async () => {
  const d = repo('inner-links');
  fs.writeFileSync(path.join(OUT, 'head'), 'ref: refs/heads/main\n');
  fs.rmSync(path.join(d, '.git/HEAD'));
  fs.symlinkSync(path.join(OUT, 'head'), path.join(d, '.git/HEAD'));
  assert.ok((await heads(['inner-links']))[0].error);
  const e = repo('ref-link');
  const sha = git(e, 'rev-parse', 'HEAD');
  fs.writeFileSync(path.join(OUT, 'ref'), `${sha}\n`);
  fs.rmSync(path.join(e, '.git/refs/heads/main'));
  fs.symlinkSync(path.join(OUT, 'ref'), path.join(e, '.git/refs/heads/main'));
  const r = (await heads(['ref-link']))[0];
  assert.ok(r.error || r.head === null, JSON.stringify(r));
  assert.notEqual(r.head, sha);
});

test('a worktree inside the root: its own branch, through commondir', async () => {
  const d = repo('main-wt');
  git(d, 'worktree', 'add', '-q', '-b', 'side', path.join(WS, 'wt-side'));
  const sha = git(path.join(WS, 'wt-side'), 'rev-parse', 'HEAD');
  assert.ok(fs.statSync(path.join(WS, 'wt-side/.git')).isFile());
  assert.deepEqual(await heads(['wt-side']), [{ repo: 'wt-side', branch: 'side', head: sha }]);
  // a new commit in the worktree is a loose ref in the main repository's refs
  fs.writeFileSync(path.join(WS, 'wt-side/w.txt'), 'w'); git(path.join(WS, 'wt-side'), 'add', 'w.txt'); git(path.join(WS, 'wt-side'), 'commit', '-q', '-m', 'w');
  assert.equal((await heads(['wt-side']))[0].head, git(path.join(WS, 'wt-side'), 'rev-parse', 'HEAD'));
});

test('not a repository, a folder that is not there, and a folder outside the workspace: an error entry for that one, the others answered', async () => {
  fs.mkdirSync(path.join(WS, 'plain'), { recursive: true });
  const ok = repo('fine');
  const r = await heads(['plain', 'missing', '../outside', '/etc', `${WS}/../outside`, 'fine', 7, '']);
  assert.equal(r.length, 8);
  for (const i of [0, 1, 2, 3, 4, 6]) assert.ok(typeof r[i].error === 'string' && r[i].error.length > 0 && r[i].error.length < 300, `${i} ${JSON.stringify(r[i])}`);
  assert.deepEqual(r[5], { repo: 'fine', branch: 'main', head: git(ok, 'rev-parse', 'HEAD') });
  assert.equal(r[7].repo, '');   // (the workspace itself: no repository there)
  assert.ok(r[7].error);
});

test('more than 100 repositories, or no list, is refused; exactly 100 is answered', async () => {
  assert.match((await call({ op: 'git.heads', repos: Array(101).fill('fine') })).error, /at most 100/);
  assert.match((await call({ op: 'git.heads', repos: 'fine' })).error, /repos/);
  assert.match((await call({ op: 'git.heads' })).error, /repos/);
  assert.equal((await heads(Array(100).fill('fine'))).length, 100);
  assert.deepEqual(await heads([]), []);
});

test('the answer holds nothing but repo, branch, head and error; a head is 40 or 64 hex characters, never other text', async () => {
  const d = repo('shape');
  const bad = repo('badref');
  fs.writeFileSync(path.join(bad, '.git/refs/heads/main'), 'not-a-sha; rm -rf /\n');
  const r = await heads(['shape', 'badref', 'plain', 'missing']);
  const call1 = await call({ op: 'git.heads', repos: ['shape'], extra: 'x' });
  assert.deepEqual(Object.keys(call1), ['heads']);
  for (const x of r) {
    for (const k of Object.keys(x)) assert.ok(['repo', 'branch', 'head', 'error'].includes(k), k);
    if (x.head) assert.match(x.head, /^[0-9a-f]{40}([0-9a-f]{24})?$/);
  }
  assert.equal(r[1].head, null, 'a ref file that is no commit is no head');
  assert.ok(!JSON.stringify(r).includes('rm -rf'));
  assert.equal(r[0].head, git(d, 'rev-parse', 'HEAD'));
});
