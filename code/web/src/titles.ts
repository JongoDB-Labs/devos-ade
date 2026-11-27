// Short session titles and search by conversation, on the page (JON-517). The backend names a session: your Rename, Claude
// Code's own title, then a short one made after its first turn, then its first prompt (api.mjs listSessions); the page
// shows what it lists, and follows a `session_title` message for a session open here that was still named by its prompt.

/** The title an open session's view takes from a `session_title` message: the new one when the backend says the session was
 *  still named by its first prompt (`replaced`), else what it had (your Rename, or the title Claude Code wrote). */
export function titleAfter(current: string, m: { title: string; replaced: boolean }): string {
  return m.replaced && m.title ? m.title : current;
}

/** Whether a session open here shows for a search: its title holds the words, or the backend's list is the answer to this very
 *  search (`listedFor`: the query it was made for) and has the session — the words were in its conversation, not its title. */
export function openMatches(title: string, query: string, listedFor: string, listed: boolean): boolean {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  return title.toLowerCase().includes(needle) || (listed && listedFor.trim().toLowerCase() === needle);
}
