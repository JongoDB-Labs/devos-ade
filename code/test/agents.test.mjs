// Your subscriptions' agents (code/server/agents): the ACP client (Copilot, Cursor, Grok) and Codex's app-server client
// against stand-ins speaking their protocols (fake-agents.mjs: no vendor's code), what the page sees of them (map.mjs),
// their permission questions and the page's modes, a sign-in that is missing, and what a hostile agent cannot do.
import test from 'node:test';
import assert from 'node:assert/strict';
import { AcpAgent, NotSignedIn } from '../server/agents/acp.mjs';
import { CodexAgent, rateLimits } from '../server/agents/codex.mjs';
import { acpCall, parseDiff, callId, codexPlan } from '../server/agents/map.mjs';
import { toolOfChatModel, chatModelId, harnessOk } from '../server/agents/tools.mjs';

import { fakeProc } from './fake-agent-proc.mjs';

function acp(scenario, opts = {}) {
  const events = [], asked = [];
  const agent = new AcpAgent(fakeProc('acp', scenario), { tool: 'copilot', onEvent: (e) => events.push(e),
    onPermission: async (p) => { asked.push(p); return opts.answer ?? 'once'; }, chat: opts.chat === true });
  return { agent, events, asked };
}

test('ACP: a session, an answer streamed and kept whole, its tokens; modes and models as the agent offers them', async () => {
  const { agent, events } = acp('ok');
  try {
    await agent.init();
    assert.equal(agent.agentVersion, '9.9.9');
    const o = await agent.open({ cwd: '/workspace' });
    assert.deepEqual(o, { ref: 'sess-1', resumed: false });
    assert.deepEqual(agent.models.map((m) => m.id), ['fast-1', 'smart-2']);
    assert.equal(agent.model, 'fast-1');
    const r = await agent.prompt('hi there');
    assert.equal(r.stop, 'end_turn');
    assert.deepEqual(r.usage, { input_tokens: 120, output_tokens: 30, cache_read_input_tokens: 10, cache_creation_input_tokens: 0 });
    assert.deepEqual(events.map((e) => e.type), ['thinking_delta', 'delta', 'delta', 'thinking', 'text']);
    assert.equal(events.at(-1).text, 'Hello you said: hi there');
    // the page's modes as the agent's: Plan and Read only to its planning or asking mode, never one that approves alone
    assert.equal(await agent.setMode('plan'), 'plan');
    assert.equal(await agent.setMode('readOnly'), 'ask');
    assert.equal(await agent.setMode('default'), 'agent');
    assert.equal(agent.agentModeFor('acceptEdits'), 'agent');
    agent.modes = [{ id: 'yolo', name: 'YOLO' }, { id: 'autopilot', name: 'Autopilot' }];
    assert.equal(agent.agentModeFor('plan'), null);
    await assert.rejects(agent.setModel('nope'), /does not offer that model/);
    await agent.setModel('smart-2');
    assert.equal(agent.model, 'smart-2');
  } finally { agent.close(); }
});

test('ACP: a tool call shown once its change is there, its permission asked through the page, a command, a plan; no file system of ours', async () => {
  const { agent, events, asked } = acp('tools', { answer: 'once' });
  try {
    await agent.init();
    await agent.open({ cwd: '/workspace' });
    await agent.prompt('change it');
    const uses = events.filter((e) => e.type === 'tool_use');
    assert.equal(uses[0].name, 'Edit');
    assert.deepEqual(uses[0].input, { file_path: '/workspace/app.js', old_string: 'a\n', new_string: 'b\n' });
    assert.match(uses[0].id, /^c[0-9a-f]{40}$/);   // (an id the page would refuse, made into one it keeps)
    assert.equal(asked.length, 1);
    assert.equal(asked[0].tool, 'Edit');
    assert.equal(asked[0].always, true);
    const res = events.filter((e) => e.type === 'tool_result');
    assert.equal(res[0].text, 'permission: ok1');
    assert.equal(res[0].is_error, false);
    assert.deepEqual(uses[1], { type: 'tool_use', id: 'run-2', name: 'Bash', input: { command: 'npm test', description: 'Run tests' }, parent: null });
    assert.equal(res[1].text, '3 passed');
    assert.equal(uses[2].name, 'TodoWrite');
    assert.deepEqual(uses[2].input.todos.map((t) => t.status), ['completed', 'in_progress']);
    // fs/read_text_file: not offered here (-32601)
    assert.match(events.filter((e) => e.type === 'text').at(-1).text, /fs:-32601/);
  } finally { agent.close(); }
});

