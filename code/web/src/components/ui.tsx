// Small building blocks: a dropdown (fixed-position panel, so no pane clips it), a modal dialog, a phone sheet and
// a splitter. Positions are set through the CSSOM (element.style), which the page's CSP allows; no inline style
// attributes, no innerHTML.
import { Component, h, type ComponentChildren, type FunctionComponent } from 'preact';
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { Icon } from './icons';

let tipSeq = 0;
/** A small styled tooltip for the control inside: what it does and its shortcut. It shows on hover (after a short
 *  delay) and on keyboard focus, above the control (below it near the top of the window), kept on screen; Escape, a
 *  click or leaving hides it. Positioned through the CSSOM (position: fixed, so no pane or the status bar clips it). The
 *  control names itself (aria-label) and points at the tip (aria-describedby: `tipId(id)`). */
export function Tip(props: { text: string; keys?: string; id: string; children: ComponentChildren; class?: string; off?: boolean }) {
  const [want, setOpen] = useState(false);
  const open = want && !props.off;   // (off: its panel is open)
  const wrap = useRef<HTMLSpanElement>(null);
  const tip = useRef<HTMLSpanElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const clear = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
  };
  const show = (delay: number) => {
    clear();
    timer.current = setTimeout(() => setOpen(true), delay);
  };
  const hide = () => {
    clear();
    setOpen(false);
  };
  useEffect(() => clear, []);
  useLayoutEffect(() => {
    if (!open || !wrap.current || !tip.current) return;
    const r = wrap.current.getBoundingClientRect();
    const t = tip.current;
    const w = Math.min(t.offsetWidth, innerWidth - 16);
    const left = Math.max(8, Math.min(r.left + r.width / 2 - w / 2, innerWidth - w - 8));
    t.style.left = `${left}px`;
    // (one of top and bottom: what the last showing set is cleared first — the tip stays mounted between showings)
    t.style.top = '';
    t.style.bottom = '';
    if (r.top > t.offsetHeight + 12) t.style.bottom = `${innerHeight - r.top + 6}px`;
    else t.style.top = `${r.bottom + 6}px`;
  }, [open]);
  useEffect(() => {
    if (!open) return;
    const key = (e: KeyboardEvent) => {
      if (e.key === 'Escape') hide();
    };
    document.addEventListener('keydown', key);
    return () => document.removeEventListener('keydown', key);
  }, [open]);
  return (
    <span
      ref={wrap}
      class={`tip-wrap${props.class ? ' ' + props.class : ''}`}
      onMouseEnter={() => show(350)}
      onMouseLeave={hide}
      onFocusIn={(e) => {
        // keyboard focus only (a click focuses too: its own panel or action follows, not a tip)
        if ((e.target as HTMLElement).matches?.(':focus-visible')) show(0);
      }}
      onFocusOut={hide}
      onPointerDown={hide}
    >
      {props.children}
      <span ref={tip} id={tipId(props.id)} role="tooltip" class="tip" hidden={!open} data-testid={`tip-${props.id}`}>
        <span class="tip-text">{props.text}</span>
        {props.keys && <kbd class="tip-keys">{props.keys}</kbd>}
      </span>
    </span>
  );
}
/** The id of a Tip's tooltip (for aria-describedby). */
export const tipId = (id: string): string => `tip-${id}`;
export const nextTipId = (): string => `t${++tipSeq}`;

// What keeps the browser's own context menu (and its own long-press): text fields, the editor, the terminal, a text
// selection's links. Everything else carrying data-ctx gets the item menu.
const OWN_MENU = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], .cm-editor, .xterm';
const LONG_PRESS_MS = 480;
const LONG_PRESS_SLOP = 10;
// the dropdowns open now, the newest last: Escape and the arrows belong to that one alone (a menu opened from inside another)
const openStack: object[] = [];
/** The control a focus goes back to when an item menu closes: the item itself when it takes focus, else its own button. */
function focusTarget(item: HTMLElement): HTMLElement | null {
  if (item.tabIndex >= 0) return item;
  return item.querySelector<HTMLElement>('[tabindex="0"], a[href], button:not(.dd-trigger):not(:disabled), input:not([type=hidden]), .dd-trigger');
}

