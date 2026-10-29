"""Local models (portal/portal/local_models.py, JON-816): a fake Hugging Face API (search, a repo's files), the fits-in-
memory logic, how tool use is said honestly, the status file ./stack writes (a fake runtime's), and the routes — search,
the list, a download and a removal handed to the update helper as one fixed-field request with the password."""

import json
import re
import time
from dataclasses import replace

import httpx
import pytest
from starlette.testclient import TestClient

from portal import local_models as lm
from portal import settings as st
from portal.app import create_app

ORIGIN = {"Origin": "http://bedrock-now.localhost"}
API = {"X-Requested-With": "bedrock-now"}
H = {**ORIGIN, **API, "Content-Type": "application/json"}
GB = 1024 ** 3

TEMPLATE_TOOLS = "{% if tools %}<tool_call>{{ tools }}{% endif %}{% for m in messages %}{{ m.content }}{% endfor %}"
TEMPLATE_PLAIN = "{% for m in messages %}{{ m.content }}{% endfor %}"


def _repo(rid, params, template, **kw):
    return {"id": rid, "downloads": 1234, "likes": 5, "gated": kw.get("gated", False), "private": False,
            "tags": ["gguf", "license:apache-2.0"], "gguf": {"total": params, "context_length": 8192, "architecture": "llama", "chat_template": template}}


SEARCH = [_repo("bartowski/SmolLM2-135M-Instruct-GGUF", 134_515_008, TEMPLATE_PLAIN),
          _repo("Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", 7_600_000_000, TEMPLATE_TOOLS),
          {"id": "../evil/x", "tags": []}, {"id": "priv/one", "private": True, "tags": []}]
TREE = [{"type": "file", "path": ".gitattributes", "size": 10},
        {"type": "file", "path": "SmolLM2-135M-Instruct-Q4_K_M.gguf", "size": 1, "lfs": {"size": 105_454_432}},
        {"type": "file", "path": "SmolLM2-135M-Instruct-Q8_0.gguf", "size": 1, "lfs": {"size": 144_811_360}},
        {"type": "file", "path": "SmolLM2-135M-Instruct-f16.gguf", "size": 1, "lfs": {"size": 270_885_952}},
        {"type": "file", "path": "mmproj-SmolLM2-f16.gguf", "size": 1, "lfs": {"size": 99}},
        {"type": "file", "path": "big/Model-Q6_K-00001-of-00002.gguf", "size": 1, "lfs": {"size": 5 * GB}},
        {"type": "file", "path": "big/Model-Q6_K-00002-of-00002.gguf", "size": 1, "lfs": {"size": 3 * GB}},
        {"type": "file", "path": "README.md", "size": 5}]


def hf(request: httpx.Request) -> httpx.Response:
    """A fake Hugging Face: the model list, one repo's page and its tree. Records what was asked (never a key)."""
    hf.seen.append((request.url.path, dict(request.url.params), dict(request.headers)))
    p = request.url.path
    if p == "/api/models":
        return httpx.Response(200, json=SEARCH)
    if p == "/api/models/bartowski/SmolLM2-135M-Instruct-GGUF":
        return httpx.Response(200, json=SEARCH[0])
    if p == "/api/models/bartowski/SmolLM2-135M-Instruct-GGUF/tree/main":
        return httpx.Response(200, json=TREE)
    if p == "/api/models/gated/repo":
        return httpx.Response(401, json={"error": "gated"})
    return httpx.Response(404)


hf.seen = []


@pytest.fixture(autouse=True)
def _fresh():
    lm._cache.clear()
    hf.seen.clear()


def _client(httpx_client_transport=hf):
    return httpx.AsyncClient(transport=httpx.MockTransport(httpx_client_transport))


def run(coro):
    import asyncio
    return asyncio.run(coro)


# --- the Hugging Face side ---

def test_search_parses_repos_and_drops_anything_unsafe():
    async def go():
        async with _client() as c:
            return await lm.search(c, "smollm2")
    rows, err = run(go())
    assert err is None
    assert [r["repo"] for r in rows] == ["bartowski/SmolLM2-135M-Instruct-GGUF", "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF"]   # '../evil/x' and the private one are out
    small = rows[0]
    assert small["license"] == "apache-2.0" and small["params"] == 134_515_008 and small["tools"] == "no" and small["context"] == 8192
    assert rows[1]["tools"] == "yes"
    path, params, headers = hf.seen[0]
    assert params["filter"] == "gguf" and params["search"] == "smollm2"
    # nothing about the user: no credential of any kind is sent
    assert "authorization" not in {k.lower() for k in headers} and "cookie" not in {k.lower() for k in headers}


def test_a_search_failure_is_said_and_a_kept_answer_is_used_again():
    async def go():
        async with _client(lambda r: httpx.Response(429)) as c:
            return await lm.search(c, "x")
    rows, err = run(go())
    assert rows == [] and "rate-limiting" in err


def test_quants_sum_a_split_model_and_skip_vision_projectors_and_other_files():
    q = {x["quant"]: x for x in lm.quants_of(TREE)}
    assert set(q) == {"Q4_K_M", "Q8_0", "F16", "Q6_K"}                  # mmproj, README and .gitattributes are out
    assert q["Q4_K_M"]["size"] == 105_454_432
    assert q["Q6_K"]["size"] == 8 * GB and q["Q6_K"]["files"] == 2         # the two parts, one quant
    assert [x["quant"] for x in lm.quants_of(TREE)] == ["Q4_K_M", "Q8_0", "F16", "Q6_K"]   # smallest first
    assert lm.quants_of({"not": "a list"}) == []
    assert [x["quant"] for x in lm.quants_of([{"type": "file", "path": "m-UD-Q4_K_XL.gguf", "size": 5}])] == ["UD-Q4_K_XL"]


def test_a_repo_has_its_facts_its_quants_and_an_honest_note():
    async def go():
        async with _client() as c:
            return await lm.repo_files(c, "bartowski/SmolLM2-135M-Instruct-GGUF")
    row, err = run(go())
    assert err is None and row["license"] == "apache-2.0" and len(row["quants"]) == 4
    assert row["note"]["level"] == "chat-only"                           # ~0.1B parameters, and a template with no tools
    async def gated():
        async with _client() as c:
            return await lm.repo_files(c, "gated/repo")
    row, err = run(gated())
    assert row is None and "HF token" in err
    async def bad():
        async with _client() as c:
            return await lm.repo_files(c, "a/b/c")
    assert run(bad())[0] is None
    assert not any("gated" in p for p, _, _ in hf.seen[:0])


