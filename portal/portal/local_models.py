"""Local models (Settings › Models & providers › Local models; lib/local_models.sh): models downloaded from Hugging Face
and run on this computer by Docker Model Runner (else a host Ollama), served to LiteLLM, so they show in Chat, the Code
page and the terminal marked Local, at $0.

What this module does, and never does:

- It reads Hugging Face's public API from here (GET https://huggingface.co/api/models …: no key, nothing about you is
  sent): a search for GGUF repos, and one repo's quant files with size, license, tool use and context. No token is held
  or sent by the portal: the optional HF_TOKEN (gated models) stays in .env and reaches only the download's environment
  on the computer (lib/local_models.sh).
- It reads what ./stack wrote (.state/status/local-models.json: the runtime found, this computer's memory and GPU, what is
  downloaded, the disk it uses, the download's progress), field by field.
- A download or a removal is one request to the update helper (settings.write_local_action: the password, a repo and quant
  name — never a URL or a path), which starts ./stack local-models in the background. The helper checks it all again.
- "Fits this machine's memory" is an estimate, said as one (fits).
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

import httpx

from . import hostfiles

STATUS_FILE = "local-models.json"
WANTED = "local-wanted"
HF_API = "https://huggingface.co/api/models"
HF_TIMEOUT = httpx.Timeout(20.0, connect=5.0)
HF_MAX_BYTES = 6 * 1024 * 1024
MAX_AGE_S = 30                       # a status file older than this is asked for again (the helper rewrites it in seconds)
CACHE_S = 600
SEARCH_MAX = 24
REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}")
QUANT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
LICENSE = re.compile(r"[A-Za-z0-9.+-]{1,40}")
# the quant name in a GGUF file name: Q4_K_M, IQ3_XS, Q8_0, BF16, F16 … (after a - _ or .; before .gguf or -0000N-of-)
QUANT_IN_NAME = re.compile(r"(?:^|[-_.])((?:UD-)?(?:IQ|Q)[0-9][A-Za-z0-9_]*|BF16|F16|F32|MXFP4)(?=\.gguf$|-[0-9]{5}-of-[0-9]{5}\.gguf$)", re.I)
SHARD = re.compile(r"-([0-9]{5})-of-([0-9]{5})\.gguf$")
GIB = 1024 ** 3
TINY_PARAMS = 3_000_000_000          # under this: chat only (lib/local_models.sh LOCAL_TINY_PARAMS_M)
SMALL_PARAMS = 7_000_000_000

_cache: dict = {}


def _text(v, n: int = 120) -> str:
    return "".join(c for c in v if c.isprintable())[:n].strip() if isinstance(v, str) else ""


def _int(v, hi: int = 10 ** 15) -> int | None:
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v < hi else None


# --- how a model fares as Claude Code's, honestly (lib/local_models.sh local_model_compat says the same in the pickers) ---

def tools_of(template) -> str:
    """yes | no | unknown: whether a GGUF's chat template (tokenizer.chat_template, as Hugging Face reads it) handles tool
    calls. A template with no mention of tools cannot take Claude Code's; one that names them can, which does not mean
    the model is good at it."""
    if not isinstance(template, str) or not template.strip():
        return "unknown"
    t = template.lower()
    return "yes" if ("tools" in t or "tool_call" in t or "tool_calls" in t or "<tool" in t or "function_call" in t) else "no"


def tool_note(tools: str, params: int | None) -> dict:
    """{level: chat-only | weak | untested, text}: what to expect of it as Claude Code's model. Under 3B parameters, or a
    template with no tool support: chat only. Under 7B: weak at tools — wrong or repeated calls. Never "works": nothing
    local was checked against Claude Code here. (Each answer is capped, so a stuck model stops: JON-805.)"""
    if tools == "no":
        return {"level": "chat-only", "text": "Its chat template has no tool-call support: Claude Code can only chat with it."}
    if params is not None and params < TINY_PARAMS:
        return {"level": "chat-only", "text": f"About {params / 1e9:.1f}B parameters: too small for Claude Code's tools (wrong or repeated calls). Fine for chat."}
    if params is not None and params < SMALL_PARAMS:
        return {"level": "weak", "text": f"About {params / 1e9:.1f}B parameters: weak at Claude Code's tools. Expect wrong or repeated calls."}
    return {"level": "untested", "text": "Not checked with Claude Code. Local models are weaker at its tools than the cloud ones" +
            ("." if tools == "yes" else "; its chat template does not say whether it handles tools.")}


# --- does it fit this machine's memory ---

def fits(size: int | None, memory: int | None, gpu: str) -> dict:
    """{fit: yes | tight | no | unknown, text}: an estimate. The file in memory needs ~1.15x its size plus 1 GiB for the
    context (KV cache) and the runtime. Apple silicon (gpu "metal"): the GPU may use about 70% of the unified memory;
    NVIDIA ("cuda:<VRAM bytes>"): the model should fit its VRAM, else it spills to the CPU (slow); no GPU: the CPU, which
    may use about 60% of the memory before the computer swaps."""
    if not size or not memory:
        return {"fit": "unknown", "text": "This computer's memory is not known yet."}
    need = int(size * 1.15) + GIB
    gb = lambda n: f"{n / GIB:.1f} GB"  # noqa: E731
    if gpu == "metal":
        budget, where = int(memory * 0.70), "the GPU's share of this Mac's memory"
    elif gpu.startswith("cuda:") and gpu[5:].isdigit() and int(gpu[5:]) > 0:
        vram = int(gpu[5:])
        if need <= vram * 0.92:
            return {"fit": "yes" if need <= vram * 0.75 else "tight", "need": need,
                    "text": f"needs about {gb(need)}; the GPU has {gb(vram)}" + ("" if need <= vram * 0.75 else " — a tight fit")}
        if need <= memory * 0.6:
            return {"fit": "tight", "need": need, "text": f"needs about {gb(need)}, more than the GPU's {gb(vram)}: part runs on the CPU, slower"}
        return {"fit": "no", "need": need, "text": f"needs about {gb(need)}; the GPU has {gb(vram)} and this computer {gb(memory)}"}
    else:
        budget, where = int(memory * 0.60), "this computer's memory (CPU only: slower)"
    if need <= budget * 0.75:
        return {"fit": "yes", "need": need, "text": f"needs about {gb(need)}; {where} is about {gb(budget)}"}
    if need <= budget:
        return {"fit": "tight", "need": need, "text": f"needs about {gb(need)}; {where} is about {gb(budget)} — a tight fit"}
    return {"fit": "no", "need": need, "text": f"needs about {gb(need)}; {where} is about {gb(budget)}"}


# --- Hugging Face's public API ---

def _license_of(tags, card) -> str:
    for t in tags if isinstance(tags, list) else []:
        if isinstance(t, str) and t.startswith("license:") and LICENSE.fullmatch(t[8:]):
            return t[8:]
    lic = card.get("license") if isinstance(card, dict) else None
    if isinstance(lic, list) and lic:
        lic = lic[0]
    return lic if isinstance(lic, str) and LICENSE.fullmatch(lic) else ""


def repo_row(m: dict, fmt: str = "gguf") -> dict | None:
    """One repo of Hugging Face's list (or its model page) → {repo, downloads, likes, gated, license, params, context,
    architecture, tools}: field by field; None when it is not a repo we could pull."""
    rid = m.get("id") if isinstance(m, dict) else None
    if not isinstance(rid, str) or not REPO.fullmatch(rid):
        return None
    g = m.get("gguf") if isinstance(m.get("gguf"), dict) else {}
    if fmt in ("mlx", "vllm"):   # MLX's, or vLLM's safetensors: parameters from their header, the rest from its config and tokenizer
        cfg = m.get("config") if isinstance(m.get("config"), dict) else {}
        tk = cfg.get("tokenizer_config") if isinstance(cfg.get("tokenizer_config"), dict) else {}
        sf = m.get("safetensors") if isinstance(m.get("safetensors"), dict) else {}
        g = {"total": sf.get("total"), "context_length": cfg.get("max_position_embeddings"),
             "architecture": cfg.get("model_type"), "chat_template": tk.get("chat_template")}
    gated = m.get("gated")
    return {"repo": rid, "downloads": _int(m.get("downloads")) or 0, "likes": _int(m.get("likes")) or 0,
            "gated": bool(gated) and gated is not None, "private": bool(m.get("private")),
            "license": _license_of(m.get("tags"), m.get("cardData")),
            "params": _int(g.get("total")), "context": _int(g.get("context_length")),
            "architecture": _text(g.get("architecture"), 40), "tools": tools_of(g.get("chat_template"))}


async def _get(client: httpx.AsyncClient, url: str, params=None) -> tuple[object, str | None]:
    try:
        r = await client.get(url, params=params, timeout=HF_TIMEOUT, headers={"Accept": "application/json"})
        if r.status_code == 404:
            return None, "Hugging Face has no such model."
        if r.status_code in (401, 403):
            return None, "That model is gated or private: accept its license on huggingface.co and add an HF token (Settings › Models & providers › Hugging Face token)."
        if r.status_code == 429:
            return None, "Hugging Face is rate-limiting this computer's address: try again in a minute."
        if r.status_code != 200:
            return None, f"huggingface.co answered HTTP {r.status_code}"
        if len(r.content) > HF_MAX_BYTES:
            return None, "huggingface.co sent too much"
        return r.json(), None
    except (httpx.HTTPError, ValueError) as e:
        return None, f"huggingface.co did not answer ({type(e).__name__})"


EXPAND = ["downloads", "likes", "gated", "tags", "gguf", "private"]
EXPAND_MLX = ["downloads", "likes", "gated", "tags", "safetensors", "config", "private"]
# what Browse models looks for, by the runtime a download goes to (lib/local_models.sh local_runtime): MLX repos, a model's
# own safetensors weights (vLLM: text generation, with transformers), or GGUF files
FILTERS = {"mlx": ["mlx"], "vllm": ["safetensors", "text-generation", "transformers"], "gguf": ["gguf"]}


def fmt_of(kind: str) -> str:
    """The kind of repo the runtime a download goes to takes: mlx, vllm (safetensors), or gguf (the rest)"""
    return kind if kind in ("mlx", "vllm") else "gguf"


async def search(client: httpx.AsyncClient, query: str, now: float | None = None, fmt: str = "gguf") -> tuple[list[dict], str | None]:
    """GGUF repos (fmt "mlx": MLX repos, Hugging Face's mlx library; "vllm": text-generation models with safetensors
    weights, never an MLX one or one that runs code of its own) matching QUERY, most downloaded first (a blank query: the
    most downloaded). -> (rows, error)"""
    now = time.time() if now is None else now
    q = _text(query, 80)
    hit = _cache.get(("s", q, fmt))
    if hit and now - hit[0] < CACHE_S:
        return hit[1], None
    params = [("filter", f) for f in FILTERS.get(fmt, FILTERS["gguf"])] + [("sort", "downloads"), ("direction", "-1"), ("limit", str(SEARCH_MAX))] \
        + [("expand[]", e) for e in (EXPAND_MLX if fmt in ("mlx", "vllm") else EXPAND)]
    if q:
        params.append(("search", q))
    data, err = await _get(client, HF_API, params)
    if err:
        return (hit[1] if hit else []), err
    ms = [m for m in (data if isinstance(data, list) else []) if not (fmt == "vllm" and _vllm_unfit(m.get("tags") if isinstance(m, dict) else None))]
    rows = [r for r in (repo_row(m, fmt) for m in ms) if r and not r["private"]]
    _cache[("s", q, fmt)] = (now, rows)
    if len(_cache) > 200:
        _cache.clear()
    return rows, None


def mlx_of(tree) -> tuple[list[dict], str]:
    """An MLX repo is one download, whole: its weights' size, and why it must be refused ('' when nothing is): any Python
    file in it (a model that ships code is how one runs code on this computer). -> ([the one "quant"], blocked)"""
    files = [f for f in tree if isinstance(f, dict) and f.get("type") == "file" and isinstance(f.get("path"), str)] if isinstance(tree, list) else []
    py = [f["path"] for f in files if f["path"].endswith(".py")]
    size = 0
    for f in files:
        if f["path"].endswith(".safetensors"):
            lfs = f.get("lfs") if isinstance(f.get("lfs"), dict) else {}
            size += _int(lfs.get("size")) or _int(f.get("size")) or 0
    if not size:
        return [], "It has no .safetensors weights."
    blocked = f"It ships Python files ({', '.join(_text(x, 40) for x in py[:3])}): DevOS ADE never runs a model's own code." if py else ""
    return [{"quant": "mlx", "size": size, "files": sum(1 for f in files if f["path"].endswith(".safetensors"))}], blocked


def _vllm_unfit(tags) -> str:
    """Why a repo is not one vLLM is given ('' when it is): code of its own (Hugging Face's custom_code tag: vLLM never
    runs it), or MLX weights (Apple's format)"""
    tags = [t for t in tags if isinstance(t, str)] if isinstance(tags, list) else []
    if "custom_code" in tags:
        return "It asks to run code of its own (custom_code): DevOS ADE never runs a model's own code."
    if "mlx" in tags:
        return "It is an MLX model (Apple's format): vLLM needs the original weights."
    return ""


def vllm_of(tree, tags) -> tuple[list[dict], str]:
    """A model for vLLM is one download, whole: its top-level safetensors weights' size (with its config and tokenizer:
    lib/local_models.sh _local_st_vet), and why it must be refused ('' when nothing is). -> ([the one "quant"], blocked)"""
    files = [f for f in tree if isinstance(f, dict) and f.get("type") == "file" and isinstance(f.get("path"), str)] if isinstance(tree, list) else []
    weights = [f for f in files if "/" not in f["path"] and f["path"].endswith(".safetensors")]
    size = sum(_int((f.get("lfs") or {}).get("size") if isinstance(f.get("lfs"), dict) else None) or _int(f.get("size")) or 0 for f in weights)
    if not size:
        return [], "It has no safetensors weights (a GGUF model goes to llama.cpp)."
    if not any(f["path"] == "config.json" for f in files):
        return [], "It has no config.json: not a model vLLM loads."
    return [{"quant": "safetensors", "size": size, "files": len(weights)}], _vllm_unfit(tags)


def quants_of(tree) -> list[dict]:
    """A repo's file list (GET /api/models/<repo>/tree/main?recursive=true) → its quants: [{quant, size, files, file}]
    smallest first. A split model (…-00001-of-00003.gguf) is one quant with its parts summed; the vision projectors
    (mmproj) and anything not a .gguf are left out."""
    by: dict[str, dict] = {}
    for f in tree if isinstance(tree, list) else []:
        path = f.get("path") if isinstance(f, dict) else None
        if not isinstance(path, str) or not path.lower().endswith(".gguf") or f.get("type") != "file":
            continue
        base = path.rsplit("/", 1)[-1]
        if "mmproj" in base.lower() or len(path) > 300:
            continue
        m = QUANT_IN_NAME.search(base)
        size = _int((f.get("lfs") or {}).get("size")) if isinstance(f.get("lfs"), dict) else None
        size = size if size is not None else _int(f.get("size"))
        if not m or not size:
            continue
        quant = m.group(1).upper()
        e = by.setdefault(quant, {"quant": quant, "size": 0, "files": 0, "file": path})
        e["size"] += size
        e["files"] += 1
        if SHARD.search(base) and not base.endswith("-00001-of-" + SHARD.search(base).group(2) + ".gguf"):
            continue
        e["file"] = path
    return sorted((e for e in by.values() if QUANT.fullmatch(e["quant"])), key=lambda e: (e["size"], e["quant"]))


async def repo_files(client: httpx.AsyncClient, repo: str, now: float | None = None, fmt: str = "gguf") -> tuple[dict | None, str | None]:
    """One repo for the page: its facts (license, gated, params, context, tool use) and its quants. -> (repo | None, error)"""
    now = time.time() if now is None else now
    if not REPO.fullmatch(repo or ""):
        return None, "That is not a Hugging Face repo (org/name)."
    hit = _cache.get(("r", repo.lower(), fmt))
    if hit and now - hit[0] < CACHE_S:
        return hit[1], None
    info, err = await _get(client, f"{HF_API}/{repo}", [("expand[]", e) for e in (EXPAND_MLX if fmt in ("mlx", "vllm") else EXPAND) + ["cardData"]])
    if err:
        return None, err
    row = repo_row(info if isinstance(info, dict) else {}, fmt)
    if row is None:
        return None, "Hugging Face did not describe that repo."
    tree, err = await _get(client, f"{HF_API}/{repo}/tree/main", [("recursive", "true")])
    if err:
        return None, err
    row["blocked"] = ""
    if fmt == "mlx":
        row["quants"], row["blocked"] = mlx_of(tree)
    elif fmt == "vllm":
        row["quants"], row["blocked"] = vllm_of(tree, info.get("tags") if isinstance(info, dict) else None)
    else:
        row["quants"] = quants_of(tree)
    row["note"] = tool_note(row["tools"], row["params"])
    if not row["quants"]:
        return None, {"mlx": "That repo has no MLX weights this runtime can use.", "vllm": row["blocked"] or "That repo has no safetensors weights vLLM can load."}.get(
            fmt, "That repo has no GGUF files this runtime can pull.")
    _cache[("r", repo.lower(), fmt)] = (now, row)
    return row, None


def annotate(row: dict, memory: int | None, gpu: str, installed: list[dict]) -> dict:
    """The repo's quants with whether each fits this machine and whether it is downloaded already."""
    have = {(i["repo"].lower(), i["quant"].lower()) for i in installed}
    out = dict(row)
    out["quants"] = [{**q, "fits": fits(q["size"], memory, gpu), "installed": (row["repo"].lower(), q["quant"].lower()) in have}
                     for q in row["quants"]]
    return out


# --- what ./stack wrote ---

JOB_STATES = ("idle", "pulling", "registering", "removing", "done", "failed", "paused", "cancelled")
LIVE = ("pulling", "registering", "removing")


def _clean_job(j: dict) -> dict:
    """job.json's download or removal (lib/local_models.sh _local_job): rate in bytes a second, eta in seconds (None: not
    known), stalled: seconds since anything arrived. A paused or stopped download keeps a part (resumable) when bytes arrived."""
    st = j.get("state") if j.get("state") in JOB_STATES else "idle"
    eta = _int(j.get("eta"))
    return {"state": st, "repo": _text(j.get("repo"), 200), "quant": _text(j.get("quant"), 64),
            "done_bytes": _int(j.get("done_bytes")) or 0, "total_bytes": _int(j.get("total_bytes")) or 0,
            "rate": _int(j.get("rate")) or 0, "eta": eta if eta is not None and eta >= 0 else None, "stalled": _int(j.get("stalled")) or 0,
            "resumable": st == "paused" or (st == "failed" and (_int(j.get("done_bytes")) or 0) > 0),
            "message": _text(j.get("message"), 300), "at": _int(j.get("at"))}


_MODEL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}")


