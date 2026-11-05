// Commit a kept project's pending work at the end of an agent turn (JON-1139). The push is keep.mjs's own, after it.
// One commit on the branch checked out, made of the files that are safe to commit: nothing is committed at all (not a
// part of it) when the changes hold a credential file by name or something secret-shaped by content (secrets.mjs), and
// the reason is said. A clean tree is no commit. Files git ignores are never in the status, so never staged; they are
// staged by name, never `add -A`. Nothing is amended, rewritten or forced.
import { isSecretName, scan } from './secrets.mjs';

export const TRAILER = 'DevOS-ADE-Auto-Commit: end-of-turn';
export const PAUSED = 'Auto-sync paused this turn';
const EXAMPLE = /^\.env\.(example|sample|template)$/i;
const KEY_EXT = /\.(pem|key|p12|pfx|keystore)$/i;
const SSH_KEY = /^id_(rsa|ed25519|ecdsa|dsa)(?!.*\.pub$)/i;
const STAGE_AT_ONCE = 100;
const MAX_SCANNED = 200;

/** credentialPath(path) -> whether a file's name says it holds a credential: .env and .env.* (not .env.example, .sample or
 *  .template), *.pem, *.key, *.p12, *.pfx, *.keystore, ssh private keys, .netrc, anything in .ssh/, *credentials*, and a
 *  .json file whose name secrets.mjs calls a secret's (service-account keys). Not .npmrc or package.json: their content is
 *  scanned, so a clean one is committed. */
export function credentialPath(p) {
  const parts = String(p).split('/');
  const base = parts[parts.length - 1];
  if (parts.slice(0, -1).includes('.ssh')) return true;
  if (base === '.env' || (/^\.env\./i.test(base) && !EXAMPLE.test(base))) return true;
  if (KEY_EXT.test(base) || SSH_KEY.test(base) || base === '.netrc') return true;
  if (/credentials?/i.test(base)) return true;
  return /\.json$/i.test(base) && isSecretName(base.slice(0, -5));
}

const pausedText = (what) => `${PAUSED}: ${what}. Review and commit manually.`;
const hit = (path, why) => ({ committed: false, paused: pausedText(`a possible secret or credential in your changes (${path}: ${why})`) });
const ascii = (s) => String(s).replace(/[^\x20-\x7e]/g, '?');

// the added lines of one file of a diff (git.file's parsed hunks), joined
const addedText = (f) => f.hunks.flatMap((h) => h.lines.filter((l) => l[0] === '+').map((l) => l.slice(1))).join('\n');
function secretIn(files) {
  for (const f of files) {
    if (f.binary || f.symlink || f.status === 'deleted') continue;
    const found = scan(addedText(f));
    if (found.length) return hit(ascii(f.path), found[0].kind);
  }
  return null;
}

/** autoCommit({git, repo, now}) -> {committed: false, clean: true} | {committed: false, paused: text} | {committed: false, error: text}
 *  | {committed: true, head, paths}. git: {status(repo), file(repo, {scope, path}), stage(repo, paths), commit(repo, message)}
 *  (api.mjs's gitStatus, gitFile, gitStage, gitCommit). */
export async function autoCommit({ git, repo }) {
  const st = await git.status(repo);
  if (!st.repo) return { committed: false, clean: true };
  if (st.state || st.detached || st.conflicts.length) return { committed: false, paused: pausedText('a merge, rebase or detached HEAD is in progress, or files are in conflict') };
  const unstaged = [...st.unstaged, ...st.untracked];
  const pending = [...new Set([...st.staged, ...unstaged].map((x) => x.path))];
  if (!pending.length) return { committed: false, clean: true };
  if (st.truncated) return { committed: false, paused: pausedText('too many changed files to check') };
  const removed = new Set([...st.staged, ...st.unstaged].filter((x) => x.code === 'D').map((x) => x.path));
  // 1. the names
  for (const p of pending) if (!removed.has(p) && credentialPath(p)) return hit(ascii(p), 'a credential file');
  // 2. the content of what would be committed (the added lines)
  const toScan = [...st.unstaged.filter((x) => x.code !== 'D').map((x) => ['unstaged', x.path]), ...st.untracked.map((x) => ['untracked', x.path])];
  if (toScan.length > MAX_SCANNED) return { committed: false, paused: pausedText('too many changed files to check') };
  if (st.staged.length) {
    const r = secretIn((await git.file(repo, { scope: 'staged' })).files);
    if (r) return r;
  }
  for (const [scope, path] of toScan) {
    const r = secretIn((await git.file(repo, { scope, path })).files);
    if (r) return r;
  }
  // 3. stage what is not staged (by name, 100 at a time), commit
  const stage = [...new Set(unstaged.map((x) => x.path))];
  for (let i = 0; i < stage.length; i += STAGE_AT_ONCE) {
    if (!(await git.stage(repo, stage.slice(i, i + STAGE_AT_ONCE))).ok) return { committed: false, error: 'could not stage the changes' };
  }
  const shown = pending.slice(0, 10).map(ascii).join(', ') + (pending.length > 10 ? ` (+${pending.length - 10} more)` : '');
  const done = await git.commit(repo, `Auto-sync: save work after an agent turn\n\nChanged: ${shown}\n\n${TRAILER}\n`);
  if (!done.ok) return { committed: false, error: 'the commit did not go through' };
  return { committed: true, head: done.head, paths: pending };
}
