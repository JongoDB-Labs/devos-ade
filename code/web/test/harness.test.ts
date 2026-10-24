import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harnessOf, normEvent, normPlan, normServerMsg } from '../src/api';
import { planText, harnessState } from '../src/components/Pickers';
import { SETUP_LINKS, settingsRoute, setupTarget, type SetupReason } from '../src/setuplinks';
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
  // (one that cannot start: why, as setuplinks.ts says it — its item goes where that is turned on)
  assert.deepEqual(harnessState({ ...h, signed: 'no' }), { ok: false, says: SETUP_LINKS['tool-signin'].says, reason: 'tool-signin' });
  assert.deepEqual(harnessState({ ...h, installed: false }), { ok: false, says: SETUP_LINKS['tool-left-out'].says, reason: 'tool-left-out' });
  assert.deepEqual(harnessState({ ...h, allowed: false }), { ok: false, says: SETUP_LINKS['claude-plan-off'].says, reason: 'claude-plan-off' });
  assert.match(harnessState({ ...h, allowed: false }).says, /Settings › Claude Code › Your AI subscriptions › Use my Claude plan/);
});

test('greyed items: every reason has a target, none dead — a setting of the portal or a sign-in; and how Settings is reached', () => {
  for (const [r, l] of Object.entries(SETUP_LINKS)) {
    assert.match(l.target, /^(setting:([A-Z][A-Z0-9_]{1,60}|\+[a-z-]{2,20})|signin:(terminal|chat))$/, r);
    assert.ok(l.says.length > 10 && l.says.length <= 300 && /Settings ›|terminal/.test(l.says), r);
    const t = setupTarget(r as SetupReason);
    assert.ok('setting' in t ? l.target === `setting:${t.setting}` : l.target === `signin:${t.signin}`, r);
  }
  // the ones this page gives
  for (const r of ['tool-left-out', 'claude-plan-off', 'tool-signin', 'auto-off', 'bypass-off', 'models-scope', 'terminal-remote-off', 'remote-preview', 'folder-read-only']) assert.ok(Object.hasOwn(SETUP_LINKS, r), r);
  // (framed: the reason alone goes to the portal — never a place; a tab of its own: the place's address)
  assert.deepEqual(settingsRoute('auto-off', 'http://bedrock-now.localhost:80/x?y', true), { post: { type: 'bn-code-setup', reason: 'auto-off' }, to: 'http://bedrock-now.localhost' });
  assert.deepEqual(settingsRoute('auto-off', 'https://p.example', false), { open: 'https://p.example/#settings/CODE_AUTO_MODE' });
  assert.deepEqual(settingsRoute('folder-read-only', 'https://p.example', false), { open: 'https://p.example/#settings/+project-folders' });
  assert.equal(settingsRoute('tool-signin', 'https://p.example', true), null, 'a sign-in: no Settings place');
  for (const origin of [null, 'javascript:alert(1)', 'not a url']) assert.equal(settingsRoute('auto-off', origin, true), null, String(origin));
});

test("the terminal panel's Open…: every choice acts on the button beside it, never on the menu's change", () => {
  const src = readFileSync(new URL('../src/components/Shell.tsx', import.meta.url), 'utf8');
  const menu = src.split('function ToolMenu(')[1].split('\nfunction ')[0];
  // (the change only keeps the choice: arrowing through a closed menu changes it on some systems)
  const change = /onChange=\{\(e\) => ([^\n]+)\}\n/.exec(menu.split('<select')[1])?.[1] ?? '';
  assert.equal(change, 'setChoice((e.currentTarget as HTMLSelectElement).value)');
  // the buttons act: Open (a launch) or Go to Settings (where it is turned on), each named for what it does
  const act = menu.split('const act = () => {')[1].split('\n  };')[0];
  assert.match(act, /goSetup\(s\.reason, s\.tool\)/);
  assert.match(act, /terminalLaunch\(id,/);
  assert.equal((menu.match(/onClick=\{act\}/g) ?? []).length, 2);
  assert.match(menu, /aria-label=\{`Go to \$\{SETUP_LINKS\[setup\.reason\]\.where\}`\}/);
  assert.match(menu, /aria-label=\{`Open \$\{named\(choice\)\} in the terminal`\}/);
});

test('a read-only project folder links where that is changed: the file tree, the Git panel, an open file, a gone project', () => {
  for (const [file, id] of [['FileTree', 'tree-read-only-setup'], ['GitPanel', 'git-read-only-setup'], ['EditorArea', 'file-read-only-setup'], ['Projects', 'project-gone-setup']]) {
    const src = readFileSync(new URL(`../src/components/${file}.tsx`, import.meta.url), 'utf8');
    const at = src.indexOf(`data-testid="${id}"`);
    assert.ok(at > 0, `${file}: ${id}`);
    assert.match(src.slice(at - 200, at + 400), /onClick=\{\(\) => goSetup\('folder-read-only'\)\}/, file);
  }
  assert.equal(SETUP_LINKS['folder-read-only'].target, 'setting:+project-folders');
});
