// Stand-ins for your subscriptions' agents, from their protocols' own shapes (no vendor's code, no network): an ACP
// agent (Copilot, Cursor, Grok) and Codex's app server, each a Node process speaking JSON lines on stdin/stdout, driven
// by FAKE (a scenario) — the tests' sandboxAgent. Run: node fake-agents.mjs acp|codex
import readline from 'node:readline';

const kind = process.argv[2];
const scenario = process.env.FAKE || 'ok';
const send = (o) => process.stdout.write(`${JSON.stringify(kind === 'acp' ? { jsonrpc: '2.0', ...o } : o)}\n`);
const log = (s) => process.stderr.write(`${s}\n`);
let next = 1000;
const waiting = new Map();
const ask = (method, params) => new Promise((resolve) => { const id = next++; waiting.set(id, resolve); send({ id, method, params }); });
let signedIn = scenario !== 'signed-out';
const sessions = new Map();   // ACP: sessionId -> {cwd, history: [text]}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  if (m.id !== undefined && !m.method) { waiting.get(m.id)?.(m); waiting.delete(m.id); return; }
  if (process.env.FAKE_LOG) log(`got ${m.method}`);
  try {
    const r = kind === 'acp' ? await acp(m) : await codex(m);
    if (m.id !== undefined && r !== undefined) send({ id: m.id, ...r });
  } catch (e) { if (m.id !== undefined) send({ id: m.id, error: { code: -32603, message: String(e.message) } }); }
});

const update = (sessionId, u) => send({ method: 'session/update', params: { sessionId, update: u } });

async function acp(m) {
  switch (m.method) {
    case 'initialize':
      return { result: { protocolVersion: 1, agentCapabilities: { loadSession: scenario !== 'no-load', promptCapabilities: { image: true } },
        authMethods: scenario === 'cursor-auth' ? [{ id: 'cursor_login', name: 'Cursor Login' }] : [{ id: 'agent-login', name: 'Log in' }],
        agentInfo: { name: 'fake', version: '9.9.9' } } };
    case 'authenticate':
      if (m.params.methodId === 'cursor_login') { signedIn = true; return { result: {} }; }
      return { error: { code: -32000, message: 'that method starts a sign-in' } };
    case 'session/new': {
      if (!signedIn || scenario === 'cursor-auth' && !signedIn) return { error: { code: -32000, message: 'Authentication required' } };
      const id = `sess-${Object.keys(Object.fromEntries(sessions)).length + 1}`;
      sessions.set(id, { cwd: m.params.cwd, history: [] });
      return { result: { sessionId: id, modes: { currentModeId: 'agent', availableModes: [{ id: 'agent', name: 'Agent' }, { id: 'plan', name: 'Plan' }, { id: 'ask', name: 'Ask' }, { id: 'yolo', name: 'YOLO' }] },
        models: { currentModelId: 'fast-1', availableModels: [{ modelId: 'fast-1', name: 'Fast' }, { modelId: 'smart-2', name: 'Smart' }] } } };
    }
    case 'session/load': {
      const s = sessions.get(m.params.sessionId) ?? (scenario === 'remembers' ? { cwd: m.params.cwd, history: ['(earlier)'] } : null);
      if (!s) return { error: { code: -32002, message: 'no such session' } };
      sessions.set(m.params.sessionId, s);
      for (const h of s.history) update(m.params.sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: `replayed ${h}` } });
      return { result: { modes: { currentModeId: 'agent', availableModes: [{ id: 'agent', name: 'Agent' }] } } };
    }
    case 'session/set_mode': return { result: {} };
    case 'session/set_model': return { result: {} };
    case 'session/cancel': return undefined;
    case 'session/prompt': {
      const sid = m.params.sessionId;
      const text = (m.params.prompt.find((b) => b.type === 'text') || {}).text || '';
      const s = sessions.get(sid);
      if (s) s.history.push(text);
      if (scenario === 'long-line') { process.stdout.write(`${'x'.repeat(17 << 20)}\n`); return undefined; }
      update(sid, { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'thinking…' } });
      update(sid, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Hello ' } });
      update(sid, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: `you said: ${text.slice(-40)}` } });
      if (scenario === 'tools' || scenario === 'chat-tools') {
        update(sid, { sessionUpdate: 'tool_call', toolCallId: 'call/1 é', title: 'Edit app.js', kind: 'edit', status: 'pending' });
        update(sid, { sessionUpdate: 'tool_call_update', toolCallId: 'call/1 é', content: [{ type: 'diff', path: '/workspace/app.js', oldText: 'a\n', newText: 'b\n' }] });
        const r = await ask('session/request_permission', { sessionId: sid, toolCall: { toolCallId: 'call/1 é' },
          options: [{ optionId: 'ok1', name: 'Allow', kind: 'allow_once' }, { optionId: 'okA', name: 'Always', kind: 'allow_always' }, { optionId: 'no1', name: 'Reject', kind: 'reject_once' }] });
        const picked = r.result?.outcome?.optionId ?? 'cancelled';
        update(sid, { sessionUpdate: 'tool_call_update', toolCallId: 'call/1 é', status: picked.startsWith('ok') ? 'completed' : 'failed',
          content: [{ type: 'content', content: { type: 'text', text: `permission: ${picked}` } }] });
        update(sid, { sessionUpdate: 'tool_call', toolCallId: 'run-2', title: 'Run tests', kind: 'execute', status: 'in_progress', rawInput: { command: ['npm', 'test'] } });
        update(sid, { sessionUpdate: 'tool_call_update', toolCallId: 'run-2', status: 'completed', content: [{ type: 'content', content: { type: 'text', text: '3 passed' } }] });
        update(sid, { sessionUpdate: 'plan', entries: [{ content: 'write it', priority: 'high', status: 'completed' }, { content: 'test it', priority: 'high', status: 'in_progress' }] });
        // a request this client never offers: refused
        const fsr = await ask('fs/read_text_file', { sessionId: sid, path: '/etc/passwd' });
        update(sid, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: ` fs:${fsr.error ? fsr.error.code : 'read'}` } });
      }
      return { result: { stopReason: 'end_turn', usage: { inputTokens: 120, outputTokens: 30, cachedReadTokens: 10 } } };
    }
    default: return { error: { code: -32601, message: 'not here' } };
  }
}

