"""A stand-in for the Experiential Labs gateway, for tests/e2e/explabs.sh --mock (inside the throwaway LiteLLM container,
on 127.0.0.1 only): GET /v1/models answers the fixture; POST /v1/chat/completions and /v1/responses answer like the
gateway — "DevOS ADE test OK", usage with cost (USD) and is_byok (true for a model whose id holds "byok") — streamed
or not, and each request body is appended to a JSONL file for the script to check. Never the key: only "Bearer" is
looked for in the header. Usage: python3 explabs-mock.py PORT LOG MODELS_JSON
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG, MODELS = int(sys.argv[1]), sys.argv[2], sys.argv[3]
COST = 0.00013376   # what the real gateway reported for this prompt on qwen3.8-27b: 58 in, 48 out


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

    def do_GET(self):
        if not self.headers.get("Authorization", "").startswith("Bearer "):
            return self._json(401, {"error": {"code": "invalid_key", "type": "authentication_error"}})
        if self.path.rstrip("/").endswith("/models"):
            with open(MODELS, encoding="utf-8") as f:
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
        usage = {"prompt_tokens": 58, "completion_tokens": 48, "total_tokens": 106,
                 "completion_tokens_details": {"reasoning_tokens": 38}, "cost": cost, "is_byok": byok}
        if body.get("stream"):
            base = {"id": "gen-1", "object": "chat.completion.chunk", "created": now, "model": body.get("model")}
            return self._sse([("", {**base, "choices": [{"index": 0, "delta": {"content": "DevOS ADE "}, "finish_reason": None}]}),
                              ("", {**base, "choices": [{"index": 0, "delta": {"content": "test OK"}, "finish_reason": None}]}),
                              ("", {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}),
                              ("", {**base, "choices": [], "usage": usage, "provider": "experiential_cloud"})])
        self._json(200, {"id": "gen-1", "object": "chat.completion", "created": now, "model": body.get("model"),
                         "choices": [{"index": 0, "message": {"role": "assistant", "content": "DevOS ADE test OK"}, "finish_reason": "stop"}],
                         "usage": usage, "provider": "experiential_cloud"})


ThreadingHTTPServer(("127.0.0.1", PORT), Gateway).serve_forever()
