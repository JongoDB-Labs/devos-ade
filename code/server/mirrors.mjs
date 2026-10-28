// Mirroring of the built-in git server's repositories (Forgejo's own repository mirroring; lib/localgit.sh, JON-810) to the
// remote git hosts you connected (GitHub, GitLab, any https server with an access token), driven from this container —
// the one that holds those hosts' credentials — through Caddy's internal site for it (caddy/localgit-on.caddy, :8099: a
// few API paths of one service, no sign-in header), with the built-in host's repository-scoped token. Two kinds, never
// mixed up:
//   push   the local repository is the source of truth and the remote a copy: Forgejo pushes all of its branches and tags
//          to the remote on every push here (sync_on_commit) and at an interval, and force-updates the remote's refs — what
//          is only there is overwritten. A normal collaborative remote (origin, fetch, pull, push) is a different thing.
//   pull   the remote is the source: a read-only local copy that Forgejo fetches at an interval (a new repository).
// The remote credential — a connected host's access token — is handed to Forgejo, which keeps it (encrypted with its own
// secret, in the gitdata volume) because it pushes and fetches on its own, later, whether or not this page is open. That is
// why only an access token is used (a sign-in's token lasts hours and cannot be renewed in there), and why a mirror is made
// only from the computer running DevOS ADE (./stack git-server mirror …, never the page). Forgejo reaches the remote only
// through a network of its own that exists while a mirror does (lib/localgit.sh), and only to the hosts named for it.
// Everything Forgejo answers is data: checked and cut before it goes anywhere.
import { GitHosts, HostError, LOCALGIT, httpsAuth } from './githosts.mjs';
import { parseRemoteUrl } from './gitremote.mjs';
import { short } from './validate.mjs';

export const API = process.env.LOCALGIT_API || 'http://caddy:8099';
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const INTERVAL = /^(?:[1-9][0-9]{0,2})(?:m|h)$|^0$/;   // 10m … 999h (Forgejo's minimum is 10m); 0: only on a push here (push mirrors)
const err = (status, m) => new HostError(status, m);
const ago = (t) => (typeof t === 'string' && /^\d{4}-\d\d-\d\dT[\d:.]+(Z|[+-]\d\d:\d\d)$/.test(t) ? t : null);
const GO_ZERO = /^0001-01-01/;

// toInterval('8h') -> Forgejo's duration text ('8h0m0s'); '0' -> '0s' (no schedule)
export function toInterval(v) {
  if (v === undefined || v === null || v === '') return '8h0m0s';
  const s = String(v).trim();
  if (!INTERVAL.test(s)) throw err(400, 'an interval of 10m to 999h (8h, 30m), or 0 for a push mirror to push only when something is pushed here');
  if (s === '0') return '0s';
  const n = Number(s.slice(0, -1));
  if (s.endsWith('m')) { if (n < 10) throw err(400, 'an interval of at least 10 minutes (Forgejo\'s own minimum)'); return `${Math.floor(n / 60)}h${n % 60}m0s`; }
  return `${n}h0m0s`;
}

