import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseDeepLink, withoutDeepLink } from '../src/deeplink';
import { recentReport, RECENT_MAX } from '../src/recent';
import { newView } from '../src/session';
import type { PermissionReq, SessionInfo } from '../src/types';

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const info = (n: number, modified: number, title = `t${n}`): SessionInfo =>
  ({ id: id(n), title, firstPrompt: `first ${n}`, branch: '', modified, size: 1, cwd: '/workspace', project: 'ws' });

test("Home's Continue row: waiting first, then working, then the most recent; open ones as they are, listed ones closed", () => {
  const views = {
    [id(1)]: { ...newView(id(1)), state: 'idle' as const, title: 'Idle one', lastActive: 5000 },
    [id(2)]: { ...newView(id(2)), state: 'busy' as const, title: 'Working one', lastActive: 1000 },
    [id(3)]: { ...newView(id(3)), state: 'idle' as const, title: '', lastActive: 2000, permissions: [{ id: 'p1' } as PermissionReq] },
    [id(4)]: { ...newView(id(4)), state: 'closed' as const, title: 'Closed view', lastActive: 9000 },
  };
  const listed = [info(5, 8000, 'Old\u202etxt.exe'), info(1, 100), info(3, 2000, 'From the list'), info(6, 7000)];
  const r = recentReport(views, listed, 1, { id: 'p_0000aaaa', name: 'ui-sweep' });
  assert.deepEqual(r.sessions.map((s) => [s.id, s.state]), [[id(3), 'waiting'], [id(2), 'working'], [id(5), 'closed'], [id(6), 'closed'], [id(1), 'idle']]);
  assert.equal(r.sessions[0].title, 'From the list', 'an open session without a title of its own: its listed one');
  assert.equal(r.sessions[2].title, 'Old⟨U+202E⟩txt.exe', 'a title is shown as text, its invisible characters visible');
  assert.equal(r.sessions[1].at, 1000);
  assert.deepEqual(r.project, { id: 'p_0000aaaa', name: 'ui-sweep' });
  assert.equal(r.waiting, 1);
  const many = recentReport({}, Array.from({ length: 30 }, (_, i) => info(i, i)), 0, null);
  assert.equal(many.sessions.length, RECENT_MAX);
  assert.equal(many.sessions[0].id, id(29));
  assert.equal(many.project, null);
  assert.equal(recentReport({}, [], 500, null).waiting, 99);
});

test("deep links: Home's New session (?new=1) — and nothing else of it", () => {
  assert.equal(parseDeepLink('?new=1').fresh, true);
  assert.equal(parseDeepLink('?new=1').any, true);
  assert.equal(parseDeepLink('?new=yes').fresh, false);
  assert.equal(parseDeepLink('?new=1&project=p_0000aaaa').project, 'p_0000aaaa');
  assert.equal(withoutDeepLink('http://code.x/?new=1&project=ws&keep=1'), '/?keep=1');
});
