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
// Chat's model ids (Open WebUI's dropdown): plan-<tool>
export const chatModelId = (tool) => `plan-${tool}`;
export const toolOfChatModel = (id) => (typeof id === 'string' && /^plan-[a-z]{1,20}$/.test(id) && Object.hasOwn(HARNESSES, id.slice(5))
  && !HARNESSES[id.slice(5)].noChat ? id.slice(5) : null);
