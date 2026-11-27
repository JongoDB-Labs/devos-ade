// Several sessions at once (JON-605): the words of the Delete… dialog and of the one notice that says what was done and
// what was skipped. Pure text: the requests are app.ts's (bulkArchive, bulkDelete), one per session.

/** How many titles the dialog lists before "and N more". */
export const BULK_TITLES_SHOWN = 4;

/** The titles the Delete… dialog names: the first few, then "and N more". */
export function bulkTitles(titles: string[]): { shown: string[]; more: number } {
  return { shown: titles.slice(0, BULK_TITLES_SHOWN), more: Math.max(0, titles.length - BULK_TITLES_SHOWN) };
}

/** The dialog's heading: "Delete this session?" for one, "Delete 3 sessions?" for several. */
export const bulkDeleteHeading = (n: number): string => (n === 1 ? 'Delete this session?' : `Delete ${n} sessions?`);

/** One short reason a session was skipped, from the words of the refusal (the backend's, or this page's own check). */
export function skipReason(message: string): string {
  const m = message.toLowerCase();
  if (/turn is running/.test(m)) return 'a turn is running in it';
  if (/terminal|elsewhere in the sandbox/.test(m)) return 'it is open in the terminal';
  if (/read only|no longer added/.test(m)) return 'it is read only';
  const t = message.replace(/\s+/g, ' ').trim().replace(/[.;:]+$/, '');
  return t.length > 60 ? `${t.slice(0, 59)}…` : t || 'it was refused';
}

/** The one notice after a bulk action: "Deleted 4; 1 skipped: a turn is running in it." (the same reason said once). */
export function bulkNotice(verb: string, done: number, reasons: string[]): string {
  const head = `${verb} ${done}`;
  if (!reasons.length) return `${head}.`;
  const uniq = [...new Set(reasons)];
  return `${head}; ${reasons.length} skipped: ${uniq.join(', ')}.`;
}
