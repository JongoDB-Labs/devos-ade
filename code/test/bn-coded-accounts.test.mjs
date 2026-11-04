// bn-coded's accounts of a subscription tool (terminal/bin/bn-coded.mjs): a Code page session on your plan or an agent
// runs in one account's folder, the account named by the request and checked against the folders that are there — never
// a path from the request — and BN_SUBS_ROOT is never passed on.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmp, TERMINAL_DIR } from './helpers.mjs';

const ROOT = tmp('bnca');
Object.assign(process.env, { BN_CODE_WORKSPACE: path.join(ROOT, 'ws'), BN_CODE_SOCK_DIR: path.join(ROOT, 'sock'), HOME: ROOT, CLAUDE_CONFIG_DIR: path.join(ROOT, '.claude') });
fs.mkdirSync(path.join(ROOT, 'ws'));
after(() => fs.rmSync(ROOT, { recursive: true, force: true }));
const coded = await import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));
const SUBS = path.join(ROOT, 'subs');
for (const d of ['claude/work', 'codex/alt', 'codex/Bad']) fs.mkdirSync(path.join(SUBS, d), { recursive: true });
fs.mkdirSync(path.join(ROOT, 'elsewhere'));
fs.symlinkSync(path.join(ROOT, 'elsewhere'), path.join(SUBS, 'codex/linked'));

test('accountDir: a name that is a real folder of the tool, else nothing', () => {
  assert.equal(coded.accountDir('claude', 'work', SUBS), path.join(SUBS, 'claude/work'));
  for (const [t, n] of [['claude', 'nope'], ['codex', 'linked'], ['codex', 'Bad'], ['claude', '../codex/alt'], ['claude', '/etc'], ['claude', ''], ['claude', 'a'.repeat(21)], ['../x', 'work'], ['cursor', 'work'], ['claude', undefined]]) {
    assert.equal(coded.accountDir(t, n, SUBS), null, `${t}:${n}`);
  }
});

test('planEnv: another account is its own folder; none is the first account; BN_SUBS_ROOT never passes', () => {
  const base = { PATH: '/bin', BN_SUBS_ROOT: '/evil', BN_SUB_ACCOUNT: 'x', ANTHROPIC_BASE_URL: 'http://litellm' };
  const first = coded.planEnv({}, base);
  assert.match(first.CLAUDE_CONFIG_DIR, /\.claude-subscription$/);
  const named = coded.planEnv({}, base, 'work', SUBS);
  assert.equal(named.CLAUDE_CONFIG_DIR, path.join(SUBS, 'claude/work'));
  for (const e of [first, named]) { assert.equal(e.BN_SUBS_ROOT, undefined); assert.equal(e.BN_SUB_ACCOUNT, undefined); assert.equal(e.ANTHROPIC_BASE_URL, undefined); }
  assert.throws(() => coded.planEnv({}, base, 'nope', SUBS), /no such account/);
  assert.throws(() => coded.planEnv({}, base, '../codex/alt', SUBS), /no such account/);
});

test('agentEnv: BN_SUB_ACCOUNT only for a folder of that tool; BN_SUBS_ROOT never', () => {
  const base = { PATH: '/bin', BN_SUBS_ROOT: '/evil', BN_SUB_ACCOUNT: 'spoof' };
  assert.equal(coded.agentEnv(base).BN_SUB_ACCOUNT, undefined);
  const e = coded.agentEnv(base, 'alt', 'codex', SUBS);
  assert.equal(e.BN_SUB_ACCOUNT, 'alt');
  assert.equal(e.BN_SUBS_ROOT, undefined);
  assert.throws(() => coded.agentEnv(base, 'alt', 'grok', SUBS), /no such account/);
  assert.throws(() => coded.agentEnv(base, 'linked', 'codex', SUBS), /no such account/);
});

test('storeArg: plan:NAME is a store, a path is not', () => {
  assert.equal(coded.storeArg('plan:work'), 'plan:work');
  assert.equal(coded.storeArg('plan'), 'plan');
  for (const bad of ['plan:', 'plan:../x', 'plan:A', 'plan:a/b', 'other']) assert.throws(() => coded.storeArg(bad), /bad store/);
});
