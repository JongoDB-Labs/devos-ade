"""The model runtimes DevOS ADE installs and runs (lib/runtimes.sh, JON-829): status/runtimes.json read field by field,
the routes that hand an install, start, stop, cancel, removal or log read to the update helper (the password for the
first three, none for the rest), Home's row and Activity's items."""

import json
import time
from dataclasses import replace

import httpx
import pytest
from starlette.testclient import TestClient

from portal import activity
from portal import local_models as lm
from portal import settings as st
from portal import summary
from portal.app import create_app

ORIGIN = {"Origin": "http://bedrock-now.localhost"}
API = {"X-Requested-With": "bedrock-now"}
H = {**ORIGIN, **API, "Content-Type": "application/json"}
PW = "correct horse"
GB = 1024 ** 3


def _rt(sd, now=None, **over):
    """a runtimes.json as lib/runtimes.sh rt_status_write writes it: Ollama running natively, one model loaded"""
    now = int(time.time()) if now is None else now
    one = {"id": "ollama", "name": "Ollama", "state": "running", "managed": True, "kind": "agent", "version": "0.40.11", "pinned": "0.40.11",
           "address": "127.0.0.1:11434", "loaded": [{"name": "qwen3:8b", "bytes": 6 * GB, "gpu_bytes": 6 * GB}], "memory_bytes": 6 * GB,
           "gpu_bytes": 6 * GB, "restarts": 0, "last_exit": None, "size": "about 180 MB", "why_not": ""}
    one.update(over.pop("one", {}))
    d = {"version": 1, "at": now, "os": "mac", "runtimes": [one], "job": {"state": "idle"},
         "events": [{"at": now - 60, "id": "ollama", "kind": "installed", "text": "Ollama 0.40.11 was installed"}]}
    d.update(over)
    (sd / "runtimes.json").write_text(json.dumps(d))


def test_the_runtimes_file_is_read_field_by_field(tmp_path):
    _rt(tmp_path)
    d = lm.read_runtimes(tmp_path)
    assert d["known"] and not d["stale"] and d["os"] == "mac"
    r = d["runtimes"][0]
    assert (r["id"], r["name"], r["state"], r["managed"], r["kind"], r["version"], r["address"]) == \
        ("ollama", "Ollama", "running", True, "agent", "0.40.11", "127.0.0.1:11434")
    assert r["loaded"] == [{"name": "qwen3:8b", "bytes": 6 * GB, "gpu_bytes": 6 * GB}] and r["memory"] == 6 * GB and r["restarts"] == 0
    assert d["job"]["state"] == "idle" and d["events"][0]["kind"] == "installed"
    # nothing at all, a stale file, and nonsense: an unknown runtime dropped, odd fields emptied, never echoed
    assert lm.read_runtimes(tmp_path / "nowhere") == {"known": False, "at": None, "stale": True, "os": "other", "runtimes": [],
                                                       "job": {"id": "", "op": "", "state": "idle", "done_bytes": 0, "total_bytes": 0, "message": "", "at": None},
                                                       "events": []}
    _rt(tmp_path, now=int(time.time()) - 600)
    assert lm.read_runtimes(tmp_path)["stale"] is True
    _rt(tmp_path, os="windows; rm", one={"state": "rm -rf", "kind": "<b>", "address": "0.0.0.0:11434", "version": "1.0 && x", "managed": "yes",
                                         "loaded": [{"name": "../../etc"}, {"name": "ok:1b", "bytes": -1}], "restarts": True, "last_exit": "9"},
        job={"id": "evil", "op": "rm", "state": "running", "message": "x" * 900, "done_bytes": "5"},
        events=[{"at": 5, "id": "ollama", "kind": "wat", "text": "x"}, {"at": "5", "id": "ollama", "kind": "up"}, {"at": 7, "id": "lmstudio", "kind": "up"}])
    d = lm.read_runtimes(tmp_path)
    r = d["runtimes"][0]
    assert d["os"] == "other" and r["state"] == "unsupported" and r["kind"] == "none" and r["address"] == "" and r["version"] == ""
    assert r["managed"] is False and r["loaded"] == [{"name": "ok:1b", "bytes": 0, "gpu_bytes": 0}] and r["restarts"] is None and r["last_exit"] is None
    assert d["job"]["id"] == "" and d["job"]["op"] == "" and d["job"]["state"] == "running" and len(d["job"]["message"]) <= 400 and d["job"]["done_bytes"] == 0
    assert d["events"] == []
    _rt(tmp_path, runtimes=[{"id": "vllm", "state": "running"}, "x", None])
    assert lm.read_runtimes(tmp_path)["runtimes"] == []


