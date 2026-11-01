import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PLACED, WIDGETS, BOUNDS, DOCKS, allowedDocks, arrange, activeIn, collapsible, defaultLayout, defaultLayoutPrefs, dockBounds, dockOf, explorerOpen, fromLegacy,
  growWidget, isDefault, moveWidget, nextDock, parseLayout, parseLayoutPrefs, resetLayout, reveal, setActive, setDockSize, setHidden, setMode, setPane,
  setWidgetSize, shiftWidget, shown, tabletPane, toggleExplorer, visibleIn, type DeviceLayout, type WidgetId,
} from '../src/layout';
import { DEFAULT_PREFS, parsePrefs } from '../src/prefs';

const all = (l: DeviceLayout) => DOCKS.flatMap((d) => l.place[d]).sort();
const every = (l: DeviceLayout) => assert.deepEqual(all(l), [...PLACED].sort(), 'every widget sits in exactly one dock');

test("the default is today's page: Explorer, Search, Git, Projects as tabs on the left, the editor in the centre, the terminal below (closed), the chat on the right", () => {
  const d = defaultLayout('desktop');
  assert.deepEqual(d.place, { left: ['explorer', 'search', 'git', 'sessions'], center: ['editor'], right: ['chat'], bottom: ['terminal'] });
  assert.deepEqual([d.docks.left.size, d.docks.right.size, d.docks.bottom.size], [260, 440, 240]);
  assert.deepEqual(d.hidden, ['terminal']);
  assert.equal(d.docks.left.mode, 'tabs');
  assert.equal(activeIn(d, 'left'), 'explorer');
  assert.equal(d.pane, 'left');
  assert.deepEqual(DEFAULT_PREFS.layout, defaultLayoutPrefs());
  assert.ok(isDefault(d, 'desktop') && isDefault(defaultLayout('tablet'), 'tablet'));
  every(d);
  // nothing hidden but the terminal; the chat can't be
  assert.deepEqual(WIDGETS.filter((w) => !shown(d, w)), ['terminal']);
});

test('the default draws as the page did: the explorer 260 px, the chat 440 px, chat first until something opens', () => {
  const d = defaultLayout('desktop');
  const a = arrange(d, 'desktop', { vw: 1440, noTabs: true, editing: false });
  assert.deepEqual([a.left, a.right, a.bottom], [260, 440, null]);
  assert.equal(a.chatFirst, true, 'no file open: the chat has the middle');
  assert.equal(a.fill, 'right');
  assert.deepEqual(a.shown.center, [], 'the editor gives way');
  const open = arrange(d, 'desktop', { vw: 1440, noTabs: false, editing: false });
  assert.equal(open.chatFirst, false);
  assert.deepEqual(open.shown.center, ['editor']);
  // the terminal open: the editor stays (welcome) above it, and the bottom dock has its height
  const term = arrange(setHidden(d, 'terminal', false), 'desktop', { vw: 1440, noTabs: true, editing: false });
  assert.equal(term.chatFirst, false);
  assert.deepEqual([term.shown.center, term.bottom], [['editor'], 240]);
  // a narrow window: the centre keeps 320 px (the explorer gives way first, then the chat to its minimum)
  const narrow = arrange(d, 'desktop', { vw: 800, noTabs: false, editing: false });
  assert.deepEqual([narrow.left, narrow.right], [160, 320]);
  const mid = arrange(d, 'desktop', { vw: 1000, noTabs: false, editing: false });
  assert.deepEqual([mid.left, mid.right], [240, 440]);
  // the explorer off (Ctrl+B): no left column
  assert.equal(arrange(toggleExplorer(d, 'desktop'), 'desktop', { vw: 1440, noTabs: false, editing: false }).left, null);
});

