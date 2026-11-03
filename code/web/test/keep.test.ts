// Keeping a project on the built-in git server on the page (src/keep.ts): the backend's answer checked on hostile input, the
// repository name the same as the backend's, when the Git panel offers it (once per project; never again after a No unless asked
// for from the menu) and shows the kept part, when New project's box is shown and what it sends, and the portal's Git page
// addresses the buttons go to.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { boxShown, gitPlace, gitPlaceUrl, keptLine, keptShown, newProjectBody, normKeep, offerShown, repoNameOk, repoSlug } from '../src/keep';

const view = (over: Record<string, unknown> = {}) => ({ available: true, owner: 'devos', suggested: 'My-App', state: null, auto: true, pushedAt: null, lastError: null, busy: false, ...over });
const kept = (over: Record<string, unknown> = {}) => view({ state: 'kept', repo: 'devos/My-App', remote: 'origin', made: true, unpushed: [], rejected: [], ...over });

// (the same table is in code/test/keep.test.mjs: the page and the backend make the same name of a project's)
const SLUGS: [string, string][] = [['My App', 'My-App'], ['  café  au lait!! ', 'cafe-au-lait'], ['a/b\\c', 'a-b-c'], ['..hidden.', 'hidden'], ['thing.git', 'thing'], ['x.wiki.git', 'x'],
  ['日本語', 'project'], ['snake_case-and.dots', 'snake_case-and.dots'], ['_lead', 'lead'], ['', 'project'], ['-', 'project'], ['...', 'project'], ['ok-1.2', 'ok-1.2'], ['a.git.wiki', 'a']];
test('the repository name is the backend\'s: the same for every name tried', () => {
  for (const [n, want] of SLUGS) {
    assert.equal(repoSlug(n), want, JSON.stringify(n));
    assert.ok(repoNameOk(repoSlug(n)), JSON.stringify(n));
  }
  assert.equal(repoSlug('a'.repeat(300)).length, 100);
  assert.equal(repoSlug('a'.repeat(99) + '-b'), 'a'.repeat(99));
  for (const n of ['a.b_c-d', 'ok', 'A1']) assert.equal(repoNameOk(n), true, n);
  for (const n of ['-a', 'a b', 'x.git', 'x.WIKI', '', 'a'.repeat(101), 7, null]) assert.equal(repoNameOk(n), false, String(n));
});

test('the answer: only what fits is taken; a kept project without a repository is no answer', () => {
  assert.equal(normKeep(null), null);
  assert.equal(normKeep('x'), null);
  assert.equal(normKeep(kept({ repo: '../x' })), null);
  const v = normKeep(view());
  assert.deepEqual([v?.available, v?.owner, v?.suggested, v?.state, v?.repo, v?.unpushed, v?.rejected], [true, 'devos', 'My-App', null, null, null, []]);
  // an owner that is not a name: not available (nothing to keep it on)
  assert.equal(normKeep(view({ owner: '../x' }))?.available, false);
  assert.equal(normKeep(view({ available: false, owner: null }))?.available, false);
  const k = normKeep(kept({ pushedAt: 5, lastError: 'a\nb‮', unpushed: ['main', '../x', 'a b', 7], rejected: ['main: the local git server has commits this project doesn\'t — pull first', 3], remote: '-x', suggested: 'bad name' }));
  assert.equal(k?.state, 'kept');
  assert.deepEqual([k?.pushedAt, k?.remote, k?.suggested], [5, null, 'project']);
  assert.ok(!/[\n‮]/.test(k?.lastError ?? ''));
  assert.deepEqual(k?.unpushed, ['main']);
  assert.equal(k?.rejected.length, 1);
  assert.equal(normKeep(view({ state: 'maybe' }))?.state, null);
  assert.equal(normKeep(view({ state: 'declined', repo: 'devos/x' }))?.repo, null, 'a repository only for a kept project');
  assert.equal(normKeep(kept({ auto: false }))?.auto, false);
});

test('made: only a kept project whose repository was made by a push says so', () => {
  assert.equal(normKeep(kept())?.made, true);
  assert.equal(normKeep(kept({ made: false }))?.made, false);
  assert.equal(normKeep(kept({ made: 'yes' }))?.made, false);
  assert.equal(normKeep(view({ made: true }))?.made, false);
});