test('ACP: Always, Deny; Read only and Plan refuse changes without asking; Accept edits allows edits; Chat refuses everything', async () => {
  for (const [answer, want] of [['always', 'okA'], ['deny', 'no1']]) {
    const { agent, events } = acp('tools', { answer });
    try { await agent.init(); await agent.open({ cwd: '/workspace' }); await agent.prompt('x'); } finally { agent.close(); }
    assert.equal(events.find((e) => e.type === 'tool_result').text, `permission: ${want}`);
  }
  for (const mode of ['readOnly', 'plan', 'acceptEdits']) {
    const { agent, events, asked } = acp('tools');
    try { await agent.init(); await agent.open({ cwd: '/workspace' }); await agent.setMode(mode); await agent.prompt('x'); } finally { agent.close(); }
    assert.equal(asked.length, 0, mode);
    assert.equal(events.find((e) => e.type === 'tool_result').text, mode === 'acceptEdits' ? 'permission: ok1' : 'permission: no1', mode);
    if (mode !== 'acceptEdits') assert.ok(events.some((e) => e.type === 'local' && /refused without asking/.test(e.text)), mode);
  }
  const { agent, events, asked } = acp('chat-tools', { chat: true });
  try { await agent.init(); await agent.open({ cwd: '/home/claude/.bn-chat/x' }); await agent.prompt('x'); } finally { agent.close(); }
  assert.equal(asked.length, 0);
  assert.equal(events.find((e) => e.type === 'tool_result').text, 'permission: no1');
});

test('ACP: its own login only — Cursor\'s existing one named back; a method that would start a sign-in never: not signed in', async () => {
  const c = acp('cursor-auth');
  try {
    await c.agent.init();
    // (signed out until authenticate names its existing login)
    assert.deepEqual(await c.agent.open({ cwd: '/workspace' }), { ref: 'sess-1', resumed: false });
  } finally { c.agent.close(); }
  const s = acp('signed-out');
  try {
    await s.agent.init();
    await assert.rejects(s.agent.open({ cwd: '/workspace' }), NotSignedIn);
  } finally { s.agent.close(); }
});

test('ACP: a session taken up again (its replay not shown twice); one the agent no longer has: a new one', async () => {
  const { agent, events } = acp('remembers');
  try {
    await agent.init();
    assert.deepEqual(await agent.open({ cwd: '/workspace', resume: 'sess-9' }), { ref: 'sess-9', resumed: true });
    assert.equal(events.length, 0);
  } finally { agent.close(); }
  const b = acp('ok');
  try {
    await b.agent.init();
    assert.deepEqual(await b.agent.open({ cwd: '/workspace', resume: 'gone' }), { ref: 'sess-1', resumed: false });
  } finally { b.agent.close(); }
});

test('ACP: a line longer than the cap ends the agent', async () => {
  const { agent } = acp('long-line');
  await agent.init();
  await agent.open({ cwd: '/workspace' });
  await assert.rejects(agent.prompt('x'), /ended/);
});

function codex(scenario, opts = {}) {
  const events = [], asked = [];
  const proc = fakeProc('codex', scenario);
  let err = '';
  proc.stderr.on('data', (d) => { err += d; });
  const agent = new CodexAgent(proc, { onEvent: (e) => events.push(e), onPermission: async (p) => { asked.push(p); return opts.answer ?? 'once'; }, chat: opts.chat === true });
  return { agent, events, asked, err: () => err };
}

test('Codex: signed in or not (account/read); a thread; a turn streamed, kept whole, its tokens and the plan\'s limits', async () => {
  const s = codex('signed-out');
  try { await assert.rejects(s.agent.init(), NotSignedIn); } finally { s.agent.close(); }
  const { agent, events, err } = codex('ok');
  try {
    await agent.init();
    assert.deepEqual(await agent.open({ cwd: '/workspace' }), { ref: 'thr-1', resumed: false });
    assert.deepEqual(agent.models.map((m) => m.id), ['gpt-x']);   // (hidden ones left out)
    const r = await agent.prompt('please');
    assert.equal(r.stop, 'end_turn');
    assert.deepEqual(r.usage, { input_tokens: 40, output_tokens: 10, cache_read_input_tokens: 5, cache_creation_input_tokens: 0 });
    assert.deepEqual(events.map((e) => e.type), ['thinking_delta', 'delta', 'delta', 'thinking', 'text']);
    assert.equal(events.at(-1).text, 'Sure: please');
    assert.deepEqual(agent.limits, [{ label: '5-hour', usedPercent: 42, resetsAt: 1792800000000 }]);
    // the Code page: Codex asks before what it does not count as safe; the container is the sandbox
    assert.match(err(), /thread\/start \{"approvalPolicy":"untrusted","dev":false\}/);
    assert.match(err(), /turn\/start \{"approvalPolicy":"untrusted","sandboxPolicy":\{"type":"externalSandbox","networkAccess":"enabled"\}\}/);
  } finally { agent.close(); }
});