# --- tool use, said honestly ---

def test_tool_use_is_never_claimed_for_a_small_or_template_less_model():
    assert lm.tools_of(TEMPLATE_TOOLS) == "yes" and lm.tools_of(TEMPLATE_PLAIN) == "no" and lm.tools_of(None) == "unknown"
    assert lm.tool_note("no", 70_000_000_000)["level"] == "chat-only"          # no template support: chat only, however big
    assert lm.tool_note("yes", 1_000_000_000)["level"] == "chat-only"          # under 3B: chat only
    assert lm.tool_note("yes", 4_000_000_000)["level"] == "weak"               # under 7B: weak at tools
    big = lm.tool_note("yes", 32_000_000_000)
    assert big["level"] == "untested" and "Not checked with Claude Code" in big["text"]   # never "works"
    assert lm.tool_note("unknown", None)["level"] == "untested"


# --- does it fit ---

def test_fits_on_apple_silicon_uses_the_gpus_share_of_unified_memory():
    mem = 16 * GB                                                         # budget ~11.2 GB
    assert lm.fits(2 * GB, mem, "metal")["fit"] == "yes"
    assert lm.fits(int(7.5 * GB), mem, "metal")["fit"] == "tight"
    assert lm.fits(12 * GB, mem, "metal")["fit"] == "no"
    assert lm.fits(None, mem, "metal")["fit"] == "unknown" and lm.fits(GB, 0, "metal")["fit"] == "unknown"


def test_fits_with_an_nvidia_gpu_spills_to_the_cpu_and_without_a_gpu_uses_the_cpu_share():
    vram = f"cuda:{8 * GB}"
    assert lm.fits(4 * GB, 32 * GB, vram)["fit"] == "yes"
    spill = lm.fits(9 * GB, 32 * GB, vram)
    assert spill["fit"] == "tight" and "CPU" in spill["text"]
    assert lm.fits(40 * GB, 32 * GB, vram)["fit"] == "no"
    assert lm.fits(GB, 8 * GB, "none")["fit"] == "yes"
    assert lm.fits(4 * GB, 8 * GB, "none")["fit"] == "no"                # (~60% of 8 GB for the CPU)
    assert "CPU only" in lm.fits(GB, 8 * GB, "none")["text"]


def test_annotate_marks_what_is_downloaded_and_what_fits():
    row = {"repo": "a/B-GGUF", "quants": [{"quant": "Q4_K_M", "size": 2 * GB}, {"quant": "Q8_0", "size": 30 * GB}]}
    out = lm.annotate(row, 16 * GB, "metal", [{"repo": "A/b-gguf", "quant": "q4_k_m"}])
    assert [q["installed"] for q in out["quants"]] == [True, False]
    assert [q["fits"]["fit"] for q in out["quants"]] == ["yes", "no"]


# --- what ./stack wrote (a fake runtime's) ---

def _status(sd, **over):
    d = {"at": int(time.time()), "runtime": {"kind": "dmr", "dmr": "ready", "ollama": "not-installed", "how": "", "command": "./stack local-models enable"},
         "gpu": "metal", "memory_bytes": 16 * GB, "disk_bytes": 105_454_432,
         "installed": [{"runtime": "dmr", "id": "hf.co/bartowski/smollm2-135m-instruct-gguf:q4_k_m", "name": "lm/bartowski/smollm2-135m-instruct-gguf:q4_k_m",
                        "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "Q4_K_M", "bytes": 105_454_432, "license": "apache-2.0",
                        "tools": "0", "context": "8192", "params_m": "135", "present": True, "registered": True},
                       {"repo": "../x", "quant": "Q4"}],
         "job": {"state": "pulling", "repo": "a/b", "quant": "Q4_K_M", "done_bytes": 50, "total_bytes": 100, "message": "Downloading hf.co/a/b:Q4_K_M", "at": int(time.time())}}
    d.update(over)
    (sd / "local-models.json").write_text(json.dumps(d))


def test_the_status_file_is_read_field_by_field(tmp_path):
    _status(tmp_path)
    s = lm.read_status(tmp_path)
    assert s["known"] and not s["stale"] and s["runtime"]["kind"] == "dmr" and s["memory"] == 16 * GB and s["disk"] == 105_454_432
    assert len(s["installed"]) == 1 and s["installed"][0]["tools"] == "no" and s["installed"][0]["registered"] is True   # the bad repo is dropped
    assert s["job"] == {"state": "pulling", "repo": "a/b", "quant": "Q4_K_M", "done_bytes": 50, "total_bytes": 100, "rate": 0, "eta": None,
                        "stalled": 0, "resumable": False, "message": "Downloading hf.co/a/b:Q4_K_M", "at": s["job"]["at"]}
    # no file, a stale one, and nonsense
    assert lm.read_status(tmp_path / "nowhere")["known"] is False and lm.read_status(tmp_path / "nowhere")["runtime"]["kind"] == "none"
    _status(tmp_path, at=int(time.time()) - 600)
    assert lm.read_status(tmp_path)["stale"] is True
    _status(tmp_path, runtime={"kind": "rm -rf"}, job={"state": "wat"}, installed="x", gpu=5)
    s = lm.read_status(tmp_path)
    assert s["runtime"]["kind"] == "none" and s["job"]["state"] == "idle" and s["installed"] == []


# --- the routes ---

PW = "correct horse"


@pytest.fixture
def app(settings, tmp_path):
    sd, rq = tmp_path / "status", tmp_path / "requests"
    sd.mkdir(); rq.mkdir()
    (sd / "helper.json").write_text(json.dumps({"heartbeat": int(time.time()), "pid": 1, "version": "v0.3.0", "rollback": {"available": False}}))
    (sd / "helper-settings.json").write_text(json.dumps({"settings": 1, "diagnostics": list(st.DIAG_ACTIONS), "local": list(st.LOCAL_ACTIONS) + ["local-server", "local-probe", "local-stop"],
                                                          "written_at": int(time.time())}))
    s = replace(settings, status_dir=sd, request_dir=rq, shared_mcp_token="mcp-token-0123456789abcdef")
    c = TestClient(create_app(s, transport=httpx.MockTransport(hf)), follow_redirects=False, base_url="http://bedrock-now.localhost")
    c.__enter__()
    assert c.post("/login", data={"password": PW}, headers=ORIGIN).status_code == 303
    yield c, sd, rq
    c.__exit__(None, None, None)


