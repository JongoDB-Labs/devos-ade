"""Experiential Labs in the portal (portal/explabs.py): its models from litellm/explabs-models.json (./stack writes it
whenever it renders LiteLLM's config: lib/explabs.sh) on Home, in Chat's Who answers and on the Code page; a call on
your own provider key shown as that provider's. The portal never holds the gateway's key."""

import json

from portal import answers, code, explabs, summary
from portal.config import from_env

DOC = {"fetched_at": "2026-10-24T00:00:00Z", "details": True, "error": None, "models": [
    {"id": "xl/qwen3.8-27b", "name": "qwen3.8-27b", "vendor": "Qwen", "prompt": 3.2e-07, "completion": 2.4e-06,
     "context_length": 1000000, "free": False, "failsafe": False},
    {"id": "xl/deepseek-v4.1-flash:free", "name": "deepseek-v4.1-flash:free", "vendor": "DeepSeek", "prompt": 0,
     "completion": 0, "context_length": None, "free": True, "failsafe": False},
    {"id": "xl/gpt-latest", "name": "gpt-latest", "vendor": "OpenAI", "prompt": None, "completion": None,
     "context_length": None, "free": False, "failsafe": True},
    {"id": "or/not-ours", "name": "x"}, {"id": "xl/bad id", "name": "x"}, "junk"]}


def _write(settings, doc=DOC):
    (settings.litellm_dir / explabs.FILE).write_text(json.dumps(doc), encoding="utf-8")


def test_the_file_is_read_field_by_field_and_off_without_it(settings):
    assert explabs.read(settings.litellm_dir) is None   # off: no file
    _write(settings)
    d = explabs.read(settings.litellm_dir)
    assert [m["id"] for m in d["models"]] == ["xl/qwen3.8-27b", "xl/deepseek-v4.1-flash:free", "xl/gpt-latest"]
    assert d["details"] is True and d["fetched_at"] == "2026-10-24T00:00:00Z"
    assert d["models"][0] == {"id": "xl/qwen3.8-27b", "name": "qwen3.8-27b", "vendor": "Qwen", "prompt": 3.2e-07,
                              "completion": 2.4e-06, "context": 1000000, "free": False, "failsafe": False}
    for bad in ("not json", json.dumps({"models": "x"}), json.dumps([1]), "x" * (explabs.MAX_FILE + 1)):
        (settings.litellm_dir / explabs.FILE).write_text(bad, encoding="utf-8")
        assert explabs.read(settings.litellm_dir) is None


def test_home_lists_them_with_the_list_price_and_says_which_run_fail_safe(settings):
    _write(settings)
    m = summary.models_with_openrouter(settings)
    rows = {r["name"]: r for r in m["rows"] if r["provider"] == "Experiential Labs"}
    assert list(rows) == ["xl/qwen3.8-27b", "xl/deepseek-v4.1-flash:free", "xl/gpt-latest"]
    assert (rows["xl/qwen3.8-27b"]["price"], rows["xl/qwen3.8-27b"]["access"]) == ("$0.32/$2.40 /1M", "paid")
    assert (rows["xl/deepseek-v4.1-flash:free"]["price"], rows["xl/deepseek-v4.1-flash:free"]["access"]) == ("free", "free")
    assert rows["xl/gpt-latest"]["price"] == "price unknown" and rows["xl/gpt-latest"]["why"] == "ok (fail safe)"
    assert m["explabs"] == {"fetched_at": "2026-10-24T00:00:00Z", "details": True, "error": None, "count": 3, "failsafe": 1}
    # off: no rows, and nothing to say
    (settings.litellm_dir / explabs.FILE).unlink()
    m = summary.models_with_openrouter(settings)
    assert m["explabs"] is None and not [r for r in m["rows"] if r["provider"] == "Experiential Labs"]


def test_who_answers_groups_them_and_greys_the_entry_while_off(settings):
    _write(settings)
    d = answers.build(settings, False, summary.models_with_openrouter(settings))
    assert d["explabs"] is True
    assert [m for m in d["models"] if m["provider"] == "Experiential Labs"][0] == \
        {"id": "xl/qwen3.8-27b", "label": "qwen3.8-27b", "provider": "Experiential Labs"}
    (settings.litellm_dir / explabs.FILE).unlink()
    d = answers.build(settings, False, summary.models_with_openrouter(settings))
    assert d["explabs"] is False and not [m for m in d["models"] if m["provider"] == "Experiential Labs"]
    # off: the greyed entry's words and place come from the setup links (Settings at the key's row), and nothing else
    # of the gateway (the portal never calls it)
    links = d["setup"]
    if links:
        assert links["explabs-off"]["target"] == "setting:EXPLABS_API_KEY"
    d.pop("setup")
    assert "experientiallabs" not in json.dumps(d).lower() and '"xl/' not in json.dumps(d)


