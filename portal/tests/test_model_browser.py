"""The model browser (portal/portal/model_browser.py): parsing each provider's list (from recorded fixtures, never a
real key), the setting change that adds or removes one model (plan), the whole browse answer (what is enabled, chosen,
and what can be done), and Try it's cost estimate. The lists come from .state/status/model-browser/ (lib/model_browser.sh
writes them) and OpenRouter's public list; nothing here holds a key."""

import asyncio
import json

import httpx

from portal import model_browser as mb

# Self-contained: minimal catalog files written here, so the test runs both in a checkout and in the portal test image
# (which does not copy code-models.tsv, models.tsv or tests/fixtures).
_CODE_MODELS_TSV = (
    "# pattern\tstatus\tmax_out\tnote\n"
    "claude-*\tworks\t-\tAnthropic's own.\n"
    "llama-*\tuntested\t-\tTranslated.\n")
_MODELS_TSV = (
    "# name\tmode\tlitellm_model\taliases\tregion\n"
    "claude-opus-5-5\tchat\tbedrock/invoke/us.anthropic.claude-opus-5-5\t-\t-\n"
    "claude-haiku-5-5\tchat\tbedrock/invoke/us.anthropic.claude-haiku-5-5\t-\t-\n")


def _catalog(tmp_path):
    cat = tmp_path / "catalog"
    cat.mkdir(exist_ok=True)
    (cat / "code-models.tsv").write_text(_CODE_MODELS_TSV, encoding="utf-8")
    (cat / "models.tsv").write_text(_MODELS_TSV, encoding="utf-8")
    return cat


# An OpenRouter public-list answer in the real shape (trimmed): used in place of the recorded fixture so the test is
# self-contained.
_OR_DOC = {"data": [
    {"id": "meta-llama/llama-3.3-70b-instruct", "name": "Meta: Llama 3.3 70B Instruct",
     "pricing": {"prompt": "0.00000022", "completion": "0.0000005", "input_cache_read": "0.00000011"},
     "context_length": 131072, "architecture": {"output_modalities": ["text"], "input_modalities": ["text"]},
     "supported_parameters": ["tools", "temperature"]},
    {"id": "z-ai/glm-5-air:free", "name": "Z.AI: GLM 5 Air (free)", "pricing": {"prompt": "0", "completion": "0"},
     "context_length": 131072, "architecture": {"output_modalities": ["text"], "input_modalities": ["text", "image"]},
     "supported_parameters": ["temperature"]},
    {"id": "openai/gpt-5-vision", "name": "OpenAI: GPT-5 Vision", "pricing": {"prompt": "0.000002", "completion": "0.000008"},
     "context_length": 400000, "architecture": {"output_modalities": ["text"], "input_modalities": ["text", "image"]},
     "supported_parameters": ["tools"]},
    {"id": "some/router", "name": "Router", "pricing": {"prompt": "-1", "completion": "-1"}, "architecture": {"output_modalities": ["text"]}},
    {"id": "some/model:batch", "name": "Batch", "pricing": {"prompt": "1", "completion": "1"}, "architecture": {"output_modalities": ["text"]}},
]}


def _mbdir(tmp_path):
    d = tmp_path / "model-browser"
    d.mkdir(exist_ok=True)
    return d


# --- OpenRouter's public list ---

def test_openrouter_rows_from_the_public_list():
    rows = mb.openrouter_rows(_OR_DOC)
    by = {r["source_id"]: r for r in rows}
    llama = by["meta-llama/llama-3.3-70b-instruct"]
    assert llama["provider"] == "openrouter" and llama["id"] == "or/meta-llama/llama-3.3-70b-instruct"
    assert llama["vendor"] == "Meta" and llama["name"] == "Llama 3.3 70B Instruct"
    assert llama["in"] == 0.22 and llama["out"] == 0.5          # per million, from per-token strings
    assert llama["tools"] is True and llama["context"] == 131072 and llama["free"] is False
    # a free model is free, with its image input; a variable-priced router and a :batch variant are left out
    assert by["z-ai/glm-5-air:free"]["free"] is True and by["z-ai/glm-5-air:free"]["images"] is True
    assert by["openai/gpt-5-vision"]["images"] is True and by["openai/gpt-5-vision"]["tools"] is True
    assert "some/router" not in by and "some/model:batch" not in by
    for r in rows:
        if r["in"] == 0 and r["out"] == 0:
            assert r["free"] is True


