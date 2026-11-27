// Gemini CLI as a Code page harness (code/server/agents/acp.mjs): a stand-in that behaves like 0.65.0 (fake-gemini.mjs) —
// its modes (never autoEdit or yolo), a mode taken on set_mode's answer alone (it sends no current_mode_update), its two
// refusals without a login (never an authenticate), its own sign-in screen on stdout (stopped at once), its models.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { AcpAgent, NotSignedIn, UnsafeMode, SAFE_MODES } from '../server/agents/acp.mjs';
import { Peer } from '../server/agents/jsonrpc.mjs';
import { HARNESSES, harnessOk, parseChatModel } from '../server/agents/tools.mjs';
import { fakeProc } from './fake-agent-proc.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const gemini = (scenario = 'ok', seenFile = null) => spawn(process.execPath, [path.join(HERE, 'fake-gemini.mjs')],
  { env: { ...process.env, FAKE: scenario, ...(seenFile ? { FAKE_SEEN: seenFile } : {}) }, stdio: ['pipe', 'pipe', 'pipe'] });
const seenFile = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'gem-')), 'seen');
const lines = (f) => (fs.existsSync(f) ? fs.readFileSync(f, 'utf8').split('\n').filter(Boolean) : []);
const make = (scenario, f = null) => { const proc = gemini(scenario, f); return { proc, agent: new AcpAgent(proc, { tool: 'gemini' }) }; };

test('Gemini: a Code harness that is not in Chat; only the modes that ask', () => {
  assert.deepEqual(HARNESSES.gemini, { id: 'gemini', name: 'Gemini CLI', provider: 'Google', plan: 'your Gemini CLI sign-in', kind: 'acp', noChat: true });
  assert.ok(harnessOk('gemini'));
  assert.equal(parseChatModel('plan-gemini'), null);
  assert.deepEqual([...SAFE_MODES.gemini], ['default', 'plan']);
});

test('Gemini: models listed, its modes safe, the page\'s Plan switched to; autoEdit and yolo never asked for, no authenticate', async () => {
  const f = seenFile();
  const { agent } = make('ok', f);
  try {
    await agent.init();
    await agent.open({ cwd: '/workspace' });
    assert.deepEqual(agent.models, [{ id: 'gemini-x-pro', name: 'Gemini X Pro' }, { id: 'gemini-x-flash', name: 'Gemini X Flash' }]);
    assert.equal(agent.model, 'gemini-x-pro');
    assert.equal(await agent.setMode('plan'), 'plan');
    assert.equal(await agent.setMode('default'), 'default');
    // Accept edits and Read only never reach autoEdit: Accept edits stays on default, Read only goes to plan
    assert.equal(await agent.setMode('acceptEdits'), 'default');
    assert.equal(await agent.setMode('readOnly'), 'plan');
    assert.equal(agent.safe('autoEdit'), false);
    assert.equal(agent.safe('yolo'), false);
    const r = await agent.prompt('hi');
    assert.equal(r.stop, 'end_turn');
    assert.deepEqual(lines(f).filter((l) => !/^set_mode (plan|default)$/.test(l)), []);
  } finally { agent.close(); }
});

test('Gemini: a session that starts in autoEdit is moved to default, taken on the set_mode answer alone', async () => {
  const f = seenFile();
  const { agent } = make('start-autoedit', f);
  try {
    await agent.init();
    await agent.open({ cwd: '/workspace' });
    assert.equal(agent.mode, 'default');
    assert.deepEqual(lines(f), ['set_mode default']);
    await agent.prompt('x');
  } finally { agent.close(); }
  // yolo too
  const g = make('start-yolo');
  try { await g.agent.init(); await g.agent.open({ cwd: '/workspace' }); assert.equal(g.agent.mode, 'default'); } finally { g.agent.close(); }
});

test('Gemini: "Gemini API key is missing" and "Authentication required" are not signed in, and authenticate is never sent', async () => {
  for (const scenario of ['no-key', 'no-auth']) {
    const f = seenFile();
    const { agent } = make(scenario, f);
    try {
      await agent.init();
      assert.ok(agent.authMethods.includes('oauth-personal'));
      await assert.rejects(agent.open({ cwd: '/workspace' }), (e) => e instanceof NotSignedIn && /Terminal/.test(e.message));
    } finally { agent.close(); }
    assert.deepEqual(lines(f), [], scenario);
  }
  // (one that names a default method, as a later version might: never sent either)
  const f = seenFile();
  const { agent } = make('default-auth', f);
  try {
    await agent.init();
    assert.equal(agent.defaultAuth, 'oauth-personal');
    await assert.rejects(agent.open({ cwd: '/workspace' }), (e) => e instanceof NotSignedIn && /Terminal/.test(e.message));
  } finally { agent.close(); }
  assert.deepEqual(lines(f), []);
});

