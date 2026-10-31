"""The UI control inventory (JON-869): what a user can see and click on each page and state, recorded by ui_sweep.py into
controls.json and compared between two releases by tests/e2e/ui_inventory_diff.py. No Playwright import: unit-tested alone."""

from __future__ import annotations

import re

# Visible interactive controls of a document (run in the page, one frame at a time) -> {visible: [...], hidden: [...]}.
# Visible: rendered with a box, not visibility:hidden, not in [hidden] or a closed <details> (its summary excepted), and
# not taken from assistive technology or the pointer either: not inside [inert] or [aria-hidden=true], not at opacity 0.
# hidden: controls with an id that are in the document but not visible (a control that went away without leaving).
COLLECT_CONTROLS = r"""() => {
  const SEL = 'button, a[href], input:not([type=hidden]), select, textarea, summary, ' +
    '[role=button], [role=tab], [role=menuitem], [role=switch], [role=checkbox], [role=link]';
  const sq = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const roleOf = (el) => {
    const r = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
    if (r) return r;
    const t = el.tagName.toLowerCase();
    if (t === 'a') return 'link';
    if (t === 'select') return 'combobox';
    if (t === 'textarea') return 'textbox';
    if (t === 'summary') return 'summary';
    if (t === 'input') {
      const ty = (el.getAttribute('type') || 'text').toLowerCase();
      if (['button', 'submit', 'reset', 'image'].includes(ty)) return 'button';
      if (ty === 'checkbox' || ty === 'radio') return ty;
      return ty === 'range' ? 'slider' : 'textbox';
    }
    return t;
  };
  const nameOf = (el) => {
    const al = sq(el.getAttribute('aria-label'));
    if (al) return al;
    const by = el.getAttribute('aria-labelledby');
    if (by) {
      const n = sq(by.split(/\s+/).map((i) => { const e = document.getElementById(i); return e ? e.textContent : ''; }).join(' '));
      if (n) return n;
    }
    const t = el.tagName.toLowerCase(), ty = (el.getAttribute('type') || '').toLowerCase();
    if (t === 'input' && ['button', 'submit', 'reset'].includes(ty)) { const v = sq(el.value); if (v) return v; }
    if (el.labels && el.labels.length) { const n = sq([...el.labels].map((l) => l.textContent).join(' ')); if (n) return n; }
    if (t !== 'input' && t !== 'select' && t !== 'textarea') {
      const tx = sq(el.innerText || el.textContent);
      if (tx) return tx;
      const im = el.querySelector('img[alt]');
      if (im && sq(im.getAttribute('alt'))) return sq(im.getAttribute('alt'));
    }
    return sq(el.getAttribute('title')) || (t === 'input' ? sq(el.getAttribute('placeholder')) : '');
  };
  const shown = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return false;
    if (el.closest('[inert], [aria-hidden="true"]')) return false;
    for (let a = el; a; a = a.parentElement) {
      if (a.hidden) return false;
      if (parseFloat(getComputedStyle(a).opacity) === 0) return false;
      const p = a.parentElement;
      if (p && p.tagName === 'DETAILS' && !p.open && !(a.tagName === 'SUMMARY' && p.querySelector(':scope > summary') === a)) return false;
    }
    return true;
  };
  const visible = [], hidden = [];
  for (const el of document.querySelectorAll(SEL)) {
    if (shown(el)) {
      visible.push({ role: roleOf(el), name: nameOf(el).slice(0, 160), disabled: el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true',
                     id: el.id || '' });
    } else if (el.id) hidden.push(el.id);
  }
  return { visible, hidden };
}"""

_RULES = (   # (pattern, replacement), in this order: ids and versions before times before bare numbers
    (re.compile(r"\bv\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.]+)?"), "<ver>"),
    (re.compile(r"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?"), "<time>"),
    (re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?(?:\s?[AaPp][Mm])?"), "<time>"),
    (re.compile(r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.? \d{1,2}(?:,? \d{4})?"), "<time>"),
    (re.compile(r"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,}\b"), "<id>"),
    (re.compile(r"\d+(?:[.,]\d+)*"), "#"),
)


def normalize_name(name: str) -> str:
    """An accessible name without its volatile parts: versions -> <ver>, dates and times -> <time>, hex ids -> <id>, other
    numbers -> #; whitespace collapsed."""
    s = " ".join((name or "").split())
    for pat, rep in _RULES:
        s = pat.sub(rep, s)
    return s


def normalize_controls(raw: dict, frame: str = "") -> tuple[list[dict], list[str]]:
    """A frame's COLLECT_CONTROLS answer -> (visible controls with normalized names, hidden ids), FRAME ("" for the page)."""
    vis = [{"role": c["role"], "name": normalize_name(c["name"]), "disabled": bool(c["disabled"]), "id": c["id"], "frame": frame}
           for c in raw.get("visible", [])]
    return vis, [f"{frame}#{i}" if frame else f"#{i}" for i in raw.get("hidden", [])]


def merge_state(book: dict, key: str, vis: list[dict], hidden: list[str]) -> None:
    """Add one frame's controls to BOOK[key] (a state captured twice, or its frames, unite; no duplicates)."""
    cur = book.setdefault(key, {"visible": [], "hidden_ids": []})
    for c in vis:
        if c not in cur["visible"]:
            cur["visible"].append(c)
    for h in hidden:
        if h not in cur["hidden_ids"]:
            cur["hidden_ids"].append(h)