def test_openrouter_rows_drop_the_unusable():
    doc = {"data": [
        {"id": "a/b", "name": "A: B", "pricing": {"prompt": "0.000001", "completion": "0.000002"},
         "architecture": {"output_modalities": ["text"], "input_modalities": ["text", "image"]}, "supported_parameters": ["tools"]},
        {"id": "a/img", "name": "img", "pricing": {"prompt": "0", "completion": "0"}, "architecture": {"output_modalities": ["image"]}},
        {"id": "a/b:batch", "name": "batch", "pricing": {"prompt": "0.1", "completion": "0.1"}, "architecture": {"output_modalities": ["text"]}},
        {"id": "a/router", "name": "router", "pricing": {"prompt": "-1", "completion": "-1"}, "architecture": {"output_modalities": ["text"]}},
        {"id": "bad id", "name": "x", "pricing": {"prompt": "1", "completion": "1"}},
    ]}
    rows = mb.openrouter_rows(doc)
    assert [r["source_id"] for r in rows] == ["a/b"]
    r = rows[0]
    assert r["in"] == 1.0 and r["out"] == 2.0 and r["images"] is True and r["tools"] is True


# --- Experiential Labs: the key's ids joined with the public catalog ---

def test_explabs_rows_join_ids_with_the_catalog(tmp_path):
    d = _mbdir(tmp_path)
    (d / "explabs-ids.json").write_text(json.dumps({"provider": "explabs", "at": 1000, "error": None,
        "ids": ["qwen3.8-27b", "deepseek-v4.1-flash:free", "org-own-model"]}), encoding="utf-8")
    # the catalog page, in the gateway's shape (a trimmed real entry for each slug)
    page = {"total": 2, "models": [
        {"model": {"slug": "qwen3.8-27b", "display_name": "Qwen3.8 27B", "maker": "Qwen", "context_window": 1000000,
                   "input_modalities": ["text", "image"], "output_modalities": ["text"], "supported_params": {"tools": True}},
         "providers": [{"id": "x", "status": "active", "input_nano_usd_per_million": 320000000, "output_nano_usd_per_million": 2400000000,
                        "capabilities": {"supports_tools": True, "supports_image_input": False}}],
         "default_provider_ids": ["x"]},
        {"model": {"slug": "deepseek-v4.1-flash", "display_name": "DeepSeek V4.1 Flash", "maker": "DeepSeek", "context_window": 393216,
                   "input_modalities": ["text"], "output_modalities": ["text"]},
         "providers": [{"id": "y", "status": "active", "input_nano_usd_per_million": 300000000, "output_nano_usd_per_million": 1200000000,
                        "capabilities": {"supports_tools": True}}], "default_provider_ids": ["y"]},
    ]}
    (d / "explabs-catalog-1.json").write_text(json.dumps(page), encoding="utf-8")
    rows, meta = mb.explabs_rows(tmp_path)
    by = {r["source_id"]: r for r in rows}
    assert meta["at"] == 1000 and meta["error"] is None
    q = by["qwen3.8-27b"]
    assert q["id"] == "xl/qwen3.8-27b" and q["in"] == 0.32 and q["out"] == 2.4 and q["tools"] is True and q["free"] is False
    # a "<slug>:free" alias: its slug's details, priced $0, free; the name marked (free)
    fr = by["deepseek-v4.1-flash:free"]
    assert fr["id"] == "xl/deepseek-v4.1-flash:free" and fr["in"] == 0.0 and fr["out"] == 0.0 and fr["free"] is True
    assert fr["context"] == 393216 and "free" in fr["name"].lower()
    # a model the public catalog has no entry for: still listed, no details, said
    own = by["org-own-model"]
    assert own["in"] is None and own["note"]


# --- Bedrock: ListFoundationModels + its inference profiles, as the one-off container wrote them ---

