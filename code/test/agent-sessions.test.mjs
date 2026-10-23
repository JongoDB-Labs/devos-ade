// The Code page's sessions with your subscriptions (sessions.mjs + agents/session.mjs): who answers chosen per session —
// Claude on your plan only with Settings' switch, its spawn on the plan (no spend tag, no budget, Anthropic's own model
// names), an agent's session (Codex, Copilot …) through the page's same events and permission cards, its record and
// history kept by the page, taken up again later with the tool's own session, and what it does not have refused.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SessionManager, PLAN_OFF } from '../server/sessions.mjs';
import { PermissionBroker } from '../server/broker.mjs';
import { AgentStore } from '../server/agents/store.mjs';
import { fakeQuery } from './fake-sdk.mjs';
import { fakeProc } from './fake-agent-proc.mjs';
import { tmp } from './helpers.mjs';

const wait = async (cond, ms = 5000) => { const t0 = Date.now(); while (!cond()) { if (Date.now() - t0 > ms) throw new Error('timed out'); await new Promise((r) => setTimeout(r, 10)); } };
function manager(opts = {}) {
  const queries = [], events = [], asked = [], sent = [], spawns = [], agents = [];
  const fq = fakeQuery(sent);
  const broker = new PermissionBroker({ onAsk: (p) => asked.push(p) });
  const store = new AgentStore({ dir: tmp('bna') });
  const mgr = new SessionManager({ broker, spawn: (o, x) => { spawns.push(x); return null; },
    query: (a) => { const q = fq(a); queries.push(q); return q; },
    spawnAgent: (o) => { agents.push(o); return fakeProc(o.tool === 'codex' ? 'codex' : 'acp', opts.scenario ?? 'tools'); },
    agentStore: store, planAllowed: opts.plan === true, onEvent: (s, seq, ev) => events.push([s.id, ev]), ...opts.more });
  return { mgr, broker, queries, events, asked, sent, spawns, agents, store };
}

test('Claude on your plan: only with the switch; its process on the plan, no spend tag, no budget, its own model names', async () => {
  const off = manager();
  assert.throws(() => off.mgr.open({ harness: 'claude' }), (e) => e.message === PLAN_OFF && e.status === 409);
  off.mgr.closeAll();
  const { mgr, queries, spawns } = manager({ plan: true });
  assert.throws(() => mgr.open({ harness: 'gemini' }), /bad harness/);
  const { id } = mgr.open({ harness: 'claude', model: 'opus', budget: { usd: 5, hard: true } });
  const s = mgr.get(id);
  assert.equal(s.harness, 'claude');
  assert.equal(s.budget, null);
  assert.equal(queries[0].options.model, 'opus');
  assert.equal(queries[0].options.maxBudgetUsd, undefined);
  queries[0].options.spawnClaudeCodeProcess({ args: [] });
  assert.deepEqual(Object.keys(spawns[0]).sort(), ['onStderr', 'plan']);
  assert.equal(spawns[0].plan, true);
  assert.throws(() => s.setBudget({ usd: 3, hard: true }), /your Claude plan: no budget in dollars/);
  assert.deepEqual(s.setBudget({ usd: null }).budget, null);
  await s.setModel('sonnet');   // (an alias is Claude Code's own name on a plan)
  assert.equal(s.info().harness, 'claude');
  assert.deepEqual(s.info().plan, { input: 0, output: 0, cached: 0, turns: 0, limits: null });
  // a limit near, then reached: said in the conversation, kept for the meter
  s.notePlan({ type: 'rate_limit_event', rate_limit_info: { status: 'allowed_warning', rateLimitType: 'five_hour', utilization: 0.82, resetsAt: 1792800000 } });
  assert.deepEqual(s.info().plan.limits, [{ label: '5-hour', usedPercent: 82, resetsAt: 1792800000000, status: 'allowed_warning' }]);
  s.notePlan({ type: 'result', usage: { input_tokens: 10, cache_creation_input_tokens: 2, output_tokens: 3, cache_read_input_tokens: 5 } });
  assert.deepEqual({ ...s.info().plan, limits: null }, { input: 12, output: 3, cached: 5, turns: 1, limits: null });
  // a Bedrock session still refuses an alias and keeps its spend tag
  assert.throws(() => mgr.open({ model: 'opus' }), /name the model in full/);
  const b = mgr.open({ model: 'claude-haiku-5-5' });
  queries.at(-1).options.spawnClaudeCodeProcess({ args: [] });
  assert.equal(spawns.at(-1).litellmSession, b.id);
  assert.equal(mgr.get(b.id).harness, 'bedrock');
  mgr.closeAll();
});

