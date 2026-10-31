# shellcheck shell=bash
# Open WebUI's own image (open-webui/): the pinned Open WebUI with the Python runner's packages vendored into it —
# vendor.py's lock rewrite (only verified wheels, and only with all they need, get a relative name), its bounds, one
# pin everywhere, compose's local name that no pull can replace, the build's retry and the status line. No Docker:
# vendor.py runs here with a fake download.
. "$STACK_DIR/lib/commands.sh"

OWUI="$STACK_DIR/open-webui"

# _vendor_py SCRIPT — runs SCRIPT (Python, on stdin) with vendor.py loaded as `v` (isolated: python3 -I)
_vendor_py() {
  command -v python3 >/dev/null || return 77
  python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("v", sys.argv[1])
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
exec(sys.stdin.read())' "$OWUI/vendor.py"
}

test_vendor_rewrites_only_verified_wheels_with_all_they_need() {
  _vendor_py <<'PY' || return $?
import hashlib, json, os, tempfile
sha = lambda b: hashlib.sha256(b).hexdigest()
CDN = "https://cdn.jsdelivr.net/pyodide/v1/full/"
blobs = {"a": b"wheel a", "b": b"wheel b", "c": b"wheel c", "bad": b"not what the lock says", "needsbad": b"wheel nb", "other": b"x"}
lock = {"info": {"python": "3.14"}, "packages": {
  "a": {"file_name": CDN + "a-1-py3-none-any.whl", "sha256": sha(blobs["a"]), "depends": ["b"]},
  "b": {"file_name": CDN + "b-1-py3-none-any.whl", "sha256": sha(blobs["b"]), "depends": []},
  "c": {"file_name": CDN + "c-1-py3-none-any.whl", "sha256": sha(blobs["c"]), "depends": ["gone"]},
  "bad": {"file_name": CDN + "bad-1-py3-none-any.whl", "sha256": sha(b"the lock's own bytes"), "depends": []},
  "needsbad": {"file_name": CDN + "needsbad-1-py3-none-any.whl", "sha256": sha(blobs["needsbad"]), "depends": ["bad"]},
  "odd": {"file_name": CDN + "..%2fpyodide.js", "sha256": sha(b"x"), "depends": []},
  "own": {"file_name": CDN + "own-1-py3-none-any.whl", "sha256": sha(b"x"), "depends": []},
  "untouched": {"file_name": CDN + "untouched-1-py3-none-any.whl", "sha256": sha(b"u"), "depends": []},
  "offline": {"file_name": CDN + "offline-1-py3-none-any.whl", "sha256": sha(b"o"), "depends": []},
}}
asked = []
def fetch(url, limit):
    asked.append(url)
    name = url.rsplit("/", 1)[1].split("-")[0]
    if name == "offline":
        raise OSError("network unreachable\tnow\n")
    return blobs[name]
dest, tmp = tempfile.mkdtemp(), tempfile.mkdtemp()
open(os.path.join(dest, "pyodide.asm.wasm"), "wb").write(b"the runtime's own")
open(os.path.join(dest, "own-1-py3-none-any.whl"), "wb").write(b"the image's own")
new, rep = v.vendor(lock, ["a", "c", "needsbad", "odd", "own", "offline", "nope"], dest, fetch=fetch, tmp=tmp)
ready = [r["name"] for r in rep["ready"]]
why = {x["name"]: x["why"] for x in rep["left_out"]}
assert ready == ["b", "a"], ready
# a relative name only for the verified wheels (with everything they need); every other package keeps its CDN URL
assert new["packages"]["a"]["file_name"] == "a-1-py3-none-any.whl"
assert new["packages"]["b"]["file_name"] == "b-1-py3-none-any.whl"
for n in ["c", "bad", "needsbad", "odd", "own", "untouched", "offline"]:
    assert new["packages"][n]["file_name"] == lock["packages"][n]["file_name"], n
assert lock["packages"]["a"]["file_name"].startswith(CDN), "the lock read is never changed in place"
# why each was left out
assert why["bad"] == "its sha256 does not match the lock's", why
assert why["needsbad"] == "needs bad, left out", why
assert why["gone"] == "not in the image's pyodide-lock.json", why
assert why["c"] == "needs gone, left out", why
assert why["odd"] == "its file name in the lock is not a plain wheel name", why
assert why["own"] == "its file name is one of the runtime's own files", why
assert why["nope"] == "not in the image's pyodide-lock.json", why
assert why["offline"].startswith("download failed (OSError: network unreachable now "), why
assert "\t" not in why["offline"] and "\n" not in why["offline"]
# only the ready wheels are in the folder (the runtime's own file untouched); nothing else was downloaded for them
assert sorted(os.listdir(dest)) == ["a-1-py3-none-any.whl", "b-1-py3-none-any.whl", "own-1-py3-none-any.whl", "pyodide.asm.wasm"], os.listdir(dest)
assert open(os.path.join(dest, "pyodide.asm.wasm"), "rb").read() == b"the runtime's own"
assert open(os.path.join(dest, "own-1-py3-none-any.whl"), "rb").read() == b"the image's own"
assert not any("odd" in u or "own-1" in u or "untouched" in u for u in asked), asked
assert rep["bytes"] == len(blobs["a"]) + len(blobs["b"])
# the status lines: ready / left, tab-separated, printable
lines = v.summary(rep).splitlines()
assert lines[0] == "ready\tb\t7" and lines[1] == "ready\ta\t7", lines
assert "left\tbad\tits sha256 does not match the lock's" in lines
PY
}