export function Dropdown(props: {
  /** an item menu: this item's right-click, long-press (touch) and Shift+F10 / the context-menu key open this same menu
   *  at the pointer (or the focused control) — the item is the nearest ancestor with data-ctx, else the parent */
  ctx?: boolean;
  trigger: ComponentChildren;
  title: string;
  /** a styled tooltip instead of the browser's title: what it does and its shortcut (keys) */
  tip?: { id: string; text: string; keys?: string };
  children: (close: () => void) => ComponentChildren;
  class?: string;
  panelClass?: string;
  align?: 'left' | 'right';
  disabled?: boolean;
  testid?: string;
  /** a change opens it (a keyboard shortcut elsewhere) */
  openSignal?: number;
  /** a class on the trigger button itself */
  triggerClass?: string;
  /** what gets the focus when it opens (a selector in the panel; default: the checked item, else the first) */
  focus?: string;
  /** a panel that holds more than menu items (a search field, its own buttons) is a dialog, named PANELLABEL: a menu
   *  may hold menu items only */
  panelRole?: 'menu' | 'dialog';
  panelLabel?: string;
}) {
  const [open, setOpen] = useState(false);
  const btn = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const root = useRef<HTMLDivElement>(null);
  // where an item menu opened (the pointer, or the focused control), and the item it belongs to
  const at = useRef<{ x: number; y: number } | null>(null);
  const item = useRef<HTMLElement | null>(null);
  const token = useRef({});
  const signal = useRef(props.openSignal);
  useEffect(() => {
    if (props.openSignal === signal.current) return;
    signal.current = props.openSignal;
    if (!props.disabled) setOpen(true);
  }, [props.openSignal]);
  const close = () => {
    setOpen(false);
    // (an item menu: back to the item; its own button's menu: back to that button)
    const back = at.current && item.current ? focusTarget(item.current) : null;
    (back ?? btn.current)?.focus();
  };
  const openAt = (x: number, y: number) => {
    if (props.disabled) return;
    at.current = { x, y };
    setOpen(true);
  };

  // --- an item menu: right-click, long-press, the keyboard ---
  useEffect(() => {
    if (!props.ctx || !root.current) return;
    const target = root.current.closest<HTMLElement>('[data-ctx]') ?? root.current.parentElement;
    if (!target) return;
    item.current = target;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let start = { x: 0, y: 0 };
    let heldAt = 0;
    const own = (e: Event) => e.target instanceof Element && (e.target.closest(OWN_MENU) !== null || panel.current?.contains(e.target) === true);
    const stop = () => { if (timer) clearTimeout(timer); timer = null; };
    const onContext = (e: MouseEvent) => {
      if (e.target instanceof Element && panel.current?.contains(e.target)) { e.preventDefault(); return; }
      if (own(e) || e.defaultPrevented) return;
      e.preventDefault();
      e.stopPropagation();
      // (a keyboard's context-menu key reports the pointer at 0,0: its own handler below places it)
      if (e.clientX === 0 && e.clientY === 0 && e.detail === 0) return;
      openAt(e.clientX, e.clientY);
    };
    const onKey = (e: KeyboardEvent) => {
      if (!(e.key === 'ContextMenu' || (e.key === 'F10' && e.shiftKey)) || own(e)) return;
      e.preventDefault();
      e.stopPropagation();
      const f = document.activeElement instanceof HTMLElement && target.contains(document.activeElement) ? document.activeElement : target;
      const r = f.getBoundingClientRect();
      item.current = target;
      openAt(Math.min(r.left + 24, r.right - 4), r.top + Math.min(r.height, 28));
    };
    const onDown = (e: PointerEvent) => {
      if (e.pointerType === 'mouse' || e.button !== 0 || own(e)) return;
      stop();
      start = { x: e.clientX, y: e.clientY };
      timer = setTimeout(() => {
        timer = null;
        heldAt = Date.now();
        openAt(start.x, start.y);
      }, LONG_PRESS_MS);
    };
    const onMove = (e: PointerEvent) => {
      if (timer && Math.hypot(e.clientX - start.x, e.clientY - start.y) > LONG_PRESS_SLOP) stop();
    };
    // the lift of a long press is not a tap on the item
    const onClick = (e: MouseEvent) => {
      if (Date.now() - heldAt < 700) { e.preventDefault(); e.stopPropagation(); }
    };
    target.addEventListener('contextmenu', onContext);
    target.addEventListener('keydown', onKey);
    target.addEventListener('pointerdown', onDown);
    target.addEventListener('pointermove', onMove);
    target.addEventListener('pointerup', stop);
    target.addEventListener('pointercancel', stop);
    target.addEventListener('click', onClick, true);
    return () => {
      stop();
      target.removeEventListener('contextmenu', onContext);
      target.removeEventListener('keydown', onKey);
      target.removeEventListener('pointerdown', onDown);
      target.removeEventListener('pointermove', onMove);
      target.removeEventListener('pointerup', stop);
      target.removeEventListener('pointercancel', stop);
      target.removeEventListener('click', onClick, true);
    };
  }, [props.ctx, props.disabled]);

  useLayoutEffect(() => {
    if (!open || !btn.current || !panel.current) return;
    const r = btn.current.getBoundingClientRect();
    const p = panel.current;
    const vw = innerWidth;
    const vh = innerHeight;
    const w = Math.min(p.offsetWidth, vw - 16);
    const point = at.current;
    p.style.top = '';
    p.style.bottom = '';
    if (point) {
      // at the pointer (or the focused control), kept inside the window: moved left and up as far as it needs
      const h = Math.min(p.offsetHeight, vh - 16);
      p.style.left = `${Math.max(8, Math.min(point.x, vw - w - 8))}px`;
      p.style.top = `${Math.max(8, Math.min(point.y, vh - h - 8))}px`;
      p.style.maxHeight = `${vh - 16}px`;
    } else {
      let left = props.align === 'right' ? r.right - w : r.left;
      left = Math.max(8, Math.min(left, vw - w - 8));
      const below = vh - r.bottom;
      const h = p.offsetHeight;
      p.style.left = `${left}px`;
      if (below >= Math.min(h, 320) + 8 || below > r.top) {
        p.style.top = `${r.bottom + 4}px`;
        p.style.maxHeight = `${Math.max(160, below - 12)}px`;
      } else {
        p.style.bottom = `${vh - r.top + 4}px`;
        p.style.maxHeight = `${Math.max(160, r.top - 12)}px`;
      }
    }
    const first = (props.focus ? p.querySelector<HTMLElement>(props.focus) : null) ?? p.querySelector<HTMLElement>('[aria-checked="true"], [role=menuitem], [role=menuitemradio], input, button');
    first?.focus({ preventScroll: true });
    // the item checked in a long list: in view
    p.querySelector<HTMLElement>('[aria-checked="true"]')?.scrollIntoView?.({ block: 'nearest' });
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const me = token.current;
    openStack.push(me);
    const down = (e: PointerEvent) => {
      const t = e.target as Node;
      if (!panel.current?.contains(t) && !btn.current?.contains(t)) setOpen(false);
    };
    const key = (e: KeyboardEvent) => {
      if (openStack[openStack.length - 1] !== me) return;   // (a menu opened inside this one has the keys)
      if (e.key === 'Escape') {
        e.stopPropagation();
        close();
      } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        const items = [...(panel.current?.querySelectorAll<HTMLElement>('[role=menuitem]:not([disabled]), [role=menuitemradio]:not([disabled])') ?? [])];
        if (!items.length) return;
        e.preventDefault();
        const i = items.indexOf(document.activeElement as HTMLElement);
        const n = e.key === 'ArrowDown' ? (i + 1) % items.length : (i - 1 + items.length) % items.length;
        items[n].focus();
      }
    };
    const resize = () => setOpen(false);
    // (a scroll of the page behind it moves what it points at: an item menu closes; a scroll inside it does not)
    const scroll = (e: Event) => { if (at.current && !(e.target instanceof Node && panel.current?.contains(e.target))) setOpen(false); };
    document.addEventListener('pointerdown', down, true);
    document.addEventListener('keydown', key, true);
    document.addEventListener('scroll', scroll, true);
    addEventListener('resize', resize);
    return () => {
      const i = openStack.indexOf(me);
      if (i >= 0) openStack.splice(i, 1);
      document.removeEventListener('pointerdown', down, true);
      document.removeEventListener('keydown', key, true);
      document.removeEventListener('scroll', scroll, true);
      removeEventListener('resize', resize);
      at.current = null;
    };
  }, [open]);

  const button = (
    <button
      ref={btn}
      type="button"
      class={`dd-trigger${props.triggerClass ? ' ' + props.triggerClass : ''}`}
      title={props.tip ? undefined : props.title}
      aria-label={props.title}
      aria-describedby={props.tip ? tipId(props.tip.id) : undefined}
      aria-keyshortcuts={props.tip?.keys ? ariaKeys(props.tip.keys) : undefined}
      aria-haspopup={props.panelRole === 'dialog' ? 'dialog' : 'true'}
      aria-expanded={open}
      disabled={props.disabled}
      data-testid={props.testid}
      onClick={() => {
        at.current = null;
        setOpen(!open);
      }}
    >
      {props.trigger}
    </button>
  );
  return (
    <div ref={root} class={`dd${props.class ? ' ' + props.class : ''}`} onClick={(e) => e.stopPropagation()}>
      {props.tip ? (
        <Tip id={props.tip.id} text={props.tip.text} keys={props.tip.keys} off={open}>
          {button}
        </Tip>
      ) : (
        button
      )}
      {open && (
        <div ref={panel} class={`dd-panel${props.panelClass ? ' ' + props.panelClass : ''}`} role={props.panelRole ?? 'menu'} aria-label={props.panelLabel}>
          {props.children(close)}
        </div>
      )}
    </div>
  );
}

