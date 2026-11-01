// The Code page's widgets: which panels there are, which dock each sits in (left, centre, right, bottom), in what order,
// shown as tabs or stacked, how wide or tall — the model behind Customize (components/Widgets.tsx). Pure: no DOM, no
// store; prefs.ts keeps it in the browser, the backend (userprefs.mjs, which holds the same ids and bounds) for your
// sign-in. Today's page is the default: a left dock of Explorer, Search, Git and Projects as tabs, the editor in the
// centre with the terminal below it, the chat on the right. Desktop and tablet each have a layout of their own.
// Everything read is validated and clamped; a layout that does not fit heals to one that does (every widget once).

export type Device = 'desktop' | 'tablet';
export type DockId = 'left' | 'center' | 'right' | 'bottom';
export type WidgetId = 'explorer' | 'search' | 'git' | 'sessions' | 'editor' | 'terminal' | 'chat' | 'status';

export const DOCKS: readonly DockId[] = ['left', 'center', 'right', 'bottom'];
/** The widgets that sit in a dock (the status bar is the page's footer: it can be hidden, not moved). */
export const PLACED: readonly WidgetId[] = ['explorer', 'search', 'git', 'sessions', 'editor', 'terminal', 'chat'];
export const WIDGETS: readonly WidgetId[] = [...PLACED, 'status'];
/** The four that were the explorer's tabs. */
export const SIDE: readonly WidgetId[] = ['explorer', 'search', 'git', 'sessions'];

export interface WidgetInfo {
  /** its name in the Widgets tray and to a screen reader */
  label: string;
  /** its tab */
  tab: string;
  icon: string;
  /** false: the chat — the page is for it */
  hideable: boolean;
}
export const WIDGET_INFO: Record<WidgetId, WidgetInfo> = {
  explorer: { label: 'Explorer', tab: 'Explorer', icon: 'files', hideable: true },
  search: { label: 'Search', tab: 'Search', icon: 'search', hideable: true },
  git: { label: 'Git', tab: 'Git', icon: 'branch', hideable: true },
  sessions: { label: 'Projects & sessions', tab: 'Projects', icon: 'folder', hideable: true },
  editor: { label: 'Editor', tab: 'Editor', icon: 'code', hideable: true },
  terminal: { label: 'Terminal', tab: 'Terminal', icon: 'terminal', hideable: true },
  chat: { label: 'Chat', tab: 'Chat', icon: 'comment', hideable: false },
  status: { label: 'Status bar', tab: 'Status bar', icon: 'panelBottom', hideable: true },
};
export const DOCK_LABEL: Record<DockId, string> = { left: 'Left dock', center: 'Centre', right: 'Right dock', bottom: 'Bottom dock' };

export const BOUNDS = {
  left: [160, 560],
  right: [320, 900],
  bottom: [120, 720],
} as const;
/** The widest a side dock may be saved (the chat in it needs more than an explorer: dockBounds). */
const SIDE_RANGE = [160, 900] as const;
/** A stacked widget's own height (width, in the bottom dock). */
export const STACK_BOUNDS = [120, 2000] as const;
export const STACK_DEFAULT = 240;
/** The centre column keeps at least this much (the editor rule) when it is drawn. */
export const CENTER_MIN = 320;

export interface DockState {
  mode: 'tabs' | 'stack';
  /** left, right: width; bottom: height (px); the centre takes what is left (0) */
  size: number;
  /** false: collapsed (Ctrl/Cmd+B on the explorer's dock); the chat's dock never is */
  open: boolean;
  /** tabs: the widget shown (null or hidden: the first shown) */
  active: WidgetId | null;
}
export interface DeviceLayout {
  docks: Record<DockId, DockState>;
  /** each dock's widgets in order, hidden ones kept in place (adding one back puts it where it was) */
  place: Record<DockId, WidgetId[]>;
  hidden: WidgetId[];
  /** a stacked widget's own size along the stack, where set */
  sizes: Partial<Record<WidgetId, number>>;
  /** tablet: which of the left and centre docks shows beside the chat */
  pane: 'left' | 'center';
}
export interface LayoutPrefs {
  desktop: DeviceLayout;
  tablet: DeviceLayout;
}

