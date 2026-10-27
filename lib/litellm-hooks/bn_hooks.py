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
  Bedrock runs none and OpenRouter barely: with a search backend (web-search.json next to this file, written by
  ./stack: lib/websearch.sh; the built-in SearXNG unless another is set up or web search is off, its searches at $0),
  LiteLLM's web search interception runs the search for those models (web_search below: the
  config names it after this hook), and each search is booked at the backend's price per search (registered with
  LiteLLM here: its own map has none for some, $0 for AgentCore). Without one, LiteLLM refuses it for Claude on Bedrock
  (telling you to set up a search of LiteLLM's own), and for another vendor's model on Bedrock or OpenRouter it is left
  out or not booked, and the model answers from what it knows as though it had searched: for those models the request
  becomes one that has the model answer WEB_SEARCH_OFF and nothing else (no tools, a short answer): the WebSearch tool
  hands that to the model as its result, and the model says so. The Experiential Labs gateway runs the search itself
  (LiteLLM asks it with web_search_options; its fee is in the cost the gateway reports): its models' requests go as
  they came.

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
- When it fails because the key may not use that model — the gateway's 403 "The requested model alias is not granted
  to this identity" (an alias the key's GET /v1/models does not list, such as a "…:free" one) — the error the caller
  gets is a 400 invalid_request_error saying so in plain words (XL_NOT_GRANTED): with a 403 Claude Code would take it
  for an expired sign-in and ask for /login. Any other 401 or 403 (a key the gateway rejects) stays as it came.
- When it is the gateway's one-time notice that a model's free promotion has ended (402: "The free promotion for
  GLM-5.3 Uncensored has ended. … requests will be charged to your credit balance. Retry to continue."), the caller gets
  a 400 invalid_request_error saying so (XL_PROMO_ENDED): sending it again agrees to the charge, which is yours to
  decide — a status no one in between tries again by itself (LiteLLM's router raises a 402 at once, and Claude Code
  retries neither; a 400 it shows as the model's error).

For a Llama model on Bedrock (its model id names meta.llama), on each call with tools: Bedrock's Converse takes the
tools (toolConfig) but hands Llama's tool call back as the text Llama wrote, in Meta's documented form ({"type":
"function", "name": …, "parameters": {…}}), with stopReason end_turn — for Claude Code's requests every time, where a
short request of one tool gets a toolUse block — so Claude Code saw an answer and ran nothing. Bedrock takes no tool
use in a stream for Llama: LiteLLM asks the Converse API (not ConverseStream) and streams the answer itself. The call
goes through LiteLLM's own client with Bedrock's answer read on the way back (llama_tool_calls): an answer that is
one text block and nothing but Llama's tool calls, each naming a tool the request offers with a JSON object of
arguments that has every key the tool's schema requires (text_tool_calls), becomes those calls as toolUse blocks with
stopReason tool_use — the answer Bedrock gives for the other models' calls, so LiteLLM's stream, its Chat Completions
answer and Claude Code's tool_use all follow from it. Anything else stays the text it was. And on every call: Bedrock
refuses, for Llama alone, a turn that holds tool results and text ("Conversation blocks and tool result blocks cannot
be provided in the same turn") — the turn LiteLLM makes of Claude Code's tool results and the reminders that follow
them. Those reminders (a system one under LiteLLM's note, a user one as it came) go at the end of the last result
instead (llama_tool_turns).
Nothing else is changed, and any problem here leaves the request exactly as it came: this must never be the reason a
request fails.
"""

from __future__ import annotations

import json
import math
import os
import re
import secrets
import string
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
_SEARCH_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web-search.json")
_search_cache: dict = {"stamp": None, "backend": ""}
_SEARCH_PROVIDER = re.compile(r"[a-z][a-z0-9_]{0,40}")


def search_backend() -> str:
    """The search backend LiteLLM's web search interception runs Claude Code's WebSearch with (web-search.json's
    "backend"), "" for none (no file, or one that names none: v0.28.2's answer, WEB_SEARCH_OFF, stays). Read again when
    the file changed; each time, the backend's price per search ("usd_per_query", under "provider") is registered with
    LiteLLM, which books every search of it at that price on the key of the request that searched."""
    try:
        st = os.stat(_SEARCH_JSON)
        stamp = (st.st_mtime_ns, st.st_size)
    except OSError:
        _search_cache.update(stamp=None, backend="")
        return ""
    if stamp != _search_cache["stamp"]:
        backend = ""
        try:
            with open(_SEARCH_JSON, encoding="utf-8") as f:
                doc = json.load(f) if st.st_size < 65536 else {}
            b, provider, price = doc.get("backend"), doc.get("provider"), doc.get("usd_per_query")
            if isinstance(b, str) and _SEARCH_PROVIDER.fullmatch(b):
                backend = b
                if (isinstance(provider, str) and _SEARCH_PROVIDER.fullmatch(provider)
                        and isinstance(price, (int, float)) and not isinstance(price, bool)
                        and math.isfinite(price) and 0 <= price < 1):
                    _register_search_price(provider, float(price))
        except (OSError, ValueError, AttributeError):
            backend = ""
        _search_cache.update(stamp=stamp, backend=backend)
    return _search_cache["backend"]


def _register_search_price(provider: str, price: float) -> None:
    """LiteLLM prices a search as <provider>/search's input_cost_per_query in its model map: ours, for this one."""
    try:
        import litellm

        litellm.register_model({f"{provider}/search": {"input_cost_per_query": price, "litellm_provider": provider,
                                                       "mode": "search"}})
    except Exception:  # noqa: BLE001 — a price never stops a search (LiteLLM's own then stands)
        pass


def _web_search_tool(t) -> bool:
    return isinstance(t, Mapping) and isinstance(t.get("type"), str) and t["type"].startswith("web_search")


def no_web_search(data: dict) -> dict:
    """DATA, when it asks a model whose provider runs no web search for Anthropic's web search and nothing else (every
    tool's type starts with web_search: the request Claude Code's WebSearch makes on its own), made a request for
    WEB_SEARCH_OFF instead: no tools, nothing to think about, a short answer that is that sentence alone — only while
    no search backend is set up (search_backend: then LiteLLM's interception searches). Unchanged otherwise: a request
    with any other tool (a session's turn) is never replaced, whatever it lists besides."""
    model, tools = data.get("model"), data.get("tools")
    if (not isinstance(model, str) or model not in _read()["no_search"] or not isinstance(tools, list) or not tools
            or not all(map(_web_search_tool, tools)) or search_backend()):
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


# --- Llama on Bedrock: the tool calls Bedrock hands back as text ---

# Llama's own marks around a tool call (Meta's prompt format: <|python_tag|>{…}<|eom_id|>), should they reach us
_LLAMA_HEAD = "<|python_tag|>"
_LLAMA_TAILS = ("<|eom_id|>", "<|eot_id|>")
# Meta's other documented form for a tool of your own: <function=name>{arguments}</function>
_FUNCTION_TAG = re.compile(r"<function=([A-Za-z0-9_-]{1,64})>")
_FUNCTION_END = "</function>"
_JSON = json.JSONDecoder()
_SPACE = " \t\r\n"
_ID_CHARS = string.ascii_letters + string.digits


def offered_tools(request) -> dict:
    """{tool name: its input schema} of the tools a Converse REQUEST offers (toolConfig.tools[].toolSpec)."""
    config = request.get("toolConfig") if isinstance(request, Mapping) else None
    tools = config.get("tools") if isinstance(config, Mapping) else None
    out = {}
    for t in tools if isinstance(tools, list) else []:
        spec = t.get("toolSpec") if isinstance(t, Mapping) else None
        if isinstance(spec, Mapping) and isinstance(spec.get("name"), str) and spec["name"]:
            schema = spec.get("inputSchema")
            schema = schema.get("json") if isinstance(schema, Mapping) else None
            out[spec["name"]] = schema if isinstance(schema, Mapping) else {}
    return out


def _tool_call(name, args, tools):
    """(NAME, ARGS) when NAME is a tool of TOOLS and ARGS an object with every key that tool's schema requires; None
    otherwise. (The values are the model's: Claude Code checks them against the schema, as for any model's call.)"""
    if not isinstance(name, str) or name not in tools or not isinstance(args, dict):
        return None
    required = tools[name].get("required")
    if isinstance(required, list) and not all(isinstance(k, str) and k in args for k in required):
        return None
    return name, args


def _skip(s: str, i: int) -> int:
    while i < len(s) and s[i] in _SPACE:
        i += 1
    return i


def text_tool_calls(text, tools) -> list | None:
    """The tool calls TEXT (a model's whole answer) is, as [(name, arguments)], when all of it is one or more calls in
    Llama's documented forms — {"type": "function", "name": …, "parameters": {…}} ("type" optional; several of them
    apart by white space or one ";"), or <function=name>{…}</function> (several apart by white space), with
    <|python_tag|> before and <|eom_id|> or <|eot_id|> after allowed — each naming a tool of TOOLS ({name: input
    schema}) with a JSON object of arguments that has every key its schema requires. None for anything else (any
    other word, a code fence, an unknown tool, JSON that does not parse, a missing argument): that stays text."""
    if not isinstance(text, str) or not tools:
        return None
    s = text.strip(_SPACE)
    if s.startswith(_LLAMA_HEAD):
        s = s[len(_LLAMA_HEAD):].lstrip(_SPACE)
    for tail in _LLAMA_TAILS:
        if s.endswith(tail):
            s = s[:-len(tail)].rstrip(_SPACE)
            break
    calls, i = [], 0
    if s.startswith("<function="):
        while i < len(s):
            m = _FUNCTION_TAG.match(s, i)
            if not m:
                return None
            try:
                args, i = _JSON.raw_decode(s, _skip(s, m.end()))
            except ValueError:
                return None
            i = _skip(s, i)
            call = _tool_call(m.group(1), args, tools)
            if call is None or not s.startswith(_FUNCTION_END, i):
                return None
            calls.append(call)
            i = _skip(s, i + len(_FUNCTION_END))
        return calls or None
    while i < len(s):
        try:
            obj, i = _JSON.raw_decode(s, i)
        except ValueError:
            return None
        if (not isinstance(obj, dict) or not obj.keys() <= {"type", "name", "parameters"} or "parameters" not in obj
                or obj.get("type", "function") != "function"):
            return None
        call = _tool_call(obj.get("name"), obj.get("parameters"), tools)
        if call is None:
            return None
        calls.append(call)
        i = _skip(s, i)
        if i < len(s) and s[i] == ";":
            i = _skip(s, i + 1)
            if i == len(s):
                return None
    return calls or None


def converse_tool_calls(request, answer) -> dict | None:
    """ANSWER (Bedrock's Converse answer to REQUEST) with Llama's tool calls as toolUse blocks and stopReason
    tool_use, as Bedrock returns the calls of the other models — when the answer is one text block, ended there
    (end_turn), that text_tool_calls reads as calls of the tools REQUEST offers. None otherwise: the answer stays as it
    came."""
    if not isinstance(answer, Mapping) or answer.get("stopReason") != "end_turn":
        return None
    output = answer.get("output")
    message = output.get("message") if isinstance(output, Mapping) else None
    content = message.get("content") if isinstance(message, Mapping) else None
    if not (isinstance(content, list) and len(content) == 1 and isinstance(content[0], Mapping)
            and set(content[0]) == {"text"}):
        return None
    calls = text_tool_calls(content[0]["text"], offered_tools(request))
    if not calls:
        return None
    blocks = [{"toolUse": {"toolUseId": "tooluse_" + "".join(secrets.choice(_ID_CHARS) for _ in range(22)),
                           "name": name, "input": args}} for name, args in calls]
    return {**answer, "output": {**output, "message": {**message, "content": blocks}}, "stopReason": "tool_use"}


def _bedrock_llama(kwargs) -> bool:
    """Whether KWARGS (one Chat Completions call) goes to a Llama model through Bedrock's Converse."""
    model, provider = kwargs.get("model"), kwargs.get("custom_llm_provider")
    if not isinstance(model, str) or "meta.llama" not in model or model.startswith(("bedrock/invoke/", "invoke/")):
        return False
    return model.startswith("bedrock/") or provider == "bedrock"


def bedrock_llama_answer(url, body, response):
    """RESPONSE — Bedrock's answer to the Converse request BODY (sent to URL) for a Llama model — with its tool calls
    made toolUse blocks (converse_tool_calls): a response of the same kind with that answer, its headers but the
    length and encoding of the old one. RESPONSE itself for anything else."""
    if (not isinstance(url, str) or "meta.llama" not in url or not url.rstrip("/").endswith("/converse")
            or getattr(response, "status_code", None) != 200):
        return response
    if isinstance(body, (bytes, bytearray)):
        body = bytes(body).decode("utf-8")
    request = json.loads(body) if isinstance(body, str) else body
    if not isinstance(request, Mapping) or not offered_tools(request):
        return response
    answer = converse_tool_calls(request, response.json())
    if answer is None:
        return response
    headers = [(k, v) for k, v in response.headers.items()
               if k.lower() not in ("content-length", "content-encoding", "transfer-encoding")]
    return type(response)(status_code=response.status_code, headers=headers, content=json.dumps(answer).encode("utf-8"),
                          request=response.request)


_llama_client_class: list = []


def _llama_client(kwargs):
    """A client for this call to Bedrock: LiteLLM's own (the one it would take: get_async_httpx_client) makes it, and
    Bedrock's answer comes back through bedrock_llama_answer. None without LiteLLM's (another LiteLLM)."""
    from litellm.llms.custom_httpx.http_handler import AsyncHTTPHandler, get_async_httpx_client

    if not _llama_client_class:
        class LlamaToolCalls(AsyncHTTPHandler):
            def __init__(self, inner):   # (not AsyncHTTPHandler's: no client of its own to make, or to close)
                self._bn_inner = inner

            def __getattr__(self, name):
                if name == "_bn_inner":
                    raise AttributeError(name)
                return getattr(self._bn_inner, name)

            def __del__(self):   # (LiteLLM's client is LiteLLM's to close)
                pass

            async def post(self, url, *args, **kw):
                response = await self._bn_inner.post(url, *args, **kw)
                if kw.get("stream"):
                    return response
                try:
                    return bedrock_llama_answer(url, kw.get("data", args[0] if args else None), response)
                except Exception:  # noqa: BLE001 — the answer as Bedrock gave it, never a failed call
                    return response

        _llama_client_class.append(LlamaToolCalls)
    # (as LiteLLM picks it: a streamed call — a fake stream, a Converse call, for Llama with tools — takes its default
    # client; any other its timeout's)
    params = None
    timeout = kwargs.get("timeout")
    if not kwargs.get("stream") and isinstance(timeout, (int, float)) and not isinstance(timeout, bool):
        import httpx

        params = {"timeout": httpx.Timeout(timeout)}
    elif not kwargs.get("stream") and type(timeout).__name__ == "Timeout":
        params = {"timeout": timeout}
    inner = get_async_httpx_client(llm_provider="bedrock", params=params)
    return _llama_client_class[0](inner) if isinstance(inner, AsyncHTTPHandler) else None


def llama_tool_calls(kwargs: dict) -> dict:
    """KWARGS for a call with tools to a Llama model on Bedrock, with a client (_llama_client) that reads Bedrock's
    answer for the tool calls Llama wrote as text (bedrock_llama_answer); unchanged for any other call, or one that
    already has a client."""
    if (not isinstance(kwargs, dict) or kwargs.get("client") is not None or not kwargs.get("tools")
            or not _bedrock_llama(kwargs)):
        return kwargs
    client = _llama_client(kwargs)
    return {**kwargs, "client": client} if client is not None else kwargs


# LiteLLM's words before a mid-conversation system message it makes a user turn for Bedrock (its own constant when
# there is one: mid_conversation_system.CONVERTED_SYSTEM_NOTE)
_SYSTEM_NOTE = ("Operator note (not from the user): the following was originally a mid-conversation system-role "
                "reminder.")


def _system_note() -> str:
    try:
        from litellm.litellm_core_utils.prompt_templates.mid_conversation_system import CONVERTED_SYSTEM_NOTE

        return CONVERTED_SYSTEM_NOTE if isinstance(CONVERTED_SYSTEM_NOTE, str) and CONVERTED_SYSTEM_NOTE else (
            _SYSTEM_NOTE)
    except Exception:  # noqa: BLE001
        return _SYSTEM_NOTE


def _texts(m) -> list | None:
    """The texts of M when it is a user or system message of text alone (Chat Completions shape); None otherwise."""
    if not isinstance(m, Mapping) or m.get("role") not in ("user", "system"):
        return None
    c = m.get("content")
    if isinstance(c, str):
        return [c] if c else []
    if isinstance(c, list) and all(isinstance(p, Mapping) and p.get("type") == "text" and isinstance(p.get("text"), str)
                                   for p in c):
        return [p["text"] for p in c if p["text"]]
    return None


def results_alone(messages: list) -> list:
    """MESSAGES (Chat Completions shape) with the text that follows tool results before the next answer — user messages
    of text alone, and system ones under LiteLLM's note — at the end of the last of those results, as more of its
    text; every other message as it came. (Bedrock's Converse puts that text in the results' turn, and refuses it there
    for Llama: "Conversation blocks and tool result blocks cannot be provided in the same turn".)"""
    out, i, changed = [], 0, False
    while i < len(messages):
        m = messages[i]
        out.append(m)
        i += 1
        if (not isinstance(m, Mapping) or m.get("role") != "tool"
                or (i < len(messages) and isinstance(messages[i], Mapping) and messages[i].get("role") == "tool")):
            continue
        extra = []
        while i < len(messages) and (texts := _texts(messages[i])) is not None:
            extra += ([_system_note()] if messages[i]["role"] == "system" and texts else []) + texts
            i += 1
            changed = True
        if extra:
            c = m.get("content")
            parts = ([{"type": "text", "text": c}] if isinstance(c, str) and c
                     else list(c) if isinstance(c, list) else [])
            out[-1] = {**m, "content": parts + [{"type": "text", "text": t} for t in extra]}
    return out if changed else messages


def llama_tool_turns(kwargs: dict) -> dict:
    """KWARGS for a call to a Llama model on Bedrock with its tool results' turns holding the results alone
    (results_alone); unchanged for any other call."""
    if not isinstance(kwargs, dict) or not isinstance(kwargs.get("messages"), list) or not _bedrock_llama(kwargs):
        return kwargs
    messages = results_alone(kwargs["messages"])
    return {**kwargs, "messages": messages} if messages is not kwargs["messages"] else kwargs


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


# The gateway's words when the key may not use a model (or one of its aliases): 403, "The requested model alias is not
# granted to this identity. GET /v1/models lists the model aliases available to this key." (seen 2026-10-26), and its
# model_not_granted code
NOT_GRANTED = re.compile(r"not granted to this (?:identity|organi[sz]ation)|model alias is not granted|model_not_granted", re.I)
XL_NOT_GRANTED = ("Your Experiential Labs key isn't allowed to use this model ({model}): the model list the gateway gives "
                  "your key does not have it. Pick another model (Settings › Models & providers › Experiential Labs "
                  "lists the ones your key has).")


# The gateway's one-time notice that a free promotion has ended: a 402 whose retry is charged (seen 2026-10-26)
PROMO_ENDED = re.compile(r"free promotion for .{1,80}? has ended|one-time notice|will be charged to your credit balance", re.I | re.S)
PROMO_NAME = re.compile(r"free promotion for ([A-Za-z0-9][A-Za-z0-9 .:_+()-]{0,58}?) has ended")
XL_PROMO_ENDED = ("Experiential Labs: the free promotion for {name} has ended. From now on its requests are charged to your "
                  "Experiential Labs credits. Send your message again to continue, or pick another model.")


def _xl_group(request_data) -> str | None:
    """The model group REQUEST_DATA (the proxy's request) asked for, when it is an Experiential Labs model ("xl/…", or
    model_info bn_xl); else None."""
    if not isinstance(request_data, Mapping):
        return None
    model = request_data.get("model")
    meta = [request_data] + [request_data.get(k) for k in ("metadata", "litellm_metadata") if isinstance(request_data.get(k), Mapping)]
    if (isinstance(model, str) and model.startswith("xl/")) or any(is_xl(m) for m in meta):
        return model if isinstance(model, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,140}", model) else "xl/…"
    return None


def xl_not_granted(request_data, exc) -> bool:
    """EXC (a failed call to the gateway) is its 403 for a model the key may not use: changed in place into a 400
    invalid_request_error with XL_NOT_GRANTED as its message — the error the proxy then answers with, on /v1/messages
    (which reads the exception itself, not a hook's answer) as on Chat Completions. -> whether it was one."""
    group = _xl_group(request_data)
    if group is None or getattr(exc, "status_code", None) != 403:
        return False
    if not NOT_GRANTED.search(f"{getattr(exc, 'message', '')} {exc}"):
        return False
    said = XL_NOT_GRANTED.format(model=group)
    exc.status_code = 400
    exc.message = said
    exc.type = "invalid_request_error"
    try:
        exc.args = (said,)
    except Exception:  # noqa: BLE001
        pass
    return True


def xl_promo_ended(request_data, exc) -> bool:
    """EXC is the gateway's one-time 402 for a model whose free promotion ended: changed in place into a 400
    invalid_request_error with XL_PROMO_ENDED (the model's name as the gateway says it, else its id) — never tried
    again here or by Claude Code: sending it again is the user's consent to the charge. -> whether it was one."""
    group = _xl_group(request_data)
    if group is None or getattr(exc, "status_code", None) != 402:
        return False
    text = f"{getattr(exc, 'message', '')} {exc}"
    if not PROMO_ENDED.search(text):
        return False
    m = PROMO_NAME.search(text)
    said = XL_PROMO_ENDED.format(name=m.group(1) if m else group)
    exc.status_code = 400
    exc.message = said
    exc.type = "invalid_request_error"
    try:
        exc.args = (said,)
    except Exception:  # noqa: BLE001
        pass
    return True


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
        if not isinstance(kwargs, dict) or not _chat_call(call_type):
            return kwargs
        for step in (xl_request, llama_tool_calls, llama_tool_turns):
            try:
                kwargs = step(kwargs)
            except Exception:  # noqa: BLE001 — never fail a request because of this hook
                pass
        return kwargs

    async def async_post_call_success_deployment_hook(self, request_data, response, call_type):  # noqa: ARG002
        try:
            if is_xl(request_data):
                book_gateway_cost(response)
        except Exception:  # noqa: BLE001 — a cost never fails an answer
            pass
        return response

    async def async_post_call_failure_hook(self, request_data, original_exception, user_api_key_dict, traceback_str=None):  # noqa: ARG002
        try:
            xl_not_granted(request_data, original_exception) or xl_promo_ended(request_data, original_exception)
        except Exception:  # noqa: BLE001 — the error as it came
            pass
        return None


proxy_handler_instance = BnHooks()


# --- Claude Code's WebSearch with a search backend: LiteLLM's web search interception ---

SEARCH_PROVIDERS = ["bedrock", "openrouter"]   # (not the Experiential Labs gateway, an openai one: it searches itself)
SEARCH_TOOL = "web-search"                      # the config's search_tools entry (lib/websearch.sh WEBSEARCH_TOOL)
NATIVE_WEB_SEARCH = {"type": "web_search_20250305", "name": "web_search"}


def web_search_interception():
    """LiteLLM's web search interception for Bedrock's and OpenRouter's models with the search tool SEARCH_TOOL (the
    config names it, bn_hooks.web_search, while a backend is set up), changed in one thing: the request Claude Code's
    WebSearch makes on its own, for a model LiteLLM answers with the search alone (another vendor's on Bedrock,
    OpenRouter's), gets Anthropic's search blocks too (server_tool_use, web_search_tool_result), as Claude's does.
    LiteLLM 1.105.0 has turned the request's web_search tool into its own by the time it looks for one there, and sent
    the results as text alone: Claude Code then counted no search and listed no links. None without the interception
    (another LiteLLM): the config would name nothing that exists, so ./stack names it only with this file there."""
    try:
        from litellm.integrations.websearch_interception.handler import (
            WEBSEARCH_EMIT_NATIVE_BLOCKS_KEY, WebSearchInterceptionLogger)
        from litellm.integrations.websearch_interception.tools import is_anthropic_native_web_search_tool
    except Exception:  # noqa: BLE001
        return None

    class BnWebSearch(WebSearchInterceptionLogger):
        async def try_short_circuit_search(self, model, messages, tools, custom_llm_provider, kwargs=None):
            try:
                # (the request came with Anthropic's web search: LiteLLM's mark of it is still there)
                if (isinstance(kwargs, Mapping) and kwargs.get(WEBSEARCH_EMIT_NATIVE_BLOCKS_KEY) is True
                        and isinstance(tools, list) and tools
                        and not any(isinstance(t, Mapping) and is_anthropic_native_web_search_tool(t) for t in tools)):
                    tools = [*tools, dict(NATIVE_WEB_SEARCH)]
            except Exception:  # noqa: BLE001 — as LiteLLM would have done it
                pass
            return await super().try_short_circuit_search(model, messages, tools, custom_llm_provider, kwargs=kwargs)

    return BnWebSearch(enabled_providers=list(SEARCH_PROVIDERS), search_tool_name=SEARCH_TOOL)


web_search = web_search_interception()
try:
    search_backend()   # (the backend's price, registered as LiteLLM loads this hook: before its first search)
except Exception:  # noqa: BLE001
    pass
