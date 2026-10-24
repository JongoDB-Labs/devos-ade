// fakeProc(kind, scenario) — a stand-in agent process (fake-agents.mjs) as the tests' sandboxAgent gives one
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// tool: the ACP tool it stands in for (its mode ids: Copilot's are the protocol's URIs, the others Cursor's)
export const fakeProc = (kind, scenario = 'ok', tool = 'cursor') => spawn(process.execPath, [path.join(HERE, 'fake-agents.mjs'), kind],
  { env: { ...process.env, FAKE: scenario, FAKE_TOOL: tool }, stdio: ['pipe', 'pipe', 'pipe'] });
