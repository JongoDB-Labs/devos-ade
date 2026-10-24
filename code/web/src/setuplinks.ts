// What a greyed item says, and where it goes: the same rows as catalog/setup-links.tsv (tests/test_code.sh compares the
// two, line by line; the portal serves its copy to its own pickers). Each greyed item of this page — its model picker's
// Who answers, its terminal panel's Open…, its mode picker — is a choice that goes there at once (app.ts goSetup): the
// portal's Settings at that row (a message to the portal that frames this page, else a tab of its own), or the tool
// itself in the terminal panel, where its own sign-in starts. Its words are what `says` says.
export const SETUP_LINKS = {
  "terminal-off": { target: "setting:TERMINAL_ENABLED", says: "The browser terminal is off: Settings › Claude Code › Browser terminal turns it on." },
  "terminal-remote-off": { target: "setting:REMOTE_TERMINAL", says: "Not over remote access: Settings › Remote access › Terminal and Code page over remote access turns it on, from the computer running bedrock-now." },
  "tool-left-out": { target: "setting:TERMINAL_AI_TOOLS", says: "Not in the sandbox: Settings › Claude Code › Tools in the sandbox puts it in." },
  "tool-signin": { target: "signin:terminal", says: "Not signed in: it opens in the terminal, where its own sign-in starts." },
  "code-off": { target: "setting:CODE_ENABLED", says: "Needs the Code page, which runs your subscriptions' agents: Settings › Claude Code › Code page turns it on." },
  "chat-egress-off": { target: "setting:TERMINAL_EGRESS", says: "Off while the sandbox has no internet: Settings › Claude Code › Sandbox internet access." },
  "claude-plan-off": { target: "setting:CODE_CLAUDE_PLAN", says: "Off: Settings › Claude Code › Your AI subscriptions › Use my Claude plan in the Code page and Chat." },
  "chat-signin": { target: "signin:chat", says: "Sign in for Chat: Chat has sign-ins of its own, and Settings › Claude Code › Your AI subscriptions shows how." },
  "auto-off": { target: "setting:CODE_AUTO_MODE", says: "Auto is off: Settings › Claude Code › Auto mode turns it on, from the computer running bedrock-now." },
  "bypass-off": { target: "setting:CODE_ALLOW_BYPASS", says: "Bypass permissions is off: Settings › Claude Code › Allow Bypass permissions turns it on, from the computer running bedrock-now." },
  "openrouter-off": { target: "setting:OPENROUTER_API_KEY", says: "OpenRouter's models need your OpenRouter key: Settings › Chat & voice › OpenRouter API key, on the computer running bedrock-now." },
  "voice-off": { target: "setting:STT_PROVIDER", says: "Voice calls need speech-to-text: Settings › Chat & voice › Speech-to-text." },
  "models-scope": { target: "setting:CODE_MODELS", says: "Settings › Claude Code › Models for Claude Code picks the models listed here." },
} as const;
/** A reason something here is off (a key of SETUP_LINKS: a reason the table does not have does not compile). */
export type SetupReason = keyof typeof SETUP_LINKS;
/** Where a reason's item goes: a setting of the portal's Settings, or a sign-in. */
export function setupTarget(r: SetupReason): { setting: string } | { signin: 'terminal' | 'chat' } {
  const t: string = SETUP_LINKS[r].target;
  return t.startsWith('setting:') ? { setting: t.slice(8) } : { signin: t === 'signin:chat' ? 'chat' : 'terminal' };
}
/** How the portal's Settings at PLACE (a key of catalog/settings.tsv) is reached from this page: a message to the
 *  portal that frames it (its code.js takes {type: 'bn-code-setup', place} from that frame only), a tab of its own, or
 *  null — no portal known (or no such place): the item's words say where, then. */
export function settingsRoute(place: string, portalOrigin: string | null | undefined, framed: boolean):
  { post: { type: 'bn-code-setup'; place: string }; to: string } | { open: string } | null {
  if (!/^[A-Z][A-Z0-9_]{1,60}$/.test(place) || !portalOrigin) return null;
  let portal: string;
  try {
    const u = new URL(portalOrigin);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    portal = u.origin;
  } catch {
    return null;
  }
  return framed ? { post: { type: 'bn-code-setup', place }, to: portal } : { open: `${portal}/#settings/${place}` };
}
