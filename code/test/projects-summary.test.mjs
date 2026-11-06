// The projects summary for the portal's Terminal page (JON-1158; projects.mjs summary/writeSummary): the one-way file the
// portal reads from a volume of its own — its shape, mode 644, written whole at every change, and nothing secret in it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { Projects, SUMMARY_FILE } from '../server/projects.mjs';
import { tmp } from './helpers.mjs';

const NOW = 1_700_000_000_000;
function rig(over = {}) {
  const pub = path.join(tmp('bnpub'), 'public');
  const hostsFile = path.join(tmp('bnhosts'), 'roots.json');
  fs.writeFileSync(hostsFile, JSON.stringify({ roots: [{ id: 'p_aaaaaaaa', name: 'src', path: '/projects/src', mode: 'ro' }] }));
  const store = new Projects({ dir: tmp('bnsum'), now: () => NOW, hostsFile, publicDir: pub, ...over });
  const read = () => JSON.parse(fs.readFileSync(path.join(pub, SUMMARY_FILE), 'utf8'));
  return { store, pub, read, hostsFile };
}

test('summary: shape, Workspace first, host folders flagged, no extra fields', () => {
  const { store, read } = rig();
  store.add({ root: 'app', name: 'App' });
  const s = read();
  assert.equal(s.written_at, NOW / 1000);
  assert.deepEqual(s.projects.map((p) => p.name), ['Workspace', 'App']);   // (the folders of this computer are not in it)
  const app = s.projects[1];
  assert.match(app.id, /^p_[0-9a-f]{8}$/);
  assert.deepEqual(Object.keys(app).sort(), ['folder', 'gone', 'host', 'id', 'kept', 'mode', 'name', 'path', 'root']);
  assert.deepEqual({ ...app, id: 'x' }, { id: 'x', name: 'App', root: 'app', path: '/workspace/app', host: false, mode: 'rw', gone: false, folder: 'ok', kept: false });
  assert.ok(!s.projects.some((p) => p.host || p.id === 'p_aaaaaaaa'));
  assert.equal(s.projects[0].id, 'ws');
  assert.equal(s.projects[0].path, '/workspace');
});

test('summary: the file is mode 644, whole (no temporary left), and rewritten at every change', () => {
  const { store, pub, read } = rig();
  const p = store.add({ root: 'app' });
  assert.equal(fs.statSync(path.join(pub, SUMMARY_FILE)).mode & 0o777, 0o644);
  assert.deepEqual(fs.readdirSync(pub), [SUMMARY_FILE]);
  store.rename(p.id, 'Renamed');
  assert.ok(read().projects.some((x) => x.name === 'Renamed' && x.path === '/workspace/app'));
  store.setLocalgit(p.id, () => ({ state: 'kept', repo: 'forge/app', remote: 'origin', auto: true, made: true, pushedAt: null, lastError: null, heads: {}, rejected: {} }));
  assert.equal(read().projects.find((x) => x.id === p.id).kept, true);
  store.remove(p.id);
  assert.ok(!read().projects.some((x) => x.id === p.id));
  assert.deepEqual(fs.readdirSync(pub), [SUMMARY_FILE]);
});

test('summary: the sandbox look overrides folder; no folder of this computer, even one no longer added', () => {
  const { store, read, hostsFile } = rig();
  store.syncHosts();
  fs.writeFileSync(hostsFile, JSON.stringify({ roots: [] }));
  store.syncHosts();
  assert.ok(!read().projects.some((x) => x.id === 'p_aaaaaaaa'));
  const q = store.add({ root: 'app' });
  assert.equal(store.writeSummary({ folders: new Map([[q.id, { folder: 'missing', git: false }]]) }), true);
  assert.equal(read().projects.find((x) => x.id === q.id).folder, 'missing');
  store.writeSummary({ folders: new Map([[q.id, { folder: 'dir', git: true }]]) });
  assert.equal(read().projects.find((x) => x.id === q.id).folder, 'ok');
});

test('summary: nothing secret, nothing but the nine fields (even with trust and a kept remote)', () => {
  const { store, pub } = rig();
  const p = store.add({ root: 'app' });
  store.setLocalgit(p.id, () => ({ state: 'kept', repo: 'forge/app', remote: 'origin', auto: true, made: true, pushedAt: 5, lastError: 'token ghp_SECRET', heads: { main: 'a'.repeat(40) }, rejected: {} }));
  store.trust(p.id, 'b'.repeat(64));
  const text = fs.readFileSync(path.join(pub, SUMMARY_FILE), 'utf8');
  for (const w of ['ghp_SECRET', 'forge/app', 'trust', 'hash', 'heads', 'lastError', 'filed']) assert.ok(!text.includes(w), w);
});

test('summary: no publicDir, no file; an unwritable one never fails a change', () => {
  const none = new Projects({ dir: tmp('bnsum'), now: () => NOW, publicDir: '' });
  assert.equal(none.writeSummary(), false);
  none.add({ root: 'app' });
  const blocker = path.join(tmp('bnblock'), 'file');
  fs.writeFileSync(blocker, 'x');
  const bad = new Projects({ dir: tmp('bnsum'), now: () => NOW, publicDir: path.join(blocker, 'sub') });
  assert.doesNotThrow(() => bad.add({ root: 'app' }));
  assert.equal(bad.writeSummary(), false);
});

test('summary: written at boot (writeSummary with no change) from what is stored', () => {
  const { store, pub, read, hostsFile } = rig();
  store.add({ root: 'app' });
  fs.rmSync(path.join(pub, SUMMARY_FILE));
  const boot = new Projects({ dir: path.dirname(store.dir), now: () => NOW, hostsFile, publicDir: pub });   // (a new process: nothing remembered)
  assert.equal(boot.writeSummary(), true);
  assert.equal(read().projects.length, 2);
});

test('summary: an unchanged one is not written again; a failed write leaves no temporary file and is logged once', () => {
  const logs = [];
  const { store, pub } = rig({ log: (m) => logs.push(m) });
  store.add({ root: 'app' });
  const f = path.join(pub, SUMMARY_FILE);
  const t0 = fs.statSync(f).mtimeMs, ino = fs.statSync(f).ino;
  assert.equal(store.writeSummary(), true);
  assert.equal(fs.statSync(f).ino, ino);
  assert.equal(fs.statSync(f).mtimeMs, t0);
  // a rename that cannot happen (the target is a folder): the temporary file goes, one log line
  fs.rmSync(f);
  fs.mkdirSync(f);
  store.rename(store.list().find((p) => p.root === 'app').id, 'Other');
  store.rename(store.list().find((p) => p.root === 'app').id, 'Third');
  assert.deepEqual(fs.readdirSync(pub), [SUMMARY_FILE]);
  assert.equal(logs.length, 1);
  assert.match(logs[0], /summary for the portal cannot be written/);
});
