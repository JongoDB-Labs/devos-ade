// Home's first cards: Get started — five steps for a first run, each ticked by what the portal can see — and Continue:
// what to pick up again, each one tap away — the Code sessions that need you, the recent ones and Chat's newest
// conversations — with New session and New chat. Loaded after app.js, mobile.js and code.js (deferred: their $, el,
// api, showTab, appUrl, appFrame, usd, lastSummary and window.bnCode) and before tour.js, whose first visit leaves the
// walkthrough closed: Get started is the first run now, the walkthrough the full tour beside it.
// Data: GET /api/continue (portal/recent.py: what the Code page last reported of its sessions, and Chat's newest
// conversations) whenever Home refreshes (app.js's bn:summary) and soon after the Code tab reports (bn:code-status);
// /api/summary through bn:summary (models, spend); /api/settings once, for the budget step only. Text only: nothing
// from the API is parsed as HTML; titles are sandbox or Chat data, shown as text with their invisible characters made
// visible (code.js shownTitle, recent.py shown). What this browser keeps (localStorage bn.getstarted, every access in
// try/catch): Get started hidden or not, and "Keep these" for the budgets.
// Item menus (ctxmenu.js; JON-821): each Continue row opens one on a right-click, its ⋯ button, a long press or Shift+F10.
// A Chat conversation: Open, Open in a new tab, Copy link, Rename, Archive, Delete — the portal asks Open WebUI as the owner
// (POST /api/chats/ID/rename|archive|delete, portal/chatsearch.py). A Code session: Open, Open in a new tab, Copy link here;
// Rename, Fork, Add to project, Open its folder in a terminal, Archive and Delete are asked of the Code page itself (the
// portal never reaches the code container: window.bnCode.sessionDo, a message to the framed page, which opens its own
// dialogs — nothing is deleted without them) and are off, with the reason, until that page has run in this browser.
"use strict";

