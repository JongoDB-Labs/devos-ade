"""A stand-in for the Experiential Labs gateway, for tests/e2e/explabs.sh --mock and tests/e2e/free-models.sh (inside the
throwaway LiteLLM container, on 127.0.0.1 only; for explabs.sh's check of a slow catalog, on this computer's 127.0.0.1),
split as the gateway is: GET
/v1/models (with a key) answers V1_JSON — the OpenAI list, ids and nothing else; GET /api/models/<id> (keyless: one
model of the public catalog) answers CATALOG_DIR/<id>.json, 404 without one — slowly (a few bytes every half second,
about 20 s in all) for an id SLOW_FILE lists, when that file exists. POST /v1/chat/completions and /v1/responses answer
like the gateway — "DevOS ADE test OK", usage with cost (USD; $0 for a free tier, "<id>:free") and is_byok (true for a
model whose id holds "byok") —
streamed or not, and each request body is appended to a JSONL file for the script to check. A Chat Completions request
with a reasoning effort is answered with the model's reasoning too (reasoning_content, as the gateway's reasoning lanes
return it); one whose history carries LiteLLM's own fields (thinking_blocks, provider_specific_fields) is refused with
the gateway's 400 ("Invalid value for 'messages.3.thinking_blocks'"). Every answer has an id of its own, as the gateway's
do: LiteLLM keys its spend log by it, and keeps only the first of two rows with one id. Never the key: only "Bearer" is
looked for in the header.
Its refusals are the gateway's (its llms.txt, read 2026-10-24, and what it answered on 2026-10-25), in its error envelope:
a message field outside OpenAI's Chat Completions ("Invalid value for 'messages.3.thinking_blocks'", 400 invalid_value:
the gateway refused LiteLLM's thinking_blocks so; any other unknown field of a message or a tool call is refused the
same way here, a strict reading), two tool calls with one id in an assistant turn (400), a tool description over
65,536 characters (400), a parameter the model's catalog entry does not list (top_k, frequency_penalty,
presence_penalty, top_logprobs; 400 unsupported_parameter), an image for a model whose catalog entry takes text only
(400 unsupported_capability, naming "messages"), a plugin other than "web" (400), a request without messages (400) and a
model the list does not have (403 model_not_granted). A user message holding PARITY-REFUSE is refused as a provider's policy refusal (400 refusal,
"provider refused the request: cybersecurity policy"), for the harness parity suite's error check.
With MOCK_RELAY (LiteLLM's base URL, its key in MOCK_RELAY_KEY: environment only) a request that passes is answered by
a real model, MOCK_RELAY_MODEL, through that LiteLLM's Chat Completions (tests/e2e/harness-parity.sh: Claude Code's
real sessions need a model that calls tools): the history goes without reasoning_content (the gateway drops it on a
lane that does not expose reasoning), the answer comes back under the model's own id with usage.cost 0 (the relayed
call is booked by that LiteLLM), its reasoning_content only for a deepseek model (the lanes that expose it); a request
that asks for a web search (web_search_options, the "web" plugin) is searched as the gateway does it, with fixed
results: fed to the model before the latest user turn, cited as url_citation annotations. With
MOCK_FLAVOR=openrouter it stands in for OpenRouter instead (tests/e2e/harness-parity.sh without a key): none of the
gateway's refusals (OpenRouter takes what it does not use), its own error envelope for PARITY-REFUSE, the reasoning
as "reasoning", as OpenRouter names it. GET /search answers as a SearXNG instance does (JSON), with the same fixed
results: a search provider for LiteLLM's web search interception.
Usage: python3 explabs-mock.py PORT LOG V1_JSON CATALOG_DIR [SLOW_FILE]
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT, LOG, V1, CATALOG = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
SLOW_FILE = sys.argv[5] if len(sys.argv) > 5 else ""
# what each answer "cost": not qwen3.8-27b's list price for 58 in / 48 out ($0.00013376, what the real gateway reported for
# that prompt), so the check can tell the gateway's figure from one LiteLLM computed
COST = 0.00042
RELAY, RELAY_MODEL = os.environ.get("MOCK_RELAY", ""), os.environ.get("MOCK_RELAY_MODEL", "")
FLAVOR = os.environ.get("MOCK_FLAVOR", "explabs")
# what its web search finds (a relayed call that asks for one; tests/e2e/harness-parity.py STAND_IN_FOUND names them)
SEARCH_RESULTS = ({"title": "IANA-managed Reserved Domains", "url": "https://www.iana.org/domains/reserved",
                   "text": "example.com, example.net and example.org are reserved for use in documentation."},
                  {"title": "Example Domain", "url": "https://example.com/", "text": "This domain is for use in documentation examples."})


class Gateway(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("x-gateway-provider", "experiential_cloud")
        self.end_headers()
        self.wfile.write(body)

    def _sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for name, data in events:
            self.wfile.write(((f"event: {name}\n" if name else "") + "data: " + json.dumps(data) + "\n\n").encode())
        if not events or not events[0][0]:
            self.wfile.write(b"data: [DONE]\n\n")

    def _slow(self, body):
        # the catalog as it was on 2026-10-25: the answer starts at once, then trickles in
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        step = max(1, len(body) // 40)
        try:
            for i in range(0, len(body), step):
                self.wfile.write(body[i:i + step])
                self.wfile.flush()
                time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/search":   # a SearXNG instance's JSON search (LiteLLM's searxng search provider): fixed results
            q = parse_qs(url.query).get("q", [""])[0]
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps({"t": time.time(), "path": "/search", "q": q}) + "\n")
            return self._json(200, {"query": q, "number_of_results": len(SEARCH_RESULTS),
                                    "results": [{"title": r["title"], "url": r["url"], "content": r["text"], "engine": "stand-in"} for r in SEARCH_RESULTS]})
        m = re.fullmatch(r"/api/models/([A-Za-z0-9][A-Za-z0-9._:-]{0,127})", url.path)
        if m:   # one model of the catalog: keyless
            path = os.path.join(CATALOG, m.group(1) + ".json")
            if not os.path.isfile(path):
                return self._json(404, {"error": "model not found"})
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
            slow = []
            if SLOW_FILE and os.path.isfile(SLOW_FILE):
                with open(SLOW_FILE, encoding="utf-8") as f:
                    slow = f.read().split()
            if m.group(1) in slow:
                return self._slow(json.dumps(doc).encode())
            return self._json(200, doc)
        if not self.headers.get("Authorization", "").startswith("Bearer "):
            return self._json(401, {"error": {"code": "invalid_key", "type": "authentication_error"}})
        if url.path == "/v1/models":
            with open(V1, encoding="utf-8") as f:
                return self._json(200, json.load(f))
        self._json(404, {"error": {"code": "not_found"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": time.time(), "path": self.path, "bearer": self.headers.get("Authorization", "").startswith("Bearer "),
                                "body": body}) + "\n")
        byok = "byok" in str(body.get("model", ""))
        gen = uuid.uuid4().hex[:24]   # (this answer's id)
        cost = 0 if byok or str(body.get("model", "")).endswith(":free") else COST
        now = int(time.time())
        if self.path.endswith("/responses"):
            usage = {"input_tokens": 58, "output_tokens": 48, "total_tokens": 106, "cost": cost, "is_byok": byok}
            resp = {"id": f"resp_{gen}", "object": "response", "created_at": now, "status": "completed", "model": body.get("model"),
                    "output": [{"type": "message", "id": "msg_1", "status": "completed", "role": "assistant",
                                "content": [{"type": "output_text", "text": "DevOS ADE test OK", "annotations": []}]}],
                    "usage": usage, "parallel_tool_calls": True, "tool_choice": "auto", "tools": []}
            if body.get("stream"):
                return self._sse([("response.created", {"type": "response.created", "response": {**resp, "status": "in_progress", "output": [], "usage": None}}),
                                  ("response.output_text.delta", {"type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": "DevOS ADE test OK"}),
                                  ("response.completed", {"type": "response.completed", "response": resp})])
            return self._json(200, resp)
        if not self.path.endswith("/responses") and not body.get("messages"):
            # (as the gateway and OpenRouter answer it: never relayed)
            return self._json(400, {"error": {"message": "Invalid 'messages': empty array. Expected an array with minimum length 1.",
                                              "type": "invalid_request_error", "param": "messages", "code": "invalid_request"}})
        refused = _refusal(body) if FLAVOR == "explabs" else None
        if refused:
            return self._json(*refused)
        if _asks_refusal(body.get("messages")):
            if FLAVOR == "openrouter":
                return self._json(400, {"error": {"code": 400, "message": "Provider returned error: content policy (stand-in)",
                                                  "metadata": {"provider_name": "Stand-in"}}})
            return self._json(400, {"error": {"message": "provider refused the request: cybersecurity policy",
                                              "type": "invalid_request_error", "param": None, "code": "refusal",
                                              "refusal_reason": "cyber_policy"}})
        if RELAY and RELAY_MODEL:
            return self._relay(body)
        usage = {"prompt_tokens": 58, "completion_tokens": 48, "total_tokens": 106,
                 "completion_tokens_details": {"reasoning_tokens": 38}, "cost": cost, "is_byok": byok}
        if body.get("stream"):
            base = {"id": f"gen-{gen}", "object": "chat.completion.chunk", "created": now, "model": body.get("model")}
            return self._sse([("", {**base, "choices": [{"index": 0, "delta": {"content": "DevOS ADE "}, "finish_reason": None}]}),
                              ("", {**base, "choices": [{"index": 0, "delta": {"content": "test OK"}, "finish_reason": None}]}),
                              ("", {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}),
                              ("", {**base, "choices": [], "usage": usage, "provider": "experiential_cloud"})])
        message = {"role": "assistant", "content": "DevOS ADE test OK"}
        if body.get("reasoning_effort"):
            message["reasoning_content"] = "Thought about it"
        self._json(200, {"id": f"gen-{gen}", "object": "chat.completion", "created": now, "model": body.get("model"),
                         "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                         "usage": usage, "provider": "experiential_cloud"})

    def _relay(self, body):
        """BODY answered by MOCK_RELAY_MODEL through LiteLLM's Chat Completions (streamed as it streams)."""
        want = body.get("model")
        # (what only the gateway or OpenRouter itself reads — OpenRouter's usage, transforms, provider routing — is not
        # the backing model's: left out of the relayed call)
        out = {**{k: v for k, v in body.items() if k not in _OWN_PARAMS}, "model": RELAY_MODEL,
               "messages": [{k: v for k, v in m.items() if k != "reasoning_content"} if isinstance(m, dict) else m
                            for m in body.get("messages") or []]}
        # a web search asked for (web_search_options, the "web" plugin): run by the gateway (or OpenRouter) itself, its
        # ranked results fed to the model before the latest user turn, cited as url_citation annotations
        searched = body.get("web_search_options") is not None or any(isinstance(p, dict) and p.get("id") == "web" for p in body.get("plugins") or [])
        if searched:
            out.pop("web_search_options", None)
            out.pop("plugins", None)
            last = max((i for i, m in enumerate(out["messages"]) if isinstance(m, dict) and m.get("role") == "user"), default=len(out["messages"]))
            out["messages"].insert(last, {"role": "system", "content": "Web search results for the latest user turn:\n" + "\n".join(
                f"[{i + 1}] {r['title']} — {r['url']}: {r['text']}" for i, r in enumerate(SEARCH_RESULTS))})
        req = urllib.request.Request(RELAY.rstrip("/") + "/v1/chat/completions", data=json.dumps(out).encode(), method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + os.environ.get("MOCK_RELAY_KEY", "")})
        try:
            resp = urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as e:
            # (the backing model's error, as the gateway would relay a provider's: all_routes_failed)
            text = e.read().decode("utf-8", "replace")[:2000]
            return self._json(502 if e.code >= 500 else e.code, {"error": {"message": f"stand-in's backing model: {text}",
                                                                           "type": "api_error", "code": "all_routes_failed"}})
        except (urllib.error.URLError, OSError) as e:
            return self._json(502, {"error": {"message": f"stand-in's backing model: {e}", "type": "api_error",
                                              "code": "all_routes_failed"}})
        keep = FLAVOR == "openrouter" or str(want).startswith("deepseek")
        cites = [{"type": "url_citation", "url_citation": {"url": r["url"], "title": r["title"], "start_index": 0, "end_index": 0}}
                 for r in SEARCH_RESULTS] if searched else []
        if not body.get("stream"):
            doc = json.loads(resp.read() or b"{}")
            doc["model"] = want
            for c in doc.get("choices") or []:
                _reasoning(c.get("message"), keep)
                if cites and isinstance(c.get("message"), dict):
                    c["message"]["annotations"] = cites
            if isinstance(doc.get("usage"), dict):
                doc["usage"].update(cost=0, is_byok=False)
                if searched:
                    doc["usage"]["server_tool_use_details"] = {"web_search_requests": 1}
            return self._json(200, doc)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            for line in resp:
                if line.startswith(b"data: {"):
                    try:
                        doc = json.loads(line[6:])
                    except ValueError:
                        doc = None
                    if isinstance(doc, dict):
                        doc["model"] = want
                        for c in doc.get("choices") or []:
                            _reasoning(c.get("delta"), keep)
                        if isinstance(doc.get("usage"), dict):
                            doc["usage"].update(cost=0, is_byok=False)
                            if searched:
                                doc["usage"]["server_tool_use_details"] = {"web_search_requests": 1}
                        if cites and doc.get("choices"):   # (one delta.annotations chunk, as the gateway sends)
                            d = doc["choices"][0].setdefault("delta", {})
                            if isinstance(d, dict):
                                d["annotations"] = cites
                            cites = []
                        line = b"data: " + json.dumps(doc).encode() + b"\n"
                self.wfile.write(line)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def _reasoning(m, keep):
    """M (a message or a delta) with its reasoning as the gateway or OpenRouter returns it: left out for a lane that does
    not expose it, "reasoning" for OpenRouter."""
    if not isinstance(m, dict) or "reasoning_content" not in m:
        return
    r = m.pop("reasoning_content")
    m.pop("thinking_blocks", None)
    m.pop("provider_specific_fields", None)
    if keep and r:
        m["reasoning" if FLAVOR == "openrouter" else "reasoning_content"] = r