/** The docks a widget may sit in: the chat has no bottom dock; on a tablet the chat stays on the right and the terminal
 *  is the drawer. */
export function allowedDocks(device: Device, id: WidgetId): DockId[] {
  if (id === 'status') return [];
  if (device === 'tablet') return id === 'chat' ? ['right'] : id === 'terminal' ? ['bottom'] : ['left', 'center', 'right'];
  return id === 'chat' ? ['left', 'center', 'right'] : [...DOCKS];
}
/** The docks Customize offers on this device (a tablet has no bottom dock: its terminal is a drawer). */
export const dockList = (device: Device): DockId[] => (device === 'tablet' ? ['left', 'center', 'right'] : [...DOCKS]);

const DEFAULT_SIZE: Record<DockId, number> = { left: 260, center: 0, right: 440, bottom: 240 };
const HOME: Record<WidgetId, DockId> = { explorer: 'left', search: 'left', git: 'left', sessions: 'left', editor: 'center', terminal: 'bottom', chat: 'right', status: 'bottom' };

export function defaultLayout(_device: Device = 'desktop'): DeviceLayout {
  const dock = (active: WidgetId): DockState => ({ mode: 'tabs', size: 0, open: true, active });
  return {
    docks: {
      left: { ...dock('explorer'), size: DEFAULT_SIZE.left },
      center: dock('editor'),
      right: { ...dock('chat'), size: DEFAULT_SIZE.right },
      bottom: { ...dock('terminal'), size: DEFAULT_SIZE.bottom },
    },
    place: { left: ['explorer', 'search', 'git', 'sessions'], center: ['editor'], right: ['chat'], bottom: ['terminal'] },
    hidden: ['terminal'],
    sizes: {},
    pane: 'left',
  };
}
export const defaultLayoutPrefs = (): LayoutPrefs => ({ desktop: defaultLayout('desktop'), tablet: defaultLayout('tablet') });

// ---------------------------------------------------------------- reading what was kept

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const clampInt = (v: unknown, [lo, hi]: readonly [number, number] | readonly number[], d: number): number =>
  typeof v === 'number' && Number.isFinite(v) ? Math.round(Math.min(hi, Math.max(lo, v))) : d;
const isWidget = (v: unknown): v is WidgetId => typeof v === 'string' && (WIDGETS as readonly string[]).includes(v);
const RANGE: Record<DockId, readonly [number, number]> = { left: SIDE_RANGE, right: SIDE_RANGE, bottom: BOUNDS.bottom, center: [0, 0] };

/** Validate a device's layout from storage or the backend: unknown ids, docks and modes are dropped, sizes clamped, a
 *  widget that is missing or twice is put right, the chat is never hidden — whatever was there, a usable layout. */
export function parseLayout(raw: unknown, device: Device): DeviceLayout {
  const o = isObj(raw) ? raw : {};
  const d = defaultLayout(device);
  const docks = isObj(o.docks) ? o.docks : {};
  const place = isObj(o.place) ? o.place : {};
  const out: DeviceLayout = { docks: { ...d.docks }, place: { left: [], center: [], right: [], bottom: [] }, hidden: [], sizes: {}, pane: o.pane === 'center' ? 'center' : 'left' };
  for (const k of DOCKS) {
    const s = isObj(docks[k]) ? (docks[k] as Record<string, unknown>) : {};
    out.docks[k] = {
      mode: s.mode === 'stack' ? 'stack' : 'tabs',
      size: clampInt(s.size, RANGE[k], d.docks[k].size),
      open: typeof s.open === 'boolean' ? s.open : true,
      active: isWidget(s.active) ? s.active : null,
    };
  }
  const seen = new Set<WidgetId>();
  for (const k of DOCKS) {
    for (const id of Array.isArray(place[k]) ? (place[k] as unknown[]) : []) {
      if (!isWidget(id) || id === 'status' || seen.has(id)) continue;
      seen.add(id);
      out.place[k].push(id);
    }
  }
  // what is missing goes home; what the device does not allow goes to where it may
  for (const id of PLACED) if (!seen.has(id)) out.place[HOME[id]].push(id);
  for (const k of DOCKS) {
    for (const id of [...out.place[k]]) {
      const ok = allowedDocks(device, id);
      if (ok.includes(k)) continue;
      out.place[k] = out.place[k].filter((x) => x !== id);
      out.place[ok.includes(HOME[id]) ? HOME[id] : ok[0]].push(id);
    }
  }
  const hid = Array.isArray(o.hidden) ? (o.hidden as unknown[]) : [];
  out.hidden = WIDGETS.filter((id) => WIDGET_INFO[id].hideable && hid.includes(id));
  if (isObj(o.sizes)) {
    for (const id of WIDGETS) {
      const v = (o.sizes as Record<string, unknown>)[id];
      if (typeof v === 'number' && Number.isFinite(v)) out.sizes[id] = clampInt(v, STACK_BOUNDS, STACK_DEFAULT);
    }
  }
  return out;
}

