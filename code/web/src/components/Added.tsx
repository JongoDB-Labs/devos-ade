// Projects the backend added by itself (JON-1059): a repository or a project folder made in the workspace — by an agent in the
// Terminal, by you, a clone — is a project without a click, and a short notice at the foot of the Projects tab says so, one line per
// project: "Added from the workspace: name — kept on your local git server", with Remove from Code (remembered: it is not added
// again) and a way to dismiss the notice (the project stays). A repository with a remote of its own is added, not kept: its line
// offers Keep it on your local git server; a folder without git offers Start git here. The page asks again every 30 seconds
// while the tab is shown (the backend looks at the workspace two levels down, no git run) so a project made in the Terminal appears.
import { useEffect, useState } from 'preact/hooks';
import { useSel } from '../store';
import { store, refreshProjects, removeProjectById, dismissAddedNotice, startGitHere, keepOnLocalGit, toast } from '../app';
import { label } from '../text';
import { Icon } from './icons';

export const ADDED_POLL_MS = 30000;

export function AddedProjects() {
  const projects = useSel(store, (s) => s.projects);
  const notices = useSel(store, (s) => s.projectsAdded);
  const [busy, setBusy] = useState<string | null>(null);
  useEffect(() => {
    const t = setInterval(() => { if (document.visibilityState !== 'hidden') void refreshProjects(); }, ADDED_POLL_MS);
    return () => clearInterval(t);
  }, []);
  const rows = notices.map((n) => ({ n, p: projects.find((x) => x.id === n.id && !x.gone) })).filter((r) => !!r.p);
  if (!rows.length) return null;
  const run = async (id: string, fn: () => Promise<unknown>) => {
    setBusy(id);
    try { await fn(); } finally { setBusy(null); }
  };
  const remove = (id: string) => run(id, async () => {
    const e = await removeProjectById(id);
    if (e) toast(`Not removed: ${label(e.text, 200)}`, 'error');
  });
  return (
    <div class="proj-found" data-testid="added-projects">
      {rows.map(({ n, p }) => {
        if (!p) return null;
        const git = p.git === true;
        return (
          <div key={n.id} class="proj-found-row" data-testid="added-project" data-folder={p.root}>
            <Icon name="branch" size={13} />
            <span class="proj-found-text" data-testid="added-text">
              Added from the workspace: <b title={p.path}>{label(p.name, 80)}</b>
              {n.kept ? <> — kept on your local git server <span class="proj-path">{label(n.kept, 100)}</span></>
                : git ? <> — not kept on your local git server{n.declined ? ' (you said not for this project)' : ''}</>
                  : <> — no git yet</>}
            </span>
            {git && !n.kept && !n.declined && (
              <button type="button" class="btn small" disabled={busy !== null} onClick={() => void run(n.id, () => keepOnLocalGit(n.id).then(() => refreshProjects()))} data-testid="added-keep">
                Keep it on your local git server
              </button>
            )}
            {!git && (
              <button type="button" class="btn small" disabled={busy !== null} onClick={() => void run(n.id, () => startGitHere(n.id))} data-testid="added-git">Start git here</button>
            )}
            <button type="button" class="btn small ghost" disabled={busy !== null} onClick={() => void remove(n.id)} data-testid="added-remove">Remove from Code</button>
            <button type="button" class="icon-btn tiny" disabled={busy !== null} title="Dismiss this notice (the project stays)" aria-label={`Dismiss the notice about ${label(p.name, 60)}`}
              onClick={() => void run(n.id, () => dismissAddedNotice(n.id))} data-testid="added-dismiss">
              <Icon name="close" size={12} />
            </button>
          </div>
        );
      })}
    </div>
  );
}