/** "Alt+R" → "Alt+R", "Ctrl+`" → "Control+`", "⌘+K · Ctrl+Shift+P" → "Meta+K Control+Shift+P" (aria-keyshortcuts). */
export function ariaKeys(keys: string): string {
  return keys
    .split('·')
    .map((k) => k.trim().replace(/⌘/g, 'Meta').replace(/\bCtrl\b/g, 'Control'))
    .filter(Boolean)
    .join(' ');
}

export function MenuItem(props: {
  onSelect: () => void;
  checked?: boolean;
  disabled?: boolean;
  icon?: string;
  children: ComponentChildren;
  hint?: ComponentChildren;
  danger?: boolean;
  testid?: string;
  /** a greyed item's reason (setuplinks.ts): choosing it goes where that is turned on — a plain menu item, never a
   *  choice of this menu's, its words saying where */
  setup?: string;
}) {
  const setup = props.setup !== undefined;
  return (
    <button
      type="button"
      class={`mi${props.danger ? ' danger' : ''}${setup ? ' mi-setup' : ''}`}
      role={props.checked === undefined || setup ? 'menuitem' : 'menuitemradio'}
      aria-checked={props.checked === undefined || setup ? undefined : props.checked}
      disabled={props.disabled}
      data-testid={props.testid}
      data-setup={props.setup}
      onClick={props.onSelect}
    >
      {props.icon !== undefined && <span class="mi-icon">{props.icon ? <Icon name={props.icon} /> : null}</span>}
      <span class="mi-body">{props.children}</span>
      {props.hint !== undefined && <span class="mi-hint">{props.hint}</span>}
      {props.checked && <Icon name="check" class="mi-check" />}
    </button>
  );
}