test('Codex: a command asks through the page; a file change shown with its diff; a plan; its login never answered here', async () => {
  const { agent, events, asked } = codex('tools', { answer: 'once' });
  try {
    await agent.init(); await agent.open({ cwd: '/workspace' }); await agent.prompt('build');
    assert.deepEqual(asked[0], { tool: 'Bash', input: { command: 'rm -rf build', description: 'in /workspace' }, kind: 'execute', always: true });
    const use = events.filter((e) => e.type === 'tool_use');
    assert.equal(use[0].name, 'Bash');
    assert.equal(use[1].name, 'Edit');
    const res = events.filter((e) => e.type === 'tool_result');
    assert.equal(res[0].text, 'done');
    assert.deepEqual(res[1].edit.hunks, [{ oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: ['-a', '+b', ' c'] }]);
    assert.equal(use[2].name, 'TodoWrite');
    assert.ok(events.some((e) => e.type === 'delta' && e.text === ' refresh:refused'));
  } finally { agent.close(); }
  // Deny, Read only (refused without asking), Chat (never asks: read-only, no approvals)
  const d = codex('tools', { answer: 'deny' });
  try { await d.agent.init(); await d.agent.open({ cwd: '/workspace' }); await d.agent.prompt('x'); } finally { d.agent.close(); }
  assert.match(d.events.filter((e) => e.type === 'tool_result')[0].text, /declined/);
  const ro = codex('tools');
  try { await ro.agent.init(); await ro.agent.open({ cwd: '/workspace' }); await ro.agent.setMode('readOnly'); await ro.agent.prompt('x'); } finally { ro.agent.close(); }
  assert.equal(ro.asked.length, 0);
  const ch = codex('ok', { chat: true });
  try { await ch.agent.init(); await ch.agent.open({ cwd: '/home/claude/.bn-chat/x' }); await ch.agent.prompt('x'); } finally { ch.agent.close(); }
  assert.match(ch.err(), /thread\/start \{"approvalPolicy":"never","sandbox":"read-only","dev":true\}/);
  assert.match(ch.err(), /turn\/start \{"approvalPolicy":"never","sandboxPolicy":null\}/);
});

test('Codex: a failed turn says so; a thread it no longer has: a new one', async () => {
  const { agent } = codex('fail');
  try {
    await agent.init(); await agent.open({ cwd: '/workspace' });
    const r = await agent.prompt('x');
    assert.equal(r.stop, 'error');
    assert.equal(r.error, 'usage limit reached');
    assert.deepEqual(await agent.open({ cwd: '/workspace', resume: 'thr-known' }), { ref: 'thr-known', resumed: true });
    assert.deepEqual(await agent.open({ cwd: '/workspace', resume: 'thr-gone' }), { ref: 'thr-2', resumed: false });
  } finally { agent.close(); }
});

test('the page\'s card names and inputs; diffs; ids; plans; limits; the harness ids', () => {
  assert.deepEqual(acpCall({ kind: 'edit', title: 'x', content: [{ type: 'diff', path: '/w/a', newText: 'n' }] }), { name: 'Write', input: { file_path: '/w/a', content: 'n' } });
  assert.deepEqual(acpCall({ kind: 'read', rawInput: { path: '/w/a' } }), { name: 'Read', input: { file_path: '/w/a' } });
  assert.deepEqual(acpCall({ kind: 'search', rawInput: { pattern: 'TODO' } }), { name: 'Grep', input: { pattern: 'TODO' } });
  assert.deepEqual(acpCall({ kind: 'fetch', rawInput: { url: 'https://x' } }), { name: 'WebFetch', input: { url: 'https://x' } });
  assert.deepEqual(acpCall({ kind: 'think', title: 'Pondering' }), { name: 'Pondering', input: { title: 'Pondering' } });
  assert.deepEqual(acpCall({ kind: 'execute', title: 'no command' }), { name: 'no command', input: { title: 'no command' } });
  assert.deepEqual(parseDiff('junk\n@@ -3 +4,2 @@\n x\n+y\n\\ No newline at end of file').hunks, [{ oldStart: 3, oldLines: 1, newStart: 4, newLines: 2, lines: [' x', '+y'] }]);
  assert.equal(callId('toolu_01'), 'toolu_01');
  assert.equal(callId(''), null);
  assert.equal(callId('a'.repeat(1001)), null);
  assert.deepEqual(codexPlan({ plan: [{ step: 's', status: 'inProgress' }, { step: 7 }] }).todos, [{ content: 's', status: 'in_progress', activeForm: 's' }]);
  assert.deepEqual(rateLimits({ primary: { usedPercent: 10, windowDurationMins: 10080, resetsAt: null }, secondary: { usedPercent: 'x' } }), [{ label: 'weekly', usedPercent: 10, resetsAt: null }]);
  assert.equal(toolOfChatModel(chatModelId('codex')), 'codex');
  assert.equal(toolOfChatModel('plan-gemini'), null);
  assert.equal(toolOfChatModel('plan-codex2'), null);
  assert.ok(harnessOk('bedrock') && harnessOk('claude') && !harnessOk('gemini'));
});
