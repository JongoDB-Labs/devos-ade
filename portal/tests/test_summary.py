import json
import time

import anyio
import httpx
import respx

from portal import summary

PROBE = (
    "# name\tkind\tverdict\treason\tprice\tchecked_at\n"
    "claude-haiku-5-5\tchat\tENABLED\tok\t$0.11/$0.55 /1M\t2026-10-12T18:55:43Z\n"
    "cohere-embed-v4\tembed\tDISABLED\tnot subscribed in this AWS account (AWS Marketplace) — ask\t$0.12 /1M\t2026-10-12T18:55:43Z\n"
    "broken\tline\n"
)


def test_reason_code_mirrors_bash():
    assert summary.reason_code("ok") == "ok"
    assert summary.reason_code("not subscribed in this AWS account") == "no Marketplace access"
    assert summary.reason_code("not available in us-west-2") == "not in region"
    assert summary.reason_code("unverified (aws exit 254): x") == "unverified: aws exit 254"
    assert summary.reason_code("unverified: LiteLLM HTTP 500") == "unverified: HTTP 500"
    assert summary.reason_code("something else") == "unverified"


def test_read_models(settings):
    assert summary.read_models(settings.litellm_dir)["error"].startswith("no model check yet")
    (settings.litellm_dir / "probe-results.tsv").write_text(PROBE)
    m = summary.read_models(settings.litellm_dir)
    assert m["checked_at"] == "2026-10-12T18:55:43Z"
    assert [r["name"] for r in m["rows"]] == ["claude-haiku-5-5", "cohere-embed-v4"]
    assert m["rows"][1]["why"] == "no Marketplace access" and not m["rows"][1]["enabled"]


def test_read_models_adds_friendly_names_and_tiers(settings):
    (settings.litellm_dir / "probe-results.tsv").write_text(PROBE)
    (settings.catalog_dir / "display.tsv").write_text(
        "# name\tdisplay_name\ticon\ttags\nclaude-haiku-5-5\tClaude Haiku 5.5\tanthropic\tAnthropic\n")
    (settings.catalog_dir / "prices.tsv").write_text(
        "# as_of: 2026-10-12\nclaude-haiku-5-5\t0.11\t0.55\t-\t-\t-\t-\ncohere-embed-v4\t0.12\t-\t-\t-\t-\t-\n")
    rows = summary.read_models(settings.litellm_dir, settings.catalog_dir)["rows"]
    assert (rows[0]["display"], rows[0]["tier"]) == ("Claude Haiku 5.5", "$")
    assert (rows[1]["display"], rows[1]["tier"]) == ("cohere-embed-v4", "")   # no row; tiers only for chat
    assert summary.tier(0.5) == "$$" and summary.tier(3.0) == "$$$" and summary.tier(None) == ""


def test_models_show_the_prices_in_use(settings):
    from datetime import date
    (settings.litellm_dir / "probe-results.tsv").write_text(PROBE)
    (settings.catalog_dir / "prices.tsv").write_text("# as_of: 2026-10-01\nclaude-haiku-5-5\t0.11\t0.55\t-\t-\t-\t-\n")
    settings.prices_dir.mkdir()
    (settings.prices_dir / "prices.auto.tsv").write_text(
        "# as_of: 2026-10-12\n# version: abc\nclaude-haiku-5-5\t3.3\t16.5\t-\t-\t-\t-\n")
    prices = summary.price_update.effective_prices(summary.price_paths(settings), date(2026, 10, 13))
    rows = summary.read_models(settings.litellm_dir, settings.catalog_dir, prices)["rows"]
    assert rows[0]["price"] == "$3.30/$16.50 /1M" and rows[0]["tier"] == "$$$"   # the daily update, not the probe's
    assert rows[1]["price"] == "$0.12 /1M"                                         # no price row: the saved one


def test_prices_fall_back_to_catalog(settings):
    (settings.catalog_dir / "prices.tsv").write_text("# comment\n# as_of: 2026-10-12\nx\t1\n")
    p = summary.price_update.status(summary.price_paths(settings), enabled=False)
    assert p["source"] == "catalog" and p["as_of"] == "2026-10-12" and p["updates_enabled"] is False