test('Gemini: "allow always" is never offered to the page nor sent (its own moves the session to autoEdit unsaid)', async () => {
  const f = seenFile();
  const asked = [];
  const proc = gemini('ask-always', f);
  const agent = new AcpAgent(proc, { tool: 'gemini', onPermission: async (q) => { asked.push(q); return 'always'; } });
  try {
    await agent.init();
    await agent.open({ cwd: '/workspace' });
    const r = await agent.prompt('write a.txt');
    assert.equal(r.stop, 'end_turn');
    assert.equal(asked.length, 1);
    assert.equal(asked[0].always, false);
    assert.deepEqual(lines(f), ['permission proceed_once']);
  } finally { agent.close(); }
});

test('Gemini: its sign-in screen in initialize or in a turn is not signed in too', async () => {
  for (const at of ['stale-init', 'stale-prompt']) {
    const { agent } = make(at);
    try {
      const t0 = Date.now();
      const go = async () => { await agent.init(); await agent.open({ cwd: '/workspace' }); await agent.prompt('x'); };
      await assert.rejects(go(), (e) => e instanceof NotSignedIn && /sign in again/.test(e.message), at);
      assert.ok(Date.now() - t0 < 5000, at);
    } finally { agent.close(); }
  }
});

test('Gemini: its sign-in screen on stdout (escape codes, then a wait on stdin) is not signed in at once, and the process is killed', async () => {
  for (const scenario of ['stale', 'stale-partial']) {
    const { proc, agent } = make(scenario);
    const t0 = Date.now();
    try {
      await agent.init();
      await assert.rejects(agent.open({ cwd: '/workspace' }), (e) => e instanceof NotSignedIn && /sign in again/.test(e.message));
      assert.ok(Date.now() - t0 < 5000, `${scenario}: ${Date.now() - t0} ms`);
      if (proc.exitCode === null && proc.signalCode === null) await once(proc, 'exit');
      assert.ok(proc.signalCode === 'SIGKILL' || proc.exitCode !== null);
    } finally { agent.close(); }
  }
});

test('Gemini: the same screen while a session is taken up (session/load) is not signed in either', async () => {
  const { agent } = make('stale');
  try {
    await agent.init();
    await assert.rejects(agent.open({ cwd: '/workspace', resume: 'g-9' }), NotSignedIn);
  } finally { agent.close(); }
});

test('other tools: a mode not reported (no current_mode_update) is still not taken (only Gemini\'s answer counts as the report)', async () => {
  // Cursor's stand-in that says yes to set_mode and stays where it is: not taken, the session ends
  const events = [];
  const agent = new AcpAgent(fakeProc('acp', 'silent-set', 'cursor'), { tool: 'cursor', onEvent: (e) => events.push(e) });
  try {
    await agent.init();
    await assert.rejects(agent.open({ cwd: '/workspace' }), UnsafeMode);
  } finally { agent.close(); }
});

test('jsonrpc: onTerminal fires once, on a raw ESC byte only, even in a line with no end; without a hook nothing happens', async () => {
  const mk = (hook) => {
    const proc = spawn(process.execPath, ['-e', 'process.stdin.resume()'], { stdio: ['pipe', 'pipe', 'pipe'] });
    return { proc, peer: new Peer(proc, { ...(hook ? { onTerminal: hook } : {}) }) };
  };
  let n = 0;
  const a = mk(() => { n++; });
  a.peer.data('{"jsonrpc":"2.0","method":"x","params":{"s":"\\u001b[0m"}}\n');   // (JSON's own escape: no ESC byte)
  assert.equal(n, 0);
  a.peer.data('plain text without an end ');
  assert.equal(n, 0);
  a.peer.data('\x1b[?1049h');
  a.peer.data('\x1b[2J\n');
  assert.equal(n, 1);
  const b = mk(null);
  b.peer.data('\x1b[2J\n');
  assert.equal(b.peer.done, false);
  for (const x of [a, b]) { x.proc.kill('SIGKILL'); await once(x.proc, 'exit'); }
});
