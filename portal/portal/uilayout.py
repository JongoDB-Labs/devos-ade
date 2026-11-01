"""Each person's layout of the portal's pages (static/widgets.js; GET and PUT /api/ui/layout): which widgets a page shows,
in what order, how many columns wide and how tall, kept per kind of screen (desktop, tablet, phone) so a phone's layout
never changes the desktop's.

One JSON file in the portal's state dir, written whole and atomically, mode 600:
  {"version": 1, "pages": {"home": {"desktop": [{"id": "spend", "span": 5, "height": "auto", "hidden": false}, ...], ...}}}
A widget that shares its row (Home's Get started and Continue) may carry "sized": true once the person set its width: at
its default span without it, it fills the row while the other is not showing (static/widgets.js usedSpan).
A kind of screen with no entry shows the page's default layout (the page decides it; nothing is stored for it).
The Terminal page (JON-946) keeps more than its widgets for a kind of screen, so its screen is an object, and the person's
quick commands are the page's, the same on every screen:
  "terminal": {"desktop": {"widgets": [...], "views": 2, "split": "cols", "weights": [60, 40]}, "commands": [{"label": "Tests",
  "text": "npm test", "run": true}, ...]}

Strict on the way in: a page or a kind of screen the portal does not know is refused; an entry that is not an object of
the right types is refused; a widget id the page does not have is dropped (an older page, a newer script); a span is
clamped to the widget's minimum and the screen's columns, a height outside Auto, S, M, L is Auto. A terminal screen has
the fields above and no others (views 1 to 4, one on a phone; split cols, rows or grid; at most four weights of 1 to 100);
a quick command is a label of at most 40 and a text of at most 200 printable characters, at most 20 commands. Never HTML,
never more than MAX_BYTES, never more than MAX_ENTRIES widgets a layout. The widget table below is the same as static/widgets.js's
(portal/tests/test_ui_layout.py compares them)."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

VERSION = 1
MAX_BYTES = 32 * 1024
MAX_ENTRIES = 32
DEVICES = {"desktop": 12, "tablet": 6, "phone": 1}   # columns of the grid on each kind of screen
HEIGHTS = ("auto", "s", "m", "l")
# page -> widget id -> narrowest span on a (desktop, tablet) screen; a phone's single column has no width to choose
PAGES: dict[str, dict[str, tuple[int, int]]] = {
    "home": {
        "get-started": (4, 3), "continue": (4, 3), "update-card": (6, 4), "spend": (4, 3), "models": (4, 3),
        "services": (3, 2), "logins": (3, 2), "maint": (3, 2), "claude": (3, 2), "feedback": (3, 2),
    },
    "terminal": {"terminals": (4, 3), "keys": (4, 3), "commands": (3, 2), "projects": (3, 2)},
}
FIXED = {"terminal": ("terminals",)}   # a widget the person cannot hide: the terminals
OBJECT_PAGES = ("terminal",)           # pages whose screen is an object (the widgets and more), not a list of widgets
VIEWS_MAX = 4
SPLITS = ("cols", "rows", "grid")
COMMANDS_MAX, COMMAND_LABEL_MAX, COMMAND_TEXT_MAX = 20, 40, 200


class LayoutError(ValueError):
    """A layout that is refused: the message says why, in words the page can show."""


def empty() -> dict:
    return {"version": VERSION, "pages": {}}


def _entry(raw, page: str, device: str) -> dict | None:
    if not isinstance(raw, dict):
        raise LayoutError("each widget is an object: id, span, height, hidden")
    wid, span, height, hidden = raw.get("id"), raw.get("span"), raw.get("height", "auto"), raw.get("hidden", False)
    sized = raw.get("sized", False)
    if not isinstance(wid, str):
        raise LayoutError("a widget's id is text")
    if isinstance(span, bool) or not isinstance(span, int):
        raise LayoutError("a widget's span is a whole number of columns")
    if not isinstance(height, str):
        raise LayoutError("a widget's height is auto, s, m or l")
    if not isinstance(hidden, bool):
        raise LayoutError("hidden is true or false")
    if not isinstance(sized, bool):
        raise LayoutError("sized is true or false")
    if wid not in PAGES[page]:
        return None   # (a widget this portal does not have: dropped, the rest kept)
    cols = DEVICES[device]
    low = 1 if cols == 1 else PAGES[page][wid][0 if device == "desktop" else 1]
    return {"id": wid, "span": max(low, min(cols, span)), "height": height if height in HEIGHTS else "auto",
            "hidden": hidden and wid not in FIXED.get(page, ()), **({"sized": True} if sized and cols > 1 else {})}


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


def _int(raw, what: str, low: int, high: int) -> int:
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise LayoutError(f"{what} is a whole number")
    return max(low, min(high, raw))


def screen(raw, page: str, device: str):
    """A kind of screen as the page sends it: a list of widgets, or (the Terminal page) an object with its widgets and
    the number of views, how they are split and their weights -> the cleaned one (LayoutError when it is not one)."""
    if page not in OBJECT_PAGES:
        return entries(raw, page, device)
    if not isinstance(raw, dict) or set(raw) - {"widgets", "views", "split", "weights"}:
        raise LayoutError("a terminal screen is an object of widgets, views, split and weights")
    weights = raw.get("weights", [])
    if not isinstance(weights, list) or len(weights) > VIEWS_MAX:
        raise LayoutError(f"weights are a list of at most {VIEWS_MAX} numbers")
    split = raw.get("split", "cols")
    if not isinstance(split, str):
        raise LayoutError("split is cols, rows or grid")
    return {"widgets": entries(raw.get("widgets", []), page, device),
            "views": 1 if device == "phone" else _int(raw.get("views", 1), "views", 1, VIEWS_MAX),
            "split": split if split in SPLITS else "cols",
            "weights": [_int(w, "a weight", 1, 100) for w in weights]}


def commands(raw) -> list[dict]:
    """The quick commands as the page sends them -> the cleaned list: at most COMMANDS_MAX of {label, text, run}."""
    if not isinstance(raw, list) or len(raw) > COMMANDS_MAX:
        raise LayoutError(f"quick commands are a list of at most {COMMANDS_MAX}")
    out = []
    for c in raw:
        if not isinstance(c, dict) or set(c) - {"label", "text", "run"}:
            raise LayoutError("a quick command is an object: label, text, run")
        label, text, run = c.get("label"), c.get("text"), c.get("run", False)
        if not isinstance(label, str) or not isinstance(text, str) or not isinstance(run, bool):
            raise LayoutError("a quick command has a label and a text (words) and run (true or false)")
        if not 0 < len(label) <= COMMAND_LABEL_MAX or not label.isprintable():
            raise LayoutError(f"a label is 1 to {COMMAND_LABEL_MAX} printable characters")
        if not 0 < len(text) <= COMMAND_TEXT_MAX or not text.isprintable():
            raise LayoutError(f"a command is 1 to {COMMAND_TEXT_MAX} printable characters (one line)")
        out.append({"label": label, "text": text, "run": run})
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
            if device == "commands" and page in OBJECT_PAGES:   # (the person's, not a screen's)
                if raw is None:
                    out["pages"].get(page, {}).pop(device, None)
                else:
                    out["pages"].setdefault(page, {})[device] = commands(raw)
                continue
            if device not in DEVICES:
                raise LayoutError(f"no screen called {device[:40]!r}: desktop, tablet or phone")
            if raw is None:
                out["pages"].get(page, {}).pop(device, None)
            else:
                out["pages"].setdefault(page, {})[device] = screen(raw, page, device)
    for p in OBJECT_PAGES:   # (no commands: nothing kept)
        if p in out["pages"] and not out["pages"][p].get("commands", True):
            del out["pages"][p]["commands"]
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
