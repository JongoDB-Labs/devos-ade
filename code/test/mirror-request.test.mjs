// JON-970: how a mirror request to the update helper went — told by the helper by its id (import-sessions.mjs request), with a
// short note (the git server's own words, already cleaned of credentials by mirrors.mjs) the page shows as "the git server said".
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { Imports, cli, HELPER_ACTIONS } from '../server/import-sessions.mjs';
import { tmp } from './helpers.mjs';

const ROOT = tmp('bnmreq');
after(() => fs.rmSync(ROOT, { recursive: true, force: true }));
const nonce = () => crypto.randomBytes(16).toString('hex');
const imports = new Imports({ dir: path.join(ROOT, 'imports'), stage: path.join(ROOT, 'stage'), helperFile: path.join(ROOT, 'helper.json') });
const ACTIONS = ['git-mirror-add', 'git-mirror-sync', 'git-mirror-change', 'git-mirror-remove'];

test('the helper may name the four mirror actions, and the page sees them in what the helper offers', () => {
  for (const a of ACTIONS) assert.ok(HELPER_ACTIONS.includes(a), a);
  fs.writeFileSync(path.join(ROOT, 'helper.json'), JSON.stringify({ sessions: [...ACTIONS, 'rm'], screen: false, written_at: Math.floor(Date.now() / 1000) }));
  assert.deepEqual(imports.helper().actions, ACTIONS);
});

test('a request\'s note is kept with it: one line, at most 300 characters; anything that is not text is refused', () => {
  const n = nonce();
  imports.noteRequest(n, { action: 'git-mirror-add', state: 'failed', why: 'mirror', note: 'the git server refused: no\nway '.repeat(40) });
  const r = imports.requests().find((x) => x.id === n);
  assert.equal(r.why, 'mirror');
  assert.ok(r.note.length <= 300 && !/[\x00-\x1f]/.test(r.note) && r.note.startsWith('the git server refused: no way'));
  assert.throws(() => imports.noteRequest(n, { state: 'failed', note: { a: 1 } }), /bad request state/);
  assert.throws(() => imports.noteRequest(n, { state: 'done', action: 'git-mirror-drop' }), /bad request state/);
  // (a later state keeps the earlier note unless a new one comes)
  imports.noteRequest(n, { state: 'failed' });
  assert.ok(imports.requests().find((x) => x.id === n).note.startsWith('the git server refused'));
});

test('the command: request --note is what ./stack sends; a long or odd note is cut, not refused', async () => {
  const n = nonce();
  const out = [];
  await cli(['request', '--id', n, '--state', 'failed', '--why', 'mirror', '--action', 'git-mirror-sync', '--note', 'x'.repeat(900)], { imports, out: (o) => out.push(o) });
  assert.deepEqual(out, [{ ok: true }]);
  const r = imports.requests().find((x) => x.id === n);
  assert.deepEqual([r.action, r.why, r.note.length], ['git-mirror-sync', 'mirror', 300]);
});