def test_bedrock_rows_and_the_denied_path(tmp_path):
    d = _mbdir(tmp_path)
    (d / "bedrock.json").write_text(json.dumps({"provider": "bedrock", "status": "ok", "region": "us-east-1", "at": 2000, "models": [
        {"id": "anthropic.claude-3-5-haiku-20241022-v1:0", "model_id": "anthropic.claude-3-5-haiku-20241022-v1:0",
         "name": "Claude 3.5 Haiku", "vendor": "Anthropic", "how": "on-demand", "lifecycle": "ACTIVE",
         "prices": {"in": 0.8, "out": 4.0, "cache_read": None, "cache_write": None}, "context": 200000, "max_out": 8192, "tools": True, "images": True},
        {"id": "us.meta.llama4-maverick-17b-instruct-v1:0", "model_id": "meta.llama4-maverick-17b-instruct-v1:0",
         "name": "Llama 4 Maverick", "vendor": "Meta", "how": "profile", "lifecycle": "ACTIVE", "prices": None, "context": None, "max_out": None, "tools": None, "images": None},
    ]}), encoding="utf-8")
    rows, meta = mb.bedrock_rows(tmp_path)
    assert meta["status"] == "ok" and meta["region"] == "us-east-1" and meta["at"] == 2000
    by = {r["source_id"]: r for r in rows}
    h = by["anthropic.claude-3-5-haiku-20241022-v1:0"]
    assert h["id"] == h["source_id"] and h["in"] == 0.8 and h["out"] == 4.0 and h["context"] == 200000 and h["tools"] is True
    m = by["us.meta.llama4-maverick-17b-instruct-v1:0"]
    assert m["in"] is None and m["vendor"] == "Meta"     # priced by LiteLLM, unknown here
    # a key that may not list: status denied, no rows
    (d / "bedrock.json").write_text(json.dumps({"provider": "bedrock", "status": "denied",
        "why": "the AWS key may not call bedrock:ListFoundationModels", "at": 3000, "models": []}), encoding="utf-8")
    rows, meta = mb.bedrock_rows(tmp_path)
    assert rows == [] and meta["status"] == "denied" and "ListFoundationModels" in meta["why"]


# --- the setting change that adds or removes one model ---

def test_plan_experiential_labs_list():
    assert mb.plan("explabs", "qwen3.8-27b", "gpt-5-mini", True) == ("EXPLABS_MODELS", "qwen3.8-27b,gpt-5-mini")
    assert mb.plan("explabs", "qwen3.8-27b,gpt-5-mini", "gpt-5-mini", False) == ("EXPLABS_MODELS", "qwen3.8-27b")
    assert mb.plan("explabs", "qwen3.8-27b", "gpt-5-mini", False) is None     # not listed: nothing to remove
    # never removed down to nothing (blank means qwen3.8-27b): the last one with last=True is refused
    assert mb.plan("explabs", "qwen3.8-27b", "qwen3.8-27b", False, last=True) is None
    assert mb.plan("explabs", "xl/gpt-5-mini", "gpt-5-mini", True) is None    # already there (xl/ stripped)


def test_plan_openrouter_keeps_its_words():
    # add to a list
    assert mb.plan("openrouter", "a/b", "c/d", True) == ("OPENROUTER_MODELS", "a/b,c/d")
    # blank is "all": adding one already covered changes nothing
    assert mb.plan("openrouter", "", "a/b", True, free=False) is None
    assert mb.plan("openrouter", "all", "a/b", True, free=False) is None
    # remove a model covered by "free": a "-id" exclusion is added, the words kept
    assert mb.plan("openrouter", "free", "x/y", False, free=True) == ("OPENROUTER_MODELS", "free,-x/y")
    # remove one named in a list
    assert mb.plan("openrouter", "a/b,c/d", "a/b", False) == ("OPENROUTER_MODELS", "c/d")
    # re-adding an excluded model drops its "-id"
    assert mb.plan("openrouter", "free,-x/y", "x/y", True, free=True) == ("OPENROUTER_MODELS", "free")
    # a paid model is not covered by "free": adding it appends it
    assert mb.plan("openrouter", "free", "p/q", True, free=False) == ("OPENROUTER_MODELS", "free,p/q")