test('an agent session: started at once in the project folder, the page\'s events, its permission card, its record and history', async () => {
  const { mgr, events, asked, agents, store, broker } = manager();
  const { id } = mgr.open({ harness: 'copilot', cwd: '/workspace/app', mode: 'auto' });
  const s = mgr.get(id);
  assert.equal(s.mode, 'default');   // (Auto is Claude Code's: an agent session starts in Manual)
  await wait(() => s.state === 'idle');
  assert.deepEqual(agents[0], { tool: 'copilot', mode: 'code', cwd: '/workspace/app' });
  const init = events.find(([, ev]) => ev.type === 'init')[1];
  assert.equal(init.harness, 'copilot');
  assert.deepEqual(init.models.map((m) => m.id), ['fast-1', 'smart-2']);
  s.prompt({ text: 'fix it' });
  await wait(() => asked.length === 1);
  assert.equal(asked[0].tool, 'Edit');
  assert.deepEqual(asked[0].rules, [{ text: 'copilot:Edit', destination: 'session' }]);
  broker.answer(asked[0].id, 'once');
  await wait(() => events.some(([, ev]) => ev.type === 'result'));
  const types = events.map(([, ev]) => ev.type);
  assert.ok(types.includes('user') && types.includes('tool_use') && types.includes('tool_result') && types.includes('text'), types.join());
  assert.equal(events.find(([, ev]) => ev.type === 'tool_result')[1].text, 'permission: ok1');
  const row = store.get(id);
  assert.equal(row.harness, 'copilot'); assert.equal(row.ref, 'sess-1'); assert.equal(row.cwd, '/workspace/app'); assert.equal(row.title, 'fix it');
  const hist = store.events(id).events.map((e) => e.type);
  assert.ok(hist.includes('user') && hist.includes('text') && !hist.includes('delta'), hist.join());
  assert.equal(s.info().plan.turns, 1);
  assert.equal(s.info().plan.input, 120);
  // what it does not have
  assert.throws(() => s.need(), /not offered for GitHub Copilot sessions/);
  assert.throws(() => s.setBudget({ usd: 1 }), /your Copilot plan: no budget in dollars/);
  assert.throws(() => s.prompt({ text: '/compact' }), /no slash commands here/);
  await assert.rejects(s.setMode('bypassPermissions'), /take Read only, Plan, Manual or Accept edits/);
  await s.setMode('plan');
  assert.equal(s.mode, 'plan');
  await s.setModel('smart-2');
  await assert.rejects(s.setModel('nope'), /does not offer that model/);
  await assert.rejects(s.toTerminal(), /not handed to the terminal/);
  // taken up again later: the page's record, the tool's own session
  s.close();
  assert.equal(s.state, 'ended');
  mgr.sessions.delete(id);
  const again = mgr.open({ harness: 'copilot', resume: id });
  assert.equal(again.id, id);
  const s2 = mgr.get(id);
  assert.equal(s2.cwd, '/workspace/app');
  assert.equal(s2.ref, 'sess-1');
  await wait(() => s2.state === 'idle' || s2.state === 'ended');
  assert.throws(() => mgr.open({ harness: 'codex', resume: id }), /GitHub Copilot's/);
  assert.throws(() => mgr.open({ harness: 'copilot', resume: '00000000-0000-4000-8000-000000000000' }), /record is gone/);
  assert.throws(() => mgr.open({ harness: 'copilot', resume: id, fork: true }), /cannot be forked/);
  mgr.closeAll();
});

test('an agent that is not signed in: the session says so (its own sign-in, in the terminal), nothing else starts', async () => {
  const { mgr } = manager({ scenario: 'signed-out' });
  const { id } = mgr.open({ harness: 'codex' });
  const s = mgr.get(id);
  await wait(() => s.state === 'ended');
  assert.match(s.error, /Codex is not signed in in the sandbox: open a terminal \(Open: Codex\) and sign in/);
  mgr.closeAll();
});