export function makeMirrors({ store = new GitHosts(), fetchImpl = globalThis.fetch, base = API, now = () => Date.now() } = {}) {
  // the built-in host's token (repository scope): what Forgejo's API gets
  function local() {
    const h = store.read().hosts.find((x) => x.builtin === LOCALGIT.id);
    const tok = h ? GitHosts.secret(h) : null;
    if (!h || !tok) throw err(409, 'the built-in git server is not connected as a Git host yet: ./stack up connects it');
    return { token: tok, owner: h.username };
  }
  async function api(method, path, body) {
    const { token } = local();
    let res;
    try {
      res = await fetchImpl(`${base}/api/v1${path}`, { method, headers: { Authorization: `token ${token}`, Accept: 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) },
        body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(60000), redirect: 'error' });
    } catch { throw err(502, 'the built-in git server did not answer (./stack logs forgejo; is the Code page running?)'); }
    let json = null;
    const text = await res.text().catch(() => '');
    try { json = text ? JSON.parse(text) : null; } catch { json = null; }
    if (!res.ok) throw err(res.status === 404 ? 404 : res.status === 401 || res.status === 403 ? 502 : 400, `the git server refused: ${short(json?.message || `HTTP ${res.status}`, 300)}`);
    return json;
  }
  // the remote host and credential a mirror uses: a connected git host with an access token, for the URL's host
  function remoteFor(url) {
    let p;
    try { p = parseRemoteUrl(url); } catch (e) { throw err(400, e.message); }
    if (p.scheme !== 'https') throw err(400, 'a mirror needs an https:// remote (with a connected host\'s access token)');
    const h = store.match(p);
    if (!h) throw err(400, `${p.host}${p.port ? `:${p.port}` : ''} is not a connected git host: connect it (Git hosts) with an access token first`);
    if (h.builtin === LOCALGIT.id) throw err(400, 'that is the built-in git server itself');
    if (h.auth === 'oauth') throw err(400, `${h.label} is connected with a sign-in, whose token lasts hours and cannot be renewed inside the git server: connect it with an access token to mirror to it`);
    if (!httpsAuth(h.auth)) throw err(400, 'a mirror needs an access token');
    const secret = GitHosts.secret(h);
    if (!secret) throw err(400, `${h.label} has no access token`);
    const web = `https://${p.host}${p.port ? `:${p.port}` : ''}/${p.path.replace(/^~?\/*/, '').replace(/\.git\/?$/, '')}.git`;
    return { p, h, secret, web };
  }
  const view = (owner, repo, m) => ({ direction: 'push', repo: `${owner}/${repo}`, name: short(m.remote_name, 100), remote: short(String(m.remote_address || '').replace(/\/\/[^/@]*@/, '//'), 300),
    interval: short(m.interval, 20), syncOnCommit: m.sync_on_commit === true, createdAt: ago(m.created), lastSync: m.last_update && !GO_ZERO.test(m.last_update) ? ago(m.last_update) : null,
    lastError: m.last_error ? short(m.last_error, 300) : null, force: true });
  const pullView = (r) => ({ direction: 'pull', repo: short(r.full_name, 140), name: null, remote: short(String(r.original_url || '').replace(/\/\/[^/@]*@/, '//'), 300), interval: short(r.mirror_interval, 20),
    syncOnCommit: false, createdAt: ago(r.created_at), lastSync: ago(r.mirror_updated), lastError: null, force: false });

  // list() -> every mirror of the owner: push mirrors of each repository, and the repositories that are pull mirrors
  async function list() {
    const { owner } = local();
    const out = [];
    const repos = [];
    for (let page = 1; page <= 20; page++) {
      const data = await api('GET', `/user/repos?limit=50&page=${page}`);
      if (!Array.isArray(data)) break;
      for (const x of data) if (x && x.owner?.login === owner && NAME.test(x.name || '')) repos.push(x);
      if (data.length < 50) break;
    }
    for (const r of repos) {
      if (r.mirror === true) out.push(pullView(r));
      let ms = [];
      try { ms = await api('GET', `/repos/${owner}/${r.name}/push_mirrors`); } catch { ms = []; }
      for (const m of Array.isArray(ms) ? ms.slice(0, 20) : []) out.push(view(owner, r.name, m));
    }
    return out;
  }

  // add({direction, repo, remote, interval, syncOnCommit}) -> the mirror (as list shows it)
  async function add(b) {
    const { owner } = local();
    const direction = b?.direction;
    if (direction !== 'push' && direction !== 'pull') throw err(400, 'direction: push or pull');
    const repo = String(b?.repo || '');
    if (!NAME.test(repo)) throw err(400, 'the repository on the built-in server (its name: letters, digits, . _ -)');
    const r = remoteFor(b?.remote);
    const interval = toInterval(b?.interval);
    if (direction === 'push') {
      if (interval !== '0s' && Number.parseInt(interval, 10) < 0) throw err(400, 'interval');
      try { await api('GET', `/repos/${owner}/${repo}`); } catch (e) { throw e.status === 404 ? err(404, `no repository ${owner}/${repo} on the built-in server: push to it first (a push creates it)`) : e; }
      const m = await api('POST', `/repos/${owner}/${repo}/push_mirrors`, { remote_address: r.web, remote_username: r.h.username || 'x-access-token', remote_password: r.secret,
        interval, sync_on_commit: b?.syncOnCommit !== false });
      return view(owner, repo, m);
    }
    const created = await api('POST', '/repos/migrate', { clone_addr: r.web, auth_username: r.h.username || 'x-access-token', auth_password: r.secret, mirror: true, private: true,
      mirror_interval: interval === '0s' ? '8h0m0s' : interval, repo_name: repo, repo_owner: owner, service: 'git', issues: false, pull_requests: false, releases: false, labels: false, milestones: false, wiki: false });
    return pullView(created);
  }

  async function sync(b) {
    const { owner } = local();
    const repo = String(b?.repo || '');
    if (!NAME.test(repo)) throw err(400, 'the repository on the built-in server');
    const direction = b?.direction === 'pull' ? 'pull' : 'push';
    await api('POST', `/repos/${owner}/${repo}/${direction === 'pull' ? 'mirror-sync' : 'push_mirrors-sync'}`);
    return { ok: true, repo: `${owner}/${repo}`, direction, at: now() };
  }

  async function remove(b) {
    const { owner } = local();
    const repo = String(b?.repo || '');
    if (!NAME.test(repo)) throw err(400, 'the repository on the built-in server');
    if (b?.direction === 'pull') throw err(400, 'a pull mirror is a repository: delete it in the git server\'s web UI (Settings › Danger zone), or convert it there');
    const name = String(b?.name || '');
    if (!NAME.test(name)) throw err(400, 'the mirror\'s name (./stack git-server mirror list)');
    await api('DELETE', `/repos/${owner}/${repo}/push_mirrors/${name}`);
    return { ok: true };
  }

  // hosts() -> the host names the mirrors reach (the egress the git server gets is limited to them)
  async function hosts() {
    const set = new Set();
    for (const m of await list()) { try { set.add(new URL(m.remote).hostname); } catch { /* not a URL */ } }
    return [...set].sort();
  }
  return { list, add, sync, remove, hosts };
}
