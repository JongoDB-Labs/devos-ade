// Keeping a project on the built-in git server, in the Git panel (keep.ts, code/server/keep.mjs): one line at the top that
// offers it once per project — "Keep this project on your local git server?" with the repository's name to change first —
// and, once it is kept, where it is, when it was last pushed and what has not been, Push now, the portal's Git page for it
// (the repository, its issues, its pull requests), automatic pushes on or off, and Stop keeping it here.
import { useEffect, useState } from 'preact/hooks';
import { useSel } from '../store';
import { store, declineKeep, keepOnLocalGit, openPortalGit, pushKept, refreshKeep, setKeepAuto, stopKeeping } from '../app';
import { keptLine, keptShown, offerShown, repoNameOk } from '../keep';
import { ago, label } from '../text';
import { Icon, Spinner } from './icons';
import { Dialog } from './ui';
import { SandboxSaid } from './Said';

// (what the panel shows of a kept project is asked again every so often: the pushes are made by the backend, on its own)
const REFRESH_MS = 15000;

export function KeepBar() {
  const project = useSel(store, (s) => s.project);
  const found = useSel(store, (s) => s.git.found);
  const isRepo = useSel(store, (s) => s.git.status?.repo === true);
  const k = useSel(store, (s) => s.keep.views[s.project] ?? null);
  const asked = useSel(store, (s) => s.keep.ask === s.project);
  const kept = k?.state === 'kept';
  // (asked when the panel is shown for a project, and again every REFRESH_MS while it is kept — the last push, what is left)
  useEffect(() => {
    void refreshKeep(project);
  }, [project, isRepo]);
  useEffect(() => {
    if (!kept) return undefined;
    const t = setInterval(() => void refreshKeep(project), REFRESH_MS);
    return () => clearInterval(t);
  }, [project, kept]);
  if (offerShown(k, found, isRepo, asked)) return <Offer id={project} suggested={k?.suggested ?? 'project'} owner={k?.owner ?? ''} />;
  if (keptShown(k, found, isRepo)) return <Kept id={project} />;
  return null;
}

function Problem() {
  const err = useSel(store, (s) => s.keep.error);
  if (!err) return null;
  return (
    <div class="plg-err small" role="alert" data-testid="keep-error">
      {label(err.text, 400)}
      {err.said && <SandboxSaid words={err.said} />}
    </div>
  );
}

function Offer({ id, suggested, owner }: { id: string; suggested: string; owner: string }) {
  const busy = useSel(store, (s) => s.keep.busy);
  const [name, setName] = useState(suggested);
  const [edit, setEdit] = useState(false);
  const ok = repoNameOk(name);
  const off = !!busy;
  return (
    <div class="gitr keep" data-testid="keep-offer">
      <div class="gitr-row">
        <Icon name="server" size={13} />
        <span class="small">
          <b>Keep this project on your local git server?</b>
        </span>
      </div>
      <div class="gitr-row small muted">
        {edit ? (
          <label class="keep-name">
            {label(owner, 60)}/
            <input type="text" value={name} maxLength={100} spellcheck={false} autocomplete="off" aria-label="The repository's name"
              onInput={(e) => setName((e.currentTarget as HTMLInputElement).value)} data-testid="keep-name" />
          </label>
        ) : (
          <>
            A private repository, <code data-testid="keep-name-shown">{label(owner, 60)}/{label(name, 100)}</code>, pushed there by itself.{' '}
            <button type="button" class="linkish" onClick={() => setEdit(true)} data-testid="keep-rename">
              Change the name
            </button>
          </>
        )}
      </div>
      {!ok && <div class="small warn-text">A name of letters, digits, . _ and - (starting with a letter or digit, not ending in .git or .wiki).</div>}
      <Problem />
      <div class="gitr-row gitr-actions">
        <button type="button" class="btn small primary" disabled={off || !ok} onClick={() => void keepOnLocalGit(id, name === suggested ? undefined : name)} data-testid="keep-yes">
          {busy?.what === 'keep' ? <Spinner size={12} /> : <Icon name="upload" size={13} />} Keep it there
        </button>
        <button type="button" class="btn small" disabled={off} onClick={() => void declineKeep(id)} data-testid="keep-no">
          Not for this project
        </button>
      </div>
    </div>
  );
}

