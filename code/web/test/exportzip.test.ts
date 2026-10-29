// Export to Files (src/exportzip.ts, api.ts exportPlan/exportZip): the plan as the backend states it, a zip that counts as whole,
// and what the page takes from the portal's answer — only from the portal that frames it, for its own request, in a shape it knows.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EXPORT_NAME, exportMessage, fmtBytes, normExportPlan, originOf, portalExport, takeExportReply, zipWhole } from '../src/exportzip';
import { ApiError, exportPlan, exportZip } from '../src/api';

const PLAN = { files: 3, bytes: 1234, cap: 200 << 20, over: false, via: 'git', skippedLinks: 1, skippedOther: 0, name: 'My-app-20261027-101500.zip' };

test('the plan: counts, a name an export can have; anything else does not fit', () => {
  assert.deepEqual(normExportPlan(PLAN), PLAN);
  assert.equal(normExportPlan({ ...PLAN, via: 'other' })?.via, 'walk');
  for (const bad of [null, 'x', { ...PLAN, files: -1 }, { ...PLAN, files: 1.5 }, { ...PLAN, bytes: '5' }, { ...PLAN, over: 'no' }, { ...PLAN, name: '../x.zip' }, { ...PLAN, name: 'a b.zip' },
    { ...PLAN, name: '.hidden.zip' }, { ...PLAN, name: 'x.txt' }, { ...PLAN, cap: undefined }]) {
    assert.equal(normExportPlan(bad), null, JSON.stringify(bad));
  }
  for (const ok of ['a.zip', 'My-app-20261027-101500.zip', 'a.b_c-d.zip']) assert.ok(EXPORT_NAME.test(ok), ok);
  for (const bad of ['', '.zip', '/a.zip', 'a/b.zip', 'a\\b.zip', 'a.zip.exe', `${'x'.repeat(120)}.zip`]) assert.ok(!EXPORT_NAME.test(bad), bad);
  assert.equal(fmtBytes(512), '512 B');
  assert.equal(fmtBytes(1536), '1.5 KiB');
  assert.equal(fmtBytes(5 << 20), '5.0 MiB');
});

const LOCAL = new Uint8Array([0x50, 0x4b, 3, 4]);
const END = new Uint8Array(22); END.set([0x50, 0x4b, 5, 6]);

test('a zip is whole when it starts with a local header (or is empty) and ends with its end record', () => {
  assert.ok(zipWhole(LOCAL, END, 5000));
  assert.ok(zipWhole(END.slice(0, 4), END, 22), 'an empty zip: just the end record');
  assert.ok(!zipWhole(LOCAL, new Uint8Array(22), 5000), 'cut off: no end record');
  assert.ok(!zipWhole(new Uint8Array([1, 2, 3, 4]), END, 5000), 'not a zip');
  assert.ok(!zipWhole(LOCAL, END, 10), 'too short');
  assert.ok(!zipWhole(LOCAL, END.slice(0, 10), 5000));
});

test('the portal\'s answer: only the portal that frames this page, only for this request, only a shape the page knows', () => {
  const portal = 'http://bedrock-now.localhost', parent = {}, id = 'abc123';
  const ok = { type: 'bn-portal-export', id, ok: true, key: 'a.zip', bucket: 'code-exports', url: 'http://files.bedrock-now.localhost/rustfs/console/browser/code-exports' };
  assert.deepEqual(takeExportReply(ok, portal, parent, portal, parent, id), { ok: true, key: 'a.zip', bucket: 'code-exports', url: ok.url });
  assert.equal(takeExportReply({ ...ok, url: 'javascript:alert(1)' }, portal, parent, portal, parent, id)?.ok && (takeExportReply({ ...ok, url: 'javascript:alert(1)' }, portal, parent, portal, parent, id) as { url: string | null }).url, null);
  assert.deepEqual(takeExportReply({ type: 'bn-portal-export', id, ok: false, error: 'RustFS said no\nx' }, portal, parent, portal, parent, id), { ok: false, error: 'RustFS said no x' });
  assert.equal(takeExportReply(ok, 'http://evil.example', parent, portal, parent, id), null, 'another origin');
  assert.equal(takeExportReply(ok, portal, {}, portal, parent, id), null, 'not the parent window');
  assert.equal(takeExportReply(ok, portal, parent, null, parent, id), null, 'no portal known');
  assert.equal(takeExportReply(ok, portal, parent, portal, parent, 'other'), null, 'another request');
  assert.equal(takeExportReply({ ...ok, type: 'bn-portal-open' }, portal, parent, portal, parent, id), null);
  assert.equal(takeExportReply({ ...ok, key: '../x.zip' }, portal, parent, portal, parent, id), null);
  assert.equal(takeExportReply({ ...ok, bucket: 'A b' }, portal, parent, portal, parent, id), null);
  assert.equal(takeExportReply(null, portal, parent, portal, parent, id), null);
});

