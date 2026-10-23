// Which tools of your subscriptions are in the sandbox and signed in, as its own `subscriptions status` says (bn-coded's
// subscriptions.status: each tool's own status command, reduced to words), kept for a minute: the Code page's picker
// and Chat's model list ask it often. Words only — never an account's detail.
import { HARNESSES } from './tools.mjs';

const SIGNED = ['yes', 'no', 'unknown'];

export function makeStatus({ call, ttlMs = 60000, now = () => Date.now(), log = () => {} }) {
  let cache = null, at = 0, inflight = null;
  return async function status({ fresh = false } = {}) {
    if (!fresh && cache && now() - at < ttlMs) return cache;
    if (!inflight) {
      inflight = call({ op: 'subscriptions.status' }, { timeoutMs: 75000 })
        .then(({ result }) => {
          const tools = {};
          for (const t of Array.isArray(result?.tools) ? result.tools : []) {
            if (t && typeof t.id === 'string' && Object.hasOwn(HARNESSES, t.id)) {
              tools[t.id] = { installed: t.installed === true, signed: SIGNED.includes(t.signed) ? t.signed : 'unknown' };
            }
          }
          cache = { tools, checked: now() }; at = now();
          return cache;
        })
        .catch((e) => {
          log(`subscriptions status: ${String(e?.message || e).slice(0, 200)}`);
          // (unknown: every tool "not known here" — never signed in by default)
          if (!cache) return { tools: {}, checked: null, error: 'the sandbox did not say' };
          return cache;
        })
        .finally(() => { inflight = null; });
    }
    return inflight;
  };
}

/** the harnesses as the page's picker shows them: each with whether it is there, signed in, and may be used here */
export function harnessList(st, { planAllowed = false } = {}) {
  return Object.values(HARNESSES).map((h) => {
    const t = st?.tools?.[h.id] ?? { installed: false, signed: 'unknown' };
    const allowed = h.id === 'claude' ? planAllowed === true : true;
    return { id: h.id, name: h.name, provider: h.provider, plan: h.plan, installed: t.installed, signed: t.signed, allowed };
  });
}
