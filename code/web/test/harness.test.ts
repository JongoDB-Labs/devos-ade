import { test } from 'node:test';
import assert from 'node:assert/strict';
import { harnessOf, normEvent, normPlan, normServerMsg } from '../src/api';
import { planText, harnessState } from '../src/components/Pickers';
import { applyEvent, newView } from '../src/session';

const S = '3f2a7c1e-9b4d-4e8a-a1c2-0d9e8f7a6b5c';

test('who answers: only the known harnesses (anything else is Claude Code on Bedrock)', () => {
  for (const h of ['bedrock', 'claude', 'codex', 'copilot', 'cursor', 'grok']) assert.equal(harnessOf(h), h);
  for (const h of ['gemini', 'toString', '<b>', null, 3]) assert.equal(harnessOf(h), 'bedrock');
});

test('a plan\'s usage: tokens and turns only, its limits checked; never a dollar figure', () => {
  assert.deepEqual(normPlan({ input: 1200, output: 30.7, cached: -5, turns: 2, usd: 9, limits: [{ label: '5-hour', usedPercent: 42.4, resetsAt: 1792800000000 }, { label: 7 }, 'x'] }),
    { input: 1200, output: 30, cached: 0, turns: 2, limits: [{ label: '5-hour', usedPercent: 42, resetsAt: 1792800000000 }] });
  assert.equal(normPlan(null), null);
  const t = planText({ input: 1000, output: 200, cached: 500, turns: 3, limits: [{ label: 'weekly', usedPercent: 80, resetsAt: null }] }, 'your ChatGPT plan');
  assert.equal(t.short, '1.5k in · 200 out');
  assert.match(t.long, /^On your ChatGPT plan: .* 3 turns in this session\. No dollars/);
  assert.match(t.long, /weekly: 80% used/);
  assert.doesNotMatch(t.long + t.short, /\$/);
});

test('an agent\'s init says who answers and its models; the session view takes them; a state message carries its plan', () => {
  const ev = normEvent({ type: 'init', model: 'gpt-x', harness: 'codex', models: [{ id: 'gpt-x', name: 'GPT X' }, { id: '<script>', name: 'bad' }, { id: 'o3', name: '<b>' }] });
  assert.equal(ev?.kind, 'init');
  if (ev?.kind !== 'init') return;
  assert.equal(ev.init.harness, 'codex');
  assert.deepEqual(ev.init.models?.map((m) => m.id), ['gpt-x', 'o3']);
  const v = applyEvent(newView(S), ev);
  assert.equal(v.harness, 'codex');
  const m = normServerMsg(JSON.stringify({ type: 'session_state', session: S, state: 'idle', model: 'gpt-x', mode: 'default', harness: 'copilot', plan: { input: 1, output: 2, cached: 0, turns: 1, limits: [] } }));
  assert.equal(m?.kind === 'session_state' && m.harness, 'copilot');
  assert.deepEqual(m?.kind === 'session_state' && m.plan, { input: 1, output: 2, cached: 0, turns: 1, limits: [] });
});

test('the picker: a subscription that can start, and why one cannot', () => {
  const h = { id: 'codex' as const, name: 'Codex', provider: 'OpenAI', plan: 'your ChatGPT plan', installed: true, signed: 'yes' as const, allowed: true };
  assert.deepEqual(harnessState(h), { ok: true, says: 'signed in' });
  assert.deepEqual(harnessState({ ...h, signed: 'unknown' }), { ok: true, says: 'sign-in not known here' });
  assert.match(harnessState({ ...h, signed: 'no' }).says, /sign in first: the terminal's Open › Codex/);
  assert.equal(harnessState({ ...h, installed: false }).ok, false);
  assert.match(harnessState({ ...h, allowed: false }).says, /Settings › Claude Code › Your AI subscriptions/);
});