/** What `prefs.layout` held before widgets: one flat layout for both devices. */
interface Legacy { left?: unknown; right?: unknown; bottom?: unknown; explorer?: unknown; terminal?: unknown; tabletPane?: unknown; side?: unknown }
const LEGACY_SIDE: Record<string, WidgetId> = { files: 'explorer', search: 'search', git: 'git', sessions: 'sessions' };

/** The saved sizes and toggles of before (pane widths, the explorer on or off, the terminal, the tablet's pane, the
 *  explorer's tab) as the layouts they were: nobody's page changes. */
export function fromLegacy(l: Legacy): LayoutPrefs {
  const mk = (device: Device): DeviceLayout => {
    const d = defaultLayout(device);
    const side = typeof l.side === 'string' && Object.hasOwn(LEGACY_SIDE, l.side) ? LEGACY_SIDE[l.side] : 'explorer';
    d.docks.left.size = clampInt(l.left, BOUNDS.left, d.docks.left.size);
    d.docks.right.size = clampInt(l.right, BOUNDS.right, d.docks.right.size);
    d.docks.bottom.size = clampInt(l.bottom, BOUNDS.bottom, d.docks.bottom.size);
    d.docks.left.open = typeof l.explorer === 'boolean' ? l.explorer : true;
    d.docks.left.active = side;
    d.hidden = l.terminal === true ? [] : ['terminal'];
    if (device === 'tablet') d.pane = l.tabletPane === 'editor' ? 'center' : 'left';
    return d;
  };
  return { desktop: mk('desktop'), tablet: mk('tablet') };
}

/** `prefs.layout` as stored: widgets' layouts per device, or the flat one of before. */
export function parseLayoutPrefs(raw: unknown): LayoutPrefs {
  if (!isObj(raw)) return defaultLayoutPrefs();
  if ('desktop' in raw || 'tablet' in raw) return { desktop: parseLayout(raw.desktop, 'desktop'), tablet: parseLayout(raw.tablet, 'tablet') };
  return fromLegacy(raw);
}

// ---------------------------------------------------------------- asking

export const shown = (l: DeviceLayout, id: WidgetId): boolean => !l.hidden.includes(id);
export const dockOf = (l: DeviceLayout, id: WidgetId): DockId | null => DOCKS.find((k) => l.place[k].includes(id)) ?? null;
export const visibleIn = (l: DeviceLayout, dock: DockId): WidgetId[] => l.place[dock].filter((id) => shown(l, id));
/** The tab shown in a dock: its remembered one while that is shown, else the first. */
export function activeIn(l: DeviceLayout, dock: DockId, among: readonly WidgetId[] = visibleIn(l, dock)): WidgetId | null {
  const a = l.docks[dock].active;
  return a && among.includes(a) ? a : among[0] ?? null;
}
/** What a dock's width (height) may be: the chat needs more than an explorer. */
export function dockBounds(l: DeviceLayout, dock: DockId): readonly [number, number] {
  if (dock === 'bottom') return BOUNDS.bottom;
  if (dock === 'center') return [0, 0];
  return l.place[dock].includes('chat') ? BOUNDS.right : BOUNDS.left;
}
/** A dock that may be collapsed: not the chat's. */
export const collapsible = (l: DeviceLayout, dock: DockId): boolean => dock !== 'center' && !l.place[dock].includes('chat');
/** The explorer is on screen (shown, its dock not collapsed). */
export function explorerOpen(l: DeviceLayout): boolean {
  const d = dockOf(l, 'explorer');
  return shown(l, 'explorer') && !!d && (l.docks[d].open || !collapsible(l, d));
}

