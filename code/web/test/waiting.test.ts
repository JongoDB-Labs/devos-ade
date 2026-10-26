// A session whose turn waits for your answer — a permission card, a question, a plan — says so (UX-04): never "working".
// The card takes the focus when it arrives, from an empty and quiet prompt box too, and is scrolled into view.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { groupOf, pageTitle, stateChip } from '../src/groups';
import { cardMayTakeFocus, QUIET_MS } from '../src/focus';
import { newView, type SessionView } from '../src/session';
import type { PermissionReq } from '../src/types';

const ID = '3f2a7c1e-9b4d-4e8a-a1c2-0d9e8f7a6b5c';
const req = (tool: string): PermissionReq => ({ id: `p-${tool}`, session: ID, tool, input: {} } as unknown as PermissionReq);
const view = (state: SessionView['state'], tools: string[] = []): SessionView => ({ ...newView(ID), state, permissions: tools.map(req) });

test('state chip: a turn on hold for a card, a question or a plan says "waiting for you", amber, no spinner', () => {
  for (const tool of ['Bash', 'AskUserQuestion', 'ExitPlanMode']) {
    const v = view('busy', [tool]);
    assert.deepEqual(stateChip(v), { cls: 'waiting', text: 'waiting for you', spin: false }, tool);
    assert.equal(groupOf(v), 'needs', tool);
  }
  assert.deepEqual(stateChip(view('busy')), { cls: 'busy', text: 'working', spin: true });
  assert.deepEqual(stateChip(view('starting')), { cls: 'starting', text: 'starting', spin: true });
  assert.deepEqual(stateChip(view('idle')), { cls: 'idle', text: 'idle', spin: false });
  assert.deepEqual(stateChip(view('error')), { cls: 'error', text: 'error', spin: false });
  // (the tab's title already counts the sessions that wait)
  assert.match(pageTitle(1, false), /^\(1\) waiting · Code/);
});

test('focus: a card that arrives takes it from an empty prompt box nobody types in — never from one with text', () => {
  const now = 1_000_000;
  const prompt = (value: string) => ({ tagName: 'TEXTAREA', value, dataset: { testid: 'prompt' } });
  // the prompt was just sent (its Enter does not count as typing): the card takes the focus
  assert.equal(cardMayTakeFocus(prompt(''), now, now - QUIET_MS), true);
  assert.equal(cardMayTakeFocus(prompt(''), now, 0), true);
  // a key typed in it a moment ago, or text in it: you are writing the next message — the focus stays
  assert.equal(cardMayTakeFocus(prompt(''), now, now - 200), false);
  assert.equal(cardMayTakeFocus(prompt('and then'), now, 0), false);
  // anything else you type into keeps it, empty or not: another field, the editor, the terminal's frame
  for (const el of [{ tagName: 'TEXTAREA', value: '' }, { tagName: 'INPUT', value: '', dataset: { testid: 'model-search' } }, { tagName: 'DIV', isContentEditable: true },
    { tagName: 'IFRAME' }]) assert.equal(cardMayTakeFocus(el, now, 0), false, JSON.stringify(el));
  // nothing you type into: the card takes it
  for (const el of [null, undefined, { tagName: 'BODY' }, { tagName: 'BUTTON' }]) assert.equal(cardMayTakeFocus(el, now, now), true, JSON.stringify(el));
});
