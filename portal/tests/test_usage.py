"""Equivalent cost view and OpenRouter usage (portal/usage.py) against LiteLLM 1.105.0's response shapes."""

import asyncio
import dataclasses
import json
from datetime import date, datetime, timedelta, timezone

import anyio
import httpx
import pytest
import respx

from portal import openrouter, summary, usage

OR_KEY = "sk-or-v1-secretsecret"
# litellm/openrouter-models.tsv as ./stack writes it (tests/fixtures/openrouter_models.json, classified)
TSV = (
    "# fetched_at: 2026-10-12T00:00:00Z\n"
    "# id\tname\tcontext\tprompt\tcompletion\tcache_read\tcache_write\ttier\tcreated\n"
    "google/gemma-4-31b-it:free\tGoogle: Gemma 4 31B (free)\t262144\t0\t0\t\t\tfree\t1\n"
    "google/gemma-4-31b-it\tGoogle: Gemma 4 31B\t262144\t0.00000009\t0.00000034\t0.00000005\t\tpaid\t1\n"
    "meta-llama/llama-3.3-70b-instruct\tMeta: Llama 3.3 70B Instruct\t131072\t0.00000022\t0.0000005\t0.00000011\t\tpaid\t1\n"
    "inclusionai/ling-3.1-flash\tinclusionAI: Ling 3.1 Flash\t131072\t0\t0\t\t\tfree\t1\n"
    "nvidia/nemotron-3-super-120b-a12b:free\tNVIDIA: Nemotron 3 Super (free)\t262144\t0\t0\t\t\tfree\t1\n"
)
GEMMA = {"in": 0.00000009, "out": 0.00000034, "cache_read": 0.00000005}
HASH = {"sk-cc": usage.key_hash("sk-cc"), "sk-ow": usage.key_hash("sk-ow")}


def metrics(req, tin, tout, spend=0.0, failed=0, cread=0):
    """One metrics object exactly as LiteLLM 1.105.0 sends it (api_requests includes failed ones)."""
    return {"spend": spend, "flat_cost": 0.0, "prompt_tokens": tin, "completion_tokens": tout,
            "cache_read_input_tokens": cread, "cache_creation_input_tokens": 0, "compression_saved_tokens": 0,
            "compression_savings_spend": 0.0, "prompt_caching_savings_spend": 0.0,
            "gateway_injected_caching_savings_spend": 0.0, "autorouter_savings_spend": 0.0,
            "total_tokens": tin + tout, "successful_requests": req, "failed_requests": failed,
            "api_requests": req + failed, "total_response_time_ms": 0, "timed_requests": req}


def group(by_key):
    """A model group: its metrics and api_key_breakdown, from {hash: metrics}."""
    tot = {f: sum(m[f] for m in by_key.values()) for f in next(iter(by_key.values()))}
    return {"metrics": tot, "metadata": {},
            "api_key_breakdown": {h: {"metrics": m, "metadata": {"key_alias": None, "key_exists": True}} for h, m in by_key.items()}}


def day(d, groups):
    return {"date": d.isoformat(), "metrics": metrics(0, 0, 0),
            "breakdown": {"mcp_servers": {}, "models": {}, "model_groups": groups, "providers": {}, "endpoints": {},
                          "api_keys": {}, "entities": {}}}


def activity_body(today):
    """Usage on four days: today, 5 days ago, 20 days ago (before the keys' period), 35 days ago (outside 30 days)."""
    ow, cc = HASH["sk-ow"], HASH["sk-cc"]
    return {"results": [
        day(today, {
            "or/google/gemma-4-31b-it:free": group({ow: metrics(3, 30000, 2000, failed=1), cc: metrics(1, 10000, 1000)}),
            "or/meta-llama/llama-3.3-70b-instruct": group({ow: metrics(2, 1000, 500, spend=0.00047)}),
            "claude-haiku-5-5": group({cc: metrics(9, 9000, 900, spend=0.5)}),   # Bedrock: not OpenRouter
        }),
        day(today - timedelta(days=5), {
            "or/inclusionai/ling-3.1-flash": group({ow: metrics(4, 4000, 400)}),
            "or/google/gemma-4-31b-it:free": group({ow: metrics(1, 1000, 100, cread=500)}),
        }),
        day(today - timedelta(days=20), {"or/google/gemma-4-31b-it:free": group({ow: metrics(10, 100000, 10000)})}),
        day(today - timedelta(days=35), {"or/google/gemma-4-31b-it:free": group({ow: metrics(50, 10**6, 10**5)})}),
    ], "metadata": {"page": 1, "total_pages": 1, "has_more": False}}


def failure(code, cls, msg, group="or/google/gemma-4-31b-it:free", provider="openrouter", at="2026-10-14T10:00:00.000+00:00"):
    return {"model": "openrouter/x", "model_group": group, "status": "failure", "startTime": at, "spend": 0.0,
            "custom_llm_provider": provider, "api_key": "h",
            "metadata": {"status": "failure", "error_information": {
                "traceback": "", "error_code": code, "error_class": cls, "llm_provider": provider, "error_message": msg}}}


