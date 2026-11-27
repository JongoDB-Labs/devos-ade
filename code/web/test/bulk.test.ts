// Several sessions at once (JON-605): the Delete… dialog's names and the one notice after a bulk action.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bulkDeleteHeading, bulkNotice, bulkTitles, skipReason } from '../src/bulk';

test('the dialog names the first few titles, then "and N more"', () => {
  assert.deepEqual(bulkTitles(['a', 'b']), { shown: ['a', 'b'], more: 0 });
  assert.deepEqual(bulkTitles(['a', 'b', 'c', 'd', 'e', 'f', 'g']), { shown: ['a', 'b', 'c', 'd'], more: 3 });
  assert.deepEqual(bulkTitles([]), { shown: [], more: 0 });
  assert.equal(bulkDeleteHeading(1), 'Delete this session?');
  assert.equal(bulkDeleteHeading(3), 'Delete 3 sessions?');
});

test('a refusal becomes one short reason', () => {
  assert.equal(skipReason('a turn is running in this session: stop it first'), 'a turn is running in it');
  assert.equal(skipReason('This conversation is open in the terminal (or elsewhere in the sandbox) right now: exit'), 'it is open in the terminal');
  assert.equal(skipReason('its folder is no longer added: its sessions are read only here'), 'it is read only');
  assert.equal(skipReason(''), 'it was refused');
  assert.ok(skipReason('x'.repeat(200)).length <= 60);
});

test('the notice: what was done, what was skipped and why (the same reason once)', () => {
  assert.equal(bulkNotice('Deleted', 4, []), 'Deleted 4.');
  assert.equal(bulkNotice('Deleted', 4, ['a turn is running in it']), 'Deleted 4; 1 skipped: a turn is running in it.');
  assert.equal(bulkNotice('Archived', 0, ['a turn is running in it', 'a turn is running in it', 'it is read only']),
    'Archived 0; 3 skipped: a turn is running in it, it is read only.');
});
