// A Code page session for tests/e2e/free-models.sh: this checkout's code/server (SessionManager, the Agent SDK's query,
// spawn-client) in the code image, its Claude Code run by bn-coded in the terminal image over the shared socket, as the
// code container runs one. Opens a session on MODEL (the picker's choice), sends one prompt, waits for its result and
// prints one JSON line: {ok, model, result} — or {ok: false, why, events} (the last few). No permission is ever asked:
// the stand-in answers in text. Usage (in the code image, from /opt/code): node e2e-free-models.mjs MODEL
import { query } from '@anthropic-ai/claude-agent-sdk';
import { SessionManager } from './server/sessions.mjs';
import { PermissionBroker } from './server/broker.mjs';
import { sandboxProcess } from './server/spawn-client.mjs';

const model = process.argv[2];
const events = [];
let done;
const finished = new Promise((resolve) => { done = resolve; });
const mgr = new SessionManager({
  query, spawn: sandboxProcess, broker: new PermissionBroker({}), log: (m) => process.stderr.write(`${m}\n`),
  onEvent: (s, seq, ev) => { events.push(ev); if (ev.type === 'result') done(ev); },
});
const s = mgr.get(mgr.open({ model }).id);
s.prompt({ text: 'Reply with exactly: DevOS ADE test OK' });
const timer = setTimeout(() => {
  process.stdout.write(`${JSON.stringify({ ok: false, why: 'no result within 150 s', model: s.model, events: events.slice(-6) })}\n`);
  process.exit(1);
}, 150000);
const result = await finished;
clearTimeout(timer);
const text = JSON.stringify(result);
process.stdout.write(`${JSON.stringify({ ok: !result.is_error && text.includes('DevOS ADE test OK'), model: s.model, session: s.id, result })}\n`);
process.exit(0);