const same = (a: unknown, b: unknown): boolean => JSON.stringify(canon(a)) === JSON.stringify(canon(b));
function canon(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(canon);
  if (isObj(v)) return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
  return v;
}
export const isDefault = (l: DeviceLayout, device: Device): boolean => same(l, defaultLayout(device));
export const sameLayout = (a: DeviceLayout, b: DeviceLayout): boolean => same(a, b);

// ---------------------------------------------------------------- changing it (each returns the same object when nothing changes)

const withDock = (l: DeviceLayout, dock: DockId, patch: Partial<DockState>): DeviceLayout => {
  const cur = l.docks[dock];
  if ((Object.keys(patch) as (keyof DockState)[]).every((k) => cur[k] === patch[k])) return l;
  return { ...l, docks: { ...l.docks, [dock]: { ...cur, ...patch } } };
};

/** Move a widget into a dock, before another widget of it (null: at the end); it becomes that dock's tab shown, and the
 *  dock it left shows the tab it showed (another of its own when that was this one). */
export function moveWidget(l: DeviceLayout, device: Device, id: WidgetId, dock: DockId, before: WidgetId | null = null): DeviceLayout {
  if (!allowedDocks(device, id).includes(dock)) return l;
  const from = dockOf(l, id);
  const place = { ...l.place };
  for (const k of DOCKS) place[k] = place[k].filter((x) => x !== id);
  const list = place[dock];
  const at = before && before !== id ? list.indexOf(before) : -1;
  place[dock] = at < 0 ? [...list, id] : [...list.slice(0, at), id, ...list.slice(at)];
  if (from === dock && place[dock].join() === l.place[dock].join()) return l;
  const docks = { ...l.docks, [dock]: { ...l.docks[dock], active: id } };
  if (from && from !== dock) docks[from] = { ...l.docks[from], active: activeIn({ ...l, place }, from) };
  const next: DeviceLayout = { ...l, place, docks };
  return device === 'tablet' && (dock === 'left' || dock === 'center') ? { ...next, pane: dock } : next;
}

/** The dock after (before, for -1) this widget's, round the docks it may sit in. */
export function nextDock(l: DeviceLayout, device: Device, id: WidgetId, dir: 1 | -1): DockId {
  const ring = dockList(device).filter((k) => allowedDocks(device, id).includes(k));
  const at = ring.indexOf(dockOf(l, id) ?? ring[0]);
  return ring[(at + dir + ring.length) % ring.length] ?? ring[0];
}

/** One place up or down among the shown widgets of its dock (a tab left or right); the tab shown stays the one shown (it
 *  is the first only by default: the order changing must not change it). */
export function shiftWidget(l: DeviceLayout, id: WidgetId, dir: -1 | 1): DeviceLayout {
  const dock = dockOf(l, id);
  if (!dock) return l;
  const list = l.place[dock];
  let j = list.indexOf(id) + dir;
  while (j >= 0 && j < list.length && !shown(l, list[j])) j += dir;
  if (j < 0 || j >= list.length) return l;
  const next = [...list];
  next[next.indexOf(id)] = list[j];
  next[j] = id;
  return { ...l, place: { ...l.place, [dock]: next }, docks: { ...l.docks, [dock]: { ...l.docks[dock], active: activeIn(l, dock) } } };
}

/** Hide a widget (the chat cannot be) or show it again where it was. */
export function setHidden(l: DeviceLayout, id: WidgetId, hide: boolean): DeviceLayout {
  if (hide && !WIDGET_INFO[id].hideable) return l;
  if (hide === l.hidden.includes(id)) return l;
  return { ...l, hidden: hide ? [...l.hidden, id] : l.hidden.filter((x) => x !== id) };
}