FAILURES = {"data": [
    failure("429", "RateLimitError", 'litellm.RateLimitError: OpenrouterException - {"error":{"message":"Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day","code":429}}'),
    failure("429", "RateLimitError", 'OpenrouterException - {"error":{"message":"Rate limit exceeded: free-models-per-day","code":429}}', at="2026-10-14T11:00:00.000+00:00"),
    failure("429", "RateLimitError", "Rate limit exceeded: free-models-per-min."),
    failure("402", "APIError", '{"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/credits","code":402}}',
            group="or/meta-llama/llama-3.3-70b-instruct"),
    failure("404", "NotFoundError", '{"error":{"message":"No endpoints found matching your data policy (Free model publication). Configure: https://openrouter.ai/settings/privacy","code":404}}'),
    failure("401", "AuthenticationError", '{"error":{"message":"User not found.","code":401}}'),
    failure("400", "BudgetExceededError", "Budget has been exceeded! Current cost: 0.05, Max budget: 0.04"),
    failure("500", "APIError", "OpenrouterException - upstream sk-or-v1-abcdef123 broke at arn:aws:iam::123456789012:user/x"),
    failure("403", "PermissionDeniedError", "BedrockException - not authorized", group="cohere-rerank-3-5", provider="bedrock"),
], "total": 9, "page": 1, "page_size": 100, "total_pages": 1, "total_is_capped": False}


def setup_function():
    usage._cache.clear()
    usage._xl_days.clear()
    openrouter._cache.clear()


def run(coro_fn, *args):
    async def go():
        async with httpx.AsyncClient() as c:
            return await coro_fn(c, *args)
    return anyio.run(go)


# --- pure helpers ---


def test_period_start_follows_litellm_reset_schedule():
    # "30d" resets on the 1st of the month (LiteLLM 1.105.0), so the period starts a calendar month earlier
    assert usage.period_start("2026-11-01T00:00:00+00:00", "30d") == date(2026, 10, 1)
    assert usage.period_start("2026-03-01T00:00:00Z", "30d") == date(2026, 2, 1)
    assert usage.period_start("2026-03-31T00:00:00+00:00", "1mo") == date(2026, 2, 28)
    assert usage.period_start("2026-10-19T00:00:00+00:00", "7d") == date(2026, 10, 12)
    assert usage.period_start("2026-10-19T00:00:00+00:00", "2w") == date(2026, 10, 5)
    assert usage.period_start("2026-10-19T00:00:00+00:00", "14d") == date(2026, 10, 5)
    assert usage.period_start("2026-10-19T06:00:00+00:00", "24h") == date(2026, 10, 18)
    for bad in ((None, "30d"), ("2026-11-01", None), ("soon", "30d"), ("2026-11-01T00:00:00Z", "monthly-ish")):
        assert usage.period_start(*bad) is None


def test_catalog_free_and_paid_variants(settings):
    assert usage.read_catalog(settings.litellm_dir) == {}
    (settings.litellm_dir / "openrouter-models.tsv").write_text(TSV)
    cat = usage.read_catalog(settings.litellm_dir)
    assert cat["google/gemma-4-31b-it"] == {"name": "Google: Gemma 4 31B", "in": 0.00000009, "out": 0.00000034,
                                            "cache_read": 0.00000005, "cache_write": None, "free": False}
    assert usage.is_free("google/gemma-4-31b-it:free", cat) and usage.is_free("inclusionai/ling-3.1-flash", cat)
    assert not usage.is_free("meta-llama/llama-3.3-70b-instruct", cat)
    assert usage.is_free("gone/model:free", cat)                    # no longer offered: the id still says free
    assert usage.paid_variant("google/gemma-4-31b-it:free", cat)["in"] == 0.00000009
    assert usage.paid_variant("nvidia/nemotron-3-super-120b-a12b:free", cat) is None   # no paid version offered
    assert usage.paid_variant("inclusionai/ling-3.1-flash", cat) is None               # free, no ":free" twin
    assert usage.paid_variant("meta-llama/llama-3.3-70b-instruct", cat) is None


def test_priced_uses_cache_read_price_and_counts_cached_tokens_once():
    m = {"tokens_in": 1500, "tokens_out": 100, "cache_read": 500, "cache_write": 0}
    assert usage.priced(m, GEMMA) == pytest.approx(1000 * 0.00000009 + 500 * 0.00000005 + 100 * 0.00000034)
    assert usage.priced(m, {"in": 0.000001, "out": 0.000002}) == pytest.approx(1500 * 0.000001 + 100 * 0.000002)


