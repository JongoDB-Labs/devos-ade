// A Code page session for tests/e2e/explabs-refusals.sh: this checkout's code/server (SessionManager, the Agent SDK's
// query, spawn-client) in the code image, its Claude Code run by bn-coded in the terminal image over the shared socket,
// as the code container runs one. Opens a session on MODEL, sends the same prompt TIMES times, one after the other (each
// once the turn before it has its result), and prints one JSON line: {model, turns: [{errors, result}]} — each turn's
// error events as the page gets them (message, fix, provider, said) and its result (is_error, text). Never a permission:
// the stand-in answers in text. Usage (in the code image, from /opt/code): node e2e-explabs-refusals.mjs MODEL [TIMES]
import { query } from '@anthropic-ai/claude-agent-sdk';
import { SessionManager } from './server/sessions.mjs';
import { PermissionBroker } from './server/broker.mjs';
import { sandboxProcess } from './server/spawn-client.mjs';

const model = process.argv[2];
const times = Math.max(1, Math.min(3, Number(process.argv[3] || 1)));
let events = [];
let done;
const mgr = new SessionManager({
  query, spawn: sandboxProcess, broker: new PermissionBroker({}), log: (m) => process.stderr.write(`${m}\n`),
  onEvent: (s, seq, ev) => { events.push(ev); if (ev.type === 'result' && done) done(ev); },
});
const s = mgr.get(mgr.open({ model }).id);
const turns = [];
const timer = setTimeout(() => {
  process.stdout.write(`${JSON.stringify({ model: s.model, turns, why: 'no result within 240 s', events: events.slice(-6) })}\n`);
  process.exit(1);
}, 240000);
for (let i = 0; i < times; i++) {
  events = [];
  const finished = new Promise((resolve) => { done = resolve; });
  s.prompt({ text: 'Reply with exactly: DevOS ADE test OK' });
  const result = await finished;
  done = null;
  turns.push({
    errors: events.filter((e) => e.type === 'error').map((e) => ({ message: e.message, fix: e.fix ?? null, provider: e.provider === true, said: e.said ?? null })),
    result: { is_error: result.is_error === true, text: String(result.text ?? '').slice(0, 600), ok: JSON.stringify(result).includes('DevOS ADE test OK') },
  });
}
clearTimeout(timer);
process.stdout.write(`${JSON.stringify({ model: s.model, session: s.id, turns })}\n`);
process.exit(0);