test_vendor_main_writes_only_its_files_and_keeps_going_offline() {
  _vendor_py <<'PY' || return $?
import hashlib, json, os, tempfile, urllib.error
sha = lambda b: hashlib.sha256(b).hexdigest()
dest = tempfile.mkdtemp()
lock = {"info": {"python": "3.14"}, "packages": {
  "micropip": {"file_name": "https://cdn.example/full/micropip-0.1-py3-none-any.whl", "sha256": sha(b"m"), "depends": []},
  "numpy": {"file_name": "https://cdn.example/full/numpy-2-cp314-wasm32.whl", "sha256": sha(b"n"), "depends": []}}}
json.dump(lock, open(os.path.join(dest, "pyodide-lock.json"), "w"))
lst = os.path.join(tempfile.mkdtemp(), "packages.txt")
open(lst, "w").write("# a comment\nmicropip\n\nNumPy  # case and comments\nmicropip\n")
assert v.wanted(open(lst).read()) == ["micropip", "numpy"]
# offline: every download fails — the image still works without them, and says so
def offline(url, limit):
    raise urllib.error.URLError("no network")
v.fetch_url = offline
assert v.main(["vendor.py", dest, lst]) == 0
assert json.load(open(os.path.join(dest, "pyodide-lock.json"))) == lock, "nothing vendored: the lock as it was"
assert sorted(os.listdir(dest)) == ["pyodide-lock.json", "vendored.json", "vendored.txt"], os.listdir(dest)
rep = json.load(open(os.path.join(dest, "vendored.json")))
assert rep["ready"] == [] and [x["name"] for x in rep["left_out"]] == ["micropip", "numpy"], rep
assert all(x["why"].startswith("download failed") for x in rep["left_out"])
# online (one verified, one not): the lock names the verified one by its bare name
v.fetch_url = lambda url, limit: b"m" if "micropip" in url else b"tampered"
assert v.main(["vendor.py", dest, lst]) == 0
new = json.load(open(os.path.join(dest, "pyodide-lock.json")))
assert new["packages"]["micropip"]["file_name"] == "micropip-0.1-py3-none-any.whl"
assert new["packages"]["numpy"]["file_name"] == lock["packages"]["numpy"]["file_name"]
assert open(os.path.join(dest, "vendored.txt")).read() == "ready\tmicropip\t1\nleft\tnumpy\tits sha256 does not match the lock's\n"
assert not [f for f in os.listdir(dest) if f.endswith(".bn-new")]
# a lock that cannot be read: nothing vendored, said, and no failure
os.remove(os.path.join(dest, "pyodide-lock.json"))
assert v.main(["vendor.py", dest, lst]) == 0
assert "pyodide-lock.json" not in os.listdir(dest)
assert all(x["why"] == "the image's pyodide-lock.json has no packages" for x in json.load(open(os.path.join(dest, "vendored.json")))["left_out"])
# with a folder of its own for what was done (the Dockerfile's: outside what Open WebUI serves): nothing of it beside the wheels
dest2, rd = tempfile.mkdtemp(), os.path.join(tempfile.mkdtemp(), "bn-vendor")
json.dump(lock, open(os.path.join(dest2, "pyodide-lock.json"), "w"))
assert v.main(["vendor.py", dest2, lst, rd]) == 0
assert sorted(os.listdir(rd)) == ["vendored.json", "vendored.txt"] and not [f for f in os.listdir(dest2) if f.startswith("vendored")], os.listdir(dest2)
PY
}

