// The optional Code page (./stack code): the Code tab — in the sidebar directly under Chat on a big screen, in the
// bottom tab bar on a phone (Home · Chat · Code · More) — its badge (permission prompts waiting), and a line on Home's
// Claude Code card. Loaded after app.js and mobile.js (deferred; shares their $, el, appUrl and APP_URLS) and adds its
// elements before DOMContentLoaded, so app.js binds the tab like the others. The tab frames code.<host> like any app:
// while the Code page is locked, that host answers with its own "Unlock the Code page" form (the portal password
// again). In a browser that has used the Code page (its page reported to the portal once), the frame is made (hidden)
// once the portal is idle, so the badge counts prompts before the tab is opened — on a phone too: the badge and
// Activity's needs-you banner are how you learn a session waits; a browser that never opened it loads nothing from the
// code host. Shown again on a phone, the page is told so ({type: "bn-portal-shown"}: it shows the session that waits for
// you, its card in view); a session named here (Home's Continue row, Activity, search, the portal's #code/<id> — a
// notification's address) is shown in place ({type: "bn-portal-session", id}) once the page runs, else by its deep link.
// What the framed page reports (the sessions that need you, those open: titles are sandbox data, text only, capped)
// goes to Home's Continue row (home.js, bn:code-status), Activity and the search; the ways in are deep links
// (?session=, ?new=1&project=, ?git=, ?setup=; ?prompt= — a draft the Code page marks as coming from a link, never sent
// by itself).
// The tab is there while the Code page is off on this site too (turned off, or not allowed over remote access): muted,
// with an "off" pill, it then shows a page of the portal's own — what the Code page is, what turning it on does and how —
// with no frame, no badge and nothing loaded from the code host.
"use strict";