def test_free_tokens_are_priced_at_the_paid_variant(settings):
    (settings.litellm_dir / "openrouter-models.tsv").write_text(TSV)
    today = date(2026, 10, 14)
    rows = usage.parse_activity(activity_body(today))
    assert {r["model"] for r in rows} == {"google/gemma-4-31b-it:free", "meta-llama/llama-3.3-70b-instruct",
                                          "inclusionai/ling-3.1-flash"}   # Bedrock groups left out
    windows = {"claude-code": (HASH["sk-cc"], date(2026, 10, 1)), "open-webui": (HASH["sk-ow"], date(2026, 10, 1))}
    eq, use = usage.summarize(rows, usage.read_catalog(settings.litellm_dir), today, today - timedelta(days=30),
                              windows, 2.0, {"claude-code": 1.5, "open-webui": 0.25})
    g = lambda tin, tout, cr=0: (tin - cr) * GEMMA["in"] + cr * GEMMA["cache_read"] + tout * GEMMA["out"]  # noqa: E731
    # today's open-webui gemma: 3 answered + 1 failed; LiteLLM's 30,000 prompt tokens include the failed one's
    # estimate, so 3/4 of them count for the key; the model's total scales by its own share (4 of 5 answered)
    in_period_ow = g(22500, 2000) + g(1000, 100, 500)
    in_30d = g(32000, 3000) + g(1000, 100, 500) + g(100000, 10000)   # 20 days ago: in 30 days, not in the period
    assert eq["extra_30d"] == pytest.approx(in_30d)
    assert eq["total_30d"] == pytest.approx(2.0 + in_30d)
    ow, cc = eq["keys"]["open-webui"], eq["keys"]["claude-code"]
    assert ow["extra"] == pytest.approx(in_period_ow) and ow["spend"] == pytest.approx(0.25 + in_period_ow)
    assert (ow["free_requests"], ow["free_tokens_in"], ow["free_tokens_out"]) == (3 + 1 + 4, 27500, 2500)  # ling counts, at $0
    assert cc["extra"] == pytest.approx(g(10000, 1000)) and cc["spend"] == pytest.approx(1.5 + g(10000, 1000))
    assert eq["no_paid_variant"] == ["inclusionai/ling-3.1-flash"]
    assert (eq["free_requests_30d"], eq["free_tokens_in_30d"]) == (3 + 1 + 4 + 1 + 10, 137000)
    # OpenRouter usage: today and 30 days, free/paid
    t, d30 = use["today"], use["days_30"]
    assert (t["free"]["requests"], t["free"]["tokens_in"], t["free"]["cost"]) == (4, 32000, 0.0)
    assert t["free"]["equivalent"] == pytest.approx(g(32000, 3000))
    assert (t["paid"]["requests"], t["paid"]["cost"], t["paid"]["equivalent"]) == (2, 0.00047, 0.00047)
    assert d30["free"]["requests"] == 19 and d30["paid"]["requests"] == 2
    assert [(m["id"], m["access"], m["requests"]) for m in use["top"]] == [
        ("or/google/gemma-4-31b-it:free", "free", 15), ("or/inclusionai/ling-3.1-flash", "free", 4),
        ("or/meta-llama/llama-3.3-70b-instruct", "paid", 2)]
    assert use["top"][0]["name"] == "Google: Gemma 4 31B (free)" and use["top"][1]["no_paid_variant"]
    assert use["top"][2]["cost"] == 0.00047


def test_parse_activity_tolerates_garbage_and_older_shapes():
    assert usage.parse_activity(None) == [] and usage.parse_activity([]) == [] and usage.parse_activity({"results": "x"}) == []
    body = {"results": [{"date": "2026-10-14", "breakdown": {"models": {"openrouter/a/b:free": {"metrics": {"api_requests": 2, "prompt_tokens": 5}},
                                                                       "bedrock/x": {"metrics": {}}}}}, None, {"date": 5}]}
    rows = usage.parse_activity(body)   # no model_groups: the deployment names ("openrouter/…")
    assert [(r["model"], r["m"]["requests"], r["m"]["tokens_in"]) for r in rows] == [("a/b:free", 2, 5)]


# Seen live on an install with a free-tier account: the model's provider throttles everyone, not this key.
UPSTREAM_429 = ('litellm.RateLimitError: RateLimitError: OpenrouterException - {"error":{"message":"Provider returned '
                'error","code":429,"metadata":{"raw":"google/gemma-4-31b-it:free is temporarily rate-limited upstream. '
                'Please retry shortly, or add your own key to accumulate your rate limits: '
                'https://openrouter.ai/settings/integrations","provider_name":"Google AI Studio"}},"user_id":"user_2x"}')


def test_upstream_429_is_not_blamed_on_the_user():
    assert usage.classify("429", UPSTREAM_429) == "upstream_busy"
    g = usage.group_failures([{"at": None, "model": "or/google/gemma-4-31b-it:free", "code": "429", "text": UPSTREAM_429}])[0]
    assert g["label"] == "This model is busy upstream (HTTP 429)"
    assert "not you" in g["fix"] and "or/openrouter/free" in g["fix"]
    # order: OpenRouter's own daily limit first, then upstream, then other daily wording, then the key's rate
    assert usage.classify("429", "Rate limit exceeded: free-models-per-day (upstream)") == "daily_limit"
    assert usage.classify("429", "Provider returned error") == "upstream_busy"
    assert usage.classify("429", "daily quota used") == "daily_limit"
    assert usage.classify("429", "Rate limit exceeded: free-models-per-min.") == "rate_limit"
    assert usage.classify("", "model is temporarily rate-limited upstream") == "upstream_busy"
    # the readable text is the provider's raw message, not "Provider returned error"
    assert usage.short_error(UPSTREAM_429).startswith("google/gemma-4-31b-it:free is temporarily rate-limited upstream.")


def test_short_error_masks_secrets_and_reads_python_reprs():
    s = usage.short_error("x AKIAABCDEFGHIJKLMNOP y ASIA0123456789ABCDEF arn:aws:iam::123456789012:user/a "
                          "acct 123456789012 me@example.org Key Hash (Token) =" + "ab" * 32 + " sk-1234abcd")
    for leaked in ("AKIA", "ASIA0123", "123456789012", "me@example.org", "ab" * 32, "sk-1234"):
        assert leaked not in s, leaked
    assert "[AWS key]" in s and "[account]" in s and "[email]" in s and "[hash]" in s and "[key]" in s
    assert usage.short_error("APIError: {'error': {'message': 'Upstream said no', 'code': 500}}") == "Upstream said no"
    assert usage.short_error("{'message': 'Provider returned error', 'metadata': {'raw': 'overloaded'}}") == "overloaded"


