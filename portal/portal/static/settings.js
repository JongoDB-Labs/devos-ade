// Settings: every .env value (secrets masked), changed through the update helper (/api/settings/*).
// Loaded after app.js (el, $, api, toast, copy, usd, day, showTab, appUrl come from there). DOM built with el() and
// textContent only; nothing from the API is ever parsed as HTML. Every change asks for the portal password again.
//
// Layout (catalog/settings-layout.tsv, from /api/settings): task sections shown one at a time (a list on the left; a
// picker on phones), each with its common settings, a folded "More settings", and settings that belong to a switch
// indented under it and hidden while it is off. Search and "Changed from default" look through every section.
// Addresses: #settings/<section>, #settings/<KEY>, #settings/<section>/<KEY> (app.js keeps the part after the slash).
"use strict";

(() => {
  const REPO = "https://github.com/JongoDB-Labs/devos-ade/blob/main/";
  // a budget and the alias of its LiteLLM key (this period's spend under it); the key itself is the row's "with" key
  const BUDGET_ALIAS = { BUDGET_CLAUDE_CODE: "claude-code", BUDGET_OPENWEBUI: "open-webui", BUDGET_SETUP: "setup",
    BUDGET_TERMINAL: "claude-code-terminal" };
  const REVEALABLE = new Set(["LITELLM_UI_PASSWORD", "RUSTFS_ACCESS_KEY", "RUSTFS_SECRET_KEY", "LITELLM_KEY_CLAUDE_CODE",
    "LITELLM_KEY_OPENWEBUI", "LITELLM_KEY_SETUP", "SHARED_MCP_TOKEN"]);
  const DIAG_PHASES = ["check-aws", "models-recheck", "backup", "test", "report"];
  const STT_LABEL = { bedrock: "Bedrock (Mistral Voxtral, in your AWS account)", openai: "OpenAI", groq: "Groq", "": "Browser speech recognition (no voice calls)" };
  // (portal/settings.py STT_REFUSED: the API refuses Bedrock with the same words)
  const STT_REFUSED = "Bedrock speech-to-text is unavailable: AWS no longer accepts audio for the Voxtral models (since October 2026). Use browser speech, or your own OpenAI/Groq key.";
  // what a change restarts, by settings.tsv's apply column (lib/settings.sh _cfg_post): the badge next to a setting —
  // in the page's words (LiteLLM is the model gateway, Caddy the web server, shared-mcp the shared file server)
  const RESTARTS = { "portal-pw": ["the portal"], email: ["Chat", "the portal"], "litellm-pw": ["the portal"], portal: ["the portal"],
    "litellm-cfg": ["the model gateway"], aws: ["the model gateway"], pins: ["Chat", "the portal"], "alert-pct": ["the portal"], stt: ["the model gateway", "Chat", "the portal"],
    openrouter: ["the model gateway", "the portal"], explabs: ["the model gateway"], websearch: ["the model gateway"],
    rustfs: ["Files", "Chat", "the shared file server", "the portal"], mcp: ["the shared file server", "the portal"],
    code: ["the portal", "the web server"], "code-env": ["the Code page"], "terminal-env": ["the terminal"], "terminal-egress": ["the terminal"],
    "remote-preview": ["the portal", "the web server"] };
  // the settings the model gateway takes without a restart (lib/litellm_live.sh: only its model list changes): a badge
  // that says so, instead of what their apply class restarts for a key
  const LIVE = new Set(["EXPLABS_MODELS", "OPENROUTER_MODELS", "OPENROUTER_MAX_MODELS", "OPENROUTER_INCLUDE_ALIASES", "CODE_MODELS", "CODE_DEFAULT_MODEL", "BEDROCK_MODELS", "LOCAL_MODELS", "MODEL_SERVERS", "MODEL_SERVER_MODELS"]);
  // what removing a key does, in each key's own words (the keys share one form; lib/settings.sh _cfg_post, _stt_apply)
  const REMOVE_KEY = {
    or_key: "OpenRouter's models disappear from Chat and the API; the model gateway and the portal restart (about 40 s).",
    stt_key: "The OpenAI or Groq key is deleted. While Speech-to-text uses OpenAI or Groq the removal is refused (they need a key): switch it to the browser or Bedrock first. the model gateway, Chat and the portal restart (about 40 s).",
    // (Experiential Labs' key restarts LiteLLM alone: RESTARTS.explabs)
    xl_key: "Experiential Labs' models disappear from Chat, the Code page and the API; the model gateway restarts (about 30 s).",
    ws_key: "Claude Code's WebSearch stops searching with it (the next search backend set up takes over, or none); the model gateway restarts (about 15 s).",
  };
  // A provider key's form: where a key comes from (a "Get a key" link under the field), its shape as a placeholder, and
  // whether the portal asks the provider before the password (POST /api/settings/check-key, portal/keycheck.py: one free
  // call; the helper checks it again either way). Web search keys and the AWS key have no such check here: the AWS key's
  // needs STS and a Bedrock call, which the helper makes; a web search costs. (The web search links: WS_INFO's.)
  const KEY_FORM = {
    OPENROUTER_API_KEY: { get: "https://openrouter.ai/settings/keys", hint: "sk-or-v1-…", check: "OpenRouter" },
    EXPLABS_API_KEY: { get: "https://platform.experientiallabs.ai/settings/api-keys", check: "Experiential Labs" },
    AWS_ACCESS_KEY_ID: { get: "https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html", getText: "IAM access keys (AWS docs)" },
    WEBSEARCH_TAVILY_API_KEY: { ws: "tavily" }, WEBSEARCH_BRAVE_API_KEY: { ws: "brave" }, WEBSEARCH_PERPLEXITY_API_KEY: { ws: "perplexity" },
  };
  const STT_KEY_FORM = { openai: { get: "https://platform.openai.com/api-keys", hint: "sk-…", check: "OpenAI" },
    groq: { get: "https://console.groq.com/keys", hint: "gsk_…", check: "Groq" } };
  // where a key comes from: the only addresses a message's text is made a link to (a helper's "create one at https://…")
  const KEY_HOSTS = new Set(["openrouter.ai", "platform.experientiallabs.ai", "platform.openai.com", "console.groq.com",
    "app.tavily.com", "api-dashboard.search.brave.com", "console.perplexity.ai", "docs.aws.amazon.com"]);
  // a key's shape, checked before the password (portal/settings.py's validators, in the same words)
  const KEY_SHAPE = {
    or_key: [/^[A-Za-z0-9_-]{1,256}$/, "must be an OpenRouter key (sk-or-…; letters, digits, - and _)"],
    xl_key: [/^[A-Za-z0-9_-]{20,256}$/, "must be an Experiential Labs key (20-256 letters, digits, - and _)"],
    stt_key: [/^[A-Za-z0-9_-]{20,512}$/, "must be an API key: 20-512 letters, digits, - and _"],
    ws_key: [/^[A-Za-z0-9_-]{16,256}$/, "must be an API key: 16-256 letters, digits, - and _"],
    aws_key_id: [/^AKIA[A-Z0-9]{16}$/, "must be an IAM user access key ID: AKIA and 16 more letters or digits"],
    aws_secret: [/^[A-Za-z0-9/+]{40}$/, "must be 40 characters (letters, digits, / and +)"],
  };
  const ON_VALUES = ["true", "1", "yes", "on"], OFF_VALUES = ["false", "0", "no", "off"];
  const KEY_NAME = /^[A-Z][A-Z0-9_]{1,60}$/;   // (as the setup links' targets: catalog/setup-links.tsv)
  const SECTION_MEMO = "bn.settings.section";
  // a row that stands for more than its key: named for what it shows (a provider's key: the provider)
  const ROW_LABEL = { RUSTFS_ACCESS_KEY: "Files (RustFS) key pair", STT_PROVIDER: "Speech-to-text", TERMINAL_ENABLED: "Browser terminal",
    REMOTE_MODE: "Remote access", AWS_ACCESS_KEY_ID: "Bedrock", OPENROUTER_API_KEY: "OpenRouter", EXPLABS_API_KEY: "Experiential Labs",
    WEBSEARCH_BACKEND: "Web search", WEBSEARCH_SEARXNG_BUILTIN: "Built-in SearXNG", WEBSEARCH_AGENTCORE_GATEWAY: "AgentCore Web Search",
    WEBSEARCH_TAVILY_API_KEY: "Tavily", WEBSEARCH_BRAVE_API_KEY: "Brave Search", WEBSEARCH_PERPLEXITY_API_KEY: "Perplexity",
    WEBSEARCH_SEARXNG_URL: "Your own SearXNG" };
  // a switch whose blank value means on (the stack's default; setup writes it): shown on while blank
  const DEFAULT_ON = new Set(["WEBSEARCH_SEARXNG_BUILTIN", "LOCALGIT"]);
  // Settings › Models & providers: a card for each provider. A key's card is its row (providerRow): MODELS, the
  // provider its models have in the snapshot's code_models (the pickers' list: litellm/code-models.tsv), and PICK,
  // where you pick which of them it adds. A provider of another kind (a web search backend) fits the same way: its
  // key's row here — or its switch's —, with ADDS(k) saying what it adds instead of a count of models and OFF what it
  // does while it is off. Your subscriptions' cards: subscriptionsRow.
  // a provider card's key -> the model browser's provider (models.js #modelbrowser/<provider>)
  const BROWSE_PROVIDER = { AWS_ACCESS_KEY_ID: "bedrock", OPENROUTER_API_KEY: "openrouter", EXPLABS_API_KEY: "explabs" };
  const PROVIDERS = {
    AWS_ACCESS_KEY_ID: { models: "Bedrock", pick: ["+models", "Models your key can use"] },
    OPENROUTER_API_KEY: { models: "OpenRouter", pick: ["OPENROUTER_MODELS", "OpenRouter's models"] },
    EXPLABS_API_KEY: { models: "Experiential Labs", pick: ["EXPLABS_MODELS", "the gateway's models"] },
    // Search: Claude Code's WebSearch (lib/websearch.sh; the snapshot's choices.websearch) — the backend it searches
    // with now, then a card for each backend: the built-in SearXNG (the default, its switch), AWS's own, your own key's,
    // then your own SearXNG. Each card's info button (wsInfo) says what a search costs, what is sent, how steady and
    // private it is, and where its key comes from.
    WEBSEARCH_BACKEND: { on: () => Boolean(webSearch().backend), state: wsChoiceState, adds: wsChoiceAdds, off: wsChoiceOff, button: ["Change", "Change"] },
    WEBSEARCH_SEARXNG_BUILTIN: wsCard("builtin", "the built-in SearXNG, and on to public search engines", "free"),
    WEBSEARCH_AGENTCORE_GATEWAY: wsCard("agentcore", "Amazon's web index, inside AWS", "$7 per 1,000 searches, on your AWS bill", ["Change gateway", "Set the gateway"]),
    WEBSEARCH_TAVILY_API_KEY: wsCard("tavily", "tavily.com", "about $0.008 a search at its list price"),
    WEBSEARCH_BRAVE_API_KEY: wsCard("brave", "search.brave.com", "about $0.005 a search at its list price"),
    WEBSEARCH_PERPLEXITY_API_KEY: wsCard("perplexity", "perplexity.ai", "about $0.005 a search at its list price"),
    WEBSEARCH_SEARXNG_URL: wsCard("searxng", "your SearXNG, and on to the search engines it asks", "free", ["Change URL", "Add its URL"]),
  };
  // the head over a group of a section's rows, before the first of them: the keys, your subscriptions (and a Search
  // group next to them, for a web search backend's card)
  const GROUP_HEAD = { AWS_ACCESS_KEY_ID: "Keys", "+subscriptions": "Subscriptions", WEBSEARCH_BACKEND: "Search", "+local-models": "Local models" };
  // where a row moved to (Settings › Models & providers), said at the top of its old section with a link
  const MOVED = { aws: [["AWS_ACCESS_KEY_ID", "The AWS key", "Models & providers › Bedrock"]],
    chat: [["OPENROUTER_API_KEY", "OpenRouter's and Experiential Labs' keys and models", "Models & providers"]],
    code: [["+subscriptions", "Your AI subscriptions and Use my Claude plan", "Models & providers"]] };

  let data = null;          // GET /api/settings
  let spend = null;         // /api/summary's spend (budget rows)
  let keys = {};            // KEY -> snapshot row
  let sections = [];        // [{id, title, lede, doc}]
  let rowOf = {};           // KEY or +own -> layout row {key, section, place, parent, summary}
  let withOf = {};          // KEY -> [the keys shown inside its row]
  let current = "";         // the section shown
  let pending = null;       // {kind: "apply"|"reveal"|"action"|"signout", ...} waiting for the password
  let watching = null;      // {id, kind, label, keys, at} a request the helper has not finished
  let pollTimer = null;
  let reconnecting = false;
  let findText = new Map(); // row element -> what the search looks through (lower case)
  // the page's search box and "Changed from default" (P-5): kept across a re-render
  const find = { q: "", changed: false };

  const page = () => $("#settings");
  const hasHelper = () => Boolean(data && data.helper.running && data.helper.settings);
  const canChange = () => hasHelper() && data.here.allowed;
  const pad2 = (n) => String(n).padStart(2, "0");
  const lower = (x) => String(x || "").trim().toLowerCase();
  const hourRange = (h) => `${pad2(h)}:00–${pad2((h + 3) % 24)}:00`;
  const plain = (k) => k.secret === "-" || k.secret === "s";
  const sectionOf = (id) => sections.find((s) => s.id === id);

  // --- data ---
  let loading = null;
  function load() {   // one request at a time: the tab switch and the page's own start may both ask
    // aria-busy while it loads: the page is drawn anew when /api/settings answers (assistive technology, and the e2e
    // checks, wait for that rather than act on rows about to be replaced)
    if (!loading) {
      const p = page();
      if (p) p.setAttribute("aria-busy", "true");
      loading = loadNow().finally(() => { loading = null; if (p) p.removeAttribute("aria-busy"); });
    }
    return loading;
  }
  async function loadNow() {
    try {
      data = await api("/api/settings");
    } catch (e) {
      if (e.message === "signed out") return;
      showError(`Could not load the settings (${e.message}). ./stack status shows what is running.`);
      return;
    }
    keys = {};
    for (const k of (data.snapshot && data.snapshot.keys) || []) keys[k.key] = k;
    updating = isUpdating(data.helper.in_progress, data.helper.job);
    buildLayout();
    render();
    renderNotice();
    const j = data.helper.job;   // a change or diagnostic still running (updates show on Home)
    if (data.helper.in_progress && j && !watching && (j.action === "settings" || DIAG_PHASES.includes(j.action) || /^restart-/.test(j.action))) {
      watch({ id: j.id, kind: j.action, at: Date.now() - 60000 });
    }
    // this month's spend per key (next to the budgets): only while Settings is shown (the Home notice needs none)
    if (page() && !page().hidden) try { spend = (await api("/api/summary")).spend; renderSpend(); } catch (_) { /* budgets still show */ }
  }

  // Without catalog/settings-layout.tsv (a damaged checkout): one section of ordinary rows, every setting changeable as
  // its policy allows, the halves of a pair and the values a row shows inside it as before the sections existed
  const FALLBACK_WITH = { AWS_SECRET_ACCESS_KEY: "AWS_ACCESS_KEY_ID", STT_API_KEY: "STT_PROVIDER", STT_MODEL: "STT_PROVIDER",
    PORTAL_PASSWORD_HASH: "PORTAL_PASSWORD", RUSTFS_SECRET_KEY: "RUSTFS_ACCESS_KEY", OWUI_DEFAULT_MODEL: "CHAT_DEFAULT_MODEL",
    OWUI_TASK_MODEL: "CHAT_TASK_MODEL", CLAUDE_BEDROCK_OPUS_MODEL: "CLAUDE_MODEL_OPUS", CLAUDE_BEDROCK_SONNET_MODEL: "CLAUDE_MODEL_SONNET",
    CLAUDE_BEDROCK_HAIKU_MODEL: "CLAUDE_MODEL_HAIKU", LITELLM_KEY_CLAUDE_CODE: "BUDGET_CLAUDE_CODE", LITELLM_KEY_OPENWEBUI: "BUDGET_OPENWEBUI",
    LITELLM_KEY_SETUP: "BUDGET_SETUP", LITELLM_KEY_TERMINAL: "BUDGET_TERMINAL" };
  function fallbackLayout() {
    const rows = Object.keys(keys).map((k) => (FALLBACK_WITH[k] && keys[FALLBACK_WITH[k]]
      ? { key: k, section: "all", place: "with", parent: FALLBACK_WITH[k], summary: "" } : { key: k, section: "all", place: "main", parent: "", summary: "" }));
    for (const own of ["+devices", "+models", "+backups", "+test", "+check-aws", "+report", "+restart", "+git-hosts", "+project-folders", "+sessions-consent", "+bring-setup", "+subscriptions", "+services"]) rows.push({ key: own, section: "all", place: "main", parent: "", summary: "" });
    return { sections: [{ id: "all", title: "All settings", lede: "The page's layout (catalog/settings-layout.tsv) could not be read: every setting in one list.", doc: "" }], rows };
  }

  // The layout from catalog/settings-layout.tsv; a key it does not name (one of yours in .env) goes to Advanced.
  function buildLayout() {
    let l = data.layout || {};
    if (!(l.sections || []).length) l = fallbackLayout();
    sections = l.sections.slice();
    rowOf = {}; withOf = {};
    for (const r of l.rows || []) if (sectionOf(r.section)) rowOf[r.key] = r;
    const fallback = sectionOf("advanced") ? "advanced" : sections[sections.length - 1].id;
    for (const k of Object.keys(keys)) if (!rowOf[k]) rowOf[k] = { key: k, section: fallback, place: "main", parent: "", summary: "" };
    for (const r of Object.values(rowOf)) if (r.place === "with" && r.parent) (withOf[r.parent] = withOf[r.parent] || []).push(r.key);
  }
  const rowsIn = (id) => Object.values(rowOf).filter((r) => r.section === id && r.place !== "with");

  // A switch that is on: true or on; for other values, set and not off (REMOTE_MODE: tailscale or domain)
  function isOn(key) {
    const k = keys[key];
    if (!k) return false;
    if (key === "REMOTE_PREVIEW") return remotePreviewOn();
    if (!plain(k)) return Boolean(k.set);
    const v = lower(k.value);
    return v !== "" && !OFF_VALUES.includes(v);
  }
  // a switch's own value is on (true or on), whatever it shows
  const switchedOn = (k) => Boolean(k && ["bool", "on_off", "true_blank"].includes(k.validator) && ON_VALUES.includes(lower(k.value)));
  // shown in its section: its parent switch (and that one's parent) is on
  function parentsOn(r, depth = 0) {
    if (!r || !r.parent || depth > 5) return true;
    return isOn(r.parent) && parentsOn(rowOf[r.parent], depth + 1);
  }
  function offParent(r, depth = 0) {   // -> the first switch above r that is off, else null
    if (!r || !r.parent || depth > 5) return null;
    if (!isOn(r.parent)) return r.parent;
    return offParent(rowOf[r.parent], depth + 1);
  }

  function showError(msg) {
    const p = page(); if (!p) return;
    let b = $("#set-error", p);
    if (!b) { b = el("p", { id: "set-error", class: "banner", role: "alert" }); p.prepend(b); }
    b.textContent = msg; b.hidden = !msg;
  }

  // --- the page ---
  function render() {
    const p = page();
    const scrollY = p.scrollTop;
    p.replaceChildren();
    findText = new Map();
    const when = data.snapshot && data.snapshot.written_at ? new Date(data.snapshot.written_at * 1000).toLocaleString() : "";
    p.append(el("header", { class: "home-head set-head" },
      el("p", { class: "eyebrow", "aria-hidden": "true", text: "DevOS ADE · Settings" }),
      el("h1", { id: "settings-title", text: "Settings" }),
      el("p", { class: "updated" }, when ? `As of ${when} ` : "", el("button", { type: "button", class: "quiet", id: "set-reload", text: "Reload" }))));
    $("#set-reload", p).addEventListener("click", load);
    if (!data.available) {
      p.append(el("p", { class: "banner", text: "Settings are not available yet: run ./stack up once (it writes .state/status/settings.json, the masked copy of .env this page shows)." }));
      return;
    }
    p.append(updatingBox(), helperBox(), jobBox(), findBar(), picker());
    const cards = el("div", { class: "set-cards" });
    for (const s of sections) cards.append(card(s));
    p.append(el("div", { class: "set-layout" }, sectionNav(), cards));
    if (!current || !sectionOf(current)) current = initialSection();
    renderSpend();
    renderJob();
    applyView();
    p.scrollTop = scrollY;
  }

  // An update or a rollback running (the helper's job): this list is rewritten when it ends — said at the top, and the
  // list is loaded again then (app.js's job poll tells us: bn:admin)
  let updating = false;
  const isUpdating = (inProgress, j) => Boolean(inProgress && j && (j.action === "update" || j.action === "rollback"));
  function updatingBox() {
    const b = el("p", { id: "settings-updating", class: "banner", role: "status",
      text: "An update is finishing: new settings appear when it's done." });
    b.hidden = !updating;
    return b;
  }
  function setUpdating(now) {
    const was = updating;
    updating = now;
    const b = $("#settings-updating");
    if (b) b.hidden = !updating;
    if (was && !now) load();   // it ended: the settings it wrote
  }
  document.addEventListener("bn:admin", (e) => { const a = e.detail || {}; setUpdating(isUpdating(a.in_progress, a.job)); });

  function initialSection() {
    let memo = null;
    try { memo = localStorage.getItem(SECTION_MEMO); } catch (_) { /* storage blocked: the first section */ }
    return sectionOf(memo) ? memo : sections[0].id;
  }

  // the section list (desktop): Diagnostics, Advanced and About apart from the rest
  function sectionNav() {
    const list = el("ul", {});
    for (const s of sections) {
      // (Diagnostics, Advanced and About apart: a rule above Diagnostics' item — the list holds list items only)
      const b = el("button", { type: "button", class: "set-nav-item", "data-section": s.id, text: s.title });
      b.addEventListener("click", (ev) => showSection(s.id, { focus: ev.detail === 0 }));
      list.append(el("li", s.id === "diagnostics" ? { class: "set-nav-split" } : {}, b));
    }
    return el("nav", { class: "set-nav", "aria-label": "Settings sections" }, list);
  }
  // the section picker (phones): the system's own list
  function picker() {
    const sel = el("select", { id: "set-picker", class: "set-picker-select" });
    for (const s of sections) sel.append(el("option", { value: s.id, text: s.title }));
    sel.addEventListener("change", () => showSection(sel.value));
    return el("div", { class: "set-picker" }, el("label", { for: "set-picker", text: "Section" }), sel);
  }

  // showSection ID — that section alone (and the address: #settings/ and its id); a search in progress is cleared
  function showSection(id, opts = {}) {
    if (!sectionOf(id)) return;
    current = id;
    try { localStorage.setItem(SECTION_MEMO, id); } catch (_) { /* fine */ }
    for (const d of document.querySelectorAll("#settings .set-forced")) d.classList.remove("set-forced");   // (goTo's)
    if (find.q || find.changed) {
      find.q = ""; find.changed = false;
      const input = $("#set-find"); if (input) input.value = "";
      const chip = $("#set-changed"); if (chip) chip.setAttribute("aria-pressed", "false");
    }
    applyView();
    const p = page();
    if (p && !p.hidden && opts.address !== false && location.hash.startsWith("#settings")) history.replaceState(null, "", `#settings/${id}`);
    if (p && opts.scroll !== false) p.scrollTop = 0;
    if (opts.focus) { const h = $(`#set-${id}-title`); if (h) h.focus({ preventScroll: true }); }
  }

  // goTo PLACE — "section", "KEY" or "section/KEY" from the address: the section, and the setting opened (More
  // unfolded, a setting whose switch is off shown anyway), scrolled to and highlighted — a setting's own switch focused
  // when it has one (a greyed item elsewhere links here: catalog/setup-links.tsv); a setting shown inside another row:
  // that row, at the setting (its [data-for]), its switch focused; a row of the page's own: the row itself
  function goTo(place) {
    let sec = null, key = null;
    for (const part of String(place || "").split("/")) {
      if (sectionOf(part)) sec = part;
      else if ((KEY_NAME.test(part) || /^\+[a-z-]{2,20}$/.test(part)) && rowOf[part]) key = part;
    }
    const inner = key && rowOf[key].place === "with" && rowOf[rowOf[key].parent] ? key : null;
    if (inner) key = rowOf[key].parent;
    if (key) sec = rowOf[key].section;
    if (!sec) return;
    showSection(sec, { address: false, scroll: !key });
    if (!key) return;
    const r = $(`#settings .set-card .set-row[data-key="${key}"], #settings .set-card .set-adv-item[data-key="${key}"], #settings .set-card .set-row[data-own="${key}"]`);
    if (!r) return;
    const more = r.closest("details.set-more");
    if (more) more.open = true;
    const tab = r.closest(".set-tabbed > [data-group]");
    if (tab) showGroup(tab.parentElement, tab.dataset.group);
    for (let d = r.closest(".set-dep"); d; d = d.parentElement.closest(".set-dep")) d.classList.add("set-forced");
    applyView();
    // what takes the focus: a Chat sign-in asked for (Sign in for Chat…: that tool's Chat row, its Sign in); else the
    // setting — its switch, when it has one: a setting's own row, or a setting shown inside a row ([data-for]); a row
    // of the page's own (Your AI subscriptions …) is focused as a whole, never a switch inside it
    const chat = chatAsk.take(key === "+subscriptions" && !inner);
    const signin = chat ? r.querySelector(`#set-subs-chat-${chat} [data-act="subscriptions-chat-signin"]`) : null;
    const at = signin ? signin.closest(".set-subs-where") : (inner && r.querySelector(`[data-for="${inner}"]`)) || r;
    const sw = !signin && (inner || !key.startsWith("+")) ? at.querySelector('button[role="switch"]:not(:disabled)') : null;
    at.setAttribute("tabindex", "-1");
    at.scrollIntoView({ block: "center" });
    (signin || sw || at).focus({ preventScroll: true });
    at.classList.add("set-flash");
    setTimeout(() => at.classList.remove("set-flash"), 2400);
  }
  // A Chat sign-in asked for from Chat's picker (answers.js sets window.bnSubsChatSignin, then goes to
  // #settings/+subscriptions): taken once, by that arrival alone — goTo at Your AI subscriptions with nothing inside it
  // named — which focuses that tool's Sign in; its command stays shown through the page's redraws for a few seconds
  // from then. Any other arrival (#settings/CODE_CLAUDE_PLAN, a row inside it, too), or leaving Settings, drops it.
  // chatAsk:begin
  const chatAsk = {
    tool: "", until: 0,
    asked() { const w = window.bnSubsChatSignin; return typeof w === "string" && /^[a-z]{2,10}$/.test(w) ? w : ""; },
    // (the subscriptions row as it is drawn: the tool whose command shows — asked for, or taken a moment ago)
    shown() { return this.asked() || (this.tool && Date.now() < this.until ? this.tool : ""); },
    // (goTo: the tool whose Sign in takes the focus — only when this arrival is the one asked for; else dropped)
    take(here) {
      const w = this.asked();
      window.bnSubsChatSignin = "";
      this.drop();
      if (!here || !w) return "";
      this.tool = w; this.until = Date.now() + 5000;
      return w;
    },
    drop() { this.tool = ""; this.until = 0; },
  };
  // chatAsk:end

  // --- what is shown: one section, or every match of the search / "Changed from default" with its section ---
  function changedFromDefault(k) {
    if (!k || !("value" in k) || !("default" in k) || !(k.secret === "-" || k.secret === "s")) return false;
    const v = String(k.value).trim();
    return v !== "" && v !== String(k.default).trim();
  }
  function findBar() {
    const input = el("input", { type: "search", id: "set-find", class: "set-find-input", placeholder: "Search settings", "aria-label": "Search settings",
      maxlength: "100", value: find.q });
    input.value = find.q;
    input.addEventListener("input", () => { find.q = input.value.slice(0, 100); applyView(); });
    const chip = el("button", { type: "button", class: "chip", id: "set-changed", "aria-pressed": String(find.changed), text: "Changed from default" });
    chip.addEventListener("click", () => { find.changed = !find.changed; chip.setAttribute("aria-pressed", String(find.changed)); applyView(); });
    const clear = el("button", { type: "button", class: "quiet", id: "set-find-clear", text: "Clear", hidden: "" });
    clear.addEventListener("click", () => showSection(current, { scroll: false }));
    const known = Object.values(keys).some((k) => "default" in k);
    return el("div", { class: "set-find", role: "search" }, input, chip,
      el("span", { class: "note set-find-note", id: "set-find-note", "aria-live": "polite", text: known ? "" : "Defaults are not known yet: ./stack up writes them." }), clear);
  }
  function rowMatches(r, q) {
    // the row's key and the ones shown inside it, except values ./stack derives (setup's model choices differ from
    // .env.example's blank on every install: they are no change of yours)
    // (a row of the page's own counts by the settings shown inside it: the Claude plan switch in Your AI subscriptions)
    const at = r.dataset.key || r.dataset.own;
    const keyNames = [r.dataset.key, ...(withOf[at] || []).filter((w) => keys[w] && keys[w].policy !== "derived")].filter(Boolean);
    const okChanged = !find.changed || keyNames.some((n) => changedFromDefault(keys[n]));
    return okChanged && (!q || (findText.get(r) || "").includes(q));
  }
  function applyView() {
    const p = page();
    if (!p || !data || !data.available) return;
    const q = find.q.trim().toLowerCase();
    const finding = Boolean(q) || find.changed;
    p.classList.toggle("set-finding", finding);
    let shownRows = 0, shownCards = 0;
    for (const c of p.querySelectorAll(".set-card")) {
      let left = 0;
      // a block: one setting and the ones that belong to it. Innermost first: a block shows when its setting matches
      // or one inside it does (its setting then dimmed, as context). A setting whose switch is off: hidden, unless
      // searching or opened by an address (then "Applies while … is on" says why it does nothing now).
      for (const d of [...c.querySelectorAll(".set-dep")].reverse()) {
        const own = d.querySelector(":scope > .set-row, :scope > .set-adv-item");
        const off = Boolean(d.dataset.parent) && !parentsOn(rowOf[d.dataset.key]);
        // a switch of its own that is on stays in sight while its parent is off (Bypass allowed, the Code page off):
        // it takes effect again the moment the parent is on
        const selfOn = off && switchedOn(keys[d.dataset.key]);
        d.classList.toggle("set-dep-off", off);
        d.classList.toggle("set-dep-on", selfOn);
        if (!finding) {
          d.hidden = off && !selfOn && !d.classList.contains("set-forced");
          if (own) own.classList.remove("set-ghost");
          continue;
        }
        const hit = Boolean(own) && rowMatches(own, q);
        const inner = [...d.querySelectorAll(":scope > .set-children > .set-dep")].some((x) => !x.hidden);
        if (hit) left++;
        d.hidden = !(hit || inner);
        if (own) own.classList.toggle("set-ghost", !hit && inner);
      }
      for (const m of c.querySelectorAll("details.set-more")) {
        const n = [...m.querySelectorAll(".set-dep")].filter((d) => !d.hidden && !d.parentElement.closest(".set-dep[hidden]")).length;
        $(".set-more-count", m).textContent = finding ? "" : `(${n})`;
        m.hidden = n === 0;
        if (finding && n) {
          if (!("wasOpen" in m.dataset)) m.dataset.wasOpen = m.open ? "1" : "";
          m.open = true;
        } else if (!finding && "wasOpen" in m.dataset) {
          m.open = m.dataset.wasOpen === "1";
          delete m.dataset.wasOpen;
        }
      }
      const show = finding ? left > 0 : c.dataset.section === current;
      c.hidden = !show;
      if (show) shownCards++;
      shownRows += left;
    }
    for (const b of p.querySelectorAll(".set-nav-item")) {
      if (!finding && b.dataset.section === current) b.setAttribute("aria-current", "true"); else b.removeAttribute("aria-current");
    }
    const sel = $("#set-picker", p); if (sel) sel.value = current;
    const note = $("#set-find-note", p), clear = $("#set-find-clear", p);
    if (note && Object.values(keys).some((k) => "default" in k)) {
      note.textContent = finding ? (shownRows ? `${shownRows} setting${shownRows === 1 ? "" : "s"} in ${shownCards} section${shownCards === 1 ? "" : "s"}` : "No setting matches.") : "";
    }
    if (clear) clear.hidden = !finding;
  }

  function helperBox() {
    const box = el("div", { class: "set-helper" });
    if (!data.here.allowed) {
      box.append(el("p", { class: "helper-off-title", text: "Changes are off for remote access" }),
        el("p", { class: "note" }, "Settings, Reveal and Diagnostics work from the computer running DevOS ADE. To use them from your devices too, turn on ",
          el("a", { href: "#settings/REMOTE_ADMIN_ACTIONS", "data-setup": "remote-admin-off", text: "Remote access › Update, settings and diagnostics from your devices" }), " there."));
      box.classList.add("helper-off");
      return box;
    }
    if (hasHelper()) {
      box.hidden = true;
      return box;
    }
    const cmd = "./stack helper install";
    const seen = data.helper.heartbeat_at ? ` (last seen ${new Date(data.helper.heartbeat_at * 1000).toLocaleString()})` : "";
    const title = data.helper.running ? "The update helper needs a refresh to change settings" : `One-click updates are off${seen}`;
    const copyBtn = el("button", { type: "button", class: "copy", text: "Copy" });
    copyBtn.addEventListener("click", () => copy(cmd, "the command"));
    box.classList.add("helper-off");
    box.append(el("p", { class: "helper-off-title", text: title }),
      el("p", { class: "cmdline" }, el("code", { text: cmd }), " ", copyBtn),
      el("p", { class: "note", text: "Everything below is read-only until then: the portal never changes your settings file itself. The update helper (a small job under your user, outside Docker) applies changes, after checking each one again. Or change a setting in a terminal: each one's Details has its command." }));
    return box;
  }

  // --- a section ---
  function card(s) {
    const c = el("section", { class: "set-card", id: `set-${s.id}`, "data-section": s.id, "aria-labelledby": `set-${s.id}-title`, hidden: "" });
    const lede = el("p", { class: "note set-lede", text: s.lede });
    if (s.doc) lede.append(" ", el("a", { href: REPO + s.doc, target: "_blank", rel: "noopener", class: "set-learn", text: "Learn more" }));
    c.append(el("div", { class: "set-card-head" }, el("h2", { id: `set-${s.id}-title`, tabindex: "-1", text: s.title }), lede));
    // (what moved to Models & providers: a line at the top of its old section, with a link to it there)
    for (const [place, what, where] of MOVED[s.id] || []) {
      if (rowOf[place] && rowOf[place].section !== s.id) {
        c.append(el("p", { class: "note set-moved" }, `${what}: `, el("a", { href: `#settings/${place}`, text: where }), "."));
      }
    }
    const all = rowsIn(s.id);
    const main = all.filter((r) => r.place === "main"), more = all.filter((r) => r.place === "more");
    const list = s.id === "advanced" || s.id === "about";
    const body = el("div", { class: list ? "set-rows set-list" : "set-rows" });
    blocks(body, main, list);
    // the read-only lists (Advanced, About this install) show their first rows and fold the rest: a search or an address
    // opens it (More settings' rule), so nothing is out of reach
    const FOLD = 10;
    let fold = null;
    if (list && body.children.length > FOLD + 2) {
      const rest = el("div", { class: "set-rows set-list" });
      rest.append(...[...body.children].slice(FOLD));
      fold = (el("details", { class: "set-more set-fold" }, el("summary", {}, "Show the rest ", el("span", { class: "set-more-count" })), rest));
    }
    // Models & providers is long: its groups (Keys · Subscriptions · Search · Local models) are tabs — one group at a time, so the page
    // is the height of its longest group, not of all three (a search or an address shows what it finds, whichever group)
    const heads = [...body.querySelectorAll(":scope > .set-group-head")];
    if (heads.length > 1) {
      const bar = el("nav", { class: "set-minnav", "aria-label": `${s.title}: its groups` });
      const names = heads.map((h) => h.textContent.toLowerCase());
      let g = names[0];
      for (const ch of body.children) { if (ch.matches(".set-group-head")) g = ch.textContent.toLowerCase(); ch.dataset.group = g; }
      body.classList.add("set-tabbed");
      for (const h of heads) {
        const b = el("button", { type: "button", class: "chip", "data-group": h.textContent.toLowerCase(), "aria-pressed": "false", text: h.textContent });
        b.addEventListener("click", () => showGroup(body, b.dataset.group));
        bar.append(b);
      }
      c.append(bar);
      showGroup(body, names[0], bar);
    }
    c.append(body);
    if (fold) c.append(fold);
    // (About: Send feedback — a link that opens GitHub; static/feedback.js)
    if (s.id === "about" && window.bnFeedback && window.bnFeedback.card) c.append(window.bnFeedback.card("set-feedback"));
    // (under the providers' cards: which of their models each picker lists — Settings' own lists of them)
    if (s.id === "providers") {
      c.append(el("p", { class: "note set-prov-foot" }, "Which of these models each picker lists: ",
        el("a", { href: "#settings/CODE_MODELS", text: "Models for Claude Code" }), " (the Code page and devos-claude) · ",
        el("a", { href: "#settings/MODELS_HIDDEN", text: "Hidden in Chat's model picker" }), " (Chat)."));
    }
    if (s.id === "diagnostics") c.append(el("div", { class: "set-report", id: "set-report", hidden: "" }));
    if (more.length) {
      const inner = el("div", { class: "set-rows" });
      blocks(inner, more, list);
      c.append(el("details", { class: "set-more" }, el("summary", {}, "More settings ", el("span", { class: "set-more-count" })), inner));
    }
    c.append(pager(s.id));
    compact(c);
    return c;
  }

  // showGroup BODY NAME [BAR] — the tab NAME of a tabbed section (Models & providers), its chip pressed: the other groups'
  // blocks marked set-tab-off (hidden unless a search looks through them all), whatever the groups are called
  function showGroup(body, name, bar) {
    if (!body || !body.classList.contains("set-tabbed")) return;
    body.dataset.group = name;
    for (const ch of body.children) ch.classList.toggle("set-tab-off", ch.dataset.group !== name);
    bar = bar || (body.closest(".set-card") && body.closest(".set-card").querySelector(".set-minnav"));
    if (bar) for (const b of bar.querySelectorAll(".chip")) b.setAttribute("aria-pressed", String(b.dataset.group === name));
  }

  // blocks CONTAINER ROWS — each row in a block of its own, followed by the rows that belong to it (indented)
  function blocks(container, rows, list) {
    const here = new Set(rows.map((r) => r.key));
    const made = {};
    for (const r of rows) {
      const node = list ? listItem(r) : rowFor(r);
      if (!node) continue;
      const block = el("div", { class: "set-dep", "data-key": r.key });
      if (r.parent) block.dataset.parent = r.parent;
      if (r.parent && offParent(r)) {   // shown only by a search or an address: why it does nothing now
        const p = keys[offParent(r)] || { label: offParent(r), secret: "-" };
        const name = ROW_LABEL[p.key] || p.label;
        block.append(el("p", { class: "note set-applies", text: plain(p) ? `Applies while ${name} is on.` : PROVIDERS[p.key] ? `Applies once ${name} has a key.` : `Applies once ${name} is set.` }));
      }
      // (a provider's card; the first of a group of rows under its head)
      if (PROVIDERS[r.key]) block.classList.add("set-prov");
      if (GROUP_HEAD[r.key] && r.section === "providers") container.append(el("h3", { class: "set-group-head", id: `set-group-${GROUP_HEAD[r.key].toLowerCase().replace(/ /g, "-")}`, tabindex: "-1", text: GROUP_HEAD[r.key] }));
      block.append(node);
      made[r.key] = block;
      const host = r.parent && here.has(r.parent) && made[r.parent];
      if (host) {
        let kids = host.querySelector(":scope > .set-children");
        if (!kids) { kids = el("div", { class: "set-children" }); host.append(kids); }
        kids.append(block);
      } else {
        container.append(block);
      }
      const k = keys[r.key] || {};
      // its name, summary, note and key, and those of the keys shown inside it (not the section's title: "budget" would
      // then list every setting of Spending & budgets)
      findText.set(node, [k.label || "", ROW_LABEL[r.key] || "", r.summary, k.note || "", r.key.startsWith("+") ? "" : r.key, node.dataset.findExtra || "",
        ...(withOf[r.key] || []).flatMap((w) => [w, (keys[w] || {}).label || ""])].join(" ").toLowerCase());
    }
  }

  function pager(id) {
    const i = sections.findIndex((s) => s.id === id);
    const nav = el("nav", { class: "set-pager", "aria-label": "Other sections" });
    for (const [j, cls, txt] of [[i - 1, "set-prev", (t) => `← ${t}`], [i + 1, "set-next", (t) => `${t} →`]]) {
      const s = sections[j];
      if (!s) { nav.append(el("span", {})); continue; }
      const b = el("button", { type: "button", class: `quiet ${cls}`, text: txt(s.title) });
      b.addEventListener("click", (ev) => showSection(s.id, { focus: ev.detail === 0 }));
      nav.append(b);
    }
    return nav;
  }

  // rowFor LAYOUT-ROW -> the row of one setting (or of one of the page's own rows), or null
  function rowFor(r) {
    const own = { "+devices": sessionsRow, "+models": modelsRow, "+backups": backupRow, "+test": actionRow, "+check-aws": actionRow,
      "+report": actionRow, "+restart": restartRow, "+git-hosts": gitHostsRow, "+project-folders": projectFoldersRow,
      "+sessions-consent": sessionsConsentRow, "+bring-setup": bringSetupRow,
      "+subscriptions": subscriptionsRow, "+services": servicesRow, "+local-models": localModelsRow };
    if (r.key.startsWith("+")) return own[r.key] ? own[r.key](r) : null;
    const k = keys[r.key];
    if (!k) return null;
    if (r.key === "STT_PROVIDER") return voiceRow(r);
    if (r.key === "CODE_ENABLED") return codeRow(r);
    if (r.key === "TERMINAL_ENABLED") return terminalRow(r);
    if (r.key === "REMOTE_MODE") return remoteStatus(r);
    if (PROVIDERS[r.key]) return providerRow(k, r);
    return row(k, r);
  }

  // --- one setting ---
  function shown(k) {
    if (!k.present && !k.set) return "not set";
    if ("value" in k) return k.value === "" ? "blank" : k.value;
    if (k.hint) return k.hint;
    return k.set ? "set" : "not set";
  }

  // REMOTE_PREVIEW shown as it takes effect: On only while the stack serves previews over remote access — it wrote their
  // address, REMOTE_PREVIEW_HOST (lib/code.sh code_remote_sync, which also checks a REMOTE_PREVIEW_DOMAIN) — so never On
  // while they are off. A change that may turn them on (true; or blank in own-domain mode with a preview domain of its
  // own) is less protection: lib/settings.sh setting_weakens.
  function remotePreviewOn() { return Boolean(keys.REMOTE_PREVIEW_HOST && keys.REMOTE_PREVIEW_HOST.value); }
  function remotePreviewMayBeOn(v) {
    if (ON_VALUES.includes(lower(v))) return true;
    if (OFF_VALUES.includes(lower(v))) return false;
    return Boolean(keys.REMOTE_MODE && keys.REMOTE_MODE.value === "domain" && keys.REMOTE_PREVIEW_DOMAIN && keys.REMOTE_PREVIEW_DOMAIN.value);
  }
  // Default model for new sessions left blank: Claude Sonnet (the Sonnet slot), the main model only without one —
  // never Opus by default (lib/code_models.sh code_models_start)
  function codeDefaultAuto() {
    const sonnet = keys.CLAUDE_BEDROCK_SONNET_MODEL ? shown(keys.CLAUDE_BEDROCK_SONNET_MODEL) : "";
    if (sonnet && sonnet !== "blank" && sonnet !== "not set") return `${modelName(sonnet)} (Claude Sonnet)`;
    return `${modelName(keys.CLAUDE_BEDROCK_OPUS_MODEL ? shown(keys.CLAUDE_BEDROCK_OPUS_MODEL) : "")} (the main model: no Sonnet enabled)`;
  }
  // what a blank value means (the stack's own default), for the keys whose default is not .env.example's value
  const BLANK = { PORTAL_SESSION_DAYS: "30 days", BUDGET_ALERT_PCT: "80%", BACKUP_HOUR: hourRange(2), BACKUP_KEEP: "7",
    AUTO_UPDATE_HOUR: hourRange(3), OPENROUTER_MODELS: "all", OPENROUTER_MAX_MODELS: "1000", EXPLABS_MODELS: "qwen3.8-27b",
    TERMINAL_EGRESS: "Internet only",
    WEBSEARCH_BACKEND: "automatic: the first one you set up, else the built-in SearXNG", TERMINAL_MEM_LIMIT: "4g", TERMINAL_AI_TOOLS: "all", REMOTE_MODE: "off", AWS_AUTH: "an access key", REMOTE_SUBNET: "10.255.255.248/29",
    PORTAL_HOST: "bedrock-now.localhost", PORTAL_PORT: "80, else 8800", CHAT_HOST: "chat. + the portal's address",
    ADMIN_HOST: "admin. + the portal's address", FILES_HOST: "files. + the portal's address",
    TERMINAL_HOST: "terminal. + the portal's address", CODE_HOST: "code. + the portal's address",
    CODE_MODELS: "every enabled model", CODE_DEFAULT_MODEL: "Claude Sonnet (the Sonnet slot)" };
  // display K -> the value in words: "$50 a month", "30 days (default)", "On", "Not set", "••••••••"
  function display(k) {
    const v = shown(k);
    if (k.key === "REMOTE_PREVIEW") return remotePreviewOn() ? "On" : "Off";
    // (never chosen: the next setup or update turns it on — lib/code.sh code_default_on)
    if (k.key === "CODE_ENABLED" && (v === "blank" || v === "not set")) return "Off (on by default: the next setup or update turns it on)";
    if (k.validator === "bool" || k.validator === "true_blank") return v === "true" ? "On" : "Off";
    if (k.validator === "on_off") return v === "on" || (DEFAULT_ON.has(k.key) && (v === "blank" || v === "not set")) ? "On" : "Off";
    if (k.validator === "egress") return EGRESS_LABEL[egressMode(k.value)];
    if (k.secret === "S") return k.set ? "••••••••" : "Not set";
    if (!plain(k)) return v === "not set" ? "Not set" : v === "set" ? "Set" : v;
    if (v === "blank" || v === "not set") return BLANK[k.key] ? `${BLANK[k.key]} (default)` : "Not set";
    if (["TERMINAL_ENABLED", "REMOTE_TERMINAL", "OWUI_HYBRID_SEARCH", "OWUI_ENABLE_IMAGES", "LITELLM_DB_ADMIN_READY"].includes(k.key)) return v === "true" ? "On" : "Off";
    if (k.validator === "budget") return `$${v} a month`;
    if (k.validator === "days") return `${v} day${v === "1" ? "" : "s"}`;
    if (k.validator === "pct") return `${v}%`;
    if (k.validator === "hour" && /^\d+$/.test(v)) return hourRange(Number(v));
    if (k.validator === "code_models") return codeModelsWords(v);
    if (k.validator === "code_model") return modelName(v);
    return v;
  }

  function editable(k) { return ["edit", "local", "on-only", "widen-local"].includes(k.policy); }
  // lib/settings.sh setting_weakens: the less protective direction of a widen-local key
  function weakens(k, v) {
    const old = "value" in k ? k.value : "";
    const n = (x, lo, hi, d) => (/^\d{1,3}$/.test(x || "") && Number(x) >= lo && Number(x) <= hi ? Number(x) : d);   // _eff_int
    const usd = (x) => (/^(\d*\.?\d+|\d+\.)$/.test(x || "") ? Number(x) : { BUDGET_CLAUDE_CODE: 200, BUDGET_OPENWEBUI: 50, BUDGET_TERMINAL: 50 }[k.key] || 5);
    if (k.key === "BACKUP_KEEP") return n(v, 1, 60, 7) < n(old, 1, 60, 7);
    if (k.key === "PORTAL_SESSION_DAYS") return n(v, 1, 90, 30) > n(old, 1, 90, 30);
    if (k.key === "BUDGET_ALERT_PCT") return n(v, 50, 99, 80) > n(old, 50, 99, 80);
    if (/^BUDGET_(CLAUDE_CODE|OPENWEBUI|SETUP|TERMINAL)$/.test(k.key)) return usd(v) > usd(old);
    if (k.key === "BACKUP_NIGHTLY" || k.key === "AUTO_UPDATE") return v !== "on" && old === "on";
    if (k.key === "UPDATE_CHECK") return v === "false" && old !== "false";
    if (k.key === "REMOTE_PREVIEW") return remotePreviewMayBeOn(v) && !ON_VALUES.includes(lower(old));
    if (k.key === "TERMINAL_EGRESS") return EGRESS_RANK[egressMode(v)] > EGRESS_RANK[egressMode(old)];
    return v === "true" && old !== "true";
  }
  // TERMINAL_EGRESS as the stack reads it (lib/common.sh egress_mode; portal/portal/settings.py egress_mode): host, off
  // (false/0/no/off), else internet — the default (blank, and the old on values)
  function egressMode(v) { const s = lower(v); return s === "host" ? "host" : OFF_VALUES.includes(s) ? "off" : "internet"; }
  const EGRESS_RANK = { off: 0, internet: 1, host: 2 };
  const EGRESS_LABEL = { internet: "Internet only (not this computer's services)", host: "Internet and this computer's services", off: "Off" };
  const EGRESS_WHAT = {
    internet: "The sandbox reaches public internet addresses (npm, pip, git, documentation, Claude Code's web fetch) through its egress proxy, on ports 80, 443 and 22 — never this computer's own services, your local network or private addresses. The terminal restarts (about 10 s; its shells and open Code sessions end).",
    host: "The sandbox itself goes on the internet, and reaches this computer's own services with it — on Docker Desktop the model gateway, the shared MCP server, the portal's login and dev servers on its 127.0.0.1, through Docker's host address — and your local network, on any port: how v0.10.0 and earlier worked. Choose it only for a service of this computer or your network that the sandbox needs. The terminal restarts (about 10 s; its shells and open Code sessions end).",
    off: "The sandbox gets no internet: only the model gateway and the shared MCP server through its gateway (npm, pip and git clone stop working there). The terminal restarts (about 10 s; its shells and open Code sessions end)." };
  // Settings › Claude Code › Sandbox internet access: Internet only · + this computer · Off (opening it further: only here)
  function egressChoice(k) {
    const cur = egressMode(k.value);
    const g = el("div", { class: "chips seg set-seg", role: "group", "aria-labelledby": `set-name-${k.key}` });
    for (const [val, label] of [["internet", "Internet only"], ["host", "+ this computer"], ["off", "Off"]]) {
      const b = el("button", { type: "button", class: "chip", "aria-pressed": String(val === cur), text: label, "data-value": val });
      b.disabled = !canChange() || (val !== cur && localOnlyHere(k, val));
      b.addEventListener("click", () => { if (val !== cur) confirmApply({ [k.key]: val }, `${k.label}: ${EGRESS_LABEL[val]}`, EGRESS_WHAT[val], [k.key]); });
      g.append(b);
    }
    const wrap = el("div", { class: "set-toggle" }, g);
    if (data.here.remote && cur !== "host") wrap.append(el("span", { class: "note", text: "Opening it further only from the computer running DevOS ADE." }));
    return wrap;
  }
  // portal/portal/settings.py _WEAKEN_WORD: how the less protective direction is said
  const WEAKEN_WORD = { BACKUP_KEEP: "lowered", BACKUP_NIGHTLY: "turned off", PORTAL_SESSION_DAYS: "made longer", BUDGET_ALERT_PCT: "raised",
    BUDGET_CLAUDE_CODE: "raised", BUDGET_OPENWEBUI: "raised", BUDGET_SETUP: "raised", BUDGET_TERMINAL: "raised", AUTO_UPDATE: "turned off",
    UPDATE_CHECK: "turned off", TERMINAL_EGRESS: "opened further" };
  function localOnlyHere(k, value) {
    if (!data.here.remote) return false;
    return k.policy === "local" || (k.policy === "widen-local" && weakens(k, value));
  }
  // The Code page runs in the browser terminal's sandbox: with the terminal off, turning it on turns the terminal on
  // too, with the folder ./stack names in the snapshot (choices.code_workspace; settings_check_batch checks it)
  const terminalOn = () => Boolean(keys.TERMINAL_ENABLED && keys.TERMINAL_ENABLED.value === "true");
  const codeOn = () => Boolean(keys.CODE_ENABLED && keys.CODE_ENABLED.value === "true");
  const codeFolder = () => terminalOn() ? (keys.TERMINAL_WORKSPACE && keys.TERMINAL_WORKSPACE.value) || ""
    : (data.snapshot && data.snapshot.choices.code_workspace) || "";

  // (NAME: its name for a screen reader where a page shows more than one of the kind — "Copy Codex's Chat sign-in command")
  function copyButton(cmd, name) {
    const b = el("button", { type: "button", class: "copy", text: "Copy" });
    if (name) b.setAttribute("aria-label", name);
    b.addEventListener("click", () => copy(cmd.replace(/\s+\(.*\)$/, ""), "the command"));
    return b;
  }
  // (NAME: its Copy button's name, where the row has another Copy — copyButton)
  function cliLine(k, lead, name) {
    const cmd = k.cli || `./stack config set ${k.key}`;
    return el("p", { class: "set-cli" }, el("span", { class: "note", text: lead || (editable(k) ? "In a terminal: " : "Change it in a terminal: ") }),
      el("code", { text: cmd }), " ", copyButton(cmd, name));
  }

  // the badges next to a setting's name: from where it may change, that it is secret or read-only, what it restarts
  function badges(k) {
    const out = el("span", { class: "set-badges" });
    const add = (text, cls, title) => out.append(el("span", { class: `badge ${cls}`, text, ...(title ? { title } : {}) }));
    if (k.policy === "local") add("This computer only", "badge-local", "Changed only from the computer running DevOS ADE: from your devices it could send your data elsewhere.");
    if (k.policy === "on-only") add("On only", "badge-local", "Can be turned on here; turning it off is a terminal step.");
    if (k.secret === "S" || k.secret === "h") add("Secret", "badge-secret");
    if (k.policy === "ro" || k.policy === "derived") add("Read-only", "badge-ro");
    if (editable(k) || k.policy === "regen") {
      const what = [...new Set(String(k.apply || "").split(",").flatMap((a) => RESTARTS[a] || []))];
      if (k.key === "CODE_ENABLED") add("Builds the Code page", "badge-restart");
      else if (LIVE.has(k.key)) add("No restart", "badge-live", "Applied in seconds: the model gateway takes the new model list as it runs");
      else if (what.length) add(`Restarts ${what.join(", ")}`, "badge-restart", "What a change restarts, for about 10-20 s");
    }
    return out;
  }

  // A setting's footer for the terminal (in its Details): its name in .env (and the keys shown inside its row) and, when
  // given, the command line — the key names only here, where a terminal command is shown
  function forTerminal(names, ...more) {
    return el("div", { class: "set-term" }, el("p", { class: "set-term-head", text: "For the terminal" }),
      el("p", { class: "note set-envkey" }, "In .env: ", el("code", { text: names.join(" · ") })), ...more);
  }

  // Phones: a section is a short list of cards. Each row keeps its name, its state and value and its control; what
  // explains it — the summary line, its badges, notes, what a provider adds, the terminal command — folds under its
  // Details (the same disclosure as everywhere; a row without one gets one). Anything holding a control stays where
  // it is (a card's Sign in, a list of folders): only its words fold, inside it.
  const PHONE = window.matchMedia("(max-width: 767.98px)");
  const CONTROL = "button, select, input, textarea, [role=switch], a.action";
  const KEEP = ".set-label, .set-value, .set-spend, .release-line, .set-applies, .set-toggle, .set-remote, .set-form, .set-actions, .set-details, .set-children, .set-term, .set-ws-info";
  const ALWAYS = ".set-cli, .cmdline";   // (a terminal command and its Copy: words for the terminal, folded with them)
  function foldInto(host, nodes) {
    if (!nodes.length) return;
    let d = host.querySelector(":scope > details.set-details");
    if (!d) { d = el("details", { class: "set-details" }, el("summary", {}, "Details")); host.append(d); }
    d.querySelector(":scope > summary").after(...nodes);
  }
  function compactRow(rw) {
    if (rw.dataset.compact) return;
    rw.dataset.compact = "1";
    const fold = [];
    const label = rw.querySelector(":scope > .set-main > .set-label");
    const badges = label && label.querySelector(":scope > .set-badges");
    if (badges && badges.children.length) fold.push(el("p", { class: "set-badges-line" }, badges));
    const parts = [...rw.querySelectorAll(":scope > .set-main > *"), ...rw.querySelectorAll(":scope > *:not(.set-main)")];
    for (const n of parts) {
      if (n.matches(KEEP)) continue;
      if (n.matches(ALWAYS) || (!n.querySelector(CONTROL) && !n.matches(CONTROL))) { fold.push(n); continue; }
      // (a list of cards: each card's words fold inside it, its head and controls stay)
      for (const li of n.querySelectorAll(":scope > li.set-prov")) {
        foldInto(li, [...li.children].filter((x) => !x.matches(".set-prov-head, .set-details, .set-subs-where")
          && (x.matches(ALWAYS) || !x.querySelector(CONTROL))));
      }
    }
    // (a terminal command goes with the rest of what is for the terminal: Details' footer)
    const term = rw.querySelector(":scope > details.set-details > .set-term");
    foldInto(rw, fold.filter((n) => !(term && n.matches(".set-cli"))));
    if (term) for (const n of fold) if (n.matches(".set-cli")) term.append(n);
  }
  function compact(root) {
    if (!PHONE.matches) return;
    for (const rw of root.querySelectorAll(".set-row")) compactRow(rw);
  }
  // (across the phone width: the page drawn again, folded or not)
  PHONE.addEventListener("change", () => { if (data) render(); });

  // the frame of a row: name and badges, the summary, the value, and the full note folded under Details
  function frame(k, r, opts = {}) {
    const row = el("div", { class: "set-row", "data-key": k.key, id: `set-row-${k.key}` });
    if (changedFromDefault(k)) {
      row.dataset.changed = "1";
      row.title = `Changed from the default (${String(k.default).trim() === "" ? "blank" : k.default})`;
    }
    const nameId = `set-name-${k.key}`, sumId = `set-sum-${k.key}`;
    const main = el("div", { class: "set-main" },
      el("div", { class: "set-label" }, el("span", { class: "set-name", id: nameId, text: opts.label || ROW_LABEL[k.key] || k.label }), badges(k)),
      el("p", { class: "set-sum", id: sumId, text: (r && r.summary) || "" }));
    if (opts.value !== false) {
      const text = opts.value || display(k);
      const v = el("p", { class: `set-value${plain(k) ? "" : " masked"}${text === "Not set" ? " set-unset" : ""}`, text });
      if (plain(k) && "value" in k) v.dataset.value = k.value;
      main.append(v);
    }
    const actions = el("div", { class: "set-actions" });
    row.append(main, actions);
    // Details: what it does, in the page's words; then, apart, what a terminal needs — the setting's name in .env and the
    // command that changes it
    const term = forTerminal([k.key, ...(withOf[k.key] || [])]);
    const details = el("details", { class: "set-details" }, el("summary", {}, "Details"), el("p", { class: "note", text: k.note }), term);
    if (opts.cli !== false && editable(k) && canChange()) term.append(cliLine(k));
    row._details = details;
    row._main = main;
    row._actions = actions;
    return row;
  }
  // finish ROW: the terminal command inline where the page cannot change it, then the Details, last
  function finish(row, k, inlineCli) {
    if (inlineCli) row.append(inlineCli === true ? cliLine(k) : inlineCli);
    row.append(row._details);
    return row;
  }

  function row(k, r) {
    const rw = frame(k, r);
    const main = rw._main, actions = rw._actions;
    const setValue = (text) => { const v = $(".set-value", main); v.textContent = text; v.classList.remove("set-unset"); };
    const alias = BUDGET_ALIAS[k.key];
    if (alias) main.append(el("p", { class: "set-spend note", "data-alias": alias }));
    if (k.key === "AWS_ACCESS_KEY_ID" && keys.AWS_AUTH && shown(keys.AWS_AUTH) === "instance-role") {
      setValue("this computer's IAM role (no key in .env)");
    }
    if (k.key === "OPENWEBUI_ADMIN_EMAIL" && keys.LITELLM_UI_USER && "value" in keys.LITELLM_UI_USER && keys.LITELLM_UI_USER.value !== k.value) {
      main.append(el("p", { class: "note set-extra", text: `Admin (LiteLLM) sign-in name until the next setup: ${keys.LITELLM_UI_USER.value || "admin"}` }));
    }
    // reveal / copy for what the portal holds anyway
    if (REVEALABLE.has(k.key) && k.set) actions.append(revealButton(k.key, "Reveal", true));
    if (k.key === "RUSTFS_ACCESS_KEY" && keys.RUSTFS_SECRET_KEY && keys.RUSTFS_SECRET_KEY.set) actions.append(revealButton("RUSTFS_SECRET_KEY", "Copy secret", false));
    const ownKey = (withOf[k.key] || []).find((w) => /^LITELLM_KEY_/.test(w));
    if (alias && ownKey && keys[ownKey] && keys[ownKey].set && REVEALABLE.has(ownKey)) actions.append(revealButton(ownKey, "Copy key", false));
    if (k.key === "AWS_ACCESS_KEY_ID") actions.append(actionButton("check-aws", "Check (free)"));
    if (k.validator === "code_model") setValue(k.value ? modelName(k.value) : `Automatic: ${codeDefaultAuto()}`);
    if (k.validator === "model_pin") {   // a pin, and the model setup chose (shown while there is no pin)
      const d = keys[(withOf[k.key] || [])[0]];
      setValue(shown(k) === "blank" || !k.set ? `Automatic: ${modelName(d ? shown(d) : "")}` : `Pinned: ${modelName(shown(k))}`);
    }
    if (k.key === "REMOTE_PREVIEW" && ON_VALUES.includes(lower(k.value)) && !remotePreviewOn()) {
      main.append(el("p", { class: "note", text: "Switched on, not in effect: the Code page is not reachable over remote access (REMOTE_TERMINAL=true), or remote access has no names yet (./stack up)." }));
    }
    if (k.key === "MODELS_HIDDEN") setValue(k.value ? k.value.split(",").map(modelName).join(", ") : "None hidden");
    // the last release check and Check for updates (updatecheck.js): a click asks once, also with the daily check off
    if (k.key === "UPDATE_CHECK" && window.bnUpdateCheck && window.bnUpdateCheck.line) main.append(window.bnUpdateCheck.line("settings"));
    if (k.key === "BACKUP_HOUR" && keys.AUTO_UPDATE && keys.AUTO_UPDATE.value === "on") {
      const h = keys.AUTO_UPDATE_HOUR && /^\d+$/.test(keys.AUTO_UPDATE_HOUR.value || "") ? Number(keys.AUTO_UPDATE_HOUR.value) : 3;
      main.append(el("p", { class: "note set-extra", text: `Automatic updates are on: nightly backups use their window (${hourRange(h)}) instead.` }));
    }
    if (k.policy === "regen") {
      const b = el("button", { type: "button", class: "action", text: "Regenerate" });
      b.disabled = !canChange();
      b.addEventListener("click", () => askPassword({ kind: "apply", values: {}, regen: [k.key], keys: [k.key] },
        `Regenerate ${k.key === "SHARED_MCP_TOKEN" ? "the MCP token" : "the Files key pair"}?`, k.note, "Regenerate",
        k.key === "SHARED_MCP_TOKEN" ? ["SHARED_MCP_TOKEN"] : ["RUSTFS_ACCESS_KEY", "RUSTFS_SECRET_KEY"]));
      actions.append(b);
      return finish(rw, k, !canChange());
    }
    if (!editable(k)) return finish(rw, k, true);
    if (localOnlyHere(k, "true") && k.policy === "local") {
      rw.append(el("p", { class: "note set-remote", text: "Change this from the computer running DevOS ADE: from your devices it could send your data elsewhere." }));
      return finish(rw, k, true);
    }
    const v = shown(k);
    if (["bool", "on_off", "true_blank"].includes(k.validator)) {
      $(".set-value", main).remove();
      actions.append(toggle(k, v, `set-name-${k.key}`));
      rw.classList.add("set-has-switch");
    } else if (k.validator === "hour") {   // the select shows the value
      $(".set-value", main).remove();
      actions.append(hourSelect(k, k.key === "AUTO_UPDATE_HOUR" ? 3 : 2, k.key === "AUTO_UPDATE_HOUR" ? "Change the nightly window?" : "Change the nightly backup window?"));
    } else if (k.validator === "keep") {
      $(".set-value", main).remove();
      actions.append(keepSelect(k));
    } else if (k.validator === "or_mode") {
      if (["all", "free", "paid", ""].includes(lower(k.value))) $(".set-value", main).remove();
      actions.append(segmented(k, rw));
    } else if (k.validator === "code_models") {
      main.append(el("p", { class: "note set-extra", text: codeModelsNote() }));
      actions.append(codeModelsSeg(k, rw));
    } else if (k.validator === "egress") {   // the chips show the value
      $(".set-value", main).remove();
      actions.append(egressChoice(k));
    } else {
      // (a provider's key: its card's one action — the form adds, replaces or removes it)
      const b = el("button", { type: "button", class: PROVIDERS[k.key] && !providerOn(k) ? "action primary" : "action",
        text: PROVIDERS[k.key] ? (PROVIDERS[k.key].button || ["Replace key", "Add key"])[k.set ? 0 : 1] : plain(k) || k.set ? "Change" : "Set",
        "aria-describedby": `set-name-${k.key}` });
      b.disabled = !canChange();
      b.addEventListener("click", () => openForm(rw, k));
      actions.append(b);
    }
    return finish(rw, k, !canChange());
  }

  // a switch: one button (role switch), its state in words next to it; a change asks for the password like any other
  function toggle(k, v, labelId) {
    const on = k.validator === "on_off" ? "on" : "true", off = k.validator === "on_off" ? "off" : (k.validator === "true_blank" ? "" : "false");
    const cur = k.key === "REMOTE_PREVIEW" ? (remotePreviewOn() ? on : off)
      : v === on || (DEFAULT_ON.has(k.key) && (v === "blank" || v === "not set")) ? on : off;
    const other = cur === on ? off : on;
    const b = el("button", { type: "button", class: "switch", role: "switch", "aria-checked": String(cur === on), "aria-labelledby": labelId,
      "aria-describedby": `set-sum-${k.key}`, "data-state": cur === on ? "on" : "off" }, el("span", { class: "switch-track", "aria-hidden": "true" }, el("span", { class: "switch-thumb" })),
    el("span", { class: "switch-text", text: cur === on ? "On" : "Off" }));
    b.disabled = !canChange() || (k.policy === "on-only" && other !== on) || localOnlyHere(k, other);
    const what = k.key === "CODE_ENABLED" ? codeSwitch(other) : k.note;
    b.addEventListener("click", () => confirmApply({ [k.key]: other }, `${k.label}: ${other === on ? "On" : "Off"}`, what, [k.key]));
    const wrap = el("div", { class: "set-toggle" }, b);
    if (k.policy === "on-only" && cur === on) wrap.append(el("span", { class: "note", text: "Turning it off is a terminal step." }));
    if (k.policy === "widen-local" && data.here.remote && weakens(k, other)) {
      wrap.append(el("span", { class: "note", text: `${other === on ? "On" : "Off"} only from the computer running DevOS ADE.` }));
    }
    return wrap;
  }

  // OpenRouter's model set: All · Free · Paid, or a list of model ids (the form)
  function segmented(k, rw) {
    const v = lower(k.value) || "all";
    const cur = ["all", "free", "paid"].includes(v) ? v : "list";
    const g = el("div", { class: "chips seg set-seg", role: "group", "aria-labelledby": `set-name-${k.key}` });
    for (const [val, label] of [["all", "All"], ["free", "Free"], ["paid", "Paid"], ["list", "List…"]]) {
      const b = el("button", { type: "button", class: "chip", "aria-pressed": String(val === cur), text: label });
      b.disabled = !canChange();
      b.addEventListener("click", () => {
        if (val === "list") openForm(rw, k);
        else if (val !== cur) confirmApply({ [k.key]: val }, `${k.label}: ${label}`, k.note, [k.key]);
      });
      g.append(b);
    }
    return g;
  }

  // --- Settings › Claude Code › Models (CODE_MODELS, CODE_DEFAULT_MODEL): the models of litellm/code-models.tsv ---
  // [id, name, provider, vendor, compat, free, listed] (lib/code_models.sh, through the snapshot's choices)
  const codeModels = () => (data && data.snapshot && data.snapshot.choices.code_models) || [];
  const COMPAT_WORD = { works: "works", "chat-only": "chat only, no tools", fails: "fails", untested: "not tested" };
  function codeScope(v) { const x = lower(v); return x === "" || x === "all" ? "all" : x === "anthropic" ? "anthropic" : "list"; }
  function codeModelsWords(v) {
    const sc = codeScope(v);
    if (sc === "all") return `Every enabled model${codeModels().length ? ` (${codeModels().length})` : ""}`;
    if (sc === "anthropic") return "Anthropic's (Claude) only";
    const ids = String(v).split(",").map((x) => x.trim()).filter(Boolean);
    return `${ids.length} picked: ${ids.slice(0, 4).map(modelName).join(", ")}${ids.length > 4 ? ", …" : ""}`;
  }
  function codeModelsNote() {
    const all = codeModels(), works = all.filter((m) => m[4] === "works").length;
    if (!all.length) return "The list appears after the next ./stack up (it writes litellm/code-models.tsv).";
    return `${all.length} enabled chat model${all.length === 1 ? "" : "s"}, ${works} of them checked to work with Claude Code's tools. Others answer through the model gateway's translation; tool use, thinking and prompt caching vary — the Code page's picker marks each.`;
  }
  function codeModelsSeg(k, rw) {
    const cur = codeScope(k.value);
    const g = el("div", { class: "chips seg set-seg", role: "group", "aria-labelledby": `set-name-${k.key}` });
    for (const [val, label] of [["all", "All enabled"], ["anthropic", "Anthropic only"], ["list", "Pick…"]]) {
      const b = el("button", { type: "button", class: "chip", "aria-pressed": String(val === cur), text: label, "data-scope": val });
      b.disabled = !canChange();
      b.addEventListener("click", () => {
        if (val === "list") openForm(rw, k);
        else if (val !== cur) confirmApply({ [k.key]: val === "all" ? "" : val }, `${k.label}: ${label}`, k.note, [k.key]);
      });
      g.append(b);
    }
    return g;
  }
  // the models in groups, for the checklist and the default's select
  function codeGroups() {
    const g = [["Anthropic (Bedrock)", []], ["Other providers on Bedrock", []], ["OpenRouter: free", []], ["OpenRouter: paid", []],
      ["Experiential Labs", []]];
    for (const m of codeModels()) {
      const i = m[2] === "Experiential Labs" ? 4 : m[2] === "OpenRouter" ? (m[5] ? 2 : 3) : (lower(m[3]) === "anthropic" ? 0 : 1);
      g[i][1].push(m);
    }
    return g.filter((x) => x[1].length);
  }
  function codeModelLabel(m) { return `${m[1]}${m[3] && lower(m[3]) !== "anthropic" ? ` (${m[3]})` : ""} · ${COMPAT_WORD[m[4]] || "not tested"}${m[5] && !/free/i.test(m[1]) ? " · free" : ""}`; }

  // --- Settings › Models & providers: each provider a card (PROVIDERS; your subscriptions': subscriptionsRow) ---
  // Search (lib/websearch.sh websearch_json): which backend Claude Code's WebSearch searches with, its check and what
  // to do, the backends set up, and AgentCore Web Search's own state (its gateway, what your AWS admin runs)
  function webSearch() {
    const w = data && data.snapshot && data.snapshot.choices.websearch;
    return w || { backend: "", name: "", status: "off", reason: "", why: "", fix: [], set_up: [], builtin: { state: "", engines: [] },
      agentcore: { status: "", gateway: "", why: "", fix: [] } };
  }
  // each backend's name, as a sentence has it ("searches with the built-in SearXNG")
  const WS_NAME = { builtin: "the built-in SearXNG", agentcore: "AgentCore Web Search", tavily: "Tavily", brave: "Brave Search", perplexity: "Perplexity",
    searxng: "your own SearXNG" };
  // the search engines the built-in SearXNG asks, by their SearXNG names (lib/websearch.sh WEBSEARCH_SEARXNG_ENGINES)
  const WS_ENGINE = { startpage: "Startpage", yahoo: "Yahoo", yep: "Yep", mojeek: "Mojeek" };
  const wsEngines = () => {
    const e = (webSearch().builtin.engines || []).map((x) => WS_ENGINE[x] || x);
    return e.length > 1 ? `${e.slice(0, -1).join(", ")} and ${e[e.length - 1]}` : e[0] || "public search engines";
  };
  // lines of what to do, as ./stack says them: a command (aws …, ./stack …) as code with its Copy button
  function wsLines(lines) {
    const f = document.createDocumentFragment();
    for (const line of lines || []) {
      const cmd = /^(aws |\.\/stack )/.test(line);
      // (blocks of the card's line of what it adds — a p: divs, never a p in a p)
      f.append(cmd ? el("div", { class: "set-cli" }, el("code", { text: line }), " ", copyButton(line, "Copy the command"))
        : el("div", { class: "note set-extra", text: line }));
    }
    return f;
  }
  function wsChoiceState(k, on) {
    const w = webSearch();
    return !on ? ["Off", "off"] : w.status === "failed" ? ["Needs a step", "warn"] : ["On", "on"];
  }
  function wsChoiceAdds() {
    const w = webSearch();
    const f = document.createDocumentFragment();
    f.append(`Claude Code's WebSearch searches with ${WS_NAME[w.backend] || w.name} on every model${w.reason ? ` (${w.reason})` : ""}: only the query goes there. `,
      w.status === "ok" ? `Checked${w.checked_at ? ` ${new Date(w.checked_at).toLocaleDateString()}` : ""}: it answers.`
        : w.status === "failed" ? `It does not work yet: ${w.why}.` : "Not checked yet.");
    f.append(wsLines(w.fix));
    return f;
  }
  function wsChoiceOff() {
    const w = webSearch();
    const f = document.createDocumentFragment();
    f.append(`Claude Code's WebSearch says it is not available (WebFetch still works): ${w.why || "no search backend is set up"}.`);
    f.append(wsLines(w.fix));
    return f;
  }
  // a backend's card: set up (its key, URL or gateway) or not, in use or not, where the query goes, what it costs
  function wsCard(b, where, cost, button) {
    return {
      backend: b, button,
      on: () => webSearch().set_up.includes(b),
      state: (k, on) => {
        const w = webSearch();
        if (b === "agentcore" && ["denied", "no-target"].includes(w.agentcore.status)) return ["Needs your AWS admin", "warn"];
        if (w.backend === b) return w.status === "failed" ? ["In use · needs a step", "warn"] : ["In use", "on"];
        if (b === "builtin") return on ? ["On · not in use", "off"] : ["Off", "off"];
        return on ? ["Set up", "off"] : ["Not set up", "off"];
      },
      adds: () => {
        const w = webSearch();
        const f = document.createDocumentFragment();
        if (b === "builtin") {
          f.append(w.backend === b ? `Claude Code's WebSearch searches with it: only the query goes to ${wsEngines()}, from this computer (free). `
            : `On, standing by: WebSearch uses ${WS_NAME[w.backend] || "none"} now${w.reason ? ` (${w.reason})` : ""}. It takes over when none of yours is set up. `);
          return f;
        }
        f.append(w.backend === b ? `Claude Code's WebSearch searches with it: the queries go to ${where} (${cost}). ` : `Set up: the queries would go to ${where} (${cost}). WebSearch uses ${WS_NAME[w.backend] || "none"} now (the first one set up, or Web search's choice above). `);
        if (b === "agentcore" && w.agentcore.gateway && !(keys.WEBSEARCH_AGENTCORE_GATEWAY && keys.WEBSEARCH_AGENTCORE_GATEWAY.value)) f.append(`Its gateway, found by itself: ${w.agentcore.gateway}.`);
        return f;
      },
      off: () => {
        const f = document.createDocumentFragment();
        if (b === "builtin") {
          f.append("Off: no container runs. Switched on, it searches for Claude Code's WebSearch whenever none of yours is set up (free, no key).");
          return f;
        }
        f.append(`Sends nothing until it is set up; then Claude Code's WebSearch can search with it: the queries go to ${where} (${cost}).`);
        if (b === "agentcore") f.append(wsLines(webSearch().agentcore.fix));
        return f;
      },
    };
  }
  // What each search option costs, sends and is like, and where its key comes from: the info button next to its card's
  // name opens it under the name (a disclosure, as the Sign in buttons' commands: aria-expanded and aria-controls, a
  // click or a tap, Escape closes it). Prices as each one's own pricing page says them (checked in October 2026, linked);
  // nothing is said here that its page does not say.
  const WS_CHECKED = "as of Oct 2026";
  const WS_INFO = {
    builtin: {
      cost: "Free: no key and no account.",
      sent: () => `Only the search query, never your conversation or files: from this computer to ${wsEngines()}.`,
      steady: "Those engines see this computer's internet address and may slow it down or refuse it after many searches; WebSearch then finds less for a while. A key below gives steadier results.",
      get: ["Nothing to sign up for: it is on by default.", ["SearXNG's documentation", "https://docs.searxng.org/"]],
    },
    agentcore: {
      cost: `$7 per 1,000 searches, plus $0.005 per 1,000 gateway calls, on your AWS bill; no free tier of its own (${WS_CHECKED}).`,
      pricing: ["AWS pricing", "https://aws.amazon.com/bedrock/agentcore/pricing/"],
      sent: "Only the search query, never your conversation or files, to Amazon's web search through your own AgentCore gateway.",
      steady: "Amazon's own index. The query stays inside AWS, on the AWS key this stack already uses.",
      get: ["No key: your AWS admin sets it up once (./stack websearch aws-setup prints the commands).", ["Setup steps", `${REPO}README.md#web-search-for-claude-code`]],
    },
    tavily: {
      cost: `1,000 free searches a month; then $0.008 a search, or plans from $30 a month for 4,000 (${WS_CHECKED}).`,
      pricing: ["Tavily pricing", "https://www.tavily.com/pricing"],
      sent: "Only the search query, never your conversation or files, to Tavily with your key.",
      steady: "A search API made for AI agents: steady results. Tavily sees your queries.",
      get: ["", ["Get a key at app.tavily.com", "https://app.tavily.com/"]],
    },
    brave: {
      cost: `$5 per 1,000 searches, with $5 of free credit each month: about 1,000 searches (${WS_CHECKED}).`,
      pricing: ["Brave Search API pricing", "https://brave.com/search/api/"],
      sent: "Only the search query, never your conversation or files, to Brave's Search API with your key.",
      steady: "Brave's own independent index: steady results. Brave sees your queries.",
      get: ["", ["Get a key at api-dashboard.search.brave.com", "https://api-dashboard.search.brave.com/register"]],
    },
    perplexity: {
      cost: `$5 per 1,000 searches with its Search API, from prepaid credit; no free tier listed (${WS_CHECKED}).`,
      pricing: ["Perplexity pricing", "https://docs.perplexity.ai/docs/getting-started/pricing"],
      sent: "Only the search query, never your conversation or files, to Perplexity's Search API with your key.",
      steady: "Steady results. Perplexity sees your queries.",
      get: ["", ["Get a key at console.perplexity.ai", "https://console.perplexity.ai/"]],
    },
    searxng: {
      cost: "Free: you run it.",
      sent: "Only the search query, never your conversation or files, to your SearXNG, and from it to the engines it asks.",
      steady: "As steady and as private as your instance and the engines it asks. Its JSON output must be on.",
      get: ["", ["How to install SearXNG", "https://docs.searxng.org/admin/installation.html"]],
    },
  };
  const extLink = ([text, href]) => el("a", { href, target: "_blank", rel: "noopener noreferrer", text });
  // wsInfo(B) -> [the info button, its panel] for backend B's card (null for none)
  function wsInfo(b) {
    const i = WS_INFO[b];
    if (!i) return null;
    const name = b === "builtin" ? "the built-in SearXNG" : b === "searxng" ? "your own SearXNG" : WS_NAME[b];
    const id = `set-ws-info-${b}`;
    const btn = el("button", { type: "button", class: "set-info-btn", "aria-expanded": "false", "aria-controls": id,
      "aria-label": `About ${name}: cost, what is sent, privacy`, title: "Cost, what is sent, privacy" },
    el("span", { "aria-hidden": "true", text: "i" }));
    const dd = (...parts) => el("dd", {}, ...parts.filter((x) => x !== "" && x !== null && x !== undefined));
    const get = i.get || [];
    const panel = el("div", { class: "set-ws-info", id, role: "region", "aria-label": `About ${name}`, hidden: true },
      el("dl", {},
        el("dt", { text: "Cost" }), dd(i.cost, i.pricing ? " " : "", i.pricing ? extLink(i.pricing) : null),
        el("dt", { text: "What is sent" }), dd(typeof i.sent === "function" ? i.sent() : i.sent),
        el("dt", { text: "Reliability and privacy" }), dd(i.steady),
        el("dt", { text: b === "builtin" || b === "searxng" ? "Getting it" : b === "agentcore" ? "Setting it up" : "Where to get a key" }),
        dd(get[0] || "", get[0] && get[1] ? " " : "", get[1] ? extLink(get[1]) : null)));
    const show = (open) => { panel.hidden = !open; btn.setAttribute("aria-expanded", String(open)); };
    btn.addEventListener("click", () => show(panel.hidden));
    const esc = (e) => { if (e.key === "Escape" && !panel.hidden) { e.stopPropagation(); show(false); btn.focus(); } };
    btn.addEventListener("keydown", esc);
    panel.addEventListener("keydown", esc);
    return [btn, panel];
  }
  // its state in a word or two next to its name: TONE on (it adds something now), warn (it needs a step) or off
  // (a badge, as the others next to a name: the page's tag style)
  const provState = (words, tone) => el("span", { class: "badge set-prov-state", "data-tone": tone, text: words });
  // its key is there (Bedrock: or this EC2 machine's own role, AWS_AUTH); a provider that is a switch: it is on
  // (a provider that says it itself: ON)
  const providerOn = (k) => (PROVIDERS[k.key] && PROVIDERS[k.key].on ? PROVIDERS[k.key].on(k)
    : plain(k) ? isOn(k.key) : Boolean(k.set) || (k.key === "AWS_ACCESS_KEY_ID" && Boolean(keys.AWS_AUTH) && shown(keys.AWS_AUTH) === "instance-role"));
  // A key's card: its row (the key masked, Add key / Replace key — a local setting: from this computer only, the row
  // says so elsewhere), its state, how many models it adds to every picker and where you pick which ones. Without a key
  // it sends nothing: the pickers grey its models out and lead here (catalog/setup-links.tsv openrouter-off …). A
  // provider of another kind says what it adds (ADDS) and, while it is off, what it then does (OFF).
  function providerRow(k, r) {
    const p = PROVIDERS[k.key];
    const rw = row(k, r);
    const on = providerOn(k);
    const models = p.models ? codeModels().filter((m) => m[2] === p.models) : [];
    const free = models.filter((m) => m[5]).length;
    const label = $(".set-label", rw._main);
    const state = p.state ? p.state(k, on) : [!on ? (plain(k) ? "Off" : "Not set up") : p.adds || models.length ? "On" : "On · no models yet", !on ? "off" : p.adds || models.length ? "on" : "warn"];
    label.insertBefore(provState(...state), $(".set-badges", label));
    // a search option's info button, after its state; its panel under the summary line
    const info = p.backend ? wsInfo(p.backend) : null;
    if (info) {
      label.insertBefore(info[0], $(".set-badges", label));
      const sum = $(".set-sum", rw._main);
      if (sum) sum.after(info[1]); else rw._main.append(info[1]);
    }
    // (without a key: its state says it, and Check (free) has nothing to check)
    if (!on) {
      const v = $(".set-value", rw._main);
      if (v) v.remove();
      const chk = $('[data-act="check-aws"]', rw._actions);
      if (chk) chk.remove();
    }
    const adds = el("p", { class: "set-prov-adds" });
    rw._main.append(adds);
    if (!on) adds.append(typeof p.off === "function" ? p.off(k) : p.off || "Sends nothing until it has a key; then its models are in every picker.");
    else if (p.adds) adds.append(p.adds(k));
    else {
      // Pick which models the provider adds: Browse models (models.js, the #modelbrowser page, searched and filtered),
      // or the plain setting row. BROWSE_PROVIDER maps a key's card to the browser's provider.
      const bp = BROWSE_PROVIDER[k.key];
      adds.append(models.length ? `Adds ${models.length} model${models.length === 1 ? "" : "s"}${free ? ` (${free} free)` : ""} to every picker. ` : "Adds no models yet. ",
        "Pick which: ", el("a", { href: bp ? `#modelbrowser/${bp}` : `#settings/${p.pick[0]}`, text: "Browse models" }),
        ...(bp ? [" (search, filter, add or remove), or ", el("a", { href: `#settings/${p.pick[0]}`, text: p.pick[1] })] : []), ".");
      // Experiential Labs: chosen models its key's list does not name — left out, never swapped for another alias
      // (JON-521: a "…:free" alias the key does not list is refused by the gateway)
      const left = k.key === "EXPLABS_API_KEY" ? ((data.explabs && data.explabs.missing) || []) : [];
      if (left.length) {
        state[0] = models.length ? "On · some left out" : "Needs a step";
        const badge = $(".set-prov-state", label); if (badge) { badge.textContent = state[0]; badge.dataset.tone = "warn"; }
        rw._main.append(el("p", { class: "note set-extra set-prov-left", "data-testid": "explabs-left-out" },
          ...left.map((m) => `${m.text} `), "Change which: ", el("a", { href: `#settings/${p.pick[0]}`, text: p.pick[1] }), "."));
      }
      // (the Code page and devos-claude list what Models for Claude Code says: all of them unless you narrowed it)
      const scope = codeScope(keys.CODE_MODELS ? keys.CODE_MODELS.value : "");
      if (models.length && scope !== "all") {
        rw._main.append(el("p", { class: "note set-extra" }, `The Code page and devos-claude list ${scope === "anthropic" ? "Anthropic's (Claude) models only" : "only the models you picked"}: `,
          el("a", { href: "#settings/CODE_MODELS", text: "Models for Claude Code" }), "."));
      }
    }
    return rw;
  }

  // --- the Code page (./stack code enable | disable, run by the update helper) and the browser terminal ---
  function codeSwitch(val) {
    if (val !== "true") return "The helper runs ./stack code disable: the code container goes; the terminal (and its tmux session), its folder and Claude Code's history stay.";
    const ws = codeFolder() || "the default folder";
    return terminalOn()
      ? `The helper runs ./stack code enable: it builds the Code page's image (a few minutes the first time) and restarts the portal and Caddy; the terminal keeps running. Claude sees the terminal's folder ${ws}.`
      : `The helper runs ./stack code enable: it turns the browser terminal on too, with the folder ${ws} as its workspace (created if it is not there; Claude sees only that folder), then builds the Code page's image (a few minutes the first time) and restarts the portal and Caddy.`;
  }
  function codeRow(r) {
    const k = keys.CODE_ENABLED;
    const rw = row(k, r);
    const ws = codeFolder();
    const egress = egressMode(keys.TERMINAL_EGRESS ? keys.TERMINAL_EGRESS.value : "");
    const extra = [el("p", { class: "set-code-ws" }, el("span", { class: "note", text: "Workspace: " }),
      el("code", { text: ws || (terminalOn() ? "the terminal's" : "the default folder") }))];
    if (terminalOn()) {
      extra.push(el("p", { class: "note", text: `Claude sees only that folder (at /workspace) and uses the terminal's key and budget. ${{
        internet: "It reaches public internet addresses (npm, pip, git, documentation) through the sandbox's egress proxy — not this computer's own services or your network (Sandbox internet access, below).",
        host: "It reaches the internet and, with it, this computer's own services and your network (Sandbox internet access, below: host).",
        off: "It has no internet and no way to this computer's services (Sandbox internet access, below: off)." }[egress]}` }));
    } else if (shown(k) !== "true") {
      extra.push(el("p", { class: "note", text: "The browser terminal is off: turning this on turns it on too, with the folder above as its workspace (Claude sees only that folder, at /workspace). Another folder: in a terminal, with the command below." }));
    }
    rw._main.append(...extra);
    rw.querySelector(":scope > .set-details").remove();
    const cmd = terminalOn() ? "./stack terminal enable --workspace DIR" : "./stack code enable --workspace DIR";
    rw.insertBefore(el("p", { class: "set-cli" }, el("span", { class: "note", text: terminalOn() ? "Another folder, in a terminal: " : "In a terminal: " }), el("code", { text: cmd }), " ", copyButton(cmd)), null);
    rw.append(rw._details);
    return rw;
  }
  function terminalRow(r) {
    const k = keys.TERMINAL_ENABLED;
    const rw = frame(k, r);
    if (terminalOn()) {
      const ws = (keys.TERMINAL_WORKSPACE && keys.TERMINAL_WORKSPACE.value) || "";
      rw._main.append(el("p", { class: "set-code-ws" }, el("span", { class: "note", text: "Folder: " }), el("code", { text: ws || "the default folder" })));
    }
    return finish(rw, k, cliLine(k, terminalOn() ? "Turned off, or another folder, in a terminal: " : "Turned on in a terminal (it builds an image and checks the folder): "));
  }

  function remoteStatus(r) {
    const k = keys.REMOTE_MODE;
    const on = data.remote && data.remote.on;
    const rw = frame(k, r, { value: on ? `${data.remote.mode}: ${data.remote.url}` : "Off" });
    rw._main.append(el("p", { class: "note set-extra", text: on ? `This page is open ${data.here.remote ? "remotely" : "on this computer"}.` : "It needs a Tailscale auth key and a few steps in your tailnet's admin console (Learn more above)." }));
    return finish(rw, k, cliLine(k, on ? "Turned off in a terminal: " : "Turned on in a terminal: "));
  }

  function modelName(id) {
    const m = ((data.snapshot && data.snapshot.choices.chat_models) || []).find((x) => x[0] === id) || codeModels().find((x) => x[0] === id);
    return m ? m[1] : id || "none";
  }

  function keepSelect(kk) {
    const cur = "value" in kk && /^\d+$/.test(kk.value) ? Number(kk.value) : 7;
    const sel = el("select", { "aria-labelledby": `set-name-${kk.key}` });
    const ns = [1, 2, 3, 5, 7, 10, 14, 21, 30, 45, 60];
    if (!ns.includes(cur)) ns.push(cur);   // a value set in a terminal shows as it is
    for (const n of ns.sort((a, b) => a - b)) {
      const o = el("option", { value: String(n), text: `keep ${n}` });
      if (n === cur) o.selected = true;
      if (n !== cur && localOnlyHere(kk, String(n))) o.disabled = true;   // fewer: only from this computer
      sel.append(o);
    }
    sel.disabled = !canChange();
    sel.addEventListener("change", () => confirmApply({ BACKUP_KEEP: sel.value }, "Change how many nightly backups are kept?", kk.note, ["BACKUP_KEEP"]));
    return sel;
  }

  function hourSelect(hk, def, title) {
    const cur = "value" in hk && /^\d+$/.test(hk.value) ? Number(hk.value) : def;
    const sel = el("select", { "aria-labelledby": `set-name-${hk.key}` });
    for (let h = 0; h < 24; h++) {
      const o = el("option", { value: String(h), text: hourRange(h) });
      if (h === cur) o.selected = true;
      sel.append(o);
    }
    sel.disabled = !canChange();
    sel.addEventListener("change", () => confirmApply({ [hk.key]: sel.value }, title, hk.note, [hk.key]));
    return sel;
  }

  function revealButton(key, label, show) {
    const b = el("button", { type: "button", class: "copy", "data-reveal": key, text: label });
    b.disabled = !data.here.allowed;
    b.addEventListener("click", () => askPassword({ kind: "reveal", key, show },
      "Show and copy?", `${key} goes on your clipboard${show ? " and shows here" : ""}. The portal already holds this value; nothing else can be revealed.`, "Copy"));
    return b;
  }

  // --- forms ---
  function field(id, label, type, attrs = {}, unit = "") {
    const input = el("input", { id, type, autocomplete: type === "password" ? "new-password" : "off", spellcheck: "false", ...attrs });
    return [el("label", { for: id, text: label }), unit ? el("span", { class: "set-unit" }, input, el("span", { class: "note", text: unit })) : input];
  }

  function openForm(r, k) {
    for (const f of document.querySelectorAll("#settings .set-form")) f.remove();
    const form = el("form", { class: "set-form", novalidate: "" });
    const id = `f-${k.key}`;
    let collect = () => ({});
    const v = "value" in k ? k.value : "";
    // what is wrong, and the key check's word: right under a key's field (a form's other fields: after them)
    const err = el("p", { class: "error", id: `${id}-err`, role: "alert", hidden: "" });
    const status = el("p", { class: "note set-check", id: `${id}-check`, "aria-live": "polite", hidden: "" });
    let keyFields = [];   // a key's inputs: Save waits until each has a value
    let asked = null;     // {key, name}: a key the provider is asked about before the password (KEY_FORM.check)
    if (k.validator === "portal_password" || k.validator === "litellm_password") {
      form.append(...field(`${id}-a`, "New password", "password", { minlength: "12", maxlength: "128" }),
        ...field(`${id}-b`, "Again", "password", { maxlength: "128" }));
      if (k.validator === "litellm_password") {
        const g = el("button", { type: "button", class: "quiet", text: "Generate one" });
        g.addEventListener("click", () => { const p = genPassword(); $(`#${id}-a`, form).value = p; $(`#${id}-b`, form).value = p; $(`#${id}-a`, form).type = "text"; });
        form.append(el("p", { class: "set-gen" }, g));
      }
      collect = () => {
        const a = $(`#${id}-a`, form).value, b = $(`#${id}-b`, form).value;
        if (!a) throw new Error("Enter the new password.");
        if (a !== b) throw new Error("The two passwords differ.");
        return { [k.key]: a };
      };
    } else if (k.key === "AWS_ACCESS_KEY_ID") {
      form.append(...field(`${id}-a`, "New access key ID (AKIA…)", "text", { maxlength: "20", autocapitalize: "characters" }),
        ...field(`${id}-b`, "New secret access key", "password", { maxlength: "40" }), err, status, getKeyLine(KEY_FORM.AWS_ACCESS_KEY_ID),
        el("p", { class: "note", text: "Checked with AWS before anything changes (free), including Bedrock access. Then the model gateway restarts (about 15 s) and a smoke test runs (~$0.0001); if it fails, the old key comes back. Deactivate the old key in IAM afterwards." }));
      keyFields = [$(`#${id}-a`, form), $(`#${id}-b`, form)];
      const other = el("input", { type: "checkbox", id: `${id}-other` });
      form.append(el("label", { for: `${id}-other`, class: "set-radio" }, other, " The new key belongs to another AWS account (its models, quotas and bill are its own)"));
      collect = () => ({ AWS_ACCESS_KEY_ID: $(`#${id}-a`, form).value.trim(), AWS_SECRET_ACCESS_KEY: $(`#${id}-b`, form).value.trim() });
      form.dataset.confirm = "";
      other.addEventListener("change", () => { form.dataset.confirm = other.checked ? "other-aws-account" : ""; });
    } else if (k.validator === "budget") {
      form.append(...field(id, "Monthly budget", "text", { inputmode: "decimal", value: v, maxlength: "12" }, "USD a month"));
      const warn = el("p", { class: "note", hidden: "" });
      form.append(warn);
      const check = () => {
        const n = Number($(`#${id}`, form).value.trim()), row = spend && (spend.keys || []).find((x) => x.alias === BUDGET_ALIAS[k.key]);
        let w = "";
        if (row && !row.error && n > 0 && n < row.spend) w = `Below this period's spend (${usd(row.spend)}): requests with this key are refused until the reset.`;
        else if (k.key === "BUDGET_SETUP" && n > 0 && n < 0.05) w = "Setup's model check and smoke test cost up to about $0.05: a lower budget can make ./stack setup and Re-check models fail.";
        warn.textContent = w; warn.hidden = !w;
      };
      $(`#${id}`, form).addEventListener("input", check);
      check();
      collect = () => ({ [k.key]: $(`#${id}`, form).value.trim() });
    } else if (k.validator === "model_pin") {
      const sel = el("select", { id });
      sel.append(el("option", { value: "", text: k.key === "CHAT_TASK_MODEL" ? "each chat's own model" : "automatic (setup picks one)" }));
      for (const [m, name] of data.snapshot.choices.chat_models) {
        if (k.key.startsWith("CLAUDE_MODEL_") && !m.startsWith("claude-")) continue;   // Claude Code speaks Anthropic's API
        const o = el("option", { value: m, text: `${name} (${m})` });
        if (m === v) o.selected = true;
        sel.append(o);
      }
      form.append(el("label", { for: id, text: "Model" }), sel);
      collect = () => ({ [k.key]: sel.value });
    } else if (k.validator === "models_list") {
      const chosen = new Set((v || "").split(",").filter(Boolean));
      const box = el("fieldset", { class: "set-radios" }, el("legend", { text: "Leave out of Chat's model picker" }));
      for (const [m, name] of data.snapshot.choices.chat_models) {
        const cb = el("input", { type: "checkbox", id: `${id}-${m}`, value: m });
        if (chosen.has(m)) cb.checked = true;
        box.append(el("label", { for: `${id}-${m}`, class: "set-radio" }, cb, " ", name));
      }
      form.append(box, el("p", { class: "note", text: "Hidden models stay usable through the API and Claude Code: this only tidies the picker." }));
      collect = () => ({ [k.key]: [...box.querySelectorAll("input:checked")].map((c) => c.value).join(",") });
    } else if (k.validator === "code_models") {
      const picked = new Set(codeScope(v) === "list" ? v.split(",").map((x) => x.trim()).filter(Boolean) : []);
      const box = el("fieldset", { class: "set-radios set-code-models" }, el("legend", { text: "List these in the Code page's picker and the terminal's /model" }));
      const q = el("input", { type: "search", id: `${id}-q`, placeholder: "Filter: a name, a provider, free…", autocomplete: "off", spellcheck: "false",
        "aria-label": "Filter the models" });
      box.append(q);
      const items = [];
      for (const [title, list] of codeGroups()) {
        const sec = el("div", { class: "set-code-group" }, el("p", { class: "set-code-head", text: title }));
        for (const m of list) {
          const cid = `${id}-${items.length}`;
          const cb = el("input", { type: "checkbox", id: cid, value: m[0] });
          if (picked.has(m[0])) cb.checked = true;
          const lab = el("label", { for: cid, class: "set-radio", title: m[0] }, cb, " ", codeModelLabel(m));
          items.push([lab, `${m[0]} ${m[1]} ${m[2]} ${m[3]} ${COMPAT_WORD[m[4]] || ""} ${m[5] ? "free" : ""}`.toLowerCase()]);
          sec.append(lab);
        }
        box.append(sec);
      }
      q.addEventListener("input", () => {
        const t = lower(q.value);
        for (const [lab, text] of items) lab.hidden = Boolean(t) && !text.includes(t);
        for (const sec of box.querySelectorAll(".set-code-group")) sec.hidden = ![...sec.querySelectorAll("label")].some((x) => !x.hidden);
      });
      form.append(box, el("p", { class: "note", text: "Only a list: the terminal's key may use every model either way, and the default model is always listed. Models that do not \"work\" cannot use Claude Code's tools reliably." }));
      collect = () => {
        const ids = [...box.querySelectorAll("input[type=checkbox]:checked")].map((c) => c.value);
        if (!ids.length) throw new Error("Pick at least one model (or choose All enabled).");
        return { [k.key]: ids.join(",") };
      };
    } else if (k.validator === "code_model") {
      const sel = el("select", { id });
      sel.append(el("option", { value: "", text: `automatic: ${codeDefaultAuto()}` }));
      for (const [title, list] of codeGroups()) {
        const og = el("optgroup", { label: title });
        for (const m of list) {
          const o = el("option", { value: m[0], text: codeModelLabel(m) });
          if (m[0] === v) o.selected = true;
          og.append(o);
        }
        sel.append(og);
      }
      if (v && !codeModels().some((m) => m[0] === v)) sel.append(el("option", { value: v, text: `${v} (not enabled: counts as automatic)`, selected: "" }));
      form.append(el("label", { for: id, text: "Model" }), sel,
        el("p", { class: "note", text: "A browser's own last pick still wins for its new sessions; --model and CLAUDE_BEDROCK_MODEL win for devos-claude." }));
      collect = () => ({ [k.key]: sel.value });
      // the confirmation names what the model costs and how it works with Claude Code
      form._note = () => {
        const m = codeModels().find((x) => x[0] === sel.value);
        if (!m) return k.note;
        return `${m[1]} (${m[0]}): ${m[7] || "price unknown"}, ${COMPAT_WORD[m[4]] || "not tested"} with Claude Code. ${k.note}`;
      };
    } else if (k.validator === "ws_backend") {
      const sel = el("select", { id });
      const only = { builtin: "The built-in SearXNG only", agentcore: "AgentCore Web Search only", tavily: "Tavily only", brave: "Brave Search only",
        perplexity: "Perplexity only", searxng: "Your own SearXNG only" };
      for (const [val, text] of [["", "Automatic: the first one you set up (AgentCore Web Search, your keys, your SearXNG), else the built-in SearXNG"],
        ["off", "Off: WebSearch says it is not available"], ...Object.entries(only)]) {
        const o = el("option", { value: val, text });
        if (val === (v === "auto" ? "" : v)) o.selected = true;
        sel.append(o);
      }
      form.append(el("label", { for: id, text: "Claude Code's WebSearch searches with" }), sel);
      collect = () => ({ [k.key]: sel.value });
    } else if (k.validator === "ws_gateway") {
      form.append(...field(id, "The gateway's MCP URL (blank: found by itself)", "url", { value: v, maxlength: "300",
        placeholder: "https://GATEWAY_ID.gateway.bedrock-agentcore.REGION.amazonaws.com/mcp" }),
        el("p", { class: "note", text: "Your AWS admin sets the gateway up once for your AWS account: ./stack websearch aws-setup prints the commands." }));
      collect = () => ({ [k.key]: $(`#${id}`, form).value.trim() });
    } else if (k.validator === "or_key" || k.validator === "stt_key" || k.validator === "xl_key" || k.validator === "ws_key") {
      // the field, what is wrong with it right under it, where a key comes from, and Remove (its own button: an empty
      // Save never removes it)
      const kf = KEY_FORM[k.key] || {};
      form.append(...field(id, "New key", "password", { maxlength: "512", ...(kf.hint ? { placeholder: kf.hint } : {}) }), err, status);
      const get = getKeyLine(kf);
      if (get) form.append(get);
      keyFields = [$(`#${id}`, form)];
      if (kf.check) asked = { key: k.key, name: kf.check };
      collect = () => ({ [k.key]: $(`#${id}`, form).value.trim() });
      if (k.set) {
        const rm = el("button", { type: "button", class: "quiet", text: "Remove the key" });
        rm.addEventListener("click", () => confirmApply({ [k.key]: "" }, `Remove ${k.label}?`, REMOVE_KEY[k.validator], [k.key]));
        form.append(el("p", { class: "set-gen" }, rm));
      }
    } else if (k.validator === "webhook") {
      // (a SearXNG's URL takes the webhook's rule: https, or http to a host of your own network)
      const sx = k.key === "WEBSEARCH_SEARXNG_URL";
      form.append(...field(id, "URL", "url", { maxlength: "2000" }));
      collect = () => {
        const u = $(`#${id}`, form).value.trim();
        if (!u) throw new Error(k.set ? `Enter the new URL, or use ${sx ? "Remove the URL" : "Remove the webhook"}.` : "Enter the URL.");
        return { [k.key]: u };
      };
      if (k.set) {
        const rm = el("button", { type: "button", class: "quiet", text: sx ? "Remove the URL" : "Remove the webhook" });
        rm.addEventListener("click", () => confirmApply({ [k.key]: "" }, sx ? "Remove SearXNG's URL?" : "Remove the budget alert webhook?",
          sx ? REMOVE_KEY.ws_key : "No more alerts are sent; the model gateway restarts (about 15 s).", [k.key]));
        form.append(el("p", { class: "set-gen" }, rm));
      }
    } else {
      const type = k.validator === "email" ? "email" : "text";
      const unit = { days: "days (1-90; blank = 30)", pct: "% (50-99; blank = 80)", int_1_5000: "models (blank = 1000)" }[k.validator] || "";
      const label = { or_mode: "all, free, paid, or model ids separated by commas", xl_models: "gateway model ids, separated by commas (blank = qwen3.8-27b)" }[k.validator] || "New value";
      form.append(...field(id, label, type, { value: v, maxlength: "2000", ...(unit ? { inputmode: "numeric" } : {}) }, unit));
      // emails in lowercase, as Chat keeps them
      collect = () => ({ [k.key]: k.validator === "email" ? $(`#${id}`, form).value.trim().toLowerCase() : $(`#${id}`, form).value.trim() });
    }
    if (!err.parentNode) form.append(err, status);
    const cancel = el("button", { type: "button", class: "quiet", text: "Cancel" });
    const save = el("button", { type: "submit", class: "action primary", text: "Save" });
    form.append(el("p", { class: "confirm-buttons" }, cancel, save));
    cancel.addEventListener("click", () => form.remove());
    keyForm(form, keyFields, save, `${id}-err ${id}-check`);
    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      if (form.dataset.busy) return;
      let values;
      try { values = collect(); } catch (e) { say(form, e.message); return; }
      // nothing to save (an empty key, the value it has now) never asks for the password; nor does a key of the wrong
      // shape (the portal and the helper refuse it with the same words)
      const nothing = nothingToSave(values) || shapeError(values);
      if (nothing) { say(form, nothing); return; }
      // the less protective direction of a widen-local value, from a remote device: refused here before the password
      // (the portal's settings.policy_error and the helper refuse it too, with the same words)
      const weak = Object.keys(values).find((n) => keys[n] && keys[n].policy === "widen-local" && localOnlyHere(keys[n], values[n]));
      if (weak) {
        say(form, `${keys[weak].label} can only be ${WEAKEN_WORD[weak] || "turned on"} from the computer running DevOS ADE (the other way works everywhere).`);
        return;
      }
      // a provider's key: asked of the provider now (free), before the password (a "Save anyway" after no answer: not again)
      if (asked && unchecked.get(form) !== values[asked.key]) {
        if (!(await checkKey(form, asked, values[asked.key]))) return;
        // (while it was asked: cancelled, or the key edited, or another dialog opened — then nothing goes on)
        let now = null;
        try { now = collect()[asked.key]; } catch (_) { return; }
        if (!form.isConnected || now !== values[asked.key] || $("#set-confirm[open]")) return;
      }
      confirmApply(values, `Save ${k.label}?`, typeof form._note === "function" ? form._note() : k.note, Object.keys(values), form, form.dataset.confirm ? [form.dataset.confirm] : []);
    });
    r.insertBefore(form, r.querySelector(":scope > .set-details"));
    const first = form.querySelector("input, select");
    if (first) first.focus();
    return form;
  }

  // --- a key's form: Save once it is filled in, what is wrong right under the field, the provider asked first ---
  // a form whose key the provider did not answer about in time -> that key ("Save anyway" sends it on unasked); kept
  // here, in the page's memory, not in an attribute of the form
  const unchecked = new WeakMap();
  // keyForm(FORM, FIELDS, SAVE, DESCRIBED): Save waits until each of FIELDS has a value (an empty Save changes nothing:
  // it never opens the password dialog), the fields name the error and the check's word (aria-describedby), and an edit
  // clears what was said about the value before.
  function keyForm(form, fields, save, described) {
    const fill = () => { save.disabled = Boolean(form.dataset.busy) || fields.some((x) => !x.hidden && !x.closest("[hidden]") && !x.value.trim()); };
    for (const x of fields) x.setAttribute("aria-describedby", described);
    form.addEventListener("input", () => {
      const err = form.querySelector(":scope > .error");
      if (err) err.hidden = true;
      for (const x of form.querySelectorAll("[aria-invalid]")) x.removeAttribute("aria-invalid");
      if (unchecked.has(form)) {   // a new value: checked again
        unchecked.delete(form);
        save.textContent = "Save";
      }
      const st = form.querySelector(".set-check");
      if (st) st.hidden = true;
      fill();
    });
    form.addEventListener("change", fill);
    form._fill = fill;
    fill();
  }

  // say(FORM, …PARTS): what is wrong, under the field (text, and links to where a key comes from); the field marked
  function say(form, ...parts) {
    const err = form.querySelector(":scope > .error");
    if (!err) return;
    err.replaceChildren(...parts.flatMap((p) => (typeof p === "string" ? linkified(p) : [p])));
    err.hidden = false;
    const f = [...form.querySelectorAll("input[aria-describedby]")].find((x) => !x.closest("[hidden]"))
      || form.querySelector("input:not([type=checkbox]):not([type=radio]), select");
    if (f) { f.setAttribute("aria-invalid", "true"); f.focus(); }
  }

  // TEXT with the addresses of key pages (KEY_HOSTS) as links; any other address stays text
  function linkified(text) {
    const out = [];
    let last = 0;
    for (const m of String(text).matchAll(/https:\/\/[^\s<>"')]+/g)) {
      const u = m[0].replace(/[.,;:]+$/, "");
      let host = "";
      try { host = new URL(u).hostname; } catch (_) { continue; }
      if (!KEY_HOSTS.has(host)) continue;
      out.push(text.slice(last, m.index), extLink([u.replace(/^https:\/\//, ""), u]));
      last = m.index + u.length;
    }
    out.push(String(text).slice(last));
    return out.filter((x) => x !== "");
  }

  // the "Get a key" line under a key's field (KEY_FORM; a web search key's: its info panel's own link)
  function getKeyLine(kf) {
    const ws = kf && kf.ws && WS_INFO[kf.ws] && WS_INFO[kf.ws].get ? WS_INFO[kf.ws].get[1] : null;
    const link = ws || (kf && kf.get ? [kf.getText ? `Get a key: ${kf.getText}` : `Get a key at ${kf.get.replace(/^https:\/\//, "")}`, kf.get] : null);
    return link ? el("p", { class: "note set-getkey" }, extLink(link)) : null;
  }

  // nothingToSave(VALUES) -> why there is nothing to save ("" when there is): an empty key or password, or the value a
  // setting has now (a secret's is never known here: an empty field is its "unchanged")
  function nothingToSave(values) {
    const names = Object.keys(values);
    if (!names.length) return "Nothing to save.";
    const empty = names.filter((n) => keys[n] && !plain(keys[n]) && keys[n].secret !== "u" && !values[n]);
    if (empty.length) {
      if (names.length > 1) return "Enter both halves of the new key.";
      return /password/.test(keys[empty[0]].validator) ? "Enter the new password." : "Enter the new key.";
    }
    const now = (n) => ("value" in keys[n] ? String(keys[n].value || "") : "");
    if (names.every((n) => keys[n] && plain(keys[n]) && String(values[n]) === now(n))) return "That is the value it has now: nothing to save.";
    return "";
  }

  // shapeError(VALUES) -> what is wrong with a key's shape (KEY_SHAPE), "" when nothing is
  function shapeError(values) {
    for (const [n, val] of Object.entries(values)) {
      const kk = keys[n];
      if (!kk || !val) continue;
      if (kk.validator === "aws_key_id" && val.startsWith("ASIA")) return `${kk.label} is a temporary key (ASIA…), which expires: use a long-lived IAM user key (AKIA…).`;
      const shape = KEY_SHAPE[kk.validator];
      if (shape && !shape[0].test(val)) return `${kk.label} ${shape[1]}.`;
    }
    return "";
  }

  // checkKey(FORM, {key, name}, VALUE, PROVIDER) -> true to go on to the password: the provider asked now
  // (/api/settings/check-key: one free call). Rejected: said under the field with where a key comes from, the key kept.
  // No answer in time: said, and Save becomes "Save anyway" (the helper checks it again on this computer first).
  async function checkKey(form, chk, value, provider) {
    const save = form.querySelector("button[type=submit]"), st = form.querySelector(".set-check");
    form.dataset.busy = "1";
    save.disabled = true;
    st.className = "note set-check";
    st.textContent = `Checking the key with ${chk.name}…`;
    st.hidden = false;
    try {
      const [r, d] = await post("/api/settings/check-key", { key: chk.key, value, ...(provider ? { provider } : {}) });
      if (r.ok && (d.result === "ok" || d.result === "unchecked")) {
        st.textContent = d.message || "";
        st.classList.add("good");
        st.hidden = !d.message;
        return true;
      }
      st.hidden = true;
      if (!r.ok) { say(form, d.error || `HTTP ${r.status}`); return false; }
      if (d.result === "rejected") {
        say(form, `${d.message} `, ...(d.url ? [extLink([`Get a new key at ${String(d.url).replace(/^https:\/\//, "")}`, d.url])] : []), ". Nothing was saved.");
        return false;
      }
      unchecked.set(form, value);
      save.textContent = "Save anyway";
      say(form, `${d.message} Save anyway hands it to the update helper, which checks it again before anything changes.`);
      return false;
    } catch (e) {
      st.hidden = true;
      if (e.message !== "signed out") say(form, `Could not reach the portal (${e.message}).`);
      return false;
    } finally {
      delete form.dataset.busy;
      if (form._fill) form._fill(); else save.disabled = false;
    }
  }

  function genPassword() {
    const sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnopqrstuvwxyz", "23456789", "-_.!@%+="];
    const all = sets.join(""), r = new Uint32Array(24);
    crypto.getRandomValues(r);
    const out = sets.map((s, i) => s[r[i] % s.length]);
    for (let i = 4; i < 24; i++) out.push(all[r[i] % all.length]);
    return out.join("");
  }

  // --- voice: provider, model and key in one form ---
  function voiceRow(lr) {
    const pk = keys.STT_PROVIDER, mk = keys.STT_MODEL || {}, kk = keys.STT_API_KEY || {};
    const prov = "value" in pk ? pk.value : "";
    const model = "value" in mk ? mk.value : "";
    const label = STT_LABEL[prov] || prov;
    const now = prov ? `${label}${model ? ` · ${model}` : prov === "bedrock" ? " · voxtral-small" : ""}${kk.set && prov !== "bedrock" ? ` · key ${kk.hint || "set"}` : ""}` : label;
    const r = frame(pk, lr, { value: now });
    const actions = r._actions;
    if (data.here.remote) {
      r.append(el("p", { class: "note set-remote", text: "Change this from the computer running DevOS ADE: from your devices it could send your voice elsewhere." }));
      return finish(r, pk, true);
    }
    const b = el("button", { type: "button", class: "action", text: "Change", "aria-describedby": `set-name-${pk.key}` });
    b.disabled = !canChange();
    actions.append(b);
    b.addEventListener("click", () => {
      for (const f of document.querySelectorAll("#settings .set-form")) f.remove();
      const form = el("form", { class: "set-form" });
      const choices = data.snapshot.choices;
      const radios = el("fieldset", { class: "set-radios" }, el("legend", { text: "Provider" }));
      for (const p of ["bedrock", "openai", "groq", ""]) {
        const id = `stt-p-${p || "browser"}`;
        const input = el("input", { type: "radio", name: "stt-provider", id, value: p });
        if (p === prov) input.checked = true;
        if (p === "bedrock" && !choices.stt_bedrock_ready.length) input.disabled = true;
        radios.append(el("label", { for: id, class: "set-radio" }, input, " ", STT_LABEL[p]));
      }
      // Bedrock refusing audio for its speech-to-text models (lib/stt.sh): unavailable, and why
      const refused = choices.stt_bedrock_refused || [];
      if (!choices.stt_bedrock_ready.length && refused.length) radios.append(el("p", { class: "note", text: STT_REFUSED }));
      const msel = el("select", { id: "stt-model" });
      const keyIn = el("input", { id: "stt-key", type: "password", autocomplete: "new-password", maxlength: "512", placeholder: kk.set ? "keep the current key" : "",
        "aria-describedby": "stt-key-err stt-key-check" });
      const getKey = el("div", { class: "set-getkey-slot" });   // where an OpenAI or Groq key comes from (STT_KEY_FORM)
      const keyRow = el("div", { class: "set-sub" }, el("label", { for: "stt-key", text: "API key" }), keyIn, getKey);
      const privacy = el("p", { class: "note" });
      // what is wrong, right under the key's field, and the key check's word
      const err = el("p", { class: "error", id: "stt-key-err", role: "alert", hidden: "" });
      const status = el("p", { class: "note set-check", id: "stt-key-check", "aria-live": "polite", hidden: "" });
      const provider = () => form.querySelector("input[name=stt-provider]:checked").value;
      const describe = () => {   // what happens to your speech, and what it costs (docs/voice.md, lib/stt.sh)
        const p = provider();
        privacy.textContent = p === "openai" || p === "groq" ? `Your speech (microphone and calls) goes to ${p === "openai" ? "api.openai.com" : "api.groq.com"}. The key is checked with ${STT_LABEL[p]} first (free).`
          : p === "bedrock" ? `Your speech stays in your AWS account; it counts on Chat's budget (an estimated ${msel.value === "voxtral-mini" ? "~$0.00004" : "~$0.00014"} a minute of speech).`
            : "The browser's own speech recognition; voice calls are unavailable.";
      };
      const sync = () => {
        const p = provider();
        msel.replaceChildren(el("option", { value: "", text: "the provider's default" }));
        for (const m of choices.stt_models[p] || []) {
          const o = el("option", { value: m, text: m });
          if (p === "bedrock" && !choices.stt_bedrock_ready.includes(m)) o.disabled = true;
          if (p === "bedrock" && (choices.stt_bedrock_refused || []).includes(m)) o.text = `${m} — AWS no longer accepts its audio`;
          if (m === model && p === prov) o.selected = true;
          msel.append(o);
        }
        msel.disabled = !p;
        keyRow.hidden = !(p === "openai" || p === "groq");
        const kf = STT_KEY_FORM[p];
        keyIn.placeholder = kk.set && p === prov ? "keep the current key" : kf ? kf.hint : "";
        getKey.replaceChildren(...(kf ? [getKeyLine(kf)] : []));
        describe();
      };
      radios.addEventListener("change", sync);
      msel.addEventListener("change", describe);
      form.append(radios, el("div", { class: "set-sub" }, el("label", { for: "stt-model", text: "Model" }), msel), keyRow, err, status, privacy);
      const cancel = el("button", { type: "button", class: "quiet", text: "Cancel" });
      const save = el("button", { type: "submit", class: "action primary", text: "Save" });
      form.append(el("p", { class: "confirm-buttons" }, cancel, save));
      cancel.addEventListener("click", () => form.remove());
      keyForm(form, [], save, "stt-key-err stt-key-check");
      form.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        if (form.dataset.busy) return;
        const p = provider(), key = keyIn.value.trim();
        const values = { STT_PROVIDER: p, STT_MODEL: p ? msel.value : "" };
        if (key) values.STT_API_KEY = key;
        if (p === "bedrock" || p === "") { if (kk.set) values.STT_API_KEY = ""; }
        // nothing changed: no password dialog; OpenAI and Groq need a key (the helper refuses it without one), of the right
        // shape, which the provider is asked about now (free) — the key kept in its field when it says no
        if (p === prov && values.STT_MODEL === (prov ? model : "") && !key) { say(form, "That is the setting it has now: nothing to save."); return; }
        const kf = STT_KEY_FORM[p];
        if (kf && !key && !(kk.set && p === prov)) { say(form, `Enter your ${kf.check} API key.`); return; }
        if (kf && key) {
          const bad = shapeError({ STT_API_KEY: key });
          if (bad) { say(form, bad); return; }
          if (unchecked.get(form) !== key) {
            if (!(await checkKey(form, { key: "STT_API_KEY", name: kf.check }, key, p))) return;
            // (while it was asked: cancelled, or the key, provider or model changed, or another dialog opened — nothing goes on)
            if (!form.isConnected || keyIn.value.trim() !== key || provider() !== p || msel.value !== values.STT_MODEL || $("#set-confirm[open]")) return;
          }
        }
        confirmApply(values, "Save speech-to-text?", "Chat restarts (about 30 s).", Object.keys(values), form);
      });
      sync();
      r.insertBefore(form, r.querySelector(":scope > .set-details"));
    });
    return finish(r, pk, !canChange());
  }

  // --- the page's own rows ---
  function ownFrame(r, label) {
    const rw = el("div", { class: "set-row", "data-own": r.key, id: `set-row-${r.key.slice(1)}` });
    const main = el("div", { class: "set-main" }, el("div", { class: "set-label" }, el("span", { class: "set-name", id: `set-name-${r.key.slice(1)}`, text: label })),
      el("p", { class: "set-sum", text: r.summary }));
    rw.dataset.findExtra = label;
    const actions = el("div", { class: "set-actions" });
    rw.append(main, actions);
    rw._main = main; rw._actions = actions;
    return rw;
  }

  // Git hosts: kept by the Code page itself (its own volume, never .env, this page or the update helper), so the row
  // opens them there — the Code tab with ?git=hosts (code.js's window.bnCode), or the code host in a new tab
  function gitHostsRow(r) {
    const rw = ownFrame(r, "Git hosts");
    rw._main.append(el("p", { class: "note set-extra",
      text: "Connect GitHub, GitLab or any https/ssh git server: Sign in with GitHub or GitLab, an access token, or an SSH key the Code page makes. The Code page keeps them, apart from the sandbox: one push, pull or clone you start gets its host's credential while it runs; Claude's own git gets none unless you let it use a host there (off by default). Adding a host, a sign-in, a token or a key works only from the computer running DevOS ADE." }));
    const open = el("button", { type: "button", class: "action", text: "Open Git hosts" });
    open.addEventListener("click", () => {
      if (window.bnCode && window.bnCode.openGitHosts) window.bnCode.openGitHosts();
      else { try { const u = new URL(appUrl("code")); u.searchParams.set("git", "hosts"); window.open(u.href, "_blank", "noopener"); } catch (_) { /* no Code page */ } }
    });
    rw._actions.append(open);
    return rw;
  }

  // Project folders: folders of this computer the Code page's sandbox sees as projects (./stack project; lib/projects.sh
  // keeps the list on this computer). Added only on this computer — Choose on this computer… asks the update helper
  // to open a folder chooser on its screen (the request names no folder), or ./stack project add in a terminal there;
  // removed or made read-only from anywhere, by the folder's id. Each change restarts the sandbox: now, or once no
  // Code session has a turn running.
  const RESTART_ENDS = "Restarting the sandbox (10–20 s) ends the terminal's shells, every Code session's Claude Code (each resumes with its next prompt), dev servers and Run & test runs; the workspace, every folder and Claude Code's history stay.";
  function projectFoldersRow(r) {
    const rw = ownFrame(r, "Project folders");
    const pf = data.projects || { folders: [], max: 16 };
    const helperDoes = (a) => canChange() && (data.helper.projects || []).includes(a);
    // (Restart now by default: a folder removed or made read-only must not stay mounted as before; when no turn runs,
    // such a change still restarts after 30 minutes whatever runs)
    const when = el("select", { id: "set-projects-when", "aria-label": "When the sandbox restarts" },
      el("option", { value: "now", text: "Restart now" }), el("option", { value: "idle", text: "Restart when no Code session has a turn running" }));
    const working = window.bnCode && window.bnCode.working ? window.bnCode.working() : null;
    const PENDING = { add: "Not in the sandbox yet: it sees this folder once it restarts.",
      ro: "Read-only once the sandbox restarts: until then Claude can still change it.",
      rw: "Read-write once the sandbox restarts: read-only there until then." };
    const list = el("ul", { class: "set-projects", id: "set-projects" });
    for (const f of pf.folders) {
      const li = el("li", { class: `set-project${f.ok ? "" : " left-out"}`, "data-project": f.id },
        el("span", { class: "set-project-name", text: f.name }), " ",
        el("span", { class: "note", text: f.hidden ? `${f.host} → ${f.path} (its path kept out of what Claude Code sends the model)` : f.host }), " ",
        el("span", { class: `badge${f.mode === "ro" ? "" : " badge-local"}`, text: f.mode === "ro" ? "read-only" : "read-write" }));
      if (!f.ok) li.append(el("p", { class: "error", text: `Left out of the sandbox: ${f.why}` }));
      else if (PENDING[f.pending]) li.append(el("p", { class: "note set-project-pending", text: `Applies when the sandbox restarts — ${PENDING[f.pending]} (./stack project apply, or the next ./stack up)` }));
      // (a linked worktree or a submodule's checkout: its repository is never shared — its hooks and configuration
      // would let the sandbox run code here when you use git there)
      const LINKED = { worktree: "This is a linked git worktree", submodule: "This is a git submodule's checkout" };
      if (f.linked) {
        li.append(el("p", { class: "note set-project-git", "data-linked": f.linked,
          text: f.linked === "other" ? "Its .git leads to a git folder elsewhere: git won't work on it inside the sandbox, which doesn't share that folder. To use git there, add the repository that holds it instead."
            : `${LINKED[f.linked]}: git won't work on it inside the sandbox (its history lives in the main repository's .git, which isn't shared). To use git there, add the main repository instead.` }));
      }
      const acts = el("span", { class: "set-project-actions" });
      if (f.mode === "rw") {
        const ro = el("button", { type: "button", class: "action", text: "Make read-only", "data-act": "project-mode-ro" });
        ro.disabled = !helperDoes("project-mode-ro");
        ro.addEventListener("click", () => askPassword({ kind: "project", action: "project-mode-ro", project: f.id, when: when.value },
          `Make ${f.name} read-only?`, `Claude may then read ${f.name} but never change it. ${RESTART_ENDS}`, "Make read-only"));
        acts.append(ro);
      }
      const rm = el("button", { type: "button", class: "action", text: "Remove", "data-act": "project-remove" });
      rm.disabled = !helperDoes("project-remove");
      rm.addEventListener("click", () => askPassword({ kind: "project", action: "project-remove", project: f.id, when: when.value },
        `Remove ${f.name} from the sandbox?`, `The folder on this computer is untouched; its sessions stay on the Code page (Folders no longer added). ${RESTART_ENDS}`, "Remove"));
      acts.append(rm);
      li.append(acts);
      list.append(li);
    }
    for (const x of pf.leaving || []) {
      list.append(el("li", { class: "set-project leaving" }, el("span", { class: "note", text: x.path }), " ",
        el("p", { class: "note set-project-pending", text: `Removed, but still in the sandbox (${x.mode === "ro" ? "read-only" : "read-write"}) until it restarts — ./stack project apply, or the next ./stack up.` })));
    }
    if (!pf.folders.length && !(pf.leaving || []).length) list.append(el("li", { class: "note", text: "None yet: the sandbox sees only the workspace." }));
    rw._main.append(list);
    // adding: on this computer only
    const add = el("div", { class: "set-projects-add" });
    const ro = el("input", { type: "checkbox", id: "set-projects-ro" });
    const hide = el("input", { type: "checkbox", id: "set-projects-hide" });
    const pick = el("button", { type: "button", class: "action", id: "set-projects-pick", text: "Choose on this computer…" });
    const local = !data.here.remote;
    pick.disabled = !local || !helperDoes("project-pick") || !data.helper.screen || pf.folders.length >= (pf.max || 16);
    pick.addEventListener("click", () => askPassword({ kind: "project", action: "project-pick", when: when.value, mode: ro.checked ? "ro" : "rw", hide: hide.checked },
      "Choose a folder on this computer's screen?",
      `A folder chooser opens on the screen of the computer running DevOS ADE; nothing is added unless you pick a folder there. ${ro.checked ? "Claude may read it, never change it." : "Read-write: Claude — and anything it runs, or text it reads and follows — can change its files, and what it writes can run on this computer when your own tools open the folder (git hooks, .envrc, VS Code tasks, package.json scripts)."} Every project shares one sandbox: a session in one can read and change the others. ${RESTART_ENDS}`,
      "Open the folder chooser"));
    add.append(el("label", { class: "set-inline" }, ro, " Read-only for Claude"), " ",
      el("label", { class: "set-inline", title: "At /projects/<name> in the sandbox: its path on this computer stays out of what Claude Code sends the model and off the Code page; programs in the sandbox can still find it (/proc/self/mountinfo)" },
        hide, " Hide its path (/projects/<name> in the sandbox)"), " ", pick);
    rw._main.append(add);
    const why = !local ? "Adding a folder works only on the computer running DevOS ADE (its folder chooser opens on that screen)."
      : !data.helper.running ? "Choose on this computer… needs the update helper (./stack helper install)."
        : !(data.helper.projects || []).includes("project-pick") ? "This update helper does not offer project folders yet: ./stack helper install refreshes it."
          : !data.helper.screen ? "The update helper cannot show a dialog on this computer's screen: add a folder in a terminal there." : "";
    if (why) rw._main.append(el("p", { class: "note set-extra", text: why }));
    rw._main.append(el("p", { class: "set-cli" }, el("span", { class: "note", text: "In a terminal on this computer: " }), el("code", { text: "./stack project add ~/path/to/folder" }), " ",
      copyButton("./stack project add ~/path/to/folder")));
    rw._main.append(el("p", { class: "note set-extra", text: `${working ? `${working} Code session${working === 1 ? " has a turn" : "s have turns"} running now. ` : ""}${RESTART_ENDS} Removing a folder or making it read-only never waits more than 30 minutes, whatever runs.` }));
    rw._actions.append(when);
    return rw;
  }

  // What DevOS ADE may read on this computer: your Claude Code and devos-claude sessions of a project folder (the
  // Code page's Import sheet; ./stack sessions, lib/sessions.sh). Allowed only on this computer — in a dialog on its
  // screen when the Code page asks, or ./stack sessions in a terminal there; taken back from anywhere (narrowing), by the
  // project's id, through the update helper. Names and folders are yours (folders.tsv); nothing of a session is here.
  function sessionsConsentRow(r) {
    const rw = ownFrame(r, "What DevOS ADE may read on this computer");
    const sc = data.sessions || { folders: [], suggest: [], setup: [] };
    const setup = sc.setup || [];
    const SETUP = { claude: "your Claude Code setup (~/.claude)", "claude-bedrock": "devos-claude's setup (~/.claude-bedrock)", git: "your Git name and email (~/.gitconfig)" };
    const can = canChange() && (data.helper.sessions || []).includes("sessions-revoke");
    const TOOL = { claude: "Claude Code (~/.claude)", "claude-bedrock": "devos-claude (~/.claude-bedrock)" };   // (keys: the tools' internal names)
    const take = (project, tool, what) => askPassword({ kind: "sessions", action: "sessions-revoke", project, tool },
      `Take back what DevOS ADE may read: ${what}?`,
      "DevOS ADE then reads none of it on this computer until you allow it again there; what the Code page's container read of it (the lists, sessions waiting to be copied) is forgotten. Sessions already copied into the sandbox stay there.",
      "Take back");
    const list = el("ul", { class: "set-projects", id: "set-sessions-consent" });
    for (const f of sc.folders) {
      const b = el("button", { type: "button", class: "action", text: "Take back", "data-act": "sessions-revoke" });
      b.disabled = !can;
      b.addEventListener("click", () => take(f.project, f.tool, `${TOOL[f.tool]} for ${f.name}`));
      list.append(el("li", { class: "set-project", "data-project": f.project, "data-tool": f.tool },
        el("span", { class: "set-project-name", text: TOOL[f.tool] }), " ", el("span", { class: "note", text: `${f.name}: ${f.host}` }), " ",
        el("span", { class: "badge", text: f.scope === "always" ? "always for this folder" : "once (within the hour)" }), " ",
        el("span", { class: "set-project-actions" }, b)));
    }
    for (const x of sc.suggest) {
      const b = el("button", { type: "button", class: "action", text: "Take back", "data-act": "sessions-revoke" });
      b.disabled = !can;
      b.addEventListener("click", () => take("all", "suggest", "the names of the folders your tools keep sessions for"));
      list.append(el("li", { class: "set-project", "data-tool": x.tool },
        el("span", { class: "set-project-name", text: TOOL[x.tool] }), " ", el("span", { class: "note", text: "the names of the folders it keeps sessions for (Suggested projects)" }), " ",
        el("span", { class: "badge", text: x.scope === "always" ? "always" : "once" }), " ", el("span", { class: "set-project-actions" }, b)));
    }
    // Bring your setup: its own consent, per tool (lib/sessions_config.sh)
    for (const x of setup) {
      const b = el("button", { type: "button", class: "action", text: "Take back", "data-act": "sessions-revoke" });
      b.disabled = !can;
      b.addEventListener("click", () => askPassword({ kind: "sessions", action: "sessions-revoke", project: "all", tool: `setup-${x.tool}` },
        `Take back what DevOS ADE may read: ${SETUP[x.tool]}?`,
        "DevOS ADE then reads none of it on this computer until you allow it again there; what the Code page's container read of it (the list, items waiting to be copied) is forgotten. What was copied into the sandbox stays there.",
        "Take back"));
      list.append(el("li", { class: "set-project", "data-tool": `setup-${x.tool}` },
        el("span", { class: "set-project-name", text: "Bring your setup" }), " ", el("span", { class: "note", text: SETUP[x.tool] }), " ",
        el("span", { class: "badge", text: x.scope === "always" ? "always" : "once (within the hour)" }), " ", el("span", { class: "set-project-actions" }, b)));
    }
    if (!sc.folders.length && !sc.suggest.length && !setup.length) list.append(el("li", { class: "note", text: "Nothing: the Code page asks first, in a dialog on this computer's screen (or ./stack sessions import in a terminal there)." }));
    rw._main.append(list);
    if (sc.folders.length || sc.suggest.length) {
      const all = el("button", { type: "button", class: "action", text: "Take back all", id: "set-sessions-revoke-all" });
      all.disabled = !can;
      all.addEventListener("click", () => take("all", "both", "everything, for every folder"));
      rw._actions.append(all);
    }
    rw._main.append(el("p", { class: "note set-extra", text: "Only on the computer running DevOS ADE is anything allowed: the Code page asks in a dialog on its screen (Allow once, or Always). Nothing is ever written back to ~/.claude, ~/.claude-bedrock or ~/.gitconfig; logins, credentials and env settings there are never read — your setup (memory, skills, MCP servers, plugins …) only under Bring your setup's own consent, above." }));
    if (!can && (sc.folders.length || sc.suggest.length || setup.length)) {
      rw._main.append(el("p", { class: "note set-extra", text: !data.helper.running ? "Taking back from here needs the update helper (./stack helper install)." : "Taking back from here needs a newer update helper: ./stack helper install refreshes it." }));
    }
    rw._main.append(el("p", { class: "set-cli" }, el("span", { class: "note", text: "In a terminal on this computer: " }), el("code", { text: "./stack sessions consent --revoke-all" }), " ",
      copyButton("./stack sessions consent --revoke-all")));
    return rw;
  }

  // Bring your setup: items of your Claude Code setup and your Git name and email, from this computer into the Code page's
  // sandbox — the Code page's sheet (?setup=1, or the Code tab's own); read only on this computer, after a dialog on its
  // screen (lib/sessions_config.sh)
  function bringSetupRow(r) {
    const rw = ownFrame(r, "Bring your setup");
    rw._main.append(el("p", { class: "note set-extra",
      text: "Your CLAUDE.md, skills, agents, commands, output styles, key bindings, settings.json's permissions, status line, output style and hooks, MCP servers and plugins — and your Git name and email — copied into the sandbox, each your choice, after you see what it brings: its cost in every request on Bedrock, the programs and rules it brings, its possible secrets (left out unless you keep them). Never env, logins or credentials; nothing is written back. Read only on this computer, after a dialog on its screen." }));
    const open = el("button", { type: "button", class: "action", text: "Bring your setup…", id: "set-bring-setup" });
    open.addEventListener("click", () => {
      if (window.bnCode && window.bnCode.openSetup) window.bnCode.openSetup();
      else { try { const u = new URL(appUrl("code")); u.searchParams.set("setup", "1"); window.open(u.href, "_blank", "noopener"); } catch (_) { /* no Code page */ } }
    });
    rw._actions.append(open);
    rw._main.append(el("p", { class: "set-cli" }, el("span", { class: "note", text: "Or in a terminal on this computer: " }), el("code", { text: "./stack sessions config import" }), " ",
      copyButton("./stack sessions config import")));
    return rw;
  }

  // Your AI subscriptions (lib/subscriptions.sh, answers.py): a card for each tool in the sandbox — the provider's own
  // client — with what it said of its own login at the last check (yes · which kind / no / not known here), never a
  // login, and the pickers it answers in once signed in. Its next step first: Sign in (it opens in the terminal, where
  // its own sign-in starts), or the setting it waits for (Tools in the sandbox, the browser terminal); Sign out. A tool
  // that is a Chat model has a second line: Chat's own sign-in (Chat's sandbox: a sign-in apart, never the terminal's),
  // with ./stack subscriptions login TOOL --chat and its own Sign out. Sign out runs the tool's own sign-out and Check
  // again (one for each sandbox, under the cards) asks that sandbox again, both through the update helper with the
  // password (narrowing: wherever Settings actions are).
  const SUBS_CHAT_SIGNOUT = ["claude", "codex", "grok"];   // (settings.py SUBS_SIGNOUT_CHAT_TOOLS)
  // the tools the Code page's Who answers offers (code/web/src/types.ts HARNESS_IDS; Gemini CLI is not one of them)
  const SUBS_CODE_AGENTS = ["claude", "codex", "copilot", "cursor", "grok"];
  const andList = (xs) => (xs.length > 1 ? `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}` : xs[0] || "");
  // Local models (localmodels.js): models downloaded from Hugging Face and run on this computer; it fills the row's frame
  function localModelsRow(r) {
    const rw = ownFrame(r, "Local models");
    if (window.bnLocal) window.bnLocal.mount(rw, { askPassword, canChange });
    return rw;
  }
  function subscriptionsRow(r) {
    const rw = ownFrame(r, "Your AI subscriptions");
    const sb = data.subscriptions || { tools: [], sandbox: null, checked_at: null };
    const can = (act) => canChange() && (data.helper.subscriptions || []).includes(act);
    const list = el("ul", { class: "set-prov-grid", id: "set-subscriptions" });
    const termHere = Boolean(APP_URLS.terminal);
    const stateOf = (t, s) => (s.installed === false ? ["not in the sandbox", ""] : s.installed == null ? ["not checked yet", ""]
      : s.signed_in === "yes" ? [`signed in${s.kind_words ? ` · ${s.kind_words}` : ""}${s.how === "file" ? " (its login file is there)" : ""}`, "badge-local"]
        : s.signed_in === "no" ? ["not signed in", ""] : [t.id === "copilot" ? "not known here — /user in Copilot says" : "not known here", ""]);
    // (each with a name of its own: which sandbox it asks — every tool of it)
    const checkButton = (action, title, body, name) => {
      const b = el("button", { type: "button", class: "action", text: "Check again", "data-act": action });
      if (name) b.setAttribute("aria-label", name);
      b.disabled = !can(action);
      b.addEventListener("click", () => askPassword({ kind: "subscriptions", action }, title, body, "Check again"));
      return b;
    };
    for (const t of sb.tools || []) {
      // the card: its name and state (the terminal's and the Code page's sign-in; Chat's has a line of its own), whose
      // plan it uses, and the pickers it answers in
      const st = stateOf(t, t);
      const tone = t.installed === false ? "warn" : t.installed && t.signed_in === "yes" ? "on" : "off";
      const pickers = [SUBS_CODE_AGENTS.includes(t.id) && "the Code page's Who answers", t.chat && "Chat's models", "the terminal's Open"].filter(Boolean);
      const li = el("li", { class: "set-prov", "data-tool": t.id },
        el("div", { class: "set-prov-head" }, el("span", { class: "set-project-name", text: t.name }), " ", provState(st[0], tone)),
        el("p", { class: "note set-prov-meta", text: `${t.provider} · ${t.plan}${t.version ? ` · ${t.version}` : ""} · ${t.command}` }),
        el("p", { class: "set-prov-adds", text: t.id === "claude"
          ? `Adds Claude on your plan to ${andList(pickers)} — the first two while Use my Claude plan is on (below).`
          : `Adds ${t.name} to ${andList(pickers)}.` }));
      // the terminal's and the Code page's sign-in — its one next step first: Sign in (it opens in the terminal), or
      // the setting that puts it in the sandbox, or the browser terminal it opens in
      const term = el("div", { class: "set-subs-where", "data-where": "terminal" }, el("span", { class: "note", text: t.chat ? "Terminal & Code page: " : "" }));
      const acts = el("span", { class: "set-project-actions" });
      if (t.installed === false) {
        acts.append(el("a", { class: "action", href: "#settings/TERMINAL_AI_TOOLS", "data-act": "subscriptions-left-out", "data-setup": "tool-left-out",
          text: "Put it in the sandbox (Tools in the sandbox)", "aria-label": `Put it in the sandbox (Tools in the sandbox): ${t.name}` }));
      } else if (!termHere) {
        // (the terminal it signs in in is off here: where that is turned on — over remote access, or at all)
        acts.append(data.here.remote && terminalOn()
          ? el("a", { class: "action", href: "#settings/REMOTE_TERMINAL", "data-act": "subscriptions-terminal-off", "data-setup": "terminal-remote-off",
            text: "Not over remote access: how to turn it on", "aria-label": `Not over remote access: how to turn the terminal on for ${t.name}` })
          : el("a", { class: "action", href: "#settings/TERMINAL_ENABLED", "data-act": "subscriptions-terminal-off", "data-setup": "terminal-off",
            text: "The browser terminal is off: how to turn it on", "aria-label": `The browser terminal is off: how to turn it on for ${t.name}` }));
      }
      if (t.installed !== false && termHere) {
        const signedIn = t.signed_in === "yes";
        const open = el("button", { type: "button", class: signedIn ? "action" : "action primary", text: signedIn ? "Open in the terminal" : "Sign in",
          // (its name as shown first, then where it goes)
          "aria-label": signedIn ? `Open in the terminal: ${t.name}` : `Sign in (terminal and Code page): ${t.name} opens in the terminal, where its own sign-in starts`, "data-act": "subscriptions-open" });
        open.addEventListener("click", () => {
          // (a launch token for exactly this, made on this click: answers.js launch)
          if (!window.bnAnswers || !window.bnAnswers.launch) return;
          window.bnAnswers.launch("open", t.id).then((url) => {
            showTab("terminal");
            const f = document.querySelector('#frames iframe[data-app="terminal"]');
            if (f) f.src = url;
          }, (e) => { if (e.message !== "signed out") toast(`Could not open it: ${e.message}`); });
        });
        acts.append(open);
      }
      // (shown whenever the tool is there: a sandbox that says "signed out" may still hold a login — its sign-out removes it)
      if (t.signout === "cli" && t.installed !== false) {
        const out = el("button", { type: "button", class: "action", text: "Sign out", "data-act": "subscriptions-signout",
          "aria-label": `Sign out: ${t.name} in the sandbox (terminal and Code page)` });
        out.disabled = !can("subscriptions-signout");
        out.addEventListener("click", () => askPassword({ kind: "subscriptions", action: "subscriptions-signout", tool: t.id },
          `Sign ${t.name} out in the sandbox?`,
          `${t.name}'s own sign-out runs in the sandbox (the terminal's and the Code page's sign-in; Chat's is its own): its login there is removed. If anything in the sandbox may have read it, revoke it at ${t.provider} too.`, "Sign out"));
        acts.append(out);
      }
      term.append(acts);
      if (t.signout === "inside" && t.installed !== false) {
        term.append(el("p", { class: "note", text: `${t.name} signs out inside it: ${t.id === "gemini" ? "/auth signout" : "/logout"} (Open in the terminal).` }));
      }
      li.append(term);
      // Chat's own sign-in (a Chat model only: catalog chat_model yes)
      if (t.chat) {
        const cs = stateOf(t, t.chat);
        const chat = el("div", { class: "set-subs-where", "data-where": "chat", id: `set-subs-chat-${t.id}` },
          el("span", { class: "note", text: "Chat: " }), el("span", { class: `badge ${cs[1]}`.trim(), text: cs[0] }));
        const cacts = el("span", { class: "set-project-actions" });
        const cmd = `./stack subscriptions login ${t.id} --chat`;
        const chatIn = t.chat.signed_in === "yes";
        const signin = el("button", { type: "button", class: chatIn ? "action" : "action primary", text: "Sign in", "aria-expanded": "false",
          "aria-label": `Sign in (Chat): ${t.name}'s command for a terminal on this computer`, "data-act": "subscriptions-chat-signin" });
        const how = el("p", { class: "set-cli", hidden: true }, el("span", { class: "note", text: `Chat's own sign-in, apart from the terminal's — in a terminal on this computer (its link and code show there): ` }),
          el("code", { text: cmd }), " ", copyButton(cmd, `Copy ${t.name}'s Chat sign-in command`));
        signin.addEventListener("click", () => { how.hidden = !how.hidden; signin.setAttribute("aria-expanded", String(!how.hidden)); });
        cacts.append(signin);
        if (SUBS_CHAT_SIGNOUT.includes(t.id) && t.chat.installed !== false) {
          const out = el("button", { type: "button", class: "action", text: "Sign out", "data-act": "subscriptions-signout-chat",
            "aria-label": `Sign out: ${t.name} for Chat` });
          out.disabled = !can("subscriptions-signout-chat");
          out.addEventListener("click", () => askPassword({ kind: "subscriptions", action: "subscriptions-signout-chat", tool: t.id },
            `Sign ${t.name} out for Chat?`,
            `${t.name}'s own sign-out runs in Chat's sandbox: Chat's login is removed (the terminal's stays). Revoke it at ${t.provider} too if that may have been read.`, "Sign out"));
          cacts.append(out);
        } else if (t.id === "copilot") {
          chat.append(el("p", { class: "note", text: "Copilot signs out inside it, and Chat has no screen of it: ./stack subscriptions logout copilot --chat says how." }));
        }
        chat.append(cacts, how);
        li.append(chat);
      }
      // Claude: the switch for Claude on your plan in the Code page and Chat (CODE_CLAUDE_PLAN, shown here: its row is
      // this one — settings-layout.tsv), off by default
      const pk = keys.CODE_CLAUDE_PLAN;
      if (t.id === "claude" && pk) {
        const plan = el("div", { class: "set-subs-where set-subs-plan", "data-for": "CODE_CLAUDE_PLAN", id: "set-row-CODE_CLAUDE_PLAN" },
          el("span", { class: "set-name", id: "set-name-CODE_CLAUDE_PLAN", text: pk.label || "Use my Claude plan in the Code page and Chat" }));
        // (its switch whether the Code page is on or not, as any setting's: with it off, it takes effect once it is on)
        if (editable(pk)) {
          plan.append(el("span", { class: "set-project-actions" }, toggle(pk, shown(pk), "set-name-CODE_CLAUDE_PLAN")));
        } else plan.append(" ", el("span", { class: "badge", text: display(pk) || "Off" }));
        if (!codeOn()) {
          plan.append(" ", el("a", { href: "#settings/CODE_ENABLED", class: "note", "data-setup": "code-off",
            text: "It takes effect with the Code page: Settings › Claude Code › Code page" }));
        }
        // (from your devices, or with changes off here: the way in a terminal on the computer running DevOS ADE)
        if (data.here.remote || !canChange() || !editable(pk)) {
          plan.append(cliLine(pk, "On the computer running DevOS ADE, in a terminal: ", "Copy the command for Use my Claude plan in the Code page and Chat"));
        }
        plan.append(el("p", { class: "note", id: "set-sum-CODE_CLAUDE_PLAN", text: "Off by default: Anthropic's support article and its legal page pull apart on apps like this one — your choice (Details)." }),
          el("details", { class: "set-details" }, el("summary", {}, "Details"), el("p", { class: "note", text: pk.note || "" })));
        li.append(plan);
      }
      list.append(li);
    }
    if (!(sb.tools || []).length) list.append(el("li", { class: "note", text: "No tools listed (catalog/ai-tools.tsv is missing)." }));
    rw._main.append(list);
    // (a search finds the row by its tools' names too)
    rw.dataset.findExtra = `Your AI subscriptions ${(sb.tools || []).map((t) => `${t.name} ${t.provider}`).join(" ")}`;
    // the last check of each sandbox, and Check again: the terminal's (and the Code page's), and Chat's
    const when = sb.checked_at ? new Date(sb.checked_at * 1000).toLocaleString() : "";
    const chatWhen = sb.chat_checked_at ? new Date(sb.chat_checked_at * 1000).toLocaleString() : "";
    const SB = { off: "The sandbox is off: ./stack terminal enable.", down: "The sandbox is not running: ./stack up.", error: "The sandbox did not answer at the last check." };
    const CSB = { off: "Chat's sandbox is off (it runs with the Code page).", down: "Chat's sandbox is not running: ./stack up.", error: "Chat's sandbox did not answer at the last check." };
    rw._main.append(el("p", { class: "note set-subs-checked" }, `${SB[sb.sandbox] || ""}${SB[sb.sandbox] ? " " : ""}${when ? `Terminal and Code page: checked ${when}.` : "Terminal and Code page: not checked yet."} `,
      checkButton("subscriptions-check", "Ask the sandbox's AI tools again?",
        "Each tool's own status command runs in the sandbox (about a second each); only signed in or not, and which kind, is kept.",
        "Check again: every tool in the sandbox (terminal and Code page)")));
    if ((sb.tools || []).some((t) => t.chat)) {
      rw._main.append(el("p", { class: "note set-subs-checked" }, `${CSB[sb.chat_sandbox] || ""}${CSB[sb.chat_sandbox] ? " " : ""}${chatWhen ? `Chat: checked ${chatWhen}.` : "Chat: not checked yet."} `,
        checkButton("subscriptions-check-chat", "Ask Chat's sandbox again?",
          "Each Chat tool's own status command runs in Chat's sandbox; only signed in or not, and which kind, is kept.",
          "Check again: every tool for Chat")));
    }
    rw._main.append(el("p", { class: "note set-extra", text: "Each sign-in is the tool's own, and stays in its own file in that sandbox (Chat's apart from the terminal's): DevOS ADE never opens it, backups leave it out. Anything in that sandbox can read it — Sign out, and revoke it at the provider, if that worries you." }));
    if (!can("subscriptions-check")) {
      rw._main.append(!data.helper.running ? el("p", { class: "note set-extra", text: "Check again and Sign out need the update helper (./stack helper install)." })
        : !canChange() ? el("p", { class: "note set-extra" }, "Settings changes are off for remote access: ",
          el("a", { href: "#settings/REMOTE_ADMIN_ACTIONS", "data-setup": "remote-admin-off", text: "Remote access › Update, settings and diagnostics from your devices" }), ".")
          : el("p", { class: "note set-extra", text: "This update helper does not offer them yet: ./stack helper install refreshes it." }));
    }
    rw._main.append(el("p", { class: "set-cli" }, el("span", { class: "note", text: "In a terminal on this computer: " }), el("code", { text: "./stack subscriptions" }), " ",
      copyButton("./stack subscriptions", "Copy the command ./stack subscriptions")));
    // (from Chat's picker: "Sign in for Chat…" — that tool's Chat row, its Sign in pressed: the command shown; goTo
    // then focuses it, the row highlighted)
    const want = chatAsk.shown();
    const c = want ? rw.querySelector(`#set-subs-chat-${want}`) : null;
    if (c) {
      c.querySelector(".set-cli").hidden = false;
      const b = c.querySelector('[data-act="subscriptions-chat-signin"]');
      if (b) b.setAttribute("aria-expanded", "true");
    }
    return rw;
  }

  function sessionDays() { const k = keys.PORTAL_SESSION_DAYS; return k && /^\d+$/.test(k.value || "") ? Number(k.value) : 30; }

  function sessionsRow(r) {
    const rw = ownFrame(r, "Signed-in devices");
    rw._main.append(el("p", { class: "note set-extra", text: `Each stays signed in for ${sessionDays()} days.` }));
    const others = el("button", { type: "button", class: "action", text: "Sign out other devices" });
    others.disabled = !data.here.allowed;
    others.addEventListener("click", () => askPassword({ kind: "signout" }, "Sign out every other device?",
      "Every other browser, phone and installed app signs in again with the portal password. This browser stays signed in.", "Sign them out"));
    const all = el("form", { method: "post", action: "/logout", class: "set-inline" }, el("button", { type: "submit", class: "action", text: "Sign out everywhere" }));
    rw._actions.append(others, all);
    return rw;
  }

  function modelsRow(r) {
    const rw = ownFrame(r, "Models your key can use");
    const link = (place, text) => el("a", { href: `#settings/${place}`, text });
    rw._main.append(
      el("p", { class: "note set-extra" }, "Which model each app uses: ", link("CHAT_DEFAULT_MODEL", "Chat & voice"), " · ",
        link("CLAUDE_MODEL_OPUS", "Claude Code"), ". Which ones Chat's picker lists: ",
        el("a", { href: `${(data.apps && data.apps.chat) || appUrl("chat")}admin/settings/models`, target: "_blank", rel: "noopener", text: "Chat › Admin settings › Models" }), "."),
      el("details", { class: "set-details" }, el("summary", {}, "Details"),
        el("p", { class: "note", text: "Re-checking asks Bedrock which models your key can use (1-token requests, < $0.01; at most once an hour); the model gateway restarts twice and setup picks the defaults again; about 2 minutes. Hiding a model in Chat's own admin settings does not block it for the API or Claude Code." })));
    rw._actions.append(actionButton("models-recheck", "Re-check models"));
    return rw;
  }

  function fmtBytes(b) { return b == null ? "" : b >= 1e9 ? `${(b / 1e9).toFixed(1)} GB` : b >= 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.round(b / 1e3)} KB`; }

  // Core services: one line (all current / how many have a newer upstream), the table folded under it
  function servicesRow(r) {
    const rw = ownFrame(r, "Core services");
    const main = rw._main;
    const v = data.versions || {}, list = v.services || [];
    if (!list.length) {
      main.append(el("p", { class: "note set-extra", text: "Not read yet: ./stack status (or any ./stack command that starts the stack) writes it." }));
      return rw;
    }
    const pending = list.filter((s) => s.state === "pending"), behind = list.filter((s) => s.state === "behind");
    main.append(el("p", { class: "note set-extra", text: pending.length
      ? `${pending.length} not on this release's pinned version: Update now (Home) or ./stack update brings ${pending.length === 1 ? "it" : "them"}.`
      : behind.length ? `All on this release's pinned versions; ${behind.length} ${behind.length === 1 ? "has" : "have"} a newer upstream release that the next DevOS ADE release will bring.`
        : "Every core service runs the newest release tested for this DevOS ADE." }));
    const say = (s) => s.state === "pending" ? `Update now brings it to ${s.pinned}`
      : s.state === "behind" ? `newer upstream exists (${s.newest}); the next DevOS ADE release will bring it`
        : s.state === "stopped" ? "not running" : "current";
    const tbody = el("tbody");
    for (const s of list) {
      tbody.append(el("tr", {}, el("td", { text: s.name }), el("td", { text: s.running || "–" }), el("td", { text: s.pinned || "–" }),
        el("td", {}, s.notes && /^https:\/\//.test(s.notes) ? el("a", { href: s.notes, target: "_blank", rel: "noopener noreferrer", text: s.newest || "–" }) : (s.newest || "–")),
        el("td", { text: say(s) })));
    }
    rw.append(el("details", { class: "set-details" }, el("summary", {}, "Versions"),
      el("div", { class: "set-backups" }, el("table", {},
        el("thead", {}, el("tr", {}, ...["Service", "Running", "This release", "Newest upstream", ""].map((h) => el("th", { scope: "col", text: h })))), tbody)),
      el("p", { class: "note", text: `Pinned by digest, a few days after upstream ships each release${v.checked ? ` (newest upstream as of ${v.checked})` : ""}. Updating DevOS ADE brings every service to the release it pins. ./stack versions prints the same.` })));
    return rw;
  }

  function backupRow(r) {
    const rw = ownFrame(r, "Backups");
    const main = rw._main;
    const list = (data.backups && data.backups.backups) || [];
    if (list.length) {
      const KIND = { manual: "yours", auto: "before an update", nightly: "nightly", portal: "Back up now" };
      const tbody = el("tbody");
      for (const b of list.slice().reverse()) {
        tbody.append(el("tr", {}, el("td", { class: "set-bk-name", text: b.name }),
          el("td", { text: KIND[b.kind] || b.kind }), el("td", { class: "set-bk-size", text: fmtBytes(b.bytes) }),
          el("td", { text: b.at ? new Date(b.at * 1000).toLocaleString() : "" }),
          el("td", { text: b.rollback ? "needed for Roll back" : "" })));
      }
      rw.append(el("div", { class: "set-backups" }, el("table", {},
        el("thead", {}, el("tr", {}, ...["Backup", "Kind", "Size", "Made", ""].map((h) => el("th", { scope: "col", text: h })))), tbody)));
    } else {
      main.append(el("p", { class: "note set-extra", text: "No backups yet." }));
    }
    rw.append(el("details", { class: "set-details" }, el("summary", {}, "Details"),
      el("p", { class: "note", text: "A backup holds both databases, every stored file and a copy of .env (backups/<time>-portal/, readable only by you; the newest 5 made here are kept). It takes seconds and no service stops; it is refused when the disk could not hold it twice." }),
      el("p", { class: "note", text: "Restoring stays in the terminal (./stack restore backups/<time>): it replaces every chat, key and file with an older state, so it asks twice and should never be one click away from a browser." })));
    rw._actions.append(actionButton("backup", "Back up now"));
    return rw;
  }

  function actionRow(r) {
    const act = r.key.slice(1);
    const [label, button] = { test: ["Smoke test", "Run smoke test"], "check-aws": ["Check the AWS key", "Check (free)"],
      report: ["Status report", "Create status report"] }[act];
    const rw = ownFrame(r, label);
    rw._actions.append(actionButton(act, button));
    return rw;
  }

  function restartRow(r) {
    const rw = ownFrame(r, "Restart a service");
    rw._main.append(el("p", { class: "note set-extra", text: "The portal and Postgres are not restarted on their own." }));
    const sel = el("select", { id: "set-restart", "aria-label": "Service to restart" });
    for (const s of (data.snapshot.choices.restart || [])) sel.append(el("option", { value: s, text: s }));
    const rb = el("button", { type: "button", class: "action", text: "Restart" });
    rb.disabled = !canChange();
    rb.addEventListener("click", () => openAction(`restart-${sel.value}`));
    rw._actions.append(sel, rb);
    return rw;
  }

  function actionButton(act, label) {
    const b = el("button", { type: "button", class: "action", "data-act": act, text: label });
    b.disabled = !canChange() || !(data.helper.diagnostics || []).includes(act);
    b.addEventListener("click", () => openAction(act));
    return b;
  }

  const ACTION_TEXT = {
    "check-aws": ["Check the AWS key?", "Asks AWS who the key belongs to and whether it may call Bedrock (free: no model runs)."],
    "models-recheck": ["Re-check the models?", "About 2 minutes, < $0.01. The model gateway restarts twice; Chat and Claude Code requests in flight may fail."],
    backup: ["Back up now?", "Databases, stored files and .env into backups/<time>/. No service stops."],
    test: ["Run the smoke test?", "About 10 seconds, ~$0.0001 of Bedrock."],
    report: ["Create a status report?", "Runs read-only ./stack commands on this computer and shows the result here."],
  };
  function openAction(act) {
    const t = ACTION_TEXT[act] || [`Restart ${act.slice(8)}?`, "It is recreated with its current settings (10-30 s); requests in flight fail."];
    askPassword({ kind: "action", action: act }, t[0], t[1], "Go");
  }

  // --- Advanced and About this install: read-only values in a compact list, each with why and how it changes ---
  function listItem(r) {
    const k = keys[r.key];
    if (!k) return null;
    const it = el("div", { class: "set-adv-item", "data-key": k.key, id: `set-row-${k.key}` },
      el("div", { class: "set-adv-head" }, el("span", { class: "set-adv-label", text: k.unknown ? k.key : k.label }),
        el("span", { class: `set-adv-value${plain(k) ? "" : " masked"}`, text: display(k) })),
      el("p", { class: "set-sum", text: r.summary || k.note }),
      el("details", { class: "set-details" }, el("summary", {}, "Details"),
        ...(r.summary && k.note ? [el("p", { class: "note", text: k.note })] : []),
        forTerminal([k.key], el("p", { class: "set-cli" }, el("span", { class: "note", text: "Changes with: " }), el("code", { class: "set-adv-cli", text: k.cli }), " ", copyButton(k.cli)))));
    if (changedFromDefault(k)) it.dataset.changed = "1";
    return it;
  }

  // --- spend under the budgets ---
  function renderSpend() {
    if (!spend) return;
    for (const p of document.querySelectorAll("#settings .set-spend")) {
      const k = (spend.keys || []).find((x) => x.alias === p.dataset.alias);
      if (!k || k.error) { p.textContent = k ? k.error : ""; continue; }
      p.textContent = `${usd(k.spend)} spent this period${k.reset_at ? ` · resets ${day(k.reset_at)}` : ""}`;
    }
  }

  // --- the password dialog (own element: the Home dialog belongs to app.js) ---
  function dialog() {
    let d = $("#set-confirm");
    if (d) return d;
    d = el("dialog", { id: "set-confirm", class: "confirm", "aria-labelledby": "set-confirm-title" });
    const form = el("form", { method: "dialog" },
      el("h2", { id: "set-confirm-title" }), el("p", { id: "set-confirm-text" }), el("ul", { id: "set-confirm-keys", class: "set-keys" }),
      el("label", { for: "set-confirm-password", text: "Portal password" }),
      el("input", { id: "set-confirm-password", type: "password", autocomplete: "current-password", required: "" }),
      el("p", { id: "set-confirm-error", class: "error", role: "alert", hidden: "" }),
      el("p", { class: "confirm-buttons" }, el("button", { type: "button", class: "quiet", id: "set-confirm-cancel", text: "Cancel" }),
        el("button", { type: "submit", class: "action primary", id: "set-confirm-ok", text: "Confirm" })));
    d.append(form);
    document.body.append(d);
    form.addEventListener("submit", submit);
    $("#set-confirm-cancel").addEventListener("click", () => {
      const p = pending;
      $("#set-confirm-password").value = ""; pending = null; d.close();
      if (data && p && p.kind === "apply" && !p.form) render();   // a switch or a select goes back to the saved value
    });
    return d;
  }

  function askPassword(what, title, text, ok, keyNames) {
    pending = what;
    const d = dialog();
    $("#set-confirm-title").textContent = title;
    $("#set-confirm-text").textContent = text || "";
    const ul = $("#set-confirm-keys"); ul.replaceChildren(...(keyNames || []).map((n) => el("li", {}, el("code", { text: n }))));
    ul.hidden = !(keyNames && keyNames.length);
    $("#set-confirm-error").hidden = true;
    $("#set-confirm-password").value = "";
    $("#set-confirm-ok").textContent = ok;
    d.showModal();
    $("#set-confirm-password").focus();
  }

  window.bnAskPassword = askPassword;   // (localmodels.js, on Browse models: a save, a removal or a download asks here too)
  function confirmApply(values, title, note, keyNames, form, confirm = []) {
    askPassword({ kind: "apply", values, form, confirm, keys: keyNames, label: title.replace(/^Save |\?$/g, "") }, title,
      `${note || ""} Applied on this computer by the update helper, which checks it again first.`, "Save", keyNames);
  }

  async function post(path, body) {
    const r = await fetch(path, { method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { ...API_HEADERS, "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const d = await r.json().catch(() => ({}));
    if (r.status === 401) { location.assign("/login"); throw new Error("signed out"); }
    return [r, d];
  }

  async function submit(ev) {
    ev.preventDefault();
    const pw = $("#set-confirm-password").value, what = pending;
    if (!pw || !what) return;
    const ok = $("#set-confirm-ok"), err = $("#set-confirm-error");
    ok.disabled = true;
    try {
      let r, d;
      if (what.kind === "apply") [r, d] = await post("/api/settings/apply", { password: pw, base: data.snapshot.base, set: what.values, regen: what.regen || [], confirm: what.confirm || [] });
      else if (what.kind === "reveal") [r, d] = await post("/api/settings/reveal", { password: pw, key: what.key });
      else if (what.kind === "action") [r, d] = await post("/api/settings/action", { password: pw, action: what.action });
      else if (what.kind === "sessions") [r, d] = await post("/api/settings/sessions", { password: pw, action: what.action, project: what.project, tool: what.tool });
      else if (what.kind === "subscriptions") [r, d] = await post("/api/settings/subscriptions", { password: pw, action: what.action, ...(what.tool ? { tool: what.tool } : {}) });
      else if (what.kind === "server") [r, d] = await post("/api/local-models/server", { password: pw, op: what.op, name: what.name || "", url: what.url || "", trust: what.trust === true, key: what.key || "", models: what.models || [] });
      else if (what.kind === "local") [r, d] = await post("/api/local-models/change", { password: pw, action: what.action, repo: what.repo, quant: what.quant });
      else if (what.kind === "project") {
        [r, d] = await post("/api/settings/project", { password: pw, action: what.action, when: what.when,
          ...(what.project ? { project: what.project } : { mode: what.mode, hide: what.hide }) });
      }
      else [r, d] = await post("/api/settings/signout-others", { password: pw });
      if (r.status === 400 && d.fields && what.form) {
        closeDialog();
        showFieldErrors(what.form, d.fields);
        return;
      }
      if (!r.ok) {
        err.textContent = d.fields ? `${d.error} ${Object.entries(d.fields).map(([k, m]) => `${k} ${m}`).join("; ")}` : (d.error || `HTTP ${r.status}`);
        err.hidden = false;
        return;
      }
      closeDialog();
      if (what.kind === "reveal") { showRevealed(what.key, d.value, what.show); return; }
      if (what.kind === "signout") { toast("Every other device is signed out"); return; }
      if (what.kind === "server") { toast(what.op === "probe" ? "Checking the server" : "Sent to the update helper"); if (window.bnLocal) window.bnLocal.serverSent(what, d); return; }
      if (what.kind === "local") { toast(what.action === "local-pull" ? "Download started" : "Removing"); if (window.bnLocal) window.bnLocal.started(); return; }
      // a form's change: what was typed is kept (in this page's memory only) until the helper's answer — a failure
      // opens the form again with it, the reason under the field (reopen)
      const restore = what.kind === "apply" && what.form ? kept(what.form) : null;
      if (what.form) what.form.remove();
      const label = ["action", "project", "sessions", "subscriptions"].includes(what.kind) ? what.action : "settings";
      watch({ id: d.id, kind: label, keys: d.keys, password: Boolean(what.values && "PORTAL_PASSWORD" in what.values), at: Date.now(), restore });
      toast("Sent to the update helper");
    } catch (e) {
      if (e.message === "signed out") return;
      err.textContent = `Could not reach the portal (${e.message}).`; err.hidden = false;
    } finally {
      ok.disabled = false;
    }
  }

  function closeDialog() { $("#set-confirm-password").value = ""; pending = null; $("#set-confirm").close(); }

  function showFieldErrors(form, fields) {
    const e = form.querySelector(".error");
    e.textContent = Object.entries(fields).map(([k, m]) => `${(keys[k] && keys[k].label) || k} ${m}.`).join(" ");
    e.hidden = false;
  }

  function showRevealed(key, value, show) {
    copy(value, key);
    const r = document.querySelector(`#settings .set-row[data-key="${key}"]`);
    if (show && r) {
      const v = r.querySelector(".set-value");
      if (!v) return;
      v.textContent = value; v.classList.remove("masked"); v.classList.add("revealed");
      setTimeout(() => { if (data) render(); }, 30000);   // shown for 30 s
    }
  }

  // --- progress of a change or a diagnostic (the helper's status file, across portal restarts) ---
  function jobBox() {
    return el("section", { class: "job set-job", id: "set-job", "aria-live": "polite", hidden: "" },
      el("div", { class: "job-head" }, el("h2", { id: "set-job-title" }), el("button", { type: "button", class: "quiet", id: "set-job-dismiss", text: "Dismiss" })),
      el("ol", { class: "job-steps", id: "set-job-steps" }), el("p", { class: "job-step", id: "set-job-step", hidden: "" }),
      el("ol", { class: "job-done set-job-done", id: "set-job-done", hidden: "" }),
      el("p", { class: "job-message", id: "set-job-message" }), el("p", { class: "note", id: "set-job-note" }));
  }
  // what a change's steps took, as the helper read them from its log (job.steps: lib/settings_helper.sh _settings_steps):
  // "Check", "Save", "Restart", "Verify" and "Done" are the phases' and the whole change's times; the others its steps
  // ("Restart · LiteLLM's models (live, no restart)"). took: "0.4s", "12s", "1m05s" -> "0.4 s", "12 s", "1 min 5 s"
  const tookText = (t) => String(t || "").replace(/^(\d+)m0?(\d+)s$/, "$1 min $2 s").replace(/^([\d.]+)s$/, "$1 s");
  function stepsOf(job) {
    const phases = {}, steps = [];
    for (const x of Array.isArray(job.steps) ? job.steps : []) {
      if (STEPS.some(([, label]) => label === x.label)) phases[x.label] = x.took; else steps.push(x);
    }
    return { phases, steps };
  }

  const STEPS = [["checking", "Check"], ["applying", "Save"], ["restarting", "Restart"], ["verifying", "Verify"], ["done", "Done"]];
  // how soon to ask again: every 400 ms for a change's first 20 s (most take a few seconds: Done shows at once), then 2 s
  const pollEvery = () => (watching && Date.now() - watching.at < 20000 ? 400 : 2000);
  function watch(w) {
    watching = w;
    renderJob();
    clearTimeout(pollTimer);
    pollTimer = setTimeout(poll, 400);
  }

  async function poll() {
    clearTimeout(pollTimer);
    let a;
    try {
      a = await api("/api/admin/status");
      reconnecting = false;
    } catch (e) {
      if (e.message === "signed out") return;
      reconnecting = true; renderJob();
      pollTimer = setTimeout(poll, 2000);
      return;
    }
    // the helper names each job after its request; one it started right after this one (a nightly backup a change turned
    // on inside its window) may have the status already: this one's result is then among the finished (admin.py)
    let job = a.job;
    if (watching && watching.id && !(job && job.id === watching.id)) job = (a.finished || []).find((j) => j && j.id === watching.id) || job;
    const mine = Boolean(job && watching && watching.id && job.id === watching.id);
    if (watching) watching.job = mine ? job : watching.job;
    // the last step it was seen at: the one a failure is marked on (Check ✕ when it never got further)
    if (mine && STEPS.some(([p]) => p === job.phase) && job.phase !== "done") watching.step = job.phase;
    const finished = mine && (job.phase === "done" || job.phase === "failed");
    renderJob();
    if (watching && !finished && Date.now() - watching.at < 15 * 60000) { pollTimer = setTimeout(poll, pollEvery()); return; }
    if (finished) {
      if (job.action === "report" && job.phase === "done") showReport();
      const w = watching;
      await load();
      if (job.phase === "failed" && w && w.restore && reopen(w.restore, job.message || "")) {
        watching = null;   // (said under the field instead of in the box at the top)
        renderJob();
      } else if (w) w.restore = null;
    }
  }

  // kept(FORM) -> what was typed in a form, to fill it in again: {row: its setting, fields: [[id, value or checked]]}
  function kept(form) {
    const rowEl = form.closest(".set-row[data-key]");
    if (!rowEl) return null;
    const fields = [...form.querySelectorAll("input[id], select[id]")]
      .filter((x) => x.type !== "search" && x.type !== "button")
      .map((x) => [x.id, x.type === "checkbox" || x.type === "radio" ? x.checked : x.value]);
    return { row: rowEl.dataset.key, fields };
  }

  // reopen(KEPT, MESSAGE) -> true when the form is open again with what was typed, and why it failed under the field
  // (an address of a key page as a link; "OPENROUTER_API_KEY: …" said without the key's name: the form is its)
  function reopen(r, message) {
    const rowEl = document.querySelector(`#settings .set-row[data-key="${r.row}"]`);
    const btn = rowEl && rowEl.querySelector(":scope > .set-actions button.action:not([data-act])");
    if (!btn || btn.disabled) return false;
    btn.click();
    const form = rowEl.querySelector(":scope > .set-form");
    if (!form) return false;
    for (const [fid, v] of r.fields) {
      const x = form.querySelector(`#${CSS.escape(fid)}`);
      if (!x) continue;
      if (typeof v === "boolean") { x.checked = v; x.dispatchEvent(new Event("change", { bubbles: true })); } else x.value = v;
    }
    if (form._fill) form._fill();
    const m = String(message).replace(/^[A-Z][A-Z0-9_]{1,60}: /, "");
    const unchanged = / — nothing was changed\.?$/.test(m);
    say(form, `Not saved: ${m.replace(/ — nothing was changed\.?$/, "").replace(/\.$/, "")}.${unchanged ? " Nothing was changed." : ""}`);
    form.scrollIntoView({ block: "nearest" });
    return true;
  }

  function renderJob() {
    const box = $("#set-job");
    if (!box) return;
    const w = watching;
    box.hidden = !w;
    if (!w) return;
    const job = w.job || { phase: "queued", message: "Waiting for the update helper…" };
    const settingsJob = w.kind === "settings";
    $("#set-job-title").textContent = settingsJob ? `Settings change${job.phase === "failed" ? " failed" : job.phase === "done" ? " saved" : ""}`
      : { "check-aws": "AWS key check", "models-recheck": "Model check", backup: "Backup", test: "Smoke test", report: "Status report",
        "project-pick": "Project folder", "project-remove": "Project folder removed", "project-mode-ro": "Project folder read-only" }[w.kind] || `Restart of ${String(w.kind).slice(8)}`;
    const steps = $("#set-job-steps"); steps.replaceChildren();
    steps.hidden = !settingsJob;
    const nowEl = $("#set-job-step"), doneEl = $("#set-job-done");
    nowEl.textContent = ""; doneEl.replaceChildren();
    if (settingsJob) {
      const at = STEPS.findIndex(([p]) => p === job.phase);
      const { phases, steps: done } = stepsOf(job);
      // a failure: the step it failed at marked ✕ (the last one seen; Check when it never got further), those before ✓
      const bad = job.phase === "failed" ? Math.max(0, STEPS.findIndex(([p]) => p === w.step)) : -1;
      STEPS.forEach(([p, label], i) => {
        const state = job.phase === "failed" ? (i < bad ? "ok" : i === bad ? "bad" : "") : i < at || job.phase === "done" ? "ok" : i === at ? "now" : "";
        const text = phases[label] ? `${label} · ${tookText(phases[label])}` : label;
        steps.append(el("li", { class: state, text, ...(state === "bad" ? { "aria-label": `${label}: failed` } : {}) }));
      });
      // the step that runs now and for how long so far (a slow one never looks stuck), and every step done with its time
      const running = job.phase !== "done" && job.phase !== "failed";
      if (running && job.step) {
        const s = job.step_started_at && job.updated_at ? Math.max(0, job.updated_at - job.step_started_at) : 0;
        nowEl.textContent = s >= 1 ? `${job.step}, ${s} s so far` : job.step;
      }
      doneEl.replaceChildren(...done.map((x) => el("li", { text: x.took ? `${x.label} · ${tookText(x.took)}` : x.label })));
    }
    nowEl.hidden = !nowEl.textContent;
    doneEl.hidden = !doneEl.children.length;
    const msg = $("#set-job-message");
    msg.textContent = job.message || "";
    msg.className = `job-message ${job.phase === "failed" ? "bad" : job.phase === "done" ? "good" : ""}`;
    let note = "";
    if (reconnecting) note = "The portal is restarting as part of the change — reconnecting…";
    else if (job.phase === "done" && w.password) note = "This browser stays signed in; every other browser and device signs in again with the new password.";
    else if (!w.job && Date.now() - w.at > 60000) note = "The update helper has not picked this up yet: is it still running? (./stack helper status)";
    else if (job.phase !== "done" && job.phase !== "failed") note = "You can leave this page; the change is carried out on your computer.";
    $("#set-job-note").textContent = note;
    $("#set-job-dismiss").hidden = !(job.phase === "done" || job.phase === "failed");
    $("#set-job-dismiss").onclick = () => { watching = null; renderJob(); };
  }

  async function showReport() {
    try {
      const r = await api("/api/settings/report");
      const box = $("#set-report");
      if (!box || !r.text) return;
      const pre = el("pre", { class: "set-report-text", text: r.text });
      const b = el("button", { type: "button", class: "copy", text: "Copy the report" });
      b.addEventListener("click", () => copy(r.text, "the report"));
      box.replaceChildren(el("p", { class: "cmdline" }, b), pre);
      box.hidden = false;
      box.scrollIntoView({ block: "nearest" });
    } catch (_) { /* the job message says it is ready; ./stack config report prints it too */ }
  }

  // --- Home: "Settings changed: … at …" for a day ---
  function renderNotice() {
    const home = $("#home");
    if (!home || !data || !data.snapshot) return;
    let n = $("#settings-notice");
    const lc = data.snapshot.last_change;
    const at = lc && Date.parse(lc.at);
    const recent = lc && lc.result === "ok" && at && Date.now() - at < 86400000;
    if (!recent) { if (n) n.hidden = true; return; }
    if (!n) {
      n = el("p", { id: "settings-notice", class: "banner settings-notice", role: "status" });
      home.querySelector(".home-head").after(n);
    }
    const names = lc.keys.map((k) => (keys[k] && keys[k].label) || k);
    const first = lc.keys.find((k) => rowOf[k]);
    n.replaceChildren(`Settings changed: ${names.slice(0, 4).join(", ")}${names.length > 4 ? ` and ${names.length - 4} more` : ""} at ${new Date(at).toLocaleString()}${lc.via === "cli" ? " (in a terminal)" : lc.via === "portal-remote" ? " (from a remote device)" : ""}. `,
      el("a", { href: first ? `#settings/${first}` : "#settings", text: "Settings" }));
    n.hidden = false;
  }

  // the place in the address (#settings/<section>[/<KEY>]) once the page is drawn
  function placeFromAddress() {
    const m = /^#settings\/(.+)$/.exec(location.hash);
    if (m) { try { goTo(decodeURIComponent(m[1])); } catch (_) { goTo(m[1]); } }
  }

  // Item menu (ctxmenu.js, JON-821): Copy for a row — its name, the setting's key (as .env spells it), its value (only a
  // plain one shown on the page: a secret is never put in a menu), a link to it. Nothing here changes a setting. No ⋯: a row's
  // switch or button sits where it would; a right-click, a long press or the context-menu key opens the menu.
  bnMenu.bind(page(), ".set-row[data-key]", (row) => {
    const key = row.dataset.key, name = (row.querySelector(".set-name") || {}).textContent || key;
    const v = row.querySelector(".set-value[data-value]");
    return [
      { id: "copy-name", label: "Copy name", run: () => copy(name, "the name") },
      { id: "copy-key", label: "Copy setting key", run: () => copy(key, "the key") },
      { id: "copy-value", label: "Copy value", ...(v && v.dataset.value ? {} : { disabled: true, reason: v ? "It is blank" : "Secrets and lists are not copied from here" }), run: () => copy(v.dataset.value, "the value") },
      { id: "copy-link", label: "Copy link to this setting", sep: true, run: () => copy(`${location.origin}${location.pathname}#settings/${key}`, "the link") },
    ];
  }, { label: (row) => (row.querySelector(".set-name") || {}).textContent, more: false });

  document.addEventListener("bn:tab", (e) => {
    if (e.detail === "settings") load().then(placeFromAddress);
    else { chatAsk.drop(); window.bnSubsChatSignin = ""; if (e.detail === "home" && data) renderNotice(); }
  });
  document.addEventListener("DOMContentLoaded", () => {
    // the More sheet on phones: Settings is a page of the portal, not a new tab
    for (const b of document.querySelectorAll(".sheet-link[data-page]")) {
      b.removeAttribute("href");
      b.addEventListener("click", () => showTab(b.dataset.page));
    }
    if (!data) load().then(() => { if (location.hash.startsWith("#settings/")) placeFromAddress(); });
  });
})();
