// A chat handed over from Chat's "Make it a project" (JON-1060; src/handoff.ts, portal/portal/chathandoff.py). The New project dialog,
// prefilled: a name from the chat's title, an empty folder of the workspace, kept on the local git server (ticked when the server is
// there), and "Continue this chat here" with the conversation shown read-only. Nothing is made until Create. Then the project is made
// and kept like any New project, and (ticked) a new session starts in it with the conversation as its first message — quoted as text
// from the chat, not as instructions from you; the session's model and everything else are what a new session starts with, and its
// mode is Manual (every command and file change waits for your OK), since the conversation is not yours to vouch for. The session
// writes the files; the kept project pushes them.
import { useEffect, useState } from 'preact/hooks';
import { useSel } from '../store';
import { store, createProject, newSession, renameSessionById, sendToSession, toast, type Problem } from '../app';
import * as api from '../api';
import { boxShown, newProjectBody } from '../keep';
import { handoffName, handoffPrompt, type Handoff } from '../handoff';
import { rootOk, WORKSPACE_ID } from '../projects';
import { label } from '../text';
import { Spinner } from './icons';
import { SandboxSaid } from './Said';
import { Dialog } from './ui';

/** The session that carries on from the chat, in the project just made (the one shown): its first message is the conversation,
 *  quoted. -> whether it started. */
export async function startHandoffSession(chat: Handoff): Promise<boolean> {
  const id = await newSession({ project: store.get().project, mode: 'default', noAsk: true });
  if (!id) return false;
  if (!sendToSession(id, handoffPrompt(chat))) return false;
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
  const valid = rootOk(target) && !taken.has(target);
  const go = async () => {
    if (!valid || busy) return;
    setErr(null);
    setBusy(true);
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
        Chat handed this conversation over{chat.title ? <> ({label(chat.title, 120)})</> : null}. Nothing is created until you press Create.
      </p>
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
          {busy ? <Spinner size={12} /> : null} Create
        </button>
      </div>
    </Dialog>
  );
}