def _body(rq):
    files = sorted(rq.glob("act-*.json"))
    assert len(files) == 1
    return json.loads(files[0].read_text())


def test_the_list_route_says_the_runtime_disk_and_progress_and_asks_for_a_fresh_look_when_old(app):
    c, sd, rq = app
    r = c.get("/api/local-models", headers=API)                               # no file yet: asks the helper to look
    d = r.json()
    assert r.status_code == 200 and d["known"] is False and d["runtime"]["kind"] == "none" and d["can_change"] is True and d["wait"] is True
    assert (rq / "local-wanted").exists()
    _status(sd, at=int(time.time()))
    (rq / "local-wanted").unlink()
    d = c.get("/api/local-models", headers=API).json()
    assert d["runtime"]["kind"] == "dmr" and d["disk"] == 105_454_432 and d["job"]["state"] == "pulling" and d["hf_token_set"] is False
    assert not (rq / "local-wanted").exists()                                  # fresh, and a download runs: no new look needed
    assert c.get("/api/local-models").status_code in (400, 403)                # a session and X-Requested-With, like every read


def test_search_route_lists_repos_and_a_repo_with_each_quants_fit(app):
    c, sd, rq = app
    _status(sd, job={"state": "idle"})
    d = c.get("/api/local-models/search?q=smollm2", headers=API).json()
    assert [r["repo"] for r in d["rows"]][0] == "bartowski/SmolLM2-135M-Instruct-GGUF" and d["error"] is None
    r = c.get("/api/local-models/search?repo=bartowski/SmolLM2-135M-Instruct-GGUF", headers=API)
    assert r.status_code == 200, r.text
    d = r.json()["repo"]
    q = {x["quant"]: x for x in d["quants"]}
    assert q["Q4_K_M"]["fits"]["fit"] == "yes" and q["Q4_K_M"]["installed"] is True and q["Q8_0"]["installed"] is False
    assert d["license"] == "apache-2.0" and d["note"]["level"] == "chat-only"
    assert c.get("/api/local-models/search?repo=gated/repo", headers=API).status_code == 404
    assert c.get("/api/local-models/search?repo=a/b/c", headers=API).status_code == 404


def test_a_download_is_one_fixed_field_request_with_facts_worked_out_here(app):
    c, sd, rq = app
    _status(sd, job={"state": "idle"})
    # the page sends only a repo and a quant; size, license, tool use come from Hugging Face's answer, not from the page
    r = c.post("/api/local-models/change", headers=H, content=json.dumps(
        {"password": PW, "action": "local-pull", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "q4_k_m", "bytes": 1, "license": "evil"}))
    assert r.status_code == 202, r.text
    b = _body(rq)
    assert b["action"] == "local-pull" and b["repo"] == "bartowski/SmolLM2-135M-Instruct-GGUF" and b["quant"] == "Q4_K_M"
    assert b["bytes"] == 105_454_432 and b["license"] == "apache-2.0" and b["tools"] == "no" and b["params_m"] == 134 and b["context"] == 8192
    assert set(b) == {"action", "requested_at", "nonce", "auth", "repo", "quant", "bytes", "tools", "context", "params_m", "license"}
    assert PW not in json.dumps(b)                                              # the password goes as the helper's base64 field only
    # the same fields as the helper's regex takes (lib/settings_helper.sh act_check_request)
    assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}", b["repo"])


def test_a_download_needs_the_password_a_runtime_and_a_real_quant(app):
    c, sd, rq = app
    _status(sd, job={"state": "idle"})
    pull = {"action": "local-pull", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "Q4_K_M"}
    assert c.post("/api/local-models/change", headers=H, content=json.dumps({**pull, "password": "wrong password"})).status_code == 403
    assert c.post("/api/local-models/change", headers=H, content=json.dumps({**pull, "password": PW, "quant": "Q9_9"})).status_code == 404
    assert c.post("/api/local-models/change", headers=H, content=json.dumps({**pull, "password": PW, "repo": "https://evil.com/x"})).status_code == 400
    assert c.post("/api/local-models/change", headers=H, content=json.dumps({**pull, "password": PW, "action": "rm -rf"})).status_code == 400
    assert not list(rq.glob("act-*.json"))
    _status(sd, job={"state": "idle"}, runtime={"kind": "none", "how": "Docker Model Runner is switched off: ./stack local-models enable.", "command": "./stack local-models enable"})
    r = c.post("/api/local-models/change", headers=H, content=json.dumps({**pull, "password": PW}))
    assert r.status_code == 409 and "local-models enable" in r.json()["error"]
    assert not list(rq.glob("act-*.json"))


def test_a_download_waits_for_the_one_running_and_a_removal_names_only_what_is_downloaded(app):
    c, sd, rq = app
    _status(sd)                                                                 # a pull is running
    pull = {"password": PW, "action": "local-pull", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "Q8_0"}
    assert c.post("/api/local-models/change", headers=H, content=json.dumps(pull)).status_code == 409
    _status(sd, job={"state": "idle"})
    rm = {"password": PW, "action": "local-remove", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "Q8_0"}
    assert c.post("/api/local-models/change", headers=H, content=json.dumps(rm)).status_code == 404   # not downloaded
    r = c.post("/api/local-models/change", headers=H, content=json.dumps({**rm, "quant": "Q4_K_M"}))
    assert r.status_code == 202
    b = _body(rq)
    assert b["action"] == "local-remove" and b["repo"] == "bartowski/SmolLM2-135M-Instruct-GGUF" and b["quant"] == "Q4_K_M" and "bytes" not in b


def test_remote_access_cannot_download_unless_settings_actions_are_allowed(app):
    c, sd, rq = app
    _status(sd, job={"state": "idle"})
    remote = {"X-Portal-Remote": "1", "X-Portal-Proxy": "p" * 64}
    c.app.state  # the app is built for local use; a remote-marked request must still be refused for changes
    d = c.get("/api/local-models", headers={**API, **remote})
    if d.status_code == 200:
        j = d.json()
        assert j["can_change"] is False and "remote access" in j["why_not"]
    r = c.post("/api/local-models/change", headers={**H, **remote}, content=json.dumps(
        {"password": PW, "action": "local-pull", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "Q4_K_M"}))
    assert r.status_code in (401, 403) and not list(rq.glob("act-*.json"))


