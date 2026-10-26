// Where the keyboard focus is when a permission card appears: the card takes it only from nothing you type into — and
// from the prompt box when it is empty and you have not typed in it for a moment (you just sent the prompt the card is
// about: the card is what needs you now, and on a phone the keyboard goes away so the card can be seen).

/** What this needs of a focused element (a DOM Element has both). */
export interface Focused {
  tagName?: string;
  isContentEditable?: boolean;
  /** a field's text (the prompt box's) */
  value?: string;
  dataset?: { testid?: string };
}

/** No keystroke in the prompt box for this long (ms): an empty box gives the focus to a card that arrives. */
export const QUIET_MS = 1500;
let lastTyped = 0;
/** The prompt box says a key went into it (Composer): an empty box keeps the focus for QUIET_MS after it. */
export function notePromptTyping(now = Date.now()): void {
  lastTyped = now;
}

/** A field, an editor (contenteditable, as CodeMirror's) or a frame (the terminal) — empty or not: a card that
 *  appears must not take the focus from it, or the next keystroke meant for it would land on the card. */
export function typingIn(el: Focused | null | undefined): boolean {
  if (!el) return false;
  const t = typeof el.tagName === 'string' ? el.tagName.toUpperCase() : '';
  return ['INPUT', 'TEXTAREA', 'SELECT', 'IFRAME', 'OBJECT', 'EMBED'].includes(t) || el.isContentEditable === true;
}

/** Whether a permission card (a question, a plan) that appears may take the focus from what has it: from nothing you
 *  type into; from the prompt box only while it is empty and quiet (no keystroke for QUIET_MS). */
export function cardMayTakeFocus(el: Focused | null | undefined, now = Date.now(), typed = lastTyped): boolean {
  if (!typingIn(el)) return true;
  return el?.dataset?.testid === 'prompt' && !el.value && now - typed >= QUIET_MS;
}