def test_failures_are_grouped_with_a_fix():
    rows, more = usage.parse_failures(FAILURES)
    assert len(rows) == 8 and not more   # the Bedrock failure is not OpenRouter's
    groups = {g["kind"]: g for g in usage.group_failures(rows)}
    assert groups["daily_limit"]["count"] == 2 and groups["daily_limit"]["last_at"] == "2026-10-14T11:00:00+00:00"
    assert "UTC day" in groups["daily_limit"]["fix"] and "$10" in groups["daily_limit"]["fix"]
    assert groups["rate_limit"]["count"] == 1
    assert "openrouter.ai/settings/credits" in groups["credits"]["fix"] and "models free" in groups["credits"]["fix"]
    assert groups["credits"]["models"] == ["or/meta-llama/llama-3.3-70b-instruct"]
    assert "openrouter.ai/settings/privacy" in groups["data_policy"]["fix"]
    assert "./stack openrouter apply" in groups["key"]["fix"] and "./stack openrouter set" in groups["key"]["fix"]
    assert "BUDGET_" in groups["budget"]["fix"]
    other = groups["other"]
    assert other["label"] == "HTTP 500" and other["status"] == "500"
    assert "sk-or" not in other["fix"] and "123456789012" not in other["fix"] and "[key]" in other["fix"]
    naive = usage.parse_failures({"data": [failure("500", "E", "x", at="2026-10-14T10:00:00")]})[0][0]
    assert naive["at"] == "2026-10-14T10:00:00+00:00"   # LiteLLM writes UTC
    assert list(usage.group_failures(rows))[0]["kind"] == "daily_limit"   # most frequent first
    _, more = usage.parse_failures({**FAILURES, "total": 500})
    assert more


def test_short_error_reads_the_providers_message():
    assert usage.short_error('litellm.NotFoundError: X - {"error":{"message":"No endpoints found","code":404}}') == "No endpoints found"
    assert usage.short_error("litellm.APIError: plain text") == "plain text"
    assert len(usage.short_error("x" * 500)) == 140


# --- through /api/summary's builder ---


def _mock_litellm(today, act=None, fails=None):
    respx.get("http://litellm:4000/health/readiness").respond(200, json={"db": "connected"})
    respx.get(url__regex=r"http://(open-webui|rustfs|shared-mcp).*").respond(200, json={})
    reset = (today.replace(day=1) + timedelta(days=32)).replace(day=1).isoformat() + "T00:00:00+00:00"
    spends = {"sk-cc": 1.5, "sk-ow": 0.25}

    def key_info(request):
        key = request.headers["authorization"].removeprefix("Bearer ")
        return httpx.Response(200, json={"info": {"spend": spends[key], "max_budget": 10.0, "budget_reset_at": reset,
                                                  "budget_duration": "30d"}})

    respx.get("http://litellm:4000/key/info").mock(side_effect=key_info)
    respx.get("http://litellm:4000/global/spend").respond(200, json={"spend": 2.0})
    a = respx.get("http://litellm:4000/user/daily/activity/aggregated").mock(
        return_value=act if act is not None else httpx.Response(200, json=activity_body(today)))
    f = respx.get("http://litellm:4000/spend/logs/v2").mock(return_value=fails if fails is not None else httpx.Response(200, json=FAILURES))
    respx.get("https://openrouter.ai/api/v1/key").respond(200, json={"data": {"usage": 0, "free_model_daily_requests": {"used": 12, "limit": 50}}})
    respx.get("https://openrouter.ai/api/v1/credits").respond(403)
    return a, f


@respx.mock
def test_summary_has_equivalent_and_openrouter_usage(settings):
    (settings.litellm_dir / "openrouter-models.tsv").write_text(TSV)
    today = datetime.now(timezone.utc).date()
    act, fails = _mock_litellm(today)
    s = dataclasses.replace(settings, openrouter_api_key=OR_KEY)
    d = run(summary.build, s)
    sp = d["spend"]
    keys = {k["alias"]: k for k in sp["keys"]}
    assert keys["claude-code"]["spend"] == 1.5 and keys["claude-code"]["period_start"] == today.replace(day=1).isoformat()
    assert sp["total_30d"] == 2.0   # Actual stays what LiteLLM recorded
    eq = sp["equivalent"]
    assert eq["error"] is None and eq["total_30d"] > 2.0 and eq["extra_30d"] == pytest.approx(eq["total_30d"] - 2.0)
    assert set(eq["keys"]) == {"claude-code", "open-webui"}   # the setup key has none yet
    use = sp["openrouter_usage"]
    assert use["today"]["free"]["requests"] == 4 and use["top"][0]["id"] == "or/google/gemma-4-31b-it:free"
    assert use["failures"]["count"] == 8 and use["failures"]["groups"][0]["kind"] == "daily_limit"
    assert sp["openrouter"]["free_requests"] == {"used": 12.0, "limit": 50.0}
    # one activity request: master key, the earliest window needed (30 days back), never a key in the URL
    req = act.calls.last.request
    assert req.headers["authorization"] == "Bearer sk-master"
    assert req.url.params["start_date"] == (today - timedelta(days=30)).isoformat() and req.url.params["end_date"] == today.isoformat()
    assert fails.calls.last.request.url.params["status_filter"] == "failure"
    for c in (act, fails):
        assert "sk-" not in str(c.calls.last.request.url)
    blob = json.dumps(d)
    assert "sk-" not in blob and OR_KEY not in blob and usage.key_hash("sk-ow") not in blob
    # cached for a minute: the next refresh asks LiteLLM's usage endpoints nothing
    run(summary.build, s)
    assert act.call_count == 1 and fails.call_count == 1


