// Browse models (#models; Settings › Models & providers' "Pick which", the Code page's More models…): search the models
// Bedrock, OpenRouter and Experiential Labs could add with your keys, filter them, and add or remove one. The lists
// come from /api/models/browse (portal/portal/model_browser.py: read on this computer, never in this page); a change
// is a settings change like any other (/api/settings/apply: the portal password, the update helper, ./stack config
// apply). Loaded after app.js (el, $, api, toast, showTab come from there). DOM built with el() and textContent only.
"use strict";

(() => {
  const PROV = { bedrock: "Bedrock", openrouter: "OpenRouter", explabs: "Experiential Labs" };
  const COMPAT = { works: "Works with Claude Code", "chat-only": "Chat only", fails: "Fails in Claude Code", untested: "Not tested with Claude Code" };
  const PAGE = 60;   // rows drawn at a time ("Show more" adds as many)
  const MEMO = "bn.models.filters";
  let data = null, loading = null, shown = PAGE, watching = null, timer = null, orPublic = false;
  const f = { q: "", prov: "all", cost: "any", tools: false, images: false, works: false, mine: false, maxOut: "", minCtx: "" };
  try { Object.assign(f, JSON.parse(localStorage.getItem(MEMO) || "{}"), { q: "" }); } catch (_) { /* storage blocked: fine */ }
  const keep = () => { try { localStorage.setItem(MEMO, JSON.stringify({ ...f, q: "" })); } catch (_) { /* fine */ } };
  const page = () => $("#modelbrowser");

  const money = (v) => (v == null ? "?" : v === 0 ? "$0" : `$${v < 0.1 ? v.toFixed(3).replace(/0+$/, "") : v.toFixed(2)}`);
  const ctx = (n) => (!n ? "" : n >= 1e6 ? `${+(n / 1e6).toFixed(1)}M` : `${Math.round(n / 1000)}K`);
  const ago = (at) => {
    if (!at) return "not read yet";
    const m = Math.round((Date.now() / 1000 - at) / 60);
    return m < 1 ? "read just now" : m < 60 ? `read ${m} min ago` : m < 1440 ? `read ${Math.round(m / 60)} h ago` : `read ${Math.round(m / 1440)} days ago`;
  };

  async function load(refresh = false) {
    if (loading) return loading;
    const p = page();
    if (p) p.setAttribute("aria-busy", "true");
    loading = (async () => {
      try {
        const q = new URLSearchParams();
        if (refresh) q.set("refresh", "1");
        if (orPublic) q.set("openrouter", "public");
        data = await api(`/api/models/browse${q.toString() ? `?${q}` : ""}`);
      } catch (e) {
        if (e.message === "signed out") return;
        data = { error: e.message };
      } finally {
        loading = null;
        if (p) p.removeAttribute("aria-busy");
      }
      render();
    })();
    return loading;
  }

  // --- filtering ---
  function rows() {
    if (!data || !data.providers) return [];
    const out = [];
    for (const [k, p] of Object.entries(data.providers)) if (f.prov === "all" || f.prov === k) out.push(...p.rows);
    return out;
  }
  function matches(r) {
    const words = f.q.toLowerCase().split(/\s+/).filter(Boolean).slice(0, 8);
    const hay = `${r.id} ${r.source_id} ${r.name} ${r.vendor} ${PROV[r.provider]}${r.free ? " free" : ""}`.toLowerCase();
    if (!words.every((w) => hay.includes(w))) return false;
    if (f.cost === "free" && !r.free) return false;
    if (f.cost === "paid" && r.free) return false;
    if (f.tools && r.tools !== true) return false;
    if (f.images && r.images !== true) return false;
    if (f.works && r.compat !== "works") return false;
    if (f.mine && !r.enabled && !r.chosen) return false;
    if (f.maxOut && !(r.free || (r.out != null && r.out <= Number(f.maxOut)))) return false;
    if (f.minCtx && !(r.context && r.context >= Number(f.minCtx))) return false;
    return true;
  }
  const order = (a, b) => (b.enabled - a.enabled) || (b.chosen - a.chosen) || a.name.localeCompare(b.name);

  // --- drawing ---
  // label: a string, or an array of nodes/strings (a name and its count) spread as the button's children
  function chip(label, pressed, onClick, extra = {}) {
    const b = el("button", { type: "button", class: "chip", "aria-pressed": String(pressed), ...extra });
    for (const part of Array.isArray(label) ? label : [label]) b.append(part);
    b.addEventListener("click", onClick);
    return b;
  }
  function select(id, label, value, options, onChange) {
    const s = el("select", { id, "aria-label": label });
    for (const [v, t] of options) {
      const o = el("option", { value: v, text: t });
      if (v === value) o.selected = true;
      s.append(o);
    }
    s.addEventListener("change", () => onChange(s.value));
    return s;
  }

  function toolbar() {
    const search = el("input", { type: "search", id: "mb-search", class: "mb-search", placeholder: "Search by name, id or vendor", "aria-label": "Search the models",
      autocomplete: "off", spellcheck: "false", maxlength: "80", value: f.q });
    search.addEventListener("input", () => { f.q = search.value; shown = PAGE; drawList(); });
    const provs = el("div", { class: "chips seg mb-provs", role: "group", "aria-label": "Provider" });
    for (const k of ["all", "bedrock", "openrouter", "explabs"]) {
      const n = k === "all" ? rows().length : ((data.providers || {})[k] || { rows: [] }).rows.length;
      provs.append(chip([k === "all" ? "All" : PROV[k], " ", el("span", { class: "count", text: String(n) })], f.prov === k, () => { f.prov = k; shown = PAGE; keep(); render(); }, { "data-prov": k }));
    }
    const cost = el("div", { class: "chips seg mb-cost", role: "group", "aria-label": "Price" });
    for (const [k, t] of [["any", "Any price"], ["free", "Free"], ["paid", "Paid"]]) cost.append(chip(t, f.cost === k, () => { f.cost = k; shown = PAGE; keep(); render(); }, { "data-cost": k }));
    const toggles = el("div", { class: "chips mb-toggles", role: "group", "aria-label": "Show only" });
    for (const [k, t] of [["tools", "Tool use"], ["images", "Image input"], ["works", "Works with Claude Code"], ["mine", "In my pickers"]]) {
      toggles.append(chip(t, f[k], () => { f[k] = !f[k]; shown = PAGE; keep(); render(); }, { "data-filter": k }));
    }
    const limits = el("div", { class: "mb-limits" },
      el("label", { class: "mb-limit" }, el("span", { text: "Output price" }), select("mb-maxout", "Highest output price per million tokens", f.maxOut,
        [["", "any"], ["1", "≤ $1 / 1M"], ["5", "≤ $5 / 1M"], ["15", "≤ $15 / 1M"], ["30", "≤ $30 / 1M"]], (v) => { f.maxOut = v; shown = PAGE; keep(); drawList(); })),
      el("label", { class: "mb-limit" }, el("span", { text: "Context" }), select("mb-minctx", "Smallest context", f.minCtx,
        [["", "any"], ["32000", "32K+"], ["128000", "128K+"], ["200000", "200K+"], ["1000000", "1M+"]], (v) => { f.minCtx = v; shown = PAGE; keep(); drawList(); })));
    return el("div", { class: "mb-toolbar" }, el("div", { class: "mb-search-row" }, search), provs,
      el("div", { class: "mb-filters" }, cost, toggles, limits));
  }

  // each provider's line: on (a key) or not, where its list comes from, when it was read, what went wrong
  function sources() {
    const box = el("ul", { class: "mb-sources" });
    for (const k of ["bedrock", "openrouter", "explabs"]) {
      const p = (data.providers || {})[k];
      if (!p) continue;
      const li = el("li", { class: "mb-source", "data-provider": k });
      const head = el("span", { class: "mb-source-name", text: PROV[k] });
      let what;
      if (!p.on && k === "openrouter") {
        what = p.rows.length ? `its public list (no key: browse only), ${ago(p.at)}` : "no key: ";
      } else if (!p.on) what = "no key: its models are listed once you add one";
      else what = `${p.rows.length} model${p.rows.length === 1 ? "" : "s"}${k === "bedrock" && p.region ? ` in ${p.region}` : ""}, ${ago(p.at)}`;
      li.append(head, " ", el("span", { class: "note", text: what }));
      if (!p.on && k === "openrouter" && !p.rows.length) {
        const b = el("button", { type: "button", class: "linkish", "data-testid": "mb-or-public", text: "Browse its public list" });
        b.addEventListener("click", () => { orPublic = true; load(); });
        li.append(b);
      }
      if (!p.on) li.append(" ", el("a", { href: `#settings/${k === "bedrock" ? "AWS_ACCESS_KEY_ID" : k === "openrouter" ? "OPENROUTER_API_KEY" : "EXPLABS_API_KEY"}`, text: "Add a key" }));
      if (p.error) li.append(el("span", { class: "mb-source-error", role: "status", text: p.error }));
      if (p.on && p.stale && p.reading) li.append(el("span", { class: "note mb-reading", text: " · reading it again on this computer…" }));
      box.append(li);
    }
    return box;
  }

  function priceText(r) {
    if (r.free) return "free";
    if (r.in == null || r.out == null) return "price unknown";
    return `${money(r.in)} in · ${money(r.out)} out / 1M`;
  }

  function rowEl(r) {
    const badges = el("span", { class: "mb-badges" });
    badges.append(el("span", { class: "badge mb-prov", "data-provider": r.provider, text: PROV[r.provider] }));
    if (r.free) badges.append(el("span", { class: "badge", "data-tone": "on", text: "Free" }));
    if (r.tools === true) badges.append(el("span", { class: "badge", text: "Tools" }));
    if (r.images === true) badges.append(el("span", { class: "badge", text: "Images" }));
    badges.append(el("span", { class: `badge mb-compat mb-compat-${r.compat}`, title: r.compat_note || "", text: COMPAT[r.compat] || "Not tested with Claude Code" }));
    if (r.lifecycle === "legacy") badges.append(el("span", { class: "badge", "data-tone": "warn", text: "Legacy" }));
    const state = r.builtin ? (r.enabled ? "Built in · in your pickers" : "Built in · not available")
      : r.enabled ? "In your pickers" : r.chosen ? "Added · applies with the change" : "";
    const facts = el("p", { class: "mb-facts" }, el("span", { class: "mb-price", text: priceText(r) }),
      r.context ? el("span", { text: `${ctx(r.context)} context` }) : null,
      state ? el("span", { class: `mb-state${r.enabled ? " on" : ""}`, text: state }) : null);
    const actions = el("div", { class: "mb-actions" });
    if (r.can === "add" || r.can === "remove") {
      const b = el("button", { type: "button", class: `action${r.can === "add" ? " primary" : ""}`, "data-act": r.can, text: r.can === "add" ? "Add" : "Remove",
        "aria-label": `${r.can === "add" ? "Add" : "Remove"} ${r.name}` });
      b.disabled = !data.can_change;
      b.addEventListener("click", () => change(r, r.can));
      actions.append(b);
    } else if (r.why && !r.builtin) actions.append(el("span", { class: "note mb-why", text: r.why }));
    if (r.enabled && data.try) {
      const t = el("button", { type: "button", class: "quiet", "data-act": "try", text: "Try it", "aria-label": `Try ${r.name}` });
      t.addEventListener("click", () => tryIt(r, li));
      actions.append(t);
    }
    const li = el("li", { class: "mb-row", "data-id": r.id, "data-provider": r.provider },
      el("div", { class: "mb-main" },
        el("p", { class: "mb-name" }, el("span", { class: "mb-title", text: r.name }), r.vendor ? el("span", { class: "note mb-vendor", text: r.vendor }) : null),
        el("p", { class: "mb-id" }, el("code", { text: r.id })), badges, facts,
        r.builtin && r.why && !r.enabled ? el("p", { class: "note", text: r.why }) : null,
        r.note ? el("p", { class: "note", text: r.note }) : null),
      actions);
    return li;
  }

  function drawList() {
    const list = $("#mb-list"), count = $("#mb-count");
    if (!list) return;
    const all = rows().filter(matches).sort(order);
    count.textContent = `${all.length} model${all.length === 1 ? "" : "s"}${f.q ? ` match “${f.q.slice(0, 40)}”` : ""}`;
    list.replaceChildren(...all.slice(0, shown).map(rowEl));
    const more = $("#mb-more");
    more.hidden = all.length <= shown;
    more.textContent = `Show ${Math.min(PAGE, all.length - shown)} more`;
    if (!all.length) list.append(el("li", { class: "mb-empty note", text: rows().length ? "No model matches these filters." : "No list yet." }));
  }

  function render() {
    const p = page();
    if (!p) return;
    const head = el("header", { class: "mb-head" },
      el("p", { class: "eyebrow" }, el("a", { href: "#settings/providers", text: "Settings › Models & providers" })),
      el("h1", { id: "models-title", text: "Browse models" }),
      el("p", { class: "note mb-lede", text: "Search what Bedrock, OpenRouter and Experiential Labs offer with your keys, and add a model to every picker: Chat, the Code page, the terminal and devos-claude. Each change is saved on this computer by the update helper, after your portal password; only the model gateway restarts." }));
    if (!data) { p.replaceChildren(head, el("p", { class: "note", text: "Loading…" })); return; }
    if (data.error) { p.replaceChildren(head, el("p", { class: "banner", text: `Could not load the lists: ${data.error}` })); return; }
    const status = el("p", { id: "mb-job", class: "mb-job", role: "status", "aria-live": "polite", hidden: "" });
    const refresh = el("button", { type: "button", class: "quiet", id: "mb-refresh", text: "Read the lists again" });
    refresh.addEventListener("click", () => load(true));
    const helper = data.can_change ? null : el("p", { class: "note mb-helper", text: data.why_not || "Changes need the update helper (./stack helper install)." });
    const more = el("button", { type: "button", class: "quiet", id: "mb-more", hidden: "" });
    more.addEventListener("click", () => { shown += PAGE; drawList(); });
    p.replaceChildren(head, status, sources(), el("p", { class: "mb-refresh-line" }, refresh), helper || "", toolbar(),
      el("p", { class: "note mb-count", id: "mb-count", "aria-live": "polite" }), el("ul", { class: "mb-list", id: "mb-list", "aria-label": "Models" }), more);
    drawList();
    renderJob();
  }

  // --- a change: the setting's next value (the portal works it out), the password, the update helper ---
  let dlg = null;
  function dialog() {
    if (dlg) return dlg;
    dlg = el("dialog", { class: "confirm", id: "mb-confirm", "aria-labelledby": "mb-confirm-title" });
    const form = el("form", { method: "dialog" },
      el("h2", { id: "mb-confirm-title" }), el("p", { id: "mb-confirm-text" }),
      el("label", { for: "mb-confirm-password", text: "Portal password" }),
      el("input", { id: "mb-confirm-password", type: "password", autocomplete: "current-password", required: "" }),
      el("p", { id: "mb-confirm-error", class: "error", role: "alert", hidden: "" }),
      el("p", { class: "confirm-buttons" }, el("button", { type: "button", class: "quiet", id: "mb-confirm-cancel", text: "Cancel" }),
        el("button", { type: "submit", class: "action primary", id: "mb-confirm-ok", text: "Save" })));
    dlg.append(form);
    document.body.append(dlg);
    $("#mb-confirm-cancel").addEventListener("click", () => { $("#mb-confirm-password").value = ""; dlg.close(); });
    form.addEventListener("submit", submit);
    return dlg;
  }
  let pendingChange = null;
  async function change(r, act) {
    let plan;
    try {
      plan = await post("/api/models/browse/plan", { provider: r.provider, id: r.source_id, action: act });
    } catch (e) { toast(`Could not work out the change (${e.message})`); return; }
    if (!plan.ok) { toast(plan.error || "Nothing to change"); return; }
    pendingChange = { plan, row: r, act };
    const d = dialog();
    $("#mb-confirm-title").textContent = `${act === "add" ? "Add" : "Remove"} ${r.name}?`;
    $("#mb-confirm-text").textContent = `${plan.key} becomes ${plan.value || "blank"}. ${plan.note || ""} Applied on this computer by the update helper, which checks it again first.`;
    $("#mb-confirm-error").hidden = true;
    $("#mb-confirm-password").value = "";
    d.showModal();
    $("#mb-confirm-password").focus();
  }
  async function post(path, body) {
    const r = await fetch(path, { method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { ...API_HEADERS, "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const d = await r.json().catch(() => ({}));
    if (r.status === 401) { location.assign("/login"); throw new Error("signed out"); }
    return { ok: r.ok, status: r.status, ...d };
  }
  async function submit(ev) {
    ev.preventDefault();
    const pw = $("#mb-confirm-password").value, c = pendingChange;
    if (!pw || !c) return;
    const ok = $("#mb-confirm-ok"), err = $("#mb-confirm-error");
    ok.disabled = true;
    try {
      const d = await post("/api/settings/apply", { password: pw, base: data.base, set: { [c.plan.key]: c.plan.value } });
      if (!d.ok) {
        err.textContent = d.fields ? `${d.error} ${Object.entries(d.fields).map(([k, m]) => `${k} ${m}`).join("; ")}` : (d.error || `HTTP ${d.status}`);
        err.hidden = false;
        return;
      }
      $("#mb-confirm-password").value = "";
      dlg.close();
      watching = { id: d.id, label: `${c.act === "add" ? "Adding" : "Removing"} ${c.row.name}`, at: Date.now(), job: null };
      toast("Sent to the update helper");
      renderJob();
      poll();
    } catch (e) {
      if (e.message !== "signed out") { err.textContent = `Could not reach the portal (${e.message}).`; err.hidden = false; }
    } finally { ok.disabled = false; }
  }
  async function poll() {
    clearTimeout(timer);
    if (!watching) return;
    try {
      const a = await api("/api/admin/status");
      if (a.job && a.job.id === watching.id) watching.job = a.job;
    } catch (e) { if (e.message === "signed out") return; }
    renderJob();
    const j = watching && watching.job;
    if (j && (j.phase === "done" || j.phase === "failed")) { await load(); return; }
    if (watching && Date.now() - watching.at < 15 * 60000) timer = setTimeout(poll, 2000);
  }
  function renderJob() {
    const s = $("#mb-job");
    if (!s) return;
    const w = watching;
    s.hidden = !w;
    if (!w) return;
    const j = w.job;
    s.className = `mb-job ${j && j.phase === "failed" ? "bad" : j && j.phase === "done" ? "good" : ""}`;
    s.replaceChildren(el("b", { text: `${w.label}: ` }),
      !j ? "waiting for the update helper…" : j.phase === "done" ? `saved. ${j.message || ""}` : j.phase === "failed" ? `not saved: ${j.message || "the helper said no"}` : `${j.message || j.phase}…`);
    if (j && (j.phase === "done" || j.phase === "failed")) {
      const x = el("button", { type: "button", class: "quiet", text: "Dismiss" });
      x.addEventListener("click", () => { watching = null; renderJob(); });
      s.append(" ", x);
    }
  }

  // --- Try it: one short request on the model, its cost said first ---
  async function tryIt(r, li) {
    const box = li.querySelector(".mb-try") || el("div", { class: "mb-try", role: "status" });
    li.append(box);
    let est;
    try { est = await post("/api/models/try", { model: r.id, estimate: true }); } catch (e) { box.textContent = e.message; return; }
    if (!est.ok) { box.replaceChildren(el("span", { class: "error", text: est.error || "Not now" })); return; }
    const cost = est.usd == null ? "an unknown amount (its price is not known)" : est.usd === 0 ? "$0 (free)" : `at most $${est.usd.toFixed(6).replace(/0+$/, "")}`;
    const go = el("button", { type: "button", class: "action", "data-act": "try-run", text: est.expensive ? "Run it on this expensive model" : "Run it" });
    const ack = est.expensive ? el("label", { class: "mb-ack" }, el("input", { type: "checkbox", id: `mb-ack-${CSS.escape(r.id)}` }), " Yes, I want to spend this on this model") : null;
    const cancel = el("button", { type: "button", class: "quiet", text: "Cancel" });
    cancel.addEventListener("click", () => box.remove());
    go.addEventListener("click", async () => {
      if (ack && !ack.querySelector("input").checked) { ack.classList.add("mb-ack-need"); return; }
      go.disabled = true;
      box.replaceChildren(el("span", { class: "note", text: "Asking the model…" }));
      const out = await post("/api/models/try", { model: r.id, confirm: true, expensive_ok: Boolean(ack) }).catch((e) => ({ ok: false, error: e.message }));
      box.replaceChildren(out.ok ? el("span", { class: "good", text: `It answered: “${out.text || "(nothing)"}”${out.cost != null ? ` · cost $${Number(out.cost).toFixed(6).replace(/0+$/, "").replace(/\.$/, "")}` : ""}` })
        : el("span", { class: "error", text: `It did not answer: ${out.error || "no reason"}` }));
    });
    box.replaceChildren(el("p", { class: "note", text: `One short request (${est.max_tokens} tokens at most) on ${r.name}, booked to the setup key: ${cost}.` }),
      ack || "", el("p", { class: "mb-try-buttons" }, cancel, go));
  }

  // --- the page: #modelbrowser[/<provider>] ---
  function place() {
    const m = /^#modelbrowser\/(bedrock|openrouter|explabs)$/.exec(location.hash);
    if (m) { f.prov = m[1]; shown = PAGE; }
  }
  document.addEventListener("bn:tab", (e) => {
    if (e.detail !== "modelbrowser") return;
    place();
    render();
    load();
  });
  // app.js runs its first showTab at parse time, before this script's bn:tab listener exists: if the page opened on
  // #modelbrowser, pick it up once the DOM is ready (as settings.js does for #settings)
  document.addEventListener("DOMContentLoaded", () => {
    if (location.hash.startsWith("#modelbrowser")) { place(); render(); load(); }
  });
  window.bnModels = { open: (prov) => { showTab(prov ? `modelbrowser/${prov}` : "modelbrowser"); } };
})();
