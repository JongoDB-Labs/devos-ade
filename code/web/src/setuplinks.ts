// What a greyed item says, and where it goes: the same rows as catalog/setup-links.tsv (tests/test_code.sh compares the
// two, line by line; the portal serves its copy to its own pickers). Each greyed item of this page — its model picker's
// Who answers, its terminal panel's Open… (there, a button beside the menu: never a change of it), its mode picker,
// previews, folders — goes where it is turned on (app.ts goSetup): the portal's Settings at that row (a message to the
// portal that frames this page, else a tab of its own), or the tool itself in the terminal panel, where its own sign-in
// starts. Its words are what `says` says; a button's name is "Go to " and `where`.
export const SETUP_LINKS = {
  "terminal-off": { target: "setting:TERMINAL_ENABLED", where: "Settings › Claude Code › Browser terminal", says: "The browser terminal is off: Settings › Claude Code › Browser terminal shows how to turn it on, from the computer running DevOS ADE." },
  "terminal-remote-off": { target: "setting:REMOTE_TERMINAL", where: "Settings › Remote access › Terminal and Code page over remote access", says: "Not over remote access: Settings › Remote access › Terminal and Code page over remote access shows how to turn it on, from the computer running DevOS ADE." },
  "tool-left-out": { target: "setting:TERMINAL_AI_TOOLS", where: "Settings › Claude Code › Tools in the sandbox", says: "Not in the sandbox: Settings › Claude Code › Tools in the sandbox shows how to put it in, from the computer running DevOS ADE." },
  "tool-signin": { target: "signin:terminal", where: "the tool in the terminal", says: "Not signed in: it opens in the terminal, where its own sign-in starts." },
  "code-off": { target: "setting:CODE_ENABLED", where: "Settings › Claude Code › Code page", says: "Needs the Code page, which runs your subscriptions' agents: Settings › Claude Code › Code page turns it on, from the computer running DevOS ADE." },
  "chat-egress-off": { target: "setting:TERMINAL_EGRESS", where: "Settings › Claude Code › Sandbox internet access", says: "Off while the sandbox has no internet: Settings › Claude Code › Sandbox internet access turns it on, from the computer running DevOS ADE." },
  "claude-plan-off": { target: "setting:CODE_CLAUDE_PLAN", where: "Settings › Models & providers › Claude Code › Use my Claude plan", says: "Off: Settings › Models & providers › Claude Code › Use my Claude plan in the Code page and Chat turns it on, from the computer running DevOS ADE." },
  "chat-signin": { target: "signin:chat", where: "Settings › Models & providers › Your AI subscriptions › Chat", says: "Sign in for Chat: Chat has sign-ins of its own, and Settings › Models & providers › Your AI subscriptions shows how, from the computer running DevOS ADE." },
  "auto-off": { target: "setting:CODE_AUTO_MODE", where: "Settings › Claude Code › Auto mode", says: "Auto is off: Settings › Claude Code › Auto mode turns it on, from the computer running DevOS ADE." },
  "bypass-off": { target: "setting:CODE_ALLOW_BYPASS", where: "Settings › Claude Code › Allow Bypass permissions", says: "Bypass permissions is off: Settings › Claude Code › Allow Bypass permissions turns it on, from the computer running DevOS ADE." },
  "openrouter-off": { target: "setting:OPENROUTER_API_KEY", where: "Settings › Models & providers › OpenRouter", says: "OpenRouter's models need your OpenRouter key: Settings › Models & providers › OpenRouter takes it, from the computer running DevOS ADE." },
  "explabs-off": { target: "setting:EXPLABS_API_KEY", where: "Settings › Models & providers › Experiential Labs", says: "Experiential Labs' models need your Experiential Labs key: add it in Settings › Models & providers › Experiential Labs, from the computer running DevOS ADE." },
  "voice-off": { target: "setting:STT_PROVIDER", where: "Settings › Chat & voice › Speech-to-text", says: "Voice calls need speech-to-text: Settings › Chat & voice › Speech-to-text turns it on, from the computer running DevOS ADE." },
  "models-scope": { target: "setting:CODE_MODELS", where: "Settings › Claude Code › Models for Claude Code", says: "Settings › Claude Code › Models for Claude Code picks the models listed here." },
  "remote-preview": { target: "setting:REMOTE_PREVIEW", where: "Settings › Remote access › Previews over remote access", says: "Previews are off over remote access: Settings › Remote access › Previews over remote access turns them on, from the computer running DevOS ADE." },
  "folder-read-only": { target: "setting:+project-folders", where: "Settings › Claude Code › Project folders", says: "Read-only: a folder of this computer added read-only — Settings › Claude Code › Project folders changes that, from the computer running DevOS ADE." },
  "remote-admin-off": { target: "setting:REMOTE_ADMIN_ACTIONS", where: "Settings › Remote access › Update, settings and diagnostics from your devices", says: "Off for remote access: Settings › Remote access › Update, settings and diagnostics from your devices turns it on, from the computer running DevOS ADE." },
} as const;
/** A reason something here is off (a key of SETUP_LINKS: a reason the table does not have does not compile). */
export type SetupReason = keyof typeof SETUP_LINKS;
/** Where a reason's item goes: a setting of the portal's Settings, or a sign-in. */
export function setupTarget(r: SetupReason): { setting: string } | { signin: 'terminal' | 'chat' } {
  const t: string = SETUP_LINKS[r].target;
  return t.startsWith('setting:') ? { setting: t.slice(8) } : { signin: t === 'signin:chat' ? 'chat' : 'terminal' };
}
/** How the portal's Settings for REASON (a setting's: setupTarget) is reached from this page: a message to the portal
 *  that frames it — the reason alone: the portal's code.js looks its place up in a fixed list of its own, from this
 *  frame only, and takes no place from here —, a tab of its own at that place, or null — no portal known (or no such
 *  place): the item's words say where, then. */
export function settingsRoute(reason: SetupReason, portalOrigin: string | null | undefined, framed: boolean):
  { post: { type: 'bn-code-setup'; reason: SetupReason }; to: string } | { open: string } | null {
  const t = setupTarget(reason);
  const place = 'setting' in t ? t.setting : '';
  if (!/^([A-Z][A-Z0-9_]{1,60}|\+[a-z-]{2,20})$/.test(place) || !portalOrigin) return null;
  let portal: string;
  try {
    const u = new URL(portalOrigin);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    portal = u.origin;
  } catch {
    return null;
  }
  return framed ? { post: { type: 'bn-code-setup', reason }, to: portal } : { open: `${portal}/#settings/${place}` };
}