def parse_models(detail: str) -> list:
    """lib/local_models.sh msrv_probe's "id|context;id|context" -> [{"id", "context"}]"""
    out = []
    for m in _text(detail, 2000).split(";")[:200]:
        mid, _, ctx = m.partition("|")
        if _MODEL_ID.fullmatch(mid):
            out.append({"id": mid, "context": (int(ctx) if ctx.isdigit() and int(ctx) > 0 else None)})
    return out


def clean_result(r) -> dict | None:
    """The last model-server form answer (server-result.json, in the status file): a probe's finding, or what a save, a
    toggle, a key change or a removal came to. Field by field; there is no field a key could be in."""
    if not isinstance(r, dict) or not re.fullmatch(r"[0-9a-f]{8,32}", r.get("ref") or ""):
        return None
    st = r.get("status") if r.get("status") in ("ok", "down", "blocked", "numeric", "dns") else ""
    return {"ref": r["ref"], "op": r.get("op") if r.get("op") in ("probe", "save", "models", "key", "remove") else "",
            "name": _text(r.get("name"), 24) if re.fullmatch(r"[a-z0-9][a-z0-9-]{0,23}", r.get("name") or "") else "",
            "ok": r.get("ok") is True, "message": _text(r.get("message"), 400), "status": st,
            "models": parse_models(r.get("detail")) if st == "ok" else [],
            "reason": _text(r.get("detail"), 300) if st and st != "ok" else "", "warning": _text(r.get("warning"), 200),
            "key": r.get("key") is True, "trust": r.get("trust") is True, "url": _text(r.get("url"), 200), "at": _int(r.get("at"))}


