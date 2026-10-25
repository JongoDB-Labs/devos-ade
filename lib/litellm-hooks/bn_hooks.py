"""DevOS ADE's one LiteLLM hook (litellm/config.yaml: litellm_settings.callbacks, rendered by lib/models.sh). Its
source lives here; ./stack copies it into litellm/ (LiteLLM's config folder) whenever it renders the config, so a
checkout of a version without it (./stack rollback) never deletes a file a running config still names.

Before each request, from code-models.tsv next to this file (written by ./stack: lib/code_models.sh, from
catalog/code-models.tsv and OpenRouter's list):
- Claude Code asks every model for up to 32,000 output tokens; some providers refuse a request above their own limit
  (Bedrock's Llama 3.3 70B: 8,192) instead of answering shorter. max_tokens (and a thinking budget that would no longer
  fit) is lowered to the model's max_out.
- Claude Code follows each tool result with a system message of its own: its running token count ("<total_tokens>N
  tokens left</total_tokens>", nothing else). Anthropic's models take a system message there. For another vendor's
  model on Bedrock, LiteLLM turns it into text after the result ("Operator note (not from the user): the following was
  originally a mid-conversation system-role reminder." and the count), and GPT-6 then sometimes ends its turn on that
  note with no answer, or asks what to do (one turn replayed: 5 times in 31 with the note, never in 30 without). For
  those models that message is left out; every other message stays as it came.

For the Experiential Labs gateway's models (lib/explabs.sh: model_info bn_xl: true), on each call to the gateway:
- Before it: the model goes by its own id on Chat Completions (with extended thinking on, LiteLLM renames it
  openai/responses/<id> for OpenAI's Responses API, which would send the gateway an id it does not know); the output cap goes under the field the model takes (model_info bn_xl_max_tokens: max_tokens or
  max_completion_tokens; Claude Code and Chat send max_tokens), and the parameters of its additional_drop_params — what
  the gateway's metadata says it does not take — are left out, extra_body included (LiteLLM drops the others itself).
- After it: the cost LiteLLM books is the one the gateway reported for the call (usage.cost, USD), $0 when the call ran
  on your own provider key (usage.is_byok), never one computed from the list prices in the config. (A streamed reply's
  usage.cost is booked by LiteLLM itself.)
Nothing else is changed, and any problem here leaves the request exactly as it came: this must never be the reason a
request fails.
"""

from __future__ import annotations

import math
import os
import re
from collections.abc import Mapping

from litellm.integrations.custom_logger import CustomLogger

_TSV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "code-models.tsv")
_cache: dict = {"stamp": None, "limits": {}, "other": frozenset()}


