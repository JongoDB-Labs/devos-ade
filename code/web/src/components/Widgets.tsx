// The page's widgets in their docks (layout.ts): a dock shows its widgets as tabs or stacked, and Customize puts a
// small header on each — a handle to drag it to another dock, an eye to hide it — a tray for the hidden ones, and
// keys for all of it (Alt+arrows move, Shift+arrows resize, H hides; an aria-live line says what changed).
// Drag is pointer events on the handle, the drop found with elementFromPoint; nothing here is third-party.
import type { ComponentChildren } from 'preact';
import { useRef } from 'preact/hooks';
import { useSel } from '../store';
import {
  store,
  addWidgetBack,
  deviceNow,
  growWidgetBy,
  hideWidget,
  moveWidgetTo,
  nextDockOf,
  pickTab,
  resetWidgets,
  resizeWidget,
  setDockMode,
  setDrag,
  setLayoutEdit,
  shiftWidgetBy,
  showGit,
  showSearch,
} from '../app';
import * as lay from '../layout';
import type { Device, DeviceLayout, DockId, WidgetId } from '../layout';
import { changedCount } from '../git';
import { MOD } from './EditorArea';
import { Icon } from './icons';
import { Splitter } from './ui';

/** Widgets that keep their state (a terminal's connection, the editor's tabs, the chat's draft) stay mounted while
 *  hidden or behind another tab. */
const KEEP: readonly WidgetId[] = ['editor', 'terminal', 'chat'];

const TAB_TITLE: Partial<Record<WidgetId, string>> = {
  explorer: 'Explorer',
  search: `Search in files (${MOD}+Shift+F)`,
  git: `Git (${MOD}+Shift+G)`,
  sessions: 'Projects and their sessions',
};
const tabTestId = (id: WidgetId) => (id === 'explorer' ? 'side-files' : lay.SIDE.includes(id) ? `side-${id}` : `dock-tab-${id}`);

/** The Git tab's count of changed files, the Projects tab's count of sessions waiting for you. */
/** The tabs with a count. A narrow dock hides an unselected tab's word, which left the count as the tab's whole name
 *  ("3, tab"): these are named by their word, and the count, in words, is the tab's description. */
const COUNTED: ReadonlySet<WidgetId> = new Set<WidgetId>(['git', 'sessions']);

function TabBadge({ id }: { id: WidgetId }) {
  const pending = useSel(store, (s) => (id === 'sessions' ? Object.values(s.views).reduce((n, v) => n + v.permissions.length, 0) : 0));
  const changes = useSel(store, (s) => (id === 'git' ? changedCount(s.git.status) : 0));
  const says = id === 'git' && changes > 0 ? `${changes} changed ${changes === 1 ? 'file' : 'files'}`
    : id === 'sessions' && pending > 0 ? `${pending} waiting for your permission` : '';
  return (
    <>
      {id === 'git' && changes > 0 && <span class="badge" data-testid="git-count">{changes > 999 ? '999+' : changes}</span>}
      {id === 'sessions' && pending > 0 && <span class="badge warn">{pending}</span>}
      {COUNTED.has(id) && <span hidden id={`tab-count-${id}`}>{says}</span>}
    </>
  );
}

// ---------------------------------------------------------------- drag and drop

type Over = { dock: DockId; before: WidgetId | null } | null;

/** Where a widget dropped at this point would go: the dock under it and the widget it goes before (null: the end). */
function dropAt(x: number, y: number, id: WidgetId): Over {
  const el = document.elementFromPoint(x, y) as HTMLElement | null;
  const dockEl = el?.closest<HTMLElement>('[data-dock]');
  if (!el || !dockEl) return null;
  const dock = dockEl.dataset.dock as DockId;
  const l = store.get().prefs.layout[deviceNow()];
  const order = lay.visibleIn(l, dock).filter((w) => w !== id);
  const after = (w: WidgetId) => order[order.indexOf(w) + 1] ?? null;
  const split = (box: HTMLElement, w: WidgetId, horizontal: boolean): Over => {
    const r = box.getBoundingClientRect();
    const first = horizontal ? x < r.left + r.width / 2 : y < r.top + r.height / 2;
    return { dock, before: first ? w : after(w) };
  };
  const tab = el.closest<HTMLElement>('[data-tab]');
  if (tab && tab.dataset.tab !== id) return split(tab, tab.dataset.tab as WidgetId, true);
  const item = el.closest<HTMLElement>('.dock-item[data-widget]');
  if (item && l.docks[dock].mode === 'stack' && item.dataset.widget !== id) return split(item, item.dataset.widget as WidgetId, dock === 'bottom');
  return { dock, before: null };
}