def test_a_runtime_log_is_its_last_printable_lines_and_only_a_known_runtime_has_one(tmp_path):
    (tmp_path / "runtime-logs").mkdir()
    (tmp_path / "runtime-logs" / "ollama.txt").write_bytes(b"time=1 level=INFO msg=\"Listening on 127.0.0.1:11434\"\n\x1b[31mred\x07\n")
    d = lm.read_runtime_logs(tmp_path, "ollama")
    assert d["text"] == 'time=1 level=INFO msg="Listening on 127.0.0.1:11434"\n[31mred' and isinstance(d["at"], int)
    assert lm.read_runtime_logs(tmp_path, "../ollama") == {"text": "", "at": None}
    (tmp_path / "runtime-logs" / "ollama.txt").unlink()
    (tmp_path / "runtime-logs" / "ollama.txt").symlink_to("/etc/hosts")
    assert lm.read_runtime_logs(tmp_path, "ollama") == {"text": "", "at": None}   # (a link is never followed)


# --- the routes ---

@pytest.fixture
def app(settings, tmp_path):
    sd, rq = tmp_path / "status", tmp_path / "requests"
    sd.mkdir(); rq.mkdir()
    (sd / "helper.json").write_text(json.dumps({"heartbeat": int(time.time()), "pid": 1, "version": "v0.41.0", "rollback": {"available": False}}))
    (sd / "helper-settings.json").write_text(json.dumps({"settings": 1, "local": list(st.LOCAL_ACTIONS) + ["local-runtime", "local-runtime-stop"],
                                                          "written_at": int(time.time())}))
    s = replace(settings, status_dir=sd, request_dir=rq, shared_mcp_token="mcp-token-0123456789abcdef")
    c = TestClient(create_app(s, transport=httpx.MockTransport(lambda r: httpx.Response(404))), follow_redirects=False,
                   base_url="http://bedrock-now.localhost")
    c.__enter__()
    assert c.post("/login", data={"password": PW}, headers=ORIGIN).status_code == 303
    yield c, sd, rq
    c.__exit__(None, None, None)


def _bodies(rq):
    return [json.loads(f.read_text()) for f in sorted(rq.glob("act-*.json"))]


def test_llamacpp_is_read_beside_ollama_with_its_linux_address_and_named_everywhere(tmp_path):
    lc = {"id": "llamacpp", "name": "llama.cpp", "state": "running", "managed": True, "kind": "container", "version": "0.8.0", "pinned": "0.8.0",
          "address": "llamacpp:8080 (the model gateway's network only)", "loaded": [{"name": "org/M-GGUF:Q4_K_M", "bytes": 0, "gpu_bytes": 0}],
          "memory_bytes": 0, "gpu_bytes": 0, "restarts": 0, "last_exit": None, "size": "about 290 MB", "why_not": ""}
    _rt(tmp_path)
    d = json.loads((tmp_path / "runtimes.json").read_text())
    d["runtimes"].append(lc)
    d["events"].append({"at": d["at"] - 30, "id": "llamacpp", "kind": "restart", "text": "llama.cpp ended (exit code 1) and was started again"})
    (tmp_path / "runtimes.json").write_text(json.dumps(d))
    r = lm.read_runtimes(tmp_path)
    assert [x["id"] for x in r["runtimes"]] == ["ollama", "llamacpp"]
    x = r["runtimes"][1]
    assert (x["name"], x["kind"], x["address"], x["loaded"][0]["name"]) == ("llama.cpp", "container", "llamacpp:8080 (the model gateway's network only)", "org/M-GGUF:Q4_K_M")
    assert r["events"][-1]["id"] == "llamacpp"
    # any other name for its address is not one
    for bad in ("llamacpp:8080", "ollama:11434 (the model gateway's network only)", "0.0.0.0:11438"):
        d["runtimes"][1]["address"] = bad
        (tmp_path / "runtimes.json").write_text(json.dumps(d))
        assert lm.read_runtimes(tmp_path)["runtimes"][1]["address"] == "", bad
    assert st.write_runtime_action(tmp_path, "install", "llamacpp", PW, now=1)
    # Activity names it as it is written
    got = activity.runtime_items(tmp_path, d["at"])
    assert got[0]["title"] == "llama.cpp ended and was started again"
    # the downloads: llama.cpp is a runtime a model can be registered with, and a download choice
    assert st.VALIDATORS["local_models"]("llamacpp:org/M-GGUF:Q4_K_M,ollama:qwen3:8b") is None
    assert st.VALIDATORS["local_runtime"]("llamacpp") is None and st.VALIDATORS["local_runtime"]("llama.cpp") is not None
    (tmp_path / lm.STATUS_FILE).write_text(json.dumps({"at": int(time.time()), "runtime": {"kind": "llamacpp", "llamacpp": "ready"},
        "installed": [{"runtime": "llamacpp", "id": "org/M-GGUF:Q4_K_M", "repo": "org/M-GGUF", "quant": "Q4_K_M", "bytes": 5}]}))
    s = lm.read_status(tmp_path)
    assert s["runtime"]["kind"] == "llamacpp" and s["runtime"]["llamacpp"] == "ready" and s["installed"][0]["runtime"] == "llamacpp"


