// A finished turn's cost is the same live and after a reload (UX-26): LiteLLM's rows are the spend, and a turn gets the
// rows between its prompt and its end — so a reloaded page must rebuild its turns at their own times (the backend's
// `at` on each event), not at the reload's.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applySeq, newView, type SessionView } from '../src/session';
import { eventTime, meter, turnCosts } from '../src/spend';
import { normServerMsg } from '../src/api';
import type { Ev, SpendRow } from '../src/types';

const ID = '3f2a7c1e-9b4d-4e8a-a1c2-0d9e8f7a6b5c';
const U1 = '11111111-1111-4111-8111-111111111111';
const usage = { input: 60_000, output: 109, cacheRead: 0, cacheWrite: 59_000 };
const T0 = 1_761_500_000_000;   // (the backend's clock)

// one Haiku turn as the audit saw it: the first request writes the prompt cache ($0.0042), the last one is cheap
const EVENTS: { seq: number; at: number; ev: Ev }[] = [
  { seq: 1, at: T0, ev: { kind: 'user', text: 'echo ux-ok', uuid: U1, images: 0 } },
  { seq: 2, at: T0 + 30_000, ev: { kind: 'tool_use', id: 't1', name: 'Bash', input: { command: 'echo ux-ok' }, parent: null } },
  { seq: 3, at: T0 + 40_000, ev: { kind: 'tool_result', id: 't1', text: '', isError: false, edit: null, parent: null } },
  { seq: 4, at: T0 + 43_000, ev: { kind: 'text', text: 'done', model: 'claude-haiku-5-5', parent: null } },
  { seq: 5, at: T0 + 44_000, ev: { kind: 'result', subtype: 'success', turns: 2, durationMs: 44_000, usage, isError: false } },
];
const ROWS: SpendRow[] = [
  { start: T0 + 1_000, model: 'claude-haiku-5-5', spend: 0.0042, tokens: 59_100 },
  { start: T0 + 41_000, model: 'claude-haiku-5-5', spend: 0.0007, tokens: 60_200 },
];

const replay = (skew: number | null, now: number, withAt = true): SessionView =>
  EVENTS.reduce((v, e) => applySeq(v, e.seq, e.ev, eventTime(withAt ? e.at : null, skew, now)), newView(ID));
const turnCost = (v: SessionView) => turnCosts(v.turns, ROWS)[0].cost;
const close = (a: number, b: number) => Math.abs(a - b) < 1e-9;

test('turn cost: live, the turn gets every row of it; LiteLLM is the source of truth (the session total)', () => {
  // live: each event as it arrives (this browser's clock 2 s ahead of the backend's)
  const live = EVENTS.reduce((v, e) => applySeq(v, e.seq, e.ev, e.at + 2_000), newView(ID));
  assert.ok(close(turnCost(live), 0.0049), String(turnCost(live)));
  const m = meter(live.turns, ROWS, T0 + 200_000);
  assert.ok(close(m.turn ?? -1, 0.0049) && close(m.session ?? -1, 0.0049), JSON.stringify(m));
});

test('turn cost: a reload minutes later replays the ring at the events\' own times — the same figure as live', () => {
  const reloadAt = T0 + 5 * 60_000;
  const v = replay(2_000, reloadAt);
  assert.deepEqual(v.turns, [{ start: T0 + 2_000, end: T0 + 46_000 }]);
  assert.ok(close(turnCost(v), 0.0049), String(turnCost(v)));
  const m = meter(v.turns, ROWS, reloadAt);
  assert.ok(close(m.turn ?? -1, 0.0049) && close(m.session ?? -1, 0.0049), JSON.stringify(m));
  // (the same with a browser clock behind the backend's)
  assert.ok(close(turnCost(replay(-90_000, reloadAt)), 0.0049));
});

test('turn cost: without the events\' times (an older backend) the replay lands at the reload — the 7x understatement', () => {
  // (what v0.31.0 did: every replayed event at "now", so the turn's interval is the reload's moment and only the rows
  // of its last minute were counted; the session total stayed right)
  const reloadAt = T0 + 95_000;
  const v = replay(null, reloadAt, false);
  assert.deepEqual(v.turns, [{ start: reloadAt, end: reloadAt }]);
  assert.ok(close(turnCost(v), 0.0007), String(turnCost(v)));
  assert.ok(close(meter(v.turns, ROWS, reloadAt).session ?? -1, 0.0049));
});

test('event times: the backend\'s time on this browser\'s clock, never in the future; now without one', () => {
  assert.equal(eventTime(1_000_000_000_000, 500, 2_000_000_000_000), 1_000_000_000_500);
  assert.equal(eventTime(1_000_000_000_000, 5_000_000, 1_000_000_001_000), 1_000_000_001_000);
  assert.equal(eventTime(null, 500, 42), 42);
  assert.equal(eventTime(1_000_000_000_000, null, 42), 42);
});

test('the socket: an event\'s time and the backend\'s clock are taken only as whole milliseconds of this era', () => {
  const ev = { type: 'event', session: ID, seq: 1, epoch: 'deadbeef', ev: { type: 'status', text: 'x' } };
  const at = (v: unknown) => {
    const m = normServerMsg(JSON.stringify({ ...ev, at: v }));
    return m && m.kind === 'event' ? m.at : 'dropped';
  };
  assert.equal(at(T0), T0);
  for (const bad of [undefined, null, -1, 1.5, '1761500000000', 1e20, NaN, 12345]) assert.equal(at(bad), null, String(bad));
  const att = normServerMsg(JSON.stringify({ type: 'attached', session: ID, epoch: 'deadbeef', from: 1, last: 5, gap: false, now: T0 }));
  assert.ok(att && att.kind === 'attached' && att.now === T0);
  const old = normServerMsg(JSON.stringify({ type: 'attached', session: ID, epoch: 'deadbeef', from: 1, last: 5, gap: false }));
  assert.ok(old && old.kind === 'attached' && old.now === null);
});
