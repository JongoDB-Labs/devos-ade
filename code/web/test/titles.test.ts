// Short session titles and search by conversation on the page (src/titles.ts, JON-517).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openMatches, titleAfter } from '../src/titles';

test('a session still named by its first prompt takes the short title; one that is not keeps its name', () => {
  assert.equal(titleAfter('please could you take a very long look at the way…', { title: 'Retry budget of the export', replaced: true }), 'Retry budget of the export');
  assert.equal(titleAfter('My own name', { title: 'Retry budget of the export', replaced: false }), 'My own name', 'a Rename (or Claude Code\'s title) stays');
  assert.equal(titleAfter('kept', { title: '', replaced: true }), 'kept', 'nothing to take');
});

test('a session open here shows for a search by its title, or when the backend\'s list for this very search has it (its conversation held the words)', () => {
  // no search: everything shows
  assert.equal(openMatches('Anything', '', '', false), true);
  assert.equal(openMatches('Anything', '   ', '', false), true);
  // by title, whatever the case, whatever the list says
  assert.equal(openMatches('Retry budget of the export', 'RETRY', '', false), true);
  assert.equal(openMatches('Retry budget of the export', 'zebra', '', false), false);
  // by conversation: the list was made for this search and holds it
  assert.equal(openMatches('Retry budget of the export', 'zebra', 'zebra', true), true);
  assert.equal(openMatches('Retry budget of the export', ' Zebra ', 'zebra ', true), true, 'the same search, trimmed, any case');
  // a list for an earlier search says nothing about this one
  assert.equal(openMatches('Retry budget of the export', 'zebra', 'zeb', true), false);
  assert.equal(openMatches('Retry budget of the export', 'zebra', '', true), false);
  // a list for this search that does not hold the session: no
  assert.equal(openMatches('Retry budget of the export', 'zebra', 'zebra', false), false);
});