def _clear(rq):
    for f in rq.glob("act-*.json"):
        f.unlink()


def _pw(c, op, rid="ollama", password=PW, **kw):
    return c.post("/api/local-models/runtime", headers=H, content=json.dumps({"password": password, "op": op, "id": rid, **kw}))


def _free(c, op, rid="ollama", **kw):
    return c.post("/api/local-models/runtime-stop", headers=H, content=json.dumps({"op": op, "id": rid, **kw}))


def test_the_list_route_carries_the_runtimes_whether_they_can_be_changed_and_the_download_choice(app):
    c, sd, rq = app
    _rt(sd)
    d = c.get("/api/local-models", headers=API).json()
    assert d["runtimes"]["runtimes"][0]["state"] == "running" and d["can_runtime"] is True and d["choice"] == "auto"
    (sd / "helper-settings.json").write_text(json.dumps({"settings": 1, "local": list(st.LOCAL_ACTIONS), "written_at": int(time.time())}))
    assert c.get("/api/local-models", headers=API).json()["can_runtime"] is False   # (an older helper: no install button)


def test_install_start_and_uninstall_need_the_password_and_write_the_op_and_id_alone(app):
    c, sd, rq = app
    _rt(sd, one={"state": "not-installed", "managed": False, "version": "", "loaded": []})
    assert _pw(c, "install", password="wrong").status_code == 403
    assert _pw(c, "install", password="").status_code in (400, 403)
    assert not _bodies(rq)
    r = _pw(c, "install")
    assert r.status_code == 202 and set(r.json()) == {"id", "op"}
    (b,) = _bodies(rq)
    assert set(b) == {"action", "requested_at", "nonce", "auth", "op", "id"} and (b["action"], b["op"], b["id"]) == ("local-runtime", "install", "ollama")
    assert PW not in json.dumps(b)                                                   # (base64, as every helper request carries it)
    assert _pw(c, "start").status_code == 429                                       # (one change at a time from a page)
    for bad_op, bad_id in (("stop", "ollama"), ("logs", "ollama"), ("rm -rf", "ollama"), ("install", "vllm"), ("install", "../x"), (None, None), ("install", 5)):
        assert _pw(c, bad_op, bad_id).status_code == 400, (bad_op, bad_id)


def test_nothing_is_installed_over_an_ollama_of_yours_or_while_a_job_runs(app):
    c, sd, rq = app
    _rt(sd, one={"state": "external", "managed": False})
    r = _pw(c, "install")
    assert r.status_code == 409 and "already runs on 127.0.0.1:11434" in r.json()["error"]
    _rt(sd, one={"id": "llamacpp", "name": "llama.cpp", "state": "external", "managed": False})
    assert "llama.cpp cannot be installed here: something that is not DevOS ADE's already answers on 127.0.0.1:11438" in _pw(c, "install", "llamacpp").json()["error"]
    _rt(sd, one={"state": "unsupported", "managed": False, "why_not": "DevOS ADE runs it on macOS and Linux only"})
    assert "macOS and Linux only" in _pw(c, "install").json()["error"]
    _rt(sd, one={"state": "installing"}, job={"id": "ollama", "op": "install", "state": "running", "done_bytes": 5, "total_bytes": 10, "message": "Downloading"})
    assert _pw(c, "uninstall").status_code == 409 and _free(c, "stop").status_code == 409
    assert not _bodies(rq)


