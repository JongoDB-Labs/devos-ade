// The item menus' backend actions (JON-821; main.mjs, api.mjs, projects.mjs, bn-coded's sessions.delete): Archive and
// listing again (a label of the page's records), Delete (confirmed by the session's own id; refused while a turn runs, in
// the terminal or for a folder no longer added; the transcript and its folder go, the labels with it), and a terminal in a
// session's or a file's folder (always a folder the records or the workspace allow) — over a stand-in sandbox, and bn-coded
// itself for the transcript's removal.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { createServer } from '../server/main.mjs';
import { Projects } from '../server/projects.mjs';
import { SandboxError } from '../server/spawn-client.mjs';
import { fakeQuery } from './fake-sdk.mjs';
import { tmp, stubDist, talk, open, result, TERMINAL_DIR } from './helpers.mjs';

const SECRET = 'ab'.repeat(16);
const calls = [];
const A = crypto.randomUUID(), B = crypto.randomUUID(), C = crypto.randomUUID();
const state = { running: false, deleteAnswer: null, listed: true };
const row = (id, cwd) => ({ id, mtimeMs: 1_700_000_000_000, size: 10, firstPrompt: `in ${cwd}`, cwd });
const answers = {
  'sessions.list': () => ({ result: { sessions: state.listed ? [row(A, '/workspace'), row(B, '/workspace/app/src'), row(C, '/workspace/.git')] : [] } }),
  'sessions.load': () => ({ result: { entries: [] } }),
  'sessions.running': () => ({ result: { running: state.running } }),
  'sessions.delete': (req) => state.deleteAnswer?.(req) ?? { result: { ok: true, folder: false } },
  'terminal.window': (req) => ({ result: { ok: true, window: path.basename(req.root ?? '/workspace').replace(/[^A-Za-z0-9_.-]/g, '-') } }),
  'ws.sensitive': () => ({ result: { files: [] } }),
};
const call = async (req) => { calls.push(req); const a = answers[req.op]; if (!a) throw new SandboxError('unknown op', 'refused'); return a(req); };