def test_plan_bedrock_extra_list():
    i = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    assert mb.plan("bedrock", "", i, True) == ("BEDROCK_MODELS", i)
    assert mb.plan("bedrock", i, i, False) == ("BEDROCK_MODELS", "")
    assert mb.plan("bedrock", i, "other.model-v1:0", False) is None
    assert mb.plan("bedrock", f"br/{i}", i, True) is None   # already there (br/ stripped)


# --- the whole answer: built-in vs addable, enabled, chosen ---

def test_browse_builtin_vs_added_and_enabled(tmp_path):
    cat = _catalog(tmp_path)
    d = _mbdir(tmp_path)
    # a probe result so a catalog model is "enabled"
    (tmp_path / "litellm").mkdir(exist_ok=True)
    (tmp_path / "litellm" / "probe-results.tsv").write_text(
        "# name\tkind\tverdict\treason\tprice\tat\nclaude-opus-5-5\tchat\tENABLED\tok\t-\tnow\n", encoding="utf-8")
    # Bedrock's list: the catalog's opus (built in) and one extra model (addable)
    (d / "bedrock.json").write_text(json.dumps({"provider": "bedrock", "status": "ok", "region": "us-east-1", "at": 9e18 and 99999999999, "models": [
        {"id": "us.anthropic.claude-opus-5-5", "model_id": "x", "name": "Claude Opus 5.5", "vendor": "Anthropic", "how": "profile",
         "prices": {"in": 4.0, "out": 20.0}, "context": 1000000, "max_out": 128000, "tools": True, "images": True, "lifecycle": "ACTIVE"},
        {"id": "us.anthropic.claude-haiku-4-5-20251001-v1:0", "model_id": "y", "name": "Claude Haiku 4.5", "vendor": "Anthropic",
         "how": "profile", "prices": {"in": 0.8, "out": 4.0}, "context": 200000, "max_out": 8192, "tools": True, "images": True, "lifecycle": "ACTIVE"},
    ]}), encoding="utf-8")
    # the Code page's served models (code-models.tsv): opus is in the pickers
    (tmp_path / "litellm" / "code-models.tsv").write_text(
        "# id\tname\tprovider\tvendor\tin\tout\tcache_read\tcache_write\tfree\tcompat\tlisted\tdefault\tmax_out\tcontext\tnote\n"
        "claude-opus-5-5\tClaude Opus 5.5\tBedrock\tAnthropic\t4\t20\t-\t-\t0\tworks\t1\t1\t-\t-\t-\n", encoding="utf-8")
    code_rows, _ = _read_code(tmp_path)
    values = {"BEDROCK_MODELS": "us.anthropic.claude-haiku-4-5-20251001-v1:0", "OPENROUTER_MODELS": "", "EXPLABS_MODELS": ""}
    keys_on = {"bedrock": True, "openrouter": False, "explabs": False}
    data = mb.browse(tmp_path, cat, tmp_path / "litellm", values, keys_on, [], {"at": None, "error": None}, code_rows)
    br = {r["source_id"]: r for r in data["bedrock"]["rows"]}
    # the catalog's opus: built in, enabled, not add/removable
    opus = br["us.anthropic.claude-opus-5-5"]
    assert opus["builtin"] is True and opus["enabled"] is True and opus["can"] == "none" and opus["id"] == "claude-opus-5-5"
    # the extra model: chosen (BEDROCK_MODELS names it), removable, its id the raw bedrock id
    haiku = br["us.anthropic.claude-haiku-4-5-20251001-v1:0"]
    assert haiku["builtin"] is False and haiku["chosen"] is True and haiku["can"] == "remove"
    assert haiku["id"] == "us.anthropic.claude-haiku-4-5-20251001-v1:0" and haiku["in"] == 0.8
    assert data["bedrock"]["region"] == "us-east-1"
    # OpenRouter and Experiential Labs are off: their rows need a key (none addable)
    assert data["openrouter"]["on"] is False and data["explabs"]["on"] is False


def _read_code(tmp_path):
    from portal import code
    return code.read_code_models(tmp_path / "litellm")


