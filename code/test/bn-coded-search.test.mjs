// bn-coded's sessions.search (JON-517): the Code page's search over what a session's conversation says. A plain,
// case-insensitive substring of the person's prompts and Claude's answers (never a pattern; never a tool call, a tool's
// result or Claude's thinking), the most recent transcripts first, and bounded three ways: sessions looked at, bytes read
// of each (its first and last half), time. A bound that cuts it short only shortens the list.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { tmp, talk, open, result, TERMINAL_DIR } from './helpers.mjs';

const ROOT = tmp('bnsearch');
const WS = path.join(ROOT, 'ws'), HOME = path.join(ROOT, 'home'), SOCKDIR = path.join(ROOT, 'sock'), CONF = path.join(HOME, '.claude');
for (const d of [WS, HOME, CONF]) fs.mkdirSync(d, { recursive: true });
Object.assign(process.env, { BN_CODE_WORKSPACE: WS, BN_CODE_SOCK_DIR: SOCKDIR, BN_CODE_CHILDREN: path.join(ROOT, 'children'), HOME, CLAUDE_CONFIG_DIR: CONF,
  BN_CODE_ROOTS: JSON.stringify([WS]) });
const coded = await import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));
let server;
const SOCK = path.join(SOCKDIR, 'coded.sock');
before(async () => { server = coded.start(); await new Promise((r) => (server.listening ? r() : server.once('listening', r))); });
after(() => { server.close(); fs.rmSync(ROOT, { recursive: true, force: true }); });
const call = async (req) => result(await talk(SOCK, [open(req)]));

const STORE = path.join(CONF, 'projects');
const enc = (p) => p.replace(/[^A-Za-z0-9]/g, '-');
const DIR = path.join(STORE, enc(WS));
fs.mkdirSync(DIR, { recursive: true });
let age = 0;
// write(entries, {ageS}) -> the id of a new transcript in the workspace's store folder (ageS: how long ago it was last written)
function write(entries, { ageS = ++age } = {}) {
  const id = crypto.randomUUID();
  const file = path.join(DIR, `${id}.jsonl`);
  fs.writeFileSync(file, `${entries.map((e) => JSON.stringify({ cwd: WS, timestamp: '2026-11-27T10:00:00Z', uuid: crypto.randomUUID(), ...e })).join('\n')}\n`);
  const t = new Date(Date.now() - ageS * 1000);
  fs.utimesSync(file, t, t);
  return id;
}
const said = (text) => ({ type: 'user', message: { role: 'user', content: text } });
const answered = (text) => ({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }] } });
const search = (q, opts) => coded.sessionsSearch(q, 'bedrock', opts);

test('what is searched: the person\'s prompts and Claude\'s answers; case does not matter; the rest of a transcript is not looked at', () => {
  const prompt = write([said('Please check the Zebra crossing logic')]);
  const answer = write([said('hello'), answered('The giraffe handler is in lib/giraffe.js')]);
  const blocks = write([said([{ type: 'text', text: 'first block' }, { type: 'text', text: 'a quokka in the second block' }]), answered('ok')]);
  const tool = write([said('hi'), { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Bash', input: { command: 'echo wombat-in-a-command' } }] } },
    { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't', content: 'wombat-in-a-result' }] } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'thinking', thinking: 'wombat-in-thinking' }] } }]);
  const side = write([said('hi'), { ...answered('wombat-in-a-subagent'), isSidechain: true }, { ...said('wombat-in-a-meta-message'), isMeta: true }]);
  const titles = write([said('hi'), { type: 'custom-title', customTitle: 'wombat-in-a-title', sessionId: 'x' }]);
  assert.ok(search('zebra').ids.includes(prompt), 'in a prompt');
  assert.ok(search('GIRAFFE').ids.includes(answer), 'in an answer, whatever the case');
  assert.ok(search('Quokka In The').ids.includes(blocks), 'in a prompt of several text blocks');
  const w = search('wombat').ids;
  for (const [what, id] of [['a tool call', tool], ['a tool result / thinking', tool], ['a subagent or meta message', side], ['a title entry', titles]]) assert.ok(!w.includes(id), what);
  assert.deepEqual(search('no such words anywhere').ids, []);
});

test('plain text, never a pattern: regex characters mean themselves; the needle is trimmed and cut at 200 characters; empty is refused', () => {
  const plain = write([said('the version a.b(c)[d]* is what I mean')]);
  const other = write([said('aXb and a_b and abc')]);
  assert.deepEqual(search('a.b(c)[d]*').ids, [plain]);
  assert.ok(!search('a.b').ids.includes(other), '. is a dot');
  assert.ok(!search('.*').ids.includes(other), '.* matches nothing that does not hold it');
  assert.deepEqual(search('(').ids.length, 1, 'an unbalanced ( is just a character');
  assert.ok(search('  A.B(C)  ').ids.includes(plain), 'trimmed, any case');
  const long = 'q'.repeat(300);
  const held = write([said(`start ${'q'.repeat(200)} end`)]);
  assert.ok(search(long).ids.includes(held), 'only its first 200 characters are looked for');
  for (const bad of ['', '   ', 7, null, undefined, {}]) assert.throws(() => search(bad), /words to look for/, JSON.stringify(bad));
});