@respx.mock
def test_litellm_usage_error_leaves_actual_intact(settings):
    (settings.litellm_dir / "openrouter-models.tsv").write_text(TSV)
    today = datetime.now(timezone.utc).date()
    _mock_litellm(today, act=httpx.Response(500, json={"error": "db"}), fails=httpx.Response(500))
    d = run(summary.build, dataclasses.replace(settings, openrouter_api_key=OR_KEY))
    sp = d["spend"]
    assert sp["total_30d"] == 2.0 and {k["alias"]: k["spend"] for k in sp["keys"]}["claude-code"] == 1.5
    assert sp["equivalent"]["error"] == "LiteLLM answered HTTP 500" and sp["equivalent"]["total_30d"] is None
    assert sp["openrouter_usage"]["error"] == "LiteLLM answered HTTP 500"
    assert sp["openrouter_usage"]["failures"]["error"] == "LiteLLM answered HTTP 500"


@respx.mock
def test_openrouter_off_means_no_usage_calls_and_no_switch(settings):
    today = datetime.now(timezone.utc).date()
    act, fails = _mock_litellm(today)
    d = run(summary.build, settings)
    assert d["spend"]["equivalent"] is None and d["spend"]["openrouter_usage"] is None
    assert not act.called and not fails.called
    assert d["spend"]["total_30d"] == 2.0


# --- Actual must never break ---


def test_period_start_never_raises():
    assert usage.period_start("2026-11-01T00:00:00Z", "99999999999d") is None        # OverflowError
    assert usage.period_start("2026-11-01T00:00:00Z", "99999999999mo") is None       # year out of range
    assert usage.period_start("0001-01-01T00:00:00Z", "30d") is None
    assert usage.period_start("2026-11-01T00:00:00", "30d") == date(2026, 10, 1)      # naive = UTC


def test_catalog_that_is_not_utf8_is_no_catalog(settings):
    (settings.litellm_dir / "openrouter-models.tsv").write_bytes(b"google/x:free\t\xff\xfe\t1\t0\t0\t\t\tfree\t1\n")
    assert usage.read_catalog(settings.litellm_dir) == {}


def test_parse_activity_with_odd_key_breakdowns():
    body = {"results": [{"date": "2026-10-14", "breakdown": {"model_groups": {"or/a/b:free": {
        "metrics": {"api_requests": 2, "prompt_tokens": 10},
        "api_key_breakdown": {"h1": ["x"], "h2": "y", "h3": None, "h4": {"metrics": {"api_requests": 1}}}}}}}]}
    keys = usage.parse_activity(body)[0]["keys"]
    assert keys["h1"]["requests"] == 0 and keys["h2"]["requests"] == 0 and keys["h4"]["requests"] == 1


def test_failed_requests_prompt_tokens_are_left_out_proportionally():
    m = usage._metrics({"api_requests": 10, "failed_requests": 8, "prompt_tokens": 1000, "completion_tokens": 50,
                        "cache_read_input_tokens": 100})
    assert (m["requests"], m["failed"], m["tokens_in"], m["tokens_out"], m["cache_read"]) == (2, 8, 200, 50, 20)
    assert usage._metrics({"api_requests": 3, "failed_requests": 3, "prompt_tokens": 90})["tokens_in"] == 0
    assert usage._metrics({"api_requests": 1, "failed_requests": 5, "prompt_tokens": 9})["requests"] == 0


@respx.mock
def test_a_crash_in_the_usage_views_leaves_actual_intact(settings, monkeypatch):
    (settings.litellm_dir / "openrouter-models.tsv").write_text(TSV)
    today = datetime.now(timezone.utc).date()
    _mock_litellm(today)

    def boom(*a, **k):
        raise KeyError("surprise")

    monkeypatch.setattr(usage, "summarize", boom)
    d = run(summary.build, dataclasses.replace(settings, openrouter_api_key=OR_KEY))
    sp = d["spend"]
    assert sp["total_30d"] == 2.0 and {k["alias"]: k["spend"] for k in sp["keys"]}["claude-code"] == 1.5
    assert sp["equivalent"]["error"] == "usage view failed (KeyError)" and sp["equivalent"]["total_30d"] is None
    assert sp["openrouter_usage"]["error"] == "usage view failed (KeyError)"
    assert sp["openrouter_usage"]["failures"]["error"] == "usage view failed (KeyError)"


@respx.mock
def test_a_garbage_budget_duration_keeps_the_key_row(settings):
    respx.get("http://litellm:4000/key/info").respond(200, json={"info": {
        "spend": 1.0, "max_budget": 5.0, "budget_reset_at": "2026-11-01T00:00:00Z", "budget_duration": "99999999999999d"}})
    respx.get("http://litellm:4000/global/spend").respond(200, json={"spend": 1.0})
    sp = run(summary.spend, settings)
    row = {k["alias"]: k for k in sp["keys"]}["claude-code"]
    assert row["spend"] == 1.0 and row["error"] is None and row["period_start"] is None