def test_the_helper_request_writer_refuses_a_url_a_path_and_odd_fields(tmp_path):
    for bad in ({"repo": "https://x.com/a", "quant": "Q4"}, {"repo": "a/b", "quant": "../x"}, {"repo": "a/b", "quant": "Q4 5"}):
        with pytest.raises(ValueError):
            st.write_local_action(tmp_path, PW, "local-pull", **bad)
    with pytest.raises(ValueError):
        st.write_local_action(tmp_path, PW, "local-pull", "a/b", "Q4", tools="maybe")
    with pytest.raises(ValueError):
        st.write_local_action(tmp_path, PW, "restart-litellm", "a/b", "Q4")
    n = st.write_local_action(tmp_path, PW, "local-remove", "a/b", "Q4")
    assert json.loads((tmp_path / f"act-{n}.json").read_text())["quant"] == "Q4"


# --- MLX repos (Apple silicon's runtime): one whole download, never one that ships code ---

MLX_TREE = [{"type": "file", "path": "config.json", "size": 700}, {"type": "file", "path": "model.safetensors", "size": 1, "lfs": {"size": 278_064_920}},
            {"type": "file", "path": "tokenizer.json", "size": 7_000_000}]


def test_an_mlx_repo_is_one_download_sized_by_its_weights():
    q, blocked = lm.mlx_of(MLX_TREE)
    assert q == [{"quant": "mlx", "size": 278_064_920, "files": 1}] and blocked == ""
    q, blocked = lm.mlx_of(MLX_TREE + [{"type": "file", "path": "modeling_evil.py", "size": 9}])
    assert q and "ships Python files" in blocked and "modeling_evil.py" in blocked and "never runs" in blocked
    assert lm.mlx_of([{"type": "file", "path": "a.gguf", "size": 5}])[0] == []


def test_mlx_search_uses_the_mlx_library_and_reads_params_and_tools_from_the_config():
    seen = []

    def handler(request):
        seen.append(str(request.url))
        return httpx.Response(200, json=[{"id": "mlx-community/Qwen2.5-0.5B-Instruct-4bit", "downloads": 9, "tags": ["mlx", "license:apache-2.0"],
                                          "safetensors": {"total": 494_032_768}, "config": {"model_type": "qwen2", "max_position_embeddings": 32768,
                                                                                             "tokenizer_config": {"chat_template": TEMPLATE_TOOLS}}}])

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
            return await lm.search(c, "qwen", fmt="mlx")
    rows, err = run(go())
    assert err is None and "filter=mlx" in seen[0] and "safetensors" in seen[0] and "gguf" not in seen[0]
    assert rows[0]["params"] == 494_032_768 and rows[0]["context"] == 32768 and rows[0]["tools"] == "yes" and rows[0]["license"] == "apache-2.0"


def test_a_download_of_an_mlx_repo_with_code_is_refused_and_a_clean_one_is_one_request(app):
    c, sd, rq = app
    tree = list(MLX_TREE)

    def handler(request):
        p = request.url.path
        if p.endswith("/tree/main"):
            return httpx.Response(200, json=tree)
        return httpx.Response(200, json={"id": "mlx-community/Tiny-4bit", "tags": ["mlx", "license:mit"], "safetensors": {"total": 494_032_768},
                                         "config": {"model_type": "qwen2", "tokenizer_config": {"chat_template": TEMPLATE_TOOLS}}})
    c.app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    _status(sd, job={"state": "idle"}, runtime={"kind": "mlx", "how": "", "command": "./stack local-models enable"})
    body = {"password": PW, "action": "local-pull", "repo": "mlx-community/Tiny-4bit", "quant": "mlx"}
    r = c.post("/api/local-models/change", headers=H, content=json.dumps(body))
    assert r.status_code == 202, r.text
    b = _body(rq)
    assert b["repo"] == "mlx-community/Tiny-4bit" and b["quant"] == "mlx" and b["bytes"] == 278_064_920 and b["tools"] == "yes"
    for f in rq.glob("act-*.json"):
        f.unlink()
    lm._cache.clear()
    tree.append({"type": "file", "path": "custom_model.py", "size": 1})
    r = c.post("/api/local-models/change", headers=H, content=json.dumps(body))
    assert r.status_code == 422 and "never runs a model" in r.json()["error"] and not list(rq.glob("act-*.json"))


# --- vLLM (Linux): a model's own safetensors weights, whole; never one that asks to run code of its own ---

ST_TREE = [{"type": "file", "path": "config.json", "size": 700}, {"type": "file", "path": "model-00001-of-00002.safetensors", "size": 1, "lfs": {"size": 4_000_000_000}},
           {"type": "file", "path": "model-00002-of-00002.safetensors", "size": 1, "lfs": {"size": 1_000_000_000}},
           {"type": "file", "path": "original/consolidated.safetensors", "size": 1, "lfs": {"size": 9_000_000_000}},
           {"type": "file", "path": "tokenizer.json", "size": 7_000_000}, {"type": "file", "path": "pytorch_model.bin", "size": 1, "lfs": {"size": 5_000_000_000}}]


def test_a_vllm_model_is_one_download_of_its_top_level_safetensors():
    assert lm.fmt_of("vllm") == "vllm" and lm.fmt_of("mlx") == "mlx" and lm.fmt_of("llamacpp") == "gguf" and lm.fmt_of("none") == "gguf"
    q, blocked = lm.vllm_of(ST_TREE, ["transformers", "safetensors"])
    assert q == [{"quant": "safetensors", "size": 5_000_000_000, "files": 2}] and blocked == ""   # (not original/, not the pickle)
    q, blocked = lm.vllm_of(ST_TREE, ["custom_code"])
    assert q and "code of its own" in blocked and "never runs" in blocked
    assert "MLX model" in lm.vllm_of(ST_TREE, ["mlx"])[1]
    assert lm.vllm_of([{"type": "file", "path": "config.json", "size": 5}, {"type": "file", "path": "m.gguf", "size": 5}], []) == ([], "It has no safetensors weights (a GGUF model goes to llama.cpp).")
    assert lm.vllm_of([{"type": "file", "path": "model.safetensors", "size": 5}], [])[1] == "It has no config.json: not a model vLLM loads."