/** The widget's header while customizing: its handle (drag, or the keys), its name, an eye to hide it. */
function Head({ id, device }: { id: WidgetId; device: Device }) {
  const info = lay.WIDGET_INFO[id];
  const movable = lay.allowedDocks(device, id).length > 0;
  const end = (commit: boolean) => {
    const d = store.get().layoutUi.drag;
    setDrag(null);
    if (commit && d?.id === id && d.over) moveWidgetTo(id, d.over.dock, d.over.before);
  };
  return (
    <div class="wd-head">
      {movable && (
        <button
          type="button"
          class="wd-grip"
          aria-label={`Move ${info.label}: drag this handle, or focus the widget and use Alt+arrow keys`}
          title="Drag to another dock, or between widgets"
          data-testid={`wd-grip-${id}`}
          onPointerDown={(e) => {
            if (e.button !== 0) return;
            (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
            setDrag({ id, over: null });
          }}
          onPointerMove={(e) => {
            const d = store.get().layoutUi.drag;
            if (!d || d.id !== id) return;
            const over = dropAt(e.clientX, e.clientY, id);
            if (over?.dock !== d.over?.dock || over?.before !== d.over?.before) setDrag({ id, over });
          }}
          onPointerUp={() => end(true)}
          onPointerCancel={() => end(false)}
          onKeyDown={(e) => {
            if (e.key === 'Escape' && store.get().layoutUi.drag) {
              e.stopPropagation();
              end(false);
            }
          }}
        >
          <Icon name="grip" size={14} />
        </button>
      )}
      <span class="wd-name">{info.label}</span>
      {info.hideable && (id !== 'terminal' || device === 'desktop') && (
        <button type="button" class="icon-btn tiny" aria-label={`Hide ${info.label}`} title={`Hide ${info.label} (H)`} onClick={() => (hideWidget(id), later(`[data-testid="tray-add-${id}"]`))} data-testid={`wd-hide-${id}`}>
          <Icon name="eye" size={15} />
        </button>
      )}
    </div>
  );
}

/** Focus follows a widget that moved to another dock (it is drawn anew there) or into the tray. */
function later(selector: string): void {
  setTimeout(() => document.querySelector<HTMLElement>(selector)?.focus(), 80);
}

/** The keys of a focused widget while customizing. Only the widget itself or its header answers: inside the widget
 *  (the editor, a text box) the arrows are the widget's own. */
function widgetKeys(id: WidgetId) {
  return (e: KeyboardEvent) => {
    const t = e.target as HTMLElement;
    if (t !== e.currentTarget && !t.closest('.wd-head')) return;
    const k = e.key;
    const arrow = k === 'ArrowLeft' || k === 'ArrowRight' || k === 'ArrowUp' || k === 'ArrowDown';
    const plain = !e.ctrlKey && !e.metaKey;
    if (arrow && e.altKey && !e.shiftKey && plain && id !== 'status') {
      e.preventDefault();
      if (k === 'ArrowLeft' || k === 'ArrowRight') nextDockOf(id, k === 'ArrowRight' ? 1 : -1);
      else shiftWidgetBy(id, k === 'ArrowUp' ? -1 : 1);
      later(`[data-widget="${id}"]`);
    } else if (arrow && e.shiftKey && !e.altKey && plain && id !== 'status') {
      e.preventDefault();
      growWidgetBy(id, k as 'ArrowLeft');
    } else if ((k === 'h' || k === 'H') && !e.altKey && !e.shiftKey && plain) {
      e.preventDefault();
      hideWidget(id);
      if (lay.WIDGET_INFO[id].hideable) later(`[data-testid="tray-add-${id}"]`);
    }
  };
}

const editProps = (id: WidgetId, where: string, editing: boolean) =>
  editing
    ? {
        tabIndex: 0,
        role: 'group' as const,
        'aria-roledescription': 'widget',
        'aria-label': `${lay.WIDGET_INFO[id].label}, in ${where}. Alt plus the arrow keys move it, Shift plus the arrow keys resize it${lay.WIDGET_INFO[id].hideable ? ', H hides it' : ''}.`,
        onKeyDown: widgetKeys(id),
      }
    : {};

// ---------------------------------------------------------------- docks

export interface DockProps {
  dock: DockId;
  layout: DeviceLayout;
  device: Device;
  /** what the dock draws now (layout.ts arrange): hidden widgets, and the editor giving way to the chat, left out */
  shown: WidgetId[];
  render: (id: WidgetId) => ComponentChildren;
  /** the dock is not drawn (its widgets that keep their state stay mounted) */
  hidden?: boolean;
  /** the dock's own label for a screen reader, where it is more than its widgets' names */
  label?: string;
}

export function Dock(p: DockProps) {
  const { dock, layout, device, shown } = p;
  const editing = useSel(store, (s) => s.layoutUi.edit);
  const drag = useSel(store, (s) => s.layoutUi.drag);
  const els = useRef<Record<string, HTMLElement | null>>({});
  const st = layout.docks[dock];
  const tabs = st.mode === 'tabs';
  const across = dock === 'bottom';
  const active = tabs ? lay.activeIn(layout, dock, shown) : null;
  const on = (id: WidgetId) => shown.includes(id) && (!tabs || id === active);
  const items = layout.place[dock].filter((id) => on(id) || KEEP.includes(id));
  const last = shown.filter(on).pop();
  const sideOnly = shown.length > 0 && shown.every((id) => lay.SIDE.includes(id));
  const mark = (id: WidgetId): string => {
    if (!drag?.over || drag.over.dock !== dock || drag.id === id) return '';
    if (drag.over.before === id) return ' drop-before';
    return drag.over.before === null && id === shown.filter((w) => w !== drag.id).pop() ? ' drop-after' : '';
  };
  const names = shown.map((id) => lay.WIDGET_INFO[id].label);
  const children: ComponentChildren[] = [];
  for (const id of items) {
    const stacked = !tabs && on(id) && id !== last;
    children.push(
      <div
        key={id}
        class={`dock-item wd${on(id) ? '' : ' hidden'}${editing ? ' wd-edit' : ''}${drag?.id === id ? ' wd-dragging' : ''}${mark(id)}`}
        data-widget={id}
        ref={(el) => {
          els.current[id] = el;
          if (el) el.style.flex = stacked ? `0 1 ${layout.sizes[id] ?? lay.STACK_DEFAULT}px` : '';
        }}
        {...editProps(id, lay.DOCK_LABEL[dock].toLowerCase(), editing)}
      >
        {editing && <Head id={id} device={device} />}
        <div class="wd-body">{p.render(id)}</div>
      </div>,
    );
    if (stacked) {
      children.push(
        <Splitter
          key={`split-${id}`}
          axis={across ? 'x' : 'y'}
          value={Math.round(across ? els.current[id]?.offsetWidth ?? lay.STACK_DEFAULT : els.current[id]?.offsetHeight ?? lay.STACK_DEFAULT)}
          min={lay.STACK_BOUNDS[0]}
          max={lay.STACK_BOUNDS[1]}
          onChange={(v) => resizeWidget(id, v)}
          label={`Resize ${lay.WIDGET_INFO[id].label}`}
          testid={`split-${id}`}
        />,
      );
    }
  }
  const isAside = sideOnly;
  const Tag = isAside ? 'aside' : 'div';
  return (
    <Tag
      class={`dock dock-${dock}${isAside ? ' side' : ''}${p.hidden ? ' hidden' : ''}${drag?.over?.dock === dock ? ' drop-over' : ''}`}
      data-dock={dock}
      data-testid={`dock-${dock}`}
      aria-label={p.label ?? (isAside ? (names.length === 4 ? 'Explorer and sessions' : names.join(' and ')) : names.length > 1 ? names.join(', ') : undefined)}
      role={isAside || names.length < 2 ? undefined : 'group'}
    >
      {editing && (
        <div class="dock-edit">
          <span class="dock-edit-name">{lay.DOCK_LABEL[dock]}</span>
          <div class="seg" role="group" aria-label={`${lay.DOCK_LABEL[dock]}: how its widgets show`}>
            <button type="button" aria-pressed={tabs} onClick={() => setDockMode(dock, 'tabs')} data-testid={`mode-tabs-${dock}`}>Tabs</button>
            <button type="button" aria-pressed={!tabs} onClick={() => setDockMode(dock, 'stack')} data-testid={`mode-stack-${dock}`}>Stacked</button>
          </div>
        </div>
      )}
      {tabs && shown.length > 1 && (
        <div class="dock-strip">
          <div class="side-tabs" role="tablist" aria-label={`${lay.DOCK_LABEL[dock]} widgets`}>
            {shown.map((id) => (
              <button
                key={id}
                type="button"
                role="tab"
                class={mark(id).trim()}
                aria-selected={id === active}
                data-tab={id}
                title={TAB_TITLE[id] ?? lay.WIDGET_INFO[id].label}
                aria-label={COUNTED.has(id) ? lay.WIDGET_INFO[id].tab : undefined}
                aria-describedby={COUNTED.has(id) ? `tab-count-${id}` : undefined}
                data-testid={tabTestId(id)}
                onClick={() => (!editing && id === 'search' ? showSearch() : !editing && id === 'git' ? showGit() : pickTab(dock, id))}
              >
                <Icon name={lay.WIDGET_INFO[id].icon} size={15} /> <span class="st-label">{lay.WIDGET_INFO[id].tab}</span>
                <TabBadge id={id} />
              </button>
            ))}
          </div>
        </div>
      )}
      <div class={`dock-body${tabs ? '' : ' stacked'}${across ? ' across' : ''}`}>
        {children}
        {editing && shown.length === 0 && <div class="dock-empty" data-testid={`dock-empty-${dock}`}>Drop a widget here</div>}
      </div>
    </Tag>
  );
}

/** The status bar as a widget: the page's footer, which can be hidden; customizing gives it a header like the others. */
export function StatusFrame({ children }: { children: ComponentChildren }) {
  const editing = useSel(store, (s) => s.layoutUi.edit);
  return (
    <div class={`wd wd-status${editing ? ' wd-edit' : ''}`} data-widget="status" {...editProps('status', 'the footer', editing)}>
      {editing && <Head id="status" device="desktop" />}
      {children}
    </div>
  );
}

// ---------------------------------------------------------------- the tray

/** Customize's bar under the top bar: the hidden widgets to add back, Reset to default, Done, and the line a screen
 *  reader hears each change in. */
export function WidgetTray({ device }: { device: Device }) {
  const l = useSel(store, (s) => s.prefs.layout[device]);
  const say = useSel(store, (s) => s.layoutUi.say);
  const hidden = l.hidden;
  return (
    <section class="wd-tray" aria-label="Widgets" data-testid="widget-tray">
      <strong class="wd-tray-title">Customize</strong>
      <span class="wd-tray-hint muted small">Drag a widget by its handle into a dock, or focus it and use Alt+arrows to move, Shift+arrows to resize, H to hide.</span>
      <ul class="wd-tray-list" aria-label="Hidden widgets">
        {hidden.length === 0 && <li class="muted small" data-testid="tray-none">Every widget is shown.</li>}
        {hidden.map((id) => (
          <li key={id}>
            <Icon name={lay.WIDGET_INFO[id].icon} size={14} />
            <span>{lay.WIDGET_INFO[id].label}</span>
            <button type="button" class="btn small" aria-label={`Add ${lay.WIDGET_INFO[id].label} back`} onClick={() => addWidgetBack(id)} data-testid={`tray-add-${id}`}>
              Add back
            </button>
          </li>
        ))}
      </ul>
      <span class="wd-tray-actions">
        <button type="button" class="btn small" onClick={resetWidgets} disabled={lay.isDefault(l, device)} data-testid="layout-reset">
          Reset to default
        </button>
        <button type="button" class="btn small primary" onClick={() => setLayoutEdit(false)} data-testid="layout-done">
          Done
        </button>
      </span>
      <span class="sr" role="status" aria-live="polite" data-testid="layout-live">{say}</span>
    </section>
  );
}