/** Bring a widget to the screen: shown, its dock open, its tab selected (a tablet: its pane). */
export function reveal(l: DeviceLayout, device: Device, id: WidgetId): DeviceLayout {
  let n = setHidden(l, id, false);
  const dock = dockOf(n, id);
  if (!dock) return n;
  n = withDock(n, dock, { open: true, active: id });
  return device === 'tablet' && (dock === 'left' || dock === 'center') && n.pane !== dock ? { ...n, pane: dock } : n;
}

/** Ctrl/Cmd+B: close the explorer's dock; open it again as it was, or show the explorer when it is hidden. A dock with the chat
 *  in it cannot close: the explorer is hidden instead. */
export function toggleExplorer(l: DeviceLayout, device: Device): DeviceLayout {
  const dock = dockOf(l, 'explorer');
  if (device === 'tablet' || !dock || !shown(l, 'explorer')) return reveal(l, device, 'explorer');
  if (!explorerOpen(l)) return withDock(l, dock, { open: true });   // (on the tab it was on: Git, Search ...)
  return collapsible(l, dock) ? withDock(l, dock, { open: false }) : setHidden(l, 'explorer', true);
}

export const setMode = (l: DeviceLayout, dock: DockId, mode: 'tabs' | 'stack'): DeviceLayout => withDock(l, dock, { mode });
export const setActive = (l: DeviceLayout, dock: DockId, id: WidgetId): DeviceLayout => withDock(l, dock, { active: id });
export const setPane = (l: DeviceLayout, pane: 'left' | 'center'): DeviceLayout => (l.pane === pane ? l : { ...l, pane });

export function setDockSize(l: DeviceLayout, dock: DockId, px: number): DeviceLayout {
  if (dock === 'center' || !Number.isFinite(px)) return l;
  const [lo, hi] = dockBounds(l, dock);
  return withDock(l, dock, { size: Math.round(Math.min(hi, Math.max(lo, px))) });
}
export function setWidgetSize(l: DeviceLayout, id: WidgetId, px: number): DeviceLayout {
  if (!Number.isFinite(px)) return l;
  const v = Math.round(Math.min(STACK_BOUNDS[1], Math.max(STACK_BOUNDS[0], px)));
  return l.sizes[id] === v ? l : { ...l, sizes: { ...l.sizes, [id]: v } };
}

/** Shift+arrow on a widget: its dock wider or taller (the left dock grows to the right, the right dock to the left, the
 *  bottom dock upward); up and down also size a widget of a stack that has one below it. */
export function growWidget(l: DeviceLayout, id: WidgetId, key: 'ArrowLeft' | 'ArrowRight' | 'ArrowUp' | 'ArrowDown', step = 40): DeviceLayout {
  const dock = dockOf(l, id);
  if (!dock) return l;
  const cur = l.docks[dock];
  if (dock === 'left' && (key === 'ArrowRight' || key === 'ArrowLeft')) return setDockSize(l, dock, cur.size + (key === 'ArrowRight' ? step : -step));
  if (dock === 'right' && (key === 'ArrowLeft' || key === 'ArrowRight')) return setDockSize(l, dock, cur.size + (key === 'ArrowLeft' ? step : -step));
  if (dock === 'bottom' && (key === 'ArrowUp' || key === 'ArrowDown')) return setDockSize(l, dock, cur.size + (key === 'ArrowUp' ? step : -step));
  if (cur.mode === 'stack' && (key === 'ArrowUp' || key === 'ArrowDown')) {
    const list = visibleIn(l, dock);
    if (dock !== 'bottom' && list.indexOf(id) >= 0 && list.indexOf(id) < list.length - 1) return setWidgetSize(l, id, (l.sizes[id] ?? STACK_DEFAULT) + (key === 'ArrowDown' ? step : -step));
  }
  if (dock === 'bottom' && cur.mode === 'stack' && (key === 'ArrowLeft' || key === 'ArrowRight')) {
    const list = visibleIn(l, dock);
    if (list.indexOf(id) >= 0 && list.indexOf(id) < list.length - 1) return setWidgetSize(l, id, (l.sizes[id] ?? STACK_DEFAULT) + (key === 'ArrowRight' ? step : -step));
  }
  return l;
}