@respx.mock
def test_timeouts_and_errors_are_not_cached():
    route = respx.get("http://litellm:4000/user/daily/activity/aggregated")
    route.side_effect = [httpx.ReadTimeout("slow"), httpx.Response(500), httpx.Response(200, json={"results": []})]
    d0 = date(2026, 10, 1)
    args = ("http://litellm:4000", "sk-master", d0, d0)
    assert run(usage.activity, *args, 100.0) == (None, "LiteLLM did not answer (ReadTimeout)")
    assert run(usage.activity, *args, 101.0) == (None, "LiteLLM answered HTTP 500")
    assert run(usage.activity, *args, 102.0) == ([], None)
    assert run(usage.activity, *args, 103.0) == ([], None)          # now cached
    assert route.call_count == 3
    route.side_effect = None
    route.return_value = httpx.Response(200, json={"results": []})
    run(usage.activity, "http://litellm:4000", "sk-master", d0 - timedelta(days=1), d0, 104.0)   # another window
    assert route.call_count == 4


@respx.mock
def test_concurrent_refreshes_share_one_request():
    route = respx.get("http://litellm:4000/user/daily/activity/aggregated").respond(200, json={"results": []})
    fails = respx.get("http://litellm:4000/spend/logs/v2").respond(200, json={"data": [], "total": 0})
    d0, now = date(2026, 10, 1), datetime(2026, 10, 1, tzinfo=timezone.utc)

    async def go():
        async with httpx.AsyncClient() as c:
            await asyncio.gather(*(usage.activity(c, "http://litellm:4000", "m", d0, d0, 50.0) for _ in range(5)),
                                 *(usage.failures(c, "http://litellm:4000", "m", now, 50.0) for _ in range(5)))
    anyio.run(go)
    assert route.call_count == 1 and fails.call_count == 1
    q = fails.calls.last.request.url.params
    assert q["page_size"] == "300" and q["exclude_internal_health_checks"] == "true"


@respx.mock
def test_concurrent_refreshes_share_one_failed_request():
    # LiteLLM failing (or hanging): five tabs wait for one request per kind, not five in a row
    route = respx.get("http://litellm:4000/user/daily/activity/aggregated").respond(500)
    fails = respx.get("http://litellm:4000/spend/logs/v2").respond(500)
    d0, now = date(2026, 10, 1), datetime(2026, 10, 1, tzinfo=timezone.utc)

    async def go():
        async with httpx.AsyncClient() as c:
            return await asyncio.gather(
                *(usage.activity(c, "http://litellm:4000", "m", d0, d0, 50.0) for _ in range(5)),
                *(usage.failures(c, "http://litellm:4000", "m", now, 50.0) for _ in range(5)))
    out = anyio.run(go)
    assert route.call_count == 1 and fails.call_count == 1
    assert all(o == (None, "LiteLLM answered HTTP 500") for o in out[:5])
    assert all(o["error"] == "LiteLLM answered HTTP 500" for o in out[5:])
    run(usage.activity, "http://litellm:4000", "m", d0, d0, 51.0)   # the error was not kept: the next refresh asks
    assert route.call_count == 2 and all(not v for v in usage._inflight.values())


# --- Experiential Labs: free tiers and $0 calls in Equivalent ---

# litellm/explabs-models.json as ./stack writes it (lib/explabs.sh): GLM 5.3 Uncensored's free tier with its model's
# prices (the owner's, 2026-10-25), a priced model, and one whose calls run on your own provider key
GLM = {"in": 1.4e-06, "out": 4.4e-06, "cache_read": 2.6e-07}
QWEN = {"in": 3.2e-07, "out": 2.4e-06, "cache_read": 4e-08}
XL_DOC = {"fetched_at": "2026-10-25T20:00:17Z", "details": True, "error": None, "models": [
    {"id": "xl/glm-5.3-uncensored:free", "name": "glm-5.3-uncensored:free", "vendor": "Z.ai", "prompt": 0, "completion": 0,
     "context_length": 1048576, "free": True, "failsafe": False,
     "paid": {"prompt": GLM["in"], "completion": GLM["out"], "cache_read": GLM["cache_read"], "cache_write": None}},
    {"id": "xl/qwen3.8-27b", "name": "qwen3.8-27b", "vendor": "Qwen", "prompt": QWEN["in"], "completion": QWEN["out"],
     "context_length": 1000000, "free": False, "failsafe": False,
     "paid": {"prompt": QWEN["in"], "completion": QWEN["out"], "cache_read": QWEN["cache_read"], "cache_write": None}},
    {"id": "xl/gpt-5-mini", "name": "gpt-5-mini", "vendor": "OpenAI", "prompt": 2.5e-07, "completion": 2e-06,
     "context_length": None, "free": False, "failsafe": False,
     "paid": {"prompt": 2.5e-07, "completion": 2e-06, "cache_read": None, "cache_write": None}},
    {"id": "xl/no-price:free", "name": "no-price:free", "vendor": "", "prompt": 0, "completion": 0,
     "context_length": None, "free": True, "failsafe": True, "paid": None},
]}


def xl_activity(today):
    """Today: the free tier (both keys), qwen at a price; 1 day ago: qwen all $0 (a promotion, mostly), 2 days ago:
    gpt-5-mini all $0 (your own provider key), 3 days ago: qwen all $0 with nothing to tell (no gateway usage); the free
    tier without a paid version; Bedrock as ever."""
    ow, cc = HASH["sk-ow"], HASH["sk-cc"]
    return {"results": [
        day(today, {
            "xl/glm-5.3-uncensored:free": group({ow: metrics(7, 7000, 700), cc: metrics(8, 40000, 400, cread=10000)}),
            "xl/qwen3.8-27b": group({cc: metrics(2, 2000, 200, spend=0.0011)}),
            "claude-haiku-5-5": group({cc: metrics(9, 9000, 900, spend=0.5)}),
        }),
        day(today - timedelta(days=1), {"xl/qwen3.8-27b": group({cc: metrics(4, 4000, 400)})}),
        day(today - timedelta(days=2), {"xl/gpt-5-mini": group({cc: metrics(6, 6000, 600)})}),
        day(today - timedelta(days=3), {"xl/qwen3.8-27b": group({cc: metrics(5, 5000, 500)}),
                                        "xl/no-price:free": group({ow: metrics(2, 200, 20)})}),
    ], "metadata": {"page": 1, "total_pages": 1, "has_more": False}}


