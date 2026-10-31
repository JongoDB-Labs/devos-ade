"""Each person's layout of the portal's pages (static/widgets.js; GET and PUT /api/ui/layout): which widgets a page shows,
in what order, how many columns wide and how tall, kept per kind of screen (desktop, tablet, phone) so a phone's layout
never changes the desktop's.

One JSON file in the portal's state dir, written whole and atomically, mode 600:
  {"version": 1, "pages": {"home": {"desktop": [{"id": "spend", "span": 5, "height": "auto", "hidden": false}, ...], ...}}}
A kind of screen with no entry shows the page's default layout (the page decides it; nothing is stored for it).

Strict on the way in: a page or a kind of screen the portal does not know is refused; an entry that is not an object of
the right types is refused; a widget id the page does not have is dropped (an older page, a newer script); a span is
clamped to the widget's minimum and the screen's columns, a height outside Auto, S, M, L is Auto. Never HTML, never
more than MAX_BYTES, never more than MAX_ENTRIES widgets a layout. The widget table below is the same as static/widgets.js's
(portal/tests/test_ui_layout.py compares them)."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

VERSION = 1
MAX_BYTES = 16 * 1024
MAX_ENTRIES = 32
DEVICES = {"desktop": 12, "tablet": 6, "phone": 1}   # columns of the grid on each kind of screen
HEIGHTS = ("auto", "s", "m", "l")
# page -> widget id -> narrowest span on a (desktop, tablet) screen; a phone's single column has no width to choose
PAGES: dict[str, dict[str, tuple[int, int]]] = {
    "home": {
        "get-started": (4, 3), "continue": (4, 3), "update-card": (6, 4), "spend": (4, 3), "models": (4, 3),
        "services": (3, 2), "logins": (3, 2), "maint": (3, 2), "claude": (3, 2), "feedback": (3, 2),
    },
}


class LayoutError(ValueError):
    """A layout that is refused: the message says why, in words the page can show."""


def empty() -> dict:
    return {"version": VERSION, "pages": {}}


def _entry(raw, page: str, device: str) -> dict | None:
    if not isinstance(raw, dict):
        raise LayoutError("each widget is an object: id, span, height, hidden")
    wid, span, height, hidden = raw.get("id"), raw.get("span"), raw.get("height", "auto"), raw.get("hidden", False)
    if not isinstance(wid, str):
        raise LayoutError("a widget's id is text")
    if isinstance(span, bool) or not isinstance(span, int):
        raise LayoutError("a widget's span is a whole number of columns")
    if not isinstance(height, str):
        raise LayoutError("a widget's height is auto, s, m or l")
    if not isinstance(hidden, bool):
        raise LayoutError("hidden is true or false")
    if wid not in PAGES[page]:
        return None   # (a widget this portal does not have: dropped, the rest kept)
    cols = DEVICES[device]
    low = 1 if cols == 1 else PAGES[page][wid][0 if device == "desktop" else 1]
    return {"id": wid, "span": max(low, min(cols, span)), "height": height if height in HEIGHTS else "auto", "hidden": hidden}


def entries(raw, page: str, device: str) -> list[dict]:
    """A list of widgets as the page sends it -> the cleaned list (LayoutError when it is not one)."""
    if not isinstance(raw, list) or len(raw) > MAX_ENTRIES:
        raise LayoutError(f"a layout is a list of at most {MAX_ENTRIES} widgets")
    out, seen = [], set()
    for r in raw:
        e = _entry(r, page, device)
        if e and e["id"] not in seen:
            seen.add(e["id"]); out.append(e)
    return out


def merge(stored: dict, change) -> dict:
    """STORED with CHANGE applied: {"version": 1, "pages": {page: {device: list | null}}}. A device named is replaced
    (null: back to the default); one not named is left as it was, so a phone saving never rewrites the desktop's."""
    if not isinstance(change, dict) or set(change) - {"version", "pages"} or change.get("version") != VERSION:
        raise LayoutError(f"a layout is {{\"version\": {VERSION}, \"pages\": {{…}}}}")
    pages = change.get("pages")
    if not isinstance(pages, dict):
        raise LayoutError("pages is an object")
    out = {"version": VERSION, "pages": {p: dict(d) for p, d in stored.get("pages", {}).items()}}
    for page, devices in pages.items():
        if page not in PAGES:
            raise LayoutError(f"no page called {page[:40]!r}")
        if not isinstance(devices, dict):
            raise LayoutError("a page is an object of screens: desktop, tablet, phone")
        for device, raw in devices.items():
            if device not in DEVICES:
                raise LayoutError(f"no screen called {device[:40]!r}: desktop, tablet or phone")
            if raw is None:
                out["pages"].get(page, {}).pop(device, None)
            else:
                out["pages"].setdefault(page, {})[device] = entries(raw, page, device)
    out["pages"] = {p: d for p, d in out["pages"].items() if d}
    return out


def clean(doc) -> dict:
    """What the file holds, read back through the same rules (a damaged or hand-edited file is the defaults, not an error)."""
    try:
        return merge(empty(), doc)
    except LayoutError:
        return empty()


def load(state_dir: Path | None) -> dict:
    if state_dir is None:
        return empty()
    try:
        raw = (state_dir / "ui-layout.json").read_bytes()
        return clean(json.loads(raw)) if len(raw) <= MAX_BYTES else empty()
    except (OSError, ValueError):
        return empty()


def save(state_dir: Path, doc: dict) -> None:
    """DOC to ui-layout.json: written beside it, then renamed over it, so a reader sees the old file or the new one."""
    body = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    if len(body) > MAX_BYTES:
        raise LayoutError("that layout is too big")
    fd, tmp = tempfile.mkstemp(prefix=".ui-layout-", suffix=".tmp", dir=state_dir)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(body)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, state_dir / "ui-layout.json")
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
