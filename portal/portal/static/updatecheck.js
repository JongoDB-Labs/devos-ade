// Check for updates: a release check now, from a click (POST /api/update/check; portal/updates.py Refresher.manual).
// The same line in Home's header and in Settings › Updates & backups › Daily release check — "Up to date · checked 12 min
// ago · Check for updates", "Update available — v0.9.0" (to Home's update card), "Checking…", GitHub could not be
// reached, GitHub's limit for this hour — and the Ctrl/⌘+K entry (search.js). The result is announced (aria-live); why,
// and that nothing about this install is sent, is under the line's About this check (also the button's description). It asks
// GitHub's public release list through the portal; it works with the daily check off too (a click is an explicit
// request). The portal answers within a few seconds, or says a check still runs: then Home's summary (app.js refresh)
// is followed until it ends. Loaded after app.js (el, $, showTab, renderUpdate, refresh, toast come from there). Text
// only: every node is built with el()/textContent.
"use strict";

(function (root) {
  const PRIVACY = "Check for updates asks GitHub's public list of DevOS ADE releases now. It sends nothing about this install.";
  const OFF = "The daily release check is off (Settings › Updates & backups): a click asks once.";
  const FRESH_MS = 15000;   // a click's answer outranks an older status for this long (a summary asked mid-check)

  // --- pure parts (portal/tests/js/updatecheck.test.mjs) ---
  // checked ISO -> "just now" / "12 min ago" / "3 h ago" / "yesterday" / "4 days ago" (app.js checked(), with a clock)
  function ago(iso, now) {
    const t = Date.parse(iso);
    if (isNaN(t)) return "";
    const ms = now - t;
    if (ms < 90000) return "just now";
    if (ms < 3600000) return `${Math.round(ms / 60000)} min ago`;
    if (ms < 86400000) return `${Math.round(ms / 3600000)} h ago`;
    const days = Math.floor(ms / 86400000);
    return days === 1 ? "yesterday" : `${days} days ago`;
  }
  // a time ahead -> "14:05" today, else "Oct 19, 14:05" (this browser's clock and language)
  function clock(iso, now) {
    const d = new Date(iso);
    if (isNaN(d)) return "";
    const t = d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    return d.toDateString() === new Date(now).toDateString() ? t : `${d.toLocaleDateString(undefined, { month: "short", day: "numeric" })}, ${t}`;
  }
  const RELEASE = /^v\d{1,4}\.\d{1,4}\.\d{1,4}$/;

  // What the line says. U: /api/summary's update (null before it loaded); BUSY: a click is waiting for its answer;
  // NOTE: what the last click's answer said besides U ({kind: "again" | "hourly" | "failed", until (ms), wait (s), at
  // (ISO), base: statusKey of the status it answered}) — said as it was answered (no countdown: the line is announced,
  // and once is enough), until UNTIL, and only while U is still that status: a new one (another device's check, the
  // daily one) is said instead.
  // -> {state, text (announced), link (a release tag: "Update available — <tag>" leads to Home's card), when, why (the
  // reason, shown under About this check: visible text, for touch and keyboard too), disabled (the button waits)}
  function describe(u, now, busy, note) {
    const off = u && u.enabled === false;
    const out = { state: "", text: "", link: "", when: "", why: "", disabled: false };
    const said = (o) => ({ ...o, why: [o.why, off && o.state !== "off" ? OFF : "", PRIVACY].filter(Boolean).join(" ") });
    if (busy || (u && u.checking)) return said({ ...out, state: "checking", text: "Checking for updates…", why: "GitHub is being asked now.", disabled: true });
    const n = note && note.until > now && (note.base === undefined || note.base === statusKey(u)) ? note : null;
    if (n && n.kind === "failed") return said({ ...out, state: "failed", text: "The portal could not be reached — try again", why: "The portal did not answer the click." });
    if (n && n.kind === "hourly") {
      return said({ ...out, state: "hourly", text: `Checked many times this hour — try again after ${clock(n.at, now)}`,
        why: "The portal asks GitHub at most 20 times an hour for these clicks.", disabled: true });
    }
    if (!u) return said(out);
    const when = u.checked_at ? `checked ${ago(u.checked_at, now)}` : "";
    const latest = RELEASE.test(u.latest || "") ? u.latest : "";
    if (n && n.kind === "again") {
      return said({ ...out, state: "again", text: `Checked a moment ago — try again in ${Math.max(1, Math.round(Number(n.wait) || 30))} s`,
        why: "The portal asks GitHub at most every 30 seconds for these clicks." });
    }
    const at = u.retry_at && Date.parse(u.retry_at) > now ? clock(u.retry_at, now) : "";
    if (u.error && u.limited) {
      const why = "GitHub answers 60 requests an hour from one address without an account, and refused the last check for that.";
      if (at) return said({ ...out, state: "limit", text: `GitHub's limit for this hour — try again after ${at}`, when, why, disabled: true });
      return said({ ...out, state: "error", text: "GitHub's limit for this hour was reached — try again now", when, why });
    }
    if (u.error && u.refused) {
      const why = `GitHub refused the last check (${u.error}), so the portal waits up to an hour before it asks again.`;
      if (at) return said({ ...out, state: "refused", text: `GitHub refused the request — try again after ${at}`, when, why, disabled: true });
      return said({ ...out, state: "error", text: "GitHub refused the last request — try again now", when, why });
    }
    if (u.error) return said({ ...out, state: "error", text: "GitHub could not be reached — try again later", when, why: `The last check failed: ${u.error}.` });
    if (u.available && latest) return said({ ...out, state: "available", link: latest, when, why: `${latest} is out; this install is ${u.installed || "older"}.` });
    if (latest && u.installed) return said({ ...out, state: "current", text: "Up to date", when, why: `${latest} is the newest release, and this install has it.` });
    if (latest) return said({ ...out, state: "newest", text: `Newest release: ${latest}`, when, why: "This install's version is not a release, so it is not compared." });
    return said({ ...out, state: off ? "off" : "none", text: off ? "Daily release check is off" : "Not checked yet", why: off ? OFF : "No check has run yet." });
  }

  // which status a click's note was about: its check (time, error, newest release)
  function statusKey(u) {
    return u && typeof u === "object" ? `${u.checked_at || ""}|${u.error || ""}|${u.latest || ""}` : "";
  }

  // A summary asked for while a click's check ran can land after the click's answer: within FRESH_MS of that answer
  // (ANSWERED: {u, at}), a status from before it (an older check, or none) is replaced by it — only then, so a clock set
  // back never pins an old answer for good.
  function fresher(u, answered, now) {
    if (!answered || !u || typeof u !== "object" || now - answered.at > FRESH_MS) return u;
    const ta = Date.parse(u.checked_at), tb = Date.parse(answered.u.checked_at);
    return !isNaN(tb) && !(ta >= tb) ? answered.u : u;
  }

  // Home's update card, a line about the release the helper prepares ahead (lib/prepare.sh; the heartbeat's "prepare" as
  // /api/admin/status gives it, LATEST the release the check names). "" says nothing: preparing is off, nothing is newer,
  // or the record is about a release that is no longer the newest.
  function prepareLine(p, latest) {
    if (!p || typeof p !== "object" || !p.supported || p.enabled === false || !p.state) return "";
    const v = typeof p.version === "string" ? p.version : "";
    if (!/^v\d+\.\d+\.\d+$/.test(v) || (latest && latest !== v)) return "";
    const step = typeof p.step === "string" ? p.step.replace(/^Prepare: /, "") : "";
    const why = typeof p.reason === "string" ? p.reason.replace(/[\s.]+$/, "") : "";
    switch (p.state) {
      case "ready": return `Ready: ${v} is downloaded and built. Update now takes a minute or two.`;
      case "preparing": return `Preparing ${v} in the background${step ? `: ${step}` : ""}. Nothing changes on your install until you update.`;
      case "failed": return `Preparing ${v} failed${why ? `: ${why}` : ""}. Update now still works; it does that work itself.`;
      // (no step: it has not started, as when the computer is busy)
      case "yielded": return step ? `Preparing ${v} is paused${why ? ` (${why})` : ""}. It goes on by itself; Update now also does it.`
        : `Preparing ${v} has not started${why ? ` (${why})` : ""}. It starts by itself; Update now also does it.`;
      default: return "";
    }
  }
  // Update now's own steps: the job's step list shows a "Prepare" stage only for an update that prepared first
  function preparedFirst(job) {
    if (!job || job.action !== "update") return false;
    return job.phase === "preparing" || (Array.isArray(job.steps) ? job.steps : []).some((x) => x && /^Prepare: /.test(x.label || "")) || /^Prepare: /.test(job.step || "");
  }


  // --- an update's progress bar (JON-978; lib/plan.sh has the same arithmetic for a terminal's) ---
  // The plan is the steps the last update took, with their seconds ({label, secs}: job.plan). The steps the job has done are
  // matched to it by label without the trailing parenthesised part ("Services (9) (http://…)" is "Services"); a step the plan
  // does not have counts as it comes. Left = what the plan expects of the steps not seen yet, plus for the running one what it
  // expects less the time it has run, but never under MIN_LEFT_S: a step that runs long keeps the bar short of done.
  const MIN_LEFT_S = 5;
  const normLabel = (l) => { const t = String(l || ""); const i = t.indexOf(" ("); return i < 0 ? t : t.slice(0, i); };
  // 3 -> "a few seconds", 40 -> "less than a minute", 95 -> "about 2 minutes"; short: "~2 min"
  function leftWords(s) {
    if (s < 15) return { long: "a few seconds left", short: "a few seconds left" };
    if (s < 60) return { long: "less than a minute left", short: "under a minute left" };
    const m = Math.round(s / 60);
    return { long: `about ${m} ${m === 1 ? "minute" : "minutes"} left`, short: `~${m} min left` };
  }
  // progress(job, nowS) -> null (no bar), else {done, total, stepNo, label, left, pct, finished, valuenow, valuemax, valuetext,
  // text, todo: [{label, secs}]}. nowS: the server's clock when the status was read (a terminal's record is written once a step).
  function progress(job, nowS) {
    if (!job || job.action !== "update") return null;
    const plan = Array.isArray(job.plan) ? job.plan : [], steps = (Array.isArray(job.steps) ? job.steps : []).filter((x) => x && typeof x === "object");
    if (!plan.length && !steps.length && !job.step) return null;
    const pl = plan.filter((p) => p && typeof p.label === "string").map((p) => ({ label: normLabel(p.label), secs: p.secs > 0 ? p.secs : 0, used: false }));
    const find = (l) => pl.find((p) => !p.used && p.label === l);
    let extra = 0;
    for (const x of steps) { const p = find(normLabel(x && x.label)); if (p) p.used = true; else extra++; }
    const finished = job.phase === "done";
    const running = finished ? "" : normLabel(job.step);
    let total = pl.length + extra, expected = 0;
    if (running) { const p = find(running); if (p) { p.used = true; expected = p.secs; } else total++; }
    const now = Number.isFinite(nowS) ? nowS : job.updated_at;
    const elapsed = running && job.step_started_at && now ? Math.max(0, now - job.step_started_at) : 0;
    let left = running ? Math.max(expected - elapsed, MIN_LEFT_S) : 0;
    const todo = pl.filter((p) => !p.used);
    for (const p of todo) left += p.secs;
    const done = steps.length;
    total = finished && done ? done : Math.max(total, done);   // (finished: the steps it took; a plan step it never reached is no step)
    const stepNo = finished ? total : running ? done + 1 : done;
    const frac = running && expected > 0 ? Math.min(0.9, elapsed / expected) : 0;
    const pct = finished ? 100 : Math.min(99, Math.floor(((done + frac) / Math.max(total, 1)) * 100));
    const last = steps.length ? normLabel(steps[steps.length - 1].label) : "";
    const label = running || last;
    const words = leftWords(left), n = (c) => `${c} ${c === 1 ? "step" : "steps"}`;
    const valuetext = finished ? `Done, ${n(total)}` : stepNo ? `Step ${stepNo} of ${total}, ${label}, ${words.long}` : `Starting, ${n(total)}, ${words.long}`;
    const text = finished ? `Done · ${n(total)}` : `${stepNo ? `Step ${stepNo} of ${total} · ${label}` : n(total)} · ${words.short}`;
    return { done, total, stepNo, label, left, pct, finished, valuenow: stepNo, valuemax: Math.max(total, 1), valuetext, text, todo: todo.map(({ label: l, secs }) => ({ label: l, secs })) };
  }
  // announce(prevKey, p, jobId) -> {key, say}: the bar's words for a screen reader's polite live region, once for each step
  function announce(prevKey, p, jobId) {
    if (!p) return { key: "", say: "" };
    const key = `${jobId || ""}:${p.finished ? "done" : p.stepNo}`;
    return { key, say: key === prevKey ? "" : p.valuetext };
  }

  // stepItem(step) -> {cls, text}: one finished step on Home's card; the one a failed job stopped in is marked failed (JON-996)
  function stepItem(x) {
    const took = x && x.took ? x.took : "", label = (x && x.label) || "";
    if (x && x.failed === true) return { cls: "failed", text: `${label}${took ? ` · ${took}` : ""} · failed` };
    if (took === "skipped") return { cls: "skipped", text: `${label} · skipped${x.why ? ` (${x.why})` : ""}` };
    return { cls: "", text: took ? `${label} · ${took}` : label };
  }
  // --- an update that moved the code and did not finish (the heartbeat's rollback.unfinished; JON-996) ---
  // The helper's update action finishes it (./stack update's finishing path: the images and setup, no new backup); it does
  // not install a newer release, so while it is unfinished the update card's Update now would only finish it too.
  // finishMode(a, onJob) -> "" (the update card as usual) | "job" (the failed update's card offers Finish the update and
  // Roll back: onJob; the update card stays hidden) | "card" (that card was dismissed: the update card offers them instead)
  function finishMode(a, onJob) {
    const rb = a && a.rollback;
    if (!rb || !rb.available || !rb.unfinished || a.in_progress) return "";
    return onJob ? "job" : "card";
  }
  // finishCard(a, u) -> the update card's words for Finish the update: {title, meta, steps}; u: the release check
  // (/api/summary's update), for a release newer than the code in place
  function finishCard(a, u) {
    const rb = (a && a.rollback) || {}, v = (a && a.version) || "the new version";
    const steps = ["The steps it did not finish run again: the images, then setup, which restarts the services and checks them.",
      `No new backup: Roll back still goes back to ${rb.to || "the previous version"} with ${rb.backup || "the backup taken before the update"}.`];
    if (u && u.available && u.latest) steps.push(`Then Update now installs ${u.latest}.`);
    return { title: "The last update did not finish", meta: `You have ${v}'s code; the update${rb.to ? ` from ${rb.to}` : ""} did not finish.`, steps };
  }
  // finishConfirm(a) -> the confirmation's words (app.js adds what else the restart ends)
  function finishConfirm(a) {
    const rb = (a && a.rollback) || {};
    return `Finish the update to ${(a && a.version) || "the new version"}: the steps it did not finish run again (the images, then setup), with no new backup, so Roll back still goes back to ${rb.to || "the previous version"}. Chat, Admin and Files may be down for a minute or two while the services restart.`;
  }
  root.bnUpdateCheck = { _pure: { stepItem, describe, ago, clock, fresher, statusKey, prepareLine, preparedFirst, progress, announce, leftWords, normLabel,
    finishMode, finishCard, finishConfirm } };
  if (typeof document === "undefined") return;

  let last = null;          // the last update status seen (Home's summary, or a click's answer)
  let busy = false;         // a click waits for its answer
  let note = null;          // what that answer said besides the status (see describe)
  let following = false;    // a click's check still runs: Home's summary is asked for every 2 s until it ends
  let answered = null;      // {u, at}: when a click's check ended, and what it said (see fresher)
  let followT = null, noteT = null, seq = 0;
  const REDUCED = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : { matches: true };

  // one line: <div class="release-line"> with its parts, made once (the button keeps the focus across redraws)
  function parts(p) {
    if (p._rl) return p._rl;
    const state = el("span", { class: "rl-state", "aria-live": "polite" });
    const sep1 = el("span", { class: "rl-sep", "aria-hidden": "true", text: "·" });
    const when = el("span", { class: "rl-when" });
    const sep2 = el("span", { class: "rl-sep", "aria-hidden": "true", text: "·" });
    const why = el("span", { class: "rl-why", id: `rl-why-${++seq}` });
    // (aria-disabled, not disabled: a focused button keeps the focus while it waits, and hears the result; its
    // description is the reason and that nothing about this install is sent)
    const btn = el("button", { type: "button", class: "linkish rl-check", text: "Check for updates", "aria-describedby": why.id });
    btn.addEventListener("click", () => { if (btn.getAttribute("aria-disabled") !== "true") run(); });
    const more = el("details", { class: "rl-more" }, el("summary", {}, "About this check"), why);
    // (a separator wraps to the next line with what follows it, never alone at the end of one)
    p.replaceChildren(state, el("span", { class: "rl-part" }, sep1, when), el("span", { class: "rl-part" }, sep2, btn), more);
    p._rl = { state, sep1, when, sep2, btn, why, key: "" };
    return p._rl;
  }
  function drawLine(p, d) {
    const r = parts(p);
    p.dataset.state = d.state || "none";
    // the live part changes only when what it says does (no announcement every 30 s)
    const key = `${d.state}|${d.text}|${d.link}`;
    if (r.key !== key) {
      r.key = key;
      const kids = [];
      if (d.state === "checking") kids.push(el("span", { class: "spinner", "aria-hidden": "true" }));
      if (d.link) {
        const a = el("a", { href: "#home", class: "rl-link", text: `Update available — ${d.link}` });
        a.addEventListener("click", (e) => { e.preventDefault(); toCard(); });
        kids.push(a);
      } else if (d.text) kids.push(d.text);
      r.state.replaceChildren(...kids);
    }
    r.when.textContent = d.when;
    r.sep1.hidden = !d.when || !(d.text || d.link);
    r.sep2.hidden = !(d.text || d.link || d.when);
    if (d.disabled) r.btn.setAttribute("aria-disabled", "true"); else r.btn.removeAttribute("aria-disabled");
    r.why.textContent = d.why;
    r.btn.title = d.why;
    p.hidden = false;
  }
  const now = () => describe(last, Date.now(), busy, note);
  function draw() {
    const d = now();
    for (const p of document.querySelectorAll(".release-line")) drawLine(p, d);
  }
  // Home's update card, once app.js has shown it (renderUpdate draws this line before the card)
  function scrollCard() {
    requestAnimationFrame(() => {
      const card = $("#update-card");
      if (card && !card.hidden && window.bnWidgets && window.bnWidgets.peek) window.bnWidgets.peek("update-card");   // (widgets.js: one the person hid shows for now)
      if (card && !card.hidden) card.scrollIntoView({ block: "start", behavior: REDUCED.matches ? "auto" : "smooth" });
    });
  }
  function toCard() { showTab("home"); scrollCard(); }

  // app.js renderUpdate(u): every new status (Home's summary every 30 s, and a click's answer), after fresher()
  function render(u) {
    if (u && typeof u === "object") last = u;
    clearTimeout(followT);
    if (following && last && last.checking) followT = setTimeout(refresh, 2000);
    else if (following) {
      following = false;
      answered = { u: last, at: Date.now() };
      if (last && last.available && !$("#home").hidden) scrollCard();   // what the click found: the card, as on any visit
    }
    draw();
  }

  // the line's button, the ⌘K entry: ask now. The answer is the new status (or when to try again).
  async function run(opts = {}) {
    if (opts.home) {   // (the ⌘K entry: Home, and the focus on its line's button, which announces the result)
      showTab("home");
      const b = $("#home .release-line .rl-check");
      if (b) { try { b.focus({ preventScroll: false }); } catch (_) { /* fine */ } }
      // the button waits (GitHub's limit, a refusal, the clicks' hourly cap, a check running): say why, ask nothing
      const d = now();
      if (d.disabled) { if (typeof toast === "function") toast(d.text); return; }
    }
    if (busy || (last && last.checking)) return;
    busy = true; note = null;
    draw();
    let r = null, d = {};
    try {
      r = await fetch("/api/update/check", { method: "POST", credentials: "same-origin", cache: "no-store",
        headers: { "X-Requested-With": "devos-ade" } });
      d = await r.json().catch(() => ({}));
    } catch (_) { r = null; }
    busy = false;
    if (r && r.status === 401) { location.assign("/login"); return; }
    const wait = Math.min(3600, Math.max(1, Number(d.retry_after) || 30));
    const u = d && d.update && typeof d.update === "object" ? d.update : null;
    const base = statusKey(u || last);
    if (!r || (!r.ok && r.status !== 429)) note = { kind: "failed", until: Date.now() + 60000, base };
    else if (r.status === 429 && d.reason === "again") note = { kind: "again", wait, until: Date.now() + wait * 1000, base };
    else if (r.status === 429 && d.reason === "hourly") {
      note = { kind: "hourly", wait, until: Date.now() + wait * 1000, at: new Date(Date.now() + wait * 1000).toISOString(), base };
    }
    if (note) { clearTimeout(noteT); noteT = setTimeout(draw, note.until - Date.now() + 50); }
    following = Boolean(r && r.ok);
    if (following && u && !u.checking) answered = { u, at: Date.now() };
    if (u && typeof renderUpdate === "function") renderUpdate(u);   // the card, the version label and this line
    else render(u);
  }

  // Settings' Daily release check row (settings.js): a line of its own, drawn at once from what Home last saw
  function line(where) {
    const p = el("div", { class: `release-line${where === "settings" ? " note set-extra" : ""}`, "data-where": where || "" });
    drawLine(p, now());
    return p;
  }

  Object.assign(root.bnUpdateCheck, { run, render, line, fresher: (u) => fresher(u, answered, Date.now()) });
  document.addEventListener("DOMContentLoaded", draw);
  setInterval(() => { if (!document.hidden) draw(); }, 60000);   // "checked 12 min ago" stays true
})(typeof window !== "undefined" ? window : globalThis);