def zero_call(byok=False, cost=0.0):
    """One /spend/logs/v2 row of a call booked $0, its usage as the gateway sent it (LiteLLM keeps it whole)."""
    u = {"prompt_tokens": 1000, "completion_tokens": 100, "total_tokens": 1100}
    if byok is not None:
        u["is_byok"] = byok
    if cost is not None:
        u["cost"] = cost
    return {"model": "openai/x", "model_group": "xl/x", "status": "success", "spend": 0.0, "api_key": "h",
            "metadata": {"status": "success", "usage_object": u}}


def _mock_xl(today):
    respx.get("http://litellm:4000/health/readiness").respond(200, json={"db": "connected"})
    respx.get(url__regex=r"http://(open-webui|rustfs|shared-mcp).*").respond(200, json={})
    respx.get("http://litellm:4000/key/info").respond(200, json={"info": {"spend": 1.0, "max_budget": 10.0}})
    respx.get("http://litellm:4000/global/spend").respond(200, json={"spend": 2.0})
    act = respx.get("http://litellm:4000/user/daily/activity/aggregated").respond(200, json=xl_activity(today))
    pages = {"xl/qwen3.8-27b": [zero_call(False)] * 3 + [zero_call(True)],   # 3 promotional, 1 on your own key
             "xl/gpt-5-mini": [zero_call(True)] * 6}

    def logs(request):
        q = request.url.params
        assert q.get("status_filter") == "success", "no failures are read while OpenRouter is off"
        d = q["start_date"][:10]
        rows = pages[q["model_group"]] if d != (today - timedelta(days=3)).isoformat() else [zero_call(None, None)] * 5
        return httpx.Response(200, json={"data": rows, "total": len(rows)})

    return act, respx.get("http://litellm:4000/spend/logs/v2").mock(side_effect=logs)


@respx.mock
def test_experiential_labs_free_tiers_and_promotions_are_priced_and_own_key_calls_are_not(settings):
    (settings.litellm_dir / "explabs-models.json").write_text(json.dumps(XL_DOC))
    today = datetime.now(timezone.utc).date()
    act, logs = _mock_xl(today)
    d = run(summary.build, settings)   # OpenRouter off, Experiential Labs on
    sp = d["spend"]
    # Actual: what LiteLLM booked, untouched — the free tier and the $0 calls stay $0 there
    assert sp["total_30d"] == 2.0 and all(k["spend"] == 1.0 for k in sp["keys"] if not k.get("error"))
    assert sp["openrouter_usage"] is None   # OpenRouter's block stays off
    eq = sp["equivalent"]
    p = lambda pr, tin, tout, cr=0: (tin - cr) * pr["in"] + cr * pr["cache_read"] + tout * pr["out"]  # noqa: E731
    glm = p(GLM, 7000, 700) + p(GLM, 40000, 400, 10000)
    promo = p(QWEN, 4000, 400) * 0.75      # 1 day ago: 3 of the 4 calls read were promotional
    assert eq["error"] is None and eq["extra_30d"] == pytest.approx(glm + promo)
    assert eq["total_30d"] == pytest.approx(2.0 + glm + promo)
    # your own provider key: 6 calls 2 days ago, and 1 of 4 the day before; never priced
    assert eq["byok_requests_30d"] == 6 + 1
    # 3 days ago: $0 calls whose usage does not say why (streamed): $0 in both views, and counted
    assert eq["zero_unknown_requests_30d"] == 5
    assert eq["free_requests_30d"] == 15 + 3 + 2   # the free tier, the promotional share, no-price:free
    assert eq["no_paid_variant"] == ["xl/no-price:free"]
    # by key (no reset date from LiteLLM here: the 30 days); the bar stays actual, the amount adds the extra
    cc, ow = eq["keys"]["claude-code"], eq["keys"]["open-webui"]
    assert ow["extra"] == pytest.approx(p(GLM, 7000, 700)) and ow["spend"] == pytest.approx(1.0 + ow["extra"])
    assert cc["extra"] == pytest.approx(p(GLM, 40000, 400, 10000) + promo)
    assert (cc["free_requests"], ow["free_requests"]) == (8 + 3, 7 + 2)
    # the spend log was asked only for the priced models' all-$0 days, one day and model each, $0 calls only
    asked = sorted((c.request.url.params["model_group"], c.request.url.params["start_date"][:10]) for c in logs.calls)
    assert asked == sorted([("xl/qwen3.8-27b", (today - timedelta(days=1)).isoformat()),
                            ("xl/gpt-5-mini", (today - timedelta(days=2)).isoformat()),
                            ("xl/qwen3.8-27b", (today - timedelta(days=3)).isoformat())])
    q = logs.calls.last.request.url.params
    assert (q["max_spend"], q["page_size"], q["end_date"][11:]) == ("0", str(usage.XL_SAMPLE), "23:59:59")
    assert all(c.request.headers["authorization"] == "Bearer sk-master" for c in logs.calls)
    # past days are read once: a minute on, the activity is asked again and the spend log is not
    usage._cache.clear()
    run(summary.build, settings)
    assert act.call_count == 2 and logs.call_count == 3