test_vendor_downloads_are_bounded_https_only() {
  _vendor_py <<'PY' || return $?
import hashlib, io, os, tempfile, time, urllib.error, urllib.request
for url in ["http://cdn.example/a.whl", "file:///etc/passwd", "ftp://x/a.whl", "data:,x"]:
    try:
        v.fetch_url(url, 10)
        raise AssertionError("fetched " + url)
    except ValueError as e:
        assert "https" in str(e), e
class Body(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False
seen = {}
body = {"b": b"x" * 1000}
class Opener:
    def __init__(self, handlers): seen["handlers"] = handlers
    def open(self, url, timeout):
        seen["timeout"] = timeout
        return Body(body["b"])
urllib.request.build_opener = lambda *h: Opener(h)
assert v.fetch_url("https://cdn.example/a.whl", 1000) == b"x" * 1000
assert seen["timeout"] == v.DOWNLOAD_TIMEOUT_S
# (redirects: only to https on the lock's own host and port)
same = [h for h in seen["handlers"] if isinstance(h, v._SameHost)][0]
class Req:
    full_url = "https://cdn.example/full/a.whl"
    def get_method(self): return "GET"
    headers = {}
    unredirected_hdrs = {}
    origin_req_host = "cdn.example"
    unverifiable = False
    data = None
for bad in ["http://cdn.example/a.whl", "https://evil.example/a.whl", "https://cdn.example:8443/a.whl", "//evil.example/a.whl", "ftp://cdn.example/a"]:
    try:
        same.redirect_request(Req(), None, 302, "Found", {}, bad)
        raise AssertionError("followed " + bad)
    except urllib.error.HTTPError as e:
        assert "away from the lock" in str(e.msg), e
assert same.redirect_request(Req(), None, 302, "Found", {}, "https://cdn.example/other/a.whl").full_url == "https://cdn.example/other/a.whl"
assert same.redirect_request(Req(), None, 302, "Found", {}, "https://CDN.example/b.whl") is not None
# (a whole download: within DOWNLOAD_DEADLINE_S, however slowly each read comes)
clock = {"t": 0.0}
def tick():
    clock["t"] += 100.0
    return clock["t"]
real_monotonic = time.monotonic   # (the module is the test's own too: put back below)
v.time.monotonic = tick
body["b"] = b"x" * (1 << 20)
try:
    v.fetch_url("https://cdn.example/a.whl", 2 << 20)
    raise AssertionError("past the deadline")
except TimeoutError as e:
    assert "within" in str(e)
v.time.monotonic = real_monotonic
body["b"] = b"x" * 1000
# (a server that drips a byte at a time, each read well within its timeout: the watchdog ends it at the deadline)
class Drip(Body):
    def read(self, n=-1):
        time.sleep(0.25)
        return b"x"
class DripOpener:
    def __init__(self, handlers): pass
    def open(self, url, timeout):
        seen["drip_timeout"] = timeout
        return Drip(b"")
urllib.request.build_opener = lambda *h: DripOpener(h)
t0 = time.monotonic()
try:
    v.fetch_url("https://cdn.example/a.whl", 1 << 20, deadline_s=1)
    raise AssertionError("a drip outlasted the deadline")
except TimeoutError as e:
    assert "within 1 s" in str(e), e
assert time.monotonic() - t0 < 2, time.monotonic() - t0
assert seen["drip_timeout"] <= 1, seen["drip_timeout"]   # (the socket's timeout: never past the time left)
import signal
assert signal.getitimer(signal.ITIMER_REAL)[0] == 0.0, "the watchdog left running"
assert signal.getsignal(signal.SIGALRM) == signal.SIG_DFL, "SIGALRM's handler not put back"
urllib.request.build_opener = lambda *h: Opener(h)
try:
    v.fetch_url("https://cdn.example/a.whl", 999)
    raise AssertionError("past the cap")
except ValueError as e:
    assert "larger than" in str(e)
# the caps: each wheel, and all of them
assert v.FILE_MAX <= 64 << 20 and v.TOTAL_MAX <= 128 << 20
got = []
lock = {"packages": {n: {"file_name": f"https://c/{n}-1-py3-none-any.whl", "sha256": hashlib.sha256(b"z").hexdigest(), "depends": []} for n in "pq"}}
v.vendor(lock, ["p", "q"], tempfile.mkdtemp(), fetch=lambda url, limit: got.append(limit) or b"z", tmp=tempfile.mkdtemp())
assert got == [v.FILE_MAX, min(v.FILE_MAX, v.TOTAL_MAX - 1)], got
# a file name two packages of the lock name: both left out, said — never a crash, nothing moved over another
z = hashlib.sha256(b"z").hexdigest()
lock = {"packages": {"p": {"file_name": "https://c/a/same-1-py3-none-any.whl", "sha256": z, "depends": []},
                     "q": {"file_name": "https://c/b/same-1-py3-none-any.whl", "sha256": z, "depends": []},
                     "r": {"file_name": "https://c/r-1-py3-none-any.whl", "sha256": z, "depends": []}}}
dest = tempfile.mkdtemp()
new, rep = v.vendor(lock, ["p", "q", "r"], dest, fetch=lambda url, limit: b"z", tmp=tempfile.mkdtemp())
assert [r["name"] for r in rep["ready"]] == ["r"], rep
assert {x["name"]: x["why"] for x in rep["left_out"]} == {"p": "its file name is another package's in the lock too", "q": "its file name is another package's in the lock too"}
assert new["packages"]["p"]["file_name"].startswith("https://") and os.listdir(dest) == ["r-1-py3-none-any.whl"]
# (a deadline that reaches the loop itself — the watchdog's own exception: a failed download, never out of vendor())
def late(url, limit):
    raise v.DownloadDeadline()
_, rep = v.vendor({"packages": {"p": {"file_name": "https://c/p-1-py3-none-any.whl", "sha256": z, "depends": []}}}, ["p"], tempfile.mkdtemp(), fetch=late, tmp=tempfile.mkdtemp())
assert rep["ready"] == [] and rep["left_out"][0]["why"].startswith("download failed (DownloadDeadline"), rep
PY
}

# Downloads over real HTTPS (http.client, a local server with a certificate made here): a body with a Content-Length,
# and a chunked one, read to their end (the socket closed under it by then: nothing touches it after); a server that
# drips a byte every 0.25 s cut at the deadline, 64 KiB reads and all; a name whose every address hangs, cut at the
# deadline too (the watchdog's exception is no OSError: socket.create_connection's loop over addresses cannot swallow
# it); and a timer of the caller's put back after
test_vendor_downloads_over_real_https_end_and_are_cut_at_the_deadline() {
  command -v openssl >/dev/null || { echo "no openssl" >&2; return 77; }
  local d; d="$(mktemp -d "$TMP/tls.XXXXXX")"
  openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -addext "subjectAltName=DNS:localhost" -days 1 \
    -keyout "$d/k" -out "$d/c" >/dev/null 2>&1 || { echo "openssl could not make a certificate" >&2; return 77; }
  BN_TEST_CERT="$d/c" BN_TEST_KEY="$d/k" _vendor_py <<'PY' || return $?
import http.server, os, signal, socket, ssl, threading, time
BODY = os.urandom(300 * 1024)
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/cl.whl":
            self.send_response(200); self.send_header("Content-Length", str(len(BODY))); self.end_headers(); self.wfile.write(BODY)
        elif self.path == "/chunked.whl":
            self.send_response(200); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            for i in range(0, len(BODY), 40000):
                part = BODY[i:i + 40000]
                self.wfile.write(b"%x\r\n" % len(part) + part + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        elif self.path == "/drip.whl":
            self.send_response(200); self.send_header("Content-Length", str(1 << 20)); self.end_headers()
            try:
                for _ in range(40):
                    self.wfile.write(b"x"); self.wfile.flush(); time.sleep(0.25)
            except OSError:
                pass
        else:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); sctx.load_cert_chain(os.environ["BN_TEST_CERT"], os.environ["BN_TEST_KEY"])
srv.socket = sctx.wrap_socket(srv.socket, server_side=True)
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]
# (this certificate trusted for the test's own requests: what urllib's default context would be)
ssl._create_default_https_context = lambda *a, **k: ssl.create_default_context(cafile=os.environ["BN_TEST_CERT"])
base = f"https://localhost:{port}"
# a caller's timer (the build has none: the test checks it is put back)
signal.signal(signal.SIGALRM, lambda *a: None)
signal.setitimer(signal.ITIMER_REAL, 50)
# read to their end — a Content-Length body and a chunked one (http.client closes the socket under each)
assert v.fetch_url(base + "/cl.whl", 1 << 20) == BODY
assert v.fetch_url(base + "/chunked.whl", 1 << 20) == BODY
# (the caller's timer goes on with what was left of it)
left, _ = signal.getitimer(signal.ITIMER_REAL)
assert 40 < left <= 50, left
# a byte every 0.25 s, 64 KiB reads: cut at the deadline
t0 = time.monotonic()
try:
    v.fetch_url(base + "/drip.whl", 2 << 20, deadline_s=1)
    raise AssertionError("a drip outlasted the deadline")
except TimeoutError as e:
    assert "within 1 s" in str(e), e
took = time.monotonic() - t0
assert 0.9 < took < 2.5, took
# a name whose every address hangs (nine of them, 1 s each): cut at the deadline, never one address after another
real_gai, real_connect = socket.getaddrinfo, socket.socket.connect
def gai(host, *a, **k):
    if host == "hang.test":
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 9))] * 9
    return real_gai(host, *a, **k)
