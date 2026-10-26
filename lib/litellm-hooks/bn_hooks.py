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
- The Read tool hands an image back as part of its result. Bedrock's Converse refuses an image inside a tool result
  for another vendor's model ("This model doesn't support the image field for user messages"), though it takes one in
  the user's message: for those models the images of a tool result go right after the results, in the same message,
  under a line saying which call they came from (what LiteLLM does itself for an OpenAI-shaped provider).
- Claude Code's WebSearch asks the model for Anthropic's web search, a tool the provider runs (type web_search_…).
  Bedrock runs none: LiteLLM refuses it for Claude there (telling you to set up a search of LiteLLM's own), and for
  another vendor's model on Bedrock or OpenRouter it is left out or not booked, and the model answers from what it
  knows as though it had searched. For those models the request becomes one that has the model answer WEB_SEARCH_OFF
  and nothing else (no tools, a short answer): the WebSearch tool hands that to the model as its result, and the model
  says so. The Experiential Labs gateway runs the search itself (LiteLLM asks it with web_search_options; its fee is in
  the cost the gateway reports): its models' requests go as they came.

For the Experiential Labs gateway's models (lib/explabs.sh: model_info bn_xl: true), on each call to the gateway:
- Before it: the model goes by its own id (with extended thinking on, LiteLLM renames it openai/responses/<id> for
  OpenAI's Responses API, which would send the gateway an id it does not know). The output cap goes under the field the
  model takes (model_info bn_xl_max_tokens: max_tokens or max_completion_tokens; Claude Code and Chat send max_tokens),
  in extra_body: LiteLLM sends that as it is, where it would rename a top-level max_tokens to max_completion_tokens for
  an o-series or GPT-5 name whatever the model takes. A call LiteLLM moves to the gateway's Responses API after this
  hook (GPT-5.4 and later names with a reasoning effort and function tools: LiteLLM's responses_api_bridge_check) keeps
  its cap at the top level instead, under the model's field, since that move leaves extra_body behind; LiteLLM sends it
  as max_output_tokens. The parameters of its additional_drop_params — what the gateway's details say it does not
  take — are left out, extra_body included (LiteLLM drops the others itself). The history goes without LiteLLM's own
  fields, which the gateway refuses: an earlier answer's thinking that Claude Code replays (LiteLLM's /v1/messages
  translation puts it in thinking_blocks) goes as reasoning_content, the gateway's field for it, and
  provider_specific_fields is left out (a call moved to the Responses API keeps them: LiteLLM makes reasoning items of
  that thinking there).
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
_EMPTY = {"limits": {}, "other": frozenset(), "no_search": frozenset()}
_cache: dict = {"stamp": None, **_EMPTY}


def _read() -> dict:
    """code-models.tsv, read again when the file changed: {"limits": {model id: max output tokens}, "other": the ids of
    another vendor's models on Bedrock, "no_search": the ids of the models whose provider runs no web search for
    Claude Code (Bedrock's, OpenRouter's)} (id col 1, provider col 3, vendor col 4, max_out col 13)."""
    try:
        st = os.stat(_TSV)
        stamp = (st.st_mtime_ns, st.st_size)
    except OSError:
        return _EMPTY
    if stamp != _cache["stamp"]:
        out, other, no_search = {}, set(), set()
        try:
            with open(_TSV, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("#"):
                        continue
                    c = line.rstrip("\n").split("\t")
                    if len(c) >= 13 and c[12].isdigit() and 0 < int(c[12]) < 10_000_000:
                        out[c[0]] = int(c[12])
                    if len(c) >= 3 and c[2] in ("Bedrock", "OpenRouter"):
                        no_search.add(c[0])
                    if len(c) >= 4 and c[2] == "Bedrock" and c[3] not in ("Anthropic", "", "-"):
                        other.add(c[0])
        except (OSError, ValueError):
            out, other, no_search = {}, set(), set()
        _cache.update(stamp=stamp, limits=out, other=frozenset(other), no_search=frozenset(no_search))
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


def _is_image(b) -> bool:
    return isinstance(b, Mapping) and b.get("type") == "image"


def lift_tool_images(data: dict) -> dict:
    """DATA with the images of its tool results moved out of them, into the same user message right after the results
    (each under a line naming its call) — only for another vendor's model on Bedrock; unchanged otherwise."""
    model, msgs = data.get("model"), data.get("messages")
    if not isinstance(model, str) or model not in _read()["other"] or not isinstance(msgs, list):
        return data
    out, changed = [], False
    for m in msgs:
        content = m.get("content") if isinstance(m, Mapping) and m.get("role") == "user" else None
        if not isinstance(content, list) or not any(
                isinstance(b, Mapping) and b.get("type") == "tool_result" and isinstance(b.get("content"), list)
                and any(_is_image(x) for x in b["content"]) for b in content):
            out.append(m)
            continue
        kept, lifted, last = [], [], -1
        for b in content:
            if isinstance(b, Mapping) and b.get("type") == "tool_result" and isinstance(b.get("content"), list):
                images = [x for x in b["content"] if _is_image(x)]
                if images:
                    rest = [x for x in b["content"] if not _is_image(x)] or [
                        {"type": "text", "text": "(its image is in the message below)" if len(images) == 1 else "(its images are in the message below)"}]
                    b = {**b, "content": rest}
                    lifted += [{"type": "text", "text": f"[The image output of tool call {b.get('tool_use_id', '')}]"}, *images]
                kept.append(b)
                last = len(kept) - 1
            else:
                kept.append(b)
        out.append({**m, "content": kept[:last + 1] + lifted + kept[last + 1:]})
        changed = True
    if changed:
        data["messages"] = out
    return data


# --- Claude Code's WebSearch where no search runs (Bedrock, OpenRouter) ---

WEB_SEARCH_OFF = "Web search isn't available for {model} in DevOS ADE. Use WebFetch with a URL."


def _web_search_tool(t) -> bool:
    return isinstance(t, Mapping) and isinstance(t.get("type"), str) and t["type"].startswith("web_search")


def no_web_search(data: dict) -> dict:
    """DATA, when it asks a model whose provider runs no web search for Anthropic's web search (a tool whose type starts
    with web_search: Claude Code's WebSearch), made a request for WEB_SEARCH_OFF instead: no tools, nothing to think
    about, a short answer that is that sentence alone. Unchanged otherwise."""
    model, tools = data.get("model"), data.get("tools")
    if not isinstance(model, str) or model not in _read()["no_search"] or not isinstance(tools, list) or not any(map(_web_search_tool, tools)):
        return data
    line = WEB_SEARCH_OFF.format(model=model)
    for k in ("tools", "tool_choice", "thinking", "output_config", "temperature", "top_p", "top_k", "stop_sequences"):
        data.pop(k, None)
    data["system"] = ("No web search can run here. Reply with exactly the line between the markers, word for word, and "
                      f"nothing else.\n<<<\n{line}\n>>>")
    data["messages"] = [{"role": "user", "content": "Reply now."}]
    data["max_tokens"] = 200
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
    kwargs = dict(kwargs)   # (a copy: the hook hands LiteLLM the request as it came should anything here fail)
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
    # the output cap: out of LiteLLM's hands (its own field first, else the other one), into extra_body under the
    # field the model takes
    field = kwargs["model_info"].get("bn_xl_max_tokens")
    cap = None
    if field in _CAP_FIELDS:
        caps = [kwargs.pop(f, None) for f in sorted(_CAP_FIELDS, key=lambda f: f != field)]
        cap = next((c for c in caps if c is not None), None)
    drops = kwargs.get("additional_drop_params")
    drop = {p for p in drops if isinstance(p, str) and p in XL_OPTIONAL} if isinstance(drops, (list, tuple)) else set()
    for p in drop:
        kwargs.pop(p, None)
    extra = kwargs.get("extra_body")
    if isinstance(extra, dict) and drop & extra.keys():
        kwargs["extra_body"] = extra = {k: v for k, v in extra.items() if k not in drop}
    route = _route(kwargs)
    if cap is not None:
        if route != "chat":
            kwargs[field] = cap
        else:
            kwargs["extra_body"] = {**(extra if isinstance(extra, dict) else {}), field: cap}
    # the history, for the gateway's Chat Completions: without LiteLLM's own fields. (A call LiteLLM moves to the
    # Responses API keeps them: LiteLLM turns thinking_blocks into the Responses API's reasoning items there, and sends
    # none of those fields itself.)
    messages = kwargs.get("messages")
    if route != "responses" and isinstance(messages, list):
        kwargs["messages"] = [xl_message(m) for m in messages]
    return kwargs


# LiteLLM's own fields on a message, which the gateway's Chat Completions refuses ("Invalid value for
# 'messages.3.thinking_blocks'"): an earlier answer's thinking, replayed by Claude Code (LiteLLM's /v1/messages
# translation puts it there), and what a provider attached to a message or a tool call
_XL_MESSAGE_ONLY_LITELLM = ("thinking_blocks", "provider_specific_fields")


def xl_message(m):
    """Message M as the gateway's Chat Completions takes it: a copy without LiteLLM's own fields, the thinking of an
    earlier answer as reasoning_content (the gateway's field for it: replayed verbatim it keeps the model's thinking
    on the lanes that use it, and any other route drops it with a disclosure, never a 400). A message without any of
    them: M itself."""
    if not isinstance(m, Mapping):
        return m
    calls = m.get("tool_calls")
    dirty_calls = isinstance(calls, list) and any(
        isinstance(c, Mapping) and ("provider_specific_fields" in c or (
            isinstance(c.get("function"), Mapping) and "provider_specific_fields" in c["function"])) for c in calls)
    if not dirty_calls and not any(k in m for k in _XL_MESSAGE_ONLY_LITELLM):
        return m
    out = {k: v for k, v in m.items() if k not in _XL_MESSAGE_ONLY_LITELLM}
    if not out.get("reasoning_content"):
        blocks = m.get("thinking_blocks")
        text = "\n".join(b["thinking"] for b in blocks if isinstance(b, Mapping) and b.get("type") == "thinking"
                         and isinstance(b.get("thinking"), str) and b["thinking"]) if isinstance(blocks, list) else ""
        if text:
            out["reasoning_content"] = text
    if dirty_calls:
        out["tool_calls"] = [_xl_tool_call(c) for c in calls]
    return out


def _xl_tool_call(c):
    if not isinstance(c, Mapping):
        return c
    out = {k: v for k, v in c.items() if k != "provider_specific_fields"}
    f = out.get("function")
    if isinstance(f, Mapping) and "provider_specific_fields" in f:
        out["function"] = {k: v for k, v in f.items() if k != "provider_specific_fields"}
    return out


def _route(kwargs: dict) -> str | None:
    """Where LiteLLM will send this Chat Completions call (KWARGS as the hook leaves them): "responses" when it moves it
    to the Responses API (which carries neither extra_body nor the messages' fields as they are), "chat" when it does
    not — its own check, asked as it will ask it; None without that check (another LiteLLM) or on any error. The cap
    then stays at the top level, never lost, and the history is cleaned for Chat Completions, never refused."""
    try:
        from litellm.main import responses_api_bridge_check
        model = kwargs.get("model")
        info, _ = responses_api_bridge_check(
            model=model.removeprefix("openai/") if isinstance(model, str) else "", custom_llm_provider="openai",
            tools=kwargs.get("tools"), reasoning_effort=kwargs.get("reasoning_effort"), api_base=kwargs.get("api_base"))
        if not isinstance(info, Mapping):
            return None
        return "responses" if info.get("mode") == "responses" else "chat"
    except Exception:  # noqa: BLE001 — never a lost cap or a refused history because of this check
        return None


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
        for step in (cap_request, drop_token_counts, lift_tool_images, no_web_search):
            try:
                if isinstance(data, dict):
                    step(data)
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