test('old saved prefs migrate: sizes, the explorer toggle, the terminal, the tablet pane and the explorer tab carry over', () => {
  const l = parseLayoutPrefs({ left: 300, right: 500, bottom: 200, explorer: false, terminal: true, tabletPane: 'editor', side: 'git' });
  assert.deepEqual([l.desktop.docks.left.size, l.desktop.docks.right.size, l.desktop.docks.bottom.size], [300, 500, 200]);
  assert.equal(l.desktop.docks.left.open, false);
  assert.equal(explorerOpen(l.desktop), false);
  assert.equal(shown(l.desktop, 'terminal'), true);
  assert.equal(activeIn(l.desktop, 'left'), 'git');
  assert.equal(l.tablet.pane, 'center');
  assert.equal(l.desktop.pane, 'left');
  assert.equal(shown(l.tablet, 'terminal'), true);
  // clamped as before, junk falls back to the defaults
  const c = parseLayoutPrefs({ left: -5, right: 99999, bottom: 'x', explorer: 'yes', side: 'sessions' });
  assert.deepEqual([c.desktop.docks.left.size, c.desktop.docks.right.size, c.desktop.docks.bottom.size], [BOUNDS.left[0], BOUNDS.right[1], 240]);
  assert.equal(c.desktop.docks.left.open, true);
  assert.equal(activeIn(c.desktop, 'left'), 'sessions');
  // nothing stored, or nonsense: the default
  for (const junk of [null, undefined, 5, 'x', [], { left: 'a' }, {}]) assert.deepEqual(parseLayoutPrefs(junk), defaultLayoutPrefs(), JSON.stringify(junk));
  // the whole of prefs
  assert.equal(parsePrefs({ layout: { terminal: true } }).layout.desktop.hidden.includes('terminal'), false);
  assert.deepEqual(fromLegacy({}), defaultLayoutPrefs());
});

test('validation: unknown ids, docks and modes are dropped, sizes clamped, a widget missing or twice is put right, the chat never hidden', () => {
  const raw = {
    docks: { left: { mode: 'floaty', size: 99999, open: 'yes', active: 'nope' }, right: { mode: 'stack', size: 3, open: false, active: 'chat' }, moon: { size: 5 } },
    place: { left: ['git', 'git', 'bogus', 42, 'status'], right: ['chat'], moon: ['editor'] },
    hidden: ['chat', 'git', 'git', 'zzz', 'status'],
    sizes: { git: 99999, search: -3, chat: 120, nope: 5, editor: 'x' },
    pane: 'sideways',
  };
  const l = parseLayout(raw, 'desktop');
  every(l);
  assert.deepEqual(l.place.left.slice(0, 1), ['git'], 'a widget once, in order');
  assert.ok(l.place.left.includes('explorer'), 'what was missing is back, where it was');
  assert.deepEqual(l.place.center, ['editor'], 'a dock that is unknown is gone; the editor goes home');
  assert.equal(l.docks.left.mode, 'tabs');
  assert.equal(l.docks.left.size, 900, 'clamped to the widest a side dock may be');
  assert.equal(l.docks.left.open, true);
  assert.equal(l.docks.right.mode, 'stack');
  assert.equal(l.docks.right.size, 160);
  assert.equal(l.docks.right.open, false);
  assert.deepEqual(l.hidden.sort(), ['git', 'status']);
  assert.ok(!l.hidden.includes('chat'));
  assert.deepEqual(l.sizes, { git: 2000, search: 120, chat: 120 });
  assert.equal(l.pane, 'left');
  // it is a fixed point: what was healed reads back the same, through JSON too
  assert.deepEqual(parseLayout(JSON.parse(JSON.stringify(l)), 'desktop'), l);
  // the chat never sits in the bottom dock; on a tablet it stays on the right and the terminal in the drawer
  const bad = { ...defaultLayout('desktop'), place: { left: ['explorer', 'search', 'git', 'sessions'], center: ['editor'], right: [], bottom: ['terminal', 'chat'] } };
  assert.equal(dockOf(parseLayout(bad, 'desktop'), 'chat'), 'right');
  const tab = parseLayout({ ...bad, place: { left: ['terminal', 'explorer'], center: ['editor', 'chat'], right: ['git', 'search', 'sessions'], bottom: ['explorer'] } }, 'tablet');
  every(tab);
  assert.equal(dockOf(tab, 'chat'), 'right');
  assert.equal(dockOf(tab, 'terminal'), 'bottom');
  assert.deepEqual(tab.place.bottom, ['terminal']);
});