test('the Git panel offers once per project: not when it is not possible, not for a repository around or inside the folder, not after a No (unless asked from the menu)', () => {
  const ask = (k: unknown, found: 'self' | 'above' | 'inside' | null = 'self', isRepo = true, asked = false) => offerShown(normKeep(k), found, isRepo, asked);
  assert.equal(ask(view()), true);
  assert.equal(ask(view({ available: false, owner: null })), false, 'the built-in server is not connected');
  assert.equal(ask(view(), 'above'), false);
  assert.equal(ask(view(), 'inside'), false);
  assert.equal(ask(view(), null), false);
  assert.equal(ask(view(), 'self', false), false, 'no repository yet');
  assert.equal(ask(view({ state: 'declined' })), false, 'a No is not asked again');
  assert.equal(ask(view({ state: 'declined' }), 'self', true, true), true, 'but it can be kept from the menu');
  assert.equal(ask(kept()), false, 'already kept');
  assert.equal(ask(kept(), 'self', true, true), false);
  assert.equal(offerShown(null, 'self', true), false);
  // the kept part: only for a kept project, on its own repository
  assert.equal(keptShown(normKeep(kept()), 'self', true), true);
  assert.equal(keptShown(normKeep(kept()), 'above', true), false);
  assert.equal(keptShown(normKeep(view()), 'self', true), false);
  assert.equal(keptShown(normKeep(view({ state: 'declined' })), 'self', true), false);
  assert.equal(keptShown(null, 'self', true), false);
});

test('New project\'s box: when the built-in server is there, for an empty folder, a clone and a folder (not a folder of this computer); what it sends', () => {
  for (const kind of ['empty', 'clone', 'folder'] as const) {
    assert.equal(boxShown(true, kind), true, kind);
    assert.equal(boxShown(false, kind), false, kind);
    assert.equal(boxShown(null, kind), false, `${kind}: not known yet`);
  }
  assert.equal(boxShown(true, 'computer'), false);
  // on: an empty folder starts a git repository whatever its own box says; a folder is kept (the backend starts the repository when it is none)
  assert.deepEqual(newProjectBody('empty', 'my-app', { git: false, keep: true }), { kind: 'new', folder: 'my-app', git: true, keep: true });
  assert.deepEqual(newProjectBody('empty', 'my-app', { git: true, keep: false }), { kind: 'new', folder: 'my-app', git: true });
  assert.deepEqual(newProjectBody('empty', 'my-app', { git: false, keep: false }), { kind: 'new', folder: 'my-app', git: false });
  assert.deepEqual(newProjectBody('folder', 'src/app', { git: true, keep: true }), { kind: 'folder', folder: 'src/app', keep: true });
  assert.deepEqual(newProjectBody('folder', 'src/app', { git: true, keep: false }), { kind: 'folder', folder: 'src/app' });
});

test('the kept part\'s line: when it was last pushed and what is left', () => {
  const ago = (t: number) => `${t} ago`;
  const line = (over: Record<string, unknown>) => keptLine(normKeep(kept(over)) as NonNullable<ReturnType<typeof normKeep>>, ago);
  assert.equal(line({}), 'Nothing pushed yet. Everything is pushed.');
  assert.equal(line({ pushedAt: 7 }), 'Last pushed 7 ago. Everything is pushed.');
  assert.equal(line({ pushedAt: 7, unpushed: ['main', 'dev'] }), 'Last pushed 7 ago. Not pushed yet: main, dev.');
  assert.equal(line({ pushedAt: 7, unpushed: ['a', 'b', 'c', 'd', 'e', 'f', 'g'] }), 'Last pushed 7 ago. Not pushed yet: a, b, c, d, e and 2 more.');
  assert.equal(line({ pushedAt: 7, unpushed: null }), 'Last pushed 7 ago.');
});

test('the portal\'s Git page: the repository, its issues and its pull requests — only for a repository name, only on the portal\'s own origin', () => {
  assert.equal(gitPlace('devos/My-App'), 'devos/My-App');
  assert.equal(gitPlace('devos/My-App', 'issues'), 'devos/My-App/issues');
  assert.equal(gitPlace('devos/My-App', 'pulls'), 'devos/My-App/pulls');
  for (const bad of [null, '', 'x', '../x/y', 'a/b/c', 'a/b c', 'a/.hidden', '/x/y', 'a/b?x=1']) assert.equal(gitPlace(bad as string | null), null, String(bad));
  assert.equal(gitPlaceUrl('http://bn.localhost:8800', 'devos/x/issues'), 'http://bn.localhost:8800/#git/devos/x/issues');
  assert.equal(gitPlaceUrl('https://portal.example/some/path?q=1', 'devos/x'), 'https://portal.example/#git/devos/x');
  for (const bad of [null, undefined, '', 'javascript:alert(1)', 'not a url']) assert.equal(gitPlaceUrl(bad, 'devos/x'), null, String(bad));
  assert.equal(gitPlaceUrl('http://bn.localhost', null), null);
});