@respx.mock
def test_build_aggregates_upstreams(settings):
    respx.get("http://litellm:4000/health/readiness").respond(200, json={"status": "healthy", "db": "connected"})
    respx.get("http://open-webui:8080/health").respond(200, json={"status": True})
    respx.get("http://rustfs:9000/health").respond(503)
    respx.get("http://shared-mcp:8000/healthz").respond(200, text="ok")

    def key_info(request):
        key = request.headers["authorization"].removeprefix("Bearer ")
        assert "key=" not in str(request.url)  # never in the URL (LiteLLM logs URLs)
        if key == "sk-cc":
            return httpx.Response(200, json={"info": {"spend": 170.5, "max_budget": 200.0, "budget_reset_at": "2026-11-03T00:00:00Z"}})
        return httpx.Response(401, json={"error": "bad key"})

    respx.get("http://litellm:4000/key/info").mock(side_effect=key_info)
    glob = respx.get("http://litellm:4000/global/spend").respond(200, json={"spend": 171.25, "max_budget": 0.0})
    (settings.litellm_dir / "probe-results.tsv").write_text(PROBE)

    async def run():
        async with httpx.AsyncClient() as c:
            return await summary.build(c, settings)

    d = anyio.run(run)
    assert glob.calls.last.request.headers["authorization"] == "Bearer sk-master"
    svc = {s["id"]: s for s in d["services"]}
    assert svc["litellm"]["ok"] and svc["postgres"]["ok"] and svc["open-webui"]["ok"] and svc["shared-mcp"]["ok"]
    assert not svc["rustfs"]["ok"] and svc["rustfs"]["detail"] == "HTTP 503"
    keys = {k["alias"]: k for k in d["spend"]["keys"]}
    assert keys["claude-code"]["spend"] == 170.5 and keys["claude-code"]["max_budget"] == 200.0
    assert keys["claude-code"]["reset_at"] == "2026-11-03T00:00:00Z"
    assert keys["open-webui"]["error"] == "LiteLLM answered HTTP 401"
    assert keys["setup"]["error"].startswith("no key yet")
    assert d["spend"]["total_30d"] == 171.25
    assert len(d["models"]["rows"]) == 2
    assert d["prices"]["source"] == "catalog" and d["prices"]["warnings"] == []
    assert "sk-" not in str(d)


@respx.mock
def test_null_global_spend_is_zero(settings):
    respx.get("http://litellm:4000/global/spend").respond(200, json={"spend": None})
    respx.get(url__regex=r".*").respond(503)

    async def run():
        async with httpx.AsyncClient() as c:
            return await summary.spend(c, settings)

    assert anyio.run(run)["total_30d"] == 0.0


def test_voice_off_is_browser_speech(settings):
    v = summary.voice(settings, {})
    assert v["on"] is False and v["provider"] == "browser"


def test_voice_bedrock_shows_an_estimated_price_per_minute(settings):
    from dataclasses import replace
    from decimal import Decimal
    s = replace(settings, stt_engine="openai", stt_provider="bedrock", stt_model="voxtral-small")
    v = summary.voice(s, {"voxtral-small": {"in": Decimal("0.10"), "out": Decimal("0.30")}})
    assert v["on"] and v["label"] == "Bedrock Mistral Voxtral Small" and v["estimated"]
    assert abs(v["per_minute"] - 0.000135) < 1e-9          # 750 in + 200 out tokens per minute, like lib/stt.sh
    assert v["where"] == "your AWS account"
    # not in the prices in use (an automatic file from before Voxtral): the catalog's price, like ./stack
    (settings.catalog_dir / "prices.tsv").write_text("# as_of: 2026-10-12\nvoxtral-small\t0.10\t0.30\t-\t-\t-\t-\n")
    assert abs(summary.voice(s, {"other": {}})["per_minute"] - 0.000135) < 1e-9
    (settings.catalog_dir / "prices.tsv").write_text("# as_of: 2026-10-12\n")
    assert summary.voice(s, {})["per_minute"] is None
    # a configured provider whose engine is not on (e.g. Voxtral not usable) is still browser speech
    assert summary.voice(replace(s, stt_engine="web"), {})["on"] is False
    o = summary.voice(replace(s, stt_provider="openai", stt_model="gpt-4o-mini-transcribe"), {})
    assert o["label"] == "OpenAI gpt-4o-mini-transcribe" and o["where"] == "api.openai.com" and o["per_minute"] is None


