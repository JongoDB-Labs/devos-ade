// DevOS ADE service worker. It exists so Android Chrome offers "Install app" (and shows Activity's opt-in browser
// notifications there, which Android allows only through a service worker: a click brings the portal back), and does
// nothing more. It keeps NOTHING: no Cache Storage, no copy of Home, /api/* or anything else signed-in; no push.
// Page loads go to the network as usual; only when the network is unreachable does it answer with a short
// built-in "can't reach DevOS ADE" page instead of the browser's error. Every other request (API calls,
// scripts, icons) is not touched. Chat, Admin and Files live on other origins and never pass through here.
//
// Retiring it: deleting this file is not enough (browsers keep running an installed worker while /sw.js fails).
// Serve this instead for a few releases, so every installed copy removes itself:
//   self.addEventListener("install", () => self.skipWaiting());
//   self.addEventListener("activate", (e) => e.waitUntil(self.registration.unregister()));
// and drop the register() call in mobile.js.
"use strict";

const OFFLINE = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark"><title>DevOS ADE</title>
<style>
:root { color-scheme: light dark; --bg: #f5f3ee; --ink: #14151a; --muted: #4b4e5a; --accent: #1b6a5f; --on: #fff; }
@media (prefers-color-scheme: dark) { :root { --bg: #14110e; --ink: #f4ecdf; --muted: #b3a394; --accent: #84c8bf; --on: #14110e; } }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px; box-sizing: border-box;
  background: var(--bg); color: var(--ink); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { max-width: 340px; }
h1 { font: 600 24px/1.15 ui-serif, "New York", Georgia, serif; margin: 0 0 8px; }
p { color: var(--muted); margin: 0 0 20px; }
a { display: inline-block; min-height: 44px; line-height: 44px; padding: 0 20px; border-radius: 999px;
  background: var(--accent); color: var(--on); text-decoration: none; font-weight: 600; }
</style></head><body><main>
<h1>Can't reach DevOS ADE</h1>
<p>This device is offline, or the computer running DevOS ADE is asleep or out of reach.</p>
<a href="/">Try again</a>
</main></body></html>`;

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.mode !== "navigate" || req.method !== "GET") return;  // untouched: the browser handles it as usual
  event.respondWith(fetch(req).catch(() => new Response(OFFLINE, {
    status: 503, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  })));
});

// A click on one of Activity's notifications (activity.js, while a portal tab is open): back to that tab.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    const mine = list.find((c) => new URL(c.url).origin === self.location.origin);
    return mine ? mine.focus() : self.clients.openWindow("/");
  }));
});
