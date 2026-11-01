// Your choices for new Code page sessions, kept for your sign-in — this stack has one, the portal's password — in the
// code container's state, not in one browser: the model you picked last, so a new browser, a phone or the installed app
// starts a session where you left off instead of on the stack's default (UX-01). With it, what Settings' default for new
// sessions was when you picked (settingsDefault: CODE_DEFAULT_MODEL as the portal's /.bn/models says it, null for none):
// a default set or changed in Settings since then wins over your older pick (code/web/src/models.ts startModel).
// With them, the layout of the page's widgets per device (desktop, tablet): which panels are shown, in which dock, as
// tabs or stacked, how big (code/web/src/layout.ts holds the same ids and bounds; the page checks what it reads too).
// Page state, never a reason to fail: a file that does not fit reads as no choice; only model ids and layouts that fit
// the widgets and docks below are kept.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { STATE_DIR } from './githosts.mjs';
import { isFullModel } from './validate.mjs';

export class PrefsError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

const NONE = Object.freeze({ model: null, settingsDefault: null, at: null });

// ---- the layout of the page's widgets (layout.ts)
const DOCKS = ['left', 'center', 'right', 'bottom'];
const PLACED = ['explorer', 'search', 'git', 'sessions', 'editor', 'terminal', 'chat'];
const WIDGETS = [...PLACED, 'status'];
const SIZE = { left: [160, 900], center: [0, 0], right: [160, 900], bottom: [120, 720] };
const STACK = [120, 2000];
const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const only = (o, keys, what) => {
  for (const k of Object.keys(o)) if (!keys.includes(k)) throw new PrefsError(400, `${what}: unknown field ${JSON.stringify(k.slice(0, 40))}`);
};
const clamp = (v, [lo, hi], what) => {
  if (typeof v !== 'number' || !Number.isFinite(v)) throw new PrefsError(400, `${what}: a number`);
  return Math.round(Math.min(hi, Math.max(lo, v)));
};

// deviceLayoutOf(v) -> the layout of one device, checked: known docks, widgets and modes only, every widget in exactly
// one dock, the chat never hidden, sizes clamped; else 400
export function deviceLayoutOf(v, what = 'layout') {
  if (!isObj(v)) throw new PrefsError(400, `${what}: an object`);
  only(v, ['docks', 'place', 'hidden', 'sizes', 'pane'], what);
  if (!isObj(v.docks) || !isObj(v.place)) throw new PrefsError(400, `${what}: docks and place`);
  only(v.docks, DOCKS, `${what}.docks`);
  only(v.place, DOCKS, `${what}.place`);
  const docks = {};
  const place = {};
  const seen = new Set();
  for (const d of DOCKS) {
    const s = v.docks[d];
    if (!isObj(s)) throw new PrefsError(400, `${what}.docks.${d}: an object`);
    only(s, ['mode', 'size', 'open', 'active'], `${what}.docks.${d}`);
    if (s.mode !== 'tabs' && s.mode !== 'stack') throw new PrefsError(400, `${what}.docks.${d}.mode: tabs or stack`);
    if (typeof s.open !== 'boolean') throw new PrefsError(400, `${what}.docks.${d}.open: true or false`);
    if (s.active !== null && !WIDGETS.includes(s.active)) throw new PrefsError(400, `${what}.docks.${d}.active: a widget or null`);
    docks[d] = { mode: s.mode, size: clamp(s.size, SIZE[d], `${what}.docks.${d}.size`), open: s.open, active: s.active };
    const list = v.place[d];
    if (!Array.isArray(list) || list.length > PLACED.length) throw new PrefsError(400, `${what}.place.${d}: a list of widgets`);
    for (const id of list) {
      if (!PLACED.includes(id)) throw new PrefsError(400, `${what}.place.${d}: ${JSON.stringify(String(id).slice(0, 40))} is not a widget that sits in a dock`);
      if (seen.has(id)) throw new PrefsError(400, `${what}.place: ${id} twice`);
      seen.add(id);
    }
    place[d] = [...list];
  }
  if (seen.size !== PLACED.length) throw new PrefsError(400, `${what}.place: every widget once`);
  if (!Array.isArray(v.hidden) || v.hidden.length > WIDGETS.length) throw new PrefsError(400, `${what}.hidden: a list of widgets`);
  for (const id of v.hidden) if (!WIDGETS.includes(id) || id === 'chat') throw new PrefsError(400, `${what}.hidden: ${JSON.stringify(String(id).slice(0, 40))} cannot be hidden`);
  if (new Set(v.hidden).size !== v.hidden.length) throw new PrefsError(400, `${what}.hidden: a widget twice`);
  const sizes = {};
  if (!isObj(v.sizes)) throw new PrefsError(400, `${what}.sizes: an object`);
  only(v.sizes, WIDGETS, `${what}.sizes`);
  for (const id of WIDGETS) if (id in v.sizes) sizes[id] = clamp(v.sizes[id], STACK, `${what}.sizes.${id}`);
  if (v.pane !== 'left' && v.pane !== 'center') throw new PrefsError(400, `${what}.pane: left or center`);
  return { docks, place, hidden: [...v.hidden], sizes, pane: v.pane };
}