test('move: into another dock before a widget or at the end; the dock shows it; the chat has no bottom dock; no-ops return the same layout', () => {
  const d = defaultLayout('desktop');
  const m = moveWidget(d, 'desktop', 'git', 'right', 'chat');
  assert.deepEqual(m.place.right, ['git', 'chat']);
  assert.ok(!m.place.left.includes('git'));
  assert.equal(activeIn(m, 'right'), 'git', 'the moved widget is the tab shown');
  every(m);
  assert.deepEqual(moveWidget(m, 'desktop', 'git', 'right').place.right, ['chat', 'git']);
  assert.deepEqual(moveWidget(d, 'desktop', 'editor', 'left', 'search').place.left, ['explorer', 'editor', 'search', 'git', 'sessions']);
  // the chat: left, centre, right — not the bottom; the editor anywhere; the status bar nowhere
  assert.equal(moveWidget(d, 'desktop', 'chat', 'bottom'), d);
  assert.deepEqual(moveWidget(d, 'desktop', 'chat', 'center').place.center, ['editor', 'chat']);
  assert.deepEqual(moveWidget(d, 'desktop', 'chat', 'left').place.left.slice(-1), ['chat']);
  assert.equal(moveWidget(d, 'desktop', 'status', 'left'), d);
  assert.deepEqual(allowedDocks('desktop', 'terminal'), ['left', 'center', 'right', 'bottom']);
  // where it already is: nothing changes
  assert.equal(moveWidget(d, 'desktop', 'chat', 'right'), d);
  assert.equal(moveWidget(d, 'desktop', 'explorer', 'left', 'search'), d);
  // a widget that is not on the old dock any more leaves nothing behind
  assert.deepEqual(moveWidget(moveWidget(d, 'desktop', 'sessions', 'bottom'), 'desktop', 'sessions', 'left').place.bottom, ['terminal']);
});

test('shift and next dock: one place along its dock (hidden ones skipped), round the docks it may sit in', () => {
  let d = defaultLayout('desktop');
  d = shiftWidget(d, 'search', -1);
  assert.deepEqual(d.place.left, ['search', 'explorer', 'git', 'sessions']);
  assert.equal(shiftWidget(d, 'search', -1), d, 'already first');
  const h = setHidden(defaultLayout('desktop'), 'search', true);
  assert.deepEqual(shiftWidget(h, 'explorer', 1).place.left, ['git', 'search', 'explorer', 'sessions'], 'it swaps with Git, the Search that is hidden is passed over');
  assert.equal(nextDock(defaultLayout('desktop'), 'desktop', 'git', 1), 'center');
  assert.equal(nextDock(defaultLayout('desktop'), 'desktop', 'git', -1), 'bottom');
  assert.equal(nextDock(defaultLayout('desktop'), 'desktop', 'chat', 1), 'left', 'the chat skips the bottom dock');
  assert.equal(nextDock(defaultLayout('desktop'), 'desktop', 'chat', -1), 'center');
  assert.equal(nextDock(defaultLayout('tablet'), 'tablet', 'git', -1), 'right', 'a tablet has three docks');
  assert.equal(nextDock(defaultLayout('tablet'), 'tablet', 'chat', 1), 'right', 'and the chat stays');
});

test('the tab shown stays put: reordering tabs never changes it, and a widget that leaves its dock hands it on', () => {
  const d = defaultLayout('desktop');
  // Explorer one place along: still the tab shown (it is the one being moved, so it must stay mounted and focused)
  assert.equal(activeIn(shiftWidget(d, 'explorer', 1), 'left'), 'explorer');
  // Git shown, Explorer moved past it: Git still shown
  assert.equal(activeIn(shiftWidget(setActive(d, 'left', 'git'), 'explorer', 1), 'left'), 'git');
  // the chat through the left dock and back: the left dock shows Explorer again, and moving Explorer keeps it shown
  const back = moveWidget(moveWidget(d, 'desktop', 'chat', 'left'), 'desktop', 'chat', 'right');
  assert.equal(activeIn(back, 'left'), 'explorer');
  assert.equal(activeIn(shiftWidget(back, 'explorer', 1), 'left'), 'explorer');
  // Git, the tab shown, leaves for the right dock: the left dock shows one of its own, never a widget it does not have
  const gone = moveWidget(setActive(d, 'left', 'git'), 'desktop', 'git', 'right');
  assert.ok(gone.place.left.includes(gone.docks.left.active as WidgetId), `left dock's tab is ${gone.docks.left.active}`);
});

