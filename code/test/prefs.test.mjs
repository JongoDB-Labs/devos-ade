// Your choices for new sessions, kept for your sign-in in the code container (userprefs.mjs, GET/PUT /api/prefs and
// /api/state's prefs): the model you picked last follows you to a new browser or a phone (UX-01).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createServer } from '../server/main.mjs';
import { UserPrefs, prefsOf } from '../server/userprefs.mjs';
import { fakeQuery } from './fake-sdk.mjs';
import { tmp, stubDist } from './helpers.mjs';

const SECRET = 'cd'.repeat(16);

test('prefs: model ids only (never an alias), null for none; kept in a file of its own (0600), a broken one reads as none', () => {
  const dir = tmp('bnprefs');
  let t = 1_700_000_000_000;
  const p = new UserPrefs({ dir, now: () => t });
  assert.deepEqual(p.read(), { model: null, settingsDefault: null, at: null });
  assert.deepEqual(p.set({ model: 'claude-haiku-5-5', settingsDefault: null }), { model: 'claude-haiku-5-5', settingsDefault: null, at: t });
  t += 5;
  assert.deepEqual(p.set({ model: 'or/google/gemma-4-31b-it:free', settingsDefault: 'claude-opus-5-5' }),
    { model: 'or/google/gemma-4-31b-it:free', settingsDefault: 'claude-opus-5-5', at: t });
  assert.deepEqual(new UserPrefs({ dir }).read(), { model: 'or/google/gemma-4-31b-it:free', settingsDefault: 'claude-opus-5-5', at: t });
  const file = path.join(dir, 'prefs', 'prefs.json');
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700);
  for (const bad of [{ model: 'opus' }, { model: 'sonnet[1m]' }, { model: '../etc/passwd' }, { model: 'a b' }, { model: 'x'.repeat(200) }, { model: 5 },
    { settingsDefault: '<img src=x>' }, null, [], 'claude-haiku-5-5']) {
    assert.throws(() => p.set(bad), (e) => e.status === 400, JSON.stringify(bad));
  }
  assert.deepEqual(prefsOf({}), { model: null, settingsDefault: null });
  for (const junk of ['{', JSON.stringify({ version: 2, model: 'claude-haiku-5-5' }), JSON.stringify({ version: 1, model: 'opus' }), 'null']) {
    fs.writeFileSync(file, junk);
    assert.deepEqual(p.read(), { model: null, settingsDefault: null, at: null }, junk);
  }
  fs.rmSync(dir, { recursive: true, force: true });
});

test('prefs over the API: /api/state carries them, PUT keeps them (the page\'s Origin only), a bad model is 400', async () => {
  const dir = tmp('bnprefs-api');
  const dist = stubDist('bnprefsdist');
  const srv = createServer({ secret: SECRET, query: fakeQuery(), spawn: () => {}, call: async () => { throw new Error('no sandbox here'); }, distDir: dist,
    logger: () => {}, userPrefs: new UserPrefs({ dir }) });
  await new Promise((r) => srv.server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${srv.server.address().port}`;
  const go = async (method, p, body, origin = base) => {
    const r = await fetch(base + p, { method, headers: { 'X-Bn-Code-Proxy': SECRET, ...(body !== undefined ? { 'Content-Type': 'application/json', ...(origin ? { Origin: origin } : {}) } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined });
    return { status: r.status, json: await r.json().catch(() => null) };
  };
  try {
    assert.deepEqual((await go('GET', '/api/state')).json.prefs, { model: null, settingsDefault: null, at: null });
    const put = await go('PUT', '/api/prefs', { model: 'claude-haiku-5-5', settingsDefault: null });
    assert.equal(put.status, 200);
    assert.equal(put.json.prefs.model, 'claude-haiku-5-5');
    // another browser (no localStorage of its own) reads the same
    assert.equal((await go('GET', '/api/state')).json.prefs.model, 'claude-haiku-5-5');
    assert.equal((await go('GET', '/api/prefs')).json.prefs.model, 'claude-haiku-5-5');
    assert.equal((await go('PUT', '/api/prefs', { model: 'haiku' })).status, 400);
    assert.equal((await go('PUT', '/api/prefs', { model: 'claude-opus-5-5' }, 'http://evil.example')).status, 403);
    assert.equal((await go('PUT', '/api/prefs', { model: 'claude-opus-5-5' }, null)).status, 403);
    assert.equal((await go('GET', '/api/prefs')).json.prefs.model, 'claude-haiku-5-5');
  } finally {
    srv.mgr.closeAll(); srv.wss.close(); srv.server.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(dist, { recursive: true, force: true });
  }
});
