// fakeProc(kind, scenario) — a stand-in agent process (fake-agents.mjs) as the tests' sandboxAgent gives one
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const fakeProc = (kind, scenario = 'ok') => spawn(process.execPath, [path.join(HERE, 'fake-agents.mjs'), kind],
  { env: { ...process.env, FAKE: scenario }, stdio: ['pipe', 'pipe', 'pipe'] });