class Win extends EventTarget {
  parent: { posted: unknown[]; postMessage: (m: unknown, to: string) => void };
  constructor(framed = true) {
    super();
    const parent = { posted: [] as unknown[], postMessage(m: unknown, _to: string) { parent.posted.push([m, _to]); } };
    this.parent = framed ? parent : (this as unknown as typeof parent);
  }
}

test('handing the zip over: posted to the portal\'s origin only; its answer settles it; no portal or no answer says so', async () => {
  const w = new Win();
  const blob = new Blob(['PK']);
  const p = portalExport(blob, 'a.zip', w as unknown as Window, 'http://bedrock-now.localhost', 5000);
  const [msg, to] = (w.parent.posted[0] as [{ type: string; id: string; name: string; blob: Blob }, string]);
  assert.equal(to, 'http://bedrock-now.localhost');
  assert.deepEqual({ type: msg.type, name: msg.name, blob: msg.blob }, { type: 'bn-code-export', name: 'a.zip', blob });
  assert.match(msg.id, /^[0-9a-f]{16}$/);
  // a stranger's answer is ignored, the portal's settles it
  const ev = (origin: string, data: unknown, source: unknown) => Object.assign(new Event('message'), { origin, data, source });
  w.dispatchEvent(ev('http://evil.example', { type: 'bn-portal-export', id: msg.id, ok: true, key: 'a.zip', bucket: 'code-exports' }, w.parent));
  w.dispatchEvent(ev('http://bedrock-now.localhost', { type: 'bn-portal-export', id: msg.id, ok: true, key: 'a.zip', bucket: 'code-exports', url: 'http://files.bedrock-now.localhost/x' }, w.parent));
  assert.deepEqual(await p, { key: 'a.zip', bucket: 'code-exports', url: 'http://files.bedrock-now.localhost/x' });
  // a refusal rejects with the portal's words
  const w2 = new Win();
  const p2 = portalExport(blob, 'a.zip', w2 as unknown as Window, 'http://bedrock-now.localhost', 5000);
  const id2 = (w2.parent.posted[0] as [{ id: string }, string])[0].id;
  w2.dispatchEvent(ev('http://bedrock-now.localhost', { type: 'bn-portal-export', id: id2, ok: false, error: 'Files (RustFS) refused the zip (HTTP 403, AccessDenied).' }, w2.parent));
  await assert.rejects(p2, /AccessDenied/);
  // not framed / no portal known
  await assert.rejects(portalExport(blob, 'a.zip', new Win(false) as unknown as Window, 'http://bedrock-now.localhost'), /not open in the portal/);
  await assert.rejects(portalExport(blob, 'a.zip', new Win() as unknown as Window, null), /not open in the portal/);
  // no answer
  await assert.rejects(portalExport(blob, 'a.zip', new Win() as unknown as Window, 'http://bedrock-now.localhost', 10), /did not answer in time/);
  assert.equal(exportMessage('x', 'a.zip', blob).type, 'bn-code-export');
});

function withFetch(handler: (url: string) => Response | Promise<Response>, run: () => Promise<void>) {
  const real = globalThis.fetch;
  globalThis.fetch = (async (u: string) => handler(String(u))) as typeof fetch;
  return run().finally(() => { globalThis.fetch = real; });
}
const zipBytes = (n: number) => { const b = new Uint8Array(n + 22); b.set([0x50, 0x4b, 3, 4]); b.set([0x50, 0x4b, 5, 6], n); return b; };