def test_the_code_page_lists_them_only_while_it_is_on(settings):
    tsv = ("# scope: all\n"
           "claude-haiku-5-5\tClaude Haiku 5.5\tBedrock\tAnthropic\t0.11\t0.55\t-\t-\t0\tworks\t1\t1\t-\t-\t-\n"
           "xl/qwen3.8-27b\tqwen3.8-27b\tExperiential Labs\tQwen\t0.32\t2.4\t0.04\t-\t0\tuntested\t1\t0\t131072\t1000000\t"
           "Not checked with Claude Code here; Experiential Labs lists tool use for it.\n")
    (settings.litellm_dir / "code-models.tsv").write_text(tsv, encoding="utf-8")
    _write(settings)
    by = {m["id"]: m for m in code.models(settings)["models"]}
    q = by["xl/qwen3.8-27b"]
    assert (q["provider"], q["vendor"], q["compat"], q["max_output_tokens"], q["context"]) == ("Experiential Labs", "Qwen", "untested", 131072, 1000000)
    assert q["prices"] == {"in": 0.32, "out": 2.4, "cache_read": 0.04, "cache_write": None}
    (settings.litellm_dir / explabs.FILE).unlink()   # off: gone at once (the file follows at the next render)
    assert "xl/qwen3.8-27b" not in {m["id"] for m in code.models(settings)["models"]}


def test_a_call_on_your_own_provider_key_is_marked_in_the_code_pages_spend():
    row = code._row({"startTime": "2026-10-24T10:00:00Z", "model": "xl/qwen3.8-27b", "spend": 0.0, "total_tokens": 106,
                     "metadata": {"usage_object": {"prompt_tokens": 58, "is_byok": True}}})
    assert row["byok"] is True and row["spend"] == 0.0
    row = code._row({"startTime": "2026-10-24T10:00:00Z", "model": "xl/q", "spend": 0.0,
                     "metadata": {"additional_usage_values": {"is_byok": True}}})
    assert row["byok"] is True
    assert code._row({"model": "claude-haiku-5-5", "spend": 0.01, "metadata": {"usage_object": {"is_byok": "yes"}}})["byok"] is False


def test_the_portal_never_holds_the_gateways_key():
    from conftest import PASSWORD_HASH
    s = from_env({"EXPLABS_API_KEY": "should-never-be-read-by-the-portal-0000", "PORTAL_SECRET": "s" * 64,
                  "PORTAL_PASSWORD_HASH": PASSWORD_HASH})
    assert "should-never-be-read" not in repr(s) and not any(
        "should-never-be-read" in str(getattr(s, f)) for f in s.__dataclass_fields__)


def test_the_page_scripts_name_the_gateways_group_and_its_settings_row():
    from pathlib import Path
    root = Path(answers.__file__).parent / "static"
    js = (root / "answers.js").read_text(encoding="utf-8")
    assert 'label: "Experiential Labs"' in js and 'setupOf(d, "explabs-off")' in js and "TODO(setup-links)" not in js
    st = (root / "settings.js").read_text(encoding="utf-8")
    assert 'explabs: ["LiteLLM"]' in st and '"xl_key"' in st
    # removing the key restarts LiteLLM alone, and the dialog says so
    assert "the Code page and the API; LiteLLM restarts (about 30 s)." in st


def test_the_greyed_entry_goes_to_a_live_settings_row():
    # catalog/setup-links.tsv explabs-off: Settings › Chat & voice › Experiential Labs key, a row the page shows, a key
    # set from this computer only (so its words say so), and the Code page's copy the same
    from pathlib import Path
    root = Path(answers.__file__).resolve().parents[2]
    table = root / "catalog" / "setup-links.tsv"
    if not table.exists():
        return
    links = answers.setup_links(table.parent)
    row = links["explabs-off"]
    assert row["target"] == "setting:EXPLABS_API_KEY" and row["where"] == "Settings › Chat & voice › Experiential Labs key"
    assert row["says"].endswith(", from the computer running DevOS ADE.") and row["where"] in row["says"]
    settings = [l.split("\t") for l in (root / "catalog" / "settings.tsv").read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")]
    key = next(f for f in settings if f[0] == "EXPLABS_API_KEY")
    assert key[3] == "local" and key[6] == "Experiential Labs key"
    layout = [l.split("\t") for l in (root / "catalog" / "settings-layout.tsv").read_text(encoding="utf-8").splitlines() if l and not l.startswith(("#", "@"))]
    assert next(f for f in layout if f[0] == "EXPLABS_API_KEY")[1:3] == ["chat", "main"]
    code = root / "code" / "web" / "src" / "setuplinks.ts"
    if code.exists():
        assert f'"explabs-off": {{ target: "setting:EXPLABS_API_KEY", where: "{row["where"]}", says: "{row["says"]}" }}' in code.read_text(encoding="utf-8")