let thread = null, turnN = 0;
async function codex(m) {
  const p = m.params || {};
  switch (m.method) {
    case 'initialize': return { result: { userAgent: 'fake/0', codexHome: '/home/claude/.codex' } };
    case 'initialized': return undefined;
    case 'account/read': return { result: signedIn ? { account: { type: 'chatgpt', email: 'x@example.com' }, requiresOpenaiAuth: true } : { account: null, requiresOpenaiAuth: true } };
    case 'model/list': return { result: { data: [{ id: 'gpt-x', displayName: 'GPT X', hidden: false }, { id: 'hidden-1', displayName: 'H', hidden: true }], nextCursor: null } };
    case 'thread/start':
      thread = { id: `thr-${++turnN}`, policy: p };
      log(`thread/start ${JSON.stringify({ approvalPolicy: p.approvalPolicy, sandbox: p.sandbox, dev: Boolean(p.developerInstructions) })}`);
      return { result: { thread: { id: thread.id }, model: 'gpt-x' } };
    case 'thread/resume':
      if (p.threadId !== 'thr-known') return { error: { code: -32600, message: 'no rollout' } };
      thread = { id: p.threadId }; return { result: { thread: { id: p.threadId }, model: 'gpt-x' } };
    case 'turn/start': {
      const tid = 'turn-1';
      const text = (p.input || []).find((x) => x.type === 'text')?.text || '';
      log(`turn/start ${JSON.stringify({ approvalPolicy: p.approvalPolicy, sandboxPolicy: p.sandboxPolicy ?? null })}`);
      setTimeout(async () => {
        const n = (method, params) => send({ method, params: { threadId: thread.id, turnId: tid, ...params } });
        n('item/reasoning/summaryTextDelta', { itemId: 'r1', delta: 'hmm', summaryIndex: 0 });
        n('item/agentMessage/delta', { itemId: 'm1', delta: 'Sure: ' });
        n('item/agentMessage/delta', { itemId: 'm1', delta: text.slice(-30) });
        n('item/completed', { item: { type: 'agentMessage', id: 'm1', text: `Sure: ${text.slice(-30)}` } });
        if (scenario === 'tools') {
          n('item/started', { item: { type: 'commandExecution', id: 'c1', command: 'rm -rf build', cwd: '/workspace', status: 'inProgress' } });
          const r = await ask('item/commandExecution/requestApproval', { threadId: thread.id, turnId: tid, itemId: 'c1', command: 'rm -rf build', cwd: '/workspace', startedAtMs: 0 });
          const ok = r.result?.decision === 'accept' || r.result?.decision === 'acceptForSession';
          n('item/completed', { item: { type: 'commandExecution', id: 'c1', command: 'rm -rf build', status: ok ? 'completed' : 'declined', exitCode: ok ? 0 : null, aggregatedOutput: ok ? 'done' : '' } });
          n('item/started', { item: { type: 'fileChange', id: 'f1', status: 'inProgress', changes: [{ path: '/workspace/a.js', kind: { type: 'update', move_path: null }, diff: '@@ -1,2 +1,2 @@\n-a\n+b\n c\n' }] } });
          n('item/completed', { item: { type: 'fileChange', id: 'f1', status: 'completed', changes: [{ path: '/workspace/a.js', kind: { type: 'update', move_path: null }, diff: '@@ -1,2 +1,2 @@\n-a\n+b\n c\n' }] } });
          n('turn/plan/updated', { explanation: null, plan: [{ step: 'build', status: 'inProgress' }] });
          const tok = await ask('account/chatgptAuthTokens/refresh', {});
          n('item/agentMessage/delta', { itemId: 'm2', delta: ` refresh:${tok.error ? 'refused' : 'answered'}` });
        }
        n('thread/tokenUsage/updated', { tokenUsage: { last: { totalTokens: 50, inputTokens: 40, cachedInputTokens: 5, cacheWriteInputTokens: 0, outputTokens: 10, reasoningOutputTokens: 0 }, total: {}, modelContextWindow: null } });
        send({ method: 'account/rateLimits/updated', params: { rateLimits: { primary: { usedPercent: 42.4, windowDurationMins: 300, resetsAt: 1792800000 }, secondary: null } } });
        n('turn/completed', { turn: { id: tid, status: scenario === 'fail' ? 'failed' : 'completed', error: scenario === 'fail' ? { message: 'usage limit reached' } : null } });
      }, 10);
      return { result: { turn: { id: tid, status: 'inProgress' } } };
    }
    case 'turn/interrupt': return { result: {} };
    default: return { error: { code: -32601, message: 'not here' } };
  }
}