export const resetLayout = (device: Device): DeviceLayout => defaultLayout(device);

// ---------------------------------------------------------------- the page from the layout

export interface Arrange {
  /** what each dock draws now: hidden widgets and the editor giving way to the chat left out */
  shown: Record<DockId, WidgetId[]>;
  /** desktop: the left and right docks' widths (px) after the centre's minimum, null: not drawn */
  left: number | null;
  right: number | null;
  /** desktop: the bottom dock's height, null: not drawn */
  bottom: number | null;
  /** the column that takes the room the others leave: the centre; a side dock (the chat's) when the centre has nothing */
  fill: DockId;
  /** the centre has nothing to show: the chat has the middle (no file, diff or preview open, the terminal closed) */
  chatFirst: boolean;
  /** the centre has only the bottom dock to show */
  bottomFill: boolean;
  /** tablet: the dock beside the chat now */
  pane: 'left' | 'center';
  /** tablet: both have something, so the Files / Editor switch shows */
  panes: boolean;
}

/** Tablet: the dock beside the chat (its remembered pane while that has something to show, else the other), and whether
 *  both have, so the Files / Editor switch shows. */
export function tabletPane(l: DeviceLayout, editing = false): { pane: 'left' | 'center'; both: boolean } {
  const have = { left: visibleIn(l, 'left').length > 0 || editing, center: visibleIn(l, 'center').length > 0 || editing };
  const other = l.pane === 'left' ? 'center' : 'left';
  return { pane: have[l.pane] || !have[other] ? l.pane : other, both: have.left && have.center };
}

/** What the page draws for a layout: the widths the docks get (the centre keeps CENTER_MIN), the chat taking the middle
 *  until something is open. Customizing draws every dock, even an empty one — a place to drop a widget. */
export function arrange(l: DeviceLayout, device: Device, ctx: { vw: number; noTabs: boolean; editing: boolean }): Arrange {
  const sh = { left: visibleIn(l, 'left'), center: visibleIn(l, 'center'), right: visibleIn(l, 'right'), bottom: visibleIn(l, 'bottom') };
  const edit = ctx.editing;
  if (device === 'tablet') {
    const { pane, both } = tabletPane(l, edit);
    const right = Math.min(Math.max(l.docks.right.size, Math.round(ctx.vw * 0.45)), ctx.vw - 300);
    return { shown: sh, left: null, right, bottom: null, fill: pane, chatFirst: false, bottomFill: false, pane, panes: both };
  }
  // the editor gives way to the chat while no file is open and nothing is below it
  if (!edit && ctx.noTabs && sh.center.includes('editor') && sh.bottom.length === 0) sh.center = sh.center.filter((id) => id !== 'editor');
  const colEmpty = sh.center.length === 0 && sh.bottom.length === 0 && !edit;
  const has = (d: 'left' | 'right') => edit || (sh[d].length > 0 && (l.docks[d].open || !collapsible(l, d)));
  const hasL = has('left');
  const hasR = has('right');
  const slot = (d: 'left' | 'right') => (sh[d].length === 0 ? Math.min(l.docks[d].size, 160) : l.docks[d].size);
  const left = hasL ? Math.min(slot('left'), Math.max(dockBounds(l, 'left')[0], ctx.vw - (hasR ? slot('right') : 0) - CENTER_MIN)) : null;
  const right = hasR ? Math.min(slot('right'), Math.max(dockBounds(l, 'right')[0], ctx.vw - (left ?? 0) - CENTER_MIN)) : null;
  const chatSide = (['left', 'right'] as const).find((d) => l.place[d].includes('chat') && (d === 'left' ? hasL : hasR));
  const fill: DockId = colEmpty ? chatSide ?? (hasR ? 'right' : hasL ? 'left' : 'center') : 'center';
  const bottom = sh.bottom.length > 0 ? l.docks.bottom.size : edit ? Math.min(l.docks.bottom.size, 96) : null;
  return { shown: sh, left, right, bottom, fill, chatFirst: fill !== 'center', bottomFill: !edit && sh.center.length === 0 && sh.bottom.length > 0, pane: 'left', panes: false };
}