def read_status(status_dir: Path, now: float | None = None) -> dict:
    """.state/status/local-models.json, field by field (nothing the file says is trusted as markup or a path)."""
    now = time.time() if now is None else now
    d = hostfiles.read_json(status_dir / STATUS_FILE, 256 * 1024)
    at = _int(d.get("at"))
    rt = d.get("runtime") if isinstance(d.get("runtime"), dict) else {}
    kind = rt.get("kind") if rt.get("kind") in ("mlx", "dmr", "ollama", "llamacpp", "lmstudio", "vllm", "none") else "none"
    installed = []
    for i in (d.get("installed") if isinstance(d.get("installed"), list) else [])[:200]:
        if not isinstance(i, dict) or not REPO.fullmatch(i.get("repo") or "") or not QUANT.fullmatch(i.get("quant") or ""):
            continue
        installed.append({"runtime": i.get("runtime") if i.get("runtime") in ("mlx", "dmr", "ollama", "llamacpp", "lmstudio", "vllm") else "", "id": _text(i.get("id"), 160),
                          "name": _text(i.get("name"), 160), "repo": i["repo"], "quant": i["quant"], "bytes": _int(i.get("bytes")) or 0,
                          "license": _text(i.get("license"), 40) if LICENSE.fullmatch(_text(i.get("license"), 40) or "-") else "",
                          "tools": {"1": "yes", "0": "no"}.get(str(i.get("tools")), "unknown"),
                          "present": i.get("present") is not False, "registered": i.get("registered") is True,
                          "revision": i.get("revision") if re.fullmatch(r"[0-9a-f]{40}", i.get("revision") or "") else ""})
    servers = []
    for s in (d.get("servers") if isinstance(d.get("servers"), list) else [])[:8]:
        if not isinstance(s, dict) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,23}", s.get("name") or ""):
            continue
        up = s.get("status") == "ok"
        models = []
        if up:   # "id|context;id|context" (lib/local_models.sh msrv_probe)
            for m in _text(s.get("detail"), 2000).split(";")[:200]:
                mid, _, ctx = m.partition("|")
                if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}", mid):
                    models.append({"id": mid, "context": (int(ctx) if ctx.isdigit() and int(ctx) > 0 else None)})
        en = [x for x in _text(s.get("enabled"), 1500).split(";") if x]
        servers.append({"name": s["name"], "url": _text(s.get("url"), 200), "reached_as": _text(s.get("reached_as"), 240),
                        "trust": s.get("trust") is True, "key": s.get("key") is True, "up": up,
                        "reason": "" if up else _text(s.get("detail"), 300), "warning": _text(s.get("warning"), 200),
                        "key_note": _text(s.get("key_note"), 120), "models": models, "all": "*" in en, "enabled": [x for x in en if x != "*"][:200]})
    return {"known": at is not None, "at": at, "servers": servers, "result": clean_result(d.get("result")), "stale": at is None or now - at > MAX_AGE_S,
            "runtime": {"kind": kind, "how": _text(rt.get("how"), 400), "command": "./stack local-models enable",
                        "dmr": _text(rt.get("dmr"), 20), "ollama": _text(rt.get("ollama"), 20), "mlx": _text(rt.get("mlx"), 20),
                        "llamacpp": _text(rt.get("llamacpp"), 20), "lmstudio": _text(rt.get("lmstudio"), 20), "vllm": _text(rt.get("vllm"), 20)},
            "gpu": _text(d.get("gpu"), 40) or "none", "memory": _int(d.get("memory_bytes")) or 0,
            "disk": _int(d.get("disk_bytes")) or 0, "installed": installed,
            "job": _clean_job(d.get("job") if isinstance(d.get("job"), dict) else {})}