def hang(self, addr):
    time.sleep(1)
    raise TimeoutError("timed out")
socket.getaddrinfo, socket.socket.connect = gai, hang
t0 = time.monotonic()
try:
    v.fetch_url("https://hang.test/a.whl", 1 << 20, deadline_s=1.5)
    raise AssertionError("a hanging name was not cut")
except TimeoutError as e:
    assert "within 1.5 s" in str(e), e
finally:
    socket.getaddrinfo, socket.socket.connect = real_gai, real_connect
took = time.monotonic() - t0
assert took < 2.5, f"{took:.1f} s: the addresses were tried one after another"
left, _ = signal.getitimer(signal.ITIMER_REAL)
assert 0 < left <= 50, left
signal.setitimer(signal.ITIMER_REAL, 0)
srv.shutdown()
PY
}

test_open_webui_one_pin_everywhere_and_a_local_image_no_pull_replaces() {
  local pin dflt tag svc
  # compose.yaml's build argument, the Dockerfile's default, the e2e's tested version: one pin, a tag and a digest
  svc="$(awk '/^  open-webui:$/ { f = 1; next } f && /^  [a-z]/ { f = 0 } f' "$STACK_DIR/compose.yaml")"
  pin="$(printf '%s\n' "$svc" | sed -n 's/^ *image: \(ghcr\.io\/open-webui\/open-webui:[^ ]*\)$/\1/p')"
  grep -qE '^ghcr\.io/open-webui/open-webui:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$' <<< "$pin" || { echo "pin: $pin" >&2; return 1; }
  dflt="$(sed -n 's/^ARG image=\(.*\)$/\1/p' "$OWUI/Dockerfile")"
  assert_eq "$dflt" "$pin"
  assert_contains "$(cat "$OWUI/Dockerfile")" 'FROM ${image}'
  tag="${pin#ghcr.io/open-webui/open-webui:}"; tag="${tag%@*}"
  assert_contains "$(cat "$STACK_DIR/tests/e2e/browser/common.py")" "\"open-webui\": \"$tag\""
  # (the e2e reads it from compose.yaml as before: its tag)
  assert_eq "$(sed -n "s|^[[:space:]]*image:[[:space:]]*[^[:space:]]*open-webui/open-webui:\\([^@[:space:]]*\\).*|\\1|p" "$STACK_DIR/compose.yaml" | head -n 1)" "$tag"
  # a local image of this project, built here, never pulled
  assert_contains "$svc" 'image: ${COMPOSE_PROJECT_NAME:-devos-ade}/open-webui:local'
  assert_contains "$svc" 'pull_policy: never'
  assert_contains "$svc" 'context: ./open-webui'
  # no other reference to Open WebUI's registry image anywhere in compose files
  assert_eq "$(grep -h 'open-webui/open-webui' "$STACK_DIR"/compose*.yaml | wc -l | tr -d ' ')" 1
  # what the build runs: vendor.py, isolated, on Pyodide's folder; nothing else copied in
  assert_contains "$(cat "$OWUI/Dockerfile")" 'python3 -I /tmp/bn-vendor/vendor.py /app/build/pyodide /tmp/bn-vendor/packages.txt /opt/bn-vendor'
  # (Pyodide's console pages: never on the public route)
  assert_contains "$(cat "$OWUI/Dockerfile")" 'rm -f /app/build/pyodide/console.html /app/build/pyodide/console-v2.html'
  assert_eq "$(grep -c '^COPY' "$OWUI/Dockerfile" | tr -d ' ')" 1
  assert_contains "$(cat "$OWUI/Dockerfile")" 'COPY vendor.py packages.txt /tmp/bn-vendor/'
  # the default packages
  assert_eq "$(grep -v '^#' "$OWUI/packages.txt" | grep . | tr '\n' ' ')" "micropip numpy pandas matplotlib "
}

