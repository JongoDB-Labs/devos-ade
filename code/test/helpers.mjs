// Test helpers: temporary folders and sockets, and a small client for raw frames.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { FrameParser, frame, T } from '../server/frames.mjs';

export const HERE = path.dirname(fileURLToPath(import.meta.url));
// terminal/ of this checkout, or the copy the image's test stage gets (code/Dockerfile: BN_TERMINAL_DIR)
export const TERMINAL_DIR = process.env.BN_TERMINAL_DIR || path.resolve(HERE, '../../terminal');

// What some of bn-coded's tests need of the sandbox (the image's test stages have all of it; a Mac has none): Linux's
// /proc, the tests running as root (their stand-in programs then are root's alone, as the image's are), and node and npm
// of root's alone in the image's own folders — which bn-coded runs, and which the git credential helper's
// `#!/usr/bin/env node` finds on the sandbox's PATH. (bn-coded's imageFile, near enough: the link, the file and their
// folders root's, writable by no one else.)
const rootOnly = (st) => st.uid === 0 && (st.mode & 0o022) === 0;
const rootProgram = (name) => ['/usr/local/bin', '/usr/bin', '/bin'].some((d) => {
  try {
    const p = path.join(d, name), real = fs.realpathSync(p);
    return fs.lstatSync(p).uid === 0 && rootOnly(fs.statSync(d)) && fs.statSync(real).isFile() && rootOnly(fs.statSync(real)) && rootOnly(fs.statSync(path.dirname(real)));
  } catch { return false; }
});
const SANDBOX_NEEDS = {
  proc: { has: () => fs.existsSync('/proc/self/stat'), what: "Linux's /proc" },
  root: { has: () => process.getuid?.() === 0, what: 'running as root, as the image\'s test stage does' },
  node: { has: () => rootProgram('node'), what: 'a node of root\'s in /usr/local/bin, /usr/bin or /bin' },
  npm: { has: () => rootProgram('npm'), what: 'an npm of root\'s in /usr/local/bin, /usr/bin or /bin' },
  tmux: { has: () => ['/usr/bin/tmux', '/usr/local/bin/tmux', '/opt/homebrew/bin/tmux'].some((p) => fs.existsSync(p)), what: 'a real tmux' },
  ssh: { has: () => ['sshd', 'ssh'].every((n) => ['/usr/bin', '/usr/local/bin', '/bin', '/usr/sbin', '/usr/local/sbin', '/opt/homebrew/bin'].some((d) => fs.existsSync(path.join(d, n)))),
    what: 'sshd and ssh' },
};
// sandboxSkip(t, ...needs) -> true when the test was skipped (return from it then): needs is any of proc, root, node,
// npm, tmux, ssh. Where one is missing the test skips, saying which (a host run on a Mac). In the image's test stages
// (BN_TEST_EXPECT_SANDBOX=1, code/Dockerfile) a missing one fails the test instead: no guard can hide a test there.
export function sandboxSkip(t, ...needs) {
  const missing = needs.filter((n) => !SANDBOX_NEEDS[n].has()).map((n) => SANDBOX_NEEDS[n].what);
  if (!missing.length) return false;
  if (process.env.BN_TEST_EXPECT_SANDBOX === '1') throw new Error(`expected the sandbox's tools: ${missing.join('; ')}`);
  t.skip(`needs the sandbox's tools: ${missing.join('; ')}`);
  return true;
}

// tmp(prefix) -> a fresh folder; short (UNIX socket paths are limited to ~100 bytes)
export function tmp(prefix = 'bnc') {
  return fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), `${prefix}-`));
}

// talk(sock, frames) -> every frame the other side sends until it closes: [[type, Buffer]]
export function talk(sock, frames, { timeoutMs = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    const c = net.connect(sock);
    const parser = new FrameParser(64 << 20);
    const got = [];
    const timer = setTimeout(() => { c.destroy(); reject(new Error(`no close within ${timeoutMs} ms; got ${got.map((g) => g[0]).join(',')}`)); }, timeoutMs);
    c.on('connect', () => { for (const f of frames) c.write(f); });
    c.on('data', (d) => { for (const f of parser.push(d)) got.push(f); });
    c.on('error', () => {});
    c.on('close', () => { clearTimeout(timer); resolve(got); });
  });
}
export const open = (req) => frame(T.OPEN, req);
export const result = (frames) => {
  const r = frames.find(([t]) => t === T.RESULT || t === T.ERROR);
  if (!r) return { none: true };
  const v = JSON.parse(r[1].toString('utf8'));
  return r[0] === T.ERROR ? { error: v.error } : v;
};
export const stdout = (frames) => Buffer.concat(frames.filter(([t]) => t === T.STDOUT).map(([, p]) => p));

// fakeSandbox(onConn) -> {sock, close}: a UNIX socket server standing in for bn-coded (hostile or not)
export async function fakeSandbox(onConn) {
  const dir = tmp('bnfake');
  const sock = path.join(dir, 's.sock');
  const server = net.createServer(onConn);
  await new Promise((r) => server.listen(sock, r));
  return { sock, close: () => new Promise((r) => server.close(() => { fs.rmSync(dir, { recursive: true, force: true }); r(); })) };
}