test('hide and show: every widget but the chat; one added back sits where it was; a shortcut shows it again', () => {
  const d = defaultLayout('desktop');
  assert.equal(setHidden(d, 'chat', true), d, 'the chat cannot be hidden');
  const h = setHidden(d, 'git', true);
  assert.deepEqual(visibleIn(h, 'left'), ['explorer', 'search', 'sessions']);
  assert.deepEqual(h.place.left, d.place.left, 'its place is kept');
  assert.equal(setHidden(h, 'git', true), h);
  assert.equal(setHidden(d, 'git', false), d);
  const back = setHidden(h, 'git', false);
  assert.deepEqual(visibleIn(back, 'left'), ['explorer', 'search', 'git', 'sessions']);
  // the status bar hides and comes back too
  assert.equal(shown(setHidden(d, 'status', true), 'status'), false);
  // reveal (Cmd+Shift+G, Ctrl+B ...): shown, its dock open, its tab selected
  const closed = { ...setHidden(setActive(d, 'left', 'explorer'), 'git', true), docks: { ...d.docks, left: { ...d.docks.left, open: false } } };
  const r = reveal(closed, 'desktop', 'git');
  assert.equal(shown(r, 'git'), true);
  assert.equal(r.docks.left.open, true);
  assert.equal(activeIn(r, 'left'), 'git');
  assert.equal(reveal(r, 'desktop', 'git'), r);
  // an active tab that is hidden falls back to the first shown
  assert.equal(activeIn(setHidden(setActive(d, 'left', 'git'), 'git', true), 'left'), 'explorer');
  assert.equal(activeIn(setHidden(d, 'chat', true), 'right'), 'chat');
});

test('Ctrl/Cmd+B: closes the explorer\'s dock, opens it again (showing the explorer); a dock with the chat in it does not close', () => {
  const d = defaultLayout('desktop');
  const off = toggleExplorer(d, 'desktop');
  assert.equal(off.docks.left.open, false);
  assert.equal(explorerOpen(off), false);
  const on = toggleExplorer(off, 'desktop');
  assert.equal(explorerOpen(on), true);
  assert.deepEqual(on, d);
  // it comes back on the tab it was on
  const onGit = toggleExplorer(toggleExplorer(setActive(d, 'left', 'git'), 'desktop'), 'desktop');
  assert.equal(activeIn(onGit, 'left'), 'git');
  // hidden explorer: the key shows it
  assert.equal(shown(toggleExplorer(setHidden(d, 'explorer', true), 'desktop'), 'explorer'), true);
  // the explorer on the chat's dock: hiding it is all the key can do
  const withChat = moveWidget(d, 'desktop', 'explorer', 'right');
  assert.equal(collapsible(withChat, 'right'), false);
  const t = toggleExplorer(withChat, 'desktop');
  assert.equal(shown(t, 'explorer'), false);
  assert.equal(t.docks.right.open, true);
  assert.equal(shown(toggleExplorer(t, 'desktop'), 'explorer'), true);
});

test('tabs or stacked: per dock; stacked widgets all show, tabs show the one selected; sizes along the stack are clamped', () => {
  const d = defaultLayout('desktop');
  const s = setMode(d, 'left', 'stack');
  assert.equal(s.docks.left.mode, 'stack');
  assert.equal(setMode(s, 'left', 'stack'), s);
  assert.deepEqual(arrange(s, 'desktop', { vw: 1440, noTabs: false, editing: false }).shown.left, ['explorer', 'search', 'git', 'sessions']);
  assert.equal(setWidgetSize(s, 'explorer', 5).sizes.explorer, 120);
  assert.equal(setWidgetSize(s, 'explorer', 99999).sizes.explorer, 2000);
  assert.equal(setWidgetSize(s, 'explorer', 300).sizes.explorer, 300);
  assert.equal(setWidgetSize(setWidgetSize(s, 'explorer', 300), 'explorer', 300).sizes.explorer, 300);
  assert.equal(setActive(d, 'left', 'search').docks.left.active, 'search');
  assert.equal(setActive(d, 'left', 'explorer'), d);
});

