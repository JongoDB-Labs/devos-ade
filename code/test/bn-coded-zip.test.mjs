// bn-coded's fs.zip (terminal/bin/bn-coded.mjs): a project folder's files as a streamed zip — what git keeps (.gitignore
// respected, no .git, no node_modules), a walk without git, "include everything" and ".git too", the size cap (refused
// before a byte is sent), links never followed, confinement to the root, one at a time, and a zip that reads back whole.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmp, talk, open, result, stdout, TERMINAL_DIR } from './helpers.mjs';
import { readZip } from './zipread.mjs';
import { sandboxCall } from '../server/spawn-client.mjs';

const ROOT = tmp('bnzip');
const WS = path.join(ROOT, 'ws'), HOME = path.join(ROOT, 'home'), SOCKDIR = path.join(ROOT, 'sock'), OUT = path.join(ROOT, 'outside');
for (const d of [WS, HOME, OUT, path.join(HOME, '.claude')]) fs.mkdirSync(d, { recursive: true });
fs.writeFileSync(path.join(OUT, 'secret.txt'), 'outside');
Object.assign(process.env, { BN_CODE_WORKSPACE: WS, BN_CODE_SOCK_DIR: SOCKDIR, BN_CODE_CHILDREN: path.join(ROOT, 'children'), HOME, CLAUDE_CONFIG_DIR: path.join(HOME, '.claude') });
const coded = await import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));
const which = (n) => ['/usr/bin', '/usr/local/bin', '/bin', '/opt/homebrew/bin'].map((d) => path.join(d, n)).find((f) => fs.existsSync(f));
const GIT = which('git');
let server;
const SOCK = path.join(SOCKDIR, 'coded.sock');
before(async () => { server = coded.start(); await new Promise((r) => (server.listening ? r() : server.once('listening', r))); });
after(() => { server.close(); fs.rmSync(ROOT, { recursive: true, force: true }); });
const zip = async (req) => { const f = await talk(SOCK, [open({ op: 'fs.zip', ...req })]); return { r: result(f), bytes: stdout(f) }; };
const PLAIN = { PATH: process.env.PATH, HOME, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
const git = (cwd, ...a) => execFileSync(GIT, a, { cwd, env: PLAIN }).toString();
const put = (dir, rel, data, mode) => { const f = path.join(dir, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, data); if (mode) fs.chmodSync(f, mode); };

const P = path.join(WS, 'proj'), G = path.join(WS, 'repo');

test('no git: a walk without dependency and build folders, links left out, modes and big files kept, reads back whole', async () => {
  const big = crypto.randomBytes(3 << 20);
  put(P, 'src/a.ts', 'const a = 1;\n');
  put(P, 'run.sh', '#!/bin/sh\necho hi\n', 0o755);
  put(P, 'empty.txt', '');
  put(P, 'ünï/código.txt', 'utf8 name');
  put(P, 'data/big.bin', big);
  put(P, 'node_modules/dep/index.js', 'x');
  put(P, 'dist/out.js', 'x');
  put(P, '.git/HEAD', 'ref: refs/heads/main');   // (not a repository: a stray folder of that name is still left out)
  fs.symlinkSync(path.join(OUT, 'secret.txt'), path.join(P, 'link.txt'));
  fs.symlinkSync(OUT, path.join(P, 'linkdir'));
  const { r, bytes } = await zip({ root: P });
  assert.equal(r.via, 'walk');
  assert.equal(r.skippedLinks, 2);
  const z = readZip(bytes);
  assert.deepEqual(Object.keys(z).sort(), ['data/big.bin', 'empty.txt', 'run.sh', 'src/a.ts', 'ünï/código.txt']);
  assert.equal(z['src/a.ts'].data.toString(), 'const a = 1;\n');
  assert.ok(z['data/big.bin'].data.equals(big));
  assert.equal(z['run.sh'].mode & 0o111, 0o111, 'an executable stays executable');
  assert.equal(r.files, 5);
  assert.equal(r.zipBytes, bytes.length);
});

test('include "all": dependency and build folders too (never the trash, never .git)', async () => {
  put(P, '.bedrock-now-trash/old.txt', 'x');
  const { bytes } = await zip({ root: P, include: 'all' });
  const names = Object.keys(readZip(bytes));
  assert.ok(names.includes('node_modules/dep/index.js') && names.includes('dist/out.js'));
  assert.ok(!names.some((n) => n.startsWith('.git/') || n.startsWith('.bedrock-now-trash/')), names.join());
});

test('a git repository: what git keeps — .gitignore respected, untracked files in, .git and node_modules out; git: true adds history', async (t) => {
  if (!GIT) { t.skip('no git'); return; }
  put(G, '.gitignore', 'secret-build/\n*.log\n');
  put(G, 'a.txt', 'tracked');
  put(G, 'sub/b.txt', 'tracked too');
  put(G, 'node_modules/x/y.js', 'x');
  git(G, 'init', '-q');
  git(G, '-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '-A', '-f', 'a.txt', 'sub', '.gitignore');
  git(G, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'first');
  put(G, 'new-untracked.txt', 'new');
  put(G, 'secret-build/out', 'ignored');
  put(G, 'debug.log', 'ignored');
  fs.rmSync(path.join(G, 'sub/b.txt'));   // tracked, deleted since: not listed
  let { r, bytes } = await zip({ root: G });
  assert.equal(r.via, 'git');
  assert.deepEqual(Object.keys(readZip(bytes)).sort(), ['.gitignore', 'a.txt', 'new-untracked.txt']);
  ({ r, bytes } = await zip({ root: G, git: true }));
  const names = Object.keys(readZip(bytes));
  assert.ok(names.includes('.git/HEAD') && names.some((n) => n.startsWith('.git/objects/')), names.join());
  assert.ok(names.includes('a.txt'));
  // history round trip: the zip's .git is a repository that has the commit
  const out = path.join(ROOT, 'unz');
  for (const [n, f] of Object.entries(readZip(bytes))) { const d = path.join(out, n); fs.mkdirSync(path.dirname(d), { recursive: true }); fs.writeFileSync(d, f.data); }
  assert.match(git(out, 'log', '--oneline'), /first/);
});

test('a repository that names programs in its configuration never runs them', async (t) => {
  if (!GIT) { t.skip('no git'); return; }
  const H = path.join(WS, 'hostile');
  put(H, 'a.txt', 'a');
  git(H, 'init', '-q');
  const mark = path.join(ROOT, 'ran');
  fs.appendFileSync(path.join(H, '.git/config'), `[core]\n\tfsmonitor = touch ${mark}\n\thooksPath = ${OUT}\n[filter "x"]\n\tclean = touch ${mark}\n`);
  put(H, '.gitattributes', '* filter=x\n');
  const { r, bytes } = await zip({ root: H });
  assert.equal(r.via, 'git');
  assert.ok(readZip(bytes)['a.txt']);
  assert.ok(!fs.existsSync(mark), 'no program of the repository ran');
});

test('dry: how many files and bytes, no zip; over the cap: refused before any byte, saying how big it is', async () => {
  let { r, bytes } = await zip({ root: P, dry: true });
  assert.equal(r.files, 5);
  assert.ok(r.bytes > 3 << 20);
  assert.equal(bytes.length, 0);
  assert.equal(r.over, false);
  ({ r, bytes } = await zip({ root: P, max: 1 << 20, dry: true }));
  assert.equal(r.over, true);
  ({ r, bytes } = await zip({ root: P, max: 1 << 20 }));
  assert.match(r.error, /too large: 5 files, 3\.\d MiB before compression; the limit is 1\.0 MiB/);
  assert.equal(bytes.length, 0);
});

test('confinement: the root only; a root through a link or outside the workspace is refused', async () => {
  fs.symlinkSync(OUT, path.join(WS, 'out-link'));
  for (const root of [path.join(WS, 'out-link'), OUT, path.join(WS, 'missing'), 'proj']) assert.ok((await zip({ root })).r.error, root);
  // the workspace itself: its folders in, with paths relative to it
  const { bytes } = await zip({});
  assert.ok(Object.keys(readZip(bytes)).includes('proj/src/a.ts'));
});

test('a folder swapped for a link after the list was made: its files are left out, never read through the link', () => {
  const R = path.join(WS, 'swap');
  put(R, 'sub/secret.txt', 'inside');
  put(OUT, 'sub-out/secret.txt', 'outside');
  const root = { abs: R }, real = fs.realpathSync(R);
  const fd = coded.zipOpen(root, 'sub/secret.txt', real);
  assert.equal(typeof fd, 'number');
  fs.closeSync(fd);
  // (listed while sub was a folder; then sub is a link to a folder outside the project)
  fs.rmSync(path.join(R, 'sub'), { recursive: true });
  fs.symlinkSync(path.join(OUT, 'sub-out'), path.join(R, 'sub'));
  assert.equal(coded.zipOpen(root, 'sub/secret.txt', real), 'link');
  // the file itself a link: refused by O_NOFOLLOW
  fs.symlinkSync(path.join(OUT, 'secret.txt'), path.join(R, 'top.txt'));
  assert.equal(coded.zipOpen(root, 'top.txt', real), 'link');
  assert.equal(coded.zipOpen(root, 'gone.txt', real), null);
});

test('an empty project is a valid, empty zip', async () => {
  fs.mkdirSync(path.join(WS, 'nothing'));
  const { r, bytes } = await zip({ root: path.join(WS, 'nothing') });
  assert.equal(r.files, 0);
  assert.deepEqual(readZip(bytes), {});
});

test('through the code container\'s client: streamed to onStdout (a slow reader waits, nothing held), the zip whole; a refusal before any chunk', async () => {
  const chunks = [];
  let waits = 0;
  const { result } = await sandboxCall({ op: 'fs.zip', root: P }, { sock: SOCK, maxBytes: 1 << 16,
    onStdout: (c, resume) => { chunks.push(c); if (chunks.length % 2 === 0) { waits++; setTimeout(resume, 2); return false; } return true; } });
  const bytes = Buffer.concat(chunks);
  assert.equal(result.zipBytes, bytes.length);
  assert.ok(bytes.length > 3 << 20 && waits >= 1);
  assert.ok(readZip(bytes)['data/big.bin']);
  let got = 0;
  await assert.rejects(sandboxCall({ op: 'fs.zip', root: P, max: 1 << 20 }, { sock: SOCK, onStdout: () => { got++; } }), /too large/);
  assert.equal(got, 0);
  const ac = new AbortController();
  const p = sandboxCall({ op: 'fs.zip', root: P }, { sock: SOCK, signal: ac.signal, onStdout: () => { ac.abort(); } });
  await assert.rejects(p, /cancelled/);
});
