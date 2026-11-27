// A chat handed over from Chat's "Make it a project" (JON-1060; src/handoff.ts, portal/portal/chathandoff.py). The New project dialog,
// prefilled: a name from the chat's title, an empty folder of the workspace, kept on the local git server (ticked when the server is
// there), and "Continue this chat here" with the conversation shown read-only. Nothing is made until Create. Then the project is made
// and kept like any New project, and (ticked) a new session starts in it with the conversation as its first message — quoted as text
// from the chat, not as instructions from you; the session's model and everything else are what a new session starts with, and its
// mode is Manual (every command and file change waits for your OK), since the conversation is not yours to vouch for. The session
// writes the files; the kept project pushes them. Or (JON-1158) a project you have instead of a new one: no project is made, and the
// session that carries on from the chat starts in the one you chose (its folder, its trust as it is) — the workspace, a project of it
// or a folder of this computer; a project that cannot start a session (its folder not there, not in the sandbox yet) is not offered.
import { useEffect, useState } from 'preact/hooks';
import { useSel } from '../store';
import { store, createProject, newSession, renameSessionById, sendToSession, setProject, toast, type Problem } from '../app';
import * as api from '../api';
import { boxShown, newProjectBody } from '../keep';
import { handoffName, handoffPrompt, handoffTargets, type Handoff } from '../handoff';
import { rootOk, WORKSPACE_ID } from '../projects';
import { label } from '../text';
import { Spinner } from './icons';
import { SandboxSaid } from './Said';
import { Dialog } from './ui';

/** The session that carries on from the chat, in the project shown (just made, or into: one you have, by its name): its first
 *  message is the conversation, quoted. -> whether it started. (noAsk: a project's own settings not applied as they are do not
 *  apply to it — the safer side for text from a chat; trusted ones do, and the dialog says so before.) */
export async function startHandoffSession(chat: Handoff, into?: string): Promise<boolean> {
  const id = await newSession({ project: store.get().project, mode: 'default', noAsk: true });
  if (!id) return false;
  if (!sendToSession(id, handoffPrompt(chat, undefined, into))) return false;
  if (chat.title) void renameSessionById(id, label(`From the chat: ${chat.title}`, 100));
  return true;
}

export function HandoffDialog({ chat, note, onClose }: { chat: Handoff | null; note: string; onClose: () => void }) {
  if (!chat) {
    return (
      <Dialog title="Make it a project" onClose={onClose} testid="handoff-dialog">
        <p data-testid="handoff-note" role="alert">
          {label(note, 400)}
        </p>
        <div class="dlg-actions">
          <button type="button" class="btn primary" onClick={onClose} data-testid="handoff-close">
            Close
          </button>
        </div>
      </Dialog>
    );
  }
  return <HandoffForm chat={chat} onClose={onClose} />;
}