test('exportPlan and exportZip: the backend\'s plan; the zip streamed in and checked whole; its refusals said as they are', async () => {
  const seen: string[] = [];
  await withFetch((u) => {
    seen.push(u);
    if (u.includes('dry=1')) return Response.json(PLAN);
    return new Response(new Blob([zipBytes(1000)]).stream(), { headers: { 'content-type': 'application/zip' } });
  }, async () => {
    assert.deepEqual(await exportPlan('p_0000000a', { include: 'default', git: false }), PLAN);
    assert.match(seen[0], /^\/api\/projects\/p_0000000a\/export\?dry=1&include=default&git=0$/);
    let last = 0;
    const blob = await exportZip('p_0000000a', { include: 'all', git: true }, PLAN.name, PLAN.cap, (n) => { last = n; });
    assert.equal(blob.size, 1022);
    assert.equal(last, 1022);
    assert.match(seen[1], /include=all&git=1&name=My-app-20261027-101500\.zip$/);
    await assert.rejects(exportPlan('../etc', { include: 'default', git: false }), ApiError);
  });
  // over the limit: the backend's own words, status kept
  await withFetch(() => Response.json({ error: 'too large: 9 files, 300.0 MiB before compression; the limit is 200.0 MiB' }, { status: 413 }), async () => {
    await assert.rejects(exportZip('p_0000000a', { include: 'default', git: false }, PLAN.name, PLAN.cap), (e: unknown) => e instanceof ApiError && e.status === 413 && /300\.0 MiB/.test(e.message));
  });
  // half a zip (the connection broke): never handed on
  await withFetch(() => new Response(new Blob([zipBytes(1000).slice(0, 600)]).stream()), async () => {
    await assert.rejects(exportZip('p_0000000a', { include: 'default', git: false }, PLAN.name, PLAN.cap), /did not arrive whole/);
  });
  // far more than the limit allows: stopped
  await withFetch(() => new Response(new Blob([new Uint8Array(5 << 20)]).stream()), async () => {
    await assert.rejects(exportZip('p_0000000a', { include: 'default', git: false }, PLAN.name, 1 << 20), (e: unknown) => e instanceof ApiError && e.status === 413);
  });
  // a plan that does not fit
  await withFetch(() => Response.json({ files: 'many' }), async () => {
    await assert.rejects(exportPlan('p_0000000a', { include: 'default', git: false }), /does not fit/);
  });
});

test('the portal\'s origin as the page keeps it (/api/state\'s portal_origin read as a URL: "http://host/") still matches its answers', async () => {
  // (the page's store holds URL.href, with a trailing slash; a message's origin never has one: compared as it was, the
  // portal's answer was never taken and Export to Files waited out its ten minutes)
  const href = new URL('http://bedrock-now.localhost:8080').href, parent = {}, id = 'abc123';
  assert.equal(href, 'http://bedrock-now.localhost:8080/');
  assert.equal(originOf(href), 'http://bedrock-now.localhost:8080');
  assert.equal(originOf('nope'), null);
  assert.equal(originOf(null), null);
  const ok = { type: 'bn-portal-export', id, ok: true, key: 'a.zip', bucket: 'code-exports' };
  assert.deepEqual(takeExportReply(ok, 'http://bedrock-now.localhost:8080', parent, href, parent, id), { ok: true, key: 'a.zip', bucket: 'code-exports', url: null });
  assert.equal(takeExportReply(ok, 'http://bedrock-now.localhost', parent, href, parent, id), null, 'another port');
  // handed over and answered with that origin
  const w = new Win();
  const p = portalExport(new Blob(['PK']), 'a.zip', w as unknown as Window, href, 5000);
  const [msg, to] = (w.parent.posted[0] as [{ id: string }, string]);
  assert.equal(to, 'http://bedrock-now.localhost:8080');
  w.dispatchEvent(Object.assign(new Event('message'), { origin: 'http://bedrock-now.localhost:8080', data: { ...ok, id: msg.id }, source: w.parent }));
  assert.deepEqual(await p, { key: 'a.zip', bucket: 'code-exports', url: null });
});
