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
  'BN_MCP_URL', 'AWS_SECRET_ACCESS_KEY', 'DISABLE_AUTOUPDATER', 'HTTPS_PROXY', 'CLAUDE_CODE_ENTRYPOINT', 'BN_CODE_WORKSPACE'];
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

test('Chat with Claude on your plan: its own empty folder, no tool and no MCP server, or nothing', async () => {
  const id = 'ab'.repeat(16);
  const s = said(await run({ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config', '--setting-sources='] }));
  assert.equal(s.cwd, fs.realpathSync(path.join(HOME, '.bn-chat', id)));
  assert.equal((fs.statSync(path.join(HOME, '.bn-chat', id)).mode & 0o777), 0o700);
  assert.ok(!s.args.some((a) => a.startsWith('--mcp-config')));
  assert.equal(s.env.CLAUDE_CONFIG_DIR, path.join(HOME, '.claude-subscription'));
  for (const [req, why] of [
    [{ op: 'claude', chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config'] }, /runs on your plan only/],
    [{ op: 'claude', plan: true, chat: id, args: [...FIXED, '--strict-mcp-config'] }, /has no tools/],
    [{ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools='] }, /has no tools/],
    [{ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config', `--project-config-root=${WS}`] }, /not for a Chat conversation/],
    [{ op: 'claude', plan: true, chat: '../../etc', args: [...FIXED, '--tools=', '--strict-mcp-config'] }, /bad conversation id/]]) {
    assert.match(result(await run(req)).error, why, JSON.stringify(req).slice(0, 80));
  }
  // a link where the conversations' folder would be: refused
  fs.rmSync(path.join(HOME, '.bn-chat'), { recursive: true });
  fs.symlinkSync(ROOT, path.join(HOME, '.bn-chat'));
  assert.match(result(await run({ op: 'claude', plan: true, chat: id, args: [...FIXED, '--tools=', '--strict-mcp-config'] })).error, /not a folder/);
  fs.unlinkSync(path.join(HOME, '.bn-chat'));
});

test('an agent: its launcher with fixed arguments, in a folder of the workspace or its conversation\'s, without the stack\'s variables', async () => {
  const want = { codex: ['codex', ['app-server']], copilot: ['copilot', ['--acp', '--stdio']], cursor: ['cursor-agent', ['acp']], grok: ['grok', ['agent', '--no-leader', 'stdio']] };
  for (const [tool, [bin, args]] of Object.entries(want)) {
    const s = said(await run({ op: 'agent', tool, mode: 'code', cwd: path.join(WS, 'app'), args: ['--yolo'] }));
    assert.equal(s.bin, bin); assert.deepEqual(s.args, args, tool);
    assert.equal(s.cwd, fs.realpathSync(path.join(WS, 'app')));
    assert.deepEqual(s.env, { HTTPS_PROXY: 'http://egress:3128' }, tool);
  }
  const c = said(await run({ op: 'agent', tool: 'copilot', mode: 'chat', chat: 'cd'.repeat(16) }));
  assert.deepEqual(c.args, ['--acp', '--stdio', '--disable-builtin-mcps']);
  assert.equal(c.cwd, fs.realpathSync(path.join(HOME, '.bn-chat', 'cd'.repeat(16))));
  for (const [req, why] of [[{ op: 'agent', tool: 'gemini', mode: 'code' }, /no such tool/], [{ op: 'agent', tool: 'toString', mode: 'code' }, /no such tool/],
    [{ op: 'agent', tool: 'codex', mode: 'yolo' }, /mode: code or chat/], [{ op: 'agent', tool: 'codex', mode: 'code', cwd: '/etc' }, /must be in \/workspace/],
    [{ op: 'agent', tool: 'codex', mode: 'chat', chat: 'x' }, /bad conversation id/]]) {
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
