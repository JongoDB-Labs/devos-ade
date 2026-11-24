// A page left open across an update (JON-1127): the portal page never reloads itself, so a tab kept open runs the old
// scripts (a Chat hand-off the old page has no listener for just times out). The server puts a fingerprint of the page's
// files into <meta name="bn-build"> (app.js reads it as BUILD) and answers the running one in /api/admin/status, which
// Home polls (app.js pollAdmin → check). When they differ, a bar (index.html #stale-bar) says so, once, with Reload. It
// never reloads by itself: the person may be typing in a frame. Loaded after app.js. Text only.
"use strict";

(function (root) {
  // Out of date: the server names a build, and this page has one that is different. A page without a build (an old
  // server) or an answer without one is never called stale.
  const isStale = (mine, theirs) => typeof theirs === "string" && theirs !== "" && typeof mine === "string" && mine !== "" && mine !== theirs;

  const api = { _pure: { isStale } };
  root.bnStale = api;
  if (typeof document === "undefined") return;

  let override = null;   // (for the browser check: this page's own build, replaced)
  let shown = false;
  api._setBuild = (v) => { override = v; };
  api.check = (theirs, mine) => {
    if (shown || !isStale(override !== null ? override : mine, theirs)) return;
    const bar = document.getElementById("stale-bar");
    if (!bar) return;
    shown = true;
    bar.hidden = false;
  };
  const btn = document.getElementById("stale-reload");
  if (btn) btn.addEventListener("click", () => location.reload());
})(typeof window !== "undefined" ? window : globalThis);
