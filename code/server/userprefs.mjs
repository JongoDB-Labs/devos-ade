// Your choices for new Code page sessions, kept for your sign-in — this stack has one, the portal's password — in the
// code container's state, not in one browser: the model you picked last, so a new browser, a phone or the installed app
// starts a session where you left off instead of on the stack's default (UX-01). With it, what Settings' default for new
// sessions was when you picked (settingsDefault: CODE_DEFAULT_MODEL as the portal's /.bn/models says it, null for none):
// a default set or changed in Settings since then wins over your older pick (code/web/src/models.ts startModel).
// Page state, never a reason to fail: a file that does not fit reads as no choice; only model ids are kept.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { STATE_DIR } from './githosts.mjs';
import { isFullModel } from './validate.mjs';

export class PrefsError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

const NONE = Object.freeze({ model: null, settingsDefault: null, at: null });

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
  /** read() -> {model, settingsDefault, at}: what was kept, every field checked (none: nulls) */
  read() {
    let v;
    try { v = JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { return { ...NONE }; }
    if (!v || v.version !== 1) return { ...NONE };
    try {
      const p = prefsOf(v);
      return { ...p, at: Number.isInteger(v.at) && v.at > 0 ? v.at : null };
    } catch {
      return { ...NONE };
    }
  }
  /** set(body) -> what is kept now ({model, settingsDefault, at}); 400 for anything but model ids */
  set(body) {
    const p = prefsOf(body);
    const v = { version: 1, ...p, at: this.now() };
    fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    try { fs.chmodSync(this.dir, 0o700); } catch { /* not ours to change */ }
    const tmp = path.join(this.dir, `.prefs-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
    fs.writeFileSync(tmp, JSON.stringify(v), { mode: 0o600, flag: 'wx' });
    fs.renameSync(tmp, this.file);
    return { model: v.model, settingsDefault: v.settingsDefault, at: v.at };
  }
}