def test_voice_says_why_when_aws_refuses_voxtrals_audio(settings, tmp_path):
    # (lib/stt.sh: since October 2026; the notice ./stack recorded, and the model check's "no audio:" reasons)
    from dataclasses import replace
    import json
    st = tmp_path / "status"; st.mkdir()
    s = replace(settings, status_dir=st)
    v = summary.voice(s, {})
    assert "notice" not in v and v["bedrock_refused"] is False
    (settings.litellm_dir / "probe-results.tsv").write_text(
        "# name\tkind\tverdict\treason\tprice\tchecked_at\nbig\tchat\tENABLED\tok\t-\tT\n"
        "voxtral-small\tstt\tENABLED\tno audio: Bedrock no longer accepts audio for this model (AWS: Model does not support audio modality)\t-\tT\n"
        "voxtral-mini\tstt\tENABLED\tno audio: Bedrock no longer accepts audio for this model (AWS: x)\t-\tT\n")
    assert summary.voice(s, {})["bedrock_refused"] is True
    assert summary.reason_code("no audio: Bedrock no longer accepts audio for this model") == "no audio (AWS)"
    (st / "stt-notice.json").write_text(json.dumps({"at": 1792700000, "reason": "audio-refused"}))
    v = summary.voice(s, {})
    assert v["notice"] == ("Bedrock speech-to-text was turned off: AWS no longer accepts audio for the Voxtral models (since "
                           "October 2026). Voice uses your browser's speech recognition; or use your own OpenAI/Groq key: "
                           "./stack stt set openai|groq.")
    assert summary.stt_notice(s) == 1792700000
    # anything odd in the file: no notice; and none once a server speech-to-text is on again
    for bad in ({"at": "1", "reason": "audio-refused"}, {"at": 1, "reason": "other"}, {"at": True, "reason": "audio-refused"}, []):
        (st / "stt-notice.json").write_text(json.dumps(bad))
        assert "notice" not in summary.voice(s, {})
    (st / "stt-notice.json").write_text(json.dumps({"at": 1792700000, "reason": "audio-refused"}))
    assert "notice" not in summary.voice(replace(s, stt_engine="openai", stt_provider="openai", stt_model="gpt-4o-mini-transcribe"), {})
    # one model still takes audio: not refused as a whole
    (settings.litellm_dir / "probe-results.tsv").write_text("voxtral-small\tstt\tENABLED\tok\t-\tT\nvoxtral-mini\tstt\tENABLED\tno audio: x\t-\tT\n")
    assert summary.voice(s, {})["bedrock_refused"] is False


@respx.mock
def test_services_include_the_stt_container_with_bedrock(settings):
    from dataclasses import replace
    for url, code in (("http://litellm:4000/health/readiness", 200), ("http://open-webui:8080/health", 200),
                      ("http://rustfs:9000/health", 200), ("http://shared-mcp:8000/healthz", 200)):
        respx.get(url).respond(code, json={"db": "connected"})
    respx.get("http://caddy:8090/healthz").respond(200, json={"ok": True})
    s = replace(settings, stt_engine="openai", stt_provider="bedrock")

    async def run(st):
        async with httpx.AsyncClient() as c:
            return await summary.services(c, st)

    ids = [x["id"] for x in anyio.run(run, s)]
    assert ids[-1] == "stt"
    assert "stt" not in [x["id"] for x in anyio.run(run, settings)]


def _services_json(status, rows, at):
    status.mkdir(exist_ok=True)
    (status / "services.json").write_text(json.dumps({"version": 1, "written_at": at, "services": rows}))