// layoutOf(v) -> {desktop?, tablet?}: each checked, null forgets that device's (the page's default again); else 400
export function layoutOf(v) {
  if (v === null) return { desktop: null, tablet: null };
  if (!isObj(v)) throw new PrefsError(400, 'layout: an object with desktop and tablet');
  only(v, ['desktop', 'tablet'], 'layout');
  const out = {};
  for (const d of ['desktop', 'tablet']) if (d in v) out[d] = v[d] === null ? null : deviceLayoutOf(v[d], `layout.${d}`);
  return out;
}

// prefsOf(body) -> {model, settingsDefault}: a full model id (never one of Claude Code's aliases) or null each; else 400
export function prefsOf(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new PrefsError(400, 'a JSON object, please');
  const one = (v, what) => {
    if (v === undefined || v === null || v === '') return null;
    if (!isFullModel(v)) throw new PrefsError(400, `${what}: a model id (letters, digits, . _ : / @ [ ] -), not an alias`);
    return v;
  };
  return { model: one(body.model, 'model'), settingsDefault: one(body.settingsDefault, 'settingsDefault') };
}

export class UserPrefs {
  constructor({ dir = STATE_DIR, now = () => Date.now() } = {}) {
    this.dir = path.join(dir, 'prefs');
    this.file = path.join(this.dir, 'prefs.json');
    this.now = now;
  }
  /** read() -> {model, settingsDefault, at, layout?}: what was kept, every field checked (none: nulls; layout only where
   *  one device's or both are kept) */
  read() {
    let v;
    try { v = JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { return { ...NONE }; }
    if (!v || v.version !== 1) return { ...NONE };
    let p;
    let fits = true;
    try { p = prefsOf(v); } catch { p = { model: null, settingsDefault: null }; fits = false; }
    const layout = {};
    for (const d of ['desktop', 'tablet']) {
      try { if (isObj(v.layout) && v.layout[d]) layout[d] = deviceLayoutOf(v.layout[d], `layout.${d}`); } catch { /* one that does not fit is not kept */ }
    }
    if (!fits && !Object.keys(layout).length) return { ...NONE };
    return { ...p, at: Number.isInteger(v.at) && v.at > 0 ? v.at : null, ...(Object.keys(layout).length ? { layout } : {}) };
  }
  /** set(body) -> what is kept now ({model, settingsDefault, at, layout?}); 400 for anything but model ids and layouts that
   *  fit. A body with a model (or settingsDefault) sets both; one with a layout sets those devices' (null forgets them);
   *  what the body does not name stays as it was. */
  set(body) {
    if (!isObj(body)) throw new PrefsError(400, 'a JSON object, please');
    const cur = this.read();
    const named = 'model' in body || 'settingsDefault' in body;
    const p = named ? prefsOf(body) : { model: cur.model, settingsDefault: cur.settingsDefault };
    const layout = { ...(cur.layout ?? {}) };
    if ('layout' in body) {
      for (const [d, l] of Object.entries(layoutOf(body.layout))) {
        if (l === null) delete layout[d];
        else layout[d] = l;
      }
    }
    const v = { version: 1, ...p, ...(Object.keys(layout).length ? { layout } : {}), at: this.now() };
    fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    try { fs.chmodSync(this.dir, 0o700); } catch { /* not ours to change */ }
    const tmp = path.join(this.dir, `.prefs-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
    fs.writeFileSync(tmp, JSON.stringify(v), { mode: 0o600, flag: 'wx' });
    fs.renameSync(tmp, this.file);
    return { model: v.model, settingsDefault: v.settingsDefault, at: v.at, ...(v.layout ? { layout: v.layout } : {}) };
  }
}
