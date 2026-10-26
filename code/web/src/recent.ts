// What this page tells the portal for Home's Continue row (POST /.bn/recent: the portal keeps it in memory for this
// sign-in, and Home shows it — on a phone too, where no Code tab is framed): the sessions that wait for you, those at
// work, then the most recently active ones — open here or only on disk — with a short title each (sandbox data: the
// portal shows it as text), and the project this page shows (Home's "New session in …"). At most RECENT_MAX sessions.
import type { SessionView } from './session';
import type { SessionInfo } from './types';
import { label } from './text';

export const RECENT_MAX = 8;
export type RecentState = 'waiting' | 'working' | 'idle' | 'closed';
export interface RecentSession { id: string; title: string; state: RecentState; at: number | null }
export interface RecentReport { waiting: number; sessions: RecentSession[]; project: { id: string; name: string } | null }

const RANK: Record<RecentState, number> = { waiting: 0, working: 1, idle: 2, closed: 2 };

/** recentReport(views, sessions, waiting, project) -> the report: the open sessions (views not closed) as they are now,
 *  the listed ones (the backend's list of transcripts) as closed, each once. */
export function recentReport(views: Record<string, SessionView>, sessions: SessionInfo[], waiting: number,
  project: { id: string; name: string } | null): RecentReport {
  const out: RecentSession[] = [];
  const seen = new Set<string>();
  const titleOf = (id: string) => sessions.find((x) => x.id === id);
  for (const v of Object.values(views)) {
    if (v.state === 'closed' || seen.has(v.id)) continue;
    seen.add(v.id);
    const info = titleOf(v.id);
    const state: RecentState = v.permissions.length ? 'waiting' : v.state === 'busy' || v.state === 'starting' ? 'working' : 'idle';
    out.push({ id: v.id, title: label(v.title || info?.title || info?.firstPrompt, 120), state, at: v.lastActive || info?.modified || null });
  }
  for (const x of sessions) {
    if (seen.has(x.id)) continue;
    seen.add(x.id);
    out.push({ id: x.id, title: label(x.title || x.firstPrompt, 120), state: 'closed', at: x.modified || null });
  }
  out.sort((a, b) => RANK[a.state] - RANK[b.state] || (b.at ?? 0) - (a.at ?? 0));
  return { waiting: Math.max(0, Math.min(99, waiting)), sessions: out.slice(0, RECENT_MAX), project: project ? { id: project.id, name: label(project.name, 80) } : null };
}