test('bounded: the most recent sessions first, at most N of them; the rest of the older ones is not looked at', () => {
  const needle = `bound-${crypto.randomBytes(4).toString('hex')}`;
  const old = write([said(`old ${needle}`)], { ageS: 100_000 });
  const mid = write([said('nothing'), answered(`mid ${needle}`)], { ageS: 50_000 });
  const fresh = write([said(`fresh ${needle}`)], { ageS: 1 });
  const all = search(needle);
  assert.deepEqual([...all.ids].sort(), [old, mid, fresh].sort());
  const two = search(needle, { sessions: 1 });
  assert.deepEqual(two.ids, [fresh], 'the newest one only');
  assert.equal(two.cut, true, 'said: cut short');
  assert.equal(two.scanned, 1);
  assert.equal(search(needle, { sessions: 3 }).ids.includes(mid), false, 'older ones are beyond the first three');
  assert.equal(search(needle, { sessions: 1000 }).cut, false);
});

test('bounded: a transcript is read only to its byte bound — its first and last half, the middle of a long one is not', () => {
  const mid = `mid-${crypto.randomBytes(4).toString('hex')}`, first = `first-${crypto.randomBytes(4).toString('hex')}`, last = `last-${crypto.randomBytes(4).toString('hex')}`;
  const filler = answered('x'.repeat(900));
  const id = write([said(first), ...Array.from({ length: 30 }, () => filler), answered(`the ${mid} is here`), ...Array.from({ length: 30 }, () => filler), answered(last)]);
  const size = fs.statSync(path.join(DIR, `${id}.jsonl`)).size;
  assert.ok(size > 40_000, String(size));
  const bytes = 8 << 10;
  assert.deepEqual(search(first, { bytes }).ids, [id], 'the start');
  assert.deepEqual(search(last, { bytes }).ids, [id], 'the end');
  const m = search(mid, { bytes });
  assert.deepEqual(m.ids, [], 'the middle is beyond the bound');
  assert.equal(m.cut, true);
  assert.deepEqual(search(mid, { bytes: 1 << 20 }).ids, [id], 'within a larger bound it is found');
});

test('bounded: a time limit ends the look; what was found stays', () => {
  const needle = `time-${crypto.randomBytes(4).toString('hex')}`;
  const a = write([said(needle)], { ageS: 1 }), b = write([said(needle)], { ageS: 2 });
  let t = 0;
  const r = search(needle, { ms: 100, now: () => { t += 60; return t; } });   // (each look at the clock takes "60 ms")
  assert.equal(r.cut, true);
  assert.equal(r.scanned, 1, 'stopped after the first');
  assert.deepEqual(r.ids, [a], 'what it found before stays');
  let c = 0;
  const none = search(needle, { ms: 5, now: () => (c += 10) });   // (already late at the first transcript)
  assert.deepEqual([none.ids, none.scanned, none.cut], [[], 0, true], 'no time left: nothing looked at');
  void b;
});

test('never through a link: a transcript that is a link is not read; a store folder that is a link is not either', () => {
  const secret = `secret-${crypto.randomBytes(4).toString('hex')}`;
  const outside = path.join(ROOT, 'outside.jsonl');
  fs.writeFileSync(outside, `${JSON.stringify({ type: 'user', cwd: WS, message: { role: 'user', content: secret } })}\n`);
  const link = `${crypto.randomUUID()}.jsonl`;
  fs.symlinkSync(outside, path.join(DIR, link));
  fs.mkdirSync(path.join(ROOT, 'elsewhere'));
  fs.writeFileSync(path.join(ROOT, 'elsewhere', `${crypto.randomUUID()}.jsonl`), `${JSON.stringify({ type: 'user', cwd: WS, message: { role: 'user', content: secret } })}\n`);
  fs.symlinkSync(path.join(ROOT, 'elsewhere'), path.join(STORE, `${enc(WS)}-linked`));
  assert.deepEqual(search(secret).ids, []);
});

test('over the socket: sessions.search {q, store}; a bad store, a bad question and an unknown store are refused plainly', async () => {
  const id = write([said('over the socket: kangaroo')]);
  const r = await call({ op: 'sessions.search', q: 'KANGAROO' });
  assert.deepEqual(r.ids, [id]);
  assert.equal(typeof r.scanned, 'number');
  assert.equal(typeof r.cut, 'boolean');
  assert.match((await call({ op: 'sessions.search', q: '' })).error, /words to look for/);
  assert.match((await call({ op: 'sessions.search', q: 'x', store: 'nope' })).error, /bad store/);
  assert.match((await call({ op: 'sessions.search', q: 'x', store: 'plan:../x' })).error, /bad store/);
  assert.deepEqual((await call({ op: 'sessions.search', q: 'kangaroo', store: 'plan' })).ids, [], 'another store: its own transcripts');
  // and the list is as it was (the search shares its directory walk, not its answers)
  assert.ok((await call({ op: 'sessions.list' })).sessions.some((s) => s.id === id));
});
