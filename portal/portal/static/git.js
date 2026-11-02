// The Git page (JON-979): the built-in git server, Forgejo (lib/localgit.sh), in the portal — the Git tab, in the sidebar
// after Files on a big screen and under More on a phone (the way the Terminal is), framing git.<host> like Chat, Admin
// and Files (Caddy has signed the owner in after the portal's own check, caddy/localgit-on.caddy), with a pop-out link.
// Loaded after app.js and mobile.js (deferred; shares their $, el, appUrl and APP_URLS) and adds its elements before
// DOMContentLoaded, so app.js binds the tab like the others.
//   deep links   #git/<owner>/<repo>[/issues[/N] | /pulls[/N] | /src/<branch|tag|commit>/…] — the search's, a notification's.
//                The address keeps only #git (app.js showTab); the page is told the place (bn:place) and loads that path of
//                the git server in the frame. Only those shapes: no other path of the server is reached from an address.
//   off          the local git server is off (LOCALGIT=off), or this is the remote site (its web UI has no host there): the
//                Git tab shows a page of the portal's own — what it is, and Settings › Local git server (catalog/setup-links.tsv
//                git-off) — with no frame and nothing loaded from the git host.
"use strict";

(function (root) {
  const TITLE = "Git — your local git server";
  // Where the off page takes you: the git server's switch (catalog/setup-links.tsv git-off: setting:LOCALGIT)
  const SWITCH = "#settings/LOCALGIT";
  const OWNER = /^[A-Za-z0-9._-]{1,100}$/;
  const SEGMENT = /^[A-Za-z0-9._~%+@=,:-]{1,200}$/;
  // first parts of a path that are the git server's own pages, not an account's name
  const RESERVED = new Set(["admin", "api", "assets", "attachments", "avatars", "devtest", "explore", "issues", "login", "notifications",
    "org", "pulls", "repo", "user", "-"]);
  const dotted = (s) => s === "." || s === "..";

  // A path segment of a file or branch: the characters a name has, and decoded no "." or "..", slash, backslash or control
  function segmentOk(s) {
    if (typeof s !== "string" || !SEGMENT.test(s)) return false;
    let d;
    try { d = decodeURIComponent(s); } catch (_) { return false; }
    return !dotted(d) && !/[/\\\u0000-\u001f\u007f]/.test(d);
  }
  // A code search's query, escaped: decoded, it is text with no control characters (a "/" or ".." in it is the query's text,
  // not the path's)
  function queryOk(s) {
    let d;
    try { d = decodeURIComponent(s); } catch (_) { return false; }
    return d.trim() !== "" && !/[\u0000-\u001f\u007f]/.test(d);
  }
  // The place of the git server's code search for Q: every character but letters, digits and - . _ ~ escaped
  // (encodeURIComponent leaves ! ' ( ) * as they are)
  const codePlace = (q) => `explore/code?q=${encodeURIComponent(String(q)).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)}`;
  // The path of the git server a place names ("" = its front page), or null when it is not one of the shapes above.
  function gitPath(place) {
    const p = place == null ? "" : String(place);
    if (p === "") return "";
    // (a search's 64 characters escaped: up to 12 characters each)
    const m = /^explore\/code\?q=((?:[A-Za-z0-9._~-]|%[0-9A-Fa-f]{2}){1,800})$/.exec(p);
    if (m) return queryOk(m[1]) ? `/explore/code?q=${m[1]}` : null;
    if (p.length > 600) return null;
    const parts = p.split("/");
    if (parts.length < 2 || parts.length > 16 || !OWNER.test(parts[0]) || !OWNER.test(parts[1]) || dotted(parts[0]) || dotted(parts[1])
      || RESERVED.has(parts[0].toLowerCase()) || parts[1].toLowerCase().endsWith(".git")) return null;
    const [owner, repo, what, ...rest] = parts;
    const base = `/${owner}/${repo}`;
    if (what === undefined) return base;
    if (what === "issues" || what === "pulls") {
      if (!rest.length) return `${base}/${what}`;
      return rest.length === 1 && /^[0-9]{1,9}$/.test(rest[0]) ? `${base}/${what}/${rest[0]}` : null;
    }
    if (what === "src") {
      if (rest.length < 2 || !["branch", "tag", "commit"].includes(rest[0]) || !rest.every(segmentOk)) return null;
      return `${base}/src/${rest.join("/")}`;
    }
    return null;
  }
  // The address of PLACE in the git server whose front page is BASE (its origin only is kept: the scheme and host), or null.
  function gitUrl(place, base) {
    const path = gitPath(place);
    const m = /^(https?:\/\/[A-Za-z0-9.-]{1,253}(?::[0-9]{1,5})?)(?:[/?#]|$)/.exec(String(base));
    return path === null || !m ? null : `${m[1]}${path === "" ? "/" : path}`;
  }
  // The place a search result opens: a repository, or one of its issues or pull requests
  function placeOf(x) {
    if (!x || typeof x.repo !== "string" || gitPath(x.repo) === null) return null;
    if (Number.isInteger(x.number) && x.number > 0 && x.number < 1e9) return `${x.repo}/${x.pr ? "pulls" : "issues"}/${x.number}`;
    return x.repo;
  }

  // the Git tab, as the sidebar and the More sheet show it
  const NAV = Object.freeze({ tab: "git", label: "Git", item: "git-item", title: TITLE, popout: "Open Git in its own window",
    note: "Your local git server: repositories, branches, pull requests" });

  root.bnGit = { codePlace, _pure: { TITLE, SWITCH, NAV, gitPath, gitUrl, placeOf, segmentOk, codePlace } };
  if (typeof document === "undefined" || typeof document.querySelector !== "function") return;

  const state = (() => {
    try { return JSON.parse(document.querySelector('meta[name="bn-git"]').content) || {}; } catch (_) { return {}; }
  })();
  const here = Boolean(state.here && APP_URLS.git);
  const NS = "http://www.w3.org/2000/svg";
  const icon = (d) => {
    const s = document.createElementNS(NS, "svg"), p = document.createElementNS(NS, "path");
    s.setAttribute("viewBox", "0 0 20 20"); s.setAttribute("aria-hidden", "true"); p.setAttribute("d", d); s.append(p);
    return s;
  };
  // a branch: two nodes on a line and a third that leaves it
  const BRANCH = "M6 3.5v13M6 12.5c0-3 8-1.5 8-6M6 5.2a1.7 1.7 0 1 0 0-.01M6 14.8a1.7 1.7 0 1 0 0-.01M14 6a1.7 1.7 0 1 0 0-.01";
  const POPOUT = "M11 4h5v5M16 4l-7 7M14 12v4H4V6h4";

  // Sidebar: after Files, with a pop-out like the other apps — or, while the git server is off here, muted with an "off" pill
  // (no pop-out: its page is the portal's own).
  function addTab() {
    const files = $(".tabs .tab[data-tab=files]");
    const settings = $(".tabs .tab[data-tab=settings]");
    const after = files ? files.closest("li") : null;
    const before = settings ? settings.closest("li") : $(".tabs .more-item");
    if (!after && !before) return;
    const li = here
      ? el("li", { class: NAV.item },
        el("button", { type: "button", class: "tab", "data-tab": NAV.tab }, icon(BRANCH), NAV.label),
        el("a", { class: "popout", "data-app": "git", href: appUrl("git"), target: "_blank", rel: "noopener",
          title: NAV.popout, "aria-label": NAV.popout }, icon(POPOUT)))
      : el("li", { class: `${NAV.item} off` },
        el("button", { type: "button", class: "tab", "data-tab": NAV.tab, "data-label": "Git (off)" }, icon(BRANCH), NAV.label,
          el("span", { class: "tab-off", text: "off" })));
    if (after) after.after(li); else before.before(li);
  }
  // Phone: under More, with the Terminal (the bottom bar has no room for it)
  function addSheetLink() {
    const tools = $("#more-sheet .sheet-tools");
    if (!tools) return;
    const link = el("a", { class: "sheet-link", href: "#git", id: "more-git" }, NAV.label,
      el("span", { text: here ? NAV.note : "Off: what it is and how to turn it on" }));
    const settings = tools.querySelector('[data-page="settings"]');
    const li = el("li", {}, link);
    if (settings) settings.closest("li").before(li); else tools.append(li);
  }

  // the deep link: the frame loads that path of the git server (a place that is none of the shapes loads its front page)
  function route() {
    document.addEventListener("bn:place", (e) => {
      const d = e.detail || {};
      if (d.tab !== "git" || typeof d.place !== "string") return;
      const url = gitUrl(d.place, appUrl("git"));
      if (url === null) return;
      if (d.place.startsWith("explore/code") && state.code_search !== true) return;
      appFrame("git").src = url;
    });
  }
  // Open the Git tab at PLACE (the search's way in)
  function open(place) {
    const hash = place ? `#git/${place}` : "#git";
    if (place && gitPath(place) === null) { showTab("git"); return; }
    if (location.hash === hash) showTab(hash.slice(1)); else location.hash = hash;
  }

  // --- the Git tab while the git server is off here: a page of the portal (no frame, nothing from the git host) ---
  const code = (t) => el("code", { text: t });
  function toSettings() {
    if (location.hash === SWITCH) showTab(SWITCH.slice(1)); else location.hash = SWITCH;
  }
  function offPage() {
    const remoteOnly = state.enabled === true;   // on, but this is the remote site
    const card = el("div", { class: "code-off-card" });
    if (remoteOnly) {
      card.append(
        el("p", { class: "code-off-lede", text: "The local git server is on, on the computer running DevOS ADE: open the portal there and this tab opens it. Its web UI has no address on the remote site, so it is not shown over remote access." }));
    } else {
      const turnOn = el("button", { type: "button", class: "action primary", id: "git-off-settings", text: "Turn on in Settings" });
      turnOn.addEventListener("click", toSettings);
      const cmd = "./stack config set LOCALGIT on";
      const copyBtn = el("button", { type: "button", class: "copy", text: "Copy" });
      copyBtn.addEventListener("click", () => copy(cmd, "the command"));
      card.append(
        el("p", { class: "code-off-lede", text: "The local git server is off. It is a git server of this computer (Forgejo): repositories, branches, issues and pull requests, with no GitHub or GitLab in between, and the Code page's sandbox pushes and pulls to it." }),
        el("p", { class: "code-off-actions" }, turnOn, el("span", { class: "note", text: "on the computer running DevOS ADE" })),
        el("p", { class: "note" }, "Settings › Claude Code › ", el("a", { href: SWITCH, "data-setup": "git-off", text: "Local git server" }),
          " turns it on. Or in a terminal, in your DevOS ADE folder:"),
        el("p", { class: "cmdline" }, code(cmd), " ", copyBtn),
        el("p", { class: "note", text: "Turning it off kept your repositories (they stay in a Docker volume), so turning it on again brings them back." }));
    }
    const head = el("header", { class: "home-head code-off-head" },
      el("p", { class: "eyebrow", "aria-hidden": "true", text: "DevOS ADE · Git" }),
      el("h1", { id: "git-off-title" }, el("span", { class: "code-off-icon", "aria-hidden": "true" }, icon(BRANCH)), TITLE,
        el("span", { class: "code-off-pill", text: remoteOnly ? "not on the remote site" : "off" })));
    const page = el("section", { id: "git", class: "code-off-page", "aria-labelledby": "git-off-title", hidden: "" }, head, card);
    $("#frames").before(page);
    PAGES.push("git");
  }

  addTab();
  addSheetLink();
  if (here) route(); else offPage();
  root.bnGit.open = open;
})(typeof window !== "undefined" ? window : globalThis);