def _read() -> dict:
    """code-models.tsv, read again when the file changed: {"limits": {model id: max output tokens}, "other": the ids of
    another vendor's models on Bedrock} (id col 1, provider col 3, vendor col 4, max_out col 13)."""
    try:
        st = os.stat(_TSV)
        stamp = (st.st_mtime_ns, st.st_size)
    except OSError:
        return {"limits": {}, "other": frozenset()}
    if stamp != _cache["stamp"]:
        out, other = {}, set()
        try:
            with open(_TSV, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("#"):
                        continue
                    c = line.rstrip("\n").split("\t")
                    if len(c) >= 13 and c[12].isdigit() and 0 < int(c[12]) < 10_000_000:
                        out[c[0]] = int(c[12])
                    if len(c) >= 4 and c[2] == "Bedrock" and c[3] not in ("Anthropic", "", "-"):
                        other.add(c[0])
        except (OSError, ValueError):
            out, other = {}, set()
        _cache.update(stamp=stamp, limits=out, other=frozenset(other))
    return _cache


def _limits() -> dict:
    """{model id: max output tokens} from code-models.tsv."""
    return _read()["limits"]


def cap_request(data: dict) -> dict:
    """DATA (a request body) with max_tokens lowered to its model's limit; unchanged when there is none."""
    model = data.get("model")
    cap = _limits().get(model) if isinstance(model, str) else None
    for key in ("max_tokens", "max_completion_tokens"):
        v = data.get(key)
        if cap and isinstance(v, int) and not isinstance(v, bool) and v > cap:
            data[key] = cap
    th = data.get("thinking")
    mt = data.get("max_tokens")
    if cap and isinstance(th, dict) and isinstance(th.get("budget_tokens"), int) and isinstance(mt, int) and th["budget_tokens"] >= mt:
        data["thinking"] = {**th, "budget_tokens": max(1024, mt // 2)}
    return data


# Claude Code's running token count: a system message with nothing else (the first turn's environment message ends with
# one too, among its other lines: that one stays)
_TOKENS_LEFT = re.compile(r"\s*<total_tokens>[0-9]{1,15} tokens left</total_tokens>\s*")


def _token_count(m) -> bool:
    """Whether message M is Claude Code's running token count: role system, its only text that note."""
    if not isinstance(m, dict) or m.get("role") != "system":
        return False
    c = m.get("content")
    if isinstance(c, list) and len(c) == 1 and isinstance(c[0], dict) and c[0].get("type") == "text":
        c = c[0].get("text")
    return isinstance(c, str) and _TOKENS_LEFT.fullmatch(c) is not None


def drop_token_counts(data: dict) -> dict:
    """DATA with Claude Code's running token counts (system messages after the first message) left out — only for
    another vendor's model on Bedrock; unchanged otherwise."""
    model, msgs = data.get("model"), data.get("messages")
    if not isinstance(model, str) or model not in _read()["other"] or not isinstance(msgs, list):
        return data
    kept = [m for i, m in enumerate(msgs) if i == 0 or not _token_count(m)]
    if len(kept) != len(msgs):
        data["messages"] = kept
    return data


# --- the Experiential Labs gateway (lib/explabs.sh) ---

# The only parameters ever left out here: those lib/explabs.sh lets the gateway's metadata decide (XL_OPTIONAL_PARAMS)
XL_OPTIONAL = frozenset(("temperature", "top_p", "top_k", "frequency_penalty", "presence_penalty", "logprobs", "top_logprobs",
                         "tools", "tool_choice", "parallel_tool_calls", "functions", "function_call", "response_format",
                         "reasoning_effort", "max_tokens", "max_completion_tokens"))
_CAP_FIELDS = ("max_tokens", "max_completion_tokens")
# where LiteLLM's cost calculator looks for a cost the provider reported before it prices anything itself
COST_HEADER = "llm_provider-x-litellm-response-cost"


# the calls that reach the gateway as Chat Completions: a /v1/messages request (Claude Code) is one of them only once
# LiteLLM has turned it into one (its own anthropic_messages call around it keeps Anthropic's max_tokens)
_CHAT_CALLS = frozenset(("acompletion", "completion"))


def is_xl(kwargs) -> bool:
    """Whether KWARGS (one call to one deployment) goes to an Experiential Labs model."""
    mi = kwargs.get("model_info") if isinstance(kwargs, Mapping) else None
    return isinstance(mi, Mapping) and mi.get("bn_xl") is True


def _chat_call(call_type) -> bool:
    return getattr(call_type, "value", call_type) in _CHAT_CALLS


def xl_request(kwargs: dict) -> dict:
    """KWARGS for an Experiential Labs model: the model's own id, the output cap under the field its model takes and
    the parameters of its additional_drop_params left out (top level and extra_body); unchanged for any other model."""
    if not is_xl(kwargs):
        return kwargs
    # a /v1/messages request with thinking on: LiteLLM names the model openai/responses/<id> to send it to OpenAI's
    # Responses API, with a Responses-shaped reasoning_effort; the gateway takes Chat Completions under the id itself
    model = kwargs.get("model")
    if isinstance(model, str) and "responses/" in model:
        head, _, rest = model.partition("responses/")
        if head in ("", "openai/") and rest:
            kwargs["model"] = head + rest
            effort = kwargs.get("reasoning_effort")
            if isinstance(effort, Mapping):
                if isinstance(effort.get("effort"), str) and effort["effort"]:
                    kwargs["reasoning_effort"] = effort["effort"]
                else:
                    kwargs.pop("reasoning_effort")
    field = kwargs["model_info"].get("bn_xl_max_tokens")
    if field in _CAP_FIELDS:
        other = _CAP_FIELDS[1] if field == _CAP_FIELDS[0] else _CAP_FIELDS[0]
        if kwargs.get(field) is None and kwargs.get(other) is not None:
            kwargs[field] = kwargs.pop(other)
    drops = kwargs.get("additional_drop_params")
    drop = {p for p in drops if isinstance(p, str) and p in XL_OPTIONAL} if isinstance(drops, (list, tuple)) else set()
    for p in drop:
        kwargs.pop(p, None)
    extra = kwargs.get("extra_body")
    if isinstance(extra, dict) and drop & extra.keys():
        kwargs["extra_body"] = {k: v for k, v in extra.items() if k not in drop}
    return kwargs


def _usage_field(usage, name):
    return usage.get(name) if isinstance(usage, Mapping) else getattr(usage, name, None)


def gateway_cost(response) -> float | None:
    """What the gateway says RESPONSE cost in USD: usage.cost, 0.0 on your own provider key (usage.is_byok); None
    without a usable figure (LiteLLM then prices it from the config)."""
    usage = response.get("usage") if isinstance(response, Mapping) else getattr(response, "usage", None)
    if usage is None:
        return None
    if _usage_field(usage, "is_byok") is True:
        return 0.0
    c = _usage_field(usage, "cost")
    if isinstance(c, bool) or not isinstance(c, (int, float)) or not math.isfinite(c) or not 0 <= c < 1e6:
        return None
    return float(c)


def book_gateway_cost(response) -> None:
    """Puts gateway_cost(RESPONSE) where LiteLLM's cost calculator reads a provider-reported cost first."""
    c = gateway_cost(response)
    hidden = getattr(response, "_hidden_params", None)
    if c is None or not isinstance(hidden, dict):
        return
    headers = hidden.get("additional_headers")
    hidden["additional_headers"] = {**(dict(headers) if isinstance(headers, Mapping) else {}), COST_HEADER: c}


class BnHooks(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):  # noqa: ARG002 — LiteLLM's signature
        try:
            if isinstance(data, dict):
                cap_request(data)
                drop_token_counts(data)
        except Exception:  # noqa: BLE001 — never fail a request because of this hook
            pass
        return data

    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        try:
            if isinstance(kwargs, dict) and _chat_call(call_type):
                return xl_request(kwargs)
        except Exception:  # noqa: BLE001
            pass
        return kwargs

    async def async_post_call_success_deployment_hook(self, request_data, response, call_type):  # noqa: ARG002
        try:
            if is_xl(request_data):
                book_gateway_cost(response)
        except Exception:  # noqa: BLE001 — a cost never fails an answer
            pass
        return response


proxy_handler_instance = BnHooks()