test('resize: a dock\'s width or height within its bounds; the chat widens what a side dock may be; Shift+arrows grow the dock they point out of', () => {
  const d = defaultLayout('desktop');
  assert.equal(setDockSize(d, 'left', 10).docks.left.size, BOUNDS.left[0]);
  assert.equal(setDockSize(d, 'left', 9999).docks.left.size, BOUNDS.left[1]);
  assert.equal(setDockSize(d, 'right', 10).docks.right.size, BOUNDS.right[0]);
  assert.equal(setDockSize(d, 'right', 9999).docks.right.size, BOUNDS.right[1]);
  assert.equal(setDockSize(d, 'bottom', 9999).docks.bottom.size, BOUNDS.bottom[1]);
  assert.equal(setDockSize(d, 'center', 400), d, 'the centre takes what is left');
  assert.equal(setDockSize(d, 'left', NaN), d);
  assert.deepEqual(dockBounds(d, 'left'), BOUNDS.left);
  const swapped = moveWidget(moveWidget(d, 'desktop', 'chat', 'left'), 'desktop', 'explorer', 'right');
  assert.deepEqual(dockBounds(swapped, 'left'), BOUNDS.right, 'the chat needs 320 px wherever it is');
  assert.deepEqual(dockBounds(swapped, 'right'), BOUNDS.left);
  // keys
  assert.equal(growWidget(d, 'explorer', 'ArrowRight').docks.left.size, 300);
  assert.equal(growWidget(d, 'explorer', 'ArrowLeft').docks.left.size, 220);
  assert.equal(growWidget(d, 'chat', 'ArrowLeft').docks.right.size, 480, 'the right dock grows to the left');
  assert.equal(growWidget(d, 'chat', 'ArrowRight').docks.right.size, 400);
  assert.equal(growWidget(d, 'terminal', 'ArrowUp').docks.bottom.size, 280);
  assert.equal(growWidget(d, 'terminal', 'ArrowDown').docks.bottom.size, 200);
  assert.equal(growWidget(d, 'editor', 'ArrowLeft'), d, 'the centre has no size');
  assert.equal(growWidget(d, 'explorer', 'ArrowUp'), d, 'tabs: nothing to size');
  // stacked: up and down size a widget that has another below it, the last has none
  const s = setMode(d, 'left', 'stack');
  assert.equal(growWidget(s, 'explorer', 'ArrowDown').sizes.explorer, 280);
  assert.equal(growWidget(s, 'sessions', 'ArrowDown'), s);
  // at the bounds the layout does not change
  const max = setDockSize(d, 'left', 560);
  assert.equal(growWidget(max, 'explorer', 'ArrowRight'), max);
});

test('reset: back to the default, for one device', () => {
  let d = defaultLayout('desktop');
  d = setHidden(moveWidget(setMode(d, 'left', 'stack'), 'desktop', 'git', 'bottom'), 'search', true);
  assert.equal(isDefault(d, 'desktop'), false);
  assert.deepEqual(resetLayout('desktop'), defaultLayout('desktop'));
  assert.equal(isDefault(resetLayout('desktop'), 'desktop'), true);
  // key order does not matter to "is it the default"
  assert.equal(isDefault(parseLayout(JSON.parse(JSON.stringify(defaultLayout('desktop'))), 'desktop'), 'desktop'), true);
});

test('the editor gives way to the chat only in the centre, with no file open and nothing below; Customize shows everything', () => {
  const d = defaultLayout('desktop');
  const inCentre = moveWidget(d, 'desktop', 'chat', 'center');
  const a = arrange(inCentre, 'desktop', { vw: 1440, noTabs: true, editing: false });
  assert.deepEqual(a.shown.center, ['chat'], 'the editor yields to the chat in their shared dock');
  assert.equal(arrange(inCentre, 'desktop', { vw: 1440, noTabs: false, editing: false }).shown.center.join(), 'editor,chat');
  assert.deepEqual(arrange(d, 'desktop', { vw: 1440, noTabs: true, editing: true }).shown.center, ['editor']);
  const inLeft = moveWidget(d, 'desktop', 'editor', 'left');
  assert.ok(arrange(inLeft, 'desktop', { vw: 1440, noTabs: true, editing: false }).shown.left.includes('editor'), 'an editor on a side dock stays');
  // the chat on the left: it takes the middle, the right dock (empty) is not drawn
  const chatLeft = moveWidget(d, 'desktop', 'chat', 'left');
  const b = arrange(chatLeft, 'desktop', { vw: 1440, noTabs: true, editing: false });
  assert.equal(b.fill, 'left');
  assert.equal(b.right, null);
  assert.ok(b.left !== null);
  // editing draws empty docks as places to drop
  const e = arrange(chatLeft, 'desktop', { vw: 1440, noTabs: true, editing: true });
  assert.ok(e.right !== null && e.bottom !== null);
  assert.equal(e.fill, 'center');
  // the editor hidden and the terminal open: the bottom dock fills the centre column
  const t = arrange(setHidden(setHidden(d, 'editor', true), 'terminal', false), 'desktop', { vw: 1440, noTabs: false, editing: false });
  assert.equal(t.bottomFill, true);
  assert.equal(t.fill, 'center');
});

