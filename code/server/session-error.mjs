// A session's refusal or failure as the API and the WebSocket answer it: our sentence (message, with its HTTP status),
// and — apart — the words of the sandbox or of Claude Code (said, saidBy), never mixed into ours.
export class SessionError extends Error {
  constructor(message, status = 400, { said = null, saidBy = null } = {}) {
    super(message); this.status = status;
    if (typeof said === 'string' && said) { this.said = said; this.saidBy = saidBy === 'sandbox' ? 'sandbox' : 'claude'; }
  }
}