function HandoffForm({ chat, onClose }: { chat: Handoff; onClose: () => void }) {
  const projects = useSel(store, (s) => s.projects);
  const taken = new Set(projects.map((p) => p.root));
  // where it continues: a new project made from the chat, or one you have (the one shown first, else the workspace)
  const targets = handoffTargets(projects);
  const [where, setWhere] = useState<'new' | 'existing'>('new');
  const [pick, setPick] = useState(() => {
    const shown = store.get().project;
    return targets.some((p) => p.id === shown) ? shown : WORKSPACE_ID;
  });
  const chosen = targets.find((p) => p.id === pick) ?? targets[0] ?? null;
  // (its own Claude Code settings apply when you trusted them: their rules can let a command run without asking)
  const ownApply = chosen !== null && (chosen.settings === 'trusted' || chosen.settings === 'recheck');
  const [name, setName] = useState(() => handoffName(chat.title, taken));
  // "Keep it on your local git server": when the built-in server is there (null: not known yet); on by default
  const [available, setAvailable] = useState<boolean | null>(null);
  const [keep, setKeep] = useState(true);
  const [carry, setCarry] = useState(true);
  const [err, setErr] = useState<Problem | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let gone = false;
    void api.getProjectKeep(WORKSPACE_ID).then((k) => !gone && setAvailable(k.available), () => !gone && setAvailable(false));
    return () => {
      gone = true;
    };
  }, []);
  const target = name.trim();
  const valid = where === 'existing' ? chosen !== null : rootOk(target) && !taken.has(target);
  const go = async () => {
    if (!valid || busy) return;
    setErr(null);
    setBusy(true);
    if (where === 'existing' && chosen) {
      // (nothing made: the chosen project shown, and the session that carries on from the chat started there)
      setProject(chosen.id);
      const ok = store.get().project === chosen.id && (await startHandoffSession(chat, chosen.workspace ? 'Workspace' : chosen.name));
      setBusy(false);
      if (!ok) {
        setErr({ text: `The session did not start in ${chosen.name}: start one there, and paste the chat if you need it.`, said: null });
        return;
      }
      onClose();
      return;
    }
    const e = await createProject(newProjectBody('empty', target, { git: true, keep: boxShown(available, 'empty') && keep }));
    if (e) {
      setBusy(false);
      setErr(e);
      return;
    }
    if (carry && !(await startHandoffSession(chat))) toast('The project is made, but the session did not start: start one in it, and paste the chat if you need it.', 'error');
    setBusy(false);
    onClose();
  };
  return (
    <Dialog title="Make it a project" onClose={onClose} wide testid="handoff-dialog">
      <p class="small" data-testid="handoff-intro">
        Chat handed this conversation over{chat.title ? <> ({label(chat.title, 120)})</> : null}.{' '}
        {where === 'existing' ? 'Nothing starts until you press Continue there.' : 'Nothing is created until you press Create.'}
      </p>
      <fieldset class="ho-where" data-testid="handoff-where">
        <legend class="small">Continue it in</legend>
        <label class="gitr-check">
          <input type="radio" name="ho-where" checked={where === 'new'} onChange={() => setWhere('new')} data-testid="handoff-where-new" />
          <span>A new project</span>
        </label>
        <label class="gitr-check">
          <input type="radio" name="ho-where" checked={where === 'existing'} disabled={!targets.length} onChange={() => setWhere('existing')}
            data-testid="handoff-where-existing" />
          <span>
            A project you have
            {!targets.length && <span class="muted small"> (none can start a session now)</span>}
          </span>
        </label>
      </fieldset>
      {where === 'existing' ? (
        <div class="gitr-form np-fields">
          <label class="wide">
            The project
            <select value={chosen?.id ?? ''} onChange={(e) => setPick((e.currentTarget as HTMLSelectElement).value)} aria-describedby="handoff-into-note"
              data-testid="handoff-project">
              {targets.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.workspace ? 'Workspace' : label(p.name, 80)} — {label(p.path, 120)}
                  {p.readOnly || p.pending === 'rw' ? ' (read-only)' : ''}
                </option>
              ))}
            </select>
          </label>
          <p class="muted small wide" id="handoff-into-note" data-testid="handoff-into-note">
            A new Claude session starts there, in Manual mode, with the conversation below as its context — text from the chat, not instructions
            from you. Nothing else is made.
          </p>
          {ownApply && (
            <p class="small wide ho-own" role="note" data-testid="handoff-own-settings">
              This project&apos;s own Claude Code settings apply to that session — its rules, hooks and MCP servers — because you trusted them. A rule that
              allows a command lets it run without asking, even with the chat&apos;s text in the session.
            </p>
          )}
        </div>
      ) : (
      <>
      <div class="gitr-form np-fields">
        <label class="wide">
          The project&apos;s name (a new, empty folder of the workspace, started as a git repository)
          <input type="text" value={name} maxLength={160} spellcheck={false} autocomplete="off" onInput={(e) => setName((e.currentTarget as HTMLInputElement).value)}
            onKeyDown={(e) => e.key === 'Enter' && void go()} data-testid="handoff-name" />
        </label>
      </div>
      {boxShown(available, 'empty') && (
        <label class="gitr-check np-keep">
          <input type="checkbox" checked={keep} onChange={(e) => setKeep((e.currentTarget as HTMLInputElement).checked)} data-testid="handoff-keep" />
          <span>
            Keep it on your local git server
            <span class="muted small np-keep-note"> A private repository there, pushed by itself.</span>
          </span>
        </label>
      )}
      <label class="gitr-check np-keep">
        <input type="checkbox" checked={carry} onChange={(e) => setCarry((e.currentTarget as HTMLInputElement).checked)} data-testid="handoff-continue" />
        <span>
          Continue this chat here
          <span class="muted small np-keep-note">
            {' '}
            A new Claude session starts in the project with the conversation below as its context — text from the chat, not instructions from you. It writes the
            files; each change waits for your OK.
          </span>
        </span>
      </label>
      </>
      )}
      <p class="muted small" id="handoff-chat-label">
        The conversation, read only ({chat.text.length.toLocaleString('en-US')} characters):
      </p>
      <pre class="ho-chat" tabIndex={0} aria-labelledby="handoff-chat-label" data-testid="handoff-text">
        {chat.text}
      </pre>
      {err && (
        <div class="plg-err small" role="alert" data-testid="handoff-error">
          {label(err.text, 300)}
          {err.said && <SandboxSaid words={err.said} />}
        </div>
      )}
      <div class="dlg-actions">
        <button type="button" class="btn" onClick={onClose} data-testid="handoff-cancel">
          Cancel
        </button>
        <button type="button" class="btn primary" disabled={!valid || busy} onClick={() => void go()} data-testid="handoff-create">
          {busy ? <Spinner size={12} /> : null} {where === 'existing' ? 'Continue there' : 'Create'}
        </button>
      </div>
    </Dialog>
  );
}