def test_vllm_search_asks_for_text_generation_safetensors_and_leaves_out_mlx_and_custom_code():
    seen = []

    def handler(request):
        seen.append(request.url)
        cfg = {"model_type": "qwen2", "max_position_embeddings": 32768, "tokenizer_config": {"chat_template": TEMPLATE_TOOLS}}
        return httpx.Response(200, json=[{"id": "Qwen/Qwen2.5-0.5B-Instruct", "downloads": 9, "tags": ["safetensors", "license:apache-2.0"],
                                          "safetensors": {"total": 494_032_768}, "config": cfg},
                                         {"id": "mlx-community/Qwen2.5-0.5B-Instruct-4bit", "tags": ["mlx", "safetensors"], "config": cfg},
                                         {"id": "evil/Coder", "tags": ["custom_code", "safetensors"], "config": cfg}])

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
            return await lm.search(c, "qwen", fmt="vllm")
    rows, err = run(go())
    assert err is None and seen[0].params.get_list("filter") == ["safetensors", "text-generation", "transformers"]
    assert "config" in seen[0].params.get_list("expand[]")
    assert [r["repo"] for r in rows] == ["Qwen/Qwen2.5-0.5B-Instruct"]
    assert rows[0]["params"] == 494_032_768 and rows[0]["context"] == 32768 and rows[0]["tools"] == "yes"


def test_a_download_for_vllm_is_its_safetensors_and_one_that_runs_its_own_code_is_refused(app):
    c, sd, rq = app
    tags = ["transformers", "safetensors", "license:apache-2.0"]

    def handler(request):
        if request.url.path.endswith("/tree/main"):
            return httpx.Response(200, json=ST_TREE)
        return httpx.Response(200, json={"id": "Qwen/Qwen2.5-7B-Instruct", "tags": tags, "safetensors": {"total": 7_615_616_512},
                                         "config": {"model_type": "qwen2", "tokenizer_config": {"chat_template": TEMPLATE_TOOLS}}})
    c.app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    _status(sd, job={"state": "idle"}, runtime={"kind": "vllm", "how": "", "command": "./stack local-models enable"})
    body = {"password": PW, "action": "local-pull", "repo": "Qwen/Qwen2.5-7B-Instruct", "quant": "safetensors"}
    r = c.post("/api/local-models/change", headers=H, content=json.dumps(body))
    assert r.status_code == 202, r.text
    b = _body(rq)
    assert (b["repo"], b["quant"], b["bytes"], b["tools"], b["params_m"]) == ("Qwen/Qwen2.5-7B-Instruct", "safetensors", 5_000_000_000, "yes", 7615)
    for f in rq.glob("act-*.json"):
        f.unlink()
    lm._cache.clear()
    tags.append("custom_code")
    r = c.post("/api/local-models/change", headers=H, content=json.dumps(body))
    assert r.status_code == 422 and "never runs a model" in r.json()["error"] and not list(rq.glob("act-*.json"))
    assert lm.read_status(sd)["runtime"]["kind"] == "vllm"


def test_model_servers_are_read_field_by_field_with_the_reason_a_down_one_gives(tmp_path):
    _status(tmp_path)
    d = json.loads((tmp_path / "local-models.json").read_text())
    d["servers"] = [
        {"name": "lab", "url": "http://10.0.0.5:8000", "reached_as": "http://10.0.0.5:8000/v1", "trust": False, "key": True, "status": "ok",
         "detail": "qwen/Qwen3-8B|32768;llama3:8b|0;<script>|0", "warning": "", "enabled": "*"},
        {"name": "mac", "url": "http://localhost:8080", "reached_as": "this computer, reached from the gateway as http://host.docker.internal:8080/v1",
         "status": "down", "detail": "connection refused: nothing is listening", "enabled": "phi", "warning": ""},
        {"name": "Bad Name", "status": "ok"}]
    (tmp_path / "local-models.json").write_text(json.dumps(d))
    s = lm.read_status(tmp_path)["servers"]
    assert [x["name"] for x in s] == ["lab", "mac"]
    assert s[0]["up"] and s[0]["key"] and s[0]["all"] and [m["id"] for m in s[0]["models"]] == ["qwen/Qwen3-8B", "llama3:8b"]   # the unsafe id is dropped
    assert s[0]["models"][0]["context"] == 32768 and s[0]["models"][1]["context"] is None
    assert not s[1]["up"] and "connection refused" in s[1]["reason"] and s[1]["enabled"] == ["phi"] and "host.docker.internal" in s[1]["reached_as"]


def test_nothing_without_the_owners_session_and_password_can_add_or_change_a_model_source(settings, tmp_path):
    """A sandbox or an agent session has no portal session and no password: the routes that start a download or a removal,
    and the generic settings apply that carries MODEL_SERVERS, refuse it and write no request to the helper."""
    sd, rq = tmp_path / "status", tmp_path / "requests"
    sd.mkdir(); rq.mkdir()
    s = replace(settings, status_dir=sd, request_dir=rq, shared_mcp_token="mcp-token-0123456789abcdef")
    with TestClient(create_app(s, transport=httpx.MockTransport(hf)), follow_redirects=False, base_url="http://bedrock-now.localhost") as c:
        body = json.dumps({"password": PW, "action": "local-pull", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "Q4_K_M"})
        assert c.post("/api/local-models/change", headers=H, content=body).status_code in (401, 403)
        assert c.post("/api/settings/apply", headers=H, content=json.dumps({"password": PW, "base": "0" * 64, "set": {"MODEL_SERVERS": "x=http://10.0.0.5:8000"}})).status_code == 401
        assert not list(rq.glob("*"))


# --- the model-server form: probe a candidate, save with the ticked models, toggle, key, remove (all through the helper) ---

KEY = "secretkey" + "0123456789"       # (a fake key, built here)


def _srv(c, op, **kw):
    body = {"password": PW, "op": op, **kw}
    return c.post("/api/local-models/server", headers=H, content=json.dumps(body))


def _last(rq):
    files = sorted(rq.glob("act-*.json"), key=lambda p: p.stat().st_mtime)
    return json.loads(files[-1].read_text())