# --- the model runtimes DevOS ADE installs and runs itself (lib/runtimes.sh: status/runtimes.json) ---
RUNTIMES_FILE = "runtimes.json"
RUNTIME_IDS = ("ollama", "llamacpp", "lmstudio", "vllm")
RUNTIME_NAMES = {"ollama": "Ollama", "llamacpp": "llama.cpp", "lmstudio": "LM Studio", "vllm": "vLLM"}
RUNTIME_PORTS = {"ollama": 11434, "llamacpp": 11438, "lmstudio": 11439}   # (lib/runtimes.sh rt_port; vLLM: none here)
# (waiting: vLLM installed, with no model to serve yet)
RT_STATES = ("installing", "running", "starting", "stopped", "waiting", "not-installed", "external", "unsupported")
RT_JOB_OPS = ("install", "start", "stop", "uninstall")
RT_JOB_STATES = ("idle", "running", "done", "failed", "cancelled")
RT_EVENTS = ("installed", "removed", "started", "stopped", "restart", "down", "up", "failed")
RT_MAX_AGE_S = 180                   # older: the helper is not writing it (it does every minute)
# (127.0.0.1:<port>, or llama.cpp's and vLLM's containers on Linux: no port here, the gateway's network only)
_ADDRESS = re.compile(r"127\.0\.0\.1:[0-9]{1,5}|(?:llamacpp:8080|vllm:8000) \(the model gateway's network only\)")
_VERSION = re.compile(r"[0-9A-Za-z.+-]{1,40}")


