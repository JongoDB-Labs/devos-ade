// Local models and model servers (Settings › Models & providers › Local models, and the panel on Browse models;
// portal/portal/local_models.py, lib/local_models.sh): search
// Hugging Face for MLX (Apple silicon) or GGUF models, see each quant's size, license and whether it fits this computer's memory, download one
// (with progress), remove one, and see the disk used. The model runs on this computer (Docker Model Runner, else Ollama)
// and is served by the model gateway: it shows in Chat, the Code page and the terminal marked Local, at $0.
// Loaded after settings.js, which calls mount(frame, helpers) while it draws the row and handles the password dialog
// (helpers.askPassword; its submit calls started() once the update helper has the request). models.js (Browse models)
// uses the same form and flow: panel(container, helpers, focus) draws it there, rows() hands over the downloaded models and each
// saved server's models as Browse rows, and onChange(fn) tells it when they changed. "Check server" is the one step with
// no password (read-only; POST /api/local-models/probe); saving, removing, keys and downloads still ask for it. DOM built with el() and
// textContent only: nothing Hugging Face or the file says is ever markup.
"use strict";

(() => {
  const GB = 1024 ** 3;
  const size = (n) => (!n ? "?" : n >= GB ? `${(n / GB).toFixed(n >= 10 * GB ? 0 : 1)} GB` : `${Math.max(1, Math.round(n / 1048576))} MB`);
  const count = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : String(n || 0));
  const ctxk = (n) => (n % 1024 === 0 ? `${n / 1024}k` : count(n));
  const RUNTIME = { mlx: "MLX (this Mac's GPU)", dmr: "Docker Model Runner", ollama: "Ollama", none: "no model runner" };
  const GPU = (g, mem) => (g === "metal" ? `Apple GPU (Metal), ${size(mem)} memory` : g.startsWith("cuda:") ? `NVIDIA GPU (${size(Number(g.slice(5)))}), ${size(mem)} memory` : `CPU only, ${size(mem)} memory`);
  let box = null, helpers = null, state = null, timer = null, query = "", results = null, open = null, detail = null, busy = false, message = "";
  let want = "", openFind = false, part = "";    // part: what the panel on Browse models shows, "download" | "server" | "" (both, and always in Settings)                     // (what an entry point asked to see first: "download" | "server")
  const listeners = [];
  // the password dialog is settings.js's: lent when Settings mounts this, else read from window (Browse models)
  const askPw = (...a) => ((helpers && helpers.askPassword) || window.bnAskPassword)(...a);

  const live = () => state && state.job && ["pulling", "registering", "removing"].includes(state.job.state);

  async function load(refresh = false) {
    try { state = await api(`/api/local-models${refresh ? "?refresh=1" : ""}`); } catch (e) { if (e.message === "signed out") return; state = { error: e.message }; }
    render();
    for (const fn of listeners) { try { fn(); } catch (_) { /* a listener's own trouble */ } }
    clearTimeout(timer);
    // quickly while a download runs, or until the first file is there; otherwise only when the section is looked at again
    if (live()) timer = setTimeout(load, 1000);
    else if (state && state.wait) timer = setTimeout(load, 2000);
  }

  async function find(q) {
    query = q; open = null; detail = null; busy = true; message = ""; render();
    try {
      const d = await api(`/api/local-models/search?q=${encodeURIComponent(q)}`);
      results = d.rows || []; message = d.error || (results.length ? "" : "Nothing matches that. Try a shorter word, like the model's family name.");
    } catch (e) { if (e.message === "signed out") return; results = []; message = e.message; }
    busy = false; render();
  }
  async function files(repo) {
    if (open === repo) { open = null; detail = null; render(); return; }
    open = repo; detail = null; message = ""; render();
    try { detail = (await api(`/api/local-models/search?repo=${encodeURIComponent(repo)}`)).repo; } catch (e) { if (e.message === "signed out") return; message = e.message; }
    render();
  }

  const badge = (text, tone, title) => el("span", { class: "badge", ...(tone ? { "data-tone": tone } : {}), ...(title ? { title } : {}), text });
  const noteTone = { "chat-only": "warn", weak: "warn", untested: "" };

  function runtimeLine() {
    const rt = state.runtime;
    if (rt.kind === "none") {
      const how = el("div", { class: "lm-how", role: "status" }, el("p", { text: state.known ? (rt.how || "Nothing on this computer can run a downloaded model yet.") : "Looking at what this computer can run…" }));
      if (state.known) {
        const cmd = el("code", { class: "lm-cmd", text: rt.command });
        const cp = el("button", { type: "button", class: "quiet", text: "Copy" });
        cp.addEventListener("click", () => { try { navigator.clipboard.writeText(rt.command); cp.textContent = "Copied"; } catch (_) { /* the command is shown */ } });
        how.append(el("p", {}, "To turn it on, run this in a terminal on this computer: ", cmd, " ", cp, " It asks before it changes anything. Or install Ollama. You can still use a model server below."));
      }
      return how;
    }
    return el("p", { class: "lm-runtime" }, el("b", { text: RUNTIME[rt.kind] }), ` · ${GPU(state.gpu, state.memory)}`);
  }

  function job() {
    const j = state.job;
    if (!j || j.state === "idle") return null;
    const pct = j.total_bytes ? Math.min(100, Math.round((100 * j.done_bytes) / j.total_bytes)) : null;
    const wrap = el("div", { class: `lm-job ${j.state === "failed" ? "bad" : j.state === "done" ? "good" : ""}`, role: "status", "aria-live": "polite" });
    wrap.append(el("p", {}, el("b", { text: `${j.repo}${j.quant ? `:${j.quant}` : ""} ` }), j.message));
    if (j.state === "pulling") {
      const p = el("progress", { max: "100", "aria-label": "Download progress" });
      if (pct != null) p.value = pct;
      wrap.append(p, el("span", { class: "note", text: ` ${j.total_bytes ? `${size(j.done_bytes)} of ${size(j.total_bytes)}` : size(j.done_bytes)}${pct != null ? ` · ${pct}%` : ""}` }));
    } else if (j.state === "registering" || j.state === "removing") wrap.append(el("progress", { "aria-label": "Working" }));
    return wrap;
  }

  function installedList() {
    const list = el("ul", { class: "lm-list", id: "lm-installed" });
    for (const i of state.installed) {
      const rm = el("button", { type: "button", class: "action", "data-act": "local-remove", text: "Remove" });
      rm.disabled = !state.can_change || live();
      rm.addEventListener("click", () => askPw({ kind: "local", action: "local-remove", repo: i.repo, quant: i.quant },
        `Remove ${i.repo}:${i.quant}?`, `It leaves Chat, the Code page and the terminal at once, and its ${size(i.bytes)} are deleted from this computer's model runner.`, "Remove"));
      list.append(el("li", { class: "lm-item" }, el("div", { class: "lm-item-main" },
        el("p", { class: "lm-name" }, el("b", { text: i.repo }), ` ${i.quant} `, badge("Local", "on"), badge("$0"),
          i.present ? "" : badge("missing from the runtime", "warn", "The runtime no longer lists it: remove it here, or download it again."),
          i.registered ? "" : badge("not served", "warn")),
        el("p", { class: "note", text: `${size(i.bytes)} · ${i.license || "license unknown"} · ${RUNTIME[i.runtime] || ""}${i.revision ? ` · revision ${i.revision.slice(0, 12)}` : ""}` })), rm));
    }
    return list;
  }

  function quantRow(repo, q) {
    const fit = q.fits || {};
    const dl = el("button", { type: "button", class: "action primary", "data-act": "local-pull", text: q.installed ? "Downloaded" : "Download" });
    dl.disabled = !state.can_change || live() || q.installed || state.runtime.kind === "none" || !!repo.blocked;
    dl.addEventListener("click", () => askPw({ kind: "local", action: "local-pull", repo: repo.repo, quant: q.quant },
      `Download ${repo.repo}${q.quant === "mlx" ? "" : `:${q.quant}`}?`,
      `${size(q.size)} from huggingface.co (license: ${repo.license || "not stated"}) to this computer's model runner, then served by the model gateway in every picker, free. ${fit.fit === "no" ? "It probably does not fit this computer's memory." : ""}`, "Download"));
    const why = repo.blocked ? repo.blocked : !state.can_change ? state.why_not : state.runtime.kind === "none" ? "No model runner is running." : "";
    return el("li", { class: "lm-quant" },
      el("span", { class: "lm-q", text: q.quant === "mlx" ? "whole model" : q.quant }), el("span", { class: "lm-size", text: size(q.size) }),
      el("span", { class: `lm-fit lm-fit-${fit.fit || "unknown"}`, title: fit.text || "" }, fit.fit === "yes" ? "fits" : fit.fit === "tight" ? "tight fit" : fit.fit === "no" ? "too big" : "fit unknown"),
      el("span", { class: "note lm-fit-text", text: fit.text || "" }), dl, why ? el("span", { class: "note lm-why", text: why }) : "");
  }

  function repoRow(r) {
    const isOpen = open === r.repo;
    const b = el("button", { type: "button", class: "linkish", "aria-expanded": String(isOpen), "data-testid": "lm-repo", text: r.repo });
    b.addEventListener("click", () => files(r.repo));
    const li = el("li", { class: "lm-item" }, el("div", { class: "lm-item-main" },
      el("p", { class: "lm-name" }, b, " ", r.gated ? badge("gated", "warn", "Needs a Hugging Face token and its license accepted on huggingface.co") : "",
        badge(r.license || "license ?"), r.params ? badge(`${(r.params / 1e9).toFixed(r.params >= 1e10 ? 0 : 1)}B`) : "",
        r.tools === "yes" ? badge("tool template") : r.tools === "no" ? badge("no tool support", "warn") : ""),
      el("p", { class: "note", text: `${count(r.downloads)} downloads · ${count(r.likes)} likes${r.context ? ` · ${count(r.context)} context` : ""}` })));
    if (isOpen) {
      const d = detail && detail.repo === r.repo ? detail : null;
      if (!d) li.append(el("p", { class: "note", role: "status", text: message || "Reading its files…" }));
      else {
        li.append(el("p", { class: `lm-warn ${noteTone[d.note.level] ? "warn" : ""}`, text: `As Claude Code's model: ${d.note.text} Each answer is capped at 4,096 tokens, so a stuck model stops.` }));
        const ul = el("ul", { class: "lm-quants" });
        for (const q of d.quants) ul.append(quantRow(d, q));
        li.append(ul);
      }
    }
    return li;
  }

  function search() {
    const input = el("input", { type: "search", id: "lm-search", class: "mb-search", placeholder: "Search Hugging Face, e.g. qwen coder, llama 3.2, smollm2", "aria-label": "Search Hugging Face for models to download", value: query });
    const go = el("button", { type: "submit", class: "action", text: "Search" });
    const form = el("form", { class: "lm-search" }, input, go);
    input.addEventListener("input", () => { query = input.value; });     // (kept: a redraw while it is typed in builds it from query)
    form.addEventListener("submit", (ev) => { ev.preventDefault(); find(input.value.trim()); });
    const out = el("div", { class: "lm-search-box" }, form);
    if (busy) out.append(el("p", { class: "note", role: "status", text: "Searching Hugging Face…" }));
    else if (message && !open) out.append(el("p", { class: "note", role: "status", text: message }));
    if (results && results.length) {
      const ul = el("ul", { class: "lm-list lm-results", id: "lm-results" });
      for (const r of results) ul.append(repoRow(r));
      out.append(ul);
    }
    out.append(el("p", { class: "note", text: "Searches Hugging Face's public list from this portal (nothing about you is sent) and pulls only from huggingface.co. A gated model needs a Hugging Face token (set it below) and its license accepted there. Small local models are weak at Claude Code's tools: each model says what to expect." }));
    return out;
  }

  // --- Model servers -------------------------------------------------------------------------------------------------
  // The one card for where models run. First row: this computer (the runtime and its downloads). Then every OpenAI-compatible server
  // (vLLM, Ollama, LM Studio, llama-server, another Mac) pointed at by address, each with whether it answers, the models it
  // serves (an on/off box for each), Edit key and Remove. Under them the Add form: address, optional name and key, "check" (a probe
  // run on this computer by the update helper), the models it found with a box each, then Save. Every step asks for the portal
  // password and goes through the update helper, like the rest of Settings; the key is never shown again and never comes back.
  const NAME_OK = /^[a-z0-9][a-z0-9-]{0,23}$/;
  const FAIL = { down: "Not reachable", blocked: "Refused", numeric: "Not an address it will use", dns: "Name does not resolve" };
  let srv = { url: "", name: "", key: "", trust: false, probe: null, picked: null, wait: null, note: "", staged: {}, keyFor: null, keyText: "" };

  const nameFrom = (url) => {
    const host = url.replace(/^[a-z]+:\/\//i, "").replace(/[/:?#].*$/, "").replace(/^\[|\]$/g, "").toLowerCase();
    const n = host.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 24).replace(/-+$/g, "");
    return NAME_OK.test(n) ? n : "";
  };
  const taken = (n) => (state.servers || []).some((x) => x.name === n);
  const uniqueName = (url, given) => {
    if (given) return given;
    const base = nameFrom(url) || "server";
    let n = base, i = 2;
    while (taken(n)) n = `${base.slice(0, 21)}-${i++}`;
    return n;
  };

  // serverSent (settings.js: the update helper has the request): wait for its answer in the status file, matched by ref
  function waitFor(ref, op, name) {
    srv.wait = { ref, op, name, since: Date.now() }; srv.note = "";
    render();
    clearTimeout(timer); timer = setTimeout(poll, 700);
  }
  async function poll() {
    await load();
    const w = srv.wait;
    if (!w) return;
    const r = state && state.result;
    if (r && r.ref === w.ref) { srv.wait = null; finished(r, w); render(); return; }
    if (Date.now() - w.since > 90000) { srv.wait = null; srv.note = "The update helper did not answer in time. Check ./stack logs helper, then try again."; render(); return; }
    clearTimeout(timer); timer = setTimeout(poll, 1000);
  }
  function finished(r, w) {
    if (w.op === "probe") {
      srv.probe = r;
      srv.picked = new Set(r.models.map((m) => m.id));     // (all on by default)
      srv.note = r.ok ? "" : (r.message || "That did not work.");
    } else if (r.ok) {
      if (w.op === "save") srv = { ...srv, url: "", name: "", key: "", trust: false, probe: null, picked: null, note: `Added ${w.name}.${/key cleared: the address changed/.test(r.message || "") ? " Key cleared: the address changed." : ""}` };
      else if (w.op === "remove") srv.note = `Removed ${w.name}.`;
      else if (w.op === "key") { srv.keyFor = null; srv.keyText = ""; srv.note = `Key for ${w.name} updated.`; }
      else { delete srv.staged[w.name]; srv.note = `Models on ${w.name} updated.`; }
    } else srv.note = r.message || "That did not work.";
    if (w.op === "save" && !r.ok) srv.note = r.message || "That did not work.";
    if (w.op !== "probe" && srv.note && typeof toast === "function") toast(srv.note);      // (Browse models has no panel open for a toggle: say it here)
    load();
  }

  // this computer's own address (localhost, 127.x, ::1): the helper checks those without the password, and only those
  const onThisComputer = (u) => {
    const host = u.replace(/^[a-z]+:\/\//i, "").replace(/^(\[[^\]]*\]|[^/:?#]*).*$/, "$1").replace(/^\[|\]$/g, "").toLowerCase();
    return host === "localhost" || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host) || host === "::1" || /^::ffff:127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host);
  };

  // "Check server" of this computer: read-only, so no password (the portal's session, CSRF and origin checks still apply, and the helper keeps
  // refusing cloud-metadata and link-local addresses); the answer is read from the status like any other, matched by ref
  async function runProbe(u) {
    srv.wait = { ref: "", op: "probe", name: "", since: Date.now() }; render();
    try {
      const r = await fetch("/api/local-models/probe", { method: "POST", credentials: "same-origin", cache: "no-store",
        headers: { ...API_HEADERS, "Content-Type": "application/json" }, body: JSON.stringify({ url: u, trust: srv.trust && /^https:/i.test(u), key: srv.key }) });
      const d = await r.json().catch(() => ({}));
      if (r.status === 401) { location.assign("/login"); return; }
      if (!r.ok) { srv.wait = null; srv.note = d.error || `That did not work (HTTP ${r.status}).`; render(); return; }
      waitFor(d.ref, "probe", "");
    } catch (e) { srv.wait = null; srv.note = `Could not reach the portal (${e.message}).`; render(); }
  }

  const ask = (what, title, text, ok) => askPw({ kind: "server", ...what }, title, text, ok);

  function addForm() {
    const url = el("input", { type: "text", id: "ms-url", class: "mb-search", placeholder: "Address, e.g. localhost:11434", "aria-label": "Address of the computer running models", autocomplete: "off", spellcheck: "false", value: srv.url });
    const name = el("input", { type: "text", id: "ms-name", placeholder: "Name (optional)", "aria-label": "Server name", autocomplete: "off", maxlength: "24", value: srv.name });
    const key = el("input", { type: "password", id: "ms-key", placeholder: "API key (optional)", "aria-label": "API key", autocomplete: "new-password", value: srv.key });
    const keyNote = el("span", { class: "note", id: "ms-key-note", text: "Changing a saved server's address clears its saved key — enter it again." });
    keyNote.hidden = !(state.servers || []).length;
    const trust = el("input", { type: "checkbox", id: "ms-trust" }); trust.checked = srv.trust;
    const trustRow = el("label", { class: "lm-trust", id: "ms-trust-row" }, trust, " Trust this server's certificate (it is self-signed)");
    const sync = () => { srv.url = url.value; srv.name = name.value.trim().toLowerCase(); srv.key = key.value; srv.trust = trust.checked; trustRow.hidden = !/^https:\/\//i.test(url.value.trim()); };
    for (const i of [url, name, key, trust]) i.addEventListener("input", sync);
    sync();
    const go = el("button", { type: "submit", class: "action primary", id: "ms-check", text: srv.wait && srv.wait.op === "probe" ? "Checking…" : "Check server" });
    go.disabled = !state.can_change || !!srv.wait;
    // (the usual ports on this computer: a click fills the address in)
    const quick = el("div", { class: "lm-quick", id: "ms-quick" }, el("span", { class: "note", text: "On this computer:" }));
    for (const [label, addr] of [["Ollama", "localhost:11434"], ["LM Studio", "localhost:1234"], ["vLLM or llama.cpp", "localhost:8000"]]) {
      const q = el("button", { type: "button", class: "quiet", "data-addr": addr, text: `${label} (${addr.split(":")[1]})` });
      q.addEventListener("click", () => { url.value = addr; sync(); url.focus(); });
      quick.append(q);
    }
    const form = el("form", { class: "lm-add", id: "ms-add" }, el("div", { class: "lm-add-row" }, url), quick, el("div", { class: "lm-add-row" }, name, key), keyNote, trustRow,
      el("div", { class: "lm-add-row" }, go, el("span", { class: "note", text: state.can_change ? "Asks the server for its models from this computer. Nothing is saved until you add it; checking this computer (localhost) needs no password, another computer asks for it." : state.why_not })));
    form.addEventListener("submit", (ev) => {
      ev.preventDefault(); sync();
      const u = srv.url.trim();
      if (!u) { srv.note = "Type the server's address first."; render(); return; }
      if (srv.name && !NAME_OK.test(srv.name)) { srv.note = "A name is lowercase letters, digits and -, up to 24."; render(); return; }
      if (srv.name && taken(srv.name)) { srv.note = `There is already a server named ${srv.name}.`; render(); return; }
      srv.probe = null; srv.picked = null; srv.note = "";
      if (onThisComputer(u)) { runProbe(u); return; }
      render();                                                   // (the last check's result goes now, not when this one answers)
      ask({ op: "probe", url: u, name: "", key: srv.key, trust: srv.trust && /^https:/i.test(u), models: [] }, "Check this server?",
        `${u} is another computer: it is asked for its model list (GET /v1/models) from this computer. Nothing is saved yet.`, "Check");
    });
    return form;
  }

  function probeResult() {
    const p = srv.probe;
    if (!p) return "";
    const pbox = el("div", { class: `lm-probe ${p.status === "ok" ? "good" : "bad"}`, id: "ms-probe", role: "status" });
    if (p.status === "ok") {
      pbox.append(el("p", {}, badge("answering", "on"), ` ${p.url} answers and has ${p.models.length} model${p.models.length === 1 ? "" : "s"}. Tick the ones you want in your pickers.`));
      if (p.warning) pbox.append(el("p", { class: "lm-warn warn", id: "ms-warn", text: p.warning }));
      const ul = el("ul", { class: "lm-models", id: "ms-models" });
      for (const m of p.models) {
        const cb = el("input", { type: "checkbox", "data-model": m.id }); cb.checked = srv.picked.has(m.id);
        cb.addEventListener("change", () => { if (cb.checked) srv.picked.add(m.id); else srv.picked.delete(m.id); saveBtn.textContent = saveLabel(); });
        ul.append(el("li", {}, el("label", {}, cb, " ", el("code", { text: m.id }), m.context ? el("span", { class: "note", text: ` · ${ctxk(m.context)} context` }) : "")));
      }
      pbox.append(ul);
    } else {
      pbox.append(el("p", {}, badge(FAIL[p.status] || "Failed", "warn"), ` ${p.reason || p.message || "no answer"}`));
      if (["down"].includes(p.status)) pbox.append(el("p", { class: "note", text: "Check that the server is running and the address and port are right. You can still add it now; its models appear when it answers." }));
      if (p.warning) pbox.append(el("p", { class: "lm-warn warn", id: "ms-warn", text: p.warning }));
    }
    const saveLabel = () => (p.status === "ok" ? `Add server with ${srv.picked.size} model${srv.picked.size === 1 ? "" : "s"}` : "Add it anyway");
    const saveBtn = el("button", { type: "button", class: "action primary", id: "ms-save", text: saveLabel() });
    saveBtn.disabled = !state.can_change || !!srv.wait || ["blocked", "numeric", "dns"].includes(p.status);
    saveBtn.addEventListener("click", () => {
      const name = uniqueName(p.url, srv.name);
      const models = p.status === "ok" ? [...srv.picked] : ["*"];       // (a server that is down: whatever it serves once it answers)
      ask({ op: "save", name, url: p.url, key: srv.key, trust: p.trust, models }, `Add ${name}?`,
        `${p.url} joins the model gateway${p.status === "ok" ? ` with ${models.length} model${models.length === 1 ? "" : "s"}` : " (it is not answering now; its models appear when it does)"}: they show in Chat, the Code page and the terminal marked Local, at $0.${p.warning ? ` ${p.warning}` : ""}`, "Add server");
    });
    pbox.append(el("p", {}, saveBtn));
    return pbox;
  }

  function serverRow(s) {
    const staged = srv.staged[s.name] || null;
    const isOn = (id) => (staged ? staged.has(id) : s.all || s.enabled.includes(id));
    const head = el("p", { class: "lm-name" }, el("b", { text: s.name }), " ", badge(s.up ? "reachable" : "unavailable", s.up ? "on" : "warn"), badge("Local"), badge("$0"),
      s.key ? badge("key set") : "", s.trust ? badge("self-signed trusted", "warn") : "");
    const main = el("div", { class: "lm-item-main" }, head, el("p", { class: "note", text: `${s.url}${s.reached_as && !s.reached_as.startsWith("http") ? ` · ${s.reached_as}` : ""}` }));
    if (s.warning) main.append(el("p", { class: "lm-warn warn", text: s.warning }));
    if (s.key_note) main.append(el("p", { class: "lm-warn warn", text: s.key_note }));
    if (!s.up) main.append(el("p", { class: "lm-warn warn", text: `Unavailable: ${s.reason || "no answer"}` }));
    if (s.up || s.enabled.length) {
      const ul = el("ul", { class: "lm-models", "data-server": s.name });
      const rows = s.up ? s.models : s.enabled.map((id) => ({ id, context: null }));
      for (const m of rows) {
        const cb = el("input", { type: "checkbox", "data-model": m.id }); cb.checked = isOn(m.id); cb.disabled = !s.up || !state.can_change;
        cb.addEventListener("change", () => {
          const cur = srv.staged[s.name] || new Set(s.all ? s.models.map((x) => x.id) : s.enabled);
          if (cb.checked) cur.add(m.id); else cur.delete(m.id);
          srv.staged[s.name] = cur; render();
        });
        ul.append(el("li", {}, el("label", {}, cb, " ", el("code", { text: m.id }), m.context ? el("span", { class: "note", text: ` · ${ctxk(m.context)} context` }) : "")));
      }
      main.append(ul);
      if (s.up) main.append(el("p", { class: "note", text: "Tool use is not known: a small or self-hosted model may call tools wrongly or not at all." }));
    }
    const acts = el("div", { class: "lm-acts" });
    if (staged) {
      const ap = el("button", { type: "button", class: "action primary", "data-act": "server-models", text: "Apply model changes" });
      ap.disabled = !state.can_change || !!srv.wait;
      const all = s.up && s.models.length > 0 && s.models.every((m) => staged.has(m.id));
      ap.addEventListener("click", () => ask({ op: "models", name: s.name, models: all && s.all ? ["*"] : [...staged] }, `Change the models on ${s.name}?`,
        `${staged.size} model${staged.size === 1 ? "" : "s"} on: they show in every picker at once, the others leave.`, "Apply"));
      const un = el("button", { type: "button", class: "quiet", text: "Undo" });
      un.addEventListener("click", () => { delete srv.staged[s.name]; render(); });
      acts.append(ap, un);
    }
    const ek = el("button", { type: "button", class: "action", "data-act": "server-key", text: "Edit key" });
    ek.disabled = !state.can_change; ek.addEventListener("click", () => { srv.keyFor = srv.keyFor === s.name ? null : s.name; srv.keyText = ""; render(); });
    const rm = el("button", { type: "button", class: "action", "data-act": "server-remove", text: "Remove" });
    rm.disabled = !state.can_change;
    rm.addEventListener("click", () => ask({ op: "remove", name: s.name, models: [] }, `Remove ${s.name}?`, `Its models leave Chat, the Code page and the terminal at once. Nothing on the server itself changes.`, "Remove"));
    acts.append(ek, rm);
    if (srv.keyFor === s.name) {
      const ki = el("input", { type: "password", class: "lm-keyin", "aria-label": `New API key for ${s.name}`, placeholder: s.key ? "New key (the old one is never shown)" : "API key", autocomplete: "new-password", value: srv.keyText });
      ki.addEventListener("input", () => { srv.keyText = ki.value; });
      const sv = el("button", { type: "button", class: "action primary", text: "Save key" });
      sv.addEventListener("click", () => { if (!ki.value.trim()) { srv.note = "Type the key, or use Remove key."; render(); return; }
        ask({ op: "key", name: s.name, key: ki.value.trim(), models: [] }, `Change the key for ${s.name}?`, "The new key is sent to the update helper and stored as a secret; it is never shown again.", "Save key"); });
      const rk = el("button", { type: "button", class: "quiet", text: "Remove key" }); rk.disabled = !s.key;
      rk.addEventListener("click", () => ask({ op: "key", name: s.name, key: "", models: [] }, `Remove the key for ${s.name}?`, "Requests to it go without a key.", "Remove key"));
      main.append(el("div", { class: "lm-keyrow" }, ki, sv, rk));
    }
    return el("li", { class: "lm-item", "data-server-row": s.name }, main, acts);
  }

  function servers(thisComputer) {
    const list = state.servers || [];
    const sec = el("div", { class: "lm-sec lm-servers", id: "lm-servers" });
    const ul = el("ul", { class: "lm-list lm-scroll", id: "lm-server-list" });
    if (thisComputer) ul.append(el("li", { class: "lm-item lm-this", id: "lm-this", "data-server-row": "this-computer" }, el("div", { class: "lm-item-main" }, el("p", { class: "lm-name" }, el("b", { text: "This computer" }), " ", badge("Local", "on")), thisComputer)));
    for (const s of list) ul.append(serverRow(s));
    if (ul.children.length) sec.append(el("h4", { class: "lm-h", text: thisComputer ? "Where models run" : "Your model servers" }), ul);
    if (!list.length) sec.append(el("p", { class: "note", id: "ms-empty", text: "No model servers yet. Add the computer that runs your models below: this one (localhost) or another on your network. Its models then show in every picker, free." }));
    sec.append(...(part === "server" ? [] : [el("h4", { class: "lm-h", id: "ms-add-h", text: "Add a model server" })]), el("p", { class: "note", text: "A computer on your network running models, or this one. Any OpenAI-compatible server works: Ollama, LM Studio, vLLM, llama.cpp." }), addForm(), probeResult());
    if (srv.wait) sec.append(el("p", { class: "note", role: "status", id: "ms-wait", text: srv.wait.op === "probe" ? "Checking the server…" : "Waiting for the update helper…" }));
    if (srv.note) sec.append(el("p", { class: `note ${/did not|not |refused|cannot/i.test(srv.note) ? "lm-warn warn" : ""}`, id: "ms-note", role: "status", text: srv.note }));
    return sec;
  }

  function render() {
    if (!box || !state) return;
    if (state.error) { box.replaceChildren(el("p", { class: "error", text: state.error })); return; }
    // (a redraw while the form is being typed in keeps the focus and what was typed: the form is only rebuilt from srv)
    const here = document.activeElement && document.activeElement.id;
    const caret = here === "lm-search" || here === "ms-url" ? document.activeElement.selectionStart : null;
    if (!srv.url && !(state.servers || []).length) srv.url = "localhost:11434";     // (localhost is the default)
    const body = el("div", { class: "lm-body" });
    const j = job();
    const mine = el("div", { class: "lm-this-body" }, runtimeLine());
    if (j) mine.append(j);
    if (!state.can_change && state.why_not) mine.append(el("p", { class: "note", text: state.why_not }));
    const have = state.installed.length;
    const dl = el("details", { class: "lm-sec", id: "lm-have", ...(have || live() ? { open: "" } : {}) },
      el("summary", { text: `Downloaded (${have})${have ? ` · ${size(state.disk)} on disk` : ""}` }),
      have ? installedList() : el("p", { class: "note", text: "Nothing downloaded yet. Search Hugging Face below, open a model and press Download." }));
    const find_ = el("details", { class: "lm-sec", id: "lm-find", ...(results || open || openFind ? { open: "" } : {}) }, el("summary", { text: "Download from Hugging Face" }), search());
    mine.append(dl, find_);
    if (part === "download") body.append(el("div", { class: "lm-sec lm-servers", id: "lm-servers" }, mine));
    else body.append(servers(part === "server" ? null : mine));
    box.replaceChildren(body);
    if (want) {                                       // (an entry point: show its part first)
      const w = want; want = "";
      const t = box.querySelector(w === "download" ? "#lm-search" : "#ms-url");
      if (t) { t.focus({ preventScroll: true }); t.scrollIntoView({ block: "center" }); }
    } else if (here && ["ms-url", "ms-name", "ms-key", "lm-search"].includes(here) && box.querySelector(`#${here}`)) {
      const t = box.querySelector(`#${here}`);
      t.focus({ preventScroll: true });
      if (caret !== null) try { t.setSelectionRange(caret, caret); } catch (e) { /* (not a text field) */ }
    }
  }

  // --- for Browse models: the downloaded models and each server's models as rows, with the same add / remove words ---
  const serverModels = (s) => (s.up ? s.models : s.enabled.map((id) => ({ id, context: null })));
  function browseRows() {
    if (!state || state.error) return [];
    const can = !!state.can_change, out = [];
    for (const i of state.installed || []) {
      out.push({ id: i.name || `lm/${i.repo}:${i.quant}`, source_id: `${i.repo}:${i.quant}`, name: `${i.repo}:${i.quant}`, vendor: i.repo.split("/")[0], provider: "local", free: true,
        tools: i.tools === "yes" ? true : i.tools === "no" ? false : null, images: null, in: 0, out: 0, context: null, compat: i.tools === "no" ? "chat-only" : "untested",
        enabled: i.present && i.registered, chosen: false, builtin: false, can: can && !live() ? "remove" : null, canChange: can && !live(), why: live() ? "A download is running." : state.why_not || "",
        note: `${size(i.bytes)} · ${i.license || "license unknown"} · runs on this computer. Remove deletes it from here.`,
        local: () => askPw({ kind: "local", action: "local-remove", repo: i.repo, quant: i.quant }, `Remove ${i.repo}:${i.quant}?`,
          `It leaves Chat, the Code page and the terminal at once, and its ${size(i.bytes)} are deleted from this computer.`, "Remove") });
    }
    for (const s of state.servers || []) {
      for (const m of serverModels(s)) {
        const on = s.all || s.enabled.includes(m.id);
        const toggle = (act) => {
          const cur = new Set(s.all ? s.models.map((x) => x.id) : s.enabled);
          if (act === "add") cur.add(m.id); else cur.delete(m.id);
          askPw({ kind: "server", op: "models", name: s.name, models: [...cur] }, `${act === "add" ? "Add" : "Remove"} ${m.id}?`,
            act === "add" ? `${m.id} on ${s.name} shows in every picker: Chat, the Code page and the terminal, free.` : `${m.id} leaves every picker. Nothing on ${s.name} itself changes.`, act === "add" ? "Add" : "Remove");
        };
        out.push({ id: `ms/${s.name}/${m.id}`, source_id: m.id, name: m.id, vendor: `on ${s.name}`, provider: "server", free: true, tools: null, images: null, in: 0, out: 0,
          context: m.context, compat: "untested", enabled: on && s.up, chosen: false, builtin: false, can: can && s.up ? (on ? "remove" : "add") : null, canChange: can && s.up,
          why: s.up ? (can ? "" : state.why_not) : `${s.name} is not answering${s.reason ? `: ${s.reason}` : ""}`,
          note: `${s.url}. Tool use is not known: a small or self-hosted model may call tools wrongly or not at all.`, local: toggle });
      }
    }
    return out;
  }

  window.bnLocal = {
    // settings.js: the row's frame, to fill, and what it lends (the password dialog)
    mount(frame, h) {
      helpers = h; part = ""; box = el("div", { class: "lm-box", id: "lm-box", "aria-busy": "false" });
      frame._main.append(box);
      if (state) render(); else box.append(el("p", { class: "note", text: "Looking…" }));   // (a redraw of Settings keeps what was read)
      load(!state);
    },
    // Browse models: the same form and flow in a panel of its own (focus: "download" | "server" | "" for both)
    panel(container, h, focus) {
      helpers = h || null; want = focus || ""; part = want; openFind = want === "download";
      box = el("div", { class: "lm-box", id: "lm-box", "aria-busy": "false" });
      container.replaceChildren(box);
      if (state) render(); else box.append(el("p", { class: "note", text: "Looking…" }));
      load(!state);
      return box;
    },
    unpanel(container) { if (box && container.contains(box)) box = null; },
    ensure() { return state ? Promise.resolve(state) : load().then(() => state); },
    refresh() { return load(true); },
    rows: browseRows,
    summary() {
      if (!state || state.error) return null;
      const j = state.job, pct = j && j.total_bytes ? Math.min(100, Math.round((100 * j.done_bytes) / j.total_bytes)) : null;
      return { known: state.known, downloaded: (state.installed || []).length, servers: (state.servers || []).length, runtime: state.runtime,
        job: live() ? { repo: j.repo, quant: j.quant, state: j.state, message: j.message, pct } : null };
    },
    onChange(fn) { listeners.push(fn); },
    // settings.js: the update helper took a download or a removal: watch its progress here
    // settings.js: a model-server request went to the update helper (what: the form's request, d: the portal's answer)
    serverSent(what, d) { if (what.key) what.key = ""; waitFor(d.ref, what.op, what.name || ""); },
    started() { state = state && { ...state, job: { ...(state.job || {}), state: "registering", message: "Waiting for the update helper…", repo: "", quant: "" } }; render(); clearTimeout(timer); timer = setTimeout(load, 1000); },
  };
})();