export function Dialog(props: { title: string; onClose: () => void; children: ComponentChildren; wide?: boolean; testid?: string }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
    return () => d?.close();
  }, []);
  return (
    <dialog
      ref={ref}
      class={`dlg${props.wide ? ' wide' : ''}`}
      aria-label={props.title}
      data-testid={props.testid}
      onCancel={(e) => {
        e.preventDefault();
        props.onClose();
      }}
      onClick={(e) => {
        if (e.target === ref.current) props.onClose();
      }}
    >
      <div class="dlg-head">
        <h2>{props.title}</h2>
        <button type="button" class="icon-btn" title="Close" aria-label="Close" onClick={props.onClose}>
          <Icon name="close" />
        </button>
      </div>
      <div class="dlg-body">{props.children}</div>
    </dialog>
  );
}

/** Phone: a full-height panel over the chat. */
export function Sheet(props: { title: ComponentChildren; onClose: () => void; children: ComponentChildren; actions?: ComponentChildren; testid?: string }) {
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.key === 'Escape') props.onClose();
    };
    document.addEventListener('keydown', key);
    return () => document.removeEventListener('keydown', key);
  }, [props.onClose]);
  return (
    <section class="sheet" role="dialog" aria-modal="true" data-testid={props.testid}>
      <header class="sheet-head">
        <button type="button" class="icon-btn" title="Close" aria-label="Close" onClick={props.onClose}>
          <Icon name="chevronDown" size={20} />
        </button>
        <div class="sheet-title">{props.title}</div>
        <div class="sheet-actions">{props.actions}</div>
      </header>
      <div class="sheet-body">{props.children}</div>
    </section>
  );
}