function Kept({ id }: { id: string }) {
  const k = useSel(store, (s) => s.keep.views[id] ?? null);
  const busy = useSel(store, (s) => s.keep.busy);
  const [stop, setStop] = useState(false);
  if (!k || k.state !== 'kept') return null;
  const off = !!busy;
  return (
    <div class="gitr keep" data-testid="keep-kept">
      <div class="gitr-row">
        <Icon name="server" size={13} />
        <span class="small">
          Kept on your local git server: <b data-testid="keep-repo">{label(k.repo, 200)}</b>
        </span>
      </div>
      <div class="small muted" data-testid="keep-line">
        {keptLine(k, ago)}
      </div>
      {!k.made && (
        <div class="small muted" data-testid="keep-not-made">
          Made on the local git server with the first commit pushed.
        </div>
      )}
      {k.rejected.map((m) => (
        <div class="small warn-text" key={m} data-testid="keep-rejected">
          {label(m, 300)}
        </div>
      ))}
      {k.lastError && (
        <div class="small warn-text" data-testid="keep-last-error">
          The last push did not work: {label(k.lastError, 400)}
        </div>
      )}
      <Problem />
      <div class="gitr-row gitr-actions">
        <button type="button" class="btn small primary" disabled={off || k.busy} onClick={() => void pushKept(id)} data-testid="keep-push">
          {busy?.what === 'push' || k.busy ? <Spinner size={12} /> : <Icon name="upload" size={13} />} Push now
        </button>
        {k.made && (
          <>
          <button type="button" class="btn small" onClick={() => openPortalGit(k.repo)} title="The repository in the Git page" data-testid="keep-open">
            <Icon name="server" size={13} /> Open in Git
          </button>
          <button type="button" class="btn small ghost" onClick={() => openPortalGit(k.repo, 'issues')} data-testid="keep-issues">
            Issues
          </button>
          <button type="button" class="btn small ghost" onClick={() => openPortalGit(k.repo, 'pulls')} data-testid="keep-pulls">
            Pull requests
          </button>
          </>
        )}
      </div>
      <div class="gitr-row">
        <label class="gitr-check small">
          <input type="checkbox" checked={k.auto} disabled={off} onChange={(e) => void setKeepAuto(id, (e.currentTarget as HTMLInputElement).checked)} data-testid="keep-auto" />
          Push by itself after a commit and after Claude's turns
        </label>
        <span class="gitr-more">
          <button type="button" class="btn small ghost" disabled={off} onClick={() => setStop(true)} data-testid="keep-stop">
            Stop keeping it here
          </button>
        </span>
      </div>
      {stop && <StopDialog id={id} repo={k.repo ?? ''} remote={k.remote ?? 'origin'} onClose={() => setStop(false)} />}
    </div>
  );
}

function StopDialog({ id, repo, remote, onClose }: { id: string; repo: string; remote: string; onClose: () => void }) {
  const busy = useSel(store, (s) => s.keep.busy);
  const go = async () => {
    if (await stopKeeping(id)) onClose();
  };
  return (
    <Dialog title="Stop keeping it here" onClose={onClose} testid="keep-stop-dialog">
      <p>
        The remote <code>{label(remote, 64)}</code> is taken out of this project, and its pushes stop. <b>{label(repo, 200)} stays on your local git server</b>,
        with everything pushed so far; this does not delete it. The Git page can still open it, and the project can be kept again from its menu.
      </p>
      <div class="dlg-actions">
        <button type="button" class="btn" onClick={onClose}>
          Cancel
        </button>
        <button type="button" class="btn primary" disabled={!!busy} onClick={() => void go()} data-testid="keep-stop-confirm">
          {busy?.what === 'stop' ? <Spinner size={12} /> : null} Stop keeping it here
        </button>
      </div>
    </Dialog>
  );
}
