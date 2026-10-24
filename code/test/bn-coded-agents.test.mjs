// bn-coded's side of your subscriptions (terminal/bin/bn-coded.mjs): Claude on your plan (claude-sub's folder, none of
// the stack's variables, no spend tag, no MCP server of the stack's, no budget stop), Chat's conversations with it (an
// empty folder each, no tool at all), the agents of the Code page and of Chat (fixed argument lists through their
// launchers, the folder confined, the stack's variables out), the plan's transcripts, and which tools are signed in.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmp, talk, open, result, stdout, TERMINAL_DIR } from './helpers.mjs';
import { frame, T } from '../server/frames.mjs';

const ROOT = tmp('bnag');
const WS = path.join(ROOT, 'ws'), HOME = path.join(ROOT, 'home'), SOCKDIR = path.join(ROOT, 'sock'), BIN = path.join(ROOT, 'bin');
for (const d of [WS, HOME, BIN, path.join(WS, 'app')]) fs.mkdirSync(d, { recursive: true });
// a stand-in for Claude Code and for each agent's launcher: its arguments, cwd and the variables that matter
const SAY = `#!/usr/bin/env node
const pick = ['ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_CUSTOM_HEADERS', 'CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_USE_BEDROCK', 'SHARED_MCP_TOKEN',
  'BN_MCP_URL', 'AWS_SECRET_ACCESS_KEY', 'DISABLE_AUTOUPDATER', 'HTTPS_PROXY', 'CLAUDE_CODE_ENTRYPOINT', 'BN_CODE_WORKSPACE', 'CLAUDE_CODE_DISABLE_ATTACHMENTS'];
process.stdout.write(JSON.stringify({ bin: require('path').basename(process.argv[1]), args: process.argv.slice(2), cwd: process.cwd(),
  env: Object.fromEntries(pick.filter((k) => k in process.env).map((k) => [k, process.env[k]])) }) + '\\n');
process.stdin.on('data', () => {}); process.stdin.on('end', () => process.exit(0));
`;
const CLAUDE = path.join(ROOT, 'claude');
for (const b of ['codex', 'copilot', 'cursor-agent', 'grok']) fs.writeFileSync(path.join(BIN, b), SAY, { mode: 0o755 });
fs.writeFileSync(CLAUDE, SAY, { mode: 0o755 });
// subscriptions status --tsv: a stand-in printing what the test sets (and a line that must not pass)
const SUBS = path.join(ROOT, 'subscriptions');
fs.writeFileSync(SUBS, `#!/bin/sh\nprintf 'codex\\tyes\\t0.163.0\\tyes\\tchatgpt\\tcommand\\ncopilot\\tyes\\t1.0.103\\tunknown\\t-\\tnone\\nevil\\tyes\\t1\\tyes\\t-\\tnone\\ncursor\\tyes\\t<b>\\tyes\\tcursor\\tcommand\\n'\n`, { mode: 0o755 });
Object.assign(process.env, { BN_CODE_WORKSPACE: WS, BN_CODE_SOCK_DIR: SOCKDIR, BN_CODE_CHILDREN: path.join(ROOT, 'children'), BN_CLAUDE_BIN: CLAUDE,
  CLAUDE_CONFIG_DIR: path.join(HOME, '.claude'), HOME, BN_PLAN_CONFIG_DIR: path.join(HOME, '.claude-subscription'), BN_CHAT_DIR: path.join(HOME, '.bn-chat'),
  BN_AGENT_BIN_DIR: BIN, BN_SUBS_BIN_PATH: SUBS, SHARED_MCP_TOKEN: 'mcp-secret', BN_MCP_URL: 'http://gateway:8091/mcp',
  ANTHROPIC_BASE_URL: 'http://gateway:8091', ANTHROPIC_AUTH_TOKEN: 'sk-terminal-key', CLAUDE_CODE_USE_BEDROCK: '1', AWS_SECRET_ACCESS_KEY: 'aws', HTTPS_PROXY: 'http://egress:3128' });