/** A drag handle between panes. `axis` x resizes widths, y heights; `sign` flips the direction. */
export function Splitter(props: { axis: 'x' | 'y'; value: number; min: number; max: number; sign?: 1 | -1; onChange: (v: number) => void; label: string; testid?: string }) {
  const start = useRef<{ pos: number; value: number } | null>(null);
  const sign = props.sign ?? 1;
  return (
    <div
      class={`split split-${props.axis}`}
      role="separator"
      aria-orientation={props.axis === 'x' ? 'vertical' : 'horizontal'}
      aria-label={props.label}
      aria-valuenow={props.value}
      aria-valuemin={props.min}
      aria-valuemax={props.max}
      tabIndex={0}
      data-testid={props.testid}
      onPointerDown={(e) => {
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        start.current = { pos: props.axis === 'x' ? e.clientX : e.clientY, value: props.value };
        document.body.classList.add(props.axis === 'x' ? 'resizing-x' : 'resizing-y');
      }}
      onPointerMove={(e) => {
        if (!start.current) return;
        const d = (props.axis === 'x' ? e.clientX : e.clientY) - start.current.pos;
        props.onChange(Math.round(Math.min(props.max, Math.max(props.min, start.current.value + sign * d))));
      }}
      onPointerUp={() => {
        start.current = null;
        document.body.classList.remove('resizing-x', 'resizing-y');
      }}
      onPointerCancel={() => {
        start.current = null;
        document.body.classList.remove('resizing-x', 'resizing-y');
      }}
      onKeyDown={(e) => {
        const step = e.shiftKey ? 40 : 10;
        const dec = props.axis === 'x' ? 'ArrowLeft' : 'ArrowUp';
        const inc = props.axis === 'x' ? 'ArrowRight' : 'ArrowDown';
        if (e.key === dec || e.key === inc) {
          e.preventDefault();
          const d = (e.key === inc ? step : -step) * sign;
          props.onChange(Math.min(props.max, Math.max(props.min, props.value + d)));
        }
      }}
    />
  );
}

/** Copy text to the clipboard; resolves false when the browser refuses. */
export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export function useMedia(query: string): boolean {
  const [m, setM] = useState(() => matchMedia(query).matches);
  useEffect(() => {
    const mq = matchMedia(query);
    const f = () => setM(mq.matches);
    mq.addEventListener('change', f);
    f();
    return () => mq.removeEventListener('change', f);
  }, [query]);
  return m;
}

/** Preact core has no memo(); this one skips re-rendering when the props are shallow-equal. */
export function memo<P extends object>(C: FunctionComponent<P>): FunctionComponent<P> {
  class Memo extends Component<P> {
    shouldComponentUpdate(next: P): boolean {
      const a = this.props as Record<string, unknown>;
      const b = next as Record<string, unknown>;
      for (const k in a) if (k !== 'children' && a[k] !== b[k]) return true;
      for (const k in b) if (k !== 'children' && !(k in a)) return true;
      return a.children !== b.children;
    }
    render(p: P) {
      return h(C, p);
    }
  }
  return Memo as unknown as FunctionComponent<P>;
}

/** A command line, with Copy (it says Copied once the browser took it). */
export function Cmd({ text, testid }: { text: string; testid: string }) {
  const [copied, setCopied] = useState<boolean | null>(null);
  return (
    <span class="np-cmd">
      <code data-testid={testid}>{text}</code>
      <button type="button" class="linkish small" onClick={() => void copyText(text).then(setCopied)} data-testid={`${testid}-copy`}>
        {copied === null ? 'Copy' : copied ? 'Copied' : 'Copy it by hand'}
      </button>
    </span>
  );
}
