// Your choices for new sessions, kept for your sign-in in the code container (userprefs.mjs, GET/PUT /api/prefs and
// /api/state's prefs): the model you picked last follows you to a new browser or a phone (UX-01).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createServer } from '../server/main.mjs';
import { UserPrefs, prefsOf, deviceLayoutOf, layoutOf } from '../server/userprefs.mjs';
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

// ---- the layout of the page's widgets (code/web/src/layout.ts), kept per device with the model

// a layout as the page sends one: today's page (the default of code/web/src/layout.ts), then changed
const layoutOne = (patch = {}) => ({
  docks: {
    left: { mode: 'tabs', size: 260, open: true, active: 'explorer' },
    center: { mode: 'tabs', size: 0, open: true, active: 'editor' },
    right: { mode: 'tabs', size: 440, open: true, active: 'chat' },
    bottom: { mode: 'tabs', size: 240, open: true, active: 'terminal' },
  },
  place: { left: ['explorer', 'search', 'git', 'sessions'], center: ['editor'], right: ['chat'], bottom: ['terminal'] },
  hidden: ['terminal'],
  sizes: {},
  pane: 'left',
  ...patch,
});

test('layout: known widgets and docks only, every widget once, the chat never hidden, sizes clamped; anything else is 400', () => {
  const ok = deviceLayoutOf(layoutOne());
  assert.deepEqual(ok, layoutOne());
  assert.deepEqual(layoutOf({ desktop: layoutOne(), tablet: null }), { desktop: layoutOne(), tablet: null });
  assert.deepEqual(layoutOf(null), { desktop: null, tablet: null });
  assert.deepEqual(layoutOf({}), {});
  // sizes are clamped, not refused: a dock to what it may be, a stacked widget to 120 to 2000 px
  const big = deviceLayoutOf(layoutOne({
    docks: { ...layoutOne().docks, left: { mode: 'stack', size: 99999, open: false, active: null }, bottom: { mode: 'tabs', size: 3, open: true, active: 'terminal' }, center: { mode: 'tabs', size: 500, open: true, active: 'editor' } },
    sizes: { git: 5, search: 99999.4 },
  }));
  assert.equal(big.docks.left.size, 900);
  assert.equal(big.docks.bottom.size, 120);
  assert.equal(big.docks.center.size, 0, 'the centre takes what is left');
  assert.deepEqual(big.sizes, { git: 120, search: 2000 });
  const dock = (d, v) => ({ ...layoutOne().docks, [d]: { ...layoutOne().docks[d], ...v } });
  const bad = [
    null, [], 'x', 5, {},
    { ...layoutOne(), extra: 1 },
    layoutOne({ docks: { ...layoutOne().docks, moon: {} } }),
    layoutOne({ docks: dock('left', { mode: 'floating' }) }),
    layoutOne({ docks: dock('left', { size: 'wide' }) }),
    layoutOne({ docks: dock('left', { open: 1 }) }),
    layoutOne({ docks: dock('left', { active: 'bogus' }) }),
    layoutOne({ docks: dock('left', { extra: 1 }) }),
    layoutOne({ place: { ...layoutOne().place, left: ['explorer', 'search', 'git', 'sessions', 'bogus'] } }),
    layoutOne({ place: { ...layoutOne().place, left: ['explorer', 'search', 'git', 'sessions', 'status'] } }),   // (the status bar sits in no dock)
    layoutOne({ place: { ...layoutOne().place, left: ['explorer', 'explorer', 'search', 'git', 'sessions'] } }),
    layoutOne({ place: { ...layoutOne().place, left: ['explorer', 'search', 'git'] } }),                         // (the Projects widget is nowhere)
    layoutOne({ place: { ...layoutOne().place, right: [] } }),                                                    // (the chat is nowhere)
    layoutOne({ place: { ...layoutOne().place, moon: [] } }),
    layoutOne({ hidden: ['chat'] }),
    layoutOne({ hidden: ['bogus'] }),
    layoutOne({ hidden: ['git', 'git'] }),
    layoutOne({ hidden: 'git' }),
    layoutOne({ sizes: { bogus: 100 } }),
    layoutOne({ sizes: { git: 'tall' } }),
    layoutOne({ sizes: [] }),
    layoutOne({ pane: 'right' }),
  ];
  for (const b of bad) assert.throws(() => deviceLayoutOf(b), (e) => e.status === 400, JSON.stringify(b)?.slice(0, 80));
  for (const b of [5, [], 'x', { phone: layoutOne() }, { desktop: 5 }, { desktop: layoutOne({ pane: 'x' }) }]) assert.throws(() => layoutOf(b), (e) => e.status === 400, JSON.stringify(b));
  // the status bar may be hidden, the editor moved anywhere, the chat to the centre
  const moved = deviceLayoutOf(layoutOne({ place: { left: ['explorer', 'search', 'git', 'sessions'], center: ['editor', 'chat'], right: [], bottom: ['terminal'] }, hidden: ['status', 'editor'] }));
  assert.deepEqual(moved.hidden, ['status', 'editor']);
});