def _rt_one(r: dict) -> dict | None:
    if not isinstance(r, dict) or r.get("id") not in RUNTIME_IDS:
        return None
    loaded = []
    for m in (r.get("loaded") if isinstance(r.get("loaded"), list) else [])[:32]:
        if isinstance(m, dict) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,159}", m.get("name") or "") and ".." not in m["name"]:
            loaded.append({"name": m["name"], "bytes": _int(m.get("bytes")) or 0, "gpu_bytes": _int(m.get("gpu_bytes")) or 0})
    ver, pin = _text(r.get("version"), 40), _text(r.get("pinned"), 40)
    return {"id": r["id"], "name": RUNTIME_NAMES[r["id"]], "state": r.get("state") if r.get("state") in RT_STATES else "unsupported",
            "managed": r.get("managed") is True, "kind": r.get("kind") if r.get("kind") in ("agent", "container") else "none",
            "version": ver if _VERSION.fullmatch(ver) else "", "pinned": pin if _VERSION.fullmatch(pin) else "",
            "address": r["address"] if _ADDRESS.fullmatch(r.get("address") or "") else "", "loaded": loaded,
            "memory": _int(r.get("memory_bytes")) or 0, "gpu_memory": _int(r.get("gpu_bytes")) or 0,
            "restarts": _int(r.get("restarts"), 10 ** 6), "last_exit": _int(r.get("last_exit"), 256),
            "size": _text(r.get("size"), 80), "why_not": _text(r.get("why_not"), 200)}