test_owui_build_tries_again_only_after_a_failed_download_and_keeps_its_try() {
  STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR/status"
  building() { shift; "$@"; }
  dc() { echo "dc $*" >> "$TMP/dc"; }
  python_runner_status() { :; }
  date() { echo 2026102509; }
  owui_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=0 open-webui"
  : > "$TMP/dc"
  printf 'ready\tmicropip\t1\nleft\tnumpy\tdownload failed (URLError: no network)\n' > "$STATE_DIR/status/python-runner.txt"
  owui_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=2026102509 open-webui"
  # (all there now: the same try value from then on — Docker's cache holds that build, never the one before)
  printf 'ready\tmicropip\t1\nready\tnumpy\t2\n' > "$STATE_DIR/status/python-runner.txt"
  : > "$TMP/dc"
  owui_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=2026102509 open-webui"
  # a package the lock does not have is no reason to build again
  printf 'ready\tmicropip\t1\nleft\tnope\tnot in the image'"'"'s pyodide-lock.json\n' > "$STATE_DIR/status/python-runner.txt"
  : > "$TMP/dc"
  owui_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=2026102509 open-webui"
  dc() { return 1; }
  if owui_build; then echo "a failed build must fail" >&2; return 1; fi
}

# python_runner_status: what the image's build did, from its own folder (outside what Open WebUI serves) — an image
# of an earlier build had it beside the wheels: read there then — once per image
test_python_runner_status_reads_the_report_outside_the_served_folder() {
  STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR/status"
  docker() {
    echo "docker $*" >> "$TMP/docker"
    case "$*" in
      "image inspect"*) echo sha256:img1 ;;
      *"cat bn-t/open-webui:local /opt/bn-vendor/vendored.txt") [ -e "$TMP/old" ] && return 1; printf 'ready\tmicropip\t1\n' ;;
      *"cat bn-t/open-webui:local /app/build/pyodide/vendored.txt") printf 'ready\tnumpy\t2\n' ;;
      *) return 1 ;;
    esac
  }
  project_name() { echo bn-t; }
  python_runner_status
  assert_eq "$(cat "$STATE_DIR/status/python-runner.txt")" "$(printf 'ready\tmicropip\t1')"
  assert_not_contains "$(cat "$TMP/docker")" "/app/build/pyodide/vendored.txt"
  # (the same image again: not read again)
  : > "$TMP/docker"; python_runner_status
  assert_not_contains "$(cat "$TMP/docker")" "docker run"
  # an image of an earlier build: its list beside the wheels
  rm -f "$STATE_DIR/status/python-runner.id"; : > "$TMP/old"
  python_runner_status
  assert_eq "$(cat "$STATE_DIR/status/python-runner.txt")" "$(printf 'ready\tnumpy\t2')"
}

test_python_runner_line_says_what_is_ready_and_what_is_left_out() {
  STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR/status"
  assert_eq "$(python_runner_line)" ""
  printf 'ready\tmicropip\t120000\nready\tnumpy\t2900000\n' > "$STATE_DIR/status/python-runner.txt"
  assert_eq "$(python_runner_line)" "Python runner (Chat): 2 packages ready"
  printf 'ready\tmicropip\t1\nleft\tnumpy\tdownload failed (URLError: no network)\nleft\tpandas\tneeds numpy, left out\n' > "$STATE_DIR/status/python-runner.txt"
  assert_eq "$(python_runner_line)" "Python runner (Chat): 1 package ready; left out: numpy (download failed (URLError: no network)), pandas (needs numpy, left out)"
}
