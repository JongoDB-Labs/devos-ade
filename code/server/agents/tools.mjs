// The tools of your subscriptions as the Code page and Chat use them (the sandbox's terminal/bin/subscriptions and
// catalog/ai-tools.tsv name the same ids): who answers, on whose plan, through which of the tool's own interfaces —
//   sdk    Claude Code through the Agent SDK (Anthropic allows the SDK on a subscription), claude-sub's folder
//   codex  Codex's app server (codex app-server: the interface the Codex extensions use)
//   acp    the Agent Client Protocol (Copilot CLI --acp, Cursor CLI acp, Grok Build agent stdio)
// Gemini CLI is not here: Google's plans stopped working in it (2026-06-18); a Gemini API key of yours is Chat's way.
export const HARNESSES = Object.freeze({
  claude: { id: 'claude', name: 'Claude', provider: 'Anthropic', plan: 'your Claude plan', kind: 'sdk' },
  codex: { id: 'codex', name: 'Codex', provider: 'OpenAI', plan: 'your ChatGPT plan', kind: 'codex' },
  copilot: { id: 'copilot', name: 'GitHub Copilot', provider: 'GitHub', plan: 'your Copilot plan', kind: 'acp' },
  // (not a Chat model: Cursor CLI has no switch that turns its tools off — its Ask mode is a mode, which it can leave)
  cursor: { id: 'cursor', name: 'Cursor', provider: 'Cursor', plan: 'your Cursor plan', kind: 'acp', noChat: true },
  grok: { id: 'grok', name: 'Grok', provider: 'xAI', plan: 'your SuperGrok or X plan', kind: 'acp' },
});
// a session's harness: bedrock (Claude Code on Bedrock, through LiteLLM: the Code page as before) or one of HARNESSES
export const SESSION_HARNESSES = Object.freeze(['bedrock', ...Object.keys(HARNESSES)]);
export const harnessOk = (h) => typeof h === 'string' && SESSION_HARNESSES.includes(h);
// the tools that run as agents of their own (not Claude Code): bn-coded's agent op
export const AGENT_TOOLS = Object.freeze(Object.keys(HARNESSES).filter((k) => HARNESSES[k].kind !== 'sdk'));
// Chat's model ids (Open WebUI's dropdown): plan-<tool> is the tool's own default; plan-<tool>--<model> one model its
// tool offers there (the live list: chat.mjs). The model is written with the characters ids of Open WebUI and
// LiteLLM-style names carry (letters, digits, . _ : + -); any other as ~ and two lower-case hex digits (~ itself ~7e).
// A tool's id never has a "-", so the first "--" ends it. Read back strictly: only the one spelling of each id.
const ID_SAFE = /[A-Za-z0-9._:+-]/;
const MODEL_ID = /^[\x21-\x7e]{1,200}$/;
export const encodeModelId = (m) => (typeof m === 'string' && MODEL_ID.test(m)
  ? [...m].map((c) => (ID_SAFE.test(c) ? c : `~${c.charCodeAt(0).toString(16).padStart(2, '0')}`)).join('') : null);
export const decodeModelId = (e) => {
  if (typeof e !== 'string' || !e || e.length > 600) return null;
  const m = e.replace(/~([0-9a-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
  return MODEL_ID.test(m) && encodeModelId(m) === e ? m : null;
};
export const chatModelId = (tool, model = null) => (model === null ? `plan-${tool}` : `plan-${tool}--${encodeModelId(model)}`);
/** a Chat model id -> {tool, model} (model null: the tool's default) or null: not one of ours */
export function parseChatModel(id) {
  const mm = typeof id === 'string' ? /^plan-([a-z]{1,20})(?:--(.+))?$/s.exec(id) : null;
  if (!mm || !Object.hasOwn(HARNESSES, mm[1]) || HARNESSES[mm[1]].noChat) return null;
  if (mm[2] === undefined) return { tool: mm[1], model: null };
  const model = decodeModelId(mm[2]);
  return model === null ? null : { tool: mm[1], model };
}
export const toolOfChatModel = (id) => parseChatModel(id)?.tool ?? null;
// What Chat lists for Claude when Claude Code's own list of the plan's models cannot be read: the aliases Claude Code
// itself resolves on any plan (the Code page's picker falls back to the same, with the plan's default first)
export const CLAUDE_PLAN_FALLBACK = Object.freeze([{ id: 'opus', name: 'Opus' }, { id: 'sonnet', name: 'Sonnet' }, { id: 'haiku', name: 'Haiku' }]);