let srv, base, stateDir;
before(async () => {
  stateDir = tmp('bnmenus');
  const dist = stubDist('bnmdist');
  srv = createServer({ secret: SECRET, query: fakeQuery(), spawn: () => {}, call, distDir: dist, logger: () => {}, projects: new Projects({ dir: stateDir }) });
  await new Promise((r) => srv.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${srv.server.address().port}`;
  fs.rmSync(dist, { recursive: true, force: true });
});
after(() => {
  srv.mgr.closeAll();
  for (const c of srv.wss.clients) c.terminate();
  srv.wss.close(); srv.server.closeAllConnections?.(); srv.server.close();
  fs.rmSync(stateDir, { recursive: true, force: true });
});

async function req(method, p, body, headers = {}) {
  const r = await fetch(base + p, { method, headers: { 'X-Bn-Code-Proxy': SECRET, ...(body !== undefined ? { 'Content-Type': 'application/json', Origin: base } : method !== 'GET' ? { Origin: base } : {}), ...headers },
    body: body !== undefined ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let json = null; try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: r.status, json };
}
const listed = async () => (await req('GET', '/api/sessions')).json.sessions;

test('archive: a label — the session is listed with archived: true, and plainly again after Unarchive; nothing is sent to the sandbox', async () => {
  const before = calls.length;
  let r = await req('POST', `/api/sessions/${A}/archive`, { archived: true });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { ok: true, archived: true, count: 1 });
  assert.equal(calls.slice(before).some((c) => c.op !== 'sessions.list' && c.op !== 'ws.sensitive'), false, 'no op for the sandbox but the list');
  let rows = await listed();
  assert.equal(rows.find((s) => s.id === A).archived, true);
  assert.equal(rows.find((s) => s.id === B).archived, undefined);
  r = await req('POST', `/api/sessions/${A}/archive`, { archived: false });
  assert.equal(r.json.archived, false);
  rows = await listed();
  assert.equal(rows.find((s) => s.id === A).archived, undefined);
});

test('archive: bad ids, a missing or non-boolean archived, and a cross-origin request are refused', async () => {
  assert.equal((await req('POST', '/api/sessions/not-an-id/archive', { archived: true })).status, 400);
  assert.equal((await req('POST', `/api/sessions/${A}/archive`, {})).status, 400);
  assert.equal((await req('POST', `/api/sessions/${A}/archive`, { archived: 'yes' })).status, 400);
  const r = await fetch(`${base}/api/sessions/${A}/archive`, { method: 'POST', headers: { 'X-Bn-Code-Proxy': SECRET, 'Content-Type': 'application/json', Origin: 'https://evil.example' }, body: '{"archived":true}' });
  assert.equal(r.status, 403, 'only the page\'s own Origin changes anything');
});

test('delete: needs the session\'s own id as confirm; then bn-coded removes it with its folder (the same cwd as its title) and the labels go', async () => {
  assert.equal((await req('POST', `/api/sessions/${B}/delete`, {})).status, 400);
  assert.equal((await req('POST', `/api/sessions/${B}/delete`, { confirm: true })).status, 400);
  assert.equal((await req('POST', `/api/sessions/${B}/delete`, { confirm: A })).status, 400);
  assert.equal(calls.some((c) => c.op === 'sessions.delete'), false, 'nothing deleted without the confirmation');
  await req('POST', `/api/sessions/${B}/archive`, { archived: true });
  const r = await req('POST', `/api/sessions/${B}/delete`, { confirm: B });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { ok: true, deleted: B });
  const c = calls.filter((x) => x.op === 'sessions.delete');
  assert.deepEqual(c.at(-1), { op: 'sessions.delete', id: B, cwd: '/workspace/app/src' });
  const proj = JSON.parse(fs.readFileSync(path.join(stateDir, 'projects', 'projects.json'), 'utf8'));
  assert.equal(B in proj.archived, false, 'its archived label went with it');
});

test('delete: refused while the terminal runs it and with a bad id; an old sandbox is said; a missing session is 404', async () => {
  state.running = true;
  let r = await req('POST', `/api/sessions/${A}/delete`, { confirm: A });
  assert.equal(r.status, 409);
  state.running = false;
  const n = calls.filter((x) => x.op === 'sessions.delete').length;
  assert.equal(calls.filter((x) => x.op === 'sessions.delete').length, n, 'never asked of the sandbox while it runs there');
  assert.equal((await req('POST', '/api/sessions/nope/delete', { confirm: 'nope' })).status, 400);
  state.deleteAnswer = () => Promise.reject(new SandboxError('unknown op', 'refused'));
  assert.equal((await req('POST', `/api/sessions/${A}/delete`, { confirm: A })).status, 501);
  state.deleteAnswer = () => Promise.reject(new SandboxError('no such session', 'refused'));
  assert.equal((await req('POST', `/api/sessions/${A}/delete`, { confirm: A })).status, 404);
  state.deleteAnswer = null;
});

test('folder-terminal: a session\'s working folder (the workspace\'s own: no root; a folder: its path), never .git, and a bad id', async () => {
  let r = await req('POST', `/api/sessions/${A}/folder-terminal`);
  assert.equal(r.status, 200);
  assert.equal(r.json.ok, true);
  assert.equal(calls.filter((x) => x.op === 'terminal.window').at(-1).root, undefined);
  r = await req('POST', `/api/sessions/${B}/folder-terminal`);
  assert.equal(r.status, 200);
  assert.equal(r.json.window, 'src');
  assert.deepEqual(calls.filter((x) => x.op === 'terminal.window').at(-1), { op: 'terminal.window', root: '/workspace/app/src' });
  // (a session working in .git: the workspace's own terminal, never .git)
  r = await req('POST', `/api/sessions/${C}/folder-terminal`);
  assert.equal(calls.filter((x) => x.op === 'terminal.window').at(-1).root, undefined);
  assert.equal((await req('POST', '/api/sessions/x/folder-terminal')).status, 400);
});

test('POST /api/fs/terminal: a folder, or the folder a file is in; never .git, "..", the trash or too deep', async () => {
  const last = () => calls.filter((x) => x.op === 'terminal.window').at(-1);
  let r = await req('POST', '/api/fs/terminal', { path: 'app/src/main.ts' });
  assert.equal(r.status, 200);
  assert.equal(last().root, '/workspace/app/src');
  r = await req('POST', '/api/fs/terminal', { path: 'app', dir: true });
  assert.equal(last().root, '/workspace/app');
  r = await req('POST', '/api/fs/terminal', { path: 'README.md' });
  assert.equal(r.status, 200);
  assert.equal(last().root, undefined, 'a file of the workspace\'s top: the workspace');
  for (const bad of [{ path: '../etc', dir: true }, { path: '.git/hooks', dir: true }, { path: 'a/.bedrock-now-trash/x', dir: true }, { path: 'a/b/c/d/e/f/g/h/i', dir: true }, {}, { path: 7 }]) {
    r = await req('POST', '/api/fs/terminal', bad);
    assert.ok(r.status === 400, `${JSON.stringify(bad)} is refused (${r.status})`);
  }
});

// --- bn-coded itself: sessions.delete ---
const ROOT = tmp('bnmdel');
const WS = path.join(ROOT, 'ws'), HOME = path.join(ROOT, 'home'), SOCKDIR = path.join(ROOT, 'sock');
fs.mkdirSync(WS); fs.mkdirSync(HOME);
Object.assign(process.env, { BN_CODE_WORKSPACE: WS, BN_CODE_SOCK_DIR: SOCKDIR, BN_CODE_CHILDREN: path.join(ROOT, 'children'), CLAUDE_CONFIG_DIR: path.join(HOME, '.claude'), HOME });
const coded = await import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));
test('bn-coded sessions.delete: the transcript and its folder go; a link, another id and a bad folder are refused', async () => {
  const server = coded.start();
  await new Promise((r) => (server.listening ? r() : server.once('listening', r)));
  try {
    const SOCK = path.join(SOCKDIR, 'coded.sock');
    const dir = path.join(HOME, '.claude', 'projects', WS.replace(/[^A-Za-z0-9]/g, '-'));
    fs.mkdirSync(dir, { recursive: true });
    const id = crypto.randomUUID(), other = crypto.randomUUID(), linked = crypto.randomUUID();
    fs.writeFileSync(path.join(dir, `${id}.jsonl`), '{}\n');
    fs.mkdirSync(path.join(dir, id, 'subagents'), { recursive: true });
    fs.writeFileSync(path.join(dir, id, 'subagents', 'a.jsonl'), '{}\n');
    fs.writeFileSync(path.join(dir, `${other}.jsonl`), '{}\n');
    fs.writeFileSync(path.join(ROOT, 'outside.txt'), 'keep');
    fs.symlinkSync(path.join(ROOT, 'outside.txt'), path.join(dir, `${linked}.jsonl`));
    const ask = async (o) => result(await talk(SOCK, [open({ op: 'sessions.delete', ...o })]));
    assert.deepEqual(await ask({ id }), { ok: true, folder: true });
    assert.equal(fs.existsSync(path.join(dir, `${id}.jsonl`)), false);
    assert.equal(fs.existsSync(path.join(dir, id)), false, 'its folder went too');
    assert.equal(fs.existsSync(path.join(dir, `${other}.jsonl`)), true, 'another session is untouched');
    assert.match((await ask({ id })).error, /no such session/, 'already gone');
    assert.match((await ask({ id: linked })).error, /not a transcript/);
    assert.equal(fs.readFileSync(path.join(ROOT, 'outside.txt'), 'utf8'), 'keep', 'never through a link');
    assert.match((await ask({ id: '../../etc/passwd' })).error, /bad session id/);
    assert.match((await ask({ id: other, cwd: '/etc' })).error, /bad session folder/);
  } finally { server.close(); fs.rmSync(ROOT, { recursive: true, force: true }); }
});

test('Projects.archive: labels kept, listed again, forgotten with a deleted session; ids and the flag checked, capped', () => {
  const dir = tmp('bnmarch');
  try {
    const store = new Projects({ dir });
    const x = crypto.randomUUID(), y = crypto.randomUUID();
    assert.deepEqual(store.archive([x, y], true), { ok: true, archived: true, count: 2 });
    assert.deepEqual([...store.archivedIds()].sort(), [x, y].sort());
    store.archive([x], false);
    assert.deepEqual([...store.archivedIds()], [y]);
    store.file([y], 'ws');
    store.forgetSession(y);
    assert.equal(store.archivedIds().size, 0);
    assert.equal(store.read().filed[y], undefined);
    assert.throws(() => store.archive(['nope'], true), /ids/);
    assert.throws(() => store.archive([x], 'yes'), /true or false/);
    assert.throws(() => store.archive([], true), /ids/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('POST /api/fs/terminal: an absolute path is accepted only inside a folder of this computer the records know', async () => {
  const r = await req('POST', '/api/fs/terminal', { path: '/etc/passwd' });
  assert.equal(r.status, 400);
  assert.equal((await req('POST', '/api/fs/terminal', { path: '/workspace/app/x.ts' })).status, 200, 'the workspace by its absolute path too');
});
