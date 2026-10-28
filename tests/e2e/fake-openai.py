"""A tiny OpenAI-compatible server for tests/e2e/model-servers.sh (standard library only): GET /v1/models and POST
/v1/chat/completions; with FAKE_KEY set it wants that bearer key (401 otherwise). It answers with a fixed sentence."""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

KEY = os.environ.get("FAKE_KEY", "")


class H(BaseHTTPRequestHandler):
    def _ok(self):
        if KEY and self.headers.get("Authorization") != f"Bearer {KEY}":
            self._send(401, {"error": {"message": "bad key"}})
            return False
        return True

    def _send(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models" and self._ok():
            self._send(200, {"object": "list", "data": [{"id": "fake/tiny-chat", "object": "model", "max_model_len": 8192}]})
        elif self.path.rstrip("/") != "/v1/models":
            self._send(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        if self.path.rstrip("/") == "/v1/chat/completions" and self._ok():
            self._send(200, {"id": "x", "object": "chat.completion", "created": 1, "model": "fake/tiny-chat",
                             "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "Hello from the fake server"}}],
                             "usage": {"prompt_tokens": 3, "completion_tokens": 5, "total_tokens": 8}})

    def log_message(self, *a):
        pass


HTTPServer(("0.0.0.0", 8000), H).serve_forever()