def test_a_candidate_is_probed_by_the_helper_not_by_the_portal_and_nothing_is_saved(app):
    c, sd, rq = app
    hf.seen.clear()
    r = _srv(c, "probe", url="10.0.0.5:8000", key=KEY, trust=True)
    assert r.status_code == 202, r.text
    d = r.json()
    assert set(d) == {"id", "op", "ref"} and re.fullmatch(r"[0-9a-f]{16}", d["ref"])
    b = _last(rq)
    assert b["action"] == "local-server" and b["op"] == "probe" and b["url"] == "http://10.0.0.5:8000" and b["ref"] == d["ref"]
    assert b["trust"] is False                                       # (a certificate only exists for https: trust is dropped for http)
    import base64
    assert base64.b64decode(b["key"]).decode() == KEY and base64.b64decode(b["auth"]).decode() == PW
    assert KEY not in r.text and PW not in r.text                    # nothing of either is answered
    assert hf.seen == []                                             # the portal itself fetched nothing (no SSRF from its container)
    # the helper's regex takes exactly these fields
    assert list(b) == ["action", "requested_at", "nonce", "auth", "op", "name", "url", "trust", "key", "models", "ref"]
    raw = json.dumps(b, separators=(",", ":"))
    assert len(raw) < 3072


def _probe(c, **kw):
    return c.post("/api/local-models/probe", headers=H, content=json.dumps(kw))


def test_check_server_needs_no_password_and_writes_a_request_that_has_none(app):
    c, sd, rq = app
    hf.seen.clear()
    r = _probe(c, url="localhost:11434", key=KEY)                      # (no "password" field at all)
    assert r.status_code == 202, r.text
    d = r.json()
    assert set(d) == {"id", "op", "ref"} and d["op"] == "probe"
    b = _last(rq)
    assert b["action"] == "local-probe" and b["url"] == "http://localhost:11434" and b["ref"] == d["ref"]
    assert "auth" not in b and "op" not in b and "name" not in b and "models" not in b   # (read-only: nothing it could save)
    assert list(b) == ["action", "requested_at", "nonce", "url", "trust", "key", "ref"]
    import base64
    assert base64.b64decode(b["key"]).decode() == KEY and KEY not in r.text and PW not in json.dumps(b)
    assert hf.seen == []                                               # the portal fetched nothing itself
    # a password sent anyway is neither needed, checked nor written
    r = _probe(c, url="127.0.0.1:8000", password="whatever")
    assert r.status_code in (202, 429)
    assert "whatever" not in json.dumps(_last(rq))


def test_check_server_keeps_the_session_the_header_the_origin_the_helper_and_the_rate_limit(app, settings, monkeypatch):
    c, sd, rq = app
    body = json.dumps({"url": "http://127.0.0.1:8000"})
    assert c.post("/api/local-models/probe", headers={**ORIGIN, "Content-Type": "application/json"}, content=body).status_code in (400, 403)   # no X-Requested-With
    assert c.post("/api/local-models/probe", headers={**API, "Origin": "http://evil.example", "Content-Type": "application/json"}, content=body).status_code == 403
    assert not list(rq.glob("act-*.json"))
    with TestClient(create_app(replace(settings, status_dir=sd, request_dir=rq), transport=httpx.MockTransport(hf)), follow_redirects=False,
                    base_url="http://bedrock-now.localhost") as anon:
        assert anon.post("/api/local-models/probe", headers=H, content=body).status_code in (401, 403)     # not signed in: refused, no password needed to say so
    assert not list(rq.glob("act-*.json"))
    assert _probe(c, url="http://127.0.0.1:8000").status_code == 202
    assert _probe(c, url="http://127.0.0.1:8000").status_code == 429                                     # (one a second)
    assert len(list(rq.glob("act-*.json"))) == 1
    (sd / "helper-settings.json").write_text(json.dumps({"settings": 1, "local": list(st.LOCAL_ACTIONS) + ["local-server"], "written_at": int(time.time())}))
    from portal import settings_api
    monkeypatch.setattr(settings_api.RateLimit, "retry_after", lambda self: 0)
    assert _probe(c, url="http://127.0.0.1:8000").status_code == 503                                     # an older helper: told to refresh it


def test_check_server_without_a_password_is_for_this_computer_only_and_refuses_odd_fields(app, monkeypatch):
    from portal import settings_api
    monkeypatch.setattr(settings_api.RateLimit, "retry_after", lambda self: 0)
    c, sd, rq = app
    hf.seen.clear()
    # (the portal writes only a bounded address, never a path or a credential, and fetches nothing; the helper judges the pinned
    # address again — tests/test_local_models.sh drives other computers' addresses through the password-free probe)
    for bad in ["file:///etc/passwd", "http://u:p@localhost", "http://local host", "", "ftp://x", "http://localhost/\nx", "http://localhost?x=1"]:
        r = _probe(c, url=bad)
        assert r.status_code in (400, 403), (bad, r.status_code, r.text)
    assert _probe(c, url="http://localhost", key="a$b").status_code == 400
    assert _probe(c, url="http://localhost", key="x" * 400).status_code == 400
    assert _probe(c, url=5).status_code == 400
    assert not list(rq.glob("act-*.json"))
    # without a password only this computer's own addresses are checked: any other — the network, metadata, link-local, a name
    # that merely starts like localhost — is refused here (403: Check asks for the password then) and by the helper again
    for target in ["http://169.254.169.254", "http://[fe80::1]", "http://metadata.google.internal", "http://10.0.0.5:8000", "http://gpu-box:8000",
                   "http://localhost.evil.example", "http://127.0.0.1.nip.io:80", "http://127.1:80", "http://[::2]:80"]:
        r = _probe(c, url=target)
        assert r.status_code == 403 and "password" in r.json()["error"], (target, r.status_code, r.text)
    assert not list(rq.glob("act-*.json"))
    for target in ["http://localhost:11434", "https://127.0.0.1:1234", "http://[::1]:8000", "http://[::ffff:127.0.0.1]:80", "localhost:1234/v1"]:
        assert _probe(c, url=target).status_code == 202, target
        b = _last(rq)
        assert b["action"] == "local-probe" and "auth" not in b
    assert hf.seen == []


def test_a_second_change_in_the_same_second_is_asked_to_wait(app):
    c, sd, rq = app
    assert _srv(c, "probe", url="http://10.0.0.5:8000").status_code == 202
    r = _srv(c, "probe", url="http://10.0.0.5:8000")
    assert r.status_code == 429 and len(list(rq.glob("act-*.json"))) == 1


