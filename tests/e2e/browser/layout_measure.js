// The layout sweep's measurement (tests/e2e/browser/layout_sweep.py evaluates this file in the page): one call measures
// the document as it is laid out now and returns what collides or is cut off. Reads only; the one thing it changes is
// focus and scroll positions while it checks that an element out of view can be reached (both put back).
//
//   overlaps     two visible things in the same layer whose boxes intersect: text over text, a control over text or over
//                another control, an icon or image over text. Not: an element and its own ancestor or descendant (a
//                button and its label), things in different layers (a fixed bar, a dialog, a menu, a toast, a sheet, a
//                popover or any positioned element with a z-index of 2 or more over the page; a sticky header over the
//                list it scrolls), sizes under 2 px, a box with nothing painted (no text, background, border or
//                image), lines of one text, and boxes that only touch (under 3 px, or a quarter of the smaller text's
//                height, of overlap). Two things inside one scrolling box are compared where they are in that box, so
//                what is scrolled away still counts; one inside it and one outside only where it shows.
//   clipped      text cut by an ellipsis, a line clamp, a box that hides what overflows (not one that scrolls), the
//                edge of a window that cannot scroll, or a <select> narrower than its chosen option. "meaning": its
//                element is (in) a heading, a control, a label, a tab, a badge or a chip (or named *title*, *label*,
//                *name*…); the rest is "content". A truncation that keeps at least 10 characters and half the text and
//                gives the whole in a title or aria-label is "intended".
//   hscroll      the document scrolls sideways: how far, and the elements that reach past the window's right edge.
//   small        a pointer target under 24 x 24 px (WCAG 2.2, 2.5.8) whose 24 px circle meets another target or
//                another small target's circle; links and link-like buttons inside a sentence are exempt.
//   unreachable  something you can Tab to that no scrolling brings into view: clipped by a box that does not scroll,
//                beyond a scroll range, or past the edge of a window that does not scroll (and it does not appear
//                when focused, as a skip link does).
(opts) => {
  opts = opts || {};
  const VW = opts.vw || window.innerWidth, VH = opts.vh || window.innerHeight;
  const MAX = opts.max || 60;
  const els = (window.__lay = []);   // registry: findings name elements by index, for the screenshots
  const reg = (e) => { let i = els.indexOf(e); if (i < 0) { i = els.length; els.push(e); } return i; };
  const cs = new Map();
  const style = (e) => { let s = cs.get(e); if (!s) { s = getComputedStyle(e); cs.set(e, s); } return s; };
  const R = (r) => ({ l: r.left, t: r.top, r: r.right, b: r.bottom });
  const area = (r) => Math.max(0, r.r - r.l) * Math.max(0, r.b - r.t);
  const inter = (a, b) => ({ l: Math.max(a.l, b.l), t: Math.max(a.t, b.t), r: Math.min(a.r, b.r), b: Math.min(a.b, b.b) });
  const round = (r) => r && ({ x: Math.round(r.l), y: Math.round(r.t), w: Math.round(r.r - r.l), h: Math.round(r.b - r.t) });
  const INTERACTIVE = 'button, a[href], input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=tab], ' +
    '[role=checkbox], [role=switch], [role=menuitem], [role=menuitemradio], [role=menuitemcheckbox], [role=option], [role=combobox], [role=slider], ' +
    '[role=separator][tabindex], [tabindex]:not([tabindex="-1"])';
  const HEADING = 'h1, h2, h3, h4, h5, h6, [role=heading], legend, caption, dt, th';
  const LABELISH = /(^|[-_\s])(title|label|name|badge|chip|pill|tag|tab|tabs|head|header|btn|button|kbd|count|state|status|eyebrow|brand|cost|crumb)s?($|[-_\s])/i;

  // --- visibility -------------------------------------------------------------------------------------------------
  // (an ancestor that hides it: opacity 0, a visually-hidden helper — 1 px with its overflow clipped, clip-path
  // inset(50%), clip rect(0 0 0 0); memoized per ancestor)
  const ancMemo = new Map();
  const ancOK = (p) => {
    if (!p || p.nodeType !== 1 || p === document.documentElement) return true;
    if (ancMemo.has(p)) return ancMemo.get(p);
    const q = style(p);
    let ok = parseFloat(q.opacity) >= 0.05 && !(q.clipPath && /inset\(\s*50%/.test(q.clipPath))
      && !(q.clip && q.clip !== 'auto' && /rect\(0(px)?,?\s*0(px)?/.test(q.clip));
    if (ok && /(hidden|clip)/.test(q.overflowX + q.overflowY)) { const r = p.getBoundingClientRect(); if (r.width <= 2 || r.height <= 2) ok = false; }
    ok = ok && ancOK(p.parentElement);
    ancMemo.set(p, ok);
    return ok;
  };
  const shown = (e) => {
    if (!e || !e.isConnected) return false;
    if (e.checkVisibility && !e.checkVisibility({ opacityProperty: true, visibilityProperty: true, contentVisibilityAuto: true })) return false;
    const s = style(e);
    if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse') return false;
    return ancOK(e);
  };

  // --- what clips an element: its containing-block chain up to the window ------------------------------------------
  // Each step: an ancestor whose overflow clips (hidden / clip: a person cannot scroll it; auto / scroll: can), or
  // contain: paint; a positioned element skips ancestors that are not its containing block (it escapes their
  // overflow), a fixed one all but a transformed one. The window ends every chain: it scrolls in an axis unless the
  // document's overflow (html's, or body's propagated to it) hides it there.
  const rootOv = (() => {
    const h = style(document.documentElement), b = document.body ? style(document.body) : h;
    const pick = (hv, bv) => (hv !== 'visible' ? hv : bv);
    return { x: pick(h.overflowX, b.overflowX), y: pick(h.overflowY, b.overflowY) };
  })();
  const docH = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
  const docW0 = Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0);
  const VIEW = { el: null, view: true, rect: { l: 0, t: 0, r: VW, b: VH }, sx: !/(hidden|clip)/.test(rootOv.x), sy: !/(hidden|clip)/.test(rootOv.y),
    range: { l: -window.scrollX, t: -window.scrollY, r: docW0 - window.scrollX, b: docH - window.scrollY } };
  const makesCB = (s) => s.transform !== 'none' || s.filter !== 'none' || s.perspective !== 'none' || /paint|layout|strict|content/.test(s.contain || '')
    || /transform|filter/.test(s.willChange || '');
  const chains = new Map();
  // SELF: the element's own overflow too (for its text: an ellipsis or a box that hides its own overflow cuts it)
  const chainOf = (e, self) => {
    const key = self ? 'self' : 'kids';
    let m = chains.get(e);
    if (m && m[key]) return m[key];
    const out = [];
    let pos = self ? 'static' : style(e).position;
    for (let p = self ? e : e.parentElement; p && p !== document.documentElement; p = p.parentElement) {
      const s = style(p);
      if (pos === 'fixed' && !makesCB(s)) continue;
      if (pos === 'absolute' && s.position === 'static' && !makesCB(s)) continue;
      const paint = /paint|strict|content/.test(s.contain || '');
      const clipsX = s.overflowX !== 'visible' || paint, clipsY = s.overflowY !== 'visible' || paint;
      if ((clipsX || clipsY) && p !== document.body) {
        const r = p.getBoundingClientRect();
        const bl = parseFloat(s.borderLeftWidth) || 0, bt = parseFloat(s.borderTopWidth) || 0;
        // the padding box (a scrollbar inside it is not taken off: it is not content)
        const rect = { l: r.left + bl, t: r.top + bt, r: r.left + bl + p.clientWidth, b: r.top + bt + p.clientHeight };
        if (!clipsX) { rect.l = -1e6; rect.r = 1e6; }
        if (!clipsY) { rect.t = -1e6; rect.b = 1e6; }
        const sx = clipsX && /(auto|scroll)/.test(s.overflowX), sy = clipsY && /(auto|scroll)/.test(s.overflowY);
        out.push({ el: p, rect, sx, sy,
          // its scroll range: what of its content a person can scroll to (from the start of its scrolled area to its end)
          range: { l: rect.l - p.scrollLeft, t: rect.t - p.scrollTop, r: rect.l - p.scrollLeft + p.scrollWidth, b: rect.t - p.scrollTop + p.scrollHeight } });
      }
      // what clips P clips E from here on: P's own position decides (a static one inside an absolute E's containing
      // block: that block's)
      if (!(s.position === 'static' && (pos === 'fixed' || pos === 'absolute') && !makesCB(s))) pos = s.position;
    }
    out.push(VIEW);
    if (!m) chains.set(e, (m = {}));
    m[key] = out;
    return out;
  };
  const ok = (v) => v && v.r - v.l > 0.5 && v.b - v.t > 0.5;
  // one axis of a step: a box that scrolls brings what lies in its scroll range into its box (the part that fits);
  // one that does not only shows what lies in it
  const axis = (v, c, lo, hi, scroll) => {
    if (!scroll) { v[lo] = Math.max(v[lo], c.rect[lo]); v[hi] = Math.min(v[hi], c.rect[hi]); return v; }
    v[lo] = Math.max(v[lo], c.range[lo]); v[hi] = Math.min(v[hi], c.range[hi]);
    if (v[hi] - v[lo] <= 0.5) return v;
    const size = v[hi] - v[lo], box = c.rect[hi] - c.rect[lo];
    if (size >= box) { v[lo] = c.rect[lo]; v[hi] = c.rect[hi]; }
    else if (v[lo] < c.rect[lo]) { v[hi] += c.rect[lo] - v[lo]; v[lo] = c.rect[lo]; }
    else if (v[hi] > c.rect[hi]) { v[lo] -= v[hi] - c.rect[hi]; v[hi] = c.rect[hi]; }
    return v;
  };
  // what of R a person can bring into view by scrolling (each step of CHAIN up to STOP, exclusive)
  const reachable = (r, chain, stop) => {
    let v = { ...r };
    for (const c of chain) {
      if (c === stop) break;
      v = axis(axis(v, c, 'l', 'r', c.sx), c, 't', 'b', c.sy);
      if (!ok(v)) return null;
    }
    return v;
  };
  // what of R shows now, as everything is scrolled (each step's box, up to STOP)
  const showsNow = (r, chain, stop) => {
    let v = { ...r };
    for (const c of chain) {
      if (c === stop) break;
      v = inter(v, c.rect);
      if (!ok(v)) return null;
    }
    return v;
  };

  // --- layers: what may lie over the page on purpose ------------------------------------------------------------------
  const layers = new Map();
  const layerOf = (e) => {
    if (layers.has(e)) return layers.get(e);
    let L = null;
    for (let p = e; p && p !== document.documentElement; p = p.parentElement) {
      const s = style(p);
      let top = false;
      try { top = p.matches('dialog:modal, :popover-open, :fullscreen'); } catch (_) { top = p.matches('dialog[open]'); }
      const z = parseInt(s.zIndex, 10);
      if (top || s.position === 'fixed' || ((s.position === 'absolute' || s.position === 'relative') && z >= 2 && p.matches('[role=dialog], [role=menu], [role=listbox], [role=tooltip], [role=alertdialog], [role=status], [role=alert], [popover], dialog') )
          || (s.position === 'absolute' && z >= 2)) { L = p; break; }
      if (s.position === 'sticky') {
        // stuck (its scrolling box is scrolled): over what scrolls under it; at rest it is in the flow
        let sc = p.parentElement;
        while (sc && sc !== document.body && !/(auto|scroll|hidden)/.test(style(sc).overflowY + style(sc).overflowX)) sc = sc.parentElement;
        const scrolled = sc && sc !== document.body ? (sc.scrollTop > 0 || sc.scrollLeft > 0) : (window.scrollY > 0 || window.scrollX > 0);
        if (scrolled) { L = p; break; }
      }
    }
    layers.set(e, L);
    return L;
  };

  // --- describing an element ------------------------------------------------------------------------------------------
  const one = (e) => {
    if (!e || e.nodeType !== 1) return '';
    let d = e.tagName.toLowerCase();
    if (e.id && !/^[\w-]*\d{3,}/.test(e.id)) d += '#' + e.id;
    const t = e.getAttribute('data-testid'); if (t) d += `[data-testid=${t}]`;
    const cls = typeof e.className === 'string' ? e.className.trim().split(/\s+/).filter((c) => c && !/^(open|in|cur|on|off|show|active|hover|focus|unread|has-[\w-]+|is-[\w-]+)$/.test(c)).slice(0, 2) : [];
    if (cls.length) d += '.' + cls.join('.');
    const role = e.getAttribute('role'); if (role && !t) d += `[role=${role}]`;
    const k = e.getAttribute('data-k') || e.getAttribute('data-tab') || e.getAttribute('data-section'); if (k) d += `[${k}]`;
    return d;
  };
  const path = (e) => { const parts = []; for (let p = e, i = 0; p && p.nodeType === 1 && p !== document.body && i < 3; p = p.parentElement, i++) parts.unshift(one(p)); return parts.join(' > '); };
  const textOf = (e) => ((e.innerText || e.value || e.getAttribute('aria-label') || e.title || '').trim().replace(/\s+/g, ' ')).slice(0, 60);
  const about = (e, text) => ({ id: reg(e), path: path(e), text: (text != null ? text : textOf(e)).slice(0, 60) });
  const control = (e) => e.closest(INTERACTIVE);
  const painted = (e) => {
    const s = style(e);
    if (!/^(transparent|rgba\(0, 0, 0, 0\))$/.test(s.backgroundColor) || s.backgroundImage !== 'none' || s.boxShadow !== 'none') return true;
    if (['Top', 'Right', 'Bottom', 'Left'].some((k) => parseFloat(s[`border${k}Width`]) > 0 && s[`border${k}Style`] !== 'none')) return true;
    if (/^(INPUT|SELECT|TEXTAREA|IMG|SVG|CANVAS|VIDEO)$/i.test(e.tagName)) return true;
    return Boolean(e.querySelector('img, svg, canvas, video'));
  };

  // --- the items: runs of text (each text node's line boxes), controls, images and icons -----------------------------
  const items = [];
  const scope = document.body || document.documentElement;
  const tw = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, { acceptNode: (n) => (n.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT) });
  const shownMemo = new Map();
  const isShown = (e) => { if (!shownMemo.has(e)) shownMemo.set(e, shown(e)); return shownMemo.get(e); };
  const textEls = new Set();
  for (let n = tw.nextNode(); n; n = tw.nextNode()) {
    const el = n.parentElement;
    if (!el || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|OPTION|TITLE|OPTGROUP|TEXTAREA)$/.test(el.tagName) || el.closest('svg, select')) continue;
    if (!isShown(el)) continue;
    const range = document.createRange(); range.selectNodeContents(n);
    const rs = [...range.getClientRects()].filter((q) => q.width > 1 && q.height > 2).map(R);
    if (!rs.length) continue;
    const box = rs.reduce((a, b) => ({ l: Math.min(a.l, b.l), t: Math.min(a.t, b.t), r: Math.max(a.r, b.r), b: Math.max(a.b, b.b) }));
    items.push({ kind: 'text', el, rs, box, text: n.nodeValue.trim().replace(/\s+/g, ' ').slice(0, 60), ctl: control(el) });
    textEls.add(el);
  }
  for (const e of scope.querySelectorAll(INTERACTIVE)) {
    if (!isShown(e)) continue;
    const r = R(e.getBoundingClientRect());
    if (r.r - r.l < 2 || r.b - r.t < 2) continue;
    if (!painted(e) && !textOf(e)) continue;   // a box with nothing painted (a link stretched over a card)
    // (a link that wraps in running text: its line pieces, not the box around both lines)
    const rs = style(e).display === 'inline' ? [...e.getClientRects()].filter((q) => q.width > 1 && q.height > 1).map(R) : [r];
    items.push({ kind: 'control', el: e, rs: rs.length ? rs : [r], box: r, ctl: e });
  }
  for (const e of scope.querySelectorAll('img, svg, canvas, video')) {
    if (e.tagName.toLowerCase() === 'svg' && e.parentElement && e.parentElement.closest('svg')) continue;
    if (control(e) || !isShown(e)) continue;
    const r = R(e.getBoundingClientRect());
    if (r.r - r.l < 6 || r.b - r.t < 6) continue;
    items.push({ kind: 'graphic', el: e, rs: [r], box: r, ctl: null });
  }

  // --- overlaps -------------------------------------------------------------------------------------------------------
  const overlaps = [];
  const seenPair = new Set();
  const sorted = items.map((it, i) => ({ it, i })).sort((a, b) => a.it.box.t - b.it.box.t);
  const related = (a, b) => a === b || a.contains(b) || b.contains(a);
  for (let x = 0; x < sorted.length && overlaps.length < MAX; x++) {
    const A = sorted[x].it;
    for (let y = x + 1; y < sorted.length; y++) {
      const B = sorted[y].it;
      if (B.box.t >= A.box.b) break;
      if (B.box.l >= A.box.r || B.box.r <= A.box.l) continue;
      if (A.kind === 'graphic' && B.kind === 'graphic') continue;
      if (A.kind !== 'text' && B.kind !== 'text' && !(A.kind === 'control' && B.kind === 'control')) continue;
      // an element and its own text, a control and what is inside it
      if (related(A.el, B.el)) continue;
      if (A.kind === 'control' && B.ctl && related(A.el, B.ctl)) continue;
      if (B.kind === 'control' && A.ctl && related(B.el, A.ctl)) continue;
      // (one text node, two parents: never; two text nodes of one element side by side: inline flow, never over each other)
      if (A.kind === 'text' && B.kind === 'text' && A.el === B.el) continue;
      if (layerOf(A.el) !== layerOf(B.el)) continue;
      let hit = null;
      for (const ra of A.rs) {
        for (const rb of B.rs) {
          const i = inter(ra, rb);
          const ix = i.r - i.l, iy = i.b - i.t;
          if (ix < 3 || iy < 3) continue;
          const minH = Math.min(ra.b - ra.t, rb.b - rb.t), minW = Math.min(ra.r - ra.l, rb.r - rb.l);
          // text boxes are the font's whole height: lines set tight touch by a few px without their letters meeting
          if ((A.kind === 'text' || B.kind === 'text') && iy < Math.max(3, 0.25 * minH)) continue;
          if (ix < Math.max(3, Math.min(8, 0.25 * minW))) continue;
          if (!hit || ix * iy > (hit.r - hit.l) * (hit.b - hit.t)) hit = i;
        }
      }
      if (!hit) continue;
      // where both show: each as it shows now inside its own boxes, up to the first box they share (B does not move
      // when only A's box scrolls); inside a shared box that scrolls they move together, so the overlap counts wherever
      // it lies in it — but a shared box that hides its overflow (below the first shared one that scrolls) still cuts
      const ca = chainOf(A.el, A.kind === 'text'), cb = chainOf(B.el, B.kind === 'text');
      const common = ca.find((c) => cb.includes(c));
      const va = showsNow(hit, ca, common), vb = va && showsNow(va, cb, common);
      if (!vb) continue;
      let vis = vb;
      for (const c of ca.slice(ca.indexOf(common))) {
        if (c.sx || c.sy) break;
        vis = inter(vis, c.rect);
      }
      if (vis.r - vis.l < 3 || vis.b - vis.t < 3) continue;
      const kind = A.kind === 'text' && B.kind === 'text' ? 'text over text' : (A.kind === 'graphic' || B.kind === 'graphic') ? 'icon over text'
        : A.kind === 'control' && B.kind === 'control' ? 'control over control' : 'control over text';
      const [P, Q] = [A, B].sort((m, n) => (path(m.el) + m.kind < path(n.el) + n.kind ? -1 : 1));
      const key = kind + '|' + path(P.el) + '|' + path(Q.el);
      if (seenPair.has(key)) continue;
      seenPair.add(key);
      overlaps.push({ kind, a: { ...about(P.el, P.kind === 'text' ? P.text : null), box: round(P.box) }, b: { ...about(Q.el, Q.kind === 'text' ? Q.text : null), box: round(Q.box) },
        at: round(vis), w: Math.round(vis.r - vis.l), h: Math.round(vis.b - vis.t) });
    }
  }

  // --- clipped text ---------------------------------------------------------------------------------------------------
  const clipped = [];
  const meaningOf = (e) => {
    if (e.closest(HEADING)) return 'heading';
    if (e.closest('button, a[href], [role=button], [role=tab], [role=link], [role=menuitem], [role=option], summary, label, select, [role=switch], [role=checkbox]')) return 'control';
    for (let p = e, i = 0; p && p !== document.body && i < 2; p = p.parentElement, i++) {
      if (typeof p.className === 'string' && LABELISH.test(p.className)) return 'label';
    }
    return 'content';
  };
  const intended = (e, shownFrac, fullText) => {
    const full = (e.getAttribute('title') || e.getAttribute('aria-label') || (e.closest('[title]') || {}).title || '').trim();
    const chars = Math.floor(fullText.length * shownFrac);
    return Boolean(full) && full.replace(/\s+/g, ' ').includes(fullText.slice(0, 20)) && shownFrac >= 0.5 && chars >= 10;
  };
  const doneClip = new Set();
  const squeezed = new Map();
  const squeeze = (e, text) => { if (!squeezed.has(e) && squeezed.size < 20) squeezed.set(e, { ...about(e, (text || '').slice(0, 60)), box: round(R(e.getBoundingClientRect())), w: e.clientWidth, h: e.clientHeight }); };
  const addClip = (e, how, needW, haveW, extra) => {
    if (doneClip.has(e) || clipped.length >= MAX) return;
    doneClip.add(e);
    const text = (extra && extra.text) || textOf(e);
    if (!text) return;
    const frac = needW > 0 ? Math.max(0, Math.min(1, haveW / needW)) : 1;
    const meaning = meaningOf(e);
    clipped.push({ how, meaning, intended: intended(e, frac, text), ...about(e, text), box: round(R(e.getBoundingClientRect())), need: Math.round(needW), have: Math.round(haveW),
      shown: Math.round(frac * 100) });
  };
  for (const el of textEls) {
    const s = style(el);
    // an ellipsis or a box that hides what overflows it: its own text wider (or a clamp taller) than the box
    if (/(hidden|clip)/.test(s.overflowX) && el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0) {
      addClip(el, s.textOverflow === 'ellipsis' ? 'ellipsis' : 'overflow hidden', el.scrollWidth, el.clientWidth);
      continue;
    }
    if (/(hidden|clip)/.test(s.overflowY) && (s.webkitLineClamp !== 'none' && s.webkitLineClamp) && el.scrollHeight > el.clientHeight + 1) {
      addClip(el, 'line clamp', el.scrollHeight, el.clientHeight);
    }
  }
  // cut by an ancestor that hides overflow, or by the edge of a window that does not scroll
  for (const it of items) {
    if (it.kind !== 'text' || doneClip.has(it.el) || clipped.length >= MAX) continue;
    const chain = chainOf(it.el, true);
    let need = 0, have = 0;
    // (a text's box is its font's whole height, taller than a tight line: a box that hides its overflow trims a few
    // px off the top and bottom without touching a letter — only a cut across, or of more than a third of the height,
    // counts)
    let cutX = 0, cutY = 0;
    for (const r of it.rs) {
      need += area(r); const v = reachable(r, chain, null); have += v ? area(v) : 0;
      if (!v) { cutX = Math.max(cutX, r.r - r.l); cutY = Math.max(cutY, 1); continue; }
      cutX = Math.max(cutX, (r.r - r.l) - (v.r - v.l)); cutY = Math.max(cutY, 1 - (v.b - v.t) / (r.b - r.t));
    }
    if (cutX <= 2 && cutY < 0.34) continue;
    if (need > 0 && need - have > Math.max(8, 0.04 * need)) {
      const by = chain.find((c) => { for (const r of it.rs) { const v = reachable(r, [c], null); if (!v || area(v) < area(r) - 1) return true; } return false; });
      // a scrolling box smaller than the text in it: scrolled, it shows (a long line of code in a block that scrolls
      // sideways) — unless the box is squeezed under 48 px, then the box is the fault, said once for the box
      if (by && !by.view && ((by.sy && it.box.b - it.box.t > by.rect.b - by.rect.t) || (by.sx && it.box.r - it.box.l > by.rect.r - by.rect.l))) {
        if ((by.sy && by.rect.b - by.rect.t < 48) || (by.sx && by.rect.r - by.rect.l < 48)) squeeze(by.el, it.text);
        continue;
      }
      addClip(it.el, by && by.view ? 'past the window edge' : 'cut by ' + (by ? one(by.el) : 'its box'), need, have);
    }
  }
  // any scrolling box with content squeezed under 24 px in the axis it scrolls
  for (const e of scope.querySelectorAll('*')) {
    const s = style(e);
    if (!/(auto|scroll)/.test(s.overflowY + s.overflowX) || !isShown(e)) continue;
    if ((/(auto|scroll)/.test(s.overflowY) && e.scrollHeight > e.clientHeight + 2 && e.clientHeight < 24 && e.clientWidth > 24)
        || (/(auto|scroll)/.test(s.overflowX) && e.scrollWidth > e.clientWidth + 2 && e.clientWidth < 24 && e.clientHeight > 24)) squeeze(e, textOf(e));
  }
  // a <select> narrower than the option it shows
  const canvas = document.createElement('canvas').getContext('2d');
  for (const e of scope.querySelectorAll('select')) {
    if (!isShown(e) || clipped.length >= MAX) continue;
    const o = e.options[e.selectedIndex]; if (!o) continue;
    const s = style(e);
    canvas.font = `${s.fontStyle} ${s.fontWeight} ${s.fontSize} ${s.fontFamily}`;
    const need = canvas.measureText(o.label || o.text).width;
    const arrow = s.appearance === 'none' || s.webkitAppearance === 'none' ? 0 : 20;
    const have = e.clientWidth - (parseFloat(s.paddingLeft) || 0) - (parseFloat(s.paddingRight) || 0) - arrow;
    if (need > have + 2) addClip(e, 'select narrower than its option', need, have, { text: (o.label || o.text).trim().slice(0, 60) });
  }

  // --- sideways scroll ------------------------------------------------------------------------------------------------
  const docW = docW0;
  let hscroll = null;
  if (VIEW.sx && docW > VW + 1) {
    const wide = [];
    for (const it of items) {
      if (it.box.r > VW + 1 && !chainOf(it.el).some((c) => !c.view && c.sx)) wide.push(it);
    }
    wide.sort((a, b) => b.box.r - a.box.r);
    const pick = [];
    for (const it of wide) { if (!pick.some((p) => p.el.contains(it.el) || it.el.contains(p.el))) pick.push(it); if (pick.length >= 4) break; }
    hscroll = { by: Math.round(docW - VW), els: pick.map((it) => ({ ...about(it.el, it.kind === 'text' ? it.text : null), box: round(it.box) })) };
  }

  // --- small targets (WCAG 2.5.8) -------------------------------------------------------------------------------------
  const small = [];
  const targets = [];
  for (const e of scope.querySelectorAll(INTERACTIVE)) {
    if (e.disabled || e.closest('[inert]') || !isShown(e)) continue;
    if (e.matches('[role=separator]')) continue;   // a resize handle: dragged, and its keyboard part is the focus ring
    let r = R(e.getBoundingClientRect());
    if (r.r - r.l < 1 || r.b - r.t < 1) continue;
    if (!reachable(r, chainOf(e), null)) continue;
    // a field with the label around it (a search pill), a checkbox or radio with its label: one target
    if (e.matches('input, select, textarea')) {
      const lab = e.closest('label') || (e.matches('input[type=checkbox], input[type=radio]') && e.id && document.querySelector(`label[for="${CSS.escape(e.id)}"]`));
      if (lab) { const q = R(lab.getBoundingClientRect()); r = { l: Math.min(r.l, q.l), t: Math.min(r.t, q.t), r: Math.max(r.r, q.r), b: Math.max(r.b, q.b) }; }
    }
    // where it is compared: inside its nearest scrolling box (they scroll together), or as it shows now
    const sc = chainOf(e).find((c) => c.sx || c.sy);
    targets.push({ e, r, sc: sc && !sc.view ? sc.el : null, now: Boolean(showsNow(r, chainOf(e), null)) });
  }
  const inSentence = (e) => {
    const s = style(e);
    if (!/^inline/.test(s.display) || s.display === 'inline-flex' || s.display === 'inline-grid') return false;
    let blk = e.parentElement;
    while (blk && /^inline/.test(style(blk).display)) blk = blk.parentElement;
    if (!blk) return false;
    const all = (blk.innerText || '').replace(/\s+/g, ' ').trim(), own = (e.innerText || '').replace(/\s+/g, ' ').trim();
    return all.length >= own.length + 12;
  };
  const smallOnes = targets.filter((t) => (t.r.r - t.r.l < 23.5 || t.r.b - t.r.t < 23.5) && !inSentence(t.e));
  for (const t of smallOnes) {
    if (small.length >= MAX) break;
    const cx = (t.r.l + t.r.r) / 2, cy = (t.r.t + t.r.b) / 2;
    // its 24 px circle against every other target's box, and against other small targets' circles
    let near = null;
    for (const o of targets) {
      if (o === t || o.e.contains(t.e) || t.e.contains(o.e)) continue;
      if (!(o.sc === t.sc || (o.now && t.now))) continue;
      if (layerOf(o.e) !== layerOf(t.e)) continue;
      const isSmall = smallOnes.includes(o);
      const ox = (o.r.l + o.r.r) / 2, oy = (o.r.t + o.r.b) / 2;
      if (isSmall) { if (Math.hypot(cx - ox, cy - oy) < 24) { near = o; break; } continue; }
      const dx = Math.max(o.r.l - cx, 0, cx - o.r.r), dy = Math.max(o.r.t - cy, 0, cy - o.r.b);
      if (Math.hypot(dx, dy) < 12) { near = o; break; }
    }
    if (near) small.push({ ...about(t.e), box: round(t.r), w: Math.round(t.r.r - t.r.l), h: Math.round(t.r.b - t.r.t), near: path(near.e) });
  }

  // --- focusable but out of reach -------------------------------------------------------------------------------------
  const unreachable = [];
  if (opts.reach !== false) {
    const tabbable = [...scope.querySelectorAll(INTERACTIVE)].filter((e) => !e.disabled && !e.closest('[inert]') && e.tabIndex >= 0 && isShown(e));
    for (const e of tabbable) {
      if (unreachable.length >= MAX) break;
      const r = R(e.getBoundingClientRect());
      if (r.r - r.l < 1 || r.b - r.t < 1) continue;
      const v = reachable(r, chainOf(e), null);
      const enough = v && (v.r - v.l >= Math.min(8, r.r - r.l) && v.b - v.t >= Math.min(8, r.b - r.t));
      if (enough) continue;
      // a skip link and its kind: shown when focused
      const before = document.activeElement, scrolls = [];
      for (const c of chainOf(e)) if (c.el) scrolls.push([c.el, c.el.scrollLeft, c.el.scrollTop]);
      const wx = window.scrollX, wy = window.scrollY;
      let ok = false;
      try {
        e.focus({ preventScroll: true });
        cs.clear(); chains.clear();
        const r2 = R(e.getBoundingClientRect());
        const v2 = reachable(r2, chainOf(e), null);
        ok = Boolean(v2 && v2.r - v2.l >= 8 && v2.b - v2.t >= 8);
      } catch (_) { ok = false; }
      try { if (before && before.focus) before.focus({ preventScroll: true }); else e.blur(); } catch (_) { /* nothing */ }
      for (const [el, x, y] of scrolls) { el.scrollLeft = x; el.scrollTop = y; }
      window.scrollTo(wx, wy);
      cs.clear(); chains.clear();
      if (ok) continue;
      const by = chainOf(e).find((c) => { const w = reachable(r, [c], null); return !w || w.r - w.l < Math.min(8, r.r - r.l) || w.b - w.t < Math.min(8, r.b - r.t); });
      unreachable.push({ ...about(e), box: round(r), why: by ? (by.view ? 'past the edge of a window that does not scroll there' : `clipped by ${one(by.el)}${by.sx || by.sy ? ' (outside its scroll range)' : ' (which does not scroll)'}`) : 'not shown' });
    }
  }

  return { vw: VW, vh: VH, docW, overlaps, clipped, squeezed: [...squeezed.values()], hscroll, small, unreachable, items: items.length,
    title: document.title, url: location.href };
}
