// The Git panel finds the repository for the project's folder (UX-09): the folder itself, the nearest one around it in
// the workspace, else the repositories directly inside it — never "not a git repository" while one is there.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { findRepo } from '../src/git';
import { normGitRepoInfo } from '../src/api';

test('git panel: the folder itself when it is a repository', () => {
  assert.deepEqual(findRepo('', { repos: ['', 'ui-sweep'], above: null }), { repo: '', found: 'self', inside: [] });
  assert.deepEqual(findRepo('app', { repos: ['app', 'app/vendor/x'], above: '' }), { repo: 'app', found: 'self', inside: [] });
});

test('git panel: else the repository around the folder (its files are in it)', () => {
  assert.deepEqual(findRepo('ui-sweep/src', { repos: [], above: 'ui-sweep' }), { repo: 'ui-sweep', found: 'above', inside: [] });
  assert.deepEqual(findRepo('notes', { repos: ['notes/a'], above: '' }), { repo: '', found: 'above', inside: [] }, 'the workspace itself');
  // (an "above" that is not around the folder is not taken)
  assert.equal(findRepo('notes', { repos: [], above: 'other' }).found, null);
  assert.equal(findRepo('/host/proj', { repos: [], above: '' }).found, null, 'a folder of this computer: never the workspace');
});

test('git panel: else the repositories directly inside it — the one shown before, one the session changed, else the first', () => {
  const info = { repos: ['web', 'ui-sweep', 'tools/deep'], above: null };
  assert.deepEqual(findRepo('', info), { repo: 'ui-sweep', found: 'inside', inside: ['ui-sweep', 'web'] });
  assert.equal(findRepo('', info, { touched: ['web/index.html'] }).repo, 'web');
  assert.equal(findRepo('', info, { touched: ['/workspace/web/index.html'] }).repo, 'web');
  assert.equal(findRepo('', info, { current: 'web', touched: ['ui-sweep/a'] }).repo, 'web', 'the one picked stays');
  assert.equal(findRepo('', info, { current: 'gone' }).repo, 'ui-sweep');
  assert.deepEqual(findRepo('proj', { repos: ['proj/a', 'proj/b/c', 'project2'], above: null }), { repo: 'proj/a', found: 'inside', inside: ['proj/a'] });
  // none: the folder itself (the panel says it is no repository)
  assert.deepEqual(findRepo('', { repos: ['tools/deep'], above: null }), { repo: '', found: null, inside: [] });
});

test('git panel: what /api/git/repos says is checked — workspace paths, the folder around it or none', () => {
  assert.deepEqual(normGitRepoInfo({ repos: [{ path: 'ui-sweep' }, { path: '../etc' }, { path: 'ui-sweep' }, 'x'], above: 'a' }), { repos: ['ui-sweep'], above: 'a' });
  assert.deepEqual(normGitRepoInfo({ repos: [], above: '' }), { repos: [], above: '' });
  assert.deepEqual(normGitRepoInfo({ repos: [] }), { repos: [], above: null });
  assert.equal(normGitRepoInfo({ repos: [], above: '../up' }).above, null);
  assert.equal(normGitRepoInfo({ repos: [], above: 5 }).above, null);
});
