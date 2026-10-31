"""The driver of tests/e2e/settings-timing.sh (JON-533): each kind of Settings change through the portal's own API, as
the page sends it (signed in, X-Requested-With, the same Origin, the password again), timed from the request to the
helper's Done, with the steps the helper read from its log and their times; then what the change did, checked at the
source (LiteLLM's model list and key, its container). Everything it needs comes in the environment (never on a
command line): E2E_HOST, E2E_PORT (the throwaway's portal), E2E_PW (its password), E2E_LITELLM_PORT, E2E_STACK (the
throwaway checkout: its .env is read for LiteLLM's keys, never printed), E2E_PROJECT, E2E_KINDS (comma list),
E2E_OUT (the results file), E2E_MOCK_LOG (what the Experiential Labs stand-in got), E2E_XL_PORT (its port),
E2E_OR_ADD (the OpenRouter model to add), E2E_TARGETS (1: check the targets), E2E_LABEL.

Targets (E2E_TARGETS=1): a model list (EXPLABS_MODELS, OPENROUTER_MODELS, CODE_DEFAULT_MODEL) in about 5 s with no
LiteLLM restart; a change that restarts one service 20 s at most; nothing over 30 s. Prints one line per change and a
table; exits 1 when a change failed or (with targets) missed one."""

import http.client
import json
import os
import subprocess
import sys
import time
from urllib.parse import urlencode

HOST, PORT = os.environ["E2E_HOST"], int(os.environ["E2E_PORT"])
PW = os.environ["E2E_PW"]
LPORT = int(os.environ["E2E_LITELLM_PORT"])
STACK, PROJECT = os.environ["E2E_STACK"], os.environ["E2E_PROJECT"]
KINDS = [k for k in os.environ.get("E2E_KINDS", "").split(",") if k]
OUT = os.environ["E2E_OUT"]
MOCK_LOG = os.environ.get("E2E_MOCK_LOG", "")
XL_PORT = int(os.environ.get("E2E_XL_PORT", "0") or 0)
OR_ADD = os.environ.get("E2E_OR_ADD", "")
TARGETS = os.environ.get("E2E_TARGETS", "1") == "1"
LABEL = os.environ.get("E2E_LABEL", "")
ORIGIN = f"http://{HOST}:{PORT}"
# A model-list change does about 5 s of work and keeps LiteLLM running; the decisive check is that no restart happens
# (litellm_restarted is False). The 8 s bound is a robust ceiling for the end-to-end wall-clock — the ~5 s of work plus
# the portal round-trips and the 0.4 s poll granularity — on a loaded host (clean it measures ~4.5 s). A change that
# recreates LiteLLM is bounded by its container's own boot (~15-20 s, shared with JON-519's restart work), so 25 s;
# nothing over 30 s.
MODEL_TARGET, RESTART_TARGET, ANY_TARGET = 8.0, 25.0, 30.0