(() => {
  const home = $("#home"), gsBox = $("#get-started"), contBox = $("#continue");
  if (!home || !gsBox || !contBox) return;
  const CODE = (() => {
    try { const c = JSON.parse(document.querySelector('meta[name="bn-code"]').content) || {}; return { enabled: c.enabled === true, here: c.here === true && Boolean(APP_URLS.code) }; }
    catch (_) { return { enabled: false, here: false }; }
  })();
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const PROJECT = /^(ws|p_[0-9a-f]{8})$/;
  const KEY = "bn.getstarted";
  const STALE_S = 300;            // a report older than this: Home says how old it is
  const NS = "http://www.w3.org/2000/svg";
  const icon = (d) => {
    const s = document.createElementNS(NS, "svg"), p = document.createElementNS(NS, "path");
    s.setAttribute("viewBox", "0 0 20 20"); s.setAttribute("aria-hidden", "true"); p.setAttribute("d", d); s.append(p);
    return s;
  };
  const BRACKETS = "M7.5 5.5 3 10l4.5 4.5M12.5 5.5 17 10l-4.5 4.5M11 4l-2 12";
  const BUBBLE = "M4 4h12a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H9l-4 3v-3H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z";
  const INVISIBLE = /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff\u{e0000}-\u{e007f}]/gu;
  const shown = (t, n = 120) => (typeof t !== "string" ? "" : Array.from(t.slice(0, n * 2)).slice(0, n).join("").replace(/[\t\n\r]/g, " ")
    .replace(INVISIBLE, (c) => `⟨U+${c.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")}⟩`).trim());
  // "just now", "5 min ago", "3 h ago", "yesterday", "Oct 14"
  function ago(sec, now = Date.now() / 1000) {
    if (!Number.isFinite(sec) || sec <= 0) return "";
    const s = Math.max(0, now - sec);
    if (s < 90) return "just now";
    if (s < 3600) return `${Math.round(s / 60)} min ago`;
    if (s < 86400) return `${Math.round(s / 3600)} h ago`;
    if (s < 172800) return "yesterday";
    return new Date(sec * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }

  // --- what this browser keeps ---
  function load() {
    let raw = null, tour = null;
    try { raw = localStorage.getItem(KEY); tour = localStorage.getItem("bn.tour"); } catch (_) { /* storage blocked: a first run */ }
    let st = null;
    try { st = JSON.parse(raw || "null"); } catch (_) { st = null; }
    if (st && typeof st === "object" && !Array.isArray(st)) return { hidden: st.hidden === true, budgets: st.budgets === true };
    // nothing kept yet: a first run — unless this browser went through Home before Get started was there (the
    // walkthrough's own state is kept): then it stays out of the way, and the walkthrough brings it back
    return { hidden: tour !== null, budgets: false };
  }
  let gs = load();
  function save() { try { localStorage.setItem(KEY, JSON.stringify({ hidden: gs.hidden, budgets: gs.budgets })); } catch (_) { /* fine */ } }
  save();

  // --- the data ---
  let cont = null, summary = null, cfg = null, cfgAsked = false, live = null, contBusy = false, contT = null;
  async function fetchContinue() {
    clearTimeout(contT); contT = null;
    if (contBusy) return;   // (one at a time: a Home shown again while it asks)
    contBusy = true;
    try { cont = await api("/api/continue"); } catch (e) { if (e.message === "signed out") return; cont = cont || { error: e.message }; } finally { contBusy = false; }
    render();
  }
  // the Code tab reported (code.js): its page sends the portal its report a moment later — asked then
  function soon(ms = 3500) { if (!contT) contT = setTimeout(fetchContinue, ms); }
  // (each time Home refreshes: shown again, Refresh, every 30 s)
  document.addEventListener("bn:summary", (e) => {
    summary = e.detail || null;
    fetchContinue();
  });
  // (only when what it says changed, and Home is on screen: the Code tab reports at every turn's step)
  let liveKey = "";
  document.addEventListener("bn:code-status", (e) => {
    live = e.detail || null;
    const k = JSON.stringify(live && [live.waiting, (live.sessions || []).map((x) => [x.id, x.state])]);
    if (k === liveKey) return;
    liveKey = k;
    render();
    if (!home.hidden && !document.hidden) soon();
  });

  // --- links into the apps ---
  const codeLink = (params) => {
    try { const u = new URL(appUrl("code")); for (const [k, v] of Object.entries(params)) if (v) u.searchParams.set(k, v); return u.href; } catch (_) { return "#code"; }
  };
  const chatLink = (id) => { try { return id ? new URL(`c/${id}`, appUrl("chat")).href : appUrl("chat"); } catch (_) { return "#chat"; } };
  function openChat(id) {
    showTab("chat");
    appFrame("chat").src = chatLink(id);
  }
  function openSession(id) { if (window.bnCode && window.bnCode.openSession) window.bnCode.openSession(id); }
  function newSession(project) {
    if (window.bnCode && window.bnCode.newSession) window.bnCode.newSession(project);
    else showTab("code");
  }
  const actLink = (cls, href, text, fn) => {
    const a = el("a", { class: cls, href, text });
    a.addEventListener("click", (e) => { if (e.button || e.metaKey || e.ctrlKey || e.shiftKey) return; e.preventDefault(); fn(); });
    return a;
  };

  // --- Continue ---
  // the Code page's sessions as Home shows them: the server's last report, or — the Code tab framed here reported
  // since — its live states on top of it (the waiting count above all)
  function codeReport() {
    const r = cont && cont.code && cont.code.report;
    if (!r && !live) return null;
    const out = { at: r ? r.at : Date.now() / 1000, sessions: r ? r.sessions.map((s) => ({ ...s })) : [], project: r ? r.project : null, waiting: r ? r.waiting : 0 };
    if (live && Array.isArray(live.sessions)) {
      for (const s of live.sessions) {
        const have = out.sessions.find((x) => x.id === s.id);
        if (have) have.state = s.state;
        else out.sessions.unshift({ id: s.id, state: s.state, title: s.title, at: null });
      }
      out.waiting = Number.isInteger(live.waiting) ? live.waiting : out.waiting;
      out.live = true;
    }
    out.sessions = out.sessions.filter((s) => typeof s.id === "string" && UUID.test(s.id));
    return out;
  }
  const STATE_WORDS = { waiting: "needs you", working: "working", idle: "open", closed: "" };
  function row(kind, item, now) {
    const code = kind === "code";
    const words = code ? (item.state === "waiting" ? "needs you" : item.state === "working" ? "working" : ago(item.at, now) || STATE_WORDS[item.state])
      : ago(item.updated_at, now);
    const verb = code ? (item.state === "waiting" ? "Answer" : "Resume") : "Open";
    // (at most 120 characters shown — two lines, three on a phone, the rest cut with an ellipsis —, the whole title in
    // its tooltip and the row's name: Chat's go up to 200)
    const full = shown(item.title, 200) || (code ? "Untitled session" : "Untitled chat");
    const cut = shown(item.title, 120);
    const title = cut && cut !== full ? `${cut}…` : full;
    const a = actLink(`cont-row ${kind}${code ? ` ${item.state}` : ""}`, code ? codeLink({ session: item.id }) : chatLink(item.id), "",
      () => (code ? openSession(item.id) : openChat(item.id)));
    a.setAttribute("aria-label", `${verb}: ${full} (${code ? "Code" : "Chat"}${words ? `, ${words}` : ""})`);
    a.append(el("span", { class: "cont-icon", "aria-hidden": "true" }, icon(code ? BRACKETS : BUBBLE)),
      el("span", { class: "cont-main" }, el("span", { class: "cont-title", title: full, text: title }),
        el("span", { class: "cont-meta", text: `${code ? "Code" : "Chat"}${words ? ` · ${words}` : ""}` })),
      el("span", { class: "cont-verb", "aria-hidden": "true", text: verb }));
    return el("li", { "data-kind": kind, "data-id": item.id, "data-name": full }, a);
  }

  // --- the item menus ---
  const post = async (path, body) => {
    const r = await fetch(path, { method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { ...API_HEADERS, "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
    const d = await r.json().catch(() => ({}));
    if (r.status === 401) { location.assign("/login"); throw new Error("signed out"); }
    if (!r.ok) throw new Error(d.error || `HTTP ${r.status}`);
    return d;
  };
  const absolute = (href) => { try { return new URL(href, location.href).href; } catch (_) { return href; } };
  const NEEDS_CODE = "Open the Code tab once, so Home can ask it";
  // a Chat conversation: Open WebUI's own change, then Continue is asked again at once
  async function chatChange(what, id, body, done) {
    try {
      await post(`/api/chats/${id}/${what}`, body);
      toast(done);
      fetchContinue();
    } catch (e) { toast(`Not done: ${e.message}`); }
  }
  function chatActions(li) {
    const id = li.dataset.id, name = li.dataset.name;
    return [
      { id: "open", label: "Open", run: () => openChat(id) },
      { id: "new-tab", label: "Open in a new tab", href: chatLink(id) },
      { id: "copy-link", label: "Copy link", run: () => copy(absolute(chatLink(id)), "the link") },
      { id: "rename", label: "Rename…", sep: true, run: async () => {
        const t = await bnMenu.ask({ title: "Rename the conversation", label: "Name", value: name === "Untitled chat" ? "" : name, ok: "Rename" });
        if (t) chatChange("rename", id, { title: t }, "Renamed");
      } },
      { id: "archive", label: "Archive", run: () => chatChange("archive", id, {}, "Archived: Chat lists it under Archived chats") },
      { id: "delete", label: "Delete…", danger: true, run: async () => {
        const ok = await bnMenu.confirm({ title: "Delete this conversation?", ok: "Delete the conversation", danger: true,
          lines: [name, "The conversation is deleted from Chat for good: its messages and what it was titled go, and there is no trash for it. Files and settings elsewhere are not touched."] });
        if (ok) chatChange("delete", id, { confirm: id }, "Deleted");
      } },
    ];
  }
  // a Code session: here what the portal knows; the rest is the Code page's own (see the top of this file)
  function codeActions(li) {
    const id = li.dataset.id, name = li.dataset.name;
    const ready = Boolean(window.bnCode && window.bnCode.ready && window.bnCode.ready());
    const ask = (action, title) => () => {
      if (window.bnCode.sessionDo(id, action, title)) { if (action === "archive") { toast("Archived: the Code page lists it under Archived"); soon(1500); } }
      else toast("The Code page did not answer: open the Code tab and try again.");
    };
    const off = ready ? {} : { disabled: true, reason: NEEDS_CODE };
    return [
      { id: "open", label: li.dataset.state === "waiting" ? "Open (it needs you)" : "Open", run: () => openSession(id) },
      { id: "new-tab", label: "Open in a new tab", href: codeLink({ session: id }) },
      { id: "rename", label: "Rename…", ...off, run: async () => {
        const t = await bnMenu.ask({ title: "Rename the session", label: "Name", value: name === "Untitled session" ? "" : name, ok: "Rename" });
        if (t) { ask("rename", t)(); toast("Renamed"); soon(1500); }
      } },
      { id: "fork", label: "Fork (a new session from here)", ...off, run: ask("fork") },
      { id: "file", label: "Add to project…", ...off, run: ask("file") },
      { id: "terminal", label: "Open its folder in a terminal", ...off, run: ask("terminal") },
      { id: "copy-link", label: "Copy link", run: () => copy(absolute(codeLink({ session: id })), "the link") },
      { id: "archive", label: "Archive", sep: true, ...off, run: ask("archive") },
      { id: "delete", label: "Delete…", danger: true, ...off, run: ask("delete") },
    ];
  }
  bnMenu.bind(contBox, ".cont-list > li", (li) => (li.dataset.kind === "code" ? codeActions(li) : chatActions(li)), { links: true, label: (li) => li.dataset.name });
  function renderContinue() {
    const now = cont && Number.isFinite(cont.now) ? cont.now : Date.now() / 1000;
    const rep = CODE.here ? codeReport() : null;
    const chats = cont && cont.chats && Array.isArray(cont.chats.items) ? cont.chats.items.filter((c) => c && typeof c.id === "string" && UUID.test(c.id)) : [];
    const waiting = rep ? rep.sessions.filter((s) => s.state === "waiting") : [];
    const recent = [...(rep ? rep.sessions.filter((s) => s.state !== "waiting").map((s) => ({ kind: "code", item: s, t: s.state === "working" ? now : s.at || 0 })) : []),
      ...chats.map((c) => ({ kind: "chat", item: c, t: c.updated_at || 0 }))].sort((a, b) => b.t - a.t).slice(0, 6);
    const project = rep && rep.project && PROJECT.test(rep.project.id) ? rep.project : null;

    const head = el("div", { class: "cont-head" }, el("h2", { id: "continue-title", text: "Continue" }));
    const acts = el("div", { class: "cont-actions" });
    if (CODE.here) {
      const name = project && project.id !== "ws" ? shown(project.name, 40) : "";
      const b = actLink("action primary cont-new", codeLink({ new: "1", project: project ? project.id : "" }), name ? `New session in ${name}` : "New session",
        () => newSession(project ? project.id : ""));
      b.dataset.k = "new-session";
      acts.append(b);
    }
    const nc = actLink("action cont-chat", chatLink(""), "New chat", () => openChat(""));
    nc.dataset.k = "new-chat";
    acts.append(nc);
    head.append(acts);
    const parts = [head];
    if (waiting.length) {
      parts.push(el("h3", { class: "cont-group waiting", text: `Needs you (${waiting.length})` }),
        el("ul", { class: "cont-list", "aria-label": "Code sessions that need you" }, ...waiting.map((s) => row("code", s, now))));
    }
    if (recent.length) {
      parts.push(el("h3", { class: "cont-group", text: "Recent" }), el("ul", { class: "cont-list", "aria-label": "Recent sessions and chats" }, ...recent.map((r) => row(r.kind, r.item, now))));
    }
    const notes = [];
    if (CODE.here && !rep) notes.push("Your Code sessions show here once the Code page has been open in a browser since the portal started.");
    else if (rep && !rep.live && now - rep.at > STALE_S) notes.push(`Code sessions as the Code page last said, ${ago(rep.at, now)}: open it for what they do now.`);
    if (!CODE.here) notes.push(CODE.enabled ? "The Code page is off from this device (remote access): its sessions are not listed here." : "The Code page is off: Settings › Claude Code turns it on.");
    if (cont && cont.chats && cont.chats.error) notes.push(`Chat's conversations are not listed: ${shown(cont.chats.error, 160)}.`);
    if (cont && cont.error) notes.push(`Could not load what to pick up again (${shown(cont.error, 80)}): Home tries again with its next refresh.`);
    if (!cont) parts.push(el("p", { class: "cont-empty", text: "Loading…" }));
    else if (!waiting.length && !recent.length) parts.push(el("p", { class: "cont-empty", text: "Nothing to pick up yet: start a session or a chat." }));
    if (notes.length) parts.push(el("p", { class: "note cont-note", text: notes.join(" ") }));
    contBox.replaceChildren(...parts);
    contBox.hidden = false;
  }

  // --- Get started ---
  const enabledChat = () => ((summary && summary.models && summary.models.rows) || []).filter((r) => r && r.enabled && r.kind === "chat");
  const spendOf = (alias) => {
    const k = summary && summary.spend && (summary.spend.keys || []).find((x) => x.alias === alias);
    return k && !k.error && typeof k.spend === "number" ? k.spend : null;
  };
  const settingsLink = (place, text) => el("a", { class: "action", href: `#settings/${place}`, text });
  function budgetsChanged() {
    if (!cfg) return null;
    return cfg.some((k) => /^BUDGET_(CLAUDE_CODE|OPENWEBUI|TERMINAL|SETUP)$/.test(k.key) && typeof k.value === "string" && "default" in k
      && k.value.trim() !== "" && k.value.trim() !== String(k.default).trim());
  }
  async function askSettings() {
    if (cfgAsked) return;
    cfgAsked = true;
    try { const d = await api("/api/settings"); cfg = (d && d.snapshot && Array.isArray(d.snapshot.keys)) ? d.snapshot.keys : []; } catch (_) { cfg = []; }
    render();
  }
  function steps() {
    const rows = enabledChat();
    const bed = rows.filter((r) => (r.provider || "Bedrock") === "Bedrock").length, other = rows.length - bed;
    const rep = CODE.here ? codeReport() : null;
    const chats = cont && cont.chats && Array.isArray(cont.chats.items) ? cont.chats.items.length : 0;
    const termSpent = spendOf("claude-code-terminal"), chatSpent = spendOf("open-webui");
    const keys = (summary && summary.spend && summary.spend.keys) || [];
    const changed = budgetsChanged();
    const plural = (n, w) => `${n} ${w}${n === 1 ? "" : "s"}`;
    return [
      { id: "signin", title: "Sign in", done: true, text: "Done: this one password opens Chat, Code and the rest." },
      { id: "models", title: "Add a model provider", done: rows.length > 0,
        text: !summary ? "Checking…" : rows.length ? `${plural(rows.length, "chat model")} ready: ${[bed ? `${bed} on Bedrock (your AWS key)` : "", other ? `${other} from your other providers` : ""].filter(Boolean).join(", ")}.`
          : "No chat model is enabled yet: add a provider's key, or ask your AWS admin for Bedrock model access.",
        acts: () => [settingsLink("providers", rows.length ? "Models & providers" : "Add a provider")] },
      CODE.here
        ? { id: "code", title: "Open Code and run a first session", done: Boolean(rep && rep.sessions.length) || (termSpent || 0) > 0,
          text: rep && rep.sessions.length ? `${plural(rep.sessions.length, "session")} in Code.` : (termSpent || 0) > 0 ? "Done: Code's key has been used."
            : "Claude Code in your browser: ask it about your project. It asks before it runs a command or changes a file.",
          acts: () => [actLink("action", codeLink({ new: "1" }), "Open Code", () => newSession(""))] }
        : { id: "code", title: "Open Code and run a first session", done: false,
          text: CODE.enabled ? "The Code page is off from this device: open the portal on the computer running DevOS ADE." : "The Code page is off: turn it on in Settings, on the computer running DevOS ADE.",
          acts: () => (CODE.enabled ? [] : [settingsLink("CODE_ENABLED", "Turn on in Settings")]) },
      { id: "chat", title: "Open Chat and ask something", done: chats > 0 || (chatSpent || 0) > 0,
        text: chats ? `${plural(chats, "conversation")} in Chat${chats >= 5 ? " (at least)" : ""}.` : (chatSpent || 0) > 0 ? "Done: Chat's key has been used." : "Pick a model at the top of Chat and ask: each answer says what it cost.",
        acts: () => [actLink("action", chatLink(""), "Open Chat", () => openChat(""))] },
      { id: "budget", title: "Set a budget", done: gs.budgets || changed === true,
        text: keys.length ? `Each key has a monthly budget: ${keys.filter((k) => !k.error).map((k) => `${k.label} ${k.max_budget != null ? `${usd(k.max_budget)}` : "none"}`).join(" · ")}.`
          : "Each app has its own key with a monthly budget.",
        acts: () => {
          const keep = el("button", { type: "button", class: "quiet", text: "Keep these" });
          keep.addEventListener("click", () => { gs.budgets = true; save(); render(); });
          return [settingsLink("spending", "Change budgets"), gs.budgets || changed ? null : keep];
        } },
    ];
  }
  function renderGetStarted() {
    if (gs.hidden) { gsBox.hidden = true; gsBox.replaceChildren(); return; }
    const all = steps(), n = all.filter((s) => s.done).length;
    if (!gs.budgets && !cfgAsked && summary) askSettings();
    const tourBtn = el("button", { type: "button", class: "linkish gs-tour", text: "Full walkthrough" });
    tourBtn.addEventListener("click", () => { if (window.bnTour && window.bnTour.open) window.bnTour.open("welcome"); });
    const hide = el("button", { type: "button", class: "quiet gs-hide", "aria-label": "Hide Get started", title: "Hide (the walkthrough brings it back)" }, "Hide");
    hide.addEventListener("click", () => {
      gs.hidden = true; save(); render();
      toast("Get started is hidden: the walkthrough brings it back");
    });
    const bar = el("i"); bar.style.width = `${(n / all.length) * 100}%`;
    const head = el("div", { class: "gs-head" },
      el("h2", { id: "gs-title", text: n === all.length ? "You're set up" : "Get started" }),
      el("p", { class: "gs-prog", text: `${n} of ${all.length} done` }),
      el("div", { class: "gs-tools" }, tourBtn, hide),
      el("div", { class: "gs-bar", role: "progressbar", "aria-label": "Get started", "aria-valuemin": "0", "aria-valuemax": String(all.length), "aria-valuenow": String(n) }, bar));
    const list = el("ol", { class: "gs-steps" });
    for (const s of all) {
      const acts = s.done && s.id !== "budget" ? [] : (s.acts ? s.acts().filter(Boolean) : []);
      list.append(el("li", { class: `gs-step${s.done ? " done" : ""}`, "data-step": s.id },
        el("span", { class: "gs-mark", "aria-hidden": "true", text: s.done ? "✓" : "" }),
        el("div", { class: "gs-body" }, el("strong", { class: "gs-name", text: s.title }), el("span", { class: "sr", text: s.done ? " (done)" : " (to do)" }),
          el("span", { class: "gs-text", text: s.text })),
        acts.length ? el("div", { class: "gs-acts" }, ...acts) : ""));
    }
    gsBox.replaceChildren(head, list);
    gsBox.classList.toggle("all-done", n === all.length);
    gsBox.hidden = false;
  }

  let shownKey = "";
  function render() {
    // (redrawn only when what it shows changed: a redraw every 30 s would disturb a reader and a keyboard user)
    const k = JSON.stringify([cont, live, gs, cfg && budgetsChanged(), summary && [enabledChat().length, (summary.spend && summary.spend.keys || []).map((x) => [x.alias, x.spend, x.max_budget, x.label])]]);
    if (k === shownKey) return;
    const keep = home.contains(document.activeElement) && (gsBox.contains(document.activeElement) || contBox.contains(document.activeElement)) ? document.activeElement : null;
    const keepK = keep ? keep.dataset.k || keep.textContent : null;
    shownKey = k;
    renderGetStarted();
    renderContinue();
    if (keepK) {
      const again = [...home.querySelectorAll("#get-started a, #get-started button, #continue a, #continue button")].find((n) => (n.dataset.k || n.textContent) === keepK);
      if (again) again.focus({ preventScroll: true });
    }
  }

  // The first visit's greeting (tour.js calls window.bnWelcome.start() once, when nothing of the walkthrough was stored):
  // Get started — already first on Home, under its title (app.js shows Home to a first visit), so nothing more is done;
  // the walkthrough stays closed beside it, and a first visit by a link to another page shows that page as it is.
  window.bnWelcome = { start: () => { if (!gs.hidden) render(); } };
  // The walkthrough (tour.js) and other pages: Get started brought back and shown, and what it says
  window.bnGetStarted = {
    open: () => {
      gs.hidden = false; save(); shownKey = ""; render();
      showTab("home");
      requestAnimationFrame(() => gsBox.scrollIntoView({ block: "start" }));
    },
    hidden: () => gs.hidden,
    state: () => { const all = steps(); return { hidden: gs.hidden, done: all.filter((s) => s.done).length, total: all.length }; },
  };
  render();
})();
