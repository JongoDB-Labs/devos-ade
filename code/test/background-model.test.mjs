// Claude Code's own background work (titles, summaries, its Explore subagent: its "haiku" model) and its subagents in a
// Code page session: on the session's model when that is not one of Bedrock's Claude models (validate.mjs
// backgroundModel, bn-coded's backgroundEnv), Haiku as the sandbox says otherwise; a model switch that changes it
// restarts the process at the next prompt (sessions.mjs). With a stand-in SDK.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { backgroundModel } from '../server/validate.mjs';
import { SessionManager } from '../server/sessions.mjs';
import { PermissionBroker } from '../server/broker.mjs';
import { fakeQuery } from './fake-sdk.mjs';

const tick = (ms = 20) => new Promise((r) => setTimeout(r, ms));

test('the background model: the session\'s own unless it is one of Bedrock\'s Claude models (or an alias, or none)', () => {
  for (const m of ['xl/glm-5.3-uncensored:free', 'or/google/gemma-4-31b-it:free', 'or/anthropic/claude-sonnet-4.5', 'mistral-large-3', 'llama-3-3-70b'])
    assert.equal(backgroundModel(m), m, m);
  assert.equal(backgroundModel('xl/qwen3.8-27b[1m]'), 'xl/qwen3.8-27b');
  for (const m of ['claude-haiku-5-5', 'claude-sonnet-5-5', 'Claude-Opus-5-5', 'claude-sonnet-5', 'haiku', 'sonnet', 'opus[1m]', 'default', '', null, undefined, 'bad model'])
    assert.equal(backgroundModel(m), '', String(m));
});

function manager() {
  const queries = [], events = [];
  const mgr = new SessionManager({ broker: new PermissionBroker({}), spawn: () => { throw new Error('not used'); }, log: () => {},
    query: (a) => { const q = fakeQuery([])(a); queries.push(q); return q; }, onEvent: (s, seq, ev) => events.push(ev) });
  return { mgr, queries, events };
}
const restarted = (events) => events.filter((e) => e.type === 'local' && /^Restarting Claude Code for this session so its own background work/.test(e.text)).length;

test('a new session on a free model starts on it; a switch to Claude, or back, restarts it at the next prompt, once', async () => {
  const { mgr, queries, events } = manager();
  const s = mgr.get(mgr.open({ model: 'xl/glm-5.3-uncensored:free' }).id);
  assert.equal(queries.length, 1);
  assert.equal(queries[0].options.model, 'xl/glm-5.3-uncensored:free', 'its first request is on the model picked');
  s.prompt({ text: 'one' });
  await tick();
  assert.equal(queries.length, 1, 'nothing changed: no restart');
  // to a Claude model: Claude Code's own work goes back to Haiku — a new process, resumed, on that model
  await s.setModel('claude-sonnet-5-5');
  s.prompt({ text: 'two' });
  await tick();
  assert.equal(queries.length, 2);
  assert.equal(queries[1].options.resume, s.id);
  assert.equal(queries[1].options.model, 'claude-sonnet-5-5');
  assert.equal(restarted(events), 1);
  s.prompt({ text: 'three' });
  await tick();
  assert.equal(queries.length, 2, 'the same model since the restart: no restart');
  // between two Claude models: Haiku either way, no restart
  await s.setModel('claude-opus-5-5');
  s.prompt({ text: 'four' });
  await tick();
  assert.equal(queries.length, 2);
  // to another free model: restarted on it
  await s.setModel('or/google/gemma-4-31b-it:free');
  s.prompt({ text: 'five' });
  await tick();
  assert.equal(queries.length, 3);
  assert.equal(queries[2].options.model, 'or/google/gemma-4-31b-it:free');
  assert.equal(restarted(events), 2);
});

test('a session with no model named (Claude Code\'s default, a Claude model) and one on Claude are never restarted for it', async () => {
  const { mgr, queries } = manager();
  const a = mgr.get(mgr.open({}).id);
  const b = mgr.get(mgr.open({ model: 'claude-haiku-5-5' }).id);
  a.prompt({ text: 'x' }); b.prompt({ text: 'y' });
  await tick();
  a.prompt({ text: 'x2' }); b.prompt({ text: 'y2' });
  await tick();
  assert.equal(queries.length, 2);
  assert.equal(queries[0].options.model, undefined);
});