def test_https_keeps_its_trust_option_and_a_save_carries_the_ticked_models(app, monkeypatch):
    from portal import settings_api
    monkeypatch.setattr(settings_api.RateLimit, "retry_after", lambda self: 0)     # (the one-a-second pause is its own test)
    c, sd, rq = app
    r = _srv(c, "save", name="lab", url="https://nas.lan:8443", trust=True, key=KEY, models=["qwen/Qwen3-8B", "llama3:8b"])
    assert r.status_code == 202, r.text
    b = _last(rq)
    assert b["op"] == "save" and b["name"] == "lab" and b["trust"] is True and b["models"] == "qwen/Qwen3-8B,llama3:8b"
    assert KEY not in r.text
    assert _srv(c, "models", name="lab", models=["*"]).status_code == 202 and _last(rq)["models"] == "*"
    assert _srv(c, "models", name="lab", models=[]).status_code == 202 and _last(rq)["models"] == ""      # (none on)
    assert _srv(c, "key", name="lab", key="").status_code == 202 and _last(rq)["key"] == ""               # (the key removed)
    assert _srv(c, "remove", name="lab").status_code == 202 and _last(rq)["op"] == "remove"


def test_the_form_refuses_odd_fields_and_the_wrong_password_and_never_echoes_a_key(app, monkeypatch):
    from portal import settings_api
    monkeypatch.setattr(settings_api.RateLimit, "retry_after", lambda self: 0)
    c, sd, rq = app
    before = len(list(rq.glob("*")))
    bad = [dict(op="probe", url="file:///etc/passwd"), dict(op="probe", url="http://u:p@h"), dict(op="probe", url="http://a b"),
           dict(op="probe"), dict(op="save", name="Bad Name", url="http://10.0.0.5:8000"), dict(op="save", url="http://10.0.0.5:8000"),
           dict(op="models", name="lab", models=["a b"]), dict(op="models", name="lab", models=["x" * 300]),
           dict(op="key", name="lab", key="a$b"), dict(op="key", name="lab", key="x" * 400), dict(op="drop", name="lab"),
           dict(op="models", name="lab", models="*")]
    for kw in bad:
        r = _srv(c, **kw)
        assert r.status_code in (400, 413), (kw, r.status_code, r.text)
    assert len(list(rq.glob("*"))) == before
    r = c.post("/api/local-models/server", headers=H, content=json.dumps({"password": "wrong", "op": "key", "name": "lab", "key": KEY}))
    assert r.status_code == 403 and KEY not in r.text and len(list(rq.glob("*"))) == before


def test_the_form_needs_the_session_the_header_the_origin_and_a_helper_that_does_it(app, settings, tmp_path):
    c, sd, rq = app
    body = json.dumps({"password": PW, "op": "probe", "url": "http://10.0.0.5:8000"})
    assert c.post("/api/local-models/server", headers={**ORIGIN, "Content-Type": "application/json"}, content=body).status_code in (400, 403)   # no X-Requested-With
    assert c.post("/api/local-models/server", headers={**API, "Origin": "http://evil.example", "Content-Type": "application/json"}, content=body).status_code == 403
    (sd / "helper-settings.json").write_text(json.dumps({"settings": 1, "local": list(st.LOCAL_ACTIONS), "written_at": int(time.time())}))
    assert _srv(c, "probe", url="http://10.0.0.5:8000").status_code == 503                                # an older helper: told to refresh it
    assert not list(rq.glob("act-*.json"))
    with TestClient(create_app(replace(settings, status_dir=sd, request_dir=rq), transport=httpx.MockTransport(hf)), follow_redirects=False,
                    base_url="http://bedrock-now.localhost") as anon:
        assert anon.post("/api/local-models/server", headers=H, content=body).status_code in (401, 403)


def test_the_form_answer_is_read_from_the_status_matched_by_its_ref_and_has_no_key_in_it(app):
    c, sd, rq = app
    _status(sd, job={"state": "idle"})
    d = json.loads((sd / "local-models.json").read_text())
    d["result"] = {"ref": "0123456789abcdef", "op": "probe", "name": "", "ok": True, "message": "", "status": "ok",
                   "detail": "qwen/Qwen3-8B|32768;llama3:8b|0;<b>x</b>|0", "warning": "This is plain http to a public address: x", "reached_as": "",
                   "key": True, "trust": False, "url": "http://203.0.113.9:8000", "at": int(time.time()), "api_key": KEY, "authorization": KEY}
    d["servers"] = [{"name": "lab", "url": "http://10.0.0.5:8000", "reached_as": "http://10.0.0.5:8000/v1", "trust": False, "key": True, "status": "ok",
                     "detail": "a|0;b|4096", "warning": "", "enabled": "a", "api_key": KEY,
                     "key_note": "key cleared: the address changed"}]
    (sd / "local-models.json").write_text(json.dumps(d))
    r = c.get("/api/local-models", headers=API)
    assert r.status_code == 200
    res = r.json()["result"]
    assert res["ref"] == "0123456789abcdef" and res["status"] == "ok" and res["key"] is True
    assert [m["id"] for m in res["models"]] == ["qwen/Qwen3-8B", "llama3:8b"]       # (the markup-shaped id is dropped)
    assert res["models"][0]["context"] == 32768 and "plain http" in res["warning"]
    assert KEY not in r.text and "api_key" not in r.text and "authorization" not in r.text   # no field a key could ride in
    srv = r.json()["servers"][0]
    assert srv["key_note"] == "key cleared: the address changed"
    assert srv["key"] is True and srv["enabled"] == ["a"] and [m["id"] for m in srv["models"]] == ["a", "b"]
    # a failed probe says its class and reason; junk is dropped
    d["result"] = {"ref": "fedcba9876543210", "op": "probe", "ok": True, "status": "dns", "detail": "its name does not resolve", "url": "http://x"}
    (sd / "local-models.json").write_text(json.dumps(d))
    res = c.get("/api/local-models", headers=API).json()["result"]
    assert res["status"] == "dns" and "does not resolve" in res["reason"] and res["models"] == []
    d["result"] = {"ref": "not hex"}
    (sd / "local-models.json").write_text(json.dumps(d))
    assert c.get("/api/local-models", headers=API).json()["result"] is None


# --- Pause, Resume and Cancel (JON-828) ---