test('layout: kept per device beside the model; a body names what it sets, the rest stays; null forgets; a broken file keeps what fits', () => {
  const dir = tmp('bnprefs-layout');
  let t = 1_700_000_000_000;
  const p = new UserPrefs({ dir, now: () => t });
  assert.equal(p.read().layout, undefined, 'none kept: no layout field, as before');
  const tablet = layoutOne({ pane: 'center', hidden: [] });
  assert.deepEqual(p.set({ layout: { desktop: layoutOne() } }), { model: null, settingsDefault: null, at: t, layout: { desktop: layoutOne() } });
  t += 5;
  // a layout alone never touches the model, a model alone never touches the layouts
  p.set({ model: 'claude-haiku-5-5', settingsDefault: null });
  assert.deepEqual(p.read(), { model: 'claude-haiku-5-5', settingsDefault: null, at: t, layout: { desktop: layoutOne() } });
  t += 5;
  p.set({ layout: { tablet } });
  assert.deepEqual(p.read(), { model: 'claude-haiku-5-5', settingsDefault: null, at: t, layout: { desktop: layoutOne(), tablet } });
  assert.deepEqual(new UserPrefs({ dir }).read().layout.tablet, tablet, 'another process reads the same');
  // null forgets one device's (back at the default), then both
  p.set({ layout: { desktop: null } });
  assert.deepEqual(Object.keys(p.read().layout), ['tablet']);
  p.set({ layout: null });
  assert.equal(p.read().layout, undefined);
  assert.equal(p.read().model, 'claude-haiku-5-5');
  // a layout that does not fit changes nothing
  p.set({ layout: { desktop: layoutOne() } });
  assert.throws(() => p.set({ layout: { desktop: layoutOne({ hidden: ['chat'] }) } }), (e) => e.status === 400);
  assert.throws(() => p.set({ model: 'claude-opus-5-5', layout: { tablet: { ...tablet, pane: 'x' } } }), (e) => e.status === 400);
  assert.equal(p.read().model, 'claude-haiku-5-5');
  assert.deepEqual(Object.keys(p.read().layout), ['desktop']);
  // the file: 0600, a layout in it that no longer fits reads as none while the model stays
  const file = path.join(dir, 'prefs', 'prefs.json');
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  const kept = JSON.parse(fs.readFileSync(file, 'utf8'));
  fs.writeFileSync(file, JSON.stringify({ ...kept, layout: { desktop: { ...layoutOne(), hidden: ['chat'] }, tablet } }));
  assert.deepEqual(Object.keys(p.read().layout), ['tablet']);
  assert.equal(p.read().model, 'claude-haiku-5-5');
  fs.writeFileSync(file, JSON.stringify({ ...kept, model: 'opus', layout: { tablet } }));
  assert.equal(p.read().model, null);
  assert.deepEqual(p.read().layout.tablet, tablet, 'a bad model does not take the layout with it');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('layout over the API: /api/state carries it, PUT keeps a device\'s, a bad one is 400, a body over the 4 KB cap is refused', async () => {
  const dir = tmp('bnprefs-layout-api');
  const dist = stubDist('bnprefslayoutdist');
  const srv = createServer({ secret: SECRET, query: fakeQuery(), spawn: () => {}, call: async () => { throw new Error('no sandbox here'); }, distDir: dist,
    logger: () => {}, userPrefs: new UserPrefs({ dir }) });
  await new Promise((r) => srv.server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${srv.server.address().port}`;
  const go = async (method, p, body) => {
    const r = await fetch(base + p, { method, headers: { 'X-Bn-Code-Proxy': SECRET, ...(body !== undefined ? { 'Content-Type': 'application/json', Origin: base } : {}) },
      body: body !== undefined ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined });
    return { status: r.status, json: await r.json().catch(() => null) };
  };
  try {
    assert.equal((await go('GET', '/api/state')).json.prefs.layout, undefined);
    await go('PUT', '/api/prefs', { model: 'claude-haiku-5-5', settingsDefault: null });
    const mine = layoutOne({ place: { left: ['explorer', 'search', 'sessions'], center: ['editor'], right: ['chat', 'git'], bottom: ['terminal'] }, hidden: ['terminal', 'status'] });
    const put = await go('PUT', '/api/prefs', { layout: { desktop: mine } });
    assert.equal(put.status, 200);
    assert.deepEqual(put.json.prefs.layout, { desktop: mine });
    assert.equal(put.json.prefs.model, 'claude-haiku-5-5', 'the model is where it was');
    // another browser reads the same, from /api/state and /api/prefs
    assert.deepEqual((await go('GET', '/api/state')).json.prefs.layout, { desktop: mine });
    assert.deepEqual((await go('GET', '/api/prefs')).json.prefs.layout, { desktop: mine });
    // the round trip: a layout of both devices, as the page sends it, comes back whole
    const both = await go('PUT', '/api/prefs', { layout: { tablet: layoutOne({ pane: 'center' }) } });
    assert.deepEqual(Object.keys(both.json.prefs.layout).sort(), ['desktop', 'tablet']);
    // a bad one is 400 and nothing changes
    assert.equal((await go('PUT', '/api/prefs', { layout: { desktop: layoutOne({ hidden: ['chat'] }) } })).status, 400);
    assert.equal((await go('PUT', '/api/prefs', { layout: { desktop: layoutOne({ place: { left: [], center: [], right: [], bottom: [] } }) } })).status, 400);
    assert.deepEqual((await go('GET', '/api/prefs')).json.prefs.layout.desktop, mine);
    // the cap stays 4 KB: both layouts and the model are well under it, a body past it is refused unread
    const most = layoutOne({ sizes: Object.fromEntries(['explorer', 'search', 'git', 'sessions', 'editor', 'terminal', 'chat', 'status'].map((k) => [k, 2000])), hidden: ['explorer', 'search', 'git', 'sessions', 'editor', 'terminal', 'status'] });
    const full = JSON.stringify({ model: 'x'.repeat(128), settingsDefault: 'y'.repeat(128), layout: { desktop: most, tablet: most } });
    assert.ok(full.length < 4096, `the fullest body is ${full.length} bytes`);
    const huge = await go('PUT', '/api/prefs', JSON.stringify({ layout: { desktop: layoutOne({ sizes: {} }) }, pad: 'x'.repeat(5000) }));
    assert.ok(huge.status === 413 || huge.status === 400, `status ${huge.status}`);
    assert.deepEqual((await go('GET', '/api/prefs')).json.prefs.layout.desktop, mine);
    // null forgets
    assert.equal((await go('PUT', '/api/prefs', { layout: { tablet: null } })).json.prefs.layout.tablet, undefined);
  } finally {
    srv.mgr.closeAll(); srv.wss.close(); srv.server.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(dist, { recursive: true, force: true });
  }
});
