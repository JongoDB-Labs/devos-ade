"""What a Code page check leaves on the code host when it fails or skips: the sessions it opened, and any session still
working or waiting for an answer, stopped and closed (checks_code's tidy_sessions, after each check: common.run_all).
The backend runs at most four such sessions at once and refuses another ("4 sessions are working or waiting for you",
409): one turn left hanging — Bedrock unreachable, a question that never came — would fail every later check that opens
a session, and the page those load would still show it. Standard library only: tests/test_e2e_harness.sh runs it
against code/web/dev/mock-server.mjs, without a browser or a stack."""

from __future__ import annotations

import re

# the sessions the running check opened through the page's API (checks_code's Code.api)
OPENED: set[str] = set()
_OPENS = re.compile(r"/api/sessions(/[^/?#]+/continue)?")
_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def note(method: str, path: str, r) -> None:
    """Every answer of the page's API: a session it opened (POST /api/sessions, or …/ID/continue) is remembered."""
    j = r.get("json") if isinstance(r, dict) else None
    if (method.upper() == "POST" and r.get("status") == 200 and _OPENS.fullmatch(path) and isinstance(j, dict)
            and isinstance(j.get("id"), str) and _ID.fullmatch(j["id"])):
        OPENED.add(j["id"])


def close_left(api, interrupt=None) -> str:
    """Closes every open session the check opened (OPENED) and every one still working or waiting for an answer — the
    page opens sessions of its own, which only the second rule finds — with DELETE /api/sessions/ID, as a person's
    close: its process ends, its transcript stays. A working one's turn is stopped first (interrupt); if that fails,
    closing it ends the turn anyway. An idle session of another check stays (the backend closes one of those itself
    to make room; later checks use some). api(method, path) -> {status, json, text}: the page's own client;
    interrupt(session_id). -> what it did, for the log ("" when nothing was left). OPENED is forgotten either way."""
    try:
        st = api("GET", "/api/state")
        if st.get("status") != 200 or not isinstance(st.get("json"), dict):
            raise RuntimeError(f"GET /api/state: {st.get('status')} {str(st.get('text'))[:120]}")

        def waiting(s):
            return s.get("pending") if isinstance(s.get("pending"), int) and s.get("pending") > 0 else 0

        left = [s for s in st["json"].get("sessions") or [] if isinstance(s, dict) and s.get("open") is True
                and isinstance(s.get("id"), str) and _ID.fullmatch(s["id"])
                and (s["id"] in OPENED or s.get("state") != "idle" or waiting(s))]
        said = []
        for s in left:
            how = [str(s.get("state"))[:20]] + ([f"{waiting(s)} waiting"] if waiting(s) else [])
            if interrupt is not None and s.get("state") == "busy":
                try:
                    interrupt(s["id"])
                    how.append("stopped")
                except Exception as e:  # noqa: BLE001 — closing it ends the turn too
                    how.append(f"not stopped: {type(e).__name__}")
            r = api("DELETE", f"/api/sessions/{s['id']}")
            if r.get("status") not in (200, 404):   # (404: no longer open)
                how.append(f"DELETE {r.get('status')}")
            said.append(f"{s['id'][:8]} ({', '.join(how)})")
        if not left:
            return ""
        # (said when one is still open: the checks after it may meet the limit again)
        ids = {s["id"] for s in left}
        after = (api("GET", "/api/state").get("json") or {}).get("sessions") or []
        still = [s["id"][:8] for s in after if isinstance(s, dict) and s.get("open") is True and s.get("id") in ids]
        return (f"closed {len(left)} session{'s' if len(left) != 1 else ''} it left: {'; '.join(said)}"
                + (f" — still open: {', '.join(still)}" if still else ""))
    finally:
        OPENED.clear()
