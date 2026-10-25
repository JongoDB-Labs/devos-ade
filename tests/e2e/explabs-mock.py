"""A stand-in for the Experiential Labs gateway, for tests/e2e/explabs.sh --mock (inside the throwaway LiteLLM container,
on 127.0.0.1 only; for its check of a slow catalog, on this computer's 127.0.0.1), split as the gateway is: GET
/v1/models (with a key) answers V1_JSON — the OpenAI list, ids and nothing else; GET /api/models/<id> (keyless: one
model of the public catalog) answers CATALOG_DIR/<id>.json, 404 without one — slowly (a few bytes every half second,
about 20 s in all) for an id SLOW_FILE lists, when that file exists. POST /v1/chat/completions and /v1/responses answer
like the gateway — "DevOS ADE test OK", usage with cost (USD) and is_byok (true for a model whose id holds "byok") —
streamed or not, and each request body is appended to a JSONL file for the script to check. A Chat Completions request
with a reasoning effort is answered with the model's reasoning too (reasoning_content, as the gateway's reasoning lanes
return it); one whose history carries LiteLLM's own fields (thinking_blocks, provider_specific_fields) is refused with
the gateway's 400 ("Invalid value for 'messages.3.thinking_blocks'"). Never the key: only "Bearer" is looked for in the
header.
Usage: python3 explabs-mock.py PORT LOG V1_JSON CATALOG_DIR [SLOW_FILE]
"""

import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PORT, LOG, V1, CATALOG = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
SLOW_FILE = sys.argv[5] if len(sys.argv) > 5 else ""
# what each answer "cost": not qwen3.8-27b's list price for 58 in / 48 out ($0.00013376, what the real gateway reported for
# that prompt), so the check can tell the gateway's figure from one LiteLLM computed
COST = 0.00042


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
            f.write(json.dumps({"path": self.path, "bearer": self.headers.get("Authorization", "").startswith("Bearer "),
                                "body": body}) + "\n")
        byok = "byok" in str(body.get("model", ""))
        cost = 0 if byok else COST
        now = int(time.time())
        if self.path.endswith("/responses"):
            usage = {"input_tokens": 58, "output_tokens": 48, "total_tokens": 106, "cost": cost, "is_byok": byok}
            resp = {"id": "resp_1", "object": "response", "created_at": now, "status": "completed", "model": body.get("model"),
                    "output": [{"type": "message", "id": "msg_1", "status": "completed", "role": "assistant",
                                "content": [{"type": "output_text", "text": "DevOS ADE test OK", "annotations": []}]}],
                    "usage": usage, "parallel_tool_calls": True, "tool_choice": "auto", "tools": []}
            if body.get("stream"):
                return self._sse([("response.created", {"type": "response.created", "response": {**resp, "status": "in_progress", "output": [], "usage": None}}),
                                  ("response.output_text.delta", {"type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": "DevOS ADE test OK"}),
                                  ("response.completed", {"type": "response.completed", "response": resp})])
            return self._json(200, resp)
        bad = _litellm_field(body.get("messages"))
        if bad:
            return self._json(400, {"error": {"message": f"Invalid value for '{bad}'", "type": "invalid_request_error",
                                              "param": bad, "code": "invalid_value"}})
        usage = {"prompt_tokens": 58, "completion_tokens": 48, "total_tokens": 106,
                 "completion_tokens_details": {"reasoning_tokens": 38}, "cost": cost, "is_byok": byok}
        if body.get("stream"):
            base = {"id": "gen-1", "object": "chat.completion.chunk", "created": now, "model": body.get("model")}
            return self._sse([("", {**base, "choices": [{"index": 0, "delta": {"content": "DevOS ADE "}, "finish_reason": None}]}),
                              ("", {**base, "choices": [{"index": 0, "delta": {"content": "test OK"}, "finish_reason": None}]}),
                              ("", {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}),
                              ("", {**base, "choices": [], "usage": usage, "provider": "experiential_cloud"})])
        message = {"role": "assistant", "content": "DevOS ADE test OK"}
        if body.get("reasoning_effort"):
            message["reasoning_content"] = "Thought about it"
        self._json(200, {"id": "gen-1", "object": "chat.completion", "created": now, "model": body.get("model"),
                         "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                         "usage": usage, "provider": "experiential_cloud"})


def _litellm_field(messages):
    """The first of LiteLLM's own fields in MESSAGES, as the gateway names it (messages.3.thinking_blocks), or None."""
    for i, m in enumerate(messages if isinstance(messages, list) else []):
        if not isinstance(m, dict):
            continue
        for k in ("thinking_blocks", "provider_specific_fields"):
            if m.get(k) is not None:
                return f"messages.{i}.{k}"
        for j, c in enumerate(m.get("tool_calls") or []):
            if isinstance(c, dict) and (c.get("provider_specific_fields") is not None or
                                        (c.get("function") or {}).get("provider_specific_fields") is not None):
                return f"messages.{i}.tool_calls.{j}.provider_specific_fields"
    return None


ThreadingHTTPServer(("127.0.0.1", PORT), Gateway).serve_forever()