def read_runtimes(status_dir: Path, now: float | None = None) -> dict:
    """.state/status/runtimes.json (lib/runtimes.sh rt_status_write), field by field: each runtime (state, version, its
    address, the models loaded and their memory, restarts), the one job (install, start, stop, uninstall) and the last
    events (Activity)."""
    now = time.time() if now is None else now
    d = hostfiles.read_json(status_dir / RUNTIMES_FILE, 128 * 1024)
    at = _int(d.get("at"))
    rts = [x for x in (_rt_one(r) for r in (d.get("runtimes") if isinstance(d.get("runtimes"), list) else [])[:8]) if x]
    j = d.get("job") if isinstance(d.get("job"), dict) else {}
    job = {"id": j.get("id") if j.get("id") in RUNTIME_IDS else "", "op": j.get("op") if j.get("op") in RT_JOB_OPS else "",
           "state": j.get("state") if j.get("state") in RT_JOB_STATES else "idle",
           "done_bytes": _int(j.get("done_bytes")) or 0, "total_bytes": _int(j.get("total_bytes")) or 0,
           "message": _text(j.get("message"), 400), "at": _int(j.get("at"))}
    events = []
    for e in (d.get("events") if isinstance(d.get("events"), list) else [])[-30:]:
        if isinstance(e, dict) and e.get("id") in RUNTIME_IDS and e.get("kind") in RT_EVENTS and _int(e.get("at")) is not None:
            events.append({"at": _int(e.get("at")), "id": e["id"], "kind": e["kind"], "text": _text(e.get("text"), 300)})
    return {"known": at is not None, "at": at, "stale": at is None or now - at > RT_MAX_AGE_S,
            "os": d.get("os") if d.get("os") in ("mac", "linux") else "other", "runtimes": rts, "job": job, "events": events}