for (const k of Object.keys(process.env)) if (/^(DISABLE_AUTOUPDATER|CLAUDE_CODE_[A-Z_]*|CLAUDECODE|TMUX|TMUX_PANE)$/.test(k)) delete process.env[k];
fs.mkdirSync(path.join(HOME, '.config/bedrock-now'), { recursive: true });
fs.writeFileSync(path.join(HOME, '.config/bedrock-now/mcp.json'), '{}');
const coded = await import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));
let server;
const SOCK = path.join(SOCKDIR, 'coded.sock');
before(async () => { server = coded.start(); await new Promise((r) => (server.listening ? r() : server.once('listening', r))); });
after(() => { server.close(); fs.rmSync(ROOT, { recursive: true, force: true }); });

const FIXED = ['--output-format', 'stream-json', '--verbose', '--input-format', 'stream-json'];
const said = (frames) => JSON.parse(stdout(frames).toString('utf8').split('\n')[0]);
const run = (req) => talk(SOCK, [open(req), frame(T.STDIN_END, Buffer.alloc(0))]);
// Chat's sandbox (subs-chat: BN_CODED_ROLE=chat) for what fn runs
async function asChat(fn) { process.env.BN_CODED_ROLE = 'chat'; try { return await fn(); } finally { delete process.env.BN_CODED_ROLE; } }

test('Claude on your plan: claude-sub\'s folder, none of the stack\'s variables, no spend tag, no stack MCP server, no budget stop', async () => {
  const f = await run({ op: 'claude', plan: true, args: [...FIXED, `--project-config-root=${WS}`], cwd: WS, env: { CLAUDE_CODE_ENTRYPOINT: 'sdk-ts', EVIL: 'x' }, litellmSession: '3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8' });
  const s = said(f);
  assert.deepEqual(s.env, { CLAUDE_CONFIG_DIR: path.join(HOME, '.claude-subscription'), DISABLE_AUTOUPDATER: '1', HTTPS_PROXY: 'http://egress:3128', CLAUDE_CODE_ENTRYPOINT: 'sdk-ts' });
  assert.ok(!s.args.some((a) => a.startsWith('--mcp-config')), s.args.join(' '));
  // the stack's Claude Code keeps its own: the MCP server, the spend tag, Bedrock
  const b = said(await run({ op: 'claude', args: [...FIXED, `--project-config-root=${WS}`], cwd: WS, env: {}, litellmSession: '3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8' }));
  assert.ok(b.args.some((a) => a.startsWith('--mcp-config=')));
  assert.match(b.env.ANTHROPIC_CUSTOM_HEADERS, /code-3f2a1b4c/);
  assert.equal(b.env.ANTHROPIC_BASE_URL, 'http://gateway:8091');
  assert.match(result(await run({ op: 'claude', plan: true, args: [...FIXED, '--max-budget-usd=1', `--project-config-root=${WS}`], cwd: WS })).error, /no budget stop for a session on your plan/);
});