def test_stop_cancel_and_logs_need_no_password_and_each_only_when_it_means_something(app):
    c, sd, rq = app
    _rt(sd)
    r = _free(c, "stop", password="ignored")
    assert r.status_code == 202
    (b,) = _bodies(rq)
    assert b == {"action": "local-runtime-stop", "requested_at": b["requested_at"], "nonce": b["nonce"], "op": "stop", "id": "ollama"}
    _clear(rq)
    assert _free(c, "cancel").status_code == 409                                   # (no install running)
    _rt(sd, one={"state": "stopped", "loaded": []})
    assert _free(c, "stop").status_code == 409
    _rt(sd, one={"state": "running", "managed": False})                            # one of yours: never stopped from here
    assert _free(c, "stop").status_code == 409
    assert _free(c, "logs").status_code == 202 and _bodies(rq)[0]["op"] == "logs"   # (its own rate: a Stop just before does not hold it up)
    _clear(rq)
    time.sleep(2.05)
    _rt(sd, one={"state": "installing"}, job={"id": "ollama", "op": "install", "state": "running", "done_bytes": 5, "total_bytes": 10})
    assert _free(c, "cancel").status_code == 202 and _bodies(rq)[0]["op"] == "cancel"
    for bad in ("install", "uninstall", "", None, "stop; rm"):
        assert _free(c, bad).status_code == 400
    assert _free(c, "stop", rid="lmstudio").status_code == 400
    assert c.post("/api/local-models/runtime-stop", headers=H, content="[1]").status_code == 400


def test_the_runtime_routes_keep_the_session_the_header_the_origin_and_a_helper_that_does_it(app, settings):
    c, sd, rq = app
    _rt(sd)
    body = json.dumps({"op": "stop", "id": "ollama"})
    assert c.post("/api/local-models/runtime-stop", headers={**ORIGIN, "Content-Type": "application/json"}, content=body).status_code in (400, 403)
    assert c.post("/api/local-models/runtime-stop", headers={**API, "Origin": "http://evil.example", "Content-Type": "application/json"},
                  content=body).status_code == 403
    assert c.post("/api/local-models/runtime", headers={**API, "Origin": "http://evil.example", "Content-Type": "application/json"},
                  content=json.dumps({"password": PW, "op": "start", "id": "ollama"})).status_code == 403
    with TestClient(create_app(replace(settings, status_dir=sd, request_dir=rq), transport=httpx.MockTransport(lambda r: httpx.Response(404))),
                    follow_redirects=False, base_url="http://bedrock-now.localhost") as anon:
        assert anon.post("/api/local-models/runtime-stop", headers=H, content=body).status_code in (401, 403)
        assert anon.get("/api/local-models/runtime-logs?id=ollama", headers=API).status_code in (401, 403)
    assert not _bodies(rq)
    (sd / "helper-settings.json").write_text(json.dumps({"settings": 1, "local": list(st.LOCAL_ACTIONS), "written_at": int(time.time())}))
    r = _free(c, "stop")
    assert r.status_code == 503 and "helper install" in r.json()["error"]
    assert _pw(c, "start").status_code == 503
    assert not _bodies(rq)


def test_the_log_route_reads_the_helpers_copy(app):
    c, sd, rq = app
    assert c.get("/api/local-models/runtime-logs?id=ollama", headers=API).json() == {"text": "", "at": None}
    (sd / "runtime-logs").mkdir()
    (sd / "runtime-logs" / "ollama.txt").write_text("hello\n")
    assert c.get("/api/local-models/runtime-logs?id=ollama", headers=API).json()["text"] == "hello"
    assert c.get("/api/local-models/runtime-logs?id=../x", headers=API).status_code == 400