def read_runtime_logs(status_dir: Path, runtime: str) -> dict:
    """status/runtime-logs/<id>.txt (./stack runtimes logs ID --portal, when Settings asks): its last lines, printable only"""
    if runtime not in RUNTIME_IDS:
        return {"text": "", "at": None}
    p = status_dir / "runtime-logs" / f"{runtime}.txt"
    try:
        if p.is_symlink() or not p.is_file():
            return {"text": "", "at": None}
        raw = p.read_bytes()[-256 * 1024:].decode("utf-8", "replace")
        return {"text": "\n".join("".join(c for c in line if c.isprintable() or c == "\t")[:400] for line in raw.splitlines()[-2000:]),
                "at": int(p.stat().st_mtime)}
    except OSError:
        return {"text": "", "at": None}


def find_quant(row: dict, quant: str) -> dict | None:
    return next((q for q in row.get("quants") or [] if q["quant"].lower() == quant.lower()), None)


def pull_fields(row: dict, quant: dict) -> dict:
    """What the helper's request carries about a download: facts worked out here from Hugging Face's answer (the helper
    checks each field's shape again, and ./stack keeps them for the picker's notes)."""
    return {"repo": row["repo"], "quant": quant["quant"], "bytes": int(quant["size"]), "tools": row["tools"],
            "context": int(row["context"] or 0), "params_m": int((row["params"] or 0) // 1_000_000),
            "license": row["license"] if row["license"] else "unknown"}