def test_a_download_s_speed_time_left_and_whether_it_can_resume_are_read_field_by_field(tmp_path):
    _status(tmp_path, job={"state": "pulling", "repo": "a/b", "quant": "mlx", "done_bytes": 50, "total_bytes": 100, "rate": 9_800_000, "eta": 6420,
                           "stalled": 3, "message": "Downloading a/b"})
    j = lm.read_status(tmp_path)["job"]
    assert (j["rate"], j["eta"], j["stalled"], j["resumable"]) == (9_800_000, 6420, 3, False)
    _status(tmp_path, job={"state": "pulling", "repo": "a/b", "quant": "mlx", "done_bytes": 50, "total_bytes": 100, "rate": -5, "eta": -1, "stalled": "x"})
    j = lm.read_status(tmp_path)["job"]
    assert (j["rate"], j["eta"], j["stalled"]) == (0, None, 0)                  # (time left not known: none said)
    for state, done, can in (("paused", 50, True), ("paused", 0, True), ("failed", 50, True), ("failed", 0, False), ("cancelled", 0, False), ("done", 100, False)):
        _status(tmp_path, job={"state": state, "repo": "a/b", "quant": "mlx", "done_bytes": done, "total_bytes": 100})
        j = lm.read_status(tmp_path)["job"]
        assert j["state"] == state and j["resumable"] is can, (state, done)


def _stop(c, op, **kw):
    return c.post("/api/local-models/stop", headers=H, content=json.dumps({"op": op, **kw}))


def test_pause_and_cancel_need_no_password_and_write_a_request_with_the_op_alone(app):
    c, sd, rq = app
    _status(sd, job={"state": "pulling", "repo": "a/b", "quant": "mlx", "done_bytes": 50, "total_bytes": 100})
    assert c.get("/api/local-models", headers=API).json()["can_stop"] is True
    r = _stop(c, "pause")
    assert r.status_code == 202 and set(r.json()) == {"id", "op"}
    b = _body(rq)
    assert set(b) == {"action", "requested_at", "nonce", "op"} and b["action"] == "local-stop" and b["op"] == "pause"
    for f in rq.glob("act-*.json"):
        f.unlink()
    time.sleep(1.05)
    assert _stop(c, "cancel", password="ignored").status_code == 202            # (a password sent along is not used, nor written)
    b = _body(rq)
    assert b["op"] == "cancel" and "auth" not in b and "password" not in json.dumps(b)


def test_pause_is_for_a_running_download_and_cancel_also_for_a_paused_or_stopped_one(app):
    c, sd, rq = app
    _status(sd, job={"state": "idle"})
    assert _stop(c, "pause").status_code == 409 and _stop(c, "cancel").status_code == 409
    _status(sd, job={"state": "registering", "repo": "a/b", "quant": "mlx"})
    assert _stop(c, "pause").status_code == 409                                  # (registering takes seconds and is not stopped halfway)
    _status(sd, job={"state": "paused", "repo": "a/b", "quant": "mlx", "done_bytes": 5, "total_bytes": 10})
    assert _stop(c, "pause").status_code == 409
    assert _stop(c, "cancel").status_code == 202
    assert not [f for f in rq.glob("act-*.json") if json.loads(f.read_text())["op"] != "cancel"]
    for bad in ("stop", "delete", "", None, 5, "pause; rm"):
        assert _stop(c, bad).status_code == 400
    assert c.post("/api/local-models/stop", headers=H, content="[1]").status_code == 400


def test_pause_keeps_the_session_the_header_the_origin_the_remote_rule_and_a_helper_that_does_it(app, settings, monkeypatch):
    c, sd, rq = app
    _status(sd, job={"state": "pulling", "repo": "a/b", "quant": "mlx"})
    body = json.dumps({"op": "pause"})
    assert c.post("/api/local-models/stop", headers={**ORIGIN, "Content-Type": "application/json"}, content=body).status_code in (400, 403)
    assert c.post("/api/local-models/stop", headers={**API, "Origin": "http://evil.example", "Content-Type": "application/json"}, content=body).status_code == 403
    with TestClient(create_app(replace(settings, status_dir=sd, request_dir=rq), transport=httpx.MockTransport(hf)), follow_redirects=False,
                    base_url="http://bedrock-now.localhost") as anon:
        assert anon.post("/api/local-models/stop", headers=H, content=body).status_code in (401, 403)
    assert not list(rq.glob("act-*.json"))
    (sd / "helper-settings.json").write_text(json.dumps({"settings": 1, "local": list(st.LOCAL_ACTIONS) + ["local-server", "local-probe"], "written_at": int(time.time())}))
    r = _stop(c, "pause")
    assert r.status_code == 503 and "helper install" in r.json()["error"]           # an older helper: told to refresh it
    assert c.get("/api/local-models", headers=API).json()["can_stop"] is False
    assert not list(rq.glob("act-*.json"))


def test_while_a_download_is_paused_only_it_may_be_resumed(app):
    c, sd, rq = app
    _status(sd, runtime={"kind": "dmr", "how": ""}, job={"state": "paused", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "Q8_0", "done_bytes": 5, "total_bytes": 10})
    pull = {"password": PW, "action": "local-pull", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF", "quant": "Q4_K_M"}
    r = c.post("/api/local-models/change", headers=H, content=json.dumps(pull))
    assert r.status_code == 409 and "is paused: Resume or Cancel it first" in r.json()["error"]
    r = c.post("/api/local-models/change", headers=H, content=json.dumps({**pull, "quant": "q8_0"}))   # Resume: the same download again
    assert r.status_code == 202 and _body(rq)["quant"] == "Q8_0"


def test_the_stop_request_writer_takes_the_op_and_nothing_else(tmp_path):
    n = st.write_local_stop_action(tmp_path, "pause", now=1000)
    b = json.loads((tmp_path / f"act-{n}.json").read_text())
    assert b == {"action": "local-stop", "requested_at": 1000, "nonce": n, "op": "pause"}
    for bad in ("delete", "", "pause ", None):
        with pytest.raises(ValueError):
            st.write_local_stop_action(tmp_path, bad)
    d = tmp_path / "s"; d.mkdir()
    (d / "helper-settings.json").write_text(json.dumps({"settings": 1, "local": ["local-pull", "local-stop", "local-evil"], "written_at": int(time.time())}))
    assert st.capability(d)["local"] == ["local-pull", "local-stop"]