def test_the_request_writer_takes_the_op_and_the_id_and_a_password_only_for_a_change(tmp_path):
    n = st.write_runtime_action(tmp_path, "stop", "ollama", now=1000)
    assert json.loads((tmp_path / f"act-{n}.json").read_text()) == {"action": "local-runtime-stop", "requested_at": 1000, "nonce": n, "op": "stop", "id": "ollama"}
    n = st.write_runtime_action(tmp_path, "install", "ollama", PW, now=1000)
    b = json.loads((tmp_path / f"act-{n}.json").read_text())
    assert b["action"] == "local-runtime" and b["auth"] and (b["op"], b["id"]) == ("install", "ollama")
    for op, rid, pw in (("install", "ollama", ""), ("delete", "ollama", PW), ("stop", "vllm", ""), ("stop ", "ollama", ""), ("install", "ollama", "x" * 5000)):
        with pytest.raises(ValueError):
            st.write_runtime_action(tmp_path, op, rid, pw)
    d = tmp_path / "s"; d.mkdir()
    (d / "helper-settings.json").write_text(json.dumps({"settings": 1, "local": ["local-runtime", "local-runtime-stop", "local-runtime-evil"],
                                                         "written_at": int(time.time())}))
    assert st.capability(d)["local"] == ["local-runtime", "local-runtime-stop"]


# --- Home and Activity ---

def test_home_lists_a_runtime_devos_ade_runs_and_never_one_of_yours(settings, tmp_path):
    s = replace(settings, status_dir=tmp_path)
    assert summary.runtimes(s) == []
    _rt(tmp_path)
    (row,) = summary.runtimes(s)
    assert row == {"id": "runtime-ollama", "name": "Ollama", "role": "local models (this Mac's GPU)", "ok": True, "detail": "ready · 1 model loaded"}
    _rt(tmp_path, one={"state": "stopped", "loaded": [], "restarts": 2})
    (row,) = summary.runtimes(s)
    assert row["ok"] is False and row["detail"] == "stopped · restarted 2×"
    _rt(tmp_path, os="linux", one={"kind": "container", "loaded": []})
    assert summary.runtimes(s)[0]["role"] == "local models (container)" and summary.runtimes(s)[0]["detail"] == "ready"
    now = int(time.time())
    _rt(tmp_path, now=now - 3600, one={"loaded": []})
    assert summary.runtimes(s, now=now)[0]["detail"] == "ready (checked 60 min ago)"
    for st_ in ("external", "not-installed", "unsupported"):
        _rt(tmp_path, one={"state": st_, "managed": st_ == "external"})
        assert summary.runtimes(s) == [], st_


def test_activity_says_when_a_runtime_ended_or_stopped_answering_and_lists_your_own_changes_quietly(settings, tmp_path):
    s = replace(settings, status_dir=tmp_path)
    now = int(time.time())
    _rt(tmp_path, now=now, events=[
        {"at": now - 9 * 86400, "id": "ollama", "kind": "down", "text": "too old"},
        {"at": now - 300, "id": "ollama", "kind": "installed", "text": "Ollama 0.40.11 was installed"},
        {"at": now - 200, "id": "ollama", "kind": "restart", "text": "Ollama ended (exit code 2) and was started again"},
        {"at": now - 100, "id": "ollama", "kind": "down", "text": "Ollama stopped answering on 127.0.0.1:11434"},
        {"at": now - 50, "id": "ollama", "kind": "up", "text": "Ollama answers again on 127.0.0.1:11434"}])
    got = activity.runtime_items(tmp_path, now)
    assert [(i["title"], i["level"], i["notify"]) for i in got] == [
        ("Ollama answers again", "good", False), ("Ollama stopped answering", "bad", True),
        ("Ollama ended and was started again", "warn", True), ("Ollama installed", "info", False)]
    assert all(i["kind"] == "runtime" and i["link"] == "#settings/+local-models" for i in got)
    assert got[1]["text"].endswith("./stack runtimes logs ollama shows its log.") and "logs" not in got[0]["text"]
    assert got[1]["id"] == f"runtime:ollama:down:{now - 100}"
    assert any(i["id"] == got[1]["id"] for i in activity.items(s, False, now))
    _rt(tmp_path, now=now, events=[{"at": now - i, "id": "ollama", "kind": "restart", "text": "x"} for i in range(1, 12)])
    assert len(activity.runtime_items(tmp_path, now)) == activity.HEALTH_MAX
