// A stand-in for Gemini CLI 0.65.0 in ACP mode (gemini --acp), from its source's shapes (no vendor's code, no network):
// authMethods without a default, session/new that signs in by itself (or fails with its two refusals), the modes default,
// autoEdit, yolo and plan, a session/set_mode that applies the mode before it answers and never sends current_mode_update,
// models in availableModels. FAKE: ok | no-key | no-auth | stale | stale-partial | start-autoedit | start-yolo.
// FAKE_SEEN gets a line for each authenticate and set_mode asked.
import readline from 'node:readline';
import fs from 'node:fs';

const scenario = process.env.FAKE || 'ok';
const send = (o) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...o })}\n`);
const seen = (what) => { if (process.env.FAKE_SEEN) fs.appendFileSync(process.env.FAKE_SEEN, `${what}\n`); };
const MODES = [{ id: 'default', name: 'Default' }, { id: 'autoEdit', name: 'Auto Edit' }, { id: 'yolo', name: 'YOLO' }, { id: 'plan', name: 'Plan' }];
let mode = scenario === 'start-autoedit' ? 'autoEdit' : scenario === 'start-yolo' ? 'yolo' : 'default';
let n = 0;

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  if (m.id === undefined || !m.method) return;
  const ok = (result) => send({ id: m.id, result });
  const fail = (message) => send({ id: m.id, error: { code: -32000, message } });
  switch (m.method) {
    case 'initialize':
      return ok({ protocolVersion: 1, agentCapabilities: { loadSession: true, promptCapabilities: { image: true } },
        authMethods: ['oauth-personal', 'gemini-api-key', 'vertex-ai', 'gateway'].map((id) => ({ id, name: id })), agentInfo: { name: 'gemini-cli', version: '0.65.0' } });
    case 'authenticate': seen(`authenticate ${m.params?.methodId}`); return ok({});
    case 'session/new':
      if (scenario === 'no-key') return fail('Gemini API key is missing or not configured.');
      if (scenario === 'no-auth') return fail('Authentication required.');
      // its stale login: its sign-in screen on stdout (the alternate screen), then a code asked for on stdin — no answer
      if (scenario === 'stale') { process.stdout.write('\x1b[?1049h\x1b[2J\x1b[H'); return undefined; }
      if (scenario === 'stale-partial') { process.stdout.write('\x1b[?1049h Please visit the following URL'); return undefined; }
      return ok({ sessionId: `g-${++n}`, modes: { currentModeId: mode, availableModes: MODES },
        models: { currentModelId: 'gemini-x-pro', availableModels: [{ modelId: 'gemini-x-pro', name: 'Gemini X Pro' }, { modelId: 'gemini-x-flash', name: 'Gemini X Flash' }] } });
    case 'session/set_mode':
      seen(`set_mode ${m.params?.modeId}`);
      if (!MODES.some((x) => x.id === m.params?.modeId)) return fail(`Invalid params: unknown mode ${m.params?.modeId}`);
      mode = m.params.modeId;
      return ok({});
    case 'session/set_model': return ok({});
    case 'session/prompt':
      send({ method: 'session/update', params: { sessionId: m.params.sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: `mode ${mode}` } } } });
      return ok({ stopReason: 'end_turn' });
    default: return send({ id: m.id, error: { code: -32601, message: 'not here' } });
  }
});
