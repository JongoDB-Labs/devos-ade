// ./stack git-server mirror … on the code container's side (lib/localgit.sh, from `docker compose exec -T code node
// server/mirror-host.mjs`): one JSON request on stdin — {op: list | hosts | add | sync | remove, …} (mirrors.mjs) —, one JSON
// line out: {ok: true, …} or {ok: false, error}. Only from the computer running DevOS ADE (nothing of the page calls it); the
// connected hosts' credentials stay in this container: what leaves it is the one access token a mirror needs, in a request to
// the git server on this stack's own network. Never prints a token. Node built-ins only (githosts.mjs, mirrors.mjs).
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { HostError } from './githosts.mjs';
import { makeMirrors } from './mirrors.mjs';

const MAX_INPUT = 64 << 10;
const out = (o, code = 0) => { process.stdout.write(`${JSON.stringify(o)}\n`); process.exit(code); };

export async function run(input, mirrors = makeMirrors()) {
  let b;
  try { b = JSON.parse(input); } catch { throw new HostError(400, 'not the request (one JSON object on stdin)'); }
  if (!b || typeof b !== 'object' || Array.isArray(b)) throw new HostError(400, 'not the request (one JSON object on stdin)');
  switch (b.op) {
    case 'list': return { mirrors: await mirrors.list() };
    case 'hosts': return { hosts: await mirrors.hosts() };
    case 'add': return { mirror: await mirrors.add(b) };
    case 'sync': return await mirrors.sync(b);
    case 'remove': return await mirrors.remove(b);
    default: throw new HostError(400, 'op: list, hosts, add, sync or remove');
  }
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let input = '';
  try { input = fs.readFileSync(0, 'utf8'); } catch { out({ ok: false, error: 'no input on stdin' }, 2); }
  if (input.length > MAX_INPUT) out({ ok: false, error: 'the input is too long' }, 2);
  try { out({ ok: true, ...(await run(input)) }); } catch (e) {
    out({ ok: false, error: e instanceof HostError ? e.message : 'the git server could not be asked' }, 1);
  }
}