def test_zero_days_are_the_priced_models_days_booked_entirely_at_zero():
    today = date(2026, 10, 25)
    rows = usage.parse_activity(xl_activity(today))
    assert {(r["src"], r["model"]) for r in rows} == {("xl", "glm-5.3-uncensored:free"), ("xl", "qwen3.8-27b"),
                                                      ("xl", "gpt-5-mini"), ("xl", "no-price:free")}
    xl = {m["id"][3:]: {"free": m["free"], "paid": {"in": 1} if m["paid"] else None} for m in XL_DOC["models"]}
    assert usage.zero_days(rows, xl) == [("gpt-5-mini", "2026-10-23"), ("qwen3.8-27b", "2026-10-22"),
                                         ("qwen3.8-27b", "2026-10-24")]
    # a model without a list price, or no longer chosen: nothing to price it at, nothing read
    assert usage.zero_days(rows, {}) == []
    assert usage.zero_days(rows, {"gpt-5-mini": {"free": False, "paid": None}}) == []
    # OpenRouter rows never
    assert usage.zero_days([{**r, "src": "or"} for r in rows], xl) == []


def test_zero_calls_say_own_key_or_promotion_or_nothing():
    assert usage.parse_zero_calls(None) is None and usage.parse_zero_calls({"data": "x"}) is None
    assert usage.parse_zero_calls({"data": [None, "x"]}) is None
    assert usage.parse_zero_calls({"data": [zero_call(True), zero_call(True, None), zero_call(False)]}) == \
        {"byok": 2 / 3, "promo": 1 / 3, "unknown": 0.0}
    # a promotion needs both: is_byok false and a cost the gateway reported as 0. A streamed answer's usage has the cost
    # without is_byok (LiteLLM drops it): it could be your own key's, so it says nothing; nor does a cost above 0
    assert usage.parse_zero_calls({"data": [zero_call(None, 0), zero_call(False, None), zero_call(False, 0.002),
                                            zero_call(False, True), {"metadata": "x"}]}) == \
        {"byok": 0.0, "promo": 0.0, "unknown": 1.0}


@respx.mock
def test_a_spend_log_that_does_not_answer_leaves_those_calls_at_zero_and_is_asked_again(settings):
    (settings.litellm_dir / "explabs-models.json").write_text(json.dumps(XL_DOC))
    today = datetime.now(timezone.utc).date()
    _mock_xl(today)
    logs = respx.get("http://litellm:4000/spend/logs/v2").respond(500)
    eq = run(summary.build, settings)["spend"]["equivalent"]
    glm = (7000 * GLM["in"] + 700 * GLM["out"]) + (30000 * GLM["in"] + 10000 * GLM["cache_read"] + 400 * GLM["out"])
    assert eq["error"] is None and eq["extra_30d"] == pytest.approx(glm) and eq["byok_requests_30d"] == 0
    usage._cache.clear()
    run(summary.build, settings)
    assert logs.call_count == 6   # 3 days, asked again


@respx.mock
def test_experiential_labs_on_alone_and_litellm_down_says_why(settings):
    (settings.litellm_dir / "explabs-models.json").write_text(json.dumps(XL_DOC))
    today = datetime.now(timezone.utc).date()
    _mock_litellm(today, act=httpx.Response(500))
    sp = run(summary.build, settings)["spend"]
    assert sp["equivalent"]["error"] == "LiteLLM answered HTTP 500" and sp["openrouter_usage"] is None
    assert sp["total_30d"] == 2.0


def test_openrouter_rows_are_unchanged_by_experiential_labs_ones(settings):
    (settings.litellm_dir / "openrouter-models.tsv").write_text(TSV)
    today = date(2026, 10, 14)
    body = activity_body(today)
    body["results"][0]["breakdown"]["model_groups"].update(xl_activity(today)["results"][0]["breakdown"]["model_groups"])
    cat = usage.read_catalog(settings.litellm_dir)
    windows = {"open-webui": (HASH["sk-ow"], date(2026, 10, 1))}
    eq0, use0 = usage.summarize(usage.parse_activity(activity_body(today)), cat, today, today - timedelta(days=30), windows, 2.0, {"open-webui": 0.25})
    xl = usage.xl_prices(settings.litellm_dir)   # off: None
    assert xl is None
    (settings.litellm_dir / "explabs-models.json").write_text(json.dumps(XL_DOC))
    xl = usage.xl_prices(settings.litellm_dir)
    eq1, use1 = usage.summarize(usage.parse_activity(body), cat, today, today - timedelta(days=30), windows, 2.0, {"open-webui": 0.25}, xl, {})
    assert use1 == use0   # OpenRouter's own block: or/… only
    glm_ow = 7000 * GLM["in"] + 700 * GLM["out"]
    assert eq1["extra_30d"] == pytest.approx(eq0["extra_30d"] + glm_ow + 30000 * GLM["in"] + 10000 * GLM["cache_read"] + 400 * GLM["out"])
    assert eq1["keys"]["open-webui"]["extra"] == pytest.approx(eq0["keys"]["open-webui"]["extra"] + glm_ow)
    assert eq1["no_paid_variant"] == eq0["no_paid_variant"]
