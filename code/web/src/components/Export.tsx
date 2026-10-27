// Export to Files: a project's files as a zip — built in the sandbox, downloaded here, then put into the Files app (RustFS)
// by the portal that frames this page (exportzip.ts), or just saved by the browser. What goes in: what git keeps (or, without
// git, everything but dependency and build folders), never .git and node_modules unless chosen; Everything and .git history
// are the two toggles. The zip may hold secrets (.env files): it is your own file in your own store.
import { useEffect, useRef, useState } from 'preact/hooks';
import { useSel } from '../store';
import { store, toast } from '../app';
import * as api from '../api';
import { fmtBytes, portalExport, type ExportOptions, type ExportPlan } from '../exportzip';
import { label } from '../text';
import { Spinner } from './icons';
import { Dialog } from './ui';

type Phase = { kind: 'idle' } | { kind: 'building'; bytes: number } | { kind: 'uploading'; bytes: number }
  | { kind: 'done'; key: string; bucket: string; url: string | null } | { kind: 'saved'; name: string } | { kind: 'error'; text: string };

export function ExportDialog({ id, onClose }: { id: string; onClose: () => void }) {
  const p = useSel(store, (s) => s.projects.find((x) => x.id === id));
  const portal = useSel(store, (s) => s.server?.portalOrigin ?? null);
  const framed = Boolean(portal) && window.parent !== window;
  const [include, setInclude] = useState<'default' | 'all'>('default');
  const [git, setGit] = useState(false);
  const [plan, setPlan] = useState<ExportPlan | null>(null);
  const [planErr, setPlanErr] = useState('');
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' });
  const abort = useRef<AbortController | null>(null);
  const opts: ExportOptions = { include, git };
  const working = phase.kind === 'building' || phase.kind === 'uploading';

  useEffect(() => {
    let live = true;
    setPlan(null);
    setPlanErr('');
    api.exportPlan(id, { include, git }).then(
      (r) => live && setPlan(r),
      (e) => live && setPlanErr(e instanceof Error ? e.message : 'Could not look at the project.'),
    );
    return () => { live = false; };
  }, [id, include, git]);
  useEffect(() => () => abort.current?.abort(), []);
  if (!p) return null;

  // build: the zip from the sandbox (streamed here, once); to: Files through the portal, or the browser's own download
  const run = async (to: 'files' | 'download') => {
    if (!plan || plan.over) return;
    const ac = new AbortController();
    abort.current = ac;
    setPhase({ kind: 'building', bytes: 0 });
    try {
      const blob = await api.exportZip(id, opts, plan.name, plan.cap, (bytes) => setPhase({ kind: 'building', bytes }), ac.signal);
      if (to === 'download') {
        const a = document.createElement('a');
        const url = URL.createObjectURL(blob);
        a.href = url;
        a.download = plan.name;
        document.body.append(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 60000);
        setPhase({ kind: 'saved', name: plan.name });
        return;
      }
      setPhase({ kind: 'uploading', bytes: blob.size });
      const r = await portalExport(blob, plan.name, window, portal);
      setPhase({ kind: 'done', ...r });
      toast(`Exported to Files: ${r.bucket}/${r.key}`, 'ok');
    } catch (e) {
      if (ac.signal.aborted) return;
      setPhase({ kind: 'error', text: e instanceof Error ? label(e.message, 400) : 'The export failed.' });
    }
  };
  const close = () => { abort.current?.abort(); onClose(); };
  return (
    <Dialog title={`Export ${p.name} to Files`} onClose={close} testid="export-dialog">
      <p class="muted small">
        A zip of <code>{p.path}</code>, made in the sandbox{framed ? ', then put in the Files app (a bucket called code-exports) for you to download' : ''}.
      </p>
      <fieldset class="gitr-form small" disabled={working}>
        <label class="gitr-check small">
          <input type="radio" name="export-include" checked={include === 'default'} onChange={() => setInclude('default')} data-testid="export-include-default" />
          The project's files: what git keeps (.gitignore respected), without <code>.git</code> and <code>node_modules</code>
        </label>
        <label class="gitr-check small">
          <input type="radio" name="export-include" checked={include === 'all'} onChange={() => setInclude('all')} data-testid="export-include-all" />
          Everything, dependency and build folders too
        </label>
        <label class="gitr-check small">
          <input type="checkbox" checked={git} onChange={(e) => setGit((e.currentTarget as HTMLInputElement).checked)} data-testid="export-git" />
          Include the <code>.git</code> folder (the project's history)
        </label>
      </fieldset>
      <p class="small" data-testid="export-plan" aria-live="polite">
        {planErr ? <span class="plg-err">{planErr}</span>
          : !plan ? <span class="muted"><Spinner size={12} /> Looking at the project…</span>
          : plan.over ? <span class="plg-err" role="alert" data-testid="export-over">
              Too large to export: {plan.files} files, {fmtBytes(plan.bytes)} before compression; the limit is {fmtBytes(plan.cap)}. Leave out dependency and build folders (the first choice) or export a smaller folder.
            </span>
          : <span>{plan.files} {plan.files === 1 ? 'file' : 'files'}, {fmtBytes(plan.bytes)} before compression ({plan.name}){plan.skippedLinks ? `; ${plan.skippedLinks} symbolic ${plan.skippedLinks === 1 ? 'link' : 'links'} left out` : ''}.</span>}
      </p>
      <p class="muted small" data-testid="export-secrets">
        The zip holds what is in the files, <code>.env</code> files and keys among them: it is your own file in your own Files store, so keep it as private as the project.
      </p>
      {phase.kind === 'building' && <p class="small" role="status"><Spinner size={12} /> Making the zip… {fmtBytes(phase.bytes)}</p>}
      {phase.kind === 'uploading' && <p class="small" role="status"><Spinner size={12} /> Putting it in Files… {fmtBytes(phase.bytes)}</p>}
      {phase.kind === 'done' && (
        <p class="small" role="status" data-testid="export-done" data-key={phase.key}>
          In Files: <code>{phase.bucket}/{phase.key}</code>.{' '}
          {phase.url && <a href={phase.url} target="_blank" rel="noopener noreferrer" data-testid="export-open-files">Open Files</a>}
        </p>
      )}
      {phase.kind === 'saved' && <p class="small" role="status" data-testid="export-saved">Saved by your browser: <code>{phase.name}</code>.</p>}
      {phase.kind === 'error' && <div class="plg-err small" role="alert" data-testid="export-error">{phase.text}</div>}
      <div class="dlg-actions">
        <button type="button" class="btn" onClick={close}>{phase.kind === 'done' || phase.kind === 'saved' ? 'Close' : 'Cancel'}</button>
        <button type="button" class="btn" disabled={!plan || plan.over || working} onClick={() => void run('download')} data-testid="export-download"
          title="Your browser saves the zip; nothing goes to Files">
          Download the zip
        </button>
        {framed && (
          <button type="button" class="btn primary" disabled={!plan || plan.over || working} onClick={() => void run('files')} data-testid="export-go">
            Export to Files
          </button>
        )}
      </div>
      {!framed && <p class="muted small">To put it in Files, open this page from the portal's Code tab.</p>}
    </Dialog>
  );
}