test('a dock whose widgets are all hidden is not drawn; one the chat is in always is', () => {
  let d = defaultLayout('desktop');
  for (const id of ['explorer', 'search', 'git', 'sessions'] as WidgetId[]) d = setHidden(d, id, true);
  assert.equal(arrange(d, 'desktop', { vw: 1440, noTabs: false, editing: false }).left, null);
  const collapsed = { ...defaultLayout('desktop'), docks: { ...d.docks, right: { ...d.docks.right, open: false } } };
  assert.equal(arrange(collapsed, 'desktop', { vw: 1440, noTabs: false, editing: false }).right, 440);
});

test('desktop and tablet are separate: each its own layout, its own sizes; the tablet has one pane beside the chat', () => {
  const p = defaultLayoutPrefs();
  const moved = { ...p, desktop: moveWidget(p.desktop, 'desktop', 'git', 'right') };
  assert.deepEqual(moved.tablet, p.tablet);
  assert.equal(dockOf(moved.desktop, 'git'), 'right');
  assert.equal(dockOf(moved.tablet, 'git'), 'left');
  // stored separately and read back separately
  const back = parseLayoutPrefs(JSON.parse(JSON.stringify(moved)));
  assert.deepEqual(back, moved);
  // a tablet: the chat's width as it was (45 % of the window at least), the pane the Files / Editor switch picked
  const t = defaultLayout('tablet');
  assert.equal(arrange(t, 'tablet', { vw: 1024, noTabs: true, editing: false }).right, 461);
  assert.equal(arrange(t, 'tablet', { vw: 700, noTabs: true, editing: false }).right, 400, 'never more than the window less 300 px');
  assert.equal(arrange(t, 'tablet', { vw: 1024, noTabs: true, editing: false }).pane, 'left');
  assert.equal(arrange(setPane(t, 'center'), 'tablet', { vw: 1024, noTabs: true, editing: false }).pane, 'center');
  assert.equal(setPane(t, 'left'), t);
  // the editor opened on a tablet: its pane
  assert.equal(reveal(t, 'tablet', 'editor').pane, 'center');
  assert.equal(reveal(reveal(t, 'tablet', 'editor'), 'tablet', 'search').pane, 'left');
  // moving the editor into the files dock leaves one pane: no switch
  const one = moveWidget(t, 'tablet', 'editor', 'left');
  assert.deepEqual(tabletPane(one), { pane: 'left', both: false });
  assert.equal(tabletPane(one, true).both, true, 'customizing shows both, to drop on');
  assert.equal(tabletPane(setPane(one, 'center')).pane, 'left', 'a pane with nothing in it is not shown');
  // the drawer's terminal and the chat stay where they are
  assert.equal(moveWidget(t, 'tablet', 'terminal', 'left'), t);
  assert.equal(moveWidget(t, 'tablet', 'chat', 'left'), t);
  assert.deepEqual(allowedDocks('tablet', 'git'), ['left', 'center', 'right']);
  // the explorer toggle on a tablet shows the explorer's pane
  assert.equal(toggleExplorer(setPane(t, 'center'), 'tablet').pane, 'left');
});

test('what the backend keeps round-trips: a layout through JSON and back is the same layout', () => {
  let d = defaultLayout('desktop');
  d = setWidgetSize(setMode(moveWidget(d, 'desktop', 'search', 'bottom'), 'bottom', 'stack'), 'search', 321);
  d = setDockSize(setHidden(d, 'status', true), 'left', 333);
  assert.deepEqual(parseLayout(JSON.parse(JSON.stringify(d)), 'desktop'), d);
  assert.ok(JSON.stringify(d).length < 1000, `a layout is small (${JSON.stringify(d).length} bytes)`);
});