(() => {
  const state = (() => {
    try { return JSON.parse(document.querySelector('meta[name="bn-code"]').content) || {}; } catch (_) { return {}; }
  })();
  const here = Boolean(state.here && APP_URLS.code);
  const NS = "http://www.w3.org/2000/svg";
  const icon = (d) => {
    const s = document.createElementNS(NS, "svg"), p = document.createElementNS(NS, "path");
    s.setAttribute("viewBox", "0 0 20 20"); s.setAttribute("aria-hidden", "true"); p.setAttribute("d", d); s.append(p);
    return s;
  };
  const BRACKETS = "M7.5 5.5 3 10l4.5 4.5M12.5 5.5 17 10l-4.5 4.5M11 4l-2 12";
  const POPOUT = "M11 4h5v5M16 4l-7 7M14 12v4H4V6h4";
  let badge = null;
  // set the first time the Code page's own page (unlocked, running) reports to the portal; kept in this browser
  const USED = "bn.code.used";
  const used = () => { try { return localStorage.getItem(USED) === "1"; } catch (_) { return false; } };
  const markUsed = () => { try { if (!used()) localStorage.setItem(USED, "1"); } catch (_) { /* storage blocked: fine */ } };

  // Sidebar: directly under Chat, with a pop-out like the other apps and a badge for permission prompts waiting — or,
  // while the Code page is off here, muted with an "off" pill (no pop-out, no badge: its page is the portal's own).
  function addTab() {
    const chat = $(".tabs .tab[data-tab=chat]");
    const after = chat ? chat.closest("li") : null;
    if (!after) return;
    if (!here) {
      after.after(el("li", { class: "code-item off" },
        el("button", { type: "button", class: "tab", "data-tab": "code", "data-label": "Code (off)" }, icon(BRACKETS), "Code",
          el("span", { class: "tab-off", text: "off" }))));
      return;
    }
    badge = el("span", { class: "tab-badge", "aria-label": "permission prompts waiting", hidden: "" });
    after.after(el("li", { class: "code-item" },
      el("button", { type: "button", class: "tab", "data-tab": "code" }, icon(BRACKETS), "Code", badge),
      el("a", { class: "popout", "data-app": "code", href: appUrl("code"), target: "_blank", rel: "noopener",
        title: "Open Code in its own window", "aria-label": "Open Code in its own window" }, icon(POPOUT))));
  }

  // --- deep links into the Code page ---
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const STATES = { waiting: "needs you", working: "working", idle: "idle" };
  let reported = null;   // {waiting, sessions} from the framed page; null until it reports
  // linkTo({session, prompt, new, project}) -> the Code page's address with that deep link
  function linkTo(params) {
    const u = new URL(appUrl("code"));
    for (const [k, v] of Object.entries(params)) if (v) u.searchParams.set(k, v);
    return u.href;
  }
  // the Code tab at a deep link — a session of a page that runs (it reported since it loaded) in place, asked by a
  // message to the code host's origin only (no reload: no unlock again, no unsaved edit lost); anything else by the
  // frame loading the address (the page reads it once and takes it out of its address; kept through the unlock)
  function openLink(params) {
    showTab("code");
    const f = document.querySelector('#frames iframe[data-app="code"]');
    const only = Object.keys(params).filter((k) => params[k]);
    if (f && window.bnCode.ready() && only.length === 1 && only[0] === "session" && UUID.test(params.session)) {
      try { f.contentWindow.postMessage({ type: "bn-portal-session", id: params.session }, new URL(appUrl("code")).origin); return; } catch (_) { /* below */ }
    }
    appFrame("code").src = linkTo(params);
  }
  // the framed page's Git hosts uses (its Git panel: your pushes and pulls, Claude's own git or gh getting a
  // credential), checked: ids, times, a few words each, at most 10 — shown as text by Activity
  const GIT_ACTIONS = ["fetch", "pull", "push", "publish", "clone", "test", "credential", "ssh-login", "gh", "claude"];
  function takeGit(v) {
    if (!Array.isArray(v)) return [];
    return v.slice(0, 10).filter((x) => x && typeof x.id === "string" && /^[0-9a-f]{12}$/.test(x.id) && Number.isFinite(x.at) && x.at > 0 && GIT_ACTIONS.includes(x.action))
      .map((x) => ({ id: x.id, at: Math.floor(x.at), who: x.who === "claude" ? "claude" : "you", action: x.action, ok: x.ok !== false,
        host: typeof x.host === "string" ? shownTitle(x.host).slice(0, 60) : "", target: typeof x.target === "string" ? shownTitle(x.target) : "" }));
  }
  // the framed page's list, checked: ids, states, short titles, at most 8
  function takeSessions(v) {
    if (!Array.isArray(v)) return [];
    return v.slice(0, 8).filter((x) => x && typeof x.id === "string" && UUID.test(x.id) && Object.prototype.hasOwnProperty.call(STATES, x.state))
      .map((x) => ({ id: x.id, state: x.state, title: typeof x.title === "string" ? shownTitle(x.title) : "" }));
  }
  // A title as the Code page shows it: at most 120 characters, line breaks and tabs as spaces, other control
  // characters and the invisible or direction-changing ones ("Trojan Source": bidi overrides and isolates, zero-width
  // characters, tag characters) shown as ⟨U+202E⟩ — so "notes⟨U+202E⟩fdp.exe" cannot pass for another name.
  const INVISIBLE = /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff\u{e0000}-\u{e007f}]/gu;
  function shownTitle(t) {
    return Array.from(t.slice(0, 240)).slice(0, 120).join("").replace(/[\t\n\r]/g, " ")
      .replace(INVISIBLE, (c) => `⟨U+${c.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")}⟩`);
  }

  // The framed page says how many permission prompts wait ({type: "bn-code-status", pending: N, busy, bypass, waiting,
  // sessions}); only the code host may. bypass: a session runs without
  // asking (Bypass permissions) — the badge turns red and says ⏵⏵ (the CLI's marker) while nothing waits.
  // the Settings place of each greyed item the Code page has (catalog/setup-links.tsv: portal/tests/test_code.py
  // checks each against it)
  const CODE_SETUP = Object.freeze({ "tool-left-out": "TERMINAL_AI_TOOLS", "claude-plan-off": "CODE_CLAUDE_PLAN", "auto-off": "CODE_AUTO_MODE",
    "bypass-off": "CODE_ALLOW_BYPASS", "models-scope": "CODE_MODELS", "terminal-remote-off": "REMOTE_TERMINAL", "remote-preview": "REMOTE_PREVIEW",
    "folder-read-only": "+project-folders", "openrouter-off": "OPENROUTER_API_KEY", "explabs-off": "EXPLABS_API_KEY",
    "websearch-off": "WEBSEARCH_BACKEND" });
  function listen() {
    let codeOrigin = "";
    try { codeOrigin = new URL(appUrl("code")).origin; } catch (_) { return; }
    // (and only from the Code tab's own frame: another window of the code host — a pop-out, a page it opened — says
    // nothing here)
    const codeFrame = () => document.querySelector('#frames iframe[data-app="code"]');
    window.addEventListener("message", (e) => {
      const f = codeFrame();
      if (e.origin !== codeOrigin || !f || e.source !== f.contentWindow || !e.data || e.data.type !== "bn-code-status" || !badge) return;
      markUsed();
      const n = Number.isInteger(e.data.pending) && e.data.pending > 0 ? Math.min(e.data.pending, 99) : 0;
      const bypass = e.data.bypass === true;
      badge.textContent = n ? String(n) : bypass ? "⏵⏵" : "";
      badge.hidden = !n && !bypass;
      badge.classList.toggle("bypass", bypass);
      badge.title = bypass ? "A Code session runs without asking (Bypass permissions)" : "";
      document.title = n ? `(${n}) DevOS ADE` : "DevOS ADE";
      reported = { waiting: Number.isInteger(e.data.waiting) && e.data.waiting > 0 ? Math.min(e.data.waiting, 99) : 0, sessions: takeSessions(e.data.sessions), git: takeGit(e.data.git),
        // how many Git hosts are connected (a number only; the walkthrough's "Connect a git host" step), null: not known
        hosts: Number.isInteger(e.data.hosts) && e.data.hosts >= 0 ? Math.min(e.data.hosts, 99) : null };
      // the frame reported since it (re)loaded: the global search may ask it (search.js); a reload (a deep link, the
      // unlock ending) waits for its next report
      if (!hooked.has(f)) { hooked.add(f); f.addEventListener("load", () => { loadedAt = Date.now(); }); }
      reportedAt = Date.now();
      // Home's Continue row (home.js) and Activity (activity.js): the sessions that wait for you, those open — checked
      document.dispatchEvent(new CustomEvent("bn:code-status", { detail: { waiting: reported.waiting, sessions: reported.sessions.map((x) => ({ ...x })), git: reported.git.map((x) => ({ ...x })), hosts: reported.hosts } }));
    });
    // A greyed item of the Code page chosen ({type: "bn-code-setup", reason}: catalog/setup-links.tsv — its Who
    // answers, terminal panel, modes, previews, folders): Settings where that is turned on (settings.js goTo), from the
    // same frame only — the place looked up here (CODE_SETUP), never one the frame names
    window.addEventListener("message", (e) => {
      const f = codeFrame();
      if (e.origin !== codeOrigin || !f || e.source !== f.contentWindow || !e.data) return;
      // "More models…" (and JON-521's "pick another model"): the model browser, optionally at one provider's card
      if (e.data.type === "bn-code-models") {
        const prov = e.data.provider;
        const hash = `#modelbrowser${typeof prov === "string" && /^(bedrock|openrouter|explabs|local|server|add)$/.test(prov) ? `/${prov}` : ""}`;
        if (location.hash === hash && typeof window.showTab === "function") window.showTab(hash.slice(1));
        else location.hash = hash;
        return;
      }
      if (e.data.type !== "bn-code-setup") return;
      const reason = e.data.reason;
      if (typeof reason !== "string" || !Object.hasOwn(CODE_SETUP, reason)) return;
      const hash = `#settings/${CODE_SETUP[reason]}`;
      if (location.hash === hash && typeof window.showTab === "function") window.showTab(hash.slice(1));
      else location.hash = hash;
    });
    // Export to Files ({type: "bn-code-export", id, name, blob}: a project's zip, built and downloaded by the Code page): the
    // portal writes it into Files (POST /api/code-export, codeexport.py: the Code page cannot reach Files itself), and says
    // how it went ({type: "bn-portal-export", id, ok, key?, url?, error?}) — from the same frame only, to its origin only, a
    // name and size of the shapes the route takes (it checks them all again)
    const EXPORT_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,115}\.zip$/, EXPORT_MAX = 220 * 1024 * 1024;
    window.addEventListener("message", async (e) => {
      const f = codeFrame();
      if (e.origin !== codeOrigin || !f || e.source !== f.contentWindow || !e.data || e.data.type !== "bn-code-export") return;
      const d = e.data;
      if (typeof d.id !== "string" || !/^[A-Za-z0-9]{1,32}$/.test(d.id)) return;
      const reply = (m) => { try { f.contentWindow.postMessage({ type: "bn-portal-export", id: d.id, ...m }, codeOrigin); } catch (_) { /* gone */ } };
      if (!(d.blob instanceof Blob) || typeof d.name !== "string" || !EXPORT_NAME.test(d.name) || d.blob.size > EXPORT_MAX) { reply({ ok: false, error: "that is not a zip an export can take" }); return; }
      try {
        const r = await fetch(`/api/code-export?name=${encodeURIComponent(d.name)}`, { method: "POST", headers: { "X-Requested-With": "devos-ade" }, body: d.blob, credentials: "same-origin" });
        let j = {};
        try { j = await r.json(); } catch (_) { /* not JSON */ }
        if (!r.ok || !j.ok) { reply({ ok: false, error: String(j.error || `Files answered HTTP ${r.status}`).slice(0, 300) }); return; }
        let url = "";
        try { url = `${new URL(appUrl("files")).origin}/rustfs/console/browser/${encodeURIComponent(String(j.bucket))}`; } catch (_) { /* none */ }
        reply({ ok: true, key: String(j.key), bucket: String(j.bucket), url });
      } catch (_) {
        reply({ ok: false, error: "the portal did not answer" });
      }
    });
  }
  const hooked = new WeakSet();
  let reportedAt = 0, loadedAt = 0;

  // For the global search (search.js) and Activity: what Home's card knows, whether the frame can be asked, and the two
  // ways into the Code page from there — a session by deep link (as Resume), a workspace file by a message to the frame
  // (the Code page checks the path itself, and opens it only as a file of its workspace)
  window.bnCode = {
    ready: () => Boolean(reported) && reportedAt > loadedAt && Boolean(document.querySelector('#frames iframe[data-app="code"]')),
    sessions: () => (reported ? reported.sessions.map((x) => ({ id: x.id, title: x.title, state: x.state })) : []),
    openSession: (id) => { if (typeof id === "string" && UUID.test(id)) openLink({ session: id }); },
    // Home's New session: the start of a new one (no earlier session shown), in that project of the page's list
    newSession: (project) => openLink({ new: "1", project: typeof project === "string" && /^(ws|p_[0-9a-f]{8})$/.test(project) ? project : "" }),
    // Settings › Claude Code › Git hosts, an Activity item of one, the walkthrough: the Code page's Git hosts — and its
    // Clone dialog (the walkthrough; empty: nothing is cloned by a link)
    openGitHosts: () => openGit("hosts"),
    openClone: () => openGit("clone"),
    // Settings › Claude Code › Bring your setup: the Code page's sheet (it reads nothing by itself)
    openSetup: () => openLink({ setup: "1" }),
    // how many Git hosts the Code page last said are connected, or null (it has not said: not loaded in this browser)
    gitHosts: () => (reported && Number.isInteger(reported.hosts) ? reported.hosts : null),
    // how many of its sessions have a turn running now (Settings › Claude Code › Project folders: what a restart ends),
    // or null (not known: the Code page has not reported in this browser)
    working: () => (reported ? reported.sessions.filter((x) => x.state === "working").length : null),
    openFile: (path) => {
      const f = document.querySelector('#frames iframe[data-app="code"]');
      let origin = "";
      try { origin = new URL(appUrl("code")).origin; } catch (_) { return; }
      if (!f || typeof path !== "string" || !path || path.length > 1024) return;
      showTab("code");
      f.contentWindow.postMessage({ type: "bn-portal-open", path }, origin);
    },
    // Home's item menu (JON-821): one of the Code page's own actions on a session, asked of the framed page (it checks the id,
    // runs its own flow and dialogs — a delete is confirmed there). Rename and archive stay on Home; the rest show the tab.
    // True when the message was sent.
    sessionDo: (id, action, title) => {
      const f = document.querySelector('#frames iframe[data-app="code"]');
      let origin = "";
      try { origin = new URL(appUrl("code")).origin; } catch (_) { return false; }
      if (!f || !window.bnCode.ready() || typeof id !== "string" || !UUID.test(id)) return false;
      if (!["rename", "archive", "unarchive", "fork", "file", "delete", "terminal"].includes(action)) return false;
      if (!["rename", "archive", "unarchive"].includes(action)) showTab("code");
      f.contentWindow.postMessage({ type: "bn-portal-session-do", id, action, ...(action === "rename" ? { title: String(title || "").slice(0, 200) } : {}) }, origin);
      return true;
    },
  };

  // The Git panel's Git hosts or Clone dialog. A Code tab whose page is running (it reported since it loaded) is asked
  // in place — {type: "bn-portal-git", dialog}, to the code host's origin only; the page takes it only from the portal
  // it was told about and from window.parent (portalbridge.ts) — so it is not reloaded and no unsaved edit is lost.
  // Otherwise (not loaded yet, locked) its address with ?git= (a deep link, kept through the unlock).
  function openGit(dialog) {
    const f = document.querySelector('#frames iframe[data-app="code"]');
    let origin = "";
    try { origin = new URL(appUrl("code")).origin; } catch (_) { return; }
    if (f && window.bnCode.ready()) {
      showTab("code");
      f.contentWindow.postMessage({ type: "bn-portal-git", dialog }, origin);
      return;
    }
    openLink({ git: dialog });
  }

  // The badge needs the page running: its frame, hidden, once the portal has nothing else to do — only in a browser
  // that has used the Code page (else the code host would answer its locked form, unasked). On a phone too: the tab's
  // badge and Activity's needs-you banner are how you learn that a session waits for you there.
  function preload() {
    if (!used()) return;
    const make = () => appFrame("code");
    if ("requestIdleCallback" in window) window.requestIdleCallback(make, { timeout: 5000 });
    else setTimeout(make, 2000);
  }

  // The Code tab shown again on a phone: the page is told ({type: "bn-portal-shown"}), and shows the session that waits
  // for you with its card in view (no sheet over it) — the tab's badge said one does. The portal's #code/<id> (a
  // notification's address, a link): that session, in place once the page runs.
  function routes() {
    let origin = "";
    try { origin = new URL(appUrl("code")).origin; } catch (_) { return; }
    document.addEventListener("bn:tab", (e) => {
      if (e.detail !== "code" || !window.matchMedia("(max-width: 767.98px)").matches || !window.bnCode.ready()) return;
      const f = document.querySelector('#frames iframe[data-app="code"]');
      if (f) f.contentWindow.postMessage({ type: "bn-portal-shown" }, origin);
    });
    document.addEventListener("bn:place", (e) => {
      const d = e.detail || {};
      if (d.tab === "code" && typeof d.place === "string" && UUID.test(d.place)) openLink({ session: d.place });
    });
  }

  // --- the Code tab while the Code page is off here: a page of the portal (no frame, nothing from the code host) ---
  // Settings at the Code page's switch: its address, #settings/CODE_ENABLED — settings.js opens its section (Claude
  // Code), scrolls to it and lights it up (also when the address is that already: showTab reads it again)
  const SWITCH = "#settings/CODE_ENABLED";
  function toSettings() {
    if (location.hash === SWITCH) showTab(SWITCH.slice(1)); else location.hash = SWITCH;
  }
  const settingsLink = (text) => el("a", { href: SWITCH, text });
  const code = (t, id) => el("code", id ? { id, text: t } : { text: t });
  function copyCmd(text) {
    const b = el("button", { type: "button", class: "copy", text: "Copy" });
    b.addEventListener("click", () => copy(text, "the command"));
    return el("p", { class: "cmdline" }, code(text), " ", b);
  }
  const item = (...c) => el("li", {}, ...c);
  const FEATURES = [
    ["Chat", "Ask in plain words. Answers stream in, with each command and its output, and each file change as a diff."],
    ["Your files", "An explorer and an editor for the workspace folder; drop files in to upload them."],
    ["Permission prompts", "Allow once, Always or Deny, before a command runs or a file changes."],
    ["Previews", "The dev servers Claude starts, shown beside the chat."],
    ["Review and Git", "Every change with Keep and Undo; stage, commit and discard."],
    ["Run & test", "Your project's scripts and tests, with the problems they report."],
  ];

  function offPage() {
    const remoteOnly = state.enabled === true;   // on, but not over remote access (REMOTE_TERMINAL)
    const features = el("ul", { class: "code-off-features" },
      ...FEATURES.map(([t, d]) => el("li", {}, el("strong", { text: t }), el("span", { text: d }))));
    const card = el("div", { class: "code-off-card" });
    if (remoteOnly) {
      card.append(
        el("p", { class: "code-off-lede", text: "The Code page is on, on the computer running DevOS ADE: open the portal there and this tab opens it. Over remote access it stays off unless you allow it, because Claude runs commands on that computer." }),
        el("p", { class: "note", text: "It is Claude Code in your browser, like its desktop app:" }), features,
        el("h2", { text: "Using it from your devices too" }),
        el("ol", { class: "code-off-list" },
          item("On the computer running DevOS ADE, set ", code("REMOTE_TERMINAL=true"), " in ", code(".env"), ", then run ", code("./stack up"), "."),
          item("The same switch shares the browser terminal over remote access too (a shell from your phone), so it is a step in a terminal on purpose: ",
            el("a", { href: "#settings/REMOTE_TERMINAL", "data-setup": "terminal-remote-off", text: "Settings › Remote access" }), " shows it, read-only."),
          item("With Tailscale, approve the new Services (", code("…-terminal"), " and ", code("…-code"), ") in the admin console like the others; ", code("./stack remote status"), " lists them."),
          item("Both still ask for the portal password again before they open.")));
    } else {
      // (both names until Settings names the folder this install would mount — fillFolder: ./stack's own choice, the new
      // ~/devos-ade-workspace, or ~/bedrock-now-workspace on an install that already has it)
      const ws = el("span", { id: "code-off-ws" }, code("~/devos-ade-workspace"), ", or ", code("~/bedrock-now-workspace"),
        " on an install that already has it");
      const other = code("./stack code enable --workspace DIR", "code-off-other");
      const turnOn = el("button", { type: "button", class: "action primary", id: "code-off-settings", text: "Turn on in Settings" });
      turnOn.addEventListener("click", toSettings);
      card.append(
        el("p", { class: "code-off-lede", text: "Claude Code in your browser, like its desktop app: a chat with Claude beside your project's files, and every command and file change shown to you first." }),
        el("p", { class: "code-off-actions" }, turnOn, el("span", { class: "note", text: "on the computer running DevOS ADE" })),
        features,
        el("h2", { text: "What turning it on does" }),
        el("ul", { class: "code-off-list" },
          item("Claude runs in the browser terminal's ", el("strong", { text: "sandbox" }), ", not on your computer itself; the terminal is turned on too if it is off (a Terminal tab comes with it)."),
          item("It sees ", el("strong", { text: "one folder" }), " of this computer, its workspace: ", ws, " (created if it is not there). Another folder: ", other, "."),
          item("It has ", el("strong", { text: "its own key and budget" }), " (the terminal's, $50 a month unless you change it), apart from Chat's and ", code("devos-claude"), "'s; its spend shows on Home."),
          item("Claude ", el("strong", { text: "asks before acting" }), ": in Manual mode every command and file change waits for your OK. Bypass permissions and Auto mode stay off unless you allow them in Settings › Claude Code."),
          item("It asks for the portal password again before it opens, because it runs commands. The sandbox reaches ", el("strong", { text: "public internet addresses only" }), ", through its egress proxy: not this computer's own services, your local network or private addresses. Settings › Claude Code › Sandbox internet access changes that (", code("TERMINAL_EGRESS=off"), " in ", code(".env"), ": no internet at all)."),
          item("The first time, it builds the Code page's image: a few minutes.")),
        el("h2", { text: "Turning it on" }),
        el("p", { class: "note", text: "Turn on in Settings works only on the computer running DevOS ADE: from another device, Settings shows the switch but leaves it to that computer. Or in a terminal, in your DevOS ADE folder:" }),
        copyCmd("./stack code enable"),
        el("p", { class: "note", text: "Once it is on, reload this page: this tab then opens Claude Code. Turning it off again works from anywhere and keeps the terminal." }));
    }
    const head = el("header", { class: "home-head code-off-head" },
      el("p", { class: "eyebrow", "aria-hidden": "true", text: "DevOS ADE · Code" }),
      el("h1", { id: "code-off-title" }, el("span", { class: "code-off-icon", "aria-hidden": "true" }, icon(BRACKETS)), "Code",
        el("span", { class: "code-off-pill", text: remoteOnly ? "off for remote access" : "off" })));
    const page = el("section", { id: "code", class: "code-off-page", "aria-labelledby": "code-off-title", hidden: "" }, head, card);
    $("#frames").before(page);
    PAGES.push("code");
    if (!remoteOnly) document.addEventListener("bn:tab", (e) => { if (e.detail === "code") fillFolder(); });
  }
  // The folder Claude would see, as Settings names it: the terminal's (TERMINAL_WORKSPACE) while the terminal is on,
  // else the one ./stack code enable would give it (the snapshot's choices.code_workspace). Asked when the page shows.
  let folderAsked = false;
  async function fillFolder() {
    if (folderAsked) return;
    folderAsked = true;
    try {
      const d = await api("/api/settings");
      const keys = {};
      for (const k of (d.snapshot && d.snapshot.keys) || []) keys[k.key] = k;
      const termOn = Boolean(keys.TERMINAL_ENABLED && keys.TERMINAL_ENABLED.value === "true");
      const ws = termOn ? (keys.TERMINAL_WORKSPACE && keys.TERMINAL_WORKSPACE.value) || ""
        : (d.snapshot && d.snapshot.choices && d.snapshot.choices.code_workspace) || "";
      if (ws) $("#code-off-ws").replaceChildren(code(ws));
      if (termOn) $("#code-off-other").textContent = "./stack terminal enable --workspace DIR";
    } catch (_) { folderAsked = false; /* the default folder's name stays */ }
  }

  // Home's "Claude Code in your terminal" card: where else it runs.
  function cardLine() {
    const card = $("section.claude");
    if (!card) return;
    let line;
    const tab = el("button", { type: "button", class: "linkish", text: "Code tab" });
    tab.addEventListener("click", () => showTab("code"));
    if (here) {
      line = el("p", { class: "note code-line" }, "Or with a chat, your files and permission prompts: the ", tab,
        ". Claude runs in the terminal's sandbox; it asks for the portal password again.");
    } else if (state.enabled) {
      line = el("p", { class: "note code-line" }, "The ", tab, " is off for remote access (", code("REMOTE_TERMINAL=true"),
        " in ", code(".env"), " turns it on with the terminal: ",
        el("a", { href: "#settings/REMOTE_TERMINAL", "data-setup": "terminal-remote-off", text: "Settings › Remote access" }), ").");
    } else {
      line = el("p", { class: "note code-line" }, "Or in the browser with a chat: the ", tab, ", off for now. ",
        settingsLink("Settings › Claude Code"), " (on the computer running DevOS ADE) or ", code("./stack code enable"), " turns it on.");
    }
    card.append(line);
  }

  // An update nobody watched turning the Code page on by default (lib/code.sh code_default_notice) is said once in
  // Activity (activity.js, from /api/activity), with Keep and Turn off: it used to be a banner on Home.

  addTab();
  if (here) { listen(); routes(); window.addEventListener("load", preload, { once: true }); } else offPage();
  cardLine();
})();