# The gateway's and OpenRouter's own request parameters (never relayed to the backing model)
_OWN_PARAMS = frozenset(("usage", "transforms", "provider", "route", "models", "plugins", "web_search_options"))
# A message's fields in OpenAI's Chat Completions (and the gateway's reasoning_content); a tool call's
_MESSAGE_KEYS = frozenset(("role", "content", "name", "tool_calls", "tool_call_id", "refusal", "audio", "function_call",
                           "reasoning_content"))
_CALL_KEYS = frozenset(("id", "type", "function", "custom"))
_ASKABLE = ("top_k", "frequency_penalty", "presence_penalty", "top_logprobs")


def _err(code, message, param=None, status=400):
    return status, {"error": {"message": message, "type": "invalid_request_error", "param": param, "code": code}}


def _catalog(model):
    try:
        with open(os.path.join(CATALOG, f"{model}.json"), encoding="utf-8") as f:
            return json.load(f).get("model") or {}
    except (OSError, ValueError, AttributeError):
        return None


def _refusal(body):
    """The gateway's answer to a request it refuses ((status, envelope)), or None."""
    model = body.get("model")
    with open(V1, encoding="utf-8") as f:
        ids = {m.get("id") for m in json.load(f).get("data") or []}
    base = model.removesuffix(":free") if isinstance(model, str) else model   # (a free tier: its slug's model)
    if model not in ids and base not in ids:
        return _err("model_not_granted", f"model {model!r} is not granted to this organization", "model", 403)
    info = _catalog(base) or {}
    supported = info.get("supported_params") or {}
    for p in _ASKABLE:
        if body.get(p) is not None and supported.get(p) is not True:
            return _err("unsupported_parameter", f"{p} is not supported by {model}", p)
    for p in body.get("plugins") or []:
        if not isinstance(p, dict) or p.get("id") != "web":
            return _err("invalid_parameter", "only the web plugin is served", "plugins")
    for i, t in enumerate(body.get("tools") or []):
        d = ((t or {}).get("function") or {}).get("description") if isinstance(t, dict) else None
        if isinstance(d, str) and len(d) > 65536:
            return _err("invalid_parameter", "tool description is longer than 65,536 characters", f"tools.{i}.function.description")
    text_only = info.get("input_modalities") == ["text"]
    for i, m in enumerate(body.get("messages") or []):
        if not isinstance(m, dict):
            return _err("invalid_request", f"messages.{i} is not an object", f"messages.{i}")
        for k, v in m.items():
            if k not in _MESSAGE_KEYS and v is not None:
                return _err("invalid_value", f"Invalid value for 'messages.{i}.{k}'", f"messages.{i}.{k}")
        seen = set()
        for j, c in enumerate(m.get("tool_calls") or []):
            if not isinstance(c, dict):
                continue
            for k, v in c.items():
                if k not in _CALL_KEYS and v is not None:
                    return _err("invalid_value", f"Invalid value for 'messages.{i}.tool_calls.{j}.{k}'", f"messages.{i}.tool_calls.{j}.{k}")
            f = c.get("function")
            for k, v in (f.items() if isinstance(f, dict) else ()):
                if k not in ("name", "arguments") and v is not None:
                    return _err("invalid_value", f"Invalid value for 'messages.{i}.tool_calls.{j}.function.{k}'", f"messages.{i}.tool_calls.{j}.function.{k}")
            if c.get("id") in seen:
                return _err("invalid_request", f"duplicate tool call id {c.get('id')!r} in messages.{i}: fix the history", f"messages.{i}.tool_calls")
            seen.add(c.get("id"))
        if text_only and isinstance(m.get("content"), list) and any(isinstance(p, dict) and p.get("type") == "image_url" for p in m["content"]):
            return _err("unsupported_capability", f"{model} does not take image input (messages)", "messages")
    return None


def _asks_refusal(messages):
    """Whether a user message holds PARITY-REFUSE (the parity suite's provider-error check)."""
    return any(isinstance(m, dict) and m.get("role") == "user" and "PARITY-REFUSE" in json.dumps(m.get("content"))
               for m in messages or [])


ThreadingHTTPServer(("127.0.0.1", PORT), Gateway).serve_forever()