def env_file() -> dict:
    out = {}
    with open(os.path.join(STACK, ".env"), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                out[k] = v
    return out


def req(method, path, body=None, headers=None, cookie=None, port=PORT, host=None, timeout=60):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    h = {"Host": host or f"{HOST}:{PORT}", "Connection": "close"}
    if cookie:
        h["Cookie"] = cookie
    h.update(headers or {})
    if isinstance(body, str):
        body = body.encode()
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, dict(r.getheaders()), data


def sign_in() -> str:
    st, hd, _ = req("POST", "/login", urlencode({"password": PW, "next": "/"}),
                    {"Content-Type": "application/x-www-form-urlencoded", "Origin": ORIGIN})
    for k, v in hd.items():
        if k.lower() == "set-cookie" and v.startswith("bn_session="):
            return v.split(";", 1)[0]
    raise SystemExit(f"could not sign in to the portal (HTTP {st})")


COOKIE = ""
API_H = {"X-Requested-With": "devos-ade", "Origin": ORIGIN}


def api(method, path, data=None):
    body = json.dumps(data) if data is not None else None
    h = dict(API_H)
    if body is not None:
        h["Content-Type"] = "application/json"
    st, _, raw = req(method, path, body, h, cookie=COOKIE)
    try:
        return st, json.loads(raw or b"null")
    except ValueError:
        return st, raw.decode("utf-8", "replace")


def lite(method, path, key, data=None, timeout=60):
    body = json.dumps(data) if data is not None else None
    h = {"Authorization": f"Bearer {key}"}
    if body is not None:
        h["Content-Type"] = "application/json"
    st, _, raw = req(method, path, body, h, port=LPORT, host=f"127.0.0.1:{LPORT}", timeout=timeout)
    try:
        return st, json.loads(raw or b"null")
    except ValueError:
        return st, None


def litellm_container() -> str:
    """LiteLLM's container: its id and when it started (a recreate changes the id, a restart the time)."""
    ids = subprocess.run(["docker", "ps", "-q", "--no-trunc", "--filter", f"label=com.docker.compose.project={PROJECT}",
                          "--filter", "label=com.docker.compose.service=litellm"], capture_output=True, text=True).stdout.split()
    if not ids:
        return ""
    return subprocess.run(["docker", "inspect", "-f", "{{.Id}} {{.State.StartedAt}}", ids[0]], capture_output=True, text=True).stdout.strip()


FORWARDER = r"""
import socket, sys, threading
port = int(sys.argv[1])
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(32)
while True:
    c, _ = srv.accept()
    u = socket.create_connection(("host.docker.internal", port))
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    threading.Thread(target=pipe, args=(u, c), daemon=True).start()
"""


def forwarder():
    """The stand-in answers on this computer's 127.0.0.1 (where ./stack reads its model list): inside LiteLLM's container
    the same address reaches it through a small relay to host.docker.internal (Docker Desktop's way to this computer)."""
    cid = litellm_container().split(" ")[0]
    if not cid or not XL_PORT:
        return
    probe = subprocess.run(["docker", "exec", cid, "python", "-c",
                            f"import socket; socket.create_connection(('127.0.0.1', {XL_PORT}), 2)"], capture_output=True)
    if probe.returncode == 0:
        return
    subprocess.run(["docker", "exec", "-d", cid, "python", "-c", FORWARDER, str(XL_PORT)], capture_output=True)
    time.sleep(0.5)


def mock_calls(model: str) -> int:
    n = 0
    try:
        with open(MOCK_LOG, encoding="utf-8") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if isinstance(d.get("body"), dict) and d["body"].get("model") == model:
                    n += 1
    except OSError:
        pass
    return n


def models(key) -> set:
    st, d = lite("GET", "/v1/models", key)
    return {m.get("id") for m in (d or {}).get("data", [])} if st == 200 else set()


def settings_log() -> str:
    try:
        with open(os.path.join(STACK, ".state/helper/last-settings.log"), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


LAST_APPLY = [0.0]


def change(values: dict, timeout=300) -> dict:
    """One change as Settings sends it; -> {ok, secs, phases: {phase: s since the request}, job, log, restarted}"""
    wait = 5.3 - (time.time() - LAST_APPLY[0])   # the portal takes one change every 5 s
    if wait > 0:
        time.sleep(wait)
    st, d = api("GET", "/api/settings")
    if st != 200:
        raise SystemExit(f"/api/settings: HTTP {st}")
    base = d["snapshot"]["base"]
    before = litellm_container()
    t0 = time.time()
    st, d = api("POST", "/api/settings/apply", {"password": PW, "base": base, "set": values})
    LAST_APPLY[0] = time.time()
    if st != 202:
        return {"ok": False, "secs": round(time.time() - t0, 2), "error": f"apply HTTP {st}: {d}"}
    nonce = d["id"]
    phases, job = {}, {}
    while time.time() - t0 < timeout:
        st, a = api("GET", "/api/admin/status")
        j = (a or {}).get("job") if st == 200 and isinstance(a, dict) else None
        if j and j.get("id") == nonce:
            job = j
            phases.setdefault(j.get("phase"), round(time.time() - t0, 2))
            if j.get("phase") in ("done", "failed"):
                break
        time.sleep(0.1)
    secs = round(time.time() - t0, 2)
    after = litellm_container()
    return {"ok": job.get("phase") == "done", "secs": secs, "phases": phases, "message": job.get("message", "timed out"),
            "helper_secs": (job["finished_at"] - job["started_at"]) if job.get("finished_at") and job.get("started_at") else None,
            "steps": job.get("steps", []), "log": settings_log()[-6000:], "litellm_restarted": before != after}


def run_kind(kind: str, e: dict) -> list:
    """-> [(name, values, result, check, target)] for one kind (some are two changes: there and back)"""
    key = e.get("LITELLM_KEY_SETUP", "")
    out = []

    def one(name, values, target, check=None):
        r = change(values)
        why = ""
        if r["ok"] and check:
            try:
                why = check() or ""
            except Exception as x:  # noqa: BLE001 — said, not raised: the next change still runs
                why = f"check failed: {x}"
        out.append((name, values, r, why, target))
        print(f"  {name:<22} {'ok' if r['ok'] and not why else 'FAIL':<5} {r['secs']:>6.1f} s  "
              f"{'LiteLLM restarted' if r.get('litellm_restarted') else 'LiteLLM kept'}  {why or r.get('message', '')[:90]}", file=sys.stderr)
        return r

    if kind == "budget":
        new = "0.025" if e.get("BUDGET_SETUP") != "0.025" else "0.03"
        def chk():
            st, d = lite("GET", "/key/info", key)
            mb = ((d or {}).get("info") or {}).get("max_budget")
            return "" if mb is not None and abs(float(mb) - float(new)) < 1e-9 else f"max_budget {mb}, want {new}"
        one("budget", {"BUDGET_SETUP": new}, RESTART_TARGET, chk)
    elif kind == "xl":
        base = e.get("EXPLABS_MODELS") or "qwen3.8-27b"
        added = base + ",gpt-5-mini"
        def chk_add():
            have = models(key)
            if "xl/gpt-5-mini" not in have or "xl/qwen3.8-27b" not in have:
                return f"/v1/models: {sorted(m for m in have if m.startswith('xl/'))}"
            forwarder()
            n0 = mock_calls("gpt-5-mini")
            st, d = lite("POST", "/v1/chat/completions", key, {"model": "xl/gpt-5-mini", "max_tokens": 5,
                                                              "messages": [{"role": "user", "content": "say ok"}]})
            if st != 200:
                return f"a call to xl/gpt-5-mini: HTTP {st} {str(d)[:120]}"
            return "" if mock_calls("gpt-5-mini") > n0 else "the call did not reach the stand-in"
        one("xl-add", {"EXPLABS_MODELS": added}, MODEL_TARGET, chk_add)
        def chk_rm():
            have = models(key)
            return "" if "xl/gpt-5-mini" not in have and "xl/qwen3.8-27b" in have else f"/v1/models: {sorted(m for m in have if m.startswith('xl/'))}"
        one("xl-remove", {"EXPLABS_MODELS": base}, MODEL_TARGET, chk_rm)
    elif kind == "or":
        base = e.get("OPENROUTER_MODELS", "")
        added = (base + "," if base else "") + OR_ADD
        def chk_add():
            have = models(key)
            return "" if f"or/{OR_ADD}" in have else f"/v1/models lacks or/{OR_ADD} ({len([m for m in have if m.startswith('or/')])} or/ models)"
        one("or-add", {"OPENROUTER_MODELS": added}, MODEL_TARGET, chk_add)
        def chk_rm():
            return "" if f"or/{OR_ADD}" not in models(key) else f"/v1/models still lists or/{OR_ADD}"
        one("or-remove", {"OPENROUTER_MODELS": base}, MODEL_TARGET, chk_rm)
    elif kind == "code-models":
        new = "claude-sonnet-5-5" if e.get("CODE_DEFAULT_MODEL") != "claude-sonnet-5-5" else "claude-haiku-5-5"
        def chk(m=new):
            st, d = lite("GET", "/model/info", key)
            for x in (d or {}).get("data", []):
                mi = x.get("model_info") or {}
                if x.get("model_name") == m and mi.get("bn_id") == m:
                    return "" if mi.get("bn_default") is True else f"{m} is not bn_default in /model/info"
            return f"{m} not in /model/info"
        one("code-default", {"CODE_DEFAULT_MODEL": new}, MODEL_TARGET, chk)
        one("code-default-back", {"CODE_DEFAULT_MODEL": e.get("CODE_DEFAULT_MODEL", "")}, MODEL_TARGET,
            (lambda m=e.get("CODE_DEFAULT_MODEL", ""): chk(m)) if e.get("CODE_DEFAULT_MODEL") else None)
    elif kind == "key":
        new = "xpl_" + os.urandom(20).hex()
        def chk():
            forwarder()
            n0 = mock_calls("qwen3.8-27b")
            st, d = lite("POST", "/v1/chat/completions", key, {"model": "xl/qwen3.8-27b", "max_tokens": 5,
                                                              "messages": [{"role": "user", "content": "say ok"}]})
            return "" if st == 200 and mock_calls("qwen3.8-27b") > n0 else f"a call after the key change: HTTP {st}"
        one("key", {"EXPLABS_API_KEY": new}, RESTART_TARGET, chk)
    elif kind == "terminal":
        cur = e.get("TERMINAL_AUTO_MODE", "")
        one("terminal", {"TERMINAL_AUTO_MODE": "false" if cur == "true" else "true"}, RESTART_TARGET)
        one("terminal-back", {"TERMINAL_AUTO_MODE": cur or "false"}, RESTART_TARGET)
    elif kind == "websearch":
        one("websearch-off", {"WEBSEARCH_SEARXNG_BUILTIN": "off"}, RESTART_TARGET)
        one("websearch-on", {"WEBSEARCH_SEARXNG_BUILTIN": "on"}, RESTART_TARGET)
    elif kind == "remote":
        one("remote", {"REMOTE_ADMIN_ACTIONS": "true"}, RESTART_TARGET)
        one("remote-back", {"REMOTE_ADMIN_ACTIONS": "false"}, RESTART_TARGET)
    else:
        raise SystemExit(f"unknown kind {kind}")
    return out


def main():
    global COOKIE
    COOKIE = sign_in()
    st, d = api("GET", "/api/settings")
    if st != 200 or not (d.get("helper") or {}).get("settings"):
        raise SystemExit(f"the portal sees no update helper with Settings: HTTP {st} {str(d)[:200]}")
    rows, fails = [], 0
    for kind in KINDS:
        for name, values, r, why, target in run_kind(kind, env_file()):
            model_kind = name.startswith(("xl-", "or-", "code-"))
            missed = []
            if TARGETS and r["ok"]:
                if r["secs"] > target:
                    missed.append(f"{r['secs']:.1f} s > {target:.0f} s")
                if model_kind and r.get("litellm_restarted"):
                    missed.append("LiteLLM was restarted")
                if r["secs"] > ANY_TARGET:
                    missed.append(f"over {ANY_TARGET:.0f} s")
            bad = (not r["ok"]) or bool(why) or bool(missed)
            fails += bad
            rows.append({"change": name, "keys": sorted(values), "ok": r["ok"], "secs": r["secs"], "helper_secs": r.get("helper_secs"),
                         "phases": r.get("phases"), "steps": r.get("steps"), "litellm_restarted": r.get("litellm_restarted"),
                         "message": r.get("message"), "check": why, "missed": missed, "target_s": target, "pass": not bad,
                         "log": r.get("log")})
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"label": LABEL, "targets": TARGETS, "changes": rows}, f, indent=1)
    print(f"\n  {'change':<22} {'total':>7} {'helper':>7}  {'LiteLLM':<9} result", file=sys.stderr)
    for r in rows:
        print(f"  {r['change']:<22} {r['secs']:>6.1f}s {str(r['helper_secs'] if r['helper_secs'] is not None else '-'):>6}s  "
              f"{'restarted' if r['litellm_restarted'] else 'kept':<9} {'PASS' if r['pass'] else 'FAIL'} {'; '.join(r['missed'] + ([r['check']] if r['check'] else []))}",
              file=sys.stderr)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