@respx.mock
def test_services_include_the_built_in_searxng_from_stacks_record(settings, tmp_path):
    # Home's Services: the built-in SearXNG's state and health as ./stack recorded them (services.json: the portal has no
    # way to it), listed after the others while the record has it — WEBSEARCH_SEARXNG_BUILTIN=off: no row at all
    from dataclasses import replace
    for url in ("http://litellm:4000/health/readiness", "http://open-webui:8080/health", "http://rustfs:9000/health",
                "http://shared-mcp:8000/healthz"):
        respx.get(url).respond(200, json={"db": "connected"})
    s = replace(settings, status_dir=tmp_path / "status")
    now = int(time.time())

    async def run(st):
        async with httpx.AsyncClient() as c:
            return await summary.services(c, st)

    assert "searxng" not in [x["id"] for x in anyio.run(run, s)]   # no record yet
    base = [{"service": "litellm", "state": "running", "health": "healthy"}]
    _services_json(s.status_dir, base, now)   # off: ./stack lists no searxng
    assert [x["id"] for x in anyio.run(run, s)] == ["litellm", "postgres", "open-webui", "rustfs", "shared-mcp"]
    _services_json(s.status_dir, base + [{"service": "searxng", "state": "running", "health": "healthy"}], now - 20)
    row = anyio.run(run, s)[-1]
    assert row == {"id": "searxng", "name": "SearXNG", "role": "web search (built-in)", "ok": True, "detail": "ready"}
    # down, in Docker's words: unhealthy, starting, exited, not created
    for state, health, detail in (("running", "unhealthy", "unhealthy"), ("running", "starting", "starting"),
                                  ("exited", "", "exited"), ("not created", "", "not created"), ("restarting", "", "restarting")):
        _services_json(s.status_dir, [{"service": "searxng", "state": state, "health": health}], now)
        assert (summary.searxng(s, now)["ok"], summary.searxng(s, now)["detail"]) == (False, detail), (state, health)
    # a record nobody rewrote for a while (no update helper) says how old it is
    _services_json(s.status_dir, [{"service": "searxng", "state": "running", "health": "healthy"}], now - 3 * 3600)
    assert summary.searxng(s, now) == {"id": "searxng", "name": "SearXNG", "role": "web search (built-in)", "ok": True,
                                       "detail": "ready (checked 3 h ago)"}
    assert summary.searxng(s, now + 400 - 3 * 3600)["detail"] == "ready (checked 6 min ago)"
    # only Docker's own words are shown; anything else is unknown, never the file's text
    _services_json(s.status_dir, [{"service": "searxng", "state": "<b>up</b>", "health": "healthy; rm -rf"}], now)
    assert summary.searxng(s, now)["detail"] == "unknown" and not summary.searxng(s, now)["ok"]
    for bad in ({"version": 1, "services": [{"service": "searxng", "state": "running"}]},   # no written_at
                {"version": 1, "written_at": now, "services": {"searxng": "running"}},
                {"version": 1, "written_at": True, "services": []}):
        (s.status_dir / "services.json").write_text(json.dumps(bad))
        assert summary.searxng(s, now) is None, bad
    (s.status_dir / "services.json").write_text("x" * 20000)   # larger than any record: not read
    assert summary.searxng(s, now) is None


def test_settings_read_voice_from_env():
    from portal.config import from_env
    base = {"PORTAL_PASSWORD": "p", "PORTAL_SECRET": "s" * 40}
    s = from_env({**base, "STT_ENGINE": "openai", "STT_PROVIDER": "bedrock", "STT_MODEL": "whisper-1", "STT_BEDROCK_MODEL": "voxtral-mini"})
    assert (s.stt_engine, s.stt_provider, s.stt_model) == ("openai", "bedrock", "voxtral-mini")
    s = from_env({**base, "STT_PROVIDER": "groq", "STT_MODEL": "whisper-large-v3"})
    assert (s.stt_engine, s.stt_model) == ("web", "whisper-large-v3")
