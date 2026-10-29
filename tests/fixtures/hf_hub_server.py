"""tests/fixtures/hf_hub_server.py ROOT PORTFILE LOG — a stand-in Hugging Face Hub for lib/hf_fetch.py's tests, on 127.0.0.1
(a free port, written to PORTFILE). GET /<org>/<name>/resolve/<sha>/<path> answers 302 to http://localhost:<port>/cdn/<path>
(another host name, as the Hub's CDN is: the token must not follow), and /cdn/<path> serves ROOT/<path>, with Range.
ROOT/.slow holds bytes a second to send at (absent: all at once). GET /api/models/<org>/<name>/revision/main answers
ROOT/.api.json (the model's info, as the Hub's API gives it with ?blobs=true), or the status code ROOT/.api.code holds. Every request's path, Authorization header and Range header go
to LOG, one line each, tab-separated ("-" for a header that was not sent). It ends by itself when the test that started it
does (its parent process changes), and after two minutes in any case: a failed test never leaves it behind."""

import http.server
import os
import sys
import threading
import time
import urllib.parse

ROOT, PORTFILE, LOG = sys.argv[1:4]


class Hub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{self.path}\t{self.headers.get('Authorization', '-')}\t{self.headers.get('Range', '-')}\n")
        if self.path.startswith("/api/models/"):
            try:
                code = int(open(os.path.join(ROOT, ".api.code")).read().strip())
            except (OSError, ValueError):
                code = 200
            data = open(os.path.join(ROOT, ".api.json"), "rb").read() if code == 200 else b"{}"
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if "/resolve/" in self.path:
            rest = self.path.split("/resolve/", 1)[1].split("/", 1)[1]
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_port}/cdn/{rest}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path = os.path.join(ROOT, urllib.parse.unquote(self.path[len("/cdn/"):]))
        if not self.path.startswith("/cdn/") or not os.path.isfile(path):
            self.send_error(404)
            return
        data = open(path, "rb").read()
        rng, start = self.headers.get("Range"), 0
        if rng and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0] or 0)
        if start >= len(data) > 0:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{len(data)}")
            self.end_headers()
            return
        self.send_response(206 if rng else 200)
        if rng:
            self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        self.send_header("Content-Length", str(len(data) - start))
        self.end_headers()
        try:
            bps = int(open(os.path.join(ROOT, ".slow")).read().strip())
        except (OSError, ValueError):
            bps = 0
        body = data[start:]
        step = max(1, bps // 20) if bps else len(body)
        try:
            for i in range(0, len(body), step or 1):
                self.wfile.write(body[i:i + step])
                if bps:
                    self.wfile.flush()
                    time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hub)
srv.daemon_threads = True
with open(PORTFILE + ".tmp", "w", encoding="utf-8") as f:
    f.write(str(srv.server_port))
os.replace(PORTFILE + ".tmp", PORTFILE)


def _watch(parent=os.getppid(), until=time.monotonic() + 120):
    while os.getppid() == parent and time.monotonic() < until:
        time.sleep(0.5)
    srv.shutdown()


threading.Thread(target=_watch, daemon=True).start()
srv.serve_forever()
