// Export to Files (the Projects menu, ⌘K): what the page checks of a zip and of the portal's answer. The zip is built in the
// sandbox, passed through the backend (GET /api/projects/ID/export) and held here once (size-capped there); the portal that
// frames this page writes it into Files (its code.js ↔ this page, below) — the Code page cannot reach Files itself, and the
// code container has no way to it.
//
//   page -> portal  {type: 'bn-code-export', id, name, blob}   id: 1-32 letters and digits; name: <project>-<time>.zip; blob: the zip
//   portal -> page  {type: 'bn-portal-export', id, ok, key?, bucket?, url?, error?}   only from the portal that frames this page
//                                                              (its origin, from /api/state's portal_origin, and window.parent)
// A zip is "whole" when it starts with a local header (or is empty) and ends with its end-of-central-directory record: a
// download that broke half way is never put in Files.
import { label } from './text';

export const EXPORT_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,115}\.zip$/;
export const EXPORT_TIMEOUT_MS = 10 * 60 * 1000;

export interface ExportPlan {
  files: number;
  bytes: number;
  cap: number;
  over: boolean;
  via: 'git' | 'walk';
  skippedLinks: number;
  skippedOther: number;
  name: string;
}
export interface ExportOptions {
  include: 'default' | 'all';
  git: boolean;
}

const count = (v: unknown, max = 1e13): number | null => (typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= max ? v : null);

/** The backend's plan, or null when it does not fit. */
export function normExportPlan(o: unknown): ExportPlan | null {
  if (!o || typeof o !== 'object') return null;
  const r = o as Record<string, unknown>;
  const files = count(r.files, 1e7), bytes = count(r.bytes), cap = count(r.cap), links = count(r.skippedLinks, 1e7), other = count(r.skippedOther, 1e7);
  if (files === null || bytes === null || cap === null || links === null || other === null || typeof r.over !== 'boolean') return null;
  if (typeof r.name !== 'string' || !EXPORT_NAME.test(r.name)) return null;
  return { files, bytes, cap, over: r.over, via: r.via === 'git' ? 'git' : 'walk', skippedLinks: links, skippedOther: other, name: r.name };
}

export function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1 << 20) return `${(n / 1024).toFixed(1)} KiB`;
  if (n < 1 << 30) return `${(n / (1 << 20)).toFixed(1)} MiB`;
  return `${(n / (1 << 30)).toFixed(2)} GiB`;
}

/** head: the zip's first 4 bytes, tail: its last 22 — a zip that begins and ends as the sandbox's writer makes one. */
export function zipWhole(head: Uint8Array, tail: Uint8Array, size: number): boolean {
  const at = (b: Uint8Array, i: number) => b[i] ?? -1;
  if (size < 22 || tail.length !== 22) return false;
  const end = at(tail, 0) === 0x50 && at(tail, 1) === 0x4b && at(tail, 2) === 5 && at(tail, 3) === 6;
  if (!end) return false;
  const empty = size === 22;
  const local = at(head, 0) === 0x50 && at(head, 1) === 0x4b && at(head, 2) === 3 && at(head, 3) === 4;
  return empty || local;
}

/** The message that hands the zip to the portal. */
export function exportMessage(id: string, name: string, blob: Blob): { type: 'bn-code-export'; id: string; name: string; blob: Blob } {
  return { type: 'bn-code-export', id, name, blob };
}

export type ExportReply = { ok: true; key: string; bucket: string; url: string | null } | { ok: false; error: string };

/** PORTAL (/api/state's portal_origin, as the page keeps it: a URL, "http://host/") as an origin ("http://host"), the form
 *  a message's origin has; null when it is not one. */
export function originOf(portal: string | null): string | null {
  if (!portal) return null;
  try {
    const o = new URL(portal).origin;
    return o === 'null' ? null : o;
  } catch {
    return null;
  }
}

/** A message from the portal, checked: who sent it (ORIGIN the portal's, SOURCE the parent window), whose it is (ID) and its
 *  shape — or null. */
export function takeExportReply(data: unknown, origin: string, source: unknown, portal: string | null, parent: unknown, id: string): ExportReply | null {
  const want = originOf(portal);
  if (!want || origin !== want || !parent || source !== parent || !data || typeof data !== 'object') return null;
  const d = data as Record<string, unknown>;
  if (d.type !== 'bn-portal-export' || d.id !== id) return null;
  if (d.ok === true) {
    if (typeof d.key !== 'string' || !EXPORT_NAME.test(d.key) || typeof d.bucket !== 'string' || !/^[a-z0-9][a-z0-9.-]{2,62}$/.test(d.bucket)) return null;
    let url: string | null = null;
    if (typeof d.url === 'string') {
      try {
        const u = new URL(d.url);
        if (u.protocol === 'http:' || u.protocol === 'https:') url = u.href;
      } catch { /* none */ }
    }
    return { ok: true, key: d.key, bucket: d.bucket, url };
  }
  return { ok: false, error: label(typeof d.error === 'string' ? d.error : 'Files did not take the zip.', 300) };
}

/** Hand BLOB to the portal that frames WIN and wait for its answer (the portal checks and writes it). Rejects with a message
 *  to show when there is no portal, or no answer in time. */
export function portalExport(blob: Blob, name: string, win: Window, portal: string | null, timeoutMs = EXPORT_TIMEOUT_MS): Promise<{ key: string; bucket: string; url: string | null }> {
  return new Promise((resolve, reject) => {
    if (!portal || win.parent === win) return reject(new Error('This page is not open in the portal: use Download instead.'));
    const id = Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, '0')).join('');
    const done = (f: () => void) => {
      clearTimeout(timer);
      win.removeEventListener('message', on);
      f();
    };
    const on = (e: MessageEvent) => {
      const r = takeExportReply(e.data, e.origin, e.source, portal, win.parent, id);
      if (!r) return;
      done(() => (r.ok ? resolve({ key: r.key, bucket: r.bucket, url: r.url }) : reject(new Error(r.error))));
    };
    const timer = setTimeout(() => done(() => reject(new Error('The portal did not answer in time: the zip may not be in Files.'))), timeoutMs);
    win.addEventListener('message', on);
    try {
      win.parent.postMessage(exportMessage(id, name, blob), originOf(portal) ?? portal);
    } catch {
      done(() => reject(new Error('The portal could not be reached from this page.')));
    }
  });
}