def test_browse_openrouter_add_and_remove(tmp_path):
    cat = _catalog(tmp_path)
    (tmp_path / "litellm").mkdir(exist_ok=True)
    (tmp_path / "litellm" / "code-models.tsv").write_text(
        "# id\tname\tprovider\tvendor\tin\tout\tcache_read\tcache_write\tfree\tcompat\tlisted\tdefault\tmax_out\tcontext\tnote\n"
        "or/a/b\tB\tOpenRouter\tA\t1\t2\t-\t-\t0\tuntested\t1\t0\t-\t-\t-\n", encoding="utf-8")
    code_rows, _ = _read_code(tmp_path)
    or_rows = [
        {"provider": "openrouter", "id": "or/a/b", "source_id": "a/b", "name": "B", "vendor": "A", "free": False,
         "in": 1.0, "out": 2.0, "context": 1000, "tools": True, "images": False, "lifecycle": "", "note": ""},
        {"provider": "openrouter", "id": "or/c/d", "source_id": "c/d", "name": "D", "vendor": "C", "free": True,
         "in": 0.0, "out": 0.0, "context": 2000, "tools": False, "images": False, "lifecycle": "", "note": ""},
    ]
    values = {"OPENROUTER_MODELS": "a/b", "BEDROCK_MODELS": "", "EXPLABS_MODELS": ""}
    keys_on = {"bedrock": False, "openrouter": True, "explabs": False}
    data = mb.browse(tmp_path, cat, tmp_path / "litellm", values, keys_on, or_rows, {"at": 5, "error": None}, code_rows)
    by = {r["source_id"]: r for r in data["openrouter"]["rows"]}
    assert by["a/b"]["chosen"] is True and by["a/b"]["enabled"] is True and by["a/b"]["can"] == "remove"
    assert by["c/d"]["chosen"] is False and by["c/d"]["can"] == "add" and by["c/d"]["free"] is True


# --- Try it ---

def test_try_estimate_caps_and_flags_expensive():
    cheap = mb.try_estimate({"in": 0.8, "out": 4.0, "id": "claude-haiku", "free": False})
    assert cheap["max_tokens"] == mb.TRY_MAX_TOKENS and cheap["usd"] is not None and cheap["expensive"] is False
    opus = mb.try_estimate({"in": 15.0, "out": 75.0, "id": "claude-opus-5-5", "free": False})
    assert opus["expensive"] is True                                  # Opus is never cheap-by-default
    dear = mb.try_estimate({"in": 1.0, "out": 40.0, "id": "x", "free": False})
    assert dear["expensive"] is True                                  # >$10/1M output
    free = mb.try_estimate({"in": 0.0, "out": 0.0, "id": "f:free", "free": True})
    assert free["usd"] == 0.0 and free["expensive"] is False
    unknown = mb.try_estimate({"in": None, "out": None, "id": "z", "free": False})
    assert unknown["usd"] is None and unknown["expensive"] is True    # unknown price: treat as needing confirmation


def _tried(headers: dict) -> dict:
    body = {"choices": [{"message": {"content": "Hello there"}}]}
    t = httpx.MockTransport(lambda req: httpx.Response(200, json=body, headers=headers))

    async def go():
        async with httpx.AsyncClient(transport=t) as c:
            return await mb.try_model(c, "http://litellm:4000", "sk-x", "lm/tiny")
    return asyncio.run(go())


def test_try_says_what_litellm_booked_and_a_free_model_is_0():
    assert _tried({"x-litellm-response-cost": "1.3e-05", "x-litellm-response-cost-original": "1.3e-05"})["cost"] == 1.3e-05
    # LiteLLM 1.106 leaves its cost header out at $0; the -original one says a cost was worked out
    assert _tried({"x-litellm-response-cost-original": "0.0"})["cost"] == 0.0
    assert _tried({})["cost"] is None   # no cost worked out: unknown, never $0


def test_missing_text_matches_the_shell_wording():
    # (a sanity check that the browser's providers map is the three it serves)
    assert set(mb.SETTING) == {"bedrock", "openrouter", "explabs"}
    assert mb.PROVIDER["explabs"] == "Experiential Labs"