test('Chat with Claude on your plan: its own empty folder, no tool and no MCP server, or nothing', async () => asChat(async () => {
  const id = 'ab'.repeat(16);
  const s = said(await run({ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config', '--setting-sources='] }));
  assert.equal(s.cwd, fs.realpathSync(path.join(HOME, '.bn-chat', id)));
  assert.equal((fs.statSync(path.join(HOME, '.bn-chat', id)).mode & 0o777), 0o700);
  assert.ok(!s.args.some((a) => a.startsWith('--mcp-config')));
  assert.equal(s.env.CLAUDE_CONFIG_DIR, path.join(HOME, '.claude-subscription'));
  // (no @-file attachments: Claude Code would read an @path in the prompt before the model runs, tools or not)
  assert.equal(s.env.CLAUDE_CODE_DISABLE_ATTACHMENTS, '1');
  const C = [...FIXED, '--tools=', '--strict-mcp-config', '--setting-sources='];
  for (const [req, why] of [
    [{ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config'] }, /has no tools/],
    [{ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config', '--setting-sources=user'] }, /has no tools/],
    [{ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=Read', '--strict-mcp-config', '--setting-sources='] }, /has no tools|argument refused/],
    [{ op: 'claude', plan: true, chat: id, args: [...C, '--setting-sources=user'] }, /given twice|has no tools/],
    [{ op: 'claude', plan: true, chat: id, args: [...C, '--mcp-config={}'] }, /has no tools|argument refused/],
    [{ op: 'claude', plan: true, chat: id, args: [...C, '--allowedTools=Read'] }, /has no tools|argument refused/],
    [{ op: 'claude', plan: true, chat: id, args: [...C, '--settings={"permissions":{}}'] }, /has no tools|argument refused/],
    [{ op: 'claude', chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config'] }, /runs on your plan only/],
    [{ op: 'claude', plan: true, chat: id, args: [...FIXED, '--strict-mcp-config'] }, /has no tools/],
    [{ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools='] }, /has no tools/],
    [{ op: 'claude', plan: true, chat: id, args: [...C, `--project-config-root=${WS}`] }, /not for a Chat conversation/],
    [{ op: 'claude', plan: true, chat: '../../etc', args: C }, /bad conversation id/]]) {
    assert.match(result(await run(req)).error, why, JSON.stringify(req).slice(0, 80));
  }
  // a link where the conversations' folder would be: refused
  fs.rmSync(path.join(HOME, '.bn-chat'), { recursive: true });
  fs.symlinkSync(ROOT, path.join(HOME, '.bn-chat'));
  assert.match(result(await run({ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config', '--setting-sources='] })).error, /not a folder/);
  fs.unlinkSync(path.join(HOME, '.bn-chat'));
}));

test('two sandboxes: Chat\'s runs Chat\'s conversations only, the workspace\'s never one of them', async () => {
  const id = 'ef'.repeat(16);
  const chatClaude = { op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config', '--setting-sources='] };
  const chatAgent = { op: 'agent', tool: 'codex', mode: 'chat', chat: id };
  for (const req of [chatClaude, chatAgent]) assert.match(result(await run(req)).error, /Chat's conversations run in their own sandbox/);
  await asChat(async () => {
    assert.equal(said(await run(chatAgent)).bin, 'codex');
    for (const req of [{ op: 'claude', args: [...FIXED, `--project-config-root=${WS}`], cwd: WS }, { op: 'agent', tool: 'codex', mode: 'code', cwd: WS },
      { op: 'fs.list', path: '' }, { op: 'project.settings' }, { op: 'sessions.list' }, { op: 'git.status' }, { op: 'cli', args: ['plugin', 'list'] }]) {
      assert.match(result(await run(req)).error, /not in Chat's sandbox/, req.op);
    }
    assert.ok(result(await talk(SOCK, [open({ op: 'subscriptions.status' })])).tools);
  });
});

test('an agent: its launcher with fixed arguments, in a folder of the workspace or its conversation\'s, without the stack\'s variables', async () => {
  const want = { codex: ['codex', ['app-server']], copilot: ['copilot', ['--acp', '--stdio']], cursor: ['cursor-agent', ['acp']], grok: ['grok', ['agent', '--no-leader', 'stdio']] };
  for (const [tool, [bin, args]] of Object.entries(want)) {
    const s = said(await run({ op: 'agent', tool, mode: 'code', cwd: path.join(WS, 'app'), args: ['--yolo'] }));
    assert.equal(s.bin, bin); assert.deepEqual(s.args, args, tool);
    assert.equal(s.cwd, fs.realpathSync(path.join(WS, 'app')));
    assert.deepEqual(s.env, { HTTPS_PROXY: 'http://egress:3128' }, tool);
  }
  // Chat's: every switch the tool has that turns its tools off, in the conversation's own folder (Chat's sandbox)
  const chatWant = {
    codex: ['app-server', '--disable', 'shell_tool', '--disable', 'unified_exec', '--disable', 'shell_snapshot', '--disable', 'apps', '--disable', 'plugins',
      '--disable', 'browser_use', '--disable', 'browser_use_external', '--disable', 'computer_use', '--disable', 'in_app_browser', '--disable', 'image_generation',
      '--disable', 'view_image', '--disable', 'skill_search', '--disable', 'skill_mcp_dependency_install', '--disable', 'tool_suggest', '--disable', 'goals',
      '--disable', 'code_mode_host', '--disable', 'sleep_tool', '-c', 'web_search="disabled"', '-c', 'mcp_servers={}', '-c', 'project_doc_max_bytes=0'],
    copilot: ['--acp', '--stdio', '--disable-builtin-mcps', '--no-custom-instructions', '--no-ask-user', '--disallow-temp-dir', '--available-tools=',
      '--deny-tool=shell', '--deny-tool=write', '--deny-tool=url'],
    grok: ['--tools=', '--disable-web-search', '--no-subagents', 'agent', '--no-leader', 'stdio'] };
  await asChat(async () => {
    for (const [tool, args] of Object.entries(chatWant)) {
      const c = said(await run({ op: 'agent', tool, mode: 'chat', chat: 'cd'.repeat(16), args: ['--yolo'] }));
      assert.deepEqual(c.args, args, tool);
      assert.equal(c.cwd, fs.realpathSync(path.join(HOME, '.bn-chat', 'cd'.repeat(16))));
      assert.deepEqual(c.env, { HTTPS_PROXY: 'http://egress:3128' }, tool);
    }
    assert.match(result(await run({ op: 'agent', tool: 'codex', mode: 'chat', chat: 'x' })).error, /bad conversation id/);
    // Cursor: no switch that turns its tools off — not in Chat
    assert.match(result(await run({ op: 'agent', tool: 'cursor', mode: 'chat', chat: 'cd'.repeat(16) })).error, /not in Chat: it has no switch that turns its tools off/);
  });
  for (const [req, why] of [[{ op: 'agent', tool: 'gemini', mode: 'code' }, /no such tool/], [{ op: 'agent', tool: 'toString', mode: 'code' }, /no such tool/],
    [{ op: 'agent', tool: 'codex', mode: 'yolo' }, /mode: code or chat/], [{ op: 'agent', tool: 'codex', mode: 'code', cwd: '/etc' }, /must be in \/workspace/]]) {
    assert.match(result(await run(req)).error, why);
  }
  fs.unlinkSync(path.join(BIN, 'grok'));
  assert.match(result(await run({ op: 'agent', tool: 'grok', mode: 'code' })).error, /not in this sandbox/);
});

test('which tools are signed in: words only, every known tool once (no line: not known), the system\'s programs', async () => {
  const r = result(await talk(SOCK, [open({ op: 'subscriptions.status' })]));
  assert.deepEqual(r.tools, [{ id: 'claude', installed: false, signed: 'unknown' }, { id: 'codex', installed: true, signed: 'yes' },
    { id: 'gemini', installed: false, signed: 'unknown' }, { id: 'copilot', installed: true, signed: 'unknown' },
    { id: 'cursor', installed: false, signed: 'unknown' }, { id: 'grok', installed: false, signed: 'unknown' }]);
  assert.deepEqual(coded.parseSubsStatus('codex\tno\t-\tno\t-\tnone\ncodex\tyes\t1\tyes\tchatgpt\tcommand').tools[1], { id: 'codex', installed: false, signed: 'no' });
});

test('the plan\'s transcripts: listed, read and titled from its own folder; a store of another name refused', async () => {
  const id = '3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8';
  const dir = path.join(HOME, '.claude-subscription/projects', WS.replace(/[^A-Za-z0-9]/g, '-'));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${id}.jsonl`), `${JSON.stringify({ type: 'user', cwd: WS, message: { role: 'user', content: 'on my plan' }, timestamp: '2026-10-23T10:00:00Z' })}\n`);
  const plan = result(await talk(SOCK, [open({ op: 'sessions.list', store: 'plan' })]));
  assert.deepEqual(plan.sessions.map((x) => [x.id, x.firstPrompt]), [[id, 'on my plan']]);
  assert.deepEqual(result(await talk(SOCK, [open({ op: 'sessions.list' })])).sessions, []);
  assert.equal(result(await talk(SOCK, [open({ op: 'sessions.load', id, store: 'plan' })])).entries.length, 1);
  assert.deepEqual(result(await talk(SOCK, [open({ op: 'sessions.title', id, title: 'Mine', store: 'plan' })])), { ok: true });
  assert.match(result(await talk(SOCK, [open({ op: 'sessions.list', store: '../x' })])).error, /bad store/);
});

test('an agent runs in a process group of its own: a kill reaches what it started (Chat kills one at the first sign of a tool)', async () => {
  const net = await import('node:net');
  const { FrameParser } = await import('../server/frames.mjs');
  const bin = path.join(BIN, 'grok');
  fs.writeFileSync(bin, '#!/bin/sh\nsleep 300 &\necho "ready $!"\nwait\n', { mode: 0o755 });
  try {
    const pid = await new Promise((resolve, reject) => {
      const c = net.connect(SOCK);
      const parser = new FrameParser(1 << 20);
      let out = '', child = null;
      const timer = setTimeout(() => { c.destroy(); reject(new Error(`no end; ${out}`)); }, 15000);
      c.on('connect', () => c.write(open({ op: 'agent', tool: 'grok', mode: 'code', cwd: path.join(WS, 'app') })));
      c.on('data', (d) => {
        for (const [t, p] of parser.push(d)) {
          if (t !== T.STDOUT) continue;
          out += p.toString('utf8');
          const m = /ready (\d+)/.exec(out);
          if (m && child === null) { child = Number(m[1]); c.write(frame(T.SIGNAL, { signal: 'SIGKILL' })); }
        }
      });
      c.on('close', () => { clearTimeout(timer); resolve(child); });
      c.on('error', () => {});
    });
    assert.ok(pid > 0);
    let alive = true;
    for (let i = 0; i < 50 && alive; i++) {
      try { process.kill(pid, 0); await new Promise((r) => setTimeout(r, 50)); } catch { alive = false; }
    }
    assert.equal(alive, false, 'what the agent started was killed with it');
  } finally { fs.writeFileSync(bin, SAY, { mode: 0o755 }); }
});

test('Chat\'s sandbox does not start where the stack\'s own services resolve (a compose run without its overlay)', async () => {
  const lookup = (resolves) => async (n) => { if (resolves.includes(n)) return { address: '172.18.0.2' }; throw Object.assign(new Error('ENOTFOUND'), { code: 'ENOTFOUND' }); };
  assert.deepEqual(await coded.chatNetworkGuard({ lookup: lookup([]) }), []);
  assert.deepEqual(await coded.chatNetworkGuard({ lookup: lookup(['portal', 'litellm']) }), ['litellm', 'portal']);
  // (a lookup that never answers, twice: counted as reachable — what is not known to be out of reach does not start)
  assert.deepEqual(await coded.chatNetworkGuard({ lookup: () => new Promise(() => {}), names: ['portal'], timeoutMs: 50 }), ['portal (no answer)']);
  // (late once, then an answer: that answer)
  let n = 0;
  const lateOnce = async () => { if (n++ === 0) await new Promise(() => {}); throw Object.assign(new Error('ENOTFOUND'), { code: 'ENOTFOUND' }); };
  assert.deepEqual(await coded.chatNetworkGuard({ lookup: lateOnce, names: ['portal'], timeoutMs: 50 }), []);
  assert.ok(coded.STACK_NAMES.includes('open-webui') && coded.STACK_NAMES.includes('litellm'));
});

test('an agent that exits while something it started (out of its group) holds its output: its EXIT comes all the same, after a short grace', async () => {
  const net = await import('node:net');
  const { FrameParser } = await import('../server/frames.mjs');
  const bin = path.join(BIN, 'grok');
  // (a grandchild in a session of its own — node's detached: setsid —, its output the agent's)
  fs.writeFileSync(bin, `#!/bin/sh\n"${process.execPath}" -e "const c = require('child_process').spawn('sleep', ['300'], { detached: true, stdio: ['ignore', 'inherit', 'inherit'] }); console.log('ready ' + c.pid); c.unref();"\nexit 0\n`, { mode: 0o755 });
  let pid = 0;
  try {
    const t0 = Date.now();
    const exit = await new Promise((resolve, reject) => {
      const c = net.connect(SOCK);
      const parser = new FrameParser(1 << 20);
      let out = '';
      const timer = setTimeout(() => { c.destroy(); reject(new Error(`no EXIT; ${out}`)); }, 15000);
      c.on('connect', () => c.write(open({ op: 'agent', tool: 'grok', mode: 'code', cwd: path.join(WS, 'app') })));
      c.on('data', (d) => {
        for (const [t, p] of parser.push(d)) {
          if (t === T.STDOUT) { out += p.toString('utf8'); const m = /ready (\d+)/.exec(out); if (m) pid = Number(m[1]); }
          if (t === T.EXIT) { clearTimeout(timer); resolve(JSON.parse(p.toString('utf8'))); c.destroy(); }
        }
      });
      c.on('error', () => {});
    });
    assert.equal(exit.code, 0);
    assert.ok(Date.now() - t0 < coded.EXIT_GRACE_MS + 8000, `${Date.now() - t0} ms`);
    assert.ok(pid > 0, 'the grandchild ran');
  } finally {
    fs.writeFileSync(bin, SAY, { mode: 0o755 });
    if (pid) { try { process.kill(pid, 'SIGKILL'); } catch { /* gone (Chat's sweep, or the group's kill) */ } }
  }
});

test('Chat\'s sweep: whatever is in no session of bn-coded\'s, its helpers\' or a live agent\'s is killed, by its pid, its start time read again; never the init, bn-coded or what docker exec put in', () => {
  const proc = tmp('bnproc');
  const put = (pid, { ppid, pgrp = pid, sid, start = `${pid}00` }) => {
    fs.mkdirSync(path.join(proc, String(pid)), { recursive: true });
    const f = ['S', ppid, pgrp, sid, ...Array(15).fill(0), start, 0, 0];
    fs.writeFileSync(path.join(proc, String(pid), 'stat'), `${pid} (a (b) c) ${f.join(' ')}\n`);
  };
  put(1, { ppid: 0, sid: 1 });                          // the init (tini)
  put(100, { ppid: 1, sid: 1 });                        // bn-coded
  put(110, { ppid: 100, sid: 1 });                      // a Claude Code of Chat's, in bn-coded's session
  put(200, { ppid: 100, sid: 200 });                    // an agent (its own session)
  put(201, { ppid: 200, pgrp: 201, sid: 200 });         // what it started, out of its group (setpgid): its session still
  put(300, { ppid: 1, sid: 300 });                      // what it started with setsid, now the init's
  put(400, { ppid: 0, sid: 400 });                      // docker exec: ./stack subscriptions login --chat
  put(401, { ppid: 400, sid: 400 });                    // what it runs: the tool's own sign-in (its session)
  put(500, { ppid: 100, sid: 500 });                    // a helper of bn-coded's (the status check)
  fs.mkdirSync(path.join(proc, 'self'));
  const killed = [];
  const kill = (pid, sig) => { killed.push([pid, sig]); };
  // (frozen first, then killed; a sign-in docker exec started survives)
  assert.deepEqual(coded.sweepChat({ procDir: proc, self: 100, agents: [200], helpers: [500], kill }), [300]);
  assert.deepEqual(killed, [[300, 'SIGSTOP'], [300, 'SIGKILL']]);
  // the agent ended: its session goes, whatever left its group — never spared, even named a live one
  killed.length = 0;
  assert.deepEqual(coded.sweepChat({ procDir: proc, self: 100, agents: [], helpers: [500], kill }).sort(), [200, 201, 300]);
  killed.length = 0;
  assert.deepEqual(coded.sweepChat({ procDir: proc, self: 100, agents: [200], helpers: [500], ending: [200], kill }).sort(), [200, 201, 300]);
  // a process that keeps starting others: each new one frozen as it appears, the sandbox looked at again, then all
  // killed (at most CHAT_SWEEP_ROUNDS rounds)
  killed.length = 0;
  let next = 600;
  const forking = (pid, sig) => { killed.push([pid, sig]); if (sig === 'SIGSTOP' && next < 603) put(next++, { ppid: pid, sid: 300 }); };
  assert.deepEqual(coded.sweepChat({ procDir: proc, self: 100, agents: [200], helpers: [500], kill: forking }).sort(), [300, 600, 601, 602]);
  assert.deepEqual(killed.filter(([, sig]) => sig === 'SIGKILL').map(([p]) => p).sort(), [300, 600, 601, 602]);
  assert.ok(killed.findIndex(([, sig]) => sig === 'SIGKILL') > killed.findLastIndex(([, sig]) => sig === 'SIGSTOP'), 'killed only once all are frozen');
  for (const p of [600, 601, 602]) fs.rmSync(path.join(proc, String(p)), { recursive: true });
  // no bn-coded found: nothing
  assert.deepEqual(coded.sweepChat({ procDir: proc, self: 999, agents: [], helpers: [], kill }), []);
  // killGroup: the leader with its start — the group; the pid taken by another process since — not; the leader gone — its group still
  const sent = [];
  const k = (pid, sig) => { sent.push([pid, sig]); };
  assert.equal(coded.killGroup(200, '20000', 'SIGKILL', { procDir: proc, kill: k }), true);
  assert.equal(coded.killGroup(200, '12345', 'SIGKILL', { procDir: proc, kill: k }), false);
  assert.equal(coded.killGroup(777, '77700', 'SIGTERM', { procDir: proc, kill: k }), true);
  assert.deepEqual(sent, [[-200, 'SIGKILL'], [-777, 'SIGTERM']]);
  fs.rmSync(proc, { recursive: true });
});
