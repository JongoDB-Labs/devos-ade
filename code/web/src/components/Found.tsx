// Git repositories of the workspace that are not projects yet (JON-1059): one made in the terminal (git init, or a clone) is offered
// at the foot of the Projects tab, one line per folder — Add as project, or Not now (remembered by folder, like "Not for this
// project" of keeping a project on the local git server). Asked of the backend when the tab opens, when the projects change and
// every 20 seconds while it is shown (a look at the workspace two levels down, no git run). Nothing is added by looking.
import { useEffect, useState } from 'preact/hooks';
import { useSel } from '../store';
import { store, createProject, toast } from '../app';
import * as api from '../api';
import type { FoundRepo } from '../projects';
import { label } from '../text';
import { Icon } from './icons';

export const FOUND_POLL_MS = 20000;

export function FoundRepos() {
  const projects = useSel(store, (s) => s.projects);
  const [rows, setRows] = useState<FoundRepo[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const look = async () => {
    try { setRows(await api.getFoundRepos()); } catch { /* not said: nothing is offered */ }
  };
  useEffect(() => {
    void look();
    const t = setInterval(() => void look(), FOUND_POLL_MS);
    return () => clearInterval(t);
  }, [projects]);
  const add = async (r: FoundRepo) => {
    setBusy(r.folder);
    setErr(null);
    const p = await createProject({ kind: 'folder', folder: r.folder });
    if (p) setErr(p.text);
    else setRows((x) => x.filter((y) => y.folder !== r.folder));
    setBusy(null);
  };
  const later = async (r: FoundRepo) => {
    setBusy(r.folder);
    try {
      await api.declineFoundRepo(r.folder);
      setRows((x) => x.filter((y) => y.folder !== r.folder));
    } catch (e) { toast(`Not remembered: ${e instanceof Error ? label(e.message, 200) : 'try again'}`, 'error'); }
    setBusy(null);
  };
  if (!rows.length) return null;
  return (
    <div class="proj-found" data-testid="found-repos">
      <div class="group-head" title="Folders of the workspace with a git repository in them, made in the terminal or cloned, that are not projects yet">Repositories in the workspace</div>
      {err && <div class="side-note err small" data-testid="found-error">{label(err, 300)}</div>}
      <ul class="sess-list">
        {rows.map((r) => (
          <li key={r.folder} class="proj-found-row" data-testid="found-repo" data-folder={r.folder}>
            <Icon name="branch" size={13} />
            <span class="proj-found-name" title={`/workspace/${r.folder}`}>{label(r.name, 80)}</span>
            {r.folder !== r.name && <span class="proj-path">{label(r.folder, 100)}</span>}
            <button type="button" class="btn small primary" disabled={busy !== null} onClick={() => void add(r)} data-testid="found-add">Add as project</button>
            <button type="button" class="btn small ghost" disabled={busy !== null} onClick={() => void later(r)} data-testid="found-decline">Not now</button>
          </li>
        ))}
      </ul>
    </div>
  );
}
