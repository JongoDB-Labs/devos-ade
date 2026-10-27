// Send feedback (JON-440 plan A): Bug / Feature / Other, on Home and in Settings › About. Each is a plain link that OPENS
// GITHUB at a prefilled, public issue of the project's repository (GET /api/feedback: portal/feedback.py builds the
// addresses from the DevOS ADE version, this computer's OS and its Docker Compose version, and nothing else). The page
// says what it does: it opens GitHub, the issue is public, and the person submits it there. A prefilled address gives
// the portal no receipt, so no text here, ever, says a report was sent, delivered or received. Nothing is stored in this
// browser or on this computer, and no key or API of any tracker is in this file.
// Loaded after app.js (el, api); settings.js asks for bnFeedback.card() when it draws About, and Home's #feedback is
// filled here.
"use strict";

(() => {
  const REPO = "JongoDB-Labs/devos-ade";
  const PREFIX = `https://github.com/${REPO}/issues/new`;
  const FALLBACK = `${PREFIX}/choose`;   // GitHub's own list of the issue forms, with no prefilled text
  const KINDS = [["bug", "Report a bug"], ["feature", "Suggest a feature"], ["other", "Something else"]];
  const WORDS = {
    title: "Send feedback",
    lede: "Tell us what went wrong or what you would like. The buttons below open GitHub with a form already started; you read it, change it and submit it there.",
    warn: "That issue is public: anyone can read it. Leave out keys, passwords, prompts, file contents and repository or project names.",
    included: "Filled in for you, and nothing else from this install:",
    opens: "Opens GitHub in a new tab",
    unavailable: "Could not read this install's details. The buttons still open GitHub; fill in the details there.",
  };

  // A link from the API is used only when it is the repository's new-issue address over https: anything else is dropped.
  const LINK = /^https:\/\/github\.com\/JongoDB-Labs\/devos-ade\/issues\/new(\?[A-Za-z0-9%+._~=&-]*)?$/;
  function safeLink(u) {
    return typeof u === "string" && u.length <= 600 && LINK.test(u) ? u : "";
  }
  const shown = (v) => (typeof v === "string" && v.length <= 40 ? v : "unknown");
  // the facts line: "DevOS ADE v0.32.2 · macOS 15.1 · Docker Compose 2.40.3"
  function factsLine(f) {
    f = f && typeof f === "object" ? f : {};
    return `DevOS ADE ${shown(f.version)} · ${shown(f.os)} · Docker Compose ${shown(f.compose)}`;
  }

  if (typeof document === "undefined") {
    globalThis.bnFeedback = { _pure: { safeLink, factsLine, WORDS, KINDS, PREFIX, FALLBACK } };
    return;
  }

  let loaded = null;   // the API's answer, once (a failed one is asked again the next time)
  function details() {
    if (!loaded) loaded = api("/api/feedback").catch(() => { loaded = null; return null; });
    return loaded;
  }

  // card(ID) -> the Send feedback block (a section whose headings and ids start with ID), its links filled in when the
  // answer comes.
  function card(id) {
    const facts = el("p", { class: "note fb-facts", text: "Reading this install's version…" });
    const row = el("p", { class: "fb-row" });
    const links = {};
    for (const [kind, label] of KINDS) {
      const a = el("a", { class: "action fb-link", href: FALLBACK, target: "_blank", rel: "noopener noreferrer", title: WORDS.opens, "aria-label": `${label} (${WORDS.opens.toLowerCase()})`, "data-kind": kind }, label);
      links[kind] = a; row.append(a);
    }
    const sec = el("section", { class: "feedback", "aria-labelledby": `${id}-title` },
      el("h2", { id: `${id}-title`, text: WORDS.title }),
      el("p", { class: "note", text: WORDS.lede }),
      el("p", { class: "note fb-warn", role: "note", text: WORDS.warn }),
      row, el("p", { class: "note fb-included" }, `${WORDS.included} `, facts));
    details().then((d) => {
      if (!d) { facts.textContent = WORDS.unavailable; return; }
      facts.textContent = factsLine(d.facts);
      for (const [kind] of KINDS) { const u = safeLink(d.links && d.links[kind]); if (u) links[kind].href = u; }
    });
    return sec;
  }

  window.bnFeedback = { card, _pure: { safeLink, factsLine, WORDS, KINDS, PREFIX, FALLBACK } };
  const home = document.getElementById("feedback");
  if (home) home.replaceWith(card("feedback-home"));
})();
